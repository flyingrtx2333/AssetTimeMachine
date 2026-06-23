#!/usr/bin/env python3
"""
Spike 012 continuation: small, hand-picked E02 breakout/chandelier mechanism variants.

Scope constraints:
- Holdings remain only nasdaq / gold_cny / cash.
- Uses the existing 011/012 simulate_event口径: full 2002-2026, T-1 signal / T execution,
  cash yield, fees/slippage.
- No large parameter fitting: candidates are named mechanism variants around REF_E02.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Callable

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec = importlib.util.spec_from_file_location(
    'R12', ROOT / 'spikes/012-e02-risk-gates-reentry/e02_risk_gates_reentry.py'
)
assert spec is not None and spec.loader is not None
R = importlib.util.module_from_spec(spec)
sys.modules['R12'] = R
spec.loader.exec_module(R)

E = R.E
Z = R.Z
CORE = R.CORE
OUT = Path('/tmp/atm_e02_breakout_chandelier_mechanism_variants_012.json')
TARGET_ANN = 0.12
TARGET_DD = 0.08
HOLDINGS = ['nasdaq', 'gold_cny']


def count(ctx, name: str) -> None:
    ev = ctx.setdefault('event_counts', {})
    ev[name] = ev.get(name, 0) + 1


def metrics(dates, vals, start=None, end=None):
    return R.metrics(dates, vals, start, end)


def all_metrics(dates, vals):
    return R.all_metrics(dates, vals)


def topdds(dates, vals, weights):
    return R.topdds(dates, vals, weights)


def overheat_exit(s: str, p, i: int) -> str | None:
    """Targeted extra chandelier exits for the post-2020/2026 failures.

    This is deliberately not a broad crash gate:
    - gold exits only after a strong 6m run rolls over quickly;
    - Nasdaq exits only on a short-volatility expansion plus 10d loss.
    """
    if s == 'gold_cny':
        if (R.mom(p[s], i, 126) or 0.0) > 0.22 and (R.mom(p[s], i, 10) or 0.0) < -0.035:
            return 'gold_blowoff_roll'
    elif s == 'nasdaq':
        rv10 = R.realized_vol(p[s], i, 10) or 0.0
        rv63 = R.realized_vol(p[s], i, 63) or 0.25
        if rv10 > rv63 * 2.0 and (R.mom(p[s], i, 10) or 0.0) < -0.055:
            return 'nq_vol_break'
    return None


def e02_core(
    label: str,
    *,
    n_kind: str = 'loose',
    g_kind: str = 'loose',
    n_weight: float = 0.58,
    g_weight: float = 0.42,
    gross: float = 0.90,
    n_stop_cool: int = 35,
    g_stop_cool: int = 35,
    extra_overheat: bool = False,
    both_cap: tuple[float, float, float] | None = None,
    quality_nq: bool = False,
) -> Callable:
    """E02 breakout/chandelier clone with a few named mechanism switches."""

    def fn(dates, p, i: int, ctx):
        st = ctx.setdefault('state', {})
        w = ctx.get('sig_w', {})
        target = dict(w)
        for s in HOLDINGS:
            cool_key = f'{label}_{s}_cool'
            st[cool_key] = max(0, st.get(cool_key, 0) - 1)
            if w.get(s, 0.0) > 0.03:
                kind = n_kind if s == 'nasdaq' else g_kind
                stop, take, reason = E.sleeve_stop_flags(p, s, i, st, kind)
                # REF_E02's fresh-breakout chandelier momentum break.
                if not stop and (R.mom(p[s], i, 21) or 0.0) < -0.075 and E.crossed_below_ma(p, s, i, 50):
                    stop = True
                    reason = 'chandelier_momentum_break'
                if extra_overheat and not stop:
                    reason2 = overheat_exit(s, p, i)
                    if reason2:
                        stop = True
                        reason = reason2
                if stop:
                    target[s] = 0.0
                    st[cool_key] = n_stop_cool if s == 'nasdaq' else g_stop_cool
                    count(ctx, f'{label}_{s}_{reason}')
                    continue
                if take:
                    target[s] = min(w.get(s, 0.0), 0.18 if s == 'nasdaq' else 0.22)
                    count(ctx, f'{label}_{s}_{reason}')

            if target.get(s, 0.0) <= 0.03 and st.get(cool_key, 0) == 0:
                h = E.rolling_high(p[s], i, 126, exclude_current=True)
                breakout = h is not None and p[s][i] > h * 1.002
                if s == 'nasdaq' and quality_nq:
                    trend = E.trend_ok(p, s, i, 160, 126, 0.06)
                else:
                    trend = E.trend_ok(p, s, i, 120, 126, 0.03)
                if breakout and trend:
                    target[s] = n_weight if s == 'nasdaq' else g_weight
                    count(ctx, f'{label}_{s}_buy')

        if both_cap and target.get('nasdaq', 0.0) > 0.0 and target.get('gold_cny', 0.0) > 0.0:
            ncap, gcap, cap = both_cap
            target['nasdaq'] = min(target.get('nasdaq', 0.0), ncap)
            target['gold_cny'] = min(target.get('gold_cny', 0.0), gcap)
            return R.normalize(target, cap)
        return R.normalize(target, gross)

    return fn


def pdd_brake(
    label: str,
    base: Callable,
    *,
    trigger: float,
    ncap: float,
    gcap: float,
    gross: float,
    duration: int = 5,
) -> Callable:
    """Portfolio-DD brake layered after the E02 signal, without new holdings."""

    def fn(dates, p, i: int, ctx):
        st = ctx.setdefault('state', {})
        target = base(dates, p, i, ctx) or {}
        if ctx.get('portfolio_dd', 0.0) > trigger:
            st[label] = max(st.get(label, 0), duration)
            count(ctx, f'{label}_pdd_brake')
        st[label] = max(0, st.get(label, 0) - 1)
        if st.get(label, 0) > 0:
            return R.cap_target(target, ncap=ncap, gcap=gcap, gross=gross)
        return R.normalize(target, 0.90)

    return fn


def make_candidates():
    ref = R.base_e02()
    overheat = e02_core(
        'V01_overheat_shortcool', extra_overheat=True, n_stop_cool=10, g_stop_cool=8
    )
    return [
        ('REF_E02_loose_from_011', 'reference E02 breakout/chandelier loose', ref),
        (
            'V01_overheat_shortcool',
            'E02 + gold blowoff-roll / Nasdaq vol-break exits; shorter stop cooldown',
            overheat,
        ),
        (
            'V02_overheat_pdd_bothmild_0875',
            'V01 + mild portfolio-DD brake at 8.75%: cap N/G to 48/36 gross 84 for 5d',
            pdd_brake(
                'V02_pdd',
                e02_core('V02_core', extra_overheat=True, n_stop_cool=10, g_stop_cool=8),
                trigger=0.0875,
                ncap=0.48,
                gcap=0.36,
                gross=0.84,
                duration=5,
            ),
        ),
        (
            'V03_overheat_pdd_mid_0875',
            'V01 + medium portfolio-DD brake at 8.75%: cap N/G to 42/32 gross 74 for 5d',
            pdd_brake(
                'V03_pdd',
                e02_core('V03_core', extra_overheat=True, n_stop_cool=10, g_stop_cool=8),
                trigger=0.0875,
                ncap=0.42,
                gcap=0.32,
                gross=0.74,
                duration=5,
            ),
        ),
        (
            'V04_overheat_pdd_ncut_090',
            'V01 + drawdown brake at 9% that mainly cuts Nasdaq: cap N/G to 30/42 gross 72 for 5d',
            pdd_brake(
                'V04_pdd',
                e02_core('V04_core', extra_overheat=True, n_stop_cool=10, g_stop_cool=8),
                trigger=0.090,
                ncap=0.30,
                gcap=0.42,
                gross=0.72,
                duration=5,
            ),
        ),
        (
            'V05_overheat_pdd_ncash_090',
            'V01 + stronger drawdown brake at 9%: Nasdaq to cash, keep gold cap 42 for 5d',
            pdd_brake(
                'V05_pdd',
                e02_core('V05_core', extra_overheat=True, n_stop_cool=10, g_stop_cool=8),
                trigger=0.090,
                ncap=0.0,
                gcap=0.42,
                gross=0.42,
                duration=5,
            ),
        ),
        (
            'V06_overheat_static_bothcap',
            'V01 + static cap whenever both sleeves are active: N/G 46/34 gross 80',
            e02_core(
                'V06_bothcap',
                extra_overheat=True,
                n_stop_cool=10,
                g_stop_cool=8,
                both_cap=(0.46, 0.34, 0.80),
            ),
        ),
        (
            'V07_quality_nq_breakout',
            'E02 with stricter Nasdaq trend quality gate, no extra risk brake',
            e02_core('V07_quality', quality_nq=True),
        ),
        (
            'V08_asym_gold_medium',
            'E02 with loose Nasdaq but medium gold stop/take thresholds',
            e02_core('V08_asym', n_kind='loose', g_kind='medium'),
        ),
    ]


def row_for(dates, p, item):
    name, desc, fn = item
    vals, weights, extra = E.simulate_event(dates, p, fn, rebalance=1, band=0.02)
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
        'pass_12_8': m['full']['ann'] >= TARGET_ANN and m['full']['dd'] <= TARGET_DD,
        'beats_ref_round': False,  # filled after REF is known
    }


def run():
    dates, p = CORE.align(CORE.fetch())
    rows = [row_for(dates, p, c) for c in make_candidates()]
    ref = next(r for r in rows if r['name'] == 'REF_E02_loose_from_011')
    ref_ann = ref['metrics']['full']['ann']
    ref_dd = ref['metrics']['full']['dd']
    for r in rows:
        m = r['metrics']['full']
        r['beats_ref_round'] = m['ann'] > ref_ann and m['dd'] <= ref_dd
    OUT.write_text(
        json.dumps(
            {
                'coverage': {'start': str(dates[0]), 'end': str(dates[-1]), 'n': len(dates)},
                'target': {'ann': TARGET_ANN, 'dd': TARGET_DD},
                'ref': {'ann': ref_ann, 'dd': ref_dd},
                'rows': rows,
            },
            ensure_ascii=False,
            indent=2,
            default=str,
        )
    )
    print('WROTE', OUT, 'coverage', dates[0], dates[-1], len(dates), 'TARGET', TARGET_ANN, TARGET_DD)
    print('\nSorted by full annualized:')
    for r in sorted(rows, key=lambda x: x['metrics']['full']['ann'], reverse=True):
        m = r['metrics']['full']
        p20 = r['metrics']['post2020']
        ten = r['metrics']['teny']
        mark = 'PASS12/8' if r['pass_12_8'] else ('BEATS_REF' if r['beats_ref_round'] else 'FAIL')
        print(
            mark,
            r['name'],
            f"full={m['ann']*100:.3f}/{m['dd']*100:.3f}",
            f"post20={p20['ann']*100:.3f}/{p20['dd']*100:.3f}",
            f"teny={ten['ann']*100:.3f}/{ten['dd']*100:.3f}",
            'latest', {k: round(v * 100, 1) for k, v in r['extra']['latest'].items()},
            'cash', round(r['extra']['cash_pct'] * 100, 1),
            'trades', r['extra']['trades'],
            'events', r['extra'].get('events', {}),
        )
        print(
            '  topdd',
            ' ; '.join(
                f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}"
                for e in r['top_dd'][:4]
            ),
        )
    print('\nCandidates with ann >= REF and DD <= REF:')
    for r in sorted(
        [r for r in rows if r['metrics']['full']['ann'] >= ref_ann and r['metrics']['full']['dd'] <= ref_dd],
        key=lambda x: (x['metrics']['full']['dd'], -x['metrics']['full']['ann']),
    ):
        m = r['metrics']['full']
        print(r['name'], f"ann={m['ann']*100:.3f} dd={m['dd']*100:.3f}")
    print('PASS_COUNT_12_8', sum(1 for r in rows if r['pass_12_8']))


if __name__ == '__main__':
    run()
