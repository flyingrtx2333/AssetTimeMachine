#!/usr/bin/env python3
"""014b: E02 with real daily OHLC stop execution.

This tests whether close-only stops are the bottleneck. Entries still use the
same E02 close signal and T execution口径; only campaign stops can execute inside
the day using real daily open/high/low from Sina where available.

Visible holdings: nasdaq, gold_cny, cash.
OHLC sources:
- Nasdaq Composite daily OHLC from Sina .IXIC, 2004+
- COMEX GC daily OHLC ratio from Sina, 2016+ (applied to existing gold_cny close)
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec = importlib.util.spec_from_file_location('E11', ROOT / 'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py')
if spec is None or spec.loader is None:
    raise RuntimeError('Cannot load E11')
E = importlib.util.module_from_spec(spec)
sys.modules['E11'] = E
spec.loader.exec_module(E)  # type: ignore
Z = E.Z
CORE = E.CORE

OUT = Path('/tmp/atm_e02_ohlc_stop_014.json')
HOLDINGS = ['nasdaq', 'gold_cny']
START = 100_000.0
FEE = Z.FEE
SLIP = Z.SLIP
pct = Z.pct
metrics = Z.metrics
all_metrics = Z.all_metrics
topdds = Z.topdds
mom = Z.mom
above = Z.above


def count(ctx: Dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def fetch_jsonp(url: str):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0', 'Referer': 'https://finance.sina.com.cn/'})
    txt = urllib.request.urlopen(req, timeout=90).read().decode('utf-8', 'ignore')
    m = re.search(r'=\((.*)\);?\s*$', txt, re.S)
    if not m:
        raise RuntimeError(f'Cannot parse JSONP: {url} head={txt[:120]!r}')
    return json.loads(m.group(1))


def fetch_ohlc_ratios() -> Dict[str, Dict[dt.date, Dict[str, float]]]:
    sources = {
        'nasdaq': ('https://stock.finance.sina.com.cn/usstock/api/jsonp.php/var%20t=/US_MinKService.getDailyK?symbol=.IXIC', 'd', ('o', 'h', 'l', 'c')),
        'gold_cny': ('https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/GlobalFuturesService.getGlobalFuturesDailyKLine?symbol=GC', 'date', ('open', 'high', 'low', 'close')),
    }
    out: Dict[str, Dict[dt.date, Dict[str, float]]] = {}
    for sym, (url, date_key, keys) in sources.items():
        rows = fetch_jsonp(url)
        dct: Dict[dt.date, Dict[str, float]] = {}
        ok = 0
        for r in rows:
            try:
                d = dt.date.fromisoformat(r[date_key])
                o = float(r[keys[0]]); h = float(r[keys[1]]); l = float(r[keys[2]]); c = float(r[keys[3]])
                if c > 0 and o > 0 and h > 0 and l > 0:
                    dct[d] = {'open_ratio': o / c, 'high_ratio': h / c, 'low_ratio': l / c}
                    ok += 1
            except Exception:
                continue
        out[sym] = dct
        print('OHLC', sym, 'rows', ok, 'range', min(dct) if dct else None, max(dct) if dct else None)
    return out


def ohlc_price(ohlc, dates, p, s: str, i: int, field: str) -> float | None:
    r = ohlc.get(s, {}).get(dates[i])
    if not r:
        return None
    return p[s][i] * r[field]


def stop_levels(st: Dict[str, Any], p, s: str, i: int, variant: str) -> list[tuple[str, float]]:
    entry = st.get(f'{s}_entry')
    high = st.get(f'{s}_high')
    if entry is None or high is None or entry <= 0 or high <= 0:
        return []
    if variant == 'tight':
        fixed = {'nasdaq': 0.085, 'gold_cny': 0.070}[s]
        trail = {'nasdaq': 0.115, 'gold_cny': 0.095}[s]
        take = {'nasdaq': 0.24, 'gold_cny': 0.19}[s]
    elif variant == 'medium':
        fixed = {'nasdaq': 0.100, 'gold_cny': 0.080}[s]
        trail = {'nasdaq': 0.135, 'gold_cny': 0.110}[s]
        take = {'nasdaq': 0.30, 'gold_cny': 0.22}[s]
    else:  # loose, mirrors E02 loose sleeve_stop_flags roughly
        fixed = {'nasdaq': 0.115, 'gold_cny': 0.090}[s]
        trail = {'nasdaq': 0.155, 'gold_cny': 0.120}[s]
        take = {'nasdaq': 0.36, 'gold_cny': 0.26}[s]
    levels = [(f'intraday_fixed_{fixed:.3f}', entry * (1 - fixed))]
    if high >= entry * (1 + take * 0.45):
        levels.append((f'intraday_trail_{trail:.3f}', high * (1 - trail)))
    return levels


def apply_intraday_stops(dates, p, ohlc, i: int, cash: float, units: Dict[str, float], ctx: Dict[str, Any], variant: str, symbols: set[str]):
    st = ctx.setdefault('state', {})
    did = False
    for s in HOLDINGS:
        if s not in symbols or units.get(s, 0.0) <= 0:
            continue
        low = ohlc_price(ohlc, dates, p, s, i, 'low_ratio')
        opn = ohlc_price(ohlc, dates, p, s, i, 'open_ratio')
        if low is None or opn is None:
            continue
        levels = stop_levels(st, p, s, i - 1 if i > 0 else i, variant)
        if not levels:
            continue
        # Use the highest active stop. If opened below stop, exit at open; otherwise at stop.
        reason, stop = max(levels, key=lambda x: x[1])
        if low <= stop:
            px = opn if opn < stop else stop
            cash += units[s] * px * (1 - SLIP) * (1 - FEE)
            units[s] = 0.0
            st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), 35 if s == 'nasdaq' else 25)
            st[f'{s}_entry'] = None
            st[f'{s}_high'] = None
            count(ctx, f'{s}_{reason}')
            did = True
    return cash, units, did


def simulate_ohlc(dates, p, ohlc, target_fn: Callable, variant: str = 'loose', stop_symbols: set[str] | None = None, rebalance: int = 1, band: float = 0.015, warmup: int = 252):
    if stop_symbols is None:
        stop_symbols = set(HOLDINGS)
    cash = START
    units = {s: 0.0 for s in HOLDINGS}
    vals = []
    weights = []
    trades = 0
    ctx: Dict[str, Any] = {'peak': START, 'state': {}, 'last_target': {}, 'event_counts': {}}
    for i, d in enumerate(dates):
        if i > 0 and cash > 0:
            cash += cash * CORE.cash_daily(dates[i - 1])

        # Intraday stop before close-based signal execution.
        if i > warmup:
            cash, units, stopped = apply_intraday_stops(dates, p, ohlc, i, cash, units, ctx, variant, stop_symbols)
            if stopped:
                trades += 1

        val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        ctx['peak'] = max(ctx.get('peak', val), val)
        if i > warmup and i % rebalance == 0:
            sig_i = i - 1
            sig_val = cash + sum(units[s] * p[s][sig_i] for s in HOLDINGS)
            sig_w = {s: (units[s] * p[s][sig_i] / sig_val if sig_val > 0 else 0.0) for s in HOLDINGS}
            ctx['sig_w'] = sig_w
            ctx['portfolio_dd'] = 1 - val / ctx['peak'] if ctx['peak'] else 0
            target = target_fn(dates, p, sig_i, ctx)
            if target is not None:
                target = Z.normalize(target, 0.98)
                E.update_campaign_state_after_target(p, sig_i, ctx['state'], sig_w, target)
                cash, units, did = E.trade_to(cash, units, p, i, target, band=band)
                if did:
                    trades += 1
                ctx['last_target'] = target
                val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s: units[s] * p[s][i] / val for s in HOLDINGS if val > 0 and units[s] * p[s][i] / val > 1e-4})
    return vals, weights, {'trades': trades, 'latest': weights[-1], 'cash_pct': max(0.0, 1 - sum(weights[-1].values())), 'events': ctx.get('event_counts', {})}


def allm_ext(dates, vals):
    m = all_metrics(dates, vals)
    m['post2022'] = metrics(dates, vals, dt.date(2022, 1, 1), None)
    return m


def row(dates, p, ohlc, name: str, desc: str, target_fn: Callable, variant: str | None, symbols: set[str] | None):
    if variant is None:
        vals, w, e = E.simulate_event(dates, p, target_fn, rebalance=1, band=0.015, warmup=252)
    else:
        vals, w, e = simulate_ohlc(dates, p, ohlc, target_fn, variant=variant, stop_symbols=symbols or set(HOLDINGS))
    bad = [s for ww in w for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    m = allm_ext(dates, vals)
    return {
        'name': name,
        'description': desc,
        'metrics': m,
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in Z.STRESS.items()},
        'extra': e,
        'top_dd': topdds(dates, vals, w),
        'frontier': m['full']['ann'] >= 0.078 and m['full']['dd'] < 0.1138,
        'lowdd': m['full']['ann'] >= 0.075 and m['full']['dd'] <= 0.105,
    }


def main():
    dates, p = CORE.align(CORE.fetch())
    ohlc = fetch_ohlc_ratios()
    base = E.E02_breakout_chandelier('loose')
    strategies = [
        ('REF_E02_close_only', 'original close-only E02 loose reference', base, None, None),
        ('OHL1_nasdaq_intraday_loose', 'E02 + real Nasdaq OHLC loose fixed/trailing stop', base, 'loose', {'nasdaq'}),
        ('OHL2_nasdaq_intraday_medium', 'E02 + real Nasdaq OHLC medium fixed/trailing stop', base, 'medium', {'nasdaq'}),
        ('OHL3_nasdaq_intraday_tight', 'E02 + real Nasdaq OHLC tight fixed/trailing stop', base, 'tight', {'nasdaq'}),
        ('OHL4_nasdaq_gold_intraday_loose', 'E02 + real Nasdaq OHLC plus GC-ratio gold OHLC loose stops', base, 'loose', {'nasdaq', 'gold_cny'}),
        ('OHL5_nasdaq_gold_intraday_medium', 'E02 + real Nasdaq OHLC plus GC-ratio gold OHLC medium stops', base, 'medium', {'nasdaq', 'gold_cny'}),
    ]
    rows = [row(dates, p, ohlc, *s) for s in strategies]
    OUT.write_text(json.dumps({
        'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates), 'holdings': HOLDINGS + ['cash'], 'ohlc_note': 'Nasdaq 2004+, GC 2016+ ratio applied to existing CNY close'},
        'rows': rows,
    }, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates))
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']; p20 = r['metrics']['post2020']; ten = r['metrics']['teny']; p22 = r['metrics']['post2022']
        mark = 'LOWDD' if r['lowdd'] else ('FRONTIER' if r['frontier'] else 'FAIL')
        latest = {k: round(v * 100, 1) for k, v in r['extra'].get('latest', {}).items()}
        print(f"{mark:8s} {r['name']:34s} full {pct(m['ann'])}/{pct(m['dd'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"          post20 {pct(p20['ann'])}/{pct(p20['dd'])} tenY {pct(ten['ann'])}/{pct(ten['dd'])} post22 {pct(p22['ann'])}/{pct(p22['dd'])}")
        print(f"          latest={latest} cash={pct(r['extra'].get('cash_pct', 0))} trades={r['extra'].get('trades')} events={r['extra'].get('events', {})}")
        print('          topdd ' + ' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))


if __name__ == '__main__':
    main()
