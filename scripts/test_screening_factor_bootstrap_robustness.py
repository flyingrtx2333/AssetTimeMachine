#!/usr/bin/env python3
from __future__ import annotations

import unittest

import numpy as np

from run_screening_factor_bootstrap_robustness import (
    LOCKED_CANDIDATES,
    evaluate_bootstrap_gate,
    expand_circular_blocks,
    sample_paired_returns,
)


class ScreeningFactorBootstrapRobustnessTests(unittest.TestCase):
    def test_locked_candidates_are_exactly_the_two_screening_winners(self) -> None:
        self.assertEqual(list(LOCKED_CANDIDATES), ["F-BREADTH", "F-HIGHBETA"])

    def test_circular_block_expansion_wraps_and_truncates(self) -> None:
        indices = expand_circular_blocks(np.array([8, 2]), n=10, block_sessions=3, target_length=5)
        self.assertEqual(indices.tolist(), [8, 9, 0, 2, 3])

    def test_paired_resampling_uses_identical_indices_for_all_three_series(self) -> None:
        candidate = np.arange(10, dtype=float)
        matched = candidate * 10.0
        v11 = candidate * 100.0
        indices = np.array([8, 9, 0, 2, 3], dtype=int)
        c, m, v = sample_paired_returns(candidate, matched, v11, indices)
        np.testing.assert_allclose(m, c * 10.0)
        np.testing.assert_allclose(v, c * 100.0)

    def test_gate_requires_all_frozen_conditions(self) -> None:
        passing = evaluate_bootstrap_gate(
            probability_cagr_gt_v11=0.91,
            probability_sharpe_gt_matched=0.92,
            median_cagr_delta=0.001,
            median_sharpe_delta=0.01,
            candidate_mdd_p975=0.149,
        )
        self.assertTrue(passing["bootstrap_robust_pass"])

        failing = evaluate_bootstrap_gate(
            probability_cagr_gt_v11=0.89,
            probability_sharpe_gt_matched=0.99,
            median_cagr_delta=0.001,
            median_sharpe_delta=0.01,
            candidate_mdd_p975=0.10,
        )
        self.assertFalse(failing["bootstrap_robust_pass"])
        self.assertFalse(failing["checks"]["probability_cagr_gt_v11_ge_0_90"])


if __name__ == "__main__":
    unittest.main()
