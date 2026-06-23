#!/usr/bin/env python3
"""Extended search over *base/custom* advanced backtest rules only.
No named rotation/meta strategy is used here.
"""
import importlib.util
import json
import math
import datetime as dt
from dataclasses import dataclass
from pathlib import Path

spec = importlib.util.spec_from_file_location("base_search", "tools/search_basic_advanced_strategies.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load base search module")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

INITIAL_CASH = base.INITIAL_CASH
FEE_RATE = base.FEE_RATE
SLIPPAGE_RATE = base.SLIPPAGE_RATE

# Focus on rule families that can actually cut risk. Still all are basic custom signals.
BUY_RULES = [
    ("alwaysBuy", 1, "持续买入"),
    ("consecutiveDown", 2, "连续下跌2日"),
    ("consecutiveDown", 3, "连续下跌3日"),
    ("priceAboveMA20", 1, "价格高于MA20"),
    ("priceAboveMA60", 1, "价格高于MA60"),
    ("ma20CrossesAboveMA60", 1, "MA20上穿MA60"),
]
SELL_RULES = [
    ("consecutiveUp", 2, "连续上涨2日"),
    ("consecutiveUp", 3, "连续上涨3日"),
    ("priceBelowMA20", 1, "价格低于MA20"),
    ("priceBelowMA60", 1, "价格低于MA60"),
    ("priceCrossesBelowMA20", 1, "价格下穿MA20"),
    ("ma20CrossesBelowMA60", 1, "MA20下穿MA60"),
]
TRADE_AMOUNTS = [INITIAL_CASH * x for x in (0.025, 0.05, 0.10)]
MAX_POSITIONS = [20, 30, 35, 50]
COOLDOWNS = [3, 14]
STOP_LOSSES = [0.0, 0.08, 0.12]
TAKE_PROFITS = [0.0, 0.35]
ASSET_SETS = [
    ("gold_cny",),
    ("gold_cny", "nasdaq"),
    ("gold_cny", "sp500"),
    ("gold_cny", "nasdaq", "sp500"),
    ("gold_cny", "nasdaq", "sp500", "dowjones"),
    ("gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"),
    ("gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"),
]

@dataclass(frozen=True)
class Key:
    buy: str; buy_days: int; buy_title: str
    sell: str; sell_days: int; sell_title: str
    trade_amount: float; max_position: int
    cooldown: int; stop_loss: float; take_profit: float


def run_single(points, signals, key, initial_cash):
    dates = [d for d, _ in points]
    prices = [p for _, p in points]
    cash = initial_cash
    units = 0.0
    avg_entry = None
    last_trade_date = None
    trades = 0
    values = []
    exposure_sum = 0.0
    exposure_n = 0
    buy_sig = signals[(key.buy, key.buy_days)]
    sell_sig = signals[(key.sell, key.sell_days)]
    max_pos_ratio = key.max_position / 100.0
    for i, (date, px) in enumerate(points):
        if i > 0:
            signal_i = i - 1
            should_buy = buy_sig[signal_i]
            should_sell = sell_sig[signal_i]
            days_since = 10**9 if last_trade_date is None else (date - last_trade_date).days
            cooldown = days_since >= key.cooldown
            pos_value = units * px
            portfolio_before = cash + pos_value
            signal_px = prices[signal_i]
            stop = key.stop_loss > 0 and units > 0 and avg_entry is not None and signal_px <= avg_entry * (1-key.stop_loss)
            take = key.take_profit > 0 and units > 0 and avg_entry is not None and signal_px >= avg_entry * (1+key.take_profit)
            if (should_sell or stop or take) and units > 0 and cooldown:
                exec_px = max(px * (1 - SLIPPAGE_RATE), 0)
                gross = units * exec_px
                cash += max(gross - gross * FEE_RATE, 0)
                units = 0.0
                avg_entry = None
                last_trade_date = date
                trades += 1
            elif should_buy and cash > 0 and cooldown:
                max_pos_value = portfolio_before * max_pos_ratio
                remaining = max(max_pos_value - pos_value, 0)
                amount = min(cash, key.trade_amount, remaining)
                if amount > 0:
                    exec_px = px * (1 + SLIPPAGE_RATE)
                    invest = max(amount - amount * FEE_RATE, 0)
                    bought = invest / exec_px if exec_px > 0 else 0
                    if bought > 0:
                        prev_cost = (avg_entry or 0) * units
                        units += bought
                        avg_entry = (prev_cost + invest) / units
                        cash -= amount
                        last_trade_date = date
                        trades += 1
        value = cash + units * px
        values.append(value)
        if value > 0:
            exposure_sum += max(min(units * px / value, 1), 0)
            exposure_n += 1
    return base.SeriesResult(dates, values, trades, cash, exposure_sum/exposure_n if exposure_n else 0)


def score(m, slices, trades):
    ann = m["annualized"] or m["total"]
    sharpe = m["sharpe"] or 0
    dd = m["max_drawdown"]
    post = slices.get("post_2020") or {}
    recent = slices.get("last_10y") or {}
    post_ann = post.get("annualized") or 0
    recent_ann = recent.get("annualized") or 0
    post_dd = post.get("max_drawdown") or 0
    recent_dd = recent.get("max_drawdown") or 0
    return ann*1.2 + post_ann*0.35 + recent_ann*0.25 + sharpe*0.16 - dd*2.0 - max(dd-0.10,0)*8 - max(post_dd-0.12,0)*3 - max(recent_dd-0.12,0)*2 - (0.08 if trades < 4 else 0)


def simplify(c):
    def sm(m):
        if m is None: return None
        return {k:(round(v,6) if isinstance(v,float) else v) for k,v in m.items()}
    k=c["key"]
    return {
        "assets": list(c["assets"]),
        "buy": k.buy_title,
        "sell": k.sell_title,
        "trade_amount": k.trade_amount,
        "max_position": k.max_position,
        "cooldown": k.cooldown,
        "stop_loss_pct": k.stop_loss*100,
        "take_profit_pct": k.take_profit*100,
        "score": round(c["score"],6),
        "trades": c["trades"],
        "exposure": round(c["exposure"],4),
        "metrics": sm(c["metrics"]),
        "slices": {name: sm(m) for name,m in c["slices"].items()},
    }


def main():
    series = base.load_data()
    fx = base.make_fx_lookup(series["usd_per_cny"])
    points = {}; signals = {}
    all_rule_pairs = list({(x[0],x[1],x[2]) for x in BUY_RULES + SELL_RULES})
    old_buy, old_sell = base.BUY_RULES, base.SELL_RULES
    base.BUY_RULES = all_rule_pairs
    base.SELL_RULES = []
    for sym in base.ASSETS:
        pts = base.normalize_asset(sym, series[sym], fx)
        points[sym]=pts; signals[sym]=base.precompute_signals(pts)
    base.BUY_RULES, base.SELL_RULES = old_buy, old_sell
    print("DATA_COVERAGE")
    for sym, pts in points.items(): print(sym, len(pts), pts[0][0], pts[-1][0])

    keys=[]
    for b in BUY_RULES:
      for s in SELL_RULES:
       for ta in TRADE_AMOUNTS:
        for mp in MAX_POSITIONS:
         for cd in COOLDOWNS:
          for sl in STOP_LOSSES:
           for tp in TAKE_PROFITS:
            # avoid too-hyperactive tiny stop with never-sell+always-buy still ok, keep it
            keys.append(Key(b[0],b[1],b[2],s[0],s[1],s[2],ta,mp,cd,sl,tp))
    print("GRID", len(keys), "keys", len(ASSET_SETS), "asset_sets")

    end_date=max(points[s][ -1][0] for s in points)
    slices={"full": None, "post_2020": dt.date(2020,1,1), "last_10y": end_date.replace(year=end_date.year-10)}
    candidates=[]
    for aset in ASSET_SETS:
      n=len(aset)
      init=INITIAL_CASH/n
      for i,k in enumerate(keys):
        res=[run_single(points[sym], signals[sym], k, init) for sym in aset]
        dates, vals = base.align_sum(res)
        m=base.metrics(dates, vals)
        if not m or not m["annualized"]: continue
        sm={name: base.slice_metrics(dates, vals, start) for name,start in slices.items()}
        trades=sum(r.trades for r in res)
        sc=score(m, sm, trades)
        candidates.append({"assets":aset,"key":k,"metrics":m,"slices":sm,"trades":trades,"score":sc,"exposure":sum(r.exposure for r in res)/len(res)})
      print("EVALUATED_SET", "+".join(aset))

    def dedupe(items, limit=30):
      out=[]; seen=set()
      for c in sorted(items, key=lambda x:(x["score"], x["metrics"]["annualized"] or -1), reverse=True):
        k=c["key"]
        family=(c["assets"], k.buy, k.buy_days, k.sell, k.sell_days, k.max_position, k.cooldown, round(k.stop_loss,3), round(k.take_profit,3))
        if family in seen: continue
        seen.add(family); out.append(c)
        if len(out)>=limit: break
      return out

    strict=[c for c in candidates if c["metrics"]["max_drawdown"]<=0.10 and (c["metrics"]["annualized"] or 0)>=0.06 and c["trades"]>=4]
    near=[c for c in candidates if c["metrics"]["max_drawdown"]<=0.12 and (c["metrics"]["annualized"] or 0)>=0.07 and c["trades"]>=4]
    balanced=[c for c in candidates if c["metrics"]["max_drawdown"]<=0.15 and (c["metrics"]["annualized"] or 0)>=0.08 and c["trades"]>=4]
    high=[c for c in candidates if (c["metrics"]["annualized"] or 0)>=0.09 and c["trades"]>=4]
    serial={
      "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
      "coverage": {sym:{"count":len(pts),"start":str(pts[0][0]),"end":str(pts[-1][0])} for sym,pts in points.items()},
      "grid_count": len(keys)*len(ASSET_SETS),
      "strict_top": [simplify(c) for c in dedupe(strict,20)],
      "near_top": [simplify(c) for c in dedupe(near,20)],
      "balanced_top": [simplify(c) for c in dedupe(balanced,20)],
      "high_return_top": [simplify(c) for c in dedupe(high,20)],
      "score_top": [simplify(c) for c in dedupe(candidates,20)],
    }
    out=Path("/tmp/atm_basic_strategy_extended_search.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2))
    print("WROTE", out)
    print("STRICT_COUNT", len(strict), "NEAR_COUNT", len(near), "BALANCED_COUNT", len(balanced), "HIGH_COUNT", len(high))
    for section in ["strict_top","near_top","balanced_top","high_return_top","score_top"]:
      print("\n==",section,"==")
      for idx,c in enumerate(serial[section][:8],1):
        m=c["metrics"]
        print(idx, "+".join(c["assets"]), c["buy"], "/", c["sell"], "amt", int(c["trade_amount"]), "max", c["max_position"], "cd", c["cooldown"], "sl", c["stop_loss_pct"], "tp", c["take_profit_pct"], "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", None if m['sharpe'] is None else round(m['sharpe'],2), "trades", c["trades"])

if __name__ == "__main__": main()
