#!/usr/bin/env python3
"""Create SHA-256 manifests for ATM-SVP-1 datasets and result artifacts."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def git_head() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"git rev-parse HEAD failed: {result.stderr.strip()}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def csv_metadata(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        fieldnames = reader.fieldnames or []
        row_count = 0
        first_date: str | None = None
        last_date: str | None = None
        date_column = next((name for name in ["date", "signal_date", "timestamp"] if name in fieldnames), None)
        for row in reader:
            row_count += 1
            if date_column:
                value = row.get(date_column)
                if value:
                    first_date = first_date or value
                    last_date = value
    return {
        "format": "csv",
        "columns": fieldnames,
        "row_count": row_count,
        "date_column": date_column,
        "first_date": first_date,
        "last_date": last_date,
    }


def file_record(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"Manifest input is not a file: {path}")
    record: dict[str, Any] = {
        "path": path.as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }
    if path.suffix.lower() == ".csv":
        try:
            record.update(csv_metadata(path))
        except UnicodeDecodeError:
            record["format"] = "binary"
    elif path.suffix.lower() == ".json":
        record["format"] = "json"
    elif path.suffix.lower() == ".jsonl":
        record["format"] = "jsonl"
    else:
        record["format"] = path.suffix.lower().lstrip(".") or "binary"
    return record


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trial-id", required=True)
    parser.add_argument("--kind", choices=["dataset", "run", "result"], required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--file", action="append", dest="files", required=True)
    parser.add_argument("--metadata-json")
    args = parser.parse_args()

    paths = [Path(raw) for raw in args.files]
    normalized = [path.as_posix() for path in paths]
    if len(normalized) != len(set(normalized)):
        raise SystemExit("Duplicate --file path in manifest input")

    metadata: dict[str, Any] = {}
    if args.metadata_json:
        parsed = json.loads(args.metadata_json)
        if not isinstance(parsed, dict):
            raise SystemExit("--metadata-json must be a JSON object")
        metadata = parsed

    records = [file_record(path) for path in sorted(paths, key=lambda value: value.as_posix())]
    manifest = {
        "protocol_id": "ATM-SVP-1",
        "trial_id": args.trial_id,
        "kind": args.kind,
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "git_commit": git_head(),
        "metadata": metadata,
        "files": records,
    }
    output = Path(args.output)
    if output in paths:
        raise SystemExit("Manifest output cannot also be one of the hashed input files")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"ARTIFACT_MANIFEST_WRITTEN kind={args.kind} trial_id={args.trial_id} "
        f"files={len(records)} output={output} sha256={sha256(output)}"
    )


if __name__ == "__main__":
    main()
