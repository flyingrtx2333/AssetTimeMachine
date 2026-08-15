#!/usr/bin/env python3
from __future__ import annotations
import csv, math, random, statistics
from dataclasses import dataclass
from datetime import date
from pathlib import Path

SQRT252 = math.sqrt(252.0)
FILES = {
    'Current': Path('/private/tmp/V5_0_current.csv'),
    'Unified122': Path('/private/tmp/V9_1_unified122.csv'),
}
FOLDS = [
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
    cagr: float
    mdd: float
    vol: float
    sharpe: float

def load(path: Path):
    dates=[]; vals=[]
    for row in csv.DictReader(path.open(encoding='utf-8')):
        try: value=float(row['portfolio_value'])
        except (KeyError, TypeError, ValueError): continue
        if math.isfinite(value) and value>0:
            dates.append(row['date']); vals.append(value)
    if len(vals)<100: raise RuntimeError(f'insufficient rows: {path}')
    return dates, vals

def metrics(dates, vals):
    if len(vals)<3: return M(0,0,0,0)
    returns=[vals[i]/vals[i-1]-1 for i in range(1,len(vals))]
    mean=statistics.fmean(returns); sd=statistics.stdev(returns)
    peak=vals[0]; mdd=0.0
    for value in vals:
        peak=max(peak,value); mdd=max(mdd,1-value/peak)
    years=max((date.fromisoformat(dates[-1])-date.fromisoformat(dates[0])).days/365.2425,1/365.2425)
    return M((vals[-1]/vals[0])**(1/years)-1,mdd,sd*SQRT252,mean/sd*SQRT252 if sd else 0)

def sliced(dates, vals, start, end):
    indices=[i for i,d in enumerate(dates) if start<=d<=end]
    return [dates[i] for i in indices],[vals[i] for i in indices]

def percentile(values,q):
    values=sorted(values); pos=(len(values)-1)*q; lo=int(math.floor(pos)); hi=int(math.ceil(pos))
    if lo==hi: return values[lo]
    weight=pos-lo
    return values[lo]*(1-weight)+values[hi]*weight

def bootstrap(vals, reps=3000, block=63, seed=20260815):
    returns=[vals[i]/vals[i-1]-1 for i in range(1,len(vals))]
    n=len(returns); rng=random.Random(seed); sharpes=[]; mdds=[]
    fake_dates=[date.fromordinal(date(2000,1,1).toordinal()+i).isoformat() for i in range(n+1)]
    for _ in range(reps):
        sample=[]
        while len(sample)<n:
            start=rng.randrange(n)
            for k in range(block):
                sample.append(returns[(start+k)%n])
                if len(sample)>=n: break
        values=[1.0]
        for r in sample: values.append(values[-1]*(1+r))
        m=metrics(fake_dates,values); sharpes.append(m.sharpe); mdds.append(m.mdd)
    return percentile(sharpes,.025),percentile(sharpes,.5),percentile(mdds,.5),percentile(mdds,.975)

def main():
    loaded={name:load(path) for name,path in FILES.items()}
    dates=loaded['Current'][0]
    if any(ds!=dates for ds,_ in loaded.values()): raise RuntimeError('date mismatch')
    folds={}
    full={}
    boots={}
    print('ACTIVE_SCALE_COLLAPSE_V9_VALIDATION')
    for name,(ds,vals) in loaded.items():
        full[name]=metrics(ds,vals); boots[name]=bootstrap(vals)
        fs=[]
        for _,start,end in FOLDS:
            fd,fv=sliced(ds,vals,start,end); fs.append(metrics(fd,fv))
        folds[name]=fs
        m=full[name]; b=boots[name]
        print(f'FULL,{name},cagr={m.cagr:.6%},mdd={m.mdd:.6%},vol={m.vol:.6%},sharpe={m.sharpe:.6f},boot_sh_p025={b[0]:.6f},boot_sh_med={b[1]:.6f},boot_mdd_med={b[2]:.6%},boot_mdd_p975={b[3]:.6%}')
        print('FOLD_SHARPE,'+name+','+','.join(f'{x.sharpe:.6f}' for x in fs))
        print('FOLD_MDD,'+name+','+','.join(f'{x.mdd:.6%}' for x in fs))
        print('FOLD_CAGR,'+name+','+','.join(f'{x.cagr:.6%}' for x in fs))
    cur=folds['Current']; cand=folds['Unified122']; cm=full['Current']; m=full['Unified122']; bt=boots['Unified122']
    gt1=sum(x.sharpe>1 for x in cand); worst=min(x.sharpe for x in cand); beat_sh=sum(x.sharpe>=y.sharpe for x,y in zip(cand,cur)); better_dd=sum(x.mdd<=y.mdd+1e-12 for x,y in zip(cand,cur))
    ok=(m.cagr>=.14 and m.sharpe>=1.50 and m.mdd<=.085 and gt1>=5 and worst>0 and bt[0]>=1.15 and bt[3]<=.15 and abs(m.sharpe-cm.sharpe)<=.035)
    print(f'GATES,Unified122,{"PASS" if ok else "FAIL"},folds_sharpe_gt1={gt1}/7,worst_fold={worst:.6f},fold_sharpe_ge_current={beat_sh}/7,fold_mdd_le_current={better_dd}/7,sharpe_delta={m.sharpe-cm.sharpe:.6f}')

if __name__=='__main__': main()
