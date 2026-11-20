#!/usr/bin/env python3
"""#4507: a development snapshot reaches the other checkout exactly, and nothing
of this checkout changes. Two private repositories stand in for the two Macs
(the transport is git's own bundle and fetch; SSH is not involved)."""

import hashlib
import os
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import remote_ship  # noqa: E402

spec = importlib.util.spec_from_file_location("remote_job", HERE / "remote-job.py")
remote_job = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote_job)


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                          text=True).stdout.strip()


class ShipContract(unittest.TestCase):
    def test_development_snapshot_arrives_exactly_and_leaves_this_checkout_alone(self):
        with tempfile.TemporaryDirectory(prefix="ew-ship-") as tmp:
            src, dst = Path(tmp) / "source", Path(tmp) / "other-mac"
            (src / "Sources").mkdir(parents=True)
            (src / "Sources/A.swift").write_text("let a = 1\n")
            (src / "Sources/Gone.swift").write_text("let gone = 1\n")
            (src / ".gitignore").write_text("ignored.txt\n")
            git(src.parent, "init", "-q", str(src))
            for cfg in (("user.email", "t@t"), ("user.name", "t")):
                git(src, "config", *cfg)
            git(src, "add", "-A")
            git(src, "commit", "-qm", "base")
            git(src.parent, "clone", "-q", str(src), str(dst))
            # Unstaged edit, a staged edit, a deletion, a new untracked file, an ignored file.
            (src / "Sources/A.swift").write_text("let a = 2\n")
            (src / "Sources/Staged.swift").write_text("let staged = 1\n")
            git(src, "add", "Sources/Staged.swift")
            (src / "Sources/Gone.swift").unlink()
            (src / "Sources/New.swift").write_text("let fresh = 1\n")
            (src / "ignored.txt").write_text("stays home\n")
            status = git(src, "status", "--porcelain")  # may refresh the index; read it after
            index = (src / ".git/index").read_bytes()

            tree = remote_ship.dev_snapshot_tree(src)
            fingerprint = remote_ship.fingerprint(src, tree)
            commit, ref, _ = remote_ship.make_bundle(src, tree, "testrun", Path(tmp) / "t.bundle")
            git(dst, "fetch", "-q", str(Path(tmp) / "t.bundle"), f"{ref}:{ref}")
            remote_job.prepare_checkout(dst, {"commit": commit, "tree": tree, "mode": "filtered",
                                              "fingerprint": fingerprint})
            remote_ship.drop_ref(src, ref)

            # Exactly the worktree's code arrived (the ignored file did not).
            self.assertEqual((dst / "Sources/A.swift").read_text(), "let a = 2\n")
            self.assertTrue((dst / "Sources/Staged.swift").exists())
            self.assertTrue((dst / "Sources/New.swift").exists())
            self.assertFalse((dst / "Sources/Gone.swift").exists())
            self.assertFalse((dst / "ignored.txt").exists())
            self.assertEqual(remote_ship.fingerprint(dst, tree), fingerprint)
            # This checkout: same index bytes, no temporary ref, same status.
            self.assertEqual(hashlib.sha256((src / ".git/index").read_bytes()).digest(),
                             hashlib.sha256(index).digest())
            self.assertEqual(git(src, "for-each-ref", "refs/ew-remote/"), "")
            self.assertEqual(git(src, "status", "--porcelain"), status)


class VerifyStep(unittest.TestCase):
    """#4712: the real remote shell step, run under `set -e` as both callers run it."""

    def run_step(self, clone, bundle, repo_url, extra_env=None, **kwargs):
        script = "set -e; " + remote_ship.verify_bundle_script(
            '"$B"', repo_url, 'touch cleaned;', **kwargs) + "; echo verified"
        env = {"B": str(bundle), "PATH": "/usr/bin:/bin", **(extra_env or {})}
        return subprocess.run(["bash", "-c", script], cwd=clone, env=env, capture_output=True, text=True,
                              timeout=60)

    def setup_behind_clone(self, tmp):
        """A source with origin/main one commit ahead of the other Mac's clone."""
        hub, src, dst = Path(tmp) / "hub.git", Path(tmp) / "source", Path(tmp) / "other-mac"
        git(tmp, "init", "-q", "--bare", "-b", "main", str(hub))
        git(tmp, "clone", "-q", str(hub), str(src))
        for cfg in (("user.email", "t@t"), ("user.name", "t")):
            git(src, "config", *cfg)
        (src / "a.txt").write_text("1\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "one")
        git(src, "push", "-q", "origin", "HEAD:main")
        git(tmp, "clone", "-q", str(hub), str(dst))
        (src / "a.txt").write_text("2\n")
        git(src, "commit", "-qam", "two")
        git(src, "push", "-q", "origin", "HEAD:main")
        git(src, "fetch", "-q")
        (src / "a.txt").write_text("3\n")
        tree = remote_ship.dev_snapshot_tree(src)
        _, ref, based = remote_ship.make_bundle(src, tree, "testrun", Path(tmp) / "t.bundle")
        self.assertTrue(based)  # a thin bundle that needs commit "two"
        return hub, dst, Path(tmp) / "t.bundle", ref

    def test_a_clone_behind_main_fetches_main_and_verifies(self):
        with tempfile.TemporaryDirectory(prefix="ew-verify-") as tmp:
            hub, dst, bundle, ref = self.setup_behind_clone(tmp)
            plain = subprocess.run(["git", "-C", str(dst), "bundle", "verify", "-q", str(bundle)],
                                   capture_output=True)
            self.assertNotEqual(plain.returncode, 0)  # control: verify alone fails here
            r = self.run_step(dst, bundle, str(hub))
            self.assertEqual((r.returncode, r.stdout.strip()), (0, "verified"), r.stderr)
            self.assertFalse((dst / "cleaned").exists())
            git(dst, "fetch", "-q", str(bundle), f"{ref}:{ref}")

    def test_a_branch_behind_main_still_ships_thin(self):
        """Main moved past the branch: the bundle still carries only the branch's own commits."""
        with tempfile.TemporaryDirectory(prefix="ew-verify-") as tmp:
            hub, src = Path(tmp) / "hub.git", Path(tmp) / "source"
            git(tmp, "init", "-q", "--bare", "-b", "main", str(hub))
            git(tmp, "clone", "-q", str(hub), str(src))
            for cfg in (("user.email", "t@t"), ("user.name", "t")):
                git(src, "config", *cfg)
            (src / "a.txt").write_text("1\n")
            git(src, "add", "-A")
            git(src, "commit", "-qm", "shared")
            git(src, "push", "-q", "origin", "HEAD:main")
            git(src, "checkout", "-qb", "feature")
            (src / "b.txt").write_text("branch\n")
            git(src, "add", "-A")
            git(src, "commit", "-qm", "branch work")
            other = Path(tmp) / "other"  # someone else moves main on
            git(tmp, "clone", "-q", str(hub), str(other))
            for cfg in (("user.email", "t@t"), ("user.name", "t")):
                git(other, "config", *cfg)
            (other / "c.txt").write_text("main moved\n")
            git(other, "add", "-A")
            git(other, "commit", "-qm", "main moved")
            git(other, "push", "-q", "origin", "HEAD:main")
            git(src, "fetch", "-q")
            tree = remote_ship.dev_snapshot_tree(src)
            _, _, based = remote_ship.make_bundle(src, tree, "testrun", Path(tmp) / "t.bundle")
            self.assertTrue(based)
            heads = subprocess.run(["git", "bundle", "list-heads", str(Path(tmp) / "t.bundle")],
                                   capture_output=True, text=True, cwd=src).stdout
            verify = subprocess.run(["git", "-C", str(src), "bundle", "verify", str(Path(tmp) / "t.bundle")],
                                    capture_output=True, text=True)
            needs = git(src, "rev-parse", "main")  # the shared commit, not main's new tip
            self.assertIn(needs, verify.stdout + verify.stderr)
            self.assertNotIn(git(src, "rev-parse", "origin/main"), verify.stdout + verify.stderr)
            self.assertTrue(heads)

    def test_an_unreachable_repo_exits_47_after_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="ew-verify-") as tmp:
            _, dst, bundle, _ = self.setup_behind_clone(tmp)
            r = self.run_step(dst, bundle, str(Path(tmp) / "missing.git"))
            self.assertEqual(r.returncode, 47, r.stdout + r.stderr)
            self.assertNotIn("verified", r.stdout)
            self.assertTrue((dst / "cleaned").exists())

    def test_a_stalled_fetch_is_stopped_and_falls_back(self):
        """Codex P2: a slow GitHub must not eat the caller's SSH timeout."""
        with tempfile.TemporaryDirectory(prefix="ew-verify-") as tmp:
            _, dst, bundle, _ = self.setup_behind_clone(tmp)
            allow_ext = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.ext.allow",
                         "GIT_CONFIG_VALUE_0": "always"}
            started = time.monotonic()
            pidfile = Path(tmp) / "helper.pid"  # this run's helper only, never a machine-wide search
            # ext:: splits on spaces; "% " is a literal space. The helper records its PID, then stalls.
            url = 'ext::sh -c echo% $$% >"$PIDFILE";% exec% sleep% 30'  # path via env: safe with spaces
            r = self.run_step(dst, bundle, url, extra_env={**allow_ext, "PIDFILE": str(pidfile)},
                              fetch_seconds=2)
            elapsed = time.monotonic() - started
            self.assertEqual(r.returncode, 47, r.stdout + r.stderr)
            self.assertTrue((dst / "cleaned").exists())
            self.assertLess(elapsed, 15)
            self.assertTrue(pidfile.exists(), "the stalled helper never started")
            pid = int(pidfile.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and self.pid_alive(pid):
                time.sleep(0.1)
            self.assertFalse(self.pid_alive(pid), "the stalled fetch's network helper is still running")

    @staticmethod
    def pid_alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True


if __name__ == "__main__":
    unittest.main()
