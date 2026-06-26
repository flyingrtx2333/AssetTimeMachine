#!/usr/bin/env python3
"""Crash-aware opportunity logic on top of the current champion.

No leverage, no shorting, no BTC.  This spike tests structural logic instead
of pure parameter tuning:

- suppress China equity exposure after a bubble-rollover state;
- use idle cash only for extra assets with clean trend and non-extreme risk;
- optionally require extra assets to be less correlated with the current core.
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

EXTRA_SYMBOLS = ["dowjones", "shenzhen_component", "chinext", "hang_seng", "nikkei", "wti"]
EXTRA_QUERY_SYMBOLS = [
    "dow_jones",
    "shenzhen_component",
    "chinext",
    "hang_seng",
    "nikkei225",
    "wti",
    app.USD_FX_SYMBOL,
]
ALIASES = {
    "dow_jones": "dowjones",
    "nikkei225": "nikkei",
    "oil_wti_usd": "wti",
}
USD_ASSETS = {"dowjones", "wti"}
CHINA_EQUITIES = {"csi300", "shanghai_composite", "shenzhen_component", "chinext"}
ALL_EQUITIES = set(app.EQUITY_SYMBOLS) | {"dowjones", "shenzhen_component", "chinext", "hang_seng", "nikkei"}


@dataclass(frozen=True)
class Candidate:
    name: str
    thesis: str
    satellite_cap: float
    per_asset_cap: float
    top_count: int
    mode: str
    corr_cap: float | None = None


@dataclass
class SimResult:
    result: app.BacktestResult
    targets_by_index: dict[int, dict[str, float]]


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


def scale_group(weights: dict[str, float], group: set[str], factor: float) -> dict[str, float]:
    out = dict(weights)
    for symbol in group:
        if out.get(symbol, 0.0) > 0:
            out[symbol] *= max(0.0, min(factor, 1.0))
    return normalize(out)


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
    window = [value for value in values[index - lookback + 1 : index + 1] if value > 0]
    if len(window) < lookback:
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def rolling_corr(a: list[float], b: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    ar: list[float] = []
    br: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if min(a[cursor - 1], a[cursor], b[cursor - 1], b[cursor]) <= 0:
            return None
        ar.append(a[cursor] / a[cursor - 1] - 1)
        br.append(b[cursor] / b[cursor - 1] - 1)
    if len(ar) < 20:
        return None
    ma = sum(ar) / len(ar)
    mb = sum(br) / len(br)
    va = sum((item - ma) ** 2 for item in ar)
    vb = sum((item - mb) ** 2 for item in br)
    if va <= 0 or vb <= 0:
        return None
    cov = sum((x - ma) * (y - mb) for x, y in zip(ar, br))
    return cov / math.sqrt(va * vb)


def fetch_extra_raw(end_date: date) -> dict[str, list[tuple[date, float]]]:
    query = urllib.parse.urlencode({"symbols": ",".join(EXTRA_QUERY_SYMBOLS), "period": "all"})
    with urllib.request.urlopen(f"{API_URL}?{query}", timeout=90) as response:
        payload = json.load(response)
    if not payload.get("success"):
        raise RuntimeError(f"history API failed: {payload!r}")
    out: dict[str, list[tuple[date, float]]] = {}
    for item in payload["series"]:
        symbol = ALIASES.get(str(item["symbol"]), str(item["symbol"]))
        rows: dict[date, float] = {}
        for date_text, price in zip(item["dates"], item["prices"]):
            day = parse_date(date_text)
            if day > end_date:
                continue
            if isinstance(price, (int, float)) and math.isfinite(price) and price > 0:
                rows[day] = float(price)
        if rows:
            out[symbol] = sorted(rows.items())
    return out


def align_extra_series(env: s30.BacktestEnv) -> dict[str, list[float]]:
    prices = {symbol: list(values) for symbol, values in env.prices_by_symbol.items()}
    raw = fetch_extra_raw(env.dates[-1])
    fx = raw[app.USD_FX_SYMBOL]
    for symbol in EXTRA_SYMBOLS:
        pts = raw.get(symbol)
        if not pts:
            continue
        point_dates = [day for day, _price in pts]
        series: list[float] = []
        for day in env.dates:
            point_index = bisect.bisect_right(point_dates, day) - 1
            if point_index < 0:
                series.append(0.0)
                continue
            source_day, price = pts[point_index]
            if (day - source_day).days > app.MAX_FORWARD_FILL_CALENDAR_DAYS:
                series.append(series[-1] if series else 0.0)
                continue
            if symbol in USD_ASSETS:
                fx_rate = app.price_on_or_before(fx, day)
                if fx_rate is None or fx_rate <= 0:
                    series.append(series[-1] if series else 0.0)
                    continue
                price = price / fx_rate if fx_rate < 1 else price * fx_rate if fx_rate <= 20 else math.nan
            series.append(price)
        if any(not math.isfinite(value) for value in series):
            raise RuntimeError(f"bad aligned data for {symbol}")
        prices[symbol] = series
    return prices


def build_env() -> s30.BacktestEnv:
    current = s30.s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
    breadth = s30.s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
    return s30.build_env(base.EngineContext(current=current, breadth=breadth))


def equity_stress(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    weak = 0
    for symbol in ["nasdaq", "sp500", "shanghai_composite"]:
        prices = prices_by_symbol[symbol]
        mom60 = momentum(prices, index, 60)
        ma120 = moving_average(prices, index, 120)
        if mom60 is None or ma120 is None or mom60 < 0 or prices[index] < ma120:
            weak += 1
    return weak >= 2


def china_bubble_rollover(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    checks = []
    for symbol in ["shanghai_composite", "shenzhen_component", "chinext"]:
        prices = prices_by_symbol.get(symbol)
        if not prices:
            continue
        mom240 = momentum(prices, index, 240)
        mom20 = momentum(prices, index, 20)
        dd40 = rolling_drawdown(prices, index, 40)
        dd60 = rolling_drawdown(prices, index, 60)
        ma60 = moving_average(prices, index, 60)
        if mom240 is None or mom20 is None or dd40 is None or dd60 is None or ma60 is None:
            continue
        hot_then_breaking = mom240 > 0.35 and (mom20 < -0.025 or dd40 < -0.07 or prices[index] < ma60)
        hard_break = dd60 < -0.12 and mom20 < 0
        checks.append(hot_then_breaking or hard_break)
    return sum(1 for item in checks if item) >= 1


def china_repair_complete(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    strong = 0
    for symbol in ["shanghai_composite", "shenzhen_component"]:
        prices = prices_by_symbol[symbol]
        mom60 = momentum(prices, index, 60)
        mom120 = momentum(prices, index, 120)
        ma120 = moving_average(prices, index, 120)
        if mom60 is not None and mom120 is not None and ma120 is not None and mom60 > 0.04 and mom120 > 0.02 and prices[index] > ma120:
            strong += 1
    return strong >= 2


def core_proxy(prices_by_symbol: dict[str, list[float]], weights: dict[str, float], index: int, lookback: int) -> list[float] | None:
    symbols = [symbol for symbol, weight in weights.items() if weight > 0 and symbol in prices_by_symbol]
    if not symbols or index - lookback < 0:
        return None
    proxy: list[float] = []
    for cursor in range(index - lookback, index + 1):
        total = 0.0
        valid = False
        for symbol in symbols:
            price = prices_by_symbol[symbol][cursor]
            base_price = prices_by_symbol[symbol][index - lookback]
            if price <= 0 or base_price <= 0:
                continue
            total += weights[symbol] * price / base_price
            valid = True
        proxy.append(total if valid else 0.0)
    return proxy if all(value > 0 for value in proxy) else None


def satellite_scores(
    prices_by_symbol: dict[str, list[float]],
    index: int,
    current_weights: dict[str, float],
    corr_cap: float | None,
) -> list[tuple[float, str]]:
    scored: list[tuple[float, str]] = []
    proxy = core_proxy(prices_by_symbol, current_weights, index, 90)
    for symbol in EXTRA_SYMBOLS:
        prices = prices_by_symbol.get(symbol)
        if not prices:
            continue
        mom60 = momentum(prices, index, 60)
        mom120 = momentum(prices, index, 120)
        mom240 = momentum(prices, index, 240)
        ma120 = moving_average(prices, index, 120)
        vol60 = annual_vol(prices, index, 60)
        dd60 = rolling_drawdown(prices, index, 60)
        dd120 = rolling_drawdown(prices, index, 120)
        if None in (mom60, mom120, mom240, ma120, vol60, dd60, dd120):
            continue
        assert mom60 is not None and mom120 is not None and mom240 is not None
        assert ma120 is not None and vol60 is not None and dd60 is not None and dd120 is not None
        if mom60 <= 0 or mom120 <= 0 or prices[index] < ma120:
            continue
        if vol60 > 0.46 or dd60 < -0.11 or dd120 < -0.18:
            continue
        corr_penalty = 0.0
        if corr_cap is not None and proxy is not None:
            corr = rolling_corr(prices[index - 90 : index + 1], proxy, 90, 60)
            if corr is not None and corr > corr_cap:
                continue
            corr_penalty = max(corr or 0.0, 0.0) * 0.15
        score = (mom120 + 0.45 * mom60 + 0.2 * max(mom240, -0.2) + max(dd60, -0.3) * 0.20) / max(vol60, 0.05)
        score -= corr_penalty
        if symbol in {"shenzhen_component", "chinext"} and china_bubble_rollover(prices_by_symbol, index):
            continue
        if score > 0:
            scored.append((score, symbol))
    scored.sort(reverse=True)
    return scored


def add_satellite(
    weights: dict[str, float],
    spec: Candidate,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    signal_month: int,
) -> dict[str, float]:
    if spec.satellite_cap <= 0:
        return weights
    if "skip_weak_months" in spec.mode and signal_month in {2, 6, 8, 9, 10}:
        return weights
    if "risk_clean" in spec.mode and equity_stress(prices_by_symbol, signal_index):
        return weights
    scored = satellite_scores(prices_by_symbol, signal_index, weights, spec.corr_cap)
    if not scored:
        return weights
    selected = scored[: spec.top_count]
    score_total = sum(score for score, _symbol in selected)
    available = min(max(0.0, 1.0 - total_weight(weights)), spec.satellite_cap)
    if available <= 0 or score_total <= 0:
        return weights
    out = dict(weights)
    for score, symbol in selected:
        addition = min(spec.per_asset_cap, available * score / score_total)
        out[symbol] = out.get(symbol, 0.0) + addition
    return normalize(out)


def apply_china_lock(
    weights: dict[str, float],
    spec: Candidate,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    state: dict[str, int],
) -> dict[str, float]:
    if "cn_lock" not in spec.mode:
        return weights
    if china_bubble_rollover(prices_by_symbol, signal_index):
        state["cn_lock_until"] = max(state.get("cn_lock_until", -1), signal_index + 180)
    if state.get("cn_lock_until", -1) >= signal_index and not china_repair_complete(prices_by_symbol, signal_index):
        capped = scale_group(weights, CHINA_EQUITIES, 0.15 if "soft" in spec.mode else 0.0)
        removed = total_weight(weights) - total_weight(capped)
        if removed > 0 and "redeploy_gold" in spec.mode:
            gold = prices_by_symbol["gold_cny"]
            mom60 = momentum(gold, signal_index, 60)
            ma90 = moving_average(gold, signal_index, 90)
            if mom60 is not None and ma90 is not None and mom60 > -0.01 and gold[signal_index] >= ma90:
                capped["gold_cny"] = capped.get("gold_cny", 0.0) + removed * 0.65
        return normalize(capped)
    return weights


def run_candidate(spec: Candidate, env: s30.BacktestEnv, prices_by_symbol: dict[str, list[float]]) -> SimResult:
    dates = env.dates
    config = env.config
    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [symbol for symbol in env.symbols if symbol not in config.signal_only_symbols]
    tradable_symbols += [symbol for symbol in EXTRA_SYMBOLS if symbol in prices_by_symbol]
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    targets_by_index: dict[int, dict[str, float]] = {}
    state: dict[str, int] = {"cn_lock_until": -1}
    smooth_budget = s30.BudgetSpec("satellite_smooth", "Satellite plus smooth risk budget", 90, 0.012, 0.045, 0.50, "profit_lock")

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, env.meta_traces) if config.meta_switch else {}
        champion = env.champion_overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        if "smooth_before" in spec.mode:
            champion = s30.apply_budget(champion, smooth_budget, signal_index, values_by_index)
        target = apply_china_lock(champion, spec, prices_by_symbol, signal_index, state)
        target = add_satellite(target, spec, prices_by_symbol, signal_index, dates[signal_index].month)
        if "smooth_after" in spec.mode:
            target = s30.apply_budget(target, smooth_budget, signal_index, values_by_index)
        return normalize(target)

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            targets = normalize(targets)
            targets_by_index[index] = dict(targets)
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
    return SimResult(
        result=app.BacktestResult(
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
        ),
        targets_by_index=targets_by_index,
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


def exposure_summary(targets_by_index: dict[int, dict[str, float]]) -> dict[str, float]:
    if not targets_by_index:
        return {}
    totals: dict[str, float] = {}
    for weights in targets_by_index.values():
        for symbol, weight in weights.items():
            totals[symbol] = totals.get(symbol, 0.0) + weight
    count = len(targets_by_index)
    return {symbol: value / count for symbol, value in sorted(totals.items()) if value / count > 0.005}


def row_for(spec: Candidate, sim: SimResult) -> dict[str, Any]:
    result = sim.result
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "satellite_cap": spec.satellite_cap,
            "per_asset_cap": spec.per_asset_cap,
            "top_count": spec.top_count,
            "mode": spec.mode,
            "corr_cap": spec.corr_cap,
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
        "avg_exposure": exposure_summary(sim.targets_by_index),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-10:]],
    }


def candidates() -> list[Candidate]:
    out = [
        Candidate("baseline_one_way", "Current champion reproduced in this spike.", 0.0, 0.0, 0, "baseline"),
    ]
    modes = [
        "risk_clean",
        "risk_clean_skip_weak_months",
        "cn_lock_redeploy_gold_risk_clean",
        "cn_lock_redeploy_gold_risk_clean_skip_weak_months",
        "cn_lock_soft_redeploy_gold_risk_clean",
        "cn_lock_redeploy_gold_risk_clean_smooth_after",
        "cn_lock_redeploy_gold_risk_clean_smooth_before",
    ]
    for mode in modes:
        for cap in [0.10, 0.15, 0.25, 0.35]:
            for per_asset in [0.08, 0.10, 0.15]:
                for top_count in [1, 2, 3]:
                    for corr_cap in [None, 0.45]:
                        if cap == 0:
                            continue
                        name = f"{mode}_cap{int(cap*100)}_per{int(per_asset*100)}_top{top_count}"
                        if corr_cap is not None:
                            name += f"_corr{int(corr_cap*100)}"
                        out.append(
                            Candidate(
                                name,
                                "Crash-aware core plus optional cross-asset opportunity satellite.",
                                cap,
                                per_asset,
                                top_count,
                                mode,
                                corr_cap,
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
        prices_by_symbol = align_extra_series(env)
        rows = [row_for(spec, run_candidate(spec, env, prices_by_symbol)) for spec in candidates()]
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
