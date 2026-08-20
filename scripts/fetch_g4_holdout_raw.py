#!/usr/bin/env python3
"""Fetch ATM-SVP-2 G4 raw role series from frozen sources.

Formal mode is deliberately locked behind the one-shot holdout authorization receipt. Before a
holdout is frozen/burned, use `development` only with explicitly supplied non-holdout/exposed
series and short ranges to test source adapters.

Supported frozen source families:
- FRED_NASDAQ: FRED graph CSV (daily close)
- CSINDEX: China Securities Index official index-perf API (daily OHLC)
- SGE: Shanghai Gold Exchange official daily pages/archive articles (daily OHLC)

This module fetches data only. It does not calculate returns, performance metrics or strategy state.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import csv
import hashlib
import io
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable

from strategy_validation_holdout import validate_manifest

ROOT = Path(__file__).resolve().parents[1]
USER_AGENT = "AssetTimeMachine-ATM-SVP-G4/1.0"
SUPPORTED_SOURCES = {"FRED_NASDAQ", "YAHOO_FTSE_RUSSELL", "YAHOO_SSE", "CSINDEX", "SGE"}
DEVELOPMENT_ALLOWLIST = {
    "FRED_NASDAQ": {"VIXCLS"},
    "CSINDEX": {"000300"},
    "SGE": {"Au99.95"},
}
HTTP_CLIENT_USED: dict[str, str] = {}


@dataclass(frozen=True)
class DailyRow:
    day: str
    close: float
    open: float | None = None
    high: float | None = None
    low: float | None = None
    volume: float | None = None


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(data)
        temp = Path(handle.name)
    temp.replace(path)


def request_bytes(url: str, *, timeout: int = 30, accept: str = "*/*", attempts: int = 4) -> bytes:
    error: Exception | None = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(
                url,
                headers={"User-Agent": USER_AGENT, "Accept": accept},
            )
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
            HTTP_CLIENT_USED[url] = "urllib"
            return payload
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            error = exc
            if attempt + 1 < attempts:
                time.sleep(0.5 * (2**attempt))

    curl = subprocess.run(
        [
            "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors", "--retry-delay", "1",
            "--connect-timeout", str(min(timeout, 15)), "--max-time", str(max(timeout, 30)),
            "-A", USER_AGENT, "-H", f"Accept: {accept}", url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if curl.returncode == 0 and curl.stdout:
        HTTP_CLIENT_USED[url] = "curl_http1.1_fallback"
        return curl.stdout
    message = curl.stderr.decode("utf-8", "ignore").strip()
    raise RuntimeError(
        f"request failed via urllib and curl: {url}; urllib={error}; curl={message or curl.returncode}"
    )


def curl_request_bytes(
    url: str, *, timeout: int = 15, accept: str = "*/*", retries: int = 1,
    minimal_headers: bool = False,
) -> bytes:
    command = [
        "curl", "--http1.1", "-fsSL", "--retry", str(retries), "--retry-all-errors",
        "--retry-delay", "1", "--connect-timeout", str(min(timeout, 10)),
        "--max-time", str(timeout),
    ]
    if not minimal_headers:
        command.extend(["-A", USER_AGENT, "-H", f"Accept: {accept}"])
    command.append(url)
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0 or not completed.stdout:
        raise RuntimeError(
            f"curl HTTP/1.1 request failed: {url}: "
            f"{completed.stderr.decode('utf-8', 'ignore').strip() or completed.returncode}"
        )
    HTTP_CLIENT_USED[url] = "curl_http1.1"
    return completed.stdout


def request_text(url: str, *, timeout: int = 30) -> str:
    return request_bytes(url, timeout=timeout, accept="text/html,application/xhtml+xml").decode("utf-8", "ignore")


def finite_number(raw: Any) -> float | None:
    if raw is None or raw == "" or raw == ".":
        return None
    try:
        value = float(str(raw).replace(",", "").strip())
    except (TypeError, ValueError):
        return None
    if value != value or value in {float("inf"), float("-inf")}:
        return None
    return value


def iso_day(raw: Any) -> str:
    text = str(raw).strip()
    if re.fullmatch(r"\d{8}", text):
        return f"{text[:4]}-{text[4:6]}-{text[6:8]}"
    return date.fromisoformat(text[:10]).isoformat()


def validate_rows(rows: Iterable[DailyRow], start: str, end: str, label: str) -> list[DailyRow]:
    by_day: dict[str, DailyRow] = {}
    for row in rows:
        if not (start <= row.day <= end):
            continue
        if row.close <= 0:
            continue
        if row.day in by_day:
            raise RuntimeError(f"duplicate date for {label}: {row.day}")
        by_day[row.day] = row
    ordered = [by_day[key] for key in sorted(by_day)]
    if len(ordered) < 2:
        raise RuntimeError(f"insufficient daily rows for {label}: {len(ordered)}")
    return ordered


def public_history_document(
    *, raw_symbol: str, source_series_id: str, source: str, currency: str, unit: str,
    category: str, label: str, rows: list[DailyRow], provenance: dict[str, Any],
) -> dict[str, Any]:
    has_ohlc = all(row.open is not None and row.high is not None and row.low is not None for row in rows)
    return {
        "success": True,
        "symbols": [raw_symbol],
        "period": "atm-svp-g4-raw",
        "start_date": rows[0].day,
        "end_date": rows[-1].day,
        "series": [{
            "symbol": raw_symbol,
            "category": category,
            "label": label,
            "currency": currency,
            "unit": unit,
            "source": source,
            "dates": [row.day for row in rows],
            "prices": [row.close for row in rows],
            "start_date": rows[0].day,
            "end_date": rows[-1].day,
            "fetched_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "has_ohlc": has_ohlc,
            "ohlc_source": source if has_ohlc else None,
            "ohlc_coverage_ratio": 1.0 if has_ohlc else 0.0,
            "open_prices": [row.open for row in rows] if has_ohlc else None,
            "high_prices": [row.high for row in rows] if has_ohlc else None,
            "low_prices": [row.low for row in rows] if has_ohlc else None,
            "close_prices": [row.close for row in rows] if has_ohlc else None,
            "volumes": [row.volume for row in rows] if any(row.volume is not None for row in rows) else None,
        }],
        "atm_svp_raw_provenance": {
            "protocol_id": "ATM-SVP-2",
            "source_series_id": source_series_id,
            **provenance,
        },
    }


def fetch_fred(series_id: str, start: str, end: str) -> tuple[list[DailyRow], dict[str, Any]]:
    query = urllib.parse.urlencode({"id": series_id, "cosd": start, "coed": end})
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?{query}"
    text = curl_request_bytes(url, timeout=15, retries=1, accept="text/csv", minimal_headers=True).decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))
    rows: list[DailyRow] = []
    for item in reader:
        day = item.get("DATE") or item.get("observation_date")
        value = finite_number(item.get(series_id))
        if day and value is not None:
            rows.append(DailyRow(iso_day(day), value))
    return validate_rows(rows, start, end, f"FRED:{series_id}"), {
        "transport": "fredgraph_csv",
        "http_client": HTTP_CLIENT_USED.get(url),
        "request_url_template": "https://fred.stlouisfed.org/graph/fredgraph.csv?id=<series>&cosd=<start>&coed=<end>",
    }


def fetch_yahoo(series_id: str, start: str, end: str) -> tuple[list[DailyRow], dict[str, Any]]:
    start_dt = datetime.fromisoformat(start).replace(tzinfo=timezone.utc)
    end_dt = datetime.fromisoformat(end).replace(tzinfo=timezone.utc) + timedelta(days=1)
    query = urllib.parse.urlencode({
        "period1": int(start_dt.timestamp()),
        "period2": int(end_dt.timestamp()),
        "interval": "1d",
        "events": "history",
        "includeAdjustedClose": "true",
    })
    quoted = urllib.parse.quote(series_id, safe="")
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{quoted}?{query}"
    payload = json.loads(request_bytes(url, accept="application/json"))
    chart = payload.get("chart") or {}
    errors = chart.get("error")
    if errors:
        raise RuntimeError(f"Yahoo error for {series_id}: {errors}")
    results = chart.get("result") or []
    if not results:
        raise RuntimeError(f"Yahoo returned no result for {series_id}")
    result = results[0]
    timestamps = result.get("timestamp") or []
    quote_rows = ((result.get("indicators") or {}).get("quote") or [{}])[0]
    opens = quote_rows.get("open") or []
    highs = quote_rows.get("high") or []
    lows = quote_rows.get("low") or []
    closes = quote_rows.get("close") or []
    volumes = quote_rows.get("volume") or []
    rows: list[DailyRow] = []
    for index, ts in enumerate(timestamps):
        if index >= len(closes):
            continue
        close = finite_number(closes[index])
        if close is None:
            continue
        day = datetime.fromtimestamp(int(ts), timezone.utc).date().isoformat()
        rows.append(DailyRow(
            day=day,
            close=close,
            open=finite_number(opens[index]) if index < len(opens) else None,
            high=finite_number(highs[index]) if index < len(highs) else None,
            low=finite_number(lows[index]) if index < len(lows) else None,
            volume=finite_number(volumes[index]) if index < len(volumes) else None,
        ))
    meta = result.get("meta") or {}
    return validate_rows(rows, start, end, f"Yahoo:{series_id}"), {
        "transport": "yahoo_chart_v8",
        "http_client": HTTP_CLIENT_USED.get(url),
        "instrument_type": meta.get("instrumentType"),
        "exchange_name": meta.get("exchangeName"),
        "data_granularity": meta.get("dataGranularity"),
    }


def fetch_csindex(series_id: str, start: str, end: str) -> tuple[list[DailyRow], dict[str, Any]]:
    query = urllib.parse.urlencode({
        "indexCode": series_id,
        "startDate": start.replace("-", ""),
        "endDate": end.replace("-", ""),
    })
    url = f"https://www.csindex.com.cn/csindex-home/perf/index-perf?{query}"
    payload = json.loads(request_bytes(url, accept="application/json"))
    if str(payload.get("code")) != "200":
        raise RuntimeError(f"CSIndex response code for {series_id}: {payload.get('code')}")
    rows: list[DailyRow] = []
    names: set[str] = set()
    for item in payload.get("data") or []:
        close = finite_number(item.get("close"))
        if close is None:
            continue
        name = item.get("indexNameCn") or item.get("indexNameEn")
        if name:
            names.add(str(name))
        rows.append(DailyRow(
            day=iso_day(item.get("tradeDate")),
            close=close,
            open=finite_number(item.get("open")),
            high=finite_number(item.get("high")),
            low=finite_number(item.get("low")),
            volume=finite_number(item.get("tradingVol")),
        ))
    return validate_rows(rows, start, end, f"CSIndex:{series_id}"), {
        "transport": "csindex_index_perf_json",
        "http_client": HTTP_CLIENT_USED.get(url),
        "endpoint": "https://www.csindex.com.cn/csindex-home/perf/index-perf",
        "reported_names": sorted(names),
    }


class TableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.tables: list[list[list[str]]] = []
        self._table: list[list[str]] | None = None
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "table":
            self._table = []
        elif self._table is not None and tag == "tr":
            self._row = []
        elif self._row is not None and tag in {"td", "th"}:
            self._cell = []

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag in {"td", "th"} and self._cell is not None and self._row is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None and self._table is not None:
            if self._row:
                self._table.append(self._row)
            self._row = None
        elif tag == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None


class ArchiveListParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str]] = []
        self._href: str | None = None
        self._text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        href = dict(attrs).get("href")
        if href and re.fullmatch(r"/sjzx/mrhqsj/\d+", href):
            self._href = href
            self._text = []

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._href is not None:
            text = " ".join("".join(self._text).split())
            match = re.search(r"20\d{2}-\d{2}-\d{2}", text)
            if match:
                self.links.append((self._href, match.group(0)))
            self._href = None
            self._text = []


def html_tables(text: str) -> list[list[list[str]]]:
    parser = TableParser()
    parser.feed(text)
    return parser.tables


def normalized_sge_contract(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def sge_contract_row_from_new_html(text: str, contract: str) -> DailyRow | None:
    for table in html_tables(text):
        if not table:
            continue
        header = [re.sub(r"\s+", "", value) for value in table[0]]
        if not {"日期", "合约", "开盘价", "最高价", "最低价", "收盘价"}.issubset(set(header)):
            continue
        index = {name: header.index(name) for name in ["日期", "合约", "开盘价", "最高价", "最低价", "收盘价"]}
        volume_index = header.index("成交量（kg）") if "成交量（kg）" in header else None
        for raw in table[1:]:
            if len(raw) <= max(index.values()):
                continue
            if normalized_sge_contract(raw[index["合约"]]) != normalized_sge_contract(contract):
                continue
            close = finite_number(raw[index["收盘价"]])
            if close is None:
                continue
            return DailyRow(
                day=iso_day(raw[index["日期"]]),
                close=close,
                open=finite_number(raw[index["开盘价"]]),
                high=finite_number(raw[index["最高价"]]),
                low=finite_number(raw[index["最低价"]]),
                volume=finite_number(raw[volume_index]) if volume_index is not None and volume_index < len(raw) else None,
            )
    return None


def sge_contract_row_from_archive_html(text: str, contract: str, day: str) -> DailyRow | None:
    for table in html_tables(text):
        if not table:
            continue
        header = [re.sub(r"\s+", "", value) for value in table[0]]
        contract_column = "品种" if "品种" in header else ("合约" if "合约" in header else None)
        required = {"开盘价", "收盘价", "最高价", "最低价"}
        if contract_column is None or not required.issubset(set(header)):
            continue
        index = {name: header.index(name) for name in required}
        contract_index = header.index(contract_column)
        volume_index = header.index("成交量") if "成交量" in header else None
        for raw in table[1:]:
            if len(raw) <= max([*index.values(), contract_index]):
                continue
            if normalized_sge_contract(raw[contract_index]) != normalized_sge_contract(contract):
                continue
            close = finite_number(raw[index["收盘价"]])
            if close is None:
                continue
            return DailyRow(
                day=day,
                close=close,
                open=finite_number(raw[index["开盘价"]]),
                high=finite_number(raw[index["最高价"]]),
                low=finite_number(raw[index["最低价"]]),
                volume=finite_number(raw[volume_index]) if volume_index is not None and volume_index < len(raw) else None,
            )
    return None


def cache_text(url: str, path: Path) -> str:
    if path.exists():
        return path.read_text(encoding="utf-8", errors="ignore")
    text = request_text(url)
    atomic_write(path, text.encode("utf-8"))
    return text


def month_windows(start: date, end: date) -> Iterable[tuple[date, date]]:
    cursor = start
    while cursor <= end:
        if cursor.month == 12:
            next_month = date(cursor.year + 1, 1, 1)
        else:
            next_month = date(cursor.year, cursor.month + 1, 1)
        chunk_end = min(end, next_month - timedelta(days=1))
        yield cursor, chunk_end
        cursor = chunk_end + timedelta(days=1)


def fetch_sge_recent(contract: str, start: str, end: str, cache_dir: Path) -> list[DailyRow]:
    begin = max(date.fromisoformat(start), date(2024, 1, 1))
    finish = date.fromisoformat(end)
    if begin > finish:
        return []
    rows: list[DailyRow] = []
    for chunk_start, chunk_end in month_windows(begin, finish):
        query = urllib.parse.urlencode({"start_date": chunk_start.isoformat(), "end_date": chunk_end.isoformat()})
        url = f"https://www.sge.com.cn/sjzx/quotation_daily_new?{query}"
        text = cache_text(url, cache_dir / "recent" / f"{chunk_start}_{chunk_end}.html")
        # One server-rendered table contains all contracts/dates for the requested range.
        for table in html_tables(text):
            if not table:
                continue
            header = [re.sub(r"\s+", "", value) for value in table[0]]
            if not {"日期", "合约", "开盘价", "最高价", "最低价", "收盘价"}.issubset(set(header)):
                continue
            index = {name: header.index(name) for name in ["日期", "合约", "开盘价", "最高价", "最低价", "收盘价"]}
            volume_index = header.index("成交量（kg）") if "成交量（kg）" in header else None
            for raw in table[1:]:
                if len(raw) <= max(index.values()) or raw[index["合约"]].replace(" ", "").casefold() != contract.casefold():
                    continue
                close = finite_number(raw[index["收盘价"]])
                if close is None:
                    continue
                rows.append(DailyRow(
                    day=iso_day(raw[index["日期"]]), close=close,
                    open=finite_number(raw[index["开盘价"]]), high=finite_number(raw[index["最高价"]]),
                    low=finite_number(raw[index["最低价"]]),
                    volume=finite_number(raw[volume_index]) if volume_index is not None and volume_index < len(raw) else None,
                ))
    return rows


def sge_archive_links(start: str, end: str, cache_dir: Path, workers: int) -> list[tuple[str, str]]:
    start_day, end_day = date.fromisoformat(start), min(date.fromisoformat(end), date(2023, 12, 31))
    if start_day > end_day:
        return []

    def parse_links(text: str) -> list[tuple[str, str]]:
        parser = ArchiveListParser()
        parser.feed(text)
        return parser.links

    def page(page_number: int) -> list[tuple[str, str]]:
        url = f"https://www.sge.com.cn/sjzx/mrhqsj?p={page_number}"
        text = cache_text(url, cache_dir / "archive-index" / f"page-{page_number:03d}.html")
        return parse_links(text)

    first_url = "https://www.sge.com.cn/sjzx/mrhqsj?p=1"
    first_text = cache_text(first_url, cache_dir / "archive-index" / "page-001.html")
    total_match = re.search(r"var\s+totalPage\s*=\s*(\d+)\s*;", first_text)
    if not total_match:
        raise RuntimeError("Unable to determine SGE archive page count from official index")
    total_pages = int(total_match.group(1))
    if total_pages < 1 or total_pages > 1000:
        raise RuntimeError(f"Unexpected SGE archive page count: {total_pages}")

    # Fetching index pages is resumable and does not parse price values; exact detail pages are
    # filtered by date before they are opened.
    all_links: list[tuple[str, str]] = list(parse_links(first_text))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = [pool.submit(page, page_number) for page_number in range(2, total_pages + 1)]
        for future in concurrent.futures.as_completed(futures):
            all_links.extend(future.result())
    unique = {(href, day) for href, day in all_links if start <= day <= end}
    return sorted(unique, key=lambda item: item[1])


def fetch_sge_archive(contract: str, start: str, end: str, cache_dir: Path, workers: int) -> list[DailyRow]:
    links = sge_archive_links(start, end, cache_dir, workers)

    def detail(item: tuple[str, str]) -> DailyRow | None:
        href, day = item
        article_id = href.rsplit("/", 1)[-1]
        url = f"https://www.sge.com.cn{href}"
        text = cache_text(url, cache_dir / "archive-detail" / f"{day}-{article_id}.html")
        return sge_contract_row_from_archive_html(text, contract, day)

    rows: list[DailyRow] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = [pool.submit(detail, item) for item in links]
        for future in concurrent.futures.as_completed(futures):
            row = future.result()
            if row is not None:
                rows.append(row)
    return rows


def fetch_sge(series_id: str, start: str, end: str, cache_dir: Path, workers: int) -> tuple[list[DailyRow], dict[str, Any]]:
    archive_rows = fetch_sge_archive(series_id, start, end, cache_dir, workers) if start <= "2023-12-31" else []
    recent_rows = fetch_sge_recent(series_id, start, end, cache_dir) if end >= "2024-01-01" else []
    rows = validate_rows([*archive_rows, *recent_rows], start, end, f"SGE:{series_id}")
    return rows, {
        "transport": "sge_official_daily_html_archive_and_current",
        "archive_index": "https://www.sge.com.cn/sjzx/mrhqsj?p=<page>",
        "current_query": "https://www.sge.com.cn/sjzx/quotation_daily_new?start_date=<start>&end_date=<end>",
        "cache_dir": cache_dir.as_posix(),
    }


def verify_formal_authorization(manifest_path: Path, receipt_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    validate_manifest(manifest, manifest_path, {"FROZEN_UNOPENED"})
    if receipt.get("protocol_id") != "ATM-SVP-2" or receipt.get("holdout_id") != manifest.get("holdout_id"):
        raise SystemExit("Holdout authorization identity mismatch")
    if receipt.get("frozen_manifest_path") != manifest_path.as_posix():
        raise SystemExit("Holdout authorization path mismatch")
    if receipt.get("frozen_manifest_sha256") != sha256(manifest_path):
        raise SystemExit("Holdout authorization SHA mismatch")
    return manifest, receipt


def fetch_slot(
    slot: dict[str, Any], output_dir: Path, workers: int,
    requested_start: str | None = None, requested_end: str | None = None,
) -> Path:
    source = str(slot["alternate_source"])
    source_series_id = str(slot["source_series_id"])
    raw_symbol = str(slot["alternate_symbol"])
    start = requested_start or str(slot["metadata_coverage_start"])
    end = requested_end or str(slot["metadata_coverage_end"])
    if start < str(slot["metadata_coverage_start"]) or end > str(slot["metadata_coverage_end"]):
        raise SystemExit(f"Requested fetch range escapes frozen metadata coverage for role={slot['role']}")
    if source not in SUPPORTED_SOURCES:
        raise SystemExit(f"Unsupported frozen source={source} for role={slot['role']}")
    if source == "FRED_NASDAQ":
        rows, provenance = fetch_fred(source_series_id, start, end)
    elif source in {"YAHOO_FTSE_RUSSELL", "YAHOO_SSE"}:
        rows, provenance = fetch_yahoo(source_series_id, start, end)
    elif source == "CSINDEX":
        rows, provenance = fetch_csindex(source_series_id, start, end)
    elif source == "SGE":
        rows, provenance = fetch_sge(source_series_id, start, end, output_dir / "_cache" / "sge", workers)
    else:
        raise AssertionError(source)
    document = public_history_document(
        raw_symbol=raw_symbol,
        source_series_id=source_series_id,
        source=source,
        currency=str(slot["source_currency"]),
        unit=str(slot["source_unit"]),
        category="gold" if slot["role"] == "gold_safe_haven" else "index",
        label=f"ATM-SVP G4 raw {slot['role']}",
        rows=rows,
        provenance={
            **provenance,
            "role": slot["role"],
            "requested_start": start,
            "requested_end": end,
        },
    )
    path = output_dir / f"{slot['role']}.json"
    atomic_write(path, (json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
    print(
        f"G4_RAW_FETCHED role={slot['role']} source={source} source_series_id={source_series_id} "
        f"rows={len(rows)} start={rows[0].day} end={rows[-1].day} output={path} sha256={sha256(path)}"
    )
    return path


def development_slot(args: argparse.Namespace) -> dict[str, Any]:
    required = [args.source, args.series_id, args.raw_symbol, args.start, args.end, args.currency, args.unit, args.role]
    if any(value is None for value in required):
        raise SystemExit("development requires --source --series-id --raw-symbol --start --end --currency --unit --role")
    if args.raw_symbol.startswith("g4_raw_") is False:
        raise SystemExit("development --raw-symbol must use g4_raw_* namespace")
    if args.series_id not in DEVELOPMENT_ALLOWLIST.get(args.source, set()):
        raise SystemExit(
            f"development fetch refused for unapproved series {args.source}:{args.series_id}; "
            "new/unexposed series require the formal holdout burn/authorization path"
        )
    return {
        "role": args.role,
        "alternate_source": args.source,
        "source_series_id": args.series_id,
        "alternate_symbol": args.raw_symbol,
        "source_currency": args.currency,
        "source_unit": args.unit,
        "metadata_coverage_start": args.start,
        "metadata_coverage_end": args.end,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    dev = sub.add_parser("development")
    dev.add_argument("--source", choices=sorted(SUPPORTED_SOURCES), required=True)
    dev.add_argument("--series-id", required=True)
    dev.add_argument("--raw-symbol", required=True)
    dev.add_argument("--start", required=True)
    dev.add_argument("--end", required=True)
    dev.add_argument("--currency", required=True)
    dev.add_argument("--unit", required=True)
    dev.add_argument("--role", required=True)
    dev.add_argument("--output-dir", required=True)
    dev.add_argument("--workers", type=int, default=12)

    formal = sub.add_parser("formal")
    formal.add_argument("--manifest", required=True)
    formal.add_argument("--holdout-authorization", required=True)
    formal.add_argument("--output-dir", required=True)
    formal.add_argument("--workers", type=int, default=16)

    args = parser.parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.mode == "development":
        slot = development_slot(args)
        fetch_slot(slot, output_dir, args.workers)
        return

    manifest_path = Path(args.manifest)
    receipt_path = Path(args.holdout_authorization)
    manifest, receipt = verify_formal_authorization(manifest_path, receipt_path)
    print(
        f"G4_FORMAL_FETCH_AUTHORIZED holdout_id={manifest['holdout_id']} "
        f"authorization_git_commit={receipt.get('authorization_git_commit')}"
    )
    evaluation = manifest["evaluation_window"]
    common_start = str(evaluation["start"])
    common_end = str(evaluation["end"])
    paths: list[str] = []
    for slot in manifest["role_slots"]:
        paths.append(
            fetch_slot(
                slot, output_dir, args.workers,
                requested_start=common_start, requested_end=common_end,
            ).as_posix()
        )
    summary = {
        "protocol_id": "ATM-SVP-2",
        "holdout_id": manifest["holdout_id"],
        "manifest_sha256": sha256(manifest_path),
        "authorization_receipt": receipt_path.as_posix(),
        "raw_fixture_files": paths,
    }
    summary_path = output_dir / "fetch-summary.json"
    atomic_write(summary_path, (json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    print(f"G4_FORMAL_FETCH_COMPLETE summary={summary_path} sha256={sha256(summary_path)}")


if __name__ == "__main__":
    main()
