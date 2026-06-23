#!/usr/bin/env python3
import importlib.util, datetime as dt, itertools, json, math
from pathlib import Path

spec = importlib.util.spec_from_file_location('base_search', 'tools/search_basic_advanced_strategies.py')
if spec is None or spec.loader is None: raise RuntimeError('cannot load base')
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)

INITIAL=100000.0; FEE=0.001; SLIP=0.0005
SYMS=['gold_cny','nasdaq','sp500']
TITLES={'gold_cny':'黄金','nasdaq':'纳指','sp500':'标普500'}

def prepare():
    raw=base.load_data(); fx=base.make_fx_lookup(raw['usd_per_cny'])
    pts={s:base.normalize_asset(s, raw[s], fx) for s in SYMS}
    # union calendar with <=7 day forward fill exactly matching app rotation alignment spirit
    all_dates=sorted(set(d for p in pts.values() for d,_ in p))
    idx={s:0 for s in SYMS}; latest={}; latest_date={}; dates=[]; prices={s:[] for s in SYMS}
    for d in all_dates:
        ok=True
        for s in SYMS:
            p=pts[s]; i=idx[s]
            while i<len(p) and p[i][0]<=d:
                latest[s]=p[i][1]; latest_date[s]=p[i][0]; i+=1
            idx[s]=i
            if s not in latest or (d-latest_date[s]).days>7:
                ok=False
        if ok:
            dates.append(d)
            for s in SYMS: prices[s].append(latest[s])
    return dates, prices

def ma(vals, n):
    out=[None]*len(vals); rs=0.0
    for i,v in enumerate(vals):
        rs+=v
        if i>=n: rs-=vals[i-n]
        if i>=n-1: out[i]=rs/n
    return out

def momentum(vals, i, lb):
    if i-lb<0 or vals[i-lb]<=0: return None
    return vals[i]/vals[i-lb]-1

def ann_vol(vals, i, lb):
    if i-lb<1: return None
    rets=[]
    for j in range(i-lb+1,i+1):
        if vals[j-1]>0 and vals[j]>0: rets.append(math.log(vals[j]/vals[j-1]))
    if len(rets)<2: return None
    m=sum(rets)/len(rets); var=sum((r-m)**2 for r in rets)/(len(rets)-1)
    return math.sqrt(var)*math.sqrt(252)

def drawdown(vals, i, lb):
    if i-lb+1<0: return None
    w=vals[i-lb+1:i+1]; peak=max(w)
    return vals[i]/peak-1 if peak>0 else None

def metrics(dates, vals): return base.metrics(dates, vals)
def slice_m(dates, vals, start): return base.slice_metrics(dates, vals, start)

def simulate(dates, prices, cfg):
    mas={s:ma(prices[s], cfg['ma_'+s]) for s in SYMS}
    cash=INITIAL; units={s:0.0 for s in SYMS}; vals=[]; trades=0; exposure_sum=0
    last_reb=-10**9
    for i,d in enumerate(dates):
        # current mark-to-market before trades
        def port_val(): return cash + sum(units[s]*prices[s][i] for s in SYMS)
        if i>0 and i-last_reb>=cfg['rebalance']:
            sig_i=i-1
            target={s:0.0 for s in SYMS}
            for s in SYMS:
                px=prices[s][sig_i]
                trend=mas[s][sig_i] is not None and px>mas[s][sig_i]
                mom=momentum(prices[s], sig_i, cfg['mom_lb'])
                if trend and mom is not None and mom>cfg['mom_th']:
                    target[s]=cfg['w_'+s]
            # if equity drawdown/vol bad, scale equities, redeploy part to gold if gold trend ok
            eq_bad=False
            for s in ['nasdaq','sp500']:
                dd=drawdown(prices[s], sig_i, cfg['brake_lb'])
                vol=ann_vol(prices[s], sig_i, cfg['vol_lb'])
                if (dd is not None and dd < -cfg['eq_dd']) or (vol is not None and vol > cfg['eq_vol']):
                    eq_bad=True
            if eq_bad:
                cut=0.0
                for s in ['nasdaq','sp500']:
                    old=target[s]; target[s]*=cfg['eq_scale']; cut += old-target[s]
                if target['gold_cny']>0:
                    target['gold_cny'] += cut*cfg['redeploy_gold']
            # vol target: approximate weighted recent vol using realized asset vols, conservative sum(abs(w)*vol)
            port_vol=0.0
            for s,w in target.items():
                v=ann_vol(prices[s], sig_i, cfg['vol_lb']) or 0
                port_vol += abs(w)*v
            gross=sum(target.values())
            scale=1.0
            if port_vol>0: scale=min(scale, cfg['target_vol']/port_vol)
            if gross>0: scale=min(scale, cfg['max_exposure']/gross)
            for s in SYMS: target[s]*=scale
            total=port_val()
            # sell first
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target[s]
                if cur>tgt*(1+cfg['band']):
                    amount=cur-tgt; sell_units=min(units[s], amount/prices[s][i])
                    if sell_units>0:
                        gross=sell_units*prices[s][i]*(1-SLIP); cash += gross*(1-FEE); units[s]-=sell_units; trades+=1
            total=port_val()
            # buy
            for s in SYMS:
                cur=units[s]*prices[s][i]; tgt=total*target[s]
                if cur<tgt*(1-cfg['band']):
                    amount=min(cash, tgt-cur)
                    if amount>1:
                        invest=amount*(1-FEE); exec_px=prices[s][i]*(1+SLIP); buy=invest/exec_px
                        units[s]+=buy; cash-=amount; trades+=1
            last_reb=i
        v=cash+sum(units[s]*prices[s][i] for s in SYMS); vals.append(v)
        exposure_sum += sum(units[s]*prices[s][i] for s in SYMS)/v if v>0 else 0
    return vals, trades, exposure_sum/len(vals)

def score(m, sm):
    ann=m['annualized'] or 0; dd=m['max_drawdown']; sharpe=m['sharpe'] or 0
    p=sm['post_2020']; r=sm['last_10y']
    pann=(p or {}).get('annualized') or 0; rann=(r or {}).get('annualized') or 0
    pdd=(p or {}).get('max_drawdown') or 0; rdd=(r or {}).get('max_drawdown') or 0
    return ann*1.4+pann*0.35+rann*0.25+sharpe*0.18-dd*1.8-max(dd-0.10,0)*7-max(pdd-0.12,0)*3-max(rdd-0.12,0)*2

def simplify(c):
    def sm(m): return None if m is None else {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
    cfg=c['cfg']
    return {'score':round(c['score'],6),'weights':{s:cfg['w_'+s] for s in SYMS},'ma':{s:cfg['ma_'+s] for s in SYMS},'rebalance':cfg['rebalance'],'mom_lb':cfg['mom_lb'],'mom_th':cfg['mom_th'],'target_vol':cfg['target_vol'],'max_exposure':cfg['max_exposure'],'eq_dd':cfg['eq_dd'],'eq_vol':cfg['eq_vol'],'eq_scale':cfg['eq_scale'],'trades':c['trades'],'exposure':round(c['exposure'],4),'metrics':sm(c['metrics']),'slices':{k:sm(v) for k,v in c['slices'].items()}}

def main():
    dates, prices=prepare(); print('COVERAGE',len(dates),dates[0],dates[-1])
    candidates=[]; count=0
    weight_grid=[]
    for wg in [0.35,0.45,0.50,0.55,0.60]:
      for wn in [0.25,0.35,0.45,0.55]:
        ws=round(1-wg-wn,4)
        if 0.0<=ws<=0.35: weight_grid.append((wg,wn,ws))
    for wg,wn,ws in weight_grid:
      for ma_g in [120,220]:
       for ma_e in [180,250]:
        for reb in [20,40]:
         for mom_lb in [60,120]:
          for mom_th in [-0.02,0.0]:
           for tv in [0.11,0.13,0.15,0.17]:
            for maxexp in [0.95,1.0]:
             for eq_dd in [0.08,0.12]:
              cfg={'w_gold_cny':wg,'w_nasdaq':wn,'w_sp500':ws,'ma_gold_cny':ma_g,'ma_nasdaq':ma_e,'ma_sp500':ma_e,'rebalance':reb,'mom_lb':mom_lb,'mom_th':mom_th,'target_vol':tv,'max_exposure':maxexp,'vol_lb':60,'brake_lb':60,'eq_dd':eq_dd,'eq_vol':0.28,'eq_scale':0.35,'redeploy_gold':0.75,'band':0.02}
              vals,trades,expo=simulate(dates,prices,cfg); m=metrics(dates,vals)
              if not m: continue
              sm={'full':m,'post_2020':slice_m(dates,vals,dt.date(2020,1,1)),'last_10y':slice_m(dates,vals,dates[-1].replace(year=dates[-1].year-10))}
              sc=score(m,sm); count+=1
              if (m['max_drawdown']<=0.16 and (m['annualized'] or 0)>=0.065) or (m['max_drawdown']<=0.10 and (m['annualized'] or 0)>=0.055) or (m['annualized'] or 0)>=0.08:
                candidates.append({'cfg':cfg,'metrics':m,'slices':sm,'score':sc,'trades':trades,'exposure':expo})
    print('EVALUATED',count,'CANDIDATES',len(candidates), flush=True)
    candidates.sort(key=lambda c:(c['score'],c['metrics']['annualized'] or 0), reverse=True)
    # dedupe by broad shape
    out=[]; seen=set()
    for c in candidates:
      cfg=c['cfg']; fam=(round(cfg['w_gold_cny'],2),round(cfg['w_nasdaq'],2),cfg['ma_gold_cny'],cfg['ma_nasdaq'],cfg['rebalance'],cfg['target_vol'],cfg['max_exposure'],cfg['eq_dd'])
      if fam in seen: continue
      seen.add(fam); out.append(c)
      if len(out)>=30: break
    under10=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.10], key=lambda c:c['metrics']['annualized'] or 0, reverse=True)[:20]
    under12=sorted([c for c in candidates if c['metrics']['max_drawdown']<=0.12], key=lambda c:c['metrics']['annualized'] or 0, reverse=True)[:20]
    serial={
      'generated_at':dt.datetime.now().isoformat(timespec='seconds'),
      'coverage':{'count':len(dates),'start':str(dates[0]),'end':str(dates[-1])},
      'evaluated':count,
      'top':[simplify(c) for c in out],
      'under10_by_return':[simplify(c) for c in under10],
      'under12_by_return':[simplify(c) for c in under12],
    }
    Path('/tmp/atm_new_portfolio_strategy_search.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
    print('WROTE /tmp/atm_new_portfolio_strategy_search.json')
    for i,c in enumerate(serial['top'][:12],1):
      m=c['metrics']; print(i,c['weights'],'ma',c['ma'],'reb',c['rebalance'],'tv',c['target_vol'],'max',c['max_exposure'],'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'])
    print('\nUNDER10_BY_RETURN')
    for i,c in enumerate(serial['under10_by_return'][:8],1):
      m=c['metrics']; print(i,c['weights'],'ma',c['ma'],'reb',c['rebalance'],'tv',c['target_vol'],'max',c['max_exposure'],'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'])
    print('\nUNDER12_BY_RETURN')
    for i,c in enumerate(serial['under12_by_return'][:8],1):
      m=c['metrics']; print(i,c['weights'],'ma',c['ma'],'reb',c['rebalance'],'tv',c['target_vol'],'max',c['max_exposure'],'ann',f"{m['annualized']*100:.2f}%",'mdd',f"{m['max_drawdown']*100:.2f}%",'sharpe',None if m['sharpe'] is None else round(m['sharpe'],2),'trades',c['trades'])
if __name__=='__main__': main()
