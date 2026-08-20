#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest

from fetch_orthogonal_factor_family_v2 import (
    ALLOWED_FACTOR_SOURCES,
    parse_fred_csv,
    parse_yahoo_chart,
)


class OrthogonalFactorV2FetchTests(unittest.TestCase):
    def test_allowed_sources_are_exactly_preregistered(self) -> None:
        self.assertEqual(
            ALLOWED_FACTOR_SOURCES,
            {
                "DCPF3M": ("FRED", "DCPF3M"),
                "DFF": ("FRED", "DFF"),
                "HG": ("YAHOO", "HG=F"),
                "GC": ("YAHOO", "GC=F"),
                "SKEW": ("YAHOO", "^SKEW"),
            },
        )

    def test_parse_fred_csv_skips_missing_values(self) -> None:
        text = "DATE,DCPF3M\n2026-01-02,4.10\n2026-01-05,.\n2026-01-06,4.05\n"
        rows = parse_fred_csv(text, "DCPF3M")
        self.assertEqual(rows, [("2026-01-02", 4.10), ("2026-01-06", 4.05)])

    def test_parse_yahoo_chart_uses_close_and_utc_date(self) -> None:
        payload = {
            "chart": {
                "error": None,
                "result": [{
                    "timestamp": [1704153600, 1704240000],
                    "indicators": {"quote": [{"close": [3.85, 3.90]}]},
                    "meta": {"instrumentType": "FUTURE", "exchangeName": "CMX"},
                }],
            }
        }
        rows, meta = parse_yahoo_chart(json.dumps(payload).encode("utf-8"))
        self.assertEqual(rows, [("2024-01-02", 3.85), ("2024-01-03", 3.90)])
        self.assertEqual(meta["instrument_type"], "FUTURE")
        self.assertEqual(meta["exchange_name"], "CMX")

    def test_parse_yahoo_rejects_error_payload(self) -> None:
        payload = {"chart": {"error": {"code": "Bad Symbol"}, "result": None}}
        with self.assertRaises(RuntimeError):
            parse_yahoo_chart(json.dumps(payload).encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
