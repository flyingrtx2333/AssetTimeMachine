import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.factor_library_manifest import build_factor_manifest, write_manifest


class FactorLibraryManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = Path(__file__).resolve().parents[1]
        cls.source_commit = "a" * 40

    def test_manifest_is_complete_and_has_no_observations(self) -> None:
        manifest = build_factor_manifest(self.repo_root, self.source_commit)
        self.assertEqual(manifest["schema_version"], "factor-library-v1")
        self.assertEqual(len(manifest["factors"]), 184)
        self.assertEqual(len({row["factor_key"] for row in manifest["factors"]}), 184)
        self.assertEqual(manifest["observations"], [])
        self.assertGreater(len(manifest["artifacts"]), 0)
        self.assertTrue(any(row["results"] for row in manifest["factors"]))

    def test_artifact_hashes_and_sizes_match_files(self) -> None:
        manifest = build_factor_manifest(self.repo_root, self.source_commit)
        for artifact in manifest["artifacts"]:
            path = self.repo_root / artifact["local_path"]
            data = path.read_bytes()
            self.assertEqual(artifact["byte_size"], len(data))
            self.assertEqual(artifact["sha256"], hashlib.sha256(data).hexdigest())

    def test_manifest_output_is_byte_deterministic(self) -> None:
        manifest = build_factor_manifest(self.repo_root, self.source_commit)
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            write_manifest(manifest, first)
            write_manifest(build_factor_manifest(self.repo_root, self.source_commit), second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            loaded = json.loads(first.read_text(encoding="utf-8"))
            self.assertEqual(len(loaded["factors"]), 184)


if __name__ == "__main__":
    unittest.main()
