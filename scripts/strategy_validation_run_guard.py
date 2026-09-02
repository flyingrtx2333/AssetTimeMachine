#!/usr/bin/env python3
"""Authorize a formal ATM-SVP experiment only after its preregistration is committed.

This guard does not execute a strategy. It proves that the requested trial exists in the durable
hash-chained ledger, that the exact preregistration record is present in the current Git HEAD, that
no RESULT exists yet, and that the worktree is clean before the formal run begins.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from strategy_validation_ledger import DEFAULT_LEDGER, canonical_json, read_records, verify_records


def run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def records_from_text(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f"Committed ledger has invalid JSON at line {line_number}: {error}") from error
        if not isinstance(value, dict):
            raise SystemExit(f"Committed ledger record must be an object at line {line_number}")
        records.append(value)
    return records


def find_trial(records: list[dict[str, Any]], trial_id: str) -> tuple[dict[str, Any], dict[str, Any] | None]:
    preregistration: dict[str, Any] | None = None
    result_record: dict[str, Any] | None = None
    for record in records:
        payload = record.get("payload", {})
        if payload.get("trial_id") != trial_id:
            continue
        if record.get("event") == "PREREGISTER":
            preregistration = record
        elif record.get("event") == "RESULT":
            result_record = record
    if preregistration is None:
        raise SystemExit(f"No PREREGISTER found for trial_id={trial_id}")
    return preregistration, result_record


def find_run_started(records: list[dict[str, Any]], trial_id: str) -> dict[str, Any] | None:
    matches = [
        record for record in records
        if record.get("event") == "RUN_STARTED"
        and (record.get("payload") or {}).get("trial_id") == trial_id
    ]
    if len(matches) > 1:
        raise SystemExit(f"Duplicate RUN_STARTED for trial_id={trial_id}")
    return matches[0] if matches else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trial-id", required=True)
    parser.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    parser.add_argument("--receipt")
    args = parser.parse_args()

    ledger_path = Path(args.ledger)
    records = read_records(ledger_path)
    verify_records(records)
    preregistration, result_record = find_trial(records, args.trial_id)
    if result_record is not None:
        raise SystemExit(f"Formal run refused: trial_id={args.trial_id} already has a RESULT")

    status = run_git("status", "--porcelain").strip()
    if status:
        raise SystemExit(
            "Formal run refused: worktree is not clean. Commit the preregistration, holdout manifest, "
            "and executable research code before running the formal experiment."
        )

    head = run_git("rev-parse", "HEAD").strip()
    committed_ledger_text = run_git("show", f"HEAD:{ledger_path.as_posix()}")
    committed_records = records_from_text(committed_ledger_text)
    verify_records(committed_records)
    committed_preregistration, committed_result = find_trial(committed_records, args.trial_id)
    if committed_result is not None:
        raise SystemExit(f"Formal run refused: committed trial_id={args.trial_id} already has a RESULT")
    if committed_preregistration["record_hash"] != preregistration["record_hash"]:
        raise SystemExit(
            "Formal run refused: working-ledger preregistration differs from the version committed in HEAD"
        )

    requires_reservation = preregistration["payload"].get("requires_durable_run_reservation") is True
    run_started = find_run_started(records, args.trial_id)
    committed_run_started = find_run_started(committed_records, args.trial_id)
    if requires_reservation:
        if run_started is None or committed_run_started is None:
            raise SystemExit(f"Formal run refused: trial_id={args.trial_id} has no committed RUN_STARTED")
        if run_started["record_hash"] != committed_run_started["record_hash"]:
            raise SystemExit("Formal run refused: RUN_STARTED differs from committed HEAD")

    protocol_id = preregistration["payload"]["protocol_id"]
    receipt = {
        "protocol_id": protocol_id,
        "trial_id": args.trial_id,
        "preregistration_record_hash": preregistration["record_hash"],
        "execution_git_commit": head,
        "ledger_head_at_authorization": records[-1]["record_hash"] if records else "GENESIS",
        "evidence_class": preregistration["payload"]["evidence_class"],
        "candidate_count": preregistration["payload"]["candidate_count"],
        "formal_run_budget": preregistration["payload"]["formal_run_budget"],
    }
    if run_started is not None:
        receipt["run_budget_record_hash"] = run_started["record_hash"]
    if args.receipt:
        receipt_path = Path(args.receipt)
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "FORMAL_RUN_AUTHORIZED "
        f"trial_id={args.trial_id} preregistration_record_hash={preregistration['record_hash']} "
        f"execution_git_commit={head}"
    )
    print(canonical_json(receipt))


if __name__ == "__main__":
    main()
