#!/usr/bin/env python3
"""Build preregistered V3 target-weight ensembles from causal Swift expert dumps."""
from __future__ import annotations

import csv
from pathlib import Path

SYMS=['gold_cny','nasdaq','sp500','csi300','shanghai_composite']
EXPERTS=[Path(f'/private/tmp/v3_e_b{b}_s{s}.csv') for b in ('090','100','110') for s in ('090','100','110')]
C0=Path('/private/tmp/v3_c0_targets.csv')
C1=Path('/private/tmp/v3_c1_targets.csv')
C2=Path('/private/tmp/v3_c2_targets.csv')


def load(path:Path)->tuple[list[str],dict[str,list[float]]]:
    rows=list(csv.DictReader(path.open(encoding='utf-8')))
    dates=[r['date'] for r in rows]
    cols={s:[float(r[s]) for r in rows] for s in SYMS}
    return dates,cols


def avg(paths:list[Path],weights:list[float],out:Path)->None:
    loaded=[load(p) for p in paths]
    dates=loaded[0][0]
    if any(d!=dates for d,_ in loaded): raise RuntimeError(f'dates mismatch for {out}')
    if abs(sum(weights)-1)>1e-12: raise RuntimeError('weights must sum to 1')
    with out.open('w',newline='',encoding='utf-8') as f:
        w=csv.writer(f);w.writerow(['date',*SYMS])
        maxgross=0.0
        for i,d in enumerate(dates):
            vals=[]
            for s in SYMS:
                v=sum(weight*cols[s][i] for weight,(_,cols) in zip(weights,loaded))
                vals.append(max(v,0.0))
            gross=sum(vals)
            if gross>1+1e-9:
                vals=[v/gross for v in vals];gross=1.0
            maxgross=max(maxgross,gross)
            w.writerow([d,*[f'{v:.10f}' for v in vals]])
    print(f'BUILT {out} rows={len(dates)} maxgross={maxgross:.10f}')


def main()->None:
    avg(EXPERTS,[1/9]*9,Path('/private/tmp/v3_bag9_targets.csv'))
    avg([C0,C2],[.5,.5],Path('/private/tmp/v3_dual_targets.csv'))
    avg([C0,C1,C2],[1/3]*3,Path('/private/tmp/v3_triple_targets.csv'))

if __name__=='__main__':main()
