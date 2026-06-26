#!/usr/bin/env python3
"""Global repair opportunity sleeve on top of the 053 repair engine.

This tests a genuinely different return source: add Hang Seng, Nikkei, and
optionally WTI only after a drawdown has started to repair. These assets are not
ranked into the main engine and can only use idle risk budget.

No leverage, no shorting, no BTC. Fees, slippage, and cash yield are included.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import bisect
import importlib.util
import json
import math
from pathlib import Path
import sys
import urllib.parse
import urllib.request
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REPAIR_PATH = ROOT / "spikes" / "053-drawdown-repair-reentry" / "drawdown_repair_reentry.py"
PHASE_PATH = ROOT / "spikes" / "055-phase-lock-risk-budget" / "phase_lock_risk_budget.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


repair = load_module("drawdown_repair_reentry_053", REPAIR_PATH)
phase = load_module("phase_lock_risk_budget_055", PHASE_PATH)

app = repair.app
dyn = repair.dyn
replay = repair.replay
t47 = repair.t47
s35 = repair.s35
s30 = repair.s30

API_URL = app.API_URL
EXTRA_ALIASES = {
    "hang_seng": "hsi",
    "hsi": "hsi",
    "nikkei225": "nikkei",
    "nikkei": "nikkei",
    "dow_jones": "dowjones",
    "oil_wti_cny": "oil_wti_cny",
}
GLOBAL_EQUITIES = {"hsi", "nikkei"}
COMMODITIES = {"oil_wti_cny"}


@dataclass(frozen=True)
class GlobalRepairSpec:
    name: str
    repair_top_count: int
    base_overlay_cap: float
    base_per_asset_cap: float
    global_symbols: tuple[str, ...]
    global_overlay_cap: float
    global_per_asset_cap: float
    global_top_count: int
    commodity_cap: float
    use_phase_lock: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def parse_date(text: str) -> date:
    return datetime.strptime(text[:10], "%Y-%m-%d").date()


def fetch_extra_raw(symbols: list[str]) -> dict[str, list[tuple[date, float]]]:
    query = urllib.parse.urlencode({"symbols": ",".join(symbols), "period": "all"})
    cache_path = HERE / "extra_history_cache.json"
    cache: dict[str, list[tuple[date, float]]] = {}
    if cache_path.exists():
        raw_cache = json.loads(cache_path.read_text())
        cache = {
            symbol: [(date.fromisoformat(day), float(price)) for day, price in rows]
            for symbol, rows in raw_cache.items()
        }
    missing = [symbol for symbol in symbols if EXTRA_ALIASES.get(symbol, symbol) not in cache]
    if missing:
        with urllib.request.urlopen(f"{API_URL}?{query}", timeout=90) as response:
            payload = json.load(response)
        if not payload.get("success"):
            raise RuntimeError(f"history API failed: {payload!r}")
        for item in payload.get("series", []):
            symbol = EXTRA_ALIASES.get(item["symbol"], item["symbol"])
            rows: dict[date, float] = {}
            for date_text, price in zip(item["dates"], item["prices"]):
                if isinstance(price, (int, float)) and math.isfinite(price) and price > 0:
                    rows[parse_date(date_text)] = float(price)
            cache[symbol] = sorted(rows.items())
        cache_path.write_text(
            json.dumps(
                {symbol: [(day.isoformat(), price) for day, price in rows] for symbol, rows in cache.items()},
                ensure_ascii=False,
            )
        )
    return {EXTRA_ALIASES.get(symbol, symbol): cache[EXTRA_ALIASES.get(symbol, symbol)] for symbol in symbols if EXTRA_ALIASES.get(symbol, symbol) in cache}


def align_extra_series(dates: list[date], raw: dict[str, list[tuple[date, float]]]) -> dict[str, list[float]]:
    out: dict[str, list[float]] = {}
    for symbol, rows in raw.items():
        point_dates = [day for day, _price in rows]
        series: list[float] = []
        last_value = 0.0
        for day in dates:
            index = bisect.bisect_right(point_dates, day) - 1
            if index < 0:
                series.append(last_value)
                continue
            source_day, price = rows[index]
            if (day - source_day).days <= app.MAX_FORWARD_FILL_CALENDAR_DAYS:
                last_value = price
            series.append(last_value)
        if any(value > 0 for value in series):
            out[symbol] = series
    return out


def add_extra_series(data: dict[str, Any], symbols: list[str]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    raw = fetch_extra_raw(symbols)
    extra = align_extra_series(dates, raw)
    next_data = dict(data)
    prices_by_symbol = {symbol: list(values) for symbol, values in data["prices_by_symbol"].items()}
    prices_by_symbol.update(extra)
    next_data["prices_by_symbol"] = prices_by_symbol
    tradable_symbols = sorted(set(data["tradable_symbols"]) | set(extra))
    next_data["tradable_symbols"] = tradable_symbols
    next_data["extra_symbols"] = sorted(extra)
    return next_data


def make_repair_spec(spec: GlobalRepairSpec) -> Any:
    return repair.RepairSpec(
        name=f"global_base_repair_top{spec.repair_top_count}",
        mode="overlay",
        drawdown_lookback=105,
        drawdown_threshold=0.10,
        rebound_lookback=30,
        rebound_threshold=0.055,
        confirmation_ma=40,
        momentum_lookback=20,
        top_count=spec.repair_top_count,
        overlay_cap=spec.base_overlay_cap,
        per_asset_cap=spec.base_per_asset_cap,
        require_breadth=True,
        exit_weakness=True,
    )


def make_phase_spec(enabled: bool, repair_top_count: int) -> Any:
    return phase.PhaseLockSpec(
        name="gold_phase_middle_scale25" if enabled else "phase_off",
        repair_top_count=repair_top_count,
        repair_overlay_cap=0.35,
        repair_per_asset_cap=0.15,
        lock_universe="gold" if enabled else "none",
        hot_lookback=126,
        hot_threshold=0.22,
        crack_lookback=20,
        crack_threshold=-0.020,
        rollover_drawdown=0.08,
        lock_scale=0.25 if enabled else 1.0,
        max_lock_days=126,
        portfolio_dd_limit=0.0,
        stress_budget=1.0,
    )


def safe_momentum(values: list[float], index: int, lookback: int) -> float | None:
    value = app.price_momentum(values, index, lookback)
    return value if value is not None and math.isfinite(value) else None


def global_breadth_ok(prices_by_symbol: dict[str, list[float]], indicators: dict[str, dict[int, list[float | None]]], index: int) -> bool:
    checked = 0
    healthy = 0
    for symbol in ["nasdaq", "sp500", "hsi", "nikkei", "csi300", "shanghai_composite"]:
        prices = prices_by_symbol.get(symbol)
        if not prices:
            continue
        ma = indicators[symbol][60][index]
        mom = safe_momentum(prices, index, 20)
        if ma is None or mom is None:
            continue
        checked += 1
        if prices[index] > ma and mom > -0.025:
            healthy += 1
    return checked >= 4 and healthy >= 3


def local_volatility(values: list[float], index: int, lookback: int) -> float | None:
    return repair.local_volatility(values, index, lookback)


def global_repair_score(
    symbol: str,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
) -> float | None:
    prices = prices_by_symbol[symbol]
    if index <= 0 or prices[index] <= 0:
        return None
    drawdown = repair.rolling_high_drawdown(prices, index, 120)
    rebound = repair.rolling_low_rebound(prices, index, 30)
    momentum20 = safe_momentum(prices, index, 20)
    momentum60 = safe_momentum(prices, index, 60)
    ma20 = indicators[symbol][20][index]
    ma40 = indicators[symbol][40][index]
    ma120 = indicators[symbol][120][index]
    if None in (drawdown, rebound, momentum20, momentum60, ma20, ma40, ma120):
        return None
    assert drawdown is not None and rebound is not None and momentum20 is not None and momentum60 is not None
    assert ma20 is not None and ma40 is not None and ma120 is not None
    if drawdown > -0.10 or rebound < 0.055:
        return None
    if prices[index] < ma20 or prices[index] < ma40 or momentum20 < 0 or momentum60 < -0.02:
        return None
    if symbol in GLOBAL_EQUITIES and not global_breadth_ok(prices_by_symbol, indicators, index):
        return None
    if symbol in COMMODITIES:
        gold = prices_by_symbol["gold_cny"]
        gold_mom60 = safe_momentum(gold, index, 60)
        gold_ma120 = indicators["gold_cny"][120][index]
        if gold_mom60 is None or gold_ma120 is None or gold_mom60 < 0 or gold[index] < gold_ma120:
            return None
        if momentum60 < 0.04 or prices[index] < ma120:
            return None
    volatility = local_volatility(prices, index, 60) or 9.0
    return max(0.0, rebound * 1.3 + momentum20 * 0.5 + momentum60 * 0.45 + max(drawdown, -0.50) * 0.15) / max(volatility, 0.04)


def global_targets(
    spec: GlobalRepairSpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
    budget: float,
) -> dict[str, float]:
    if signal_index < 0 or budget <= 0:
        return {}
    scored: list[tuple[float, str]] = []
    for symbol in spec.global_symbols:
        if symbol not in prices_by_symbol:
            continue
        score = global_repair_score(symbol, prices_by_symbol, indicators, signal_index)
        if score is not None and score > 0:
            scored.append((score, symbol))
    scored.sort(reverse=True)
    selected = scored[: max(1, spec.global_top_count)]
    score_total = sum(score for score, _symbol in selected)
    if score_total <= 0:
        return {}
    out: dict[str, float] = {}
    for score, symbol in selected:
        cap = spec.commodity_cap if symbol in COMMODITIES else spec.global_per_asset_cap
        out[symbol] = min(cap, budget * score / score_total)
    return repair.normalize(out, budget)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def simulate(data: dict[str, Any], spec: GlobalRepairSpec) -> tuple[list[float], dict[str, Any], list[Any]]:
    prices_by_symbol: dict[str, list[float]] = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    indicators = repair.build_indicators(prices_by_symbol)
    repair_spec = make_repair_spec(spec)
    phase_spec = make_phase_spec(spec.use_phase_lock, spec.repair_top_count)

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
    locked: dict[str, int] = {}
    active_targets: dict[str, float] = {}
    base_targets: dict[str, float] = {}
    repair_overlay: dict[str, float] = {}
    global_overlay: dict[str, float] = {}
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, _current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        signal_index = index - 1
        previous_lock_count = len(locked)

        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = dyn.choose_weight(
                    repair.BASE_SELECTOR,
                    satellite_values,
                    defensive_values,
                    values,
                    signal_index,
                    selector_weight,
                )
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
                if spec.use_phase_lock:
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

        if index == 0 or index % 21 == 0:
            base_budget = min(repair_spec.overlay_cap, max(0.0, 1.0 - repair.total_weight(base_targets)))
            active_repair_symbols = set(repair_overlay)
            repair_overlay = repair.repair_targets(
                spec=repair_spec,
                prices_by_symbol=prices_by_symbol,
                indicators=indicators,
                tradable_symbols=[symbol for symbol in tradable_symbols if symbol not in set(spec.global_symbols)],
                signal_index=signal_index,
                budget=base_budget,
                active_repair_symbols=active_repair_symbols,
            )
            if repair_overlay:
                repair_hits += 1
            remaining_budget = min(spec.global_overlay_cap, max(0.0, 1.0 - repair.total_weight(base_targets) - repair.total_weight(repair_overlay)))
            global_overlay = global_targets(spec, prices_by_symbol, indicators, signal_index, remaining_budget)
            if global_overlay:
                global_hits += 1
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
            if spec.use_phase_lock:
                targets = phase.apply_phase_locks(targets, locked, phase_spec)
            max_target_sum = max(max_target_sum, repair.total_weight(targets))
            if targets_changed(targets, active_targets):
                active_targets = repair.rebalance_portfolio(
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
        "switches": switches,
        "repair_hits": repair_hits,
        "global_hits": global_hits,
        "phase_lock_events": phase_lock_events,
        "phase_lock_days": phase_lock_days,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else None,
        "latest_selector_weight": selector_weights[-1] if selector_weights else None,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return values, extra, trades


def row_for(data: dict[str, Any], spec: GlobalRepairSpec, values: list[float], extra: dict[str, Any], trades: list[Any]) -> dict[str, Any]:
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
            "post_2020": repair.slice_metrics(dates, values, "2020-01-01"),
            "last_10y": repair.slice_metrics(dates, values, "2016-06-23"),
            "post_2022": repair.slice_metrics(dates, values, "2022-01-01"),
            "post_2024": repair.slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": repair.max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def specs() -> list[GlobalRepairSpec]:
    out: list[GlobalRepairSpec] = []
    symbol_sets = [
        ("global_eq", ("hsi", "nikkei")),
        ("global_eq_oil", ("hsi", "nikkei", "oil_wti_cny")),
        ("oil_only", ("oil_wti_cny",)),
    ]
    for repair_top_count in [1, 2]:
        for label, symbols in symbol_sets:
            for global_overlay_cap, global_per_asset_cap, global_top_count in [
                (0.08, 0.06, 1),
                (0.12, 0.08, 1),
                (0.15, 0.08, 2),
            ]:
                for commodity_cap in [0.04, 0.06]:
                    for use_phase_lock in [False, True]:
                        if "oil_wti_cny" not in symbols and commodity_cap != 0.04:
                            continue
                        out.append(
                            GlobalRepairSpec(
                                name=(
                                    f"{label}_cap{int(global_overlay_cap*100)}_per{int(global_per_asset_cap*100)}_"
                                    f"top{global_top_count}_oil{int(commodity_cap*100)}_phase{int(use_phase_lock)}_repair{repair_top_count}"
                                ),
                                repair_top_count=repair_top_count,
                                base_overlay_cap=0.35,
                                base_per_asset_cap=0.15,
                                global_symbols=symbols,
                                global_overlay_cap=global_overlay_cap,
                                global_per_asset_cap=global_per_asset_cap,
                                global_top_count=global_top_count,
                                commodity_cap=commodity_cap,
                                use_phase_lock=use_phase_lock,
                            )
                        )
    return out


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data = add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        rows: list[dict[str, Any]] = []
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "053 repair overlay plus global repair opportunity sleeve. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:80]:
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
