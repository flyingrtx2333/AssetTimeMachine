#!/usr/bin/env python3
"""Rebuild deterministic field-level OHLC provenance for public_history.json.

This tool audits data only. It never mutates the history fixture and never reads or
computes strategy performance. The output contains no wall-clock timestamp, so the
same inputs and implementation produce byte-identical JSON.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import os
import tempfile
from collections import Counter
from datetime import date
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable, Sequence

import merge_choice_gc00y_gold_ohlc as choice_parser


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tools/fixtures/backtest-history/public_history.json"
DEFAULT_SOURCE = ROOT / "tools/fixtures/backtest-history/sources/choice/GC00Y_daily_1990-01-03_2026-07-08.xlsx"
DEFAULT_PRODUCTION_REPORT = ROOT / "tools/fixtures/backtest-history/sources/choice/gc00y-production-apply-20260902.json"
DEFAULT_OUTPUT = ROOT / "tools/fixtures/backtest-history/public_history_ohlc_provenance_v1.json"
TARGET_SYMBOLS = ("gold_cny", "nasdaq_composite", "sp500")
OHLC_FIELDS = ("open_prices", "high_prices", "low_prices", "close_prices")
ROW_FIELDS = ("prices", "observed", *OHLC_FIELDS, "volumes")
TROY_OUNCE_GRAMS = 31.1034768
MAX_FX_STALENESS_DAYS = 7
DIGEST_PREFIX = b"asset-time-machine/public-history-ohlc-provenance-v1\0"


class AuditError(ValueError):
    """Raised when an input violates a fail-closed audit invariant."""


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def stable_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def domain_digest(domain: str, records: Iterable[Any]) -> str:
    """Hash ordered canonical records with an explicit domain separator."""
    digest = hashlib.sha256()
    digest.update(DIGEST_PREFIX)
    digest.update(domain.encode("utf-8"))
    digest.update(b"\0")
    for record in records:
        digest.update(canonical_json_bytes(record))
        digest.update(b"\n")
    return digest.hexdigest()


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
            temporary = handle.name
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def display_path(path: Path, root: Path = ROOT) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return os.path.relpath(path.resolve(), root.resolve()).replace(os.sep, "/")


def _positive_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value > 0
    )


def _nonnegative_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= 0
    )


def _parse_iso_date(value: Any, context: str) -> date:
    if not isinstance(value, str):
        raise AuditError(f"{context} must be an ISO date string")
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise AuditError(f"{context} is not a valid ISO date: {value!r}") from error
    if parsed.isoformat() != value:
        raise AuditError(f"{context} must use canonical YYYY-MM-DD form: {value!r}")
    return parsed


def _series(document: dict[str, Any], symbol: str) -> dict[str, Any]:
    series = document.get("series")
    if not isinstance(series, list):
        raise AuditError("fixture series must be a list")
    matches = [item for item in series if isinstance(item, dict) and item.get("symbol") == symbol]
    if len(matches) != 1:
        raise AuditError(f"fixture must contain exactly one {symbol} series")
    return matches[0]


def _required_vector(series: dict[str, Any], field: str, length: int | None = None) -> list[Any]:
    value = series.get(field)
    if not isinstance(value, list):
        raise AuditError(f"{series.get('symbol')}.{field} must be a list")
    if length is not None and len(value) != length:
        raise AuditError(
            f"{series.get('symbol')}.{field} length {len(value)} does not match dates length {length}"
        )
    return value


def validate_price_series(series: dict[str, Any]) -> dict[str, Any]:
    """Validate dates, canonical prices, OHLC completeness, volume, and geometry."""
    symbol = str(series.get("symbol"))
    dates = _required_vector(series, "dates")
    parsed_dates = [_parse_iso_date(value, f"{symbol}.dates[{index}]") for index, value in enumerate(dates)]
    if any(left >= right for left, right in zip(parsed_dates, parsed_dates[1:])):
        raise AuditError(f"{symbol} dates must be unique and strictly increasing")

    prices = _required_vector(series, "prices", len(dates))
    if not all(_positive_number(value) for value in prices):
        raise AuditError(f"{symbol}.prices must contain finite positive numbers")

    vectors = {field: _required_vector(series, field, len(dates)) for field in OHLC_FIELDS}
    volumes = _required_vector(series, "volumes", len(dates))
    observed = series.get("observed")
    if observed is not None and (not isinstance(observed, list) or len(observed) != len(dates)):
        raise AuditError(f"{symbol}.observed must be absent or match dates length")

    complete_rows = 0
    all_null_dates: list[str] = []
    canonical_close_fallback_dates: list[str] = []
    missing_dates: list[str] = []
    for index, trading_date in enumerate(dates):
        values = [vectors[field][index] for field in OHLC_FIELDS]
        present = sum(value is not None for value in values)
        canonical_close_fallback = (
            values[0] is None
            and values[1] is None
            and values[2] is None
            and values[3] == prices[index]
        )
        if present == 0 or canonical_close_fallback:
            missing_dates.append(trading_date)
            if present == 0:
                all_null_dates.append(trading_date)
            else:
                canonical_close_fallback_dates.append(trading_date)
            if volumes[index] is not None and not _nonnegative_number(volumes[index]):
                raise AuditError(f"{symbol} has invalid volume at {trading_date}")
            continue
        if present != len(OHLC_FIELDS):
            raise AuditError(f"{symbol} has partial OHLC at {trading_date}")
        if not all(_positive_number(value) for value in values):
            raise AuditError(f"{symbol} has non-positive or non-finite OHLC at {trading_date}")
        open_price, high_price, low_price, close_price = values
        if low_price > high_price or high_price < max(open_price, close_price) or low_price > min(open_price, close_price):
            raise AuditError(f"{symbol} has invalid OHLC geometry at {trading_date}")
        if volumes[index] is not None and not _nonnegative_number(volumes[index]):
            raise AuditError(f"{symbol} has invalid volume at {trading_date}")
        complete_rows += 1

    row_records = []
    for index, trading_date in enumerate(dates):
        row = {"date": trading_date}
        for field in ROW_FIELDS:
            vector = series.get(field)
            row[field] = vector[index] if isinstance(vector, list) else None
        row_records.append(row)

    return {
        "row_count": len(dates),
        "date_start": dates[0] if dates else None,
        "date_end": dates[-1] if dates else None,
        "complete_ohlc_rows": complete_rows,
        "missing_ohlc_rows": len(missing_dates),
        "missing_ohlc_dates": missing_dates,
        "missing_all_null_rows": len(all_null_dates),
        "missing_all_null_dates": all_null_dates,
        "missing_canonical_close_fallback_rows": len(canonical_close_fallback_dates),
        "missing_canonical_close_fallback_dates": canonical_close_fallback_dates,
        "partial_ohlc_rows": 0,
        "geometry_violations": 0,
        "row_digest": {
            "algorithm": "sha256",
            "domain": f"asset/{symbol}/fixture-rows",
            "sha256": domain_digest(f"asset/{symbol}/fixture-rows", row_records),
        },
    }


def validate_fx_series(series: dict[str, Any]) -> tuple[list[str], list[date], list[float]]:
    symbol = str(series.get("symbol"))
    dates = _required_vector(series, "dates")
    parsed_dates = [_parse_iso_date(value, f"{symbol}.dates[{index}]") for index, value in enumerate(dates)]
    if any(left >= right for left, right in zip(parsed_dates, parsed_dates[1:])):
        raise AuditError(f"{symbol} dates must be unique and strictly increasing")
    prices = _required_vector(series, "prices", len(dates))
    if not all(_positive_number(value) for value in prices):
        raise AuditError(f"{symbol}.prices must contain finite positive numbers")
    return dates, parsed_dates, [float(value) for value in prices]


def latest_causal_fx(
    trade_date: date,
    fx_dates: Sequence[date],
    fx_values: Sequence[float],
    max_staleness_days: int = MAX_FX_STALENESS_DAYS,
) -> tuple[date, float, int] | None:
    """Return the latest non-future FX observation within a calendar-day age cap."""
    if len(fx_dates) != len(fx_values):
        raise AuditError("FX dates and values lengths differ")
    index = bisect.bisect_right(fx_dates, trade_date) - 1
    if index < 0:
        return None
    age = (trade_date - fx_dates[index]).days
    if age > max_staleness_days:
        return None
    return fx_dates[index], fx_values[index], age


def choice_rounding_fx_intersection(
    source_row: choice_parser.SourceRow,
    actual_values: Sequence[Any],
) -> tuple[Decimal, Decimal] | None:
    """Return the FX interval whose 6dp HALF_UP results explain all four current fields."""
    source_values = (
        source_row.open_price,
        source_row.high_price,
        source_row.low_price,
        source_row.close_price,
    )
    half_unit = Decimal("0.0000005")
    grams = Decimal(str(TROY_OUNCE_GRAMS))
    lower = Decimal("0")
    upper: Decimal | None = None
    for source_value, actual_value in zip(source_values, actual_values):
        source_decimal = Decimal(str(source_value))
        actual_decimal = Decimal(str(actual_value))
        if source_decimal <= 0 or actual_decimal <= 0:
            return None
        field_lower = (actual_decimal - half_unit) * grams / source_decimal
        field_upper = (actual_decimal + half_unit) * grams / source_decimal
        lower = max(lower, field_lower)
        upper = field_upper if upper is None else min(upper, field_upper)
    if upper is None or lower >= upper:
        return None
    return lower, upper


def volume_matches_choice(source_row: choice_parser.SourceRow, actual_volume: Any) -> bool:
    return Decimal(str(source_row.volume)) == Decimal(str(actual_volume))


def _provider_labels(series: dict[str, Any]) -> dict[str, Any]:
    return {
        "source": series.get("source"),
        "ohlc_source": series.get("ohlc_source"),
    }


def validate_production_report(report: dict[str, Any], source_sha256: str) -> list[str]:
    """Validate the immutable apply report and return proven imported dates."""
    if not isinstance(report, dict):
        raise AuditError("production apply report must be a JSON object")
    dates = report.get("would_update_dates")
    if not isinstance(dates, list) or not all(isinstance(value, str) for value in dates):
        raise AuditError("production would_update_dates must be a string list")
    parsed = [_parse_iso_date(value, "production_report.would_update_dates") for value in dates]
    if parsed != sorted(parsed) or len(set(parsed)) != len(parsed):
        raise AuditError("production apply dates must be sorted and unique")
    if report.get("dry_run") is not False:
        raise AuditError("production report must record a real apply")
    if report.get("updated") != len(dates) or report.get("would_update") != len(dates):
        raise AuditError("production updated counts do not bind imported dates")
    if report.get("candidate_count") != len(dates) or report.get("candidate_dates") != dates:
        raise AuditError("production candidate dates do not match imported dates")
    source = report.get("source")
    if not isinstance(source, dict) or source.get("sha256") != source_sha256:
        raise AuditError("production report does not bind frozen Choice source")
    return dates


def build_manifest(
    *,
    document: dict[str, Any],
    fixture_entry: dict[str, Any],
    source_entry: dict[str, Any],
    parsed_source: choice_parser.ParsedSource,
    production_report_entry: dict[str, Any],
    production_report: dict[str, Any],
    generator_entry: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise AuditError("fixture root must be a JSON object")

    assets: dict[str, Any] = {}
    validated: dict[str, dict[str, Any]] = {}
    for symbol in TARGET_SYMBOLS:
        series = _series(document, symbol)
        validated[symbol] = validate_price_series(series)
        assets[symbol] = {
            "provider_labels": _provider_labels(series),
            **validated[symbol],
        }

    fx_series = _series(document, "usd_per_cny")
    fx_date_strings, fx_dates, fx_values = validate_fx_series(fx_series)
    gold = _series(document, "gold_cny")
    source_by_date = {row.trading_date: row for row in parsed_source.rows}
    if len(source_by_date) != len(parsed_source.rows):
        raise AuditError("Choice source has duplicate valid dates")

    imported_dates = validate_production_report(production_report, source_entry["sha256"])
    imported_set = set(imported_dates)
    missing_ohlc_set = set(validated["gold_cny"]["missing_ohlc_dates"])
    classifications: list[tuple[str, str]] = []
    category_dates: dict[str, list[str]] = {
        "choice_imported": [],
        "native_preexisting": [],
        "missing": [],
    }
    close_diff_dates: list[str] = []

    for index, trading_date in enumerate(gold["dates"]):
        actual_values = tuple(gold[field][index] for field in OHLC_FIELDS)
        if trading_date in missing_ohlc_set:
            classification = "missing"
        elif trading_date in imported_set:
            source_row = source_by_date.get(trading_date)
            if source_row is None:
                raise AuditError(f"production report date has no valid Choice source row: {trading_date}")
            if latest_causal_fx(date.fromisoformat(trading_date), fx_dates, fx_values) is None:
                raise AuditError(f"production report date has no causal FX evidence in fixture: {trading_date}")
            if choice_rounding_fx_intersection(source_row, actual_values) is None:
                raise AuditError(
                    f"current fixture OHLC cannot be jointly explained by Choice plus one 6dp FX rate: {trading_date}"
                )
            if not volume_matches_choice(source_row, gold["volumes"][index]):
                raise AuditError(f"current fixture volume differs from Choice: {trading_date}")
            classification = "choice_imported"
        else:
            classification = "native_preexisting"
        classifications.append((trading_date, classification))
        category_dates[classification].append(trading_date)
        close_value = gold["close_prices"][index]
        if close_value is not None and close_value != gold["prices"][index]:
            close_diff_dates.append(trading_date)

    if set(category_dates["choice_imported"]) != imported_set:
        absent = sorted(imported_set - set(category_dates["choice_imported"]))
        raise AuditError(f"production-imported dates are not complete in fixture: {absent[:5]}")

    gold_asset = assets["gold_cny"]
    gold_asset.update(
        {
            "provider_label_only": False,
            "choice_source_row_proof": True,
            "row_level_proof_basis": "immutable successful production apply membership plus current fixture O/H/L/C jointly fitting one Choice-to-CNY 6dp rounding interval and exact Choice volume; canonical-close differences are diagnostic only",
            "classification_counts": {
                category: len(category_dates[category])
                for category in (
                    "choice_imported",
                    "native_preexisting",
                    "missing",
                )
            },
            "classification_digest": {
                "algorithm": "sha256",
                "domain": "asset/gold_cny/date-classification",
                "sha256": domain_digest("asset/gold_cny/date-classification", classifications),
            },
            "classification_date_digests": {
                category: domain_digest(f"asset/gold_cny/category/{category}/dates", dates)
                for category, dates in category_dates.items()
            },
            # Keep the artifact compact: complete per-date classifications are committed
            # by the digest above; only genuinely absent rows are expanded.
            "ambiguous_dates_expanded": False,
            "ambiguous_dates_count": 0,
            "independent_close_differs_from_canonical": {
                "count": len(close_diff_dates),
                "dates_sha256": domain_digest("asset/gold_cny/independent-close-diff-dates", close_diff_dates),
            },
        }
    )

    for symbol in ("nasdaq_composite", "sp500"):
        assets[symbol].update(
            {
                "provider_label_only": True,
                "row_level_source_proof": False,
                "provider_caveat": "provider labels are fixture metadata only; no frozen raw provider file is available",
            }
        )

    return {
        "schema_version": "public-history-ohlc-provenance-v1",
        "artifact_semantics": {
            "immutable_for_input_hashes": True,
            "contains_wall_clock_time": False,
            "reads_strategy_performance": False,
            "mutates_public_history_fixture": False,
        },
        "generator": generator_entry,
        "inputs": {
            "public_history_fixture": fixture_entry,
            "choice_gc00y_source": source_entry,
            "production_apply_report": production_report_entry,
        },
        "rules": {
            "target_assets": list(TARGET_SYMBOLS),
            "row_validation": "strictly increasing canonical ISO dates; finite positive canonical prices; OHLC is either all-null, canonical-close fallback only, or four finite positive fields; complete bars must satisfy low <= min(open, close) <= max(open, close) <= high; volume is null or finite nonnegative",
            "gold_conversion_formula": "CNY_per_gram = GC00Y_USD_per_troy_oz * CNY_per_USD / 31.1034768, rounded HALF_UP to six decimals",
            "fx_policy": "production apply used latest causal CNY_per_USD; fixture usd_per_cny is checked only for causal date coverage with <=7 calendar-day staleness because its serialized precision cannot reproduce production values",
            "choice_value_verification": {
                "ohlc": "intersect the exact Decimal CNY_per_USD intervals implied by each current 6dp O/H/L/C value and corresponding Choice field; require one non-empty common interval",
                "volume": "exact Decimal equality with the same-date Choice row",
                "failure": "fail closed; no similarity threshold",
            },
            "gold_classification": {
                "missing": "all four fixture OHLC fields are null, or open/high/low are null while close_prices equals canonical prices (API close fallback)",
                "choice_imported": "date is listed in the immutable successful production apply report; current O/H/L/C jointly fit one Choice-to-CNY 6dp rounding interval and volume exactly matches Choice",
                "native_preexisting": "complete fixture OHLC not listed among production Choice updates; exact upstream row provenance is not claimed",
                "anti_heuristic": "canonical prices != close_prices and numerical similarity are reported only as diagnostics and never used to assign provenance",
            },
            "digest_encoding": "sha256(prefix || UTF-8 domain || NUL || repeated canonical-JSON(record) || LF); canonical JSON sorts object keys and uses compact separators",
        },
        "choice_source_audit": {
            "sheet_name": parsed_source.sheet_name,
            "metadata_footer": parsed_source.metadata_footer,
            "source_rows": parsed_source.source_rows,
            "valid_rows": len(parsed_source.rows),
            "date_start": parsed_source.source_start,
            "date_end": parsed_source.source_end,
            "invalid_geometry_count": len(parsed_source.invalid_geometry_dates),
            "invalid_geometry_dates": list(parsed_source.invalid_geometry_dates),
            "zero_volume_rows": parsed_source.zero_volume,
        },
        "fx_input_audit": {
            "symbol": "usd_per_cny",
            "provider_label": fx_series.get("source"),
            "row_count": len(fx_date_strings),
            "date_start": fx_date_strings[0] if fx_date_strings else None,
            "date_end": fx_date_strings[-1] if fx_date_strings else None,
            "row_digest": {
                "algorithm": "sha256",
                "domain": "asset/usd_per_cny/date-price",
                "sha256": domain_digest(
                    "asset/usd_per_cny/date-price",
                    zip(fx_date_strings, fx_values),
                ),
            },
        },
        "assets": assets,
    }


def _file_entry(path: Path, payload: bytes) -> dict[str, Any]:
    return {
        "path": display_path(path),
        "bytes": len(payload),
        "sha256": sha256_bytes(payload),
    }


def _verify_expected(label: str, actual: str, expected: str | None) -> None:
    if expected is not None and actual.lower() != expected.lower():
        raise AuditError(f"{label} SHA-256 mismatch: expected {expected.lower()}, got {actual}")


def run_audit(
    *,
    fixture_path: Path,
    source_path: Path,
    production_report_path: Path,
    output_path: Path,
    expected_fixture_sha256: str | None = None,
    expected_source_sha256: str | None = None,
    check: bool = False,
) -> dict[str, Any]:
    fixture_path = Path(fixture_path)
    source_path = Path(source_path)
    production_report_path = Path(production_report_path)
    output_path = Path(output_path)
    if output_path.resolve() in (fixture_path.resolve(), source_path.resolve(), production_report_path.resolve()):
        raise AuditError("output must not overwrite an input")

    fixture_bytes = fixture_path.read_bytes()
    source_bytes = source_path.read_bytes()
    production_report_bytes = production_report_path.read_bytes()
    fixture_hash = sha256_bytes(fixture_bytes)
    source_hash = sha256_bytes(source_bytes)
    _verify_expected("fixture", fixture_hash, expected_fixture_sha256)
    _verify_expected("source", source_hash, expected_source_sha256)
    try:
        document = json.loads(fixture_bytes)
        production_report = json.loads(production_report_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuditError(f"fixture/report is not valid UTF-8 JSON: {error}") from error

    try:
        parsed_source = choice_parser.parse_choice_xlsx(source_path)
    except choice_parser.ValidationError as error:
        raise AuditError(str(error)) from error

    generator_bytes = Path(__file__).read_bytes()
    manifest = build_manifest(
        document=document,
        fixture_entry=_file_entry(fixture_path, fixture_bytes),
        source_entry=_file_entry(source_path, source_bytes),
        parsed_source=parsed_source,
        production_report_entry=_file_entry(production_report_path, production_report_bytes),
        production_report=production_report,
        generator_entry=_file_entry(Path(__file__), generator_bytes),
    )
    output_bytes = stable_json_bytes(manifest)

    # Fail if an input changed during the audit window.
    if sha256_bytes(fixture_path.read_bytes()) != fixture_hash:
        raise AuditError("fixture changed while audit was running")
    if sha256_bytes(source_path.read_bytes()) != source_hash:
        raise AuditError("source changed while audit was running")
    if production_report_path.read_bytes() != production_report_bytes:
        raise AuditError("production report changed while audit was running")

    if check:
        if not output_path.exists() or output_path.read_bytes() != output_bytes:
            raise AuditError(f"manifest is absent or stale: {output_path}")
    else:
        atomic_write(output_path, output_bytes)
    return manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--production-report", type=Path, default=DEFAULT_PRODUCTION_REPORT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--expected-fixture-sha256")
    parser.add_argument("--expected-source-sha256")
    parser.add_argument("--check", action="store_true", help="verify byte-for-byte output instead of writing")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    manifest = run_audit(
        fixture_path=args.fixture,
        source_path=args.source,
        production_report_path=args.production_report,
        output_path=args.output,
        expected_fixture_sha256=args.expected_fixture_sha256,
        expected_source_sha256=args.expected_source_sha256,
        check=args.check,
    )
    summary = {
        "output": display_path(args.output),
        "fixture_sha256": manifest["inputs"]["public_history_fixture"]["sha256"],
        "source_sha256": manifest["inputs"]["choice_gc00y_source"]["sha256"],
        "gold_classification_counts": manifest["assets"]["gold_cny"]["classification_counts"],
        "gold_independent_close_diff_count": manifest["assets"]["gold_cny"]["independent_close_differs_from_canonical"]["count"],
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
