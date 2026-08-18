#!/usr/bin/env python3
"""Append-only hash-chained ledger for AssetTimeMachine strategy research trials.

This tool stores research governance metadata only. It does not implement or simulate a strategy.

Examples:
  python3 scripts/strategy_validation_ledger.py verify
  python3 scripts/strategy_validation_ledger.py append \
      --event PREREGISTER \
      --payload-json '{"trial_id":"SVP1-0001","hypothesis":"..."}'
"""
from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_LEDGER = Path("tools/research-results/strategy-validation/trial-ledger.jsonl")
GENESIS = "GENESIS"


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def record_hash(record_without_hash: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(record_without_hash).encode("utf-8")).hexdigest()


def read_records(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"Invalid JSON at {path}:{line_number}: {error}") from error
            if not isinstance(value, dict):
                raise SystemExit(f"Ledger record must be an object at {path}:{line_number}")
            records.append(value)
    return records


def verify_records(records: list[dict[str, Any]]) -> None:
    previous = GENESIS
    seen_hashes: set[str] = set()
    preregistered_trials: set[str] = set()
    result_trials: set[str] = set()

    for index, record in enumerate(records, start=1):
        required = {"sequence", "timestamp", "event", "payload", "previous_hash", "record_hash"}
        missing = required - set(record)
        if missing:
            raise SystemExit(f"Ledger sequence {index} missing fields: {sorted(missing)}")
        if record["sequence"] != index:
            raise SystemExit(
                f"Ledger sequence mismatch: expected {index}, got {record['sequence']}"
            )
        if record["previous_hash"] != previous:
            raise SystemExit(
                f"Hash-chain mismatch at sequence {index}: expected previous_hash={previous}"
            )

        stored_hash = record["record_hash"]
        unsigned = dict(record)
        unsigned.pop("record_hash", None)
        computed = record_hash(unsigned)
        if stored_hash != computed:
            raise SystemExit(
                f"Record hash mismatch at sequence {index}: stored={stored_hash}, computed={computed}"
            )
        if stored_hash in seen_hashes:
            raise SystemExit(f"Duplicate record hash at sequence {index}")
        seen_hashes.add(stored_hash)
        previous = stored_hash

        event = str(record["event"])
        payload = record["payload"]
        if not isinstance(payload, dict):
            raise SystemExit(f"Payload must be an object at sequence {index}")
        trial_id = payload.get("trial_id")
        if event == "PREREGISTER":
            if not trial_id:
                raise SystemExit(f"PREREGISTER missing trial_id at sequence {index}")
            if trial_id in preregistered_trials:
                raise SystemExit(f"Duplicate PREREGISTER for trial_id={trial_id}")
            preregistered_trials.add(str(trial_id))
        elif event == "RESULT":
            if not trial_id:
                raise SystemExit(f"RESULT missing trial_id at sequence {index}")
            if trial_id not in preregistered_trials:
                raise SystemExit(
                    f"RESULT for trial_id={trial_id} has no earlier PREREGISTER"
                )
            if trial_id in result_trials:
                raise SystemExit(f"Duplicate RESULT for trial_id={trial_id}")
            result_trials.add(str(trial_id))


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def append_record(
    path: Path,
    event: str,
    payload: dict[str, Any],
    timestamp: str | None,
) -> dict[str, Any]:
    records = read_records(path)
    verify_records(records)
    previous = records[-1]["record_hash"] if records else GENESIS
    unsigned = {
        "sequence": len(records) + 1,
        "timestamp": timestamp or now_iso(),
        "event": event,
        "payload": payload,
        "previous_hash": previous,
    }
    record = {**unsigned, "record_hash": record_hash(unsigned)}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(record) + "\n")
    verify_records(read_records(path))
    return record


def parse_payload(args: argparse.Namespace) -> dict[str, Any]:
    if args.payload_json is not None:
        value = json.loads(args.payload_json)
    elif args.payload_file is not None:
        value = json.loads(Path(args.payload_file).read_text(encoding="utf-8"))
    else:
        raise SystemExit("append requires --payload-json or --payload-file")
    if not isinstance(value, dict):
        raise SystemExit("payload must be a JSON object")
    return value


def cmd_verify(args: argparse.Namespace) -> None:
    path = Path(args.ledger)
    records = read_records(path)
    verify_records(records)
    head = records[-1]["record_hash"] if records else GENESIS
    prereg = sum(1 for row in records if row["event"] == "PREREGISTER")
    results = sum(1 for row in records if row["event"] == "RESULT")
    print(
        f"LEDGER_VALID records={len(records)} preregistrations={prereg} "
        f"results={results} head={head}"
    )


def cmd_append(args: argparse.Namespace) -> None:
    path = Path(args.ledger)
    payload = parse_payload(args)
    record = append_record(path, args.event, payload, args.timestamp)
    print(
        f"LEDGER_APPENDED sequence={record['sequence']} event={record['event']} "
        f"record_hash={record['record_hash']}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    subparsers = parser.add_subparsers(dest="command", required=True)

    verify = subparsers.add_parser("verify")
    verify.set_defaults(func=cmd_verify)

    append = subparsers.add_parser("append")
    append.add_argument("--event", required=True)
    payload_group = append.add_mutually_exclusive_group(required=True)
    payload_group.add_argument("--payload-json")
    payload_group.add_argument("--payload-file")
    append.add_argument("--timestamp")
    append.set_defaults(func=cmd_append)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
