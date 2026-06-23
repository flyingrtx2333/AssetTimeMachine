#!/usr/bin/env python3
from __future__ import annotations
import datetime as dt, importlib.util, json, math, urllib.parse, urllib.request
from pathlib import Path

spec=importlib.util.spec_from_file_location('base','tools/search_basic_advanced_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('load base failed')
base=importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
BASE='https://api.flyingrtx.com/api/v1/money/public/history'; INITIAL=100000.0; FEE=0.001; SLIP=0.0005
SYMS=['gold_cny','nasdaq','sp500','btc']; USD=['nasdaq','sp500','btc']
ALIASES={'nasdaq_composite':'nasdaq'}

def fetch(symbols):
    url=BASE+'?'+urllib.parse.urlencode({'symbols':','.join(symbols),'start_date':'2000-01-01','end_date':dt.date.today().isoformat()})
    with urllib.request.urlopen(url,timeout=90) as r: return json.load(r)['series']

def parse(d):
    y,m,day=map(int,d.split('-')); return dt.date(y,m,day)

def load():
    raw=[]
    for b in [['gold_cny','nasdaq','sp500','btc','usd_per_cny']]: raw.extend(fetch(b))
    series={}
    for s in raw:
        sym=ALIASES.get(s['symbol'],s['symbol'])
        series[sym]=s
    fx=base.make_fx_lookup(series['usd_per_cny'])
    pts={}
    for sym in SYMS:
        out=[]
        for d,p in zip(series[sym]['dates'],series[sym]['prices']):
            if not p or p<=0: continue
            date=parse(d); price=p
            out.append((date,price))
        pts[sym]=out
    # Convert USD assets to CNY using base cny logic manually.
    fxd,fxp=fx
    import bisect
    for sym in USD:
        conv=[]
        for date,p in pts[sym]:
            j=bisect.bisect_right(fxd,date)-1
            if j<0: continue
            r=fxp[j]
            if r<1: c=p/r
            elif r<=20: c=p*r
            else: continue
            conv.append((date,c))
        pts[sym]=conv
    # aligned with forward fill <=7 days
    all_dates=sorted(set(d for arr in pts.values() for d,_ in arr)); idx={s:0 for s in SYMS}; latest={}; latestd={}; dates=[]; prices={s:[] for s in SYMS}
    for d in all_dates:
        ok=True
        for s in SYMS:
            arr=pts[s]; i=idx[s]
            while i<len(arr) and arr[i][0]<=d:
                latest[s]=arr[i][1]; latestd[s]=arr[i][0]; i+=1
            idx[s]=i
            if s not in latest or (d-latestd[s]).days>7: ok=False
        if ok:
            dates.append(d)
            for s in SYMS: prices[s].append(latest[s])
    return dates,prices,{s:{'count':len(pts[s]),'start':str(pts[s][0][0]),'end':str(pts[s][-1][0])} for s in SYMS}

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
    rs=[]
    for j in range(i-n+1,i+1):
        if vals[j-1]>0: rs.append(math.log(vals[j]/vals[j-1]))
    if len(rs)<2: return None
    m=sum(rs)/len(rs); var=sum((x-m)**2 for x in rs)/(len(rs)-1)
    return math.sqrt(var)*math.sqrt(252)

def dd(vals,i,n):
    if i-n+1<0: return None
    w=vals[i-n+1:i+1]; peak=max(w)
    return vals[i]/peak-1 if peak>0 else None

def simulate(dates,prices,cfg):
    mas={s:ma(prices[s],cfg['ma_'+s]) for s in SYMS}
    cash=INITIAL; units={s:0.0 for s in SYMS}; vals=[]; trades=0; exposure=0; last=-10**9
    for i,d in enumerate(dates):
        def pv(): return cash+sum(units[s]*prices[s][i] for s in SYMS)
        if i>0 and i-last>=cfg['rebalance']:
            sig=i-1; target={s:0.0 for s in SYMS}
            for s in SYMS:
                m=mas[s][sig]; mo=mom(prices[s],sig,cfg['mom_'+s]); vv=vol(prices[s],sig,cfg['vol_lb']); d60=dd(prices[s],sig,cfg['dd_lb'])
                good=m is not None and prices[s][sig]>m and mo is not None and mo>cfg['mom_th_'+s]
                bad=(vv is not None and vv>cfg['max_vol_'+s]) or (d60 is not None and d60<-cfg['max_dd_'+s])
                if good and not bad: target[s]=cfg['w_'+s]
            # if equities weak but gold good, redeploy part to gold
            eq_cut=0
            for s in ['nasdaq','sp500']:
                if target[s]==0:
                    eq_cut += cfg['w_'+s]
            if target['gold_cny']>0: target['gold_cny'] += eq_cut*cfg['redeploy_gold']
            # vol target by conservative weighted vol
            portv=sum(abs(w)*(vol(prices[s],sig,cfg['vol_lb']) or 0) for s,w in target.items())
            gross=sum(target.values()); scale=1.0
            if portv>0: scale=min(scale,cfg['target_vol']/portv)
            if gross>0: scale=min(scale,cfg['max_exposure']/gross)
            for s in SYMS: target[s]*=scale
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

def slices(dates,vals): return {'full':base.metrics(dates,vals),'post_2020':base.slice_metrics(dates,vals,dt.date(2020,1,1)),'last_10y':base.slice_metrics(dates,vals,dates[-1].replace(year=dates[-1].year-10)),'post_2022':base.slice_metrics(dates,vals,dt.date(2022,1,1))}
def score(sl):
    f=sl['full']; p=sl['post_2020'] or {}; y=sl['last_10y'] or {}; z=sl['post_2022'] or {}
    ann=f['annualized'] or 0; ddv=f['max_drawdown']; sh=f['sharpe'] or 0
    return ann*1.5+(p.get('annualized') or 0)*.3+(y.get('annualized') or 0)*.25+(z.get('annualized') or 0)*.15+sh*.18-ddv*1.8-max(ddv-.10,0)*8-max((p.get('max_drawdown') or 0)-.12,0)*2

def simp(c):
    def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
    return {'score':round(c['score'],6),'config':c['cfg'],'trades':c['trades'],'exposure':round(c['exposure'],4),'metrics':sm(c['slices']['full']),'slices':{k:sm(v) for k,v in c['slices'].items() if k!='full'}}

def main():
    dates,prices,cov=load(); print('COVERAGE',len(dates),dates[0],dates[-1],cov,flush=True)
    candidates=[]; evaluated=0
    weights=[(0.35,0.45,0.10,0.10),(0.35,0.40,0.15,0.10),(0.40,0.40,0.10,0.10),(0.45,0.35,0.10,0.10),(0.35,0.50,0.10,0.05),(0.45,0.40,0.10,0.05),(0.50,0.35,0.10,0.05),(0.55,0.30,0.10,0.05),(0.50,0.40,0.07,0.03)]
    for wg,wn,ws,wb in weights:
      for ma_btc in [120,180,250]:
       for tv in [0.09,0.11,0.13,0.15,0.17]:
        for maxexp in [0.55,0.65,0.75,0.85]:
         for btc_vol in [0.65,0.85,1.10]:
          cfg={'w_gold_cny':wg,'w_nasdaq':wn,'w_sp500':ws,'w_btc':wb,'ma_gold_cny':220,'ma_nasdaq':220,'ma_sp500':220,'ma_btc':ma_btc,'mom_gold_cny':120,'mom_nasdaq':120,'mom_sp500':120,'mom_btc':90,'mom_th_gold_cny':-0.02,'mom_th_nasdaq':-0.02,'mom_th_sp500':-0.02,'mom_th_btc':0.04,'vol_lb':60,'dd_lb':60,'max_vol_gold_cny':0.35,'max_vol_nasdaq':0.35,'max_vol_sp500':0.3,'max_vol_btc':btc_vol,'max_dd_gold_cny':0.15,'max_dd_nasdaq':0.12,'max_dd_sp500':0.1,'max_dd_btc':0.20,'redeploy_gold':0.75,'target_vol':tv,'max_exposure':maxexp,'rebalance':20,'band':0.02}
          vals,trades,expo=simulate(dates,prices,cfg); sl=slices(dates,vals); f=sl['full']; evaluated+=1
          candidates.append({'cfg':cfg,'slices':sl,'score':score(sl),'trades':trades,'exposure':expo})
    candidates.sort(key=lambda c:(c['score'],c['slices']['full']['annualized'] or 0), reverse=True)
    def dedupe(items,limit=30):
        out=[]; seen=set()
        for c in items:
            cfg=c['cfg']; fam=(cfg['w_gold_cny'],cfg['w_nasdaq'],cfg['w_btc'],cfg['ma_btc'],cfg['target_vol'],cfg['max_exposure'],cfg['max_vol_btc'])
            if fam in seen: continue
            seen.add(fam); out.append(c)
            if len(out)>=limit: break
        return out
    under10=sorted([c for c in candidates if c['slices']['full']['max_drawdown']<=0.10],key=lambda c:c['slices']['full']['annualized'] or 0,reverse=True)
    under12=sorted([c for c in candidates if c['slices']['full']['max_drawdown']<=0.12],key=lambda c:c['slices']['full']['annualized'] or 0,reverse=True)
    serial={'generated_at':dt.datetime.now().isoformat(timespec='seconds'),'coverage':cov,'evaluated':evaluated,'score_top':[simp(c) for c in dedupe(candidates)],'under10_by_return':[simp(c) for c in dedupe(under10,20)],'under12_by_return':[simp(c) for c in dedupe(under12,20)]}
    Path('/tmp/atm_btc_satellite_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_btc_satellite_search.json')
    for sec in ['under10_by_return','under12_by_return','score_top']:
        print('\n==',sec,'==')
        for i,c in enumerate(serial[sec][:10],1):
            m=c['metrics']; print(i,'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'],'cfg',c['config'])
if __name__=='__main__': main()
