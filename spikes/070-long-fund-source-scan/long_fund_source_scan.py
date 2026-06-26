#!/usr/bin/env python3
"""Long-history active/sector fund source scan under 1% fee.

No leverage, no shorting, no BTC. This is a source-of-return screen:

1. Standalone CNY total-return checks for long-history funds/ETFs/stocks.
2. Static blend ceiling with at least 20% current core and at least 20% OSTIX.

Individual stocks are diagnostic only and should not be treated as an App
strategy candidate without a separate product decision.
"""
from __future__ import annotations

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


carry = load_module("atm_spike041_carry_for_070", ROOT / "spikes/041-carry-total-return-assets/carry_total_return_assets.py")

END_DATE = "2026-06-23"
START_DATE = app.parse_date("2005-01-03")
FEE_RATE = 0.01
INITIAL = 100_000.0
YAHOO_CACHE = Path("/tmp/atm_spike070_yahoo_cache")

SYMBOLS = """
FBGRX FDGRX FCNTX FOCPX FSPTX FSCSX FSELX FBSOX FSHOX FSRPX FSPHX FBIOX FIDSX FCPVX
PRWCX PRMTX PRNHX PRGTX PRHSX TRBCX OTCFX JAGTX JANIX POAGX VPMCX VWUSX VIGRX
VGT VUG VOOG IYW IGM IGV FDN SKYY SOXX SMH QQQ XLK XLY XLV XLP XLU IHI IBB XBI XRT
AAPL MSFT AMZN GOOGL GOOG NVDA COST UNH LLY NVO ASML TSM
OSTIX PIMIX PONAX DODIX PTTRX
""".split()

BLEND_RISK_SYMBOLS = [
    "AAPL",
    "VOOG",
    "NVDA",
    "TSM",
    "COST",
    "GOOG",
    "ASML",
    "FSELX",
    "FDGRX",
    "LLY",
    "QQQ",
    "XLK",
    "SMH",
    "FSPTX",
    "VGT",
    "PRWCX",
    "XLP",
]


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


def performance(dates: list[date], values: list[float]) -> dict[str, float | None]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "annualized": annualized,
        "max_drawdown": max_dd,
        "annual_volatility": annual_vol,
        "sharpe": sharpe,
        "total": total,
    }


def slice_performance(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(dates) if day >= start_date), None)
    if index is None or index >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    return performance(dates[index:], values[index:])


def symbol_series(symbol: str, dates: list[date], fx_points: list[tuple[date, float]]) -> list[float | None]:
    cny_points = carry.convert_usd_points_to_cny(fetch_yahoo_adjusted(symbol), fx_points)
    out: list[float | None] = []
    first_price: float | None = None
    for day in dates:
        if day < START_DATE:
            out.append(None)
            continue
        price = carry.price_on_or_before(cny_points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
        if price is None:
            out.append(None)
            continue
        if first_price is None:
            first_price = price
        out.append(INITIAL * (1 - FEE_RATE) * price / first_price)
    return out


def aligned_values(dates: list[date], series: dict[str, list[float | None]], symbols: list[str], weights: tuple[float, ...]) -> tuple[list[date], list[float]] | None:
    indices = [
        index
        for index, day in enumerate(dates)
        if day >= START_DATE and all(series[symbol][index] is not None and float(series[symbol][index] or 0) > 0 for symbol in symbols)
    ]
    if len(indices) < 252 * 10:
        return None
    aligned_dates = [dates[index] for index in indices]
    values = [
        sum(weights[cursor] * float(series[symbol][index] or 0) for cursor, symbol in enumerate(symbols))
        for index in indices
    ]
    return aligned_dates, values


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


def main() -> None:
    core = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=END_DATE, start_date=START_DATE.isoformat())
    raw = app.fetch_public_history(end_date=app.parse_date(END_DATE))
    dates = core.dates
    series: dict[str, list[float | None]] = {"CORE": [float(value) for value in core.values]}
    errors: dict[str, str] = {}
    for symbol in sorted(set(SYMBOLS + BLEND_RISK_SYMBOLS)):
        try:
            series[symbol] = symbol_series(symbol, dates, raw[app.USD_FX_SYMBOL])
        except Exception as exc:
            errors[symbol] = repr(exc)

    standalone: list[dict[str, Any]] = []
    for symbol, values in series.items():
        if symbol == "CORE":
            valid_indices = list(range(len(dates)))
        else:
            valid_indices = [index for index, value in enumerate(values) if value is not None and value > 0]
        if len(valid_indices) < 252 * 10:
            continue
        aligned_dates = [dates[index] for index in valid_indices]
        first = float(values[valid_indices[0]] or 0)
        aligned_values_only = [INITIAL * float(values[index] or 0) / first for index in valid_indices]
        standalone.append(
            {
                "symbol": symbol,
                "start": aligned_dates[0].isoformat(),
                "end": aligned_dates[-1].isoformat(),
                "full": performance(aligned_dates, aligned_values_only),
                "slices": {
                    "post_2020": slice_performance(aligned_dates, aligned_values_only, "2020-01-01"),
                    "last_10y": slice_performance(aligned_dates, aligned_values_only, "2016-06-23"),
                },
            }
        )
    standalone.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)

    blends: list[dict[str, Any]] = []
    for risk_count in [1, 2]:
        for risk_symbols in itertools.combinations(BLEND_RISK_SYMBOLS, risk_count):
            symbols = ["OSTIX", "CORE", *risk_symbols]
            if any(symbol not in series for symbol in symbols):
                continue
            for weights in weight_vectors(len(symbols), 10):
                if weights[0] < 0.20 or weights[1] < 0.20 or any(weight <= 0 for weight in weights[2:]):
                    continue
                aligned = aligned_values(dates, series, symbols, weights)
                if aligned is None:
                    continue
                aligned_dates, values = aligned
                blends.append(
                    {
                        "weights": {symbol: weights[index] for index, symbol in enumerate(symbols) if weights[index] > 0},
                        "full": performance(aligned_dates, values),
                        "slices": {
                            "post_2020": slice_performance(aligned_dates, values, "2020-01-01"),
                            "last_10y": slice_performance(aligned_dates, values, "2016-06-23"),
                        },
                    }
                )
    blends.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)

    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "fee_rate": FEE_RATE,
                "coverage_start": dates[0].isoformat(),
                "coverage_end": dates[-1].isoformat(),
                "errors": errors,
                "standalone": standalone,
                "static_blends": blends,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("\nStandalone top")
    for row in standalone[:35]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        print(
            f"{row['symbol']:7s} {row['start']} ann={pct(full['annualized'])} dd={pct(full['max_drawdown'])} "
            f"vol={pct(full['annual_volatility'])} sh={full['sharpe']:.4f} post2020={pct(post['annualized'])}/{(post['sharpe'] or 0):.4f}"
        )

    print("\nBlend top")
    for row in blends[:35]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        print(
            f"{row['weights']} | ann={pct(full['annualized'])} dd={pct(full['max_drawdown'])} "
            f"vol={pct(full['annual_volatility'])} sh={full['sharpe']:.4f} post2020={pct(post['annualized'])}/{(post['sharpe'] or 0):.4f}"
        )


if __name__ == "__main__":
    main()
