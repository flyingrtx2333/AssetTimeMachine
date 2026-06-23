#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, math, statistics
from pathlib import Path

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
spec2=importlib.util.spec_from_file_location('cta', ROOT/'spikes/006-new-payoff-source/managed_futures_cta.py')
CTA=importlib.util.module_from_spec(spec2); sys.modules['cta']=CTA; spec2.loader.exec_module(CTA)  # type: ignore
OUT=Path('/tmp/atm_core_defensive_trend_overlay.json')
SYMS=['GC=F','SI=F','ZB=F','ZN=F','ZF=F','ZT=F','6E=F','6J=F','6B=F','6A=F','6C=F']
STRESS={'2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),'2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),'2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),'2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),'2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),'2026AI波动':(dt.date(2025,12,1),None)}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'
def mom(vals,i,n): return None if i-n<0 or vals[i-n]<=0 else vals[i]/vals[i-n]-1
def vol(rets,i,n):
    if i-n+1<0: return None
    arr=rets[i-n+1:i+1]
    if len(arr)<2: return None
    m=sum(arr)/len(arr); return math.sqrt(sum((x-m)**2 for x in arr)/(len(arr)-1))*math.sqrt(252)
def ma(vals,i,n):
    if i-n+1<0: return None
    return sum(vals[i-n+1:i+1])/n

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

def def_trend_weights(prices,rets,i):
    active=[]
    for s in SYMS:
        m=mom(prices[s],i,252); v=vol(rets[s],i,60)
        if m is None or v is None or v<=0: continue
        # Defensive trend: require price to agree with long trend to avoid mean-reversion noise.
        avg=ma(prices[s],i,200)
        if avg is None: continue
        if m>0 and prices[s][i]>avg: sig=1
        elif m<0 and prices[s][i]<avg: sig=-1
        else: continue
        active.append((s,sig,v))
    if not active: return {}
    per_risk=0.06/math.sqrt(len(active))
    w={s:sig*min(0.35,per_risk/max(v,0.04)) for s,sig,v in active}
    # cluster caps
    rates=['ZB=F','ZN=F','ZF=F','ZT=F']; fx=['6E=F','6J=F','6B=F','6A=F','6C=F']; metals=['GC=F','SI=F']
    for group,cap in [(rates,.60),(fx,.50),(metals,.40)]:
        g=sum(abs(w.get(s,0)) for s in group)
        if g>cap:
            for s in group:
                if s in w:
                    w[s]*=cap/g
    gross=sum(abs(x) for x in w.values())
    if gross>1.25: w={s:x*1.25/gross for s,x in w.items()}
    return w

def simulate_def_trend(dates,prices):
    rets={s:[0.0]*len(dates) for s in SYMS}
    for s in SYMS:
        for i in range(1,len(dates)): rets[s][i]=prices[s][i]/prices[s][i-1]-1
    vals=[100000.0]; weights=[]; w={s:0 for s in SYMS}; turnover=0
    weights.append(w.copy())
    for i in range(1,len(dates)):
        pnl=sum(w[s]*rets[s][i] for s in SYMS)
        vals.append(vals[-1]*(1+CTA.cash_daily(dates[i-1])+pnl))
        if i>260 and i%21==0:
            nw=def_trend_weights(prices,rets,i-1)
            turn=sum(abs(nw.get(s,0)-w.get(s,0)) for s in SYMS)
            vals[-1]*=(1-0.0002*turn-0.002/12)
            turnover+=turn; w={s:nw.get(s,0) for s in SYMS}
        weights.append(w.copy())
    return vals,weights

def combine(dates,core_vals,sleeve_vals,overlay):
    vals=[100000.0]
    for i in range(1,len(dates)):
        cr=core_vals[i]/core_vals[i-1]-1
        sr=sleeve_vals[i]/sleeve_vals[i-1]-1-CTA.cash_daily(dates[i-1])
        vals.append(vals[-1]*(1+cr+overlay*sr))
    return vals

def main():
    cd,cp=CORE.align(CORE.fetch()); cv,_,_=CORE.simulate(cd,cp,CORE.base_cfg())
    fd,fp,cov=CTA.load(); fidx={d:i for i,d in enumerate(fd)}; cidx={d:i for i,d in enumerate(cd)}
    # Build sleeve on futures native dates.
    sleeve_vals,sleeve_w=simulate_def_trend(fd,fp)
    dates=sorted(set(cidx)&set(fidx)); core=[cv[cidx[d]] for d in dates]; sleeve=[sleeve_vals[fidx[d]] for d in dates]
    rows=[]
    for ov in [.20,.30,.40,.50,.60]:
        vals=combine(dates,core,sleeve,ov); ten=dates[-1].replace(year=dates[-1].year-10)
        row={'name':f'R_core_plus_defensive_trend_overlay_{ov:.2f}','overlay':ov,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':topdds(dates,vals)}; rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'core_full':metrics(dates,core),'sleeve_full':metrics(dates,sleeve),'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'CORE',metrics(dates,core),'SLEEVE',metrics(dates,sleeve))
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
