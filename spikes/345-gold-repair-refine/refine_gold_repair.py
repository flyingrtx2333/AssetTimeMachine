#!/usr/bin/env python3
"""Spike 345 - refine promoted gold-drawdown repair.

The incumbent for this search is no longer refine_buy_permission_only. It is the
research hit from spike 344:
Full 8.44% / -10.93%, Sharpe 0.979, 2020+ 12.60%, 10y 10.59%.

This script only reports candidates that improve the promoted hit, not merely the
old incumbent.
"""
from __future__ import annotations
import importlib.util, json, pathlib, random, sys

ROOT=pathlib.Path(__file__).resolve().parents[2]
GDR_PATH=ROOT/'spikes/344-gold-drawdown-repair/gold_drawdown_repair.py'
BEST_PATH=ROOT/'spikes/344-gold-drawdown-repair/best_hit.json'
OUTDIR=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('gdr',GDR_PATH)
if spec is None or spec.loader is None: raise RuntimeError(GDR_PATH)
gdr=importlib.util.module_from_spec(spec); sys.modules['gdr']=gdr; spec.loader.exec_module(gdr)
BEST=json.loads(BEST_PATH.read_text(encoding='utf-8'))
BASE=BEST['overlay']
BASE_METRICS=BEST['metrics']
BASE_SLICES=BEST['slice_metrics']

GRID={
 'dd_fast_n':[40,50,63,80],
 'dd_slow_n':[100,126,150,189],
 'dd_fast_cut':[-0.07,-0.08,-0.09,-0.10,-0.11],
 'dd_slow_cut':[-0.14,-0.16,-0.18,-0.20],
 'deep_dd_cut':[-0.20,-0.22,-0.24,-0.26],
 'mom_fast_n':[15,20,30,40],
 'mom_slow_n':[90,120,150],
 'mom_fast_cut':[-0.02,-0.03,-0.04,-0.05],
 'mom_slow_cut':[-0.04,-0.05,-0.06,-0.08],
 'ma_fast':[80,100,120],
 'ma_slow':[180,200,220],
 'gold_stress_cap':[0.18,0.20,0.22,0.24,0.26,0.28],
 'gold_deep_cap':[0.16,0.18,0.20,0.22,0.24],
 'eq_ma':[100,120,140,160],
 'eq_mom_n':[90,120,150],
 'nas_min_mom':[0.0,0.02,0.04,0.06],
 'sp_min_mom':[-0.01,0.0,0.01,0.02],
 'vol_n':[63,90,126],
 'score_mom_n':[90,120,150],
 'eq_dd_n':[90,126,150],
 'eq_dd_floor':[-0.10,-0.12,-0.14,-0.16],
 'handoff_ratio':[0.65,0.75,0.85,0.95,1.0],
 'second_ratio':[0.0,0.15,0.25,0.30,0.40],
}

def mutate(rng: random.Random, radius: float=0.55):
    op=dict(BASE)
    for k,vals in GRID.items():
        if rng.random()<radius:
            # Bias toward neighboring values around current if possible.
            cur=op[k]
            if cur in vals:
                idx=vals.index(cur)
                lo=max(0,idx-1); hi=min(len(vals)-1,idx+1)
                choices=vals[lo:hi+1]
                if rng.random()<0.8:
                    op[k]=rng.choice(choices)
                else:
                    op[k]=rng.choice(vals)
            else:
                op[k]=rng.choice(vals)
    if op['gold_deep_cap']>op['gold_stress_cap']:
        op['gold_deep_cap']=op['gold_stress_cap']
    return op

def score_vs_base(r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']; s22=r.slice_metrics['2022+']
    bm=BASE_METRICS; b20=BASE_SLICES['2020+']; b10=BASE_SLICES['10y']; b22=BASE_SLICES['2022+']
    return ((m['cagr']-bm['cagr'])*8 + (m['max_dd']-bm['max_dd'])*6 + (m['sharpe']-bm['sharpe'])*0.4 +
            (s20['cagr']-b20['cagr'])*1.2 + (s10['cagr']-b10['cagr']) +
            (s20['max_dd']-b20['max_dd'])*3 + (s10['max_dd']-b10['max_dd'])*3 +
            (s22['cagr']-b22['cagr'])*0.6 + (s22['max_dd']-b22['max_dd'])*2)

def beats_base(r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']; s22=r.slice_metrics['2022+']
    bm=BASE_METRICS; b20=BASE_SLICES['2020+']; b10=BASE_SLICES['10y']; b22=BASE_SLICES['2022+']
    # Allow tiny return trade only if drawdown improves materially; otherwise require full improvement.
    full_better=(m['cagr']>=bm['cagr']+0.0003 and m['max_dd']>=bm['max_dd']+0.0005 and m['sharpe']>=bm['sharpe']-0.005)
    dd_better=(m['cagr']>=bm['cagr']-0.001 and m['max_dd']>=bm['max_dd']+0.006 and m['sharpe']>=bm['sharpe'])
    slice_ok=(s20['cagr']>=b20['cagr']-0.002 and s20['max_dd']>=b20['max_dd'] and
              s10['cagr']>=b10['cagr']-0.002 and s10['max_dd']>=b10['max_dd'] and
              s22['cagr']>=b22['cagr']-0.002 and s22['max_dd']>=b22['max_dd'])
    return (full_better or dd_better) and slice_ok and r.stats['avg_exposure']>=0.56

def fmt(x): return 'NA' if x is None else f'{x*100:.2f}%'
def row_line(i,r):
    m=r.metrics; s20=r.slice_metrics['2020+']; s10=r.slice_metrics['10y']; s22=r.slice_metrics['2022+']
    return f"#{i:02d} score_vs_base={score_vs_base(r):.4f} beat={beats_base(r)} CAGR={fmt(m['cagr'])} DD={fmt(m['max_dd'])} Sharpe={m['sharpe']:.3f} 2020={fmt(s20['cagr'])}/{fmt(s20['max_dd'])} 10y={fmt(s10['cagr'])}/{fmt(s10['max_dd'])} 2022={fmt(s22['cagr'])}/{fmt(s22['max_dd'])} exp={r.stats['avg_exposure']:.2f} repairs={r.stats['repair_days']}"

def main():
    count=int(sys.argv[1]) if len(sys.argv)>1 else 900
    seed=int(sys.argv[2]) if len(sys.argv)>2 else 345
    rng=random.Random(seed)
    panel=gdr.s.align(gdr.s.parse_series(gdr.s.fetch()))
    rows=[]; seen=set()
    # include base exact.
    rows.append(gdr.replay(panel, BASE))
    for _ in range(count):
        op=mutate(rng, radius=rng.choice([0.35,0.5,0.65,0.8]))
        key=json.dumps(op,sort_keys=True)
        if key in seen: continue
        seen.add(key)
        rows.append(gdr.replay(panel,op))
    rows.sort(key=score_vs_base, reverse=True)
    hits=[r for r in rows if beats_base(r)]
    print('Base 344:', f"CAGR={fmt(BASE_METRICS['cagr'])}", f"DD={fmt(BASE_METRICS['max_dd'])}", f"Sharpe={BASE_METRICS['sharpe']:.3f}", f"2020={fmt(BASE_SLICES['2020+']['cagr'])}/{fmt(BASE_SLICES['2020+']['max_dd'])}", f"10y={fmt(BASE_SLICES['10y']['cagr'])}/{fmt(BASE_SLICES['10y']['max_dd'])}")
    print(f'Ran {len(rows)} refine candidates count={count} seed={seed}')
    print(f'Better-than-344 hits: {len(hits)}\n')
    for i,r in enumerate(rows[:30],1): print(row_line(i,r), flush=True)
    out=OUTDIR/'results.json'
    out.write_text(json.dumps([{'name':r.name,'overlay':r.overlay,'metrics':r.metrics,'slice_metrics':r.slice_metrics,'stats':r.stats,'weights_tail':r.weights_tail,'score_vs_base':score_vs_base(r),'beats_base':beats_base(r)} for r in rows[:200]],ensure_ascii=False,indent=2),encoding='utf-8')
    if hits:
        hits.sort(key=score_vs_base, reverse=True)
        (OUTDIR/'best_hit.json').write_text(json.dumps({'name':hits[0].name,'overlay':hits[0].overlay,'metrics':hits[0].metrics,'slice_metrics':hits[0].slice_metrics,'stats':hits[0].stats,'weights_tail':hits[0].weights_tail,'score_vs_base':score_vs_base(hits[0])},ensure_ascii=False,indent=2),encoding='utf-8')
        print(f"\nBEST_HIT {OUTDIR/'best_hit.json'}")
    print(f"\nWrote {out}")
if __name__=='__main__': main()
