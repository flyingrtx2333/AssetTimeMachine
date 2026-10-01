#!/usr/bin/env python3
"""Run isolated Release native Mac tours and measure physical footprint after 30s idle."""
import argparse
import json
import os
import re
import signal
import subprocess
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PERF = ROOT / "build" / "performance"
APP = ROOT / "build" / "native-mac" / "Build" / "Products" / "Release" / "AssetTimeMachine.app" / "Contents" / "MacOS" / "AssetTimeMachine"
FIXTURES = PERF


@contextmanager
def launch_fixture(app: Path, store: Path, arguments: list[str], log_path: Path):
    """Activate exactly one GUI process with isolated data and identify its actual PID."""
    if not store.is_file():
        raise FileNotFoundError(f"Isolated performance fixture is missing: {store}")
    app = app.resolve()
    executable = app / "Contents" / "MacOS" / "AssetTimeMachine"
    run_id = str(uuid.uuid4())
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        launcher = subprocess.Popen([
            "open", "-W", "-n", "-a", str(app), "--args",
            "-macPerfStorePath", str(store.resolve()), "-macPerfRunID", run_id, *arguments,
        ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        pid = None
        try:
            deadline = time.monotonic() + 15
            while pid is None:
                rows = subprocess.check_output(["ps", "-axo", "pid=,args="], text=True)
                matches = [int(row.split(None, 1)[0]) for row in rows.splitlines()
                           if str(executable) in row and run_id in row and "-macPerfStorePath" in row]
                if len(matches) > 1:
                    raise RuntimeError("Multiple processes used the same isolated test ID")
                if matches:
                    pid = matches[0]
                elif launcher.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"Could not identify the isolated GUI process: {log_path}")
                else:
                    time.sleep(0.25)
            yield pid
        finally:
            if pid is not None:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if launcher.poll() is None:
                try:
                    launcher.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    if pid is not None:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    launcher.terminate()
                    launcher.wait(timeout=5)


def wait_for_marker(pid: int, marker: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while not marker.exists():
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            raise RuntimeError(f"Native app exited before completing {marker}") from None
        if time.monotonic() > deadline:
            raise TimeoutError(f"Native operation did not complete: {marker}")
        time.sleep(0.25)


def footprint(pid: int) -> tuple[float, float]:
    output = subprocess.check_output(["vmmap", "-summary", str(pid)], text=True)
    current = re.search(r"^Physical footprint:\s+([\d.]+)M", output, re.MULTILINE)
    peak = re.search(r"^Physical footprint \(peak\):\s+([\d.]+)M", output, re.MULTILINE)
    if not current or not peak:
        raise RuntimeError("vmmap did not report physical footprint")
    return float(current.group(1)), float(peak.group(1))


def run(years: int, round_number: int) -> dict:
    store = FIXTURES / f"fixture-{years}y.store"
    if not store.is_file():
        raise FileNotFoundError(f"Isolated performance fixture is missing: {store}")
    marker = PERF / f"native-tour-{years}y-{round_number}.done"
    interaction_path = PERF / f"native-interaction-{years}y-{round_number}.json"
    log_path = PERF / f"native-tour-{years}y-{round_number}.log"
    marker.unlink(missing_ok=True)
    interaction_path.unlink(missing_ok=True)
    arguments = ["-macPerfAutoBrowse", "-macPerfCompletePath", str(marker),
                 "-macPerfInteractionOutput", str(interaction_path)]
    with launch_fixture(APP.parents[2], store, arguments, log_path) as pid:
        wait_for_marker(pid, marker, 180)
        time.sleep(30)
        current, peak = footprint(pid)
        return {"years": years, "round": round_number,
                "physicalFootprintMB": current, "peakMB": peak,
                "interactions": json.loads(interaction_path.read_text()) if interaction_path.exists() else None,
                "log": str(log_path)}


def main() -> None:
    global APP, PERF, FIXTURES
    parser = argparse.ArgumentParser()
    parser.add_argument("--years", nargs="+", type=int, default=[1, 5, 10])
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--app", type=Path, default=APP)
    parser.add_argument("--fixtures", type=Path, default=FIXTURES)
    parser.add_argument("--output", type=Path, default=PERF)
    args = parser.parse_args()
    APP, FIXTURES, PERF = args.app.resolve(), args.fixtures.resolve(), args.output.resolve()
    if APP.suffix == ".app":
        APP = APP / "Contents" / "MacOS" / "AssetTimeMachine"
    if not APP.is_file():
        parser.error(f"Release application is missing: {APP}")
    PERF.mkdir(parents=True, exist_ok=True)
    results = []
    for years in args.years:
        for round_number in range(1, args.rounds + 1):
            result = run(years, round_number)
            results.append(result)
            (PERF / "native-3round-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps(result, ensure_ascii=False), flush=True)
    (PERF / "native-3round-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
