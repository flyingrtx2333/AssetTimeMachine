#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json
from pathlib import Path

ROOT = Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec = importlib.util.spec_from_file_location('base016', ROOT/'spikes/016-meta-loss-vol-unit-verify/meta_loss_vol_unit_verify.py')
B016 = importlib.util.module_from_spec(spec); sys.modules['base016'] = B016; spec.loader.exec_module(B016)  # type: ignore
OUT = Path('/tmp/atm_meta_loss_vol_heat_cap_016.json')

EQUITY = ['nasdaq','sp500','csi300','shanghai_composite']

def make_heat_cap_fn(cap: float, gold_cap: float | None = None, gross: float = 0.85):
    def fn(data, i, vals, current_value, weights, traces, state, events):
        target = B016.target_meta_gold_sat(data, i, vals, current_value, weights, traces, state, events)
        clipped = False
        for s in EQUITY:
            j = B016.ix(data, s)
            if target[j] > cap:
                target[j] = cap
                clipped = True
        if gold_cap is not None:
            j = B016.ix(data, 'gold_cny')
            if target[j] > gold_cap:
                target[j] = gold_cap
                clipped = True
        if clipped:
            events[f'heat_cap_{cap:.2f}'] = events.get(f'heat_cap_{cap:.2f}', 0) + 1
        return B016.normalize(target, gross)
    return fn

def main():
    raw = B016.L.fetch_history(); series = B016.L.build_cny_series(raw)
    data = B016.L.align_series(series, '5asset', B016.ASSETS, [1], [10,20,30,40,60,90])
    pack = B016.B.IndicatorPack(data); engines = B016.META.make_engine_variants()
    traces = {k: B016.META.run_engine_trace(data, pack, v) for k, v in engines.items()}
    rows=[]
    variants=[
        ('BASE_M01_no_extra_cap', B016.target_meta_gold_sat),
        ('H01_equity_single_cap72', make_heat_cap_fn(0.72)),
        ('H02_equity_single_cap70', make_heat_cap_fn(0.70)),
        ('H03_equity_single_cap68', make_heat_cap_fn(0.68)),
        ('H04_equity70_gold82', make_heat_cap_fn(0.70, gold_cap=0.82)),
        ('H05_equity70_gold80', make_heat_cap_fn(0.70, gold_cap=0.80)),
        ('H06_equity68_gold82', make_heat_cap_fn(0.68, gold_cap=0.82)),
    ]
    for name,fn in variants:
        vals,wh,extra = B016.simulate_units(data, traces, fn, rebalance=60)
        m=B016.calc_metrics(data, vals)
        rows.append({'name':name,'metrics':m,'stress':B016.calc_stress(data,vals),'extra':extra,'top_dd':B016.episodes(data,vals,wh)})
    OUT.write_text(json.dumps({'coverage':{'start':str(data.dates[0]),'end':str(data.dates[-1]),'n':len(data.dates),'assets':data.assets},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE', OUT)
    for r in sorted(rows, key=lambda r:(r['metrics']['full']['dd']<=0.10, r['metrics']['full']['ann']), reverse=True):
        f=r['metrics']['full']; p=r['metrics']['post2020']; t=r['metrics']['teny']; y=r['metrics']['2024+']; e=r['extra']
        mark='PASS<10' if f['dd']<=0.10 else 'DD>10'
        print(f"\n{mark} {r['name']} full={f['ann']*100:.2f}/{f['dd']*100:.2f} post={p['ann']*100:.2f}/{p['dd']*100:.2f} ten={t['ann']*100:.2f}/{t['dd']*100:.2f} 2024+={y['ann']*100:.2f}/{y['dd']*100:.2f}")
        print(' latest',e['latest'],'cash',round(e['cash_pct']*100,1),'trades',e['trades'],'events',e['events'])
        print(' topdd',' ; '.join(f"{x['peak']}->{x['trough']} {x['dd']*100:.2f}% W={x['weights']}" for x in r['top_dd'][:5]))
        print(' stress',' | '.join(f"{k}:{v['ann']*100:.2f}/{v['dd']*100:.2f}" for k,v in r['stress'].items() if v))

if __name__=='__main__': main()
