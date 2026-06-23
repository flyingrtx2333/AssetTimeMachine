#!/usr/bin/env python3
"""Search CPPI/TIPP-style portfolio-insurance strategies without changing asset universe.

Universe remains existing AssetTimeMachine market assets:
- gold_cny, nasdaq, sp500, dowjones, csi300, shanghai_composite
Measured window: 2002-01-04 .. latest aligned date.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
from typing import Any

spec = importlib.util.spec_from_file_location("no_btc", "tools/search_no_btc_2002_strategies.py")
if spec is None or spec.loader is None:
    raise RuntimeError("load no_btc helpers failed")
nb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nb)
base = nb.base

INITIAL = 100_000.0
FEE = 0.001
SLIP = 0.0005
SYMS = nb.SYMS
EQUITIES = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]


def ma(values: list[float], n: int) -> list[float | None]:
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


def ann_vol(values: list[float], i: int, n: int) -> float | None:
    if i - n < 1:
        return None
    rets: list[float] = []
    for j in range(i - n + 1, i + 1):
        if values[j - 1] > 0 and values[j] > 0:
            rets.append(math.log(values[j] / values[j - 1]))
    if len(rets) < 2:
        return None
    mean = sum(rets) / len(rets)
    var = sum((x - mean) ** 2 for x in rets) / (len(rets) - 1)
    return math.sqrt(max(var, 0.0)) * math.sqrt(252)


def rolling_dd(values: list[float], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    window = values[i - n + 1 : i + 1]
    peak = max(window)
    return values[i] / peak - 1 if peak > 0 else None


def weighted_basket(prices: dict[str, list[float]], weights: dict[str, float]) -> list[float]:
    n = len(next(iter(prices.values())))
    return [sum(w * prices[sym][i] / prices[sym][0] for sym, w in weights.items()) for i in range(n)]


def build_cache(prices: dict[str, list[float]], basket_weights_list: list[dict[str, float]]) -> dict[str, Any]:
    cache: dict[str, Any] = {"ma": {}, "vol": {}, "mom": {}, "dd": {}, "basket": {}}
    ma_periods = [80, 120, 160, 180, 200, 220, 260]
    mom_periods = [60, 90, 120, 180]
    vol_periods = [40, 60, 90]
    dd_periods = [60, 90, 120]
    for sym in SYMS:
        for n in ma_periods:
            cache["ma"][(sym, n)] = ma(prices[sym], n)
        for n in mom_periods:
            cache["mom"][(sym, n)] = [momentum(prices[sym], i, n) for i in range(len(prices[sym]))]
        for n in vol_periods:
            cache["vol"][(sym, n)] = [ann_vol(prices[sym], i, n) for i in range(len(prices[sym]))]
        for n in dd_periods:
            cache["dd"][(sym, n)] = [rolling_dd(prices[sym], i, n) for i in range(len(prices[sym]))]
    for idx, weights in enumerate(basket_weights_list):
        basket = weighted_basket(prices, weights)
        cache["basket"][(idx, "values")] = basket
        for n in ma_periods:
            cache["basket"][(idx, "ma", n)] = ma(basket, n)
        for n in mom_periods:
            cache["basket"][(idx, "mom", n)] = [momentum(basket, i, n) for i in range(len(basket))]
        for n in vol_periods:
            cache["basket"][(idx, "vol", n)] = [ann_vol(basket, i, n) for i in range(len(basket))]
        for n in dd_periods:
            cache["basket"][(idx, "dd", n)] = [rolling_dd(basket, i, n) for i in range(len(basket))]
    return cache


def signal_strength(prices: dict[str, list[float]], cache: dict[str, Any], sym: str, i: int, cfg: dict[str, Any]) -> float:
    ma_v = cache["ma"][(sym, cfg["asset_ma"])][i]
    mom_v = cache["mom"][(sym, cfg["asset_mom_lb"])][i]
    vol_v = cache["vol"][(sym, cfg["asset_vol_lb"])][i]
    dd_v = cache["dd"][(sym, cfg["asset_dd_lb"])][i]
    if ma_v is None or mom_v is None:
        return 0.0
    if prices[sym][i] <= ma_v:
        return 0.0
    if mom_v <= cfg["asset_mom_th"]:
        return 0.0
    if vol_v is not None and vol_v > cfg["gold_vol_cap" if sym == "gold_cny" else "eq_vol_cap"]:
        return 0.0
    if dd_v is not None and dd_v < -cfg["gold_dd_cap" if sym == "gold_cny" else "eq_dd_cap"]:
        return 0.0
    # Continuous signal: momentum per unit volatility, clipped so one asset cannot dominate too wildly.
    raw = mom_v / max(vol_v or cfg["fallback_vol"], 0.05)
    return max(0.0, min(raw, cfg["signal_clip"]))


def target_weights_from_signals(
    prices: dict[str, list[float]],
    cache: dict[str, Any],
    i: int,
    cfg: dict[str, Any],
) -> dict[str, float]:
    base_weights = cfg["risk_weights"]
    strengths: dict[str, float] = {}
    for sym, base_w in base_weights.items():
        st = signal_strength(prices, cache, sym, i, cfg)
        if st > 0 and base_w > 0:
            # Blend strategic weight and tactical signal. The exponent keeps it interpretable.
            strengths[sym] = (base_w ** cfg["base_weight_power"]) * (st ** cfg["signal_power"])
    if not strengths:
        # Risk-off: gold only if gold itself passes filter; otherwise cash.
        g = signal_strength(prices, cache, "gold_cny", i, cfg)
        if g > 0:
            return {sym: (cfg["riskoff_gold"] if sym == "gold_cny" else 0.0) for sym in SYMS}
        return {sym: 0.0 for sym in SYMS}

    total = sum(strengths.values())
    weights = {sym: 0.0 for sym in SYMS}
    for sym, value in strengths.items():
        weights[sym] = value / total
    # Keep at least some gold when gold passes; avoids all-risk-on equity concentration.
    g = signal_strength(prices, cache, "gold_cny", i, cfg)
    if g > 0 and weights.get("gold_cny", 0.0) < cfg["min_gold_when_active"]:
        need = cfg["min_gold_when_active"] - weights.get("gold_cny", 0.0)
        eq_sum = sum(weights[sym] for sym in EQUITIES)
        if eq_sum > 0:
            for sym in EQUITIES:
                weights[sym] *= max(0.0, 1 - need / eq_sum)
        weights["gold_cny"] = cfg["min_gold_when_active"]
    return weights


def simulate(dates: list[dt.date], prices: dict[str, list[float]], cache: dict[str, Any], cfg: dict[str, Any]) -> tuple[list[float], int, float]:
    cash = INITIAL
    units = {sym: 0.0 for sym in SYMS}
    values: list[float] = []
    trades = 0
    exposure_sum = 0.0
    last_rebalance = -10**9
    peak = INITIAL
    floor = INITIAL * (1 - cfg["floor_dd"])

    for i, _date in enumerate(dates):
        def pv() -> float:
            return cash + sum(units[sym] * prices[sym][i] for sym in SYMS)

        current_value = pv()
        peak = max(peak, current_value)
        if cfg["tipp"]:
            floor = max(floor, peak * (1 - cfg["floor_dd"]))
        cushion = max(0.0, (current_value - floor) / current_value) if current_value > 0 else 0.0

        if i > 0 and i - last_rebalance >= cfg["rebalance"]:
            sig = i - 1
            # Basket regime gate from the strategic risk basket.
            basket_idx = cfg["basket_idx"]
            basket = cache["basket"][(basket_idx, "values")]
            b_ma = cache["basket"][(basket_idx, "ma", cfg["basket_ma"])][sig]
            b_mom = cache["basket"][(basket_idx, "mom", cfg["basket_mom_lb"])][sig]
            b_vol = cache["basket"][(basket_idx, "vol", cfg["basket_vol_lb"])][sig]
            b_dd = cache["basket"][(basket_idx, "dd", cfg["basket_dd_lb"])][sig]
            regime_good = (
                b_ma is not None
                and b_mom is not None
                and basket[sig] > b_ma
                and b_mom > cfg["basket_mom_th"]
                and (b_vol is None or b_vol < cfg["basket_vol_cap"])
                and (b_dd is None or b_dd > -cfg["basket_dd_cap"])
            )
            raw_target = target_weights_from_signals(prices, cache, sig, cfg) if regime_good else {sym: 0.0 for sym in SYMS}
            if not regime_good:
                g = signal_strength(prices, cache, "gold_cny", sig, cfg)
                if g > 0:
                    raw_target["gold_cny"] = cfg["riskoff_gold"]

            # CPPI/TIPP exposure budget: risk exposure falls automatically near floor.
            cppi_exposure = min(cfg["max_exposure"], cfg["multiplier"] * cushion)
            if current_value < peak * (1 - cfg["panic_dd"]):
                cppi_exposure *= cfg["panic_scale"]
            if current_value > peak * (1 - cfg["recover_dd"]):
                cppi_exposure = min(cfg["max_exposure"], cppi_exposure * cfg["recover_boost"])

            # Vol target using conservative weighted vols.
            raw_sum = sum(raw_target.values())
            if raw_sum > 0:
                for sym in SYMS:
                    raw_target[sym] /= raw_sum
            port_vol = sum(raw_target[sym] * (cache["vol"][(sym, cfg["asset_vol_lb"])][sig] or 0.0) for sym in SYMS)
            vol_exposure = cfg["target_vol"] / port_vol if port_vol > 0 else 0.0
            final_exposure = min(cppi_exposure, vol_exposure, cfg["max_exposure"])
            target = {sym: raw_target[sym] * final_exposure for sym in SYMS}

            total = pv()
            # Sell first.
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
            # Buy second.
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


def score(full: dict[str, Any], sl: dict[str, Any]) -> float:
    ann = full["annualized"] or 0.0
    dd = full["max_drawdown"]
    sh = full["sharpe"] or 0.0
    p20 = sl["post_2020"] or {}
    y10 = sl["last_10y"] or {}
    p22 = sl["post_2022"] or {}
    return (
        ann * 1.7
        + (p20.get("annualized") or 0) * 0.25
        + (y10.get("annualized") or 0) * 0.20
        + (p22.get("annualized") or 0) * 0.12
        + sh * 0.18
        - dd * 1.5
        - max(dd - 0.10, 0) * 10
        - max((p20.get("max_drawdown") or 0) - 0.12, 0) * 3
        - max((y10.get("max_drawdown") or 0) - 0.12, 0) * 2
    )


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    if m is None:
        return None
    return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def simplify(c: dict[str, Any]) -> dict[str, Any]:
    return {
        "score": round(c["score"], 6),
        "trades": c["trades"],
        "exposure": round(c["exposure"], 4),
        "config": c["cfg"],
        "metrics": sm(c["metrics"]),
        "slices": {k: sm(v) for k, v in c["slices"].items()},
    }


def main() -> None:
    dates, prices, coverage = nb.load_aligned()
    basket_weights_list = [
        {"gold_cny": 0.60, "nasdaq": 0.30, "sp500": 0.10},
        {"gold_cny": 0.55, "nasdaq": 0.35, "sp500": 0.10},
        {"gold_cny": 0.50, "nasdaq": 0.40, "sp500": 0.10},
        {"gold_cny": 0.50, "nasdaq": 0.35, "sp500": 0.10, "csi300": 0.05},
        {"gold_cny": 0.45, "nasdaq": 0.45, "sp500": 0.10},
    ]
    print("COVERAGE", coverage["aligned"], flush=True)
    cache = build_cache(prices, basket_weights_list)
    candidates: list[dict[str, Any]] = []
    evaluated = 0

    for basket_idx, risk_weights in enumerate(basket_weights_list):
        for floor_dd in [0.08, 0.10, 0.12, 0.15]:
            for multiplier in [2.0, 3.0, 4.0, 5.0]:
                for max_exposure in [0.55, 0.65, 0.75, 0.85, 0.95]:
                    for target_vol in [0.10, 0.12, 0.14, 0.16, 0.18]:
                        for min_gold in [0.25, 0.35, 0.45]:
                            for riskoff_gold in [0.35, 0.55, 0.75]:
                                cfg = {
                                    "basket_idx": basket_idx,
                                    "risk_weights": risk_weights,
                                    "tipp": True,
                                    "floor_dd": floor_dd,
                                    "multiplier": multiplier,
                                    "max_exposure": max_exposure,
                                    "target_vol": target_vol,
                                    "basket_ma": 220,
                                    "basket_mom_lb": 120,
                                    "basket_mom_th": -0.02,
                                    "basket_vol_lb": 60,
                                    "basket_dd_lb": 60,
                                    "basket_vol_cap": 0.28,
                                    "basket_dd_cap": 0.14,
                                    "asset_ma": 180,
                                    "asset_mom_lb": 90,
                                    "asset_mom_th": -0.02,
                                    "asset_vol_lb": 60,
                                    "asset_dd_lb": 60,
                                    "gold_vol_cap": 0.38,
                                    "eq_vol_cap": 0.42,
                                    "gold_dd_cap": 0.18,
                                    "eq_dd_cap": 0.18,
                                    "fallback_vol": 0.18,
                                    "signal_clip": 3.0,
                                    "base_weight_power": 0.7,
                                    "signal_power": 0.8,
                                    "min_gold_when_active": min_gold,
                                    "riskoff_gold": riskoff_gold,
                                    "panic_dd": floor_dd * 0.75,
                                    "recover_dd": floor_dd * 0.30,
                                    "panic_scale": 0.35,
                                    "recover_boost": 1.10,
                                    "rebalance": 20,
                                    "band": 0.02,
                                }
                                values, trades, exposure = simulate(dates, prices, cache, cfg)
                                full = base.metrics(dates, values)
                                if not full:
                                    continue
                                sl = {
                                    "post_2020": base.slice_metrics(dates, values, dt.date(2020, 1, 1)),
                                    "last_10y": base.slice_metrics(dates, values, dates[-1].replace(year=dates[-1].year - 10)),
                                    "post_2022": base.slice_metrics(dates, values, dt.date(2022, 1, 1)),
                                }
                                candidates.append({"cfg": cfg, "metrics": full, "slices": sl, "trades": trades, "exposure": exposure, "score": score(full, sl)})
                                evaluated += 1
    print("EVALUATED", evaluated, "CANDIDATES", len(candidates), flush=True)
    candidates.sort(key=lambda c: (c["score"], c["metrics"]["annualized"] or 0), reverse=True)

    def dedupe(items: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        seen = set()
        for c in items:
            cfg = c["cfg"]
            key = (
                cfg["basket_idx"], cfg["floor_dd"], cfg["multiplier"], cfg["max_exposure"], cfg["target_vol"],
                cfg["min_gold_when_active"], cfg["riskoff_gold"]
            )
            if key in seen:
                continue
            seen.add(key)
            out.append(c)
            if len(out) >= limit:
                break
        return out

    under10 = sorted([c for c in candidates if c["metrics"]["max_drawdown"] <= 0.10], key=lambda c: c["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([c for c in candidates if c["metrics"]["max_drawdown"] <= 0.11], key=lambda c: c["metrics"]["annualized"] or 0, reverse=True)
    under12 = sorted([c for c in candidates if c["metrics"]["max_drawdown"] <= 0.12], key=lambda c: c["metrics"]["annualized"] or 0, reverse=True)
    robust = [
        c for c in candidates
        if c["metrics"]["max_drawdown"] <= 0.12
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
    out = Path("/tmp/atm_no_btc_cppi_tipp_2002_search.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2))
    print("WROTE", out, flush=True)
    for section in ["under10_by_return", "under11_by_return", "under12_by_return", "robust_top", "score_top"]:
        print("\n==", section, "==")
        for i, c in enumerate(serial[section][:10], 1):
            m = c["metrics"]
            print(i, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", None if m["sharpe"] is None else round(m["sharpe"], 2), "trades", c["trades"], "expo", c["exposure"], "cfg", c["config"])


if __name__ == "__main__":
    main()
