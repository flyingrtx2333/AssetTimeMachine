#!/usr/bin/env python3
"""Replay historical tools in their recorded Git source version without touching this checkout."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def replay(source_ref: str, entrypoint: str, arguments: list[str]) -> int:
    commit = subprocess.check_output(["git", "rev-parse", "--verify", f"{source_ref}^{{commit}}"], cwd=ROOT, text=True).strip()
    path = Path(entrypoint)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit("entrypoint must be a repository-relative script path")
    # Local shared clone retains the exact Git identity required by formal guards.
    # It contains committed source only, leaving all current UI/sync edits untouched.
    with tempfile.TemporaryDirectory(prefix="atm-legacy-replay-") as temporary:
        checkout = Path(temporary) / "repository"
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(ROOT), str(checkout)], check=True)
        subprocess.run(["git", "-C", str(checkout), "checkout", "--quiet", "--detach", commit], check=True)
        target = checkout / path
        if not target.is_file():
            raise SystemExit(f"{entrypoint} is absent from {commit}")
        environment = os.environ.copy()
        environment.pop("ATM_LEGACY_SOURCE_REF", None)
        print(f"LEGACY_SOURCE_COMMIT={commit}", flush=True)
        if path.suffix == ".py":
            command = [sys.executable, str(target), *arguments]
        else:
            raise SystemExit("Use an original Python orchestrator; raw Swift fragments are not standalone tools")
        return subprocess.run(command, cwd=checkout, env=environment).returncode


def redirect_historical(entrypoint: str, arguments: list[str]) -> None:
    args = list(arguments)
    source_ref = os.environ.get("ATM_LEGACY_SOURCE_REF")
    if "--legacy-ref" in args:
        index = args.index("--legacy-ref")
        if index + 1 >= len(args):
            raise SystemExit("--legacy-ref requires the source commit recorded in the original evidence")
        source_ref = args[index + 1]
        del args[index:index + 2]
    if not source_ref:
        raise SystemExit(
            "This command belongs to a historical frozen study. Supply --legacy-ref <recorded-source-commit> "
            "or ATM_LEGACY_SOURCE_REF to replay it unchanged. Current research uses: "
            "swift run -c release AssetTimeMachineResearch run --config FILE --history FILE --output NEW_DIRECTORY."
        )
    relative = str(Path(entrypoint).resolve().relative_to(ROOT))
    raise SystemExit(replay(source_ref, relative, args))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--entrypoint", required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    forwarded = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    raise SystemExit(replay(args.source_ref, args.entrypoint, forwarded))


if __name__ == "__main__":
    main()
