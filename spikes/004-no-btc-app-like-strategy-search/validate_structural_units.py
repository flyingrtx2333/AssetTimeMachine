#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, math, datetime as dt
from pathlib import Path

spec=importlib.util.spec_from_file_location('nb','/tmp/atm_next_better_strategy_search.py')
NB=importlib.util.module_from_spec(spec); sys.modules['nb']=NB; spec.loader.exec_module(NB)  # type: ignore
START=100000.0; FEE=0.001; SLIP=0.0005
OUT=Path('/tmp/atm_structural_candidates_units_validation.json')
RATE_POINTS=[(dt.date(1990,4,15),0.0288),(dt.date(1999,6,10),0.0099),(dt.date(2002,2,21),0.0072),(dt.date(2007,7,21),0.0081),(dt.date(2007,12,21),0.0072),(dt.date(2008,11,27),0.0036),(dt.date(2011,2,9),0.0040),(dt.date(2011,4,6),0.0050),(dt.date(2012,6,8),0.0040),(dt.date(2012,7,6),0.0035),(dt.date(2015,10,24),0.0035)]

def cash_daily(day):
    r=RATE_POINTS[0][1]
    for d,v in RATE_POINTS:
        if d<=day: r=v
        else: break
    return r/252.0

def pct(x): return f'{x*100:.2f}%'
def ix(d,s): return d.assets.index(s)
def price(d,s,i): return d.prices[ix(d,s)][i]
def desc(d,w): return {s:round(x*100,1) for s,x in zip(d.assets,w) if x>1e-4}

def target_from_p(d, base_w, vals, weights, sig, p, events):
    core=[x*p['core_w'] for x in base_w[sig]]
    target=core[:]
    ev=[]
    if NB.gold_sat_ok(d,sig,p):
        target[ix(d,'gold_cny')]+=p['sat_w']; ev.append('gold_sat')
    target=NB.cap_total(target,p['max_exp'])
    if p.get('gold_exhaust') and NB.gold_exhausted(d,sig,p):
        j=ix(d,'gold_cny')
        if target[j]>p['gold_cap']:
            target[j]=p['gold_cap']; ev.append('gold_exhaust_cap')
    if p.get('weak_month_guard') and NB.q_weak_equity_trigger(d,sig,target,p):
        target=NB.apply_equity_cap(d,sig,target,p['weak_cap'],'weak_month_cap',events,p.get('weak_redeploy_gold',False)); ev.append('weak_month_cap')
    if p.get('vol_spike_guard') and NB.vol_spike_trigger(d,sig,target,p):
        target=NB.apply_equity_cap(d,sig,target,p['vol_cap'],'vol_spike_cap',events,p.get('vol_redeploy_gold',False)); ev.append('vol_spike_cap')
    if p.get('drawdown_guard') and len(vals)>p['port_lb']:
        pk=max(vals[-p['port_lb']:]); dd=1-vals[-1]/pk if pk>0 else 0
        if dd>p['port_dd']:
            for s in NB.equity_symbols(): target[ix(d,s)]*=p['port_scale']
            ev.append('portfolio_dd_scale')
    if p.get('breadth_boost') and NB.breadth_boost_ok(d,sig,p):
        target[ix(d,'nasdaq')]+=p['boost_w']*0.6
        target[ix(d,'sp500')]+=p['boost_w']*0.4
        ev.append('breadth_boost')
    target=NB.cap_total(target,p['max_exp'])
    for e in ev: events[e]=events.get(e,0)+1
    return target

def run_units(d, base_w, p):
    cash=START; units=[0.0]*len(d.assets); vals=[]; wa=[]; events={}; trades=0; turn=0.0
    def pv(i): return cash+sum(units[j]*d.prices[j][i] for j in range(len(units)))
    for i in range(len(d.dates)):
        if i>0 and cash>0:
            cash += cash*cash_daily(d.dates[i-1])
        if i==1 or (i>1 and i%p['rebalance']==0):
            sig=i-1
            pre=pv(i)
            oldw=[(units[j]*d.prices[j][i]/pre if pre>0 else 0) for j in range(len(units))]
            target=target_from_p(d,base_w,vals if vals else [START],oldw,sig,p,events)
            # sell first
            for j,s in enumerate(d.assets):
                cur=units[j]*d.prices[j][i]
                tgt=pre*target[j]
                if cur>tgt+1e-9:
                    sell_value=cur-tgt
                    sell_units=min(units[j], sell_value/d.prices[j][i])
                    if sell_units>1e-12:
                        gross=sell_units*d.prices[j][i]*(1-SLIP)
                        cash += gross*(1-FEE)
                        units[j]-=sell_units
                        trades+=1
            total=pv(i)
            for j,s in enumerate(d.assets):
                cur=units[j]*d.prices[j][i]
                tgt=total*target[j]
                if cur<tgt-1e-9:
                    amt=min(cash,max(tgt-cur,0))
                    if amt>1:
                        units[j]+=amt*(1-FEE)/(d.prices[j][i]*(1+SLIP))
                        cash-=amt; trades+=1
            newv=pv(i)
            neww=[(units[j]*d.prices[j][i]/newv if newv>0 else 0) for j in range(len(units))]
            turn += sum(abs(a-b) for a,b in zip(oldw,neww))
        val=pv(i); vals.append(val)
        wa.append([(units[j]*d.prices[j][i]/val if val>0 else 0) for j in range(len(units))])
    return vals,wa,{'events':events,'trades':trades,'avg_turnover':turn/max(trades,1),'latest':desc(d,wa[-1]),'cash_pct':max(0,1-sum(wa[-1]))}

def run_base_units(d, base_w, rebalance=60):
    cash=START; units=[0.0]*len(d.assets); vals=[]; wa=[]; trades=0; turn=0.0
    def pv(i): return cash+sum(units[j]*d.prices[j][i] for j in range(len(units)))
    for i in range(len(d.dates)):
        if i>0 and cash>0:
            cash += cash*cash_daily(d.dates[i-1])
        if i==1 or (i>1 and i%rebalance==0):
            sig=i-1
            pre=pv(i)
            oldw=[(units[j]*d.prices[j][i]/pre if pre>0 else 0) for j in range(len(units))]
            target=[max(x,0) for x in base_w[sig]]
            sm=sum(target)
            if sm>1 and sm>0:
                target=[x/sm for x in target]
            for j in range(len(d.assets)):
                cur=units[j]*d.prices[j][i]
                tgt=pre*target[j]
                if cur>tgt+1e-9:
                    sell_units=min(units[j],(cur-tgt)/d.prices[j][i])
                    if sell_units>1e-12:
                        gross=sell_units*d.prices[j][i]*(1-SLIP)
                        cash+=gross*(1-FEE); units[j]-=sell_units; trades+=1
            total=pv(i)
            for j in range(len(d.assets)):
                cur=units[j]*d.prices[j][i]
                tgt=total*target[j]
                if cur<tgt-1e-9:
                    amt=min(cash,max(tgt-cur,0))
                    if amt>1:
                        units[j]+=amt*(1-FEE)/(d.prices[j][i]*(1+SLIP))
                        cash-=amt; trades+=1
            newv=pv(i)
            neww=[(units[j]*d.prices[j][i]/newv if newv>0 else 0) for j in range(len(units))]
            turn += sum(abs(a-b) for a,b in zip(oldw,neww))
        val=pv(i); vals.append(val)
        wa.append([(units[j]*d.prices[j][i]/val if val>0 else 0) for j in range(len(units))])
    return vals,wa,{'events':{},'trades':trades,'avg_turnover':turn/max(trades,1),'latest':desc(d,wa[-1]),'cash_pct':max(0,1-sum(wa[-1]))}

def episodes(d,values,wa,topn=5):
    peak=trough=0; out=[]
    for i in range(1,len(values)):
        if values[i]>values[peak]:
            if values[trough]<values[peak]*0.985: out.append((peak,trough,1-values[trough]/values[peak],wa[trough]))
            peak=trough=i
        elif values[i]<values[trough]: trough=i
    if values[trough]<values[peak]*0.985: out.append((peak,trough,1-values[trough]/values[peak],wa[trough]))
    out=sorted(out,key=lambda x:x[2],reverse=True)[:topn]
    return [(str(d.dates[p]),str(d.dates[t]),dd,desc(d,w)) for p,t,dd,w in out]

def main():
    d,base_vals,base_w=NB.base_data()
    src=json.load(open('/tmp/atm_next_better_strategy_results.json'))
    candidates=[]
    # validate baseline meta and known balanced first
    named=[('BASE_META', None),('KNOWN_BALANCED',src['known_balanced'].get('p'))]
    # known_balanced lacks p in result file, reconstruct from script
    named[1]=('KNOWN_BALANCED', NB.base_params(0.975,0.10,0.85)|{'weak_month_guard':True,'weak_months':(2,), 'weak_lb':60,'weak_thr':-0.02,'weak_cap':0.35})
    for r in src['rows'][:80]: named.append((r['name'],r['p']))
    seen=set(); rows=[]
    for name,p in named:
        if name in seen: continue
        seen.add(name)
        if p is None:
            vals,wa,extra=run_base_units(d,base_w,60)
        else:
            vals,wa,extra=run_units(d,base_w,p)
        m=NB.metrics(d,vals); st=NB.stress(d,vals)
        rows.append({'name':name,'p':p,'metrics':m,'stress':st,'extra':extra,'top_dd':episodes(d,vals,wa),'score':NB.score(m)})
    rows.sort(key=lambda r:(r['metrics']['full']['dd']<=0.10,r['metrics']['full']['ann'], -r['metrics']['full']['dd']), reverse=True)
    OUT.write_text(json.dumps({'rows':rows},ensure_ascii=False,default=str,indent=2))
    print('WROTE',OUT,'rows',len(rows))
    for i,r in enumerate(rows[:20],1):
        m=r['metrics']; e=r['extra']
        print(f"#{i:02d} {r['name']}")
        print(f"  full {pct(m['full']['ann'])}/{pct(m['full']['dd'])} post {pct(m['post2020']['ann'])}/{pct(m['post2020']['dd'])} ten {pct(m['teny']['ann'])}/{pct(m['teny']['dd'])} 2024+ {pct(m['2024+']['ann'])}/{pct(m['2024+']['dd'])}")
        print('  latest',e['latest'],'cash',pct(e.get('cash_pct',0)),'trades',e['trades'],'events',e['events'])
        print('  topdd',' ; '.join(f'{a}->{b} {pct(c)} W={w}' for a,b,c,w in r['top_dd'][:3]))

if __name__=='__main__': main()
