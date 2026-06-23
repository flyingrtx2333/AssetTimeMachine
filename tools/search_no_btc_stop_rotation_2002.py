#!/usr/bin/env python3
"""No-BTC 2002 full-cycle: relative-strength rotation with daily emergency exits.

No new assets. Uses existing market series only.
"""
from __future__ import annotations
import datetime as dt, importlib.util, json, math
from pathlib import Path
from typing import Any

spec=importlib.util.spec_from_file_location('nb','tools/search_no_btc_2002_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load failed')
nb=importlib.util.module_from_spec(spec); spec.loader.exec_module(nb)
base=nb.base; SYMS=nb.SYMS; INITIAL=100000.0; FEE=.001; SLIP=.0005


def ma(vals,n):
    out=[None]*len(vals); rs=0.0
    for i,v in enumerate(vals):
        rs+=v
        if i>=n: rs-=vals[i-n]
        if i>=n-1: out[i]=rs/n
    return out

def mom(vals,i,n):
    if i-n<0 or vals[i-n]<=0: return None
    return vals[i]/vals[i-n]-1

def vol(vals,i,n):
    if i-n<1: return None
    arr=[]
    for j in range(i-n+1,i+1):
        if vals[j-1]>0 and vals[j]>0: arr.append(math.log(vals[j]/vals[j-1]))
    if len(arr)<2: return None
    m=sum(arr)/len(arr); var=sum((x-m)**2 for x in arr)/(len(arr)-1)
    return math.sqrt(var)*math.sqrt(252)

def dd(vals,i,n):
    if i-n+1<0: return None
    w=vals[i-n+1:i+1]; p=max(w)
    return vals[i]/p-1 if p>0 else None

def build_cache(prices):
    cache={'ma':{},'mom':{},'vol':{},'dd':{}}
    for sym in SYMS:
        for n in [40,60,80,120,160,180,200,220,260]: cache['ma'][(sym,n)]=ma(prices[sym],n)
        for n in [40,60,90,120,180]: cache['mom'][(sym,n)]=[mom(prices[sym],i,n) for i in range(len(prices[sym]))]
        for n in [40,60,90]: cache['vol'][(sym,n)]=[vol(prices[sym],i,n) for i in range(len(prices[sym]))]
        for n in [40,60,90,120]: cache['dd'][(sym,n)]=[dd(prices[sym],i,n) for i in range(len(prices[sym]))]
    return cache

def active_score(prices,cache,sym,i,cfg):
    ma_long=cache['ma'][(sym,cfg['gold_ma'] if sym=='gold_cny' else cfg['eq_ma'])][i]
    mo=cache['mom'][(sym,cfg['mom_lb'])][i]
    vv=cache['vol'][(sym,cfg['vol_lb'])][i]
    d=cache['dd'][(sym,cfg['dd_lb'])][i]
    if ma_long is None or mo is None: return None
    if prices[sym][i] <= ma_long: return None
    if mo <= cfg['mom_th']: return None
    if vv is not None and vv > (cfg['gold_vol_cap'] if sym=='gold_cny' else cfg['eq_vol_cap']): return None
    if d is not None and d < -(cfg['gold_dd_cap'] if sym=='gold_cny' else cfg['eq_dd_cap']): return None
    return mo/max(vv or cfg['fallback_vol'],.05)

def simulate(dates,prices,cache,cfg):
    cash=INITIAL; units={s:0.0 for s in SYMS}; vals=[]; trades=0; exposure=0.0; last_reb=-10**9
    entry_peak={s:0.0 for s in SYMS}; cooldown={s:0 for s in SYMS}
    for i,date in enumerate(dates):
        def pv(): return cash+sum(units[s]*prices[s][i] for s in SYMS)
        # mark/update entry peaks and daily emergency exits using yesterday signal if available, executing today
        if i>0:
            sig=i-1
            total=pv()
            for sym in SYMS:
                if units[sym] <= 0: continue
                entry_peak[sym]=max(entry_peak[sym], prices[sym][sig])
                short_ma=cache['ma'][(sym,cfg['gold_stop_ma'] if sym=='gold_cny' else cfg['eq_stop_ma'])][sig]
                trail=prices[sym][sig]/entry_peak[sym]-1 if entry_peak[sym]>0 else 0
                stop_dd=cfg['gold_trail_stop'] if sym=='gold_cny' else cfg['eq_trail_stop']
                exit_now=(short_ma is not None and prices[sym][sig] < short_ma) or trail < -stop_dd
                if exit_now:
                    cash += units[sym]*prices[sym][i]*(1-SLIP)*(1-FEE); units[sym]=0.0; trades+=1; cooldown[sym]=cfg['cooldown']; entry_peak[sym]=0.0
            for sym in SYMS:
                if cooldown[sym]>0: cooldown[sym]-=1
        if i>0 and i-last_reb>=cfg['rebalance']:
            sig=i-1
            ranked=[]
            for sym in SYMS:
                if cooldown[sym]>0: continue
                sc=active_score(prices,cache,sym,sig,cfg)
                if sc is not None: ranked.append((sc,sym))
            ranked.sort(reverse=True); selected=[sym for _,sym in ranked[:cfg['top_n']]]
            target={s:0.0 for s in SYMS}
            if selected:
                inv={}
                for sym in selected:
                    vv=cache['vol'][(sym,cfg['vol_lb'])][sig] or cfg['fallback_vol']
                    inv[sym]=1/max(vv,.05)
                inv_sum=sum(inv.values())
                for sym in selected: target[sym]=inv[sym]/inv_sum
                # cap equities if gold is absent during high market stress
                if 'gold_cny' not in selected:
                    eq_dds=[cache['dd'][(s,cfg['dd_lb'])][sig] for s in ['nasdaq','sp500','dowjones']]
                    if any(x is not None and x < -cfg['market_stress_dd'] for x in eq_dds):
                        for sym in selected: target[sym]*=cfg['stress_scale']
            # target volatility + max exposure
            port_vol=sum(target[s]*(cache['vol'][(s,cfg['vol_lb'])][sig] or 0) for s in SYMS)
            scale=cfg['max_exposure']
            if port_vol>0: scale=min(scale,cfg['target_vol']/port_vol)
            for sym in target: target[sym]*=scale
            total=pv()
            for sym in SYMS:
                cur=units[sym]*prices[sym][i]; tgt=total*target[sym]
                if cur>tgt*(1+cfg['band']):
                    su=min(units[sym],(cur-tgt)/prices[sym][i])
                    if su>0:
                        cash+=su*prices[sym][i]*(1-SLIP)*(1-FEE); units[sym]-=su; trades+=1
                        if units[sym]<=1e-12: entry_peak[sym]=0.0
            total=pv()
            for sym in SYMS:
                cur=units[sym]*prices[sym][i]; tgt=total*target[sym]
                if cur<tgt*(1-cfg['band']):
                    amt=min(cash,tgt-cur)
                    if amt>1:
                        units[sym]+=amt*(1-FEE)/(prices[sym][i]*(1+SLIP)); cash-=amt; trades+=1; entry_peak[sym]=max(entry_peak[sym],prices[sym][i])
            last_reb=i
        v=pv(); vals.append(v); exposure += sum(units[s]*prices[s][i] for s in SYMS)/v if v>0 else 0
    return vals,trades,exposure/len(vals)

def score(m,sl):
    ann=m['annualized'] or 0; d=m['max_drawdown']; sh=m['sharpe'] or 0
    p=sl['post_2020'] or {}; y=sl['last_10y'] or {}; z=sl['post_2022'] or {}
    return ann*1.65+(p.get('annualized') or 0)*.25+(y.get('annualized') or 0)*.20+(z.get('annualized') or 0)*.12+sh*.20-d*1.6-max(d-.10,0)*9

def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
def simp(c): return {'score':round(c['score'],6),'trades':c['trades'],'exposure':round(c['exposure'],4),'config':c['cfg'],'metrics':sm(c['metrics']),'slices':{k:sm(v) for k,v in c['slices'].items()}}

def main():
    dates,prices,cov=nb.load_aligned(); print('COVERAGE',cov['aligned'],flush=True)
    cache=build_cache(prices)
    candidates=[]; evaluated=0
    for top_n in [1,2]:
      for reb in [5,10,20]:
       for mom_lb in [60,90,120]:
        for mom_th in [-.02,0.0,.02]:
         for eq_ma in [120,180,220]:
          for gold_ma in [120,180,220]:
           for stop_ma in [40,60,80]:
            for target_vol in [.10,.12,.14,.16,.18]:
             for maxexp in [.55,.65,.75,.85,.95]:
              cfg={'top_n':top_n,'rebalance':reb,'mom_lb':mom_lb,'mom_th':mom_th,'eq_ma':eq_ma,'gold_ma':gold_ma,'eq_stop_ma':stop_ma,'gold_stop_ma':stop_ma,'vol_lb':60,'dd_lb':60,'gold_vol_cap':.40,'eq_vol_cap':.45,'gold_dd_cap':.20,'eq_dd_cap':.20,'gold_trail_stop':.09,'eq_trail_stop':.10,'cooldown':reb,'fallback_vol':.18,'target_vol':target_vol,'max_exposure':maxexp,'market_stress_dd':.10,'stress_scale':.45,'band':.02}
              vals,trades,expo=simulate(dates,prices,cache,cfg); m=base.metrics(dates,vals)
              if not m: continue
              sl={'post_2020':base.slice_metrics(dates,vals,dt.date(2020,1,1)),'last_10y':base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':base.slice_metrics(dates,vals,dt.date(2022,1,1))}
              candidates.append({'cfg':cfg,'metrics':m,'slices':sl,'trades':trades,'exposure':expo,'score':score(m,sl)}); evaluated+=1
    print('EVALUATED',evaluated,'CANDIDATES',len(candidates),flush=True)
    candidates.sort(key=lambda c:(c['score'],c['metrics']['annualized'] or 0),reverse=True)
    def dedupe(items,limit=30):
      out=[]; seen=set()
      for c in items:
        cfg=c['cfg']; key=(cfg['top_n'],cfg['rebalance'],cfg['mom_lb'],cfg['mom_th'],cfg['eq_ma'],cfg['gold_ma'],cfg['eq_stop_ma'],cfg['target_vol'],cfg['max_exposure'])
        if key in seen: continue
        seen.add(key); out.append(c)
        if len(out)>=limit: break
      return out
    under10=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.10],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under11=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.11],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under12=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.12],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':cov,'evaluated':evaluated,'score_top':[simp(c) for c in dedupe(candidates)],'under10_by_return':[simp(c) for c in dedupe(under10,20)],'under11_by_return':[simp(c) for c in dedupe(under11,20)],'under12_by_return':[simp(c) for c in dedupe(under12,20)]}
    Path('/tmp/atm_no_btc_stop_rotation_2002_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_no_btc_stop_rotation_2002_search.json')
    for sec in ['under10_by_return','under11_by_return','under12_by_return','score_top']:
      print('\n==',sec,'==')
      for i,c in enumerate(serial[sec][:10],1):
        m=c['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'],'expo',c['exposure'],'cfg',c['config'])
if __name__=='__main__': main()
