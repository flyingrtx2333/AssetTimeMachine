#!/usr/bin/env python3
"""013 v3: low-drawdown frontier overlays on E02.

Reference E02 is the best low-DD candidate from 011/012. This tests narrow,
mechanism-level overlays only: cap gold when gold itself is in blowoff/liquidity
trap, cap both sleeves only in rare liquidity shock, and staged rebuild.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any, Callable, Dict

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec = importlib.util.spec_from_file_location('E11', ROOT / 'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py')
E = importlib.util.module_from_spec(spec)
sys.modules['E11'] = E
spec.loader.exec_module(E)  # type: ignore
Z = E.Z
CORE = E.CORE
OUT = Path('/tmp/atm_portfolio_scheduler_signal_013_v3.json')

HOLDINGS = ['nasdaq', 'gold_cny']
TARGET_ANN = 0.12
TARGET_DD = 0.08
pct = Z.pct
ma = Z.ma
mom = Z.mom
above = Z.above
realized_vol = Z.realized_vol
dd_series = Z.dd_series
normalize = Z.normalize
metrics = Z.metrics
all_metrics = Z.all_metrics
topdds = Z.topdds


def count(ctx: Dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def rolling_low(v, i: int, n: int, exclude_current: bool = True):
    end = i if exclude_current else i + 1
    start = max(0, end - n)
    if end - start < 5:
        return None
    return min(v[start:end])


def gold_trap(p, i: int) -> bool:
    if i < 252:
        return False
    return ((mom(p['gold_cny'], i, 252) or 0) > 0.28 and (mom(p['gold_cny'], i, 21) or 0) < -0.030) or (
        (mom(p['gold_cny'], i, 10) or 0) < -0.035 and (mom(p['sp500'], i, 10) or 0) < -0.040
    )


def rare_shock(p, i: int) -> bool:
    if i < 63:
        return False
    sp5 = mom(p['sp500'], i, 5) or 0
    sp10 = mom(p['sp500'], i, 10) or 0
    sp21 = mom(p['sp500'], i, 21) or 0
    nq5 = mom(p['nasdaq'], i, 5) or 0
    spv10 = realized_vol(p['sp500'], i, 10) or 0
    spv63 = realized_vol(p['sp500'], i, 63) or 0.18
    return sp5 < -0.085 or sp10 < -0.120 or (sp21 < -0.170 and not above(p, 'sp500', i, 40)) or (nq5 < -0.120) or (spv10 > spv63 * 2.8 and sp10 < -0.070)


def recovery_stage(p, s: str, i: int) -> int:
    if i < 63:
        return 0
    l21 = rolling_low(p[s], i, 21, exclude_current=False)
    l63 = rolling_low(p[s], i, 63, exclude_current=False)
    r21 = p[s][i] / l21 - 1 if l21 else 0
    r63 = p[s][i] / l63 - 1 if l63 else 0
    m10 = mom(p[s], i, 10) or 0
    m21 = mom(p[s], i, 21) or 0
    if s == 'nasdaq':
        if m21 > 0.080 and above(p, s, i, 40):
            return 3
        if r63 > 0.090 or (m10 > 0.055 and above(p, s, i, 20)):
            return 2
        if r21 > 0.050:
            return 1
        return 0
    if gold_trap(p, i):
        return 0
    if m21 > 0.055 and above(p, s, i, 40):
        return 3
    if r63 > 0.060 or (m10 > 0.035 and above(p, s, i, 20)):
        return 2
    if r21 > 0.035:
        return 1
    return 0


def base_e02():
    return E.E02_breakout_chandelier('loose')


def L01_e02_gold_trap_cap():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        if gold_trap(p, i) and target.get('gold_cny', 0) > 0.18:
            target['gold_cny'] = 0.18
            count(ctx, 'gold_trap_cap')
        return normalize(target, 0.90)
    return fn


def L02_e02_gold_trap_exit():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        if gold_trap(p, i):
            target['gold_cny'] = 0.0
            count(ctx, 'gold_trap_exit')
        return normalize(target, 0.90)
    return fn


def L03_e02_rare_shock_cap():
    base = base_e02()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        target = base(dates, p, i, ctx) or {}
        if rare_shock(p, i):
            st['shock_cool'] = max(st.get('shock_cool', 0), 7)
            count(ctx, 'rare_shock')
        st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
        if st.get('shock_cool', 0) > 0:
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.16)
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.18 if gold_trap(p, i) else 0.26)
        return normalize(target, 0.46 if st.get('shock_cool', 0) > 0 else 0.90)
    return fn


def L04_e02_gold_trap_plus_shock_cap():
    base = base_e02()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        target = base(dates, p, i, ctx) or {}
        if gold_trap(p, i):
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.18)
            count(ctx, 'gold_trap_cap')
        if rare_shock(p, i):
            st['shock_cool'] = max(st.get('shock_cool', 0), 7)
            count(ctx, 'rare_shock')
        st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
        if st.get('shock_cool', 0) > 0:
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.16)
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.18)
            return normalize(target, 0.36)
        return normalize(target, 0.90)
    return fn


def L05_e02_shock_cap_fast_rebuild():
    base = base_e02()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        target = base(dates, p, i, ctx) or {}
        if rare_shock(p, i):
            st['shock_cool'] = max(st.get('shock_cool', 0), 10)
            count(ctx, 'rare_shock')
        st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
        if st.get('shock_cool', 0) > 0:
            target = {}
            ns = recovery_stage(p, 'nasdaq', i)
            gs = recovery_stage(p, 'gold_cny', i)
            if ns >= 2:
                target['nasdaq'] = 0.18 if ns == 2 else 0.30
            if gs >= 1:
                target['gold_cny'] = [0, 0.14, 0.24, 0.32][gs]
            return normalize(target, 0.48)
        return normalize(target, 0.90)
    return fn


def L06_e02_selective_gold_rebuild():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        # E02 sometimes waits too long after exiting. Rebuild gold only after recovery and only if not trap.
        if target.get('gold_cny', 0) < 0.03 and recovery_stage(p, 'gold_cny', i) >= 2 and not gold_trap(p, i):
            target['gold_cny'] = 0.24
            count(ctx, 'gold_rebuild')
        if gold_trap(p, i):
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.12)
            count(ctx, 'gold_trap_cap')
        return normalize(target, 0.88)
    return fn


def stale_trend(p, s: str, i: int) -> bool:
    if i < 200:
        return False
    if s == 'nasdaq':
        return (not above(p, s, i, 120) and (mom(p[s], i, 63) or 0) < -0.055) or (
            not above(p, s, i, 200) and (mom(p[s], i, 126) or 0) < -0.015
        )
    # Gold can chop around MA120; require either short damage or broader risk-off to expire it.
    return (not above(p, s, i, 120) and (mom(p[s], i, 21) or 0) < -0.030 and (mom(p[s], i, 63) or 0) < 0.010) or (
        gold_trap(p, i)
    )


def L07_e02_stale_trend_exit():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        if stale_trend(p, 'nasdaq', i) and target.get('nasdaq', 0) > 0.03:
            target['nasdaq'] = 0.0
            count(ctx, 'nasdaq_stale_exit')
        if stale_trend(p, 'gold_cny', i) and target.get('gold_cny', 0) > 0.03:
            target['gold_cny'] = 0.0
            count(ctx, 'gold_stale_exit')
        return normalize(target, 0.90)
    return fn


def L08_e02_stale_trend_cap():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        if stale_trend(p, 'nasdaq', i) and target.get('nasdaq', 0) > 0.18:
            target['nasdaq'] = 0.18
            count(ctx, 'nasdaq_stale_cap')
        if stale_trend(p, 'gold_cny', i) and target.get('gold_cny', 0) > 0.22:
            target['gold_cny'] = 0.22
            count(ctx, 'gold_stale_cap')
        return normalize(target, 0.90)
    return fn


def L09_e02_market_confirmed_stale_exit():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        market_bad = (not above(p, 'sp500', i, 120)) and ((mom(p['sp500'], i, 63) or 0) < -0.025)
        if market_bad and stale_trend(p, 'nasdaq', i) and target.get('nasdaq', 0) > 0.03:
            target['nasdaq'] = 0.0
            count(ctx, 'market_confirmed_nasdaq_stale_exit')
        if market_bad and stale_trend(p, 'gold_cny', i) and target.get('gold_cny', 0) > 0.03:
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.18)
            count(ctx, 'market_confirmed_gold_stale_cap')
        return normalize(target, 0.90)
    return fn


def L10_e02_stale_cap_plus_rare_shock():
    stale_cap = L08_e02_stale_trend_cap()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        target = stale_cap(dates, p, i, ctx) or {}
        if rare_shock(p, i):
            st['shock_cool'] = max(st.get('shock_cool', 0), 7)
            count(ctx, 'rare_shock')
        st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
        if st.get('shock_cool', 0) > 0:
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.16)
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.18 if gold_trap(p, i) else 0.24)
        return normalize(target, 0.48 if st.get('shock_cool', 0) > 0 else 0.90)
    return fn


def high_gross_stale(p, target: Dict[str, float], i: int) -> bool:
    gross = sum(target.get(s, 0.0) for s in HOLDINGS)
    if gross < 0.72:
        return False
    market_bad = (not above(p, 'sp500', i, 120)) and ((mom(p['sp500'], i, 63) or 0) < -0.020)
    own_bad = stale_trend(p, 'nasdaq', i) or stale_trend(p, 'gold_cny', i)
    return market_bad and own_bad


def L11_e02_high_gross_stale_cap():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        if high_gross_stale(p, target, i):
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.22)
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.26)
            count(ctx, 'high_gross_stale_cap')
        return normalize(target, 0.90)
    return fn


def L12_e02_high_gross_stale_plus_shock():
    high_cap = L11_e02_high_gross_stale_cap()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        target = high_cap(dates, p, i, ctx) or {}
        if rare_shock(p, i):
            st['shock_cool'] = max(st.get('shock_cool', 0), 7)
            count(ctx, 'rare_shock')
        st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
        if st.get('shock_cool', 0) > 0:
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.16)
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.18 if gold_trap(p, i) else 0.24)
        return normalize(target, 0.48 if st.get('shock_cool', 0) > 0 else 0.90)
    return fn


def L13_e02_high_gross_stale_soft_cap():
    base = base_e02()
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        if high_gross_stale(p, target, i):
            # Softer: cut only excess risk, preserving recovery participation.
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.30)
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.30)
            count(ctx, 'high_gross_stale_soft_cap')
        return normalize(target, 0.90)
    return fn


def simulate(dates, p, fn: Callable):
    vals, weights, extra = E.simulate_event(dates, p, fn, rebalance=1, band=0.015, warmup=252)
    bad = [s for ww in weights for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    return vals, weights, extra


def allm_ext(dates, vals):
    m = all_metrics(dates, vals)
    m['post2022'] = metrics(dates, vals, dt.date(2022, 1, 1), None)
    return m


def row(dates, p, name: str, desc: str, fn: Callable):
    vals, w, e = simulate(dates, p, fn)
    m = allm_ext(dates, vals)
    return {
        'name': name,
        'description': desc,
        'metrics': m,
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in Z.STRESS.items()},
        'extra': e,
        'top_dd': topdds(dates, vals, w),
        'pass_12_8': m['full']['ann'] >= TARGET_ANN and m['full']['dd'] <= TARGET_DD,
        'lowdd_frontier': m['full']['ann'] >= 0.075 and m['full']['dd'] <= 0.105,
    }


def main():
    dates, p = CORE.align(CORE.fetch())
    strategies = [
        ('REF_E02_loose', '011 reference: breakout + chandelier + rollover take-profit', base_e02()),
        ('L01_e02_gold_trap_cap', 'E02 + cap gold to 18% during gold blowoff/liquidity trap', L01_e02_gold_trap_cap()),
        ('L02_e02_gold_trap_exit', 'E02 + exit gold during gold blowoff/liquidity trap', L02_e02_gold_trap_exit()),
        ('L03_e02_rare_shock_cap', 'E02 + rare SP500 liquidity shock cap', L03_e02_rare_shock_cap()),
        ('L04_e02_gold_trap_plus_shock_cap', 'E02 + gold trap cap + rare shock cap', L04_e02_gold_trap_plus_shock_cap()),
        ('L05_e02_shock_cap_fast_rebuild', 'E02 + rare shock cash/rebuild ladder', L05_e02_shock_cap_fast_rebuild()),
        ('L06_e02_selective_gold_rebuild', 'E02 + selective gold rebuild after recovery, trap-capped', L06_e02_selective_gold_rebuild()),
        ('L07_e02_stale_trend_exit', 'E02 + expire sleeves when post-entry trend turns stale', L07_e02_stale_trend_exit()),
        ('L08_e02_stale_trend_cap', 'E02 + cap stale sleeves instead of full exit', L08_e02_stale_trend_cap()),
        ('L09_e02_market_confirmed_stale_exit', 'E02 + stale expiry only when SP500 also confirms risk-off', L09_e02_market_confirmed_stale_exit()),
        ('L10_e02_stale_cap_plus_rare_shock', 'E02 + stale cap plus rare SP500 liquidity shock cap', L10_e02_stale_cap_plus_rare_shock()),
        ('L11_e02_high_gross_stale_cap', 'E02 + cap only when high gross exposure becomes stale', L11_e02_high_gross_stale_cap()),
        ('L12_e02_high_gross_stale_plus_shock', 'E02 + high-gross stale cap plus rare liquidity shock cap', L12_e02_high_gross_stale_plus_shock()),
        ('L13_e02_high_gross_stale_soft_cap', 'E02 + softer high-gross stale cap preserving participation', L13_e02_high_gross_stale_soft_cap()),
    ]
    rows = [row(dates, p, *s) for s in strategies]
    OUT.write_text(json.dumps({
        'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates), 'holdings': HOLDINGS + ['cash'], 'signals_only': ['sp500']},
        'target': {'ann': TARGET_ANN, 'dd': TARGET_DD},
        'rows': rows,
    }, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates))
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']; p20 = r['metrics']['post2020']; ten = r['metrics']['teny']; p22 = r['metrics']['post2022']
        mark = 'PASS12/8' if r['pass_12_8'] else ('LOWDD' if r['lowdd_frontier'] else 'FAIL')
        latest = {k: round(v * 100, 1) for k, v in r['extra'].get('latest', {}).items()}
        print(f"{mark:8s} {r['name']:36s} full {pct(m['ann'])}/{pct(m['dd'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"          post20 {pct(p20['ann'])}/{pct(p20['dd'])} tenY {pct(ten['ann'])}/{pct(ten['dd'])} post22 {pct(p22['ann'])}/{pct(p22['dd'])}")
        print(f"          latest={latest} cash={pct(r['extra'].get('cash_pct', 0))} trades={r['extra'].get('trades')} events={r['extra'].get('events', {})}")
        print('          topdd ' + ' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))


if __name__ == '__main__':
    main()
