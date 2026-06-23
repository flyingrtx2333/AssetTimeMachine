#!/usr/bin/env python3
"""Probe crisis-payoff / hedge proxy sources for AssetTimeMachine.

Intent: do NOT tune stock/gold timing.  Verify whether independent payoff sources
(USD, Treasuries, volatility proxy, commodity trend) have real data and useful
crisis-window behavior from the 2001 full-cycle horizon.

Outputs /tmp/atm_crisis_payoff_sources.json and prints compact tables.
"""
from __future__ import annotations

import bisect
import datetime as dt
import json
import math
import statistics
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

BASE_URL = "https://api.flyingrtx.com/api/v1/money/public/history"
START_DATE = dt.date(2001, 1, 1)
END_DATE = dt.date(2026, 6, 21)
CACHE_DIR = Path("/tmp/atm_crisis_payoff_cache")
CACHE_DIR.mkdir(parents=True, exist_ok=True)
OUT = Path("/tmp/atm_crisis_payoff_sources.json")
INITIAL = 100_000.0
FEE = 0.001
SLIP = 0.0005

# Fixed, economically defined stress windows.  These are diagnostics, not fitted.
CRISIS_WINDOWS: list[tuple[str, dt.date, dt.date]] = [
    ("dotcom_9_11", dt.date(2001, 9, 10), dt.date(2002, 10, 9)),
    ("gfc_2008", dt.date(2008, 3, 18), dt.date(2009, 3, 9)),
    ("euro_us_debt_2011", dt.date(2011, 7, 22), dt.date(2011, 10, 3)),
    ("china_fx_2015", dt.date(2015, 6, 12), dt.date(2016, 2, 29)),
    ("q4_2018", dt.date(2018, 1, 26), dt.date(2018, 12, 24)),
    ("covid_crash", dt.date(2020, 2, 19), dt.date(2020, 3, 23)),
    ("inflation_2022", dt.date(2022, 1, 3), dt.date(2022, 10, 12)),
]

YAHOO_SYMBOLS = {
    # Daily adjusted NAV, dividends reinvested.  Real 2001-covering mutual funds.
    "vustx_usd": {"symbol": "VUSTX", "kind": "usd_asset", "note": "Vanguard Long-Term Treasury Fund adjusted NAV"},
    "vfitx_usd": {"symbol": "VFITX", "kind": "usd_asset", "note": "Vanguard Intermediate-Term Treasury Fund adjusted NAV"},
    "vfisx_usd": {"symbol": "VFISX", "kind": "usd_asset", "note": "Vanguard Short-Term Treasury Fund adjusted NAV"},
    # Dollar index and volatility index: benchmark/proxy; not automatically investable in the app.
    "dxy_index": {"symbol": "DX-Y.NYB", "kind": "index", "note": "ICE US Dollar Index, proxy/index"},
    "vix_index": {"symbol": "^VIX", "kind": "index", "note": "VIX spot index, non-investable payoff proxy only"},
    # Shorter-history implementable products for coverage diagnostics.
    "uup_usd": {"symbol": "UUP", "kind": "usd_asset", "note": "Dollar ETF, starts 2007"},
    "vxx_usd": {"symbol": "VXX", "kind": "usd_asset", "note": "VIX futures ETN, starts 2009/2018 series"},
    "vixy_usd": {"symbol": "VIXY", "kind": "usd_asset", "note": "VIX futures ETF, starts 2011"},
    "rymtx_usd": {"symbol": "RYMTX", "kind": "usd_asset", "note": "Rydex managed-futures fund, starts 2007"},
}


def parse_date(text: str) -> dt.date:
    y, m, d = map(int, text.split("-"))
    return dt.date(y, m, d)


def fetch_api(symbols: list[str]) -> list[dict[str, Any]]:
    key = "api_" + "_".join(symbols).replace("/", "_") + ".json"
    cache = CACHE_DIR / key
    if cache.exists():
        return json.loads(cache.read_text())["series"]
    url = BASE_URL + "?" + urllib.parse.urlencode({
        "symbols": ",".join(symbols),
        "start_date": START_DATE.isoformat(),
        "end_date": END_DATE.isoformat(),
    })
    with urllib.request.urlopen(url, timeout=90) as response:
        data = json.load(response)
    cache.write_text(json.dumps(data))
    return data["series"]


def fetch_yahoo_adj(symbol: str) -> list[tuple[dt.date, float]]:
    safe = urllib.parse.quote(symbol, safe="")
    cache = CACHE_DIR / f"yahoo_{safe}_adj.json"
    if cache.exists():
        raw = json.loads(cache.read_text())
        return [(dt.date.fromisoformat(d), float(p)) for d, p in raw]
    p1 = int(dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc).timestamp())
    p2 = int(dt.datetime(2026, 6, 21, tzinfo=dt.timezone.utc).timestamp())
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{safe}?period1={p1}&period2={p2}&interval=1d&events=history&includeAdjustedClose=true"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = json.load(response)
    err = data.get("chart", {}).get("error")
    if err:
        raise RuntimeError(f"Yahoo error {symbol}: {err}")
    result = data["chart"]["result"][0]
    ts = result.get("timestamp") or []
    quote = result["indicators"]["quote"][0]
    adj = result["indicators"].get("adjclose", [{}])[0].get("adjclose") or quote["close"]
    rows: list[tuple[dt.date, float]] = []
    for t, p in zip(ts, adj):
        if p is None or p <= 0 or not math.isfinite(float(p)):
            continue
        rows.append((dt.datetime.fromtimestamp(t, dt.timezone.utc).date(), float(p)))
    cache.write_text(json.dumps([(d.isoformat(), p) for d, p in rows]))
    return rows


def series_to_points(item: dict[str, Any], alias: str | None = None) -> tuple[str, list[tuple[dt.date, float]]]:
    sym = alias or str(item["symbol"])
    rows: list[tuple[dt.date, float]] = []
    for d_text, raw in zip(item["dates"], item["prices"]):
        if raw is None or raw <= 0 or not math.isfinite(float(raw)):
            continue
        rows.append((parse_date(d_text), float(raw)))
    rows.sort()
    return sym, rows


def value_on_or_before(points: list[tuple[dt.date, float]], date: dt.date, max_gap_days: int = 7) -> float | None:
    i = bisect.bisect_right(points, (date, float("inf"))) - 1
    if i < 0:
        return None
    d, v = points[i]
    if (date - d).days > max_gap_days:
        return None
    return v


def make_fx_cny_per_usd(raw_fx: list[tuple[dt.date, float]]) -> list[tuple[dt.date, float]]:
    out: list[tuple[dt.date, float]] = []
    for d, fx in raw_fx:
        if fx <= 0:
            continue
        # API symbol is usd_per_cny (~0.12 historically), so CNY per USD is 1/fx.
        out.append((d, 1.0 / fx if fx < 1 else fx))
    return out


def convert_usd_to_cny(rows: list[tuple[dt.date, float]], fx_cny_usd: list[tuple[dt.date, float]]) -> list[tuple[dt.date, float]]:
    out: list[tuple[dt.date, float]] = []
    for d, p in rows:
        fx = value_on_or_before(fx_cny_usd, d, 7)
        if fx is not None:
            out.append((d, p * fx))
    return out


def load_sources() -> tuple[list[dt.date], dict[str, list[float | None]], dict[str, Any]]:
    raw: list[dict[str, Any]] = []
    raw.extend(fetch_api(["usd_per_cny", "gold_cny", "nasdaq", "sp500", "wti"]))
    raw.extend(fetch_api(["dow_jones"]))
    api_points: dict[str, list[tuple[dt.date, float]]] = {}
    aliases = {"oil_wti_usd": "wti_usd", "wti": "wti_usd", "dow_jones": "dowjones", "nasdaq_composite": "nasdaq"}
    for item in raw:
        raw_sym = str(item["symbol"])
        name = aliases.get(raw_sym, raw_sym)
        _, pts = series_to_points(item, name)
        api_points[name] = pts

    fx_cny_usd = make_fx_cny_per_usd(api_points["usd_per_cny"])
    source_points: dict[str, list[tuple[dt.date, float]]] = {}
    source_points["usd_cash_cny"] = fx_cny_usd
    source_points["gold_cny"] = api_points["gold_cny"]
    source_points["sp500_cny"] = convert_usd_to_cny(api_points["sp500"], fx_cny_usd)
    source_points["nasdaq_cny"] = convert_usd_to_cny(api_points["nasdaq"], fx_cny_usd)
    source_points["dowjones_cny"] = convert_usd_to_cny(api_points["dowjones"], fx_cny_usd)
    source_points["wti_cny"] = convert_usd_to_cny(api_points["wti_usd"], fx_cny_usd)

    yahoo_errors: dict[str, str] = {}
    for out_name, meta in YAHOO_SYMBOLS.items():
        try:
            rows = fetch_yahoo_adj(meta["symbol"])
            if meta["kind"] == "usd_asset":
                source_points[out_name.replace("_usd", "_cny")] = convert_usd_to_cny(rows, fx_cny_usd)
            else:
                source_points[out_name] = rows
        except Exception as exc:  # keep diagnostics explicit, do not fabricate data
            yahoo_errors[out_name] = repr(exc)

    # UUP is not available before 2007.  For 2001 diagnostics create a transparent
    # DXY-in-CNY proxy: DXY index level * CNY-per-USD.  This is an index/futures
    # proxy, not an ETF total-return series, but it directly tests whether "long
    # dollar vs majors" is the missing crisis payoff.
    if "dxy_index" in source_points:
        dxy_cny: list[tuple[dt.date, float]] = []
        for d, p in source_points["dxy_index"]:
            fx = value_on_or_before(fx_cny_usd, d, 7)
            if fx is not None:
                dxy_cny.append((d, p * fx))
        source_points["dxy_cny_proxy"] = dxy_cny

    all_dates = sorted({d for rows in source_points.values() for d, _ in rows if d >= dt.date(2001, 6, 25)})
    prices: dict[str, list[float | None]] = {s: [] for s in source_points}
    for d in all_dates:
        for s, rows in source_points.items():
            prices[s].append(value_on_or_before(rows, d, 7))
    coverage: dict[str, Any] = {"yahoo_errors": yahoo_errors}
    for s, rows in source_points.items():
        vals = [(d, v) for d, v in rows if d >= dt.date(2001, 6, 25) and v is not None and v > 0]
        coverage[s] = {
            "count": len(vals),
            "start": str(vals[0][0]) if vals else None,
            "end": str(vals[-1][0]) if vals else None,
        }
    coverage["aligned_union"] = {"count": len(all_dates), "start": str(all_dates[0]), "end": str(all_dates[-1])}
    return all_dates, prices, coverage


def valid_range(dates: list[dt.date], series: list[float | None]) -> tuple[int, int] | None:
    idxs = [i for i, v in enumerate(series) if v is not None and v > 0]
    if not idxs:
        return None
    return idxs[0], idxs[-1]


def daily_returns(vals: list[float], dates: list[dt.date]) -> list[float]:
    return [vals[i] / vals[i - 1] - 1 for i in range(1, len(vals)) if vals[i - 1] > 0 and vals[i] > 0]


def metrics(dates: list[dt.date], vals: list[float]) -> dict[str, Any]:
    if len(vals) < 3:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "start": None, "end": None, "total_return": None}
    yrs = (dates[-1] - dates[0]).days / 365.25
    total = vals[-1] / vals[0] - 1
    ann = (vals[-1] / vals[0]) ** (1 / yrs) - 1 if yrs > 0 and vals[0] > 0 and vals[-1] > 0 else None
    peak = vals[0]
    max_dd = 0.0
    for v in vals:
        if v > peak:
            peak = v
        if peak > 0:
            max_dd = min(max_dd, v / peak - 1)
    rets = daily_returns(vals, dates)
    if len(rets) > 2:
        mean = statistics.fmean(rets)
        sd = statistics.stdev(rets)
        sharpe = (mean / sd * math.sqrt(252)) if sd > 0 else None
    else:
        sharpe = None
    return {
        "start": str(dates[0]), "end": str(dates[-1]), "years": round(yrs, 2),
        "total_return": total, "annualized": ann, "max_drawdown": -max_dd, "sharpe": sharpe,
    }


def slice_series(dates: list[dt.date], vals: list[float | None], start: dt.date | None = None, end: dt.date | None = None) -> tuple[list[dt.date], list[float]]:
    out_d: list[dt.date] = []
    out_v: list[float] = []
    for d, v in zip(dates, vals):
        if start is not None and d < start:
            continue
        if end is not None and d > end:
            continue
        if v is None or v <= 0:
            continue
        out_d.append(d)
        out_v.append(float(v))
    return out_d, out_v


def point_return(dates: list[dt.date], vals: list[float | None], start: dt.date, end: dt.date) -> float | None:
    pairs = [(d, v) for d, v in zip(dates, vals) if v is not None and v > 0]
    if not pairs:
        return None
    d_list = [d for d, _ in pairs]
    i0 = bisect.bisect_left(d_list, start)
    i1 = bisect.bisect_right(d_list, end) - 1
    if i0 >= len(pairs) or i1 < 0 or i0 >= i1:
        return None
    # Require not too stale vs window boundaries.
    if abs((pairs[i0][0] - start).days) > 10 or abs((end - pairs[i1][0]).days) > 10:
        return None
    return pairs[i1][1] / pairs[i0][1] - 1


def trailing_ma(vals: list[float | None], n: int) -> list[float | None]:
    out: list[float | None] = [None] * len(vals)
    buf: list[float] = []
    s = 0.0
    for i, v in enumerate(vals):
        if v is None or v <= 0:
            buf.clear(); s = 0.0; continue
        buf.append(float(v)); s += float(v)
        if len(buf) > n:
            s -= buf.pop(0)
        if len(buf) == n:
            out[i] = s / n
    return out


def trailing_ret(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n < 0:
        return None
    cur, old = vals[i], vals[i - n]
    if cur is None or old is None or old <= 0:
        return None
    return cur / old - 1


def simulate_fixed_strategy(
    name: str,
    dates: list[dt.date],
    prices: dict[str, list[float | None]],
    target_func,
    symbols: list[str],
    rebalance_days: int = 20,
) -> dict[str, Any]:
    cash = INITIAL
    units = {s: 0.0 for s in symbols}
    vals: list[float] = []
    trades = 0
    last = -10**9
    states: dict[str, int] = {}

    def price(sym: str, i: int) -> float:
        p = prices[sym][i]
        if p is None:
            if abs(units[sym]) > 1e-10:
                raise RuntimeError(f"missing price for held {sym} on {dates[i]}")
            return 0.0
        return float(p)

    for i, d in enumerate(dates):
        def pv() -> float:
            return cash + sum(units[s] * price(s, i) for s in symbols)

        if i > 0 and i - last >= rebalance_days:
            sig = i - 1
            target, state = target_func(sig)
            states[state] = states.get(state, 0) + 1
            gross = sum(target.values())
            if gross > 1.0 and gross > 0:
                target = {s: w / gross for s, w in target.items()}
            total = pv()
            # sell first
            for s in symbols:
                if prices[s][i] is None:
                    continue
                cur = units[s] * price(s, i)
                tgt = total * target.get(s, 0.0)
                if cur > tgt * 1.02:
                    sell_units = min(units[s], (cur - tgt) / price(s, i))
                    if sell_units > 0:
                        cash += sell_units * price(s, i) * (1 - SLIP) * (1 - FEE)
                        units[s] -= sell_units
                        trades += 1
            total = pv()
            # buy
            for s in symbols:
                if prices[s][i] is None:
                    continue
                cur = units[s] * price(s, i)
                tgt = total * target.get(s, 0.0)
                if cur < tgt * 0.98:
                    amt = min(cash, tgt - cur)
                    if amt > 1:
                        units[s] += amt * (1 - FEE) / (price(s, i) * (1 + SLIP))
                        cash -= amt
                        trades += 1
            last = i
        vals.append(pv())
    return {"name": name, "metrics": metrics(dates, vals), "trades": trades, "states": states, "values": vals}


def monthly_correlation_to_sp500(dates: list[dt.date], prices: dict[str, list[float | None]], source: str) -> float | None:
    # End-of-month returns over overlapping valid months.
    def eom(sym: str) -> dict[tuple[int, int], float]:
        out: dict[tuple[int, int], float] = {}
        for d, v in zip(dates, prices[sym]):
            if v is not None and v > 0:
                out[(d.year, d.month)] = float(v)
        return out
    a = eom(source); b = eom("sp500_cny")
    keys = sorted(set(a) & set(b))
    ra: list[float] = []; rb: list[float] = []
    for k0, k1 in zip(keys, keys[1:]):
        if a[k0] > 0 and b[k0] > 0:
            ra.append(a[k1] / a[k0] - 1)
            rb.append(b[k1] / b[k0] - 1)
    if len(ra) < 12:
        return None
    ma, mb = statistics.fmean(ra), statistics.fmean(rb)
    sa = math.sqrt(sum((x - ma) ** 2 for x in ra) / (len(ra) - 1))
    sb = math.sqrt(sum((x - mb) ** 2 for x in rb) / (len(rb) - 1))
    if sa <= 0 or sb <= 0:
        return None
    return sum((x - ma) * (y - mb) for x, y in zip(ra, rb)) / ((len(ra) - 1) * sa * sb)


def main() -> None:
    dates, prices, coverage = load_sources()
    # Create strategy helper caches.
    ma200 = {s: trailing_ma(v, 200) for s, v in prices.items()}

    def ok_trend(sym: str, i: int) -> bool:
        p = prices[sym][i]
        r = trailing_ret(prices[sym], i, 252)
        m = ma200[sym][i]
        return p is not None and m is not None and r is not None and p > m and r > 0

    # Logic 1: 2001-real Treasury crisis reserve.  Own-trend gate, inactive capital in USD cash.
    def treasury_trend(sig: int):
        if ok_trend("vustx_cny", sig):
            return {"vustx_cny": 1.0, "usd_cash_cny": 0.0}, "long_vustx"
        return {"vustx_cny": 0.0, "usd_cash_cny": 1.0}, "usd_cash"

    # Product-friendly version: when the Treasury source is not in its own trend,
    # leave capital as ordinary CNY cash instead of forcing a USD exposure.
    def treasury_trend_cny_cash(sig: int):
        if ok_trend("vustx_cny", sig):
            return {"vustx_cny": 1.0}, "long_vustx"
        return {"vustx_cny": 0.0}, "cny_cash"

    # Dollar-basket payoff.  2001 test uses DXY-in-CNY proxy; UUP validates the
    # same idea only from 2007 onward.  This is own-trend gating, not stock/gold timing.
    def dollar_trend_cny_cash(sig: int):
        if ok_trend("dxy_cny_proxy", sig):
            return {"dxy_cny_proxy": 1.0}, "long_dxy_cny"
        return {"dxy_cny_proxy": 0.0}, "cny_cash"

    # Logic 2: 2001-real three-engine hedge sleeve: Treasuries, commodity trend, USD cash.
    # Fixed weights: 60% Treasury trend engine, 25% WTI trend engine, 15% always USD cash.
    def treasury_wti_usd(sig: int):
        target = {"vustx_cny": 0.0, "wti_cny": 0.0, "usd_cash_cny": 0.15}
        state_parts = []
        if ok_trend("vustx_cny", sig):
            target["vustx_cny"] += 0.60; state_parts.append("ust")
        else:
            target["usd_cash_cny"] += 0.60; state_parts.append("usd")
        if ok_trend("wti_cny", sig):
            target["wti_cny"] += 0.25; state_parts.append("wti")
        else:
            target["usd_cash_cny"] += 0.25
        return target, "+".join(state_parts)

    # Alternative less duration-heavy version (not a fitted parameter; sanity check for 2022 duration risk).
    def intermediate_treasury_wti_usd(sig: int):
        target = {"vfitx_cny": 0.0, "wti_cny": 0.0, "usd_cash_cny": 0.15}
        state_parts = []
        if ok_trend("vfitx_cny", sig):
            target["vfitx_cny"] += 0.60; state_parts.append("int_ust")
        else:
            target["usd_cash_cny"] += 0.60; state_parts.append("usd")
        if ok_trend("wti_cny", sig):
            target["wti_cny"] += 0.25; state_parts.append("wti")
        else:
            target["usd_cash_cny"] += 0.25
        return target, "+".join(state_parts)

    # Three independent crisis/inflation engines.  Each fixed 1/3 sleeve is either
    # in its own positive trend or idle as CNY cash; no fitted ranking/threshold grid.
    def tri_hedge_trend_cny_cash(sig: int):
        target = {"vustx_cny": 0.0, "dxy_cny_proxy": 0.0, "wti_cny": 0.0}
        state_parts: list[str] = []
        for sym, tag in [("vustx_cny", "ust"), ("dxy_cny_proxy", "dxy"), ("wti_cny", "wti")]:
            if ok_trend(sym, sig):
                target[sym] = 1.0 / 3.0
                state_parts.append(tag)
        return target, "+".join(state_parts) if state_parts else "cny_cash"

    strategies = [
        simulate_fixed_strategy("ust_long_trend_or_usd", dates, prices, treasury_trend, ["vustx_cny", "usd_cash_cny"]),
        simulate_fixed_strategy("ust_long_trend_plus_wti_trend_usd", dates, prices, treasury_wti_usd, ["vustx_cny", "wti_cny", "usd_cash_cny"]),
        simulate_fixed_strategy("ust_intermediate_trend_plus_wti_trend_usd", dates, prices, intermediate_treasury_wti_usd, ["vfitx_cny", "wti_cny", "usd_cash_cny"]),
    ]

    # Convert strategy value curves to pseudo prices for crisis-window diagnostics.
    for st in strategies:
        prices["strategy_" + st["name"]] = st["values"]
        coverage["strategy_" + st["name"]] = {"count": len(st["values"]), "start": str(dates[0]), "end": str(dates[-1])}

    inspect = [
        "sp500_cny", "nasdaq_cny", "gold_cny", "usd_cash_cny", "dxy_index",
        "vustx_cny", "vfitx_cny", "vfisx_cny", "wti_cny", "vix_index",
        "uup_cny", "vxx_cny", "vixy_cny", "rymtx_cny",
        "strategy_ust_long_trend_or_usd",
        "strategy_ust_long_trend_plus_wti_trend_usd",
        "strategy_ust_intermediate_trend_plus_wti_trend_usd",
    ]

    source_metrics: dict[str, Any] = {}
    for s in inspect:
        if s not in prices:
            continue
        d2, v2 = slice_series(dates, prices[s], dt.date(2001, 6, 25), None)
        source_metrics[s] = metrics(d2, v2) if len(v2) >= 3 else None
        if source_metrics[s]:
            source_metrics[s]["monthly_corr_sp500_cny"] = monthly_correlation_to_sp500(dates, prices, s)

    crisis_returns: dict[str, dict[str, float | None]] = {}
    for name, start, end in CRISIS_WINDOWS:
        crisis_returns[name] = {s: point_return(dates, prices[s], start, end) if s in prices else None for s in inspect}

    # Record coverage class: can it be genuinely tested from 2001-06-25?
    coverage_class: dict[str, str] = {}
    for s in inspect:
        cov = coverage.get(s)
        if not cov or cov.get("start") is None:
            coverage_class[s] = "no_data"
            continue
        start = dt.date.fromisoformat(cov["start"])
        if start <= dt.date(2001, 6, 25):
            coverage_class[s] = "2001_real_or_index_proxy"
        elif start <= dt.date(2002, 7, 31):
            coverage_class[s] = "near_2001_dynamic_join"
        else:
            coverage_class[s] = "short_history_only"

    serial = {
        "as_of": dt.datetime.now(dt.timezone.utc).isoformat(),
        "coverage": coverage,
        "coverage_class": coverage_class,
        "source_metrics": source_metrics,
        "crisis_returns": crisis_returns,
        "fixed_strategies": [
            {k: v for k, v in st.items() if k != "values"} for st in strategies
        ],
        "notes": {
            "vustx_vfitx_vfisx": "Yahoo adjusted NAV mutual funds; real daily data from 2000 and usable for 2001-to-present source tests.",
            "vix_index": "VIX spot is not investable; VXX/VIXY have shorter history and large negative carry, so not valid for 2001 main backtest.",
            "wti_cny": "FlyingRTX WTI spot converted to CNY; trend strategy is a source proxy, not a futures total-return index.",
        },
    }
    OUT.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))

    def pct(x: Any) -> str:
        if x is None:
            return "n/a"
        return f"{float(x)*100:6.2f}%"

    print("WROTE", OUT)
    print("\nCOVERAGE CLASS")
    for s in inspect:
        if s in coverage_class:
            print(f"{s:48s} {coverage_class[s]:24s} {coverage.get(s, {}).get('start')} -> {coverage.get(s, {}).get('end')}")

    print("\nFULL-HISTORY METRICS")
    for s in inspect:
        m = source_metrics.get(s)
        if not m:
            continue
        print(f"{s:48s} ann={pct(m['annualized'])} mdd={pct(m['max_drawdown'])} corrSP={m.get('monthly_corr_sp500_cny') if m.get('monthly_corr_sp500_cny') is not None else 'n/a'}")

    print("\nCRISIS WINDOW RETURNS")
    cols = ["sp500_cny", "gold_cny", "usd_cash_cny", "vustx_cny", "vfitx_cny", "wti_cny", "dxy_index", "vix_index", "strategy_ust_long_trend_or_usd", "strategy_ust_intermediate_trend_plus_wti_trend_usd"]
    print("window".ljust(22), " ".join(c[:11].rjust(11) for c in cols))
    for w, vals in crisis_returns.items():
        print(w.ljust(22), " ".join(pct(vals.get(c)).rjust(11) for c in cols))

    print("\nFIXED STRATEGIES")
    for st in strategies:
        m = st["metrics"]
        print(f"{st['name']:48s} ann={pct(m['annualized'])} mdd={pct(m['max_drawdown'])} trades={st['trades']} states={st['states']}")


if __name__ == "__main__":
    main()
