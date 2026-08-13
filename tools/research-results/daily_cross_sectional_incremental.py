#!/usr/bin/env python3
"""Incremental cross-sectional alpha test conditional on production target weights.

For each date and horizon, run a 5-sleeve cross-sectional regression of future
return ranks on (1) current production target-weight ranks and (2) candidate
factor ranks. The time-series of daily factor coefficients is then tested with
Newey-West errors. This asks whether the candidate carries information not
already encoded in production allocation.
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
HORIZONS = [5, 20, 60]
TARGET_COL = {
    "gold": "target_gold",
    "nasdaq": "target_nasdaq",
    "sp500": "target_sp500",
    "csi300": "target_csi300",
    "shanghai": "target_shanghai",
}


def centered_ranks(values: list[float]) -> list[float]:
    ranks = lab.rankdata(values)
    m = lab.mean(ranks)
    sd = lab.stdev(ranks)
    if not math.isfinite(sd) or sd <= 1e-12:
        return [0.0] * len(values)
    return [(r - m) / sd for r in ranks]


def daily_two_predictor_beta(y: list[float], w: list[float], f: list[float]) -> tuple[float, float] | None:
    # Within-date centered ranks => intercept is zero by construction.
    yy = centered_ranks(y)
    ww = centered_ranks(w)
    ff = centered_ranks(f)
    sww = sum(x * x for x in ww)
    sff = sum(x * x for x in ff)
    swf = sum(x * z for x, z in zip(ww, ff))
    swy = sum(x * z for x, z in zip(ww, yy))
    sfy = sum(x * z for x, z in zip(ff, yy))
    det = sww * sff - swf * swf
    if abs(det) < 1e-10:
        return None
    bw = (swy * sff - sfy * swf) / det
    bf = (sfy * sww - swy * swf) / det
    return bw, bf


def nw_mean(values: list[float], lag: int) -> tuple[float, float, float]:
    return xlab.nw_mean_t(values, lag)


def factor_weight_overlap(
    dates: list[str],
    cols: dict[str, list[float]],
    cube: dict[str, list[float | None]],
) -> dict[str, float]:
    daily_corr = []
    top_match = 0
    top2_overlap = []
    n = 0
    for i in range(len(dates)):
        fs = [cube[a][i] for a in ASSETS]
        ws = [cols[TARGET_COL[a]][i] for a in ASSETS]
        if any(v is None or not math.isfinite(float(v)) for v in fs if v is not None) or any(v is None for v in fs):
            continue
        f = [float(v) for v in fs if v is not None]
        corr = lab.spearman(f, ws)
        if math.isfinite(corr):
            daily_corr.append(corr)
        f_order = sorted(range(5), key=lambda j: f[j], reverse=True)
        w_order = sorted(range(5), key=lambda j: ws[j], reverse=True)
        top_match += int(f_order[0] == w_order[0])
        top2_overlap.append(len(set(f_order[:2]) & set(w_order[:2])) / 2.0)
        n += 1
    return {
        "overlap_n": n,
        "mean_rank_corr_with_target": lab.mean(daily_corr) if daily_corr else float("nan"),
        "top1_match_rate": top_match / n if n else float("nan"),
        "top2_mean_overlap": lab.mean(top2_overlap) if top2_overlap else float("nan"),
    }


def evaluate() -> list[dict[str, object]]:
    dates, cols = lab.read_panel()
    factor_cube = xlab.build_asset_factor_cube(cols)
    rows: list[dict[str, object]] = []

    for horizon in HORIZONS:
        fwd = xlab.forward_cube(cols, horizon)
        temp: list[dict[str, object]] = []
        pdev: list[tuple[str, float]] = []
        for factor_name, cube in factor_cube.items():
            daily_factor_beta: dict[str, list[float]] = {"dev": [], "validation": [], "holdout": []}
            daily_weight_beta: dict[str, list[float]] = {"dev": [], "validation": [], "holdout": []}
            for i, d in enumerate(dates):
                fv = [cube[a][i] for a in ASSETS]
                yv = [fwd[a][i] for a in ASSETS]
                wv = [cols[TARGET_COL[a]][i] for a in ASSETS]
                if any(v is None for v in fv) or any(v is None for v in yv):
                    continue
                f = [float(v) for v in fv if v is not None]
                y = [float(v) for v in yv if v is not None]
                if any(not math.isfinite(v) for v in f + y + wv):
                    continue
                coef = daily_two_predictor_beta(y, wv, f)
                if coef is None:
                    continue
                bw, bf = coef
                split = lab.split_name(d)
                daily_weight_beta[split].append(bw)
                daily_factor_beta[split].append(bf)
            if min(len(daily_factor_beta[s]) for s in daily_factor_beta) < 100:
                continue
            dev_m, dev_t, dev_p = nw_mean(daily_factor_beta["dev"], horizon - 1)
            val_m, val_t, _ = nw_mean(daily_factor_beta["validation"], horizon - 1)
            hold_m, hold_t, _ = nw_mean(daily_factor_beta["holdout"], horizon - 1)
            wdev_m, wdev_t, _ = nw_mean(daily_weight_beta["dev"], horizon - 1)
            overlap = factor_weight_overlap(dates, cols, cube)
            rec: dict[str, object] = {
                "horizon": horizon,
                "factor": factor_name,
                "dev_n": len(daily_factor_beta["dev"]),
                "dev_factor_beta": dev_m,
                "dev_factor_t_nw": dev_t,
                "dev_factor_p": dev_p,
                "val_factor_beta": val_m,
                "val_factor_t_nw": val_t,
                "hold_factor_beta": hold_m,
                "hold_factor_t_nw": hold_t,
                "dev_weight_beta": wdev_m,
                "dev_weight_t_nw": wdev_t,
                "val_sign_stable": 1 if dev_m * val_m > 0 else 0,
                "hold_sign_stable": 1 if dev_m * hold_m > 0 else 0,
                **overlap,
            }
            temp.append(rec)
            pdev.append((factor_name, dev_p))
        qvals = lab.bh_qvalues(pdev)
        for r in temp:
            r["dev_bh_q"] = qvals.get(str(r["factor"]), float("nan"))
            r["score"] = abs(float(r["dev_factor_t_nw"])) + 1.5 * int(r["val_sign_stable"]) + 1.0 * int(r["hold_sign_stable"]) + (1.0 if float(r["dev_bh_q"]) <= 0.05 else 0.0)
            rows.append(r)
    return rows


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


def write_report(path: Path, rows: list[dict[str, object]]) -> None:
    lines = [
        "# Cross-sectional incremental alpha conditional on production weights",
        "",
        "Each day: future return rank ~ production target-weight rank + candidate factor rank. Daily factor coefficients are aggregated with Newey-West errors.",
        "",
    ]
    for h in HORIZONS:
        sub = [r for r in rows if r["horizon"] == h]
        sub.sort(key=lambda r: (-float(r["score"]), float(r["dev_bh_q"])))
        lines += [f"## Horizon {h}", "", "| factor | dev β | NW t | BH q | val β | hold β | corr w/target | top1 match | top2 overlap |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for r in sub[:20]:
            lines.append(
                f"| {r['factor']} | {float(r['dev_factor_beta']):+.3f} | {float(r['dev_factor_t_nw']):+.2f} | {float(r['dev_bh_q']):.4f} | "
                f"{float(r['val_factor_beta']):+.3f} | {float(r['hold_factor_beta']):+.3f} | {float(r['mean_rank_corr_with_target']):+.3f} | "
                f"{float(r['top1_match_rate']):.3f} | {float(r['top2_mean_overlap']):.3f} |"
            )
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    rows = evaluate()
    rows.sort(key=lambda r: (int(r["horizon"]), -float(r["score"])))
    out_csv = OUT / "cross_sectional_incremental_scores.csv"
    write_csv(out_csv, rows)
    report = OUT / "cross_sectional_incremental_summary.md"
    write_report(report, rows)
    print("CROSS_SECTIONAL_INCREMENTAL")
    print(f"rows={len(rows)} report={report}")
    for h in HORIZONS:
        sub = [r for r in rows if r["horizon"] == h]
        sub.sort(key=lambda r: (-float(r["score"]), float(r["dev_bh_q"])))
        print("TOP horizon", h)
        for r in sub[:12]:
            print(
                f"{r['factor']} beta={float(r['dev_factor_beta']):+.3f} t={float(r['dev_factor_t_nw']):+.2f} q={float(r['dev_bh_q']):.4g} "
                f"val={float(r['val_factor_beta']):+.3f} hold={float(r['hold_factor_beta']):+.3f} "
                f"target_corr={float(r['mean_rank_corr_with_target']):+.3f} top1={float(r['top1_match_rate']):.3f}"
            )


if __name__ == "__main__":
    main()
