#!/usr/bin/env python3
from __future__ import annotations

import unittest

from fetch_prospective_factor_inputs import ALLOWED_SOURCES, clip_rows_to_signal_date


class ProspectiveFactorInputFetchTests(unittest.TestCase):
    def test_sources_are_exactly_frozen_registry_sources(self) -> None:
        self.assertEqual(
            ALLOWED_SOURCES,
            {
                "HYG": "HYG",
                "SHY": "SHY",
                "RSP": "RSP",
                "SPY": "SPY",
                "SPHB": "SPHB",
                "SPLV": "SPLV",
            },
        )

    def test_clip_rejects_future_observations(self) -> None:
        rows = [(f"2026-07-{day:02d}", 100.0 + day) for day in range(1, 23)]
        rows.append(("2026-08-24", 200.0))
        self.assertEqual(
            clip_rows_to_signal_date(rows, "2026-08-21"),
            rows[:-1],
        )

    def test_clip_requires_at_least_21_observations(self) -> None:
        rows = [(f"2026-07-{day:02d}", float(day)) for day in range(1, 21)]
        with self.assertRaises(RuntimeError):
            clip_rows_to_signal_date(rows, "2026-07-20")


if __name__ == "__main__":
    unittest.main()
