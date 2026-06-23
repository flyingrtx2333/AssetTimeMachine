#!/usr/bin/env python3
"""014c: aggressive 25N/35G barbell with real daily OHLC tail stops.

Hypothesis: E02 may be too low-exposure to improve; start from the stronger
25N/35G drift-harvest-rebuild engine (~9.98/19.95) and use real OHLC stops to
cut tail risk while preserving the return source.

Visible holdings: nasdaq, gold_cny, cash. S&P/GC OHLC are signal/execution aids
only; no extra held assets, no BTC, no parameter grid.
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

spec_b = importlib.util.spec_from_file_location('B007', ROOT / 'spikes/007-gold-nasdaq-cash-only/barbell_drift_policies.py')
B = importlib.util.module_from_spec(spec_b); sys.modules['B007'] = B; spec_b.loader.exec_module(B)  # type: ignore
CORE = B.CORE

spec_e = importlib.util.spec_from_file_location('E11', ROOT / 'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py')
E = importlib.util.module_from_spec(spec_e); sys.modules['E11'] = E; spec_e.loader.exec_module(E)  # type: ignore
Z = E.Z

OUT = Path('/tmp/atm_barbell_ohlc_tail_014.json')
HOLDINGS = ['nasdaq', 'gold_cny']
START = 100_000.0
FEE = B.FEE
SLIP = B.SLIP
BASE = {'nasdaq': 0.25, 'gold_cny': 0.35}

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
        raise RuntimeError(f'Cannot parse JSONP {url} head={txt[:120]!r}')
    return json.loads(m.group(1))


def fetch_ohlc_ratios():
    sources = {
        'nasdaq': ('https://stock.finance.sina.com.cn/usstock/api/jsonp.php/var%20t=/US_MinKService.getDailyK?symbol=.IXIC', 'd', ('o', 'h', 'l', 'c')),
        'gold_cny': ('https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/GlobalFuturesService.getGlobalFuturesDailyKLine?symbol=GC', 'date', ('open', 'high', 'low', 'close')),
    }
    out = {}
    for sym, (url, dk, ks) in sources.items():
        rows = fetch_jsonp(url)
        dct = {}
        for r in rows:
            try:
                d = dt.date.fromisoformat(r[dk])
                o, h, l, c = [float(r[k]) for k in ks]
                if min(o, h, l, c) > 0:
                    dct[d] = {'open_ratio': o / c, 'high_ratio': h / c, 'low_ratio': l / c}
            except Exception:
                pass
        print('OHLC', sym, len(dct), min(dct) if dct else None, max(dct) if dct else None)
        out[sym] = dct
    return out


def trade_to(cash, units, p, i, target, band=0.012):
    total = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
    did = False
    for s in HOLDINGS:
        cur = units[s] * p[s][i]; tgt = total * target.get(s, 0.0)
        if cur > tgt * (1 + band):
            su = min(units[s], (cur - tgt) / p[s][i])
            if su > 0:
                cash += su * p[s][i] * (1 - SLIP) * (1 - FEE)
                units[s] -= su
                did = True
    total = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
    for s in HOLDINGS:
        cur = units[s] * p[s][i]; tgt = total * target.get(s, 0.0)
        if cur < tgt * (1 - band):
            amt = min(cash, tgt - cur)
            if amt > 1:
                units[s] += amt * (1 - FEE) / (p[s][i] * (1 + SLIP))
                cash -= amt
                did = True
    return cash, units, did


def price_field(ohlc, dates, p, s, i, field):
    r = ohlc.get(s, {}).get(dates[i])
    return None if not r else p[s][i] * r[field]


def stop_params(style: str, s: str):
    # fixed, trailing, profit activation, cooldown
    if style == 'loose':
        return {'nasdaq': (0.17, 0.20, 0.24, 21), 'gold_cny': (0.14, 0.17, 0.20, 18)}[s]
    if style == 'medium':
        return {'nasdaq': (0.14, 0.17, 0.20, 28), 'gold_cny': (0.115, 0.145, 0.17, 21)}[s]
    if style == 'tight':
        return {'nasdaq': (0.11, 0.14, 0.16, 35), 'gold_cny': (0.095, 0.125, 0.14, 28)}[s]
    raise ValueError(style)


def apply_intraday_tail(dates, p, ohlc, i, cash, units, ctx, style: str, stop_symbols: set[str], stop_mode: str = 'exit'):
    st = ctx.setdefault('state', {})
    did = False
    total_before = cash + sum(units[x] * p[x][i] for x in HOLDINGS)
    for s in HOLDINGS:
        if s not in stop_symbols or units.get(s, 0) <= 0:
            continue
        low = price_field(ohlc, dates, p, s, i, 'low_ratio')
        opn = price_field(ohlc, dates, p, s, i, 'open_ratio')
        if low is None or opn is None:
            continue
        entry = st.get(f'{s}_entry')
        high = st.get(f'{s}_high')
        if not entry or not high:
            continue
        fixed, trail, activation, cool = stop_params(style, s)
        levels = [(f'{s}_ohlc_fixed_{fixed:.3f}', entry * (1 - fixed))]
        if high >= entry * (1 + activation):
            levels.append((f'{s}_ohlc_trail_{trail:.3f}', high * (1 - trail)))
        reason, stop = max(levels, key=lambda x: x[1])
        if low <= stop:
            px = opn if opn < stop else stop
            if stop_mode == 'base':
                keep_weight = BASE.get(s, 0.0)
                keep_value = total_before * keep_weight
                keep_units = min(units[s], keep_value / max(px, 1e-9))
                sell_units = max(0.0, units[s] - keep_units)
            elif stop_mode == 'half':
                sell_units = units[s] * 0.50
            else:
                sell_units = units[s]
            if sell_units > 0:
                cash += sell_units * px * (1 - SLIP) * (1 - FEE)
                units[s] -= sell_units
                if units[s] <= 1e-9:
                    units[s] = 0.0
                    st[f'{s}_entry'] = None
                    st[f'{s}_high'] = None
                    st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), cool)
                else:
                    # Preserve the campaign but reset high to avoid repeated same high stop whipsaw.
                    st[f'{s}_high'] = max(px, p[s][i])
                    st[f'{s}_entry'] = min(st.get(f'{s}_entry') or px, px)
                    st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), max(5, cool // 3))
                count(ctx, f'{reason}_{stop_mode}')
                did = True
    return cash, units, did


def update_state_after_close(dates, p, ohlc, i, units, ctx):
    st = ctx.setdefault('state', {})
    for s in HOLDINGS:
        if units.get(s, 0) > 0:
            if st.get(f'{s}_entry') is None:
                st[f'{s}_entry'] = p[s][i]
                st[f'{s}_high'] = p[s][i]
                count(ctx, f'{s}_position_open')
            h = price_field(ohlc, dates, p, s, i, 'high_ratio') or p[s][i]
            st[f'{s}_high'] = max(st.get(f'{s}_high') or h, h)
        else:
            st[f'{s}_entry'] = None
            st[f'{s}_high'] = None


def gold_trap_cap_policy(dates, p, i, w, pdd):
    pol = B.make_blowoff_rebuild(BASE)
    tgt = pol(dates, p, i, w, pdd)
    out = dict(w if tgt is None else tgt)
    changed = tgt is not None
    gold_trap = ((mom(p['gold_cny'], i, 252) or 0) > 0.28 and (mom(p['gold_cny'], i, 21) or 0) < -0.030) or ((mom(p['gold_cny'], i, 10) or 0) < -0.035 and (mom(p['sp500'], i, 10) or 0) < -0.040)
    if gold_trap and out.get('gold_cny', 0) > 0.24:
        out['gold_cny'] = 0.24
        changed = True
    return out if changed else None


def rare_market_shock(p, i):
    if i < 63: return False
    return (mom(p['sp500'], i, 5) or 0) < -0.085 or (mom(p['sp500'], i, 10) or 0) < -0.120 or ((mom(p['nasdaq'], i, 5) or 0) < -0.120)


def shock_goldtrap_policy(dates, p, i, w, pdd):
    tgt = gold_trap_cap_policy(dates, p, i, w, pdd)
    out = dict(w if tgt is None else tgt)
    changed = tgt is not None
    if rare_market_shock(p, i):
        out['nasdaq'] = min(out.get('nasdaq', 0), 0.20)
        out['gold_cny'] = min(out.get('gold_cny', 0), 0.26)
        changed = True
    return out if changed else None


def simulate(dates, p, ohlc, policy, init=BASE, style: str | None = None, stop_symbols: set[str] | None = None, rebalance_days=20, stop_mode: str = 'exit'):
    if stop_symbols is None:
        stop_symbols = set(HOLDINGS)
    cash = START
    units = {s: 0.0 for s in HOLDINGS}
    trades = 0
    ctx: Dict[str, Any] = {'state': {}, 'event_counts': {}}
    cash, units, did = trade_to(cash, units, p, 0, init, band=0.0)
    trades += 1 if did else 0
    vals = []
    weights = []
    peak = START
    for i, d in enumerate(dates):
        if i > 0 and cash > 0:
            cash += cash * CORE.cash_daily(dates[i-1])
        # daily cooldown decay
        st = ctx.setdefault('state', {})
        for s in HOLDINGS:
            st[f'{s}_cool'] = max(0, st.get(f'{s}_cool', 0) - 1)
        if style and i > 0:
            cash, units, did = apply_intraday_tail(dates, p, ohlc, i, cash, units, ctx, style, stop_symbols, stop_mode=stop_mode)
            trades += 1 if did else 0
        val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        peak = max(peak, val)
        if i > 0 and i % rebalance_days == 0:
            sig_i = i - 1
            sig_val = cash + sum(units[s] * p[s][sig_i] for s in HOLDINGS)
            w = {s: units[s] * p[s][sig_i] / sig_val if sig_val > 0 else 0 for s in HOLDINGS}
            target = policy(dates, p, sig_i, w, 1 - val / peak)
            if target is not None:
                # Apply cooldown after OHLC exits: no immediate same-sleeve rebuy.
                target = dict(target)
                for s in HOLDINGS:
                    if st.get(f'{s}_cool', 0) > 0:
                        target[s] = min(target.get(s, 0.0), 0.0)
                target = Z.normalize(target, 0.90)
                cash, units, did = trade_to(cash, units, p, i, target)
                trades += 1 if did else 0
                val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        update_state_after_close(dates, p, ohlc, i, units, ctx)
        val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s: units[s] * p[s][i] / val for s in HOLDINGS if val > 0 and units[s] * p[s][i] / val > 1e-4})
    return vals, weights, {'trades': trades, 'latest': weights[-1], 'cash_pct': max(0, 1 - sum(weights[-1].values())), 'events': ctx.get('event_counts', {})}


def allm_ext(dates, vals):
    m = all_metrics(dates, vals)
    m['post2022'] = metrics(dates, vals, dt.date(2022, 1, 1), None)
    return m


def row(dates, p, ohlc, name, desc, policy, style=None, symbols=None, stop_mode='exit'):
    if style is None:
        vals, w, e = B.simulate_policy(dates, p, name, policy, init=BASE)
    else:
        vals, w, e = simulate(dates, p, ohlc, policy, init=BASE, style=style, stop_symbols=symbols or set(HOLDINGS), stop_mode=stop_mode)
    m = allm_ext(dates, vals)
    return {
        'name': name,
        'description': desc,
        'metrics': m,
        'extra': e,
        'top_dd': topdds(dates, vals, w),
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in Z.STRESS.items()},
        'strong_lowdd': m['full']['ann'] >= 0.085 and m['full']['dd'] <= 0.12,
        'candidate': m['full']['ann'] >= 0.09 and m['full']['dd'] <= 0.16,
    }


def main():
    dates, p = CORE.align(CORE.fetch())
    ohlc = fetch_ohlc_ratios()
    base_policy = B.make_blowoff_rebuild(BASE)
    strategies = [
        ('REF_25N35G_blowoff_rebuild', '007 reference high-return drift/harvest/rebuild', base_policy, None, None),
        ('B01_goldtrap_cap_close', '007 reference plus close-signal gold trap cap', gold_trap_cap_policy, None, None),
        ('B02_shock_goldtrap_close', 'B01 plus rare market shock cap', shock_goldtrap_policy, None, None),
        ('B03_nasdaq_ohlc_loose', '25N/35G + Nasdaq OHLC loose tail stop', gold_trap_cap_policy, 'loose', {'nasdaq'}),
        ('B04_nasdaq_ohlc_medium', '25N/35G + Nasdaq OHLC medium tail stop', gold_trap_cap_policy, 'medium', {'nasdaq'}),
        ('B05_both_ohlc_loose', '25N/35G + Nasdaq/GC OHLC loose tail stop', gold_trap_cap_policy, 'loose', {'nasdaq', 'gold_cny'}),
        ('B06_both_ohlc_medium', '25N/35G + Nasdaq/GC OHLC medium tail stop', gold_trap_cap_policy, 'medium', {'nasdaq', 'gold_cny'}),
        ('B07_shock_plus_nasdaq_ohlc', 'shock/goldtrap close cap + Nasdaq OHLC medium', shock_goldtrap_policy, 'medium', {'nasdaq'}),
        ('B08_shock_plus_both_ohlc', 'shock/goldtrap close cap + both OHLC medium', shock_goldtrap_policy, 'medium', {'nasdaq', 'gold_cny'}),
        ('B09_nasdaq_ohlc_excess_to_base', 'Nasdaq OHLC stop sells only excess above base sleeve', gold_trap_cap_policy, 'medium', {'nasdaq'}, 'base'),
        ('B10_both_ohlc_excess_to_base', 'Nasdaq/GC OHLC stops sell only excess above base sleeves', gold_trap_cap_policy, 'medium', {'nasdaq', 'gold_cny'}, 'base'),
        ('B11_nasdaq_ohlc_half_harvest', 'Nasdaq OHLC stop harvests half, preserving campaign', gold_trap_cap_policy, 'medium', {'nasdaq'}, 'half'),
        ('B12_shock_nasdaq_excess_to_base', 'Shock/goldtrap cap plus Nasdaq excess-only OHLC stop', shock_goldtrap_policy, 'medium', {'nasdaq'}, 'base'),
    ]
    rows = [row(dates, p, ohlc, *s) for s in strategies]
    OUT.write_text(json.dumps({'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates)}, 'rows': rows}, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates))
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']; p20 = r['metrics']['post2020']; ten = r['metrics']['teny']; p22 = r['metrics']['post2022']
        mark = 'STRONG' if r['strong_lowdd'] else ('CAND' if r['candidate'] else 'FAIL')
        latest = {k: round(v*100, 1) for k, v in r['extra'].get('latest', {}).items()}
        print(f"{mark:6s} {r['name']:31s} full {pct(m['ann'])}/{pct(m['dd'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"        post20 {pct(p20['ann'])}/{pct(p20['dd'])} tenY {pct(ten['ann'])}/{pct(ten['dd'])} post22 {pct(p22['ann'])}/{pct(p22['dd'])}")
        print(f"        latest={latest} cash={pct(r['extra'].get('cash_pct', 0))} trades={r['extra'].get('trades')} events={r['extra'].get('events', {})}")
        print('        topdd ' + ' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))

if __name__ == '__main__':
    main()
