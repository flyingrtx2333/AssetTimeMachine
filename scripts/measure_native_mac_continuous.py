#!/usr/bin/env python3
"""Measure three 10-year page tours in one isolated native Mac process."""
import argparse
import json
import time
from pathlib import Path
from measure_native_mac_performance import APP, PERF, launch_fixture, wait_for_marker, footprint


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=APP.parents[2])
    parser.add_argument("--fixtures", type=Path, default=PERF)
    parser.add_argument("--output", type=Path, default=PERF)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    prefix = output / "native-continuous-round"
    for round_number in range(1, 4):
        Path(f"{prefix}-{round_number}.done").unlink(missing_ok=True)
    complete = output / "native-continuous-complete.done"
    complete.unlink(missing_ok=True)
    arguments = ["-macPerfAutoBrowse", "-macPerfContinuousRounds", "3",
                 "-macPerfRoundMarkerPrefix", str(prefix),
                 "-macPerfCompletePath", str(complete)]
    results = []
    with launch_fixture(args.app, args.fixtures / "fixture-10y.store", arguments,
                        output / "native-continuous.log") as pid:
        for round_number in range(1, 4):
            wait_for_marker(pid, Path(f"{prefix}-{round_number}.done"), 180)
            time.sleep(30)
            current, peak = footprint(pid)
            result = {"round": round_number, "physicalFootprintMB": current, "peakMB": peak}
            results.append(result)
            (output / "native-continuous-results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
