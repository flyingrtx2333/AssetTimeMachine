#!/usr/bin/env python3
from __future__ import annotations
import datetime as dt, importlib.util, json, math
from pathlib import Path

spec=importlib.util.spec_from_file_location('s','tools/search_no_btc_2002_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load failed')
s=importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
base=s.base; INITIAL=100000.0; FEE=0.001; SLIP=0.0005

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
    rets=[]
    for j in range(i-n+1,i+1):
        if vals[j-1]>0 and vals[j]>0: rets.append(math.log(vals[j]/vals[j-1]))
    if len(rets)<2: return None
    m=sum(rets)/len(rets); var=sum((x-m)**2 for x in rets)/(len(rets)-1)
    return math.sqrt(var)*math.sqrt(252)

def dd(vals,i,n):
    if i-n+1<0: return None
    w=vals[i-n+1:i+1]; p=max(w)
    return vals[i]/p-1 if p>0 else None

def metrics(dates,vals): return base.metrics(dates,vals)
def slice_m(dates,vals,start): return base.slice_metrics(dates,vals,start)
def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}

def make_basket(prices, weights):
    n=len(next(iter(prices.values()))); vals=[]
    for i in range(n):
        vals.append(sum(w*prices[sym][i]/prices[sym][0] for sym,w in weights.items()))
    return vals

def simulate(dates,prices,cfg):
    basket=make_basket(prices,cfg['risk_weights'])
    basket_ma=ma(basket,cfg['basket_ma']); gold_ma=ma(prices['gold_cny'],cfg['gold_ma'])
    cash=INITIAL; units={sym:0.0 for sym in s.SYMS}; vals=[]; trades=0; exposure=0; last=-10**9
    for i,d in enumerate(dates):
        def pv(): return cash+sum(units[x]*prices[x][i] for x in s.SYMS)
        if i>0 and i-last>=cfg['rebalance']:
            sig=i-1
            b_mom=mom(basket,sig,cfg['basket_mom']); b_vol=vol(basket,sig,cfg['vol_lb']); b_dd=dd(basket,sig,cfg['dd_lb'])
            trend=basket_ma[sig] is not None and basket[sig]>basket_ma[sig]
            risk_on=trend and b_mom is not None and b_mom>cfg['basket_mom_th'] and (b_vol is None or b_vol<cfg['basket_vol_cap']) and (b_dd is None or b_dd>-cfg['basket_dd_cap'])
            gold_ok=gold_ma[sig] is not None and prices['gold_cny'][sig]>gold_ma[sig] and (mom(prices['gold_cny'],sig,120) or -9)>-0.02
            target={sym:0.0 for sym in s.SYMS}
            if risk_on:
                for sym,w in cfg['risk_weights'].items(): target[sym]=w
            elif gold_ok:
                target['gold_cny']=cfg['riskoff_gold']
            # vol targeting by basket vol / gold vol depending target
            port_vol=0.0
            for sym,w in target.items():
                if w<=0: continue
                port_vol += w*(vol(prices[sym],sig,cfg['vol_lb']) or 0)
            gross=sum(target.values()); scale=1.0
            if port_vol>0: scale=min(scale,cfg['target_vol']/port_vol)
            if gross>0: scale=min(scale,cfg['max_exposure']/gross)
            # portfolio dd governor
            if len(vals)>=120:
                recent=vals[-120:]; peak=max(recent); pdd=vals[-1]/peak-1 if peak>0 else 0
                if pdd<-cfg['pf_hard_dd']: scale*=cfg['pf_hard_scale']
                elif pdd<-cfg['pf_soft_dd']: scale*=cfg['pf_soft_scale']
            for sym in target: target[sym]*=scale
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

def score(m,sl):
    ann=m['annualized'] or 0; d=m['max_drawdown']; sh=m['sharpe'] or 0
    p=sl['post_2020'] or {}; y=sl['last_10y'] or {}; z=sl['post_2022'] or {}
    return ann*1.5+(p.get('annualized') or 0)*.35+(y.get('annualized') or 0)*.25+(z.get('annualized') or 0)*.15+sh*.2-d*1.75-max(d-.10,0)*8

def simp(c): return {'score':round(c['score'],6),'config':c['cfg'],'trades':c['trades'],'exposure':round(c['exposure'],4),'metrics':sm(c['metrics']),'slices':{k:sm(v) for k,v in c['slices'].items()}}

def main():
    dates,prices,cov=s.load_aligned(); print('COVERAGE',cov['aligned'],flush=True)
    risk_weights=[
      {'gold_cny':.60,'nasdaq':.30,'sp500':.10,'csi300':.00},
      {'gold_cny':.55,'nasdaq':.30,'sp500':.10,'csi300':.05},
      {'gold_cny':.50,'nasdaq':.35,'sp500':.10,'csi300':.05},
      {'gold_cny':.45,'nasdaq':.45,'sp500':.10,'csi300':.00},
      {'gold_cny':.40,'nasdaq':.50,'sp500':.10,'csi300':.00},
      {'gold_cny':.50,'nasdaq':.40,'sp500':.10,'csi300':.00},
    ]
    candidates=[]; evaluated=0
    for rw in risk_weights:
      for bma in [180,220]:
       for gma in [180,220]:
        for bmom in [120]:
         for bmth in [-.02,0.0]:
          for tv in [.11,.13,.15,.17]:
           for maxexp in [.65,.75,.85]:
            for rfg in [.35,.65]:
             cfg={'risk_weights':rw,'basket_ma':bma,'gold_ma':gma,'basket_mom':bmom,'basket_mom_th':bmth,'basket_vol_cap':.24,'basket_dd_cap':.12,'vol_lb':60,'dd_lb':60,'target_vol':tv,'max_exposure':maxexp,'riskoff_gold':rfg,'pf_soft_dd':.06,'pf_hard_dd':.10,'pf_soft_scale':.65,'pf_hard_scale':.35,'rebalance':20,'band':.02}
             vals,trades,expo=simulate(dates,prices,cfg); m=metrics(dates,vals)
             if not m: continue
             sl={'post_2020':slice_m(dates,vals,dt.date(2020,1,1)),'last_10y':slice_m(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':slice_m(dates,vals,dt.date(2022,1,1))}
             candidates.append({'cfg':cfg,'metrics':m,'slices':sl,'trades':trades,'exposure':expo,'score':score(m,sl)}); evaluated+=1
    print('EVALUATED',evaluated,'CANDIDATES',len(candidates),flush=True)
    candidates.sort(key=lambda c:(c['score'],c['metrics']['annualized'] or 0),reverse=True)
    def dedupe(items,limit=30):
      out=[]; seen=set()
      for c in items:
        cfg=c['cfg']; fam=(tuple(sorted(cfg['risk_weights'].items())),cfg['basket_ma'],cfg['gold_ma'],cfg['basket_mom'],cfg['target_vol'],cfg['max_exposure'],cfg['riskoff_gold'])
        if fam in seen: continue
        seen.add(fam); out.append(c)
        if len(out)>=limit: break
      return out
    under10=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.10],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under11=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.11],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    under12=sorted([c for c in candidates if c['metrics']['max_drawdown']<=.12],key=lambda c:c['metrics']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':cov,'evaluated':evaluated,'score_top':[simp(c) for c in dedupe(candidates)],'under10_by_return':[simp(c) for c in dedupe(under10,20)],'under11_by_return':[simp(c) for c in dedupe(under11,20)],'under12_by_return':[simp(c) for c in dedupe(under12,20)]}
    Path('/tmp/atm_no_btc_basket_trend_2002_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_no_btc_basket_trend_2002_search.json')
    for sec in ['under10_by_return','under11_by_return','under12_by_return','score_top']:
      print('\n==',sec,'==')
      for i,c in enumerate(serial[sec][:10],1):
        m=c['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'],'expo',c['exposure'],'cfg',c['config'])
if __name__=='__main__': main()
