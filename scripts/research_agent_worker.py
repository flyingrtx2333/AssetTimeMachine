#!/usr/bin/env python3
"""Lease and execute frozen Research Agent jobs in isolated Git worktrees.

The worker accepts only a repository-relative Python entrypoint from a server-frozen
contract. It never invokes a shell and never stores the API key in job artifacts.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, Optional

from research_asset_policy import validate_research_policy_snapshot


API_PATH = "/api/v1/asset-time-machine/internal/research-agent/jobs"
DEFAULT_BASE_URL = "https://api.flyingrtx.com"
HEARTBEAT_SECONDS = 30
MAX_ERROR_TEXT = 6000


class WorkerError(RuntimeError):
    pass


class ApiError(WorkerError):
    def __init__(self, status: int, message: str):
        super().__init__(f"Research API {status}: {message}")
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


def build_formal_command(worktree: Path, runner: Dict[str, Any]) -> list[str]:
    entrypoint = safe_repo_path(worktree, str(runner["entrypoint"]))
    trial_id = str(runner["trial_id"])
    output_relative = f"tools/research-results/strategy-validation/runs/{trial_id}"
    candidate_output_relative = f"{output_relative}/candidates"
    safe_repo_path(worktree, output_relative)
    safe_repo_path(worktree, candidate_output_relative)
    arguments = [str(item) for item in runner.get("arguments", [])]
    if any("\x00" in item or "\n" in item or "\r" in item for item in arguments):
        raise WorkerError("Runner arguments contain forbidden control characters")
    return [
        sys.executable,
        "scripts/strategy_validation_formal_run.py",
        "--trial-id",
        trial_id,
        "--output-dir",
        output_relative,
        "--",
        sys.executable,
        str(runner["entrypoint"]),
        "--output-dir",
        candidate_output_relative,
        *arguments,
    ]


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
        raise WorkerError(f"Cannot read required JSON artifact: {path}") from exc
    if not isinstance(value, dict):
        raise WorkerError(f"Required JSON artifact is not an object: {path}")
    return value


def artifact_checksums(worktree: Path, paths: Iterable[str]) -> list[Dict[str, Any]]:
    checksums: list[Dict[str, Any]] = []
    seen: set[str] = set()
    for relative in paths:
        if not relative or relative in seen:
            continue
        seen.add(relative)
        path = safe_repo_path(worktree, relative)
        if not path.is_file():
            continue
        checksums.append({"path": relative, "sha256": sha256_file(path), "size_bytes": path.stat().st_size})
        if len(checksums) >= 512:
            break
    return checksums


class ResearchApi:
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
            raise WorkerError(f"Research API unavailable: {exc.reason}") from exc
        value = json.loads(raw or "{}")
        if not isinstance(value, dict):
            raise WorkerError("Research API returned a non-object response")
        return value


class ResearchWorker:
    def __init__(
        self,
        api: ResearchApi,
        repo: Path,
        state_dir: Path,
        worker_id: str,
    ):
        self.api = api
        self.repo = repo.resolve()
        self.state_dir = state_dir.resolve()
        self.worker_id = worker_id
        self.pending_dir = self.state_dir / "pending"
        self.worktrees_dir = self.state_dir / "worktrees"
        self.logs_dir = self.state_dir / "logs"
        for directory in (self.pending_dir, self.worktrees_dir, self.logs_dir):
            directory.mkdir(parents=True, exist_ok=True)

    def _pending_path(self, study_key: str) -> Path:
        safe_key = "".join(character if character.isalnum() or character in "_.-" else "_" for character in study_key)
        return self.pending_dir / f"{safe_key}.json"

    def _write_pending(self, study_key: str, payload: Dict[str, Any]) -> Path:
        target = self._pending_path(study_key)
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(target)
        return target

    def flush_pending(self) -> bool:
        pending = sorted(self.pending_dir.glob("*.json"))
        for path in pending:
            envelope = read_json(path)
            study_key = str(envelope["study_key"])
            payload = dict(envelope["payload"])
            self.api.request(f"/{study_key}/complete", payload)
            path.unlink()
            print(f"COMPLETION_ACKNOWLEDGED study_key={study_key}")
        return not any(self.pending_dir.glob("*.json"))

    def claim(self) -> Optional[Dict[str, Any]]:
        response = self.api.request("/claim", {
            "worker_id": self.worker_id,
            "capabilities": ["atm-svp-2", "git-worktree", "python-entrypoint", "strategy-library-v2"],
        })
        job = response.get("job")
        if job is None:
            return None
        if not isinstance(job, dict):
            raise WorkerError("Claim response contains an invalid job")
        return job

    def heartbeat(self, job: Dict[str, Any], phase: str, **details: Any) -> Dict[str, Any]:
        return self.api.request(f"/{job['study_key']}/heartbeat", {
            "worker_id": self.worker_id,
            "lease_token": job["lease_token"],
            "progress": {"phase": phase, **details},
        })

    def prepare_worktree(self, job: Dict[str, Any]) -> Path:
        authorization = str(job["authorization_sha256"])
        commit = str(job["execution_commit"])
        worktree = self.worktrees_dir / authorization
        run_git(self.repo, "cat-file", "-e", f"{commit}^{{commit}}")
        if worktree.exists():
            existing = run_git(worktree, "rev-parse", "HEAD").stdout.strip()
            if existing != commit:
                raise WorkerError("Existing isolated worktree points at a different commit")
        else:
            run_git(self.repo, "worktree", "add", "--detach", str(worktree), commit)
        if run_git(worktree, "status", "--porcelain").stdout.strip():
            raise WorkerError("Isolated worktree is not clean before formal execution")
        return worktree

    def validate_frozen_inputs(self, job: Dict[str, Any], worktree: Path) -> Dict[str, Any]:
        contract = dict(job["execution_contract"])
        if contract.get("authorization_sha256") != job.get("authorization_sha256"):
            raise WorkerError("Authorization hash differs between claim and contract")
        if contract.get("protocol_id") != "ATM-SVP-2":
            raise WorkerError("Worker only accepts ATM-SVP-2 contracts")
        hard = dict(contract.get("hard_constraints") or {})
        if (
            hard.get("max_gross") != 1.0
            or hard.get("leverage_allowed") is not False
            or hard.get("shorting_allowed") is not False
            or hard.get("financing_allowed") is not False
            or hard.get("digital_assets_allowed") is not False
            or hard.get("leveraged_products_allowed") is not False
        ):
            raise WorkerError("Frozen contract relaxes mandatory asset or exposure constraints")
        try:
            validate_research_policy_snapshot(contract)
        except ValueError as exc:
            raise WorkerError(str(exc)) from exc
        runner = dict(contract.get("runner") or {})
        evidence = dict(contract.get("bound_evidence") or {})
        entrypoint = safe_repo_path(worktree, str(runner["entrypoint"]))
        dataset_manifest = safe_repo_path(worktree, str(runner["dataset_manifest_path"]))
        if not entrypoint.is_file() or not dataset_manifest.is_file():
            raise WorkerError("Frozen entrypoint or dataset manifest is missing at execution commit")
        if sha256_file(entrypoint) != evidence.get("code_sha256"):
            raise WorkerError("Frozen entrypoint SHA-256 mismatch")
        if sha256_file(dataset_manifest) != evidence.get("dataset_manifest_sha256"):
            raise WorkerError("Frozen dataset manifest SHA-256 mismatch")
        if run_git(worktree, "rev-parse", "HEAD").stdout.strip() != evidence.get("execution_commit"):
            raise WorkerError("Worktree commit differs from bound execution evidence")
        return runner

    def execute(self, job: Dict[str, Any]) -> Dict[str, Any]:
        study_key = str(job["study_key"])
        worktree = self.prepare_worktree(job)
        self.heartbeat(job, "validating_frozen_inputs")
        runner = self.validate_frozen_inputs(job, worktree)
        command = build_formal_command(worktree, runner)
        log_prefix = self.logs_dir / str(job["authorization_sha256"])
        stdout_path = log_prefix.with_suffix(".stdout.txt")
        stderr_path = log_prefix.with_suffix(".stderr.txt")
        started_at = time.monotonic()
        with stdout_path.open("w", encoding="utf-8") as stdout_handle, stderr_path.open("w", encoding="utf-8") as stderr_handle:
            process = subprocess.Popen(command, cwd=worktree, stdout=stdout_handle, stderr=stderr_handle, text=True)
            while process.poll() is None:
                time.sleep(min(HEARTBEAT_SECONDS, 5))
                elapsed = int(time.monotonic() - started_at)
                if elapsed > 0 and elapsed % HEARTBEAT_SECONDS < 5:
                    heartbeat = self.heartbeat(job, "formal_run", pid=process.pid, elapsed_seconds=elapsed)
                    if heartbeat.get("cancel_requested"):
                        process.terminate()
                        try:
                            process.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            process.kill()
                        raise WorkerError("Formal execution was cancelled by the control plane")
            return_code = int(process.returncode or 0)

        trial_id = str(runner["trial_id"])
        execution_relative = f"tools/research-results/strategy-validation/runs/{trial_id}/execution.json"
        execution_path = safe_repo_path(worktree, execution_relative)
        execution_receipt = read_json(execution_path) if execution_path.is_file() else None
        if return_code != 0:
            stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-MAX_ERROR_TEXT:]
            return {
                "worker_id": self.worker_id,
                "lease_token": job["lease_token"],
                "outcome": "failed",
                "exit_code": return_code,
                "execution_receipt": execution_receipt,
                "artifact_checksums": artifact_checksums(worktree, [execution_relative]),
                "error": {"code": "FORMAL_RUN_FAILED", "message": stderr_tail or f"exit code {return_code}"},
            }

        result_path = safe_repo_path(worktree, str(runner["result_path"]))
        strategy_manifest_path = safe_repo_path(worktree, str(runner["strategy_manifest_path"]))
        result = read_json(result_path)
        strategy_manifest = read_json(strategy_manifest_path)
        artifact_paths = [
            execution_relative,
            str(runner["result_path"]),
            str(runner["strategy_manifest_path"]),
            *[str(item) for item in result.get("artifacts", []) if isinstance(item, str)],
        ]
        return {
            "worker_id": self.worker_id,
            "lease_token": job["lease_token"],
            "outcome": "completed",
            "exit_code": 0,
            "execution_receipt": execution_receipt,
            "result_document": result,
            "strategy_manifest": strategy_manifest,
            "artifact_checksums": artifact_checksums(worktree, artifact_paths),
            "error": None,
        }

    def run_once(self) -> bool:
        if not self.flush_pending():
            return False
        job = self.claim()
        if job is None:
            return False
        study_key = str(job["study_key"])
        print(f"JOB_CLAIMED study_key={study_key} authorization={job['authorization_sha256']}")
        try:
            completion = self.execute(job)
        except Exception as exc:
            completion = {
                "worker_id": self.worker_id,
                "lease_token": job["lease_token"],
                "outcome": "failed",
                "exit_code": None,
                "execution_receipt": None,
                "artifact_checksums": [],
                "error": {"code": "WORKER_ERROR", "message": str(exc)[:MAX_ERROR_TEXT]},
            }
        pending_path = self._write_pending(study_key, {"study_key": study_key, "payload": completion})
        try:
            response = self.api.request(f"/{study_key}/complete", completion)
        except Exception:
            print(f"COMPLETION_SPOOLED study_key={study_key} path={pending_path}", file=sys.stderr)
            raise
        pending_path.unlink()
        print(
            f"JOB_FINISHED study_key={study_key} outcome={completion['outcome']} "
            f"server_status={response.get('status', 'unknown')}"
        )
        return True


def default_state_dir() -> Path:
    configured = os.environ.get("FLYINGRTX_RESEARCH_WORKER_STATE")
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
    return research_root / "agent" / "execution"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("FLYINGRTX_API_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--state-dir", type=Path, default=default_state_dir())
    parser.add_argument("--worker-id", default=f"atm-mac:{socket.gethostname()}")
    parser.add_argument("--poll-seconds", type=int, default=20)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    token = os.environ.get("FLYINGRTX_RESEARCH_WORKER_TOKEN", "").strip()
    if not token:
        raise SystemExit("FLYINGRTX_RESEARCH_WORKER_TOKEN is required")
    if not (args.repo / ".git").exists():
        raise SystemExit(f"AssetTimeMachine Git repository not found: {args.repo}")

    worker = ResearchWorker(
        ResearchApi(args.base_url, token),
        args.repo,
        args.state_dir,
        args.worker_id,
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
            print(f"WORKER_ERROR {exc}", file=sys.stderr)
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
