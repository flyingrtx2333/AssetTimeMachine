#!/usr/bin/env python3
"""Build frozen weekly SEC insider-buy breadth without strategy performance.

Source: SEC Insider Transactions Data Sets, quarterly Form 3/4/5 bulk ZIPs.
Only initial Form 4 filings are used. A filing qualifies as an open-market buy filing
when NONDERIV_TRANS contains at least one transaction with TRANS_CODE=P and
TRANS_ACQUIRED_DISP_CD=A. Amendments (4/A), derivative transactions, sales, grants,
option exercises and other transaction codes are excluded.

The factor input is weekly issuer breadth, not raw transaction count: each issuer CIK
is counted at most once per filing week even if multiple insiders or transactions are
reported. A completed Monday-Friday filing week becomes usable on the following
Tuesday. This deliberately avoids relying on unavailable historical acceptance times.
No strategy performance is calculated here.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import subprocess
import time
import urllib.error
import urllib.request
import zipfile
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

USER_AGENT = "AssetTimeMachine/1.0 https://resume.flyingrtx.com"
NEW_BASE = "https://www.sec.gov/files/datastandardsinnovation/data/insider-transactions-data-sets/"
LEGACY_BASE = "https://www.sec.gov/files/structureddata/data/insider-transactions-data-sets/"
REQUIRED_SUBMISSION = {
    "ACCESSION_NUMBER",
    "FILING_DATE",
    "DOCUMENT_TYPE",
    "ISSUERCIK",
    "ISSUERTRADINGSYMBOL",
}
REQUIRED_TRANS = {
    "ACCESSION_NUMBER",
    "TRANS_FORM_TYPE",
    "TRANS_CODE",
    "TRANS_ACQUIRED_DISP_CD",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quarter_ids(start_year: int, start_quarter: int, end_year: int, end_quarter: int) -> list[str]:
    if not (1 <= start_quarter <= 4 and 1 <= end_quarter <= 4):
        raise ValueError("quarter must be 1..4")
    start = start_year * 4 + (start_quarter - 1)
    end = end_year * 4 + (end_quarter - 1)
    if start > end:
        raise ValueError("start quarter must not exceed end quarter")
    result: list[str] = []
    for value in range(start, end + 1):
        year, offset = divmod(value, 4)
        result.append(f"{year}q{offset + 1}")
    return result


def request_archive(quarter: str, timeout: int = 60) -> tuple[bytes, str]:
    headers = {"User-Agent": USER_AGENT, "Accept": "application/zip"}
    last_error: Exception | str | None = None
    for base in (NEW_BASE, LEGACY_BASE):
        url = f"{base}{quarter}_form345.zip"
        for attempt in range(3):
            request = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    return response.read(), url
            except urllib.error.HTTPError as error:
                last_error = error
                if error.code == 404:
                    break
                if attempt == 2:
                    raise
            except (urllib.error.URLError, OSError) as error:
                last_error = error
            time.sleep(0.5 * (attempt + 1))

        completed = subprocess.run(
            [
                "curl",
                "--http1.1",
                "-fsSL",
                "--retry",
                "3",
                "--retry-all-errors",
                "--connect-timeout",
                "10",
                "--max-time",
                str(max(timeout, 60)),
                "-A",
                USER_AGENT,
                "-H",
                "Accept: application/zip",
                url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout, url
        last_error = completed.stderr.decode("utf-8", "ignore").strip() or last_error
    raise RuntimeError(f"SEC insider archive unavailable for {quarter}: {last_error}")


def parse_sec_date(raw: str) -> date:
    value = raw.strip()
    for fmt in ("%d-%b-%Y", "%Y-%m-%d", "%m/%d/%Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"unsupported SEC date: {raw!r}")


def validate_headers(reader: csv.DictReader, required: set[str], *, label: str) -> None:
    missing = required - set(reader.fieldnames or [])
    if missing:
        raise RuntimeError(f"{label} missing required fields: {sorted(missing)}")


def extract_quarter(payload: bytes, quarter: str) -> list[dict[str, str]]:
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for name in ("SUBMISSION.tsv", "NONDERIV_TRANS.tsv"):
            if name not in archive.namelist():
                raise RuntimeError(f"{quarter} missing {name}")

        submissions: dict[str, tuple[str, str, str]] = {}
        with archive.open("SUBMISSION.tsv") as raw:
            reader = csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig", errors="replace"), delimiter="\t")
            validate_headers(reader, REQUIRED_SUBMISSION, label=f"{quarter} SUBMISSION.tsv")
            for row in reader:
                if (row.get("DOCUMENT_TYPE") or "").strip() != "4":
                    continue
                accession = (row.get("ACCESSION_NUMBER") or "").strip()
                filing_date = (row.get("FILING_DATE") or "").strip()
                issuer_cik = (row.get("ISSUERCIK") or "").strip()
                symbol = (row.get("ISSUERTRADINGSYMBOL") or "").strip()
                if not accession or not filing_date or not issuer_cik:
                    continue
                parse_sec_date(filing_date)
                submissions[accession] = (filing_date, issuer_cik, symbol)

        buy_accessions: set[str] = set()
        with archive.open("NONDERIV_TRANS.tsv") as raw:
            reader = csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig", errors="replace"), delimiter="\t")
            validate_headers(reader, REQUIRED_TRANS, label=f"{quarter} NONDERIV_TRANS.tsv")
            for row in reader:
                accession = (row.get("ACCESSION_NUMBER") or "").strip()
                if accession not in submissions:
                    continue
                if (row.get("TRANS_FORM_TYPE") or "").strip() not in ("", "4"):
                    continue
                if (row.get("TRANS_CODE") or "").strip() != "P":
                    continue
                if (row.get("TRANS_ACQUIRED_DISP_CD") or "").strip() != "A":
                    continue
                buy_accessions.add(accession)

    output: list[dict[str, str]] = []
    for accession in sorted(buy_accessions):
        filing_date, issuer_cik, symbol = submissions[accession]
        output.append(
            {
                "quarter": quarter,
                "accession_number": accession,
                "filing_date": parse_sec_date(filing_date).isoformat(),
                "issuer_cik": issuer_cik,
                "issuer_trading_symbol": symbol,
            }
        )
    return output


def monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def build_weekly_breadth(evidence: list[dict[str, str]], final_complete_date: date) -> list[dict[str, Any]]:
    if not evidence:
        raise RuntimeError("no SEC open-market buy filings found")
    issuer_by_week: dict[date, set[str]] = defaultdict(set)
    for row in evidence:
        filing_day = date.fromisoformat(row["filing_date"])
        issuer_by_week[monday_of(filing_day)].add(row["issuer_cik"])

    first_week = min(issuer_by_week)
    final_week = monday_of(final_complete_date)
    # The final week may be partial if the archive stops before Friday. Only complete
    # Monday-Friday weeks may become factor observations.
    if final_week + timedelta(days=4) > final_complete_date:
        final_week -= timedelta(days=7)

    output: list[dict[str, Any]] = []
    previous_count: int | None = None
    week = first_week
    while week <= final_week:
        count = len(issuer_by_week.get(week, set()))
        delta = None if previous_count is None else count - previous_count
        available = week + timedelta(days=8)  # following Tuesday
        output.append(
            {
                "week_start": week.isoformat(),
                "week_end": (week + timedelta(days=4)).isoformat(),
                "conservative_available_date": available.isoformat(),
                "open_market_buy_issuer_count": count,
                "prior_week_buy_issuer_count": "" if previous_count is None else previous_count,
                "delta_buy_issuer_count": "" if delta is None else delta,
            }
        )
        previous_count = count
        week += timedelta(days=7)
    return output


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start-year", type=int, default=2012)
    parser.add_argument("--start-quarter", type=int, default=1)
    parser.add_argument("--end-year", type=int, default=2026)
    parser.add_argument("--end-quarter", type=int, default=2)
    parser.add_argument("--request-pause-seconds", type=float, default=0.12)
    args = parser.parse_args()
    if not math.isfinite(args.request_pause_seconds) or args.request_pause_seconds < 0:
        raise SystemExit("request pause must be finite and >=0")

    quarters = quarter_ids(args.start_year, args.start_quarter, args.end_year, args.end_quarter)
    output_dir = Path(args.output_dir)
    cache_dir = output_dir / "quarter-evidence"
    cache_dir.mkdir(parents=True, exist_ok=True)
    evidence: list[dict[str, str]] = []
    sources: dict[str, Any] = {}
    final_date: date | None = None

    for index, quarter in enumerate(quarters):
        cache_path = cache_dir / f"{quarter}.json"
        if cache_path.is_file():
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            if cached.get("cache_schema") != "sec-insider-buy-breadth-v1" or cached.get("quarter") != quarter:
                raise RuntimeError(f"invalid SEC insider quarter cache: {cache_path}")
            rows = cached.get("evidence")
            source = cached.get("source")
            if not isinstance(rows, list) or not isinstance(source, dict):
                raise RuntimeError(f"incomplete SEC insider quarter cache: {cache_path}")
            print(
                f"SEC_INSIDER_QUARTER_CACHED quarter={quarter} buys={len(rows)} "
                f"sha256={source.get('sha256', '')}",
                flush=True,
            )
        else:
            payload, url = request_archive(quarter)
            rows = extract_quarter(payload, quarter)
            source_hash = sha256_bytes(payload)
            source = {
                "url": url,
                "sha256": source_hash,
                "bytes": len(payload),
                "open_market_buy_form4_filings": len(rows),
            }
            cache_document = {
                "cache_schema": "sec-insider-buy-breadth-v1",
                "quarter": quarter,
                "source": source,
                "evidence": rows,
            }
            temp_path = cache_path.with_suffix(".json.tmp")
            temp_path.write_text(
                json.dumps(cache_document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            temp_path.replace(cache_path)
            print(
                f"SEC_INSIDER_QUARTER_FETCHED quarter={quarter} buys={len(rows)} "
                f"bytes={len(payload)} sha256={source_hash}",
                flush=True,
            )
        evidence.extend(rows)
        sources[quarter] = source
        quarter_dates = [date.fromisoformat(row["filing_date"]) for row in rows]
        if quarter_dates:
            candidate_final = max(quarter_dates)
            final_date = candidate_final if final_date is None else max(final_date, candidate_final)
        if index + 1 < len(quarters) and args.request_pause_seconds:
            time.sleep(args.request_pause_seconds)

    if final_date is None:
        raise RuntimeError("SEC insider evidence has no filing dates")
    evidence.sort(key=lambda row: (row["filing_date"], row["issuer_cik"], row["accession_number"]))
    if len({row["accession_number"] for row in evidence}) != len(evidence):
        raise RuntimeError("duplicate accession in frozen SEC insider evidence")

    weekly = build_weekly_breadth(evidence, final_date)
    usable = [row for row in weekly if row["delta_buy_issuer_count"] != ""]
    if not usable:
        raise RuntimeError("SEC insider weekly breadth has no usable deltas")

    output_dir = Path(args.output_dir)
    evidence_path = output_dir / "SEC_FORM4_OPEN_MARKET_BUY_FILINGS.csv"
    weekly_path = output_dir / "SEC_INSIDER_BUY_BREADTH_WEEKLY.csv"
    write_csv(
        evidence_path,
        evidence,
        ["quarter", "accession_number", "filing_date", "issuer_cik", "issuer_trading_symbol"],
    )
    write_csv(
        weekly_path,
        weekly,
        [
            "week_start",
            "week_end",
            "conservative_available_date",
            "open_market_buy_issuer_count",
            "prior_week_buy_issuer_count",
            "delta_buy_issuer_count",
        ],
    )

    summary = {
        "purpose": "SEC insider-buy breadth factor input only; no strategy performance",
        "performance_computed": False,
        "source": "SEC Insider Transactions Data Sets",
        "source_page": "https://www.sec.gov/data-research/sec-markets-data/insider-transactions-data-sets",
        "quarters": quarters,
        "source_archives": sources,
        "factor_id": "F-SEC-INSIDER-BUY-BREADTH-US",
        "factor_definition": (
            "weekly number of unique issuer CIKs with at least one initial Form 4 non-derivative "
            "open-market purchase (TRANS_CODE=P, acquired=A); risk-on rule reserved for preregistration: "
            "current completed-week issuer count > immediately previous completed-week issuer count"
        ),
        "document_type_rule": "initial Form 4 only; Form 4/A amendments excluded",
        "availability_policy": "completed Monday-Friday filing week usable on following Tuesday",
        "historical_acceptance_timestamp_dependency": False,
        "first_week_start": weekly[0]["week_start"],
        "last_complete_week_end": weekly[-1]["week_end"],
        "last_available_date": weekly[-1]["conservative_available_date"],
        "weekly_rows": len(weekly),
        "usable_delta_rows": len(usable),
        "evidence_rows": len(evidence),
        "evidence_sha256": sha256_file(evidence_path),
        "weekly_sha256": sha256_file(weekly_path),
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "SEC_INSIDER_BREADTH_COMPLETE "
        f"quarters={len(quarters)} evidence={len(evidence)} weekly={len(weekly)} usable={len(usable)} "
        f"last_week={weekly[-1]['week_end']} weekly_sha256={summary['weekly_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
