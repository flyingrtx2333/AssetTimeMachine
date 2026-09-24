#!/usr/bin/env python3
"""Compile or execute the single guarded RS range-breadth formal run."""
from __future__ import annotations
import argparse, hashlib, json, os, subprocess, sys
from pathlib import Path

try:
    from artifact_paths import (
        read_bytes as artifact_read_bytes,
        resolve as resolve_artifact,
        sha256_of as artifact_sha256,
    )
except ImportError:  # imported as scripts.<name>
    from scripts.artifact_paths import (
        read_bytes as artifact_read_bytes,
        resolve as resolve_artifact,
        sha256_of as artifact_sha256,
    )

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-RS-RANGE-BREADTH-001"
CANDIDATE_ID = "RS-RANGE-BREADTH-21-252-001"
SV_DIR = "tools/research-results/strategy-validation"
PREREG_LOGICAL = f"{SV_DIR}/preregistrations/{TRIAL_ID}.json"
SCHEDULE_LOGICAL = f"{SV_DIR}/preregistrations/RS-RANGE-BREADTH-21-252-001-schedule.json"
DATASET_LOGICAL = f"{SV_DIR}/datasets/{TRIAL_ID}.json"
FIXTURE_LOGICAL = "tools/fixtures/backtest-history/public_history.json"
# Logical paths are the frozen identity recorded in the preregistration and ledger;
# resolve() maps them to whichever checkout currently holds the bytes.
PREREG = resolve_artifact(PREREG_LOGICAL, repo_root=ROOT)
SCHEDULE = resolve_artifact(SCHEDULE_LOGICAL, repo_root=ROOT)
DATASET = resolve_artifact(DATASET_LOGICAL, repo_root=ROOT)
BINARY = ROOT / ".build/release/RSRangeBreadthFormal"


def run(command: list[str], timeout: int = 600) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        sys.stderr.write(result.stdout[-20000:])
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}")
    return result.stdout


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compile_binary() -> None:
    print(run(["swift", "build", "-c", "release", "--package-path", ".", "--product", "RSRangeBreadthFormal"]), end="")
    if not BINARY.is_file():
        raise RuntimeError("formal binary missing")
    print(f"RS_RANGE_BREADTH_COMPILE_OK binary={BINARY}")


def validate_inputs() -> dict:
    prereg = json.loads(PREREG.read_text())
    if prereg.get("trial_id") != TRIAL_ID or prereg.get("candidate_ids") != [CANDIDATE_ID]:
        raise SystemExit("preregistration identity mismatch")
    frozen = prereg.get("frozen_schedule", {})
    if frozen.get("path") != SCHEDULE_LOGICAL or frozen.get("sha256") != artifact_sha256(SCHEDULE_LOGICAL, repo_root=ROOT):
        raise SystemExit("schedule binding mismatch")
    if prereg.get("dataset_manifest") != DATASET_LOGICAL or prereg.get("fixture", {}).get("dataset_manifest_sha256") != sha(DATASET):
        raise SystemExit("dataset binding mismatch")
    dataset = json.loads(DATASET.read_text())
    for entry in dataset.get("files", []):
        # entry["path"] is a frozen logical path; read_bytes decompresses .xz transparently
        # and verifies against the recorded logical size/hash.
        payload = artifact_read_bytes(entry["path"], repo_root=ROOT)
        if len(payload) != entry["bytes"] or hashlib.sha256(payload).hexdigest() != entry["sha256"]:
            raise SystemExit(f"dataset file mismatch: {entry['path']}")
    return prereg


def validate_guard() -> None:
    required = ["ATM_SVP_PROTOCOL_ID", "ATM_SVP_TRIAL_ID", "ATM_SVP_PREREGISTRATION_RECORD_HASH", "ATM_SVP_EXECUTION_GIT_COMMIT", "ATM_SVP_RUN_GUARD_RECEIPT"]
    if any(not os.environ.get(name) for name in required):
        raise SystemExit("formal guard environment missing")
    if os.environ["ATM_SVP_PROTOCOL_ID"] != "ATM-SVP-2" or os.environ["ATM_SVP_TRIAL_ID"] != TRIAL_ID:
        raise SystemExit("formal guard identity mismatch")
    receipt = json.loads(Path(os.environ["ATM_SVP_RUN_GUARD_RECEIPT"]).read_text())
    expected = {
        "trial_id": TRIAL_ID,
        "preregistration_record_hash": os.environ["ATM_SVP_PREREGISTRATION_RECORD_HASH"],
        "execution_git_commit": os.environ["ATM_SVP_EXECUTION_GIT_COMMIT"],
        "formal_run_budget": 1,
        "candidate_count": 1,
    }
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise SystemExit("formal guard receipt mismatch")
    if run(["git", "rev-parse", "HEAD"]).strip() != expected["execution_git_commit"]:
        raise SystemExit("execution Git commit mismatch")


def validate_outputs(directory: Path) -> None:
    metrics_path, trace_path = directory / "candidate-metrics.json", directory / "queue-trace.json"
    if not metrics_path.is_file() or not trace_path.is_file():
        raise RuntimeError("formal outputs missing")
    metrics = json.loads(metrics_path.read_text())
    if metrics.get("trial_id") != TRIAL_ID or metrics.get("candidate_id") != CANDIDATE_ID or metrics.get("decision") not in {"PASS", "REJECTED"}:
        raise RuntimeError("formal metrics malformed")
    trace = json.loads(trace_path.read_text())
    if set(trace) != {"candidate", "natural", "placebo"} or any(not trace[name] for name in trace):
        raise RuntimeError("queue trace malformed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--output-dir")
    args = parser.parse_args()
    compile_binary()
    if args.compile_only:
        return 0
    validate_guard(); validate_inputs()
    if not args.output_dir:
        raise SystemExit("--output-dir required")
    output = Path(args.output_dir).resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit("formal output directory must be new/empty")
    output.mkdir(parents=True, exist_ok=True)
    print(run([str(BINARY), "--repo-root", str(ROOT), "--output-dir", str(output)]), end="")
    validate_outputs(output)
    print(f"RS_RANGE_BREADTH_RESULT_OK output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
