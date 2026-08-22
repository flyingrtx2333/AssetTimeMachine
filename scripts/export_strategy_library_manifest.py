#!/usr/bin/env python3
"""Export formal ATM-SVP strategy RESULT records into strategy-library-v1 manifests.

One formal trial becomes one import batch. Every candidate in that trial is retained,
including FAIL/INVALID/near-miss outcomes. Factor-only trials are skipped.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = ROOT / "tools/research-results/strategy-validation/results"
PREREG_DIR = ROOT / "tools/research-results/strategy-validation/preregistrations"
DEFAULT_OUTPUT_DIR = ROOT / "tools/research-results/strategy-library"

# A stricter later audit may invalidate the promotion interpretation of a truthful
# historical PASS. Preserve that PASS and attach the later audit instead of deleting it.
SUPERSEDED_BY: dict[str, str] = {
    "S-IWD-PROD-SP500-ROLE": "ATM-SVP2-IWD-SPY-TR-001",
}


def git_head() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "git rev-parse HEAD failed")
    return completed.stdout.strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_source_at_commit(path: Path, commit: str) -> str:
    relative = path.relative_to(ROOT).as_posix()
    completed = subprocess.run(
        ["git", "show", f"{commit}:{relative}"], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode == 0:
        return hashlib.sha256(completed.stdout).hexdigest()
    # This fallback is only for old evidence whose exact source path was not present at
    # the recorded commit. New formal research should always resolve at the execution commit.
    return sha256_file(path)


def finite(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number == number and abs(number) != float("inf") else None


def first_number(*values: Any) -> float | None:
    for value in values:
        number = finite(value)
        if number is not None:
            return number
    return None


def result_primary_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    if first_number(metrics.get("cagr_percent"), metrics.get("full_cagr_percent")) is not None:
        return metrics
    combined = metrics.get("combined")
    return combined if isinstance(combined, dict) else metrics


def is_strategy_trial(prereg: dict[str, Any], result: dict[str, Any]) -> bool:
    kind = str(prereg.get("candidate_kind") or "").upper()
    if kind:
        return "STRATEGY" in kind
    candidate_ids = [str(item.get("candidate_id") or "") for item in result.get("candidate_results") or []]
    # Older strategy preregistrations predate candidate_kind. Their immutable candidate
    # namespace is S-* (strategy) or HR-* (high-return architecture). Formal factor
    # candidates use F-* and must stay exclusively in the factor library.
    return bool(candidate_ids) and all(candidate.startswith(("S-", "HR-")) for candidate in candidate_ids)


def infer_family(trial_id: str, candidate_id: str, prereg: dict[str, Any]) -> str:
    text = " ".join((trial_id, candidate_id, str(prereg.get("protocol_component") or ""))).upper()
    if "DAYK" in text:
        return "日K高速"
    if "IWD" in text or "VALUE" in text:
        return "美股资产角色"
    if "QUAL" in text or "MTUM" in text or "MQ-ROLE" in text:
        return "美股质量动量角色"
    if "HIGHCORE" in text or "C3L3" in text:
        return "V11核心架构"
    if "HR-ARCH" in text or candidate_id.startswith("HR-"):
        return "高收益架构"
    return "策略研究"


def infer_display_name(candidate_id: str, prereg: dict[str, Any]) -> str:
    lineage = str(prereg.get("strategy_lineage") or "")
    if candidate_id.startswith("S-DAYK-HIGH-SPEED-"):
        suffix = candidate_id.rsplit("-", 1)[-1]
        return f"日K高速{suffix}"
    names = {
        "S-IWD-PROD-SP500-ROLE": "V12 / IWD 美股价值角色",
        "S-IWD-VS-SPY-TR-ROLE": "IWD vs SPY 同口径审计",
        "S-QUAL-VS-SPY-TR-ROLE": "QUAL vs SPY 同口径审计",
        "S-V11-HIGHCORE-ONLY": "V11 HighCore 高收益核心",
        "S-V11-C3L3-CORE-SWITCH": "V11 C3/L3 核心切换",
        "F-IWD-SP500-ROLE": "IWD 美股价值角色替代",
        "F-VBR-SP500-ROLE": "VBR 美股价值角色替代",
        "F-MTUM-SP500-ROLE": "MTUM 美股动量角色替代",
        "F-QUAL-SP500-ROLE": "QUAL 美股质量角色替代",
    }
    if candidate_id in names:
        return names[candidate_id]
    if lineage:
        short = lineage.split(";")[0].strip()
        if short and len(short) <= 96:
            return short
    return candidate_id


def first_existing_source(entrypoint: str) -> Path | None:
    candidates = re.findall(r"(?:scripts|tools)/[A-Za-z0-9_./-]+\.(?:py|swift|swiftpart)", entrypoint)
    # Prefer the Swift implementation over the Python launcher for code identity.
    ordered = sorted(candidates, key=lambda value: (0 if value.endswith((".swift", ".swiftpart")) else 1, value))
    for raw in ordered:
        path = ROOT / raw
        if path.is_file():
            return path
    return None


def infer_assets(prereg: dict[str, Any], metrics: dict[str, Any]) -> list[str]:
    shared = prereg.get("shared_rules") if isinstance(prereg.get("shared_rules"), dict) else {}
    raw = shared.get("assets") or shared.get("symbols")
    if isinstance(raw, list):
        return [str(item) for item in raw]
    asset_paths = metrics.get("asset_paths")
    if isinstance(asset_paths, dict):
        return [str(key) for key in asset_paths]
    return []


def infer_fold_count(metrics: dict[str, Any], primary: dict[str, Any]) -> tuple[int | None, int | None]:
    won = None
    for key in (
        "folds_sharpe_ge_v11", "folds_sharpe_ge_matched", "folds_sharpe_gt1", "folds_with_positive_sharpe"
    ):
        value = metrics.get(key, primary.get(key))
        if isinstance(value, int):
            won = value
            break
    names = metrics.get("fold_names") or primary.get("fold_names")
    total = len(names) if isinstance(names, list) else None
    return won, total


def probability(metrics: dict[str, Any], primary: dict[str, Any], kind: str) -> float | None:
    keys = (
        ("bootstrap_probability_cagr_gt_v11", "bootstrap_probability_cagr_gt_matched", "probability_cagr_gt_v11", "probability_cagr_gt_matched")
        if kind == "cagr"
        else ("bootstrap_probability_sharpe_gt_v11", "bootstrap_probability_sharpe_gt_matched", "probability_sharpe_gt_v11", "probability_sharpe_gt_matched_control")
    )
    bootstrap = metrics.get("bootstrap") if isinstance(metrics.get("bootstrap"), dict) else {}
    if "bootstrap" in bootstrap and isinstance(bootstrap["bootstrap"], dict):
        bootstrap = bootstrap["bootstrap"]
    for container in (metrics, primary, bootstrap):
        for key in keys:
            number = finite(container.get(key)) if isinstance(container, dict) else None
            if number is not None:
                return number
    return None


def lifecycle_for(result_status: str, robust: bool, superseded: str | None) -> str:
    if superseded:
        return "suspended"
    if robust:
        return "validated"
    if result_status == "PASS":
        return "candidate"
    return "rejected"


def candidate_result_status(trial_status: str, metrics: dict[str, Any], robust: bool) -> str:
    if robust:
        return "PASS"
    explicit = metrics.get("result_status")
    if explicit in {"PASS", "FAIL", "INCONCLUSIVE", "INVALID", "ABORTED", "CONTROL"}:
        return str(explicit)
    if trial_status in {"INVALID", "ABORTED", "INCONCLUSIVE"}:
        return trial_status
    return "FAIL"


def unlevered_constraints(prereg: dict[str, Any], metrics: dict[str, Any], primary: dict[str, Any]) -> tuple[float, dict[str, Any]]:
    shared = prereg.get("shared_rules") if isinstance(prereg.get("shared_rules"), dict) else {}
    candidate_def = prereg.get("candidate_definition") if isinstance(prereg.get("candidate_definition"), dict) else {}
    constraints = metrics.get("constraints") if isinstance(metrics.get("constraints"), dict) else {}
    max_gross = first_number(
        metrics.get("max_gross"), primary.get("max_gross"), constraints.get("max_gross"),
        shared.get("max_gross"), candidate_def.get("max_gross"), 1.0,
    )
    if max_gross is None:
        max_gross = 1.0
    financing = bool(shared.get("financing_allowed", False))
    shorting = bool(shared.get("shorting_allowed", False))
    leverage = bool(shared.get("leverage_allowed", False)) or max_gross > 1.000000001
    if financing or shorting or leverage:
        raise ValueError(
            f"strategy violates no-leverage policy: max_gross={max_gross} financing={financing} shorting={shorting}"
        )
    merged = {
        "max_gross": max_gross,
        "financing_allowed": financing,
        "shorting_allowed": shorting,
        "leverage_allowed": leverage,
        **constraints,
    }
    return min(max_gross, 1.0), merged


def export_one(result_path: Path, output_dir: Path) -> Path | None:
    result = json.loads(result_path.read_text(encoding="utf-8"))
    trial_id = str(result.get("trial_id") or result_path.stem)
    prereg_path = PREREG_DIR / f"{trial_id}.json"
    if not prereg_path.is_file():
        return None
    prereg = json.loads(prereg_path.read_text(encoding="utf-8"))
    if not is_strategy_trial(prereg, result):
        return None
    candidates = result.get("candidate_results") or []
    if not candidates:
        return None

    source_commit = str(result.get("execution_git_commit") or git_head())
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        source_commit = git_head()
    entrypoint = str(prereg.get("swift_engine_entrypoint") or "")
    source = first_existing_source(entrypoint)
    code_sha = sha256_source_at_commit(source, source_commit) if source else None
    trial_status = str(result.get("status") or "INCONCLUSIVE")
    strategies: list[dict[str, Any]] = []

    for candidate in candidates:
        candidate_id = str(candidate.get("candidate_id") or "").strip()
        if not candidate_id:
            continue
        metrics = candidate.get("metrics") if isinstance(candidate.get("metrics"), dict) else {}
        primary = result_primary_metrics(metrics)
        robust = bool(metrics.get("robust_strategy_pass", candidate.get("robust_strategy_pass", False)))
        superseded = SUPERSEDED_BY.get(candidate_id)
        result_status = candidate_result_status(trial_status, metrics, robust)
        max_gross, constraints = unlevered_constraints(prereg, metrics, primary)
        folds_won, folds_total = infer_fold_count(metrics, primary)
        bootstrap_block = metrics.get("bootstrap") if isinstance(metrics.get("bootstrap"), dict) else {}
        gates = (
            metrics.get("admission_checks") if isinstance(metrics.get("admission_checks"), dict)
            else metrics.get("checks") if isinstance(metrics.get("checks"), dict)
            else {}
        )
        fold_payload = {
            "names": metrics.get("fold_names", primary.get("fold_names")),
            "sharpes": metrics.get("fold_sharpes", primary.get("fold_sharpes")),
            "cagrs_percent": metrics.get("fold_cagrs_percent", primary.get("fold_cagrs_percent")),
            "mdds_percent": metrics.get("fold_mdds_percent", primary.get("fold_mdds_percent")),
        }
        fold_payload = {key: value for key, value in fold_payload.items() if value is not None}
        dsr = first_number(
            metrics.get("global_post_protocol_dsr_probability"),
            metrics.get("dsr_probability"),
            candidate.get("global_post_protocol_dsr_probability"),
        )
        target_fp = (
            metrics.get("target_fingerprint") or metrics.get("fingerprint")
            or metrics.get("execution_event_target_fingerprint")
        )
        strategies.append({
            "strategy_key": candidate_id,
            "display_name": infer_display_name(candidate_id, prereg),
            "family": infer_family(trial_id, candidate_id, prereg),
            "strategy_kind": str(prereg.get("candidate_kind") or "strategy").lower(),
            "description": str(prereg.get("hypothesis") or "") or None,
            "tags": [trial_id, str(prereg.get("evidence_class") or "R1_RETROSPECTIVE")],
            "source_project": "AssetTimeMachine",
            "version": {
                "version_key": candidate_id,
                "mechanism_text": str(prereg.get("hypothesis") or prereg.get("selection_metric") or candidate_id),
                "parameters": {
                    "candidate_definition": prereg.get("candidate_definition"),
                    "shared_rules": prereg.get("shared_rules"),
                    "allowed_changes": prereg.get("allowed_changes"),
                    "forbidden_changes": prereg.get("forbidden_changes"),
                },
                "assets": infer_assets(prereg, metrics),
                "source_path": source.relative_to(ROOT).as_posix() if source else entrypoint[:768] or None,
                "code_sha256": code_sha,
                "target_fingerprint": str(target_fp) if target_fp is not None else None,
                "lifecycle_status": lifecycle_for(result_status, robust, superseded),
                "max_gross_limit": max_gross,
                "leverage_allowed": False,
                "shorting_allowed": False,
                "financing_allowed": False,
            },
            "result": {
                "candidate_id": candidate_id,
                "result_status": result_status,
                "robust_strategy_pass": robust,
                "superseded_by": superseded,
                "cagr_percent": first_number(primary.get("cagr_percent"), primary.get("full_cagr_percent")),
                "sharpe": first_number(primary.get("sharpe"), primary.get("full_sharpe")),
                "mdd_percent": first_number(primary.get("mdd_percent"), primary.get("full_mdd_percent")),
                "since2020_cagr_percent": first_number(metrics.get("since2020_cagr_percent"), primary.get("since2020_cagr_percent")),
                "since2022_cagr_percent": first_number(metrics.get("since2022_cagr_percent"), primary.get("since2022_cagr_percent")),
                "max_gross": max_gross,
                "folds_won": folds_won,
                "folds_total": folds_total,
                "bootstrap_probability_cagr": probability(metrics, primary, "cagr"),
                "bootstrap_probability_sharpe": probability(metrics, primary, "sharpe"),
                "dsr_probability": dsr,
                "metrics": metrics,
                "gates": gates,
                "bootstrap": bootstrap_block,
                "folds": fold_payload,
                "constraints": constraints,
                "artifacts": [{"path": str(path)} for path in result.get("artifacts") or []],
                "conclusion": str(result.get("decision") or "") or None,
            },
        })

    if not strategies:
        return None
    prereg_hash = result.get("preregistration_record_hash")
    manifest = {
        "schema_version": "strategy-library-v1",
        "batch_key": f"{trial_id}-strategy-library-v1",
        "source_repository": "AssetTimeMachine",
        "source_commit": source_commit,
        "run": {
            "run_key": trial_id,
            "title": str(prereg.get("protocol_component") or prereg.get("strategy_lineage") or trial_id)[:255],
            "protocol_id": str(prereg.get("protocol_id") or "ATM-SVP-2"),
            "evidence_class": str(prereg.get("evidence_class") or "R1_RETROSPECTIVE"),
            "dataset_manifest": result.get("dataset_manifest"),
            "artifact_manifest": result.get("artifact_manifest"),
            "preregistration_hash": prereg_hash if isinstance(prereg_hash, str) and len(prereg_hash) == 64 else None,
            "execution_commit": source_commit,
            "status": trial_status if trial_status in {"PASS", "FAIL", "INCONCLUSIVE", "INVALID", "ABORTED", "CONTROL"} else "INCONCLUSIVE",
            "decision": result.get("decision"),
            "methodology": {
                "selection_metric": prereg.get("selection_metric"),
                "pass_fail_gates": prereg.get("pass_fail_gates"),
                "formal_run_budget": prereg.get("formal_run_budget"),
                "follow_up_policy": prereg.get("follow_up_policy"),
            },
        },
        "strategies": strategies,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{trial_id}-strategy-library-v1.json"
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", help="one formal RESULT JSON")
    parser.add_argument("--all", action="store_true", help="export every recorded strategy trial")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR.relative_to(ROOT)))
    args = parser.parse_args()
    if bool(args.result) == bool(args.all):
        raise SystemExit("choose exactly one of --result or --all")
    output_dir = ROOT / args.output_dir
    paths = [ROOT / args.result] if args.result else sorted(RESULTS_DIR.glob("ATM-SVP2-*.json"))
    exported: list[Path] = []
    skipped: list[str] = []
    for path in paths:
        output = export_one(path, output_dir)
        if output is None:
            skipped.append(path.name)
        else:
            exported.append(output)
            print(f"STRATEGY_LIBRARY_MANIFEST_WRITTEN {output.relative_to(ROOT)}")
    print(f"STRATEGY_LIBRARY_EXPORT_COMPLETE exported={len(exported)} skipped={len(skipped)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
