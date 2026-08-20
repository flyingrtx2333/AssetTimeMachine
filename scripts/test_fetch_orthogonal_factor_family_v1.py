#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest

from fetch_orthogonal_factor_family_v1 import (
    ALLOWED_FACTOR_SOURCES,
    parse_fred_csv,
    parse_yahoo_chart,
)


class OrthogonalFactorFetchTests(unittest.TestCase):
    def test_allowed_sources_are_exactly_preregistered(self) -> None:
        self.assertEqual(
            ALLOWED_FACTOR_SOURCES,
            {
                "T10Y3M": ("FRED", "T10Y3M"),
                "DXY": ("YAHOO", "DX-Y.NYB"),
                "RUT": ("YAHOO", "^RUT"),
                "RUI": ("YAHOO", "^RUI"),
            },
        )

    def test_parse_fred_csv_skips_missing_values(self) -> None:
        text = "DATE,T10Y3M\n2026-01-02,0.50\n2026-01-05,.\n2026-01-06,-0.10\n"
        rows = parse_fred_csv(text, "T10Y3M")
        self.assertEqual(rows, [("2026-01-02", 0.5), ("2026-01-06", -0.1)])

    def test_parse_yahoo_chart_uses_close_and_utc_date(self) -> None:
        payload = {
            "chart": {
                "error": None,
                "result": [{
                    "timestamp": [1704153600, 1704240000],
                    "indicators": {"quote": [{"close": [101.25, 102.5]}]},
                    "meta": {"instrumentType": "INDEX", "exchangeName": "TEST"},
                }],
            }
        }
        rows, meta = parse_yahoo_chart(json.dumps(payload).encode("utf-8"))
        self.assertEqual(rows, [("2024-01-02", 101.25), ("2024-01-03", 102.5)])
        self.assertEqual(meta["instrument_type"], "INDEX")
        self.assertEqual(meta["exchange_name"], "TEST")

    def test_parse_yahoo_rejects_error_payload(self) -> None:
        payload = {"chart": {"error": {"code": "Bad Symbol"}, "result": None}}
        with self.assertRaises(RuntimeError):
            parse_yahoo_chart(json.dumps(payload).encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
