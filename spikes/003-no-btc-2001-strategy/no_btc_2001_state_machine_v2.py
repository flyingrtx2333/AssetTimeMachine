#!/usr/bin/env python3
"""Mechanism-level V2 experiments for no-BTC 2001-present strategy.

Focus: China equity state machine, not BTC and not broad parameter grids.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("dyn", HERE / "no_btc_2001_dynamic_verify.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load dynamic verifier")
dyn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dyn)

STRESS_START = dt.date(2015, 6, 12)
STRESS_END = dt.date(2018, 5, 3)


def slice_metrics(dates: list[dt.date], vals: list[float], start: dt.date, end: dt.date | None = None) -> dict[str, float] | None:
    idx = [i for i, d in enumerate(dates) if d >= start and (end is None or d <= end)]
    if len(idx) < 2:
        return None
    sd = [dates[i] for i in idx]
    sv = [vals[i] for i in idx]
    return dyn.base.metrics(sd, sv)


def mdd_episode(dates: list[dt.date], vals: list[float]) -> dict[str, Any]:
    peak_i = max_peak_i = trough_i = 0
    peak_v = vals[0]
    max_dd = 0.0
    for i, v in enumerate(vals):
        if v > peak_v:
            peak_v = v
            peak_i = i
        dd = v / peak_v - 1 if peak_v > 0 else 0.0
        if dd < max_dd:
            max_dd = dd
            max_peak_i = peak_i
            trough_i = i
    return {"peak": str(dates[max_peak_i]), "trough": str(dates[trough_i]), "depth": round(-max_dd, 6)}


def clamp_china(target: dict[str, float], cap: float) -> float:
    cn = target["csi300"] + target["shanghai_composite"]
    if cn <= cap or cn <= 0:
        return 0.0
    scale = cap / cn
    cut = 0.0
    for s in ["csi300", "shanghai_composite"]:
        old = target[s]
        target[s] *= scale
        cut += old - target[s]
    return cut


def zero_china(target: dict[str, float]) -> float:
    cut = target["csi300"] + target["shanghai_composite"]
    target["csi300"] = 0.0
    target["shanghai_composite"] = 0.0
    return cut


def add_us_from_cut(target: dict[str, float], cut: float, prices: dict[str, list[float | None]], mas: dict[tuple[str, int], list[float | None]], vols: dict[tuple[str, int], list[float | None]], sig: int, fraction: float) -> float:
    if cut <= 0 or fraction <= 0:
        return 0.0
    ranked: list[tuple[float, str]] = []
    for s in ["nasdaq", "sp500", "dowjones"]:
        px = prices[s][sig]
        mm = dyn.multi_mom(prices, s, sig)
        ma = mas[(s, dyn.CFG["asset_ma"])][sig]
        vv = vols[(s, 60)][sig]
        dd60 = dyn.series_dd(prices[s], sig, 60)
        if px is None or mm is None or ma is None:
            continue
        if px > ma and mm > 0 and (vv is None or vv < 0.34) and (dd60 is None or dd60 > -0.08):
            ranked.append((mm / max(vv or 0.18, 0.05), s))
    if not ranked:
        return 0.0
    ranked.sort(reverse=True)
    add = cut * fraction
    inv = {s: 1 / max(vols[(s, 60)][sig] or 0.18, 0.05) for _, s in ranked[:2]}
    sm = sum(inv.values())
    for s, invv in inv.items():
        target[s] += add * invv / sm
    return add


def simulate(name: str, variant: dict[str, Any], dates: list[dt.date], prices: dict[str, list[float | None]]) -> dict[str, Any]:
    mas: dict[tuple[str, int], list[float | None]] = {}
    for s in dyn.SYMS:
        for n in [dyn.CFG["canary_ma"], dyn.CFG["asset_ma"], dyn.CFG["gold_ma"], 120, 200, 252]:
            mas[(s, n)] = dyn.ma(prices[s], n)
    vols = {(s, 60): [dyn.vol(prices[s], i, 60) for i in range(len(dates))] for s in dyn.SYMS}
    cn_idx = dyn.normalized_average_series(prices, ["csi300", "shanghai_composite"])
    cn_ma120 = dyn.ma(cn_idx, 120)
    cn_ma200 = dyn.ma(cn_idx, 200)

    cash = dyn.INITIAL
    units = {s: 0.0 for s in dyn.SYMS}
    vals: list[float] = []
    trades = 0
    exposure = 0.0
    last = -10**9
    cn_blocked = False
    block_until = -1
    block_events = 0
    cap_events = 0
    repair_us_events = 0
    pf_peak = dyn.INITIAL

    for i, d in enumerate(dates):
        def px(sym: str) -> float:
            p = prices[sym][i]
            if p is None:
                if abs(units[sym]) > 1e-12:
                    raise RuntimeError(f"missing price with position: {sym} {d}")
                return 0.0
            return p

        def pv() -> float:
            return cash + sum(units[s] * px(s) for s in dyn.SYMS)

        curv = pv()
        if curv > pf_peak:
            pf_peak = curv

        if i > 0 and i - last >= dyn.CFG["rebalance"]:
            sig = i - 1
            target, _meta = dyn.base_target(prices, mas, vols, sig)
            cn_r252 = dyn.series_ret(cn_idx, sig, 252)
            cn_r120 = dyn.series_ret(cn_idx, sig, 120)
            cn_r60 = dyn.series_ret(cn_idx, sig, 60)
            cn_dd20 = dyn.series_dd(cn_idx, sig, 20)
            cn_dd60 = dyn.series_dd(cn_idx, sig, 60)
            cn_close = cn_idx[sig]
            ma120 = cn_ma120[sig]
            ma200 = cn_ma200[sig]
            us_mom_ok = False
            for s in ["nasdaq", "sp500", "dowjones"]:
                mm = dyn.multi_mom(prices, s, sig)
                p = prices[s][sig]
                m = mas[(s, dyn.CFG["asset_ma"])][sig]
                if mm is not None and p is not None and m is not None and mm > 0 and p > m:
                    us_mom_ok = True

            bubble_hot = cn_r252 is not None and cn_r252 > variant["hot_ret252"]
            bubble_break = (
                (cn_r252 is not None and cn_r252 > variant["break_ret252"] and cn_dd20 is not None and cn_dd20 < -variant["break_dd20"])
                or (cn_r120 is not None and cn_r120 > variant["break_ret120"] and cn_dd60 is not None and cn_dd60 < -variant["break_dd60"])
            )
            weak_repair = cn_r120 is not None and cn_r120 < variant["repair_mom120"]
            hard_trend_recovery = (
                cn_close is not None and ma200 is not None and ma120 is not None
                and cn_close > ma200 and cn_close > ma120
                and cn_r120 is not None and cn_r120 > variant["recover_ret120"]
                and cn_r60 is not None and cn_r60 > variant["recover_ret60"]
            )

            if bubble_break:
                if not cn_blocked:
                    block_events += 1
                cn_blocked = True
                block_until = max(block_until, sig + variant["cooldown_days"])
            elif cn_blocked and sig >= block_until and hard_trend_recovery:
                cn_blocked = False
            elif variant.get("block_weak_repair") and weak_repair and cn_dd60 is not None and cn_dd60 < -0.04:
                cn_blocked = True
                block_until = max(block_until, sig + variant["weak_repair_days"])

            cut = 0.0
            if cn_blocked:
                cut += zero_china(target)
            elif bubble_hot:
                cut += clamp_china(target, variant["hot_cap"])
                if cut > 0:
                    cap_events += 1
            else:
                cut += clamp_china(target, variant["normal_cap"])
                if cut > 0:
                    cap_events += 1

            # Repair return without BTC: only redeploy cut risk into strong US trend or healthy gold; otherwise cash.
            used_cut = 0.0
            if variant.get("us_repair") and us_mom_ok:
                used_cut += add_us_from_cut(target, cut, prices, mas, vols, sig, variant["us_repair_frac"])
                if used_cut > 0:
                    repair_us_events += 1
            if dyn.gold_ok(prices, mas, sig):
                target["gold_cny"] = min(target["gold_cny"] + (cut - used_cut) * variant["gold_redeploy_frac"], variant["gold_max"])

            # Portfolio drawdown brake: only activates after losses, not a permanent low-exposure cap.
            pf_dd = curv / pf_peak - 1 if pf_peak > 0 else 0.0
            if pf_dd < -variant["pf_brake_dd"]:
                for s in ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"]:
                    target[s] *= variant["pf_brake_scale"]
                if dyn.gold_ok(prices, mas, sig):
                    target["gold_cny"] = min(target["gold_cny"] + variant["pf_brake_gold_add"], variant["gold_max"])

            gross = sum(target.values())
            max_exp = variant["max_exposure"]
            if gross > max_exp and gross > 0:
                scale = max_exp / gross
                for s in target:
                    target[s] *= scale

            total = pv()
            for s in dyn.SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur > tgt * (1 + dyn.CFG["band"]):
                    su = min(units[s], (cur - tgt) / px(s))
                    if su > 0:
                        cash += su * px(s) * (1 - dyn.SLIP) * (1 - dyn.FEE)
                        units[s] -= su
                        trades += 1
            total = pv()
            for s in dyn.SYMS:
                if prices[s][i] is None:
                    continue
                cur = units[s] * px(s)
                tgt = total * target[s]
                if cur < tgt * (1 - dyn.CFG["band"]):
                    amt = min(cash, tgt - cur)
                    if amt > 1:
                        units[s] += amt * (1 - dyn.FEE) / (px(s) * (1 + dyn.SLIP))
                        cash -= amt
                        trades += 1
            last = i
        v = pv()
        vals.append(v)
        exposure += sum(units[s] * px(s) for s in dyn.SYMS) / v if v > 0 else 0.0

    slices = {
        "full": dyn.base.metrics(dates, vals),
        "post_2020": dyn.base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
        "last_10y": dyn.base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
        "post_2022": dyn.base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
        "stress_2015_2018": slice_metrics(dates, vals, STRESS_START, STRESS_END),
    }
    return {
        "name": name,
        "start": str(dates[0]),
        "end": str(dates[-1]),
        "trades": trades,
        "exposure": exposure / len(vals),
        "slices": slices,
        "max_dd_episode": mdd_episode(dates, vals),
        "events": {"block": block_events, "cap": cap_events, "us_repair": repair_us_events},
        "variant": variant,
    }


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    if m is None:
        return None
    return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def print_result(r: dict[str, Any]) -> None:
    f = r["slices"]["full"]
    p20 = r["slices"]["post_2020"]
    y10 = r["slices"]["last_10y"]
    p22 = r["slices"]["post_2022"]
    st = r["slices"]["stress_2015_2018"]
    print(
        f"{r['name']:28s} ann={f['annualized']*100:5.2f}% mdd={f['max_drawdown']*100:5.2f}% "
        f"sharpe={(f['sharpe'] or 0):4.2f} trades={r['trades']:4d} expo={r['exposure']*100:5.1f}% "
        f"| p20 {p20['annualized']*100:5.2f}/{p20['max_drawdown']*100:5.2f} "
        f"y10 {y10['annualized']*100:5.2f}/{y10['max_drawdown']*100:5.2f} "
        f"p22 {p22['annualized']*100:5.2f}/{p22['max_drawdown']*100:5.2f} "
        f"stress {st['annualized']*100:5.2f}/{st['max_drawdown']*100:5.2f} "
        f"events={r['events']} dd={r['max_dd_episode']}"
    )


VARIANTS: dict[str, dict[str, Any]] = {
    # Earlier bubble compression + long post-bubble cooldown. No permanent China underweight.
    "china_state_v2": {
        "normal_cap": 0.40,
        "hot_cap": 0.12,
        "hot_ret252": 0.60,
        "break_ret252": 0.55,
        "break_ret120": 0.28,
        "break_dd20": 0.055,
        "break_dd60": 0.12,
        "cooldown_days": 504,
        "recover_ret120": 0.08,
        "recover_ret60": 0.03,
        "repair_mom120": 0.02,
        "block_weak_repair": True,
        "weak_repair_days": 160,
        "gold_redeploy_frac": 0.75,
        "gold_max": 0.50,
        "us_repair": False,
        "us_repair_frac": 0.0,
        "pf_brake_dd": 0.08,
        "pf_brake_scale": 0.70,
        "pf_brake_gold_add": 0.05,
        "max_exposure": 0.95,
    },
    # Same state machine, but redeploy part of cut China risk into strong US trend to repair returns.
    "china_state_v2_us_repair": {
        "normal_cap": 0.40,
        "hot_cap": 0.12,
        "hot_ret252": 0.60,
        "break_ret252": 0.55,
        "break_ret120": 0.28,
        "break_dd20": 0.055,
        "break_dd60": 0.12,
        "cooldown_days": 504,
        "recover_ret120": 0.08,
        "recover_ret60": 0.03,
        "repair_mom120": 0.02,
        "block_weak_repair": True,
        "weak_repair_days": 160,
        "gold_redeploy_frac": 0.55,
        "gold_max": 0.48,
        "us_repair": True,
        "us_repair_frac": 0.40,
        "pf_brake_dd": 0.08,
        "pf_brake_scale": 0.70,
        "pf_brake_gold_add": 0.05,
        "max_exposure": 0.95,
    },
    # More conservative China normal cap, but not as harsh as permanent 15%.
    "china_state_v2_cn25": {
        "normal_cap": 0.25,
        "hot_cap": 0.10,
        "hot_ret252": 0.55,
        "break_ret252": 0.50,
        "break_ret120": 0.25,
        "break_dd20": 0.05,
        "break_dd60": 0.10,
        "cooldown_days": 504,
        "recover_ret120": 0.10,
        "recover_ret60": 0.04,
        "repair_mom120": 0.03,
        "block_weak_repair": True,
        "weak_repair_days": 220,
        "gold_redeploy_frac": 0.60,
        "gold_max": 0.48,
        "us_repair": True,
        "us_repair_frac": 0.45,
        "pf_brake_dd": 0.07,
        "pf_brake_scale": 0.65,
        "pf_brake_gold_add": 0.05,
        "max_exposure": 0.90,
    },
    # Allow full China in normal periods, but use hard portfolio brake to stop long drawdown spirals.
    "china_state_v2_pf_brake": {
        "normal_cap": 0.40,
        "hot_cap": 0.15,
        "hot_ret252": 0.60,
        "break_ret252": 0.55,
        "break_ret120": 0.28,
        "break_dd20": 0.055,
        "break_dd60": 0.12,
        "cooldown_days": 504,
        "recover_ret120": 0.08,
        "recover_ret60": 0.03,
        "repair_mom120": 0.02,
        "block_weak_repair": True,
        "weak_repair_days": 160,
        "gold_redeploy_frac": 0.55,
        "gold_max": 0.50,
        "us_repair": True,
        "us_repair_frac": 0.35,
        "pf_brake_dd": 0.055,
        "pf_brake_scale": 0.45,
        "pf_brake_gold_add": 0.10,
        "max_exposure": 0.95,
    },
}


def main() -> None:
    dates, prices, coverage = dyn.load_dynamic()
    results = [simulate(name, cfg, dates, prices) for name, cfg in VARIANTS.items()]
    print("COVERAGE", coverage)
    for r in results:
        print_result(r)
    out = Path("/tmp/atm_no_btc_2001_state_machine_v2.json")
    out.write_text(json.dumps({
        "coverage": coverage,
        "results": [
            {
                **r,
                "exposure": round(r["exposure"], 6),
                "slices": {k: sm(v) for k, v in r["slices"].items()},
            }
            for r in results
        ],
    }, ensure_ascii=False, indent=2, default=str))
    print("WROTE", out)


if __name__ == "__main__":
    main()
