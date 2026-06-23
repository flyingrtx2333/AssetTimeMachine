#!/usr/bin/env python3
"""No-BTC 2002 full-cycle: VAA/PAA-style canary regime allocation.

No asset universe change. Offensive assets are existing equity indices; defensive asset is existing gold_cny; cash otherwise.
"""
from __future__ import annotations
import datetime as dt, importlib.util, json, math
from pathlib import Path

spec=importlib.util.spec_from_file_location('nb','tools/search_no_btc_2002_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load failed')
nb=importlib.util.module_from_spec(spec); spec.loader.exec_module(nb)
base=nb.base; INITIAL=100000.0; FEE=.001; SLIP=.0005
SYMS=nb.SYMS
OFF=['nasdaq','sp500','dowjones','csi300','shanghai_composite']
CANARIES=[['nasdaq','sp500'],['nasdaq','sp500','csi300'],['nasdaq','sp500','dowjones'],['nasdaq','csi300']]

def ma(vals,n):
    out=[None]*len(vals); rs=0.0
    for i,v in enumerate(vals):
        rs+=v
        if i>=n: rs-=vals[i-n]
        if i>=n-1: out[i]=rs/n
    return out

def ret(vals,i,n):
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

def build_cache(prices):
    c={'ma':{},'ret':{},'vol':{}}
    for s in SYMS:
        for n in [80,120,180,200,220,260]: c['ma'][(s,n)]=ma(prices[s],n)
        for n in [20,40,60,80,120,160,180,240]: c['ret'][(s,n)]=[ret(prices[s],i,n) for i in range(len(prices[s]))]
        for n in [40,60,90]: c['vol'][(s,n)]=[vol(prices[s],i,n) for i in range(len(prices[s]))]
    return c

def multi_mom(c,s,i,lbs,weights):
    total=0.0
    for lb,w in zip(lbs,weights):
        r=c['ret'][(s,lb)][i]
        if r is None: return None
        total += w*r
    return total

def simulate(dates,prices,c,cfg):
    cash=INITIAL; units={s:0.0 for s in SYMS}; vals=[]; trades=0; exposure=0; last=-10**9
    for i,d in enumerate(dates):
        def pv(): return cash+sum(units[s]*prices[s][i] for s in SYMS)
        if i>0 and i-last>=cfg['rebalance']:
            sig=i-1
            # Canary: if too many canaries have weak multi-momentum or below long MA, go defensive.
            weak=0
            for s in cfg['canaries']:
                mm=multi_mom(c,s,sig,cfg['mom_lbs'],cfg['mom_weights'])
                ma_v=c['ma'][(s,cfg['canary_ma'])][sig]
                if mm is None or ma_v is None or mm<cfg['canary_mom_th'] or prices[s][sig]<ma_v: weak+=1
            risk_on = weak <= cfg['weak_allowed']
            target={s:0.0 for s in SYMS}
            if risk_on:
                ranked=[]
                for s in OFF:
                    mm=multi_mom(c,s,sig,cfg['mom_lbs'],cfg['mom_weights'])
                    ma_v=c['ma'][(s,cfg['asset_ma'])][sig]
                    vv=c['vol'][(s,60)][sig]
                    if mm is None or ma_v is None: continue
                    if mm>cfg['asset_mom_th'] and prices[s][sig]>ma_v and (vv is None or vv<cfg['eq_vol_cap']):
                        score=mm/max(vv or .18,.05)
                        ranked.append((score,s))
                ranked.sort(reverse=True); selected=[s for _,s in ranked[:cfg['top_n']]]
                if selected:
                    off_weight=cfg['offensive_weight']
                    if cfg['equal_weight']:
                        for s in selected: target[s]=off_weight/len(selected)
                    else:
                        inv={s:1/max(c['vol'][(s,60)][sig] or .18,.05) for s in selected}; sm=sum(inv.values())
                        for s in selected: target[s]=off_weight*inv[s]/sm
                # Gold ballast if gold positive; otherwise leave as cash.
                gmm=multi_mom(c,'gold_cny',sig,cfg['mom_lbs'],cfg['mom_weights'])
                gma=c['ma'][('gold_cny',cfg['gold_ma'])][sig]
                if gmm is not None and gma is not None and gmm>cfg['gold_mom_th'] and prices['gold_cny'][sig]>gma:
                    target['gold_cny']=cfg['gold_ballast']
            else:
                gmm=multi_mom(c,'gold_cny',sig,cfg['mom_lbs'],cfg['mom_weights'])
                gma=c['ma'][('gold_cny',cfg['gold_ma'])][sig]
                if gmm is not None and gma is not None and gmm>cfg['gold_mom_th'] and prices['gold_cny'][sig]>gma:
                    target['gold_cny']=cfg['defensive_gold']
            gross=sum(target.values())
            if gross>cfg['max_exposure'] and gross>0:
                for s in target: target[s]*=cfg['max_exposure']/gross
            total=pv()
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target[s]
                if cur>tgt*(1+cfg['band']):
                    su=min(units[s],(cur-tgt)/prices[s][i])
                    if su>0: cash+=su*prices[s][i]*(1-SLIP)*(1-FEE); units[s]-=su; trades+=1
            total=pv()
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target[s]
                if cur<tgt*(1-cfg['band']):
                    amt=min(cash,tgt-cur)
                    if amt>1: units[s]+=amt*(1-FEE)/(prices[s][i]*(1+SLIP)); cash-=amt; trades+=1
            last=i
        v=pv(); vals.append(v); exposure += sum(units[s]*prices[s][i] for s in SYMS)/v if v>0 else 0
    return vals,trades,exposure/len(vals)

def score(m,sl):
    ann=m['annualized'] or 0; d=m['max_drawdown']; sh=m['sharpe'] or 0
    p=sl['post_2020'] or {}; y=sl['last_10y'] or {}; z=sl['post_2022'] or {}
    return ann*1.65+(p.get('annualized') or 0)*.25+(y.get('annualized') or 0)*.20+(z.get('annualized') or 0)*.12+sh*.22-d*1.5-max(d-.10,0)*8

def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
def simp(cand): return {'score':round(cand['score'],6),'trades':cand['trades'],'exposure':round(cand['exposure'],4),'config':cand['cfg'],'metrics':sm(cand['metrics']),'slices':{k:sm(v) for k,v in cand['slices'].items()}}

def main():
    dates,prices,cov=nb.load_aligned(); print('COVERAGE',cov['aligned'],flush=True)
    c=build_cache(prices); candidates=[]; evaluated=0
    mom_sets=[([20,60,120],[12,4,2]),([20,60,120,240],[12,4,2,1]),([60,120,240],[4,2,1]),([40,80,160],[6,3,1])]
    for canaries in [CANARIES[0], CANARIES[1]]:
      for mom_lbs,mom_weights in mom_sets[:3]:
       for weak_allowed in [0,1]:
        for top_n in [1,2]:
         for reb in [20]:
          for canary_ma in [180,220]:
           for asset_ma in [180,220]:
            for gold_ma in [180,220]:
             for off_w in [.25,.35,.45,.55,.65]:
              for gold_ballast in [0,.15,.25]:
               for def_gold in [.25,.35,.45,.55]:
                gross=off_w+gold_ballast
                if gross>1.0: continue
                cfg={'canaries':canaries,'mom_lbs':mom_lbs,'mom_weights':mom_weights,'weak_allowed':weak_allowed,'top_n':top_n,'rebalance':reb,'canary_ma':canary_ma,'asset_ma':asset_ma,'gold_ma':gold_ma,'canary_mom_th':0.0,'asset_mom_th':0.0,'gold_mom_th':0.0,'eq_vol_cap':.45,'offensive_weight':off_w,'gold_ballast':gold_ballast,'defensive_gold':def_gold,'max_exposure':.95,'equal_weight':False,'band':.02}
                vals,trades,expo=simulate(dates,prices,c,cfg); m=base.metrics(dates,vals)
                if not m: continue
                sl={'post_2020':base.slice_metrics(dates,vals,dt.date(2020,1,1)),'last_10y':base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':base.slice_metrics(dates,vals,dt.date(2022,1,1))}
                candidates.append({'cfg':cfg,'metrics':m,'slices':sl,'trades':trades,'exposure':expo,'score':score(m,sl)}); evaluated+=1
    print('EVALUATED',evaluated,'CANDIDATES',len(candidates),flush=True)
    candidates.sort(key=lambda x:(x['score'],x['metrics']['annualized'] or 0),reverse=True)
    def dedupe(items,limit=30):
        out=[]; seen=set()
        for cnd in items:
            cfg=cnd['cfg']; key=(tuple(cfg['canaries']),tuple(cfg['mom_lbs']),cfg['weak_allowed'],cfg['top_n'],cfg['rebalance'],cfg['canary_ma'],cfg['asset_ma'],cfg['gold_ma'],cfg['offensive_weight'],cfg['gold_ballast'],cfg['defensive_gold'])
            if key in seen: continue
            seen.add(key); out.append(cnd)
            if len(out)>=limit: break
        return out
    under10=sorted([x for x in candidates if x['metrics']['max_drawdown']<=.10],key=lambda x:x['metrics']['annualized'] or 0,reverse=True)
    under11=sorted([x for x in candidates if x['metrics']['max_drawdown']<=.11],key=lambda x:x['metrics']['annualized'] or 0,reverse=True)
    under12=sorted([x for x in candidates if x['metrics']['max_drawdown']<=.12],key=lambda x:x['metrics']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':cov,'evaluated':evaluated,'score_top':[simp(x) for x in dedupe(candidates)],'under10_by_return':[simp(x) for x in dedupe(under10,20)],'under11_by_return':[simp(x) for x in dedupe(under11,20)],'under12_by_return':[simp(x) for x in dedupe(under12,20)]}
    Path('/tmp/atm_no_btc_vaa_paa_2002_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_no_btc_vaa_paa_2002_search.json')
    for sec in ['under10_by_return','under11_by_return','under12_by_return','score_top']:
        print('\n==',sec,'==')
        for i,x in enumerate(serial[sec][:10],1):
            m=x['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',x['trades'],'expo',x['exposure'],'cfg',x['config'])
if __name__=='__main__': main()
