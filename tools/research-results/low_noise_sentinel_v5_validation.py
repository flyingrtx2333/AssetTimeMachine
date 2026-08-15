#!/usr/bin/env python3
from __future__ import annotations
import csv, math, random, statistics
from dataclasses import dataclass
from datetime import date
from pathlib import Path

SQRT252=math.sqrt(252.0)
FILES={
    'Current':Path('/private/tmp/V5_0_current.csv'),
    'NoSentinel':Path('/private/tmp/V5_2_no_sentinel.csv'),
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

def load(p:Path):
    d=[];v=[]
    for r in csv.DictReader(p.open()):
        x=float(r['portfolio_value'])
        if math.isfinite(x) and x>0:d.append(r['date']);v.append(x)
    return d,v

def metrics(d,v):
    if len(v)<3:return M(0,0,0,0)
    rs=[v[i]/v[i-1]-1 for i in range(1,len(v))]
    mu=statistics.fmean(rs);sd=statistics.stdev(rs)
    peak=v[0];mdd=0
    for x in v:peak=max(peak,x);mdd=max(mdd,1-x/peak)
    years=max((date.fromisoformat(d[-1])-date.fromisoformat(d[0])).days/365.2425,1/365.2425)
    return M((v[-1]/v[0])**(1/years)-1,mdd,sd*SQRT252,mu/sd*SQRT252 if sd else 0)

def sliced(d,v,a,b):
    ii=[i for i,x in enumerate(d) if a<=x<=b]
    return [d[i] for i in ii],[v[i] for i in ii]

def pct(xs,q):
    y=sorted(xs);p=(len(y)-1)*q;lo=int(p);hi=min(lo+1,len(y)-1);w=p-lo
    return y[lo]*(1-w)+y[hi]*w

def bootstrap(v,reps=3000,block=63,seed=20260815):
    r=[v[i]/v[i-1]-1 for i in range(1,len(v))];n=len(r);rng=random.Random(seed);sh=[];dd=[]
    for _ in range(reps):
        s=[]
        while len(s)<n:
            j=rng.randrange(n)
            s.extend(r[(j+k)%n] for k in range(min(block,n-len(s))))
        vv=[1.0]
        for x in s:vv.append(vv[-1]*(1+x))
        mm=metrics([date.fromordinal(date(2000,1,1).toordinal()+i).isoformat() for i in range(len(vv))],vv)
        sh.append(mm.sharpe);dd.append(mm.mdd)
    return pct(sh,.025),pct(sh,.5),pct(dd,.5),pct(dd,.975)

def main():
    loaded={k:load(p) for k,p in FILES.items()};d=loaded['Current'][0]
    assert all(x[0]==d for x in loaded.values())
    print('LOW_NOISE_SENTINEL_V5_VALIDATION')
    folds={}
    for name,(dates,vals) in loaded.items():
        full=metrics(dates,vals);bt=bootstrap(vals);fs=[]
        for label,a,b in FOLDS:
            dd,vv=sliced(dates,vals,a,b);fs.append(metrics(dd,vv))
        folds[name]=fs
        print(f'FULL,{name},cagr={full.cagr:.6%},mdd={full.mdd:.6%},vol={full.vol:.6%},sharpe={full.sharpe:.6f},boot_sh_p025={bt[0]:.6f},boot_sh_med={bt[1]:.6f},boot_mdd_med={bt[2]:.6%},boot_mdd_p975={bt[3]:.6%}')
        print('FOLD_SHARPE,'+name+','+','.join(f'{x.sharpe:.6f}' for x in fs))
        print('FOLD_MDD,'+name+','+','.join(f'{x.mdd:.6%}' for x in fs))
        print('FOLD_CAGR,'+name+','+','.join(f'{x.cagr:.6%}' for x in fs))
    cur=folds['Current'];new=folds['NoSentinel']
    print('COMPARE,sharpe_ge_current='+str(sum(n.sharpe>=c.sharpe for n,c in zip(new,cur)))+'/7,mdd_le_current='+str(sum(n.mdd<=c.mdd+1e-12 for n,c in zip(new,cur)))+'/7')
if __name__=='__main__':main()
