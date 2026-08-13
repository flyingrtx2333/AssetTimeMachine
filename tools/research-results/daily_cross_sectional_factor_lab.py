#!/usr/bin/env python3
"""Cross-sectional alpha-factor mining across the five tradable sleeves.

Each date ranks the five sleeves by a common asset-specific characteristic and
measures rank IC versus future returns. This is the closest analogue to classic
cross-sectional factor research for AssetTimeMachine's small multi-asset universe.
"""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import daily_alpha_factor_lab as lab  # noqa: E402

OUT_DIR = HERE / "daily-factor-lab"
ASSETS = lab.ASSETS
HORIZONS = [5, 20, 60]


def nw_mean_t(values: list[float], lag: int) -> tuple[float, float, float]:
    n = len(values)
    if n < 40:
        return float("nan"), float("nan"), float("nan")
    m = lab.mean(values)
    resid = [x - m for x in values]
    gamma0 = sum(u * u for u in resid) / n
    long_var = gamma0
    max_lag = min(max(lag, 0), n - 2)
    for ell in range(1, max_lag + 1):
        w = 1 - ell / (max_lag + 1.0)
        gamma = sum(resid[t] * resid[t - ell] for t in range(ell, n)) / n
        long_var += 2 * w * gamma
    se_mean = math.sqrt(max(long_var, 0.0) / n)
    t = m / se_mean if se_mean > 1e-18 else float("nan")
    return m, t, lab.normal_two_sided_p(t)


def build_asset_factor_cube(cols: dict[str, list[float]]) -> dict[str, dict[str, list[float | None]]]:
    prices = {a: cols[f"price_{a}"] for a in ASSETS}
    ret1 = {a: lab.daily_returns(prices[a]) for a in ASSETS}
    factors: dict[str, dict[str, list[float | None]]] = {}

    for w in [5, 10, 20, 60, 120, 252]:
        factors[f"momentum_{w}"] = {a: lab.pct_change(prices[a], w) for a in ASSETS}
    for w in [10, 20, 60, 120]:
        factors[f"volatility_{w}"] = {a: lab.rolling_std(ret1[a], w) for a in ASSETS}
        factors[f"downside_vol_{w}"] = {a: lab.rolling_std(ret1[a], w, downside_only=True) for a in ASSETS}
    for w in [20, 60, 120, 252]:
        factors[f"drawdown_{w}"] = {a: lab.rolling_drawdown(prices[a], w) for a in ASSETS}
        factors[f"ma_distance_{w}"] = {a: lab.rolling_ma_distance(prices[a], w) for a in ASSETS}
    for w in [20, 60, 120]:
        factors[f"efficiency_{w}"] = {a: lab.rolling_efficiency(prices[a], w) for a in ASSETS}

    # Simple economically interpretable composites, pre-specified rather than mined thresholds.
    for mom_w, vol_w in [(20, 20), (60, 20), (120, 60), (252, 60)]:
        mom = factors[f"momentum_{mom_w}"]
        vol = factors[f"volatility_{vol_w}"]
        cube: dict[str, list[float | None]] = {}
        for a in ASSETS:
            vals = []
            for m, v in zip(mom[a], vol[a]):
                vals.append(None if m is None or v is None or v <= 1e-12 else m / v)
            cube[a] = vals
        factors[f"risk_adjusted_momentum_{mom_w}_{vol_w}"] = cube

    # Low-risk style: reverse sign so high score means preferred lower risk.
    for w in [20, 60, 120]:
        base = factors[f"volatility_{w}"]
        factors[f"low_vol_{w}"] = {a: [None if v is None else -v for v in base[a]] for a in ASSETS}
    for w in [20, 60, 120, 252]:
        base = factors[f"drawdown_{w}"]
        # Higher drawdown factor means closer to peak (less negative drawdown).
        factors[f"near_peak_{w}"] = {a: base[a][:] for a in ASSETS}
    return factors


def forward_cube(cols: dict[str, list[float]], horizon: int) -> dict[str, list[float | None]]:
    return {a: lab.forward_return(cols[f"price_{a}"], horizon) for a in ASSETS}


def daily_cross_section_stats(
    dates: list[str],
    cube: dict[str, list[float | None]],
    fwd: dict[str, list[float | None]],
) -> tuple[list[float | None], list[float | None]]:
    ic: list[float | None] = [None] * len(dates)
    spread: list[float | None] = [None] * len(dates)
    for i in range(len(dates)):
        x, y = [], []
        for a in ASSETS:
            xv, yv = cube[a][i], fwd[a][i]
            if xv is None or yv is None or not math.isfinite(xv) or not math.isfinite(yv):
                continue
            x.append(float(xv)); y.append(float(yv))
        if len(x) != len(ASSETS):
            continue
        ic[i] = lab.spearman(x, y)
        order = sorted(range(len(x)), key=lambda j: x[j])
        bottom = [y[j] for j in order[:2]]
        top = [y[j] for j in order[-2:]]
        spread[i] = lab.mean(top) - lab.mean(bottom)
    return ic, spread


def split_values(dates: list[str], values: list[float | None], split: str) -> list[float]:
    out = []
    for d, v in zip(dates, values):
        if lab.split_name(d) == split and v is not None and math.isfinite(v):
            out.append(float(v))
    return out


def evaluate(dates: list[str], cols: dict[str, list[float]]) -> list[dict[str, object]]:
    factor_cube = build_asset_factor_cube(cols)
    rows: list[dict[str, object]] = []
    for horizon in HORIZONS:
        fwd = forward_cube(cols, horizon)
        temp = []
        ptests = []
        for name, cube in factor_cube.items():
            ic, spread = daily_cross_section_stats(dates, cube, fwd)
            dev_ic = split_values(dates, ic, "dev")
            val_ic = split_values(dates, ic, "validation")
            hold_ic = split_values(dates, ic, "holdout")
            dev_sp = split_values(dates, spread, "dev")
            val_sp = split_values(dates, spread, "validation")
            hold_sp = split_values(dates, spread, "holdout")
            if min(len(dev_ic), len(val_ic), len(hold_ic)) < 100:
                continue
            dev_mean, dev_t, dev_p = nw_mean_t(dev_ic, horizon - 1)
            val_mean, val_t, _ = nw_mean_t(val_ic, horizon - 1)
            hold_mean, hold_t, _ = nw_mean_t(hold_ic, horizon - 1)
            dev_sp_mean, dev_sp_t, _ = nw_mean_t(dev_sp, horizon - 1)
            val_sp_mean, val_sp_t, _ = nw_mean_t(val_sp, horizon - 1)
            hold_sp_mean, hold_sp_t, _ = nw_mean_t(hold_sp, horizon - 1)
            rec = {
                "horizon": horizon,
                "factor": name,
                "dev_n": len(dev_ic),
                "dev_rank_ic": dev_mean,
                "dev_ic_t_nw": dev_t,
                "dev_ic_p": dev_p,
                "val_rank_ic": val_mean,
                "val_ic_t_nw": val_t,
                "hold_rank_ic": hold_mean,
                "hold_ic_t_nw": hold_t,
                "dev_top2_bottom2": dev_sp_mean,
                "dev_spread_t_nw": dev_sp_t,
                "val_top2_bottom2": val_sp_mean,
                "val_spread_t_nw": val_sp_t,
                "hold_top2_bottom2": hold_sp_mean,
                "hold_spread_t_nw": hold_sp_t,
                "val_sign_stable": 1 if dev_mean * val_mean > 0 else 0,
                "hold_sign_stable": 1 if dev_mean * hold_mean > 0 else 0,
            }
            temp.append(rec)
            ptests.append((name, dev_p))
        q = lab.bh_qvalues(ptests)
        for rec in temp:
            rec["dev_bh_q"] = q.get(str(rec["factor"]), float("nan"))
            rec["selection_score"] = abs(float(rec["dev_ic_t_nw"])) + 1.5 * int(rec["val_sign_stable"]) + (1.0 if float(rec["dev_bh_q"]) <= 0.05 else 0.0)
            rows.append(rec)
    return rows


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


def write_report(path: Path, rows: list[dict[str, object]]) -> None:
    lines = [
        "# Cross-sectional daily factor mining",
        "",
        "Five-sleeve cross-sectional Rank IC. Development through 2014, validation 2015–2020, holdout 2021+.",
        "",
    ]
    for h in HORIZONS:
        sub = [r for r in rows if r["horizon"] == h]
        sub.sort(key=lambda r: (-float(r["selection_score"]), float(r["dev_bh_q"])))
        lines += [f"## Horizon {h} sessions", "", "| factor | dev IC | NW t | BH q | val IC | hold IC | dev T2-B2 | val T2-B2 | hold T2-B2 |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for r in sub[:20]:
            lines.append(
                f"| {r['factor']} | {float(r['dev_rank_ic']):+.3f} | {float(r['dev_ic_t_nw']):+.2f} | {float(r['dev_bh_q']):.4f} | "
                f"{float(r['val_rank_ic']):+.3f} | {float(r['hold_rank_ic']):+.3f} | "
                f"{float(r['dev_top2_bottom2']):+.4f} | {float(r['val_top2_bottom2']):+.4f} | {float(r['hold_top2_bottom2']):+.4f} |"
            )
        lines.append("")
    lines += [
        "## Caveat",
        "",
        "The universe has only five heterogeneous sleeves, so cross-sectional IC is a supporting diagnostic rather than a standalone promotion criterion. A factor must still improve the exact Swift strategy out of sample after costs and risk constraints.",
    ]
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    dates, cols = lab.read_panel()
    rows = evaluate(dates, cols)
    rows.sort(key=lambda r: (int(r["horizon"]), -float(r["selection_score"])))
    write_csv(OUT_DIR / "cross_sectional_factor_scores.csv", rows)
    report = OUT_DIR / "cross_sectional_factor_summary.md"
    write_report(report, rows)
    print("CROSS_SECTIONAL_FACTOR_LAB")
    print(f"rows={len(rows)} report={report}")
    for h in HORIZONS:
        sub = [r for r in rows if r["horizon"] == h]
        sub.sort(key=lambda r: (-float(r["selection_score"]), float(r["dev_bh_q"])))
        print("TOP horizon", h)
        for r in sub[:10]:
            print(
                f"{r['factor']} devIC={float(r['dev_rank_ic']):+.3f} t={float(r['dev_ic_t_nw']):+.2f} "
                f"q={float(r['dev_bh_q']):.4g} valIC={float(r['val_rank_ic']):+.3f} holdIC={float(r['hold_rank_ic']):+.3f} "
                f"valSpread={float(r['val_top2_bottom2']):+.4f} holdSpread={float(r['hold_top2_bottom2']):+.4f}"
            )


if __name__ == "__main__":
    main()
