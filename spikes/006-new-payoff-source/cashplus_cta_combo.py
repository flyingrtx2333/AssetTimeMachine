#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, statistics, math
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('cashplus', ROOT/'spikes/006-new-payoff-source/core_cashplus_defense.py')
CP=importlib.util.module_from_spec(spec); sys.modules['cashplus']=CP; spec.loader.exec_module(CP)  # type: ignore
spec2=importlib.util.spec_from_file_location('cta', ROOT/'spikes/006-new-payoff-source/managed_futures_cta.py')
CTA=importlib.util.module_from_spec(spec2); sys.modules['cta']=CTA; spec2.loader.exec_module(CTA)  # type: ignore
OUT=Path('/tmp/atm_cashplus_cta_combo.json')
STRESS={'2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),'2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),'2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),'2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),'2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),'2026AI波动':(dt.date(2025,12,1),None)}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

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

def combine(dates,base_vals,cta_dates,cta_vals,overlay):
    cta_map={d:v for d,v in zip(cta_dates,cta_vals)}
    base_map={d:v for d,v in zip(dates,base_vals)}
    ds=sorted(set(cta_map)&set(base_map))
    vals=[100000.0]
    for i in range(1,len(ds)):
        br=base_map[ds[i]]/base_map[ds[i-1]]-1
        tr=cta_map[ds[i]]/cta_map[ds[i-1]]-1-CTA.cash_daily(ds[i-1])
        vals.append(vals[-1]*(1+br+overlay*tr))
    return ds,vals

def main():
    dates,cprices,fprices=CP.align_all()
    base_rows=[]
    for mode in ['cashplus_third','cashplus_half']:
        vals,w,e=CP.simulate_core_cashplus(dates,cprices,fprices,mode)
        base_rows.append((mode,vals))
    cta_dates,cta_prices,_=CTA.load(); cta_vals,_,_=CTA.simulate_cta(cta_dates,cta_prices,0.08)
    rows=[]
    for mode,base_vals in base_rows:
        for ov in [0.05,0.10,0.15]:
            ds,vals=combine(dates,base_vals,cta_dates,cta_vals,ov)
            ten=ds[-1].replace(year=ds[-1].year-10)
            row={'name':f'T_{mode}_plus_cta_{ov:.2f}','mode':mode,'overlay':ov,'metrics':{'full':metrics(ds,vals),'post2020':metrics(ds,vals,dt.date(2020,1,1)),'teny':metrics(ds,vals,ten),'2024+':metrics(ds,vals,dt.date(2024,1,1)),'2002-2012':metrics(ds,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(ds,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(ds,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':topdds(ds,vals)}
            rows.append(row)
    OUT.write_text(json.dumps({'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT)
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
