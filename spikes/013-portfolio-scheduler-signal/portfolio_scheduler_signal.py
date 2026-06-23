#!/usr/bin/env python3
"""013: portfolio-level gold/Nasdaq/cash scheduler with external risk signals.

Visible holdings stay fixed to: nasdaq, gold_cny, cash.
External assets (SP500/Dow) are signals only, not holdings.

This is a mechanism spike, not a parameter grid:
- each strategy is one interpretable fixed rule set;
- execution reuses 011/012口径: T-1 signal / T execution, real units/cash,
  CNY cash yield, fee/slippage, full aligned AssetTimeMachine history.
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
spec = importlib.util.spec_from_file_location(
    'E11', ROOT / 'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py'
)
E = importlib.util.module_from_spec(spec)
sys.modules['E11'] = E
spec.loader.exec_module(E)  # type: ignore
Z = E.Z
CORE = E.CORE

OUT = Path('/tmp/atm_portfolio_scheduler_signal_013.json')
START = 100_000.0
TARGET_ANN = 0.12
TARGET_DD = 0.08
HOLDINGS = ['nasdaq', 'gold_cny']
VISIBLE_ALLOWED = set(HOLDINGS)

pct = Z.pct
ma = Z.ma
mom = Z.mom
above = Z.above
normalize = Z.normalize
score_asset = Z.score_asset
positive_6m = Z.positive_6m
positive_12m = Z.positive_12m
realized_vol = Z.realized_vol
dd_series = Z.dd_series
virtual_barbell = Z.virtual_barbell
virtual_ma = Z.virtual_ma
virtual_mom = Z.virtual_mom
barbell_health_state = Z.barbell_health_state


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


def count(ctx: Dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def clip(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def pressure_score(p, i: int) -> float:
    """0..100 external US-equity liquidity/risk pressure.

    Uses SP500 + Nasdaq as signals only. Higher means cut Nasdaq risk budget.
    """
    if i < 63:
        return 0.0
    score = 0.0
    sp5 = mom(p['sp500'], i, 5) or 0
    sp21 = mom(p['sp500'], i, 21) or 0
    sp63dd = dd_series(p['sp500'], i, 63) or 0
    nq5 = mom(p['nasdaq'], i, 5) or 0
    nq21 = mom(p['nasdaq'], i, 21) or 0
    spv20 = realized_vol(p['sp500'], i, 20) or 0
    spv63 = realized_vol(p['sp500'], i, 63) or 0.18

    if sp5 < -0.060:
        score += 30
    elif sp5 < -0.035:
        score += 18
    elif sp5 < -0.020:
        score += 8

    if sp21 < -0.110:
        score += 30
    elif sp21 < -0.075:
        score += 20
    elif sp21 < -0.045:
        score += 10

    if sp63dd < -0.160:
        score += 22
    elif sp63dd < -0.100:
        score += 14
    elif sp63dd < -0.065:
        score += 7

    if nq5 < -0.075 or nq21 < -0.130:
        score += 12
    elif nq5 < -0.045 or nq21 < -0.080:
        score += 7

    if spv20 > 0.36 or spv20 > spv63 * 2.0:
        score += 16
    elif spv20 > 0.27 or spv20 > spv63 * 1.6:
        score += 9

    return clip(score, 0, 100)


def pressure_level(p, i: int) -> str:
    s = pressure_score(p, i)
    if s >= 75:
        return 'shock'
    if s >= 50:
        return 'stress'
    if s >= 25:
        return 'watch'
    return 'calm'


def gold_blowoff_or_trap(p, i: int) -> bool:
    if i < 252:
        return False
    one_y = mom(p['gold_cny'], i, 252) or 0
    one_m = mom(p['gold_cny'], i, 21) or 0
    two_w = mom(p['gold_cny'], i, 10) or 0
    short_gold_down_with_spx = two_w < -0.035 and (mom(p['sp500'], i, 10) or 0) < -0.035
    blowoff_roll = one_y > 0.28 and one_m < -0.035
    return short_gold_down_with_spx or blowoff_roll


def recovery_stage(p, s: str, i: int) -> int:
    """0..3 staged re-entry after crash/stop, fixed and interpretable."""
    if i < 63:
        return 0
    l21 = rolling_low(p[s], i, 21, exclude_current=False)
    l63 = rolling_low(p[s], i, 63, exclude_current=False)
    r21 = p[s][i] / l21 - 1 if l21 else 0
    r63 = p[s][i] / l63 - 1 if l63 else 0
    m5 = mom(p[s], i, 5) or 0
    m10 = mom(p[s], i, 10) or 0
    m21 = mom(p[s], i, 21) or 0
    st = 0
    if s == 'nasdaq':
        if r21 > 0.050 or (m5 > 0.030 and above(p, s, i, 10)):
            st = 1
        if r63 > 0.090 or (m10 > 0.055 and above(p, s, i, 20)):
            st = 2
        if m21 > 0.080 and above(p, s, i, 40):
            st = 3
    else:
        if gold_blowoff_or_trap(p, i):
            return 0
        if r21 > 0.035 or (m5 > 0.018 and above(p, s, i, 10)):
            st = 1
        if r63 > 0.060 or (m10 > 0.035 and above(p, s, i, 20)):
            st = 2
        if m21 > 0.055 and above(p, s, i, 40):
            st = 3
    return st


def trend_ok(p, s: str, i: int, ma_n: int = 160, mom_n: int = 126, th: float = 0.0) -> bool:
    return above(p, s, i, ma_n) and (mom(p[s], i, mom_n) or -9) > th


def base_scheduler_target(p, i: int) -> Dict[str, float]:
    """Base target: product story is Nasdaq engine + gold ballast + cash buffer."""
    state, _ = barbell_health_state(p, i)
    nq_ok = trend_ok(p, 'nasdaq', i, 180, 126, -0.015)
    gold_ok = trend_ok(p, 'gold_cny', i, 120, 126, -0.010) and not gold_blowoff_or_trap(p, i)
    sp_ok = positive_6m(p, 'sp500', i)
    pressure = pressure_level(p, i)

    # Start from a conservative barbell. Increase Nasdaq only when broad US risk is calm.
    target: Dict[str, float] = {}
    if gold_ok:
        target['gold_cny'] = 0.28
    if nq_ok and sp_ok:
        target['nasdaq'] = 0.32

    if state == 'healthy' and pressure == 'calm':
        if nq_ok:
            target['nasdaq'] = max(target.get('nasdaq', 0), 0.46)
        if gold_ok:
            target['gold_cny'] = max(target.get('gold_cny', 0), 0.32)
    elif state == 'healthy' and pressure == 'watch':
        if nq_ok:
            target['nasdaq'] = min(max(target.get('nasdaq', 0), 0.34), 0.38)
        if gold_ok:
            target['gold_cny'] = max(target.get('gold_cny', 0), 0.34)
    elif state == 'bruised':
        if nq_ok:
            target['nasdaq'] = min(target.get('nasdaq', 0), 0.22)
        if gold_ok:
            target['gold_cny'] = max(target.get('gold_cny', 0), 0.30)
    elif state == 'broken':
        target = {'gold_cny': 0.22} if gold_ok else {}

    if pressure == 'stress':
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.18)
        if gold_ok:
            target['gold_cny'] = max(target.get('gold_cny', 0), 0.24)
    elif pressure == 'shock':
        target['nasdaq'] = 0.0
        target['gold_cny'] = min(target.get('gold_cny', 0), 0.18) if gold_ok else 0.0

    return normalize(target, 0.88)


# ---- fixed mechanism candidates ----

def P01_pressure_scaled_scheduler(dates, p, i, ctx):
    """Base scheduler; external pressure only scales Nasdaq, not gold/Nasdaq entry rules."""
    target = base_scheduler_target(p, i)
    count(ctx, f"pressure_{pressure_level(p, i)}")
    return normalize(target, 0.88)


def P02_pressure_ladder_rebuild(dates, p, i, ctx):
    """Cut risk in pressure; rebuild in stages from crash lows instead of waiting for new highs."""
    st = ctx.setdefault('state', {})
    w = ctx.get('sig_w', {})
    target = base_scheduler_target(p, i)
    level = pressure_level(p, i)
    count(ctx, f"pressure_{level}")

    if level in ('stress', 'shock'):
        st['risk_watch'] = max(st.get('risk_watch', 0), 45 if level == 'stress' else 70)
        for s in HOLDINGS:
            st[f'{s}_crash_low'] = min(st.get(f'{s}_crash_low', p[s][i]), p[s][i])

    st['risk_watch'] = max(0, st.get('risk_watch', 0) - 1)
    if st.get('risk_watch', 0) > 0:
        # Start from very defensive, then add staged re-entry only after actual recovery.
        defensive: Dict[str, float] = {}
        if trend_ok(p, 'gold_cny', i, 80, 42, -0.02) and not gold_blowoff_or_trap(p, i):
            defensive['gold_cny'] = 0.20
        nq_stage = recovery_stage(p, 'nasdaq', i)
        g_stage = recovery_stage(p, 'gold_cny', i)
        if nq_stage >= 1 and pressure_score(p, i) < 65:
            defensive['nasdaq'] = [0, 0.14, 0.26, 0.38][nq_stage]
        if g_stage >= 1:
            defensive['gold_cny'] = max(defensive.get('gold_cny', 0), [0, 0.16, 0.26, 0.34][g_stage])
        return normalize(defensive, 0.62)

    # Normal state: if currently underinvested after a watch, allow staged rebuild to base weights.
    if w.get('nasdaq', 0) < 0.10 and recovery_stage(p, 'nasdaq', i) >= 2 and positive_6m(p, 'sp500', i):
        target['nasdaq'] = max(target.get('nasdaq', 0), 0.34)
        count(ctx, 'nasdaq_staged_rebuild')
    if w.get('gold_cny', 0) < 0.10 and recovery_stage(p, 'gold_cny', i) >= 2:
        target['gold_cny'] = max(target.get('gold_cny', 0), 0.28)
        count(ctx, 'gold_staged_rebuild')
    return normalize(target, 0.86)


def P03_equity_curve_trailing_budget(dates, p, i, ctx):
    """Portfolio-level trailing risk budget: drawdown reduces gross exposure, recovery restores."""
    st = ctx.setdefault('state', {})
    target = base_scheduler_target(p, i)
    pdd = ctx.get('portfolio_dd', 0)
    vb = virtual_barbell(p, i, 0.5, 0.5)
    vm80 = virtual_ma(p, i, 80, 0.5, 0.5)
    vm160 = virtual_ma(p, i, 160, 0.5, 0.5)
    recovered = vm80 is not None and vm160 is not None and vb > vm80 > vm160 and (virtual_mom(p, i, 21, 0.5, 0.5) or 0) > 0.015

    if pdd > 0.105:
        st['budget_state'] = 'hard'
        count(ctx, 'portfolio_hard_trail')
    elif pdd > 0.075 and st.get('budget_state') != 'hard':
        st['budget_state'] = 'soft'
        count(ctx, 'portfolio_soft_trail')
    elif recovered and pdd < 0.040:
        st['budget_state'] = 'normal'

    state = st.get('budget_state', 'normal')
    if state == 'hard':
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.10)
        target['gold_cny'] = min(target.get('gold_cny', 0), 0.22 if not gold_blowoff_or_trap(p, i) else 0.0)
        return normalize(target, 0.32)
    if state == 'soft':
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.22)
        target['gold_cny'] = min(target.get('gold_cny', 0), 0.30)
        return normalize(target, 0.52)
    return normalize(target, 0.88)


def P04_barbell_relative_strength_scheduler(dates, p, i, ctx):
    """Allocate the extra budget only when Nasdaq beats gold and broad US risk confirms."""
    level = pressure_level(p, i)
    state, _ = barbell_health_state(p, i)
    target: Dict[str, float] = {}
    gold_ok = trend_ok(p, 'gold_cny', i, 120, 126, -0.02) and not gold_blowoff_or_trap(p, i)
    nq_ok = trend_ok(p, 'nasdaq', i, 180, 126, -0.02) and positive_6m(p, 'sp500', i)
    rel_nq = (mom(p['nasdaq'], i, 63) or 0) - (mom(p['gold_cny'], i, 63) or 0)

    if state == 'broken' or level == 'shock':
        return {'gold_cny': 0.20} if gold_ok and level != 'shock' else {}

    # Core exposure only when each sleeve is individually alive.
    if nq_ok:
        target['nasdaq'] = 0.24
    if gold_ok:
        target['gold_cny'] = 0.30

    # Satellite goes to the risk-adjusted leader, but Nasdaq needs external confirmation.
    if level == 'calm' and nq_ok and rel_nq > 0.025:
        target['nasdaq'] = target.get('nasdaq', 0) + 0.24
    elif gold_ok and rel_nq < -0.015:
        target['gold_cny'] = target.get('gold_cny', 0) + 0.18

    if level == 'stress':
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.14)
    elif level == 'watch':
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.34)
    return normalize(target, 0.78 if state == 'healthy' else 0.58)


def P05_m13_harvest_with_pressure_brake(dates, p, i, ctx):
    """Use M13 harvest/rebuild as return engine, but pressure and gold-trap state cap tail risk."""
    st = ctx.setdefault('state', {})
    if 'm13_target' not in st or (i + 1) % 20 == 0:
        raw = Z.M13_rebalance_harvest_rebuild(dates, p, i, ctx)
        if raw is not None:
            st['m13_target'] = dict(raw)
        elif 'm13_target' not in st:
            st['m13_target'] = dict(ctx.get('sig_w', {}))
    target = dict(st.get('m13_target', {}))
    level = pressure_level(p, i)
    count(ctx, f"pressure_{level}")

    if level == 'shock':
        st['pressure_cool'] = max(st.get('pressure_cool', 0), 45)
    elif level == 'stress':
        st['pressure_cool'] = max(st.get('pressure_cool', 0), 25)
    st['pressure_cool'] = max(0, st.get('pressure_cool', 0) - 1)

    if st.get('pressure_cool', 0) > 0:
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.16)
        if not gold_blowoff_or_trap(p, i) and positive_6m(p, 'gold_cny', i):
            target['gold_cny'] = min(max(target.get('gold_cny', 0), 0.22), 0.34)
        else:
            target['gold_cny'] = min(target.get('gold_cny', 0), 0.12)
        return normalize(target, 0.46)

    if gold_blowoff_or_trap(p, i):
        target['gold_cny'] = min(target.get('gold_cny', 0), 0.18)
        count(ctx, 'gold_blowoff_cap')
    return normalize(target, 0.88)


def P06_e02_plus_scheduler_override(dates, p, i, ctx):
    """E02 entries remain selective; scheduler adds portfolio-level pressure override/rebuild."""
    base = E.E02_breakout_chandelier('loose')
    target = base(dates, p, i, ctx) or {}
    level = pressure_level(p, i)
    st = ctx.setdefault('state', {})
    if level in ('stress', 'shock'):
        st['override'] = max(st.get('override', 0), 30 if level == 'stress' else 55)
    st['override'] = max(0, st.get('override', 0) - 1)
    if st.get('override', 0) > 0:
        target['nasdaq'] = min(target.get('nasdaq', 0), 0.12 if level == 'shock' else 0.22)
        if gold_blowoff_or_trap(p, i):
            target['gold_cny'] = 0.0
        else:
            target['gold_cny'] = min(max(target.get('gold_cny', 0), 0.18), 0.30)
        return normalize(target, 0.42 if level == 'shock' else 0.58)
    # Explicit staged rebuild avoids waiting for a fresh 126d high.
    if target.get('nasdaq', 0) < 0.03 and recovery_stage(p, 'nasdaq', i) >= 3 and positive_6m(p, 'sp500', i):
        target['nasdaq'] = 0.30
    if target.get('gold_cny', 0) < 0.03 and recovery_stage(p, 'gold_cny', i) >= 2:
        target['gold_cny'] = 0.26
    return normalize(target, 0.86)


def simulate_buy_hold(dates, p, init):
    return Z.simulate_buy_hold(dates, p, init)


def simulate_strategy(dates, p, fn: Callable):
    vals, weights, extra = E.simulate_event(dates, p, fn, rebalance=1, band=0.015, warmup=252)
    bad = [s for ww in weights for s in ww if s not in VISIBLE_ALLOWED]
    assert not bad, bad[:5]
    return vals, weights, extra


def metrics(dates, vals, start=None, end=None):
    return Z.metrics(dates, vals, start, end)


def all_metrics_extended(dates, vals):
    m = Z.all_metrics(dates, vals)
    m['post2022'] = metrics(dates, vals, dt.date(2022, 1, 1), None)
    return m


def topdds(dates, vals, weights):
    return Z.topdds(dates, vals, weights)


def row_for(dates, p, name: str, desc: str, fn: Callable | None, bh: Dict[str, float] | None = None):
    if bh is not None:
        vals, weights, extra = simulate_buy_hold(dates, p, bh)
    else:
        vals, weights, extra = simulate_strategy(dates, p, fn)  # type: ignore[arg-type]
    return {
        'name': name,
        'description': desc,
        'metrics': all_metrics_extended(dates, vals),
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in Z.STRESS.items()},
        'extra': extra,
        'top_dd': topdds(dates, vals, weights),
        'pass_12_8': (all_metrics_extended(dates, vals)['full']['ann'] >= TARGET_ANN and all_metrics_extended(dates, vals)['full']['dd'] <= TARGET_DD),
        'promotable_10dd': (all_metrics_extended(dates, vals)['full']['ann'] >= 0.075 and all_metrics_extended(dates, vals)['full']['dd'] <= 0.10),
    }


def run():
    dates, p = CORE.align(CORE.fetch())
    strategies = [
        ('BH_25N_25G_50C', 'true 25% Nasdaq + 25% gold + 50% cash buy-and-hold baseline', None, {'nasdaq': 0.25, 'gold_cny': 0.25}),
        ('BH_25N_35G_40C', 'true 25% Nasdaq + 35% gold + 40% cash buy-and-hold baseline', None, {'nasdaq': 0.25, 'gold_cny': 0.35}),
        ('REF_E02_loose', '011 low-DD frontier: breakout + chandelier + rollover take-profit', E.E02_breakout_chandelier('loose'), None),
        ('P01_pressure_scaled_scheduler', 'portfolio scheduler: Nasdaq/gold/cash base target, SP500 pressure scales Nasdaq risk', P01_pressure_scaled_scheduler, None),
        ('P02_pressure_ladder_rebuild', 'pressure cut + staged re-entry from crash lows', P02_pressure_ladder_rebuild, None),
        ('P03_equity_curve_trailing_budget', 'portfolio high-water trailing budget with recovery unlock', P03_equity_curve_trailing_budget, None),
        ('P04_barbell_relative_strength_scheduler', 'barbell relative strength with external US confirmation', P04_barbell_relative_strength_scheduler, None),
        ('P05_m13_harvest_with_pressure_brake', 'M13 harvest/rebuild return engine with pressure/gold-trap cap', P05_m13_harvest_with_pressure_brake, None),
        ('P06_e02_plus_scheduler_override', 'E02 selective entries plus portfolio scheduler override and staged rebuild', P06_e02_plus_scheduler_override, None),
    ]
    rows = [row_for(dates, p, *item) for item in strategies]
    payload = {
        'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates), 'holdings': HOLDINGS + ['cash'], 'signals_only': ['sp500', 'dowjones']},
        'target': {'ann': TARGET_ANN, 'dd': TARGET_DD},
        'rows': rows,
    }
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates), 'holdings', HOLDINGS + ['cash'])
    print('\nSorted by full annualized:')
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']
        p20 = r['metrics']['post2020']
        ten = r['metrics']['teny']
        p22 = r['metrics']['post2022']
        mark = 'PASS12/8' if r['pass_12_8'] else ('PROMO10DD' if r['promotable_10dd'] else 'FAIL')
        latest = {k: round(v * 100, 1) for k, v in r['extra'].get('latest', {}).items()}
        cash = r['extra'].get('cash_pct', 0)
        print(f"{mark:9s} {r['name']:34s} full {pct(m['ann'])}/{pct(m['dd'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"           post20 {pct(p20['ann'])}/{pct(p20['dd'])}  tenY {pct(ten['ann'])}/{pct(ten['dd'])}  post22 {pct(p22['ann'])}/{pct(p22['dd'])}")
        print(f"           latest={latest} cash={pct(cash)} trades={r['extra'].get('trades')} desc={r['description']}")
        print('           topdd ' + ' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:2]))


if __name__ == '__main__':
    run()
