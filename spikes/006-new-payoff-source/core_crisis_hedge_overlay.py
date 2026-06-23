#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, math, statistics
from pathlib import Path

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
spec2=importlib.util.spec_from_file_location('cta', ROOT/'spikes/006-new-payoff-source/managed_futures_cta.py')
CTA=importlib.util.module_from_spec(spec2); sys.modules['cta']=CTA; spec2.loader.exec_module(CTA)  # type: ignore
OUT=Path('/tmp/atm_core_crisis_hedge_overlay.json')
HEDGE_SYMS=['ES=F','NQ=F','ZB=F','ZN=F','GC=F','6E=F','6B=F','6A=F','6C=F','6J=F']
STRESS={
 '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
 '2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
 '2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),
 '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
 '2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
 '2026AI波动':(dt.date(2025,12,1),None),
}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

def ma(vals,i,n):
    if i-n+1<0: return None
    return sum(vals[i-n+1:i+1])/n

def mom(vals,i,n):
    if i-n<0 or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def dd(vals,i,n):
    if i-n+1<0: return None
    h=max(vals[i-n+1:i+1]); return vals[i]/h-1 if h>0 else None

def metrics(dates,vals,start=None,end=None):
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]; peak=vs[0]; mdd=0; rs=[]
    for a,b in zip(vs,vs[1:]): rs.append(b/a-1); peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=(ds[-1]-ds[0]).days/365.25; ann=(vs[-1]/vs[0])**(1/years)-1
    vv=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0; sh=statistics.mean(rs)*252/vv if vv else 0
    return {'start':str(ds[0]),'end':str(ds[-1]),'ann':ann,'dd':mdd,'total':vs[-1]/vs[0]-1,'vol':vv,'sharpe':sh,'calmar':ann/mdd if mdd else 0}

def topdds(dates,vals,n=5):
    peak=tr=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr]<vals[peak]*.985: out.append((peak,tr,1-vals[tr]/vals[peak]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c} for a,b,c in out[:n]]

def hedge_target(core_prices, cta_prices, core_i, cta_i, scale):
    # Crisis hedge: only activate when broad US market loses trend / suffers sharp drawdown.
    sp=core_prices['sp500']; nq=core_prices['nasdaq']
    sp_bad=(ma(sp,core_i,200) is not None and sp[core_i]<ma(sp,core_i,200)) or (dd(sp,core_i,60) or 0)<-0.10
    nq_bad=(ma(nq,core_i,200) is not None and nq[core_i]<ma(nq,core_i,200)) or (dd(nq,core_i,60) or 0)<-0.12
    crisis=sp_bad and nq_bad
    if not crisis: return {}
    w={'ES=F':-0.18*scale,'NQ=F':-0.14*scale}
    # Long bonds only if bond futures are not themselves falling.
    for s,base in [('ZB=F',0.18),('ZN=F',0.12)]:
        if (mom(cta_prices[s],cta_i,60) or -9)>0 and ma(cta_prices[s],cta_i,120) is not None and cta_prices[s][cta_i]>ma(cta_prices[s],cta_i,120):
            w[s]=base*scale
    # Gold hedge only if gold trend confirms.
    if (mom(cta_prices['GC=F'],cta_i,60) or -9)>0 and ma(cta_prices['GC=F'],cta_i,120) is not None and cta_prices['GC=F'][cta_i]>ma(cta_prices['GC=F'],cta_i,120):
        w['GC=F']=0.14*scale
    # USD/JPY crisis complex: long dollar vs weak currencies; long JPY if JPY trend positive.
    for s in ['6E=F','6B=F','6A=F','6C=F']:
        if (mom(cta_prices[s],cta_i,60) or 0)<0:
            w[s]=-0.05*scale
    if (mom(cta_prices['6J=F'],cta_i,60) or 0)>0:
        w['6J=F']=0.05*scale
    return {k:v for k,v in w.items() if abs(v)>1e-6}

def main():
    core_dates,core_prices=CORE.align(CORE.fetch())
    core_vals,_,_=CORE.simulate(core_dates,core_prices,CORE.base_cfg())
    cta_dates,cta_prices,cta_cov=CTA.load()
    core_idx={d:i for i,d in enumerate(core_dates)}; cta_idx={d:i for i,d in enumerate(cta_dates)}
    dates=sorted(set(core_idx)&set(cta_idx))
    cv=[core_vals[core_idx[d]] for d in dates]
    # precompute futures returns on cta native indices
    cta_rets={s:[0.0]*len(cta_dates) for s in HEDGE_SYMS}
    for s in HEDGE_SYMS:
        for i in range(1,len(cta_dates)):
            cta_rets[s][i]=cta_prices[s][i]/cta_prices[s][i-1]-1 if cta_prices[s][i-1]>0 else 0
    rows=[]
    for scale in [0.75,1.0,1.25,1.5]:
        vals=[100000.0]; w={s:0.0 for s in HEDGE_SYMS}; active=0; turns=0.0
        for j in range(1,len(dates)):
            d=dates[j]
            ci=core_idx[d]; cti=cta_idx[d]
            cr=cv[j]/cv[j-1]-1
            pnl=sum(w[s]*cta_rets[s][cti] for s in HEDGE_SYMS)
            vals.append(vals[-1]*(1+cr+pnl))
            # set tomorrow's hedge from today's close, no lookahead for next return
            target=hedge_target(core_prices,cta_prices,ci,cti,scale)
            nw={s:target.get(s,0.0) for s in HEDGE_SYMS}
            turn=sum(abs(nw[s]-w.get(s,0.0)) for s in HEDGE_SYMS)
            if turn>0:
                vals[-1]*=(1-0.0002*turn)
                turns+=turn
            if sum(abs(v) for v in nw.values())>0: active+=1
            w=nw
        ten=dates[-1].replace(year=dates[-1].year-10)
        row={'name':f'Q_core_plus_crisis_hedge_scale{scale:.2f}','scale':scale,'active_ratio':active/max(1,len(dates)),'turnover':turns,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':topdds(dates,vals)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'core_full':metrics(dates,cv),'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates),'CORE',metrics(dates,cv))
    for r in rows:
        print('\n##',r['name'],'active',f"{r['active_ratio']*100:.1f}%")
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
