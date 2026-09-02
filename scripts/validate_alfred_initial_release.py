#!/usr/bin/env python3
"""Validate frozen ALFRED initial-release tables without computing strategy returns."""
from __future__ import annotations

import argparse
import calendar
import csv
import hashlib
import re
from datetime import date
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIR = ROOT / "tools/research-results/macro-vintages/alfred-initial-release"
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_GAPS = {"UNRATE": ["2025-10"], "CPIAUCSL": ["2025-10"]}
EXPECTED_FIRST = "1999-12"


def month_sequence(start: str, end: str) -> list[str]:
    year, month = map(int, start.split("-"))
    values: list[str] = []
    while True:
        current = f"{year:04d}-{month:02d}"
        values.append(current)
        if current == end:
            return values
        month += 1
        if month == 13:
            year += 1
            month = 1


def verify_manifest(root: Path) -> None:
    manifest = root / "source-manifest.txt"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    entries = [line for line in lines if line.startswith("sha256=")]
    if len(entries) != 6:
        raise RuntimeError(f"expected six manifest entries, got {len(entries)}")
    for line in entries:
        match = re.fullmatch(r"sha256=([0-9a-f]{64}) bytes=(\d+) path=(.+)", line)
        if not match:
            raise RuntimeError(f"invalid manifest line: {line}")
        expected_hash, expected_bytes, relative = match.groups()
        path = ROOT / relative
        body = path.read_bytes()
        if len(body) != int(expected_bytes):
            raise RuntimeError(f"byte-size mismatch: {relative}")
        if hashlib.sha256(body).hexdigest() != expected_hash:
            raise RuntimeError(f"sha256 mismatch: {relative}")


def read_rows(root: Path, series: str) -> list[dict[str, str]]:
    path = root / f"{series}_initial_release.csv"
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise RuntimeError(f"empty table: {series}")
    months = [row["reference_month"] for row in rows]
    if months != sorted(set(months)):
        raise RuntimeError(f"duplicate or unsorted reference months: {series}")
    if months[0] != EXPECTED_FIRST:
        raise RuntimeError(f"unexpected first month for {series}: {months[0]}")
    expected = month_sequence(months[0], months[-1])
    missing = [month for month in expected if month not in set(months)]
    if missing != EXPECTED_GAPS[series]:
        raise RuntimeError(f"unexpected gaps for {series}: {missing}")

    prior_release: date | None = None
    release_date_file = root / "sources" / f"release_dates_{50 if series == 'UNRATE' else 10}.txt"
    official_dates = {
        line.strip() for line in release_date_file.read_text(encoding="utf-8").splitlines()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", line.strip())
    }
    for row in rows:
        if row["series_id"] != series:
            raise RuntimeError(f"series identity mismatch: {row}")
        reference = row["reference_month"]
        year, month = map(int, reference.split("-"))
        reference_end = date(year, month, calendar.monthrange(year, month)[1])
        release = date.fromisoformat(row["release_date"])
        if release <= reference_end:
            raise RuntimeError(f"release is not after reference month: {series} {reference} {release}")
        if prior_release is not None and release <= prior_release:
            raise RuntimeError(f"non-increasing release date: {series} {release}")
        prior_release = release
        if row["release_date"] not in official_dates:
            raise RuntimeError(f"release date absent from official list: {series} {release}")
        if row["vintage_id"] != row["release_date"]:
            raise RuntimeError(f"vintage/release mismatch: {series} {reference}")
        parsed = urlparse(row["source"])
        query = parse_qs(parsed.query)
        if parsed.netloc != "alfred.stlouisfed.org" or query.get("id") != [series]:
            raise RuntimeError(f"invalid source identity: {row['source']}")
        if query.get("vintage_date") != [row["vintage_id"]]:
            raise RuntimeError(f"invalid source vintage: {row['source']}")
        if not SHA_RE.fullmatch(row["snapshot_sha256"]):
            raise RuntimeError(f"invalid snapshot sha256: {series} {reference}")
        value = float(row["initial_value"])
        if series == "UNRATE" and not 0 <= value <= 50:
            raise RuntimeError(f"implausible UNRATE value: {reference} {value}")
        if series == "CPIAUCSL" and not 1 <= value <= 1000:
            raise RuntimeError(f"implausible CPI value: {reference} {value}")

    gaps_path = root / f"{series}_missing_reference_months.csv"
    with gaps_path.open(newline="", encoding="utf-8") as handle:
        gap_rows = list(csv.DictReader(handle))
    if [row["missing_reference_month"] for row in gap_rows] != EXPECTED_GAPS[series]:
        raise RuntimeError(f"gap artifact mismatch: {series}")
    if any("never interpolate or backfill" not in row["handling"] for row in gap_rows):
        raise RuntimeError(f"gap handling is not conservative: {series}")
    print(
        f"{series}_INITIAL_RELEASE_VALID rows={len(rows)} reference={months[0]}..{months[-1]} "
        f"releases={rows[0]['release_date']}..{rows[-1]['release_date']} gaps={','.join(missing)} "
        f"sha256={hashlib.sha256(path.read_bytes()).hexdigest()}"
    )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DIR)
    args = parser.parse_args()
    verify_manifest(args.data_dir)
    unrate = read_rows(args.data_dir, "UNRATE")
    cpi = read_rows(args.data_dir, "CPIAUCSL")
    unrate_months = {row["reference_month"] for row in unrate}
    cpi_months = {row["reference_month"] for row in cpi}
    if unrate_months != cpi_months:
        raise RuntimeError("UNRATE/CPI reference-month coverage differs")
    print(f"ALFRED_INITIAL_RELEASE_DATASET_VALID paired_months={len(unrate_months)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
