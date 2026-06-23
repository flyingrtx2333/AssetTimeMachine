#!/usr/bin/env python3
"""013 v2: start from the proven 25N/35G drift-harvest engine, add rare brakes.

Why: first 013 scheduler variants were too cash-heavy and over-traded. This file
keeps the return engine from spike 007 and tests only mechanism-level overlays:
rare liquidity shock trim, recession trend brake, and staged rebuild.
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
spec = importlib.util.spec_from_file_location('B07', ROOT / 'spikes/007-gold-nasdaq-cash-only/barbell_drift_policies.py')
B = importlib.util.module_from_spec(spec)
sys.modules['B07'] = B
spec.loader.exec_module(B)  # type: ignore
CORE = B.CORE
OUT = Path('/tmp/atm_portfolio_scheduler_signal_013_v2.json')

START = 100_000.0
HOLDINGS = ['nasdaq', 'gold_cny']
INIT_25_35 = {'nasdaq': 0.25, 'gold_cny': 0.35}
TARGET_ANN = 0.12
TARGET_DD = 0.08

pct = B.pct
ma = B.ma
mom = B.mom
above = B.above
dd = B.dd
metrics = B.metrics
topdds = B.topdds

STRESS = B.STRESS
PERIODS = dict(B.PERIODS)
PERIODS['post2022'] = (dt.date(2022, 1, 1), None)


def allm(dates, vals):
    return {k: metrics(dates, vals, a, b) for k, (a, b) in PERIODS.items()}


def rolling_low(v, i: int, n: int, exclude_current: bool = True):
    end = i if exclude_current else i + 1
    start = max(0, end - n)
    if end - start < 5:
        return None
    return min(v[start:end])


def realized_vol(v, i: int, n: int = 20):
    if i - n < 1:
        return None
    rs = []
    for j in range(i - n + 1, i + 1):
        if v[j - 1] > 0 and v[j] > 0:
            rs.append(v[j] / v[j - 1] - 1)
    return statistics.stdev(rs) * math.sqrt(252) if len(rs) > 2 else None


def count(ctx: Dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('events', {})
    ev[name] = ev.get(name, 0) + 1


def gold_blowoff_or_trap(p, i: int) -> bool:
    if i < 252:
        return False
    return ((mom(p['gold_cny'], i, 252) or 0) > 0.32 and (mom(p['gold_cny'], i, 21) or 0) < -0.030) or (
        (mom(p['gold_cny'], i, 10) or 0) < -0.035 and (mom(p['sp500'], i, 10) or 0) < -0.040
    )


def liquidity_shock(p, i: int) -> bool:
    """Rare cash-demand event: intentionally much narrower than 013 v1 pressure score."""
    if i < 63:
        return False
    sp5 = mom(p['sp500'], i, 5) or 0
    sp10 = mom(p['sp500'], i, 10) or 0
    sp21 = mom(p['sp500'], i, 21) or 0
    nq5 = mom(p['nasdaq'], i, 5) or 0
    nq10 = mom(p['nasdaq'], i, 10) or 0
    spv10 = realized_vol(p['sp500'], i, 10) or 0
    spv63 = realized_vol(p['sp500'], i, 63) or 0.18
    return (
        sp5 < -0.085
        or sp10 < -0.120
        or (sp21 < -0.170 and not above(p, 'sp500', i, 40))
        or (nq5 < -0.115 and nq10 < -0.145)
        or (spv10 > spv63 * 2.8 and sp10 < -0.070)
    )


def recession_trend_break(p, i: int) -> bool:
    if i < 220:
        return False
    return (
        (not above(p, 'sp500', i, 220))
        and (not above(p, 'nasdaq', i, 220))
        and (mom(p['sp500'], i, 126) or 0) < -0.08
    )


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
    if gold_blowoff_or_trap(p, i):
        return 0
    if m21 > 0.055 and above(p, s, i, 40):
        return 3
    if r63 > 0.060 or (m10 > 0.035 and above(p, s, i, 20)):
        return 2
    if r21 > 0.035:
        return 1
    return 0


def trade_to(cash, units, p, i, target, band: float = 0.012):
    total = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
    traded = False
    # sell first
    for s in HOLDINGS:
        cur = units[s] * p[s][i]
        tgt = total * target.get(s, 0.0)
        if cur > tgt * (1 + band):
            su = min(units[s], (cur - tgt) / p[s][i])
            if su > 0:
                cash += su * p[s][i] * (1 - CORE.SLIP) * (1 - CORE.FEE)
                units[s] -= su
                traded = True
                if units[s] < 1e-12:
                    units[s] = 0.0
    total = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
    for s in HOLDINGS:
        cur = units[s] * p[s][i]
        tgt = total * target.get(s, 0.0)
        if cur < tgt * (1 - band):
            amt = min(cash, max(tgt - cur, 0))
            if amt > 1:
                units[s] += amt * (1 - CORE.FEE) / (p[s][i] * (1 + CORE.SLIP))
                cash -= amt
                traded = True
    return cash, units, traded


# Base 007 policy: harvest blowoff, rebuild base when medium trend recovers.
def base_blowoff_rebuild_policy(dates, p, i, w, pdd, ctx):
    return B.make_blowoff_rebuild(INIT_25_35)(dates, p, i, w, pdd)


def O01_rare_shock_trim(dates, p, i, w, pdd, ctx):
    base = base_blowoff_rebuild_policy(dates, p, i, w, pdd, ctx)
    st = ctx.setdefault('state', {})
    if liquidity_shock(p, i):
        st['shock_cool'] = max(st.get('shock_cool', 0), 10)
        count(ctx, 'liquidity_shock')
    st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
    if st.get('shock_cool', 0) > 0:
        tgt = dict(w if base is None else base)
        # Rare trim only: preserve the barbell engine, but stop crash tail from drifted Nasdaq.
        tgt['nasdaq'] = min(tgt.get('nasdaq', 0), 0.18)
        if gold_blowoff_or_trap(p, i):
            tgt['gold_cny'] = min(tgt.get('gold_cny', 0), 0.18)
        return tgt
    return base


def O02_shock_cash_then_fast_rebuild(dates, p, i, w, pdd, ctx):
    base = base_blowoff_rebuild_policy(dates, p, i, w, pdd, ctx)
    st = ctx.setdefault('state', {})
    if liquidity_shock(p, i):
        st['shock_cool'] = max(st.get('shock_cool', 0), 14)
        count(ctx, 'liquidity_shock')
    st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
    if st.get('shock_cool', 0) > 0:
        tgt: Dict[str, float] = {}
        ns = recovery_stage(p, 'nasdaq', i)
        gs = recovery_stage(p, 'gold_cny', i)
        if ns >= 2 and (mom(p['sp500'], i, 5) or 0) > -0.020:
            tgt['nasdaq'] = [0, 0.0, 0.18, 0.28][ns]
        if gs >= 1:
            tgt['gold_cny'] = [0, 0.14, 0.24, 0.32][gs]
        return tgt
    return base


def O03_recession_nasdaq_cap(dates, p, i, w, pdd, ctx):
    base = base_blowoff_rebuild_policy(dates, p, i, w, pdd, ctx)
    tgt = dict(w if base is None else base)
    if recession_trend_break(p, i) and pdd > 0.10:
        tgt['nasdaq'] = min(tgt.get('nasdaq', 0), INIT_25_35['nasdaq'])
        count(ctx, 'recession_nasdaq_cap')
        return tgt
    return base


def O04_combined_rare_brake(dates, p, i, w, pdd, ctx):
    # Combine rare shock trim + recession cap, but avoid persistent pressure scoring.
    tgt = O01_rare_shock_trim(dates, p, i, w, pdd, ctx)
    current = dict(w if tgt is None else tgt)
    if recession_trend_break(p, i) and pdd > 0.10:
        current['nasdaq'] = min(current.get('nasdaq', 0), INIT_25_35['nasdaq'])
        count(ctx, 'recession_nasdaq_cap')
        return current
    return tgt


def O05_blowoff_rebuild_gold_trap_cap(dates, p, i, w, pdd, ctx):
    base = base_blowoff_rebuild_policy(dates, p, i, w, pdd, ctx)
    tgt = dict(w if base is None else base)
    if gold_blowoff_or_trap(p, i) and tgt.get('gold_cny', 0) > 0.25:
        tgt['gold_cny'] = 0.25
        count(ctx, 'gold_trap_cap')
        return tgt
    return base


def O06_combined_with_rebuild_floor(dates, p, i, w, pdd, ctx):
    tgt = O04_combined_rare_brake(dates, p, i, w, pdd, ctx)
    current = dict(w if tgt is None else tgt)
    changed = tgt is not None
    # If rare brake left a sleeve too low, restore the base only after trend recovery.
    if current.get('nasdaq', 0) < 0.18 and recovery_stage(p, 'nasdaq', i) >= 3 and above(p, 'sp500', i, 80):
        current['nasdaq'] = INIT_25_35['nasdaq']
        changed = True
        count(ctx, 'nasdaq_rebuild_floor')
    if current.get('gold_cny', 0) < 0.26 and recovery_stage(p, 'gold_cny', i) >= 2:
        current['gold_cny'] = INIT_25_35['gold_cny']
        changed = True
        count(ctx, 'gold_rebuild_floor')
    return current if changed else None


def simulate_overlay(dates, p, policy: Callable, init=INIT_25_35, monthly_base=True, daily_emergency=True):
    cash = START
    units = {s: 0.0 for s in HOLDINGS}
    vals = []
    weights = []
    trades = 0
    ctx: Dict[str, Any] = {'state': {}, 'events': {}, 'peak': START}
    cash, units, did = trade_to(cash, units, p, 0, init)
    trades += 1 if did else 0

    for i, d in enumerate(dates):
        if i > 0 and cash > 0:
            cash += cash * CORE.cash_daily(dates[i - 1])
        val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        ctx['peak'] = max(ctx.get('peak', val), val)
        if i > 252:
            sig_i = i - 1
            sig_val = cash + sum(units[s] * p[s][sig_i] for s in HOLDINGS)
            w = {s: (units[s] * p[s][sig_i] / sig_val if sig_val > 0 else 0.0) for s in HOLDINGS}
            pdd = 1 - val / ctx['peak'] if ctx['peak'] else 0
            should_check = False
            if daily_emergency and (liquidity_shock(p, sig_i) or ctx['state'].get('shock_cool', 0) > 0):
                should_check = True
            if monthly_base and i % 20 == 0:
                should_check = True
            if should_check:
                target = policy(dates, p, sig_i, w, pdd, ctx)
                if target is not None:
                    # never allow visible holdings outside the product story
                    target = {s: max(0.0, float(target.get(s, 0.0))) for s in HOLDINGS if target.get(s, 0.0) > 1e-6}
                    gross = sum(target.values())
                    if gross > 0.95:
                        target = {s: v * 0.95 / gross for s, v in target.items()}
                    cash, units, did = trade_to(cash, units, p, i, target)
                    if did:
                        trades += 1
                        val = cash + sum(units[s] * p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s: units[s] * p[s][i] / val for s in HOLDINGS if val > 0 and units[s] * p[s][i] / val > 1e-4})
    return vals, weights, {'trades': trades, 'latest': weights[-1], 'cash_pct': max(0, 1 - sum(weights[-1].values())), 'events': ctx.get('events', {})}


def row(dates, p, name: str, desc: str, policy: Callable | None, baseline: bool = False):
    if baseline:
        vals, w, e = B.simulate_policy(dates, p, name, B.make_blowoff_rebuild(INIT_25_35), init=INIT_25_35)
    else:
        vals, w, e = simulate_overlay(dates, p, policy)  # type: ignore[arg-type]
    bad = [s for ww in w for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    m = allm(dates, vals)
    return {
        'name': name,
        'description': desc,
        'metrics': m,
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in STRESS.items()},
        'extra': e,
        'top_dd': topdds(dates, vals, w),
        'pass_12_8': m['full']['ann'] >= TARGET_ANN and m['full']['dd'] <= TARGET_DD,
        'better_than_007_on_dd': m['full']['ann'] >= 0.085 and m['full']['dd'] < 0.1995,
    }


def main():
    dates, p = CORE.align(CORE.fetch())
    strategies = [
        ('REF_D_25N_35G_blowoff_rebuild', '007 reference: 25N/35G drift + blowoff harvest + rebuild', None, True),
        ('O01_rare_shock_trim', '007 engine + rare liquidity shock trims Nasdaq/gold only during shock', O01_rare_shock_trim, False),
        ('O02_shock_cash_then_fast_rebuild', '007 engine + shock cash/re-entry ladder', O02_shock_cash_then_fast_rebuild, False),
        ('O03_recession_nasdaq_cap', '007 engine + cap Nasdaq to base during confirmed recession trend break', O03_recession_nasdaq_cap, False),
        ('O04_combined_rare_brake', '007 engine + rare shock trim + recession Nasdaq cap', O04_combined_rare_brake, False),
        ('O05_gold_trap_cap', '007 engine + cap gold after blowoff/liquidity-trap signal', O05_blowoff_rebuild_gold_trap_cap, False),
        ('O06_combined_with_rebuild_floor', 'combined rare brake plus trend-confirmed rebuild floor', O06_combined_with_rebuild_floor, False),
    ]
    rows = [row(dates, p, *s) for s in strategies]
    OUT.write_text(json.dumps({
        'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates), 'holdings': HOLDINGS + ['cash'], 'signals_only': ['sp500']},
        'target': {'ann': TARGET_ANN, 'dd': TARGET_DD},
        'rows': rows,
    }, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates))
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']
        p20 = r['metrics']['post2020']
        ten = r['metrics']['teny']
        p22 = r['metrics']['post2022']
        mark = 'PASS12/8' if r['pass_12_8'] else ('BETTER007DD' if r['better_than_007_on_dd'] else 'FAIL')
        latest = {k: round(v * 100, 1) for k, v in r['extra'].get('latest', {}).items()}
        print(f"{mark:11s} {r['name']:36s} full {pct(m['ann'])}/{pct(m['dd'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"             post20 {pct(p20['ann'])}/{pct(p20['dd'])} tenY {pct(ten['ann'])}/{pct(ten['dd'])} post22 {pct(p22['ann'])}/{pct(p22['dd'])}")
        print(f"             latest={latest} cash={pct(r['extra'].get('cash_pct', 0))} trades={r['extra'].get('trades')} events={r['extra'].get('events', {})}")
        print('             topdd ' + ' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))


if __name__ == '__main__':
    main()
