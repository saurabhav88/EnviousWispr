#!/usr/bin/env python3
"""Drop package checkouts whose revision differs from Package.resolved (#4485).

WHY: when a dependency pin change also ENABLES a package trait, SwiftPM checks
the enabled trait against the checkout it already holds, at the OLD revision,
and stops before updating it:

    Trait 'X' enabled by package 'a' (A) is not declared by package 'b' (B).

Known upstream (swiftlang/swift-package-manager#9538, backport #10197). Still
reproduced on the pinned Xcode 27.1 (27A9275) on 2026-11-10 with a scratch
consumer; the self-test's real case repeats that measurement and says so when
the toolchain stops reproducing it, which is the signal to retire this file.

WHAT: for every `SourcePackages` tree it is pointed at, compare each
source-control checkout recorded in `workspace-state.json` with the pin of the
same identity in `Package.resolved`. A differing one loses its state entry and
its `checkouts/<subpath>` folder, so SwiftPM resolves it fresh. A tree whose
revisions all match is not written to at all.

ONE owner, three callers: `.github/actions/xcode-ci-setup/action.yml` (after
the cache restore, before project generation), `scripts/build-dev-only.sh` and
`scripts/xcode-test.sh` (before project generation).

REFUSES RATHER THAN GUESSES: an unreadable or unexpected state file, a linked
tree, an odd subpath or a failed removal is reported and that tree is left for
SwiftPM, exactly as before this file existed. Nothing outside
`<SourcePackages>/checkouts/<one name>` is ever deleted, and the deletion goes
through the shared physical boundary in `remove-tree.py` (#4197).

Exit: 0 every tree checked (dropped or untouched); 1 at least one tree refused
or incomplete; 2 bad invocation, or Package.resolved unreadable.

Known limits, stated rather than hidden:
- A dependency that Package.resolved no longer lists is left alone; removal of
  a dependency is not this failure class.
- The state entry is removed before the folder. If the removal is then
  refused, the folder is an orphan SwiftPM replaces on its next resolve.
- `--project-root` finds Xcode's default per-project folder by reproducing
  Xcode's folder-name hash. A wrong hash finds no folder and changes nothing.
  A custom `IDECustomDerivedDataLocation` is not followed locally.
"""

import argparse
import glob
import hashlib
import json
import os
import stat
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.realpath(__file__))
TREE_NAME = "SourcePackages"
STATE_NAME = "workspace-state.json"
CHECKOUT_STATE = "sourceControlCheckout"
# Names Xcode's default DerivedData folder is derived from, per checkout.
PROJECT_CONTAINERS = ("EnviousWispr.xcworkspace", "EnviousWispr.xcodeproj")


class Refusal(Exception):
    """This tree cannot be judged; leave it exactly as it is."""


def load_remover():
    path = os.path.join(HERE, "remove-tree.py")
    module = types.ModuleType("ew_remove_tree")
    module.__file__ = path
    with open(path, "rb") as handle:
        exec(compile(handle.read(), path, "exec"), module.__dict__)  # no import-cache writes
    return module


def read_pins(resolved_path):
    """identity -> revision for every pin that carries a revision."""
    with open(resolved_path, "rb") as handle:
        document = json.load(handle)
    pins = document.get("pins") if isinstance(document, dict) else None
    if not isinstance(pins, list):
        raise ValueError("no 'pins' list")
    result = {}
    for pin in pins:
        if not isinstance(pin, dict) or not isinstance(pin.get("identity"), str):
            raise ValueError("a pin has no identity")
        state = pin.get("state")
        revision = state.get("revision") if isinstance(state, dict) else None
        if isinstance(revision, str) and revision:
            result[pin["identity"].lower()] = revision
    return result


def xcode_default_folder_hash(container_path):
    """The suffix Xcode gives `<Name>-<suffix>` under its default DerivedData.

    md5 of the container's absolute path; each 8-byte half, read big-endian,
    is written as 14 base-26 letters. Checked against a literal pair observed
    on disk in the self-test.
    """
    digest = hashlib.md5(container_path.encode("utf-8")).digest()
    out = []
    for half in (digest[:8], digest[8:]):
        value = int.from_bytes(half, "big")
        letters = []
        for _ in range(14):
            letters.append(chr(ord("a") + value % 26))
            value //= 26
        out.append("".join(reversed(letters)))
    return "".join(out)


def trees_for_derived_data(derived_data):
    """Both shapes the hosted cache holds: flat, and one per-project level down."""
    found = [os.path.join(derived_data, TREE_NAME)]
    found.extend(sorted(glob.glob(os.path.join(glob.escape(derived_data), "*", TREE_NAME))))
    return found


def trees_for_project_root(root, xcode_root):
    found = []
    found.extend(trees_for_derived_data(os.path.join(root, ".derivedData")))
    for container in PROJECT_CONTAINERS:
        stem = os.path.splitext(container)[0]
        suffix = xcode_default_folder_hash(os.path.join(root, container))
        found.append(os.path.join(xcode_root, "{}-{}".format(stem, suffix), TREE_NAME))
    return found


def plan_tree(tree, pins):
    """Return (document, stale entries, matching count) without changing anything."""
    state_path = os.path.join(tree, STATE_NAME)
    try:
        entry = os.lstat(state_path)
    except FileNotFoundError:
        return None, [], 0
    if not stat.S_ISREG(entry.st_mode):
        raise Refusal("{} is linked or not a regular file".format(STATE_NAME))
    try:
        with open(state_path, "rb") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as error:
        raise Refusal("cannot read {}: {}".format(STATE_NAME, error))
    container = document.get("object") if isinstance(document, dict) else None
    dependencies = container.get("dependencies") if isinstance(container, dict) else None
    if not isinstance(dependencies, list):
        raise Refusal("{} has no object.dependencies list".format(STATE_NAME))
    stale, matching = [], 0
    for dependency in dependencies:
        state = dependency.get("state") if isinstance(dependency, dict) else None
        if not isinstance(state, dict) or not isinstance(state.get("name"), str):
            raise Refusal("a dependency has no state name")
        if state["name"] != CHECKOUT_STATE:
            continue  # local, edited or registry packages hold no pinned checkout
        reference = dependency.get("packageRef")
        identity = reference.get("identity") if isinstance(reference, dict) else None
        checkout = state.get("checkoutState")
        revision = checkout.get("revision") if isinstance(checkout, dict) else None
        subpath = dependency.get("subpath")
        if not all(isinstance(value, str) and value for value in (identity, revision, subpath)):
            raise Refusal("a checkout entry lacks identity, revision or subpath")
        wanted = pins.get(identity.lower())
        if wanted is None:
            continue
        if wanted == revision:
            matching += 1
            continue
        if subpath in (".", "..") or "/" in subpath or "\0" in subpath or os.sep in subpath:
            raise Refusal("checkout subpath {!r} is not a single folder name".format(subpath))
        stale.append({"entry": dependency, "identity": identity, "subpath": subpath,
                      "have": revision, "want": wanted})
    return document, stale, matching


def write_state(tree, document):
    """Replace the state file atomically; a reader sees the old or the new one."""
    handle, temporary = tempfile.mkstemp(prefix=".{}.".format(STATE_NAME), dir=tree)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, os.path.join(tree, STATE_NAME))
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def process_tree(tree, pins, remover, dry_run=False):
    """Returns the number of checkouts dropped. Raises Refusal to leave the tree."""
    if not os.path.isabs(tree) or os.path.basename(os.path.normpath(tree)) != TREE_NAME:
        raise Refusal("not an absolute path to a folder named {}".format(TREE_NAME))
    tree = os.path.normpath(tree)
    try:
        entry = os.lstat(tree)
    except FileNotFoundError:
        return 0
    if not stat.S_ISDIR(entry.st_mode):
        raise Refusal("linked or not a directory")
    document, stale, matching = plan_tree(tree, pins)
    if document is None:
        print("==> package checkouts: {}: no {}; nothing to compare".format(tree, STATE_NAME))
        return 0
    if not stale:
        print("==> package checkouts: {}: {} match Package.resolved; untouched".format(tree, matching))
        return 0
    for item in stale:
        print("==> package checkouts: {}: {} is at {} but Package.resolved pins {}{}".format(
            tree, item["identity"], item["have"][:12], item["want"][:12],
            " (dry run)" if dry_run else "; dropping it"))
    if dry_run:
        return len(stale)
    doomed = {id(item["entry"]) for item in stale}
    document["object"]["dependencies"] = [
        dependency for dependency in document["object"]["dependencies"] if id(dependency) not in doomed
    ]
    try:
        write_state(tree, document)
    except OSError as error:
        raise Refusal("could not rewrite {}: {}".format(STATE_NAME, error))
    failed = []
    for item in stale:
        target = os.path.join(tree, "checkouts", item["subpath"])
        status = remover.remove_tree(tree, target)
        if status not in (remover.REMOVED, remover.ABSENT):
            failed.append(item["subpath"])
    if failed:
        raise Refusal("state entries dropped but removal was refused for: {}".format(", ".join(failed)))
    return len(stale)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--resolved", required=True, help="the Package.resolved to compare with")
    parser.add_argument("--derived-data", action="append", default=[],
                        help="check DIR/SourcePackages and DIR/*/SourcePackages")
    parser.add_argument("--source-packages", action="append", default=[],
                        help="check exactly this SourcePackages folder")
    parser.add_argument("--project-root", help="check a checkout's .derivedData and its Xcode default folder")
    parser.add_argument("--xcode-derived-data-root",
                        default=os.path.expanduser("~/Library/Developer/Xcode/DerivedData"))
    parser.add_argument("--dry-run", action="store_true", help="report, change nothing")
    args = parser.parse_args(argv[1:])

    paths = [args.resolved, args.xcode_derived_data_root] + args.derived_data + args.source_packages
    if args.project_root:
        paths.append(args.project_root)
    for path in paths:
        if not os.path.isabs(path) or ".." in path.split(os.sep):
            print("drop-stale-package-checkouts: paths must be absolute with no '..': {!r}".format(path),
                  file=sys.stderr)
            return 2
    try:
        pins = read_pins(args.resolved)
    except (OSError, ValueError) as error:
        print("drop-stale-package-checkouts: cannot read {}: {}; nothing checked".format(args.resolved, error),
              file=sys.stderr)
        return 2

    trees = list(args.source_packages)
    for derived_data in args.derived_data:
        trees.extend(trees_for_derived_data(derived_data))
    if args.project_root:
        trees.extend(trees_for_project_root(args.project_root, args.xcode_derived_data_root))
    seen, ordered = set(), []
    for tree in trees:
        key = os.path.normpath(tree)
        if key not in seen:
            seen.add(key)
            ordered.append(tree)
    if not ordered:
        print("drop-stale-package-checkouts: no tree named; pass --derived-data, --source-packages or --project-root",
              file=sys.stderr)
        return 2

    remover = load_remover()
    refused = dropped = 0
    for tree in ordered:
        try:
            dropped += process_tree(tree, pins, remover, args.dry_run)
        except Refusal as refusal:
            refused += 1
            print("drop-stale-package-checkouts: {}: REFUSED, left as it is: {}".format(tree, refusal),
                  file=sys.stderr)
    print("==> package checkouts: {} tree(s) named, {} checkout(s) {}, {} tree(s) refused".format(
        len(ordered), dropped, "would be dropped" if args.dry_run else "dropped", refused))
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
