#!/usr/bin/env python3
"""Run a mutation battery: break one production line at a time and require the named test to notice.

WHY THIS EXISTS
    A test that passes when the code it guards is broken proves nothing. The only way to know a test
    binds is to break the thing it names and watch it go red. That is cheap to describe and expensive
    to do by hand, so this runs it unattended.

THE CONTROLS, none of which are optional — each exists because a real run got it wrong
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
    5. THE RESTORE IS STAMPED `NOW`. `copy2` returns the file's original MODIFICATION TIME too, and
       against warm DerivedData a replacement the same SIZE as its anchor then leaves a byte-identical
       file OLDER than the object compiled from the mutant — so the next row runs sabotaged code while
       every check reports clean. Invisible to a byte comparison.
    6. THE RESTORE SURVIVES BEING CANCELLED. The row's `finally` does not run under Python's default
       SIGTERM action, so an interrupted overnight run would leave the file MUTATED. The in-flight
       mutation is registered outside the try/finally and restored from a signal handler.
    7. THE LANE IS BOUNDED. A mutation that removes a completion or cancellation path can hang the
       suite; unbounded, the battery parks all night and never restores. A timeout is a row ERROR.
    8. NO DEV APP MAY BE RUNNING. Concurrent writes to the app log corrupt the AppLogger tests, and
       those failures score as mutants CAUGHT when nothing detected the sabotage (#2080) — it fails
       toward CONFIDENCE, so it is a refusal rather than a warning.
    9. THE CANONICAL BUILD SETTINGS MUST NOT HAVE DRIFTED. This runner reproduces `xcode-test.sh`'s
       invocation rather than calling it; the guard is the price, and #2165 is the plan to delete both.

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
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

# The dev app writes to ~/Library/Logs/EnviousWispr/app.log. AppLogger tests write a marker there and
# read it back; a second concurrent writer breaks UTF-8 boundaries, the read returns empty, and ~6
# tests fail on a diff that touches no logging code (#2080). Inside a battery that scores as a mutant
# CAUGHT when nothing detected the sabotage — it fails toward CONFIDENCE, which is the direction
# nothing prompts you to check. So this is a refusal, not a warning.
# Overridable ONLY so the self-test is not machine-wide. The check is a `pgrep` across the whole box,
# so without a seam every case in the suite fails whenever ANY session has a dev app open — which
# happened mid-run the night this was written, and produced a suite that half passed and half refused.
# The DEFAULT is the real pattern, so an unset environment is the safe one; the override can only make
# the check look at something else, never skip it, and it announces itself when used. Contrast #2145,
# where a convenience DEFAULT silently reconnected an injected seam to production — the direction
# matters more than the presence of a seam.
DEV_APP_PATTERN = os.environ.get(
    "EW_BATTERY_DEV_APP_PATTERN", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr")

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
# The exact token set of the canonical `xcodebuild test` invocation, compared BOTH WAYS. A
# presence-only check is one-directional and therefore blind in the direction that matters most: if the
# canonical lane GAINS a build setting, an environment wrapper, or a flag, every fragment it already had
# is still there, the guard stays green, and the battery quietly measures a differently-configured build
# than the lane everyone else trusts. Cloud review, PR #2158.
CANONICAL_TOKENS = {
    "-project", "-scheme", "-configuration", "-derivedDataPath", "-destination",
    "ARCHS=arm64", "VALID_ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
}
# Values that are shell expansions in the invocation and literals here, so they cannot be compared as
# tokens. Two review rounds each found ONE more of these, so rather than wait for a third the axes were
# enumerated exhaustively: every input that decides WHAT gets built and WHERE. Each line below is a
# literal that must appear in the canonical script verbatim.
#
#   what project      -> PROJECT
#   what scheme       -> DEBUG_SCHEME, and the CALL SITE that passes it (a scheme can be right while the
#                        call passes the other one)
#   what config       -> the call site again; `Lane.run_suite` hardcodes Debug, so a call site changed to
#                        Release diverges while `run_lane` itself is untouched
#   where it lands    -> DERIVED_DATA's default, which this runner reproduces as .derivedData/Test
#   what destination  -> DEST
#   how it filters    -> TEST_ARGS
#   what generates it -> the pinned tuist version, which this runner invokes directly
CANONICAL_ASSIGNMENTS = [
    'PROJECT="EnviousWispr.xcodeproj"',
    'DEBUG_SCHEME="EnviousWispr"',
    "DEST='platform=macOS,arch=arm64'",
    'TEST_ARGS=(-only-testing:"$FILTER")',
    'DERIVED_DATA="${DERIVED_DATA_PATH:-$PROJECT_ROOT/.derivedData/Test}"',
    # The WHOLE line, not a prefix: `run_lane "$DEBUG_SCHEME" Debug build/... ENABLE_TESTABILITY=YES`
    # still starts with the prefix, and those trailing positionals reach xcodebuild through `"$@"`,
    # which the expansion allowlist accepts by name without seeing its contents.
    'run_lane "$DEBUG_SCHEME" Debug build/xcode-test-debug.log\n',
    "mise x tuist@4.195.11 -- tuist generate --no-open",
]
# Expansions the runner knows the contents of, because CANONICAL_ASSIGNMENTS pins each one. An
# expansion NOT in this set hides arguments the runner cannot see, so it is a refusal rather than a
# token to skip — the difference between "I checked and it matches" and "I could not look".
CANONICAL_EXPANSIONS = {
    '"$PROJECT"', '"$scheme"', '"$config"', '"$DERIVED_DATA"', '"$DEST"',
    '"$@"', '"${TEST_ARGS[@]}"',
}
INVOCATION_RE = re.compile(r"xcodebuild test\s*\\\n(.*?)\|\s*tee", re.DOTALL)
# Whatever sits between the start of the line and `xcodebuild` — an env prefix, a wrapper, a different
# toolchain via DEVELOPER_DIR. Required to be EMPTY rather than enumerated: the runner invokes
# xcodebuild with its ambient environment, so any prefix means the canonical lane and the battery build
# differently, and there is no list of prefixes worth maintaining.
INVOCATION_PREFIX_RE = re.compile(r"^([^\n]*?)xcodebuild test\s*\\", re.MULTILINE)
# One definition, so the drift guard above and the call below cannot disagree about the version.
TUIST_GENERATE_ARGV = ["mise", "x", "tuist@4.195.11", "--", "tuist", "generate", "--no-open"]


# A row's restore lives in a `finally`, and Python's DEFAULT action for SIGTERM does not run it: the
# process dies where it stands, leaving the production file MUTATED and a .mutbak beside it. That is the
# worst state this tool can leave behind, and an overnight battery is exactly the thing someone cancels
# — a terminal closing, a session ending, a job being killed. So the restore is also registered here,
# outside the try/finally, and runs from the signal handler.
_ACTIVE_RESTORES = {}


def _restore_active(reason: str):
    """Put every in-flight mutation back. Safe to call twice; the row's `finally` may also run."""
    for target, backup in list(_ACTIVE_RESTORES.items()):
        try:
            if Path(backup).exists():
                shutil.copy2(backup, target)
                os.utime(target, None)
                Path(backup).unlink()
                print(f"  restored {target} after {reason}", file=sys.stderr)
        except OSError as exc:  # nothing better to do while dying; say so rather than exit silently
            print(f"  COULD NOT RESTORE {target} after {reason}: {exc}", file=sys.stderr)
        _ACTIVE_RESTORES.pop(target, None)


def _install_restore_on_signal():
    def handler(signum, _frame):
        _restore_active(f"signal {signum}")
        # Re-raise with the default action so the exit status still says we were killed.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


class Refusal(Exception):
    """Preflight said no. The battery never started, so there is nothing to restore."""


class _LaneTimedOut(Exception):
    """The lane was killed for running past its bound. Never a catch: a hang proves nothing."""


class _RowFailed(Exception):
    """This row cannot produce a verdict. It is an ERROR, never a catch and never a survivor.

    Raised rather than returned so the restore in the row's `finally` cannot be skipped, and caught
    per-row so one broken row does not abort the run before the closing baseline check — that check is
    what proves the tree came back, and losing it is worse than losing the remaining rows.
    """


# A mutation can make the code under test WAIT FOREVER — removing a completion path or a cancellation
# is one of the most valuable things to mutate, and also the most likely to hang. Unbounded, the
# unattended battery sits on that row all night and never reaches its restore or its closing baseline,
# so it leaves a MUTATED TREE behind. The bound is generous: it exists to convert a hang into a row
# ERROR, not to police a slow suite (validation-discipline.md `hang-guard-vs-latency-bound`).
LANE_TIMEOUT_SECONDS = 1800


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
            TUIST_GENERATE_ARGV,
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
        try:
            rc, out = run(cmd, cwd=self.worktree, log_path=log_path,
                          timeout=LANE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            Path(log_path).write_text(
                f"lane exceeded {LANE_TIMEOUT_SECONDS}s and was killed after {elapsed:.0f}s\n")
            raise _LaneTimedOut(
                f"the lane ran past {LANE_TIMEOUT_SECONDS}s and was killed. A mutation that removes a "
                f"completion or cancellation path can hang the suite; that is a row ERROR, never a "
                f"catch ({log_path})")
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

    missing_assignments = [frag for frag in CANONICAL_ASSIGNMENTS if frag not in text]

    match = INVOCATION_RE.search(text)
    if not match:
        raise Refusal(
            f"could not find the `xcodebuild test ... | tee` invocation in {CANONICAL_SCRIPT}. The "
            "runner reproduces that command, so it cannot confirm it still matches. Fail closed."
        )
    # Literal flags and build settings are compared as tokens, both ways. Shell EXPANSIONS cannot be
    # compared that way, so they are allowlisted instead: each one in CANONICAL_EXPANSIONS has its
    # contents pinned by CANONICAL_ASSIGNMENTS above, and an expansion outside that set hides arguments
    # this runner cannot see. Silently dropping them was the round-3 defect — indirection read as
    # absence.
    prefix_match = INVOCATION_PREFIX_RE.search(text)
    invocation_prefix = (prefix_match.group(1).strip() if prefix_match else "")

    raw_tokens = [tok for tok in match.group(1).split() if tok != "\\"]
    expansions = [tok for tok in raw_tokens if "$" in tok]
    unknown_expansions = sorted(set(expansions) - CANONICAL_EXPANSIONS)
    found = {tok for tok in raw_tokens if "$" not in tok}
    missing_tokens = sorted(CANONICAL_TOKENS - found)
    extra_tokens = sorted(found - CANONICAL_TOKENS)

    if missing_assignments or missing_tokens or extra_tokens or unknown_expansions or invocation_prefix:
        lines = []
        if missing_assignments:
            lines.append("  settings the runner expects and the script no longer has:")
            lines += [f"    - {m}" for m in missing_assignments]
        if missing_tokens:
            lines.append("  invocation tokens the runner expects and the script no longer passes:")
            lines += [f"    - {m}" for m in missing_tokens]
        if extra_tokens:
            lines.append("  tokens the script now passes and the runner does NOT reproduce:")
            lines += [f"    + {m}" for m in extra_tokens]
        if unknown_expansions:
            lines.append("  shell expansions whose contents this runner cannot see, so it cannot know")
            lines.append("  whether it reproduces them:")
            lines += [f"    ? {m}" for m in unknown_expansions]
        if invocation_prefix:
            lines.append("  something now runs BEFORE xcodebuild, so the canonical lane may use a")
            lines.append("  different environment or toolchain than this runner's ambient one:")
            lines.append(f"    ! {invocation_prefix}")
        raise Refusal(
            f"{CANONICAL_SCRIPT} has drifted from what this runner reproduces, so the battery would "
            "measure a differently-configured build than the canonical lane:\n"
            + "\n".join(lines)
            + "\n\nReconcile CANONICAL_TOKENS / CANONICAL_ASSIGNMENTS / CANONICAL_EXPANSIONS and "
            "the Lane class with the script, deliberately. Do not delete the guard to make this go "
            "away."
        )


def check_no_dev_app(worktree: Path):
    """Its own function so the self-test can drive it directly rather than through every case."""
    if DEV_APP_PATTERN != "EnviousWispr Local.app/Contents/MacOS/EnviousWispr":
        print(f"NOTE: dev-app check is using a non-default pattern: {DEV_APP_PATTERN!r}",
              file=sys.stderr)
    rc, out = run(["pgrep", "-f", DEV_APP_PATTERN], cwd=worktree)
    if rc == 0 and out.strip():
        raise Refusal(
            "A dev app is running. Its writes to ~/Library/Logs/EnviousWispr/app.log corrupt the\n"
            "AppLogger tests, and those failures score as mutants CAUGHT when nothing detected the\n"
            "sabotage (#2080). Stop every dev instance across ALL worktrees and re-run.\n"
            f"  pids: {' '.join(out.split())}"
        )


def preflight(worktree: Path):
    check_canonical_settings(worktree)
    check_no_dev_app(worktree)
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
    # Body AND comments. github-light.md FACT: finding-issues records that in this repo "title/body
    # often stale; adopted plan lives in comments" — so a recipe posted as a comment is the NORMAL
    # case, not a mistake, and reading only the body would refuse correctly-filed work. The
    # exactly-one rule below is what keeps that from being ambiguous, and it now spans both.
    # Never bare `--comments`: in a non-TTY pipe it drops the body and prints nothing for zero
    # comments, so a piped read of a recipe-in-body issue would look empty (cli/cli#2462).
    rc, out = run(
        ["gh", "issue", "view", str(number), "--json", "body,comments",
         "--jq", '.body, (.comments[]?.body)'],
        cwd=worktree,
    )
    if rc != 0:
        raise Refusal(f"could not read issue #{number}: {out.strip()[:300]}")
    blocks = FENCE_RE.findall(out)
    if not blocks:
        raise Refusal(
            f"issue #{number} carries no ```json recipe block in its body or any comment. A "
            "test-hardening issue without its recipe cannot be acted on cold, which is the whole "
            "reason the recipe is written into the issue."
        )
    if len(blocks) > 1:
        raise Refusal(
            f"issue #{number} carries {len(blocks)} ```json blocks across its body and comments. "
            "Exactly one, or the run and the issue disagree about what was tested — edit the "
            "superseded one out rather than adding a newer block beside it."
        )
    return blocks[0]


def load_recipes(path: Path, worktree: Path, raw: str = None):
    where = "the issue body" if raw is not None else str(path)
    if raw is None:
        # A missing or unreadable file is a preflight refusal like any other. Left as an OSError it
        # escapes as a traceback with exit 1, which the documented exit codes reserve for "a row
        # SURVIVED" — the one status an unattended caller must not confuse with a real result.
        try:
            raw = path.read_text()
        except OSError as exc:
            raise Refusal(f"cannot read the recipe file {path}: {exc}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise Refusal(f"the recipe in {where} is not valid JSON: {exc}")
    # Valid JSON is not the expected SHAPE. `[]`, `{"rows": [1]}`, or a row that is a string all parse
    # fine and then raise AttributeError deep in the loop. In the unattended --from-issue path that
    # surfaces as a traceback rather than a refusal, which is the difference between "the recipe is
    # wrong" and "the battery is broken".
    if not isinstance(data, dict):
        raise Refusal(f"the recipe in {where} must be a JSON object, got {type(data).__name__}.")
    if "rows" in data and not isinstance(data["rows"], list):
        raise Refusal(f"the recipe in {where} has a 'rows' that is not a list.")
    default_suite = data.get("suite_default")
    rows = data.get("rows") or []
    if not rows:
        raise Refusal(f"{where} declares no rows.")
    for i, row in enumerate(rows, 1):
        if not isinstance(row, dict):
            raise Refusal(f"row {i} is a {type(row).__name__}, not an object.")
        for field in ("label", "file", "anchor", "replacement", "expect_fail"):
            if field not in row or row[field] is None:
                raise Refusal(f"row {i} is missing required field '{field}'.")
            if not isinstance(row[field], str):
                raise Refusal(
                    f"row {i} field '{field}' must be a string, got {type(row[field]).__name__}.")
            # `replacement` may legitimately be EMPTY: deleting an anchored statement or block is one
            # of the most natural mutations there is, and a truthiness check classified that correctly
            # typed value as missing. Every other field empty is still a mistake.
            if field != "replacement" and not row[field]:
                raise Refusal(f"row {i} is missing required field '{field}'.")
        row.setdefault("suite", default_suite)
        if not row["suite"]:
            raise Refusal(f"row {i} has no suite and no suite_default is set.")
        if not isinstance(row["suite"], str):
            raise Refusal(
                f"row {i} suite must be a string, got {type(row['suite']).__name__}. "
                "(A non-string here used to raise TypeError and exit 1, which the exit codes reserve "
                "for a row SURVIVING.)"
            )
        if "/" not in row["suite"]:
            raise Refusal(
                f"row {i} suite '{row['suite']}' is not target-qualified. It must read "
                "'EnviousWisprTests/<SuiteName>', and <SuiteName> comes from the @Suite "
                "declaration, never from the filename."
            )
        # An absolute path, a `..`, or a symlink pointing out of the tree would let a recipe mutate a
        # file the battery was never scoped to — and with --from-issue the recipe is data written by
        # whoever authored the issue. Resolve BOTH sides and require containment; resolving is what
        # catches the symlink, since a lexical check cannot.
        if Path(row["file"]).is_absolute():
            raise Refusal(f"row {i} file must be repo-relative, got an absolute path: {row['file']}")
        target = (worktree / row["file"]).resolve()
        wt = worktree.resolve()
        if not (target == wt or wt in target.parents):
            raise Refusal(
                f"row {i} resolves OUTSIDE the worktree and will not be mutated:\n"
                f"  recipe says: {row['file']}\n"
                f"  resolves to: {target}\n"
                f"  worktree:    {wt}"
            )
        if not target.is_file():
            raise Refusal(f"row {i} target does not exist: {row['file']}")
        row["_resolved"] = str(target)
        if row["anchor"] == row["replacement"]:
            raise Refusal(f"row {i} anchor and replacement are identical — it would mutate nothing.")
        # Check anchor presence and uniqueness HERE, against the clean tree, so a bad recipe costs
        # nothing. The row re-checks at apply time because an earlier row may share the file.
        occurrences = target.read_text().count(row["anchor"])  # target is the resolved, contained path
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
        try:
            count, failures, compiled, log, rc, elapsed = lane.run_suite(suite, tag)
        except _LaneTimedOut as exc:
            problems.append(f"{suite}: {exc}")
            continue
        if not compiled:
            problems.append(f"{suite}: did not compile ({log})")
        elif count is None or count < 1:
            problems.append(
                f"{suite}: executed ZERO tests and REPORTED SUCCESS. Nothing was mutated. The "
                f"filter names a suite that does not exist here — renamed, moved to another target, "
                f"or read off a filename rather than off its @Suite declaration. Left unchecked this "
                f"is the worst failure the battery has, because every row would score SURVIVED ({log})"
            )
        elif rc != 0 or failures:
            problems.append(f"{suite}: {len(failures)} failing on an unmutated tree ({log})")
        else:
            print(f"    baseline {phase}: {suite} — {count} tests green in {elapsed:.0f}s")
    return problems


def main_for_test(recipes: Path, worktree: Path):
    """Entry point for the self-test's stubbed-lane cases. Same code path as the CLI."""
    return main(["--recipes", str(recipes), "--worktree", str(worktree)])


def main(argv=None):
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
    args = ap.parse_args(argv)
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

    _install_restore_on_signal()
    print(f"\n[2/3] {len(rows)} mutation(s), one at a time")
    results = []
    for i, row in enumerate(rows, 1):
        target = Path(row["_resolved"])
        backup = target.with_suffix(target.suffix + ".mutbak")
        tag = f"row{i:02d}"
        verdict, detail = "ERROR", "did not run"
        shutil.copy2(target, backup)
        _ACTIVE_RESTORES[target] = backup
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
                    try:
                        count, failures, compiled, log, rc_run, elapsed = lane.run_suite(
                            row["suite"], tag)
                    except Exception as exc:  # noqa: BLE001 — any lane failure is this row's problem
                        raise _RowFailed(f"the lane raised {type(exc).__name__}: {exc}") from exc
                    if not compiled:
                        detail = f"mutant does not compile — proves nothing about the test ({log})"
                    elif count is None or count < 1:
                        detail = (
                            f"executed ZERO tests, so this row is a verdict about nothing. Either the "
                            f"suite was renamed and the recipe is stale, or the filter never matched. "
                            f"Read the name off its @Suite declaration, never off the filename ({log})"
                        )
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
        except _RowFailed as exc:
            detail = str(exc)
        finally:
            shutil.copy2(backup, target)
            # `copy2` restores the original MODIFICATION TIME as well as the bytes, and that is a bug
            # here rather than a nicety. xcodebuild's incremental check is timestamp-based against a
            # deliberately WARM DerivedData: if the replacement happened to be the same SIZE as the
            # anchor, the restored file is byte-identical AND older than the object compiled from the
            # MUTANT, so the next row — or the closing baseline — can run against mutant code while
            # every check here reports a clean tree. That fails toward false CAUGHT and false green,
            # silently, for every row after it. Stamp the restore as NOW so the next build recompiles.
            os.utime(target, None)
            if not filecmp.cmp(backup, target, shallow=False):
                verdict, detail = "ERROR", "RESTORE FAILED — the tree is dirty, stop and inspect"
            else:
                backup.unlink()
            _ACTIVE_RESTORES.pop(target, None)
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
