#!/usr/bin/env python3
"""015: risk-budget / insurance-budget frontier for AssetTimeMachine.

Goal: find a product-compatible gold/Nasdaq/cash strategy without BTC and without
parameter-grid fitting.  The mechanisms here are fixed, interpretable rules:

1. E02 plus an equity-curve insurance budget.
2. Aggressive 25N/35G barbell plus a TIPP-style portfolio floor.
3. Regime allocator using Nasdaq/Gold as visible holdings and S&P only as signal.
4. Shock/recovery staged re-entry after liquidity shocks.

All candidates use real units/cash accounting, T-1 signal / T execution, cash yield,
fees/slippage inherited from the existing AssetTimeMachine spike modules.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Tuple

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
OUT = Path('/tmp/atm_risk_budget_frontier_015.json')

spec_e = importlib.util.spec_from_file_location('E11', ROOT / 'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py')
E = importlib.util.module_from_spec(spec_e); sys.modules['E11'] = E; spec_e.loader.exec_module(E)  # type: ignore
Z = E.Z
CORE = E.CORE

spec_b = importlib.util.spec_from_file_location('B007', ROOT / 'spikes/007-gold-nasdaq-cash-only/barbell_drift_policies.py')
B = importlib.util.module_from_spec(spec_b); sys.modules['B007'] = B; spec_b.loader.exec_module(B)  # type: ignore

HOLDINGS = ['nasdaq', 'gold_cny']
START = 100_000.0
BASE = {'nasdaq': 0.25, 'gold_cny': 0.35}
TARGET_ANN = 0.12
TARGET_DD = 0.08

pct = Z.pct
ma = Z.ma
mom = Z.mom
above = Z.above
normalize = Z.normalize
all_metrics = Z.all_metrics
metrics = Z.metrics
topdds = Z.topdds
realized_vol = Z.realized_vol
score_asset = Z.score_asset

STRESS = {
    '2008金融危机': (dt.date(2007, 10, 1), dt.date(2009, 3, 31)),
    '2011黄金拐点': (dt.date(2011, 1, 1), dt.date(2013, 12, 31)),
    '2015波动': (dt.date(2015, 6, 1), dt.date(2016, 2, 29)),
    '2020疫情': (dt.date(2020, 2, 1), dt.date(2020, 4, 30)),
    '2022加息': (dt.date(2022, 1, 1), dt.date(2022, 12, 31)),
    '2026AI波动': (dt.date(2025, 12, 1), None),
}


def count(ctx: Dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def rolling_high(v, i: int, n: int, exclude_current: bool = True):
    end = i if exclude_current else i + 1
    start = max(0, end - n)
    if end - start < 5:
        return None
    return max(v[start:end])


def rolling_low(v, i: int, n: int, exclude_current: bool = True):
    end = i if exclude_current else i + 1
    start = max(0, end - n)
    if end - start < 5:
        return None
    return min(v[start:end])


def rare_liquidity_shock(p, i: int) -> bool:
    if i < 63:
        return False
    sp5 = mom(p['sp500'], i, 5) or 0
    sp10 = mom(p['sp500'], i, 10) or 0
    nq5 = mom(p['nasdaq'], i, 5) or 0
    vol10 = realized_vol(p['sp500'], i, 10) or 0
    vol63 = realized_vol(p['sp500'], i, 63) or 0.18
    return sp5 < -0.085 or sp10 < -0.120 or nq5 < -0.120 or (vol10 > vol63 * 2.8 and sp10 < -0.07)


def gold_trap(p, i: int) -> bool:
    if i < 252:
        return False
    return ((mom(p['gold_cny'], i, 252) or 0) > 0.28 and (mom(p['gold_cny'], i, 21) or 0) < -0.030) or (
        (mom(p['gold_cny'], i, 10) or 0) < -0.035 and (mom(p['sp500'], i, 10) or 0) < -0.040
    )


def trend_ok(p, s: str, i: int, ma_n: int, mom_n: int, th: float = 0.0) -> bool:
    return above(p, s, i, ma_n) and (mom(p[s], i, mom_n) or -9) > th


def scale_to_gross(target: Dict[str, float], gross_cap: float) -> Dict[str, float]:
    cleaned = {s: max(0.0, target.get(s, 0.0)) for s in HOLDINGS}
    gross = sum(cleaned.values())
    if gross <= gross_cap + 1e-12:
        return normalize(cleaned, max(gross_cap, 0.0))
    k = max(0.0, gross_cap) / gross
    return {s: v * k for s, v in cleaned.items() if v * k > 1e-6}


def cap_with_preference(target: Dict[str, float], gross_cap: float, prefer_gold: bool = False) -> Dict[str, float]:
    out = {s: max(0.0, target.get(s, 0.0)) for s in HOLDINGS}
    if prefer_gold:
        out['nasdaq'] = min(out.get('nasdaq', 0.0), max(0.0, gross_cap * 0.30))
        out['gold_cny'] = min(out.get('gold_cny', 0.0), max(0.0, gross_cap - out.get('nasdaq', 0.0)))
        return normalize(out, gross_cap)
    return scale_to_gross(out, gross_cap)


def insurance_gross_cap(pdd: float) -> float:
    """Equity-curve insurance budget: reduce gross only after actual portfolio pain."""
    if pdd >= 0.105:
        return 0.28
    if pdd >= 0.080:
        return 0.42
    if pdd >= 0.060:
        return 0.58
    if pdd >= 0.040:
        return 0.72
    return 0.90


# --- Candidate 1: known E02 entry engine, but risk budget comes from equity-curve state. ---
def C01_e02_equity_insurance():
    base = E.E02_breakout_chandelier('loose')
    def fn(dates, p, i, ctx):
        target = base(dates, p, i, ctx) or {}
        pdd = ctx.get('portfolio_dd', 0.0)
        cap = insurance_gross_cap(pdd)
        if rare_liquidity_shock(p, i):
            cap = min(cap, 0.36)
            count(ctx, 'rare_liquidity_shock_cap')
        if gold_trap(p, i):
            target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.24)
            count(ctx, 'gold_trap_cap')
        return cap_with_preference(target, cap, prefer_gold=rare_liquidity_shock(p, i))
    return fn


# --- Candidate 2: aggressive drift/harvest base + TIPP cushion. ---
def C02_barbell_tipp_floor(floor_ratio: float = 0.90, multiplier: float = 3.0):
    base_policy = B.make_blowoff_rebuild(BASE)
    def fn(dates, p, i, ctx):
        w = ctx.get('sig_w', {})
        pdd = ctx.get('portfolio_dd', 0.0)
        target = base_policy(dates, p, i, w, pdd) or dict(w)
        # TIPP: floor is a fraction of the running peak. Gross budget is multiplier * cushion.
        # Using pdd avoids needing absolute portfolio value inside the target function.
        val_vs_peak = max(1e-9, 1.0 - pdd)
        cushion_ratio = max(0.0, val_vs_peak - floor_ratio) / val_vs_peak
        cap = min(0.90, multiplier * cushion_ratio)
        if pdd < 0.025:
            cap = max(cap, 0.62)  # allow participation near highs
        if rare_liquidity_shock(p, i):
            cap = min(cap, 0.34)
            count(ctx, 'rare_liquidity_shock_cap')
        if gold_trap(p, i):
            target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.24)
            count(ctx, 'gold_trap_cap')
        return cap_with_preference(target, cap, prefer_gold=rare_liquidity_shock(p, i))
    return fn


# --- Candidate 3: state machine; S&P is only a market-permission signal. ---
def C03_regime_allocator():
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        if rare_liquidity_shock(p, i):
            st['shock_days'] = 45
            count(ctx, 'shock_state_enter')
        st['shock_days'] = max(0, st.get('shock_days', 0) - 1)

        n_trend = trend_ok(p, 'nasdaq', i, 180, 126, 0.01)
        g_trend = trend_ok(p, 'gold_cny', i, 120, 63, 0.00) and not gold_trap(p, i)
        sp_permission = above(p, 'sp500', i, 180) and (mom(p['sp500'], i, 63) or 0) > -0.02
        recovery = above(p, 'nasdaq', i, 60) and (mom(p['nasdaq'], i, 21) or 0) > 0.035 and (mom(p['sp500'], i, 21) or 0) > 0.020

        if st.get('shock_days', 0) > 0 and not recovery:
            target = {'gold_cny': 0.22 if g_trend else 0.0}
            return normalize(target, 0.28)

        n_score = (mom(p['nasdaq'], i, 126) or -9) - 0.55 * (realized_vol(p['nasdaq'], i, 63) or 0.25)
        g_score = (mom(p['gold_cny'], i, 126) or -9) - 0.35 * (realized_vol(p['gold_cny'], i, 63) or 0.18)

        if n_trend and sp_permission and n_score >= g_score:
            target = {'nasdaq': 0.52, 'gold_cny': 0.22 if g_trend else 0.10}
        elif g_trend and g_score > n_score:
            target = {'gold_cny': 0.48, 'nasdaq': 0.14 if n_trend and sp_permission else 0.0}
        elif n_trend and sp_permission:
            target = {'nasdaq': 0.32}
        else:
            target = {'gold_cny': 0.22 if g_trend else 0.0}

        pdd = ctx.get('portfolio_dd', 0.0)
        if pdd > 0.075:
            target['nasdaq'] = min(target.get('nasdaq', 0.0), 0.18)
            target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.26)
            count(ctx, 'portfolio_dd_brake')
        return normalize(target, 0.78)
    return fn


# --- Candidate 4: staged recovery ladder after shocks instead of immediately buying full risk. ---
def C04_shock_recovery_ladder():
    base = C01_e02_equity_insurance()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        if rare_liquidity_shock(p, i):
            st['ladder_state'] = 0
            st['shock_cool'] = 60
            count(ctx, 'ladder_shock_reset')
        st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)

        target = base(dates, p, i, ctx) or {}
        recovery1 = above(p, 'sp500', i, 40) and (mom(p['sp500'], i, 10) or 0) > 0.015
        recovery2 = above(p, 'nasdaq', i, 60) and (mom(p['nasdaq'], i, 21) or 0) > 0.035
        recovery3 = trend_ok(p, 'nasdaq', i, 120, 63, 0.03) and above(p, 'sp500', i, 120)
        if st.get('shock_cool', 0) > 0:
            stage = st.get('ladder_state', 0)
            if stage == 0 and recovery1:
                stage = 1
            if stage <= 1 and recovery2:
                stage = 2
            if stage <= 2 and recovery3:
                stage = 3
            st['ladder_state'] = stage
            caps = {0: 0.22, 1: 0.36, 2: 0.54, 3: 0.72}
            cap = caps.get(stage, 0.22)
            if stage < 2:
                target['nasdaq'] = min(target.get('nasdaq', 0.0), 0.08 if stage == 0 else 0.18)
            count(ctx, f'ladder_stage_{stage}')
            return cap_with_preference(target, cap, prefer_gold=stage < 2)
        return target
    return fn


# --- Candidate 5: CPPI/TIPP allocator with risk asset selected by relative trend, not E02 entries. ---
def C05_cppi_relative_trend(floor_ratio: float = 0.91, multiplier: float = 4.0):
    def fn(dates, p, i, ctx):
        pdd = ctx.get('portfolio_dd', 0.0)
        val_vs_peak = max(1e-9, 1.0 - pdd)
        cushion_ratio = max(0.0, val_vs_peak - floor_ratio) / val_vs_peak
        cap = min(0.88, multiplier * cushion_ratio)
        if pdd < 0.025:
            cap = max(cap, 0.58)
        if rare_liquidity_shock(p, i):
            cap = min(cap, 0.25)
            count(ctx, 'cppi_shock_cap')

        n_ok = trend_ok(p, 'nasdaq', i, 180, 126, 0.00) and above(p, 'sp500', i, 180)
        g_ok = trend_ok(p, 'gold_cny', i, 120, 63, 0.00) and not gold_trap(p, i)
        n_score = (mom(p['nasdaq'], i, 126) or -9) + 0.45 * (mom(p['nasdaq'], i, 21) or 0) - 0.50 * (realized_vol(p['nasdaq'], i, 63) or 0.25)
        g_score = (mom(p['gold_cny'], i, 126) or -9) + 0.35 * (mom(p['gold_cny'], i, 21) or 0) - 0.35 * (realized_vol(p['gold_cny'], i, 63) or 0.18)
        if n_ok and (not g_ok or n_score >= g_score + 0.01):
            target = {'nasdaq': cap * 0.72, 'gold_cny': cap * 0.28 if g_ok else 0.0}
        elif g_ok:
            target = {'gold_cny': cap * 0.86, 'nasdaq': cap * 0.14 if n_ok else 0.0}
        elif n_ok:
            target = {'nasdaq': cap * 0.55}
        else:
            target = {}
        return normalize(target, cap)
    return fn


CANDIDATES = [
    ('REF_E02_loose', 'Reference: breakout/chandelier E02, current low-DD frontier', E.E02_breakout_chandelier('loose'), 1),
    ('C01_e02_equity_insurance', 'E02 entries + equity-curve insurance budget + shock/gold-trap caps', C01_e02_equity_insurance(), 1),
    ('C02_barbell_tipp_floor', '25N/35G drift-harvest-rebuild + TIPP floor risk budget', C02_barbell_tipp_floor(), 20),
    ('C03_regime_allocator', 'S&P-permission state machine rotating only Nasdaq/Gold/Cash', C03_regime_allocator(), 5),
    ('C04_shock_recovery_ladder', 'E02 insurance plus staged re-entry after liquidity shock', C04_shock_recovery_ladder(), 1),
    ('C05_cppi_relative_trend', 'CPPI/TIPP cushion allocated by relative Nasdaq-vs-Gold trend', C05_cppi_relative_trend(), 5),
]


def run_candidate(dates, p, name: str, desc: str, fn: Callable, rebalance: int) -> Dict[str, Any]:
    vals, weights, extra = E.simulate_event(dates, p, fn, rebalance=rebalance, band=0.02)
    m = all_metrics(dates, vals)
    return {
        'name': name,
        'description': desc,
        'rebalance': rebalance,
        'metrics': m,
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in STRESS.items()},
        'extra': extra,
        'top_dd': topdds(dates, vals, weights),
        'promote_gate_12_8': bool(m['full']['ann'] >= TARGET_ANN and m['full']['dd'] <= TARGET_DD),
        'lowdd_gate_8_10': bool(m['full']['ann'] >= 0.08 and m['full']['dd'] <= 0.10),
        'frontier_gate_7_10': bool(m['full']['ann'] >= 0.07 and m['full']['dd'] <= 0.10),
    }


def main() -> None:
    dates, p = CORE.align(CORE.fetch())
    rows = [run_candidate(dates, p, *c) for c in CANDIDATES]
    payload = {
        'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates)},
        'target': {'ann': TARGET_ANN, 'dd': TARGET_DD},
        'rows': rows,
    }
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates), 'target', TARGET_ANN, TARGET_DD)
    print('\nSorted by full annualized:')
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        full = r['metrics']['full']; p20 = r['metrics']['post2020']; ten = r['metrics']['teny']; p24 = r['metrics']['2024+']
        mark = 'PROMOTE12/8' if r['promote_gate_12_8'] else ('LOW8/10' if r['lowdd_gate_8_10'] else ('FRONTIER7/10' if r['frontier_gate_7_10'] else 'FAIL'))
        latest = {k: round(v * 100, 1) for k, v in r['extra']['latest'].items()}
        print(f"{mark:12s} {r['name']:32s} full={full['ann']*100:.2f}/{full['dd']*100:.2f} sh={full['sharpe']:.2f} cal={full['calmar']:.2f}")
        print(f"             post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f} tenY={ten['ann']*100:.2f}/{ten['dd']*100:.2f} 2024+={p24['ann']*100:.2f}/{p24['dd']*100:.2f} latest={latest} cash={r['extra']['cash_pct']*100:.1f}% trades={r['extra']['trades']}")
        print('             events=', r['extra'].get('events', {}))
        print('             topdd=', ' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
    print('\nStress slices:')
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        print('\n##', r['name'])
        for k, v in r['stress'].items():
            if v:
                print(f"  {k}: {v['ann']*100:.2f}/{v['dd']*100:.2f}")


if __name__ == '__main__':
    main()
