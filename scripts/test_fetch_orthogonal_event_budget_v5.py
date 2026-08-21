#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest

from fetch_orthogonal_event_budget_v5 import ALLOWED_SOURCES, parse_yahoo_adjusted_chart


class OrthogonalEventBudgetV5FetchTests(unittest.TestCase):
    def test_allowed_sources_are_exactly_preregistered(self) -> None:
        self.assertEqual(
            ALLOWED_SOURCES,
            {
                "QQQ": "QQQ",
                "TLT": "TLT",
                "XBI": "XBI",
                "XLV": "XLV",
                "IYT": "IYT",
                "IEF": "IEF",
            },
        )

    def test_parser_uses_adjusted_close_not_raw_close(self) -> None:
        payload = {
            "chart": {
                "error": None,
                "result": [{
                    "timestamp": [1704153600, 1704240000],
                    "indicators": {
                        "quote": [{"close": [100.0, 101.0]}],
                        "adjclose": [{"adjclose": [95.0, 96.5]}],
                    },
                    "meta": {"instrumentType": "ETF", "exchangeName": "NGM", "currency": "USD"},
                }],
            }
        }
        rows, meta = parse_yahoo_adjusted_chart(json.dumps(payload).encode("utf-8"))
        self.assertEqual(rows, [("2024-01-02", 95.0), ("2024-01-03", 96.5)])
        self.assertEqual(meta["instrument_type"], "ETF")
        self.assertEqual(meta["exchange_name"], "NGM")

    def test_parser_rejects_missing_adjusted_close(self) -> None:
        payload = {
            "chart": {
                "error": None,
                "result": [{
                    "timestamp": [1704153600],
                    "indicators": {"quote": [{"close": [100.0]}]},
                    "meta": {},
                }],
            }
        }
        with self.assertRaises(RuntimeError):
            parse_yahoo_adjusted_chart(json.dumps(payload).encode("utf-8"))

    def test_parser_rejects_yahoo_error(self) -> None:
        payload = {"chart": {"error": {"code": "Bad Symbol"}, "result": None}}
        with self.assertRaises(RuntimeError):
            parse_yahoo_adjusted_chart(json.dumps(payload).encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
