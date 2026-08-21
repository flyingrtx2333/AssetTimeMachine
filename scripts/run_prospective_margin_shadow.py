#!/usr/bin/env python3
"""Append one frozen prospective FINRA-margin shadow snapshot.

This runner consumes a frozen V11 forward snapshot and a FINRA margin input file. It
clips the margin observations to their conservative available dates at/before the V11
signal_date before invoking the Swift kernel. It never recomputes historical strategy
performance or changes the frozen factor rule.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from run_prospective_factor_shadow import (
    GENESIS,
    canonical_json,
    finite_weight_map,
    make_record,
    record_hash,
    sha256_file,
    target_fingerprint,
    validate_v11_snapshot,
)

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-PROSPECTIVE-MARGIN-001"
PROTOCOL_ID = "ATM-SVP-2"
CANDIDATE_ID = "F-MARGIN-LEV-PROSPECTIVE"
FREEZE_DATE = "2026-08-21"
KERNEL_SOURCES = [
    ROOT / "tools/finra_margin_leverage_v1_logic.swift",
    ROOT / "tools/prospective_margin_shadow_cli.swift",
]


def kernel_source_sha() -> str:
    digest = hashlib.sha256()
    for path in KERNEL_SOURCES:
        digest.update(path.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def compile_kernel() -> Path:
    source_sha = kernel_source_sha()
    binary = Path(f"/private/tmp/atm_prospective_margin_shadow_{source_sha[:16]}")
    if binary.exists():
        return binary
    completed = subprocess.run(
        [
            "xcrun", "swiftc", "-parse-as-library",
            *[str(path.relative_to(ROOT)) for path in KERNEL_SOURCES],
            "-o", str(binary),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"Swift prospective margin kernel compilation failed:\n{completed.stdout}")
    return binary


def read_margin_points(path: Path, *, signal_date: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {
            "reference_month",
            "conservative_available_date",
            "delta_leverage_ratio",
        }
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"FINRA margin input missing columns: {sorted(missing)}")
        prior_reference: str | None = None
        prior_available: str | None = None
        for row in reader:
            reference = str(row["reference_month"])
            available = str(row["conservative_available_date"])
            raw_delta = str(row["delta_leverage_ratio"])
            if prior_reference is not None and reference <= prior_reference:
                raise ValueError("FINRA reference months are not strictly increasing")
            if prior_available is not None and available <= prior_available:
                raise ValueError("FINRA conservative available dates are not strictly increasing")
            prior_reference = reference
            prior_available = available
            if raw_delta == "":
                continue
            delta = float(raw_delta)
            if not math.isfinite(delta):
                raise ValueError(f"non-finite FINRA margin delta: {reference}")
            # Critical causality boundary: rows whose conservative publication date is in
            # the future are not merely marked unavailable; they are not passed to Swift.
            if available > signal_date:
                continue
            rows.append({
                "reference_month": reference,
                "available_date": available,
                "delta_leverage_ratio": delta,
            })
    if not rows:
        raise ValueError("no point-in-time-usable FINRA margin observations")
    return rows


def run_kernel(
    binary: Path,
    *,
    signal_date: str,
    rebalance_recommended: bool,
    prior_base_event_target: dict[str, float] | None,
    current_base_target: dict[str, float],
    prior_candidate_shadow_target: dict[str, float] | None,
    prior_matched_shadow_target: dict[str, float] | None,
    points: list[dict[str, Any]],
) -> dict[str, Any]:
    payload = {
        "signal_date": signal_date,
        "rebalance_recommended": rebalance_recommended,
        "prior_base_event_target": prior_base_event_target,
        "current_base_target": current_base_target,
        "prior_candidate_shadow_target": prior_candidate_shadow_target,
        "prior_matched_shadow_target": prior_matched_shadow_target,
        "points": points,
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8", delete=False) as handle:
        json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
        temp_path = Path(handle.name)
    try:
        completed = subprocess.run(
            [str(binary), str(temp_path)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    finally:
        temp_path.unlink(missing_ok=True)
    if completed.returncode != 0:
        raise RuntimeError(f"Swift prospective margin kernel failed: {completed.stdout}")
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise RuntimeError("Swift prospective margin kernel returned non-object JSON")
    return value


def read_records(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError(f"prospective margin ledger line {line_number} is not an object")
        records.append(value)
    return records


def verify_records(records: list[dict[str, Any]]) -> None:
    previous = GENESIS
    prior_signal: str | None = None
    for sequence, record in enumerate(records, start=1):
        if record.get("sequence") != sequence:
            raise ValueError("prospective margin ledger sequence mismatch")
        if record.get("previous_hash") != previous:
            raise ValueError("prospective margin ledger previous_hash mismatch")
        stored = record.get("record_hash")
        unsigned = dict(record)
        unsigned.pop("record_hash", None)
        if stored != record_hash(unsigned):
            raise ValueError("prospective margin ledger record_hash mismatch")
        payload = record.get("payload")
        if not isinstance(payload, dict) or payload.get("trial_id") != TRIAL_ID:
            raise ValueError("prospective margin ledger trial_id mismatch")
        if payload.get("protocol_id") != PROTOCOL_ID:
            raise ValueError("prospective margin ledger protocol_id mismatch")
        v11 = payload.get("v11")
        if not isinstance(v11, dict):
            raise ValueError("prospective margin ledger missing V11 snapshot")
        validate_v11_snapshot(v11)
        signal_date = str(v11["signal_date"])
        if signal_date < FREEZE_DATE:
            raise ValueError("prospective margin snapshot precedes freeze date")
        if prior_signal is not None and signal_date <= prior_signal:
            raise ValueError("prospective margin signal_date must strictly increase")
        prior_signal = signal_date
        candidate = payload.get("candidate")
        if not isinstance(candidate, dict) or candidate.get("candidate_id") != CANDIDATE_ID:
            raise ValueError("prospective margin candidate identity mismatch")
        candidate_target = finite_weight_map(candidate.get("candidate_target"), label="prospective margin candidate target")
        matched_target = finite_weight_map(candidate.get("matched_control_target"), label="prospective margin matched target")
        if candidate.get("candidate_target_fingerprint") != target_fingerprint(candidate_target):
            raise ValueError("prospective margin candidate target fingerprint mismatch")
        if candidate.get("matched_control_target_fingerprint") != target_fingerprint(matched_target):
            raise ValueError("prospective margin matched target fingerprint mismatch")
        state = payload.get("state")
        if not isinstance(state, dict):
            raise ValueError("prospective margin state missing")
        previous = str(stored)


def current_recorded_at() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def build_payload(
    *,
    v11_snapshot: dict[str, Any],
    factor_input_path: Path,
    prior_record: dict[str, Any] | None,
) -> dict[str, Any]:
    validate_v11_snapshot(v11_snapshot)
    signal_date = str(v11_snapshot["signal_date"])
    if signal_date < FREEZE_DATE:
        raise ValueError(f"signal_date must be on/after prospective margin freeze date {FREEZE_DATE}")
    points = read_margin_points(factor_input_path, signal_date=signal_date)
    prior_state = ((prior_record or {}).get("payload") or {}).get("state") or {}
    prior_base = prior_state.get("prior_v11_event_base_target")
    prior_candidate = prior_state.get("candidate_shadow_target")
    prior_matched = prior_state.get("matched_control_shadow_target")
    current_base = finite_weight_map(v11_snapshot["desired_target_weights"], label="V11 current target")
    output = run_kernel(
        compile_kernel(),
        signal_date=signal_date,
        rebalance_recommended=bool(v11_snapshot.get("rebalance_recommended")),
        prior_base_event_target=prior_base,
        current_base_target=current_base,
        prior_candidate_shadow_target=prior_candidate,
        prior_matched_shadow_target=prior_matched,
        points=points,
    )
    candidate_target = finite_weight_map(output["candidate_target"], label="prospective margin candidate target")
    matched_target = finite_weight_map(output["matched_control_target"], label="prospective margin matched target")
    next_prior = output.get("next_prior_base_event_target")
    if next_prior is not None:
        next_prior = finite_weight_map(next_prior, label="prospective margin next prior V11 event target")
    factor_state = output.get("factor_state")
    if factor_state is not None and not isinstance(factor_state, dict):
        raise RuntimeError("prospective margin factor_state must be object/null")
    return {
        "trial_id": TRIAL_ID,
        "protocol_id": PROTOCOL_ID,
        "v11": v11_snapshot,
        "factor_input": {
            "path": factor_input_path.as_posix(),
            "sha256": sha256_file(factor_input_path),
            "point_count_clipped_to_signal_date": len(points),
            "last_point": points[-1],
        },
        "kernel": {
            "source_sha256": kernel_source_sha(),
            "swift_sources": [path.relative_to(ROOT).as_posix() for path in KERNEL_SOURCES],
        },
        "candidate": {
            "candidate_id": CANDIDATE_ID,
            "factor_state": factor_state,
            "factor_available": bool(output.get("factor_available")),
            "us_derisk_event": bool(output.get("us_derisk_event")),
            "eligible_event": bool(output.get("eligible_event")),
            "intervened": bool(output.get("intervened")),
            "matched_control_intervened": bool(output.get("matched_control_intervened")),
            "candidate_target": candidate_target,
            "candidate_target_fingerprint": target_fingerprint(candidate_target),
            "candidate_gross": sum(candidate_target.values()),
            "matched_control_target": matched_target,
            "matched_control_target_fingerprint": target_fingerprint(matched_target),
            "matched_control_gross": sum(matched_target.values()),
        },
        "state": {
            "prior_v11_event_base_target": next_prior,
            "candidate_shadow_target": candidate_target,
            "matched_control_shadow_target": matched_target,
        },
    }


def append_snapshot(
    *,
    ledger_path: Path,
    v11_snapshot_path: Path,
    factor_input_path: Path,
    recorded_at: str | None = None,
    output_path: Path | None = None,
) -> dict[str, Any]:
    records = read_records(ledger_path)
    verify_records(records)
    snapshot = json.loads(v11_snapshot_path.read_text(encoding="utf-8"))
    if not isinstance(snapshot, dict):
        raise ValueError("V11 snapshot file must contain an object")
    payload = build_payload(
        v11_snapshot=snapshot,
        factor_input_path=factor_input_path,
        prior_record=records[-1] if records else None,
    )
    record = make_record(
        sequence=len(records) + 1,
        previous_hash=records[-1]["record_hash"] if records else GENESIS,
        payload=payload,
        recorded_at=recorded_at or current_recorded_at(),
    )
    verify_records([*records, record])
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    with ledger_path.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(record) + "\n")
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--v11-snapshot", required=True)
    parser.add_argument("--factor-input", required=True)
    parser.add_argument("--ledger", required=True)
    parser.add_argument("--output")
    parser.add_argument("--recorded-at")
    args = parser.parse_args()
    record = append_snapshot(
        ledger_path=Path(args.ledger),
        v11_snapshot_path=Path(args.v11_snapshot),
        factor_input_path=Path(args.factor_input),
        recorded_at=args.recorded_at,
        output_path=Path(args.output) if args.output else None,
    )
    print(
        f"PROSPECTIVE_MARGIN_SHADOW_APPENDED sequence={record['sequence']} "
        f"signal_date={record['payload']['v11']['signal_date']} "
        f"record_hash={record['record_hash']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
