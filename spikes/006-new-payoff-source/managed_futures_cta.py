#!/usr/bin/env python3
from __future__ import annotations

import bisect, datetime as dt, json, math, statistics, urllib.parse, urllib.request
from pathlib import Path

API='https://api.flyingrtx.com/api/v1/money/public/history'
START=100000.0
OUT=Path('/tmp/atm_managed_futures_cta.json')
CACHE=Path('/tmp')

# Fixed, mechanism-level universe: liquid futures across metals, energy, grains, softs, livestock, rates, equity, FX.
UNIVERSE={
    'metals':['GC=F','SI=F','HG=F'],
    'energy':['CL=F'],
    'grains':['ZC=F','ZS=F','ZW=F'],
    'softs':['KC=F','SB=F','CT=F','CC=F'],
    'livestock':['LE=F','HE=F'],
    'rates':['ZB=F','ZN=F','ZF=F','ZT=F'],
    'equity':['ES=F','NQ=F'],
    'fx':['6E=F','6J=F','6B=F','6A=F','6C=F'],
}
SYMS=[s for g in UNIVERSE.values() for s in g]
STRESS={
 '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
 '2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
 '2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),
 '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
 '2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
 '2026AI波动':(dt.date(2025,12,1),None),
}
RATE_POINTS=[(dt.date(1999,6,10),0.0099),(dt.date(2002,2,21),0.0072),(dt.date(2007,7,21),0.0081),(dt.date(2007,12,21),0.0072),(dt.date(2008,11,27),0.0036),(dt.date(2011,4,6),0.005),(dt.date(2012,7,6),0.0035),(dt.date(2015,10,24),0.0035)]

def cash_daily(day):
    r=RATE_POINTS[0][1]
    for d,v in RATE_POINTS:
        if d<=day: r=v
        else: break
    return r/252

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

def fetch_api(symbols):
    q=urllib.parse.urlencode({'symbols':','.join(symbols),'period':'all'})
    return json.load(urllib.request.urlopen(API+'?'+q,timeout=90))['series']

def parse_api_series(ser):
    rows=[]
    for ds,p in zip(ser['dates'],ser['prices']):
        if p and p>0:
            rows.append((dt.date.fromisoformat(ds[:10]),float(p)))
    return rows

def fetch_yahoo(sym):
    safe=sym.replace('=','_').replace('^','_').replace('.','_').replace('-','_')
    cache=CACHE/f'atm_yahoo_cta_{safe}.json'
    if cache.exists():
        return [(dt.date.fromisoformat(d),float(p)) for d,p in json.loads(cache.read_text())]
    start=int(dt.datetime(2000,1,1,tzinfo=dt.timezone.utc).timestamp())
    end=int(dt.datetime(2026,6,21,tzinfo=dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    data=json.load(urllib.request.urlopen(req,timeout=60))
    r=data['chart']['result'][0]
    ts=r.get('timestamp') or []
    q=r['indicators']['quote'][0]
    arr=r['indicators'].get('adjclose',[{}])[0].get('adjclose') or q.get('close') or []
    rows=[]
    for t,p in zip(ts,arr):
        if p is not None and math.isfinite(float(p)) and float(p)>0:
            rows.append((dt.datetime.fromtimestamp(t,dt.UTC).date(),float(p)))
    cache.write_text(json.dumps([(d.isoformat(),p) for d,p in rows]))
    return rows

def load():
    raw=fetch_api(['usd_per_cny'])
    fx=parse_api_series(raw[0]); fxd=[d for d,_ in fx]; fxv=[p for _,p in fx]
    def usd_cny(day):
        j=bisect.bisect_right(fxd,day)-1
        if j<0: return None
        f=fxv[j]
        return 1/f if f<1 else f
    points={}
    coverage={}
    for s in SYMS:
        rows=[]
        for d,p in fetch_yahoo(s):
            u=usd_cny(d)
            if u and u>0:
                rows.append((d,p*u))
        points[s]=rows
        coverage[s]={'start':str(rows[0][0]),'end':str(rows[-1][0]),'count':len(rows)}
    all_dates=sorted(set(d for rows in points.values() for d,_ in rows))
    idx={s:0 for s in SYMS}; latest={}; latest_d={}; prices={s:[] for s in SYMS}; dates=[]
    for day in all_dates:
        for s in SYMS:
            rows=points[s]; j=idx[s]
            while j<len(rows) and rows[j][0]<=day:
                latest[s]=rows[j][1]; latest_d[s]=rows[j][0]; j+=1
            idx[s]=j
        if all(s in latest and (day-latest_d[s]).days<=7 for s in SYMS):
            dates.append(day)
            for s in SYMS: prices[s].append(latest[s])
    coverage['aligned']={'start':str(dates[0]),'end':str(dates[-1]),'count':len(dates)}
    return dates,prices,coverage

def mom(vals,i,n):
    if i-n<0 or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def vol_ret(rets,i,n):
    if i-n+1<0: return None
    arr=rets[i-n+1:i+1]
    if len(arr)<2 or any(x is None for x in arr): return None
    m=sum(arr)/len(arr)
    return math.sqrt(sum((x-m)**2 for x in arr)/(len(arr)-1))*math.sqrt(252)

def metrics(dates,vals,start=None,end=None):
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]
    peak=vs[0]; mdd=0; rs=[]
    for a,b in zip(vs,vs[1:]):
        rs.append(b/a-1); peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=max((ds[-1]-ds[0]).days/365.25,1e-9)
    ann=(vs[-1]/vs[0])**(1/years)-1
    vv=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=statistics.mean(rs)*252/vv if vv else 0
    return {'start':str(ds[0]),'end':str(ds[-1]),'ann':ann,'dd':mdd,'total':vs[-1]/vs[0]-1,'vol':vv,'sharpe':sh,'calmar':ann/mdd if mdd else 0}

def drawdowns(dates,vals,weights,n=5):
    peak=trough=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[trough]<vals[peak]*.985: out.append((peak,trough,1-vals[trough]/vals[peak],weights[trough]))
            peak=trough=i
        elif vals[i]<vals[trough]: trough=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v,3) for k,v in w.items() if abs(v)>0.02}} for a,b,c,w in out[:n]]

def group_cap(raw):
    # fixed risk cluster cap: no cluster dominates the CTA book.
    out=raw.copy()
    for group,syms in UNIVERSE.items():
        gross=sum(abs(out.get(s,0)) for s in syms)
        cap=0.75 if group not in ('equity','rates') else 0.60
        if gross>cap and gross>0:
            for s in syms: out[s]*=cap/gross
    gross=sum(abs(v) for v in out.values())
    if gross>3.0 and gross>0:
        out={s:v*3.0/gross for s,v in out.items()}
    return out

def cta_weights(prices,rets,i,target_vol=0.10):
    active=[]
    for s in SYMS:
        m=mom(prices[s],i,252)
        vv=vol_ret(rets[s],i,60)
        if m is None or vv is None or vv<=0: continue
        sig=1 if m>0 else -1
        # one asset gets equal risk share; no fitted thresholds.
        active.append((s,sig,vv))
    if not active: return {}
    per_asset_risk=target_vol/math.sqrt(len(active))
    raw={s:sig*min(0.55,per_asset_risk/max(vv,0.05)) for s,sig,vv in active}
    return group_cap(raw)

def simulate_cta(dates,prices,target_vol=0.10):
    rets={s:[0.0]*len(dates) for s in SYMS}
    for s in SYMS:
        for i in range(1,len(dates)):
            rets[s][i]=prices[s][i]/prices[s][i-1]-1 if prices[s][i-1]>0 else 0
    value=START; vals=[]; weights=[]; w={s:0.0 for s in SYMS}; trades=0; turnover=0.0
    for i,d in enumerate(dates):
        if i>0:
            pnl=sum(w[s]*rets[s][i] for s in SYMS)
            value *= (1 + cash_daily(dates[i-1]) + pnl)
            if value<=0: raise RuntimeError('blown up')
        if i>260 and i%21==0:
            nw=cta_weights(prices,rets,i-1,target_vol)
            turn=sum(abs(nw.get(s,0)-w.get(s,0)) for s in SYMS)
            # realistic small futures/roll/turnover drag: 2 bps per notional turned + small annual ops drag.
            value *= (1 - 0.0002*turn - 0.003/12)
            turnover += turn; trades += sum(1 for s in SYMS if abs(nw.get(s,0)-w.get(s,0))>0.01)
            w={s:nw.get(s,0.0) for s in SYMS}
        vals.append(value); weights.append(w.copy())
    return vals,weights,{'trades':trades,'avg_turnover':turnover/max(1,trades),'latest':weights[-1]}

def main():
    dates,prices,cov=load()
    rows=[]
    for tv in [0.08,0.10,0.12]:
        vals,weights,extra=simulate_cta(dates,prices,tv)
        ten=dates[-1].replace(year=dates[-1].year-10)
        row={'name':f'K_managed_futures_cta_tv{tv:.2f}','target_vol':tv,'extra':extra,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':drawdowns(dates,vals,weights)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':cov,'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',cov['aligned'])
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('latest',{k:round(v,2) for k,v in r['extra']['latest'].items() if abs(v)>0.02},'gross',round(sum(abs(v) for v in r['extra']['latest'].values()),2),'trades',r['extra']['trades'])
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
