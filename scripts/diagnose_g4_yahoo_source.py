#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import requests


def chart_probe(symbol: str, host: str, start: str, end: str) -> dict:
    a = datetime.fromisoformat(start).replace(tzinfo=timezone.utc)
    b = datetime.fromisoformat(end).replace(tzinfo=timezone.utc)
    query = urllib.parse.urlencode({
        'period1': int(a.timestamp()), 'period2': int(b.timestamp()) + 86400,
        'interval': '1d', 'events': 'history', 'includeAdjustedClose': 'true',
    })
    url = f'https://{host}/v8/finance/chart/{urllib.parse.quote(symbol, safe="")}?{query}'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=20) as response:
        doc = json.load(response)
    chart = doc.get('chart') or {}
    result = (chart.get('result') or [{}])[0]
    meta = result.get('meta') or {}
    return {
        'url_family': host + '/v8/finance/chart',
        'http_error': chart.get('error'),
        'timestamp_count': len(result.get('timestamp') or []),
        'first_trade_date': meta.get('firstTradeDate'),
        'currency': meta.get('currency'),
        'exchange': meta.get('exchangeName'),
    }


def spark_probe(symbol: str) -> dict:
    url = 'https://query1.finance.yahoo.com/v7/finance/spark?' + urllib.parse.urlencode({'symbols': symbol, 'range': 'max', 'interval': '1d'})
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=20) as response:
        doc = json.load(response)
    spark = doc.get('spark') or {}
    row = (spark.get('result') or [{}])[0]
    response = (row.get('response') or [{}])[0]
    quote = ((response.get('indicators') or {}).get('quote') or [{}])[0]
    return {
        'url_family': 'query1.finance.yahoo.com/v7/finance/spark',
        'error': spark.get('error'),
        'timestamp_count': len(response.get('timestamp') or []),
        'close_count': len(quote.get('close') or []),
    }


def history_page_probe(symbol: str) -> dict:
    url = f'https://finance.yahoo.com/quote/{symbol}/history/'
    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
            return {'url': url, 'status': response.status, 'bytes': len(body)}
    except urllib.error.HTTPError as error:
        return {'url': url, 'status': error.code, 'bytes': 0}


def download_probe(symbol: str, start: str, end: str) -> dict:
    session = requests.Session()
    session.headers.update({'User-Agent': 'Mozilla/5.0'})
    try:
        session.get('https://fc.yahoo.com', timeout=20, allow_redirects=True)
    except requests.RequestException:
        pass
    crumb_response = session.get('https://query1.finance.yahoo.com/v1/test/getcrumb', timeout=20)
    crumb = crumb_response.text.strip() if crumb_response.ok else ''
    a = datetime.fromisoformat(start).replace(tzinfo=timezone.utc)
    b = datetime.fromisoformat(end).replace(tzinfo=timezone.utc)
    response = session.get(
        f'https://query1.finance.yahoo.com/v7/finance/download/{symbol}',
        params={
            'period1': int(a.timestamp()), 'period2': int(b.timestamp()) + 86400,
            'interval': '1d', 'events': 'history', 'includeAdjustedClose': 'true', 'crumb': crumb,
        }, timeout=30,
    )
    return {
        'url_family': 'query1.finance.yahoo.com/v7/finance/download',
        'crumb_status': crumb_response.status_code,
        'download_status': response.status_code,
        'content_type': response.headers.get('content-type'),
        'response_prefix': response.text[:240],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--symbol', action='append', required=True)
    parser.add_argument('--start', required=True)
    parser.add_argument('--end', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    results = {}
    for symbol in args.symbol:
        results[symbol] = {
            'query1_chart': chart_probe(symbol, 'query1.finance.yahoo.com', args.start, args.end),
            'query2_chart': chart_probe(symbol, 'query2.finance.yahoo.com', args.start, args.end),
            'spark_max': spark_probe(symbol),
            'history_page': history_page_probe(symbol),
            'download': download_probe(symbol, args.start, args.end),
        }
    doc = {
        'diagnostic': 'ATM-SVP-2 G4 frozen Yahoo source history availability',
        'generated_at_epoch': int(time.time()),
        'start': args.start, 'end': args.end, 'symbols': results,
        'interpretation': 'No strategy metrics are computed. This artifact diagnoses whether the exact frozen Yahoo instruments expose reproducible historical daily data through Yahoo-owned interfaces.',
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')

if __name__ == '__main__':
    main()
