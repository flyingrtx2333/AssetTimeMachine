#!/usr/bin/env python3
"""Smooth portfolio-state risk budget candidates.

No leverage, no shorting, no notional exposure above 100%.

The current champion is the one-way volatility-managed engine router.  This
spike keeps that router and tests whether a smoother portfolio-state risk
budget can remove more dead volatility than the earlier two-step ladder.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

S28_PATH = ROOT / "spikes" / "028-calendar-invariant-sharpe14" / "sharpe14_logic.py"
SPEC = importlib.util.spec_from_file_location("sharpe14_logic_base", S28_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {S28_PATH}")
s28 = importlib.util.module_from_spec(SPEC)
sys.modules["sharpe14_logic_base"] = s28
SPEC.loader.exec_module(s28)

app = s28.app
base = s28.base
Overlay = base.Overlay


@dataclass(frozen=True)
class BudgetSpec:
    name: str
    thesis: str
    lookback: int
    soft_dd: float
    hard_dd: float
    min_scale: float
    mode: str


@dataclass(frozen=True)
class BacktestEnv:
    dates: list[date]
    prices_by_symbol: dict[str, list[float]]
    symbols: list[str]
    config: app.Config
    ma_by_symbol: dict[str, list[float | None]]
    vol_by_symbol: dict[str, list[float | None]]
    meta_traces: dict[str, app.SimulatedTrace]
    champion_overlay: Overlay


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = sum(clean.values())
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def scale(weights: dict[str, float], factor: float) -> dict[str, float]:
    factor = min(max(factor, 0.0), 1.0)
    return normalize({symbol: weight * factor for symbol, weight in weights.items()})


def clean_portfolio_values(portfolio_values: list[float] | None, signal_index: int) -> list[float]:
    if not portfolio_values:
        return []
    return [value for value in portfolio_values[: signal_index + 1] if value > 0]


def portfolio_drawdown(portfolio_values: list[float] | None, signal_index: int, lookback: int) -> float:
    clean = clean_portfolio_values(portfolio_values, signal_index)
    if not clean:
        return 0.0
    window = clean[-max(lookback, 1):]
    peak = max(window)
    return window[-1] / peak - 1 if peak > 0 else 0.0


def portfolio_return(portfolio_values: list[float] | None, signal_index: int, lookback: int) -> float:
    clean = clean_portfolio_values(portfolio_values, signal_index)
    if len(clean) <= lookback or clean[-lookback - 1] <= 0:
        return 0.0
    return clean[-1] / clean[-lookback - 1] - 1


def smooth_scale(dd: float, spec: BudgetSpec) -> float:
    stress = abs(min(dd, 0.0))
    if stress <= spec.soft_dd:
        return 1.0
    if stress >= spec.hard_dd:
        return spec.min_scale
    span = max(spec.hard_dd - spec.soft_dd, 0.0001)
    progress = (stress - spec.soft_dd) / span
    return 1.0 - progress * (1.0 - spec.min_scale)


def apply_budget(
    weights: dict[str, float],
    spec: BudgetSpec,
    signal_index: int,
    portfolio_values: list[float] | None,
) -> dict[str, float]:
    dd = portfolio_drawdown(portfolio_values, signal_index, spec.lookback)
    base_scale = smooth_scale(dd, spec)

    if spec.mode == "smooth":
        return scale(weights, base_scale)

    if spec.mode == "loss_confirmed":
        recent = portfolio_return(portfolio_values, signal_index, 20)
        if recent < 0:
            return scale(weights, base_scale)
        return weights

    if spec.mode == "two_speed":
        recent = portfolio_return(portfolio_values, signal_index, 20)
        if recent < -0.015:
            return scale(weights, min(base_scale, spec.min_scale + 0.12))
        return scale(weights, base_scale)

    if spec.mode == "profit_lock":
        recent = portfolio_return(portfolio_values, signal_index, 60)
        if recent > 0.08 and dd > -0.02:
            return scale(weights, min(base_scale, 0.90))
        return scale(weights, base_scale)

    if spec.mode == "convex":
        stress = abs(min(dd, 0.0))
        if stress <= spec.soft_dd:
            return weights
        span = max(spec.hard_dd - spec.soft_dd, 0.0001)
        progress = min(max((stress - spec.soft_dd) / span, 0.0), 1.0)
        convex = 1.0 - (progress ** 2) * (1.0 - spec.min_scale)
        return scale(weights, convex)

    raise ValueError(spec.mode)


def overlay_factory(context: base.EngineContext, spec: BudgetSpec) -> Callable[[Overlay], Overlay]:
    champion = next(item for item in s28.candidate_specs() if item.name == "baseline_one_way_vol")
    champion_factory = s28.overlay_factory(context, champion)

    def factory(original: Overlay) -> Overlay:
        champion_overlay = champion_factory(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            weights = champion_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            return apply_budget(weights, spec, signal_index, portfolio_values)

        return overlay

    return factory


def build_env(context: base.EngineContext) -> BacktestEnv:
    raw = app.fetch_public_history(end_date=app.parse_date("2026-06-23"))
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [series.symbol for series in prepared]
    config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
    ma_by_symbol, vol_by_symbol = app.indicator_maps(prices_by_symbol, config)
    if config.meta_switch is None:
        raise RuntimeError("expected meta switch for core strategy")
    meta_traces = {
        config.meta_switch.default_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.default_mode)),
        config.meta_switch.defensive_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.defensive_mode)),
    }
    gold_guard = base.base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    champion = next(item for item in s28.candidate_specs() if item.name == "baseline_one_way_vol")
    champion_overlay = s28.overlay_factory(context, champion)(gold_guard)
    return BacktestEnv(
        dates=dates,
        prices_by_symbol=prices_by_symbol,
        symbols=symbols,
        config=config,
        ma_by_symbol=ma_by_symbol,
        vol_by_symbol=vol_by_symbol,
        meta_traces=meta_traces,
        champion_overlay=champion_overlay,
    )


def run_budget_strategy(spec: BudgetSpec, env: BacktestEnv) -> app.BacktestResult:
    dates = env.dates
    prices_by_symbol = env.prices_by_symbol
    config = env.config
    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [symbol for symbol in env.symbols if symbol not in config.signal_only_symbols]
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        if config.meta_switch is None:
            raw_weights = app.advanced_rotation_target_weights(
                env.symbols,
                prices_by_symbol,
                env.ma_by_symbol,
                env.vol_by_symbol,
                signal_index,
                dates[signal_index],
                config,
            )
        else:
            raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, env.meta_traces) or {}
        champion_weights = env.champion_overlay(raw_weights, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        return apply_budget(champion_weights, spec, signal_index, values_by_index)

    for index, _current_date in enumerate(dates):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            targets = normalize(targets)
            target_symbols = set(targets.keys())
            pre_value = portfolio_value(index)

            for symbol in sorted(held - target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices_by_symbol[symbol][index]
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = current_units * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[symbol] = 0.0
                trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, current_units))
            held &= target_symbols

            for symbol in sorted(target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices_by_symbol[symbol][index]
                current_value = current_units * price
                target_value = pre_value * targets[symbol]
                gross_to_sell = max(current_value - target_value, 0.0)
                if gross_to_sell <= 0:
                    continue
                units_to_sell = min(current_units, gross_to_sell / price)
                if units_to_sell <= 0:
                    continue
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = units_to_sell * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[symbol] = max(current_units - units_to_sell, 0.0)
                trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
                if units[symbol] <= sys.float_info.min:
                    held.discard(symbol)

            total_value = portfolio_value(index)
            for symbol in sorted(target_symbols):
                price = prices_by_symbol[symbol][index]
                if price <= 0:
                    continue
                current_value = units.get(symbol, 0.0) * price
                target_value = total_value * targets[symbol]
                amount = min(cash, max(target_value - current_value, 0.0))
                if amount <= 0:
                    continue
                execution_price = price * (1 + slippage_rate)
                invested = amount * (1 - fee_rate)
                bought_units = invested / execution_price if execution_price > 0 else 0.0
                units[symbol] = units.get(symbol, 0.0) + bought_units
                cash -= amount
                held.add(symbol)
                trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))

        value = portfolio_value(index)
        points.append(value)
        values_by_index[index] = value

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    return app.BacktestResult(
        strategy=spec.name,
        coverage_start=dates[0].isoformat(),
        coverage_end=dates[-1].isoformat(),
        point_count=len(points),
        annualized_return=annualized,
        max_drawdown=max_dd,
        total_return=total,
        annualized_volatility=annual_vol,
        sharpe_ratio=sharpe,
        final_value=points[-1],
        trades=trades,
        dates=dates,
        values=points,
    )


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def rolling_window_metrics(result: app.BacktestResult, years: int = 3) -> dict[str, float | None]:
    window_days = int(years * 365.25)
    sharpes: list[float] = []
    annualized: list[float] = []
    drawdowns: list[float] = []
    for start_idx, start_day in enumerate(result.dates):
        end_day = date.fromordinal(start_day.toordinal() + window_days)
        end_idx = next((i for i in range(start_idx + 1, len(result.dates)) if result.dates[i] >= end_day), None)
        if end_idx is None:
            break
        _total, ann, dd, _vol, sharpe = app.performance_metrics(result.dates[start_idx : end_idx + 1], result.values[start_idx : end_idx + 1])
        annualized.append(ann)
        drawdowns.append(dd)
        if sharpe is not None:
            sharpes.append(sharpe)
    return {
        "worst_annualized": min(annualized) if annualized else None,
        "worst_sharpe": min(sharpes) if sharpes else None,
        "worst_drawdown": max(drawdowns) if drawdowns else None,
    }


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


def row_for(spec: BudgetSpec, result: app.BacktestResult, include_rolling: bool = False) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "lookback": spec.lookback,
            "soft_dd": spec.soft_dd,
            "hard_dd": spec.hard_dd,
            "min_scale": spec.min_scale,
            "mode": spec.mode,
        },
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
            "last_10y": slice_metrics(result, "2016-06-23"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "rolling_3y": rolling_window_metrics(result, 3) if include_rolling else {},
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def spec_grid() -> list[BudgetSpec]:
    specs: list[BudgetSpec] = []
    for mode in ["smooth", "loss_confirmed", "two_speed", "profit_lock", "convex"]:
        for lookback in [40, 60, 90, 120]:
            for soft_dd, hard_dd in [(0.012, 0.045), (0.018, 0.055), (0.025, 0.070), (0.035, 0.090)]:
                for min_scale in [0.35, 0.50, 0.65, 0.80]:
                    name = f"{mode}_lb{lookback}_s{int(soft_dd*1000)}_h{int(hard_dd*1000)}_m{int(min_scale*100)}"
                    specs.append(BudgetSpec(name, "Smooth portfolio-state risk budget on top of the current champion.", lookback, soft_dd, hard_dd, min_scale, mode))
    return specs


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
        current = s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
        breadth = s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
        context = base.EngineContext(current=current, breadth=breadth)
        env = build_env(context)
        rows = [row_for(spec, run_budget_strategy(spec, env)) for spec in spec_grid()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    enriched_rows: list[dict[str, Any]] = []
    for row in rows[:30]:
        spec_data = row["spec"]
        spec = BudgetSpec(
            name=row["name"],
            thesis=row["thesis"],
            lookback=spec_data["lookback"],
            soft_dd=spec_data["soft_dd"],
            hard_dd=spec_data["hard_dd"],
            min_scale=spec_data["min_scale"],
            mode=spec_data["mode"],
        )
        result = run_budget_strategy(spec, env)
        enriched_rows.append(row_for(spec, result, include_rolling=True))
    rows = enriched_rows + rows[30:]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | worst3y ann/sharpe | trades | dd window")
    for row in rows[:30]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        rolling: dict[str, Any] = row["rolling_3y"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{pct(rolling['worst_annualized'])}/{(rolling['worst_sharpe'] or 0):.4f} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
