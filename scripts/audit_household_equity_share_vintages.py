#!/usr/bin/env python3
"""Audit quarter-to-quarter vintage continuity for first-release Household Equity Share.

No strategy performance is calculated. For every release after the first, this script
reconstructs the immediately previous quarter from the *current* release's own historical
columns and compares that backcast with the prior quarter's recorded first-release HEShare.
Large differences indicate data-definition/revision breaks that must not be mistaken for
an economic factor move.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

from fetch_broker_dealer_leverage_vintage import TableParser
from fetch_net_payout_yield_vintage import numeric_values


def parse_rows(path: Path) -> list[list[str]]:
    parser = TableParser()
    parser.feed(path.read_text(encoding="utf-8", errors="ignore"))
    return parser.rows


def series_values(
    rows: list[list[str]],
    description: str,
    *,
    aliases: tuple[str, ...] = (),
    codes: tuple[str, ...] = (),
) -> list[float]:
    wanted = {description.lower(), *(alias.lower() for alias in aliases)}
    matches = [
        row
        for row in rows
        if (codes and any(cell.strip() in codes for cell in row[:4]))
        or any(cell.strip().lower() in wanted for cell in row[:3])
    ]
    if not matches:
        raise RuntimeError(f"missing row: {description}")
    values = [numeric_values(row) for row in matches]
    if any(candidate != values[0] for candidate in values[1:]):
        raise RuntimeError(f"ambiguous non-identical rows: {description}")
    return values[0]


def heshare_from_release(row: dict[str, str], root: Path, offset: int) -> float:
    household = parse_rows(root / row["household_table_local_path"])
    fund = parse_rows(root / row["mutual_fund_table_local_path"])
    if row.get("household_mutual_fund_table_local_path"):
        shares_rows = parse_rows(root / row["household_mutual_fund_table_local_path"])
    else:
        shares_rows = household

    direct = series_values(
        household,
        "Households and nonprofit organizations; corporate equities; asset",
        codes=("LM153064105", "FL153064105"),
    )[offset]
    shares = series_values(
        shares_rows,
        "Households and nonprofit organizations; mutual fund shares; asset",
        codes=("LM153064205", "FL153064205"),
    )[offset]

    loans_source = row["loans_source"]
    if loans_source == "pre-2015 combined credit market instruments":
        debt = series_values(
            household,
            "Households and nonprofit organizations; credit market instruments; asset",
            codes=("FL154004005", "LM154004005"),
        )[offset]
        loans = 0.0
    elif loans_source == "FL154023005/LM154023005":
        debt = series_values(
            household,
            "Households and nonprofit organizations; debt securities; asset",
            codes=("LM154022005", "FL154022005"),
        )[offset]
        loans = series_values(
            household,
            "Households and nonprofit organizations; loans; asset",
            codes=("FL154023005", "LM154023005"),
        )[offset]
    elif loans_source == "FL153065005+FL153069005+FL163066223":
        debt = series_values(
            household,
            "Households and nonprofit organizations; debt securities; asset",
            codes=("LM154022005", "FL154022005"),
        )[offset]
        mortgages = series_values(
            household,
            "Households and nonprofit organizations; total mortgages; asset",
            aliases=("Households and nonprofit organizations; mortgages; asset",),
            codes=("FL153065005", "LM153065005"),
        )[offset]
        other_loans = series_values(
            household,
            "Households and nonprofit organizations; other loans and advances; asset",
            codes=("FL153069005", "LM153069005"),
        )[offset]
        student_loans = series_values(
            household,
            "Nonprofit organizations; consumer credit, student loans; asset",
            codes=("FL163066223", "LM163066223"),
        )[offset]
        loans = mortgages + other_loans + student_loans
    else:
        raise RuntimeError(f"unknown loans source: {loans_source}")

    mf_equity = series_values(
        fund,
        "Mutual funds; corporate equities; asset",
        codes=("LM653064100", "FL653064100"),
    )[offset]
    mf_treasury = series_values(
        fund,
        "Mutual funds; Treasury securities; asset",
        aliases=("Mutual funds; Treasury securities; asset (market value)",),
        codes=("LM653061105", "FL653061105"),
    )[offset]
    mf_agency = series_values(
        fund,
        "Mutual funds; agency- and GSE-backed securities; asset",
        aliases=("Mutual funds; agency- and GSE-backed securities; asset (market value)",),
        codes=("LM653061703", "FL653061703"),
    )[offset]
    mf_municipal = series_values(
        fund,
        "Mutual funds; municipal securities; asset",
        aliases=(
            "Mutual funds; municipal securities and loans; asset",
            "Mutual funds; municipal securities; asset (market value)",
        ),
        codes=("LM653062003", "FL653062003"),
    )[offset]
    mf_corporate_bonds = series_values(
        fund,
        "Mutual funds; corporate and foreign bonds; asset",
        aliases=("Mutual funds; corporate and foreign bonds; asset (market value)",),
        codes=("LM653063005", "FL653063005"),
    )[offset]
    mf_total = series_values(
        fund,
        "Mutual funds; total financial assets",
        codes=("LM654090000", "FL654090000", "LM653164205", "FL653164205"),
    )[offset]

    if mf_total <= 0:
        raise RuntimeError("non-positive mutual-fund assets")
    equity_funds = shares * mf_equity / mf_total
    bond_funds = shares * (mf_treasury + mf_agency + mf_municipal + mf_corporate_bonds) / mf_total
    equity_assets = direct + equity_funds
    credit_assets = debt + loans + bond_funds
    denominator = equity_assets + credit_assets
    if denominator <= 0:
        raise RuntimeError("non-positive HEShare denominator")
    value = equity_assets / denominator
    if not math.isfinite(value) or not 0 < value < 1:
        raise RuntimeError(f"invalid HEShare {value}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    args = parser.parse_args()

    input_path = Path(args.input)
    root = input_path.parent
    with input_path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) < 2:
        raise RuntimeError("HEShare input has fewer than two quarters")

    audit: list[dict[str, object]] = []
    for index in range(1, len(rows)):
        current = rows[index]
        previous = rows[index - 1]
        backcast = heshare_from_release(current, root, -2)
        prior_first = float(previous["household_equity_share"])
        current_first = float(current["household_equity_share"])
        revision = backcast - prior_first
        observed_change = current_first - prior_first
        economic_change_with_current_vintage = current_first - backcast
        audit.append(
            {
                "current_quarter": current["quarter"],
                "previous_quarter": previous["quarter"],
                "current_release_date": current["release_date"],
                "previous_first_release_heshare": prior_first,
                "previous_quarter_backcast_in_current_release": backcast,
                "revision_delta": revision,
                "current_first_release_heshare": current_first,
                "observed_first_release_change": observed_change,
                "same_vintage_economic_change": economic_change_with_current_vintage,
                "absolute_revision_delta": abs(revision),
            }
        )

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fields = list(audit[0])
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(audit)

    ranked = sorted(audit, key=lambda row: float(row["absolute_revision_delta"]), reverse=True)
    threshold = 0.02
    breaks = [row for row in audit if float(row["absolute_revision_delta"]) >= threshold]
    summary = {
        "purpose": "HEShare first-release vintage continuity audit only; no strategy performance",
        "performance_computed": False,
        "rows": len(audit),
        "major_revision_threshold_absolute_share": threshold,
        "major_revision_count": len(breaks),
        "major_revision_quarters": [row["current_quarter"] for row in breaks],
        "last_major_revision_quarter": breaks[-1]["current_quarter"] if breaks else None,
        "max_absolute_revision_delta": float(ranked[0]["absolute_revision_delta"]),
        "top_revisions": ranked[:10],
    }
    Path(args.summary).write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    print("HESHARE_VINTAGE_CONTINUITY_AUDIT_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
