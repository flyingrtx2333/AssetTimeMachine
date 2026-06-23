#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('R12', ROOT/'spikes/012-e02-risk-gates-reentry/e02_risk_gates_reentry.py')
R=importlib.util.module_from_spec(spec); sys.modules['R12']=R; spec.loader.exec_module(R)  # type: ignore
E=R.E; Z=R.Z; CORE=R.CORE
OUT=Path('/tmp/atm_e02_limited_ratchet_variants_012.json')
TARGET_ANN=0.12; TARGET_DD=0.08


def make_ratchet(name,pdd_trigger=0.075,duration=20,ncap=0.32,gcap=0.26,gross=0.58,reset_dd=0.035,slow=True,shock_mode='none'):
    base=R.base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        triggered=False
        if slow and R.slow_barbell_damage(p,i): triggered=True
        if ctx.get('portfolio_dd',0)>pdd_trigger: triggered=True
        if shock_mode!='none' and R.spx_liquidity_shock(p,i):
            st['shock']=max(st.get('shock',0), 5 if shock_mode=='brief' else 10)
            R.count(ctx,f'{name}_shock')
        if triggered:
            st['ratchet']=max(st.get('ratchet',0),duration)
            R.count(ctx,f'{name}_ratchet')
        if R.recovered_barbell(p,i) and ctx.get('portfolio_dd',0)<reset_dd:
            st['ratchet']=0
        st['ratchet']=max(0,st.get('ratchet',0)-1)
        st['shock']=max(0,st.get('shock',0)-1)
        if st.get('shock',0)>0:
            if shock_mode=='cash': return {}
            if shock_mode=='brief':
                return R.cap_target(target,ncap=0.0,gcap=0.12,gross=0.12)
        if st.get('ratchet',0)>0:
            return R.cap_target(target,ncap=ncap,gcap=gcap,gross=gross)
        return R.normalize(target,0.92)
    return fn

CANDIDATES=[]
# Handful of interpretable strengths around the R02 mechanism, not an unbounded search.
for name,pdd,dur,ncap,gcap,gross in [
    ('A_light_ratchet',0.085,15,0.40,0.32,0.70),
    ('B_mid_ratchet',0.080,20,0.34,0.28,0.60),
    ('C_R02_like',0.070,30,0.22,0.24,0.46),
    ('D_late_ratchet',0.095,15,0.42,0.32,0.72),
    ('E_fast_short_ratchet',0.075,8,0.36,0.28,0.62),
    ('F_slow_only',0.999,18,0.34,0.28,0.62),
    ('G_pdd_only',0.075,18,0.34,0.28,0.62),
    ('H_light_with_brief_shock',0.085,15,0.40,0.32,0.70),
    ('I_mid_with_brief_shock',0.080,18,0.36,0.28,0.64),
    ('J_mid_with_cash_shock',0.080,18,0.36,0.28,0.64),
]:
    shock='none'
    slow=True
    if name=='G_pdd_only': slow=False
    if 'brief_shock' in name: shock='brief'
    if 'cash_shock' in name: shock='cash'
    CANDIDATES.append((name,make_ratchet(name,pdd,dur,ncap,gcap,gross,slow=slow,shock_mode=shock)))

# A combined variant that only caps the sleeve whose own trend is damaged, instead of all risk.
def K_selective_sleeve_ratchet():
    base=R.base_e02()
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{})
        target=base(dates,p,i,ctx) or {}
        if ctx.get('portfolio_dd',0)>0.080 or R.slow_barbell_damage(p,i):
            st['ratchet']=max(st.get('ratchet',0),18); R.count(ctx,'K_ratchet')
        if R.recovered_barbell(p,i) and ctx.get('portfolio_dd',0)<0.030:
            st['ratchet']=0
        st['ratchet']=max(0,st.get('ratchet',0)-1)
        if st.get('ratchet',0)>0:
            if not R.trend_ok(p,'nasdaq',i,80,21,-0.025): target['nasdaq']=min(target.get('nasdaq',0),0.18)
            else: target['nasdaq']=min(target.get('nasdaq',0),0.42)
            if not R.trend_ok(p,'gold_cny',i,60,21,-0.020) or R.gold_liquidity_trap(p,i): target['gold_cny']=0.0
            else: target['gold_cny']=min(target.get('gold_cny',0),0.24)
            return R.normalize(target,0.60)
        return R.normalize(target,0.92)
    return fn
CANDIDATES.append(('K_selective_sleeve_ratchet',K_selective_sleeve_ratchet()))

def row_for(dates,p,item):
    name,fn=item
    vals,w,e=E.simulate_event(dates,p,fn,rebalance=1,band=0.02)
    m=R.all_metrics(dates,vals)
    return {'name':name,'metrics':m,'stress':{k:R.metrics(dates,vals,a,b) for k,(a,b) in Z.STRESS.items()},'extra':e,'top_dd':R.topdds(dates,vals,w),'pass_12_8':m['full']['ann']>=TARGET_ANN and m['full']['dd']<=TARGET_DD}

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[row_for(dates,p,c) for c in CANDIDATES]
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    print('Sorted by ann:')
    for r in sorted(rows,key=lambda r:r['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']
        mark='PASS' if r['pass_12_8'] else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'],'events',r['extra'].get('events',{}))
        print('  topdd',' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
    print('Best dd<=10:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.10],key=lambda r:r['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; print(r['name'],f"{m['ann']*100:.2f}/{m['dd']*100:.2f}")
    print('PASS_COUNT',sum(1 for r in rows if r['pass_12_8']))
if __name__=='__main__': run()
