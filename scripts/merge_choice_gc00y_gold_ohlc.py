#!/usr/bin/env python3
"""Backfill gold_cny daily OHLC from a Choice GC00Y XLSX export.

This utility only performs deterministic data conversion.  It deliberately writes a
versioned candidate instead of modifying the pinned public-history fixture in place.
It uses only Python's standard library, including zipfile/XML parsing for XLSX.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import posixpath
import re
import tempfile
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET
from zipfile import BadZipFile, ZipFile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tools/fixtures/backtest-history/public_history.json"
DEFAULT_SOURCE = ROOT / "tools/fixtures/backtest-history/sources/choice/GC00Y_daily_1990-01-03_2026-07-08.xlsx"
DEFAULT_OUTPUT = ROOT / "tools/fixtures/backtest-history/public_history_choice_gc00y_candidate.json"
DEFAULT_REPORT = ROOT / "tools/fixtures/backtest-history/public_history_choice_gc00y_report.json"
DEFAULT_MANIFEST = ROOT / "tools/fixtures/backtest-history/public_history_choice_gc00y_manifest.json"
TROY_OUNCE_GRAMS = 31.1034768
SOURCE_TAG = "choice-gc00y-daily-backfill"
EXPECTED_HEADERS = (
    "证券代码",
    "证券名称",
    "交易时间",
    "开盘价",
    "最高价",
    "最低价",
    "收盘价",
    "成交量",
)
MAIN_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"
OFFICE_REL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
CELL_REFERENCE = re.compile(r"^([A-Z]+)[1-9][0-9]*$")


class ValidationError(ValueError):
    """Raised when a source or fixture violates a fail-closed invariant."""


@dataclass(frozen=True)
class SourceRow:
    trading_date: str
    open_price: float
    high_price: float
    low_price: float
    close_price: float
    volume: float


@dataclass(frozen=True)
class ParsedSource:
    rows: tuple[SourceRow, ...]
    source_rows: int
    source_start: str | None
    source_end: str | None
    invalid_geometry_dates: tuple[str, ...]
    zero_volume: int
    metadata_footer: str | None
    sheet_name: str


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def stable_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
            temporary = handle.name
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def display_path(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return os.path.relpath(path.resolve(), root.resolve()).replace(os.sep, "/")


def _column_index(reference: str) -> int:
    match = CELL_REFERENCE.fullmatch(reference)
    if match is None:
        raise ValidationError(f"invalid XLSX cell reference: {reference!r}")
    result = 0
    for character in match.group(1):
        result = result * 26 + ord(character) - ord("A") + 1
    return result - 1


def _shared_strings(archive: ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in archive.namelist():
        return []
    try:
        root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
    except ET.ParseError as error:
        raise ValidationError(f"invalid XLSX shared strings XML: {error}") from error
    return ["".join(node.text or "" for node in item.iter(MAIN_NS + "t")) for item in root.findall(MAIN_NS + "si")]


def _select_worksheet(archive: ZipFile) -> tuple[str, str]:
    try:
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    except KeyError as error:
        raise ValidationError(f"XLSX is missing workbook metadata: {error}") from error
    except ET.ParseError as error:
        raise ValidationError(f"invalid XLSX workbook XML: {error}") from error

    relationship_targets = {
        item.attrib.get("Id"): item.attrib.get("Target")
        for item in relationships.findall(REL_NS + "Relationship")
        if item.attrib.get("Type", "").endswith("/worksheet")
    }
    sheets = workbook.findall(f"{MAIN_NS}sheets/{MAIN_NS}sheet")
    if not sheets:
        raise ValidationError("XLSX workbook has no worksheets")
    if len(sheets) == 1:
        selected = sheets[0]
    else:
        sheet0 = [sheet for sheet in sheets if sheet.attrib.get("name") == "Sheet0"]
        if len(sheet0) != 1:
            raise ValidationError("XLSX must contain one worksheet or exactly one worksheet named Sheet0")
        selected = sheet0[0]
    relationship_id = selected.attrib.get(OFFICE_REL_NS + "id")
    target = relationship_targets.get(relationship_id)
    if not target:
        raise ValidationError(f"worksheet relationship not found for {selected.attrib.get('name')!r}")
    normalized = posixpath.normpath(posixpath.join("xl", target.lstrip("/")))
    if normalized.startswith("../") or normalized not in archive.namelist():
        raise ValidationError(f"worksheet target is invalid or missing: {target!r}")
    return selected.attrib.get("name", ""), normalized


def _cell_value(cell: ET.Element, shared_strings: list[str]) -> str:
    cell_type = cell.attrib.get("t")
    if cell_type == "inlineStr":
        inline = cell.find(MAIN_NS + "is")
        return "" if inline is None else "".join(node.text or "" for node in inline.iter(MAIN_NS + "t"))
    value = cell.find(MAIN_NS + "v")
    text = "" if value is None or value.text is None else value.text
    if cell_type == "s":
        try:
            return shared_strings[int(text)]
        except (ValueError, IndexError) as error:
            raise ValidationError(f"invalid shared-string index: {text!r}") from error
    if cell_type == "b":
        return "1" if text == "1" else "0"
    return text


def _worksheet_rows(archive: ZipFile, worksheet_path: str, shared_strings: list[str]) -> list[list[str]]:
    rows: list[list[str]] = []
    try:
        with archive.open(worksheet_path) as stream:
            for _, element in ET.iterparse(stream, events=("end",)):
                if element.tag != MAIN_NS + "row":
                    continue
                values: list[str] = []
                for cell in element.findall(MAIN_NS + "c"):
                    index = _column_index(cell.attrib.get("r", ""))
                    while len(values) <= index:
                        values.append("")
                    values[index] = _cell_value(cell, shared_strings)
                rows.append(values)
                element.clear()
    except ET.ParseError as error:
        raise ValidationError(f"invalid XLSX worksheet XML: {error}") from error
    return rows


def _finite_number(value: str, field: str, row_number: int, *, positive: bool, nonnegative: bool = False) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise ValidationError(f"row {row_number}: {field} must be numeric, got {value!r}") from error
    if not math.isfinite(number):
        raise ValidationError(f"row {row_number}: {field} must be finite")
    if positive and number <= 0:
        raise ValidationError(f"row {row_number}: {field} must be positive")
    if nonnegative and number < 0:
        raise ValidationError(f"row {row_number}: {field} must be nonnegative")
    return number


def _excel_date(value: str, row_number: int) -> str:
    number = _finite_number(value, "交易时间", row_number, positive=False)
    if not number.is_integer():
        raise ValidationError(f"row {row_number}: Excel date serial must be an integer, got {value!r}")
    try:
        converted = date(1899, 12, 30) + timedelta(days=int(number))
    except OverflowError as error:
        raise ValidationError(f"row {row_number}: Excel date serial out of range: {value!r}") from error
    return converted.isoformat()


def parse_choice_xlsx(path: Path) -> ParsedSource:
    try:
        with ZipFile(path) as archive:
            sheet_name, worksheet_path = _select_worksheet(archive)
            rows = _worksheet_rows(archive, worksheet_path, _shared_strings(archive))
    except FileNotFoundError:
        raise
    except BadZipFile as error:
        raise ValidationError(f"source is not a valid XLSX ZIP archive: {path}") from error

    nonempty = [row for row in rows if any(str(value).strip() for value in row)]
    if not nonempty:
        raise ValidationError("XLSX worksheet is empty")
    headers = [str(value).strip() for value in nonempty[0]]
    missing = [header for header in EXPECTED_HEADERS if headers.count(header) != 1]
    if missing:
        raise ValidationError(f"XLSX header must contain each required field exactly once; invalid: {missing}")
    columns = {header: headers.index(header) for header in EXPECTED_HEADERS}

    parsed_rows: list[SourceRow] = []
    all_dates: list[str] = []
    invalid_geometry: list[str] = []
    metadata_footer: str | None = None
    zero_volume = 0
    footer_seen = False
    for row_number, row in enumerate(nonempty[1:], 2):
        values = [str(value).strip() for value in row]
        populated = [value for value in values if value]
        if populated == ["数据来源：妙想Choice"]:
            if footer_seen:
                raise ValidationError("duplicate Choice metadata footer")
            footer_seen = True
            metadata_footer = populated[0]
            continue
        if footer_seen:
            raise ValidationError("data row found after Choice metadata footer")

        def field(name: str) -> str:
            index = columns[name]
            return values[index] if index < len(values) else ""

        if field("证券代码") != "GC00Y":
            raise ValidationError(f"row {row_number}: security code must be GC00Y")
        if not field("证券名称"):
            raise ValidationError(f"row {row_number}: security name must not be empty")
        trading_date = _excel_date(field("交易时间"), row_number)
        parsed_date = date.fromisoformat(trading_date)
        if parsed_date.weekday() >= 5:
            raise ValidationError(f"row {row_number}: weekend trading date is forbidden: {trading_date}")
        if trading_date in all_dates:
            raise ValidationError(f"row {row_number}: duplicate trading date: {trading_date}")
        if all_dates and trading_date <= all_dates[-1]:
            raise ValidationError(
                f"row {row_number}: trading dates must be strictly increasing; {trading_date} follows {all_dates[-1]}"
            )
        all_dates.append(trading_date)
        open_price = _finite_number(field("开盘价"), "开盘价", row_number, positive=True)
        high_price = _finite_number(field("最高价"), "最高价", row_number, positive=True)
        low_price = _finite_number(field("最低价"), "最低价", row_number, positive=True)
        close_price = _finite_number(field("收盘价"), "收盘价", row_number, positive=True)
        volume = _finite_number(field("成交量"), "成交量", row_number, positive=False, nonnegative=True)
        if volume == 0:
            zero_volume += 1
        if high_price < max(open_price, close_price) or low_price > min(open_price, close_price):
            invalid_geometry.append(trading_date)
            continue
        parsed_rows.append(SourceRow(trading_date, open_price, high_price, low_price, close_price, volume))

    if not all_dates:
        raise ValidationError("XLSX contains no GC00Y data rows")
    return ParsedSource(
        rows=tuple(parsed_rows),
        source_rows=len(all_dates),
        source_start=all_dates[0],
        source_end=all_dates[-1],
        invalid_geometry_dates=tuple(invalid_geometry),
        zero_volume=zero_volume,
        metadata_footer=metadata_footer,
        sheet_name=sheet_name,
    )


def _series(document: dict[str, Any], symbol: str) -> dict[str, Any]:
    series = document.get("series")
    if not isinstance(series, list):
        raise ValidationError("fixture series must be a list")
    matches = [item for item in series if isinstance(item, dict) and item.get("symbol") == symbol]
    if len(matches) != 1:
        raise ValidationError(f"fixture must contain exactly one {symbol} series")
    return matches[0]


def _required_list(series: dict[str, Any], field: str, expected_length: int | None = None) -> list[Any]:
    value = series.get(field)
    if not isinstance(value, list):
        raise ValidationError(f"{series.get('symbol')}.{field} must be a list")
    if expected_length is not None and len(value) != expected_length:
        raise ValidationError(
            f"{series.get('symbol')}.{field} length {len(value)} does not match dates length {expected_length}"
        )
    return value


def _valid_positive(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def _validate_fixture(document: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any], list[str], list[float]]:
    gold = _series(document, "gold_cny")
    fx = _series(document, "usd_per_cny")
    dates = _required_list(gold, "dates")
    prices = _required_list(gold, "prices", len(dates))
    if not all(isinstance(item, str) for item in dates) or len(set(dates)) != len(dates) or dates != sorted(dates):
        raise ValidationError("gold_cny dates must be unique strings in increasing order")
    if not all(_valid_positive(item) for item in prices):
        raise ValidationError("gold_cny prices must be finite positive numbers")
    for field in ("open_prices", "high_prices", "low_prices", "close_prices", "volumes"):
        _required_list(gold, field, len(dates))
    fx_dates = _required_list(fx, "dates")
    fx_prices = _required_list(fx, "prices", len(fx_dates))
    if not all(isinstance(item, str) for item in fx_dates) or len(set(fx_dates)) != len(fx_dates):
        raise ValidationError("usd_per_cny dates must be unique strings")
    return gold, fx, dates, prices


def _ohlc_state(gold: dict[str, Any], prices: list[float], index: int) -> str:
    open_price = gold["open_prices"][index]
    high_price = gold["high_prices"][index]
    low_price = gold["low_prices"][index]
    close_price = gold["close_prices"][index]
    ohl = (open_price, high_price, low_price)
    if all(value is not None for value in ohl) and close_price is not None:
        if not all(_valid_positive(value) for value in (*ohl, close_price)):
            raise ValidationError(f"gold_cny has non-positive/non-finite OHLC at {gold['dates'][index]}")
        if high_price < max(open_price, close_price) or low_price > min(open_price, close_price):
            raise ValidationError(f"gold_cny has invalid existing OHLC geometry at {gold['dates'][index]}")
        return "complete"
    # Existing fixtures may carry canonical close in close_prices even before O/H/L are available.
    # Such a close-only placeholder is eligible. When filled, all four OHLC fields must come
    # from the same real Choice bar; the independent canonical strategy series is `prices`.
    if all(value is None for value in ohl) and (close_price is None or close_price == prices[index]):
        return "missing"
    raise ValidationError(f"gold_cny has partial OHLC at {gold['dates'][index]}; refusing ambiguous backfill")


def _file_entry(path: Path, payload: bytes, root: Path) -> dict[str, Any]:
    return {"path": display_path(path, root), "bytes": len(payload), "sha256": sha256_bytes(payload)}


def run_merge(
    *,
    fixture_path: Path,
    source_path: Path,
    output_path: Path,
    report_path: Path,
    manifest_path: Path,
    root: Path = ROOT,
) -> dict[str, Any]:
    paths = {
        "fixture": Path(fixture_path),
        "source": Path(source_path),
        "output": Path(output_path),
        "report": Path(report_path),
        "manifest": Path(manifest_path),
    }
    resolved = {name: path.resolve() for name, path in paths.items()}
    if resolved["output"] in (resolved["fixture"], resolved["source"]):
        raise ValidationError("output and input must not resolve to the same path; in-place overwrite is forbidden")
    write_paths = [resolved[name] for name in ("output", "report", "manifest")]
    if len(set(write_paths)) != len(write_paths):
        raise ValidationError("output, report, and manifest must resolve to distinct paths")

    fixture_bytes = paths["fixture"].read_bytes()
    source_bytes = paths["source"].read_bytes()
    try:
        original = json.loads(fixture_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"fixture is not valid UTF-8 JSON: {error}") from error
    if not isinstance(original, dict):
        raise ValidationError("fixture root must be a JSON object")

    parsed = parse_choice_xlsx(paths["source"])
    output = copy.deepcopy(original)
    gold, fx, gold_dates, gold_prices = _validate_fixture(output)
    states = [_ohlc_state(gold, gold_prices, index) for index in range(len(gold_dates))]
    gold_index = {value: index for index, value in enumerate(gold_dates)}
    fx_dates = _required_list(fx, "dates")
    fx_prices = _required_list(fx, "prices", len(fx_dates))
    fx_by_date = dict(zip(fx_dates, fx_prices))

    added_dates: list[str] = []
    preserved_dates: list[str] = []
    missing_fx_dates: list[str] = []
    not_in_gold_dates: list[str] = []
    eligible_dates: list[str] = []
    for row in parsed.rows:
        index = gold_index.get(row.trading_date)
        if index is None:
            not_in_gold_dates.append(row.trading_date)
            continue
        if states[index] == "complete":
            preserved_dates.append(row.trading_date)
            continue
        eligible_dates.append(row.trading_date)
        fx_value = fx_by_date.get(row.trading_date)
        if not _valid_positive(fx_value):
            missing_fx_dates.append(row.trading_date)
            continue
        divisor = float(fx_value) * TROY_OUNCE_GRAMS
        gold["open_prices"][index] = row.open_price / divisor
        gold["high_prices"][index] = row.high_price / divisor
        gold["low_prices"][index] = row.low_price / divisor
        gold["close_prices"][index] = row.close_price / divisor
        gold["volumes"][index] = row.volume
        states[index] = "complete"
        added_dates.append(row.trading_date)

    complete_before = sum(state == "complete" for state in [_ohlc_state(_series(original, "gold_cny"), _series(original, "gold_cny")["prices"], index) for index in range(len(gold_dates))])
    complete_after = sum(state == "complete" for state in states)
    before_ratio = complete_before / len(gold_dates) if gold_dates else 0.0
    after_ratio = complete_after / len(gold_dates) if gold_dates else 0.0
    gold["has_ohlc"] = complete_after > 0
    gold["ohlc_coverage_ratio"] = after_ratio
    source_value = gold.get("ohlc_source")
    tags = [] if not isinstance(source_value, str) or not source_value else source_value.split("+")
    if SOURCE_TAG not in tags:
        tags.append(SOURCE_TAG)
    gold["ohlc_source"] = "+".join(tags)

    source_rel = display_path(paths["source"], root)
    source_hash = sha256_bytes(source_bytes)
    gold["ohlc_backfill"] = {
        "source_path": source_rel,
        "source_sha256": source_hash,
        "source_sheet": parsed.sheet_name,
        "source_start": parsed.source_start,
        "source_end": parsed.source_end,
        "source_rows": parsed.source_rows,
        "valid_rows": len(parsed.rows),
        "added_count": len(added_dates),
        "invalid_dates": list(parsed.invalid_geometry_dates),
        "conversion_formula": "CNY/gram = GC_USD_per_troy_oz / usd_per_cny / 31.1034768",
        "fx_policy": "same-date usd_per_cny prices only; no forward-fill",
        "preserve_existing_policy": "existing complete OHLC always wins; canonical prices never change; missing four-field OHLC is filled from one Choice bar",
    }

    skipped_dates = {
        "invalid_geometry": list(parsed.invalid_geometry_dates),
        "missing_fx": missing_fx_dates,
        "not_in_gold_dates": not_in_gold_dates,
        "preserved_existing": preserved_dates,
    }
    report: dict[str, Any] = {
        "schema_version": "choice-gc00y-ohcl-backfill-report-v1".replace("ohcl", "ohlc"),
        "source_rows": parsed.source_rows,
        "valid_rows": len(parsed.rows),
        "source_start": parsed.source_start,
        "source_end": parsed.source_end,
        "duplicate": 0,
        "out_of_order": 0,
        "weekend": 0,
        "invalid_geometry": len(parsed.invalid_geometry_dates),
        "zero_volume": parsed.zero_volume,
        "metadata_footer": parsed.metadata_footer,
        "fixture_eligible": len(eligible_dates),
        "added": len(added_dates),
        "preserved_existing": len(preserved_dates),
        "missing_fx": len(missing_fx_dates),
        "not_in_gold_dates": len(not_in_gold_dates),
        "before_coverage": {"complete": complete_before, "total": len(gold_dates), "ratio": before_ratio},
        "after_coverage": {"complete": complete_after, "total": len(gold_dates), "ratio": after_ratio},
        "added_dates": added_dates,
        "skipped_dates": skipped_dates,
    }

    output_bytes = stable_json_bytes(output)
    report_bytes = stable_json_bytes(report)
    generated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    manifest = {
        "schema_version": "choice-gc00y-ohlc-backfill-manifest-v1",
        "generated_at": generated_at,
        "script": display_path(Path(__file__), root),
        "rules": {
            "instrument": "GC00Y daily OHLC",
            "excel_epoch": "1899-12-30",
            "conversion_formula": "CNY/gram = GC_USD_per_troy_oz / usd_per_cny / 31.1034768",
            "fx_policy": "same-date only; no forward-fill",
            "date_policy": "gold_cny dates are immutable; never add, delete, or reorder",
            "existing_ohlc_policy": "preserve complete existing OHLC; fail closed on partial OHLC",
            "invalid_geometry_policy": "skip and report; never repair",
        },
        "files": {
            "source": _file_entry(paths["source"], source_bytes, root),
            "input_fixture": _file_entry(paths["fixture"], fixture_bytes, root),
            "output_fixture": _file_entry(paths["output"], output_bytes, root),
            "report": _file_entry(paths["report"], report_bytes, root),
        },
    }
    manifest_bytes = stable_json_bytes(manifest)
    atomic_write(paths["output"], output_bytes)
    atomic_write(paths["report"], report_bytes)
    atomic_write(paths["manifest"], manifest_bytes)
    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    report = run_merge(
        fixture_path=args.fixture,
        source_path=args.source,
        output_path=args.output,
        report_path=args.report,
        manifest_path=args.manifest,
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
