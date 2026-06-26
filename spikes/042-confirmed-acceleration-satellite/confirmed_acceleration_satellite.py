#!/usr/bin/env python3
"""Confirmed acceleration satellite tests.

No leverage, no shorting, no BTC. This builds on the extra-equity satellite
idea, but changes the entry logic instead of only changing weights:

- require same-market confirmation before adding an extra equity asset;
- require positive short-term acceleration without volatility expansion;
- suppress China beta during bubble-rollover states;
- only use the current champion's idle cash.
"""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
S35_PATH = ROOT / "spikes" / "035-extra-equity-satellite" / "extra_equity_satellite.py"
SPEC35 = importlib.util.spec_from_file_location("extra_equity_satellite_base", S35_PATH)
if SPEC35 is None or SPEC35.loader is None:
    raise RuntimeError(f"failed to load {S35_PATH}")
s35 = importlib.util.module_from_spec(SPEC35)
sys.modules["extra_equity_satellite_base"] = s35
SPEC35.loader.exec_module(s35)

app = s35.app

US_MARKET = ["nasdaq", "sp500"]
CHINA_MARKET = ["shanghai_composite", "csi300", "shenzhen_component", "chinext"]
CHINA_EXTRA = {"shenzhen_component", "chinext"}


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    return s35.momentum(values, index, lookback)


def moving_average(values: list[float], index: int, period: int) -> float | None:
    return s35.moving_average(values, index, period)


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    return s35.annual_vol(values, index, lookback)


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    return s35.rolling_drawdown(values, index, lookback)


def total_weight(weights: dict[str, float]) -> float:
    return s35.total_weight(weights)


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return s35.normalize(weights, max_total)


def trend_confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, ma_period: int = 120) -> bool:
    values = prices_by_symbol.get(symbol)
    if not values:
        return False
    mom60 = momentum(values, index, 60)
    ma = moving_average(values, index, ma_period)
    return mom60 is not None and ma is not None and mom60 > 0 and values[index] > ma


def breadth_count(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int) -> int:
    return sum(1 for symbol in symbols if trend_confirmed(prices_by_symbol, symbol, index))


def china_bubble_rollover(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    broken = 0
    for symbol in CHINA_MARKET:
        values = prices_by_symbol.get(symbol)
        if not values:
            continue
        mom20 = momentum(values, index, 20)
        mom60 = momentum(values, index, 60)
        mom120 = momentum(values, index, 120)
        dd20 = rolling_drawdown(values, index, 20)
        dd60 = rolling_drawdown(values, index, 60)
        vol20 = annual_vol(values, index, 20)
        vol120 = annual_vol(values, index, 120)
        ma60 = moving_average(values, index, 60)
        if None in (mom20, mom60, mom120, dd20, dd60, vol20, vol120, ma60):
            continue
        assert mom20 is not None and mom60 is not None and mom120 is not None
        assert dd20 is not None and dd60 is not None and vol20 is not None and vol120 is not None and ma60 is not None
        hot = mom120 > 0.32 or mom60 > 0.22
        cracking = mom20 < -0.02 or dd20 < -0.045 or dd60 < -0.09 or values[index] < ma60
        vol_expanding = vol120 > 0 and vol20 > vol120 * 1.30
        if hot and (cracking or vol_expanding):
            broken += 1
    return broken >= 1


def cross_market_support(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, mode: str) -> bool:
    us_breadth = breadth_count(prices_by_symbol, US_MARKET, index)
    china_breadth = breadth_count(prices_by_symbol, CHINA_MARKET, index)
    if symbol == "dowjones":
        return us_breadth >= (2 if "strict" in mode else 1)
    if symbol in CHINA_EXTRA:
        if china_bubble_rollover(prices_by_symbol, index):
            return False
        if "us_leads" in mode and us_breadth < 2:
            return False
        return china_breadth >= (3 if "strict" in mode else 2)
    return False


def asset_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, mode: str) -> float | None:
    values = prices_by_symbol[symbol]
    mom20 = momentum(values, index, 20)
    mom60 = momentum(values, index, 60)
    mom120 = momentum(values, index, 120)
    mom240 = momentum(values, index, 240)
    ma60 = moving_average(values, index, 60)
    ma120 = moving_average(values, index, 120)
    vol20 = annual_vol(values, index, 20)
    vol60 = annual_vol(values, index, 60)
    vol120 = annual_vol(values, index, 120)
    dd20 = rolling_drawdown(values, index, 20)
    dd60 = rolling_drawdown(values, index, 60)
    dd120 = rolling_drawdown(values, index, 120)
    if None in (mom20, mom60, mom120, mom240, ma60, ma120, vol20, vol60, vol120, dd20, dd60, dd120):
        return None
    assert mom20 is not None and mom60 is not None and mom120 is not None and mom240 is not None
    assert ma60 is not None and ma120 is not None and vol20 is not None and vol60 is not None and vol120 is not None
    assert dd20 is not None and dd60 is not None and dd120 is not None

    if mom60 <= 0 or mom120 <= 0 or values[index] < ma120:
        return None
    if vol60 > 0.36 or dd60 < -0.10 or dd120 < -0.17:
        return None
    if "accel" in mode and (mom20 <= 0.004 or mom60 < max(0.015, mom120 * 0.20)):
        return None
    if "compression" in mode and not (vol20 < vol60 * 0.95 or vol20 < vol120 * 0.90):
        return None
    if "repair" in mode and not (values[index] > ma60 and dd20 > -0.035 and mom20 > -0.005):
        return None
    if "breakout" in mode and not (values[index] > ma60 and mom20 > 0.01 and mom60 > mom120 * 0.35):
        return None
    if symbol in CHINA_EXTRA and china_bubble_rollover(prices_by_symbol, index):
        return None

    compression_bonus = 0.10 if vol20 < vol60 else 0.0
    repair_bonus = 0.05 if dd20 > -0.015 else 0.0
    hot_penalty = 0.15 if (symbol in CHINA_EXTRA and mom120 > 0.38 and vol20 > vol60) else 0.0
    score = (mom120 + 0.60 * mom60 + 0.35 * mom20 + 0.15 * max(mom240, -0.20) + 0.20 * max(dd60, -0.30)) / max(vol60, 0.05)
    score += compression_bonus + repair_bonus - hot_penalty
    return score if score > 0 else None


def confirmed_scores(prices_by_symbol: dict[str, list[float]], index: int, mode: str) -> list[tuple[float, str]]:
    scored: list[tuple[float, str]] = []
    for symbol in s35.EXTRA_SYMBOLS:
        if not cross_market_support(prices_by_symbol, symbol, index, mode):
            continue
        score = asset_score(prices_by_symbol, symbol, index, mode)
        if score is not None:
            scored.append((score, symbol))
    scored.sort(reverse=True)
    return scored


def add_satellite(
    champion: dict[str, float],
    spec: Any,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
) -> dict[str, float]:
    if spec.cap <= 0:
        return champion
    signal_month = s35.current_signal_month(prices_by_symbol, signal_index)
    if "no_weak_months" in spec.mode and signal_month in {2, 6, 8, 9, 10}:
        return champion
    if "spring_autumn" in spec.mode and signal_month not in {1, 3, 4, 5, 7, 11, 12}:
        return champion
    if "risk_clean" in spec.mode and s35.equity_stress(prices_by_symbol, signal_index):
        return champion
    scored = confirmed_scores(prices_by_symbol, signal_index, spec.mode)
    if not scored:
        return champion
    selected = scored[: spec.top_count]
    score_total = sum(score for score, _symbol in selected)
    available = min(max(0.0, 1.0 - total_weight(champion)), spec.cap)
    if available <= 0 or score_total <= 0:
        return champion
    out = dict(champion)
    for score, symbol in selected:
        addition = min(spec.per_asset_cap, available * score / score_total)
        out[symbol] = out.get(symbol, 0.0) + addition
    return normalize(out)


def specs() -> list[Any]:
    out: list[Any] = [
        s35.SatelliteSpec("baseline_one_way", "Current one-way champion without extra satellite.", 0.0, 0.0, 0, "baseline"),
    ]
    modes = [
        "risk_clean_confirmed_accel",
        "risk_clean_confirmed_accel_no_weak_months",
        "risk_clean_confirmed_accel_spring_autumn",
        "risk_clean_confirmed_accel_compression",
        "risk_clean_confirmed_accel_compression_no_weak_months",
        "risk_clean_confirmed_repair",
        "risk_clean_confirmed_repair_no_weak_months",
        "risk_clean_confirmed_breakout",
        "risk_clean_us_leads_confirmed_accel",
        "risk_clean_us_leads_confirmed_accel_no_weak_months",
        "risk_clean_strict_confirmed_accel",
    ]
    allocation_grid = [
        (0.10, 0.08, 1),
        (0.10, 0.10, 2),
        (0.15, 0.08, 1),
        (0.15, 0.10, 2),
        (0.25, 0.10, 2),
    ]
    for mode in modes:
        for cap, per_asset_cap, top_count in allocation_grid:
            out.append(
                s35.SatelliteSpec(
                    f"{mode}_cap{int(cap*100)}_per{int(per_asset_cap*100)}_top{top_count}",
                    "Use idle cash only when extra equity has local confirmation, acceleration, and controlled volatility.",
                    cap,
                    per_asset_cap,
                    top_count,
                    mode,
                )
            )
    return out


def main() -> None:
    original_fetch = app.fetch_public_history
    original_add = s35.add_satellite
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.add_satellite = add_satellite  # type: ignore[assignment]
    try:
        env = s35.build_env()
        rows = [s35.row_for(spec, s35.run_satellite_strategy(spec, env)) for spec in specs()]
    finally:
        s35.add_satellite = original_add  # type: ignore[assignment]
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows[:40]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
