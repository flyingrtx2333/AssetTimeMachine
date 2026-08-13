#!/usr/bin/env python3
"""Second-stage factor regression and incremental contribution analysis.

Consumes daily_alpha_factor_lab.py outputs/functions. Research only.
"""
from __future__ import annotations

import csv
import math
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import daily_alpha_factor_lab as lab  # noqa: E402

OUT_DIR = HERE / "daily-factor-lab"
SCORES = OUT_DIR / "factor_univariate_scores.csv"

STATE_CONTROLS = [
    "state_target_gold",
    "state_target_nasdaq",
    "state_target_sp500",
    "state_target_csi300",
    "state_target_shanghai",
]

# Raw persistent levels are retained in first-pass diagnostics but cannot be
# promoted directly without a stationary transformation.
NONPROMOTABLE_RAW_LEVELS = {"real10_level"}


@dataclass
class GeneralOLS:
    coef: list[float]
    se: list[float]
    t: list[float]
    p: list[float]
    r2: float
    n: int


def matmul(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [[sum(a[i][k] * b[k][j] for k in range(len(b))) for j in range(len(b[0]))] for i in range(len(a))]


def transpose(a: list[list[float]]) -> list[list[float]]:
    return [list(row) for row in zip(*a)]


def general_ols_hac(xrows: list[list[float]], ys: list[float], lag: int) -> GeneralOLS | None:
    if not xrows or len(xrows) != len(ys):
        return None
    n = len(ys)
    k = len(xrows[0])
    if n < max(40, k * 8):
        return None
    zrows = [[1.0] + row for row in xrows]
    p = k + 1
    xtx = [[0.0] * p for _ in range(p)]
    xty = [0.0] * p
    for z, y in zip(zrows, ys):
        for i in range(p):
            xty[i] += z[i] * y
            for j in range(p):
                xtx[i][j] += z[i] * z[j]
    inv = lab.matrix_inverse(xtx)
    if inv is None:
        return None
    coef = lab.mat_vec(inv, xty)
    residuals = [y - sum(c * z for c, z in zip(coef, row)) for row, y in zip(zrows, ys)]

    meat = [[0.0] * p for _ in range(p)]
    for z, u in zip(zrows, residuals):
        uu = u * u
        for i in range(p):
            for j in range(p):
                meat[i][j] += uu * z[i] * z[j]
    max_lag = max(0, min(lag, n - 2))
    for ell in range(1, max_lag + 1):
        w = 1.0 - ell / (max_lag + 1.0)
        for t in range(ell, n):
            z0, z1 = zrows[t], zrows[t - ell]
            cross = w * residuals[t] * residuals[t - ell]
            for i in range(p):
                for j in range(p):
                    meat[i][j] += cross * (z0[i] * z1[j] + z1[i] * z0[j])
    cov = matmul(matmul(inv, meat), inv)
    se = [math.sqrt(max(cov[i][i], 0.0)) for i in range(p)]
    tstats = [coef[i] / se[i] if se[i] > 1e-18 else float("nan") for i in range(p)]
    pvals = [lab.normal_two_sided_p(t) for t in tstats]
    ybar = lab.mean(ys)
    sst = sum((y - ybar) ** 2 for y in ys)
    sse = sum(u * u for u in residuals)
    r2 = 1.0 - sse / sst if sst > 0 else 0.0
    return GeneralOLS(coef=coef, se=se, t=tstats, p=pvals, r2=r2, n=n)


def train_stats(values: list[float]) -> tuple[float, float]:
    m = lab.mean(values)
    sd = lab.stdev(values)
    return m, sd if math.isfinite(sd) and sd > 1e-12 else 1.0


def standardize_dataset(
    dates: list[str],
    factors: dict[str, list[float | None]],
    label: list[float | None],
    names: list[str],
    fit_splits: set[str],
    eval_split: str,
) -> tuple[list[list[float]], list[float], list[list[float]], list[float], dict[str, tuple[float, float]]]:
    fit_indices = []
    eval_indices = []
    for i, d in enumerate(dates):
        values = [factors[n][i] for n in names]
        y = label[i]
        if y is None or not math.isfinite(y) or any(v is None or not math.isfinite(v) for v in values):
            continue
        split = lab.split_name(d)
        if split in fit_splits:
            fit_indices.append(i)
        if split == eval_split:
            eval_indices.append(i)
    stats: dict[str, tuple[float, float]] = {}
    for name in names:
        xs = [float(factors[name][i]) for i in fit_indices]
        stats[name] = train_stats(xs)

    def rows(indices: list[int]) -> tuple[list[list[float]], list[float]]:
        xr, yr = [], []
        for i in indices:
            row = []
            for name in names:
                m, sd = stats[name]
                row.append((float(factors[name][i]) - m) / sd)
            xr.append(row)
            yr.append(float(label[i]))
        return xr, yr

    xfit, yfit = rows(fit_indices)
    xeval, yeval = rows(eval_indices)
    return xfit, yfit, xeval, yeval, stats


def predict(coef: list[float], xrows: list[list[float]]) -> list[float]:
    return [coef[0] + sum(c * x for c, x in zip(coef[1:], row)) for row in xrows]


def oos_r2(y: list[float], pred: list[float], benchmark_mean: float) -> float:
    if not y:
        return float("nan")
    sse = sum((a - b) ** 2 for a, b in zip(y, pred))
    sst = sum((a - benchmark_mean) ** 2 for a in y)
    return 1.0 - sse / sst if sst > 0 else float("nan")


def nested_incremental(
    dates: list[str],
    factors: dict[str, list[float | None]],
    label: list[float | None],
    horizon: int,
    candidate: str,
) -> dict[str, float] | None:
    controls = [x for x in STATE_CONTROLS if x != candidate]
    if candidate in controls:
        return None

    # Development conditional regression and partial R².
    names_full = controls + [candidate]
    fit_idx = []
    for i, d in enumerate(dates):
        if lab.split_name(d) != "dev":
            continue
        y = label[i]
        vals = [factors[n][i] for n in names_full]
        if y is None or any(v is None for v in vals):
            continue
        if not math.isfinite(float(y)) or any(not math.isfinite(float(v)) for v in vals if v is not None):
            continue
        fit_idx.append(i)
    if len(fit_idx) < 300:
        return None
    stats = {name: train_stats([float(factors[name][i]) for i in fit_idx]) for name in names_full}
    x_base, x_full, y_dev = [], [], []
    for i in fit_idx:
        base = [(float(factors[n][i]) - stats[n][0]) / stats[n][1] for n in controls]
        cand = (float(factors[candidate][i]) - stats[candidate][0]) / stats[candidate][1]
        x_base.append(base)
        x_full.append(base + [cand])
        y_dev.append(float(label[i]))
    base_dev = general_ols_hac(x_base, y_dev, horizon - 1)
    full_dev = general_ols_hac(x_full, y_dev, horizon - 1)
    if base_dev is None or full_dev is None:
        return None
    partial = (full_dev.r2 - base_dev.r2) / max(1.0 - base_dev.r2, 1e-12)

    # Validation: fit development, compare OOS predictive R².
    def build_eval(split: str, train_splits: set[str]):
        train_indices, eval_indices = [], []
        for i, d in enumerate(dates):
            y = label[i]
            vals = [factors[n][i] for n in names_full]
            if y is None or any(v is None for v in vals):
                continue
            if not math.isfinite(float(y)) or any(not math.isfinite(float(v)) for v in vals if v is not None):
                continue
            s = lab.split_name(d)
            if s in train_splits:
                train_indices.append(i)
            elif s == split:
                eval_indices.append(i)
        if len(train_indices) < 300 or len(eval_indices) < 80:
            return None
        local_stats = {name: train_stats([float(factors[name][i]) for i in train_indices]) for name in names_full}
        xb_tr, xf_tr, ytr = [], [], []
        xb_ev, xf_ev, yev = [], [], []
        for i in train_indices:
            b = [(float(factors[n][i]) - local_stats[n][0]) / local_stats[n][1] for n in controls]
            c = (float(factors[candidate][i]) - local_stats[candidate][0]) / local_stats[candidate][1]
            xb_tr.append(b); xf_tr.append(b + [c]); ytr.append(float(label[i]))
        for i in eval_indices:
            b = [(float(factors[n][i]) - local_stats[n][0]) / local_stats[n][1] for n in controls]
            c = (float(factors[candidate][i]) - local_stats[candidate][0]) / local_stats[candidate][1]
            xb_ev.append(b); xf_ev.append(b + [c]); yev.append(float(label[i]))
        bfit = lab.multivariate_ols(xb_tr, ytr)
        ffit = lab.multivariate_ols(xf_tr, ytr)
        if bfit is None or ffit is None:
            return None
        bcoef, _ = bfit
        fcoef, _ = ffit
        bm = lab.mean(ytr)
        br2 = oos_r2(yev, predict(bcoef, xb_ev), bm)
        fr2 = oos_r2(yev, predict(fcoef, xf_ev), bm)
        return br2, fr2, fr2 - br2

    val = build_eval("validation", {"dev"})
    hold = build_eval("holdout", {"dev", "validation"})
    if val is None or hold is None:
        return None
    return {
        "dev_base_r2": base_dev.r2,
        "dev_full_r2": full_dev.r2,
        "dev_partial_r2": partial,
        "dev_cond_beta_sd": full_dev.coef[-1],
        "dev_cond_t_nw": full_dev.t[-1],
        "dev_cond_p": full_dev.p[-1],
        "val_base_oos_r2": val[0],
        "val_full_oos_r2": val[1],
        "val_delta_oos_r2": val[2],
        "hold_base_oos_r2": hold[0],
        "hold_full_oos_r2": hold[1],
        "hold_delta_oos_r2": hold[2],
    }


def ar1_persistence(values: list[float | None]) -> float:
    xs, ys = [], []
    last = None
    for v in values:
        if v is None or not math.isfinite(v):
            last = None
            continue
        if last is not None:
            xs.append(last); ys.append(v)
        last = v
    return lab.pearson(xs, ys) if len(xs) > 20 else float("nan")


def read_score_rows() -> list[dict[str, str]]:
    with SCORES.open(newline="") as f:
        return list(csv.DictReader(f))


def candidate_pool(score_rows: list[dict[str, str]], label: str) -> list[str]:
    rows = [r for r in score_rows if r["label"] == label and r["family"] != "strategy_state"]
    rows.sort(key=lambda r: float(r["selection_score"]), reverse=True)
    chosen = []
    families_seen: dict[str, int] = {}
    for r in rows:
        name = r["factor"]
        if name in NONPROMOTABLE_RAW_LEVELS:
            continue
        family = r["family"]
        if families_seen.get(family, 0) >= 4:
            continue
        chosen.append(name)
        families_seen[family] = families_seen.get(family, 0) + 1
        if len(chosen) >= 40:
            break
    # Ensure external daily transforms are tested even if their univariate score is middling.
    for name in [
        "vix_level", "vix_z252", "vix_pct252", "vix_term_ratio", "vixterm_z252",
        "chg_vix_5", "chg_vix_20", "chg_vix3m_5", "chg_vix3m_20",
        "real10_z252", "chg_real10_5", "chg_real10_20", "chg_real10_60",
    ]:
        if name not in chosen:
            chosen.append(name)
    return chosen


def bh_add(rows: list[dict[str, object]], pkey: str, qkey: str) -> None:
    pairs = [(str(i), float(r[pkey])) for i, r in enumerate(rows) if math.isfinite(float(r[pkey]))]
    q = lab.bh_qvalues(pairs)
    for i, r in enumerate(rows):
        r[qkey] = q.get(str(i), float("nan"))


def portfolio_return_attribution(dates: list[str], cols: dict[str, list[float]]) -> dict[str, object]:
    port = lab.daily_returns(cols["portfolio_value"])
    rets = {asset: lab.daily_returns(cols[f"price_{asset}"]) for asset in lab.ASSETS}
    xrows, ys = [], []
    for i in range(1, len(dates)):
        vals = [port[i], rets["nasdaq"][i], rets["sp500"][i], rets["gold"][i], rets["csi300"][i], rets["shanghai"][i]]
        if any(v is None or not math.isfinite(float(v)) for v in vals if v is not None):
            continue
        if any(v is None for v in vals):
            continue
        us = 0.5 * (float(rets["nasdaq"][i]) + float(rets["sp500"][i]))
        china = 0.5 * (float(rets["csi300"][i]) + float(rets["shanghai"][i]))
        xrows.append([us, float(rets["gold"][i]), china])
        ys.append(float(port[i]))
    fit = general_ols_hac(xrows, ys, lag=5)
    if fit is None:
        return {}
    return {
        "n": fit.n,
        "daily_alpha": fit.coef[0],
        "annualized_alpha_linear": fit.coef[0] * 252,
        "alpha_t_nw": fit.t[0],
        "alpha_p": fit.p[0],
        "beta_us": fit.coef[1],
        "beta_us_t": fit.t[1],
        "beta_gold": fit.coef[2],
        "beta_gold_t": fit.t[2],
        "beta_china": fit.coef[3],
        "beta_china_t": fit.t[3],
        "r2": fit.r2,
    }


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        return
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


def write_report(path: Path, regressions: list[dict[str, object]], attr: dict[str, object], factors: dict[str, list[float | None]]) -> None:
    lines = [
        "# Daily Alpha Factor Lab — incremental regression",
        "",
        "Research-only. Production strategy unchanged.",
        "",
        "## Static return attribution",
        "",
    ]
    if attr:
        lines += [
            f"- annualized intercept alpha (linear approximation): {float(attr['annualized_alpha_linear']) * 100:.3f}%",
            f"- alpha Newey-West t: {float(attr['alpha_t_nw']):.2f}",
            f"- beta US: {float(attr['beta_us']):.3f} (t={float(attr['beta_us_t']):.2f})",
            f"- beta Gold: {float(attr['beta_gold']):.3f} (t={float(attr['beta_gold_t']):.2f})",
            f"- beta China: {float(attr['beta_china']):.3f} (t={float(attr['beta_china_t']):.2f})",
            f"- R²: {float(attr['r2']):.3f}",
            "",
        ]
    for label in ["fwd_portfolio_20", "fwd_us_20", "fwd_gold_20", "fwd_us_minus_gold_20"]:
        rows = [r for r in regressions if r["label"] == label]
        rows.sort(key=lambda r: (float(r["dev_cond_bh_q"]), -float(r["val_delta_oos_r2"])))
        lines += [f"## {label}", "", "| factor | family | AR1 | partial R² dev | cond NW t | BH q | ΔR² val | ΔR² holdout |", "|---|---|---:|---:|---:|---:|---:|---:|"]
        for r in rows[:18]:
            lines.append(
                f"| {r['factor']} | {r['family']} | {float(r['ar1']):.3f} | {float(r['dev_partial_r2']):.4f} | "
                f"{float(r['dev_cond_t_nw']):+.2f} | {float(r['dev_cond_bh_q']):.4f} | "
                f"{float(r['val_delta_oos_r2']):+.4f} | {float(r['hold_delta_oos_r2']):+.4f} |"
            )
        lines.append("")
    lines += [
        "## Interpretation rule",
        "",
        "A candidate is strong only when it adds conditional explanatory power after current strategy weights are controlled, survives development multiple-testing correction, improves validation OOS R², and does not collapse in holdout. Raw persistent level series such as the 10Y real-yield level are diagnostic only and are not directly promotable.",
    ]
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    dates, cols = lab.read_panel()
    factors, families = lab.build_factors(dates, cols)
    labels = lab.build_labels(dates, cols)
    score_rows = read_score_rows()

    regression_rows: list[dict[str, object]] = []
    for label_name in ["fwd_portfolio_20", "fwd_us_20", "fwd_gold_20", "fwd_us_minus_gold_20"]:
        y, horizon = labels[label_name]
        for factor in candidate_pool(score_rows, label_name):
            if factor not in factors or factor in STATE_CONTROLS:
                continue
            inc = nested_incremental(dates, factors, y, horizon, factor)
            if inc is None:
                continue
            regression_rows.append({
                "label": label_name,
                "factor": factor,
                "family": families[factor],
                "ar1": ar1_persistence(factors[factor]),
                **inc,
            })
    # Multiple-testing correction is per target on the conditional dev tests.
    for label_name in {str(r["label"]) for r in regression_rows}:
        subset = [r for r in regression_rows if r["label"] == label_name]
        bh_add(subset, "dev_cond_p", "dev_cond_bh_q")

    regression_rows.sort(key=lambda r: (str(r["label"]), float(r["dev_cond_bh_q"]), -float(r["val_delta_oos_r2"])))
    write_csv(OUT_DIR / "incremental_factor_regressions.csv", regression_rows)

    attr = portfolio_return_attribution(dates, cols)
    if attr:
        write_csv(OUT_DIR / "portfolio_return_factor_attribution_hac.csv", [attr])

    report = OUT_DIR / "incremental_regression_summary.md"
    write_report(report, regression_rows, attr, factors)

    print("DAILY_ALPHA_INCREMENTAL_REGRESSION")
    print(f"rows={len(regression_rows)} report={report}")
    if attr:
        print(
            f"BASE_ATTR alpha_ann={float(attr['annualized_alpha_linear'])*100:.3f}% "
            f"alpha_t={float(attr['alpha_t_nw']):.3f} r2={float(attr['r2']):.3f} "
            f"beta_us={float(attr['beta_us']):.3f} beta_gold={float(attr['beta_gold']):.3f} beta_china={float(attr['beta_china']):.3f}"
        )
    for label_name in ["fwd_portfolio_20", "fwd_us_20", "fwd_gold_20", "fwd_us_minus_gold_20"]:
        rows = [r for r in regression_rows if r["label"] == label_name]
        rows.sort(key=lambda r: (float(r["dev_cond_bh_q"]), -float(r["val_delta_oos_r2"])))
        print("TOP", label_name)
        for r in rows[:8]:
            print(
                f"{r['factor']} fam={r['family']} ar1={float(r['ar1']):.3f} "
                f"partial={float(r['dev_partial_r2']):.4f} t={float(r['dev_cond_t_nw']):+.3f} "
                f"q={float(r['dev_cond_bh_q']):.4g} val_dR2={float(r['val_delta_oos_r2']):+.4f} "
                f"hold_dR2={float(r['hold_delta_oos_r2']):+.4f}"
            )


if __name__ == "__main__":
    main()
