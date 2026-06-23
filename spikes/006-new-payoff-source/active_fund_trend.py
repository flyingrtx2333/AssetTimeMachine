#!/usr/bin/env python3
from __future__ import annotations
import bisect, datetime as dt, json, math, statistics, urllib.parse, urllib.request
from pathlib import Path

API='https://api.flyingrtx.com/api/v1/money/public/history'
SYMS=['FPACX','PRWCX','VWINX','VFISX','DODIX','VUSTX','QQQ','SPY']
GROWTH=['FPACX','PRWCX','QQQ']
DEF=['VFISX','DODIX','VUSTX']
OUT=Path('/tmp/atm_active_fund_trend.json')
STRESS={
 '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
 '2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
 '2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),
 '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
 '2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
 '2026AI波动':(dt.date(2025,12,1),None),
}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

def fetch_api(symbols):
    q=urllib.parse.urlencode({'symbols':','.join(symbols),'period':'all'})
    return json.load(urllib.request.urlopen(API+'?'+q,timeout=90))['series']

def parse_api_series(ser):
    rows=[]
    for ds,p in zip(ser['dates'],ser['prices']):
        if p and p>0: rows.append((dt.date.fromisoformat(ds[:10]),float(p)))
    return rows

def fetch_yahoo(sym):
    cache=Path(f'/tmp/atm_yahoo_active_{sym}.json')
    if cache.exists(): return [(dt.date.fromisoformat(d),float(p)) for d,p in json.loads(cache.read_text())]
    start=int(dt.datetime(1999,1,1,tzinfo=dt.timezone.utc).timestamp()); end=int(dt.datetime(2026,6,21,tzinfo=dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    data=json.load(urllib.request.urlopen(req,timeout=60))
    r=data['chart']['result'][0]; ts=r.get('timestamp') or []
    q=r['indicators']['quote'][0]; arr=r['indicators'].get('adjclose',[{}])[0].get('adjclose') or q.get('close') or []
    rows=[]
    for t,p in zip(ts,arr):
        if p and math.isfinite(float(p)) and p>0: rows.append((dt.datetime.fromtimestamp(t,dt.UTC).date(),float(p)))
    cache.write_text(json.dumps([(d.isoformat(),p) for d,p in rows])); return rows

def load():
    fx=parse_api_series(fetch_api(['usd_per_cny'])[0]); fxd=[d for d,_ in fx]; fxv=[p for _,p in fx]
    def usd_cny(day):
        j=bisect.bisect_right(fxd,day)-1
        if j<0: return None
        f=fxv[j]; return 1/f if f<1 else f
    points={}; cov={}
    for s in SYMS:
        rows=[]
        for d,p in fetch_yahoo(s):
            u=usd_cny(d)
            if u: rows.append((d,p*u))
        points[s]=rows; cov[s]={'start':str(rows[0][0]),'end':str(rows[-1][0]),'count':len(rows)}
    all_dates=sorted(set(d for rows in points.values() for d,_ in rows)); idx={s:0 for s in SYMS}; latest={}; latest_d={}; prices={s:[] for s in SYMS}; dates=[]
    for day in all_dates:
        for s in SYMS:
            rows=points[s]; j=idx[s]
            while j<len(rows) and rows[j][0]<=day:
                latest[s]=rows[j][1]; latest_d[s]=rows[j][0]; j+=1
            idx[s]=j
        if all(s in latest and (day-latest_d[s]).days<=7 for s in SYMS):
            dates.append(day)
            for s in SYMS: prices[s].append(latest[s])
    cov['aligned']={'start':str(dates[0]),'end':str(dates[-1]),'count':len(dates)}
    return dates,prices,cov

def ma(v,i,n):
    if i-n+1<0: return None
    return sum(v[i-n+1:i+1])/n

def mom(v,i,n):
    if i-n<0 or v[i-n]<=0: return None
    return v[i]/v[i-n]-1

def dd(v,i,n):
    if i-n+1<0: return None
    h=max(v[i-n+1:i+1]); return v[i]/h-1 if h>0 else None

def vol(v,i,n):
    if i-n<1: return None
    rs=[math.log(v[j]/v[j-1]) for j in range(i-n+1,i+1) if v[j-1]>0]
    if len(rs)<2: return None
    m=sum(rs)/len(rs); return math.sqrt(sum((x-m)**2 for x in rs)/(len(rs)-1))*math.sqrt(252)

def healthy(prices,s,i):
    return ma(prices[s],i,200) is not None and prices[s][i]>ma(prices[s],i,200) and (mom(prices[s],i,120) or -9)>0 and (dd(prices[s],i,60) or 0)>-0.08

def best_def(prices,i):
    # Defensive carry selector: choose the healthiest low-risk bond/cash-plus fund; if long bonds are unstable prefer short-term.
    candidates=[]
    for s in DEF:
        score=(mom(prices[s],i,120) or 0)-0.5*(vol(prices[s],i,60) or 0.03)
        if (dd(prices[s],i,60) or 0)>-0.06: candidates.append((score,s))
    if not candidates: return 'VFISX'
    return sorted(candidates,reverse=True)[0][1]

def target_active_alpha(prices,i):
    # New payoff source: active absolute-return/balanced managers as return engine, short-duration fund as capital parking.
    # Only allocate to manager when its own NAV trend confirms; otherwise defense is an actual carry asset, not idle cash.
    good=[]
    for s in ['FPACX','PRWCX','VWINX']:
        if healthy(prices,s,i):
            good.append(((mom(prices[s],i,120) or 0)-0.35*(vol(prices[s],i,60) or 0.1),s))
    good.sort(reverse=True)
    d=best_def(prices,i)
    if not good:
        return {d:0.90}
    leader=good[0][1]
    # If broad SPY is unhealthy, do not let active fund consume full risk budget.
    broad_ok=healthy(prices,'SPY',i)
    return {leader:0.62 if broad_ok else 0.42, d:0.30 if broad_ok else 0.50}

def target_alpha_plus_q(prices,i):
    # Active fund core + QQQ only when broad market and QQQ both healthy; otherwise carry defense.
    d=best_def(prices,i); w={d:0.45}
    active=[]
    for s in ['FPACX','PRWCX']:
        if healthy(prices,s,i): active.append(((mom(prices[s],i,120) or 0)-0.35*(vol(prices[s],i,60) or 0.1),s))
    active.sort(reverse=True)
    if active:
        w[active[0][1]]=0.35
    if healthy(prices,'SPY',i) and healthy(prices,'QQQ',i) and (dd(prices['QQQ'],i,20) or 0)>-0.05:
        w['QQQ']=0.18
    return w

def simulate(name,dates,prices,fn):
    units={s:0.0 for s in SYMS}; cash=100000.0; vals=[]; ws=[]; trades=0
    def pv(i): return cash+sum(units[s]*prices[s][i] for s in SYMS)
    for i,d in enumerate(dates):
        if i>260 and i%21==0:
            sig=i-1; target=fn(prices,sig); total=pv(i)
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target.get(s,0)
                if cur>tgt*1.02:
                    su=min(units[s],(cur-tgt)/prices[s][i])
                    if su>0: cash+=su*prices[s][i]*(1-.0005)*(1-.001); units[s]-=su; trades+=1
            total=pv(i)
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target.get(s,0)
                if cur<tgt*.98:
                    amt=min(cash,tgt-cur)
                    if amt>1: units[s]+=amt*(1-.001)/(prices[s][i]*(1+.0005)); cash-=amt; trades+=1
        v=pv(i); vals.append(v); ws.append({s:units[s]*prices[s][i]/v for s in SYMS if units[s]*prices[s][i]/v>.0001})
    return {'name':name,'values':vals,'weights':ws,'trades':trades,'latest':ws[-1],'cash_pct':max(0,1-sum(ws[-1].values()))}

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

def episodes(dates,vals,weights,n=5):
    peak=trough=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[trough]<vals[peak]*.985: out.append((peak,trough,1-vals[trough]/vals[peak],weights[trough]))
            peak=trough=i
        elif vals[i]<vals[trough]: trough=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v*100,1) for k,v in w.items()}} for a,b,c,w in out[:n]]

def main():
    dates,prices,cov=load(); runs=[simulate('L_active_alpha_trend_carry',dates,prices,target_active_alpha),simulate('M_active_alpha_plus_q_carry',dates,prices,target_alpha_plus_q)]
    rows=[]
    for r in runs:
        vals=r.pop('values'); weights=r.pop('weights'); ten=dates[-1].replace(year=dates[-1].year-10)
        row={**r,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':episodes(dates,vals,weights)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':cov,'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',cov['aligned'])
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('latest',{k:round(v*100,1) for k,v in r['latest'].items()},'cash',pct(r['cash_pct']),'trades',r['trades'])
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
