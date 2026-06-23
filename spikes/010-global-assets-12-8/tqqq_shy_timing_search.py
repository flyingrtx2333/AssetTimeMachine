#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, datetime as dt, itertools
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('E', ROOT/'spikes/010-global-assets-12-8/external_etf_12_8.py')
E=importlib.util.module_from_spec(spec); sys.modules['E']=E; spec.loader.exec_module(E)  # type: ignore
OUT=Path('/tmp/atm_tqqq_shy_timing_12_8.json')
ASSETS=['QQQ','SPY','TQQQ','UPRO','QLD','SSO','GLD','SHY']
def fetch_all(): return {s:E.yahoo(s) for s in ASSETS}
def simulate(dates,p,cfg):
    cash=E.START; units={s:0.0 for s in ASSETS}; vals=[]; weights=[]; trades=0; peak=E.START; cool=0
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash+=cash*E.cash_daily(dates[i-1])
        val=cash+sum(units[s]*p[s][i] for s in ASSETS); peak=max(peak,val)
        if i>252 and i%cfg['reb']==0:
            sig=i-1; dd=1-val/peak
            if dd>cfg['dd_stop']: cool=cfg['cool']
            cool=max(0,cool-cfg['reb'])
            qtrend=E.above(p,'QQQ',sig,cfg['ma']) and (E.mom(p['QQQ'],sig,cfg['mom']) or -9)>cfg['mom_th']
            strend=E.above(p,'SPY',sig,cfg['ma']) and (E.mom(p['SPY'],sig,cfg['mom']) or -9)>cfg['mom_th']
            crash=(E.mom(p['QQQ'],sig,21) or 0)<cfg['crash'] or (E.mom(p['SPY'],sig,21) or 0)<cfg['crash']
            target={}
            if cool>0 or crash or not (qtrend and strend):
                if cfg['safe']=='SHY': target={'SHY':cfg['safe_w']}
                elif cfg['safe']=='cash': target={}
                elif cfg['safe']=='GLD' and E.above(p,'GLD',sig,100) and (E.mom(p['GLD'],sig,63) or -9)>0: target={'GLD':cfg['safe_w']}
                else: target={}
            else:
                # risk choice fixed or best of levered by short score.
                if cfg['risk']=='best':
                    rows=[]
                    for r in ['TQQQ','UPRO','QLD','SSO']:
                        sc=(E.mom(p[r],sig,21) or 0)*6+(E.mom(p[r],sig,63) or 0)*3+(E.mom(p[r],sig,126) or 0)
                        if E.above(p,r,sig,60) and sc>0: rows.append((sc,r))
                    risk=sorted(rows,reverse=True)[0][1] if rows else 'TQQQ'
                else: risk=cfg['risk']
                target={risk:cfg['risk_w']}
                if cfg['gold_w']>0 and E.above(p,'GLD',sig,100) and (E.mom(p['GLD'],sig,63) or -9)>0: target['GLD']=cfg['gold_w']
                if cfg['shy_w']>0: target['SHY']=cfg['shy_w']
            cash,units,did=E.trade_to(cash,units,p,i,target,ASSETS,band=cfg['band'])
            if did: trades+=1
            val=cash+sum(units[s]*p[s][i] for s in ASSETS)
        vals.append(val); weights.append({s:units[s]*p[s][i]/val for s in ASSETS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0,1-sum(weights[-1].values()))}
def run():
    series=fetch_all(); dates,p=E.align(series,ASSETS,dt.date(2011,1,3))
    cfgs=[]
    for reb in [1,5,10,21]:
     for ma in [80,100,120,150,200]:
      for mom in [21,63,126]:
       for risk in ['TQQQ','UPRO','QLD','SSO','best']:
        for risk_w in [0.15,0.20,0.25,0.30,0.35,0.45,0.55]:
         for gold_w in [0.0,0.15,0.25]:
          for dd_stop in [0.04,0.06,0.08,0.10]:
           cfgs.append({'reb':reb,'ma':ma,'mom':mom,'mom_th':0.0,'risk':risk,'risk_w':risk_w,'gold_w':gold_w,'shy_w':0.0,'safe':'SHY','safe_w':0.95,'dd_stop':dd_stop,'cool':42,'crash':-0.08,'band':0.02})
    rows=[]
    for n,cfg in enumerate(cfgs):
        vals,w,e=simulate(dates,p,cfg); m=E.all_metrics(dates,vals)
        rows.append({'name':f'T{n:05d}','cfg':cfg,'metrics':m,'extra':e,'top_dd':E.topdds(dates,vals,w)})
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'rows',len(rows),'coverage',dates[0],dates[-1],len(dates))
    passed=[r for r in rows if r['metrics']['full']['ann']>=0.12 and r['metrics']['full']['dd']<=0.08]
    print('PASS_COUNT',len(passed))
    for r in sorted(passed,key=lambda r:r['metrics']['full']['ann'],reverse=True)[:30]:
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; print('PASS',r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'trades',r['extra']['trades'],'cfg',r['cfg'])
    print('TOP DD<=12')
    for r in sorted([r for r in rows if r['metrics']['full']['dd']<=0.12],key=lambda r:r['metrics']['full']['ann'],reverse=True)[:30]:
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; mark='PASS' if m['ann']>=0.12 and m['dd']<=0.08 else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'trades',r['extra']['trades'],'cfg',r['cfg'])
    print('TOP OVERALL')
    for r in sorted(rows,key=lambda r:r['metrics']['full']['ann'],reverse=True)[:10]:
        m=r['metrics']['full']; print(r['name'],f"{m['ann']*100:.2f}/{m['dd']*100:.2f}",r['cfg'])
if __name__=='__main__': run()
