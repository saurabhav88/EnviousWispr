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
  refs/ew-remote/<run_id>, bundled against the commit it shares with origin/main.
- verify_bundle_script(bundle, repo_url, cleanup): the remote shell step that verifies
  the bundle and, when its base is missing there, fetches main from GitHub once and
  verifies again (#4712); exit 47 asks the caller for a full bundle.
"""

import hashlib
import os
import shlex
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
    # Thin against the commit this branch shares with main, not main's tip: a branch
    # that main has since moved past would otherwise ship its whole history (#4712).
    # That shared commit is on GitHub main, so verify_bundle_script can fetch it.
    shared = subprocess.run(["git", "-C", str(root), "merge-base", "origin/main", commit],
                            capture_output=True, text=True)
    base = shared.stdout.strip() if shared.returncode == 0 else ""
    git(root, "bundle", "create", str(out_path), ref, *([f"^{base}"] if base else []))
    return commit, ref, bool(base)


FETCH_MAIN_SECONDS = 90  # well under both callers' 600 s SSH timeout
# perl <seconds> <command...>: run the command in a new process group; on the
# deadline TERM then KILL that group. Exit status is the command's, 124 on deadline.
_GROUP_DEADLINE_PERL = (
    '$s = shift; setpgrp(0, 0); my $p = fork; die "fork" unless defined $p; '
    'if ($p == 0) { exec @ARGV; exit 127 } '
    '$SIG{ALRM} = sub { $SIG{TERM} = "IGNORE"; kill "TERM", -$$; sleep 1; kill "KILL", -$$; exit 124 }; '
    'alarm $s; waitpid($p, 0); exit($? >> 8)')


def verify_bundle_script(bundle, repo_url, cleanup="", fetch_seconds=FETCH_MAIN_SECONDS):
    """Remote shell step: verify `bundle` (a shell word, may name a variable).

    A missing base usually means that Mac's clone is behind main. It fetches main
    from `repo_url` itself, which is faster than this Mac re-sending the whole
    history (#4712: ~600 MB over a ~4.7 MB/s link), then verifies again. The fetch
    is optional: a failed, slow or stalled one is stopped after `fetch_seconds`
    and changes nothing. macOS has no `timeout`, so perl runs git in its own
    process group and stops the WHOLE group (git and its network helpers), so no
    abandoned transfer overlaps the full-bundle fallback. Still missing: run
    `cleanup`, exit 47, and the caller sends full_bundle as before. Safe under `set -e`.
    """
    verify = f"git bundle verify -q {bundle} >/dev/null 2>&1"
    fetch = (f"/usr/bin/perl -e {shlex.quote(_GROUP_DEADLINE_PERL)} {int(fetch_seconds)} git fetch -q "
             f"{shlex.quote(repo_url)} +refs/heads/main:refs/remotes/origin/main >/dev/null 2>&1 || true")
    return f"{{ {verify} || {{ {fetch}; {verify}; }}; }} || {{ {cleanup} exit 47; }}"


def full_bundle(root, ref, out_path):
    git(root, "bundle", "create", str(out_path), ref)


def drop_ref(root, ref):
    subprocess.run(["git", "-C", str(root), "update-ref", "-d", ref], capture_output=True)
