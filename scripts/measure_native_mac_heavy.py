#!/usr/bin/env python3
"""Measure memory recovery after native video export and isolated JSON import."""
import argparse
import json
import sqlite3
import time
from pathlib import Path
from measure_native_mac_performance import APP, PERF, launch_fixture, wait_for_marker, footprint


def measure(app: Path, store: Path, output: Path, name: str,
            arguments: list[str], marker: Path) -> dict:
    marker.unlink(missing_ok=True)
    log_path = output / f"native-heavy-{name}.log"
    with launch_fixture(app, store, arguments, log_path) as pid:
        wait_for_marker(pid, marker, 300)
        time.sleep(60)
        current, peak = footprint(pid)
        return {"operation": name, "physicalFootprintAfter60sMB": current,
                "peakMB": peak, "log": str(log_path)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=APP.parents[2])
    parser.add_argument("--fixtures", type=Path, default=PERF)
    parser.add_argument("--output", type=Path, default=PERF)
    args = parser.parse_args()
    output, fixtures = args.output.resolve(), args.fixtures.resolve()
    output.mkdir(parents=True, exist_ok=True)
    video = output / "native-video-final.mp4"
    result = measure(args.app, fixtures / "fixture-10y.store", output, "video",
                     ["-macPerfVideoOutput", str(video)], video)
    result.update(years=10, outputBytes=video.stat().st_size)
    results = [result]
    report = output / "native-heavy-results.json"
    report.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")

    # SQLite backup includes pending WAL pages and only copies the synthetic fixture.
    disposable = output / "native-heavy-import-fixture.store"
    for suffix in ("", "-wal", "-shm"):
        Path(str(disposable) + suffix).unlink(missing_ok=True)
    with sqlite3.connect(f"file:{fixtures / 'fixture-1y.store'}?mode=ro", uri=True) as source:
        with sqlite3.connect(disposable) as destination:
            source.backup(destination)
    marker = output / "native-heavy-import-result.json"
    result = measure(args.app, disposable, output, "edit-delete-import", [
        "-macPerfMutationOutput", str(marker),
        "-macPerfImportJSON", str(fixtures / "fixture-1y.json"),
    ], marker)
    result.update(years=1, mutations=json.loads(marker.read_text()))
    results.append(result)
    report.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(results, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
