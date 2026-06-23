#!/usr/bin/env python3
"""No-BTC full-cycle strategy search from 2002 for AssetTimeMachine.

Universe: gold_cny, nasdaq, sp500, dowjones, csi300, shanghai_composite.
Start: common aligned data from 2002-01-04.
Execution: previous-session signals, next-session rebalance, fees/slippage.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

BASE_URL = "https://api.flyingrtx.com/api/v1/money/public/history"
INITIAL = 100_000.0
FEE = 0.001
SLIP = 0.0005
START_DATE = dt.date(2002, 1, 4)
SYMS = ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
EQUITIES = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]
USD_ASSETS = {"nasdaq", "sp500", "dowjones"}
ALIASES = {"nasdaq_composite": "nasdaq", "dow_jones": "dowjones"}
TITLES = {
    "gold_cny": "黄金",
    "nasdaq": "纳指",
    "sp500": "标普500",
    "dowjones": "道指",
    "csi300": "沪深300",
    "shanghai_composite": "上证综指",
}

spec = importlib.util.spec_from_file_location("base_search", "tools/search_basic_advanced_strategies.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load base search helpers")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def fetch(symbols: list[str]) -> list[dict[str, Any]]:
    url = BASE_URL + "?" + urllib.parse.urlencode({
        "symbols": ",".join(symbols),
        "start_date": "2002-01-01",
        "end_date": dt.date.today().isoformat(),
    })
    with urllib.request.urlopen(url, timeout=90) as response:
        return json.load(response)["series"]


def parse_date(text: str) -> dt.date:
    y, m, d = map(int, text.split("-"))
    return dt.date(y, m, d)


def load_aligned() -> tuple[list[dt.date], dict[str, list[float]], dict[str, Any]]:
    raw: list[dict[str, Any]] = []
    raw.extend(fetch(["gold_cny", "nasdaq", "sp500", "usd_per_cny"]))
    raw.extend(fetch(["dow_jones", "csi300", "shanghai_composite"]))
    series: dict[str, dict[str, Any]] = {}
    for item in raw:
        raw_symbol = item["symbol"]
        sym = ALIASES.get(raw_symbol, raw_symbol)
        series[sym] = item

    fx_lookup = base.make_fx_lookup(series["usd_per_cny"])
    fx_dates, fx_prices = fx_lookup

    def fx_on_or_before(date: dt.date) -> float | None:
        import bisect
        i = bisect.bisect_right(fx_dates, date) - 1
        if i < 0:
            return None
        return fx_prices[i]

    points: dict[str, list[tuple[dt.date, float]]] = {}
    coverage: dict[str, Any] = {}
    for sym in SYMS:
        pts: list[tuple[dt.date, float]] = []
        item = series[sym]
        for date_text, raw_price in zip(item["dates"], item["prices"]):
            if raw_price is None or raw_price <= 0 or not math.isfinite(raw_price):
                continue
            date = parse_date(date_text)
            if date < START_DATE:
                continue
            price = float(raw_price)
            if sym in USD_ASSETS:
                fx = fx_on_or_before(date)
                if fx is None or fx <= 0 or not math.isfinite(fx):
                    continue
                price = price / fx if fx < 1 else price * fx if fx <= 20 else math.nan
                if not math.isfinite(price):
                    continue
            pts.append((date, price))
        pts.sort()
        points[sym] = pts
        coverage[sym] = {"count": len(pts), "start": str(pts[0][0]), "end": str(pts[-1][0])}

    all_dates = sorted(set(date for pts in points.values() for date, _ in pts))
    idx = {sym: 0 for sym in SYMS}
    latest: dict[str, float] = {}
    latest_date: dict[str, dt.date] = {}
    dates: list[dt.date] = []
    prices = {sym: [] for sym in SYMS}
    for date in all_dates:
        if date < START_DATE:
            continue
        ok = True
        for sym in SYMS:
            pts = points[sym]
            i = idx[sym]
            while i < len(pts) and pts[i][0] <= date:
                latest[sym] = pts[i][1]
                latest_date[sym] = pts[i][0]
                i += 1
            idx[sym] = i
            # Same forward-fill spirit as app rotation alignment: tolerate market holiday gaps only.
            if sym not in latest or (date - latest_date[sym]).days > 7:
                ok = False
                break
        if ok:
            dates.append(date)
            for sym in SYMS:
                prices[sym].append(latest[sym])
    coverage["aligned"] = {"count": len(dates), "start": str(dates[0]), "end": str(dates[-1])}
    return dates, prices, coverage


def moving_average(values: list[float], n: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    rolling = 0.0
    for i, v in enumerate(values):
        rolling += v
        if i >= n:
            rolling -= values[i - n]
        if i >= n - 1:
            out[i] = rolling / n
    return out


def momentum(values: list[float], i: int, n: int) -> float | None:
    if i - n < 0 or values[i - n] <= 0:
        return None
    return values[i] / values[i - n] - 1


def annualized_vol(values: list[float], i: int, n: int) -> float | None:
    if i - n < 1:
        return None
    returns = []
    for j in range(i - n + 1, i + 1):
        if values[j - 1] > 0 and values[j] > 0:
            returns.append(math.log(values[j] / values[j - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    var = sum((x - mean) ** 2 for x in returns) / (len(returns) - 1)
    return math.sqrt(max(var, 0.0)) * math.sqrt(252)


def rolling_drawdown(values: list[float], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    window = values[i - n + 1 : i + 1]
    peak = max(window)
    if peak <= 0:
        return None
    return values[i] / peak - 1


def build_cache(prices: dict[str, list[float]]) -> dict[str, Any]:
    cache: dict[str, Any] = {"ma": {}, "mom": {}, "vol": {}, "dd": {}}
    ma_periods = [80, 120, 160, 180, 200, 220, 240]
    mom_periods = [60, 90, 120, 180]
    vol_periods = [40, 60]
    dd_periods = [60, 120]
    for sym in SYMS:
        for n in ma_periods:
            cache["ma"][(sym, n)] = moving_average(prices[sym], n)
        for n in mom_periods:
            cache["mom"][(sym, n)] = [momentum(prices[sym], i, n) for i in range(len(prices[sym]))]
        for n in vol_periods:
            cache["vol"][(sym, n)] = [annualized_vol(prices[sym], i, n) for i in range(len(prices[sym]))]
        for n in dd_periods:
            cache["dd"][(sym, n)] = [rolling_drawdown(prices[sym], i, n) for i in range(len(prices[sym]))]
    return cache


def metrics(dates: list[dt.date], values: list[float]) -> dict[str, Any] | None:
    return base.metrics(dates, values)


def slices(dates: list[dt.date], values: list[float]) -> dict[str, Any]:
    return {
        "full": base.metrics(dates, values),
        "post_2020": base.slice_metrics(dates, values, dt.date(2020, 1, 1)),
        "last_10y": base.slice_metrics(dates, values, dates[-1].replace(year=dates[-1].year - 10)),
        "post_2022": base.slice_metrics(dates, values, dt.date(2022, 1, 1)),
    }


def score(sl: dict[str, Any], trades: int) -> float:
    full = sl["full"]
    if not full:
        return -999
    p20 = sl["post_2020"] or {}
    y10 = sl["last_10y"] or {}
    p22 = sl["post_2022"] or {}
    ann = full["annualized"] or 0.0
    dd = full["max_drawdown"]
    sh = full["sharpe"] or 0.0
    p20_ann = p20.get("annualized") or 0.0
    y10_ann = y10.get("annualized") or 0.0
    p22_ann = p22.get("annualized") or 0.0
    p20_dd = p20.get("max_drawdown") or 0.0
    y10_dd = y10.get("max_drawdown") or 0.0
    p22_dd = p22.get("max_drawdown") or 0.0
    return (
        ann * 1.55
        + p20_ann * 0.35
        + y10_ann * 0.25
        + p22_ann * 0.15
        + sh * 0.20
        - dd * 1.75
        - max(dd - 0.10, 0) * 8.0
        - max(p20_dd - 0.12, 0) * 3.0
        - max(y10_dd - 0.12, 0) * 2.0
        - max(p22_dd - 0.12, 0) * 1.5
        - (0.08 if trades < 20 else 0.0)
    )


def simulate_core_trend(
    dates: list[dt.date],
    prices: dict[str, list[float]],
    cache: dict[str, Any],
    cfg: dict[str, Any],
) -> tuple[list[float], int, float]:
    cash = INITIAL
    units = {sym: 0.0 for sym in SYMS}
    values: list[float] = []
    trades = 0
    exposure_sum = 0.0
    last_rebalance = -10**9
    for i, date in enumerate(dates):
        def pv() -> float:
            return cash + sum(units[sym] * prices[sym][i] for sym in SYMS)

        if i > 0 and i - last_rebalance >= cfg["rebalance"]:
            sig = i - 1
            target = {sym: 0.0 for sym in SYMS}
            for sym, base_w in cfg["weights"].items():
                ma = cache["ma"][(sym, cfg["ma"].get(sym, cfg["eq_ma"]))][sig]
                mom = cache["mom"][(sym, cfg["mom_lb"].get(sym, cfg["eq_mom_lb"]))][sig]
                vol = cache["vol"][(sym, cfg["vol_lb"])][sig]
                dd = cache["dd"][(sym, cfg["dd_lb"])][sig]
                trend_ok = ma is not None and prices[sym][sig] > ma
                mom_ok = mom is not None and mom > cfg["mom_th"].get(sym, cfg["eq_mom_th"])
                vol_ok = vol is None or vol < cfg["vol_cap"].get(sym, cfg["eq_vol_cap"])
                dd_ok = dd is None or dd > -cfg["dd_cap"].get(sym, cfg["eq_dd_cap"])
                if trend_ok and mom_ok and vol_ok and dd_ok:
                    target[sym] = base_w

            # If an equity sleeve is blocked, redeploy part to gold only when gold itself is active.
            blocked_equity_weight = sum(cfg["weights"].get(sym, 0.0) for sym in EQUITIES if target.get(sym, 0.0) == 0.0)
            if target.get("gold_cny", 0.0) > 0:
                target["gold_cny"] += blocked_equity_weight * cfg["redeploy_to_gold"]

            # Portfolio drawdown soft governor using previous values only.
            if len(values) >= cfg["portfolio_dd_lb"]:
                window = values[-cfg["portfolio_dd_lb"] :]
                peak = max(window)
                pf_dd = values[-1] / peak - 1 if peak > 0 else 0.0
                if pf_dd < -cfg["portfolio_hard_dd"]:
                    for sym in EQUITIES:
                        target[sym] *= cfg["portfolio_hard_scale"]
                elif pf_dd < -cfg["portfolio_soft_dd"]:
                    for sym in EQUITIES:
                        target[sym] *= cfg["portfolio_soft_scale"]

            # Conservative vol targeting using weighted asset vols.
            portfolio_vol = 0.0
            for sym, w in target.items():
                if w <= 0:
                    continue
                vol = cache["vol"][(sym, cfg["vol_lb"])][sig]
                portfolio_vol += w * (vol or 0.0)
            gross = sum(target.values())
            scale = 1.0
            if portfolio_vol > 0:
                scale = min(scale, cfg["target_vol"] / portfolio_vol)
            if gross > 0:
                scale = min(scale, cfg["max_exposure"] / gross)
            for sym in SYMS:
                target[sym] *= scale

            total = pv()
            # Sell first
            for sym in SYMS:
                current = units[sym] * prices[sym][i]
                desired = total * target[sym]
                if current > desired * (1 + cfg["band"]):
                    sell_units = min(units[sym], (current - desired) / prices[sym][i])
                    if sell_units > 1e-12:
                        cash += sell_units * prices[sym][i] * (1 - SLIP) * (1 - FEE)
                        units[sym] -= sell_units
                        trades += 1
            total = pv()
            # Buy second
            for sym in SYMS:
                current = units[sym] * prices[sym][i]
                desired = total * target[sym]
                if current < desired * (1 - cfg["band"]):
                    amount = min(cash, desired - current)
                    if amount > 1:
                        units[sym] += amount * (1 - FEE) / (prices[sym][i] * (1 + SLIP))
                        cash -= amount
                        trades += 1
            last_rebalance = i

        value = pv()
        values.append(value)
        exposure_sum += sum(units[sym] * prices[sym][i] for sym in SYMS) / value if value > 0 else 0.0
    return values, trades, exposure_sum / len(values)


def simulate_rotation(
    dates: list[dt.date],
    prices: dict[str, list[float]],
    cache: dict[str, Any],
    cfg: dict[str, Any],
) -> tuple[list[float], int, float]:
    cash = INITIAL
    units = {sym: 0.0 for sym in SYMS}
    values: list[float] = []
    trades = 0
    exposure_sum = 0.0
    last_rebalance = -10**9
    for i, date in enumerate(dates):
        def pv() -> float:
            return cash + sum(units[sym] * prices[sym][i] for sym in SYMS)

        if i > 0 and i - last_rebalance >= cfg["rebalance"]:
            sig = i - 1
            candidates: list[tuple[float, str]] = []
            gold_active = False
            for sym in SYMS:
                ma_period = cfg["gold_ma"] if sym == "gold_cny" else cfg["eq_ma"]
                ma = cache["ma"][(sym, ma_period)][sig]
                mom = cache["mom"][(sym, cfg["mom_lb"])][sig]
                vol = cache["vol"][(sym, cfg["vol_lb"])][sig]
                dd = cache["dd"][(sym, cfg["dd_lb"])][sig]
                if ma is None or mom is None:
                    continue
                trend_ok = prices[sym][sig] > ma and mom > cfg["mom_th"]
                vol_ok = vol is None or vol < (cfg["gold_vol_cap"] if sym == "gold_cny" else cfg["eq_vol_cap"])
                dd_ok = dd is None or dd > -(cfg["gold_dd_cap"] if sym == "gold_cny" else cfg["eq_dd_cap"])
                if not (trend_ok and vol_ok and dd_ok):
                    continue
                if sym == "gold_cny":
                    gold_active = True
                score_value = mom / max(vol or cfg["fallback_vol"], 0.05)
                candidates.append((score_value, sym))

            candidates.sort(reverse=True)
            selected = [sym for _, sym in candidates if sym != "gold_cny"][: cfg["top_n"]]
            target = {sym: 0.0 for sym in SYMS}
            if gold_active:
                target["gold_cny"] = cfg["gold_core"]
            if selected:
                sleeve = cfg["risk_sleeve"]
                # Inverse-vol split among selected equities.
                inv: dict[str, float] = {}
                for sym in selected:
                    vol = cache["vol"][(sym, cfg["vol_lb"])][sig] or cfg["fallback_vol"]
                    inv[sym] = 1 / max(vol, 0.05)
                inv_sum = sum(inv.values())
                for sym in selected:
                    target[sym] = sleeve * inv[sym] / inv_sum
            elif gold_active:
                target["gold_cny"] += cfg["empty_risk_to_gold"]

            # Portfolio drawdown governor.
            if len(values) >= cfg["portfolio_dd_lb"]:
                window = values[-cfg["portfolio_dd_lb"] :]
                peak = max(window)
                pf_dd = values[-1] / peak - 1 if peak > 0 else 0.0
                if pf_dd < -cfg["portfolio_hard_dd"]:
                    for sym in EQUITIES:
                        target[sym] *= cfg["portfolio_hard_scale"]
                elif pf_dd < -cfg["portfolio_soft_dd"]:
                    for sym in EQUITIES:
                        target[sym] *= cfg["portfolio_soft_scale"]

            gross = sum(target.values())
            portfolio_vol = sum(target[sym] * (cache["vol"][(sym, cfg["vol_lb"])][sig] or 0) for sym in SYMS)
            scale = 1.0
            if portfolio_vol > 0:
                scale = min(scale, cfg["target_vol"] / portfolio_vol)
            if gross > 0:
                scale = min(scale, cfg["max_exposure"] / gross)
            for sym in SYMS:
                target[sym] *= scale

            total = pv()
            for sym in SYMS:
                current = units[sym] * prices[sym][i]
                desired = total * target[sym]
                if current > desired * (1 + cfg["band"]):
                    sell_units = min(units[sym], (current - desired) / prices[sym][i])
                    if sell_units > 1e-12:
                        cash += sell_units * prices[sym][i] * (1 - SLIP) * (1 - FEE)
                        units[sym] -= sell_units
                        trades += 1
            total = pv()
            for sym in SYMS:
                current = units[sym] * prices[sym][i]
                desired = total * target[sym]
                if current < desired * (1 - cfg["band"]):
                    amount = min(cash, desired - current)
                    if amount > 1:
                        units[sym] += amount * (1 - FEE) / (prices[sym][i] * (1 + SLIP))
                        cash -= amount
                        trades += 1
            last_rebalance = i

        value = pv()
        values.append(value)
        exposure_sum += sum(units[sym] * prices[sym][i] for sym in SYMS) / value if value > 0 else 0.0
    return values, trades, exposure_sum / len(values)


def simplify(candidate: dict[str, Any]) -> dict[str, Any]:
    def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
        if m is None:
            return None
        return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}

    return {
        "family": candidate["family"],
        "score": round(candidate["score"], 6),
        "trades": candidate["trades"],
        "exposure": round(candidate["exposure"], 4),
        "config": candidate["config"],
        "metrics": sm(candidate["slices"]["full"]),
        "slices": {k: sm(v) for k, v in candidate["slices"].items() if k != "full"},
    }


def run_search() -> None:
    dates, prices, coverage = load_aligned()
    cache = build_cache(prices)
    print("COVERAGE", json.dumps(coverage, ensure_ascii=False), flush=True)
    candidates: list[dict[str, Any]] = []
    evaluated = 0

    weight_sets = [
        {"gold_cny": 0.55, "nasdaq": 0.30, "sp500": 0.10, "dowjones": 0.00, "csi300": 0.05, "shanghai_composite": 0.00},
        {"gold_cny": 0.60, "nasdaq": 0.25, "sp500": 0.10, "dowjones": 0.00, "csi300": 0.05, "shanghai_composite": 0.00},
        {"gold_cny": 0.50, "nasdaq": 0.35, "sp500": 0.10, "dowjones": 0.00, "csi300": 0.05, "shanghai_composite": 0.00},
        {"gold_cny": 0.55, "nasdaq": 0.35, "sp500": 0.10, "dowjones": 0.00, "csi300": 0.00, "shanghai_composite": 0.00},
        {"gold_cny": 0.60, "nasdaq": 0.30, "sp500": 0.10, "dowjones": 0.00, "csi300": 0.00, "shanghai_composite": 0.00},
        {"gold_cny": 0.50, "nasdaq": 0.25, "sp500": 0.15, "dowjones": 0.00, "csi300": 0.10, "shanghai_composite": 0.00},
        {"gold_cny": 0.50, "nasdaq": 0.30, "sp500": 0.10, "dowjones": 0.00, "csi300": 0.05, "shanghai_composite": 0.05},
        {"gold_cny": 0.45, "nasdaq": 0.35, "sp500": 0.15, "dowjones": 0.00, "csi300": 0.05, "shanghai_composite": 0.00},
    ]
    for weights in weight_sets:
        for gold_ma in [120, 180, 220]:
            for eq_ma in [160, 200, 240]:
                for target_vol in [0.11, 0.13, 0.15, 0.17]:
                    for max_exposure in [0.65, 0.75, 0.85, 0.95]:
                        for eq_dd_cap in [0.10, 0.12, 0.15]:
                            cfg = {
                                "weights": weights,
                                "ma": {"gold_cny": gold_ma},
                                "eq_ma": eq_ma,
                                "mom_lb": {"gold_cny": 120},
                                "eq_mom_lb": 120,
                                "mom_th": {"gold_cny": -0.02},
                                "eq_mom_th": -0.02,
                                "vol_lb": 60,
                                "dd_lb": 60,
                                "vol_cap": {"gold_cny": 0.35, "sp500": 0.30},
                                "eq_vol_cap": 0.36,
                                "dd_cap": {"gold_cny": 0.15, "sp500": 0.10},
                                "eq_dd_cap": eq_dd_cap,
                                "redeploy_to_gold": 0.75,
                                "portfolio_dd_lb": 120,
                                "portfolio_soft_dd": 0.06,
                                "portfolio_hard_dd": 0.10,
                                "portfolio_soft_scale": 0.70,
                                "portfolio_hard_scale": 0.35,
                                "target_vol": target_vol,
                                "max_exposure": max_exposure,
                                "rebalance": 20,
                                "band": 0.02,
                            }
                            values, trades, exposure = simulate_core_trend(dates, prices, cache, cfg)
                            sl = slices(dates, values)
                            if not sl["full"]:
                                continue
                            evaluated += 1
                            candidates.append({
                                "family": "core_trend_risk_budget",
                                "config": cfg,
                                "slices": sl,
                                "trades": trades,
                                "exposure": exposure,
                                "score": score(sl, trades),
                            })

    for gold_core in [0.35, 0.45, 0.55, 0.65]:
        for risk_sleeve in [0.25, 0.35, 0.45, 0.55]:
            for top_n in [1, 2, 3]:
                for eq_ma in [160, 200, 240]:
                    for gold_ma in [120, 180, 220]:
                        for target_vol in [0.11, 0.13, 0.15, 0.17]:
                            for max_exposure in [0.65, 0.75, 0.85, 0.95]:
                                cfg = {
                                    "gold_core": gold_core,
                                    "risk_sleeve": risk_sleeve,
                                    "top_n": top_n,
                                    "eq_ma": eq_ma,
                                    "gold_ma": gold_ma,
                                    "mom_lb": 120,
                                    "mom_th": -0.02,
                                    "vol_lb": 60,
                                    "dd_lb": 60,
                                    "gold_vol_cap": 0.35,
                                    "eq_vol_cap": 0.36,
                                    "gold_dd_cap": 0.15,
                                    "eq_dd_cap": 0.12,
                                    "fallback_vol": 0.18,
                                    "empty_risk_to_gold": 0.15,
                                    "portfolio_dd_lb": 120,
                                    "portfolio_soft_dd": 0.06,
                                    "portfolio_hard_dd": 0.10,
                                    "portfolio_soft_scale": 0.70,
                                    "portfolio_hard_scale": 0.35,
                                    "target_vol": target_vol,
                                    "max_exposure": max_exposure,
                                    "rebalance": 20,
                                    "band": 0.02,
                                }
                                values, trades, exposure = simulate_rotation(dates, prices, cache, cfg)
                                sl = slices(dates, values)
                                if not sl["full"]:
                                    continue
                                evaluated += 1
                                candidates.append({
                                    "family": "gold_core_relative_momentum_rotation",
                                    "config": cfg,
                                    "slices": sl,
                                    "trades": trades,
                                    "exposure": exposure,
                                    "score": score(sl, trades),
                                })

    print("EVALUATED", evaluated, "CANDIDATES", len(candidates), flush=True)
    candidates.sort(key=lambda c: (c["score"], c["slices"]["full"]["annualized"] or 0), reverse=True)

    def dedupe(items: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        seen = set()
        for c in items:
            cfg = c["config"]
            if c["family"] == "core_trend_risk_budget":
                key = (c["family"], tuple(sorted((k, round(v, 3)) for k, v in cfg["weights"].items() if v > 0)), cfg["ma"].get("gold_cny"), cfg["eq_ma"], cfg["target_vol"], cfg["max_exposure"], cfg["eq_dd_cap"])
            else:
                key = (c["family"], cfg["gold_core"], cfg["risk_sleeve"], cfg["top_n"], cfg["gold_ma"], cfg["eq_ma"], cfg["target_vol"], cfg["max_exposure"])
            if key in seen:
                continue
            seen.add(key)
            out.append(c)
            if len(out) >= limit:
                break
        return out

    under10 = sorted([c for c in candidates if c["slices"]["full"]["max_drawdown"] <= 0.10], key=lambda c: c["slices"]["full"]["annualized"] or 0, reverse=True)
    under11 = sorted([c for c in candidates if c["slices"]["full"]["max_drawdown"] <= 0.11], key=lambda c: c["slices"]["full"]["annualized"] or 0, reverse=True)
    under12 = sorted([c for c in candidates if c["slices"]["full"]["max_drawdown"] <= 0.12], key=lambda c: c["slices"]["full"]["annualized"] or 0, reverse=True)
    robust = [
        c for c in candidates
        if c["slices"]["full"]["max_drawdown"] <= 0.12
        and (c["slices"]["post_2020"] or {}).get("max_drawdown", 1) <= 0.12
        and (c["slices"]["last_10y"] or {}).get("max_drawdown", 1) <= 0.12
        and (c["slices"]["post_2022"] or {}).get("max_drawdown", 1) <= 0.12
    ]
    serial = {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "coverage": coverage,
        "evaluated": evaluated,
        "score_top": [simplify(c) for c in dedupe(candidates, 30)],
        "under10_by_return": [simplify(c) for c in dedupe(under10, 20)],
        "under11_by_return": [simplify(c) for c in dedupe(under11, 20)],
        "under12_by_return": [simplify(c) for c in dedupe(under12, 20)],
        "robust_top": [simplify(c) for c in dedupe(robust, 20)],
    }
    out = Path("/tmp/atm_no_btc_2002_search.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2))
    print("WROTE", out, flush=True)
    for section in ["under10_by_return", "under11_by_return", "under12_by_return", "robust_top", "score_top"]:
        print("\n==", section, "==")
        for i, c in enumerate(serial[section][:8], 1):
            m = c["metrics"]
            print(i, c["family"], "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", None if m["sharpe"] is None else round(m["sharpe"], 2), "trades", c["trades"], "exposure", c["exposure"])


if __name__ == "__main__":
    run_search()
