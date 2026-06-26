#!/usr/bin/env python3
"""Portfolio-construction logic candidates.

This spike tests whether Sharpe can be improved by changing the portfolio
construction engine instead of tuning signal thresholds:

- confirmed-asset inverse volatility;
- confirmed-asset minimum variance;
- confirmed-asset tangency portfolio;
- anti-correlated pair construction;
- target-level ensembles with the current champion.
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
    overlay_factory: Callable[[Overlay], Overlay]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def normalize(weights: dict[str, float], budget: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total <= 0:
        return {}
    scale = budget / total
    return {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}


def cap_total(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
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


def log_returns(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int, lookback: int = 120) -> dict[str, list[float]]:
    if index - lookback + 1 < 1:
        return {}
    output: dict[str, list[float]] = {symbol: [] for symbol in symbols}
    for cursor in range(index - lookback + 1, index + 1):
        for symbol in symbols:
            previous = prices_by_symbol[symbol][cursor - 1]
            current = prices_by_symbol[symbol][cursor]
            if previous <= 0 or current <= 0:
                return {}
            output[symbol].append(math.log(current / previous))
    return output


def covariance(returns_by_symbol: dict[str, list[float]], symbols: list[str]) -> tuple[list[float], list[list[float]]]:
    sample_count = len(next(iter(returns_by_symbol.values())))
    means = [sum(returns_by_symbol[symbol]) / sample_count for symbol in symbols]
    matrix = [[0.0 for _ in symbols] for _ in symbols]
    for i, left in enumerate(symbols):
        for j, right in enumerate(symbols):
            acc = 0.0
            for cursor in range(sample_count):
                acc += (returns_by_symbol[left][cursor] - means[i]) * (returns_by_symbol[right][cursor] - means[j])
            matrix[i][j] = acc / max(sample_count - 1, 1)
    # Light diagonal shrinkage keeps the optimizer from creating unstable
    # near-singular portfolios while preserving observed correlation structure.
    for i in range(len(symbols)):
        matrix[i][i] += max(matrix[i][i] * 0.05, 1e-8)
    return means, matrix


def solve_linear(matrix: list[list[float]], vector: list[float]) -> list[float] | None:
    n = len(vector)
    a = [row[:] + [vector[i]] for i, row in enumerate(matrix)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda row: abs(a[row][col]))
        if abs(a[pivot][col]) < 1e-12:
            return None
        if pivot != col:
            a[col], a[pivot] = a[pivot], a[col]
        pivot_value = a[col][col]
        for item in range(col, n + 1):
            a[col][item] /= pivot_value
        for row in range(n):
            if row == col:
                continue
            factor = a[row][col]
            if factor == 0:
                continue
            for item in range(col, n + 1):
                a[row][item] -= factor * a[col][item]
    return [a[row][n] for row in range(n)]


def long_only_solve(symbols: list[str], matrix: list[list[float]], vector: list[float]) -> dict[str, float]:
    active = list(range(len(symbols)))
    while active:
        sub_matrix = [[matrix[i][j] for j in active] for i in active]
        sub_vector = [vector[i] for i in active]
        solution = solve_linear(sub_matrix, sub_vector)
        if solution is None:
            break
        if all(value >= 0 for value in solution):
            raw = {symbols[index]: value for index, value in zip(active, solution)}
            return normalize(raw)
        worst_position = min(range(len(solution)), key=lambda i: solution[i])
        active.pop(worst_position)
    return {}


def inverse_vol_portfolio(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int) -> dict[str, float]:
    returns_by_symbol = log_returns(prices_by_symbol, symbols, index)
    if not returns_by_symbol:
        return {}
    _means, cov = covariance(returns_by_symbol, symbols)
    inv: dict[str, float] = {}
    for i, symbol in enumerate(symbols):
        vol = math.sqrt(max(cov[i][i], 1e-12))
        inv[symbol] = 1 / vol
    return normalize(inv)


def min_variance_portfolio(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int) -> dict[str, float]:
    returns_by_symbol = log_returns(prices_by_symbol, symbols, index)
    if not returns_by_symbol:
        return {}
    _means, cov = covariance(returns_by_symbol, symbols)
    return long_only_solve(symbols, cov, [1.0] * len(symbols))


def tangency_portfolio(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int) -> dict[str, float]:
    returns_by_symbol = log_returns(prices_by_symbol, symbols, index)
    if not returns_by_symbol:
        return {}
    means, cov = covariance(returns_by_symbol, symbols)
    expected = [max(mean, 0.0) for mean in means]
    if sum(expected) <= 0:
        return {}
    return long_only_solve(symbols, cov, expected)


def correlation(returns_by_symbol: dict[str, list[float]], left: str, right: str) -> float:
    left_values = returns_by_symbol[left]
    right_values = returns_by_symbol[right]
    mean_left = sum(left_values) / len(left_values)
    mean_right = sum(right_values) / len(right_values)
    cov = sum((l - mean_left) * (r - mean_right) for l, r in zip(left_values, right_values))
    var_left = sum((l - mean_left) ** 2 for l in left_values)
    var_right = sum((r - mean_right) ** 2 for r in right_values)
    denom = math.sqrt(max(var_left * var_right, 1e-18))
    return cov / denom


def anti_correlated_pair(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int) -> dict[str, float]:
    returns_by_symbol = log_returns(prices_by_symbol, symbols, index)
    if len(symbols) < 2 or not returns_by_symbol:
        return {}
    primary = max(symbols, key=lambda symbol: (logic.mom(prices_by_symbol, symbol, index, 120) or 0.0))
    partners = [symbol for symbol in symbols if symbol != primary]
    partner = min(partners, key=lambda symbol: correlation(returns_by_symbol, primary, symbol))
    return inverse_vol_portfolio(prices_by_symbol, [primary, partner], index)


def current_handoff_overlay(original: Overlay) -> Overlay:
    return logic.mechanism_gold_to_confirmed_us_handoff(original)


def overlay_equity_breadth_accelerator(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        equities = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(equities) < 2:
            return weights
        budget = 1.0 - total_weight(weights)
        if budget <= 0:
            return cap_total(weights)
        addition = tangency_portfolio(prices_by_symbol, equities, signal_index) or inverse_vol_portfolio(prices_by_symbol, equities, signal_index)
        for symbol, weight in addition.items():
            weights[symbol] = weights.get(symbol, 0.0) + budget * weight
        return cap_total(weights)

    return overlay


def overlay_inverse_vol_all(_original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        symbols = [symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(symbols) < 2:
            return {}
        return inverse_vol_portfolio(prices_by_symbol, symbols, signal_index)
    return overlay


def overlay_min_variance_all(_original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        symbols = [symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(symbols) < 2:
            return {}
        return min_variance_portfolio(prices_by_symbol, symbols, signal_index)
    return overlay


def overlay_tangency_all(_original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        symbols = [symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(symbols) < 2:
            return {}
        return tangency_portfolio(prices_by_symbol, symbols, signal_index)
    return overlay


def overlay_tangency_core(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(symbols) < 2:
            return base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return tangency_portfolio(prices_by_symbol, symbols, signal_index)
    return overlay


def overlay_anti_pair_all(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        symbols = [symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(symbols) < 2:
            return base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return anti_correlated_pair(prices_by_symbol, symbols, signal_index)
    return overlay


def blend(first: dict[str, float], second: dict[str, float], first_share: float = 0.5) -> dict[str, float]:
    out: dict[str, float] = {}
    for symbol, weight in first.items():
        out[symbol] = out.get(symbol, 0.0) + weight * first_share
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * (1 - first_share)
    return cap_total(out)


def overlay_current_tangency_ensemble(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)
    tangency = overlay_tangency_all(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        base_weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        tangent_weights = tangency(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return blend(base_weights, tangent_weights) if tangent_weights else base_weights
    return overlay


def overlay_current_minvar_ensemble(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)
    minvar = overlay_min_variance_all(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        base_weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        minvar_weights = minvar(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return blend(base_weights, minvar_weights) if minvar_weights else base_weights
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


def candidate_specs() -> list[Candidate]:
    return [
        Candidate("current_gold_handoff", "Current gold handoff champion.", current_handoff_overlay),
        Candidate("equity_breadth_tangency", "Current champion plus idle-cash equity breadth using tangency weights.", overlay_equity_breadth_accelerator),
        Candidate("inverse_vol_confirmed_all", "Fully invested inverse-vol basket over confirmed assets.", overlay_inverse_vol_all),
        Candidate("min_variance_confirmed_all", "Fully invested minimum-variance basket over confirmed assets.", overlay_min_variance_all),
        Candidate("tangency_confirmed_all", "Fully invested long-only tangency basket over confirmed assets.", overlay_tangency_all),
        Candidate("tangency_confirmed_core", "Tangency basket over confirmed gold/Nasdaq/S&P, with current fallback.", overlay_tangency_core),
        Candidate("anti_correlated_pair_all", "Pair the strongest confirmed asset with its most diversifying confirmed partner.", overlay_anti_pair_all),
        Candidate("ensemble_current_tangency", "Target-level 50/50 ensemble of current champion and tangency basket.", overlay_current_tangency_ensemble),
        Candidate("ensemble_current_minvar", "Target-level 50/50 ensemble of current champion and minimum-variance basket.", overlay_current_minvar_ensemble),
    ]


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
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def run_candidate(spec: Candidate) -> dict[str, Any]:
    result = run_overlay_strategy(spec.name, spec.overlay_factory)
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

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

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
