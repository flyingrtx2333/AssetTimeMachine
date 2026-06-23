#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt
from pathlib import Path

spec=importlib.util.spec_from_file_location('exp','/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine/spikes/003-no-btc-2001-strategy/search_no_btc_2001_expanded_universe.py')
EXP=importlib.util.module_from_spec(spec); sys.modules['exp']=EXP; spec.loader.exec_module(EXP)  # type: ignore
base=EXP.base
OUT=Path('/tmp/atm_expanded_universe_focused.json')

def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}

def score(m,sl):
    ann=m['annualized'] or 0; dd=m['max_drawdown']; sh=m['sharpe'] or 0
    p20=sl['post_2020']['annualized'] or 0; y10=sl['last_10y']['annualized'] or 0
    return ann*4+p20+y10+sh*.25-dd*5-max(dd-.10,0)*20

def main():
    dates,prices,cov=EXP.load_expanded(); c=EXP.build_cache(prices)
    cfgs=[]
    for canaries in [['nasdaq','sp500'],['nasdaq','sp500','hang_seng'],['nasdaq','sp500','wti']]:
      for weak_allowed in [0,1]:
       for top_n in [1,2,3]:
        for rebalance in [10,20,30]:
         for risk_weight in [0.45,0.55,0.65,0.75]:
          for gold_ballast in [0.20,0.30,0.40]:
           for def_gold in [0.0,0.35,0.55,0.75]:
            for cn_cap in [0.10,0.20,0.30]:
             for us_cap in [0.35,0.50,0.65]:
              cfgs.append({
                'canaries':canaries,'mom_lbs':[20,60,120,240],'mom_weights':[12,4,2,1],
                'weak_allowed':weak_allowed,'top_n':top_n,'rebalance':rebalance,
                'canary_ma':180,'asset_ma':180,'gold_ma':220,
                'risk_weight':risk_weight,'gold_ballast':gold_ballast,'def_gold':def_gold,
                'vol_cap':0.45,'dd_cap':0.12,
                'cn_cap':cn_cap,'cn_hot_cap':0.12,'us_cap':us_cap,'wti_cap':0.12,
                'cut_to_gold':0.65,'gold_max':0.70,'gold_hot_cap':0.35,
                'max_exposure':0.95,'band':0.02,
              })
    rows=[]
    for n,cfg in enumerate(cfgs,1):
        sim=EXP.simulate(dates,prices,c,cfg); vals=sim['values']; m=base.metrics(dates,vals)
        sl={'post_2020':base.slice_metrics(dates,vals,dt.date(2020,1,1)),'last_10y':base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':base.slice_metrics(dates,vals,dt.date(2022,1,1))}
        if (m['annualized'] or 0)>=0.055 and m['max_drawdown']<=0.14:
            rows.append({'score':score(m,sl),'cfg':cfg,'metrics':sm(m),'slices':{k:sm(v) for k,v in sl.items()},'trades':sim['trades'],'exposure':round(sim['exposure'],4),'max_dd_episode':EXP.mdd_episode(dates,vals)})
        if n%1000==0: print('eval',n,'kept',len(rows),flush=True)
    rows.sort(key=lambda r:(r['metrics']['max_drawdown']<=.10,r['metrics']['annualized'],r['score']), reverse=True)
    serial={'coverage':cov,'evaluated':len(cfgs),'kept':len(rows),'under10_by_return':[r for r in rows if r['metrics']['max_drawdown']<=.10][:30],'under12_by_return':[r for r in rows if r['metrics']['max_drawdown']<=.12][:30],'score_top':sorted(rows,key=lambda r:r['score'],reverse=True)[:30]}
    OUT.write_text(json.dumps(serial,ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'eval',len(cfgs),'kept',len(rows),'under10',len(serial['under10_by_return']))
    for sec in ['under10_by_return','under12_by_return','score_top']:
        print('\n==',sec,'==')
        for i,r in enumerate(serial[sec][:10],1):
            m=r['metrics']; p=r['slices']['post_2020']; y=r['slices']['last_10y']
            print(i,f"ann={m['annualized']*100:.2f}% dd={m['max_drawdown']*100:.2f}% sh={m['sharpe']:.2f}",f"p20={p['annualized']*100:.2f}/{p['max_drawdown']*100:.2f}",f"y10={y['annualized']*100:.2f}/{y['max_drawdown']*100:.2f}",'ep',r['max_dd_episode'],'cfg',r['cfg'])
if __name__=='__main__': main()
