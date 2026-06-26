#!/usr/bin/env python3
"""Mechanism-first high-return / high-Sharpe strategy candidates.

This spike intentionally avoids parameter grids.  Each candidate is a distinct
portfolio construction idea on top of the current gold handoff champion.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402
import atm_new_logic_explorer as logic  # noqa: E402
import atm_strategy_explorer as base_explorer  # noqa: E402

Overlay = Callable[[dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config], dict[str, float]]


@dataclass(frozen=True)
class Candidate:
    name: str
    thesis: str
    overlay_factory: Callable[[Overlay], Overlay]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def normalize_to_budget(weights: dict[str, float], max_total: float) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


def rolling_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    values = prices_by_symbol[symbol]
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(app.math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return app.math.sqrt(variance) * app.math.sqrt(app.TRADING_DAYS_PER_YEAR)


def confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60)
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120)
    return (
        mom60 is not None
        and mom120 is not None
        and mom60 > 0
        and mom120 > 0
        and logic.above_ma(prices_by_symbol, symbol, index, 120)
    )


def risk_adjusted_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60) or 0.0
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120) or 0.0
    vol = rolling_vol(prices_by_symbol, symbol, index, 60) or 9.0
    if vol <= 0:
        return 0.0
    return max(0.0, (mom120 + mom60 * 0.5) / vol)


def fill_budget_by_scores(
    weights: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    symbols: list[str],
    max_total: float,
) -> dict[str, float]:
    out = dict(weights)
    budget = max_total - total_weight(out)
    if budget <= 0:
        return normalize_to_budget(out, max_total)
    scored = [
        (risk_adjusted_score(prices_by_symbol, symbol, signal_index), symbol)
        for symbol in symbols
        if confirmed(prices_by_symbol, symbol, signal_index)
    ]
    scored = [(score, symbol) for score, symbol in scored if score > 0]
    if not scored:
        return normalize_to_budget(out, max_total)
    score_total = sum(score for score, _symbol in scored)
    for score, symbol in scored:
        out[symbol] = out.get(symbol, 0.0) + budget * score / score_total
    return normalize_to_budget(out, max_total)


def replace_with_score_basket(
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    symbols: list[str],
    max_total: float,
) -> dict[str, float]:
    scored = [
        (risk_adjusted_score(prices_by_symbol, symbol, signal_index), symbol)
        for symbol in symbols
        if confirmed(prices_by_symbol, symbol, signal_index)
    ]
    scored = [(score, symbol) for score, symbol in scored if score > 0]
    if not scored:
        return {}
    score_total = sum(score for score, _symbol in scored)
    return {
        symbol: max_total * score / score_total
        for score, symbol in scored
        if max_total * score / score_total > 0.0001
    }


def current_handoff(original: Overlay) -> Overlay:
    return logic.mechanism_gold_to_confirmed_us_handoff(original)


def mechanism_fill_all_confirmed_to_full(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return fill_budget_by_scores(weights, prices_by_symbol, signal_index, app.SYMBOLS, 1.0)

    return overlay


def mechanism_fill_core_confirmed_to_full(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)
    core_symbols = ["gold_cny", "nasdaq", "sp500"]

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return fill_budget_by_scores(weights, prices_by_symbol, signal_index, core_symbols, 1.0)

    return overlay


def mechanism_full_budget_current_winner(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        total = total_weight(weights)
        if total <= 0:
            return weights
        # New logic: if the existing champion logic chooses risk, use the full
        # cash budget instead of leaving the last 15% idle.
        return {symbol: weight / total for symbol, weight in weights.items() if weight > 0.0001}

    return overlay


def mechanism_score_basket_all_assets(_original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        basket = replace_with_score_basket(prices_by_symbol, signal_index, app.SYMBOLS, 1.0)
        return basket or raw_weights

    return overlay


def mechanism_score_basket_core_assets(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)
    core_symbols = ["gold_cny", "nasdaq", "sp500"]

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        basket = replace_with_score_basket(prices_by_symbol, signal_index, core_symbols, 1.0)
        if basket:
            return basket
        return handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

    return overlay


def mechanism_us_growth_accelerator(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if confirmed(prices_by_symbol, "sp500", signal_index) and confirmed(prices_by_symbol, "nasdaq", signal_index):
            # New logic: when both US engines confirm, fill unused budget into
            # the higher risk-adjusted US engine instead of holding cash.
            winner = "nasdaq" if risk_adjusted_score(prices_by_symbol, "nasdaq", signal_index) >= risk_adjusted_score(prices_by_symbol, "sp500", signal_index) else "sp500"
            budget = 1.0 - total_weight(weights)
            if budget > 0:
                weights[winner] = weights.get(winner, 0.0) + budget
        return normalize_to_budget(weights, 1.0)

    return overlay


def mechanism_dual_engine_core_satellite(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        additions = [symbol for symbol in ["sp500", "nasdaq", "gold_cny"] if confirmed(prices_by_symbol, symbol, signal_index)]
        if not additions:
            return normalize_to_budget(weights, 1.0)
        budget = 1.0 - total_weight(weights)
        if budget > 0:
            for symbol in additions:
                weights[symbol] = weights.get(symbol, 0.0) + budget / len(additions)
        return normalize_to_budget(weights, 1.0)

    return overlay


def mechanism_equity_breadth_accelerator(original: Overlay) -> Overlay:
    handoff = logic.mechanism_gold_to_confirmed_us_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = handoff(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        equity_confirmed = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(equity_confirmed) >= 2:
            return fill_budget_by_scores(weights, prices_by_symbol, signal_index, equity_confirmed, 1.0)
        return normalize_to_budget(weights, 1.0)

    return overlay


def candidate_specs() -> list[Candidate]:
    return [
        Candidate(
            "current_gold_handoff",
            "Current champion: gold rollover cap plus confirmed US handoff.",
            current_handoff,
        ),
        Candidate(
            "full_budget_current_winner",
            "Use the full budget whenever current champion logic chooses risk.",
            mechanism_full_budget_current_winner,
        ),
        Candidate(
            "fill_core_confirmed_to_full",
            "Fill idle cash into confirmed gold/Nasdaq/S&P sleeves by risk-adjusted momentum.",
            mechanism_fill_core_confirmed_to_full,
        ),
        Candidate(
            "fill_all_confirmed_to_full",
            "Fill idle cash into any confirmed asset by risk-adjusted momentum.",
            mechanism_fill_all_confirmed_to_full,
        ),
        Candidate(
            "us_growth_accelerator",
            "When both Nasdaq and S&P confirm, fill idle cash into the stronger risk-adjusted US engine.",
            mechanism_us_growth_accelerator,
        ),
        Candidate(
            "dual_engine_core_satellite",
            "Keep champion selection, then diversify idle cash equally across confirmed US/gold engines.",
            mechanism_dual_engine_core_satellite,
        ),
        Candidate(
            "equity_breadth_accelerator",
            "When at least two equity markets confirm, fill idle cash into the confirmed equity breadth.",
            mechanism_equity_breadth_accelerator,
        ),
        Candidate(
            "score_basket_core_assets",
            "Replace winner-take-all with a full-budget risk-adjusted basket over gold/Nasdaq/S&P.",
            mechanism_score_basket_core_assets,
        ),
        Candidate(
            "score_basket_all_assets",
            "Replace winner-take-all with a full-budget risk-adjusted basket over all assets.",
            mechanism_score_basket_all_assets,
        ),
    ]


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "total": total, "annual_vol": annual_vol}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, Any]:
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


def run_candidate(spec: Candidate) -> dict[str, Any]:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    app.apply_gold_satellite_overlay = spec.overlay_factory(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]

    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "annual_volatility": result.annualized_volatility,
            "sharpe": result.sharpe_ratio,
            "total": result.total_return,
            "trades": len(result.trades),
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
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
        rows = [run_candidate(spec) for spec in candidate_specs()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(
        key=lambda row: (
            row["full"]["sharpe"] or 0.0,  # type: ignore[index]
            row["full"]["annualized"],  # type: ignore[index]
        ),
        reverse=True,
    )

    output = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "rows": rows,
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nSUMMARY")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
