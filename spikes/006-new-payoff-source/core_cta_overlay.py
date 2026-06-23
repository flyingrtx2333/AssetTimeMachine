#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, math, statistics
from pathlib import Path

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
# import core canary strategy
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
# import CTA module
spec2=importlib.util.spec_from_file_location('cta', ROOT/'spikes/006-new-payoff-source/managed_futures_cta.py')
CTA=importlib.util.module_from_spec(spec2); sys.modules['cta']=CTA; spec2.loader.exec_module(CTA)  # type: ignore
OUT=Path('/tmp/atm_core_cta_overlay.json')
STRESS={
 '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
 '2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
 '2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),
 '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
 '2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
 '2026AI波动':(dt.date(2025,12,1),None),
}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

def metrics(dates,vals,start=None,end=None):
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]; peak=vs[0]; mdd=0; rs=[]
    for a,b in zip(vs,vs[1:]):
        rs.append(b/a-1); peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=(ds[-1]-ds[0]).days/365.25; ann=(vs[-1]/vs[0])**(1/years)-1
    vol=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=statistics.mean(rs)*252/vol if vol else 0
    return {'start':str(ds[0]),'end':str(ds[-1]),'ann':ann,'dd':mdd,'total':vs[-1]/vs[0]-1,'vol':vol,'sharpe':sh,'calmar':ann/mdd if mdd else 0}

def topdds(dates,vals,n=5):
    peak=tr=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr]<vals[peak]*.985: out.append((peak,tr,1-vals[tr]/vals[peak]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c} for a,b,c in out[:n]]

def align_series(d1,v1,d2,v2):
    m1={d:v for d,v in zip(d1,v1)}; m2={d:v for d,v in zip(d2,v2)}
    dates=sorted(set(m1)&set(m2))
    return dates,[m1[d] for d in dates],[m2[d] for d in dates]

def combine_overlay(dates,core_vals,cta_vals,overlay):
    vals=[100000.0]
    for i in range(1,len(dates)):
        cr=core_vals[i]/core_vals[i-1]-1
        tr=cta_vals[i]/cta_vals[i-1]-1
        # CTA module includes collateral cash return; overlay should add only trading excess over cash.
        excess=tr-CTA.cash_daily(dates[i-1])
        vals.append(vals[-1]*(1+cr+overlay*excess))
    return vals

def ma_arr(vals,i,n):
    if i-n+1<0: return None
    return sum(vals[i-n+1:i+1])/n

def combine_overlay_gated(dates,core_vals,cta_vals,overlay):
    # Mechanism: CTA overlay is a sleeve with its own permission layer. If its own equity curve is below
    # long trend or its 6-month return is negative, do not spend overlay risk budget. Core keeps running.
    vals=[100000.0]
    active_days=0
    for i in range(1,len(dates)):
        cr=core_vals[i]/core_vals[i-1]-1
        tr=cta_vals[i]/cta_vals[i-1]-1
        excess=tr-CTA.cash_daily(dates[i-1])
        active=False
        if i>260:
            m=ma_arr(cta_vals,i-1,200)
            ret126=cta_vals[i-1]/cta_vals[i-127]-1 if i>=127 else -1
            active = (m is not None and cta_vals[i-1] > m and ret126 > 0)
        if active: active_days+=1
        vals.append(vals[-1]*(1+cr+(overlay if active else 0.0)*excess))
    return vals, active_days/max(1,len(dates))

def combine_overlay_budgeted(dates,core_vals,cta_vals,overlay):
    # Mechanism: overlay is allowed only while the total strategy has drawdown budget left.
    # Core always runs; CTA overlay shuts off after portfolio drawdown breaches 8%, and resumes after recovery.
    vals=[100000.0]
    peak=vals[0]
    active_days=0
    for i in range(1,len(dates)):
        peak=max(peak,vals[-1])
        portfolio_dd=1-vals[-1]/peak if peak>0 else 0
        cr=core_vals[i]/core_vals[i-1]-1
        tr=cta_vals[i]/cta_vals[i-1]-1
        excess=tr-CTA.cash_daily(dates[i-1])
        cta_ok=False
        if i>260:
            m=ma_arr(cta_vals,i-1,200)
            ret126=cta_vals[i-1]/cta_vals[i-127]-1 if i>=127 else -1
            cta_ok=(m is not None and cta_vals[i-1]>m and ret126>0)
        active=cta_ok and portfolio_dd<0.08
        if active: active_days+=1
        vals.append(vals[-1]*(1+cr+(overlay if active else 0.0)*excess))
    return vals, active_days/max(1,len(dates))

def main():
    core_dates,core_prices=CORE.align(CORE.fetch())
    cfg=CORE.base_cfg()
    core_vals,core_w,core_extra=CORE.simulate(core_dates,core_prices,cfg)
    cta_dates,cta_prices,cta_cov=CTA.load()
    cta_vals,cta_w,cta_extra=CTA.simulate_cta(cta_dates,cta_prices,0.08)
    dates,cv,tv=align_series(core_dates,core_vals,cta_dates,cta_vals)
    rows=[]
    for ov in [0.10,0.20,0.30,0.40,0.50]:
        vals=combine_overlay(dates,cv,tv,ov)
        ten=dates[-1].replace(year=dates[-1].year-10)
        row={'name':f'N_core_plus_cta_overlay_{ov:.2f}','overlay':ov,'active_ratio':1.0,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':topdds(dates,vals)}
        rows.append(row)
    for ov in [0.20,0.30,0.40,0.50,0.60]:
        vals,active_ratio=combine_overlay_gated(dates,cv,tv,ov)
        ten=dates[-1].replace(year=dates[-1].year-10)
        row={'name':f'O_core_plus_cta_gated_overlay_{ov:.2f}','overlay':ov,'active_ratio':active_ratio,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':topdds(dates,vals)}
        rows.append(row)
    for ov in [0.20,0.30,0.40,0.50,0.60]:
        vals,active_ratio=combine_overlay_budgeted(dates,cv,tv,ov)
        ten=dates[-1].replace(year=dates[-1].year-10)
        row={'name':f'P_core_plus_cta_budgeted_overlay_{ov:.2f}','overlay':ov,'active_ratio':active_ratio,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':topdds(dates,vals)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'core_full':metrics(dates,cv),'cta_full':metrics(dates,tv),'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    print('CORE',metrics(dates,cv))
    print('CTA',metrics(dates,tv))
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
