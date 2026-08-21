#!/usr/bin/env python3
"""Publish a factor-library manifest to FlyingrtxFast without leaking local paths or API keys."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

DEFAULT_BASE_URL = "https://api.flyingrtx.com"
DEFAULT_TOKEN_ENV = "FRK_TOKEN"


@dataclass(frozen=True)
class UploadArtifact:
    artifact_key: str
    path: Path
    mime_type: str
    byte_size: int
    sha256: str


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_token(token_env: str, agents_file: Path | None) -> str:
    token = os.environ.get(token_env, "").strip()
    if token:
        if not token.startswith("frk_"):
            raise ValueError(f"{token_env} is not an FRK API key")
        return token
    if agents_file is not None:
        text = agents_file.read_text(encoding="utf-8")
        match = re.search(r"FRK_TOKEN\s*=\s*(frk_[A-Za-z0-9_-]+)", text)
        if match:
            return match.group(1)
    raise ValueError(
        f"API key unavailable: set {token_env} or pass --agents-file containing a local FRK_TOKEN"
    )


def prepare_upload_plan(
    manifest: dict[str, Any],
    *,
    manifest_root: Path,
) -> tuple[dict[str, Any], dict[str, UploadArtifact]]:
    wire = copy.deepcopy(manifest)
    raw_artifacts = manifest.get("artifacts") or []
    wire_artifacts = wire.get("artifacts") or []
    if len(raw_artifacts) != len(wire_artifacts):
        raise ValueError("artifact list drifted while preparing wire manifest")

    uploads: dict[str, UploadArtifact] = {}
    for raw, wire_item in zip(raw_artifacts, wire_artifacts, strict=True):
        artifact_key = str(raw.get("artifact_key") or "")
        if not artifact_key or artifact_key in uploads:
            raise ValueError(f"invalid or duplicate artifact_key: {artifact_key!r}")
        local_path = raw.get("local_path")
        if not isinstance(local_path, str) or not local_path:
            raise ValueError(f"artifact {artifact_key} is missing local_path")
        path = Path(local_path)
        if not path.is_absolute():
            path = manifest_root / path
        path = path.resolve()
        if not path.is_file():
            raise ValueError(f"artifact file missing: {artifact_key}: {path}")

        expected_size = int(raw.get("byte_size", -1))
        expected_sha = str(raw.get("sha256") or "")
        actual_size = path.stat().st_size
        actual_sha = sha256_file(path)
        if actual_size != expected_size:
            raise ValueError(
                f"artifact size mismatch for {artifact_key}: manifest={expected_size} actual={actual_size}"
            )
        if actual_sha != expected_sha:
            raise ValueError(f"artifact SHA mismatch for {artifact_key}")
        mime_type = str(raw.get("mime_type") or "application/octet-stream")
        uploads[artifact_key] = UploadArtifact(
            artifact_key=artifact_key,
            path=path,
            mime_type=mime_type,
            byte_size=actual_size,
            sha256=actual_sha,
        )
        wire_item.pop("local_path", None)

    return wire, uploads


def should_upload_artifacts(batch_status: str) -> bool:
    if batch_status in {"created", "staging", "failed"}:
        return True
    if batch_status in {"structured_completed", "artifact_pending", "completed"}:
        return False
    raise ValueError(f"unknown factor import batch status: {batch_status}")


def response_json(response: requests.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return {"text": response.text[:1000]}


def require_success(response: requests.Response, *, action: str) -> Any:
    if 200 <= response.status_code < 300:
        return response_json(response)
    body = response_json(response)
    detail = body.get("detail") if isinstance(body, dict) else None
    message = detail if detail is not None else body
    raise RuntimeError(f"{action} failed with HTTP {response.status_code}: {message}")


def get_remote_manifest(*, batch_key: str, token: str, base_url: str, timeout: float) -> dict[str, Any]:
    api_root = base_url.rstrip("/") + "/api/v1/asset-time-machine/internal/factor-imports"
    value = require_success(
        requests.get(
            f"{api_root}/{batch_key}/manifest",
            headers={"X-API-Key": token, "Accept": "application/json"},
            timeout=timeout,
        ),
        action="factor import stored manifest",
    )
    if not isinstance(value, dict):
        raise RuntimeError("factor import stored manifest returned non-object JSON")
    return value


def json_diff_paths(left: Any, right: Any, path: str = "$") -> list[tuple[str, Any, Any]]:
    if type(left) is not type(right):
        return [(path, left, right)]
    if isinstance(left, dict):
        differences: list[tuple[str, Any, Any]] = []
        for key in sorted(set(left).union(right)):
            child = f"{path}.{key}"
            if key not in left:
                differences.append((child, "<missing>", right[key]))
            elif key not in right:
                differences.append((child, left[key], "<missing>"))
            else:
                differences.extend(json_diff_paths(left[key], right[key], child))
        return differences
    if isinstance(left, list):
        differences = []
        for index in range(max(len(left), len(right))):
            child = f"{path}[{index}]"
            if index >= len(left):
                differences.append((child, "<missing>", right[index]))
            elif index >= len(right):
                differences.append((child, left[index], "<missing>"))
            else:
                differences.extend(json_diff_paths(left[index], right[index], child))
        return differences
    return [] if left == right else [(path, left, right)]


def get_batch_status(*, batch_key: str, token: str, base_url: str, timeout: float) -> dict[str, Any]:
    api_root = base_url.rstrip("/") + "/api/v1/asset-time-machine/internal/factor-imports"
    value = require_success(
        requests.get(
            f"{api_root}/{batch_key}",
            headers={"X-API-Key": token, "Accept": "application/json"},
            timeout=timeout,
        ),
        action="factor import batch status",
    )
    if not isinstance(value, dict):
        raise RuntimeError("factor import batch status returned non-object JSON")
    return value


def publish_manifest(
    *,
    manifest_path: Path,
    token: str,
    base_url: str,
    validate_only: bool,
    timeout: float,
) -> dict[str, Any]:
    manifest_path = manifest_path.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("manifest root must be an object")
    # Exporter local paths are repository-root relative. The manifest currently lives under
    # tools/research-results/factor-library/, so locate the repository root by walking upward
    # until its source_repository assets are visible.
    manifest_root = manifest_path.parent
    for candidate in [manifest_path.parent, *manifest_path.parents]:
        if (candidate / "scripts").is_dir() and (candidate / "tools").is_dir():
            manifest_root = candidate
            break
    wire, uploads = prepare_upload_plan(manifest, manifest_root=manifest_root)

    headers = {"X-API-Key": token, "Accept": "application/json"}
    api_root = base_url.rstrip("/") + "/api/v1/asset-time-machine/internal/factor-imports"
    validation = require_success(
        requests.post(
            api_root + "/validate",
            headers={**headers, "Content-Type": "application/json"},
            json=wire,
            timeout=timeout,
        ),
        action="factor manifest validation",
    )
    if validate_only:
        return {"mode": "validate_only", "validation": validation}

    batch = require_success(
        requests.post(
            api_root,
            headers={**headers, "Content-Type": "application/json"},
            json=wire,
            timeout=timeout,
        ),
        action="factor import batch creation",
    )
    batch_key = str(wire.get("batch_key") or "")
    if not batch_key:
        raise ValueError("manifest batch_key is missing")

    uploaded: list[str] = []
    batch_status = str(batch.get("status") or "")
    if should_upload_artifacts(batch_status):
        for artifact_key, artifact in uploads.items():
            with artifact.path.open("rb") as handle:
                upload_response = requests.put(
                    f"{api_root}/{batch_key}/artifacts/{artifact_key}",
                    headers=headers,
                    files={
                        "file": (
                            artifact.path.name,
                            handle,
                            artifact.mime_type,
                        )
                    },
                    timeout=timeout,
                )
            require_success(upload_response, action=f"artifact upload {artifact_key}")
            uploaded.append(artifact_key)

    completed = require_success(
        requests.post(
            f"{api_root}/{batch_key}/complete",
            headers={**headers, "Content-Type": "application/json"},
            json=wire,
            timeout=timeout,
        ),
        action="factor import completion",
    )
    return {
        "mode": "publish",
        "validation": validation,
        "batch": batch,
        "uploaded_artifacts": uploaded,
        "completed": completed,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--token-env", default=DEFAULT_TOKEN_ENV)
    parser.add_argument("--agents-file")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--status-only", action="store_true")
    parser.add_argument("--complete-only", action="store_true")
    parser.add_argument("--diff-remote-manifest", action="store_true")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    token = resolve_token(
        args.token_env,
        Path(args.agents_file).resolve() if args.agents_file else None,
    )
    if args.status_only or args.complete_only or args.diff_remote_manifest:
        manifest_path = Path(args.manifest).resolve()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        batch_key = str(manifest.get("batch_key") or "")
        if not batch_key:
            raise ValueError("manifest batch_key is missing")
        if args.diff_remote_manifest:
            manifest_root = manifest_path.parent
            for candidate in [manifest_path.parent, *manifest_path.parents]:
                if (candidate / "scripts").is_dir() and (candidate / "tools").is_dir():
                    manifest_root = candidate
                    break
            wire, _ = prepare_upload_plan(manifest, manifest_root=manifest_root)
            remote = get_remote_manifest(
                batch_key=batch_key,
                token=token,
                base_url=args.base_url,
                timeout=args.timeout,
            )
            differences = json_diff_paths(wire, remote)
            print(f"FACTOR_LIBRARY_REMOTE_MANIFEST_DIFF count={len(differences)}")
            for path, local_value, remote_value in differences[:50]:
                local_text = repr(local_value)[:240]
                remote_text = repr(remote_value)[:240]
                print(f"DIFF path={path} local={local_text} remote={remote_text}")
            return 0
        if args.complete_only:
            manifest_root = manifest_path.parent
            for candidate in [manifest_path.parent, *manifest_path.parents]:
                if (candidate / "scripts").is_dir() and (candidate / "tools").is_dir():
                    manifest_root = candidate
                    break
            wire, _ = prepare_upload_plan(manifest, manifest_root=manifest_root)
            api_root = args.base_url.rstrip("/") + "/api/v1/asset-time-machine/internal/factor-imports"
            completed = require_success(
                requests.post(
                    f"{api_root}/{batch_key}/complete",
                    headers={
                        "X-API-Key": token,
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                    },
                    json=wire,
                    timeout=args.timeout,
                ),
                action="factor import completion",
            )
            print(
                "FACTOR_LIBRARY_COMPLETE_ONLY "
                f"batch_key={batch_key} status={completed.get('status')} "
                f"created_count={completed.get('created_count')} failed_count={completed.get('failed_count')}"
            )
            return 0
        status = get_batch_status(
            batch_key=batch_key,
            token=token,
            base_url=args.base_url,
            timeout=args.timeout,
        )
        print(
            "FACTOR_LIBRARY_BATCH_STATUS "
            f"batch_key={batch_key} status={status.get('status')} "
            f"created_count={status.get('created_count')} failed_count={status.get('failed_count')} "
            f"staged_bytes={status.get('staged_bytes')} manifest_sha256={status.get('manifest_sha256')} "
            f"error_message={status.get('error_message')} error_details={json.dumps(status.get('error_details_json'), ensure_ascii=False, sort_keys=True)}"
        )
        return 0
    result = publish_manifest(
        manifest_path=Path(args.manifest),
        token=token,
        base_url=args.base_url,
        validate_only=args.validate_only,
        timeout=args.timeout,
    )
    validation = result.get("validation") or {}
    print(
        "FACTOR_LIBRARY_PUBLISH_RESULT "
        f"mode={result['mode']} valid={validation.get('valid')} "
        f"manifest_sha256={validation.get('manifest_sha256')}"
    )
    if result["mode"] == "publish":
        completed = result.get("completed") or {}
        print(
            "FACTOR_LIBRARY_PUBLISH_COMPLETE "
            f"batch_key={completed.get('batch_key')} status={completed.get('status')} "
            f"uploaded_artifacts={len(result.get('uploaded_artifacts') or [])}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
