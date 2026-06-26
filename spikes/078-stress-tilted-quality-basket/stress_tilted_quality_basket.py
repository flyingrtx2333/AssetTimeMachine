#!/usr/bin/env python3
"""Stress-tilted variant of the annual quality/core basket.

This tests a new overlay on top of spike 074: keep the same long-only basket,
but when the CORE or quality sleeve enters a stress state, temporarily move a
portion of CORE/quality exposure into OSTIX and IAU.  The goal is to improve the
12% annualized frontier without leverage.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


frontier073 = load_module("atm_spike073_for_078", ROOT / "spikes/073-static-quality-income-frontier/static_quality_income_frontier.py")
app = frontier073.app


BASE_BASKETS = [
    ("max_sharpe", {"OSTIX": 0.50, "CORE": 0.30, "IAU": 0.05, "AAPL": 0.05, "LLY": 0.05, "ORLY": 0.05}),
    ("middle", {"OSTIX": 0.45, "CORE": 0.30, "IAU": 0.05, "AAPL": 0.10, "LLY": 0.05, "ORLY": 0.05}),
    ("annual12", {"OSTIX": 0.40, "CORE": 0.35, "IAU": 0.05, "AAPL": 0.10, "LLY": 0.05, "ORLY": 0.05}),
    ("annual1230", {"OSTIX": 0.40, "CORE": 0.30, "IAU": 0.05, "AAPL": 0.10, "COST": 0.05, "LLY": 0.05, "ORLY": 0.05}),
]


@dataclass(frozen=True)
class TiltSpec:
    name: str
    review_sessions: int
    core_dd_threshold: float
    quality_dd_threshold: float
    core_cut: float
    quality_cut: float
    redeploy_to_gold: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def trailing_return(values: list[float | None], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    current = values[index]
    previous = values[index - lookback]
    if current is None or previous is None or current <= 0 or previous <= 0:
        return None
    return current / previous - 1


def trailing_drawdown(values: list[float | None], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1 : index + 1]
    if any(item is None or item <= 0 for item in window):
        return None
    peak = max(float(item) for item in window)
    current = float(values[index] or 0.0)
    return current / peak - 1 if peak > 0 else None


def synthetic_quality_series(weights: dict[str, float], series: dict[str, list[float | None]]) -> list[float | None]:
    quality = {symbol: weight for symbol, weight in weights.items() if symbol not in {"OSTIX", "CORE", "IAU"}}
    total = sum(quality.values())
    if total <= 0:
        return []
    length = len(next(iter(series.values())))
    out: list[float | None] = []
    for index in range(length):
        value = 0.0
        for symbol, weight in quality.items():
            price = series[symbol][index]
            if price is None or price <= 0:
                out.append(None)
                break
            value += weight / total * float(price)
        else:
            out.append(value)
    return out


def tilted_targets(base: dict[str, float], series: dict[str, list[float | None]], quality_curve: list[float | None], index: int, spec: TiltSpec) -> dict[str, float]:
    targets = dict(base)
    core_dd = trailing_drawdown(series["CORE"], index, 126)
    core_ret = trailing_return(series["CORE"], index, 63)
    quality_dd = trailing_drawdown(quality_curve, index, 126)
    quality_ret = trailing_return(quality_curve, index, 63)
    core_stress = core_dd is not None and core_ret is not None and core_dd < -spec.core_dd_threshold and core_ret < 0
    quality_stress = quality_dd is not None and quality_ret is not None and quality_dd < -spec.quality_dd_threshold and quality_ret < 0
    moved = 0.0
    if core_stress:
        cut = min(targets.get("CORE", 0.0), spec.core_cut)
        targets["CORE"] = targets.get("CORE", 0.0) - cut
        moved += cut
    if quality_stress:
        for symbol in list(targets):
            if symbol in {"OSTIX", "CORE", "IAU"}:
                continue
            cut = targets[symbol] * spec.quality_cut
            targets[symbol] -= cut
            moved += cut
    if moved > 0:
        gold = moved * spec.redeploy_to_gold
        targets["IAU"] = targets.get("IAU", 0.0) + gold
        targets["OSTIX"] = targets.get("OSTIX", 0.0) + moved - gold
    return {symbol: weight for symbol, weight in targets.items() if weight > 0.0001}


def replay(dates: list[Any], series: dict[str, list[float | None]], base: dict[str, float], spec: TiltSpec) -> tuple[list[Any], list[float], int] | None:
    symbols = list(base)
    indices = frontier073.aligned_indices(dates, series, symbols)
    if not indices:
        return None
    cash = frontier073.INITIAL_CASH
    units = {symbol: 0.0 for symbol in symbols}
    out_dates: list[Any] = []
    values: list[float] = []
    trades = 0
    last_review = -10**9
    current_targets = dict(base)
    quality_curve = synthetic_quality_series(base, series)

    def value_at(index: int) -> float:
        total = cash
        for symbol, qty in units.items():
            price = float(series[symbol][index] or 0.0)
            if qty > 0 and price > 0:
                total += qty * price
        return total

    def rebalance_to(index: int, targets: dict[str, float]) -> None:
        nonlocal cash, trades
        current_value = value_at(index)
        for symbol in symbols:
            price = float(series[symbol][index] or 0.0)
            if price <= 0:
                continue
            current_symbol_value = units[symbol] * price
            desired = current_value * targets.get(symbol, 0.0)
            if current_symbol_value > desired * 1.08:
                qty = min(units[symbol], (current_symbol_value - desired) / price)
                if qty > 0:
                    fee = 0.0 if symbol == "CORE" else frontier073.FEE_RATE
                    cash += qty * price * (1 - frontier073.SLIPPAGE_RATE) * (1 - fee)
                    units[symbol] -= qty
                    trades += 1
        current_value = value_at(index)
        for symbol in symbols:
            price = float(series[symbol][index] or 0.0)
            if price <= 0:
                continue
            current_symbol_value = units[symbol] * price
            desired = current_value * targets.get(symbol, 0.0)
            if current_symbol_value < desired * 0.92:
                gross = desired - current_symbol_value
                fee = 0.0 if symbol == "CORE" else frontier073.FEE_RATE
                spend = min(cash, gross * (1 + frontier073.SLIPPAGE_RATE) * (1 + fee))
                if spend > 0:
                    units[symbol] += spend / ((1 + frontier073.SLIPPAGE_RATE) * (1 + fee) * price)
                    cash -= spend
                    trades += 1

    for index in indices:
        if not out_dates or index - last_review >= spec.review_sessions:
            current_targets = tilted_targets(base, series, quality_curve, max(index - 1, 0), spec)
            rebalance_to(index, current_targets)
            last_review = index
        out_dates.append(dates[index])
        values.append(value_at(index))
    return out_dates, values, trades


def row_for(dates: list[Any], series: dict[str, list[float | None]], base_name: str, base: dict[str, float], spec: TiltSpec) -> dict[str, Any] | None:
    result = replay(dates, series, base, spec)
    if result is None:
        return None
    replay_dates, values, trades = result
    basket = frontier073.Basket(dict(sorted(base.items())))
    row = frontier073.metric_row(f"{base_name}:{spec.name}", "stress_tilt", replay_dates, values, basket, trades)
    row["base_name"] = base_name
    row["spec"] = spec.__dict__
    return row


def specs() -> list[TiltSpec]:
    rows: list[TiltSpec] = []
    for review in [63, 126]:
        for core_dd in [0.08, 0.12]:
            for quality_dd in [0.10, 0.15]:
                for core_cut in [0.05, 0.10]:
                    for quality_cut in [0.35, 0.60]:
                        for gold_share in [0.25, 0.50]:
                            name = f"r{review}_cdd{int(core_dd*100)}_qdd{int(quality_dd*100)}_cc{int(core_cut*100)}_qc{int(quality_cut*100)}_g{int(gold_share*100)}"
                            rows.append(TiltSpec(name, review, core_dd, quality_dd, core_cut, quality_cut, gold_share))
    return rows


def main() -> None:
    dates, series, errors = frontier073.load_series()
    rows: list[dict[str, Any]] = []
    for base_name, base in BASE_BASKETS:
        for spec in specs():
            row = row_for(dates, series, base_name, base, spec)
            if row is not None:
                rows.append(row)
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "errors": errors,
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:80],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:80],
            "sharpe_ge_16": [row for row in rows if (row["full"]["sharpe"] or 0.0) >= 1.6][:80],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    for row in rows[:70]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
