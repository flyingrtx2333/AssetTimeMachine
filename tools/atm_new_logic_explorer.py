#!/usr/bin/env python3
"""New-mechanism strategy spikes for AssetTimeMachine.

This script is intentionally mechanism-first, not parameter-grid-first.  Each
candidate expresses a distinct risk idea on top of the current App-equivalent
baseline and the previously found gold blowoff rollover guard.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
import json
from typing import Any, Callable

import atm_app_equivalent_backtest as app
import atm_strategy_explorer as base_explorer

Overlay = Callable[[dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config], dict[str, float]]


@dataclass(frozen=True)
class Mechanism:
    name: str
    thesis: str
    overlay_factory: Callable[[Overlay], Overlay]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def cap_group(weights: dict[str, float], symbols: list[str], max_total: float) -> dict[str, float]:
    current = sum(max(weights.get(symbol, 0.0), 0.0) for symbol in symbols)
    if current <= max_total or current <= 0:
        return weights
    scale = max_total / current
    out = dict(weights)
    for symbol in symbols:
        if out.get(symbol, 0.0) > 0:
            out[symbol] *= scale
    return {k: v for k, v in out.items() if v > 0.0001}


def mom(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    return app.price_momentum(prices_by_symbol[symbol], index, lookback)


def above_ma(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, period: int) -> bool:
    ma = app.moving_average(prices_by_symbol[symbol], period)[index]
    return ma is not None and prices_by_symbol[symbol][index] >= ma


def equity_exposure(weights: dict[str, float]) -> float:
    return sum(max(weights.get(symbol, 0.0), 0.0) for symbol in app.EQUITY_SYMBOLS)


def drawdown_from_points(points: list[float] | None, lookback: int = 60) -> float:
    if not points:
        return 0.0
    window = points[-lookback:]
    peak = max(window) if window else 0.0
    if peak <= 0:
        return 0.0
    return points[-1] / peak - 1.0


def normalize_total(weights: dict[str, float], max_total: float = 0.85) -> dict[str, float]:
    total = sum(max(v, 0.0) for v in weights.values())
    if total > max_total and total > 0:
        scale = max_total / total
        return {symbol: weight * scale for symbol, weight in weights.items() if weight * scale > 0.0001}
    return {symbol: weight for symbol, weight in weights.items() if weight > 0.0001}


def mechanism_global_risk_confirmation(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        eq = equity_exposure(weights)
        if eq <= 0.45:
            return weights
        selected_equities = [s for s in app.EQUITY_SYMBOLS if weights.get(s, 0.0) > 0]
        selected_ok = all((mom(prices_by_symbol, s, signal_index, 20) or -1.0) > 0 for s in selected_equities)
        market_ok = (mom(prices_by_symbol, "sp500", signal_index, 60) or -1.0) > 0 and above_ma(prices_by_symbol, "sp500", signal_index, 120)
        # New logic: a high equity allocation is allowed only when both the target
        # asset and broad US market confirm. Otherwise stage risk in cash.
        if not (selected_ok and market_ok):
            weights = cap_group(weights, app.EQUITY_SYMBOLS, 0.35)
        return normalize_total(weights)
    return overlay


def mechanism_bubble_quarantine(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if equity_exposure(weights) <= 0:
            return weights
        # New logic: after a regional equity bubble has already doubled-ish over a
        # year and then loses short-term momentum, avoid rotating into another
        # equity market.  Treat it as global risk-contagion risk, not local noise.
        bubble_rolling_over = False
        for symbol in app.EQUITY_SYMBOLS:
            long = mom(prices_by_symbol, symbol, signal_index, 240)
            short = mom(prices_by_symbol, symbol, signal_index, 20)
            if long is not None and short is not None and long > 0.45 and short < 0:
                bubble_rolling_over = True
                break
        if bubble_rolling_over:
            weights = cap_group(weights, app.EQUITY_SYMBOLS, 0.30)
        return normalize_total(weights)
    return overlay


def mechanism_drawdown_sensitive_risk_budget(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        # New logic: when the strategy equity curve is below its recent high,
        # don't immediately rebuild a full 60%+ risky sleeve.  This is a state
        # machine risk budget, not an asset-level stop.
        curve_dd = drawdown_from_points(portfolio_values, 60)
        if curve_dd < -0.025:
            weights = cap_group(weights, ["gold_cny", *app.EQUITY_SYMBOLS], 0.65)
        return normalize_total(weights)
    return overlay


def mechanism_safe_haven_validity(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        # New logic: gold is defensive only when it is not itself in a blowoff
        # rollover. If equities are also not broadly confirmed, hold cash instead
        # of forcing risk into either gold or equity.
        gold_hot = (mom(prices_by_symbol, "gold_cny", signal_index, 90) or 0.0) > 0.08
        gold_roll = (mom(prices_by_symbol, "gold_cny", signal_index, 20) or 0.0) < 0
        market_ok = (mom(prices_by_symbol, "sp500", signal_index, 60) or -1.0) > 0 and above_ma(prices_by_symbol, "sp500", signal_index, 120)
        if gold_hot and gold_roll and not market_ok:
            weights = cap_group(weights, ["gold_cny", *app.EQUITY_SYMBOLS], 0.45)
        return normalize_total(weights)
    return overlay


def mechanism_cluster_rotation_veto(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        # New logic: don't allow a single regional equity cluster to inherit risk
        # when the other cluster is in a severe rollover.  Cross-market contagion
        # usually arrives with a lag, so cash is the neutral asset during handoff.
        us_symbols = ["nasdaq", "sp500"]
        cn_symbols = ["csi300", "shanghai_composite"]
        us_bad = any((mom(prices_by_symbol, s, signal_index, 60) or 0.0) < -0.08 for s in us_symbols)
        cn_bad = any((mom(prices_by_symbol, s, signal_index, 60) or 0.0) < -0.12 for s in cn_symbols)
        if equity_exposure(weights) > 0.45 and (us_bad or cn_bad):
            weights = cap_group(weights, app.EQUITY_SYMBOLS, 0.35)
        return normalize_total(weights)
    return overlay


def mechanism_gold_to_confirmed_us_handoff(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        # New logic: when gold loses safe-haven validity after a blowoff rollover,
        # do not leave all released risk in cash if US broad risk is confirmed.
        # Hand off one replacement sleeve to the stronger confirmed US core asset.
        gold_hot = (mom(prices_by_symbol, "gold_cny", signal_index, 90) or 0.0) > 0.08
        gold_roll = (mom(prices_by_symbol, "gold_cny", signal_index, 20) or 0.0) < 0
        if not (gold_hot and gold_roll):
            return normalize_total(weights)
        china_mania = any(
            (mom(prices_by_symbol, symbol, signal_index, 240) or 0.0) > 1.0
            and (app.donchian_range_position(prices_by_symbol[symbol], signal_index, 240) or 0.0) > 0.95
            for symbol in ["csi300", "shanghai_composite"]
        )
        if china_mania:
            return normalize_total(weights)
        sp_ok = (mom(prices_by_symbol, "sp500", signal_index, 60) or -1.0) > 0 and above_ma(prices_by_symbol, "sp500", signal_index, 120)
        nd_ok = (mom(prices_by_symbol, "nasdaq", signal_index, 60) or -1.0) > 0 and above_ma(prices_by_symbol, "nasdaq", signal_index, 120)
        if not (sp_ok or nd_ok):
            return normalize_total(weights)
        replacement_symbol = "nasdaq" if nd_ok and (mom(prices_by_symbol, "nasdaq", signal_index, 60) or 0.0) > (mom(prices_by_symbol, "sp500", signal_index, 60) or 0.0) else "sp500"
        # Fixed replacement sleeve: this represents the freed gold-risk budget,
        # not a searched parameter. Total exposure remains capped by 85% below.
        weights[replacement_symbol] = weights.get(replacement_symbol, 0.0) + 0.20
        return normalize_total(weights)
    return overlay


def mechanisms() -> list[Mechanism]:
    return [
        Mechanism(
            "gold_to_confirmed_us_handoff",
            "When gold rolls over after a run-up, hand one freed sleeve to the stronger confirmed US core asset instead of leaving it all in cash.",
            mechanism_gold_to_confirmed_us_handoff,
        ),
        Mechanism(
            "global_risk_confirmation",
            "High equity exposure requires both the chosen equity and broad S&P confirmation; otherwise stage the entry in cash.",
            mechanism_global_risk_confirmation,
        ),
        Mechanism(
            "bubble_quarantine",
            "A rolling-over regional equity bubble is treated as global contagion risk; cap all equities instead of rotating to the next equity market.",
            mechanism_bubble_quarantine,
        ),
        Mechanism(
            "drawdown_sensitive_risk_budget",
            "If the strategy equity curve is below its recent high, rebuild risk slowly via a portfolio-state budget.",
            mechanism_drawdown_sensitive_risk_budget,
        ),
        Mechanism(
            "safe_haven_validity",
            "When gold itself is in a blowoff rollover and equities lack broad confirmation, hold cash rather than forcing either safe-haven or equity risk.",
            mechanism_safe_haven_validity,
        ),
        Mechanism(
            "cluster_rotation_veto",
            "A severe rollover in one regional equity cluster vetoes a large equity allocation to another cluster during the contagion handoff.",
            mechanism_cluster_rotation_veto,
        ),
    ]


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "total": None}
    total, annualized, max_dd, _vol, _sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, object]:
    peak = result.values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def run_with_overlay(name: str, thesis: str, overlay_factory: Callable[[Overlay], Overlay]) -> dict[str, object]:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(cap=0.45, long_lookback=90, long_threshold=0.08, short_lookback=20)
    app.apply_gold_satellite_overlay = overlay_factory(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
    return {
        "name": name,
        "thesis": thesis,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "total": result.total_return,
            "sharpe": result.sharpe_ratio,
            "trades": len(result.trades),
            "final_value": result.final_value,
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(t.date, t.action, t.symbol, round(t.cash_amount, 2)) for t in result.trades[-8:]],
    }


def main() -> None:
    original_fetch = app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        # Reference candidate from the previous round.
        reference = run_with_overlay(
            "gold_blowoff_rollover_cap45_reference",
            "Reference: cap gold to 45% only after a gold run-up rolls over.",
            lambda gold_guard: gold_guard,
        )
        rows = [reference] + [run_with_overlay(m.name, m.thesis, m.overlay_factory) for m in mechanisms()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["max_drawdown"] <= 0.10, row["full"]["annualized"]), reverse=True)  # type: ignore[index, operator]
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    print("\nSUMMARY")
    print("name | full ann/dd | post2020 ann/dd | last10 ann/dd | post2024 ann/dd | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]  # type: ignore[assignment]
        slices: dict[str, dict[str, Any]] = row["slices"]  # type: ignore[assignment]
        ddw: dict[str, Any] = row["drawdown_window"]  # type: ignore[assignment]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{pct(slices['post_2020']['max_drawdown'])} | "
            f"{pct(slices['last_10y']['annualized'])}/{pct(slices['last_10y']['max_drawdown'])} | "
            f"{pct(slices['post_2024']['annualized'])}/{pct(slices['post_2024']['max_drawdown'])} | "
            f"{full['trades']} | {ddw['peak_date']}→{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
