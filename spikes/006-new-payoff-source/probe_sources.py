#!/usr/bin/env python3
from __future__ import annotations
import json, datetime as dt, urllib.request
from pathlib import Path

SYMS = [
    # ETFs / mutual funds / indices
    'SPY','QQQ','XLK','VFINX','VUSTX','VFISX','VFITX','VBMFX','PCRIX','RYMFX','AQMIX','PQTIX','^SPGSCI','DX-Y.NYB',
    # continuous futures
    'GC=F','SI=F','CL=F','BZ=F','HG=F','ZC=F','ZS=F','ZW=F','KC=F','SB=F','CT=F','CC=F','LE=F','HE=F',
    'ZB=F','ZN=F','ZF=F','ZT=F','ES=F','NQ=F','YM=F','6E=F','6J=F','6B=F','6A=F','6C=F','DX=F'
]

def fetch(sym):
    cache=Path(f'/tmp/yahoo_probe_{sym.replace("=","_").replace("^","_").replace(".","_").replace("-","_")}.json')
    if cache.exists():
        try: return json.loads(cache.read_text())
        except Exception: pass
    start=int(dt.datetime(1999,1,1,tzinfo=dt.timezone.utc).timestamp())
    end=int(dt.datetime(2026,6,21,tzinfo=dt.timezone.utc).timestamp())
    url=f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={start}&period2={end}&interval=1d&events=history&includeAdjustedClose=true'
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    try:
        data=json.load(urllib.request.urlopen(req,timeout=20))
    except Exception as e:
        return {'sym':sym,'ok':False,'err':str(e)[:120]}
    cache.write_text(json.dumps(data))
    return data

def summarize(sym,data):
    try:
        r=data['chart']['result'][0]
        ts=r.get('timestamp') or []
        q=r['indicators']['quote'][0]
        adj=r['indicators'].get('adjclose',[{}])[0].get('adjclose') or q.get('close') or []
        rows=[]
        for t,p in zip(ts,adj):
            if p and p>0:
                rows.append((dt.datetime.fromtimestamp(t,dt.UTC).date(),float(p)))
        if not rows: return {'sym':sym,'ok':False,'err':'no rows'}
        return {'sym':sym,'ok':True,'n':len(rows),'start':str(rows[0][0]),'end':str(rows[-1][0]),'first':rows[0][1],'last':rows[-1][1]}
    except Exception as e:
        return {'sym':sym,'ok':False,'err':str(e)[:120]}

def main():
    out=[]
    for s in SYMS:
        rec=summarize(s,fetch(s)); out.append(rec); print(rec,flush=True)
    Path('/tmp/atm_source_probe.json').write_text(json.dumps(out,ensure_ascii=False,indent=2))
if __name__=='__main__': main()
