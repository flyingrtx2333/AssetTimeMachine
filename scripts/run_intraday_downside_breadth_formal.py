#!/usr/bin/env python3
"""Compile or execute the single guarded IDB-63-21 formal run."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from strategy_validation_ledger import append_record, read_records, verify_records

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-IDB-63-21-001"
AUTHORITY_REMOTE = "origin"
AUTHORITY_BRANCH = "main"
AUTHORITY_TAG = "atm-run-budget/ATM-SVP2-IDB-63-21-001"
AUTHORITY_REF = f"refs/tags/{AUTHORITY_TAG}"
CANDIDATE_ID = "IDB-63-21"
BASE = ROOT / "tools/research-results/strategy-validation"
PREREG = BASE / "preregistrations" / f"{TRIAL_ID}.json"
SCHEDULE = BASE / "preregistrations/IDB-63-21-schedule.json"
DATASET = BASE / "datasets" / f"{TRIAL_ID}.json"
LEDGER = BASE / "trial-ledger.jsonl"
OUTPUT = BASE / "runs" / TRIAL_ID
BINARY = ROOT / ".build/release/IntradayDownsideBreadthFormal"
ALLOWED_POST_IMPLEMENTATION = {
    str(PREREG.relative_to(ROOT)),
    str(SCHEDULE.relative_to(ROOT)),
    str(DATASET.relative_to(ROOT)),
    str(LEDGER.relative_to(ROOT)),
}
FORMAL_RUNTIME = {
    "swift_version": "swift-driver version: 1.127.15 Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)",
    "target": "arm64-apple-macosx26.0",
    "os_product": "macOS",
    "os_version": "26.5.2",
    "os_build": "25F84",
}


def run(command: list[str], timeout: int = 600, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=timeout,
    )
    if check and result.returncode:
        sys.stderr.write(result.stdout[-20_000:])
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}")
    return result


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def trial_records() -> tuple[dict, dict | None, dict | None]:
    records = read_records(LEDGER)
    verify_records(records)
    prereg = next(
        (record for record in records if record.get("event") == "PREREGISTER" and (record.get("payload") or {}).get("trial_id") == TRIAL_ID),
        None,
    )
    if prereg is None:
        raise SystemExit("formal preregistration ledger record missing")
    started = [record for record in records if record.get("event") == "RUN_STARTED" and (record.get("payload") or {}).get("trial_id") == TRIAL_ID]
    results = [record for record in records if record.get("event") == "RESULT" and (record.get("payload") or {}).get("trial_id") == TRIAL_ID]
    if len(started) > 1 or len(results) > 1:
        raise SystemExit("duplicate formal lifecycle ledger event")
    return prereg, started[0] if started else None, results[0] if results else None


def reserve_budget(output: Path) -> tuple[dict, bool]:
    prereg_record, started, result = trial_records()
    if result is not None:
        raise SystemExit("formal RESULT already exists")
    if started is not None:
        committed_ledger = git("show", f"HEAD:{LEDGER.relative_to(ROOT)}")
        if started["record_hash"] not in committed_ledger:
            status = git("status", "--porcelain").splitlines()
            expected = {f" M {LEDGER.relative_to(ROOT)}", f"M  {LEDGER.relative_to(ROOT)}"}
            if len(status) != 1 or status[0] not in expected:
                raise SystemExit("uncommitted RUN_STARTED recovery found unrelated worktree changes")
            git("add", str(LEDGER.relative_to(ROOT)))
            git("commit", "-m", f"research: reserve formal budget for {TRIAL_ID}")
        verify_remote_reservation(started, push=True)
        return started, False
    if git("status", "--porcelain"):
        raise SystemExit("durable one-shot reservation requires a clean worktree")
    prereg = prereg_record["payload"]
    if prereg.get("requires_durable_run_reservation") is not True:
        raise SystemExit("preregistration does not require durable one-shot reservation")
    if prereg.get("run_budget_authority") != {
        "kind": "git-remote-immutable-tag-cas", "remote": AUTHORITY_REMOTE,
        "base_branch": AUTHORITY_BRANCH, "ref": AUTHORITY_REF,
    }:
        raise SystemExit("preregistration run-budget authority mismatch")
    run(["git", "fetch", AUTHORITY_REMOTE, AUTHORITY_BRANCH])
    authority_base = git("rev-parse", f"refs/remotes/{AUTHORITY_REMOTE}/{AUTHORITY_BRANCH}")
    nonce = secrets.token_bytes(32)
    payload = {
        "trial_id": TRIAL_ID,
        "protocol_id": "ATM-SVP-2",
        "preregistration_record_hash": prereg_record["record_hash"],
        "implementation_commit": prereg["implementation_commit"],
        "formal_run_budget": 1,
        "output_directory": str(output.relative_to(ROOT)),
        "nonce_sha256": hashlib.sha256(nonce).hexdigest(),
        "permanent": True,
        "authority_remote": AUTHORITY_REMOTE,
        "authority_ref": AUTHORITY_REF,
        "authority_base_commit": authority_base,
    }
    record = append_record(LEDGER, "RUN_STARTED", payload, None)
    run(["git", "add", str(LEDGER.relative_to(ROOT))])
    run(["git", "commit", "-m", f"research: consume {TRIAL_ID} formal run budget"])
    committed = git("show", f"HEAD:{LEDGER.relative_to(ROOT)}")
    if record["record_hash"] not in committed:
        raise SystemExit("RUN_STARTED reservation was not committed")
    verify_remote_reservation(record, push=True)
    return record, True


def verify_remote_reservation(record: dict, push: bool) -> None:
    remote = run(["git", "ls-remote", "--refs", AUTHORITY_REMOTE, AUTHORITY_REF]).stdout.strip()
    if push and not remote:
        run(["git", "tag", "-d", AUTHORITY_TAG], check=False)
        run(["git", "tag", "-a", AUTHORITY_TAG, record["payload"]["authority_base_commit"],
             "-m", stable_bytes(record).decode().strip()])
        run(["git", "push", AUTHORITY_REMOTE, f"{AUTHORITY_REF}:{AUTHORITY_REF}"], check=False)
        remote = run(["git", "ls-remote", "--refs", AUTHORITY_REMOTE, AUTHORITY_REF]).stdout.strip()
    if not remote:
        raise SystemExit("durable formal reservation immutable tag is absent")
    run(["git", "fetch", "--force", AUTHORITY_REMOTE, f"{AUTHORITY_REF}:{AUTHORITY_REF}"])
    contents = git("for-each-ref", "--format=%(contents)", AUTHORITY_REF)
    try:
        remote_record = json.loads(contents)
    except json.JSONDecodeError as error:
        raise SystemExit("durable formal reservation tag payload is malformed") from error
    if remote_record != record:
        raise SystemExit("durable formal reservation lost immutable-tag CAS")
    if git("rev-parse", f"{AUTHORITY_REF}^{{}}") != record["payload"]["authority_base_commit"]:
        raise SystemExit("durable formal reservation tag base mismatch")


def git(*arguments: str) -> str:
    return run(["git", *arguments]).stdout.strip()


def validate_runtime() -> None:
    swift_lines = run(["xcrun", "swift", "--version"]).stdout.strip().splitlines()
    actual = {
        "swift_version": swift_lines[0] if swift_lines else "",
        "target": swift_lines[1].removeprefix("Target: ") if len(swift_lines) > 1 else "",
        "os_product": run(["sw_vers", "-productName"]).stdout.strip(),
        "os_version": run(["sw_vers", "-productVersion"]).stdout.strip(),
        "os_build": run(["sw_vers", "-buildVersion"]).stdout.strip(),
    }
    if actual != FORMAL_RUNTIME:
        raise SystemExit(f"formal runtime mismatch: {actual!r}")


def validate_inputs() -> dict:
    prereg = json.loads(PREREG.read_text(encoding="utf-8"))
    if prereg.get("trial_id") != TRIAL_ID or prereg.get("candidate_ids") != [CANDIDATE_ID]:
        raise SystemExit("preregistration identity mismatch")
    frozen = prereg.get("frozen_schedule") or {}
    if frozen.get("path") != str(SCHEDULE.relative_to(ROOT)) or frozen.get("sha256") != sha(SCHEDULE):
        raise SystemExit("schedule binding mismatch")
    if prereg.get("dataset_manifest") != str(DATASET.relative_to(ROOT)) or prereg.get("dataset_manifest_sha256") != sha(DATASET):
        raise SystemExit("dataset binding mismatch")
    cost = prereg.get("cost_model") or {}
    expected_cost = {
        "initial_cash_cny": 100_000.0,
        "transaction_fee_rate": 0.01,
        "slippage_rate": 0.0005,
        "financing_annual_rate": 0.0,
        "allows_financed_exposure": False,
        "sensitivity_runs_allowed": False,
    }
    if cost != expected_cost:
        raise SystemExit("formal cost contract mismatch")
    dataset = json.loads(DATASET.read_text(encoding="utf-8"))
    if dataset.get("trial_id") != TRIAL_ID or dataset.get("return_blind_freeze") is not True:
        raise SystemExit("dataset identity mismatch")
    for entry in dataset.get("files", []):
        path = ROOT / entry["path"]
        if not path.is_file() or path.stat().st_size != entry["bytes"] or sha(path) != entry["sha256"]:
            raise SystemExit(f"dataset file mismatch: {entry['path']}")
    return prereg


def validate_guard(output: Path) -> tuple[dict, Path]:
    required = [
        "ATM_SVP_PROTOCOL_ID", "ATM_SVP_TRIAL_ID", "ATM_SVP_PREREGISTRATION_RECORD_HASH",
        "ATM_SVP_EXECUTION_GIT_COMMIT", "ATM_SVP_RUN_GUARD_RECEIPT",
        "ATM_SVP_RUN_BUDGET_RECORD_HASH",
    ]
    if any(not os.environ.get(name) for name in required):
        raise SystemExit("formal guard environment missing")
    if os.environ["ATM_SVP_PROTOCOL_ID"] != "ATM-SVP-2" or os.environ["ATM_SVP_TRIAL_ID"] != TRIAL_ID:
        raise SystemExit("formal guard identity mismatch")
    receipt_path = Path(os.environ["ATM_SVP_RUN_GUARD_RECEIPT"]).resolve()
    allowed_receipts = {output / "run-authorization.json", output / "run-guard-receipt.json"}
    if output != OUTPUT.resolve() or receipt_path not in allowed_receipts:
        raise SystemExit("formal output/receipt path is not the fixed trial slot")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    expected = {
        "trial_id": TRIAL_ID,
        "preregistration_record_hash": os.environ["ATM_SVP_PREREGISTRATION_RECORD_HASH"],
        "execution_git_commit": os.environ["ATM_SVP_EXECUTION_GIT_COMMIT"],
        "formal_run_budget": 1,
        "candidate_count": 1,
        "run_budget_record_hash": os.environ["ATM_SVP_RUN_BUDGET_RECORD_HASH"],
    }
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise SystemExit("formal guard receipt mismatch")
    if git("rev-parse", "HEAD") != expected["execution_git_commit"]:
        raise SystemExit("execution Git commit mismatch")
    return receipt, receipt_path


def reservation_record(expected_hash: str) -> dict:
    _prereg, started, _result = trial_records()
    if started is None or started["record_hash"] != expected_hash:
        raise SystemExit("durable RUN_STARTED reservation binding mismatch")
    return started


def write_identical_or_new(path: Path, value: object) -> None:
    data = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() != data:
            raise SystemExit(f"refusing non-identical recovery artifact: {path}")
        return
    path.write_bytes(data)


def archive_reservation(record: dict, output: Path) -> None:
    write_identical_or_new(output / "run-budget-reservation.json", record)


def validate_clean_committed_source(prereg: dict, receipt_path: Path) -> None:
    if run(["git", "diff", "--quiet"], check=False).returncode or run(["git", "diff", "--cached", "--quiet"], check=False).returncode:
        raise SystemExit("formal run requires clean tracked sources")
    untracked = set(filter(None, git("ls-files", "--others", "--exclude-standard").splitlines()))
    expected_untracked = {str(receipt_path.relative_to(ROOT))}
    if receipt_path.name == "run-authorization.json":
        expected_untracked |= {
            str((receipt_path.parent / "stdout.txt").relative_to(ROOT)),
            str((receipt_path.parent / "stderr.txt").relative_to(ROOT)),
        }
    if untracked != expected_untracked:
        raise SystemExit(f"unexpected untracked files before formal run: {sorted(untracked)!r}")
    implementation = prereg.get("implementation_commit")
    if not isinstance(implementation, str) or len(implementation) != 40:
        raise SystemExit("implementation commit missing")
    changed = set(filter(None, git("diff", "--name-only", f"{implementation}..HEAD").splitlines()))
    if not changed.issubset(ALLOWED_POST_IMPLEMENTATION):
        raise SystemExit(f"source changed after implementation freeze: {sorted(changed - ALLOWED_POST_IMPLEMENTATION)!r}")
    for line in LEDGER.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        if record.get("event") == "RESULT" and (record.get("payload") or {}).get("trial_id") == TRIAL_ID:
            raise SystemExit("formal RESULT already exists")


def compile_binary() -> None:
    result = run([
        "swift", "build", "-c", "release", "--package-path", ".",
        "--product", "IntradayDownsideBreadthFormal",
    ])
    print(result.stdout, end="")
    if not BINARY.is_file():
        raise RuntimeError("formal binary missing")
    print(f"IDB_FORMAL_COMPILE_OK binary={BINARY} sha256={sha(BINARY)}")


def consume_slot(receipt_path: Path, output: Path) -> tuple[Path, str]:
    git_dir = Path(git("rev-parse", "--git-dir"))
    if not git_dir.is_absolute():
        git_dir = (ROOT / git_dir).resolve()
    slot_dir = git_dir / "atm-svp-run-slots"
    slot_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    slot = slot_dir / f"{TRIAL_ID}.json"
    value = {
        "schema_version": 1,
        "trial_id": TRIAL_ID,
        "protocol_id": "ATM-SVP-2",
        "execution_git_commit": git("rev-parse", "HEAD"),
        "preregistration_record_hash": os.environ["ATM_SVP_PREREGISTRATION_RECORD_HASH"],
        "run_budget_record_hash": os.environ["ATM_SVP_RUN_BUDGET_RECORD_HASH"],
        "output_directory": str(output.relative_to(ROOT)),
        "guard_receipt_sha256": sha(receipt_path),
        "executable_sha256": sha(BINARY),
        "runtime": FORMAL_RUNTIME,
        "nonce": secrets.token_hex(32),
    }
    data = stable_bytes(value)
    try:
        descriptor = os.open(slot, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise SystemExit("formal one-shot slot already consumed") from error
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        # Never remove a created slot: an attempted launch consumes the trial budget.
        raise
    shutil.copy2(slot, output / "run-slot.json")
    return slot, hashlib.sha256(data).hexdigest()


def validate_outputs(directory: Path) -> None:
    metrics_path = directory / "candidate-metrics.json"
    trace_path = directory / "queue-trace.json"
    if not metrics_path.is_file() or not trace_path.is_file():
        raise RuntimeError("formal outputs missing")
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
    if metrics.get("trial_id") != TRIAL_ID or metrics.get("candidate_id") != CANDIDATE_ID or metrics.get("decision") not in {"PASS", "FAIL", "INVALID"}:
        raise RuntimeError("formal metrics malformed")
    trace = json.loads(trace_path.read_text(encoding="utf-8"))
    if set(trace) != {"candidate", "natural", "placebo"}:
        raise RuntimeError("queue trace malformed")
    if metrics["decision"] != "INVALID" and any(not trace[name] for name in trace):
        raise RuntimeError("valid formal run has empty queue trace")


def local_slot_paths() -> tuple[Path, Path]:
    git_dir = Path(git("rev-parse", "--git-dir"))
    if not git_dir.is_absolute():
        git_dir = (ROOT / git_dir).resolve()
    slot = git_dir / "atm-svp-run-slots" / f"{TRIAL_ID}.json"
    return slot, slot.with_suffix(".launched.json")


def ensure_recovery_evidence(record: dict, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    receipt_path = output / "run-authorization.json"
    if not receipt_path.exists():
        guard = run([
            sys.executable, str(ROOT / "scripts/strategy_validation_run_guard.py"),
            "--trial-id", TRIAL_ID, "--receipt", str(receipt_path.relative_to(ROOT)),
        ], timeout=120, check=False)
        if guard.returncode:
            raise RuntimeError("cannot create recovery receipt for consumed formal budget")
    archive_reservation(record, output)
    slot, marker = local_slot_paths()
    if slot.is_file() and not (output / "run-slot.json").exists():
        shutil.copy2(slot, output / "run-slot.json")
    if marker.is_file() and not (output / "launch-marker.json").exists():
        shutil.copy2(marker, output / "launch-marker.json")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    for name in ["stdout.txt", "stderr.txt"]:
        (output / name).touch(exist_ok=True)
    execution_path = output / "execution.json"
    if not execution_path.exists():
        started_at = record["timestamp"]
        execution = {
            "protocol_id": "ATM-SVP-2",
            "trial_id": TRIAL_ID,
            "preregistration_record_hash": receipt["preregistration_record_hash"],
            "run_budget_record_hash": record["record_hash"],
            "execution_git_commit": receipt["execution_git_commit"],
            "run_guard_receipt": str(receipt_path.relative_to(ROOT)),
            "command": ["RECOVERY_WITHOUT_RERUN"],
            "started_at": started_at,
            "finished_at": now_iso(),
            "return_code": -255,
            "stdout": str((output / "stdout.txt").relative_to(ROOT)),
            "stderr": str((output / "stderr.txt").relative_to(ROOT)),
        }
        write_identical_or_new(execution_path, execution)


def finalize(output: Path) -> None:
    finalizer = run([
        sys.executable,
        str(ROOT / "scripts/finalize_intraday_downside_breadth_formal.py"),
        "--output-dir", str(output),
    ], timeout=180, check=False)
    print(finalizer.stdout, end="")
    if finalizer.returncode:
        raise RuntimeError("formal launch was consumed but RESULT finalization failed")


def orchestrate(output: Path) -> int:
    if output != OUTPUT.resolve():
        raise SystemExit("formal output directory is not the fixed trial slot")
    reservation, newly_reserved = reserve_budget(output)
    if not newly_reserved:
        ensure_recovery_evidence(reservation, output)
        finalize(output)
        raise SystemExit("previously consumed formal budget closed INVALID without rerun")
    command = [
        sys.executable, str(ROOT / "scripts/strategy_validation_formal_run.py"),
        "--trial-id", TRIAL_ID,
        "--output-dir", str(output.relative_to(ROOT)), "--",
        sys.executable, str(Path(__file__).resolve()), "--output-dir", str(output),
    ]
    try:
        formal = run(command, timeout=900, check=False)
    except BaseException:
        ensure_recovery_evidence(reservation, output)
        finalize(output)
        raise
    print(formal.stdout, end="")
    ensure_recovery_evidence(reservation, output)
    finalize(output)
    if formal.returncode:
        raise RuntimeError(f"standard formal wrapper failed ({formal.returncode}); trial closed INVALID")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--output-dir")
    args = parser.parse_args()
    if args.compile_only:
        validate_runtime()
        compile_binary()
        return 0
    if not args.output_dir:
        raise SystemExit("--output-dir required")
    output = Path(args.output_dir).resolve()
    if not os.environ.get("ATM_SVP_RUN_GUARD_RECEIPT"):
        return orchestrate(output)
    receipt, receipt_path = validate_guard(output)
    prereg = validate_inputs()
    validate_clean_committed_source(prereg, receipt_path)
    validate_runtime()
    existing = {path.name for path in output.iterdir()}
    allowed_initial = ({"run-guard-receipt.json"}, {"run-authorization.json", "stdout.txt", "stderr.txt"})
    if existing not in allowed_initial:
        raise SystemExit("formal output directory is not guard-clean")
    reservation = reservation_record(receipt["run_budget_record_hash"])
    archive_reservation(reservation, output)
    compile_binary()
    slot, slot_sha = consume_slot(receipt_path, output)
    environment = os.environ.copy()
    environment.update({
        "ATM_SVP_RUN_SLOT": str(slot),
        "ATM_SVP_RUN_SLOT_SHA256": slot_sha,
        "ATM_SVP_EXECUTABLE_SHA256": sha(BINARY),
    })
    result = subprocess.run(
        [str(BINARY), "--repo-root", str(ROOT), "--output-dir", str(output)],
        cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=600,
    )
    launch_marker = slot.with_suffix(".launched.json")
    if launch_marker.is_file() and not (output / "launch-marker.json").exists():
        shutil.copy2(launch_marker, output / "launch-marker.json")
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(f"formal binary failed after one-shot consumption ({result.returncode})")
    validate_outputs(output)
    print(f"IDB_FORMAL_RESULT_OK output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
