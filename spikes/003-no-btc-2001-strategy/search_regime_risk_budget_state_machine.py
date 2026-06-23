#!/usr/bin/env python3
"""Throwaway bounded search: no-BTC 2001-present regime/risk-budget/state-machine family.

This is intentionally *not* another simple VAA grid. It reuses the current
expanded+bonds loader, then searches a small set of structural presets:
- explicit global regime state machine: risk_on / caution / crisis / recovery
- cluster risk budgets: US / China+HK / Japan / WTI, with dynamic join for CSI300/bonds
- independent China bubble and gold blowoff state machines
- optional state volatility budget + portfolio drawdown state transition

Main horizon remains 2001-06-25..present because gold determines the practical
common start. BTC is not requested or loaded.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("bd", HERE / "search_no_btc_2001_bond_defense.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load bond-defense loader")
bd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bd)

BASELINE_ANN = 0.0510
BASELINE_MDD = 0.1175

US = ["nasdaq", "sp500", "dowjones"]
CHINA_HK = ["shanghai_composite", "shenzhen_component", "csi300", "hang_seng"]
JAPAN = ["nikkei225"]
COMMODITY = ["wti"]
RISK_GROUPS = {
    "us": US,
    "china_hk": CHINA_HK,
    "japan": JAPAN,
    "commodity": COMMODITY,
}
RISK_CAP_GROUPS = {
    "us": US,
    "china_hk": CHINA_HK,
    "japan": JAPAN,
    "commodity": COMMODITY,
}
DEF_NO_GOLD = ["tlt", "ief", "shy", "usd_cash"]
DEF_WITH_GOLD = ["gold_cny", "tlt", "ief", "shy", "usd_cash"]


GROUP_PRESETS: list[dict[str, Any]] = [
    {
        "name": "us_core",
        "fracs": {"us": 0.55, "china_hk": 0.18, "japan": 0.17, "commodity": 0.10},
        "caps": {"us": 0.52, "china_hk": 0.24, "japan": 0.22, "commodity": 0.12},
        "rebudget_active_groups": True,
    },
    {
        "name": "balanced_global",
        "fracs": {"us": 0.42, "china_hk": 0.25, "japan": 0.18, "commodity": 0.15},
        "caps": {"us": 0.48, "china_hk": 0.30, "japan": 0.24, "commodity": 0.12},
        "rebudget_active_groups": True,
    },
    {
        "name": "anti_bubble_global",
        "fracs": {"us": 0.50, "china_hk": 0.12, "japan": 0.23, "commodity": 0.15},
        "caps": {"us": 0.52, "china_hk": 0.18, "japan": 0.26, "commodity": 0.12},
        "rebudget_active_groups": True,
    },
    {
        # Higher-return structural variant: still cluster-budgeted, but lets US/China winners carry more of risk-on regimes.
        "name": "us_china_momentum",
        "fracs": {"us": 0.55, "china_hk": 0.25, "japan": 0.10, "commodity": 0.10},
        "caps": {"us": 0.65, "china_hk": 0.35, "japan": 0.20, "commodity": 0.12},
        "rebudget_active_groups": True,
    },
]

BUDGET_PRESETS: list[dict[str, Any]] = [
    {
        "name": "return_tilt",
        "budgets": {
            "risk_on": {"risk": 0.70, "gold": 0.15, "def": 0.05},
            "caution": {"risk": 0.38, "gold": 0.24, "def": 0.08},
            "recovery": {"risk": 0.46, "gold": 0.18, "def": 0.10},
            "crisis": {"risk": 0.00, "gold": 0.12, "def": 0.50},
        },
        "max_exposure": 0.95,
        "gold_max": 0.42,
        "def_each_cap": 0.45,
    },
    {
        "name": "balanced_budget",
        "budgets": {
            "risk_on": {"risk": 0.60, "gold": 0.20, "def": 0.08},
            "caution": {"risk": 0.30, "gold": 0.24, "def": 0.14},
            "recovery": {"risk": 0.38, "gold": 0.20, "def": 0.14},
            "crisis": {"risk": 0.00, "gold": 0.08, "def": 0.55},
        },
        "max_exposure": 0.90,
        "gold_max": 0.40,
        "def_each_cap": 0.42,
    },
    {
        "name": "low_dd_budget",
        "budgets": {
            "risk_on": {"risk": 0.52, "gold": 0.18, "def": 0.10},
            "caution": {"risk": 0.20, "gold": 0.20, "def": 0.18},
            "recovery": {"risk": 0.30, "gold": 0.18, "def": 0.18},
            "crisis": {"risk": 0.00, "gold": 0.05, "def": 0.45},
        },
        "max_exposure": 0.82,
        "gold_max": 0.35,
        "def_each_cap": 0.36,
    },
    {
        "name": "risk_budget_return",
        "budgets": {
            "risk_on": {"risk": 0.75, "gold": 0.20, "def": 0.00},
            "caution": {"risk": 0.45, "gold": 0.35, "def": 0.00},
            "recovery": {"risk": 0.55, "gold": 0.25, "def": 0.00},
            "crisis": {"risk": 0.10, "gold": 0.20, "def": 0.25},
        },
        "max_exposure": 0.95,
        "gold_max": 0.60,
        "def_each_cap": 0.45,
    },
]

REGIME_PRESETS: list[dict[str, Any]] = [
    {
        "name": "fast_state",
        "risk_on_breadth": 0.34,
        "risk_on_ret60": -0.03,
        "crisis_breadth": 0.18,
        "crisis_dd60": 0.095,
        "crisis_ret60": -0.12,
        "pf_crisis_dd": 0.075,
        "crisis_hold": 65,
        "recovery_days": 80,
        "weak_allowed": 1,
        "shock_dd20": 9.0,
        "shock_ret20": -9.0,
    },
    {
        "name": "slow_state",
        "risk_on_breadth": 0.44,
        "risk_on_ret60": 0.00,
        "crisis_breadth": 0.25,
        "crisis_dd60": 0.115,
        "crisis_ret60": -0.15,
        "pf_crisis_dd": 0.085,
        "crisis_hold": 110,
        "recovery_days": 120,
        "weak_allowed": 1,
        "shock_dd20": 9.0,
        "shock_ret20": -9.0,
    },
    {
        # Loose global gate plus a short-horizon crash breaker; avoids staying defensive for half the sample.
        "name": "loose_shock_state",
        "risk_on_breadth": 0.25,
        "risk_on_ret60": -0.03,
        "crisis_breadth": 0.10,
        "crisis_dd60": 0.18,
        "crisis_ret60": -0.25,
        "pf_crisis_dd": 9.0,
        "crisis_hold": 30,
        "recovery_days": 40,
        "weak_allowed": 1,
        "shock_dd20": 0.10,
        "shock_ret20": -0.12,
    },
]

VOL_PRESETS: list[dict[str, Any]] = [
    {"name": "no_vol_target", "target_vols": None},
    {"name": "state_vol_10", "target_vols": {"risk_on": 0.105, "caution": 0.075, "recovery": 0.080, "crisis": 0.045}},
]

DEF_STYLES: list[dict[str, Any]] = [
    {"name": "ranked_def", "gold_first": False, "def_top_n": 2},
    {"name": "gold_then_ranked", "gold_first": True, "def_top_n": 2},
]

PF_PRESETS: list[dict[str, Any]] = [
    {"pf_name": "pf_off", "pf_brake_dd": 9.0, "pf_brake_scale": 1.0, "pf_brake_def_add": 0.0, "pf_crisis_override": None},
    {"pf_name": "pf_soft7", "pf_brake_dd": 0.07, "pf_brake_scale": 0.75, "pf_brake_def_add": 0.10, "pf_crisis_override": 9.0},
    {"pf_name": "pf_soft8", "pf_brake_dd": 0.08, "pf_brake_scale": 0.60, "pf_brake_def_add": 0.15, "pf_crisis_override": 9.0},
]


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def augment_cache(prices: dict[str, list[float | None]], c: dict[str, Any]) -> None:
    risk_idx = bd.exp.normalized_average(prices, bd.RISK)
    us_idx = bd.exp.normalized_average(prices, US)
    c["risk_idx"] = risk_idx
    c["risk_ma200"] = bd.ma(risk_idx, 200)
    c["risk_ret60"] = [bd.ret(risk_idx, i, 60) for i in range(len(risk_idx))]
    c["risk_dd60"] = [bd.dd(risk_idx, i, 60) for i in range(len(risk_idx))]
    c["us_idx"] = us_idx
    c["us_ret60"] = [bd.ret(us_idx, i, 60) for i in range(len(us_idx))]
    c["cn_ret120"] = [bd.ret(c["cn_idx"], i, 120) for i in range(len(c["cn_idx"]))]
    c["cn_ret60"] = [bd.ret(c["cn_idx"], i, 60) for i in range(len(c["cn_idx"]))]
    c["cn_ma200"] = bd.ma(c["cn_idx"], 200)


def base_asset_ok(prices: dict[str, list[float | None]], c: dict[str, Any], s: str, i: int, cfg: dict[str, Any], ma_n: int | None = None) -> bool:
    # Reuse existing local signal helpers; return False instead of raising on early optional-history gaps.
    try:
        return bd.asset_ok(prices, c, s, i, cfg, ma_n)
    except KeyError:
        return False


def asset_score(prices: dict[str, list[float | None]], c: dict[str, Any], s: str, i: int, cfg: dict[str, Any]) -> float:
    mm = bd.multi_mom(c, s, i, cfg["mom_lbs"], cfg["mom_weights"])
    vv = c["vol"][(s, 60)][i]
    r60 = c["ret"][(s, 60)][i]
    # Favor persistent momentum, but normalize by vol so high-vol WTI/China do not dominate blindly.
    return ((mm or 0.0) + 0.25 * (r60 or 0.0)) / max(vv or 0.14, 0.035)


def ranked_ok_assets(symbols: list[str], prices: dict[str, list[float | None]], c: dict[str, Any], i: int, cfg: dict[str, Any], *, is_def: bool, gold_blocked: bool) -> list[tuple[float, str]]:
    rows: list[tuple[float, str]] = []
    for s in symbols:
        if s == "gold_cny" and gold_blocked:
            continue
        ma_n = cfg["def_ma"] if is_def else cfg["asset_ma"]
        if base_asset_ok(prices, c, s, i, cfg, ma_n):
            rows.append((asset_score(prices, c, s, i, cfg), s))
    rows.sort(reverse=True)
    return rows


def add_capped(target: dict[str, float], sym: str, weight: float, cap: float) -> float:
    if weight <= 0:
        return 0.0
    cur = target.get(sym, 0.0)
    add = min(weight, max(cap - cur, 0.0))
    if add > 0:
        target[sym] = cur + add
    return add


def allocate_ranked(
    target: dict[str, float],
    ranked: list[tuple[float, str]],
    weight: float,
    c: dict[str, Any],
    i: int,
    *,
    top_n: int,
    each_cap: float,
) -> float:
    if weight <= 0 or not ranked:
        return 0.0
    selected = [s for _, s in ranked[:top_n]]
    inv = {s: 1.0 / max(c["vol"][(s, 60)][i] or 0.12, 0.035) for s in selected}
    sm_inv = sum(inv.values())
    used = 0.0
    if sm_inv <= 0:
        return 0.0
    for s in selected:
        used += add_capped(target, s, weight * inv[s] / sm_inv, each_cap)
    return used


def clamp_group(target: dict[str, float], group: list[str], cap: float) -> float:
    total = sum(target.get(s, 0.0) for s in group)
    if total <= cap or total <= 0:
        return 0.0
    scale = cap / total
    cut = 0.0
    for s in group:
        old = target.get(s, 0.0)
        target[s] = old * scale
        cut += old - target[s]
    return cut


def apply_state_vol_budget(target: dict[str, float], c: dict[str, Any], i: int, state: str, cfg: dict[str, Any]) -> float:
    tv = cfg.get("target_vols")
    if not tv:
        return 1.0
    target_vol = tv[state]
    # Conservative diagonal approximation; correlations ignored intentionally.
    approx_var = 0.0
    for s, w in target.items():
        if w <= 0:
            continue
        vv = c["vol"][(s, 60)][i]
        if vv is not None:
            approx_var += (w * vv) ** 2
    approx_vol = math.sqrt(approx_var)
    if approx_vol <= target_vol or approx_vol <= 0:
        return 1.0
    scale = target_vol / approx_vol
    # Scale risky assets first. Defense/gold are capped by their own state machines.
    for s in bd.RISK:
        target[s] = target.get(s, 0.0) * scale
    return scale


def canary_weak_count(prices: dict[str, list[float | None]], c: dict[str, Any], i: int, cfg: dict[str, Any]) -> int:
    weak = 0
    for s in cfg["canaries"]:
        p = prices[s][i]
        mm = bd.multi_mom(c, s, i, cfg["mom_lbs"], cfg["mom_weights"])
        m = c["ma"][(s, cfg["canary_ma"])][i]
        if p is None or mm is None or m is None or p < m or mm < 0:
            weak += 1
    return weak


def risk_breadth(prices: dict[str, list[float | None]], c: dict[str, Any], i: int, cfg: dict[str, Any]) -> float:
    avail = [s for s in bd.RISK if prices[s][i] is not None]
    if not avail:
        return 0.0
    ok = sum(1 for s in avail if base_asset_ok(prices, c, s, i, cfg, cfg["asset_ma"]))
    return ok / len(avail)


def gold_break_signal(c: dict[str, Any], i: int) -> bool:
    g_r252 = c["ret"][("gold_cny", 252)][i]
    g_r120 = c["ret"][("gold_cny", 120)][i]
    g_dd20 = c["dd"][("gold_cny", 20)][i]
    g_dd60 = c["dd"][("gold_cny", 60)][i]
    return bool(
        (g_r252 is not None and g_r252 > 0.22 and g_dd20 is not None and g_dd20 < -0.045)
        or (g_r120 is not None and g_r120 > 0.14 and g_dd60 is not None and g_dd60 < -0.09)
    )


def cn_break_signal(c: dict[str, Any], i: int) -> bool:
    cn_r252 = c["cn_ret252"][i]
    cn_dd20 = c["cn_dd20"][i]
    cn_dd60 = c["cn_dd60"][i]
    return bool(
        (cn_r252 is not None and cn_r252 > 0.50 and cn_dd20 is not None and cn_dd20 < -0.055)
        or (cn_r252 is not None and cn_r252 > 0.35 and cn_dd60 is not None and cn_dd60 < -0.12)
    )


def simulate(dates: list[dt.date], prices: dict[str, list[float | None]], c: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    cash = bd.exp.INITIAL
    units = {s: 0.0 for s in bd.SYMS}
    vals: list[float] = []
    trades = 0
    exposure = 0.0
    last_rebal = -10**9
    pf_peak = bd.exp.INITIAL

    state = "caution"
    state_until = -1
    state_counts: dict[str, int] = {"risk_on": 0, "caution": 0, "recovery": 0, "crisis": 0}
    transitions: dict[str, int] = {"risk_on": 0, "caution": 0, "recovery": 0, "crisis": 0}
    cn_blocked = False
    cn_until = -1
    gold_blocked = False
    gold_until = -1
    events = {"cn_block": 0, "gold_block": 0, "pf_crisis": 0, "vol_scales": 0}

    for i, d in enumerate(dates):
        def px(sym: str) -> float:
            p = prices[sym][i]
            if p is None:
                if abs(units[sym]) > 1e-12:
                    raise RuntimeError(f"missing price with position: {sym} {d}")
                return 0.0
            return p

        def pv() -> float:
            return cash + sum(units[s] * px(s) for s in bd.SYMS)

        current = pv()
        if current > pf_peak:
            pf_peak = current
        pf_dd = current / pf_peak - 1 if pf_peak > 0 else 0.0

        if i > 0 and i - last_rebal >= cfg["rebalance"]:
            sig = i - 1

            # China bubble state machine: block/repair is separate from global state.
            if cn_break_signal(c, sig):
                if not cn_blocked:
                    events["cn_block"] += 1
                cn_blocked = True
                cn_until = max(cn_until, sig + cfg["cn_cooldown"])
            elif cn_blocked and sig >= cn_until:
                cn_close = c["cn_idx"][sig]
                cn_ma200 = c["cn_ma200"][sig]
                cn_r120 = c["cn_ret120"][sig]
                cn_r60 = c["cn_ret60"][sig]
                if cn_close is not None and cn_ma200 is not None and cn_r120 is not None and cn_r60 is not None and cn_close > cn_ma200 and cn_r120 > 0.06 and cn_r60 > 0.02:
                    cn_blocked = False

            # Gold blowoff state machine: persistent cap until trend repairs.
            if gold_break_signal(c, sig):
                if not gold_blocked:
                    events["gold_block"] += 1
                gold_blocked = True
                gold_until = max(gold_until, sig + cfg["gold_cooldown"])
            elif gold_blocked and sig >= gold_until:
                g_p = prices["gold_cny"][sig]
                g_ma = c["ma"][("gold_cny", cfg["gold_ma"])][sig]
                g_r60 = c["ret"][("gold_cny", 60)][sig]
                if g_p is not None and g_ma is not None and g_r60 is not None and g_p > g_ma and g_r60 > 0.02:
                    gold_blocked = False

            breadth = risk_breadth(prices, c, sig, cfg)
            weak = canary_weak_count(prices, c, sig, cfg)
            risk_idx = c["risk_idx"][sig]
            risk_ma200 = c["risk_ma200"][sig]
            risk_ret60 = c["risk_ret60"][sig]
            risk_dd60 = c["risk_dd60"][sig]
            risk_on_signal = (
                breadth >= cfg["risk_on_breadth"]
                and weak <= cfg["weak_allowed"]
                and (risk_ret60 is None or risk_ret60 >= cfg["risk_on_ret60"])
            )
            global_crisis_signal = (
                (breadth <= cfg["crisis_breadth"] and weak >= max(2, cfg["weak_allowed"] + 1))
                or (risk_idx is not None and risk_ma200 is not None and risk_idx < risk_ma200 and risk_dd60 is not None and risk_dd60 < -cfg["crisis_dd60"])
                or (risk_ret60 is not None and risk_ret60 < cfg["crisis_ret60"] and weak >= 2)
            )
            pf_crisis = pf_dd < -cfg["pf_crisis_dd"]
            if pf_crisis:
                events["pf_crisis"] += 1

            old_state = state
            if state == "crisis":
                if sig >= state_until and risk_on_signal and not pf_crisis:
                    state = "recovery"
                    state_until = sig + cfg["recovery_days"]
                else:
                    state = "crisis"
            elif global_crisis_signal or pf_crisis:
                state = "crisis"
                state_until = sig + cfg["crisis_hold"]
            elif state == "recovery":
                if sig >= state_until and risk_on_signal:
                    state = "risk_on"
                elif not risk_on_signal:
                    state = "caution"
            elif risk_on_signal:
                state = "risk_on"
            else:
                state = "caution"
            if old_state != state:
                transitions[state] += 1

            target = {s: 0.0 for s in bd.SYMS}
            budget = cfg["budgets"][state]
            risk_budget = budget["risk"]
            gold_budget = budget["gold"]
            def_budget = budget["def"]

            # Portfolio brake inside non-crisis states: reduce risky budget before it escalates to crisis.
            if state != "crisis" and pf_dd < -cfg["pf_brake_dd"]:
                risk_budget *= cfg["pf_brake_scale"]
                def_budget += cfg["pf_brake_def_add"]

            # Cluster risk budget allocation. Groups only receive budget when their own trend is healthy.
            active: list[tuple[str, list[tuple[float, str]]]] = []
            for g, syms in RISK_GROUPS.items():
                if g == "china_hk" and cn_blocked:
                    continue
                ranked = ranked_ok_assets(syms, prices, c, sig, cfg, is_def=False, gold_blocked=False)
                if ranked:
                    active.append((g, ranked))
            denom = sum(cfg["group_fracs"][g] for g, _ in active) if cfg["rebudget_active_groups"] else 1.0
            for g, ranked in active:
                group_weight = risk_budget * cfg["group_fracs"][g] / max(denom, 1e-9)
                # China hot phase is separate from bubble break: harvest before full break.
                cap = cfg["group_caps"][g]
                if g == "china_hk":
                    cn_r252 = c["cn_ret252"][sig]
                    if cn_r252 is not None and cn_r252 > 0.55:
                        cap = min(cap, cfg["cn_hot_cap"])
                allocate_ranked(target, ranked, min(group_weight, cap), c, sig, top_n=cfg["risk_top_n"], each_cap=cap)
                clamp_group(target, RISK_CAP_GROUPS[g], cap)

            # Gold ballast / defensive sleeve. Gold first is useful in ordinary regimes, but the state machine caps it after blowoffs.
            gold_cap = cfg["gold_bad_cap"] if gold_blocked else cfg["gold_max"]
            if cfg["gold_first"] and gold_budget > 0 and not gold_blocked:
                g_ranked = ranked_ok_assets(["gold_cny"], prices, c, sig, cfg, is_def=True, gold_blocked=gold_blocked)
                if g_ranked:
                    used = allocate_ranked(target, g_ranked, gold_budget, c, sig, top_n=1, each_cap=gold_cap)
                    gold_budget -= used
            elif gold_budget > 0 and not gold_blocked:
                def_budget += gold_budget
                gold_budget = 0.0

            # Remaining defense budget ranks bonds / USD / optionally gold.
            def_symbols = DEF_NO_GOLD if gold_blocked else DEF_WITH_GOLD
            d_ranked = ranked_ok_assets(def_symbols, prices, c, sig, cfg, is_def=True, gold_blocked=gold_blocked)
            if def_budget > 0 and d_ranked:
                allocate_ranked(target, d_ranked, def_budget, c, sig, top_n=cfg["def_top_n"], each_cap=cfg["def_each_cap"])
            if gold_blocked and target.get("gold_cny", 0.0) > gold_cap:
                target["gold_cny"] = gold_cap

            # Final hard caps, state vol budget and max exposure.
            for g, cap in cfg["group_caps"].items():
                clamp_group(target, RISK_CAP_GROUPS[g], cap)
            if target.get("gold_cny", 0.0) > gold_cap:
                target["gold_cny"] = gold_cap
            vol_scale = apply_state_vol_budget(target, c, sig, state, cfg)
            if vol_scale < 0.999:
                events["vol_scales"] += 1
            gross = sum(target.values())
            if gross > cfg["max_exposure"] and gross > 0:
                scale = cfg["max_exposure"] / gross
                for s in target:
                    target[s] *= scale

            total = pv()
            for s in bd.SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur > tgt * (1 + cfg["band"]):
                    su = min(units[s], (cur - tgt) / px(s))
                    if su > 0:
                        cash += su * px(s) * (1 - bd.exp.SLIP) * (1 - bd.exp.FEE)
                        units[s] -= su
                        trades += 1
            total = pv()
            for s in bd.SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur < tgt * (1 - cfg["band"]):
                    amt = min(cash, tgt - cur)
                    if amt > 1:
                        units[s] += amt * (1 - bd.exp.FEE) / (px(s) * (1 + bd.exp.SLIP))
                        cash -= amt
                        trades += 1
            last_rebal = i

        v = pv()
        vals.append(v)
        exposure += sum(units[s] * px(s) for s in bd.SYMS) / v if v > 0 else 0.0
        state_counts[state] = state_counts.get(state, 0) + 1

    return {
        "values": vals,
        "trades": trades,
        "exposure": exposure / len(vals),
        "state_counts": state_counts,
        "transitions": transitions,
        "events": events,
    }


def score(m: dict[str, Any], slices: dict[str, Any]) -> float:
    ann = m["annualized"] or 0.0
    d = m["max_drawdown"]
    sh = m["sharpe"] or 0.0
    p20 = (slices["post_2020"]["annualized"] or 0.0) if slices["post_2020"] else 0.0
    y10 = (slices["last_10y"]["annualized"] or 0.0) if slices["last_10y"] else 0.0
    p22 = (slices["post_2022"]["annualized"] or 0.0) if slices["post_2022"] else 0.0
    # Prefer candidates near the current lead: don't let low-DD/low-return dominate.
    return (
        ann * 3.0
        + p20 * 0.15
        + y10 * 0.15
        + p22 * 0.10
        + sh * 0.25
        - d * 2.4
        - max(d - 0.10, 0.0) * 8.0
        - max(BASELINE_ANN - ann, 0.0) * 2.0
    )


def build_cfgs() -> list[dict[str, Any]]:
    cfgs: list[dict[str, Any]] = []
    for group in GROUP_PRESETS:
        for budget in BUDGET_PRESETS:
            for regime in REGIME_PRESETS:
                for volp in VOL_PRESETS:
                    for defs in DEF_STYLES:
                        for rebalance in [5, 10]:
                            cfg = {
                                "family": "regime_risk_budget_state_machine",
                                "group_preset": group["name"],
                                "budget_preset": budget["name"],
                                "regime_preset": regime["name"],
                                "vol_preset": volp["name"],
                                "def_style": defs["name"],
                                "rebalance": rebalance,
                                "mom_lbs": [60, 120, 240],
                                "mom_weights": [4, 2, 1],
                                "canaries": ["nasdaq", "sp500", "hang_seng"],
                                "canary_ma": 180,
                                "asset_ma": 180,
                                "def_ma": 120,
                                "gold_ma": 220,
                                "vol_cap": 0.45,
                                "dd_cap": 0.16,
                                "risk_top_n": 2,
                                "cn_hot_cap": 0.12,
                                "cn_cooldown": 420,
                                "gold_cooldown": 160,
                                "gold_bad_cap": 0.10,
                                "pf_brake_dd": 0.055,
                                "pf_brake_scale": 0.60,
                                "pf_brake_def_add": 0.08,
                                "band": 0.02,
                                "group_fracs": group["fracs"],
                                "group_caps": group["caps"],
                                "rebudget_active_groups": group["rebudget_active_groups"],
                                **budget,
                                **regime,
                                **volp,
                                **defs,
                            }
                            cfgs.append(cfg)
    return cfgs


def main() -> None:
    dates, prices, coverage = bd.load_with_bonds()
    c = bd.build_cache(prices)
    augment_cache(prices, c)
    cfgs = build_cfgs()
    results: list[dict[str, Any]] = []
    for cfg in cfgs:
        sim = simulate(dates, prices, c, cfg)
        vals = sim["values"]
        m = bd.exp.base.metrics(dates, vals)
        slices = {
            "post_2020": bd.exp.base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
            "last_10y": bd.exp.base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
            "post_2022": bd.exp.base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
        }
        results.append({
            "score": score(m, slices),
            "config": cfg,
            "metrics": m,
            "slices": slices,
            "trades": sim["trades"],
            "exposure": sim["exposure"],
            "state_counts": sim["state_counts"],
            "transitions": sim["transitions"],
            "events": sim["events"],
            "max_dd_episode": bd.exp.mdd_episode(dates, vals),
        })
    results.sort(key=lambda x: (x["score"], x["metrics"]["annualized"] or 0), reverse=True)
    by_return = sorted(results, key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under10 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.10], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.11], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    beats = sorted([
        x for x in results
        if (x["metrics"]["annualized"] or 0) >= BASELINE_ANN and x["metrics"]["max_drawdown"] <= BASELINE_MDD
    ], key=lambda x: ((x["metrics"]["annualized"] or 0) - x["metrics"]["max_drawdown"]), reverse=True)

    def simp(x: dict[str, Any]) -> dict[str, Any]:
        cfg = x["config"]
        keep_cfg = {
            k: cfg[k]
            for k in [
                "group_preset", "budget_preset", "regime_preset", "vol_preset", "def_style", "rebalance",
                "group_fracs", "group_caps", "budgets", "max_exposure", "gold_max", "def_each_cap",
                "risk_on_breadth", "crisis_breadth", "crisis_dd60", "pf_crisis_dd",
            ]
        }
        return {
            "score": round(x["score"], 6),
            "trades": x["trades"],
            "exposure": round(x["exposure"], 4),
            "metrics": sm(x["metrics"]),
            "slices": {k: sm(v) for k, v in x["slices"].items()},
            "max_dd_episode": x["max_dd_episode"],
            "state_counts": x["state_counts"],
            "transitions": x["transitions"],
            "events": x["events"],
            "config": keep_cfg,
        }

    serial = {
        "coverage": coverage,
        "baseline": {"annualized": BASELINE_ANN, "max_drawdown": BASELINE_MDD},
        "evaluated": len(results),
        "score_top": [simp(x) for x in results[:30]],
        "return_top": [simp(x) for x in by_return[:30]],
        "under10_by_return": [simp(x) for x in under10[:30]],
        "under11_by_return": [simp(x) for x in under11[:30]],
        "beats_baseline_ann_and_mdd": [simp(x) for x in beats[:30]],
    }
    out = Path("/tmp/atm_regime_risk_budget_search.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))

    print("COVERAGE", coverage["aligned_dynamic_with_bonds"])
    print("EVALUATED", len(results), "WROTE", out)
    print("BASELINE", f"ann>={BASELINE_ANN*100:.2f}%", f"mdd<={BASELINE_MDD*100:.2f}%", "BEATS", len(beats), "UNDER10", len(under10), "UNDER11", len(under11))
    for sec in ["beats_baseline_ann_and_mdd", "under10_by_return", "under11_by_return", "score_top", "return_top"]:
        print("\n==", sec, "==")
        for i, x in enumerate(serial[sec][:10], 1):
            m = x["metrics"]
            p20 = x["slices"]["post_2020"]
            y10 = x["slices"]["last_10y"]
            p22 = x["slices"]["post_2022"]
            print(
                i,
                "ann", f"{m['annualized']*100:.2f}%",
                "mdd", f"{m['max_drawdown']*100:.2f}%",
                "sharpe", round(m["sharpe"] or 0, 2),
                "p20", f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}",
                "y10", f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}",
                "p22", f"{p22['annualized']*100:.2f}/{p22['max_drawdown']*100:.2f}",
                "dd", x["max_dd_episode"],
                "cfg", {k: x["config"][k] for k in ["group_preset", "budget_preset", "regime_preset", "vol_preset", "def_style", "rebalance"]},
            )


if __name__ == "__main__":
    main()
