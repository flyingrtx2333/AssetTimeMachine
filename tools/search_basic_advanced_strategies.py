#!/usr/bin/env python3
import datetime as dt
import itertools
import json
import math
import statistics
import urllib.parse
import urllib.request
from bisect import bisect_right
from dataclasses import dataclass
from pathlib import Path

BASE = "https://api.flyingrtx.com/api/v1/money/public/history"
INITIAL_CASH = 100_000.0
FEE_RATE = 0.001
SLIPPAGE_RATE = 0.0005
COOLDOWN_DAYS = 3
STOP_LOSS = 0.0
TAKE_PROFIT = 0.0

ASSETS = {
    "gold_cny": {"title": "黄金", "requires_fx": False},
    "sp500": {"title": "标普500", "requires_fx": True},
    "nasdaq": {"title": "纳指", "requires_fx": True},
    "dowjones": {"title": "道指", "requires_fx": True},
    "csi300": {"title": "沪深300", "requires_fx": False},
    "shanghai_composite": {"title": "上证综指", "requires_fx": False},
}
SYMBOL_ALIASES = {"nasdaq_composite": "nasdaq", "dow_jones": "dowjones"}
BUY_RULES = [
    ("alwaysBuy", 1, "持续买入"),
    ("consecutiveDown", 2, "连续下跌2日"),
    ("consecutiveDown", 3, "连续下跌3日"),
    ("consecutiveDown", 5, "连续下跌5日"),
    ("priceAboveMA20", 1, "价格高于MA20"),
    ("priceAboveMA60", 1, "价格高于MA60"),
    ("priceCrossesAboveMA20", 1, "价格上穿MA20"),
    ("priceCrossesAboveBollMiddle", 1, "价格上穿BOLL中轨"),
    ("touchesBollLower", 1, "触及BOLL下轨"),
    ("ma20CrossesAboveMA60", 1, "MA20上穿MA60"),
]
SELL_RULES = [
    ("neverSell", 1, "不主动卖出"),
    ("consecutiveUp", 2, "连续上涨2日"),
    ("consecutiveUp", 3, "连续上涨3日"),
    ("consecutiveUp", 5, "连续上涨5日"),
    ("priceBelowMA20", 1, "价格低于MA20"),
    ("priceBelowMA60", 1, "价格低于MA60"),
    ("priceCrossesBelowMA20", 1, "价格下穿MA20"),
    ("priceCrossesBelowBollMiddle", 1, "价格下穿BOLL中轨"),
    ("touchesBollUpper", 1, "触及BOLL上轨"),
    ("ma20CrossesBelowMA60", 1, "MA20下穿MA60"),
]
TRADE_AMOUNTS = [INITIAL_CASH * 0.05, INITIAL_CASH * 0.10, INITIAL_CASH * 0.20]
MAX_POSITIONS = [35, 50, 70, 100]
# Include app default 70, already covered. Keep the grid lean but faithful to user-facing optimizer options.

ASSET_SETS = [
    ("gold_cny",), ("nasdaq",), ("sp500",), ("dowjones",), ("csi300",), ("shanghai_composite",),
    ("gold_cny", "nasdaq"),
    ("gold_cny", "sp500"),
    ("gold_cny", "nasdaq", "sp500"),
    ("gold_cny", "nasdaq", "sp500", "dowjones"),
    ("gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"),
    ("gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"),
    ("gold_cny", "csi300", "shanghai_composite"),
    ("gold_cny", "nasdaq", "csi300"),
    ("gold_cny", "sp500", "csi300"),
]
# Values are filled at runtime; None means full history.
SLICES: dict[str, dt.date | None] = {
    "full": None,
    "post_2020": dt.date(2020, 1, 1),
    "last_10y": None,  # calculated from end date
}

@dataclass(frozen=True)
class RuleKey:
    buy: str
    buy_days: int
    buy_title: str
    sell: str
    sell_days: int
    sell_title: str
    trade_amount: float
    max_position: int

@dataclass
class SeriesResult:
    dates: list
    values: list
    trades: int
    final_cash: float
    exposure: float


def fetch(symbols):
    url = BASE + "?" + urllib.parse.urlencode({
        "symbols": ",".join(symbols),
        "start_date": "2000-01-01",
        "end_date": dt.date.today().isoformat(),
    })
    with urllib.request.urlopen(url, timeout=90) as r:
        return json.load(r)["series"]


def parse_date(s):
    y, m, d = map(int, s.split("-"))
    return dt.date(y, m, d)


def load_data():
    batches = [
        ["gold_cny", "nasdaq_composite", "sp500", "usd_per_cny"],
        ["hang_seng", "nikkei225", "csi300", "shanghai_composite", "dow_jones"],
    ]
    raw = []
    for b in batches:
        raw.extend(fetch(b))
    series = {}
    for s in raw:
        sym = SYMBOL_ALIASES.get(s["symbol"], s["symbol"])
        if sym in series and len(series[sym]["dates"]) >= len(s["dates"]):
            continue
        series[sym] = s
    return series


def moving_average(vals, period):
    out = [None] * len(vals)
    rs = 0.0
    for i, v in enumerate(vals):
        rs += v
        if i >= period:
            rs -= vals[i-period]
        if i >= period-1:
            out[i] = rs / period
    return out


def bollinger(vals, period=20, mult=2):
    out = [None] * len(vals)
    rs = 0.0
    rss = 0.0
    for i, v in enumerate(vals):
        rs += v
        rss += v*v
        if i >= period:
            old = vals[i-period]
            rs -= old
            rss -= old*old
        if i >= period-1:
            mean = rs / period
            var = max(rss / period - mean*mean, 0.0)
            sd = math.sqrt(var)
            out[i] = (mean, mean - mult*sd, mean + mult*sd)
    return out


def make_fx_lookup(series):
    pts = [(parse_date(d), p) for d, p in zip(series["dates"], series["prices"]) if p and p > 0 and math.isfinite(p)]
    pts.sort()
    dates = [x[0] for x in pts]
    prices = [x[1] for x in pts]
    return dates, prices


def fx_on_or_before(fx, date):
    dates, prices = fx
    i = bisect_right(dates, date) - 1
    if i < 0:
        return None
    return prices[i]


def normalize_asset(sym, s, fx_lookup):
    pts = []
    requires_fx = ASSETS[sym]["requires_fx"]
    for dtext, price in zip(s["dates"], s["prices"]):
        if not price or price <= 0 or not math.isfinite(price):
            continue
        date = parse_date(dtext)
        cny = price
        if requires_fx:
            fx = fx_on_or_before(fx_lookup, date)
            if fx is None or fx <= 0 or not math.isfinite(fx):
                continue
            if fx < 1:  # USD per CNY
                cny = price / fx
            elif fx <= 20:  # CNY per USD fallback
                cny = price * fx
            else:
                continue
        pts.append((date, cny))
    pts.sort()
    return pts


def precompute_signals(points):
    prices = [p for _, p in points]
    n = len(prices)
    ma20 = moving_average(prices, 20)
    ma60 = moving_average(prices, 60)
    boll = bollinger(prices, 20, 2)
    up = [0]*n
    down = [0]*n
    for i in range(1, n):
        if prices[i] > prices[i-1]:
            up[i] = up[i-1] + 1
        if prices[i] < prices[i-1]:
            down[i] = down[i-1] + 1

    def trig(kind, days, i):
        if i <= 0:
            return False
        px = prices[i]
        if kind == "alwaysBuy": return True
        if kind == "neverSell": return False
        if kind == "consecutiveDown": return down[i] == days
        if kind == "consecutiveUp": return up[i] == days
        if kind == "priceAboveMA20": return ma20[i] is not None and px > ma20[i]
        if kind == "priceBelowMA20": return ma20[i] is not None and px < ma20[i]
        if kind == "priceAboveMA60": return ma60[i] is not None and px > ma60[i]
        if kind == "priceBelowMA60": return ma60[i] is not None and px < ma60[i]
        if kind == "priceCrossesAboveMA20": return ma20[i-1] is not None and ma20[i] is not None and prices[i-1] <= ma20[i-1] and px > ma20[i]
        if kind == "priceCrossesBelowMA20": return ma20[i-1] is not None and ma20[i] is not None and prices[i-1] >= ma20[i-1] and px < ma20[i]
        if kind == "ma20CrossesAboveMA60": return ma20[i-1] is not None and ma20[i] is not None and ma60[i-1] is not None and ma60[i] is not None and ma20[i-1] <= ma60[i-1] and ma20[i] > ma60[i]
        if kind == "ma20CrossesBelowMA60": return ma20[i-1] is not None and ma20[i] is not None and ma60[i-1] is not None and ma60[i] is not None and ma20[i-1] >= ma60[i-1] and ma20[i] < ma60[i]
        if kind == "priceCrossesAboveBollMiddle": return boll[i-1] is not None and boll[i] is not None and prices[i-1] <= boll[i-1][0] and px > boll[i][0]
        if kind == "priceCrossesBelowBollMiddle": return boll[i-1] is not None and boll[i] is not None and prices[i-1] >= boll[i-1][0] and px < boll[i][0]
        if kind == "touchesBollLower": return boll[i-1] is not None and boll[i] is not None and prices[i-1] > boll[i-1][1] and px <= boll[i][1]
        if kind == "touchesBollUpper": return boll[i-1] is not None and boll[i] is not None and prices[i-1] < boll[i-1][2] and px >= boll[i][2]
        raise ValueError(kind)

    sig = {}
    for kind, days, title in BUY_RULES + SELL_RULES:
        k = (kind, days)
        if k not in sig:
            sig[k] = [trig(kind, days, i) for i in range(n)]
    return sig


def metrics(dates, vals):
    if len(vals) < 2 or vals[0] <= 0:
        return None
    returns = []
    peak = vals[0]
    mdd = 0.0
    for i in range(1, len(vals)):
        if vals[i-1] > 0:
            returns.append(vals[i]/vals[i-1]-1)
        peak = max(peak, vals[i])
        if peak > 0:
            mdd = max(mdd, (peak - vals[i])/peak)
    total = vals[-1]/vals[0]-1
    years = max((dates[-1] - dates[0]).days, 1) / 365.25
    ann = (vals[-1]/vals[0]) ** (1/years) - 1 if years > 0 else None
    vol = None
    sharpe = None
    if len(returns) > 1:
        mean = sum(returns)/len(returns)
        var = sum((r-mean)**2 for r in returns)/(len(returns)-1)
        dv = math.sqrt(var)
        vol = dv * math.sqrt(252)
        sharpe = (mean*252)/(dv*math.sqrt(252)) if dv > 0 else None
    return {"total": total, "annualized": ann, "max_drawdown": mdd, "volatility": vol, "sharpe": sharpe}


def slice_metrics(dates, vals, start):
    if start is None:
        return metrics(dates, vals)
    idx = 0
    while idx < len(dates) and dates[idx] < start:
        idx += 1
    if idx >= len(dates)-2:
        return None
    return metrics(dates[idx:], vals[idx:])


def run_single(points, signals, key, initial_cash):
    dates = [d for d, _ in points]
    prices = [p for _, p in points]
    cash = initial_cash
    units = 0.0
    avg_entry = None
    first_entry_date = None
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
            cooldown = days_since >= COOLDOWN_DAYS
            pos_value = units * px
            portfolio_before = cash + pos_value
            signal_px = prices[signal_i]
            stop = STOP_LOSS > 0 and units > 0 and avg_entry is not None and signal_px <= avg_entry * (1-STOP_LOSS)
            take = TAKE_PROFIT > 0 and units > 0 and avg_entry is not None and signal_px >= avg_entry * (1+TAKE_PROFIT)
            if (should_sell or stop or take) and units > 0 and cooldown:
                exec_px = max(px * (1 - SLIPPAGE_RATE), 0)
                gross = units * exec_px
                fee = gross * FEE_RATE
                cash += max(gross - fee, 0)
                units = 0.0
                avg_entry = None
                first_entry_date = None
                last_trade_date = date
                trades += 1
            elif should_buy and cash > 0 and cooldown:
                max_pos_value = portfolio_before * max_pos_ratio
                remaining = max(max_pos_value - pos_value, 0)
                amount = min(cash, key.trade_amount, remaining)
                if amount > 0:
                    exec_px = px * (1 + SLIPPAGE_RATE)
                    fee = amount * FEE_RATE
                    invest = max(amount - fee, 0)
                    bought = invest / exec_px if exec_px > 0 else 0
                    if bought > 0:
                        was_flat = units <= 0
                        prev_cost = (avg_entry or 0) * units
                        units += bought
                        avg_entry = (prev_cost + invest) / units if units > 0 else None
                        cash -= amount
                        if was_flat:
                            first_entry_date = date
                        last_trade_date = date
                        trades += 1
        value = cash + units * px
        values.append(value)
        if value > 0:
            exposure_sum += max(min(units * px / value, 1), 0)
            exposure_n += 1
    return SeriesResult(dates, values, trades, cash, exposure_sum/exposure_n if exposure_n else 0)


def align_sum(results):
    all_dates = sorted(set(d for r in results for d in r.dates))
    cursors = [0]*len(results)
    current = [r.values[0] for r in results]
    vals = []
    for d in all_dates:
        for j, r in enumerate(results):
            c = cursors[j]
            while c < len(r.dates) and r.dates[c] <= d:
                current[j] = r.values[c]
                c += 1
            cursors[j] = c
        vals.append(sum(current))
    return all_dates, vals


def score(m, trade_count):
    if not m:
        return -999
    ann = m["annualized"] or m["total"]
    sharpe = m["sharpe"] or 0
    # user preference: punish >10% drawdown hard, but still allow exploration
    dd = m["max_drawdown"]
    dd_penalty = dd * 1.6 + max(dd - 0.10, 0) * 6.0
    low_return_penalty = max(0.07 - ann, 0) * 2.0
    trade_penalty = 0.15 if trade_count < 2 else 0
    return ann * 1.35 + sharpe * 0.20 - dd_penalty - low_return_penalty - trade_penalty


def main():
    series = load_data()
    fx = make_fx_lookup(series["usd_per_cny"])
    points = {}
    signals = {}
    for sym in ASSETS:
        pts = normalize_asset(sym, series[sym], fx)
        points[sym] = pts
        signals[sym] = precompute_signals(pts)
    print("DATA_COVERAGE")
    for sym, pts in points.items():
        print(sym, len(pts), pts[0][0], pts[-1][0])

    keys = []
    for b in BUY_RULES:
        for s in SELL_RULES:
            for ta in TRADE_AMOUNTS:
                for mp in MAX_POSITIONS:
                    keys.append(RuleKey(b[0], b[1], b[2], s[0], s[1], s[2], ta, mp))
    print("GRID", len(keys), "keys", len(ASSET_SETS), "asset_sets")

    single_cache = {}
    for sym in ASSETS:
        per_asset_cash = {}  # results differ by initial cash because position sizing is portfolio-relative
        for n_assets in sorted({len(s) for s in ASSET_SETS if sym in s}):
            init = INITIAL_CASH / n_assets
            single_cache[(sym, n_assets)] = [run_single(points[sym], signals[sym], key, init) for key in keys]
        print("PRECOMPUTED", sym)

    end_date = max(max(r.dates) for rr in single_cache.values() for r in rr[:1])
    SLICES["last_10y"] = end_date.replace(year=end_date.year - 10)

    candidates = []
    for aset in ASSET_SETS:
        n = len(aset)
        for ki, key in enumerate(keys):
            res = [single_cache[(sym, n)][ki] for sym in aset]
            dates, vals = align_sum(res)
            m = metrics(dates, vals)
            if not m:
                continue
            trade_count = sum(r.trades for r in res)
            sm = {name: slice_metrics(dates, vals, start) for name, start in SLICES.items()}
            # hard quality floors for the main shortlist; still store a few high-return rejects separately later.
            sc = score(m, trade_count)
            if m["annualized"] is not None:
                candidates.append({
                    "score": sc,
                    "assets": aset,
                    "key": key,
                    "metrics": m,
                    "slices": sm,
                    "trades": trade_count,
                    "exposure": sum(r.exposure for r in res)/len(res),
                    "final": vals[-1],
                })
        print("EVALUATED_SET", "+".join(aset))

    # Non-dominated-ish shortlist: mdd under 12 first, sort by score then ann.
    strict = [c for c in candidates if c["metrics"]["max_drawdown"] <= 0.10 and (c["metrics"]["annualized"] or 0) >= 0.06 and c["trades"] >= 2]
    near = [c for c in candidates if c["metrics"]["max_drawdown"] <= 0.12 and (c["metrics"]["annualized"] or 0) >= 0.075 and c["trades"] >= 2]
    high = [c for c in candidates if (c["metrics"]["annualized"] or 0) >= 0.09 and c["trades"] >= 2]

    def dedupe_sorted(items, limit=20):
        out=[]; seen=set()
        for c in sorted(items, key=lambda x:(x["score"], x["metrics"]["annualized"] or -1), reverse=True):
            sig=(c["assets"], c["key"].buy, c["key"].buy_days, c["key"].sell, c["key"].sell_days, c["key"].trade_amount, c["key"].max_position)
            family=(c["assets"], c["key"].buy, c["key"].sell, c["key"].trade_amount, c["key"].max_position)
            if family in seen: continue
            seen.add(family); out.append(c)
            if len(out)>=limit: break
        return out

    result={
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "coverage": {sym: {"count": len(pts), "start": str(pts[0][0]), "end": str(pts[-1][0])} for sym, pts in points.items()},
        "grid_count": len(keys)*len(ASSET_SETS),
        "strict_top": dedupe_sorted(strict, 15),
        "near_top": dedupe_sorted(near, 15),
        "high_return_top": dedupe_sorted(high, 15),
    }

    def simplify(c):
        k=c["key"]
        def simp_m(m):
            if m is None: return None
            return {kk: (round(v, 6) if isinstance(v,float) else v) for kk,v in m.items()}
        return {
            "assets": list(c["assets"]),
            "buy": k.buy_title,
            "sell": k.sell_title,
            "trade_amount": k.trade_amount,
            "max_position": k.max_position,
            "score": round(c["score"], 6),
            "trades": c["trades"],
            "exposure": round(c["exposure"], 4),
            "metrics": simp_m(c["metrics"]),
            "slices": {name: simp_m(m) for name,m in c["slices"].items()},
        }
    serial={k: ([simplify(x) for x in v] if isinstance(v,list) else v) for k,v in result.items()}
    out=Path("/tmp/atm_basic_strategy_search.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2))
    print("WROTE", out)
    print("STRICT_COUNT", len(strict), "NEAR_COUNT", len(near), "HIGH_COUNT", len(high))
    for section in ["strict_top", "near_top", "high_return_top"]:
        print("\n==", section, "==")
        for i,c in enumerate(serial[section][:8],1):
            m=c["metrics"]
            print(i, "+".join(c["assets"]), c["buy"], "/", c["sell"], "amt", int(c["trade_amount"]), "max", c["max_position"],
                  "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", None if m['sharpe'] is None else round(m['sharpe'],2), "trades", c["trades"])

if __name__ == "__main__":
    main()
