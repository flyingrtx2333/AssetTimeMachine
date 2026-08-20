#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from build_g4_role_fixture import G4_BASE_REQUIRED_SYMBOLS, build_fixture
from strategy_validation_holdout import EXPECTED_PASS_FORMULAS, EXPECTED_ROLES, ROLE_ENGINE_REQUIREMENTS, validate_manifest


class G4RoleFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.manifest_path = self.root / "manifest.json"
        self.scan_path = self.root / "scan.json"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def make_manifest(self) -> dict:
        roles = []
        scan_rows = []
        for index, (role, current_symbol) in enumerate(EXPECTED_ROLES, start=1):
            normalized_symbol, currency, unit = ROLE_ENGINE_REQUIREMENTS[role]
            source_series_id = f"SOURCE_ALT_{index}"
            raw_symbol = f"g4_raw_fixture_{index}"
            roles.append({
                "role": role,
                "current_symbol": current_symbol,
                "alternate_source": f"source-{index}",
                "source_series_id": source_series_id,
                "alternate_symbol": raw_symbol,
                "source_currency": currency,
                "source_unit": unit,
                "source_frequency": "daily",
                "normalized_fixture_symbol": normalized_symbol,
                "engine_input_currency": currency,
                "engine_input_unit": unit,
                "normalization_rule": "identity",
                "normalization_inputs": [],
                "metadata_checked": True,
                "metadata_coverage_start": "2000-01-01",
                "metadata_coverage_end": "2026-08-01",
                "selection_reason_without_return_performance": "Chosen using role, publisher, frequency and coverage metadata only.",
                "metadata_evidence": [f"metadata://source-{index}/{raw_symbol}"],
            })
            scan_rows.append({
                "role": role,
                "source": f"source-{index}",
                "source_series_id": source_series_id,
                "current_tracked_matches": [],
                "historical_match_commits": [],
                "locally_unexposed": True,
            })
        self.scan_path.write_text(json.dumps({
            "protocol_id": "ATM-SVP-2",
            "scan_type": "LOCAL_GIT_EXPOSURE_LOWER_BOUND",
            "all_locally_unexposed": True,
            "candidates": scan_rows,
            "excludes": [self.manifest_path.as_posix()],
        }), encoding="utf-8")
        manifest = {
            "holdout_id": "TEST-HOLDOUT",
            "protocol_id": "ATM-SVP-2",
            "strategy_id": "nfci-dual-core-v11",
            "strategy_version": "dualcore-v11-2026-08-15",
            "status": "DRAFT_NOT_FROZEN",
            "metadata_only_selection": True,
            "full_return_history_viewed_before_freeze": False,
            "freeze_git_ref": None,
            "frozen_at": None,
            "selection_payload_sha256": None,
            "local_exposure_scan": self.scan_path.as_posix(),
            "evaluation_window": {
                "rule": "intersection_of_all_role_metadata_coverage",
                "start": None,
                "end": None,
            },
            "role_slots": roles,
            "formal_run_budget": {
                "one_slot_substitutions": 5,
                "all_alternate_basket": 1,
                "total": 6,
                "additional_runs_after_results": 0,
            },
            "pass_formulas": dict(EXPECTED_PASS_FORMULAS),
            "failure_rule": "Permanent one-shot holdout.",
        }
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        return manifest

    @staticmethod
    def series(symbol: str, currency: str, unit: str) -> dict:
        return {
            "symbol": symbol,
            "category": "test",
            "label": symbol,
            "currency": currency,
            "unit": unit,
            "source": "test-source",
            "dates": ["2020-01-01", "2020-01-02", "2020-01-03"],
            "prices": [100.0, 101.0, 102.0],
            "has_ohlc": False,
            "ohlc_source": None,
            "ohlc_coverage_ratio": 0.0,
            "open_prices": None,
            "high_prices": None,
            "low_prices": None,
            "close_prices": None,
            "volumes": None,
        }

    def make_raw_document(self, manifest: dict) -> dict:
        rows = []
        for slot in manifest["role_slots"]:
            rows.append(self.series(slot["alternate_symbol"], slot["source_currency"], slot["source_unit"]))
        return {"success": True, "symbols": [row["symbol"] for row in rows], "series": rows}

    def make_base_document(self) -> dict:
        rows = []
        for symbol in sorted(G4_BASE_REQUIRED_SYMBOLS):
            if symbol == "gold_cny":
                currency, unit = "CNY", "gram"
            elif symbol in {"nasdaq_composite", "sp500"}:
                currency, unit = "USD", "index"
            else:
                currency, unit = "CNY", "index"
            rows.append(self.series(symbol, currency, unit))
        return {"success": True, "symbols": [row["symbol"] for row in rows], "series": rows}

    def test_identity_normalization_uses_neutral_role_symbols(self) -> None:
        manifest = self.make_manifest()
        validate_manifest(manifest, self.manifest_path, {"DRAFT_NOT_FROZEN"})
        raw_path = self.root / "raw.json"
        raw_document = self.make_raw_document(manifest)
        raw_path.write_text(json.dumps(raw_document), encoding="utf-8")
        output = build_fixture(
            self.make_base_document(),
            manifest,
            [(raw_path, raw_document)],
        )
        by_symbol = {row["symbol"]: row for row in output["series"]}
        for role, _ in EXPECTED_ROLES:
            normalized_symbol, currency, unit = ROLE_ENGINE_REQUIREMENTS[role]
            self.assertIn(normalized_symbol, by_symbol)
            self.assertEqual(by_symbol[normalized_symbol]["currency"], currency)
            self.assertEqual(by_symbol[normalized_symbol]["unit"], unit)
            self.assertEqual(by_symbol[normalized_symbol]["normalization"]["rule"], "identity")

    def test_identity_rejects_raw_currency_mismatch(self) -> None:
        manifest = self.make_manifest()
        raw_path = self.root / "raw.json"
        raw_document = self.make_raw_document(manifest)
        raw_document["series"][0]["currency"] = "USD"
        raw_path.write_text(json.dumps(raw_document), encoding="utf-8")
        with self.assertRaises(SystemExit):
            build_fixture(self.make_base_document(), manifest, [(raw_path, raw_document)])

    def test_unimplemented_normalization_rule_is_rejected(self) -> None:
        manifest = self.make_manifest()
        manifest["role_slots"][0]["normalization_rule"] = "usd_per_oz_to_cny_per_gram"
        manifest["role_slots"][0]["normalization_inputs"] = ["usd_per_cny"]
        raw_path = self.root / "raw.json"
        raw_document = self.make_raw_document(manifest)
        raw_path.write_text(json.dumps(raw_document), encoding="utf-8")
        with self.assertRaises(SystemExit):
            build_fixture(self.make_base_document(), manifest, [(raw_path, raw_document)])


if __name__ == "__main__":
    unittest.main()
