#!/usr/bin/env python3
"""Energy/inflation sleeve on top of the current champion.

No leverage, no shorting, no BTC.  WTI is tested as a separate conditional
inflation/commodity sleeve that can use idle cash, instead of being ranked with
equity indices.
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

S30_PATH = ROOT / "spikes" / "030-smooth-risk-budget" / "smooth_risk_budget.py"
SPEC = importlib.util.spec_from_file_location("smooth_risk_budget_base", S30_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {S30_PATH}")
s30 = importlib.util.module_from_spec(SPEC)
sys.modules["smooth_risk_budget_base"] = s30
SPEC.loader.exec_module(s30)

app = s30.app
base = s30.base
API_URL = app.API_URL
ENERGY_SYMBOL = "oil_wti_cny"


@dataclass(frozen=True)
class EnergySpec:
    name: str
    thesis: str
    cap: float
    contribution_vol: float
    mode: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def parse_date(text: str) -> date:
    return datetime.strptime(text, "%Y-%m-%d").date()


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(clean)
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    previous = values[index - lookback]
    if previous <= 0 or values[index] <= 0:
        return None
    return values[index] / previous - 1


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1 : index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] <= 0 or values[cursor] <= 0:
            return None
        returns.append(math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0 or values[index] <= 0:
        return None
    window = values[index - lookback + 1 : index + 1]
    if any(value <= 0 for value in window):
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def fetch_energy_raw(end_date: date) -> list[tuple[date, float]]:
    query = urllib.parse.urlencode({"symbols": ENERGY_SYMBOL, "period": "all"})
    with urllib.request.urlopen(f"{API_URL}?{query}", timeout=90) as response:
        payload = json.load(response)
    if not payload.get("success"):
        raise RuntimeError(f"history API failed: {payload!r}")
    item = payload["series"][0]
    rows: dict[date, float] = {}
    for date_text, price in zip(item["dates"], item["prices"]):
        day = parse_date(date_text)
        if day > end_date:
            continue
        if isinstance(price, (int, float)) and math.isfinite(price) and price > 0:
            rows[day] = float(price)
    return sorted(rows.items())


def add_energy_series(env: s30.BacktestEnv) -> dict[str, list[float]]:
    prices = {symbol: list(values) for symbol, values in env.prices_by_symbol.items()}
    raw = fetch_energy_raw(env.dates[-1])
    point_dates = [day for day, _price in raw]
    series: list[float] = []
    for day in env.dates:
        point_index = bisect.bisect_right(point_dates, day) - 1
        if point_index < 0:
            series.append(0.0)
            continue
        source_day, price = raw[point_index]
        if (day - source_day).days > app.MAX_FORWARD_FILL_CALENDAR_DAYS:
            series.append(series[-1] if series else 0.0)
        else:
            series.append(price)
    prices[ENERGY_SYMBOL] = series
    return prices


def build_env() -> s30.BacktestEnv:
    current = s30.s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
    breadth = s30.s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
    return s30.build_env(base.EngineContext(current=current, breadth=breadth))


def equity_risk_clean(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    weak = 0
    for symbol in ["nasdaq", "sp500"]:
        prices = prices_by_symbol[symbol]
        mom60 = momentum(prices, index, 60)
        ma120 = moving_average(prices, index, 120)
        if mom60 is None or ma120 is None or mom60 < 0 or prices[index] < ma120:
            weak += 1
    return weak == 0


def gold_confirms_inflation(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    gold = prices_by_symbol["gold_cny"]
    mom60 = momentum(gold, index, 60)
    ma120 = moving_average(gold, index, 120)
    return mom60 is not None and ma120 is not None and mom60 > 0 and gold[index] >= ma120


def energy_weight(spec: EnergySpec, prices_by_symbol: dict[str, list[float]], index: int) -> float:
    energy = prices_by_symbol[ENERGY_SYMBOL]
    mom60 = momentum(energy, index, 60)
    mom120 = momentum(energy, index, 120)
    mom240 = momentum(energy, index, 240)
    ma120 = moving_average(energy, index, 120)
    vol60 = annual_vol(energy, index, 60)
    dd40 = rolling_drawdown(energy, index, 40)
    dd120 = rolling_drawdown(energy, index, 120)
    if None in (mom60, mom120, mom240, ma120, vol60, dd40, dd120):
        return 0.0
    assert mom60 is not None and mom120 is not None and mom240 is not None
    assert ma120 is not None and vol60 is not None and dd40 is not None and dd120 is not None
    if energy[index] < ma120 or mom60 <= 0 or mom120 <= 0:
        return 0.0
    if dd40 < -0.11 or dd120 < -0.24 or vol60 > 0.72:
        return 0.0
    if spec.mode == "gold_confirmed" and not gold_confirms_inflation(prices_by_symbol, index):
        return 0.0
    if spec.mode == "risk_clean" and not equity_risk_clean(prices_by_symbol, index):
        return 0.0
    if spec.mode == "dual_confirmed" and (not gold_confirms_inflation(prices_by_symbol, index) or not equity_risk_clean(prices_by_symbol, index)):
        return 0.0
    raw = spec.contribution_vol / max(vol60, 0.05)
    if mom240 < 0:
        raw *= 0.50
    if mom120 > 0.25 and dd40 > -0.04:
        raw *= 1.20
    return min(spec.cap, raw)


def add_energy(weights: dict[str, float], spec: EnergySpec, prices_by_symbol: dict[str, list[float]], signal_index: int) -> dict[str, float]:
    energy = energy_weight(spec, prices_by_symbol, signal_index)
    if energy <= 0:
        return weights
    available = max(0.0, 1.0 - total_weight(weights))
    if available <= 0:
        return weights
    out = dict(weights)
    out[ENERGY_SYMBOL] = min(energy, available)
    return normalize(out)


def run_energy_strategy(spec: EnergySpec, env: s30.BacktestEnv, prices_by_symbol: dict[str, list[float]]) -> app.BacktestResult:
    dates = env.dates
    config = env.config
    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [symbol for symbol in env.symbols if symbol not in config.signal_only_symbols] + [ENERGY_SYMBOL]
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, env.meta_traces) if config.meta_switch else {}
        champion = env.champion_overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        return add_energy(champion, spec, prices_by_symbol, signal_index)

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = normalize(target_weights(signal_index, index) if signal_index >= 0 else {})
            target_symbols = set(targets.keys())
            pre_value = portfolio_value(index)

            for symbol in sorted(held - target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices_by_symbol[symbol][index]
                execution_price = max(price * (1 - slippage_rate), 0.0)
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

            total_value = portfolio_value(index)
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

        value = portfolio_value(index)
        points.append(value)
        values_by_index[index] = value

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    return app.BacktestResult(
        strategy=spec.name,
        coverage_start=dates[0].isoformat(),
        coverage_end=dates[-1].isoformat(),
        point_count=len(points),
        annualized_return=annualized,
        max_drawdown=max_dd,
        total_return=total,
        annualized_volatility=annual_vol,
        sharpe_ratio=sharpe,
        final_value=points[-1],
        trades=trades,
        dates=dates,
        values=points,
    )


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, Any]:
    peak = result.values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {"peak_date": result.dates[worst_peak].isoformat(), "trough_date": result.dates[worst_trough].isoformat(), "max_drawdown": worst}


def row_for(spec: EnergySpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "cap": spec.cap,
            "contribution_vol": spec.contribution_vol,
            "mode": spec.mode,
        },
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "annual_volatility": result.annualized_volatility,
            "sharpe": result.sharpe_ratio,
            "total": result.total_return,
            "trades": len(result.trades),
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-23"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def specs() -> list[EnergySpec]:
    out = [EnergySpec("baseline_one_way", "Current champion reproduced in this spike.", 0.0, 0.0, "none")]
    for mode in ["simple", "gold_confirmed", "risk_clean", "dual_confirmed"]:
        for cap in [0.08, 0.12, 0.15, 0.20]:
            for contribution in [0.025, 0.035, 0.045, 0.060]:
                out.append(
                    EnergySpec(
                        f"energy_{mode}_cap{int(cap*100)}_cv{int(contribution*1000)}",
                        "Use idle cash for a separate WTI inflation-trend sleeve.",
                        cap,
                        contribution,
                        mode,
                    )
                )
    return out


def main() -> None:
    original_fetch = app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        env = build_env()
        prices_by_symbol = add_energy_series(env)
        rows = [row_for(spec, run_energy_strategy(spec, env, prices_by_symbol)) for spec in specs()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows[:30]:
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
