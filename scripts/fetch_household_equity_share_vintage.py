#!/usr/bin/env python3
"""Build point-in-time Household Equity Share from archived Federal Reserve Z.1 releases.

This reproduces the Yang-Zhang HEShare definition using the components cited in the
paper, but expands the two computed mutual-fund split series into their underlying
same-release Z.1 components so the definition survives table/series-display changes.
No strategy performance is calculated here.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

from fetch_broker_dealer_leverage_vintage import TableParser
from fetch_net_payout_yield_vintage import (
    discover_releases,
    exact_row,
    get,
    numeric_values,
    release_date,
    release_roots,
    sha,
)

HOUSEHOLD_TABLE_NAMES = ("b100.htm", "b100e.htm", "b101.htm", "B100.htm", "B100E.htm", "B101.htm", "S1M_b.htm")
MUTUAL_FUND_TABLE_NAMES = ("l120.htm", "l121.htm", "l122.htm", "L120.htm", "L121.htm", "L122.htm", "S124_1_s.htm")


def probe_table(url: str, timeout: int = 20) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "AssetTimeMachine-HEShare-Vintage/1.0", "Accept": "text/html,*/*;q=0.8"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise
        return get(url, timeout=timeout)
    except (urllib.error.URLError, OSError):
        return get(url, timeout=timeout)


def landing_links(landing: str) -> list[tuple[str, str]]:
    page = probe_table(landing).decode("utf-8", "ignore")
    matches = re.findall(r'<a\s+href="([^"]+)"[^>]*>(.*?)</a>', page, flags=re.I | re.S)
    output: list[tuple[str, str]] = []
    for href, raw_text in matches:
        text = re.sub(r"<[^>]+>", " ", raw_text)
        text = re.sub(r"\s+", " ", text).strip()
        if href.lower().endswith(".htm"):
            output.append((urllib.parse.urljoin(landing, href), text))
    return output


def discovered_table_urls(landing: str, predicate) -> list[str]:
    return [url for url, text in landing_links(landing) if predicate(text)]


def value_by_codes(
    rows: list[list[str]],
    description: str,
    codes: tuple[str, ...],
    *,
    aliases: tuple[str, ...] = (),
) -> float:
    try:
        row = exact_row(rows, description, description_aliases=aliases, series_codes=codes)
    except RuntimeError:
        wanted = {description, *aliases}
        matches = [
            candidate
            for candidate in rows
            if any(cell.strip() in codes for cell in candidate[:4])
            or any(cell.strip() in wanted for cell in candidate[:3])
        ]
        if len(matches) < 2:
            raise
        numeric = [numeric_values(candidate) for candidate in matches]
        if any(values != numeric[0] for values in numeric[1:]):
            raise RuntimeError(
                f"ambiguous duplicate rows for {description}: numeric values differ"
            )
        row = matches[0]
    value = numeric_values(row)[-1]
    if not math.isfinite(value):
        raise RuntimeError(f"non-finite value for {description}")
    return value


def parse_table(data: bytes) -> list[list[str]]:
    parser = TableParser()
    parser.feed(data.decode("utf-8", "ignore"))
    return parser.rows


def find_household_table(landing: str) -> tuple[str, bytes, dict[str, float]]:
    errors: list[str] = []
    for root in release_roots(landing):
        for name in HOUSEHOLD_TABLE_NAMES:
            url = urllib.parse.urljoin(root, name)
            try:
                data = probe_table(url)
                rows = parse_table(data)
                direct_equity = value_by_codes(
                    rows,
                    "Households and nonprofit organizations; corporate equities; asset",
                    ("LM153064105", "FL153064105"),
                )
                try:
                    mutual_fund_shares = value_by_codes(
                        rows,
                        "Households and nonprofit organizations; mutual fund shares; asset",
                        ("LM153064205", "FL153064205"),
                    )
                except Exception:
                    mutual_fund_shares = None
                try:
                    debt_securities = value_by_codes(
                        rows,
                        "Households and nonprofit organizations; debt securities; asset",
                        ("LM154022005", "FL154022005"),
                    )
                    try:
                        loans = value_by_codes(
                            rows,
                            "Households and nonprofit organizations; loans; asset",
                            ("FL154023005", "LM154023005"),
                        )
                        loans_source = "FL154023005/LM154023005"
                    except Exception:
                        mortgages = value_by_codes(
                            rows,
                            "Households and nonprofit organizations; total mortgages; asset",
                            ("FL153065005", "LM153065005"),
                            aliases=("Households and nonprofit organizations; mortgages; asset",),
                        )
                        other_loans = value_by_codes(
                            rows,
                            "Households and nonprofit organizations; other loans and advances; asset",
                            ("FL153069005", "LM153069005"),
                        )
                        student_loans = value_by_codes(
                            rows,
                            "Nonprofit organizations; consumer credit, student loans; asset",
                            ("FL163066223", "LM163066223"),
                        )
                        loans = mortgages + other_loans + student_loans
                        loans_source = "FL153065005+FL153069005+FL163066223"
                except Exception:
                    # Before the 2015 Financial Accounts redesign the paper's debt
                    # securities + loans were reported together as credit market instruments.
                    debt_securities = value_by_codes(
                        rows,
                        "Households and nonprofit organizations; credit market instruments; asset",
                        ("FL154004005", "LM154004005"),
                    )
                    loans = 0.0
                    loans_source = "pre-2015 combined credit market instruments"
                checked = [direct_equity, debt_securities, loans]
                if mutual_fund_shares is not None:
                    checked.append(mutual_fund_shares)
                if min(checked) < 0:
                    raise RuntimeError("negative household balance-sheet component")
                return url, data, {
                    "direct_equity": direct_equity,
                    "debt_securities": debt_securities,
                    "mutual_fund_shares": mutual_fund_shares,
                    "loans": loans,
                    "loans_source": loans_source,
                }
            except Exception as exc:
                errors.append(f"{url}: {exc}")
    raise RuntimeError(f"household balance-sheet table not found: {'; '.join(errors)}")


def find_household_mutual_fund_shares(landing: str) -> tuple[str, bytes, float]:
    discovered = discovered_table_urls(
        landing,
        lambda text: (
            "mutual fund shares" in text.lower()
            and "money market" not in text.lower()
            and text.lower().startswith(("l.", "s."))
        ),
    )
    fallback = [
        urllib.parse.urljoin(root, name)
        for root in release_roots(landing)
        for name in ("l214.htm", "L214.htm", "l224.htm", "L224.htm")
    ]
    errors: list[str] = []
    for url in list(dict.fromkeys([*discovered, *fallback])):
        try:
            data = probe_table(url)
            rows = parse_table(data)
            value = value_by_codes(
                rows,
                "Households and nonprofit organizations; mutual fund shares; asset",
                ("LM153064205", "FL153064205"),
            )
            if value < 0:
                raise RuntimeError("negative household mutual-fund shares")
            return url, data, value
        except Exception as exc:
            errors.append(f"{url}: {exc}")
    raise RuntimeError(f"household mutual-fund shares table not found: {'; '.join(errors)}")


def find_mutual_fund_table(landing: str) -> tuple[str, bytes, dict[str, float]]:
    discovered = discovered_table_urls(
        landing,
        lambda text: (
            "mutual funds" in text.lower()
            and "money market" not in text.lower()
            and "mutual fund shares" not in text.lower()
            and text.lower().startswith(("l.", "s."))
        ),
    )
    fallback = [
        urllib.parse.urljoin(root, name)
        for root in release_roots(landing)
        for name in MUTUAL_FUND_TABLE_NAMES
    ]
    errors: list[str] = []
    for url in list(dict.fromkeys([*discovered, *fallback])):
        try:
            data = probe_table(url)
            rows = parse_table(data)
            equity = value_by_codes(rows, "Mutual funds; corporate equities; asset", ("LM653064100", "FL653064100"))
            treasury = value_by_codes(
                rows,
                "Mutual funds; Treasury securities; asset",
                ("LM653061105", "FL653061105"),
                aliases=("Mutual funds; Treasury securities; asset (market value)",),
            )
            agency = value_by_codes(
                rows,
                "Mutual funds; agency- and GSE-backed securities; asset",
                ("LM653061703", "FL653061703"),
                aliases=("Mutual funds; agency- and GSE-backed securities; asset (market value)",),
            )
            municipal = value_by_codes(
                rows,
                "Mutual funds; municipal securities; asset",
                ("LM653062003", "FL653062003"),
                aliases=(
                    "Mutual funds; municipal securities and loans; asset",
                    "Mutual funds; municipal securities; asset (market value)",
                ),
            )
            corporate_bonds = value_by_codes(
                rows,
                "Mutual funds; corporate and foreign bonds; asset",
                ("LM653063005", "FL653063005"),
                aliases=("Mutual funds; corporate and foreign bonds; asset (market value)",),
            )
            total_assets = value_by_codes(
                rows,
                "Mutual funds; total financial assets",
                ("LM654090000", "FL654090000", "LM653164205", "FL653164205"),
            )
            if total_assets <= 0 or min(equity, treasury, agency, municipal, corporate_bonds) < 0:
                raise RuntimeError("invalid mutual-fund balance-sheet component")
            return url, data, {
                "equity_assets": equity,
                "treasury_assets": treasury,
                "agency_assets": agency,
                "municipal_assets": municipal,
                "corporate_bond_assets": corporate_bonds,
                "total_assets": total_assets,
            }
        except Exception as exc:
            errors.append(f"{url}: {exc}")
    raise RuntimeError(f"mutual-fund balance-sheet table not found: {'; '.join(errors)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start-year", type=int, default=2011)
    parser.add_argument("--start-quarter", type=int, choices=[1, 2, 3, 4], default=1)
    parser.add_argument("--through-year", type=int, default=2026)
    parser.add_argument("--through-quarter", type=int, choices=[1, 2, 3, 4], default=1)
    args = parser.parse_args()

    outdir = Path(args.output_dir)
    rawdir = outdir / "raw-first-release-tables"
    outdir.mkdir(parents=True, exist_ok=True)
    rawdir.mkdir(parents=True, exist_ok=True)
    output_path = outdir / "HOUSEHOLD_EQUITY_SHARE_FIRST_RELEASE.csv"

    cached: dict[str, dict[str, str]] = {}
    if output_path.is_file():
        with output_path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                qid = row.get("quarter", "")
                household_path = outdir / row.get("household_table_local_path", "")
                fund_path = outdir / row.get("mutual_fund_table_local_path", "")
                share_local = row.get("household_mutual_fund_table_local_path", "")
                if not qid or not household_path.is_file() or not fund_path.is_file():
                    continue
                if sha(household_path.read_bytes()) != row.get("household_table_sha256"):
                    continue
                if sha(fund_path.read_bytes()) != row.get("mutual_fund_table_sha256"):
                    continue
                if share_local:
                    share_path = outdir / share_local
                    if not share_path.is_file():
                        continue
                    if sha(share_path.read_bytes()) != row.get("household_mutual_fund_table_sha256"):
                        continue
                row.setdefault("household_mutual_fund_table_url", "")
                row.setdefault("household_mutual_fund_table_sha256", "")
                row.setdefault("household_mutual_fund_table_local_path", "")
                cached[qid] = row

    rows: list[dict[str, object]] = []
    for year, quarter, landing in discover_releases(
        args.start_year, args.start_quarter, args.through_year, args.through_quarter
    ):
        qid = f"{year}Q{quarter}"
        if qid in cached:
            rows.append(dict(cached[qid]))
            print(f"HESHARE_VINTAGE_CACHED quarter={qid} release={cached[qid]['release_date']}", flush=True)
            continue

        household_url, household_data, hh = find_household_table(landing)
        share_url = ""
        share_data: bytes | None = None
        if hh["mutual_fund_shares"] is None:
            share_url, share_data, share_value = find_household_mutual_fund_shares(landing)
            hh["mutual_fund_shares"] = share_value
        fund_url, fund_data, mf = find_mutual_fund_table(landing)
        rel_date = release_date(household_url, year, quarter)
        if release_date(fund_url, year, quarter) != rel_date:
            raise RuntimeError(f"release-date mismatch for {qid}")
        if share_url and release_date(share_url, year, quarter) != rel_date:
            raise RuntimeError(f"household mutual-fund release-date mismatch for {qid}")
        available = (datetime.fromisoformat(rel_date).date() + timedelta(days=1)).isoformat()

        equity_fund_holdings = float(hh["mutual_fund_shares"]) * float(mf["equity_assets"]) / float(mf["total_assets"])
        bond_assets = (
            float(mf["treasury_assets"]) + float(mf["agency_assets"]) +
            float(mf["municipal_assets"]) + float(mf["corporate_bond_assets"])
        )
        bond_fund_holdings = float(hh["mutual_fund_shares"]) * bond_assets / float(mf["total_assets"])
        equity_assets = float(hh["direct_equity"]) + equity_fund_holdings
        credit_assets = float(hh["debt_securities"]) + float(hh["loans"]) + bond_fund_holdings
        denominator = equity_assets + credit_assets
        if denominator <= 0:
            raise RuntimeError(f"non-positive HEShare denominator at {qid}")
        heshare = equity_assets / denominator
        if not math.isfinite(heshare) or not 0 < heshare < 1:
            raise RuntimeError(f"implausible HEShare {heshare} at {qid}")

        household_path = rawdir / f"{qid}-households.html"
        fund_path = rawdir / f"{qid}-mutual-funds.html"
        share_path = rawdir / f"{qid}-household-mutual-fund-shares.html"
        household_path.write_bytes(household_data)
        fund_path.write_bytes(fund_data)
        if share_data is not None:
            share_path.write_bytes(share_data)
        row = {
            "quarter": qid,
            "release_date": rel_date,
            "available_date": available,
            "household_direct_equity_billions": hh["direct_equity"],
            "household_mutual_fund_shares_billions": hh["mutual_fund_shares"],
            "household_equity_fund_holdings_billions": equity_fund_holdings,
            "household_debt_securities_billions": hh["debt_securities"],
            "household_loans_billions": hh["loans"],
            "household_bond_fund_holdings_billions": bond_fund_holdings,
            "household_equity_assets_billions": equity_assets,
            "household_credit_assets_billions": credit_assets,
            "household_equity_share": heshare,
            "loans_source": hh["loans_source"],
            "household_table_url": household_url,
            "household_table_sha256": sha(household_data),
            "household_table_local_path": household_path.relative_to(outdir).as_posix(),
            "household_mutual_fund_table_url": share_url,
            "household_mutual_fund_table_sha256": sha(share_data) if share_data is not None else "",
            "household_mutual_fund_table_local_path": share_path.relative_to(outdir).as_posix() if share_data is not None else "",
            "mutual_fund_table_url": fund_url,
            "mutual_fund_table_sha256": sha(fund_data),
            "mutual_fund_table_local_path": fund_path.relative_to(outdir).as_posix(),
        }
        rows.append(row)
        # Persist each completed quarter so a network/tool timeout can resume without
        # re-downloading already frozen release tables.
        with output_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(
            f"HESHARE_VINTAGE quarter={qid} release={rel_date} heshare={heshare:.6f} "
            f"equity={equity_assets:.3f} credit={credit_assets:.3f}",
            flush=True,
        )

    if not rows:
        raise RuntimeError("no HEShare rows")
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    values = [float(row["household_equity_share"]) for row in rows]
    summary = {
        "purpose": "first-release Household Equity Share construction only; no strategy performance",
        "performance_computed": False,
        "paper_definition": "(direct corporate equities + equity mutual fund holdings) / (equity assets + debt securities + loans + bond mutual fund holdings)",
        "paper_series": ["FL153064105", "FL153064245", "FL154022005", "FL154023005", "FL153064235"],
        "computed_mutual_fund_formula": {
            "equity_funds": "FL153064205 * FL653064100 / FL653164205",
            "bond_funds": "FL153064205 * (FL653061105 + FL653061703 + FL653062003 + FL653063005) / FL653164205",
            "implementation_note": "level aliases LM... are accepted when archived balance-sheet tables display LM rather than FL; same-release mutual fund total financial assets LM654090000 is equivalent to mutual fund shares liability FL653164205 per the Federal Reserve series definition",
        },
        "loans_schema_note": "When legacy FL154023005 is absent after the June 2026 Z.1 taxonomy change, the exact legacy economic definition is reconstructed as FL153065005 + FL153069005 + FL163066223.",
        "first_quarter": rows[0]["quarter"],
        "last_quarter": rows[-1]["quarter"],
        "rows": len(rows),
        "min_household_equity_share": min(values),
        "max_household_equity_share": max(values),
        "output_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
        "point_in_time_note": "Every component is obtained from the same quarter's archived Federal Reserve Z.1 release; source household and mutual-fund tables are frozen locally with SHA-256 and become usable release_date+1 calendar day.",
    }
    (outdir / "fetch-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"HESHARE_VINTAGE_COMPLETE rows={len(rows)} min={min(values):.6f} max={max(values):.6f} "
        f"sha256={summary['output_sha256']}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
