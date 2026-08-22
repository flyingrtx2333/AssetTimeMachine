#!/usr/bin/env python3
"""Validate/publish one strategy-library-v1 manifest to FlyingrtxFast."""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import requests

from publish_factor_library_manifest import DEFAULT_BASE_URL, DEFAULT_TOKEN_ENV, require_success, resolve_token

ROOT = Path(__file__).resolve().parents[1]


def resolve_strategy_token(token_env: str, agents_file: Path | None) -> str:
    if agents_file is not None:
        return resolve_token(token_env, agents_file)
    candidates = [
        ROOT / "AGENTS.md",
        ROOT.parent / "FlyingrtxFast" / "AGENTS.md",
    ]
    last_error: Exception | None = None
    for candidate in candidates:
        if not candidate.is_file():
            continue
        try:
            return resolve_token(token_env, candidate)
        except ValueError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error
    return resolve_token(token_env, None)


def request_with_retry(method: str, url: str, *, attempts: int = 3, **kwargs):
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return requests.request(method, url, **kwargs)
        except (requests.Timeout, requests.ConnectionError) as exc:
            last_error = exc
            if attempt >= attempts:
                raise
            time.sleep(float(attempt))
    raise last_error or RuntimeError("request retry failed")


def publish_manifest(*, manifest_path: Path, token: str, base_url: str, validate_only: bool, timeout: float) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("manifest root must be an object")
    headers = {"X-API-Key": token, "Accept": "application/json", "Content-Type": "application/json"}
    api_root = base_url.rstrip("/") + "/api/v1/asset-time-machine/internal/strategy-imports"
    validation = require_success(
        request_with_retry("POST", api_root + "/validate", headers=headers, json=manifest, timeout=timeout),
        action="strategy manifest validation",
    )
    if validate_only:
        return {"mode": "validate_only", "validation": validation}
    batch = require_success(
        request_with_retry("POST", api_root, headers=headers, json=manifest, timeout=timeout),
        action="strategy manifest import",
    )
    return {"mode": "publish", "validation": validation, "batch": batch}


def get_status(*, batch_key: str, token: str, base_url: str, timeout: float) -> dict[str, Any]:
    api_root = base_url.rstrip("/") + "/api/v1/asset-time-machine/internal/strategy-imports"
    value = require_success(
        request_with_retry(
            "GET", f"{api_root}/{batch_key}",
            headers={"X-API-Key": token, "Accept": "application/json"},
            timeout=timeout,
        ),
        action="strategy import batch status",
    )
    if not isinstance(value, dict):
        raise RuntimeError("strategy import batch status returned non-object JSON")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--token-env", default=DEFAULT_TOKEN_ENV)
    parser.add_argument("--agents-file")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--status-only", action="store_true")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    batch_key = str(manifest.get("batch_key") or "")
    if not batch_key:
        raise ValueError("manifest batch_key is missing")
    token = resolve_strategy_token(
        args.token_env,
        Path(args.agents_file).resolve() if args.agents_file else None,
    )
    if args.status_only:
        status = get_status(batch_key=batch_key, token=token, base_url=args.base_url, timeout=args.timeout)
        print(json.dumps(status, ensure_ascii=False, sort_keys=True))
        return 0
    result = publish_manifest(
        manifest_path=manifest_path,
        token=token,
        base_url=args.base_url,
        validate_only=args.validate_only,
        timeout=args.timeout,
    )
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    if not args.validate_only:
        batch = result.get("batch") or {}
        if batch.get("status") != "completed" or int(batch.get("failed_count") or 0) != 0:
            raise RuntimeError(f"strategy import did not complete cleanly: {batch}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
