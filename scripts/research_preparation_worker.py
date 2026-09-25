#!/usr/bin/env python3
"""Prepare frozen Research Agent studies with Codex in isolated Git worktrees.

This worker may edit and test research code, but it must not execute a formal
backtest. A successful preparation is accepted only when Codex leaves a clean,
new commit containing an ATM-SVP preregistration with no RESULT record.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Optional

from research_asset_policy import validate_research_policy_snapshot


API_PATH = "/api/v1/asset-time-machine/internal/research-agent/preparation/jobs"
DEFAULT_BASE_URL = "https://api.flyingrtx.com"
HEARTBEAT_SECONDS = 30
MAX_ERROR_TEXT = 6000


class WorkerError(RuntimeError):
    pass


class ApiError(WorkerError):
    def __init__(self, status: int, message: str):
        super().__init__(f"Research preparation API {status}: {message}")
        self.status = status


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_repo_path(root: Path, relative: str) -> Path:
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != relative:
        raise WorkerError(f"Unsafe repository path: {relative}")
    root = root.resolve()
    resolved = (root / Path(*pure.parts)).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise WorkerError(f"Path escapes worktree: {relative}") from exc
    return resolved


def run_git(repo: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    process = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and process.returncode != 0:
        raise WorkerError(f"git {' '.join(arguments)} failed: {process.stderr.strip()}")
    return process


def read_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise WorkerError(f"Cannot read JSON artifact: {path}") from exc
    if not isinstance(value, dict):
        raise WorkerError(f"JSON artifact is not an object: {path}")
    return value


def sanitized_study_key(value: str) -> str:
    safe = "".join(character.lower() if character.isalnum() else "-" for character in value)
    return "-".join(part for part in safe.split("-") if part)[:80] or "study"


def preparation_output_schema() -> Dict[str, Any]:
    path_schema = {"type": "string", "minLength": 1, "maxLength": 768}
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "required": [
            "trial_id", "entrypoint", "arguments", "dataset_manifest_path",
            "result_path", "strategy_manifest_path", "tests_run", "summary",
        ],
        "properties": {
            "trial_id": {"type": "string", "pattern": "^[A-Z0-9][A-Z0-9_.-]*$"},
            "entrypoint": path_schema,
            "arguments": {"type": "array", "maxItems": 32, "items": {"type": "string", "maxLength": 512}},
            "dataset_manifest_path": path_schema,
            "result_path": path_schema,
            "strategy_manifest_path": path_schema,
            "tests_run": {"type": "array", "maxItems": 40, "items": {"type": "string", "maxLength": 500}},
            "summary": {"type": "string", "minLength": 1, "maxLength": 4000},
        },
    }


def build_codex_command(
    codex_binary: str,
    worktree: Path,
    model: str,
    reasoning_effort: str,
    schema_path: Path,
    output_path: Path,
) -> list[str]:
    if reasoning_effort not in {"low", "medium", "high", "xhigh", "max", "ultra"}:
        raise WorkerError(f"Unsupported Codex reasoning effort: {reasoning_effort}")
    return [
        codex_binary,
        "exec",
        "--ephemeral",
        "--sandbox",
        "workspace-write",
        "--model",
        model,
        "-c",
        f'model_reasoning_effort="{reasoning_effort}"',
        "--output-schema",
        str(schema_path),
        "--output-last-message",
        str(output_path),
        "-C",
        str(worktree),
        "-",
    ]


def sanitized_codex_environment(source: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    environment = dict(source if source is not None else os.environ)
    sensitive_suffixes = ("_TOKEN", "_API_KEY", "_SECRET", "_PASSWORD", "_PRIVATE_KEY")
    for key in list(environment):
        upper = key.upper()
        if upper == "FRK_TOKEN" or upper.startswith("FLYINGRTX_") or upper.endswith(sensitive_suffixes):
            environment.pop(key, None)
    return environment


def build_prompt(contract: Dict[str, Any]) -> str:
    frozen = json.dumps(contract, ensure_ascii=False, indent=2, sort_keys=True)
    return f"""You are the code-preparation stage of the AssetTimeMachine quantitative Research Agent.

Read and obey AGENTS.md before editing. Work only on the frozen study contract below.

NON-NEGOTIABLE SAFETY BOUNDARY:
- Do not run a formal backtest, formal experiment, strategy_validation_formal_run.py, or any command that creates/reads a RESULT for this trial.
- Do not inspect the performance result of this new trial. This stage ends before formal execution.
- Do not change the frozen plan, candidate IDs, trial budget, hard constraints, or pass/fail gates.
- Never introduce digital assets/cryptocurrencies, leveraged or inverse products, leverage, financing, shorting, negative cash, or gross exposure above 100%.
- Do not use network data to evaluate candidate performance.

Required deliverables:
1. Implement every frozen candidate mechanism using the repository's Swift/App backtest engine where appropriate. Add focused mechanism and causality tests.
2. Create one executable Python entrypoint under scripts/. It must later run all frozen candidates through the approved Swift engine and emit both the declared result JSON and strategy-library-v2 manifest, including every candidate whether it passes or fails.
3. Create a pinned dataset artifact manifest under tools/research-results/. It must describe the frozen dataset inputs without opening the formal result.
4. Create a complete ATM-SVP-2 preregistration and append exactly one PREREGISTER event with scripts/strategy_validation_ledger.py. Do not append RESULT.
5. Run only non-formal unit, compile, protocol, and static validation checks. Fix failures.
6. Commit every preparation input and code change with a short imperative commit message. Leave the worktree clean.
7. Return only the structured output requested by the supplied JSON schema. Paths must be repository-relative. `tests_run` must list commands actually run.

The worker will independently reject the result if HEAD did not change, the worktree is dirty, the preregistration is missing/uncommitted, a RESULT exists, paths escape the repository, or required files are absent.

FROZEN PREPARATION CONTRACT:
{frozen}
"""


def preregistered_candidate_ids(worktree: Path, trial_id: str) -> set[str]:
    ledger = safe_repo_path(
        worktree,
        "tools/research-results/strategy-validation/trial-ledger.jsonl",
    )
    if not ledger.is_file():
        raise WorkerError("Strategy-validation ledger is missing")
    matches: list[set[str]] = []
    for raw in ledger.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise WorkerError("Strategy-validation ledger contains invalid JSON") from exc
        payload = record.get("payload") if isinstance(record, dict) else None
        if record.get("event") == "PREREGISTER" and isinstance(payload, dict) and payload.get("trial_id") == trial_id:
            values = payload.get("candidate_ids")
            if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
                raise WorkerError("Prepared preregistration has invalid candidate IDs")
            matches.append(set(values))
    if len(matches) != 1:
        raise WorkerError(f"Expected exactly one PREREGISTER for trial {trial_id}")
    return matches[0]


class ResearchPreparationApi:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def request(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        request = urllib.request.Request(
            f"{self.base_url}{API_PATH}{path}",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.token}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                raw = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            try:
                detail = json.loads(body).get("detail", body)
            except json.JSONDecodeError:
                detail = body
            raise ApiError(exc.code, str(detail)[:1000]) from exc
        except urllib.error.URLError as exc:
            raise WorkerError(f"Research preparation API unavailable: {exc.reason}") from exc
        value = json.loads(raw or "{}")
        if not isinstance(value, dict):
            raise WorkerError("Research preparation API returned a non-object response")
        return value


class ResearchPreparationWorker:
    def __init__(
        self,
        api: ResearchPreparationApi,
        repo: Path,
        state_dir: Path,
        worker_id: str,
        codex_binary: str,
        codex_version: Optional[str] = None,
    ):
        self.api = api
        self.repo = repo.resolve()
        self.state_dir = state_dir.resolve()
        self.worker_id = worker_id
        self.codex_binary = codex_binary
        self.codex_version = codex_version or self._read_codex_version()
        self.pending_dir = self.state_dir / "pending"
        self.worktrees_dir = self.state_dir / "worktrees"
        self.logs_dir = self.state_dir / "logs"
        self.contracts_dir = self.state_dir / "contracts"
        for directory in (self.pending_dir, self.worktrees_dir, self.logs_dir, self.contracts_dir):
            directory.mkdir(parents=True, exist_ok=True)

    def _read_codex_version(self) -> str:
        process = subprocess.run(
            [self.codex_binary, "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if process.returncode != 0:
            raise WorkerError(f"Codex CLI is unavailable: {process.stderr.strip()}")
        return process.stdout.strip()[:80]

    def _pending_path(self, study_key: str) -> Path:
        return self.pending_dir / f"{sanitized_study_key(study_key)}.json"

    def _write_pending(self, study_key: str, payload: Dict[str, Any]) -> Path:
        target = self._pending_path(study_key)
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(target)
        return target

    def flush_pending(self) -> bool:
        for path in sorted(self.pending_dir.glob("*.json")):
            envelope = read_json(path)
            study_key = str(envelope["study_key"])
            self.api.request(f"/{study_key}/complete", dict(envelope["payload"]))
            path.unlink()
            print(f"PREPARATION_ACKNOWLEDGED study_key={study_key}")
        return not any(self.pending_dir.glob("*.json"))

    def claim(self) -> Optional[Dict[str, Any]]:
        response = self.api.request("/claim", {
            "worker_id": self.worker_id,
            "codex_version": self.codex_version,
        })
        job = response.get("job")
        if job is None:
            return None
        if not isinstance(job, dict):
            raise WorkerError("Claim response contains an invalid preparation job")
        return job

    def heartbeat(self, job: Dict[str, Any], phase: str, **details: Any) -> Dict[str, Any]:
        return self.api.request(f"/{job['study_key']}/heartbeat", {
            "worker_id": self.worker_id,
            "lease_token": job["lease_token"],
            "progress": {"phase": phase, **details},
        })

    def prepare_worktree(self, job: Dict[str, Any]) -> tuple[Path, str]:
        base_commit = run_git(self.repo, "rev-parse", "HEAD").stdout.strip()
        run_git(self.repo, "cat-file", "-e", f"{base_commit}^{{commit}}")
        lease_fingerprint = hashlib.sha256(str(job["lease_token"]).encode("utf-8")).hexdigest()[:16]
        worktree = self.worktrees_dir / f"{sanitized_study_key(str(job['study_key']))}-{lease_fingerprint}"
        if worktree.exists():
            raise WorkerError(f"Preparation worktree already exists: {worktree}")
        run_git(self.repo, "worktree", "add", "--detach", str(worktree), base_commit)
        if run_git(worktree, "status", "--porcelain").stdout.strip():
            raise WorkerError("Preparation worktree is not clean")
        return worktree, base_commit

    def _run_codex(self, job: Dict[str, Any], worktree: Path) -> Dict[str, Any]:
        study_key = sanitized_study_key(str(job["study_key"]))
        schema_path = self.contracts_dir / f"{study_key}.schema.json"
        output_path = self.contracts_dir / f"{study_key}.output.json"
        schema_path.write_text(json.dumps(preparation_output_schema(), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(schema_path, 0o600)
        output_path.unlink(missing_ok=True)
        command = build_codex_command(
            self.codex_binary,
            worktree,
            str(job["model"]),
            str(job["reasoning_effort"]),
            schema_path,
            output_path,
        )
        prompt = build_prompt(dict(job["preparation_contract"]))
        stdout_path = self.logs_dir / f"{study_key}.stdout.txt"
        stderr_path = self.logs_dir / f"{study_key}.stderr.txt"
        started_at = time.monotonic()
        with stdout_path.open("w", encoding="utf-8") as stdout_handle, stderr_path.open("w", encoding="utf-8") as stderr_handle:
            process = subprocess.Popen(
                command,
                cwd=worktree,
                env=sanitized_codex_environment(),
                stdin=subprocess.PIPE,
                stdout=stdout_handle,
                stderr=stderr_handle,
                text=True,
            )
            assert process.stdin is not None
            process.stdin.write(prompt)
            process.stdin.close()
            next_heartbeat = time.monotonic() + HEARTBEAT_SECONDS
            try:
                while process.poll() is None:
                    time.sleep(2)
                    now = time.monotonic()
                    if now >= next_heartbeat:
                        heartbeat = self.heartbeat(
                            job,
                            "codex_preparation",
                            pid=process.pid,
                            elapsed_seconds=int(now - started_at),
                        )
                        if heartbeat.get("cancel_requested"):
                            raise WorkerError("Preparation was cancelled by the control plane")
                        next_heartbeat = now + HEARTBEAT_SECONDS
            except Exception:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                raise
            if process.returncode != 0:
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-MAX_ERROR_TEXT:]
                raise WorkerError(stderr_tail or f"Codex exited with code {process.returncode}")
        return read_json(output_path)

    def _verify_output(self, job: Dict[str, Any], worktree: Path, output: Dict[str, Any], base_commit: str) -> Dict[str, Any]:
        prepared_commit = run_git(worktree, "rev-parse", "HEAD").stdout.strip()
        if prepared_commit == base_commit:
            raise WorkerError("Codex did not create a preparation commit")
        if run_git(worktree, "status", "--porcelain").stdout.strip():
            raise WorkerError("Codex left uncommitted preparation changes")

        entrypoint_relative = str(output["entrypoint"])
        dataset_relative = str(output["dataset_manifest_path"])
        result_relative = str(output["result_path"])
        strategy_relative = str(output["strategy_manifest_path"])
        entrypoint = safe_repo_path(worktree, entrypoint_relative)
        dataset_manifest = safe_repo_path(worktree, dataset_relative)
        safe_repo_path(worktree, result_relative)
        safe_repo_path(worktree, strategy_relative)
        if not entrypoint_relative.startswith("scripts/") or not entrypoint_relative.endswith(".py") or not entrypoint.is_file():
            raise WorkerError("Prepared runner must be a committed file under scripts/")
        if not dataset_relative.startswith("tools/research-results/") or not dataset_relative.endswith(".json") or not dataset_manifest.is_file():
            raise WorkerError("Prepared dataset manifest must be a committed file under tools/research-results/")
        if (
            not result_relative.startswith("tools/research-results/")
            or not strategy_relative.startswith("tools/research-results/")
            or not result_relative.endswith(".json")
            or not strategy_relative.endswith(".json")
        ):
            raise WorkerError("Prepared output paths must be under tools/research-results/")
        arguments = [str(item) for item in output.get("arguments", [])]
        if len(arguments) > 32 or any(
            len(item) > 512 or "\x00" in item or "\n" in item or "\r" in item
            for item in arguments
        ):
            raise WorkerError("Prepared runner arguments violate the execution contract")

        trial_id = str(output["trial_id"])
        receipt_path = self.contracts_dir / f"{sanitized_study_key(str(job['study_key']))}.guard.json"
        guard = subprocess.run(
            [
                sys.executable,
                "scripts/strategy_validation_run_guard.py",
                "--trial-id",
                trial_id,
                "--receipt",
                str(receipt_path),
            ],
            cwd=worktree,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if guard.returncode != 0:
            raise WorkerError(f"Preregistration guard rejected preparation: {guard.stderr.strip() or guard.stdout.strip()}")
        receipt = read_json(receipt_path)
        if receipt.get("protocol_id") != "ATM-SVP-2":
            raise WorkerError("Prepared preregistration does not use ATM-SVP-2")
        if receipt.get("execution_git_commit") != prepared_commit:
            raise WorkerError("Guard receipt commit differs from prepared HEAD")

        plan = dict(job["preparation_contract"].get("plan") or {})
        expected_candidates = {
            str(item.get("candidate_id"))
            for item in plan.get("candidates", [])
            if isinstance(item, dict) and item.get("candidate_id")
        }
        if int(receipt.get("candidate_count") or 0) != len(expected_candidates):
            raise WorkerError("Preregistration candidate count differs from the frozen plan")
        if preregistered_candidate_ids(worktree, trial_id) != expected_candidates:
            raise WorkerError("Preregistration candidate IDs differ from the frozen plan")

        branch_name = f"codex/research-agent-{sanitized_study_key(str(job['study_key']))}-{prepared_commit[:8]}"
        run_git(self.repo, "check-ref-format", f"refs/heads/{branch_name}")
        run_git(self.repo, "branch", branch_name, prepared_commit)
        return {
            "worker_id": self.worker_id,
            "lease_token": job["lease_token"],
            "outcome": "prepared",
            "base_commit": base_commit,
            "prepared_commit": prepared_commit,
            "branch_name": branch_name,
            "evidence": {
                "preregistration_hash": str(receipt["preregistration_record_hash"]),
                "execution_commit": prepared_commit,
                "dataset_manifest_sha256": sha256_file(dataset_manifest),
                "code_sha256": sha256_file(entrypoint),
                "runner": {
                    "trial_id": trial_id,
                    "entrypoint": entrypoint_relative,
                    "arguments": arguments,
                    "dataset_manifest_path": dataset_relative,
                    "result_path": result_relative,
                    "strategy_manifest_path": strategy_relative,
                },
            },
            "summary": {
                "codex_version": self.codex_version,
                "model": job["model"],
                "reasoning_effort": job["reasoning_effort"],
                "tests_run": output.get("tests_run", []),
                "summary": output.get("summary"),
            },
        }

    def execute(self, job: Dict[str, Any]) -> Dict[str, Any]:
        contract = dict(job.get("preparation_contract") or {})
        policies = dict(contract.get("policies") or {})
        if job.get("provider") != "codex-cli":
            raise WorkerError(f"Unsupported preparation provider: {job.get('provider')}")
        if contract.get("schema_version") != "research-preparation-v1":
            raise WorkerError("Unsupported preparation contract")
        if contract.get("protocol_id") != "ATM-SVP-2" or policies.get("formal_backtest_allowed") is not False:
            raise WorkerError("Preparation contract does not preserve the formal-run safety boundary")
        execution_contract = dict(contract.get("execution_contract") or {})
        hard = dict(execution_contract.get("hard_constraints") or {})
        if (
            hard.get("max_gross") != 1.0
            or hard.get("leverage_allowed") is not False
            or hard.get("shorting_allowed") is not False
            or hard.get("financing_allowed") is not False
            or hard.get("digital_assets_allowed") is not False
            or hard.get("leveraged_products_allowed") is not False
        ):
            raise WorkerError("Preparation contract relaxes mandatory asset or exposure constraints")
        try:
            validate_research_policy_snapshot(execution_contract)
        except ValueError as exc:
            raise WorkerError(str(exc)) from exc
        worktree, base_commit = self.prepare_worktree(job)
        self.heartbeat(job, "codex_starting", base_commit=base_commit)
        output = self._run_codex(job, worktree)
        self.heartbeat(job, "validating_preparation")
        return self._verify_output(job, worktree, output, base_commit)

    def run_once(self) -> bool:
        if not self.flush_pending():
            return False
        job = self.claim()
        if job is None:
            return False
        study_key = str(job["study_key"])
        print(f"PREPARATION_CLAIMED study_key={study_key} model={job['model']}")
        try:
            completion = self.execute(job)
        except Exception as exc:
            completion = {
                "worker_id": self.worker_id,
                "lease_token": job["lease_token"],
                "outcome": "failed",
                "error": {"code": "PREPARATION_WORKER_ERROR", "message": str(exc)[:MAX_ERROR_TEXT]},
            }
        pending_path = self._write_pending(study_key, {"study_key": study_key, "payload": completion})
        try:
            response = self.api.request(f"/{study_key}/complete", completion)
        except Exception:
            print(f"PREPARATION_SPOOLED study_key={study_key} path={pending_path}", file=sys.stderr)
            raise
        pending_path.unlink()
        print(
            f"PREPARATION_FINISHED study_key={study_key} outcome={completion['outcome']} "
            f"server_status={response.get('status', 'unknown')}"
        )
        return True


def default_state_dir() -> Path:
    configured = os.environ.get("FLYINGRTX_RESEARCH_PREPARATION_STATE")
    if configured:
        return Path(configured).expanduser()
    workspace = os.environ.get("ASSET_TIME_MACHINE_RESEARCH_WORKSPACE")
    research_root = (
        Path(workspace).expanduser()
        if workspace
        else (
            Path(__file__).resolve().parents[1].parent
            / "FlyingrtxFast"
            / "research"
            / "asset-time-machine"
            / "workspace"
        )
    )
    return research_root / "agent" / "preparation"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("FLYINGRTX_API_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--state-dir", type=Path, default=default_state_dir())
    parser.add_argument("--worker-id", default=f"atm-preparation-mac:{socket.gethostname()}")
    parser.add_argument("--codex", default=shutil.which("codex") or "codex")
    parser.add_argument("--poll-seconds", type=int, default=20)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    token = os.environ.get("FLYINGRTX_RESEARCH_PREPARATION_TOKEN", "").strip()
    if not token:
        raise SystemExit("FLYINGRTX_RESEARCH_PREPARATION_TOKEN is required")
    if not (args.repo / ".git").exists():
        raise SystemExit(f"AssetTimeMachine Git repository not found: {args.repo}")

    worker = ResearchPreparationWorker(
        ResearchPreparationApi(args.base_url, token),
        args.repo,
        args.state_dir,
        args.worker_id,
        args.codex,
    )
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    had_error = False
    while not stopping:
        try:
            did_work = worker.run_once()
        except Exception as exc:
            print(f"PREPARATION_WORKER_ERROR {exc}", file=sys.stderr)
            did_work = False
            had_error = True
        if args.once:
            break
        if not did_work:
            time.sleep(max(5, args.poll_seconds))
    if args.once and had_error:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
