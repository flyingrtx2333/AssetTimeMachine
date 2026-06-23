#!/usr/bin/env python3
"""Expanded no-BTC 2001-present universe experiment.

Adds only assets with real 2001 coverage from the current API:
- hang_seng
- nikkei225
- shenzhen_component
- oil_wti_usd via symbol alias wti
No BTC, no shorter-history main conclusion.
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
SYMS = [
    "gold_cny", "nasdaq", "sp500", "dowjones",
    "shanghai_composite", "shenzhen_component", "csi300",
    "hang_seng", "nikkei225", "wti",
]
REQUIRED = ["gold_cny", "nasdaq", "sp500", "dowjones", "shanghai_composite", "shenzhen_component", "hang_seng", "nikkei225", "wti"]
OPTIONAL = ["csi300"]
OFF = ["nasdaq", "sp500", "dowjones", "shanghai_composite", "shenzhen_component", "csi300", "hang_seng", "nikkei225", "wti"]
USD_ASSETS = {"nasdaq", "sp500", "dowjones", "wti"}
ALIASES = {"nasdaq_composite": "nasdaq", "dow_jones": "dowjones", "oil_wti_usd": "wti"}
CN_ASSETS = ["shanghai_composite", "shenzhen_component", "csi300", "hang_seng"]
US_ASSETS = ["nasdaq", "sp500", "dowjones"]

base_spec = importlib.util.spec_from_file_location("base_search", REPO / "tools/search_basic_advanced_strategies.py")
if base_spec is None or base_spec.loader is None:
    raise RuntimeError("cannot load base helpers")
base = importlib.util.module_from_spec(base_spec)
base_spec.loader.exec_module(base)


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


def load_expanded() -> tuple[list[dt.date], dict[str, list[float | None]], dict[str, Any]]:
    raw: list[dict[str, Any]] = []
    raw.extend(fetch(["gold_cny", "nasdaq", "sp500", "usd_per_cny"]))
    raw.extend(fetch(["dow_jones", "csi300", "shanghai_composite", "shenzhen_component"]))
    raw.extend(fetch(["hang_seng", "nikkei225", "wti"]))
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
            # For HSI/Nikkei, keep index local-currency level. In rotation backtests, only relative returns matter.
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
        for sym in SYMS:
            pts = points[sym]
            j = idx[sym]
            while j < len(pts) and pts[j][0] <= date:
                latest[sym] = pts[j][1]
                latest_date[sym] = pts[j][0]
                j += 1
            idx[sym] = j
        ok = True
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
    buf: list[float] = []
    s = 0.0
    for i, v in enumerate(vals):
        if v is None:
            buf = []
            s = 0.0
            continue
        buf.append(v)
        s += v
        if len(buf) > n:
            s -= buf.pop(0)
        if len(buf) == n:
            out[i] = s / n
    return out


def ret(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n < 0:
        return None
    cur = vals[i]
    old = vals[i - n]
    if cur is None or old is None or old <= 0:
        return None
    return cur / old - 1


def vol(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n < 1:
        return None
    arr: list[float] = []
    for j in range(i - n + 1, i + 1):
        cur = vals[j]
        prev = vals[j - 1]
        if cur is None or prev is None or prev <= 0:
            return None
        arr.append(math.log(cur / prev))
    if len(arr) < 2:
        return None
    m = sum(arr) / len(arr)
    var = sum((x - m) ** 2 for x in arr) / (len(arr) - 1)
    return math.sqrt(var) * math.sqrt(252)


def rolling_dd(vals: list[float | None], i: int, n: int) -> float | None:
    if i - n + 1 < 0 or vals[i] is None:
        return None
    w = vals[i - n + 1 : i + 1]
    if any(x is None for x in w):
        return None
    peak = max(x for x in w if x is not None)
    cur = vals[i]
    if cur is None or peak <= 0:
        return None
    return cur / peak - 1


def normalized_average(prices: dict[str, list[float | None]], members: list[str]) -> list[float | None]:
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


def build_cache(prices: dict[str, list[float | None]]) -> dict[str, Any]:
    c: dict[str, Any] = {"ma": {}, "ret": {}, "vol": {}, "dd": {}}
    for s in SYMS:
        for n in [120, 180, 200, 220, 260]:
            c["ma"][(s, n)] = ma(prices[s], n)
        for n in [20, 60, 120, 240, 252]:
            c["ret"][(s, n)] = [ret(prices[s], i, n) for i in range(len(prices[s]))]
        for n in [60, 90]:
            c["vol"][(s, n)] = [vol(prices[s], i, n) for i in range(len(prices[s]))]
        for n in [20, 60]:
            c["dd"][(s, n)] = [rolling_dd(prices[s], i, n) for i in range(len(prices[s]))]
    cn_idx = normalized_average(prices, CN_ASSETS)
    c["cn_idx"] = cn_idx
    c["cn_ret252"] = [ret(cn_idx, i, 252) for i in range(len(cn_idx))]
    c["cn_dd20"] = [rolling_dd(cn_idx, i, 20) for i in range(len(cn_idx))]
    c["cn_dd60"] = [rolling_dd(cn_idx, i, 60) for i in range(len(cn_idx))]
    return c


def multi_mom(c: dict[str, Any], s: str, i: int, lbs: list[int], weights: list[int]) -> float | None:
    total = 0.0
    for lb, w in zip(lbs, weights):
        r = c["ret"][(s, lb)][i]
        if r is None:
            return None
        total += w * r
    return total


def gold_ok(prices: dict[str, list[float | None]], c: dict[str, Any], i: int, cfg: dict[str, Any]) -> bool:
    px = prices["gold_cny"][i]
    mm = multi_mom(c, "gold_cny", i, cfg["mom_lbs"], cfg["mom_weights"])
    m = c["ma"][("gold_cny", cfg["gold_ma"])][i]
    return px is not None and mm is not None and m is not None and mm > 0 and px > m


def clamp_group(target: dict[str, float], group: list[str], cap: float) -> float:
    total = sum(target[s] for s in group)
    if total <= cap or total <= 0:
        return 0.0
    scale = cap / total
    cut = 0.0
    for s in group:
        old = target[s]
        target[s] *= scale
        cut += old - target[s]
    return cut


def simulate(dates: list[dt.date], prices: dict[str, list[float | None]], c: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    cash = INITIAL
    units = {s: 0.0 for s in SYMS}
    vals: list[float] = []
    trades = 0
    exposure = 0.0
    last = -10**9
    cn_blocked = False
    block_until = -1
    pf_peak = INITIAL

    for i, d in enumerate(dates):
        def px(sym: str) -> float:
            p = prices[sym][i]
            if p is None:
                if abs(units[sym]) > 1e-12:
                    raise RuntimeError(f"missing price with position: {sym} {d}")
                return 0.0
            return p
        def pv() -> float:
            return cash + sum(units[s] * px(s) for s in SYMS)

        current_value = pv()
        if current_value > pf_peak:
            pf_peak = current_value

        if i > 0 and i - last >= cfg["rebalance"]:
            sig = i - 1
            weak = 0
            for s in cfg["canaries"]:
                p = prices[s][sig]
                mm = multi_mom(c, s, sig, cfg["mom_lbs"], cfg["mom_weights"])
                m = c["ma"][(s, cfg["canary_ma"])][sig]
                if p is None or mm is None or m is None or mm < 0 or p < m:
                    weak += 1
            risk_on = weak <= cfg["weak_allowed"]
            target = {s: 0.0 for s in SYMS}
            if risk_on:
                ranked: list[tuple[float, str]] = []
                for s in OFF:
                    p = prices[s][sig]
                    mm = multi_mom(c, s, sig, cfg["mom_lbs"], cfg["mom_weights"])
                    m = c["ma"][(s, cfg["asset_ma"])][sig]
                    vv = c["vol"][(s, 60)][sig]
                    dd60 = c["dd"][(s, 60)][sig]
                    if p is None or mm is None or m is None:
                        continue
                    if mm > 0 and p > m and (vv is None or vv < cfg["vol_cap"]) and (dd60 is None or dd60 > -cfg["dd_cap"]):
                        ranked.append((mm / max(vv or 0.18, 0.05), s))
                ranked.sort(reverse=True)
                selected = [s for _, s in ranked[: cfg["top_n"]]]
                if selected:
                    inv = {s: 1 / max(c["vol"][(s, 60)][sig] or 0.18, 0.05) for s in selected}
                    sm = sum(inv.values())
                    for s in selected:
                        target[s] = cfg["risk_weight"] * inv[s] / sm
                if gold_ok(prices, c, sig, cfg):
                    target["gold_cny"] = cfg["gold_ballast"]
            else:
                if gold_ok(prices, c, sig, cfg):
                    target["gold_cny"] = cfg["def_gold"]

            cut = 0.0
            # region caps avoid same-region clones dominating top-N
            cut += clamp_group(target, CN_ASSETS, cfg["cn_cap"])
            cut += clamp_group(target, US_ASSETS, cfg["us_cap"])
            cut += clamp_group(target, ["wti"], cfg["wti_cap"])
            # China bubble state overlay
            cn_r252 = c["cn_ret252"][sig]
            cn_dd20 = c["cn_dd20"][sig]
            cn_dd60 = c["cn_dd60"][sig]
            bubble_break = (
                (cn_r252 is not None and cn_r252 > 0.50 and cn_dd20 is not None and cn_dd20 < -0.055)
                or (cn_r252 is not None and cn_r252 > 0.35 and cn_dd60 is not None and cn_dd60 < -0.12)
            )
            if bubble_break:
                cn_blocked = True
                block_until = max(block_until, sig + 420)
            elif cn_blocked and sig >= block_until and cn_r252 is not None and cn_r252 > 0.04:
                cn_blocked = False
            if cn_blocked:
                cut += sum(target[s] for s in CN_ASSETS)
                for s in CN_ASSETS:
                    target[s] = 0.0
            elif cn_r252 is not None and cn_r252 > 0.55:
                cut += clamp_group(target, CN_ASSETS, min(cfg["cn_cap"], cfg["cn_hot_cap"]))
            if cut > 0 and gold_ok(prices, c, sig, cfg):
                target["gold_cny"] = min(target["gold_cny"] + cut * cfg["cut_to_gold"], cfg["gold_max"])

            # Gold is not always a safe haven. In 2008 gold itself had a large post-blowoff drawdown.
            # If gold is hot and starts breaking, cap gold and let the rest sit in cash.
            g_r252 = c["ret"][("gold_cny", 252)][sig]
            g_r120 = c["ret"][("gold_cny", 120)][sig]
            g_dd20 = c["dd"][("gold_cny", 20)][sig]
            g_dd60 = c["dd"][("gold_cny", 60)][sig]
            gold_blowoff_break = (
                (g_r252 is not None and g_r252 > 0.22 and g_dd20 is not None and g_dd20 < -0.045)
                or (g_r120 is not None and g_r120 > 0.14 and g_dd60 is not None and g_dd60 < -0.09)
            )
            if gold_blowoff_break and target["gold_cny"] > cfg["gold_hot_cap"]:
                target["gold_cny"] = cfg["gold_hot_cap"]

            # Portfolio-level drawdown brake: temporary, path-aware risk reduction.
            pf_dd = current_value / pf_peak - 1 if pf_peak > 0 else 0.0
            if pf_dd < -cfg.get("pf_brake_dd", 9.0):
                for s in OFF:
                    target[s] *= cfg.get("pf_brake_scale", 1.0)
                if gold_ok(prices, c, sig, cfg) and not gold_blowoff_break:
                    target["gold_cny"] = min(target["gold_cny"] + cfg.get("pf_brake_gold_add", 0.0), cfg["gold_max"])

            gross = sum(target.values())
            if gross > cfg["max_exposure"] and gross > 0:
                scale = cfg["max_exposure"] / gross
                for s in target:
                    target[s] *= scale

            total = pv()
            for s in SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur > tgt * (1 + cfg["band"]):
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
                if cur < tgt * (1 - cfg["band"]):
                    amt = min(cash, tgt - cur)
                    if amt > 1:
                        units[s] += amt * (1 - FEE) / (px(s) * (1 + SLIP))
                        cash -= amt
                        trades += 1
            last = i
        v = pv()
        vals.append(v)
        exposure += sum(units[s] * px(s) for s in SYMS) / v if v > 0 else 0.0

    return {"values": vals, "trades": trades, "exposure": exposure / len(vals)}


def mdd_episode(dates: list[dt.date], vals: list[float]) -> dict[str, Any]:
    peak_i = max_peak_i = trough_i = 0
    peak_v = vals[0]
    max_dd = 0.0
    for i, v in enumerate(vals):
        if v > peak_v:
            peak_v = v
            peak_i = i
        dd = v / peak_v - 1 if peak_v > 0 else 0.0
        if dd < max_dd:
            max_dd = dd
            max_peak_i = peak_i
            trough_i = i
    return {"peak": str(dates[max_peak_i]), "trough": str(dates[trough_i]), "depth": round(-max_dd, 6)}


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def score(m: dict[str, Any], sl: dict[str, Any]) -> float:
    ann = m["annualized"] or 0
    d = m["max_drawdown"]
    sh = m["sharpe"] or 0
    return ann * 2.2 + (sl["post_2020"]["annualized"] or 0) * 0.2 + (sl["last_10y"]["annualized"] or 0) * 0.2 + sh * 0.20 - d * 2.2 - max(d - 0.10, 0) * 12


def main() -> None:
    dates, prices, coverage = load_expanded()
    c = build_cache(prices)
    cfgs: list[dict[str, Any]] = []
    mom_sets = [([20, 60, 120, 240], [12, 4, 2, 1]), ([60, 120, 240], [4, 2, 1])]
    canary_sets = [["nasdaq", "sp500"], ["nasdaq", "sp500", "hang_seng"], ["nasdaq", "sp500", "wti"]]
    for canaries in canary_sets:
      for mom_lbs, mom_weights in mom_sets:
       for weak_allowed in [0, 1]:
        for top_n in [2, 3]:
         for rebalance in [5, 10, 20]:
          for risk_weight in [0.45, 0.55, 0.65]:
           for gold_ballast in [0.25, 0.35]:
            for def_gold in [0.45, 0.60, 0.75]:
             for cn_cap in [0.20, 0.30]:
              for us_cap in [0.35, 0.50]:
               for dd_cap in [0.08, 0.12, 0.16]:
                for gold_hot_cap in [0.20, 0.35, 0.70]:
                 cfgs.append({
                "canaries": canaries, "mom_lbs": mom_lbs, "mom_weights": mom_weights,
                "weak_allowed": weak_allowed, "top_n": top_n, "rebalance": rebalance,
                "canary_ma": 180, "asset_ma": 180, "gold_ma": 220,
                "risk_weight": risk_weight, "gold_ballast": gold_ballast, "def_gold": def_gold,
                "vol_cap": 0.45, "dd_cap": dd_cap,
                "cn_cap": cn_cap, "cn_hot_cap": 0.12,
                "us_cap": us_cap, "wti_cap": 0.12,
                "cut_to_gold": 0.65, "gold_max": 0.70,
                "gold_hot_cap": gold_hot_cap,
                "max_exposure": 0.95, "band": 0.02,
                 })
    candidates = []
    for cfg in cfgs:
        sim = simulate(dates, prices, c, cfg)
        vals = sim["values"]
        m = base.metrics(dates, vals)
        sl = {
            "post_2020": base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
            "last_10y": base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
            "post_2022": base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
        }
        candidates.append({"cfg": cfg, "metrics": m, "slices": sl, "trades": sim["trades"], "exposure": sim["exposure"], "max_dd_episode": mdd_episode(dates, vals), "score": score(m, sl)})
    candidates.sort(key=lambda x: (x["score"], x["metrics"]["annualized"] or 0), reverse=True)
    under10 = sorted([x for x in candidates if x["metrics"]["max_drawdown"] <= 0.10], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([x for x in candidates if x["metrics"]["max_drawdown"] <= 0.11], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under12 = sorted([x for x in candidates if x["metrics"]["max_drawdown"] <= 0.12], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    def simp(x: dict[str, Any]) -> dict[str, Any]:
        return {"score": round(x["score"], 6), "trades": x["trades"], "exposure": round(x["exposure"], 4), "config": x["cfg"], "metrics": sm(x["metrics"]), "slices": {k: sm(v) for k, v in x["slices"].items()}, "max_dd_episode": x["max_dd_episode"]}
    serial = {
        "coverage": coverage,
        "evaluated": len(candidates),
        "score_top": [simp(x) for x in candidates[:30]],
        "under10_by_return": [simp(x) for x in under10[:30]],
        "under11_by_return": [simp(x) for x in under11[:30]],
        "under12_by_return": [simp(x) for x in under12[:30]],
    }
    out = Path("/tmp/atm_no_btc_2001_expanded_universe.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))
    print("COVERAGE", coverage["aligned_dynamic"])
    print("EVALUATED", len(candidates), "WROTE", out)
    for sec in ["under10_by_return", "under11_by_return", "under12_by_return", "score_top"]:
        print("\n==", sec, "==")
        for i, x in enumerate(serial[sec][:10], 1):
            m = x["metrics"]; p20=x["slices"]["post_2020"]; y10=x["slices"]["last_10y"]
            print(i, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", round(m['sharpe'] or 0,2), "p20", f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}", "y10", f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}", "dd", x["max_dd_episode"], "cfg", x["config"])


if __name__ == "__main__":
    main()
