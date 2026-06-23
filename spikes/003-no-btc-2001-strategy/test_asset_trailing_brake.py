#!/usr/bin/env python3
"""Targeted follow-up search: asset-level trailing brake on top of the current
full-core gold-satellite candidate.

Goal: reduce the ~9.07% top drawdowns without giving up too much annualized
return. This is a disposable spike script.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("nb", "/tmp/atm_next_better_strategy_search.py")
NB = importlib.util.module_from_spec(spec)
sys.modules["nb"] = NB
assert spec and spec.loader
spec.loader.exec_module(NB)  # type: ignore

L = NB.L
START = NB.START
FEE = NB.FEE

EQUITY = ["nasdaq", "sp500", "csi300", "shanghai_composite"]
RISK_ASSETS = ["nasdaq", "sp500", "csi300", "shanghai_composite", "gold_cny"]


def pct(x: float) -> str:
    return f"{x * 100:.2f}%"


def ix(d, s: str) -> int:
    return d.assets.index(s)


def desc(d, w):
    return {s: round(x * 100, 1) for s, x in zip(d.assets, w) if x > 1e-4}


def cap_total(w, cap: float):
    sm = sum(max(x, 0.0) for x in w)
    if sm > cap and sm > 0:
        return [max(x, 0.0) * cap / sm for x in w]
    return [max(x, 0.0) for x in w]


def metrics(d, v):
    return {k: L.calc_metrics(d.dates, v, st, en or d.dates[-1]) for k, (st, en) in NB.PERIODS.items()}


def stress(d, v):
    return {k: L.calc_metrics(d.dates, v, st, en or d.dates[-1]) for k, (st, en) in NB.STRESS.items()}


def worst3(m) -> float:
    return max(m[k]["dd"] for k in ["full", "post2020", "teny"])


def score(m) -> float:
    return (
        m["full"]["ann"] * 5.0
        + m["post2020"]["ann"] * 2.0
        + m["teny"]["ann"] * 2.0
        + m["2024+"]["ann"] * 0.4
        - worst3(m) * 6.0
        + m["full"].get("sharpe", 0) * 0.20
        + m["full"].get("calmar", 0) * 0.08
    )


def episodes(d, values, weights, topn=6):
    peak = trough = 0
    out = []
    for i in range(1, len(values)):
        if values[i] > values[peak]:
            if values[trough] < values[peak] * 0.985:
                out.append((peak, trough, 1 - values[trough] / values[peak]))
            peak = trough = i
        elif values[i] < values[trough]:
            trough = i
    if values[trough] < values[peak] * 0.985:
        out.append((peak, trough, 1 - values[trough] / values[peak]))
    return sorted(out, key=lambda x: x[2], reverse=True)[:topn]


def base_params():
    # Current strong baseline: full core + 10% gold satellite + February weak-equity
    # guard + light portfolio equity brake.
    return NB.base_params(1.0, 0.10, 0.85) | {
        "weak_month_guard": True,
        "weak_months": (2,),
        "weak_lb": 60,
        "weak_thr": -0.02,
        "weak_cap": 0.35,
        "drawdown_guard": True,
        "port_lb": 60,
        "port_dd": 0.065,
        "port_scale": 0.85,
        "main_reb": 60,
    }


def apply_current_overlay(d, base_w_i, sig: int, p: dict):
    target = [x * p["core_w"] for x in base_w_i]
    ev = []
    if NB.gold_sat_ok(d, sig, p):
        target[ix(d, "gold_cny")] += p["sat_w"]
        ev.append("gold_sat")
    target = cap_total(target, p["max_exp"])
    if p.get("gold_exhaust") and NB.gold_exhausted(d, sig, p):
        j = ix(d, "gold_cny")
        if target[j] > p["gold_cap"]:
            target[j] = p["gold_cap"]
            ev.append("gold_exhaust")
    if p.get("weak_month_guard") and NB.q_weak_equity_trigger(d, sig, target, p):
        target = NB.apply_equity_cap(d, sig, target, p["weak_cap"], "weak_month_cap", {}, False)
        ev.append("weak_month_cap")
    target = cap_total(target, p["max_exp"])
    return target, ev


def asset_trailing_brake(d, sig: int, target: list[float], p: dict):
    out = target[:]
    ev = []
    for s in RISK_ASSETS:
        j = ix(d, s)
        if out[j] <= 1e-4:
            continue
        dd = NB.drawdown(d, s, sig, p["asset_dd_lb"]) or 0.0
        m1 = NB.mom(d, s, sig, p["asset_mom_lb"]) or 0.0
        m2 = NB.mom(d, s, sig, p["asset_confirm_lb"]) or 0.0
        vol = NB.rollvol(d, s, sig, p["asset_vol_lb"]) or 0.0
        # For gold, require more evidence; for equity, a fast drawdown + negative
        # short momentum is enough. This avoids killing normal trend pullbacks.
        is_gold = s == "gold_cny"
        dd_thr = p["gold_dd_thr"] if is_gold else p["asset_dd_thr"]
        cap = p["gold_trail_cap"] if is_gold else p["asset_trail_cap"]
        hit = dd < -dd_thr and m1 < p["asset_mom_thr"] and (m2 < p["asset_confirm_thr"] or vol > p["asset_vol_thr"])
        if hit and out[j] > cap:
            removed = out[j] - cap
            out[j] = cap
            ev.append(f"trail_{s}")
            # Optional: redeploy a fraction of equity cuts to gold only when gold
            # itself is healthy; never redeploy gold cuts back into equities.
            if s != "gold_cny" and p.get("trail_redeploy_gold", 0) > 0:
                gp = base_params() | {"sat_lb": 60, "sat_thr": -0.02, "sat_ma": 60, "sat_rel_lb": 60, "sat_rel_thr": -0.02, "sat_rel_to": "sp500"}
                if NB.gold_sat_ok(d, sig, gp):
                    out[ix(d, "gold_cny")] += removed * p["trail_redeploy_gold"]
    return cap_total(out, p["max_exp"]), ev


def run(d, base_w, p: dict):
    weights = [0.0] * len(d.assets)
    vals = [START]
    wa = [weights[:]]
    value = START
    events: dict[str, int] = {}
    event_dates = []
    trades = 0
    turn = 0.0
    exp = 0.0
    for i in range(1, len(d.dates)):
        value *= 1 + sum(weights[a] * d.returns[a][i] for a in range(len(weights)) if weights[a])
        do_main = i == 1 or i % p["main_reb"] == 0
        do_check = (not do_main) and p.get("trail_check", False) and i % p["trail_reb"] == 0
        if do_main or do_check:
            sig = i - 1
            if do_main:
                target, ev = apply_current_overlay(d, base_w[i], sig, p)
                if p.get("drawdown_guard") and len(vals) > p["port_lb"]:
                    pk = max(vals[-p["port_lb"]:])
                    dd = 1 - vals[-1] / pk if pk > 0 else 0
                    if dd > p["port_dd"]:
                        for s in EQUITY:
                            target[ix(d, s)] *= p["port_scale"]
                        ev.append("portfolio_dd_scale")
                if p.get("trail_on_main"):
                    target, tev = asset_trailing_brake(d, sig, target, p)
                    ev.extend(tev)
            else:
                target, ev = asset_trailing_brake(d, sig, weights, p)
            tw = sum(abs(t - w) for t, w in zip(target, weights))
            if tw > 1e-10:
                value *= max(0.0, 1 - FEE * tw)
                trades += 1
                turn += tw
            weights = target
            for e in ev:
                events[e] = events.get(e, 0) + 1
            if ev and len(event_dates) < 500:
                event_dates.append((str(d.dates[sig]), "+".join(ev), desc(d, weights)))
        vals.append(value)
        wa.append(weights[:])
        exp += sum(weights)
    return vals, wa, {"events": events, "event_dates": event_dates, "trades": trades, "avg_turnover": turn / max(trades, 1), "avg_exposure": exp / max(len(d.dates) - 1, 1), "latest": desc(d, weights)}


def main():
    t = time.time()
    d, _base_vals, base_w = NB.base_data()
    bp = base_params()
    bvals, bwa, be = run(d, base_w, bp)
    bm = metrics(d, bvals)
    print("DATA", d.dates[0], d.dates[-1], len(d.dates), d.assets)
    print("BENCH", pct(bm["full"]["ann"]), pct(bm["full"]["dd"]), pct(bm["post2020"]["ann"]), pct(bm["post2020"]["dd"]), pct(bm["teny"]["ann"]), pct(bm["teny"]["dd"]), be)
    rows = []
    searched = 0
    for trail_reb in [5, 10, 15, 20]:
      for trail_on_main in [False, True]:
       for asset_dd_thr in [0.045, 0.055, 0.065, 0.075, 0.09]:
        for asset_cap in [0.0, 0.25, 0.35, 0.50, 0.65]:
         for gold_dd_thr in [0.055, 0.07, 0.085, 0.10, 0.12]:
          for gold_cap in [0.25, 0.35, 0.50, 0.65]:
           for mom_lb, mom_thr in [(10, -0.015), (15, -0.02), (20, -0.025), (20, -0.04)]:
            for confirm_lb, confirm_thr in [(40, -0.02), (60, -0.03), (90, -0.04)]:
             for redeploy in [0.0, 0.35]:
              searched += 1
              p = bp | {
                  "trail_check": True,
                  "trail_on_main": trail_on_main,
                  "trail_reb": trail_reb,
                  "asset_dd_lb": 60,
                  "asset_dd_thr": asset_dd_thr,
                  "asset_trail_cap": asset_cap,
                  "gold_dd_thr": gold_dd_thr,
                  "gold_trail_cap": gold_cap,
                  "asset_mom_lb": mom_lb,
                  "asset_mom_thr": mom_thr,
                  "asset_confirm_lb": confirm_lb,
                  "asset_confirm_thr": confirm_thr,
                  "asset_vol_lb": 20,
                  "asset_vol_thr": 0.34,
                  "trail_redeploy_gold": redeploy,
              }
              vals, wa, extra = run(d, base_w, p)
              m = metrics(d, vals)
              w3 = worst3(m)
              improves = (
                  m["full"]["ann"] >= bm["full"]["ann"] - 0.001
                  and w3 < worst3(bm) - 0.001
                  and m["post2020"]["ann"] >= 0.14
                  and m["teny"]["ann"] >= 0.12
              )
              smoother = m["full"]["ann"] >= 0.126 and w3 <= 0.0895 and m["post2020"]["ann"] >= 0.14 and m["teny"]["ann"] >= 0.12
              high_return = m["full"]["ann"] > bm["full"]["ann"] and w3 <= worst3(bm) + 0.0005
              if improves or smoother or high_return:
                  rows.append({
                      "p": p,
                      "metrics": m,
                      "stress": stress(d, vals),
                      "extra": extra,
                      "score": score(m),
                      "improves": improves,
                      "smoother": smoother,
                      "high_return": high_return,
                      "top_dd": [(str(d.dates[a]), str(d.dates[b]), dd, desc(d, wa[b])) for a, b, dd in episodes(d, vals, wa, 6)],
                  })
              if searched % 5000 == 0:
                  print("searched", searched, "kept", len(rows), "elapsed", round(time.time() - t, 1), flush=True)
    rows.sort(key=lambda r: (r["improves"], r["smoother"], r["high_return"], r["score"]), reverse=True)
    out = {"bench": {"metrics": bm, "extra": be, "top_dd": [(str(d.dates[a]), str(d.dates[b]), dd, desc(d, bwa[b])) for a,b,dd in episodes(d,bvals,bwa,6)]}, "searched": searched, "rows": rows}
    path = Path("/tmp/atm_asset_trailing_brake_results.json")
    path.write_text(json.dumps(out, ensure_ascii=False, default=str, indent=2))
    print("SEARCHED", searched, "KEPT", len(rows), "elapsed", round(time.time() - t, 1), "WROTE", path)
    for i, r in enumerate(rows[:35], 1):
        m = r["metrics"]
        e = r["extra"]
        print(f"#{i:02d} improve={r['improves']} smooth={r['smoother']} high={r['high_return']} score={r['score']:.3f}")
        print(f"  full {pct(m['full']['ann'])}/{pct(m['full']['dd'])} post {pct(m['post2020']['ann'])}/{pct(m['post2020']['dd'])} ten {pct(m['teny']['ann'])}/{pct(m['teny']['dd'])} 2024 {pct(m['2024+']['ann'])}/{pct(m['2024+']['dd'])} worst3 {pct(worst3(m))}")
        print("  events", e["events"], "trades", e["trades"], "latest", e["latest"])
        print("  params", {k:r["p"][k] for k in ["trail_reb","trail_on_main","asset_dd_thr","asset_trail_cap","gold_dd_thr","gold_trail_cap","asset_mom_lb","asset_mom_thr","asset_confirm_lb","asset_confirm_thr","trail_redeploy_gold"]})
        print("  topdd", " ; ".join(f"{a}->{b} {pct(c)} W={w}" for a,b,c,w in r["top_dd"][:5]))


if __name__ == "__main__":
    main()
