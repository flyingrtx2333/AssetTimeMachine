#!/usr/bin/env python3
"""Measure the isolated Release-optimized Mac preview with vmmap physical footprint."""

import argparse
import json
import re
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PERFORMANCE = ROOT / "build" / "performance"
APP = ROOT / "build" / "AssetTimeMachine-Mac-Perf.app" / "Contents" / "MacOS" / "AssetTimeMachine"


def physical_footprint(pid: int) -> tuple[float, float]:
    result = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True, check=True)
    current = re.search(r"^Physical footprint:\s+([\d.]+)M", result.stdout, re.MULTILINE)
    peak = re.search(r"^Physical footprint \(peak\):\s+([\d.]+)M", result.stdout, re.MULTILINE)
    if not current or not peak:
        raise RuntimeError(f"Could not read vmmap physical footprint for PID {pid}")
    return float(current.group(1)), float(peak.group(1))


def run(years: int, round_number: int, browse: bool) -> dict:
    store = PERFORMANCE / f"fixture-{years}y.store"
    if not store.is_file():
        raise FileNotFoundError(f"Missing isolated test store: {store}")
    suffix = "browse" if browse else "steady"
    output = PERFORMANCE / f"interaction-{years}y-{suffix}-{round_number}.json"
    capture = PERFORMANCE / f"capture-{years}y-{suffix}-{round_number}.png"
    log_path = PERFORMANCE / f"run-{years}y-{suffix}-{round_number}.log"
    output.unlink(missing_ok=True)
    capture.unlink(missing_ok=True)
    command = [
        str(APP), "-macPreview", "-macPerfSkipAccountEntry", "-macPerfStorePath", str(store),
        "-openTimeMachineTab", "-timeMachineRange", "all",
        "-macCapturePath", str(capture), "-macCaptureDelaySeconds", "12",
    ]
    if browse:
        command.append("-profileTabSwitchLoop")
    else:
        command.extend(["-macPerfInteractionOutput", str(output)])
    with log_path.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            ready_file = capture if browse else output
            while not ready_file.is_file():
                if process.poll() is not None:
                    raise RuntimeError(f"App exited early; see {log_path}")
                if time.monotonic() > deadline:
                    raise TimeoutError(f"Preview did not finish; see {log_path}")
                time.sleep(0.2)
            interactions = {} if browse else json.loads(output.read_text())
            time.sleep(30)
            current, peak = physical_footprint(process.pid)
            return {
                "years": years, "round": round_number, "browse": browse,
                "physicalFootprintMB": current, "peakMB": peak,
                "interactions": interactions, "capture": str(capture), "log": str(log_path),
            }
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--years", nargs="+", type=int, default=[1, 5, 10])
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--browse", action="store_true")
    args = parser.parse_args()
    if not APP.is_file():
        raise FileNotFoundError(APP)
    results = []
    for years in args.years:
        for round_number in range(1, args.rounds + 1):
            result = run(years, round_number, args.browse)
            results.append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    name = "browse-results.json" if args.browse else "steady-results.json"
    (PERFORMANCE / name).write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
