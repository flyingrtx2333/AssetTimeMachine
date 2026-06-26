#!/usr/bin/env python3
"""Coarse weight frontier for the stress-tilted quality/core basket."""
from __future__ import annotations

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


stress078 = load_module("atm_spike078_for_079", ROOT / "spikes/078-stress-tilted-quality-basket/stress_tilted_quality_basket.py")


BEST_SPECS = [
    stress078.TiltSpec("q35_g50_r126", 126, 0.08, 0.15, 0.05, 0.35, 0.50),
    stress078.TiltSpec("q60_g50_r126", 126, 0.08, 0.15, 0.05, 0.60, 0.50),
    stress078.TiltSpec("q35_g25_r126", 126, 0.12, 0.15, 0.05, 0.35, 0.25),
    stress078.TiltSpec("q60_g25_r63", 63, 0.12, 0.15, 0.05, 0.60, 0.25),
]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def candidate_weights() -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    # Five-percent units.
    for ostix in range(7, 11):
        for core in range(5, 9):
            for iau in [1, 2]:
                for aapl in [1, 2, 3]:
                    for lly in [1, 2]:
                        for orly in [1, 2]:
                            for cost in [0, 1, 2]:
                                units = {
                                    "OSTIX": ostix,
                                    "CORE": core,
                                    "IAU": iau,
                                    "AAPL": aapl,
                                    "LLY": lly,
                                    "ORLY": orly,
                                }
                                if cost:
                                    units["COST"] = cost
                                if sum(units.values()) != 20:
                                    continue
                                quality_total = aapl + lly + orly + cost
                                if quality_total < 3 or quality_total > 6:
                                    continue
                                rows.append({symbol: value / 20 for symbol, value in units.items()})
    # Deduplicate any structures with omitted COST.
    unique: dict[str, dict[str, float]] = {}
    for row in rows:
        key = "+".join(f"{symbol}:{weight:.2f}" for symbol, weight in sorted(row.items()))
        unique[key] = row
    return list(unique.values())


def main() -> None:
    dates, series, errors = stress078.frontier073.load_series()
    rows: list[dict[str, Any]] = []
    for weights in candidate_weights():
        for spec in BEST_SPECS:
            row = stress078.row_for(dates, series, "coarse", weights, spec)
            if row is not None:
                rows.append(row)
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "errors": errors,
        "candidate_count": len(candidate_weights()),
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:100],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:100],
            "annual_ge_115": [row for row in rows if row["full"]["annualized"] >= 0.115][:100],
            "sharpe_ge_16": [row for row in rows if (row["full"]["sharpe"] or 0.0) >= 1.6][:100],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print(f"candidates={out['candidate_count']} rows={len(rows)}")
    for row in rows[:80]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | weights={row['weights']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
