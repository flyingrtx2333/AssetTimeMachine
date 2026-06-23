#!/usr/bin/env python3
from __future__ import annotations
import datetime as dt, importlib.util, json, math
from pathlib import Path
spec=importlib.util.spec_from_file_location('s','tools/search_no_btc_2002_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load failed')
s=importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
base=s.base; INITIAL=100000.0; FEE=.001; SLIP=.0005

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

def simulate(dates,prices,cfg):
    mas={(sym,n):ma(prices[sym],n) for sym in s.SYMS for n in [120,180,220,260]}
    cash=INITIAL; units={sym:0.0 for sym in s.SYMS}; vals=[]; trades=0; exposure=0; last=-10**9
    for i,d in enumerate(dates):
        def pv(): return cash+sum(units[x]*prices[x][i] for x in s.SYMS)
        if i>0 and i-last>=cfg['rebalance']:
            sig=i-1; ranked=[]
            for sym in s.SYMS:
                ma_n=cfg['gold_ma'] if sym=='gold_cny' else cfg['eq_ma']
                mavg=mas[(sym,ma_n)][sig]; mo=mom(prices[sym],sig,cfg['mom_lb']); vv=vol(prices[sym],sig,cfg['vol_lb']); ddd=dd(prices[sym],sig,cfg['dd_lb'])
                if mavg is None or mo is None: continue
                vol_cap=cfg['gold_vol_cap'] if sym=='gold_cny' else cfg['eq_vol_cap']
                dd_cap=cfg['gold_dd_cap'] if sym=='gold_cny' else cfg['eq_dd_cap']
                if prices[sym][sig]>mavg and mo>cfg['mom_th'] and (vv is None or vv<vol_cap) and (ddd is None or ddd>-dd_cap):
                    # score balances momentum and volatility, lets gold compete fairly
                    ranked.append((mo/max(vv or cfg['fallback_vol'],0.05),sym))
            ranked.sort(reverse=True); selected=[sym for _,sym in ranked[:cfg['top_n']]]
            target={sym:0.0 for sym in s.SYMS}
            if selected:
                inv={}
                for sym in selected:
                    vv=vol(prices[sym],sig,cfg['vol_lb']) or cfg['fallback_vol']; inv[sym]=1/max(vv,0.05)
                total_inv=sum(inv.values())
                for sym in selected: target[sym]=cfg['max_exposure']*inv[sym]/total_inv
            # vol target
            pvvol=sum(target[sym]*(vol(prices[sym],sig,cfg['vol_lb']) or 0) for sym in s.SYMS)
            if pvvol>0:
                scale=min(1.0,cfg['target_vol']/pvvol)
                for sym in target: target[sym]*=scale
            # portfolio dd throttle
            if len(vals)>=120:
                peak=max(vals[-120:]); pdd=vals[-1]/peak-1 if peak>0 else 0
                if pdd<-cfg['pf_hard_dd']:
                    for sym in target: target[sym]*=cfg['pf_hard_scale']
                elif pdd<-cfg['pf_soft_dd']:
                    for sym in target: target[sym]*=cfg['pf_soft_scale']
            total=pv()
            for sym in s.SYMS:
                cur=units[sym]*prices[sym][i]; tgt=total*target[sym]
                if cur>tgt*(1+cfg['band']):
                    su=min(units[sym],(cur-tgt)/prices[sym][i])
                    if su>0: cash+=su*prices[sym][i]*(1-SLIP)*(1-FEE); units[sym]-=su; trades+=1
            total=pv()
            for sym in s.SYMS:
                cur=units[sym]*prices[sym][i]; tgt=total*target[sym]
                if cur<tgt*(1-cfg['band']):
                    amt=min(cash,tgt-cur)
                    if amt>1: units[sym]+=amt*(1-FEE)/(prices[sym][i]*(1+SLIP)); cash-=amt; trades+=1
            last=i
        v=pv(); vals.append(v); exposure += sum(units[x]*prices[x][i] for x in s.SYMS)/v if v>0 else 0
    return vals,trades,exposure/len(vals)

def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
def score(m,sl):
    ann=m['annualized'] or 0; d=m['max_drawdown']; sh=m['sharpe'] or 0
    p=sl['post_2020'] or {}; y=sl['last_10y'] or {}; z=sl['post_2022'] or {}
    return ann*1.5+(p.get('annualized') or 0)*.35+(y.get('annualized') or 0)*.25+(z.get('annualized') or 0)*.15+sh*.2-d*1.7-max(d-.10,0)*8

def simp(c): return {'score':round(c['score'],6),'config':c['cfg'],'trades':c['trades'],'exposure':round(c['exposure'],4),'metrics':sm(c['metrics']),'slices':{k:sm(v) for k,v in c['slices'].items()}}

def main():
    dates,prices,cov=s.load_aligned(); print('COVERAGE',cov['aligned'],flush=True)
    candidates=[]; evaluated=0
    for top_n in [1,2]:
      for mom_lb in [90,120]:
       for mom_th in [-.02,0.0]:
        for eq_ma in [180,220]:
         for gold_ma in [180,220]:
          for target_vol in [.11,.13,.15,.17]:
           for maxexp in [.55,.65,.75,.85]:
            cfg={'top_n':top_n,'mom_lb':mom_lb,'mom_th':mom_th,'eq_ma':eq_ma,'gold_ma':gold_ma,'vol_lb':60,'dd_lb':60,'gold_vol_cap':.38,'eq_vol_cap':.40,'gold_dd_cap':.18,'eq_dd_cap':.16,'fallback_vol':.18,'target_vol':target_vol,'max_exposure':maxexp,'pf_soft_dd':.06,'pf_hard_dd':.10,'pf_soft_scale':.65,'pf_hard_scale':.35,'rebalance':20,'band':.02}
            vals,trades,expo=simulate(dates,prices,cfg); m=base.metrics(dates,vals)
            if not m: continue
            sl={'post_2020':base.slice_metrics(dates,vals,dt.date(2020,1,1)),'last_10y':base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':base.slice_metrics(dates,vals,dt.date(2022,1,1))}
            candidates.append({'cfg':cfg,'metrics':m,'slices':sl,'trades':trades,'exposure':expo,'score':score(m,sl)}); evaluated+=1
    print('EVALUATED',evaluated,'CANDIDATES',len(candidates),flush=True)
    candidates.sort(key=lambda c:(c['score'],c['metrics']['annualized'] or 0),reverse=True)
    def dedupe(items,limit=30):
      out=[]; seen=set()
      for c in items:
        cfg=c['cfg']; fam=(cfg['top_n'],cfg['mom_lb'],cfg['mom_th'],cfg['eq_ma'],cfg['gold_ma'],cfg['target_vol'],cfg['max_exposure'])
        if fam in seen: continue
        seen.add(fam); out.append(c)
        if len(out)>=limit: break
      return out
    under10=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.10],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under11=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.11],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under12=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.12],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':cov,'evaluated':evaluated,'score_top':[simp(c) for c in dedupe(candidates)],'under10_by_return':[simp(c) for c in dedupe(under10,20)],'under11_by_return':[simp(c) for c in dedupe(under11,20)],'under12_by_return':[simp(c) for c in dedupe(under12,20)]}
    Path('/tmp/atm_no_btc_dual_momentum_2002_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_no_btc_dual_momentum_2002_search.json')
    for sec in ['under10_by_return','under11_by_return','under12_by_return','score_top']:
      print('\n==',sec,'==')
      for i,c in enumerate(serial[sec][:10],1):
        m=c['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'],'expo',c['exposure'],'cfg',c['config'])
if __name__=='__main__': main()
