#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("run_intraday_downside_breadth_formal.py")
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("idb_runner", SCRIPT)
assert spec and spec.loader
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RemoteTagReservationTests(unittest.TestCase):
    def test_first_writer_wins_and_payload_is_read_back(self):
        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw)
            remote = base / "remote.git"
            work = base / "work"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            subprocess.run(["git", "init", "-q", "-b", "main", str(work)], check=True)
            for key, value in [("user.email", "test@example.invalid"), ("user.name", "test")]:
                subprocess.run(["git", "config", key, value], cwd=work, check=True)
            (work / "seed").write_text("seed\n", encoding="utf-8")
            subprocess.run(["git", "add", "seed"], cwd=work, check=True)
            subprocess.run(["git", "commit", "-qm", "seed"], cwd=work, check=True)
            subprocess.run(["git", "remote", "add", "origin", str(remote)], cwd=work, check=True)
            subprocess.run(["git", "push", "-q", "-u", "origin", "main"], cwd=work, check=True)
            commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=work, text=True, stdout=subprocess.PIPE, check=True).stdout.strip()
            names = ("ROOT", "AUTHORITY_REMOTE", "AUTHORITY_TAG", "AUTHORITY_REF")
            old = tuple(getattr(runner, name) for name in names)
            for name, value in zip(names, (work, "origin", "atm-run-budget/SYNTH", "refs/tags/atm-run-budget/SYNTH")):
                setattr(runner, name, value)
            try:
                record = {"sequence": 1, "event": "RUN_STARTED", "payload": {"authority_base_commit": commit}, "record_hash": "a" * 64}
                runner.verify_remote_reservation(record, push=True)
                self.assertEqual(json.loads(runner.git("for-each-ref", "--format=%(contents)", runner.AUTHORITY_REF)), record)
                other = {**record, "record_hash": "b" * 64}
                with self.assertRaises(SystemExit):
                    runner.verify_remote_reservation(other, push=True)
            finally:
                for name, value in zip(names, old):
                    setattr(runner, name, value)


if __name__ == "__main__":
    unittest.main()
