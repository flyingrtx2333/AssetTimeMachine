#!/usr/bin/env python3
"""Verify the real Mac credential API with synthetic values in a temporary signed app."""
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source_app = root / "build/AssetTimeMachine-Native.app"
identity_text = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
match = re.search(r'"(Apple Development:[^"]+)"', identity_text)
if not match:
    raise SystemExit("A development signing identity is required")
entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(source_app)], stderr=subprocess.DEVNULL)
if "keychain-access-groups" not in plistlib.loads(entitlements):
    raise SystemExit("The signed app must declare its authorized keychain identity")
with tempfile.TemporaryDirectory(prefix="atm-keychain-system-") as temporary:
    folder = Path(temporary)
    app = folder / "KeychainProbe.app"
    contents = app / "Contents"
    executable = contents / "MacOS/KeychainProbe"
    executable.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.flyingrtx.AssetTimeMachine.mac",
        "CFBundleExecutable": "KeychainProbe", "CFBundlePackageType": "APPL",
    }))
    shutil.copy2(source_app / "Contents/embedded.provisionprofile", contents / "embedded.provisionprofile")
    entitlement_path = folder / "entitlements.plist"
    entitlement_path.write_bytes(entitlements)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-o", str(executable),
        str(root / "AssetTimeMachine/Services/KeychainTokenStore.swift"),
        str(root / "scripts/tests/KeychainTokenStoreSystemProbe.swift")], check=True)
    subprocess.run(["codesign", "--force", "--options", "runtime", "--entitlements", str(entitlement_path),
                    "--sign", match.group(1), str(app)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
