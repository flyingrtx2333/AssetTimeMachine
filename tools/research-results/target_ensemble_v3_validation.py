#!/usr/bin/env python3
"""Evaluate preregistered target-ensemble V3 candidates."""
from __future__ import annotations
import csv, math, random, statistics
from dataclasses import dataclass
from datetime import date
from pathlib import Path

SQRT252=math.sqrt(252.0)
FILES={
 'V3_0_C0':Path('/private/tmp/v2_0.csv'),
 'V3_1_Bag9':Path('/private/tmp/v3_bag9_b25.csv'),
 'V3_2_DualCore':Path('/private/tmp/v3_dual.csv'),
 'V3_3_TripleCore':Path('/private/tmp/v3_triple.csv'),
}
BAG_DIAG={'b20':Path('/private/tmp/v3_bag9_b20.csv'),'b25':Path('/private/tmp/v3_bag9_b25.csv'),'b30':Path('/private/tmp/v3_bag9_b30.csv')}
FOLDS=[
 ('F1_2012_2014','2012-07-05','2014-12-31'),('F2_2015_2016','2015-01-01','2016-12-31'),
 ('F3_2017_2018','2017-01-01','2018-12-31'),('F4_2019_2020','2019-01-01','2020-12-31'),
 ('F5_2021_2022','2021-01-01','2022-12-31'),('F6_2023_2024','2023-01-01','2024-12-31'),
 ('F7_2025_latest','2025-01-01','9999-12-31')]

@dataclass(frozen=True)
class M: cagr:float;mdd:float;vol:float;sharpe:float

def load(p:Path):
 r=list(csv.DictReader(p.open(encoding='utf-8')));d=[];v=[]
 for x in r:
  try:y=float(x['portfolio_value'])
  except:continue
  if math.isfinite(y) and y>0:d.append(x['date']);v.append(y)
 return d,v

def met(v,d=None):
 if len(v)<3:return M(0,0,0,0)
 r=[v[i]/v[i-1]-1 for i in range(1,len(v))];mu=statistics.fmean(r);sd=statistics.stdev(r)
 pk=v[0];dd=0
 for x in v:pk=max(pk,x);dd=max(dd,1-x/pk)
 yrs=((date.fromisoformat(d[-1])-date.fromisoformat(d[0])).days/365.2425) if d else (len(v)-1)/252
 return M((v[-1]/v[0])**(1/max(yrs,1/365.2425))-1,dd,sd*SQRT252,mu/sd*SQRT252 if sd else 0)

def sub(d,v,a,b):
 ix=[i for i,x in enumerate(d) if a<=x<=b];return [d[i] for i in ix],[v[i] for i in ix]

def pct(x,q):
 y=sorted(x);p=(len(y)-1)*q;l=int(p);h=math.ceil(p);w=p-l
 return y[l] if l==h else y[l]*(1-w)+y[h]*w

def boot(v,reps=1800,block=63):
 r=[v[i]/v[i-1]-1 for i in range(1,len(v))];n=len(r);rng=random.Random(20260814);ss=[];dd=[]
 for _ in range(reps):
  q=[]
  while len(q)<n:
   j=rng.randrange(n)
   for k in range(block):
    q.append(r[(j+k)%n])
    if len(q)>=n:break
  x=[1.0]
  for z in q:x.append(x[-1]*(1+z))
  m=met(x);ss.append(m.sharpe);dd.append(m.mdd)
 return pct(ss,.025),pct(ss,.5),pct(dd,.5),pct(dd,.975)

def score(ms):
 s=[x.sharpe for x in ms];return statistics.median(s)-.5*statistics.stdev(s)-max(0,max(x.mdd for x in ms)-.10)

def active(base,cand,d,exclude=None):
 z=[]
 for fi,(_,a,b) in enumerate(FOLDS):
  if fi==exclude:continue
  ix=[i for i,x in enumerate(d) if a<=x<=b]
  for k in range(1,len(ix)):
   i0,i1=ix[k-1],ix[k];z.append((cand[i1]/cand[i0]-1)-(base[i1]/base[i0]-1))
 mu=statistics.fmean(z);sd=statistics.stdev(z);return mu*252,mu/sd*SQRT252 if sd else 0

def main():
 L={n:load(p) for n,p in FILES.items()};d=L['V3_0_C0'][0]
 if any(x[0]!=d for x in L.values()):raise RuntimeError('dates differ')
 V={n:x[1] for n,x in L.items()};full={n:met(v,d) for n,v in V.items()}
 folds={n:[met(vv,dd) for _,a,b in FOLDS for dd,vv in [sub(d,v,a,b)]] for n,v in V.items()};boots={n:boot(v) for n,v in V.items()}
 base='V3_0_C0';bf=folds[base];bm=full[base]
 diag={n:met(*reversed(load(p))) for n,p in BAG_DIAG.items()}
 # explicit recompute to avoid positional ambiguity
 diag={n:met(v,dd) for n,p in BAG_DIAG.items() for dd,v in [load(p)]}
 spread=max(x.sharpe for x in diag.values())-min(x.sharpe for x in diag.values())
 print('TARGET_ENSEMBLE_V3_VALIDATION')
 print('FULL,name,cagr,mdd,vol,sharpe,robust_score,boot_s_p025,boot_s_med,boot_mdd_med,boot_mdd_p975')
 for n in FILES:
  m=full[n];b=boots[n];print(f'FULL,{n},{m.cagr:.6%},{m.mdd:.6%},{m.vol:.6%},{m.sharpe:.6f},{score(folds[n]):.6f},{b[0]:.6f},{b[1]:.6f},{b[2]:.6%},{b[3]:.6%}')
 print('FOLD_HEADER,'+','.join(x[0] for x in FOLDS))
 for n in FILES:
  print('FOLD_SHARPE,'+n+','+','.join(f'{x.sharpe:.6f}' for x in folds[n]));print('FOLD_MDD,'+n+','+','.join(f'{x.mdd:.6%}' for x in folds[n]));print('FOLD_CAGR,'+n+','+','.join(f'{x.cagr:.6%}' for x in folds[n]))
 print('BAG9_BAND_DIAG,'+','.join(f'{n}_sharpe={m.sharpe:.6f}' for n,m in diag.items())+f',spread={spread:.6f}')
 print('GATES,name,pass,full_cagr,full_mdd,full_sharpe,folds_gt1,worst_fold,fold_ge_c0,mdd_improve_pp,sharpe_gap,boot_s_p025,boot_mdd_p975,robust_score')
 passed=[]
 for n in FILES:
  if n==base:continue
  m=full[n];fs=folds[n];b=boots[n];gt=sum(x.sharpe>1 for x in fs);worst=min(x.sharpe for x in fs);beat=sum(x.sharpe>=y.sharpe for x,y in zip(fs,bf));mdi=(bm.mdd-m.mdd)*100;gap=bm.sharpe-m.sharpe
  relative=beat>=4 or (gap<=.03 and mdi>=.30)
  bagok=(spread<=.06) if n=='V3_1_Bag9' else True
  ok=m.sharpe>=1.50 and m.mdd<=.085 and m.cagr>=.14 and gt>=5 and worst>0 and relative and b[0]>=1.18 and b[3]<=.15 and bagok
  if ok:passed.append(n)
  print(f'GATES,{n},{"PASS" if ok else "FAIL"},{m.cagr:.6%},{m.mdd:.6%},{m.sharpe:.6f},{gt},{worst:.6f},{beat},{mdi:.6f},{gap:.6f},{b[0]:.6f},{b[3]:.6%},{score(fs):.6f}')
 print('PASSED,'+('|'.join(passed) if passed else 'none'))
 ranked=sorted(passed,key=lambda n:(score(folds[n]),-boots[n][3],full[n].sharpe),reverse=True)
 if ranked:
  w=ranked[0];print(f'V3_RETROSPECTIVE_RANK1,{w},score={score(folds[w]):.6f},cagr={full[w].cagr:.6%},mdd={full[w].mdd:.6%},sharpe={full[w].sharpe:.6f}')
  print('JACKKNIFE_ACTIVE,excluded,ann_mean,active_sharpe')
  for i in range(7):
   a,s=active(V[base],V[w],d,i);print(f'JACKKNIFE_ACTIVE,{FOLDS[i][0]},{a:.6%},{s:.6f}')
if __name__=='__main__':main()
