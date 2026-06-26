#!/usr/bin/env python3
"""Structured annual-rebalance search around the promising quality/core logic.

This follows spike 073.  It is not retuning the gold-handoff strategy; it tests
coarse structural variants of an ultra-low-turnover basket:

- CORE sleeve;
- one income sleeve;
- two to four durable quality equities;
- optional gold ETF.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import importlib.util
import itertools
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


frontier073 = load_module("atm_spike073_for_074", ROOT / "spikes/073-static-quality-income-frontier/static_quality_income_frontier.py")


@dataclass(frozen=True)
class Structure:
    name: str
    income_symbol: str
    quality_symbols: tuple[str, ...]
    gold_symbol: str | None = None


STRUCTURES = [
    Structure("quality_triad_ostix", "OSTIX", ("AAPL", "LLY", "ORLY")),
    Structure("quality_triad_pimix", "PIMIX", ("AAPL", "LLY", "ORLY")),
    Structure("auto_health_ostix", "OSTIX", ("AAPL", "AZO", "LLY", "ORLY")),
    Structure("consumer_health_ostix", "OSTIX", ("AAPL", "COST", "LLY", "ORLY")),
    Structure("growth_health_ostix", "OSTIX", ("AAPL", "FSELX", "LLY", "ORLY")),
    Structure("quality_triad_gold_ostix", "OSTIX", ("AAPL", "LLY", "ORLY"), "IAU"),
    Structure("auto_health_gold_ostix", "OSTIX", ("AAPL", "AZO", "LLY", "ORLY"), "IAU"),
    Structure("consumer_health_gold_ostix", "OSTIX", ("AAPL", "COST", "LLY", "ORLY"), "IAU"),
    Structure("quality_triad_gold_pimix", "PIMIX", ("AAPL", "LLY", "ORLY"), "IAU"),
    Structure("cost_lly_smh_gold", "OSTIX", ("COST", "LLY", "SMH"), "IAU"),
    Structure("lowvol_quality_gold_ostix", "OSTIX", ("AAPL", "LLY", "ORLY", "WM"), "IAU"),
    Structure("consumer_lowvol_gold_ostix", "OSTIX", ("COST", "LLY", "ORLY", "WM"), "IAU"),
    Structure("staples_health_gold_ostix", "OSTIX", ("LLY", "NVO", "XLP", "XLV"), "IAU"),
    Structure("dividend_quality_gold_ostix", "OSTIX", ("AAPL", "COST", "MCD", "WM"), "IAU"),
    Structure("health_compounder_gold_ostix", "OSTIX", ("AAPL", "LLY", "TMO", "UNH"), "IAU"),
    Structure("lowvol_quality_ostix", "OSTIX", ("AAPL", "LLY", "ORLY", "WM")),
    Structure("consumer_lowvol_ostix", "OSTIX", ("COST", "LLY", "ORLY", "WM")),
]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def weight_candidates(structure: Structure) -> list[frontier073.Basket]:
    symbols = ["CORE", structure.income_symbol, *structure.quality_symbols]
    if structure.gold_symbol:
        symbols.append(structure.gold_symbol)
    symbols = sorted(symbols)
    rows: list[frontier073.Basket] = []

    # Five-percent steps.  The bounds encode the structure rather than a fine
    # optimizer: CORE and income remain the anchors; quality stays a satellite.
    units_total = 20
    bounds: dict[str, tuple[int, int]] = {"CORE": (4, 12), structure.income_symbol: (4, 10)}
    if structure.gold_symbol:
        bounds[structure.gold_symbol] = (1, 4)
    for symbol in structure.quality_symbols:
        bounds[symbol] = (1, 5)

    def rec(index: int, remaining: int, current: dict[str, int]) -> None:
        if index == len(symbols):
            if remaining == 0:
                rows.append(frontier073.Basket({symbol: units / units_total for symbol, units in sorted(current.items())}))
            return
        symbol = symbols[index]
        low, high = bounds[symbol]
        slots_left = symbols[index + 1 :]
        min_rest = sum(bounds[item][0] for item in slots_left)
        max_rest = sum(bounds[item][1] for item in slots_left)
        for units in range(low, high + 1):
            if remaining - units < min_rest or remaining - units > max_rest:
                continue
            current[symbol] = units
            rec(index + 1, remaining - units, current)
            current.pop(symbol, None)

    rec(0, units_total, {})
    return rows


def main() -> None:
    dates, series, errors = frontier073.load_series()
    rows: list[dict[str, Any]] = []
    for structure in STRUCTURES:
        for basket in weight_candidates(structure):
            replay = frontier073.replay_annual_rebalance(dates, series, basket)
            if replay is None:
                continue
            replay_dates, replay_values, trades = replay
            row = frontier073.metric_row(basket.name, "annual_rebalance", replay_dates, replay_values, basket, trades)
            row["structure"] = structure.__dict__
            rows.append(row)

    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "source": "spike073 annual rebalance replay",
        "errors": errors,
        "row_count": len(rows),
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:80],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:80],
            "annual_ge_14": [row for row in rows if row["full"]["annualized"] >= 0.14][:80],
            "post2020_ge_14": [row for row in rows if (row["slices"]["post_2020"]["sharpe"] or 0.0) >= 1.4][:80],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    for row in rows[:50]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | {row['structure']['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
