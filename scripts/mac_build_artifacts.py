#!/usr/bin/env python3
"""Install verified Mac apps and remove only known, unused local build products."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
INSTALL_NAMES = {
    "AssetTimeMachine-Native.app": "AssetTimeMachine-Native-Previous.app",
    "AssetTimeMachine-Mac-Signed.app": "AssetTimeMachine-Mac-Signed-Previous.app",
    "AssetTimeMachine-Mac.app": "AssetTimeMachine-Mac-Previous.app",
}
# Current launch/performance caches and the latest iPhone validation stay in place.
OLD_DERIVED_DATA = {
    "DerivedData-Catalyst", "ios-compat", "ios-release", "ios-sim-time-machine",
    "ios-sync-validation", "ios-ui-verification", "iphone-final", "mac-compat-final",
    "mac-development", "mac-perf-release", "mac-signed-development", "native-backtest",
    "native-mac-signed", "native-mac-video", "native-signed-release",
    "records-ios-check", "sync-audit-ios",
}
XCODE_ENTRIES = {
    "Build", "Logs", "Index.noindex", "info.plist", "SourcePackages",
    "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex",
    "SDKExplicitPrecompiledModules", "SymbolCache.noindex",
}
OLD_NATIVE_NAMES = {
    "AssetTimeMachine-Native-Diagnostic.app", "AssetTimeMachine-Native-ReadWrite.app",
    "AssetTimeMachine-Native-Mac-20260929.app",
}


def process_commands():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,command="], check=True, capture_output=True, text=True
    )
    commands = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and int(parts[0]) not in {os.getpid(), os.getppid()}:
            commands.append(parts[1])
    return commands


def build_is_running(commands):
    for command in commands:
        parts = command.split()
        executable = Path(parts[0]).name if parts else ""
        if executable in {"xcodebuild", "swift-build", "swift-test", "swiftc", "swift-frontend", "clang", "clang++"}:
            return True
        if executable == "swift" and len(parts) > 1 and parts[1] in {"build", "test"}:
            return True
    return False


def path_is_running(path, commands):
    return any(str(path) + "/" in command or str(path) in command.split() for command in commands)


def verify_app(path):
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"App is missing or is a symlink: {path.name}")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.flyingrtx.AssetTimeMachine.mac":
        raise ValueError(f"Unexpected app identity: {path.name}")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)], check=True)


def valid_app(path):
    try:
        verify_app(path)
        return True
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        return False


def build_root(root):
    build = root / "build"
    if build.is_symlink() or build.resolve().parent != root.resolve():
        raise ValueError("The build directory must be a real directory inside this checkout")
    build.mkdir(exist_ok=True)
    return build


def install_app(root, source, name):
    build = build_root(root)
    if name not in INSTALL_NAMES or not source.resolve().is_relative_to(build.resolve()):
        raise ValueError("Installation is restricted to project build products")
    destination = build / name
    previous = build / INSTALL_NAMES[name]
    if source.resolve() in {destination.resolve(), previous.resolve()}:
        raise ValueError("Installation requires a separate new build")
    verify_app(source)
    with (build / ".artifacts.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        commands = process_commands()
        if any(path_is_running(p, commands) for p in (destination, previous)):
            raise RuntimeError("The current or previous app is running; its files were preserved")
        if destination.is_symlink() or previous.is_symlink():
            raise ValueError("App destinations must not be symlinks")
        if destination.exists():
            verify_app(destination)
        if previous.exists():
            verify_app(previous)
        with tempfile.TemporaryDirectory(prefix=".app-install-", dir=build) as directory:
            staged = Path(directory) / name
            subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
            verify_app(staged)
            if destination.exists():
                if previous.exists():
                    shutil.rmtree(previous)
                destination.rename(previous)
            try:
                staged.rename(destination)
            except OSError:
                if previous.exists() and not destination.exists():
                    previous.rename(destination)
                raise
    print(f"Installed {name}; retained at most one previous version.")


def protected_data_reason(path):
    if path.name in OLD_DERIVED_DATA:
        if not (path / "Build").is_dir() or any(p.name not in XCODE_ENTRIES for p in path.iterdir()):
            return "not a recognized Xcode build directory"
    for directory, folders, files in os.walk(path, followlinks=False):
        if any(name.endswith(".xcarchive") for name in folders):
            return "contains a release archive"
        for name in files:
            suffix = Path(name).suffix.lower()
            if suffix in {".store", ".sqlite", ".sqlite3", ".ipa"}:
                return "contains a database or release export"
            is_build_db = name == "build.db" and Path(directory).name == "XCBuildData"
            if suffix == ".db" and not is_build_db:
                return "contains a database outside Xcode build metadata"
    return None


def size_kib(path):
    return int(subprocess.check_output(["/usr/bin/du", "-sk", str(path)], text=True).split()[0])


def cleanup(root, apply=False, keep_app=None):
    build = build_root(root)
    with (build / ".artifacts.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = size_kib(build)
        report = {"applied": apply, "before_kib": before, "removed": [], "candidates": [], "skipped": []}
        if build_is_running(process_commands()):
            report["skipped"].append({"path": "build", "reason": "a build is running"})
        else:
            native_ready = all(valid_app(build / name) for name in (
                "AssetTimeMachine-Native.app", "AssetTimeMachine-Native-Previous.app"
            ))
            signed_ready = valid_app(build / "AssetTimeMachine-Mac-Signed.app")
            perf_ready = valid_app(build / "AssetTimeMachine-Mac-Perf.app")
            for path in sorted(build.iterdir()):
                name = path.name
                old_native = name in OLD_NATIVE_NAMES or re.fullmatch(
                    r"AssetTimeMachine-Native-\d{8}-\d{6}\.app", name
                )
                old_signed = re.fullmatch(r"AssetTimeMachine-Mac-Signed-Previous-\d{8}-\d{6}\.app", name)
                old_perf = name.startswith("AssetTimeMachine-Mac-Perf-") and name.endswith(".app")
                old_preview = name in {"AssetTimeMachine-Mac.app", "AssetTimeMachine-Mac-Preview.app", "AssetTimeMachine-Mac-Release.app"}
                candidate = (name in OLD_DERIVED_DATA or (old_native and native_ready)
                             or (old_signed and signed_ready and native_ready)
                             or (old_perf and perf_ready) or (old_preview and signed_ready))
                if not candidate or name == keep_app:
                    continue
                commands = process_commands()  # Recheck immediately before each removal.
                if path.is_symlink():
                    reason = "symlink preserved"
                elif build_is_running(commands) or path_is_running(path, commands):
                    reason = "in use"
                elif not path.is_dir():
                    reason = "unexpected file type"
                else:
                    reason = protected_data_reason(path)
                if reason:
                    report["skipped"].append({"path": name, "reason": reason})
                    continue
                report["candidates"].append({"path": name, "kib": size_kib(path)})
                if apply:
                    commands = process_commands()
                    if build_is_running(commands) or path_is_running(path, commands):
                        report["skipped"].append({"path": name, "reason": "became active before removal"})
                        continue
                    shutil.rmtree(path)
                    report["removed"].append(name)
        report["after_kib"] = size_kib(build)
        report["reclaimed_kib"] = report["before_kib"] - report["after_kib"]
        if apply:
            (build / "artifact-cleanup-report.json").write_text(json.dumps(report, indent=2) + "\n")
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    clean = sub.add_parser("clean", help="List safe candidates; delete only with --apply")
    clean.add_argument("--apply", action="store_true")
    clean.add_argument("--keep-app", choices=INSTALL_NAMES, help="Preserve the variant just built")
    install = sub.add_parser("install", help="Verify, replace fixed app, retain one rollback")
    install.add_argument("source", type=Path)
    install.add_argument("name", choices=INSTALL_NAMES)
    args = parser.parse_args()
    if args.command == "install":
        install_app(ROOT, args.source, args.name)
    else:
        report = cleanup(ROOT, args.apply, args.keep_app)
        if args.apply:
            print(f"Removed {len(report['removed'])} unused products; "
                  f"reclaimed {report['reclaimed_kib'] / 1024 / 1024:.3f} GiB; "
                  f"skipped {len(report['skipped'])} protected or active paths.")
        else:
            print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
