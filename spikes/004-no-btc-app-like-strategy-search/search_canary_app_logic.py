#!/usr/bin/env python3
from __future__ import annotations
import datetime as dt, json, math, statistics, urllib.parse, urllib.request, itertools
from pathlib import Path
from typing import Any

API='https://api.flyingrtx.com/api/v1/money/public/history'
RAW=['gold_cny','nasdaq','sp500','dow_jones','csi300','shanghai_composite','usd_per_cny']
ASSETS=['gold_cny','nasdaq','sp500','dowjones','csi300','shanghai_composite']
US={'nasdaq','sp500','dowjones'}
START=100000.0; FEE=0.001; SLIP=0.0005; STALE=7
OUT=Path('/tmp/atm_canary_app_logic_search.json')
RATE_POINTS=[(dt.date(1990,4,15),0.0288),(dt.date(1990,8,21),0.0216),(dt.date(1991,4,21),0.018),(dt.date(1993,5,15),0.0216),(dt.date(1993,7,11),0.0315),(dt.date(1996,5,1),0.0297),(dt.date(1996,8,23),0.0198),(dt.date(1997,10,23),0.0171),(dt.date(1998,3,25),0.0171),(dt.date(1998,7,1),0.0144),(dt.date(1998,12,7),0.0144),(dt.date(1999,6,10),0.0099),(dt.date(2002,2,21),0.0072),(dt.date(2004,10,29),0.0072),(dt.date(2006,8,19),0.0072),(dt.date(2007,3,18),0.0072),(dt.date(2007,5,19),0.0072),(dt.date(2007,7,21),0.0081),(dt.date(2007,8,22),0.0081),(dt.date(2007,9,15),0.0081),(dt.date(2007,12,21),0.0072),(dt.date(2008,10,9),0.0072),(dt.date(2008,10,30),0.0072),(dt.date(2008,11,27),0.0036),(dt.date(2008,12,23),0.0036),(dt.date(2010,10,20),0.0036),(dt.date(2010,12,26),0.0036),(dt.date(2011,2,9),0.004),(dt.date(2011,4,6),0.005),(dt.date(2011,7,7),0.005),(dt.date(2012,6,8),0.004),(dt.date(2012,7,6),0.0035),(dt.date(2015,3,1),0.0035),(dt.date(2015,5,11),0.0035),(dt.date(2015,6,28),0.0035),(dt.date(2015,8,26),0.0035),(dt.date(2015,10,24),0.0035)]
PERIODS={'full':(None,None),'post2020':(dt.date(2020,1,1),None),'2024+':(dt.date(2024,1,1),None),'2002-2012':(dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':(dt.date(2013,1,1),dt.date(2023,12,31))}
STRESS={'2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),'2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),'2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),'2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),'2026AI波动':(dt.date(2025,12,1),None)}

def cash_daily(day):
    r=RATE_POINTS[0][1]
    for d,v in RATE_POINTS:
        if d<=day: r=v
        else: break
    return max(r,0)/252.0

def fetch():
    q=urllib.parse.urlencode({'symbols':','.join(RAW),'period':'all'})
    data=json.load(urllib.request.urlopen(API+'?'+q,timeout=90))
    raw={}
    for ser in data['series']:
        sym={'dow_jones':'dowjones','nasdaq_composite':'nasdaq'}.get(ser['symbol'],ser['symbol'])
        rows=[]
        for ds,p in zip(ser.get('dates',[]),ser.get('prices',[])):
            try:
                day=dt.date.fromisoformat(str(ds)[:10]); val=float(p)
            except Exception: continue
            if math.isfinite(val) and val>0: rows.append((day,val))
        raw[sym]=sorted(rows)
    # convert USD assets to CNY by usd_per_cny (API value is USD per CNY, so divide)
    fx=raw['usd_per_cny']; fxd=[x[0] for x in fx]; fxv=[x[1] for x in fx]
    import bisect
    out={}
    for s in ASSETS:
        rr=raw[s]; rows=[]
        for day,p in rr:
            val=p
            if s in US:
                j=bisect.bisect_right(fxd,day)-1
                if j<0: continue
                val=p/fxv[j]
            rows.append((day,val))
        out[s]=rows
    return out

def align(series):
    dates=sorted(set(d for rows in series.values() for d,_ in rows))
    idx={s:0 for s in ASSETS}; latest={}; latest_day={}; prices={s:[] for s in ASSETS}; out=[]
    for day in dates:
        for s in ASSETS:
            rows=series[s]; i=idx[s]
            while i<len(rows) and rows[i][0]<=day:
                latest[s]=rows[i][1]; latest_day[s]=rows[i][0]; i+=1
            idx[s]=i
        if all(s in latest and (day-latest_day[s]).days<=STALE for s in ASSETS):
            out.append(day)
            for s in ASSETS: prices[s].append(latest[s])
    return out,prices

def ma(vals,i,n):
    if n<=0: return vals[i] if 0<=i<len(vals) else None
    if i-n+1<0: return None
    return sum(vals[i-n+1:i+1])/n

def mom(vals,i,n):
    if n<=0 or i-n<0 or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def multi_mom(vals,i,lbs,ws):
    total=0.0
    for k,lb in enumerate(lbs):
        m=mom(vals,i,lb)
        if m is None: return None
        total += m*(ws[k] if k<len(ws) else 1.0)
    return total

def rolling_vol(vals,period):
    out=[None]*len(vals)
    for i in range(len(vals)):
        if period<=1 or i-period+1<1: continue
        rs=[]
        for j in range(i-period+1,i+1):
            if vals[j-1]>0 and vals[j]>0: rs.append(vals[j]/vals[j-1]-1)
        if len(rs)>=2:
            mean=sum(rs)/len(rs); var=sum((x-mean)**2 for x in rs)/len(rs) # Swift uses count, not count-1
            out[i]=math.sqrt(max(var,0))*math.sqrt(252)
    return out

def target(i,prices,vols,cfg):
    can=[s for s in cfg['canary'] if s in ASSETS]
    if not can: return {}
    def mm(s): return multi_mom(prices[s],i,cfg['lbs'],cfg['ws'])
    def above(s,n):
        mv=ma(prices[s],i,n)
        return mv is not None and prices[s][i] > mv
    weak=0
    for s in can:
        if (mm(s) if mm(s) is not None else -1e9) < cfg['canary_thr'] or not above(s,cfg['canary_ma']): weak+=1
    risk_on=weak <= max(cfg['weak_allowed'],0)
    tw={}
    if risk_on:
        ranked=[]
        for s in cfg['offensive']:
            if s not in ASSETS: continue
            m=mm(s); v=vols[s][i]
            if m is None or m <= cfg['asset_thr'] or not above(s,cfg['asset_ma']): continue
            if v is not None and v >= cfg['vol_cap']: continue
            vv=max(v if v is not None else 0.18,0.05)
            ranked.append((m/vv,s))
        ranked.sort(key=lambda x:(-x[0],x[1]))
        selected=ranked[:max(cfg['top'],1)]
        if selected:
            ow=max(cfg['off_w'],0)
            if cfg.get('equal',False):
                for _,s in selected: tw[s]=ow/len(selected)
            else:
                inv=[]
                for _,s in selected:
                    v=max(vols[s][i] if vols[s][i] is not None else 0.18,0.05)
                    inv.append((s,1/v))
                tot=sum(x for _,x in inv)
                if tot>0:
                    for s,x in inv: tw[s]=ow*x/tot
        ds=cfg['defensive_symbol']
        dm=mm(ds) if ds in ASSETS else None
        if ds in ASSETS and dm is not None and dm>cfg['def_thr'] and above(ds,cfg['def_ma']):
            tw[ds]=tw.get(ds,0)+max(cfg['ballast'],0)
    else:
        ds=cfg['defensive_symbol']; dm=mm(ds) if ds in ASSETS else None
        if ds in ASSETS and dm is not None and dm>cfg['def_thr'] and above(ds,cfg['def_ma']):
            tw[ds]=max(cfg['def_only'],0)
    gross=sum(max(x,0) for x in tw.values()); mx=min(max(cfg['max_exp'],0),1)
    if gross>mx and gross>0: tw={s:max(w,0)*mx/gross for s,w in tw.items()}
    return {s:w for s,w in tw.items() if w>0.0001}

def simulate(dates,prices,cfg):
    vols=cfg.get('_vols') or {s:rolling_vol(prices[s],cfg['vol_lb']) for s in ASSETS}
    cash=START; units={s:0.0 for s in ASSETS}; held=set(); vals=[]; weights=[]; trades=0
    warmup=max(cfg['lookback'],cfg['ma_filter'],cfg['vol_lb'],max(cfg['lbs']),cfg['canary_ma'],cfg['asset_ma'],cfg['def_ma'])+1
    last_reb=-10**9
    def pv(i): return cash+sum(units[s]*prices[s][i] for s in ASSETS)
    for i,day in enumerate(dates):
        if i>0 and cash>0: cash += cash*cash_daily(dates[i-1])
        should = (i>0 and i-last_reb>=cfg['rebalance']) if cfg.get('from_first',True) else (i==0 or i%cfg['rebalance']==0)
        if should:
            sig=i-1; pre=pv(i)
            tw = target(sig,prices,vols,cfg) if sig>=warmup-1 else {}
            targets=set(tw)
            # sell symbols no longer target
            for s in list(held-targets):
                if units[s]>0:
                    gross=units[s]*prices[s][i]*(1-SLIP); cash += gross*(1-FEE); units[s]=0; trades+=1
            held &= targets
            band=cfg['band']
            for s in sorted(targets):
                cur=units[s]*prices[s][i]; tgt=pre*tw[s]
                if cur > tgt*(1+band):
                    sell_value=cur-tgt; sell_units=min(units[s],sell_value/prices[s][i])
                    if sell_units>0:
                        gross=sell_units*prices[s][i]*(1-SLIP); cash+=gross*(1-FEE); units[s]-=sell_units; trades+=1
                        if units[s]<=1e-12: units[s]=0; held.discard(s)
            total=pv(i)
            for s in sorted(targets):
                cur=units[s]*prices[s][i]; tgt=total*tw[s]
                if cur < tgt*(1-band):
                    amt=min(cash,max(tgt-cur,0))
                    if amt>0:
                        units[s]+=amt*(1-FEE)/(prices[s][i]*(1+SLIP)); cash-=amt; held.add(s); trades+=1
            last_reb=i
        val=pv(i); vals.append(val); weights.append({s:units[s]*prices[s][i]/val for s in ASSETS if val>0 and units[s]*prices[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1]}

def metrics(dates,vals,start=None,end=None):
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=0
    while lo<len(dates) and dates[lo]<start: lo+=1
    hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]; peak=vs[0]; dd=0; rs=[]
    for a,b in zip(vs,vs[1:]):
        if a>0 and b>0: rs.append(b/a-1)
        peak=max(peak,b); dd=max(dd,1-b/peak)
    years=max((ds[-1]-ds[0]).days,1)/365.25
    ann=(vs[-1]/vs[0])**(1/years)-1; total=vs[-1]/vs[0]-1
    vol=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=(statistics.mean(rs)*252)/vol if vol>0 else 0
    return {'start':str(ds[0]),'end':str(ds[-1]),'n':len(vs),'ann':ann,'dd':dd,'total':total,'vol':vol,'sharpe':sh,'calmar':ann/dd if dd else 0}

def allm(dates,vals):
    p=dict(PERIODS)
    try: ten=dates[-1].replace(year=dates[-1].year-10)
    except Exception: ten=dates[-1]-dt.timedelta(days=3652)
    p['teny']=(ten,None)
    return {k:metrics(dates,vals,a,b) for k,(a,b) in p.items()}

def topdds(dates,vals,weights,n=5):
    peak=tr=0; eps=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr] < vals[peak]*0.985: eps.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    if vals[tr] < vals[peak]*0.985: eps.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
    eps.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v*100,1) for k,v in w.items()}} for a,b,c,w in eps[:n]]

def score(row):
    m=row['metrics']; f=m['full']; p=m['post2020']; t=m['teny']
    if not f or not p or not t: return -999
    worst=max(f['dd'],p['dd'],t['dd'])
    return f['ann']*6+p['ann']*2+t['ann']*2+f['sharpe']*.25+f['calmar']*.15-worst*4-max(f['dd']-.10,0)*12-max(.075-f['ann'],0)*8

def base_cfg():
    return dict(name='CURRENT_双金丝雀动量防守',lookback=240,rebalance=20,ma_filter=220,top=2,max_exp=.95,vol_lb=60,canary=['nasdaq','sp500'],offensive=['nasdaq','sp500','dowjones','csi300','shanghai_composite'],defensive_symbol='gold_cny',lbs=[20,60,120,240],ws=[12,4,2,1],weak_allowed=1,canary_ma=180,asset_ma=220,def_ma=220,canary_thr=0,asset_thr=0,def_thr=0,vol_cap=.45,off_w=.40,ballast=.30,def_only=.20,equal=False,from_first=True,band=.02)

def main():
    dates,prices=align(fetch())
    print('DATA',dates[0],dates[-1],len(dates))
    shared_vols={s:rolling_vol(prices[s],60) for s in ASSETS}
    cfgs=[base_cfg()]
    for reb,top,off,bal,defonly,maxexp,weak,asset_ma,def_ma,volcap in itertools.product(
        [10,15,20,30], [1,2], [.38,.42,.46,.50], [.25,.30,.35], [.15,.20,.25], [.90,.95], [0,1], [180,220], [180,220], [.40,.45]):
        c=base_cfg(); c.update(name=f'canary_rb{reb}_top{top}_off{off}_bal{bal}_def{defonly}_max{maxexp}_weak{weak}_ama{asset_ma}_dma{def_ma}_vc{volcap}',rebalance=reb,top=top,off_w=off,ballast=bal,def_only=defonly,max_exp=maxexp,weak_allowed=weak,asset_ma=asset_ma,def_ma=def_ma,vol_cap=volcap)
        c['_vols']=shared_vols
        cfgs.append(c)
    rows=[]; baseline=None
    for n,cfg in enumerate(cfgs,1):
        vals,w,e=simulate(dates,prices,cfg); m=allm(dates,vals)
        clean_cfg={k:v for k,v in cfg.items() if k!='_vols'}
        row={'name':cfg['name'],'cfg':clean_cfg,'metrics':m,'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'score':0}
        row['score']=score(row)
        if n==1: baseline=row
        f=m['full']
        if f and f['ann']>=0.065 and f['dd']<=0.125: rows.append(row)
        if n%2000==0: print('eval',n,'kept',len(rows),flush=True)
    rows.sort(key=lambda r:(r['metrics']['full']['dd']<=.10,r['score']), reverse=True)
    strict=[r for r in rows if r['metrics']['full']['dd']<=.10]
    by_return=sorted(strict,key=lambda r:r['metrics']['full']['ann'],reverse=True)[:30]
    result={'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'baseline':baseline,'evaluated':len(cfgs),'kept':len(rows),'strict_count':len(strict),'best_return_under10':by_return,'best_score':rows[:40]}
    OUT.write_text(json.dumps(result,ensure_ascii=False,indent=2,default=str))
    print('BASE',baseline['metrics']['full']['ann']*100,baseline['metrics']['full']['dd']*100,baseline['metrics']['post2020']['ann']*100,baseline['metrics']['post2020']['dd']*100,baseline['metrics']['teny']['ann']*100,baseline['metrics']['teny']['dd']*100,baseline['extra'])
    print('WROTE',OUT,'eval',len(cfgs),'kept',len(rows),'strict',len(strict))
    for title,arr in [('UNDER10_RETURN',by_return[:10]),('BEST_SCORE',rows[:10])]:
        print('\n==',title,'==')
        for i,r in enumerate(arr,1):
            f=r['metrics']['full']; p=r['metrics']['post2020']; t=r['metrics']['teny']
            print(i,r['name'],f"full={f['ann']*100:.2f}/{f['dd']*100:.2f} sh={f['sharpe']:.2f}",f"post20={p['ann']*100:.2f}/{p['dd']*100:.2f}",f"ten={t['ann']*100:.2f}/{t['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()})

if __name__=='__main__': main()
