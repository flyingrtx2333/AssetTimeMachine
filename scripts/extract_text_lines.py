#!/usr/bin/env python3
"""Extract an inclusive line range from a large UTF-8 text file."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("start", type=int)
    parser.add_argument("end", type=int)
    args = parser.parse_args()

    if args.start < 1 or args.end < args.start:
        raise SystemExit("invalid line range")

    lines = Path(args.source).read_text(encoding="utf-8").splitlines()
    selected = lines[args.start - 1 : args.end]
    rendered = "\n".join(
        f"{line_number:6d} | {line}"
        for line_number, line in enumerate(selected, start=args.start)
    ) + "\n"
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    print(f"extracted={len(selected)} output={output}")


if __name__ == "__main__":
    main()
