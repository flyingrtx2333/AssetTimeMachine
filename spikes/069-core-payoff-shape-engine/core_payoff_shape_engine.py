#!/usr/bin/env python3
"""Core payoff-shape experiments under 1% fee.

No leverage, no shorting, no BTC. Instead of adding new assets, this spike
modifies the current App-equivalent core strategy at the target-weight layer:

- deploy unused cash when the core state is strong;
- cut target exposure when core equity curve or target quality weakens;
- keep all trading on scheduled rebalance dates with real 1% fees.

This is intended to test whether the current gold/equity engine can be reshaped
into a higher-Sharpe, still-high-return product candidate.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
END_DATE = "2026-06-23"
INITIAL = 100_000.0
FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


carry = load_module("atm_spike041_carry_for_069", ROOT / "spikes/041-carry-total-return-assets/carry_total_return_assets.py")
app = carry.app


@dataclass(frozen=True)
class ShapeSpec:
    name: str
    thesis: str
    mode: str
    strong_scale: float
    neutral_scale: float
    weak_scale: float
    strong_return: float = 0.03
    weak_return: float = -0.02
    weak_drawdown: float = -0.04
    strong_drawdown: float = -0.02
    quality_threshold: float = 0.00
    strong_quality: float = 0.03
    lookback: int = 126
    drawdown_lookback: int = 63
    no_trade_band: float = 0.025


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        factor = max_total / total
        out = {symbol: weight * factor for symbol, weight in out.items() if weight * factor > 0.0001}
    return out


def scale_to_total(weights: dict[str, float], target_total: float) -> dict[str, float]:
    current_total = total_weight(weights)
    if current_total <= 0 or target_total <= 0:
        return {}
    return normalize({symbol: weight * target_total / current_total for symbol, weight in weights.items()}, 1.0)


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index] <= 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0 or values[index] <= 0:
        return None
    window = [value for value in values[index - lookback + 1 : index + 1] if value > 0]
    if not window:
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        previous = values[cursor - 1]
        current = values[cursor]
        if previous <= 0 or current <= 0:
            return None
        returns.append(math.log(current / previous))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def target_quality(
    targets: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
) -> tuple[float, float, int, int]:
    weighted_momentum = 0.0
    momentum_weight = 0.0
    weighted_var = 0.0
    checked = 0
    healthy = 0
    for symbol, weight in targets.items():
        if weight <= 0 or symbol not in prices_by_symbol:
            continue
        prices = prices_by_symbol[symbol]
        mom60 = momentum(prices, signal_index, 60)
        mom120 = momentum(prices, signal_index, 120)
        vol60 = annual_vol(prices, signal_index, 60)
        ma120 = carry.moving_average(prices, signal_index, 120)
        if mom60 is not None and mom120 is not None:
            weighted_momentum += weight * (0.5 * mom60 + mom120)
            momentum_weight += weight
        if vol60 is not None:
            weighted_var += (weight * vol60) ** 2
        if ma120 is not None and mom60 is not None:
            checked += 1
            if prices[signal_index] >= ma120 and mom60 > -0.02:
                healthy += 1
    quality = weighted_momentum / momentum_weight if momentum_weight > 0 else 0.0
    target_vol = math.sqrt(weighted_var) if weighted_var > 0 else 0.0
    return quality, target_vol, checked, healthy


def state_scale(
    spec: ShapeSpec,
    base_targets: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    values_by_index: list[float],
    signal_index: int,
) -> tuple[float, dict[str, Any]]:
    base_total = total_weight(base_targets)
    if spec.mode == "baseline":
        return base_total, {"state": "base"}

    equity_return = momentum(values_by_index, signal_index, spec.lookback)
    equity_dd = rolling_drawdown(values_by_index, signal_index, spec.drawdown_lookback)
    quality, target_vol, checked, healthy = target_quality(base_targets, prices_by_symbol, signal_index)
    breadth_ratio = healthy / checked if checked else 0.0
    state = "neutral"

    if spec.mode == "equity_curve":
        if equity_return is not None and equity_dd is not None and equity_return >= spec.strong_return and equity_dd >= spec.strong_drawdown:
            state = "strong"
        elif (equity_return is not None and equity_return <= spec.weak_return) or (equity_dd is not None and equity_dd <= spec.weak_drawdown):
            state = "weak"
    elif spec.mode == "target_quality":
        if quality >= spec.strong_quality and breadth_ratio >= 0.6:
            state = "strong"
        elif quality <= spec.quality_threshold or (checked >= 3 and breadth_ratio <= 0.4):
            state = "weak"
    elif spec.mode == "combined":
        strong = (
            equity_return is not None
            and equity_dd is not None
            and equity_return >= spec.strong_return
            and equity_dd >= spec.strong_drawdown
            and quality >= spec.quality_threshold
            and breadth_ratio >= 0.5
        )
        weak = (
            (equity_return is not None and equity_return <= spec.weak_return)
            or (equity_dd is not None and equity_dd <= spec.weak_drawdown)
            or quality <= spec.quality_threshold
            or (checked >= 3 and breadth_ratio <= 0.4)
        )
        if strong:
            state = "strong"
        elif weak:
            state = "weak"
    elif spec.mode == "vol_efficiency":
        if target_vol > 0 and quality / max(target_vol, 0.01) >= 0.45:
            state = "strong"
        elif target_vol > 0 and quality / max(target_vol, 0.01) <= 0.10:
            state = "weak"
    else:
        raise ValueError(spec.mode)

    scale = {
        "strong": spec.strong_scale,
        "neutral": spec.neutral_scale,
        "weak": spec.weak_scale,
    }[state]
    target_total = min(max(base_total * scale, 0.0), 1.0)
    return target_total, {
        "state": state,
        "equity_return": equity_return,
        "equity_drawdown": equity_dd,
        "quality": quality,
        "target_vol": target_vol,
        "breadth": breadth_ratio,
    }


def run_shape(spec: ShapeSpec) -> dict[str, Any]:
    end_date = app.parse_date(END_DATE)
    dates, core_prices, symbols, config, meta_traces, overlay, _raw = carry.cached_core_context("index", end_date)
    tradable_symbols = [symbol for symbol in symbols if symbol not in config.signal_only_symbols]

    cash = INITIAL
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    state_counts: dict[str, int] = {}
    latest_targets: dict[str, float] = {}
    rebalance_sessions = max(config.rebalance_sessions, 1)
    band = max(config.rebalance_band, spec.no_trade_band)

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * core_prices[symbol][index] for symbol in tradable_symbols)

    def base_target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces) if config.meta_switch else {}
        return normalize(overlay(raw_weights or {}, signal_index, dates[signal_index], core_prices, values_by_index, config))

    last_rebalance_index = -10**9
    for index, current_date in enumerate(dates):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index - last_rebalance_index >= rebalance_sessions:
            signal_index = index - 1
            pre_value = portfolio_value(index)
            if signal_index >= 0:
                base_targets = base_target_weights(signal_index, index)
                target_total, state = state_scale(spec, base_targets, core_prices, values_by_index, signal_index)
                targets = scale_to_total(base_targets, target_total)
            else:
                targets = {}
                state = {"state": "warmup"}
            state_name = str(state.get("state", "unknown"))
            state_counts[state_name] = state_counts.get(state_name, 0) + 1
            latest_targets = targets
            target_symbols = set(targets)

            for symbol in sorted(held - target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = core_prices[symbol][index]
                execution_price = max(price * (1 - SLIPPAGE_RATE), 0.0)
                cash_amount = current_units * execution_price * (1 - FEE_RATE)
                cash += cash_amount
                units[symbol] = 0.0
                trades.append(app.Trade(current_date.isoformat(), "sell", symbol, execution_price, cash_amount, current_units))
            held &= target_symbols

            for symbol in sorted(target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = core_prices[symbol][index]
                current_value = current_units * price
                target_value = pre_value * targets[symbol]
                current_weight = current_value / pre_value if pre_value > 0 else 0.0
                if abs(current_weight - targets[symbol]) <= band:
                    continue
                gross_to_sell = max(current_value - target_value, 0.0)
                if gross_to_sell <= 0 or price <= 0:
                    continue
                units_to_sell = min(current_units, gross_to_sell / price)
                execution_price = max(price * (1 - SLIPPAGE_RATE), 0.0)
                cash_amount = units_to_sell * execution_price * (1 - FEE_RATE)
                cash += cash_amount
                units[symbol] = max(current_units - units_to_sell, 0.0)
                trades.append(app.Trade(current_date.isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
                if units[symbol] <= sys.float_info.min:
                    held.discard(symbol)

            total = portfolio_value(index)
            for symbol in sorted(target_symbols):
                price = core_prices[symbol][index]
                if price <= 0:
                    continue
                current_value = units.get(symbol, 0.0) * price
                target_value = total * targets[symbol]
                current_weight = current_value / total if total > 0 else 0.0
                if abs(current_weight - targets[symbol]) <= band:
                    continue
                amount = min(cash, max(target_value - current_value, 0.0))
                if amount <= 0:
                    continue
                execution_price = price * (1 + SLIPPAGE_RATE)
                bought_units = amount * (1 - FEE_RATE) / execution_price if execution_price > 0 else 0.0
                units[symbol] = units.get(symbol, 0.0) + bought_units
                cash -= amount
                held.add(symbol)
                trades.append(app.Trade(current_date.isoformat(), "buy", symbol, execution_price, amount, bought_units))
            last_rebalance_index = index

        value = portfolio_value(index)
        values.append(value)
        values_by_index[index] = value

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": spec.__dict__,
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
            "trades": len(trades),
        },
        "slices": {
            "post_2020": slice_metrics(dates, values, "2020-01-01"),
            "last_10y": slice_metrics(dates, values, "2016-06-23"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "state_counts": state_counts,
        "latest_targets": latest_targets,
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-12:]],
    }


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(dates) if day >= start_date), None)
    if index is None or index >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[index:], values[index:])
    return {"annualized": annualized, "max_drawdown": max_dd, "annual_volatility": annual_vol, "sharpe": sharpe, "total": total}


def specs() -> list[ShapeSpec]:
    out = [ShapeSpec("baseline_target_replay", "Target-level replay of current core.", "baseline", 1.0, 1.0, 1.0)]
    for mode in ["equity_curve", "target_quality", "combined", "vol_efficiency"]:
        for strong_scale in [1.10, 1.18]:
            for weak_scale in [0.45, 0.60, 0.75]:
                out.append(
                    ShapeSpec(
                        name=f"{mode}_strong{int(strong_scale*100)}_weak{int(weak_scale*100)}",
                        thesis="Scale current core targets based on state, max total exposure 100%.",
                        mode=mode,
                        strong_scale=strong_scale,
                        neutral_scale=1.0,
                        weak_scale=weak_scale,
                    )
                )
        out.append(
            ShapeSpec(
                name=f"{mode}_always_full_weak60",
                thesis="Use unused cash aggressively except in weak states.",
                mode=mode,
                strong_scale=1.18,
                neutral_scale=1.18,
                weak_scale=0.60,
            )
        )
    return out


def main() -> None:
    rows = [run_shape(spec) for spec in specs()]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "fee_rate": FEE_RATE,
                "slippage_rate": SLIPPAGE_RATE,
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sh | last10 ann/sh | post2024 ann/sh | trades | states")
    for row in rows[:35]:
        full = row["full"]
        slices = row["slices"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{full['trades']} | {row['state_counts']}"
        )


if __name__ == "__main__":
    main()
