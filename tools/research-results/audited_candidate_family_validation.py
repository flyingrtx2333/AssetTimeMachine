#!/usr/bin/env python3
"""Validate the preregistered audited candidate family.

Protocol is frozen in docs/strategies/retrospective-nested-optimization-v1-2026-08-14.md.
This script only combines already-defined sleeves and scores them. It does not tune parameters.
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

CORE = Path('/private/tmp/audited_candidate_family_core.csv')
BAND090 = Path('/private/tmp/audited_candidate_band090.csv')
BAND100 = Path('/private/tmp/audited_candidate_band100.csv')
BAND110 = Path('/private/tmp/audited_candidate_band110.csv')
BASE = Path('tools/research-results/daily_factor_panel.csv')
OUT = Path('/private/tmp/audited_candidate_family_final.csv')

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
    total_return: float


def read_panel(path: Path) -> tuple[list[str], dict[str, list[float]]]:
    rows = list(csv.DictReader(path.open(encoding='utf-8')))
    if not rows:
        raise RuntimeError(f'empty panel: {path}')
    names = [k for k in rows[0].keys() if k != 'date']
    dates: list[str] = []
    cols = {name: [] for name in names}
    for row in rows:
        d = row['date']
        try:
            vals = {name: float(row[name]) for name in names}
        except (ValueError, TypeError):
            continue
        if not all(math.isfinite(v) and v > 0 for v in vals.values()):
            continue
        dates.append(d)
        for name in names:
            cols[name].append(vals[name])
    return dates, cols


def metrics(values: list[float], dates: list[str] | None = None) -> M:
    if len(values) < 3:
        return M(0, 0, 0, 0, 0)
    r = [values[i] / values[i-1] - 1 for i in range(1, len(values))]
    mean = statistics.fmean(r)
    sd = statistics.stdev(r)
    vol = sd * SQRT252
    sharpe = mean / sd * SQRT252 if sd > 1e-18 else 0.0
    peak = values[0]
    mdd = 0.0
    for v in values:
        peak = max(peak, v)
        mdd = max(mdd, 1 - v / peak)
    total = values[-1] / values[0] - 1
    if dates:
        years = max((date.fromisoformat(dates[-1]) - date.fromisoformat(dates[0])).days / 365.2425, 1/365.2425)
    else:
        years = max((len(values)-1)/252.0, 1/252.0)
    cagr = (values[-1] / values[0]) ** (1/years) - 1
    return M(cagr, mdd, vol, sharpe, total)


def subset(dates: list[str], values: list[float], start: str, end: str) -> tuple[list[str], list[float]]:
    idx = [i for i,d in enumerate(dates) if start <= d <= end]
    return [dates[i] for i in idx], [values[i] for i in idx]


def percentile(xs: list[float], q: float) -> float:
    ys = sorted(xs)
    if not ys:
        return float('nan')
    pos = (len(ys)-1)*q
    lo = int(math.floor(pos)); hi = int(math.ceil(pos))
    if lo == hi: return ys[lo]
    w = pos-lo
    return ys[lo]*(1-w)+ys[hi]*w


def bootstrap(values: list[float], block: int = 63, reps: int = 1600, seed: int = 20260814) -> tuple[float,float,float,float,float,float]:
    r = [values[i]/values[i-1]-1 for i in range(1,len(values))]
    n=len(r); rng=random.Random(seed)
    sharpes=[]; mdds=[]
    for _ in range(reps):
        s=[]
        while len(s)<n:
            j=rng.randrange(n)
            for k in range(block):
                s.append(r[(j+k)%n])
                if len(s)>=n: break
        v=[1.0]
        for x in s: v.append(v[-1]*(1+x))
        mm=metrics(v)
        sharpes.append(mm.sharpe); mdds.append(mm.mdd)
    return (
        percentile(sharpes,.025), percentile(sharpes,.50), percentile(sharpes,.975),
        percentile(mdds,.025), percentile(mdds,.50), percentile(mdds,.975),
    )


def combine_panels() -> tuple[list[str], dict[str,list[float]]]:
    core_dates, core = read_panel(CORE)
    d90,c90=read_panel(BAND090); d100,c100=read_panel(BAND100); d110,c110=read_panel(BAND110)
    if not (core_dates == d90 == d100 == d110):
        raise RuntimeError('candidate panel dates differ')
    c4name='C4_low_noise_param_ensemble'
    c4=[
        (a+b+c)/3.0
        for a,b,c in zip(c90[c4name], c100[c4name], c110[c4name])
    ]
    final={
        'C0_low_noise_c3l3': core['C0_low_noise_c3l3'],
        'C1_cash_c3l3': core['C1_cash_c3l3'],
        'C2_cash_c3l3_scale130': core['C2_cash_c3l3_scale130'],
        'C3_simple_scale_ensemble': core['C3_simple_scale_ensemble'],
        'C4_low_noise_param_ensemble': c4,
        'C5_dual_core_5050': core['C5_dual_core_5050'],
    }
    with OUT.open('w', newline='', encoding='utf-8') as f:
        w=csv.writer(f); names=list(final); w.writerow(['date',*names])
        for i,d in enumerate(core_dates): w.writerow([d,*[f'{final[n][i]:.10f}' for n in names]])
    return core_dates, final


def base_aligned(dates: list[str]) -> list[float]:
    mp: dict[str, float] = {}
    for row in csv.DictReader(BASE.open(encoding='utf-8')):
        try:
            value = float(row['portfolio_value'])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(value) and value > 0:
            mp[row['date']] = value
    return [mp[d] for d in dates]


def fold_metrics(dates: list[str], values: list[float]) -> list[M]:
    out=[]
    for _,start,end in FOLDS:
        dd,vv=subset(dates,values,start,end)
        out.append(metrics(vv,dd))
    return out


def robust_score(ms: list[M]) -> float:
    sharpes=[m.sharpe for m in ms]
    med=statistics.median(sharpes)
    sd=statistics.stdev(sharpes) if len(sharpes)>1 else 0
    worst_mdd=max(m.mdd for m in ms)
    return med - .50*sd - max(0.0,worst_mdd-.10)


def chain_selected_returns(dates: list[str], candidates: dict[str,list[float]], selections: list[tuple[int,str]]) -> tuple[list[float], list[str]]:
    out=[1.0]; out_dates=[]
    for fold_index,name in selections:
        _,start,end=FOLDS[fold_index]
        v=candidates[name]
        idx=[i for i,d in enumerate(dates) if start<=d<=end]
        if len(idx)<2: continue
        for k in range(1,len(idx)):
            i0,i1=idx[k-1],idx[k]
            ret=v[i1]/v[i0]-1
            out.append(out[-1]*(1+ret)); out_dates.append(dates[i1])
    if out_dates:
        return out, [out_dates[0]] + out_dates
    return out, []


def main() -> None:
    dates,candidates=combine_panels()
    base=base_aligned(dates)
    all_series={'BASE_low_noise':base,**candidates}
    full={name:metrics(v,dates) for name,v in all_series.items()}
    folds={name:fold_metrics(dates,v) for name,v in all_series.items()}
    boots={name:bootstrap(v) for name,v in all_series.items()}

    print('AUDITED_CANDIDATE_FAMILY_VALIDATION_V1')
    print(f'rows={len(dates)},start={dates[0]},end={dates[-1]},candidates={len(candidates)},protocol=retrospective-nested-optimization-v1-2026-08-14')
    print('FULL,name,cagr,mdd,vol,sharpe,robust_score,block63_sharpe_p025,block63_sharpe_med,block63_mdd_med,block63_mdd_p975')
    for name in all_series:
        m=full[name]; b=boots[name]
        rs=robust_score(folds[name])
        print(f'FULL,{name},{m.cagr:.6%},{m.mdd:.6%},{m.vol:.6%},{m.sharpe:.6f},{rs:.6f},{b[0]:.6f},{b[1]:.6f},{b[4]:.6%},{b[5]:.6%}')

    print('FOLDS,name,'+','.join(f[0] for f in FOLDS))
    for name in all_series:
        print('FOLD_SHARPE,'+name+','+','.join(f'{m.sharpe:.6f}' for m in folds[name]))
        print('FOLD_MDD,'+name+','+','.join(f'{m.mdd:.6%}' for m in folds[name]))
        print('FOLD_CAGR,'+name+','+','.join(f'{m.cagr:.6%}' for m in folds[name]))

    # Walk-forward selector: from fold 3 (zero-based index 2), only prior folds are scored.
    selections=[]
    print('WALK_FORWARD,fold,selected,train_score,test_sharpe,test_mdd,test_cagr')
    names=list(candidates)
    for test_idx in range(2,len(FOLDS)):
        scored=[]
        for name in names:
            train=folds[name][:test_idx]
            scored.append((robust_score(train),name))
        score,name=max(scored,key=lambda x:(x[0],x[1]))
        tm=folds[name][test_idx]
        selections.append((test_idx,name))
        print(f'WALK_FORWARD,{FOLDS[test_idx][0]},{name},{score:.6f},{tm.sharpe:.6f},{tm.mdd:.6%},{tm.cagr:.6%}')
    sv,sd=chain_selected_returns(dates,candidates,selections)
    wf=metrics(sv,sd if sd else None)
    # corresponding baseline folds 3..7
    bv,bd=chain_selected_returns(dates,{'BASE_low_noise':base},[(i,'BASE_low_noise') for i in range(2,len(FOLDS))])
    bwm=metrics(bv,bd if bd else None)
    print(f'WALK_FORWARD_AGG,selected,cagr={wf.cagr:.6%},mdd={wf.mdd:.6%},sharpe={wf.sharpe:.6f}')
    print(f'WALK_FORWARD_AGG,base,cagr={bwm.cagr:.6%},mdd={bwm.mdd:.6%},sharpe={bwm.sharpe:.6f}')

    # Hard preregistered gates and retrospective ranking.
    base_fold=folds['BASE_low_noise']
    start_nfci=next(i for i,d in enumerate(dates) if d>='2012-07-05')
    base_nfci=metrics(base[start_nfci:],dates[start_nfci:])
    print('GATES,name,pass,full_sharpe,full_mdd,folds_sharpe_gt1,worst_fold_sharpe,fold_sharpe_beats_base,nfci_sharpe_delta,boot_sharpe_p025,boot_mdd_p975')
    passed=[]
    for name in names:
        fm=full[name]; fs=folds[name]; bt=boots[name]
        gt1=sum(m.sharpe>1 for m in fs)
        worst=min(m.sharpe for m in fs)
        beat=sum(m.sharpe>=b.sharpe for m,b in zip(fs,base_fold))
        nm=metrics(candidates[name][start_nfci:],dates[start_nfci:])
        delta=nm.sharpe-base_nfci.sharpe
        ok=(fm.sharpe>=1.48 and fm.mdd<=.09 and gt1>=5 and worst>0 and (beat>=4 or delta>=.02) and bt[0]>=1.15 and bt[5]<=.15)
        if ok: passed.append(name)
        print(f'GATES,{name},{"PASS" if ok else "FAIL"},{fm.sharpe:.6f},{fm.mdd:.6%},{gt1},{worst:.6f},{beat},{delta:.6f},{bt[0]:.6f},{bt[5]:.6%}')

    # Rank only among candidates that passed, using the preregistered robustness score, not full Sharpe.
    ranked=sorted(passed,key=lambda n:(robust_score(folds[n]),full[n].sharpe),reverse=True)
    print('PASSED,'+('|'.join(ranked) if ranked else 'none'))
    if ranked:
        winner=ranked[0]
        print(f'RETROSPECTIVE_WINNER,{winner},robust_score={robust_score(folds[winner]):.6f},full_sharpe={full[winner].sharpe:.6f},full_cagr={full[winner].cagr:.6%},full_mdd={full[winner].mdd:.6%}')
        # leave-one-fold-out active-return sign / active Sharpe versus base
        win=candidates[winner]
        print('FOLD_JACKKNIFE,excluded,active_ann_mean,active_sharpe')
        for ex in range(len(FOLDS)):
            active=[]
            for fi,(_,start,end) in enumerate(FOLDS):
                if fi==ex: continue
                idx=[i for i,d in enumerate(dates) if start<=d<=end]
                for k in range(1,len(idx)):
                    i0,i1=idx[k-1],idx[k]
                    active.append((win[i1]/win[i0]-1)-(base[i1]/base[i0]-1))
            mu=statistics.fmean(active); sdv=statistics.stdev(active)
            ash=mu/sdv*SQRT252 if sdv>1e-18 else 0
            print(f'FOLD_JACKKNIFE,{FOLDS[ex][0]},{mu*252:.6%},{ash:.6f}')


if __name__=='__main__':
    main()
