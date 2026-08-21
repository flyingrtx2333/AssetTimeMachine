#!/usr/bin/env python3
"""Build an ATM-SVP-2 G4 common-window identity fixture from already-exposed base data only.

This file must never read pristine holdout histories. It aliases the frozen V11 current-role series into the
neutral `atm_g4_*` symbols used by the G4 runner, clips all required inputs to the frozen common evaluation
window, and marks every alias explicitly as an exposed-base identity reference.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any

from build_g4_role_fixture import G4_BASE_REQUIRED_SYMBOLS, filter_series
from strategy_validation_holdout import ROLE_ENGINE_REQUIREMENTS

ROLE_BASE_SYMBOLS = {
    "gold_safe_haven": "gold_cny",
    "us_growth_equity": "nasdaq_composite",
    "us_broad_equity": "sp500",
    "china_large_equity": "csi300",
    "china_broad_equity": "shanghai_composite",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_identity_reference_fixture(base: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
    configured = manifest.get("evaluation_window") or {}
    start = configured.get("start")
    end = configured.get("end")
    if not isinstance(start, str) or not isinstance(end, str) or start >= end:
        raise SystemExit("Frozen G4 identity reference requires a valid evaluation_window")

    base_rows = [row for row in base.get("series", []) if isinstance(row, dict)]
    by_symbol = {str(row.get("symbol")): row for row in base_rows if row.get("symbol")}
    missing = G4_BASE_REQUIRED_SYMBOLS - set(by_symbol)
    if missing:
        raise SystemExit(f"Base fixture missing required G4/V11 symbols: {sorted(missing)}")

    roles = [slot.get("role") for slot in manifest.get("role_slots", []) if isinstance(slot, dict)]
    if set(roles) != set(ROLE_BASE_SYMBOLS):
        raise SystemExit("Frozen G4 identity reference manifest must contain exactly the five expected roles")

    filtered_base = [filter_series(by_symbol[symbol], start, end) for symbol in sorted(G4_BASE_REQUIRED_SYMBOLS)]
    neutral_rows: list[dict[str, Any]] = []
    for role in ROLE_BASE_SYMBOLS:
        source_symbol = ROLE_BASE_SYMBOLS[role]
        source = filter_series(by_symbol[source_symbol], start, end)
        normalized_symbol, expected_currency, expected_unit = ROLE_ENGINE_REQUIREMENTS[role]
        if source.get("currency") != expected_currency or source.get("unit") != expected_unit:
            raise SystemExit(
                f"Exposed identity role unit mismatch for {role}: "
                f"expected={expected_currency}/{expected_unit} got={source.get('currency')}/{source.get('unit')}"
            )
        alias = copy.deepcopy(source)
        alias["symbol"] = normalized_symbol
        alias["label"] = f"ATM-SVP G4 exposed identity reference {role}"
        alias["source"] = "EXPOSED_BASE_IDENTITY_REFERENCE"
        alias["identity_reference"] = {
            "protocol_id": "ATM-SVP-2",
            "role": role,
            "source_symbol": source_symbol,
            "rule": "identity_reference_from_exposed_base",
        }
        neutral_rows.append(alias)

    output = copy.deepcopy(base)
    output["series"] = [*filtered_base, *neutral_rows]
    output["symbols"] = [str(row["symbol"]) for row in output["series"]]
    output["start_date"] = start
    output["end_date"] = end
    output["g4_normalization"] = {
        "protocol_id": "ATM-SVP-2",
        "holdout_id": manifest["holdout_id"],
        "strategy_version": manifest["strategy_version"],
        "reference_type": "EXPOSED_BASE_IDENTITY_COMMON_WINDOW",
        "evaluation_window": {"start": start, "end": end},
        "role_symbols": [row["symbol"] for row in neutral_rows],
        "source_series_ids": {role: f"EXPOSED_BASE:{ROLE_BASE_SYMBOLS[role]}" for role in ROLE_BASE_SYMBOLS},
        "normalization_rules": {role: "identity_reference_from_exposed_base" for role in ROLE_BASE_SYMBOLS},
    }
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-fixture", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    base_path = Path(args.base_fixture)
    manifest_path = Path(args.manifest)
    output_path = Path(args.output)
    base = json.loads(base_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    output = build_identity_reference_fixture(base, manifest)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(
        f"G4_IDENTITY_REFERENCE_FIXTURE_WRITTEN output={output_path} sha256={sha256(output_path)} "
        f"base_sha256={sha256(base_path)} window={output['start_date']}..{output['end_date']}"
    )


if __name__ == "__main__":
    main()
