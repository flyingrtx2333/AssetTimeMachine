#!/usr/bin/env python3
"""High-return strategy logic candidates.

This spike focuses on annualized return under a strict no-financing rule.
All candidates are long-only with maximum notional exposure capped at 100%.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
import math
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
    runner: Callable[[], app.BacktestResult]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize_to(weights: dict[str, float], target_total: float) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total <= 0:
        return {}
    scale = max(target_total, 0.0) / total
    return {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}


def cap_total(weights: dict[str, float], max_total: float) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


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


def rolling_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int = 60) -> float | None:
    values = prices_by_symbol[symbol]
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(variance) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def risk_adjusted_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60) or 0.0
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120) or 0.0
    vol = rolling_vol(prices_by_symbol, symbol, index) or 9.0
    return max(0.0, (mom120 + 0.5 * mom60) / max(vol, 0.01))


def score_basket(symbols: list[str], prices_by_symbol: dict[str, list[float]], index: int, budget: float) -> dict[str, float]:
    scored = [(symbol, risk_adjusted_score(prices_by_symbol, symbol, index)) for symbol in symbols]
    scored = [(symbol, score) for symbol, score in scored if score > 0]
    total = sum(score for _symbol, score in scored)
    if total <= 0:
        return {}
    return {symbol: budget * score / total for symbol, score in scored}


def current_handoff(original: Overlay) -> Overlay:
    return logic.mechanism_gold_to_confirmed_us_handoff(original)


def full_budget_current_winner(original: Overlay) -> Overlay:
    base = current_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return normalize_to(weights, 1.0) if weights else {}

    return overlay


def fill_all_confirmed_to_full(original: Overlay) -> Overlay:
    base = current_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        budget = 1.0 - total_weight(weights)
        if budget > 0:
            addition = score_basket([symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)], prices_by_symbol, signal_index, budget)
            for symbol, weight in addition.items():
                weights[symbol] = weights.get(symbol, 0.0) + weight
        return cap_total(weights, 1.0)

    return overlay


def equity_breadth(original: Overlay) -> Overlay:
    base = current_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        equities = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        budget = 1.0 - total_weight(weights)
        if len(equities) >= 2 and budget > 0:
            addition = score_basket(equities, prices_by_symbol, signal_index, budget)
            for symbol, weight in addition.items():
                weights[symbol] = weights.get(symbol, 0.0) + weight
        return cap_total(weights, 1.0)

    return overlay


def us_equity_core_boost(original: Overlay) -> Overlay:
    base = current_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        us = [symbol for symbol in ["nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index)]
        budget = 1.0 - total_weight(weights)
        if us and budget > 0:
            addition = score_basket(us, prices_by_symbol, signal_index, budget)
            for symbol, weight in addition.items():
                weights[symbol] = weights.get(symbol, 0.0) + weight
        return cap_total(weights, 1.0)

    return overlay


def china_us_barbell_boost(original: Overlay) -> Overlay:
    base = current_handoff(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        confirmed_equities = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        us_ok = any(symbol in confirmed_equities for symbol in ["nasdaq", "sp500"])
        cn_ok = any(symbol in confirmed_equities for symbol in ["csi300", "shanghai_composite"])
        budget = 1.0 - total_weight(weights)
        if us_ok and cn_ok and budget > 0:
            addition = score_basket(confirmed_equities, prices_by_symbol, signal_index, budget)
            for symbol, weight in addition.items():
                weights[symbol] = weights.get(symbol, 0.0) + weight
        return cap_total(weights, 1.0)

    return overlay


def run_overlay_strategy(name: str, overlay_factory: Callable[[Overlay], Overlay]) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    app.apply_gold_satellite_overlay = overlay_factory(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
    return app.BacktestResult(
        strategy=name,
        coverage_start=result.coverage_start,
        coverage_end=result.coverage_end,
        point_count=result.point_count,
        annualized_return=result.annualized_return,
        max_drawdown=result.max_drawdown,
        total_return=result.total_return,
        annualized_volatility=result.annualized_volatility,
        sharpe_ratio=result.sharpe_ratio,
        final_value=result.final_value,
        trades=result.trades,
        dates=result.dates,
        values=result.values,
    )


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def route_by_return(context: dict[str, app.BacktestResult]) -> Callable[[Overlay], Overlay]:
    engines = {
        "full": full_budget_current_winner,
        "fill_all": fill_all_confirmed_to_full,
        "breadth": equity_breadth,
    }

    def factory(original: Overlay) -> Overlay:
        overlays = {name: overlay_factory(original) for name, overlay_factory in engines.items()}

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            scores: list[tuple[float, str]] = []
            for name, result in context.items():
                value = trailing_return(result.values, signal_index, 240)
                if value is not None:
                    scores.append((value, name))
            if not scores:
                return overlays["fill_all"](raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            best = max(scores)[1]
            return overlays[best](raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

        return overlay

    return factory


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


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
    return {"peak_date": result.dates[worst_peak].isoformat(), "trough_date": result.dates[worst_trough].isoformat(), "max_drawdown": worst}


def row_for(candidate: Candidate, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": candidate.name,
        "thesis": candidate.thesis,
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
        base_candidates = [
            Candidate("current_gold_handoff", "Current defensive/balanced champion.", lambda: run_overlay_strategy("current_gold_handoff", current_handoff)),
            Candidate("full_budget_current_winner", "Use full cash budget whenever current champion chooses risk.", lambda: run_overlay_strategy("full_budget_current_winner", full_budget_current_winner)),
            Candidate("fill_all_confirmed_to_full", "Fill idle cash into all confirmed assets by risk-adjusted momentum.", lambda: run_overlay_strategy("fill_all_confirmed_to_full", fill_all_confirmed_to_full)),
            Candidate("equity_breadth", "Fill idle cash into confirmed equity breadth.", lambda: run_overlay_strategy("equity_breadth", equity_breadth)),
            Candidate("us_equity_core_boost", "Fill idle cash into confirmed US equity engines.", lambda: run_overlay_strategy("us_equity_core_boost", us_equity_core_boost)),
            Candidate("china_us_barbell_boost", "Use idle cash only when both US and China equity engines confirm.", lambda: run_overlay_strategy("china_us_barbell_boost", china_us_barbell_boost)),
        ]
        rows = [row_for(candidate, candidate.runner()) for candidate in base_candidates]

        engine_results = {
            "full": run_overlay_strategy("full", full_budget_current_winner),
            "fill_all": run_overlay_strategy("fill_all", fill_all_confirmed_to_full),
            "breadth": run_overlay_strategy("breadth", equity_breadth),
        }
        router_candidate = Candidate("aggressive_return_router", "Route among full-budget, all-confirmed, and equity-breadth engines by one-year return leadership.", lambda: run_overlay_strategy("aggressive_return_router", route_by_return(engine_results)))
        rows.append(row_for(router_candidate, router_candidate.runner()))

    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["annualized"], row["full"]["sharpe"] or 0.0), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nSUMMARY")
    print("name | ann/dd/sharpe/vol | post2020 ann | last10 ann | post2024 ann | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])} | "
            f"{pct(slices['last_10y']['annualized'])} | "
            f"{pct(slices['post_2024']['annualized'])} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
