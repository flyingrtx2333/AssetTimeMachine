#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import unittest
from pathlib import Path

from export_factor_library_rejected_manifest import build_manifest


class RejectedFactorLibraryExportTests(unittest.TestCase):
    def test_exports_all_remaining_formal_candidates_without_survivorship_filter(self) -> None:
        manifest = build_manifest(source_commit="a" * 40)
        factors = manifest["factors"]
        self.assertEqual(len(factors), 15)
        keys = [factor["factor_key"] for factor in factors]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertNotIn("atm.event.breadth_rsp_spy_20", keys)
        self.assertNotIn("atm.event.highbeta_sphb_splv_20", keys)
        self.assertNotIn("atm.event.creditcash_hyg_shy_20", keys)
        self.assertEqual(manifest["methodology"]["formal_candidate_count"], 18)
        self.assertEqual(manifest["methodology"]["already_synced_research_candidates"], 3)
        self.assertEqual(manifest["methodology"]["this_batch_rejected_candidates"], 15)
        self.assertNotIn("sample_windows", manifest)
        self.assertEqual(manifest["observations"], [])

        for factor in factors:
            self.assertEqual(factor["version"]["lifecycle_status"], "rejected")
            self.assertEqual(factor["version"]["materialization_policy"], "none")
            self.assertEqual(factor["results"], [])
            self.assertRegex(factor["version"]["code_sha256"], r"^[0-9a-f]{64}$")
            self.assertGreaterEqual(factor["version"]["observation_lag_sessions"], 1)

    def test_every_rejected_factor_has_prereg_and_formal_result_artifacts(self) -> None:
        manifest = build_manifest(source_commit="b" * 40)
        by_factor: dict[str, list[dict]] = {}
        for artifact in manifest["artifacts"]:
            factor_key = artifact.get("factor_key")
            if factor_key:
                by_factor.setdefault(factor_key, []).append(artifact)
            path = Path(artifact["local_path"])
            self.assertTrue(path.is_file(), path)
            self.assertEqual(artifact["byte_size"], path.stat().st_size)
            self.assertEqual(artifact["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

        self.assertEqual(set(by_factor), {factor["factor_key"] for factor in manifest["factors"]})
        for factor_key, artifacts in by_factor.items():
            self.assertEqual({item["artifact_type"] for item in artifacts}, {"preregistration", "formal_result"}, factor_key)


if __name__ == "__main__":
    unittest.main()
