import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("research_agent_worker.py")
SPEC = importlib.util.spec_from_file_location("research_agent_worker", SCRIPT)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(worker)


class ResearchAgentWorkerTests(unittest.TestCase):
    def test_safe_repo_path_rejects_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(worker.WorkerError):
                worker.safe_repo_path(root, "../secret")
            with self.assertRaises(worker.WorkerError):
                worker.safe_repo_path(root, "/tmp/secret")

    def test_formal_command_is_an_argument_vector_without_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts" / "run_candidate.py").write_text("print('ok')\n", encoding="utf-8")
            command = worker.build_formal_command(root, {
                "trial_id": "ATM-SVP2-TEST-001",
                "entrypoint": "scripts/run_candidate.py",
                "arguments": ["--mode", "formal value"],
            })
        self.assertNotIn("sh", command[:1])
        self.assertIn("scripts/strategy_validation_formal_run.py", command)
        self.assertIn("--output-dir", command)
        self.assertIn(
            "tools/research-results/strategy-validation/runs/ATM-SVP2-TEST-001/candidates",
            command,
        )
        self.assertEqual(command[-2:], ["--mode", "formal value"])
        self.assertEqual(command[-1], "formal value")

    def test_sha256_file_is_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            path.write_bytes(b"{}\n")
            self.assertEqual(worker.sha256_file(path), "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356")


if __name__ == "__main__":
    unittest.main()
