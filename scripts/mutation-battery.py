#!/usr/bin/env python3
"""Run a mutation battery: break one production line at a time and require the named test to notice.

WHY THIS EXISTS
    A test that passes when the code it guards is broken proves nothing. The only way to know a test
    binds is to break the thing it names and watch it go red. That is cheap to describe and expensive
    to do by hand, so this runs it unattended.

THE FOUR CONTROLS, none of which are optional
    1. CLEAN BEFORE, not tidy after. The baseline pass runs every named suite BEFORE the first mutation
       and requires green. A battery started on an already-poisoned tree reports a perfect score, and
       verified restores cannot catch that because the poisoning predates the harness (2026-08-17:
       8/8 CAUGHT, every row worthless, row eight running against a file six mutations deep).
    2. RESTORE BY FILE COPY. `git checkout --` silently no-ops on an untracked file and, for a file
       staged as a RENAME, restores the OLD content under the NEW path. Both failures are silent. This
       uses shutil.copy2 and then requires the bytes to match.
    3. FAIL CLOSED ON ZERO TESTS. `-only-testing:` with a suite name that does not exist does NOT
       error: xcodebuild prints `Executed 0 tests` and `** TEST SUCCEEDED **`. Inside a battery that
       reads as EVERY MUTANT SURVIVED, so every filter is validated in the baseline pass and any run
       executing zero tests is an ERROR, never a result. The suite name comes from the `@Suite`
       declaration, never from the filename.
    4. A MUTANT THAT DOES NOT COMPILE IS AN ERROR, NOT A CATCH. A compile failure turns the lane red
       while proving nothing about the test. Detected as a red lane carrying `error:` and no test-run
       summary.

WHAT IT CANNOT DO, stated so nobody reads a green report as more than it is
    A battery only ever tries the mutations its author imagined. It proves a test fires on the shapes
    you thought of; it never proves the test is BINDING. For a guard written over identifier names or
    source text this gap is total: an alias, a helper returning the comparison, or the same expression
    moved upstream all walk past while every row still reports CAUGHT. Those guards need an independent
    attempt to evade them, by someone other than their author. See
    `.claude/rules/validation-discipline.md` RULE: verify-the-feature-not-the-crash.

RECIPE FORMAT (JSON; the same block that goes in the `test-hardening` issue body)
    {
      "suite_default": "EnviousWisprTests/FooTests",
      "rows": [
        {
          "label":       "drop the adjudication term from the completeness check",
          "file":        "Sources/EnviousWisprPipeline/Foo.swift",
          "anchor":      "exact source text, must occur EXACTLY once",
          "replacement": "exact replacement text",
          "suite":       "EnviousWisprTests/FooTests",   // optional if suite_default is set
          "expect_fail": "the test that must go red"     // substring-matched against failure lines
        }
      ]
    }

USAGE
    scripts/mutation-battery.py --from-issue 2156        # the overnight form: recipe from the issue
    scripts/mutation-battery.py --recipes recipes.json
    scripts/mutation-battery.py --recipes recipes.json --row 3      # one row, for iterating on a fix
    scripts/mutation-battery.py --recipes recipes.json --dry-run    # validate + baseline, no mutations
    scripts/mutation-battery.py --recipes recipes.json --validate-only  # no xcodebuild at all

EXIT CODES
    0  every row CAUGHT, baseline green before and after, every file byte-identical
    1  at least one SURVIVED, ERRORED, or a restore failed
    2  usage / preflight refusal (the battery never started)
"""

import argparse
import filecmp
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# The dev app writes to ~/Library/Logs/EnviousWispr/app.log. AppLogger tests write a marker there and
# read it back; a second concurrent writer breaks UTF-8 boundaries, the read returns empty, and ~6
# tests fail on a diff that touches no logging code (#2080). Inside a battery that scores as a mutant
# CAUGHT when nothing detected the sabotage — it fails toward CONFIDENCE, which is the direction
# nothing prompts you to check. So this is a refusal, not a warning.
DEV_APP_PATTERN = "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"

TEST_COUNT_RE = re.compile(r"Test run with (\d+) test")
FAILURE_LINE_RE = re.compile(r"✘ .*")
COMPILE_ERROR_RE = re.compile(r"^.*?: error: ", re.MULTILINE)


# The canonical logic-test entry point is scripts/xcode-test.sh (tools-and-apps.md
# RULE: xcode-test-entrypoint). This runner deliberately does NOT shell out to it, for two reasons:
# that script tees to a FIXED log path and SUMS every "Test run with N test" line it finds, so two
# lanes writing it produce an inflated count; and it runs `tuist generate` unconditionally, 6.7s of
# byte-identical output per row. Both are correct for a one-shot run and wrong for a battery.
#
# The cost of that deviation is TWO SOURCES OF TRUTH for the build settings, so it is paid for with a
# fail-closed drift guard: if the canonical script's settings stop matching the ones below, the battery
# REFUSES rather than quietly measuring a differently-configured build. Reconcile deliberately; do not
# silence it.
CANONICAL_SCRIPT = "scripts/xcode-test.sh"
CANONICAL_SETTINGS = [
    'PROJECT="EnviousWispr.xcodeproj"',
    'DEBUG_SCHEME="EnviousWispr"',
    "DEST='platform=macOS,arch=arm64'",
    "ARCHS=arm64",
    "VALID_ARCHS=arm64",
    "ONLY_ACTIVE_ARCH=YES",
    'TEST_ARGS=(-only-testing:"$FILTER")',
]


class Refusal(Exception):
    """Preflight said no. The battery never started, so there is nothing to restore."""


def run(cmd, cwd, log_path=None, timeout=None):
    """Run a command, optionally teeing to a per-row log. Never the shared fixed log path."""
    proc = subprocess.run(
        cmd, cwd=str(cwd), capture_output=True, text=True, timeout=timeout, check=False
    )
    out = proc.stdout + proc.stderr
    if log_path is not None:
        Path(log_path).write_text(out)
    return proc.returncode, out


class Lane:
    """One filtered Debug test run against warm DerivedData."""

    def __init__(self, worktree: Path, derived_data: Path, log_dir: Path):
        self.worktree = worktree
        self.derived_data = derived_data
        self.log_dir = log_dir
        self.generated = False

    def generate_once(self):
        """`tuist generate` output is byte-identical on a warm tree (measured 6.7s, M5 Max) so it is
        pure per-row overhead. Generate once. Safe ONLY because a mutation changes file CONTENT, never
        the file list — a recipe that adds or removes a file violates that and is rejected at load."""
        if self.generated:
            return
        rc, out = run(
            ["mise", "x", "tuist@4.195.11", "--", "tuist", "generate", "--no-open"],
            cwd=self.worktree,
            log_path=self.log_dir / "tuist-generate.log",
        )
        if rc != 0:
            raise Refusal(f"tuist generate failed (rc={rc}); see {self.log_dir/'tuist-generate.log'}")
        self.generated = True

    def run_suite(self, suite: str, tag: str):
        """Returns (count, failures, compiled, log_path). count is None when no summary was printed."""
        self.generate_once()
        log_path = self.log_dir / f"{tag}.log"
        cmd = [
            "xcodebuild", "test",
            "-project", "EnviousWispr.xcodeproj",
            "-scheme", "EnviousWispr",
            "-configuration", "Debug",
            "-derivedDataPath", str(self.derived_data),
            "-destination", "platform=macOS,arch=arm64",
            "ARCHS=arm64", "VALID_ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
            f"-only-testing:{suite}",
        ]
        started = time.monotonic()
        rc, out = run(cmd, cwd=self.worktree, log_path=log_path)
        elapsed = time.monotonic() - started

        counts = [int(n) for n in TEST_COUNT_RE.findall(out)]
        count = sum(counts) if counts else None
        failures = FAILURE_LINE_RE.findall(out)
        # A red lane with compiler diagnostics and no test summary never ran the tests.
        compiled = not (count is None and COMPILE_ERROR_RE.search(out) is not None)
        return count, failures, compiled, log_path, rc, elapsed


def check_canonical_settings(worktree: Path):
    """Fail closed if scripts/xcode-test.sh has drifted from the flags this runner reproduces."""
    canonical = worktree / CANONICAL_SCRIPT
    if not canonical.is_file():
        raise Refusal(
            f"{CANONICAL_SCRIPT} is missing. This runner reproduces its build settings, so it cannot "
            "confirm it is building the same thing the canonical entry point builds."
        )
    text = canonical.read_text()
    missing = [frag for frag in CANONICAL_SETTINGS if frag not in text]
    if missing:
        raise Refusal(
            f"{CANONICAL_SCRIPT} no longer contains settings this runner reproduces, so the battery "
            "would measure a differently-configured build than the canonical lane:\n  "
            + "\n  ".join(missing)
            + "\n\nReconcile CANONICAL_SETTINGS and the Lane class with the script, deliberately. "
            "Do not delete the guard to make this go away."
        )


def preflight(worktree: Path):
    check_canonical_settings(worktree)
    rc, out = run(["pgrep", "-f", DEV_APP_PATTERN], cwd=worktree)
    if rc == 0 and out.strip():
        raise Refusal(
            "A dev app is running. Its writes to ~/Library/Logs/EnviousWispr/app.log corrupt the\n"
            "AppLogger tests, and those failures score as mutants CAUGHT when nothing detected the\n"
            "sabotage (#2080). Stop every dev instance across ALL worktrees and re-run.\n"
            f"  pids: {' '.join(out.split())}"
        )
    leftovers = list(worktree.rglob("*.mutbak"))
    if leftovers:
        raise Refusal(
            "Backup files from an earlier battery are still on disk, so a previous run did not "
            "restore. Investigate before mutating anything else:\n  "
            + "\n  ".join(str(p) for p in leftovers)
        )


FENCE_RE = re.compile(r"```json\s*\n(.*?)```", re.DOTALL)


def recipes_from_issue(number: int, worktree: Path):
    """Pull the recipe out of a `test-hardening` issue body.

    The issue IS the backlog (testing-philosophy.md RULE:
    write-the-test-by-day-run-the-battery-by-night) — the founder hands out overnight work from the issue
    list, so a recipe living in a repo file is invisible to that. This is what closes the loop: the
    overnight session runs `--from-issue N` and never has to transcribe anything by hand.

    Fails closed on zero or several fenced json blocks. Picking "the first one" would silently run a
    different recipe than the one a reader of the issue believes is running.
    """
    rc, out = run(
        ["gh", "issue", "view", str(number), "--json", "body", "--jq", ".body"], cwd=worktree
    )
    if rc != 0:
        raise Refusal(f"could not read issue #{number}: {out.strip()[:300]}")
    blocks = FENCE_RE.findall(out)
    if not blocks:
        raise Refusal(
            f"issue #{number} carries no ```json recipe block. A test-hardening issue without its "
            "recipe cannot be acted on cold, which is the whole reason the recipe goes in the BODY."
        )
    if len(blocks) > 1:
        raise Refusal(
            f"issue #{number} carries {len(blocks)} ```json blocks. Exactly one, or the run and the "
            "issue disagree about what was tested."
        )
    return blocks[0]


def load_recipes(path: Path, worktree: Path, raw: str = None):
    try:
        data = json.loads(raw if raw is not None else path.read_text())
    except json.JSONDecodeError as exc:
        where = f"issue body" if raw is not None else str(path)
        raise Refusal(f"the recipe in {where} is not valid JSON: {exc}")
    default_suite = data.get("suite_default")
    rows = data.get("rows") or []
    if not rows:
        raise Refusal(f"{'the issue body' if raw is not None else path} declares no rows.")
    for i, row in enumerate(rows, 1):
        for field in ("label", "file", "anchor", "replacement", "expect_fail"):
            if not row.get(field):
                raise Refusal(f"row {i} is missing required field '{field}'.")
        row.setdefault("suite", default_suite)
        if not row["suite"]:
            raise Refusal(f"row {i} has no suite and no suite_default is set.")
        if "/" not in row["suite"]:
            raise Refusal(
                f"row {i} suite '{row['suite']}' is not target-qualified. It must read "
                "'EnviousWisprTests/<SuiteName>', and <SuiteName> comes from the @Suite "
                "declaration, never from the filename."
            )
        target = worktree / row["file"]
        if not target.is_file():
            raise Refusal(f"row {i} target does not exist: {row['file']}")
        if row["anchor"] == row["replacement"]:
            raise Refusal(f"row {i} anchor and replacement are identical — it would mutate nothing.")
        # Check anchor presence and uniqueness HERE, against the clean tree, so a bad recipe costs
        # nothing. The row re-checks at apply time because an earlier row may share the file.
        occurrences = target.read_text().count(row["anchor"])
        if occurrences == 0:
            raise Refusal(
                f"row {i} anchor not found in {row['file']} — the mutation would never be applied, "
                "and a row that never applied is not a row that passed."
            )
        if occurrences > 1:
            raise Refusal(
                f"row {i} anchor occurs {occurrences} times in {row['file']}; it must be unique or "
                "the mutation lands somewhere you did not choose."
            )
    return rows


def baseline(lane: Lane, suites, phase: str):
    """Every named suite must run at least one test and pass. This is both the clean-tree control and
    the filter validation: a suite name that does not exist executes zero tests and SUCCEEDS."""
    problems = []
    for suite in sorted(suites):
        tag = f"baseline-{phase}-{suite.replace('/', '_')}"
        count, failures, compiled, log, rc, elapsed = lane.run_suite(suite, tag)
        if not compiled:
            problems.append(f"{suite}: did not compile ({log})")
        elif count is None or count < 1:
            problems.append(
                f"{suite}: executed ZERO tests and reported success — the filter names a suite that "
                f"does not exist. Read the name from its @Suite declaration. ({log})"
            )
        elif rc != 0 or failures:
            problems.append(f"{suite}: {len(failures)} failing on an unmutated tree ({log})")
        else:
            print(f"    baseline {phase}: {suite} — {count} tests green in {elapsed:.0f}s")
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--recipes", type=Path, help="a recipe JSON file")
    src.add_argument("--from-issue", type=int, metavar="N",
                     help="read the recipe from the ```json block in test-hardening issue #N")
    ap.add_argument("--worktree", type=Path, default=None)
    ap.add_argument("--row", type=int, default=None, help="run a single 1-indexed row")
    ap.add_argument("--dry-run", action="store_true", help="validate recipes and baseline, mutate nothing")
    ap.add_argument("--validate-only", action="store_true",
                    help="preflight and recipe validation only — no xcodebuild, no baseline, no mutations")
    args = ap.parse_args()
    if args.validate_only and (args.dry_run or args.row is not None):
        ap.error("--validate-only stops before any run; combining it with --dry-run or --row would "
                 "silently do less than the other flag promises.")

    worktree = (args.worktree or Path(__file__).resolve().parent.parent).resolve()
    derived = worktree / ".derivedData" / "Test"
    log_dir = worktree / "build" / "mutation-battery"
    log_dir.mkdir(parents=True, exist_ok=True)

    print(f"worktree: {worktree}")
    rc, branch = run(["git", "branch", "--show-current"], cwd=worktree)
    rc, head = run(["git", "rev-parse", "HEAD"], cwd=worktree)
    print(f"branch:   {branch.strip()} @ {head.strip()[:12]}")

    try:
        preflight(worktree)
        if args.from_issue is not None:
            print(f"recipe:   issue #{args.from_issue}")
            rows = load_recipes(None, worktree, raw=recipes_from_issue(args.from_issue, worktree))
        else:
            rows = load_recipes(args.recipes.resolve(), worktree)
    except Refusal as exc:
        print(f"\nREFUSED — the battery did not start.\n\n{exc}", file=sys.stderr)
        return 2

    if args.validate_only:
        print(f"\n--validate-only: preflight clean, {len(rows)} row(s) well-formed. Nothing was run.")
        return 0

    if args.row is not None:
        if not 1 <= args.row <= len(rows):
            print(f"--row {args.row} out of range (1..{len(rows)})", file=sys.stderr)
            return 2
        rows = [rows[args.row - 1]]

    lane = Lane(worktree, derived, log_dir)
    suites = {row["suite"] for row in rows}

    print(f"\n[1/3] baseline on a clean tree — {len(suites)} suite(s)")
    try:
        problems = baseline(lane, suites, "before")
    except Refusal as exc:
        print(f"\nREFUSED — {exc}", file=sys.stderr)
        return 2
    if problems:
        print("\nBASELINE IS NOT GREEN. Nothing was mutated.", file=sys.stderr)
        print("A failing test on a supposedly clean tree is a claim about the TREE first and the code",
              file=sys.stderr)
        print("second — verify the tree before believing any diagnosis.\n", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    if args.dry_run:
        print("\n--dry-run: recipes validated, baseline green, nothing mutated.")
        return 0

    print(f"\n[2/3] {len(rows)} mutation(s), one at a time")
    results = []
    for i, row in enumerate(rows, 1):
        target = worktree / row["file"]
        backup = target.with_suffix(target.suffix + ".mutbak")
        tag = f"row{i:02d}"
        verdict, detail = "ERROR", "did not run"
        shutil.copy2(target, backup)
        try:
            src = target.read_text()
            occurrences = src.count(row["anchor"])
            if occurrences == 0:
                detail = "anchor not found — the mutation was never applied"
            elif occurrences > 1:
                detail = f"anchor occurs {occurrences} times; it must be unique"
            else:
                target.write_text(src.replace(row["anchor"], row["replacement"], 1))
                # Prove it landed by reading the file back rather than trusting the write.
                if row["replacement"] not in target.read_text():
                    detail = "mutation did not land on re-read"
                else:
                    count, failures, compiled, log, rc_run, elapsed = lane.run_suite(row["suite"], tag)
                    if not compiled:
                        detail = f"mutant does not compile — proves nothing about the test ({log})"
                    elif count is None or count < 1:
                        detail = f"executed ZERO tests — filter is wrong, not the test ({log})"
                    elif any(row["expect_fail"] in line for line in failures):
                        verdict = "CAUGHT"
                        others = [l for l in failures if row["expect_fail"] not in l]
                        detail = f"{row['expect_fail']} went red in {elapsed:.0f}s"
                        if others:
                            detail += f" (+{len(others)} other failing)"
                    elif failures:
                        detail = (
                            f"suite went red but NOT via {row['expect_fail']} — something else "
                            f"caught it, so this test is not the guard ({log})"
                        )
                        verdict = "SURVIVED"
                    else:
                        verdict = "SURVIVED"
                        detail = f"{count} tests still green with the code broken ({log})"
        finally:
            shutil.copy2(backup, target)
            if not filecmp.cmp(backup, target, shallow=False):
                verdict, detail = "ERROR", "RESTORE FAILED — the tree is dirty, stop and inspect"
            else:
                backup.unlink()
        marker = {"CAUGHT": "  ok  ", "SURVIVED": " SURV ", "ERROR": " ERR  "}[verdict]
        print(f"  [{marker}] row {i}: {row['label']}\n           {detail}")
        results.append((verdict, row["label"], detail))

    print("\n[3/3] baseline again — every file must be back to where it started")
    after = baseline(lane, suites, "after")
    if after:
        print("\nBASELINE NOT RESTORED. A restore failed; the tree is dirty.", file=sys.stderr)
        for p in after:
            print(f"  - {p}", file=sys.stderr)
        return 1

    caught = [r for r in results if r[0] == "CAUGHT"]
    bad = [r for r in results if r[0] != "CAUGHT"]
    print(f"\n{'=' * 72}\n{len(caught)}/{len(results)} CAUGHT, baseline green before and after.")
    if bad:
        print(f"\n{len(bad)} row(s) need work:")
        for verdict, label, detail in bad:
            print(f"  {verdict}: {label}\n    {detail}")
        return 1
    print("\nEvery mutation was detected by the test that claimed to guard it.")
    print("This proves the tests fire on the mutations written here. It does NOT prove they are")
    print("binding — a guard over identifier names or source text still needs an independent")
    print("attempt to evade it, by someone other than its author.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
