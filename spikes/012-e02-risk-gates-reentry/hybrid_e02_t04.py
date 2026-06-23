#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
# Import 011/E02 and 012/T04 helpers.
spec=importlib.util.spec_from_file_location('E11', ROOT/'spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py')
E=importlib.util.module_from_spec(spec); sys.modules['E11']=E; spec.loader.exec_module(E)  # type: ignore
spec2=importlib.util.spec_from_file_location('T12', ROOT/'spikes/012-e02-risk-gates-reentry/m13_m34_tail_control.py')
T=importlib.util.module_from_spec(spec2); sys.modules['T12']=T; spec2.loader.exec_module(T)  # type: ignore
spec3=importlib.util.spec_from_file_location('R12', ROOT/'spikes/012-e02-risk-gates-reentry/e02_risk_gates_reentry.py')
R=importlib.util.module_from_spec(spec3); sys.modules['R12']=R; spec3.loader.exec_module(R)  # type: ignore
Z=E.Z; CORE=E.CORE
OUT=Path('/tmp/atm_hybrid_e02_t04_012.json')
TARGET_ANN=0.12; TARGET_DD=0.08
HOLDINGS=['nasdaq','gold_cny']
normalize=Z.normalize; mom=Z.mom; above=Z.above; score_asset=Z.score_asset; positive_6m=Z.positive_6m; realized_vol=Z.realized_vol
barbell_health_state=Z.barbell_health_state; virtual_mom=Z.virtual_mom; virtual_barbell=Z.virtual_barbell; virtual_ma=Z.virtual_ma

def count(ctx,name):
    ev=ctx.setdefault('event_counts',{}); ev[name]=ev.get(name,0)+1

def metrics(dates,vals,start=None,end=None): return Z.metrics(dates,vals,start,end)
def all_metrics(dates,vals): return Z.all_metrics(dates,vals)
def topdds(dates,vals,w): return Z.topdds(dates,vals,w)

def vb_recovered(p,i):
    vb=virtual_barbell(p,i,0.5,0.5); m80=virtual_ma(p,i,80,0.5,0.5); m160=virtual_ma(p,i,160,0.5,0.5)
    return m80 is not None and m160 is not None and vb>m80>m160 and (virtual_mom(p,i,42,0.5,0.5) or 0)>0

def cap(t,n=None,g=None,gross=0.92):
    t=dict(t or {})
    if n is not None: t['nasdaq']=min(t.get('nasdaq',0),n)
    if g is not None: t['gold_cny']=min(t.get('gold_cny',0),g)
    return normalize(t,gross)

def H01_E02_health_lift():
    base=E.E02_breakout_chandelier('loose')
    def fn(dates,p,i,ctx):
        target=base(dates,p,i,ctx) or {}
        state,_=barbell_health_state(p,i)
        healthy=state=='healthy' and vb_recovered(p,i) and ctx.get('portfolio_dd',0)<0.055 and not R.spx_liquidity_shock(p,i)
        if healthy:
            sn,sg=score_asset(p,'nasdaq',i),score_asset(p,'gold_cny',i)
            if sn>=sg and positive_6m(p,'nasdaq',i):
                target['nasdaq']=max(target.get('nasdaq',0),0.66 if (realized_vol(p['nasdaq'],i,63) or 0.25)<0.28 else 0.54)
                target['gold_cny']=max(target.get('gold_cny',0),0.18)
                count(ctx,'H01_nasdaq_health_lift')
            elif positive_6m(p,'gold_cny',i):
                target['gold_cny']=max(target.get('gold_cny',0),0.46)
                target['nasdaq']=max(target.get('nasdaq',0),0.20)
                count(ctx,'H01_gold_health_lift')
        if R.slow_barbell_damage(p,i) or ctx.get('portfolio_dd',0)>0.085:
            count(ctx,'H01_tail_cap')
            target=cap(target,n=0.35,g=0.30,gross=0.60)
        return normalize(target,0.92)
    return fn

def H02_E02_core_when_healthy():
    base=E.E02_breakout_chandelier('loose')
    def fn(dates,p,i,ctx):
        target=base(dates,p,i,ctx) or {}
        state,_=barbell_health_state(p,i)
        if state=='healthy' and vb_recovered(p,i) and ctx.get('portfolio_dd',0)<0.045:
            # Add only a small core when E02 has no fresh breakout; avoid turning into full buy-hold.
            if above(p,'nasdaq',i,120) and (mom(p['nasdaq'],i,63) or 0)>0.02:
                target['nasdaq']=max(target.get('nasdaq',0),0.34); count(ctx,'H02_nasdaq_core')
            if above(p,'gold_cny',i,100) and (mom(p['gold_cny'],i,63) or 0)>0.015:
                target['gold_cny']=max(target.get('gold_cny',0),0.26); count(ctx,'H02_gold_core')
        if R.slow_barbell_damage(p,i) or R.spx_liquidity_shock(p,i):
            count(ctx,'H02_risk_cut')
            target=cap(target,n=0.22,g=0.20,gross=0.42)
        return normalize(target,0.90)
    return fn

def H03_T04_stronger_tail():
    base=T.T04_M34_lift_then_excess_tail_brake()
    def fn(dates,p,i,ctx):
        target=base(dates,p,i,ctx) or {}
        pdd=ctx.get('portfolio_dd',0.0)
        barbell_tail=R.slow_barbell_damage(p,i) or (virtual_mom(p,i,42,0.5,0.5) or 0)<-0.045
        if pdd>0.070 and barbell_tail:
            target['nasdaq']=min(target.get('nasdaq',0),0.24)
            target['gold_cny']=min(target.get('gold_cny',0),0.30)
            count(ctx,'H03_first_tail')
        if pdd>0.105 and barbell_tail:
            target['nasdaq']=min(target.get('nasdaq',0),0.14)
            target['gold_cny']=min(target.get('gold_cny',0),0.22)
            count(ctx,'H03_second_tail')
        if R.spx_liquidity_shock(p,i):
            target['nasdaq']=min(target.get('nasdaq',0),0.10)
            target['gold_cny']=min(target.get('gold_cny',0),0.18)
            count(ctx,'H03_liquidity_cap')
        return normalize(target,0.88)
    return fn

def H04_T04_daily_e02_shock():
    # Daily risk detector wrapped around T04, otherwise T4 allocation. This tests whether timing the 2020 air-pocket helps.
    base=T.T04_M34_lift_then_excess_tail_brake()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if R.spx_liquidity_shock(p,i):
            st['shock']=max(st.get('shock',0),8); count(ctx,'H04_shock')
        st['shock']=max(0,st.get('shock',0)-1)
        if st.get('shock',0)>0:
            if (mom(p['nasdaq'],i,5) or 0)>0.055 and above(p,'nasdaq',i,10):
                return {'nasdaq':0.18}
            return {}
        if R.slow_barbell_damage(p,i) and ctx.get('portfolio_dd',0)>0.060:
            count(ctx,'H04_slow_cap')
            return cap(target,n=0.22,g=0.24,gross=0.46)
        return normalize(target,0.90)
    return fn

def H05_E02_plus_T04_only_when_flat():
    e02=E.E02_breakout_chandelier('loose')
    t04=T.T04_M34_lift_then_excess_tail_brake()
    def fn(dates,p,i,ctx):
        t=e02(dates,p,i,ctx) or {}
        if sum(t.values())<0.05:
            state,_=barbell_health_state(p,i)
            if state=='healthy' and vb_recovered(p,i) and ctx.get('portfolio_dd',0)<0.04:
                core=t04(dates,p,i,ctx) or {}
                # Half-size T04 core only when E02 is flat.
                t={'nasdaq':min(core.get('nasdaq',0),0.30),'gold_cny':min(core.get('gold_cny',0),0.24)}
                count(ctx,'H05_half_t04_core')
        if R.slow_barbell_damage(p,i) or R.spx_liquidity_shock(p,i):
            count(ctx,'H05_risk_cut')
            t=cap(t,n=0.18,g=0.16,gross=0.34)
        return normalize(t,0.90)
    return fn

CANDIDATES=[
 ('REF_E02_loose','E02 reference',E.E02_breakout_chandelier('loose'),1),
 ('REF_T04_M34_lift','T04 monthly reference',T.T04_M34_lift_then_excess_tail_brake(),20),
 ('H01_E02_health_lift','E02 + modest health-state lift + tail cap',H01_E02_health_lift(),1),
 ('H02_E02_core_when_healthy','E02 + small core exposure in healthy non-breakout regimes',H02_E02_core_when_healthy(),1),
 ('H03_T04_stronger_tail','T04 + stronger portfolio/barbell/liquidity tail caps',H03_T04_stronger_tail(),20),
 ('H04_T04_daily_e02_shock','T04 + daily E02-style shock cash/reentry wrapper',H04_T04_daily_e02_shock(),1),
 ('H05_E02_plus_T04_only_when_flat','E02 plus half-size T04 core only when E02 flat and healthy',H05_E02_plus_T04_only_when_flat(),1),
]

def row_for(dates,p,item):
    name,desc,fn,reb=item
    vals,w,e=E.simulate_event(dates,p,fn,rebalance=reb,band=0.02)
    m=all_metrics(dates,vals)
    return {'name':name,'description':desc,'metrics':m,'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in Z.STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'pass_12_8':m['full']['ann']>=TARGET_ANN and m['full']['dd']<=TARGET_DD}

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[row_for(dates,p,c) for c in CANDIDATES]
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    for r in sorted(rows,key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; mark='PASS' if r['pass_12_8'] else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'],'events',r['extra'].get('events',{}))
        print('  topdd',' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
    print('Best under 12% DD:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.12],key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; print(r['name'],f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f}")
    print('PASS_COUNT',sum(1 for r in rows if r['pass_12_8']))
if __name__=='__main__': run()
