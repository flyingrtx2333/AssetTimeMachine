#!/usr/bin/env python3
"""Export the four formal ATM-SVP-2 factor candidates completed after the original 18-factor catalog sync."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SOURCE_REPOSITORY = "flyingrtx2333/AssetTimeMachine"

FACTOR_SPECS: dict[str, dict[str, Any]] = {
    "F-BAA": {
        "trial_id": "ATM-SVP2-LIT-STRESS-001",
        "display_name": "信用压力 BAA10Y 20观测",
        "family": "credit_stress",
        "factor_key": "atm.event.baa10y_20",
        "source_path": "tools/literature_stress_factor_v1.swiftpart",
        "lookback_sessions": 20,
        "observation_lag_sessions": 1,
        "required_inputs": ["FRED BAA10Y"],
    },
    "F-EPU": {
        "trial_id": "ATM-SVP2-LIT-STRESS-001",
        "display_name": "经济政策不确定性 USEPUINDXD 20观测",
        "family": "policy_uncertainty",
        "factor_key": "atm.event.epu_usepuindxd_20",
        "source_path": "tools/literature_stress_factor_v1.swiftpart",
        "lookback_sessions": 20,
        "observation_lag_sessions": 1,
        "required_inputs": ["FRED USEPUINDXD"],
    },
    "F-MOVE": {
        "trial_id": "ATM-SVP2-LIT-STRESS-001",
        "display_name": "债券波动压力 MOVE 20观测",
        "family": "rates_volatility",
        "factor_key": "atm.event.move_20",
        "source_path": "tools/literature_stress_factor_v1.swiftpart",
        "lookback_sessions": 20,
        "observation_lag_sessions": 0,
        "required_inputs": ["Yahoo ^MOVE close"],
    },
    "F-VRP-PROXY": {
        "trial_id": "ATM-SVP2-VRP-001",
        "display_name": "波动率风险溢价代理 VIX-RV21",
        "family": "variance_risk_premium_proxy",
        "factor_key": "atm.event.vrp_proxy_vix_rv21_252median",
        "source_path": "tools/vrp_proxy_v1.swiftpart",
        "lookback_sessions": 252,
        "observation_lag_sessions": 0,
        "required_inputs": ["FRED VIXCLS", "frozen V11 S&P 500 sleeve daily prices"],
    },
}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version_key(candidate_id: str) -> str:
    return candidate_id.removeprefix("F-").lower().replace("_", "-") + "-v1"


def artifact_spec(
    key: str,
    kind: str,
    path: Path,
    factor_key: str,
    version_key_value: str,
) -> dict[str, Any]:
    return {
        "artifact_key": key,
        "artifact_type": kind,
        "original_name": path.name,
        "mime_type": "application/json",
        "byte_size": path.stat().st_size,
        "sha256": sha256_file(path),
        "local_path": path.relative_to(ROOT).as_posix(),
        "factor_key": factor_key,
        "version_key": version_key_value,
    }


def _trial_paths(trial_id: str) -> tuple[Path, Path, Path]:
    base = ROOT / "tools/research-results/strategy-validation"
    return (
        base / "preregistrations" / f"{trial_id}.json",
        base / "results" / f"{trial_id}.json",
        base / "datasets" / f"{trial_id}.json",
    )


def _source_definition(candidate_id: str, prereg: dict[str, Any]) -> dict[str, Any]:
    if candidate_id == "F-VRP-PROXY":
        return dict(prereg["factor_definition"])
    return dict(prereg["factor_sources"][candidate_id])


def _formula_text(candidate_id: str, source: dict[str, Any]) -> str:
    if candidate_id == "F-VRP-PROXY":
        return (
            "VRP_t=(VIX_t/100)^2-RV21_t; risk_on = I[VRP_t > median(previous 252 valid VRP observations)]"
        )
    return str(source["risk_on_rule"])


def build_manifest(*, source_commit: str) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("source_commit must be a lowercase 40-character Git SHA")

    factors: list[dict[str, Any]] = []
    artifacts: list[dict[str, Any]] = []
    dataset_entries: dict[str, dict[str, str]] = {}
    decisions: dict[str, Any] = {}
    loaded_trials: dict[str, tuple[dict[str, Any], dict[str, Any], Path, Path, Path]] = {}

    for candidate_id, spec in FACTOR_SPECS.items():
        trial_id = str(spec["trial_id"])
        if trial_id not in loaded_trials:
            prereg_path, result_path, dataset_path = _trial_paths(trial_id)
            prereg = json.loads(prereg_path.read_text(encoding="utf-8"))
            result = json.loads(result_path.read_text(encoding="utf-8"))
            loaded_trials[trial_id] = (prereg, result, prereg_path, result_path, dataset_path)
            dataset_entries[dataset_path.relative_to(ROOT).as_posix()] = {"sha256": sha256_file(dataset_path)}
        prereg, result, prereg_path, result_path, _ = loaded_trials[trial_id]

        result_by_id = {row["candidate_id"]: row for row in result.get("candidate_results", [])}
        candidate_result = result_by_id.get(candidate_id)
        if candidate_result is None:
            raise ValueError(f"formal result missing candidate {candidate_id} in {trial_id}")
        if bool(candidate_result.get("metrics", {}).get("robust_factor_pass")):
            raise ValueError(f"{candidate_id} is not rejected and must not be exported by this manifest")

        factor_key = str(spec["factor_key"])
        vkey = version_key(candidate_id)
        source = _source_definition(candidate_id, prereg)
        runner_path = ROOT / str(spec["source_path"])
        shared_rules = dict(prereg.get("shared_rules") or {})
        # Keep import-control metadata numerically stable across JSON database round-trips.
        # Exact high-precision formal metrics remain in the attached immutable result artifact.
        for key, value in list(shared_rules.items()):
            if isinstance(value, float) and value.is_integer():
                shared_rules[key] = int(value)

        decisions[factor_key] = {
            "candidate_id": candidate_id,
            "trial_id": trial_id,
            "trial_status": result.get("status"),
            "robust_factor_pass": bool(candidate_result.get("metrics", {}).get("robust_factor_pass")),
            "formal_result_artifact": result_path.relative_to(ROOT).as_posix(),
        }
        factors.append(
            {
                "factor_key": factor_key,
                "display_name": spec["display_name"],
                "family": spec["family"],
                "description": (
                    f"ATM-SVP-2 正式历史候选 {candidate_id}；已完成正式检验但未通过冻结 robust gate，"
                    "以 rejected 状态永久保留。"
                ),
                "tags": ["ATM-SVP-2", "formal_trial", "rejected", "followup_sync", candidate_id.lower()],
                "research_role": "alpha_candidate",
                "owner_name": "AssetTimeMachine Research",
                "source_project": "AssetTimeMachine",
                "version": {
                    "version_key": vkey,
                    "formula_text": _formula_text(candidate_id, source),
                    "parameters": {
                        "historical_trial_id": trial_id,
                        "source_definition": source,
                        "shared_rules": shared_rules,
                    },
                    "required_inputs": list(spec["required_inputs"]),
                    "applicable_universe": ["nfci-dual-core-v11 risk overlay research"],
                    "frequency": "daily",
                    "lookback_sessions": int(spec["lookback_sessions"]),
                    "observation_lag_sessions": int(spec["observation_lag_sessions"]),
                    "source_path": runner_path.relative_to(ROOT).as_posix(),
                    "code_sha256": sha256_file(runner_path),
                    "lifecycle_status": "rejected",
                    "materialization_policy": "none",
                },
                "results": [],
            }
        )

        suffix = candidate_id.removeprefix("F-").lower().replace("_", "-")
        artifacts.extend(
            [
                artifact_spec(f"{suffix}-preregister", "preregistration", prereg_path, factor_key, vkey),
                artifact_spec(f"{suffix}-result", "formal_result", result_path, factor_key, vkey),
            ]
        )

    if len(factors) != 4:
        raise AssertionError(f"expected 4 follow-up rejected factors, got {len(factors)}")

    encoded = json.dumps(dataset_entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    dataset_fingerprint = hashlib.sha256(encoded).hexdigest()
    runner_rel = "scripts/export_factor_library_followup_rejected_manifest.py"
    batch_key = f"atm-svp2-followup-rejected-v2-sync-{source_commit[:12]}"
    return {
        "schema_version": "factor-library-v1",
        "batch_key": batch_key,
        "source_repository": SOURCE_REPOSITORY,
        "source_commit": source_commit,
        "dataset_fingerprint": dataset_fingerprint,
        "methodology": {
            "evaluation_kind": "event_overlay",
            "sync_kind": "post_initial_catalog_formal_factor_archive",
            "new_research_trial_created": False,
            "factor_catalog_before_batch": 18,
            "this_batch_rejected_candidates": 4,
            "factor_catalog_after_batch": 22,
            "structured_results_policy": (
                "omitted because factor-library-v1 horizon coordinates do not faithfully represent these event-overlay "
                "portfolio metrics; exact preregistration and formal-result artifacts are attached"
            ),
            "historical_decisions": decisions,
            "g3_note": (
                "These four candidates remain in the formal trial/DSR accounting exactly as originally recorded; "
                "the catalog sync does not reopen, retune, or promote them."
            ),
        },
        "run_key": batch_key,
        "run_title": "ATM-SVP-2 后续正式失败因子补档",
        "runner_path": runner_rel,
        "runner_sha256": sha256_file(ROOT / runner_rel),
        "dataset_spec": {
            "kind": "two_followup_formal_factor_trials",
            "dataset_manifests": dataset_entries,
        },
        "summary": (
            "补齐初始18因子目录同步后完成的四条正式因子：F-BAA、F-EPU、F-MOVE、F-VRP-PROXY；"
            "全部保持 rejected 生命周期并附带原始正式证据。"
        ),
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
        check=True,
    )
    return completed.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-commit")
    args = parser.parse_args()
    manifest = build_manifest(source_commit=args.source_commit or current_head())
    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"FACTOR_LIBRARY_FOLLOWUP_REJECTED_MANIFEST_WRITTEN output={output.relative_to(ROOT)} "
        f"factors={len(manifest['factors'])} artifacts={len(manifest['artifacts'])} sha256={sha256_file(output)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
