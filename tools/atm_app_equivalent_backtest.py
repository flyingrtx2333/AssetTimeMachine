#!/usr/bin/env python3
"""App-equivalent Python backtest engine for AssetTimeMachine.

This file is intentionally a fixed, repo-tracked counterpart of the Swift
`BacktestEngine.runAdvancedRotation` implementation in `ContentView.swift`.
Do not replace it with one-off `/tmp` research scripts for production metric
checks.  When Swift strategy logic changes, update this file and the regression
spec beside it in the same commit.

Currently implemented strategy scope:
- coreGoldSatelliteHeatCappedMomentum (热度上限元策略)

The implementation mirrors the Swift production path that matters for this
strategy:
- public history fetch + USD asset conversion with `usd_per_cny`
- union-date forward fill capped at 30 calendar days
- meta switch between `highZoneDecelerationMomentum` and
  `tailBreakdownLockMomentum`
- gold satellite overlay, weak-February brake, single-equity cap
- portfolio cash yield, fees, slippage, rebalance cadence, rebalance band
- Swift-compatible performance metrics
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
import argparse
import bisect
import json
import math
import sys
import urllib.request
from typing import Any, Literal

API_URL = "https://api.flyingrtx.com/api/v1/money/public/history"
SYMBOLS = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
EQUITY_SYMBOLS = ["nasdaq", "sp500", "csi300", "shanghai_composite"]
USD_FX_SYMBOL = "usd_per_cny"
SYMBOL_ALIASES = {"nasdaq_composite": "nasdaq"}
MAX_FORWARD_FILL_CALENDAR_DAYS = 30
TRADING_DAYS_PER_YEAR = 252.0


@dataclass(frozen=True)
class Trade:
    date: str
    action: Literal["buy", "sell"]
    symbol: str
    price: float
    cash_amount: float
    units: float


@dataclass(frozen=True)
class BacktestResult:
    strategy: str
    coverage_start: str
    coverage_end: str
    point_count: int
    annualized_return: float
    max_drawdown: float
    total_return: float
    annualized_volatility: float | None
    sharpe_ratio: float | None
    final_value: float
    trades: list[Trade]
    dates: list[date] = field(default_factory=list)
    values: list[float] = field(default_factory=list)


@dataclass(frozen=True)
class PortfolioDrawdownGuard:
    lookback_sessions: int
    drawdown_threshold: float
    scale: float


@dataclass(frozen=True)
class OverheatBrake:
    trigger_symbols: list[str]
    momentum_lookback_sessions: int
    momentum_threshold: float
    rsi_lookback_sessions: int
    rsi_threshold: float
    donchian_lookback_sessions: int
    donchian_position_threshold: float
    max_exposure: float
    redeploy_symbol: str | None
    redeploy_ratio: float


@dataclass(frozen=True)
class DecelerationLock:
    trigger_symbols: list[str]
    short_momentum_lookback_sessions: int
    short_momentum_upper_threshold: float
    rsi_lookback_sessions: int
    rsi_threshold: float
    donchian_lookback_sessions: int
    donchian_position_threshold: float
    max_exposure: float
    redeploy_symbol: str | None
    redeploy_ratio: float


@dataclass(frozen=True)
class ShortWeaknessLock:
    trigger_symbols: list[str]
    short_momentum_lookback_sessions: int
    short_momentum_threshold: float
    relative_symbol: str
    relative_lookback_sessions: int
    relative_momentum_threshold: float
    max_exposure: float
    redeploy_symbol: str | None
    redeploy_ratio: float


@dataclass(frozen=True)
class HeldBreakdownLock:
    trigger_symbols: list[str]
    drawdown_lookback_sessions: int
    drawdown_threshold: float
    short_momentum_lookback_sessions: int
    short_momentum_threshold: float
    medium_momentum_lookback_sessions: int
    medium_momentum_threshold: float
    relative_symbol: str
    relative_lookback_sessions: int
    relative_momentum_threshold: float
    donchian_lookback_sessions: int
    donchian_position_threshold: float
    required_signals: int
    max_exposure: float
    redeploy_symbol: str | None
    redeploy_ratio: float


@dataclass(frozen=True)
class MetaSwitch:
    default_mode: str
    defensive_mode: str
    loss_lookback_sessions: int
    loss_threshold: float
    volatility_lookback_sessions: int
    volatility_threshold: float
    drawdown_lookback_sessions: int
    loss_drawdown_threshold: float
    volatility_drawdown_threshold: float


@dataclass(frozen=True)
class OverlayPortfolioEquityBrake:
    lookback_sessions: int
    drawdown_threshold: float
    equity_symbols: list[str]
    equity_scale: float


@dataclass(frozen=True)
class SingleAssetExposureCap:
    symbols: list[str]
    max_weight: float


@dataclass(frozen=True)
class WeakMonthEquityBrake:
    months: list[int]
    equity_symbols: list[str]
    momentum_lookback_sessions: int
    momentum_threshold: float
    max_equity_exposure: float


@dataclass(frozen=True)
class GoldSatelliteOverlay:
    core_scale: float
    satellite_symbol: str
    satellite_weight: float
    max_total_exposure: float
    satellite_momentum_lookback_sessions: int
    satellite_momentum_threshold: float
    satellite_moving_average_period: int
    relative_symbol: str
    relative_lookback_sessions: int
    relative_momentum_threshold: float
    portfolio_equity_brake: OverlayPortfolioEquityBrake | None = None
    single_asset_exposure_cap: SingleAssetExposureCap | None = None
    weak_month_equity_brake: WeakMonthEquityBrake | None = None


@dataclass(frozen=True)
class Config:
    name: str
    lookback_sessions: int = 180
    rebalance_sessions: int = 60
    ma_filter_period: int = 1
    top_count: int = 1
    max_exposure: float = 0.75
    target_annual_volatility: float | None = 0.11
    volatility_lookback_sessions: int = 60
    weighting: Literal["winner"] = "winner"
    signal: Literal["guardedDualMomentum"] = "guardedDualMomentum"
    min_momentum_threshold: float = -0.02
    max_signal_annual_volatility: float | None = 0.18
    secondary_lookback_sessions: int | None = 60
    secondary_momentum_threshold: float | None = -0.04
    signal_drawdown_lookback_sessions: int | None = 60
    max_signal_drawdown: float | None = 0.15
    rsi_lookback_sessions: int | None = 14
    donchian_lookback_sessions: int | None = 240
    overheat_brake: OverheatBrake | None = None
    deceleration_lock: DecelerationLock | None = None
    short_weakness_lock: ShortWeaknessLock | None = None
    held_breakdown_lock: HeldBreakdownLock | None = None
    portfolio_drawdown_guard: PortfolioDrawdownGuard | None = None
    meta_switch: MetaSwitch | None = None
    gold_satellite_overlay: GoldSatelliteOverlay | None = None
    signal_only_symbols: set[str] = field(default_factory=set)
    rebalances_from_first_signal: bool = False
    rebalance_band: float = 0.0


@dataclass(frozen=True)
class PreparedSeries:
    symbol: str
    points: list[tuple[date, float]]


@dataclass(frozen=True)
class SimulatedTrace:
    values: list[float]
    weights_by_index: list[dict[str, float]]


def parse_date(text: str) -> date:
    return datetime.strptime(text, "%Y-%m-%d").date()


def clamp01(value: float) -> float:
    return min(max(value, 0.0), 1.0)


def fetch_public_history(end_date: date | None = None) -> dict[str, list[tuple[date, float]]]:
    query = "%2C".join(SYMBOLS + [USD_FX_SYMBOL])
    url = f"{API_URL}?symbols={query}&period=all"
    with urllib.request.urlopen(url, timeout=60) as response:
        payload = json.load(response)
    if not payload.get("success"):
        raise RuntimeError(f"history API failed: {payload!r}")

    series_by_symbol: dict[str, list[tuple[date, float]]] = {}
    for item in payload["series"]:
        raw_symbol = str(item["symbol"])
        symbol = SYMBOL_ALIASES.get(raw_symbol, raw_symbol)
        rows: list[tuple[date, float]] = []
        for date_text, price in zip(item["dates"], item["prices"]):
            row_date = parse_date(date_text)
            if end_date is not None and row_date > end_date:
                continue
            if isinstance(price, (int, float)) and math.isfinite(price) and price > 0:
                rows.append((row_date, float(price)))
        # Swift normalizedPricePoints sorts and deduplicates by Date.
        dedup: dict[date, float] = {d: p for d, p in rows}
        series_by_symbol[symbol] = sorted(dedup.items())
    return series_by_symbol


def price_on_or_before(points: list[tuple[date, float]], target: date) -> float | None:
    dates = [d for d, _ in points]
    idx = bisect.bisect_right(dates, target) - 1
    if idx < 0:
        return None
    return points[idx][1]


def prepare_series(raw: dict[str, list[tuple[date, float]]]) -> list[PreparedSeries]:
    fx = raw[USD_FX_SYMBOL]
    prepared: list[PreparedSeries] = []
    for symbol in SYMBOLS:
        points: list[tuple[date, float]] = []
        for d, price in raw[symbol]:
            if symbol in {"nasdaq", "sp500"}:
                fx_rate = price_on_or_before(fx, d)
                if not fx_rate or not math.isfinite(fx_rate) or fx_rate <= 0:
                    continue
                cny_price = price / fx_rate if fx_rate < 1 else price * fx_rate if fx_rate <= 20 else None
                if cny_price is None:
                    continue
                points.append((d, cny_price))
            else:
                points.append((d, price))
        if len(points) < 2:
            raise RuntimeError(f"insufficient data for {symbol}")
        prepared.append(PreparedSeries(symbol, points))
    return prepared


def align_rotation_price_series(prepared: list[PreparedSeries]) -> tuple[list[date], dict[str, list[float]]]:
    all_dates = sorted({d for series in prepared for d, _ in series.points})
    indices = {series.symbol: 0 for series in prepared}
    latest_prices: dict[str, float] = {}
    latest_dates: dict[str, date] = {}
    output_dates: list[date] = []
    prices_by_symbol: dict[str, list[float]] = {series.symbol: [] for series in prepared}

    for current_date in all_dates:
        for series in prepared:
            idx = indices[series.symbol]
            while idx < len(series.points) and series.points[idx][0] <= current_date:
                latest_dates[series.symbol], latest_prices[series.symbol] = series.points[idx]
                idx += 1
            indices[series.symbol] = idx

        valid = True
        for series in prepared:
            if series.symbol not in latest_prices or series.symbol not in latest_dates:
                valid = False
                break
            stale_days = (current_date - latest_dates[series.symbol]).days
            if stale_days > MAX_FORWARD_FILL_CALENDAR_DAYS:
                valid = False
                break
        if not valid:
            continue
        output_dates.append(current_date)
        for series in prepared:
            prices_by_symbol[series.symbol].append(latest_prices[series.symbol])
    return output_dates, prices_by_symbol


def moving_average(values: list[float], period: int) -> list[float | None]:
    if period <= 0 or not values:
        return [None] * len(values)
    result: list[float | None] = [None] * len(values)
    rolling_sum = 0.0
    for i, value in enumerate(values):
        rolling_sum += value
        if i >= period:
            rolling_sum -= values[i - period]
        if i >= period - 1:
            result[i] = rolling_sum / period
    return result


def rolling_annualized_volatility(values: list[float], period: int) -> list[float | None]:
    if period <= 1 or len(values) <= 1:
        return [None] * len(values)
    log_returns = [0.0] * len(values)
    for i in range(1, len(values)):
        prev, cur = values[i - 1], values[i]
        log_returns[i] = math.log(cur / prev) if prev > 0 and cur > 0 else 0.0
    result: list[float | None] = [None] * len(values)
    rolling_sum = 0.0
    rolling_sq = 0.0
    for i, value in enumerate(log_returns):
        rolling_sum += value
        rolling_sq += value * value
        if i >= period:
            old = log_returns[i - period]
            rolling_sum -= old
            rolling_sq -= old * old
        if i >= period:
            mean = rolling_sum / period
            variance = max((rolling_sq / period) - mean * mean, 0.0)
            result[i] = math.sqrt(variance) * math.sqrt(TRADING_DAYS_PER_YEAR)
    return result


def price_momentum(values: list[float], index: int, lookback: int) -> float | None:
    if lookback <= 0 or index < 0 or index >= len(values) or index - lookback < 0:
        return None
    previous = values[index - lookback]
    if previous <= 0:
        return None
    return values[index] / previous - 1


def rolling_drawdown_from_high(values: list[float], index: int, period: int) -> float | None:
    if period <= 0 or index < 0 or index >= len(values) or index - period + 1 < 0:
        return None
    window = values[index - period + 1 : index + 1]
    peak = max(window) if window else 0
    if peak <= 0:
        return None
    return values[index] / peak - 1


def relative_strength_index(values: list[float], index: int, period: int) -> float | None:
    if period <= 0 or index < period or len(values) <= period or index >= len(values):
        return None
    avg_gain = 0.0
    avg_loss = 0.0
    for cursor in range(1, period + 1):
        previous = values[cursor - 1]
        change = values[cursor] / previous - 1 if previous > 0 else 0.0
        avg_gain += max(change, 0.0)
        avg_loss += max(-change, 0.0)
    avg_gain /= period
    avg_loss /= period
    if index > period:
        for cursor in range(period + 1, index + 1):
            previous = values[cursor - 1]
            change = values[cursor] / previous - 1 if previous > 0 else 0.0
            gain = max(change, 0.0)
            loss = max(-change, 0.0)
            avg_gain = (avg_gain * (period - 1) + gain) / period
            avg_loss = (avg_loss * (period - 1) + loss) / period
    if avg_loss == 0:
        return 100.0
    relative_strength = avg_gain / avg_loss
    return 100.0 - 100.0 / (1.0 + relative_strength)


def donchian_range_position(values: list[float], index: int, period: int) -> float | None:
    if period <= 0 or index < 0 or index >= len(values) or index - period + 1 < 0:
        return None
    window = values[index - period + 1 : index + 1]
    high = max(window)
    low = min(window)
    return (values[index] - low) / max(high - low, 1e-12)


def cash_annual_rate(day: date) -> float:
    # Swift CashYieldCNY.ratePoints
    points = [
        (date(1990, 4, 15), 0.0288), (date(1990, 8, 21), 0.0216),
        (date(1991, 4, 21), 0.0180), (date(1993, 5, 15), 0.0216),
        (date(1993, 7, 11), 0.0315), (date(1996, 5, 1), 0.0297),
        (date(1996, 8, 23), 0.0198), (date(1997, 10, 23), 0.0171),
        (date(1998, 3, 25), 0.0171), (date(1998, 7, 1), 0.0144),
        (date(1998, 12, 7), 0.0144), (date(1999, 6, 10), 0.0099),
        (date(2002, 2, 21), 0.0072), (date(2004, 10, 29), 0.0072),
        (date(2006, 8, 19), 0.0072), (date(2007, 3, 18), 0.0072),
        (date(2007, 5, 19), 0.0072), (date(2007, 7, 21), 0.0081),
        (date(2007, 8, 22), 0.0081), (date(2007, 9, 15), 0.0081),
        (date(2007, 12, 21), 0.0072), (date(2008, 10, 9), 0.0072),
        (date(2008, 10, 30), 0.0072), (date(2008, 11, 27), 0.0036),
        (date(2008, 12, 23), 0.0036), (date(2010, 10, 20), 0.0036),
        (date(2010, 12, 26), 0.0036), (date(2011, 2, 9), 0.0040),
        (date(2011, 4, 6), 0.0050), (date(2011, 7, 7), 0.0050),
        (date(2012, 6, 8), 0.0040), (date(2012, 7, 6), 0.0035),
        (date(2015, 3, 1), 0.0035), (date(2015, 5, 11), 0.0035),
        (date(2015, 6, 28), 0.0035), (date(2015, 8, 26), 0.0035),
        (date(2015, 10, 24), 0.0035),
    ]
    rate = points[0][1]
    for d, value in points:
        if d <= day:
            rate = value
        else:
            break
    return rate


def cash_daily_return(day: date) -> float:
    return max(cash_annual_rate(day), 0.0) / TRADING_DAYS_PER_YEAR


def base_guarded_config(name: str, *, rebalance_sessions: int = 60, held_breakdown: bool = False) -> Config:
    common: dict[str, Any] = dict(
        name=name,
        lookback_sessions=180,
        rebalance_sessions=rebalance_sessions,
        ma_filter_period=1,
        top_count=1,
        max_exposure=0.75,
        target_annual_volatility=0.11,
        volatility_lookback_sessions=60,
        min_momentum_threshold=-0.02,
        max_signal_annual_volatility=0.18,
        secondary_lookback_sessions=60,
        secondary_momentum_threshold=-0.04,
        signal_drawdown_lookback_sessions=60,
        max_signal_drawdown=0.15,
        rsi_lookback_sessions=14,
        donchian_lookback_sessions=240,
        overheat_brake=OverheatBrake(
            trigger_symbols=["csi300", "shanghai_composite"],
            momentum_lookback_sessions=60,
            momentum_threshold=0.18,
            rsi_lookback_sessions=14,
            rsi_threshold=68,
            donchian_lookback_sessions=240,
            donchian_position_threshold=0.90,
            max_exposure=0.50,
            redeploy_symbol="gold_cny",
            redeploy_ratio=1.0,
        ),
        deceleration_lock=DecelerationLock(
            trigger_symbols=EQUITY_SYMBOLS,
            short_momentum_lookback_sessions=20,
            short_momentum_upper_threshold=0.06,
            rsi_lookback_sessions=14,
            rsi_threshold=65,
            donchian_lookback_sessions=240,
            donchian_position_threshold=0.90,
            max_exposure=0.30,
            redeploy_symbol="gold_cny",
            redeploy_ratio=0.75,
        ),
        short_weakness_lock=ShortWeaknessLock(
            trigger_symbols=EQUITY_SYMBOLS,
            short_momentum_lookback_sessions=20,
            short_momentum_threshold=-0.005,
            relative_symbol="gold_cny",
            relative_lookback_sessions=60,
            relative_momentum_threshold=-0.05,
            max_exposure=0.35,
            redeploy_symbol=None,
            redeploy_ratio=0.0,
        ),
        portfolio_drawdown_guard=PortfolioDrawdownGuard(240, 0.06, 0.18 if held_breakdown else 0.25),
    )
    if held_breakdown:
        common["held_breakdown_lock"] = HeldBreakdownLock(
            trigger_symbols=EQUITY_SYMBOLS,
            drawdown_lookback_sessions=40,
            drawdown_threshold=0.045,
            short_momentum_lookback_sessions=10,
            short_momentum_threshold=-0.01,
            medium_momentum_lookback_sessions=20,
            medium_momentum_threshold=0.01,
            relative_symbol="gold_cny",
            relative_lookback_sessions=60,
            relative_momentum_threshold=-0.04,
            donchian_lookback_sessions=240,
            donchian_position_threshold=0.55,
            required_signals=2,
            max_exposure=0.55,
            redeploy_symbol="gold_cny",
            redeploy_ratio=0.50,
        )
    return Config(**common)


def strategy_config(name: str) -> Config:
    if name == "highZoneDecelerationMomentum":
        return base_guarded_config(name)
    if name == "tailBreakdownLockMomentum":
        return base_guarded_config(name, held_breakdown=True)
    if name == "coreGoldSatelliteHeatCappedMomentum":
        return Config(
            name=name,
            max_exposure=0.85,
            meta_switch=MetaSwitch(
                default_mode="highZoneDecelerationMomentum",
                defensive_mode="tailBreakdownLockMomentum",
                loss_lookback_sessions=60,
                loss_threshold=0.035,
                volatility_lookback_sessions=20,
                volatility_threshold=0.13,
                drawdown_lookback_sessions=60,
                loss_drawdown_threshold=0.015,
                volatility_drawdown_threshold=0.025,
            ),
            gold_satellite_overlay=GoldSatelliteOverlay(
                core_scale=1.0,
                satellite_symbol="gold_cny",
                satellite_weight=0.10,
                max_total_exposure=0.85,
                satellite_momentum_lookback_sessions=90,
                satellite_momentum_threshold=0.0,
                satellite_moving_average_period=120,
                relative_symbol="sp500",
                relative_lookback_sessions=60,
                relative_momentum_threshold=0.0,
                portfolio_equity_brake=OverlayPortfolioEquityBrake(60, 0.065, EQUITY_SYMBOLS, 0.85),
                single_asset_exposure_cap=SingleAssetExposureCap(EQUITY_SYMBOLS, 0.64),
                weak_month_equity_brake=WeakMonthEquityBrake([2], EQUITY_SYMBOLS, 60, -0.02, 0.35),
            ),
        )
    raise ValueError(f"unsupported strategy: {name}")


def indicator_maps(prices_by_symbol: dict[str, list[float]], config: Config) -> tuple[dict[str, list[float | None]], dict[str, list[float | None]]]:
    ma_by_symbol: dict[str, list[float | None]] = {}
    vol_by_symbol: dict[str, list[float | None]] = {}
    for symbol, prices in prices_by_symbol.items():
        ma_by_symbol[symbol] = moving_average(prices, config.ma_filter_period)
        vol_by_symbol[symbol] = rolling_annualized_volatility(prices, config.volatility_lookback_sessions)
    return ma_by_symbol, vol_by_symbol


def advanced_rotation_target_weights(
    symbols: list[str],
    prices_by_symbol: dict[str, list[float]],
    ma_by_symbol: dict[str, list[float | None]],
    vol_by_symbol: dict[str, list[float | None]],
    signal_index: int,
    signal_date: date,
    config: Config,
) -> dict[str, float]:
    if signal_index - config.lookback_sessions < 0:
        return {}

    ranked: list[tuple[float, float, str]] = []
    for symbol in symbols:
        prices = prices_by_symbol[symbol]
        if not (0 <= signal_index < len(prices)):
            continue
        previous_price = prices[signal_index - config.lookback_sessions]
        if previous_price <= 0:
            continue
        momentum = prices[signal_index] / previous_price - 1
        secondary = price_momentum(prices, signal_index, config.secondary_lookback_sessions or 0)
        annual_vol = vol_by_symbol[symbol][signal_index]
        drawdown = rolling_drawdown_from_high(prices, signal_index, config.signal_drawdown_lookback_sessions or 0)
        if secondary is None or annual_vol is None or drawdown is None:
            continue
        if momentum <= config.min_momentum_threshold:
            continue
        if secondary <= (config.secondary_momentum_threshold if config.secondary_momentum_threshold is not None else config.min_momentum_threshold):
            continue
        if config.max_signal_annual_volatility is not None and annual_vol > config.max_signal_annual_volatility:
            continue
        if config.max_signal_drawdown is not None and drawdown < -max(config.max_signal_drawdown, 0.0):
            continue
        rsi = relative_strength_index(prices, signal_index, config.rsi_lookback_sessions or 0)
        donchian = donchian_range_position(prices, signal_index, config.donchian_lookback_sessions or 0)
        score = momentum * 1.2 + secondary * 0.5 + max(drawdown, -0.5) * 0.4 + (1.0 / max(annual_vol, 0.01)) * 0.015
        if rsi is not None:
            score += (1 - abs(rsi - 62) / 62) * 0.05
        if donchian is not None:
            score += donchian * 0.08
        if symbol == "gold_cny":
            score += 0.03
        ranked.append((score, momentum, symbol))

    ranked.sort(key=lambda x: (-x[0], x[2]))
    picks = ranked[: max(config.top_count, 1)]
    if not picks:
        return {}
    base_weights = {picks[0][2]: 1.0}
    exposure = min(max(config.max_exposure, 0.0), 1.0)
    if config.target_annual_volatility is not None:
        weighted_vol = sum(weight * max(vol_by_symbol[sym][signal_index] or 9.0, 0.01) for sym, weight in base_weights.items())
        exposure = min(exposure, config.target_annual_volatility / max(weighted_vol, 0.01))
    final = {sym: weight * exposure for sym, weight in base_weights.items()}

    def can_redeploy(to_symbol: str) -> bool:
        prices = prices_by_symbol[to_symbol]
        ma = moving_average(prices, 60)[signal_index]
        mom = price_momentum(prices, signal_index, 60)
        return ma is not None and mom is not None and prices[signal_index] >= ma and mom > -0.02

    def cap_total_exposure(max_exposure: float, redeploy_symbol: str | None, redeploy_ratio: float) -> None:
        nonlocal final
        current_exposure = sum(max(v, 0.0) for v in final.values())
        normalized_max = clamp01(max_exposure)
        if current_exposure <= normalized_max or current_exposure <= 0:
            return
        scale = normalized_max / current_exposure
        removed = 0.0
        for sym, original in list(final.items()):
            original = max(original, 0.0)
            scaled = original * scale
            final[sym] = scaled
            removed += original - scaled
        if redeploy_symbol and can_redeploy(redeploy_symbol):
            final[redeploy_symbol] = final.get(redeploy_symbol, 0.0) + removed * clamp01(redeploy_ratio)

    if config.overheat_brake:
        brake = config.overheat_brake
        is_overheated = False
        for sym in brake.trigger_symbols:
            if final.get(sym, 0.0) <= 0:
                continue
            prices = prices_by_symbol[sym]
            heat = price_momentum(prices, signal_index, brake.momentum_lookback_sessions)
            rsi = relative_strength_index(prices, signal_index, brake.rsi_lookback_sessions)
            don = donchian_range_position(prices, signal_index, brake.donchian_lookback_sessions)
            if heat is not None and rsi is not None and don is not None and heat > brake.momentum_threshold and rsi > brake.rsi_threshold and don > brake.donchian_position_threshold:
                is_overheated = True
                break
        if is_overheated:
            cap_total_exposure(brake.max_exposure, brake.redeploy_symbol, brake.redeploy_ratio)

    did_use_deceleration = False
    if config.deceleration_lock:
        lock = config.deceleration_lock
        triggered = False
        for sym in lock.trigger_symbols:
            if final.get(sym, 0.0) <= 0:
                continue
            prices = prices_by_symbol[sym]
            short = price_momentum(prices, signal_index, lock.short_momentum_lookback_sessions)
            rsi = relative_strength_index(prices, signal_index, lock.rsi_lookback_sessions)
            don = donchian_range_position(prices, signal_index, lock.donchian_lookback_sessions)
            if short is not None and rsi is not None and don is not None and don > lock.donchian_position_threshold and rsi > lock.rsi_threshold and short < lock.short_momentum_upper_threshold:
                triggered = True
                break
        if triggered:
            did_use_deceleration = True
            cap_total_exposure(lock.max_exposure, lock.redeploy_symbol, lock.redeploy_ratio)

    if not did_use_deceleration and config.short_weakness_lock:
        lock = config.short_weakness_lock
        triggered = False
        for sym in lock.trigger_symbols:
            if final.get(sym, 0.0) <= 0:
                continue
            prices = prices_by_symbol[sym]
            rel = prices_by_symbol[lock.relative_symbol]
            if signal_index - lock.relative_lookback_sessions < 0:
                continue
            short = price_momentum(prices, signal_index, lock.short_momentum_lookback_sessions)
            prev_asset, cur_asset = prices[signal_index - lock.relative_lookback_sessions], prices[signal_index]
            prev_rel, cur_rel = rel[signal_index - lock.relative_lookback_sessions], rel[signal_index]
            if short is None or min(prev_asset, cur_asset, prev_rel, cur_rel) <= 0:
                continue
            relative_momentum = (cur_asset / prev_asset) / (cur_rel / prev_rel) - 1
            if short < lock.short_momentum_threshold and relative_momentum < lock.relative_momentum_threshold:
                triggered = True
                break
        if triggered:
            cap_total_exposure(lock.max_exposure, lock.redeploy_symbol, lock.redeploy_ratio)

    if config.held_breakdown_lock:
        lock = config.held_breakdown_lock
        triggered = False
        for sym in lock.trigger_symbols:
            if final.get(sym, 0.0) <= 0:
                continue
            prices = prices_by_symbol[sym]
            rel = prices_by_symbol[lock.relative_symbol]
            don = donchian_range_position(prices, signal_index, lock.donchian_lookback_sessions)
            if don is None or don <= lock.donchian_position_threshold:
                continue
            signal_count = 0
            dd = rolling_drawdown_from_high(prices, signal_index, lock.drawdown_lookback_sessions)
            if dd is not None and dd <= -max(lock.drawdown_threshold, 0.0):
                signal_count += 1
            short = price_momentum(prices, signal_index, lock.short_momentum_lookback_sessions)
            if short is not None and short < lock.short_momentum_threshold:
                signal_count += 1
            medium = price_momentum(prices, signal_index, lock.medium_momentum_lookback_sessions)
            if medium is not None and medium < lock.medium_momentum_threshold:
                signal_count += 1
            if signal_index - lock.relative_lookback_sessions >= 0:
                prev_asset, cur_asset = prices[signal_index - lock.relative_lookback_sessions], prices[signal_index]
                prev_rel, cur_rel = rel[signal_index - lock.relative_lookback_sessions], rel[signal_index]
                if min(prev_asset, cur_asset, prev_rel, cur_rel) > 0:
                    rel_mom = (cur_asset / prev_asset) / (cur_rel / prev_rel) - 1
                    if rel_mom < lock.relative_momentum_threshold:
                        signal_count += 1
            if signal_count >= max(lock.required_signals, 1):
                triggered = True
                break
        if triggered:
            cap_total_exposure(lock.max_exposure, lock.redeploy_symbol, lock.redeploy_ratio)

    return {sym: weight for sym, weight in final.items() if weight > 0.0001}


def apply_portfolio_guard(target: dict[str, float], current_value: float, points: list[float], config: Config) -> dict[str, float]:
    guard = config.portfolio_drawdown_guard
    if not guard or not target or not points:
        return target
    recent = points[-max(guard.lookback_sessions, 1):] + [current_value]
    peak = max(recent) if recent else 0
    if peak <= 0:
        return target
    drawdown = current_value / peak - 1
    if drawdown < -max(guard.drawdown_threshold, 0.0):
        scale = clamp01(guard.scale)
        return {sym: weight * scale for sym, weight in target.items()}
    return target


def simulated_rotation_trace(symbols: list[str], prices_by_symbol: dict[str, list[float]], dates: list[date], config: Config) -> SimulatedTrace:
    ma_by_symbol, vol_by_symbol = indicator_maps(prices_by_symbol, config)
    weights: dict[str, float] = {}
    values = [100_000.0]
    weights_by_index = [dict(weights)]
    value = 100_000.0
    rebalance_sessions = max(config.rebalance_sessions, 1)
    for index in range(1, len(dates)):
        daily_return = 0.0
        for sym in symbols:
            weight = weights.get(sym, 0.0)
            prices = prices_by_symbol[sym]
            if weight > 0 and prices[index - 1] > 0:
                daily_return += weight * (prices[index] / prices[index - 1] - 1)
        invested = sum(max(v, 0.0) for v in weights.values())
        daily_return += max(0.0, 1.0 - invested) * cash_daily_return(dates[index - 1])
        value *= 1 + daily_return
        if not math.isfinite(value) or value <= 0:
            value = values[-1]
        if index == 1 or index % rebalance_sessions == 0:
            signal_index = index - 1
            base = advanced_rotation_target_weights(symbols, prices_by_symbol, ma_by_symbol, vol_by_symbol, signal_index, dates[signal_index], config)
            weights = apply_portfolio_guard(base, value, values, config)
        values.append(value)
        weights_by_index.append(dict(weights))
    return SimulatedTrace(values, weights_by_index)


def portfolio_rolling_return(values: list[float], index: int, lookback: int) -> float | None:
    if lookback <= 0 or index < 0 or index >= len(values) or index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def portfolio_rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if lookback <= 0 or index < 0 or index >= len(values):
        return None
    start = max(0, index - lookback + 1)
    peak = max(values[start : index + 1])
    if peak <= 0:
        return None
    return values[index] / peak - 1


def portfolio_annualized_volatility(values: list[float], index: int, lookback: int) -> float | None:
    if lookback <= 1 or index < 0 or index >= len(values):
        return None
    start = max(1, index - lookback + 1)
    returns = []
    for i in range(start, index + 1):
        if values[i - 1] > 0 and values[i] > 0:
            returns.append(values[i] / values[i - 1] - 1)
    if len(returns) < 5:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((x - mean) ** 2 for x in returns) / len(returns)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(TRADING_DAYS_PER_YEAR)


def meta_rotation_target_weights(meta: MetaSwitch, stress_index: int, weight_index: int, traces: dict[str, SimulatedTrace]) -> dict[str, float] | None:
    default = traces[meta.default_mode]
    defensive = traces[meta.defensive_mode]
    if stress_index >= len(default.values) or weight_index >= len(default.weights_by_index) or weight_index >= len(defensive.weights_by_index):
        return None
    recent_return = portfolio_rolling_return(default.values, stress_index, meta.loss_lookback_sessions) or 0.0
    recent_vol = portfolio_annualized_volatility(default.values, stress_index, meta.volatility_lookback_sessions) or 0.0
    recent_dd = portfolio_rolling_drawdown(default.values, stress_index, max(meta.drawdown_lookback_sessions, meta.loss_lookback_sessions, meta.volatility_lookback_sessions)) or 0.0
    loss_stress = recent_return <= -max(meta.loss_threshold, 0.0) and recent_dd < -max(meta.loss_drawdown_threshold, 0.0)
    vol_stress = recent_vol >= max(meta.volatility_threshold, 0.0) and recent_return < 0 and recent_dd < -max(meta.volatility_drawdown_threshold, 0.0)
    chosen = defensive if (loss_stress or vol_stress) else default
    return dict(chosen.weights_by_index[weight_index])


def apply_gold_satellite_overlay(
    raw_weights: dict[str, float],
    signal_index: int,
    signal_date: date,
    prices_by_symbol: dict[str, list[float]],
    portfolio_values: list[float] | None,
    config: Config,
) -> dict[str, float]:
    overlay = config.gold_satellite_overlay
    if not overlay:
        return raw_weights
    final = {sym: max(weight, 0.0) * clamp01(overlay.core_scale) for sym, weight in raw_weights.items()}

    def symbol_momentum(sym: str, lookback: int) -> float | None:
        return price_momentum(prices_by_symbol[sym], signal_index, lookback)

    def is_above_ma(sym: str, period: int) -> bool:
        ma = moving_average(prices_by_symbol[sym], period)[signal_index]
        return ma is not None and prices_by_symbol[sym][signal_index] >= ma

    satellite_mom = symbol_momentum(overlay.satellite_symbol, overlay.satellite_momentum_lookback_sessions)
    rel_prices = prices_by_symbol[overlay.relative_symbol]
    sat_prices = prices_by_symbol[overlay.satellite_symbol]
    can_satellite = False
    if satellite_mom is not None and satellite_mom > overlay.satellite_momentum_threshold and is_above_ma(overlay.satellite_symbol, overlay.satellite_moving_average_period) and signal_index - overlay.relative_lookback_sessions >= 0:
        ps = sat_prices[signal_index - overlay.relative_lookback_sessions]
        pr = rel_prices[signal_index - overlay.relative_lookback_sessions]
        cs = sat_prices[signal_index]
        cr = rel_prices[signal_index]
        if min(ps, pr, cs, cr) > 0:
            rel_mom = (cs / ps) / (cr / pr) - 1
            can_satellite = rel_mom > overlay.relative_momentum_threshold
    if can_satellite:
        final[overlay.satellite_symbol] = final.get(overlay.satellite_symbol, 0.0) + max(overlay.satellite_weight, 0.0)

    if overlay.portfolio_equity_brake and portfolio_values is not None and signal_index < len(portfolio_values):
        brake = overlay.portfolio_equity_brake
        start = max(0, signal_index - max(brake.lookback_sessions, 1) + 1)
        peak = max(portfolio_values[start : signal_index + 1])
        if peak > 0 and portfolio_values[signal_index] / peak - 1 < -max(brake.drawdown_threshold, 0.0):
            scale = clamp01(brake.equity_scale)
            for sym in brake.equity_symbols:
                if final.get(sym, 0.0) > 0:
                    final[sym] *= scale

    if overlay.weak_month_equity_brake and signal_date.month in overlay.weak_month_equity_brake.months:
        brake = overlay.weak_month_equity_brake
        weak = []
        for sym in brake.equity_symbols:
            if final.get(sym, 0.0) <= 0:
                continue
            mom = symbol_momentum(sym, brake.momentum_lookback_sessions)
            if mom is not None and mom < brake.momentum_threshold:
                weak.append(sym)
        current_equity = sum(max(final.get(sym, 0.0), 0.0) for sym in brake.equity_symbols)
        max_equity = clamp01(brake.max_equity_exposure)
        if weak and current_equity > max_equity and current_equity > 0:
            scale = max_equity / current_equity
            for sym in brake.equity_symbols:
                if final.get(sym, 0.0) > 0:
                    final[sym] *= scale

    if overlay.single_asset_exposure_cap:
        cap = clamp01(overlay.single_asset_exposure_cap.max_weight)
        for sym in overlay.single_asset_exposure_cap.symbols:
            if final.get(sym, 0.0) > cap:
                final[sym] = cap

    total = sum(max(v, 0.0) for v in final.values())
    max_total = clamp01(overlay.max_total_exposure)
    if total > max_total and total > 0:
        scale = max_total / total
        final = {sym: max(weight, 0.0) * scale for sym, weight in final.items()}
    return {sym: weight for sym, weight in final.items() if weight > 0.0001}


def performance_metrics(dates: list[date], values: list[float]) -> tuple[float, float, float, float | None, float | None]:
    if not dates or not values or values[0] <= 0:
        raise RuntimeError("empty performance series")
    normalized = 1.0
    previous = values[0]
    peak = 1.0
    returns: list[float] = []
    max_dd = 0.0
    for value in values[1:]:
        if previous > 0 and value > 0:
            period_return = value / previous - 1
            returns.append(period_return)
            normalized *= 1 + period_return
            peak = max(peak, normalized)
            if peak > 0:
                max_dd = max(max_dd, (peak - normalized) / peak)
        previous = value
    total = normalized - 1
    day_span = max((dates[-1] - dates[0]).days, 1)
    years = day_span / 365.25
    annualized = normalized ** (1 / years) - 1 if years > 0 else None
    if annualized is None:
        raise RuntimeError("annualized return unavailable")
    if len(returns) > 1:
        mean = sum(returns) / len(returns)
        variance = sum((x - mean) ** 2 for x in returns) / (len(returns) - 1)
        daily_vol = math.sqrt(variance)
        annual_vol = daily_vol * math.sqrt(TRADING_DAYS_PER_YEAR)
        sharpe = (mean * TRADING_DAYS_PER_YEAR) / annual_vol if annual_vol > 0 else None
    else:
        annual_vol = None
        sharpe = None
    return total, annualized, max_dd, annual_vol, sharpe


def run_strategy(strategy: str = "coreGoldSatelliteHeatCappedMomentum", initial_cash: float = 100_000.0, fee_rate_pct: float = 0.10, slippage_rate_pct: float = 0.05, end_date: str | date | None = None) -> BacktestResult:
    cutoff = parse_date(end_date) if isinstance(end_date, str) else end_date
    raw = fetch_public_history(end_date=cutoff)
    prepared = prepare_series(raw)
    dates, prices_by_symbol = align_rotation_price_series(prepared)
    symbols = [p.symbol for p in prepared]
    config = strategy_config(strategy)
    ma_by_symbol, vol_by_symbol = indicator_maps(prices_by_symbol, config)

    meta_traces: dict[str, SimulatedTrace] | None = None
    if config.meta_switch:
        meta_traces = {
            config.meta_switch.default_mode: simulated_rotation_trace(symbols, prices_by_symbol, dates, strategy_config(config.meta_switch.default_mode)),
            config.meta_switch.defensive_mode: simulated_rotation_trace(symbols, prices_by_symbol, dates, strategy_config(config.meta_switch.defensive_mode)),
        }

    cash = max(initial_cash, 0.0)
    fee_rate = max(fee_rate_pct, 0.0) / 100.0
    slippage_rate = max(slippage_rate_pct, 0.0) / 100.0
    band = max(config.rebalance_band, 0.0)
    tradable_symbols = [s for s in symbols if s not in config.signal_only_symbols]
    units = {sym: 0.0 for sym in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[Trade] = []
    last_rebalance_index = -10**9

    def portfolio_value(index: int) -> float:
        return cash + sum(units[sym] * prices_by_symbol[sym][index] for sym in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        if config.meta_switch and meta_traces is not None:
            raw_weights = meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces)
            if raw_weights is None:
                return {}
            return apply_gold_satellite_overlay(raw_weights, signal_index, dates[signal_index], prices_by_symbol, points, config)
        return advanced_rotation_target_weights(symbols, prices_by_symbol, ma_by_symbol, vol_by_symbol, signal_index, dates[signal_index], config)

    for index, current_date in enumerate(dates):
        if index > 0 and cash > 0:
            interest = cash * cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        rebalance_sessions = max(config.rebalance_sessions, 1)
        if config.rebalances_from_first_signal:
            should_rebalance = index > 0 and index - last_rebalance_index >= rebalance_sessions
        else:
            should_rebalance = index == 0 or index % rebalance_sessions == 0

        if should_rebalance:
            signal_index = index - 1
            pre_value = portfolio_value(index)
            base_targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            targets = base_targets if config.meta_switch else apply_portfolio_guard(base_targets, pre_value, points, config)
            target_symbols = set(targets.keys())

            for sym in sorted(held - target_symbols):
                price = prices_by_symbol[sym][index]
                current_units = units.get(sym, 0.0)
                if current_units <= 0:
                    continue
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = current_units * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[sym] = 0.0
                trades.append(Trade(current_date.isoformat(), "sell", sym, execution_price, cash_amount, current_units))
            held &= target_symbols

            for sym in sorted(target_symbols):
                current_units = units.get(sym, 0.0)
                if current_units <= 0:
                    continue
                price = prices_by_symbol[sym][index]
                current_value = current_units * price
                target_value = pre_value * targets[sym]
                gross_to_sell = max(current_value - target_value, 0.0) if current_value > target_value * (1 + band) else 0.0
                if gross_to_sell <= 0:
                    continue
                units_to_sell = min(current_units, gross_to_sell / price)
                if units_to_sell <= 0:
                    continue
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = units_to_sell * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[sym] = max(current_units - units_to_sell, 0.0)
                trades.append(Trade(current_date.isoformat(), "sell", sym, execution_price, cash_amount, units_to_sell))
                if units[sym] <= sys.float_info.min:
                    held.discard(sym)

            total_value = portfolio_value(index)
            for sym in sorted(target_symbols):
                price = prices_by_symbol[sym][index]
                if price <= 0:
                    continue
                current_value = units.get(sym, 0.0) * price
                target_value = total_value * targets[sym]
                amount = min(cash, max(target_value - current_value, 0.0)) if current_value < target_value * (1 - band) else 0.0
                if amount <= 0:
                    continue
                execution_price = price * (1 + slippage_rate)
                invested = amount * (1 - fee_rate)
                bought_units = invested / execution_price if execution_price > 0 else 0.0
                units[sym] = units.get(sym, 0.0) + bought_units
                cash -= amount
                held.add(sym)
                trades.append(Trade(current_date.isoformat(), "buy", sym, execution_price, amount, bought_units))
            last_rebalance_index = index

        points.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol, sharpe = performance_metrics(dates, points)
    return BacktestResult(
        strategy=strategy,
        coverage_start=dates[0].isoformat(),
        coverage_end=dates[-1].isoformat(),
        point_count=len(points),
        annualized_return=annualized,
        max_drawdown=max_dd,
        total_return=total,
        annualized_volatility=annual_vol,
        sharpe_ratio=sharpe,
        final_value=points[-1],
        trades=trades,
        dates=dates,
        values=points,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run AssetTimeMachine app-equivalent Python backtest")
    parser.add_argument("strategy", nargs="?", default="coreGoldSatelliteHeatCappedMomentum")
    parser.add_argument("--end-date", help="optional YYYY-MM-DD market-data cutoff for stable App-record regression")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = parser.parse_args()
    result = run_strategy(args.strategy, end_date=args.end_date)
    if args.json:
        print(json.dumps({
            "strategy": result.strategy,
            "coverage_start": result.coverage_start,
            "coverage_end": result.coverage_end,
            "point_count": result.point_count,
            "annualized_return": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "total_return": result.total_return,
            "annualized_volatility": result.annualized_volatility,
            "sharpe_ratio": result.sharpe_ratio,
            "final_value": result.final_value,
            "first_trades": [trade.__dict__ for trade in result.trades[:10]],
        }, ensure_ascii=False, indent=2))
    else:
        print(f"{result.strategy}: annualized={result.annualized_return:.6%} max_drawdown={result.max_drawdown:.6%} total={result.total_return:.6%}")
        print(f"coverage={result.coverage_start}..{result.coverage_end} points={result.point_count} trades={len(result.trades)} final={result.final_value:.2f}")
        for trade in result.trades[:10]:
            print(f"{trade.date} {trade.action:4s} {trade.symbol:20s} amount={trade.cash_amount:.2f} price={trade.price:.6f} units={trade.units:.6f}")


if __name__ == "__main__":
    main()
