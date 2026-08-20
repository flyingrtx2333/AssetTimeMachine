#!/usr/bin/env python3
"""Build a neutral-symbol G4 role fixture without implementing any strategy logic.

Raw holdout series keep their source identifiers in immutable input files. This builder copies each
frozen source series into a role-neutral `atm_g4_*` series using only the normalization rule frozen in
the holdout manifest, then merges those normalized aliases with the ordinary V11 base fixture.

ATM-SVP-2 intentionally supports only `identity` normalization. A new
normalization formula must be added and committed before a holdout using it is frozen/burned; never
invent a conversion after opening pristine history.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any

from strategy_validation_holdout import ROLE_ENGINE_REQUIREMENTS, validate_manifest

G4_BASE_REQUIRED_SYMBOLS = {
    "gold_cny",
    "nasdaq_composite",
    "sp500",
    "csi300",
    "shanghai_composite",
    "usd_per_cny",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_document(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("series"), list):
        raise SystemExit(f"Expected public-history style JSON with series[]: {path}")
    return value


def series_index(documents: list[tuple[Path, dict[str, Any]]]) -> dict[str, tuple[Path, dict[str, Any]]]:
    index: dict[str, tuple[Path, dict[str, Any]]] = {}
    for path, document in documents:
        for row in document["series"]:
            if not isinstance(row, dict):
                continue
            symbol = row.get("symbol")
            if not isinstance(symbol, str) or not symbol:
                continue
            if symbol in index:
                prior_path, _ = index[symbol]
                raise SystemExit(f"Duplicate raw holdout symbol={symbol} in {prior_path} and {path}")
            index[symbol] = (path, row)
    return index


def validate_series_shape(series: dict[str, Any], source_path: Path) -> None:
    dates = series.get("dates")
    prices = series.get("prices")
    if not isinstance(dates, list) or not isinstance(prices, list) or len(dates) != len(prices) or len(dates) < 2:
        raise SystemExit(f"Invalid dates/prices for {series.get('symbol')} in {source_path}")
    optional_arrays = ["open_prices", "high_prices", "low_prices", "close_prices", "volumes"]
    for key in optional_arrays:
        values = series.get(key)
        if values is not None and (not isinstance(values, list) or len(values) != len(dates)):
            raise SystemExit(f"Invalid {key} length for {series.get('symbol')} in {source_path}")


def normalize_identity(slot: dict[str, Any], raw: dict[str, Any], source_path: Path) -> dict[str, Any]:
    role = str(slot["role"])
    normalized_symbol, engine_currency, engine_unit = ROLE_ENGINE_REQUIREMENTS[role]
    source_currency = raw.get("currency")
    source_unit = raw.get("unit")
    if source_currency != slot["source_currency"] or source_unit != slot["source_unit"]:
        raise SystemExit(
            f"Raw metadata mismatch for role={role}: manifest={slot['source_currency']}/{slot['source_unit']} "
            f"raw={source_currency}/{source_unit}"
        )
    if source_currency != engine_currency or source_unit != engine_unit:
        raise SystemExit(
            f"identity normalization cannot map role={role} {source_currency}/{source_unit} "
            f"to {engine_currency}/{engine_unit}"
        )
    validate_series_shape(raw, source_path)
    normalized = copy.deepcopy(raw)
    normalized["symbol"] = normalized_symbol
    normalized["currency"] = engine_currency
    normalized["unit"] = engine_unit
    normalized["category"] = "gold" if role == "gold_safe_haven" else "index"
    normalized["label"] = f"ATM-SVP G4 {role}"
    raw_source = str(raw.get("source") or slot["alternate_source"])
    normalized["source"] = f"{raw_source} · ATM-SVP role-normalized identity"
    normalized["normalization"] = {
        "protocol_id": "ATM-SVP-2",
        "role": role,
        "source_series_id": slot["source_series_id"],
        "raw_symbol": slot["alternate_symbol"],
        "raw_source_file": source_path.as_posix(),
        "raw_source_sha256": sha256(source_path),
        "rule": "identity",
        "inputs": [],
    }
    return normalized


def evaluation_window(manifest: dict[str, Any]) -> tuple[str, str]:
    configured = manifest.get("evaluation_window") or {}
    start = configured.get("start") or max(slot["metadata_coverage_start"] for slot in manifest["role_slots"])
    end = configured.get("end") or min(slot["metadata_coverage_end"] for slot in manifest["role_slots"])
    if start >= end:
        raise SystemExit(f"Invalid G4 evaluation window: {start}..{end}")
    return str(start), str(end)


def filter_series(series: dict[str, Any], start: str, end: str) -> dict[str, Any]:
    dates = series.get("dates")
    prices = series.get("prices")
    if not isinstance(dates, list) or not isinstance(prices, list) or len(dates) != len(prices):
        raise SystemExit(f"Invalid series shape while applying G4 evaluation window: {series.get('symbol')}")
    indices = [index for index, raw_day in enumerate(dates) if start <= str(raw_day) <= end]
    if len(indices) < 2:
        raise SystemExit(
            f"Series has insufficient rows in G4 common window {start}..{end}: {series.get('symbol')} rows={len(indices)}"
        )
    filtered = copy.deepcopy(series)
    filtered["dates"] = [dates[index] for index in indices]
    filtered["prices"] = [prices[index] for index in indices]
    for key in ["open_prices", "high_prices", "low_prices", "close_prices", "volumes"]:
        values = series.get(key)
        if values is None:
            filtered[key] = None
        elif isinstance(values, list) and len(values) == len(dates):
            filtered[key] = [values[index] for index in indices]
        else:
            raise SystemExit(f"Invalid {key} shape for {series.get('symbol')}")
    filtered["start_date"] = str(filtered["dates"][0])
    filtered["end_date"] = str(filtered["dates"][-1])
    return filtered


def build_fixture(base: dict[str, Any], manifest: dict[str, Any], raw_documents: list[tuple[Path, dict[str, Any]]]) -> dict[str, Any]:
    raw_by_symbol = series_index(raw_documents)
    normalized_rows: list[dict[str, Any]] = []
    for slot in manifest["role_slots"]:
        raw_symbol = slot["alternate_symbol"]
        item = raw_by_symbol.get(raw_symbol)
        if item is None:
            raise SystemExit(f"Raw holdout fixture missing frozen symbol={raw_symbol}")
        source_path, raw = item
        rule = str(slot["normalization_rule"]).casefold()
        if rule != "identity":
            raise SystemExit(
                f"Unsupported frozen normalization_rule={slot['normalization_rule']!r} for role={slot['role']}. "
                "Implement and commit the rule before freezing/burning the holdout."
            )
        normalized_rows.append(normalize_identity(slot, raw, source_path))

    output = copy.deepcopy(base)
    common_start, common_end = evaluation_window(manifest)
    all_base_series = [row for row in output.get("series", []) if isinstance(row, dict)]
    base_series = [row for row in all_base_series if row.get("symbol") in G4_BASE_REQUIRED_SYMBOLS]
    missing_base = G4_BASE_REQUIRED_SYMBOLS - {str(row.get("symbol")) for row in base_series}
    if missing_base:
        raise SystemExit(f"Base fixture missing required G4/V11 symbols: {sorted(missing_base)}")
    neutral_symbols = {row["symbol"] for row in normalized_rows}
    if neutral_symbols.intersection({row.get("symbol") for row in base_series}):
        raise SystemExit("Base fixture already contains a reserved atm_g4_* normalized symbol")
    filtered_base = [filter_series(row, common_start, common_end) for row in base_series]
    filtered_normalized = [filter_series(row, common_start, common_end) for row in normalized_rows]
    output["series"] = [*filtered_base, *filtered_normalized]
    output["start_date"] = common_start
    output["end_date"] = common_end

    output["symbols"] = [str(row["symbol"]) for row in [*filtered_base, *filtered_normalized]]
    output["g4_normalization"] = {
        "protocol_id": "ATM-SVP-2",
        "holdout_id": manifest["holdout_id"],
        "strategy_version": manifest["strategy_version"],
        "evaluation_window": {"start": common_start, "end": common_end},
        "role_symbols": [row["symbol"] for row in filtered_normalized],
        "source_series_ids": {slot["role"]: slot["source_series_id"] for slot in manifest["role_slots"]},
        "normalization_rules": {slot["role"]: slot["normalization_rule"] for slot in manifest["role_slots"]},
    }
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-fixture", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--raw-fixture", action="append", dest="raw_fixtures", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    base_path = Path(args.base_fixture)
    manifest_path = Path(args.manifest)
    raw_paths = [Path(raw) for raw in args.raw_fixtures]
    output_path = Path(args.output)
    if output_path in raw_paths or output_path == base_path:
        raise SystemExit("Output fixture must be a distinct file")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise SystemExit("Holdout manifest must be a JSON object")
    validate_manifest(manifest, manifest_path, {"DRAFT_NOT_FROZEN", "FROZEN_UNOPENED"})
    base = read_document(base_path)
    raw_documents = [(path, read_document(path)) for path in raw_paths]
    output = build_fixture(base, manifest, raw_documents)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(
        f"G4_ROLE_FIXTURE_WRITTEN output={output_path} sha256={sha256(output_path)} "
        f"base_sha256={sha256(base_path)} raw_files={len(raw_paths)} normalized_roles=5"
    )


if __name__ == "__main__":
    main()
