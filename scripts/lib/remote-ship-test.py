#!/usr/bin/env python3
"""#4507: a development snapshot reaches the other checkout exactly, and nothing
of this checkout changes. Two private repositories stand in for the two Macs
(the transport is git's own bundle and fetch; SSH is not involved)."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
