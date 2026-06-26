#!/usr/bin/env python3
"""Low-frequency return-source probes under 1% fee.

This file deliberately avoids another defensive wrapper around the 063 stack.
It tests lower-turnover allocation logic where the return source itself changes:

- quarterly gold/Nasdaq trend barbell;
- volatility-balanced gold/Nasdaq trend core;
- global risk-efficiency top-two rotation;
- crisis router that prefers gold/USD cash when equity breadth breaks.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import statistics
import sys
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
BASE_PATH = HERE / "low_turnover_daily_defense.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


base = load_module("low_turnover_daily_defense_064", BASE_PATH)
app = base.app
repair = base.repair
t47 = base.t47
g59 = base.g59
s061 = base.s061

GOLD = "gold_cny"
NASDAQ = "nasdaq"
SP500 = "sp500"
USD_CASH = s061.USD_CASH
EQUITY_SYMBOLS = {
    "nasdaq",
    "sp500",
    "dowjones",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
    "hsi",
    "nikkei",
}
GLOBAL_UNIVERSE = [
    GOLD,
    NASDAQ,
    SP500,
    "dowjones",
    "hsi",
    "nikkei",
    "shanghai_composite",
    "csi300",
    USD_CASH,
]


@dataclass(frozen=True)
class LowFreqSpec:
    name: str
    thesis: str
    rebalance_sessions: int
    mode: str
    max_asset_weight: float = 0.70
    max_total_weight: float = 1.0
    rebalance_band: float = 0.025


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def positive_price(prices: dict[str, list[float]], symbol: str, index: int) -> bool:
    return symbol in prices and 0 <= index < len(prices[symbol]) and prices[symbol][index] > 0


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
    return statistics.stdev(returns) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def trend_ok(prices: dict[str, list[float]], symbol: str, index: int, ma_period: int = 180, mom_lookback: int = 126) -> bool:
    if not positive_price(prices, symbol, index):
        return False
    values = prices[symbol]
    ma = moving_average(values, index, ma_period)
    mom = momentum(values, index, mom_lookback)
    return ma is not None and mom is not None and values[index] >= ma and mom > 0


def normalize(weights: dict[str, float], max_total: float = 1.0, max_asset: float = 1.0) -> dict[str, float]:
    clean = {
        symbol: min(max(weight, 0.0), max_asset)
        for symbol, weight in weights.items()
        if weight > 0.0001
    }
    total = sum(clean.values())
    if total > max_total and total > 0:
        scale = max_total / total
        clean = {symbol: weight * scale for symbol, weight in clean.items() if weight * scale > 0.0001}
    return clean


def usd_cash_ok(prices: dict[str, list[float]], index: int) -> bool:
    if not positive_price(prices, USD_CASH, index):
        return False
    values = prices[USD_CASH]
    mom = momentum(values, index, 63)
    ma = moving_average(values, index, 126)
    return mom is not None and ma is not None and mom > 0 and values[index] >= ma


def idle_cash_target(prices: dict[str, list[float]], index: int, weight: float) -> dict[str, float]:
    if weight <= 0:
        return {}
    return {USD_CASH: min(weight, 1.0)} if usd_cash_ok(prices, index) else {}


def global_breadth_weak(prices: dict[str, list[float]], index: int) -> bool:
    checked = 0
    healthy = 0
    for symbol in ["nasdaq", "sp500", "dowjones", "hsi", "nikkei", "shanghai_composite", "csi300"]:
        if not positive_price(prices, symbol, index):
            continue
        ma = moving_average(prices[symbol], index, 120)
        mom = momentum(prices[symbol], index, 40)
        if ma is None or mom is None:
            continue
        checked += 1
        if prices[symbol][index] >= ma and mom > -0.015:
            healthy += 1
    return checked >= 5 and healthy <= 2


def score_asset(prices: dict[str, list[float]], symbol: str, index: int) -> float | None:
    if not positive_price(prices, symbol, index):
        return None
    values = prices[symbol]
    mom126 = momentum(values, index, 126)
    mom252 = momentum(values, index, 252)
    ma = moving_average(values, index, 180)
    vol = annual_vol(values, index, 126)
    dd = rolling_drawdown(values, index, 126)
    if None in (mom126, mom252, ma, vol, dd):
        return None
    assert mom126 is not None and mom252 is not None and ma is not None and vol is not None and dd is not None
    if values[index] < ma or mom126 <= 0:
        return None
    drawdown_penalty = min(abs(min(dd, 0.0)), 0.25) * 0.35
    return (mom126 + 0.45 * mom252 - drawdown_penalty) / max(vol, 0.04)


def target_for(spec: LowFreqSpec, prices: dict[str, list[float]], index: int) -> dict[str, float]:
    if index < 0:
        return {}

    if spec.mode == "trend_barbell":
        out: dict[str, float] = {}
        if trend_ok(prices, GOLD, index):
            out[GOLD] = 0.50
        if trend_ok(prices, NASDAQ, index):
            out[NASDAQ] = 0.50
        leftover = max(0.0, 1.0 - sum(out.values()))
        out.update(idle_cash_target(prices, index, leftover))
        return normalize(out, spec.max_total_weight, spec.max_asset_weight)

    if spec.mode == "vol_balanced_gold_nasdaq":
        candidates = [symbol for symbol in [GOLD, NASDAQ] if trend_ok(prices, symbol, index)]
        if not candidates:
            return idle_cash_target(prices, index, 1.0)
        inv: dict[str, float] = {}
        for symbol in candidates:
            vol = annual_vol(prices[symbol], index, 126)
            inv[symbol] = 1.0 / max(vol or 0.20, 0.05)
        total = sum(inv.values())
        out = {symbol: min(spec.max_asset_weight, inv[symbol] / total) for symbol in candidates}
        leftover = max(0.0, spec.max_total_weight - sum(out.values()))
        out.update(idle_cash_target(prices, index, leftover))
        return normalize(out, spec.max_total_weight, spec.max_asset_weight)

    if spec.mode == "global_top2_efficiency":
        scored: list[tuple[float, str]] = []
        for symbol in GLOBAL_UNIVERSE:
            score = score_asset(prices, symbol, index)
            if score is not None and score > 0:
                scored.append((score, symbol))
        scored.sort(reverse=True)
        selected = scored[:2]
        if not selected:
            return idle_cash_target(prices, index, 1.0)
        score_total = sum(score for score, _symbol in selected)
        out = {
            symbol: min(spec.max_asset_weight, spec.max_total_weight * score / score_total)
            for score, symbol in selected
            if score_total > 0
        }
        leftover = max(0.0, spec.max_total_weight - sum(out.values()))
        out.update(idle_cash_target(prices, index, leftover))
        return normalize(out, spec.max_total_weight, spec.max_asset_weight)

    if spec.mode == "crisis_gold_router":
        weak = global_breadth_weak(prices, index)
        out: dict[str, float] = {}
        if weak:
            if trend_ok(prices, GOLD, index, 120, 63):
                out[GOLD] = 0.70
            out.update(idle_cash_target(prices, index, 1.0 - sum(out.values())))
            return normalize(out, spec.max_total_weight, spec.max_asset_weight)
        if trend_ok(prices, NASDAQ, index, 180, 126):
            out[NASDAQ] = 0.60
        if trend_ok(prices, GOLD, index, 180, 126):
            out[GOLD] = out.get(GOLD, 0.0) + 0.35
        if not out and trend_ok(prices, SP500, index, 180, 126):
            out[SP500] = 0.55
        out.update(idle_cash_target(prices, index, max(0.0, 1.0 - sum(out.values()))))
        return normalize(out, spec.max_total_weight, spec.max_asset_weight)

    if spec.mode == "single_best_macro":
        scored: list[tuple[float, str]] = []
        for symbol in [GOLD, NASDAQ, SP500, "hsi", "nikkei", USD_CASH]:
            score = score_asset(prices, symbol, index)
            if score is not None and score > 0:
                scored.append((score, symbol))
        if not scored:
            return idle_cash_target(prices, index, 1.0)
        scored.sort(reverse=True)
        return normalize({scored[0][1]: spec.max_total_weight}, spec.max_total_weight, spec.max_asset_weight)

    raise ValueError(spec.mode)


def run_spec(data: dict[str, Any], spec: LowFreqSpec) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    prices: dict[str, list[float]] = data["prices_by_symbol"]
    tradable_symbols = sorted(symbol for symbol in set(GLOBAL_UNIVERSE) if symbol in prices)
    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[Any] = []
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices[symbol][index] for symbol in tradable_symbols)

    for index, _current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        if index == 0 or index % max(spec.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_for(spec, prices, signal_index) if signal_index >= 0 else {}
            max_target_sum = max(max_target_sum, sum(targets.values()))
            if base.targets_changed(targets, active_targets):
                active_targets = base.fee_aware_rebalance(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices,
                    tradable_symbols=tradable_symbols,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                    band=spec.rebalance_band,
                    buy=True,
                )

        values.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol_value, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": spec.__dict__,
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol_value,
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
        "extra": {
            "max_target_sum": max_target_sum,
            "symbols": tradable_symbols,
        },
    }


def specs() -> list[LowFreqSpec]:
    return [
        LowFreqSpec(
            name="quarterly_gold_nasdaq_trend_barbell",
            thesis="Hold gold and Nasdaq sleeves only when each has absolute trend; idle budget can sit in USD cash.",
            rebalance_sessions=63,
            mode="trend_barbell",
            max_asset_weight=0.55,
        ),
        LowFreqSpec(
            name="quarterly_vol_balanced_gold_nasdaq",
            thesis="Risk-balance gold/Nasdaq only when each passes trend; avoids constant equity exposure.",
            rebalance_sessions=63,
            mode="vol_balanced_gold_nasdaq",
            max_asset_weight=0.70,
        ),
        LowFreqSpec(
            name="quarterly_global_top2_efficiency",
            thesis="Quarterly top-two by trend-adjusted return per volatility across gold, global equities, and USD cash.",
            rebalance_sessions=63,
            mode="global_top2_efficiency",
            max_asset_weight=0.65,
        ),
        LowFreqSpec(
            name="semiannual_global_top2_efficiency",
            thesis="Same top-two efficiency logic but with half-year rebalance to cut turnover under 1% fee.",
            rebalance_sessions=126,
            mode="global_top2_efficiency",
            max_asset_weight=0.65,
        ),
        LowFreqSpec(
            name="quarterly_crisis_gold_router",
            thesis="Prefer gold/USD cash when global breadth breaks; otherwise hold Nasdaq plus gold only if trends are intact.",
            rebalance_sessions=63,
            mode="crisis_gold_router",
            max_asset_weight=0.70,
        ),
        LowFreqSpec(
            name="semiannual_single_best_macro",
            thesis="Concentrated low-turnover macro winner among gold, Nasdaq, broad US, HK/Japan, and USD cash.",
            rebalance_sessions=126,
            mode="single_best_macro",
            max_asset_weight=0.90,
        ),
    ]


def load_data() -> dict[str, Any]:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    patched_apps = [
        app, g59.app, g59.replay.app, g59.s35.app, g59.s30.app,
        s061.app, s061.s060.app, s061.repair.app,
    ]
    for module_app in patched_apps:
        module_app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data = g59.add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        data = s061.add_usd_cash_series(data)
        return data
    finally:
        for module_app in patched_apps:
            module_app.fetch_public_history = original_fetch  # type: ignore[assignment]


def main() -> None:
    data = load_data()
    rows = [run_spec(data, spec) for spec in specs()]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "low_frequency_results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Low-frequency no-leverage/no-BTC return-source probes with 1% fee and 0.05% slippage.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows:
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
