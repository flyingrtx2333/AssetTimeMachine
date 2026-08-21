#!/usr/bin/env python3
"""Build first-release nonfinancial-corporate net payout yield from Fed Z.1 archives.

Data construction only; no strategy returns are calculated. For every quarterly Z.1
release from 2012Q1 onward, read from that release's own tables:
  * net dividends paid (SAAR flow)
  * corporate equities; liability (SAAR transaction; negative means net repurchase)
  * corporate equities; liability (market-value level)
Then compute annualized net payout yield = (dividends - equity issuance) / equity value.
All source tables are frozen locally with SHA-256 so later Z.1 revisions cannot leak in.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

from fetch_broker_dealer_leverage_vintage import TableParser

RELEASE_ARCHIVE = "https://www.federalreserve.gov/releases/z1/release-dates.htm"
USER_AGENT = "AssetTimeMachine-NetPayoutVintage/1.0"


def get(url: str, timeout: int = 30) -> bytes:
    last_error: Exception | str | None = None
    for attempt in range(3):
        request = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "text/html,*/*;q=0.8"},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception as error:
            last_error = error
            time.sleep(0.5 * (attempt + 1))
    completed = subprocess.run(
        [
            "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors",
            "--connect-timeout", "10", "--max-time", str(max(timeout, 30)),
            "-A", USER_AGENT, "-H", "Accept: text/html,*/*;q=0.8", url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode == 0 and completed.stdout:
        return completed.stdout
    detail = completed.stderr.decode("utf-8", "ignore").strip()
    raise RuntimeError(f"Z.1 request failed: {url}; urllib={last_error}; curl={detail}")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def discover_releases(
    start_year: int,
    start_quarter: int,
    through_year: int,
    through_quarter: int,
) -> list[tuple[int, int, str]]:
    page = get(RELEASE_ARCHIVE).decode("utf-8", "ignore")
    pattern = re.compile(
        r'<div class="row">\s*<div class="col-xs-2">[^<]+</div>\s*'
        r'<div class="col-xs-2">(20\d{2}):Q([1-4])</div>.*?'
        r'<a href="([^"]+)">HTML</a>',
        re.I | re.S,
    )
    found: dict[tuple[int, int], str] = {}
    for year, quarter, href in pattern.findall(page):
        key = (int(year), int(quarter))
        if (start_year, start_quarter) <= key <= (through_year, through_quarter):
            found[key] = urllib.parse.urljoin(RELEASE_ARCHIVE, href)
    expected: list[tuple[int, int]] = []
    year, quarter = start_year, start_quarter
    while (year, quarter) <= (through_year, through_quarter):
        expected.append((year, quarter))
        quarter += 1
        if quarter == 5:
            year += 1
            quarter = 1
    if sorted(found) != expected:
        raise RuntimeError(
            f"NPY release archive coverage mismatch: missing={sorted(set(expected)-set(found))}"
        )
    return [(year, quarter, found[(year, quarter)]) for year, quarter in expected]


def current_release_date(year: int, quarter: int) -> str:
    page = get("https://www.federalreserve.gov/releases/z1/default.htm").decode("utf-8", "ignore")
    plain = re.sub(r"<[^>]+>", " ", page)
    plain = re.sub(r"\s+", " ", plain)
    match = re.search(
        rf"Release Date:\s*([A-Za-z]+\s+\d{{1,2}},\s+\d{{4}})\s+{year}:Q{quarter}\s+Release",
        plain,
        re.I,
    )
    if not match:
        raise RuntimeError(f"cannot resolve current Z.1 release date for {year}Q{quarter}")
    return datetime.strptime(match.group(1), "%B %d, %Y").date().isoformat()


def release_date(url: str, year: int, quarter: int) -> str:
    stamp = re.search(r"/z1/(20\d{6})/", url, re.I)
    if stamp:
        return datetime.strptime(stamp.group(1), "%Y%m%d").date().isoformat()
    if "/current/" in url:
        return current_release_date(year, quarter)
    raise RuntimeError(f"cannot parse release date from {url}")


def release_roots(landing: str) -> list[str]:
    base = landing.rsplit("/", 1)[0] + "/"
    roots = [base]
    if "/html/" in base:
        roots.append(base.replace("/html/", "/accessible/"))
    elif "/accessible/" in base:
        roots.append(base.replace("/accessible/", "/html/"))
    return list(dict.fromkeys(roots))


def normalized_description(value: str) -> str:
    return re.sub(r"\s+", " ", value.replace("\xa0", " ")).strip().lower()


def exact_row(
    rows: list[list[str]],
    description: str,
    *,
    description_aliases: tuple[str, ...] = (),
    series_codes: tuple[str, ...] = (),
) -> list[str]:
    code_matches = [
        row
        for row in rows
        if any(cell.strip() in series_codes for cell in row[:4])
    ] if series_codes else []
    if code_matches:
        matches = code_matches
    else:
        wanted = {
            normalized_description(value)
            for value in (description, *description_aliases)
        }
        matches = []
        for row in rows:
            for cell in row[:3]:
                if normalized_description(cell) in wanted:
                    matches.append(row)
                    break
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one row '{description}' codes={series_codes}, got {len(matches)}"
        )
    return matches[0]


def numeric_values(row: list[str]) -> list[float]:
    # Old accessible tables end with a numeric line id. Modern tables begin with
    # 'Line N' and may include a series-code cell. Strip the old terminal line id only.
    cells = row if row and row[0].lower().startswith("line ") else row[:-1]
    values = []
    for cell in cells:
        raw = cell.replace(",", "").strip()
        if re.fullmatch(r"[-+]?\d+(?:\.\d+)?", raw):
            values.append(float(raw))
    if not values:
        raise RuntimeError("row has no numeric data")
    return values


def find_transactions(landing: str) -> tuple[str, bytes, float, float]:
    errors = []
    for root in release_roots(landing):
        names = ["f102.htm", "f103.htm", "S11_1_t.htm"]
        for name in names:
            url = urllib.parse.urljoin(root, name)
            try:
                data = get(url)
            except Exception as exc:
                errors.append(f"{url}: {exc}")
                continue
            parser = TableParser()
            parser.feed(data.decode("utf-8", "ignore"))
            try:
                dividend_row = exact_row(
                    parser.rows,
                    "Nonfinancial corporate business; net dividends paid",
                    description_aliases=(
                        "Nonfarm nonfinancial corporate business; net dividends paid",
                    ),
                    series_codes=("FA106121075",),
                )
                issuance_row = exact_row(
                    parser.rows,
                    "Nonfinancial corporate business; corporate equities; liability",
                    description_aliases=(
                        "Nonfarm nonfinancial corporate business; corporate equities; liability",
                    ),
                    series_codes=("FA103164105",),
                )
                dividends = numeric_values(dividend_row)[-1]
                issuance = numeric_values(issuance_row)[-1]
            except Exception as exc:
                errors.append(f"{url}: {exc}")
                continue
            return url, data, dividends, issuance
    raise RuntimeError(f"no transaction table found: {'; '.join(errors)}")


def find_equity_value(landing: str) -> tuple[str, bytes, float]:
    errors = []
    for root in release_roots(landing):
        names = ["l102.htm", "l103.htm", "l213.htm", "l223.htm", "S11_1_s.htm"]
        for name in names:
            url = urllib.parse.urljoin(root, name)
            try:
                data = get(url)
            except Exception as exc:
                errors.append(f"{url}: {exc}")
                continue
            parser = TableParser()
            parser.feed(data.decode("utf-8", "ignore"))
            try:
                row = exact_row(
                    parser.rows,
                    "Nonfinancial corporate business; corporate equities; liability",
                    description_aliases=(
                        "Nonfarm nonfinancial corporate business; corporate equities; liability",
                    ),
                    series_codes=("LM103164105",),
                )
                value = numeric_values(row)[-1]
            except Exception as exc:
                errors.append(f"{url}: {exc}")
                continue
            if value <= 0 or not math.isfinite(value):
                errors.append(f"{url}: invalid equity market value {value}")
                continue
            return url, data, value
    raise RuntimeError(f"no equity-value table found: {'; '.join(errors)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start-year", type=int, default=2009)
    parser.add_argument("--start-quarter", type=int, choices=[1, 2, 3, 4], default=1)
    parser.add_argument("--through-year", type=int, default=2026)
    parser.add_argument("--through-quarter", type=int, choices=[1, 2, 3, 4], default=1)
    args = parser.parse_args()
    if (args.start_year, args.start_quarter) > (args.through_year, args.through_quarter):
        raise SystemExit("start quarter must not be after through quarter")

    outdir = Path(args.output_dir)
    rawdir = outdir / "raw-first-release-tables"
    outdir.mkdir(parents=True, exist_ok=True)
    rawdir.mkdir(parents=True, exist_ok=True)

    output_path = outdir / "NET_PAYOUT_YIELD_FIRST_RELEASE.csv"
    cached: dict[str, dict[str, str]] = {}
    if output_path.is_file():
        with output_path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                qid = row.get("quarter", "")
                tx_path = outdir / row.get("transaction_table_local_path", "")
                level_path = outdir / row.get("level_table_local_path", "")
                if not qid or not tx_path.is_file() or not level_path.is_file():
                    continue
                if sha(tx_path.read_bytes()) != row.get("transaction_table_sha256"):
                    continue
                if sha(level_path.read_bytes()) != row.get("level_table_sha256"):
                    continue
                cached[qid] = row

    rows = []
    for year, quarter, landing in discover_releases(
        args.start_year,
        args.start_quarter,
        args.through_year,
        args.through_quarter,
    ):
        qid = f"{year}Q{quarter}"
        if qid in cached:
            item = dict(cached[qid])
            rows.append(item)
            print(f"NPY_VINTAGE_CACHED quarter={qid} release={item['release_date']}")
            continue
        tx_url, tx_data, dividends, issuance = find_transactions(landing)
        level_url, level_data, equity_value = find_equity_value(landing)
        rel_date = release_date(tx_url, year, quarter)
        if release_date(level_url, year, quarter) != rel_date:
            raise RuntimeError(f"transaction/level release-date mismatch {year}Q{quarter}")
        available = (datetime.fromisoformat(rel_date).date() + timedelta(days=1)).isoformat()
        net_payout = dividends - issuance
        npy = net_payout / equity_value
        if not math.isfinite(npy) or abs(npy) > 1.0:
            raise RuntimeError(f"implausible net payout yield {npy} at {year}Q{quarter}")
        qid = f"{year}Q{quarter}"
        tx_path = rawdir / f"{qid}-transactions.html"
        level_path = rawdir / f"{qid}-levels.html"
        tx_path.write_bytes(tx_data)
        level_path.write_bytes(level_data)
        rows.append({
            "quarter": qid,
            "release_date": rel_date,
            "available_date": available,
            "net_dividends_saar_billions": dividends,
            "net_equity_issuance_saar_billions": issuance,
            "net_payout_saar_billions": net_payout,
            "equity_market_value_billions": equity_value,
            "net_payout_yield": npy,
            "transaction_table_url": tx_url,
            "transaction_table_sha256": sha(tx_data),
            "transaction_table_local_path": tx_path.relative_to(outdir).as_posix(),
            "level_table_url": level_url,
            "level_table_sha256": sha(level_data),
            "level_table_local_path": level_path.relative_to(outdir).as_posix(),
        })
        print(
            f"NPY_VINTAGE quarter={qid} release={rel_date} dividends={dividends:.3f} "
            f"issuance={issuance:.3f} equity={equity_value:.3f} npy={npy:.6f}"
        )

    out = outdir / "NET_PAYOUT_YIELD_FIRST_RELEASE.csv"
    with out.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    values = [float(row["net_payout_yield"]) for row in rows]
    summary = {
        "purpose": "first-release aggregate net payout yield feasibility; no strategy performance",
        "performance_computed": False,
        "formula": "(Net Dividends Paid - Corporate Equities Liability Transactions) / Corporate Equities Liability Market Value",
        "first_quarter": rows[0]["quarter"],
        "last_quarter": rows[-1]["quarter"],
        "rows": len(rows),
        "min_net_payout_yield": min(values),
        "max_net_payout_yield": max(values),
        "positive_count": sum(value > 0 for value in values),
        "nonpositive_count": sum(value <= 0 for value in values),
        "raw_table_count": len(list(rawdir.glob("*.html"))),
        "output_sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
        "point_in_time_note": "Every numerator and denominator is read from the same quarter's original Federal Reserve Z.1 release; source HTML is frozen locally with SHA-256.",
    }
    (outdir / "fetch-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"NET_PAYOUT_VINTAGE_COMPLETE rows={len(rows)} positive={summary['positive_count']} "
        f"nonpositive={summary['nonpositive_count']} sha256={summary['output_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
