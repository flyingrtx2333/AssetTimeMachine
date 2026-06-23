#!/usr/bin/env python3
"""Verify the BTC satellite strategy family against comparable no-BTC baselines.

This is intentionally a clean verification wrapper around the existing tool
`tools/search_btc_satellite_strategies.py`, using one fixed, previously found
configuration rather than a parameter grid.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]

btc_spec = importlib.util.spec_from_file_location("btc", REPO / "tools/search_btc_satellite_strategies.py")
if btc_spec is None or btc_spec.loader is None:
    raise RuntimeError("cannot load btc strategy helper")
btc = importlib.util.module_from_spec(btc_spec)
btc_spec.loader.exec_module(btc)

risk_spec = importlib.util.spec_from_file_location("risk_engine", REPO / "spikes/001-risk-engine-strategy/risk_engine_strategy.py")
if risk_spec is None or risk_spec.loader is None:
    raise RuntimeError("cannot load risk engine helper")
risk = importlib.util.module_from_spec(risk_spec)
risk_spec.loader.exec_module(risk)

SATELLITE_CFG: dict[str, Any] = {
    "w_gold_cny": 0.55,
    "w_nasdaq": 0.30,
    "w_sp500": 0.10,
    "w_btc": 0.05,
    "ma_gold_cny": 220,
    "ma_nasdaq": 220,
    "ma_sp500": 220,
    "ma_btc": 120,
    "mom_gold_cny": 120,
    "mom_nasdaq": 120,
    "mom_sp500": 120,
    "mom_btc": 90,
    "mom_th_gold_cny": -0.02,
    "mom_th_nasdaq": -0.02,
    "mom_th_sp500": -0.02,
    "mom_th_btc": 0.04,
    "vol_lb": 60,
    "dd_lb": 60,
    "max_vol_gold_cny": 0.35,
    "max_vol_nasdaq": 0.35,
    "max_vol_sp500": 0.30,
    "max_vol_btc": 0.85,
    "max_dd_gold_cny": 0.15,
    "max_dd_nasdaq": 0.12,
    "max_dd_sp500": 0.10,
    "max_dd_btc": 0.20,
    "redeploy_gold": 0.75,
    "target_vol": 0.17,
    "max_exposure": 0.65,
    "rebalance": 20,
    "band": 0.02,
}

NO_BTC_SAME_FRAMEWORK = dict(SATELLITE_CFG, w_gold_cny=0.55, w_nasdaq=0.35, w_sp500=0.10, w_btc=0.0)


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    if m is None:
        return None
    return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def run_btc_family() -> dict[str, Any]:
    dates, prices, cov = btc.load()
    rows = []
    for name, cfg in [("btc_satellite", SATELLITE_CFG), ("no_btc_same_framework", NO_BTC_SAME_FRAMEWORK)]:
        vals, trades, exposure = btc.simulate(dates, prices, cfg)
        slices = btc.slices(dates, vals)
        rows.append({
            "name": name,
            "start": str(dates[0]),
            "end": str(dates[-1]),
            "trades": trades,
            "exposure": round(exposure, 6),
            "config": cfg,
            "slices": {k: sm(v) for k, v in slices.items()},
        })
    return {"coverage": cov, "rows": rows}


def run_current_vaa_same_window(start: dt.date) -> list[dict[str, Any]]:
    dates, prices, _ = risk.nb.load_aligned()
    c = risk.vaa.build_cache(prices)
    raw = risk.load_ohlc_sources()
    us = risk.normalized_cluster_ohlc(dates, raw, ["nasdaq", "sp500"])
    cn = risk.normalized_cluster_ohlc(dates, raw, ["csi300", "shanghai_composite"])
    for cl in [us, cn]:
        cl["ma60"] = risk.ma(cl["close"], 60)
        cl["ma120"] = risk.ma(cl["close"], 120)
        cl["ma200"] = risk.ma(cl["close"], 200)
    out = []
    for name in ["baseline", "vaa_ohlc_crisis_gate", "vaa_mania_safe_haven_crisis_gate"]:
        r = risk.simulate(name, dates, prices, c, us, cn, start)
        public_name = "current_vaa_same_window" if name == "baseline" else name
        out.append({
            "name": public_name,
            "start": r["start"],
            "end": r["end"],
            "trades": r["trades"],
            "exposure": round(r["exposure"], 6),
            "slices": {k: sm(v) for k, v in r["slices"].items()},
        })
    return out


def print_row(row: dict[str, Any]) -> None:
    f = row["slices"]["full"]
    p20 = row["slices"].get("post_2020")
    p22 = row["slices"].get("post_2022")
    print(
        f"{row['name']:34s} {row['start']}..{row['end']} "
        f"ann={f['annualized']*100:5.2f}% mdd={f['max_drawdown']*100:5.2f}% sharpe={(f['sharpe'] or 0):4.2f} "
        f"trades={row['trades']:4d} expo={row['exposure']*100:5.1f}%"
        + (f" | p20 {p20['annualized']*100:5.2f}/{p20['max_drawdown']*100:5.2f}" if p20 else "")
        + (f" p22 {p22['annualized']*100:5.2f}/{p22['max_drawdown']*100:5.2f}" if p22 else "")
    )


def main() -> None:
    btc_result = run_btc_family()
    btc_start = dt.date.fromisoformat(btc_result["rows"][0]["start"])
    vaa_rows = run_current_vaa_same_window(btc_start)
    result = {"btc_family": btc_result, "vaa_same_window": vaa_rows}
    out = Path("/tmp/atm_btc_satellite_verify.json")
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    print("BTC family:")
    for row in btc_result["rows"]:
        print_row(row)
    print("\nCurrent VAA same window:")
    for row in vaa_rows:
        print_row(row)
    print("WROTE", out)


if __name__ == "__main__":
    main()
