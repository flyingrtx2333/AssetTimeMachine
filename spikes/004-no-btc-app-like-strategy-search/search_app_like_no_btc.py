#!/usr/bin/env python3
"""App-like no-BTC strategy search for AssetTimeMachine.

Goals:
- idea discovery only, not production card metrics
- no BTC
- previous-session signals, next-session execution
- real units + cash, fee + slippage
- AssetTimeMachine public history data, USD converted to CNY
- union calendar with max 7-day forward-fill, matching app alignment spirit
"""
from __future__ import annotations

import datetime as dt
import itertools
import json
import math
import statistics
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

API = "https://api.flyingrtx.com/api/v1/money/public/history"
SYMBOLS_RAW = ["gold_cny", "nasdaq", "sp500", "dow_jones", "csi300", "shanghai_composite", "usd_per_cny"]
USD_ASSETS = {"nasdaq", "sp500", "dow_jones"}
ALIASES = {"nasdaq_composite": "nasdaq", "dow_jones": "dowjones", "dowjones": "dowjones"}
ASSETS = ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
EQUITIES = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
US_EQ = ["nasdaq", "sp500", "dowjones"]
CN_EQ = ["csi300", "shanghai_composite"]
START = 100_000.0
FEE = 0.001
SLIP = 0.0005
MAX_STALE_DAYS = 7
OUT = Path("/tmp/atm_app_like_no_btc_strategy_search.json")

PERIODS = {
    "full": (None, None),
    "post2020": (dt.date(2020, 1, 1), None),
    "teny": (None, None),  # filled from last date
    "post2024": (dt.date(2024, 1, 1), None),
    "2002_2012": (dt.date(2002, 1, 1), dt.date(2012, 12, 31)),
    "2013_2023": (dt.date(2013, 1, 1), dt.date(2023, 12, 31)),
}
STRESS = {
    "2008金融危机": (dt.date(2007, 10, 1), dt.date(2009, 3, 31)),
    "2015A股冲击": (dt.date(2015, 6, 1), dt.date(2016, 2, 29)),
    "2020疫情": (dt.date(2020, 2, 1), dt.date(2020, 4, 30)),
    "2022通胀加息": (dt.date(2022, 1, 1), dt.date(2022, 12, 31)),
    "2026AI波动": (dt.date(2025, 12, 1), None),
}

@dataclass
class Data:
    dates: list[dt.date]
    assets: list[str]
    prices: dict[str, list[float]]
    returns: dict[str, list[float]]


def fetch_history() -> dict[str, list[tuple[dt.date, float]]]:
    query = urllib.parse.urlencode({"symbols": ",".join(SYMBOLS_RAW), "period": "all"})
    with urllib.request.urlopen(API + "?" + query, timeout=90) as resp:
        payload = json.load(resp)
    raw: dict[str, list[tuple[dt.date, float]]] = {}
    for series in payload["series"]:
        symbol = ALIASES.get(series["symbol"], series["symbol"])
        rows: list[tuple[dt.date, float]] = []
        for ds, p in zip(series.get("dates", []), series.get("prices", [])):
            try:
                day = dt.date.fromisoformat(str(ds)[:10])
                value = float(p)
            except Exception:
                continue
            if math.isfinite(value) and value > 0:
                rows.append((day, value))
        rows.sort()
        raw[symbol] = rows
    return raw


def convert_to_cny(raw: dict[str, list[tuple[dt.date, float]]]) -> dict[str, list[tuple[dt.date, float]]]:
    fx = raw["usd_per_cny"]
    fx_dates = [d for d, _ in fx]
    fx_vals = [v for _, v in fx]
    out: dict[str, list[tuple[dt.date, float]]] = {}
    import bisect
    for s in ASSETS:
        raw_key = "dow_jones" if s == "dowjones" and "dow_jones" in raw else s
        rows = []
        for day, price in raw.get(raw_key, raw.get(s, [])):
            val = price
            if s in USD_ASSETS or s == "dowjones":
                j = bisect.bisect_right(fx_dates, day) - 1
                if j < 0 or fx_vals[j] <= 0:
                    continue
                val = price / fx_vals[j]  # API usd_per_cny means USD per CNY
            if math.isfinite(val) and val > 0:
                rows.append((day, val))
        out[s] = rows
    return out


def align(series: dict[str, list[tuple[dt.date, float]]]) -> Data:
    all_dates = sorted(set(d for s in ASSETS for d, _ in series[s]))
    idx = {s: 0 for s in ASSETS}
    latest: dict[str, float] = {}
    latest_day: dict[str, dt.date] = {}
    prices = {s: [] for s in ASSETS}
    dates: list[dt.date] = []
    for day in all_dates:
        for s in ASSETS:
            rows = series[s]
            i = idx[s]
            while i < len(rows) and rows[i][0] <= day:
                latest[s] = rows[i][1]
                latest_day[s] = rows[i][0]
                i += 1
            idx[s] = i
        ok = True
        for s in ASSETS:
            if s not in latest:
                ok = False; break
            if (day - latest_day[s]).days > MAX_STALE_DAYS:
                ok = False; break
        if not ok:
            continue
        dates.append(day)
        for s in ASSETS:
            prices[s].append(latest[s])
    returns = {s: [0.0] for s in ASSETS}
    for s in ASSETS:
        p = prices[s]
        for i in range(1, len(p)):
            returns[s].append(p[i] / p[i - 1] - 1 if p[i - 1] > 0 else 0.0)
    return Data(dates, ASSETS[:], prices, returns)


def ma(vals: list[float], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    return sum(vals[i - n + 1:i + 1]) / n


def mom(vals: list[float], i: int, n: int) -> float | None:
    if i - n < 0 or vals[i - n] <= 0:
        return None
    return vals[i] / vals[i - n] - 1


def vol(vals: list[float], i: int, n: int) -> float | None:
    if i - n < 1:
        return None
    rs = [vals[j] / vals[j - 1] - 1 for j in range(i - n + 1, i + 1) if vals[j - 1] > 0]
    if len(rs) < 10:
        return None
    mean = sum(rs) / len(rs)
    var = sum((x - mean) ** 2 for x in rs) / max(len(rs) - 1, 1)
    return math.sqrt(var) * math.sqrt(252)


def drawdown(vals: list[float], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    w = vals[i - n + 1:i + 1]
    pk = max(w)
    return vals[i] / pk - 1 if pk > 0 else None


def rel_mom(data: Data, a: str, b: str, i: int, n: int) -> float | None:
    ma_ = mom(data.prices[a], i, n)
    mb = mom(data.prices[b], i, n)
    if ma_ is None or mb is None:
        return None
    return ma_ - mb


def clamp_weights(w: dict[str, float], cap: float = 1.0) -> dict[str, float]:
    out = {s: max(0.0, float(x)) for s, x in w.items() if x > 1e-8}
    sm = sum(out.values())
    if sm > cap and sm > 0:
        out = {s: x * cap / sm for s, x in out.items()}
    return out


def target_weights(data: Data, i: int, cfg: dict[str, Any], port_values: list[float]) -> dict[str, float]:
    # Regime/canary score: use only signal index i.
    us_ok = sum(
        1 for s in US_EQ[:cfg["us_canary_n"]]
        if (mom(data.prices[s], i, cfg["canary_lb"]) or -9) > cfg["canary_thr"]
        and (ma(data.prices[s], i, cfg["canary_ma"]) is not None and data.prices[s][i] >= ma(data.prices[s], i, cfg["canary_ma"]))
    )
    cn_ok = sum(
        1 for s in CN_EQ
        if (mom(data.prices[s], i, cfg["cn_canary_lb"]) or -9) > cfg["cn_canary_thr"]
    )
    gold_ok = (mom(data.prices["gold_cny"], i, cfg["gold_lb"]) or -9) > cfg["gold_thr"] and (
        ma(data.prices["gold_cny"], i, cfg["gold_ma"]) is not None and data.prices["gold_cny"][i] >= ma(data.prices["gold_cny"], i, cfg["gold_ma"])
    )
    risk_on = us_ok >= cfg["us_need"] and cn_ok >= cfg["cn_need"]

    scores = []
    for s in cfg["pool"]:
        m1 = mom(data.prices[s], i, cfg["mom1"]) or -9
        m2 = mom(data.prices[s], i, cfg["mom2"]) or -9
        v = vol(data.prices[s], i, cfg["vol_lb"]) or 9
        dd = drawdown(data.prices[s], i, cfg["dd_lb"]) or -1
        above_ma = ma(data.prices[s], i, cfg["asset_ma"])
        if above_ma is None or data.prices[s][i] < above_ma:
            continue
        sc = cfg["m1w"] * m1 + cfg["m2w"] * m2 - cfg["vol_pen"] * v + cfg["dd_bonus"] * dd
        if s == "gold_cny":
            sc += cfg["gold_bias"]
        if s in US_EQ:
            sc += cfg["us_bias"]
        scores.append((sc, s, v))
    scores.sort(reverse=True)

    w: dict[str, float] = {}
    if risk_on and scores:
        chosen = scores[:cfg["top_n"]]
        inv_vol = []
        for _, s, v in chosen:
            inv_vol.append((s, 1.0 / max(v, 0.05)))
        total_iv = sum(x for _, x in inv_vol)
        for s, x in inv_vol:
            w[s] = cfg["risk_exposure"] * x / total_iv
        if gold_ok and cfg["gold_sleeve"] > 0:
            w["gold_cny"] = w.get("gold_cny", 0) + cfg["gold_sleeve"]
    else:
        if gold_ok:
            w["gold_cny"] = cfg["def_gold"]
        # else cash

    # February / weak equity brake.
    if data.dates[i].month in cfg["weak_months"]:
        eq_exp = sum(w.get(s, 0.0) for s in EQUITIES)
        weak = any((mom(data.prices[s], i, cfg["weak_lb"]) or 0) < cfg["weak_thr"] for s in EQUITIES if w.get(s, 0) > 1e-8)
        if weak and eq_exp > cfg["weak_eq_cap"]:
            scale = cfg["weak_eq_cap"] / eq_exp
            for s in EQUITIES:
                if s in w:
                    w[s] *= scale

    # Portfolio drawdown brake: scale equities when our own strategy is in a hole.
    if len(port_values) > cfg["port_lb"]:
        recent = port_values[-cfg["port_lb"]:]
        pk = max(recent)
        pdd = 1 - port_values[-1] / pk if pk > 0 else 0
        if pdd > cfg["port_dd"]:
            for s in EQUITIES:
                if s in w:
                    w[s] *= cfg["port_scale"]

    return clamp_weights(w, cfg["max_exp"])


def simulate(data: Data, cfg: dict[str, Any]) -> tuple[list[float], list[dict[str, float]], dict[str, Any]]:
    cash = START
    units = {s: 0.0 for s in ASSETS}
    vals: list[float] = []
    weights_after: list[dict[str, float]] = []
    trades = 0
    turn_sum = 0.0
    rebalance_days = 0
    guard_exits = 0

    def pv(i: int) -> float:
        return cash + sum(units[s] * data.prices[s][i] for s in ASSETS)

    for i, day in enumerate(data.dates):
        # app-style cash accrual approximation: PBC demand deposit default around 0.35% annual
        if i > 0 and cash > 0:
            cash *= 1 + 0.0035 / 365.25 * max((data.dates[i] - data.dates[i - 1]).days, 1)
        value = pv(i)

        if i > max(cfg["warmup"], 1) and cfg.get("daily_guard", False):
            sig = i - 1
            cur_val = pv(i)
            target: dict[str, float] | None = None
            for s in ASSETS:
                if units[s] <= 1e-12:
                    continue
                p_sig = data.prices[s][sig]
                ma_fast = ma(data.prices[s], sig, cfg["guard_ma"])
                m_fast = mom(data.prices[s], sig, cfg["guard_mom"])
                dd_fast = drawdown(data.prices[s], sig, cfg["guard_dd_lb"])
                is_bad = (
                    (ma_fast is not None and p_sig < ma_fast and (m_fast or 0) < cfg["guard_mom_thr"])
                    or ((dd_fast or 0) < -cfg["guard_dd_thr"] and (m_fast or 0) < cfg["guard_mom_confirm"])
                )
                if is_bad:
                    target = target or {x: units[x] * data.prices[x][i] / cur_val for x in ASSETS if cur_val > 0}
                    target[s] = min(target.get(s, 0), cfg["guard_asset_cap"])
                    guard_exits += 1
            if target is not None:
                gold_ma = ma(data.prices["gold_cny"], sig, cfg["gold_ma"])
                gold_ok_now = gold_ma is not None and data.prices["gold_cny"][sig] >= gold_ma and (mom(data.prices["gold_cny"], sig, cfg["gold_lb"]) or -9) > cfg["gold_thr"]
                if gold_ok_now and cfg.get("guard_redeploy_gold", 0) > 0:
                    before = sum(units[x] * data.prices[x][i] / cur_val for x in ASSETS if cur_val > 0)
                    after = sum(target.values())
                    target["gold_cny"] = target.get("gold_cny", 0) + max(before - after, 0) * cfg["guard_redeploy_gold"]
                target = clamp_weights(target, cfg["max_exp"])
                cur_val = pv(i)
                for s in ASSETS:
                    cur_value = units[s] * data.prices[s][i]
                    target_value = cur_val * target.get(s, 0.0)
                    if cur_value > target_value * (1 + cfg["band"]):
                        sell_value = cur_value - target_value
                        sell_units = min(units[s], sell_value / data.prices[s][i])
                        if sell_units > 1e-12:
                            gross = sell_units * data.prices[s][i] * (1 - SLIP)
                            cash += gross * (1 - FEE)
                            units[s] -= sell_units
                            trades += 1
                if target.get("gold_cny", 0) > 0:
                    cur_val = pv(i)
                    cur_value = units["gold_cny"] * data.prices["gold_cny"][i]
                    target_value = cur_val * target.get("gold_cny", 0.0)
                    if cur_value < target_value * (1 - cfg["band"]):
                        amount = min(cash, target_value - cur_value)
                        if amount > 1:
                            exec_price = data.prices["gold_cny"][i] * (1 + SLIP)
                            bought = amount * (1 - FEE) / exec_price
                            if bought > 1e-12:
                                units["gold_cny"] += bought
                                cash -= amount
                                trades += 1

        if i > max(cfg["warmup"], 1) and (i - cfg["warmup"]) % cfg["rebalance"] == 0:
            sig = i - 1
            cur_val = pv(i)
            old_weights = {s: (units[s] * data.prices[s][i] / cur_val if cur_val > 0 else 0.0) for s in ASSETS}
            target = target_weights(data, sig, cfg, vals if vals else [START])
            # Sell first.
            for s in ASSETS:
                cur_value = units[s] * data.prices[s][i]
                target_value = cur_val * target.get(s, 0.0)
                if cur_value > target_value * (1 + cfg["band"]):
                    sell_value = cur_value - target_value
                    sell_units = min(units[s], sell_value / data.prices[s][i])
                    if sell_units > 1e-12:
                        gross = sell_units * data.prices[s][i] * (1 - SLIP)
                        cash += gross * (1 - FEE)
                        units[s] -= sell_units
                        trades += 1
            # Recompute after sells; buy.
            cur_val = pv(i)
            for s in ASSETS:
                cur_value = units[s] * data.prices[s][i]
                target_value = cur_val * target.get(s, 0.0)
                if cur_value < target_value * (1 - cfg["band"]):
                    amount = min(cash, target_value - cur_value)
                    if amount > 1:
                        exec_price = data.prices[s][i] * (1 + SLIP)
                        bought = amount * (1 - FEE) / exec_price
                        if bought > 1e-12:
                            units[s] += bought
                            cash -= amount
                            trades += 1
            new_val = pv(i)
            new_weights = {s: (units[s] * data.prices[s][i] / new_val if new_val > 0 else 0.0) for s in ASSETS}
            turn_sum += sum(abs(new_weights.get(s, 0) - old_weights.get(s, 0)) for s in ASSETS)
            rebalance_days += 1
        value = pv(i)
        vals.append(value)
        total = value if value > 0 else 1
        weights_after.append({s: units[s] * data.prices[s][i] / total for s in ASSETS if units[s] * data.prices[s][i] / total > 1e-4})
    extra = {"trades": trades, "guard_exits": guard_exits, "avg_turnover": turn_sum / max(rebalance_days, 1), "rebalance_days": rebalance_days, "latest_weights": weights_after[-1]}
    return vals, weights_after, extra


def metrics(dates: list[dt.date], values: list[float], start: dt.date | None = None, end: dt.date | None = None) -> dict[str, float] | None:
    if start is None:
        start = dates[0]
    if end is None:
        end = dates[-1]
    lo = 0
    while lo < len(dates) and dates[lo] < start:
        lo += 1
    hi = len(dates)
    while hi > 0 and dates[hi - 1] > end:
        hi -= 1
    if hi - lo < 30:
        return None
    ds = dates[lo:hi]
    vs = values[lo:hi]
    if vs[0] <= 0:
        return None
    peak = vs[0]
    dd = 0.0
    rets = []
    for prev, cur in zip(vs, vs[1:]):
        if prev > 0 and cur > 0:
            rets.append(cur / prev - 1)
        peak = max(peak, cur)
        dd = max(dd, 1 - cur / peak)
    years = max((ds[-1] - ds[0]).days, 1) / 365.25
    total = vs[-1] / vs[0] - 1
    ann = (vs[-1] / vs[0]) ** (1 / years) - 1
    vol_ann = statistics.stdev(rets) * math.sqrt(252) if len(rets) > 1 else 0.0
    sharpe = (statistics.mean(rets) * 252) / vol_ann if vol_ann > 0 else 0.0
    return {"ann": ann, "dd": dd, "total": total, "vol": vol_ann, "sharpe": sharpe, "calmar": ann / dd if dd > 0 else 0.0, "n": len(vs)}


def all_metrics(data: Data, vals: list[float]) -> dict[str, Any]:
    periods = dict(PERIODS)
    try:
        ten_start = data.dates[-1].replace(year=data.dates[-1].year - 10)
    except ValueError:
        ten_start = data.dates[-1] - dt.timedelta(days=3652)
    periods["teny"] = (ten_start, None)
    return {k: metrics(data.dates, vals, st, en) for k, (st, en) in periods.items()}


def stress_metrics(data: Data, vals: list[float]) -> dict[str, Any]:
    return {k: metrics(data.dates, vals, st, en) for k, (st, en) in STRESS.items()}


def top_drawdowns(data: Data, vals: list[float], weights: list[dict[str, float]], n=5):
    peak = trough = 0
    out = []
    for i in range(1, len(vals)):
        if vals[i] > vals[peak]:
            if vals[trough] < vals[peak] * 0.985:
                out.append((peak, trough, 1 - vals[trough] / vals[peak], weights[trough]))
            peak = trough = i
        elif vals[i] < vals[trough]:
            trough = i
    if vals[trough] < vals[peak] * 0.985:
        out.append((peak, trough, 1 - vals[trough] / vals[peak], weights[trough]))
    out.sort(key=lambda x: x[2], reverse=True)
    return [{"peak": str(data.dates[a]), "trough": str(data.dates[b]), "dd": c, "weights": {k: round(v*100,1) for k,v in w.items()}} for a,b,c,w in out[:n]]


def score(row: dict[str, Any]) -> float:
    m = row["metrics"]
    f = m["full"]; p20 = m["post2020"]; ten = m["teny"]
    if not f or not p20 or not ten:
        return -999
    ann = f["ann"]; dd = f["dd"]; ten_ann = ten["ann"]; p20_ann = p20["ann"]
    # Hard preference: dd under 10, but don't crush return.
    penalty = max(dd - 0.10, 0) * 12 + max(0.08 - ann, 0) * 5 + max(0.07 - ten_ann, 0) * 3
    return ann * 6 + ten_ann * 2 + p20_ann * 1.5 + f["sharpe"] * 0.3 + f["calmar"] * 0.12 - dd * 4 - penalty


def main():
    raw = fetch_history()
    data = align(convert_to_cny(raw))
    print("DATA", data.dates[0], data.dates[-1], len(data.dates), data.assets, flush=True)

    cfgs = []
    base = {
        "pool": ASSETS,
        "us_canary_n": 2,
        "cn_need": 0,
        "weak_months": (2,),
        "weak_lb": 60,
        "weak_thr": -0.02,
        "band": 0.015,
        "m1w": 0.70,
        "m2w": 0.30,
        "dd_bonus": 0.12,
        "warmup": 260,
    }
    # First pass: intentionally small/focused grid. Expand only after we see a promising family.
    for rebalance in [20, 60]:
      for top_n in [1, 2]:
       for risk_exp in [0.60, 0.72, 0.84]:
        for max_exp in [0.75, 0.85, 0.95]:
         for mom1, mom2 in [(60, 120), (90, 180), (120, 240)]:
          for canary_lb, canary_ma, us_need in [(60,120,1),(120,180,1),(120,180,2)]:
           for gold_sleeve in [0.0, 0.08, 0.15]:
            for def_gold in [0.0, 0.45, 0.70]:
             for port_dd, port_scale in [(0.055,0.5),(0.075,0.65),(0.10,0.85)]:
              cfg = dict(base)
              cfg.update({
                "name": f"app_like_m{mom1}_{mom2}_rb{rebalance}_top{top_n}_risk{risk_exp}_max{max_exp}_gold{gold_sleeve}_def{def_gold}_pdd{port_dd}",
                "rebalance": rebalance,
                "top_n": top_n,
                "risk_exposure": risk_exp,
                "max_exp": max_exp,
                "mom1": mom1,
                "mom2": mom2,
                "asset_ma": 120 if mom1 <= 90 else 180,
                "vol_lb": 60,
                "dd_lb": 60,
                "vol_pen": 0.18,
                "gold_bias": 0.00,
                "us_bias": 0.01,
                "gold_sleeve": gold_sleeve,
                "gold_lb": 90,
                "gold_thr": -0.005,
                "gold_ma": 120,
                "def_gold": def_gold,
                "canary_lb": canary_lb,
                "canary_thr": -0.02,
                "canary_ma": canary_ma,
                "us_need": us_need,
                "cn_canary_lb": 60,
                "cn_canary_thr": -0.06,
                "weak_eq_cap": 0.30,
                "port_lb": 60,
                "port_dd": port_dd,
                "port_scale": port_scale,
                "daily_guard": True,
                "guard_ma": 80,
                "guard_mom": 20,
                "guard_mom_thr": -0.005,
                "guard_dd_lb": 40,
                "guard_dd_thr": 0.055,
                "guard_mom_confirm": 0.0,
                "guard_asset_cap": 0.0,
                "guard_redeploy_gold": 0.35,
              })
              cfgs.append(cfg)

    rows = []
    evaluated = 0
    for cfg in cfgs:
        vals, ws, extra = simulate(data, cfg)
        m = all_metrics(data, vals)
        f = m["full"]
        if not f:
            continue
        evaluated += 1
        # Keep a broad frontier; final sort decides.
        if f["ann"] >= 0.055 and f["dd"] <= 0.16:
            row = {"name": cfg["name"], "cfg": cfg, "metrics": m, "stress": stress_metrics(data, vals), "extra": extra, "top_dd": top_drawdowns(data, vals, ws), "score": 0.0}
            row["score"] = score(row)
            rows.append(row)
        if evaluated % 2000 == 0:
            print("evaluated", evaluated, "kept", len(rows), flush=True)
    rows.sort(key=lambda r: (r["metrics"]["full"]["dd"] <= 0.10, r["score"]), reverse=True)
    strict = [r for r in rows if r["metrics"]["full"]["dd"] <= 0.10]
    under12 = [r for r in rows if r["metrics"]["full"]["dd"] <= 0.12]
    best_return_under10 = sorted(strict, key=lambda r: r["metrics"]["full"]["ann"], reverse=True)[:20]
    best_score = rows[:40]
    result = {"coverage": {s: [str(data.dates[0]), str(data.dates[-1]), len(data.dates)] for s in ASSETS}, "evaluated": evaluated, "kept": len(rows), "strict_count": len(strict), "under12_count": len(under12), "best_return_under10": best_return_under10, "best_score": best_score[:40]}
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    print("WROTE", OUT, "evaluated", evaluated, "kept", len(rows), "strict", len(strict), "under12", len(under12))
    for sec, arr in [("UNDER10_BY_RETURN", best_return_under10[:10]), ("BEST_SCORE", best_score[:10])]:
        print("\n==", sec, "==")
        for i, r in enumerate(arr, 1):
            f = r["metrics"]["full"]; p20 = r["metrics"]["post2020"]; ten = r["metrics"]["teny"]
            print(i, r["name"], f"ann={f['ann']*100:.2f}% dd={f['dd']*100:.2f}% sh={f['sharpe']:.2f}", f"post20={p20['ann']*100:.2f}/{p20['dd']*100:.2f}", f"ten={ten['ann']*100:.2f}/{ten['dd']*100:.2f}", "latest", {k: round(v*100,1) for k,v in r["extra"]["latest_weights"].items()})

if __name__ == "__main__":
    main()
