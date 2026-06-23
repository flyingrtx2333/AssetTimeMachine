#!/usr/bin/env python3
"""Mechanism-level strategy explorer for AssetTimeMachine.

This script intentionally reuses `atm_app_equivalent_backtest.py` instead of
one-off /tmp research engines.  It tests a small set of interpretable candidate
mechanisms and reports full-history + slice metrics.
"""
from __future__ import annotations

from dataclasses import replace
from datetime import date
import json
import math
from typing import Any, Callable

import atm_app_equivalent_backtest as app

StrategyConfigFactory = Callable[[], dict[str, app.Config]]


def d(text: str) -> date:
    return app.parse_date(text)


def pct(x: float | None) -> str:
    return "n/a" if x is None else f"{x * 100:.2f}%"


def with_single_cap(config: app.Config, cap: float, symbols: list[str] | None = None) -> app.Config:
    overlay = config.gold_satellite_overlay
    assert overlay is not None
    old_cap = overlay.single_asset_exposure_cap
    assert old_cap is not None
    return replace(
        config,
        gold_satellite_overlay=replace(
            overlay,
            single_asset_exposure_cap=replace(old_cap, symbols=symbols or old_cap.symbols, max_weight=cap),
        ),
    )


def with_overlay_equity_brake(config: app.Config, threshold: float, scale: float) -> app.Config:
    overlay = config.gold_satellite_overlay
    assert overlay is not None
    brake = overlay.portfolio_equity_brake
    assert brake is not None
    return replace(
        config,
        gold_satellite_overlay=replace(
            overlay,
            portfolio_equity_brake=replace(brake, drawdown_threshold=threshold, equity_scale=scale),
        ),
    )


def with_meta_switch(config: app.Config, *, loss: float, vol: float, loss_dd: float, vol_dd: float) -> app.Config:
    meta = config.meta_switch
    assert meta is not None
    return replace(
        config,
        meta_switch=replace(
            meta,
            loss_threshold=loss,
            volatility_threshold=vol,
            loss_drawdown_threshold=loss_dd,
            volatility_drawdown_threshold=vol_dd,
        ),
    )


def with_tail_lock(config: app.Config, *, exposure: float, required: int) -> app.Config:
    lock = config.held_breakdown_lock
    guard = config.portfolio_drawdown_guard
    assert lock is not None and guard is not None
    return replace(
        config,
        held_breakdown_lock=replace(lock, max_exposure=exposure, required_signals=required),
        portfolio_drawdown_guard=replace(guard, drawdown_threshold=0.05, scale=0.12),
    )


def candidate_factories() -> list[tuple[str, str, StrategyConfigFactory]]:
    def baseline() -> dict[str, app.Config]:
        return {"coreGoldSatelliteHeatCappedMomentum": app.strategy_config("coreGoldSatelliteHeatCappedMomentum")}

    def cap60() -> dict[str, app.Config]:
        return {"coreGoldSatelliteHeatCappedMomentum": with_single_cap(app.strategy_config("coreGoldSatelliteHeatCappedMomentum"), 0.60)}

    def cap58() -> dict[str, app.Config]:
        return {"coreGoldSatelliteHeatCappedMomentum": with_single_cap(app.strategy_config("coreGoldSatelliteHeatCappedMomentum"), 0.58)}

    def early_meta_cap60() -> dict[str, app.Config]:
        c = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
        c = with_single_cap(c, 0.60)
        c = with_meta_switch(c, loss=0.025, vol=0.115, loss_dd=0.012, vol_dd=0.020)
        return {"coreGoldSatelliteHeatCappedMomentum": c}

    def equity_brake() -> dict[str, app.Config]:
        c = with_overlay_equity_brake(app.strategy_config("coreGoldSatelliteHeatCappedMomentum"), threshold=0.055, scale=0.70)
        return {"coreGoldSatelliteHeatCappedMomentum": c}

    def cap60_equity_brake() -> dict[str, app.Config]:
        c = with_single_cap(app.strategy_config("coreGoldSatelliteHeatCappedMomentum"), 0.60)
        c = with_overlay_equity_brake(c, threshold=0.055, scale=0.70)
        return {"coreGoldSatelliteHeatCappedMomentum": c}

    def harder_tail_defense() -> dict[str, app.Config]:
        core = with_single_cap(app.strategy_config("coreGoldSatelliteHeatCappedMomentum"), 0.60)
        core = with_meta_switch(core, loss=0.025, vol=0.115, loss_dd=0.012, vol_dd=0.020)
        defensive = with_tail_lock(app.strategy_config("tailBreakdownLockMomentum"), exposure=0.45, required=1)
        return {
            "coreGoldSatelliteHeatCappedMomentum": core,
            "tailBreakdownLockMomentum": defensive,
        }

    def gold_cap60() -> dict[str, app.Config]:
        c = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
        # Failure-regime diagnosis: the current max drawdown is the 2003 gold-heavy
        # drawdown, so cap gold as a blowoff-prone single asset while leaving the
        # existing equity cap mechanism intact.
        c = with_single_cap(c, 0.60, symbols=["gold_cny", *app.EQUITY_SYMBOLS])
        return {"coreGoldSatelliteHeatCappedMomentum": c}

    def gold_cap55() -> dict[str, app.Config]:
        c = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
        c = with_single_cap(c, 0.55, symbols=["gold_cny", *app.EQUITY_SYMBOLS])
        return {"coreGoldSatelliteHeatCappedMomentum": c}

    def gold_cap60_early_meta() -> dict[str, app.Config]:
        c = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
        c = with_single_cap(c, 0.60, symbols=["gold_cny", *app.EQUITY_SYMBOLS])
        c = with_meta_switch(c, loss=0.025, vol=0.115, loss_dd=0.012, vol_dd=0.020)
        return {"coreGoldSatelliteHeatCappedMomentum": c}

    def gold_blowoff_rollover_cap45() -> dict[str, app.Config]:
        return {"coreGoldSatelliteHeatCappedMomentum": app.strategy_config("coreGoldSatelliteHeatCappedMomentum")}

    return [
        ("baseline_cap64", "current App-equivalent baseline: meta loss/vol + gold satellite + 64% single-equity cap", baseline),
        ("gold_blowoff_rollover_cap45", "only after gold has run up and then rolls over, cap gold to 45% so safe-haven exposure cannot become the drawdown source", gold_blowoff_rollover_cap45),
        ("gold_and_equity_cap60", "cap every single asset including gold, because the live max drawdown is the 2003 gold-heavy blowoff reversal", gold_cap60),
        ("gold_and_equity_cap55", "stricter robustness check for the gold blowoff cap mechanism", gold_cap55),
        ("gold_cap60_early_meta", "gold blowoff cap plus earlier defensive meta switch", gold_cap60_early_meta),
        ("concentration_cap60", "same logic, but stricter single-equity concentration cap to reduce 2007/2022 concentration tails", cap60),
        ("concentration_cap58", "robustness check for the concentration-cap mechanism, not an open grid", cap58),
        ("early_meta_cap60", "switch to tail-breakdown defensive mode earlier when default engine loses money and volatility rises", early_meta_cap60),
        ("portfolio_equity_brake", "cut equity sleeves after portfolio equity-curve rollover, keeping gold/cash as shock absorbers", equity_brake),
        ("cap60_plus_equity_brake", "combine concentration cap with equity-curve brake to attack clustered equity tail risk", cap60_equity_brake),
        ("harder_tail_defense", "make defensive meta branch more decisive during breakdowns instead of waiting for multiple signals", harder_tail_defense),
    ]


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = d(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "total": None}
    total, annualized, max_dd, _vol, _sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "total": total}


def make_gold_blowoff_rollover_overlay(cap: float = 0.45, long_lookback: int = 90, long_threshold: float = 0.08, short_lookback: int = 20):
    original_overlay = app.apply_gold_satellite_overlay

    def patched_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        final = original_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        gold_weight = final.get("gold_cny", 0.0)
        if gold_weight > cap:
            gold_prices = prices_by_symbol["gold_cny"]
            long_momentum = app.price_momentum(gold_prices, signal_index, long_lookback)
            short_momentum = app.price_momentum(gold_prices, signal_index, short_lookback)
            # Mechanism: after a sharp gold run-up, a short-term rollover means
            # gold is no longer a clean defensive asset; cap the single-name risk
            # instead of treating it as unconditional safe haven.
            if long_momentum is not None and short_momentum is not None and long_momentum > long_threshold and short_momentum < 0:
                final["gold_cny"] = cap
        total = sum(max(weight, 0.0) for weight in final.values())
        if total > 0.85 and total > 0:
            scale = 0.85 / total
            final = {symbol: weight * scale for symbol, weight in final.items()}
        return {symbol: weight for symbol, weight in final.items() if weight > 0.0001}

    return patched_overlay


def max_drawdown_window(result: app.BacktestResult) -> dict[str, object]:
    peak_value = result.values[0]
    peak_index = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak_value:
            peak_value = value
            peak_index = i
        if peak_value > 0:
            dd = (peak_value - value) / peak_value
            if dd > worst:
                worst = dd
                worst_peak = peak_index
                worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def run_candidate(name: str, rationale: str, factory: StrategyConfigFactory, end_date: str | None) -> dict[str, object]:
    original_strategy_config = app.strategy_config
    mapping = factory()

    def patched_strategy_config(strategy_name: str) -> app.Config:
        if strategy_name in mapping:
            return mapping[strategy_name]
        return original_strategy_config(strategy_name)

    app.strategy_config = patched_strategy_config  # type: ignore[assignment]
    original_overlay = app.apply_gold_satellite_overlay
    if name == "gold_blowoff_rollover_cap45":
        app.apply_gold_satellite_overlay = make_gold_blowoff_rollover_overlay(cap=0.45, long_lookback=90, long_threshold=0.08, short_lookback=20)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date=end_date)
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
        app.strategy_config = original_strategy_config  # type: ignore[assignment]

    return {
        "name": name,
        "rationale": rationale,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "total": result.total_return,
            "sharpe": result.sharpe_ratio,
            "trades": len(result.trades),
            "final_value": result.final_value,
            "coverage_start": result.coverage_start,
            "coverage_end": result.coverage_end,
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_targets_proxy": [(t.date, t.action, t.symbol, round(t.cash_amount, 2)) for t in result.trades[-8:]],
    }


def main() -> None:
    # Keep the regression comparable with the saved App record. Remove end_date
    # only when intentionally evaluating with latest market data.
    end_date = "2026-06-19"

    # Fetch once; candidates reuse the same payload via the production parser.
    original_fetch = app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        rows = [run_candidate(name, rationale, factory, end_date) for name, rationale, factory in candidate_factories()]
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
