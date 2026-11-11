#!/usr/bin/env python3
"""Self-test for drop-stale-package-checkouts.py (#4485).

Portable cases build small state trees by hand and stub the removal boundary,
so they run on the Linux fast-check runner. `--real` (macOS with a Swift
toolchain) builds a throwaway local package with two commits, the second of
which declares a trait, and drives the real `swift package resolve` and the
real `xcodebuild -resolvePackageDependencies` (the hosted lane's resolver):

  control   a consumer moved to the second commit WITH the trait enabled fails
            to resolve on its retained checkout (the upstream defect);
  negative  a tree whose revisions match is not written to;
  positive  after the helper runs, the same resolve succeeds at the new commit.

If the control stops failing, the toolchain carries the upstream fix: the run
says so and still passes, and this helper can be retired.

Usage: drop-stale-package-checkouts-test.py [--portable | --real]
       (no flag: portable, plus real when the platform allows it)
"""

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest

HERE = Path(__file__).resolve().parent
HELPER_PATH = HERE / "drop-stale-package-checkouts.py"
OLD, NEW, OTHER = "a" * 40, "b" * 40, "c" * 40


def load(path, name):
    module = types.ModuleType(name)
    module.__file__ = str(path)
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)  # no import-cache writes
    return module


H = load(HELPER_PATH, "drop_stale")


class StubRemover:
    """Stands in for remove-tree.py where its macOS floor is unavailable."""
    REMOVED, REFUSED, INVALID, ABSENT = 0, 1, 2, 3

    def __init__(self, status=0):
        self.status, self.calls = status, []

    def remove_tree(self, root, target, expected_identity=None):
        self.calls.append((root, target))
        if self.status == self.REMOVED:
            shutil.rmtree(target)
        return self.status


def checkout_entry(identity, revision, subpath=None):
    return {"basedOn": None,
            "packageRef": {"identity": identity, "kind": "remoteSourceControl",
                           "location": "https://example.invalid/" + identity, "name": identity},
            "state": {"checkoutState": {"revision": revision}, "name": "sourceControlCheckout"},
            "subpath": subpath if subpath is not None else identity}


def make_tree(base, entries, name="SourcePackages"):
    tree = Path(base) / name
    (tree / "checkouts").mkdir(parents=True)
    for entry in entries:
        folder = tree / "checkouts" / entry["subpath"]
        if "/" not in entry["subpath"] and entry["subpath"] not in (".", ".."):
            folder.mkdir(exist_ok=True)
            (folder / "Package.swift").write_text("// fixture\n")
    state = {"object": {"artifacts": [{"keep": "me"}], "dependencies": entries, "prebuilts": []},
             "version": 7}
    (tree / "workspace-state.json").write_text(json.dumps(state))
    return tree


def run(tree, pins, remover=None, dry_run=False):
    remover = remover or StubRemover()
    with contextlib.redirect_stdout(io.StringIO()):
        return H.process_tree(str(tree), pins, remover, dry_run), remover


class PortableTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="ew-drop-stale-")
        self.addCleanup(shutil.rmtree, self.base, True)

    def test_matching_tree_is_not_written(self):
        tree = make_tree(self.base, [checkout_entry("one", OLD), checkout_entry("two", OTHER)])
        state = tree / "workspace-state.json"
        before = (state.read_bytes(), state.stat().st_ino, state.stat().st_mtime_ns)
        dropped, remover = run(tree, {"one": OLD, "two": OTHER})
        self.assertEqual(dropped, 0)
        self.assertEqual(remover.calls, [])
        self.assertEqual(before, (state.read_bytes(), state.stat().st_ino, state.stat().st_mtime_ns))
        self.assertTrue((tree / "checkouts" / "one" / "Package.swift").exists())

    def test_stale_checkout_loses_entry_and_folder_and_nothing_else(self):
        tree = make_tree(self.base, [checkout_entry("one", OLD, "One"), checkout_entry("two", OTHER)])
        dropped, remover = run(tree, {"one": NEW, "two": OTHER})
        self.assertEqual(dropped, 1)
        self.assertEqual(remover.calls, [(str(tree), str(tree / "checkouts" / "One"))])
        self.assertFalse((tree / "checkouts" / "One").exists())
        self.assertTrue((tree / "checkouts" / "two" / "Package.swift").exists())
        state = json.loads((tree / "workspace-state.json").read_text())
        self.assertEqual([d["packageRef"]["identity"] for d in state["object"]["dependencies"]], ["two"])
        self.assertEqual(state["object"]["artifacts"], [{"keep": "me"}])
        self.assertEqual(state["version"], 7)
        self.assertEqual(sorted(p.name for p in tree.iterdir()), ["checkouts", "workspace-state.json"])

    def test_identity_compare_ignores_case(self):
        tree = make_tree(self.base, [checkout_entry("FluidAudio", OLD)])
        self.assertEqual(run(tree, {"fluidaudio": OLD})[0], 0)

    def test_dry_run_changes_nothing(self):
        tree = make_tree(self.base, [checkout_entry("one", OLD)])
        before = (tree / "workspace-state.json").read_bytes()
        dropped, remover = run(tree, {"one": NEW}, dry_run=True)
        self.assertEqual((dropped, remover.calls), (1, []))
        self.assertEqual(before, (tree / "workspace-state.json").read_bytes())

    def test_unpinned_and_non_checkout_entries_are_left(self):
        local = checkout_entry("local", OLD)
        local["state"] = {"name": "fileSystem", "path": "/somewhere"}
        tree = make_tree(self.base, [checkout_entry("gone", OLD), local])
        self.assertEqual(run(tree, {"local": NEW})[0], 0)

    def test_absent_tree_and_absent_state_are_nothing_to_do(self):
        self.assertEqual(run(Path(self.base) / "SourcePackages", {"one": NEW})[0], 0)
        tree = make_tree(self.base, [checkout_entry("one", OLD)])
        (tree / "workspace-state.json").unlink()
        dropped, remover = run(tree, {"one": NEW})
        self.assertEqual((dropped, remover.calls), (0, []))
        self.assertTrue((tree / "checkouts" / "one").exists())

    def assert_refused_untouched(self, tree, pins, remover=None):
        state = Path(tree) / "workspace-state.json"
        before = state.read_bytes() if state.is_file() else None
        with self.assertRaises(H.Refusal):
            run(tree, pins, remover)
        if before is not None:
            self.assertEqual(before, state.read_bytes())

    def test_refuses_unreadable_or_unexpected_state(self):
        for index, text in enumerate(("{not json", "[]", '{"object": {}}',
                                      '{"object": {"dependencies": [{"state": {}}]}}',
                                      json.dumps({"object": {"dependencies": [
                                          {"state": {"name": "sourceControlCheckout"}, "subpath": "x"}]}}))):
            tree = make_tree(Path(self.base) / str(index), [checkout_entry("one", OLD)])
            (tree / "workspace-state.json").write_text(text)
            self.assert_refused_untouched(tree, {"one": NEW})
            self.assertTrue((tree / "checkouts" / "one").exists())

    def test_refuses_a_subpath_that_could_leave_checkouts(self):
        for index, subpath in enumerate(("..", ".", "a/b", "../../etc")):
            tree = make_tree(Path(self.base) / str(index), [checkout_entry("one", OLD, subpath)])
            remover = StubRemover()
            self.assert_refused_untouched(tree, {"one": NEW}, remover)
            self.assertEqual(remover.calls, [])

    def test_refuses_wrong_name_relative_and_linked_trees(self):
        wrong = make_tree(self.base, [checkout_entry("one", OLD)], name="NotPackages")
        self.assert_refused_untouched(wrong, {"one": NEW})
        with self.assertRaises(H.Refusal):
            run("SourcePackages", {"one": NEW})
        link_home = Path(self.base) / "linked"
        link_home.mkdir()
        os.symlink(wrong, link_home / "SourcePackages")
        with self.assertRaises(H.Refusal):
            run(link_home / "SourcePackages", {"one": NEW})
        self.assertTrue((wrong / "checkouts" / "one").exists())

    def test_refused_removal_is_reported_not_credited(self):
        tree = make_tree(self.base, [checkout_entry("one", OLD)])
        with self.assertRaises(H.Refusal):
            run(tree, {"one": NEW}, StubRemover(status=1))

    def test_derived_data_expands_to_flat_and_per_project_trees_only(self):
        dd = Path(self.base) / "dd"
        for sub in ("SourcePackages", "Proj-abc/SourcePackages", "a/b/SourcePackages", "Proj-abc/Other"):
            (dd / sub).mkdir(parents=True)
        self.assertEqual(H.trees_for_derived_data(str(dd)),
                         [str(dd / "SourcePackages"), str(dd / "Proj-abc" / "SourcePackages")])

    def test_xcode_default_folder_hash_matches_a_folder_observed_on_disk(self):
        # Literal pair read off ~/Library/Developer/Xcode/DerivedData on 2026-11-10.
        self.assertEqual(
            H.xcode_default_folder_hash("/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/EnviousWispr.xcworkspace"),
            "fhimjqwfwhraqtdkjzcblllcmvrw")
        self.assertEqual(
            H.xcode_default_folder_hash("/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/EnviousWispr.xcodeproj"),
            "cnwiyqfpmzbwnhepizogsixwnixl")

    def test_project_root_names_local_and_xcode_default_trees(self):
        trees = H.trees_for_project_root("/r", "/x")
        self.assertEqual(trees[0], "/r/.derivedData/SourcePackages")
        self.assertEqual([t for t in trees if t.startswith("/x/")],
                         ["/x/EnviousWispr-{}/SourcePackages".format(H.xcode_default_folder_hash("/r/" + c))
                          for c in H.PROJECT_CONTAINERS])

    def cli(self, *args):
        return subprocess.run([sys.executable, str(HELPER_PATH), *args], capture_output=True, text=True)

    def test_cli_exit_codes(self):
        tree = make_tree(self.base, [checkout_entry("one", OLD)])
        resolved = Path(self.base) / "Package.resolved"
        resolved.write_text(json.dumps({"pins": [{"identity": "one", "state": {"revision": OLD}}]}))
        self.assertEqual(self.cli("--resolved", str(resolved), "--source-packages", str(tree)).returncode, 0)
        self.assertEqual(self.cli("--resolved", str(resolved)).returncode, 2)
        self.assertEqual(self.cli("--resolved", "relative", "--source-packages", str(tree)).returncode, 2)
        (tree / "workspace-state.json").write_text("{broken")
        refused = self.cli("--resolved", str(resolved), "--source-packages", str(tree))
        self.assertEqual(refused.returncode, 1)
        self.assertIn("REFUSED", refused.stderr)
        resolved.write_text("{broken")
        self.assertEqual(self.cli("--resolved", str(resolved), "--source-packages", str(tree)).returncode, 2)
        self.assertTrue((tree / "checkouts" / "one").exists())


DEP_MANIFEST = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "Dep",
  products: [.library(name: "Dep", targets: ["Dep"])],%s
  targets: [.target(name: "Dep")]
)
"""
CONSUMER_MANIFEST = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "Consumer",
  dependencies: [.package(url: "%s", revision: "%s", traits: [%s])],
  targets: [.target(name: "Consumer", dependencies: [.product(name: "Dep", package: "Dep")])]
)
"""


class RealSwiftPMTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(os.path.realpath(tempfile.mkdtemp(prefix="ew-drop-stale-real-")))
        self.addCleanup(shutil.rmtree, self.base, True)

    def git(self, *args):
        done = subprocess.run(["git", "-C", str(self.base / "Dep"), "-c", "user.name=fixture",
                               "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", *args],
                              capture_output=True, text=True, check=True)
        return done.stdout.strip()

    def commit_dep(self, traits_line, message):
        (self.base / "Dep" / "Package.swift").write_text(DEP_MANIFEST % traits_line)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def resolve(self):
        if self.resolver == "swiftpm":
            command = ["swift", "package", "--scratch-path", str(self.tree), "resolve"]
        else:
            # The resolver the hosted lane and `tuist generate` use. The two overrides
            # pin Xcode's NORMAL resolution for this one call: a Mac left in the
            # offline mode of xcode-build-tooling.md FACT: offline-build-on-bad-wifi
            # applies pins directly and does not show the defect.
            command = ["xcodebuild", "-resolvePackageDependencies", "-list",
                       "-clonedSourcePackagesDirPath", str(self.tree),
                       "-packageCachePath", str(self.base / "package-cache"),
                       "-IDEDisableAutomaticPackageResolution=NO",
                       "-IDEPackageOnlyUseVersionsFromResolvedFile=NO"]
        return subprocess.run(command, cwd=self.base / "Consumer", capture_output=True, text=True)

    def recorded_revision(self):
        state = json.loads((self.tree / "workspace-state.json").read_text())
        found = [d["state"]["checkoutState"]["revision"] for d in state["object"]["dependencies"]
                 if d["packageRef"]["identity"] == "dep"]
        return found[0] if found else None

    def helper(self):
        return subprocess.run([sys.executable, str(HELPER_PATH), "--resolved",
                               str(self.base / "Consumer" / "Package.resolved"),
                               "--source-packages", str(self.tree)], capture_output=True, text=True)

    def test_swiftpm_resolves_a_trait_adding_pin_change_after_the_drop(self):
        self.check_trait_adding_pin_change("swiftpm")

    def test_xcodebuild_resolves_a_trait_adding_pin_change_after_the_drop(self):
        self.check_trait_adding_pin_change("xcodebuild")

    def check_trait_adding_pin_change(self, resolver):
        self.resolver = resolver
        dep, consumer = self.base / "Dep", self.base / "Consumer"
        (dep / "Sources" / "Dep").mkdir(parents=True)
        (dep / "Sources" / "Dep" / "Dep.swift").write_text("public let dep = 1\n")
        (consumer / "Sources" / "Consumer").mkdir(parents=True)
        (consumer / "Sources" / "Consumer" / "Consumer.swift").write_text("import Dep\n")
        subprocess.run(["git", "init", "-q", str(dep)], check=True, capture_output=True)
        # The old commit must declare SOME trait: SwiftPM refuses `traits: []` on a
        # package that declares none. This mirrors the real case (#4483), where the
        # old pin declared one trait and the new pin added the one being enabled.
        old = self.commit_dep('\n  traits: ["Base"],', "one trait")
        new = self.commit_dep('\n  traits: ["Base", "Extra"],', "declare the Extra trait")
        self.tree = self.base / "SourcePackages"
        manifest, url = consumer / "Package.swift", dep.as_uri()

        manifest.write_text(CONSUMER_MANIFEST % (url, old, ""))
        first = self.resolve()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.recorded_revision(), old)

        # Negative: revisions match, so nothing may be written.
        state = self.tree / "workspace-state.json"
        checkout = self.tree / "checkouts" / "Dep"
        before = (state.read_bytes(), state.stat().st_ino, checkout.stat().st_ino)
        untouched = self.helper()
        self.assertEqual(untouched.returncode, 0, untouched.stderr)
        self.assertIn("untouched", untouched.stdout)
        self.assertEqual(before, (state.read_bytes(), state.stat().st_ino, checkout.stat().st_ino))

        # The pin change that also enables a trait, as a `git checkout` delivers it.
        manifest.write_text(CONSUMER_MANIFEST % (url, new, '"Extra"'))
        resolved = consumer / "Package.resolved"
        text = resolved.read_text()
        self.assertEqual(text.count(old), 1)
        resolved.write_text(text.replace(old, new))

        control = self.resolve()
        if control.returncode == 0:
            print("\nNOTICE (" + resolver + "): this toolchain resolved the trait-adding pin change on a retained checkout; "
                  "the upstream SwiftPM fix has landed and drop-stale-package-checkouts.py can be retired (#4485).")
            self.assertEqual(self.recorded_revision(), new)
            return
        self.assertIn("is not declared by package", control.stdout + control.stderr)
        self.assertEqual(self.recorded_revision(), old)
        print("\ncontrol ({}): the retained checkout reproduced the defect".format(resolver))

        dropped = self.helper()
        self.assertEqual(dropped.returncode, 0, dropped.stdout + dropped.stderr)
        self.assertIn("dropping it", dropped.stdout)
        self.assertFalse(checkout.exists())
        self.assertIsNone(self.recorded_revision())

        healed = self.resolve()
        self.assertEqual(healed.returncode, 0, healed.stdout + healed.stderr)
        self.assertEqual(self.recorded_revision(), new)
        self.assertEqual(subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"],
                                        capture_output=True, text=True).stdout.strip(), new)


def main():
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--portable", action="store_true")
    selection.add_argument("--real", action="store_true")
    args = parser.parse_args()
    can_run_real = sys.platform == "darwin" and shutil.which("swift") and shutil.which("git")
    if args.real and not can_run_real:
        print("drop-stale-package-checkouts-test: --real needs macOS with swift and git", file=sys.stderr)
        return 2
    cases = []
    if not args.real:
        cases.append(PortableTests)
    if args.real or (not args.portable and can_run_real):
        cases.append(RealSwiftPMTests)
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case) for case in cases)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful() or result.testsRun == 0:
        return 1
    print("drop-stale-package-checkouts-test: {} test(s) passed ({})".format(
        result.testsRun, " + ".join(case.__name__ for case in cases)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
