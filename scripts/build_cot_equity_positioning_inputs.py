#!/usr/bin/env python3
"""Build point-in-time CFTC TFF availability and one frozen positioning input.

This script does not calculate AssetTimeMachine strategy returns. It transforms the
already-fetched official CFTC consolidated S&P 500 / Nasdaq-100 TFF rows into a
conservative availability calendar and a single pre-performance factor input:

    F-COT-LEV-SPX raw state = weekly change in S&P 500 Consolidated Leveraged Money
    net-long share of total open interest.

The public CFTC archive stores report/position dates rather than release timestamps.
For ordinary weeks we deliberately wait seven calendar days after the report date,
which is more conservative than the usual Friday 15:30 ET release of prior-Tuesday
data and also covers ordinary one/two-day holiday delays. Known extraordinary COT
publication disruptions are handled separately below.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

NORMAL_CONSERVATIVE_LAG_DAYS = 7
SP500_MARKET = "sp500_consolidated"
EXPECTED_MARKETS = {"sp500_consolidated", "nasdaq100_consolidated"}

# Official CFTC announcements establish that these report-date ranges were not
# published on the normal schedule. We exclude them rather than infer exact releases.
# The first ordinary row after each range is delayed by NORMAL_CONSERVATIVE_LAG_DAYS,
# which places its use after the published catch-up completion boundary.
BLACKOUTS = [
    {
        "start": "2013-10-01",
        "end": "2013-10-29",
        "reason": "2013 federal shutdown; CFTC resumed rolling publication 2013-10-25 and expected normal schedule by 2013-11-08",
        "source": "CFTC Release 6745-13",
    },
    {
        "start": "2018-12-24",
        "end": "2019-02-26",
        "reason": "2018-2019 lapse in appropriations; last normal COT release was 2018-12-21 and catch-up started 2019-02-01",
        "source": "CFTC Release 7864-19",
    },
    {
        "start": "2023-01-31",
        "end": "2023-03-14",
        "reason": "ION cyber incident delayed COT reports; CFTC issued the report originally scheduled for 2023-03-17 on 2023-03-21",
        "source": "CFTC Release 8662-23 / COT Historical Special Announcements",
    },
]

# 2025 has an exact official catch-up table, so preserve the observations using their
# actual publication dates. To avoid any same-day/intraday ambiguity, the factor may
# use each row only from the following calendar day.
ACTUAL_RELEASE_2025 = {
    "2025-09-30": "2025-11-19",
    "2025-10-07": "2025-11-21",
    "2025-10-14": "2025-11-25",
    "2025-10-21": "2025-12-02",
    "2025-10-28": "2025-12-05",
    "2025-11-04": "2025-12-09",
    "2025-11-10": "2025-12-10",
    "2025-11-18": "2025-12-12",
    "2025-11-25": "2025-12-15",
    "2025-12-02": "2025-12-17",
    "2025-12-09": "2025-12-19",
    "2025-12-16": "2025-12-23",
    "2025-12-23": "2025-12-29",
}

PROVENANCE = {
    "normal_schedule": "https://www.cftc.gov/MarketReports/CommitmentsofTraders/ReleaseSchedule/index.htm",
    "historical_dates_warning": "https://www.cftc.gov/MarketReports/CommitmentsofTraders/HistoricalViewable/index.htm",
    "shutdown_2013": "https://www.cftc.gov/PressRoom/PressReleases/6745-13",
    "shutdown_2019": "https://www.cftc.gov/PressRoom/PressReleases/7864-19",
    "ion_2023": "https://www.cftc.gov/PressRoom/PressReleases/8662-23",
    "special_announcements": "https://www.cftc.gov/MarketReports/CommitmentsofTraders/HistoricalSpecialAnnouncements/index.htm",
    "shutdown_2025": "https://www.cftc.gov/PressRoom/PressReleases/9147-25",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_day(value: str) -> date:
    return datetime.strptime(value, "%Y-%m-%d").date()


def finite_float(raw: Any, *, field: str, report_date: str) -> float:
    try:
        value = float(str(raw).strip())
    except (TypeError, ValueError) as error:
        raise RuntimeError(f"invalid {field} at report_date={report_date}: {raw!r}") from error
    if not math.isfinite(value):
        raise RuntimeError(f"non-finite {field} at report_date={report_date}")
    return value


def blackout_for(report_date: str) -> dict[str, str] | None:
    for item in BLACKOUTS:
        if item["start"] <= report_date <= item["end"]:
            return item
    return None


def availability_for(report_date: str) -> dict[str, Any]:
    blackout = blackout_for(report_date)
    if blackout is not None:
        return {
            "usable": False,
            "actual_release_date": "",
            "conservative_available_date": "",
            "availability_policy": "excluded_known_publication_disruption",
            "availability_reason": blackout["reason"],
            "availability_source": blackout["source"],
        }

    actual = ACTUAL_RELEASE_2025.get(report_date)
    if actual is not None:
        available = parse_day(actual) + timedelta(days=1)
        return {
            "usable": True,
            "actual_release_date": actual,
            "conservative_available_date": available.isoformat(),
            "availability_policy": "official_actual_release_plus_1_calendar_day",
            "availability_reason": "2025 shutdown/backlog exact CFTC publication table; +1 day avoids same-day timing ambiguity",
            "availability_source": "CFTC Release 9147-25",
        }

    report = parse_day(report_date)
    available = report + timedelta(days=NORMAL_CONSERVATIVE_LAG_DAYS)
    return {
        "usable": True,
        "actual_release_date": "",
        "conservative_available_date": available.isoformat(),
        "availability_policy": "report_date_plus_7_calendar_days",
        "availability_reason": "conservative proxy for usual prior-Tuesday data published Friday at 15:30 ET; also covers ordinary holiday delays",
        "availability_source": "CFTC Release Schedule",
    }


def read_raw(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {
            "normalized_market",
            "Report_Date_as_YYYY-MM-DD",
            "Open_Interest_All",
            "Lev_Money_Positions_Long_All",
            "Lev_Money_Positions_Short_All",
            "CFTC_Contract_Market_Code",
        }
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise RuntimeError(f"raw COT input missing columns: {sorted(missing)}")
        rows = list(reader)
    if not rows:
        raise RuntimeError("raw COT input is empty")
    return rows


def validate_pairing(rows: list[dict[str, str]]) -> dict[str, dict[str, dict[str, str]]]:
    by_date: dict[str, dict[str, dict[str, str]]] = {}
    for row in rows:
        report_date = row["Report_Date_as_YYYY-MM-DD"]
        market = row["normalized_market"]
        if market not in EXPECTED_MARKETS:
            raise RuntimeError(f"unexpected market {market}")
        markets = by_date.setdefault(report_date, {})
        if market in markets:
            raise RuntimeError(f"duplicate market row date={report_date} market={market}")
        markets[market] = row
    incomplete = {day: sorted(EXPECTED_MARKETS - set(markets)) for day, markets in by_date.items() if set(markets) != EXPECTED_MARKETS}
    if incomplete:
        first = next(iter(sorted(incomplete.items())))
        raise RuntimeError(f"COT consolidated market pairing incomplete: first={first} total={len(incomplete)}")
    return by_date


def build_calendar(by_date: dict[str, dict[str, dict[str, str]]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for report_date in sorted(by_date):
        availability = availability_for(report_date)
        output.append({
            "report_date": report_date,
            **availability,
            "market_count": len(by_date[report_date]),
        })
    return output


def build_sp500_factor(
    by_date: dict[str, dict[str, dict[str, str]]],
    calendar: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    availability_by_date = {row["report_date"]: row for row in calendar}
    report_dates = sorted(by_date)
    output: list[dict[str, Any]] = []
    prior_usable_net_share: float | None = None
    prior_usable_report_date: str | None = None
    for report_date in report_dates:
        spx = by_date[report_date][SP500_MARKET]
        oi = finite_float(spx["Open_Interest_All"], field="Open_Interest_All", report_date=report_date)
        long_value = finite_float(
            spx["Lev_Money_Positions_Long_All"],
            field="Lev_Money_Positions_Long_All",
            report_date=report_date,
        )
        short_value = finite_float(
            spx["Lev_Money_Positions_Short_All"],
            field="Lev_Money_Positions_Short_All",
            report_date=report_date,
        )
        if oi <= 0:
            raise RuntimeError(f"non-positive open interest at {report_date}")
        net_share = (long_value - short_value) / oi
        availability = availability_by_date[report_date]
        delta = (
            None
            if not availability["usable"] or prior_usable_net_share is None
            else net_share - prior_usable_net_share
        )
        output.append({
            "report_date": report_date,
            "conservative_available_date": availability["conservative_available_date"],
            "usable": availability["usable"],
            "availability_policy": availability["availability_policy"],
            "contract_market_code": spx["CFTC_Contract_Market_Code"],
            "open_interest": oi,
            "leveraged_money_long": long_value,
            "leveraged_money_short": short_value,
            "leveraged_money_net_long_share": net_share,
            "prior_report_date": prior_usable_report_date or "",
            "delta_net_long_share": "" if delta is None else delta,
        })
        if availability["usable"]:
            prior_usable_net_share = net_share
            prior_usable_report_date = report_date
    return output


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    raw_path = Path(args.raw)
    output_dir = Path(args.output_dir)
    rows = read_raw(raw_path)
    by_date = validate_pairing(rows)
    calendar = build_calendar(by_date)
    factor = build_sp500_factor(by_date, calendar)

    calendar_path = output_dir / "COT_AVAILABILITY.csv"
    factor_path = output_dir / "SP500_LEVERAGED_MONEY_NET_CHANGE.csv"
    write_csv(
        calendar_path,
        calendar,
        [
            "report_date", "usable", "actual_release_date", "conservative_available_date",
            "availability_policy", "availability_reason", "availability_source", "market_count",
        ],
    )
    write_csv(
        factor_path,
        factor,
        [
            "report_date", "conservative_available_date", "usable", "availability_policy",
            "contract_market_code", "open_interest", "leveraged_money_long", "leveraged_money_short",
            "leveraged_money_net_long_share", "prior_report_date", "delta_net_long_share",
        ],
    )

    usable = [row for row in factor if row["usable"] and row["delta_net_long_share"] != ""]
    excluded = [row for row in calendar if not row["usable"]]
    if not usable:
        raise RuntimeError("no usable COT factor observations")
    summary = {
        "purpose": "point-in-time COT factor-input construction only; no strategy performance",
        "performance_computed": False,
        "factor_id": "F-COT-LEV-SPX",
        "factor_definition": "weekly change in S&P 500 Consolidated Leveraged Money net-long share of total open interest",
        "risk_on_rule_not_yet_executed": "delta_net_long_share > 0",
        "raw_input": raw_path.as_posix(),
        "raw_input_sha256": sha256(raw_path),
        "calendar_sha256": sha256(calendar_path),
        "factor_input_sha256": sha256(factor_path),
        "rows_total": len(factor),
        "rows_usable_with_delta": len(usable),
        "first_report_date": factor[0]["report_date"],
        "last_report_date": factor[-1]["report_date"],
        "first_usable_available_date": usable[0]["conservative_available_date"],
        "last_usable_available_date": usable[-1]["conservative_available_date"],
        "excluded_report_rows": len(excluded),
        "normal_conservative_lag_days": NORMAL_CONSERVATIVE_LAG_DAYS,
        "known_blackouts": BLACKOUTS,
        "actual_release_overrides_2025": ACTUAL_RELEASE_2025,
        "provenance": PROVENANCE,
        "point_in_time_note": (
            "Historical CFTC page dates are report/position dates, not release dates. Ordinary rows are delayed by 7 calendar days; "
            "known exceptional publication disruptions are excluded unless the CFTC published an exact actual-release table."
        ),
    }
    summary_path = output_dir / "availability-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "COT_INPUTS_COMPLETE "
        f"reports={len(factor)} usable_with_delta={len(usable)} excluded={len(excluded)} "
        f"first={factor[0]['report_date']} last={factor[-1]['report_date']} "
        f"factor_sha256={summary['factor_input_sha256']} calendar_sha256={summary['calendar_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
