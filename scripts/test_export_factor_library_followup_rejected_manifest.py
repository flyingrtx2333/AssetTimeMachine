#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import unittest
from pathlib import Path

from export_factor_library_followup_rejected_manifest import build_manifest


class FollowupRejectedFactorLibraryExportTests(unittest.TestCase):
    def test_exports_exact_four_followup_formal_factors(self) -> None:
        manifest = build_manifest(source_commit="c" * 40)
        expected = {
            "atm.event.baa10y_20",
            "atm.event.epu_usepuindxd_20",
            "atm.event.move_20",
            "atm.event.vrp_proxy_vix_rv21_252median",
        }
        factors = manifest["factors"]
        self.assertEqual({factor["factor_key"] for factor in factors}, expected)
        self.assertEqual(len(factors), 4)
        self.assertEqual(manifest["methodology"]["factor_catalog_before_batch"], 18)
        self.assertEqual(manifest["methodology"]["factor_catalog_after_batch"], 22)
        self.assertEqual(manifest["methodology"]["this_batch_rejected_candidates"], 4)
        self.assertEqual(manifest["observations"], [])
        for factor in factors:
            self.assertEqual(factor["version"]["lifecycle_status"], "rejected")
            self.assertEqual(factor["version"]["materialization_policy"], "none")
            self.assertEqual(factor["results"], [])
            self.assertRegex(factor["version"]["code_sha256"], r"^[0-9a-f]{64}$")

    def test_every_factor_has_preregistration_and_formal_result_evidence(self) -> None:
        manifest = build_manifest(source_commit="d" * 40)
        by_factor: dict[str, list[dict]] = {}
        for artifact in manifest["artifacts"]:
            factor_key = artifact.get("factor_key")
            self.assertIsNotNone(factor_key)
            by_factor.setdefault(str(factor_key), []).append(artifact)
            path = Path(artifact["local_path"])
            self.assertTrue(path.is_file(), path)
            self.assertEqual(artifact["byte_size"], path.stat().st_size)
            self.assertEqual(artifact["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

        self.assertEqual(len(manifest["artifacts"]), 8)
        self.assertEqual(set(by_factor), {factor["factor_key"] for factor in manifest["factors"]})
        for factor_key, artifacts in by_factor.items():
            self.assertEqual(
                {item["artifact_type"] for item in artifacts},
                {"preregistration", "formal_result"},
                factor_key,
            )


if __name__ == "__main__":
    unittest.main()
