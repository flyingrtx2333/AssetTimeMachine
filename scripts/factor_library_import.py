#!/usr/bin/env python3
"""Validate and upload factor-library-v1 manifests without persisting credentials."""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import secrets
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional


API_PREFIX = "/api/v1/asset-time-machine"
API_KEY_ENV = "FLYINGRTX_FACTOR_IMPORT_API_KEY"


class FactorImportClientError(RuntimeError):
    pass


def _api_key() -> str:
    value = os.getenv(API_KEY_ENV, "").strip()
    if not value:
        raise FactorImportClientError("请先设置 %s" % API_KEY_ENV)
    return value


def _redact(message: str, api_key: Optional[str]) -> str:
    return message.replace(api_key, "[已隐藏]") if api_key else message


def _url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + API_PREFIX + path


def _request(
    base_url: str,
    path: str,
    *,
    method: str,
    api_key: str,
    payload: Optional[Dict[str, Any]] = None,
    body: Optional[bytes] = None,
    content_type: str = "application/json",
) -> Dict[str, Any]:
    data = body
    if payload is not None:
        data = json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    request = urllib.request.Request(
        _url(base_url, path),
        data=data,
        method=method,
        headers={
            "X-API-Key": api_key,
            "Accept": "application/json",
            "Content-Type": content_type,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise FactorImportClientError(
            _redact("服务返回 %d：%s" % (exc.code, detail[:2000]), api_key)
        ) from exc
    except Exception as exc:
        raise FactorImportClientError(_redact(str(exc), api_key)) from exc
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise FactorImportClientError("服务返回了无法识别的响应") from exc


def _multipart_file(field_name: str, filename: str, mime_type: str, data: bytes):
    boundary = "----flyingrtx-factor-%s" % secrets.token_hex(12)
    body = (
        ("--%s\r\n" % boundary).encode("ascii")
        + (
            'Content-Disposition: form-data; name="%s"; filename="%s"\r\n'
            % (field_name, filename.replace('"', ""))
        ).encode("utf-8")
        + ("Content-Type: %s\r\n\r\n" % mime_type).encode("ascii")
        + data
        + ("\r\n--%s--\r\n" % boundary).encode("ascii")
    )
    return body, "multipart/form-data; boundary=%s" % boundary


def load_manifest(path: Path) -> Dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != "factor-library-v1":
        raise FactorImportClientError("只支持 factor-library-v1 清单")
    if not payload.get("batch_key") or not isinstance(payload.get("factors"), list):
        raise FactorImportClientError("清单缺少批次编号或因子目录")
    return payload


def validate_remote(manifest: Dict[str, Any], base_url: str, api_key: str) -> Dict[str, Any]:
    return _request(
        base_url,
        "/internal/factor-imports/validate",
        method="POST",
        api_key=api_key,
        payload=manifest,
    )


def upload_manifest(
    manifest: Dict[str, Any],
    base_url: str,
    api_key: str,
    repo_root: Path,
) -> Dict[str, Any]:
    batch = _request(
        base_url,
        "/internal/factor-imports",
        method="POST",
        api_key=api_key,
        payload=manifest,
    )
    batch_key = manifest["batch_key"]
    for artifact in manifest.get("artifacts", []):
        relative = Path(artifact.get("local_path") or "")
        path = (repo_root / relative).resolve()
        try:
            path.relative_to(repo_root.resolve())
        except ValueError as exc:
            raise FactorImportClientError("附件路径超出仓库目录") from exc
        data = path.read_bytes()
        mime_type = artifact.get("mime_type") or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        body, content_type = _multipart_file("file", path.name, mime_type, data)
        _request(
            base_url,
            "/internal/factor-imports/%s/artifacts/%s" % (
                batch_key,
                artifact["artifact_key"],
            ),
            method="PUT",
            api_key=api_key,
            body=body,
            content_type=content_type,
        )
    return _request(
        base_url,
        "/internal/factor-imports/%s/complete" % batch_key,
        method="POST",
        api_key=api_key,
        payload={},
    ) or batch


def import_status(batch_key: str, base_url: str, api_key: str) -> Dict[str, Any]:
    return _request(
        base_url,
        "/internal/factor-imports/%s" % batch_key,
        method="GET",
        api_key=api_key,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="因子研究清单导入工具")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "upload"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--manifest", required=True, type=Path)
        subparser.add_argument("--base-url", required=True)
        if command == "upload":
            subparser.add_argument(
                "--repo-root",
                type=Path,
                default=Path(__file__).resolve().parents[1],
            )
    status = subparsers.add_parser("status")
    status.add_argument("--batch-key", required=True)
    status.add_argument("--base-url", required=True)
    args = parser.parse_args()

    api_key = None
    try:
        api_key = _api_key()
        if args.command == "status":
            result = import_status(args.batch_key, args.base_url, api_key)
        else:
            manifest = load_manifest(args.manifest)
            if args.command == "validate":
                result = validate_remote(manifest, args.base_url, api_key)
            else:
                result = upload_manifest(
                    manifest,
                    args.base_url,
                    api_key,
                    args.repo_root.resolve(),
                )
        print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
        return 0
    except Exception as exc:
        print(_redact(str(exc), api_key), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
