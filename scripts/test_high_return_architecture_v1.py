#!/usr/bin/env python3
from __future__ import annotations

import unittest

from run_high_return_architecture_v1 import FORMAL_CANDIDATES, evaluate_candidate


class HighReturnArchitectureV1Tests(unittest.TestCase):
    def test_candidate_family_is_exactly_preregistered_three(self) -> None:
        self.assertEqual(FORMAL_CANDIDATES, ["HR-A", "HR-B", "HR-C"])

    def test_candidate_in_target_region_is_admitted(self) -> None:
        metrics = {
            "cagr_percent": 18.2,
            "sharpe": 1.50,
            "mdd_percent": 9.5,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.2, 1.1, 1.3, 1.4, 1.05, 0.8, 1.2],
        }
        flags = evaluate_candidate(metrics, frozen_v11_cagr_percent=14.345615)
        self.assertTrue(flags["admit_for_robustness"])
        self.assertTrue(flags["target_region"])
        self.assertEqual(flags["folds_sharpe_gt1"], 6)
        self.assertAlmostEqual(flags["worst_fold_sharpe"], 0.8)

    def test_high_cagr_fails_if_time_folds_are_weak(self) -> None:
        metrics = {
            "cagr_percent": 19.0,
            "sharpe": 1.55,
            "mdd_percent": 8.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.2, 1.1, 1.3, 1.4, 0.9, 0.8, 0.7],
        }
        flags = evaluate_candidate(metrics, frozen_v11_cagr_percent=14.345615)
        self.assertFalse(flags["admit_for_robustness"])
        self.assertFalse(flags["target_region"])
        self.assertEqual(flags["folds_sharpe_gt1"], 4)

    def test_candidate_fails_if_gross_or_negative_weight_constraint_breaks(self) -> None:
        metrics = {
            "cagr_percent": 18.2,
            "sharpe": 1.50,
            "mdd_percent": 9.5,
            "max_gross": 1.01,
            "min_weight": -0.001,
            "fold_sharpes": [1.2, 1.1, 1.3, 1.4, 1.05, 0.8, 1.2],
        }
        flags = evaluate_candidate(metrics, frozen_v11_cagr_percent=14.345615)
        self.assertFalse(flags["admit_for_robustness"])
        self.assertFalse(flags["constraints_pass"])


if __name__ == "__main__":
    unittest.main()
