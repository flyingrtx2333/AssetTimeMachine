#!/usr/bin/env python3
"""Regression tests for the Python backtest engine against the App/Swift engine.

These numbers are the raw SwiftData/App result for `coreGoldSatelliteHeatCappedMomentum`
(热度上限元策略) saved by the iOS app with:
- gold_cny, nasdaq, sp500, csi300, shanghai_composite
- initialCash 100000
- fee 1.00%, slippage 0.05%
- single equity cap 64%, gold satellite 10%, max total exposure 85%

The test intentionally guards against using older exploratory research scripts whose
metrics drifted to ~12.08% / 9.76% and caused incorrect conclusions.
"""
from __future__ import annotations

import math
import unittest

import atm_app_equivalent_backtest as app_engine


class AppEquivalentBacktestTests(unittest.TestCase):
    def test_heat_capped_momentum_matches_saved_app_record(self) -> None:
        result = app_engine.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")

        self.assertEqual(result.coverage_start, "2002-01-04")
        self.assertEqual(result.coverage_end, "2026-06-19")
        self.assertGreaterEqual(result.point_count, 6300)
        self.assertEqual(result.strategy, "coreGoldSatelliteHeatCappedMomentum")

        # Exact 1% fee App-equivalent result was 0.09543098298955388 /
        # 0.12039121527949208 when the market data endpoint ended on
        # 2026-06-19. The endpoint may advance by a few latest days, so use a
        # tight-but-realistic tolerance on annualized return and exact drawdown
        # episode tolerance.
        self.assertTrue(math.isclose(result.annualized_return, 0.09543098298955388, abs_tol=0.003))
        self.assertTrue(math.isclose(result.max_drawdown, 0.12039121527949208, abs_tol=0.0005))

        self.assertEqual(len(result.trades), 177)
        first_trades = [(trade.date, trade.action, trade.symbol) for trade in result.trades[:3]]
        self.assertEqual(
            first_trades,
            [
                ("2002-06-24", "buy", "gold_cny"),
                ("2002-09-16", "buy", "gold_cny"),
                ("2002-12-09", "buy", "gold_cny"),
            ],
        )
        self.assertGreater(result.trades[2].cash_amount, 70_000)

    def test_one_way_vol_managed_momentum_matches_spike_027_record(self) -> None:
        result = app_engine.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date="2026-06-19")

        self.assertEqual(result.coverage_start, "2002-01-04")
        self.assertEqual(result.coverage_end, "2026-06-19")
        self.assertGreaterEqual(result.point_count, 6300)
        self.assertEqual(result.strategy, "coreGoldSatelliteOneWayVolManagedMomentum")

        self.assertTrue(math.isclose(result.annualized_return, 0.10700570007571142, abs_tol=0.0005))
        self.assertTrue(math.isclose(result.max_drawdown, 0.11234419592125398, abs_tol=0.0005))
        self.assertTrue(math.isclose(result.sharpe_ratio or 0, 1.0429550234586935, abs_tol=0.002))

        self.assertLessEqual(result.max_drawdown, 0.12)
        self.assertGreater(result.sharpe_ratio or 0, 1.0)

    def test_one_way_vol_managed_momentum_uses_pre_start_signal_history(self) -> None:
        full_result = app_engine.run_strategy(
            "coreGoldSatelliteOneWayVolManagedMomentum",
            end_date="2026-06-23",
        )
        result = app_engine.run_strategy(
            "coreGoldSatelliteOneWayVolManagedMomentum",
            start_date="2025-06-23",
            end_date="2026-06-23",
        )

        self.assertEqual(result.coverage_start, "2025-06-23")
        self.assertEqual(result.coverage_end, "2026-06-23")
        self.assertGreater(result.annualized_return, 0.07)
        self.assertGreater(result.total_return, 0.07)
        self.assertGreater(len(result.trades), 0)

        start = app_engine.parse_date("2025-06-23")
        full_recent = [
            (trade.date, trade.action, trade.symbol)
            for trade in full_result.trades
            if app_engine.parse_date(trade.date) >= start
        ]
        window_after_initial_entry = [
            (trade.date, trade.action, trade.symbol)
            for trade in result.trades
            if trade.date != "2025-06-23"
        ]
        self.assertEqual(window_after_initial_entry, full_recent)


if __name__ == "__main__":
    unittest.main(verbosity=2)
