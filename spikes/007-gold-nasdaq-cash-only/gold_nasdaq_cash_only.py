#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, math, statistics
from pathlib import Path
from typing import Callable

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('coremod', ROOT/'spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py')
CORE=importlib.util.module_from_spec(spec); sys.modules['coremod']=CORE; spec.loader.exec_module(CORE)  # type: ignore
OUT=Path('/tmp/atm_gold_nasdaq_cash_only.json')
SPIKE_DIR=ROOT/'spikes/007-gold-nasdaq-cash-only'
HOLDINGS=['nasdaq','gold_cny']
VISIBLE_ALLOWED=set(HOLDINGS)
START=100000.0
FEE=CORE.FEE
SLIP=CORE.SLIP
STRESS={
    '2008金融危机':(dt.date(2007,10,1),dt.date(2009,3,31)),
    '2011黄金拐点':(dt.date(2011,1,1),dt.date(2013,12,31)),
    '2015A股冲击':(dt.date(2015,6,1),dt.date(2016,2,29)),
    '2018美股回撤':(dt.date(2018,1,1),dt.date(2018,12,31)),
    '2020疫情':(dt.date(2020,2,1),dt.date(2020,4,30)),
    '2022通胀加息':(dt.date(2022,1,1),dt.date(2022,12,31)),
    '2026AI波动':(dt.date(2025,12,1),None),
}
PERIODS={
    'full':(None,None),
    'post2020':(dt.date(2020,1,1),None),
    'teny':('TENY',None),
    '2024+':(dt.date(2024,1,1),None),
    '2002-2012':(dt.date(2002,1,1),dt.date(2012,12,31)),
    '2013-2023':(dt.date(2013,1,1),dt.date(2023,12,31)),
}

def pct(x): return 'n/a' if x is None else f'{x*100:.2f}%'

def ma(vals,i,n):
    if i-n+1<0: return None
    return sum(vals[i-n+1:i+1])/n

def mom(vals,i,n):
    if i-n<0 or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def dd(vals,i,n):
    if i-n+1<0: return None
    h=max(vals[i-n+1:i+1]); return vals[i]/h-1 if h>0 else None

def comp_mom(vals,i):
    lbs=[21,63,126,252]; ws=[8,4,2,1]
    out=0.0
    for lb,w in zip(lbs,ws):
        m=mom(vals,i,lb)
        if m is None: return None
        out += w*m
    return out/sum(ws)

def above(vals,i,n):
    m=ma(vals,i,n)
    return m is not None and vals[i]>m

def us_risk_ok(p,i):
    # Signal only: broad US risk regime. Not a holding.
    return above(p['sp500'],i,200) and (mom(p['sp500'],i,63) or -9)>-0.02 and (dd(p['nasdaq'],i,63) or -9)>-0.14

def gold_ok(p,i):
    return above(p['gold_cny'],i,180) and (mom(p['gold_cny'],i,63) or -9)>-0.015

def gold_blowoff_risk(p,i):
    # If gold had a sharp 1Y run and has already cracked below 60d trend, don't rely on it as defense.
    return (mom(p['gold_cny'],i,252) or 0)>0.32 and not above(p['gold_cny'],i,60)

def nq_ok(p,i):
    return above(p['nasdaq'],i,180) and (mom(p['nasdaq'],i,63) or -9)>-0.02 and us_risk_ok(p,i)

def normalize(tw):
    clean={k:max(0.0,v) for k,v in tw.items() if k in VISIBLE_ALLOWED and v>0.0001}
    gross=sum(clean.values())
    if gross>0.98:
        clean={k:v*0.98/gross for k,v in clean.items()}
    return clean

# Strategy target functions: signal i -> target weights in visible holdings only.
def S1_dual_momentum_router(dates,p,i):
    # Economic idea: hold the single visible asset with stronger long+short momentum; cash if neither trend is positive.
    sn=comp_mom(p['nasdaq'],i); sg=comp_mom(p['gold_cny'],i)
    if sn is None or sg is None: return {}
    n_ok=nq_ok(p,i) and sn>0
    g_ok=gold_ok(p,i) and sg>0 and not gold_blowoff_risk(p,i)
    if n_ok and g_ok:
        # If both engines work, keep a small barbell rather than over-rotating.
        if sn>=sg*1.15: return normalize({'nasdaq':0.72,'gold_cny':0.18})
        if sg>=sn*1.15: return normalize({'gold_cny':0.72,'nasdaq':0.18})
        return normalize({'nasdaq':0.48,'gold_cny':0.42})
    if n_ok: return normalize({'nasdaq':0.86})
    if g_ok: return normalize({'gold_cny':0.82})
    return {}

def S2_gold_nasdaq_state_machine(dates,p,i):
    # Economic idea: Nasdaq is growth engine; gold is inflation/crisis engine; cash when each engine's own state is bad.
    n=nq_ok(p,i); g=gold_ok(p,i) and not gold_blowoff_risk(p,i)
    n_m=mom(p['nasdaq'],i,126) or -9
    g_m=mom(p['gold_cny'],i,126) or -9
    if n and g:
        if n_m>g_m+0.04: return normalize({'nasdaq':0.62,'gold_cny':0.28})
        if g_m>n_m+0.04: return normalize({'nasdaq':0.30,'gold_cny':0.60})
        return normalize({'nasdaq':0.50,'gold_cny':0.40})
    if n:
        return normalize({'nasdaq':0.72,'gold_cny':0.10 if above(p['gold_cny'],i,360) else 0.0})
    if g:
        return normalize({'gold_cny':0.72})
    return {}

def S3_gold_crisis_bridge(dates,p,i):
    # Economic idea: Nasdaq participates only in clean risk-on; gold is bridge in risk-off if gold itself confirms.
    crisis=(not us_risk_ok(p,i)) or ((dd(p['nasdaq'],i,63) or 0)<-0.16)
    g=gold_ok(p,i) and not gold_blowoff_risk(p,i)
    n=nq_ok(p,i)
    if crisis:
        return normalize({'gold_cny':0.78 if g else 0.0})
    if n and g: return normalize({'nasdaq':0.62,'gold_cny':0.28})
    if n: return normalize({'nasdaq':0.78})
    if g: return normalize({'gold_cny':0.60})
    return {}

def S4_balanced_risk_barbell(dates,p,i):
    # Economic idea: keep both story assets but size by regime; avoid all-in rotation.
    n=nq_ok(p,i); g=gold_ok(p,i) and not gold_blowoff_risk(p,i)
    if n and g: return normalize({'nasdaq':0.52,'gold_cny':0.38})
    if n: return normalize({'nasdaq':0.65,'gold_cny':0.12 if above(p['gold_cny'],i,360) else 0.0})
    if g: return normalize({'gold_cny':0.65})
    return {}

def S5_cash_first_trend(dates,p,i):
    # Economic idea: accept lower exposure; only buy visible assets when trend and momentum agree.
    tw={}
    if nq_ok(p,i) and (mom(p['nasdaq'],i,126) or -9)>0.04: tw['nasdaq']=0.55
    if gold_ok(p,i) and not gold_blowoff_risk(p,i) and (mom(p['gold_cny'],i,126) or -9)>0.02: tw['gold_cny']=0.35
    return normalize(tw)

def realized_vol(vals,i,n=60):
    if i-n+1<1: return None
    rs=[]
    for j in range(i-n+1,i+1):
        if vals[j-1]>0 and vals[j]>0:
            rs.append(vals[j]/vals[j-1]-1)
    if len(rs)<2: return None
    m=sum(rs)/len(rs)
    return math.sqrt(sum((x-m)**2 for x in rs)/(len(rs)-1))*math.sqrt(252)

def vol_weight(p,s,i,risk_budget,cap):
    v=realized_vol(p[s],i,60)
    if v is None or v<=0: return 0.0
    return min(cap,risk_budget/max(v,0.06))

def S6_gold_nq_drawdown_budget(dates,p,i,port_ctx):
    # Economic idea: same state machine, but if portfolio drawdown budget is nearly spent, cut Nasdaq first.
    tw=S2_gold_nasdaq_state_machine(dates,p,i)
    port_dd=port_ctx.get('dd',0.0)
    if port_dd>0.075:
        if 'nasdaq' in tw: tw['nasdaq']*=0.45
        if 'gold_cny' in tw: tw['gold_cny']*=0.70
    elif port_dd>0.055:
        if 'nasdaq' in tw: tw['nasdaq']*=0.70
    return normalize(tw)

def S7_vol_budget_dual_engine(dates,p,i):
    # Economic idea: same visible assets, but position size is paid from a volatility budget.
    # Gold is not treated as free defense; both assets shrink when their own realized vol rises.
    n=nq_ok(p,i); g=gold_ok(p,i) and not gold_blowoff_risk(p,i)
    tw={}
    if n:
        tw['nasdaq']=vol_weight(p,'nasdaq',i,0.060,0.52)
    if g:
        tw['gold_cny']=vol_weight(p,'gold_cny',i,0.045,0.48)
    gross=sum(tw.values())
    if gross>0.82:
        tw={k:v*0.82/gross for k,v in tw.items()}
    return normalize(tw)

def S8_vol_budget_router(dates,p,i):
    # Economic idea: rank gold vs Nasdaq, but size the winner by risk; never let a single asset dominate.
    sn=comp_mom(p['nasdaq'],i); sg=comp_mom(p['gold_cny'],i)
    if sn is None or sg is None: return {}
    candidates=[]
    if nq_ok(p,i) and sn>0: candidates.append(('nasdaq',sn))
    if gold_ok(p,i) and not gold_blowoff_risk(p,i) and sg>0: candidates.append(('gold_cny',sg))
    if not candidates: return {}
    candidates.sort(key=lambda x:x[1],reverse=True)
    top=candidates[0][0]
    rb=0.080 if top=='nasdaq' else 0.060
    cap=0.62 if top=='nasdaq' else 0.55
    tw={top:vol_weight(p,top,i,rb,cap)}
    if len(candidates)>1 and candidates[1][1] > candidates[0][1]*0.65:
        s2=candidates[1][0]
        tw[s2]=vol_weight(p,s2,i,0.025,0.25)
    return normalize(tw)

def S9_low_drawdown_story(dates,p,i):
    # Economic idea: explicitly optimize for product-comfort drawdown: visible story remains gold/Nasdaq, but cash is the default.
    tw={}
    if nq_ok(p,i) and (mom(p['nasdaq'],i,126) or -9)>0.03:
        tw['nasdaq']=vol_weight(p,'nasdaq',i,0.050,0.42)
    if gold_ok(p,i) and not gold_blowoff_risk(p,i) and (mom(p['gold_cny'],i,126) or -9)>0.00:
        tw['gold_cny']=vol_weight(p,'gold_cny',i,0.035,0.38)
    gross=sum(tw.values())
    if gross>0.65:
        tw={k:v*0.65/gross for k,v in tw.items()}
    return normalize(tw)

def S10_nasdaq_primary_gold_small(dates,p,i):
    # Economic idea: Nasdaq is the main engine. Gold is a small inflation/chaos sleeve, never the main rescue asset.
    tw={}
    n_trend=above(p['nasdaq'],i,180) and (mom(p['nasdaq'],i,126) or -9)>0.03 and us_risk_ok(p,i)
    g_trend=above(p['gold_cny'],i,180) and (mom(p['gold_cny'],i,126) or -9)>0.00 and not gold_blowoff_risk(p,i)
    if n_trend:
        nv=realized_vol(p['nasdaq'],i,60) or 0.22
        tw['nasdaq']=0.60 if nv<0.28 else 0.48
    if g_trend:
        gv=realized_vol(p['gold_cny'],i,60) or 0.16
        tw['gold_cny']=0.24 if gv<0.20 else 0.16
    if sum(tw.values())>0.72:
        # When both are on, keep enough real cash; don't become a two-asset risky portfolio.
        sc=0.72/sum(tw.values()); tw={k:v*sc for k,v in tw.items()}
    return normalize(tw)

def S11_nasdaq_primary_vol_budget(dates,p,i):
    # Economic idea: same story as S10, but both sleeves are volatility-budgeted; gold budget is intentionally small.
    tw={}
    if nq_ok(p,i) and (mom(p['nasdaq'],i,126) or -9)>0.02:
        tw['nasdaq']=vol_weight(p,'nasdaq',i,0.075,0.60)
    if gold_ok(p,i) and not gold_blowoff_risk(p,i) and (mom(p['gold_cny'],i,126) or -9)>0.00:
        tw['gold_cny']=vol_weight(p,'gold_cny',i,0.025,0.25)
    if sum(tw.values())>0.72:
        sc=0.72/sum(tw.values()); tw={k:v*sc for k,v in tw.items()}
    return normalize(tw)

def ratio_series(p,i):
    return p['nasdaq'][i]/p['gold_cny'][i] if p['gold_cny'][i]>0 else None

def ratio_ma(p,i,n):
    if i-n+1<0: return None
    rs=[]
    for j in range(i-n+1,i+1):
        r=ratio_series(p,j)
        if r is None: return None
        rs.append(r)
    return sum(rs)/n

def ratio_mom(p,i,n):
    if i-n<0: return None
    r0=ratio_series(p,i-n); r1=ratio_series(p,i)
    if not r0 or not r1: return None
    return r1/r0-1

def S12_gold_nasdaq_relative_strength(dates,p,i):
    # Economic idea: the visible story is a relay race. If Nasdaq beats gold, own Nasdaq; if gold beats Nasdaq, own gold; otherwise cash.
    r=ratio_series(p,i); rm=ratio_ma(p,i,180); rr=ratio_mom(p,i,126)
    if r is None or rm is None or rr is None: return {}
    if r>rm and rr>0 and nq_ok(p,i):
        return normalize({'nasdaq':0.68})
    if r<rm and rr<0 and gold_ok(p,i) and not gold_blowoff_risk(p,i):
        # Gold leg is deliberately smaller: gold drawdowns are visible in this dataset.
        return normalize({'gold_cny':0.42})
    return {}

def S13_relative_strength_vol_budget(dates,p,i):
    # Same relay-race logic, but position size is volatility-budgeted.
    r=ratio_series(p,i); rm=ratio_ma(p,i,180); rr=ratio_mom(p,i,126)
    if r is None or rm is None or rr is None: return {}
    if r>rm and rr>0 and nq_ok(p,i):
        return normalize({'nasdaq':vol_weight(p,'nasdaq',i,0.085,0.68)})
    if r<rm and rr<0 and gold_ok(p,i) and not gold_blowoff_risk(p,i):
        return normalize({'gold_cny':vol_weight(p,'gold_cny',i,0.040,0.38)})
    return {}

# Barbell family: start from the user's simple benchmark instead of inventing low-exposure strategies.
def B0_static_25_25(dates,p,i):
    # Benchmark: 25% Nasdaq + 25% gold + 50% cash, periodically rebalanced.
    return normalize({'nasdaq':0.25,'gold_cny':0.25})

def B1_static_with_trend_halving(dates,p,i):
    # Keep the 25/25 identity, but cut a sleeve in half only when its own long trend and 6M momentum are both broken.
    n=0.25; g=0.25
    if not above(p['nasdaq'],i,220) and (mom(p['nasdaq'],i,126) or 0)<0:
        n=0.125
    if (not above(p['gold_cny'],i,220) and (mom(p['gold_cny'],i,126) or 0)<0) or gold_blowoff_risk(p,i):
        g=0.125
    return normalize({'nasdaq':n,'gold_cny':g})

def B2_core_plus_winner_sleeve(dates,p,i):
    # 20/20 permanent story core + 15% tactical sleeve to the stronger healthy asset.
    tw={'nasdaq':0.20,'gold_cny':0.20}
    sn=comp_mom(p['nasdaq'],i); sg=comp_mom(p['gold_cny'],i)
    if sn is None or sg is None: return normalize(tw)
    if sn>sg and above(p['nasdaq'],i,180) and (mom(p['nasdaq'],i,126) or 0)>0:
        tw['nasdaq']+=0.15
    elif sg>sn and above(p['gold_cny'],i,180) and (mom(p['gold_cny'],i,126) or 0)>0 and not gold_blowoff_risk(p,i):
        tw['gold_cny']+=0.15
    return normalize(tw)

def B3_barbell_with_crash_rebalance(dates,p,i):
    # 25/25 base. Add only a small contrarian rebalance when Nasdaq is deeply down but 1M momentum turns positive.
    tw={'nasdaq':0.25,'gold_cny':0.25}
    nd=dd(p['nasdaq'],i,252) or 0
    gd=dd(p['gold_cny'],i,252) or 0
    if nd<-0.28 and (mom(p['nasdaq'],i,21) or -9)>0 and above(p['nasdaq'],i,60):
        tw['nasdaq']+=0.10
    if gd<-0.20 and (mom(p['gold_cny'],i,21) or -9)>0 and above(p['gold_cny'],i,60):
        tw['gold_cny']+=0.08
    return normalize(tw)

def B4_barbell_regime_tilt(dates,p,i):
    # 25/25 base. Tilt, don't abandon: growth regime -> 35/20; gold regime -> 20/35; unclear -> 25/25.
    r=ratio_series(p,i); rm=ratio_ma(p,i,200); rr=ratio_mom(p,i,126)
    if r is None or rm is None or rr is None:
        return normalize({'nasdaq':0.25,'gold_cny':0.25})
    if r>rm and rr>0 and above(p['nasdaq'],i,180):
        return normalize({'nasdaq':0.35,'gold_cny':0.20})
    if r<rm and rr<0 and above(p['gold_cny'],i,180) and not gold_blowoff_risk(p,i):
        return normalize({'nasdaq':0.20,'gold_cny':0.35})
    return normalize({'nasdaq':0.25,'gold_cny':0.25})

def B5_barbell_drawdown_brake(dates,p,i,port_ctx):
    # 25/25 base. Only if portfolio drawdown is already high, cut the asset that is currently below trend.
    tw={'nasdaq':0.25,'gold_cny':0.25}
    if port_ctx.get('dd',0)>0.12:
        if not above(p['nasdaq'],i,180): tw['nasdaq']=0.15
        if not above(p['gold_cny'],i,180) or gold_blowoff_risk(p,i): tw['gold_cny']=0.15
    return normalize(tw)

def simulate(dates,p,target_fn:Callable,rebalance=20,band=0.02,warmup=0):
    cash=START; units={s:0.0 for s in HOLDINGS}; vals=[]; weights=[]; trades=0; last=-10**9
    peak=START
    def pv(i): return cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    for i,day in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val_before=pv(i); peak=max(peak,val_before)
        if i>0 and i-last>=rebalance:
            sig=i-1
            if sig>=warmup:
                ctx={'dd':1-val_before/peak if peak>0 else 0.0}
                try:
                    tw=target_fn(dates,p,sig,ctx)
                except TypeError:
                    tw=target_fn(dates,p,sig)
                tw=normalize(tw)
            else:
                tw={}
            total=val_before
            # sell first
            for s in HOLDINGS:
                cur=units[s]*p[s][i]; tgt=total*tw.get(s,0.0)
                if cur>tgt*(1+band):
                    su=min(units[s],(cur-tgt)/p[s][i])
                    if su>0:
                        cash += su*p[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; trades+=1
            total=pv(i)
            # buy
            for s in HOLDINGS:
                cur=units[s]*p[s][i]; tgt=total*tw.get(s,0.0)
                if cur<tgt*(1-band):
                    amt=min(cash,max(0.0,tgt-cur))
                    if amt>1:
                        units[s]+=amt*(1-FEE)/(p[s][i]*(1+SLIP)); cash-=amt; trades+=1
            last=i
        val=pv(i); vals.append(val)
        ww={s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4}
        weights.append(ww)
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

def simulate_buy_hold(dates,p,init_weights):
    cash=START; units={s:0.0 for s in HOLDINGS}; vals=[]; weights=[]
    # Buy on first available day with fee/slippage; leave the rest as cash earning demand-deposit yield.
    for s,w in init_weights.items():
        amt=START*w
        units[s]=amt*(1-FEE)/(p[s][0]*(1+SLIP)); cash-=amt
    for i,day in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':len(init_weights),'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values()))}

def metrics(dates,vals,start=None,end=None):
    if start=='TENY':
        try: start=dates[-1].replace(year=dates[-1].year-10)
        except Exception: start=dates[-1]-dt.timedelta(days=3652)
    if start is None: start=dates[0]
    if end is None: end=dates[-1]
    lo=next((i for i,d in enumerate(dates) if d>=start),0); hi=len(dates)
    while hi>0 and dates[hi-1]>end: hi-=1
    if hi-lo<30: return None
    ds=dates[lo:hi]; vs=vals[lo:hi]; peak=vs[0]; mdd=0.0; rs=[]
    for a,b in zip(vs,vs[1:]):
        if a>0 and b>0: rs.append(b/a-1)
        peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=max((ds[-1]-ds[0]).days/365.25,1e-9)
    ann=(vs[-1]/vs[0])**(1/years)-1
    vol=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0.0
    sh=statistics.mean(rs)*252/vol if vol else 0.0
    return {'start':str(ds[0]),'end':str(ds[-1]),'n':len(vs),'ann':ann,'dd':mdd,'total':vs[-1]/vs[0]-1,'vol':vol,'sharpe':sh,'calmar':ann/mdd if mdd else 0.0}

def topdds(dates,vals,weights,n=5):
    peak=tr=0; out=[]
    for i in range(1,len(vals)):
        if vals[i]>vals[peak]:
            if vals[tr]<vals[peak]*0.985: out.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
            peak=tr=i
        elif vals[i]<vals[tr]: tr=i
    if vals[tr]<vals[peak]*0.985: out.append((peak,tr,1-vals[tr]/vals[peak],weights[tr]))
    out.sort(key=lambda x:x[2],reverse=True)
    return [{'peak':str(dates[a]),'trough':str(dates[b]),'dd':c,'weights':{k:round(v*100,1) for k,v in w.items()},'cash':round((1-sum(w.values()))*100,1)} for a,b,c,w in out[:n]]

def all_metrics(dates,vals):
    return {k:metrics(dates,vals,a,b) for k,(a,b) in PERIODS.items()}

def score(row):
    f=row['metrics']['full']; p=row['metrics']['post2020']; t=row['metrics']['teny']; r=row['metrics']['2013-2023']
    if not f or not p or not t or not r: return -999
    worst=max(f['dd'],p['dd'],t['dd'],r['dd'])
    return f['ann']*7+p['ann']*2+t['ann']*2+r['ann']-worst*5-max(f['dd']-.10,0)*20+f['sharpe']*.25

def main():
    dates,p=CORE.align(CORE.fetch())
    strategies=[
        ('U1_dual_momentum_router',S1_dual_momentum_router,20),
        ('U2_gold_nasdaq_state_machine',S2_gold_nasdaq_state_machine,20),
        ('U3_gold_crisis_bridge',S3_gold_crisis_bridge,20),
        ('U4_balanced_risk_barbell',S4_balanced_risk_barbell,20),
        ('U5_cash_first_trend',S5_cash_first_trend,20),
        ('U6_drawdown_budget_state_machine',S6_gold_nq_drawdown_budget,20),
        ('U7_vol_budget_dual_engine_m20',S7_vol_budget_dual_engine,20),
        ('U7_vol_budget_dual_engine_m10',S7_vol_budget_dual_engine,10),
        ('U7_vol_budget_dual_engine_w5',S7_vol_budget_dual_engine,5),
        ('U8_vol_budget_router_m20',S8_vol_budget_router,20),
        ('U8_vol_budget_router_m10',S8_vol_budget_router,10),
        ('U8_vol_budget_router_w5',S8_vol_budget_router,5),
        ('U9_low_drawdown_story_m20',S9_low_drawdown_story,20),
        ('U9_low_drawdown_story_m10',S9_low_drawdown_story,10),
        ('U9_low_drawdown_story_w5',S9_low_drawdown_story,5),
        ('U10_nasdaq_primary_gold_small',S10_nasdaq_primary_gold_small,20),
        ('U10_nasdaq_primary_gold_small_w5',S10_nasdaq_primary_gold_small,5),
        ('U10_nasdaq_primary_gold_small_d1',S10_nasdaq_primary_gold_small,1),
        ('U11_nasdaq_primary_vol_budget',S11_nasdaq_primary_vol_budget,20),
        ('U11_nasdaq_primary_vol_budget_w5',S11_nasdaq_primary_vol_budget,5),
        ('U11_nasdaq_primary_vol_budget_d1',S11_nasdaq_primary_vol_budget,1),
        ('U12_gold_nasdaq_relative_strength',S12_gold_nasdaq_relative_strength,20),
        ('U13_relative_strength_vol_budget',S13_relative_strength_vol_budget,20),
        ('B0_static_25_25_rebalanced',B0_static_25_25,20),
        ('B1_static_25_25_trend_halving',B1_static_with_trend_halving,20),
        ('B2_core20_20_plus_winner15',B2_core_plus_winner_sleeve,20),
        ('B3_25_25_crash_rebalance',B3_barbell_with_crash_rebalance,20),
        ('B4_25_25_regime_tilt',B4_barbell_regime_tilt,20),
        ('B5_25_25_drawdown_brake',B5_barbell_drawdown_brake,20),
    ]
    rows=[]
    # True buy-and-hold baselines (no rebalance), because this is the user's reference point.
    for name,init in [
        ('BH_true_buy_hold_25_gold_25_nasdaq',{'nasdaq':0.25,'gold_cny':0.25}),
        ('BH_true_buy_hold_30_gold_30_nasdaq',{'nasdaq':0.30,'gold_cny':0.30}),
    ]:
        vals,w,e=simulate_buy_hold(dates,p,init)
        row={'name':name,'metrics':all_metrics(dates,vals),'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'score':0}
        row['score']=score(row)
        rows.append(row)
    for name,fn,rebalance in strategies:
        vals,w,e=simulate(dates,p,fn,rebalance=rebalance,warmup=0)
        bad=[s for ww in w for s in ww if s not in VISIBLE_ALLOWED]
        assert not bad, bad[:5]
        row={'name':name,'metrics':all_metrics(dates,vals),'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'score':0}
        row['score']=score(row)
        rows.append(row)
    rows.sort(key=lambda r:(r['metrics']['full']['dd']<=.10,r['score']),reverse=True)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'allowed_holdings':HOLDINGS,'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates),'allowed',HOLDINGS)
    for r in rows:
        print('\n##',r['name'],'score',f"{r['score']:.3f}")
        for k in ['full','post2020','teny','2024+','2002-2012','2013-2023']:
            m=r['metrics'][k]
            print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} vol={pct(m['vol'])} sh={m['sharpe']:.2f} cal={m['calmar']:.2f}")
        print('stress',' | '.join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k,v in r['stress'].items() if v))
        print('latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',pct(r['extra'].get('cash_pct',0)),'trades',r['extra']['trades'])
        print('topdd',' ; '.join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
if __name__=='__main__': main()
