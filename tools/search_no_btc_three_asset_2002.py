#!/usr/bin/env python3
from __future__ import annotations
import datetime as dt, importlib.util, json
from pathlib import Path

spec=importlib.util.spec_from_file_location('prev','tools/search_new_portfolio_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load failed')
prev=importlib.util.module_from_spec(spec); spec.loader.exec_module(prev)
base=prev.base
START=dt.date(2002,1,4)

def filter_from_2002(dates, prices):
    idx=0
    while idx<len(dates) and dates[idx]<START: idx+=1
    return dates[idx:], {s: arr[idx:] for s,arr in prices.items()}

def sm(m):
    if m is None: return None
    return {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}

def score(m, slices):
    ann=m['annualized'] or 0; dd=m['max_drawdown']; sh=m['sharpe'] or 0
    p=slices['post_2020'] or {}; y=slices['last_10y'] or {}; z=slices['post_2022'] or {}
    return ann*1.55+(p.get('annualized') or 0)*.35+(y.get('annualized') or 0)*.25+(z.get('annualized') or 0)*.15+sh*.2-dd*1.75-max(dd-.10,0)*8-max((p.get('max_drawdown') or 0)-.12,0)*3

def simplify(c):
    return {'score':round(c['score'],6),'config':c['cfg'],'trades':c['trades'],'exposure':round(c['exposure'],4),'metrics':sm(c['metrics']),'slices':{k:sm(v) for k,v in c['slices'].items()}}

def main():
    dates,prices=prev.prepare(); dates,prices=filter_from_2002(dates,prices)
    print('COVERAGE',len(dates),dates[0],dates[-1],flush=True)
    candidates=[]; evaluated=0
    weight_grid=[]
    for wg in [0.25,0.30,0.35,0.40,0.45]:
      for wn in [0.40,0.45,0.50,0.55,0.60]:
        ws=round(1.0-wg-wn,4)
        if 0.0 <= ws <= 0.25: weight_grid.append((wg,wn,ws))
    for wg,wn,ws in weight_grid:
      for ma_g in [180,220]:
       for ma_e in [180,220,250]:
        for reb in [20]:
         for mom_lb in [120]:
          for mom_th in [-0.02,0.0]:
           for tv in [0.13,0.15,0.17,0.19]:
            for maxexp in [0.65,0.75,0.85,0.95,1.0]:
             for eq_dd in [0.08,0.12]:
              cfg={'w_gold_cny':wg,'w_nasdaq':wn,'w_sp500':ws,'ma_gold_cny':ma_g,'ma_nasdaq':ma_e,'ma_sp500':ma_e,'rebalance':reb,'mom_lb':mom_lb,'mom_th':mom_th,'target_vol':tv,'max_exposure':maxexp,'vol_lb':60,'brake_lb':60,'eq_dd':eq_dd,'eq_vol':0.28,'eq_scale':0.35,'redeploy_gold':0.75,'band':0.02}
              vals,trades,expo=prev.simulate(dates,prices,cfg); m=base.metrics(dates,vals)
              if not m: continue
              sl={'post_2020':base.slice_metrics(dates,vals,dt.date(2020,1,1)),'last_10y':base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':base.slice_metrics(dates,vals,dt.date(2022,1,1))}
              candidates.append({'cfg':cfg,'metrics':m,'slices':sl,'trades':trades,'exposure':expo,'score':score(m,sl)}); evaluated+=1
    print('EVALUATED',evaluated,'CANDIDATES',len(candidates),flush=True)
    candidates.sort(key=lambda c:(c['score'],c['metrics']['annualized'] or 0),reverse=True)
    def dedupe(items,limit=30):
      out=[]; seen=set()
      for c in items:
        cfg=c['cfg']; fam=(cfg['w_gold_cny'],cfg['w_nasdaq'],cfg['w_sp500'],cfg['ma_gold_cny'],cfg['ma_nasdaq'],cfg['rebalance'],cfg['target_vol'],cfg['max_exposure'],cfg['eq_dd'])
        if fam in seen: continue
        seen.add(fam); out.append(c)
        if len(out)>=limit: break
      return out
    under10=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.10],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under11=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.11],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under12=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.12],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':{'count':len(dates),'start':str(dates[0]),'end':str(dates[-1])},'evaluated':evaluated,'score_top':[simplify(c) for c in dedupe(candidates)],'under10_by_return':[simplify(c) for c in dedupe(under10,20)],'under11_by_return':[simplify(c) for c in dedupe(under11,20)],'under12_by_return':[simplify(c) for c in dedupe(under12,20)]}
    Path('/tmp/atm_no_btc_three_asset_2002_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_no_btc_three_asset_2002_search.json')
    for sec in ['under10_by_return','under11_by_return','under12_by_return','score_top']:
      print('\n==',sec,'==')
      for i,c in enumerate(serial[sec][:10],1):
        m=c['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'],'expo',c['exposure'],'cfg',c['config'])
if __name__=='__main__': main()
