#!/usr/bin/env python3
"""scripts/ci/check-ci-drift.py — the three CI-file drift checks (#3729).

These ran weekly in .github/workflows/ci-drift-check.yml (Mondays, schedule
only), so a floating action ref or a deleted script could sit on main for up to
a week before anything said so, and the founder ruled out timed runs
(2026-10-13). They now run as fast-checks members (scripts/ci/fast-checks.sh):
in the required build-check job and in the local pre-push hook.

  pins     every external `uses:` (workflow steps, reusable-workflow jobs,
           composite-action steps) is pinned to a full 40-hex commit SHA. A tag
           can be moved to new code after review; a SHA cannot.
  scripts  every `scripts/....sh` a CI definition names in a value (a `run:`
           body, a `paths:` entry, an input) exists. deploy-blog runs with
           `working-directory: website`, so `website/<ref>` also counts.
           Comments are not values: a YAML comment naming a retired script is
           history, not a reference.
  yaml     real `yamllint` over every file, with the drift workflow's config.

Which files: scripts/ci/check-cache-paths.py::discover(root), the one CI
definition enumeration (workflows *.yml/*.yaml and action manifests at any
depth under .github/actions/). It is loaded from this script's own folder, so
both come from the same checkout. #1994: the drift job once scanned only
.github/workflows/* and a composite action moved CI logic out of coverage; an
empty list, or an actions folder that contributes no manifest, is a failure
here, never a vacuous pass.

Usage:
  check-ci-drift.py --list [--tree DIR]
  check-ci-drift.py --check pins|scripts|yaml [--tree DIR]
  check-ci-drift.py --self-test

--tree defaults to the current directory. Exit 0 clean; 1 a finding or a
failure to read, parse or enumerate (always named); 2 a usage error.
"""
import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("check-ci-drift: PyYAML is required (python3 -m pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
YAMLLINT_CONFIG = ("{extends: default, rules: {line-length: disable, truthy: disable, "
                   "document-start: disable, comments: disable, brackets: disable, "
                   "comments-indentation: disable}}")
PINNED = re.compile(r"@[0-9a-f]{40}$")
SCRIPT_REF = re.compile(r"(?:\./)?(scripts/[A-Za-z0-9_./-]+\.sh)")


class DriftError(Exception):
    pass


def load_discover():
    path = os.path.join(HERE, "check-cache-paths.py")
    spec = importlib.util.spec_from_file_location("ew_check_cache_paths", path)
    if spec is None or spec.loader is None:
        raise DriftError(f"cannot load the CI file enumeration from {path}")
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except (OSError, SyntaxError) as e:
        raise DriftError(f"cannot load the CI file enumeration from {path}: {e}")
    return mod.discover


def population(tree):
    files = load_discover()(tree)
    if not files:
        raise DriftError(f"no CI definition files under {tree}; the drift scan would pass vacuously")
    if os.path.isdir(os.path.join(tree, ".github/actions")) and not any(
            f.startswith(".github/actions/") for f in files):
        raise DriftError(".github/actions exists but contributed no action manifest; the scan glob is wrong")
    return files


def load(tree, rel):
    try:
        with open(os.path.join(tree, rel)) as fh:
            doc = yaml.safe_load(fh)
    except OSError as e:
        raise DriftError(f"{rel}: cannot be read: {e}")
    except yaml.YAMLError as e:
        raise DriftError(f"{rel}: cannot be parsed as YAML: {str(e).splitlines()[0]}")
    if not isinstance(doc, dict):
        raise DriftError(f"{rel}: is not a YAML mapping")
    return doc


def uses_refs(doc):
    """Every `uses:` value: job steps, reusable-workflow jobs, composite steps."""
    refs = []
    for job in (doc.get("jobs") or {}).values():
        job = job or {}
        if "uses" in job:
            refs.append(str(job["uses"]))
        refs += [str(st["uses"]) for st in (job.get("steps") or []) if isinstance(st, dict) and "uses" in st]
    runs = doc.get("runs") or {}
    if isinstance(runs, dict):
        refs += [str(st["uses"]) for st in (runs.get("steps") or []) if isinstance(st, dict) and "uses" in st]
    return refs


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from strings(k)
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)


def check_pins(tree, files):
    bad, seen = [], 0
    for rel in files:
        for ref in uses_refs(load(tree, rel)):
            if ref.startswith("./"):
                continue  # a local action or workflow, read from the checkout itself
            seen += 1
            if not PINNED.search(ref):
                bad.append(f"{rel}: floating action ref {ref!r}; pin it to a full commit SHA")
    print(f"==> pins: {seen} external action ref(s) in {len(files)} file(s)")
    return bad


def check_scripts(tree, files):
    bad, refs = [], set()
    for rel in files:
        for text in strings(load(tree, rel)):
            for ref in SCRIPT_REF.findall(text):
                refs.add((rel, ref))
    for rel, ref in sorted(refs):
        if os.path.isfile(os.path.join(tree, ref)):
            print(f"  OK  {ref}")
        elif os.path.isfile(os.path.join(tree, "website", ref)):
            # deploy-blog runs this path with working-directory: website. Limit, kept
            # from ci-drift-check.yml: the fallback does not read the step's working
            # directory, so a root-relative call to a website-only script passes here
            # and fails when the step runs.
            print(f"  OK  website/{ref}")
        else:
            bad.append(f"{rel}: referenced script {ref} does not exist")
    print(f"==> scripts: {len(refs)} reference(s) in {len(files)} file(s)")
    return bad


def check_yaml(tree, files):
    exe = shutil.which("yamllint")
    if exe is None:
        raise DriftError("yamllint is not installed")
    for rel in files:
        if not os.path.isfile(os.path.join(tree, rel)):
            raise DriftError(f"{rel}: listed but missing")
    p = subprocess.run([exe, "-d", YAMLLINT_CONFIG, *files], cwd=tree, capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    print(f"==> yaml: yamllint exit {p.returncode} over {len(files)} file(s)")
    return [] if p.returncode == 0 else [f"yamllint reported problems (exit {p.returncode})"]


CHECKS = {"pins": check_pins, "scripts": check_scripts, "yaml": check_yaml}


def run(mode, tree):
    try:
        files = population(tree)
        if mode == "list":
            print(f"==> {len(files)} CI definition file(s):")
            for f in files:
                print(f"    {f}")
            return 0
        bad = CHECKS[mode](tree, files)
    except DriftError as e:
        print(f"::error title=ci-drift::{e}")
        return 1
    for msg in bad:
        print(f"::error title=ci-drift {mode}::{msg}")
    return 1 if bad else 0


# ---------------------------------------------------------------------------
# Self-test: drives this file's real entrypoint, as a new process, against
# fixture trees. Expected answers are literals, never read from the subject.
# ---------------------------------------------------------------------------
def self_test():
    import tempfile
    import textwrap
    passed = failed = 0
    pinned = "actions/checkout@" + "d23441a48e516b6c34aea4fa41551a30e30af803"

    def tree_with(base, files):
        root = os.path.join(base, f"t{len(os.listdir(base))}")
        os.makedirs(root)
        for rel, body in files.items():
            p = os.path.join(root, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as fh:
                fh.write(textwrap.dedent(body).lstrip("\n"))
        return root

    def entry(*args):
        p = subprocess.run([sys.executable, os.path.abspath(__file__), *args], capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr

    def expect(label, got_rc, want_rc, out, saying=None):
        nonlocal passed, failed
        if got_rc == want_rc and (saying is None or saying in out):
            print(f"ok   [{label}] rc={got_rc}")
            passed += 1
        else:
            print(f"FAIL [{label}] wanted rc={want_rc} saying {saying!r}, got rc={got_rc}:\n{out}")
            failed += 1

    wf = lambda uses, run="echo hi": f"""
        jobs:
          a:
            runs-on: ubuntu-latest
            steps:
              - uses: {uses}
              - run: {run}
        """
    action = lambda uses: f"""
        name: x
        runs:
          using: composite
          steps:
            - uses: {uses}
        """
    with tempfile.TemporaryDirectory() as base:
        # discovery: known population against a literal answer, decoys left out
        t = tree_with(base, {
            ".github/workflows/a.yml": wf(pinned),
            ".github/workflows/b.yaml": wf(pinned),
            ".github/actions/top/action.yml": action(pinned),
            ".github/actions/deep/er/action.yaml": action(pinned),
            ".github/actions/top/README.yml": "{}\n",
            ".github/workflows/nested/c.yml": "{}\n",
        })
        rc, out = entry("--list", "--tree", t)
        listed = [ln.strip() for ln in out.splitlines() if ln.startswith("    ")]
        want = [".github/actions/deep/er/action.yaml", ".github/actions/top/action.yml",
                ".github/workflows/a.yml", ".github/workflows/b.yaml"]
        expect("list: workflows .yml/.yaml and nested action manifests, no decoys",
               0 if (rc == 0 and listed == want) else 1, 0, out)
        rc, out = entry("--check", "pins", "--tree", t)
        expect("pins: pinned workflow and composite refs pass", rc, 0, out, "4 external action ref(s) in 4 file(s)")

        # empty scope, and an actions folder that contributes nothing
        t = tree_with(base, {"README.md": "x\n"})
        rc, out = entry("--check", "pins", "--tree", t)
        expect("empty scope fails loudly", rc, 1, out, "pass vacuously")
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned), ".github/actions/top/README.md": "x\n"})
        rc, out = entry("--check", "scripts", "--tree", t)
        expect("an actions folder with no manifest fails", rc, 1, out, "contributed no action manifest")

        # pins
        t = tree_with(base, {".github/workflows/a.yml": wf("actions/checkout@v4")})
        rc, out = entry("--check", "pins", "--tree", t)
        expect("pins: a floating workflow ref fails and is named", rc, 1, out, "'actions/checkout@v4'")
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned),
                             ".github/actions/top/action.yml": action("actions/cache/restore@v5")})
        rc, out = entry("--check", "pins", "--tree", t)
        expect("pins: a floating composite-action ref fails", rc, 1, out, ".github/actions/top/action.yml")
        t = tree_with(base, {".github/workflows/a.yml": "# - uses: actions/checkout@v4\n" + textwrap.dedent(wf(pinned)).lstrip("\n")})
        rc, out = entry("--check", "pins", "--tree", t)
        expect("pins: a floating ref in a comment is not a ref", rc, 0, out)
        t = tree_with(base, {".github/workflows/a.yml": """
            jobs:
              r:
                uses: someorg/shared/.github/workflows/build.yml@main
            """})
        rc, out = entry("--check", "pins", "--tree", t)
        expect("pins: a floating reusable-workflow job ref fails", rc, 1, out, "@main")

        # scripts
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned, "bash scripts/ci/here.sh"),
                             "scripts/ci/here.sh": "true\n"})
        rc, out = entry("--check", "scripts", "--tree", t)
        expect("scripts: an existing script passes", rc, 0, out, "OK  scripts/ci/here.sh")
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned, "./scripts/ci/gone.sh")})
        rc, out = entry("--check", "scripts", "--tree", t)
        expect("scripts: a missing script fails and is named", rc, 1, out, "referenced script scripts/ci/gone.sh does not exist")
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned, "bash scripts/deploy-blog.sh"),
                             "website/scripts/deploy-blog.sh": "true\n"})
        rc, out = entry("--check", "scripts", "--tree", t)
        expect("scripts: a script found only under website/ passes (working directory not read)", rc, 0, out, "OK  website/scripts/deploy-blog.sh")
        t = tree_with(base, {".github/workflows/a.yml": "# was: scripts/ci/retired.sh\n" + textwrap.dedent(wf(pinned)).lstrip("\n")})
        rc, out = entry("--check", "scripts", "--tree", t)
        expect("scripts: a missing script named only in a comment is history", rc, 0, out, "0 reference(s)")
        t = tree_with(base, {".github/workflows/a.yml": """
            on:
              pull_request:
                paths:
                  - 'scripts/ci/gone.sh'
            jobs: {}
            """})
        rc, out = entry("--check", "scripts", "--tree", t)
        expect("scripts: a paths-filter entry is a value and is checked", rc, 1, out, "scripts/ci/gone.sh does not exist")

        # yaml, with the real linter
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned)})
        rc, out = entry("--check", "yaml", "--tree", t)
        expect("yaml: a clean file passes the real yamllint", rc, 0, out, "yamllint exit 0 over 1 file(s)")
        t = tree_with(base, {".github/workflows/a.yml": "jobs:\n  a: 1\n  a: 2\n"})
        rc, out = entry("--check", "yaml", "--tree", t)
        expect("yaml: a duplicate key fails the real yamllint", rc, 1, out, "yamllint reported problems")

        # unreadable and unparsable input are named failures
        t = tree_with(base, {".github/workflows/a.yml": "jobs:\n  a: [unterminated\n"})
        rc, out = entry("--check", "pins", "--tree", t)
        expect("a file that does not parse is a named failure", rc, 1, out, "a.yml: cannot be parsed as YAML")
        t = tree_with(base, {".github/workflows/a.yml": wf(pinned)})
        os.chmod(os.path.join(t, ".github/workflows/a.yml"), 0)
        rc, out = entry("--check", "scripts", "--tree", t)
        os.chmod(os.path.join(t, ".github/workflows/a.yml"), 0o644)
        if os.geteuid() == 0:
            print("ok   [an unreadable file is a named failure] (root reads everything; not exercised)")
        else:
            expect("an unreadable file is a named failure", rc, 1, out, "a.yml: cannot be read")

    print(f"check-ci-drift self-test: executed={passed + failed} passed={passed} failed={failed}")
    return 0 if failed == 0 and passed > 0 else 1


def main():
    ap = argparse.ArgumentParser(add_help=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--list", action="store_true")
    g.add_argument("--check", choices=sorted(CHECKS))
    g.add_argument("--self-test", action="store_true")
    ap.add_argument("--tree", default=os.getcwd())
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not os.path.isdir(a.tree):
        print(f"check-ci-drift: no such tree: {a.tree}", file=sys.stderr)
        return 2
    return run("list" if a.list else a.check, a.tree)


if __name__ == "__main__":
    sys.exit(main())
