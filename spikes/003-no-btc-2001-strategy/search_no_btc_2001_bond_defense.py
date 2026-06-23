#!/usr/bin/env python3
"""No-BTC 2001-present strategy with dynamic bond defense pool.

Main horizon still starts at 2001-06-25. Bond ETFs TLT/IEF/SHY are real Yahoo
adjusted-close data and join only after 2002-07-30.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
import urllib.request
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("exp", HERE / "search_no_btc_2001_expanded_universe.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load expanded universe module")
exp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exp)

BONDS = ["tlt", "ief", "shy"]
FX_DEF = ["usd_cash"]
DEF = ["gold_cny", "tlt", "ief", "shy", "usd_cash"]
RISK = ["nasdaq", "sp500", "dowjones", "shanghai_composite", "shenzhen_component", "csi300", "hang_seng", "nikkei225", "wti"]
SYMS = exp.SYMS + BONDS + FX_DEF


def fetch_yahoo_adj(symbol: str) -> list[tuple[dt.date, float]]:
    cache = Path(f"/tmp/atm_yahoo_{symbol.lower()}_adj.json")
    if cache.exists():
        raw = json.loads(cache.read_text())
        return [(dt.date.fromisoformat(d), float(p)) for d, p in raw]
    start = int(dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc).timestamp())
    end = int(dt.datetime(2026, 6, 21, tzinfo=dt.timezone.utc).timestamp())
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    data = json.load(urllib.request.urlopen(req, timeout=60))
    r = data["chart"]["result"][0]
    ts = r.get("timestamp") or []
    quote = r["indicators"]["quote"][0]
    adj = r["indicators"].get("adjclose", [{}])[0].get("adjclose") or quote["close"]
    rows = []
    for t, p in zip(ts, adj):
        if p is None or p <= 0:
            continue
        rows.append((dt.datetime.fromtimestamp(t, dt.UTC).date(), float(p)))
    cache.write_text(json.dumps([(d.isoformat(), p) for d, p in rows]))
    return rows


def load_with_bonds() -> tuple[list[dt.date], dict[str, list[float | None]], dict[str, Any]]:
    dates, prices, coverage = exp.load_expanded()
    # FX lookup from API via exp module helper data already in USD assets conversion; fetch direct for bond conversion.
    raw_fx = exp.fetch(["usd_per_cny"])[0]
    fx_pts = [(exp.parse_date(d), p) for d, p in zip(raw_fx["dates"], raw_fx["prices"]) if p and p > 0]
    fx_pts.sort()
    fx_dates = [d for d, _ in fx_pts]
    fx_prices = [p for _, p in fx_pts]
    import bisect
    def fx_on_or_before(date: dt.date) -> float | None:
        i = bisect.bisect_right(fx_dates, date) - 1
        return fx_prices[i] if i >= 0 else None
    date_index = {d: i for i, d in enumerate(dates)}
    for b in BONDS:
        arr: list[float | None] = [None] * len(dates)
        rows = fetch_yahoo_adj(b.upper())
        latest_price: float | None = None
        latest_date: dt.date | None = None
        j = 0
        for i, d in enumerate(dates):
            while j < len(rows) and rows[j][0] <= d:
                latest_date, usd = rows[j]
                fx = fx_on_or_before(latest_date)
                if fx is not None and fx > 0:
                    latest_price = usd / fx if fx < 1 else usd * fx if fx <= 20 else None
                j += 1
            if latest_price is not None and latest_date is not None and (d - latest_date).days <= 7:
                arr[i] = latest_price
        prices[b] = arr
        valid = [(d, p) for d, p in zip(dates, arr) if p is not None and p > 0]
        coverage[b] = {"count": len(valid), "start": str(valid[0][0]) if valid else None, "end": str(valid[-1][0]) if valid else None, "source": "Yahoo adjusted close, converted by usd_per_cny"}
    usd_cash: list[float | None] = []
    for d in dates:
        fx = fx_on_or_before(d)
        if fx is None or fx <= 0:
            usd_cash.append(None)
        else:
            usd_cash.append(1 / fx if fx < 1 else fx if fx <= 20 else None)
    prices["usd_cash"] = usd_cash
    valid_usd = [(d, p) for d, p in zip(dates, usd_cash) if p is not None and p > 0]
    coverage["usd_cash"] = {"count": len(valid_usd), "start": str(valid_usd[0][0]) if valid_usd else None, "end": str(valid_usd[-1][0]) if valid_usd else None, "source": "CNY per USD from usd_per_cny"}
    coverage["aligned_dynamic_with_bonds"] = {"count": len(dates), "start": str(dates[0]), "end": str(dates[-1])}
    return dates, prices, coverage


def ma(vals: list[float | None], n: int) -> list[float | None]:
    return exp.ma(vals, n)


def ret(vals: list[float | None], i: int, n: int) -> float | None:
    return exp.ret(vals, i, n)


def vol(vals: list[float | None], i: int, n: int) -> float | None:
    return exp.vol(vals, i, n)


def dd(vals: list[float | None], i: int, n: int) -> float | None:
    return exp.rolling_dd(vals, i, n)


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
            c["dd"][(s, n)] = [dd(prices[s], i, n) for i in range(len(prices[s]))]
    cn_idx = exp.normalized_average(prices, exp.CN_ASSETS)
    c["cn_idx"] = cn_idx
    c["cn_ret252"] = [ret(cn_idx, i, 252) for i in range(len(cn_idx))]
    c["cn_dd20"] = [dd(cn_idx, i, 20) for i in range(len(cn_idx))]
    c["cn_dd60"] = [dd(cn_idx, i, 60) for i in range(len(cn_idx))]
    return c


def multi_mom(c: dict[str, Any], s: str, i: int, lbs: list[int], weights: list[int]) -> float | None:
    total = 0.0
    for lb, w in zip(lbs, weights):
        r = c["ret"][(s, lb)][i]
        if r is None:
            return None
        total += w * r
    return total


def asset_ok(prices: dict[str, list[float | None]], c: dict[str, Any], s: str, i: int, cfg: dict[str, Any], ma_n: int | None = None) -> bool:
    p = prices[s][i]
    mm = multi_mom(c, s, i, cfg["mom_lbs"], cfg["mom_weights"])
    m = c["ma"][(s, ma_n or cfg["asset_ma"])][i]
    vv = c["vol"][(s, 60)][i]
    d60 = c["dd"][(s, 60)][i]
    return p is not None and mm is not None and m is not None and p > m and mm > 0 and (vv is None or vv < cfg["vol_cap"]) and (d60 is None or d60 > -cfg["dd_cap"])


def clamp_group(target: dict[str, float], group: list[str], cap: float) -> float:
    total = sum(target.get(s, 0.0) for s in group)
    if total <= cap or total <= 0:
        return 0.0
    scale = cap / total
    cut = 0.0
    for s in group:
        old = target.get(s, 0.0)
        target[s] = old * scale
        cut += old - target[s]
    return cut


def allocate_ranked(target: dict[str, float], symbols: list[str], weight: float, prices: dict[str, list[float | None]], c: dict[str, Any], i: int, cfg: dict[str, Any], max_each: float | None = None) -> None:
    ranked: list[tuple[float, str]] = []
    for s in symbols:
        if not asset_ok(prices, c, s, i, cfg, cfg["def_ma"] if s in DEF else cfg["asset_ma"]):
            continue
        mm = multi_mom(c, s, i, cfg["mom_lbs"], cfg["mom_weights"])
        vv = c["vol"][(s, 60)][i]
        ranked.append(((mm or 0) / max(vv or 0.12, 0.03), s))
    ranked.sort(reverse=True)
    selected = [s for _, s in ranked[: cfg["def_top_n"] if symbols == DEF else cfg["risk_top_n"]]]
    if not selected:
        return
    inv = {s: 1 / max(c["vol"][(s, 60)][i] or 0.12, 0.03) for s in selected}
    sm = sum(inv.values())
    for s in selected:
        add = weight * inv[s] / sm
        if max_each is not None:
            add = min(add, max_each - target.get(s, 0.0))
            if add <= 0:
                continue
        target[s] = target.get(s, 0.0) + add


def simulate(dates: list[dt.date], prices: dict[str, list[float | None]], c: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    cash = exp.INITIAL
    units = {s: 0.0 for s in SYMS}
    vals: list[float] = []
    trades = 0
    exposure = 0.0
    last = -10**9
    pf_peak = exp.INITIAL
    cn_blocked = False
    block_until = -1

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
        current = pv()
        if current > pf_peak:
            pf_peak = current
        if i > 0 and i - last >= cfg["rebalance"]:
            sig = i - 1
            weak = 0
            for s in cfg["canaries"]:
                p = prices[s][sig]
                mm = multi_mom(c, s, sig, cfg["mom_lbs"], cfg["mom_weights"])
                m = c["ma"][(s, cfg["canary_ma"])][sig]
                if p is None or mm is None or m is None or p < m or mm < 0:
                    weak += 1
            risk_on = weak <= cfg["weak_allowed"]
            target = {s: 0.0 for s in SYMS}
            if risk_on:
                allocate_ranked(target, RISK, cfg["risk_weight"], prices, c, sig, cfg)
                allocate_ranked(target, DEF, cfg["def_ballast"], prices, c, sig, cfg, cfg["def_each_cap"])
            else:
                allocate_ranked(target, DEF, cfg["def_weight"], prices, c, sig, cfg, cfg["def_each_cap"])

            cut = 0.0
            cut += clamp_group(target, exp.CN_ASSETS, cfg["cn_cap"])
            cut += clamp_group(target, exp.US_ASSETS, cfg["us_cap"])
            cut += clamp_group(target, ["wti"], cfg["wti_cap"])
            cut += clamp_group(target, ["tlt", "ief", "shy"], cfg["bond_cap"])
            # China bubble block.
            cn_r252 = c["cn_ret252"][sig]
            cn_dd20 = c["cn_dd20"][sig]
            cn_dd60 = c["cn_dd60"][sig]
            bubble_break = ((cn_r252 is not None and cn_r252 > 0.50 and cn_dd20 is not None and cn_dd20 < -0.055) or (cn_r252 is not None and cn_r252 > 0.35 and cn_dd60 is not None and cn_dd60 < -0.12))
            if bubble_break:
                cn_blocked = True
                block_until = max(block_until, sig + 420)
            elif cn_blocked and sig >= block_until and cn_r252 is not None and cn_r252 > 0.04:
                cn_blocked = False
            if cn_blocked:
                cut += sum(target[s] for s in exp.CN_ASSETS)
                for s in exp.CN_ASSETS:
                    target[s] = 0.0
            elif cn_r252 is not None and cn_r252 > 0.55:
                cut += clamp_group(target, exp.CN_ASSETS, min(cfg["cn_cap"], 0.12))
            # If risk cut occurs, first try bonds, then cash; don't force gold after blowoff.
            if cut > 0:
                allocate_ranked(target, ["usd_cash", "ief", "shy", "tlt", "gold_cny"], cut * cfg["cut_to_def"], prices, c, sig, cfg, cfg["def_each_cap"])
            # Gold blowoff cap.
            g_r252 = c["ret"][("gold_cny", 252)][sig]
            g_r120 = c["ret"][("gold_cny", 120)][sig]
            g_dd20 = c["dd"][("gold_cny", 20)][sig]
            g_dd60 = c["dd"][("gold_cny", 60)][sig]
            gold_break = ((g_r252 is not None and g_r252 > 0.22 and g_dd20 is not None and g_dd20 < -0.045) or (g_r120 is not None and g_r120 > 0.14 and g_dd60 is not None and g_dd60 < -0.09))
            if gold_break and target["gold_cny"] > cfg["gold_hot_cap"]:
                target["gold_cny"] = cfg["gold_hot_cap"]
            # Portfolio brake.
            pf_dd = current / pf_peak - 1 if pf_peak > 0 else 0.0
            if pf_dd < -cfg["pf_brake_dd"]:
                for s in RISK:
                    target[s] *= cfg["pf_brake_scale"]
                allocate_ranked(target, ["usd_cash", "shy", "ief", "tlt"], cfg["pf_brake_def_add"], prices, c, sig, cfg, cfg["def_each_cap"])
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
                        cash += su * px(s) * (1 - exp.SLIP) * (1 - exp.FEE)
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
                        units[s] += amt * (1 - exp.FEE) / (px(s) * (1 + exp.SLIP))
                        cash -= amt
                        trades += 1
            last = i
        v = pv()
        vals.append(v)
        exposure += sum(units[s] * px(s) for s in SYMS) / v if v > 0 else 0.0
    return {"values": vals, "trades": trades, "exposure": exposure / len(vals)}


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def score(m: dict[str, Any], sl: dict[str, Any]) -> float:
    ann = m["annualized"] or 0
    d = m["max_drawdown"]
    sh = m["sharpe"] or 0
    return ann * 2.4 + (sl["post_2020"]["annualized"] or 0) * 0.2 + (sl["last_10y"]["annualized"] or 0) * 0.2 + sh * 0.25 - d * 2.4 - max(d - 0.10, 0) * 16


def main() -> None:
    dates, prices, coverage = load_with_bonds()
    cache = build_cache(prices)
    cfgs: list[dict[str, Any]] = []
    for canaries in [["nasdaq", "sp500"], ["nasdaq", "sp500", "hang_seng"]]:
      for mom_lbs, mom_weights in [([60, 120, 240], [4, 2, 1]), ([20, 60, 120, 240], [12, 4, 2, 1])]:
       for weak_allowed in [0, 1]:
        for rebalance in [5, 10]:
         for risk_weight in [0.45, 0.55, 0.65]:
          for def_ballast in [0.20, 0.30, 0.40]:
           for def_weight in [0.55, 0.70, 0.85]:
            for cn_cap in [0.20, 0.30]:
             cfgs.append({
                "canaries": canaries, "mom_lbs": mom_lbs, "mom_weights": mom_weights,
                "weak_allowed": weak_allowed, "rebalance": rebalance,
                "risk_top_n": 3, "def_top_n": 2,
                "canary_ma": 180, "asset_ma": 180, "def_ma": 120,
                "risk_weight": risk_weight, "def_ballast": def_ballast, "def_weight": def_weight,
                "vol_cap": 0.45, "dd_cap": 0.16,
                "cn_cap": cn_cap, "us_cap": 0.50, "wti_cap": 0.12, "bond_cap": 0.85, "def_each_cap": 0.55,
                "cut_to_def": 0.70, "gold_hot_cap": 0.25,
                "pf_brake_dd": 0.055, "pf_brake_scale": 0.65, "pf_brake_def_add": 0.10,
                "max_exposure": 0.95, "band": 0.02,
             })
    results = []
    for cfg in cfgs:
        sim = simulate(dates, prices, cache, cfg)
        vals = sim["values"]
        m = exp.base.metrics(dates, vals)
        sl = {
            "post_2020": exp.base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
            "last_10y": exp.base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
            "post_2022": exp.base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
        }
        results.append({"score": score(m, sl), "config": cfg, "metrics": m, "slices": sl, "trades": sim["trades"], "exposure": sim["exposure"], "max_dd_episode": exp.mdd_episode(dates, vals)})
    results.sort(key=lambda x: (x["score"], x["metrics"]["annualized"] or 0), reverse=True)
    under10 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.10], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.11], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    def simp(x: dict[str, Any]) -> dict[str, Any]:
        return {"score": round(x["score"], 6), "trades": x["trades"], "exposure": round(x["exposure"], 4), "config": x["config"], "metrics": sm(x["metrics"]), "slices": {k: sm(v) for k, v in x["slices"].items()}, "max_dd_episode": x["max_dd_episode"]}
    serial = {"coverage": coverage, "evaluated": len(results), "score_top": [simp(x) for x in results[:30]], "under10_by_return": [simp(x) for x in under10[:30]], "under11_by_return": [simp(x) for x in under11[:30]]}
    out = Path("/tmp/atm_no_btc_2001_bond_defense.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))
    print("COVERAGE", coverage["aligned_dynamic_with_bonds"], {b: coverage[b] for b in BONDS})
    print("EVALUATED", len(results), "WROTE", out)
    for sec in ["under10_by_return", "under11_by_return", "score_top"]:
        print("\n==", sec, "==")
        for i, x in enumerate(serial[sec][:10], 1):
            m=x["metrics"]; p20=x["slices"]["post_2020"]; y10=x["slices"]["last_10y"]; p22=x["slices"]["post_2022"]
            print(i, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", round(m['sharpe'] or 0,2), "p20", f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}", "y10", f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}", "p22", f"{p22['annualized']*100:.2f}/{p22['max_drawdown']*100:.2f}", "dd", x["max_dd_episode"], "cfg", x["config"])

if __name__ == "__main__":
    main()
