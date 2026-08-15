#!/usr/bin/env python3
"""Score the preregistered LowNoise structural-smoothing V2 family.

Protocol: docs/strategies/structural-smoothing-validation-v2-2026-08-14.md
No parameter search occurs here. The script only evaluates V2-0..V2-5 paths already generated
by the exact Swift App engine.
"""
from __future__ import annotations

import csv
import math
import random
import statistics
from dataclasses import dataclass
from datetime import date
from pathlib import Path

SQRT252 = math.sqrt(252.0)
FILES = [Path(f'/private/tmp/v2_{i}.csv') for i in range(6)]
NAMES = [
    'V2_0_hard_current',
    'V2_1_soft25_current_scale',
    'V2_2_soft20_current_scale',
    'V2_3_hard25_unified120',
    'V2_4_soft25_unified120',
    'V2_5_soft25_no_active_scale',
]
FOLDS = [
    ('F1_2012_2014', '2012-07-05', '2014-12-31'),
    ('F2_2015_2016', '2015-01-01', '2016-12-31'),
    ('F3_2017_2018', '2017-01-01', '2018-12-31'),
    ('F4_2019_2020', '2019-01-01', '2020-12-31'),
    ('F5_2021_2022', '2021-01-01', '2022-12-31'),
    ('F6_2023_2024', '2023-01-01', '2024-12-31'),
    ('F7_2025_latest', '2025-01-01', '9999-12-31'),
]


@dataclass(frozen=True)
class M:
    cagr: float
    mdd: float
    vol: float
    sharpe: float


def load(path: Path) -> tuple[list[str], list[float]]:
    dates=[]; vals=[]
    for row in csv.DictReader(path.open(encoding='utf-8')):
        try: v=float(row['portfolio_value'])
        except (KeyError, TypeError, ValueError): continue
        if math.isfinite(v) and v>0:
            dates.append(row['date']); vals.append(v)
    if len(vals)<100: raise RuntimeError(f'insufficient rows {path}: {len(vals)}')
    return dates,vals


def metrics(vals: list[float], dates: list[str] | None=None) -> M:
    if len(vals)<3: return M(0,0,0,0)
    r=[vals[i]/vals[i-1]-1 for i in range(1,len(vals))]
    mu=statistics.fmean(r); sd=statistics.stdev(r)
    vol=sd*SQRT252; sh=mu/sd*SQRT252 if sd>1e-18 else 0
    peak=vals[0]; mdd=0
    for v in vals:
        peak=max(peak,v); mdd=max(mdd,1-v/peak)
    if dates:
        years=max((date.fromisoformat(dates[-1])-date.fromisoformat(dates[0])).days/365.2425,1/365.2425)
    else:
        years=max((len(vals)-1)/252,1/252)
    cagr=(vals[-1]/vals[0])**(1/years)-1
    return M(cagr,mdd,vol,sh)


def slice_values(dates: list[str], vals: list[float], start: str, end: str) -> tuple[list[str],list[float]]:
    idx=[i for i,d in enumerate(dates) if start<=d<=end]
    return [dates[i] for i in idx],[vals[i] for i in idx]


def percentile(xs:list[float],q:float)->float:
    ys=sorted(xs); p=(len(ys)-1)*q; lo=int(math.floor(p)); hi=int(math.ceil(p))
    if lo==hi:return ys[lo]
    w=p-lo; return ys[lo]*(1-w)+ys[hi]*w


def bootstrap(vals:list[float],block:int=63,reps:int=1800,seed:int=20260814)->tuple[float,float,float,float]:
    r=[vals[i]/vals[i-1]-1 for i in range(1,len(vals))]; n=len(r); rng=random.Random(seed)
    sharpes=[]; mdds=[]
    for _ in range(reps):
        s=[]
        while len(s)<n:
            j=rng.randrange(n)
            for k in range(block):
                s.append(r[(j+k)%n])
                if len(s)>=n:break
        v=[1.0]
        for x in s:v.append(v[-1]*(1+x))
        mm=metrics(v); sharpes.append(mm.sharpe);mdds.append(mm.mdd)
    return percentile(sharpes,.025),percentile(sharpes,.5),percentile(mdds,.5),percentile(mdds,.975)


def robust_score(ms:list[M])->float:
    sh=[m.sharpe for m in ms]
    med=statistics.median(sh); sd=statistics.stdev(sh) if len(sh)>1 else 0
    return med-.5*sd-max(0,max(m.mdd for m in ms)-.10)


def active_stats(base:list[float],cand:list[float],dates:list[str],exclude_fold:int|None=None)->tuple[float,float]:
    x=[]
    for fi,(_,start,end) in enumerate(FOLDS):
        if fi==exclude_fold:continue
        idx=[i for i,d in enumerate(dates) if start<=d<=end]
        for k in range(1,len(idx)):
            i0,i1=idx[k-1],idx[k]
            x.append((cand[i1]/cand[i0]-1)-(base[i1]/base[i0]-1))
    if len(x)<2:return 0,0
    mu=statistics.fmean(x);sd=statistics.stdev(x)
    return mu*252,mu/sd*SQRT252 if sd>1e-18 else 0


def main()->None:
    loaded=[load(p) for p in FILES]
    dates=loaded[0][0]
    if any(d!=dates for d,_ in loaded):raise RuntimeError('V2 dates differ')
    series={n:v for n,(_,v) in zip(NAMES,loaded)}
    full={n:metrics(v,dates) for n,v in series.items()}
    folds={n:[metrics(*reversed(slice_values(dates,v,start,end))) for _,start,end in FOLDS] for n,v in series.items()}
    # Reversed trick above passes vals,dates. Keep explicit sanity below.
    folds={n:[metrics(vv,dd) for _,start,end in FOLDS for dd,vv in [slice_values(dates,v,start,end)]] for n,v in series.items()}
    boots={n:bootstrap(v) for n,v in series.items()}
    base=NAMES[0]

    print('STRUCTURAL_SMOOTHING_V2_VALIDATION')
    print(f'rows={len(dates)},start={dates[0]},end={dates[-1]},protocol=structural-smoothing-validation-v2-2026-08-14')
    print('FULL,name,cagr,mdd,vol,sharpe,robust_score,boot63_sharpe_p025,boot63_sharpe_med,boot63_mdd_med,boot63_mdd_p975')
    for n in NAMES:
        m=full[n];b=boots[n]
        print(f'FULL,{n},{m.cagr:.6%},{m.mdd:.6%},{m.vol:.6%},{m.sharpe:.6f},{robust_score(folds[n]):.6f},{b[0]:.6f},{b[1]:.6f},{b[2]:.6%},{b[3]:.6%}')

    print('FOLD_HEADER,'+','.join(x[0] for x in FOLDS))
    for n in NAMES:
        print('FOLD_SHARPE,'+n+','+','.join(f'{m.sharpe:.6f}' for m in folds[n]))
        print('FOLD_MDD,'+n+','+','.join(f'{m.mdd:.6%}' for m in folds[n]))
        print('FOLD_CAGR,'+n+','+','.join(f'{m.cagr:.6%}' for m in folds[n]))

    bfold=folds[base]
    print('GATES,name,pass,full_sharpe,full_mdd,folds_gt1,worst_fold,fold_sharpe_ge_base,boot_sharpe_p025,boot_mdd_p975,robust_score')
    passed=[]
    for n in NAMES:
        fs=folds[n];m=full[n];bt=boots[n]
        gt1=sum(x.sharpe>1 for x in fs);worst=min(x.sharpe for x in fs);beat=sum(x.sharpe>=b.sharpe for x,b in zip(fs,bfold))
        # Conservative interpretation: use only the explicit 4/7 relative-fold branch.
        ok=m.sharpe>=1.48 and m.mdd<=.09 and gt1>=5 and worst>0 and bt[0]>=1.15 and bt[3]<=.15 and beat>=4
        if ok:passed.append(n)
        print(f'GATES,{n},{"PASS" if ok else "FAIL"},{m.sharpe:.6f},{m.mdd:.6%},{gt1},{worst:.6f},{beat},{bt[0]:.6f},{bt[3]:.6%},{robust_score(fs):.6f}')

    # Soft-band platform diagnostic was preregistered only as a diagnostic, not a selection rule.
    softdiff=abs(full[NAMES[1]].sharpe-full[NAMES[2]].sharpe)
    print(f'SOFT_PLATFORM,soft25_sharpe={full[NAMES[1]].sharpe:.6f},soft20_sharpe={full[NAMES[2]].sharpe:.6f},abs_delta={softdiff:.6f},soft25_mdd={full[NAMES[1]].mdd:.6%},soft20_mdd={full[NAMES[2]].mdd:.6%}')
    print('PASSED,'+('|'.join(passed) if passed else 'none'))

    # Rank passed candidates only by preregistered priority proxy: robust score, then lower MDD, then Sharpe.
    ranked=sorted(passed,key=lambda n:(robust_score(folds[n]),-full[n].mdd,full[n].sharpe),reverse=True)
    if ranked:
        winner=ranked[0]
        print(f'V2_RETROSPECTIVE_RANK1,{winner},robust_score={robust_score(folds[winner]):.6f},cagr={full[winner].cagr:.6%},mdd={full[winner].mdd:.6%},sharpe={full[winner].sharpe:.6f}')
        print('JACKKNIFE_ACTIVE,excluded,ann_mean,active_sharpe')
        for ex in range(7):
            am,ash=active_stats(series[base],series[winner],dates,ex)
            print(f'JACKKNIFE_ACTIVE,{FOLDS[ex][0]},{am:.6%},{ash:.6f}')

if __name__=='__main__':main()
