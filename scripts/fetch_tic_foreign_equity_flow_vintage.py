#!/usr/bin/env python3
"""Build first-release monthly foreign net purchases of U.S. corporate stocks from TIC archives.

Data construction only; no strategy performance is calculated.

For releases reporting data through January 2023 (old Form S regime), extract the
Grand Total / Corp. Stocks / net value from `snetus.txt`. For data beginning February
2023 (new expanded Form SLT regime), extract Grand Total (country code 99996) / U.S.
Corp. Equity / Net U.S. Sales from `slt_table1.html`. Treasury explicitly identifies
these as the old/new presentation of the same economic direction: positive means
foreign residents are net buyers / increase holdings of U.S. stocks. Treasury also
explicitly identifies February 2023 as a reporting-system series break; the output
preserves that regime boundary and never smooths it away.

Every monthly observation comes from the archive ZIP released for that reporting
month. The ZIP SHA-256 and selected source-member SHA-256 are recorded before any
strategy performance is viewed. Availability is conservatively the actual release
date + 1 calendar day. If the archive page annotates a delayed actual release date,
that actual date overrides the date embedded in the ZIP filename.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import re
import subprocess
import time
import urllib.error
import urllib.request
import zipfile
from datetime import date, datetime, timedelta
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from fetch_broker_dealer_leverage_vintage import TableParser

ARCHIVE_PAGE = "https://home.treasury.gov/archives-of-tic-monthly-data-releases"
ZIP_BASE = "https://ticdata.treasury.gov/resource-center/data-chart-center/tic/Documents/"
USER_AGENT = "AssetTimeMachine-TIC-FirstRelease/1.0"
SERIES_BREAK_MONTH = "2023-02"

MONTHS = {
    "January": 1,
    "February": 2,
    "March": 3,
    "April": 4,
    "May": 5,
    "June": 6,
    "July": 7,
    "August": 8,
    "September": 9,
    "October": 10,
    "November": 11,
    "December": 12,
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, *, accept: str, timeout: int = 45) -> bytes:
    last_error: Exception | str | None = None
    for attempt in range(3):
        request = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": accept},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code == 404:
                raise
        except (urllib.error.URLError, OSError) as error:
            last_error = error
        time.sleep(0.5 * (attempt + 1))

    completed = subprocess.run(
        [
            "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors",
            "--connect-timeout", "10", "--max-time", str(max(timeout, 45)),
            "-A", USER_AGENT, "-H", f"Accept: {accept}", url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode == 0 and completed.stdout:
        return completed.stdout
    detail = completed.stderr.decode("utf-8", "ignore").strip()
    raise RuntimeError(f"TIC request failed: {url}; urllib={last_error}; curl={detail}")


class LinkTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.href: str | None = None
        self.text: list[str] = []
        self.links: list[tuple[str, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() == "a":
            values = dict(attrs)
            self.href = values.get("href")
            self.text = []

    def handle_data(self, data: str) -> None:
        if self.href is not None:
            self.text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "a" and self.href is not None:
            self.links.append((self.href, "".join(self.text).strip()))
            self.href = None
            self.text = []


def month_id(name: str, year: int) -> str:
    return f"{year:04d}-{MONTHS[name]:02d}"


def parse_archive_releases(html: str) -> list[dict[str, str]]:
    # Treasury renders the past-release list as adjacent <a>Release date</a> + text.
    # Regex intentionally binds each TIC ZIP to its immediately following report-month text.
    pattern = re.compile(
        r'<a\s+href="([^"]*ticrel_(\d{8})\.zip)"[^>]*>\s*'
        r'(\d{2}/\d{2}/\d{4})\s*</a>(?:\s|&nbsp;)*'
        r'TIC\s+Data\s+for\s+'
        r'(January|February|March|April|May|June|July|August|September|October|November|December)\s+'
        r'(20\d{2})'
        r'([^<]*)',
        re.I,
    )
    rows: list[dict[str, str]] = []
    for href, filename_date, anchor_date, month_name, year_text, suffix in pattern.findall(html):
        release = datetime.strptime(anchor_date, "%m/%d/%Y").date()
        delayed = re.search(r"released\s+(\d{2})-(\d{2})-(\d{4})", suffix, re.I)
        if delayed:
            release = date(int(delayed.group(3)), int(delayed.group(1)), int(delayed.group(2)))
        report_month = month_id(month_name.title(), int(year_text))
        filename = f"ticrel_{filename_date}.zip"
        rows.append(
            {
                "report_month": report_month,
                "release_date": release.isoformat(),
                "archive_filename": filename,
                "archive_url": ZIP_BASE + filename,
                "archive_href": href,
            }
        )
    if not rows:
        raise RuntimeError("TIC archive page produced no monthly release rows")
    by_month: dict[str, dict[str, str]] = {}
    for row in rows:
        month = row["report_month"]
        if month in by_month:
            raise RuntimeError(f"duplicate TIC report month in archive page: {month}")
        by_month[month] = row
    return sorted(by_month.values(), key=lambda item: item["report_month"])


def old_snetus_value(text: str, report_month: str) -> float:
    year, month = map(int, report_month.split("-"))
    month_name = next(name for name, number in MONTHS.items() if number == month)
    title = re.search(r"Foreign Net Purchases of U\.S\. Long-Term Securities.*?as of:\s*([A-Za-z]+)\s+(\d{4})", text, re.I)
    if not title or title.group(1).lower() != month_name.lower() or int(title.group(2)) != year:
        raise RuntimeError(f"snetus title/report-month mismatch for {report_month}")
    grand = next((line for line in text.splitlines() if line.strip().startswith("Grand Total")), None)
    if grand is None:
        raise RuntimeError(f"snetus missing Grand Total for {report_month}")
    tail = grand[grand.index("Grand Total") + len("Grand Total"):]
    tokens = re.findall(r"n\.a\.|[-+]?\d[\d,]*", tail, flags=re.I)
    # Three months x five U.S.-security net columns. The first block is the newly
    # released month and the fifth value is Corp. Stocks, net.
    if len(tokens) < 5:
        raise RuntimeError(f"snetus Grand Total has too few numeric columns for {report_month}")
    raw = tokens[4]
    if raw.lower() == "n.a.":
        raise RuntimeError(f"snetus stock net value is n.a. for {report_month}")
    return float(raw.replace(",", ""))


def new_slt_value(text: str, report_month: str, *, tab_delimited: bool) -> float:
    if tab_delimited:
        rows = list(csv.reader(io.StringIO(text), delimiter="\t"))
    else:
        parser = TableParser()
        parser.feed(text)
        rows = parser.rows
    header = next((row for row in rows if "for_lt_eqty_net" in row), None)
    if header is None:
        raise RuntimeError("slt_table1 missing for_lt_eqty_net header")
    index = header.index("for_lt_eqty_net")
    matches = [
        row for row in rows
        if len(row) > index
        and row[0].strip() == "Grand Total"
        and row[1].strip() == "99996"
        and row[2].strip() == report_month
    ]
    if len(matches) != 1:
        raise RuntimeError(f"slt_table1 expected one Grand Total row for {report_month}, got {len(matches)}")
    raw = matches[0][index].replace(",", "").strip()
    if raw.lower() in {"n.a.", "na", ""}:
        raise RuntimeError(f"slt_table1 U.S. Corp Equity net is unavailable for {report_month}")
    value = float(raw)
    if not math.isfinite(value):
        raise RuntimeError(f"slt_table1 non-finite net value for {report_month}")
    return value


def archive_member_by_basename(archive: zipfile.ZipFile, basename: str) -> str | None:
    matches = [name for name in archive.namelist() if name.rsplit("/", 1)[-1].lower() == basename.lower()]
    if len(matches) > 1:
        raise RuntimeError(f"TIC archive contains duplicate basename {basename}: {matches}")
    return matches[0] if matches else None


def extract_month(payload: bytes, report_month: str) -> tuple[str, bytes, float, str]:
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        if report_month < SERIES_BREAK_MONTH:
            member = archive_member_by_basename(archive, "snetus.txt")
            if member is None:
                raise RuntimeError(f"old TIC archive missing snetus.txt for {report_month}")
            data = archive.read(member)
            value = old_snetus_value(data.decode("utf-8", "ignore"), report_month)
            regime = "FORM_S_NET_FOREIGN_PURCHASES"
        else:
            member = archive_member_by_basename(archive, "slt_table1.html")
            tab_delimited = False
            if member is None:
                member = archive_member_by_basename(archive, "slt_table1.txt")
                tab_delimited = True
            if member is None:
                raise RuntimeError(f"new TIC archive missing slt_table1 html/txt for {report_month}")
            data = archive.read(member)
            value = new_slt_value(
                data.decode("utf-8", "ignore"),
                report_month,
                tab_delimited=tab_delimited,
            )
            regime = "FORM_SLT_NET_US_SALES"
    return member, data, value, regime


def month_sequence(start: str, end: str) -> list[str]:
    year, month = map(int, start.split("-"))
    end_year, end_month = map(int, end.split("-"))
    result: list[str] = []
    while (year, month) <= (end_year, end_month):
        result.append(f"{year:04d}-{month:02d}")
        month += 1
        if month == 13:
            year += 1
            month = 1
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start-month", default="2011-01")
    parser.add_argument("--end-month", default="2026-06")
    parser.add_argument("--request-pause-seconds", type=float, default=0.08)
    args = parser.parse_args()
    if not re.fullmatch(r"\d{4}-\d{2}", args.start_month) or not re.fullmatch(r"\d{4}-\d{2}", args.end_month):
        raise SystemExit("start/end month must be YYYY-MM")
    if args.start_month > args.end_month:
        raise SystemExit("start month must not exceed end month")
    if not math.isfinite(args.request_pause_seconds) or args.request_pause_seconds < 0:
        raise SystemExit("request pause must be finite and >=0")

    archive_html = request_bytes(ARCHIVE_PAGE, accept="text/html,*/*;q=0.8").decode("utf-8", "ignore")
    releases = parse_archive_releases(archive_html)
    release_by_month = {row["report_month"]: row for row in releases}
    wanted = month_sequence(args.start_month, args.end_month)
    missing = [month for month in wanted if month not in release_by_month]
    if missing:
        raise RuntimeError(f"TIC archive is missing requested report months: {missing[:20]}")

    output_dir = Path(args.output_dir)
    cache_dir = output_dir / "month-cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []

    for number, month in enumerate(wanted, start=1):
        release = release_by_month[month]
        cache_path = cache_dir / f"{month}.json"
        if cache_path.is_file():
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            if cached.get("cache_schema") != "tic-foreign-equity-first-release-v1" or cached.get("report_month") != month:
                raise RuntimeError(f"invalid TIC month cache: {cache_path}")
            row = cached["row"]
            print(f"TIC_FOREIGN_EQUITY_CACHED month={month} value={row['net_foreign_purchases_us_stocks_millions']}", flush=True)
        else:
            payload = request_bytes(release["archive_url"], accept="application/zip", timeout=75)
            member, member_data, value, regime = extract_month(payload, month)
            release_day = date.fromisoformat(release["release_date"])
            row = {
                "report_month": month,
                "release_date": release_day.isoformat(),
                "available_date": (release_day + timedelta(days=1)).isoformat(),
                "net_foreign_purchases_us_stocks_millions": value,
                "regime": regime,
                "series_break_2023_02": month >= SERIES_BREAK_MONTH,
                "archive_filename": release["archive_filename"],
                "archive_url": release["archive_url"],
                "archive_sha256": sha256_bytes(payload),
                "source_member": member,
                "source_member_sha256": sha256_bytes(member_data),
            }
            document = {
                "cache_schema": "tic-foreign-equity-first-release-v1",
                "report_month": month,
                "row": row,
            }
            temp = cache_path.with_suffix(".json.tmp")
            temp.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            temp.replace(cache_path)
            print(
                f"TIC_FOREIGN_EQUITY_FETCHED {number}/{len(wanted)} month={month} "
                f"release={row['release_date']} value={value:.0f} regime={regime}",
                flush=True,
            )
        rows.append(row)
        if number < len(wanted) and args.request_pause_seconds:
            time.sleep(args.request_pause_seconds)

    rows.sort(key=lambda row: row["report_month"])
    if [row["report_month"] for row in rows] != wanted:
        raise RuntimeError("TIC first-release month sequence drifted")

    output_path = output_dir / "TIC_FOREIGN_NET_PURCHASES_US_STOCKS_FIRST_RELEASE.csv"
    fields = [
        "report_month", "release_date", "available_date",
        "net_foreign_purchases_us_stocks_millions", "regime", "series_break_2023_02",
        "archive_filename", "archive_url", "archive_sha256", "source_member", "source_member_sha256",
    ]
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    values = [float(row["net_foreign_purchases_us_stocks_millions"]) for row in rows]
    release_days = [date.fromisoformat(row["release_date"]) for row in rows]
    gaps = [(release_days[i] - release_days[i - 1]).days for i in range(1, len(release_days))]
    old_values = [float(row["net_foreign_purchases_us_stocks_millions"]) for row in rows if row["report_month"] < SERIES_BREAK_MONTH]
    new_values = [float(row["net_foreign_purchases_us_stocks_millions"]) for row in rows if row["report_month"] >= SERIES_BREAK_MONTH]
    around_break = {
        row["report_month"]: row["net_foreign_purchases_us_stocks_millions"]
        for row in rows
        if "2022-11" <= row["report_month"] <= "2023-05"
    }
    summary = {
        "purpose": "first-release TIC foreign U.S.-stock flow feasibility; no strategy performance",
        "performance_computed": False,
        "source": "U.S. Treasury TIC monthly release archives",
        "source_archive_page": ARCHIVE_PAGE,
        "first_report_month": rows[0]["report_month"],
        "last_report_month": rows[-1]["report_month"],
        "rows": len(rows),
        "positive_months": sum(value > 0 for value in values),
        "negative_months": sum(value < 0 for value in values),
        "zero_months": sum(value == 0 for value in values),
        "old_regime_rows": len(old_values),
        "new_regime_rows": len(new_values),
        "old_positive_months": sum(value > 0 for value in old_values),
        "old_negative_months": sum(value < 0 for value in old_values),
        "new_positive_months": sum(value > 0 for value in new_values),
        "new_negative_months": sum(value < 0 for value in new_values),
        "min_value_millions": min(values),
        "max_value_millions": max(values),
        "max_release_gap_days": max(gaps) if gaps else 0,
        "series_break_month": SERIES_BREAK_MONTH,
        "series_break_note": (
            "Treasury explicitly identifies February 2023 as a Form S to expanded Form SLT series break. "
            "Old foreign net purchases and new net U.S. sales preserve the same economic sign but are not treated as a statistically seamless measurement regime."
        ),
        "around_break_values_millions": around_break,
        "availability_rule": "actual monthly release date + 1 calendar day",
        "factor_direction_not_yet_executed": (
            "literature-motivated contrarian candidate would treat net foreign purchases < 0 as favorable; "
            "this feasibility script does not calculate strategy returns"
        ),
        "output_sha256": sha256_file(output_path),
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "TIC_FOREIGN_EQUITY_FIRST_RELEASE_COMPLETE "
        f"rows={len(rows)} positive={summary['positive_months']} negative={summary['negative_months']} "
        f"old={len(old_values)} new={len(new_values)} max_gap={summary['max_release_gap_days']} "
        f"sha256={summary['output_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
