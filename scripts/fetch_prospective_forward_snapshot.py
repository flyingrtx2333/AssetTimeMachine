#!/usr/bin/env python3
"""Fetch a strictly validated frozen V11 forward snapshot from FlyingrtxFast.

Credentials are never accepted on the command line and are never written to output.
The API key must be provided through the FRK_TOKEN environment variable. The default
endpoint is the scope-protected production research proxy added to FlyingrtxFast.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_URL = (
    "https://resume.flyingrtx.com/api/v1/asset-time-machine/"
    "internal/prospective-forward-snapshots"
)
V11_STRATEGY_ID = "nfci-dual-core-v11"
V11_STRATEGY_VERSION = "dualcore-v11-2026-08-15"
V11_FROZEN_AT = "2026-08-15"
EXPECTED_SYMBOLS = {
    "gold_cny",
    "nasdaq",
    "sp500",
    "csi300",
    "shanghai_composite",
}


def finite_weights(raw: Any, *, label: str) -> dict[str, float]:
    if not isinstance(raw, dict) or set(raw) != EXPECTED_SYMBOLS:
        raise ValueError(f"{label} must contain exactly the five frozen V11 roles")
    result: dict[str, float] = {}
    for symbol, raw_value in raw.items():
        value = float(raw_value)
        if not math.isfinite(value) or value < -1e-12:
            raise ValueError(f"{label} contains invalid weight: {symbol}")
        result[symbol] = max(value, 0.0)
    if sum(result.values()) > 1.000001:
        raise ValueError(f"{label} gross exceeds 100%")
    return result


def validate_v11_snapshot(snapshot: Any) -> dict[str, Any]:
    if not isinstance(snapshot, dict):
        raise ValueError("V11 snapshot must be an object")
    if snapshot.get("strategy_id") != V11_STRATEGY_ID:
        raise ValueError("unexpected V11 strategy_id")
    if snapshot.get("strategy_version") != V11_STRATEGY_VERSION:
        raise ValueError("V11 strategy version drifted")
    if snapshot.get("frozen_at") != V11_FROZEN_AT:
        raise ValueError("V11 freeze date drifted")
    if snapshot.get("data_stale") is not False:
        raise ValueError("V11 forward snapshot requires fresh market data")
    desired = finite_weights(snapshot.get("desired_target_weights"), label="desired_target_weights")
    executed = finite_weights(snapshot.get("model_executed_weights"), label="model_executed_weights")
    desired_gross = float(snapshot.get("desired_gross_exposure"))
    model_gross = float(snapshot.get("model_gross_exposure"))
    desired_cash = float(snapshot.get("desired_cash_weight"))
    model_cash = float(snapshot.get("model_cash_weight"))
    for label, value in (
        ("desired_gross_exposure", desired_gross),
        ("model_gross_exposure", model_gross),
        ("desired_cash_weight", desired_cash),
        ("model_cash_weight", model_cash),
    ):
        if not math.isfinite(value) or value < -1e-12 or value > 1.000001:
            raise ValueError(f"invalid {label}")
    if abs(sum(desired.values()) - desired_gross) > 1e-6:
        raise ValueError("desired gross does not match desired target weights")
    if abs(sum(executed.values()) - model_gross) > 1e-6:
        raise ValueError("model gross does not match executed weights")
    if abs(desired_cash + desired_gross - 1.0) > 1e-6:
        raise ValueError("desired cash/gross accounting mismatch")
    for key in (
        "signal_date",
        "execution_date_hint",
        "data_cutoff",
        "dataset_hash",
        "engine_version",
        "target_fingerprint",
        "causal_input_fingerprint",
    ):
        if not isinstance(snapshot.get(key), str) or not snapshot[key]:
            raise ValueError(f"V11 snapshot missing {key}")
    if snapshot["signal_date"] > snapshot["data_cutoff"]:
        raise ValueError("V11 signal_date exceeds data_cutoff")
    if snapshot["execution_date_hint"] <= snapshot["signal_date"]:
        raise ValueError("V11 execution date must be after signal date")
    if not isinstance(snapshot.get("nfci"), dict):
        raise ValueError("V11 snapshot missing NFCI state")
    return snapshot


def select_v11_snapshot(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("forward snapshot response must be an object")
    snapshots = payload.get("snapshots")
    if not isinstance(snapshots, list):
        raise ValueError("forward snapshot response missing snapshots")
    matches = [item for item in snapshots if isinstance(item, dict) and item.get("strategy_id") == V11_STRATEGY_ID]
    if len(matches) != 1:
        raise ValueError("forward snapshot response must contain exactly one V11 snapshot")
    return validate_v11_snapshot(matches[0])


def request_payload(url: str, token: str, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "X-API-Key": token,
            "Accept": "application/json",
            "User-Agent": "AssetTimeMachine-ProspectiveForward/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read(300).decode("utf-8", "ignore")
        raise RuntimeError(f"forward snapshot API returned HTTP {error.code}: {body}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"forward snapshot API unavailable: {error.reason}") from error
    if not isinstance(payload, dict):
        raise RuntimeError("forward snapshot API returned non-object JSON")
    return payload


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        temp = Path(handle.name)
    temp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--url", default=os.environ.get("ATM_FORWARD_SNAPSHOT_URL", DEFAULT_URL))
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()

    token = os.environ.get("FRK_TOKEN", "").strip()
    if not token:
        raise SystemExit("FRK_TOKEN environment variable is required")
    if args.timeout < 1 or args.timeout > 120:
        raise SystemExit("timeout must be between 1 and 120 seconds")

    payload = request_payload(args.url, token, args.timeout)
    snapshot = select_v11_snapshot(payload)
    output = Path(args.output)
    atomic_write_json(output, snapshot)
    print(
        "PROSPECTIVE_V11_SNAPSHOT_FETCHED "
        f"signal_date={snapshot['signal_date']} data_cutoff={snapshot['data_cutoff']} "
        f"data_stale={str(snapshot['data_stale']).lower()} "
        f"rebalance={str(bool(snapshot.get('rebalance_recommended'))).lower()} "
        f"output={output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
