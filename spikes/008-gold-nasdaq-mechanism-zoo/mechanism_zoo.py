#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, math, statistics, datetime as dt
from pathlib import Path
from typing import Callable, Dict, Any

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
OUT=Path('/tmp/atm_gold_nasdaq_mechanism_zoo.json')
START=100000.0; FEE=CORE.FEE; SLIP=CORE.SLIP
HOLDINGS=['nasdaq','gold_cny']
VISIBLE_ALLOWED=set(HOLDINGS)
STRESS={
    '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
    '2011黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
    '2015A股/全球波动':(dt.date(2015,6,1),dt.date(2016,2,29)),
    '2018美股回撤':(dt.date(2018,9,1),dt.date(2019,1,31)),
    '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
    '2022加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
    '2026AI波动':(dt.date(2025,12,1),None),
}
PERIODS={
    'full':(None,None),'post2020':(dt.date(2020,1,1),None),'teny':('TENY',None),
    '2024+':(dt.date(2024,1,1),None),'2002-2012':(dt.date(2002,1,1),dt.date(2012,12,31)),
    '2013-2023':(dt.date(2013,1,1),dt.date(2023,12,31)),
}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'
def clamp(x,a,b): return max(a,min(b,x))
def ma(v,i,n): return None if i-n+1<0 else sum(v[i-n+1:i+1])/n
def mom(v,i,n): return None if i-n<0 or v[i-n]<=0 else v[i]/v[i-n]-1
def above(p,s,i,n):
    m=ma(p[s],i,n); return m is not None and p[s][i]>m
def dd_series(v,i,n):
    if i-n+1<0: return None
    h=max(v[i-n+1:i+1]); return v[i]/h-1 if h else None
def realized_vol(v,i,n=63):
    if i-n<1: return None
    rs=[]
    for j in range(i-n+1,i+1):
        if v[j-1]>0 and v[j]>0: rs.append(v[j]/v[j-1]-1)
    return statistics.stdev(rs)*math.sqrt(252) if len(rs)>2 else None
def comp_mom(v,i):
    parts=[]
    for n in (21,63,126,252):
        m=mom(v,i,n)
        if m is None: return None
        parts.append(m)
    return 12*parts[0]+4*parts[1]+2*parts[2]+parts[3]
def normalize(tw:Dict[str,float], cap=0.95):
    tw={k:max(0.0,float(v)) for k,v in tw.items() if k in HOLDINGS and v>1e-6}
    s=sum(tw.values())
    if s>cap and s>0: tw={k:v*cap/s for k,v in tw.items()}
    return tw

def score_asset(p,s,i):
    c=comp_mom(p[s],i)
    if c is None: return -999
    return c

def positive_12m(p,s,i):
    m=mom(p[s],i,252)
    return m is not None and m>0

def positive_6m(p,s,i):
    m=mom(p[s],i,126)
    return m is not None and m>0

def trade_to(cash,units,p,i,target):
    target=normalize(target,0.98)
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    traded=False
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur>tgt*1.01:
            su=min(units[s],(cur-tgt)/p[s][i])
            if su>0:
                cash += su*p[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; traded=True
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur<tgt*0.99:
            amt=min(cash,tgt-cur)
            if amt>1:
                units[s]+=amt*(1-FEE)/(p[s][i]*(1+SLIP)); cash-=amt; traded=True
    return cash,units,traded

def simulate_target(dates,p,target_fn:Callable,rebalance=20):
    cash=START; units={s:0.0 for s in HOLDINGS}; vals=[]; weights=[]; trades=0; ctx={'peak':START,'state':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in HOLDINGS); ctx['peak']=max(ctx.get('peak',val),val)
        if i>0 and i%rebalance==0:
            sig_i=i-1
            sig_val=cash+sum(units[s]*p[s][sig_i] for s in HOLDINGS)
            sig_w={s:units[s]*p[s][sig_i]/sig_val for s in HOLDINGS}
            ctx['sig_w']=sig_w; ctx['portfolio_dd']=1-val/ctx['peak']
            target=target_fn(dates,p,sig_i,ctx)
            if target is not None:
                cash,units,did=trade_to(cash,units,p,i,target)
                if did: trades+=1
                val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

def simulate_buy_hold(dates,p,init):
    cash=START; units={s:0.0 for s in HOLDINGS}; vals=[]; weights=[]
    cash,units,_=trade_to(cash,units,p,0,init)
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        vals.append(val); weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':len(init),'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

def metrics(dates,vals,start=None,end=None):
    if start=='TENY': start=dates[-1].replace(year=dates[-1].year-10)
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]
    peak=vs[0]; mdd=0; rs=[]
    for a,b in zip(vs,vs[1:]):
        if a>0 and b>0: rs.append(b/a-1)
        peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=(ds[-1]-ds[0]).days/365.25
    ann=(vs[-1]/vs[0])**(1/years)-1
    vol=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=statistics.mean(rs)*252/vol if vol else 0
    return {'start':str(ds[0]),'end':str(ds[-1]),'ann':ann,'dd':mdd,'total':vs[-1]/vs[0]-1,'vol':vol,'sharpe':sh,'calmar':ann/mdd if mdd else 0}

def all_metrics(dates,vals): return {k:metrics(dates,vals,a,b) for k,(a,b) in PERIODS.items()}
def topdds(dates,vals,weights,n=4):
    peak=tr=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr]<vals[peak]*.985: out.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v*100,1) for k,v in w.items()},'cash':round((1-sum(w.values()))*100,1)} for a,b,c,w in out[:n]]

# === Mechanism zoo: one fixed rule set per logic, no parameter grid. ===

def M01_gem_dual_momentum(dates,p,i,ctx):
    # Global-equity-momentum style: absolute momentum gate, then relative winner.
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    pn=positive_12m(p,'nasdaq',i); pg=positive_12m(p,'gold_cny',i)
    if not pn and not pg: return {}
    if pn and (not pg or sn>=sg): return {'nasdaq':0.75}
    return {'gold_cny':0.75}

def M02_absolute_momentum_split(dates,p,i,ctx):
    # Time-series momentum: own each sleeve only if its own trend is positive.
    tw={}
    if positive_12m(p,'nasdaq',i) and above(p,'nasdaq',i,200): tw['nasdaq']=0.40
    if positive_12m(p,'gold_cny',i) and above(p,'gold_cny',i,200): tw['gold_cny']=0.40
    return tw

def M03_core_satellite_relative(dates,p,i,ctx):
    # Permanent gold/Nasdaq core + satellite to the stronger positive trend.
    tw={'nasdaq':0.20,'gold_cny':0.20}
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if sn>sg and positive_6m(p,'nasdaq',i): tw['nasdaq']+=0.35
    elif sg>sn and positive_6m(p,'gold_cny',i): tw['gold_cny']+=0.35
    return tw

def M04_vaa_canary(dates,p,i,ctx):
    # VAA-ish: external canaries decide risk-on/risk-off; holdings remain gold/Nasdaq/cash.
    canary=sum(1 for s in ['sp500','dowjones','csi300','shanghai_composite'] if positive_6m(p,s,i))
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if canary>=3:
        return {'nasdaq':0.65} if sn>=sg else {'gold_cny':0.65}
    if canary==2:
        return {'nasdaq':0.25,'gold_cny':0.25}
    return {'gold_cny':0.35} if positive_6m(p,'gold_cny',i) else {}

def M05_paa_breadth(dates,p,i,ctx):
    # PAA-ish: breadth of bad assets controls total risk budget; top positive sleeves receive risk.
    universe=['sp500','dowjones','csi300','shanghai_composite','nasdaq','gold_cny']
    bad=sum(1 for s in universe if not positive_6m(p,s,i))
    budget=0.75 if bad<=1 else 0.55 if bad<=3 else 0.30 if bad<=4 else 0.0
    candidates=[s for s in HOLDINGS if positive_6m(p,s,i)]
    if not candidates or budget<=0: return {}
    candidates.sort(key=lambda s:score_asset(p,s,i),reverse=True)
    if len(candidates)==1: return {candidates[0]:budget}
    return {candidates[0]:budget*0.65,candidates[1]:budget*0.35}

def M06_dual_trend_following(dates,p,i,ctx):
    # Classic trend following: 200d trend + 12m absolute momentum.
    tn=above(p,'nasdaq',i,200) and positive_12m(p,'nasdaq',i)
    tg=above(p,'gold_cny',i,200) and positive_12m(p,'gold_cny',i)
    if tn and tg: return {'nasdaq':0.35,'gold_cny':0.35}
    if tn: return {'nasdaq':0.65}
    if tg: return {'gold_cny':0.65}
    return {}

def M07_vol_target_trend(dates,p,i,ctx):
    # Trend-following but risk-budgeted: volatile assets get smaller weights.
    tw={}
    for s in HOLDINGS:
        if above(p,s,i,200) and positive_6m(p,s,i):
            rv=realized_vol(p[s],i,63) or 0.25
            tw[s]=clamp(0.09/rv,0.10,0.55)
    return normalize(tw,0.80)

def M08_inverse_vol_all_weather(dates,p,i,ctx):
    # All-weather intuition: if both sleeves are alive, inverse-vol balance; otherwise only the survivor.
    healthy=[s for s in HOLDINGS if positive_6m(p,s,i) or above(p,s,i,200)]
    if not healthy: return {}
    inv={}
    for s in healthy:
        rv=realized_vol(p[s],i,63) or 0.25
        inv[s]=1/rv
    total=sum(inv.values())
    budget=0.70 if len(healthy)==2 else 0.50
    return {s:budget*inv[s]/total for s in inv}

def M09_cppi_floor(dates,p,i,ctx):
    # Portfolio insurance: risk budget grows only when portfolio is above its floor.
    peak=ctx.get('peak',START); sig_w=ctx.get('sig_w',{})
    current_risk=sum(sig_w.values())
    # 85% high-water floor; 4x cushion, capped.
    val_frac=max(0.01,1-ctx.get('portfolio_dd',0))
    floor_frac=0.85
    cushion=max(0,val_frac-floor_frac)
    budget=clamp(4*cushion,0,0.75)
    # allocate cushion risk to stronger positive sleeve(s)
    if budget<=0.05: return {'gold_cny':0.20} if positive_6m(p,'gold_cny',i) else {}
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if sn>=sg and positive_6m(p,'nasdaq',i): return {'nasdaq':budget*0.70,'gold_cny':budget*0.30 if positive_6m(p,'gold_cny',i) else 0}
    if positive_6m(p,'gold_cny',i): return {'gold_cny':budget*0.70,'nasdaq':budget*0.30 if positive_6m(p,'nasdaq',i) else 0}
    return {}

def M10_tipp_lock_in(dates,p,i,ctx):
    # TIPP-ish: after portfolio drawdown, stop adding risk; near highs, hold a core+winner sleeve.
    pdd=ctx.get('portfolio_dd',0)
    if pdd>0.12:
        return {'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {}
    base={'nasdaq':0.25,'gold_cny':0.25}
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if sn>sg and positive_6m(p,'nasdaq',i): base['nasdaq']+=0.20
    elif sg>sn and positive_6m(p,'gold_cny',i): base['gold_cny']+=0.20
    return base

def ratio(p,i): return p['nasdaq'][i]/p['gold_cny'][i] if p['gold_cny'][i]>0 else None
def ratio_ma(p,i,n):
    if i-n+1<0: return None
    xs=[]
    for j in range(i-n+1,i+1):
        r=ratio(p,j)
        if r is None: return None
        xs.append(r)
    return sum(xs)/n

def M11_ratio_regime(dates,p,i,ctx):
    # Nasdaq/gold ratio defines which engine is leading; keep the other as ballast.
    r=ratio(p,i); rm=ratio_ma(p,i,200); r0=ratio(p,i-126) if i>=126 else None
    rr=None if r is None or r0 is None else r/r0-1
    if r is None or rm is None or rr is None: return {'nasdaq':0.25,'gold_cny':0.25}
    if r>rm and rr>0 and above(p,'nasdaq',i,120): return {'nasdaq':0.55,'gold_cny':0.20}
    if r<rm and rr<0 and above(p,'gold_cny',i,120): return {'nasdaq':0.20,'gold_cny':0.55}
    return {'nasdaq':0.25,'gold_cny':0.25}

def M12_momentum_crash_protection(dates,p,i,ctx):
    # Base barbell, but if a sleeve had a blowoff and then rolls over, avoid it for six months.
    state=ctx.setdefault('state',{})
    for s in HOLDINGS:
        state[s]=max(0,state.get(s,0)-1)
        blow=(mom(p[s],i,252) or 0)>0.35 and (mom(p[s],i,21) or 0)<-0.03 and not above(p,s,i,60)
        if blow: state[s]=6
    tw={'nasdaq':0.25,'gold_cny':0.35}
    for s in HOLDINGS:
        if state.get(s,0)>0:
            tw[s]=0.15
    # Rebuild if under cooldown expires and trend is healthy happens automatically via base.
    return tw

def M13_rebalance_harvest_rebuild(dates,p,i,ctx):
    # Mechanism found in 007, included as a benchmark: harvest after blowoff, rebuild base after trend recovery.
    base={'nasdaq':0.25,'gold_cny':0.35}; w=ctx.get('sig_w',{})
    if not w:
        return base
    target=dict(w); changed=False
    for s,b in base.items():
        blow=(mom(p[s],i,252) or 0)>0.35 and (mom(p[s],i,21) or 0)<-0.03
        if w.get(s,b)>0.30 and blow:
            target[s]=0.25; changed=True
    if changed: return target
    for s,b in base.items():
        if w.get(s,0)<b*0.78 and above(p,s,i,180) and (mom(p[s],i,126) or 0)>0.04:
            target[s]=b; changed=True
    return target if changed else None

def M14_four_quadrant_regime(dates,p,i,ctx):
    # Four economic quadrants from equity breadth and gold leadership.
    equity_breadth=sum(1 for s in ['sp500','dowjones','csi300','shanghai_composite'] if positive_6m(p,s,i))
    gold_leads=score_asset(p,'gold_cny',i)>score_asset(p,'nasdaq',i)
    if equity_breadth>=3 and not gold_leads: return {'nasdaq':0.55,'gold_cny':0.20}     # growth
    if equity_breadth>=3 and gold_leads: return {'nasdaq':0.30,'gold_cny':0.35}         # reflation
    if equity_breadth<=1 and gold_leads and positive_6m(p,'gold_cny',i): return {'gold_cny':0.55} # inflation/crisis
    if equity_breadth<=1: return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) else {}          # deflation/cash
    return {'nasdaq':0.25,'gold_cny':0.25}

def norm_level(p,s,i):
    return p[s][i]/p[s][0] if p[s][0] else 1

def virtual_barbell(p,i,wn=0.5,wg=0.5):
    return wn*norm_level(p,'nasdaq',i)+wg*norm_level(p,'gold_cny',i)

def virtual_mom(p,i,n,wn=0.5,wg=0.5):
    if i-n<0: return None
    a=virtual_barbell(p,i,wn,wg); b=virtual_barbell(p,i-n,wn,wg)
    return a/b-1 if b else None

def virtual_ma(p,i,n,wn=0.5,wg=0.5):
    if i-n+1<0: return None
    return sum(virtual_barbell(p,j,wn,wg) for j in range(i-n+1,i+1))/n

def rolling_corr(p,a,b,i,n=126):
    if i-n<1: return None
    ra=[]; rb=[]
    for j in range(i-n+1,i+1):
        ra.append(p[a][j]/p[a][j-1]-1)
        rb.append(p[b][j]/p[b][j-1]-1)
    ma=sum(ra)/len(ra); mb=sum(rb)/len(rb)
    va=sum((x-ma)**2 for x in ra); vb=sum((y-mb)**2 for y in rb)
    if va<=0 or vb<=0: return None
    return sum((x-ma)*(y-mb) for x,y in zip(ra,rb))/(va*vb)**0.5

def M15_synthetic_barbell_taa(dates,p,i,ctx):
    # Treat gold+Nasdaq as one synthetic asset. Own the barbell when the barbell itself trends; otherwise defensive gold/cash.
    vm=virtual_mom(p,i,252,0.5,0.5); vb=virtual_barbell(p,i,0.5,0.5); vma=virtual_ma(p,i,200,0.5,0.5)
    if vm is not None and vma is not None and vm>0 and vb>vma:
        return {'nasdaq':0.35,'gold_cny':0.35}
    if positive_6m(p,'gold_cny',i):
        return {'gold_cny':0.45}
    return {}

def M16_us_leadership_filter(dates,p,i,ctx):
    # Nasdaq only gets large weight when US equity leadership is broad; otherwise gold/cash dominates.
    us_ok=positive_6m(p,'sp500',i) and positive_6m(p,'dowjones',i) and above(p,'nasdaq',i,120)
    china_bad=(not positive_6m(p,'csi300',i)) and (not positive_6m(p,'shanghai_composite',i))
    if us_ok and score_asset(p,'nasdaq',i)>score_asset(p,'gold_cny',i):
        return {'nasdaq':0.60,'gold_cny':0.20}
    if china_bad and positive_6m(p,'gold_cny',i):
        return {'gold_cny':0.50,'nasdaq':0.15}
    return {'nasdaq':0.25,'gold_cny':0.25}

def M17_crash_reversal_ladder(dates,p,i,ctx):
    # Contrarian only after real damage: buy recovery from deep drawdown, not falling knives.
    tw={'nasdaq':0.25,'gold_cny':0.25}
    if (dd_series(p['nasdaq'],i,252) or 0)<-0.25 and (mom(p['nasdaq'],i,21) or -1)>0 and above(p,'nasdaq',i,60):
        tw['nasdaq']=0.55
    if (dd_series(p['gold_cny'],i,252) or 0)<-0.18 and (mom(p['gold_cny'],i,21) or -1)>0 and above(p,'gold_cny',i,60):
        tw['gold_cny']=0.45
    if not above(p,'nasdaq',i,200) and (mom(p['nasdaq'],i,126) or 0)<0: tw['nasdaq']=min(tw['nasdaq'],0.10)
    if not above(p,'gold_cny',i,200) and (mom(p['gold_cny'],i,126) or 0)<0: tw['gold_cny']=min(tw['gold_cny'],0.15)
    return tw

def M18_correlation_regime(dates,p,i,ctx):
    # If gold/Nasdaq diversify each other, hold both; if they move together, follow the leader and keep cash.
    c=rolling_corr(p,'nasdaq','gold_cny',i,126)
    if c is None: return {'nasdaq':0.25,'gold_cny':0.25}
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if c<0 and (positive_6m(p,'nasdaq',i) or positive_6m(p,'gold_cny',i)):
        return {'nasdaq':0.35,'gold_cny':0.35}
    if c>0.35:
        if sn>sg and positive_6m(p,'nasdaq',i): return {'nasdaq':0.60,'gold_cny':0.10}
        if positive_6m(p,'gold_cny',i): return {'gold_cny':0.55,'nasdaq':0.10}
        return {}
    return {'nasdaq':0.25,'gold_cny':0.30 if positive_6m(p,'gold_cny',i) else 0.15}

def M19_virtual_drawdown_budget(dates,p,i,ctx):
    # Risk budget is based on drawdown of the simple gold/Nasdaq barbell, not individual assets.
    if i<252: return {'nasdaq':0.25,'gold_cny':0.25}
    vals=[virtual_barbell(p,j,0.5,0.5) for j in range(i-252,i+1)]
    vdd=vals[-1]/max(vals)-1
    if vdd>-0.06:
        return {'nasdaq':0.35,'gold_cny':0.35}
    if vdd>-0.14:
        return {'nasdaq':0.25,'gold_cny':0.30}
    return {'gold_cny':0.35} if positive_6m(p,'gold_cny',i) else {}

def M20_ratio_extreme_reversal(dates,p,i,ctx):
    # Pair logic: follow ratio trend normally, but when ratio is extreme and rolls over, harvest the crowded side.
    r=ratio(p,i); rm=ratio_ma(p,i,200); r63=ratio(p,i-63) if i>=63 else None
    if r is None or rm is None or r63 is None: return {'nasdaq':0.25,'gold_cny':0.25}
    rr63=r/r63-1
    # Nasdaq crowded vs gold and rolling over: harvest Nasdaq into gold/cash.
    if r>rm*1.25 and rr63<0:
        return {'nasdaq':0.20,'gold_cny':0.40}
    # Gold crowded vs Nasdaq and rolling over: harvest gold into Nasdaq/cash.
    if r<rm*0.80 and rr63>0:
        return {'nasdaq':0.40,'gold_cny':0.20}
    return M11_ratio_regime(dates,p,i,ctx)

def M21_equal_weight_if_uncertain_momentum_if_clear(dates,p,i,ctx):
    # Avoid overconfidence: only concentrate when relative momentum and absolute trends agree; otherwise simple 25/25.
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if abs(sn-sg)<0.20:
        return {'nasdaq':0.25,'gold_cny':0.25}
    if sn>sg and positive_6m(p,'nasdaq',i) and above(p,'nasdaq',i,120):
        return {'nasdaq':0.55,'gold_cny':0.20}
    if sg>sn and positive_6m(p,'gold_cny',i) and above(p,'gold_cny',i,120):
        return {'nasdaq':0.20,'gold_cny':0.55}
    return {'nasdaq':0.25,'gold_cny':0.25}

def barbell_health_state(p,i):
    if i<252: return 'warmup',0.0
    vals=[virtual_barbell(p,j,0.5,0.5) for j in range(i-252,i+1)]
    vdd=vals[-1]/max(vals)-1
    if vdd>-0.06: return 'healthy',vdd
    if vdd>-0.14: return 'bruised',vdd
    return 'broken',vdd

def M22_health_budget_momentum_satellite(dates,p,i,ctx):
    # First decide total risk from the virtual gold/Nasdaq barbell's health, then give a satellite to the stronger sleeve.
    state,vdd=barbell_health_state(p,i)
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if state in ('warmup','healthy'):
        tw={'nasdaq':0.25,'gold_cny':0.25}
        if sn>sg and positive_6m(p,'nasdaq',i): tw['nasdaq']+=0.25
        elif sg>sn and positive_6m(p,'gold_cny',i): tw['gold_cny']+=0.25
        return tw
    if state=='bruised':
        return {'nasdaq':0.25,'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {'nasdaq':0.25}
    return {'gold_cny':0.35} if positive_6m(p,'gold_cny',i) else {}

def M23_health_budget_asymmetric_growth(dates,p,i,ctx):
    # When the combined barbell is healthy, prefer Nasdaq growth but keep gold ballast; when damaged, retreat by state.
    state,vdd=barbell_health_state(p,i)
    if state in ('warmup','healthy'):
        if positive_6m(p,'nasdaq',i) and above(p,'nasdaq',i,120):
            return {'nasdaq':0.45,'gold_cny':0.25}
        return {'nasdaq':0.25,'gold_cny':0.35} if positive_6m(p,'gold_cny',i) else {'nasdaq':0.25,'gold_cny':0.25}
    if state=='bruised':
        return {'nasdaq':0.25,'gold_cny':0.30}
    return {'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {}

def M24_health_budget_safehaven_rotation(dates,p,i,ctx):
    # Healthy barbell: own both. Bruised: keep the asset with better defensive behavior. Broken: cash unless gold is trending.
    state,vdd=barbell_health_state(p,i)
    if state in ('warmup','healthy'):
        return {'nasdaq':0.35,'gold_cny':0.35}
    if state=='bruised':
        if score_asset(p,'gold_cny',i)>score_asset(p,'nasdaq',i) and positive_6m(p,'gold_cny',i):
            return {'gold_cny':0.45,'nasdaq':0.15}
        if positive_6m(p,'nasdaq',i):
            return {'nasdaq':0.35,'gold_cny':0.20}
        return {'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {}
    return {'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {}

def accel_score(p,s,i):
    # Accelerating dual momentum style: recent momentum gets intentionally more weight.
    m1=mom(p[s],i,21); m3=mom(p[s],i,63); m6=mom(p[s],i,126)
    if m1 is None or m3 is None or m6 is None: return -999
    return 6*m1+3*m3+m6

def M25_accelerating_dual_momentum_tempered(dates,p,i,ctx):
    # ADM-inspired, but tempered: never all-in; keep ballast or cash to avoid pure winner-take-most blowups.
    an=accel_score(p,'nasdaq',i); ag=accel_score(p,'gold_cny',i)
    if an<=0 and ag<=0: return {}
    if an>ag and positive_6m(p,'nasdaq',i):
        return {'nasdaq':0.55,'gold_cny':0.15 if positive_6m(p,'gold_cny',i) else 0.0}
    if positive_6m(p,'gold_cny',i):
        return {'gold_cny':0.50,'nasdaq':0.15 if positive_6m(p,'nasdaq',i) else 0.0}
    return {}

def M26_faa_momentum_vol_corr(dates,p,i,ctx):
    # FAA/EAA-inspired: rank by momentum, penalize volatility, reward diversification when corr is low.
    c=rolling_corr(p,'nasdaq','gold_cny',i,126)
    scores={}
    for s in HOLDINGS:
        m=comp_mom(p[s],i)
        rv=realized_vol(p[s],i,63)
        if m is None or rv is None:
            scores[s]=-999
        else:
            # fixed economic score, not optimized: trend reward minus volatility cost.
            scores[s]=m - 0.8*rv
    # If they diversify each other, hold both; if not, favor the higher score.
    if c is not None and c<0 and max(scores.values())>0:
        # more to better score but keep both because negative corr is valuable.
        better=max(scores, key=lambda k: scores[k]); other='gold_cny' if better=='nasdaq' else 'nasdaq'
        return {better:0.42,other:0.28}
    better=max(scores, key=lambda k: scores[k])
    if scores[better]>0:
        other='gold_cny' if better=='nasdaq' else 'nasdaq'
        return {better:0.55,other:0.15 if scores[other]>0 else 0.0}
    return {}

def M27_eaa_elastic_allocation(dates,p,i,ctx):
    # EAA-style elastic weights: positive momentum divided by vol and correlation penalty.
    c=rolling_corr(p,'nasdaq','gold_cny',i,126) or 0
    raw={}
    for s in HOLDINGS:
        m=max(0.0, mom(p[s],i,126) or 0.0)
        rv=realized_vol(p[s],i,63) or 0.25
        corr_penalty=1+max(0,c)
        raw[s]=m/(rv*corr_penalty)
    total=sum(raw.values())
    if total<=0: return {}
    budget=0.75 if c<0.2 else 0.60
    return {s:budget*raw[s]/total for s in HOLDINGS if raw[s]>0}

def M28_harvest_rebuild_health_guard(dates,p,i,ctx):
    # Take the high-return harvest/rebuild idea, but use virtual barbell health as master guard.
    state,vdd=barbell_health_state(p,i)
    w=ctx.get('sig_w',{})
    if state=='broken':
        return {'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {}
    if state=='bruised':
        # Keep a moderate core; don't allow drifted Nasdaq to dominate while the product story is under water.
        return {'nasdaq':min(w.get('nasdaq',0.25),0.30),'gold_cny':0.35 if positive_6m(p,'gold_cny',i) else 0.20}
    return M13_rebalance_harvest_rebuild(dates,p,i,ctx)

def M29_virtual_health_reaccumulation(dates,p,i,ctx):
    # Health-gate strategy with explicit re-accumulation after the barbell recovers above medium trend.
    state,vdd=barbell_health_state(p,i)
    vb=virtual_barbell(p,i,0.5,0.5); vma=virtual_ma(p,i,120,0.5,0.5)
    recovered=(vma is not None and vb>vma and (virtual_mom(p,i,63,0.5,0.5) or 0)>0)
    if state=='healthy' and recovered:
        sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
        if sn>sg: return {'nasdaq':0.45,'gold_cny':0.30}
        return {'nasdaq':0.30,'gold_cny':0.45}
    if state=='bruised' and recovered:
        return {'nasdaq':0.30,'gold_cny':0.35}
    if state=='bruised':
        return {'nasdaq':0.20,'gold_cny':0.30}
    if state=='broken':
        return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) else {}
    return {'nasdaq':0.25,'gold_cny':0.35}

def M30_risk_spread_regime(dates,p,i,ctx):
    # Risk appetite spread: Nasdaq vs gold and Nasdaq vs broad US equity confirm risk-on.
    rg=ratio(p,i); rgma=ratio_ma(p,i,200)
    ns = p['nasdaq'][i]/p['sp500'][i] if p['sp500'][i] else None
    ns0 = p['nasdaq'][i-126]/p['sp500'][i-126] if i>=126 and p['sp500'][i-126] else None
    nq_lead = ns is not None and ns0 is not None and ns/ns0-1>0
    if rg is not None and rgma is not None and rg>rgma and nq_lead and positive_6m(p,'nasdaq',i):
        return {'nasdaq':0.55,'gold_cny':0.20}
    if rg is not None and rgma is not None and rg<rgma and positive_6m(p,'gold_cny',i):
        return {'gold_cny':0.50,'nasdaq':0.15}
    return {'nasdaq':0.25,'gold_cny':0.25}

def M31_volatility_shock_cooldown(dates,p,i,ctx):
    # When either sleeve has a volatility shock and negative short momentum, cool that sleeve for a few months.
    state=ctx.setdefault('state',{})
    tw={'nasdaq':0.30,'gold_cny':0.35}
    for s in HOLDINGS:
        state[s]=max(0,state.get(s,0)-1)
        rv21=realized_vol(p[s],i,21); rv126=realized_vol(p[s],i,126)
        shock=rv21 is not None and rv126 is not None and rv21>rv126*1.8 and (mom(p[s],i,21) or 0)<0
        if shock: state[s]=4
        if state.get(s,0)>0: tw[s]=0.12 if s=='nasdaq' else 0.18
    return tw

def M32_two_layer_health_and_spread(dates,p,i,ctx):
    # Layer 1: virtual barbell health controls total risk. Layer 2: risk spread controls Nasdaq/gold split.
    state,vdd=barbell_health_state(p,i)
    if state=='broken':
        return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) else {}
    budget=0.78 if state=='healthy' else 0.58
    rg=ratio(p,i); rgma=ratio_ma(p,i,200)
    if rg is not None and rgma is not None and rg>rgma and positive_6m(p,'nasdaq',i):
        return {'nasdaq':budget*0.68,'gold_cny':budget*0.32}
    if rg is not None and rgma is not None and rg<rgma and positive_6m(p,'gold_cny',i):
        return {'nasdaq':budget*0.32,'gold_cny':budget*0.68}
    return {'nasdaq':budget*0.50,'gold_cny':budget*0.50}

def M33_health_reaccumulation_plus_satellite(dates,p,i,ctx):
    # Extension of M29: after virtual barbell recovery, add a modest satellite to the leading sleeve.
    state,vdd=barbell_health_state(p,i)
    vb=virtual_barbell(p,i,0.5,0.5); vma=virtual_ma(p,i,120,0.5,0.5)
    recovered=(vma is not None and vb>vma and (virtual_mom(p,i,63,0.5,0.5) or 0)>0)
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    if state=='healthy' and recovered:
        if sn>sg and positive_6m(p,'nasdaq',i): return {'nasdaq':0.50,'gold_cny':0.30}
        if positive_6m(p,'gold_cny',i): return {'nasdaq':0.30,'gold_cny':0.50}
        return {'nasdaq':0.35,'gold_cny':0.35}
    if state=='bruised' and recovered:
        if sn>sg and positive_6m(p,'nasdaq',i): return {'nasdaq':0.38,'gold_cny':0.30}
        return {'nasdaq':0.25,'gold_cny':0.38}
    if state=='bruised': return {'nasdaq':0.20,'gold_cny':0.30}
    if state=='broken': return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) else {}
    return {'nasdaq':0.25,'gold_cny':0.35}

def M34_health_recovery_with_vol_cap(dates,p,i,ctx):
    # Same recovery concept, but if current volatility is elevated, scale down the satellite instead of exiting entirely.
    state,vdd=barbell_health_state(p,i)
    vb=virtual_barbell(p,i,0.5,0.5); vma=virtual_ma(p,i,120,0.5,0.5)
    recovered=(vma is not None and vb>vma and (virtual_mom(p,i,63,0.5,0.5) or 0)>0)
    sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
    nq_vol=realized_vol(p['nasdaq'],i,63) or 0.25
    high_vol=nq_vol>0.28
    if state=='healthy' and recovered:
        if sn>sg and positive_6m(p,'nasdaq',i):
            return {'nasdaq':0.42 if high_vol else 0.52,'gold_cny':0.30}
        return {'nasdaq':0.30,'gold_cny':0.48 if positive_6m(p,'gold_cny',i) else 0.30}
    if state=='bruised' and recovered: return {'nasdaq':0.30,'gold_cny':0.35}
    if state=='bruised': return {'nasdaq':0.20,'gold_cny':0.30}
    if state=='broken': return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) else {}
    return {'nasdaq':0.25,'gold_cny':0.35}

def M35_health_phase_three_bucket(dates,p,i,ctx):
    # Three buckets: core barbell, recovery satellite, and cash buffer. Satellite exists only after health recovery.
    state,vdd=barbell_health_state(p,i)
    vma=virtual_ma(p,i,120,0.5,0.5)
    recovered=(vma is not None and virtual_barbell(p,i,0.5,0.5)>vma)
    tw={'nasdaq':0.25,'gold_cny':0.25}
    if state=='healthy' and recovered:
        if accel_score(p,'nasdaq',i)>accel_score(p,'gold_cny',i) and positive_6m(p,'nasdaq',i): tw['nasdaq']+=0.28
        elif positive_6m(p,'gold_cny',i): tw['gold_cny']+=0.28
        return tw
    if state=='bruised':
        return {'nasdaq':0.22,'gold_cny':0.30}
    if state=='broken':
        return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) else {}
    return tw

def M36_asset_specific_health_matrix(dates,p,i,ctx):
    # Separate each sleeve's health instead of only combined health; combined health caps total exposure.
    state,vdd=barbell_health_state(p,i)
    cap=0.82 if state=='healthy' else 0.60 if state=='bruised' else 0.30
    tw={}
    for s in HOLDINGS:
        own_ok=above(p,s,i,160) and positive_6m(p,s,i)
        own_recover=(dd_series(p[s],i,252) or 0)<-0.12 and (mom(p[s],i,63) or 0)>0.05
        if own_ok: tw[s]=0.35
        elif own_recover: tw[s]=0.25
    if not tw and positive_6m(p,'gold_cny',i): tw={'gold_cny':0.25}
    return normalize(tw,cap)

def M37_equity_curve_surf_baseline(dates,p,i,ctx):
    # Surfing the equity curve: use the virtual 25/25 buy-hold equity curve trend to switch between aggressive and defensive barbell.
    vb=virtual_barbell(p,i,0.5,0.5); vma_fast=virtual_ma(p,i,80,0.5,0.5); vma_slow=virtual_ma(p,i,200,0.5,0.5)
    if vma_fast is None or vma_slow is None: return {'nasdaq':0.25,'gold_cny':0.25}
    if vb>vma_fast>vma_slow:
        return {'nasdaq':0.45,'gold_cny':0.35}
    if vb>vma_slow:
        return {'nasdaq':0.30,'gold_cny':0.35}
    return {'gold_cny':0.30} if positive_6m(p,'gold_cny',i) else {}

def M38_gold_shock_absorber_nasdaq_engine(dates,p,i,ctx):
    # Product story: Nasdaq is engine only when the combined barbell and US breadth are healthy; gold absorbs shocks unless it is in blowoff rollover.
    state,vdd=barbell_health_state(p,i)
    us_ok=positive_6m(p,'sp500',i) and positive_6m(p,'dowjones',i)
    gold_blow=(mom(p['gold_cny'],i,252) or 0)>0.35 and (mom(p['gold_cny'],i,21) or 0)<-0.03
    if state=='healthy' and us_ok and positive_6m(p,'nasdaq',i):
        return {'nasdaq':0.50,'gold_cny':0.25 if not gold_blow else 0.15}
    if state=='healthy':
        return {'nasdaq':0.25,'gold_cny':0.40 if not gold_blow and positive_6m(p,'gold_cny',i) else 0.25}
    if state=='bruised':
        return {'nasdaq':0.20,'gold_cny':0.35 if not gold_blow and positive_6m(p,'gold_cny',i) else 0.20}
    return {'gold_cny':0.25} if positive_6m(p,'gold_cny',i) and not gold_blow else {}

def run():
    dates,p=CORE.align(CORE.fetch())
    strategies=[
        ('BH_25_25_buyhold', 'true buy-and-hold 25N/25G/50C baseline', None, {'nasdaq':0.25,'gold_cny':0.25}),
        ('BH_25_35_buyhold', 'true buy-and-hold 25N/35G/40C baseline', None, {'nasdaq':0.25,'gold_cny':0.35}),
        ('M01_GEM_dual_momentum', 'absolute momentum gate then relative winner', M01_gem_dual_momentum, None),
        ('M02_absolute_momentum_split', 'own each sleeve only when its own trend is positive', M02_absolute_momentum_split, None),
        ('M03_core_satellite_relative', 'permanent core plus satellite to stronger positive sleeve', M03_core_satellite_relative, None),
        ('M04_VAA_canary', 'external equity canaries decide risk-on/risk-off', M04_vaa_canary, None),
        ('M05_PAA_breadth', 'bad-asset breadth controls total risk budget', M05_paa_breadth, None),
        ('M06_dual_trend_following', '200d trend plus 12m absolute momentum', M06_dual_trend_following, None),
        ('M07_vol_target_trend', 'trend following with volatility target sizing', M07_vol_target_trend, None),
        ('M08_inverse_vol_all_weather', 'inverse-vol gold/Nasdaq balance when healthy', M08_inverse_vol_all_weather, None),
        ('M09_CPPI_floor', 'portfolio insurance floor/cushion risk budget', M09_cppi_floor, None),
        ('M10_TIPP_lock_in', 'drawdown lock-in guard plus core/winner near highs', M10_tipp_lock_in, None),
        ('M11_ratio_regime', 'Nasdaq/gold ratio regime rotation', M11_ratio_regime, None),
        ('M12_momentum_crash_protection', 'base barbell plus sleeve cooldown after blowoff rollover', M12_momentum_crash_protection, None),
        ('M13_harvest_rebuild', 'barbell drift: blowoff harvest then trend rebuild', M13_rebalance_harvest_rebuild, None),
        ('M14_four_quadrant_regime', 'equity breadth × gold leadership state machine', M14_four_quadrant_regime, None),
        ('M15_synthetic_barbell_taa', 'time the gold/Nasdaq barbell as one synthetic asset', M15_synthetic_barbell_taa, None),
        ('M16_us_leadership_filter', 'Nasdaq weight requires broad US equity leadership', M16_us_leadership_filter, None),
        ('M17_crash_reversal_ladder', 'buy recovery after deep drawdown, cut broken trends', M17_crash_reversal_ladder, None),
        ('M18_correlation_regime', 'hold both when diversifying, follow leader when correlated', M18_correlation_regime, None),
        ('M19_virtual_drawdown_budget', 'risk budget from drawdown of virtual gold/Nasdaq barbell', M19_virtual_drawdown_budget, None),
        ('M20_ratio_extreme_reversal', 'ratio trend with extreme-crowding reversal harvest', M20_ratio_extreme_reversal, None),
        ('M21_clear_momentum_or_equal_weight', 'concentrate only when momentum is clear, otherwise 25/25', M21_equal_weight_if_uncertain_momentum_if_clear, None),
        ('M22_health_budget_momentum_satellite', 'virtual barbell health gate plus momentum satellite', M22_health_budget_momentum_satellite, None),
        ('M23_health_budget_asymmetric_growth', 'barbell health gate with Nasdaq growth bias', M23_health_budget_asymmetric_growth, None),
        ('M24_health_budget_safehaven_rotation', 'barbell health gate plus safe-haven rotation', M24_health_budget_safehaven_rotation, None),
        ('M25_accelerating_dual_momentum_tempered', 'accelerating dual momentum, but tempered with ballast', M25_accelerating_dual_momentum_tempered, None),
        ('M26_faa_momentum_vol_corr', 'FAA-style momentum minus volatility plus correlation regime', M26_faa_momentum_vol_corr, None),
        ('M27_eaa_elastic_allocation', 'EAA-style positive momentum over vol and corr penalty', M27_eaa_elastic_allocation, None),
        ('M28_harvest_rebuild_health_guard', 'harvest/rebuild with virtual barbell health master guard', M28_harvest_rebuild_health_guard, None),
        ('M29_virtual_health_reaccumulation', 'barbell health gate with explicit recovery re-accumulation', M29_virtual_health_reaccumulation, None),
        ('M30_risk_spread_regime', 'Nasdaq/gold and Nasdaq/SP500 risk appetite spread', M30_risk_spread_regime, None),
        ('M31_volatility_shock_cooldown', 'cool sleeves after volatility shock plus negative momentum', M31_volatility_shock_cooldown, None),
        ('M32_two_layer_health_and_spread', 'two-layer health gate plus risk-spread split', M32_two_layer_health_and_spread, None),
        ('M33_health_reaccumulation_plus_satellite', 'health recovery then modest satellite to leading sleeve', M33_health_reaccumulation_plus_satellite, None),
        ('M34_health_recovery_with_vol_cap', 'health recovery satellite scaled by volatility', M34_health_recovery_with_vol_cap, None),
        ('M35_health_phase_three_bucket', 'core barbell + recovery satellite + cash buffer', M35_health_phase_three_bucket, None),
        ('M36_asset_specific_health_matrix', 'combined health cap plus separate sleeve recovery states', M36_asset_specific_health_matrix, None),
        ('M37_equity_curve_surf_baseline', 'surf the virtual barbell equity curve trend', M37_equity_curve_surf_baseline, None),
        ('M38_gold_shock_absorber_nasdaq_engine', 'Nasdaq engine gated by health/US breadth, gold shock absorber', M38_gold_shock_absorber_nasdaq_engine, None),
    ]
    rows=[]
    for name,desc,fn,bh in strategies:
        if bh is not None: vals,w,e=simulate_buy_hold(dates,p,bh)
        else: vals,w,e=simulate_target(dates,p,fn,rebalance=20)
        bad=[s for ww in w for s in ww if s not in VISIBLE_ALLOWED]
        assert not bad, bad[:5]
        row={'name':name,'description':desc,'metrics':all_metrics(dates,vals),'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    base=next(r for r in rows if r['name']=='BH_25_25_buyhold')
    print('BASE BH_25_25',pct(base['metrics']['full']['ann']),pct(base['metrics']['full']['dd']))
    for r in sorted(rows,key=lambda r:r['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; t=r['metrics']['teny']; p20=r['metrics']['post2020']
        print('\n##',r['name'])
        print(r['description'])
        print(f"full ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print(f"post20 {pct(p20['ann'])}/{pct(p20['dd'])} ; teny {pct(t['ann'])}/{pct(t['dd'])}")
        print('latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',pct(r['extra']['cash_pct']),'trades',r['extra']['trades'])
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
if __name__=='__main__': run()
