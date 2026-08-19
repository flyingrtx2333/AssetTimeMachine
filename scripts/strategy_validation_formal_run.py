#!/usr/bin/env python3
"""Run one formal ATM-SVP-1 experiment behind the committed-preregistration guard."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trial-id", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise SystemExit("A formal command is required after --")

    output_dir = Path(args.output_dir)
    if output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit(f"Formal output directory must be new/empty: {output_dir}")
    receipt_path = output_dir / "run-authorization.json"

    guard = subprocess.run(
        [
            sys.executable,
            "scripts/strategy_validation_run_guard.py",
            "--trial-id",
            args.trial_id,
            "--receipt",
            str(receipt_path),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    print(guard.stdout, end="")
    if guard.returncode != 0:
        raise SystemExit(guard.returncode)

    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    stdout_path = output_dir / "stdout.log"
    stderr_path = output_dir / "stderr.log"
    execution_path = output_dir / "execution.json"

    env = os.environ.copy()
    env.update(
        {
            "ATM_SVP_PROTOCOL_ID": "ATM-SVP-1",
            "ATM_SVP_TRIAL_ID": args.trial_id,
            "ATM_SVP_PREREGISTRATION_RECORD_HASH": receipt["preregistration_record_hash"],
            "ATM_SVP_EXECUTION_GIT_COMMIT": receipt["execution_git_commit"],
            "ATM_SVP_RUN_GUARD_RECEIPT": str(receipt_path),
        }
    )

    started_at = now_iso()
    with stdout_path.open("w", encoding="utf-8") as stdout_handle, stderr_path.open("w", encoding="utf-8") as stderr_handle:
        process = subprocess.run(
            command,
            env=env,
            text=True,
            stdout=stdout_handle,
            stderr=stderr_handle,
            check=False,
        )
    finished_at = now_iso()

    execution = {
        "protocol_id": "ATM-SVP-1",
        "trial_id": args.trial_id,
        "preregistration_record_hash": receipt["preregistration_record_hash"],
        "execution_git_commit": receipt["execution_git_commit"],
        "run_guard_receipt": str(receipt_path),
        "command": command,
        "started_at": started_at,
        "finished_at": finished_at,
        "return_code": process.returncode,
        "stdout": str(stdout_path),
        "stderr": str(stderr_path),
    }
    execution_path.write_text(json.dumps(execution, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if process.returncode != 0:
        print(
            f"FORMAL_RUN_FAILED trial_id={args.trial_id} return_code={process.returncode} "
            f"execution={execution_path}"
        )
        raise SystemExit(process.returncode)
    print(f"FORMAL_RUN_COMPLETE trial_id={args.trial_id} execution={execution_path}")


if __name__ == "__main__":
    main()
