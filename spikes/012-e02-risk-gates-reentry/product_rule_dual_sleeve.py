#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, sys, json, math, statistics
from pathlib import Path
ROOT=Path('/Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine')
spec=importlib.util.spec_from_file_location('Z', ROOT/'spikes/008-gold-nasdaq-mechanism-zoo/mechanism_zoo.py')
Z=importlib.util.module_from_spec(spec); sys.modules['Z']=Z; spec.loader.exec_module(Z)  # type: ignore
CORE=Z.CORE
OUT=Path('/tmp/atm_product_rule_dual_sleeve_012.json')
START=100000.0; HOLDINGS=['nasdaq','gold_cny']; TARGET_ANN=0.12; TARGET_DD=0.08
BUY=['alwaysBuy','consecutiveDown','priceAboveMA20','priceAboveMA60','priceCrossesAboveMA20','ma20CrossesAboveMA60','priceCrossesAboveBollMiddle','touchesBollLower']
SELL=['neverSell','consecutiveUp','priceBelowMA20','priceBelowMA60','priceCrossesBelowMA20','ma20CrossesBelowMA60','priceCrossesBelowBollMiddle','touchesBollUpper']

def ma(vals,n):
    out=[None]*len(vals); s=0.0
    for i,v in enumerate(vals):
        s+=v
        if i>=n: s-=vals[i-n]
        if i>=n-1: out[i]=s/n
    return out

def boll(vals,n=20,m=2):
    out: list[tuple[float,float,float] | None]=[None]*len(vals); s=ss=0.0
    for i,v in enumerate(vals):
        s+=v; ss+=v*v
        if i>=n:
            old=vals[i-n]; s-=old; ss-=old*old
        if i>=n-1:
            mid=s/n; var=max(ss/n-mid*mid,0); dev=math.sqrt(var); out[i]=(mid,mid-m*dev,mid+m*dev)
    return out

def prep(p):
    c={}
    for s in HOLDINGS:
        vals=p[s]; up=[0]*len(vals); down=[0]*len(vals)
        for i in range(1,len(vals)):
            if vals[i]>vals[i-1]: up[i]=up[i-1]+1; down[i]=0
            elif vals[i]<vals[i-1]: down[i]=down[i-1]+1; up[i]=0
        c[s]={'ma20':ma(vals,20),'ma60':ma(vals,60),'bb':boll(vals),'up':up,'down':down}
    return c

def trigger(rule,s,i,p,c,thr):
    if i<=0: return False
    vals=p[s]; prev=vals[i-1]; cur=vals[i]; cc=c[s]; m20=cc['ma20']; m60=cc['ma60']; bb=cc['bb']
    if rule=='alwaysBuy': return True
    if rule=='neverSell': return False
    if rule=='consecutiveDown': return cc['down'][i]>=thr
    if rule=='consecutiveUp': return cc['up'][i]>=thr
    if rule=='priceAboveMA20': return m20[i] is not None and cur>m20[i]
    if rule=='priceBelowMA20': return m20[i] is not None and cur<m20[i]
    if rule=='priceAboveMA60': return m60[i] is not None and cur>m60[i]
    if rule=='priceBelowMA60': return m60[i] is not None and cur<m60[i]
    if rule=='priceCrossesAboveMA20': return m20[i-1] is not None and m20[i] is not None and prev<=m20[i-1] and cur>m20[i]
    if rule=='priceCrossesBelowMA20': return m20[i-1] is not None and m20[i] is not None and prev>=m20[i-1] and cur<m20[i]
    if rule=='ma20CrossesAboveMA60': return m20[i-1] is not None and m20[i] is not None and m60[i-1] is not None and m60[i] is not None and m20[i-1]<=m60[i-1] and m20[i]>m60[i]
    if rule=='ma20CrossesBelowMA60': return m20[i-1] is not None and m20[i] is not None and m60[i-1] is not None and m60[i] is not None and m20[i-1]>=m60[i-1] and m20[i]<m60[i]
    if rule=='priceCrossesAboveBollMiddle': return bb[i-1] and bb[i] and prev<=bb[i-1][0] and cur>bb[i][0]
    if rule=='priceCrossesBelowBollMiddle': return bb[i-1] and bb[i] and prev>=bb[i-1][0] and cur<bb[i][0]
    if rule=='touchesBollLower': return bb[i-1] and bb[i] and prev>bb[i-1][1] and cur<=bb[i][1]
    if rule=='touchesBollUpper': return bb[i-1] and bb[i] and prev<bb[i-1][2] and cur>=bb[i][2]
    return False

def metrics(dates,vals,start=None,end=None): return Z.metrics(dates,vals,start,end)
def allm(dates,vals): return Z.all_metrics(dates,vals)
def topdds(dates,vals,weights): return Z.topdds(dates,vals,weights)

def simulate(dates,p,cfg):
    c=prep(p); cash=START; units={s:0.0 for s in HOLDINGS}; avg={s:None for s in HOLDINGS}; last={s:None for s in HOLDINGS}; vals=[]; weights=[]; trades=0
    def pv(i): return cash+sum(units[s]*p[s][i] for s in HOLDINGS)
    for i,d in enumerate(dates):
        if i>0 and cash>0: cash+=cash*CORE.cash_daily(dates[i-1])
        if i>0:
            sig=i-1
            for s in HOLDINGS:
                sc=cfg[s]
                price_sig=p[s][sig]
                days=10**9 if last[s] is None else (d-last[s]).days
                if days<sc['cooldown']: continue
                sell=trigger(sc['sell'],s,sig,p,c,sc.get('sell_thr',1))
                buy=trigger(sc['buy'],s,sig,p,c,sc.get('buy_thr',1))
                stop=sc['stop']>0 and units[s]>0 and avg[s] is not None and price_sig<=avg[s]*(1-sc['stop'])
                take=sc['take']>0 and units[s]>0 and avg[s] is not None and price_sig>=avg[s]*(1+sc['take'])
                if units[s]>0 and (sell or stop or take):
                    gross=units[s]*p[s][i]*(1-Z.SLIP); proceeds=gross*(1-Z.FEE)
                    cash+=proceeds; units[s]=0; avg[s]=None; last[s]=d; trades+=1
                elif buy and cash>0:
                    port=pv(i); cur=units[s]*p[s][i]; cap=max(port*sc['max_pos']-cur,0); spend=min(cash,port*sc['trade'],cap)
                    if spend>1:
                        invest=spend*(1-Z.FEE); bought=invest/(p[s][i]*(1+Z.SLIP))
                        old_cost=(avg[s] or 0)*units[s]; avg[s]=(old_cost+invest)/(units[s]+bought) if units[s]+bought>0 else None
                        units[s]+=bought; cash-=spend; last[s]=d; trades+=1
        val=pv(i); vals.append(val); weights.append({s:units[s]*p[s][i]/val for s in HOLDINGS if val>0 and units[s]*p[s][i]/val>1e-4})
    return vals,weights,{'trades':trades,'latest':weights[-1],'cash_pct':max(0,1-sum(weights[-1].values()))}

# Limited product-compatible candidates. No custom hidden state; only App rules + stop/take/cooldown/position sizing.
def cfg(n_buy,n_sell,g_buy,g_sell,n_stop,n_take,g_stop,g_take,n_trade=0.20,g_trade=0.18,n_max=0.55,g_max=0.42,cool=14,nbt=1,gbt=1,nst=1,gst=1):
    return {
        'nasdaq':{'buy':n_buy,'sell':n_sell,'buy_thr':nbt,'sell_thr':nst,'stop':n_stop,'take':n_take,'trade':n_trade,'max_pos':n_max,'cooldown':cool},
        'gold_cny':{'buy':g_buy,'sell':g_sell,'buy_thr':gbt,'sell_thr':gst,'stop':g_stop,'take':g_take,'trade':g_trade,'max_pos':g_max,'cooldown':cool},
    }
CANDIDATES=[]
base_pairs=[
 ('trend_ma60_vs_ma20', cfg('priceAboveMA60','priceBelowMA20','priceAboveMA60','priceBelowMA20',0.10,0.35,0.07,0.24)),
 ('cross_ma20', cfg('priceCrossesAboveMA20','priceCrossesBelowMA20','priceCrossesAboveMA20','priceCrossesBelowMA20',0.10,0.35,0.07,0.24)),
 ('ma_golden_cross', cfg('ma20CrossesAboveMA60','ma20CrossesBelowMA60','ma20CrossesAboveMA60','ma20CrossesBelowMA60',0.12,0.45,0.08,0.28,n_trade=0.25,g_trade=0.22,n_max=0.65,g_max=0.48,cool=7)),
 ('boll_reversal', cfg('touchesBollLower','touchesBollUpper','touchesBollLower','touchesBollUpper',0.08,0.22,0.06,0.16,n_trade=0.15,g_trade=0.15,n_max=0.40,g_max=0.35,cool=7)),
 ('breakout_boll_mid', cfg('priceCrossesAboveBollMiddle','priceCrossesBelowBollMiddle','priceCrossesAboveBollMiddle','priceCrossesBelowBollMiddle',0.10,0.32,0.07,0.22,n_trade=0.22,g_trade=0.18,n_max=0.58,g_max=0.42,cool=10)),
 ('always_with_stops', cfg('alwaysBuy','priceBelowMA60','alwaysBuy','priceBelowMA60',0.11,0.40,0.08,0.25,n_trade=0.10,g_trade=0.10,n_max=0.55,g_max=0.42,cool=21)),
 ('down_buy_up_sell', cfg('consecutiveDown','consecutiveUp','consecutiveDown','consecutiveUp',0.10,0.28,0.07,0.18,n_trade=0.16,g_trade=0.14,n_max=0.45,g_max=0.36,cool=10,nbt=3,gbt=3,nst=3,gst=3)),
]
CANDIDATES.extend(base_pairs)
# A few asymmetrical product-rule candidates inspired by E02: Nasdaq trend breakout, gold tighter exit.
CANDIDATES += [
 ('nq_breakout_gold_ma', cfg('ma20CrossesAboveMA60','priceBelowMA20','priceAboveMA60','priceBelowMA20',0.12,0.42,0.065,0.22,n_trade=0.28,g_trade=0.16,n_max=0.68,g_max=0.36,cool=7)),
 ('nq_ma60_gold_boll', cfg('priceAboveMA60','priceBelowMA20','touchesBollLower','touchesBollUpper',0.10,0.36,0.06,0.16,n_trade=0.24,g_trade=0.12,n_max=0.62,g_max=0.30,cool=10)),
 ('nq_boll_mid_gold_trend', cfg('priceCrossesAboveBollMiddle','priceCrossesBelowMA20','priceAboveMA20','priceBelowMA20',0.10,0.34,0.065,0.20,n_trade=0.24,g_trade=0.15,n_max=0.62,g_max=0.34,cool=10)),
]

def run():
    dates,p=CORE.align(CORE.fetch())
    rows=[]
    for name,c in CANDIDATES:
        vals,w,e=simulate(dates,p,c); m=allm(dates,vals)
        rows.append({'name':name,'cfg':c,'metrics':m,'stress':{k:metrics(dates,vals,a,b) for k,(a,b) in Z.STRESS.items()},'extra':e,'top_dd':topdds(dates,vals,w),'pass_12_8':m['full']['ann']>=TARGET_ANN and m['full']['dd']<=TARGET_DD})
    OUT.write_text(json.dumps({'coverage':{'start':str(dates[0]),'end':str(dates[-1]),'n':len(dates)},'rows':rows},ensure_ascii=False,indent=2,default=str))
    print('WROTE',OUT,'coverage',dates[0],dates[-1],len(dates))
    for r in sorted(rows,key=lambda r:r['metrics']['full']['ann'],reverse=True):
        m=r['metrics']['full']; p20=r['metrics']['post2020']; ten=r['metrics']['teny']; mark='PASS' if r['pass_12_8'] else 'FAIL'
        print(mark,r['name'],f"full={m['ann']*100:.2f}/{m['dd']*100:.2f}",f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}",f"teny={ten['ann']*100:.2f}/{ten['dd']*100:.2f}",'latest',{k:round(v*100,1) for k,v in r['extra']['latest'].items()},'cash',round(r['extra']['cash_pct']*100,1),'trades',r['extra']['trades'])
        print('  topdd',' ; '.join(f"{e['peak']}->{e['trough']} {e['dd']*100:.2f}% W={e['weights']} cash={e['cash']}" for e in r['top_dd'][:3]))
    print('PASS_COUNT',sum(1 for r in rows if r['pass_12_8']))
if __name__=='__main__': run()
