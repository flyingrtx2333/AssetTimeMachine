#!/usr/bin/env python3
"""Deterministic app-only static allocation frontier.

This checks whether the current app asset universe has a low-turnover permanent
portfolio that beats dynamic rotation after the 1% default fee.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import itertools
import json
import math
from pathlib import Path
import random
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import search_app_only_logic as logic


@dataclass(frozen=True)
class Portfolio:
    weights: dict[str, float]
    rebalance_sessions: int
    band: float
    values: list[float]
    trades: int


def simulate_static(ctx: logic.Context, weights: dict[str, float], rebalance_sessions: int, band: float) -> Portfolio:
    cash = logic.INITIAL
    units = {symbol: 0.0 for symbol in ctx.prices}
    values: list[float] = []
    trades = 0
    last_rebalance = -10**9

    def value_at(index: int) -> float:
        return cash + sum(units[symbol] * ctx.prices[symbol][index] for symbol in ctx.prices)

    for index, day in enumerate(ctx.dates):
        if index > 0 and cash > 0:
            cash += cash * logic.app.cash_daily_return(ctx.dates[index - 1])
        current_value = value_at(index)
        if index == 0 or index - last_rebalance >= rebalance_sessions:
            held = {symbol for symbol, unit in units.items() if unit > 0}
            targets = logic.normalize(weights, 1.0)
            for symbol in sorted(held - set(targets)):
                price = ctx.prices[symbol][index] * (1 - logic.SLIPPAGE)
                cash += units[symbol] * price * (1 - logic.FEE_RATE)
                units[symbol] = 0.0
                trades += 1
            for symbol, target_weight in sorted(targets.items()):
                price = ctx.prices[symbol][index]
                current_position = units[symbol] * price
                target_position = current_value * target_weight
                if current_position > target_position * (1 + band):
                    sell_value = current_position - target_position
                    sell_units = min(units[symbol], sell_value / price)
                    cash += sell_units * price * (1 - logic.SLIPPAGE) * (1 - logic.FEE_RATE)
                    units[symbol] -= sell_units
                    trades += 1
            current_value = value_at(index)
            for symbol, target_weight in sorted(targets.items()):
                price = ctx.prices[symbol][index]
                current_position = units[symbol] * price
                target_position = current_value * target_weight
                if current_position < target_position * (1 - band):
                    amount = min(cash, target_position - current_position)
                    units[symbol] += amount * (1 - logic.FEE_RATE) / (price * (1 + logic.SLIPPAGE))
                    cash -= amount
                    trades += 1
            last_rebalance = index
        values.append(value_at(index))
    return Portfolio(weights, rebalance_sessions, band, values, trades)


def summarize(ctx: logic.Context, portfolio: Portfolio) -> dict[str, object]:
    metrics = logic.performance(ctx.dates, portfolio.values)
    return {
        "weights": portfolio.weights,
        "rebalance_sessions": portfolio.rebalance_sessions,
        "band": portfolio.band,
        "trades": portfolio.trades,
        "full": metrics,
        "slices": {
            "post_2020": logic.slice_metrics(ctx.dates, portfolio.values, date(2020, 1, 1)),
            "last_10y": logic.slice_metrics(ctx.dates, portfolio.values, date(ctx.dates[-1].year - 10, ctx.dates[-1].month, ctx.dates[-1].day)),
            "post_2022": logic.slice_metrics(ctx.dates, portfolio.values, date(2022, 1, 1)),
            "post_2024": logic.slice_metrics(ctx.dates, portfolio.values, date(2024, 1, 1)),
        },
    }


def candidate_weights(symbols: list[str]) -> list[dict[str, float]]:
    out: list[dict[str, float]] = []
    # Structured baskets first: gold + US growth + broad US + optional China/global diversifier + cash.
    for gold in [0.30, 0.40, 0.50, 0.60]:
        for nasdaq in [0.20, 0.30, 0.40]:
            for sp500 in [0.0, 0.10, 0.20]:
                for china in [0.0, 0.10]:
                    for global_weight in [0.0, 0.05]:
                        total = gold + nasdaq + sp500 + china + global_weight
                        if total > 1.0:
                            continue
                        weights = {"gold_cny": gold, "nasdaq": nasdaq}
                        if sp500:
                            weights["sp500"] = sp500
                        if china:
                            weights["shanghai_composite"] = china * 0.5
                            weights["csi300"] = china * 0.5
                        if global_weight:
                            weights["hsi"] = global_weight * 0.5
                            weights["nikkei"] = global_weight * 0.5
                        out.append({k: v for k, v in weights.items() if v > 0})

    rng = random.Random(20260625)
    liquid = ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "hsi", "nikkei"]
    for _ in range(200):
        picked = [symbol for symbol in liquid if rng.random() < 0.45]
        if "gold_cny" not in picked:
            picked.append("gold_cny")
        if not any(symbol in picked for symbol in ["nasdaq", "sp500", "dowjones"]):
            picked.append("sp500")
        raw = {symbol: rng.random() ** 1.5 for symbol in picked}
        total_raw = sum(raw.values())
        exposure = rng.choice([0.55, 0.65, 0.75, 0.85, 0.95, 1.0])
        weights = {symbol: exposure * value / total_raw for symbol, value in raw.items()}
        if weights.get("gold_cny", 0) > 0.72 or max(weights.values()) > 0.70:
            continue
        out.append(weights)

    dedup: dict[tuple[tuple[str, int], ...], dict[str, float]] = {}
    for weights in out:
        key = tuple(sorted((symbol, round(weight * 100)) for symbol, weight in weights.items() if weight > 0.005))
        dedup[key] = weights
    return list(dedup.values())


def main() -> None:
    raw = logic.fetch_history()
    points = logic.prepare_points(raw)
    dates, prices = logic.align(points, logic.CORE_FULL_HISTORY)
    ctx = logic.Context(dates, prices)
    weights_list = candidate_weights(logic.CORE_FULL_HISTORY)
    rows = []
    for weights in weights_list:
        for rebalance in [126, 252, 99999]:
            for band in [0.05, 0.10]:
                portfolio = simulate_static(ctx, weights, rebalance, band)
                row = summarize(ctx, portfolio)
                rows.append(row)
    rows.sort(key=lambda row: ((row["full"]["sharpe"] or -9), (row["full"]["annualized"] or -9)), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("static_results.json")
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "coverage": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "points": len(dates)},
        "evaluated": len(rows),
        "rows": rows[:300],
    }
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))
    print(f"WROTE {out_path}")
    print("rank | ann | dd | vol | sharpe | post2020 ann/dd | trades | reb/band | weights")
    for rank, row in enumerate(rows[:25], 1):
        full = row["full"]
        p20 = row["slices"]["post_2020"]
        print(
            rank,
            logic.pct(full["annualized"]),
            logic.pct(full["max_drawdown"]),
            logic.pct(full["volatility"]),
            f"{full['sharpe']:.3f}",
            f"{logic.pct(p20['annualized'])}/{logic.pct(p20['max_drawdown'])}" if p20 else "n/a",
            row["trades"],
            row["rebalance_sessions"],
            row["band"],
            {k: round(v, 3) for k, v in row["weights"].items()},
        )


if __name__ == "__main__":
    main()
