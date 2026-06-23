#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, math, statistics
from pathlib import Path
from typing import Callable
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('S', ROOT/'spikes/009-strict-12-8-target/strict_12_8_target.py')
S=importlib.util.module_from_spec(spec); sys.modules['S']=S; spec.loader.exec_module(S)  # type: ignore
Z=S.Z; CORE=S.CORE
OUT=Path('/tmp/atm_gold_nasdaq_strategy_surf_12_8.json')

def pct(x): return f'{x*100:.2f}%'

def maxdd(vals):
    peak=vals[0]; dd=0
    for v in vals:
        peak=max(peak,v); dd=max(dd,1-v/peak)
    return dd

def ma(vals,i,n):
    return None if i-n+1<0 else sum(vals[i-n+1:i+1])/n

def mom(vals,i,n):
    return None if i-n<0 or vals[i-n]<=0 else vals[i]/vals[i-n]-1

def simulate_weights(dates,p,weight_fn:Callable,rebalance=5,band=0.02):
    cash=S.START; units={s:0.0 for s in S.HOLDINGS}; vals=[]; weights=[]; trades=0; ctx={'peak':S.START,'state':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in S.HOLDINGS)
        ctx['peak']=max(ctx.get('peak',val),val)
        if i>0 and i%rebalance==0:
            sig=i-1
            ctx['portfolio_dd']=1-val/ctx['peak'] if ctx['peak'] else 0
            target=weight_fn(dates,p,sig,ctx)
            cash,units,did=S.trade_to(cash,units,p,i,target,band=band)
            if did: trades+=1
            val=cash+sum(units[s]*p[s][i] for s in S.HOLDINGS)
        vals.append(val); weights.append({s:units[s]*p[s][i]/val for s in S.HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

# Aggressive engines as pure weight functions.
def E01_allin_best_abs_mom(dates,p,i,ctx):
    scores={}
    for s in S.HOLDINGS:
        m6=S.mom(p[s],i,126) or -9
        m3=S.mom(p[s],i,63) or -9
        scores[s]=m6+0.5*m3
    best=max(scores,key=lambda k:scores[k])
    if scores[best]<=0: return {}
    return {best:0.98}

def E02_nasdaq_growth_gold_crisis(dates,p,i,ctx):
    nq=S.above(p,'nasdaq',i,160) and (S.mom(p['nasdaq'],i,126) or -1)>0 and S.positive_6m(p,'sp500',i)
    gold=S.above(p,'gold_cny',i,120) and (S.mom(p['gold_cny'],i,63) or -1)>0
    equity_stress=(S.mom(p['sp500'],i,63) or 0)<-0.04 or not S.above(p,'sp500',i,160)
    if nq and not equity_stress: return {'nasdaq':0.90,'gold_cny':0.08 if gold else 0.0}
    if gold: return {'gold_cny':0.90}
    return {}

def E03_breakout_pair(dates,p,i,ctx):
    # All-in only on fresh trend breakouts; otherwise cash.
    rn=(S.mom(p['nasdaq'],i,63) or 0); rg=(S.mom(p['gold_cny'],i,63) or 0)
    nq_break=S.above(p,'nasdaq',i,80) and S.above(p,'nasdaq',i,200) and rn>0.08
    g_break=S.above(p,'gold_cny',i,80) and S.above(p,'gold_cny',i,200) and rg>0.05
    if nq_break and rn>rg: return {'nasdaq':0.98}
    if g_break: return {'gold_cny':0.98}
    return {}

def E04_m13_like_high_base(dates,p,i,ctx):
    # High base, event harvest. It is intentionally aggressive to see if surfing can tame it.
    w=ctx.get('sig_w',{})
    if not w: return {'nasdaq':0.55,'gold_cny':0.35}
    target=dict(w); changed=False
    for s,b in {'nasdaq':0.55,'gold_cny':0.35}.items():
        blow=(S.mom(p[s],i,252) or 0)>0.35 and (S.mom(p[s],i,21) or 0)<-0.03
        if w.get(s,b)>b*1.35 and blow:
            target[s]=b; changed=True
        if w.get(s,0)<b*0.75 and S.above(p,s,i,160) and (S.mom(p[s],i,126) or 0)>0.04:
            target[s]=b; changed=True
    return target if changed else w

def build_engine_curve(dates,p,fn,rebalance):
    vals,w,e=simulate_weights(dates,p,fn,rebalance=rebalance,band=0.02)
    return vals,w,e

def surf_engine(engine_vals, engine_weights, fallback_fn:Callable, fast=80, slow=200, dd_cut=0.08):
    def fn(dates,p,i,ctx):
        ev=engine_vals
        if i>=len(ev): i=len(ev)-1
        mf=ma(ev,i,fast); ms=ma(ev,i,slow)
        recent_dd=maxdd(ev[max(0,i-252):i+1]) if i>10 else 0
        engine_on=mf is not None and ms is not None and ev[i]>mf>ms and recent_dd<dd_cut and (mom(ev,i,63) or 0)>0
        if ctx.get('portfolio_dd',0)>0.07:
            # realized product-level circuit breaker.
            return {'gold_cny':0.25} if S.sleeve_ok(p,'gold_cny',i) else {}
        if engine_on:
            return engine_weights[i]
        return fallback_fn(dates,p,i,ctx)
    return fn

def fallback_m34lite(dates,p,i,ctx):
    state,vdd=S.barbell_health_state(p,i)
    if state=='healthy' and S.recovered_barbell(p,i):
        if S.score_asset(p,'nasdaq',i)>S.score_asset(p,'gold_cny',i) and S.sleeve_ok(p,'nasdaq',i):
            return {'nasdaq':0.45,'gold_cny':0.30 if S.sleeve_ok(p,'gold_cny',i) else 0.0}
        if S.sleeve_ok(p,'gold_cny',i): return {'nasdaq':0.25 if S.sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.45}
    if state=='bruised': return {'nasdaq':0.20 if S.sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.30 if S.sleeve_ok(p,'gold_cny',i) else 0.0}
    return {'gold_cny':0.20} if S.sleeve_ok(p,'gold_cny',i) else {}

def fallback_cash_or_gold(dates,p,i,ctx):
    return {'gold_cny':0.30} if S.sleeve_ok(p,'gold_cny',i) else {}

ENGINES=[
    ('E01_allin_best_abs_mom',E01_allin_best_abs_mom,21),
    ('E02_nasdaq_growth_gold_crisis',E02_nasdaq_growth_gold_crisis,5),
    ('E03_breakout_pair',E03_breakout_pair,5),
    ('E04_m13_like_high_base',E04_m13_like_high_base,20),
]

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[]
    for ename,efn,erb in ENGINES:
        ev,ew,ee=build_engine_curve(dates,p,efn,erb)
        em=S.all_metrics(dates,ev)
        rows.append({'name':ename,'description':'raw aggressive engine','mode':'engine','metrics':em,'extra':ee,'top_dd':S.topdds(dates,ev,ew)})
        for fbname,fb in [('m34lite',fallback_m34lite),('goldcash',fallback_cash_or_gold)]:
            for fast,slow,dd_cut in [(60,160,0.08),(80,200,0.08),(80,200,0.12)]:
                name=f'SURF_{ename}_{fbname}_f{fast}_s{slow}_dd{int(dd_cut*100)}'
                fn=surf_engine(ev,ew,fb,fast=fast,slow=slow,dd_cut=dd_cut)
                vals,w,e=simulate_weights(dates,p,fn,rebalance=5,band=0.02)
                rows.append({'name':name,'description':f'strategy equity-curve surf of {ename} with {fbname} fallback','mode':'surf','metrics':S.all_metrics(dates,vals),'extra':e,'top_dd':S.topdds(dates,vals,w)})
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT)
    for r in sorted(rows,key=lambda x:x['metrics']['full']['ann'],reverse=True)[:30]:
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']
        mark='PASS' if m['ann']>=0.12 and m['dd']<=0.08 else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'])
    print('\nUnder 8 DD sorted by ann:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.08],key=lambda x:x['metrics']['full']['ann'],reverse=True)[:20]:
        m=r['metrics']['full']; print(r['name'],f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f}")
if __name__=='__main__': run()
