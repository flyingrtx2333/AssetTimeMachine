#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, json, pathlib, sys
from collections import defaultdict

ROOT=pathlib.Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'spikes/344-gold-drawdown-repair/gold_drawdown_repair.py'
BEST=ROOT/'spikes/344-gold-drawdown-repair/best_hit.json'
spec=importlib.util.spec_from_file_location('gdr',SCRIPT)
if spec is None or spec.loader is None: raise RuntimeError(SCRIPT)
gdr=importlib.util.module_from_spec(spec); sys.modules['gdr']=gdr; spec.loader.exec_module(gdr)

def fmt(x): return 'NA' if x is None else f'{x*100:.2f}%'

def replay_rows(panel, op):
    p=dict(gdr.INC['params']); dates=panel.dates; eq=[1.0]; weights={}; rows=[]
    for t in range(1,len(dates)):
        i=t-1
        base=gdr.evt.event_overlay_signal(panel,i,weights,p)
        nw=gdr.repair(panel,i,base,p,op)
        nw={k:v for k,v in nw.items() if v>1e-9}
        turnover=sum(abs(nw.get(a,0)-weights.get(a,0)) for a in set(nw)|set(weights))
        contrib={}; dr=0; valid=True
        for a,w in nw.items():
            c=panel.close[a]
            if not(gdr.finite(c[t]) and gdr.finite(c[t-1]) and c[t-1]>0): valid=False; break
            r=c[t]/c[t-1]-1; contrib[a]=w*r; dr+=w*r
        if not valid: contrib={}; dr=0
        net=dr-turnover*gdr.FEE
        eq.append(max(eq[-1]*(1+net),1e-9))
        repaired=nw.get('gold',0)<base.get('gold',0)-1e-9
        rows.append({'date':dates[t],'equity':eq[-1],'ret':net,'weights':dict(nw),'contrib':contrib,'repaired':repaired})
        weights=nw
    return rows, eq

def dds(rows):
    peak=rows[0]['equity']; pi=0; out=[]; indd=False; ti=0; td=0
    for i,r in enumerate(rows):
        e=r['equity']
        if e>=peak:
            if indd: out.append((td,pi,ti,i-1))
            peak=e; pi=i; indd=False; ti=i; td=0
        else:
            d=e/peak-1
            if not indd: indd=True; ti=i; td=d
            elif d<td: ti=i; td=d
    if indd: out.append((td,pi,ti,len(rows)-1))
    return sorted(out,key=lambda x:x[0])

def summarize(rows,a,b):
    c=defaultdict(float); w=defaultdict(float); repairs=0; ret=1.0; days=b-a+1
    worst=[]
    for r in rows[a:b+1]:
        ret*=1+r['ret']; repairs+=int(r['repaired'])
        for k,v in r['contrib'].items(): c[k]+=v
        for k,v in r['weights'].items(): w[k]+=v
        worst.append((r['ret'],r['date'],r['weights'],r['contrib'],r['repaired']))
    worst=sorted(worst)[:5]
    return {'ret':ret-1,'repairs':repairs,'avg_weights':{k:v/days for k,v in w.items()},'contrib':dict(c),'worst':worst}

def main():
    best=json.loads(BEST.read_text())
    panel=gdr.s.align(gdr.s.parse_series(gdr.s.fetch()))
    r=gdr.replay(panel,best['overlay'])
    print('EXACT_REPLAY')
    print('Full', fmt(r.metrics['cagr']), fmt(r.metrics['max_dd']), f"Sharpe={r.metrics['sharpe']:.4f}")
    for k in ['2020+','10y','2022+']:
        m=r.slice_metrics[k]
        print(k, fmt(m['cagr']), fmt(m['max_dd']), f"Sharpe={m['sharpe']:.4f}")
    print('stats', r.stats, 'promotion', gdr.promotion(r))
    rows,eq=replay_rows(panel,best['overlay'])
    print('\nTop drawdowns:')
    out=[]
    for rank,(dd,a,t,e) in enumerate(dds(rows)[:8],1):
        s=summarize(rows,a,t)
        item={'rank':rank,'dd':dd,'peak':rows[a]['date'],'trough':rows[t]['date'],'end':rows[e]['date'],'summary':s}
        out.append(item)
        print(f"#{rank} DD={dd*100:.2f}% peak={rows[a]['date']} trough={rows[t]['date']} end={rows[e]['date']} ret={s['ret']*100:.2f}% repairs={s['repairs']}")
        print(' avg_w', {k:round(v,3) for k,v in s['avg_weights'].items()}, 'contrib', {k:round(v*100,2) for k,v in s['contrib'].items()})
    p=pathlib.Path(__file__).resolve().parent/'verify_exact.json'
    p.write_text(json.dumps({'metrics':r.metrics,'slice_metrics':r.slice_metrics,'stats':r.stats,'promotion':gdr.promotion(r),'drawdowns':out},ensure_ascii=False,indent=2),encoding='utf-8')
    print('\nWrote',p)
if __name__=='__main__': main()
