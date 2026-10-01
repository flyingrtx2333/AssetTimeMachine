#!/usr/bin/env python3
"""Compile the real Apple keychain adapter with simulated Security operations."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="atm-keychain-tests-") as folder:
    binary = Path(folder) / "KeychainAdapterTests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-o", str(binary),
        str(root / "AssetTimeMachine/Services/KeychainTokenStore.swift"),
        str(root / "scripts/tests/KeychainTokenStoreTests.swift")], check=True)
    subprocess.run([str(binary)], check=True)
