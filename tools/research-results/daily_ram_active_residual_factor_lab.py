#!/usr/bin/env python3
"""Residual factor mining conditional on RAM overlay actually changing target weights."""
from __future__ import annotations
import csv, math, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import daily_alpha_factor_lab as lab

OUT=HERE/'daily-factor-lab'
POINTS=OUT/'g85_v80_s40_points.csv'
STATES=OUT/'g85_v80_s40_states.csv'
HORIZONS=[5,20,60]
STATE_COLS=['target_gold','target_nasdaq','target_sp500','target_csi300','target_shanghai']

def read_map(path, value):
    out={}
    with path.open(newline='') as f:
        for r in csv.DictReader(f):
            try: out[r['date']]=float(r[value])
            except: pass
    return out

def active_mask(dates, cols):
    states={}
    with STATES.open(newline='') as f:
        for r in csv.DictReader(f): states[r['date']]=r
    mask=[]
    for i,d in enumerate(dates):
        r=states.get(d)
        if not r: mask.append(False); continue
        diff=0.0
        for c in STATE_COLS:
            try: diff += abs(float(r[c])-float(cols[c][i]))
            except: pass
        mask.append(diff>1e-6)
    return mask

def excess_labels(dates, cols, mask):
    pm=read_map(POINTS,'value'); cand=[pm.get(d) for d in dates]; base=cols['portfolio_value']; out={}
    for h in HORIZONS:
        y=[None]*len(dates)
        for i in range(len(dates)-h):
            if not mask[i]: continue
            c0,c1=cand[i],cand[i+h]; b0,b1=base[i],base[i+h]
            if c0 and c1 and b0>0 and b1>0: y[i]=c1/c0-b1/b0
        out[h]=y
    return out

def main():
    dates,cols=lab.read_panel(); factors,fams=lab.build_factors(dates,cols); mask=active_mask(dates,cols); labels=excess_labels(dates,cols,mask)
    print('RAM_ACTIVE_RESIDUAL active_days',sum(mask),'of',len(mask))
    rows=[]
    for h,y in labels.items():
        temp=[]; ps=[]
        for name,x in factors.items():
            if fams[name]=='strategy_state' and name not in {'state_cash_ratio','state_target_gross'}: continue
            xd,yd=lab.valid_xy(dates,x,y,'dev'); xv,yv=lab.valid_xy(dates,x,y,'validation'); xh,yh=lab.valid_xy(dates,x,y,'holdout')
            if min(len(xd),len(xv),len(xh))<40: continue
            d=lab.nw_univariate(xd,yd,h-1); v=lab.nw_univariate(xv,yv,h-1); ho=lab.nw_univariate(xh,yh,h-1)
            if not d or not v or not ho: continue
            r={'horizon':h,'factor':name,'family':fams[name],'n_dev':len(xd),'dev_beta':d.beta,'dev_t':d.beta_t,'dev_p':d.p_value,'val_beta':v.beta,'val_t':v.beta_t,'hold_beta':ho.beta,'hold_t':ho.beta_t,'val_ok':int(d.beta*v.beta>0),'hold_ok':int(d.beta*ho.beta>0)}
            temp.append(r);ps.append((name,d.p_value))
        q=lab.bh_qvalues(ps)
        for r in temp:r['dev_bh_q']=q.get(r['factor'],float('nan'));rows.append(r)
    with (OUT/'ram_active_residual_factor_scores.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()));w.writeheader();w.writerows(rows)
    for h in HORIZONS:
        s=[r for r in rows if r['horizon']==h];s.sort(key=lambda r:(r['dev_bh_q'],-abs(r['dev_t'])))
        print('TOP',h)
        for r in s[:15]: print(r)
if __name__=='__main__':main()
