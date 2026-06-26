#!/usr/bin/env python3
"""Drawdown-repair reentry engine.

This spike tests a return source that is intentionally different from the 047
trend sleeve: buy only after a meaningful drawdown has started to repair.

Two forms are tested:
- overlay: keep the verified 047 dynamic sleeve and use only idle budget for
  repair candidates.
- standalone: trade only the repair engine.

No leverage, no shorting, no BTC. Fees, slippage, and cash yield are included.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SPIKE047 = ROOT / "spikes" / "047-dynamic-sleeve-selector"
sys.path.insert(0, str(SPIKE047))

import dynamic_sleeve_selector as dyn  # noqa: E402
import target_replay_search as t47  # noqa: E402
import target_weight_replay as replay  # noqa: E402

app = dyn.app
s35 = replay.s35
s30 = replay.s30

BASE_SELECTOR = dyn.SelectorSpec(
    name="target_hysteresis_selector_lb315_h95_l25_m125_d35",
    thesis="047 verified dynamic sleeve selector.",
    mode="hysteresis_selector",
    lookback=315,
    satellite_high=0.95,
    satellite_low=0.25,
    ret_margin=0.0125,
    dd_limit=0.035,
    portfolio_dd_limit=0.030,
)

EQUITY_SYMBOLS = {
    "nasdaq",
    "sp500",
    "dowjones",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
}


@dataclass(frozen=True)
class RepairSpec:
    name: str
    mode: str
    drawdown_lookback: int
    drawdown_threshold: float
    rebound_lookback: int
    rebound_threshold: float
    confirmation_ma: int
    momentum_lookback: int
    top_count: int
    overlay_cap: float
    per_asset_cap: float
    require_breadth: bool
    exit_weakness: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return replay.normalize(weights, max_total)


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if idx is None or idx >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[idx:], values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(dates: list[date], values: list[float]) -> dict[str, Any]:
    peak = values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for index, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = index
        drawdown = (peak - value) / peak if peak > 0 else 0.0
        if drawdown > worst:
            worst = drawdown
            worst_peak = peak_i
            worst_trough = index
    return {"peak_date": dates[worst_peak].isoformat(), "trough_date": dates[worst_trough].isoformat(), "max_drawdown": worst}


def build_indicators(prices_by_symbol: dict[str, list[float]]) -> dict[str, dict[int, list[float | None]]]:
    periods = [20, 40, 60, 80, 120]
    return {
        symbol: {period: app.moving_average(prices, period) for period in periods}
        for symbol, prices in prices_by_symbol.items()
    }


def safe_momentum(values: list[float], index: int, lookback: int) -> float | None:
    value = app.price_momentum(values, index, lookback)
    return value if value is not None and math.isfinite(value) else None


def rolling_low_rebound(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = [item for item in values[index - lookback + 1:index + 1] if item > 0]
    if not window:
        return None
    low = min(window)
    return values[index] / low - 1 if low > 0 else None


def rolling_high_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    return app.rolling_drawdown_from_high(values, index, lookback)


def equity_breadth_ok(prices_by_symbol: dict[str, list[float]], indicators: dict[str, dict[int, list[float | None]]], index: int) -> bool:
    checked = 0
    healthy = 0
    for symbol in ["nasdaq", "sp500", "csi300", "shanghai_composite"]:
        if symbol not in prices_by_symbol:
            continue
        prices = prices_by_symbol[symbol]
        ma = indicators[symbol][60][index]
        mom = safe_momentum(prices, index, 20)
        if ma is None or mom is None:
            continue
        checked += 1
        if prices[index] > ma and mom > -0.02:
            healthy += 1
    return checked >= 3 and healthy >= 2


def repair_score(
    symbol: str,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
    spec: RepairSpec,
) -> float | None:
    prices = prices_by_symbol[symbol]
    if index <= 0 or index >= len(prices) or prices[index] <= 0:
        return None
    drawdown = rolling_high_drawdown(prices, index, spec.drawdown_lookback)
    rebound = rolling_low_rebound(prices, index, spec.rebound_lookback)
    momentum = safe_momentum(prices, index, spec.momentum_lookback)
    fast_momentum = safe_momentum(prices, index, 10)
    ma = indicators[symbol].get(spec.confirmation_ma, indicators[symbol][60])[index]
    ma20 = indicators[symbol][20][index]
    ma120 = indicators[symbol][120][index]
    if None in (drawdown, rebound, momentum, fast_momentum, ma, ma20):
        return None
    assert drawdown is not None and rebound is not None and momentum is not None and fast_momentum is not None
    assert ma is not None and ma20 is not None
    if drawdown > -spec.drawdown_threshold:
        return None
    if rebound < spec.rebound_threshold:
        return None
    if prices[index] < ma or prices[index] < ma20:
        return None
    if momentum < 0 or fast_momentum < 0:
        return None
    if symbol in EQUITY_SYMBOLS and spec.require_breadth and not equity_breadth_ok(prices_by_symbol, indicators, index):
        return None
    if symbol == "gold_cny" and ma120 is not None and prices[index] < ma120 * 0.96:
        return None
    volatility = local_volatility(prices, index, 60) or 9.0
    return max(0.0, rebound * 1.2 + momentum * 0.8 + fast_momentum * 0.5 + max(drawdown, -0.60) * 0.20) / max(volatility, 0.03)


def local_volatility(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        previous = values[cursor - 1]
        current = values[cursor]
        if previous > 0 and current > 0:
            returns.append(math.log(current / previous))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def repair_targets(
    *,
    spec: RepairSpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    tradable_symbols: list[str],
    signal_index: int,
    budget: float,
    active_repair_symbols: set[str],
) -> dict[str, float]:
    if signal_index < 0 or budget <= 0:
        return {}
    scored: list[tuple[float, str]] = []
    for symbol in tradable_symbols:
        score = repair_score(symbol, prices_by_symbol, indicators, signal_index, spec)
        if score is None:
            if spec.exit_weakness and symbol in active_repair_symbols:
                continue
            if not spec.exit_weakness and symbol in active_repair_symbols:
                score = 0.001
            else:
                continue
        if score > 0:
            scored.append((score, symbol))
    scored.sort(reverse=True)
    selected = scored[: max(spec.top_count, 1)]
    score_total = sum(score for score, _symbol in selected)
    if score_total <= 0:
        return {}
    out: dict[str, float] = {}
    for score, symbol in selected:
        out[symbol] = min(spec.per_asset_cap, budget * score / score_total)
    return normalize(out, budget)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def rebalance_portfolio(
    *,
    index: int,
    dates: list[date],
    prices_by_symbol: dict[str, list[float]],
    tradable_symbols: list[str],
    targets: dict[str, float],
    cash_box: dict[str, float],
    units: dict[str, float],
    held: set[str],
    trades: list[app.Trade],
) -> dict[str, float]:
    cash = cash_box["cash"]
    fee_rate = 0.001
    slippage_rate = 0.0005
    targets = normalize(targets)
    target_symbols = set(targets)

    def portfolio_value() -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    pre_value = portfolio_value()
    for symbol in sorted(held - target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        execution_price = max(prices_by_symbol[symbol][index] * (1 - slippage_rate), 0.0)
        cash_amount = current_units * execution_price * (1 - fee_rate)
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
        execution_price = max(price * (1 - slippage_rate), 0.0)
        cash_amount = units_to_sell * execution_price * (1 - fee_rate)
        cash += cash_amount
        units[symbol] = max(current_units - units_to_sell, 0.0)
        trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
        if units[symbol] <= sys.float_info.min:
            held.discard(symbol)

    total_value = portfolio_value()
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
        bought_units = amount * (1 - fee_rate) / execution_price if execution_price > 0 else 0.0
        units[symbol] = units.get(symbol, 0.0) + bought_units
        cash -= amount
        held.add(symbol)
        trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))

    cash_box["cash"] = cash
    return targets


def simulate(data: dict[str, Any], spec: RepairSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    env = data["env"]
    prices_by_symbol = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    indicators = build_indicators(prices_by_symbol)

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    repair_hits = 0
    active_targets: dict[str, float] = {}
    base_targets: dict[str, float] = {}
    repair_overlay: dict[str, float] = {}
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        signal_index = index - 1
        if spec.mode == "overlay" and index in targets_by_index:
            if signal_index >= 0:
                new_weight = dyn.choose_weight(BASE_SELECTOR, satellite_values, defensive_values, values, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if index == 0 or index % 21 == 0:
            budget = spec.overlay_cap if spec.mode == "standalone" else min(spec.overlay_cap, max(0.0, 1.0 - total_weight(base_targets)))
            active_repair_symbols = set(repair_overlay)
            repair_overlay = repair_targets(
                spec=spec,
                prices_by_symbol=prices_by_symbol,
                indicators=indicators,
                tradable_symbols=tradable_symbols,
                signal_index=signal_index,
                budget=budget,
                active_repair_symbols=active_repair_symbols,
            )
            if repair_overlay:
                repair_hits += 1
            needs_rebalance = True

        if needs_rebalance:
            targets = dict(base_targets) if spec.mode == "overlay" else {}
            for symbol, weight in repair_overlay.items():
                targets[symbol] = targets.get(symbol, 0.0) + weight
            targets = normalize(targets)
            max_target_sum = max(max_target_sum, total_weight(targets))
            if targets_changed(targets, active_targets):
                active_targets = rebalance_portfolio(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    tradable_symbols=tradable_symbols,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                )

        values.append(portfolio_value(index))

    extra = {
        "mode": spec.mode,
        "switches": switches,
        "repair_hits": repair_hits,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else None,
        "latest_selector_weight": selector_weights[-1] if selector_weights else None,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return values, extra, trades


def row_for(data: dict[str, Any], spec: RepairSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
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
            "post_2022": slice_metrics(dates, values, "2022-01-01"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def specs() -> list[RepairSpec]:
    out: list[RepairSpec] = []
    for mode in ["overlay", "standalone"]:
        for drawdown_lookback, drawdown_threshold in [(120, 0.12), (180, 0.16), (240, 0.20)]:
            for rebound_lookback, rebound_threshold in [(20, 0.035), (40, 0.055)]:
                for confirmation_ma in [20, 40]:
                    for momentum_lookback in [20]:
                        for top_count in [1, 2]:
                            for require_breadth in [False, True]:
                                if mode == "overlay":
                                    caps = [(0.25, 0.12), (0.35, 0.15)]
                                else:
                                    caps = [(0.75, 0.45), (1.0, 0.60)]
                                for overlay_cap, per_asset_cap in caps:
                                    out.append(
                                        RepairSpec(
                                            name=(
                                                f"{mode}_dd{drawdown_lookback}_{int(drawdown_threshold*100)}_"
                                                f"rb{rebound_lookback}_{int(rebound_threshold*1000)}_"
                                                f"ma{confirmation_ma}_mom{momentum_lookback}_top{top_count}_"
                                                f"cap{int(overlay_cap*100)}_per{int(per_asset_cap*100)}_"
                                                f"{'breadth' if require_breadth else 'open'}"
                                            ),
                                            mode=mode,
                                            drawdown_lookback=drawdown_lookback,
                                            drawdown_threshold=drawdown_threshold,
                                            rebound_lookback=rebound_lookback,
                                            rebound_threshold=rebound_threshold,
                                            confirmation_ma=confirmation_ma,
                                            momentum_lookback=momentum_lookback,
                                            top_count=top_count,
                                            overlay_cap=overlay_cap,
                                            per_asset_cap=per_asset_cap,
                                            require_breadth=require_breadth,
                                            exit_weakness=True,
                                        )
                                    )
    return out


def baseline_row(data: dict[str, Any]) -> dict[str, Any]:
    values, extra, trades = t47.simulate(data, BASE_SELECTOR)
    spec = RepairSpec(
        name="baseline_047_dynamic_sleeve",
        mode="overlay",
        drawdown_lookback=0,
        drawdown_threshold=0,
        rebound_lookback=0,
        rebound_threshold=0,
        confirmation_ma=20,
        momentum_lookback=20,
        top_count=0,
        overlay_cap=0,
        per_asset_cap=0,
        require_breadth=False,
        exit_weakness=True,
    )
    return row_for(data, spec, values, extra, trades)


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        rows = [baseline_row(data)]
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Drawdown-repair reentry search. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:60]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{row['extra']} | {full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
