#!/usr/bin/env python3
"""Focused robustness check for the best dynamic sleeve selector.

This intentionally stays within the same mechanism that nearly crossed 1.4:
long lookback relative return, hysteresis, and drawdown guard.
"""
from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
from typing import Any

import dynamic_sleeve_selector as dyn


def main() -> None:
    satellite_result = dyn.s44.run_confirmed_satellite()
    defensive_result = dyn.s44.run_profit_lock()
    dates, series = dyn.common_series(satellite_result, defensive_result)
    satellite, defensive = series

    specs: list[dyn.SelectorSpec] = []
    for lookback in [210, 231, 252, 273, 294, 315]:
        for high, low in [(0.92, 0.30), (0.90, 0.32), (0.90, 0.35), (0.88, 0.35), (0.86, 0.40)]:
            for ret_margin in [0.010, 0.0125, 0.015, 0.0175, 0.020, 0.025]:
                for dd_limit, pf_limit in [(0.040, 0.030), (0.045, 0.035), (0.050, 0.035), (0.055, 0.040), (0.065, 0.045)]:
                    specs.append(
                        dyn.SelectorSpec(
                            name=f"refined_hysteresis_lb{lookback}_h{int(high*100)}_l{int(low*100)}_m{int(ret_margin*10000)}_d{int(dd_limit*1000)}",
                            thesis="Focused long-lookback hysteresis selector between confirmed satellite and profit-lock defense.",
                            mode="hysteresis_selector",
                            lookback=lookback,
                            satellite_high=high,
                            satellite_low=low,
                            ret_margin=ret_margin,
                            dd_limit=dd_limit,
                            portfolio_dd_limit=pf_limit,
                        )
                    )

    rows: list[dict[str, Any]] = []
    for spec in specs:
        values, extra = dyn.run_selector(spec, dates, satellite, defensive)
        rows.append(dyn.row_for(spec.name, dates, values, spec, extra))

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("refined_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Focused NAV-level robustness screen only; target-weight replay required before app use.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | dd window")
    for row in rows[:40]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{dyn.pct(full['annualized'])}/{dyn.pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{dyn.pct(full['annual_volatility'])} | "
            f"{dyn.pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{dyn.pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{dyn.pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{row['extra']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
