#!/usr/bin/env python3
"""Gold panic-premium release lock on top of the 061 line.

The 061 champion still has its worst drawdown in early 2003, when gold had a
fast panic-premium run-up and then rolled over. This spike tests a state machine:
after gold becomes short-term overheated, a short reversal locks part of the
gold exposure into cash/USD cash for a limited time.

No leverage, no shorting, no BTC. Total target weight remains capped at 100%.
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
S061_PATH = ROOT / "spikes" / "061-currency-cash-selector" / "currency_cash_selector.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


s061 = load_module("currency_cash_selector_061", S061_PATH)
s060 = s061.s060
app = s061.app
repair = s061.repair
g59 = s061.g59
t47 = s061.t47
replay = s061.replay
s35 = s061.s35
s30 = s061.s30
phase = s061.phase

GOLD = "gold_cny"


@dataclass(frozen=True)
class GoldLockSpec:
    name: str
    currency_spec: Any
    hot_lookback: int
    hot_threshold: float
    crack_lookback: int
    crack_threshold: float
    ma_period: int
    scale: float
    cooldown_sessions: int
    release_mode: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0 or values[index] <= 0:
        return None
    return values[index] / values[index - lookback] - 1.0


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0 or values[index] <= 0:
        return None
    window = values[index - lookback + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    peak = max(window)
    return values[index] / peak - 1.0 if peak > 0 else None


def gold_overheated(values: list[float], index: int, spec: GoldLockSpec) -> bool:
    hot_mom = momentum(values, index, spec.hot_lookback)
    ma_long = moving_average(values, index, max(80, spec.hot_lookback * 2))
    if hot_mom is None or ma_long is None:
        return False
    return hot_mom > spec.hot_threshold and values[index] > ma_long * 1.06


def gold_cracked(values: list[float], index: int, spec: GoldLockSpec) -> bool:
    crack_mom = momentum(values, index, spec.crack_lookback)
    ma = moving_average(values, index, spec.ma_period)
    dd = rolling_drawdown(values, index, max(spec.crack_lookback, 10))
    if crack_mom is None or ma is None or dd is None:
        return False
    return crack_mom < spec.crack_threshold or values[index] < ma or dd < spec.crack_threshold * 1.4


def release_ok(values: list[float], index: int, spec: GoldLockSpec) -> bool:
    if spec.release_mode == "time_only":
        return False
    ma = moving_average(values, index, spec.ma_period)
    mom = momentum(values, index, max(5, spec.crack_lookback))
    if ma is None or mom is None:
        return False
    if spec.release_mode == "ma_reclaim":
        return values[index] > ma and mom > 0
    if spec.release_mode == "calm_reclaim":
        dd = rolling_drawdown(values, index, 20)
        return values[index] > ma and mom > -0.005 and (dd is None or dd > -0.03)
    raise ValueError(spec.release_mode)


def apply_gold_lock(
    targets: dict[str, float],
    spec: GoldLockSpec,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    state: dict[str, Any],
) -> dict[str, float]:
    if signal_index < 0 or GOLD not in targets:
        return repair.normalize(targets)
    gold = prices_by_symbol[GOLD]
    armed = bool(state.get("gold_lock_armed", False))
    if gold_overheated(gold, signal_index, spec):
        armed = True
        state["gold_lock_armed"] = True
        state["gold_lock_hot_hits"] = int(state.get("gold_lock_hot_hits", 0)) + 1
    if armed and gold_cracked(gold, signal_index, spec):
        state["gold_lock_until"] = max(int(state.get("gold_lock_until", -1)), signal_index + spec.cooldown_sessions)
        state["gold_lock_events"] = int(state.get("gold_lock_events", 0)) + 1
        state["gold_lock_armed"] = False

    active = int(state.get("gold_lock_until", -1)) >= signal_index
    if active and release_ok(gold, signal_index, spec):
        active = False
        state["gold_lock_until"] = signal_index - 1
        state["gold_lock_releases"] = int(state.get("gold_lock_releases", 0)) + 1

    if not active:
        return repair.normalize(targets)

    out = dict(targets)
    old = out.get(GOLD, 0.0)
    if old > 0:
        out[GOLD] = old * spec.scale
        state["gold_lock_active_days"] = int(state.get("gold_lock_active_days", 0)) + 1
    return repair.normalize(out)


def run_gold_spec(data: dict[str, Any], spec: GoldLockSpec) -> dict[str, Any]:
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
        locked = apply_gold_lock(base, spec, prices_by_symbol, signal_index, state)
        final_state.clear()
        final_state.update(state)
        return s061.add_currency_cash(locked, spec.currency_spec, prices_by_symbol, indicators, signal_index, state)

    s060.apply_contagion_control = wrapped_apply  # type: ignore[assignment]
    try:
        values, extra, trades, target_log = s060.simulate(data, spec.currency_spec.contagion_spec)
    finally:
        s060.apply_contagion_control = original_apply  # type: ignore[assignment]

    for key in [
        "gold_lock_hot_hits",
        "gold_lock_events",
        "gold_lock_active_days",
        "gold_lock_releases",
        "gold_lock_until",
    ]:
        if key in final_state:
            extra[key] = final_state[key]

    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "spec": {
            "hot_lookback": spec.hot_lookback,
            "hot_threshold": spec.hot_threshold,
            "crack_lookback": spec.crack_lookback,
            "crack_threshold": spec.crack_threshold,
            "ma_period": spec.ma_period,
            "scale": spec.scale,
            "cooldown_sessions": spec.cooldown_sessions,
            "release_mode": spec.release_mode,
            "currency": {
                "name": spec.currency_spec.name,
                "mode": spec.currency_spec.mode,
                "lookback": spec.currency_spec.lookback,
                "ma_period": spec.currency_spec.ma_period,
                "cap": spec.currency_spec.cap,
                "cny_cash_hurdle_scale": spec.currency_spec.cny_cash_hurdle_scale,
                "contagion": spec.currency_spec.contagion_spec.__dict__,
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


def currency_best() -> Any:
    return s061.CurrencySpec(
        name="currency_idle_hurdle_lb40_ma80_cap100_h10",
        contagion_spec=s061.specs()[0].contagion_spec,
        mode="idle_hurdle",
        lookback=40,
        ma_period=80,
        cap=1.0,
        cny_cash_hurdle_scale=1.0,
    )


def specs() -> list[GoldLockSpec]:
    currency = currency_best()
    out: list[GoldLockSpec] = []
    for hot_lookback, hot_threshold in [(20, 0.08), (30, 0.10), (40, 0.12), (60, 0.16)]:
        for crack_lookback, crack_threshold in [(5, -0.020), (10, -0.030), (20, -0.045)]:
            for ma_period in [10, 20, 40]:
                for scale in [0.15, 0.25, 0.35, 0.50]:
                    for cooldown in [21, 42, 63]:
                        for release_mode in ["time_only", "ma_reclaim", "calm_reclaim"]:
                            out.append(
                                GoldLockSpec(
                                    name=(
                                        f"gold_panic_hot{hot_lookback}_{int(hot_threshold*1000)}"
                                        f"_cr{crack_lookback}_{int(abs(crack_threshold)*1000)}"
                                        f"_ma{ma_period}_s{int(scale*100)}_cd{cooldown}_{release_mode}"
                                    ),
                                    currency_spec=currency,
                                    hot_lookback=hot_lookback,
                                    hot_threshold=hot_threshold,
                                    crack_lookback=crack_lookback,
                                    crack_threshold=crack_threshold,
                                    ma_period=ma_period,
                                    scale=scale,
                                    cooldown_sessions=cooldown,
                                    release_mode=release_mode,
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
        rows = [s061.run_currency_spec(data, currency_best())]
        for spec in specs():
            rows.append(run_gold_spec(data, spec))
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
                "note": "061 line plus gold panic-premium release lock. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | goldlock | trades | dd window")
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
            f"{extra.get('gold_lock_events', 0)}/{extra.get('gold_lock_active_days', 0)}/{extra.get('gold_lock_releases', 0)} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
