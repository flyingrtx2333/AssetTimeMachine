#!/usr/bin/env python3
"""Build a neutral-symbol G4 role fixture without implementing any strategy logic.

Raw holdout series keep their source identifiers in immutable input files. This builder copies each
frozen source series into a role-neutral `atm_g4_*` series using only the normalization rule frozen in
the holdout manifest, then merges those normalized aliases with the ordinary V11 base fixture.

The initial ATM-SVP-1 implementation intentionally supports only `identity` normalization. A new
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
        "protocol_id": "ATM-SVP-1",
        "role": role,
        "raw_symbol": slot["alternate_symbol"],
        "raw_source_file": source_path.as_posix(),
        "raw_source_sha256": sha256(source_path),
        "rule": "identity",
        "inputs": [],
    }
    return normalized


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
    base_series = [row for row in output.get("series", []) if isinstance(row, dict)]
    neutral_symbols = {row["symbol"] for row in normalized_rows}
    if neutral_symbols.intersection({row.get("symbol") for row in base_series}):
        raise SystemExit("Base fixture already contains a reserved atm_g4_* normalized symbol")
    output["series"] = [*base_series, *normalized_rows]

    existing_symbols = [value for value in output.get("symbols", []) if isinstance(value, str)]
    output["symbols"] = [*existing_symbols, *[row["symbol"] for row in normalized_rows if row["symbol"] not in existing_symbols]]
    output["g4_normalization"] = {
        "protocol_id": "ATM-SVP-1",
        "holdout_id": manifest["holdout_id"],
        "strategy_version": manifest["strategy_version"],
        "role_symbols": [row["symbol"] for row in normalized_rows],
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
