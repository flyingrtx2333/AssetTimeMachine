#!/usr/bin/env python3
"""Export every formally rejected ATM-SVP-2 factor candidate not already synced as a live research shadow."""
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
EXCLUDED_RESEARCH_CANDIDATES = {"F-BREADTH", "F-HIGHBETA", "F-CREDITCASH"}
TRIAL_RUNNERS = {
    1: "tools/orthogonal_factor_family_v1.swiftpart",
    2: "tools/orthogonal_factor_family_v2.swiftpart",
    3: "tools/orthogonal_event_factor_v3.swiftpart",
    4: "tools/orthogonal_event_factor_v4.swiftpart",
    5: "tools/orthogonal_event_budget_v5.swiftpart",
    6: "tools/final_crisis_filter_v6.swiftpart",
}
DISPLAY = {
    "F-CURVE": ("收益率曲线 T10Y3M", "yield_curve", "atm.event.curve_t10y3m"),
    "F-USD": ("美元风险状态 DXY 20观测", "currency_liquidity", "atm.event.usd_dxy_20"),
    "F-SIZE": ("大小盘广度 RUT/RUI 20观测", "market_breadth", "atm.event.size_rut_rui_20"),
    "F-FUNDING": ("短期融资压力 DCPF3M-DFF 20观测", "funding_stress", "atm.event.funding_dcpf3m_dff_20"),
    "F-COPGOLD": ("铜金比 HG/GC 20观测", "cross_asset_macro", "atm.event.copper_gold_20"),
    "F-SKEW": ("尾部风险 SKEW 20观测", "tail_risk", "atm.event.skew_20"),
    "F-CREDIT": ("信用风险偏好 HYG/LQD 20观测", "credit_risk_appetite", "atm.event.credit_hyg_lqd_20"),
    "F-CYCLICAL": ("周期消费偏好 XLY/XLP 20观测", "sector_risk_appetite", "atm.event.cyclical_xly_xlp_20"),
    "F-INDUTIL": ("工业/公用风险偏好 XLI/XLU 20观测", "sector_risk_appetite", "atm.event.indutil_xli_xlu_20"),
    "F-BANKS": ("区域银行风险偏好 KRE/SPY 20观测", "financial_risk_appetite", "atm.event.banks_kre_spy_20"),
    "F-GROWTHBOND": ("成长股/长债 QQQ/TLT 20观测", "cross_asset_risk_appetite", "atm.event.growthbond_qqq_tlt_20"),
    "F-BIOTECH": ("生物科技/医疗 XBI/XLV 20观测", "sector_risk_appetite", "atm.event.biotech_xbi_xlv_20"),
    "F-TRANSPORT": ("运输/国债 IYT/IEF 20观测", "cross_asset_macro", "atm.event.transport_iyt_ief_20"),
    "F-VIXTERM": ("波动率期限结构 VIX9D/VIX", "volatility_term_structure", "atm.event.vixterm_vix9d_vix"),
    "F-VVIX": ("波动率波动 VVIX 20观测", "volatility_of_volatility", "atm.event.vvix_20"),
}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact_spec(key: str, kind: str, path: Path, factor_key: str, version_key: str) -> dict[str, Any]:
    return {
        "artifact_key": key,
        "artifact_type": kind,
        "original_name": path.name,
        "mime_type": "application/json",
        "byte_size": path.stat().st_size,
        "sha256": sha256_file(path),
        "local_path": path.relative_to(ROOT).as_posix(),
        "factor_key": factor_key,
        "version_key": version_key,
    }


def required_inputs(source: dict[str, Any]) -> list[str]:
    field = str(source.get("price_field") or "source value")
    ids = source.get("series_ids")
    if not ids:
        one = source.get("series_id")
        ids = [one] if one else []
    return [f"{series} {field}" for series in ids]


def lookback_for(source: dict[str, Any], shared: dict[str, Any]) -> int:
    if "lookback_observations" in shared:
        return int(shared["lookback_observations"])
    if "direction_lookback_observations" in shared:
        return int(shared["direction_lookback_observations"])
    rule = str(source.get("risk_on_rule") or "")
    return 20 if re.search(r"\b20\b", rule) else 0


def version_key(candidate_id: str) -> str:
    return candidate_id.removeprefix("F-").lower().replace("_", "-") + "-v1"


def build_manifest(*, source_commit: str) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("source_commit must be a lowercase 40-character Git SHA")

    factors: list[dict[str, Any]] = []
    artifacts: list[dict[str, Any]] = []
    dataset_entries: dict[str, dict[str, str]] = {}
    decisions: dict[str, Any] = {}

    for trial_number in range(1, 7):
        trial_id = f"ATM-SVP2-ORTHO-FACTOR-00{trial_number}"
        prereg_path = ROOT / f"tools/research-results/strategy-validation/preregistrations/{trial_id}.json"
        result_path = ROOT / f"tools/research-results/strategy-validation/results/{trial_id}.json"
        dataset_path = ROOT / f"tools/research-results/strategy-validation/datasets/{trial_id}.json"
        runner_path = ROOT / TRIAL_RUNNERS[trial_number]
        prereg = json.loads(prereg_path.read_text(encoding="utf-8"))
        result = json.loads(result_path.read_text(encoding="utf-8"))
        result_by_id = {row["candidate_id"]: row for row in result.get("candidate_results", [])}
        dataset_entries[dataset_path.relative_to(ROOT).as_posix()] = {"sha256": sha256_file(dataset_path)}
        shared = dict(prereg.get("shared_rules") or {})

        for candidate_id in prereg.get("candidate_ids", []):
            if candidate_id in EXCLUDED_RESEARCH_CANDIDATES:
                continue
            if candidate_id not in DISPLAY:
                raise ValueError(f"missing catalog identity for formal candidate {candidate_id}")
            display_name, family, factor_key = DISPLAY[candidate_id]
            source = dict((prereg.get("factor_sources") or {})[candidate_id])
            vkey = version_key(candidate_id)
            candidate_result = result_by_id.get(candidate_id)
            if candidate_result is None:
                raise ValueError(f"formal result missing candidate {candidate_id} in {trial_id}")
            decisions[factor_key] = {
                "candidate_id": candidate_id,
                "trial_id": trial_id,
                "trial_status": result.get("status"),
                "candidate_result": candidate_result,
                "family_decision": result.get("decision"),
            }
            params = {"source_definition": source, "shared_rules": shared, "historical_trial_id": trial_id}
            factors.append(
                {
                    "factor_key": factor_key,
                    "display_name": display_name,
                    "family": family,
                    "description": f"ATM-SVP-2 正式历史候选 {candidate_id}；未通过冻结 gate，作为 rejected 研究证据永久保留。",
                    "tags": ["ATM-SVP-2", "formal_trial", "rejected", candidate_id.lower()],
                    "research_role": "alpha_candidate",
                    "owner_name": "AssetTimeMachine Research",
                    "source_project": "AssetTimeMachine",
                    "version": {
                        "version_key": vkey,
                        "formula_text": str(source.get("risk_on_rule") or source.get("derived_series") or candidate_id),
                        "parameters": params,
                        "required_inputs": required_inputs(source),
                        "applicable_universe": ["nfci-dual-core-v11 risk overlay research"],
                        "frequency": "daily",
                        "lookback_sessions": lookback_for(source, shared),
                        "observation_lag_sessions": 1,
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

    if len(factors) != 15:
        raise AssertionError(f"expected 15 rejected factors, got {len(factors)}")
    encoded = json.dumps(dataset_entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    dataset_fingerprint = hashlib.sha256(encoded).hexdigest()
    runner_rel = "scripts/export_factor_library_rejected_manifest.py"
    return {
        "schema_version": "factor-library-v1",
        "batch_key": f"atm-svp2-rejected-factor-sync-{source_commit[:12]}",
        "source_repository": SOURCE_REPOSITORY,
        "source_commit": source_commit,
        "dataset_fingerprint": dataset_fingerprint,
        "methodology": {
            "evaluation_kind": "event_overlay",
            "sync_kind": "complete_formal_candidate_catalog_without_survivorship_filter",
            "new_research_trial_created": False,
            "formal_candidate_count": 18,
            "already_synced_research_candidates": 3,
            "this_batch_rejected_candidates": 15,
            "structured_results_policy": "omitted because factor-library-v1 horizon coordinates do not faithfully represent event-overlay portfolio metrics; exact formal results are attached",
            "historical_decisions": decisions,
            "g3_note": "Rejected candidates remain visible and count in trial accounting; this catalog sync does not reopen or retune them.",
        },
        "run_key": f"atm-svp2-rejected-factor-sync-{source_commit[:12]}",
        "run_title": "ATM-SVP-2 正式失败因子完整归档",
        "runner_path": runner_rel,
        "runner_sha256": sha256_file(ROOT / runner_rel),
        "dataset_spec": {"kind": "six_formal_factor_families", "dataset_manifests": dataset_entries},
        "summary": "补齐 retrospective stop-rule 前全部正式因子候选；15个未通过候选以 rejected 状态永久保留，避免因子库产生幸存者偏差。",
        "factors": factors,
        "artifacts": artifacts,
        "observations": [],
    }


def current_head() -> str:
    completed = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stdout=subprocess.PIPE, check=True)
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
        f"FACTOR_LIBRARY_REJECTED_MANIFEST_WRITTEN output={output.relative_to(ROOT)} "
        f"factors={len(manifest['factors'])} artifacts={len(manifest['artifacts'])} sha256={sha256_file(output)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
