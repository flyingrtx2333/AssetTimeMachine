#!/usr/bin/env python3
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.parse

import refresh_app_backtest_baseline as refresh


class _Response:
    def __init__(self, payload: bytes):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self) -> bytes:
        return self.payload


class RefreshFixtureTests(unittest.TestCase):
    def test_fetch_fixture_bypasses_stale_public_cache(self):
        document = {
            "success": True,
            "series": [{"symbol": symbol} for symbol in refresh.SYMBOLS],
        }
        payload = json.dumps(document).encode("utf-8")
        captured = {}

        def fake_urlopen(request, timeout):
            captured["request"] = request
            captured["timeout"] = timeout
            return _Response(payload)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "history.json"
            with mock.patch.object(refresh.urllib.request, "urlopen", side_effect=fake_urlopen):
                result = refresh.fetch_fixture(output, 17)
            self.assertEqual(result, document)
            self.assertEqual(output.read_bytes(), payload)

        request = captured["request"]
        query = urllib.parse.parse_qs(urllib.parse.urlparse(request.full_url).query)
        self.assertEqual(query["period"], ["all"])
        self.assertEqual(query["include_ohlc"], ["true"])
        self.assertEqual(len(query["_refresh_nonce"]), 1)
        self.assertTrue(query["_refresh_nonce"][0].isdigit())
        self.assertEqual(request.get_header("Cache-control"), "no-cache")
        self.assertEqual(request.get_header("Pragma"), "no-cache")
        self.assertEqual(captured["timeout"], 17)


if __name__ == "__main__":
    unittest.main()
