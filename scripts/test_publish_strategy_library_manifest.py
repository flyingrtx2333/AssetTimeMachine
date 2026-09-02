#!/usr/bin/env python3
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_strategy_library_manifest as publisher


class StrategyLibraryPublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.manifest_path = Path(self.tmp.name) / "manifest.json"
        self.manifest = {
            "schema_version": "strategy-library-v2",
            "batch_key": "strategy-batch-001",
            "strategies": [{"strategy_key": "s1", "result": "PASS"}],
        }
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    @staticmethod
    def response(status_code: int, body: object) -> Mock:
        response = Mock(status_code=status_code, text=json.dumps(body))
        response.json.return_value = body
        return response

    def test_validate_only_posts_only_validation_and_prints_stable_marker(self) -> None:
        validation = {
            "valid": True,
            "manifest_sha256": "a" * 64,
            "strategy_count": 1,
            "robust_pass_count": 1,
            "rejected_count": 0,
            "warnings": [],
        }
        with patch.object(publisher.requests, "post", return_value=self.response(200, validation)) as post:
            result = publisher.publish_manifest(
                manifest_path=self.manifest_path,
                token="frk_private",
                base_url="https://example.test/",
                validate_only=True,
                timeout=9,
            )
        self.assertEqual(result["mode"], "validate_only")
        self.assertEqual(post.call_count, 1)
        self.assertTrue(post.call_args.args[0].endswith("/strategy-imports/validate"))
        self.assertNotIn("frk_private", publisher.format_result_marker(result))
        self.assertIn("batch_key=strategy-batch-001", publisher.format_result_marker(result))
        self.assertIn("status=validated", publisher.format_result_marker(result))
        self.assertIn("count=1", publisher.format_result_marker(result))
        self.assertIn("manifest_sha256=" + "a" * 64, publisher.format_result_marker(result))

    def test_successful_publish_validates_imports_and_checks_completed_status(self) -> None:
        validation = {
            "valid": True,
            "manifest_sha256": "b" * 64,
            "strategy_count": 1,
            "robust_pass_count": 1,
            "rejected_count": 0,
            "warnings": [],
        }
        batch = {"batch_key": "strategy-batch-001", "status": "completed"}
        status = {
            "batch_key": "strategy-batch-001",
            "status": "completed",
            "strategy_count": 1,
            "failed_count": 0,
            "manifest_sha256": "b" * 64,
        }
        with (
            patch.object(
                publisher.requests,
                "post",
                side_effect=[self.response(200, validation), self.response(200, batch)],
            ) as post,
            patch.object(publisher.requests, "get", return_value=self.response(200, status)) as get,
        ):
            result = publisher.publish_manifest(
                manifest_path=self.manifest_path,
                token="frk_private",
                base_url="https://example.test",
                validate_only=False,
                timeout=12,
            )
        self.assertEqual(post.call_count, 2)
        self.assertEqual(get.call_count, 1)
        self.assertTrue(get.call_args.args[0].endswith("/strategy-imports/strategy-batch-001"))
        self.assertEqual(result["status"], status)
        marker = publisher.format_result_marker(result)
        self.assertIn("status=completed", marker)
        self.assertIn("failed_count=0", marker)
        self.assertNotIn("frk_private", marker)

    def test_http_failure_raises_without_leaking_request_payload_or_token(self) -> None:
        response = self.response(500, {"detail": "backend unavailable"})
        with patch.object(publisher.requests, "post", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "HTTP 500") as raised:
                publisher.publish_manifest(
                    manifest_path=self.manifest_path,
                    token="frk_do_not_print",
                    base_url="https://example.test",
                    validate_only=False,
                    timeout=10,
                )
        text = str(raised.exception)
        self.assertNotIn("frk_do_not_print", text)
        self.assertNotIn('"strategies"', text)

    def test_completed_with_failed_count_is_failure(self) -> None:
        validation = {"valid": True, "manifest_sha256": "e" * 64, "strategy_count": 1}
        batch = {"batch_key": "strategy-batch-001", "status": "completed"}
        status = {
            "batch_key": "strategy-batch-001",
            "status": "completed",
            "failed_count": 1,
        }
        with (
            patch.object(
                publisher.requests,
                "post",
                side_effect=[self.response(200, validation), self.response(200, batch)],
            ),
            patch.object(publisher.requests, "get", return_value=self.response(200, status)),
            self.assertRaisesRegex(RuntimeError, "failed_count=1"),
        ):
            publisher.publish_manifest(
                manifest_path=self.manifest_path,
                token="frk_private",
                base_url="https://example.test",
                validate_only=False,
                timeout=10,
            )

    def test_non_completed_status_is_failure(self) -> None:
        validation = {"valid": True, "manifest_sha256": "f" * 64, "strategy_count": 1}
        batch = {"batch_key": "strategy-batch-001", "status": "created"}
        status = {
            "batch_key": "strategy-batch-001",
            "status": "failed",
            "failed_count": 0,
        }
        with (
            patch.object(
                publisher.requests,
                "post",
                side_effect=[self.response(200, validation), self.response(200, batch)],
            ),
            patch.object(publisher.requests, "get", return_value=self.response(200, status)),
            self.assertRaisesRegex(RuntimeError, "status=failed"),
        ):
            publisher.publish_manifest(
                manifest_path=self.manifest_path,
                token="frk_private",
                base_url="https://example.test",
                validate_only=False,
                timeout=10,
            )

    def test_idempotent_completed_batch_is_success(self) -> None:
        validation = {"valid": True, "manifest_sha256": "c" * 64, "strategy_count": 1}
        batch = {"batch_key": "strategy-batch-001", "status": "completed"}
        status = {"batch_key": "strategy-batch-001", "status": "completed", "failed_count": 0}
        with (
            patch.object(
                publisher.requests,
                "post",
                side_effect=[self.response(200, validation), self.response(200, batch)],
            ),
            patch.object(publisher.requests, "get", return_value=self.response(200, status)),
        ):
            result = publisher.publish_manifest(
                manifest_path=self.manifest_path,
                token="frk_private",
                base_url="https://example.test",
                validate_only=False,
                timeout=10,
            )
        self.assertEqual(result["status"]["status"], "completed")

    def test_status_only_prints_marker_and_returns_zero_only_for_clean_completion(self) -> None:
        status = {
            "batch_key": "strategy-batch-001",
            "status": "completed",
            "strategy_count": 1,
            "failed_count": 0,
            "manifest_sha256": "d" * 64,
        }
        output = io.StringIO()
        with (
            patch.object(publisher, "resolve_token", return_value="frk_private"),
            patch.object(publisher.requests, "get", return_value=self.response(200, status)),
            patch("sys.argv", ["publisher", "--manifest", str(self.manifest_path), "--status-only"]),
            redirect_stdout(output),
        ):
            self.assertEqual(publisher.main(), 0)
        self.assertIn("STRATEGY_LIBRARY_STATUS", output.getvalue())
        self.assertIn("count=1", output.getvalue())
        self.assertNotIn("frk_private", output.getvalue())

    def test_resolve_token_prefers_environment(self) -> None:
        with patch.dict(os.environ, {"CUSTOM_TOKEN": "frk_from_env"}, clear=True):
            self.assertEqual(publisher.resolve_token("CUSTOM_TOKEN", None), "frk_from_env")

    def test_resolve_token_reads_private_file(self) -> None:
        token_file = Path(self.tmp.name) / "token.env"
        token_file.write_text('export CUSTOM_TOKEN="frk_from_file"\n', encoding="utf-8")
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(publisher.resolve_token("CUSTOM_TOKEN", token_file), "frk_from_file")

    def test_rejects_invalid_root_schema_and_empty_batch_key(self) -> None:
        with self.assertRaisesRegex(ValueError, "root must be an object"):
            publisher.validate_local_manifest([])
        with self.assertRaisesRegex(ValueError, "schema_version"):
            publisher.validate_local_manifest({"schema_version": "strategy-library-v1", "batch_key": "x"})
        with self.assertRaisesRegex(ValueError, "batch_key"):
            publisher.validate_local_manifest({"schema_version": "strategy-library-v2", "batch_key": "  "})
        for batch_key in ("../other", "batch..other", "batch?x=1", "batch#fragment", "batch/key", "batch\nforged"):
            with self.subTest(batch_key=batch_key), self.assertRaisesRegex(ValueError, "batch_key"):
                publisher.validate_local_manifest(
                    {"schema_version": "strategy-library-v2", "batch_key": batch_key}
                )

    def test_recursively_rejects_absolute_local_path_and_sensitive_fields(self) -> None:
        absolute = dict(self.manifest)
        for path_field in ("local_path", "localPath"):
            with self.subTest(path_field=path_field):
                absolute = dict(self.manifest)
                absolute["strategies"] = [{"evidence": {path_field: "/Users/me/private.json"}}]
                with self.assertRaisesRegex(ValueError, "absolute local_path"):
                    publisher.validate_local_manifest(absolute)

        for field in (
            "secret", "secret_key", "secretValue", "secrets", "token", "api_key", "apiKey",
            "access_token", "clientSecret", "password", "credential", "credentials", "authorization",
        ):
            with self.subTest(field=field):
                sensitive = dict(self.manifest)
                sensitive["strategies"] = [{"metadata": {field: "do-not-send"}}]
                with self.assertRaisesRegex(ValueError, "sensitive field"):
                    publisher.validate_local_manifest(sensitive)

    def test_validation_must_be_valid_and_batch_keys_must_match(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "valid=true"):
            publisher.require_valid_validation({"valid": False})
        with self.assertRaisesRegex(RuntimeError, "batch_key mismatch"):
            publisher.require_batch_key({"batch_key": "other"}, "strategy-batch-001", action="import")


if __name__ == "__main__":
    unittest.main()
