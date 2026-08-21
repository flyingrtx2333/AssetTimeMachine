#!/usr/bin/env python3
"""Fetch and normalize FINRA monthly margin statistics without strategy performance.

The official source is an XLSX file. To keep the research tool dependency-free, this
script reads the OOXML worksheet directly with Python's standard library. It does not
save or modify the workbook; it records the source SHA-256 and emits a plain CSV.

Point-in-time policy: FINRA says margin statistics are generally published in the
third week of the month following the reference month. We conservatively make each
reference month usable only on the first calendar day of the *second* following
month, which is later than the stated normal publication window.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import re
import urllib.request
import zipfile
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from typing import Any

SOURCE_URL = "https://www.finra.org/sites/default/files/2021-03/margin-statistics.xlsx"
USER_AGENT = "AssetTimeMachine-FINRAMarginFeasibility/1.0"
UNIFIED_START_MONTH = "2010-02"
EXPECTED_HEADERS = [
    "Year-Month",
    "Debit Balances in Customers' Securities Margin Accounts",
    "Free Credit Balances in Customers' Cash Accounts",
    "Free Credit Balances in Customers' Securities Margin Accounts",
]
NS = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def column_index(reference: str) -> int:
    match = re.match(r"([A-Z]+)", reference)
    if not match:
        raise RuntimeError(f"invalid XLSX cell reference: {reference}")
    result = 0
    for char in match.group(1):
        result = result * 26 + (ord(char) - ord("A") + 1)
    return result - 1


def cell_text(cell: ET.Element) -> str:
    cell_type = cell.attrib.get("t")
    if cell_type == "inlineStr":
        return "".join(node.text or "" for node in cell.findall(".//x:t", NS)).strip()
    value = cell.find("x:v", NS)
    return (value.text or "").strip() if value is not None else ""


def parse_first_sheet(payload: bytes) -> list[list[str]]:
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        if "xl/worksheets/sheet1.xml" not in archive.namelist():
            raise RuntimeError("FINRA workbook missing sheet1.xml")
        root = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
    rows: list[list[str]] = []
    for row in root.findall(".//x:sheetData/x:row", NS):
        values = [""] * 4
        for cell in row.findall("x:c", NS):
            index = column_index(cell.attrib.get("r", ""))
            if 0 <= index < len(values):
                values[index] = cell_text(cell)
        rows.append(values)
    if not rows or rows[0] != EXPECTED_HEADERS:
        raise RuntimeError(f"unexpected FINRA workbook headers: {rows[0] if rows else None}")
    return rows


def finite_number(raw: Any, *, field: str, month: str) -> float:
    try:
        value = float(str(raw).replace(",", "").strip())
    except (TypeError, ValueError) as error:
        raise RuntimeError(f"invalid {field} month={month}: {raw!r}") from error
    if not math.isfinite(value):
        raise RuntimeError(f"non-finite {field} month={month}")
    return value


def conservative_available_date(month: str) -> str:
    year, number = map(int, month.split("-"))
    number += 2
    if number > 12:
        year += (number - 1) // 12
        number = (number - 1) % 12 + 1
    return date(year, number, 1).isoformat()


def parse_rows(sheet_rows: list[list[str]]) -> list[dict[str, Any]]:
    parsed: list[dict[str, Any]] = []
    for values in sheet_rows[1:]:
        month = values[0].strip()
        if not re.fullmatch(r"\d{4}-\d{2}", month) or month < UNIFIED_START_MONTH:
            continue
        debit = finite_number(values[1], field="debit", month=month)
        free_cash = finite_number(values[2], field="free_cash", month=month)
        free_margin = finite_number(values[3], field="free_margin", month=month)
        denominator = free_cash + free_margin
        if debit < 0 or free_cash < 0 or free_margin < 0 or denominator <= 0:
            raise RuntimeError(f"invalid FINRA balances month={month}")
        parsed.append({
            "reference_month": month,
            "conservative_available_date": conservative_available_date(month),
            "debit_millions": debit,
            "free_credit_cash_millions": free_cash,
            "free_credit_margin_millions": free_margin,
            "leverage_ratio": debit / denominator,
        })
    parsed.sort(key=lambda row: row["reference_month"])
    if not parsed:
        raise RuntimeError("no unified FINRA margin rows")
    if len({row["reference_month"] for row in parsed}) != len(parsed):
        raise RuntimeError("duplicate FINRA reference month")
    previous_ratio: float | None = None
    previous_month: str | None = None
    for row in parsed:
        row["prior_reference_month"] = previous_month or ""
        row["delta_leverage_ratio"] = "" if previous_ratio is None else row["leverage_ratio"] - previous_ratio
        previous_ratio = row["leverage_ratio"]
        previous_month = row["reference_month"]
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    payload = request_bytes(SOURCE_URL)
    rows = parse_rows(parse_first_sheet(payload))
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "FINRA_MARGIN_LEVERAGE.csv"
    fields = [
        "reference_month",
        "conservative_available_date",
        "debit_millions",
        "free_credit_cash_millions",
        "free_credit_margin_millions",
        "leverage_ratio",
        "prior_reference_month",
        "delta_leverage_ratio",
    ]
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    usable = [row for row in rows if row["delta_leverage_ratio"] != ""]
    summary = {
        "purpose": "FINRA margin leverage feasibility; no strategy performance",
        "performance_computed": False,
        "source": "FINRA Margin Statistics",
        "source_url": SOURCE_URL,
        "source_xlsx_sha256": sha256_bytes(payload),
        "unified_start_month": UNIFIED_START_MONTH,
        "rows": len(rows),
        "usable_delta_rows": len(usable),
        "first_reference_month": rows[0]["reference_month"],
        "last_reference_month": rows[-1]["reference_month"],
        "first_usable_available_date": usable[0]["conservative_available_date"],
        "last_usable_available_date": usable[-1]["conservative_available_date"],
        "factor_definition": "debit / (free credit in cash accounts + free credit in securities margin accounts)",
        "raw_state_not_yet_strategy_executed": "delta_leverage_ratio > 0",
        "availability_policy": "reference month is usable only on first calendar day of the second following month",
        "availability_rationale": "FINRA states updates are generally published in the third week of the month following the reference month; this policy is deliberately later",
        "source_schema_note": "Use only 2010-02 onward unified FINRA Rule 4521-era rows; pre-2010 legacy NYSE/FINRA free-credit aggregation is excluded",
        "output_sha256": sha256_file(output_path),
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "FINRA_MARGIN_FEASIBILITY_COMPLETE "
        f"rows={len(rows)} usable={len(usable)} first={rows[0]['reference_month']} last={rows[-1]['reference_month']} "
        f"output_sha256={summary['output_sha256']} source_sha256={summary['source_xlsx_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
