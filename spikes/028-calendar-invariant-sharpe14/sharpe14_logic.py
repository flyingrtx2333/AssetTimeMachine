#!/usr/bin/env python3
"""Calendar-invariant no-leverage search for Sharpe 1.4+ candidates.

This spike starts from the corrected app-equivalent engine calendar.  It looks
for structural logic improvements over the current one-way volatility-managed
router:

- route only when the offensive engine has better quality;
- cut exposure when the selected portfolio's own trailing volatility is high;
- treat equity-market stress as a reason to hold cash, not rotate sideways;
- slow risk rebuilds after the strategy equity curve is below a recent high.

All candidates are long-only and capped at 100% total notional exposure.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "spikes" / "022-engine-selection-logic" / "engine_selection_logic.py"
SPEC = importlib.util.spec_from_file_location("engine_selection_logic_base", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {MODULE_PATH}")
base = importlib.util.module_from_spec(SPEC)
sys.modules["engine_selection_logic_base"] = base
SPEC.loader.exec_module(base)

import atm_app_equivalent_backtest as app  # noqa: E402
import atm_new_logic_explorer as logic  # noqa: E402

Overlay = base.Overlay
EQUITIES = app.EQUITY_SYMBOLS
US_EQUITIES = ["nasdaq", "sp500"]


@dataclass(frozen=True)
class Candidate:
    name: str
    thesis: str
    route_mode: str
    risk_modules: tuple[str, ...]
    rebalance_sessions: int = 60


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


def scale(weights: dict[str, float], factor: float) -> dict[str, float]:
    factor = min(max(factor, 0.0), 1.0)
    return normalize({symbol: weight * factor for symbol, weight in weights.items()})


def blend(first: dict[str, float], second: dict[str, float], first_share: float) -> dict[str, float]:
    out: dict[str, float] = {}
    share = min(max(first_share, 0.0), 1.0)
    for symbol, weight in first.items():
        out[symbol] = out.get(symbol, 0.0) + weight * share
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * (1 - share)
    return normalize(out)


def cap_group(weights: dict[str, float], symbols: list[str], max_group_total: float) -> dict[str, float]:
    out = dict(weights)
    current = sum(max(out.get(symbol, 0.0), 0.0) for symbol in symbols)
    if current <= max_group_total or current <= 0:
        return normalize(out)
    factor = max_group_total / current
    for symbol in symbols:
        if out.get(symbol, 0.0) > 0:
            out[symbol] *= factor
    return normalize(out)


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def trailing_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    start = max(0, index - lookback + 1)
    window = values[start:index + 1]
    if not window:
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def trailing_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def trailing_sharpe(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(values[cursor] / values[cursor - 1] - 1)
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    annual_vol = math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)
    if annual_vol <= 0:
        return None
    return mean * app.TRADING_DAYS_PER_YEAR / annual_vol


def price_mom(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    return app.price_momentum(prices_by_symbol[symbol], index, lookback)


def above_ma(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, period: int) -> bool:
    ma = app.moving_average(prices_by_symbol[symbol], period)[index]
    return ma is not None and prices_by_symbol[symbol][index] >= ma


def confirmed_equity(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    mom60 = price_mom(prices_by_symbol, symbol, index, 60)
    mom120 = price_mom(prices_by_symbol, symbol, index, 120)
    return mom60 is not None and mom120 is not None and mom60 > 0 and mom120 > 0 and above_ma(prices_by_symbol, symbol, index, 120)


def confirmed_equity_count(prices_by_symbol: dict[str, list[float]], index: int) -> int:
    return sum(1 for symbol in EQUITIES if confirmed_equity(prices_by_symbol, symbol, index))


def us_risk_off(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    weak = 0
    for symbol in US_EQUITIES:
        mom60 = price_mom(prices_by_symbol, symbol, index, 60)
        if mom60 is None or mom60 < 0 or not above_ma(prices_by_symbol, symbol, index, 120):
            weak += 1
    return weak >= 2


def recent_portfolio_drawdown(portfolio_values: list[float] | None, signal_index: int, lookback: int) -> float:
    if not portfolio_values:
        return 0.0
    clean = [value for value in portfolio_values[: signal_index + 1] if value > 0]
    if not clean:
        return 0.0
    window = clean[-lookback:]
    peak = max(window)
    return window[-1] / peak - 1 if peak > 0 else 0.0


def weighted_portfolio_vol(
    weights: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    index: int,
    lookback: int,
) -> float | None:
    if not weights or index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        daily = 0.0
        valid = False
        for symbol, weight in weights.items():
            prices = prices_by_symbol[symbol]
            if prices[cursor - 1] <= 0 or prices[cursor] <= 0:
                continue
            daily += weight * (prices[cursor] / prices[cursor - 1] - 1)
            valid = True
        if valid:
            returns.append(daily)
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def asset_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int = 120) -> float | None:
    return weighted_portfolio_vol({symbol: 1.0}, prices_by_symbol, index, lookback)


def trend_ok(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    mom60 = price_mom(prices_by_symbol, symbol, index, 60)
    mom120 = price_mom(prices_by_symbol, symbol, index, 120)
    if mom60 is None or mom120 is None or mom60 <= 0 or mom120 <= 0:
        return False
    if symbol != "gold_cny" and not above_ma(prices_by_symbol, symbol, index, 120):
        return False
    if symbol == "gold_cny" and not above_ma(prices_by_symbol, symbol, index, 90):
        return False
    return True


def asset_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    mom60 = price_mom(prices_by_symbol, symbol, index, 60) or 0.0
    mom120 = price_mom(prices_by_symbol, symbol, index, 120) or 0.0
    mom240 = price_mom(prices_by_symbol, symbol, index, 240) or 0.0
    vol = asset_vol(prices_by_symbol, symbol, index, 120) or 9.0
    return max(0.0, (mom120 + 0.5 * mom60 + 0.25 * mom240) / max(vol, 0.01))


def cap_single_assets(weights: dict[str, float], cap: float) -> dict[str, float]:
    return normalize({symbol: min(max(weight, 0.0), cap) for symbol, weight in weights.items()})


def score_weighted_trend_basket(
    prices_by_symbol: dict[str, list[float]],
    index: int,
    top_count: int,
    max_total: float,
    cap: float,
    use_inverse_vol: bool,
) -> dict[str, float]:
    scored = [(asset_score(prices_by_symbol, symbol, index), symbol) for symbol in app.SYMBOLS if trend_ok(prices_by_symbol, symbol, index)]
    scored = [(score, symbol) for score, symbol in scored if score > 0]
    if not scored:
        return {}
    scored.sort(reverse=True)
    selected = scored[:top_count]
    raw: dict[str, float] = {}
    for score, symbol in selected:
        vol = asset_vol(prices_by_symbol, symbol, index, 120) or 0.25
        raw[symbol] = 1 / max(vol, 0.03) if use_inverse_vol else score
    total = total_weight(raw)
    if total <= 0:
        return {}
    weights = {symbol: max_total * value / total for symbol, value in raw.items()}
    return cap_single_assets(weights, cap)


def gold_us_barbell_weights(prices_by_symbol: dict[str, list[float]], index: int, max_total: float) -> dict[str, float]:
    selected: list[str] = []
    if trend_ok(prices_by_symbol, "gold_cny", index):
        selected.append("gold_cny")
    confirmed_us = [symbol for symbol in US_EQUITIES if trend_ok(prices_by_symbol, symbol, index)]
    if confirmed_us:
        selected.append(max(confirmed_us, key=lambda symbol: asset_score(prices_by_symbol, symbol, index)))
    confirmed_cn = [symbol for symbol in ["csi300", "shanghai_composite"] if trend_ok(prices_by_symbol, symbol, index)]
    if confirmed_cn and len(selected) < 2 and not us_risk_off(prices_by_symbol, index):
        selected.append(max(confirmed_cn, key=lambda symbol: asset_score(prices_by_symbol, symbol, index)))
    if not selected:
        return {}
    raw = {symbol: 1 / max(asset_vol(prices_by_symbol, symbol, index, 120) or 0.25, 0.03) for symbol in selected}
    total = total_weight(raw)
    weights = {symbol: max_total * value / total for symbol, value in raw.items()}
    return cap_single_assets(weights, 0.60)


def standalone_weights(route_mode: str, prices_by_symbol: dict[str, list[float]], signal_index: int) -> dict[str, float]:
    if route_mode == "asset_top2_score_85":
        return score_weighted_trend_basket(prices_by_symbol, signal_index, 2, 0.85, 0.58, False)
    if route_mode == "asset_top3_score_100":
        return score_weighted_trend_basket(prices_by_symbol, signal_index, 3, 1.00, 0.50, False)
    if route_mode == "asset_top2_invvol_95":
        return score_weighted_trend_basket(prices_by_symbol, signal_index, 2, 0.95, 0.60, True)
    if route_mode == "asset_top3_invvol_100":
        return score_weighted_trend_basket(prices_by_symbol, signal_index, 3, 1.00, 0.50, True)
    if route_mode == "asset_gold_us_barbell_90":
        return gold_us_barbell_weights(prices_by_symbol, signal_index, 0.90)
    if route_mode == "asset_gold_us_barbell_100":
        return gold_us_barbell_weights(prices_by_symbol, signal_index, 1.00)
    raise ValueError(route_mode)


def engine_quality(values: list[float], index: int, lookback: int) -> float | None:
    ret = trailing_return(values, index, lookback)
    vol = trailing_vol(values, index, lookback)
    dd = trailing_drawdown(values, index, lookback // 2)
    if ret is None or vol is None:
        return None
    drawdown_penalty = abs(min(dd or 0.0, 0.0))
    return ret / max(vol, 0.01) - drawdown_penalty * 1.5


def route_weights(
    context: base.EngineContext,
    current_weights: dict[str, float],
    breadth_weights: dict[str, float],
    signal_index: int,
    route_mode: str,
) -> tuple[dict[str, float], str]:
    current_ret = trailing_return(context.current.values, signal_index, 240)
    breadth_ret = trailing_return(context.breadth.values, signal_index, 240)
    current_sharpe = trailing_sharpe(context.current.values, signal_index, 240)
    breadth_sharpe = trailing_sharpe(context.breadth.values, signal_index, 240)
    current_quality = engine_quality(context.current.values, signal_index, 240)
    breadth_quality = engine_quality(context.breadth.values, signal_index, 240)
    breadth_dd = trailing_drawdown(context.breadth.values, signal_index, 120)

    if route_mode == "return_lead_blend":
        if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret:
            if breadth_dd is not None and breadth_dd < -0.08:
                return blend(current_weights, breadth_weights, 0.7), "defensive_blend"
            return blend(breadth_weights, current_weights, 0.7), "offensive_blend"
        return current_weights, "current"

    if route_mode == "quality_gate":
        if (
            breadth_ret is not None
            and current_ret is not None
            and breadth_quality is not None
            and current_quality is not None
            and breadth_ret > current_ret
            and breadth_quality > current_quality
            and (breadth_dd is None or breadth_dd > -0.08)
        ):
            return blend(breadth_weights, current_weights, 0.65), "offensive_blend"
        if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret and (breadth_dd is None or breadth_dd > -0.12):
            return blend(current_weights, breadth_weights, 0.75), "defensive_blend"
        return current_weights, "current"

    if route_mode == "dual_quality":
        if (
            breadth_ret is not None
            and current_ret is not None
            and breadth_sharpe is not None
            and current_sharpe is not None
            and breadth_ret > current_ret
            and breadth_sharpe > current_sharpe
            and (breadth_dd is None or breadth_dd > -0.08)
        ):
            return blend(breadth_weights, current_weights, 0.7), "offensive_blend"
        return current_weights, "current"

    if route_mode == "regret_router":
        if current_quality is None or breadth_quality is None:
            return current_weights, "current"
        gap = breadth_quality - current_quality
        if gap > 0.40 and (breadth_dd is None or breadth_dd > -0.08):
            return blend(breadth_weights, current_weights, 0.70), "offensive_blend"
        if gap > 0.10 and (breadth_dd is None or breadth_dd > -0.12):
            return blend(breadth_weights, current_weights, 0.50), "offensive_half"
        return current_weights, "current"

    if route_mode == "quality_risk_parity":
        if current_quality is None or breadth_quality is None:
            return current_weights, "current"
        c = max(current_quality, 0.0)
        b = max(breadth_quality, 0.0)
        if c <= 0 and b <= 0:
            return current_weights, "current"
        breadth_share = b / max(c + b, 0.001)
        if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret:
            breadth_share = max(breadth_share, 0.55)
        else:
            breadth_share = min(breadth_share, 0.35)
        state = "offensive_blend" if breadth_share > 0.5 else "current"
        return blend(breadth_weights, current_weights, breadth_share), state

    raise ValueError(route_mode)


def apply_risk_module(
    weights: dict[str, float],
    state: str,
    context: base.EngineContext,
    signal_index: int,
    prices_by_symbol: dict[str, list[float]],
    portfolio_values: list[float] | None,
    module: str,
) -> dict[str, float]:
    if module == "one_way_engine_vol":
        current_vol = trailing_vol(context.current.values, signal_index, 240)
        breadth_vol = trailing_vol(context.breadth.values, signal_index, 240)
        if state.startswith("offensive") and current_vol is not None and breadth_vol is not None and breadth_vol > current_vol:
            return scale(weights, current_vol / breadth_vol)
        return weights

    if module == "basket_vol_10":
        vol = weighted_portfolio_vol(weights, prices_by_symbol, signal_index, 120)
        if vol is not None and vol > 0.10:
            return scale(weights, 0.10 / vol)
        return weights

    if module == "basket_vol_9":
        vol = weighted_portfolio_vol(weights, prices_by_symbol, signal_index, 120)
        if vol is not None and vol > 0.09:
            return scale(weights, 0.09 / vol)
        return weights

    if module == "basket_vol_8":
        vol = weighted_portfolio_vol(weights, prices_by_symbol, signal_index, 120)
        if vol is not None and vol > 0.08:
            return scale(weights, 0.08 / vol)
        return weights

    if module == "equity_stress_cash":
        if sum(weights.get(symbol, 0.0) for symbol in EQUITIES) > 0.35 and (confirmed_equity_count(prices_by_symbol, signal_index) < 2 or us_risk_off(prices_by_symbol, signal_index)):
            return cap_group(weights, EQUITIES, 0.28)
        return weights

    if module == "breadth_drawdown_cash":
        breadth_dd = trailing_drawdown(context.breadth.values, signal_index, 120)
        if state.startswith("offensive") and breadth_dd is not None and breadth_dd < -0.04:
            return cap_group(weights, EQUITIES, 0.35)
        return weights

    if module == "portfolio_ladder":
        dd = recent_portfolio_drawdown(portfolio_values, signal_index, 60)
        if dd < -0.035:
            return scale(weights, 0.62)
        if dd < -0.020:
            return scale(weights, 0.78)
        return weights

    if module == "offense_profit_lock":
        fast = trailing_return(context.breadth.values, signal_index, 60)
        shallow_dd = trailing_drawdown(context.breadth.values, signal_index, 60)
        if state.startswith("offensive") and fast is not None and fast > 0.08 and (shallow_dd is None or shallow_dd > -0.02):
            return scale(weights, 0.88)
        return weights

    if module == "china_bubble_contagion":
        china = ["csi300", "shanghai_composite"]
        bubble = any(
            (price_mom(prices_by_symbol, symbol, signal_index, 240) or 0.0) > 0.55
            and (app.donchian_range_position(prices_by_symbol[symbol], signal_index, 240) or 0.0) > 0.75
            for symbol in china
        )
        rollover = any(
            (price_mom(prices_by_symbol, symbol, signal_index, 20) or 0.0) < -0.04
            or (app.rolling_drawdown_from_high(prices_by_symbol[symbol], signal_index, 60) or 0.0) < -0.10
            for symbol in china
        )
        if bubble and rollover and sum(weights.get(symbol, 0.0) for symbol in EQUITIES) > 0:
            weights = cap_group(weights, china, 0.0)
            return cap_group(weights, EQUITIES, 0.35)
        return weights

    if module == "us_breakdown_cash":
        us_break = any(
            weights.get(symbol, 0.0) > 0
            and (
                (price_mom(prices_by_symbol, symbol, signal_index, 20) or 0.0) < -0.035
                or not above_ma(prices_by_symbol, symbol, signal_index, 60)
            )
            for symbol in US_EQUITIES
        )
        if us_break:
            return cap_group(weights, EQUITIES, 0.28)
        return weights

    if module == "gold_blowoff_cash":
        if weights.get("gold_cny", 0.0) > 0.30:
            long = price_mom(prices_by_symbol, "gold_cny", signal_index, 90)
            short = price_mom(prices_by_symbol, "gold_cny", signal_index, 20)
            if long is not None and short is not None and long > 0.08 and short < 0:
                weights = dict(weights)
                weights["gold_cny"] = min(weights.get("gold_cny", 0.0), 0.32)
                return normalize(weights)
        return weights

    raise ValueError(module)


def overlay_factory(context: base.EngineContext, candidate: Candidate) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            if candidate.route_mode.startswith("asset_"):
                weights, state = standalone_weights(candidate.route_mode, prices_by_symbol, signal_index), "standalone"
            else:
                current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
                breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
                weights, state = route_weights(context, current_weights, breadth_weights, signal_index, candidate.route_mode)
            for module in candidate.risk_modules:
                weights = apply_risk_module(weights, state, context, signal_index, prices_by_symbol, portfolio_values, module)
            return normalize(weights)

        return overlay

    return factory


def run_overlay_strategy(
    name: str,
    overlay_builder: Callable[[Overlay], Overlay],
    rebalance_sessions: int,
) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    original_strategy_config = app.strategy_config
    gold_guard = base.base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )

    def patched_strategy_config(strategy_name: str) -> app.Config:
        config = original_strategy_config(strategy_name)
        if rebalance_sessions != 60:
            return replace(config, rebalance_sessions=rebalance_sessions)
        return config

    app.strategy_config = patched_strategy_config  # type: ignore[assignment]
    app.apply_gold_satellite_overlay = overlay_builder(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
        app.strategy_config = original_strategy_config  # type: ignore[assignment]
    return app.BacktestResult(
        strategy=name,
        coverage_start=result.coverage_start,
        coverage_end=result.coverage_end,
        point_count=result.point_count,
        annualized_return=result.annualized_return,
        max_drawdown=result.max_drawdown,
        total_return=result.total_return,
        annualized_volatility=result.annualized_volatility,
        sharpe_ratio=result.sharpe_ratio,
        final_value=result.final_value,
        trades=result.trades,
        dates=result.dates,
        values=result.values,
    )


def candidate_specs() -> list[Candidate]:
    base_specs = [
        Candidate("baseline_return_lead_blend", "Prior return-led current/breadth router.", "return_lead_blend", ()),
        Candidate("baseline_one_way_vol", "Current app champion: return-led router with one-way engine volatility scale-down.", "return_lead_blend", ("one_way_engine_vol",)),
        Candidate("one_way_plus_basket_vol10", "Add selected-basket volatility budget, never scaling above 100%.", "return_lead_blend", ("one_way_engine_vol", "basket_vol_10")),
        Candidate("one_way_plus_basket_vol9", "Same logic with a stricter selected-basket volatility budget.", "return_lead_blend", ("one_way_engine_vol", "basket_vol_9")),
        Candidate("one_way_plus_basket_vol8", "Stress test for an even lower selected-basket volatility budget.", "return_lead_blend", ("one_way_engine_vol", "basket_vol_8")),
        Candidate("one_way_equity_stress_cash", "Hold cash when equity breadth or US risk confirmation fails.", "return_lead_blend", ("one_way_engine_vol", "equity_stress_cash")),
        Candidate("one_way_portfolio_ladder", "After equity-curve drawdown, rebuild exposure slowly instead of immediately refilling risk.", "return_lead_blend", ("one_way_engine_vol", "portfolio_ladder")),
        Candidate("one_way_breadth_dd_cash", "If the offensive engine is already in drawdown, cap equity sleeves and keep cash.", "return_lead_blend", ("one_way_engine_vol", "breadth_drawdown_cash")),
        Candidate("one_way_profit_lock", "Reserve cash after fast offensive gains near local highs.", "return_lead_blend", ("one_way_engine_vol", "offense_profit_lock")),
        Candidate("one_way_full_stack", "Combine volatility budget, equity stress veto, and portfolio drawdown ladder.", "return_lead_blend", ("one_way_engine_vol", "basket_vol_10", "equity_stress_cash", "portfolio_ladder")),
        Candidate("quality_gate", "Route offensively only when the offensive engine leads on return and quality.", "quality_gate", ()),
        Candidate("quality_gate_one_way", "Quality-gated routing with one-way engine volatility scale-down.", "quality_gate", ("one_way_engine_vol",)),
        Candidate("quality_gate_basket_vol10", "Quality-gated routing plus selected-basket volatility budget.", "quality_gate", ("one_way_engine_vol", "basket_vol_10")),
        Candidate("quality_gate_equity_stress", "Quality-gated routing plus equity stress cash veto.", "quality_gate", ("one_way_engine_vol", "equity_stress_cash")),
        Candidate("dual_quality_one_way", "Require both return and trailing Sharpe leadership before offensive routing.", "dual_quality", ("one_way_engine_vol",)),
        Candidate("dual_quality_basket_vol10", "Dual-quality route plus selected-basket volatility budget.", "dual_quality", ("one_way_engine_vol", "basket_vol_10")),
        Candidate("regret_router_one_way", "Treat engine selection as regret minimization via return-vol-drawdown quality.", "regret_router", ("one_way_engine_vol",)),
        Candidate("regret_router_basket_vol10", "Regret router plus selected-basket volatility budget.", "regret_router", ("one_way_engine_vol", "basket_vol_10")),
        Candidate("risk_parity_one_way", "Blend engines by quality share instead of picking one winner.", "quality_risk_parity", ("one_way_engine_vol",)),
        Candidate("risk_parity_basket_vol10", "Quality-share engine blend plus selected-basket volatility budget.", "quality_risk_parity", ("one_way_engine_vol", "basket_vol_10")),
        Candidate("risk_parity_full_stack", "Quality-share engine blend with volatility budget, equity stress veto, and drawdown ladder.", "quality_risk_parity", ("one_way_engine_vol", "basket_vol_10", "equity_stress_cash", "portfolio_ladder")),
        Candidate("one_way_china_contagion", "After a China equity bubble rolls over, avoid handing risk sideways to other equity markets.", "return_lead_blend", ("one_way_engine_vol", "china_bubble_contagion")),
        Candidate("one_way_us_breakdown_cash", "Treat a held US breakdown as a cash trigger instead of waiting for the next engine route.", "return_lead_blend", ("one_way_engine_vol", "us_breakdown_cash")),
        Candidate("one_way_gold_blowoff_cash", "Treat gold blowoff rollover as risk, not unconditional defense.", "return_lead_blend", ("one_way_engine_vol", "gold_blowoff_cash")),
        Candidate("one_way_contagion_ladder", "Combine China contagion avoidance with slow risk rebuild after equity-curve drawdown.", "return_lead_blend", ("one_way_engine_vol", "china_bubble_contagion", "portfolio_ladder")),
        Candidate("one_way_tail_combo", "Stack the specific 2015 contagion guard with US breakdown, gold blowoff, and slow rebuild.", "return_lead_blend", ("one_way_engine_vol", "china_bubble_contagion", "us_breakdown_cash", "gold_blowoff_cash", "portfolio_ladder")),
    ]
    faster_risk_review = [
        Candidate(f"one_way_fast_review_{sessions}", "Review risk more often while keeping the same no-leverage target logic.", "return_lead_blend", ("one_way_engine_vol",), sessions)
        for sessions in (20, 30, 40)
    ]
    faster_ladder = [
        Candidate(f"one_way_portfolio_ladder_fast_{sessions}", "Use faster risk review plus slow rebuild after equity-curve drawdown.", "return_lead_blend", ("one_way_engine_vol", "portfolio_ladder"), sessions)
        for sessions in (20, 30, 40)
    ]
    faster_quality = [
        Candidate(f"quality_gate_one_way_fast_{sessions}", "Use faster risk review with quality-gated offensive routing.", "quality_gate", ("one_way_engine_vol",), sessions)
        for sessions in (20, 30, 40)
    ]
    faster_vol_budget = [
        Candidate(f"one_way_basket_vol10_fast_{sessions}", "Use faster risk review plus selected-basket volatility budget.", "return_lead_blend", ("one_way_engine_vol", "basket_vol_10"), sessions)
        for sessions in (20, 30, 40)
    ]
    standalone = [
        Candidate("asset_top2_score_85", "Build a fresh two-asset positive-trend basket weighted by risk-adjusted momentum.", "asset_top2_score_85", ()),
        Candidate("asset_top2_score_85_vol10", "Two-asset positive-trend basket with a selected-basket volatility budget.", "asset_top2_score_85", ("basket_vol_10",)),
        Candidate("asset_top2_score_85_vol9", "Two-asset positive-trend basket with a stricter volatility budget.", "asset_top2_score_85", ("basket_vol_9",)),
        Candidate("asset_top3_score_100_vol10", "Three-asset positive-trend basket, score weighted, no leverage, volatility budgeted.", "asset_top3_score_100", ("basket_vol_10",)),
        Candidate("asset_top2_invvol_95", "Two-asset trend basket with inverse-volatility construction.", "asset_top2_invvol_95", ()),
        Candidate("asset_top2_invvol_95_vol10", "Two-asset inverse-volatility trend basket with volatility budget.", "asset_top2_invvol_95", ("basket_vol_10",)),
        Candidate("asset_top3_invvol_100_vol10", "Three-asset inverse-volatility trend basket with volatility budget.", "asset_top3_invvol_100", ("basket_vol_10",)),
        Candidate("asset_gold_us_barbell_90", "Barbell gold with the strongest confirmed US core asset, leaving cash when neither side confirms.", "asset_gold_us_barbell_90", ()),
        Candidate("asset_gold_us_barbell_90_vol10", "Gold-US barbell with selected-basket volatility budget.", "asset_gold_us_barbell_90", ("basket_vol_10",)),
        Candidate("asset_gold_us_barbell_100_vol10", "Full-budget gold-US barbell, capped by selected-basket volatility.", "asset_gold_us_barbell_100", ("basket_vol_10",)),
    ]
    return base_specs + faster_risk_review + faster_ladder + faster_quality + faster_vol_budget + standalone


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, Any]:
    peak = result.values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def rolling_window_metrics(result: app.BacktestResult, years: int = 3) -> dict[str, float | None]:
    window_days = int(years * 365.25)
    sharpes: list[float] = []
    annualized: list[float] = []
    drawdowns: list[float] = []
    for start_idx, start_day in enumerate(result.dates):
        end_day = date.fromordinal(start_day.toordinal() + window_days)
        end_idx = next((i for i in range(start_idx + 1, len(result.dates)) if result.dates[i] >= end_day), None)
        if end_idx is None:
            break
        _total, ann, dd, _vol, sharpe = app.performance_metrics(result.dates[start_idx : end_idx + 1], result.values[start_idx : end_idx + 1])
        annualized.append(ann)
        drawdowns.append(dd)
        if sharpe is not None:
            sharpes.append(sharpe)
    return {
        "worst_annualized": min(annualized) if annualized else None,
        "worst_sharpe": min(sharpes) if sharpes else None,
        "worst_drawdown": max(drawdowns) if drawdowns else None,
    }


def row_for(candidate: Candidate, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": candidate.name,
        "thesis": candidate.thesis,
        "route_mode": candidate.route_mode,
        "risk_modules": list(candidate.risk_modules),
        "rebalance_sessions": candidate.rebalance_sessions,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "annual_volatility": result.annualized_volatility,
            "sharpe": result.sharpe_ratio,
            "total": result.total_return,
            "trades": len(result.trades),
            "coverage_start": result.coverage_start,
            "coverage_end": result.coverage_end,
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "rolling_3y": rolling_window_metrics(result, 3),
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def main() -> None:
    original_fetch = app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        contexts: dict[int, base.EngineContext] = {}

        rows: list[dict[str, Any]] = []
        for candidate in candidate_specs():
            if candidate.rebalance_sessions not in contexts:
                current = run_overlay_strategy("current_gold_handoff", base.current_overlay, candidate.rebalance_sessions)
                breadth = run_overlay_strategy("equity_breadth", base.breadth_overlay, candidate.rebalance_sessions)
                contexts[candidate.rebalance_sessions] = base.EngineContext(current=current, breadth=breadth)
            context = contexts[candidate.rebalance_sessions]
            result = run_overlay_strategy(candidate.name, overlay_factory(context, candidate), candidate.rebalance_sessions)
            rows.append(row_for(candidate, result))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nSUMMARY")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | worst3y ann/sharpe | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        rolling: dict[str, Any] = row["rolling_3y"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{pct(rolling['worst_annualized'])}/{(rolling['worst_sharpe'] or 0):.4f} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
