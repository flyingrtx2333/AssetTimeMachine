#!/usr/bin/env python3
"""Independent byte-grammar golden for RS-RANGE-BREADTH-21-252-001."""
import datetime as dt
import hashlib
import math
import struct
import unittest

DOMAIN = b"ATM_RS_RANGE_BREADTH_SCHEDULE_V1\0"
ASSETS = ("gold_cny", "nasdaq", "sp500")
EXPECTED_COMBINED = "a403012272e69b7c8516e5352cd6f0d2b389615ad65831a14163bd9476ea6df5"
EXPECTED_CANDIDATE = "83dd346fe7dd9ff5b20b22cae03d9673bf516afab7522c0c85fc06c4e3a6b45f"


def u64(value): return struct.pack(">Q", value)
def f64(value): return struct.pack(">d", value)
def text(value):
    raw = value.encode()
    return u64(len(raw)) + raw
def boolean(value): return bytes((int(value),))
def array(items): return u64(len(items)) + b"".join(items)
def optional(value): return boolean(value is not None) + (f64(value) if value is not None else b"")


def rs(bar):
    o, h, low, c = bar
    return max(0.0, math.log(h / c) * math.log(h / o) + math.log(low / c) * math.log(low / o))


def factor(qs):
    long_sum = 0.0
    for q in qs: long_sum += q
    short_sum = 0.0
    for q in qs[-21:]: short_sum += q
    long_mean, short_mean = long_sum / 252.0, short_sum / 21.0
    x = short_mean / long_mean - 1.0
    return long_mean, short_mean, x, 1 if x <= 0 else 2


def header(anchor):
    windows = (
        ("full", None, "2020-09-09", "2021-01-01"),
        ("since_2020", "2020-01-01", "2020-09-09", "2021-01-01"),
    )
    out = DOMAIN
    out += u64(1)
    for value in (
        "RS-RANGE-BREADTH-21-252-001", "1", "91c6bd4b05fa34d637686f42e96e62ad6cd48189",
        "fixture.json", "1" * 64, "manifest.json", "2" * 64,
    ): out += text(value)
    out += array([text(x) for x in ASSETS]) + u64(252) + u64(21) + u64(21) + text(anchor)
    for value in (
        "Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)",
        "arm64-apple-macosx26.0", "macOS", "26.5.2", "25F84",
    ): out += text(value)
    encoded = []
    for name, requested, actual_start, actual_end in windows:
        encoded.append(text(name) + boolean(requested is not None) + (text(requested) if requested else b"") + text(actual_start) + text(actual_end))
    return out + array(encoded) + array([])


def target(variant, weights, event):
    rows = [text(symbol) + f64(weight) for symbol, weight in zip(ASSETS, weights)]
    return bytes((variant,)) + array(rows) + boolean(event) + boolean(not event)


def digest(variants):
    start = dt.date(2020, 1, 1)
    dates = [(start + dt.timedelta(days=i)).isoformat() for i in range(273)]
    low, high = (100.0, 110.0, 90.0, 100.0), (100.0, 120.0, 80.0, 100.0)
    bars = [low] * 272 + [high]
    reviews = []
    previous = {}
    for review_index, end in enumerate((251, 272)):
        asset_rows, states = [], []
        for offset, symbol in enumerate(ASSETS):
            window = bars[end - 251:end + 1]
            qs = [rs(x) for x in window]
            long_mean, short_mean, x, state = factor(qs)
            states.append(state)
            frozen = []
            for index, values in enumerate(window, start=end - 251):
                frozen.append(text(dates[index]) + b"".join(f64(v) for v in values) + text("synthetic") + optional(rs(values)))
            asset_rows.append(text(symbol) + text(f"source-{offset}") + text("CNY") + array(frozen)
                              + optional(long_mean) + optional(short_mean) + optional(x) + boolean(True) + bytes((state,)))
        calm = [i for i, state in enumerate(states) if state == 1]
        expanding = [i for i, state in enumerate(states) if state == 2]
        def weights(indices):
            return [1.0 / len(indices) if i in indices else 0.0 for i in range(3)] if indices else [0.0] * 3
        all_targets = {0: weights(calm), 1: [1.0 / 3.0] * 3, 2: weights(expanding)}
        encoded_targets = []
        for variant in variants:
            values = all_targets[variant]
            old = previous.get(variant, [0.0] * len(values))
            event = any(struct.pack(">d", a) != struct.pack(">d", b) for a, b in zip(old, values))
            previous[variant] = values
            encoded_targets.append(target(variant, values, event))
        reviews.append(text(dates[end]) + array(asset_rows) + array(encoded_targets))
    return hashlib.sha256(header(dates[251]) + array(reviews)).hexdigest()


class RSGoldenTests(unittest.TestCase):
    def test_independent_combined_golden(self):
        self.assertEqual(digest((0, 1, 2)), EXPECTED_COMBINED)

    def test_independent_candidate_golden(self):
        self.assertEqual(digest((0,)), EXPECTED_CANDIDATE)


if __name__ == "__main__":
    unittest.main()
