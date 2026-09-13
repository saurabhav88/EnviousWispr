#!/usr/bin/env python3
"""A PR that adds more than a floor of test lines must name how those tests are bound (#2868).

testing-philosophy.md RULE: write-the-test-by-day-run-the-battery-by-night states the ship
condition: a test ships with a `test-hardening` issue carrying its recipe, or with one of the two
substitutes the same rule names. Measured 2026-09-13: 8 of the 18 PRs merged since 2026-09-10 with
more than 100 added lines under `Tests/` carried none of the three. Nothing checked.

Usage (the `recipe-check` job in pr-check.yml):
    check-test-recipe.py --base <sha> --head <sha> --pr <number> [--checkout <dir>]
    check-test-recipe.py --self-test

The PR body carries exactly one line starting with `Recipe:`, in one of three shapes:

    Recipe: #<N>                      an issue labelled test-hardening whose recipe VALIDATES
                                      against the PR head (scripts/validate-mutation-recipe.py)
    Recipe: parent-red <TestName>     the bug-fix route: the named test ran RED on the parent
                                      commit for the bug's reason (declared; no Xcode here)
    Recipe: resource-control <Test>   the non-Swift-subject route (#2693, #2749): a two-way
                                      control on the resource, in the PR (declared)

Exit codes: 0 the PR satisfies the condition (or is under the floor); 1 it does not, with the
reason printed; 3 the check could not run (a gh or git failure), which is not a verdict.
"""

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

# The floor is the measurement in #2868: every PR in its table added more than this. Below it a
# bounded wait, a renamed helper or a settle fix (#2857, #2860) ships without ceremony, and the
# rule's daytime route for a small bug-fix test is the parent-red proof the reviewer reads.
FLOOR = 100
LABEL = "test-hardening"
RECIPE_LINE = re.compile(r"^\s*Recipe:\s*(.*?)\s*$", re.MULTILINE)
# The PR template explains the shapes inside an HTML comment that itself contains `Recipe:` lines;
# a body that keeps the comment must not count them.
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
ISSUE_SHAPE = re.compile(r"^#(\d+)$")
DECLARED_SHAPE = re.compile(r"^(parent-red|resource-control)\s+(\S.*)$")
SHAPES = (
    "Recipe: #<N>  (an issue labelled test-hardening whose recipe validates against this PR)",
    "Recipe: parent-red <TestName>  (the new test ran RED on the parent commit for the bug's reason)",
    "Recipe: resource-control <TestName>  (a two-way control on a non-Swift resource, in this PR)",
)

VALIDATOR = pathlib.Path(__file__).resolve().parent.parent / "validate-mutation-recipe.py"


class Infrastructure(Exception):
    """The check could not ask its question; the answer is unknown, not 'no'."""


def run(argv, cwd):
    proc = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def added_test_lines(checkout, base, head):
    """Lines ADDED under Tests/ between base and head, three-dot (what the PR introduces).

    `--numstat` prints `-` for a binary file; that counts as zero, since no recipe can bind a
    binary. A diff that cannot resolve is a refusal to answer, never a zero: a zero would pass the
    PR on the count with nothing measured.
    """
    rc, out = run(["git", "diff", "--numstat", f"{base}...{head}", "--", "Tests/"], cwd=checkout)
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


def pr_body(number, checkout):
    rc, out = run(["gh", "pr", "view", str(number), "--json", "body", "--jq", ".body"], cwd=checkout)
    if rc != 0:
        raise Infrastructure(f"could not read PR #{number}: {out.strip()[:300]}")
    return out


def issue_labels(number, checkout):
    rc, out = run(
        ["gh", "issue", "view", str(number), "--json", "labels", "--jq", ".labels[].name"],
        cwd=checkout,
    )
    if rc != 0:
        raise Infrastructure(f"could not read issue #{number}: {out.strip()[:300]}")
    return out.split()


def validate_recipe(number, checkout):
    """The validator's exit code is the verdict; its output is the reason, quoted whole."""
    rc, out = run([sys.executable, str(VALIDATOR), "--issue", str(number), "--checkout", str(checkout)],
                  cwd=checkout)
    # The validator's own read failure is exit 2 like a malformed recipe (mutation-battery.py
    # `could not read issue`); that one is nobody's recipe to fix. Same classification as
    # test-hardening-recipe.yml.
    if rc != 0 and "could not read issue" in out:
        raise Infrastructure(out.strip())
    return rc, out


def recipe_lines(body):
    return [m.group(1) for m in RECIPE_LINE.finditer(HTML_COMMENT.sub("", body))]


def check(checkout, base, head, pr, *, body=None, labels=issue_labels, validate=validate_recipe):
    """Returns (exit code, message). Keyword seams exist for --self-test only; the job passes none."""
    added = added_test_lines(checkout, base, head)
    if added <= FLOOR:
        return 0, f"ok: {added} lines added under Tests/, at or under the {FLOOR}-line floor; no Recipe line required"

    if body is None:
        body = pr_body(pr, checkout)
    lines = recipe_lines(body)
    need = (f"{added} lines added under Tests/ is over the {FLOOR}-line floor, so the PR body must carry "
            f"exactly one `Recipe:` line in one of these shapes:\n  " + "\n  ".join(SHAPES))
    if len(lines) != 1:
        found = "none" if not lines else "\n  ".join(f"Recipe: {l}" for l in lines)
        return 1, f"FAIL: {len(lines)} `Recipe:` lines in the PR body (found: {found}).\n{need}"

    value = lines[0]
    issue = ISSUE_SHAPE.match(value)
    if issue:
        number = int(issue.group(1))
        if LABEL not in labels(number, checkout):
            return 1, f"FAIL: `Recipe: #{number}` names an issue without the `{LABEL}` label.\n{need}"
        rc, out = validate(number, checkout)
        if rc != 0:
            return 1, (f"FAIL: `Recipe: #{number}` does not validate against this PR's head "
                       f"(validate-mutation-recipe.py exit {rc}):\n{out.rstrip()}\n"
                       f"Every row must be runnable in the tree that is about to merge; a row that "
                       f"anchors on code this PR does not carry is dead on the night it is run.")
        return 0, f"ok: {added} lines added under Tests/; `Recipe: #{number}` validates against this PR:\n{out.rstrip()}"

    declared = DECLARED_SHAPE.match(value)
    if declared:
        route, subject = declared.groups()
        return 0, (f"ok: {added} lines added under Tests/; declared route `{route}` for `{subject}`. "
                   f"This runner has no Xcode, so the declaration is what the review gate reads.")

    return 1, f"FAIL: `Recipe: {value}` is not one of the accepted shapes.\n{need}"


# ---------------------------------------------------------------------------
# Self-test: a real git repo for the count, real bodies for the parse. The issue half is proven
# against real issues on GitHub (#2868's kill criterion), never stubbed here beyond the seams.
# ---------------------------------------------------------------------------

def _git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)


def _repo_with_test_lines(lines, path="Tests/Probe/Probe.swift"):
    repo = pathlib.Path(tempfile.mkdtemp(prefix="recipe-check-"))
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base")
    base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(f"// line {i}\n" for i in range(lines)))
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "tests")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    return repo, base, head


def self_test():
    fails = 0

    def expect(label, got, want):
        nonlocal fails
        if got == want:
            print(f"ok   [{label}]")
        else:
            fails += 1
            print(f"FAIL [{label}] expected {want!r}, got {got!r}")

    labelled = lambda n, c: [LABEL] if n == 7 else ["task"]
    calls = []

    def validator(rc, text):
        def fake(n, c):
            calls.append(n)
            return rc, text
        return fake

    repo, base, head = _repo_with_test_lines(FLOOR)
    code, _ = check(repo, base, head, 1, body="", labels=labelled, validate=validator(1, "x"))
    expect("at the floor: no Recipe line needed", code, 0)

    repo, base, head = _repo_with_test_lines(FLOOR + 1)
    code, msg = check(repo, base, head, 1, body="## Summary\nno line here\n", labels=labelled, validate=validator(0, ""))
    expect("over the floor, no Recipe line: fails", (code, "0 `Recipe:` lines" in msg), (1, True))

    code, msg = check(repo, base, head, 1, body="Recipe: #7\nRecipe: parent-red X\n", labels=labelled, validate=validator(0, ""))
    expect("two Recipe lines: fails", (code, "2 `Recipe:` lines" in msg), (1, True))

    code, msg = check(repo, base, head, 1, body="Recipe:\n", labels=labelled, validate=validator(0, ""))
    expect("template line left empty: fails naming the shapes", (code, SHAPES[0] in msg), (1, True))

    code, msg = check(repo, base, head, 1, body="Recipe: #8\n", labels=labelled, validate=validator(0, ""))
    expect("issue without the label: fails before validating", (code, calls), (1, []))

    code, msg = check(repo, base, head, 1, body="Recipe: #7\n", labels=labelled, validate=validator(2, "REFUSED — no block"))
    expect("labelled issue, validator refuses: fails quoting it", (code, "REFUSED — no block" in msg, calls), (1, True, [7]))

    calls.clear()
    code, msg = check(repo, base, head, 1, body="Recipe: #7\n", labels=labelled, validate=validator(0, "#7: 4/4 rows runnable"))
    expect("labelled issue, validator passes: ok", (code, "4/4 rows runnable" in msg), (0, True))

    code, msg = check(repo, base, head, 1, body="  Recipe: parent-red FooTests/barFails\n", labels=labelled, validate=validator(1, "x"))
    expect("parent-red declaration: ok", (code, "parent-red" in msg), (0, True))

    code, msg = check(repo, base, head, 1, body="Recipe: resource-control ManifestTests\n", labels=labelled, validate=validator(1, "x"))
    expect("resource-control declaration: ok", code, 0)

    code, msg = check(repo, base, head, 1, body="Recipe: parent-red\n", labels=labelled, validate=validator(1, "x"))
    expect("parent-red with no test named: fails", code, 1)

    code, msg = check(repo, base, head, 1, body="Recipe: none, trust me\n", labels=labelled, validate=validator(1, "x"))
    expect("unrecognised shape: fails", code, 1)

    template = pathlib.Path(__file__).resolve().parent.parent.parent / ".github" / "pull_request_template.md"
    kept = template.read_text().replace("Recipe:\n", "Recipe: #7\n")
    expect("the template names the shapes inside its comment", kept.count("Recipe:") > 2, True)
    code, msg = check(repo, base, head, 1, body=kept, labels=labelled, validate=validator(0, "#7: 1/1 rows runnable"))
    expect("template comment kept beside one real line: ok", code, 0)
    code, msg = check(repo, base, head, 1, body=template.read_text(), labels=labelled, validate=validator(0, ""))
    expect("template left unfilled: fails", code, 1)

    # Binary and non-Tests additions do not count toward the floor.
    repo, base, head = _repo_with_test_lines(FLOOR + 50, path="Sources/Probe.swift")
    code, _ = check(repo, base, head, 1, body="", labels=labelled, validate=validator(1, "x"))
    expect("lines outside Tests/ do not count", code, 0)

    # A diff that cannot resolve is not a zero.
    try:
        check(repo, "0" * 40, head, 1, body="", labels=labelled, validate=validator(1, "x"))
        expect("unresolvable base raises", "returned", "raised")
    except Infrastructure:
        expect("unresolvable base raises", "raised", "raised")

    print(f"self-test: {fails} failure(s)")
    return 1 if fails else 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--pr", type=int)
    parser.add_argument("--checkout", type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not (args.base and args.head and args.pr):
        parser.error("--base, --head and --pr are required (or --self-test)")
    try:
        code, message = check(args.checkout, args.base, args.head, args.pr)
    except Infrastructure as error:
        print(f"::error title=recipe-check::could not run: {error}\nNot a verdict on the PR; re-run the job.")
        return 3
    print(message)
    if code != 0:
        print("::error title=recipe-check::the PR body does not satisfy the test ship condition; "
              "edit the body, then re-run this job (gh run rerun <run id> --failed) or push.")
    return code


if __name__ == "__main__":
    sys.exit(main())
