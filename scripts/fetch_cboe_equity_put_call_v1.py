#!/usr/bin/env python3
"""Build a stable-definition Cboe Equity Put/Call Ratio history without using portfolio returns.

Data policy:
- Cboe's legacy equitypc.csv is used only from 2012-06-11 onward because the file itself
  states that from that date Equity Volume excludes exchange-traded products (ETPs).
- The legacy file ends 2019-10-04. From 2019-10-07 onward, Cboe's official Daily Market
  Statistics page is queried by explicit date (`?dt=YYYY-MM-DD`).
- Daily values are conservatively marked available on trade_date + 1 calendar day.
- This script never reads backtest results or computes strategy performance.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import gzip
import hashlib
import io
import json
import re
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
LEGACY_URL = "https://cdn.cboe.com/resources/options/volume_and_call_put_ratios/equitypc.csv"
DAILY_URL = "https://www.cboe.com/us/options/market_statistics/daily/?dt={date}"
STABLE_START = dt.date(2012, 6, 11)
LEGACY_END = dt.date(2019, 10, 4)
WEB_START = dt.date(2019, 10, 7)
USER_AGENT = "Mozilla/5.0 (AssetTimeMachine research data audit; contact via repository owner)"
EQUITY_RATIO_RE = re.compile(r"EQUITY PUT/CALL RATIO[^0-9]*([0-9]+(?:\.[0-9]+)?)", re.I)
_thread_local = threading.local()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, timeout: float = 30.0) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,text/csv;q=0.9,*/*;q=0.8",
            "Accept-Encoding": "gzip",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read()
        if str(response.headers.get("Content-Encoding") or "").lower() == "gzip":
            data = gzip.decompress(data)
        return data


def parse_legacy(data: bytes) -> list[dict[str, Any]]:
    text = data.decode("utf-8-sig", errors="replace")
    lines = text.splitlines()
    header_index = next((index for index, line in enumerate(lines) if line.strip().upper().startswith("DATE,")), None)
    if header_index is None:
        raise RuntimeError("Cboe legacy equitypc.csv header not found")
    rows: list[dict[str, Any]] = []
    reader = csv.DictReader(io.StringIO("\n".join(lines[header_index:])), skipinitialspace=True)
    for row in reader:
        raw_date = str(row.get("DATE") or "").strip()
        raw_ratio = str(row.get("P/C Ratio") or "").strip()
        if not raw_date or not raw_ratio:
            continue
        try:
            day = dt.datetime.strptime(raw_date, "%m/%d/%Y").date()
            ratio = float(raw_ratio)
        except ValueError:
            continue
        if day < STABLE_START or day > LEGACY_END:
            continue
        if ratio < 0 or not (ratio < float("inf")):
            continue
        rows.append({
            "trade_date": day.isoformat(),
            "available_date": (day + dt.timedelta(days=1)).isoformat(),
            "equity_put_call_ratio": ratio,
            "source_segment": "cboe_equitypc_csv_stable_definition",
            "source_url": LEGACY_URL,
        })
    if not rows or rows[-1]["trade_date"] != LEGACY_END.isoformat():
        raise RuntimeError("legacy stable segment does not end on 2019-10-04")
    return rows


def weekdays(start: dt.date, end: dt.date) -> list[dt.date]:
    result = []
    day = start
    while day <= end:
        if day.weekday() < 5:
            result.append(day)
        day += dt.timedelta(days=1)
    return result


def fetch_daily(day: dt.date, attempts: int = 4) -> dict[str, Any]:
    url = DAILY_URL.format(date=day.isoformat())
    last_error = ""
    for attempt in range(attempts):
        try:
            data = request_bytes(url)
            text = data.decode("utf-8", errors="ignore")
            match = EQUITY_RATIO_RE.search(text)
            if match is None:
                return {
                    "date": day.isoformat(),
                    "status": "no_ratio",
                    "ratio": None,
                    "response_sha256": sha256_bytes(data),
                    "response_bytes": len(data),
                    "url": url,
                }
            ratio = float(match.group(1))
            return {
                "date": day.isoformat(),
                "status": "ok",
                "ratio": ratio,
                "response_sha256": sha256_bytes(data),
                "response_bytes": len(data),
                "url": url,
            }
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
            last_error = f"{type(exc).__name__}: {exc}"
            time.sleep(0.5 * (attempt + 1))
    return {
        "date": day.isoformat(),
        "status": "error",
        "ratio": None,
        "error": last_error[:500],
        "url": url,
    }


def load_cache(path: Path) -> dict[str, dict[str, Any]]:
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("daily cache root must be an object")
    return {str(key): dict(item) for key, item in value.items()}


def save_cache(path: Path, cache: dict[str, dict[str, Any]]) -> None:
    path.write_text(json.dumps(cache, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def assemble(output_dir: Path, legacy_data: bytes, cache: dict[str, dict[str, Any]]) -> dict[str, Any]:
    legacy_rows = parse_legacy(legacy_data)
    web_rows: list[dict[str, Any]] = []
    errors = []
    no_ratio = []
    for day in sorted(cache):
        item = cache[day]
        status = item.get("status")
        if status == "ok":
            date = dt.date.fromisoformat(day)
            if date < WEB_START:
                continue
            web_rows.append({
                "trade_date": day,
                "available_date": (date + dt.timedelta(days=1)).isoformat(),
                "equity_put_call_ratio": float(item["ratio"]),
                "source_segment": "cboe_daily_market_statistics_explicit_date",
                "source_url": item["url"],
            })
        elif status == "error":
            errors.append(day)
        elif status == "no_ratio":
            no_ratio.append(day)

    combined = legacy_rows + web_rows
    combined.sort(key=lambda row: row["trade_date"])
    if len({row["trade_date"] for row in combined}) != len(combined):
        raise RuntimeError("duplicate trade dates across Cboe source segments")
    if web_rows and web_rows[0]["trade_date"] != WEB_START.isoformat():
        raise RuntimeError(f"web segment does not begin on {WEB_START.isoformat()}: {web_rows[0]['trade_date']}")
    dates = [dt.date.fromisoformat(row["trade_date"]) for row in combined]
    gaps = [(right - left).days for left, right in zip(dates, dates[1:])]
    max_gap = max(gaps, default=0)

    output_csv = output_dir / "CBOE_EQUITY_PUT_CALL_STABLE.csv"
    with output_csv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "trade_date", "available_date", "equity_put_call_ratio", "source_segment", "source_url"
        ])
        writer.writeheader()
        for row in combined:
            writer.writerow(row)

    # Transition diagnostics are data-only: no portfolio returns are touched.
    pre = [row["equity_put_call_ratio"] for row in legacy_rows[-20:]]
    post = [row["equity_put_call_ratio"] for row in web_rows[:20]]
    pre_median = sorted(pre)[len(pre) // 2] if pre else None
    post_median = sorted(post)[len(post) // 2] if post else None
    summary = {
        "purpose": "Cboe Equity Put/Call Ratio source continuity audit only; no strategy performance",
        "performance_computed": False,
        "stable_definition_start": STABLE_START.isoformat(),
        "stable_definition_reason": (
            "Cboe equitypc.csv states that as of 2012-06-11 Equity Volume includes only equity option products "
            "and excludes exchange-traded products; earlier rows are intentionally excluded"
        ),
        "availability_rule": "trade_date + 1 calendar day",
        "legacy_url": LEGACY_URL,
        "daily_url_template": DAILY_URL,
        "legacy_rows": len(legacy_rows),
        "web_rows": len(web_rows),
        "combined_rows": len(combined),
        "first_trade_date": combined[0]["trade_date"] if combined else None,
        "last_trade_date": combined[-1]["trade_date"] if combined else None,
        "web_no_ratio_weekdays": no_ratio,
        "web_errors": errors,
        "max_calendar_gap_between_observations": max_gap,
        "transition_last_legacy": legacy_rows[-1] if legacy_rows else None,
        "transition_first_web": web_rows[0] if web_rows else None,
        "transition_last20_legacy_median": pre_median,
        "transition_first20_web_median": post_median,
        "output_sha256": sha256_file(output_csv),
        "cache_entries": len(cache),
    }
    (output_dir / "fetch-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start", default=WEB_START.isoformat())
    parser.add_argument("--end", required=True)
    parser.add_argument("--workers", type=int, default=24)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    legacy_path = output_dir / "equitypc.csv"
    if args.refresh or not legacy_path.exists():
        legacy_path.write_bytes(request_bytes(LEGACY_URL))
    legacy_data = legacy_path.read_bytes()

    start = max(dt.date.fromisoformat(args.start), WEB_START)
    end = dt.date.fromisoformat(args.end)
    if end < start:
        raise RuntimeError("end date precedes start date")

    cache_path = output_dir / "daily-page-cache.json"
    cache = load_cache(cache_path)
    wanted = [day for day in weekdays(start, end) if args.refresh or day.isoformat() not in cache or cache[day.isoformat()].get("status") == "error"]
    if wanted:
        with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 64))) as pool:
            futures = {pool.submit(fetch_daily, day): day for day in wanted}
            for index, future in enumerate(as_completed(futures), start=1):
                result = future.result()
                cache[result["date"]] = result
                if index % 100 == 0:
                    save_cache(cache_path, cache)
        save_cache(cache_path, cache)

    summary = assemble(output_dir, legacy_data, cache)
    print(json.dumps({
        "requested_start": start.isoformat(),
        "requested_end": end.isoformat(),
        "new_or_refreshed_weekdays": len(wanted),
        "combined_rows": summary["combined_rows"],
        "last_trade_date": summary["last_trade_date"],
        "web_errors": len(summary["web_errors"]),
        "web_no_ratio_weekdays": len(summary["web_no_ratio_weekdays"]),
        "max_calendar_gap": summary["max_calendar_gap_between_observations"],
        "transition_last20_legacy_median": summary["transition_last20_legacy_median"],
        "transition_first20_web_median": summary["transition_first20_web_median"],
    }, ensure_ascii=False, sort_keys=True))
    print("CBOE_EQUITY_PUT_CALL_FETCH_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
