#!/usr/bin/env python3
"""Which code a Dev build's String Catalog extraction belongs to (#3524 PR 3).

The pre-push hook may judge the String Catalogs from the pushing checkout's last Dev build only
when that build was made from exactly the code being pushed. File times cannot say so; this
receipt does. It records:

  version            RECEIPT_VERSION
  configuration      the Xcode configuration built (Dev)
  xcode_build        `xcodebuild -version` build, e.g. 27A266a
  input_tree         the git tree id of the build's inputs (INPUT_PATHS below), from working bytes
  input_digest       sha256 over version, input_tree, xcode_build and configuration
  extraction_count   how many `.stringsdata` files the receipt certifies
  extraction_digest  sha256 over each certified file's path (relative to the derived data) and bytes

The certified set is exactly what `l10n-catalog-sync.sh --list-inputs` names: the catalog
script owns which targets and files count. A receipt is evidence that the build saw these inputs
before AND after it ran (equal digests either side of a successful build) and left this
extraction; it does not prove the build compiled every input, which is the build system's job.

Commands (exit 0 done, 2 could not / evidence unavailable; nothing here is a catalog verdict):
  input-digest --repo R [--commit SHA] --configuration C [--xcode-build B]
      print the receipt fields for R's working bytes, or for commit SHA's tree (no checkout).
  invalidate --receipt P
      remove P if present; a build calls this first, so a failed build leaves no receipt.
  publish --repo R --derived-data D --configuration C --before DIGEST --build-exit N --receipt P
      write P atomically when N is 0 and R's input digest still equals DIGEST.
  verify --receipt P --repo R --commit SHA --derived-data D --configuration C
      0 when P is a complete receipt for SHA's inputs under the current Xcode build and D still
      holds the extraction it certifies; otherwise 2 with the reason.
  --self-test
"""

import argparse
import hashlib
import json
import os
import pathlib
import posixpath
import re
import stat
import subprocess
import sys
import tempfile

RECEIPT_VERSION = 1
HERE = pathlib.Path(__file__).resolve().parent
CATALOG_SCRIPT = HERE / "l10n-catalog-sync.sh"

# The build inputs, as repository paths. Info.plist and the What's New source sit under Sources/
# and are named again as REQUIRED so a tree without them is refused, never fingerprinted.
# Working mode reads every physical file in these places, ignored ones included: Project.swift
# globs `Sources/<target>/**` regardless of git. `.xcconfig` files count at the repository root
# and inside DIRECTORIES; a whole-checkout walk for them measured 42-65 s on this Mac, too slow
# for a push check. Instead, a manifest (MANIFESTS, or any .swift under Tuist/) whose text
# contains "xcconfig" in any case is unsupported syntax and makes the evidence Unavailable in
# both modes, and so does a manifest that is a symlink: a referenced config elsewhere could
# change without changing the manifest. This is a text check, not a Swift parser: a name built
# from fragments that never spell "xcconfig" would pass it. None exists today (2026-10-08).
REQUIRED = ("Project.swift", "Package.swift", "Sources/EnviousWispr/Resources/Info.plist",
            "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift")
OPTIONAL_FILES = ("Tuist.swift", "Workspace.swift", "Package.resolved")
DIRECTORIES = ("Sources/", "Tuist/")
SUFFIXES = (".xcconfig",)
# Finder metadata is not a build input; excluding it avoids invalidating receipts when Finder
# writes it.
SKIP_NAMES = (".DS_Store",)
MANIFESTS = ("Project.swift", "Tuist.swift", "Workspace.swift", "Package.swift")
MAX_LINK_HOPS = 16
# Inherited variables that would point git at another repository, index or work tree.
_GIT_CONTEXT = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_COMMON_DIR", "GIT_NAMESPACE")


class Unavailable(Exception):
    """The evidence cannot be produced or does not hold; never a catalog defect."""


def is_input(path):
    if posixpath.basename(path) in SKIP_NAMES:
        return False
    return (path in REQUIRED or path in OPTIONAL_FILES or path.startswith(DIRECTORIES)
            or ("/" not in path and path.endswith(SUFFIXES)))


def _walk_error(error):
    raise Unavailable(f"cannot list {error.filename}: {error}")


def _working_entries(repo):
    """{path: (mode, kind)} for every physical input file and symlink; kind is "file" or "link".
    os.walk never follows links, so a directory link is listed as a link, not walked."""
    repo = pathlib.Path(repo)
    found = {}

    def add(rel, full):
        st = os.lstat(full)
        if stat.S_ISLNK(st.st_mode):
            found[rel] = ("120000", "link")
        elif stat.S_ISREG(st.st_mode):
            found[rel] = ("100755" if st.st_mode & 0o111 else "100644", "file")
        else:
            raise Unavailable(f"input {rel} is neither a file nor a symlink")

    for name in os.listdir(repo):
        full = repo / name
        if is_input(name) and (os.path.islink(full) or not os.path.isdir(full)):
            add(name, full)
    for top in DIRECTORIES:
        base = repo / top
        if os.path.islink(base.parent / top.rstrip("/")):
            raise Unavailable(f"{top} is a symlink")
        if not base.is_dir():
            continue
        for root, dirs, files in os.walk(base, onerror=_walk_error):
            for name in sorted(dirs):
                if os.path.islink(os.path.join(root, name)):
                    files.append(name)
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
            for name in files:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, repo).replace(os.sep, "/")
                if is_input(rel):
                    add(rel, full)
    return found


def _check_links(modes, targets):
    """Every symlink must lead, within MAX_LINK_HOPS and without leaving the repository, to a
    regular input file that is itself fingerprinted. Anything else is unavailable evidence:
    otherwise a link could carry bytes from outside the fingerprint."""
    for path, target in targets.items():
        current, link, seen = path, target, set()
        for _ in range(MAX_LINK_HOPS):
            if posixpath.isabs(link):
                raise Unavailable(f"symlink {path} points outside the repository ({link})")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(current), link))
            if resolved == ".." or resolved.startswith("../"):
                raise Unavailable(f"symlink {path} points outside the repository ({link})")
            if resolved in seen:
                raise Unavailable(f"symlink {path} is a cycle")
            seen.add(resolved)
            if resolved in targets:
                current, link = resolved, targets[resolved]
                continue
            if modes.get(resolved) in ("100644", "100755"):
                break
            raise Unavailable(f"symlink {path} leads to {resolved}, which is not a fingerprinted input file")
        else:
            raise Unavailable(f"symlink {path} has more than {MAX_LINK_HOPS} hops")


def _git(repo, *args, index=None, stdin=None):
    env = {k: v for k, v in os.environ.items() if k not in _GIT_CONTEXT}
    if index is not None:
        env["GIT_INDEX_FILE"] = str(index)
    proc = subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True, env=env)
    if proc.returncode != 0:
        raise Unavailable(f"git {' '.join(args[:3])} failed (rc={proc.returncode}): "
                          f"{proc.stderr.decode(errors='replace').strip()[:300]}")
    return proc.stdout


def _check_manifests(repo, rows):
    """Unavailable when a manifest is a symlink or its text contains "xcconfig" in any case (see
    the comment at SUFFIXES). Every manifest row is selected whatever its mode. Reads the stored
    blob in both modes, so working bytes and commits are judged by the same text."""
    manifests = sorted(p for p in rows if p in MANIFESTS or (p.startswith("Tuist/") and p.endswith(".swift")))
    linked = [p for p in manifests if rows[p][0] == "120000"]
    if linked:
        raise Unavailable(f"manifest {linked[0]} is a symlink, which this receipt does not support")
    if not manifests:
        return
    out = _git(repo, "cat-file", "--batch", stdin="".join(f"{rows[p][1]}\n" for p in manifests).encode())
    for p in manifests:
        header, _, out = out.partition(b"\n")
        size = int(header.split()[2])
        body, out = out[:size], out[size + 1:]
        if b"xcconfig" in body.lower():
            raise Unavailable(f"{p} mentions xcconfig, unsupported syntax for this receipt (a config "
                              "outside Sources/ and Tuist/ could change unseen)")


def input_tree(repo, commit=None):
    """The git tree of the input paths: the working bytes on disk (every physical file, ignored
    ones included, hashed with no git filter) when commit is None, else that commit's tree. Both
    modes apply the same membership and symlink rules. Built in a temporary index; the real index
    and anything staged in it are never touched."""
    with tempfile.TemporaryDirectory(prefix="l10n-receipt-") as tmp:
        index = pathlib.Path(tmp) / "index"
        _git(repo, "read-tree", "--empty", index=index)
        targets = {}
        if commit is None:
            entries = _working_entries(repo)
            files = sorted(p for p, (_, kind) in entries.items() if kind == "file")
            oids = _git(repo, "hash-object", "-w", "--no-filters", "--stdin-paths",
                        stdin="".join(f"{p}\n" for p in files).encode()).decode().split() if files else []
            if len(oids) != len(files):
                raise Unavailable(f"git hash-object returned {len(oids)} ids for {len(files)} files")
            rows = {p: (entries[p][0], oid) for p, oid in zip(files, oids)}
            for p, (mode, kind) in entries.items():
                if kind == "link":
                    targets[p] = os.readlink(os.path.join(repo, p))
                    oid = _git(repo, "hash-object", "-w", "--no-filters", "--stdin",
                               stdin=targets[p].encode()).decode().strip()
                    rows[p] = (mode, oid)
        else:
            listed = _git(repo, "ls-tree", "-r", "-z", "--full-tree", commit).decode().split("\0")
            rows = {}
            for line in listed:
                if not line:
                    continue
                meta, path = line.split("\t", 1)
                mode, kind, oid = meta.split()
                if not is_input(path):
                    continue
                if kind != "blob":
                    raise Unavailable(f"input {path} is a {kind} in {commit[:12]}")
                rows[path] = (mode, oid)
            links = [p for p, (mode, _) in rows.items() if mode == "120000"]
            if links:
                out = _git(repo, "cat-file", "--batch", stdin="".join(f"{rows[p][1]}\n" for p in links).encode())
                for p in links:
                    header, _, out = out.partition(b"\n")
                    size = int(header.split()[2])
                    targets[p], out = out[:size].decode(), out[size + 1:]
        modes = {p: mode for p, (mode, _) in rows.items()}
        _check_links(modes, targets)
        _check_manifests(repo, rows)
        _git(repo, "update-index", "-z", "--index-info", index=index,
             stdin="".join(f"{mode} {oid}\t{p}\0" for p, (mode, oid) in sorted(rows.items())).encode())
        paths = list(rows)
        missing = [p for p in REQUIRED if p not in paths]
        if missing:
            raise Unavailable(f"required build inputs missing: {missing}")
        if not any(p.startswith("Sources/") for p in paths):
            raise Unavailable("no files under Sources/")
        return _git(repo, "write-tree", index=index).decode().strip()


def xcode_build():
    proc = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            if line.startswith("Build version "):
                return line.split()[-1]
    raise Unavailable(f"cannot read the Xcode build: {(proc.stdout + proc.stderr).strip()[:200]}")


def input_digest(tree, xcode, configuration):
    body = json.dumps({"version": RECEIPT_VERSION, "input_tree": tree, "xcode_build": xcode,
                       "configuration": configuration}, sort_keys=True)
    return hashlib.sha256(body.encode()).hexdigest()


def extraction(derived, configuration, catalog_script=CATALOG_SCRIPT):
    """(count, digest) of the `.stringsdata` set the catalog script would read from derived."""
    proc = subprocess.run(["bash", str(catalog_script), "--list-inputs", "--derived-data", str(derived),
                           "--configuration", configuration], capture_output=True)
    if proc.returncode != 0:
        raise Unavailable(f"l10n-catalog-sync.sh --list-inputs refused (rc={proc.returncode}): "
                          f"{proc.stderr.decode(errors='replace').strip()[:300]}")
    rels = sorted(r for r in proc.stdout.decode().split("\0") if r)
    if not rels:
        raise Unavailable("the extraction set is empty")
    h = hashlib.sha256()
    for rel in rels:
        try:
            data = (pathlib.Path(derived) / rel).read_bytes()
        except OSError as error:
            raise Unavailable(f"cannot read {rel}: {error}") from error
        h.update(rel.encode() + b"\0" + hashlib.sha256(data).hexdigest().encode() + b"\n")
    return len(rels), h.hexdigest()


def fields(repo, configuration, xcode, commit=None):
    tree = input_tree(repo, commit)
    return {"version": RECEIPT_VERSION, "configuration": configuration, "xcode_build": xcode,
            "input_tree": tree, "input_digest": input_digest(tree, xcode, configuration)}


def write_atomically(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ew-l10n-receipt.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def publish(repo, derived, configuration, before, build_exit, receipt, xcode=None, catalog_script=CATALOG_SCRIPT):
    if build_exit != 0:
        raise Unavailable(f"the build exited {build_exit}; no receipt")
    xcode = xcode or xcode_build()
    after = fields(repo, configuration, xcode)
    if after["input_digest"] != before:
        raise Unavailable("the inputs changed while the build ran (digest before != after); no receipt")
    count, digest = extraction(derived, configuration, catalog_script)
    data = validate({**after, "extraction_count": count, "extraction_digest": digest})
    write_atomically(receipt, data)
    return data


KEYS = ("version", "configuration", "xcode_build", "input_tree", "input_digest",
        "extraction_count", "extraction_digest")


CONFIGURATIONS = ("Dev",)
_HEX40 = re.compile(r"[0-9a-f]{40}")
_HEX64 = re.compile(r"[0-9a-f]{64}")
_XCODE = re.compile(r"[0-9A-Za-z]+")


def _no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError(f"duplicate keys {sorted(k for k in set(keys) if keys.count(k) > 1)}")
    return dict(pairs)


def validate(data):
    """Raise Unavailable unless data is a complete, self-consistent version-1 receipt."""
    def bad(why):
        raise Unavailable(f"malformed receipt: {why}")

    if not isinstance(data, dict) or sorted(data) != sorted(KEYS):
        bad(f"keys {sorted(data) if isinstance(data, dict) else type(data).__name__}")
    for key in ("version", "extraction_count"):
        if type(data[key]) is not int:
            bad(f"{key} is {type(data[key]).__name__}, not an integer")
    if data["version"] != RECEIPT_VERSION:
        bad(f"version {data['version']} is not {RECEIPT_VERSION}")
    if data["extraction_count"] <= 0:
        bad(f"extraction_count {data['extraction_count']} is not positive")
    for key in ("configuration", "xcode_build", "input_tree", "input_digest", "extraction_digest"):
        if not isinstance(data[key], str):
            bad(f"{key} is {type(data[key]).__name__}, not a string")
    if data["configuration"] not in CONFIGURATIONS:
        bad(f"configuration {data['configuration']!r}")
    if not _XCODE.fullmatch(data["xcode_build"]):
        bad(f"xcode_build {data['xcode_build']!r}")
    if not _HEX40.fullmatch(data["input_tree"]):
        bad(f"input_tree {data['input_tree']!r}")
    for key in ("input_digest", "extraction_digest"):
        if not _HEX64.fullmatch(data[key]):
            bad(f"{key} {data[key]!r}")
    if data["input_digest"] != input_digest(data["input_tree"], data["xcode_build"], data["configuration"]):
        bad("input_digest does not match its own input_tree, xcode_build and configuration")
    return data


def read_receipt(receipt):
    try:
        data = json.loads(pathlib.Path(receipt).read_text(), object_pairs_hook=_no_duplicate_keys)
    except FileNotFoundError as error:
        raise Unavailable(f"no receipt at {receipt}: the last Dev build did not finish here") from error
    except (OSError, ValueError) as error:
        raise Unavailable(f"unreadable receipt {receipt}: {error}") from error
    return validate(data)


def verify(receipt, repo, commit, derived, configuration, xcode=None, catalog_script=CATALOG_SCRIPT):
    """verify_expected with the expected digest computed from commit's tree in repo."""
    xcode = xcode or xcode_build()
    want = fields(repo, configuration, xcode, commit)
    return verify_expected(receipt, want["input_digest"], derived, configuration, xcode, catalog_script,
                           pushed=f"{commit[:12]}, input tree {want['input_tree'][:12]}")


def verify_expected(receipt, expected, derived, configuration, xcode=None, catalog_script=CATALOG_SCRIPT,
                    pushed=None):
    """The one receipt check: schema, configuration, this Mac's Xcode build, the expected input
    digest and the extraction now on disk must all match. Anything else is Unavailable."""
    data = read_receipt(receipt)
    if data["configuration"] != configuration:
        raise Unavailable(f"the receipt is for {data['configuration']}, not {configuration}")
    xcode = xcode or xcode_build()
    if data["xcode_build"] != xcode:
        raise Unavailable(f"the receipt's Xcode build {data['xcode_build']} is not this Mac's {xcode}")
    if data["input_digest"] != expected:
        raise Unavailable(f"the Dev build is not of the pushed code ({pushed or 'input digest ' + expected[:12]}): "
                          f"input tree {data['input_tree'][:12]} built")
    count, digest = extraction(derived, configuration, catalog_script)
    if (count, digest) != (data["extraction_count"], data["extraction_digest"]):
        raise Unavailable("the extraction changed since the receipt was written")
    return data


# ---------------------------------------------------------------------------
# Self-test: real git repositories and a stub catalog script that lists fixture `.stringsdata`.
# Expected tree ids come from `git mktree`/`git hash-object` on the fixture bytes, never from
# input_tree() itself.
# ---------------------------------------------------------------------------

_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def _run(repo, *args, stdin=None):
    env = {**{k: v for k, v in os.environ.items() if not k.startswith("GIT_")}, **_ENV}
    return subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
                          cwd=repo, input=stdin, check=True, capture_output=True, text=True, env=env).stdout.strip()


FIXTURE = {
    "Project.swift": "let project = 1\n",
    "Package.swift": "let package = 1\n",
    "Package.resolved": "{}\n",
    "Sources/EnviousWispr/Resources/Info.plist": "<plist/>\n",
    "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift": "let whatsNew = 1\n",
    "Sources/EnviousWisprCore/A.swift": "let a = 1\n",
    "README.md": "not an input\n",
}


def _make_repo(root, name):
    repo = root / name
    repo.mkdir()
    _run(repo, "init", "-q", "-b", "main")
    for rel, text in FIXTURE.items():
        p = repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    _run(repo, "add", "-A")
    _run(repo, "commit", "-q", "-m", "fixture")
    return repo


def _expected_tree(repo, files, links=()):
    """An independent oracle: build the tree with hash-object + mktree, level by level."""
    def blob(text):
        return _run(repo, "hash-object", "-w", "--stdin", stdin=text)

    def build(prefix_items):
        entries = []
        dirs = {}
        for rel, (mode, text) in prefix_items.items():
            head, _, rest = rel.partition("/")
            if rest:
                dirs.setdefault(head, {})[rest] = (mode, text)
            else:
                entries.append(f"{mode} blob {blob(text)}\t{head}")
        for d, items in dirs.items():
            entries.append(f"040000 tree {build(items)}\t{d}")
        return _run(repo, "mktree", stdin="\n".join(entries) + "\n")

    items = {rel: ("100644", text) for rel, text in files.items()}
    for rel, target in links:
        items[rel] = ("120000", target)
    return build(items)


def _stub_catalog(root, listing_file):
    stub = root / "stub-catalog.sh"
    stub.write_text("#!/usr/bin/env bash\n"
                    f'if [ -f "{listing_file}.refuse" ]; then echo "REFUSED: stub" >&2; exit 2; fi\n'
                    f'tr "\\n" "\\0" < "{listing_file}"\n')
    return stub


def self_test():
    with tempfile.TemporaryDirectory(prefix="l10n-receipt-selftest-") as tmp:
        return _self_test(pathlib.Path(tmp).resolve())


def _self_test(root):
    fails = cases = 0

    def expect(label, got, want):
        nonlocal fails, cases
        cases += 1
        if got == want:
            print(f"ok   [{label}]")
        else:
            fails += 1
            print(f"FAIL [{label}] expected {want!r}, got {got!r}")

    def refused(label, fn, needle):
        nonlocal fails, cases
        cases += 1
        try:
            fn()
            fails += 1
            print(f"FAIL [{label}] expected Unavailable, got a result")
        except Unavailable as error:
            if needle in str(error):
                print(f"ok   [{label}]")
            else:
                fails += 1
                print(f"FAIL [{label}] Unavailable without {needle!r}: {error}")

    inputs = {k: v for k, v in FIXTURE.items() if k != "README.md"}
    a = _make_repo(root, "a")
    b = _make_repo(root, "elsewhere-b")
    expect("1 the input tree equals an independent mktree oracle", input_tree(a), _expected_tree(a, inputs))
    expect("2 identical bytes in two checkouts at different paths give one tree", input_tree(a), input_tree(b))
    base_tree = input_tree(a)
    (a / "README.md").write_text("changed, not an input\n")
    expect("3 a non-input change leaves the tree alone", input_tree(a), base_tree)

    (a / "Sources/EnviousWisprCore/A.swift").write_text("let a = 2\n")
    expect("4 a source edit changes the tree", input_tree(a) != base_tree, True)
    (a / "Sources/EnviousWisprCore/A.swift").write_text(FIXTURE["Sources/EnviousWisprCore/A.swift"])
    expect("4b reverting the edit restores the tree", input_tree(a), base_tree)

    (a / "Sources/EnviousWisprCore/New.swift").write_text("let n = 1\n")
    added = input_tree(a)
    expect("5 an untracked source file is an input", added, _expected_tree(a, {**inputs, "Sources/EnviousWisprCore/New.swift": "let n = 1\n"}))
    (a / "Sources/EnviousWisprCore/New.swift").unlink()
    (a / "Sources/EnviousWisprCore/A.swift").unlink()
    without = {k: v for k, v in inputs.items() if k != "Sources/EnviousWisprCore/A.swift"}
    expect("6 a deleted tracked source leaves the tree", input_tree(a), _expected_tree(a, without))
    (a / "Sources/EnviousWisprCore/A.swift").write_text(FIXTURE["Sources/EnviousWisprCore/A.swift"])

    (a / "Sources/EnviousWisprCore/A.swift").rename(a / "Sources/EnviousWisprCore/B.swift")
    renamed = {**without, "Sources/EnviousWisprCore/B.swift": FIXTURE["Sources/EnviousWisprCore/A.swift"]}
    expect("7 a rename changes the tree to the renamed layout", input_tree(a), _expected_tree(a, renamed))
    (a / "Sources/EnviousWisprCore/B.swift").rename(a / "Sources/EnviousWisprCore/A.swift")

    core = a / "Sources/EnviousWisprCore"
    os.symlink("A.swift", core / "Link.swift")
    linked = input_tree(a)
    expect("8 an internal symlink is recorded as a link beside its target's bytes", linked,
           _expected_tree(a, inputs, links=[("Sources/EnviousWisprCore/Link.swift", "A.swift")]))
    (core / "A.swift").write_text("let a = through the link\n")
    expect("8b editing the link's target changes the tree", input_tree(a) != linked, True)
    (core / "A.swift").write_text(FIXTURE["Sources/EnviousWisprCore/A.swift"])
    os.symlink("Link.swift", core / "Chain.swift")
    chained = input_tree(a)
    expect("8c a chain of internal links to an input file is accepted", chained,
           _expected_tree(a, inputs, links=[("Sources/EnviousWisprCore/Link.swift", "A.swift"),
                                            ("Sources/EnviousWisprCore/Chain.swift", "Link.swift")]))
    _run(a, "add", "-A")
    _run(a, "commit", "-q", "-m", "links")
    expect("8d commit mode reads the same links to the same tree", input_tree(a, _run(a, "rev-parse", "HEAD")), chained)
    _run(a, "reset", "-q", "--hard", "HEAD~1")
    for name, target, needle in (("Readme.swift", "../../README.md", "not a fingerprinted input"),
                                 ("Out.swift", "../../../outside.swift", "outside the repository"),
                                 ("Abs.swift", "/etc/hosts", "outside the repository"),
                                 ("Dangling.swift", "Missing.swift", "not a fingerprinted input"),
                                 ("Loop.swift", "Loop.swift", "cycle")):
        os.symlink(target, core / name)
        refused(f"8e a link to {needle.split()[-1]} ({name} -> {target}) is unavailable", lambda: input_tree(a), needle)
        (core / name).unlink()
    os.symlink("../EnviousWisprCore", a / "Sources/EnviousWispr/DirLink")
    refused("8f a directory symlink is unavailable", lambda: input_tree(a), "not a fingerprinted input")
    (a / "Sources/EnviousWispr/DirLink").unlink()
    expect("precondition: links removed, back to the base tree", input_tree(a), base_tree)

    for rel, label in (("Package.resolved", "9 the package lock"), ("Project.swift", "9b the project manifest")):
        (a / rel).write_text("changed\n")
        expect(f"{label} changes the tree", input_tree(a) != base_tree, True)
        (a / rel).write_text(FIXTURE[rel])
    (a / "Dev.xcconfig").write_text("A = 1\n")
    expect("9c a root .xcconfig is an input", input_tree(a) != base_tree, True)
    (a / "Dev.xcconfig").unlink()
    (a / "Configs").mkdir()
    (a / "Configs/Dev.xcconfig").write_text("A = 1\n")
    expect("9d an unreferenced .xcconfig outside the walked places changes nothing", input_tree(a), base_tree)
    # Already referenced, then only the config changes: refused in both modes, every time.
    (a / "Project.swift").write_text('let project = 1 // settings: .settings(configurations: [.debug(name: "Dev", xcconfig: "Configs/Dev.xcconfig")])\n')
    _run(a, "add", "-A")
    _run(a, "commit", "-q", "-m", "reference an xcconfig")
    referenced = _run(a, "rev-parse", "HEAD")
    refused("9h a manifest referencing an .xcconfig is unavailable (working bytes)", lambda: input_tree(a), "mentions xcconfig")
    refused("9i ... and for the commit", lambda: input_tree(a, referenced), "mentions xcconfig")
    (a / "Configs/Dev.xcconfig").write_text("A = 2\n")
    refused("9j editing only the referenced config stays unavailable", lambda: input_tree(a), "mentions xcconfig")
    (a / "Tuist").mkdir()
    (a / "Tuist/Helpers.swift").write_text('let c = "Base.XCConfig"\n')
    (a / "Project.swift").write_text(FIXTURE["Project.swift"])
    refused("9k a Tuist/ helper mentioning one (any case) is unavailable", lambda: input_tree(a), "Tuist/Helpers.swift mentions xcconfig")
    (a / "Tuist/Helpers.swift").unlink()
    (a / "Tuist").rmdir()
    _run(a, "reset", "-q", "--hard", "HEAD~1")
    for leftover in (a / "Configs/Dev.xcconfig", a / "Configs"):
        if leftover.is_dir():
            leftover.rmdir()
        elif leftover.exists():
            leftover.unlink()
    expect("9l back to the supported tree, which still fingerprints", input_tree(a), base_tree)

    # The same guard against an assembled name and against linked manifests, in both modes.
    def both_modes(label, needle, prepare):
        prepare()
        _run(a, "add", "-A")
        _run(a, "commit", "-q", "-m", label)
        refused(f"{label} (working bytes)", lambda: input_tree(a), needle)
        refused(f"{label} (commit)", lambda: input_tree(a, _run(a, "rev-parse", "HEAD")), needle)
        _run(a, "reset", "-q", "--hard", "HEAD~1")
        _run(a, "clean", "-q", "-fdx", "--", "Sources", "Tuist")
        if (a / "Tuist").exists():
            (a / "Tuist").rmdir()

    both_modes("9m an assembled name (\"Configs/Dev\" + \".\" + \"xcconfig\") is unavailable", "mentions xcconfig",
               lambda: (a / "Project.swift").write_text('let c = "Configs/Dev" + "." + "xcconfig"\n'))

    def link_project():
        (a / "Sources/EnviousWisprCore/RealProject.swift").write_text("let project = 1\n")
        (a / "Project.swift").unlink()
        os.symlink("Sources/EnviousWisprCore/RealProject.swift", a / "Project.swift")
    both_modes("9n a symlinked Project.swift is unavailable", "manifest Project.swift is a symlink", link_project)

    def link_helper():
        (a / "Tuist").mkdir()
        (a / "Tuist/Real.swift").write_text("let helper = 1\n")
        os.symlink("Real.swift", a / "Tuist/Helper.swift")
    both_modes("9o a symlinked Tuist/ helper is unavailable", "manifest Tuist/Helper.swift is a symlink", link_helper)
    expect("9p back to the supported tree after the manifest cases", input_tree(a), base_tree)

    (a / ".gitignore").write_text("*.gen.swift\n")
    (a / "Sources/EnviousWisprCore/X.gen.swift").write_text("let generated = 1\n")
    expect("9e an IGNORED file under Sources/ is an input",
           input_tree(a), _expected_tree(a, {**inputs, "Sources/EnviousWisprCore/X.gen.swift": "let generated = 1\n"}))
    (a / "Sources/EnviousWisprCore/X.gen.swift").unlink()
    (a / ".gitignore").unlink()
    (a / "Sources/EnviousWisprCore/.DS_Store").write_text("finder\n")
    expect("9f Finder's .DS_Store is not an input", input_tree(a), base_tree)
    (a / "Sources/EnviousWisprCore/.DS_Store").unlink()

    # A clean filter that upper-cases .swift would make these two working files hash alike if
    # git's filters were applied; the fingerprint is the bytes on disk.
    (a / ".gitattributes").write_text("*.swift filter=upper\n")
    _run(a, "config", "filter.upper.clean", "tr a-z A-Z")
    (a / "Sources/EnviousWisprCore/A.swift").write_text("let a = 1\n")
    lower = input_tree(a)
    (a / "Sources/EnviousWisprCore/A.swift").write_text("LET A = 1\n")
    upper = input_tree(a)
    expect("9g a clean filter cannot collapse distinct working bytes",
           (lower != upper, lower), (True, _expected_tree(a, inputs)))
    (a / "Sources/EnviousWisprCore/A.swift").write_text(FIXTURE["Sources/EnviousWisprCore/A.swift"])
    (a / ".gitattributes").unlink()
    _run(a, "config", "--unset", "filter.upper.clean")
    (a / "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift").write_text("let whatsNew = 2\n")
    expect("10 the What's New seed source changes the tree", input_tree(a) != base_tree, True)
    (a / "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift").write_text(FIXTURE["Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift"])
    (a / "Sources/EnviousWispr/Resources/Info.plist").write_text("<plist>changed</plist>\n")
    expect("10b the Info.plist seed source changes the tree", input_tree(a) != base_tree, True)
    (a / "Sources/EnviousWispr/Resources/Info.plist").write_text(FIXTURE["Sources/EnviousWispr/Resources/Info.plist"])
    expect("precondition: back to the base tree", input_tree(a), base_tree)

    (a / "Project.swift").unlink()
    refused("11 a missing required input is refused, not fingerprinted", lambda: input_tree(a), "required build inputs missing")
    (a / "Project.swift").write_text(FIXTURE["Project.swift"])
    (a / "Sources/EnviousWisprCore/A.swift").chmod(0)
    refused("11b an unreadable input is refused", lambda: input_tree(a), "could not open")
    (a / "Sources/EnviousWisprCore/A.swift").chmod(0o644)

    (a / "Sources/EnviousWisprCore/A.swift").write_text("let a = staged\n")
    _run(a, "add", "Sources/EnviousWisprCore/A.swift")
    (a / "Sources/EnviousWisprCore/A.swift").write_text("let a = working\n")
    index_before = (a / ".git/index").read_bytes()
    staged_before = _run(a, "diff", "--cached", "--name-only")
    input_tree(a)
    expect("12 the real index is untouched (bytes and staged set)",
           ((a / ".git/index").read_bytes() == index_before, _run(a, "diff", "--cached", "--name-only")),
           (True, staged_before))
    _run(a, "reset", "-q", "--hard")

    commit = _run(a, "rev-parse", "HEAD")
    expect("13 a commit's tree equals the same working bytes' tree", input_tree(a, commit), input_tree(a))
    # Inherited variables that point at ANOTHER repository and index (as inside a git hook) must
    # not decide which bytes are read: b's copy of a shared source differs from a's.
    (b / "Sources/EnviousWisprCore/A.swift").write_text("let a = only in b\n")
    _run(b, "add", "-A")
    foreign = {"GIT_DIR": str(b / ".git"), "GIT_WORK_TREE": str(b), "GIT_INDEX_FILE": str(b / ".git/index")}
    os.environ.update(foreign)
    try:
        got = (input_tree(a), input_tree(a, commit))
    finally:
        for key in foreign:
            os.environ.pop(key)
    expect("13b inherited GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE for another repo are ignored", got, (base_tree, base_tree))

    derived = root / "derived"
    files = {"Build/x/A.stringsdata": b"one", "Build/x/B.stringsdata": b"two"}
    for rel, data in files.items():
        (derived / rel).parent.mkdir(parents=True, exist_ok=True)
        (derived / rel).write_bytes(data)
    listing = root / "listing.txt"
    listing.write_text("\n".join(files) + "\n")
    stub = _stub_catalog(root, listing)
    oracle = hashlib.sha256()
    for rel in sorted(files):
        oracle.update(rel.encode() + b"\0" + hashlib.sha256(files[rel]).hexdigest().encode() + b"\n")
    expect("14 the extraction digest covers exactly the listed files and bytes",
           extraction(derived, "Dev", stub), (2, oracle.hexdigest()))
    (derived / "Build/x/B.stringsdata").write_bytes(b"TWO")
    expect("14b a changed .stringsdata changes the extraction digest", extraction(derived, "Dev", stub)[1] != oracle.hexdigest(), True)
    (derived / "Build/x/B.stringsdata").write_bytes(b"two")
    listing.write_text("Build/x/A.stringsdata\n")
    expect("14c a smaller listed set changes the extraction digest", extraction(derived, "Dev", stub)[0], 1)
    listing.write_text("")
    refused("14d an empty extraction set is refused", lambda: extraction(derived, "Dev", stub), "empty")
    listing.write_text("\n".join(files) + "\n")
    (pathlib.Path(str(listing) + ".refuse")).write_text("")
    refused("14e the catalog script's refusal is unavailable evidence", lambda: extraction(derived, "Dev", stub), "--list-inputs refused")
    (pathlib.Path(str(listing) + ".refuse")).unlink()

    receipt = root / "dd" / "ew-l10n-receipt.json"
    before = fields(a, "Dev", "27A266a")["input_digest"]
    data = publish(a, derived, "Dev", before, 0, receipt, xcode="27A266a", catalog_script=stub)
    on_disk = json.loads(receipt.read_text())
    expect("15 a successful build publishes a complete receipt",
           (on_disk, sorted(on_disk)), ({"version": 1, "configuration": "Dev", "xcode_build": "27A266a",
                                         "input_tree": base_tree,
                                         "input_digest": input_digest(base_tree, "27A266a", "Dev"),
                                         "extraction_count": 2, "extraction_digest": oracle.hexdigest()}, sorted(KEYS)))
    expect("15b the receipt verifies for the commit it was built from",
           verify(receipt, a, commit, derived, "Dev", xcode="27A266a", catalog_script=stub)["input_tree"], base_tree)

    receipt.unlink()
    refused("16 a failed build publishes nothing",
            lambda: publish(a, derived, "Dev", before, 65, receipt, xcode="27A266a", catalog_script=stub), "exited 65")
    expect("16b ... and no receipt file exists", receipt.exists(), False)
    (a / "Sources/EnviousWisprCore/A.swift").write_text("let a = edited during the build\n")
    refused("17 inputs changed during the build publish nothing",
            lambda: publish(a, derived, "Dev", before, 0, receipt, xcode="27A266a", catalog_script=stub), "changed while the build ran")
    expect("17b ... and no receipt file exists", receipt.exists(), False)
    (a / "Sources/EnviousWisprCore/A.swift").write_text(FIXTURE["Sources/EnviousWisprCore/A.swift"])

    publish(a, derived, "Dev", before, 0, receipt, xcode="27A266a", catalog_script=stub)
    _run(a, "commit", "-q", "--allow-empty", "-m", "empty")
    (a / "Sources/EnviousWisprCore/A.swift").write_text("let a = 3\n")
    _run(a, "commit", "-q", "-am", "pushed change")
    pushed = _run(a, "rev-parse", "HEAD")
    refused("18 a receipt for other code is unavailable for the pushed commit",
            lambda: verify(receipt, a, pushed, derived, "Dev", xcode="27A266a", catalog_script=stub), "not of the pushed code")
    refused("18b another Xcode build is unavailable",
            lambda: verify(receipt, a, commit, derived, "Dev", xcode="27B000x", catalog_script=stub), "Xcode build")
    (derived / "Build/x/A.stringsdata").write_bytes(b"rebuilt")
    refused("18c an extraction changed after the receipt is unavailable",
            lambda: verify(receipt, a, commit, derived, "Dev", xcode="27A266a", catalog_script=stub), "extraction changed")
    good = json.loads(json.dumps(data))
    for label, change in (("version true", {"version": True}), ("version 2", {"version": 2}),
                          ("input_tree null", {"input_tree": None}), ("input_tree short", {"input_tree": "abc"}),
                          ("count 2.0", {"extraction_count": 2.0}), ("count true", {"extraction_count": True}),
                          ("count 0", {"extraction_count": 0}), ("configuration Release", {"configuration": "Release"}),
                          ("empty xcode build", {"xcode_build": ""}), ("digest uppercase", {"extraction_digest": oracle.hexdigest().upper()}),
                          ("input_digest of another tree", {"input_tree": "0" * 40}), ("missing key", {"extraction_digest": None, "_drop": True})):
        bad = {**good, **{k: v for k, v in change.items() if k != "_drop"}}
        if change.get("_drop"):
            bad.pop("extraction_digest")
        receipt.write_text(json.dumps(bad))
        refused(f"19 a malformed receipt ({label}) is unavailable", lambda: read_receipt(receipt), "malformed")
    receipt.write_text(json.dumps(good)[:-1] + ', "version": 1}')
    refused("19a a receipt with a duplicate key is unavailable", lambda: read_receipt(receipt), "duplicate")
    receipt.write_text(json.dumps(good))
    expect("19z the untouched receipt still reads", read_receipt(receipt)["input_tree"], base_tree)
    receipt.write_text("not json")
    refused("19b an unreadable receipt is unavailable", lambda: read_receipt(receipt), "unreadable")
    receipt.unlink()
    refused("19c a missing receipt is unavailable", lambda: read_receipt(receipt), "no receipt")

    leftovers = [p.name for p in receipt.parent.iterdir() if p.name.startswith(".ew-l10n-receipt.")]
    expect("20 no temporary receipt file is left behind", leftovers, [])
    print(f"self-test: {cases} cases, {fails} failure(s)")
    return 1 if fails or not cases else 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="l10n-build-receipt.py")
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("input-digest")
    p.add_argument("--repo", type=pathlib.Path, required=True)
    p.add_argument("--commit")
    p.add_argument("--configuration", required=True)
    p.add_argument("--xcode-build")
    p = sub.add_parser("invalidate")
    p.add_argument("--receipt", type=pathlib.Path, required=True)
    p = sub.add_parser("publish")
    p.add_argument("--repo", type=pathlib.Path, required=True)
    p.add_argument("--derived-data", type=pathlib.Path, required=True)
    p.add_argument("--configuration", required=True)
    p.add_argument("--before", required=True)
    p.add_argument("--build-exit", type=int, required=True)
    p.add_argument("--receipt", type=pathlib.Path, required=True)
    p = sub.add_parser("verify")
    p.add_argument("--receipt", type=pathlib.Path, required=True)
    p.add_argument("--repo", type=pathlib.Path)
    p.add_argument("--commit")
    p.add_argument("--expect-inputs", help="the expected input_digest, instead of --repo/--commit")
    p.add_argument("--derived-data", type=pathlib.Path, required=True)
    p.add_argument("--configuration", required=True)
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    try:
        if args.command == "input-digest":
            print(json.dumps(fields(args.repo, args.configuration, args.xcode_build or xcode_build(), args.commit),
                             sort_keys=True))
        elif args.command == "invalidate":
            try:
                args.receipt.unlink()
            except FileNotFoundError:
                pass
        elif args.command == "publish":
            data = publish(args.repo, args.derived_data, args.configuration, args.before, args.build_exit, args.receipt)
            print(f"receipt: {args.receipt} ({data['extraction_count']} .stringsdata, inputs {data['input_tree'][:12]})")
        elif args.command == "verify":
            if bool(args.expect_inputs) == bool(args.repo and args.commit):
                parser.error("verify needs either --expect-inputs or both --repo and --commit")
            if args.expect_inputs:
                data = verify_expected(args.receipt, args.expect_inputs, args.derived_data, args.configuration)
                what = f"input digest {args.expect_inputs[:12]}"
            else:
                data = verify(args.receipt, args.repo, args.commit, args.derived_data, args.configuration)
                what = args.commit[:12]
            print(f"receipt ok: the Dev build is of {what} ({data['extraction_count']} .stringsdata)")
        else:
            parser.error("a command or --self-test is required")
    except (Unavailable, OSError) as error:
        print(f"UNAVAILABLE: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
