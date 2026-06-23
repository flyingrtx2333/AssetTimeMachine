#!/usr/bin/env python3
from __future__ import annotations

"""
012 focused spike: preserve high-yield M13/M34 while controlling tail risk.

Constraints:
- holdings are only nasdaq / gold_cny / cash
- no new held assets, no parameter grid
- compare a few mechanism-driven monthly rules, avoiding the daily stop/take churn seen in 011
"""

import importlib.util
import json
import sys
from pathlib import Path
from typing import Callable, Any

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')

spec = importlib.util.spec_from_file_location(
    'E11', ROOT / 'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py'
)
assert spec is not None and spec.loader is not None
E = importlib.util.module_from_spec(spec)
sys.modules['E11'] = E
spec.loader.exec_module(E)  # type: ignore

Z = E.Z
CORE = E.CORE
OUT = Path('/tmp/atm_m13_m34_tail_control_012.json')
HOLDINGS = ['nasdaq', 'gold_cny']
BASE_M13 = {'nasdaq': 0.25, 'gold_cny': 0.35}
TARGET_DD = 0.12  # this spike asks for less tail, not a hard 8% pass/fail search

pct = Z.pct
mom = Z.mom
ma = Z.ma
above = Z.above
score_asset = Z.score_asset
positive_6m = Z.positive_6m
realized_vol = Z.realized_vol
virtual_barbell = Z.virtual_barbell
virtual_ma = Z.virtual_ma
virtual_mom = Z.virtual_mom
barbell_health_state = Z.barbell_health_state
normalize = Z.normalize
metrics = Z.metrics
all_metrics = Z.all_metrics
topdds = Z.topdds


def count(ctx: dict[str, Any], name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def dd_asset(p: dict[str, list[float]], s: str, i: int, n: int) -> float:
    if i - n + 1 < 0:
        return 0.0
    window = p[s][i - n + 1:i + 1]
    h = max(window)
    return p[s][i] / h - 1 if h else 0.0


def vb_dd(p: dict[str, list[float]], i: int, n: int = 252) -> float:
    if i - n + 1 < 0:
        return 0.0
    vals = [virtual_barbell(p, j, 0.5, 0.5) for j in range(i - n + 1, i + 1)]
    h = max(vals)
    return vals[-1] / h - 1 if h else 0.0


def vb_recovered(p: dict[str, list[float]], i: int) -> bool:
    vb = virtual_barbell(p, i, 0.5, 0.5)
    m80 = virtual_ma(p, i, 80, 0.5, 0.5)
    m160 = virtual_ma(p, i, 160, 0.5, 0.5)
    return m80 is not None and m160 is not None and vb > m80 > m160 and (virtual_mom(p, i, 42, 0.5, 0.5) or 0) > 0


def own_recovered(p: dict[str, list[float]], s: str, i: int) -> bool:
    return above(p, s, i, 120) and (mom(p[s], i, 63) or 0) > 0.04


def blowoff_rollover(p: dict[str, list[float]], s: str, i: int) -> bool:
    # Deliberately sparse: only after a large 12m run and visible rollover.
    if s == 'nasdaq':
        run = (mom(p[s], i, 252) or 0) > 0.36
        roll = (mom(p[s], i, 21) or 0) < -0.045 or dd_asset(p, s, i, 63) < -0.095
        broken = not above(p, s, i, 80)
    else:
        run = (mom(p[s], i, 252) or 0) > 0.24
        roll = (mom(p[s], i, 21) or 0) < -0.035 or dd_asset(p, s, i, 63) < -0.075
        broken = not above(p, s, i, 60)
    return run and roll and broken


def liquidity_air_pocket(p: dict[str, list[float]], s: str, i: int) -> bool:
    # Monthly signal, not daily stop: require fast loss plus trend damage.
    if s == 'nasdaq':
        return ((mom(p[s], i, 21) or 0) < -0.105 and not above(p, s, i, 120)) or dd_asset(p, s, i, 126) < -0.22
    return ((mom(p[s], i, 21) or 0) < -0.070 and (mom(p[s], i, 126) or 0) > 0.12) or (dd_asset(p, s, i, 126) < -0.16 and not above(p, s, i, 100))


def base_or_current_m13(dates, p, i, ctx) -> tuple[dict[str, float], bool]:
    """Correct M13 overlay semantics: None means hold current, not cash."""
    w = ctx.get('sig_w', {})
    base = Z.M13_rebalance_harvest_rebuild(dates, p, i, ctx)
    if base is not None:
        return dict(base), True
    return dict(w), False


def sameish(a: dict[str, float], b: dict[str, float], tol: float = 0.002) -> bool:
    for s in HOLDINGS:
        if abs(a.get(s, 0.0) - b.get(s, 0.0)) > tol:
            return False
    return True


# ---- Candidate logic 1: only hedge tails after sleeve blowoff ----
def T01_M13_blowoff_tail_hedge():
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        w = ctx.get('sig_w', {})
        target, changed = base_or_current_m13(dates, p, i, ctx)
        for s in HOLDINGS:
            key = f'T01_{s}_cool'
            st[key] = max(0, st.get(key, 0) - 1)
            if blowoff_rollover(p, s, i):
                st[key] = max(st.get(key, 0), 3 if s == 'nasdaq' else 2)
                count(ctx, f'T01_{s}_blowoff_tail')
            if st.get(key, 0) > 0:
                # Tail hedge only trims the overheated sleeve back toward base; it does not abandon the barbell.
                cap = 0.22 if s == 'nasdaq' else 0.26
                if (target.get(s, w.get(s, 0.0)) or 0.0) > cap:
                    target[s] = cap
                    changed = True
            if st.get(key, 0) > 0 and own_recovered(p, s, i):
                st[key] = 0
        return normalize(target, 0.92) if changed and not sameish(target, w) else None
    return fn


# ---- Candidate logic 2: portfolio drawdown trims only excess drift, never base sleeves ----
def T02_M13_excess_drift_pdd_trim():
    def fn(dates, p, i, ctx):
        w = ctx.get('sig_w', {})
        target, changed = base_or_current_m13(dates, p, i, ctx)
        pdd = ctx.get('portfolio_dd', 0.0)
        barbell_bad = vb_dd(p, i, 126) < -0.065 or (virtual_mom(p, i, 42, 0.5, 0.5) or 0) < -0.045
        if pdd > 0.075 and barbell_bad:
            for s, b in BASE_M13.items():
                # Keep the base sleeve; sell only drift/satellite excess.
                if (target.get(s, w.get(s, 0.0)) or 0.0) > b:
                    target[s] = b
                    changed = True
            count(ctx, 'T02_pdd_trim_excess_only')
        if pdd > 0.115 and barbell_bad:
            # Second stage still preserves a smaller core; no all-cash switch.
            if target.get('nasdaq', 0.0) > 0.20:
                target['nasdaq'] = 0.20
                changed = True
            if target.get('gold_cny', 0.0) > 0.30:
                target['gold_cny'] = 0.30
                changed = True
            count(ctx, 'T02_pdd_second_stage_core')
        return normalize(target, 0.92) if changed and not sameish(target, w) else None
    return fn


# ---- Candidate logic 3: monthly asymmetric sleeve stops with re-entry hysteresis ----
def T03_M13_asymmetric_monthly_stops():
    def fn(dates, p, i, ctx):
        st = ctx.setdefault('state', {})
        w = ctx.get('sig_w', {})
        target, changed = base_or_current_m13(dates, p, i, ctx)
        for s in HOLDINGS:
            key = f'T03_{s}_stop'
            st[key] = max(0, st.get(key, 0) - 1)
            if liquidity_air_pocket(p, s, i):
                st[key] = max(st.get(key, 0), 2 if s == 'nasdaq' else 3)
                count(ctx, f'T03_{s}_asym_stop')
            if st.get(key, 0) > 0:
                # Nasdaq gets more room but can go near-cash in real trend breaks; gold is tighter after blowoff.
                cap = 0.10 if s == 'nasdaq' else 0.16
                if (target.get(s, w.get(s, 0.0)) or 0.0) > cap:
                    target[s] = cap
                    changed = True
            if st.get(key, 0) > 0 and own_recovered(p, s, i):
                st[key] = 0
        return normalize(target, 0.90) if changed and not sameish(target, w) else None
    return fn


# ---- Candidate logic 4: M34 with a modest healthy-regime lift and excess-only tail brake ----
def T04_M34_lift_then_excess_tail_brake():
    def fn(dates, p, i, ctx):
        w = ctx.get('sig_w', {})
        target = Z.M34_health_recovery_with_vol_cap(dates, p, i, ctx) or {}
        changed = True  # M34 is an allocation engine; returning target monthly is normal.
        state, _vdd = barbell_health_state(p, i)
        recovered = vb_recovered(p, i)
        # Lift only in the same healthy/recovered state M34 already likes; no extra asset source.
        if state == 'healthy' and recovered:
            sn, sg = score_asset(p, 'nasdaq', i), score_asset(p, 'gold_cny', i)
            if sn >= sg and positive_6m(p, 'nasdaq', i):
                target['nasdaq'] = max(target.get('nasdaq', 0.0), 0.58 if (realized_vol(p['nasdaq'], i, 63) or 0.25) <= 0.30 else 0.48)
                target['gold_cny'] = max(target.get('gold_cny', 0.0), 0.26)
                count(ctx, 'T04_healthy_nasdaq_lift')
            elif positive_6m(p, 'gold_cny', i):
                target['gold_cny'] = max(target.get('gold_cny', 0.0), 0.52)
                target['nasdaq'] = max(target.get('nasdaq', 0.0), 0.24)
                count(ctx, 'T04_healthy_gold_lift')
        # Tail brake trims only the satellite/excess, not the M34 core.
        pdd = ctx.get('portfolio_dd', 0.0)
        barbell_tail = vb_dd(p, i, 126) < -0.075 or (virtual_mom(p, i, 42, 0.5, 0.5) or 0) < -0.055
        if pdd > 0.080 and barbell_tail:
            target['nasdaq'] = min(target.get('nasdaq', 0.0), 0.30)
            target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.35)
            count(ctx, 'T04_excess_tail_brake')
        if pdd > 0.120 and barbell_tail:
            target['nasdaq'] = min(target.get('nasdaq', 0.0), 0.20)
            target['gold_cny'] = min(target.get('gold_cny', 0.0), 0.28)
            count(ctx, 'T04_second_stage_brake')
        return normalize(target, 0.92) if changed else None
    return fn


CANDIDATES: list[tuple[str, str, Callable, str, int]] = [
    ('REF_M13', 'M13 harvest/rebuild reference', Z.M13_rebalance_harvest_rebuild, 'target', 20),
    ('REF_M34', 'M34 health recovery with vol cap reference', Z.M34_health_recovery_with_vol_cap, 'target', 20),
    ('T01_M13_blowoff_tail_hedge', 'M13 + only after sleeve blowoff: trim overheated sleeve to base-ish cap for 2-3 months', T01_M13_blowoff_tail_hedge(), 'event', 20),
    ('T02_M13_excess_drift_pdd_trim', 'M13 + portfolio DD trims only drift/satellite excess; base sleeves remain', T02_M13_excess_drift_pdd_trim(), 'event', 20),
    ('T03_M13_asym_monthly_sleeve_stops', 'M13 + monthly asymmetric sleeve stops/re-entry hysteresis; no daily stop churn', T03_M13_asymmetric_monthly_stops(), 'event', 20),
    ('T04_M34_lift_excess_tail_brake', 'M34 + healthy-regime lift, tail brake trims only excess above core', T04_M34_lift_then_excess_tail_brake(), 'event', 20),
]


def row_for(dates, p, item):
    name, desc, fn, mode, rebalance = item
    if mode == 'target':
        vals, weights, extra = Z.simulate_target(dates, p, fn, rebalance=rebalance)
    else:
        vals, weights, extra = E.simulate_event(dates, p, fn, rebalance=rebalance, band=0.02)
    bad = [s for ww in weights for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    m = all_metrics(dates, vals)
    return {
        'name': name,
        'description': desc,
        'metrics': m,
        'stress': {k: metrics(dates, vals, a, b) for k, (a, b) in Z.STRESS.items()},
        'extra': extra,
        'top_dd': topdds(dates, vals, weights),
        'dd_improved_vs_m13': None,
    }


def run():
    dates, p = CORE.align(CORE.fetch())
    rows = [row_for(dates, p, c) for c in CANDIDATES]
    ref_m13 = next(r for r in rows if r['name'] == 'REF_M13')['metrics']['full']
    for r in rows:
        r['dd_improved_vs_m13'] = ref_m13['dd'] - r['metrics']['full']['dd']
    OUT.write_text(json.dumps({
        'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates)},
        'note': 'holdings restricted to nasdaq/gold_cny/cash; 4 hand-built monthly mechanisms, no grid',
        'rows': rows,
    }, ensure_ascii=False, indent=2, default=str))
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates))
    print('name | full ann/DD | post2020 ann/DD | 10y ann/DD | latest | cash | trades | events')
    for r in rows:
        m = r['metrics']['full']; p20 = r['metrics']['post2020']; ten = r['metrics']['teny']
        print(
            r['name'],
            f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",
            f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",
            f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",
            'latest', {k: round(v * 100, 1) for k, v in r['extra']['latest'].items()},
            'cash', round(r['extra']['cash_pct'] * 100, 1),
            'trades', r['extra']['trades'],
            'events', r['extra'].get('events', {}),
        )
        print('  topdd', ' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
    print('\nSorted non-reference by least return sacrificed per DD cut vs M13:')
    for r in sorted([x for x in rows if not x['name'].startswith('REF_')], key=lambda x: (-x['metrics']['full']['ann'], x['metrics']['full']['dd'])):
        m = r['metrics']['full']
        ann_loss = ref_m13['ann'] - m['ann']
        dd_cut = ref_m13['dd'] - m['dd']
        print(r['name'], f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f} ann_loss={ann_loss*100:.2f} dd_cut={dd_cut*100:.2f}")


if __name__ == '__main__':
    run()
