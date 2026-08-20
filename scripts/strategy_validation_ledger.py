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
CURRENT_PROTOCOL_ID = "ATM-SVP-2"
SUPPORTED_PROTOCOL_IDS = {"ATM-SVP-1", "ATM-SVP-2"}
EVIDENCE_CLASSES = {"D0_EXPOSED", "R1_RETROSPECTIVE", "H2_PRISTINE_HOLDOUT", "P3_PROSPECTIVE"}
PREREGISTER_REQUIRED_FIELDS = {
    "trial_id",
    "protocol_id",
    "strategy_lineage",
    "hypothesis",
    "evidence_class",
    "dataset_manifest",
    "allowed_changes",
    "candidate_ids",
    "candidate_count",
    "selection_metric",
    "pass_fail_gates",
    "formal_run_budget",
    "follow_up_policy",
    "swift_engine_entrypoint",
    "expected_outputs",
}
RESULT_REQUIRED_FIELDS = {
    "trial_id",
    "preregistration_record_hash",
    "execution_git_commit",
    "run_guard_receipt",
    "dataset_manifest",
    "artifact_manifest",
    "status",
    "candidate_results",
    "decision",
    "artifacts",
}
HOLDOUT_BURN_REQUIRED_FIELDS = {
    "protocol_id",
    "holdout_id",
    "strategy_id",
    "strategy_version",
    "manifest_path",
    "manifest_sha256",
    "selection_payload_sha256",
    "frozen_manifest_git_commit",
    "permanent",
    "rule",
}
PROTOCOL_UPGRADE_REQUIRED_FIELDS = {
    "from_protocol",
    "to_protocol",
    "strategy_id",
    "strategy_version",
    "governance_change_scope",
    "strategy_target_path_changed",
    "prospective_clock_restarted",
    "g4_holdout_burned_before_upgrade",
    "g4_full_history_opened_before_upgrade",
    "reason",
}
G4_REFERENCE_REQUIRED_FIELDS = {
    "protocol_id",
    "holdout_id",
    "strategy_id",
    "strategy_version",
    "manifest_path",
    "manifest_sha256",
    "selection_payload_sha256",
    "evaluation_start",
    "evaluation_end",
    "cagr",
    "sharpe",
    "mdd",
    "trades",
    "target_fingerprint",
    "max_gross",
    "min_weight",
    "source_fixture_path",
    "source_fixture_sha256",
    "execution_git_commit",
    "reference_artifact_path",
    "reference_artifact_sha256",
}
G4_HOLDOUT_INVALID_REQUIRED_FIELDS = {
    "protocol_id",
    "holdout_id",
    "strategy_id",
    "strategy_version",
    "manifest_path",
    "manifest_sha256",
    "authorization_receipt_path",
    "authorization_receipt_sha256",
    "invalid_stage",
    "invalid_reason",
    "opened_full_history",
    "formal_substitution_run_started",
    "substitution_performance_metrics_viewed",
    "permanent_no_replacement",
    "successful_raw_roles",
    "unavailable_roles",
    "diagnostic_artifact_path",
    "diagnostic_artifact_sha256",
}


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


def require_payload_fields(payload: dict[str, Any], required: set[str], label: str) -> None:
    missing = required - set(payload)
    if missing:
        raise SystemExit(f"{label} missing payload fields: {sorted(missing)}")


def validate_preregister_payload(payload: dict[str, Any]) -> None:
    require_payload_fields(payload, PREREGISTER_REQUIRED_FIELDS, "PREREGISTER")
    if payload["protocol_id"] not in SUPPORTED_PROTOCOL_IDS:
        raise SystemExit(f"PREREGISTER protocol_id must be one of {sorted(SUPPORTED_PROTOCOL_IDS)}")
    if payload["evidence_class"] not in EVIDENCE_CLASSES:
        raise SystemExit(f"Unknown evidence_class: {payload['evidence_class']}")
    candidate_ids = payload["candidate_ids"]
    if not isinstance(candidate_ids, list) or not candidate_ids or not all(isinstance(x, str) and x for x in candidate_ids):
        raise SystemExit("PREREGISTER candidate_ids must be a non-empty string list")
    if len(candidate_ids) != len(set(candidate_ids)):
        raise SystemExit("PREREGISTER candidate_ids contain duplicates")
    if payload["candidate_count"] != len(candidate_ids):
        raise SystemExit("PREREGISTER candidate_count must equal len(candidate_ids)")
    if not isinstance(payload["dataset_manifest"], str) or not payload["dataset_manifest"].strip():
        raise SystemExit("PREREGISTER dataset_manifest must be a non-empty manifest path")
    if not isinstance(payload["allowed_changes"], list):
        raise SystemExit("PREREGISTER allowed_changes must be a list")
    if not isinstance(payload["pass_fail_gates"], list) or not payload["pass_fail_gates"]:
        raise SystemExit("PREREGISTER pass_fail_gates must be a non-empty list")
    if not isinstance(payload["expected_outputs"], list) or not payload["expected_outputs"]:
        raise SystemExit("PREREGISTER expected_outputs must be a non-empty list")
    if not isinstance(payload["formal_run_budget"], int) or payload["formal_run_budget"] < 1:
        raise SystemExit("PREREGISTER formal_run_budget must be an integer >= 1")
    for key in ["trial_id", "strategy_lineage", "hypothesis", "selection_metric", "follow_up_policy", "swift_engine_entrypoint"]:
        if not isinstance(payload[key], str) or not payload[key].strip():
            raise SystemExit(f"PREREGISTER {key} must be a non-empty string")


def validate_result_payload(
    payload: dict[str, Any],
    preregistration_record: dict[str, Any],
) -> None:
    require_payload_fields(payload, RESULT_REQUIRED_FIELDS, "RESULT")
    prereg_payload = preregistration_record["payload"]
    if payload["preregistration_record_hash"] != preregistration_record["record_hash"]:
        raise SystemExit("RESULT preregistration_record_hash does not match the registered trial")
    if payload["status"] not in {"PASS", "FAIL", "INCONCLUSIVE", "INVALID", "ABORTED"}:
        raise SystemExit(f"RESULT has unsupported status: {payload['status']}")
    execution_git_commit = payload["execution_git_commit"]
    if not isinstance(execution_git_commit, str) or len(execution_git_commit) != 40 or any(c not in "0123456789abcdef" for c in execution_git_commit.lower()):
        raise SystemExit("RESULT execution_git_commit must be a full 40-character Git SHA")
    if not isinstance(payload["run_guard_receipt"], str) or not payload["run_guard_receipt"].strip():
        raise SystemExit("RESULT run_guard_receipt must be a non-empty artifact path")
    for key in ["dataset_manifest", "artifact_manifest"]:
        if not isinstance(payload[key], str) or not payload[key].strip():
            raise SystemExit(f"RESULT {key} must be a non-empty artifact path")
    if not isinstance(payload["candidate_results"], list):
        raise SystemExit("RESULT candidate_results must be a list")
    if payload["status"] in {"PASS", "FAIL", "INCONCLUSIVE"}:
        if len(payload["candidate_results"]) != prereg_payload["candidate_count"]:
            raise SystemExit("RESULT must report every preregistered candidate")
        candidate_ids: list[str] = []
        for candidate_result in payload["candidate_results"]:
            if not isinstance(candidate_result, dict):
                raise SystemExit("RESULT candidate_results entries must be objects")
            candidate_id = candidate_result.get("candidate_id")
            if not isinstance(candidate_id, str) or not candidate_id:
                raise SystemExit("RESULT candidate result missing candidate_id")
            if not isinstance(candidate_result.get("metrics"), dict):
                raise SystemExit(f"RESULT candidate={candidate_id} missing metrics object")
            candidate_ids.append(candidate_id)
        if len(candidate_ids) != len(set(candidate_ids)):
            raise SystemExit("RESULT candidate_results contain duplicate candidate_id values")
        if set(candidate_ids) != set(prereg_payload["candidate_ids"]):
            raise SystemExit("RESULT candidate_results do not exactly match preregistered candidate_ids")
    if not isinstance(payload["artifacts"], list):
        raise SystemExit("RESULT artifacts must be a list")
    if not isinstance(payload["decision"], str) or not payload["decision"].strip():
        raise SystemExit("RESULT decision must be a non-empty string")


def verify_records(records: list[dict[str, Any]]) -> None:
    previous = GENESIS
    previous_timestamp: datetime | None = None
    seen_hashes: set[str] = set()
    preregistrations: dict[str, dict[str, Any]] = {}
    result_trials: set[str] = set()
    burned_holdout_by_strategy_version: dict[str, str] = {}
    upgraded_protocols: set[tuple[str, str]] = set()
    g4_reference_by_holdout: dict[str, dict[str, Any]] = {}
    g4_invalid_by_holdout: set[str] = set()

    for index, record in enumerate(records, start=1):
        required = {"sequence", "timestamp", "event", "payload", "previous_hash", "record_hash"}
        missing = required - set(record)
        if missing:
            raise SystemExit(f"Ledger sequence {index} missing fields: {sorted(missing)}")
        if record["sequence"] != index:
            raise SystemExit(
                f"Ledger sequence mismatch: expected {index}, got {record['sequence']}"
            )
        try:
            timestamp = datetime.fromisoformat(str(record["timestamp"]))
        except ValueError as error:
            raise SystemExit(f"Invalid ISO timestamp at sequence {index}") from error
        if timestamp.tzinfo is None:
            raise SystemExit(f"Ledger timestamp must include timezone at sequence {index}")
        if previous_timestamp is not None and timestamp < previous_timestamp:
            raise SystemExit(f"Ledger timestamp moved backward at sequence {index}")
        previous_timestamp = timestamp
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
            validate_preregister_payload(payload)
            trial_id = str(payload["trial_id"])
            if trial_id in preregistrations:
                raise SystemExit(f"Duplicate PREREGISTER for trial_id={trial_id}")
            preregistrations[trial_id] = record
        elif event == "RESULT":
            if not trial_id:
                raise SystemExit(f"RESULT missing trial_id at sequence {index}")
            trial_id = str(trial_id)
            preregistration = preregistrations.get(trial_id)
            if preregistration is None:
                raise SystemExit(
                    f"RESULT for trial_id={trial_id} has no earlier PREREGISTER"
                )
            if trial_id in result_trials:
                raise SystemExit(f"Duplicate RESULT for trial_id={trial_id}")
            validate_result_payload(payload, preregistration)
            result_trials.add(trial_id)
        elif event == "PROTOCOL_UPGRADE":
            require_payload_fields(payload, PROTOCOL_UPGRADE_REQUIRED_FIELDS, "PROTOCOL_UPGRADE")
            transition = (str(payload["from_protocol"]), str(payload["to_protocol"]))
            if transition != ("ATM-SVP-1", "ATM-SVP-2"):
                raise SystemExit(f"Unsupported protocol upgrade transition: {transition}")
            if transition in upgraded_protocols:
                raise SystemExit(f"Duplicate PROTOCOL_UPGRADE transition: {transition}")
            if payload["strategy_target_path_changed"] is not False:
                raise SystemExit("ATM-SVP-2 governance upgrade must not change the strategy target path")
            if payload["prospective_clock_restarted"] is not False:
                raise SystemExit("ATM-SVP-2 governance upgrade must not restart the prospective clock")
            if payload["g4_holdout_burned_before_upgrade"] is not False:
                raise SystemExit("ATM-SVP-2 upgrade must occur before any G4 holdout burn")
            if payload["g4_full_history_opened_before_upgrade"] is not False:
                raise SystemExit("ATM-SVP-2 upgrade must occur before any G4 full-history opening")
            upgraded_protocols.add(transition)
        elif event == "G4_REFERENCE_BASELINE_FROZEN":
            require_payload_fields(payload, G4_REFERENCE_REQUIRED_FIELDS, "G4_REFERENCE_BASELINE_FROZEN")
            if payload["protocol_id"] != "ATM-SVP-2":
                raise SystemExit("G4 reference baseline must be frozen under ATM-SVP-2")
            holdout_id = str(payload["holdout_id"])
            if not holdout_id:
                raise SystemExit("G4 reference holdout_id must be non-empty")
            if holdout_id in g4_reference_by_holdout:
                raise SystemExit(f"Duplicate G4 reference baseline for holdout_id={holdout_id}")
            if float(payload["cagr"]) <= 0 or float(payload["sharpe"]) <= 0:
                raise SystemExit("G4 common-window identity reference must have positive CAGR and Sharpe")
            if float(payload["mdd"]) > 0.25:
                raise SystemExit("G4 common-window identity reference MDD must be <=25%")
            if float(payload["max_gross"]) > 1.000000001 or float(payload["min_weight"]) < -1e-10:
                raise SystemExit("G4 common-window identity reference violates portfolio constraints")
            g4_reference_by_holdout[holdout_id] = record
        elif event == "G4_HOLDOUT_INVALID":
            require_payload_fields(payload, G4_HOLDOUT_INVALID_REQUIRED_FIELDS, "G4_HOLDOUT_INVALID")
            if payload["protocol_id"] != "ATM-SVP-2":
                raise SystemExit("G4_HOLDOUT_INVALID must use ATM-SVP-2")
            holdout_id = str(payload["holdout_id"])
            if holdout_id in g4_invalid_by_holdout:
                raise SystemExit(f"Duplicate G4_HOLDOUT_INVALID for holdout_id={holdout_id}")
            if payload.get("opened_full_history") is not True:
                raise SystemExit("G4_HOLDOUT_INVALID must acknowledge that full history was opened")
            if payload.get("formal_substitution_run_started") is not False:
                raise SystemExit("G4 source-invalid state must precede any formal substitution run")
            if payload.get("substitution_performance_metrics_viewed") is not False:
                raise SystemExit("G4 source-invalid state must not be performance-driven")
            if payload.get("permanent_no_replacement") is not True:
                raise SystemExit("G4 invalid holdout must preserve the permanent no-replacement rule")
            if holdout_id not in set(burned_holdout_by_strategy_version.values()):
                raise SystemExit(f"G4_HOLDOUT_INVALID requires an earlier burned holdout: {holdout_id}")
            successful = payload.get("successful_raw_roles")
            unavailable = payload.get("unavailable_roles")
            if not isinstance(successful, list) or not all(isinstance(x, str) and x for x in successful):
                raise SystemExit("G4_HOLDOUT_INVALID successful_raw_roles must be a string list")
            if not isinstance(unavailable, list) or not unavailable or not all(isinstance(x, str) and x for x in unavailable):
                raise SystemExit("G4_HOLDOUT_INVALID unavailable_roles must be a non-empty string list")
            if not isinstance(payload.get("invalid_reason"), str) or len(payload["invalid_reason"].strip()) < 20:
                raise SystemExit("G4_HOLDOUT_INVALID invalid_reason is too weak")
            g4_invalid_by_holdout.add(holdout_id)
        elif event == "HOLDOUT_BURNED":
            require_payload_fields(payload, HOLDOUT_BURN_REQUIRED_FIELDS, "HOLDOUT_BURNED")
            if payload["protocol_id"] not in SUPPORTED_PROTOCOL_IDS:
                raise SystemExit(f"HOLDOUT_BURNED protocol_id must be one of {sorted(SUPPORTED_PROTOCOL_IDS)}")
            if payload["permanent"] is not True:
                raise SystemExit("HOLDOUT_BURNED permanent must be true")
            strategy_version = payload["strategy_version"]
            holdout_id = payload["holdout_id"]
            if payload["protocol_id"] == "ATM-SVP-2":
                reference = g4_reference_by_holdout.get(str(holdout_id))
                if reference is None:
                    raise SystemExit(
                        f"ATM-SVP-2 HOLDOUT_BURNED requires an earlier G4_REFERENCE_BASELINE_FROZEN for holdout_id={holdout_id}"
                    )
                ref_payload = reference["payload"]
                if ref_payload["manifest_sha256"] != payload["manifest_sha256"]:
                    raise SystemExit("G4 reference and HOLDOUT_BURNED manifest SHA do not match")
                if ref_payload["selection_payload_sha256"] != payload["selection_payload_sha256"]:
                    raise SystemExit("G4 reference and HOLDOUT_BURNED selection payload SHA do not match")
            if not isinstance(strategy_version, str) or not strategy_version:
                raise SystemExit("HOLDOUT_BURNED strategy_version must be non-empty")
            if not isinstance(holdout_id, str) or not holdout_id:
                raise SystemExit("HOLDOUT_BURNED holdout_id must be non-empty")
            existing_holdout = burned_holdout_by_strategy_version.get(strategy_version)
            if existing_holdout is not None:
                raise SystemExit(
                    f"Second pristine holdout burn forbidden for strategy_version={strategy_version}: "
                    f"existing={existing_holdout}, attempted={holdout_id}"
                )
            burned_holdout_by_strategy_version[strategy_version] = holdout_id


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
    # Validate the prospective append before touching the durable ledger. A malformed RESULT or
    # PREREGISTER must never leave the JSONL file in a broken state.
    verify_records([*records, record])
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(record) + "\n")
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
