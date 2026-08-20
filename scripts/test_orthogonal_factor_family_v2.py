#!/usr/bin/env python3
from __future__ import annotations

import unittest

from run_orthogonal_factor_family_v2 import FORMAL_CANDIDATES, evaluate_factor


class OrthogonalFactorFamilyV2Tests(unittest.TestCase):
    def test_formal_candidates_are_exactly_preregistered_three(self) -> None:
        self.assertEqual(FORMAL_CANDIDATES, ["F-FUNDING", "F-COPGOLD", "F-SKEW"])

    def test_factor_is_admitted_when_every_frozen_gate_passes(self) -> None:
        metrics = {
            "cagr_percent": 15.6,
            "sharpe": 1.56,
            "mdd_percent": 9.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 1.1, 0.9, 1.5, 1.6],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        always = {
            "sharpe": 1.50,
            "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.7],
        }
        flags = evaluate_factor(metrics, v11=v11, always_fill=always)
        self.assertTrue(flags["admit_for_robustness"])
        self.assertTrue(flags["strong_incremental"])
        self.assertEqual(flags["folds_sharpe_ge_always_fill"], 5)

    def test_more_return_without_better_sharpe_than_always_fill_is_rejected(self) -> None:
        metrics = {
            "cagr_percent": 17.0,
            "sharpe": 1.30,
            "mdd_percent": 10.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 1.1, 0.9, 1.5, 1.6],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        always = {
            "sharpe": 1.40,
            "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.7],
        }
        flags = evaluate_factor(metrics, v11=v11, always_fill=always)
        self.assertFalse(flags["admit_for_robustness"])
        self.assertFalse(flags["strong_incremental"])

    def test_factor_needs_four_fold_wins_or_ties_vs_always_fill(self) -> None:
        metrics = {
            "cagr_percent": 15.6,
            "sharpe": 1.56,
            "mdd_percent": 9.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 0.9, 0.8, 1.2, 1.0],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        always = {
            "sharpe": 1.50,
            "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.1],
        }
        flags = evaluate_factor(metrics, v11=v11, always_fill=always)
        self.assertFalse(flags["admit_for_robustness"])
        self.assertEqual(flags["folds_sharpe_ge_always_fill"], 3)


if __name__ == "__main__":
    unittest.main()
