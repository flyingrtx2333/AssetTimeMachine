#!/usr/bin/env python3
"""Unit tests for the cross-repo artifact path resolver."""
from __future__ import annotations

import json
import lzma
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import artifact_paths as ap  # noqa: E402


class ArchiveRelativeTests(unittest.TestCase):
    def test_research_results_prefix(self) -> None:
        self.assertEqual(
            ap.archive_relative("tools/research-results/strategy-validation/trial-ledger.jsonl"),
            "research/asset-time-machine/strategy-validation/trial-ledger.jsonl",
        )

    def test_fixtures_prefix_lands_under_fixtures(self) -> None:
        self.assertEqual(
            ap.archive_relative("tools/fixtures/backtest-history/public_history.json"),
            "research/asset-time-machine/fixtures/backtest-history/public_history.json",
        )

    def test_non_artifact_path_is_not_mapped(self) -> None:
        self.assertIsNone(ap.archive_relative("scripts/validate_strategy_protocol.py"))
        self.assertIsNone(ap.archive_relative("AssetTimeMachine/Backtest/BacktestEngine.swift"))

    def test_nested_subpath_is_preserved(self) -> None:
        self.assertEqual(
            ap.archive_relative("tools/research-results/strategy-validation/runs/T-1/execution.json"),
            "research/asset-time-machine/strategy-validation/runs/T-1/execution.json",
        )


class ResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        # Resolve: macOS temp dirs live under /var, a symlink to /private/var, and the
        # resolver canonicalises every root it returns.
        base = Path(self._tmp.name).resolve()
        self.app = base / "AssetTimeMachine"
        self.archive = base / "FlyingrtxFast"
        (self.app / "scripts").mkdir(parents=True)
        (self.archive / ap.ARCHIVE_SUBDIR).mkdir(parents=True)
        self.logical = "tools/research-results/strategy-validation/trial-ledger.jsonl"
        self.env = mock.patch.dict(os.environ, {"ATM_RESEARCH_ROOT": str(self.archive)}, clear=False)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write(self, root: Path, logical: str, text: str) -> Path:
        path = root / logical
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def test_in_repo_wins_when_present(self) -> None:
        self._write(self.app, self.logical, "in-repo")
        self._write(self.archive / ap.ARCHIVE_SUBDIR / "strategy-validation", "trial-ledger.jsonl", "archive")
        with self.env:
            self.assertEqual(ap.resolve(self.logical, repo_root=self.app), self.app / self.logical)
            self.assertEqual(ap.read_text(self.logical, repo_root=self.app), "in-repo")

    def test_falls_back_to_archive_when_in_repo_missing(self) -> None:
        self._write(self.archive / ap.ARCHIVE_SUBDIR / "strategy-validation", "trial-ledger.jsonl", "archive")
        with self.env:
            resolved = ap.resolve(self.logical, repo_root=self.app)
            self.assertEqual(resolved, self.archive / ap.ARCHIVE_SUBDIR / "strategy-validation/trial-ledger.jsonl")
            self.assertEqual(ap.read_text(self.logical, repo_root=self.app), "archive")

    def test_missing_everywhere_returns_in_repo_path(self) -> None:
        """The error message should name the familiar in-repo location."""
        with self.env:
            resolved = ap.resolve(self.logical, repo_root=self.app)
            self.assertEqual(resolved, self.app / self.logical)
            self.assertFalse(resolved.exists())

    def test_for_write_never_escapes_the_app_repo(self) -> None:
        self._write(self.archive / ap.ARCHIVE_SUBDIR / "strategy-validation", "trial-ledger.jsonl", "archive")
        with self.env:
            resolved = ap.resolve(self.logical, repo_root=self.app, for_write=True)
            self.assertEqual(resolved, self.app / self.logical)

    def test_fixtures_map_under_fixtures(self) -> None:
        logical = "tools/fixtures/backtest-history/public_history.json"
        self._write(self.archive / ap.ARCHIVE_SUBDIR / "fixtures/backtest-history", "public_history.json", "{}")
        with self.env:
            self.assertEqual(
                ap.resolve(logical, repo_root=self.app),
                self.archive / ap.ARCHIVE_SUBDIR / "fixtures/backtest-history/public_history.json",
            )

    def test_archive_root_accepts_the_asset_time_machine_dir_directly(self) -> None:
        with mock.patch.dict(os.environ, {"ATM_RESEARCH_ROOT": str(self.archive / ap.ARCHIVE_SUBDIR)}):
            self.assertEqual(ap.archive_root(self.app), self.archive)

    def test_archive_root_raises_when_env_points_nowhere(self) -> None:
        """An explicitly misconfigured root must fail loudly, not fall back silently."""
        with mock.patch.dict(os.environ, {"ATM_RESEARCH_ROOT": str(self.app / "nope")}):
            with self.assertRaises(ap.ArtifactPathError):
                ap.archive_root(self.app)

    def test_archive_root_raises_when_env_lacks_the_archive_subdir(self) -> None:
        empty = self.app / "empty-repo"
        empty.mkdir()
        with mock.patch.dict(os.environ, {"ATM_RESEARCH_ROOT": str(empty)}):
            with self.assertRaises(ap.ArtifactPathError):
                ap.archive_root(self.app)

    def test_archive_root_absent_when_env_unset_and_no_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as isolated:
            lonely = Path(isolated).resolve() / "LonelyRepo"
            lonely.mkdir()
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("ATM_RESEARCH_ROOT", None)
                self.assertIsNone(ap.archive_root(lonely))


class CompressedArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name).resolve()
        self.app = base / "AssetTimeMachine"
        self.archive = base / "FlyingrtxFast"
        (self.app / "scripts").mkdir(parents=True)
        self.logical = "tools/research-results/strategy-validation/preregistrations/schedule.json"
        target = self.archive / ap.ARCHIVE_SUBDIR / "strategy-validation/preregistrations/schedule.json.xz"
        target.parent.mkdir(parents=True)
        self.payload = json.dumps({"review_count": 289, "grid": list(range(200))}).encode()
        with lzma.open(target, "wb") as handle:
            handle.write(self.payload)
        self.env = mock.patch.dict(os.environ, {"ATM_RESEARCH_ROOT": str(self.archive)}, clear=False)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_resolve_returns_the_xz_path(self) -> None:
        with self.env:
            resolved = ap.resolve(self.logical, repo_root=self.app)
            self.assertEqual(resolved.suffix, ".xz")
            self.assertTrue(resolved.exists())

    def test_read_bytes_decompresses_transparently(self) -> None:
        with self.env:
            self.assertEqual(ap.read_bytes(self.logical, repo_root=self.app), self.payload)

    def test_load_json_round_trips_through_compression(self) -> None:
        with self.env:
            self.assertEqual(ap.load_json(self.logical, repo_root=self.app), json.loads(self.payload))

    def test_in_repo_plain_file_still_wins_over_archive_xz(self) -> None:
        plain = self.app / self.logical
        plain.parent.mkdir(parents=True)
        plain.write_text('{"source": "in-repo"}', encoding="utf-8")
        with self.env:
            self.assertEqual(ap.load_json(self.logical, repo_root=self.app), {"source": "in-repo"})


class WorktreeAnchoringTests(unittest.TestCase):
    """Formal runs execute in a detached worktree, whose siblings are not the archive."""

    def setUp(self) -> None:
        if shutil.which("git") is None:  # pragma: no cover
            self.skipTest("git not available")
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name).resolve()
        self.main = self.base / "AssetTimeMachine"
        self.main.mkdir()
        # A fake archive, sibling of the MAIN checkout only.
        (self.base / "FlyingrtxFast" / ap.ARCHIVE_SUBDIR / "strategy-validation").mkdir(parents=True)

        git = ["git", "-C", str(self.main), "-c", "user.email=t@example.com", "-c", "user.name=t"]
        subprocess.run([*git, "init", "-q"], check=True, capture_output=True)
        (self.main / "seed.txt").write_text("seed", encoding="utf-8")
        subprocess.run([*git, "add", "seed.txt"], check=True, capture_output=True)
        subprocess.run([*git, "commit", "-qm", "seed"], check=True, capture_output=True)

        # A linked worktree far away from the main checkout.
        self.worktree = self.base / "elsewhere" / "wt"
        self.worktree.parent.mkdir(parents=True)
        subprocess.run(
            [*git, "worktree", "add", "--detach", str(self.worktree), "HEAD"],
            check=True,
            capture_output=True,
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_main_checkout_root_resolves_from_a_linked_worktree(self) -> None:
        self.assertEqual(ap.main_checkout_root(self.worktree), self.main)

    def test_main_checkout_root_is_none_for_a_plain_directory(self) -> None:
        plain = self.base / "not-a-repo"
        plain.mkdir()
        self.assertIsNone(ap.main_checkout_root(plain))

    def test_archive_is_found_via_the_main_checkout_not_the_worktree(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ATM_RESEARCH_ROOT", None)
            # The worktree has no sibling archive; the main checkout does.
            self.assertEqual(ap.archive_root(self.worktree), self.base / "FlyingrtxFast")

    def test_resolution_falls_back_from_a_worktree_to_the_archive(self) -> None:
        logical = "tools/research-results/strategy-validation/preregistrations/schedule.json"
        target = self.base / "FlyingrtxFast" / ap.ARCHIVE_SUBDIR / "strategy-validation/preregistrations/schedule.json.xz"
        target.parent.mkdir(parents=True)
        with lzma.open(target, "wb") as handle:
            handle.write(b'{"ok": true}')
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ATM_RESEARCH_ROOT", None)
            self.assertEqual(ap.load_json(logical, repo_root=self.worktree), {"ok": True})


class DescribeTests(unittest.TestCase):
    def test_describe_reports_both_roots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            app = base / "AssetTimeMachine"
            archive = base / "FlyingrtxFast"
            (app / "tools/research-results/strategy-validation").mkdir(parents=True)
            (archive / ap.ARCHIVE_SUBDIR / "strategy-validation").mkdir(parents=True)
            with mock.patch.dict(os.environ, {"ATM_RESEARCH_ROOT": str(archive)}):
                info = ap.describe(app)
            self.assertEqual(info["archive_root"], str(archive))
            self.assertTrue(info["in_repo_strategy_validation_exists"])
            self.assertTrue(info["archive_strategy_validation_exists"])


if __name__ == "__main__":
    unittest.main()
