#!/usr/bin/env python3
"""Search stronger stable anchors for the annual quality/core basket.

Spike 074/075 found a high-Sharpe structure, but the 1.6+ Sharpe version depends
on a 50% OSTIX anchor and only reaches about 10.2% annualized return.  This spike
keeps the same annual-rebalance quality/core logic and searches whether balanced
or income funds can replace or complement OSTIX to lift annualized return without
breaking Sharpe.
"""
from __future__ import annotations

from datetime import datetime
import importlib.util
import itertools
import json
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


frontier073 = load_module("atm_spike073_for_076", ROOT / "spikes/073-static-quality-income-frontier/static_quality_income_frontier.py")
scan070 = frontier073.scan070
carry = frontier073.carry


ANCHOR_UNIVERSE = sorted(
    set(
        """
        OSTIX PIMIX PONAX PRWCX VWINX VWELX FBALX FPURX DODBX OAKBX BERIX
        VBIAX VWINX VWELX VSMGX VSCGX VASIX VTINX
        DODIX PTTRX VBMFX VBTLX BND AGG
        """.split()
    )
)

QUALITY_SETS = [
    ("triad", ("AAPL", "LLY", "ORLY")),
    ("auto_health", ("AAPL", "AZO", "LLY", "ORLY")),
    ("consumer_health", ("AAPL", "COST", "LLY", "ORLY")),
    ("triad_cost", ("AAPL", "COST", "LLY", "ORLY")),
]
QUALITY_SYMBOLS = sorted({symbol for _, symbols in QUALITY_SETS for symbol in symbols})
GOLD_SYMBOLS = ["IAU"]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def load_series() -> tuple[list[Any], dict[str, list[float | None]], dict[str, str]]:
    core = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=frontier073.END_DATE, start_date=frontier073.START_DATE.isoformat())
    raw = app.fetch_public_history(end_date=app.parse_date(frontier073.END_DATE))
    dates = core.dates
    fx_points = raw[app.USD_FX_SYMBOL]
    needed = sorted(set(ANCHOR_UNIVERSE + QUALITY_SYMBOLS + GOLD_SYMBOLS))
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


def basket(weights: dict[str, float]) -> frontier073.Basket:
    return frontier073.Basket(dict(sorted((symbol, weight) for symbol, weight in weights.items() if weight > 0)))


def row_for(dates: list[Any], series: dict[str, list[float | None]], weights: dict[str, float], label: str) -> dict[str, Any] | None:
    item = basket(weights)
    replay = frontier073.replay_annual_rebalance(dates, series, item)
    if replay is None:
        return None
    replay_dates, replay_values, trades = replay
    row = frontier073.metric_row(item.name, "annual_rebalance", replay_dates, replay_values, item, trades)
    row["label"] = label
    return row


def single_anchor_rows(dates: list[Any], series: dict[str, list[float | None]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for anchor in ANCHOR_UNIVERSE:
        if anchor not in series:
            continue
        for quality_name, quality_symbols in QUALITY_SETS:
            for anchor_w, core_w, gold_w in [
                (0.50, 0.30, 0.05),
                (0.45, 0.30, 0.05),
                (0.40, 0.35, 0.05),
                (0.40, 0.30, 0.10),
                (0.35, 0.35, 0.10),
            ]:
                remainder = 1.0 - anchor_w - core_w - gold_w
                if remainder <= 0:
                    continue
                weights = {anchor: anchor_w, "CORE": core_w, "IAU": gold_w}
                each = remainder / len(quality_symbols)
                for symbol in quality_symbols:
                    weights[symbol] = weights.get(symbol, 0.0) + each
                row = row_for(dates, series, weights, f"single:{anchor}:{quality_name}")
                if row is not None:
                    rows.append(row)
    return rows


def dual_anchor_rows(dates: list[Any], series: dict[str, list[float | None]], best_anchors: list[str]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for a, b in itertools.combinations(best_anchors, 2):
        for quality_name, quality_symbols in QUALITY_SETS:
            for a_w, b_w, core_w, gold_w in [
                (0.25, 0.25, 0.30, 0.05),
                (0.30, 0.20, 0.30, 0.05),
                (0.25, 0.20, 0.35, 0.05),
                (0.25, 0.20, 0.30, 0.10),
                (0.20, 0.20, 0.35, 0.10),
            ]:
                remainder = 1.0 - a_w - b_w - core_w - gold_w
                if remainder <= 0:
                    continue
                weights = {a: a_w, b: b_w, "CORE": core_w, "IAU": gold_w}
                each = remainder / len(quality_symbols)
                for symbol in quality_symbols:
                    weights[symbol] = weights.get(symbol, 0.0) + each
                row = row_for(dates, series, weights, f"dual:{a}+{b}:{quality_name}")
                if row is not None:
                    rows.append(row)
    return rows


def main() -> None:
    dates, series, errors = load_series()
    single = single_anchor_rows(dates, series)
    single.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    best_anchors: list[str] = []
    for row in single[:20]:
        for symbol in row["weights"]:
            if symbol in ANCHOR_UNIVERSE and symbol not in best_anchors:
                best_anchors.append(symbol)
    best_anchors = best_anchors[:8]
    dual = dual_anchor_rows(dates, series, best_anchors)
    rows = single + dual
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "errors": errors,
        "best_anchors": best_anchors,
        "single_anchor": single,
        "dual_anchor": dual,
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:100],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:100],
            "annual_ge_13": [row for row in rows if row["full"]["annualized"] >= 0.13][:100],
            "sharpe_ge_16": [row for row in rows if (row["full"]["sharpe"] or 0.0) >= 1.6][:100],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print(f"best anchors: {', '.join(best_anchors)}")
    for row in rows[:80]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | {row['label']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
