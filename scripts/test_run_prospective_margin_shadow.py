#!/usr/bin/env python3
from __future__ import annotations

import copy
import csv
import tempfile
import unittest
from pathlib import Path

from run_prospective_factor_shadow import GENESIS, make_record, target_fingerprint
from run_prospective_margin_shadow import (
    CANDIDATE_ID,
    TRIAL_ID,
    read_margin_points,
    verify_records,
)


class ProspectiveMarginShadowTests(unittest.TestCase):
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

    def test_margin_points_are_clipped_by_conservative_available_date(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "margin.csv"
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=[
                    "reference_month", "conservative_available_date", "delta_leverage_ratio"
                ])
                writer.writeheader()
                writer.writerow({
                    "reference_month": "2026-05",
                    "conservative_available_date": "2026-07-01",
                    "delta_leverage_ratio": "-0.1",
                })
                writer.writerow({
                    "reference_month": "2026-06",
                    "conservative_available_date": "2026-08-01",
                    "delta_leverage_ratio": "0.2",
                })
                writer.writerow({
                    "reference_month": "2026-07",
                    "conservative_available_date": "2026-09-01",
                    "delta_leverage_ratio": "0.3",
                })
            points = read_margin_points(path, signal_date="2026-08-21")
            self.assertEqual([row["reference_month"] for row in points], ["2026-05", "2026-06"])
            self.assertEqual(points[-1]["available_date"], "2026-08-01")

    def test_hash_chain_rejects_tampering_and_duplicate_signal(self) -> None:
        target = {"gold_cny": 0.2, "nasdaq": 0.2, "sp500": 0.1}
        payload = {
            "trial_id": TRIAL_ID,
            "protocol_id": "ATM-SVP-2",
            "v11": self.snapshot(),
            "factor_input": {"path": "margin.csv", "sha256": "1" * 64},
            "candidate": {
                "candidate_id": CANDIDATE_ID,
                "candidate_target": target,
                "candidate_target_fingerprint": target_fingerprint(target),
                "matched_control_target": target,
                "matched_control_target_fingerprint": target_fingerprint(target),
            },
            "state": {},
        }
        first = make_record(
            sequence=1,
            previous_hash=GENESIS,
            payload=payload,
            recorded_at="2026-08-21T23:00:00+08:00",
        )
        verify_records([first])
        tampered = copy.deepcopy(first)
        tampered["payload"]["candidate"]["candidate_target"]["sp500"] = 0.2
        with self.assertRaises(ValueError):
            verify_records([tampered])
        second = make_record(
            sequence=2,
            previous_hash=first["record_hash"],
            payload=payload,
            recorded_at="2026-08-22T23:00:00+08:00",
        )
        with self.assertRaises(ValueError):
            verify_records([first, second])


if __name__ == "__main__":
    unittest.main()
