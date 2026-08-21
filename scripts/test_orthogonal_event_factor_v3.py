#!/usr/bin/env python3
from __future__ import annotations

import unittest

from run_orthogonal_event_factor_v3 import FORMAL_CANDIDATES, MATCHED_CONTROLS, evaluate_factor


class OrthogonalEventFactorV3Tests(unittest.TestCase):
    def test_candidate_and_control_mapping_is_frozen(self) -> None:
        self.assertEqual(FORMAL_CANDIDATES, ["F-CREDIT", "F-CYCLICAL", "F-BREADTH"])
        self.assertEqual(
            MATCHED_CONTROLS,
            {
                "F-CREDIT": "C-CREDIT-ALWAYS",
                "F-CYCLICAL": "C-CYCLICAL-ALWAYS",
                "F-BREADTH": "C-BREADTH-ALWAYS",
            },
        )

    def test_factor_admits_only_if_it_beats_matched_control(self) -> None:
        candidate = {
            "cagr_percent": 15.8,
            "sharpe": 1.60,
            "mdd_percent": 9.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 1.1, 0.9, 1.5, 1.6],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        matched = {
            "sharpe": 1.52,
            "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.7],
        }
        result = evaluate_factor(candidate, v11=v11, matched_control=matched)
        self.assertTrue(result["admit_for_robustness"])
        self.assertTrue(result["strong_incremental"])
        self.assertEqual(result["folds_sharpe_ge_matched"], 5)

    def test_more_cagr_but_worse_sharpe_than_matched_control_fails(self) -> None:
        candidate = {
            "cagr_percent": 17.0,
            "sharpe": 1.40,
            "mdd_percent": 9.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 1.1, 0.9, 1.5, 1.6],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        matched = {
            "sharpe": 1.45,
            "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.7],
        }
        result = evaluate_factor(candidate, v11=v11, matched_control=matched)
        self.assertFalse(result["admit_for_robustness"])
        self.assertFalse(result["strong_incremental"])

    def test_factor_needs_four_fold_wins_vs_matched_control(self) -> None:
        candidate = {
            "cagr_percent": 15.8,
            "sharpe": 1.60,
            "mdd_percent": 9.0,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 0.9, 0.8, 1.2, 1.0],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        matched = {
            "sharpe": 1.50,
            "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.1],
        }
        result = evaluate_factor(candidate, v11=v11, matched_control=matched)
        self.assertFalse(result["admit_for_robustness"])
        self.assertEqual(result["folds_sharpe_ge_matched"], 3)


if __name__ == "__main__":
    unittest.main()
