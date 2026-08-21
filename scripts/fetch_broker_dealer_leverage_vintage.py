#!/usr/bin/env python3
"""Build first-release broker-dealer book leverage from historical Fed Z.1 pages.

This is data construction only: it never calculates strategy returns. For each quarter
from 2012Q1 onward, the script reads that quarter's original Z.1 release page and the
Security Brokers and Dealers level table, then computes
Assets / (Assets - Liabilities). Later Z.1 revisions are therefore excluded.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from html.parser import HTMLParser
from pathlib import Path

ARCHIVE = "https://www.federalreserve.gov/releases/z1/release-dates.htm"
USER_AGENT = "AssetTimeMachine-BDVintage/1.0"


class TableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.in_row = False
        self.in_cell = False
        self.cell = []
        self.row = []
        self.rows = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "tr":
            if self.in_row and self.row:
                self.rows.append(self.row)
            self.in_row, self.row = True, []
        elif self.in_row and tag.lower() in {"td", "th"}:
            self.in_cell, self.cell = True, []

    def handle_data(self, data):
        if self.in_cell:
            self.cell.append(data)

    def handle_entityref(self, name):
        if self.in_cell:
            self.cell.append(" " if name.lower() == "nbsp" else f"&{name};")

    def handle_charref(self, name):
        if self.in_cell:
            self.cell.append(" ")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if self.in_cell and tag in {"td", "th"}:
            self.row.append(re.sub(r"\s+", " ", " ".join(self.cell)).strip())
            self.in_cell = False
        elif self.in_row and tag == "tr":
            if self.row:
                self.rows.append(self.row)
            self.in_row = False


def get(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html,*/*;q=0.8"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def discover(through_year, through_quarter):
    page = get(ARCHIVE).decode("utf-8", "ignore")
    pattern = re.compile(
        r'<div class="row">\s*<div class="col-xs-2">[^<]+</div>\s*'
        r'<div class="col-xs-2">(20\d{2}):Q([1-4])</div>.*?'
        r'<a href="([^"]+)">HTML</a>',
        re.I | re.S,
    )
    found = {}
    for year, quarter, href in pattern.findall(page):
        key = (int(year), int(quarter))
        if (2012, 1) <= key <= (through_year, through_quarter):
            found[key] = urllib.parse.urljoin(ARCHIVE, href)
    expected = []
    y, q = 2012, 1
    while (y, q) <= (through_year, through_quarter):
        expected.append((y, q))
        q += 1
        if q == 5:
            y, q = y + 1, 1
    if sorted(found) != expected:
        raise RuntimeError(f"release archive coverage mismatch: missing={sorted(set(expected)-set(found))}")
    return [(y, q, found[(y, q)]) for y, q in expected]


def candidate_tables(release_url):
    base = release_url.rsplit("/", 1)[0] + "/"
    roots = [base, base.replace("/html/", "/accessible/")]
    candidates = []
    if "/current/" in base:
        candidates.append(urllib.parse.urljoin(base, "S125s3_s.htm"))
    candidates.extend(
        urllib.parse.urljoin(root, f"l{number}.htm")
        for root in roots
        for number in (127, 128, 129, 130)
    )
    return candidates


def period_values(rows, phrase, series_code):
    phrase = phrase.lower()
    code_matches = [row for row in rows if any(cell.strip() == series_code for cell in row)]
    if code_matches:
        matches = code_matches
    else:
        matches = [
            row
            for row in rows
            if row
            and any(
                re.search(rf"(?:^|;\s*){re.escape(phrase)}\s*$", cell.lower())
                for cell in row[:3]
            )
        ]
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one row for {phrase}/{series_code}, got {len(matches)}"
        )
    row = matches[0]
    # Old accessible tables put the description first and a small Line id in the final
    # cell. Modern HTML puts "Line N" first, description second, series code third,
    # and the newest quarter in the final cell. Select data cells by layout rather than
    # blindly dropping the last value.
    data_cells = row if row[0].lower().startswith("line ") else row[:-1]
    numeric = []
    for cell in data_cells:
        raw = cell.replace(",", "").strip()
        if re.fullmatch(r"[-+]?\d+(?:\.\d+)?", raw):
            numeric.append(float(raw))
    if len(numeric) < 5:
        raise RuntimeError(
            f"fewer than five period values for annual growth {phrase}/{series_code}"
        )
    return numeric


def release_date_for_table(url, year, quarter):
    stamp = re.search(r"/z1/(20\d{6})/", url, re.I)
    if stamp:
        return datetime.strptime(stamp.group(1), "%Y%m%d").date().isoformat()
    if "/z1/current/" not in url:
        raise RuntimeError(f"cannot parse release date: {url}")
    current = get("https://www.federalreserve.gov/releases/z1/default.htm").decode(
        "utf-8",
        "ignore",
    )
    plain = re.sub(r"<[^>]+>", " ", current)
    plain = re.sub(r"\s+", " ", plain)
    match = re.search(
        rf"Release Date:\s*([A-Za-z]+\s+\d{{1,2}},\s+\d{{4}})\s+{year}:Q{quarter}\s+Release",
        plain,
        re.I,
    )
    if not match:
        raise RuntimeError(f"cannot resolve current release date for {year}Q{quarter}")
    return datetime.strptime(match.group(1), "%B %d, %Y").date().isoformat()


def fetch_quarter(year, quarter, release_url):
    errors = []
    for url in candidate_tables(release_url):
        try:
            data = get(url)
        except Exception as exc:
            errors.append(f"{url}: {exc}")
            continue
        decoded = data.decode("utf-8", "ignore")
        legacy_identity = re.search(
            r"L\.\d+\s+Security\s+Brokers\s+and\s+Dealers",
            decoded,
            re.I,
        )
        modern_identity = (
            "s125s3.s" in decoded.lower()
            and "security brokers and dealers" in decoded.lower()
        )
        if not legacy_identity and not modern_identity:
            errors.append(f"{url}: wrong table title")
            continue
        parser = TableParser()
        parser.feed(decoded)
        try:
            asset_values = period_values(
                parser.rows,
                "total financial assets",
                "FL664090005",
            )
            liability_values = period_values(
                parser.rows,
                "total liabilities",
                "FL664190005",
            )
            prior_assets, assets = asset_values[-2], asset_values[-1]
            prior_liabilities, liabilities = liability_values[-2], liability_values[-1]
            lag4_assets = asset_values[-5]
            lag4_liabilities = liability_values[-5]
        except Exception as exc:
            errors.append(f"{url}: {exc}")
            continue
        equity = assets - liabilities
        prior_equity = prior_assets - prior_liabilities
        lag4_equity = lag4_assets - lag4_liabilities
        if assets <= 0 or liabilities < 0 or equity <= 0:
            raise RuntimeError(f"invalid balance sheet {year}Q{quarter}: A={assets} L={liabilities}")
        if prior_assets <= 0 or prior_liabilities < 0 or prior_equity <= 0:
            raise RuntimeError(
                f"invalid prior-quarter balance sheet in {year}Q{quarter} release: "
                f"A={prior_assets} L={prior_liabilities}"
            )
        if lag4_assets <= 0 or lag4_liabilities < 0 or lag4_equity <= 0:
            raise RuntimeError(
                f"invalid four-quarter-lag balance sheet in {year}Q{quarter} release: "
                f"A={lag4_assets} L={lag4_liabilities}"
            )
        leverage = assets / equity
        prior_leverage_same_release = prior_assets / prior_equity
        lag4_leverage_same_release = lag4_assets / lag4_equity
        # Extremely thin broker-dealer book equity can make release-vintage leverage
        # legitimately exceed 100x. This is only a parser-sanity guard, not a factor
        # transform: preserve raw values and same-release lagged changes.
        if not math.isfinite(leverage) or not 1 < leverage < 1000:
            raise RuntimeError(f"implausible leverage {leverage} at {year}Q{quarter}")
        if not math.isfinite(prior_leverage_same_release) or not 1 < prior_leverage_same_release < 1000:
            raise RuntimeError(
                f"implausible prior-quarter leverage {prior_leverage_same_release} "
                f"in {year}Q{quarter} release"
            )
        if not math.isfinite(lag4_leverage_same_release) or not 1 < lag4_leverage_same_release < 1000:
            raise RuntimeError(
                f"implausible four-quarter-lag leverage {lag4_leverage_same_release} "
                f"in {year}Q{quarter} release"
            )
        release_date = release_date_for_table(url, year, quarter)
        return (
            prior_assets,
            prior_liabilities,
            prior_leverage_same_release,
            lag4_assets,
            lag4_liabilities,
            lag4_leverage_same_release,
            assets,
            liabilities,
            leverage,
            release_date,
            url,
            sha(data),
            data,
        )
    raise RuntimeError(f"no usable broker-dealer table for {year}Q{quarter}: {'; '.join(errors)}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--output-dir", required=True)
    p.add_argument("--through-year", type=int, default=2026)
    p.add_argument("--through-quarter", type=int, choices=[1, 2, 3, 4], default=1)
    args = p.parse_args()

    outdir = Path(args.output_dir)
    rawdir = outdir / "raw-first-release-tables"
    outdir.mkdir(parents=True, exist_ok=True)
    rawdir.mkdir(parents=True, exist_ok=True)
    releases = discover(args.through_year, args.through_quarter)
    rows = []
    for year, quarter, landing in releases:
        (
            prior_assets,
            prior_liabilities,
            prior_leverage_same_release,
            lag4_assets,
            lag4_liabilities,
            lag4_leverage_same_release,
            assets,
            liabilities,
            leverage,
            release_date,
            table_url,
            table_sha,
            source_data,
        ) = fetch_quarter(year, quarter, landing)
        quarterly_delta = math.log(leverage) - math.log(prior_leverage_same_release)
        annual_growth = math.log(leverage) - math.log(lag4_leverage_same_release)
        quarter_id = f"{year}Q{quarter}"
        raw_path = rawdir / f"{quarter_id}.html"
        raw_path.write_bytes(source_data)
        available_date = (
            datetime.fromisoformat(release_date).date() + timedelta(days=1)
        ).isoformat()
        item = {
            "quarter": f"{year}Q{quarter}",
            "release_date": release_date,
            "available_date": available_date,
            "prior_quarter_assets_same_release": prior_assets,
            "prior_quarter_liabilities_same_release": prior_liabilities,
            "prior_quarter_book_leverage_same_release": prior_leverage_same_release,
            "lag4_quarter_assets_same_release": lag4_assets,
            "lag4_quarter_liabilities_same_release": lag4_liabilities,
            "lag4_quarter_book_leverage_same_release": lag4_leverage_same_release,
            "total_financial_assets": assets,
            "total_liabilities": liabilities,
            "book_equity_assets_minus_liabilities": assets - liabilities,
            "book_leverage": leverage,
            "quarterly_log_change_diagnostic_only": quarterly_delta,
            "annual_log_book_leverage_growth": annual_growth,
            "source_table_url": table_url,
            "source_table_sha256": table_sha,
            "source_table_local_path": raw_path.relative_to(outdir).as_posix(),
        }
        rows.append(item)
        print(
            f"BD_VINTAGE quarter={item['quarter']} release={release_date} "
            f"leverage={leverage:.6f} lag4_same_release={lag4_leverage_same_release:.6f} "
            f"annual_log_growth={annual_growth:.6f} qoq_diagnostic={quarterly_delta:.6f}"
        )

    outdir = Path(args.output_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / "BROKER_DEALER_BOOK_LEVERAGE_FIRST_RELEASE.csv"
    with out.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    summary = {
        "purpose": "first-release broker-dealer leverage data only; no strategy performance",
        "performance_computed": False,
        "formula": "Assets/(Assets-Liabilities)",
        "forecasting_variable": (
            "annual log book-leverage growth computed between the current quarter and "
            "four quarters earlier inside the same historical Z.1 release"
        ),
        "candidate_rule_not_yet_strategy_executed": "annual_log_book_leverage_growth < 0",
        "quarterly_change_is_diagnostic_only": True,
        "availability_policy": "usable one calendar day after the historical Z.1 release date",
        "first_quarter": rows[0]["quarter"],
        "last_quarter": rows[-1]["quarter"],
        "rows": len(rows),
        "raw_source_table_count": len(list(rawdir.glob("*.html"))),
        "output_sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
        "point_in_time_note": (
            "Every observation and its four-quarter comparison value are read from the "
            "same original Federal Reserve Z.1 release page; later revisions are not used. "
            "All source HTML is frozen locally with SHA-256."
        ),
    }
    (outdir / "fetch-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True)+"\n", encoding="utf-8")
    print(f"BROKER_DEALER_VINTAGE_COMPLETE rows={len(rows)} sha256={summary['output_sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
