#!/usr/bin/env python3
"""Paper-inspired App-only high-Sharpe strategy search.

This spike is intentionally mechanism-first:
- dual momentum: relative ranking plus absolute trend filter
- DAA/PAA: breadth-based crash protection
- volatility management: lower exposure when volatility is high, with no leverage
- Faber TAA: long moving-average gate to cash

It imports the spike080 App-only harness for data preparation, cash yield,
fees/slippage, and metrics so the result is comparable to current App-equivalent
research. A winning candidate still needs Swift BacktestEngine replay before
product use.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
BASE_SPIKE = ROOT / "spikes" / "080-app-only-high-sharpe-logic" / "search_app_only_logic.py"
spec = importlib.util.spec_from_file_location("app_only", BASE_SPIKE)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load {BASE_SPIKE}")
app_only = importlib.util.module_from_spec(spec)
sys.modules["app_only"] = app_only
spec.loader.exec_module(app_only)

Context = app_only.Context
Result = app_only.Result

ALL = app_only.CORE_FULL_HISTORY
US = app_only.US
CHINA = app_only.CHINA[:-1]
GLOBAL = app_only.GLOBAL
EQUITIES = US + CHINA + GLOBAL
GOLD = "gold_cny"

TargetFn = Callable[[Context, int, date, list[float], dict[str, float]], dict[str, float]]


@dataclass(frozen=True)
class CandidateSpec:
    name: str
    thesis: str
    rebalance: int
    band: float
    target_fn: TargetFn


def multi_momentum(ctx: Context, symbol: str, index: int, lookbacks: tuple[int, ...], weights: tuple[float, ...]) -> float | None:
    total = 0.0
    weight_sum = 0.0
    for lookback, weight in zip(lookbacks, weights):
        value = ctx.mom(symbol, index, lookback)
        if value is None:
            return None
        total += value * weight
        weight_sum += weight
    return total / weight_sum if weight_sum > 0 else None


def trend_ok(ctx: Context, symbol: str, index: int, ma_period: int, lookbacks: tuple[int, ...], weights: tuple[float, ...], threshold: float) -> bool:
    mm = multi_momentum(ctx, symbol, index, lookbacks, weights)
    return mm is not None and mm > threshold and ctx.above_ma(symbol, index, ma_period)


def symbol_score(ctx: Context, symbol: str, index: int, lookbacks: tuple[int, ...], weights: tuple[float, ...]) -> float:
    mm = multi_momentum(ctx, symbol, index, lookbacks, weights)
    vol = ctx.vol(symbol, index, 60)
    if mm is None or mm <= 0:
        return 0.0
    return mm / max(vol or 0.25, 0.04)


def normalize(weights: dict[str, float], cap: float) -> dict[str, float]:
    return app_only.normalize(weights, cap)


def scaled(weights: dict[str, float], factor: float) -> dict[str, float]:
    return {symbol: weight * factor for symbol, weight in weights.items() if weight * factor > 0.0001}


def current_portfolio_drawdown(values: list[float], lookback: int) -> float:
    if not values:
        return 0.0
    return app_only.rolling_drawdown(values, len(values) - 1, min(lookback, len(values)))


def inverse_vol_budget(ctx: Context, symbols: list[str], index: int, budget: float, per_asset_cap: float) -> dict[str, float]:
    inv = {}
    for symbol in symbols:
        vol = ctx.vol(symbol, index, 60)
        inv[symbol] = 1.0 / max(vol or 0.25, 0.05)
    total = sum(inv.values())
    if total <= 0:
        return {}
    raw = {symbol: min(per_asset_cap, budget * value / total) for symbol, value in inv.items()}
    leftover = budget - sum(raw.values())
    if leftover > 0.0001:
        uncapped = {symbol: inv[symbol] for symbol in symbols if raw[symbol] < per_asset_cap - 0.0001}
        uncapped_total = sum(uncapped.values())
        if uncapped_total > 0:
            for symbol, value in uncapped.items():
                raw[symbol] += leftover * value / uncapped_total
    return normalize(raw, budget)


def estimate_weighted_vol(ctx: Context, weights: dict[str, float], index: int) -> float:
    # Conservative diagonal-vol estimate: no diversification credit.
    return sum(weight * max(ctx.vol(symbol, index, 60) or 0.25, 0.05) for symbol, weight in weights.items())


def ranked_symbols(
    ctx: Context,
    symbols: list[str],
    index: int,
    *,
    lookbacks: tuple[int, ...],
    momentum_weights: tuple[float, ...],
    ma_period: int,
    threshold: float,
) -> list[str]:
    rows = []
    for symbol in symbols:
        if not trend_ok(ctx, symbol, index, ma_period, lookbacks, momentum_weights, threshold):
            continue
        score = symbol_score(ctx, symbol, index, lookbacks, momentum_weights)
        if score > 0:
            rows.append((score, symbol))
    rows.sort(reverse=True)
    return [symbol for _score, symbol in rows]


def make_daa_breadth_vol(
    *,
    name: str,
    canaries: list[str],
    offensive: list[str],
    lookbacks: tuple[int, ...],
    momentum_weights: tuple[float, ...],
    canary_ma: int,
    asset_ma: int,
    top_n: int,
    weak_allowed: int,
    max_exposure: float,
    max_defensive_gold: float,
    target_vol: float,
    per_asset_cap: float,
    drawdown_cut: float,
) -> tuple[str, TargetFn]:
    def target(ctx: Context, index: int, _day: date, values: list[float], _current: dict[str, float]) -> dict[str, float]:
        weak = 0
        for symbol in canaries:
            if not trend_ok(ctx, symbol, index, canary_ma, lookbacks, momentum_weights, 0.0):
                weak += 1

        weak_excess = max(0, weak - weak_allowed)
        crash_ratio = min(1.0, weak_excess / max(len(canaries) - weak_allowed, 1))
        risk_budget = max_exposure * (1.0 - crash_ratio)
        defensive_budget = max_exposure - risk_budget

        selected = ranked_symbols(
            ctx,
            offensive,
            index,
            lookbacks=lookbacks,
            momentum_weights=momentum_weights,
            ma_period=asset_ma,
            threshold=0.0,
        )[:top_n]

        weights: dict[str, float] = {}
        if selected and risk_budget > 0:
            weights.update(inverse_vol_budget(ctx, selected, index, risk_budget, per_asset_cap))

        gold_ok = trend_ok(ctx, GOLD, index, 120, lookbacks, momentum_weights, -0.01)
        if defensive_budget > 0 and gold_ok:
            weights[GOLD] = weights.get(GOLD, 0.0) + min(defensive_budget, max_defensive_gold)

        gross = sum(weights.values())
        weighted_vol = estimate_weighted_vol(ctx, weights, index)
        if weighted_vol > target_vol and weighted_vol > 0:
            weights = scaled(weights, target_vol / weighted_vol)

        if drawdown_cut > 0 and current_portfolio_drawdown(values, 90) < -drawdown_cut:
            weights = scaled(weights, 0.65)

        return normalize(weights, max_exposure)

    return name, target


def make_dual_momentum_vol_target(
    *,
    name: str,
    universe: list[str],
    lookbacks: tuple[int, ...],
    momentum_weights: tuple[float, ...],
    ma_period: int,
    top_n: int,
    target_vol: float,
    max_exposure: float,
    per_asset_cap: float,
    gold_floor: float,
    canary: str,
) -> tuple[str, TargetFn]:
    def target(ctx: Context, index: int, _day: date, values: list[float], _current: dict[str, float]) -> dict[str, float]:
        risk_on = trend_ok(ctx, canary, index, ma_period, lookbacks, momentum_weights, 0.0)
        symbols = ranked_symbols(
            ctx,
            universe,
            index,
            lookbacks=lookbacks,
            momentum_weights=momentum_weights,
            ma_period=ma_period,
            threshold=0.0,
        )[:top_n]
        weights: dict[str, float] = {}
        if risk_on and symbols:
            weights.update(inverse_vol_budget(ctx, symbols, index, max_exposure, per_asset_cap))
        if trend_ok(ctx, GOLD, index, 120, lookbacks, momentum_weights, -0.01):
            weights[GOLD] = max(weights.get(GOLD, 0.0), gold_floor)

        weighted_vol = estimate_weighted_vol(ctx, weights, index)
        if weighted_vol > target_vol and weighted_vol > 0:
            weights = scaled(weights, target_vol / weighted_vol)
        if current_portfolio_drawdown(values, 120) < -0.06:
            weights = scaled(weights, 0.60)
        return normalize(weights, max_exposure)

    return name, target


def make_faber_cluster_taa(
    *,
    name: str,
    cluster_budgets: dict[str, float],
    ma_period: int,
    lookbacks: tuple[int, ...],
    momentum_weights: tuple[float, ...],
    max_exposure: float,
    target_vol: float,
) -> tuple[str, TargetFn]:
    clusters = {
        "gold": [GOLD],
        "us": US,
        "china": CHINA,
        "global": GLOBAL,
    }

    def target(ctx: Context, index: int, _day: date, values: list[float], _current: dict[str, float]) -> dict[str, float]:
        weights: dict[str, float] = {}
        for cluster_name, budget in cluster_budgets.items():
            symbols = ranked_symbols(
                ctx,
                clusters[cluster_name],
                index,
                lookbacks=lookbacks,
                momentum_weights=momentum_weights,
                ma_period=ma_period if cluster_name != "gold" else 120,
                threshold=-0.005 if cluster_name == "gold" else 0.0,
            )
            if not symbols:
                continue
            weights.update({
                **weights,
                **{
                    symbol: weights.get(symbol, 0.0) + weight
                    for symbol, weight in inverse_vol_budget(ctx, symbols[:2], index, budget, budget).items()
                },
            })
        weighted_vol = estimate_weighted_vol(ctx, weights, index)
        if weighted_vol > target_vol and weighted_vol > 0:
            weights = scaled(weights, target_vol / weighted_vol)
        if current_portfolio_drawdown(values, 90) < -0.05:
            weights = scaled(weights, 0.70)
        return normalize(weights, max_exposure)

    return name, target


def build_candidates() -> list[CandidateSpec]:
    candidates: list[CandidateSpec] = []
    momentum_sets = [
        ((21, 63, 126, 252), (12.0, 4.0, 2.0, 1.0)),
        ((63, 126, 252), (4.0, 2.0, 1.0)),
        ((42, 84, 168), (6.0, 3.0, 1.0)),
    ]
    canary_sets = [
        ["nasdaq", "sp500"],
        ["nasdaq", "sp500", "dowjones"],
        ["nasdaq", "sp500", "csi300", "shanghai_composite"],
        ["nasdaq", "sp500", "hsi", "nikkei"],
    ]
    for lookbacks, weights in momentum_sets:
        for canaries in canary_sets:
            for weak_allowed in [0, 1]:
                for top_n in [1, 2, 3]:
                    for target_vol in [0.075, 0.085, 0.095, 0.105]:
                        name, fn = make_daa_breadth_vol(
                            name=(
                                f"daa_vol_can{len(canaries)}_weak{weak_allowed}_"
                                f"top{top_n}_tv{int(target_vol * 1000)}"
                            ),
                            canaries=canaries,
                            offensive=EQUITIES,
                            lookbacks=lookbacks,
                            momentum_weights=weights,
                            canary_ma=200,
                            asset_ma=200,
                            top_n=top_n,
                            weak_allowed=weak_allowed,
                            max_exposure=0.98,
                            max_defensive_gold=0.55,
                            target_vol=target_vol,
                            per_asset_cap=0.55,
                            drawdown_cut=0.055,
                        )
                        for rebalance in [20, 40, 60]:
                            for band in [0.02, 0.05, 0.10]:
                                candidates.append(CandidateSpec(
                                    name=f"{name}_reb{rebalance}_band{int(band * 100)}",
                                    thesis="DAA/PAA breadth crash protection plus non-levered volatility management.",
                                    rebalance=rebalance,
                                    band=band,
                                    target_fn=fn,
                                ))

    for lookbacks, weights in momentum_sets:
        for top_n in [1, 2, 3]:
            for target_vol in [0.075, 0.085, 0.095, 0.105, 0.115]:
                for gold_floor in [0.0, 0.15, 0.25]:
                    name, fn = make_dual_momentum_vol_target(
                        name=f"dual_vol_top{top_n}_tv{int(target_vol * 1000)}_gold{int(gold_floor * 100)}",
                        universe=EQUITIES,
                        lookbacks=lookbacks,
                        momentum_weights=weights,
                        ma_period=200,
                        top_n=top_n,
                        target_vol=target_vol,
                        max_exposure=0.98,
                        per_asset_cap=0.60,
                        gold_floor=gold_floor,
                        canary="sp500",
                    )
                    for rebalance in [20, 40, 60, 120]:
                        for band in [0.02, 0.05, 0.10]:
                            candidates.append(CandidateSpec(
                                name=f"{name}_reb{rebalance}_band{int(band * 100)}",
                                thesis="Dual momentum with absolute trend gate and non-levered volatility target.",
                                rebalance=rebalance,
                                band=band,
                                target_fn=fn,
                            ))

    cluster_sets = [
        {"gold": 0.40, "us": 0.35, "china": 0.15, "global": 0.10},
        {"gold": 0.35, "us": 0.45, "china": 0.10, "global": 0.10},
        {"gold": 0.50, "us": 0.30, "china": 0.10, "global": 0.10},
        {"gold": 0.30, "us": 0.50, "china": 0.10, "global": 0.10},
    ]
    for budgets in cluster_sets:
        for lookbacks, weights in momentum_sets:
            for target_vol in [0.075, 0.085, 0.095, 0.105]:
                name, fn = make_faber_cluster_taa(
                    name=(
                        "faber_cluster_"
                        + "_".join(f"{key}{int(value * 100)}" for key, value in budgets.items())
                        + f"_tv{int(target_vol * 1000)}"
                    ),
                    cluster_budgets=budgets,
                    ma_period=200,
                    lookbacks=lookbacks,
                    momentum_weights=weights,
                    max_exposure=0.98,
                    target_vol=target_vol,
                )
                for rebalance in [20, 40, 60, 120]:
                    for band in [0.02, 0.05, 0.10]:
                        candidates.append(CandidateSpec(
                            name=f"{name}_reb{rebalance}_band{int(band * 100)}",
                            thesis="Faber-style cluster TAA with cash for failed trend sleeves.",
                            rebalance=rebalance,
                            band=band,
                            target_fn=fn,
                        ))
    return candidates


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def compact_metric(metric: dict[str, float | None] | None) -> dict[str, float | None] | None:
    if metric is None:
        return None
    return {key: round(value, 6) if isinstance(value, float) else value for key, value in metric.items()}


def row_for_result(result: Result) -> dict[str, object]:
    return app_only.summarize(result)


def main() -> None:
    raw = app_only.fetch_history()
    points = app_only.prepare_points(raw)
    dates, prices = app_only.align(points, app_only.CORE_FULL_HISTORY)
    ctx = Context(dates, prices)
    specs = build_candidates()

    rows = app_only.run_baselines()
    for index, spec_item in enumerate(specs, 1):
        result = app_only.simulate(
            spec_item.name,
            spec_item.thesis,
            ctx,
            spec_item.target_fn,
            spec_item.rebalance,
            spec_item.band,
        )
        rows.append(row_for_result(result))
        if index % 250 == 0:
            print(f"evaluated {index}/{len(specs)}", flush=True)

    rows.sort(
        key=lambda row: (
            row["full"]["sharpe"] or -99,  # type: ignore[index]
            row["full"]["annualized"] or -99,  # type: ignore[index]
        ),
        reverse=True,
    )

    sharpe_12 = [
        row for row in rows
        if (row["full"]["sharpe"] or -99) >= 1.2  # type: ignore[index]
    ]
    practical = [
        row for row in rows
        if (row["full"]["sharpe"] or -99) >= 1.2  # type: ignore[index]
        and (row["full"]["annualized"] or -99) >= 0.08  # type: ignore[index]
    ]
    high_return = sorted(
        [row for row in rows if (row["full"]["annualized"] or -99) >= 0.10],  # type: ignore[index]
        key=lambda row: row["full"]["sharpe"] or -99,  # type: ignore[index]
        reverse=True,
    )

    output = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "constraints": {
            "assets": app_only.CORE_FULL_HISTORY,
            "fee_rate": app_only.FEE_RATE,
            "slippage": app_only.SLIPPAGE,
            "no_leverage": True,
            "no_external_tickers": True,
            "sources": [
                "Antonacci dual momentum / Risk Premia Harvesting Through Dual Momentum",
                "Keller and Keuning PAA/DAA breadth momentum",
                "Moreira and Muir Volatility-Managed Portfolios",
                "Faber Quantitative Approach to Tactical Asset Allocation",
            ],
        },
        "coverage": {
            "start": dates[0].isoformat(),
            "end": dates[-1].isoformat(),
            "points": len(dates),
        },
        "evaluated": len(specs),
        "top_by_sharpe": rows[:30],
        "sharpe_12": sharpe_12[:30],
        "practical_sharpe_12_ann8": practical[:30],
        "high_return_ann10": high_return[:30],
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(f"WROTE {out_path}")
    print(f"COVERAGE {dates[0]}..{dates[-1]} points={len(dates)} evaluated={len(specs)}")
    print(f"SHARPE>=1.2 {len(sharpe_12)} practical_ann>=8% {len(practical)}")
    print("name | ann | dd | vol | sharpe | post2020 ann/dd | trades | avg exposure | latest")
    for row in rows[:20]:
        full = row["full"]  # type: ignore[assignment]
        p20 = row["slices"]["post_2020"]  # type: ignore[index]
        latest = row["latest_weights"]
        print(
            f"{row['name']} | {pct(full['annualized'])} | {pct(full['max_drawdown'])} | "
            f"{pct(full['volatility'])} | {full['sharpe']:.3f} | "
            f"{pct(p20['annualized']) if p20 else 'n/a'}/{pct(p20['max_drawdown']) if p20 else 'n/a'} | "
            f"{row['trades']} | {row['average_exposure']} | {latest}"
        )


if __name__ == "__main__":
    main()
