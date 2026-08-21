#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from export_factor_library_event_manifest import build_manifest


class FactorLibraryEventManifestExportTests(unittest.TestCase):
    def test_builds_truthful_metadata_only_event_factor_catalog_sync(self) -> None:
        source_commit = "a" * 40
        manifest = build_manifest(source_commit=source_commit)

        self.assertEqual(manifest["schema_version"], "factor-library-v1")
        self.assertNotIn("sample_windows", manifest)
        self.assertEqual(manifest["source_commit"], source_commit)
        self.assertEqual(manifest["methodology"]["evaluation_kind"], "event_overlay")
        self.assertEqual(
            [factor["factor_key"] for factor in manifest["factors"]],
            [
                "atm.event.creditcash_hyg_shy_20",
                "atm.event.breadth_rsp_spy_20",
                "atm.event.highbeta_sphb_splv_20",
            ],
        )
        for factor in manifest["factors"]:
            self.assertEqual(factor["version"]["lifecycle_status"], "research")
            self.assertEqual(factor["version"]["materialization_policy"], "none")
            self.assertEqual(factor["results"], [])
            self.assertEqual(factor["version"]["observation_lag_sessions"], 1)
            self.assertEqual(factor["version"]["lookback_sessions"], 20)
            self.assertRegex(factor["version"]["code_sha256"], r"^[0-9a-f]{64}$")

        self.assertEqual(manifest["observations"], [])
        self.assertGreaterEqual(len(manifest["artifacts"]), 8)
        artifact_keys = [artifact["artifact_key"] for artifact in manifest["artifacts"]]
        self.assertEqual(len(artifact_keys), len(set(artifact_keys)))
        for artifact in manifest["artifacts"]:
            local_path = Path(artifact["local_path"])
            self.assertTrue(local_path.is_file(), local_path)
            self.assertEqual(artifact["byte_size"], local_path.stat().st_size)
            self.assertEqual(
                artifact["sha256"],
                hashlib.sha256(local_path.read_bytes()).hexdigest(),
            )

    def test_manifest_is_json_roundtrip_safe(self) -> None:
        manifest = build_manifest(source_commit="b" * 40)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True), encoding="utf-8")
            loaded = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(loaded, manifest)


if __name__ == "__main__":
    unittest.main()
