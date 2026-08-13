#!/usr/bin/env python3
"""Strict online Fama-MacBeth ensemble for the two RAM factor families.

At each signal date, cross-sectionally regress 20-session future return ranks of
five sleeves on RAM(60,20) and RAM(252,60) ranks. A coefficient observation only
becomes available after the 20-session forward return is fully realized. Live
factor premia are the expanding or rolling mean of already-realized coefficients.
No future observation is used to form a score.
"""
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
HORIZON = 20


def zrank(values: list[float]) -> list[float]:
    r = lab.rankdata(values)
    m = lab.mean(r)
    sd = lab.stdev(r)
    if not math.isfinite(sd) or sd <= 1e-12:
        return [0.0] * len(values)
    return [(x - m) / sd for x in r]


def daily_fm_coefficients(dates, cols, cube):
    fwd = {a: lab.forward_return(cols[f"price_{a}"], HORIZON) for a in ASSETS}
    short = cube["risk_adjusted_momentum_60_20"]
    long = cube["risk_adjusted_momentum_252_60"]
    coeffs: list[tuple[int, float, float]] = []
    for i in range(len(dates) - HORIZON):
        xs = [short[a][i] for a in ASSETS]
        xl = [long[a][i] for a in ASSETS]
        yy = [fwd[a][i] for a in ASSETS]
        if any(v is None for v in xs + xl + yy):
            continue
        xsf = [float(v) for v in xs if v is not None]
        xlf = [float(v) for v in xl if v is not None]
        yyf = [float(v) for v in yy if v is not None]
        if any(not math.isfinite(v) for v in xsf + xlf + yyf):
            continue
        xrows = list(zip(zrank(xsf), zrank(xlf)))
        result = lab.multivariate_ols([list(r) for r in xrows], zrank(yyf))
        if result is None:
            continue
        coef, _ = result
        coeffs.append((i, coef[1], coef[2]))
    return coeffs


def mean_pair(rows):
    if not rows:
        return None
    return lab.mean([r[1] for r in rows]), lab.mean([r[2] for r in rows])


def online_scores(dates, cols, cube, coeffs, window: int | None):
    short = cube["risk_adjusted_momentum_60_20"]
    long = cube["risk_adjusted_momentum_252_60"]
    fwd = {a: lab.forward_return(cols[f"price_{a}"], HORIZON) for a in ASSETS}
    result_rows = []
    for i in range(len(dates) - HORIZON):
        # Coefficient from signal j is known only once j+HORIZON <= i.
        eligible = [r for r in coeffs if r[0] + HORIZON <= i]
        if window is not None:
            eligible = [r for r in eligible if r[0] >= i - window]
        if len(eligible) < 126:
            continue
        premia = mean_pair(eligible)
        if premia is None:
            continue
        b_short, b_long = premia
        xs = [short[a][i] for a in ASSETS]
        xl = [long[a][i] for a in ASSETS]
        yy = [fwd[a][i] for a in ASSETS]
        if any(v is None for v in xs + xl + yy):
            continue
        rs = zrank([float(v) for v in xs if v is not None])
        rl = zrank([float(v) for v in xl if v is not None])
        y = [float(v) for v in yy if v is not None]
        score = [b_short * a + b_long * b for a, b in zip(rs, rl)]
        ic = lab.spearman(score, y)
        order = sorted(range(len(score)), key=lambda j: score[j])
        spread = lab.mean([y[j] for j in order[-2:]]) - lab.mean([y[j] for j in order[:2]])
        result_rows.append({
            "date": dates[i],
            "split": lab.split_name(dates[i]),
            "b_short": b_short,
            "b_long": b_long,
            "ic": ic,
            "top2_bottom2": spread,
        })
    return result_rows


def nw_mean(values):
    return xlab.nw_mean_t(values, HORIZON - 1)


def summarize(name, rows):
    out = []
    for split in ["dev", "validation", "holdout", "all"]:
        g = rows if split == "all" else [r for r in rows if r["split"] == split]
        if len(g) < 50:
            continue
        ics = [float(r["ic"]) for r in g]
        spreads = [float(r["top2_bottom2"]) for r in g]
        icm, ict, icp = nw_mean(ics)
        spm, spt, spp = nw_mean(spreads)
        out.append({
            "model": name,
            "split": split,
            "n": len(g),
            "mean_ic": icm,
            "ic_t_nw": ict,
            "ic_p": icp,
            "mean_top2_bottom2": spm,
            "spread_t_nw": spt,
            "spread_p": spp,
            "last_b_short": g[-1]["b_short"],
            "last_b_long": g[-1]["b_long"],
        })
    return out


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


def main():
    dates, cols = lab.read_panel()
    cube = xlab.build_asset_factor_cube(cols)
    coeffs = daily_fm_coefficients(dates, cols, cube)
    all_summaries = []
    for name, window in [("expanding", None), ("rolling756", 756), ("rolling1260", 1260)]:
        rows = online_scores(dates, cols, cube, coeffs, window)
        write_csv(OUT / f"online_fm_{name}_daily.csv", rows)
        all_summaries += summarize(name, rows)
    write_csv(OUT / "online_fm_summary.csv", all_summaries)
    print("ONLINE_FAMA_MACBETH")
    print("daily_coefficients", len(coeffs))
    for r in all_summaries:
        print(r)


if __name__ == "__main__":
    main()
