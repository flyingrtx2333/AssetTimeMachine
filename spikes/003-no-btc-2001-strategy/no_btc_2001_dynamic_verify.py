#!/usr/bin/env python3
"""No-BTC 2001-present dynamic-universe verification.

Start from 2001 as requested. Assets with data from 2001 are required.
CSI300 starts in 2002 in the current API, so it is not used before its first
real data point; it joins the candidate pool only after it has enough history.
"""
from __future__ import annotations

import bisect
import datetime as dt
import importlib.util
import json
import math
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
BASE_URL = "https://api.flyingrtx.com/api/v1/money/public/history"
INITIAL = 100_000.0
FEE = 0.001
SLIP = 0.0005
START_DATE = dt.date(2001, 1, 1)
SYMS = ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
REQUIRED = ["gold_cny", "nasdaq", "sp500", "dowjones", "shanghai_composite"]
OPTIONAL = ["csi300"]
OFF = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
USD_ASSETS = {"nasdaq", "sp500", "dowjones"}
ALIASES = {"nasdaq_composite": "nasdaq", "dow_jones": "dowjones"}

base_spec = importlib.util.spec_from_file_location("base_search", REPO / "tools/search_basic_advanced_strategies.py")
if base_spec is None or base_spec.loader is None:
    raise RuntimeError("cannot load base helpers")
base = importlib.util.module_from_spec(base_spec)
base_spec.loader.exec_module(base)

CFG = {
    "canaries": ["nasdaq", "sp500"],
    "mom_lbs": [20, 60, 120, 240],
    "mom_weights": [12, 4, 2, 1],
    "weak_allowed": 1,
    "top_n": 2,
    "rebalance": 20,
    "canary_ma": 180,
    "asset_ma": 220,
    "gold_ma": 220,
    "eq_vol_cap": 0.45,
    "offensive_weight": 0.40,
    "gold_ballast": 0.30,
    "defensive_gold": 0.20,
    "max_exposure": 0.95,
    "band": 0.02,
}


def fetch(symbols: list[str]) -> list[dict[str, Any]]:
    url = BASE_URL + "?" + urllib.parse.urlencode({
        "symbols": ",".join(symbols),
        "start_date": START_DATE.isoformat(),
        "end_date": dt.date.today().isoformat(),
    })
    with urllib.request.urlopen(url, timeout=90) as response:
        return json.load(response)["series"]


def parse_date(text: str) -> dt.date:
    y, m, d = map(int, text.split("-"))
    return dt.date(y, m, d)


def load_dynamic() -> tuple[list[dt.date], dict[str, list[float | None]], dict[str, Any]]:
    raw: list[dict[str, Any]] = []
    raw.extend(fetch(["gold_cny", "nasdaq", "sp500", "usd_per_cny"]))
    raw.extend(fetch(["dow_jones", "csi300", "shanghai_composite"]))
    series: dict[str, dict[str, Any]] = {}
    for item in raw:
        raw_symbol = str(item["symbol"])
        sym = ALIASES.get(raw_symbol, raw_symbol)
        series[sym] = item
    fx_dates, fx_prices = base.make_fx_lookup(series["usd_per_cny"])

    def fx_on_or_before(date: dt.date) -> float | None:
        i = bisect.bisect_right(fx_dates, date) - 1
        return fx_prices[i] if i >= 0 else None

    points: dict[str, list[tuple[dt.date, float]]] = {}
    coverage: dict[str, Any] = {}
    for sym in SYMS:
        pts: list[tuple[dt.date, float]] = []
        item = series[sym]
        for date_text, raw_price in zip(item["dates"], item["prices"]):
            if raw_price is None or raw_price <= 0 or not math.isfinite(raw_price):
                continue
            date = parse_date(date_text)
            if date < START_DATE:
                continue
            price = float(raw_price)
            if sym in USD_ASSETS:
                fx = fx_on_or_before(date)
                if fx is None or fx <= 0 or not math.isfinite(fx):
                    continue
                price = price / fx if fx < 1 else price * fx if fx <= 20 else math.nan
                if not math.isfinite(price):
                    continue
            pts.append((date, price))
        pts.sort()
        points[sym] = pts
        coverage[sym] = {"count": len(pts), "start": str(pts[0][0]), "end": str(pts[-1][0])}

    all_dates = sorted(set(d for pts in points.values() for d, _ in pts))
    idx = {s: 0 for s in SYMS}
    latest: dict[str, float] = {}
    latest_date: dict[str, dt.date] = {}
    dates: list[dt.date] = []
    prices: dict[str, list[float | None]] = {s: [] for s in SYMS}
    for date in all_dates:
        ok = True
        for sym in SYMS:
            pts = points[sym]
            j = idx[sym]
            while j < len(pts) and pts[j][0] <= date:
                latest[sym] = pts[j][1]
                latest_date[sym] = pts[j][0]
                j += 1
            idx[sym] = j
        for sym in REQUIRED:
            if sym not in latest or (date - latest_date[sym]).days > 7:
                ok = False
                break
        if not ok:
            continue
        dates.append(date)
        for sym in SYMS:
            if sym in latest and (date - latest_date[sym]).days <= 7:
                prices[sym].append(latest[sym])
            else:
                prices[sym].append(None)
    coverage["aligned_dynamic"] = {"count": len(dates), "start": str(dates[0]), "end": str(dates[-1])}
    return dates, prices, coverage


def ma(vals: list[float | None], n: int) -> list[float | None]:
    out: list[float | None] = [None] * len(vals)
    window: list[float] = []
    s = 0.0
    for i, v in enumerate(vals):
        if v is None:
            window = []
            s = 0.0
            continue
        window.append(v)
        s += v
        if len(window) > n:
            s -= window.pop(0)
        if len(window) == n:
            out[i] = s / n
    return out


def vol(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n < 1:
        return None
    rs: list[float] = []
    for j in range(i - n + 1, i + 1):
        cur = vals[j]
        prev = vals[j - 1]
        if cur is None or prev is None or prev <= 0:
            return None
        rs.append(math.log(cur / prev))
    if len(rs) < 2:
        return None
    m = sum(rs) / len(rs)
    var = sum((x - m) ** 2 for x in rs) / (len(rs) - 1)
    return math.sqrt(var) * math.sqrt(252)


def series_ret(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n < 0:
        return None
    cur = vals[i]
    old = vals[i - n]
    if cur is None or old is None or old <= 0:
        return None
    return cur / old - 1


def series_dd(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n + 1 < 0 or vals[i] is None:
        return None
    window = vals[i - n + 1 : i + 1]
    if any(v is None for v in window):
        return None
    peak = max(v for v in window if v is not None)
    cur = vals[i]
    if cur is None or peak <= 0:
        return None
    return cur / peak - 1


def normalized_average_series(prices: dict[str, list[float | None]], members: list[str]) -> list[float | None]:
    bases: dict[str, float] = {}
    out: list[float | None] = []
    n = len(next(iter(prices.values())))
    for i in range(n):
        vals: list[float] = []
        for s in members:
            p = prices[s][i]
            if p is None:
                continue
            if s not in bases:
                bases[s] = p
            if bases[s] > 0:
                vals.append(p / bases[s])
        out.append(sum(vals) / len(vals) if vals else None)
    return out


def multi_mom(prices: dict[str, list[float | None]], sym: str, i: int) -> float | None:
    total = 0.0
    wsum = 0.0
    cur = prices[sym][i]
    if cur is None:
        return None
    for lb, w in zip(CFG["mom_lbs"], CFG["mom_weights"]):
        if i - lb < 0:
            return None
        old = prices[sym][i - lb]
        if old is None or old <= 0:
            return None
        total += w * (cur / old - 1)
        wsum += w
    return total / wsum if wsum else None


def gold_ok(prices: dict[str, list[float | None]], mas: dict[tuple[str, int], list[float | None]], i: int) -> bool:
    px = prices["gold_cny"][i]
    mm = multi_mom(prices, "gold_cny", i)
    m = mas[("gold_cny", CFG["gold_ma"])][i]
    return px is not None and mm is not None and m is not None and mm > 0 and px > m


def base_target(prices: dict[str, list[float | None]], mas: dict[tuple[str, int], list[float | None]], vols: dict[tuple[str, int], list[float | None]], i: int) -> tuple[dict[str, float], dict[str, Any]]:
    weak = 0
    for s in CFG["canaries"]:
        px = prices[s][i]
        mm = multi_mom(prices, s, i)
        m = mas[(s, CFG["canary_ma"])][i]
        if px is None or mm is None or m is None or mm < 0 or px < m:
            weak += 1
    risk_on = weak <= CFG["weak_allowed"]
    target = {s: 0.0 for s in SYMS}
    selected: list[str] = []
    if risk_on:
        ranked: list[tuple[float, str]] = []
        for s in OFF:
            px = prices[s][i]
            mm = multi_mom(prices, s, i)
            m = mas[(s, CFG["asset_ma"])][i]
            vv = vols[(s, 60)][i]
            if px is None or mm is None or m is None:
                continue
            if mm > 0 and px > m and (vv is None or vv < CFG["eq_vol_cap"]):
                ranked.append((mm / max(vv or 0.18, 0.05), s))
        ranked.sort(reverse=True)
        selected = [s for _, s in ranked[: CFG["top_n"]]]
        if selected:
            inv = {s: 1 / max(vols[(s, 60)][i] or 0.18, 0.05) for s in selected}
            sm = sum(inv.values())
            for s in selected:
                target[s] = CFG["offensive_weight"] * inv[s] / sm
        if gold_ok(prices, mas, i):
            target["gold_cny"] = CFG["gold_ballast"]
    else:
        if gold_ok(prices, mas, i):
            target["gold_cny"] = CFG["defensive_gold"]
    return target, {"weak": weak, "risk_on": risk_on, "selected": selected}


def simulate(name: str, dates: list[dt.date], prices: dict[str, list[float | None]]) -> dict[str, Any]:
    mas: dict[tuple[str, int], list[float | None]] = {}
    for s in SYMS:
        for n in [CFG["canary_ma"], CFG["asset_ma"], CFG["gold_ma"]]:
            mas[(s, n)] = ma(prices[s], n)
    vols = {(s, 60): [vol(prices[s], i, 60) for i in range(len(dates))] for s in SYMS}
    cash = INITIAL
    units = {s: 0.0 for s in SYMS}
    vals: list[float] = []
    trades = 0
    exposure = 0.0
    last = -10**9
    cn_idx = normalized_average_series(prices, ["csi300", "shanghai_composite"])
    cn_ma120 = ma(cn_idx, 120)
    cn_blocked = False
    block_events = 0
    for i, _d in enumerate(dates):
        def px(sym: str) -> float:
            p = prices[sym][i]
            if p is None:
                if abs(units[sym]) > 1e-12:
                    raise RuntimeError(f"missing price with nonzero units: {sym} {dates[i]}")
                return 0.0
            return p
        def pv() -> float:
            return cash + sum(units[s] * px(s) for s in SYMS)
        if i > 0 and i - last >= CFG["rebalance"]:
            sig = i - 1
            target, _meta = base_target(prices, mas, vols, sig)
            if name == "dynamic_shanghai_cap":
                # When both China indices are selected, cap total China cluster to avoid same-region bubble concentration.
                cn_total = target["csi300"] + target["shanghai_composite"]
                if cn_total > 0.30:
                    scale = 0.30 / cn_total
                    cut = 0.0
                    for s in ["csi300", "shanghai_composite"]:
                        old = target[s]
                        target[s] *= scale
                        cut += old - target[s]
                    if gold_ok(prices, mas, sig):
                        target["gold_cny"] = min(target["gold_cny"] + cut * 0.50, 0.45)
            elif name == "dynamic_us_gold_core":
                # Treat China as only a satellite; keep the engine mainly gold/US.
                cn_total = target["csi300"] + target["shanghai_composite"]
                if cn_total > 0.15:
                    scale = 0.15 / cn_total
                    cut = 0.0
                    for s in ["csi300", "shanghai_composite"]:
                        old = target[s]
                        target[s] *= scale
                        cut += old - target[s]
                    if gold_ok(prices, mas, sig):
                        target["gold_cny"] = min(target["gold_cny"] + cut * 0.60, 0.45)
            elif name == "dynamic_china_bubble_state":
                cn_r252 = series_ret(cn_idx, sig, 252)
                cn_r120 = series_ret(cn_idx, sig, 120)
                cn_dd20 = series_dd(cn_idx, sig, 20)
                cn_dd60 = series_dd(cn_idx, sig, 60)
                cn_close = cn_idx[sig]
                cn_m120 = cn_ma120[sig]
                trigger = (
                    (cn_r252 is not None and cn_r252 > 0.65 and cn_dd20 is not None and cn_dd20 < -0.08)
                    or (cn_r120 is not None and cn_r120 > 0.35 and cn_dd60 is not None and cn_dd60 < -0.16)
                )
                recovery = cn_blocked and cn_close is not None and cn_m120 is not None and cn_close > cn_m120 and cn_r120 is not None and cn_r120 > 0.04
                if trigger and not cn_blocked:
                    cn_blocked = True
                    block_events += 1
                elif recovery:
                    cn_blocked = False
                cn_total = target["csi300"] + target["shanghai_composite"]
                if cn_blocked and cn_total > 0:
                    cut = cn_total
                    target["csi300"] = 0.0
                    target["shanghai_composite"] = 0.0
                    if gold_ok(prices, mas, sig):
                        target["gold_cny"] = min(target["gold_cny"] + cut * 0.65, 0.45)
                elif not cn_blocked and cn_r252 is not None and cn_r252 > 0.80 and cn_total > 0.22:
                    # Blowoff phase: harvest before the formal break, but do not permanently ban China.
                    scale = 0.22 / cn_total
                    cut = 0.0
                    for s in ["csi300", "shanghai_composite"]:
                        old = target[s]
                        target[s] *= scale
                        cut += old - target[s]
                    if gold_ok(prices, mas, sig):
                        target["gold_cny"] = min(target["gold_cny"] + cut * 0.50, 0.45)
            gross = sum(target.values())
            if gross > CFG["max_exposure"] and gross > 0:
                scale = CFG["max_exposure"] / gross
                for s in target:
                    target[s] *= scale
            total = pv()
            for s in SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur > tgt * (1 + CFG["band"]):
                    su = min(units[s], (cur - tgt) / px(s))
                    if su > 0:
                        cash += su * px(s) * (1 - SLIP) * (1 - FEE)
                        units[s] -= su
                        trades += 1
            total = pv()
            for s in SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur < tgt * (1 - CFG["band"]):
                    amt = min(cash, tgt - cur)
                    if amt > 1:
                        units[s] += amt * (1 - FEE) / (px(s) * (1 + SLIP))
                        cash -= amt
                        trades += 1
            last = i
        v = pv()
        vals.append(v)
        exposure += sum(units[s] * px(s) for s in SYMS) / v if v > 0 else 0.0
    slices = {
        "full": base.metrics(dates, vals),
        "post_2020": base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
        "last_10y": base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
        "post_2022": base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
    }
    peak_i = trough_i = max_peak_i = 0
    peak_v = vals[0]
    max_dd = 0.0
    for j, val in enumerate(vals):
        if val > peak_v:
            peak_v = val
            peak_i = j
        dd = val / peak_v - 1 if peak_v > 0 else 0.0
        if dd < max_dd:
            max_dd = dd
            max_peak_i = peak_i
            trough_i = j
    return {"name": name, "start": str(dates[0]), "end": str(dates[-1]), "trades": trades, "exposure": exposure / len(vals), "slices": slices, "block_events": block_events, "max_dd_episode": {"peak": str(dates[max_peak_i]), "trough": str(dates[trough_i]), "depth": round(-max_dd, 6)}}


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    if m is None:
        return None
    return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def print_result(r: dict[str, Any]) -> None:
    f = r["slices"]["full"]
    p20 = r["slices"]["post_2020"]
    y10 = r["slices"]["last_10y"]
    p22 = r["slices"]["post_2022"]
    print(f"{r['name']:24s} {r['start']}..{r['end']} ann={f['annualized']*100:5.2f}% mdd={f['max_drawdown']*100:5.2f}% sharpe={(f['sharpe'] or 0):4.2f} trades={r['trades']:4d} expo={r['exposure']*100:5.1f}% | p20 {p20['annualized']*100:5.2f}/{p20['max_drawdown']*100:5.2f} y10 {y10['annualized']*100:5.2f}/{y10['max_drawdown']*100:5.2f} p22 {p22['annualized']*100:5.2f}/{p22['max_drawdown']*100:5.2f}")


def main() -> None:
    dates, prices, coverage = load_dynamic()
    print("COVERAGE", coverage)
    results = [simulate(name, dates, prices) for name in ["dynamic_vaa", "dynamic_shanghai_cap", "dynamic_us_gold_core", "dynamic_china_bubble_state"]]
    for r in results:
        print_result(r)
    out = Path("/tmp/atm_no_btc_2001_dynamic_verify.json")
    out.write_text(json.dumps({"coverage": coverage, "results": [{**r, "exposure": round(r["exposure"], 6), "slices": {k: sm(v) for k, v in r["slices"].items()}} for r in results]}, ensure_ascii=False, indent=2, default=str))
    print("WROTE", out)


if __name__ == "__main__":
    main()
