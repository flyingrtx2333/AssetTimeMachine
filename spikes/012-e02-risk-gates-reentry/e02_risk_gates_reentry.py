#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt
from pathlib import Path
from typing import Callable

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('E11', ROOT/'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py')
E=importlib.util.module_from_spec(spec); sys.modules['E11']=E; spec.loader.exec_module(E)  # type: ignore
Z=E.Z; CORE=E.CORE
OUT=Path('/tmp/atm_e02_risk_gates_reentry_012.json')
HOLDINGS=['nasdaq','gold_cny']
TARGET_ANN=0.12; TARGET_DD=0.08
pct=Z.pct
mom=Z.mom; ma=Z.ma; above=Z.above; realized_vol=Z.realized_vol; dd_series=Z.dd_series
normalize=Z.normalize
virtual_barbell=Z.virtual_barbell; virtual_ma=Z.virtual_ma; virtual_mom=Z.virtual_mom


def metrics(dates,vals,start=None,end=None): return Z.metrics(dates,vals,start,end)
def all_metrics(dates,vals): return Z.all_metrics(dates,vals)
def topdds(dates,vals,weights): return Z.topdds(dates,vals,weights)

def count(ctx,name):
    ev=ctx.setdefault('event_counts',{})
    ev[name]=ev.get(name,0)+1

def spx_liquidity_shock(p,i):
    # Pure signal gate; SP500 is not a holding. Detect fast cash-demand/liquidity breaks.
    if i<63: return False
    sp5=mom(p['sp500'],i,5) or 0
    sp10=mom(p['sp500'],i,10) or 0
    sp21=mom(p['sp500'],i,21) or 0
    nq5=mom(p['nasdaq'],i,5) or 0
    nq10=mom(p['nasdaq'],i,10) or 0
    v10=realized_vol(p['sp500'],i,10) or 0
    v63=realized_vol(p['sp500'],i,63) or 0.18
    return sp5<-0.055 or sp10<-0.075 or (sp21<-0.10 and not above(p,'sp500',i,40)) or (nq5<-0.080 and nq10<-0.105) or (v10>v63*2.4 and sp10<-0.035)

def slow_barbell_damage(p,i):
    if i<160: return False
    vb=virtual_barbell(p,i,0.5,0.5); m80=virtual_ma(p,i,80,0.5,0.5); m160=virtual_ma(p,i,160,0.5,0.5)
    if m80 is None or m160 is None: return False
    return (vb<m80<m160 and (virtual_mom(p,i,42,0.5,0.5) or 0)<-0.035)

def recovered_barbell(p,i):
    if i<160: return False
    vb=virtual_barbell(p,i,0.5,0.5); m40=virtual_ma(p,i,40,0.5,0.5); m120=virtual_ma(p,i,120,0.5,0.5)
    return m40 is not None and m120 is not None and vb>m40>m120 and (virtual_mom(p,i,21,0.5,0.5) or 0)>0.025

def gold_liquidity_trap(p,i):
    # Gold can fail as an airbag in fast deleveraging or after its own blowoff.
    if i<126: return False
    return ((mom(p['gold_cny'],i,5) or 0)<-0.035 and (mom(p['sp500'],i,10) or 0)<-0.035) or ((mom(p['gold_cny'],i,126) or 0)>0.20 and (mom(p['gold_cny'],i,10) or 0)<-0.035)

def trend_ok(p,s,i,ma_n=120,mom_n=63,th=0.0):
    return above(p,s,i,ma_n) and (mom(p[s],i,mom_n) or -9)>th

def cap_target(target, ncap=None, gcap=None, gross=None):
    t=dict(target or {})
    if ncap is not None: t['nasdaq']=min(t.get('nasdaq',0),ncap)
    if gcap is not None: t['gold_cny']=min(t.get('gold_cny',0),gcap)
    return normalize(t,gross if gross is not None else 0.98)

# Base E02 from 011: breakout buy + chandelier + rollover take-profit.
def base_e02(): return E.E02_breakout_chandelier('loose')

def R01_liquidity_gold_exit():
    base=base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if spx_liquidity_shock(p,i):
            st['shock_cool']=max(st.get('shock_cool',0),10)
            count(ctx,'liquidity_shock')
        st['shock_cool']=max(0,st.get('shock_cool',0)-1)
        if st.get('shock_cool',0)>0:
            # In liquidity shock, both Nasdaq and gold can fall; cash is the hedge.
            return {}
        return normalize(target,0.90)
    return fn

def R02_slow_damage_ratchet():
    base=base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if slow_barbell_damage(p,i) or ctx.get('portfolio_dd',0)>0.070:
            st['ratchet']=max(st.get('ratchet',0),30)
            count(ctx,'slow_damage_ratchet')
        if recovered_barbell(p,i) and ctx.get('portfolio_dd',0)<0.035:
            st['ratchet']=0
        st['ratchet']=max(0,st.get('ratchet',0)-1)
        if st.get('ratchet',0)>0:
            return cap_target(target,ncap=0.22,gcap=0.24,gross=0.46)
        return normalize(target,0.90)
    return fn

def R03_gold_trap_filter():
    base=base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if gold_liquidity_trap(p,i):
            st['gold_forbid']=max(st.get('gold_forbid',0),18)
            count(ctx,'gold_liquidity_trap')
        st['gold_forbid']=max(0,st.get('gold_forbid',0)-1)
        if st.get('gold_forbid',0)>0:
            target['gold_cny']=0.0
        return normalize(target,0.90)
    return fn

def R04_shock_plus_fast_reentry():
    base=base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if spx_liquidity_shock(p,i):
            st['shock_cool']=max(st.get('shock_cool',0),12)
            count(ctx,'liquidity_shock')
        st['shock_cool']=max(0,st.get('shock_cool',0)-1)
        if st.get('shock_cool',0)>0:
            # Start re-entering before full recovery, but only after actual bounce.
            if (mom(p['nasdaq'],i,5) or 0)>0.045 and above(p,'nasdaq',i,10):
                return {'nasdaq':0.22}
            if trend_ok(p,'gold_cny',i,20,10,0.012) and not gold_liquidity_trap(p,i):
                return {'gold_cny':0.18}
            return {}
        return normalize(target,0.92)
    return fn

def R05_combined_guard():
    base=base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if spx_liquidity_shock(p,i):
            st['shock_cool']=max(st.get('shock_cool',0),10); count(ctx,'liquidity_shock')
        if slow_barbell_damage(p,i) or ctx.get('portfolio_dd',0)>0.075:
            st['ratchet']=max(st.get('ratchet',0),25); count(ctx,'slow_damage_ratchet')
        if gold_liquidity_trap(p,i):
            st['gold_forbid']=max(st.get('gold_forbid',0),16); count(ctx,'gold_liquidity_trap')
        for k in ['shock_cool','ratchet','gold_forbid']:
            st[k]=max(0,st.get(k,0)-1)
        if st.get('shock_cool',0)>0:
            # cash first, tiny reentry only after a bounce
            if (mom(p['nasdaq'],i,5) or 0)>0.05 and above(p,'nasdaq',i,10): return {'nasdaq':0.18}
            return {}
        if st.get('gold_forbid',0)>0:
            target['gold_cny']=0.0
        if st.get('ratchet',0)>0:
            target=cap_target(target,ncap=0.26,gcap=0.20,gross=0.46)
        return normalize(target,0.88)
    return fn

def R06_regime_scaled_e02():
    # Same E02 entries/exits, but exposure budget adapts to barbell health and US trend.
    base=base_e02()
    def fn(dates,p,i,ctx):
        target=base(dates,p,i,ctx) or {}
        us_good=above(p,'sp500',i,120) and (mom(p['sp500'],i,63) or -9)>0
        vb_good=recovered_barbell(p,i) or (virtual_mom(p,i,63,0.5,0.5) or -9)>0.06
        if spx_liquidity_shock(p,i):
            count(ctx,'liquidity_shock')
            return {}
        if us_good and vb_good:
            return normalize(target,0.92)
        if us_good or vb_good:
            return cap_target(target,ncap=0.42,gcap=0.32,gross=0.68)
        return cap_target(target,ncap=0.18,gcap=0.22,gross=0.36)
    return fn

def R07_defensive_e02_lowdd():
    # Lower-DD target: does not aim at 12 return; checks if 8 DD with decent return is reachable.
    base=base_e02()
    def fn(dates,p,i,ctx):
        target=base(dates,p,i,ctx) or {}
        if spx_liquidity_shock(p,i) or gold_liquidity_trap(p,i):
            count(ctx,'defensive_shock_cash')
            return {}
        if ctx.get('portfolio_dd',0)>0.055 or slow_barbell_damage(p,i):
            count(ctx,'defensive_brake')
            return cap_target(target,ncap=0.14,gcap=0.18,gross=0.28)
        return cap_target(target,ncap=0.48,gcap=0.34,gross=0.72)
    return fn

CANDIDATES=[
    ('REF_E02_loose_from_011','reference E02 breakout/chandelier loose',base_e02()),
    ('R01_liquidity_gold_exit','E02 + SP500/Nasdaq liquidity shock exits both Nasdaq and gold to cash',R01_liquidity_gold_exit()),
    ('R02_slow_damage_ratchet','E02 + slow barbell damage / portfolio DD ratchet caps risk until recovery',R02_slow_damage_ratchet()),
    ('R03_gold_trap_filter','E02 + forbid gold during liquidity trap / gold blowoff rollover',R03_gold_trap_filter()),
    ('R04_shock_fast_reentry','E02 + liquidity shock cash, then small fast re-entry after bounce',R04_shock_plus_fast_reentry()),
    ('R05_combined_guard','E02 + shock cash + slow damage ratchet + gold trap filter',R05_combined_guard()),
    ('R06_regime_scaled_e02','E02 + exposure budget scaled by US trend and virtual barbell health',R06_regime_scaled_e02()),
    ('R07_defensive_lowdd','E02 low-DD sibling: aggressive brakes, test if <8 DD still has useful return',R07_defensive_e02_lowdd()),
]

def row_for(dates,p,item):
    name,desc,fn=item
    vals,w,e=E.simulate_event(dates,p,fn,rebalance=1,band=0.02)
    m=all_metrics(dates,vals)
    return {
        'name':name,'description':desc,'metrics':m,
        'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in Z.STRESS.items()},
        'extra':e,'top_dd':topdds(dates,vals,w),
        'pass_12_8':m['full']['ann']>=TARGET_ANN and m['full']['dd']<=TARGET_DD,
    }

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[row_for(dates,p,c) for c in CANDIDATES]
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'target':{'ann':TARGET_ANN,'dd':TARGET_DD},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    print('\nSorted by full annualized:')
    for r in sorted(rows,key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; mark='PASS' if r['pass_12_8'] else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'],'events',r['extra'].get('events',{}))
        print('  topdd',' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
    print('\nBest under 12% DD:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.12],key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; print(r['name'],f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f}",r['extra'].get('events',{}))
    print('PASS_COUNT',sum(1 for r in rows if r['pass_12_8']))
if __name__=='__main__': run()
