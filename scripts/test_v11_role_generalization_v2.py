#!/usr/bin/env python3
from __future__ import annotations

import unittest

from run_v11_role_generalization import FORMAL_PROTOCOL_ID, evaluate_g4_v2


class V11RoleGeneralizationV2Tests(unittest.TestCase):
    def test_formal_protocol_is_atm_svp_2(self) -> None:
        self.assertEqual(FORMAL_PROTOCOL_ID, "ATM-SVP-2")

    def test_relative_common_window_gates_pass(self) -> None:
        common = {
            "cagr_percent": 10.0,
            "sharpe": 1.20,
            "mdd_percent": 10.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
        }
        one_slot = [
            {"sharpe": 0.80, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.70, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.65, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.61, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": -0.05, "max_gross": 1.0, "min_weight": 0.0},
        ]
        all_alt = {
            "cagr_percent": 2.0,
            "sharpe": 0.62,
            "mdd_percent": 12.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
        }
        result = evaluate_g4_v2(common_baseline=common, one_slot_metrics=one_slot, all_alternate=all_alt)
        self.assertTrue(result["pass"])
        self.assertAlmostEqual(result["thresholds"]["one_slot_median_sharpe_min"], 0.60)
        self.assertAlmostEqual(result["thresholds"]["all_alternate_sharpe_min"], 0.60)
        self.assertAlmostEqual(result["thresholds"]["all_alternate_mdd_max_percent"], 12.5)
        self.assertEqual(result["observed"]["positive_one_slot_sharpe_count"], 4)

    def test_common_baseline_must_be_valid(self) -> None:
        common = {
            "cagr_percent": 10.0,
            "sharpe": 1.20,
            "mdd_percent": 26.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
        }
        one_slot = [{"sharpe": 1.0, "max_gross": 1.0, "min_weight": 0.0}] * 5
        all_alt = {
            "cagr_percent": 5.0,
            "sharpe": 1.0,
            "mdd_percent": 10.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
        }
        result = evaluate_g4_v2(common_baseline=common, one_slot_metrics=one_slot, all_alternate=all_alt)
        self.assertFalse(result["pass"])
        self.assertFalse(result["checks"]["common_reference_mdd_le_25pct"])

    def test_all_alternate_uses_relative_mdd_and_sharpe(self) -> None:
        common = {
            "cagr_percent": 8.0,
            "sharpe": 0.80,
            "mdd_percent": 20.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
        }
        one_slot = [
            {"sharpe": 0.50, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.45, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.42, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.41, "max_gross": 1.0, "min_weight": 0.0},
            {"sharpe": 0.39, "max_gross": 1.0, "min_weight": 0.0},
        ]
        all_alt = {
            "cagr_percent": 1.0,
            "sharpe": 0.39,
            "mdd_percent": 25.01,
            "max_gross": 1.0,
            "min_weight": 0.0,
        }
        result = evaluate_g4_v2(common_baseline=common, one_slot_metrics=one_slot, all_alternate=all_alt)
        self.assertFalse(result["pass"])
        self.assertAlmostEqual(result["thresholds"]["all_alternate_sharpe_min"], 0.40)
        self.assertAlmostEqual(result["thresholds"]["all_alternate_mdd_max_percent"], 25.0)
        self.assertFalse(result["checks"]["all_alternate_sharpe_relative_pass"])
        self.assertFalse(result["checks"]["all_alternate_mdd_relative_pass"])


if __name__ == "__main__":
    unittest.main()
