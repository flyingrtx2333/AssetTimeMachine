#!/usr/bin/env python3
"""Conservative local-repository exposure scan for ATM-SVP-2 pristine holdout candidates.

This scanner cannot prove that a series was never viewed outside Git. It establishes a reproducible
lower-bound check: a proposed alternate symbol must not already appear in tracked strategy/research
code, durable research results, or historical commits in the configured research scopes.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_SCOPES = [
    "AssetTimeMachine/Backtest",
    "docs/strategies",
    "scripts",
    "tools",
]


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def exposure_pattern(series_id: str) -> str:
    # POSIX-ERE-compatible token boundary. This avoids false positives for numeric index IDs such
    # as 000016 appearing as a substring of a longer decimal/identifier while still matching IDs
    # containing punctuation such as ^RUA or Au99.99.
    escaped = re.escape(series_id)
    return rf"(^|[^[:alnum:]_]){escaped}([^[:alnum:]_]|$)"


def current_matches(series_id: str, scopes: list[str], excludes: set[str]) -> list[str]:
    pattern = exposure_pattern(series_id)
    result = git("grep", "-I", "-i", "-E", "-l", "-e", pattern, "HEAD", "--", *scopes, check=False)
    if result.returncode not in {0, 1}:
        raise SystemExit(f"git grep failed for {series_id}: {result.stderr.strip()}")
    matches: list[str] = []
    for line in result.stdout.splitlines():
        raw = line.strip()
        if not raw:
            continue
        path = raw.split(":", 1)[1] if raw.startswith("HEAD:") else raw
        if path not in excludes:
            matches.append(path)
    return sorted(set(matches))


def historical_matches(series_id: str, scopes: list[str], max_commits: int) -> list[str]:
    pattern = exposure_pattern(series_id)
    result = git(
        "log",
        "--all",
        "-i",
        f"-G{pattern}",
        "--format=%H",
        "--",
        *scopes,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"git log -G failed for {series_id}: {result.stderr.strip()}")
    commits: list[str] = []
    for line in result.stdout.splitlines():
        sha = line.strip()
        if sha and sha not in commits:
            commits.append(sha)
        if len(commits) >= max_commits:
            break
    return commits


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", action="append", required=True, help="role=source:source_series_id")
    parser.add_argument("--scope", action="append", dest="scopes")
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-history-commits", type=int, default=20)
    args = parser.parse_args()

    scopes = args.scopes or DEFAULT_SCOPES
    excludes = set(args.exclude)
    rows = []
    seen_roles: set[str] = set()
    seen_series_ids: set[str] = set()
    for raw in args.candidate:
        if "=" not in raw or ":" not in raw.split("=", 1)[1]:
            raise SystemExit(f"Invalid --candidate {raw!r}; expected role=source:source_series_id")
        role, source_series = raw.split("=", 1)
        source, series_id = source_series.split(":", 1)
        role, source, series_id = role.strip(), source.strip(), series_id.strip()
        if not role or not source or not series_id:
            raise SystemExit(f"Invalid --candidate {raw!r}; values must be non-empty")
        if role in seen_roles:
            raise SystemExit(f"Duplicate role: {role}")
        if series_id.casefold() in seen_series_ids:
            raise SystemExit(f"Duplicate source series id: {series_id}")
        seen_roles.add(role)
        seen_series_ids.add(series_id.casefold())
        current = current_matches(series_id, scopes, excludes)
        history = historical_matches(series_id, scopes, args.max_history_commits)
        rows.append({
            "role": role,
            "source": source,
            "source_series_id": series_id,
            "current_tracked_matches": current,
            "historical_match_commits": history,
            "locally_unexposed": not current and not history,
        })

    output = {
        "protocol_id": "ATM-SVP-2",
        "scan_type": "LOCAL_GIT_EXPOSURE_LOWER_BOUND",
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "git_head": git("rev-parse", "HEAD").stdout.strip(),
        "scopes": scopes,
        "excludes": sorted(excludes),
        "candidates": rows,
        "all_locally_unexposed": all(row["locally_unexposed"] for row in rows),
        "limitation": "No local Git match does not prove global/prior human non-exposure. It is a conservative reproducible lower-bound check only.",
    }
    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"EXPOSURE_SCAN_WRITTEN output={path} all_locally_unexposed={output['all_locally_unexposed']}")
    if not output["all_locally_unexposed"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
