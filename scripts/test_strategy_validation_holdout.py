#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from strategy_validation_holdout import EXPECTED_ROLES, burn_records, selection_payload, validate_manifest
from strategy_validation_ledger import append_record, read_records, verify_records


class StrategyValidationHoldoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.manifest_path = self.root / "holdout.json"
        self.scan_path = self.root / "scan.json"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def make_manifest(self) -> dict:
        roles = []
        scan_rows = []
        for index, (role, current) in enumerate(EXPECTED_ROLES, start=1):
            source = f"metadata-source-{index}"
            symbol = f"PRISTINE_ALT_{index}"
            roles.append({
                "role": role,
                "current_symbol": current,
                "alternate_source": source,
                "alternate_symbol": symbol,
                "metadata_checked": True,
                "metadata_coverage_start": "2000-01-01",
                "metadata_coverage_end": "2026-08-01",
                "selection_reason_without_return_performance": "Chosen from role definition and date/frequency metadata only.",
                "metadata_evidence": [f"metadata://{source}/{symbol}"],
            })
            scan_rows.append({
                "role": role,
                "source": source,
                "symbol": symbol,
                "current_tracked_matches": [],
                "historical_match_commits": [],
                "locally_unexposed": True,
            })
        scan = {
            "protocol_id": "ATM-SVP-1",
            "scan_type": "LOCAL_GIT_EXPOSURE_LOWER_BOUND",
            "all_locally_unexposed": True,
            "candidates": scan_rows,
            "excludes": [self.manifest_path.as_posix()],
        }
        self.scan_path.write_text(json.dumps(scan), encoding="utf-8")
        return {
            "holdout_id": "ATM-SVP1-G4-ROLE-HOLDOUT-TEST",
            "protocol_id": "ATM-SVP-1",
            "strategy_id": "nfci-dual-core-v11",
            "strategy_version": "dualcore-v11-2026-08-15",
            "status": "DRAFT_NOT_FROZEN",
            "metadata_only_selection": True,
            "full_return_history_viewed_before_freeze": False,
            "freeze_git_ref": None,
            "frozen_at": None,
            "selection_payload_sha256": None,
            "local_exposure_scan": self.scan_path.as_posix(),
            "role_slots": roles,
            "formal_run_budget": {
                "one_slot_substitutions": 5,
                "all_alternate_basket": 1,
                "total": 6,
                "additional_runs_after_results": 0,
            },
            "pass_formulas": {
                "positive_one_slot_sharpe_count_min": 4,
                "one_slot_median_sharpe_min": "0.50 * frozen_baseline_sharpe",
                "all_alternate_cagr": "> 0",
                "all_alternate_sharpe_min": "0.50 * frozen_baseline_sharpe",
                "all_alternate_mdd_max": "2.00 * frozen_baseline_mdd",
            },
            "failure_rule": "After the first formal run, this holdout is permanently exposed and may not be replaced.",
        }

    def write_manifest(self, manifest: dict) -> None:
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    def test_valid_metadata_only_manifest(self) -> None:
        manifest = self.make_manifest()
        self.write_manifest(manifest)
        validate_manifest(manifest, self.manifest_path, {"DRAFT_NOT_FROZEN"})
        payload = selection_payload(manifest)
        self.assertEqual(len(payload["role_slots"]), 5)

    def test_exposed_candidate_is_rejected(self) -> None:
        manifest = self.make_manifest()
        scan = json.loads(self.scan_path.read_text(encoding="utf-8"))
        scan["all_locally_unexposed"] = False
        scan["candidates"][0]["locally_unexposed"] = False
        scan["candidates"][0]["historical_match_commits"] = ["a" * 40]
        self.scan_path.write_text(json.dumps(scan), encoding="utf-8")
        self.write_manifest(manifest)
        with self.assertRaises(SystemExit):
            validate_manifest(manifest, self.manifest_path, {"DRAFT_NOT_FROZEN"})

    def test_performance_field_is_forbidden_in_role_metadata(self) -> None:
        manifest = self.make_manifest()
        manifest["role_slots"][0]["sharpe"] = 1.0
        self.write_manifest(manifest)
        with self.assertRaises(SystemExit):
            validate_manifest(manifest, self.manifest_path, {"DRAFT_NOT_FROZEN"})

    def test_duplicate_alternate_series_is_rejected(self) -> None:
        manifest = self.make_manifest()
        manifest["role_slots"][1]["alternate_source"] = manifest["role_slots"][0]["alternate_source"]
        manifest["role_slots"][1]["alternate_symbol"] = manifest["role_slots"][0]["alternate_symbol"]
        self.write_manifest(manifest)
        with self.assertRaises(SystemExit):
            validate_manifest(manifest, self.manifest_path, {"DRAFT_NOT_FROZEN"})

    def test_burn_record_lookup_is_holdout_specific(self) -> None:
        records = [
            {"event": "HOLDOUT_BURNED", "payload": {"holdout_id": "A"}},
            {"event": "HOLDOUT_BURNED", "payload": {"holdout_id": "B"}},
            {"event": "RESULT", "payload": {"holdout_id": "A"}},
        ]
        self.assertEqual(len(burn_records(records, "A")), 1)
        self.assertEqual(len(burn_records(records, "B")), 1)
        self.assertEqual(len(burn_records(records, "C")), 0)

    @staticmethod
    def holdout_burn_payload(holdout_id: str) -> dict:
        return {
            "protocol_id": "ATM-SVP-1",
            "holdout_id": holdout_id,
            "strategy_id": "nfci-dual-core-v11",
            "strategy_version": "dualcore-v11-2026-08-15",
            "manifest_path": f"holdouts/{holdout_id}.json",
            "manifest_sha256": "a" * 64,
            "selection_payload_sha256": "b" * 64,
            "frozen_manifest_git_commit": "c" * 40,
            "permanent": True,
            "rule": "Permanently reserve this holdout before opening full history.",
        }

    def test_second_holdout_burn_for_same_strategy_version_is_rejected(self) -> None:
        ledger = self.root / "burn-ledger.jsonl"
        append_record(
            ledger,
            "HOLDOUT_BURNED",
            self.holdout_burn_payload("HOLDOUT-A"),
            "2026-08-19T12:00:00+08:00",
        )
        with self.assertRaises(SystemExit):
            append_record(
                ledger,
                "HOLDOUT_BURNED",
                self.holdout_burn_payload("HOLDOUT-B"),
                "2026-08-19T12:01:00+08:00",
            )
        records = read_records(ledger)
        self.assertEqual(len(records), 1)
        verify_records(records)


if __name__ == "__main__":
    unittest.main()
