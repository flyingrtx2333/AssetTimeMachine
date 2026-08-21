#!/usr/bin/env python3
"""Fetch official CFTC TFF equity-index positioning for feasibility research only.

This script intentionally does not assign historical availability timestamps and does
not compute any strategy or factor performance. Report dates are CFTC position dates,
not release dates; availability must be audited separately before any formal trial.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import subprocess
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Any

USER_AGENT = "AssetTimeMachine-COT-Feasibility/1.0"
CFTC_ANNUAL_URL = "https://www.cftc.gov/files/dea/history/fut_fin_txt_{year}.zip"
CFTC_EARLY_HISTORY_URL = "https://www.cftc.gov/files/dea/history/fin_fut_txt_2006_2016.zip"
CONSOLIDATED_START_DATE = "2010-06-15"
ANNUAL_TFF_START_DATE = "2010-07-20"
TARGETS = {
    "13874+": "sp500_consolidated",
    "20974+": "nasdaq100_consolidated",
}
FIELDS = [
    "Report_Date_as_YYYY-MM-DD",
    "CFTC_Contract_Market_Code",
    "CFTC_Commodity_Code",
    "Market_and_Exchange_Names",
    "Open_Interest_All",
    "Dealer_Positions_Long_All",
    "Dealer_Positions_Short_All",
    "Asset_Mgr_Positions_Long_All",
    "Asset_Mgr_Positions_Short_All",
    "Lev_Money_Positions_Long_All",
    "Lev_Money_Positions_Short_All",
    "Other_Rept_Positions_Long_All",
    "Other_Rept_Positions_Short_All",
    "NonRept_Positions_Long_All",
    "NonRept_Positions_Short_All",
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, timeout: int = 45) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/zip"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except Exception as first_error:
        completed = subprocess.run(
            [
                "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors",
                "--connect-timeout", "10", "--max-time", str(max(timeout, 45)),
                "-A", USER_AGENT, "-H", "Accept: application/zip", url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout
        raise RuntimeError(
            f"CFTC request failed: {url}; urllib={first_error}; "
            f"curl={completed.stderr.decode('utf-8', 'ignore').strip()}"
        )


def normalized_code(raw: Any) -> str:
    return str(raw or "").strip()


def canonical_report_date(row: dict[str, str]) -> str | None:
    candidates = [
        str(row.get("Report_Date_as_YYYY-MM-DD") or "").strip(),
        str(row.get("Report_Date_as_MM_DD_YYYY") or "").strip(),
    ]
    for raw in candidates:
        if not raw:
            continue
        for fmt in ("%Y-%m-%d", "%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y", "%m_%d_%Y"):
            try:
                return datetime.strptime(raw, fmt).date().isoformat()
            except ValueError:
                pass
    yymmdd = str(row.get("As_of_Date_In_Form_YYMMDD") or "").strip()
    if yymmdd:
        try:
            return datetime.strptime(yymmdd, "%y%m%d").date().isoformat()
        except ValueError:
            pass
    return None


def parse_archive(
    payload: bytes,
    *,
    source_label: str,
    min_report_date: str | None = None,
    max_report_date: str | None = None,
) -> list[dict[str, str]]:
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        names = [name for name in archive.namelist() if name.lower().endswith((".txt", ".csv"))]
        if len(names) != 1:
            raise RuntimeError(f"unexpected CFTC archive members for {source_label}: {archive.namelist()}")
        with archive.open(names[0]) as raw:
            reader = csv.DictReader(io.TextIOWrapper(raw, encoding="latin1"))
            required_fields = [field for field in FIELDS if field != "Report_Date_as_YYYY-MM-DD"]
            missing = [field for field in required_fields if field not in (reader.fieldnames or [])]
            if missing:
                raise RuntimeError(f"CFTC {source_label} missing columns: {missing}")
            rows: list[dict[str, str]] = []
            for row in reader:
                contract_code = normalized_code(row.get("CFTC_Contract_Market_Code"))
                if contract_code not in TARGETS:
                    continue
                report_date = canonical_report_date(row)
                if report_date is None:
                    continue
                if min_report_date is not None and report_date < min_report_date:
                    continue
                if max_report_date is not None and report_date > max_report_date:
                    continue
                result = {field: str(row.get(field) or "").strip() for field in FIELDS}
                result["Report_Date_as_YYYY-MM-DD"] = report_date
                result["normalized_market"] = TARGETS[contract_code]
                result["source_year"] = report_date[:4]
                result["source_archive"] = source_label
                rows.append(result)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start-year", type=int, default=2006)
    parser.add_argument("--end-year", type=int, default=2026)
    args = parser.parse_args()
    if args.start_year > args.end_year:
        raise SystemExit("start-year must be <= end-year")

    all_rows: list[dict[str, str]] = []
    archives: dict[str, Any] = {}

    if args.start_year <= 2010:
        payload = request_bytes(CFTC_EARLY_HISTORY_URL)
        digest = hashlib.sha256(payload).hexdigest()
        early_min = max(f"{args.start_year:04d}-01-01", CONSOLIDATED_START_DATE)
        early_max = "2010-07-19" if args.end_year >= 2010 else f"{args.end_year:04d}-12-31"
        rows = parse_archive(
            payload,
            source_label="2006-2016-history",
            min_report_date=early_min,
            max_report_date=early_max,
        )
        all_rows.extend(rows)
        archives["2006-2016-history"] = {
            "url": CFTC_EARLY_HISTORY_URL,
            "sha256": digest,
            "filtered_rows": len(rows),
            "used_report_date_range": [early_min, early_max],
        }
        print(
            f"COT_TFF_EARLY_HISTORY_FETCHED rows={len(rows)} min={early_min} max={early_max} sha256={digest}"
        )

    annual_start_year = max(args.start_year, 2010)
    for year in range(annual_start_year, args.end_year + 1):
        url = CFTC_ANNUAL_URL.format(year=year)
        payload = request_bytes(url)
        digest = hashlib.sha256(payload).hexdigest()
        min_report_date = ANNUAL_TFF_START_DATE if year == 2010 else f"{year:04d}-01-01"
        max_report_date = f"{year:04d}-12-31"
        rows = parse_archive(
            payload,
            source_label=f"annual-{year}",
            min_report_date=min_report_date,
            max_report_date=max_report_date,
        )
        all_rows.extend(rows)
        archives[str(year)] = {
            "url": url,
            "sha256": digest,
            "filtered_rows": len(rows),
            "used_report_date_range": [min_report_date, max_report_date],
        }
        print(f"COT_TFF_YEAR_FETCHED year={year} rows={len(rows)} sha256={digest}")

    all_rows.sort(key=lambda row: (row["Report_Date_as_YYYY-MM-DD"], row["normalized_market"]))
    if not all_rows:
        raise RuntimeError("no target CFTC TFF rows found")
    seen: set[tuple[str, str]] = set()
    for row in all_rows:
        key = (row["Report_Date_as_YYYY-MM-DD"], row["normalized_market"])
        if key in seen:
            raise RuntimeError(f"duplicate target market/report date: {key}")
        seen.add(key)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "TFF_EQUITY_INDEX_RAW.csv"
    output_fields = ["normalized_market", "source_year", "source_archive", *FIELDS]
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=output_fields)
        writer.writeheader()
        writer.writerows(all_rows)

    coverage: dict[str, Any] = {}
    for market in TARGETS.values():
        rows = [row for row in all_rows if row["normalized_market"] == market]
        coverage[market] = {
            "rows": len(rows),
            "first_report_date": rows[0]["Report_Date_as_YYYY-MM-DD"] if rows else None,
            "last_report_date": rows[-1]["Report_Date_as_YYYY-MM-DD"] if rows else None,
            "commodity_codes": sorted({normalized_code(row["CFTC_Commodity_Code"]) for row in rows}),
            "contract_market_codes": sorted({normalized_code(row["CFTC_Contract_Market_Code"]) for row in rows}),
        }
    summary = {
        "purpose": "CFTC TFF equity-index positioning feasibility; no factor signal and no performance",
        "performance_computed": False,
        "historical_availability_assigned": False,
        "critical_point_in_time_warning": (
            "Report_Date_as_YYYY-MM-DD is the CFTC position/report date, not the public release timestamp. "
            "No row may be consumed by a formal backtest until a separate release-availability policy handles normal Friday publication, holidays, and shutdown/backlog exceptions."
        ),
        "source": "CFTC Traders in Financial Futures, futures only; 2006-2010 early history archive plus annual compressed archives from 2010-07-20 onward",
        "years": [args.start_year, args.end_year],
        "targets": TARGETS,
        "coverage": coverage,
        "archives": archives,
        "output_sha256": sha256(output_path),
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"COT_TFF_FEASIBILITY_COMPLETE rows={len(all_rows)} output={output_path} "
        f"sha256={summary['output_sha256']} summary_sha256={sha256(summary_path)}"
    )
    for market, item in coverage.items():
        print(
            f"COT_TFF_COVERAGE market={market} rows={item['rows']} "
            f"first={item['first_report_date']} last={item['last_report_date']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
