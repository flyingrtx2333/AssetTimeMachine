#!/usr/bin/env python3
from __future__ import annotations
import json, datetime as dt, urllib.request, math, statistics
from pathlib import Path

SYMS=[
 # option/risk premia indices
 '^BXM','^PUT','^CLL','^RXM','^BXMD','^VIX','^MOVE',
 # permanent / real return / alternatives / hedged
 'PRPFX','HSTRX','HSGFX','MERFX','ARBNX','LSBRX','MWTRX','FAGIX','OSTIX','PONAX','PAUIX','PIMIX','RPHYX',
 # managed futures / alt candidates
 'WDTI','DBMF','KMLM','CTA','AQMIX','AQMNX','AQMIX','PQTIX','PQMIX','ABYIX','ASFYX','EVOIX','RYMFX','PCLIX','PCRIX',
 # all weather building blocks
 'VFINX','VUSTX','VFITX','VFISX','VBMFX','VWINX','PRWCX','FPACX','OAKBX','DODIX','VGSIX','GLD','IAU','DBC','GSG'
]
OUT=Path('/tmp/atm_alt_probe2.json')

def fetch(sym):
    safe=sym.replace('^','_').replace('.','_').replace('-','_').replace('/','_')
    cache=Path(f'/tmp/atm_alt_probe2_{safe}.json')
    if cache.exists():
        try: return [(dt.date.fromisoformat(d),float(p)) for d,p in json.loads(cache.read_text())]
        except Exception: pass
    start=int(dt.datetime(1999,1,1,tzinfo=dt.timezone.utc).timestamp())
    end=int(dt.datetime(2026,6,21,tzinfo=dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    try:
        data=json.load(urllib.request.urlopen(req,timeout=25))
        r=data['chart']['result'][0]
        ts=r.get('timestamp') or []
        q=r['indicators']['quote'][0]
        arr=r['indicators'].get('adjclose',[{}])[0].get('adjclose') or q.get('close') or []
        rows=[]
        for t,p in zip(ts,arr):
            if p and math.isfinite(float(p)) and float(p)>0:
                rows.append((dt.datetime.fromtimestamp(t,dt.UTC).date(),float(p)))
        cache.write_text(json.dumps([(d.isoformat(),p) for d,p in rows]))
        return rows
    except Exception as e:
        return []

def metrics(rows,start=dt.date(2001,1,1)):
    rows=[x for x in rows if x[0]>=start]
    if len(rows)<500: return None
    dates=[d for d,_ in rows]; vals=[p for _,p in rows]
    peak=vals[0]; mdd=0; rs=[]
    for a,b in zip(vals,vals[1:]):
        rs.append(b/a-1); peak=max(peak,b); mdd=max(mdd,1-b/peak)
    years=(dates[-1]-dates[0]).days/365.25
    ann=(vals[-1]/vals[0])**(1/years)-1
    vv=statistics.stdev(rs)*math.sqrt(252) if len(rs)>1 else 0
    sh=statistics.mean(rs)*252/vv if vv else 0
    return {'start':str(dates[0]),'end':str(dates[-1]),'n':len(rows),'ann':ann,'dd':mdd,'vol':vv,'sharpe':sh,'calmar':ann/mdd if mdd else 0,'total':vals[-1]/vals[0]-1}

def main():
    out=[]
    for s in dict.fromkeys(SYMS):
        rows=fetch(s); m=metrics(rows)
        out.append({'sym':s,'ok':m is not None,'metrics':m,'raw_start':str(rows[0][0]) if rows else None,'raw_end':str(rows[-1][0]) if rows else None,'raw_n':len(rows)})
    out.sort(key=lambda r:((r['metrics'] or {}).get('calmar',-9),(r['metrics'] or {}).get('ann',-9)),reverse=True)
    OUT.write_text(json.dumps(out,ensure_ascii=False,indent=2))
    for r in out:
        m=r['metrics']
        if not m: print(f"{r['sym']:8s} NO raw={r['raw_start']} n={r['raw_n']}"); continue
        print(f"{r['sym']:8s} {m['start']}..{m['end']} ann={m['ann']*100:6.2f}% dd={m['dd']*100:6.2f}% vol={m['vol']*100:6.2f}% sh={m['sharpe']:4.2f} cal={m['calmar']:4.2f}")
if __name__=='__main__': main()
