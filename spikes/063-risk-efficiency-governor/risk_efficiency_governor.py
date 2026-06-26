#!/usr/bin/env python3
"""Risk-efficiency governor on top of the 062 line.

After 062, the largest drawdown is much lower but Sharpe is still around 1.51.
This spike tests a different control: estimate the risk of the current target
mix before trading. If target volatility is high and trend/breadth quality does
not justify it, scale only the risk assets and let the currency cash selector
use the freed idle budget.

No leverage, no shorting, no BTC. Total target weight remains <= 100%.
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
S062_PATH = ROOT / "spikes" / "062-gold-panic-premium-lock" / "gold_panic_premium_lock.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


s062 = load_module("gold_panic_premium_lock_062", S062_PATH)
s061 = s062.s061
s060 = s062.s060
app = s062.app
repair = s062.repair
g59 = s062.g59
t47 = s062.t47
replay = s062.replay
s35 = s062.s35
s30 = s062.s30
phase = s062.phase

NON_RISK_SYMBOLS = {s061.USD_CASH}


@dataclass(frozen=True)
class GovernorSpec:
    name: str
    gold_spec: Any
    mode: str
    vol_lookback: int
    trigger_vol: float
    target_vol: float
    momentum_lookback: int
    momentum_threshold: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0 or values[index] <= 0:
        return None
    return values[index] / values[index - lookback] - 1.0


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    returns: list[float] = []
    for idx in range(index - lookback + 1, index + 1):
        prev = values[idx - 1]
        cur = values[idx]
        if prev <= 0 or cur <= 0:
            return None
        returns.append(cur / prev - 1.0)
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def target_risk_quality(
    targets: dict[str, float],
    spec: GovernorSpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
) -> tuple[float | None, float, int, int]:
    weighted_var = 0.0
    weighted_momentum = 0.0
    momentum_weight = 0.0
    checked = 0
    healthy = 0
    for symbol, weight in targets.items():
        if symbol in NON_RISK_SYMBOLS or weight <= 0:
            continue
        prices = prices_by_symbol.get(symbol)
        if not prices:
            continue
        vol = annual_vol(prices, signal_index, spec.vol_lookback)
        mom = momentum(prices, signal_index, spec.momentum_lookback)
        if vol is not None:
            weighted_var += (weight * vol) ** 2
        if mom is not None:
            weighted_momentum += weight * mom
            momentum_weight += weight
        ma = indicators[symbol][60][signal_index] if symbol in indicators and 60 in indicators[symbol] else None
        mom20 = momentum(prices, signal_index, 20)
        if ma is not None and mom20 is not None:
            checked += 1
            if prices[signal_index] > ma and mom20 > -0.015:
                healthy += 1
    expected_vol = math.sqrt(weighted_var) if weighted_var > 0 else None
    quality = weighted_momentum / momentum_weight if momentum_weight > 0 else 0.0
    return expected_vol, quality, checked, healthy


def should_scale(
    targets: dict[str, float],
    spec: GovernorSpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
) -> tuple[bool, float | None, float, int, int]:
    expected_vol, quality, checked, healthy = target_risk_quality(targets, spec, prices_by_symbol, indicators, signal_index)
    if expected_vol is None or expected_vol <= spec.trigger_vol:
        return False, expected_vol, quality, checked, healthy
    if spec.mode == "weak_momentum":
        trigger = quality < spec.momentum_threshold
    elif spec.mode == "weak_breadth":
        trigger = checked >= 4 and healthy <= max(1, checked // 2)
    elif spec.mode == "inefficient":
        trigger = quality < spec.momentum_threshold or (checked >= 4 and healthy <= max(1, checked // 2))
    else:
        raise ValueError(spec.mode)
    return trigger, expected_vol, quality, checked, healthy


def apply_governor(
    targets: dict[str, float],
    spec: GovernorSpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
    state: dict[str, Any],
) -> dict[str, float]:
    if signal_index < 0:
        return repair.normalize(targets)
    trigger, expected_vol, quality, checked, healthy = should_scale(targets, spec, prices_by_symbol, indicators, signal_index)
    if not trigger or expected_vol is None:
        return repair.normalize(targets)
    scale = min(1.0, spec.target_vol / max(expected_vol, 0.001))
    if scale >= 0.995:
        return repair.normalize(targets)
    out = dict(targets)
    for symbol in list(out):
        if symbol not in NON_RISK_SYMBOLS:
            out[symbol] = out[symbol] * scale
    state["governor_events"] = int(state.get("governor_events", 0)) + 1
    state["governor_last_scale"] = scale
    state["governor_last_expected_vol"] = expected_vol
    state["governor_last_quality"] = quality
    state["governor_last_breadth"] = f"{healthy}/{checked}"
    return repair.normalize(out)


def run_governor_spec(data: dict[str, Any], spec: GovernorSpec) -> dict[str, Any]:
    original_apply: Callable[..., dict[str, float]] = s060.apply_contagion_control
    final_state: dict[str, Any] = {}

    def wrapped_apply(
        targets: dict[str, float],
        contagion_spec: Any,
        prices_by_symbol: dict[str, list[float]],
        indicators: dict[str, dict[int, list[float | None]]],
        signal_index: int,
        state: dict[str, Any],
    ) -> dict[str, float]:
        base = original_apply(targets, contagion_spec, prices_by_symbol, indicators, signal_index, state)
        locked = s062.apply_gold_lock(base, spec.gold_spec, prices_by_symbol, signal_index, state)
        governed = apply_governor(locked, spec, prices_by_symbol, indicators, signal_index, state)
        final_state.clear()
        final_state.update(state)
        return s061.add_currency_cash(governed, spec.gold_spec.currency_spec, prices_by_symbol, indicators, signal_index, state)

    s060.apply_contagion_control = wrapped_apply  # type: ignore[assignment]
    try:
        values, extra, trades, target_log = s060.simulate(data, spec.gold_spec.currency_spec.contagion_spec)
    finally:
        s060.apply_contagion_control = original_apply  # type: ignore[assignment]

    for key in [
        "gold_lock_events",
        "gold_lock_active_days",
        "gold_lock_releases",
        "governor_events",
        "governor_last_scale",
        "governor_last_expected_vol",
        "governor_last_quality",
        "governor_last_breadth",
    ]:
        if key in final_state:
            extra[key] = final_state[key]

    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "spec": {
            "mode": spec.mode,
            "vol_lookback": spec.vol_lookback,
            "trigger_vol": spec.trigger_vol,
            "target_vol": spec.target_vol,
            "momentum_lookback": spec.momentum_lookback,
            "momentum_threshold": spec.momentum_threshold,
            "gold": {
                "name": spec.gold_spec.name,
                "hot_lookback": spec.gold_spec.hot_lookback,
                "hot_threshold": spec.gold_spec.hot_threshold,
                "crack_lookback": spec.gold_spec.crack_lookback,
                "crack_threshold": spec.gold_spec.crack_threshold,
                "ma_period": spec.gold_spec.ma_period,
                "scale": spec.gold_spec.scale,
                "cooldown_sessions": spec.gold_spec.cooldown_sessions,
                "release_mode": spec.gold_spec.release_mode,
            },
        },
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


def gold_best() -> Any:
    return s062.GoldLockSpec(
        name="gold_panic_hot30_100_cr20_45_ma20_s25_cd21_ma_reclaim",
        currency_spec=s062.currency_best(),
        hot_lookback=30,
        hot_threshold=0.10,
        crack_lookback=20,
        crack_threshold=-0.045,
        ma_period=20,
        scale=0.25,
        cooldown_sessions=21,
        release_mode="ma_reclaim",
    )


def specs() -> list[GovernorSpec]:
    gold = gold_best()
    out: list[GovernorSpec] = []
    for mode in ["weak_momentum", "weak_breadth", "inefficient"]:
        for vol_lookback in [20, 40, 60]:
            for trigger_vol in [0.115, 0.130, 0.150]:
                for target_vol in [0.080, 0.090, 0.100]:
                    for momentum_lookback, momentum_threshold in [(20, 0.000), (40, 0.015), (60, 0.030)]:
                        out.append(
                            GovernorSpec(
                                name=(
                                    f"governor_{mode}_vl{vol_lookback}_tr{int(trigger_vol*1000)}"
                                    f"_tv{int(target_vol*1000)}_ml{momentum_lookback}_mt{int(momentum_threshold*1000)}"
                                ),
                                gold_spec=gold,
                                mode=mode,
                                vol_lookback=vol_lookback,
                                trigger_vol=trigger_vol,
                                target_vol=target_vol,
                                momentum_lookback=momentum_lookback,
                                momentum_threshold=momentum_threshold,
                            )
                        )
    return out


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    for module_app in [
        app, replay.app, s35.app, s30.app,
        repair.app, repair.replay.app, repair.s35.app, repair.s30.app,
        phase.app, phase.replay.app, phase.s35.app, phase.s30.app,
        g59.app, g59.replay.app, g59.s35.app, g59.s30.app, s060.app,
    ]:
        module_app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data = g59.add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        data = s061.add_usd_cash_series(data)
        rows = [s062.run_gold_spec(data, gold_best())]
        for spec in specs():
            rows.append(run_governor_spec(data, spec))
    finally:
        for module_app in [
            app, replay.app, s35.app, s30.app,
            repair.app, repair.replay.app, repair.s35.app, repair.s30.app,
            phase.app, phase.replay.app, phase.s35.app, phase.s30.app,
            g59.app, g59.replay.app, g59.s35.app, g59.s30.app, s060.app,
        ]:
            module_app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "062 line plus ex-ante risk-efficiency governor. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | governor | trades | dd window")
    for row in rows[:80]:
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
            f"{extra.get('governor_events', 0)}/{extra.get('governor_last_scale', 0):.3f}/{extra.get('governor_last_breadth', '-')} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
