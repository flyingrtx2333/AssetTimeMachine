#!/usr/bin/env python3
from __future__ import annotations
import json, math, urllib.parse, urllib.request, datetime as dt, random, statistics
from pathlib import Path
from typing import Dict, List, Tuple, Callable, Any

OUT=Path('/tmp/atm_global_assets_12_8_search.json')
SPIKE_DIR=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine/spikes/010-global-assets-12-8')
TARGET_ANN=0.12
TARGET_DD=0.08
START_CASH=100000.0
FEE=0.001
SLIP=0.0005
BASE='https://api.flyingrtx.com/api/v1/money/public/history'

ALL_ASSETS=['gold_cny','nasdaq_composite','sp500','dow_jones','nikkei225','shanghai_composite','shenzhen_component','csi300','chinext','hang_seng']
CORE2002=['gold_cny','nasdaq_composite','sp500','dow_jones','nikkei225','shanghai_composite','shenzhen_component','csi300','hang_seng']
WITH_CHINEXT=ALL_ASSETS[:]
USD_ASSETS={'nasdaq_composite','sp500','dow_jones','nikkei225'}
LABELS={'gold_cny':'黄金','nasdaq_composite':'纳指','sp500':'标普500','dow_jones':'道指','nikkei225':'日经225','shanghai_composite':'上证','shenzhen_component':'深成','csi300':'沪深300','chinext':'创业板','hang_seng':'恒生'}
STRESS={
    '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
    '2011黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
    '2015A股/全球波动':(dt.date(2015,6,1),dt.date(2016,2,29)),
    '2018美股回撤':(dt.date(2018,9,1),dt.date(2019,1,31)),
    '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
    '2022加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
    '2026AI波动':(dt.date(2025,12,1),None),
}

def parse(d): return dt.datetime.strptime(d,'%Y-%m-%d').date()

def fetch_raw():
    url=BASE+'?'+urllib.parse.urlencode({'symbols':','.join(ALL_ASSETS+['usd_per_cny']),'period':'max'})
    data=json.load(urllib.request.urlopen(url,timeout=45))
    return {s['symbol']:s for s in data['series']}

def convert_series(series):
    fx=dict(zip(series['usd_per_cny']['dates'],series['usd_per_cny']['prices']))
    out={}
    for sym in ALL_ASSETS:
        s=series[sym]; pts=[]
        for d,p in zip(s['dates'],s['prices']):
            if p and math.isfinite(p) and p>0:
                if sym in USD_ASSETS:
                    r=fx.get(d)
                    if not r or r<=0: continue
                    p=p/r  # keep app's existing CNY convention for USD-priced assets
                pts.append((parse(d),float(p)))
        pts.sort(); clean=[]
        for d,p in pts:
            if clean and clean[-1][0]==d: clean[-1]=(d,p)
            else: clean.append((d,p))
        out[sym]=clean
    return out

def align(series:Dict[str,List[Tuple[dt.date,float]]], assets:List[str], start:dt.date|None=None):
    maps={s:dict(series[s]) for s in assets}
    dates=sorted(set.intersection(*(set(m.keys()) for m in maps.values())))
    if start: dates=[d for d in dates if d>=start]
    p={s:[maps[s][d] for d in dates] for s in assets}
    return dates,p

def cash_daily(prev_date):
    # same rough demand-deposit convention as existing spikes: if not imported, keep conservative 0.35% annual.
    return 0.0035/365.25

def pct(x): return f'{x*100:.2f}%'
def ma(v,i,n): return None if i-n+1<0 else sum(v[i-n+1:i+1])/n
def mom(v,i,n): return None if i-n<0 or v[i-n]<=0 else v[i]/v[i-n]-1
def above(p,s,i,n):
    m=ma(p[s],i,n); return m is not None and p[s][i]>m
def dd_series(v,i,n):
    if i-n+1<0: return None
    h=max(v[i-n+1:i+1]); return v[i]/h-1 if h else None
def vol(v,i,n=63):
    if i-n<1: return None
    rs=[v[j]/v[j-1]-1 for j in range(i-n+1,i+1) if v[j-1]>0]
    return statistics.stdev(rs)*math.sqrt(252) if len(rs)>2 else None

def comp_mom(p,s,i,lbs=(21,63,126,252), ws=(12,4,2,1)):
    total=0.0
    for n,w in zip(lbs,ws):
        m=mom(p[s],i,n)
        if m is None: return None
        total += w*m
    return total

def normalize(tw,cap=0.98):
    tw={k:max(0.0,float(v)) for k,v in tw.items() if v and v>1e-8}
    s=sum(tw.values())
    if s>cap and s>0: tw={k:v*cap/s for k,v in tw.items()}
    return tw

def trade_to(cash,units,p,i,target,assets,band=0.01):
    target=normalize(target,0.98); total=cash+sum(units[s]*p[s][i] for s in assets); traded=False
    for s in assets:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur>tgt*(1+band):
            su=min(units[s],(cur-tgt)/p[s][i])
            if su>0:
                cash += su*p[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; traded=True
    total=cash+sum(units[s]*p[s][i] for s in assets)
    for s in assets:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur<tgt*(1-band):
            amt=min(cash,tgt-cur)
            if amt>1:
                units[s]+=amt*(1-FEE)/(p[s][i]*(1+SLIP)); cash-=amt; traded=True
    return cash,units,traded

def metrics(dates,vals,start=None,end=None):
    if start=='TENY': start=dates[-1].replace(year=dates[-1].year-10)
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    idx=[i for i,d in enumerate(dates) if d>=start and d<=end]
    if len(idx)<2: return None
    sub=[vals[i] for i in idx]
    yrs=max((dates[idx[-1]]-dates[idx[0]]).days/365.25,1e-9)
    ann=(sub[-1]/sub[0])**(1/yrs)-1 if sub[0]>0 else 0
    peak=sub[0]; dd=0.0; rs=[]
    for a,b in zip(sub,sub[1:]):
        if a>0: rs.append(b/a-1)
        peak=max(peak,b); dd=max(dd,1-b/peak if peak>0 else 0)
    vv=statistics.stdev(rs)*math.sqrt(252) if len(rs)>2 else 0
    sh=(statistics.mean(rs)*252/vv) if vv>0 else 0
    return {'ann':ann,'dd':dd,'total':sub[-1]/sub[0]-1,'vol':vv,'sharpe':sh,'calmar':ann/dd if dd>0 else 0}

def all_metrics(dates,vals):
    return {
        'full':metrics(dates,vals),
        'post2020':metrics(dates,vals,dt.date(2020,1,1)),
        'teny':metrics(dates,vals,'TENY'),
        '2024+':metrics(dates,vals,dt.date(2024,1,1)),
        '2002-2012':metrics(dates,vals,dt.date(2002,1,1),dt.date(2012,12,31)),
        '2013-2023':metrics(dates,vals,dt.date(2013,1,1),dt.date(2023,12,31)),
    }

def topdds(dates,vals,weights,limit=4):
    events=[]; peak_i=0; peak=vals[0]; trough_i=0; trough=vals[0]; in_dd=False
    for i,v in enumerate(vals):
        if v>=peak:
            if in_dd and trough<peak:
                events.append((peak_i,trough_i,1-trough/peak))
            peak=v; peak_i=i; trough=v; trough_i=i; in_dd=False
        elif v<trough:
            trough=v; trough_i=i; in_dd=True
    if in_dd and trough<peak: events.append((peak_i,trough_i,1-trough/peak))
    events=sorted(events,key=lambda x:x[2],reverse=True)[:limit]
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':dd,'weights':{k:round(v*100,1) for k,v in weights[b].items()},'cash':round((1-sum(weights[b].values()))*100,1)} for a,b,dd in events]

def simulate_buy_hold(dates,p,assets,init,band=0.0):
    cash=START_CASH; units={s:0.0 for s in assets}; vals=[]; weights=[]; trades=0
    cash,units,did=trade_to(cash,units,p,0,init,assets,band)
    trades+=1 if did else 0
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in assets)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in assets if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

def simulate(dates,p,assets,fn,rebalance=21,band=0.01):
    cash=START_CASH; units={s:0.0 for s in assets}; vals=[]; weights=[]; trades=0; ctx={'peak':START_CASH,'state':{},'last':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in assets); ctx['peak']=max(ctx.get('peak',val),val)
        if i>252 and i%rebalance==0:
            sig=i-1; ctx['portfolio_dd']=1-val/ctx['peak'] if ctx['peak'] else 0
            sig_val=cash+sum(units[s]*p[s][sig] for s in assets)
            ctx['sig_w']={s:(units[s]*p[s][sig]/sig_val if sig_val>0 else 0) for s in assets}
            target=fn(dates,p,assets,sig,ctx)
            if target is not None:
                cash,units,did=trade_to(cash,units,p,i,target,assets,band)
                if did: trades+=1
                val=cash+sum(units[s]*p[s][i] for s in assets)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in assets if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

# Strategy factories. These are mechanism variants, not reported as robust until slice-tested.
def rank_assets(p,assets,i,lbs=(21,63,126,252),ws=(12,4,2,1),vol_pen=0.0,need_above=120):
    rows=[]
    for s in assets:
        cm=comp_mom(p,s,i,lbs,ws)
        if cm is None: continue
        vv=vol(p[s],i,63) or 0.25
        ok=(mom(p[s],i,126) or -9)>0 and (above(p,s,i,need_above) if need_above else True)
        rows.append((cm-vol_pen*vv,s,ok,cm,vv))
    return sorted(rows,reverse=True)

def strat_top_momentum(k=1,budget=0.98,lbs=(21,63,126,252),ws=(12,4,2,1),vol_pen=0.0,gold_def=True,need_above=120):
    def fn(dates,p,assets,i,ctx):
        ranked=rank_assets(p,assets,i,lbs,ws,vol_pen,need_above)
        good=[r for r in ranked if r[2] and r[0]>0]
        if not good:
            return {'gold_cny':0.45} if gold_def and 'gold_cny' in assets and (mom(p['gold_cny'],i,126) or -9)>0 and above(p,'gold_cny',i,120) else {}
        take=good[:k]
        # score-weighted but capped, so one winner can dominate.
        vals=[max(0.01,r[0]) for r in take]; sm=sum(vals)
        return {s:budget*v/sm for v,(_,s,_,_,_) in zip(vals,take)}
    return fn

def strat_paa(top=2,base_budget=0.98,bad_scale=(1.0,0.75,0.45,0.20,0.0),canary=None):
    def fn(dates,p,assets,i,ctx):
        universe=[s for s in assets if s!='gold_cny']
        bad=sum(1 for s in universe if (mom(p[s],i,126) or -9)<0 or not above(p,s,i,120))
        frac_bad=bad/max(1,len(universe))
        if frac_bad<=0.15: budget=base_budget*bad_scale[0]
        elif frac_bad<=0.35: budget=base_budget*bad_scale[1]
        elif frac_bad<=0.55: budget=base_budget*bad_scale[2]
        elif frac_bad<=0.75: budget=base_budget*bad_scale[3]
        else: budget=base_budget*bad_scale[4]
        if canary:
            can_bad=sum(1 for s in canary if s in assets and ((mom(p[s],i,126) or -9)<0 or not above(p,s,i,120)))
            if can_bad>=len(canary)//2+1: budget=min(budget,0.35)
        ranked=rank_assets(p,assets,i,vol_pen=0.4,need_above=100)
        good=[r for r in ranked if r[2] and r[0]>0]
        if budget<=0.05 or not good:
            return {'gold_cny':0.35} if 'gold_cny' in assets and above(p,'gold_cny',i,120) and (mom(p['gold_cny'],i,63) or 0)>0 else {}
        take=good[:top]; vals=[max(0.01,r[0]) for r in take]; sm=sum(vals)
        return {s:budget*v/sm for v,(_,s,_,_,_) in zip(vals,take)}
    return fn

def strat_global_state_machine():
    def fn(dates,p,assets,i,ctx):
        us_ok=('sp500' in assets and above(p,'sp500',i,160) and (mom(p['sp500'],i,126) or -9)>0) and ('nasdaq_composite' in assets and above(p,'nasdaq_composite',i,120))
        jp_ok='nikkei225' in assets and above(p,'nikkei225',i,120) and (mom(p['nikkei225'],i,63) or -9)>0
        cn_ok=sum(1 for s in ['csi300','shenzhen_component','shanghai_composite','chinext'] if s in assets and above(p,s,i,120) and (mom(p[s],i,63) or -9)>0)>1
        gold_ok='gold_cny' in assets and above(p,'gold_cny',i,120) and (mom(p['gold_cny'],i,63) or -9)>0
        risk_breadth=sum([us_ok,jp_ok,cn_ok])
        if ctx.get('portfolio_dd',0)>0.075:
            return {'gold_cny':0.30} if gold_ok else {}
        if risk_breadth>=2:
            ranked=rank_assets(p,[s for s in assets if s!='gold_cny'],i,vol_pen=0.25,need_above=100)
            good=[r for r in ranked if r[2] and r[0]>0][:2]
            tw={}
            if good:
                tw[good[0][1]]=0.50
                if len(good)>1: tw[good[1][1]]=0.25
            if gold_ok: tw['gold_cny']=0.20
            return normalize(tw,0.95)
        if gold_ok:
            return {'gold_cny':0.55}
        return {}
    return fn

def strat_crisis_alpha_reentry():
    def fn(dates,p,assets,i,ctx):
        # Equity momentum normally, but if global equities break, rotate to gold/cash; reenter on breadth repair.
        eq=[s for s in assets if s!='gold_cny']
        breadth=sum(1 for s in eq if above(p,s,i,120) and (mom(p[s],i,63) or -9)>0)/max(1,len(eq))
        gold_ok='gold_cny' in assets and above(p,'gold_cny',i,100) and (mom(p['gold_cny'],i,63) or -9)>0
        if breadth<0.35 or ctx.get('portfolio_dd',0)>0.075:
            return {'gold_cny':0.60} if gold_ok else {}
        ranked=rank_assets(p,eq,i,lbs=(21,63,126),ws=(8,3,1),vol_pen=0.35,need_above=100)
        good=[r for r in ranked if r[2] and r[0]>0][:2]
        if not good: return {'gold_cny':0.40} if gold_ok else {}
        tw={good[0][1]:0.62}
        if len(good)>1: tw[good[1][1]]=0.22
        if gold_ok: tw['gold_cny']=0.12
        return normalize(tw,0.96)
    return fn

def strat_eaa_like(top=3,budget_hi=0.98,budget_mid=0.65):
    def corr(p,a,b,i,n=126):
        if i-n<1: return 0.0
        ra=[p[a][j]/p[a][j-1]-1 for j in range(i-n+1,i+1)]
        rb=[p[b][j]/p[b][j-1]-1 for j in range(i-n+1,i+1)]
        ma=sum(ra)/len(ra); mb=sum(rb)/len(rb)
        va=sum((x-ma)**2 for x in ra); vb=sum((y-mb)**2 for y in rb)
        return 0.0 if va<=0 or vb<=0 else sum((x-ma)*(y-mb) for x,y in zip(ra,rb))/(va*vb)**0.5
    def fn(dates,p,assets,i,ctx):
        raw={}
        for s in assets:
            m=max(0.0,(mom(p[s],i,63) or 0)*0.6+(mom(p[s],i,126) or 0)*0.4)
            if m<=0 or not above(p,s,i,100): continue
            vv=vol(p[s],i,63) or 0.25
            # penalize crowding with average positive corr to other candidates
            avgc=sum(max(0,corr(p,s,t,i,126)) for t in assets if t!=s)/max(1,len(assets)-1)
            raw[s]=m/(vv*(1+avgc))
        if not raw: return {}
        breadth=len(raw)/len(assets)
        budget=budget_hi if breadth>=0.45 else budget_mid if breadth>=0.25 else 0.35
        ranked=sorted(raw.items(),key=lambda kv:kv[1],reverse=True)[:top]
        sm=sum(v for _,v in ranked)
        return {s:budget*v/sm for s,v in ranked}
    return fn

STRATEGIES=[]
# Fixed mechanism family variants, not all promoted.
for k in [1,2,3]:
    STRATEGIES.append((f'TOP{k}_vaa_fast',strat_top_momentum(k=k,budget=0.98,lbs=(21,63,126,252),ws=(12,4,2,1),vol_pen=0.0),21))
    STRATEGIES.append((f'TOP{k}_vaa_volpen',strat_top_momentum(k=k,budget=0.98,lbs=(21,63,126,252),ws=(12,4,2,1),vol_pen=0.5),21))
    STRATEGIES.append((f'TOP{k}_adm_tempered',strat_top_momentum(k=k,budget=0.95,lbs=(21,63,126),ws=(6,3,1),vol_pen=0.2),21))
for top in [1,2,3]:
    STRATEGIES.append((f'PAA_top{top}',strat_paa(top=top,base_budget=0.98,canary=['nasdaq_composite','sp500','csi300']),21))
    STRATEGIES.append((f'PAA_top{top}_weekly',strat_paa(top=top,base_budget=0.98,canary=['nasdaq_composite','sp500','csi300']),5))
STRATEGIES += [
    ('GLOBAL_STATE_MACHINE',strat_global_state_machine(),21),
    ('GLOBAL_STATE_MACHINE_weekly',strat_global_state_machine(),5),
    ('CRISIS_ALPHA_REENTRY',strat_crisis_alpha_reentry(),21),
    ('CRISIS_ALPHA_REENTRY_weekly',strat_crisis_alpha_reentry(),5),
    ('EAA_like_top2',strat_eaa_like(top=2),21),
    ('EAA_like_top3',strat_eaa_like(top=3),21),
    ('EAA_like_top2_weekly',strat_eaa_like(top=2),5),
]

def run_branch(name,assets,start,series=None):
    if series is None:
        raw=fetch_raw(); series=convert_series(raw)
    dates,p=align(series,assets,start)
    rows=[]
    # static asset baselines
    for s in assets:
        vals,w,e=simulate_buy_hold(dates,p,assets,{s:0.98})
        rows.append({'branch':name,'name':f'BH_{s}','description':f'Buy/hold {s}','rebalance':None,'metrics':all_metrics(dates,vals),'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w)})
    for sname,fn,reb in STRATEGIES:
        vals,w,e=simulate(dates,p,assets,fn,rebalance=reb,band=0.02)
        rows.append({'branch':name,'name':sname,'description':'global expanded assets fixed mechanism','rebalance':reb,'metrics':all_metrics(dates,vals),'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w)})
    return {'name':name,'assets':assets,'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows}

def main():
    raw=fetch_raw(); series=convert_series(raw)
    branches=[
        run_branch('core2002_no_chinext',CORE2002,dt.date(2002,1,4),series),
        run_branch('with_chinext_2010',WITH_CHINEXT,dt.date(2010,6,1),series),
    ]
    OUT.write_text(json.dumps({'target':{'ann':TARGET_ANN,'dd':TARGET_DD},'branches':branches},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT)
    for br in branches:
        print('\n##',br['name'],br['coverage'],'assets',','.join(br['assets']))
        rows=br['rows']
        passed=[]
        for r in sorted(rows,key=lambda x:x['metrics']['full']['ann'],reverse=True)[:25]:
            m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']
            mark='PASS' if m and m['ann']>=TARGET_ANN and m['dd']<=TARGET_DD else 'FAIL'
            if mark=='PASS': passed.append(r)
            print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}" if p20 else 'post20=n/a',f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}" if ten else 'teny=n/a','latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'])
        print('PASS_COUNT',sum(1 for r in rows if r['metrics']['full'] and r['metrics']['full']['ann']>=TARGET_ANN and r['metrics']['full']['dd']<=TARGET_DD))
        print('UNDER_8DD_TOP')
        for r in sorted([r for r in rows if r['metrics']['full'] and r['metrics']['full']['dd']<=TARGET_DD],key=lambda x:x['metrics']['full']['ann'],reverse=True)[:10]:
            m=r['metrics']['full']; print(r['name'],f"{m['ann']*100:.2f}/{m['dd']*100:.2f}")

if __name__=='__main__': main()
