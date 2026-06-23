#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
import sys
from pathlib import Path
from typing import Any

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
OUT = Path('/tmp/atm_meta_loss_vol_unit_verify_016.json')
START = 100000.0
FEE = 0.001
SLIP = 0.0005

spec = importlib.util.spec_from_file_location('meta', '/tmp/atm_meta_engine_recovery_search.py')
META = importlib.util.module_from_spec(spec)
sys.modules['meta'] = META
spec.loader.exec_module(META)  # type: ignore

L = META.L
B = META.B
ASSETS = META.ASSETS

PERIODS = {
    'full': (None, None),
    'post2020': (dt.date(2020, 1, 1), None),
    'teny': (dt.date(2016, 6, 18), None),
    '2024+': (dt.date(2024, 1, 1), None),
    '2002-2012': (dt.date(2002, 1, 1), dt.date(2012, 12, 31)),
    '2013-2023': (dt.date(2013, 1, 1), dt.date(2023, 12, 31)),
    'pre2020': (None, dt.date(2019, 12, 31)),
    'post2010': (dt.date(2010, 1, 1), None),
}

STRESS = {
    '2008金融危机': (dt.date(2007, 10, 1), dt.date(2009, 3, 31)),
    '2015A股冲击': (dt.date(2015, 6, 1), dt.date(2016, 2, 29)),
    '2020疫情': (dt.date(2020, 2, 1), dt.date(2020, 4, 30)),
    '2022通胀加息': (dt.date(2022, 1, 1), dt.date(2022, 12, 31)),
    '2026AI波动': (dt.date(2025, 12, 1), None),
}

RATE_POINTS = [
    (dt.date(1990, 4, 15), 0.0288),
    (dt.date(1999, 6, 10), 0.0099),
    (dt.date(2002, 2, 21), 0.0072),
    (dt.date(2007, 7, 21), 0.0081),
    (dt.date(2007, 12, 21), 0.0072),
    (dt.date(2008, 11, 27), 0.0036),
    (dt.date(2011, 2, 9), 0.0040),
    (dt.date(2011, 4, 6), 0.0050),
    (dt.date(2012, 6, 8), 0.0040),
    (dt.date(2012, 7, 6), 0.0035),
    (dt.date(2015, 10, 24), 0.0035),
]


def cash_daily(day: dt.date) -> float:
    r = RATE_POINTS[0][1]
    for d, v in RATE_POINTS:
        if d <= day:
            r = v
        else:
            break
    return r / 252.0


def pct(x: float | None) -> str:
    return 'NA' if x is None else f'{x * 100:.2f}%'


def ix(data: Any, symbol: str) -> int:
    return data.assets.index(symbol)


def price(data: Any, symbol: str, i: int) -> float:
    return data.prices[ix(data, symbol)][i]


def mom(data: Any, symbol: str, i: int, lb: int) -> float | None:
    if i - lb < 0:
        return None
    p0 = price(data, symbol, i - lb)
    return price(data, symbol, i) / p0 - 1.0 if p0 > 0 else None


def ma(data: Any, symbol: str, i: int, lb: int) -> float | None:
    if i - lb + 1 < 0:
        return None
    arr = data.prices[ix(data, symbol)][i - lb + 1:i + 1]
    return sum(arr) / len(arr)


def above(data: Any, symbol: str, i: int, lb: int) -> bool:
    m = ma(data, symbol, i, lb)
    return m is not None and price(data, symbol, i) >= m


def rel(data: Any, a: str, b: str, i: int, lb: int) -> float | None:
    if i - lb < 0:
        return None
    pa = price(data, a, i - lb)
    pb = price(data, b, i - lb)
    return (price(data, a, i) / pa) / (price(data, b, i) / pb) - 1.0 if pa > 0 and pb > 0 else None


def don(data: Any, symbol: str, i: int, lb: int) -> float | None:
    if i - lb + 1 < 0:
        return None
    arr = data.prices[ix(data, symbol)][i - lb + 1:i + 1]
    lo, hi = min(arr), max(arr)
    return 0.5 if hi <= lo else (price(data, symbol, i) - lo) / (hi - lo)


def rsi(data: Any, symbol: str, i: int, lb: int = 14) -> float | None:
    if i - lb < 1:
        return None
    arr = data.prices[ix(data, symbol)]
    gains = losses = 0.0
    for j in range(i - lb + 1, i + 1):
        ch = arr[j] / arr[j - 1] - 1.0 if arr[j - 1] > 0 else 0.0
        if ch >= 0:
            gains += ch
        else:
            losses -= ch
    if losses == 0:
        return 100.0
    rs = (gains / lb) / (losses / lb)
    return 100 - 100 / (1 + rs)


def calc_metrics(data: Any, values: list[float]) -> dict[str, Any]:
    return {k: L.calc_metrics(data.dates, values, st, en or data.dates[-1]) for k, (st, en) in PERIODS.items()}


def calc_stress(data: Any, values: list[float]) -> dict[str, Any]:
    return {k: L.calc_metrics(data.dates, values, st, en or data.dates[-1]) for k, (st, en) in STRESS.items()}


def desc(data: Any, weights: list[float]) -> dict[str, float]:
    return {s: round(w * 100, 1) for s, w in zip(data.assets, weights) if w > 1e-4}


def episodes(data: Any, values: list[float], weights: list[list[float]], topn: int = 8) -> list[dict[str, Any]]:
    peak = trough = 0
    out: list[tuple[int, int, float]] = []
    for i in range(1, len(values)):
        if values[i] > values[peak]:
            if values[trough] < values[peak] * 0.985:
                out.append((peak, trough, 1 - values[trough] / values[peak]))
            peak = trough = i
        elif values[i] < values[trough]:
            trough = i
    if values[trough] < values[peak] * 0.985:
        out.append((peak, trough, 1 - values[trough] / values[peak]))
    out.sort(key=lambda x: x[2], reverse=True)
    return [
        {'peak': str(data.dates[p]), 'trough': str(data.dates[t]), 'dd': dd, 'weights': desc(data, weights[t])}
        for p, t, dd in out[:topn]
    ]


def normalize(target: list[float], cap: float = 1.0) -> list[float]:
    out = [max(0.0, float(x)) for x in target]
    sm = sum(out)
    if sm > cap and sm > 0:
        out = [x * cap / sm for x in out]
    return out


def target_meta_only(data: Any, i: int, vals: list[float], current_value: float, weights: list[float], traces: dict[str, Any], state: dict[str, Any], events: dict[str, int]) -> list[float]:
    spec = {
        'kind': 'loss_vol_gate',
        'name': '近期亏损波动元策略_clean_unit',
        'safe': 'tail_def',
        'meta_rebalance': 60,
        'params': {'loss_lb': 60, 'loss': 0.035, 'vol_lb': 20, 'vol_thr': 0.13},
    }
    target, mode, reason = META.choose_engine_or_weights(spec, i, data, vals, current_value, weights, traces, state)
    events[f'mode_{mode}'] = events.get(f'mode_{mode}', 0) + 1
    return normalize(target, 1.0)


def gold_sat_ok(data: Any, sig: int) -> bool:
    gm = mom(data, 'gold_cny', sig, 90)
    gr = rel(data, 'gold_cny', 'sp500', sig, 60)
    return gm is not None and gm > 0.0 and above(data, 'gold_cny', sig, 120) and (gr or -9) > 0.0


def gold_exhaust(data: Any, sig: int) -> bool:
    return (don(data, 'gold_cny', sig, 120) or 0) > 0.85 and (rsi(data, 'gold_cny', sig, 14) or 50) > 75 and ((mom(data, 'gold_cny', sig, 10) or 0) < -0.02 or (mom(data, 'gold_cny', sig, 20) or 0) < 0.015)


def target_meta_gold_sat(data: Any, i: int, vals: list[float], current_value: float, weights: list[float], traces: dict[str, Any], state: dict[str, Any], events: dict[str, int]) -> list[float]:
    # Fixed candidate from old search: meta core + 10% gold satellite + weak-Feb equity cap + portfolio DD mild scale.
    base = target_meta_only(data, i, vals, current_value, weights, traces, state, events)
    sig = i - 1
    target = base[:]
    if gold_sat_ok(data, sig):
        target[ix(data, 'gold_cny')] += 0.10
        events['gold_sat'] = events.get('gold_sat', 0) + 1
    target = normalize(target, 0.85)
    if gold_exhaust(data, sig):
        j = ix(data, 'gold_cny')
        if target[j] > 0.35:
            target[j] = 0.35
            events['gold_exhaust_cap'] = events.get('gold_exhaust_cap', 0) + 1
    # February weak equity cap, matching the old fixed candidate.
    if data.dates[sig].month == 2:
        equity = ['nasdaq', 'sp500', 'csi300', 'shanghai_composite']
        held = [s for s in equity if target[ix(data, s)] > 1e-4]
        weak = any((mom(data, s, sig, 60) or 0) < -0.02 for s in held)
        if weak:
            eq_exp = sum(target[ix(data, s)] for s in equity)
            if eq_exp > 0.35 and eq_exp > 0:
                scale = 0.35 / eq_exp
                for s in equity:
                    target[ix(data, s)] *= scale
                events['weak_month_cap'] = events.get('weak_month_cap', 0) + 1
    # Portfolio DD mild scale, old best used 60-day 6.5% threshold and 0.85 scale.
    if len(vals) > 60:
        pk = max(vals[-60:])
        pdd = 1 - vals[-1] / pk if pk > 0 else 0.0
        if pdd > 0.065:
            for s in ['nasdaq', 'sp500', 'csi300', 'shanghai_composite']:
                target[ix(data, s)] *= 0.85
            events['portfolio_dd_scale'] = events.get('portfolio_dd_scale', 0) + 1
    return normalize(target, 0.85)


def simulate_units(data: Any, traces: dict[str, Any], target_fn, rebalance: int = 60) -> tuple[list[float], list[list[float]], dict[str, Any]]:
    cash = START
    units = [0.0] * len(data.assets)
    vals: list[float] = []
    weights_hist: list[list[float]] = []
    events: dict[str, int] = {}
    state: dict[str, Any] = {}
    trades = 0
    turn_sum = 0.0
    mode_dates: list[Any] = []

    def pv(i: int) -> float:
        return cash + sum(units[j] * data.prices[j][i] for j in range(len(units)))

    for i in range(len(data.dates)):
        if i > 0 and cash > 0:
            cash += cash * cash_daily(data.dates[i - 1])
        if i == 1 or (i > 1 and i % rebalance == 0):
            pre = pv(i)
            oldw = [(units[j] * data.prices[j][i] / pre if pre > 0 else 0.0) for j in range(len(units))]
            target = target_fn(data, i, vals if vals else [START], pre, oldw, traces, state, events)
            # Sell first at current close with slippage/fee.
            for j in range(len(units)):
                cur = units[j] * data.prices[j][i]
                tgt = pre * target[j]
                if cur > tgt + 1e-9:
                    sell_value = cur - tgt
                    sell_units = min(units[j], sell_value / data.prices[j][i])
                    if sell_units > 1e-12:
                        gross = sell_units * data.prices[j][i] * (1 - SLIP)
                        cash += gross * (1 - FEE)
                        units[j] -= sell_units
                        trades += 1
            # Buy using post-sell portfolio value.
            total = pv(i)
            for j in range(len(units)):
                cur = units[j] * data.prices[j][i]
                tgt = total * target[j]
                if cur < tgt - 1e-9:
                    amt = min(cash, max(tgt - cur, 0.0))
                    if amt > 1:
                        units[j] += amt * (1 - FEE) / (data.prices[j][i] * (1 + SLIP))
                        cash -= amt
                        trades += 1
            newv = pv(i)
            neww = [(units[j] * data.prices[j][i] / newv if newv > 0 else 0.0) for j in range(len(units))]
            turn_sum += sum(abs(a - b) for a, b in zip(oldw, neww))
            if len(mode_dates) < 200:
                mode_dates.append((str(data.dates[i - 1]), desc(data, neww), round(max(0.0, 1 - sum(neww)) * 100, 1)))
        val = pv(i)
        vals.append(val)
        weights_hist.append([(units[j] * data.prices[j][i] / val if val > 0 else 0.0) for j in range(len(units))])

    latest = desc(data, weights_hist[-1])
    return vals, weights_hist, {
        'events': events,
        'trades': trades,
        'avg_turnover': turn_sum / max(trades, 1),
        'latest': latest,
        'cash_pct': max(0.0, 1 - sum(weights_hist[-1])),
        'sample_rebalances': mode_dates[-12:],
    }


def main() -> None:
    raw = L.fetch_history()
    series = L.build_cny_series(raw)
    data = L.align_series(series, '5asset', ASSETS, [1], [10, 20, 30, 40, 60, 90])
    pack = B.IndicatorPack(data)
    engines = META.make_engine_variants()
    traces = {k: META.run_engine_trace(data, pack, v) for k, v in engines.items()}

    rows = []
    for name, fn in [
        ('M00_meta_loss_vol_clean_unit', target_meta_only),
        ('M01_meta_loss_vol_gold_sat_clean_unit', target_meta_gold_sat),
    ]:
        vals, wh, extra = simulate_units(data, traces, fn, rebalance=60)
        m = calc_metrics(data, vals)
        rows.append({
            'name': name,
            'metrics': m,
            'stress': calc_stress(data, vals),
            'extra': extra,
            'top_dd': episodes(data, vals, wh),
        })

    OUT.write_text(json.dumps({'coverage': {'start': str(data.dates[0]), 'end': str(data.dates[-1]), 'n': len(data.dates), 'assets': data.assets}, 'rows': rows}, ensure_ascii=False, indent=2, default=str))

    print('WROTE', OUT, 'coverage', data.dates[0], data.dates[-1], len(data.dates), data.assets)
    for r in rows:
        m = r['metrics']; e = r['extra']
        print('\n##', r['name'])
        for k in ['full', 'post2020', 'teny', '2024+', '2002-2012', '2013-2023']:
            x = m[k]
            print(f"{k}: ann={pct(x['ann'])} dd={pct(x['dd'])} total={pct(x['total'])} sharpe={x.get('sharpe', 0):.2f} calmar={x.get('calmar', 0):.2f}")
        print('latest', e['latest'], 'cash', pct(e['cash_pct']), 'trades', e['trades'], 'events', e['events'])
        print('topdd', ' ; '.join(f"{x['peak']}->{x['trough']} {pct(x['dd'])} W={x['weights']}" for x in r['top_dd'][:6]))
        print('stress', ' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k, v in r['stress'].items() if v))
        print('recent rebalances', e['sample_rebalances'])


if __name__ == '__main__':
    main()
