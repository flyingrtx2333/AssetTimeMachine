#!/usr/bin/env python3
"""Diagnose target weights around the 2015-2018 max drawdown window.

No BTC. Uses the 2001-present dynamic universe from no_btc_2001_dynamic_verify.py.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("dyn", HERE / "no_btc_2001_dynamic_verify.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load dynamic verifier")
dyn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dyn)

WATCH_START = dt.date(2015, 1, 1)
WATCH_END = dt.date(2018, 8, 31)


def fmtw(t: dict[str, float]) -> str:
    keep = [(k, v) for k, v in t.items() if v > 0.005]
    return " ".join(f"{k}:{v*100:.0f}%" for k, v in keep) or "cash"


def diagnose(strategy: str) -> None:
    dates, prices, _coverage = dyn.load_dynamic()
    mas = {}
    for s in dyn.SYMS:
        for n in [dyn.CFG["canary_ma"], dyn.CFG["asset_ma"], dyn.CFG["gold_ma"]]:
            mas[(s, n)] = dyn.ma(prices[s], n)
    vols = {(s, 60): [dyn.vol(prices[s], i, 60) for i in range(len(dates))] for s in dyn.SYMS}
    cn_idx = dyn.normalized_average_series(prices, ["csi300", "shanghai_composite"])
    cn_ma120 = dyn.ma(cn_idx, 120)
    cn_blocked = False

    print(f"\n== {strategy} ==")
    for i, d in enumerate(dates):
        if i == 0 or i % dyn.CFG["rebalance"] != 0:
            continue
        sig = i - 1
        target, meta = dyn.base_target(prices, mas, vols, sig)
        event = ""
        if strategy == "dynamic_shanghai_cap":
            cn_total = target["csi300"] + target["shanghai_composite"]
            if cn_total > 0.30:
                scale = 0.30 / cn_total
                for s in ["csi300", "shanghai_composite"]:
                    target[s] *= scale
                event = "cap_cn_30"
        elif strategy == "dynamic_us_gold_core":
            cn_total = target["csi300"] + target["shanghai_composite"]
            if cn_total > 0.15:
                scale = 0.15 / cn_total
                for s in ["csi300", "shanghai_composite"]:
                    target[s] *= scale
                event = "cap_cn_15"
        elif strategy == "dynamic_china_bubble_state":
            cn_r252 = dyn.series_ret(cn_idx, sig, 252)
            cn_r120 = dyn.series_ret(cn_idx, sig, 120)
            cn_dd20 = dyn.series_dd(cn_idx, sig, 20)
            cn_dd60 = dyn.series_dd(cn_idx, sig, 60)
            cn_close = cn_idx[sig]
            cn_m120 = cn_ma120[sig]
            trigger = (
                (cn_r252 is not None and cn_r252 > 0.65 and cn_dd20 is not None and cn_dd20 < -0.08)
                or (cn_r120 is not None and cn_r120 > 0.35 and cn_dd60 is not None and cn_dd60 < -0.16)
            )
            recovery = cn_blocked and cn_close is not None and cn_m120 is not None and cn_close > cn_m120 and cn_r120 is not None and cn_r120 > 0.04
            if trigger and not cn_blocked:
                cn_blocked = True
                event = "BLOCK_ON"
            elif recovery:
                cn_blocked = False
                event = "BLOCK_OFF"
            cn_total = target["csi300"] + target["shanghai_composite"]
            if cn_blocked and cn_total > 0:
                target["csi300"] = 0.0
                target["shanghai_composite"] = 0.0
                event += " cut_cn"
            elif not cn_blocked and cn_r252 is not None and cn_r252 > 0.80 and cn_total > 0.22:
                scale = 0.22 / cn_total
                for s in ["csi300", "shanghai_composite"]:
                    target[s] *= scale
                event = "blowoff_cap_22"
        if WATCH_START <= d <= WATCH_END:
            cn_total = target["csi300"] + target["shanghai_composite"]
            cn_r252 = dyn.series_ret(cn_idx, sig, 252)
            cn_dd60 = dyn.series_dd(cn_idx, sig, 60)
            print(
                f"{d} sig={dates[sig]} risk_on={meta['risk_on']} weak={meta['weak']} "
                f"cn={cn_total*100:4.1f}% cn252={(cn_r252 or 0)*100:6.1f}% cnDD60={(cn_dd60 or 0)*100:6.1f}% "
                f"{event:14s} {fmtw(target)}"
            )


for name in ["dynamic_vaa", "dynamic_shanghai_cap", "dynamic_us_gold_core", "dynamic_china_bubble_state"]:
    diagnose(name)
