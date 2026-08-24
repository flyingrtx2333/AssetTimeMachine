#!/usr/bin/env python3
"""Export formal ATM-SVP strategy RESULT records into strategy-library-v2 manifests.

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

STRATEGY_LIBRARY_VALIDATION_POLICY_ID = "ATM-STRATEGY-LIBRARY-VALIDATION-1"
COMPARATIVE_TOKENS = (
    "v11", "matched", "no-sma", "no_sma", "equal-eligible", "equal_eligible",
    "spy", "versus", " vs ", "candidate_minus_", "gt_v11", "ge_v11",
)


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
    if isinstance(combined, dict):
        return combined
    candidate = metrics.get("candidate")
    if isinstance(candidate, dict):
        return candidate
    return metrics


def is_strategy_trial(prereg: dict[str, Any], result: dict[str, Any]) -> bool:
    kind = str(prereg.get("candidate_kind") or "").upper()
    if kind:
        return "STRATEGY" in kind
    candidate_ids = [str(item.get("candidate_id") or "") for item in result.get("candidate_results") or []]
    if not candidate_ids:
        candidate_ids = [str(item or "") for item in prereg.get("candidate_ids") or []]
    # Older strategy preregistrations predate candidate_kind. Their immutable candidate
    # namespace is S-* (strategy) or HR-* (high-return architecture). Formal factor
    # candidates use F-* and must stay exclusively in the factor library. INVALID trials
    # may terminate before candidate_results are materialized, so fall back to prereg IDs.
    return bool(candidate_ids) and all(candidate.startswith(("S-", "HR-")) for candidate in candidate_ids)


def candidate_id_reused_in_other_result(candidate_id: str, trial_id: str) -> bool:
    for path in RESULTS_DIR.glob("ATM-SVP*-*.json"):
        if path.stem == trial_id:
            continue
        try:
            other = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for item in other.get("candidate_results") or []:
            if str(item.get("candidate_id") or "") == candidate_id:
                return True
    return False


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


def is_comparative_gate(text: str) -> bool:
    normalized = " " + str(text or "").lower().replace("_", "_") + " "
    return any(token in normalized for token in COMPARATIVE_TOKENS)


def _bool_false_checks(mapping: Any) -> tuple[list[str], list[str]]:
    intrinsic: list[str] = []
    comparative: list[str] = []
    if not isinstance(mapping, dict):
        return intrinsic, comparative
    for key, value in mapping.items():
        if value is not False:
            continue
        (comparative if is_comparative_gate(str(key)) else intrinsic).append(str(key))
    return intrinsic, comparative


def infer_total_folds(prereg: dict[str, Any], metrics: dict[str, Any], primary: dict[str, Any]) -> int | None:
    for container in (metrics, primary):
        names = container.get("fold_names") if isinstance(container, dict) else None
        if isinstance(names, list) and names:
            return len(names)
        sharpes = container.get("fold_sharpes") if isinstance(container, dict) else None
        if isinstance(sharpes, list) and sharpes:
            return len(sharpes)
    for gate in prereg.get("pass_fail_gates") or []:
        match = re.search(r"(?:at least\s+)?\d+/(\d+)\s+fixed", str(gate), flags=re.I)
        if match:
            return int(match.group(1))
    return None


def strategy_validation_assessment(
    *, prereg: dict[str, Any], result: dict[str, Any], metrics: dict[str, Any], constraints: dict[str, Any]
) -> dict[str, Any]:
    """Assess strategy validity independently from target attainment and peer ranking.

    ATM-SVP-3 RESULT records may carry an explicit three-axis interpretation produced
    after the frozen formal run (for example an absolute-gate PASS downgraded to WEAK
    by the global DSR audit). Preserve that durable interpretation instead of trying
    to infer it again from legacy single-axis fields.
    """
    explicit = metrics.get("strategy_library_validation")
    if str(prereg.get("protocol_id") or "") == "ATM-SVP-3" and isinstance(explicit, dict):
        validation_status = str(explicit.get("status") or result.get("validation_status") or "INCOMPLETE")
        objective_status = str(explicit.get("objective_status") or result.get("objective_status") or "INCONCLUSIVE")
        comparison_status = str(explicit.get("comparison_status") or result.get("comparison_status") or "NOT_APPLICABLE")
        if validation_status not in {"PASS", "WEAK", "FAIL", "INCOMPLETE"}:
            validation_status = "INCOMPLETE"
        if objective_status not in {"PASS", "FAIL", "INCONCLUSIVE", "NOT_APPLICABLE"}:
            objective_status = "INCONCLUSIVE"
        if comparison_status not in {"PASS", "FAIL", "UNKNOWN", "NOT_APPLICABLE"}:
            comparison_status = "UNKNOWN"
        durable = dict(explicit)
        durable.update({
            "policy_id": str(explicit.get("policy_id") or STRATEGY_LIBRARY_VALIDATION_POLICY_ID),
            "status": validation_status,
            "level": str(explicit.get("level") or "R1_RETROSPECTIVE"),
            "objective_status": objective_status,
            "comparison_status": comparison_status,
            "trial_status": str(result.get("status") or explicit.get("trial_status") or "INCONCLUSIVE"),
        })
        durable.setdefault("evidence_missing", [])
        durable.setdefault("validation_failures", [])
        durable.setdefault("validation_warnings", [])
        durable.setdefault("objective_failures", [])
        durable.setdefault("comparative_failures", [])
        durable.setdefault("legacy_robust_strategy_pass", bool(metrics.get("robust_strategy_pass", False)))
        durable.setdefault("note", "Validation, campaign objective attainment and peer-strategy comparison are independent axes.")
        return durable

    trial_status = str(result.get("status") or "").upper()
    if trial_status in {"INVALID", "ABORTED"} and not metrics:
        return {
            "policy_id": STRATEGY_LIBRARY_VALIDATION_POLICY_ID,
            "status": "FAIL",
            "level": str(prereg.get("evidence_class") or "R1_RETROSPECTIVE"),
            "evidence_missing": ["performance_metrics"],
            "validation_failures": [f"formal_trial_{trial_status.lower()}"],
            "validation_warnings": ["formal_trial_ended_before_candidate_metrics"],
            "objective_status": "INCONCLUSIVE",
            "objective_failures": [],
            "comparison_status": "UNKNOWN",
            "comparative_failures": [],
            "trial_status": trial_status,
            "legacy_robust_strategy_pass": False,
            "note": "The formal strategy trial ended before candidate performance metrics were recorded; preserve it as an INVALID/ABORTED research artifact rather than dropping it from the strategy library.",
        }

    primary = result_primary_metrics(metrics)
    validation_failures: list[str] = []
    validation_warnings: list[str] = []
    comparative_failures: list[str] = []
    objective_failures: list[str] = []

    failed_gates = metrics.get("failed_preregistered_gates")
    if isinstance(failed_gates, list):
        for gate in failed_gates:
            text = str(gate)
            if is_comparative_gate(text):
                comparative_failures.append(text)
            else:
                objective_failures.append(text)
    for check_key in ("admission_checks", "checks"):
        mapping = metrics.get(check_key)
        if isinstance(mapping, dict):
            for key, value in mapping.items():
                if value is False:
                    text = str(key)
                    if is_comparative_gate(text) or "improvement" in text.lower():
                        comparative_failures.append(text)
                    else:
                        objective_failures.append(text)

    evidence_missing = [
        key for key, value in {
            "artifact_manifest": result.get("artifact_manifest"),
            "preregistration_record_hash": result.get("preregistration_record_hash"),
            "run_guard_receipt": result.get("run_guard_receipt"),
            "execution_git_commit": result.get("execution_git_commit"),
        }.items() if not value
    ]

    # Common absolute retrospective floor. These are project validation floors, not
    # optimization targets: positive return/risk-adjusted return and bounded drawdown.
    primary_cagr = first_number(primary.get("cagr_percent"), primary.get("full_cagr_percent"))
    primary_sharpe = first_number(primary.get("sharpe"), primary.get("full_sharpe"))
    primary_mdd = first_number(primary.get("mdd_percent"), primary.get("full_mdd_percent"))
    if primary_cagr is None or primary_cagr <= 0:
        validation_failures.append("full_cagr_gt_0")
    if primary_sharpe is None or primary_sharpe <= 0:
        validation_failures.append("full_sharpe_gt_0")
    if primary_mdd is None or primary_mdd > 25.0:
        validation_failures.append("full_mdd_le_25pct")

    # Time stability: at least 70% of fixed folds have positive Sharpe. A positive
    # worst-fold Sharpe is stronger and also satisfies this condition.
    fold_positive = None
    fold_total = infer_total_folds(prereg, metrics, primary)
    for container in (metrics, primary):
        sharpes = container.get("fold_sharpes") if isinstance(container, dict) else None
        if isinstance(sharpes, list) and sharpes:
            fold_positive = sum(1 for value in sharpes if finite(value) is not None and float(value) > 0)
            fold_total = len(sharpes)
            break
    if fold_positive is None:
        fold_positive = metrics.get("folds_with_positive_sharpe", primary.get("folds_with_positive_sharpe"))
    worst_fold = first_number(metrics.get("worst_fold_sharpe"), primary.get("worst_fold_sharpe"))
    if worst_fold is not None and worst_fold > 0:
        fold_pass = True
    elif isinstance(fold_positive, int) and fold_total:
        fold_pass = fold_positive / fold_total >= 0.70
    else:
        fold_pass = None
    if fold_pass is False:
        validation_failures.append("positive_sharpe_folds_ge_70pct")
    elif fold_pass is None:
        validation_warnings.append("fold_robustness_evidence_unavailable")

    # Execution/cost stress is evaluated when the formal result provides it. Missing
    # stress evidence lowers confidence but does not rewrite a valid formal trial to FAIL.
    stress = metrics.get("slippage_stress") if isinstance(metrics.get("slippage_stress"), dict) else {}
    if stress:
        stress_cagr = finite(stress.get("cagr_percent"))
        stress_sharpe = finite(stress.get("sharpe"))
        stress_mdd = finite(stress.get("mdd_percent"))
        if stress_cagr is None or stress_cagr <= 0:
            validation_failures.append("stress_cagr_gt_0")
        if stress_sharpe is None or stress_sharpe <= 0:
            validation_failures.append("stress_sharpe_gt_0")
        if stress_mdd is not None and primary_mdd is not None and stress_mdd > 2.0 * primary_mdd + 1e-9:
            validation_failures.append("stress_mdd_le_2x_base")
    else:
        validation_warnings.append("execution_stress_not_in_this_trial")

    if constraints.get("pass") is False:
        validation_failures.append("portfolio_constraints_pass")
    max_gross = finite(constraints.get("max_gross"))
    if max_gross is not None and max_gross > 1.000000001:
        validation_failures.append("max_gross_le_1")
    if bool(constraints.get("financing_allowed", False)):
        validation_failures.append("financing_forbidden")
    if bool(constraints.get("shorting_allowed", False)):
        validation_failures.append("shorting_forbidden")

    trial_status = str(result.get("status") or "").upper()
    if trial_status in {"INVALID", "ABORTED"}:
        validation_failures.append(f"formal_trial_{trial_status.lower()}")

    # Multiple-testing evidence changes confidence level rather than turning an otherwise
    # sound strategy into a fake "rejected" strategy. It remains visible as WEAK.
    selection_risk_weak = metrics.get("global_dsr_pass") is False
    if selection_risk_weak:
        validation_warnings.append("global_dsr_below_project_pass_threshold")

    validation_failures = list(dict.fromkeys(validation_failures))
    validation_warnings = list(dict.fromkeys(validation_warnings))
    comparative_failures = list(dict.fromkeys(comparative_failures))
    objective_failures = list(dict.fromkeys(objective_failures))

    if evidence_missing:
        validation_status = "INCOMPLETE"
    elif validation_failures:
        validation_status = "FAIL"
    elif selection_risk_weak:
        validation_status = "WEAK"
    else:
        validation_status = "PASS"

    prereg_gates = prereg.get("pass_fail_gates") if isinstance(prereg.get("pass_fail_gates"), list) else []
    comparative_gate_count = sum(1 for gate in prereg_gates if is_comparative_gate(str(gate)))
    # Scalar comparative bootstrap/fold evidence can fail even when older result JSON did
    # not enumerate failed gates.
    has_peer_bootstrap = any(
        key in metrics for key in (
            "bootstrap_probability_cagr_gt_v11", "bootstrap_probability_sharpe_gt_v11",
            "bootstrap_probability_cagr_gt_matched", "bootstrap_probability_sharpe_gt_matched",
        )
    )
    if has_peer_bootstrap and metrics.get("bootstrap_robust_pass") is False:
        comparative_failures.append("peer_superiority_bootstrap")
    comparative_failures = list(dict.fromkeys(comparative_failures))
    if comparative_failures:
        comparison_status = "FAIL"
    elif comparative_gate_count:
        comparison_status = "PASS"
    else:
        comparison_status = "NOT_APPLICABLE"

    prereg_gate_pass = metrics.get("preregistered_gate_pass")
    objective_status = (
        "PASS" if prereg_gate_pass is True
        else "FAIL" if prereg_gate_pass is False or trial_status == "FAIL"
        else trial_status or "INCONCLUSIVE"
    )

    return {
        "policy_id": STRATEGY_LIBRARY_VALIDATION_POLICY_ID,
        "status": validation_status,
        "level": "R1_RETROSPECTIVE",
        "evidence_missing": evidence_missing,
        "validation_failures": validation_failures,
        "validation_warnings": validation_warnings,
        "objective_status": objective_status,
        "objective_failures": objective_failures,
        "comparison_status": comparison_status,
        "comparative_failures": comparative_failures,
        "trial_status": trial_status or "INCONCLUSIVE",
        "legacy_robust_strategy_pass": bool(metrics.get("robust_strategy_pass", False)),
        "note": "Validation, campaign objective attainment and peer-strategy comparison are independent axes.",
    }


def lifecycle_for_validation(validation_status: str) -> str:
    if validation_status == "PASS":
        return "validated"
    if validation_status == "WEAK":
        return "candidate"
    if validation_status == "FAIL":
        return "rejected"
    return "research"


def candidate_result_status(
    trial_status: str,
    metrics: dict[str, Any],
    robust: bool,
    *,
    protocol_id: str,
    single_candidate: bool,
) -> str:
    explicit = metrics.get("result_status")
    if explicit in {"PASS", "FAIL", "INCONCLUSIVE", "INVALID", "ABORTED", "CONTROL"}:
        return str(explicit)
    if robust:
        return "PASS"
    # ATM-SVP-3 separates the formal mechanical trial result from validation strength.
    # A one-candidate trial can mechanically PASS while its final validation evidence is
    # WEAK (for example after DSR). Do not rewrite that truthful PASS into FAIL.
    if protocol_id == "ATM-SVP-3" and single_candidate and trial_status in {
        "PASS", "FAIL", "INCONCLUSIVE", "INVALID", "ABORTED"
    }:
        return trial_status
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
    had_recorded_candidates = bool(candidates)
    if not candidates:
        prereg_ids = [str(item or "").strip() for item in prereg.get("candidate_ids") or []]
        candidates = [{"candidate_id": candidate_id, "metrics": {}} for candidate_id in prereg_ids if candidate_id]
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
        result_status = candidate_result_status(
            trial_status,
            metrics,
            robust,
            protocol_id=str(prereg.get("protocol_id") or ""),
            single_candidate=len(candidates) == 1,
        )
        max_gross, constraints = unlevered_constraints(prereg, metrics, primary)
        validation = strategy_validation_assessment(
            prereg=prereg, result=result, metrics=metrics, constraints=constraints
        )
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
        archive_key = (
            f"{candidate_id}--archive--{trial_id}"
            if not had_recorded_candidates and candidate_id_reused_in_other_result(candidate_id, trial_id)
            else candidate_id
        )
        strategies.append({
            "strategy_key": archive_key,
            "display_name": infer_display_name(candidate_id, prereg),
            "family": infer_family(trial_id, candidate_id, prereg),
            "strategy_kind": str(prereg.get("candidate_kind") or "strategy").lower(),
            "description": str(prereg.get("hypothesis") or "") or None,
            "tags": [trial_id, str(prereg.get("evidence_class") or "R1_RETROSPECTIVE")],
            "source_project": "AssetTimeMachine",
            "version": {
                "version_key": archive_key,
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
                "lifecycle_status": lifecycle_for_validation(str(validation["status"])),
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
                "metrics": {**metrics, "strategy_library_validation": validation},
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
        "schema_version": "strategy-library-v2",
        "batch_key": f"{trial_id}-strategy-library-v2",
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
    output = output_dir / f"{trial_id}-strategy-library-v2.json"
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
    paths = [ROOT / args.result] if args.result else sorted(RESULTS_DIR.glob("ATM-SVP*-*.json"))
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
