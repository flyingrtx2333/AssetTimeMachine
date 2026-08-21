#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
import unittest
from pathlib import Path

from fetch_broker_dealer_leverage_vintage import period_values

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "tools/research-results/strategy-validation/factor-data/BROKER-DEALER-VINTAGE-2026-08-21"


class BrokerDealerVintageTests(unittest.TestCase):
    def test_old_and_modern_table_layouts_select_same_series(self) -> None:
        old_rows = [
            [
                "Security brokers and dealers; total financial assets",
                "10.0", "11.0", "12.0", "13.0", "14.0", "1",
            ]
        ]
        modern_rows = [
            [
                "Line 1", "Total financial assets", "FL664090005",
                "10.0", "11.0", "12.0", "13.0", "14.0",
            ]
        ]
        self.assertEqual(
            period_values(old_rows, "total financial assets", "FL664090005"),
            [10.0, 11.0, 12.0, 13.0, 14.0],
        )
        self.assertEqual(
            period_values(modern_rows, "total financial assets", "FL664090005"),
            [10.0, 11.0, 12.0, 13.0, 14.0],
        )

    def test_total_liabilities_does_not_match_liabilities_and_equity(self) -> None:
        rows = [
            ["Line 18", "Total liabilities and equity", "FL664194005", "1", "2", "3", "4", "5"],
            ["Line 19", "Total liabilities", "FL664190005", "10", "11", "12", "13", "14"],
        ]
        self.assertEqual(
            period_values(rows, "total liabilities", "FL664190005"),
            [10.0, 11.0, 12.0, 13.0, 14.0],
        )

    def test_frozen_dataset_has_expected_first_release_anchors(self) -> None:
        path = DATA_DIR / "BROKER_DEALER_BOOK_LEVERAGE_FIRST_RELEASE.csv"
        rows = {row["quarter"]: row for row in csv.DictReader(path.open(encoding="utf-8"))}
        self.assertEqual(len(rows), 57)
        self.assertAlmostEqual(float(rows["2012Q1"]["total_financial_assets"]), 2064.3, places=6)
        self.assertAlmostEqual(float(rows["2012Q1"]["total_liabilities"]), 1993.8, places=6)
        self.assertAlmostEqual(float(rows["2016Q1"]["book_leverage"]), 100.68316831683258, places=9)
        self.assertAlmostEqual(float(rows["2025Q1"]["total_financial_assets"]), 5759.3, places=6)
        self.assertAlmostEqual(float(rows["2026Q1"]["total_financial_assets"]), 6689.1, places=6)
        self.assertAlmostEqual(float(rows["2026Q1"]["total_liabilities"]), 6277.3, places=6)
        self.assertEqual(rows["2026Q1"]["release_date"], "2026-06-11")
        self.assertEqual(rows["2026Q1"]["available_date"], "2026-06-12")

    def test_every_frozen_raw_table_matches_recorded_sha(self) -> None:
        path = DATA_DIR / "BROKER_DEALER_BOOK_LEVERAGE_FIRST_RELEASE.csv"
        rows = list(csv.DictReader(path.open(encoding="utf-8")))
        self.assertEqual(len(rows), 57)
        for row in rows:
            raw_path = DATA_DIR / row["source_table_local_path"]
            self.assertTrue(raw_path.is_file(), row["quarter"])
            digest = hashlib.sha256(raw_path.read_bytes()).hexdigest()
            self.assertEqual(digest, row["source_table_sha256"], row["quarter"])


if __name__ == "__main__":
    unittest.main()
