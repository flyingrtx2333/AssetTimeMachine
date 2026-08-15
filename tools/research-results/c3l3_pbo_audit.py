#!/usr/bin/env python3
"""CSCV/PBO audit for the frozen coarse C3/L3 parameter family.

Input panel is produced by tools/c3l3_pbo_panel.swiftpart using the exact Swift App engine.
The 27 C/L/generic-retention variants are intentionally the already-researched coarse grid;
this script does not create or tune new parameters.
"""
from __future__ import annotations

import argparse
import csv
import itertools
import math
from collections import Counter
from pathlib import Path

SQRT_252 = math.sqrt(252.0)
TIE_EPS = 1e-10


def read_value_panel(path: Path) -> tuple[list[str], list[str], list[list[float]]]:
    rows = list(csv.reader(path.open(encoding="utf-8")))
    header = rows[0]
    dates = []
    values = [[] for _ in header[1:]]
    for row in rows[1:]:
        if len(row) != len(header):
            continue
        dates.append(row[0])
        for j, x in enumerate(row[1:]):
            values[j].append(float(x))
    return dates, header[1:], values


def read_base(path: Path, wanted_dates: list[str]) -> list[float]:
    data = {r["date"]: float(r["portfolio_value"]) for r in csv.DictReader(path.open(encoding="utf-8"))}
    return [data[d] for d in wanted_dates]


def to_returns(values: list[float]) -> list[float]:
    return [values[i] / values[i-1] - 1 for i in range(1, len(values))]


def sharpe_from_stats(n: int, s: float, ss: float) -> float:
    if n <= 1:
        return -1e9
    mean = s / n
    var = max((ss - s*s/n) / (n-1), 0.0)
    if var <= 1e-24:
        return -1e9
    return mean / math.sqrt(var) * SQRT_252


def partition_stats(matrix: list[list[float]], blocks: int) -> list[list[tuple[int, float, float]]]:
    n = len(matrix[0])
    m = len(matrix)
    out = [[(0,0.0,0.0) for _ in range(m)] for _ in range(blocks)]
    starts = [round(i*n/blocks) for i in range(blocks+1)]
    for b in range(blocks):
        lo, hi = starts[b], starts[b+1]
        for j in range(m):
            xs = matrix[j][lo:hi]
            out[b][j] = (len(xs), sum(xs), sum(x*x for x in xs))
    return out


def aggregate(block_stats: list[list[tuple[int,float,float]]], chosen: set[int], m: int) -> list[float]:
    result = []
    for j in range(m):
        nn=0; s=0.0; ss=0.0
        for b in chosen:
            bn, bs, bss = block_stats[b][j]
            nn += bn; s += bs; ss += bss
        result.append(sharpe_from_stats(nn,s,ss))
    return result


def percentile_rank(values: list[float], selected_index: int) -> float:
    v = values[selected_index]
    less = sum(x < v - TIE_EPS for x in values)
    equal = sum(abs(x-v) <= TIE_EPS for x in values)
    mid = less + 0.5 * max(equal, 1)
    return (mid + 0.5) / (len(values) + 1.0)


def spearman(a: list[float], b: list[float]) -> float:
    def ranks(xs: list[float]) -> list[float]:
        order = sorted(range(len(xs)), key=lambda i: xs[i])
        r = [0.0]*len(xs)
        pos=0
        while pos < len(order):
            end=pos+1
            while end < len(order) and abs(xs[order[end]]-xs[order[pos]]) <= TIE_EPS:
                end += 1
            avg = (pos + end - 1)/2 + 1
            for k in range(pos,end): r[order[k]]=avg
            pos=end
        return r
    ra,rb=ranks(a),ranks(b)
    ma=sum(ra)/len(ra); mb=sum(rb)/len(rb)
    num=sum((x-ma)*(y-mb) for x,y in zip(ra,rb))
    den=math.sqrt(sum((x-ma)**2 for x in ra)*sum((y-mb)**2 for y in rb))
    return num/den if den>1e-18 else 0.0


def audit(matrix: list[list[float]], ids: list[str], blocks: int, base_index: int, champion_index: int) -> None:
    stats = partition_stats(matrix, blocks)
    half = blocks//2
    combos = list(itertools.combinations(range(blocks), half))
    lambdas=[]; oos_ranks=[]; select_counts=Counter(); under_base=0; top_quartile=0; rank_corr=[]
    champion_beats_base=0; champion_oos_sharpes=[]; base_oos_sharpes=[]
    for comb in combos:
        ins=set(comb); outs=set(range(blocks))-ins
        is_s=aggregate(stats,ins,len(ids)); oos_s=aggregate(stats,outs,len(ids))
        best=max(range(len(ids)),key=lambda j:(is_s[j],ids[j]))
        select_counts[ids[best]] += 1
        rank=percentile_rank(oos_s,best)
        rank=min(max(rank,1e-9),1-1e-9)
        oos_ranks.append(rank)
        lambdas.append(math.log(rank/(1-rank)))
        if oos_s[best] < oos_s[base_index]: under_base += 1
        if rank >= .75: top_quartile += 1
        rank_corr.append(spearman(is_s,oos_s))
        champion_oos_sharpes.append(oos_s[champion_index]); base_oos_sharpes.append(oos_s[base_index])
        if oos_s[champion_index] > oos_s[base_index]: champion_beats_base += 1
    n=len(combos)
    pbo=sum(x<=0 for x in lambdas)/n
    sranks=sorted(oos_ranks)
    med=sranks[n//2]
    q10=sranks[int(.10*(n-1))]; q90=sranks[int(.90*(n-1))]
    avg_corr=sum(rank_corr)/n
    print(f"CSCV,blocks={blocks},splits={n},pbo={pbo:.6f},selected_oos_rank_median={med:.4f},rank_p10={q10:.4f},rank_p90={q90:.4f},selected_under_base={under_base/n:.4%},selected_top_quartile={top_quartile/n:.4%},mean_is_oos_rank_corr={avg_corr:.4f}")
    print(f"FIXED_CHAMPION,blocks={blocks},champion={ids[champion_index]},beats_base_oos={champion_beats_base/n:.4%},champion_oos_sharpe_mean={sum(champion_oos_sharpes)/n:.4f},base_oos_sharpe_mean={sum(base_oos_sharpes)/n:.4f}")
    top=select_counts.most_common(8)
    print("SELECTION_FREQ,blocks=%d,%s" % (blocks, "|".join(f"{k}:{v/n:.2%}" for k,v in top)))


def main() -> None:
    ap=argparse.ArgumentParser()
    ap.add_argument("--panel",default="/private/tmp/c3l3_pbo_panel.csv")
    ap.add_argument("--base",default="tools/research-results/daily_factor_panel.csv")
    args=ap.parse_args()
    dates,ids,vals=read_value_panel(Path(args.panel))
    base=read_base(Path(args.base),dates)
    ids=["low_noise_base"]+ids
    vals=[base]+vals
    matrix=[to_returns(v) for v in vals]
    champion="cm0.03_lm0.03_g1.00"
    if champion not in ids:
        raise RuntimeError(f"champion id missing; available={ids}")
    base_index=ids.index("low_noise_base"); champion_index=ids.index(champion)
    full=[sharpe_from_stats(len(r),sum(r),sum(x*x for x in r)) for r in matrix]
    ranking=sorted(range(len(ids)),key=lambda j:full[j],reverse=True)
    print("C3L3_CSCV_PBO_AUDIT_V1")
    print(f"rows={len(dates)},returns={len(matrix[0])},candidates={len(ids)},champion={champion},champion_full_rank={ranking.index(champion_index)+1},champion_full_sharpe={full[champion_index]:.6f},base_full_sharpe={full[base_index]:.6f}")
    print("FULL_TOP,"+"|".join(f"{ids[j]}:{full[j]:.4f}" for j in ranking[:8]))
    for blocks in [8,10,12,16]:
        audit(matrix,ids,blocks,base_index,champion_index)


if __name__=="__main__":
    main()
