#!/usr/bin/env python3
from __future__ import annotations

import unittest

from run_final_crisis_filter_v6 import FORMAL_CANDIDATES, MATCHED_CONTROLS, evaluate_factor


class FinalCrisisFilterV6Tests(unittest.TestCase):
    def test_candidate_and_control_mapping_is_frozen(self) -> None:
        self.assertEqual(FORMAL_CANDIDATES, ["F-VIXTERM", "F-VVIX", "F-CREDITCASH"])
        self.assertEqual(
            MATCHED_CONTROLS,
            {
                "F-VIXTERM": "C-VIXTERM-ALWAYS",
                "F-VVIX": "C-VVIX-ALWAYS",
                "F-CREDITCASH": "C-CREDITCASH-ALWAYS",
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
        matched = {"sharpe": 1.52, "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.7]}
        result = evaluate_factor(candidate, v11=v11, matched_control=matched)
        self.assertTrue(result["admit_for_robustness"])
        self.assertTrue(result["strong_incremental"])

    def test_factor_fails_if_drawdown_exceeds_frozen_ceiling(self) -> None:
        candidate = {
            "cagr_percent": 16.0,
            "sharpe": 1.60,
            "mdd_percent": 12.1,
            "max_gross": 1.0,
            "min_weight": 0.0,
            "fold_sharpes": [1.4, 1.2, 1.3, 1.1, 0.9, 1.5, 1.6],
        }
        v11 = {"cagr_percent": 14.345615, "sharpe": 1.522263}
        matched = {"sharpe": 1.50, "fold_sharpes": [1.3, 1.1, 1.2, 1.0, 1.0, 1.4, 1.7]}
        result = evaluate_factor(candidate, v11=v11, matched_control=matched)
        self.assertFalse(result["admit_for_robustness"])
        self.assertFalse(result["admission_checks"]["mdd_le_12pct"])


if __name__ == "__main__":
    unittest.main()
