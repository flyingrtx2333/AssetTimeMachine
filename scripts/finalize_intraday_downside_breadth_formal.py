#!/usr/bin/env python3
"""Finalize the single IDB formal launch into immutable governance artifacts and RESULT."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publish_strategy_library_manifest import validate_local_manifest
from strategy_validation_ledger import append_record

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_SCRIPT = Path(__file__).resolve().parent / "validate_strategy_protocol.py"
LEDGER_SCRIPT = Path(__file__).resolve().parent / "strategy_validation_ledger.py"
BASE = ROOT / "tools/research-results/strategy-validation"
TRIAL_ID = "ATM-SVP2-IDB-63-21-001"
CANDIDATE_ID = "IDB-63-21"
RUN_DIR = BASE / "runs" / TRIAL_ID
RESULT_PATH = BASE / "results" / f"{TRIAL_ID}.json"
DATASET_PATH = BASE / "datasets" / f"{TRIAL_ID}.json"
PREREG_PATH = BASE / "preregistrations" / f"{TRIAL_ID}.json"
LEDGER_PATH = BASE / "trial-ledger.jsonl"
ARTIFACT_PATH = RUN_DIR / "artifact-manifest.json"
LIBRARY_PATH = RUN_DIR / "strategy-library-import-v2.json"


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"expected JSON object: {path}")
    return value


def write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()
    if path.exists():
        if path.read_bytes() != data:
            raise SystemExit(f"refusing to overwrite non-identical formal artifact: {path}")
        return
    path.write_bytes(data)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def committed_blob_sha(commit: str, relative_path: str) -> str:
    result = subprocess.run(
        ["git", "show", f"{commit}:{relative_path}"], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise SystemExit(f"cannot read committed source blob: {relative_path}")
    return hashlib.sha256(result.stdout).hexdigest()


def relative(path: Path) -> str:
    return str(path.relative_to(ROOT))


def file_entry(path: Path) -> dict[str, Any]:
    return {
        "path": relative(path),
        "sha256": sha(path),
        "bytes": path.stat().st_size,
        "format": path.suffix.removeprefix(".") or "binary",
    }


def artifact_files() -> list[Path]:
    excluded = {ARTIFACT_PATH.name}
    return sorted(
        (path for path in RUN_DIR.iterdir() if path.is_file() and path.name not in excluded),
        key=lambda path: path.name,
    )


def validate_identity(execution: dict[str, Any], prereg: dict[str, Any]) -> None:
    if execution.get("trial_id") != TRIAL_ID or prereg.get("trial_id") != TRIAL_ID:
        raise SystemExit("formal finalizer trial identity mismatch")
    ledger_prereg = None
    run_started = None
    for line in LEDGER_PATH.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        payload = record.get("payload") or {}
        if record.get("event") == "PREREGISTER" and payload.get("trial_id") == TRIAL_ID:
            if ledger_prereg is not None:
                raise SystemExit("duplicate formal preregistration ledger event")
            ledger_prereg = record
        if record.get("event") == "RUN_STARTED" and payload.get("trial_id") == TRIAL_ID:
            if run_started is not None:
                raise SystemExit("duplicate formal RUN_STARTED ledger event")
            run_started = record
        if record.get("event") == "RESULT" and payload.get("trial_id") == TRIAL_ID:
            raise SystemExit("formal RESULT ledger event already exists")
    if ledger_prereg is None or ledger_prereg.get("payload") != prereg:
        raise SystemExit("formal finalizer preregistration ledger payload mismatch")
    if run_started is None:
        raise SystemExit("formal finalizer durable RUN_STARTED missing")
    if load(RUN_DIR / "run-budget-reservation.json") != run_started:
        raise SystemExit("formal finalizer archived RUN_STARTED differs from ledger")
    if execution.get("preregistration_record_hash") != ledger_prereg.get("record_hash"):
        raise SystemExit("formal finalizer preregistration hash mismatch")
    if execution.get("run_budget_record_hash") != run_started.get("record_hash"):
        raise SystemExit("formal finalizer RUN_STARTED hash mismatch")
    receipt_value = str(execution.get("run_guard_receipt", ""))
    expected_receipt = relative(RUN_DIR / "run-authorization.json")
    if receipt_value != expected_receipt:
        raise SystemExit("formal finalizer receipt path is not the exact standard wrapper receipt")
    receipt_path = ROOT / receipt_value
    if not receipt_path.is_file():
        raise SystemExit("formal finalizer receipt missing")
    receipt = load(receipt_path)
    expected_receipt_fields = {
        "protocol_id": "ATM-SVP-2", "trial_id": TRIAL_ID,
        "preregistration_record_hash": ledger_prereg["record_hash"],
        "run_budget_record_hash": run_started["record_hash"],
        "execution_git_commit": execution["execution_git_commit"],
        "formal_run_budget": 1, "candidate_count": 1,
    }
    if any(receipt.get(key) != value for key, value in expected_receipt_fields.items()):
        raise SystemExit("formal finalizer standard receipt identity mismatch")
    if execution.get("return_code") is None:
        raise SystemExit("formal execution return code missing")


def successful_payload(metrics: dict[str, Any]) -> tuple[str, list[dict[str, Any]], str]:
    decision = metrics.get("decision")
    if decision not in {"PASS", "FAIL"}:
        raise SystemExit("successful formal process has unsupported decision")
    if metrics.get("trial_id") != TRIAL_ID or metrics.get("candidate_id") != CANDIDATE_ID:
        raise SystemExit("formal metrics identity mismatch")
    required = {"candidate", "natural", "placebo", "factor_mechanism", "checks", "schedule_fingerprints"}
    if not required.issubset(metrics):
        raise SystemExit("formal metrics evidence incomplete")
    expected_windows = {"full", "since_2016_08_31", "since_2020_01_01", "since_2022_01_01"}
    for name in ["candidate", "natural", "placebo"]:
        windows = metrics.get(name)
        if not isinstance(windows, dict) or set(windows) != expected_windows:
            raise SystemExit(f"formal {name} windows incomplete")
        for window in windows.values():
            if not isinstance(window, dict) or set(window) != {"cagr", "sharpe", "mdd"}:
                raise SystemExit(f"formal {name} window malformed")
            if any(not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) for value in window.values()):
                raise SystemExit(f"formal {name} metrics must be finite")
    if not isinstance(metrics["factor_mechanism"], dict) or not isinstance(metrics["checks"], dict):
        raise SystemExit("formal factor/check evidence malformed")
    candidate_result = {
        "candidate_id": CANDIDATE_ID,
        "metrics": {
            "candidate": metrics["candidate"],
            "natural_control": metrics["natural"],
            "placebo_control": metrics["placebo"],
            "factor_mechanism": metrics["factor_mechanism"],
            "checks": metrics["checks"],
            "schedule_fingerprints": metrics["schedule_fingerprints"],
        },
    }
    text = (
        f"{decision}: all preregistered four-window IDB gates were evaluated exactly once; "
        "the intraday-downside-breadth-63-21-v1 lineage is permanently closed with no rescue run."
    )
    return decision, [candidate_result], text


def invalid_payload(return_code: int) -> tuple[str, list[dict[str, Any]], str]:
    return (
        "INVALID",
        [],
        f"INVALID / PERMANENTLY CLOSED: the one-shot formal launch returned code {return_code} "
        "without a complete validated performance artifact; no retry or parameter rescue is permitted.",
    )


def strategy_library(
    status: str,
    decision: str,
    execution: dict[str, Any],
    prereg: dict[str, Any],
    metrics: dict[str, Any] | None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "candidate_id": CANDIDATE_ID,
        "result_status": status,
        "robust_strategy_pass": status == "PASS",
        "metrics": {
            "strategy_library_validation": {
                "status": status,
                "basis": "formal exact four-window App-cost gates" if metrics else "formal launch produced no complete metrics",
            }
        },
        "gates": metrics.get("checks", {}) if metrics else {},
        "constraints": {
            "max_gross_limit": 1.0,
            "leverage_allowed": False,
            "shorting_allowed": False,
            "financing_allowed": False,
        },
        "artifacts": [
            {"path": relative(RESULT_PATH)},
            {"path": relative(ARTIFACT_PATH)},
            {"path": relative(LEDGER_PATH)},
        ],
        "conclusion": decision,
    }
    if metrics:
        full = metrics["candidate"]["full"]
        result.update({
            "cagr_percent": full["cagr"] * 100 if full["cagr"] is not None else None,
            "sharpe": full["sharpe"],
            "mdd_percent": full["mdd"] * 100 if full["mdd"] is not None else None,
            "since2020_cagr_percent": metrics["candidate"]["since_2020_01_01"]["cagr"] * 100,
            "since2022_cagr_percent": metrics["candidate"]["since_2022_01_01"]["cagr"] * 100,
        })
        result["metrics"].update({
            "windows": metrics["candidate"],
            "natural_control_windows": metrics["natural"],
            "placebo_control_windows": metrics["placebo"],
            "factor_mechanism": metrics["factor_mechanism"],
        })
    return {
        "schema_version": "strategy-library-v2",
        "batch_key": f"{TRIAL_ID}-strategy-library-v2",
        "source_repository": "AssetTimeMachine",
        "source_commit": execution["execution_git_commit"],
        "run": {
            "run_key": TRIAL_ID,
            "title": "IDB 日内下跌广度黄金轮动正式验证",
            "protocol_id": "ATM-SVP-2",
            "evidence_class": prereg["evidence_class"],
            "dataset_manifest": relative(DATASET_PATH),
            "artifact_manifest": relative(ARTIFACT_PATH),
            "preregistration_hash": execution["preregistration_record_hash"],
            "execution_commit": execution["execution_git_commit"],
            "status": status,
            "decision": decision,
            "methodology": {
                "metric_display_basis": "fixed CNY 100000, fee 0.01, slippage 0.0005, zero financing",
                "formal_result_source": "hash-chained trial-ledger RESULT and committed candidate-metrics.json",
                "no_parameter_rescue": True,
                "permanent_no_retry": True,
            },
            "started_at": execution["started_at"],
            "finished_at": execution["finished_at"],
        },
        "strategies": [{
            "strategy_key": CANDIDATE_ID,
            "display_name": "IDB 日内下跌广度 63/21",
            "family": "intraday-downside-breadth",
            "strategy_kind": "allocation",
            "description": "以纳指与标普收盘相对开盘的有符号日内方向衡量下跌广度，在黄金与股票指数间轮动。",
            "tags": ["formal", status.lower(), "permanently-closed", "ohlc", "return-blind"],
            "source_project": "AssetTimeMachine",
            "version": {
                "version_key": "intraday-downside-breadth-63-21-v1",
                "mechanism_text": "两个指数各取63个共同OHLC观察的log(C/O)均值，每21个共同观察复核；收盘后入队，下一可执行session起生效。",
                "parameters": {"lookback": 63, "review_step": 21, "threshold": 0},
                "assets": ["gold_cny", "nasdaq", "sp500"],
                "source_path": "AssetTimeMachine/Backtest/IntradayDownsideBreadthStrategy.swift",
                "code_sha256": committed_blob_sha(
                    execution["execution_git_commit"],
                    "AssetTimeMachine/Backtest/IntradayDownsideBreadthStrategy.swift",
                ),
                "target_fingerprint": prereg["frozen_schedule"]["fingerprints"]["full"],
                "lifecycle_status": "accepted" if status == "PASS" else "rejected",
                "max_gross_limit": 1.0,
                "leverage_allowed": False,
                "shorting_allowed": False,
                "financing_allowed": False,
            },
            "result": result,
        }],
    }


def validate_strategy_library() -> None:
    manifest = load(LIBRARY_PATH)
    try:
        validate_local_manifest(manifest)
    except (TypeError, ValueError) as error:
        raise SystemExit(f"strategy-library manifest invalid: {error}") from error
    strategies = manifest.get("strategies")
    if not isinstance(strategies, list) or len(strategies) != 1:
        raise SystemExit("strategy-library manifest must contain exactly one strategy")
    strategy = strategies[0]
    if not isinstance(strategy, dict) or strategy.get("strategy_key") != CANDIDATE_ID:
        raise SystemExit("strategy-library candidate identity mismatch")
    version = strategy.get("version")
    result = strategy.get("result")
    if not isinstance(version, dict) or version.get("version_key") != "intraday-downside-breadth-63-21-v1":
        raise SystemExit("strategy-library version identity mismatch")
    if not isinstance(result, dict) or result.get("candidate_id") != CANDIDATE_ID:
        raise SystemExit("strategy-library result identity mismatch")
    run = manifest.get("run")
    if not isinstance(run, dict) or run.get("run_key") != TRIAL_ID or result.get("result_status") != run.get("status"):
        raise SystemExit("strategy-library run/result status mismatch")


def validate_trial_evidence(ledger_path: Path) -> None:
    validation = subprocess.run([
        sys.executable, str(VALIDATOR_SCRIPT),
        "--ledger", str(ledger_path), "--trial-id", TRIAL_ID,
        "--result-evidence-only",
    ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if validation.returncode:
        raise SystemExit(f"authoritative result-evidence validation failed:\n{validation.stdout[-8_000:]}")


def validate_before_append(result_payload: dict[str, Any]) -> None:
    validate_strategy_library()
    with tempfile.NamedTemporaryFile(prefix="idb-prospective-ledger-", suffix=".jsonl", delete=False) as handle:
        temporary_ledger = Path(handle.name)
        handle.write(LEDGER_PATH.read_bytes())
    try:
        append_record(temporary_ledger, "RESULT", result_payload, None)
        validate_trial_evidence(temporary_ledger)
    finally:
        temporary_ledger.unlink(missing_ok=True)


def existing_result_payload() -> dict[str, Any] | None:
    if not LEDGER_PATH.is_file():
        return None
    match = None
    for line in LEDGER_PATH.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        payload = record.get("payload") or {}
        if record.get("event") == "RESULT" and payload.get("trial_id") == TRIAL_ID:
            if match is not None:
                raise SystemExit("duplicate formal RESULT ledger event")
            match = payload
    return match


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output = Path(args.output_dir).resolve()
    if output != RUN_DIR.resolve():
        raise SystemExit("finalizer output directory is not the fixed trial directory")
    existing = existing_result_payload()
    if existing is not None:
        if not RESULT_PATH.is_file() or load(RESULT_PATH) != existing:
            raise SystemExit("existing formal RESULT differs from immutable result artifact")
        validate_strategy_library()
        validate_trial_evidence(LEDGER_PATH)
        print(f"IDB_FORMAL_ALREADY_FINALIZED status={existing['status']} result={relative(RESULT_PATH)}")
        return 0

    execution_path = RUN_DIR / "execution.json"
    if not execution_path.is_file() or not (RUN_DIR / "run-budget-reservation.json").is_file():
        raise SystemExit("formal budget was not durably reserved; refusing RESULT finalization")
    execution = load(execution_path)
    prereg = load(PREREG_PATH)
    validate_identity(execution, prereg)
    return_code = int(execution["return_code"])
    metrics_path = RUN_DIR / "candidate-metrics.json"
    raw_metrics: dict[str, Any] | None = None
    malformed_reason: str | None = None
    if return_code == 0 and metrics_path.is_file():
        try:
            raw_metrics = load(metrics_path)
        except (OSError, ValueError, json.JSONDecodeError, SystemExit) as error:
            malformed_reason = str(error)
    performance_metrics: dict[str, Any] | None = None
    if raw_metrics and raw_metrics.get("decision") in {"PASS", "FAIL"}:
        try:
            status, candidate_results, decision = successful_payload(raw_metrics)
            performance_metrics = raw_metrics
        except (KeyError, TypeError, ValueError, SystemExit) as error:
            malformed_reason = str(error)
            raw_metrics = None
            status, candidate_results, decision = invalid_payload(return_code)
    elif raw_metrics and raw_metrics.get("decision") == "INVALID":
        valid_factor_only = (
            raw_metrics.get("trial_id") == TRIAL_ID
            and raw_metrics.get("candidate_id") == CANDIDATE_ID
            and isinstance(raw_metrics.get("factor_mechanism"), dict)
            and raw_metrics.get("candidate") == {}
            and raw_metrics.get("natural") == {}
            and raw_metrics.get("placebo") == {}
        )
        if valid_factor_only:
            status, candidate_results = "INVALID", []
            decision = (
                "INVALID / PERMANENTLY CLOSED: preregistered factor evidence was insufficient before "
                "portfolio metrics; no retry or parameter rescue is permitted."
            )
        else:
            malformed_reason = "factor-insufficient output structure malformed"
            raw_metrics = None
            status, candidate_results, decision = invalid_payload(return_code)
    else:
        if raw_metrics is not None:
            malformed_reason = "unsupported formal decision"
            raw_metrics = None
        status, candidate_results, decision = invalid_payload(return_code)

    factor_path = RUN_DIR / "factor-evidence.json"
    if raw_metrics:
        factor_payload: dict[str, Any] = {
            "protocol_id": "ATM-SVP-2", "trial_id": TRIAL_ID,
            "candidate_id": CANDIDATE_ID, "status": "PRODUCED",
            "evidence_role": "preregistered_falsification_control_not_factor_candidate",
            "factor_library_required": False,
            "factor_mechanism": raw_metrics["factor_mechanism"],
        }
    else:
        factor_payload = {
            "protocol_id": "ATM-SVP-2", "trial_id": TRIAL_ID,
            "candidate_id": CANDIDATE_ID, "status": "NOT_PRODUCED",
            "evidence_role": "preregistered_falsification_control_not_factor_candidate",
            "factor_library_required": False,
            "factor_mechanism": None,
            "reason": malformed_reason or f"formal launch returned code {return_code} without complete validated metrics",
        }
    write(factor_path, factor_payload)
    write(LIBRARY_PATH, strategy_library(status, decision, execution, prereg, performance_metrics))
    manifest = {
        "files": [file_entry(path) for path in artifact_files()],
        "generated_at": execution["finished_at"],
        "git_commit": execution["execution_git_commit"],
        "kind": "result",
        "metadata": {"status": status, "permanent_no_retry": True},
        "protocol_id": "ATM-SVP-2",
        "trial_id": TRIAL_ID,
    }
    write(ARTIFACT_PATH, manifest)
    result_payload = {
        "trial_id": TRIAL_ID,
        "preregistration_record_hash": execution["preregistration_record_hash"],
        "run_budget_record_hash": execution["run_budget_record_hash"],
        "execution_git_commit": execution["execution_git_commit"],
        "run_guard_receipt": execution["run_guard_receipt"],
        "dataset_manifest": relative(DATASET_PATH),
        "artifact_manifest": relative(ARTIFACT_PATH),
        "status": status,
        "candidate_results": candidate_results,
        "decision": decision,
        "artifacts": [entry["path"] for entry in manifest["files"]],
    }
    write(RESULT_PATH, result_payload)
    validate_before_append(result_payload)
    subprocess.run([
        sys.executable, str(LEDGER_SCRIPT),
        "--ledger", str(LEDGER_PATH), "append", "--event", "RESULT",
        "--payload-file", str(RESULT_PATH),
    ], cwd=ROOT, check=True)
    print(f"IDB_FORMAL_FINALIZED status={status} result={relative(RESULT_PATH)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
