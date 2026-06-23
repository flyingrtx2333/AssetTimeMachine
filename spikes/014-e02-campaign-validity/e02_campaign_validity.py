#!/usr/bin/env python3
"""014: E02 campaign-level holding validity.

Hypothesis: E02's remaining full-cycle low-DD blocker is not entry quality;
it is holding a breakout campaign after the regime that justified it has gone stale.

Visible holdings: nasdaq, gold_cny, cash.
External series: sp500 as signal only.
No BTC, no new held assets, no parameter grid.
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
if spec is None or spec.loader is None:
    raise RuntimeError('Cannot load E11 spike module')
E = importlib.util.module_from_spec(spec)
sys.modules['E11'] = E
spec.loader.exec_module(E)  # type: ignore
Z = E.Z
CORE = E.CORE

OUT = Path('/tmp/atm_e02_campaign_validity_014.json')
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


def rare_liquidity_shock(p, i: int) -> bool:
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
        if m21 > 0.080 and above(p, s, i, 40): return 3
        if r63 > 0.090 or (m10 > 0.055 and above(p, s, i, 20)): return 2
        if r21 > 0.050: return 1
        return 0
    if gold_trap(p, i): return 0
    if m21 > 0.055 and above(p, s, i, 40): return 3
    if r63 > 0.060 or (m10 > 0.035 and above(p, s, i, 20)): return 2
    if r21 > 0.035: return 1
    return 0


def campaign_init_or_update(p, i: int, ctx: Dict[str, Any], w: Dict[str, float], target: Dict[str, float]) -> None:
    """Track campaign state using signal-date prices.

    This runs inside target_fn before execution; it records the signal context that
    caused a target to appear. The simulator then trades on T day.
    """
    st = ctx.setdefault('state', {})
    for s in HOLDINGS:
        was = w.get(s, 0.0) > 0.03
        will = target.get(s, 0.0) > 0.03
        if will and not was:
            st[f'{s}_campaign_start'] = i
            st[f'{s}_campaign_entry'] = p[s][i]
            st[f'{s}_campaign_high'] = p[s][i]
            st[f'{s}_campaign_confirmed'] = False
            st[f'{s}_invalid_until'] = 0
            st[f'{s}_entry_spx_above120'] = above(p, 'sp500', i, 120)
            st[f'{s}_entry_own_m126'] = mom(p[s], i, 126) or 0.0
            count(ctx, f'{s}_campaign_open')
        elif will and was:
            prev_high = st.get(f'{s}_campaign_high') or p[s][i]
            st[f'{s}_campaign_high'] = max(prev_high, p[s][i])
            entry = st.get(f'{s}_campaign_entry') or p[s][i]
            if entry > 0:
                gain = p[s][i] / entry - 1
                if gain > (0.08 if s == 'nasdaq' else 0.06):
                    st[f'{s}_campaign_confirmed'] = True
        elif not will:
            # Keep invalid_until, clear active campaign data.
            st[f'{s}_campaign_start'] = None
            st[f'{s}_campaign_entry'] = None
            st[f'{s}_campaign_high'] = None
            st[f'{s}_campaign_confirmed'] = False


def campaign_age(ctx: Dict[str, Any], s: str, i: int) -> int:
    start = ctx.setdefault('state', {}).get(f'{s}_campaign_start')
    return 0 if start is None else max(0, i - int(start))


def campaign_giveback(p, ctx: Dict[str, Any], s: str, i: int) -> float:
    st = ctx.setdefault('state', {})
    entry = st.get(f'{s}_campaign_entry')
    high = st.get(f'{s}_campaign_high')
    if not entry or not high or high <= entry:
        return 0.0
    max_gain = high / entry - 1
    cur_gain = p[s][i] / entry - 1
    return max(0.0, (max_gain - cur_gain) / max_gain) if max_gain > 0 else 0.0


def market_regime_lost(p, i: int) -> bool:
    return (not above(p, 'sp500', i, 120) and (mom(p['sp500'], i, 63) or 0) < -0.020) or (
        not above(p, 'sp500', i, 200) and (mom(p['sp500'], i, 126) or 0) < -0.030
    )


def own_regime_lost(p, s: str, i: int) -> bool:
    if s == 'nasdaq':
        return (not above(p, s, i, 120) and (mom(p[s], i, 63) or 0) < -0.045) or (
            not above(p, s, i, 200) and (mom(p[s], i, 126) or 0) < -0.010
        )
    return gold_trap(p, i) or ((not above(p, s, i, 120)) and (mom(p[s], i, 21) or 0) < -0.030 and (mom(p[s], i, 63) or 0) < 0.010)


def base_e02():
    return E.E02_breakout_chandelier('loose')


def wrap_campaign(name: str, decision: Callable[[Any, str, int, Dict[str, Any], Dict[str, float], Dict[str, float]], Dict[str, float] | None]):
    base = base_e02()
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        w = ctx.get('sig_w', {})
        target = base(dates, p, i, ctx) or {}
        campaign_init_or_update(p, i, ctx, w, target)
        for s in HOLDINGS:
            st[f'{s}_invalid_until'] = max(0, st.get(f'{s}_invalid_until', 0) - 1)
            if st.get(f'{s}_invalid_until', 0) > 0 and target.get(s, 0.0) > 0.03:
                # Do not allow immediate re-open while the just-invalidated campaign is cooling off.
                target[s] = 0.0
        changed = decision(p, name, i, ctx, w, target)
        if changed is not None:
            target = changed
        return normalize(target, 0.90)
    return fn


# Mechanism 1: validated campaign expiry.
# If a confirmed campaign gives back most of its profit and both own + market regime are stale,
# expire only that sleeve, with a cooldown so it needs a fresh campaign.
def C01_confirmed_giveback_expiry(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = dict(target)
    changed = False
    for s in HOLDINGS:
        if out.get(s, 0.0) <= 0.03:
            continue
        confirmed = st.get(f'{s}_campaign_confirmed', False)
        giveback = campaign_giveback(p, ctx, s, i)
        if confirmed and giveback > (0.62 if s == 'nasdaq' else 0.58) and own_regime_lost(p, s, i) and (market_regime_lost(p, i) or s == 'gold_cny'):
            out[s] = 0.0
            st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), 35 if s == 'nasdaq' else 25)
            st[f'{s}_invalid_until'] = 35 if s == 'nasdaq' else 25
            count(ctx, f'{s}_confirmed_giveback_expiry')
            changed = True
    return out if changed else None


# Mechanism 2: unconfirmed campaign time stop.
# A breakout that does not get follow-through within a quarter is not allowed to remain high-gross.
def C02_unconfirmed_time_stop(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = dict(target)
    changed = False
    for s in HOLDINGS:
        if out.get(s, 0.0) <= 0.03:
            continue
        age = campaign_age(ctx, s, i)
        confirmed = st.get(f'{s}_campaign_confirmed', False)
        entry = st.get(f'{s}_campaign_entry') or p[s][i]
        underwater = p[s][i] < entry * (0.985 if s == 'nasdaq' else 0.990)
        if age > 63 and not confirmed and underwater and own_regime_lost(p, s, i):
            out[s] = 0.0
            st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), 28 if s == 'nasdaq' else 20)
            st[f'{s}_invalid_until'] = 28 if s == 'nasdaq' else 20
            count(ctx, f'{s}_unconfirmed_time_stop')
            changed = True
    return out if changed else None


# Mechanism 3: high-gross campaign budget expiry.
# If total gross is high and at least one sleeve's campaign is invalid, reduce only excess risk.
def C03_high_gross_campaign_budget(p, name, i, ctx, w, target):
    gross = sum(target.get(s, 0.0) for s in HOLDINGS)
    if gross < 0.72:
        return None
    invalid = [s for s in HOLDINGS if target.get(s, 0.0) > 0.03 and own_regime_lost(p, s, i)]
    if not invalid or not market_regime_lost(p, i):
        return None
    out = dict(target)
    if 'nasdaq' in invalid:
        out['nasdaq'] = min(out.get('nasdaq', 0.0), 0.24)
        count(ctx, 'nasdaq_high_gross_campaign_cap')
    if 'gold_cny' in invalid:
        out['gold_cny'] = min(out.get('gold_cny', 0.0), 0.24)
        count(ctx, 'gold_high_gross_campaign_cap')
    return out


# Mechanism 4: combine 1+2 but only as expiry, not continuous caps.
def C04_campaign_expiry_combo(p, name, i, ctx, w, target):
    out = C01_confirmed_giveback_expiry(p, name, i, ctx, w, target)
    out2 = C02_unconfirmed_time_stop(p, name, i, ctx, w, out if out is not None else target)
    return out2 if out2 is not None else out


# Mechanism 5: combo + rare shock cap, because prior work showed shock cap fixes 2020.
def C05_campaign_expiry_plus_shock(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = C04_campaign_expiry_combo(p, name, i, ctx, w, target)
    out = dict(target if out is None else out)
    changed = out != target
    if rare_liquidity_shock(p, i):
        st['shock_cool'] = max(st.get('shock_cool', 0), 7)
        count(ctx, 'rare_liquidity_shock')
    st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
    if st.get('shock_cool', 0) > 0:
        out['nasdaq'] = min(out.get('nasdaq', 0.0), 0.16)
        out['gold_cny'] = min(out.get('gold_cny', 0.0), 0.20 if gold_trap(p, i) else 0.26)
        changed = True
    return out if changed else None


# Mechanism 6: C02, but only for Nasdaq. Gold trend exits were often return-destructive.
def C06_nasdaq_only_unconfirmed_time_stop(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = dict(target)
    s = 'nasdaq'
    if out.get(s, 0.0) <= 0.03:
        return None
    age = campaign_age(ctx, s, i)
    confirmed = st.get(f'{s}_campaign_confirmed', False)
    entry = st.get(f'{s}_campaign_entry') or p[s][i]
    underwater = p[s][i] < entry * 0.985
    if age > 63 and not confirmed and underwater and own_regime_lost(p, s, i):
        out[s] = 0.0
        st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), 28)
        st[f'{s}_invalid_until'] = 28
        count(ctx, 'nasdaq_only_unconfirmed_time_stop')
        return out
    return None


# Mechanism 7: unconfirmed campaign soft stop. Reduce exposure instead of exiting, so recovery is not missed.
def C07_unconfirmed_soft_stop(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = dict(target)
    changed = False
    for s in HOLDINGS:
        if out.get(s, 0.0) <= 0.03:
            continue
        age = campaign_age(ctx, s, i)
        confirmed = st.get(f'{s}_campaign_confirmed', False)
        entry = st.get(f'{s}_campaign_entry') or p[s][i]
        underwater = p[s][i] < entry * (0.985 if s == 'nasdaq' else 0.990)
        if age > 63 and not confirmed and underwater and own_regime_lost(p, s, i):
            out[s] = min(out.get(s, 0.0), 0.20 if s == 'nasdaq' else 0.24)
            count(ctx, f'{s}_unconfirmed_soft_stop')
            changed = True
    return out if changed else None


# Mechanism 8: C02 plus rare shock cap, without the over-aggressive C01 giveback exit.
def C08_unconfirmed_time_stop_plus_shock(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = C02_unconfirmed_time_stop(p, name, i, ctx, w, target)
    out = dict(target if out is None else out)
    changed = out != target
    if rare_liquidity_shock(p, i):
        st['shock_cool'] = max(st.get('shock_cool', 0), 7)
        count(ctx, 'rare_liquidity_shock')
    st['shock_cool'] = max(0, st.get('shock_cool', 0) - 1)
    if st.get('shock_cool', 0) > 0:
        out['nasdaq'] = min(out.get('nasdaq', 0.0), 0.16)
        out['gold_cny'] = min(out.get('gold_cny', 0.0), 0.20 if gold_trap(p, i) else 0.26)
        changed = True
    return out if changed else None


# Mechanism 9: C02 plus staged rebuild after the invalidated campaign has cooled.
def C09_unconfirmed_time_stop_with_rebuild(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = C02_unconfirmed_time_stop(p, name, i, ctx, w, target)
    out = dict(target if out is None else out)
    changed = out != target
    for s in HOLDINGS:
        if out.get(s, 0.0) <= 0.03 and st.get(f'{s}_invalid_until', 0) == 0:
            stage = recovery_stage(p, s, i)
            if s == 'nasdaq' and stage >= 3 and above(p, 'sp500', i, 80):
                out[s] = 0.30
                count(ctx, 'nasdaq_campaign_rebuild')
                changed = True
            elif s == 'gold_cny' and stage >= 2 and not gold_trap(p, i):
                out[s] = 0.26
                count(ctx, 'gold_campaign_rebuild')
                changed = True
    return out if changed else None


# Mechanism 10: only stop unconfirmed campaigns when the portfolio is high-gross.
def C10_high_gross_unconfirmed_time_stop(p, name, i, ctx, w, target):
    gross = sum(target.get(s, 0.0) for s in HOLDINGS)
    if gross < 0.72:
        return None
    return C02_unconfirmed_time_stop(p, name, i, ctx, w, target)


# Mechanism 11: campaign score, but stateful cooldown. This is not a parameter grid;
# score is a hand-written validity checklist: follow-through, own trend, market regime.
def C11_campaign_validity_score(p, name, i, ctx, w, target):
    st = ctx.setdefault('state', {})
    out = dict(target)
    changed = False
    gross = sum(target.get(s, 0.0) for s in HOLDINGS)
    for s in HOLDINGS:
        if out.get(s, 0.0) <= 0.03:
            continue
        score = 0
        age = campaign_age(ctx, s, i)
        entry = st.get(f'{s}_campaign_entry') or p[s][i]
        if p[s][i] > entry * (1.04 if s == 'nasdaq' else 1.03): score += 1
        if above(p, s, i, 80): score += 1
        if above(p, s, i, 160): score += 1
        if s == 'nasdaq' and above(p, 'sp500', i, 120): score += 1
        if s == 'gold_cny' and not gold_trap(p, i): score += 1
        if own_regime_lost(p, s, i): score -= 2
        if market_regime_lost(p, i) and s == 'nasdaq': score -= 1
        if campaign_giveback(p, ctx, s, i) > 0.65: score -= 1
        # Only act on aged campaigns or high-gross portfolios; avoid killing fresh breakouts.
        if score <= 0 and (age > 63 or gross > 0.72):
            out[s] = min(out.get(s, 0.0), 0.18 if s == 'nasdaq' else 0.22)
            count(ctx, f'{s}_campaign_score_cap')
            changed = True
        if score < -1 and age > 84:
            out[s] = 0.0
            st[f'{s}_cool'] = max(st.get(f'{s}_cool', 0), 25 if s == 'nasdaq' else 18)
            st[f'{s}_invalid_until'] = 25 if s == 'nasdaq' else 18
            count(ctx, f'{s}_campaign_score_exit')
            changed = True
    return out if changed else None


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
        'candidate_lowdd': m['full']['ann'] >= 0.075 and m['full']['dd'] <= 0.105,
        'candidate_frontier': m['full']['ann'] >= 0.078 and m['full']['dd'] < 0.1138,
    }


def main():
    dates, p = CORE.align(CORE.fetch())
    strategies = [
        ('REF_E02_loose', '011 reference: breakout + chandelier + rollover take-profit', base_e02()),
        ('C01_confirmed_giveback_expiry', 'expire confirmed campaigns after large giveback + lost regime', wrap_campaign('C01', C01_confirmed_giveback_expiry)),
        ('C02_unconfirmed_time_stop', 'time-stop unconfirmed breakout campaigns that go underwater', wrap_campaign('C02', C02_unconfirmed_time_stop)),
        ('C03_high_gross_campaign_budget', 'cap excess only when high gross exposure has invalid campaign', wrap_campaign('C03', C03_high_gross_campaign_budget)),
        ('C04_campaign_expiry_combo', 'combine confirmed giveback expiry + unconfirmed time stop', wrap_campaign('C04', C04_campaign_expiry_combo)),
        ('C05_campaign_expiry_plus_shock', 'campaign expiry combo + rare liquidity shock cap', wrap_campaign('C05', C05_campaign_expiry_plus_shock)),
        ('C06_nasdaq_only_unconfirmed_time_stop', 'C02 but only stop Nasdaq unconfirmed campaigns', wrap_campaign('C06', C06_nasdaq_only_unconfirmed_time_stop)),
        ('C07_unconfirmed_soft_stop', 'soft cap unconfirmed campaigns instead of exiting', wrap_campaign('C07', C07_unconfirmed_soft_stop)),
        ('C08_unconfirmed_time_stop_plus_shock', 'C02 unconfirmed stop plus rare liquidity shock cap', wrap_campaign('C08', C08_unconfirmed_time_stop_plus_shock)),
        ('C09_unconfirmed_time_stop_with_rebuild', 'C02 unconfirmed stop plus staged campaign rebuild', wrap_campaign('C09', C09_unconfirmed_time_stop_with_rebuild)),
        ('C10_high_gross_unconfirmed_time_stop', 'C02 only when portfolio gross exposure is high', wrap_campaign('C10', C10_high_gross_unconfirmed_time_stop)),
        ('C11_campaign_validity_score', 'stateful campaign validity checklist score', wrap_campaign('C11', C11_campaign_validity_score)),
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
        mark = 'PASS12/8' if r['pass_12_8'] else ('LOWDD' if r['candidate_lowdd'] else ('FRONTIER' if r['candidate_frontier'] else 'FAIL'))
        latest = {k: round(v * 100, 1) for k, v in r['extra'].get('latest', {}).items()}
        print(f"{mark:8s} {r['name']:36s} full {pct(m['ann'])}/{pct(m['dd'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"          post20 {pct(p20['ann'])}/{pct(p20['dd'])} tenY {pct(ten['ann'])}/{pct(ten['dd'])} post22 {pct(p22['ann'])}/{pct(p22['dd'])}")
        print(f"          latest={latest} cash={pct(r['extra'].get('cash_pct', 0))} trades={r['extra'].get('trades')} events={r['extra'].get('events', {})}")
        print('          topdd ' + ' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))


if __name__ == '__main__':
    main()
