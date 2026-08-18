#!/usr/bin/env python3
"""Statistical diagnostics for ATM-SVP-1.

The module is intentionally strategy-agnostic. Strategy return/value series must be produced by
AssetTimeMachine's Swift engine. This script only computes statistics such as PSR/DSR from those
outputs and from a complete trial-family Sharpe inventory.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from pathlib import Path
from statistics import NormalDist
from typing import Iterable

EULER_MASCHERONI = 0.5772156649015329
NORMAL = NormalDist()


def read_numeric_column(path: Path, column: str) -> list[float]:
    rows = csv.DictReader(path.open(encoding="utf-8"))
    values: list[float] = []
    for row in rows:
        raw = row.get(column)
        if raw is None or raw == "":
            continue
        value = float(raw)
        if math.isfinite(value):
            values.append(value)
    if len(values) < 3:
        raise SystemExit(f"Insufficient numeric rows in {path} column={column}")
    return values


def values_to_returns(values: list[float]) -> list[float]:
    if any(value <= 0 for value in values):
        raise SystemExit("Portfolio values must be positive")
    return [values[i] / values[i - 1] - 1.0 for i in range(1, len(values))]


def read_trial_sharpes(path: Path, column: str) -> list[float]:
    if path.suffix.lower() == ".json":
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            value = value.get(column)
        if not isinstance(value, list):
            raise SystemExit(f"JSON trial Sharpe file must be a list or contain list key={column}")
        sharpes = [float(item) for item in value]
    else:
        rows = csv.DictReader(path.open(encoding="utf-8"))
        sharpes = []
        for row in rows:
            raw = row.get(column)
            if raw is None or raw == "":
                continue
            sharpes.append(float(raw))
    sharpes = [value for value in sharpes if math.isfinite(value)]
    if not sharpes:
        raise SystemExit("No finite trial Sharpes found")
    return sharpes


def mean(values: Iterable[float]) -> float:
    return statistics.fmean(values)


def sample_sharpe(returns: list[float]) -> float:
    if len(returns) < 2:
        raise SystemExit("Need at least two returns")
    sd = statistics.stdev(returns)
    if sd <= 0:
        raise SystemExit("Return standard deviation is zero")
    return mean(returns) / sd


def standardized_moments(returns: list[float]) -> tuple[float, float]:
    """Return moment skewness and Pearson kurtosis (normal => 3).

    For the long daily histories used by the protocol, moment estimators are stable and avoid an
    external SciPy dependency. The exact estimator is fixed here so future runs are reproducible.
    """
    n = len(returns)
    mu = mean(returns)
    m2 = sum((x - mu) ** 2 for x in returns) / n
    if m2 <= 0:
        raise SystemExit("Cannot compute moments with zero variance")
    m3 = sum((x - mu) ** 3 for x in returns) / n
    m4 = sum((x - mu) ** 4 for x in returns) / n
    skew = m3 / (m2 ** 1.5)
    kurtosis = m4 / (m2 * m2)
    return skew, kurtosis


def probabilistic_sharpe_ratio(
    observed_sharpe: float,
    benchmark_sharpe: float,
    observations: int,
    skewness: float,
    pearson_kurtosis: float,
) -> tuple[float, float]:
    """Return (PSR probability, z-score) at the same frequency as observed_sharpe."""
    if observations < 3:
        raise SystemExit("PSR requires at least three observations")
    variance_term = (
        1.0
        - skewness * observed_sharpe
        + ((pearson_kurtosis - 1.0) / 4.0) * observed_sharpe * observed_sharpe
    )
    if variance_term <= 0:
        raise SystemExit(f"Invalid PSR variance term: {variance_term}")
    z = (
        (observed_sharpe - benchmark_sharpe)
        * math.sqrt(observations - 1.0)
        / math.sqrt(variance_term)
    )
    return NORMAL.cdf(z), z


def expected_maximum_sharpe(trial_sharpes: list[float]) -> float:
    """Expected maximum Sharpe under the zero-skill null using the DSR approximation.

    trial_sharpes must all use the same frequency. Cross-trial dispersion is estimated with sample
    standard deviation. N=1 reduces to a zero benchmark (PSR against zero).
    """
    n = len(trial_sharpes)
    if n == 1:
        return 0.0
    if n < 1:
        raise SystemExit("Need at least one trial Sharpe")
    sigma = statistics.stdev(trial_sharpes)
    if sigma <= 0:
        return 0.0
    q1 = NORMAL.inv_cdf(1.0 - 1.0 / n)
    q2 = NORMAL.inv_cdf(1.0 - 1.0 / (n * math.e))
    expected_standard_max = (
        (1.0 - EULER_MASCHERONI) * q1
        + EULER_MASCHERONI * q2
    )
    return sigma * expected_standard_max


def deflated_sharpe_ratio(
    returns: list[float],
    annualized_trial_sharpes: list[float],
    annualization: float,
) -> dict[str, float | int]:
    if annualization <= 0:
        raise SystemExit("annualization must be positive")
    scale = math.sqrt(annualization)
    daily_trial_sharpes = [value / scale for value in annualized_trial_sharpes]
    observed_daily = sample_sharpe(returns)
    skewness, kurtosis = standardized_moments(returns)
    benchmark_daily = expected_maximum_sharpe(daily_trial_sharpes)
    probability, z = probabilistic_sharpe_ratio(
        observed_sharpe=observed_daily,
        benchmark_sharpe=benchmark_daily,
        observations=len(returns),
        skewness=skewness,
        pearson_kurtosis=kurtosis,
    )
    return {
        "observations": len(returns),
        "trial_count": len(annualized_trial_sharpes),
        "observed_sharpe_annualized": observed_daily * scale,
        "expected_max_sharpe_annualized": benchmark_daily * scale,
        "skewness": skewness,
        "pearson_kurtosis": kurtosis,
        "dsr_probability": probability,
        "dsr_z": z,
    }


def cmd_dsr(args: argparse.Namespace) -> None:
    if not args.certify_complete_trial_family:
        raise SystemExit(
            "Refusing DSR calculation without --certify-complete-trial-family. "
            "ATM-SVP-1 requires every tested candidate in the family to be included."
        )
    series = read_numeric_column(Path(args.series_csv), args.series_column)
    if args.series_kind == "value":
        returns = values_to_returns(series)
    else:
        returns = series
    trial_sharpes = read_trial_sharpes(Path(args.trial_sharpes), args.trial_sharpe_column)
    result = deflated_sharpe_ratio(returns, trial_sharpes, args.annualization)
    result["trial_family_id"] = args.trial_family_id
    result["complete_trial_family_certified"] = True
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    dsr = sub.add_parser("dsr")
    dsr.add_argument("--series-csv", required=True)
    dsr.add_argument("--series-column", default="portfolio_value")
    dsr.add_argument("--series-kind", choices=["value", "return"], default="value")
    dsr.add_argument("--trial-sharpes", required=True)
    dsr.add_argument("--trial-sharpe-column", default="sharpe")
    dsr.add_argument("--trial-family-id", required=True)
    dsr.add_argument(
        "--certify-complete-trial-family",
        action="store_true",
        help="Required acknowledgement that the trial Sharpe input contains every tested candidate in this family.",
    )
    dsr.add_argument("--annualization", type=float, default=252.0)
    dsr.set_defaults(func=cmd_dsr)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
