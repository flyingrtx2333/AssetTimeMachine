#!/usr/bin/env python3
from __future__ import annotations
import csv, math, random, statistics
from dataclasses import dataclass
from datetime import date
from pathlib import Path

SQRT252=math.sqrt(252.0)
FILES={
    'Unified122V10':Path('/private/tmp/DualCoreV10_unified122.csv'),
    'Round25V11':Path('/private/tmp/DualCoreV11_round25.csv'),
}
FOLDS=[
    ('2012-2014','2012-07-05','2014-12-31'),
    ('2015-2016','2015-01-01','2016-12-31'),
    ('2017-2018','2017-01-01','2018-12-31'),
    ('2019-2020','2019-01-01','2020-12-31'),
    ('2021-2022','2021-01-01','2022-12-31'),
    ('2023-2024','2023-01-01','2024-12-31'),
    ('2025-latest','2025-01-01','9999-12-31'),
]
@dataclass(frozen=True)
class M:
    cagr:float;mdd:float;vol:float;sharpe:float

def load(path):
    d=[];v=[]
    for r in csv.DictReader(path.open(encoding='utf-8')):
        try:x=float(r['portfolio_value'])
        except (KeyError,TypeError,ValueError):continue
        if math.isfinite(x) and x>0:d.append(r['date']);v.append(x)
    if len(v)<100:raise RuntimeError(f'insufficient rows {path}')
    return d,v

def metrics(d,v):
    if len(v)<3:return M(0,0,0,0)
    rs=[v[i]/v[i-1]-1 for i in range(1,len(v))];mu=statistics.fmean(rs);sd=statistics.stdev(rs)
    peak=v[0];mdd=0.0
    for x in v:peak=max(peak,x);mdd=max(mdd,1-x/peak)
    years=max((date.fromisoformat(d[-1])-date.fromisoformat(d[0])).days/365.2425,1/365.2425)
    return M((v[-1]/v[0])**(1/years)-1,mdd,sd*SQRT252,mu/sd*SQRT252 if sd else 0)

def sliced(d,v,a,b):
    ii=[i for i,x in enumerate(d) if a<=x<=b]
    return [d[i] for i in ii],[v[i] for i in ii]

def pct(xs,q):
    y=sorted(xs);p=(len(y)-1)*q;lo=int(math.floor(p));hi=int(math.ceil(p))
    if lo==hi:return y[lo]
    w=p-lo;return y[lo]*(1-w)+y[hi]*w

def bootstrap(v,reps=3000,block=63,seed=20260815):
    r=[v[i]/v[i-1]-1 for i in range(1,len(v))];n=len(r);rng=random.Random(seed);sh=[];dd=[]
    fake=[date.fromordinal(date(2000,1,1).toordinal()+i).isoformat() for i in range(n+1)]
    for _ in range(reps):
        s=[]
        while len(s)<n:
            j=rng.randrange(n)
            for k in range(block):
                s.append(r[(j+k)%n])
                if len(s)>=n:break
        vv=[1.0]
        for x in s:vv.append(vv[-1]*(1+x))
        m=metrics(fake,vv);sh.append(m.sharpe);dd.append(m.mdd)
    return pct(sh,.025),pct(sh,.5),pct(dd,.5),pct(dd,.975)

def main():
    loaded={n:load(p) for n,p in FILES.items()};dates=loaded['Unified122V10'][0]
    if any(d!=dates for d,_ in loaded.values()):raise RuntimeError('date mismatch')
    full={};folds={};boots={}
    print('DUAL_CORE_V11_VALIDATION')
    for n,(d,v) in loaded.items():
        full[n]=metrics(d,v);boots[n]=bootstrap(v);fs=[]
        for _,a,b in FOLDS:
            dd,vv=sliced(d,v,a,b);fs.append(metrics(dd,vv))
        folds[n]=fs;m=full[n];bt=boots[n]
        print(f'FULL,{n},cagr={m.cagr:.6%},mdd={m.mdd:.6%},vol={m.vol:.6%},sharpe={m.sharpe:.6f},boot_sh_p025={bt[0]:.6f},boot_sh_med={bt[1]:.6f},boot_mdd_med={bt[2]:.6%},boot_mdd_p975={bt[3]:.6%}')
        print('FOLD_SHARPE,'+n+','+','.join(f'{x.sharpe:.6f}' for x in fs))
        print('FOLD_MDD,'+n+','+','.join(f'{x.mdd:.6%}' for x in fs))
        print('FOLD_CAGR,'+n+','+','.join(f'{x.cagr:.6%}' for x in fs))
    base=full['Unified122V10'];m=full['Round25V11'];bt=boots['Round25V11'];bf=folds['Unified122V10'];cf=folds['Round25V11']
    gt1=sum(x.sharpe>1 for x in cf);worst=min(x.sharpe for x in cf);beat_sh=sum(x.sharpe>=y.sharpe for x,y in zip(cf,bf));better_dd=sum(x.mdd<=y.mdd+1e-12 for x,y in zip(cf,bf))
    ok=(m.cagr>=.14 and m.sharpe>=1.50 and m.mdd<=.085 and abs(m.sharpe-base.sharpe)<=.025 and gt1>=5 and worst>0 and bt[0]>=1.15 and bt[3]<=.15 and (beat_sh>=4 or better_dd>=6))
    print(f'GATES,Round25V11,{"PASS" if ok else "FAIL"},folds_sharpe_gt1={gt1}/7,worst_fold={worst:.6f},fold_sharpe_ge_v10={beat_sh}/7,fold_mdd_le_v10={better_dd}/7,sharpe_delta={m.sharpe-base.sharpe:.6f}')
if __name__=='__main__':main()
