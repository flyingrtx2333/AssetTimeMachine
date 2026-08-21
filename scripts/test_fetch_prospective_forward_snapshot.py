#!/usr/bin/env python3
from __future__ import annotations

import copy
import unittest

from fetch_prospective_forward_snapshot import select_v11_snapshot, validate_v11_snapshot


class ProspectiveForwardSnapshotTests(unittest.TestCase):
    @staticmethod
    def snapshot() -> dict:
        weights = {
            "gold_cny": 0.2,
            "nasdaq": 0.2,
            "sp500": 0.1,
            "csi300": 0.0,
            "shanghai_composite": 0.0,
        }
        return {
            "strategy_id": "nfci-dual-core-v11",
            "strategy_version": "dualcore-v11-2026-08-15",
            "strategy_name": "NFCI 双核心·简化（前瞻）",
            "frozen_at": "2026-08-15",
            "decision_at": "2026-08-21T08:00:00Z",
            "signal_date": "2026-08-20",
            "execution_date_hint": "2026-08-21",
            "data_cutoff": "2026-08-20",
            "dataset_hash": "a" * 64,
            "engine_version": "atm-swift-test",
            "data_stale": False,
            "desired_target_weights": weights,
            "desired_cash_weight": 0.5,
            "desired_gross_exposure": 0.5,
            "model_executed_weights": weights,
            "model_cash_weight": 0.5,
            "model_gross_exposure": 0.5,
            "rebalance_recommended": True,
            "target_fingerprint": "deadbeefdeadbeef",
            "causal_input_fingerprint": "cafebabecafebabe",
            "nfci": {"source": "test"},
        }

    def test_selects_exactly_one_v11_snapshot(self) -> None:
        v11 = self.snapshot()
        v1 = {**v11, "strategy_id": "nfci-dual-core-v1", "strategy_version": "dualcore-v1-2026-08-14", "frozen_at": "2026-08-14"}
        selected = select_v11_snapshot({"snapshots": [v1, v11]})
        self.assertEqual(selected["strategy_id"], "nfci-dual-core-v11")

    def test_rejects_stale_or_version_drift(self) -> None:
        stale = self.snapshot()
        stale["data_stale"] = True
        with self.assertRaises(ValueError):
            validate_v11_snapshot(stale)

        drifted = self.snapshot()
        drifted["strategy_version"] = "drifted"
        with self.assertRaises(ValueError):
            validate_v11_snapshot(drifted)

    def test_rejects_weight_and_accounting_drift(self) -> None:
        missing = self.snapshot()
        del missing["desired_target_weights"]["sp500"]
        with self.assertRaises(ValueError):
            validate_v11_snapshot(missing)

        mismatch = self.snapshot()
        mismatch["desired_gross_exposure"] = 0.7
        with self.assertRaises(ValueError):
            validate_v11_snapshot(mismatch)

    def test_rejects_duplicate_v11(self) -> None:
        v11 = self.snapshot()
        with self.assertRaises(ValueError):
            select_v11_snapshot({"snapshots": [v11, copy.deepcopy(v11)]})


if __name__ == "__main__":
    unittest.main()
