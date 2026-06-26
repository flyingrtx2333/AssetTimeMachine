#!/usr/bin/env python3
"""USD-cash defensive sleeve probe using App-style usd_cash construction."""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SPIKE = ROOT / "spikes" / "081-paper-inspired-high-sharpe" / "paper_inspired_high_sharpe.py"
spec = importlib.util.spec_from_file_location("paper", SPIKE)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load {SPIKE}")
paper = importlib.util.module_from_spec(spec)
sys.modules["paper"] = paper
spec.loader.exec_module(paper)

app_only = paper.app_only
Context = app_only.Context

USD = "usd_cash"
SYMBOLS = app_only.CORE_FULL_HISTORY + [USD]
EQUITIES = paper.EQUITIES
GOLD = paper.GOLD


def prepare_points_with_usd(raw):
    points = app_only.prepare_points(raw)
    usd_points = []
    for day, rate in raw["usd_per_cny"]:
        if day >= app_only.START and rate > 0:
            usd_points.append((day, 1 / rate if rate < 1 else rate))
    points[USD] = usd_points
    return points


def usd_ok(ctx: Context, index: int, lookback: int = 40, ma_period: int = 80, hurdle_scale: float = 1.0) -> bool:
    momentum = ctx.mom(USD, index, lookback)
    if momentum is None:
        return False
    hurdle = 0.0035 * lookback / 252 * hurdle_scale
    prices = ctx.prices[USD]
    if index - ma_period + 1 < 0:
        return False
    moving_average = sum(prices[index - ma_period + 1 : index + 1]) / ma_period
    return momentum > hurdle and prices[index] >= moving_average


def defensive_score(ctx: Context, symbol: str, index: int, lookbacks, weights) -> float:
    if symbol == USD:
        momentum = ctx.mom(USD, index, 40)
        vol = ctx.vol(USD, index, 60)
        return max(momentum or 0, 0) / max(vol or 0.05, 0.01)
    return paper.symbol_score(ctx, symbol, index, lookbacks, weights)


def make_target(cfg):
    lookbacks = cfg["lookbacks"]
    weights = cfg["weights"]

    def target(ctx: Context, index: int, _day: date, values, _current):
        weak = 0
        for symbol in cfg["canaries"]:
            if not paper.trend_ok(ctx, symbol, index, cfg["canary_ma"], lookbacks, weights, cfg["canary_th"]):
                weak += 1
        risk_on = weak <= cfg["weak_allowed"]

        target_weights = {}
        if risk_on:
            ranked = paper.ranked_symbols(
                ctx,
                EQUITIES,
                index,
                lookbacks=lookbacks,
                momentum_weights=weights,
                ma_period=cfg["asset_ma"],
                threshold=cfg["asset_th"],
            )[: cfg["top_n"]]
            if ranked:
                target_weights.update(paper.inverse_vol_budget(
                    ctx,
                    ranked,
                    index,
                    cfg["offensive_weight"],
                    cfg["per_asset_cap"],
                ))
            if paper.trend_ok(ctx, GOLD, index, 120, lookbacks, weights, cfg["gold_th"]):
                target_weights[GOLD] = target_weights.get(GOLD, 0.0) + cfg["gold_ballast"]
            if usd_ok(ctx, index, hurdle_scale=cfg["usd_hurdle_scale"]):
                idle = max(0.0, cfg["max_exposure"] - sum(target_weights.values()))
                target_weights[USD] = min(idle, cfg["usd_idle_cap"])
        else:
            choices = []
            if paper.trend_ok(ctx, GOLD, index, 120, lookbacks, weights, cfg["gold_th"]):
                choices.append(GOLD)
            if usd_ok(ctx, index, hurdle_scale=cfg["usd_hurdle_scale"]):
                choices.append(USD)
            if choices:
                raw_scores = {symbol: max(defensive_score(ctx, symbol, index, lookbacks, weights), 0.0001) for symbol in choices}
                total = sum(raw_scores.values())
                for symbol, score in raw_scores.items():
                    target_weights[symbol] = cfg["defensive_weight"] * score / total

        weighted_vol = paper.estimate_weighted_vol(ctx, target_weights, index)
        if weighted_vol > cfg["target_vol"] and weighted_vol > 0:
            target_weights = paper.scaled(target_weights, cfg["target_vol"] / weighted_vol)
        if paper.current_portfolio_drawdown(values, 90) < -cfg["drawdown_cut"]:
            target_weights = paper.scaled(target_weights, cfg["drawdown_scale"])
        return paper.normalize(target_weights, cfg["max_exposure"])

    return target


def pct(value):
    return "n/a" if value is None else f"{value * 100:.2f}%"


def compact(row):
    full = row["full"]
    return {
        "name": row["name"],
        "thesis": row["thesis"],
        "annualized": full["annualized"],
        "max_drawdown": full["max_drawdown"],
        "volatility": full["volatility"],
        "sharpe": full["sharpe"],
        "slices": row["slices"],
        "trades": row["trades"],
        "average_exposure": row["average_exposure"],
        "latest_weights": row["latest_weights"],
    }


def main():
    raw = app_only.fetch_history()
    points = prepare_points_with_usd(raw)
    dates, prices = app_only.align(points, SYMBOLS)
    ctx = Context(dates, prices)

    momentum_sets = [
        ((21, 63, 126, 252), (12.0, 4.0, 2.0, 1.0)),
        ((63, 126, 252), (4.0, 2.0, 1.0)),
    ]
    canary_sets = [
        ["nasdaq", "sp500"],
        ["nasdaq", "sp500", "csi300", "shanghai_composite"],
    ]
    rows = app_only.run_baselines()
    evaluated = 0
    for lookbacks, weights in momentum_sets:
        for canaries in canary_sets:
            for weak_allowed in [0, 1]:
                for top_n in [1, 2]:
                    for offensive_weight in [0.60, 0.75]:
                        for gold_ballast in [0.15, 0.25]:
                            for defensive_weight in [0.65, 0.98]:
                                for usd_idle_cap in [0.60, 0.98]:
                                    for target_vol in [0.095, 0.11, 0.13]:
                                        if offensive_weight + gold_ballast > 0.98:
                                            continue
                                        cfg = {
                                            "lookbacks": lookbacks,
                                            "weights": weights,
                                            "canaries": canaries,
                                            "weak_allowed": weak_allowed,
                                            "top_n": top_n,
                                            "offensive_weight": offensive_weight,
                                            "gold_ballast": gold_ballast,
                                            "defensive_weight": defensive_weight,
                                            "usd_idle_cap": usd_idle_cap,
                                            "target_vol": target_vol,
                                            "max_exposure": 0.98,
                                            "per_asset_cap": 0.60,
                                            "drawdown_cut": 0.06,
                                            "drawdown_scale": 0.65,
                                            "canary_ma": 200,
                                            "asset_ma": 200,
                                            "canary_th": 0.0,
                                            "asset_th": 0.0,
                                            "gold_th": -0.01,
                                            "usd_hurdle_scale": 1.0,
                                        }
                                        target = make_target(cfg)
                                        base_name = (
                                            f"usd_def_can{len(canaries)}_weak{weak_allowed}_top{top_n}_"
                                            f"off{int(offensive_weight * 100)}_gold{int(gold_ballast * 100)}_"
                                            f"def{int(defensive_weight * 100)}_uidle{int(usd_idle_cap * 100)}_"
                                            f"tv{int(target_vol * 1000)}"
                                        )
                                        for rebalance in [60, 120]:
                                            for band in [0.10]:
                                                result = app_only.simulate(
                                                    f"{base_name}_reb{rebalance}_band{int(band * 100)}",
                                                    "US dollar cash as trend-confirmed idle/risk-off defense.",
                                                    ctx,
                                                    target,
                                                    rebalance,
                                                    band,
                                                )
                                                rows.append(app_only.summarize(result))
                                                evaluated += 1
                                                if evaluated % 500 == 0:
                                                    print(f"evaluated {evaluated}", flush=True)

    rows.sort(
        key=lambda row: (
            row["full"]["sharpe"] or -99,
            row["full"]["annualized"] or -99,
        ),
        reverse=True,
    )
    sharpe_12 = [row for row in rows if (row["full"]["sharpe"] or -99) >= 1.2]
    high_return = sorted(
        [row for row in rows if (row["full"]["annualized"] or -99) >= 0.10],
        key=lambda row: row["full"]["sharpe"] or -99,
        reverse=True,
    )
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "coverage": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "points": len(dates)},
        "evaluated": evaluated,
        "symbols": SYMBOLS,
        "top_by_sharpe": [compact(row) for row in rows[:30]],
        "sharpe_12": [compact(row) for row in sharpe_12[:30]],
        "high_return_ann10": [compact(row) for row in high_return[:30]],
    }
    out_path = Path(__file__).with_name("currency_results.json")
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))
    print(f"WROTE {out_path}")
    print(f"COVERAGE {dates[0]}..{dates[-1]} points={len(dates)} evaluated={evaluated}")
    print(f"SHARPE>=1.2 {len(sharpe_12)}")
    print("name | ann | dd | vol | sharpe | post2020 ann/dd | trades | avg exposure | latest")
    for row in rows[:20]:
        full = row["full"]
        p20 = row["slices"]["post_2020"]
        print(
            f"{row['name']} | {pct(full['annualized'])} | {pct(full['max_drawdown'])} | "
            f"{pct(full['volatility'])} | {full['sharpe']:.3f} | "
            f"{pct(p20['annualized']) if p20 else 'n/a'}/{pct(p20['max_drawdown']) if p20 else 'n/a'} | "
            f"{row['trades']} | {row['average_exposure']} | {row['latest_weights']}"
        )


if __name__ == "__main__":
    main()
