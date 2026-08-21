#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from run_prospective_factor_shadow import (
    CANDIDATE_SPECS,
    GENESIS,
    make_record,
    target_fingerprint,
    validate_v11_snapshot,
    verify_shadow_records,
)


class ProspectiveFactorShadowRunnerTests(unittest.TestCase):
    @staticmethod
    def snapshot(signal_date: str = "2026-08-21") -> dict:
        return {
            "strategy_id": "nfci-dual-core-v11",
            "strategy_version": "dualcore-v11-2026-08-15",
            "strategy_name": "NFCI 双核心·简化（前瞻）",
            "frozen_at": "2026-08-15",
            "decision_at": "2026-08-21T22:00:00Z",
            "signal_date": signal_date,
            "execution_date_hint": "2026-08-24",
            "data_cutoff": signal_date,
            "dataset_hash": "a" * 64,
            "engine_version": "test-engine",
            "data_stale": False,
            "desired_target_weights": {
                "gold_cny": 0.2,
                "nasdaq": 0.2,
                "sp500": 0.1,
                "csi300": 0.0,
                "shanghai_composite": 0.0,
            },
            "desired_cash_weight": 0.5,
            "desired_gross_exposure": 0.5,
            "model_executed_weights": {},
            "model_cash_weight": 1.0,
            "model_gross_exposure": 0.0,
            "rebalance_recommended": False,
            "target_fingerprint": "deadbeefdeadbeef",
            "causal_input_fingerprint": "cafebabecafebabe",
            "nfci": {"source": "test"},
        }

    def test_candidate_set_is_exactly_preregistered(self) -> None:
        self.assertEqual(
            list(CANDIDATE_SPECS),
            [
                "F-CREDITCASH-PROSPECTIVE",
                "F-BREADTH-PROSPECTIVE",
                "F-HIGHBETA-PROSPECTIVE",
            ],
        )

    def test_snapshot_before_freeze_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            validate_v11_snapshot(self.snapshot("2026-08-20"))

    def test_snapshot_wrong_strategy_is_rejected(self) -> None:
        snapshot = self.snapshot()
        snapshot["strategy_id"] = "nfci-dual-core-v1"
        with self.assertRaises(ValueError):
            validate_v11_snapshot(snapshot)

    def test_target_fingerprint_is_order_independent(self) -> None:
        left = {"sp500": 0.1, "gold_cny": 0.2}
        right = {"gold_cny": 0.2, "sp500": 0.1}
        self.assertEqual(target_fingerprint(left), target_fingerprint(right))

    def test_hash_chain_detects_tampering_and_duplicate_signal_date(self) -> None:
        target = {"gold_cny": 0.2, "nasdaq": 0.2, "sp500": 0.1}
        payload = {
            "trial_id": "ATM-SVP2-PROSPECTIVE-FACTOR-001",
            "v11": self.snapshot(),
            "input_manifest": {"path": "inputs.json", "sha256": "1" * 64},
            "candidates": {
                candidate: {
                    "candidate_target": target,
                    "candidate_target_fingerprint": target_fingerprint(target),
                    "matched_control_target": target,
                    "matched_control_target_fingerprint": target_fingerprint(target),
                }
                for candidate in CANDIDATE_SPECS
            },
            "state": {},
        }
        first = make_record(sequence=1, previous_hash=GENESIS, payload=payload, recorded_at="2026-08-21T23:00:00+08:00")
        verify_shadow_records([first])

        tampered = copy.deepcopy(first)
        tampered["payload"]["v11"]["dataset_hash"] = "b" * 64
        with self.assertRaises(ValueError):
            verify_shadow_records([tampered])

        second = make_record(sequence=2, previous_hash=first["record_hash"], payload=payload, recorded_at="2026-08-22T23:00:00+08:00")
        with self.assertRaises(ValueError):
            verify_shadow_records([first, second])


if __name__ == "__main__":
    unittest.main()
