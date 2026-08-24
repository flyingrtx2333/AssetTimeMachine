import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("research_preparation_worker.py")
SPEC = importlib.util.spec_from_file_location("research_preparation_worker", SCRIPT)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(worker)


class ResearchPreparationWorkerTests(unittest.TestCase):
    def test_codex_command_uses_workspace_write_and_structured_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = worker.build_codex_command(
                "/usr/local/bin/codex",
                root,
                "gpt-5.6-sol",
                "high",
                root / "schema.json",
                root / "output.json",
            )
        self.assertEqual(command[1], "exec")
        self.assertIn("--ephemeral", command)
        self.assertEqual(command[command.index("--sandbox") + 1], "workspace-write")
        self.assertIn("--output-schema", command)
        self.assertNotIn("danger-full-access", command)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", command)
        self.assertEqual(command[-1], "-")

    def test_prompt_forbids_formal_results_and_preserves_frozen_contract(self):
        prompt = worker.build_prompt({
            "schema_version": "research-preparation-v1",
            "study_key": "ATM-RA-TEST",
            "plan": {"candidates": [{"candidate_id": "MECH-TEST"}]},
        })
        self.assertIn("Do not run a formal backtest", prompt)
        self.assertIn("Do not append RESULT", prompt)
        self.assertIn("MECH-TEST", prompt)
        self.assertIn("Leave the worktree clean", prompt)

    def test_codex_environment_does_not_inherit_business_secrets(self):
        environment = worker.sanitized_codex_environment({
            "PATH": "/usr/bin",
            "FLYINGRTX_RESEARCH_PREPARATION_TOKEN": "secret",
            "FRK_TOKEN": "secret",
            "VENDOR_API_KEY": "secret",
            "DATABASE_PASSWORD": "secret",
        })
        self.assertEqual(environment, {"PATH": "/usr/bin"})

    def test_safe_paths_reject_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(worker.WorkerError):
                worker.safe_repo_path(root, "../outside.json")
            with self.assertRaises(worker.WorkerError):
                worker.safe_repo_path(root, "/tmp/outside.json")

    def test_preregistered_candidates_must_be_unique_for_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = root / "tools/research-results/strategy-validation/trial-ledger.jsonl"
            ledger.parent.mkdir(parents=True)
            ledger.write_text(
                '{"event":"PREREGISTER","payload":{"trial_id":"ATM-SVP2-TEST","candidate_ids":["A","B"]}}\n',
                encoding="utf-8",
            )
            self.assertEqual(
                worker.preregistered_candidate_ids(root, "ATM-SVP2-TEST"),
                {"A", "B"},
            )


if __name__ == "__main__":
    unittest.main()
