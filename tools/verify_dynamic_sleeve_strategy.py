#!/usr/bin/env python3
"""Verify the dynamic sleeve Sharpe-1.4 candidate from spike 047."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SPIKE = ROOT / "spikes" / "047-dynamic-sleeve-selector"
VERIFY_PATH = SPIKE / "verify_best_target_selector.py"


def main() -> None:
    sys.path.insert(0, str(SPIKE))
    spec = importlib.util.spec_from_file_location("verify_best_target_selector", VERIFY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {VERIFY_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["verify_best_target_selector"] = module
    spec.loader.exec_module(module)
    module.main()


if __name__ == "__main__":
    main()
