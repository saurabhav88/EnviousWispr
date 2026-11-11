#!/usr/bin/env python3
"""Put an exact tree of this checkout on another Mac (#4507 §3.3-§3.4, G3).

Local side (the dispatcher) and remote side (the supervisor) share this module;
the supervisor runs the copy shipped inside the run, never an older one.

- dev_snapshot_tree(root): the worktree as a tree, for filtered runs. A private
  copy of the real index, then `git add -A` and `git write-tree` against that
  private copy only: tracked-but-ignored files stay,
  deletions are recorded, untracked non-ignored files are added, and the real index
  is never touched. Never push proof.
- refuse_unsupported(root, tree): submodules, tracked .gitattributes / .gitmodules /
  .lfsconfig would make the tree differ from the bytes a build reads; refused by name.
- fingerprint(root, tree): SHA-256 over the raw bytes (no Git filters; symlink
  targets as text) of every tracked file of `tree` under the compiled roots, read
  from the working files. Equal on both Macs = the compiled bytes are the same.
- make_bundle(root, tree, run_id): a commit of `tree` under a unique temporary ref
  refs/ew-remote/<run_id>, bundled against origin/main when that is an ancestor.
"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

COMPILED_ROOTS = ("Sources", "Tests", "scripts/eval", "Package.swift", "Package.resolved",
                  "Project.swift", "Tuist.swift", "Tuist")
UNSUPPORTED_NAMES = (".gitattributes", ".gitmodules", ".lfsconfig")


class ShipError(RuntimeError):
    """A setup failure: never a test result (runner exit 4)."""


def git(root, *args, env=None, input_bytes=None):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                            env=env, input=input_bytes)
    if result.returncode != 0:
        raise ShipError(f"git {' '.join(args[:3])} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode().strip()


def dev_snapshot_tree(root):
    # Seed a PRIVATE copy of the real index (even `git write-tree` against the real
    # index rewrites it, storing its cache-tree), then add the worktree to the copy.
    real_index = Path(git(root, "rev-parse", "--git-path", "index"))
    if not real_index.is_absolute():
        real_index = Path(root) / real_index
    tmp = Path(tempfile.mkdtemp(prefix="ew-snapshot-"))
    try:
        private = tmp / "index"
        if real_index.exists():
            shutil.copyfile(real_index, private)
        env = dict(os.environ, GIT_INDEX_FILE=str(private))
        git(root, "add", "-A", env=env)
        return git(root, "write-tree", env=env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def tree_entries(root, tree, *paths):
    out = git(root, "ls-tree", "-r", "-z", "--full-tree", tree, "--", *paths)
    entries = []
    for record in filter(None, out.split("\0")):
        meta, path = record.split("\t", 1)
        mode, kind, _sha = meta.split()
        entries.append((mode, kind, path))
    return entries


def refuse_unsupported(root, tree):
    for mode, kind, path in tree_entries(root, tree):
        if mode == "160000" or kind == "commit":
            raise ShipError(f"the tree contains a submodule ({path}); remote runs do not support it")
        if Path(path).name in UNSUPPORTED_NAMES:
            raise ShipError(f"the tree contains {path}; its checkout filters would change the bytes "
                            "a remote build reads, so remote runs refuse it")


def fingerprint(root, tree):
    digest = hashlib.sha256()
    for mode, kind, path in sorted(tree_entries(root, tree, *COMPILED_ROOTS), key=lambda e: e[2]):
        if kind != "blob":
            continue
        full = Path(root) / path
        try:
            data = os.readlink(full).encode() if mode == "120000" else full.read_bytes()
        except OSError:
            raise ShipError(f"compiled input {path} is missing from the working files") from None
        digest.update(path.encode() + b"\0" + mode.encode() + b"\0")
        digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()


def make_bundle(root, tree, run_id, out_path):
    """Commit `tree` under refs/ew-remote/<run_id> and bundle it; returns the commit."""
    head = git(root, "rev-parse", "--verify", "HEAD")
    commit = git(root, "commit-tree", tree, "-p", head, "-m", f"ew remote run {run_id}")
    ref = f"refs/ew-remote/{run_id}"
    git(root, "update-ref", ref, commit)
    base = subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", "origin/main", commit],
                          capture_output=True).returncode == 0
    git(root, "bundle", "create", str(out_path), ref, *(["^origin/main"] if base else []))
    return commit, ref, base


def full_bundle(root, ref, out_path):
    git(root, "bundle", "create", str(out_path), ref)


def drop_ref(root, ref):
    subprocess.run(["git", "-C", str(root), "update-ref", "-d", ref], capture_output=True)
