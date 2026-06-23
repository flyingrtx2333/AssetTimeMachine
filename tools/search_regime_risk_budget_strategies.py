#!/usr/bin/env python3
"""Search interpretable regime + risk-budget strategies for AssetTimeMachine.

This does NOT use existing named strategy templates. It uses real public history data,
previous-session signals, next-session execution, fees/slippage, and explicit cash defense.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
from typing import Any

spec = importlib.util.spec_from_file_location("base_search", "tools/search_basic_advanced_strategies.py")
if spec is None or spec.loader is None:
    raise RuntimeError("Cannot load base search module")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

INITIAL = 100_000.0
FEE = 0.001
SLIP = 0.0005
SYMS = ["gold_cny", "nasdaq", "sp500"]
EQUITIES = ["nasdaq", "sp500"]


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


def rolling_vol(values: list[float], i: int, n: int) -> float | None:
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
    return math.sqrt(var) * math.sqrt(252)


def rolling_drawdown(values: list[float], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    window = values[i - n + 1 : i + 1]
    peak = max(window)
    if peak <= 0:
        return None
    return values[i] / peak - 1


def portfolio_cov_vol(weights: dict[str, float], returns_by_symbol: dict[str, list[float]], i: int, n: int) -> float | None:
    if i - n + 1 < 1:
        return None
    # compute realized portfolio returns over the lookback using current candidate weights
    rets = []
    for j in range(i - n + 1, i + 1):
        r = 0.0
        ok = False
        for s, w in weights.items():
            if w == 0:
                continue
            arr = returns_by_symbol[s]
            r += w * arr[j]
            ok = True
        if ok:
            rets.append(r)
    if len(rets) < 2:
        return None
    mean = sum(rets) / len(rets)
    var = sum((x - mean) ** 2 for x in rets) / (len(rets) - 1)
    return math.sqrt(max(var, 0.0)) * math.sqrt(252)


def prepare() -> tuple[list[dt.date], dict[str, list[float]], dict[str, list[float]]]:
    raw = base.load_data()
    fx = base.make_fx_lookup(raw["usd_per_cny"])
    points = {s: base.normalize_asset(s, raw[s], fx) for s in SYMS}
    all_dates = sorted(set(d for pts in points.values() for d, _ in pts))
    idx = {s: 0 for s in SYMS}
    latest: dict[str, float] = {}
    latest_date: dict[str, dt.date] = {}
    dates: list[dt.date] = []
    prices = {s: [] for s in SYMS}
    for d in all_dates:
        ok = True
        for s in SYMS:
            pts = points[s]
            i = idx[s]
            while i < len(pts) and pts[i][0] <= d:
                latest[s] = pts[i][1]
                latest_date[s] = pts[i][0]
                i += 1
            idx[s] = i
            if s not in latest or (d - latest_date[s]).days > 7:
                ok = False
        if ok:
            dates.append(d)
            for s in SYMS:
                prices[s].append(latest[s])
    returns = {s: [0.0] * len(dates) for s in SYMS}
    for s in SYMS:
        for i in range(1, len(dates)):
            returns[s][i] = prices[s][i] / prices[s][i - 1] - 1 if prices[s][i - 1] > 0 else 0.0
    return dates, prices, returns


def normalized(weights: dict[str, float]) -> dict[str, float]:
    clean = {k: max(v, 0.0) for k, v in weights.items()}
    total = sum(clean.values())
    if total <= 1e-12:
        return {k: 0.0 for k in clean}
    return {k: v / total for k, v in clean.items()}


def target_weights(
    i: int,
    cfg: dict[str, Any],
    prices: dict[str, list[float]],
    returns: dict[str, list[float]],
    ma_cache: dict[tuple[str, int], list[float | None]],
    portfolio_values: list[float],
) -> dict[str, float]:
    # Called with signal index i. It must only inspect data <= i.
    eq_ok_count = 0
    eq_bad_count = 0
    eq_crash = False
    for s in EQUITIES:
        ma = ma_cache[(s, cfg["eq_ma"])][i]
        mom_fast = momentum(prices[s], i, cfg["eq_fast_mom"])
        mom_slow = momentum(prices[s], i, cfg["eq_slow_mom"])
        dd = rolling_drawdown(prices[s], i, cfg["eq_dd_lb"])
        vol = rolling_vol(prices[s], i, cfg["eq_vol_lb"])
        trend_ok = ma is not None and prices[s][i] > ma
        slow_ok = mom_slow is not None and mom_slow > cfg["eq_slow_th"]
        fast_bad = mom_fast is not None and mom_fast < -cfg["eq_fast_bad"]
        dd_bad = dd is not None and dd < -cfg["eq_dd_bad"]
        vol_bad = vol is not None and vol > cfg["eq_vol_bad"]
        if trend_ok and slow_ok:
            eq_ok_count += 1
        if fast_bad or dd_bad or vol_bad or not trend_ok:
            eq_bad_count += 1
        if fast_bad and dd_bad:
            eq_crash = True

    gold_ma = ma_cache[("gold_cny", cfg["gold_ma"])][i]
    gold_mom = momentum(prices["gold_cny"], i, cfg["gold_mom"])
    gold_ok = gold_ma is not None and prices["gold_cny"][i] > gold_ma and (gold_mom is None or gold_mom > cfg["gold_mom_th"])

    if eq_crash or eq_bad_count >= cfg["riskoff_bad_count"]:
        state = "risk_off"
    elif eq_ok_count >= cfg["riskon_ok_count"]:
        state = "risk_on"
    else:
        state = "neutral"

    if state == "risk_on":
        w = {"gold_cny": cfg["ro_gold"], "nasdaq": cfg["ro_nasdaq"], "sp500": cfg["ro_sp500"]}
    elif state == "neutral":
        w = {"gold_cny": cfg["nt_gold"], "nasdaq": cfg["nt_nasdaq"], "sp500": cfg["nt_sp500"]}
    else:
        if gold_ok:
            w = {"gold_cny": cfg["off_gold"], "nasdaq": cfg["off_nasdaq"], "sp500": cfg["off_sp500"]}
        else:
            w = {"gold_cny": cfg["off_gold_no_trend"], "nasdaq": 0.0, "sp500": 0.0}

    w = normalized(w)

    # Equity brake: cut equities, redeploy configurable part to gold if gold trend is okay.
    if eq_bad_count > 0:
        cut = 0.0
        for s in EQUITIES:
            old = w[s]
            w[s] *= cfg["eq_brake_scale"]
            cut += old - w[s]
        if gold_ok:
            w["gold_cny"] += cut * cfg["brake_redeploy_gold"]

    # Portfolio self-defense: if the strategy itself is off its high-water mark, de-risk.
    if len(portfolio_values) >= cfg["pf_dd_lb"]:
        recent = portfolio_values[-cfg["pf_dd_lb"] :]
        peak = max(recent)
        pf_dd = portfolio_values[-1] / peak - 1 if peak > 0 else 0.0
        if pf_dd < -cfg["pf_dd_hard"]:
            for s in EQUITIES:
                w[s] *= cfg["pf_hard_scale"]
            if gold_ok:
                w["gold_cny"] = min(w["gold_cny"] + cfg["pf_hard_gold_add"], 1.0)
        elif pf_dd < -cfg["pf_dd_soft"]:
            for s in EQUITIES:
                w[s] *= cfg["pf_soft_scale"]
            if gold_ok:
                w["gold_cny"] = min(w["gold_cny"] + cfg["pf_soft_gold_add"], 1.0)

    # Trend-gate gold too: if gold not healthy, unused weight becomes cash rather than forced exposure.
    if not gold_ok:
        w["gold_cny"] *= cfg["weak_gold_scale"]

    # Volatility target using covariance-aware realized portfolio return, not sum of individual vols.
    gross = sum(w.values())
    if gross > 0:
        pv = portfolio_cov_vol(w, returns, i, cfg["vol_target_lb"])
        scale = 1.0
        if pv and pv > 0:
            scale = min(scale, cfg["target_vol"] / pv)
        scale = min(scale, cfg["max_exposure"] / gross)
        for s in SYMS:
            w[s] *= scale

    return {s: max(min(w.get(s, 0.0), 1.0), 0.0) for s in SYMS}


def simulate(dates: list[dt.date], prices: dict[str, list[float]], returns: dict[str, list[float]], cfg: dict[str, Any]) -> tuple[list[float], int, float]:
    ma_periods = {
        ("gold_cny", cfg["gold_ma"]),
        ("nasdaq", cfg["eq_ma"]),
        ("sp500", cfg["eq_ma"]),
    }
    ma_cache = {(s, n): moving_average(prices[s], n) for s, n in ma_periods}
    cash = INITIAL
    units = {s: 0.0 for s in SYMS}
    values: list[float] = []
    trades = 0
    exposure_sum = 0.0
    last_rebalance = -10**9

    for idx, date in enumerate(dates):
        def value_at_current() -> float:
            return cash + sum(units[s] * prices[s][idx] for s in SYMS)

        if idx > 0 and idx - last_rebalance >= cfg["rebalance"]:
            signal_idx = idx - 1
            target = target_weights(signal_idx, cfg, prices, returns, ma_cache, values if values else [INITIAL])
            total = value_at_current()

            # Sell first.
            for s in SYMS:
                current = units[s] * prices[s][idx]
                desired = total * target[s]
                if current > desired * (1 + cfg["band"]):
                    amount = current - desired
                    sell_units = min(units[s], amount / prices[s][idx])
                    if sell_units > 1e-12:
                        gross = sell_units * prices[s][idx] * (1 - SLIP)
                        cash += gross * (1 - FEE)
                        units[s] -= sell_units
                        trades += 1

            total = value_at_current()
            # Then buy.
            for s in SYMS:
                current = units[s] * prices[s][idx]
                desired = total * target[s]
                if current < desired * (1 - cfg["band"]):
                    amount = min(cash, desired - current)
                    if amount > 1.0:
                        exec_price = prices[s][idx] * (1 + SLIP)
                        bought = amount * (1 - FEE) / exec_price if exec_price > 0 else 0.0
                        if bought > 1e-12:
                            units[s] += bought
                            cash -= amount
                            trades += 1
            last_rebalance = idx

        val = value_at_current()
        values.append(val)
        if val > 0:
            exposure_sum += sum(units[s] * prices[s][idx] for s in SYMS) / val
    return values, trades, exposure_sum / len(values)


def metric_slices(dates: list[dt.date], values: list[float]) -> dict[str, Any]:
    return {
        "full": base.metrics(dates, values),
        "post_2020": base.slice_metrics(dates, values, dt.date(2020, 1, 1)),
        "last_10y": base.slice_metrics(dates, values, dates[-1].replace(year=dates[-1].year - 10)),
        "post_2022": base.slice_metrics(dates, values, dt.date(2022, 1, 1)),
    }


def score(slices: dict[str, Any], trades: int) -> float:
    full = slices["full"]
    p20 = slices["post_2020"] or {}
    y10 = slices["last_10y"] or {}
    p22 = slices["post_2022"] or {}
    ann = full["annualized"] or 0.0
    dd = full["max_drawdown"]
    sharpe = full["sharpe"] or 0.0
    p20_ann = p20.get("annualized") or 0.0
    y10_ann = y10.get("annualized") or 0.0
    p22_ann = p22.get("annualized") or 0.0
    p20_dd = p20.get("max_drawdown") or 0.0
    y10_dd = y10.get("max_drawdown") or 0.0
    p22_dd = p22.get("max_drawdown") or 0.0
    return (
        ann * 1.50
        + p20_ann * 0.35
        + y10_ann * 0.25
        + p22_ann * 0.15
        + sharpe * 0.20
        - dd * 1.8
        - max(dd - 0.10, 0) * 8.0
        - max(p20_dd - 0.12, 0) * 3.0
        - max(y10_dd - 0.12, 0) * 2.0
        - max(p22_dd - 0.12, 0) * 1.5
        - (0.08 if trades < 20 else 0.0)
    )


def simplify(candidate: dict[str, Any]) -> dict[str, Any]:
    def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
        if m is None:
            return None
        return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}

    cfg = candidate["cfg"]
    keep = [
        "ro_gold", "ro_nasdaq", "ro_sp500", "nt_gold", "nt_nasdaq", "nt_sp500",
        "off_gold", "off_nasdaq", "off_sp500", "off_gold_no_trend", "eq_ma", "gold_ma",
        "rebalance", "target_vol", "max_exposure", "eq_dd_bad", "eq_vol_bad", "eq_brake_scale",
        "pf_dd_soft", "pf_dd_hard", "pf_soft_scale", "pf_hard_scale", "weak_gold_scale",
    ]
    return {
        "score": round(candidate["score"], 6),
        "trades": candidate["trades"],
        "exposure": round(candidate["exposure"], 4),
        "config": {k: cfg[k] for k in keep},
        "metrics": sm(candidate["slices"]["full"]),
        "slices": {k: sm(v) for k, v in candidate["slices"].items() if k != "full"},
    }


def main() -> None:
    dates, prices, returns = prepare()
    print("COVERAGE", len(dates), dates[0], dates[-1], flush=True)

    risk_on_weights = [
        (0.25, 0.60, 0.15),
        (0.30, 0.55, 0.15),
        (0.35, 0.50, 0.15),
        (0.35, 0.55, 0.10),
    ]
    neutral_weights = [
        (0.55, 0.25, 0.20),
        (0.60, 0.25, 0.15),
        (0.65, 0.20, 0.15),
    ]
    off_weights = [
        (0.75, 0.05, 0.05),
        (0.95, 0.00, 0.00),
    ]

    candidates: list[dict[str, Any]] = []
    evaluated = 0
    for ro in risk_on_weights:
        for nt in neutral_weights:
            for off in off_weights:
                for eq_ma in [200, 240]:
                    for gold_ma in [180, 220]:
                        for rebalance in [20]:
                            for target_vol in [0.14, 0.16, 0.18]:
                                for max_exposure in [0.95]:
                                    for pf_soft, pf_hard in [(0.04, 0.075), (0.06, 0.10)]:
                                        cfg = {
                                            "ro_gold": ro[0], "ro_nasdaq": ro[1], "ro_sp500": ro[2],
                                            "nt_gold": nt[0], "nt_nasdaq": nt[1], "nt_sp500": nt[2],
                                            "off_gold": off[0], "off_nasdaq": off[1], "off_sp500": off[2],
                                            "off_gold_no_trend": 0.15,
                                            "eq_ma": eq_ma,
                                            "gold_ma": gold_ma,
                                            "eq_fast_mom": 20,
                                            "eq_slow_mom": 90,
                                            "eq_slow_th": -0.02,
                                            "eq_fast_bad": 0.055,
                                            "eq_dd_lb": 60,
                                            "eq_dd_bad": 0.10,
                                            "eq_vol_lb": 30,
                                            "eq_vol_bad": 0.34,
                                            "riskoff_bad_count": 2,
                                            "riskon_ok_count": 1,
                                            "gold_mom": 60,
                                            "gold_mom_th": -0.02,
                                            "eq_brake_scale": 0.45,
                                            "brake_redeploy_gold": 0.80,
                                            "pf_dd_lb": 120,
                                            "pf_dd_soft": pf_soft,
                                            "pf_dd_hard": pf_hard,
                                            "pf_soft_scale": 0.55,
                                            "pf_hard_scale": 0.25,
                                            "pf_soft_gold_add": 0.10,
                                            "pf_hard_gold_add": 0.20,
                                            "weak_gold_scale": 0.35,
                                            "vol_target_lb": 60,
                                            "target_vol": target_vol,
                                            "max_exposure": max_exposure,
                                            "rebalance": rebalance,
                                            "band": 0.02,
                                        }
                                        values, trades, exposure = simulate(dates, prices, returns, cfg)
                                        slices = metric_slices(dates, values)
                                        full = slices["full"]
                                        if not full or not full["annualized"]:
                                            continue
                                        evaluated += 1
                                        ann = full["annualized"] or 0
                                        dd = full["max_drawdown"]
                                        candidates.append({
                                            "cfg": cfg,
                                            "slices": slices,
                                            "trades": trades,
                                            "exposure": exposure,
                                            "score": score(slices, trades),
                                        })
    print("EVALUATED", evaluated, "CANDIDATES", len(candidates), flush=True)

    candidates.sort(key=lambda c: (c["score"], c["slices"]["full"]["annualized"] or 0), reverse=True)

    def dedupe(items: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        seen = set()
        for c in items:
            cfg = c["cfg"]
            fam = (
                round(cfg["ro_gold"], 2), round(cfg["ro_nasdaq"], 2),
                round(cfg["nt_gold"], 2), round(cfg["nt_nasdaq"], 2),
                cfg["eq_ma"], cfg["gold_ma"], cfg["rebalance"], cfg["target_vol"],
                cfg["max_exposure"], cfg["pf_dd_soft"], cfg["pf_dd_hard"],
            )
            if fam in seen:
                continue
            seen.add(fam)
            out.append(c)
            if len(out) >= limit:
                break
        return out

    strict = sorted(
        [c for c in candidates if c["slices"]["full"]["max_drawdown"] <= 0.10],
        key=lambda c: c["slices"]["full"]["annualized"] or 0,
        reverse=True,
    )
    under12 = sorted(
        [c for c in candidates if c["slices"]["full"]["max_drawdown"] <= 0.12],
        key=lambda c: c["slices"]["full"]["annualized"] or 0,
        reverse=True,
    )
    robust = [
        c for c in candidates
        if c["slices"]["full"]["max_drawdown"] <= 0.125
        and (c["slices"]["post_2020"] or {}).get("max_drawdown", 1) <= 0.125
        and (c["slices"]["last_10y"] or {}).get("max_drawdown", 1) <= 0.125
    ]

    serial = {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "coverage": {"count": len(dates), "start": str(dates[0]), "end": str(dates[-1])},
        "evaluated": evaluated,
        "candidate_count": len(candidates),
        "score_top": [simplify(c) for c in dedupe(candidates, 30)],
        "under10_by_return": [simplify(c) for c in dedupe(strict, 20)],
        "under12_by_return": [simplify(c) for c in dedupe(under12, 20)],
        "robust_top": [simplify(c) for c in dedupe(robust, 20)],
    }
    output = Path("/tmp/atm_regime_risk_budget_search.json")
    output.write_text(json.dumps(serial, ensure_ascii=False, indent=2))
    print("WROTE", output, flush=True)
    for section in ["under10_by_return", "under12_by_return", "robust_top", "score_top"]:
        print("\n==", section, "==")
        for idx, c in enumerate(serial[section][:8], 1):
            m = c["metrics"]
            print(idx, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", None if m["sharpe"] is None else round(m["sharpe"], 2), "trades", c["trades"], "cfg", c["config"])


if __name__ == "__main__":
    main()
