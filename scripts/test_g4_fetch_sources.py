#!/usr/bin/env python3
from __future__ import annotations

import unittest

from fetch_g4_holdout_raw import SUPPORTED_SOURCES


class G4FetchSourceTests(unittest.TestCase):
    def test_russell_yahoo_source_is_supported_before_holdout_freeze(self) -> None:
        self.assertIn("YAHOO_FTSE_RUSSELL", SUPPORTED_SOURCES)

    def test_sse_yahoo_source_is_supported_before_holdout_freeze(self) -> None:
        self.assertIn("YAHOO_SSE", SUPPORTED_SOURCES)


if __name__ == "__main__":
    unittest.main()
