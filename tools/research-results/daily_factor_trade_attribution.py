#!/usr/bin/env python3
"""Event-level attribution: does cross-sectional factor alignment explain base trade quality?"""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import daily_alpha_factor_lab as lab  # noqa: E402
import daily_cross_sectional_factor_lab as xlab  # noqa: E402

OUT = HERE / "daily-factor-lab"
ASSETS = lab.ASSETS
TARGET_COL = {
    "gold": "target_gold",
    "nasdaq": "target_nasdaq",
    "sp500": "target_sp500",
    "csi300": "target_csi300",
    "shanghai": "target_shanghai",
}
COST = 0.0105


def static_return(weights: dict[str, float], prices: dict[str, list[float]], start: int, horizon: int) -> float | None:
    end = start + horizon
    if end >= len(next(iter(prices.values()))):
        return None
    gross = sum(weights.values())
    r = 0.0
    for a, w in weights.items():
        if w <= 0:
            continue
        p0, p1 = prices[a][start], prices[a][end]
        if p0 <= 0 or p1 <= 0:
            return None
        r += w * (p1 / p0 - 1.0)
    # Cash carry omitted in the edge comparison because both static portfolios differ
    # only by risky weights and this is a diagnostic, not the production backtest.
    return r


def normalized_rank(values: dict[str, float]) -> dict[str, float]:
    ordered = sorted(values, key=lambda a: (values[a], a))
    out = {}
    for i, a in enumerate(ordered):
        out[a] = i / (len(ordered) - 1)
    return out


def composite_rank(cube: dict[str, dict[str, list[float | None]]], i: int) -> dict[str, float] | None:
    a = cube["risk_adjusted_momentum_60_20"]
    b = cube["risk_adjusted_momentum_252_60"]
    av = {x: a[x][i] for x in ASSETS}
    bv = {x: b[x][i] for x in ASSETS}
    if any(v is None or not math.isfinite(float(v)) for v in list(av.values()) + list(bv.values()) if v is not None) or any(v is None for v in list(av.values()) + list(bv.values())):
        return None
    ar = normalized_rank({k: float(v) for k, v in av.items() if v is not None})
    br = normalized_rank({k: float(v) for k, v in bv.items() if v is not None})
    return {x: 0.5 * ar[x] + 0.5 * br[x] for x in ASSETS}


def build_events():
    dates, cols = lab.read_panel()
    cube = xlab.build_asset_factor_cube(cols)
    prices = {a: cols[f"price_{a}"] for a in ASSETS}
    events = []
    for i in range(1, len(dates)):
        prior = {a: cols[TARGET_COL[a]][i - 1] for a in ASSETS}
        new = {a: cols[TARGET_COL[a]][i] for a in ASSETS}
        delta = {a: new[a] - prior[a] for a in ASSETS}
        turnover = sum(abs(v) for v in delta.values())
        if turnover < 0.02:
            continue
        ranks = composite_rank(cube, i - 1)
        if ranks is None:
            continue
        ordered = sorted(ASSETS, key=lambda a: ranks[a], reverse=True)
        top1 = {ordered[0]}
        top2 = set(ordered[:2])
        sale_top1 = sum(max(-delta[a], 0.0) for a in top1)
        sale_top2 = sum(max(-delta[a], 0.0) for a in top2)
        buy_top2 = sum(max(delta[a], 0.0) for a in top2)
        alignment = sum(delta[a] * (ranks[a] - 0.5) for a in ASSETS)
        gross_decrease = sum(prior.values()) - sum(new.values())
        us_decrease = (prior["nasdaq"] + prior["sp500"]) - (new["nasdaq"] + new["sp500"])
        row = {
            "date": dates[i],
            "signal_date": dates[i - 1],
            "turnover": turnover,
            "gross_decrease": gross_decrease,
            "us_decrease": us_decrease,
            "factor_alignment": alignment,
            "sale_top1": sale_top1,
            "sale_top2": sale_top2,
            "buy_top2": buy_top2,
            "top1": ordered[0],
            "top2": "|".join(ordered[:2]),
        }
        for h in [5, 20, 60]:
            rn = static_return(new, prices, i, h)
            rp = static_return(prior, prices, i, h)
            row[f"edge{h}"] = None if rn is None or rp is None else rn - rp - COST * turnover
        events.append(row)
    return events


def regression_rows(events):
    out = []
    for event_type, pred in [
        ("all", lambda e: True),
        ("derisk", lambda e: e["gross_decrease"] >= 0.03),
        ("us_derisk", lambda e: e["us_decrease"] >= 0.05 and e["gross_decrease"] >= 0.03),
        ("non_us_derisk", lambda e: e["us_decrease"] < 0.05 and e["gross_decrease"] >= 0.03),
    ]:
        subset = [e for e in events if pred(e)]
        for h in [5, 20, 60]:
            for f in ["factor_alignment", "sale_top1", "sale_top2", "buy_top2"]:
                xy = [(float(e[f]), float(e[f"edge{h}"])) for e in subset if isinstance(e[f"edge{h}"], (int, float)) and math.isfinite(float(e[f"edge{h}"]))]
                if len(xy) < 20:
                    continue
                xs, ys = map(list, zip(*xy))
                r = lab.nw_univariate(xs, ys, 0)
                if r:
                    out.append({
                        "event_type": event_type,
                        "horizon": h,
                        "factor": f,
                        "n": len(xs),
                        "beta_sd": r.beta,
                        "t": r.beta_t,
                        "p": r.p_value,
                        "r2": r.r2,
                        "spearman": lab.spearman(xs, ys),
                    })
    return out


def group_rows(events):
    rows = []
    groups = [
        ("derisk_sell_top1", lambda e: e["gross_decrease"] >= .03 and e["sale_top1"] >= .03),
        ("derisk_sell_top2", lambda e: e["gross_decrease"] >= .03 and e["sale_top2"] >= .05),
        ("derisk_sell_top2_large", lambda e: e["gross_decrease"] >= .03 and e["sale_top2"] >= .15),
        ("derisk_no_top2_sale", lambda e: e["gross_decrease"] >= .03 and e["sale_top2"] < .05),
        ("us_derisk_sell_top2", lambda e: e["us_decrease"] >= .05 and e["gross_decrease"] >= .03 and e["sale_top2"] >= .05),
        ("non_us_derisk_sell_top2", lambda e: e["us_decrease"] < .05 and e["gross_decrease"] >= .03 and e["sale_top2"] >= .05),
    ]
    for name, pred in groups:
        g = [e for e in events if pred(e)]
        for h in [5,20,60]:
            y = [float(e[f"edge{h}"]) for e in g if isinstance(e[f"edge{h}"], (int,float)) and math.isfinite(float(e[f"edge{h}"]))]
            if not y: continue
            m,t,p = __import__('daily_cross_sectional_factor_lab').nw_mean_t(y,0)
            rows.append({"group":name,"horizon":h,"n":len(y),"mean_edge":m,"t":t,"p":p,"win_rate":sum(v>0 for v in y)/len(y)})
    return rows


def write_csv(path, rows):
    if not rows:return
    with path.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()));w.writeheader();w.writerows(rows)


def main():
    events=build_events(); regs=regression_rows(events); groups=group_rows(events)
    write_csv(OUT/'factor_trade_events.csv',events)
    write_csv(OUT/'factor_trade_regressions.csv',regs)
    write_csv(OUT/'factor_trade_groups.csv',groups)
    print('FACTOR_TRADE_ATTRIBUTION')
    print('events',len(events))
    for r in sorted(regs,key=lambda x:abs(float(x['t'])),reverse=True)[:18]:
        print('REG',r)
    for r in groups:
        print('GROUP',r)

if __name__=='__main__':main()
