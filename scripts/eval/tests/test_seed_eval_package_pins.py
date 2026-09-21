#!/usr/bin/env python3
"""Tests for scripts/ci/seed-eval-package-pins.py (#996 chunk 2b-ii follow-up).

compile-eval-packages.sh seeds each standalone eval package's Package.resolved
from the app's tracked pins and then builds with
`--only-use-versions-from-resolved-file`. alias_runner depends on a package the
app does not (swift-transformers), so the seed must also carry the package's
tracked runner-only pins, and it must refuse a runner-only pin that would shadow
an app pin. The tracked alias_runner pins file is run through the same merge, so
it cannot drift into a shape the merge refuses; SwiftPM's own acceptance is proven
by compile-eval-packages.sh, not here.

Run from repo root:
  python3 scripts/eval/tests/test_seed_eval_package_pins.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "scripts" / "ci" / "seed-eval-package-pins.py"
ALIAS_RUNNER = REPO / "scripts" / "eval" / "alias_runner"

_spec = importlib.util.spec_from_file_location("seed_eval_package_pins", SCRIPT)
seed_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(seed_mod)


def _pin(identity: str, version: str = "1.0.0") -> dict:
    return {
        "identity": identity,
        "kind": "remoteSourceControl",
        "location": f"https://example.invalid/{identity}",
        "state": {"revision": "0" * 40, "version": version},
    }


class SeedEvalPackagePinsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "Package.resolved"
        self.root.write_text(
            json.dumps({"originHash": "abc", "pins": [_pin("shared", "2.0.0")], "version": 3})
        )
        self.pkg = self.tmp / "pkg"
        self.pkg.mkdir()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _runner_only(self, pins: object) -> None:
        (self.pkg / seed_mod.RUNNER_ONLY_NAME).write_text(json.dumps({"pins": pins, "version": 3}))

    def _seeded(self) -> dict:
        return json.loads((self.pkg / "Package.resolved").read_text())

    def test_no_runner_only_file_copies_root_pins_verbatim(self) -> None:
        seed_mod.seed(self.root, self.pkg)
        self.assertEqual(self._seeded(), json.loads(self.root.read_text()))

    def test_runner_only_pins_are_appended_after_root_pins(self) -> None:
        self._runner_only([_pin("runner-only", "1.3.4")])
        seed_mod.seed(self.root, self.pkg)
        out = self._seeded()
        self.assertEqual([p["identity"] for p in out["pins"]], ["shared", "runner-only"])
        self.assertEqual(out["pins"][0]["state"]["version"], "2.0.0")
        self.assertEqual(out["version"], 3)

    def test_runner_only_pin_that_shadows_an_app_pin_is_refused(self) -> None:
        self._runner_only([_pin("shared", "9.9.9")])
        with self.assertRaises(seed_mod.SeedError) as ctx:
            seed_mod.seed(self.root, self.pkg)
        self.assertIn("'shared' is already pinned", str(ctx.exception))
        self.assertFalse((self.pkg / "Package.resolved").exists())

    def test_incomplete_runner_only_pin_is_refused(self) -> None:
        self._runner_only([{"identity": "half"}])
        with self.assertRaises(seed_mod.SeedError):
            seed_mod.seed(self.root, self.pkg)
        self._runner_only({"not": "a list"})
        with self.assertRaises(seed_mod.SeedError):
            seed_mod.seed(self.root, self.pkg)

    def test_wrongly_typed_documents_and_pins_are_refused_with_exit_2(self) -> None:
        def refused(document: object) -> None:
            (self.pkg / seed_mod.RUNNER_ONLY_NAME).write_text(json.dumps(document))
            with self.assertRaises(seed_mod.SeedError):
                seed_mod.seed(self.root, self.pkg)
            self.assertEqual(seed_mod.main(["seed", str(self.root), str(self.pkg)]), 2)

        refused({"pins": [_pin("ok")], "version": 2})
        bad_identity = _pin("x")
        bad_identity["identity"] = 7
        refused({"pins": [bad_identity], "version": 3})
        bad_kind = _pin("k")
        bad_kind["kind"] = "carrierPigeon"
        refused({"pins": [bad_kind], "version": 3})
        bad_state = _pin("s")
        bad_state["state"] = {"note": "no version, branch or revision"}
        refused({"pins": [bad_state], "version": 3})
        unhashable_kind = _pin("list-kind")
        unhashable_kind["kind"] = ["remoteSourceControl"]
        refused({"pins": [unhashable_kind], "version": 3})
        mixed_state = _pin("mixed-state")
        mixed_state["state"] = {"version": "1.0.0", "revision": 7}
        refused({"pins": [mixed_state], "version": 3})
        # A root file that is not v3 is refused the same way.
        self.root.write_text(json.dumps({"pins": [], "version": 1}))
        (self.pkg / seed_mod.RUNNER_ONLY_NAME).unlink()
        self.assertEqual(seed_mod.main(["seed", str(self.root), str(self.pkg)]), 2)
        self.assertFalse((self.pkg / "Package.resolved").exists())

    def test_tracked_alias_runner_pins_merge_cleanly_into_the_real_root_pins(self) -> None:
        # The real tracked fragment is checked against the merger's schema here.
        # compile-eval-packages.sh is the authority that proves SwiftPM accepts it.
        with tempfile.TemporaryDirectory() as scratch:
            pkg = Path(scratch) / "alias_runner"
            pkg.mkdir()
            (pkg / seed_mod.RUNNER_ONLY_NAME).write_bytes(
                (ALIAS_RUNNER / seed_mod.RUNNER_ONLY_NAME).read_bytes()
            )
            seed_mod.seed(REPO / "Package.resolved", pkg)
            identities = [p["identity"] for p in json.loads((pkg / "Package.resolved").read_text())["pins"]]
        self.assertIn("swift-transformers", identities)
        self.assertEqual(len(identities), len(set(identities)))
        manifest = (ALIAS_RUNNER / "Package.swift").read_text()
        self.assertIn('url: "https://github.com/huggingface/swift-transformers"', manifest)


EXPECTED_TESTS = 6


def _main() -> int:
    """`unittest.main()` exits 0 on ZERO discovered tests; assert the count."""
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    found = suite.countTestCases()
    if found != EXPECTED_TESTS:
        print(f"FAIL: discovered {found} tests, expected {EXPECTED_TESTS}")
        return 1
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(_main())
