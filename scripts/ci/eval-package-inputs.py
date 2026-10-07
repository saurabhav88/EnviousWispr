#!/usr/bin/env python3
"""Print every repo path whose change can break the standalone eval packages (#3505).

compile-eval-packages.sh builds scripts/eval/{apple_runner,alias_runner,prompt_render},
which path-depend on products of the root package. This derives their real inputs instead
of listing them by hand, so a new dependency can never be missed:

  1. each eval package's own directory;
  2. every root target reachable from the root products those packages use (read with
     `swift package dump-package`, closed transitively over target dependencies), as the
     target's source directory;
  3. the root manifest and lockfile, and the scripts and workflow that run the compile.

Output: one path prefix per line (directories end in "/"). Exit 2 when any manifest cannot
be read; the caller treats that as "compile" (fail safe), never as "skip".

Usage: eval-package-inputs.py [repo-root]   (default: current directory)
"""
import json
import os
import subprocess
import sys

EVAL_PACKAGES = ["scripts/eval/apple_runner", "scripts/eval/alias_runner", "scripts/eval/prompt_render"]
ALWAYS = [
    "Package.swift",
    "Package.resolved",
    "scripts/ci/compile-eval-packages.sh",
    "scripts/ci/seed-eval-package-pins.py",
    "scripts/ci/eval-package-inputs.py",
    "scripts/ci/needs-eval-packages.sh",
    ".github/workflows/pr-check.yml",
    ".github/actions/",
]


def dump(path):
    out = subprocess.run(
        ["swift", "package", "dump-package", "--package-path", path],
        capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def dependency_names(dep):
    """Target and product names a dump-package dependency entry refers to."""
    for kind in ("byName", "target", "product"):
        if kind in dep and dep[kind]:
            yield kind, dep[kind][0], (dep[kind][1] if kind == "product" and len(dep[kind]) > 1 else None)


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        manifest = dump(root)
        evals = {p: dump(os.path.join(root, p)) for p in EVAL_PACKAGES}
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError) as error:
        print(f"eval-package-inputs: cannot read a manifest: {error}", file=sys.stderr)
        return 2

    targets = {t["name"]: t for t in manifest["targets"]}
    products = {p["name"]: p["targets"] for p in manifest["products"]}
    # The root package's identity as the eval packages name it ("EnviousWispr").
    root_names = {manifest["name"], os.path.basename(root)}

    wanted = set()
    for package in evals.values():
        for target in package["targets"]:
            for dep in target["dependencies"]:
                for kind, name, package_name in dependency_names(dep):
                    if kind == "product" and package_name in root_names:
                        if name not in products:
                            print(f"eval-package-inputs: unknown root product {name}", file=sys.stderr)
                            return 2
                        wanted.update(products[name])

    closure, stack = set(), list(wanted)
    while stack:
        name = stack.pop()
        if name in closure or name not in targets:
            continue
        closure.add(name)
        for dep in targets[name]["dependencies"]:
            for kind, dep_name, _ in dependency_names(dep):
                if kind in ("byName", "target") and dep_name in targets:
                    stack.append(dep_name)
    if not closure:
        print("eval-package-inputs: found no root targets; refusing an empty input set", file=sys.stderr)
        return 2

    paths = set(ALWAYS) | {p + "/" for p in EVAL_PACKAGES}
    for name in closure:
        target = targets[name]
        base = "Tests" if target.get("type") == "test" else "Sources"
        paths.add((target.get("path") or f"{base}/{name}").rstrip("/") + "/")
    print("\n".join(sorted(paths)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
