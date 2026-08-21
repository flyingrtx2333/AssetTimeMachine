#!/usr/bin/env python3
"""Append one frozen prospective-factor shadow snapshot.

This runner never simulates/optimizes historical performance. It consumes one frozen V11 forward snapshot,
recent factor inputs clipped through that snapshot's signal_date, and the prior append-only shadow state. The
actual factor-state and target transforms are delegated to the frozen Swift kernel.
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

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-PROSPECTIVE-FACTOR-001"
PROTOCOL_ID = "ATM-SVP-2"
FREEZE_DATE = "2026-08-21"
V11_STRATEGY_ID = "nfci-dual-core-v11"
V11_STRATEGY_VERSION = "dualcore-v11-2026-08-15"
GENESIS = "GENESIS"
EXPECTED_V11_SYMBOLS = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
CANDIDATE_SPECS = {
    "F-CREDITCASH-PROSPECTIVE": {"mode": "completion", "numerator": "HYG", "denominator": "SHY"},
    "F-BREADTH-PROSPECTIVE": {"mode": "retention", "numerator": "RSP", "denominator": "SPY"},
    "F-HIGHBETA-PROSPECTIVE": {"mode": "retention", "numerator": "SPHB", "denominator": "SPLV"},
}
KERNEL_SOURCES = [
    ROOT / "tools/orthogonal_event_factor_v3_logic.swift",
    ROOT / "tools/orthogonal_factor_family_v1_logic.swift",
    ROOT / "tools/prospective_factor_shadow_logic.swift",
    ROOT / "tools/prospective_factor_shadow_cli.swift",
]


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def target_fingerprint(weights: dict[str, float]) -> str:
    normalized = {key: round(float(value), 12) for key, value in sorted(weights.items()) if float(value) > 0}
    return sha256_bytes(canonical_json(normalized).encode("utf-8"))[:16]


def record_hash(record_without_hash: dict[str, Any]) -> str:
    return sha256_bytes(canonical_json(record_without_hash).encode("utf-8"))


def make_record(*, sequence: int, previous_hash: str, payload: dict[str, Any], recorded_at: str) -> dict[str, Any]:
    unsigned = {
        "sequence": sequence,
        "recorded_at": recorded_at,
        "payload": payload,
        "previous_hash": previous_hash,
    }
    return {**unsigned, "record_hash": record_hash(unsigned)}


def finite_weight_map(raw: Any, *, label: str) -> dict[str, float]:
    if not isinstance(raw, dict):
        raise ValueError(f"{label} must be an object")
    output: dict[str, float] = {}
    for key, raw_value in raw.items():
        if not isinstance(key, str) or not key:
            raise ValueError(f"{label} contains invalid symbol")
        value = float(raw_value)
        if not math.isfinite(value) or value < -1e-12:
            raise ValueError(f"{label} contains invalid weight for {key}: {raw_value}")
        if value > 0:
            output[key] = value
    gross = sum(output.values())
    if gross > 1.000000001:
        raise ValueError(f"{label} gross exceeds 100%: {gross}")
    return output


def validate_v11_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    if snapshot.get("strategy_id") != V11_STRATEGY_ID:
        raise ValueError("prospective factor shadow requires frozen V11 strategy_id")
    if snapshot.get("strategy_version") != V11_STRATEGY_VERSION:
        raise ValueError("prospective factor shadow requires frozen V11 strategy_version")
    signal_date = snapshot.get("signal_date")
    if not isinstance(signal_date, str) or signal_date < FREEZE_DATE:
        raise ValueError(f"signal_date must be on/after prospective freeze date {FREEZE_DATE}")
    if snapshot.get("data_stale") is True:
        raise ValueError("prospective factor shadow refuses stale V11 market data")
    target = finite_weight_map(snapshot.get("desired_target_weights"), label="V11 desired_target_weights")
    missing = set(EXPECTED_V11_SYMBOLS) - set((snapshot.get("desired_target_weights") or {}).keys())
    if missing:
        raise ValueError(f"V11 snapshot is missing target symbols: {sorted(missing)}")
    expected_gross = float(snapshot.get("desired_gross_exposure"))
    if not math.isfinite(expected_gross) or abs(sum(target.values()) - expected_gross) > 1e-6:
        raise ValueError("V11 desired_gross_exposure does not match target weights")
    if not isinstance(snapshot.get("dataset_hash"), str) or not snapshot["dataset_hash"]:
        raise ValueError("V11 dataset_hash missing")
    if not isinstance(snapshot.get("causal_input_fingerprint"), str) or not snapshot["causal_input_fingerprint"]:
        raise ValueError("V11 causal_input_fingerprint missing")
    return snapshot


def read_shadow_records(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError(f"snapshot ledger line {line_number} is not an object")
        records.append(value)
    return records


def verify_shadow_records(records: list[dict[str, Any]]) -> None:
    previous = GENESIS
    prior_signal: str | None = None
    for expected_sequence, record in enumerate(records, start=1):
        if record.get("sequence") != expected_sequence:
            raise ValueError("snapshot ledger sequence mismatch")
        if record.get("previous_hash") != previous:
            raise ValueError("snapshot ledger previous_hash mismatch")
        stored = record.get("record_hash")
        unsigned = dict(record)
        unsigned.pop("record_hash", None)
        if stored != record_hash(unsigned):
            raise ValueError("snapshot ledger record_hash mismatch")
        payload = record.get("payload")
        if not isinstance(payload, dict) or payload.get("trial_id") != TRIAL_ID:
            raise ValueError("snapshot ledger trial_id mismatch")
        v11 = payload.get("v11")
        if not isinstance(v11, dict):
            raise ValueError("snapshot ledger missing V11 snapshot")
        validate_v11_snapshot(v11)
        signal_date = str(v11["signal_date"])
        if prior_signal is not None and signal_date <= prior_signal:
            raise ValueError("snapshot signal_date must be strictly increasing; duplicates/backfill are forbidden")
        prior_signal = signal_date
        candidates = payload.get("candidates")
        if not isinstance(candidates, dict) or list(candidates) != list(CANDIDATE_SPECS):
            raise ValueError("snapshot candidate set/order drifted")
        state = payload.get("state")
        if not isinstance(state, dict):
            raise ValueError("snapshot state missing")
        for candidate_id in CANDIDATE_SPECS:
            row = candidates[candidate_id]
            if not isinstance(row, dict):
                raise ValueError(f"candidate snapshot missing: {candidate_id}")
            candidate_target = finite_weight_map(row.get("candidate_target"), label=f"{candidate_id} target")
            matched_target = finite_weight_map(row.get("matched_control_target"), label=f"{candidate_id} matched target")
            if row.get("candidate_target_fingerprint") != target_fingerprint(candidate_target):
                raise ValueError(f"candidate target fingerprint mismatch: {candidate_id}")
            if row.get("matched_control_target_fingerprint") != target_fingerprint(matched_target):
                raise ValueError(f"matched target fingerprint mismatch: {candidate_id}")
        previous = str(stored)


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
    binary = Path(f"/private/tmp/atm_prospective_factor_shadow_{source_sha[:16]}")
    if binary.exists():
        return binary
    command = [
        "xcrun", "swiftc", "-parse-as-library",
        *[str(path.relative_to(ROOT)) for path in KERNEL_SOURCES],
        "-o", str(binary),
    ]
    completed = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"Swift shadow kernel compilation failed:\n{completed.stdout}")
    return binary


def read_points(path: Path, *, signal_date: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None or "date" not in reader.fieldnames or "value" not in reader.fieldnames:
            raise ValueError(f"invalid factor CSV columns: {path}")
        prior_day: str | None = None
        for row in reader:
            day = str(row["date"])
            value = float(row["value"])
            if day > signal_date:
                raise ValueError(f"future factor observation in {path}: {day} > {signal_date}")
            if prior_day is not None and day <= prior_day:
                raise ValueError(f"factor dates are not strictly increasing: {path}")
            if not math.isfinite(value) or value <= 0:
                raise ValueError(f"invalid factor value in {path}: {value}")
            rows.append({"date": day, "value": value})
            prior_day = day
    if len(rows) < 21:
        raise ValueError(f"factor CSV has fewer than 21 observations: {path}")
    return rows


def validate_input_manifest(path: Path, *, signal_date: str) -> tuple[dict[str, Any], dict[str, list[dict[str, Any]]]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("trial_id") != TRIAL_ID or document.get("protocol_id") != PROTOCOL_ID:
        raise ValueError("factor input manifest identity mismatch")
    if document.get("signal_date") != signal_date:
        raise ValueError("factor input manifest signal_date does not match V11 snapshot")
    if document.get("future_observations_allowed") is not False:
        raise ValueError("factor input manifest must forbid future observations")
    series_doc = document.get("series")
    if not isinstance(series_doc, dict):
        raise ValueError("factor input manifest missing series")
    expected_series = {spec["numerator"] for spec in CANDIDATE_SPECS.values()}.union(
        spec["denominator"] for spec in CANDIDATE_SPECS.values()
    )
    if set(series_doc) != expected_series:
        raise ValueError("factor input manifest source set drifted")
    points: dict[str, list[dict[str, Any]]] = {}
    for series_id in sorted(expected_series):
        row = series_doc[series_id]
        file_path = Path(row["path"])
        if not file_path.is_absolute():
            file_path = ROOT / file_path
        if not file_path.is_file():
            raise ValueError(f"factor input file missing: {file_path}")
        if row.get("sha256") != sha256_file(file_path):
            raise ValueError(f"factor input SHA mismatch: {series_id}")
        if str(row.get("last_date")) > signal_date:
            raise ValueError(f"factor input manifest contains future last_date: {series_id}")
        points[series_id] = read_points(file_path, signal_date=signal_date)
    return document, points


def run_kernel(
    binary: Path,
    *,
    spec: dict[str, str],
    signal_date: str,
    rebalance_recommended: bool,
    prior_base_event_target: dict[str, float] | None,
    current_base_target: dict[str, float],
    prior_candidate_shadow_target: dict[str, float] | None,
    prior_matched_shadow_target: dict[str, float] | None,
    numerator: list[dict[str, Any]],
    denominator: list[dict[str, Any]],
) -> dict[str, Any]:
    payload = {
        "mode": spec["mode"],
        "signal_date": signal_date,
        "rebalance_recommended": rebalance_recommended,
        "prior_base_event_target": prior_base_event_target,
        "current_base_target": current_base_target,
        "prior_candidate_shadow_target": prior_candidate_shadow_target,
        "prior_matched_shadow_target": prior_matched_shadow_target,
        "numerator": numerator,
        "denominator": denominator,
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8", delete=False) as handle:
        json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
        temp_path = Path(handle.name)
    try:
        completed = subprocess.run([str(binary), str(temp_path)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    finally:
        temp_path.unlink(missing_ok=True)
    if completed.returncode != 0:
        raise RuntimeError(f"Swift shadow kernel failed: {completed.stdout}")
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise RuntimeError("Swift shadow kernel returned non-object JSON")
    return value


def current_recorded_at() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def build_snapshot_payload(
    *,
    v11_snapshot: dict[str, Any],
    input_manifest_path: Path,
    prior_record: dict[str, Any] | None,
) -> dict[str, Any]:
    validate_v11_snapshot(v11_snapshot)
    signal_date = str(v11_snapshot["signal_date"])
    input_manifest, points = validate_input_manifest(input_manifest_path, signal_date=signal_date)
    binary = compile_kernel()
    prior_state = ((prior_record or {}).get("payload") or {}).get("state") or {}
    prior_base = prior_state.get("prior_v11_event_base_target")
    previous_candidate_targets = prior_state.get("candidate_shadow_targets") or {}
    previous_matched_targets = prior_state.get("matched_control_shadow_targets") or {}
    current_base = finite_weight_map(v11_snapshot["desired_target_weights"], label="V11 current base target")
    rebalance = bool(v11_snapshot.get("rebalance_recommended"))

    candidate_rows: dict[str, Any] = {}
    next_base_target = prior_base
    next_candidate_targets: dict[str, dict[str, float]] = {}
    next_matched_targets: dict[str, dict[str, float]] = {}
    for candidate_id, spec in CANDIDATE_SPECS.items():
        output = run_kernel(
            binary,
            spec=spec,
            signal_date=signal_date,
            rebalance_recommended=rebalance,
            prior_base_event_target=prior_base,
            current_base_target=current_base,
            prior_candidate_shadow_target=previous_candidate_targets.get(candidate_id),
            prior_matched_shadow_target=previous_matched_targets.get(candidate_id),
            numerator=points[spec["numerator"]],
            denominator=points[spec["denominator"]],
        )
        candidate_target = finite_weight_map(output["candidate_target"], label=f"{candidate_id} candidate target")
        matched_target = finite_weight_map(output["matched_control_target"], label=f"{candidate_id} matched target")
        candidate_rows[candidate_id] = {
            "mode": spec["mode"],
            "numerator": spec["numerator"],
            "denominator": spec["denominator"],
            "factor_state": output.get("factor_state"),
            "factor_available": bool(output.get("factor_available")),
            "de_risk_event": bool(output.get("de_risk_event")),
            "eligible_event": bool(output.get("eligible_event")),
            "intervened": bool(output.get("intervened")),
            "matched_control_intervened": bool(output.get("matched_control_intervened")),
            "candidate_target": candidate_target,
            "candidate_target_fingerprint": target_fingerprint(candidate_target),
            "candidate_gross": sum(candidate_target.values()),
            "matched_control_target": matched_target,
            "matched_control_target_fingerprint": target_fingerprint(matched_target),
            "matched_control_gross": sum(matched_target.values()),
        }
        next_candidate_targets[candidate_id] = candidate_target
        next_matched_targets[candidate_id] = matched_target
        if spec["mode"] == "retention":
            candidate_next = output.get("next_prior_base_event_target")
            if candidate_next is not None:
                candidate_next = finite_weight_map(candidate_next, label="next prior V11 event target")
                if next_base_target is not None and rebalance and candidate_next != finite_weight_map(current_base, label="current base"):
                    raise RuntimeError("retention kernel next prior base target drifted")
                next_base_target = candidate_next

    if rebalance:
        next_base_target = current_base
    payload = {
        "trial_id": TRIAL_ID,
        "protocol_id": PROTOCOL_ID,
        "v11": v11_snapshot,
        "input_manifest": {
            "path": input_manifest_path.as_posix(),
            "sha256": sha256_file(input_manifest_path),
            "signal_date": input_manifest["signal_date"],
        },
        "kernel": {
            "source_sha256": kernel_source_sha(),
            "swift_sources": [path.relative_to(ROOT).as_posix() for path in KERNEL_SOURCES],
        },
        "candidates": candidate_rows,
        "state": {
            "prior_v11_event_base_target": next_base_target,
            "candidate_shadow_targets": next_candidate_targets,
            "matched_control_shadow_targets": next_matched_targets,
        },
    }
    return payload


def append_snapshot(
    *,
    ledger_path: Path,
    v11_snapshot_path: Path,
    input_manifest_path: Path,
    recorded_at: str | None = None,
    output_path: Path | None = None,
) -> dict[str, Any]:
    records = read_shadow_records(ledger_path)
    verify_shadow_records(records)
    v11_snapshot = json.loads(v11_snapshot_path.read_text(encoding="utf-8"))
    if not isinstance(v11_snapshot, dict):
        raise ValueError("V11 snapshot file must contain an object")
    payload = build_snapshot_payload(
        v11_snapshot=v11_snapshot,
        input_manifest_path=input_manifest_path,
        prior_record=records[-1] if records else None,
    )
    record = make_record(
        sequence=len(records) + 1,
        previous_hash=records[-1]["record_hash"] if records else GENESIS,
        payload=payload,
        recorded_at=recorded_at or current_recorded_at(),
    )
    candidate_records = [*records, record]
    verify_shadow_records(candidate_records)
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
    parser.add_argument("--input-manifest", required=True)
    parser.add_argument("--ledger", required=True)
    parser.add_argument("--output")
    parser.add_argument("--recorded-at")
    args = parser.parse_args()
    record = append_snapshot(
        ledger_path=Path(args.ledger),
        v11_snapshot_path=Path(args.v11_snapshot),
        input_manifest_path=Path(args.input_manifest),
        recorded_at=args.recorded_at,
        output_path=Path(args.output) if args.output else None,
    )
    print(
        f"PROSPECTIVE_FACTOR_SHADOW_APPENDED sequence={record['sequence']} "
        f"signal_date={record['payload']['v11']['signal_date']} record_hash={record['record_hash']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
