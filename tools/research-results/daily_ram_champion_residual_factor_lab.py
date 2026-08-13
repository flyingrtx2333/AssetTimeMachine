#!/usr/bin/env python3
"""Factor lab for RAM85soft15 residual alpha versus production baseline.

The dependent variable is candidate forward return minus production baseline
forward return. Candidate selection uses development significance and validation
direction; holdout is diagnostic only.
"""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import daily_alpha_factor_lab as lab  # noqa: E402

OUT = HERE / "daily-factor-lab"
POINTS = OUT / "g85_v80_s40_points.csv"
HORIZONS = [5, 20, 60]


def candidate_values(dates: list[str]) -> list[float | None]:
    values = {}
    with POINTS.open(newline="") as f:
        for row in csv.DictReader(f):
            v = lab.safe_float(row.get("value"))
            if v is not None:
                values[row["date"]] = v
    return [values.get(d) for d in dates]


def forward_excess(candidate, baseline, h):
    out = [None] * len(baseline)
    for i in range(len(baseline) - h):
        c0, c1 = candidate[i], candidate[i+h]
        b0, b1 = baseline[i], baseline[i+h]
        if c0 is None or c1 is None or c0 <= 0 or c1 <= 0 or b0 <= 0 or b1 <= 0:
            continue
        out[i] = c1 / c0 - b1 / b0
    return out


def evaluate(dates, factors, families, labels):
    rows = []
    for label_name, (y, h) in labels.items():
        temp = []
        ptests = []
        for factor, x in factors.items():
            if families[factor] == "strategy_state" and factor not in {"state_cash_ratio", "state_target_gross"}:
                continue
            xdev, ydev = lab.valid_xy(dates, x, y, "dev")
            xval, yval = lab.valid_xy(dates, x, y, "validation")
            xhold, yhold = lab.valid_xy(dates, x, y, "holdout")
            if min(len(xdev), len(xval), len(xhold)) < 80:
                continue
            dev = lab.nw_univariate(xdev, ydev, h - 1)
            val = lab.nw_univariate(xval, yval, h - 1)
            hold = lab.nw_univariate(xhold, yhold, h - 1)
            if dev is None or val is None or hold is None:
                continue
            rec = {
                "label": label_name,
                "horizon": h,
                "factor": factor,
                "family": families[factor],
                "dev_beta_sd": dev.beta,
                "dev_t_nw": dev.beta_t,
                "dev_p": dev.p_value,
                "dev_r2": dev.r2,
                "val_beta_sd": val.beta,
                "val_t_nw": val.beta_t,
                "hold_beta_sd": hold.beta,
                "hold_t_nw": hold.beta_t,
                "dev_spearman": lab.spearman(xdev, ydev),
                "val_spearman": lab.spearman(xval, yval),
                "hold_spearman": lab.spearman(xhold, yhold),
                "val_sign_stable": int(dev.beta * val.beta > 0),
                "hold_sign_stable": int(dev.beta * hold.beta > 0),
            }
            temp.append(rec)
            ptests.append((factor, dev.p_value))
        q = lab.bh_qvalues(ptests)
        for rec in temp:
            rec["dev_bh_q"] = q.get(str(rec["factor"]), float("nan"))
            rec["selection_score"] = abs(float(rec["dev_t_nw"])) + 1.5 * int(rec["val_sign_stable"]) + (1.0 if float(rec["dev_bh_q"]) <= .05 else 0.0)
            rows.append(rec)
    return rows


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


def main():
    dates, cols = lab.read_panel()
    candidate = candidate_values(dates)
    if sum(v is not None for v in candidate) < 6000:
        raise SystemExit("candidate point series incomplete")
    factors, families = lab.build_factors(dates, cols)
    labels = {
        f"ram_excess_{h}": (forward_excess(candidate, cols["portfolio_value"], h), h)
        for h in HORIZONS
    }
    rows = evaluate(dates, factors, families, labels)
    rows.sort(key=lambda r: (int(r["horizon"]), -float(r["selection_score"])))
    write_csv(OUT / "ram_residual_factor_scores.csv", rows)
    print("RAM_CHAMPION_RESIDUAL_FACTOR_LAB")
    for h in HORIZONS:
        sub = [r for r in rows if r["horizon"] == h]
        sub.sort(key=lambda r: (-float(r["selection_score"]), float(r["dev_bh_q"])))
        print("TOP", h)
        for r in sub[:15]:
            print(
                f"{r['factor']} fam={r['family']} devBeta={float(r['dev_beta_sd']):+.6f} "
                f"t={float(r['dev_t_nw']):+.2f} q={float(r['dev_bh_q']):.4g} "
                f"val={float(r['val_beta_sd']):+.6f} hold={float(r['hold_beta_sd']):+.6f} "
                f"valOK={r['val_sign_stable']} holdOK={r['hold_sign_stable']}"
            )


if __name__ == "__main__":
    main()
