#!/usr/bin/env python3
"""Convert current AssetTimeMachine factor research products to factor-library-v1."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import subprocess
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

try:
    from scripts.factor_library_catalog import build_factor_catalog
except ModuleNotFoundError:  # Direct `python3 scripts/...` execution.
    from factor_library_catalog import build_factor_catalog


ARTIFACT_PATHS = [
    "tools/research-results/2026-08-13-daily-alpha-factor-research.md",
    "tools/research-results/daily-factor-lab/cross_sectional_factor_scores.csv",
    "tools/research-results/daily-factor-lab/cross_sectional_incremental_scores.csv",
    "tools/research-results/daily-factor-lab/factor_univariate_scores.csv",
]
MIME_TYPES = {".md": "text/markdown", ".csv": "text/csv", ".json": "application/json"}
SEGMENT_ORDER = {"full": 0, "development": 1, "validation": 2, "holdout": 3}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _finite_number(raw: Any) -> Optional[float]:
    if raw in (None, "", ".", "nan", "NaN", "None"):
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def _integer(raw: Any) -> Optional[int]:
    value = _finite_number(raw)
    return int(value) if value is not None else None


def _read_rows(path: Path) -> Iterable[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _result_bucket(
    grouped: Dict[str, Dict[Tuple[str, int], Dict[str, Any]]],
    factor_key: str,
    target_key: str,
    horizon: int,
) -> Dict[str, Any]:
    coordinate = (target_key, horizon)
    if coordinate not in grouped[factor_key]:
        grouped[factor_key][coordinate] = {
            "target_key": target_key,
            "horizon_sessions": horizon,
            "result_status": "completed",
            "sample_counts": {},
            "conclusion": None,
            "metrics": [],
        }
    return grouped[factor_key][coordinate]


def _append_metric(result: Dict[str, Any], segment: str, metric_key: str, raw: Any) -> None:
    result["metrics"].append(
        {
            "sample_segment": segment,
            "metric_key": metric_key,
            "value": _finite_number(raw),
            "unit": None,
        }
    )


def _load_univariate_results(
    repo_root: Path,
    known_keys: set,
    grouped: Dict[str, Dict[Tuple[str, int], Dict[str, Any]]],
) -> None:
    path = repo_root / "tools/research-results/daily-factor-lab/factor_univariate_scores.csv"
    mappings = {
        "full": ["beta_full_sd", "t_full_nw", "r2_full"],
        "development": [
            "dev_beta_sd",
            "dev_t_nw",
            "dev_p",
            "dev_r2",
            "dev_rank_ic",
            "dev_q5_q1",
            "dev_quintile_mono",
            "dev_bh_q",
            "selection_score",
        ],
        "validation": ["val_beta_sd", "val_t_nw", "sign_stable_val"],
        "holdout": ["hold_beta_sd", "hold_t_nw", "sign_stable_hold"],
    }
    for row in _read_rows(path):
        factor_key = row.get("factor", "")
        if factor_key not in known_keys:
            continue
        horizon = _integer(row.get("horizon"))
        target_key = row.get("label", "").strip()
        if not horizon or not target_key:
            continue
        result = _result_bucket(grouped, factor_key, target_key, horizon)
        n_full = _integer(row.get("n_full"))
        if n_full is not None:
            result["sample_counts"]["full"] = n_full
        for segment, columns in mappings.items():
            for column in columns:
                _append_metric(result, segment, column, row.get(column))


def _load_cross_sectional_results(
    repo_root: Path,
    known_keys: set,
    grouped: Dict[str, Dict[Tuple[str, int], Dict[str, Any]]],
) -> None:
    sources = [
        (
            "tools/research-results/daily-factor-lab/cross_sectional_factor_scores.csv",
            "cross_sectional_return",
            {
                "development": [
                    "dev_rank_ic",
                    "dev_ic_t_nw",
                    "dev_ic_p",
                    "dev_top2_bottom2",
                    "dev_spread_t_nw",
                    "dev_bh_q",
                    "selection_score",
                ],
                "validation": [
                    "val_rank_ic",
                    "val_ic_t_nw",
                    "val_top2_bottom2",
                    "val_spread_t_nw",
                    "val_sign_stable",
                ],
                "holdout": [
                    "hold_rank_ic",
                    "hold_ic_t_nw",
                    "hold_top2_bottom2",
                    "hold_spread_t_nw",
                    "hold_sign_stable",
                ],
            },
        ),
        (
            "tools/research-results/daily-factor-lab/cross_sectional_incremental_scores.csv",
            "cross_sectional_incremental_return",
            {
                "development": [
                    "dev_factor_beta",
                    "dev_factor_t_nw",
                    "dev_factor_p",
                    "dev_weight_beta",
                    "dev_weight_t_nw",
                    "dev_bh_q",
                    "score",
                ],
                "validation": ["val_factor_beta", "val_factor_t_nw", "val_sign_stable"],
                "holdout": ["hold_factor_beta", "hold_factor_t_nw", "hold_sign_stable"],
                "full": [
                    "overlap_n",
                    "mean_rank_corr_with_target",
                    "top1_match_rate",
                    "top2_mean_overlap",
                ],
            },
        ),
    ]
    for relative_path, target_key, mappings in sources:
        for row in _read_rows(repo_root / relative_path):
            factor_key = row.get("factor", "")
            if factor_key not in known_keys:
                continue
            horizon = _integer(row.get("horizon"))
            if not horizon:
                continue
            result = _result_bucket(grouped, factor_key, target_key, horizon)
            dev_n = _integer(row.get("dev_n"))
            if dev_n is not None:
                result["sample_counts"]["development"] = dev_n
            for segment, columns in mappings.items():
                for column in columns:
                    _append_metric(result, segment, column, row.get(column))


def _artifact_manifest(repo_root: Path) -> List[Dict[str, Any]]:
    artifacts = []
    for relative_path in sorted(ARTIFACT_PATHS):
        path = repo_root / relative_path
        if not path.is_file():
            raise FileNotFoundError("研究附件不存在: %s" % relative_path)
        artifacts.append(
            {
                "artifact_key": re.sub(r"[^a-z0-9]+", "-", path.stem.lower()).strip("-"),
                "artifact_type": "report" if path.suffix == ".md" else "metrics",
                "original_name": path.name,
                "mime_type": MIME_TYPES.get(path.suffix.lower(), "application/octet-stream"),
                "byte_size": path.stat().st_size,
                "sha256": sha256_file(path),
                "local_path": relative_path,
                "factor_key": None,
                "version_key": None,
            }
        )
    return artifacts


def _panel_bounds(panel_path: Path) -> Tuple[str, str]:
    first = None
    last = None
    with panel_path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            value = row.get("date")
            if value:
                first = first or value
                last = value
    if not first or not last:
        raise ValueError("日频因子面板没有有效日期")
    return first, last


def build_factor_manifest(repo_root: Path, source_commit: str) -> Dict[str, Any]:
    repo_root = repo_root.resolve()
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("source_commit 必须是 40 位小写 Git SHA")
    panel_path = repo_root / "tools/research-results/daily_factor_panel.csv"
    lab_path = repo_root / "tools/research-results/daily_alpha_factor_lab.py"
    first_date, last_date = _panel_bounds(panel_path)
    catalog = build_factor_catalog()
    known_keys = {row["factor_key"] for row in catalog}
    grouped = defaultdict(dict)
    _load_univariate_results(repo_root, known_keys, grouped)
    _load_cross_sectional_results(repo_root, known_keys, grouped)

    factors = []
    for record in catalog:
        code_path = repo_root / record["source_path"]
        version = {
            "version_key": "v1",
            "formula_text": record["formula_text"],
            "parameters": record["parameters"],
            "required_inputs": record["required_inputs"],
            "applicable_universe": record["applicable_universe"],
            "frequency": record["frequency"],
            "lookback_sessions": record["lookback_sessions"],
            "observation_lag_sessions": record["observation_lag_sessions"],
            "source_path": record["source_path"],
            "code_sha256": sha256_file(code_path),
            "lifecycle_status": record["lifecycle_status"],
            "materialization_policy": record["materialization_policy"],
        }
        results = list(grouped.get(record["factor_key"], {}).values())
        for result in results:
            result["metrics"].sort(
                key=lambda item: (SEGMENT_ORDER[item["sample_segment"]], item["metric_key"])
            )
        results.sort(key=lambda item: (item["target_key"], item["horizon_sessions"]))
        factors.append(
            {
                "factor_key": record["factor_key"],
                "display_name": record["display_name"],
                "family": record["family"],
                "description": record["description"],
                "tags": record["tags"],
                "research_role": record["research_role"],
                "owner_name": record["owner_name"],
                "source_project": record["source_project"],
                "version": version,
                "results": results,
            }
        )

    batch_key = "daily-alpha-%s-%s" % (last_date, source_commit[:8])
    return {
        "schema_version": "factor-library-v1",
        "batch_key": batch_key,
        "source_repository": "flyingrtx2333/AssetTimeMachine",
        "source_commit": source_commit,
        "dataset_fingerprint": sha256_file(panel_path),
        "sample_windows": {
            "development": {"start": first_date, "end": "2014-12-31"},
            "validation": {"start": "2015-01-01", "end": "2020-12-31"},
            "holdout": {"start": "2021-01-01", "end": last_date},
        },
        "methodology": {
            "signal_timing": "close_t_to_future_return",
            "standard_errors": "newey_west_hac",
            "multiple_testing": "benjamini_hochberg_fdr",
            "cross_sectional_metric": "spearman_rank_ic",
            "holdout_used_for_selection": False,
        },
        "run_key": batch_key,
        "run_title": "日频 Alpha 因子研究",
        "runner_path": "tools/research-results/daily_alpha_factor_lab.py",
        "runner_sha256": sha256_file(lab_path),
        "dataset_spec": {
            "panel_path": "tools/research-results/daily_factor_panel.csv",
            "frequency": "daily",
            "assets": ["gold", "nasdaq", "sp500", "csi300", "shanghai"],
        },
        "started_at": "%sT00:00:00" % last_date,
        "finished_at": "%sT00:00:00" % last_date,
        "summary": "当前日频因子研究目录与已生成指标。",
        "factors": factors,
        "artifacts": _artifact_manifest(repo_root),
        "observations": [],
    }


def write_manifest(manifest: Dict[str, Any], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def _git_commit(repo_root: Path) -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"],
        cwd=str(repo_root),
        text=True,
    ).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="生成因子库导入清单")
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build", help="生成 factor-library-v1.json")
    build.add_argument("--output", required=True, type=Path)
    build.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    build.add_argument("--source-commit")
    args = parser.parse_args()
    if args.command == "build":
        repo_root = args.repo_root.resolve()
        manifest = build_factor_manifest(
            repo_root,
            args.source_commit or _git_commit(repo_root),
        )
        write_manifest(manifest, args.output)
        print("已生成 %s（%d 个因子）" % (args.output, len(manifest["factors"])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
