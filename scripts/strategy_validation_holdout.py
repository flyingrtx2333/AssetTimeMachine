#!/usr/bin/env python3
"""One-shot pristine-holdout firewall for ATM-SVP-2 G4.

Lifecycle:
  1. Fill a metadata-only draft manifest and produce a local Git exposure scan.
  2. `freeze` turns the draft into FROZEN_UNOPENED and records the parent Git commit.
  3. Commit the frozen manifest and exposure scan.
  4. `burn` permanently reserves this exact holdout in the hash-chained trial ledger BEFORE any
     full return history may be fetched. Commit the burn event.
  5. `authorize-open` only succeeds when the frozen manifest and burn event are both present in the
     current Git HEAD and the worktree is clean.

This deliberately makes a reserved holdout non-reusable even if the later data fetch fails.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from strategy_validation_ledger import (
    DEFAULT_LEDGER,
    append_record,
    canonical_json,
    read_records,
    verify_records,
)

PROTOCOL_ID = "ATM-SVP-2"
STRATEGY_ID = "nfci-dual-core-v11"
STRATEGY_VERSION = "dualcore-v11-2026-08-15"
EXPECTED_ROLES = [
    ("gold_safe_haven", "gold_cny"),
    ("us_growth_equity", "nasdaq"),
    ("us_broad_equity", "sp500"),
    ("china_large_equity", "csi300"),
    ("china_broad_equity", "shanghai_composite"),
]
ROLE_ENGINE_REQUIREMENTS = {
    "gold_safe_haven": ("atm_g4_gold_safe_haven", "CNY", "gram"),
    "us_growth_equity": ("atm_g4_us_growth_equity", "USD", "index"),
    "us_broad_equity": ("atm_g4_us_broad_equity", "USD", "index"),
    "china_large_equity": ("atm_g4_china_large_equity", "CNY", "index"),
    "china_broad_equity": ("atm_g4_china_broad_equity", "CNY", "index"),
}
EXPECTED_PASS_FORMULAS = {
    "reference": "same common evaluation window identity baseline frozen before HOLDOUT_BURNED",
    "common_reference_cagr": "> 0",
    "common_reference_sharpe": "> 0",
    "common_reference_mdd_max": "25%",
    "positive_one_slot_sharpe_count_min": 4,
    "one_slot_median_sharpe_min": "0.50 * common_window_identity_sharpe",
    "all_alternate_cagr": "> 0",
    "all_alternate_sharpe_min": "0.50 * common_window_identity_sharpe",
    "all_alternate_mdd_max": "min(25%, 1.25 * common_window_identity_mdd)",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"Expected JSON object: {path}")
    return value


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def current_head() -> str:
    return git("rev-parse", "HEAD").stdout.strip()


def require_clean_worktree() -> None:
    status = git("status", "--porcelain").stdout.strip()
    if status:
        raise SystemExit(
            "Holdout operation refused: worktree is not clean. Commit all governance/manifests "
            "before crossing an irreversible holdout boundary."
        )


def parse_iso_date(raw: Any, label: str) -> date:
    if not isinstance(raw, str):
        raise SystemExit(f"{label} must be YYYY-MM-DD")
    try:
        return date.fromisoformat(raw)
    except ValueError as error:
        raise SystemExit(f"{label} must be YYYY-MM-DD: {raw}") from error


def validate_exposure_scan(manifest: dict[str, Any], manifest_path: Path) -> dict[str, Any]:
    raw_path = manifest.get("local_exposure_scan")
    if not isinstance(raw_path, str) or not raw_path:
        raise SystemExit("Manifest local_exposure_scan must be a non-empty path")
    scan_path = Path(raw_path)
    if not scan_path.exists():
        raise SystemExit(f"Exposure scan missing: {scan_path}")
    scan = read_json(scan_path)
    if scan.get("protocol_id") != PROTOCOL_ID:
        raise SystemExit("Exposure scan protocol mismatch")
    if scan.get("scan_type") != "LOCAL_GIT_EXPOSURE_LOWER_BOUND":
        raise SystemExit("Unexpected exposure scan type")
    if scan.get("all_locally_unexposed") is not True:
        raise SystemExit("At least one holdout candidate is already locally exposed")
    scan_rows = scan.get("candidates")
    if not isinstance(scan_rows, list):
        raise SystemExit("Exposure scan candidates missing")
    scan_by_role = {row.get("role"): row for row in scan_rows if isinstance(row, dict)}
    for slot in manifest["role_slots"]:
        row = scan_by_role.get(slot["role"])
        if row is None:
            raise SystemExit(f"Exposure scan missing role={slot['role']}")
        if (
            row.get("source") != slot["alternate_source"]
            or row.get("source_series_id") != slot["source_series_id"]
        ):
            raise SystemExit(f"Exposure scan candidate mismatch for role={slot['role']}")
        if row.get("locally_unexposed") is not True:
            raise SystemExit(f"Exposure scan marks role={slot['role']} as exposed")
    # The draft/frozen manifest may be excluded from current grep, but it did not exist in the
    # scan's parent Git history. Preserve the explicit path for auditability.
    if manifest_path.as_posix() not in set(scan.get("excludes", [])):
        raise SystemExit("Exposure scan must explicitly exclude the holdout manifest itself")
    return scan


def validate_manifest(manifest: dict[str, Any], manifest_path: Path, allowed_statuses: set[str]) -> None:
    if manifest.get("protocol_id") != PROTOCOL_ID:
        raise SystemExit("Holdout protocol_id mismatch")
    if manifest.get("strategy_id") != STRATEGY_ID or manifest.get("strategy_version") != STRATEGY_VERSION:
        raise SystemExit("Holdout strategy identity mismatch")
    if manifest.get("status") not in allowed_statuses:
        raise SystemExit(f"Unexpected holdout status: {manifest.get('status')}")
    if manifest.get("metadata_only_selection") is not True:
        raise SystemExit("Holdout selection must be metadata-only")
    if manifest.get("full_return_history_viewed_before_freeze") is not False:
        raise SystemExit("Holdout is not pristine: full_return_history_viewed_before_freeze must be false")

    slots = manifest.get("role_slots")
    if not isinstance(slots, list) or len(slots) != len(EXPECTED_ROLES):
        raise SystemExit("Holdout must contain exactly five role slots")
    expected = dict(EXPECTED_ROLES)
    seen_roles: set[str] = set()
    seen_alternates: set[tuple[str, str]] = set()
    seen_normalized_symbols: set[str] = set()
    coverage_starts: list[date] = []
    coverage_ends: list[date] = []
    for slot in slots:
        if not isinstance(slot, dict):
            raise SystemExit("Holdout role slot must be an object")
        role = slot.get("role")
        if role not in expected or role in seen_roles:
            raise SystemExit(f"Unexpected/duplicate holdout role: {role}")
        seen_roles.add(str(role))
        if slot.get("current_symbol") != expected[role]:
            raise SystemExit(f"Current role symbol drift for {role}")
        source = slot.get("alternate_source")
        source_series_id = slot.get("source_series_id")
        symbol = slot.get("alternate_symbol")
        if (
            not isinstance(source, str) or not source.strip()
            or not isinstance(source_series_id, str) or not source_series_id.strip()
            or not isinstance(symbol, str) or not symbol.strip()
        ):
            raise SystemExit(f"Alternate source/source_series_id/raw symbol missing for role={role}")
        if symbol.casefold() == str(slot["current_symbol"]).casefold():
            raise SystemExit(f"Raw alternate symbol equals current role symbol for role={role}")
        if not symbol.startswith("g4_raw_"):
            raise SystemExit(f"Raw alternate symbol must use g4_raw_* namespace for role={role}")
        key = (source.casefold(), source_series_id.casefold())
        if key in seen_alternates:
            raise SystemExit(f"Duplicate alternate source series: {source}:{source_series_id}")
        seen_alternates.add(key)

        expected_normalized, expected_currency, expected_unit = ROLE_ENGINE_REQUIREMENTS[str(role)]
        normalized_symbol = slot.get("normalized_fixture_symbol")
        if normalized_symbol != expected_normalized:
            raise SystemExit(
                f"normalized_fixture_symbol drift for role={role}: expected={expected_normalized}, got={normalized_symbol}"
            )
        if normalized_symbol in seen_normalized_symbols:
            raise SystemExit(f"Duplicate normalized_fixture_symbol: {normalized_symbol}")
        seen_normalized_symbols.add(str(normalized_symbol))
        if slot.get("engine_input_currency") != expected_currency or slot.get("engine_input_unit") != expected_unit:
            raise SystemExit(
                f"Engine input unit/currency drift for role={role}: expected={expected_currency}/{expected_unit}"
            )
        for key_name in ["source_currency", "source_unit", "source_frequency", "normalization_rule"]:
            value = slot.get(key_name)
            if not isinstance(value, str) or not value.strip():
                raise SystemExit(f"{key_name} must be non-empty for role={role}")
        if slot["source_frequency"].casefold() != "daily":
            raise SystemExit(f"G4 alternate must be daily for role={role}")
        normalization_inputs = slot.get("normalization_inputs")
        if not isinstance(normalization_inputs, list) or not all(isinstance(x, str) and x.strip() for x in normalization_inputs):
            raise SystemExit(f"normalization_inputs must be a string list for role={role}")
        if slot["normalization_rule"].casefold() == "identity":
            if slot["source_currency"] != expected_currency or slot["source_unit"] != expected_unit:
                raise SystemExit(
                    f"identity normalization is invalid for role={role}: source units do not match engine input"
                )
        elif not normalization_inputs:
            raise SystemExit(f"Non-identity normalization must declare inputs for role={role}")

        if slot.get("metadata_checked") is not True:
            raise SystemExit(f"metadata_checked must be true for role={role}")
        start = parse_iso_date(slot.get("metadata_coverage_start"), f"{role}.metadata_coverage_start")
        end = parse_iso_date(slot.get("metadata_coverage_end"), f"{role}.metadata_coverage_end")
        if start >= end:
            raise SystemExit(f"Invalid metadata coverage for role={role}")
        coverage_starts.append(start)
        coverage_ends.append(end)
        reason = slot.get("selection_reason_without_return_performance")
        if not isinstance(reason, str) or len(reason.strip()) < 20:
            raise SystemExit(f"Selection reason is too weak/missing for role={role}")
        evidence = slot.get("metadata_evidence")
        if not isinstance(evidence, list) or not evidence or not all(isinstance(x, str) and x.strip() for x in evidence):
            raise SystemExit(f"metadata_evidence must be a non-empty string list for role={role}")
        forbidden = {"sharpe", "cagr", "mdd", "return", "returns", "performance", "drawdown"}
        illegal = forbidden.intersection(slot.keys())
        if illegal:
            raise SystemExit(f"Performance field(s) forbidden in metadata-only role={role}: {sorted(illegal)}")

    if set(seen_roles) != set(expected):
        raise SystemExit("Holdout role set mismatch")
    evaluation_window = manifest.get("evaluation_window")
    if not isinstance(evaluation_window, dict) or evaluation_window.get("rule") != "intersection_of_all_role_metadata_coverage":
        raise SystemExit("G4 evaluation_window rule must be intersection_of_all_role_metadata_coverage")
    expected_start = max(coverage_starts).isoformat()
    expected_end = min(coverage_ends).isoformat()
    if expected_start >= expected_end:
        raise SystemExit(f"G4 role coverage has no usable common intersection: {expected_start}..{expected_end}")
    if manifest.get("status") == "DRAFT_NOT_FROZEN":
        if evaluation_window.get("start") is not None or evaluation_window.get("end") is not None:
            raise SystemExit("Draft evaluation_window start/end must remain null; freeze derives them mechanically")
    else:
        if evaluation_window.get("start") != expected_start or evaluation_window.get("end") != expected_end:
            raise SystemExit(
                f"Frozen evaluation window drifted: expected={expected_start}..{expected_end}, "
                f"got={evaluation_window.get('start')}..{evaluation_window.get('end')}"
            )
    budget = manifest.get("formal_run_budget")
    if budget != {
        "one_slot_substitutions": 5,
        "all_alternate_basket": 1,
        "total": 6,
        "additional_runs_after_results": 0,
    }:
        raise SystemExit("Formal G4 run budget drifted")
    if manifest.get("pass_formulas") != EXPECTED_PASS_FORMULAS:
        raise SystemExit("ATM-SVP-2 G4 pass formulas drifted")
    validate_exposure_scan(manifest, manifest_path)


def selection_payload(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
        "holdout_id": manifest["holdout_id"],
        "protocol_id": manifest["protocol_id"],
        "strategy_id": manifest["strategy_id"],
        "strategy_version": manifest["strategy_version"],
        "evaluation_window": manifest["evaluation_window"],
        "role_slots": manifest["role_slots"],
        "formal_run_budget": manifest["formal_run_budget"],
        "pass_formulas": manifest["pass_formulas"],
        "failure_rule": manifest["failure_rule"],
        "local_exposure_scan": manifest["local_exposure_scan"],
    }


def cmd_validate(args: argparse.Namespace) -> None:
    path = Path(args.manifest)
    manifest = read_json(path)
    validate_manifest(manifest, path, {"DRAFT_NOT_FROZEN", "FROZEN_UNOPENED"})
    print(f"HOLDOUT_MANIFEST_VALID status={manifest['status']} holdout_id={manifest['holdout_id']}")


def cmd_freeze(args: argparse.Namespace) -> None:
    path = Path(args.manifest)
    manifest = read_json(path)
    validate_manifest(manifest, path, {"DRAFT_NOT_FROZEN"})
    if manifest.get("freeze_git_ref") is not None or manifest.get("frozen_at") is not None:
        raise SystemExit("Draft already contains freeze metadata")
    evaluation_start = max(slot["metadata_coverage_start"] for slot in manifest["role_slots"])
    evaluation_end = min(slot["metadata_coverage_end"] for slot in manifest["role_slots"])
    if evaluation_start >= evaluation_end:
        raise SystemExit(f"Cannot freeze empty G4 evaluation intersection: {evaluation_start}..{evaluation_end}")
    manifest["evaluation_window"]["start"] = evaluation_start
    manifest["evaluation_window"]["end"] = evaluation_end
    manifest["status"] = "FROZEN_UNOPENED"
    manifest["freeze_git_ref"] = current_head()
    manifest["frozen_at"] = now_iso()
    manifest["selection_payload_sha256"] = sha256_bytes(canonical_json(selection_payload(manifest)).encode("utf-8"))
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"HOLDOUT_FROZEN holdout_id={manifest['holdout_id']} parent_git_ref={manifest['freeze_git_ref']} "
        f"selection_payload_sha256={manifest['selection_payload_sha256']}"
    )
    print("Commit the frozen manifest and exposure scan before burning/opening the holdout.")


def manifest_committed_in_head(path: Path) -> dict[str, Any]:
    local_bytes = path.read_bytes()
    result = git("show", f"HEAD:{path.as_posix()}", check=False)
    if result.returncode != 0:
        raise SystemExit(f"Frozen holdout manifest is not committed in HEAD: {path}")
    committed_bytes = result.stdout.encode("utf-8")
    if committed_bytes != local_bytes:
        raise SystemExit("Frozen holdout manifest differs from the exact version committed in HEAD")
    return read_json(path)


def burn_records(records: list[dict[str, Any]], holdout_id: str) -> list[dict[str, Any]]:
    return [
        row for row in records
        if row.get("event") == "HOLDOUT_BURNED"
        and isinstance(row.get("payload"), dict)
        and row["payload"].get("holdout_id") == holdout_id
    ]


def cmd_burn(args: argparse.Namespace) -> None:
    require_clean_worktree()
    path = Path(args.manifest)
    manifest = manifest_committed_in_head(path)
    validate_manifest(manifest, path, {"FROZEN_UNOPENED"})
    records = read_records(Path(args.ledger))
    verify_records(records)
    existing = burn_records(records, str(manifest["holdout_id"]))
    if existing:
        raise SystemExit(f"Holdout is already permanently burned: {manifest['holdout_id']}")
    selection_hash = manifest.get("selection_payload_sha256")
    expected_hash = sha256_bytes(canonical_json(selection_payload(manifest)).encode("utf-8"))
    if selection_hash != expected_hash:
        raise SystemExit("Frozen holdout selection payload hash mismatch")
    payload = {
        "protocol_id": PROTOCOL_ID,
        "holdout_id": manifest["holdout_id"],
        "strategy_id": STRATEGY_ID,
        "strategy_version": STRATEGY_VERSION,
        "manifest_path": path.as_posix(),
        "manifest_sha256": sha256_file(path),
        "selection_payload_sha256": selection_hash,
        "frozen_manifest_git_commit": current_head(),
        "permanent": True,
        "rule": "This exact role-holdout set is permanently reserved before any full return history is opened. It may not be replaced for V11 after burn, regardless of fetch/run success.",
    }
    record = append_record(Path(args.ledger), "HOLDOUT_BURNED", payload, None)
    print(
        f"HOLDOUT_BURNED_APPEND holdout_id={manifest['holdout_id']} record_hash={record['record_hash']}"
    )
    print("Commit the HOLDOUT_BURNED ledger event before any full-history fetch is authorized.")


def committed_ledger_records(path: Path) -> list[dict[str, Any]]:
    result = git("show", f"HEAD:{path.as_posix()}", check=False)
    if result.returncode != 0:
        raise SystemExit(f"Ledger is not committed in HEAD: {path}")
    records = []
    for line in result.stdout.splitlines():
        if line.strip():
            value = json.loads(line)
            if not isinstance(value, dict):
                raise SystemExit("Committed ledger contains a non-object record")
            records.append(value)
    verify_records(records)
    return records


def cmd_authorize_open(args: argparse.Namespace) -> None:
    require_clean_worktree()
    path = Path(args.manifest)
    manifest = manifest_committed_in_head(path)
    validate_manifest(manifest, path, {"FROZEN_UNOPENED"})
    ledger_path = Path(args.ledger)
    local_records = read_records(ledger_path)
    verify_records(local_records)
    committed_records = committed_ledger_records(ledger_path)
    local_burn = burn_records(local_records, str(manifest["holdout_id"]))
    committed_burn = burn_records(committed_records, str(manifest["holdout_id"]))
    if len(local_burn) != 1 or len(committed_burn) != 1:
        raise SystemExit("Full-history opening refused: exactly one HOLDOUT_BURNED event must be committed in HEAD")
    if local_burn[0]["record_hash"] != committed_burn[0]["record_hash"]:
        raise SystemExit("Local and committed HOLDOUT_BURNED records differ")
    payload = committed_burn[0]["payload"]
    if payload.get("manifest_sha256") != sha256_file(path):
        raise SystemExit("Committed burn event does not bind to the current frozen manifest")
    subprocess.run(["python3", "scripts/validate_strategy_protocol.py"], check=True)
    receipt = {
        "protocol_id": PROTOCOL_ID,
        "holdout_id": manifest["holdout_id"],
        "strategy_version": STRATEGY_VERSION,
        "authorization_git_commit": current_head(),
        "frozen_manifest_path": path.as_posix(),
        "frozen_manifest_sha256": sha256_file(path),
        "holdout_burn_record_hash": committed_burn[0]["record_hash"],
        "selection_payload_sha256": manifest["selection_payload_sha256"],
        "authorized_at": now_iso(),
        "scope": "One-time full-history opening for the six preregistered ATM-SVP-2 G4 role-preserving runs only.",
    }
    output = Path(args.receipt)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"HOLDOUT_OPEN_AUTHORIZED holdout_id={manifest['holdout_id']} "
        f"burn_record_hash={committed_burn[0]['record_hash']} receipt={output}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate")
    validate.add_argument("--manifest", required=True)
    validate.set_defaults(func=cmd_validate)
    freeze = sub.add_parser("freeze")
    freeze.add_argument("--manifest", required=True)
    freeze.set_defaults(func=cmd_freeze)
    burn = sub.add_parser("burn")
    burn.add_argument("--manifest", required=True)
    burn.set_defaults(func=cmd_burn)
    authorize = sub.add_parser("authorize-open")
    authorize.add_argument("--manifest", required=True)
    authorize.add_argument("--receipt", required=True)
    authorize.set_defaults(func=cmd_authorize_open)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
