#!/usr/bin/env python3
"""App-only equity-curve state gate candidates.

This builds on spike 083:

1. Use the App-only 240-session offensive router.
2. Add an equity-curve state gate on the strategy itself.
3. When the state gate is defensive, scale the active target weights and keep
   the rest in idle CNY cash.

No external assets, BTC, leverage, or financing are used.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path
import importlib.util
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

ROUTER_083_PATH = ROOT / "spikes" / "083-app-only-router-search" / "app_only_router_search.py"
spec = importlib.util.spec_from_file_location("router083", ROUTER_083_PATH)
router083 = importlib.util.module_from_spec(spec)
sys.modules["router083"] = router083
assert spec.loader is not None
spec.loader.exec_module(router083)


@dataclass(frozen=True)
class StateGateConfig:
    name: str
    lookback: int
    enter_return: float
    enter_drawdown: float
    exit_return: float
    exit_drawdown: float
    low_scale: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def trailing_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    start = max(0, index - lookback + 1)
    window = values[start : index + 1]
    if not window:
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def scaled_weights(weights: dict[str, float], scale: float) -> dict[str, float]:
    factor = min(max(scale, 0.0), 1.0)
    return {symbol: weight * factor for symbol, weight in weights.items() if weight * factor > 0.0001}


def make_state_gate(base_overlay, state: StateGateConfig):
    defensive = False

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        nonlocal defensive
        weights = base_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not portfolio_values or signal_index >= len(portfolio_values):
            return weights

        recent_return = trailing_return(portfolio_values, signal_index, state.lookback)
        recent_drawdown = trailing_drawdown(portfolio_values, signal_index, state.lookback)

        if defensive:
            recovered_by_return = recent_return is not None and recent_return > state.exit_return
            recovered_by_drawdown = recent_drawdown is not None and recent_drawdown > -state.exit_drawdown
            if recovered_by_return or recovered_by_drawdown:
                defensive = False
        else:
            weak_return = recent_return is not None and recent_return < state.enter_return
            weak_drawdown = recent_drawdown is not None and recent_drawdown < -state.enter_drawdown
            if weak_return or weak_drawdown:
                defensive = True

        return scaled_weights(weights, state.low_scale) if defensive else weights

    return overlay


def run_candidate(end_date: str, state: StateGateConfig | None):
    context = router083.prepare_context(end_date)
    context = router083.PreparedRunContext(
        dates=context.dates,
        prices_by_symbol=context.prices_by_symbol,
        symbols=context.symbols,
        config=replace(context.config, rebalance_band=0.08),
        ma_by_symbol=context.ma_by_symbol,
        vol_by_symbol=context.vol_by_symbol,
        meta_traces=context.meta_traces,
    )

    original_overlay = app.apply_gold_satellite_overlay
    current_trace = router083.run_with_overlay(
        context,
        "gold_handoff",
        app._overlay_gold_handoff(app._overlay_gold_rollover_cap(original_overlay)),
    )
    breadth_trace = router083.run_with_overlay(
        context,
        "equity_breadth",
        app._overlay_equity_breadth(app._overlay_gold_rollover_cap(original_overlay)),
    )
    base_overlay = router083.router_overlay(
        current_trace,
        breadth_trace,
        lookback=240,
        metric="return",
        offensive_share=1.0,
        defensive_current_share=0.7,
        drawdown_threshold=0.08,
        scale_mode="current_vol",
        cash_gate=False,
        min_offensive_return=0.0,
        score_margin=0.0,
    )

    if state is None:
        return router083.run_with_overlay(context, "app_only_240d_router_band8", base_overlay)
    return router083.run_with_overlay(context, state.name, make_state_gate(base_overlay, state))


def main() -> None:
    end_date = "2026-06-26"
    candidates: list[tuple[str, object]] = [
        ("existing_one_way", app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=end_date)),
        ("app_only_240d_router_band8", run_candidate(end_date, None)),
        (
            "state_gate_high_sharpe",
            run_candidate(
                end_date,
                StateGateConfig(
                    name="state_gate_high_sharpe",
                    lookback=60,
                    enter_return=0.0,
                    enter_drawdown=0.025,
                    exit_return=0.04,
                    exit_drawdown=0.0,
                    low_scale=0.5,
                ),
            ),
        ),
        (
            "state_gate_balanced_return",
            run_candidate(
                end_date,
                StateGateConfig(
                    name="state_gate_balanced_return",
                    lookback=90,
                    enter_return=0.0,
                    enter_drawdown=0.025,
                    exit_return=0.02,
                    exit_drawdown=0.03,
                    low_scale=0.7,
                ),
            ),
        ),
    ]

    print("name | annualized | max_drawdown | volatility | sharpe | trades | latest trades")
    for name, result in candidates:
        latest_trades = [
            (trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2))
            for trade in result.trades[-6:]
        ]
        print(
            f"{name} | "
            f"{pct(result.annualized_return)} | "
            f"{pct(result.max_drawdown)} | "
            f"{pct(result.annualized_volatility)} | "
            f"{(result.sharpe_ratio or 0):.3f} | "
            f"{len(result.trades)} | "
            f"{latest_trades}"
        )


if __name__ == "__main__":
    main()
