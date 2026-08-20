#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from strategy_validation_ledger import append_record, read_records, verify_records


class StrategyValidationLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.ledger = Path(self.tempdir.name) / "trial-ledger.jsonl"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    @staticmethod
    def preregister_payload(trial_id: str = "TEST-1") -> dict:
        return {
            "trial_id": trial_id,
            "protocol_id": "ATM-SVP-1",
            "strategy_lineage": "nfci-dual-core-v11",
            "hypothesis": "A preregistered mechanism hypothesis.",
            "evidence_class": "D0_EXPOSED",
            "dataset_manifest": "datasets/TEST-1.json",
            "allowed_changes": ["one fixed implementation choice"],
            "candidate_ids": ["candidate-a", "candidate-b"],
            "candidate_count": 2,
            "selection_metric": "highest median fold Sharpe subject to frozen gates",
            "pass_fail_gates": ["both candidate outputs must be reported"],
            "formal_run_budget": 2,
            "follow_up_policy": "No candidate additions after result.",
            "swift_engine_entrypoint": "tools/strategy_metric_dump.swift",
            "expected_outputs": ["candidate metrics", "portfolio series"],
        }

    @staticmethod
    def result_payload(trial_id: str, prereg_hash: str) -> dict:
        return {
            "trial_id": trial_id,
            "preregistration_record_hash": prereg_hash,
            "execution_git_commit": "a" * 40,
            "run_guard_receipt": "runs/TEST-1/run-authorization.json",
            "dataset_manifest": "datasets/TEST-1.json",
            "artifact_manifest": "runs/TEST-1/artifact-manifest.json",
            "status": "PASS",
            "candidate_results": [
                {"candidate_id": "candidate-a", "metrics": {"sharpe": 1.1}},
                {"candidate_id": "candidate-b", "metrics": {"sharpe": 1.2}},
            ],
            "decision": "PASS by preregistered gates.",
            "artifacts": ["candidate-metrics.json"],
        }

    def test_valid_preregister_and_result_chain(self) -> None:
        prereg = append_record(
            self.ledger,
            "PREREGISTER",
            self.preregister_payload(),
            "2026-08-19T12:00:00+08:00",
        )
        append_record(
            self.ledger,
            "RESULT",
            self.result_payload("TEST-1", prereg["record_hash"]),
            "2026-08-19T12:01:00+08:00",
        )
        records = read_records(self.ledger)
        verify_records(records)
        self.assertEqual([row["event"] for row in records], ["PREREGISTER", "RESULT"])

    def test_invalid_preregister_does_not_touch_ledger(self) -> None:
        payload = self.preregister_payload()
        del payload["selection_metric"]
        with self.assertRaises(SystemExit):
            append_record(
                self.ledger,
                "PREREGISTER",
                payload,
                "2026-08-19T12:00:00+08:00",
            )
        self.assertFalse(self.ledger.exists())

    def test_wrong_result_binding_is_rejected_without_corrupting_ledger(self) -> None:
        append_record(
            self.ledger,
            "PREREGISTER",
            self.preregister_payload(),
            "2026-08-19T12:00:00+08:00",
        )
        with self.assertRaises(SystemExit):
            append_record(
                self.ledger,
                "RESULT",
                self.result_payload("TEST-1", "0" * 64),
                "2026-08-19T12:01:00+08:00",
            )
        records = read_records(self.ledger)
        self.assertEqual(len(records), 1)
        verify_records(records)

    def test_result_must_report_exact_candidate_family(self) -> None:
        prereg = append_record(
            self.ledger,
            "PREREGISTER",
            self.preregister_payload(),
            "2026-08-19T12:00:00+08:00",
        )
        payload = self.result_payload("TEST-1", prereg["record_hash"])
        payload["candidate_results"][1]["candidate_id"] = "candidate-c"
        with self.assertRaises(SystemExit):
            append_record(
                self.ledger,
                "RESULT",
                payload,
                "2026-08-19T12:01:00+08:00",
            )
        self.assertEqual(len(read_records(self.ledger)), 1)

    def test_hash_tampering_is_detected(self) -> None:
        append_record(
            self.ledger,
            "PREREGISTER",
            self.preregister_payload(),
            "2026-08-19T12:00:00+08:00",
        )
        record = json.loads(self.ledger.read_text(encoding="utf-8"))
        record["payload"]["hypothesis"] = "tampered after the fact"
        self.ledger.write_text(json.dumps(record) + "\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            verify_records(read_records(self.ledger))

    def test_timestamp_cannot_move_backward(self) -> None:
        append_record(
            self.ledger,
            "PREREGISTER",
            self.preregister_payload("TEST-1"),
            "2026-08-19T12:00:00+08:00",
        )
        with self.assertRaises(SystemExit):
            append_record(
                self.ledger,
                "PREREGISTER",
                self.preregister_payload("TEST-2"),
                "2026-08-19T11:59:59+08:00",
            )
        self.assertEqual(len(read_records(self.ledger)), 1)


if __name__ == "__main__":
    unittest.main()
