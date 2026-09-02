#!/usr/bin/env python3
"""Tests for the Choice GC00Y OHLC backfill converter."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape
from zipfile import ZIP_DEFLATED, ZipFile

import merge_choice_gc00y_gold_ohlc as merger


HEADERS = ["证券代码", "证券名称", "交易时间", "开盘价", "最高价", "最低价", "收盘价", "成交量"]


def excel_serial(value: str) -> int:
    return (date.fromisoformat(value) - date(1899, 12, 30)).days


def column_name(index: int) -> str:
    result = ""
    while index:
        index, remainder = divmod(index - 1, 26)
        result = chr(65 + remainder) + result
    return result


def make_xlsx(path: Path, rows: list[list[object]], footer: bool = True) -> None:
    all_rows = [HEADERS] + rows
    if footer:
        all_rows.append(["数据来源：妙想Choice"])
    xml_rows = []
    for row_number, row in enumerate(all_rows, 1):
        cells = []
        for column, value in enumerate(row, 1):
            reference = f"{column_name(column)}{row_number}"
            if isinstance(value, (int, float)):
                cells.append(f'<c r="{reference}"><v>{value}</v></c>')
            else:
                cells.append(
                    f'<c r="{reference}" t="inlineStr"><is><t>{escape(str(value))}</t></is></c>'
                )
        xml_rows.append(f'<row r="{row_number}">{"".join(cells)}</row>')
    worksheet = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<sheetData>{"".join(xml_rows)}</sheetData></worksheet>'
    )
    workbook = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet0" sheetId="1" r:id="rId1"/></sheets></workbook>'
    )
    relationships = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet1.xml"/></Relationships>'
    )
    with ZipFile(path, "w", ZIP_DEFLATED) as archive:
        archive.writestr("xl/workbook.xml", workbook)
        archive.writestr("xl/_rels/workbook.xml.rels", relationships)
        archive.writestr("xl/worksheets/sheet1.xml", worksheet)


def fixture_document() -> dict:
    dates = ["2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05"]
    prices = [450.0, 451.0, 452.0, 453.0]
    return {
        "success": True,
        "series": [
            {
                "symbol": "gold_cny",
                "dates": dates,
                "prices": prices,
                "observed": [True, True, True, True],
                # A close equal to canonical prices is a close-only placeholder, not partial OHLC.
                "open_prices": [None, 440.0, None, None],
                "high_prices": [None, 460.0, None, None],
                "low_prices": [None, 430.0, None, None],
                "close_prices": prices.copy(),
                "volumes": [None, 99.0, None, None],
                "has_ohlc": True,
                "ohlc_coverage_ratio": 0.25,
                "ohlc_source": "existing-source",
            },
            {
                "symbol": "usd_per_cny",
                "dates": ["2024-01-02", "2024-01-03", "2024-01-05"],
                "prices": [0.14, 0.14, 0.14],
            },
        ],
    }


class MergeChoiceGC00YTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = self.root / "fixture.json"
        self.source = self.root / "source.xlsx"
        self.output = self.root / "candidate.json"
        self.report = self.root / "report.json"
        self.manifest = self.root / "manifest.json"
        self.fixture.write_text(json.dumps(fixture_document()), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_merge(self) -> tuple[dict, dict, dict]:
        merger.run_merge(
            fixture_path=self.fixture,
            source_path=self.source,
            output_path=self.output,
            report_path=self.report,
            manifest_path=self.manifest,
            root=self.root,
        )
        return tuple(
            json.loads(path.read_text(encoding="utf-8"))
            for path in (self.output, self.report, self.manifest)
        )

    def test_conversion_preserves_existing_and_does_not_forward_fill_fx(self) -> None:
        make_xlsx(
            self.source,
            [
                ["GC00Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 0],
                ["GC00Y", "Gold", excel_serial("2024-01-03"), 2100, 2120, 2080, 2110, 10],
                ["GC00Y", "Gold", excel_serial("2024-01-04"), 2200, 2220, 2180, 2210, 20],
            ],
        )
        output, report, _ = self.run_merge()
        gold = output["series"][0]
        divisor = 0.14 * merger.TROY_OUNCE_GRAMS
        self.assertAlmostEqual(gold["open_prices"][0], 2000 / divisor)
        self.assertAlmostEqual(gold["high_prices"][0], 2020 / divisor)
        self.assertAlmostEqual(gold["low_prices"][0], 1980 / divisor)
        # K-line close comes from the same Choice bar; canonical `prices` remains separate.
        self.assertAlmostEqual(gold["close_prices"][0], 2010 / divisor)
        self.assertEqual(gold["prices"][0], 450.0)
        self.assertEqual(gold["volumes"][0], 0)
        self.assertEqual(gold["open_prices"][1:2], [440.0])
        self.assertEqual(gold["high_prices"][1:2], [460.0])
        self.assertEqual(gold["low_prices"][1:2], [430.0])
        self.assertEqual(gold["close_prices"][1:2], [451.0])
        self.assertEqual(gold["volumes"][1:2], [99.0])
        self.assertIsNone(gold["open_prices"][2])
        self.assertEqual(report["added"], 1)
        self.assertEqual(report["preserved_existing"], 1)
        self.assertEqual(report["missing_fx"], 1)
        self.assertEqual(report["zero_volume"], 1)
        self.assertIn("2024-01-04", report["skipped_dates"]["missing_fx"])

    def test_invalid_geometry_is_skipped_and_reported(self) -> None:
        make_xlsx(
            self.source,
            [["GC00Y", "Gold", excel_serial("2024-01-05"), 2000, 1990, 1980, 2010, 5]],
        )
        output, report, _ = self.run_merge()
        self.assertIsNone(output["series"][0]["open_prices"][3])
        self.assertEqual(report["invalid_geometry"], 1)
        self.assertEqual(report["skipped_dates"]["invalid_geometry"], ["2024-01-05"])

    def test_source_dates_not_in_gold_are_reported(self) -> None:
        make_xlsx(
            self.source,
            [["GC00Y", "Gold", excel_serial("2024-01-08"), 2000, 2020, 1980, 2010, 5]],
        )
        _, report, _ = self.run_merge()
        self.assertEqual(report["not_in_gold_dates"], 1)
        self.assertEqual(report["skipped_dates"]["not_in_gold_dates"], ["2024-01-08"])

    def test_partial_ohlc_fails_closed(self) -> None:
        document = fixture_document()
        gold = document["series"][0]
        gold["open_prices"][0] = 440.0
        self.fixture.write_text(json.dumps(document), encoding="utf-8")
        make_xlsx(
            self.source,
            [["GC00Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 5]],
        )
        with self.assertRaisesRegex(merger.ValidationError, "partial OHLC"):
            self.run_merge()
        self.assertFalse(self.output.exists())

    def test_duplicate_and_out_of_order_dates_fail(self) -> None:
        row = ["GC00Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 5]
        make_xlsx(self.source, [row, row])
        with self.assertRaisesRegex(merger.ValidationError, "duplicate"):
            self.run_merge()
        make_xlsx(
            self.source,
            [
                ["GC00Y", "Gold", excel_serial("2024-01-03"), 2000, 2020, 1980, 2010, 5],
                ["GC00Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 5],
            ],
        )
        with self.assertRaisesRegex(merger.ValidationError, "strictly increasing"):
            self.run_merge()

    def test_weekend_and_wrong_symbol_fail_strict_validation(self) -> None:
        make_xlsx(
            self.source,
            [["GC00Y", "Gold", excel_serial("2024-01-06"), 2000, 2020, 1980, 2010, 5]],
        )
        with self.assertRaisesRegex(merger.ValidationError, "weekend"):
            self.run_merge()
        make_xlsx(
            self.source,
            [["GC99Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 5]],
        )
        with self.assertRaisesRegex(merger.ValidationError, "GC00Y"):
            self.run_merge()

    def test_refuses_in_place_output(self) -> None:
        make_xlsx(
            self.source,
            [["GC00Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 5]],
        )
        with self.assertRaisesRegex(merger.ValidationError, "same path"):
            merger.run_merge(
                fixture_path=self.fixture,
                source_path=self.source,
                output_path=self.fixture,
                report_path=self.report,
                manifest_path=self.manifest,
                root=self.root,
            )

    def test_metadata_manifest_hashes_and_idempotent_source_tag(self) -> None:
        make_xlsx(
            self.source,
            [["GC00Y", "Gold", excel_serial("2024-01-02"), 2000, 2020, 1980, 2010, 5]],
        )
        output, report, manifest = self.run_merge()
        gold = output["series"][0]
        self.assertEqual(gold["ohlc_source"], "existing-source+choice-gc00y-daily-backfill")
        self.assertTrue(gold["has_ohlc"])
        self.assertEqual(gold["ohlc_coverage_ratio"], 0.5)
        self.assertEqual(gold["ohlc_backfill"]["source_sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertEqual(report["source_rows"], 1)
        self.assertEqual(report["valid_rows"], 1)
        self.assertEqual(report["source_start"], "2024-01-02")
        self.assertEqual(report["source_end"], "2024-01-02")
        for key, path in {
            "source": self.source,
            "input_fixture": self.fixture,
            "output_fixture": self.output,
            "report": self.report,
        }.items():
            entry = manifest["files"][key]
            self.assertEqual(entry["bytes"], path.stat().st_size)
            self.assertEqual(entry["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(entry["path"], path.name)
        self.assertIn("generated_at", manifest)
        self.assertIn("script", manifest)
        self.assertTrue(self.output.read_bytes().endswith(b"\n"))
        self.assertTrue(self.report.read_bytes().endswith(b"\n"))
        self.assertTrue(self.manifest.read_bytes().endswith(b"\n"))


if __name__ == "__main__":
    unittest.main()
