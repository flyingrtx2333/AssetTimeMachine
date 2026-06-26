#!/usr/bin/env python3
"""Currency cash selector on top of the 060 contagion-controlled line.

The hypothesis is deliberately narrow: keep the 060 equity/gold targets intact,
but when the strategy leaves idle budget, choose between CNY cash and USD cash
based on the USD/CNY trend. Holding USD cash is not leverage and does not
increase total target weight above 100%.
"""
from __future__ import annotations

import bisect
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
S060_PATH = ROOT / "spikes" / "060-contagion-controlled-global-repair" / "contagion_controlled_global_repair.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


s060 = load_module("contagion_controlled_global_repair_060", S060_PATH)

app = s060.app
repair = s060.repair
g59 = s060.g59
t47 = s060.t47
replay = s060.replay
s35 = s060.s35
s30 = s060.s30
phase = s060.phase

USD_CASH = "usd_cash"


@dataclass(frozen=True)
class CurrencySpec:
    name: str
    contagion_spec: Any
    mode: str
    lookback: int
    ma_period: int
    cap: float
    cny_cash_hurdle_scale: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def parse_date(text: str) -> date:
    return datetime.strptime(text[:10], "%Y-%m-%d").date()


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


def add_usd_cash_series(data: dict[str, Any]) -> dict[str, Any]:
    raw = app.fetch_public_history(end_date=data["dates"][-1]).get(app.USD_FX_SYMBOL)
    if not raw:
        raise RuntimeError("missing usd_per_cny history")
    fx_by_day = {day: price for day, price in raw if price > 0}
    point_days = sorted(fx_by_day)

    usd_cash: list[float] = []
    last_value = 0.0
    for day in data["dates"]:
        point_index = bisect.bisect_right(point_days, day) - 1
        if point_index < 0:
            usd_cash.append(last_value)
            continue
        source_day = point_days[point_index]
        value = fx_by_day[source_day]
        if (day - source_day).days <= app.MAX_FORWARD_FILL_CALENDAR_DAYS:
            last_value = 1 / value if value < 1 else value
        usd_cash.append(last_value)

    next_data = dict(data)
    prices_by_symbol = {symbol: list(values) for symbol, values in data["prices_by_symbol"].items()}
    prices_by_symbol[USD_CASH] = usd_cash
    next_data["prices_by_symbol"] = prices_by_symbol
    next_data["tradable_symbols"] = sorted(set(data["tradable_symbols"]) | {USD_CASH})
    return next_data


def global_risk_off(
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
) -> bool:
    checked, healthy = s060.global_breadth(prices_by_symbol, indicators, index)
    return checked >= 5 and healthy <= 2


def usd_cash_ok(
    spec: CurrencySpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
    contagion_state: dict[str, Any],
) -> bool:
    if signal_index < 0:
        return False
    usd = prices_by_symbol[USD_CASH]
    mom = momentum(usd, signal_index, spec.lookback)
    ma = moving_average(usd, signal_index, spec.ma_period)
    if mom is None or ma is None:
        return False
    trend_ok = mom > 0 and usd[signal_index] >= ma
    cny_hurdle = 0.0035
    hurdle_ok = mom > cny_hurdle * spec.lookback / app.TRADING_DAYS_PER_YEAR * spec.cny_cash_hurdle_scale
    contagion_active = int(contagion_state.get("until", -1)) >= signal_index
    risk_off = global_risk_off(prices_by_symbol, indicators, signal_index)

    if spec.mode == "idle_trend":
        return trend_ok
    if spec.mode == "idle_hurdle":
        return trend_ok and hurdle_ok
    if spec.mode == "riskoff_trend":
        return trend_ok and risk_off
    if spec.mode == "contagion_trend":
        return trend_ok and contagion_active
    if spec.mode == "riskoff_or_contagion":
        return trend_ok and (risk_off or contagion_active)
    raise ValueError(spec.mode)


def add_currency_cash(
    targets: dict[str, float],
    spec: CurrencySpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
    contagion_state: dict[str, Any],
) -> dict[str, float]:
    out = dict(targets)
    leftover = max(0.0, 1.0 - repair.total_weight(out))
    if leftover <= 0.0001:
        return repair.normalize(out)
    if usd_cash_ok(spec, prices_by_symbol, indicators, signal_index, contagion_state):
        out[USD_CASH] = min(leftover, spec.cap)
    return repair.normalize(out)


def run_currency_spec(data: dict[str, Any], spec: CurrencySpec) -> dict[str, Any]:
    original_apply: Callable[..., dict[str, float]] = s060.apply_contagion_control

    def wrapped_apply(
        targets: dict[str, float],
        contagion_spec: Any,
        prices_by_symbol: dict[str, list[float]],
        indicators: dict[str, dict[int, list[float | None]]],
        signal_index: int,
        state: dict[str, Any],
    ) -> dict[str, float]:
        base = original_apply(targets, contagion_spec, prices_by_symbol, indicators, signal_index, state)
        return add_currency_cash(base, spec, prices_by_symbol, indicators, signal_index, state)

    s060.apply_contagion_control = wrapped_apply  # type: ignore[assignment]
    try:
        values, extra, trades, target_log = s060.simulate(data, spec.contagion_spec)
    finally:
        s060.apply_contagion_control = original_apply  # type: ignore[assignment]

    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "spec": {
            "mode": spec.mode,
            "lookback": spec.lookback,
            "ma_period": spec.ma_period,
            "cap": spec.cap,
            "cny_cash_hurdle_scale": spec.cny_cash_hurdle_scale,
            "contagion": spec.contagion_spec.__dict__,
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


def specs() -> list[CurrencySpec]:
    best_060 = s060.ContagionSpec(
        name="contagion_cluster_cd63_eq35_glob0_gold0_us_repair",
        cooldown_sessions=63,
        equity_scale=0.35,
        global_overlay_scale=0.0,
        redeploy_gold_ratio=0.0,
        release_mode="us_repair",
        trigger_mode="cluster",
    )
    out: list[CurrencySpec] = []
    for mode in ["idle_trend", "idle_hurdle", "riskoff_trend", "contagion_trend", "riskoff_or_contagion"]:
        for lookback, ma_period in [(40, 80), (60, 120), (90, 180), (126, 252)]:
            for cap in [0.25, 0.50, 1.00]:
                for hurdle_scale in [0.0, 1.0, 2.0]:
                    out.append(
                        CurrencySpec(
                            name=f"currency_{mode}_lb{lookback}_ma{ma_period}_cap{int(cap*100)}_h{int(hurdle_scale*10)}",
                            contagion_spec=best_060,
                            mode=mode,
                            lookback=lookback,
                            ma_period=ma_period,
                            cap=cap,
                            cny_cash_hurdle_scale=hurdle_scale,
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
    g59.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    g59.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    g59.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    g59.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s060.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data = g59.add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        data = add_usd_cash_series(data)
        rows = []
        rows.append(s060.baseline_row(data))
        rows.append(run_currency_spec(data, specs()[0].__class__(
            name="baseline_060_best_without_currency",
            contagion_spec=specs()[0].contagion_spec,
            mode="idle_trend",
            lookback=9999,
            ma_period=9999,
            cap=0.0,
            cny_cash_hurdle_scale=0.0,
        )))
        for spec in specs():
            rows.append(run_currency_spec(data, spec))
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
        g59.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        g59.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        g59.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        g59.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s060.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "060 contagion-controlled line plus idle USD cash selector. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
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
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
