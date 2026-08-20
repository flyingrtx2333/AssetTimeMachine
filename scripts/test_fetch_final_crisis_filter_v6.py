#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest

from fetch_final_crisis_filter_v6 import ALLOWED_SOURCES, parse_yahoo_adjusted_chart


class FinalCrisisFilterV6FetchTests(unittest.TestCase):
    def test_allowed_sources_are_exactly_preregistered(self) -> None:
        self.assertEqual(
            ALLOWED_SOURCES,
            {
                "VIX9D": "^VIX9D",
                "VIX": "^VIX",
                "VVIX": "^VVIX",
                "HYG": "HYG",
                "SHY": "SHY",
            },
        )

    def test_parser_uses_adjusted_close(self) -> None:
        payload = {
            "chart": {
                "error": None,
                "result": [{
                    "timestamp": [1704153600, 1704240000],
                    "indicators": {
                        "quote": [{"close": [100.0, 101.0]}],
                        "adjclose": [{"adjclose": [95.0, 96.5]}],
                    },
                    "meta": {"instrumentType": "INDEX", "exchangeName": "WCB", "currency": "USD"},
                }],
            }
        }
        rows, meta = parse_yahoo_adjusted_chart(json.dumps(payload).encode("utf-8"))
        self.assertEqual(rows, [("2024-01-02", 95.0), ("2024-01-03", 96.5)])
        self.assertEqual(meta["instrument_type"], "INDEX")

    def test_parser_rejects_missing_adjusted_close(self) -> None:
        payload = {"chart": {"error": None, "result": [{"timestamp": [1704153600], "indicators": {"quote": [{"close": [100.0]}]}, "meta": {}}]}}
        with self.assertRaises(RuntimeError):
            parse_yahoo_adjusted_chart(json.dumps(payload).encode("utf-8"))

    def test_parser_rejects_yahoo_error(self) -> None:
        payload = {"chart": {"error": {"code": "Bad Symbol"}, "result": None}}
        with self.assertRaises(RuntimeError):
            parse_yahoo_adjusted_chart(json.dumps(payload).encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
