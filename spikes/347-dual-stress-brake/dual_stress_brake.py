#!/usr/bin/env python3
"""Spike 347 - dual-stress brake on top of stable gold repair.

Logic, not cherry-pick:
- Gold repair says: gold is broken, reduce gold sleeve.
- New rule says: if US equities are also under stress, do not force handoff into
  equities. Cap total equity sleeve and let freed weight remain cash.

Promotion requires beating 345; cluster summary is reported.
"""
from __future__ import annotations
import importlib.util, json, pathlib, random, statistics, sys

ROOT=pathlib.Path(__file__).resolve().parents[2]
GDR_PATH=ROOT/'spikes/344-gold-drawdown-repair/gold_drawdown_repair.py'
BASE345_PATH=ROOT/'spikes/345-gold-repair-refine/best_hit.json'
OUTDIR=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('gdr',GDR_PATH)
if spec is None or spec.loader is None: raise RuntimeError(GDR_PATH)
gdr=importlib.util.module_from_spec(spec); sys.modules['gdr']=gdr; spec.loader.exec_module(gdr)
BASE345=json.loads(BASE345_PATH.read_text())
BASE_OP=BASE345['overlay']; BM=BASE345['metrics']; BS=BASE345['slice_metrics']

def finite(x): return gdr.finite(x)
def pct(panel,sym,i,n): return gdr.pct(panel,sym,i,n)
def dd_high(panel,sym,i,n): return gdr.dd_high(panel,sym,i,n)
def ma(panel,sym,i,n): return gdr.ma(panel,sym,i,n)
def norm(w,cap): return gdr.normalize(w,cap)

def eq_bad(panel,i,sym,op):
    mfast=pct(panel,sym,i,op['eq_fast_mom_n']) or 0
    mslow=pct(panel,sym,i,op['eq_slow_mom_n']) or 0
    dd=dd_high(panel,sym,i,op['eq_dd_n']) or 0
    c=panel.close[sym][i]; mm=ma(panel,sym,i,op['eq_ma'])
    trend_bad=finite(c) and finite(mm) and c<mm and mslow<op['eq_slow_cut']
    shock_bad=(mfast<op['eq_fast_cut'] and dd<op['eq_dd_cut'])
    return trend_bad or shock_bad

def apply_dual_stress(panel,i,base,nw,op):
    # only apply when gold was actually reduced; otherwise do not disturb return engine
    if nw.get('gold',0) >= base.get('gold',0)-1e-9:
        return nw
    nas_bad=eq_bad(panel,i,'nasdaq',op); sp_bad=eq_bad(panel,i,'sp500',op)
    if not (nas_bad or sp_bad): return nw
    out=dict(nw)
    # cap bad equity sleeves. If both bad, cap total equity more aggressively.
    if nas_bad: out['nasdaq']=min(out.get('nasdaq',0),op['nas_stress_cap'])
    if sp_bad: out['sp500']=min(out.get('sp500',0),op['sp_stress_cap'])
    if nas_bad and sp_bad:
        total=out.get('nasdaq',0)+out.get('sp500',0)
        if total>op['dual_eq_total_cap'] and total>0:
            scale=op['dual_eq_total_cap']/total
            out['nasdaq']=out.get('nasdaq',0)*scale; out['sp500']=out.get('sp500',0)*scale
    return norm(out,gdr.INC['params']['cap'])

def replay(panel,op):
    p=dict(gdr.INC['params']); dates=panel.dates; eq=[1.0]; weights={}; exp=turn=repairs=brakes=0; tail=[]
    gold_op={k:op[k] for k in BASE_OP.keys()}
    for t in range(1,len(dates)):
        i=t-1
        base=gdr.evt.event_overlay_signal(panel,i,weights,p)
        repaired=gdr.repair(panel,i,base,p,gold_op)
        nw=apply_dual_stress(panel,i,base,repaired,op)
        if repaired.get('gold',0)<base.get('gold',0)-1e-9: repairs+=1
        if (nw.get('nasdaq',0)+nw.get('sp500',0)) < (repaired.get('nasdaq',0)+repaired.get('sp500',0))-1e-9: brakes+=1
        nw={k:v for k,v in nw.items() if v>1e-9}
        turnover=sum(abs(nw.get(a,0)-weights.get(a,0)) for a in set(nw)|set(weights)); dr=0; valid=True
        for a,w in nw.items():
            c=panel.close[a]
            if not(finite(c[t]) and finite(c[t-1]) and c[t-1]>0): valid=False; break
            dr+=w*(c[t]/c[t-1]-1)
        if not valid: dr=0
        eq.append(max(eq[-1]*(1+dr-turnover*gdr.FEE),1e-9)); weights=nw; exp+=sum(nw.values()); turn+=turnover
        if t>len(dates)-8: tail.append((dates[t],dict(sorted(nw.items()))))
    m=gdr.s.metrics(dates,eq); slices={'2020+':gdr.s.metrics(dates,eq,'2020-01-01'),'10y':gdr.s.metrics(dates,eq,'2016-07-02'),'2022+':gdr.s.metrics(dates,eq,'2022-01-01')}
    return {'overlay':op,'metrics':m,'slice_metrics':slices,'stats':{'avg_exposure':exp/max(len(dates)-1,1),'turnover':turn,'repair_days':repairs,'brake_days':brakes},'weights_tail':tail}

def rand_op(rng):
    op=dict(BASE_OP)
    # Keep gold logic close to 345; vary only coarsely.
    for k,vals in {
        'dd_fast_cut':[-0.07,-0.08,-0.09], 'dd_slow_cut':[-0.14,-0.16,-0.18], 'gold_stress_cap':[0.20,0.22,0.24], 'gold_deep_cap':[0.18,0.20,0.22]
    }.items():
        if rng.random()<0.35: op[k]=rng.choice(vals)
    if op['gold_deep_cap']>op['gold_stress_cap']: op['gold_deep_cap']=op['gold_stress_cap']
    op.update({
        'eq_fast_mom_n':rng.choice([20,30,40]), 'eq_slow_mom_n':rng.choice([90,120,150]), 'eq_ma':rng.choice([120,160,200]),
        'eq_fast_cut':rng.choice([-0.04,-0.06,-0.08]), 'eq_slow_cut':rng.choice([-0.02,-0.04,-0.06]),
        'eq_dd_n':rng.choice([63,90,126]), 'eq_dd_cut':rng.choice([-0.08,-0.10,-0.12]),
        'nas_stress_cap':rng.choice([0.05,0.08,0.12,0.16]), 'sp_stress_cap':rng.choice([0.12,0.18,0.24,0.30]),
        'dual_eq_total_cap':rng.choice([0.12,0.20,0.30,0.40])
    })
    return op

def fmt(x): return f'{x*100:.2f}%'
def better(r):
    m=r['metrics']; s20=r['slice_metrics']['2020+']; s10=r['slice_metrics']['10y']; s22=r['slice_metrics']['2022+']
    return (m['cagr']>=BM['cagr']+0.0005 and m['max_dd']>=BM['max_dd']+0.0005 and m['sharpe']>=BM['sharpe']-0.005 and
            s20['cagr']>=BS['2020+']['cagr']-0.002 and s20['max_dd']>=BS['2020+']['max_dd']-0.0001 and
            s10['cagr']>=BS['10y']['cagr']-0.002 and s10['max_dd']>=BS['10y']['max_dd']-0.0001 and
            s22['cagr']>=BS['2022+']['cagr']-0.002 and s22['max_dd']>=BS['2022+']['max_dd']-0.0001 and r['stats']['brake_days']>=5)

def score(r):
    m=r['metrics']; s20=r['slice_metrics']['2020+']; s10=r['slice_metrics']['10y']; s22=r['slice_metrics']['2022+']
    return ((m['cagr']-BM['cagr'])*8+(m['max_dd']-BM['max_dd'])*10+(m['sharpe']-BM['sharpe'])*0.5+
            (s20['cagr']-BS['2020+']['cagr'])*1.2+(s10['cagr']-BS['10y']['cagr'])+(s22['cagr']-BS['2022+']['cagr'])*0.8+
            (s20['max_dd']-BS['2020+']['max_dd'])*3+(s10['max_dd']-BS['10y']['max_dd'])*3+(s22['max_dd']-BS['2022+']['max_dd'])*2)

def main():
    count=int(sys.argv[1]) if len(sys.argv)>1 else 500; seed=int(sys.argv[2]) if len(sys.argv)>2 else 347
    rng=random.Random(seed); panel=gdr.s.align(gdr.s.parse_series(gdr.s.fetch()))
    rows=[]; seen=set()
    for _ in range(count):
        op=rand_op(rng); key=json.dumps(op,sort_keys=True)
        if key in seen: continue
        seen.add(key); r=replay(panel,op); r['score']=score(r); r['better']=better(r); rows.append(r)
    rows.sort(key=lambda r:r['score'], reverse=True); hits=[r for r in rows if r['better']]
    print('Baseline 345', f"{fmt(BM['cagr'])}/{fmt(BM['max_dd'])} Sh={BM['sharpe']:.3f}", f"2020={fmt(BS['2020+']['cagr'])}/{fmt(BS['2020+']['max_dd'])}", f"10y={fmt(BS['10y']['cagr'])}/{fmt(BS['10y']['max_dd'])}")
    print(f'Ran {len(rows)} dual-stress candidates seed={seed}; hits={len(hits)}')
    for i,r in enumerate(rows[:25],1):
        m=r['metrics']; s20=r['slice_metrics']['2020+']; s10=r['slice_metrics']['10y']; s22=r['slice_metrics']['2022+']
        print(f"#{i:02d} score={r['score']:.4f} hit={r['better']} Full={fmt(m['cagr'])}/{fmt(m['max_dd'])} Sh={m['sharpe']:.3f} 2020={fmt(s20['cagr'])}/{fmt(s20['max_dd'])} 10y={fmt(s10['cagr'])}/{fmt(s10['max_dd'])} 2022={fmt(s22['cagr'])}/{fmt(s22['max_dd'])} brakes={r['stats']['brake_days']} tail={r['weights_tail'][-1][1]}")
    (OUTDIR/'results.json').write_text(json.dumps(rows[:160],ensure_ascii=False,indent=2),encoding='utf-8')
    if hits:
        hits.sort(key=lambda r:r['score'], reverse=True)
        (OUTDIR/'best_hit.json').write_text(json.dumps(hits[0],ensure_ascii=False,indent=2),encoding='utf-8')
        print(f"\nBEST_HIT {OUTDIR/'best_hit.json'}")
    print(f"\nWrote {OUTDIR/'results.json'}")
if __name__=='__main__': main()
