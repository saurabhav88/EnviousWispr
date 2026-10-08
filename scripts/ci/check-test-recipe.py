#!/usr/bin/env python3
"""A change that adds more than a floor of test lines must name how those tests are bound (#2868).

testing-philosophy.md RULE: write-the-test-by-day-run-the-battery-by-night states the ship
condition: a test ships with a `test-hardening` issue carrying its recipe, or with one of the two
substitutes the same rule names. Measured 2026-09-13: 8 of the 18 PRs merged since 2026-09-10 with
more than 100 added lines under `Tests/` carried none of the three. Nothing checked.

Usage (the `recipe-check` job in pr-check.yml, and the pre-push hook, #3524):
    check-test-recipe.py --trailers --base <sha> --head <sha> [--repo <dir>] [--checkout <dir>]
    check-test-recipe.py --self-test

The declaration is a `Recipe:` commit trailer, read from the first-parent commits in base..head, so
the Mac can check it before a push and no PR body is needed (#3524). The NEWEST commit that carries
a `Recipe` trailer decides, and it must carry exactly one value; older declarations are superseded.
A correction is a new commit, never a history rewrite:

    git commit --allow-empty --trailer "Recipe: #N" -m "test: name recipe #N"

The value takes one of three shapes:

    Recipe: #<N>                      an issue labelled test-hardening whose recipe VALIDATES
                                      against --checkout, the tree that lands: the PR merged with
                                      its base in CI, the prospective merge in the hook
                                      (scripts/validate-mutation-recipe.py)
    Recipe: parent-red <TestName>     the bug-fix route: the named test ran RED on the parent
                                      commit for the bug's reason (declared; no Xcode here)
    Recipe: resource-control <Test>   the non-Swift-subject route (#2693, #2749): a two-way
                                      control on the resource, in the change (declared)

--repo is where history and GitHub questions run (git log, git diff, gh); --checkout is the tree
whose files the validator reads. They differ in the hook, where the tree is a throwaway snapshot.

Exit codes: 0 the range satisfies the condition (or is under the floor); 1 it does not, with the
reason printed; 3 the check could not run (a gh or git failure), which is not a verdict.
"""

import argparse
import contextlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import traceback

# The floor is the measurement in #2868: every PR in its table added more than this. Below it a
# bounded wait, a renamed helper or a settle fix (#2857, #2860) ships without ceremony, and the
# rule's daytime route for a small bug-fix test is the parent-red proof the reviewer reads.
FLOOR = 100
LABEL = "test-hardening"
ISSUE_SHAPE = re.compile(r"^#(\d+)$")
DECLARED_SHAPE = re.compile(r"^(parent-red|resource-control)\s+(\S.*)$")
SHAPES = (
    "Recipe: #<N>  (an issue labelled test-hardening whose recipe validates against this change)",
    "Recipe: parent-red <TestName>  (the new test ran RED on the parent commit for the bug's reason)",
    "Recipe: resource-control <TestName>  (a two-way control on a non-Swift resource, in this change)",
)
REPAIR = ('Add the declaration as a new commit (never rewrite history):\n'
          '  git commit --allow-empty --trailer "Recipe: #N" -m "test: name recipe #N"\n'
          'An ordinary rebase keeps commit trailers; a squash or fixup can drop them, so a trailer '
          'that went missing after a history rewrite needs this new commit.')
# One git log record per first-parent commit: SHA, the trailer values, then the same trailers with
# their keys. The keyed form is what tells an EMPTY `Recipe:` (keyed "Recipe: ", value "") from no
# trailer at all (both empty). `unfold` joins a continuation line into its value.
_LOG_FORMAT = ("%H%x00%(trailers:key=Recipe,valueonly,unfold,separator=%x1f)"
               "%x00%(trailers:key=Recipe,unfold,separator=%x1f)%x1e")

VALIDATOR = pathlib.Path(__file__).resolve().parent.parent / "validate-mutation-recipe.py"


class Infrastructure(Exception):
    """The check could not ask its question; the answer is unknown, not 'no'."""


def run(argv, cwd):
    proc = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def added_test_lines(repo, base, head):
    """Lines ADDED under Tests/ between base and head, three-dot (what the change introduces).

    `--numstat` prints `-` for a binary file; that counts as zero, since no recipe can bind a
    binary. `-M` pins rename detection ON whatever `diff.renames` says on the machine, so a moved
    test file adds nothing and the count does not depend on configuration. A diff that cannot
    resolve is a refusal to answer, never a zero: a zero would pass the change on the count with
    nothing measured.
    """
    rc, out = run(["git", "diff", "--numstat", "-M", f"{base}...{head}", "--", "Tests/"], cwd=repo)
    if rc != 0:
        raise Infrastructure(f"git diff --numstat {base}...{head} failed (rc={rc}): {out.strip()[:300]}")
    total = 0
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        if parts[0].isdigit():
            total += int(parts[0])
    return total


def recipe_trailers(repo, base, head):
    """The newest first-parent commit in base..head that carries a `Recipe` trailer.

    Returns (sha, values) with one entry per trailer, an empty string for an empty one, or None
    when no commit in the range carries one. Only git's own trailer block counts: `Recipe:` text in
    an earlier paragraph of a message is prose, not a declaration.
    """
    # trailer.separators is pinned to git's default ":" so a workstation setting cannot hide a
    # trailer that CI, on default settings, would see.
    rc = subprocess.run(["git", "-c", "trailer.separators=:", "log", "--first-parent",
                         f"--format={_LOG_FORMAT}", f"{base}..{head}"],
                        cwd=repo, capture_output=True, text=True)
    if rc.returncode != 0:
        raise Infrastructure(f"git log {base}..{head} failed (rc={rc.returncode}): "
                             f"{(rc.stdout + rc.stderr).strip()[:300]}")
    for record in rc.stdout.split("\x1e"):
        record = record.lstrip("\n")
        if not record:
            continue
        fields = record.split("\x00")
        if len(fields) != 3:
            raise Infrastructure(f"git log printed a record this check cannot read: {record[:200]!r}")
        sha, values, keyed = fields
        if not keyed:
            continue
        found = values.split("\x1f")
        if len(found) != len(keyed.split("\x1f")):
            raise Infrastructure(f"git log trailer fields disagree for {sha}: {values!r} vs {keyed!r}")
        return sha, [value.strip() for value in found]
    return None


def issue_labels(number, repo):
    rc, out = run(
        ["gh", "issue", "view", str(number), "--json", "labels", "--jq", ".labels[].name"],
        cwd=repo,
    )
    if rc != 0:
        raise Infrastructure(f"could not read issue #{number}: {out.strip()[:300]}")
    return [name for name in out.splitlines() if name]


def validate_recipe(number, repo, checkout):
    """The validator's exit code is the verdict; its output is the reason, quoted whole."""
    rc, out = run([sys.executable, str(VALIDATOR), "--issue", str(number),
                   "--repo", str(repo), "--checkout", str(checkout)], cwd=repo)
    # The validator's own read failure is exit 2 like a malformed recipe (mutation-battery.py
    # `could not read issue`); that one is nobody's recipe to fix. Same classification as
    # test-hardening-recipe.yml.
    if rc != 0 and "could not read issue" in out:
        raise Infrastructure(out.strip())
    return rc, out


def check(repo, checkout, base, head, *, labels=issue_labels, validate=validate_recipe):
    """Returns (exit code, message). Keyword seams exist for --self-test only; callers pass none."""
    added = added_test_lines(repo, base, head)
    if added <= FLOOR:
        return 0, f"ok: {added} lines added under Tests/, at or under the {FLOOR}-line floor; no Recipe trailer required"

    need = (f"{added} lines added under Tests/ is over the {FLOOR}-line floor, so a commit in "
            f"{base[:12]}..{head[:12]} must carry a `Recipe:` trailer in one of these shapes:\n  "
            + "\n  ".join(SHAPES) + "\n" + REPAIR)
    found = recipe_trailers(repo, base, head)
    if found is None:
        return 1, f"FAIL: no commit in the range carries a `Recipe:` trailer.\n{need}"
    sha, values = found
    where = f"commit {sha[:12]}"
    if len(values) != 1:
        listed = "\n  ".join(f"Recipe: {v}" for v in values)
        return 1, f"FAIL: {where}, the newest with a `Recipe` trailer, carries {len(values)} of them:\n  {listed}\n{need}"

    value = values[0]
    if not value:
        return 1, f"FAIL: {where} carries an empty `Recipe:` trailer.\n{need}"
    issue = ISSUE_SHAPE.match(value)
    if issue:
        number = int(issue.group(1))
        if LABEL not in labels(number, repo):
            return 1, f"FAIL: `Recipe: #{number}` in {where} names an issue without the `{LABEL}` label.\n{need}"
        rc, out = validate(number, repo, checkout)
        if rc != 0:
            return 1, (f"FAIL: `Recipe: #{number}` in {where} does not validate against the tree that lands "
                       f"(validate-mutation-recipe.py exit {rc}):\n{out.rstrip()}\n"
                       f"Every row must be runnable in the tree that is about to merge; a row that "
                       f"anchors on code this change does not carry is dead on the night it is run.")
        return 0, (f"ok: {added} lines added under Tests/; `Recipe: #{number}` in {where} validates against "
                   f"the tree that lands:\n{out.rstrip()}")

    declared = DECLARED_SHAPE.match(value)
    if declared:
        route, subject = declared.groups()
        return 0, (f"ok: {added} lines added under Tests/; {where} declares route `{route}` for `{subject}`. "
                   f"This check runs no Xcode, so the declaration is what the review gate reads.")

    return 1, f"FAIL: `Recipe: {value}` in {where} is not one of the accepted shapes.\n{need}"


# ---------------------------------------------------------------------------
# Self-test: real git repos and real commits for the count and the trailers; a fake `gh` on PATH
# for the GitHub boundary. The issue half is proven against real issues on GitHub (#2868's kill
# criterion), never stubbed here beyond the seams and the fake.
# ---------------------------------------------------------------------------

# Fixtures ignore the machine's git configuration (signing, hooks, rename settings, trailer
# settings) so the self-test measures the script and not the workstation. self_test() also sets
# the two config variables in its own environment, so the git calls inside check() are isolated.
_GIT_ENV = {**{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def _git(repo, *args):
    subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
                   cwd=repo, check=True, capture_output=True, text=True, env=_GIT_ENV)


def _sha(repo, rev="HEAD"):
    return subprocess.check_output(["git", "rev-parse", rev], cwd=repo, text=True, env=_GIT_ENV).strip()


def _repo_with_test_lines(scratch, lines, path="Tests/Probe/Probe.swift", message=("tests",)):
    repo = pathlib.Path(tempfile.mkdtemp(prefix="recipe-check-", dir=scratch))
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "commit", "-q", "--allow-empty", "-m", "base")
    base = _sha(repo)
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(f"// line {i}\n" for i in range(lines)))
    _git(repo, "add", "-A")
    args = []
    for paragraph in message:
        args += ["-m", paragraph]
    _git(repo, "commit", "-q", *args)
    return repo, base, _sha(repo)


def _commit(repo, *paragraphs, trailer=None):
    args = ["commit", "-q", "--allow-empty"]
    if trailer:
        args += ["--trailer", trailer]
    for paragraph in paragraphs:
        args += ["-m", paragraph]
    _git(repo, *args)
    return _sha(repo)


# A recipe row the real validator accepts, and a landing tree large enough for its oracle floors
# (100 test files, 100 KB, 1,000 suite-scoped names in validate-mutation-recipe.py test_oracle).
_ROW = {
    "label": "a representative mutation",
    "file": "Sources/Thing.swift",
    "anchor": "let guarded = true",
    "replacement": "let guarded = false",
    "suite": "EnviousWisprTests/ThingTests",
    "expect_fail": "the guard holds",
}


def _landing_tree(scratch):
    tree = scratch / "landing-snapshot"
    tests = tree / "Tests" / "EnviousWisprTests"
    tests.mkdir(parents=True)
    (tree / "Sources").mkdir()
    (tree / "Sources" / "Thing.swift").write_text(_ROW["anchor"] + "\n")
    (tree / "scripts").mkdir()
    entry = tree / "scripts" / "xcode-test.sh"
    entry.write_text("#!/usr/bin/env bash\nexit 0\n")
    entry.chmod(0o755)
    (tests / "ThingTests.swift").write_text(
        'import Testing\n@Suite struct ThingTests {\n    @Test("the guard holds") func guardHolds() {}\n}\n')
    for i in range(100):
        cases = "".join(f'    @Test("filler {i} case {j}") func case{j}() {{}}\n' for j in range(11))
        (tests / f"Filler{i}Tests.swift").write_text(
            "import Testing\n" + "// padding for the oracle size floor\n" * 30
            + f"@Suite struct Filler{i}Tests {{\n{cases}}}\n")
    return tree


def _cli(*argv):
    """main() as the hook and CI call it: (exit code, everything printed). A raised exception is
    reported as the code so a traceback can never pass for a verdict."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = main(list(argv))
        except BaseException as error:  # noqa: BLE001 - the case asserts there is none
            code = f"raised {type(error).__name__}"
            traceback.print_exc(file=out)
    return code, out.getvalue()


def self_test():
    saved = {k: os.environ.get(k) for k in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "PATH")}
    os.environ["GIT_CONFIG_GLOBAL"] = "/dev/null"
    os.environ["GIT_CONFIG_SYSTEM"] = "/dev/null"
    try:
        with tempfile.TemporaryDirectory(prefix="recipe-check-selftest-") as scratch:
            return _self_test(pathlib.Path(scratch))
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _self_test(scratch):
    fails = 0
    cases = 0

    def expect(label, got, want):
        nonlocal fails, cases
        cases += 1
        if got == want:
            print(f"ok   [{label}]")
        else:
            fails += 1
            print(f"FAIL [{label}] expected {want!r}, got {got!r}")

    labelled = lambda n, r: [LABEL] if n == 7 else ["task"]
    calls = []

    def validator(rc, text):
        def fake(n, r, c):
            calls.append((n, r, c))
            return rc, text
        return fake

    tree = scratch / "landing-tree"
    tree.mkdir()

    def run_check(repo, base, head, rc=0, text="#7: 1/1 rows runnable", labels=labelled):
        return check(repo, tree, base, head, labels=labels, validate=validator(rc, text))

    # 1-2. The floor.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR)
    code, _ = run_check(repo, base, head)
    expect("at the floor: no trailer needed", code, 0)
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    code, msg = run_check(repo, base, head)
    expect("over the floor, no trailer: fails with the repair command",
           (code, "no commit in the range" in msg, 'git commit --allow-empty --trailer "Recipe: #N"' in msg),
           (1, True, True))

    # 3. Body-only text is prose, not a trailer.
    repo, base, head = _repo_with_test_lines(
        scratch, FLOOR + 1, message=("tests", "Recipe: #7 is described here", "Signed-off-by: t <t@t>"))
    code, msg = run_check(repo, base, head)
    expect("Recipe text in a body paragraph: not a declaration", (code, "no commit in the range" in msg), (1, True))

    # 4-6. The three valid shapes, each naming the selected commit.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    calls.clear()
    sha = _commit(repo, "test: name recipe #7", trailer="Recipe: #7")
    code, msg = run_check(repo, base, sha)
    expect("issue shape, labelled, validator passes: ok naming the commit and forwarding repo and tree",
           (code, sha[:12] in msg, "1/1 rows runnable" in msg, calls), (0, True, True, [(7, repo, tree)]))
    sha = _commit(repo, "test: parent-red", trailer="Recipe: parent-red FooTests/barFails")
    code, msg = run_check(repo, base, sha)
    expect("parent-red shape: ok", (code, "parent-red" in msg, sha[:12] in msg), (0, True, True))
    sha = _commit(repo, "test: control", trailer="Recipe: resource-control ManifestTests")
    code, msg = run_check(repo, base, sha)
    expect("resource-control shape: ok", (code, "resource-control" in msg), (0, True))

    # 7-9. Empty, malformed and incomplete values.
    sha = _commit(repo, "empty", "Recipe:")
    code, msg = run_check(repo, base, sha)
    expect("empty trailer: fails as empty, not as absent", (code, "empty `Recipe:` trailer" in msg, sha[:12] in msg), (1, True, True))
    sha = _commit(repo, "bad", "Recipe: none, trust me")
    code, msg = run_check(repo, base, sha)
    expect("unrecognised shape: fails", (code, "not one of the accepted shapes" in msg), (1, True))
    sha = _commit(repo, "bare", "Recipe: parent-red")
    code, _ = run_check(repo, base, sha)
    expect("parent-red with no test named: fails", code, 1)

    # 10. Two trailers on the newest declaring commit.
    sha = _commit(repo, "two", "Recipe: #7\nRecipe: parent-red X")
    code, msg = run_check(repo, base, sha)
    expect("two trailers on the newest declaring commit: fails", (code, "carries 2 of them" in msg), (1, True))

    # 11. A newer correction supersedes the bad one; 12. a newer commit with no trailer does not.
    fixed = _commit(repo, "test: name recipe #7", trailer="Recipe: #7")
    code, msg = run_check(repo, base, fixed)
    expect("newest correction supersedes older declarations", (code, fixed[:12] in msg), (0, True))
    later = _commit(repo, "fix: unrelated follow-up")
    code, msg = run_check(repo, base, later)
    expect("a newer commit without a trailer leaves the correction in force", (code, fixed[:12] in msg), (0, True))

    # 13. A range that stops before HEAD: the correction above HEAD~2 is out of range.
    code, msg = run_check(repo, base, sha)
    expect("non-HEAD range reads only its own commits", (code, "carries 2 of them" in msg), (1, True))

    # 14. First parent only: a trailer reached only through a merged side branch does not count.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    _git(repo, "switch", "-q", "-c", "side", base)
    _commit(repo, "side", trailer="Recipe: #7")
    _git(repo, "switch", "-q", "main")
    _git(repo, "merge", "-q", "--no-ff", "-m", "merge side", "side")
    code, msg = run_check(repo, base, _sha(repo))
    expect("a trailer only on a merged side branch is not on the first-parent path",
           (code, "no commit in the range" in msg), (1, True))
    _commit(repo, "on main", trailer="Recipe: #7")
    code, _ = run_check(repo, base, _sha(repo))
    expect("the same trailer on the first-parent path counts", code, 0)

    # 16-17. Label refusal stops before validation; validator refusal is quoted.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    calls.clear()
    sha = _commit(repo, "x", trailer="Recipe: #8")
    code, _ = run_check(repo, base, sha)
    expect("issue without the label: fails before validating", (code, calls), (1, []))
    sha = _commit(repo, "y", trailer="Recipe: #7")
    code, msg = run_check(repo, base, sha, rc=2, text="REFUSED — no block")
    expect("labelled issue, validator refuses: fails quoting it", (code, "REFUSED — no block" in msg), (1, True))
    code, _ = run_check(repo, base, sha, labels=lambda n, r: ["not test-hardening"])
    expect("a label merely containing the word: fails", code, 1)

    # 19-20. Git cannot answer: exit 3 territory, never a verdict.
    for label, b, h in (("unresolvable base raises", "0" * 40, sha), ("unresolvable head raises", base, "f" * 40)):
        try:
            run_check(repo, b, h)
            expect(label, "returned", "raised")
        except Infrastructure:
            expect(label, "raised", "raised")

    # 21-22. Counting: lines outside Tests/ and a moved test file add nothing.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 50, path="Sources/Probe.swift")
    code, _ = run_check(repo, base, head)
    expect("lines outside Tests/ do not count", code, 0)
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 50)
    _git(repo, "mv", "Tests/Probe/Probe.swift", "Tests/Probe/Moved.swift")
    _git(repo, "commit", "-q", "-m", "move")
    code, msg = run_check(repo, head, _sha(repo))
    expect("a renamed test file counts zero added lines", (code, "0 lines added" in msg), (0, True))
    blob = repo / "Tests" / "Probe" / "blob.bin"
    blob.write_bytes(bytes(range(256)) * 64)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "binary")
    code, msg = run_check(repo, head, _sha(repo))
    expect("a binary test file counts zero added lines", (code, "0 lines added" in msg), (0, True))

    # 24-25. Rebase keeps the trailer; a squash that rewrites the message loses it.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    _commit(repo, "test: name recipe #7", trailer="Recipe: #7")
    _git(repo, "switch", "-q", "-c", "upstream", base)
    _commit(repo, "upstream moved")
    _git(repo, "switch", "-q", "main")
    _git(repo, "rebase", "-q", "upstream")
    new_base = _sha(repo, "upstream")
    code, _ = run_check(repo, new_base, _sha(repo))
    expect("rebase keeps the trailer", code, 0)
    _git(repo, "reset", "-q", "--soft", new_base)
    _git(repo, "commit", "-q", "-m", "squashed: tests")
    code, msg = run_check(repo, new_base, _sha(repo))
    expect("a squash that drops the message loses the trailer, and the message names squash",
           (code, "squash or fixup can drop them" in msg), (1, True))

    # A workstation trailer.separators setting does not hide a trailer CI would see.
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    sha = _commit(repo, "test: control", trailer="Recipe: resource-control ManifestTests")
    _git(repo, "config", "trailer.separators", "=")
    code, msg = run_check(repo, base, sha)
    expect("a repository trailer.separators setting does not hide the trailer", (code, sha[:12] in msg), (0, True))

    # 26-28. The real GitHub boundary through a fake gh on PATH: lookups run in --repo, a gh
    # failure is Infrastructure, and the validator forwards --repo to its issue read.
    fakebin = scratch / "fakebin"
    fakebin.mkdir()
    cwd_log = scratch / "gh-cwd.log"
    issue_body = scratch / "issue-body.md"
    issue_body.write_text("A test-hardening issue.\n\n```json\n" + json.dumps({"rows": [_ROW]}) + "\n```\n")
    gh = fakebin / "gh"
    gh.write_text("#!/bin/sh\n"
                  f"pwd -P >> '{cwd_log}'\n"
                  'if [ "$FAKE_GH_FAIL" = 1 ]; then echo "HTTP 502" >&2; exit 1; fi\n'
                  'case "$*" in\n'
                  f"  *body,comments*) cat '{issue_body}' ;;\n"
                  "  *) echo test-hardening ;;\n"
                  "esac\n")
    gh.chmod(0o755)
    real_path = os.environ["PATH"]
    git_path = shutil.which("git")
    os.environ["PATH"] = f"{fakebin}{os.pathsep}{real_path}"
    repo, base, head = _repo_with_test_lines(scratch, FLOOR + 1)
    expect("issue_labels runs gh in the repo", (issue_labels(7, repo), cwd_log.read_text().split()),
           (["test-hardening"], [str(repo.resolve())]))
    os.environ["FAKE_GH_FAIL"] = "1"
    try:
        try:
            issue_labels(7, repo)
            expect("a gh failure raises, never a verdict", "returned", "raised")
        except Infrastructure:
            expect("a gh failure raises, never a verdict", "raised", "raised")
        cwd_log.write_text("")
        try:
            validate_recipe(7, repo, tree)
            expect("the validator reads the issue from --repo, not --checkout", "returned", "raised")
        except Infrastructure:
            expect("the validator reads the issue from --repo, not --checkout",
                   cwd_log.read_text().split(), [str(repo.resolve())])
    finally:
        os.environ.pop("FAKE_GH_FAIL", None)

    # 29-31. The real checker CLI and the real validator, with the landing tree apart from the
    # repository: the verdict follows the tree's files, the issue read follows the repository.
    landing = _landing_tree(scratch)
    head = _commit(repo, "test: name recipe #7", trailer="Recipe: #7")
    args = ("--trailers", "--base", base, "--head", head, "--repo", str(repo), "--checkout", str(landing))
    cwd_log.write_text("")
    code, out = _cli(*args)
    expect("real validator, anchor present in the landing tree: exit 0",
           (code, "1/1 rows runnable" in out), (0, True))
    thing = landing / "Sources" / "Thing.swift"
    thing.write_text("let guarded = maybe\n")
    code, out = _cli(*args)
    expect("real validator, anchor gone from the landing tree only: exit 1 naming the row",
           (code, "UNRUNNABLE" in out, _ROW["label"] in out), (1, True, True))
    thing.write_text(_ROW["anchor"] + "\n")
    code, out = _cli(*args)
    expect("real validator, anchor restored: exit 0, and every gh lookup ran in the repository",
           (code, sorted(set(cwd_log.read_text().split()))), (0, [str(repo.resolve())]))

    # 32-35. A tool that cannot start, or a repository path that does not exist, is "could not
    # run" (exit 3) with no traceback; a real recipe failure stays exit 1.
    git_only = scratch / "git-only-bin"
    git_only.mkdir()
    (git_only / "git").symlink_to(git_path)
    os.environ["PATH"] = str(git_only)
    try:
        code, out = _cli(*args)
    finally:
        os.environ["PATH"] = f"{fakebin}{os.pathsep}{real_path}"
    expect("gh not installed: exit 3, could not run, no traceback",
           (code, "could not run" in out, "Traceback" in out), (3, True, False))
    os.environ["PATH"] = str(fakebin)
    try:
        code, out = _cli(*args)
    finally:
        os.environ["PATH"] = f"{fakebin}{os.pathsep}{real_path}"
    expect("git not installed: exit 3, could not run, no traceback",
           (code, "could not run" in out, "Traceback" in out), (3, True, False))
    missing = scratch / "no-such-repo"
    code, out = _cli("--trailers", "--base", base, "--head", head, "--repo", str(missing))
    expect("repository path missing: exit 3, could not run, no traceback",
           (code, "could not run" in out, "Traceback" in out), (3, True, False))
    rel_cwd = os.getcwd()
    os.chdir(repo.parent)
    try:
        code, out = _cli("--trailers", "--base", base, "--head", head, "--repo", repo.name,
                         "--checkout", os.path.relpath(landing, repo.parent))
    finally:
        os.chdir(rel_cwd)
    expect("relative --repo and --checkout from another directory: exit 0", (code, "1/1 rows runnable" in out), (0, True))
    bare = _commit(repo, "fix: drop the declaration", "Recipe:")
    code, out = _cli("--trailers", "--base", base, "--head", bare, "--repo", str(repo), "--checkout", str(landing))
    expect("a real recipe failure through the CLI stays exit 1", (code, "empty `Recipe:` trailer" in out), (1, True))

    print(f"self-test: {cases} cases, {fails} failure(s)")
    return 1 if fails or cases == 0 else 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--trailers", action="store_true",
                        help="read the Recipe declaration from commit trailers in base..head")
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd(),
                        help="where git history and gh run (default: the current directory)")
    parser.add_argument("--checkout", type=pathlib.Path,
                        help="the tree the validator reads (default: --repo)")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not (args.trailers and args.base and args.head):
        parser.error("--trailers, --base and --head are required (or --self-test)")
    # Absolute, because the validator runs with --repo as its working directory: a relative
    # --checkout would then resolve inside the repository a second time.
    repo = args.repo.resolve()
    checkout = (args.checkout if args.checkout is not None else args.repo).resolve()
    try:
        code, message = check(repo, checkout, args.base, args.head)
    except (Infrastructure, OSError) as error:
        # OSError: git or gh could not start, or --repo does not exist. Unknown, not a verdict.
        print(f"::error title=recipe-check::could not run: {error}\nNot a verdict on the change; re-run the check.")
        return 3
    print(message)
    if code != 0:
        print("::error title=recipe-check::the commits do not satisfy the test ship condition; "
              "add a commit carrying the `Recipe:` trailer, then push again.")
    return code


if __name__ == "__main__":
    sys.exit(main())
