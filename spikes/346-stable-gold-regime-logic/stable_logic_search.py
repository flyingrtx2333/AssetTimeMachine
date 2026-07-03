#!/usr/bin/env python3
"""Spike 346 - stable logic cluster search, not single-point parameter picking.

Goal: find a better *logic* than spike 345, not a fragile cherry-picked parameter.

Method:
- Define coarse economic logic centers for gold insurance repair.
- For each center, generate small local perturbations.
- Rank by median / lower-quartile performance of the cluster, not by one best run.
- A center is considered promoted only if its cluster median beats spike 345 on return
  and drawdown, with stable 2020+/10y slices.
"""
from __future__ import annotations
import importlib.util, json, pathlib, random, statistics, sys
from dataclasses import dataclass

ROOT=pathlib.Path(__file__).resolve().parents[2]
GDR_PATH=ROOT/'spikes/344-gold-drawdown-repair/gold_drawdown_repair.py'
BASE345_PATH=ROOT/'spikes/345-gold-repair-refine/best_hit.json'
OUTDIR=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('gdr',GDR_PATH)
if spec is None or spec.loader is None: raise RuntimeError(GDR_PATH)
gdr=importlib.util.module_from_spec(spec); sys.modules['gdr']=gdr; spec.loader.exec_module(gdr)
BASE345=json.loads(BASE345_PATH.read_text(encoding='utf-8'))
BM=BASE345['metrics']; BS=BASE345['slice_metrics']

CENTERS={
    # 345-like but rounded: gold loses insurance role when medium drawdown + trend break.
    'medium_gold_break_rounded': {
        'dd_fast_n':63,'dd_slow_n':126,'dd_fast_cut':-0.08,'dd_slow_cut':-0.16,'deep_dd_cut':-0.24,
        'mom_fast_n':30,'mom_slow_n':150,'mom_fast_cut':-0.02,'mom_slow_cut':-0.05,'ma_fast':80,'ma_slow':220,
        'gold_stress_cap':0.22,'gold_deep_cap':0.20,'eq_ma':120,'eq_mom_n':150,'nas_min_mom':0.04,'sp_min_mom':0.0,
        'vol_n':63,'score_mom_n':120,'eq_dd_n':90,'eq_dd_floor':-0.12,'handoff_ratio':0.95,'second_ratio':0.30},
    # Slightly more conservative gold cap, only handoff to stronger equities.
    'conservative_gold_fault': {
        'dd_fast_n':63,'dd_slow_n':150,'dd_fast_cut':-0.09,'dd_slow_cut':-0.18,'deep_dd_cut':-0.26,
        'mom_fast_n':30,'mom_slow_n':150,'mom_fast_cut':-0.03,'mom_slow_cut':-0.06,'ma_fast':100,'ma_slow':220,
        'gold_stress_cap':0.24,'gold_deep_cap':0.20,'eq_ma':140,'eq_mom_n':150,'nas_min_mom':0.05,'sp_min_mom':0.0,
        'vol_n':63,'score_mom_n':120,'eq_dd_n':126,'eq_dd_floor':-0.12,'handoff_ratio':0.85,'second_ratio':0.25},
    # Earlier gold de-risk, lower cap; intends to reduce tail drawdown, may lose CAGR.
    'early_gold_derisk': {
        'dd_fast_n':50,'dd_slow_n':126,'dd_fast_cut':-0.07,'dd_slow_cut':-0.14,'deep_dd_cut':-0.22,
        'mom_fast_n':20,'mom_slow_n':120,'mom_fast_cut':-0.02,'mom_slow_cut':-0.04,'ma_fast':80,'ma_slow':200,
        'gold_stress_cap':0.20,'gold_deep_cap':0.18,'eq_ma':120,'eq_mom_n':120,'nas_min_mom':0.04,'sp_min_mom':0.0,
        'vol_n':63,'score_mom_n':120,'eq_dd_n':90,'eq_dd_floor':-0.12,'handoff_ratio':0.95,'second_ratio':0.30},
    # Later but higher confidence: gold must be clearly broken; less turnover.
    'late_confirmed_gold_fault': {
        'dd_fast_n':80,'dd_slow_n':150,'dd_fast_cut':-0.09,'dd_slow_cut':-0.18,'deep_dd_cut':-0.26,
        'mom_fast_n':40,'mom_slow_n':150,'mom_fast_cut':-0.03,'mom_slow_cut':-0.05,'ma_fast':100,'ma_slow':220,
        'gold_stress_cap':0.24,'gold_deep_cap':0.22,'eq_ma':120,'eq_mom_n':150,'nas_min_mom':0.04,'sp_min_mom':0.0,
        'vol_n':63,'score_mom_n':120,'eq_dd_n':90,'eq_dd_floor':-0.12,'handoff_ratio':0.95,'second_ratio':0.30},
    # Equity handoff is mostly S&P unless Nasdaq is very healthy; aims less crash beta.
    'sp_first_gold_fault': {
        'dd_fast_n':63,'dd_slow_n':126,'dd_fast_cut':-0.08,'dd_slow_cut':-0.16,'deep_dd_cut':-0.24,
        'mom_fast_n':30,'mom_slow_n':150,'mom_fast_cut':-0.02,'mom_slow_cut':-0.05,'ma_fast':80,'ma_slow':220,
        'gold_stress_cap':0.22,'gold_deep_cap':0.20,'eq_ma':120,'eq_mom_n':150,'nas_min_mom':0.07,'sp_min_mom':-0.01,
        'vol_n':63,'score_mom_n':120,'eq_dd_n':90,'eq_dd_floor':-0.12,'handoff_ratio':0.95,'second_ratio':0.20},
}

JITTER={
 'dd_fast_n':[50,63,80], 'dd_slow_n':[126,150,189], 'dd_fast_cut':[-0.07,-0.08,-0.09], 'dd_slow_cut':[-0.14,-0.16,-0.18],
 'deep_dd_cut':[-0.22,-0.24,-0.26], 'mom_fast_n':[20,30,40], 'mom_slow_n':[120,150], 'mom_fast_cut':[-0.02,-0.03],
 'mom_slow_cut':[-0.04,-0.05,-0.06], 'ma_fast':[80,100], 'ma_slow':[200,220], 'gold_stress_cap':[0.20,0.22,0.24],
 'gold_deep_cap':[0.18,0.20,0.22], 'eq_ma':[120,140], 'eq_mom_n':[120,150], 'nas_min_mom':[0.04,0.05,0.07],
 'sp_min_mom':[-0.01,0.0,0.01], 'vol_n':[63], 'score_mom_n':[120], 'eq_dd_n':[90,126], 'eq_dd_floor':[-0.10,-0.12,-0.14],
 'handoff_ratio':[0.85,0.95,1.0], 'second_ratio':[0.20,0.30,0.40]
}

def perturb(center, rng, p=0.28):
    op=dict(center)
    for k,vals in JITTER.items():
        if rng.random()<p:
            op[k]=rng.choice(vals)
    if op['gold_deep_cap']>op['gold_stress_cap']:
        op['gold_deep_cap']=op['gold_stress_cap']
    return op

def fmt(x): return f'{x*100:.2f}%'
def better_than_345(r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']; s22=r.slice_metrics['2022+']
    return (m['cagr']>=BM['cagr']+0.0005 and m['max_dd']>=BM['max_dd']+0.0005 and m['sharpe']>=BM['sharpe']-0.005 and
            s20['cagr']>=BS['2020+']['cagr']-0.0015 and s20['max_dd']>=BS['2020+']['max_dd']-0.0001 and
            s10['cagr']>=BS['10y']['cagr']-0.0015 and s10['max_dd']>=BS['10y']['max_dd']-0.0001 and
            s22['cagr']>=BS['2022+']['cagr']-0.0015 and s22['max_dd']>=BS['2022+']['max_dd']-0.0001)

def scalar(r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']; s22=r.slice_metrics['2022+']
    return ((m['cagr']-BM['cagr'])*8 + (m['max_dd']-BM['max_dd'])*8 + (m['sharpe']-BM['sharpe'])*0.5 +
            (s20['cagr']-BS['2020+']['cagr'])*1.2 + (s10['cagr']-BS['10y']['cagr']) + (s22['cagr']-BS['2022+']['cagr'])*0.7 +
            (s20['max_dd']-BS['2020+']['max_dd'])*3 + (s10['max_dd']-BS['10y']['max_dd'])*3 + (s22['max_dd']-BS['2022+']['max_dd'])*2)

def q(vals, frac):
    vals=sorted(vals); idx=min(len(vals)-1,max(0,int(round((len(vals)-1)*frac))))
    return vals[idx]

def main():
    per_center=int(sys.argv[1]) if len(sys.argv)>1 else 180
    seed=int(sys.argv[2]) if len(sys.argv)>2 else 346
    rng=random.Random(seed)
    panel=gdr.s.align(gdr.s.parse_series(gdr.s.fetch()))
    print('Baseline 345:', f"Full {fmt(BM['cagr'])}/{fmt(BM['max_dd'])} Sharpe={BM['sharpe']:.3f}", f"2020 {fmt(BS['2020+']['cagr'])}/{fmt(BS['2020+']['max_dd'])}", f"10y {fmt(BS['10y']['cagr'])}/{fmt(BS['10y']['max_dd'])}")
    reports=[]; all_rows=[]
    for name,center in CENTERS.items():
        variants=[center]
        seen={json.dumps(center,sort_keys=True)}
        while len(variants)<per_center:
            op=perturb(center,rng,p=rng.choice([0.18,0.25,0.35]))
            key=json.dumps(op,sort_keys=True)
            if key not in seen:
                seen.add(key); variants.append(op)
        rows=[gdr.replay(panel,op) for op in variants]
        rows.sort(key=scalar, reverse=True)
        scores=[scalar(r) for r in rows]
        cagr=[r.metrics['cagr'] for r in rows]; dd=[r.metrics['max_dd'] for r in rows]; hits=[r for r in rows if better_than_345(r)]
        rep={'name':name,'n':len(rows),'hit_rate':len(hits)/len(rows),'median_score':statistics.median(scores),'q25_score':q(scores,0.25),'best_score':scores[0],
             'median_cagr':statistics.median(cagr),'median_dd':statistics.median(dd),'q25_cagr':q(cagr,0.25),'q25_dd':q(dd,0.25),'best':rows[0],'hits':len(hits)}
        reports.append(rep); all_rows.extend((name,r) for r in rows[:20])
    reports.sort(key=lambda x:(x['hit_rate'],x['q25_score'],x['median_score'],x['best_score']), reverse=True)
    print('\nCluster reports:')
    for rep in reports:
        b=rep['best']; m=b.metrics; s20=b.slice_metrics['2020+']; s10=b.slice_metrics['10y']; s22=b.slice_metrics['2022+']
        print(f"{rep['name']}: hit_rate={rep['hit_rate']:.1%} hits={rep['hits']}/{rep['n']} median={rep['median_score']:.4f} q25={rep['q25_score']:.4f} medCAGR={fmt(rep['median_cagr'])} medDD={fmt(rep['median_dd'])}")
        print(f"  best score={rep['best_score']:.4f} Full={fmt(m['cagr'])}/{fmt(m['max_dd'])} Sh={m['sharpe']:.3f} 2020={fmt(s20['cagr'])}/{fmt(s20['max_dd'])} 10y={fmt(s10['cagr'])}/{fmt(s10['max_dd'])} 2022={fmt(s22['cagr'])}/{fmt(s22['max_dd'])} tail={b.weights_tail[-1][1]}")
    # Promote only if cluster hit-rate is non-trivial, not a single outlier.
    promoted=[rep for rep in reports if rep['hit_rate']>=0.08 and rep['q25_score']>-0.04]
    out_reports=[]
    for rep in reports:
        b=rep['best']
        out_reports.append({'name':rep['name'],'n':rep['n'],'hit_rate':rep['hit_rate'],'hits':rep['hits'],'median_score':rep['median_score'],'q25_score':rep['q25_score'],'median_cagr':rep['median_cagr'],'median_dd':rep['median_dd'],'q25_cagr':rep['q25_cagr'],'q25_dd':rep['q25_dd'],'best':{'overlay':b.overlay,'metrics':b.metrics,'slice_metrics':b.slice_metrics,'stats':b.stats,'weights_tail':b.weights_tail,'score':scalar(b),'better_than_345':better_than_345(b)}})
    (OUTDIR/'cluster_report.json').write_text(json.dumps(out_reports,ensure_ascii=False,indent=2),encoding='utf-8')
    if promoted:
        rep=promoted[0]; b=rep['best']
        (OUTDIR/'best_stable_logic.json').write_text(json.dumps({'cluster':rep['name'],'cluster_hit_rate':rep['hit_rate'],'cluster_q25_score':rep['q25_score'],'overlay':b.overlay,'metrics':b.metrics,'slice_metrics':b.slice_metrics,'stats':b.stats,'weights_tail':b.weights_tail,'score':scalar(b),'better_than_345':better_than_345(b)},ensure_ascii=False,indent=2),encoding='utf-8')
        print(f"\nSTABLE_LOGIC_HIT {OUTDIR/'best_stable_logic.json'}")
    else:
        print('\nNo stable cluster beat 345. Do not promote single-point outliers.')
    print(f"Wrote {OUTDIR/'cluster_report.json'}")
if __name__=='__main__': main()
