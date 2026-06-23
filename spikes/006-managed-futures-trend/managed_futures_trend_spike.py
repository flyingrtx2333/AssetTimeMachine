#!/usr/bin/env python3
"""Managed futures / multi-asset time-series trend spike for AssetTimeMachine.

Scope:
- Free real data only: Yahoo continuous futures + FRED 3M T-bill collateral + existing USD/CNY API.
- No parameter grid: two fixed rule sets, both 12-month trend / 63-day vol / monthly rebalance.
- This is a source-of-return screen, not production-grade futures accounting.
"""
from __future__ import annotations

import bisect
import csv
import datetime as dt
import io
import json
import math
import statistics
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

INITIAL = 100_000.0
START_DATE = dt.date(2001, 1, 2)
END_DATE = dt.date.today()
LOOKBACK_DAYS = 252
VOL_DAYS = 63
REBALANCE_DAYS = 21
MAX_FFILL_DAYS = 7
# Conservative futures/friction screen: 5 bps per one-way notional turnover.
# Existing ETF scripts use 15 bps cash trade friction; for futures that would be punitive,
# so results are not yet app-equivalent.
TURNOVER_COST = 0.0005
YAHOO_CHART = "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}"
FRED_CSV = "https://fred.stlouisfed.org/graph/fredgraph.csv?id={series}"
FX_API = "https://api.flyingrtx.com/api/v1/money/public/history"

FUTURES: dict[str, dict[str, str]] = {
    # Equity index
    "ES=F": {"family": "equity", "name": "E-mini S&P 500"},
    "NQ=F": {"family": "equity", "name": "E-mini Nasdaq 100"},
    # Rates
    "ZB=F": {"family": "rates", "name": "30Y Treasury Bond"},
    "ZN=F": {"family": "rates", "name": "10Y Treasury Note"},
    "ZF=F": {"family": "rates", "name": "5Y Treasury Note"},
    "ZT=F": {"family": "rates", "name": "2Y Treasury Note"},
    # FX futures, USD quoted
    "6E=F": {"family": "fx", "name": "EUR/USD future"},
    "6J=F": {"family": "fx", "name": "JPY/USD future"},
    "6B=F": {"family": "fx", "name": "GBP/USD future"},
    "6A=F": {"family": "fx", "name": "AUD/USD future"},
    "6C=F": {"family": "fx", "name": "CAD/USD future"},
    "6S=F": {"family": "fx", "name": "CHF/USD future"},
    # Energy. CL is deliberately not in the simulation universe because Yahoo has negative
    # 2020 front-month prices; percentage-return tests are invalid across sign changes.
    "CL=F": {"family": "energy_problem", "name": "WTI Crude Oil (negative-price issue)"},
    "NG=F": {"family": "commodity", "name": "Natural Gas"},
    "RB=F": {"family": "commodity", "name": "RBOB Gasoline"},
    "HO=F": {"family": "commodity", "name": "Heating Oil"},
    # Metals
    "GC=F": {"family": "commodity", "name": "Gold"},
    "SI=F": {"family": "commodity", "name": "Silver"},
    "HG=F": {"family": "commodity", "name": "Copper"},
    "PL=F": {"family": "commodity", "name": "Platinum"},
    "PA=F": {"family": "commodity", "name": "Palladium"},
    # Agriculture / softs / livestock
    "ZC=F": {"family": "commodity", "name": "Corn"},
    "ZS=F": {"family": "commodity", "name": "Soybeans"},
    "ZW=F": {"family": "commodity", "name": "Wheat"},
    "KC=F": {"family": "commodity", "name": "Coffee"},
    "SB=F": {"family": "commodity", "name": "Sugar"},
    "CC=F": {"family": "commodity", "name": "Cocoa"},
    "CT=F": {"family": "commodity", "name": "Cotton"},
    "LE=F": {"family": "commodity", "name": "Live Cattle"},
    "HE=F": {"family": "commodity", "name": "Lean Hogs"},
}

PROXY_FUNDS = [
    "WTMF",   # WisdomTree Managed Futures Strategy Fund, 2011+
    "AQMIX", "AQMNX", "CSAIX",  # 2010/2011+ mutual-fund proxies found on Yahoo
    "RYMFX",  # 2007+
    "DBMF", "KMLM", "CTA", "JPFP", "FFUT",  # ETF proxies, mostly 2019+
]


def parse_date(text: str) -> dt.date:
    y, m, d = map(int, text.split("-"))
    return dt.date(y, m, d)


def urlopen_json(url: str, timeout: int = 60) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def urlopen_text(url: str, timeout: int = 60) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read().decode("utf-8")


def fetch_yahoo(symbol: str, start: dt.date = dt.date(1990, 1, 1), end: dt.date | None = None) -> dict[str, Any]:
    if end is None:
        end = dt.date.today() + dt.timedelta(days=1)
    p1 = int(dt.datetime(start.year, start.month, start.day, tzinfo=dt.timezone.utc).timestamp())
    p2 = int(dt.datetime(end.year, end.month, end.day, tzinfo=dt.timezone.utc).timestamp())
    url = YAHOO_CHART.format(symbol=urllib.parse.quote(symbol, safe="")) + "?" + urllib.parse.urlencode({
        "period1": p1,
        "period2": p2,
        "interval": "1d",
        "events": "history",
        "includeAdjustedClose": "true",
    })
    data = urlopen_json(url, timeout=90)
    chart = data.get("chart", {})
    if chart.get("error"):
        raise RuntimeError(f"Yahoo error for {symbol}: {chart['error']}")
    result = chart.get("result") or []
    if not result:
        raise RuntimeError(f"Yahoo empty result for {symbol}")
    res = result[0]
    timestamps = res.get("timestamp") or []
    indicators = res.get("indicators") or {}
    quote = (indicators.get("quote") or [{}])[0]
    adj_blocks = indicators.get("adjclose") or []
    adj = adj_blocks[0].get("adjclose") if adj_blocks else None
    close = adj or quote.get("close") or []
    raw_points: list[tuple[dt.date, float | None]] = []
    for t, c in zip(timestamps, close):
        date = dt.datetime.utcfromtimestamp(t).date()
        val = None if c is None else float(c)
        raw_points.append((date, val))
    raw_points.sort()
    meta = res.get("meta", {})
    return {"symbol": symbol, "meta": meta, "raw_points": raw_points}


def fetch_fred(series: str) -> list[tuple[dt.date, float]]:
    url = FRED_CSV.format(series=urllib.parse.quote(series, safe=""))
    text = urlopen_text(url, timeout=90)
    rows = csv.DictReader(io.StringIO(text))
    points: list[tuple[dt.date, float]] = []
    for row in rows:
        date_text = row.get("observation_date") or row.get("DATE")
        val_text = row.get(series) or row.get("VALUE")
        if not date_text or not val_text or val_text == ".":
            continue
        try:
            val = float(val_text)
        except ValueError:
            continue
        points.append((parse_date(date_text), val))
    points.sort()
    return points


def fetch_usd_per_cny() -> list[tuple[dt.date, float]]:
    query = urllib.parse.urlencode({
        "symbols": "usd_per_cny",
        "start_date": "2000-01-01",
        "end_date": dt.date.today().isoformat(),
    })
    data = urlopen_json(FX_API + "?" + query, timeout=90)
    item = data["series"][0]
    points: list[tuple[dt.date, float]] = []
    for d, p in zip(item["dates"], item["prices"]):
        if p is None:
            continue
        val = float(p)
        if val > 0 and math.isfinite(val):
            points.append((parse_date(d), val))
    points.sort()
    return points


def coverage_from_raw(raw_points: list[tuple[dt.date, float | None]]) -> dict[str, Any]:
    finite = [(d, p) for d, p in raw_points if p is not None and math.isfinite(p)]
    positive = [(d, p) for d, p in finite if p > 0]
    nonpositive = [(d, p) for d, p in finite if p <= 0]
    out: dict[str, Any] = {
        "count_finite": len(finite),
        "count_positive": len(positive),
        "nonpositive_count": len(nonpositive),
        "nonpositive_dates": [str(d) for d, _ in nonpositive[:8]],
    }
    if finite:
        out.update({"start": str(finite[0][0]), "end": str(finite[-1][0])})
        out["obs_to_2001_12_31"] = sum(1 for d, _ in finite if d <= dt.date(2001, 12, 31))
    return out


def make_lookup(points: list[tuple[dt.date, float]]) -> tuple[list[dt.date], list[float]]:
    return [d for d, _ in points], [v for _, v in points]


def value_on_or_before(lookup: tuple[list[dt.date], list[float]], date: dt.date, max_gap_days: int = 14) -> float | None:
    dates, values = lookup
    i = bisect.bisect_right(dates, date) - 1
    if i < 0:
        return None
    if (date - dates[i]).days > max_gap_days:
        return None
    return values[i]


def align_prices(series: dict[str, list[tuple[dt.date, float]]]) -> tuple[list[dt.date], dict[str, list[float | None]], dict[str, list[bool]]]:
    all_dates = sorted({d for pts in series.values() for d, _ in pts if d >= START_DATE})
    latest: dict[str, float] = {}
    latest_date: dict[str, dt.date] = {}
    cursors = {sym: 0 for sym in series}
    prices = {sym: [] for sym in series}
    fresh = {sym: [] for sym in series}
    for date in all_dates:
        for sym, pts in series.items():
            i = cursors[sym]
            while i < len(pts) and pts[i][0] <= date:
                latest[sym] = pts[i][1]
                latest_date[sym] = pts[i][0]
                i += 1
            cursors[sym] = i
            ok = sym in latest and (date - latest_date[sym]).days <= MAX_FFILL_DAYS
            prices[sym].append(latest[sym] if ok else None)
            fresh[sym].append(ok)
    return all_dates, prices, fresh


def pct_return(prices: list[float | None], i: int) -> float | None:
    if i <= 0:
        return None
    p0, p1 = prices[i - 1], prices[i]
    if p0 is None or p1 is None or p0 <= 0 or p1 <= 0:
        return None
    return p1 / p0 - 1.0


def log_return(prices: list[float | None], i: int) -> float | None:
    r = pct_return(prices, i)
    if r is None or r <= -1:
        return None
    return math.log1p(r)


def momentum(prices: list[float | None], i: int, n: int = LOOKBACK_DAYS) -> float | None:
    if i - n < 0:
        return None
    p0, p1 = prices[i - n], prices[i]
    if p0 is None or p1 is None or p0 <= 0 or p1 <= 0:
        return None
    return p1 / p0 - 1.0


def annualized_vol(prices: list[float | None], i: int, n: int = VOL_DAYS) -> float | None:
    if i - n < 1:
        return None
    rets: list[float] = []
    for j in range(i - n + 1, i + 1):
        lr = log_return(prices, j)
        if lr is not None:
            rets.append(lr)
    if len(rets) < max(20, n * 2 // 3):
        return None
    if len(rets) < 2:
        return None
    stdev = statistics.stdev(rets)
    vol = stdev * math.sqrt(252)
    if not math.isfinite(vol) or vol <= 0:
        return None
    return vol


def moving_average(vals: list[float], n: int) -> list[float | None]:
    out: list[float | None] = [None] * len(vals)
    total = 0.0
    for i, v in enumerate(vals):
        total += v
        if i >= n:
            total -= vals[i - n]
        if i >= n - 1:
            out[i] = total / n
    return out


def metrics(dates: list[dt.date], vals: list[float]) -> dict[str, Any]:
    if len(vals) < 2 or vals[0] <= 0:
        raise ValueError("bad values")
    daily: list[float] = []
    peak = vals[0]
    peak_date = dates[0]
    mdd = 0.0
    mdd_start = dates[0]
    mdd_end = dates[0]
    for i in range(1, len(vals)):
        if vals[i - 1] > 0:
            daily.append(vals[i] / vals[i - 1] - 1.0)
        if vals[i] > peak:
            peak = vals[i]
            peak_date = dates[i]
        if peak > 0:
            dd = (peak - vals[i]) / peak
            if dd > mdd:
                mdd = dd
                mdd_start = peak_date
                mdd_end = dates[i]
    years = max((dates[-1] - dates[0]).days, 1) / 365.25
    total = vals[-1] / vals[0] - 1.0
    ann = (vals[-1] / vals[0]) ** (1 / years) - 1 if years > 0 and vals[-1] > 0 else None
    vol = None
    sharpe = None
    if len(daily) > 1:
        mean = statistics.mean(daily)
        sd = statistics.stdev(daily)
        vol = sd * math.sqrt(252)
        sharpe = (mean * 252) / vol if vol and vol > 0 else None
    return {
        "start": str(dates[0]),
        "end": str(dates[-1]),
        "total": total,
        "annualized": ann,
        "max_drawdown": mdd,
        "max_drawdown_start": str(mdd_start),
        "max_drawdown_end": str(mdd_end),
        "volatility": vol,
        "sharpe": sharpe,
    }


def slice_metrics(dates: list[dt.date], vals: list[float], start: dt.date) -> dict[str, Any] | None:
    i = bisect.bisect_left(dates, start)
    if i >= len(dates) - 5:
        return None
    return metrics(dates[i:], vals[i:])


def daily_tbill_returns(dates: list[dt.date], dgs3mo: list[tuple[dt.date, float]]) -> list[float]:
    lookup = make_lookup(dgs3mo)
    out: list[float] = []
    for date in dates:
        y = value_on_or_before(lookup, date, max_gap_days=14)
        if y is None or y < 0 or not math.isfinite(y):
            out.append(0.0)
        else:
            out.append((1.0 + y / 100.0) ** (1.0 / 252.0) - 1.0)
    return out


def fx_multiplier_to_cny(dates: list[dt.date], usd_per_cny: list[tuple[dt.date, float]]) -> list[float]:
    lookup = make_lookup(usd_per_cny)
    start_fx = value_on_or_before(lookup, dates[0], max_gap_days=14)
    if start_fx is None or start_fx <= 0:
        return [1.0] * len(dates)
    out: list[float] = []
    for date in dates:
        fx = value_on_or_before(lookup, date, max_gap_days=14)
        if fx is None or fx <= 0:
            out.append(out[-1] if out else 1.0)
        else:
            # usd_per_cny = USD per 1 CNY; CNY value of USD assets is proportional to 1/fx.
            out.append(start_fx / fx)
    return out


def compute_target_weights(
    mode: str,
    sig_i: int,
    universe: list[str],
    prices: dict[str, list[float | None]],
) -> dict[str, float]:
    target: dict[str, float] = {sym: 0.0 for sym in universe}
    active: list[tuple[str, int, float]] = []
    for sym in universe:
        mom = momentum(prices[sym], sig_i, LOOKBACK_DAYS)
        vol = annualized_vol(prices[sym], sig_i, VOL_DAYS)
        p = prices[sym][sig_i]
        if mom is None or vol is None or p is None or p <= 0:
            continue
        sign = 1 if mom > 0 else -1
        active.append((sym, sign, vol))
    if not active:
        return target

    if mode == "instrument_equal_risk":
        target_vol = 0.10
        max_gross = 1.00
        per_instrument_cap = 0.20
        k = target_vol / math.sqrt(len(active))
        for sym, sign, vol in active:
            target[sym] = sign * min(k / vol, per_instrument_cap)
    elif mode == "family_balanced":
        target_vol = 0.12
        max_gross = 1.50
        per_instrument_cap = 0.30
        families = sorted({FUTURES[sym]["family"] for sym, _, _ in active if FUTURES[sym]["family"] in {"equity", "rates", "fx", "commodity"}})
        for fam in families:
            fam_items = [(sym, sign, vol) for sym, sign, vol in active if FUTURES[sym]["family"] == fam]
            if not fam_items:
                continue
            # Four sleeves, each receives a fixed sub-risk budget; if a sleeve has no valid members it is skipped.
            sleeve_k = (target_vol / math.sqrt(max(len(families), 1))) / math.sqrt(len(fam_items))
            for sym, sign, vol in fam_items:
                target[sym] = sign * min(sleeve_k / vol, per_instrument_cap)
    else:
        raise ValueError(mode)

    gross = sum(abs(w) for w in target.values())
    if gross > max_gross and gross > 0:
        scale = max_gross / gross
        target = {sym: w * scale for sym, w in target.items()}
    return target


def simulate(
    name: str,
    mode: str,
    dates: list[dt.date],
    prices: dict[str, list[float | None]],
    universe: list[str],
    cash_returns: list[float],
    cny_mult: list[float],
) -> dict[str, Any]:
    value = INITIAL
    values_usd: list[float] = [value]
    weights = {sym: 0.0 for sym in universe}
    gross_sum = 0.0
    net_sum = 0.0
    turnover_sum = 0.0
    cost_sum = 0.0
    rebalance_count = 0
    nonzero_count = 0
    position_days_by_family = {"equity": 0, "rates": 0, "fx": 0, "commodity": 0}
    for i in range(1, len(dates)):
        fut_ret = 0.0
        for sym, w in weights.items():
            if w == 0:
                continue
            r = pct_return(prices[sym], i)
            if r is not None:
                fut_ret += w * r
        value *= max(0.01, 1.0 + cash_returns[i] + fut_ret)

        if i > LOOKBACK_DAYS and i % REBALANCE_DAYS == 0:
            new_weights = compute_target_weights(mode, i - 1, universe, prices)
            turnover = sum(abs(new_weights[sym] - weights.get(sym, 0.0)) for sym in universe)
            cost = value * turnover * TURNOVER_COST
            value = max(0.01, value - cost)
            turnover_sum += turnover
            cost_sum += cost
            weights = new_weights
            rebalance_count += 1

        gross = sum(abs(w) for w in weights.values())
        net = sum(weights.values())
        gross_sum += gross
        net_sum += net
        if gross > 1e-9:
            nonzero_count += 1
        active_families = {FUTURES[sym]["family"] for sym, w in weights.items() if abs(w) > 1e-9}
        for fam in position_days_by_family:
            if fam in active_families:
                position_days_by_family[fam] += 1
        values_usd.append(value)

    values_cny = [v * m for v, m in zip(values_usd, cny_mult)]
    end_date = dates[-1]
    slices = {
        "full": metrics(dates, values_cny),
        "usd_full": metrics(dates, values_usd),
        "2001_2008": slice_metrics(dates, values_cny, dt.date(2001, 1, 2)),
        "post_2009": slice_metrics(dates, values_cny, dt.date(2009, 1, 1)),
        "post_2020": slice_metrics(dates, values_cny, dt.date(2020, 1, 1)),
        "post_2022": slice_metrics(dates, values_cny, dt.date(2022, 1, 1)),
        "last_10y": slice_metrics(dates, values_cny, end_date.replace(year=end_date.year - 10)),
    }
    n_days = max(len(dates) - 1, 1)
    return {
        "name": name,
        "mode": mode,
        "assumptions": {
            "lookback_trading_days": LOOKBACK_DAYS,
            "vol_trading_days": VOL_DAYS,
            "rebalance_trading_days": REBALANCE_DAYS,
            "turnover_cost_one_way": TURNOVER_COST,
            "collateral": "FRED DGS3MO 3M T-bill on full NAV",
            "currency_reporting": "CNY unhedged via usd_per_cny; USD metrics also included",
        },
        "universe": universe,
        "metrics": slices,
        "avg_abs_gross": gross_sum / n_days,
        "avg_net": net_sum / n_days,
        "invested_day_ratio": nonzero_count / n_days,
        "rebalance_count": rebalance_count,
        "avg_turnover_per_rebalance": turnover_sum / rebalance_count if rebalance_count else 0.0,
        "total_turnover": turnover_sum,
        "total_cost_paid": cost_sum,
        "position_day_ratio_by_family": {fam: days / n_days for fam, days in position_days_by_family.items()},
    }


def simplify_float(x: Any) -> Any:
    if isinstance(x, float):
        return round(x, 6)
    if isinstance(x, dict):
        return {k: simplify_float(v) for k, v in x.items()}
    if isinstance(x, list):
        return [simplify_float(v) for v in x]
    return x


def main() -> None:
    fetched: dict[str, dict[str, Any]] = {}
    coverage: dict[str, Any] = {}
    print("FETCHING Yahoo futures/proxies...", flush=True)
    for symbol in list(FUTURES) + PROXY_FUNDS:
        try:
            item = fetch_yahoo(symbol)
            fetched[symbol] = item
            cov = coverage_from_raw(item["raw_points"])
            cov.update({
                "currency": item["meta"].get("currency"),
                "exchange": item["meta"].get("exchangeName"),
                "family": FUTURES.get(symbol, {}).get("family", "proxy_fund"),
                "name": FUTURES.get(symbol, {}).get("name", symbol),
            })
            coverage[symbol] = cov
            print(symbol, cov.get("start"), cov.get("end"), "obs<=2001", cov.get("obs_to_2001_12_31"), "nonpos", cov.get("nonpositive_count"), flush=True)
        except Exception as exc:
            coverage[symbol] = {"error": repr(exc)}
            print("ERR", symbol, repr(exc), flush=True)
        time.sleep(0.05)

    # Strategy universe: real Yahoo continuous futures with finite positive prices by 2001,
    # excluding symbols with non-positive daily closes (CL 2020) for percentage-return validity.
    universe: list[str] = []
    series_positive: dict[str, list[tuple[dt.date, float]]] = {}
    for symbol, meta in FUTURES.items():
        cov = coverage.get(symbol, {})
        if cov.get("error"):
            continue
        if meta["family"] == "energy_problem":
            continue
        if cov.get("start") is None or parse_date(cov["start"]) > dt.date(2001, 12, 31):
            continue
        if cov.get("nonpositive_count", 0) > 0:
            continue
        raw = fetched[symbol]["raw_points"]
        pts = [(d, float(p)) for d, p in raw if p is not None and math.isfinite(float(p)) and float(p) > 0]
        series_positive[symbol] = pts
        universe.append(symbol)

    print("FETCHING FRED DGS3MO and USD/CNY...", flush=True)
    dgs3mo = fetch_fred("DGS3MO")
    usd_per_cny = fetch_usd_per_cny()
    dates, prices, _fresh = align_prices(series_positive)
    cash_rets = daily_tbill_returns(dates, dgs3mo)
    cny_mult = fx_multiplier_to_cny(dates, usd_per_cny)

    results = [
        simulate("A_instrument_equal_risk_10vol_gross1", "instrument_equal_risk", dates, prices, universe, cash_rets, cny_mult),
        simulate("B_family_balanced_12vol_gross1_5", "family_balanced", dates, prices, universe, cash_rets, cny_mult),
    ]

    source_summary = {
        "yahoo_continuous_futures": {
            "usable_2001_symbols": universe,
            "excluded_key_symbols": {
                "CL=F": "WTI crude has non-positive front-month closes on Yahoo in 2020; percentage returns invalid without contract point P&L/back-adjustment.",
                "YM=F/RTY=F/BZ=F": "start after 2001, not usable for main 2001口径 as fixed universe.",
            },
        },
        "fred": {
            "DGS3MO": {"role": "USD collateral cash yield", "start": str(dgs3mo[0][0]), "end": str(dgs3mo[-1][0]), "count": len(dgs3mo)},
        },
        "usd_cny": {"source": FX_API, "start": str(usd_per_cny[0][0]), "end": str(usd_per_cny[-1][0]), "count": len(usd_per_cny)},
    }

    out = {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "start_date": str(START_DATE),
        "end_date": str(dates[-1]),
        "source_summary": source_summary,
        "coverage": coverage,
        "results": results,
    }
    out_path = Path("/tmp/atm_managed_futures_trend_spike.json")
    out_path.write_text(json.dumps(simplify_float(out), ensure_ascii=False, indent=2))
    print("WROTE", out_path)
    print("USABLE", ",".join(universe))
    for res in results:
        full = res["metrics"]["full"]
        usd = res["metrics"]["usd_full"]
        p20 = res["metrics"]["post_2020"]
        y10 = res["metrics"]["last_10y"]
        print("\n==", res["name"], "==")
        print(
            "CNY ann", f"{full['annualized']*100:.2f}%", "mdd", f"{full['max_drawdown']*100:.2f}%",
            "vol", f"{full['volatility']*100:.2f}%", "sharpe", round(full["sharpe"], 2) if full["sharpe"] is not None else None,
            "worst", full["max_drawdown_start"], "->", full["max_drawdown_end"],
        )
        print(
            "USD ann", f"{usd['annualized']*100:.2f}%", "mdd", f"{usd['max_drawdown']*100:.2f}%",
            "avgGross", f"{res['avg_abs_gross']:.2f}", "avgTurnover/Reb", f"{res['avg_turnover_per_rebalance']:.2f}",
        )
        if p20:
            print("post2020 CNY ann", f"{p20['annualized']*100:.2f}%", "mdd", f"{p20['max_drawdown']*100:.2f}%")
        if y10:
            print("last10y CNY ann", f"{y10['annualized']*100:.2f}%", "mdd", f"{y10['max_drawdown']*100:.2f}%")


if __name__ == "__main__":
    main()
