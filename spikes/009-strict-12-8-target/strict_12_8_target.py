#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, math, statistics, datetime as dt
from pathlib import Path
from typing import Dict, Callable, Any

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('zoo', ROOT/'spikes/008-gold-nasdaq-mechanism-zoo/mechanism_zoo.py')
Z=importlib.util.module_from_spec(spec); sys.modules['zoo']=Z; spec.loader.exec_module(Z)  # type: ignore
CORE=Z.CORE
OUT=Path('/tmp/atm_gold_nasdaq_strict_12_8.json')
START=100000.0
HOLDINGS=['nasdaq','gold_cny']
TARGET_ANN=0.12
TARGET_DD=0.08

# Re-export helpers from 008.
pct=Z.pct; mom=Z.mom; ma=Z.ma; above=Z.above; dd_series=Z.dd_series; realized_vol=Z.realized_vol
positive_6m=Z.positive_6m; score_asset=Z.score_asset; ratio=Z.ratio; ratio_ma=Z.ratio_ma
virtual_barbell=Z.virtual_barbell; virtual_ma=Z.virtual_ma; virtual_mom=Z.virtual_mom
barbell_health_state=Z.barbell_health_state; normalize=Z.normalize

PERIODS=Z.PERIODS
STRESS=Z.STRESS

def metrics(dates,vals,start=None,end=None): return Z.metrics(dates,vals,start,end)
def all_metrics(dates,vals): return Z.all_metrics(dates,vals)
def topdds(dates,vals,weights): return Z.topdds(dates,vals,weights)
def simulate_buy_hold(dates,p,init): return Z.simulate_buy_hold(dates,p,init)

def trade_to(cash,units,p,i,target,band=0.015):
    target=normalize(target,0.98)
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    traded=False
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur>tgt*(1+band):
            su=min(units[s],(cur-tgt)/p[s][i])
            if su>0:
                cash += su*p[s][i]*(1-Z.SLIP)*(1-Z.FEE); units[s]-=su; traded=True
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur<tgt*(1-band):
            amt=min(cash,tgt-cur)
            if amt>1:
                units[s]+=amt*(1-Z.FEE)/(p[s][i]*(1+Z.SLIP)); cash-=amt; traded=True
    return cash,units,traded

def simulate_event(dates,p,target_fn:Callable, rebalance:int=1, band=0.015):
    cash=START; units={s:0.0 for s in HOLDINGS}; vals=[]; weights=[]; trades=0
    ctx={'peak':START,'state':{},'last_target':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        ctx['peak']=max(ctx.get('peak',val),val)
        if i>0 and i%rebalance==0:
            sig_i=i-1
            sig_val=cash+sum(units[s]*p[s][sig_i] for s in HOLDINGS)
            ctx['sig_w']={s:(units[s]*p[s][sig_i]/sig_val if sig_val>0 else 0) for s in HOLDINGS}
            ctx['portfolio_dd']=1-val/ctx['peak'] if ctx['peak'] else 0
            target=target_fn(dates,p,sig_i,ctx)
            if target is not None:
                cash,units,did=trade_to(cash,units,p,i,target,band=band)
                if did: trades+=1
                ctx['last_target']=target
                val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

def vol_scale(p,i,base_cap=0.9):
    nv=realized_vol(p['nasdaq'],i,42) or 0.22
    gv=realized_vol(p['gold_cny'],i,42) or 0.18
    # fixed scale: if realized vol expands, reduce total risk budget.
    stress=max(nv/0.24, gv/0.22)
    if stress<=1: return base_cap
    return max(0.35, base_cap/stress)

def fast_bad(p,s,i):
    return ((mom(p[s],i,5) or 0)<-0.05) or ((mom(p[s],i,21) or 0)<-0.09) or ((dd_series(p[s],i,42) or 0)<-0.10)

def sleeve_ok(p,s,i):
    return above(p,s,i,80) and (mom(p[s],i,63) or -1)>0 and not fast_bad(p,s,i)

def recovered_barbell(p,i):
    vm80=virtual_ma(p,i,80,0.5,0.5); vm160=virtual_ma(p,i,160,0.5,0.5)
    if vm80 is None or vm160 is None: return False
    vb=virtual_barbell(p,i,0.5,0.5)
    return vb>vm80>vm160 and (virtual_mom(p,i,42,0.5,0.5) or 0)>0

# --- New fixed mechanisms aimed at the original 12/8 target. ---

def S01_portfolio_dd_circuit_breaker(dates,p,i,ctx):
    # Aggressive engine, but any portfolio drawdown beyond 5.5% forces risk-off until barbell recovery.
    st=ctx.setdefault('state',{})
    if ctx.get('portfolio_dd',0)>0.055:
        st['risk_off']=max(st.get('risk_off',0),21)
    st['risk_off']=max(0,st.get('risk_off',0)-1)
    if st.get('risk_off',0)>0 and not recovered_barbell(p,i):
        return {'gold_cny':0.20} if positive_6m(p,'gold_cny',i) else {}
    cap=vol_scale(p,i,0.92)
    tw={}
    if sleeve_ok(p,'nasdaq',i): tw['nasdaq']=0.58
    if sleeve_ok(p,'gold_cny',i): tw['gold_cny']=0.35
    if not tw and positive_6m(p,'gold_cny',i): tw={'gold_cny':0.25}
    return normalize(tw,cap)

def S02_dual_sleeve_trailing_stop_reentry(dates,p,i,ctx):
    # Per-asset stops + reentry: let each sleeve run, cut it on fast drawdown, reenter after trend repair.
    st=ctx.setdefault('state',{})
    target={}
    base={'nasdaq':0.65,'gold_cny':0.35}
    for s,w in base.items():
        cool=f'{s}_cool'
        st[cool]=max(0,st.get(cool,0)-1)
        if fast_bad(p,s,i): st[cool]=21
        if st[cool]>0:
            continue
        if sleeve_ok(p,s,i) or ((mom(p[s],i,21) or 0)>0.04 and above(p,s,i,40)):
            target[s]=w
    if ctx.get('portfolio_dd',0)>0.065:
        target={k:v*0.45 for k,v in target.items()}
    return normalize(target,vol_scale(p,i,0.95))

def S03_nasdaq_engine_gold_airbag(dates,p,i,ctx):
    # Nasdaq is high-return engine only when US risk appetite and barbell health agree; gold is airbag, not equal peer.
    state,vdd=barbell_health_state(p,i)
    us_ok=positive_6m(p,'sp500',i) and above(p,'sp500',i,120) and above(p,'dowjones',i,120)
    nq_ok=sleeve_ok(p,'nasdaq',i) and us_ok and state=='healthy'
    gold_ok=sleeve_ok(p,'gold_cny',i) and not fast_bad(p,'gold_cny',i)
    if nq_ok:
        return normalize({'nasdaq':0.68,'gold_cny':0.25 if gold_ok else 0.10},vol_scale(p,i,0.95))
    if state in ('healthy','bruised') and gold_ok:
        return {'nasdaq':0.20 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.42}
    return {'gold_cny':0.20} if positive_6m(p,'gold_cny',i) else {}

def S04_risk_on_ratio_breakout_with_stop(dates,p,i,ctx):
    # Use Nasdaq/gold ratio breakout as risk-on signal; hard stop on ratio failure or portfolio DD.
    r=ratio(p,i); rma=ratio_ma(p,i,120)
    st=ctx.setdefault('state',{})
    if ctx.get('portfolio_dd',0)>0.06: st['defensive']=42
    if r is not None and rma is not None and r<rma*0.96: st['defensive']=21
    st['defensive']=max(0,st.get('defensive',0)-1)
    gold_ok=sleeve_ok(p,'gold_cny',i)
    if st.get('defensive',0)>0:
        return {'gold_cny':0.35} if gold_ok else {}
    if r is not None and rma is not None and r>rma and sleeve_ok(p,'nasdaq',i):
        return normalize({'nasdaq':0.70,'gold_cny':0.20 if gold_ok else 0.0},vol_scale(p,i,0.92))
    return {'nasdaq':0.25 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.35 if gold_ok else 0.0}

def S05_barbell_equity_curve_pyramid(dates,p,i,ctx):
    # Pyramid exposure by virtual barbell trend alignment; cut quickly when equity curve breaks.
    vb=virtual_barbell(p,i,0.5,0.5); m40=virtual_ma(p,i,40,0.5,0.5); m100=virtual_ma(p,i,100,0.5,0.5); m200=virtual_ma(p,i,200,0.5,0.5)
    if m40 is None or m100 is None or m200 is None: return {'nasdaq':0.25,'gold_cny':0.25}
    if ctx.get('portfolio_dd',0)>0.065 or vb<m100:
        return {'gold_cny':0.25} if sleeve_ok(p,'gold_cny',i) else {}
    cap=0.95 if vb>m40>m100>m200 else 0.70 if vb>m100>m200 else 0.45
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if sn>sg and sleeve_ok(p,'nasdaq',i): return normalize({'nasdaq':0.68,'gold_cny':0.25 if sleeve_ok(p,'gold_cny',i) else 0.0},cap)
    if sleeve_ok(p,'gold_cny',i): return normalize({'nasdaq':0.25 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.55},cap)
    return {}

def S06_return_stack_without_leverage(dates,p,i,ctx):
    # Try to reach 12% by high exposure only in rare all-clear states; otherwise cash. No leverage.
    all_clear=recovered_barbell(p,i) and sleeve_ok(p,'nasdaq',i) and positive_6m(p,'sp500',i) and not fast_bad(p,'gold_cny',i)
    if ctx.get('portfolio_dd',0)>0.055:
        return {'gold_cny':0.20} if sleeve_ok(p,'gold_cny',i) else {}
    if all_clear:
        return normalize({'nasdaq':0.78,'gold_cny':0.20 if sleeve_ok(p,'gold_cny',i) else 0.0},vol_scale(p,i,0.98))
    if recovered_barbell(p,i):
        return normalize({'nasdaq':0.40 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.35 if sleeve_ok(p,'gold_cny',i) else 0.0},0.70)
    return {'gold_cny':0.25} if sleeve_ok(p,'gold_cny',i) else {}

def S07_gold_breakout_nasdaq_reentry(dates,p,i,ctx):
    # Exploit gold breakouts during equity stress, then re-enter Nasdaq after recovery. Different payoff timing.
    equity_stress=(not above(p,'sp500',i,120)) or ((mom(p['sp500'],i,21) or 0)<-0.05)
    gold_break=sleeve_ok(p,'gold_cny',i) and (mom(p['gold_cny'],i,63) or 0)>0.06
    nq_reentry=recovered_barbell(p,i) and sleeve_ok(p,'nasdaq',i)
    if ctx.get('portfolio_dd',0)>0.06:
        return {'gold_cny':0.35} if gold_break else {}
    if equity_stress and gold_break:
        return {'gold_cny':0.65}
    if nq_reentry:
        return normalize({'nasdaq':0.62,'gold_cny':0.25 if gold_break else 0.0},vol_scale(p,i,0.92))
    return {'nasdaq':0.25 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.35 if gold_break else 0.0}

def S08_monthly_m34_more_aggressive(dates,p,i,ctx):
    # Not a parameter sweep; a single more aggressive version of M34 to test if the logic can cross 12/8.
    state,vdd=barbell_health_state(p,i)
    recovered=recovered_barbell(p,i)
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    nv=realized_vol(p['nasdaq'],i,63) or 0.25
    if ctx.get('portfolio_dd',0)>0.06:
        return {'gold_cny':0.25} if sleeve_ok(p,'gold_cny',i) else {}
    if state=='healthy' and recovered:
        if sn>sg and sleeve_ok(p,'nasdaq',i):
            return normalize({'nasdaq':0.62 if nv<0.28 else 0.48,'gold_cny':0.28 if sleeve_ok(p,'gold_cny',i) else 0.0},0.92)
        if sleeve_ok(p,'gold_cny',i): return {'nasdaq':0.25 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.55}
    if state=='bruised': return {'nasdaq':0.22 if sleeve_ok(p,'nasdaq',i) else 0.0,'gold_cny':0.32 if sleeve_ok(p,'gold_cny',i) else 0.0}
    return {'gold_cny':0.22} if sleeve_ok(p,'gold_cny',i) else {}

CANDIDATES=[
    ('BH_25_25_buyhold','baseline 25N/25G/50C',None,'buyhold',{'nasdaq':0.25,'gold_cny':0.25},None),
    ('BH_50_35_buyhold','aggressive buyhold 50N/35G/15C',None,'buyhold',{'nasdaq':0.50,'gold_cny':0.35},None),
    ('M13_harvest_rebuild_from_008','existing aggressive reference',Z.M13_rebalance_harvest_rebuild,'monthly',None,20),
    ('M34_from_008','existing best balanced reference',Z.M34_health_recovery_with_vol_cap,'monthly',None,20),
    ('S01_daily_portfolio_dd_circuit_breaker','daily aggressive engine with portfolio drawdown circuit breaker',S01_portfolio_dd_circuit_breaker,'event',None,1),
    ('S02_daily_dual_sleeve_trailing_stop_reentry','daily per-sleeve trailing stops and reentry',S02_dual_sleeve_trailing_stop_reentry,'event',None,1),
    ('S03_daily_nasdaq_engine_gold_airbag','daily Nasdaq engine gated by US risk appetite; gold airbag',S03_nasdaq_engine_gold_airbag,'event',None,1),
    ('S04_daily_ratio_breakout_with_stop','daily Nasdaq/gold ratio breakout with stop',S04_risk_on_ratio_breakout_with_stop,'event',None,1),
    ('S05_daily_barbell_equity_curve_pyramid','daily virtual barbell equity-curve pyramid',S05_barbell_equity_curve_pyramid,'event',None,1),
    ('S06_daily_return_stack_without_leverage','daily rare all-clear high exposure, otherwise cash',S06_return_stack_without_leverage,'event',None,1),
    ('S07_daily_gold_breakout_nasdaq_reentry','daily gold breakout in equity stress, Nasdaq recovery reentry',S07_gold_breakout_nasdaq_reentry,'event',None,1),
    ('S08_daily_m34_more_aggressive','daily more aggressive M34-style fixed logic',S08_monthly_m34_more_aggressive,'event',None,1),
    # Same event logics at weekly cadence to see if daily trading is the whole source.
    ('S01_weekly_portfolio_dd_circuit_breaker','weekly aggressive engine with portfolio drawdown circuit breaker',S01_portfolio_dd_circuit_breaker,'event',None,5),
    ('S03_weekly_nasdaq_engine_gold_airbag','weekly Nasdaq engine gated by US risk appetite; gold airbag',S03_nasdaq_engine_gold_airbag,'event',None,5),
    ('S05_weekly_barbell_equity_curve_pyramid','weekly virtual barbell equity-curve pyramid',S05_barbell_equity_curve_pyramid,'event',None,5),
    ('S08_weekly_m34_more_aggressive','weekly more aggressive M34-style fixed logic',S08_monthly_m34_more_aggressive,'event',None,5),
]

def row_for(dates,p,c):
    name,desc,fn,mode,bh,reb=c
    if mode=='buyhold': vals,w,e=simulate_buy_hold(dates,p,bh)
    elif mode=='monthly': vals,w,e=Z.simulate_target(dates,p,fn,rebalance=reb or 20)
    else: vals,w,e=simulate_event(dates,p,fn,rebalance=reb or 1,band=0.02)
    bad=[s for ww in w for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    m=all_metrics(dates,vals)
    return {'name':name,'description':desc,'mode':mode,'rebalance':reb,'metrics':m,'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'pass_12_8':m['full']['ann']>=TARGET_ANN and m['full']['dd']<=TARGET_DD}

def static_grid(dates,p):
    # Sanity check: best fixed no-leverage weights under 8% DD.
    rows=[]
    for wn in [x/100 for x in range(0,99,5)]:
        for wg in [x/100 for x in range(0,99,5)]:
            if wn+wg>0.98: continue
            vals,w,e=simulate_buy_hold(dates,p,{'nasdaq':wn,'gold_cny':wg})
            m=all_metrics(dates,vals)['full']
            rows.append({'wn':wn,'wg':wg,'ann':m['ann'],'dd':m['dd'],'sharpe':m['sharpe'],'calmar':m['calmar']})
    rows.sort(key=lambda x:(x['dd']<=TARGET_DD,x['ann']), reverse=True)
    return rows[:20], sorted([r for r in rows if r['dd']<=TARGET_DD], key=lambda x:x['ann'], reverse=True)[:10]

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[row_for(dates,p,c) for c in CANDIDATES]
    all_static, static_under8 = static_grid(dates,p)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'target':{'ann':TARGET_ANN,'dd':TARGET_DD},'static_under8':static_under8,'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates),'TARGET',TARGET_ANN,TARGET_DD)
    print('\nStatic fixed-weight best under 8% DD:')
    for r in static_under8[:8]: print(f"N={r['wn']*100:.0f} G={r['wg']*100:.0f} ann={r['ann']*100:.2f}% dd={r['dd']*100:.2f}%")
    print('\nCandidates sorted by full annualized:')
    for r in sorted(rows,key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; mark='PASS' if r['pass_12_8'] else 'FAIL'
        print(mark, r['name'], f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}", f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}", f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}", 'latest', {k:round(v*100,1) for k,v in r['extra']['latest'].items()}, 'cash', round(r['extra']['cash_pct']*100,1), 'trades', r['extra']['trades'])
    print('\nClosest under 8% DD:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=TARGET_DD], key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; print(r['name'], f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f}")

if __name__=='__main__': run()
