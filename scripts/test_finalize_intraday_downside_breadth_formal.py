#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]


def module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


finalizer = module(PROJECT / "scripts/finalize_intraday_downside_breadth_formal.py", "idb_finalizer")
ledger = module(PROJECT / "scripts/strategy_validation_ledger.py", "idb_ledger")
publisher = module(PROJECT / "scripts/publish_strategy_library_manifest.py", "idb_publisher")
protocol = module(PROJECT / "scripts/validate_strategy_protocol.py", "idb_protocol")


class FinalizerTests(unittest.TestCase):
    def configure(self, root: Path, return_code: int, metrics: bool, decision: str = "PASS") -> None:
        base = root / "tools/research-results/strategy-validation"
        run_dir = base / "runs" / finalizer.TRIAL_ID
        run_dir.mkdir(parents=True)
        source = root / "AssetTimeMachine/Backtest/IntradayDownsideBreadthStrategy.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// synthetic\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "test"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "synthetic source"], cwd=root, check=True)
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True, stdout=subprocess.PIPE, check=True
        ).stdout.strip()
        prereg = {
            "trial_id": finalizer.TRIAL_ID, "protocol_id": "ATM-SVP-2",
            "strategy_lineage": "intraday-downside-breadth-63-21-v1",
            "hypothesis": "synthetic finalizer test", "evidence_class": "R1_RETROSPECTIVE",
            "dataset_manifest": f"tools/research-results/strategy-validation/datasets/{finalizer.TRIAL_ID}.json",
            "allowed_changes": [], "candidate_ids": [finalizer.CANDIDATE_ID], "candidate_count": 1,
            "selection_metric": "all frozen gates", "pass_fail_gates": ["synthetic"],
            "formal_run_budget": 1, "follow_up_policy": "no retry",
            "requires_durable_run_reservation": True, "implementation_commit": commit,
            "result_manifest_kind": "result",
            "run_budget_authority": {"kind": "git-remote-immutable-tag-cas", "remote": "origin", "base_branch": "main", "ref": "refs/tags/atm-run-budget/ATM-SVP2-IDB-63-21-001"},
            "swift_engine_entrypoint": "synthetic", "expected_outputs": ["RESULT"],
            "frozen_schedule": {"fingerprints": {"full": "b" * 64}},
        }
        prereg_path = base / "preregistrations" / f"{finalizer.TRIAL_ID}.json"
        prereg_path.parent.mkdir(parents=True)
        prereg_path.write_text(json.dumps(prereg), encoding="utf-8")
        dataset = base / "datasets" / f"{finalizer.TRIAL_ID}.json"
        dataset.parent.mkdir(parents=True)
        fixture = root / "fixtures/synthetic.json"
        fixture.parent.mkdir(parents=True)
        fixture.write_bytes(b"{}\n")
        dataset.write_text(json.dumps({
            "protocol_id": "ATM-SVP-2", "trial_id": finalizer.TRIAL_ID, "kind": "dataset",
            "files": [{"path": "fixtures/synthetic.json", "sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(), "bytes": fixture.stat().st_size}],
        }), encoding="utf-8")
        ledger_path = base / "trial-ledger.jsonl"
        prereg_record = ledger.append_record(ledger_path, "PREREGISTER", prereg, "2026-01-01T00:00:00+00:00")
        started = ledger.append_record(ledger_path, "RUN_STARTED", {
            "trial_id": finalizer.TRIAL_ID, "protocol_id": "ATM-SVP-2",
            "preregistration_record_hash": prereg_record["record_hash"],
            "implementation_commit": commit, "formal_run_budget": 1,
            "output_directory": str(run_dir.relative_to(root)),
            "nonce_sha256": "c" * 64, "permanent": True,
            "authority_remote": "origin", "authority_ref": "refs/tags/atm-run-budget/ATM-SVP2-IDB-63-21-001",
            "authority_base_commit": commit,
        }, "2026-01-01T00:00:30+00:00")
        receipt = {
            "trial_id": finalizer.TRIAL_ID, "protocol_id": "ATM-SVP-2",
            "preregistration_record_hash": prereg_record["record_hash"],
            "run_budget_record_hash": started["record_hash"],
            "execution_git_commit": commit,
            "formal_run_budget": 1, "candidate_count": 1,
        }
        execution = {
            "trial_id": finalizer.TRIAL_ID, "protocol_id": "ATM-SVP-2",
            "preregistration_record_hash": prereg_record["record_hash"],
            "run_budget_record_hash": started["record_hash"],
            "execution_git_commit": commit,
            "run_guard_receipt": str((run_dir / "run-authorization.json").relative_to(root)),
            "started_at": "2026-01-01T00:01:00+00:00", "finished_at": "2026-01-01T00:02:00+00:00",
            "return_code": return_code,
        }
        for name, content in {
            "execution.json": json.dumps(execution), "run-authorization.json": json.dumps(receipt),
            "run-budget-reservation.json": json.dumps(started),
            "stdout.txt": "", "stderr.txt": "", "run-slot.json": "{}\n",
            "launch-marker.json": "{}\n",
        }.items():
            (run_dir / name).write_text(content, encoding="utf-8")
        if metrics:
            window_ids = ["full", "since_2016_08_31", "since_2020_01_01", "since_2022_01_01"]
            candidate = {key: {"cagr": 0.10, "sharpe": 0.90, "mdd": 0.08} for key in window_ids}
            if decision == "FAIL":
                candidate = {key: {"cagr": 0.05, "sharpe": 0.50, "mdd": 0.15} for key in window_ids}
            natural = {key: {"cagr": 0.08, "sharpe": 0.70, "mdd": 0.12} for key in window_ids}
            placebo = {key: {"cagr": 0.08, "sharpe": 0.60, "mdd": 0.10} for key in window_ids}
            factor_windows = {key: {
                "risk_count": 5, "calm_count": 5, "risk_median": -0.01, "calm_median": 0.01,
                "sufficient": True, "direction": True,
            } for key in window_ids}
            value = {
                "trial_id": finalizer.TRIAL_ID, "candidate_id": finalizer.CANDIDATE_ID,
                "decision": decision,
                "candidate": candidate if decision != "INVALID" else {},
                "natural": natural if decision != "INVALID" else {},
                "placebo": placebo if decision != "INVALID" else {},
                "factor_mechanism": {"sufficient": decision != "INVALID", "direction": decision != "INVALID", "windows": factor_windows},
                "checks": {key: decision == "PASS" for key in window_ids},
                "schedule_fingerprints": {"full": "b" * 64},
            }
            (run_dir / "candidate-metrics.json").write_text(json.dumps(value), encoding="utf-8")
            (run_dir / "queue-trace.json").write_text("{}\n", encoding="utf-8")
        for name, value in {
            "ROOT": root, "BASE": base, "RUN_DIR": run_dir,
            "RESULT_PATH": base / "results" / f"{finalizer.TRIAL_ID}.json",
            "DATASET_PATH": dataset, "PREREG_PATH": prereg_path, "LEDGER_PATH": ledger_path,
            "ARTIFACT_PATH": run_dir / "artifact-manifest.json",
            "LIBRARY_PATH": run_dir / "strategy-library-import-v2.json",
        }.items():
            setattr(finalizer, name, value)

    def run_case(self, return_code: int, metrics: bool, decision: str = "PASS") -> dict:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.configure(root, return_code, metrics, decision)
            with patch.object(
                sys, "argv", ["finalizer", "--output-dir", str(finalizer.RUN_DIR)]
            ):
                self.assertEqual(finalizer.main(), 0)
            ledger.verify_records(ledger.read_records(finalizer.LEDGER_PATH))
            publisher.validate_local_manifest(json.loads(finalizer.LIBRARY_PATH.read_text(encoding="utf-8")))
            previous = Path.cwd()
            try:
                os.chdir(root)
                manifest = protocol.verify_artifact_manifest(
                    Path(finalizer.ARTIFACT_PATH.relative_to(root)), finalizer.TRIAL_ID, "result", "ATM-SVP-2"
                )
                covered = {entry["path"] for entry in manifest["files"]}
                self.assertTrue(set(json.loads(finalizer.RESULT_PATH.read_text())["artifacts"]).issubset(covered))
            finally:
                os.chdir(previous)
            return json.loads(finalizer.RESULT_PATH.read_text(encoding="utf-8"))

    def test_success_writes_complete_result(self):
        result = self.run_case(0, True)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(len(result["candidate_results"]), 1)

    def test_false_pass_with_control_ties_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            self.configure(Path(raw), 0, True, "PASS")
            metrics_path = finalizer.RUN_DIR / "candidate-metrics.json"
            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
            metrics["natural"] = metrics["candidate"]
            metrics["placebo"] = metrics["candidate"]
            metrics_path.write_text(json.dumps(metrics), encoding="utf-8")
            with patch.object(sys, "argv", ["finalizer", "--output-dir", str(finalizer.RUN_DIR)]):
                self.assertEqual(finalizer.main(), 0)
            result = json.loads(finalizer.RESULT_PATH.read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "INVALID")
            self.assertEqual(result["candidate_results"], [])

    def test_failure_writes_invalid_without_fake_metrics(self):
        result = self.run_case(1, False)
        self.assertEqual(result["status"], "INVALID")
        self.assertEqual(result["candidate_results"], [])

    def test_factor_insufficient_writes_invalid_without_portfolio_metrics(self):
        result = self.run_case(0, True, "INVALID")
        self.assertEqual(result["status"], "INVALID")
        self.assertEqual(result["candidate_results"], [])

    def test_ledger_append_failure_can_resume_identical_finalization(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.configure(root, 0, True)
            argv = ["finalizer", "--output-dir", str(finalizer.RUN_DIR)]
            real_run = subprocess.run

            def fail_only_real_append(command, **kwargs):
                if str(finalizer.LEDGER_SCRIPT) in command and "append" in command:
                    raise subprocess.CalledProcessError(1, command)
                return real_run(command, **kwargs)

            with patch.object(finalizer.subprocess, "run", side_effect=fail_only_real_append), patch.object(sys, "argv", argv):
                with self.assertRaises(subprocess.CalledProcessError):
                    finalizer.main()
            with patch.object(sys, "argv", argv):
                self.assertEqual(finalizer.main(), 0)
                self.assertEqual(finalizer.main(), 0)
            finalizer.LIBRARY_PATH.write_text('{"tampered":true}\n', encoding="utf-8")
            with patch.object(sys, "argv", argv):
                with self.assertRaises(SystemExit):
                    finalizer.main()
            ledger.verify_records(ledger.read_records(finalizer.LEDGER_PATH))


if __name__ == "__main__":
    unittest.main()
