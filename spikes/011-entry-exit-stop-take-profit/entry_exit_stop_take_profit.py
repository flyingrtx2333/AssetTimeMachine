#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, math, statistics, datetime as dt
from pathlib import Path
from typing import Callable, Dict, Any

ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('zoo', ROOT/'spikes/008-gold-nasdaq-mechanism-zoo/mechanism_zoo.py')
Z=importlib.util.module_from_spec(spec); sys.modules['zoo']=Z; spec.loader.exec_module(Z)  # type: ignore
CORE=Z.CORE
OUT=Path('/tmp/atm_entry_exit_stop_take_profit_011.json')
START=100000.0
HOLDINGS=['nasdaq','gold_cny']
TARGET_ANN=0.12
TARGET_DD=0.08
PERIODS=Z.PERIODS
STRESS=Z.STRESS

pct=Z.pct
ma=Z.ma
mom=Z.mom
above=Z.above
dd_series=Z.dd_series
realized_vol=Z.realized_vol
positive_6m=Z.positive_6m
score_asset=Z.score_asset
normalize=Z.normalize
barbell_health_state=Z.barbell_health_state
virtual_barbell=Z.virtual_barbell
virtual_ma=Z.virtual_ma
virtual_mom=Z.virtual_mom


def metrics(dates,vals,start=None,end=None): return Z.metrics(dates,vals,start,end)
def all_metrics(dates,vals): return Z.all_metrics(dates,vals)
def topdds(dates,vals,weights): return Z.topdds(dates,vals,weights)
def simulate_buy_hold(dates,p,init): return Z.simulate_buy_hold(dates,p,init)

def rolling_high(v,i,n,exclude_current=True):
    end=i if exclude_current else i+1
    start=max(0,end-n)
    if end-start<5: return None
    return max(v[start:end])

def rolling_low(v,i,n,exclude_current=True):
    end=i if exclude_current else i+1
    start=max(0,end-n)
    if end-start<5: return None
    return min(v[start:end])

def crossed_above_ma(p,s,i,n):
    if i<=0: return False
    m0=ma(p[s],i-1,n); m1=ma(p[s],i,n)
    return m0 is not None and m1 is not None and p[s][i-1]<=m0 and p[s][i]>m1

def crossed_below_ma(p,s,i,n):
    if i<=0: return False
    m0=ma(p[s],i-1,n); m1=ma(p[s],i,n)
    return m0 is not None and m1 is not None and p[s][i-1]>=m0 and p[s][i]<m1

def trend_ok(p,s,i,ma_n=160,mom_n=126,mom_th=0.0):
    return above(p,s,i,ma_n) and (mom(p[s],i,mom_n) or -9)>mom_th

def fast_break(p,s,i,look=21,th=-0.075):
    return (mom(p[s],i,look) or 0)<th

def sleeve_stop_flags(p,s,i,state,kind):
    """Return (stop, take, reason) for a campaign. State keys are maintained by target functions."""
    entry=state.get(f'{s}_entry')
    high=state.get(f'{s}_high')
    if entry is None or high is None:
        return False, False, ''
    px=p[s][i]
    high=max(high,px); state[f'{s}_high']=high
    if kind=='strict':
        fixed={'nasdaq':0.075,'gold_cny':0.060}[s]; trail={'nasdaq':0.105,'gold_cny':0.085}[s]; take={'nasdaq':0.22,'gold_cny':0.18}[s]
    elif kind=='loose':
        fixed={'nasdaq':0.115,'gold_cny':0.090}[s]; trail={'nasdaq':0.155,'gold_cny':0.120}[s]; take={'nasdaq':0.36,'gold_cny':0.26}[s]
    else:
        fixed={'nasdaq':0.095,'gold_cny':0.075}[s]; trail={'nasdaq':0.130,'gold_cny':0.105}[s]; take={'nasdaq':0.28,'gold_cny':0.22}[s]
    # hard stop from campaign entry, trailing stop from campaign high, and profit-harvest only after rollover.
    if px<=entry*(1-fixed): return True, False, f'fixed_stop_{fixed:.2f}'
    if px<=high*(1-trail) and high>=entry*(1+take*0.45): return True, False, f'trail_stop_{trail:.2f}'
    rollover=(mom(p[s],i,10) or 0)<-0.025 or (mom(p[s],i,21) or 0)<-0.045 or crossed_below_ma(p,s,i,40)
    if px>=entry*(1+take) and rollover: return False, True, f'take_profit_{take:.2f}'
    return False, False, ''

def update_campaign_state_after_target(p,i,state,w,target):
    # This is called at signal time. If target opens/reopens a sleeve, set campaign entry/high at signal close.
    for s in HOLDINGS:
        cur=w.get(s,0.0); tgt=target.get(s,0.0)
        if tgt>0.03 and cur<=0.03:
            state[f'{s}_entry']=p[s][i]
            state[f'{s}_high']=p[s][i]
        elif tgt<=0.03:
            state[f'{s}_entry']=None
            state[f'{s}_high']=None
        elif state.get(f'{s}_entry') is None:
            state[f'{s}_entry']=p[s][i]
            state[f'{s}_high']=p[s][i]
        elif state.get(f'{s}_high') is not None:
            state[f'{s}_high']=max(state[f'{s}_high'],p[s][i])


def trade_to(cash,units,p,i,target,band=0.015):
    target=normalize(target,0.98)
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    traded=False
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur>tgt*(1+band):
            su=min(units[s],(cur-tgt)/p[s][i])
            if su>0:
                cash += su*p[s][i]*(1-Z.SLIP)*(1-Z.FEE); units[s]-=su; traded=True
                if units[s]<1e-12: units[s]=0.0
    total=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    for s in HOLDINGS:
        cur=units[s]*p[s][i]; tgt=total*target.get(s,0.0)
        if cur<tgt*(1-band):
            amt=min(cash,max(tgt-cur,0))
            if amt>1:
                units[s]+=amt*(1-Z.FEE)/(p[s][i]*(1+Z.SLIP)); cash-=amt; traded=True
    return cash,units,traded

def simulate_event(dates,p,target_fn:Callable,rebalance:int=1,band=0.015,warmup=252):
    cash=START; units={s:0.0 for s in HOLDINGS}; vals=[]; weights=[]; trades=0
    ctx={'peak':START,'state':{},'last_target':{},'event_counts':{}}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash += cash*CORE.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        ctx['peak']=max(ctx.get('peak',val),val)
        if i>warmup and i%rebalance==0:
            sig_i=i-1
            sig_val=cash+sum(units[s]*p[s][sig_i] for s in HOLDINGS)
            sig_w={s:(units[s]*p[s][sig_i]/sig_val if sig_val>0 else 0.0) for s in HOLDINGS}
            ctx['sig_w']=sig_w
            ctx['portfolio_dd']=1-val/ctx['peak'] if ctx['peak'] else 0
            target=target_fn(dates,p,sig_i,ctx)
            if target is not None:
                target=normalize(target,0.98)
                update_campaign_state_after_target(p,sig_i,ctx['state'],sig_w,target)
                cash,units,did=trade_to(cash,units,p,i,target,band=band)
                if did: trades+=1
                ctx['last_target']=target
                val=cash+sum(units[s]*p[s][i] for s in HOLDINGS)
        vals.append(val)
        weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0.0,1-sum(weights[-1].values())),'events':ctx.get('event_counts',{})}

def count_event(ctx,name):
    e=ctx.setdefault('event_counts',{})
    e[name]=e.get(name,0)+1

# ---- Entry / exit / stop/take-profit mechanisms ----

def E01_trend_pullback_campaign(kind='medium'):
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=dict(w)
        for s in HOLDINGS:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                if stop:
                    target[s]=0.0; st[f'{s}_cool']=42 if s=='nasdaq' else 30; count_event(ctx,f'{s}_{reason}')
                    continue
                if take:
                    # harvest profit, but do not fully exit unless trend is broken.
                    target[s]=min(w.get(s,0),0.22 if s=='nasdaq' else 0.26); count_event(ctx,f'{s}_{reason}')
            if target.get(s,0)<=0.03 and st.get(f'{s}_cool',0)==0:
                # Buy after healthy trend pullback/recovery, not at any random MA cross.
                h=rolling_high(p[s],i,63,exclude_current=True)
                pull=(p[s][i]/h-1) if h else 0
                recovery=(mom(p[s],i,10) or 0)>0.015 or crossed_above_ma(p,s,i,20)
                if trend_ok(p,s,i,180,126,0.0) and -0.13<=pull<=-0.025 and recovery:
                    target[s]=0.48 if s=='nasdaq' else 0.38; count_event(ctx,f'{s}_buy_pullback')
        if ctx.get('portfolio_dd',0)>0.085:
            # Portfolio-level stop: cut risky sleeve first, leave only small gold if it still trends.
            target['nasdaq']=min(target.get('nasdaq',0),0.12); target['gold_cny']=min(target.get('gold_cny',0),0.28)
            count_event(ctx,'portfolio_dd_brake')
        return normalize(target,0.86)
    return fn

def E02_breakout_chandelier(kind='medium'):
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=dict(w)
        for s in HOLDINGS:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                # Chandelier exit is deliberately stricter on fresh breakouts.
                if not stop and (mom(p[s],i,21) or 0)<-0.075 and crossed_below_ma(p,s,i,50):
                    stop=True; reason='chandelier_momentum_break'
                if stop:
                    target[s]=0.0; st[f'{s}_cool']=35; count_event(ctx,f'{s}_{reason}')
                    continue
                if take:
                    target[s]=min(w.get(s,0),0.18 if s=='nasdaq' else 0.22); count_event(ctx,f'{s}_{reason}')
            if target.get(s,0)<=0.03 and st.get(f'{s}_cool',0)==0:
                h=rolling_high(p[s],i,126,exclude_current=True)
                breakout=h is not None and p[s][i]>h*1.002
                if breakout and trend_ok(p,s,i,120,126,0.03):
                    target[s]=0.58 if s=='nasdaq' else 0.42; count_event(ctx,f'{s}_buy_breakout')
        return normalize(target,0.90)
    return fn

def E03_core_satellite_with_stops(kind='medium'):
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target={}
        # Core only when own trend is alive; satellites require stronger momentum.
        if trend_ok(p,'nasdaq',i,220,126,-0.02): target['nasdaq']=0.25
        if trend_ok(p,'gold_cny',i,180,126,-0.01): target['gold_cny']=0.30
        leader='nasdaq' if score_asset(p,'nasdaq',i)>score_asset(p,'gold_cny',i) else 'gold_cny'
        if leader=='nasdaq' and trend_ok(p,'nasdaq',i,120,63,0.02) and not fast_break(p,'nasdaq',i,21,-0.06):
            target['nasdaq']=target.get('nasdaq',0)+0.32
        if leader=='gold_cny' and trend_ok(p,'gold_cny',i,100,63,0.02) and not fast_break(p,'gold_cny',i,21,-0.05):
            target['gold_cny']=target.get('gold_cny',0)+0.26
        # Event stop/take: cut to core or zero depending on trend damage.
        for s in HOLDINGS:
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                if stop:
                    target[s]=0.0 if not trend_ok(p,s,i,180,126,-0.02) else min(target.get(s,0),0.18 if s=='nasdaq' else 0.22)
                    st[f'{s}_cool']=30; count_event(ctx,f'{s}_{reason}')
                elif take:
                    target[s]=min(target.get(s,0),0.25 if s=='nasdaq' else 0.30); count_event(ctx,f'{s}_{reason}')
        if ctx.get('portfolio_dd',0)>0.08:
            target={s:min(v,0.20 if s=='nasdaq' else 0.26) for s,v in target.items()}
            count_event(ctx,'portfolio_dd_core_cut')
        return normalize(target,0.88)
    return fn

def E04_m34_event_stop_overlay(kind='medium'):
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=Z.M34_health_recovery_with_vol_cap(dates,p,i,ctx) or {}
        for s in HOLDINGS:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if st.get(f'{s}_cool',0)>0:
                target[s]=0.0
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                if stop:
                    target[s]=0.0; st[f'{s}_cool']=30 if s=='nasdaq' else 21; count_event(ctx,f'{s}_{reason}')
                elif take:
                    target[s]=min(target.get(s,0),w.get(s,0)*0.55); count_event(ctx,f'{s}_{reason}')
        # Re-entry after stop only if barbell itself has recovered.
        state,vdd=barbell_health_state(p,i)
        if state=='broken':
            target['nasdaq']=0.0
            if not positive_6m(p,'gold_cny',i): target['gold_cny']=0.0
        return normalize(target,0.82)
    return fn

def E05_recovery_after_deep_drawdown(kind='medium'):
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=dict(w)
        for s in HOLDINGS:
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                if stop:
                    target[s]=0.0; st[f'{s}_cool']=25; count_event(ctx,f'{s}_{reason}')
                elif take:
                    target[s]=min(w.get(s,0),0.20 if s=='nasdaq' else 0.24); count_event(ctx,f'{s}_{reason}')
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            one_y_dd=dd_series(p[s],i,252) or 0.0
            repair=above(p,s,i,60) and (mom(p[s],i,21) or 0)>0.035 and (mom(p[s],i,63) or 0)>0
            long_not_dead=(mom(p[s],i,252) or -9)>-0.18
            if target.get(s,0)<=0.03 and st.get(f'{s}_cool',0)==0 and one_y_dd<-0.16 and repair and long_not_dead:
                target[s]=0.52 if s=='nasdaq' else 0.42; count_event(ctx,f'{s}_buy_recovery')
        return normalize(target,0.86)
    return fn

def E06_profit_ladder_rebuild(kind='medium'):
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=dict(w)
        # Start/rebuild base when trend is constructive.
        for s,base in [('nasdaq',0.28),('gold_cny',0.34)]:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if target.get(s,0)<=0.03 and st.get(f'{s}_cool',0)==0 and trend_ok(p,s,i,160,126,0.0):
                target[s]=base; count_event(ctx,f'{s}_base_buy')
            if target.get(s,0)>0.03 and trend_ok(p,s,i,100,63,0.035):
                target[s]=min(target.get(s,0)+ (0.12 if s=='nasdaq' else 0.09), 0.62 if s=='nasdaq' else 0.50)
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                if stop:
                    target[s]=0.0; st[f'{s}_cool']=35; count_event(ctx,f'{s}_{reason}')
                elif take:
                    # ladder harvest: sell only excess above base first; full exit only if MA breaks.
                    base=0.28 if s=='nasdaq' else 0.34
                    target[s]=0.0 if crossed_below_ma(p,s,i,120) else min(w.get(s,0),base)
                    count_event(ctx,f'{s}_{reason}')
        if ctx.get('portfolio_dd',0)>0.085:
            target={s:min(v,0.20 if s=='nasdaq' else 0.28) for s,v in target.items()}
            count_event(ctx,'portfolio_dd_ladder_cut')
        return normalize(target,0.90)
    return fn


def m13_overlay_base(dates,p,i,ctx):
    # Preserve M13's original monthly-ish buy/rebuild cadence.
    # Existing Z.simulate_target trades when execution index % 20 == 0 using sig_i = i-1,
    # so the signal-side cadence is (sig_i + 1) % 20 == 0.
    # Important: Z.M13_rebalance_harvest_rebuild returns None to mean "no rebalance / keep holding",
    # not "go to cash". Only replace the cached target when M13 returns an actual dict.
    st=ctx.setdefault('state',{})
    if 'm13_base_target' not in st:
        raw=Z.M13_rebalance_harvest_rebuild(dates,p,i,ctx)
        st['m13_base_target']=dict(raw if raw is not None else ctx.get('sig_w',{}))
    elif (i+1)%20==0:
        raw=Z.M13_rebalance_harvest_rebuild(dates,p,i,ctx)
        if raw is not None:
            st['m13_base_target']=dict(raw)
    return dict(st.get('m13_base_target',{}))


def E07_M13_stop_overlay(kind='medium'):
    """Keep M13's buy/rebuild logic, but add daily sleeve stops and modest profit harvesting."""
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=m13_overlay_base(dates,p,i,ctx)
        for s in HOLDINGS:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if st.get(f'{s}_cool',0)>0:
                target[s]=0.0
            if w.get(s,0)>0.03:
                stop,take,reason=sleeve_stop_flags(p,s,i,st,kind)
                # Extra crash stop: only fires on fresh fast damage, so it doesn't constantly sell normal noise.
                crash=(mom(p[s],i,5) or 0)<(-0.075 if s=='nasdaq' else -0.055) or ((dd_series(p[s],i,21) or 0)<(-0.11 if s=='nasdaq' else -0.085) and not above(p,s,i,40))
                if stop or crash:
                    target[s]=0.0
                    st[f'{s}_cool']=21 if s=='nasdaq' else 16
                    count_event(ctx,f'{s}_{reason or "fast_crash_stop"}')
                elif take:
                    # Do not kill the whole winner; just harvest the drift excess.
                    cap=0.38 if s=='nasdaq' else 0.34
                    target[s]=min(target.get(s,w.get(s,0)),cap)
                    count_event(ctx,f'{s}_{reason}')
        # Portfolio brake only trims risk; avoids M34-style over-cashifying.
        if ctx.get('portfolio_dd',0)>0.085:
            target['nasdaq']=min(target.get('nasdaq',0),0.22)
            target['gold_cny']=min(target.get('gold_cny',0),0.30)
            count_event(ctx,'portfolio_dd_trim')
        return normalize(target,0.90)
    return fn


def E08_M13_portfolio_stop_reentry():
    """Portfolio-level stop: if the strategy equity curve breaks, go mostly cash; rebuild only after barbell recovery."""
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        state,vdd=barbell_health_state(p,i)
        vb=virtual_barbell(p,i,0.5,0.5); vm80=virtual_ma(p,i,80,0.5,0.5); vm160=virtual_ma(p,i,160,0.5,0.5)
        recovered=vm80 is not None and vm160 is not None and vb>vm80>vm160 and (virtual_mom(p,i,42,0.5,0.5) or 0)>0
        if ctx.get('portfolio_dd',0)>0.075 or ((virtual_mom(p,i,10,0.5,0.5) or 0)<-0.055):
            st['risk_off']=42
        st['risk_off']=max(0,st.get('risk_off',0)-1)
        if st.get('risk_off',0)>0 and not recovered:
            count_event(ctx,'portfolio_risk_off')
            return {'gold_cny':0.20} if trend_ok(p,'gold_cny',i,120,63,0.0) and not fast_break(p,'gold_cny',i,10,-0.04) else {}
        target=m13_overlay_base(dates,p,i,ctx)
        # If barbell health is bruised, cap total risk but stay invested enough to recover.
        if state=='bruised':
            target['nasdaq']=min(target.get('nasdaq',0),0.34)
            target['gold_cny']=min(target.get('gold_cny',0),0.34)
        elif state=='broken':
            target['nasdaq']=0.0
            target['gold_cny']=min(target.get('gold_cny',0),0.24)
        return normalize(target,0.88)
    return fn


def E09_M13_takeprofit_only():
    """Test the user's take-profit idea without stop-loss: harvest only after large profits roll over."""
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=m13_overlay_base(dates,p,i,ctx)
        for s in HOLDINGS:
            if w.get(s,0)>0.03:
                _stop,take,reason=sleeve_stop_flags(p,s,i,st,'loose')
                if take:
                    target[s]=min(target.get(s,w.get(s,0)),0.32 if s=='nasdaq' else 0.30)
                    count_event(ctx,f'{s}_{reason}')
        return normalize(target,0.92)
    return fn


def E10_M13_stop_no_takeprofit(kind='medium'):
    """Test the opposite: stop-loss only, no take-profit, to avoid cutting winners too early."""
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=m13_overlay_base(dates,p,i,ctx)
        for s in HOLDINGS:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if st.get(f'{s}_cool',0)>0:
                target[s]=0.0
            if w.get(s,0)>0.03:
                stop,_take,reason=sleeve_stop_flags(p,s,i,st,kind)
                if stop:
                    target[s]=0.0; st[f'{s}_cool']=18 if s=='nasdaq' else 12; count_event(ctx,f'{s}_{reason}')
        if ctx.get('portfolio_dd',0)>0.09:
            target['nasdaq']=min(target.get('nasdaq',0),0.18)
            count_event(ctx,'portfolio_dd_stop_only_trim')
        return normalize(target,0.92)
    return fn


def E11_adaptive_breakout_budget():
    """Breakout engine with active buy rules, tight gold stop, and winner-preserving profit harvest."""
    def fn(dates,p,i,ctx):
        st=ctx.setdefault('state',{}); w=ctx.get('sig_w',{})
        target=dict(w)
        # Existing positions: dynamic exits first.
        for s in HOLDINGS:
            st[f'{s}_cool']=max(0,st.get(f'{s}_cool',0)-1)
            if w.get(s,0)>0.03:
                entry=st.get(f'{s}_entry'); high=st.get(f'{s}_high')
                if entry is None: entry=p[s][i]
                if high is None: high=p[s][i]
                high=max(high,p[s][i]); st[f'{s}_high']=high; st[f'{s}_entry']=entry
                px=p[s][i]
                if s=='nasdaq':
                    fixed=0.10; trail=0.13; profit=0.34; min_after_profit=0.38
                    shock=(mom(p[s],i,5) or 0)<-0.075 or ((mom(p[s],i,21) or 0)<-0.10 and not above(p,s,i,40))
                else:
                    fixed=0.065; trail=0.080; profit=0.20; min_after_profit=0.26
                    # Gold often creates short sharp air-pocket losses; stop it faster after blowoff.
                    blowoff=(mom(p[s],i,126) or 0)>0.18 and (mom(p[s],i,10) or 0)<-0.035
                    shock=(mom(p[s],i,5) or 0)<-0.045 or blowoff
                if px<=entry*(1-fixed) or (px<=high*(1-trail) and high>=entry*(1+profit*0.4)) or shock:
                    target[s]=0.0; st[f'{s}_cool']=20 if s=='nasdaq' else 14; count_event(ctx,f'{s}_adaptive_stop')
                    continue
                rollover=(mom(p[s],i,10) or 0)<-0.025 or crossed_below_ma(p,s,i,50)
                if px>=entry*(1+profit) and rollover:
                    target[s]=min(w.get(s,0),min_after_profit); count_event(ctx,f'{s}_adaptive_take')
        # New entries / rebuild. Use breakout OR post-pullback recovery, so we do not wait for rare 126d highs only.
        for s in HOLDINGS:
            if target.get(s,0)>0.03 or st.get(f'{s}_cool',0)>0: continue
            h126=rolling_high(p[s],i,126,exclude_current=True); h63=rolling_high(p[s],i,63,exclude_current=True)
            breakout=(h126 is not None and p[s][i]>h126*1.001) or (h63 is not None and p[s][i]>h63*1.006 and (mom(p[s],i,63) or 0)>0.05)
            h=rolling_high(p[s],i,63,exclude_current=True); pull=(p[s][i]/h-1) if h else 0
            pull_recovery=(-0.10<=pull<=-0.025 and above(p,s,i,40) and (mom(p[s],i,10) or 0)>0.012)
            if s=='nasdaq':
                if (breakout or pull_recovery) and trend_ok(p,s,i,120,126,0.02):
                    target[s]=0.72; count_event(ctx,'nasdaq_adaptive_buy')
            else:
                if (breakout or pull_recovery) and trend_ok(p,s,i,100,63,0.015) and not ((mom(p[s],i,126) or 0)>0.28 and (mom(p[s],i,21) or 0)<0):
                    target[s]=0.42; count_event(ctx,'gold_adaptive_buy')
        # If both are active, cap combined risk and favor the stronger current trend.
        sn=score_asset(p,'nasdaq',i); sg=score_asset(p,'gold_cny',i)
        if target.get('nasdaq',0)>0 and target.get('gold_cny',0)>0:
            if sn>=sg:
                target['nasdaq']=min(target['nasdaq'],0.68); target['gold_cny']=min(target['gold_cny'],0.24)
            else:
                target['nasdaq']=min(target['nasdaq'],0.35); target['gold_cny']=min(target['gold_cny'],0.46)
        if ctx.get('portfolio_dd',0)>0.075:
            target['nasdaq']=min(target.get('nasdaq',0),0.24)
            target['gold_cny']=min(target.get('gold_cny',0),0.25)
            count_event(ctx,'adaptive_portfolio_brake')
        return normalize(target,0.92)
    return fn


def E12_adaptive_breakout_defensive():
    """Lower-DD sibling of E11: same entries, lower caps and faster portfolio brake."""
    base=E11_adaptive_breakout_budget()
    def fn(dates,p,i,ctx):
        target=base(dates,p,i,ctx) or {}
        if target.get('nasdaq',0)>0: target['nasdaq']=min(target['nasdaq'],0.56)
        if target.get('gold_cny',0)>0: target['gold_cny']=min(target['gold_cny'],0.36)
        if ctx.get('portfolio_dd',0)>0.06:
            target['nasdaq']=min(target.get('nasdaq',0),0.16)
            target['gold_cny']=min(target.get('gold_cny',0),0.22)
            count_event(ctx,'defensive_portfolio_brake')
        return normalize(target,0.78)
    return fn

CANDIDATES=[
    ('BH_25_25_buyhold','baseline 25N/25G/50C',None,'buyhold',{'nasdaq':0.25,'gold_cny':0.25},None),
    ('BH_25_35_buyhold','baseline 25N/35G/40C',None,'buyhold',{'nasdaq':0.25,'gold_cny':0.35},None),
    ('M13_ref_harvest_rebuild','old high-return harvest/rebuild reference',Z.M13_rebalance_harvest_rebuild,'monthly',None,20),
    ('M34_ref_health_recovery_volcap','old lower-DD M34 reference',Z.M34_health_recovery_with_vol_cap,'monthly',None,20),
]
for kind in ['strict','medium','loose']:
    CANDIDATES += [
        (f'E01_daily_trend_pullback_{kind}','buy trend pullbacks/recovery; fixed+trailing stop; rollover take-profit',E01_trend_pullback_campaign(kind),'event',None,1),
        (f'E02_daily_breakout_chandelier_{kind}','buy breakouts; chandelier stop; partial take-profit',E02_breakout_chandelier(kind),'event',None,1),
        (f'E03_daily_core_satellite_stops_{kind}','core + satellite; stop/take cuts satellite first',E03_core_satellite_with_stops(kind),'event',None,1),
        (f'E04_daily_M34_stop_overlay_{kind}','M34 with explicit campaign stop/take/cooldown overlay',E04_m34_event_stop_overlay(kind),'event',None,1),
        (f'E05_daily_deep_recovery_{kind}','buy only recovery after deep drawdown; campaign stops',E05_recovery_after_deep_drawdown(kind),'event',None,1),
        (f'E06_daily_profit_ladder_{kind}','base/rebuild + profit ladder + stops',E06_profit_ladder_rebuild(kind),'event',None,1),
        (f'E04_weekly_M34_stop_overlay_{kind}','weekly M34 stop/take/cooldown overlay',E04_m34_event_stop_overlay(kind),'event',None,5),
        (f'E06_weekly_profit_ladder_{kind}','weekly base/rebuild + profit ladder + stops',E06_profit_ladder_rebuild(kind),'event',None,5),
        (f'E07_daily_M13_stop_take_{kind}','M13 buy/rebuild + daily stop/take/cooldown overlay',E07_M13_stop_overlay(kind),'event',None,1),
        (f'E10_daily_M13_stop_only_{kind}','M13 buy/rebuild + stop-loss only, no take-profit',E10_M13_stop_no_takeprofit(kind),'event',None,1),
    ]
CANDIDATES += [
    ('E08_daily_M13_portfolio_stop_reentry','M13 + portfolio equity-curve stop and recovery re-entry',E08_M13_portfolio_stop_reentry(),'event',None,1),
    ('E09_daily_M13_takeprofit_only','M13 + take-profit only, no stop-loss',E09_M13_takeprofit_only(),'event',None,1),
    ('E11_daily_adaptive_breakout_budget','adaptive breakout/pullback buys + dynamic stops + winner-preserving take profit',E11_adaptive_breakout_budget(),'event',None,1),
    ('E12_daily_adaptive_breakout_defensive','lower-risk adaptive breakout sibling with faster portfolio brake',E12_adaptive_breakout_defensive(),'event',None,1),
]

def row_for(dates,p,c):
    name,desc,fn,mode,bh,reb=c
    if mode=='buyhold': vals,w,e=simulate_buy_hold(dates,p,bh)
    elif mode=='monthly': vals,w,e=Z.simulate_target(dates,p,fn,rebalance=reb or 20)
    else: vals,w,e=simulate_event(dates,p,fn,rebalance=reb or 1,band=0.02)
    bad=[s for ww in w for s in ww if s not in HOLDINGS]
    assert not bad, bad[:5]
    m=all_metrics(dates,vals)
    return {'name':name,'description':desc,'mode':mode,'rebalance':reb,'metrics':m,'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'pass_12_8':m['full']['ann']>=TARGET_ANN and m['full']['dd']<=TARGET_DD}

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[row_for(dates,p,c) for c in CANDIDATES]
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'target':{'ann':TARGET_ANN,'dd':TARGET_DD},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates),'TARGET',TARGET_ANN,TARGET_DD)
    print('\nCandidates sorted by full annualized:')
    for r in sorted(rows,key=lambda x:x['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; mark='PASS' if r['pass_12_8'] else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'],'events',r['extra'].get('events',{}))
    print('\nBest under 12% DD:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.12],key=lambda x:x['metrics']['full']['ann'],reverse=True)[:20]:
        m=r['metrics']['full']; print(r['name'],f"ann={m['ann']*100:.2f} dd={m['dd']*100:.2f}",'events',r['extra'].get('events',{}))
    print('\nPASS_COUNT',sum(1 for r in rows if r['pass_12_8']))
if __name__=='__main__': run()
