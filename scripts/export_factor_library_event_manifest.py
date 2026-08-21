#!/usr/bin/env python3
"""Export locked AssetTimeMachine event-factor evidence to FlyingrtxFast factor-library-v1.

This is an evidence/catalog sync only. It does not rerun backtests, search parameters, create a new
research trial, or claim that retrospective event-overlay metrics are forward-horizon factor metrics.
Until the factor library has an explicit event-overlay result type, structured ``results`` remain empty
and the exact preregistration/result/robustness evidence is attached as immutable artifacts instead.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SOURCE_REPOSITORY = "flyingrtx2333/AssetTimeMachine"
SOURCE_PROJECT = "AssetTimeMachine"

FACTOR_SPECS: list[dict[str, Any]] = [
    {
        "factor_key": "atm.event.creditcash_hyg_shy_20",
        "display_name": "信用风险偏好 HYG/SHY 20观测",
        "family": "credit_risk_appetite",
        "description": "HYG/SHY 调整收盘价相对强弱状态；仅作为冻结 V11 事件级风险预算研究因子，不代表生产策略。",
        "tags": ["ATM-SVP-2", "event_overlay", "credit", "retrospective_fail", "prospective_shadow"],
        "version_key": "hyg-shy-20-v1",
        "formula_text": "risk_on = I[(HYG_t / SHY_t) >= (HYG_t-20c / SHY_t-20c)], using common source observations available by T-1 and max 7 calendar days stale",
        "parameters": {
            "numerator": "HYG",
            "denominator": "SHY",
            "price_field": "adjusted_close",
            "lookback_common_observations": 20,
            "max_stale_calendar_days": 7,
            "signal_direction": "ratio_non_decreasing",
        },
        "required_inputs": ["HYG adjusted_close", "SHY adjusted_close"],
        "source_path": "tools/final_crisis_filter_v6.swiftpart",
        "lineage_trial": "ATM-SVP2-ORTHO-FACTOR-006",
        "historical_status": "FAIL_MDD_AND_RISK_ADJUSTED_QUALITY",
        "overlay_evaluation": {
            "base_strategy": "nfci-dual-core-v11 / dualcore-v11-2026-08-15",
            "event_scope": "unique frozen V11 trade events with 0 < gross < 1",
            "risk_on_action": "complete existing positive V11 holdings proportionally to 100% gross",
            "matched_control": "complete whenever factor is available",
            "historical_cagr_percent": 16.067258,
            "historical_sharpe": 1.377913,
            "historical_mdd_percent": 12.777213,
            "admit_for_robustness": False,
            "strong_incremental": False,
        },
        "artifacts": [
            ("creditcash-preregister", "preregistration", "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-006.json"),
            ("creditcash-result", "formal_result", "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-006.json"),
        ],
    },
    {
        "factor_key": "atm.event.breadth_rsp_spy_20",
        "display_name": "市场广度 RSP/SPY 20观测",
        "family": "market_breadth",
        "description": "RSP/SPY 调整收盘价相对强弱状态；历史筛选通过但独立 block-bootstrap robustness 未通过，当前只作研究/前瞻 shadow。",
        "tags": ["ATM-SVP-2", "event_overlay", "breadth", "screening_pass", "robustness_fail", "prospective_shadow"],
        "version_key": "rsp-spy-20-v1",
        "formula_text": "risk_on = I[(RSP_t / SPY_t) >= (RSP_t-20c / SPY_t-20c)], using common source observations available by T-1 and max 7 calendar days stale",
        "parameters": {
            "numerator": "RSP",
            "denominator": "SPY",
            "price_field": "adjusted_close",
            "lookback_common_observations": 20,
            "max_stale_calendar_days": 7,
            "signal_direction": "ratio_non_decreasing",
        },
        "required_inputs": ["RSP adjusted_close", "SPY adjusted_close"],
        "source_path": "tools/orthogonal_event_factor_v3.swiftpart",
        "lineage_trial": "ATM-SVP2-ORTHO-FACTOR-003",
        "historical_status": "SCREENING_PASS_ROBUSTNESS_FAIL",
        "overlay_evaluation": {
            "base_strategy": "nfci-dual-core-v11 / dualcore-v11-2026-08-15",
            "event_scope": "frozen V11 de-risk events",
            "risk_on_action": "retain exactly 50% of each event reduction, gross cap 100%",
            "matched_control": "retain 50% on every factor-available de-risk event",
            "historical_cagr_percent": 14.425407,
            "historical_sharpe": 1.470087,
            "historical_mdd_percent": 9.102436,
            "admit_for_robustness": True,
            "strong_incremental": False,
            "bootstrap_probability_cagr_gt_v11": 0.61395,
            "bootstrap_robust": False,
        },
        "artifacts": [
            ("breadth-preregister", "preregistration", "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-003.json"),
            ("breadth-result", "formal_result", "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-003.json"),
        ],
    },
    {
        "factor_key": "atm.event.highbeta_sphb_splv_20",
        "display_name": "高Beta风险偏好 SPHB/SPLV 20观测",
        "family": "risk_appetite",
        "description": "SPHB/SPLV 调整收盘价相对强弱状态；历史筛选通过但独立 block-bootstrap robustness 未通过，当前只作研究/前瞻 shadow。",
        "tags": ["ATM-SVP-2", "event_overlay", "high_beta", "screening_pass", "robustness_fail", "prospective_shadow"],
        "version_key": "sphb-splv-20-v1",
        "formula_text": "risk_on = I[(SPHB_t / SPLV_t) >= (SPHB_t-20c / SPLV_t-20c)], using common source observations available by T-1 and max 7 calendar days stale",
        "parameters": {
            "numerator": "SPHB",
            "denominator": "SPLV",
            "price_field": "adjusted_close",
            "lookback_common_observations": 20,
            "max_stale_calendar_days": 7,
            "signal_direction": "ratio_non_decreasing",
        },
        "required_inputs": ["SPHB adjusted_close", "SPLV adjusted_close"],
        "source_path": "tools/orthogonal_event_factor_v4.swiftpart",
        "lineage_trial": "ATM-SVP2-ORTHO-FACTOR-004",
        "historical_status": "SCREENING_PASS_ROBUSTNESS_FAIL",
        "overlay_evaluation": {
            "base_strategy": "nfci-dual-core-v11 / dualcore-v11-2026-08-15",
            "event_scope": "frozen V11 de-risk events",
            "risk_on_action": "retain exactly 50% of each event reduction, gross cap 100%",
            "matched_control": "retain 50% on every factor-available de-risk event",
            "historical_cagr_percent": 14.392126,
            "historical_sharpe": 1.494292,
            "historical_mdd_percent": 8.521421,
            "admit_for_robustness": True,
            "strong_incremental": False,
            "bootstrap_probability_cagr_gt_v11": 0.59620,
            "bootstrap_robust": False,
        },
        "artifacts": [
            ("highbeta-preregister", "preregistration", "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-004.json"),
            ("highbeta-result", "formal_result", "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-004.json"),
        ],
    },
]

SHARED_ARTIFACTS = [
    ("screening-winners-robust-preregister", "robustness_preregistration", "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-FACTOR-ROBUST-001.json"),
    ("screening-winners-robust-result", "robustness_result", "tools/research-results/strategy-validation/results/ATM-SVP2-FACTOR-ROBUST-001.json"),
    ("prospective-factor-preregister", "prospective_preregistration", "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-PROSPECTIVE-FACTOR-001.json"),
    ("prospective-factor-registry", "prospective_registry", "docs/strategies/prospective-factor-shadow-registry-2026-08-21-v2.md"),
]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mime_type_for(path: Path) -> str:
    if path.suffix == ".json":
        return "application/json"
    if path.suffix == ".md":
        return "text/markdown"
    if path.suffix == ".csv":
        return "text/csv"
    return "application/octet-stream"


def artifact_spec(
    artifact_key: str,
    artifact_type: str,
    relative_path: str,
    *,
    factor_key: str | None = None,
    version_key: str | None = None,
) -> dict[str, Any]:
    path = ROOT / relative_path
    if not path.is_file():
        raise FileNotFoundError(path)
    item: dict[str, Any] = {
        "artifact_key": artifact_key,
        "artifact_type": artifact_type,
        "original_name": path.name,
        "mime_type": mime_type_for(path),
        "byte_size": path.stat().st_size,
        "sha256": sha256_file(path),
        "local_path": relative_path,
    }
    if factor_key is not None:
        item["factor_key"] = factor_key
    if version_key is not None:
        item["version_key"] = version_key
    return item


def evidence_bundle_fingerprint() -> tuple[str, dict[str, dict[str, str]]]:
    dataset_paths = [
        "tools/research-results/strategy-validation/datasets/ATM-SVP2-ORTHO-FACTOR-003.json",
        "tools/research-results/strategy-validation/datasets/ATM-SVP2-ORTHO-FACTOR-004.json",
        "tools/research-results/strategy-validation/datasets/ATM-SVP2-ORTHO-FACTOR-006.json",
        "tools/research-results/strategy-validation/datasets/ATM-SVP2-FACTOR-ROBUST-001.json",
    ]
    entries = {
        relative: {"sha256": sha256_file(ROOT / relative)}
        for relative in dataset_paths
    }
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest(), entries


def build_manifest(*, source_commit: str) -> dict[str, Any]:
    if len(source_commit) != 40 or any(ch not in "0123456789abcdef" for ch in source_commit):
        raise ValueError("source_commit must be a lowercase 40-character Git SHA")

    dataset_fingerprint, dataset_entries = evidence_bundle_fingerprint()
    factors: list[dict[str, Any]] = []
    artifacts: list[dict[str, Any]] = []
    status_by_factor: dict[str, Any] = {}

    for spec in FACTOR_SPECS:
        source_path = ROOT / spec["source_path"]
        if not source_path.is_file():
            raise FileNotFoundError(source_path)
        factor = {
            "factor_key": spec["factor_key"],
            "display_name": spec["display_name"],
            "family": spec["family"],
            "description": spec["description"],
            "tags": list(spec["tags"]),
            "research_role": "alpha_candidate",
            "owner_name": "AssetTimeMachine Research",
            "source_project": SOURCE_PROJECT,
            "version": {
                "version_key": spec["version_key"],
                "formula_text": spec["formula_text"],
                "parameters": dict(spec["parameters"]),
                "required_inputs": list(spec["required_inputs"]),
                "applicable_universe": ["nfci-dual-core-v11 event-level risk overlay"],
                "frequency": "daily",
                "lookback_sessions": 20,
                "observation_lag_sessions": 1,
                "source_path": spec["source_path"],
                "code_sha256": sha256_file(source_path),
                "lifecycle_status": "research",
                "materialization_policy": "none",
            },
            "results": [],
        }
        factors.append(factor)
        status_by_factor[spec["factor_key"]] = {
            "lineage_trial": spec["lineage_trial"],
            "historical_status": spec["historical_status"],
            "overlay_evaluation": spec["overlay_evaluation"],
        }
        for artifact_key, artifact_type, relative_path in spec["artifacts"]:
            artifacts.append(
                artifact_spec(
                    artifact_key,
                    artifact_type,
                    relative_path,
                    factor_key=spec["factor_key"],
                    version_key=spec["version_key"],
                )
            )

    for artifact_key, artifact_type, relative_path in SHARED_ARTIFACTS:
        artifacts.append(artifact_spec(artifact_key, artifact_type, relative_path))

    runner_path = "scripts/export_factor_library_event_manifest.py"
    return {
        "schema_version": "factor-library-v1",
        "batch_key": f"atm-svp2-event-factor-sync-{source_commit[:12]}",
        "source_repository": SOURCE_REPOSITORY,
        "source_commit": source_commit,
        "dataset_fingerprint": dataset_fingerprint,
        "methodology": {
            "evaluation_kind": "event_overlay",
            "sync_kind": "catalog_sync_of_existing_research_evidence",
            "new_research_trial_created": False,
            "sample_design": "legacy/fixed-fold event-overlay research without a truthful strict development-validation-holdout partition",
            "structured_results_policy": "omitted: factor-library-v1 forward-horizon result coordinates do not faithfully represent event-overlay CAGR/Sharpe/MDD; exact evidence is attached instead",
            "base_strategy": "nfci-dual-core-v11 / dualcore-v11-2026-08-15",
            "factor_status": status_by_factor,
            "prospective_trial": "ATM-SVP2-PROSPECTIVE-FACTOR-001",
            "g3_note": "Historical screening/robustness outcomes remain exactly as recorded; this import is not a new trial and must not reset model-selection accounting.",
        },
        "run_key": f"atm-svp2-event-factor-sync-{source_commit[:12]}",
        "run_title": "ATM-SVP-2 事件因子研究档案同步",
        "runner_path": runner_path,
        "runner_sha256": sha256_file(ROOT / runner_path),
        "dataset_spec": {
            "kind": "multi_trial_existing_evidence_bundle",
            "dataset_manifests": dataset_entries,
        },
        "summary": "同步三条已暴露 event-level 因子及其正式证据到 FlyingrtxFast 私有因子库；不重新回测、不新增 trial、不改变 lifecycle 结论。",
        "factors": factors,
        "artifacts": artifacts,
        "observations": [],
    }


def current_head() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "unable to resolve Git HEAD")
    return completed.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-commit", default=None)
    args = parser.parse_args()

    source_commit = args.source_commit or current_head()
    manifest = build_manifest(source_commit=source_commit)
    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    digest = sha256_file(output)
    print(
        f"FACTOR_LIBRARY_EVENT_MANIFEST_WRITTEN output={output.relative_to(ROOT)} "
        f"factors={len(manifest['factors'])} artifacts={len(manifest['artifacts'])} sha256={digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
