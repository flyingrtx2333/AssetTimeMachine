#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate_strategy_protocol.py"
V1_MANIFEST = ROOT / "tools/research-results/strategy-validation/v11-protocol-manifest.json"
V2_MANIFEST = ROOT / "tools/research-results/strategy-validation/v11-protocol-manifest-v2.json"


class StrategyProtocolValidatorTests(unittest.TestCase):
    def run_validator(self, manifest: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), "--manifest", str(manifest.relative_to(ROOT))],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_v1_still_validates(self) -> None:
        result = self.run_validator(V1_MANIFEST)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PROTOCOL_VALID ATM-SVP-1", result.stdout)

    def test_v2_validates_with_its_own_frozen_policy(self) -> None:
        result = self.run_validator(V2_MANIFEST)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PROTOCOL_VALID ATM-SVP-2", result.stdout)
        self.assertIn("G4_domain_preserving_generalization=INVALID_SOURCE_UNAVAILABLE", result.stdout)
        self.assertIn("G5_execution_robustness=PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
