#!/usr/bin/env python3
from __future__ import annotations

import bisect, datetime as dt, json, math, statistics, urllib.request, urllib.parse
from pathlib import Path

API='https://api.flyingrtx.com/api/v1/money/public/history'
START=100000.0; FEE=.001; SLIP=.0005; BAND=.02
OUT=Path('/tmp/atm_new_yahoo_growth_logic.json')
RISK=['QQQ','XLK','SPY']
SYMS=['QQQ','XLK','SPY','gold_cny']
STRESS={
 '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
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
    cache=Path(f'/tmp/atm_yahoo_{sym.lower()}_adj_2001_2026.json')
    if cache.exists():
        return [(dt.date.fromisoformat(d),float(p)) for d,p in json.loads(cache.read_text())]
    start=int(dt.datetime(2001,1,1,tzinfo=dt.timezone.utc).timestamp())
    end=int(dt.datetime(2026,6,21,tzinfo=dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    data=json.load(urllib.request.urlopen(req,timeout=60))
    r=data['chart']['result'][0]; ts=r.get('timestamp') or []
    q=r['indicators']['quote'][0]
    adj=r['indicators'].get('adjclose',[{}])[0].get('adjclose') or q['close']
    rows=[]
    for t,p in zip(ts,adj):
        if p and p>0:
            rows.append((dt.datetime.fromtimestamp(t,dt.UTC).date(),float(p)))
    cache.write_text(json.dumps([(d.isoformat(),p) for d,p in rows]))
    return rows

def load():
    raw=fetch_api(['gold_cny','usd_per_cny'])
    api={ser['symbol']:parse_api_series(ser) for ser in raw}
    fx=api['usd_per_cny']; fxd=[d for d,_ in fx]; fxv=[p for _,p in fx]
    def fx_on(d):
        j=bisect.bisect_right(fxd,d)-1
        return fxv[j] if j>=0 else None
    points={'gold_cny':api['gold_cny']}
    coverage={}
    for s in RISK:
        rows=[]
        for d,p in fetch_yahoo(s):
            f=fx_on(d)
            if f and f>0:
                # API convention: usd_per_cny may be USD/CNY inverse; same as previous scripts: if <1 divide.
                cny=p/f if f<1 else p*f
                rows.append((d,cny))
        points[s]=rows
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
    for s in SYMS:
        coverage[s]={'start':str(next(d for d,p in points[s] if p>0)),'end':str(points[s][-1][0]),'count':len(points[s])}
    coverage['aligned']={'start':str(dates[0]),'end':str(dates[-1]),'count':len(dates)}
    return dates,prices,coverage

def ma(vals,i,n):
    if i-n+1<0: return None
    return sum(vals[i-n+1:i+1])/n

def mom(vals,i,n):
    if i-n<0 or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def dd(vals,i,n):
    if i-n+1<0: return None
    high=max(vals[i-n+1:i+1]); return vals[i]/high-1 if high>0 else None

def vol(vals,i,n):
    if i-n<1: return None
    rs=[math.log(vals[j]/vals[j-1]) for j in range(i-n+1,i+1) if vals[j-1]>0]
    if len(rs)<2: return None
    m=sum(rs)/len(rs); return math.sqrt(sum((x-m)**2 for x in rs)/(len(rs)-1))*math.sqrt(252)

def valid_growth(prices,s,i):
    return (ma(prices[s],i,200) is not None and prices[s][i]>ma(prices[s],i,200)
            and (mom(prices[s],i,120) or -9)>0
            and (dd(prices[s],i,20) or 0)>-0.07
            and (vol(prices[s],i,60) or 9)<0.40)

def gold_ok(prices,i):
    g=prices['gold_cny']
    blow=((mom(g,i,252) or 0)>0.25 and (dd(g,i,20) or 0)<-0.045) or ((mom(g,i,120) or 0)>0.14 and (dd(g,i,60) or 0)<-0.09)
    return ma(g,i,200) is not None and g[i]>ma(g,i,200) and (mom(g,i,120) or -9)>0 and not blow

def target_quality_growth(prices,i):
    # 新逻辑：只买“质量增长核心”（QQQ/XLK），SPY 只是降波辅助；黄金是独立避险收益源。
    ranked=[]
    for s in ['QQQ','XLK']:
        if valid_growth(prices,s,i):
            sc=0.7*(mom(prices[s],i,120) or 0)+0.3*(mom(prices[s],i,252) or 0)-0.25*(vol(prices[s],i,60) or 0.2)
            ranked.append((sc,s))
    ranked.sort(reverse=True)
    w={}
    if ranked:
        leader=ranked[0][1]
        w[leader]=0.58
        if valid_growth(prices,'SPY',i): w['SPY']=0.17
        if gold_ok(prices,i): w['gold_cny']=0.15
    elif gold_ok(prices,i) and (dd(prices['gold_cny'],i,20) or 0)>-0.04:
        w['gold_cny']=0.50
    sm=sum(w.values())
    if sm>.90: w={k:v*.90/sm for k,v in w.items()}
    return w

def target_crash_repair(prices,i):
    qdd=dd(prices['QQQ'],i,252) or 0; sdd=dd(prices['SPY'],i,252) or 0
    damaged=qdd<-0.18 or sdd<-0.14
    repair=damaged and (mom(prices['QQQ'],i,20) or -9)>0.04 and (mom(prices['SPY'],i,20) or -9)>0.025 and (vol(prices['QQQ'],i,20) or 9)<0.45
    smooth=valid_growth(prices,'QQQ',i) and valid_growth(prices,'SPY',i) and (dd(prices['QQQ'],i,20) or 0)>-0.045
    if repair: return {'QQQ':0.62,'SPY':0.18}
    if smooth: return {'QQQ':0.50,'SPY':0.20,'gold_cny':0.12 if gold_ok(prices,i) else 0}
    if gold_ok(prices,i) and (dd(prices['gold_cny'],i,20) or 0)>-0.04: return {'gold_cny':0.45}
    return {}

def target_market_permission_growth(prices,i):
    # 新逻辑：增长资产需要“市场许可”。QQQ/XLK 自己强不够，SPY 必须确认整体风险偏好。
    # 这样避免在 2008、2022 这种系统性熊市里被单一科技强势假象骗进去。
    spy_ok = ma(prices['SPY'],i,200) is not None and prices['SPY'][i] > ma(prices['SPY'],i,200) and (mom(prices['SPY'],i,120) or -9) > 0 and (dd(prices['SPY'],i,60) or 0) > -0.08
    w={}
    if spy_ok:
        ranked=[]
        for s in ['QQQ','XLK']:
            if valid_growth(prices,s,i):
                sc=0.7*(mom(prices[s],i,120) or 0)+0.3*(mom(prices[s],i,252) or 0)-0.25*(vol(prices[s],i,60) or 0.2)
                ranked.append((sc,s))
        ranked.sort(reverse=True)
        if ranked:
            leader=ranked[0][1]
            w[leader]=0.50
            w['SPY']=0.20
            if gold_ok(prices,i) and (dd(prices['gold_cny'],i,20) or 0)>-0.04:
                w['gold_cny']=0.12
            return w
    # 无市场许可时，不做增长；黄金也必须独立健康，否则现金。
    if gold_ok(prices,i) and (dd(prices['gold_cny'],i,20) or 0)>-0.04:
        return {'gold_cny':0.42}
    return {}

def simulate(name,dates,prices,fn):
    cash=START; units={s:0.0 for s in SYMS}; vals=[]; ws=[]; trades=0
    def pv(i): return cash+sum(units[s]*prices[s][i] for s in SYMS)
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*cash_daily(dates[i-1])
        if i>260:
            sig=i-1; target=fn(prices,sig); total=pv(i)
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target.get(s,0)
                if cur>tgt*(1+BAND):
                    su=min(units[s],(cur-tgt)/prices[s][i])
                    if su>0: cash+=su*prices[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; trades+=1
            total=pv(i)
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target.get(s,0)
                if cur<tgt*(1-BAND):
                    amt=min(cash,tgt-cur)
                    if amt>1: units[s]+=amt*(1-FEE)/(prices[s][i]*(1+SLIP)); cash-=amt; trades+=1
        v=pv(i); vals.append(v); ws.append({s:units[s]*prices[s][i]/v for s in SYMS if units[s]*prices[s][i]/v>0.0001})
    return {'name':name,'values':vals,'weights':ws,'trades':trades,'latest':ws[-1],'cash_pct':max(0,1-sum(ws[-1].values()))}

def metrics(dates,vals,start=None,end=None):
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]; peak=vs[0]; mdd=0; rs=[]
    for a,b in zip(vs,vs[1:]):
        if a>0: rs.append(b/a-1)
        peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=(ds[-1]-ds[0]).days/365.25
    ann=(vs[-1]/vs[0])**(1/years)-1
    vv=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=statistics.mean(rs)*252/vv if vv else 0
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
    dates,prices,cov=load(); runs=[simulate('H_quality_growth_QQQ_XLK',dates,prices,target_quality_growth),simulate('I_q_growth_crash_repair',dates,prices,target_crash_repair),simulate('J_market_permission_growth',dates,prices,target_market_permission_growth)]
    rows=[]
    for r in runs:
        vals=r.pop('values'); weights=r.pop('weights')
        ten=dates[-1].replace(year=dates[-1].year-10)
        row={**r,'metrics':{'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,ten),'2024+':metrics(dates,vals,dt.date(2024,1,1)),'2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31))},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'top_dd':episodes(dates,vals,weights)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':cov,'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',cov['aligned'])
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('latest',{k:round(v*100,1) for k,v in r['latest'].items()},'cash',pct(r['cash_pct']),'trades',r['trades'])
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
