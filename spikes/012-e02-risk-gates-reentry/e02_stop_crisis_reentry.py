#!/usr/bin/env python3
"""012 continuation: E02 stop/crisis re-entry experiments.

Focus: keep visible holdings restricted to nasdaq/gold_cny/cash, and test
interpretable rules that re-buy after E02 stop-loss or crisis exits so the
strategy does not wait for a fresh 126-day breakout before participating in a
rebound.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import datetime as dt
from pathlib import Path
from typing import Callable, Dict, Any

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec = importlib.util.spec_from_file_location(
    'R12', ROOT / 'spikes/012-e02-risk-gates-reentry/e02_risk_gates_reentry.py'
)
R = importlib.util.module_from_spec(spec)
sys.modules['R12'] = R
spec.loader.exec_module(R)  # type: ignore
E = R.E
Z = R.Z
CORE = R.CORE

OUT = Path('/tmp/atm_e02_stop_crisis_reentry_012.json')
TARGET_ANN = 0.12
TARGET_DD = 0.08
HOLDINGS = ['nasdaq', 'gold_cny']

mom = R.mom
ma = R.ma
above = R.above
normalize = R.normalize
metrics = R.metrics
all_metrics = R.all_metrics
topdds = R.topdds

FOCUS = {
    '2004_slow_recovery': (dt.date(2004, 1, 1), dt.date(2005, 12, 31)),
    '2020_fast_crash': (dt.date(2020, 2, 1), dt.date(2020, 4, 30)),
    '2026_ai_recovery': (dt.date(2025, 12, 1), None),
}


def count(ctx: Dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def rolling_low(v, i: int, n: int, exclude_current: bool = True):
    end = i if exclude_current else i + 1
    start = max(0, end - n)
    if end - start < 5:
        return None
    return min(v[start:end])


def rolling_high(v, i: int, n: int, exclude_current: bool = True):
    end = i if exclude_current else i + 1
    start = max(0, end - n)
    if end - start < 5:
        return None
    return max(v[start:end])


def trend_ok_asset(p, s: str, i: int, ma_n: int, mom_n: int, th: float = 0.0) -> bool:
    return above(p, s, i, ma_n) and (mom(p[s], i, mom_n) or -9) > th


def bounce_stage(p, s: str, i: int, style: str) -> int:
    """0..3 staged recovery signal after a stop/crisis.

    The stages deliberately use short/medium rebound confirmation instead of a
    new 126-day high, because that is exactly where E02 misses fast rebounds.
    """
    m3 = mom(p[s], i, 3) or 0.0
    m5 = mom(p[s], i, 5) or 0.0
    m10 = mom(p[s], i, 10) or 0.0
    m21 = mom(p[s], i, 21) or 0.0
    m63 = mom(p[s], i, 63) or 0.0
    l21 = rolling_low(p[s], i, 21, exclude_current=False)
    l63 = rolling_low(p[s], i, 63, exclude_current=False)
    rebound21 = p[s][i] / l21 - 1 if l21 else 0.0
    rebound63 = p[s][i] / l63 - 1 if l63 else 0.0

    if s == 'gold_cny' and R.gold_liquidity_trap(p, i):
        return 0

    if s == 'nasdaq':
        if style == 'fast':
            st = 0
            if (m3 > 0.018 and m5 > -0.010) or m5 > 0.030 or rebound21 > 0.045:
                st = 1
            if (m5 > 0.045 and above(p, s, i, 10)) or (m10 > 0.060) or (rebound21 > 0.075 and above(p, s, i, 10)):
                st = 2
            if (m10 > 0.070 and above(p, s, i, 20)) or (m21 > 0.080 and above(p, s, i, 20)):
                st = 3
            return st
        if style == 'conservative':
            st = 0
            if m5 > 0.040 and above(p, s, i, 10):
                st = 1
            if m10 > 0.070 and above(p, s, i, 20) and m21 > 0:
                st = 2
            if m21 > 0.100 and above(p, s, i, 40) and m63 > -0.08:
                st = 3
            return st
        # balanced
        st = 0
        if (m5 > 0.032 and above(p, s, i, 10)) or rebound21 > 0.050:
            st = 1
        if (m10 > 0.055 and above(p, s, i, 20)) or (rebound63 > 0.090 and above(p, s, i, 20)):
            st = 2
        if (m21 > 0.075 and above(p, s, i, 40)) or (m10 > 0.080 and above(p, s, i, 20) and m63 > -0.12):
            st = 3
        return st

    # gold_cny: slower/lower staged rebuild, with trap filter above.
    if style == 'fast':
        st = 0
        if m5 > 0.018 or rebound21 > 0.030:
            st = 1
        if m10 > 0.032 and above(p, s, i, 10):
            st = 2
        if m21 > 0.045 and above(p, s, i, 20):
            st = 3
        return st
    if style == 'conservative':
        st = 0
        if m5 > 0.025 and above(p, s, i, 10):
            st = 1
        if m10 > 0.045 and above(p, s, i, 20):
            st = 2
        if m21 > 0.060 and above(p, s, i, 40):
            st = 3
        return st
    st = 0
    if (m5 > 0.020 and above(p, s, i, 10)) or rebound21 > 0.035:
        st = 1
    if m10 > 0.038 and above(p, s, i, 20):
        st = 2
    if m21 > 0.055 and above(p, s, i, 40):
        st = 3
    return st


def stage_weight(s: str, stage: int, aggressiveness: str) -> float:
    if stage <= 0:
        return 0.0
    if aggressiveness == 'small':
        table = {'nasdaq': [0.00, 0.14, 0.26, 0.40], 'gold_cny': [0.00, 0.12, 0.22, 0.34]}
    elif aggressiveness == 'large':
        table = {'nasdaq': [0.00, 0.24, 0.42, 0.58], 'gold_cny': [0.00, 0.18, 0.32, 0.42]}
    else:
        table = {'nasdaq': [0.00, 0.18, 0.34, 0.52], 'gold_cny': [0.00, 0.14, 0.26, 0.40]}
    return table[s][stage]


def recovery_buy_ok(p, s: str, i: int, style: str) -> bool:
    """Non-breakout recovery buy used after the E02 cooldown expires.

    This is intentionally weaker than a 126-day high, but still requires the
    instrument to reclaim short/medium trend and rebound from a recent low.
    """
    l63 = rolling_low(p[s], i, 63, exclude_current=False)
    h126 = rolling_high(p[s], i, 126, exclude_current=True)
    rebound = p[s][i] / l63 - 1 if l63 else 0.0
    under_old_high = h126 is not None and p[s][i] < h126 * 1.002
    if not under_old_high:
        return False
    if s == 'gold_cny' and R.gold_liquidity_trap(p, i):
        return False
    if s == 'nasdaq':
        if style == 'conservative':
            return rebound > 0.12 and above(p, s, i, 40) and (mom(p[s], i, 21) or 0) > 0.055 and (mom(p[s], i, 126) or -9) > -0.18
        if style == 'fast':
            return rebound > 0.075 and above(p, s, i, 20) and (mom(p[s], i, 10) or 0) > 0.035 and (mom(p[s], i, 63) or -9) > -0.20
        return rebound > 0.09 and above(p, s, i, 30) and (mom(p[s], i, 21) or 0) > 0.040 and (mom(p[s], i, 63) or -9) > -0.18
    if style == 'conservative':
        return rebound > 0.075 and above(p, s, i, 40) and (mom(p[s], i, 21) or 0) > 0.035
    if style == 'fast':
        return rebound > 0.045 and above(p, s, i, 20) and (mom(p[s], i, 10) or 0) > 0.020
    return rebound > 0.060 and above(p, s, i, 30) and (mom(p[s], i, 21) or 0) > 0.030


def make_reentry_variant(
    name: str,
    style: str = 'balanced',
    aggressiveness: str = 'medium',
    after_days: int = 90,
    crisis_days: int = 45,
    crisis_trim: str = 'none',
    allow_late_recovery: bool = True,
    residual: bool = False,
    gross_cap: float = 0.92,
) -> Callable:
    """Wrap E02 with a stateful staged re-entry layer."""
    base = R.base_e02()

    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        pre_w = dict(ctx.get('sig_w', {}))
        pre_cool = {s: st.get(f'{s}_cool', 0) for s in HOLDINGS}
        target = base(dates, p, i, ctx) or {}

        # Age re-entry windows after base has applied its own stop/cooldown.
        for s in HOLDINGS:
            st[f'{s}_after_stop'] = max(0, st.get(f'{s}_after_stop', 0) - 1)
            if st.get(f'{s}_after_stop', 0) > 0:
                low_key = f'{s}_stop_low'
                st[low_key] = min(st.get(low_key, p[s][i]), p[s][i])

        # Detect a fresh E02 full stop (weight existed yesterday, target is now zero and cooldown jumped).
        for s in HOLDINGS:
            if pre_w.get(s, 0.0) > 0.03 and target.get(s, 0.0) <= 0.03 and st.get(f'{s}_cool', 0) >= max(pre_cool.get(s, 0), 1):
                st[f'{s}_after_stop'] = max(st.get(f'{s}_after_stop', 0), after_days)
                st[f'{s}_stop_low'] = p[s][i]
                st[f'{s}_reentry_stage'] = 0
                count(ctx, f'{name}_fresh_stop_{s}')
                if residual and trend_ok_asset(p, s, i, 80 if s == 'nasdaq' else 60, 21, -0.04):
                    # Keep a token sleeve instead of going all the way to cash, but only if short trend is not broken.
                    target[s] = max(target.get(s, 0.0), 0.08 if s == 'nasdaq' else 0.10)
                    count(ctx, f'{name}_residual_{s}')

        # Crisis is a re-entry watch state, not necessarily an immediate full-cash exit.
        if R.spx_liquidity_shock(p, i):
            st['crisis_watch'] = max(st.get('crisis_watch', 0), crisis_days)
            count(ctx, f'{name}_crisis_watch')
            # Keep recovery windows alive for both sleeves so a bounce can rebuild before 126d breakout.
            for s in HOLDINGS:
                st[f'{s}_after_stop'] = max(st.get(f'{s}_after_stop', 0), min(after_days, crisis_days + 15))
                st[f'{s}_stop_low'] = min(st.get(f'{s}_stop_low', p[s][i]), p[s][i])
        st['crisis_watch'] = max(0, st.get('crisis_watch', 0) - 1)

        # Optional trim during the shock leg; unlike R01/R04 it avoids a hard full-cash exit.
        if st.get('crisis_watch', 0) > 0 and crisis_trim != 'none':
            if crisis_trim == 'light':
                target['nasdaq'] = min(target.get('nasdaq', 0.0), 0.34)
                target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.30)
            elif crisis_trim == 'hard':
                target['nasdaq'] = min(target.get('nasdaq', 0.0), 0.18)
                target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.22)
            count(ctx, f'{name}_crisis_trim_{crisis_trim}')

        # Staged re-entry inside the stop/crisis window.
        for s in HOLDINGS:
            if target.get(s, 0.0) <= 0.03 and st.get(f'{s}_after_stop', 0) > 0:
                stage = bounce_stage(p, s, i, style)
                if stage > 0:
                    st[f'{s}_reentry_stage'] = max(st.get(f'{s}_reentry_stage', 0), stage)
                    target[s] = max(target.get(s, 0.0), stage_weight(s, st[f'{s}_reentry_stage'], aggressiveness))
                    count(ctx, f'{name}_stage{st[f"{s}_reentry_stage"]}_{s}')
            elif target.get(s, 0.0) > 0.03:
                # If E02 is already in, allow a same-window ramp when bounce confirmation strengthens.
                if st.get(f'{s}_after_stop', 0) > 0:
                    stage = bounce_stage(p, s, i, style)
                    if stage > st.get(f'{s}_reentry_stage', 0):
                        st[f'{s}_reentry_stage'] = stage
                        target[s] = max(target.get(s, 0.0), stage_weight(s, stage, aggressiveness))
                        count(ctx, f'{name}_ramp_stage{stage}_{s}')

        # After the E02 cooldown expires, do not require a new 126-day high if a clear repair is underway.
        if allow_late_recovery:
            for s in HOLDINGS:
                if target.get(s, 0.0) <= 0.03 and st.get(f'{s}_cool', 0) == 0 and recovery_buy_ok(p, s, i, style):
                    w = 0.40 if s == 'nasdaq' else 0.32
                    if aggressiveness == 'large':
                        w = 0.50 if s == 'nasdaq' else 0.40
                    elif aggressiveness == 'small':
                        w = 0.30 if s == 'nasdaq' else 0.26
                    target[s] = max(target.get(s, 0.0), w)
                    count(ctx, f'{name}_late_recovery_{s}')

        # Avoid combining a full Nasdaq rebuild with hot/rolling-over gold.
        if R.gold_liquidity_trap(p, i):
            if target.get('gold_cny', 0.0) > 0.03:
                count(ctx, f'{name}_gold_trap_cut')
            target['gold_cny'] = 0.0

        return normalize(target, gross_cap)

    return fn


def structural_ok_for_nasdaq_reentry(p, i: int, strict: bool = False) -> bool:
    """Block re-entry in slow bear markets while allowing fast V-shock repair."""
    nq126 = mom(p['nasdaq'], i, 126) or -9.0
    nq252 = mom(p['nasdaq'], i, 252) or -9.0
    sp126 = mom(p['sp500'], i, 126) or -9.0
    # Must not be deeply below medium-term trend; 2020/2026 pass early, 2008/2022 later legs fail.
    m120 = ma(p['nasdaq'], i, 120)
    m200 = ma(p['nasdaq'], i, 200)
    near_medium = (m120 is not None and p['nasdaq'][i] > m120 * (0.88 if not strict else 0.94))
    long_not_dead = nq252 > (-0.22 if not strict else -0.10)
    medium_not_dead = nq126 > (-0.16 if not strict else -0.06) or sp126 > (-0.12 if not strict else -0.05)
    reclaim = above(p, 'nasdaq', i, 20) and (mom(p['nasdaq'], i, 21) or 0) > (0.045 if strict else 0.025)
    return long_not_dead and medium_not_dead and (near_medium or reclaim or (m200 is not None and p['nasdaq'][i] > m200))


def fast_shock_anchor_ok(p, i: int) -> bool:
    """Was this shock a fast break from a still-healthy tape, rather than a mature bear?"""
    return (
        ((mom(p['nasdaq'], i, 126) or -9) > -0.08 or above(p, 'nasdaq', i, 160))
        and ((mom(p['nasdaq'], i, 252) or -9) > -0.12 or above(p, 'sp500', i, 200))
    )


def make_nasdaq_only_reentry(
    name: str,
    style: str = 'balanced',
    aggressiveness: str = 'medium',
    after_days: int = 80,
    crisis_days: int = 35,
    crisis_enabled: bool = False,
    strict_structural: bool = False,
    late_recovery: bool = True,
    pdd_cap: float | None = None,
    gross_cap: float = 0.92,
    pdd_trim: tuple[float, float] | None = None,
    tight_reentry_exit: bool = False,
) -> Callable:
    """E02 wrapper that only re-enters Nasdaq; gold remains pure base E02.

    The earlier all-sleeve re-entry tests solved 2020 but accidentally bought
    gold in 2008/2022 bear legs.  This isolates the intended mechanism: restore
    growth exposure after a stopped fast crash, while keeping gold's original
    E02 stop/take behaviour.
    """
    base = R.base_e02()

    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        pre_w = dict(ctx.get('sig_w', {}))
        pre_cool = st.get('nasdaq_cool', 0)
        target = base(dates, p, i, ctx) or {}

        st['nq_after_stop'] = max(0, st.get('nq_after_stop', 0) - 1)
        st['nq_reentry_active'] = max(0, st.get('nq_reentry_active', 0) - 1)
        if st.get('nq_after_stop', 0) > 0:
            st['nq_stop_low'] = min(st.get('nq_stop_low', p['nasdaq'][i]), p['nasdaq'][i])

        # Fresh E02 Nasdaq stop: open a finite recovery window.
        if pre_w.get('nasdaq', 0.0) > 0.03 and target.get('nasdaq', 0.0) <= 0.03 and st.get('nasdaq_cool', 0) >= max(pre_cool, 1):
            st['nq_after_stop'] = max(st.get('nq_after_stop', 0), after_days)
            st['nq_stop_low'] = p['nasdaq'][i]
            st['nq_reentry_stage'] = 0
            st['nq_reentry_entry'] = None
            st['nq_reentry_high'] = None
            count(ctx, f'{name}_fresh_stop_nasdaq')

        # Optional fast-shock watch: enabled only while the crash still looks like a fast dislocation.
        if crisis_enabled and R.spx_liquidity_shock(p, i) and fast_shock_anchor_ok(p, i):
            st['nq_crisis_watch'] = max(st.get('nq_crisis_watch', 0), crisis_days)
            st['nq_after_stop'] = max(st.get('nq_after_stop', 0), min(after_days, crisis_days + 10))
            st['nq_stop_low'] = min(st.get('nq_stop_low', p['nasdaq'][i]), p['nasdaq'][i])
            count(ctx, f'{name}_fast_shock_watch')
        st['nq_crisis_watch'] = max(0, st.get('nq_crisis_watch', 0) - 1)

        # Re-entry is only allowed when the medium/long tape is not a mature bear.
        ok = structural_ok_for_nasdaq_reentry(p, i, strict_structural)
        if pdd_cap is not None and ctx.get('portfolio_dd', 0) > pdd_cap:
            ok = False

        if target.get('nasdaq', 0.0) <= 0.03 and st.get('nq_after_stop', 0) > 0 and ok:
            stage = bounce_stage(p, 'nasdaq', i, style)
            if stage > 0:
                st['nq_reentry_stage'] = max(st.get('nq_reentry_stage', 0), stage)
                target['nasdaq'] = max(target.get('nasdaq', 0.0), stage_weight('nasdaq', st['nq_reentry_stage'], aggressiveness))
                st['nq_reentry_active'] = max(st.get('nq_reentry_active', 0), 252)
                st['nq_reentry_entry'] = st.get('nq_reentry_entry') or p['nasdaq'][i]
                st['nq_reentry_high'] = max(st.get('nq_reentry_high', p['nasdaq'][i]), p['nasdaq'][i])
                count(ctx, f'{name}_stage{st["nq_reentry_stage"]}_nasdaq')
        elif target.get('nasdaq', 0.0) > 0.03 and st.get('nq_after_stop', 0) > 0 and ok:
            stage = bounce_stage(p, 'nasdaq', i, style)
            if stage > st.get('nq_reentry_stage', 0):
                st['nq_reentry_stage'] = stage
                target['nasdaq'] = max(target.get('nasdaq', 0.0), stage_weight('nasdaq', stage, aggressiveness))
                st['nq_reentry_active'] = max(st.get('nq_reentry_active', 0), 252)
                st['nq_reentry_entry'] = st.get('nq_reentry_entry') or p['nasdaq'][i]
                st['nq_reentry_high'] = max(st.get('nq_reentry_high', p['nasdaq'][i]), p['nasdaq'][i])
                count(ctx, f'{name}_ramp_stage{stage}_nasdaq')

        # Late repair buy after cooldown: still Nasdaq-only and structurally gated.
        if late_recovery and target.get('nasdaq', 0.0) <= 0.03 and st.get('nasdaq_cool', 0) == 0 and ok and recovery_buy_ok(p, 'nasdaq', i, style):
            w = 0.36 if aggressiveness == 'medium' else 0.46 if aggressiveness == 'large' else 0.28
            target['nasdaq'] = max(target.get('nasdaq', 0.0), w)
            st['nq_reentry_active'] = max(st.get('nq_reentry_active', 0), 252)
            st['nq_reentry_entry'] = st.get('nq_reentry_entry') or p['nasdaq'][i]
            st['nq_reentry_high'] = max(st.get('nq_reentry_high', p['nasdaq'][i]), p['nasdaq'][i])
            count(ctx, f'{name}_late_recovery_nasdaq')

        # Optional tighter exit for positions that were opened by the re-entry layer.
        # This tries to keep the 2020/2026 rebound capture while not carrying the
        # same repaired sleeve deep into 2008/2022-style trend failures.
        if tight_reentry_exit and target.get('nasdaq', 0.0) > 0.03 and st.get('nq_reentry_active', 0) > 0:
            entry = st.get('nq_reentry_entry') or p['nasdaq'][i]
            high = max(st.get('nq_reentry_high', p['nasdaq'][i]), p['nasdaq'][i])
            st['nq_reentry_entry'] = entry
            st['nq_reentry_high'] = high
            px = p['nasdaq'][i]
            trail_hit = px <= high * 0.88 and high >= entry * 1.12
            momentum_hit = ((mom(p['nasdaq'], i, 21) or 0) < -0.070 and not above(p, 'nasdaq', i, 50)) or ((mom(p['nasdaq'], i, 10) or 0) < -0.055 and not above(p, 'nasdaq', i, 20))
            profit_roll = px >= entry * 1.25 and ((mom(p['nasdaq'], i, 10) or 0) < -0.025 or not above(p, 'nasdaq', i, 20))
            if trail_hit or momentum_hit:
                target['nasdaq'] = 0.0
                st['nasdaq_cool'] = max(st.get('nasdaq_cool', 0), 18)
                st['nq_after_stop'] = max(st.get('nq_after_stop', 0), after_days)
                st['nq_reentry_active'] = 0
                st['nq_reentry_entry'] = None
                st['nq_reentry_high'] = None
                count(ctx, f'{name}_tight_reentry_exit')
            elif profit_roll and target.get('nasdaq', 0.0) > 0.24:
                target['nasdaq'] = 0.24
                count(ctx, f'{name}_tight_reentry_harvest')

        # Optional drawdown trim: keep the re-entry idea, but do not let a repaired
        # Nasdaq sleeve grow into a full 2022-style drawdown without de-risking.
        if pdd_trim is not None and ctx.get('portfolio_dd', 0) > pdd_trim[0] and target.get('nasdaq', 0.0) > pdd_trim[1]:
            target['nasdaq'] = pdd_trim[1]
            count(ctx, f'{name}_pdd_trim_nasdaq')

        return normalize(target, gross_cap)

    return fn


CANDIDATES = [
    ('REF_E02_loose_from_011', 'reference E02 breakout/chandelier loose', R.base_e02()),
    ('NQ01_balanced_stop_reentry', 'E02 + Nasdaq-only staged re-entry after actual E02 stop', make_nasdaq_only_reentry('NQ01', 'balanced', 'medium', 80, 0, False, False, True, None, 0.92)),
    ('NQ02_fast_stop_reentry', 'E02 + Nasdaq-only fast staged re-entry after actual E02 stop', make_nasdaq_only_reentry('NQ02', 'fast', 'medium', 80, 0, False, False, True, None, 0.92)),
    ('NQ03_conservative_stop_reentry', 'E02 + Nasdaq-only conservative staged re-entry after actual E02 stop', make_nasdaq_only_reentry('NQ03', 'conservative', 'medium', 80, 0, False, True, True, None, 0.92)),
    ('NQ04_fast_shock_reentry', 'E02 + Nasdaq-only staged re-entry after stop or anchored fast-shock watch', make_nasdaq_only_reentry('NQ04', 'fast', 'medium', 85, 35, True, False, True, None, 0.92)),
    ('NQ05_balanced_shock_reentry', 'E02 + Nasdaq-only balanced re-entry after stop or anchored fast-shock watch', make_nasdaq_only_reentry('NQ05', 'balanced', 'medium', 90, 35, True, False, True, None, 0.92)),
    ('NQ06_fast_small_shock_reentry', 'E02 + Nasdaq-only fast shock re-entry with smaller weights', make_nasdaq_only_reentry('NQ06', 'fast', 'small', 85, 35, True, False, True, None, 0.90)),
    ('NQ07_fast_shock_pdd_guard', 'E02 + Nasdaq-only fast shock re-entry blocked while portfolio DD > 9.5%', make_nasdaq_only_reentry('NQ07', 'fast', 'medium', 85, 35, True, False, True, 0.095, 0.92)),
    ('NQ08_fast_shock_strict', 'E02 + Nasdaq-only fast shock re-entry with stricter structural filter', make_nasdaq_only_reentry('NQ08', 'fast', 'medium', 85, 35, True, True, True, None, 0.92)),
    ('NQ09_fast_small_pdd_trim', 'E02 + Nasdaq-only fast/small re-entry + trim Nasdaq to 24% after 8.5% portfolio DD', make_nasdaq_only_reentry('NQ09', 'fast', 'small', 85, 35, True, False, True, None, 0.90, (0.085, 0.24))),
    ('NQ10_fast_small_tight_trim', 'E02 + Nasdaq-only fast/small re-entry + trim Nasdaq to 18% after 7.5% portfolio DD', make_nasdaq_only_reentry('NQ10', 'fast', 'small', 85, 35, True, False, True, None, 0.88, (0.075, 0.18))),
    ('NQ11_balanced_medium_trim', 'E02 + Nasdaq-only balanced/medium re-entry + trim Nasdaq to 24% after 8.5% portfolio DD', make_nasdaq_only_reentry('NQ11', 'balanced', 'medium', 90, 35, True, False, True, None, 0.90, (0.085, 0.24))),
    ('NQ12_fast_small_no_late_trim', 'E02 + Nasdaq-only fast/small during stop window only + 8.5% DD trim', make_nasdaq_only_reentry('NQ12', 'fast', 'small', 85, 35, True, False, False, None, 0.90, (0.085, 0.24))),
    ('NQ13_fast_small_soft_trim', 'E02 + Nasdaq-only fast/small re-entry + trim Nasdaq to 30% after 10% portfolio DD', make_nasdaq_only_reentry('NQ13', 'fast', 'small', 85, 35, True, False, True, None, 0.90, (0.100, 0.30))),
    ('NQ14_fast_small_late_trim', 'E02 + Nasdaq-only fast/small re-entry + trim Nasdaq to 34% after 10.5% portfolio DD', make_nasdaq_only_reentry('NQ14', 'fast', 'small', 85, 35, True, False, True, None, 0.90, (0.105, 0.34))),
    ('NQ15_fast_small_mid_trim', 'E02 + Nasdaq-only fast/small re-entry + trim Nasdaq to 30% after 9.5% portfolio DD', make_nasdaq_only_reentry('NQ15', 'fast', 'small', 85, 35, True, False, True, None, 0.90, (0.095, 0.30))),
    ('NQ16_fast_small_no_late_soft_trim', 'E02 + Nasdaq-only fast/small no late repair + trim Nasdaq to 30% after 10% portfolio DD', make_nasdaq_only_reentry('NQ16', 'fast', 'small', 85, 35, True, False, False, None, 0.90, (0.100, 0.30))),
    ('Q01_balanced_stage_reentry', 'E02 + staged re-entry after stop/crisis; balanced confirmation', make_reentry_variant('Q01', 'balanced', 'medium', 90, 45, 'none', True, False, 0.92)),
    ('Q02_fast_stage_reentry', 'E02 + faster smaller-confirmation staged re-entry', make_reentry_variant('Q02', 'fast', 'medium', 90, 45, 'none', True, False, 0.92)),
    ('Q03_conservative_stage_reentry', 'E02 + conservative staged re-entry', make_reentry_variant('Q03', 'conservative', 'medium', 90, 45, 'none', True, False, 0.92)),
    ('Q04_balanced_large_reentry', 'E02 + balanced staged re-entry with larger ramp weights', make_reentry_variant('Q04', 'balanced', 'large', 100, 50, 'none', True, False, 0.94)),
    ('Q05_fast_small_reentry', 'E02 + fast confirmation but smaller ramp weights', make_reentry_variant('Q05', 'fast', 'small', 90, 45, 'none', True, False, 0.88)),
    ('Q06_balanced_light_crisis_trim', 'E02 + staged re-entry + light crisis trim instead of cash exit', make_reentry_variant('Q06', 'balanced', 'medium', 90, 45, 'light', True, False, 0.90)),
    ('Q07_fast_light_crisis_trim', 'E02 + fast staged re-entry + light crisis trim', make_reentry_variant('Q07', 'fast', 'medium', 90, 45, 'light', True, False, 0.90)),
    ('Q08_balanced_residual_reentry', 'E02 + token residual on valid stop + staged re-entry', make_reentry_variant('Q08', 'balanced', 'medium', 90, 45, 'none', True, True, 0.92)),
    ('Q09_balanced_no_late_recovery', 'E02 + only during-cooldown/crisis staged re-entry, no late repair buy', make_reentry_variant('Q09', 'balanced', 'medium', 90, 45, 'none', False, False, 0.92)),
    ('Q10_long_window_reentry', 'E02 + staged re-entry with 160-day post-stop window', make_reentry_variant('Q10', 'balanced', 'medium', 160, 60, 'none', True, False, 0.92)),
    ('Q11_fast_long_large', 'E02 + fast long-window larger re-entry', make_reentry_variant('Q11', 'fast', 'large', 160, 60, 'none', True, False, 0.94)),
    ('Q12_hard_trim_then_reentry', 'E02 + hard crisis trim then staged re-entry', make_reentry_variant('Q12', 'balanced', 'medium', 120, 55, 'hard', True, False, 0.88)),
]


def value_at_or_after(dates, vals, day: dt.date):
    for d, v in zip(dates, vals):
        if d >= day:
            return d, v
    return dates[-1], vals[-1]


def recovery_snapshot(dates, vals, weights, peak_day: dt.date, trough_day: dt.date, end_day: dt.date):
    pd, pv = value_at_or_after(dates, vals, peak_day)
    td, tv = value_at_or_after(dates, vals, trough_day)
    ed, ev = value_at_or_after(dates, vals, end_day)
    wi = next(i for i, d in enumerate(dates) if d == td)
    return {
        'peak_day': str(pd),
        'trough_day': str(td),
        'end_day': str(ed),
        'peak_to_trough': tv / pv - 1 if pv else None,
        'trough_to_end': ev / tv - 1 if tv else None,
        'weight_at_trough': {k: round(v * 100, 1) for k, v in weights[wi].items()},
        'cash_at_trough': round((1 - sum(weights[wi].values())) * 100, 1),
    }


def row_for(dates, p, item):
    name, desc, fn = item
    vals, w, e = E.simulate_event(dates, p, fn, rebalance=1, band=0.02)
    m = all_metrics(dates, vals)
    row = {
        'name': name,
        'description': desc,
        'metrics': m,
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in Z.STRESS.items()},
        'focus': {k: metrics(dates, vals, a, b) for k, (a, b) in FOCUS.items()},
        'extra': e,
        'top_dd': topdds(dates, vals, w),
        'snapshots': {
            '2004_topdd_recovery': recovery_snapshot(dates, vals, w, dt.date(2004, 1, 12), dt.date(2005, 4, 15), dt.date(2005, 12, 30)),
            '2020_crash_recovery': recovery_snapshot(dates, vals, w, dt.date(2020, 2, 20), dt.date(2020, 3, 18), dt.date(2020, 4, 30)),
            '2026_ai_recovery': recovery_snapshot(dates, vals, w, dt.date(2026, 1, 28), dt.date(2026, 3, 30), dates[-1]),
        },
        'pass_12_8': m['full']['ann'] >= TARGET_ANN and m['full']['dd'] <= TARGET_DD,
    }
    bad = [s for ww in w for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    return row


def pct(x):
    return 'n/a' if x is None else f'{x * 100:.2f}%'


def fmt_m(m):
    return f"{m['ann'] * 100:.2f}/{m['dd'] * 100:.2f}"


def run():
    dates, p = CORE.align(CORE.fetch())
    rows = [row_for(dates, p, c) for c in CANDIDATES]
    OUT.write_text(
        json.dumps(
            {
                'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates)},
                'target': {'ann': TARGET_ANN, 'dd': TARGET_DD},
                'holdings_constraint': HOLDINGS + ['cash'],
                'rows': rows,
            },
            ensure_ascii=False,
            indent=2,
            default=str,
        )
    )
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates), 'holdings', HOLDINGS + ['cash'])
    print('\nSorted by full annualized:')
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']
        p20 = r['metrics']['post2020']
        ten = r['metrics']['teny']
        f20 = r['focus']['2020_fast_crash']
        f04 = r['focus']['2004_slow_recovery']
        f26 = r['focus']['2026_ai_recovery']
        mark = 'PASS' if r['pass_12_8'] else 'FAIL'
        print(
            mark,
            r['name'],
            f"full={fmt_m(m)}",
            f"post20={fmt_m(p20)}",
            f"teny={fmt_m(ten)}",
            f"2004={fmt_m(f04)}",
            f"2020={fmt_m(f20)}",
            f"2026={fmt_m(f26)}",
            'latest', {k: round(v * 100, 1) for k, v in r['extra']['latest'].items()},
            'cash', round(r['extra']['cash_pct'] * 100, 1),
            'trades', r['extra']['trades'],
            'events', r['extra'].get('events', {}),
        )
        print('  topdd', ' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
        for snap_name, snap in r['snapshots'].items():
            print(
                ' ', snap_name,
                f"pt={pct(snap['peak_to_trough'])}",
                f"rec={pct(snap['trough_to_end'])}",
                f"W_trough={snap['weight_at_trough']}",
                f"cash={snap['cash_at_trough']}",
            )
    print('\nBest dd<=12:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd'] <= 0.12], key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']
        print(r['name'], f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f}", 'trades', r['extra']['trades'])
    print('PASS_COUNT', sum(1 for r in rows if r['pass_12_8']))


if __name__ == '__main__':
    run()
