#!/usr/bin/env python3
"""Offensive total-return source search under 1% fee.

No leverage, no shorting, no BTC. This spike asks whether high-return sector /
technology total-return assets plus an income ballast can beat the current
1%-fee App core on Sharpe without collapsing annualized return.

External Yahoo adjusted-close assets are converted to CNY with the App's
usd_per_cny history. Passing candidates are research-only until backend data
support exists.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone
import itertools
import json
import math
from pathlib import Path
import sys
import urllib.parse
import urllib.request
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402


def load_module(name: str, path: Path) -> Any:
    import importlib.util

    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


carry = load_module("atm_spike041_carry_for_068", ROOT / "spikes/041-carry-total-return-assets/carry_total_return_assets.py")

END_DATE = "2026-06-23"
START_DATE = app.parse_date("2005-01-03")
FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005
INITIAL = 100_000.0
YAHOO_CACHE = Path("/tmp/atm_spike068_yahoo_cache")

INCOME_ASSETS = ["OSTIX", "PIMIX", "PONAX", "DODIX", "PTTRX", "VWINX"]
RISK_ASSETS = [
    "CORE",
    "QQQ",
    "XLK",
    "SMH",
    "SOXX",
    "GLD",
    "IAU",
    "SPY",
    "XLY",
    "XLV",
    "XLP",
    "XLU",
    "PRWCX",
    "FPACX",
    "gold_cny",
]
ROUTER_RISK_ASSETS = ["QQQ", "XLK", "SMH", "SOXX", "GLD", "SPY", "XLY", "XLV", "XLP", "XLU"]
ROUTER_SAFE_ASSETS = ["OSTIX", "PIMIX", "DODIX", "PTTRX", "gold_cny"]


@dataclass(frozen=True)
class RouterSpec:
    name: str
    risk_assets: tuple[str, ...]
    safe_assets: tuple[str, ...]
    rebalance_sessions: int
    top_n: int
    gross: float
    safe_gross: float
    lookback_fast: int
    lookback_slow: int
    ma_period: int
    band: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def fetch_yahoo_adjusted(symbol: str) -> list[tuple[date, float]]:
    cache_path = YAHOO_CACHE / f"{urllib.parse.quote(symbol, safe='')}.json"
    if cache_path.exists():
        raw = json.loads(cache_path.read_text())
        return [(date.fromisoformat(day), float(price)) for day, price in raw if float(price) > 0]

    p1 = int(datetime(1999, 1, 1, tzinfo=timezone.utc).timestamp())
    p2 = int(datetime(2026, 6, 24, tzinfo=timezone.utc).timestamp())
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(symbol, safe='')}?period1={p1}&period2={p2}"
        "&interval=1d&events=history&includeAdjustedClose=true"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as response:
        payload = json.load(response)
    error = payload.get("chart", {}).get("error")
    if error:
        raise RuntimeError(f"Yahoo error for {symbol}: {error}")
    result = payload["chart"]["result"][0]
    timestamps = result.get("timestamp") or []
    quote = result["indicators"]["quote"][0]
    adjusted = result["indicators"].get("adjclose", [{}])[0].get("adjclose") or quote["close"]
    rows: list[tuple[date, float]] = []
    for timestamp, price in zip(timestamps, adjusted):
        if price is None or not math.isfinite(float(price)) or float(price) <= 0:
            continue
        rows.append((datetime.fromtimestamp(timestamp, timezone.utc).date(), float(price)))
    YAHOO_CACHE.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps([(day.isoformat(), price) for day, price in rows]))
    return rows


def load_series() -> tuple[list[date], dict[str, list[float | None]], dict[str, Any]]:
    core = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=END_DATE, start_date=START_DATE.isoformat())
    raw = app.fetch_public_history(end_date=app.parse_date(END_DATE))
    dates = core.dates
    series: dict[str, list[float | None]] = {"CORE": [float(value) for value in core.values]}
    coverage: dict[str, Any] = {
        "CORE": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "count": len(dates), "source": "App-equivalent current core"},
    }

    all_yahoo = sorted(set(INCOME_ASSETS + [asset for asset in RISK_ASSETS if asset not in {"CORE", "gold_cny"}] + ROUTER_RISK_ASSETS))
    for symbol in all_yahoo:
        cny_points = carry.convert_usd_points_to_cny(fetch_yahoo_adjusted(symbol), raw[app.USD_FX_SYMBOL])
        out: list[float | None] = []
        first_price: float | None = None
        valid_days = []
        for day in dates:
            price = carry.price_on_or_before(cny_points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
            if price is None:
                out.append(None)
                continue
            if first_price is None:
                first_price = price
            valid_days.append(day)
            out.append(INITIAL * (1 - FEE_RATE) * price / first_price)
        series[symbol] = out
        coverage[symbol] = {
            "start": valid_days[0].isoformat() if valid_days else None,
            "end": valid_days[-1].isoformat() if valid_days else None,
            "count": len(valid_days),
            "source": f"Yahoo adjusted close {symbol}, CNY converted",
        }

    prepared = app.prepare_series(raw)
    raw_dates, raw_prices = app.align_rotation_price_series(prepared)
    raw_index = {day: index for index, day in enumerate(raw_dates)}
    gold: list[float | None] = []
    first_gold: float | None = None
    for day in dates:
        index = raw_index.get(day)
        price = raw_prices["gold_cny"][index] if index is not None else 0.0
        if price <= 0:
            gold.append(None)
            continue
        if first_gold is None:
            first_gold = price
        gold.append(INITIAL * (1 - FEE_RATE) * price / first_gold)
    series["gold_cny"] = gold
    coverage["gold_cny"] = {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "count": len([v for v in gold if v]), "source": "App public history"}
    return dates, series, coverage


def metrics_from_values(dates: list[date], values: list[float]) -> dict[str, float | None]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "annualized": annualized,
        "max_drawdown": max_dd,
        "annual_volatility": annual_vol,
        "sharpe": sharpe,
        "total": total,
    }


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(dates) if day >= start_date), None)
    if index is None or index >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    return metrics_from_values(dates[index:], values[index:])


def valid_aligned(dates: list[date], series: dict[str, list[float | None]], assets: list[str]) -> tuple[list[date], dict[str, list[float]]]:
    indices = [
        index
        for index, _day in enumerate(dates)
        if all(series[asset][index] is not None and float(series[asset][index] or 0) > 0 for asset in assets)
    ]
    if len(indices) < 252 * 8:
        raise RuntimeError(f"not enough aligned data for {assets}")
    aligned_dates = [dates[index] for index in indices]
    aligned = {asset: [float(series[asset][index] or 0.0) for index in indices] for asset in assets}
    return aligned_dates, aligned


def weight_vectors(count: int, total_steps: int = 10) -> list[tuple[float, ...]]:
    rows: list[tuple[float, ...]] = []

    def rec(left_count: int, remaining: int, prefix: tuple[int, ...]) -> None:
        if left_count == 1:
            rows.append(tuple([*prefix, remaining / total_steps]))
            return
        for step in range(remaining + 1):
            rec(left_count - 1, remaining - step, (*prefix, step / total_steps))

    rec(count, total_steps, ())
    return rows


def static_blend_search(dates: list[date], series: dict[str, list[float | None]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    base_income = ["OSTIX"]
    candidate_risks = [asset for asset in RISK_ASSETS if asset != "OSTIX"]
    weight_cache: dict[int, list[tuple[float, ...]]] = {}

    for risk_count in [1, 2]:
        for risks in itertools.combinations(candidate_risks, risk_count):
            assets = [*base_income, *risks]
            try:
                aligned_dates, aligned = valid_aligned(dates, series, assets)
            except RuntimeError:
                continue
            if len(aligned_dates) == 0 or aligned_dates[0] > START_DATE:
                # Keep comparison anchored to the same 2005+ horizon.
                continue
            weights = weight_cache.setdefault(len(assets), weight_vectors(len(assets), 10))
            for current_weights in weights:
                if current_weights[0] < 0.30 or max(current_weights[1:]) < 0.10:
                    continue
                if any(weight <= 0 for weight in current_weights[1:]):
                    continue
                values = [
                    sum(current_weights[cursor] * aligned[asset][index] for cursor, asset in enumerate(assets))
                    for index in range(len(aligned_dates))
                ]
                full = metrics_from_values(aligned_dates, values)
                rows.append(
                    {
                        "name": "static_" + "_".join(assets),
                        "weights": {asset: float(current_weights[cursor]) for cursor, asset in enumerate(assets) if current_weights[cursor] > 0},
                        "full": full,
                        "slices": {
                            "post_2020": slice_metrics(aligned_dates, values, "2020-01-01"),
                            "last_10y": slice_metrics(aligned_dates, values, "2016-06-23"),
                            "post_2024": slice_metrics(aligned_dates, values, "2024-01-01"),
                        },
                    }
                )
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)
    return rows


def rolling_ma(values: list[float | None], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1 : index + 1]
    if any(value is None or value <= 0 for value in window):
        return None
    return sum(float(value) for value in window) / period


def momentum(values: list[float | None], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    current = values[index]
    previous = values[index - lookback]
    if current is None or previous is None or current <= 0 or previous <= 0:
        return None
    return current / previous - 1


def annual_vol(values: list[float | None], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        previous = values[cursor - 1]
        current = values[cursor]
        if previous is None or current is None or previous <= 0 or current <= 0:
            return None
        returns.append(math.log(current / previous))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def rolling_drawdown(values: list[float | None], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1 : index + 1]
    if any(value is None or value <= 0 for value in window):
        return None
    current = float(window[-1])
    peak = max(float(value) for value in window if value is not None)
    return current / peak - 1 if peak > 0 else None


def router_specs() -> list[RouterSpec]:
    out: list[RouterSpec] = []
    risk_sets = [
        ("QQQ", "XLK", "SMH", "SOXX", "GLD"),
        ("QQQ", "XLK", "SMH", "SOXX", "XLY", "XLV", "XLP", "XLU", "GLD"),
        ("QQQ", "XLK", "SMH", "SOXX", "XLY", "XLV", "XLP", "XLU", "SPY", "GLD"),
    ]
    safe_sets = [
        ("OSTIX",),
        ("OSTIX", "PIMIX", "DODIX"),
        ("OSTIX", "DODIX", "PTTRX"),
        ("OSTIX", "gold_cny"),
    ]
    for risks in risk_sets:
        for safes in safe_sets:
            for rebalance in [42, 63]:
                for top_n in [1, 2, 3]:
                    for gross in [0.70, 0.85, 1.00]:
                        out.append(
                            RouterSpec(
                                name=f"router_r{len(risks)}_s{len(safes)}_rb{rebalance}_top{top_n}_g{int(gross*100)}",
                                risk_assets=risks,
                                safe_assets=safes,
                                rebalance_sessions=rebalance,
                                top_n=top_n,
                                gross=gross,
                                safe_gross=min(gross, 0.85),
                                lookback_fast=63,
                                lookback_slow=126,
                                ma_period=120,
                                band=0.08,
                            )
                        )
    return out


def simulate_router(spec: RouterSpec, dates: list[date], series: dict[str, list[float | None]]) -> dict[str, Any]:
    tradable = sorted(set(spec.risk_assets + spec.safe_assets))
    cash = INITIAL
    units = {symbol: 0.0 for symbol in tradable}
    values: list[float] = []
    trades = 0
    last_rebalance = -10**9

    start_index = next(index for index, day in enumerate(dates) if day >= START_DATE)

    def price(symbol: str, index: int) -> float:
        value = series[symbol][index]
        return float(value or 0.0)

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * price(symbol, index) for symbol in tradable)

    for index in range(start_index, len(dates)):
        if index > start_index and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index > start_index and index - last_rebalance >= spec.rebalance_sessions:
            signal_index = index - 1
            scored: list[tuple[float, str]] = []
            for symbol in spec.risk_assets:
                p = price(symbol, signal_index)
                ma_value = rolling_ma(series[symbol], signal_index, spec.ma_period)
                fast = momentum(series[symbol], signal_index, spec.lookback_fast)
                slow = momentum(series[symbol], signal_index, spec.lookback_slow)
                vol = annual_vol(series[symbol], signal_index, 60)
                dd60 = rolling_drawdown(series[symbol], signal_index, 60)
                if p <= 0 or ma_value is None or fast is None or slow is None or vol is None or dd60 is None:
                    continue
                if p < ma_value or fast < -0.01 or slow < 0 or dd60 < -0.18:
                    continue
                scored.append(((slow + 0.5 * fast) / max(vol, 0.03), symbol))
            scored.sort(reverse=True)

            targets: dict[str, float] = {}
            if scored:
                selected = scored[: spec.top_n]
                inv_vol = {symbol: 1 / max(annual_vol(series[symbol], signal_index, 60) or 0.2, 0.05) for _score, symbol in selected}
                total_inv = sum(inv_vol.values())
                for _score, symbol in selected:
                    targets[symbol] = spec.gross * inv_vol[symbol] / total_inv
            else:
                safe_scores: list[tuple[float, str]] = []
                for symbol in spec.safe_assets:
                    p = price(symbol, signal_index)
                    ma_value = rolling_ma(series[symbol], signal_index, 80)
                    mom = momentum(series[symbol], signal_index, 63)
                    vol = annual_vol(series[symbol], signal_index, 60)
                    if p > 0 and ma_value is not None and mom is not None and vol is not None and p > ma_value and mom > -0.005:
                        safe_scores.append(((mom + 0.01) / max(vol, 0.02), symbol))
                safe_scores.sort(reverse=True)
                if safe_scores:
                    targets[safe_scores[0][1]] = spec.safe_gross

            pre_value = portfolio_value(index)
            for symbol in tradable:
                p = price(symbol, index)
                current = units[symbol] * p if p > 0 else 0.0
                target_weight = targets.get(symbol, 0.0)
                if current > 0 and (symbol not in targets or abs(current / pre_value - target_weight) > spec.band):
                    cash += units[symbol] * p * (1 - SLIPPAGE_RATE) * (1 - FEE_RATE)
                    units[symbol] = 0.0
                    trades += 1

            total = portfolio_value(index)
            for symbol, target_weight in targets.items():
                p = price(symbol, index)
                if p <= 0:
                    continue
                current = units[symbol] * p
                if total <= 0 or abs(current / total - target_weight) <= spec.band:
                    continue
                amount = min(cash, max(total * target_weight - current, 0.0))
                if amount > 1:
                    units[symbol] += amount * (1 - FEE_RATE) / (p * (1 + SLIPPAGE_RATE))
                    cash -= amount
                    trades += 1
            last_rebalance = index

        values.append(portfolio_value(index))

    aligned_dates = dates[start_index:]
    full = metrics_from_values(aligned_dates, values)
    return {
        "name": spec.name,
        "spec": spec.__dict__,
        "full": full,
        "slices": {
            "post_2020": slice_metrics(aligned_dates, values, "2020-01-01"),
            "last_10y": slice_metrics(aligned_dates, values, "2016-06-23"),
            "post_2024": slice_metrics(aligned_dates, values, "2024-01-01"),
        },
        "trades": trades,
    }


def router_search(dates: list[date], series: dict[str, list[float | None]]) -> list[dict[str, Any]]:
    rows = [simulate_router(spec, dates, series) for spec in router_specs()]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)
    return rows


def standalone_rows(dates: list[date], series: dict[str, list[float | None]], assets: list[str]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for asset in assets:
        indices = [index for index, day in enumerate(dates) if day >= START_DATE and series[asset][index] is not None and float(series[asset][index] or 0) > 0]
        if len(indices) < 252 * 8:
            continue
        aligned_dates = [dates[index] for index in indices]
        first = float(series[asset][indices[0]] or 0)
        values = [INITIAL * float(series[asset][index] or 0) / first for index in indices]
        rows.append({"asset": asset, "full": metrics_from_values(aligned_dates, values), "start": aligned_dates[0].isoformat(), "end": aligned_dates[-1].isoformat()})
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)
    return rows


def main() -> None:
    dates, series, coverage = load_series()
    standalones = standalone_rows(dates, series, sorted(set(INCOME_ASSETS + RISK_ASSETS + ROUTER_RISK_ASSETS)))
    static_rows = static_blend_search(dates, series)
    router_rows = router_search(dates, series)

    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "fee_rate": FEE_RATE,
                "slippage_rate": SLIPPAGE_RATE,
                "coverage": coverage,
                "standalone": standalones,
                "static_blends": static_rows,
                "routers": router_rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("\nStandalone top")
    for row in standalones[:20]:
        full = row["full"]
        print(f"{row['asset']:8s} {row['start']} ann={pct(full['annualized'])} dd={pct(full['max_drawdown'])} vol={pct(full['annual_volatility'])} sh={full['sharpe']:.4f}")

    print("\nStatic blend top")
    for row in static_rows[:25]:
        full = row["full"]
        slices = row["slices"]
        print(
            f"{row['weights']} | ann={pct(full['annualized'])} dd={pct(full['max_drawdown'])} "
            f"vol={pct(full['annual_volatility'])} sh={full['sharpe']:.4f} "
            f"post2020={pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f}"
        )

    print("\nRouter top")
    for row in router_rows[:25]:
        full = row["full"]
        slices = row["slices"]
        spec = row["spec"]
        print(
            f"{row['name']} risks={len(spec['risk_assets'])} safes={len(spec['safe_assets'])} "
            f"rb={spec['rebalance_sessions']} top={spec['top_n']} gross={spec['gross']} | "
            f"ann={pct(full['annualized'])} dd={pct(full['max_drawdown'])} "
            f"vol={pct(full['annual_volatility'])} sh={full['sharpe']:.4f} "
            f"post2020={pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
