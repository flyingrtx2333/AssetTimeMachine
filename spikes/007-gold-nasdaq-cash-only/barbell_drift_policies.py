#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, math, statistics
from pathlib import Path

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
OUT=Path('/tmp/atm_gold_nasdaq_drift_policies.json')
HOLDINGS=['nasdaq','gold_cny']; START=100000.0; FEE=CORE.FEE; SLIP=CORE.SLIP
STRESS={'2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),'2011黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),'2015波动':(dt.date(2015,6,1),dt.date(2016,2,29)),'2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),'2022加息':(dt.date(2022,1,1),dt.date(2022,12,31)),'2026AI波动':(dt.date(2025,12,1),None)}
PERIODS={'full':(None,None),'post2020':(dt.date(2020,1,1),None),'teny':('TENY',None),'2024+':(dt.date(2024,1,1),None),'2002-2012':(dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':(dt.date(2013,1,1),dt.date(2023,12,31))}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'
def ma(v,i,n): return None if i-n+1<0 else sum(v[i-n+1:i+1])/n
def mom(v,i,n): return None if i-n<0 or v[i-n]<=0 else v[i]/v[i-n]-1
def dd(v,i,n):
    if i-n+1<0: return None
    h=max(v[i-n+1:i+1]); return v[i]/h-1 if h>0 else None
def above(p,s,i,n):
    m=ma(p[s],i,n); return m is not None and p[s][i]>m

def metrics(dates,vals,start=None,end=None):
    if start=='TENY': start=dates[-1].replace(year=dates[-1].year-10)
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]; peak=vs[0]; mdd=0; rs=[]
    for a,b in zip(vs,vs[1:]):
        if a>0 and b>0: rs.append(b/a-1)
        peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=(ds[-1]-ds[0]).days/365.25
    ann=(vs[-1]/vs[0])**(1/years)-1
    vol=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=statistics.mean(rs)*252/vol if vol else 0
    return {'start':str(ds[0]),'end':str(ds[-1]),'ann':ann,'dd':mdd,'total':vs[-1]/vs[0]-1,'vol':vol,'sharpe':sh,'calmar':ann/mdd if mdd else 0}

def allm(dates,vals): return {k:metrics(dates,vals,a,b) for k,(a,b) in PERIODS.items()}
def topdds(dates,vals,weights,n=5):
    peak=tr=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr]<vals[peak]*.985: out.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v*100,1) for k,v in w.items()},'cash':round((1-sum(w.values()))*100,1)} for a,b,c,w in out[:n]]

def trade_to(cash,units,p,i,target):
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    # sells
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur>tgt*1.01:
            su=min(units[s],(cur-tgt)/p[s][i])
            if su>0:
                cash += su*p[s][i]*(1-SLIP)*(1-FEE); units[s]-=su
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    # buys
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur<tgt*.99:
            amt=min(cash,tgt-cur)
            if amt>1:
                units[s]+=amt*(1-FEE)/(p[s][i]*(1+SLIP)); cash-=amt
    return cash,units

def simulate_policy(dates,p,name,policy,init=None):
    if init is None: init={'nasdaq':0.25,'gold_cny':0.25}
    cash=START; units={s:0.0 for s in HOLDINGS}; trades=0
    cash,units=trade_to(cash,units,p,0,init); trades+=len(init)
    vals=[]; weights=[]; peak=START
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in HOLDINGS); peak=max(peak,val)
        if i>0 and i%20==0:
            # T-1 signal, T execution: compute signal/weights using yesterday's prices, trade at today's prices.
            sig_i=i-1
            sig_val=cash+sum(units[s]*p[s][sig_i] for s in HOLDINGS)
            w={s:units[s]*p[s][sig_i]/sig_val for s in HOLDINGS}
            target=policy(dates,p,sig_i,w,1-val/peak)
            if target is not None:
                cash,units=trade_to(cash,units,p,i,target); trades+=1
                val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0,1-sum(weights[-1].values()))}

# Policies return target weights only when action is needed; None = let profits drift.
def P0_none(dates,p,i,w,pdd): return None

def P1_cap40_trim30(dates,p,i,w,pdd):
    tgt=dict(w)
    changed=False
    for s in HOLDINGS:
        if w.get(s,0)>0.40:
            tgt[s]=0.30; changed=True
    return tgt if changed else None

def P2_cap45_trend_trim30(dates,p,i,w,pdd):
    tgt=dict(w); changed=False
    for s in HOLDINGS:
        trend_bad=(not above(p,s,i,120)) or ((mom(p[s],i,63) or 0)<-0.04)
        if w.get(s,0)>0.42 and trend_bad:
            tgt[s]=0.30; changed=True
    return tgt if changed else None

def P3_blowoff_harvest(dates,p,i,w,pdd):
    tgt=dict(w); changed=False
    for s in HOLDINGS:
        blow=(mom(p[s],i,252) or 0)>0.35 and (mom(p[s],i,21) or 0)<-0.03
        if w.get(s,0)>0.30 and blow:
            tgt[s]=0.25; changed=True
    return tgt if changed else None

def P4_trailing_brake(dates,p,i,w,pdd):
    tgt=dict(w); changed=False
    for s in HOLDINGS:
        # if sleeve has become large and is now >12% below its 1Y high, harvest hard.
        if w.get(s,0)>0.35 and (dd(p[s],i,252) or 0)<-0.12 and not above(p,s,i,120):
            tgt[s]=0.22; changed=True
    return tgt if changed else None

def P5_rebuild_after_brake(dates,p,i,w,pdd):
    # combine harvest with re-entry to original 25/25 when trend recovers and sleeve is underweight
    tgt=P4_trailing_brake(dates,p,i,w,pdd)
    if tgt is not None: return tgt
    nt=dict(w); changed=False
    for s in HOLDINGS:
        if w.get(s,0)<0.18 and above(p,s,i,180) and (mom(p[s],i,126) or 0)>0.05:
            nt[s]=0.25; changed=True
    return nt if changed else None

def P6_drawdown_guard(dates,p,i,w,pdd):
    if pdd<0.14: return None
    tgt=dict(w); changed=False
    for s in HOLDINGS:
        if not above(p,s,i,120):
            tgt[s]=min(w.get(s,0),0.20); changed=True
    return tgt if changed else None

def make_blowoff_rebuild(base):
    def policy(dates,p,i,w,pdd):
        tgt=P3_blowoff_harvest(dates,p,i,w,pdd)
        if tgt is not None:
            return tgt
        tgt=dict(w); changed=False
        for s,b in base.items():
            # If previous harvesting left the sleeve under its intended base, buy it back only after medium trend recovers.
            if w.get(s,0)<b*0.78 and above(p,s,i,180) and (mom(p[s],i,126) or 0)>0.04:
                tgt[s]=b; changed=True
        return tgt if changed else None
    return policy

def make_soft_rebalance_to_band(base, low=0.70, high=1.75):
    def policy(dates,p,i,w,pdd):
        tgt=dict(w); changed=False
        for s,b in base.items():
            if w.get(s,0)>b*high:
                # don't fully rebalance; just harvest excess back toward a still-large holding.
                tgt[s]=b*1.25; changed=True
            elif w.get(s,0)<b*low and above(p,s,i,180) and (mom(p[s],i,126) or 0)>0:
                tgt[s]=b; changed=True
        return tgt if changed else None
    return policy

def make_blowoff_rebuild_dd_guard(base):
    def policy(dates,p,i,w,pdd):
        # If the portfolio itself is already in a meaningful drawdown and Nasdaq trend is broken,
        # cut only the excess Nasdaq drift; keep gold as the product's anchor.
        if pdd>0.12 and (not above(p,'nasdaq',i,120) or (mom(p['nasdaq'],i,63) or 0)<-0.10):
            tgt=dict(w)
            tgt['nasdaq']=min(w.get('nasdaq',0), base.get('nasdaq',0))
            return tgt
        return make_blowoff_rebuild(base)(dates,p,i,w,pdd)
    return policy

def main():
    dates,p=CORE.align(CORE.fetch())
    base_policies=[('none',P0_none),('cap40_trim30',P1_cap40_trim30),('cap45_trend_trim30',P2_cap45_trend_trim30),('blowoff_harvest',P3_blowoff_harvest),('trailing_brake',P4_trailing_brake)]
    init_sets=[
        ('25_25',{'nasdaq':0.25,'gold_cny':0.25}),
        ('30_30',{'nasdaq':0.30,'gold_cny':0.30}),
        ('35N_25G',{'nasdaq':0.35,'gold_cny':0.25}),
        ('25N_35G',{'nasdaq':0.25,'gold_cny':0.35}),
        ('40N_20G',{'nasdaq':0.40,'gold_cny':0.20}),
        ('45N_15G',{'nasdaq':0.45,'gold_cny':0.15}),
        ('50N_10G',{'nasdaq':0.50,'gold_cny':0.10}),
    ]
    rows=[]
    for init_name,init in init_sets:
        policies = base_policies + [
            ('blowoff_rebuild', make_blowoff_rebuild(init)),
            ('soft_band_rebalance', make_soft_rebalance_to_band(init)),
            ('blowoff_rebuild_dd_guard', make_blowoff_rebuild_dd_guard(init)),
        ]
        for pol_name,pol in policies:
            name=f'D_{init_name}_{pol_name}'
            vals,w,e=simulate_policy(dates,p,name,pol,init=init)
            row={'name':name,'metrics':allm(dates,vals),'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w)}
            rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',pct(r['extra']['cash_pct']),'trades',r['extra']['trades'])
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
