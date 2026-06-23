#!/usr/bin/env python3
"""Search VAA/PAA-style no-BTC strategies on the 2001 dynamic universe.

This ports the existing 2002 VAA/PAA search to the corrected 2001-present口径:
- no BTC
- gold/nasdaq/sp500/dowjones/shanghai are available from 2001
- CSI300 joins only after real data exists
- optional China overlays are mechanism-level, not a huge blind parameter grid
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("dyn", HERE / "no_btc_2001_dynamic_verify.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load dynamic verifier")
dyn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dyn)

INITIAL = dyn.INITIAL
SYMS = dyn.SYMS
OFF = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
CANARIES = [["nasdaq", "sp500"], ["nasdaq", "sp500", "dowjones"], ["nasdaq", "sp500", "csi300"]]


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


def build_cache(prices: dict[str, list[float | None]]) -> dict[str, Any]:
    c: dict[str, Any] = {"ma": {}, "ret": {}, "vol": {}}
    for s in SYMS:
        for n in [80, 120, 180, 200, 220, 260]:
            c["ma"][(s, n)] = ma(prices[s], n)
        for n in [20, 40, 60, 80, 120, 160, 180, 240, 252]:
            c["ret"][(s, n)] = [ret(prices[s], i, n) for i in range(len(prices[s]))]
        for n in [40, 60, 90]:
            c["vol"][(s, n)] = [vol(prices[s], i, n) for i in range(len(prices[s]))]
    cn_idx = dyn.normalized_average_series(prices, ["csi300", "shanghai_composite"])
    c["cn_idx"] = cn_idx
    c["cn_ma120"] = ma(cn_idx, 120)
    c["cn_ma200"] = ma(cn_idx, 200)
    c["cn_ret120"] = [ret(cn_idx, i, 120) for i in range(len(cn_idx))]
    c["cn_ret252"] = [ret(cn_idx, i, 252) for i in range(len(cn_idx))]
    c["cn_dd20"] = [dyn.series_dd(cn_idx, i, 20) for i in range(len(cn_idx))]
    c["cn_dd60"] = [dyn.series_dd(cn_idx, i, 60) for i in range(len(cn_idx))]
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
    gmm = multi_mom(c, "gold_cny", i, cfg["mom_lbs"], cfg["mom_weights"])
    gma = c["ma"][("gold_cny", cfg["gold_ma"])][i]
    return px is not None and gmm is not None and gma is not None and gmm > cfg["gold_mom_th"] and px > gma


def clamp_china(target: dict[str, float], cap: float) -> float:
    cn = target["csi300"] + target["shanghai_composite"]
    if cn <= cap or cn <= 0:
        return 0.0
    scale = cap / cn
    cut = 0.0
    for s in ["csi300", "shanghai_composite"]:
        old = target[s]
        target[s] *= scale
        cut += old - target[s]
    return cut


def apply_overlay(name: str, target: dict[str, float], prices: dict[str, list[float | None]], c: dict[str, Any], sig: int, cfg: dict[str, Any], state: dict[str, Any]) -> None:
    if name == "none":
        return
    cut = 0.0
    cn_ret252 = c["cn_ret252"][sig]
    cn_ret120 = c["cn_ret120"][sig]
    cn_dd20 = c["cn_dd20"][sig]
    cn_dd60 = c["cn_dd60"][sig]
    cn_close = c["cn_idx"][sig]
    ma120 = c["cn_ma120"][sig]
    ma200 = c["cn_ma200"][sig]

    if name == "cap30":
        cut = clamp_china(target, 0.30)
    elif name == "cap25":
        cut = clamp_china(target, 0.25)
    elif name == "cap20":
        cut = clamp_china(target, 0.20)
    elif name in {"hot15", "hot20", "state_hot20", "state_hot15"}:
        hot = cn_ret252 is not None and cn_ret252 > 0.55
        if name == "hot15":
            cut = clamp_china(target, 0.15 if hot else 0.40)
        elif name == "hot20":
            cut = clamp_china(target, 0.20 if hot else 0.40)
        else:
            break_now = (
                (cn_ret252 is not None and cn_ret252 > 0.50 and cn_dd20 is not None and cn_dd20 < -0.055)
                or (cn_ret120 is not None and cn_ret120 > 0.25 and cn_dd60 is not None and cn_dd60 < -0.12)
            )
            recover = (
                state.get("blocked")
                and sig >= state.get("block_until", -1)
                and cn_close is not None and ma120 is not None and ma200 is not None
                and cn_close > ma120 and cn_close > ma200
                and cn_ret120 is not None and cn_ret120 > 0.08
            )
            if break_now:
                state["blocked"] = True
                state["block_until"] = max(state.get("block_until", -1), sig + 504)
            elif recover:
                state["blocked"] = False
            if state.get("blocked"):
                cut = target["csi300"] + target["shanghai_composite"]
                target["csi300"] = 0.0
                target["shanghai_composite"] = 0.0
            else:
                hot_cap = 0.15 if name == "state_hot15" else 0.20
                cut = clamp_china(target, hot_cap if hot else 0.40)
    if cut > 0 and gold_ok(prices, c, sig, cfg):
        target["gold_cny"] = min(target["gold_cny"] + cut * cfg["china_cut_to_gold"], cfg["gold_max"])


def simulate(dates: list[dt.date], prices: dict[str, list[float | None]], c: dict[str, Any], cfg: dict[str, Any]) -> tuple[list[float], int, float]:
    cash = INITIAL
    units = {s: 0.0 for s in SYMS}
    vals: list[float] = []
    trades = 0
    exposure = 0.0
    last = -10**9
    overlay_state: dict[str, Any] = {"blocked": False, "block_until": -1}

    for i, d in enumerate(dates):
        def px(sym: str) -> float:
            p = prices[sym][i]
            if p is None:
                if abs(units[sym]) > 1e-12:
                    raise RuntimeError(f"missing price with units: {sym} {d}")
                return 0.0
            return p

        def pv() -> float:
            return cash + sum(units[s] * px(s) for s in SYMS)

        if i > 0 and i - last >= cfg["rebalance"]:
            sig = i - 1
            weak = 0
            for s in cfg["canaries"]:
                if prices[s][sig] is None:
                    weak += 1
                    continue
                mm = multi_mom(c, s, sig, cfg["mom_lbs"], cfg["mom_weights"])
                ma_v = c["ma"][(s, cfg["canary_ma"])][sig]
                if mm is None or ma_v is None or mm < cfg["canary_mom_th"] or prices[s][sig] < ma_v:
                    weak += 1
            risk_on = weak <= cfg["weak_allowed"]
            target = {s: 0.0 for s in SYMS}
            if risk_on:
                ranked: list[tuple[float, str]] = []
                for s in OFF:
                    px_sig = prices[s][sig]
                    if px_sig is None:
                        continue
                    mm = multi_mom(c, s, sig, cfg["mom_lbs"], cfg["mom_weights"])
                    ma_v = c["ma"][(s, cfg["asset_ma"])][sig]
                    vv = c["vol"][(s, 60)][sig]
                    if mm is None or ma_v is None:
                        continue
                    if mm > cfg["asset_mom_th"] and px_sig > ma_v and (vv is None or vv < cfg["eq_vol_cap"]):
                        ranked.append((mm / max(vv or 0.18, 0.05), s))
                ranked.sort(reverse=True)
                selected = [s for _, s in ranked[: cfg["top_n"]]]
                if selected:
                    if cfg["equal_weight"]:
                        for s in selected:
                            target[s] = cfg["offensive_weight"] / len(selected)
                    else:
                        inv = {s: 1 / max(c["vol"][(s, 60)][sig] or 0.18, 0.05) for s in selected}
                        sm = sum(inv.values())
                        for s in selected:
                            target[s] = cfg["offensive_weight"] * inv[s] / sm
                if gold_ok(prices, c, sig, cfg):
                    target["gold_cny"] = cfg["gold_ballast"]
            else:
                if gold_ok(prices, c, sig, cfg):
                    target["gold_cny"] = cfg["defensive_gold"]
            apply_overlay(cfg["china_overlay"], target, prices, c, sig, cfg, overlay_state)
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
                        cash += su * px(s) * (1 - dyn.SLIP) * (1 - dyn.FEE)
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
                        units[s] += amt * (1 - dyn.FEE) / (px(s) * (1 + dyn.SLIP))
                        cash -= amt
                        trades += 1
            last = i
        v = pv()
        vals.append(v)
        exposure += sum(units[s] * px(s) for s in SYMS) / v if v > 0 else 0
    return vals, trades, exposure / len(vals)


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


def score(m: dict[str, Any], sl: dict[str, Any]) -> float:
    ann = m["annualized"] or 0
    d = m["max_drawdown"]
    sh = m["sharpe"] or 0
    p = sl["post_2020"] or {}
    y = sl["last_10y"] or {}
    z = sl["post_2022"] or {}
    return ann * 2.0 + (p.get("annualized") or 0) * 0.25 + (y.get("annualized") or 0) * 0.25 + (z.get("annualized") or 0) * 0.15 + sh * 0.20 - d * 2.0 - max(d - 0.10, 0) * 10


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def simp(cand: dict[str, Any]) -> dict[str, Any]:
    return {
        "score": round(cand["score"], 6),
        "trades": cand["trades"],
        "exposure": round(cand["exposure"], 4),
        "config": cand["cfg"],
        "metrics": sm(cand["metrics"]),
        "slices": {k: sm(v) for k, v in cand["slices"].items()},
        "max_dd_episode": cand["max_dd_episode"],
    }


def dedupe(items: list[dict[str, Any]], limit: int = 30) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    for cnd in items:
        cfg = cnd["cfg"]
        key = (
            tuple(cfg["canaries"]), tuple(cfg["mom_lbs"]), cfg["weak_allowed"], cfg["top_n"],
            cfg["canary_ma"], cfg["asset_ma"], cfg["gold_ma"], cfg["offensive_weight"],
            cfg["gold_ballast"], cfg["defensive_gold"], cfg["china_overlay"], cfg["china_cut_to_gold"],
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(cnd)
        if len(out) >= limit:
            break
    return out


def main() -> None:
    dates, prices, coverage = dyn.load_dynamic()
    c = build_cache(prices)
    candidates: list[dict[str, Any]] = []
    evaluated = 0
    mom_sets = [([20, 60, 120], [12, 4, 2]), ([20, 60, 120, 240], [12, 4, 2, 1]), ([60, 120, 240], [4, 2, 1])]
    overlays = ["none", "cap25", "hot20", "state_hot20"]
    for canaries in CANARIES[:2]:
      for mom_lbs, mom_weights in mom_sets[:2]:
       for weak_allowed in [0, 1]:
        for top_n in [1, 2]:
         for canary_ma in [180, 220]:
          for asset_ma in [180, 220]:
           for gold_ma in [180, 220]:
            for off_w in [0.45, 0.55, 0.65]:
             for gold_ballast in [0.15, 0.25, 0.35]:
              for def_gold in [0.45, 0.55, 0.70]:
               if off_w + gold_ballast > 1.0:
                   continue
               for overlay in overlays:
                for cut_to_gold in ([0.5, 0.8] if overlay != "none" else [0.0]):
                    cfg = {
                        "canaries": canaries, "mom_lbs": mom_lbs, "mom_weights": mom_weights,
                        "weak_allowed": weak_allowed, "top_n": top_n, "rebalance": 20,
                        "canary_ma": canary_ma, "asset_ma": asset_ma, "gold_ma": gold_ma,
                        "canary_mom_th": 0.0, "asset_mom_th": 0.0, "gold_mom_th": 0.0,
                        "eq_vol_cap": 0.45, "offensive_weight": off_w, "gold_ballast": gold_ballast,
                        "defensive_gold": def_gold, "max_exposure": 0.95, "equal_weight": False,
                        "band": 0.02, "china_overlay": overlay, "china_cut_to_gold": cut_to_gold,
                        "gold_max": 0.70,
                    }
                    vals, trades, expo = simulate(dates, prices, c, cfg)
                    m = dyn.base.metrics(dates, vals)
                    if not m:
                        continue
                    sl = {
                        "post_2020": dyn.base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
                        "last_10y": dyn.base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
                        "post_2022": dyn.base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
                        "stress_2015_2018": dyn.base.slice_metrics(dates, vals, dt.date(2015, 6, 12)),
                    }
                    candidates.append({"cfg": cfg, "metrics": m, "slices": sl, "trades": trades, "exposure": expo, "score": score(m, sl), "max_dd_episode": mdd_episode(dates, vals)})
                    evaluated += 1
    candidates.sort(key=lambda x: (x["score"], x["metrics"]["annualized"] or 0), reverse=True)
    under10 = sorted([x for x in candidates if x["metrics"]["max_drawdown"] <= 0.10], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([x for x in candidates if x["metrics"]["max_drawdown"] <= 0.11], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under12 = sorted([x for x in candidates if x["metrics"]["max_drawdown"] <= 0.12], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    robust = sorted([
        x for x in candidates
        if x["metrics"]["max_drawdown"] <= 0.11
        and (x["slices"]["post_2020"] or {}).get("max_drawdown", 1) <= 0.11
        and (x["slices"]["last_10y"] or {}).get("max_drawdown", 1) <= 0.11
    ], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    serial = {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "coverage": coverage,
        "evaluated": evaluated,
        "score_top": [simp(x) for x in dedupe(candidates, 30)],
        "under10_by_return": [simp(x) for x in dedupe(under10, 30)],
        "under11_by_return": [simp(x) for x in dedupe(under11, 30)],
        "under12_by_return": [simp(x) for x in dedupe(under12, 30)],
        "robust_under11_by_return": [simp(x) for x in dedupe(robust, 30)],
    }
    out = Path("/tmp/atm_no_btc_2001_dynamic_vaa_search.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))
    print("COVERAGE", coverage["aligned_dynamic"])
    print("EVALUATED", evaluated, "CANDIDATES", len(candidates))
    print("WROTE", out)
    for sec in ["under10_by_return", "under11_by_return", "under12_by_return", "robust_under11_by_return", "score_top"]:
        print("\n==", sec, "==")
        for i, x in enumerate(serial[sec][:10], 1):
            m = x["metrics"]
            p20 = x["slices"]["post_2020"]
            y10 = x["slices"]["last_10y"]
            print(i, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", None if m["sharpe"] is None else round(m["sharpe"], 2), "p20", f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}", "y10", f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}", "dd", x["max_dd_episode"], "cfg", x["config"])


if __name__ == "__main__":
    main()
