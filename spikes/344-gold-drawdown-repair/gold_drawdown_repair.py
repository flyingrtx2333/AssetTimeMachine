#!/usr/bin/env python3
"""Spike 344 - Gold sleeve drawdown repair on incumbent.

Attribution showed incumbent's largest drawdowns are mostly gold sleeve losses
(2022, 2008, 2006, 2011, 2026). This overlay keeps incumbent return engine but
caps gold when gold itself is in a slow drawdown regime. Freed weight is handed
to healthy US equity only if available; otherwise cash.

This is not an OHLC forced-sell rule and not a full strategy rewrite.
"""
from __future__ import annotations
import importlib.util, json, math, pathlib, random, statistics, sys
from dataclasses import dataclass
from typing import Dict, Optional

ROOT=pathlib.Path(__file__).resolve().parents[2]
EVT_PATH=ROOT/'spikes/336-ohlc-event-overlay/ohlc_event_overlay.py'
REFINED=ROOT/'spikes/336-ohlc-event-overlay/refined_results.json'
OUTDIR=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('evt',EVT_PATH)
if spec is None or spec.loader is None: raise RuntimeError(EVT_PATH)
evt=importlib.util.module_from_spec(spec); sys.modules['evt']=evt; spec.loader.exec_module(evt)
s=evt.s; FEE=evt.FEE; TRADING_DAYS=evt.TRADING_DAYS
INC=json.loads(REFINED.read_text())[0]
INCUMBENT={'cagr':INC['metrics']['cagr'],'max_dd':INC['metrics']['max_dd'],'sharpe':INC['metrics']['sharpe'],'cagr_2020':INC['slice_metrics']['2020+']['cagr'],'dd_2020':INC['slice_metrics']['2020+']['max_dd'],'cagr_10y':INC['slice_metrics']['10y']['cagr'],'dd_10y':INC['slice_metrics']['10y']['max_dd']}

def finite(x): return evt.finite(x)
def pct(panel,sym,i,n): return evt.pct(panel,sym,i,n)
def ma(panel,sym,i,n): return evt.ma(panel,sym,i,n)
def trend(panel,sym,i,ma_n,mom_n,min_mom):
    c=panel.close[sym][i]; m=ma(panel,sym,i,ma_n); r=pct(panel,sym,i,mom_n)
    return finite(c) and finite(m) and r is not None and c>m and r>min_mom

def dd_high(panel,sym,i,n):
    if i<n: return None
    arr=panel.close[sym]; win=[x for x in arr[i-n+1:i+1] if finite(x)]
    if not win: return None
    c=arr[i]; hi=max(win)
    if not finite(c) or hi<=0: return None
    return c/hi-1

def vol(panel,sym,i,n):
    if i<n+1: return None
    arr=panel.close[sym]; rs=[]
    for k in range(i-n+1,i+1):
        if finite(arr[k]) and finite(arr[k-1]) and arr[k-1]>0: rs.append(arr[k]/arr[k-1]-1)
    if len(rs)<max(20,n//2): return None
    return statistics.pstdev(rs)*math.sqrt(TRADING_DAYS)

def normalize(w,cap): return s.normalize_weights({k:v for k,v in w.items() if v>1e-9},cap)

def gold_bad(panel,i,op):
    d1=dd_high(panel,'gold',i,op['dd_fast_n']) or 0
    d2=dd_high(panel,'gold',i,op['dd_slow_n']) or 0
    m1=pct(panel,'gold',i,op['mom_fast_n']) or 0
    m2=pct(panel,'gold',i,op['mom_slow_n']) or 0
    c=panel.close['gold'][i]; ma_fast=ma(panel,'gold',i,op['ma_fast']); ma_slow=ma(panel,'gold',i,op['ma_slow'])
    bad_draw=(d1<op['dd_fast_cut']) or (d2<op['dd_slow_cut'])
    bad_trend=(finite(c) and finite(ma_fast) and c<ma_fast and m1<op['mom_fast_cut']) or (finite(c) and finite(ma_slow) and c<ma_slow and m2<op['mom_slow_cut'])
    hot_reversal=(m1<op['mom_fast_cut'] and d1<op['dd_fast_cut']*0.6)
    return (bad_draw and bad_trend) or hot_reversal

def repair(panel,i,base,p,op):
    out=dict(base); g=out.get('gold',0.0)
    if g<=1e-9 or not gold_bad(panel,i,op): return out
    target=min(g,op['gold_stress_cap'])
    # If gold is deeply underwater, allow even lower cap.
    if (dd_high(panel,'gold',i,op['dd_slow_n']) or 0) < op['deep_dd_cut']:
        target=min(target,op['gold_deep_cap'])
    freed=max(0,g-target); out['gold']=target
    # Handoff only to healthy equities; avoid forced equity in broad stress.
    candidates=[]
    for sym,min_mom in [('nasdaq',op['nas_min_mom']),('sp500',op['sp_min_mom'])]:
        if trend(panel,sym,i,op['eq_ma'],op['eq_mom_n'],min_mom):
            v=vol(panel,sym,i,op['vol_n']) or 0.2
            mom=pct(panel,sym,i,op['score_mom_n']) or 0
            d=dd_high(panel,sym,i,op['eq_dd_n']) or 0
            if d>op['eq_dd_floor']:
                candidates.append((mom/max(v,0.06),sym))
    candidates.sort(reverse=True)
    if candidates and freed>1e-9:
        top=candidates[0][1]
        out[top]=out.get(top,0)+freed*op['handoff_ratio']
        if len(candidates)>1:
            out[candidates[1][1]]=out.get(candidates[1][1],0)+freed*op['second_ratio']
    return normalize(out,p['cap'])

@dataclass
class Replay:
    name:str; params:dict; overlay:dict; metrics:dict; slice_metrics:dict; stats:dict; weights_tail:list; score:float

def replay(panel,op):
    p=dict(INC['params']); dates=panel.dates; eq=[1.0]; weights={}; exp=0; turn=0; repairs=0; freed_sum=0; tail=[]
    for t in range(1,len(dates)):
        i=t-1
        base=evt.event_overlay_signal(panel,i,weights,p)
        nw=repair(panel,i,base,p,op)
        if nw.get('gold',0)<base.get('gold',0)-1e-9:
            repairs+=1; freed_sum += base.get('gold',0)-nw.get('gold',0)
        nw={k:v for k,v in nw.items() if v>1e-9}
        turnover=sum(abs(nw.get(a,0)-weights.get(a,0)) for a in set(nw)|set(weights))
        dr=0; valid=True
        for a,w in nw.items():
            c=panel.close[a]
            if not(finite(c[t]) and finite(c[t-1]) and c[t-1]>0): valid=False; break
            dr += w*(c[t]/c[t-1]-1)
        if not valid: dr=0
        eq.append(max(eq[-1]*(1+dr-turnover*FEE),1e-9)); weights=nw; exp+=sum(weights.values()); turn+=turnover
        if t>len(dates)-8: tail.append((dates[t],dict(sorted(weights.items()))))
    m=s.metrics(dates,eq); slices={'2016+':s.metrics(dates,eq,'2016-01-01'),'2020+':s.metrics(dates,eq,'2020-01-01'),'10y':s.metrics(dates,eq,'2016-07-02'),'2022+':s.metrics(dates,eq,'2022-01-01')}
    stats={'avg_exposure':exp/max(len(dates)-1,1),'turnover':turn,'repair_days':repairs,'freed_gold_sum':freed_sum}
    return Replay('incumbent_gold_drawdown_repair',INC['params'],op,m,slices,stats,tail,score(m,slices,stats))

def score(m,slices,stats):
    return (m['cagr']*7 + slices['2020+']['cagr']*1.2 + slices['10y']['cagr'] + m['sharpe']*0.15 - max(0,abs(m['max_dd'])-0.105)*12 - max(0,abs(slices['2020+']['max_dd'])-0.115)*5 - max(0,abs(slices['10y']['max_dd'])-0.115)*5 - max(0,60-stats['repair_days'])*0.0002)

def promotion(r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']
    return (m['cagr']>INCUMBENT['cagr']+0.0008 and m['max_dd']>=INCUMBENT['max_dd']+0.001 and m['sharpe']>=INCUMBENT['sharpe']-0.015 and s20['cagr']>=INCUMBENT['cagr_2020']-0.003 and s20['max_dd']>=INCUMBENT['dd_2020']+0.001 and s10['cagr']>=INCUMBENT['cagr_10y']-0.0015 and s10['max_dd']>=INCUMBENT['dd_10y']+0.001 and r.stats['avg_exposure']>=0.55)

def random_overlay(rng):
    return {'dd_fast_n':rng.choice([20,40,63]),'dd_slow_n':rng.choice([126,189,252]),'dd_fast_cut':rng.choice([-0.05,-0.07,-0.09]),'dd_slow_cut':rng.choice([-0.10,-0.14,-0.18]),'deep_dd_cut':rng.choice([-0.16,-0.20,-0.24]),'mom_fast_n':rng.choice([20,40,60]),'mom_slow_n':rng.choice([90,120,180]),'mom_fast_cut':rng.choice([-0.03,-0.05,-0.08]),'mom_slow_cut':rng.choice([-0.05,-0.08,-0.12]),'ma_fast':rng.choice([50,80,100]),'ma_slow':rng.choice([160,200]),'gold_stress_cap':rng.choice([0.12,0.18,0.24,0.30]),'gold_deep_cap':rng.choice([0.05,0.10,0.15,0.22]),'eq_ma':rng.choice([120,160,200]),'eq_mom_n':rng.choice([60,120]),'nas_min_mom':rng.choice([0.02,0.05,0.08]),'sp_min_mom':rng.choice([0.0,0.02,0.04]),'vol_n':rng.choice([63,126]),'score_mom_n':rng.choice([60,120]),'eq_dd_n':rng.choice([63,126]),'eq_dd_floor':rng.choice([-0.08,-0.12,-0.16]),'handoff_ratio':rng.choice([0.0,0.35,0.60,0.85]),'second_ratio':rng.choice([0.0,0.15,0.30])}

def fmt(x): return 'NA' if x is None else f'{x*100:.2f}%'
def print_row(i,r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']; s22=r.slice_metrics['2022+']
    print(f"#{i:02d} score={r.score:.4f} CAGR={fmt(m['cagr'])} DD={fmt(m['max_dd'])} Sharpe={m['sharpe']:.2f} 2020={fmt(s20['cagr'])}/{fmt(s20['max_dd'])} 10y={fmt(s10['cagr'])}/{fmt(s10['max_dd'])} 2022={fmt(s22['cagr'])}/{fmt(s22['max_dd'])} exp={r.stats['avg_exposure']:.2f} turn={r.stats['turnover']:.1f} repairs={r.stats['repair_days']} tail={r.weights_tail[-1][1] if r.weights_tail else {}}",flush=True)

def main():
    count=int(sys.argv[1]) if len(sys.argv)>1 else 700; seed=int(sys.argv[2]) if len(sys.argv)>2 else 344
    rng=random.Random(seed); panel=s.align(s.parse_series(s.fetch())); rows=[]; seen=set()
    for _ in range(count):
        op=random_overlay(rng); key=json.dumps(op,sort_keys=True)
        if key in seen: continue
        seen.add(key); rows.append(replay(panel,op))
    rows.sort(key=lambda r:r.score,reverse=True); hits=[r for r in rows if promotion(r)]
    print('Incumbent:',INCUMBENT); print(f'Ran {len(rows)} gold drawdown repair candidates count={count} seed={seed}'); print(f'Promotion hits: {len(hits)}\n')
    for i,r in enumerate(rows[:30],1): print_row(i,r)
    out=OUTDIR/'results.json'; out.write_text(json.dumps([{'name':r.name,'params':r.params,'overlay':r.overlay,'metrics':r.metrics,'slice_metrics':r.slice_metrics,'stats':r.stats,'weights_tail':r.weights_tail,'score':r.score,'promotion':promotion(r)} for r in rows[:200]],ensure_ascii=False,indent=2),encoding='utf-8')
    if hits:
        (OUTDIR/'best_hit.json').write_text(json.dumps({'name':hits[0].name,'params':hits[0].params,'overlay':hits[0].overlay,'metrics':hits[0].metrics,'slice_metrics':hits[0].slice_metrics,'stats':hits[0].stats,'weights_tail':hits[0].weights_tail,'score':hits[0].score},ensure_ascii=False,indent=2),encoding='utf-8')
        print(f"\nBEST_HIT {OUTDIR/'best_hit.json'}")
    print(f"\nWrote {out}")
if __name__=='__main__': main()
