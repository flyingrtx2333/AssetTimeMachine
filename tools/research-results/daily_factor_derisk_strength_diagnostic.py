#!/usr/bin/env python3
"""Diagnose which high-rank derisk-delay events are economically strong enough to veto."""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import daily_alpha_factor_lab as lab  # noqa
import daily_cross_sectional_factor_lab as xlab  # noqa

OUT=HERE/'daily-factor-lab'
ASSETS=lab.ASSETS
TARGET={'gold':'target_gold','nasdaq':'target_nasdaq','sp500':'target_sp500','csi300':'target_csi300','shanghai':'target_shanghai'}
COST=.0105


def ranks(vals):
    o=sorted(ASSETS,key=lambda a:(vals[a],a)); return {a:i/(len(o)-1) for i,a in enumerate(o)}


def static(weights,prices,i,h):
    if i+h>=len(next(iter(prices.values()))): return None
    return sum(w*(prices[a][i+h]/prices[a][i]-1) for a,w in weights.items() if w>0)


def rows():
    dates,cols=lab.read_panel(); cube=xlab.build_asset_factor_cube(cols); prices={a:cols[f'price_{a}'] for a in ASSETS}
    short=cube['risk_adjusted_momentum_60_20']; long=cube['risk_adjusted_momentum_252_60']
    mom60=cube['momentum_60']; mom252=cube['momentum_252']
    out=[]
    for i in range(1,len(dates)):
        prior={a:cols[TARGET[a]][i-1] for a in ASSETS}; new={a:cols[TARGET[a]][i] for a in ASSETS}; d={a:new[a]-prior[a] for a in ASSETS}
        turnover=sum(abs(x) for x in d.values()); gd=sum(prior.values())-sum(new.values())
        if turnover<.02 or gd<.03: continue
        vals_s={a:short[a][i-1] for a in ASSETS}; vals_l={a:long[a][i-1] for a in ASSETS}
        if any(v is None or not math.isfinite(float(v)) for v in list(vals_s.values())+list(vals_l.values()) if v is not None) or any(v is None for v in list(vals_s.values())+list(vals_l.values())): continue
        rs=ranks({a:float(vals_s[a]) for a in ASSETS}); rl=ranks({a:float(vals_l[a]) for a in ASSETS}); comp={a:.5*rs[a]+.5*rl[a] for a in ASSETS}
        oc=sorted(ASSETS,key=lambda a:(comp[a],a),reverse=True); os=sorted(ASSETS,key=lambda a:(rs[a],a),reverse=True); ol=sorted(ASSETS,key=lambda a:(rl[a],a),reverse=True)
        top2=set(oc[:2]); sale_top2=sum(max(-d[a],0) for a in top2)
        if sale_top2<.05: continue
        sold=[a for a in top2 if d[a]<0]
        consensus_top2=int(set(os[:2])==set(ol[:2]))
        sold_dual_rank=sum(1 for a in sold if a in set(os[:2]) and a in set(ol[:2]))
        sold_both_pos=0
        sold_any_both_pos=0
        for a in sold:
            m60=mom60[a][i-1]; m252=mom252[a][i-1]
            if m60 is not None and m252 is not None and m60>0 and m252>0:
                sold_both_pos+=1
                sold_any_both_pos=1
        score_gap=comp[oc[1]]-comp[oc[2]]
        edge={}
        for h in [5,20,60]:
            rn=static(new,prices,i,h); rp=static(prior,prices,i,h); edge[h]=None if rn is None or rp is None else rn-rp-COST*turnover
        out.append({'date':dates[i],'signal_date':dates[i-1],'split':lab.split_name(dates[i]),'sale_top2':sale_top2,'gross_decrease':gd,'consensus_top2':consensus_top2,'sold_dual_rank':sold_dual_rank,'sold_both_pos':sold_both_pos,'sold_any_both_pos':sold_any_both_pos,'score_gap':score_gap,'top2':'|'.join(oc[:2]),'edge5':edge[5],'edge20':edge[20],'edge60':edge[60]})
    return out


def nw(values):
    import daily_cross_sectional_factor_lab as xl
    return xl.nw_mean_t(values,0)


def summarize(events):
    specs=[
      ('all',lambda e:True),
      ('consensus_top2',lambda e:e['consensus_top2']==1),
      ('sold_dual_rank',lambda e:e['sold_dual_rank']>=1),
      ('sold_both_pos',lambda e:e['sold_any_both_pos']==1),
      ('dual_and_positive',lambda e:e['sold_dual_rank']>=1 and e['sold_any_both_pos']==1),
      ('gap_ge_025',lambda e:e['score_gap']>=.25),
      ('gap_ge_05',lambda e:e['score_gap']>=.50),
      ('large_sale_15',lambda e:e['sale_top2']>=.15),
      ('dual_positive_large',lambda e:e['sold_dual_rank']>=1 and e['sold_any_both_pos']==1 and e['sale_top2']>=.15),
    ]
    out=[]
    for name,p in specs:
      for split in ['all','dev','validation','holdout']:
        g=[e for e in events if p(e) and (split=='all' or e['split']==split)]
        for h in [5,20,60]:
          ys=[float(e[f'edge{h}']) for e in g if isinstance(e[f'edge{h}'],(int,float)) and math.isfinite(float(e[f'edge{h}']))]
          if not ys: continue
          m,t,pv=nw(ys)
          out.append({'rule':name,'split':split,'horizon':h,'n':len(ys),'mean_edge':m,'t':t,'p':pv,'base_trade_win':sum(y>0 for y in ys)/len(ys)})
    return out


def write(path,rows):
  if not rows:return
  with path.open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0].keys()));w.writeheader();w.writerows(rows)


def main():
  e=rows(); s=summarize(e); write(OUT/'derisk_strength_events.csv',e); write(OUT/'derisk_strength_groups.csv',s)
  print('DERISK_STRENGTH_DIAGNOSTIC events',len(e))
  for r in s:
    if r['horizon']==5 and r['split'] in ('all','validation','holdout'):
      print(r)

if __name__=='__main__':main()
