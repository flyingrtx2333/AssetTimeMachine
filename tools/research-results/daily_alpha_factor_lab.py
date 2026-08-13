#!/usr/bin/env python3
"""Daily alpha-factor research lab for AssetTimeMachine.

Design goals:
- daily data only (price-derived + VIX/VIX3M/DFII10);
- strict close-t -> trade/forecast t+1 semantics;
- no third-party Python dependencies;
- univariate predictive regressions with Newey-West HAC errors;
- rank IC, quintile monotonicity/spreads, development/validation/holdout splits;
- Benjamini-Hochberg multiple-testing correction on development p-values;
- factor redundancy clustering;
- baseline portfolio beta/alpha attribution;
- event-level counterfactual attribution for base-strategy de-risk decisions.

This is a research tool only. It does not modify the production strategy.
"""
from __future__ import annotations

import csv
import datetime as dt
import math
import os
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
PANEL = ROOT / "tools/research-results/daily_factor_panel.csv"
MACRO = ROOT / "tools/fixtures/macro-risk"
OUT_DIR = ROOT / "tools/research-results/daily-factor-lab"
OUT_DIR.mkdir(parents=True, exist_ok=True)

DEV_END = "2014-12-31"
VAL_END = "2020-12-31"
COST_RATE = 0.0105

ASSETS = ["gold", "nasdaq", "sp500", "csi300", "shanghai"]
RISK_ASSETS = ["gold", "nasdaq", "sp500", "csi300", "shanghai"]
US_ASSETS = ["nasdaq", "sp500"]
CHINA_ASSETS = ["csi300", "shanghai"]
WINDOWS_MOM = [5, 10, 20, 60, 120, 252]
WINDOWS_VOL = [10, 20, 60, 120]
WINDOWS_DD = [20, 60, 120, 252]
HORIZONS = [5, 20, 60]


def safe_float(value: str | None) -> float | None:
    if value in (None, "", ".", "nan", "NaN"):
        return None
    try:
        x = float(value)
    except (TypeError, ValueError):
        return None
    return x if math.isfinite(x) else None


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs)


def variance(xs: list[float], ddof: int = 1) -> float:
    if len(xs) <= ddof:
        return float("nan")
    m = mean(xs)
    return sum((x - m) ** 2 for x in xs) / (len(xs) - ddof)


def stdev(xs: list[float], ddof: int = 1) -> float:
    v = variance(xs, ddof)
    return math.sqrt(v) if v >= 0 and math.isfinite(v) else float("nan")


def pearson(xs: list[float], ys: list[float]) -> float:
    if len(xs) < 3 or len(xs) != len(ys):
        return float("nan")
    mx, my = mean(xs), mean(ys)
    sx = sum((x - mx) ** 2 for x in xs)
    sy = sum((y - my) ** 2 for y in ys)
    if sx <= 0 or sy <= 0:
        return float("nan")
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(sx * sy)


def rankdata(xs: list[float]) -> list[float]:
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    ranks = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i + 1
        while j < len(order) and xs[order[j]] == xs[order[i]]:
            j += 1
        rank = (i + 1 + j) / 2.0
        for k in range(i, j):
            ranks[order[k]] = rank
        i = j
    return ranks


def spearman(xs: list[float], ys: list[float]) -> float:
    if len(xs) < 3:
        return float("nan")
    return pearson(rankdata(xs), rankdata(ys))


def normal_two_sided_p(t: float) -> float:
    if not math.isfinite(t):
        return float("nan")
    return math.erfc(abs(t) / math.sqrt(2.0))


def invert_2x2(a: float, b: float, c: float, d: float) -> tuple[float, float, float, float] | None:
    det = a * d - b * c
    if abs(det) < 1e-18:
        return None
    return d / det, -b / det, -c / det, a / det


@dataclass
class OLSResult:
    n: int
    alpha: float
    beta: float
    beta_t: float
    p_value: float
    r2: float


def nw_univariate(xs: list[float], ys: list[float], lag: int) -> OLSResult | None:
    if len(xs) != len(ys) or len(xs) < 20:
        return None
    n = len(xs)
    mx = mean(xs)
    sx = stdev(xs)
    if not math.isfinite(sx) or sx <= 1e-14:
        return None
    xz = [(x - mx) / sx for x in xs]
    sy = sum(x * x for x in xz)
    xy = sum(x * y for x, y in zip(xz, ys))
    ybar = mean(ys)
    beta = xy / sy if sy > 0 else 0.0
    alpha = ybar
    resid = [y - alpha - beta * x for x, y in zip(xz, ys)]

    # X'X for [1, xz]
    x00 = float(n)
    x01 = sum(xz)
    x11 = sum(x * x for x in xz)
    inv = invert_2x2(x00, x01, x01, x11)
    if inv is None:
        return None
    i00, i01, i10, i11 = inv

    # Newey-West meat matrix.
    s00 = s01 = s10 = s11 = 0.0
    for x, u in zip(xz, resid):
        uu = u * u
        s00 += uu
        s01 += uu * x
        s10 += uu * x
        s11 += uu * x * x
    max_lag = max(0, min(lag, n - 2))
    for ell in range(1, max_lag + 1):
        w = 1.0 - ell / (max_lag + 1.0)
        for t in range(ell, n):
            u0 = resid[t]
            u1 = resid[t - ell]
            x0 = xz[t]
            x1 = xz[t - ell]
            cross = w * u0 * u1
            s00 += 2.0 * cross
            s01 += cross * (x0 + x1)
            s10 += cross * (x0 + x1)
            s11 += 2.0 * cross * x0 * x1

    # cov = inv(X'X) * S * inv(X'X)
    a00 = i00 * s00 + i01 * s10
    a01 = i00 * s01 + i01 * s11
    a10 = i10 * s00 + i11 * s10
    a11 = i10 * s01 + i11 * s11
    cov11 = a10 * i01 + a11 * i11
    se = math.sqrt(max(cov11, 0.0))
    tstat = beta / se if se > 1e-18 else float("nan")

    sst = sum((y - ybar) ** 2 for y in ys)
    sse = sum(u * u for u in resid)
    r2 = 1.0 - sse / sst if sst > 0 else 0.0
    return OLSResult(n=n, alpha=alpha, beta=beta, beta_t=tstat, p_value=normal_two_sided_p(tstat), r2=r2)


def matrix_inverse(a: list[list[float]]) -> list[list[float]] | None:
    n = len(a)
    aug = [row[:] + [1.0 if i == j else 0.0 for j in range(n)] for i, row in enumerate(a)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(aug[r][col]))
        if abs(aug[pivot][col]) < 1e-12:
            return None
        if pivot != col:
            aug[col], aug[pivot] = aug[pivot], aug[col]
        p = aug[col][col]
        aug[col] = [x / p for x in aug[col]]
        for r in range(n):
            if r == col:
                continue
            f = aug[r][col]
            if abs(f) < 1e-18:
                continue
            aug[r] = [x - f * y for x, y in zip(aug[r], aug[col])]
    return [row[n:] for row in aug]


def mat_vec(a: list[list[float]], x: list[float]) -> list[float]:
    return [sum(v * w for v, w in zip(row, x)) for row in a]


def multivariate_ols(xrows: list[list[float]], ys: list[float]) -> tuple[list[float], float] | None:
    if len(xrows) != len(ys) or not xrows:
        return None
    p = len(xrows[0]) + 1
    xtx = [[0.0] * p for _ in range(p)]
    xty = [0.0] * p
    for row, y in zip(xrows, ys):
        z = [1.0] + row
        for i in range(p):
            xty[i] += z[i] * y
            for j in range(p):
                xtx[i][j] += z[i] * z[j]
    inv = matrix_inverse(xtx)
    if inv is None:
        return None
    coef = mat_vec(inv, xty)
    ybar = mean(ys)
    sst = sum((y - ybar) ** 2 for y in ys)
    sse = 0.0
    for row, y in zip(xrows, ys):
        pred = coef[0] + sum(c * x for c, x in zip(coef[1:], row))
        sse += (y - pred) ** 2
    r2 = 1.0 - sse / sst if sst > 0 else 0.0
    return coef, r2


def read_panel() -> tuple[list[str], dict[str, list[float]]]:
    dates: list[str] = []
    columns: dict[str, list[float]] = defaultdict(list)
    with PANEL.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            dates.append(row["date"])
            for key, raw in row.items():
                if key == "date":
                    continue
                value = safe_float(raw)
                columns[key].append(value if value is not None else float("nan"))
    return dates, dict(columns)


def read_macro(path: Path, value_column: str) -> dict[str, float]:
    out: dict[str, float] = {}
    if not path.exists():
        return out
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            d = row.get("observation_date") or row.get("DATE") or row.get("date")
            value = safe_float(row.get(value_column))
            if d and value is not None:
                out[d] = value
    return out


def align_forward_fill(dates: list[str], values: dict[str, float]) -> list[float | None]:
    result: list[float | None] = []
    last: float | None = None
    for d in dates:
        if d in values:
            last = values[d]
        result.append(last)
    return result


def pct_change(prices: list[float], lag: int) -> list[float | None]:
    out: list[float | None] = [None] * len(prices)
    for i in range(lag, len(prices)):
        p0, p1 = prices[i - lag], prices[i]
        if p0 > 0 and p1 > 0 and math.isfinite(p0) and math.isfinite(p1):
            out[i] = p1 / p0 - 1.0
    return out


def daily_returns(prices: list[float]) -> list[float | None]:
    return pct_change(prices, 1)


def rolling_mean(values: list[float | None], window: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    for i in range(window - 1, len(values)):
        xs = [x for x in values[i - window + 1 : i + 1] if x is not None and math.isfinite(x)]
        if len(xs) == window:
            out[i] = mean(xs)
    return out


def rolling_std(values: list[float | None], window: int, downside_only: bool = False) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    for i in range(window - 1, len(values)):
        xs0 = values[i - window + 1 : i + 1]
        if any(x is None or not math.isfinite(x) for x in xs0):
            continue
        xs = [float(x) for x in xs0 if x is not None]
        if downside_only:
            xs = [min(x, 0.0) for x in xs]
        out[i] = stdev(xs)
    return out


def rolling_drawdown(prices: list[float], window: int) -> list[float | None]:
    out: list[float | None] = [None] * len(prices)
    for i in range(window - 1, len(prices)):
        xs = prices[i - window + 1 : i + 1]
        if min(xs) <= 0 or any(not math.isfinite(x) for x in xs):
            continue
        out[i] = prices[i] / max(xs) - 1.0
    return out


def rolling_ma_distance(prices: list[float], window: int) -> list[float | None]:
    out: list[float | None] = [None] * len(prices)
    for i in range(window - 1, len(prices)):
        xs = prices[i - window + 1 : i + 1]
        m = mean(xs)
        if m > 0:
            out[i] = prices[i] / m - 1.0
    return out


def rolling_efficiency(prices: list[float], window: int) -> list[float | None]:
    out: list[float | None] = [None] * len(prices)
    ret1 = daily_returns(prices)
    for i in range(window, len(prices)):
        if prices[i - window] <= 0:
            continue
        net = abs(prices[i] / prices[i - window] - 1.0)
        path = 0.0
        okay = True
        for r in ret1[i - window + 1 : i + 1]:
            if r is None:
                okay = False
                break
            path += abs(r)
        if okay and path > 1e-12:
            out[i] = net / path
    return out


def rolling_z(values: list[float | None], window: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    for i in range(window - 1, len(values)):
        xs0 = values[i - window + 1 : i + 1]
        if any(x is None or not math.isfinite(x) for x in xs0):
            continue
        xs = [float(x) for x in xs0 if x is not None]
        sd = stdev(xs)
        if sd > 1e-12:
            out[i] = (xs[-1] - mean(xs)) / sd
    return out


def rolling_percentile(values: list[float | None], window: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    for i in range(window - 1, len(values)):
        xs0 = values[i - window + 1 : i + 1]
        if any(x is None or not math.isfinite(x) for x in xs0):
            continue
        xs = [float(x) for x in xs0 if x is not None]
        v = xs[-1]
        less = sum(x < v for x in xs)
        equal = sum(x == v for x in xs)
        out[i] = (less + 0.5 * equal) / len(xs)
    return out


def pairwise_sub(a: list[float | None], b: list[float | None]) -> list[float | None]:
    out: list[float | None] = []
    for x, y in zip(a, b):
        out.append(None if x is None or y is None else x - y)
    return out


def pairwise_ratio(a: list[float | None], b: list[float | None]) -> list[float | None]:
    out: list[float | None] = []
    for x, y in zip(a, b):
        out.append(None if x is None or y is None or abs(y) < 1e-12 else x / y)
    return out


def build_factors(dates: list[str], cols: dict[str, list[float]]) -> tuple[dict[str, list[float | None]], dict[str, str]]:
    prices = {asset: cols[f"price_{asset}"] for asset in ASSETS}
    factors: dict[str, list[float | None]] = {}
    family: dict[str, str] = {}
    returns1 = {asset: daily_returns(prices[asset]) for asset in ASSETS}

    # Price-derived single-asset factors.
    for asset in ASSETS:
        for w in WINDOWS_MOM:
            name = f"mom_{asset}_{w}"
            factors[name] = pct_change(prices[asset], w)
            family[name] = "momentum"
        for w in WINDOWS_VOL:
            name = f"vol_{asset}_{w}"
            factors[name] = rolling_std(returns1[asset], w)
            family[name] = "volatility"
            dname = f"downvol_{asset}_{w}"
            factors[dname] = rolling_std(returns1[asset], w, downside_only=True)
            family[dname] = "downside_vol"
        for w in WINDOWS_DD:
            name = f"dd_{asset}_{w}"
            factors[name] = rolling_drawdown(prices[asset], w)
            family[name] = "drawdown"
        for w in [20, 60, 120, 252]:
            name = f"ma_dist_{asset}_{w}"
            factors[name] = rolling_ma_distance(prices[asset], w)
            family[name] = "trend"
        for w in [20, 60, 120]:
            name = f"eff_{asset}_{w}"
            factors[name] = rolling_efficiency(prices[asset], w)
            family[name] = "trend_efficiency"

    # Cross-asset momentum, breadth, dispersion.
    for w in [10, 20, 60, 120, 252]:
        moms = {asset: factors[f"mom_{asset}_{w}"] for asset in ASSETS}
        name = f"rel_us_gold_{w}"
        us = [None if moms["nasdaq"][i] is None or moms["sp500"][i] is None else 0.5 * (moms["nasdaq"][i] + moms["sp500"][i]) for i in range(len(dates))]
        china = [None if moms["csi300"][i] is None or moms["shanghai"][i] is None else 0.5 * (moms["csi300"][i] + moms["shanghai"][i]) for i in range(len(dates))]
        factors[name] = pairwise_sub(us, moms["gold"])
        family[name] = "relative_strength"
        n2 = f"rel_us_china_{w}"
        factors[n2] = pairwise_sub(us, china)
        family[n2] = "relative_strength"
        n3 = f"rel_gold_china_{w}"
        factors[n3] = pairwise_sub(moms["gold"], china)
        family[n3] = "relative_strength"

        breadth: list[float | None] = []
        dispersion: list[float | None] = []
        for i in range(len(dates)):
            xs = [moms[a][i] for a in ASSETS]
            if any(x is None for x in xs):
                breadth.append(None)
                dispersion.append(None)
            else:
                vals = [float(x) for x in xs if x is not None]
                breadth.append(sum(x > 0 for x in vals) / len(vals))
                dispersion.append(stdev(vals))
        bn = f"breadth_{w}"
        factors[bn] = breadth
        family[bn] = "breadth"
        dn = f"dispersion_{w}"
        factors[dn] = dispersion
        family[dn] = "dispersion"

    # Strategy state is a control family, not an external alpha candidate.
    for key in ["cash_ratio", "target_gross", "actual_gross", "target_gold", "target_nasdaq", "target_sp500", "target_csi300", "target_shanghai"]:
        factors[f"state_{key}"] = [float(x) for x in cols[key]]
        family[f"state_{key}"] = "strategy_state"

    # External daily data.
    vix = align_forward_fill(dates, read_macro(MACRO / "VIXCLS.csv", "VIXCLS"))
    vix3m = align_forward_fill(dates, read_macro(MACRO / "VXVCLS.csv", "VXVCLS"))
    real10 = align_forward_fill(dates, read_macro(MACRO / "DFII10.csv", "DFII10"))
    factors["vix_level"] = vix
    family["vix_level"] = "vix"
    factors["vix3m_level"] = vix3m
    family["vix3m_level"] = "vix_term"
    factors["vix_term_ratio"] = pairwise_ratio(vix, vix3m)
    family["vix_term_ratio"] = "vix_term"
    factors["vix_term_spread"] = pairwise_sub(vix, vix3m)
    family["vix_term_spread"] = "vix_term"
    for w in [1, 5, 10, 20, 60]:
        for base_name, base, fam in [("vix", vix, "vix"), ("vix3m", vix3m, "vix_term"), ("real10", real10, "real_yield")]:
            values: list[float | None] = [None] * len(dates)
            for i in range(w, len(dates)):
                now, prior = base[i], base[i - w]
                if now is not None and prior is not None:
                    values[i] = now - prior
            name = f"chg_{base_name}_{w}"
            factors[name] = values
            family[name] = fam
    factors["vix_z252"] = rolling_z(vix, 252)
    family["vix_z252"] = "vix"
    factors["vix_pct252"] = rolling_percentile(vix, 252)
    family["vix_pct252"] = "vix"
    factors["vixterm_z252"] = rolling_z(factors["vix_term_ratio"], 252)
    family["vixterm_z252"] = "vix_term"
    factors["real10_level"] = real10
    family["real10_level"] = "real_yield"
    factors["real10_z252"] = rolling_z(real10, 252)
    family["real10_z252"] = "real_yield"

    return factors, family


def forward_return(prices: list[float], horizon: int) -> list[float | None]:
    out: list[float | None] = [None] * len(prices)
    for i in range(len(prices) - horizon):
        p0, p1 = prices[i], prices[i + horizon]
        if p0 > 0 and p1 > 0:
            out[i] = p1 / p0 - 1.0
    return out


def build_labels(dates: list[str], cols: dict[str, list[float]]) -> dict[str, tuple[list[float | None], int]]:
    prices = {asset: cols[f"price_{asset}"] for asset in ASSETS}
    labels: dict[str, tuple[list[float | None], int]] = {}
    for h in HORIZONS:
        fr = {asset: forward_return(prices[asset], h) for asset in ASSETS}
        portfolio = forward_return(cols["portfolio_value"], h)
        us: list[float | None] = []
        china: list[float | None] = []
        us_minus_gold: list[float | None] = []
        us_minus_china: list[float | None] = []
        for i in range(len(dates)):
            if fr["nasdaq"][i] is None or fr["sp500"][i] is None:
                us.append(None)
            else:
                us.append(0.5 * (fr["nasdaq"][i] + fr["sp500"][i]))
            if fr["csi300"][i] is None or fr["shanghai"][i] is None:
                china.append(None)
            else:
                china.append(0.5 * (fr["csi300"][i] + fr["shanghai"][i]))
            us_minus_gold.append(None if us[-1] is None or fr["gold"][i] is None else us[-1] - fr["gold"][i])
            us_minus_china.append(None if us[-1] is None or china[-1] is None else us[-1] - china[-1])
        labels[f"fwd_us_{h}"] = (us, h)
        labels[f"fwd_gold_{h}"] = (fr["gold"], h)
        labels[f"fwd_china_{h}"] = (china, h)
        labels[f"fwd_portfolio_{h}"] = (portfolio, h)
        labels[f"fwd_us_minus_gold_{h}"] = (us_minus_gold, h)
        labels[f"fwd_us_minus_china_{h}"] = (us_minus_china, h)
    return labels


def split_name(date: str) -> str:
    if date <= DEV_END:
        return "dev"
    if date <= VAL_END:
        return "validation"
    return "holdout"


def valid_xy(dates: list[str], x: list[float | None], y: list[float | None], split: str | None = None) -> tuple[list[float], list[float]]:
    xs: list[float] = []
    ys: list[float] = []
    for d, a, b in zip(dates, x, y):
        if split is not None and split_name(d) != split:
            continue
        if a is None or b is None or not math.isfinite(a) or not math.isfinite(b):
            continue
        xs.append(a)
        ys.append(b)
    return xs, ys


def quintile_stats(xs: list[float], ys: list[float]) -> tuple[list[float], float, float]:
    if len(xs) < 100:
        return [], float("nan"), float("nan")
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    buckets: list[list[float]] = [[] for _ in range(5)]
    for rank, idx in enumerate(order):
        b = min(4, rank * 5 // len(order))
        buckets[b].append(ys[idx])
    means = [mean(b) if b else float("nan") for b in buckets]
    spread = means[-1] - means[0]
    mono = pearson([1, 2, 3, 4, 5], means)
    return means, spread, mono


def bh_qvalues(pairs: list[tuple[str, float]]) -> dict[str, float]:
    usable = [(name, p) for name, p in pairs if math.isfinite(p)]
    usable.sort(key=lambda x: x[1])
    m = len(usable)
    q: dict[str, float] = {}
    running = 1.0
    for rank in range(m, 0, -1):
        name, p = usable[rank - 1]
        candidate = min(1.0, p * m / rank)
        running = min(running, candidate)
        q[name] = running
    return q


def evaluate_factors(dates: list[str], factors: dict[str, list[float | None]], families: dict[str, str], labels: dict[str, tuple[list[float | None], int]]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for label_name, (y, horizon) in labels.items():
        temp: list[dict[str, object]] = []
        dev_p: list[tuple[str, float]] = []
        for factor_name, x in factors.items():
            xfull, yfull = valid_xy(dates, x, y)
            xdev, ydev = valid_xy(dates, x, y, "dev")
            xval, yval = valid_xy(dates, x, y, "validation")
            xhold, yhold = valid_xy(dates, x, y, "holdout")
            if min(len(xdev), len(xval), len(xhold)) < 80:
                continue
            full = nw_univariate(xfull, yfull, horizon - 1)
            dev = nw_univariate(xdev, ydev, horizon - 1)
            val = nw_univariate(xval, yval, horizon - 1)
            hold = nw_univariate(xhold, yhold, horizon - 1)
            if not all([full, dev, val, hold]):
                continue
            _, qspread, qmono = quintile_stats(xdev, ydev)
            rank_ic = spearman(xdev, ydev)
            sign_stable_val = 1 if dev.beta * val.beta > 0 else 0
            sign_stable_hold = 1 if dev.beta * hold.beta > 0 else 0
            record = {
                "label": label_name,
                "horizon": horizon,
                "factor": factor_name,
                "family": families[factor_name],
                "n_full": full.n,
                "beta_full_sd": full.beta,
                "t_full_nw": full.beta_t,
                "r2_full": full.r2,
                "dev_beta_sd": dev.beta,
                "dev_t_nw": dev.beta_t,
                "dev_p": dev.p_value,
                "dev_r2": dev.r2,
                "dev_rank_ic": rank_ic,
                "dev_q5_q1": qspread,
                "dev_quintile_mono": qmono,
                "val_beta_sd": val.beta,
                "val_t_nw": val.beta_t,
                "hold_beta_sd": hold.beta,
                "hold_t_nw": hold.beta_t,
                "sign_stable_val": sign_stable_val,
                "sign_stable_hold": sign_stable_hold,
            }
            temp.append(record)
            dev_p.append((factor_name, dev.p_value))
        qvals = bh_qvalues(dev_p)
        for record in temp:
            record["dev_bh_q"] = qvals.get(str(record["factor"]), float("nan"))
            # Selection score NEVER uses holdout. Holdout is diagnostic only.
            t = abs(float(record["dev_t_nw"]))
            q = float(record["dev_bh_q"])
            val_ok = int(record["sign_stable_val"])
            mono = abs(float(record["dev_quintile_mono"])) if math.isfinite(float(record["dev_quintile_mono"])) else 0.0
            record["selection_score"] = t + 1.5 * val_ok + 0.5 * mono + (1.0 if q <= 0.05 else 0.0)
            rows.append(record)
    return rows


def write_dict_rows(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        return
    fields = list(rows[0].keys())
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def factor_correlation_clusters(dates: list[str], factors: dict[str, list[float | None]], score_rows: list[dict[str, object]], label: str, threshold: float = 0.80) -> list[dict[str, object]]:
    ranked = [r for r in score_rows if r["label"] == label and r["family"] != "strategy_state"]
    ranked.sort(key=lambda r: float(r["selection_score"]), reverse=True)
    chosen: list[str] = []
    cluster_rows: list[dict[str, object]] = []
    for r in ranked:
        name = str(r["factor"])
        best_corr = 0.0
        best_with = ""
        for selected in chosen:
            xs, ys = valid_xy(dates, factors[name], factors[selected], "dev")
            corr = pearson(xs, ys) if len(xs) >= 100 else float("nan")
            if math.isfinite(corr) and abs(corr) > abs(best_corr):
                best_corr = corr
                best_with = selected
        if chosen and abs(best_corr) >= threshold:
            cluster_rows.append({"factor": name, "status": "redundant", "with": best_with, "dev_corr": best_corr, "score": r["selection_score"]})
        else:
            chosen.append(name)
            cluster_rows.append({"factor": name, "status": "selected", "with": "", "dev_corr": best_corr, "score": r["selection_score"]})
        if len(chosen) >= 12:
            # Still record top redundant rows, but stop accepting more independent factors.
            pass
        if len(cluster_rows) >= 80:
            break
    return cluster_rows


def baseline_beta_attribution(dates: list[str], cols: dict[str, list[float]]) -> dict[str, object]:
    port = daily_returns(cols["portfolio_value"])
    rets = {asset: daily_returns(cols[f"price_{asset}"]) for asset in ASSETS}
    xrows: list[list[float]] = []
    ys: list[float] = []
    for i in range(1, len(dates)):
        vals = [port[i], rets["nasdaq"][i], rets["sp500"][i], rets["gold"][i], rets["csi300"][i], rets["shanghai"][i]]
        if any(v is None or not math.isfinite(v) for v in vals):
            continue
        us = 0.5 * (float(rets["nasdaq"][i]) + float(rets["sp500"][i]))
        china = 0.5 * (float(rets["csi300"][i]) + float(rets["shanghai"][i]))
        xrows.append([us, float(rets["gold"][i]), china])
        ys.append(float(port[i]))
    result = multivariate_ols(xrows, ys)
    if result is None:
        return {}
    coef, r2 = result
    return {
        "n": len(ys),
        "daily_alpha": coef[0],
        "annualized_alpha_linear": coef[0] * 252.0,
        "beta_us": coef[1],
        "beta_gold": coef[2],
        "beta_china": coef[3],
        "r2": r2,
    }


def static_weight_return(weights: dict[str, float], prices: dict[str, list[float]], start: int, horizon: int) -> float | None:
    end = start + horizon
    if end >= len(next(iter(prices.values()))):
        return None
    total = 0.0
    for asset in ASSETS:
        w = weights.get(asset, 0.0)
        if w <= 0:
            continue
        p0, p1 = prices[asset][start], prices[asset][end]
        if p0 <= 0 or p1 <= 0:
            return None
        total += w * (p1 / p0 - 1.0)
    return total


def build_derisk_events(dates: list[str], cols: dict[str, list[float]], factors: dict[str, list[float | None]]) -> list[dict[str, object]]:
    prices = {asset: cols[f"price_{asset}"] for asset in ASSETS}
    target_cols = {
        "gold": cols["target_gold"],
        "nasdaq": cols["target_nasdaq"],
        "sp500": cols["target_sp500"],
        "csi300": cols["target_csi300"],
        "shanghai": cols["target_shanghai"],
    }
    events: list[dict[str, object]] = []
    for i in range(1, len(dates)):
        prior = {a: target_cols[a][i - 1] for a in ASSETS}
        new = {a: target_cols[a][i] for a in ASSETS}
        gross_prior = sum(prior.values())
        gross_new = sum(new.values())
        gross_decrease = gross_prior - gross_new
        us_decrease = sum(prior[a] - new[a] for a in US_ASSETS)
        turnover = sum(abs(new[a] - prior[a]) for a in ASSETS)
        if turnover < 0.02 or gross_decrease < 0.03:
            continue
        edge20 = None
        edge60 = None
        for h in [20, 60]:
            nr = static_weight_return(new, prices, i, h)
            pr = static_weight_return(prior, prices, i, h)
            edge = None if nr is None or pr is None else nr - pr - COST_RATE * turnover
            if h == 20:
                edge20 = edge
            else:
                edge60 = edge
        event = {
            "date": dates[i],
            "signal_date": dates[i - 1],
            "gross_decrease": gross_decrease,
            "us_decrease": us_decrease,
            "turnover": turnover,
            "edge20": edge20,
            "edge60": edge60,
        }
        # Store a compact, pre-specified factor set for explainability/event attribution.
        for name in [
            "mom_nasdaq_20", "mom_nasdaq_60", "dd_nasdaq_60", "vol_nasdaq_20",
            "mom_gold_20", "mom_gold_60", "breadth_20", "rel_us_gold_20",
            "vix_level", "chg_vix_5", "vix_term_ratio", "chg_real10_20",
        ]:
            event[name] = factors.get(name, [None] * len(dates))[i - 1]
        events.append(event)
    return events


def event_factor_summary(events: list[dict[str, object]]) -> list[dict[str, object]]:
    fields = [k for k in events[0].keys() if k not in {"date", "signal_date", "gross_decrease", "us_decrease", "turnover", "edge20", "edge60"}] if events else []
    rows: list[dict[str, object]] = []
    for event_type, pred in [
        ("all_derisk", lambda e: True),
        ("us_derisk", lambda e: float(e["us_decrease"]) >= 0.05),
        ("non_us_derisk", lambda e: float(e["us_decrease"]) < 0.05),
    ]:
        subset = [e for e in events if pred(e)]
        for horizon in [20, 60]:
            yname = f"edge{horizon}"
            for factor in fields:
                xs, ys = [], []
                for e in subset:
                    x, y = e.get(factor), e.get(yname)
                    if isinstance(x, (int, float)) and isinstance(y, (int, float)) and math.isfinite(float(x)) and math.isfinite(float(y)):
                        xs.append(float(x)); ys.append(float(y))
                if len(xs) < 15:
                    continue
                ols = nw_univariate(xs, ys, lag=0)
                if ols is None:
                    continue
                rows.append({
                    "event_type": event_type,
                    "horizon": horizon,
                    "factor": factor,
                    "n": len(xs),
                    "beta_sd": ols.beta,
                    "t": ols.beta_t,
                    "p": ols.p_value,
                    "r2": ols.r2,
                    "spearman": spearman(xs, ys),
                })
    return rows


def write_summary(path: Path, factor_rows: list[dict[str, object]], beta_attr: dict[str, object], event_rows: list[dict[str, object]]) -> None:
    key_labels = ["fwd_us_20", "fwd_gold_20", "fwd_portfolio_20", "fwd_us_minus_gold_20"]
    lines = [
        "# Daily Alpha Factor Lab — first-pass research",
        "",
        "Research-only. Production strategy is unchanged.",
        "",
        "## Method",
        "- daily price-derived factors + VIX/VIX3M/10Y real yield only;",
        "- signal at close t predicts returns after t (tradeable from t+1);",
        "- Newey-West HAC t-statistics with lag h-1 for overlapping h-day forward returns;",
        "- development through 2014, validation 2015–2020, holdout 2021+;",
        "- Benjamini-Hochberg FDR correction is computed on development tests;",
        "- holdout statistics are diagnostic and are not used in the selection score;",
        "- exact Swift production engine is used to generate the aligned price/strategy panel.",
        "",
        "## Baseline return attribution",
    ]
    if beta_attr:
        lines += [
            f"- daily linear alpha: {float(beta_attr['daily_alpha']):.8f}",
            f"- linear annualized alpha approximation: {float(beta_attr['annualized_alpha_linear']) * 100:.3f}%",
            f"- beta US: {float(beta_attr['beta_us']):.3f}",
            f"- beta Gold: {float(beta_attr['beta_gold']):.3f}",
            f"- beta China: {float(beta_attr['beta_china']):.3f}",
            f"- R²: {float(beta_attr['r2']):.3f}",
        ]
    for label in key_labels:
        candidates = [r for r in factor_rows if r["label"] == label and r["family"] != "strategy_state"]
        candidates.sort(key=lambda r: float(r["selection_score"]), reverse=True)
        lines += ["", f"## {label} — top development/validation candidates", ""]
        lines.append("| factor | family | dev NW t | BH q | val beta | holdout beta | dev rank IC | dev Q5-Q1 |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
        for r in candidates[:12]:
            lines.append(
                f"| {r['factor']} | {r['family']} | {float(r['dev_t_nw']):.2f} | {float(r['dev_bh_q']):.4f} | "
                f"{float(r['val_beta_sd']):+.5f} | {float(r['hold_beta_sd']):+.5f} | {float(r['dev_rank_ic']):+.3f} | {float(r['dev_q5_q1']):+.4f} |"
            )
    lines += ["", "## Event-level de-risk explainability", ""]
    ers = sorted(event_rows, key=lambda r: abs(float(r["t"])), reverse=True)
    lines.append("| event type | horizon | factor | n | beta/sd | t | R² | Spearman |")
    lines.append("|---|---:|---|---:|---:|---:|---:|---:|")
    for r in ers[:20]:
        lines.append(
            f"| {r['event_type']} | {r['horizon']} | {r['factor']} | {r['n']} | {float(r['beta_sd']):+.4f} | "
            f"{float(r['t']):+.2f} | {float(r['r2']):.3f} | {float(r['spearman']):+.3f} |"
        )
    lines += [
        "",
        "## Promotion rule",
        "A factor is not promoted into a Swift strategy overlay from this table alone. It must also pass redundancy/orthogonalization, walk-forward economic tests in the exact App engine, costs, drawdown constraints, and robustness/ablation tests.",
    ]
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    if not PANEL.exists():
        raise SystemExit(f"missing panel: {PANEL}")
    dates, cols = read_panel()
    factors, families = build_factors(dates, cols)
    labels = build_labels(dates, cols)
    rows = evaluate_factors(dates, factors, families, labels)
    rows.sort(key=lambda r: (str(r["label"]), -float(r["selection_score"])))
    write_dict_rows(OUT_DIR / "factor_univariate_scores.csv", rows)

    for label in ["fwd_us_20", "fwd_gold_20", "fwd_portfolio_20", "fwd_us_minus_gold_20"]:
        clusters = factor_correlation_clusters(dates, factors, rows, label)
        if clusters:
            write_dict_rows(OUT_DIR / f"clusters_{label}.csv", clusters)

    beta_attr = baseline_beta_attribution(dates, cols)
    if beta_attr:
        write_dict_rows(OUT_DIR / "baseline_beta_attribution.csv", [beta_attr])

    events = build_derisk_events(dates, cols, factors)
    write_dict_rows(OUT_DIR / "derisk_events.csv", events)
    event_rows = event_factor_summary(events)
    if event_rows:
        write_dict_rows(OUT_DIR / "derisk_factor_regressions.csv", event_rows)

    summary_path = OUT_DIR / "first_pass_summary.md"
    write_summary(summary_path, rows, beta_attr, event_rows)

    print("DAILY_ALPHA_FACTOR_LAB")
    print(f"panel_rows={len(dates)} factors={len(factors)} labels={len(labels)} score_rows={len(rows)} derisk_events={len(events)}")
    print(f"output={OUT_DIR}")
    print(f"summary={summary_path}")
    for label in ["fwd_us_20", "fwd_gold_20", "fwd_portfolio_20", "fwd_us_minus_gold_20"]:
        top = [r for r in rows if r["label"] == label and r["family"] != "strategy_state"][:5]
        print(f"TOP {label}")
        for r in top:
            print(
                f"{r['factor']} family={r['family']} dev_t={float(r['dev_t_nw']):+.3f} "
                f"q={float(r['dev_bh_q']):.4g} val_beta={float(r['val_beta_sd']):+.6f} "
                f"hold_beta={float(r['hold_beta_sd']):+.6f} score={float(r['selection_score']):.3f}"
            )


if __name__ == "__main__":
    main()
