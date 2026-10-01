import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import mac_build_artifacts as artifacts


class BuildArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.build.mkdir()
        self.processes = patch.object(artifacts, "process_commands", return_value=[])
        self.processes.start()
        self.addCleanup(self.processes.stop)
        self.valid = patch.object(artifacts, "valid_app", return_value=True)
        self.valid.start()
        self.addCleanup(self.valid.stop)

    def derived(self, name="ios-ui-verification"):
        path = self.build / name
        (path / "Build").mkdir(parents=True)
        (path / "info.plist").write_text("generated")
        return path

    def test_only_allowlisted_products_are_deleted(self):
        old = self.derived()
        old_app = self.build / "AssetTimeMachine-Native-20260930-115021.app"
        old_app.mkdir()
        protected = ["native-mac", "native-release", "ExecutionV4Compatibility",
                     "cloud-audit", "performance", "TestFlight-1.14-205",
                     "AssetTimeMachine-Native.app", "AssetTimeMachine-Native-Previous.app",
                     "AssetTimeMachine-Mac-Signed.app", "unrecognized-directory"]
        for name in protected:
            (self.build / name).mkdir()
        report = artifacts.cleanup(self.root, apply=True)
        self.assertFalse(old.exists())
        self.assertFalse(old_app.exists())
        self.assertTrue(all((self.build / name).exists() for name in protected))
        self.assertEqual(set(report["removed"]), {old.name, old_app.name})

    def test_dry_run_preserves_candidates(self):
        old = self.derived()
        report = artifacts.cleanup(self.root)
        self.assertTrue(old.exists())
        self.assertEqual(report["removed"], [])
        self.assertEqual(report["candidates"][0]["path"], old.name)

    def test_newly_built_preview_is_preserved(self):
        preview = self.build / 'AssetTimeMachine-Mac.app'
        preview.mkdir()
        artifacts.cleanup(self.root, True, keep_app=preview.name)
        self.assertTrue(preview.exists())
        artifacts.cleanup(self.root, True)
        self.assertFalse(preview.exists())

    def test_build_and_running_app_are_preserved(self):
        old = self.derived()
        with patch.object(artifacts, "process_commands", return_value=["/usr/bin/xcodebuild build"]):
            self.assertEqual(artifacts.cleanup(self.root, True)["removed"], [])
        with patch.object(artifacts, "process_commands", return_value=[str(old / "Build/Products/App.app/Contents/MacOS/App")]):
            report = artifacts.cleanup(self.root, True)
            self.assertEqual(report["removed"], [])
            self.assertEqual(report["skipped"][0]["reason"], "in use")
        self.assertTrue(old.exists())

    def test_symlinks_and_user_databases_are_preserved(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.build / "ios-ui-verification").symlink_to(outside, target_is_directory=True)
        old = self.derived("ios-release")
        (old / "Build/personal.store").write_text("do not delete")
        other = self.derived("ios-compat")
        (other / "Build/user.db").write_text("do not delete")
        artifacts.cleanup(self.root, True)
        self.assertTrue(outside.exists())
        self.assertTrue((self.build / "ios-ui-verification").is_symlink())
        self.assertTrue((old / "Build/personal.store").exists())
        self.assertTrue((other / "Build/user.db").exists())

    def test_old_native_apps_need_verified_current_and_rollback(self):
        old = self.build / "AssetTimeMachine-Native-20260930-115021.app"
        old.mkdir()
        with patch.object(artifacts, "valid_app", return_value=False):
            artifacts.cleanup(self.root, True)
        self.assertTrue(old.exists())

    def test_build_root_cannot_escape_checkout(self):
        self.build.rmdir()
        outside = self.root / "other"
        outside.mkdir()
        self.build.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            artifacts.cleanup(self.root, True)

    def test_failed_verification_preserves_current_and_rollback(self):
        current = self.build / "AssetTimeMachine-Native.app"
        previous = self.build / "AssetTimeMachine-Native-Previous.app"
        source = self.build / "new.app"
        for path in (current, previous, source):
            path.mkdir()
            (path / "marker").write_text(path.name)
        with patch.object(artifacts, "verify_app", side_effect=ValueError("bad signature")):
            with self.assertRaises(ValueError):
                artifacts.install_app(self.root, source, current.name)
        self.assertEqual((current / "marker").read_text(), current.name)
        self.assertEqual((previous / "marker").read_text(), previous.name)

    def test_repeated_installs_keep_only_current_and_previous(self):
        current = self.build / "AssetTimeMachine-Native.app"
        previous = self.build / "AssetTimeMachine-Native-Previous.app"
        source = self.build / "new.app"
        source.mkdir()
        with patch.object(artifacts, "verify_app"):
            for version in ("one", "two", "three"):
                (source / "marker").write_text(version)
                artifacts.install_app(self.root, source, current.name)
        self.assertEqual((current / "marker").read_text(), "three")
        self.assertEqual((previous / "marker").read_text(), "two")
        self.assertEqual(list(self.build.glob('.app-install-*')), [])

    def test_running_current_app_prevents_replacement(self):
        current = self.build / "AssetTimeMachine-Native.app"
        source = self.build / "new.app"
        for path in (current, source):
            path.mkdir()
        with patch.object(artifacts, "verify_app"), patch.object(
            artifacts, "process_commands", return_value=[str(current / "Contents/MacOS/AssetTimeMachine")]
        ):
            with self.assertRaises(RuntimeError):
                artifacts.install_app(self.root, source, current.name)
        self.assertTrue(current.exists())
        self.assertFalse((self.build / "AssetTimeMachine-Native-Previous.app").exists())

    def test_validation_cleans_temporary_products_on_success_and_failure(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        wrapper = scripts / "validate_xcode_build.sh"
        shutil.copyfile(Path(__file__).with_name(wrapper.name), wrapper)
        binaries = self.root / "bin"
        binaries.mkdir()
        fake = binaries / "xcodebuild"
        fake.write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n'
                        'if [[ "$1" == "-derivedDataPath" ]]; then mkdir -p "$2/Build"; fi\n'
                        'shift\ndone\nexit "$FAKE_BUILD_EXIT"\n')
        fake.chmod(0o755)
        for status in (0, 1):
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                               FAKE_BUILD_EXIT=str(status))
            result = subprocess.run(['bash', str(wrapper), 'native'], env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertEqual(list(self.build.glob('.validation-*')), [])


if __name__ == "__main__":
    unittest.main()
