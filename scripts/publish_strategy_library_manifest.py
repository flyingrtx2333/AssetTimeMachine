#!/usr/bin/env python3
"""Safely validate, publish, and verify strategy-library-v2 manifests."""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path, PureWindowsPath
from typing import Any

import requests

DEFAULT_BASE_URL = "https://api.flyingrtx.com"
DEFAULT_TOKEN_ENV = "FRK_TOKEN"
DEFAULT_TOKEN_FILE = Path.home() / ".config" / "flyingrtx" / "asset-time-machine.env"
API_PATH = "/api/v1/asset-time-machine/internal/strategy-imports"

_SENSITIVE_FIELD_NAMES = {
    "api_key",
    "apikey",
    "access_token",
    "auth_token",
    "bearer_token",
    "client_secret",
    "password",
    "private_key",
    "secret",
    "secret_key",
    "token",
}


def resolve_token(token_env: str, token_file: Path | None) -> str:
    """Resolve an FRK key from the environment first, then a private env file."""
    token = os.environ.get(token_env, "").strip()
    if token:
        if not token.startswith("frk_"):
            raise ValueError(f"{token_env} is not an FRK API key")
        return token
    if token_file is not None and token_file.is_file():
        text = token_file.read_text(encoding="utf-8")
        match = re.search(
            rf"(?m)^\s*(?:export\s+)?{re.escape(token_env)}\s*=\s*['\"]?(frk_[A-Za-z0-9_-]+)['\"]?\s*(?:#.*)?$",
            text,
        )
        if match:
            return match.group(1)
    raise ValueError(
        f"API key unavailable: set {token_env} or store it in the configured private token file"
    )


def _canonical_field_name(name: str) -> str:
    snake = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", name)
    return re.sub(r"[^a-z0-9]+", "_", snake.lower()).strip("_")


def _is_sensitive_field(name: str) -> bool:
    canonical = _canonical_field_name(name)
    parts = set(canonical.split("_"))
    return (
        canonical in _SENSITIVE_FIELD_NAMES
        or bool(parts & {"secret", "secrets", "credential", "credentials", "authorization"})
        or canonical.endswith("_api_key")
        or canonical.endswith("_password")
        or canonical.endswith("_secret")
        or canonical.endswith("_token")
    )


def _check_safe_fields(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            child_path = f"{path}.{key_text}"
            if _is_sensitive_field(key_text):
                raise ValueError(f"manifest contains sensitive field at {child_path}")
            if _canonical_field_name(key_text) == "local_path" and isinstance(child, str):
                if Path(child).expanduser().is_absolute() or PureWindowsPath(child).is_absolute():
                    raise ValueError(f"manifest contains absolute local_path at {child_path}")
            _check_safe_fields(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _check_safe_fields(child, f"{path}[{index}]")


def validate_local_manifest(manifest: Any) -> dict[str, Any]:
    """Validate the wire-safety invariants before any HTTP request."""
    if not isinstance(manifest, dict):
        raise ValueError("manifest root must be an object")
    if manifest.get("schema_version") != "strategy-library-v2":
        raise ValueError("manifest schema_version must be strategy-library-v2")
    batch_key = manifest.get("batch_key")
    if (
        not isinstance(batch_key, str)
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}", batch_key) is None
        or ".." in batch_key
    ):
        raise ValueError("manifest batch_key must be one safe URL-segment identifier")
    _check_safe_fields(manifest)
    return manifest


def load_manifest(manifest_path: Path) -> dict[str, Any]:
    value = json.loads(manifest_path.expanduser().read_text(encoding="utf-8"))
    return validate_local_manifest(value)


def response_json(response: requests.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return None


def require_success(
    response: requests.Response,
    *,
    action: str,
    secret: str | None = None,
) -> Any:
    """Return JSON for 2xx responses; raise a body-free error otherwise."""
    if 200 <= response.status_code < 300:
        return response_json(response)
    # Do not include the response body: a misbehaving backend could echo the
    # submitted manifest or authentication material in an error detail.
    del secret
    raise RuntimeError(f"{action} failed with HTTP {response.status_code}")


def _require_object(value: Any, *, action: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RuntimeError(f"{action} returned non-object JSON")
    return value


def require_valid_validation(validation: dict[str, Any]) -> None:
    if validation.get("valid") is not True:
        raise RuntimeError("strategy manifest validation did not return valid=true")


def require_batch_key(value: dict[str, Any], expected: str, *, action: str) -> None:
    actual = value.get("batch_key")
    if actual != expected:
        raise RuntimeError(
            f"{action} batch_key mismatch: expected={expected!r} actual={actual!r}"
        )


def require_completed(status: dict[str, Any], *, expected_batch_key: str) -> None:
    require_batch_key(status, expected_batch_key, action="strategy import status")
    actual_status = status.get("status")
    if actual_status != "completed":
        raise RuntimeError(f"strategy import status={actual_status}; expected completed")
    failed_count = status.get("failed_count")
    if failed_count != 0:
        raise RuntimeError(f"strategy import completed with failed_count={failed_count}; expected 0")


def get_batch_status(
    *, batch_key: str, token: str, base_url: str, timeout: float
) -> dict[str, Any]:
    api_root = base_url.rstrip("/") + API_PATH
    value = require_success(
        requests.get(
            f"{api_root}/{batch_key}",
            headers={"X-API-Key": token, "Accept": "application/json"},
            timeout=timeout,
        ),
        action="strategy import batch status",
        secret=token,
    )
    return _require_object(value, action="strategy import batch status")


def publish_manifest(
    *,
    manifest_path: Path,
    token: str,
    base_url: str,
    validate_only: bool,
    timeout: float,
) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    batch_key = manifest["batch_key"]
    api_root = base_url.rstrip("/") + API_PATH
    headers = {
        "X-API-Key": token,
        "Accept": "application/json",
        "Content-Type": "application/json",
    }

    validation = _require_object(
        require_success(
            requests.post(
                api_root + "/validate",
                headers=headers,
                json=manifest,
                timeout=timeout,
            ),
            action="strategy manifest validation",
            secret=token,
        ),
        action="strategy manifest validation",
    )
    require_valid_validation(validation)
    if validate_only:
        return {
            "mode": "validate_only",
            "batch_key": batch_key,
            "validation": validation,
        }

    batch = _require_object(
        require_success(
            requests.post(api_root, headers=headers, json=manifest, timeout=timeout),
            action="strategy manifest import",
            secret=token,
        ),
        action="strategy manifest import",
    )
    require_batch_key(batch, batch_key, action="strategy manifest import")

    status = get_batch_status(
        batch_key=batch_key,
        token=token,
        base_url=base_url,
        timeout=timeout,
    )
    require_completed(status, expected_batch_key=batch_key)
    return {
        "mode": "publish",
        "batch_key": batch_key,
        "validation": validation,
        "batch": batch,
        "status": status,
    }


def _count_from(value: dict[str, Any], fallback: dict[str, Any] | None = None) -> Any:
    for key in ("strategy_count", "created_count", "imported_count"):
        if key in value:
            return value[key]
    if fallback is not None:
        return _count_from(fallback)
    return None


def format_result_marker(result: dict[str, Any]) -> str:
    validation = result.get("validation") or {}
    if result.get("mode") == "validate_only":
        return (
            "STRATEGY_LIBRARY_VALIDATE "
            f"batch_key={result.get('batch_key')} status=validated "
            f"count={_count_from(validation)} manifest_sha256={validation.get('manifest_sha256')} "
            f"robust_pass_count={validation.get('robust_pass_count')} "
            f"rejected_count={validation.get('rejected_count')}"
        )
    status = result.get("status") or {}
    return (
        "STRATEGY_LIBRARY_PUBLISH "
        f"batch_key={result.get('batch_key')} status={status.get('status')} "
        f"count={_count_from(status, validation)} "
        f"manifest_sha256={status.get('manifest_sha256') or validation.get('manifest_sha256')} "
        f"failed_count={status.get('failed_count')}"
    )


def format_status_marker(status: dict[str, Any]) -> str:
    return (
        "STRATEGY_LIBRARY_STATUS "
        f"batch_key={status.get('batch_key')} status={status.get('status')} "
        f"count={_count_from(status)} manifest_sha256={status.get('manifest_sha256')} "
        f"failed_count={status.get('failed_count')}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--token-env", default=DEFAULT_TOKEN_ENV)
    parser.add_argument("--token-file", default=str(DEFAULT_TOKEN_FILE))
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--status-only", action="store_true")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    if args.validate_only and args.status_only:
        parser.error("--validate-only and --status-only are mutually exclusive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    manifest = load_manifest(Path(args.manifest))
    batch_key = manifest["batch_key"]
    token = resolve_token(
        args.token_env,
        Path(args.token_file).expanduser().resolve() if args.token_file else None,
    )

    if args.status_only:
        status = get_batch_status(
            batch_key=batch_key,
            token=token,
            base_url=args.base_url,
            timeout=args.timeout,
        )
        print(format_status_marker(status))
        require_completed(status, expected_batch_key=batch_key)
        return 0

    result = publish_manifest(
        manifest_path=Path(args.manifest),
        token=token,
        base_url=args.base_url,
        validate_only=args.validate_only,
        timeout=args.timeout,
    )
    print(format_result_marker(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
