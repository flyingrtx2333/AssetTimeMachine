#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, urllib.request, urllib.parse, bisect, math, statistics
from pathlib import Path

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
API='https://api.flyingrtx.com/api/v1/money/public/history'
FUNDS=['OSTIX','VFISX','RPHYX']
OUT=Path('/tmp/atm_core_cashplus_defense.json')
STRESS={'2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),'2011欧债/黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),'2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),'2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),'2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),'2026AI波动':(dt.date(2025,12,1),None)}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

def fetch_api(symbols):
    q=urllib.parse.urlencode({'symbols':','.join(symbols),'period':'all'})
    return json.load(urllib.request.urlopen(API+'?'+q,timeout=90))['series']

def parse_api(ser):
    rows=[]
    for ds,p in zip(ser['dates'],ser['prices']):
        if p and p>0: rows.append((dt.date.fromisoformat(ds[:10]),float(p)))
    return rows

def fetch_yahoo(sym):
    cache=Path(f'/tmp/atm_cashplus_{sym}.json')
    if cache.exists(): return [(dt.date.fromisoformat(d),float(p)) for d,p in json.loads(cache.read_text())]
    start=int(dt.datetime(1999,1,1,tzinfo=dt.timezone.utc).timestamp()); end=int(dt.datetime(2026,6,21,tzinfo=dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    data=json.load(urllib.request.urlopen(req,timeout=60)); r=data['chart']['result'][0]
    ts=r.get('timestamp') or []; q=r['indicators']['quote'][0]; arr=r['indicators'].get('adjclose',[{}])[0].get('adjclose') or q.get('close') or []
    rows=[]
    for t,p in zip(ts,arr):
        if p and math.isfinite(float(p)) and p>0: rows.append((dt.datetime.fromtimestamp(t,dt.UTC).date(),float(p)))
    cache.write_text(json.dumps([(d.isoformat(),p) for d,p in rows])); return rows

def load_funds():
    fx=parse_api(fetch_api(['usd_per_cny'])[0]); fxd=[d for d,_ in fx]; fxv=[p for _,p in fx]
    def usd_cny(day):
        j=bisect.bisect_right(fxd,day)-1
        if j<0: return None
        f=fxv[j]; return 1/f if f<1 else f
    pts={}
    for s in FUNDS:
        rows=[]
        for d,p in fetch_yahoo(s):
            u=usd_cny(d)
            if u: rows.append((d,p*u))
        pts[s]=rows
    return pts

def ma(vals,i,n):
    if i-n+1<0: return None
    win=vals[i-n+1:i+1]
    if any(x is None for x in win): return None
    return sum(win)/n

def mom(vals,i,n):
    if i-n<0 or vals[i] is None or vals[i-n] is None or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def dd(vals,i,n):
    if i-n+1<0 or vals[i] is None: return None
    win=vals[i-n+1:i+1]
    if any(x is None for x in win): return None
    h=max(win); return vals[i]/h-1 if h>0 else None

def choose_cashplus(prices,i):
    # Cash-plus rule: use OSTIX only when its own NAV trend is healthy; otherwise use VFISX.
    # RPHYX is available only from 2010; use it only as post-2010 ultra-short fallback if VFISX is breaking.
    if 'OSTIX' in prices and prices['OSTIX'][i] is not None:
        o=prices['OSTIX']
        if ma(o,i,120) is not None and o[i]>ma(o,i,120) and (dd(o,i,60) or 0)>-0.025 and (mom(o,i,60) or -9)>-0.005:
            return 'OSTIX'
    if 'RPHYX' in prices and prices['RPHYX'][i] is not None:
        r=prices['RPHYX']
        if ma(r,i,60) is not None and r[i]>ma(r,i,60) and (dd(r,i,60) or 0)>-0.015:
            return 'RPHYX'
    return 'VFISX'

def align_all():
    core_series=CORE.fetch(); core_dates,core_prices=CORE.align(core_series)
    fund_pts=load_funds()
    all_dates=sorted(set(core_dates) | set(d for rows in fund_pts.values() for d,_ in rows))
    # forward-fill fund prices, require core date and at least OSTIX/VFISX after OSTIX start for main comparison
    fund_idx={s:0 for s in FUNDS}; latest={}; latest_d={}; fund_prices={s:[] for s in FUNDS}; dates=[]; cprices={s:[] for s in CORE.ASSETS}
    core_i={d:i for i,d in enumerate(core_dates)}
    for day in all_dates:
        for s in FUNDS:
            rows=fund_pts[s]; j=fund_idx[s]
            while j<len(rows) and rows[j][0]<=day:
                latest[s]=rows[j][1]; latest_d[s]=rows[j][0]; j+=1
            fund_idx[s]=j
        if day not in core_i: continue
        if not (('VFISX' in latest) and (day-latest_d['VFISX']).days<=10): continue
        dates.append(day)
        ci=core_i[day]
        for s in CORE.ASSETS: cprices[s].append(core_prices[s][ci])
        for s in FUNDS:
            if s in latest and (day-latest_d[s]).days<=10:
                fund_prices[s].append(latest[s])
            else:
                fund_prices[s].append(None)
    return dates,cprices,fund_prices

def simulate_core_cashplus(dates,cprices,fprices,mode):
    cfg=CORE.base_cfg(); vols={s:CORE.rolling_vol(cprices[s],cfg['vol_lb']) for s in CORE.ASSETS}
    cash=CORE.START; core_units={s:0.0 for s in CORE.ASSETS}; fund_units={s:0.0 for s in FUNDS}; vals=[]; weights=[]; trades=0; last=-10**9
    warmup=max(cfg['lookback'],cfg['ma_filter'],cfg['vol_lb'],max(cfg['lbs']),cfg['canary_ma'],cfg['asset_ma'],cfg['def_ma'])+1
    def pv(i): return cash+sum(core_units[s]*cprices[s][i] for s in CORE.ASSETS)+sum(fund_units[s]*(fprices[s][i] or 0) for s in FUNDS)
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        if i>0 and i-last>=cfg['rebalance']:
            sig=i-1; pre=pv(i)
            tw=CORE.target(sig,cprices,vols,cfg) if sig>=warmup-1 else {}
            # Cash-plus allocation uses otherwise idle capital. Keep 2% true cash for friction.
            idle=max(0.0,0.98-sum(tw.values()))
            cashplus_fraction=1.0
            if mode=='cashplus_half': cashplus_fraction=0.50
            if mode=='cashplus_third': cashplus_fraction=0.33
            idle_to_fund=idle*cashplus_fraction
            fw={s:0.0 for s in FUNDS}
            if mode=='ostix_static':
                fw['OSTIX' if fprices['OSTIX'][sig] is not None else 'VFISX']=idle_to_fund
            elif mode in ('cashplus_guarded','cashplus_half','cashplus_third'):
                fw[choose_cashplus(fprices,sig)]=idle_to_fund
            elif mode=='vfisx_only': fw['VFISX']=idle_to_fund
            # sell core/funds to targets
            total=pre
            for s in CORE.ASSETS:
                cur=core_units[s]*cprices[s][i]; tgt=total*tw.get(s,0.0)
                if cur>tgt*1.02:
                    su=min(core_units[s],(cur-tgt)/cprices[s][i])
                    if su>0: cash+=su*cprices[s][i]*(1-CORE.SLIP)*(1-CORE.FEE); core_units[s]-=su; trades+=1
            for s in FUNDS:
                p=fprices[s][i]
                if not p: continue
                cur=fund_units[s]*p; tgt=total*fw.get(s,0.0)
                if cur>tgt*1.02:
                    su=min(fund_units[s],(cur-tgt)/p)
                    if su>0: cash+=su*p*(1-CORE.SLIP)*(1-CORE.FEE); fund_units[s]-=su; trades+=1
            total=pv(i)
            for s in CORE.ASSETS:
                cur=core_units[s]*cprices[s][i]; tgt=total*tw.get(s,0.0)
                if cur<tgt*.98:
                    amt=min(cash,tgt-cur)
                    if amt>1: core_units[s]+=amt*(1-CORE.FEE)/(cprices[s][i]*(1+CORE.SLIP)); cash-=amt; trades+=1
            total=pv(i)
            for s in FUNDS:
                p=fprices[s][i]
                if not p: continue
                cur=fund_units[s]*p; tgt=total*fw.get(s,0.0)
                if cur<tgt*.98:
                    amt=min(cash,tgt-cur)
                    if amt>1: fund_units[s]+=amt*(1-CORE.FEE)/(p*(1+CORE.SLIP)); cash-=amt; trades+=1
            last=i
        v=pv(i); vals.append(v)
        w={}
        for s in CORE.ASSETS:
            x=core_units[s]*cprices[s][i]/v
            if x>.0001: w[s]=x
        for s in FUNDS:
            p=fprices[s][i]
            x=fund_units[s]*(p or 0)/v
            if x>.0001: w[s]=x
        weights.append(w)
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0,1-sum(weights[-1].values()))}

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
    peak=tr=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr]<vals[peak]*.985: out.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v*100,1) for k,v in w.items()}} for a,b,c,w in out[:n]]

def main():
    dates,cprices,fprices=align_all(); rows=[]
    # baseline core on same dates for honest comparison
    core_vals,core_w,core_e=CORE.simulate(dates,cprices,CORE.base_cfg())
    base={'name':'BASE_CORE_same_OSTIX_window','metrics':{},'extra':core_e,'top_dd':episodes(dates,core_vals,core_w)}
    for k,(a,b) in {'full':(None,None),'post2020':(dt.date(2020,1,1),None),'teny':(dates[-1].replace(year=dates[-1].year-10),None),'2024+':(dt.date(2024,1,1),None),'2002-2012':(dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':(dt.date(2013,1,1),dt.date(2023,12,31))}.items(): base['metrics'][k]=metrics(dates,core_vals,a,b)
    rows.append(base)
    for mode in ['vfisx_only','ostix_static','cashplus_guarded','cashplus_half','cashplus_third']:
        vals,w,e=simulate_core_cashplus(dates,cprices,fprices,mode)
        row={'name':f'S_core_idle_to_{mode}','metrics':{},'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':episodes(dates,vals,w)}
        for k,(a,b) in {'full':(None,None),'post2020':(dt.date(2020,1,1),None),'teny':(dates[-1].replace(year=dates[-1].year-10),None),'2024+':(dt.date(2024,1,1),None),'2002-2012':(dt.date(2002,1,1),dt.date(2012,12,31)),'2013-2023':(dt.date(2013,1,1),dt.date(2023,12,31))}.items(): row['metrics'][k]=metrics(dates,vals,a,b)
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    for r in rows:
        print('\n##',r['name'])
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]; print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print('latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',pct(r['extra'].get('cash_pct',0)),'trades',r['extra'].get('trades'))
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
