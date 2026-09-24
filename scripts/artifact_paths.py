#!/usr/bin/env python3
"""Resolve ATM research artifact paths across the App repo and the archive repo.

Background
----------
The ATM-SVP research artifacts used to live only in this repository under
``tools/research-results/`` and ``tools/fixtures/``.  They have been archived to
the FlyingrtxFast repository (``research/asset-time-machine/``) so that this
repository no longer carries ~175 MiB of research payload.

The frozen governance records (``trial-ledger.jsonl`` and every RESULT, dataset
and artifact manifest) still name the **old, App-repo-relative paths**.  Those
records are hash-chained and append-only, so they must never be rewritten.  That
means the logical path ``tools/research-results/...`` remains the canonical
*identity* of an artifact, while its *physical* location may now be either:

* inside this repository (the historical layout, and where new artifacts are
  still written), or
* inside the archive repository (where the frozen read-only bulk now lives).

This module is the single place that knows how to turn one into the other.

Resolution order (read)
-----------------------
1. ``<repo_root>/<logical>``                      -- in-repo wins, unchanged behaviour
2. ``<archive_root>/research/asset-time-machine/<mapped>``
3. the in-repo path, so the resulting error message is the familiar one

Writes always stay in this repository (``for_write=True``); the formal-run
pipeline creates its output inside a detached git worktree of this repo.

Archive root selection
----------------------
``ATM_RESEARCH_ROOT`` if set, otherwise a sibling ``FlyingrtxFast`` checkout of
this repository.  ``ATM_RESEARCH_ROOT`` may point either at the archive repo root
or directly at its ``research/asset-time-machine`` directory.

Compressed artifacts
--------------------
Two frozen schedule grids are stored ``.json.xz`` in the archive (122 MiB raw,
110x and 34x compression).  ``open_binary``/``read_bytes``/``read_text``/``load_json``
transparently decompress, so callers see the original bytes.  Use ``resolve()``
directly only when you need the on-disk path and can handle ``.xz`` yourself.
"""
from __future__ import annotations

import hashlib
import json
import lzma
import os
import subprocess
from pathlib import Path
from typing import Any, BinaryIO

ARCHIVE_SUBDIR = "research/asset-time-machine"


class ArtifactPathError(RuntimeError):
    """Raised when artifact path configuration is unusable.

    Deliberately loud: silently resolving frozen artifacts from a different
    location than the operator asked for would make "which data produced this
    result" unanswerable.
    """


#: App-repo logical prefix -> archive-relative prefix
ARCHIVE_PREFIX_MAP: tuple[tuple[str, str], ...] = (
    ("tools/research-results/", f"{ARCHIVE_SUBDIR}/"),
    ("tools/fixtures/", f"{ARCHIVE_SUBDIR}/fixtures/"),
)

#: Directory holding the governance records that stay in this repository.
STRATEGY_VALIDATION_DIR = "tools/research-results/strategy-validation"


def app_repo_root(start: Path | str | None = None) -> Path:
    """Repo root of the App checkout that contains this module."""
    anchor = Path(start) if start is not None else Path(__file__)
    return anchor.resolve().parents[1]


def _sibling_candidates(root: Path) -> tuple[Path, ...]:
    return (root.parent / "FlyingrtxFast", root / "FlyingrtxFast")


def main_checkout_root(repo_root: Path | str) -> Path | None:
    """Root of the *main* checkout when ``repo_root`` is a linked git worktree.

    Formal runs execute inside a detached worktree, which is created wherever the
    worker's state directory happens to live.  The archive repo is a sibling of
    the main checkout, not of that worktree, so sibling discovery must be anchored
    on the main checkout root instead.
    """
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    raw = completed.stdout.strip()
    if not raw:
        return None
    common = Path(raw)
    if not common.is_absolute():
        common = Path(repo_root) / common
    try:
        common = common.resolve()
    except OSError:
        return None
    return common.parent if common.name == ".git" else None


def archive_root(repo_root: Path | str | None = None) -> Path | None:
    """Best-effort location of the archive repo, or ``None`` if not found.

    Accepts either the archive repository root or its ``research/asset-time-machine``
    directory, from ``ATM_RESEARCH_ROOT`` or a sibling ``FlyingrtxFast`` checkout of
    this repository (or of its main checkout, when running inside a linked worktree).
    """
    env = os.environ.get("ATM_RESEARCH_ROOT")
    if env:
        candidate = Path(env).expanduser()
        if not candidate.is_dir():
            raise ArtifactPathError(
                f"ATM_RESEARCH_ROOT is set to {env!r} but is not a directory. "
                "Unset it to fall back to sibling-checkout discovery, or point it at "
                "the archive repository root."
            )
        candidate = candidate.resolve()
        # Allow pointing straight at research/asset-time-machine.
        if candidate.name == "asset-time-machine" and candidate.parent.name == "research":
            return candidate.parent.parent
        if not (candidate / ARCHIVE_SUBDIR).is_dir():
            raise ArtifactPathError(
                f"ATM_RESEARCH_ROOT={env!r} has no {ARCHIVE_SUBDIR}/ directory; "
                "it does not look like the archive repository."
            )
        return candidate

    root = Path(repo_root).resolve() if repo_root is not None else app_repo_root()
    anchors = [root]
    main_root = main_checkout_root(root)
    if main_root is not None and main_root != root:
        anchors.append(main_root)
    for anchor in anchors:
        for candidate in _sibling_candidates(anchor):
            if (candidate / ARCHIVE_SUBDIR).is_dir():
                return candidate
    return None


def archive_relative(logical: str) -> str | None:
    """Map an App-repo logical artifact path to its archive-relative path.

    Returns ``None`` when the path is not an artifact path this module manages.
    """
    pure = logical.replace(os.sep, "/")
    for app_prefix, archive_prefix in ARCHIVE_PREFIX_MAP:
        if pure.startswith(app_prefix):
            return archive_prefix + pure[len(app_prefix):]
    return None


def _archive_candidate(logical: str, root: Path | None) -> Path | None:
    if root is None:
        return None
    relative = archive_relative(logical)
    if relative is None:
        return None
    return root / relative


def resolve(logical: str | Path, *, repo_root: Path | str | None = None, for_write: bool = False) -> Path:
    """Resolve a logical artifact path to an on-disk path.

    ``for_write=True`` always resolves inside this repository.  Otherwise the
    in-repo path wins when it exists, then the archive, then the in-repo path.
    """
    logical_str = str(logical).replace(os.sep, "/")
    root = Path(repo_root).resolve() if repo_root is not None else app_repo_root()
    in_repo = root / logical_str

    if for_write:
        return in_repo
    if in_repo.exists():
        return in_repo

    archived = _archive_candidate(logical_str, archive_root(root))
    if archived is not None:
        if archived.exists():
            return archived
        compressed = Path(f"{archived}.xz")
        if compressed.exists():
            return compressed

    return in_repo


def exists(logical: str | Path, *, repo_root: Path | str | None = None) -> bool:
    return resolve(logical, repo_root=repo_root).exists()


def open_binary(logical: str | Path, *, repo_root: Path | str | None = None) -> BinaryIO:
    """Open an artifact for reading, transparently decompressing ``.xz``."""
    path = resolve(logical, repo_root=repo_root)
    if path.suffix == ".xz":
        return lzma.open(path, "rb")
    return path.open("rb")


def read_bytes(logical: str | Path, *, repo_root: Path | str | None = None) -> bytes:
    path = resolve(logical, repo_root=repo_root)
    if path.suffix == ".xz":
        with lzma.open(path, "rb") as handle:
            return handle.read()
    return path.read_bytes()


def read_text(logical: str | Path, *, repo_root: Path | str | None = None, encoding: str = "utf-8") -> str:
    return read_bytes(logical, repo_root=repo_root).decode(encoding)


def load_json(logical: str | Path, *, repo_root: Path | str | None = None) -> Any:
    return json.loads(read_text(logical, repo_root=repo_root))


def sha256_of(logical: str | Path, *, repo_root: Path | str | None = None) -> str:
    """SHA-256 of an artifact's *logical* content.

    For a ``.json.xz`` archive copy this hashes the decompressed bytes, so the
    value still matches the pins recorded in ``trial-ledger.jsonl``.
    """
    return hashlib.sha256(read_bytes(logical, repo_root=repo_root)).hexdigest()


def describe(repo_root: Path | str | None = None) -> dict[str, Any]:
    """Diagnostic summary; useful in CI logs and when debugging resolution."""
    root = Path(repo_root).resolve() if repo_root is not None else app_repo_root()
    archive = archive_root(root)
    return {
        "app_repo_root": str(root),
        "archive_root": str(archive) if archive else None,
        "archive_env_override": os.environ.get("ATM_RESEARCH_ROOT"),
        "in_repo_strategy_validation_exists": (root / STRATEGY_VALIDATION_DIR).is_dir(),
        "archive_strategy_validation_exists": bool(
            archive and (archive / ARCHIVE_SUBDIR / "strategy-validation").is_dir()
        ),
    }


if __name__ == "__main__":  # pragma: no cover - manual diagnostics
    import argparse

    parser = argparse.ArgumentParser(description="Show ATM artifact path resolution.")
    parser.add_argument("logical", nargs="?", help="logical artifact path to resolve")
    parser.add_argument("--repo-root", type=Path, default=None)
    args = parser.parse_args()

    print(json.dumps(describe(args.repo_root), indent=2))
    if args.logical:
        resolved = resolve(args.logical, repo_root=args.repo_root)
        print(f"\n{args.logical}\n  -> {resolved}\n  exists={resolved.exists()}")
