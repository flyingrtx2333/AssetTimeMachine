#!/usr/bin/env python3
"""Local search around the promising gold/nasdaq/sp500 trend-vol strategy,
adding portfolio-level drawdown governor to shave max drawdown.
"""
from __future__ import annotations
import datetime as dt, importlib.util, json, math
from pathlib import Path
from typing import Any

spec=importlib.util.spec_from_file_location('prev','tools/search_new_portfolio_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load failed')
prev=importlib.util.module_from_spec(spec); spec.loader.exec_module(prev)
base=prev.base
SYMS=['gold_cny','nasdaq','sp500']; INITIAL=100000.0; FEE=0.001; SLIP=0.0005

def ma(vals,n): return prev.ma(vals,n)
def momentum(vals,i,lb): return prev.momentum(vals,i,lb)
def ann_vol(vals,i,lb): return prev.ann_vol(vals,i,lb)
def drawdown(vals,i,lb): return prev.drawdown(vals,i,lb)
def metrics(dates,vals): return base.metrics(dates,vals)
def slice_m(dates,vals,start): return base.slice_metrics(dates,vals,start)

def prepare(): return prev.prepare()

def simulate(dates, prices, cfg):
    mas={s:ma(prices[s], cfg['ma_'+s]) for s in SYMS}
    cash=INITIAL; units={s:0.0 for s in SYMS}; vals=[]; trades=0; exposure_sum=0.0; last_reb=-10**9
    peak=INITIAL; guard_level='normal'; guard_release_count=0
    for i,d in enumerate(dates):
        def port_val(): return cash + sum(units[s]*prices[s][i] for s in SYMS)
        # update guard from previous marked value only; action executes today.
        if i>0:
            prev_val=vals[-1]
            peak=max(peak, prev_val)
            dd=prev_val/peak-1 if peak>0 else 0
            if dd < -cfg['hard_dd']:
                guard_level='hard'; guard_release_count=0
            elif dd < -cfg['soft_dd'] and guard_level=='normal':
                guard_level='soft'; guard_release_count=0
            elif guard_level!='normal':
                # require several sessions back above soft line and equities trend ok before release
                sig=i-1
                eq_ok=0
                for s in ['nasdaq','sp500']:
                    m=mas[s][sig]
                    mo=momentum(prices[s],sig,cfg['mom_lb'])
                    if m is not None and prices[s][sig]>m and mo is not None and mo>cfg['mom_th']:
                        eq_ok+=1
                if dd > -cfg['release_dd'] and eq_ok>=1:
                    guard_release_count+=1
                    if guard_release_count>=cfg['release_sessions']:
                        guard_level='normal'; guard_release_count=0
                else:
                    guard_release_count=0
        if i>0 and i-last_reb>=cfg['rebalance']:
            sig=i-1
            target={s:0.0 for s in SYMS}
            for s in SYMS:
                m=mas[s][sig]
                mo=momentum(prices[s],sig,cfg['mom_lb'])
                if m is not None and prices[s][sig]>m and mo is not None and mo>cfg['mom_th']:
                    target[s]=cfg['w_'+s]
            # equity crash brake from asset behavior
            eq_bad=False
            for s in ['nasdaq','sp500']:
                dd=drawdown(prices[s],sig,cfg['brake_lb']); vol=ann_vol(prices[s],sig,cfg['vol_lb'])
                if (dd is not None and dd < -cfg['eq_dd']) or (vol is not None and vol>cfg['eq_vol']): eq_bad=True
            if eq_bad:
                cut=0
                for s in ['nasdaq','sp500']:
                    old=target[s]; target[s]*=cfg['eq_scale']; cut += old-target[s]
                if target['gold_cny']>0: target['gold_cny'] += cut*cfg['redeploy_gold']
            # portfolio drawdown guard
            if guard_level=='soft':
                cut=0
                for s in ['nasdaq','sp500']:
                    old=target[s]; target[s]*=cfg['soft_scale']; cut += old-target[s]
                if target['gold_cny']>0: target['gold_cny'] += cut*cfg['soft_to_gold']
            elif guard_level=='hard':
                cut=0
                for s in ['nasdaq','sp500']:
                    old=target[s]; target[s]*=cfg['hard_scale']; cut += old-target[s]
                target['gold_cny'] *= cfg['hard_gold_scale']
                if target['gold_cny']>0: target['gold_cny'] += cut*cfg['hard_to_gold']
            # vol target conservative/cov-lite same as previous script approx sum of weighted vols
            port_vol=0.0
            for s,w in target.items(): port_vol += abs(w)*(ann_vol(prices[s],sig,cfg['vol_lb']) or 0)
            gross=sum(target.values()); scale=1.0
            if port_vol>0: scale=min(scale, cfg['target_vol']/port_vol)
            if gross>0: scale=min(scale, cfg['max_exposure']/gross)
            for s in SYMS: target[s]*=scale
            total=port_val()
            # sell first
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target[s]
                if cur>tgt*(1+cfg['band']):
                    amount=cur-tgt; su=min(units[s], amount/prices[s][i])
                    if su>0:
                        cash += su*prices[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; trades+=1
            total=port_val()
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target[s]
                if cur<tgt*(1-cfg['band']):
                    amount=min(cash,tgt-cur)
                    if amount>1:
                        units[s]+=amount*(1-FEE)/(prices[s][i]*(1+SLIP)); cash-=amount; trades+=1
            last_reb=i
        v=port_val(); vals.append(v)
        exposure_sum += sum(units[s]*prices[s][i] for s in SYMS)/v if v>0 else 0
    return vals,trades,exposure_sum/len(vals)

def score(m, sm):
    ann=m['annualized'] or 0; dd=m['max_drawdown']; sh=m['sharpe'] or 0
    p=sm['post_2020']; y=sm['last_10y']; z=sm['post_2022']
    pann=(p or {}).get('annualized') or 0; yann=(y or {}).get('annualized') or 0; zann=(z or {}).get('annualized') or 0
    pdd=(p or {}).get('max_drawdown') or 0; ydd=(y or {}).get('max_drawdown') or 0; zdd=(z or {}).get('max_drawdown') or 0
    return ann*1.55+pann*.35+yann*.25+zann*.15+sh*.2-dd*1.8-max(dd-.10,0)*9-max(pdd-.11,0)*3-max(ydd-.11,0)*2-max(zdd-.11,0)*1.5

def simplify(c):
    def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
    return {'score':round(c['score'],6),'config':c['cfg'],'trades':c['trades'],'exposure':round(c['exposure'],4),'metrics':sm(c['metrics']),'slices':{k:sm(v) for k,v in c['slices'].items()}}

def main():
    dates,prices=prepare(); print('COVERAGE',len(dates),dates[0],dates[-1],flush=True)
    candidates=[]; evaluated=0
    for wg,wn,ws in [(0.35,0.55,0.10),(0.35,0.50,0.15),(0.40,0.50,0.10),(0.45,0.45,0.10),(0.50,0.40,0.10)]:
      for ma_g in [180,220]:
       for ma_e in [180,220,250]:
        for tv in [0.14,0.15,0.16,0.17]:
         for maxexp in [0.85,0.95,1.0]:
          for soft_dd,hard_dd in [(0.045,0.075),(0.055,0.085),(0.065,0.095)]:
           for soft_scale,hard_scale in [(0.35,0.10),(0.50,0.20),(0.65,0.25)]:
            cfg={'w_gold_cny':wg,'w_nasdaq':wn,'w_sp500':ws,'ma_gold_cny':ma_g,'ma_nasdaq':ma_e,'ma_sp500':ma_e,'rebalance':20,'mom_lb':120,'mom_th':-0.02,'target_vol':tv,'max_exposure':maxexp,'vol_lb':60,'brake_lb':60,'eq_dd':0.12,'eq_vol':0.28,'eq_scale':0.35,'redeploy_gold':0.75,'band':0.02,'soft_dd':soft_dd,'hard_dd':hard_dd,'release_dd':soft_dd/2,'release_sessions':20,'soft_scale':soft_scale,'hard_scale':hard_scale,'soft_to_gold':0.75,'hard_to_gold':0.25,'hard_gold_scale':0.65}
            vals,trades,expo=simulate(dates,prices,cfg); m=metrics(dates,vals)
            if not m: continue
            sm={'full':m,'post_2020':slice_m(dates,vals,dt.date(2020,1,1)),'last_10y':slice_m(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':slice_m(dates,vals,dt.date(2022,1,1))}
            candidates.append({'cfg':cfg,'metrics':m,'slices':sm,'score':score(m,sm),'trades':trades,'exposure':expo}); evaluated+=1
    print('EVALUATED',evaluated,'CANDIDATES',len(candidates),flush=True)
    candidates.sort(key=lambda c:(c['score'],c['metrics']['annualized'] or 0),reverse=True)
    def dedupe(items,limit=30):
        out=[]; seen=set()
        for c in items:
            cfg=c['cfg']; fam=(cfg['w_gold_cny'],cfg['w_nasdaq'],cfg['ma_gold_cny'],cfg['ma_nasdaq'],cfg['target_vol'],cfg['max_exposure'],cfg['soft_dd'],cfg['hard_dd'],cfg['soft_scale'],cfg['hard_scale'])
            if fam in seen: continue
            seen.add(fam); out.append(c)
            if len(out)>=limit: break
        return out
    under10=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.10],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under11=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.11],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under12=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.12],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':{'count':len(dates),'start':str(dates[0]),'end':str(dates[-1])},'evaluated':evaluated,'score_top':[simplify(c) for c in dedupe(candidates)],'under10_by_return':[simplify(c) for c in dedupe(under10,20)],'under11_by_return':[simplify(c) for c in dedupe(under11,20)],'under12_by_return':[simplify(c) for c in dedupe(under12,20)]}
    Path('/tmp/atm_portfolio_guard_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_portfolio_guard_search.json')
    for sec in ['under10_by_return','under11_by_return','under12_by_return','score_top']:
        print('\n==',sec,'==')
        for i,c in enumerate(serial[sec][:8],1):
            m=c['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'],'cfg',c['config'])
if __name__=='__main__': main()
