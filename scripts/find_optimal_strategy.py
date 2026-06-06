#!/usr/bin/env python3
import json, math, urllib.parse, urllib.request
from datetime import datetime
from statistics import mean, stdev

SYMBOLS = [
    'gold_cny','btc','eth','nasdaq_composite','sp500','dow_jones','nikkei225',
    'shanghai_composite','shenzhen_component','csi300','chinext','hang_seng'
]
USD_ASSETS = {'nasdaq_composite','sp500','dow_jones','nikkei225'}
LABELS = {
    'gold_cny':'黄金(CNY/g)','btc':'BTC','eth':'ETH','nasdaq_composite':'纳指综合','sp500':'标普500',
    'dow_jones':'道琼斯','nikkei225':'日经225','shanghai_composite':'上证综指',
    'shenzhen_component':'深证成指','csi300':'沪深300','chinext':'创业板指','hang_seng':'恒生指数'
}
BASE='https://api.flyingrtx.com/api/v1/money/public/history'
ALL_SYMBOLS=','.join(SYMBOLS+['usd_per_cny'])
url=BASE+'?'+urllib.parse.urlencode({'symbols':ALL_SYMBOLS,'period':'max'})
data=json.load(urllib.request.urlopen(url, timeout=30))
series={s['symbol']:s for s in data['series']}
fx=dict(zip(series['usd_per_cny']['dates'], series['usd_per_cny']['prices']))

def parse(d): return datetime.strptime(d, '%Y-%m-%d').date()

def convert_series(sym):
    s=series[sym]
    pts=[]
    for d,p in zip(s['dates'], s['prices']):
        if p and math.isfinite(p) and p>0:
            if sym in USD_ASSETS:
                r=fx.get(d)
                if not r or r<=0: continue
                p=p/r  # app convention: USD price / USD-per-CNY = CNY value
            pts.append((parse(d), float(p)))
    pts.sort()
    # de-dupe
    out=[]
    for d,p in pts:
        if out and out[-1][0]==d: out[-1]=(d,p)
        else: out.append((d,p))
    return out

def ma(vals, n):
    res=[None]*len(vals); s=0.0
    for i,v in enumerate(vals):
        s += v
        if i>=n: s -= vals[i-n]
        if i>=n-1: res[i]=s/n
    return res

def boll(vals,n=20,m=2):
    res=[None]*len(vals); s=ss=0.0
    for i,v in enumerate(vals):
        s += v; ss += v*v
        if i>=n:
            old=vals[i-n]; s-=old; ss-=old*old
        if i>=n-1:
            mid=s/n; var=max(ss/n-mid*mid,0); dev=math.sqrt(var)
            res[i]=(mid, mid-m*dev, mid+m*dev)
    return res

def metrics(points):
    # points [(date,value)]
    if len(points)<2 or points[0][1]<=0: return None
    rets=[]; peak=points[0][1]; mdd=0.0
    for (_,prev),(_,cur) in zip(points, points[1:]):
        if prev>0: rets.append(cur/prev-1)
        peak=max(peak,cur)
        if peak>0: mdd=max(mdd,(peak-cur)/peak)
    total=points[-1][1]/points[0][1]-1
    years=max((points[-1][0]-points[0][0]).days,1)/365.25
    ann=(points[-1][1]/points[0][1])**(1/years)-1
    vol=(stdev(rets)*math.sqrt(252)) if len(rets)>1 else None
    shp=(mean(rets)*252/(stdev(rets)*math.sqrt(252))) if len(rets)>1 and stdev(rets)>0 else None
    return dict(total=total, annualized=ann, max_drawdown=mdd, volatility=vol, sharpe=shp, days=(points[-1][0]-points[0][0]).days)

SIGNALS_BUY=['consecutiveDown','priceCrossesAboveMA20','priceCrossesAboveBollMiddle','touchesBollLower','ma20CrossesAboveMA60']
SIGNALS_SELL=['consecutiveUp','priceCrossesBelowMA20','priceCrossesBelowBollMiddle','touchesBollUpper','ma20CrossesBelowMA60']

def triggered(sig,i,prices,ma20,ma60,bb,up,down,thr):
    if i<=0: return False
    prev=prices[i-1]; cur=prices[i]
    if sig=='consecutiveDown': return down==thr
    if sig=='consecutiveUp': return up==thr
    if sig=='priceCrossesAboveMA20': return ma20[i-1] and ma20[i] and prev<=ma20[i-1] and cur>ma20[i]
    if sig=='priceCrossesBelowMA20': return ma20[i-1] and ma20[i] and prev>=ma20[i-1] and cur<ma20[i]
    if sig=='ma20CrossesAboveMA60': return ma20[i-1] and ma20[i] and ma60[i-1] and ma60[i] and ma20[i-1]<=ma60[i-1] and ma20[i]>ma60[i]
    if sig=='ma20CrossesBelowMA60': return ma20[i-1] and ma20[i] and ma60[i-1] and ma60[i] and ma20[i-1]>=ma60[i-1] and ma20[i]<ma60[i]
    if sig=='priceCrossesAboveBollMiddle': return bb[i-1] and bb[i] and prev<=bb[i-1][0] and cur>bb[i][0]
    if sig=='priceCrossesBelowBollMiddle': return bb[i-1] and bb[i] and prev>=bb[i-1][0] and cur<bb[i][0]
    if sig=='touchesBollLower': return bb[i-1] and bb[i] and prev>bb[i-1][1] and cur<=bb[i][1]
    if sig=='touchesBollUpper': return bb[i-1] and bb[i] and prev<bb[i-1][2] and cur>=bb[i][2]
    return False

def run_strategy(pts, buy_sig, sell_sig, buy_days, sell_days, trade_ratio, max_pos, cooldown, stop_loss, take_profit, fee_rate=0.001, initial=100000):
    prices=[p for _,p in pts]
    m20=ma(prices,20); m60=ma(prices,60); bb=boll(prices)
    cash=initial; units=0.0; avg=None; last_trade_day=None; up=down=0; prev=None; trades=[]; vals=[]
    for i,(d,price) in enumerate(pts):
        if prev is not None:
            if price>prev: up+=1; down=0
            elif price<prev: down+=1; up=0
            else: up=down=0
            should_buy=triggered(buy_sig,i,prices,m20,m60,bb,up,down,buy_days)
            should_sell=triggered(sell_sig,i,prices,m20,m60,bb,up,down,sell_days)
            days_since=10**9 if last_trade_day is None else (d-last_trade_day).days
            can_trade=days_since>=cooldown
            pos_val=units*price; portfolio=cash+pos_val
            stop=(stop_loss>0 and units>0 and avg and price<=avg*(1-stop_loss))
            take=(take_profit>0 and units>0 and avg and price>=avg*(1+take_profit))
            if (should_sell or stop or take) and units>0 and can_trade:
                gross=units*price; proceeds=gross*(1-fee_rate)
                cash+=proceeds; trades.append((d,'sell',proceeds,price))
                units=0; avg=None; last_trade_day=d
            elif should_buy and cash>0 and can_trade:
                cap=max(portfolio*max_pos - pos_val, 0)
                spend=min(cash, initial*trade_ratio, cap)
                invest=spend*(1-fee_rate)
                if invest>0:
                    bought=invest/price
                    avg=((avg or 0)*units + invest)/(units+bought) if units+bought>0 else None
                    units+=bought; cash-=spend; trades.append((d,'buy',spend,price)); last_trade_day=d
        vals.append((d,cash+units*price)); prev=price
    mt=metrics(vals)
    if not mt: return None
    mt.update(trades=len(trades), buy=sum(1 for t in trades if t[1]=='buy'), sell=sum(1 for t in trades if t[1]=='sell'), final=vals[-1][1])
    return mt

def score(m):
    return (m['annualized']*1.35 + (m['sharpe'] or 0)*0.18 - m['max_drawdown']*1.2 - (0.35 if m['trades']<2 else 0))

def fmt_pct(x): return f"{x*100:.2f}%"

results=[]; holds=[]
for sym in SYMBOLS:
    pts=convert_series(sym)
    if len(pts)<80: continue
    hold=metrics([(d,p/pts[0][1]*100000) for d,p in pts])
    holds.append((sym, hold, pts[0][0], pts[-1][0], len(pts)))
    best=[]
    for bs in SIGNALS_BUY:
      for ss in SIGNALS_SELL:
       for bd in ([2,3,5] if bs in ['consecutiveDown','consecutiveUp'] else [1]):
        for sd in ([2,3,5] if ss in ['consecutiveDown','consecutiveUp'] else [1]):
         for tr in [0.10,0.20,0.35]:
          for mp in [0.50,0.70,1.0]:
           for cd in [3,7]:
            for sl in [0,0.12]:
             for tp in [0,0.35]:
                m=run_strategy(pts,bs,ss,bd,sd,tr,mp,cd,sl,tp)
                if not m or m['trades']<2: continue
                sc=score(m)
                best.append((sc,m,dict(sym=sym,buy=bs,sell=ss,buy_days=bd,sell_days=sd,trade_ratio=tr,max_pos=mp,cooldown=cd,stop_loss=sl,take_profit=tp)))
    best.sort(key=lambda x:x[0], reverse=True)
    results.extend(best[:10])

results.sort(key=lambda x:x[0], reverse=True)
holds.sort(key=lambda x:(x[1]['annualized'] if x[1] else -9), reverse=True)
print('DATA_RANGE')
for sym,h,s,e,n in holds:
    print(f"{sym:20s} {LABELS[sym]:12s} {s}..{e} n={n:4d} HOLD total={fmt_pct(h['total'])} ann={fmt_pct(h['annualized'])} mdd={fmt_pct(h['max_drawdown'])} sharpe={(h['sharpe'] or 0):.2f}")
print('\nTOP_STRATEGIES')
for rank,(sc,m,p) in enumerate(results[:15],1):
    print(f"#{rank:02d} {p['sym']:20s} {LABELS[p['sym']]:12s} score={sc:.3f} total={fmt_pct(m['total'])} ann={fmt_pct(m['annualized'])} mdd={fmt_pct(m['max_drawdown'])} sharpe={(m['sharpe'] or 0):.2f} trades={m['trades']} final={m['final']:.0f}")
    print(f"    buy={p['buy']}({p['buy_days']}d) sell={p['sell']}({p['sell_days']}d) trade={p['trade_ratio']*100:.0f}% maxPos={p['max_pos']*100:.0f}% cooldown={p['cooldown']} stop={p['stop_loss']*100:.0f}% take={p['take_profit']*100:.0f}% fee=0.10%")

# simple robustness: split validation from 2024-01-01 for top params
print('\nROBUSTNESS_TOP5_VALIDATE_FROM_2024')
cut=datetime.strptime('2024-01-01','%Y-%m-%d').date()
for rank,(sc,m,p) in enumerate(results[:5],1):
    pts=[x for x in convert_series(p['sym']) if x[0]>=cut]
    vm=run_strategy(pts,p['buy'],p['sell'],p['buy_days'],p['sell_days'],p['trade_ratio'],p['max_pos'],p['cooldown'],p['stop_loss'],p['take_profit']) if len(pts)>80 else None
    hm=metrics([(d,pr/pts[0][1]*100000) for d,pr in pts]) if pts else None
    if vm and hm:
        print(f"#{rank:02d} {p['sym']:20s} validation {pts[0][0]}..{pts[-1][0]} strat total={fmt_pct(vm['total'])} ann={fmt_pct(vm['annualized'])} mdd={fmt_pct(vm['max_drawdown'])} sharpe={(vm['sharpe'] or 0):.2f} trades={vm['trades']} | hold total={fmt_pct(hm['total'])} ann={fmt_pct(hm['annualized'])} mdd={fmt_pct(hm['max_drawdown'])}")
