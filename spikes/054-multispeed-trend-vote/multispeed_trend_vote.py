#!/usr/bin/env python3
"""Multi-speed trend vote strategy.

This tests a standalone model that does not use the 047 sleeve machinery:
short, medium, and long trend engines vote independently, then the portfolio
holds the consensus assets with no leverage and no shorting.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SPIKE047 = ROOT / "spikes" / "047-dynamic-sleeve-selector"
sys.path.insert(0, str(SPIKE047))

import dynamic_sleeve_selector as dyn  # noqa: E402
import target_replay_search as t47  # noqa: E402
import target_weight_replay as replay  # noqa: E402

app = dyn.app
s35 = replay.s35
s30 = replay.s30


@dataclass(frozen=True)
class VoteSpec:
    name: str
    windows: tuple[int, ...]
    rebalance_sessions: int
    top_per_window: int
    min_votes: int
    max_exposure: float
    per_asset_cap: float
    target_volatility: float | None
    require_ma: bool
    use_inverse_vol: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return replay.normalize(weights, max_total)


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
    for index, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = index
        drawdown = (peak - value) / peak if peak > 0 else 0.0
        if drawdown > worst:
            worst = drawdown
            worst_peak = peak_i
            worst_trough = index
    return {"peak_date": dates[worst_peak].isoformat(), "trough_date": dates[worst_trough].isoformat(), "max_drawdown": worst}


def local_volatility(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        previous = values[cursor - 1]
        current = values[cursor]
        if previous > 0 and current > 0:
            returns.append(math.log(current / previous))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def build_mas(prices_by_symbol: dict[str, list[float]]) -> dict[str, dict[int, list[float | None]]]:
    periods = [20, 40, 60, 80, 120, 160, 240]
    return {symbol: {period: app.moving_average(prices, period) for period in periods} for symbol, prices in prices_by_symbol.items()}


def target_weights(
    *,
    spec: VoteSpec,
    symbols: list[str],
    prices_by_symbol: dict[str, list[float]],
    mas: dict[str, dict[int, list[float | None]]],
    signal_index: int,
) -> dict[str, float]:
    votes: dict[str, int] = {}
    scores: dict[str, float] = {}
    vols: dict[str, float] = {}

    for window in spec.windows:
        candidates: list[tuple[float, str]] = []
        secondary = max(20, window // 3)
        ma_period = min(max(40, window // 2), 240)
        for symbol in symbols:
            prices = prices_by_symbol[symbol]
            if signal_index - window < 0 or prices[signal_index] <= 0 or prices[signal_index - window] <= 0:
                continue
            momentum = prices[signal_index] / prices[signal_index - window] - 1
            short_momentum = app.price_momentum(prices, signal_index, secondary)
            drawdown = app.rolling_drawdown_from_high(prices, signal_index, max(40, window // 2))
            volatility = local_volatility(prices, signal_index, 60)
            ma = mas[symbol].get(ma_period, mas[symbol][120])[signal_index]
            if short_momentum is None or drawdown is None or volatility is None:
                continue
            if momentum <= -0.01 or short_momentum <= -0.02:
                continue
            if spec.require_ma and (ma is None or prices[signal_index] < ma):
                continue
            if volatility > 0.32:
                continue
            score = momentum * 1.15 + short_momentum * 0.45 + max(drawdown, -0.50) * 0.25
            score += 0.025 / max(volatility, 0.03)
            if symbol == "gold_cny":
                score += 0.03
            if score > 0:
                candidates.append((score, symbol))
        candidates.sort(reverse=True)
        for score, symbol in candidates[: max(spec.top_per_window, 1)]:
            votes[symbol] = votes.get(symbol, 0) + 1
            scores[symbol] = scores.get(symbol, 0.0) + score
            vols[symbol] = local_volatility(prices_by_symbol[symbol], signal_index, 60) or 9.0

    eligible = [symbol for symbol, count in votes.items() if count >= spec.min_votes]
    if not eligible:
        return {}
    raw: dict[str, float] = {}
    for symbol in eligible:
        if spec.use_inverse_vol:
            raw[symbol] = votes[symbol] * scores[symbol] / max(vols[symbol], 0.03)
        else:
            raw[symbol] = votes[symbol] * max(scores[symbol], 0.001)
    raw_total = sum(raw.values())
    if raw_total <= 0:
        return {}
    weights = {symbol: min(spec.per_asset_cap, value / raw_total) for symbol, value in raw.items()}
    weights = normalize(weights)
    exposure = spec.max_exposure
    if spec.target_volatility is not None:
        portfolio_vol = sum(weights[symbol] * max(vols.get(symbol, 9.0), 0.03) for symbol in weights)
        exposure = min(exposure, spec.target_volatility / max(portfolio_vol, 0.03))
    return normalize({symbol: weight * exposure for symbol, weight in weights.items()}, 1.0)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def rebalance_portfolio(
    *,
    index: int,
    dates: list[date],
    prices_by_symbol: dict[str, list[float]],
    symbols: list[str],
    targets: dict[str, float],
    cash_box: dict[str, float],
    units: dict[str, float],
    held: set[str],
    trades: list[app.Trade],
) -> dict[str, float]:
    cash = cash_box["cash"]
    fee_rate = 0.001
    slippage_rate = 0.0005
    targets = normalize(targets)
    target_symbols = set(targets)

    def portfolio_value() -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in symbols)

    pre_value = portfolio_value()
    for symbol in sorted(held - target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        execution_price = max(prices_by_symbol[symbol][index] * (1 - slippage_rate), 0.0)
        cash_amount = current_units * execution_price * (1 - fee_rate)
        cash += cash_amount
        units[symbol] = 0.0
        trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, current_units))
    held &= target_symbols

    for symbol in sorted(target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        price = prices_by_symbol[symbol][index]
        current_value = current_units * price
        target_value = pre_value * targets[symbol]
        gross_to_sell = max(current_value - target_value, 0.0)
        if gross_to_sell <= 0:
            continue
        units_to_sell = min(current_units, gross_to_sell / price)
        execution_price = max(price * (1 - slippage_rate), 0.0)
        cash_amount = units_to_sell * execution_price * (1 - fee_rate)
        cash += cash_amount
        units[symbol] = max(current_units - units_to_sell, 0.0)
        trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
        if units[symbol] <= sys.float_info.min:
            held.discard(symbol)

    total_value = portfolio_value()
    for symbol in sorted(target_symbols):
        price = prices_by_symbol[symbol][index]
        if price <= 0:
            continue
        current_value = units.get(symbol, 0.0) * price
        target_value = total_value * targets[symbol]
        amount = min(cash, max(target_value - current_value, 0.0))
        if amount <= 0:
            continue
        execution_price = price * (1 + slippage_rate)
        bought_units = amount * (1 - fee_rate) / execution_price if execution_price > 0 else 0.0
        units[symbol] = units.get(symbol, 0.0) + bought_units
        cash -= amount
        held.add(symbol)
        trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))

    cash_box["cash"] = cash
    return targets


def simulate(data: dict[str, Any], spec: VoteSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    prices_by_symbol = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    symbols: list[str] = data["tradable_symbols"]
    mas = build_mas(prices_by_symbol)
    cash_returns: list[float] = [0.0] + [app.cash_daily_return(dates[index - 1]) for index in range(1, len(dates))]

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[app.Trade] = []
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0
    invested_hits = 0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in symbols)

    for index in range(len(dates)):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * cash_returns[index]
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest
        if index == 0 or index % max(spec.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(
                spec=spec,
                symbols=symbols,
                prices_by_symbol=prices_by_symbol,
                mas=mas,
                signal_index=signal_index,
            ) if signal_index >= 0 else {}
            if targets:
                invested_hits += 1
            max_target_sum = max(max_target_sum, sum(targets.values()))
            if targets_changed(targets, active_targets):
                active_targets = rebalance_portfolio(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    symbols=symbols,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                )
        values.append(portfolio_value(index))
    return values, {"max_target_sum": max_target_sum, "invested_hits": invested_hits, "symbols": symbols}, trades


def row_for(data: dict[str, Any], spec: VoteSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
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


def specs() -> list[VoteSpec]:
    out: list[VoteSpec] = []
    window_sets = [
        (60, 120, 240),
        (80, 160, 320),
        (40, 120, 240),
    ]
    for windows in window_sets:
        for rebalance_sessions in [21, 42]:
            for top_per_window in [1, 2]:
                for min_votes in [1, 2]:
                    if min_votes > len(windows):
                        continue
                    for max_exposure in [0.90, 1.0]:
                        for per_asset_cap in [0.60, 1.0]:
                            for target_volatility in [0.12, None]:
                                for require_ma in [True]:
                                    for use_inverse_vol in [True, False]:
                                        out.append(
                                            VoteSpec(
                                                name=(
                                                    f"vote_w{'_'.join(str(item) for item in windows)}_"
                                                    f"rb{rebalance_sessions}_top{top_per_window}_mv{min_votes}_"
                                                    f"exp{int(max_exposure*100)}_cap{int(per_asset_cap*100)}_"
                                                    f"tv{int(target_volatility*100) if target_volatility else 0}_"
                                                    f"{'ma' if require_ma else 'raw'}_"
                                                    f"{'ivol' if use_inverse_vol else 'score'}"
                                                ),
                                                windows=windows,
                                                rebalance_sessions=rebalance_sessions,
                                                top_per_window=top_per_window,
                                                min_votes=min_votes,
                                                max_exposure=max_exposure,
                                                per_asset_cap=per_asset_cap,
                                                target_volatility=target_volatility,
                                                require_ma=require_ma,
                                                use_inverse_vol=use_inverse_vol,
                                            )
                                        )
    return out


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        rows: list[dict[str, Any]] = []
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Standalone multi-speed trend voting. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades")
    for row in rows[:80]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{row['extra']} | {full['trades']}"
        )


if __name__ == "__main__":
    main()
