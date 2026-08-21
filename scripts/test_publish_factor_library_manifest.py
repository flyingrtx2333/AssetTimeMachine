#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from publish_factor_library_manifest import prepare_upload_plan, resolve_token, should_upload_artifacts


class FactorLibraryPublisherTests(unittest.TestCase):
    def test_prepare_upload_plan_strips_local_paths_and_verifies_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifact = root / "evidence.json"
            artifact.write_text('{"ok":true}\n', encoding="utf-8")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            manifest = {
                "schema_version": "factor-library-v1",
                "batch_key": "test-batch",
                "artifacts": [
                    {
                        "artifact_key": "evidence",
                        "artifact_type": "formal_result",
                        "original_name": "evidence.json",
                        "mime_type": "application/json",
                        "byte_size": artifact.stat().st_size,
                        "sha256": digest,
                        "local_path": "evidence.json",
                    }
                ],
            }
            wire, uploads = prepare_upload_plan(manifest, manifest_root=root)
            self.assertNotIn("local_path", wire["artifacts"][0])
            self.assertEqual(uploads["evidence"].path, artifact.resolve())
            self.assertEqual(uploads["evidence"].sha256, digest)

    def test_prepare_upload_plan_rejects_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifact = root / "evidence.json"
            artifact.write_text("{}\n", encoding="utf-8")
            manifest = {
                "artifacts": [
                    {
                        "artifact_key": "evidence",
                        "artifact_type": "formal_result",
                        "original_name": "evidence.json",
                        "mime_type": "application/json",
                        "byte_size": artifact.stat().st_size,
                        "sha256": "0" * 64,
                        "local_path": "evidence.json",
                    }
                ]
            }
            with self.assertRaises(ValueError):
                prepare_upload_plan(manifest, manifest_root=root)

    def test_resume_upload_policy_matches_server_batch_states(self) -> None:
        self.assertTrue(should_upload_artifacts("created"))
        self.assertTrue(should_upload_artifacts("staging"))
        self.assertTrue(should_upload_artifacts("failed"))
        self.assertFalse(should_upload_artifacts("structured_completed"))
        self.assertFalse(should_upload_artifacts("artifact_pending"))
        self.assertFalse(should_upload_artifacts("completed"))
        with self.assertRaises(ValueError):
            should_upload_artifacts("mystery")

    def test_resolve_token_prefers_environment_and_never_requires_printing_it(self) -> None:
        fake_token = "frk_" + "test_secret"
        with patch.dict(os.environ, {"FRK_TOKEN": fake_token}, clear=False):
            self.assertEqual(resolve_token("FRK_TOKEN", None), fake_token)

    def test_resolve_token_can_read_local_agents_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "AGENTS.md"
            fake_token = "frk_" + "local_only"
            path.write_text(f"FRK_TOKEN={fake_token}\n", encoding="utf-8")
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(resolve_token("FRK_TOKEN", path), fake_token)

    def test_resolve_token_can_read_markdown_bullet_code_agents_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "AGENTS.md"
            fake_token = "frk_" + "markdown_local_only"
            path.write_text(f"- `FRK_TOKEN={fake_token}`\n", encoding="utf-8")
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(resolve_token("FRK_TOKEN", path), fake_token)


if __name__ == "__main__":
    unittest.main()
