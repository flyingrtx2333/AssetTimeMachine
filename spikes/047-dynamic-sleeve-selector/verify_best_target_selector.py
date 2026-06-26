#!/usr/bin/env python3
"""Single-candidate verification for the best target-level selector."""
from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
from typing import Any

import dynamic_sleeve_selector as dyn
import target_replay_search as search


BEST_SELECTOR = dyn.SelectorSpec(
    name="target_hysteresis_selector_lb315_h95_l25_m125_d35",
    thesis="Target-level long-lookback hysteresis selector between high-return satellite and profit-lock defense.",
    mode="hysteresis_selector",
    lookback=315,
    satellite_high=0.95,
    satellite_low=0.25,
    ret_margin=0.0125,
    dd_limit=0.035,
    portfolio_dd_limit=0.030,
)


def main() -> None:
    original_fetch = search.app.fetch_public_history
    cached_fetch = search.cached_public_history_factory(original_fetch)

    search.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.replay.SHARED_DATA = None
    try:
        data = search.precompute_targets()
        values, extra, trades = search.simulate(data, BEST_SELECTOR)
        row = search.row_for(data, BEST_SELECTOR, values, extra, trades)
    finally:
        search.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        search.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        search.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        search.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    out: dict[str, Any] = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "note": "Independent single-candidate target-weight replay. Fees, slippage, no shorting, no leverage.",
        "coverage": {
            "start": data["dates"][0].isoformat(),
            "end": data["dates"][-1].isoformat(),
            "points": len(values),
        },
        "row": row,
        "checks": {
            "no_btc": "btc" not in extra["symbols"] and "bitcoin" not in extra["symbols"],
            "no_leverage": extra["max_target_sum"] <= 1.0000001,
            "sharpe_above_1_4": (row["full"]["sharpe"] or 0.0) > 1.4,
        },
    }
    out_path = Path(__file__).with_name("best_target_verify.json")
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    full = row["full"]
    print(f"WROTE {out_path}")
    print(
        f"{row['name']} | annualized={search.replay.pct(full['annualized'])} "
        f"dd={search.replay.pct(full['max_drawdown'])} "
        f"vol={search.replay.pct(full['annual_volatility'])} "
        f"sharpe={full['sharpe']:.4f} trades={full['trades']}"
    )
    print(f"checks={out['checks']}")
    print(f"extra={extra}")


if __name__ == "__main__":
    main()
