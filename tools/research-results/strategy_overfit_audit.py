#!/usr/bin/env python3
"""Audit low-noise and NFCI C3/L3 daily equity paths for temporal robustness.

This script deliberately does not search strategy parameters. It consumes already-frozen
portfolio-value paths and reports rolling-window stability, moving-block bootstrap uncertainty,
and multiple-testing-aware probabilistic Sharpe scenarios.

It is an audit tool, not a strategy optimizer.
"""
from __future__ import annotations

import argparse
import csv
import math
import random
import statistics
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Iterable

TRADING_DAYS = 252.0
SQRT_252 = math.sqrt(TRADING_DAYS)


@dataclass(frozen=True)
class Series:
    name: str
    dates: list[date]
    values: list[float]

    @property
    def returns(self) -> list[float]:
        return [self.values[i] / self.values[i - 1] - 1.0 for i in range(1, len(self.values))]


@dataclass(frozen=True)
class Metrics:
    cagr: float
    max_drawdown: float
    volatility: float
    sharpe: float
    total_return: float


def load_panel(path: Path, name: str) -> Series:
    rows = list(csv.DictReader(path.open(encoding="utf-8")))
    dates: list[date] = []
    values: list[float] = []
    for row in rows:
        try:
            d = date.fromisoformat(row["date"])
            v = float(row["portfolio_value"])
        except (KeyError, ValueError):
            continue
        if not math.isfinite(v) or v <= 0:
            continue
        dates.append(d)
        values.append(v)
    if len(values) < 100:
        raise RuntimeError(f"{name}: insufficient panel rows: {len(values)}")
    return Series(name=name, dates=dates, values=values)


def sample_skew(xs: list[float]) -> float:
    n = len(xs)
    if n < 3:
        return 0.0
    m = statistics.fmean(xs)
    s = statistics.stdev(xs)
    if s <= 1e-18:
        return 0.0
    return (n / ((n - 1) * (n - 2))) * sum(((x - m) / s) ** 3 for x in xs)


def sample_kurtosis(xs: list[float]) -> float:
    """Unbiased Pearson kurtosis (normal ~= 3)."""
    n = len(xs)
    if n < 4:
        return 3.0
    m = statistics.fmean(xs)
    s2 = statistics.variance(xs)
    if s2 <= 1e-24:
        return 3.0
    z4 = sum((x - m) ** 4 for x in xs) / (s2 * s2)
    excess = ((n - 1) / ((n - 2) * (n - 3))) * ((n + 1) * z4 / n - 3 * (n - 1))
    return excess + 3.0


def metrics_from_values(values: list[float], dates: list[date] | None = None) -> Metrics:
    if len(values) < 2:
        return Metrics(0, 0, 0, 0, 0)
    returns = [values[i] / values[i - 1] - 1 for i in range(1, len(values))]
    mean = statistics.fmean(returns)
    stdev = statistics.stdev(returns) if len(returns) > 1 else 0.0
    vol = stdev * SQRT_252
    sharpe = mean / stdev * SQRT_252 if stdev > 1e-18 else 0.0
    peak = values[0]
    mdd = 0.0
    for v in values:
        peak = max(peak, v)
        mdd = max(mdd, 1 - v / peak)
    total = values[-1] / values[0] - 1
    if dates is not None and len(dates) == len(values):
        years = max((dates[-1] - dates[0]).days / 365.2425, 1 / 365.2425)
    else:
        years = max((len(values) - 1) / TRADING_DAYS, 1 / TRADING_DAYS)
    cagr = (values[-1] / values[0]) ** (1 / years) - 1
    return Metrics(cagr, mdd, vol, sharpe, total)


def metrics_from_returns(returns: list[float]) -> Metrics:
    values = [1.0]
    for r in returns:
        values.append(values[-1] * (1 + r))
    return metrics_from_values(values)


def percentile(xs: list[float], q: float) -> float:
    if not xs:
        return float("nan")
    ys = sorted(xs)
    if len(ys) == 1:
        return ys[0]
    pos = (len(ys) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return ys[lo]
    w = pos - lo
    return ys[lo] * (1 - w) + ys[hi] * w


def rolling_windows(series: Series, sessions: int, step: int = 21) -> list[Metrics]:
    out: list[Metrics] = []
    if len(series.values) <= sessions:
        return out
    for end in range(sessions, len(series.values), step):
        start = end - sessions
        out.append(metrics_from_values(series.values[start : end + 1], series.dates[start : end + 1]))
    if (len(series.values) - 1) % step != 0:
        end = len(series.values) - 1
        start = max(0, end - sessions)
        if end - start >= sessions:
            out.append(metrics_from_values(series.values[start : end + 1], series.dates[start : end + 1]))
    return out


def moving_block_bootstrap(returns: list[float], block: int, reps: int, seed: int) -> dict[str, tuple[float, float, float]]:
    rng = random.Random(seed)
    n = len(returns)
    if n < block * 2:
        raise RuntimeError("insufficient returns for bootstrap")
    cagr: list[float] = []
    mdd: list[float] = []
    sharpe: list[float] = []
    volatility: list[float] = []
    for _ in range(reps):
        sampled: list[float] = []
        while len(sampled) < n:
            start = rng.randrange(n)
            for k in range(block):
                sampled.append(returns[(start + k) % n])
                if len(sampled) >= n:
                    break
        m = metrics_from_returns(sampled)
        cagr.append(m.cagr)
        mdd.append(m.max_drawdown)
        sharpe.append(m.sharpe)
        volatility.append(m.volatility)
    def ci(xs: list[float]) -> tuple[float, float, float]:
        return percentile(xs, 0.025), percentile(xs, 0.50), percentile(xs, 0.975)
    return {"cagr": ci(cagr), "mdd": ci(mdd), "sharpe": ci(sharpe), "vol": ci(volatility)}


def norm_cdf(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def norm_ppf(p: float) -> float:
    # Acklam rational approximation.
    if not 0 < p < 1:
        return -math.inf if p == 0 else math.inf
    a = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2,
         1.383577518672690e2, -3.066479806614716e1, 2.506628277459239]
    b = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2,
         6.680131188771972e1, -1.328068155288572e1]
    c = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838,
         -2.549732539343734, 4.374664141464968, 2.938163982698783]
    d = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416]
    plow = 0.02425
    phigh = 1 - plow
    if p < plow:
        q = math.sqrt(-2 * math.log(p))
        return (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
    if p > phigh:
        q = math.sqrt(-2 * math.log(1-p))
        return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
    q = p - 0.5
    r = q*q
    return (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q / (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1)


def psr_against_benchmark(returns: list[float], benchmark_annual_sharpe: float) -> float:
    n = len(returns)
    if n < 3:
        return float("nan")
    mean = statistics.fmean(returns)
    sd = statistics.stdev(returns)
    if sd <= 1e-18:
        return 0.0
    sr = mean / sd  # daily SR
    sr0 = benchmark_annual_sharpe / SQRT_252
    skew = sample_skew(returns)
    kurt = sample_kurtosis(returns)
    denom_sq = max(1 - skew * sr + ((kurt - 1) / 4) * sr * sr, 1e-12)
    z = (sr - sr0) * math.sqrt(n - 1) / math.sqrt(denom_sq)
    return norm_cdf(z)


def multiple_trial_null_threshold_annual(n_obs: int, trials: int) -> float:
    """Approx expected best annual Sharpe under independent zero-alpha Gaussian trials.

    This is intentionally labelled a DSR-style stress scenario rather than a formal DSR because
    the historical cross-trial Sharpe variance/correlation matrix was not logged prospectively.
    """
    if trials <= 1:
        return 0.0
    gamma = 0.5772156649015329
    z1 = norm_ppf(1 - 1 / trials)
    z2 = norm_ppf(1 - 1 / (trials * math.e))
    expected_max_z = (1 - gamma) * z1 + gamma * z2
    daily_threshold = expected_max_z / math.sqrt(max(n_obs, 1))
    return daily_threshold * SQRT_252


def print_series_audit(series: Series, bootstrap_reps: int) -> None:
    full = metrics_from_values(series.values, series.dates)
    rs = series.returns
    skew = sample_skew(rs)
    kurt = sample_kurtosis(rs)
    print(f"SERIES,{series.name},rows={len(series.values)},start={series.dates[0]},end={series.dates[-1]}")
    print(f"FULL,{series.name},cagr={full.cagr:.6%},mdd={full.max_drawdown:.6%},vol={full.volatility:.6%},sharpe={full.sharpe:.6f},skew={skew:.4f},kurtosis={kurt:.4f}")

    for years, sessions in [(3, 756), (5, 1260), (10, 2520)]:
        ws = rolling_windows(series, sessions)
        sharpes = [m.sharpe for m in ws]
        cagrs = [m.cagr for m in ws]
        mdds = [m.max_drawdown for m in ws]
        print(
            f"ROLLING,{series.name},{years}y,n={len(ws)},"
            f"sharpe_worst={min(sharpes):.4f},sharpe_p10={percentile(sharpes,.10):.4f},sharpe_median={percentile(sharpes,.50):.4f},"
            f"cagr_worst={min(cagrs):.4%},cagr_p10={percentile(cagrs,.10):.4%},"
            f"mdd_worst={max(mdds):.4%},positive_sharpe={sum(x>0 for x in sharpes)/len(sharpes):.2%}"
        )

    for block in [20, 63, 252]:
        boot = moving_block_bootstrap(rs, block=block, reps=bootstrap_reps, seed=20260814 + block)
        print(
            f"BOOTSTRAP,{series.name},block={block},reps={bootstrap_reps},"
            f"cagr95={boot['cagr'][0]:.4%}|{boot['cagr'][1]:.4%}|{boot['cagr'][2]:.4%},"
            f"mdd95={boot['mdd'][0]:.4%}|{boot['mdd'][1]:.4%}|{boot['mdd'][2]:.4%},"
            f"sharpe95={boot['sharpe'][0]:.4f}|{boot['sharpe'][1]:.4f}|{boot['sharpe'][2]:.4f}"
        )

    for trials in [10, 50, 100, 250, 500, 1000, 5000]:
        threshold = multiple_trial_null_threshold_annual(len(rs), trials)
        psr = psr_against_benchmark(rs, threshold)
        print(f"MULTITRIAL_PSR,{series.name},trials={trials},null_best_sharpe={threshold:.4f},psr={psr:.8f}")


def compare(a: Series, b: Series) -> None:
    common = sorted(set(a.dates).intersection(b.dates))
    ai = {d: v for d, v in zip(a.dates, a.values)}
    bi = {d: v for d, v in zip(b.dates, b.values)}
    av = [ai[d] for d in common]
    bv = [bi[d] for d in common]
    ar = [av[i]/av[i-1]-1 for i in range(1,len(av))]
    br = [bv[i]/bv[i-1]-1 for i in range(1,len(bv))]
    corr_num = sum((x-statistics.fmean(ar))*(y-statistics.fmean(br)) for x,y in zip(ar,br))
    corr_den = math.sqrt(sum((x-statistics.fmean(ar))**2 for x in ar)*sum((y-statistics.fmean(br))**2 for y in br))
    corr = corr_num/corr_den if corr_den>1e-18 else 0
    diff = [y-x for x,y in zip(ar,br)]
    diff_mean = statistics.fmean(diff)
    diff_sd = statistics.stdev(diff)
    diff_sharpe = diff_mean/diff_sd*SQRT_252 if diff_sd>1e-18 else 0
    print(f"PAIR,{a.name}->{b.name},common={len(common)},daily_corr={corr:.6f},active_ann_mean={diff_mean*252:.4%},active_sharpe={diff_sharpe:.4f}")
    for years,sessions in [(3,756),(5,1260),(10,2520)]:
        wins=0; total=0; sharpe_wins=0
        for end in range(sessions,len(common),21):
            start=end-sessions
            ma=metrics_from_values(av[start:end+1],common[start:end+1])
            mb=metrics_from_values(bv[start:end+1],common[start:end+1])
            total+=1
            wins += mb.cagr > ma.cagr
            sharpe_wins += mb.sharpe > ma.sharpe
        if total:
            print(f"PAIR_ROLLING,{a.name}->{b.name},{years}y,n={total},cagr_improve={wins/total:.2%},sharpe_improve={sharpe_wins/total:.2%}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--low-noise", default="tools/research-results/daily_factor_panel.csv")
    ap.add_argument("--c3l3", default="/private/tmp/c3l3_state_panel_audit.csv")
    ap.add_argument("--bootstrap-reps", type=int, default=1000)
    args = ap.parse_args()

    low = load_panel(Path(args.low_noise), "low_noise")
    c3 = load_panel(Path(args.c3l3), "c3l3")
    print("STRATEGY_OVERFIT_AUDIT_V1")
    print("NOTE,multiple-trial PSR is a conservative DSR-style scenario, not formal DSR/PBO; prospective trial covariance was not logged")
    print_series_audit(low, args.bootstrap_reps)
    print_series_audit(c3, args.bootstrap_reps)
    compare(low, c3)


if __name__ == "__main__":
    main()
