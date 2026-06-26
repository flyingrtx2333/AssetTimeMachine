#!/usr/bin/env python3
"""Low-turnover daily-defense probes under 1% fee.

The previous champion was found with much lower trading cost. This spike keeps
the same no-leverage/no-BTC strategy stack, then tests structure changes that
make sense when the App default fee is 1%:

- trade with a rebalance band so tiny target drift is ignored;
- allow daily sell-only risk exits between scheduled rebalance dates;
- re-enter only at the next scheduled rebalance to avoid churn.
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
S063_PATH = ROOT / "spikes" / "063-risk-efficiency-governor" / "risk_efficiency_governor.py"

FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


s063 = load_module("risk_efficiency_governor_063_for_064", S063_PATH)
s062 = s063.s062
s061 = s063.s061
s060 = s063.s060
app = s063.app
repair = s063.repair
g59 = s063.g59
t47 = s063.t47
replay = s063.replay
s35 = s063.s35
s30 = s063.s30
phase = s063.phase
dyn = s060.dyn

EQUITY_SYMBOLS = set(s060.EQUITY_SYMBOLS)
GOLD = s062.GOLD
USD_CASH = s061.USD_CASH


@dataclass(frozen=True)
class DailyDefenseSpec:
    name: str
    thesis: str
    daily_equity_airbag: bool = False
    daily_portfolio_airbag: bool = False
    daily_gold_lock: bool = False
    rebalance_band: float = 0.025
    use_repair_overlay: bool = True
    use_global_overlay: bool = True
    overlay_refresh_sessions: int = 21
    fixed_selector_weight: float | None = None
    min_target_weight: float = 0.0
    quantize_step: float = 0.0
    top_target_count: int | None = None
    preserve_same_group: bool = False


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def target_total(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0 or values[index] <= 0:
        return None
    return values[index] / values[index - lookback] - 1.0


def target_exposure(targets: dict[str, float], symbols: set[str]) -> float:
    return sum(max(targets.get(symbol, 0.0), 0.0) for symbol in symbols)


def coarse_targets(targets: dict[str, float], spec: DailyDefenseSpec) -> dict[str, float]:
    out = dict(targets)
    if spec.top_target_count is not None and spec.top_target_count > 0:
        protected = {USD_CASH}
        ranked = sorted(
            [(weight, symbol) for symbol, weight in out.items() if symbol not in protected],
            reverse=True,
        )
        keep = {symbol for _weight, symbol in ranked[:spec.top_target_count]} | {symbol for symbol in protected if symbol in out}
        out = {symbol: weight for symbol, weight in out.items() if symbol in keep}
    if spec.min_target_weight > 0:
        out = {
            symbol: weight
            for symbol, weight in out.items()
            if weight >= spec.min_target_weight or symbol == USD_CASH
        }
    if spec.quantize_step > 0:
        step = spec.quantize_step
        quantized: dict[str, float] = {}
        for symbol, weight in out.items():
            bucket = round(weight / step) * step
            if bucket >= max(step * 0.5, 0.0001):
                quantized[symbol] = bucket
        out = quantized
    return repair.normalize(out)


def symbol_group(symbol: str) -> str:
    if symbol in {"nasdaq", "sp500", "dowjones"}:
        return "us_equity"
    if symbol in {"csi300", "shanghai_composite", "shenzhen_component", "chinext", "hsi"}:
        return "china_hk_equity"
    if symbol == "nikkei":
        return "japan_equity"
    if symbol == GOLD:
        return "gold"
    if symbol == USD_CASH:
        return "cash"
    return symbol


def trend_holding_ok(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    if index < 120 or symbol not in prices_by_symbol:
        return False
    values = prices_by_symbol[symbol]
    if index >= len(values) or values[index] <= 0:
        return False
    ma = sum(values[index - 119:index + 1]) / 120 if all(value > 0 for value in values[index - 119:index + 1]) else None
    mom60 = momentum(values, index, 60)
    return ma is not None and values[index] >= ma and mom60 is not None and mom60 > -0.03


def preserve_group_targets(
    targets: dict[str, float],
    active_targets: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
) -> dict[str, float]:
    if signal_index < 0 or not active_targets:
        return repair.normalize(targets)
    out: dict[str, float] = {}
    used_old: set[str] = set()
    for symbol, weight in sorted(targets.items(), key=lambda item: item[1], reverse=True):
        group = symbol_group(symbol)
        replacement = symbol
        if symbol not in active_targets and group not in {"gold", "cash"}:
            candidates = [
                old_symbol
                for old_symbol, old_weight in active_targets.items()
                if old_weight > 0.0001
                and old_symbol not in used_old
                and symbol_group(old_symbol) == group
                and trend_holding_ok(prices_by_symbol, old_symbol, signal_index)
            ]
            if candidates:
                replacement = max(candidates, key=lambda item: active_targets.get(item, 0.0))
        out[replacement] = out.get(replacement, 0.0) + weight
        used_old.add(replacement)
    return repair.normalize(out)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def portfolio_drawdown(values: list[float], lookback: int) -> float:
    if len(values) < 2:
        return 0.0
    window = values[-min(len(values), lookback):]
    peak = max(window)
    return values[-1] / peak - 1.0 if peak > 0 else 0.0


def equity_shock(
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
) -> bool:
    sp20 = momentum(prices_by_symbol["sp500"], index, 20)
    sp60 = momentum(prices_by_symbol["sp500"], index, 60)
    nd20 = momentum(prices_by_symbol["nasdaq"], index, 20)
    checked, healthy = s060.global_breadth(prices_by_symbol, indicators, index)
    broad_break = checked >= 5 and healthy <= 2
    us_shock = sp20 is not None and sp60 is not None and sp20 < -0.055 and sp60 < 0
    nasdaq_shock = nd20 is not None and nd20 < -0.075
    return broad_break or us_shock or nasdaq_shock


def daily_gold_exit(
    prices_by_symbol: dict[str, list[float]],
    index: int,
    gold_spec: Any,
    guard_state: dict[str, Any],
) -> bool:
    gold = prices_by_symbol[GOLD]
    if s062.gold_overheated(gold, index, gold_spec):
        guard_state["daily_gold_armed"] = True
    if not guard_state.get("daily_gold_armed", False):
        return False
    if s062.gold_cracked(gold, index, gold_spec):
        guard_state["daily_gold_armed"] = False
        guard_state["daily_gold_events"] = int(guard_state.get("daily_gold_events", 0)) + 1
        return True
    return False


def fee_aware_rebalance(
    *,
    index: int,
    dates: list[date],
    prices_by_symbol: dict[str, list[float]],
    tradable_symbols: list[str],
    targets: dict[str, float],
    cash_box: dict[str, float],
    units: dict[str, float],
    held: set[str],
    trades: list[Any],
    band: float,
    buy: bool,
) -> dict[str, float]:
    cash = cash_box["cash"]
    targets = repair.normalize(targets)
    target_symbols = set(targets)

    def portfolio_value() -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    pre_value = portfolio_value()
    for symbol in sorted(held - target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        execution_price = max(prices_by_symbol[symbol][index] * (1 - SLIPPAGE_RATE), 0.0)
        cash_amount = current_units * execution_price * (1 - FEE_RATE)
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
        threshold = target_value * (1 + max(band, 0.0))
        gross_to_sell = max(current_value - target_value, 0.0) if current_value > threshold else 0.0
        if gross_to_sell <= 0:
            continue
        units_to_sell = min(current_units, gross_to_sell / price)
        execution_price = max(price * (1 - SLIPPAGE_RATE), 0.0)
        cash_amount = units_to_sell * execution_price * (1 - FEE_RATE)
        cash += cash_amount
        units[symbol] = max(current_units - units_to_sell, 0.0)
        trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
        if units[symbol] <= sys.float_info.min:
            held.discard(symbol)

    if buy:
        total_value = portfolio_value()
        for symbol in sorted(target_symbols):
            price = prices_by_symbol[symbol][index]
            if price <= 0:
                continue
            current_value = units.get(symbol, 0.0) * price
            target_value = total_value * targets[symbol]
            threshold = target_value * (1 - max(band, 0.0))
            amount = min(cash, max(target_value - current_value, 0.0)) if current_value < threshold else 0.0
            if amount <= 0:
                continue
            execution_price = price * (1 + SLIPPAGE_RATE)
            bought_units = amount * (1 - FEE_RATE) / execution_price if execution_price > 0 else 0.0
            units[symbol] = units.get(symbol, 0.0) + bought_units
            cash -= amount
            held.add(symbol)
            trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))

    cash_box["cash"] = cash
    return targets


def governor_gold_best() -> Any:
    return s063.GovernorSpec(
        name="governor_weak_momentum_vl20_tr130_tv80_ml40_mt15",
        gold_spec=s063.gold_best(),
        mode="weak_momentum",
        vol_lookback=20,
        trigger_vol=0.130,
        target_vol=0.080,
        momentum_lookback=40,
        momentum_threshold=0.015,
    )


def add_champion_overlays(
    targets: dict[str, float],
    spec: Any,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
    state: dict[str, Any],
) -> dict[str, float]:
    contagion_state = state.setdefault("contagion", {"until": -1, "events": 0, "active_days": 0, "released": 0})
    targets = s060.apply_contagion_control(
        targets,
        spec.gold_spec.currency_spec.contagion_spec,
        prices_by_symbol,
        indicators,
        signal_index,
        contagion_state,
    )
    targets = s062.apply_gold_lock(targets, spec.gold_spec, prices_by_symbol, signal_index, state)
    targets = s063.apply_governor(targets, spec, prices_by_symbol, indicators, signal_index, state)
    return s061.add_currency_cash(
        targets,
        spec.gold_spec.currency_spec,
        prices_by_symbol,
        indicators,
        signal_index,
        contagion_state,
    )


def run_spec(data: dict[str, Any], defense: DailyDefenseSpec) -> dict[str, Any]:
    prices_by_symbol: dict[str, list[float]] = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    indicators = repair.build_indicators(prices_by_symbol)
    repair_spec = g59.make_repair_spec(s060.BASE_SPEC)
    phase_spec = g59.make_phase_spec(True, s060.BASE_SPEC.repair_top_count)
    governor_spec = governor_gold_best()

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[Any] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    repair_hits = 0
    global_hits = 0
    phase_lock_events = 0
    phase_lock_days = 0
    daily_equity_exits = 0
    daily_portfolio_exits = 0
    daily_gold_exits = 0
    locked: dict[str, int] = {}
    state: dict[str, Any] = {}
    repair_overlay: dict[str, float] = {}
    global_overlay: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    base_targets: dict[str, float] = {}
    target_log: list[dict[str, Any]] = []
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
        previous_lock_count = len(locked)

        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = (
                    defense.fixed_selector_weight
                    if defense.fixed_selector_weight is not None
                    else dyn.choose_weight(
                        repair.BASE_SELECTOR,
                        satellite_values,
                        defensive_values,
                        values,
                        signal_index,
                        selector_weight,
                    )
                )
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
                phase.update_locks(
                    prices_by_symbol=prices_by_symbol,
                    indicators=indicators,
                    tradable_symbols=tradable_symbols,
                    signal_index=signal_index,
                    spec=phase_spec,
                    locked=locked,
                )
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if index == 0 or index % max(defense.overlay_refresh_sessions, 1) == 0:
            if defense.use_repair_overlay:
                base_budget = min(repair_spec.overlay_cap, max(0.0, 1.0 - target_total(base_targets)))
                active_repair_symbols = set(repair_overlay)
                repair_overlay = repair.repair_targets(
                    spec=repair_spec,
                    prices_by_symbol=prices_by_symbol,
                    indicators=indicators,
                    tradable_symbols=[symbol for symbol in tradable_symbols if symbol not in set(s060.BASE_SPEC.global_symbols)],
                    signal_index=signal_index,
                    budget=base_budget,
                    active_repair_symbols=active_repair_symbols,
                )
                if repair_overlay:
                    repair_hits += 1
            else:
                repair_overlay = {}
            if defense.use_global_overlay:
                remaining_budget = min(
                    s060.BASE_SPEC.global_overlay_cap,
                    max(0.0, 1.0 - target_total(base_targets) - target_total(repair_overlay)),
                )
                global_overlay = g59.global_targets(s060.BASE_SPEC, prices_by_symbol, indicators, signal_index, remaining_budget)
                if global_overlay:
                    global_hits += 1
            else:
                global_overlay = {}
            needs_rebalance = True

        if len(locked) > previous_lock_count:
            phase_lock_events += len(locked) - previous_lock_count
        if locked:
            phase_lock_days += 1

        if needs_rebalance:
            targets = dict(base_targets)
            for overlay in [repair_overlay, global_overlay]:
                for symbol, weight in overlay.items():
                    targets[symbol] = targets.get(symbol, 0.0) + weight
            targets = repair.normalize(targets)
            targets = phase.apply_phase_locks(targets, locked, phase_spec)
            targets = add_champion_overlays(targets, governor_spec, prices_by_symbol, indicators, signal_index, state)
            if defense.preserve_same_group:
                targets = preserve_group_targets(targets, active_targets, prices_by_symbol, signal_index)
            targets = coarse_targets(targets, defense)
            max_target_sum = max(max_target_sum, target_total(targets))
            if app.parse_date("2015-04-01") <= current_date <= app.parse_date("2015-10-31"):
                contagion_state = state.get("contagion", {})
                target_log.append(
                    {
                        "date": current_date.isoformat(),
                        "signal_date": dates[signal_index].isoformat() if signal_index >= 0 else None,
                        "targets": {symbol: round(weight, 4) for symbol, weight in sorted(targets.items()) if weight > 0.0001},
                        "selector_weight": selector_weight,
                        "contagion_until": contagion_state.get("until", -1),
                    }
                )
            if targets_changed(targets, active_targets):
                active_targets = fee_aware_rebalance(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    tradable_symbols=tradable_symbols,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                    band=defense.rebalance_band,
                    buy=True,
                )
        elif active_targets and signal_index >= 0:
            reduced_targets = dict(active_targets)
            triggered = False
            if (
                defense.daily_equity_airbag
                and target_exposure(active_targets, EQUITY_SYMBOLS) > 0.20
                and equity_shock(prices_by_symbol, indicators, signal_index)
            ):
                for symbol in EQUITY_SYMBOLS:
                    reduced_targets.pop(symbol, None)
                daily_equity_exits += 1
                triggered = True
            if (
                defense.daily_portfolio_airbag
                and target_exposure(active_targets, EQUITY_SYMBOLS) > 0.20
                and portfolio_drawdown(values, 40) < -0.035
                and equity_shock(prices_by_symbol, indicators, signal_index)
            ):
                for symbol in EQUITY_SYMBOLS:
                    reduced_targets[symbol] = reduced_targets.get(symbol, 0.0) * 0.25
                daily_portfolio_exits += 1
                triggered = True
            if (
                defense.daily_gold_lock
                and active_targets.get(GOLD, 0.0) > 0.10
                and daily_gold_exit(prices_by_symbol, signal_index, governor_spec.gold_spec, state)
            ):
                reduced_targets[GOLD] = active_targets.get(GOLD, 0.0) * governor_spec.gold_spec.scale
                daily_gold_exits += 1
                triggered = True
            if triggered:
                active_targets = repair.normalize(reduced_targets)
                fee_aware_rebalance(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    tradable_symbols=tradable_symbols,
                    targets=active_targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                    band=0.0,
                    buy=False,
                )

        values.append(portfolio_value(index))

    contagion_state = state.get("contagion", {})
    extra = {
        "switches": switches,
        "repair_hits": repair_hits,
        "global_hits": global_hits,
        "phase_lock_events": phase_lock_events,
        "phase_lock_days": phase_lock_days,
        "contagion_events": contagion_state.get("events", 0),
        "contagion_active_days": contagion_state.get("active_days", 0),
        "contagion_releases": contagion_state.get("released", 0),
        "gold_lock_events": state.get("gold_lock_events", 0),
        "governor_events": state.get("governor_events", 0),
        "daily_equity_exits": daily_equity_exits,
        "daily_portfolio_exits": daily_portfolio_exits,
        "daily_gold_exits": daily_gold_exits,
        "daily_gold_guard_events": state.get("daily_gold_events", 0),
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else None,
        "latest_selector_weight": selector_weights[-1] if selector_weights else None,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return row_for(data, defense, values, extra, trades, target_log)


def row_for(
    data: dict[str, Any],
    spec: DailyDefenseSpec,
    values: list[float],
    extra: dict[str, Any],
    trades: list[Any],
    target_log: list[dict[str, Any]],
) -> dict[str, Any]:
    dates: list[date] = data["dates"]
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
            "post_2020": repair.slice_metrics(dates, values, "2020-01-01"),
            "last_10y": repair.slice_metrics(dates, values, "2016-06-23"),
            "post_2022": repair.slice_metrics(dates, values, "2022-01-01"),
            "post_2024": repair.slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": repair.max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "target_log_2015": target_log[:20],
        "extra": extra,
    }


def specs() -> list[DailyDefenseSpec]:
    return [
        DailyDefenseSpec(
            name="baseline_063_1pct_no_band",
            thesis="063 champion replayed with 1% fee and no rebalance band.",
            rebalance_band=0.0,
        ),
        DailyDefenseSpec(
            name="baseline_063_1pct_band",
            thesis="063 champion replayed with 1% fee and a 2.5% rebalance band.",
        ),
        DailyDefenseSpec(
            name="slow_overlay_refresh_63",
            thesis="Keep 063 logic but refresh repair/global overlays quarterly instead of monthly to reduce high-cost turnover.",
            overlay_refresh_sessions=63,
        ),
        DailyDefenseSpec(
            name="base_targets_no_repair_global",
            thesis="Keep dynamic sleeve, phase, contagion, gold lock, currency cash, and governor, but remove monthly repair/global overlays.",
            use_repair_overlay=False,
            use_global_overlay=False,
        ),
        DailyDefenseSpec(
            name="no_global_overlay_keep_repair",
            thesis="Remove only the global repair overlay while keeping base repair; checks whether extra markets pay for their turnover.",
            use_global_overlay=False,
        ),
        DailyDefenseSpec(
            name="no_repair_keep_global",
            thesis="Remove base repair while keeping global overlay; isolates the repair sleeve's net contribution under 1% fee.",
            use_repair_overlay=False,
        ),
        DailyDefenseSpec(
            name="fixed_selector_95_low_churn",
            thesis="Avoid sleeve selector churn by staying mostly in the satellite engine while keeping 063 overlays.",
            fixed_selector_weight=0.95,
        ),
        DailyDefenseSpec(
            name="fixed_selector_50_balanced",
            thesis="Avoid selector churn with a stable 50/50 satellite/defensive blend.",
            fixed_selector_weight=0.50,
        ),
        DailyDefenseSpec(
            name="coarse_drop_lt5_quant5",
            thesis="Ignore sub-5% sleeves and trade targets in 5% buckets to reduce high-cost micro-rotation.",
            min_target_weight=0.05,
            quantize_step=0.05,
        ),
        DailyDefenseSpec(
            name="coarse_top4_quant5",
            thesis="Keep only the four largest target sleeves and quantize to 5% buckets.",
            top_target_count=4,
            quantize_step=0.05,
        ),
        DailyDefenseSpec(
            name="coarse_top3_quant10",
            thesis="Keep only the three largest target sleeves and quantize to 10% buckets.",
            top_target_count=3,
            quantize_step=0.10,
        ),
        DailyDefenseSpec(
            name="coarse_top2_quant10",
            thesis="Force the 063 stack into a top-two core allocation with 10% buckets.",
            top_target_count=2,
            quantize_step=0.10,
        ),
        DailyDefenseSpec(
            name="sticky_same_group",
            thesis="Avoid full switches inside the same equity region when the existing holding remains trend-healthy.",
            preserve_same_group=True,
        ),
        DailyDefenseSpec(
            name="sticky_same_group_drop_lt5",
            thesis="Same-group holding preservation plus dropping sub-5% sleeves.",
            preserve_same_group=True,
            min_target_weight=0.05,
        ),
        DailyDefenseSpec(
            name="sticky_same_group_quant5",
            thesis="Same-group holding preservation plus 5% target buckets.",
            preserve_same_group=True,
            quantize_step=0.05,
        ),
        DailyDefenseSpec(
            name="daily_equity_airbag_sell_only",
            thesis="Sell equity exposure between rebalances when broad equity shock appears; re-enter only on scheduled rebalance.",
            daily_equity_airbag=True,
        ),
        DailyDefenseSpec(
            name="daily_gold_crack_sell_only",
            thesis="Arm after gold overheats, then sell down gold immediately if it cracks before the next scheduled rebalance.",
            daily_gold_lock=True,
        ),
        DailyDefenseSpec(
            name="daily_portfolio_airbag_sell_only",
            thesis="Sell risk only when the strategy curve itself is already drawing down and broad equity shock confirms.",
            daily_portfolio_airbag=True,
        ),
        DailyDefenseSpec(
            name="combined_daily_sell_only_airbags",
            thesis="Combine equity shock, portfolio airbag, and daily gold crack protection with scheduled re-entry.",
            daily_equity_airbag=True,
            daily_portfolio_airbag=True,
            daily_gold_lock=True,
        ),
    ]


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    patched_apps = [
        app, replay.app, s35.app, s30.app,
        repair.app, repair.replay.app, repair.s35.app, repair.s30.app,
        phase.app, phase.replay.app, phase.s35.app, phase.s30.app,
        g59.app, g59.replay.app, g59.s35.app, g59.s30.app, s060.app,
    ]
    for module_app in patched_apps:
        module_app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data = g59.add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        data = s061.add_usd_cash_series(data)
        rows = [run_spec(data, spec) for spec in specs()]
    finally:
        for module_app in patched_apps:
            module_app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "063 stack replayed with 1% final execution fee, 0.05% slippage, no leverage, no shorting, no BTC. Daily guards are sell-only and re-enter only at scheduled rebalance.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | daily exits | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        extra: dict[str, Any] = row["extra"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{extra.get('daily_equity_exits', 0)}/{extra.get('daily_portfolio_exits', 0)}/{extra.get('daily_gold_exits', 0)} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
