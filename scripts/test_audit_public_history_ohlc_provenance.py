#!/usr/bin/env python3
from __future__ import annotations

import copy
import sys
import unittest
from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audit_public_history_ohlc_provenance as audit


class ProvenanceAuditTests(unittest.TestCase):
    def test_latest_causal_fx_never_uses_future_and_enforces_staleness(self) -> None:
        dates = [date(2024, 1, 2), date(2024, 1, 5)]
        values = [0.14, 0.15]
        self.assertIsNone(audit.latest_causal_fx(date(2024, 1, 1), dates, values))
        self.assertEqual(audit.latest_causal_fx(date(2024, 1, 4), dates, values), (dates[0], 0.14, 2))
        self.assertEqual(audit.latest_causal_fx(date(2024, 1, 12), dates, values), (dates[1], 0.15, 7))
        self.assertIsNone(audit.latest_causal_fx(date(2024, 1, 13), dates, values))

    def test_production_report_binds_sorted_unique_dates_and_source(self) -> None:
        report = {
            "dry_run": False,
            "updated": 2,
            "would_update": 2,
            "candidate_count": 2,
            "candidate_dates": ["2024-01-02", "2024-01-03"],
            "would_update_dates": ["2024-01-02", "2024-01-03"],
            "source": {"sha256": "abc"},
        }
        self.assertEqual(audit.validate_production_report(report, "abc"), report["would_update_dates"])
        bad = copy.deepcopy(report)
        bad["source"]["sha256"] = "wrong"
        with self.assertRaises(audit.AuditError):
            audit.validate_production_report(bad, "abc")
        bad = copy.deepcopy(report)
        bad["would_update_dates"].reverse()
        with self.assertRaises(audit.AuditError):
            audit.validate_production_report(bad, "abc")

    @staticmethod
    def series() -> dict:
        return {
            "symbol": "gold_cny",
            "dates": ["2024-01-02", "2024-01-03"],
            "prices": [100.0, 101.0],
            "observed": [True, True],
            "open_prices": [99.0, None],
            "high_prices": [102.0, None],
            "low_prices": [98.0, None],
            "close_prices": [100.5, 101.0],
            "volumes": [10.0, None],
        }

    def test_canonical_close_fallback_is_missing_not_partial(self) -> None:
        result = audit.validate_price_series(self.series())
        self.assertEqual(result["complete_ohlc_rows"], 1)
        self.assertEqual(result["missing_ohlc_dates"], ["2024-01-03"])
        self.assertEqual(result["missing_all_null_rows"], 0)
        self.assertEqual(result["missing_canonical_close_fallback_rows"], 1)

        all_null = self.series()
        all_null["close_prices"][1] = None
        result = audit.validate_price_series(all_null)
        self.assertEqual(result["missing_all_null_rows"], 1)
        self.assertEqual(result["missing_canonical_close_fallback_rows"], 0)

    def test_other_partial_ohlc_and_bad_geometry_fail_closed(self) -> None:
        partial = self.series()
        partial["open_prices"][1] = 100.0
        with self.assertRaises(audit.AuditError):
            audit.validate_price_series(partial)
        geometry = self.series()
        geometry["high_prices"][0] = 99.5
        with self.assertRaises(audit.AuditError):
            audit.validate_price_series(geometry)

    def test_choice_values_require_one_shared_rounding_fx_interval(self) -> None:
        source = audit.choice_parser.SourceRow(
            trading_date="2024-01-02",
            open_price=2000.0,
            high_price=2020.0,
            low_price=1980.0,
            close_price=2010.0,
            volume=1234.0,
        )
        fx = Decimal("7.23456789")
        grams = Decimal(str(audit.TROY_OUNCE_GRAMS))
        actual = [
            (Decimal(str(value)) * fx / grams).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
            for value in (source.open_price, source.high_price, source.low_price, source.close_price)
        ]
        self.assertIsNotNone(audit.choice_rounding_fx_intersection(source, actual))
        self.assertTrue(audit.volume_matches_choice(source, 1234))
        tampered = list(actual)
        tampered[1] += Decimal("0.01")
        self.assertIsNone(audit.choice_rounding_fx_intersection(source, tampered))
        self.assertFalse(audit.volume_matches_choice(source, 1235))

    def test_digest_is_stable_ordered_and_domain_separated(self) -> None:
        rows = [("2024-01-02", "choice_imported"), ("2024-01-03", "missing")]
        value = audit.domain_digest("asset/gold", rows)
        self.assertEqual(value, audit.domain_digest("asset/gold", rows))
        self.assertNotEqual(value, audit.domain_digest("asset/gold", reversed(rows)))
        self.assertNotEqual(value, audit.domain_digest("asset/sp500", rows))


if __name__ == "__main__":
    unittest.main()
