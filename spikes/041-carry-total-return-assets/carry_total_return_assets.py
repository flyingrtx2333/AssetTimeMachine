#!/usr/bin/env python3
"""Carry / total-return asset tests for the current champion.

No leverage, no shorting, no BTC.  This spike tests whether long-history,
real total-return/carry assets can provide the missing Sharpe improvement:

- QQQ/SPY adjusted close can replace Nasdaq/S&P price indices as tradable
  total-return proxies.
- Vanguard Treasury mutual funds (VUSTX/VFITX/VFISX) can use idle cash only.

Any passing candidate still needs product data-source work before app release.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone
import bisect
import json
import math
from pathlib import Path
import sys
import urllib.parse
import urllib.request
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

CACHE_DIRS = [Path("/tmp/atm_crisis_payoff_cache"), Path("/tmp")]
YAHOO_SYMBOLS = {
    "qqq": "QQQ",
    "spy": "SPY",
    "vustx": "VUSTX",
    "vfitx": "VFITX",
    "vfisx": "VFISX",
}
FUND_SYMBOLS = ["vustx", "vfitx", "vfisx"]
FUND_LABELS = {
    "vustx": "Vanguard Long-Term Treasury Fund",
    "vfitx": "Vanguard Intermediate-Term Treasury Fund",
    "vfisx": "Vanguard Short-Term Treasury Fund",
}
CORE_CONTEXT_CACHE: dict[
    tuple[str, str],
    tuple[
        list[date],
        dict[str, list[float]],
        list[str],
        app.Config,
        dict[str, app.SimulatedTrace],
        Any,
        dict[str, list[tuple[date, float]]],
    ],
] = {}


@dataclass(frozen=True)
class CarrySpec:
    name: str
    thesis: str
    proxy: str
    mode: str
    cap: float
    per_asset_cap: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def parse_date(text: str) -> date:
    return datetime.strptime(text[:10], "%Y-%m-%d").date()


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(clean)
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def cache_candidates(symbol: str) -> list[Path]:
    yahoo = YAHOO_SYMBOLS[symbol]
    safe = urllib.parse.quote(yahoo, safe="")
    return [
        Path("/tmp/atm_crisis_payoff_cache") / f"yahoo_{safe}_adj.json",
        Path("/tmp") / f"atm_yahoo_fund_{yahoo}.json",
        Path("/tmp") / f"atm_yahoo_active_{yahoo}.json",
        Path("/tmp") / f"atm_alt_probe2_{yahoo}.json",
        Path("/tmp") / f"atm_cashplus_{yahoo}.json",
    ]


def fetch_yahoo_adjusted(symbol: str) -> list[tuple[date, float]]:
    for path in cache_candidates(symbol):
        if path.exists():
            raw = json.loads(path.read_text())
            return [(date.fromisoformat(day), float(price)) for day, price in raw if float(price) > 0]

    yahoo = YAHOO_SYMBOLS[symbol]
    p1 = int(datetime(1999, 1, 1, tzinfo=timezone.utc).timestamp())
    p2 = int(datetime(2026, 6, 24, tzinfo=timezone.utc).timestamp())
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(yahoo, safe='')}?period1={p1}&period2={p2}"
        "&interval=1d&events=history&includeAdjustedClose=true"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as response:
        payload = json.load(response)
    error = payload.get("chart", {}).get("error")
    if error:
        raise RuntimeError(f"Yahoo error for {yahoo}: {error}")
    result = payload["chart"]["result"][0]
    timestamps = result.get("timestamp") or []
    quote = result["indicators"]["quote"][0]
    adjusted = result["indicators"].get("adjclose", [{}])[0].get("adjclose") or quote["close"]
    rows: list[tuple[date, float]] = []
    for timestamp, price in zip(timestamps, adjusted):
        if price is None or not math.isfinite(float(price)) or float(price) <= 0:
            continue
        rows.append((datetime.fromtimestamp(timestamp, timezone.utc).date(), float(price)))
    cache_path = Path("/tmp/atm_crisis_payoff_cache") / f"yahoo_{urllib.parse.quote(yahoo, safe='')}_adj.json"
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps([(day.isoformat(), price) for day, price in rows]))
    return rows


def price_on_or_before(points: list[tuple[date, float]], target: date, max_gap_days: int = 30) -> float | None:
    idx = bisect.bisect_right(points, (target, float("inf"))) - 1
    if idx < 0:
        return None
    day, price = points[idx]
    if (target - day).days > max_gap_days:
        return None
    return price


def cny_per_usd_from_fx(fx: float) -> float | None:
    if not math.isfinite(fx) or fx <= 0:
        return None
    return 1.0 / fx if fx < 1 else fx if fx <= 20 else None


def convert_usd_points_to_cny(points: list[tuple[date, float]], fx_points: list[tuple[date, float]]) -> list[tuple[date, float]]:
    out: list[tuple[date, float]] = []
    for day, price in points:
        fx = price_on_or_before(fx_points, day, 30)
        cny_per_usd = cny_per_usd_from_fx(fx) if fx is not None else None
        if cny_per_usd is not None:
            out.append((day, price * cny_per_usd))
    return out


def raw_with_proxy(
    proxy: str,
    end_date: date | None = None,
    base_fetch: Any | None = None,
) -> dict[str, list[tuple[date, float]]]:
    fetch = base_fetch or app.fetch_public_history
    raw = fetch(end_date=end_date)
    if proxy in {"qqq", "qqq_spy"}:
        raw["nasdaq"] = fetch_yahoo_adjusted("qqq")
    if proxy in {"spy", "qqq_spy"}:
        raw["sp500"] = fetch_yahoo_adjusted("spy")
    if end_date is not None:
        raw = {symbol: [(day, price) for day, price in rows if day <= end_date] for symbol, rows in raw.items()}
    return raw


def align_extra_cny_series(dates: list[date], raw: dict[str, list[tuple[date, float]]]) -> dict[str, list[float]]:
    fx = raw[app.USD_FX_SYMBOL]
    out: dict[str, list[float]] = {}
    for symbol in FUND_SYMBOLS:
        cny_points = convert_usd_points_to_cny(fetch_yahoo_adjusted(symbol), fx)
        series: list[float] = []
        for day in dates:
            price = price_on_or_before(cny_points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
            series.append(price if price is not None else 0.0)
        out[symbol] = series
    return out


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1 : index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    previous = values[index - lookback]
    if previous <= 0 or values[index] <= 0:
        return None
    return values[index] / previous - 1


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


def equity_stress(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    weak = 0
    for symbol in ["nasdaq", "sp500"]:
        prices = prices_by_symbol[symbol]
        mom60 = momentum(prices, index, 60)
        ma120 = moving_average(prices, index, 120)
        if mom60 is None or ma120 is None or mom60 < 0 or prices[index] < ma120:
            weak += 1
    return weak >= 1


def fund_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, risk_off: bool) -> float | None:
    values = prices_by_symbol[symbol]
    mom60 = momentum(values, index, 60)
    mom120 = momentum(values, index, 120)
    ma120 = moving_average(values, index, 120)
    vol60 = annual_vol(values, index, 60)
    dd60 = rolling_drawdown(values, index, 60)
    if mom60 is None or mom120 is None or ma120 is None or vol60 is None or dd60 is None:
        return None
    if values[index] < ma120 or dd60 < -0.035:
        return None
    if symbol == "vustx" and not risk_off and dd60 < -0.015:
        return None
    if mom60 < -0.003 or mom120 < -0.006:
        return None
    duration_bonus = {"vfisx": 0.00, "vfitx": 0.005, "vustx": 0.012 if risk_off else -0.004}[symbol]
    score = (mom120 + 0.5 * mom60 + duration_bonus) / max(vol60, 0.01)
    return score if score > 0 else None


def carry_target(
    base_target: dict[str, float],
    spec: CarrySpec,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    portfolio_values: list[float],
) -> dict[str, float]:
    if spec.cap <= 0:
        return base_target
    available = min(max(0.0, 1.0 - total_weight(base_target)), spec.cap)
    if available <= 0:
        return base_target
    risk_off = equity_stress(prices_by_symbol, signal_index)
    if spec.mode == "risk_off_duration" and not risk_off:
        return base_target
    if spec.mode == "curve_dd_duration":
        clean = [value for value in portfolio_values[: signal_index + 1] if value > 0]
        if clean:
            peak = max(clean[-90:])
            risk_off = risk_off or (clean[-1] / peak - 1 if peak > 0 else 0.0) < -0.02
        if not risk_off:
            return base_target

    symbols = ["vfisx", "vfitx", "vustx"]
    if spec.mode == "short_only":
        symbols = ["vfisx"]
    if spec.mode in {"risk_off_duration", "curve_dd_duration"}:
        symbols = ["vfitx", "vustx", "vfisx"]
    scored: list[tuple[float, str]] = []
    for symbol in symbols:
        score = fund_score(prices_by_symbol, symbol, signal_index, risk_off)
        if score is not None:
            scored.append((score, symbol))
    if not scored:
        return base_target
    scored.sort(reverse=True)
    selected = scored[:2 if spec.mode == "balanced_carry" else 1]
    score_total = sum(score for score, _symbol in selected)
    out = dict(base_target)
    for score, symbol in selected:
        addition = min(spec.per_asset_cap, available * score / score_total)
        out[symbol] = out.get(symbol, 0.0) + addition
    return normalize(out)


def build_core_context(proxy: str, end_date: date | None) -> tuple[list[date], dict[str, list[float]], list[str], app.Config, dict[str, app.SimulatedTrace], Any, dict[str, list[tuple[date, float]]]]:
    original_fetch = app.fetch_public_history
    raw = raw_with_proxy(proxy, end_date=end_date, base_fetch=original_fetch)
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [series.symbol for series in prepared]
    config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")

    def patched_fetch(end_date: date | None = None):
        return raw_with_proxy(proxy, end_date=end_date, base_fetch=original_fetch)

    app.fetch_public_history = patched_fetch  # type: ignore[assignment]
    try:
        current = app.run_strategy("coreGoldSatelliteGoldHandoffMomentum", end_date=end_date)
        breadth = app.run_strategy("coreGoldSatelliteEquityBreadthMomentum", end_date=end_date)
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    meta_traces = {
        config.meta_switch.default_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.default_mode)),
        config.meta_switch.defensive_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.defensive_mode)),
    }
    overlay = app._one_way_vol_managed_overlay(current, breadth)(app._overlay_gold_rollover_cap(app.apply_gold_satellite_overlay))
    return dates, prices_by_symbol, symbols, config, meta_traces, overlay, raw


def cached_core_context(proxy: str, end_date: date | None):
    key = (proxy, end_date.isoformat() if end_date else "")
    if key not in CORE_CONTEXT_CACHE:
        CORE_CONTEXT_CACHE[key] = build_core_context(proxy, end_date)
    return CORE_CONTEXT_CACHE[key]


def run_carry_strategy(spec: CarrySpec, end_date: date | None = app.parse_date("2026-06-23")) -> app.BacktestResult:
    dates, core_prices, symbols, config, meta_traces, overlay, raw = cached_core_context(spec.proxy, end_date)
    fund_prices = align_extra_cny_series(dates, raw)
    prices_by_symbol = {**core_prices, **fund_prices}
    tradable_symbols = [symbol for symbol in symbols if symbol not in config.signal_only_symbols] + FUND_SYMBOLS

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    targets_by_index: dict[int, dict[str, float]] = {}

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces) if config.meta_switch else {}
        champion = overlay(raw_weights or {}, signal_index, dates[signal_index], core_prices, values_by_index, config)
        return carry_target(champion, spec, prices_by_symbol, signal_index, values_by_index)

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = normalize(target_weights(signal_index, index) if signal_index >= 0 else {})
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


def row_for(spec: CarrySpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "proxy": spec.proxy,
            "mode": spec.mode,
            "cap": spec.cap,
            "per_asset_cap": spec.per_asset_cap,
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
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-10:]],
    }


def specs() -> list[CarrySpec]:
    out: list[CarrySpec] = []
    for proxy in ["index", "qqq", "spy", "qqq_spy"]:
        out.append(CarrySpec(f"{proxy}_baseline", "Current champion under this market-data proxy.", proxy, "none", 0.0, 0.0))
        for mode in ["short_only", "balanced_carry", "risk_off_duration", "curve_dd_duration"]:
            for cap in [0.15, 0.30, 0.50, 1.00]:
                for per_asset in [0.15, 0.30, 0.50]:
                    if per_asset > cap:
                        continue
                    out.append(
                        CarrySpec(
                            f"{proxy}_{mode}_cap{int(cap*100)}_per{int(per_asset*100)}",
                            "Use idle cash for long-history Treasury total-return/carry funds.",
                            proxy,
                            mode,
                            cap,
                            per_asset,
                        )
                    )
    return out


def main() -> None:
    rows: list[dict[str, Any]] = []
    errors: dict[str, str] = {}
    for spec in specs():
        try:
            rows.append(row_for(spec, run_carry_strategy(spec)))
        except Exception as exc:
            errors[spec.name] = repr(exc)
            print(f"ERR {spec.name}: {exc}", flush=True)

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    coverage = {
        symbol: {
            "source": YAHOO_SYMBOLS[symbol],
            "label": FUND_LABELS.get(symbol, YAHOO_SYMBOLS[symbol]),
            "start": fetch_yahoo_adjusted(symbol)[0][0].isoformat(),
            "end": fetch_yahoo_adjusted(symbol)[-1][0].isoformat(),
            "count": len(fetch_yahoo_adjusted(symbol)),
        }
        for symbol in ["qqq", "spy", *FUND_SYMBOLS]
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "coverage": coverage, "errors": errors, "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows[:40]:
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
