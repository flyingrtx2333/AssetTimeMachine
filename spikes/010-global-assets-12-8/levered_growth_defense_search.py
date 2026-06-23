#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, itertools, json, datetime as dt, math
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('E', ROOT/'spikes/010-global-assets-12-8/external_etf_12_8.py')
E=importlib.util.module_from_spec(spec); sys.modules['E']=E; spec.loader.exec_module(E)  # type: ignore
OUT=Path('/tmp/atm_levered_growth_defense_12_8.json')
ASSETS=['QQQ','SPY','TQQQ','UPRO','QLD','SSO','GLD','TLT','IEF','SHY','TMF','UBT']
TARGET_ANN=0.12; TARGET_DD=0.08

def fetch_all(): return {s:E.yahoo(s) for s in ASSETS}
def score(p,s,i,lbs,ws):
    total=0
    for n,w in zip(lbs,ws):
        m=E.mom(p[s],i,n)
        if m is None: return None
        total+=w*m
    return total

def best_safe(p,i,safes):
    rows=[]
    for s in safes:
        sc=score(p,s,i,(21,63,126),(6,3,1))
        if sc is None: continue
        ok=(E.mom(p[s],i,63) or -9)>0 and E.above(p,s,i,60)
        if ok: rows.append((sc,s))
    rows=sorted(rows,reverse=True)
    return rows[0][1] if rows else 'SHY'

def simulate_cfg(dates,p,cfg):
    assets=ASSETS; cash=E.START; units={s:0.0 for s in assets}; vals=[]; weights=[]; trades=0; peak=E.START; state={'cool':0}
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash+=cash*E.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in assets); peak=max(peak,val)
        if i>cfg['warmup'] and i%cfg['reb']==0:
            sig=i-1; dd=1-val/peak
            if dd>cfg['dd_stop']: state['cool']=cfg['cool']
            state['cool']=max(0,state.get('cool',0)-cfg['reb'])
            q_ok=E.above(p,'QQQ',sig,cfg['ma']) and (E.mom(p['QQQ'],sig,cfg['mom_lb']) or -9)>cfg['mom_th']
            s_ok=E.above(p,'SPY',sig,cfg['ma']) and (E.mom(p['SPY'],sig,cfg['mom_lb']) or -9)>cfg['mom_th']
            crash=(E.mom(p['QQQ'],sig,21) or 0)<cfg['crash21'] or (E.mom(p['SPY'],sig,21) or 0)<cfg['crash21']
            target={}
            if state['cool']>0 or crash or not (q_ok and s_ok):
                safe=best_safe(p,sig,cfg['safes'])
                target={safe:cfg['safe_w']}
            else:
                # choose risk sleeve by momentum among risk candidates
                rows=[]
                for r in cfg['risks']:
                    sc=score(p,r,sig,(21,63,126),(6,3,1))
                    if sc is not None and sc>0 and E.above(p,r,sig,60): rows.append((sc,r))
                if rows:
                    risk=sorted(rows,reverse=True)[0][1]
                    target={risk:cfg['risk_w']}
                    # ballast only if positive trend
                    bal=best_safe(p,sig,cfg['ballasts'])
                    if bal!='SHY': target[bal]=cfg['ballast_w']
                    else: target['SHY']=cfg['cash_proxy_w']
                else:
                    target={best_safe(p,sig,cfg['safes']):cfg['safe_w']}
            cash,units,did=E.trade_to(cash,units,p,i,target,assets,band=cfg['band'])
            if did: trades+=1
            val=cash+sum(units[s]*p[s][i] for s in assets)
        vals.append(val); weights.append({s:units[s]*p[s][i]/val for s in assets if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0,1-sum(weights[-1].values()))}

def run():
    series=fetch_all(); dates,p=E.align(series,ASSETS,dt.date(2011,1,3))
    cfgs=[]
    for reb in [5,10,21]:
      for ma in [100,150,200]:
       for mom_lb in [63,126]:
        for risk_w in [0.25,0.35,0.45,0.55]:
         for ballast_w in [0.0,0.15,0.25,0.35]:
          for dd_stop in [0.05,0.07,0.09,0.12]:
           cfgs.append({
            'reb':reb,'ma':ma,'mom_lb':mom_lb,'mom_th':0.0,'risk_w':risk_w,'ballast_w':ballast_w,'cash_proxy_w':0.20,
            'dd_stop':dd_stop,'cool':42,'crash21':-0.08,'safe_w':0.80,'band':0.02,'warmup':252,
            'risks':['TQQQ','UPRO','QLD','SSO'],'safes':['GLD','TLT','IEF','SHY','TMF','UBT'],'ballasts':['GLD','TLT','IEF']})
    rows=[]
    best=[]
    for n,cfg in enumerate(cfgs):
        vals,w,e=simulate_cfg(dates,p,cfg)
        m=E.all_metrics(dates,vals)
        row={'name':f'L{n:04d}','cfg':cfg,'metrics':m,'extra':e,'top_dd':E.topdds(dates,vals,w)}
        rows.append(row)
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'rows',len(rows),'coverage',dates[0],dates[-1],len(dates))
    print('PASS:')
    passed=[r for r in rows if r['metrics']['full']['ann']>=TARGET_ANN and r['metrics']['full']['dd']<=TARGET_DD]
    for r in sorted(passed,key=lambda r:r['metrics']['full']['ann'],reverse=True)[:20]:
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']
        print(r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cfg',r['cfg'])
    print('TOP BY ANN WITH DD<=12:')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.12],key=lambda r:r['metrics']['full']['ann'],reverse=True)[:20]:
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']
        mark='PASS' if m['ann']>=TARGET_ANN and m['dd']<=TARGET_DD else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'trades',r['extra']['trades'],'cfg',r['cfg'])
    print('TOP OVERALL:')
    for r in sorted(rows,key=lambda r:r['metrics']['full']['ann'],reverse=True)[:10]:
        m=r['metrics']['full']; print(r['name'],f"{m['ann']*100:.2f}/{m['dd']*100:.2f}",r['cfg'])
if __name__=='__main__': run()
