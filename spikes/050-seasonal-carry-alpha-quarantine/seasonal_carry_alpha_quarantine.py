#!/usr/bin/env python3
"""Seasonal confidence + carry + guarded alpha target replay.

This spike starts from the verified 047 dynamic sleeve target replay, then adds
three logic layers that are intentionally different from simple weight tuning:

- monthly risk budget from either a fixed season tier or an adaptive same-month
  confidence score built only from prior 047 base returns;
- idle-budget carry using real Treasury total-return fund histories converted
  to CNY;
- guarded seasonal alpha that can use weak/month-specific assets only when trend
  confirmation passes, and suppresses China alpha during bubble rollover states.

No leverage, no shorting, no BTC. All candidates are replayed with target
weights, fees, slippage, cash interest, and max total target <= 100%.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SPIKE047 = ROOT / "spikes" / "047-dynamic-sleeve-selector"
SPIKE049 = ROOT / "spikes" / "049-seasonal-alpha-router"
sys.path.insert(0, str(SPIKE047))
sys.path.insert(0, str(SPIKE049))

import dynamic_sleeve_selector as dyn  # noqa: E402
import seasonal_alpha_router_search as alpha049  # noqa: E402
import seasonal_carry_search as carry049  # noqa: E402
import target_replay_search as t47  # noqa: E402
import target_weight_replay as replay  # noqa: E402

app = dyn.app
carry_assets = carry049.carry
s35 = replay.s35
s30 = replay.s30

CHINA_SYMBOLS = {"csi300", "shanghai_composite", "shenzhen_component", "chinext"}
US_SYMBOLS = {"nasdaq", "sp500", "dowjones"}

SELECTOR = dyn.SelectorSpec(
    name="target_hysteresis_selector_lb315_h95_l25_m125_d35",
    thesis="047 verified dynamic sleeve selector.",
    mode="hysteresis_selector",
    lookback=315,
    satellite_high=0.95,
    satellite_low=0.25,
    ret_margin=0.0125,
    dd_limit=0.035,
    portfolio_dd_limit=0.030,
)


@dataclass(frozen=True)
class CandidateSpec:
    name: str
    thesis: str
    seasonal_mode: str
    weak_scale: float
    mid_scale: float
    good_scale: float
    adaptive_lookback_years: int
    adaptive_good_score: float
    adaptive_mid_score: float
    weak_alpha: float
    mid_alpha: float
    good_alpha: float
    alpha_basket: str
    alpha_trend: str
    alpha_guard: str
    alpha_top_count: int
    alpha_per_asset_cap: float
    carry_mode: str
    carry_cap: float
    carry_per_asset_cap: float
    carry_month_scope: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return replay.normalize(weights, max_total)


def month_tier(month: int) -> str:
    if month in {2, 6, 9, 10}:
        return "weak"
    if month in {1, 3, 8}:
        return "mid"
    return "good"


def tier_scale(spec: CandidateSpec, tier: str) -> float:
    if tier == "weak":
        return spec.weak_scale
    if tier == "mid":
        return spec.mid_scale
    return spec.good_scale


def tier_alpha(spec: CandidateSpec, tier: str) -> float:
    if tier == "weak":
        return spec.weak_alpha
    if tier == "mid":
        return spec.mid_alpha
    return spec.good_alpha


def month_return_windows(dates: list[date], values: list[float]) -> dict[int, list[tuple[int, float]]]:
    by_month: dict[int, list[tuple[int, float]]] = {month: [] for month in range(1, 13)}
    if not dates or not values:
        return by_month

    start = 0
    while start < len(dates):
        month = dates[start].month
        year = dates[start].year
        end = start
        while end + 1 < len(dates) and dates[end + 1].month == month and dates[end + 1].year == year:
            end += 1
        if values[start] > 0 and values[end] > 0 and end > start:
            by_month[month].append((end, values[end] / values[start] - 1.0))
        start = end + 1
    return by_month


def adaptive_month_tier(
    spec: CandidateSpec,
    month_windows: dict[int, list[tuple[int, float]]],
    month: int,
    signal_index: int,
) -> str:
    rows = [(idx, ret) for idx, ret in month_windows.get(month, []) if idx < signal_index]
    if len(rows) < 4:
        return month_tier(month)
    rows = rows[-max(spec.adaptive_lookback_years, 1):]
    returns = [ret for _idx, ret in rows]
    mean = sum(returns) / len(returns)
    downside = [min(ret, 0.0) for ret in returns]
    downside_rms = math.sqrt(sum(item * item for item in downside) / len(downside)) if downside else 0.0
    hit_rate = sum(1 for ret in returns if ret > 0) / len(returns)
    score = mean / max(downside_rms, 0.008)
    if score >= spec.adaptive_good_score and hit_rate >= 0.56:
        return "good"
    if score >= spec.adaptive_mid_score and hit_rate >= 0.48:
        return "mid"
    return "weak"


def risk_tier(
    spec: CandidateSpec,
    month_windows: dict[int, list[tuple[int, float]]],
    month: int,
    signal_index: int,
) -> str:
    if spec.seasonal_mode == "fixed":
        return month_tier(month)
    if spec.seasonal_mode == "adaptive_same_month":
        return adaptive_month_tier(spec, month_windows, month, signal_index)
    raise ValueError(spec.seasonal_mode)


def china_bubble_rollover(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    broken = 0
    for symbol in CHINA_SYMBOLS:
        values = prices_by_symbol.get(symbol)
        if not values or index >= len(values):
            continue
        mom20 = alpha049.momentum(values, index, 20)
        mom60 = alpha049.momentum(values, index, 60)
        mom120 = alpha049.momentum(values, index, 120)
        dd20 = alpha049.drawdown(values, index, 20)
        dd60 = alpha049.drawdown(values, index, 60)
        vol20 = alpha049.annual_vol(values, index, 20)
        vol120 = alpha049.annual_vol(values, index, 120)
        ma60 = alpha049.moving_average(values, index, 60)
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


def trend_confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    values = prices_by_symbol.get(symbol)
    if not values or index >= len(values):
        return False
    mom60 = alpha049.momentum(values, index, 60)
    ma120 = alpha049.moving_average(values, index, 120)
    dd60 = alpha049.drawdown(values, index, 60)
    return (
        mom60 is not None
        and ma120 is not None
        and dd60 is not None
        and mom60 > 0
        and values[index] > ma120
        and dd60 > -0.10
    )


def breadth(prices_by_symbol: dict[str, list[float]], symbols: set[str], index: int) -> int:
    return sum(1 for symbol in symbols if trend_confirmed(prices_by_symbol, symbol, index))


def guarded_alpha_target(
    spec: CandidateSpec,
    prices_by_symbol: dict[str, list[float]],
    month: int,
    signal_index: int,
) -> dict[str, float]:
    router_spec = alpha049.RouterSpec(
        name="guarded_alpha",
        thesis="Guarded seasonal alpha sleeve.",
        basket_mode=spec.alpha_basket,
        transform_mode="overlay_idle",
        weak_base_scale=1.0,
        mid_base_scale=1.0,
        good_base_scale=1.0,
        weak_alpha=1.0,
        mid_alpha=1.0,
        trend_mode=spec.alpha_trend,
        top_count=spec.alpha_top_count,
        per_asset_cap=spec.alpha_per_asset_cap,
    )
    raw = alpha049.seasonal_alpha_target(router_spec, prices_by_symbol, month, signal_index)
    if not raw:
        return {}

    china_rollover = china_bubble_rollover(prices_by_symbol, signal_index)
    china_breadth = breadth(prices_by_symbol, CHINA_SYMBOLS, signal_index)
    us_breadth = breadth(prices_by_symbol, US_SYMBOLS, signal_index)

    out: dict[str, float] = {}
    for symbol, weight in raw.items():
        if symbol in CHINA_SYMBOLS:
            if china_rollover:
                continue
            if spec.alpha_guard in {"breadth", "strict"} and china_breadth < (3 if spec.alpha_guard == "strict" else 2):
                continue
        if symbol in US_SYMBOLS and spec.alpha_guard == "strict" and us_breadth < 2:
            continue
        out[symbol] = weight
    return normalize(out)


def overlay_alpha(base_target: dict[str, float], alpha_target: dict[str, float], alpha_weight: float) -> dict[str, float]:
    if not alpha_target or alpha_weight <= 0:
        return base_target
    available = min(alpha_weight, max(0.0, 1.0 - total_weight(base_target)))
    if available <= 0:
        return base_target
    out = dict(base_target)
    for symbol, weight in alpha_target.items():
        out[symbol] = out.get(symbol, 0.0) + available * weight
    return normalize(out)


def carry_spec_for(spec: CandidateSpec) -> carry049.CarryOverlaySpec:
    weak_mid_only = spec.carry_month_scope == "weak_mid"
    return carry049.CarryOverlaySpec(
        name="carry_overlay",
        thesis="Use idle budget for Treasury carry assets.",
        mode=spec.carry_mode,
        cap=spec.carry_cap,
        per_asset_cap=spec.carry_per_asset_cap,
        use_only_weak_mid_months=weak_mid_only,
    )


def rebalance_portfolio(
    *,
    index: int,
    dates: list[date],
    prices_by_symbol: dict[str, list[float]],
    tradable_symbols: list[str],
    targets: dict[str, float],
    cash_box: dict[str, float],
    units: dict[str, float],
    held: set[str],
    trades: list[app.Trade],
) -> dict[str, float]:
    return carry049.rebalance_portfolio(
        index=index,
        dates=dates,
        prices_by_symbol=prices_by_symbol,
        tradable_symbols=tradable_symbols,
        targets=targets,
        cash_box=cash_box,
        units=units,
        held=held,
        trades=trades,
    )


def simulate(data: dict[str, Any], spec: CandidateSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    core_prices = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    raw_public = data["raw_public"]
    fund_prices = carry_assets.align_extra_cny_series(dates, raw_public)
    prices_by_symbol = {**core_prices, **fund_prices}
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    base_values: list[float] = data["base_values"]
    month_windows: dict[int, list[tuple[int, float]]] = data["base_month_windows"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = sorted(set(data["tradable_symbols"] + carry_assets.FUND_SYMBOLS))

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    alpha_hits = 0
    carry_hits = 0
    max_target_sum = 0.0
    last_month: int | None = None
    raw_base_target: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    carry_spec = carry_spec_for(spec)

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def build_targets(current_index: int, signal_index: int) -> dict[str, float]:
        if signal_index < 0 or not raw_base_target:
            return {}
        tier = risk_tier(spec, month_windows, dates[current_index].month, signal_index)
        scale = tier_scale(spec, tier)
        base = normalize({symbol: weight * scale for symbol, weight in raw_base_target.items()})
        alpha_target = guarded_alpha_target(spec, prices_by_symbol, dates[current_index].month, signal_index)
        target = overlay_alpha(base, alpha_target, tier_alpha(spec, tier))
        target = carry049.add_carry(target, carry_spec, prices_by_symbol, dates[current_index].month, signal_index, points)
        return normalize(target)

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        signal_index = index - 1
        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = dyn.choose_weight(SELECTOR, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            raw_base_target = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if last_month is not None and current_date.month != last_month:
            needs_rebalance = True

        if needs_rebalance:
            targets = build_targets(index, signal_index)
            if any(symbol in targets for symbol in carry_assets.FUND_SYMBOLS):
                carry_hits += 1
            if signal_index >= 0 and guarded_alpha_target(spec, prices_by_symbol, current_date.month, signal_index):
                alpha_hits += 1
            if targets != active_targets:
                active_targets = rebalance_portfolio(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    tradable_symbols=tradable_symbols,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                )
                max_target_sum = max(max_target_sum, total_weight(active_targets))

        last_month = current_date.month
        points.append(portfolio_value(index))
        _ = base_values  # documents that adaptive tiers use the 047 base curve precomputed in data.

    return points, {
        "switches": switches,
        "alpha_hits": alpha_hits,
        "carry_hits": carry_hits,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }, trades


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if idx is None or idx >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[idx:], values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(dates: list[date], values: list[float]) -> dict[str, Any]:
    peak = values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {"peak_date": dates[worst_peak].isoformat(), "trough_date": dates[worst_trough].isoformat(), "max_drawdown": worst}


def row_for(data: dict[str, Any], spec: CandidateSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": spec.__dict__,
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
            "trades": len(trades),
        },
        "slices": {
            "post_2020": slice_metrics(dates, values, "2020-01-01"),
            "last_10y": slice_metrics(dates, values, "2016-06-23"),
            "post_2022": slice_metrics(dates, values, "2022-01-01"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def fixed_specs() -> list[CandidateSpec]:
    out: list[CandidateSpec] = []
    for weak_scale, mid_scale, good_scale in [
        (0.40, 0.60, 0.90),
        (0.40, 0.65, 1.00),
        (0.45, 0.65, 1.00),
        (0.50, 0.70, 1.00),
    ]:
        for weak_alpha, mid_alpha, good_alpha in [(0.00, 0.00, 0.00), (0.10, 0.10, 0.00), (0.20, 0.10, 0.00), (0.20, 0.20, 0.05)]:
            for alpha_guard in ["breadth", "strict"]:
                for carry_mode in ["short_only", "balanced_carry", "curve_or_month"]:
                    out.append(
                        CandidateSpec(
                            name=(
                                f"fixed_ws{int(weak_scale*100)}_ms{int(mid_scale*100)}_gs{int(good_scale*100)}"
                                f"_wa{int(weak_alpha*100)}_ma{int(mid_alpha*100)}_ga{int(good_alpha*100)}"
                                f"_{alpha_guard}_{carry_mode}"
                            ),
                            thesis=(
                                "Fixed seasonal risk tier with guarded weak-month alpha and Treasury carry for idle budget."
                            ),
                            seasonal_mode="fixed",
                            weak_scale=weak_scale,
                            mid_scale=mid_scale,
                            good_scale=good_scale,
                            adaptive_lookback_years=8,
                            adaptive_good_score=0.60,
                            adaptive_mid_score=0.15,
                            weak_alpha=weak_alpha,
                            mid_alpha=mid_alpha,
                            good_alpha=good_alpha,
                            alpha_basket="seasonal_gold_china_us",
                            alpha_trend="confirmed",
                            alpha_guard=alpha_guard,
                            alpha_top_count=1,
                            alpha_per_asset_cap=0.70,
                            carry_mode=carry_mode,
                            carry_cap=0.50,
                            carry_per_asset_cap=0.35,
                            carry_month_scope="all",
                        )
                    )
    return out


def adaptive_specs() -> list[CandidateSpec]:
    out: list[CandidateSpec] = []
    for lookback_years in [5, 8, 12]:
        for good_score, mid_score in [(0.45, 0.05), (0.60, 0.15), (0.80, 0.20)]:
            for weak_scale, mid_scale, good_scale in [(0.40, 0.65, 1.00), (0.45, 0.70, 1.00), (0.50, 0.75, 1.00)]:
                for weak_alpha, mid_alpha, good_alpha in [(0.10, 0.10, 0.00), (0.20, 0.10, 0.00), (0.20, 0.20, 0.05)]:
                    for alpha_guard in ["breadth", "strict"]:
                        out.append(
                            CandidateSpec(
                                name=(
                                    f"adaptive_y{lookback_years}_g{int(good_score*100)}_m{int(mid_score*100)}"
                                    f"_ws{int(weak_scale*100)}_ms{int(mid_scale*100)}_gs{int(good_scale*100)}"
                                    f"_wa{int(weak_alpha*100)}_ma{int(mid_alpha*100)}_ga{int(good_alpha*100)}_{alpha_guard}"
                                ),
                                thesis=(
                                    "Adaptive same-month confidence decides risk tier from prior base-strategy month returns; "
                                    "guarded seasonal alpha and Treasury carry fill idle budget."
                                ),
                                seasonal_mode="adaptive_same_month",
                                weak_scale=weak_scale,
                                mid_scale=mid_scale,
                                good_scale=good_scale,
                                adaptive_lookback_years=lookback_years,
                                adaptive_good_score=good_score,
                                adaptive_mid_score=mid_score,
                                weak_alpha=weak_alpha,
                                mid_alpha=mid_alpha,
                                good_alpha=good_alpha,
                                alpha_basket="seasonal_gold_china_us",
                                alpha_trend="confirmed",
                                alpha_guard=alpha_guard,
                                alpha_top_count=1,
                                alpha_per_asset_cap=0.70,
                                carry_mode="short_only",
                                carry_cap=0.50,
                                carry_per_asset_cap=0.35,
                                carry_month_scope="all",
                            )
                        )
    return out


def build_data() -> dict[str, Any]:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data["raw_public"] = cached_fetch(end_date=None)
        base_values, base_extra, base_trades = t47.simulate(data, SELECTOR)
        data["base_values"] = base_values
        data["base_extra"] = base_extra
        data["base_trades"] = base_trades
        data["base_month_windows"] = month_return_windows(data["dates"], base_values)
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
    return data


def main() -> None:
    data = build_data()
    rows: list[dict[str, Any]] = []
    for spec in fixed_specs() + adaptive_specs():
        values, extra, trades = simulate(data, spec)
        rows.append(row_for(data, spec, values, extra, trades))

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight seasonal confidence + guarded alpha + carry search. No leverage, no shorting, no BTC.",
                "base_047": {
                    "name": SELECTOR.name,
                    "extra": data["base_extra"],
                },
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:80]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{row['extra']} | {full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
