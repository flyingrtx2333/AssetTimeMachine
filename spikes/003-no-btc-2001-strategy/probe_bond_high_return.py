#!/usr/bin/env python3
"""High-return side probe for bond-defense universe."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("bd", HERE / "search_no_btc_2001_bond_defense.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load bond defense")
bd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bd)


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def main() -> None:
    dates, prices, coverage = bd.load_with_bonds()
    cache = bd.build_cache(prices)
    cfgs=[]
    for canaries in [["nasdaq","sp500"],["nasdaq","sp500","hang_seng"]]:
      for weak_allowed in [0,1]:
       for rebalance in [5,10]:
        for risk_weight in [0.65,0.75,0.85]:
         for def_ballast in [0.0,0.10,0.20]:
          for def_weight in [0.35,0.55,0.70]:
           for pf_brake_dd in [0.055,0.075,9.0]:
            cfgs.append({
                "canaries": canaries, "mom_lbs": [60,120,240], "mom_weights": [4,2,1],
                "weak_allowed": weak_allowed, "rebalance": rebalance,
                "risk_top_n": 3, "def_top_n": 2,
                "canary_ma": 180, "asset_ma": 180, "def_ma": 120,
                "risk_weight": risk_weight, "def_ballast": def_ballast, "def_weight": def_weight,
                "vol_cap": 0.45, "dd_cap": 0.16,
                "cn_cap": 0.30, "us_cap": 0.50, "wti_cap": 0.12, "bond_cap": 0.85, "def_each_cap": 0.55,
                "cut_to_def": 0.70, "gold_hot_cap": 0.25,
                "pf_brake_dd": pf_brake_dd, "pf_brake_scale": 0.65, "pf_brake_def_add": 0.10,
                "max_exposure": 0.95, "band": 0.02,
            })
    results=[]
    for cfg in cfgs:
        sim=bd.simulate(dates,prices,cache,cfg); vals=sim['values']
        m=bd.exp.base.metrics(dates,vals)
        sl={
            'post_2020':bd.exp.base.slice_metrics(dates,vals,dt.date(2020,1,1)),
            'last_10y':bd.exp.base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),
            'post_2022':bd.exp.base.slice_metrics(dates,vals,dt.date(2022,1,1)),
        }
        results.append({'config':cfg,'metrics':m,'slices':sl,'trades':sim['trades'],'exposure':sim['exposure'],'max_dd_episode':bd.exp.mdd_episode(dates,vals)})
    by_return=sorted(results,key=lambda x:x['metrics']['annualized'] or 0, reverse=True)
    under12=sorted([x for x in results if x['metrics']['max_drawdown']<=0.12],key=lambda x:x['metrics']['annualized'] or 0, reverse=True)
    under13=sorted([x for x in results if x['metrics']['max_drawdown']<=0.13],key=lambda x:x['metrics']['annualized'] or 0, reverse=True)
    def simp(x): return {'metrics':sm(x['metrics']),'slices':{k:sm(v) for k,v in x['slices'].items()},'config':x['config'],'trades':x['trades'],'exposure':round(x['exposure'],4),'max_dd_episode':x['max_dd_episode']}
    serial={'coverage':coverage,'evaluated':len(results),'return_top':[simp(x) for x in by_return[:30]],'under12_by_return':[simp(x) for x in under12[:30]],'under13_by_return':[simp(x) for x in under13[:30]]}
    out=Path('/tmp/atm_no_btc_2001_bond_high_return_probe.json'); out.write_text(json.dumps(serial,ensure_ascii=False,indent=2,default=str))
    print('EVALUATED',len(results),'WROTE',out)
    for sec in ['under12_by_return','under13_by_return','return_top']:
        print('\n==',sec,'==')
        for i,x in enumerate(serial[sec][:10],1):
            m=x['metrics']; p20=x['slices']['post_2020']; y10=x['slices']['last_10y']
            print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'p20',f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}",'y10',f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}",'dd',x['max_dd_episode'],'cfg',x['config'])

if __name__=='__main__': main()
