#!/usr/bin/env python3
"""Expand quality satellite universe for the annual CORE/OSTIX framework.

Spike 074 reached Sharpe 1.607, but only at 10.22% annualized return.  This
search keeps the annual-rebalance logic fixed and looks for better quality
satellites that may preserve Sharpe while lifting annualized return.
"""
from __future__ import annotations

from datetime import datetime
import importlib.util
import itertools
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


frontier073 = load_module("atm_spike073_for_075", ROOT / "spikes/073-static-quality-income-frontier/static_quality_income_frontier.py")
scan070 = frontier073.scan070
carry = frontier073.carry


QUALITY_UNIVERSE = sorted(
    set(
        """
        AAPL MSFT COST LLY NVO ORLY AZO UNH MCD WM TMO LIN DHR AMGN PG KO PEP
        RSG CTAS CPRT ODFL FAST TJX ROST ADP PAYX SPGI MCO AON AJG MMC BRO
        SHW ECL ROP IDXX MNST WST KLAC SNPS INTU V MA
        XLP XLV FSELX FSPTX
        """.split()
    )
)

ANCHORS = [
    ("core30_ostix50_iau5_q3", {"CORE": 0.30, "OSTIX": 0.50, "IAU": 0.05}, 3),
    ("core30_ostix45_iau5_q4", {"CORE": 0.30, "OSTIX": 0.45, "IAU": 0.05}, 4),
    ("core35_ostix40_iau5_q4", {"CORE": 0.35, "OSTIX": 0.40, "IAU": 0.05}, 4),
    ("core30_ostix40_iau5_q5", {"CORE": 0.30, "OSTIX": 0.40, "IAU": 0.05}, 5),
    ("core25_ostix45_iau10_q4", {"CORE": 0.25, "OSTIX": 0.45, "IAU": 0.10}, 4),
    ("core25_ostix40_iau10_q5", {"CORE": 0.25, "OSTIX": 0.40, "IAU": 0.10}, 5),
]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def load_series() -> tuple[list[Any], dict[str, list[float | None]], dict[str, str]]:
    core = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=frontier073.END_DATE, start_date=frontier073.START_DATE.isoformat())
    raw = app.fetch_public_history(end_date=app.parse_date(frontier073.END_DATE))
    dates = core.dates
    fx_points = raw[app.USD_FX_SYMBOL]
    needed = sorted(set(QUALITY_UNIVERSE + ["OSTIX", "IAU"]))
    series: dict[str, list[float | None]] = {"CORE": [float(value) for value in core.values]}
    errors: dict[str, str] = {}
    for symbol in needed:
        try:
            usd = scan070.fetch_yahoo_adjusted(symbol)
            cny = carry.convert_usd_points_to_cny(usd, fx_points)
            series[symbol] = [carry.price_on_or_before(cny, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS) for day in dates]
        except Exception as exc:
            errors[symbol] = repr(exc)
    return dates, series, errors


def candidate_basket(anchor: dict[str, float], quality_symbols: tuple[str, ...]) -> frontier073.Basket:
    remainder = 1.0 - sum(anchor.values())
    weight = remainder / len(quality_symbols)
    weights = dict(anchor)
    for symbol in quality_symbols:
        weights[symbol] = weight
    return frontier073.Basket(dict(sorted(weights.items())))


def row_for(dates: list[Any], series: dict[str, list[float | None]], basket: frontier073.Basket, anchor_name: str, quality_symbols: tuple[str, ...]) -> dict[str, Any] | None:
    replay = frontier073.replay_annual_rebalance(dates, series, basket)
    if replay is None:
        return None
    replay_dates, replay_values, trades = replay
    row = frontier073.metric_row(basket.name, "annual_rebalance", replay_dates, replay_values, basket, trades)
    row["anchor"] = anchor_name
    row["quality_symbols"] = list(quality_symbols)
    return row


def marginal_screen(dates: list[Any], series: dict[str, list[float | None]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    anchor = {"CORE": 0.30, "OSTIX": 0.50, "IAU": 0.05}
    for symbol in QUALITY_UNIVERSE:
        if symbol not in series:
            continue
        basket = candidate_basket(anchor, (symbol,))
        row = row_for(dates, series, basket, "marginal_core30_ostix50_iau5", (symbol,))
        if row is not None:
            rows.append(row)
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    return rows


def main() -> None:
    dates, series, errors = load_series()
    marginal = marginal_screen(dates, series)
    top_symbols = []
    for row in marginal[:16]:
        symbol = row["quality_symbols"][0]
        if symbol not in top_symbols:
            top_symbols.append(symbol)
    rows: list[dict[str, Any]] = []
    for anchor_name, anchor, quality_count in ANCHORS:
        for combo in itertools.combinations(top_symbols, quality_count):
            basket = candidate_basket(anchor, combo)
            row = row_for(dates, series, basket, anchor_name, combo)
            if row is not None:
                rows.append(row)
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "errors": errors,
        "marginal": marginal,
        "top_symbols": top_symbols,
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:80],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:80],
            "annual_ge_13": [row for row in rows if row["full"]["annualized"] >= 0.13][:80],
            "sharpe_ge_16": [row for row in rows if (row["full"]["sharpe"] or 0.0) >= 1.6][:80],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print(f"top symbols: {', '.join(top_symbols)}")
    for row in rows[:60]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | {row['anchor']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
