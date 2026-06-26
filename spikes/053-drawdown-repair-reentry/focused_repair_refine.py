#!/usr/bin/env python3
"""Focused refinement around the best 053 repair-overlay shape."""
from __future__ import annotations

from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MODULE_PATH = HERE / "drawdown_repair_reentry.py"

spec_module = importlib.util.spec_from_file_location("drawdown_repair_reentry_053", MODULE_PATH)
if spec_module is None or spec_module.loader is None:
    raise RuntimeError(f"failed to load {MODULE_PATH}")
repair = importlib.util.module_from_spec(spec_module)
sys.modules["drawdown_repair_reentry_053"] = repair
spec_module.loader.exec_module(repair)


def refined_specs() -> list[Any]:
    out: list[Any] = []
    for drawdown_lookback in [105, 120, 135]:
        for drawdown_threshold in [0.10, 0.12, 0.14]:
            for rebound_lookback in [30, 40, 50]:
                for rebound_threshold in [0.045, 0.055, 0.065]:
                    for confirmation_ma in [20, 40]:
                        for top_count in [1, 2]:
                            for overlay_cap, per_asset_cap in [
                                (0.22, 0.10),
                                (0.25, 0.12),
                                (0.35, 0.15),
                            ]:
                                out.append(
                                    repair.RepairSpec(
                                        name=(
                                            f"refine_overlay_dd{drawdown_lookback}_{int(drawdown_threshold*100)}_"
                                            f"rb{rebound_lookback}_{int(rebound_threshold*1000)}_"
                                            f"ma{confirmation_ma}_top{top_count}_cap{int(overlay_cap*100)}_"
                                            f"per{int(per_asset_cap*100)}_breadth"
                                        ),
                                        mode="overlay",
                                        drawdown_lookback=drawdown_lookback,
                                        drawdown_threshold=drawdown_threshold,
                                        rebound_lookback=rebound_lookback,
                                        rebound_threshold=rebound_threshold,
                                        confirmation_ma=confirmation_ma,
                                        momentum_lookback=20,
                                        top_count=top_count,
                                        overlay_cap=overlay_cap,
                                        per_asset_cap=per_asset_cap,
                                        require_breadth=True,
                                        exit_weakness=True,
                                    )
                                )
    return out


def main() -> None:
    original_fetch = repair.app.fetch_public_history
    cached_fetch = repair.t47.cached_public_history_factory(original_fetch)
    repair.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = repair.t47.precompute_targets()
        rows = [repair.baseline_row(data)]
        for spec in refined_specs():
            values, extra, trades = repair.simulate(data, spec)
            rows.append(repair.row_for(data, spec, values, extra, trades))
    finally:
        repair.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = HERE / "focused_results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Focused 053 refinement around repair-overlay candidates. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades")
    for row in rows[:80]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        print(
            f"{row['name']} | "
            f"{repair.pct(full['annualized'])}/{repair.pct(full['max_drawdown'])}/"
            f"{full['sharpe']:.4f}/{repair.pct(full['annual_volatility'])} | "
            f"{repair.pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{repair.pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{repair.pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{full['trades']}"
        )


if __name__ == "__main__":
    main()
