#!/usr/bin/env python3
"""Validate the AppLocalization catalog against Swift source literals."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "AssetTimeMachine"
CATALOG_PATH = SOURCE_ROOT / "Localizable.xcstrings"
LOCALES = ("en", "zh-Hans", "zh-Hant")

LOCALIZATION_CALL = re.compile(
    r'AppLocalization\.(?:string|format)\(\s*"((?:[^"\\]|\\.)*)"'
)
FORMAT_CALL = re.compile(
    r'AppLocalization\.format\(\s*"((?:[^"\\]|\\.)*)"'
)
NESTED_FORMAT_CALL = re.compile(
    r'AppLocalization\.format\(\s*AppLocalization\.string\(\s*"((?:[^"\\]|\\.)*)"'
)
CHINESE_LITERAL = re.compile(
    r'"((?:[^"\\]|\\.)*[\u3400-\u9fff](?:[^"\\]|\\.)*)"'
)
FORMAT_TOKEN = re.compile(
    r'%(?:\d+\$)?[-+ 0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?'
    r'(?:hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfFeEgGcCsSpaA%])'
)


def decoded_literal(value: str) -> str:
    return value.replace(r'\"', '"').replace(r"\n", "\n").replace(r"\\", "\\")


def format_signature(value: str) -> list[str]:
    return sorted(token for token in FORMAT_TOKEN.findall(value.replace("%%", "")) if token != "%")


def main() -> int:
    catalog = json.loads(CATALOG_PATH.read_text())["strings"]
    localized_keys: set[str] = set()
    format_keys: set[str] = set()
    chinese_literals: set[str] = set()

    for path in SOURCE_ROOT.rglob("*.swift"):
        source = path.read_text(errors="ignore")
        localized_keys.update(decoded_literal(match.group(1)) for match in LOCALIZATION_CALL.finditer(source))
        format_keys.update(decoded_literal(match.group(1)) for match in FORMAT_CALL.finditer(source))
        format_keys.update(decoded_literal(match.group(1)) for match in NESTED_FORMAT_CALL.finditer(source))
        chinese_literals.update(decoded_literal(match.group(1)) for match in CHINESE_LITERAL.finditer(source))

    missing = sorted((localized_keys | chinese_literals) - set(catalog))
    incomplete: list[tuple[str, str]] = []
    format_errors: list[tuple[str, str]] = []

    for key, entry in catalog.items():
        if not key:
            continue
        for locale in LOCALES:
            unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {})
            if unit.get("state") != "translated" or "value" not in unit:
                incomplete.append((key, locale))

    for key in format_keys:
        expected = format_signature(key)
        for locale in LOCALES:
            value = catalog.get(key, {}).get("localizations", {}).get(locale, {}).get("stringUnit", {}).get("value", "")
            if format_signature(value) != expected:
                format_errors.append((key, locale))

    if missing:
        print("Missing localization keys:", file=sys.stderr)
        for key in missing:
            print(f"  {key}", file=sys.stderr)
    if incomplete:
        print("Incomplete localizations:", file=sys.stderr)
        for key, locale in incomplete:
            print(f"  {locale}: {key}", file=sys.stderr)
    if format_errors:
        print("Format placeholder mismatches:", file=sys.stderr)
        for key, locale in format_errors:
            print(f"  {locale}: {key}", file=sys.stderr)

    if missing or incomplete or format_errors:
        return 1

    print(
        f"Localization audit passed: {len(catalog)} keys, "
        f"{len(localized_keys)} direct calls, {len(chinese_literals)} Chinese source literals."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
