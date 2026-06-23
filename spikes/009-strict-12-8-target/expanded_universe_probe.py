#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, math, statistics, json, datetime as dt
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
START=100000.0; FEE=CORE.FEE; SLIP=CORE.SLIP
ASSETS=['nasdaq','gold_cny','sp500','dowjones','csi300','shanghai_composite']
OUT=Path('/tmp/atm_expanded_universe_12_8_probe.json')

def ma(v,i,n): return None if i-n+1<0 else sum(v[i-n+1:i+1])/n
def mom(v,i,n): return None if i-n<0 else v[i]/v[i-n]-1

def above(p,s,i,n):
    m=ma(p[s],i,n); return m is not None and p[s][i]>m

def vol(v,i,n=63):
    if i-n<1: return None
    rs=[v[j]/v[j-1]-1 for j in range(i-n+1,i+1) if v[j-1]>0]
    return statistics.stdev(rs)*math.sqrt(252) if len(rs)>2 else None

def normalize(tw,cap=0.98):
    tw={k:max(0.0,float(v)) for k,v in tw.items() if v>1e-6}
    s=sum(tw.values())
    if s>cap and s>0: tw={k:v*cap/s for k,v in tw.items()}
    return tw

def trade_to(cash,units,p,i,target,assets=ASSETS,band=0.02):
    target=normalize(target,0.98); total=cash+sum(units[s]*p[s][i] for s in assets); traded=False
    for s in assets:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0)
        if cur>tgt*(1+band):
            su=min(units[s],(cur-tgt)/p[s][i])
            if su>0: cash+=su*p[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; traded=True
    total=cash+sum(units[s]*p[s][i] for s in assets)
    for s in assets:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0)
        if cur<tgt*(1-band):
            amt=min(cash,tgt-cur)
            if amt>1: units[s]+=amt*(1-FEE)/(p[s][i]*(1+SLIP)); cash-=amt; traded=True
    return cash,units,traded

def metrics(dates,vals):
    yrs=(dates[-1]-dates[0]).days/365.25
    ann=(vals[-1]/vals[0])**(1/yrs)-1
    peak=vals[0]; dd=0
    for v in vals: peak=max(peak,v); dd=max(dd,1-v/peak)
    return ann,dd

def simulate(dates,p,fn,assets=ASSETS,reb=21):
    cash=START; units={s:0.0 for s in assets}; vals=[]; trades=0; ctx={'peak':START,'state':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash+=cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in assets); ctx['peak']=max(ctx['peak'],val)
        if i>252 and i%reb==0:
            sig=i-1; ctx['portfolio_dd']=1-val/ctx['peak']
            target=fn(dates,p,sig,ctx,assets)
            cash,units,did=trade_to(cash,units,p,i,target,assets)
            if did: trades+=1
        vals.append(cash+sum(units[s]*p[s][i] for s in assets))
    return vals,trades,{s:units[s]*p[s][-1]/vals[-1] for s in assets if vals[-1]>0 and units[s]*p[s][-1]/vals[-1]>1e-4}

def comp_score(p,s,i):
    parts=[]
    for n,w in [(21,12),(63,4),(126,2),(252,1)]:
        m=mom(p[s],i,n)
        if m is None: return -999
        parts.append(w*m)
    vv=vol(p[s],i,63) or 0.25
    return sum(parts)-0.5*vv

def X01_top2_momentum(dates,p,i,ctx,assets):
    sc={s:comp_score(p,s,i) for s in assets}
    ranked=[s for s in sorted(assets,key=lambda s:sc[s],reverse=True) if sc[s]>0 and above(p,s,i,120)]
    if ctx.get('portfolio_dd',0)>0.07: return {}
    if not ranked: return {}
    return {ranked[0]:0.60, **({ranked[1]:0.35} if len(ranked)>1 else {})}

def X02_protective_momentum(dates,p,i,ctx,assets):
    # Breadth controls risk budget; top asset(s) receive budget.
    good=[s for s in assets if (mom(p[s],i,126) or -1)>0 and above(p,s,i,120)]
    breadth=len(good)/len(assets)
    if ctx.get('portfolio_dd',0)>0.065: budget=0.25
    elif breadth>=0.65: budget=0.95
    elif breadth>=0.35: budget=0.65
    else: budget=0.25
    ranked=sorted(good,key=lambda s:comp_score(p,s,i),reverse=True)
    if not ranked: return {}
    if len(ranked)==1: return {ranked[0]:budget}
    return {ranked[0]:budget*0.65, ranked[1]:budget*0.35}

def X03_equity_gold_rotation_plus_china_bubble(dates,p,i,ctx,assets):
    # Allow China only in strong breakouts, otherwise US/gold.
    tw={}
    us=above(p,'nasdaq',i,160) and (mom(p['nasdaq'],i,126) or 0)>0 and above(p,'sp500',i,160)
    gold=above(p,'gold_cny',i,120) and (mom(p['gold_cny'],i,63) or 0)>0
    china=above(p,'csi300',i,120) and (mom(p['csi300'],i,63) or 0)>0.10 and above(p,'shanghai_composite',i,120)
    if ctx.get('portfolio_dd',0)>0.07: return {'gold_cny':0.25} if gold else {}
    if us: tw['nasdaq']=0.55
    if gold: tw['gold_cny']=0.30
    if china: tw['csi300']=0.25
    return normalize(tw,0.98)

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[]
    for name,fn,reb in [('X01_top2_momentum',X01_top2_momentum,21),('X02_protective_momentum',X02_protective_momentum,21),('X03_equity_gold_rotation_plus_china_bubble',X03_equity_gold_rotation_plus_china_bubble,21),('X01_weekly',X01_top2_momentum,5),('X02_weekly',X02_protective_momentum,5),('X03_weekly',X03_equity_gold_rotation_plus_china_bubble,5)]:
        vals,trades,latest=simulate(dates,p,fn,ASSETS,reb)
        ann,dd=metrics(dates,vals)
        rows.append({'name':name,'ann':ann,'dd':dd,'trades':trades,'latest':latest})
    OUT.write_text(json.dumps({'rows':rows},ensure_ascii=False,indent=2))
    for r in sorted(rows,key=lambda r:r['ann'],reverse=True):
        print(('PASS' if r['ann']>=0.12 and r['dd']<=0.08 else 'FAIL'),r['name'],f"{r['ann']*100:.2f}/{r['dd']*100:.2f}",'trades',r['trades'],'latest',{k:round(v*100,1) for k,v in r['latest'].items()})
if __name__=='__main__': run()
