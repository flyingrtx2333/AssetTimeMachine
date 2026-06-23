#!/usr/bin/env python3
from __future__ import annotations
import json, math, urllib.request, urllib.parse, datetime as dt, statistics, time
from pathlib import Path
OUT=Path('/tmp/atm_external_etf_12_8.json')
TARGET_ANN=0.12; TARGET_DD=0.08; START=100000.0; FEE=0.001; SLIP=0.0005
# Non-crypto external ETFs/proxies. Levered branch is separate.
CORE_ETFS={
    'QQQ':'纳指100ETF','SPY':'标普500ETF','DIA':'道指ETF','EWJ':'日本ETF','FXI':'中国大盘ETF','EEM':'新兴市场ETF','EFA':'发达海外ETF',
    'GLD':'黄金ETF','TLT':'20Y美债ETF','IEF':'7-10Y美债ETF','SHY':'短债ETF','UUP':'美元指数ETF','DBC':'商品篮子ETF','VNQ':'REITs',
}
LEVERED_ETFS={
    'QLD':'2x纳指100','SSO':'2x标普500','TQQQ':'3x纳指100','UPRO':'3x标普500','TMF':'3x长期美债','SSO':'2x标普500','UBT':'2x长期美债'
}

def yahoo(symbol, start='1990-01-01'):
    p1=int(dt.datetime.strptime(start,'%Y-%m-%d').replace(tzinfo=dt.timezone.utc).timestamp())
    p2=int(dt.datetime.now(dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(symbol)}?period1={p1}&period2={p2}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    data=json.load(urllib.request.urlopen(req,timeout=30))
    result=data['chart']['result'][0]
    ts=result['timestamp']; q=result['indicators']['quote'][0]; adj=result['indicators'].get('adjclose',[{}])[0].get('adjclose')
    close=adj or q['close']; pts=[]
    for t,c in zip(ts,close):
        if c and math.isfinite(c) and c>0:
            pts.append((dt.datetime.fromtimestamp(t,dt.timezone.utc).date(),float(c)))
    pts.sort(); out=[]
    for d,p in pts:
        if out and out[-1][0]==d: out[-1]=(d,p)
        else: out.append((d,p))
    return out

def align(series,assets,start=None):
    maps={s:dict(series[s]) for s in assets}
    dates=sorted(set.intersection(*(set(m.keys()) for m in maps.values())))
    if start: dates=[d for d in dates if d>=start]
    p={s:[maps[s][d] for d in dates] for s in assets}
    return dates,p

def cash_daily(prev): return 0.0035/365.25
def ma(v,i,n): return None if i-n+1<0 else sum(v[i-n+1:i+1])/n
def mom(v,i,n): return None if i-n<0 or v[i-n]<=0 else v[i]/v[i-n]-1
def above(p,s,i,n):
    m=ma(p[s],i,n); return m is not None and p[s][i]>m
def vol(v,i,n=63):
    if i-n<1: return None
    rs=[v[j]/v[j-1]-1 for j in range(i-n+1,i+1) if v[j-1]>0]
    return statistics.stdev(rs)*math.sqrt(252) if len(rs)>2 else None
def normalize(tw,cap=0.98):
    tw={k:max(0.0,float(v)) for k,v in tw.items() if v and v>1e-9}
    s=sum(tw.values())
    if s>cap and s>0: tw={k:v*cap/s for k,v in tw.items()}
    return tw
def trade_to(cash,units,p,i,target,assets,band=0.02):
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
def metrics(dates,vals,start=None,end=None):
    if start=='TENY': start=dates[-1].replace(year=dates[-1].year-10)
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    idx=[i for i,d in enumerate(dates) if d>=start and d<=end]
    if len(idx)<2: return None
    sub=[vals[i] for i in idx]; yrs=(dates[idx[-1]]-dates[idx[0]]).days/365.25
    ann=(sub[-1]/sub[0])**(1/max(yrs,1e-9))-1
    peak=sub[0]; dd=0; rs=[]
    for a,b in zip(sub,sub[1:]):
        if a>0: rs.append(b/a-1)
        peak=max(peak,b); dd=max(dd,1-b/peak if peak>0 else 0)
    vv=statistics.stdev(rs)*math.sqrt(252) if len(rs)>2 else 0
    sh=statistics.mean(rs)*252/vv if vv>0 else 0
    return {'ann':ann,'dd':dd,'total':sub[-1]/sub[0]-1,'vol':vv,'sharpe':sh,'calmar':ann/dd if dd>0 else 0}
def all_metrics(dates,vals):
    return {'full':metrics(dates,vals),'post2020':metrics(dates,vals,dt.date(2020,1,1)),'teny':metrics(dates,vals,'TENY'),'2024+':metrics(dates,vals,dt.date(2024,1,1))}
def topdds(dates,vals,weights):
    events=[]; pi=0; peak=vals[0]; ti=0; trough=vals[0]; indd=False
    for i,v in enumerate(vals):
        if v>=peak:
            if indd and trough<peak: events.append((pi,ti,1-trough/peak))
            peak=v; pi=i; trough=v; ti=i; indd=False
        elif v<trough: trough=v; ti=i; indd=True
    if indd and trough<peak: events.append((pi,ti,1-trough/peak))
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':dd,'weights':{k:round(v*100,1) for k,v in weights[b].items()},'cash':round((1-sum(weights[b].values()))*100,1)} for a,b,dd in sorted(events,key=lambda x:x[2],reverse=True)[:4]]

def score(p,s,i,lbs=(21,63,126,252),ws=(12,4,2,1),volpen=0):
    total=0
    for n,w in zip(lbs,ws):
        m=mom(p[s],i,n)
        if m is None: return None
        total+=w*m
    return total-volpen*(vol(p[s],i,63) or 0.25)

def rank(p,assets,i,volpen=0,need=120):
    rows=[]
    for s in assets:
        sc=score(p,s,i,volpen=volpen)
        if sc is None: continue
        ok=(mom(p[s],i,126) or -9)>0 and (above(p,s,i,need) if need else True)
        rows.append((sc,s,ok))
    return sorted(rows,reverse=True)

def simulate(dates,p,assets,fn,rebalance=21):
    cash=START; units={s:0.0 for s in assets}; vals=[]; weights=[]; trades=0; ctx={'peak':START,'state':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash+=cash*cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in assets); ctx['peak']=max(ctx['peak'],val)
        if i>252 and i%rebalance==0:
            sig=i-1; ctx['portfolio_dd']=1-val/ctx['peak']
            target=fn(dates,p,assets,sig,ctx)
            cash,units,did=trade_to(cash,units,p,i,target,assets)
            if did: trades+=1
            val=cash+sum(units[s]*p[s][i] for s in assets)
        vals.append(val); weights.append({s:units[s]*p[s][i]/val for s in assets if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0,1-sum(weights[-1].values()))}

# Mechanisms
SAFE=['SHY','IEF','TLT','GLD','UUP']
RISK=['QQQ','SPY','DIA','EWJ','FXI','EEM','EFA','DBC','VNQ']
def top_mom(k=2,budget=0.98,volpen=0.2,safe_when_bad=True):
    def fn(dates,p,assets,i,ctx):
        rows=rank(p,assets,i,volpen=volpen,need=120)
        good=[r for r in rows if r[2] and r[0]>0]
        if not good:
            safe=[r for r in rows if r[1] in SAFE and r[0]>0]
            return {safe[0][1]:0.90} if safe and safe_when_bad else {}
        take=good[:k]; vals=[max(0.01,x[0]) for x in take]; sm=sum(vals)
        return {s:budget*v/sm for v,(_,s,_) in zip(vals,take)}
    return fn
def risk_safe_rotation(top=2):
    def fn(dates,p,assets,i,ctx):
        risk=[s for s in RISK if s in assets]; safe=[s for s in SAFE if s in assets]
        risk_breadth=sum(1 for s in risk if above(p,s,i,120) and (mom(p[s],i,126) or -9)>0)/max(1,len(risk))
        if ctx.get('portfolio_dd',0)>0.07: risk_breadth=0
        if risk_breadth>=0.55:
            rows=[r for r in rank(p,risk,i,volpen=0.2,need=100) if r[2] and r[0]>0][:top]
            if not rows: return {}
            vals=[max(.01,r[0]) for r in rows]; sm=sum(vals)
            return {s:0.92*v/sm for v,(_,s,_) in zip(vals,rows)}
        # defensive: choose best safe asset, often TLT/GLD/SHY.
        rows=[r for r in rank(p,safe,i,volpen=0.1,need=80) if r[0]>0]
        if rows: return {rows[0][1]:0.90}
        return {}
    return fn
def levered_barbell():
    def fn(dates,p,assets,i,ctx):
        # only if levered symbols present. Risk-on TQQQ/UPRO, risk-off TMF/GLD/SHY.
        risk=[s for s in ['TQQQ','UPRO','QLD','SSO'] if s in assets]
        safe=[s for s in ['TMF','UBT','GLD','TLT','SHY'] if s in assets]
        sp_ok='SPY' in assets and above(p,'SPY',i,120) and (mom(p['SPY'],i,63) or -9)>0
        q_ok='QQQ' in assets and above(p,'QQQ',i,120) and (mom(p['QQQ'],i,63) or -9)>0
        if ctx.get('portfolio_dd',0)>0.065:
            rows=[r for r in rank(p,safe,i,volpen=0.1,need=60) if r[0]>0]
            return {rows[0][1]:0.70} if rows else {}
        if sp_ok and q_ok:
            rows=[r for r in rank(p,risk,i,volpen=0.35,need=60) if r[2] and r[0]>0]
            if rows:
                # Do not max out levered exposure; keep cash buffer.
                return {rows[0][1]:0.45, **({'GLD':0.25} if 'GLD' in assets and above(p,'GLD',i,100) else {})}
        rows=[r for r in rank(p,safe,i,volpen=0.1,need=60) if r[0]>0]
        return {rows[0][1]:0.80} if rows else {}
    return fn

def run_branch(name,symbols,start):
    series={}
    for s in symbols:
        try:
            series[s]=yahoo(s)
            print('FETCHED',s,series[s][0][0],series[s][-1][0],len(series[s]),flush=True)
            time.sleep(0.1)
        except Exception as e:
            print('FETCH_ERR',s,repr(e),flush=True)
    symbols=[s for s in symbols if s in series and len(series[s])>300]
    dates,p=align(series,symbols,start)
    rows=[]
    strategies=[('TOP1',top_mom(1),21),('TOP2',top_mom(2),21),('TOP3',top_mom(3),21),('RISK_SAFE_TOP1',risk_safe_rotation(1),21),('RISK_SAFE_TOP2',risk_safe_rotation(2),21),('RISK_SAFE_WEEKLY',risk_safe_rotation(1),5)]
    if any(s in symbols for s in ['TQQQ','UPRO','QLD','SSO']): strategies.append(('LEVERED_BARBELL',levered_barbell(),5))
    for name2,fn,reb in strategies:
        vals,w,e=simulate(dates,p,symbols,fn,reb)
        rows.append({'name':name2,'rebalance':reb,'metrics':all_metrics(dates,vals),'extra':e,'top_dd':topdds(dates,vals,w)})
    return {'branch':name,'symbols':symbols,'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows}

def main():
    core=list(CORE_ETFS.keys())
    lev=list(dict(CORE_ETFS|LEVERED_ETFS).keys())
    branches=[run_branch('core_etf_2006',core,dt.date(2006,1,1)), run_branch('levered_etf_2011',lev,dt.date(2011,1,1))]
    OUT.write_text(json.dumps({'target':{'ann':TARGET_ANN,'dd':TARGET_DD},'branches':branches},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT)
    for br in branches:
        print('\n##',br['branch'],br['coverage'],'symbols',','.join(br['symbols']))
        for r in sorted(br['rows'],key=lambda x:x['metrics']['full']['ann'],reverse=True):
            m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']
            mark='PASS' if m['ann']>=TARGET_ANN and m['dd']<=TARGET_DD else 'FAIL'
            print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'])
            print('  topdd',r['top_dd'][:2])
if __name__=='__main__': main()
