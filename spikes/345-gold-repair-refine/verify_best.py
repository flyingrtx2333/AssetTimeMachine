#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, json, pathlib, sys
from collections import defaultdict

ROOT=pathlib.Path(__file__).resolve().parents[2]
GDR=ROOT/'spikes/344-gold-drawdown-repair/gold_drawdown_repair.py'
BEST=ROOT/'spikes/345-gold-repair-refine/best_hit.json'
BASE344=ROOT/'spikes/344-gold-drawdown-repair/best_hit.json'
spec=importlib.util.spec_from_file_location('gdr',GDR)
if spec is None or spec.loader is None: raise RuntimeError(GDR)
gdr=importlib.util.module_from_spec(spec); sys.modules['gdr']=gdr; spec.loader.exec_module(gdr)

def fmt(x): return 'NA' if x is None else f'{x*100:.2f}%'

def rows(panel,op):
    p=dict(gdr.INC['params']); dates=panel.dates; eq=[1.0]; weights={}; out=[]
    for t in range(1,len(dates)):
        i=t-1; base=gdr.evt.event_overlay_signal(panel,i,weights,p); nw=gdr.repair(panel,i,base,p,op); nw={k:v for k,v in nw.items() if v>1e-9}
        turnover=sum(abs(nw.get(a,0)-weights.get(a,0)) for a in set(nw)|set(weights)); dr=0; contrib={}; valid=True
        for a,w in nw.items():
            c=panel.close[a]
            if not(gdr.finite(c[t]) and gdr.finite(c[t-1]) and c[t-1]>0): valid=False; break
            rr=c[t]/c[t-1]-1; dr+=w*rr; contrib[a]=w*rr
        if not valid: dr=0; contrib={}
        net=dr-turnover*gdr.FEE; eq.append(max(eq[-1]*(1+net),1e-9))
        out.append({'date':dates[t],'equity':eq[-1],'ret':net,'weights':dict(nw),'contrib':contrib,'repair':nw.get('gold',0)<base.get('gold',0)-1e-9})
        weights=nw
    return out

def dds(rs):
    peak=rs[0]['equity']; pi=0; ans=[]; indd=False; ti=0; td=0
    for i,r in enumerate(rs):
        e=r['equity']
        if e>=peak:
            if indd: ans.append((td,pi,ti,i-1))
            peak=e; pi=i; indd=False; td=0
        else:
            d=e/peak-1
            if not indd: indd=True; ti=i; td=d
            elif d<td: td=d; ti=i
    if indd: ans.append((td,pi,ti,len(rs)-1))
    return sorted(ans,key=lambda x:x[0])

def summ(rs,a,b):
    c=defaultdict(float); w=defaultdict(float); rep=0; ret=1; n=b-a+1
    for r in rs[a:b+1]:
        ret*=1+r['ret']; rep+=int(r['repair'])
        for k,v in r['contrib'].items(): c[k]+=v
        for k,v in r['weights'].items(): w[k]+=v
    return {'ret':ret-1,'repairs':rep,'avg_weights':{k:v/n for k,v in w.items()},'contrib':dict(c)}

def print_metrics(label,r):
    print(label, fmt(r.metrics['cagr']), fmt(r.metrics['max_dd']), f"Sharpe={r.metrics['sharpe']:.4f}")
    for k in ['2020+','10y','2022+']:
        m=r.slice_metrics[k]; print(' ',k,fmt(m['cagr']),fmt(m['max_dd']),f"Sharpe={m['sharpe']:.4f}")
    print(' stats',r.stats,'tail',r.weights_tail[-1][1])

def main():
    best=json.loads(BEST.read_text()); base=json.loads(BASE344.read_text())
    panel=gdr.s.align(gdr.s.parse_series(gdr.s.fetch()))
    rb=gdr.replay(panel,base['overlay']); rr=gdr.replay(panel,best['overlay'])
    print_metrics('BASE344',rb); print(); print_metrics('REFINED',rr)
    rs=rows(panel,best['overlay']); outs=[]
    print('\nREFINED top drawdowns:')
    for i,(dd,a,t,e) in enumerate(dds(rs)[:8],1):
        s=summ(rs,a,t); outs.append({'rank':i,'dd':dd,'peak':rs[a]['date'],'trough':rs[t]['date'],'end':rs[e]['date'],'summary':s})
        print(f"#{i} DD={dd*100:.2f}% peak={rs[a]['date']} trough={rs[t]['date']} end={rs[e]['date']} ret={s['ret']*100:.2f}% repairs={s['repairs']} avg_w={ {k:round(v,3) for k,v in s['avg_weights'].items()} } contrib={ {k:round(v*100,2) for k,v in s['contrib'].items()} }")
    out=pathlib.Path(__file__).resolve().parent/'verify_best.json'
    out.write_text(json.dumps({'base344':{'metrics':rb.metrics,'slice_metrics':rb.slice_metrics,'stats':rb.stats},'refined':{'metrics':rr.metrics,'slice_metrics':rr.slice_metrics,'stats':rr.stats,'weights_tail':rr.weights_tail},'drawdowns':outs},ensure_ascii=False,indent=2),encoding='utf-8')
    print('\nWrote',out)
if __name__=='__main__': main()
