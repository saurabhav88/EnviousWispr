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
    8. TEST LOGS ARE PRIVATE TO EACH LANE. The canonical entry point gives the test process its own
       AppLogger directory, so a running dev app cannot corrupt a test receipt and falsely score a
       mutant as CAUGHT (#2279).

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
          "expect_fail": "theGuard()"                    // FULL name, never a prefix: see below
        }
      ]
    }

    `expect_fail` is the backward-compatible single-guard form. A row that needs to
    describe a JOINT expectation uses these fields instead:

        "must_fire": ["theGuard()"],
        "must_not_fire": ["theIndependentControl()"]

    `must_fire` is the EXACT set of tests that must newly fail. An empty set is an
    expected survivor: no test in the suite may newly fail. `must_not_fire` names
    important silent controls and requires their status to stay unchanged. A row
    supplies either `expect_fail` or `must_fire`, never both.

    A mixed mechanical/human issue may instead carry one fenced `mutation-recipe`
    Markdown table. Run `scripts/mutation-battery.py --print-markdown-template` for
    the exact header. Mechanical rows use `<br>` between test names and `&#124;` for
    a literal pipe. A semantic instruction that cannot be an anchor/replacement pair
    is mode `human`; it is reported as DEFERRED and is never guessed into source code.

    `expect_fail` NAMES A TEST AND IS MATCHED EXACTLY — it is not a substring of the
    failure line. Any one of the three spellings the result bundle carries will do:
    the `Suite/function()` identifier, the bare `function()`, or the display name in
    `@Test("...")`. A parameterized test keeps its `(_:)`. A prefix is refused before
    anything is mutated, with the full name it was probably meant to be.

USAGE
    scripts/mutation-battery.py --from-issue 2156        # the overnight form: recipe from the issue
    scripts/mutation-battery.py --recipes recipes.json
    scripts/mutation-battery.py --recipes recipes.json --row 3      # one row, for iterating on a fix
    scripts/mutation-battery.py --recipes recipes.json --dry-run    # validate + baseline, no mutations
    scripts/mutation-battery.py --recipes recipes.json --validate-only  # no xcodebuild at all

EXIT CODES
    0  every row matched its expectation, baseline green before and after, every file byte-identical
    1  at least one expectation missed, SURVIVED, ERRORED, or a restore failed
    2  usage / preflight refusal (the battery never started)
"""

import argparse
import filecmp
import fcntl
import functools
import html
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

TEST_COUNT_RE = re.compile(r"Test run with (\d+) test")
# Swift Testing prints ✘ for a KNOWN issue too, and the lane still exits 0. A test wrapped in
# `withKnownIssue` is explicitly configured NOT to go red, so crediting it with detecting a mutation is
# a false CAUGHT — the direction that fails toward confidence. Matched separately and excluded.
KNOWN_ISSUE_RE = re.compile(r"✘ .*[Kk]nown issue.*")
FAILURE_LINE_RE = re.compile(r"✘ .*")
# Swift Testing's two verdict shapes, plus the SUITE line that must never be read as a test failing.
#   ✘ Test "display name" recorded an issue at File.swift:12:3: Expectation failed: ...
#   ✘ Test functionName() recorded an issue ...
#   ✘ Suite "SuiteName" failed after 0.1 seconds.
# A display name may CONTAIN quotes — Swift Testing prints them unescaped, and this repo has three:
#   @Test("founder repro: \"Other apps.\" (2 words, punctuation kept) bypasses")
# so terminating on the first inner quote truncated the identity to `founder repro: `, which then
# matched nothing and made those tests unusable in a recipe. Terminate on the closing quote that is
# FOLLOWED BY a verdict verb instead — greedy up to the last one. Cloud review, PR #2158.
_VERDICT_VERB = r'(?:recorded|passed|failed|skipped)'
TEST_VERDICT_RE = re.compile(
    r'^✘\s+Test\s+(?:"(?P<quoted>.*)"\s+' + _VERDICT_VERB + r'|(?P<bare>[A-Za-z_][\w]*)\s*\()')
# The same identity in the same position, for EITHER outcome — used to enumerate what a clean baseline
# actually ran, so a recipe naming a test that does not exist is refused before anything is mutated.
TEST_NAME_ANY_RE = re.compile(
    r'^[✔✘]\s+Test\s+(?:"(?P<quoted>.*)"\s+' + _VERDICT_VERB + r'|(?P<bare>[A-Za-z_][\w]*)\s*\()',
    re.MULTILINE)
SUITE_VERDICT_RE = re.compile(r'^✘\s+Suite\s')
COMPILE_ERROR_RE = re.compile(r"^.*?: error: ", re.MULTILINE)


CANONICAL_SCRIPT = "scripts/xcode-test.sh"
# WHAT A RECIPE MAY MUTATE — an ALLOW-list, deliberately, and the second attempt at this.
#
# Review round 6 found a recipe could target a Tuist input; the fix denied those by name. Round 7 then
# found `Tests/` reachable the same way — the identical defect at a site the deny-list did not
# enumerate. Two rounds of one shape is the signal to stop extending a list and INVERT it
# (codex-cli.md RULE: enumerate-the-class-when-review-rounds-repeat). The question is no longer "which
# paths are dangerous", which is unbounded and was wrong once per round, but "where is a mutation
# MEANINGFUL", which has one answer: production Swift the filtered lane actually executes.
#
# What a deny-list would have had to keep growing to cover, and why none of it is a mutation target:
#   Tests/**       breaking the test makes `expect_fail` go red and the row reports CAUGHT. That proves
#                  only that breaking a test breaks it, while the report claims a PRODUCTION mutation
#                  was detected — a false CAUGHT, the exact vacuity this tool exists to prevent.
#   Project.swift, Workspace.swift, Tuist.swift, Package.swift, Tuist/**
#                  changing project inputs is outside a production-code mutation's scope; the canonical
#                  test command owns generation and project configuration.
#   scripts/**     including this runner: a battery mutating its own harness reports on itself.
#   workers/**, website/**
#                  real code, but nothing an `xcodebuild test` lane executes, so every row reports
#                  SURVIVED regardless of the test's quality.
MUTABLE_ROOTS = ("Sources/",)
# A row's restore lives in a `finally`, and Python's DEFAULT action for SIGTERM does not run it: the
# process dies where it stands, leaving the production file MUTATED and a .mutbak beside it. That is the
# worst state this tool can leave behind, and an overnight battery is exactly the thing someone cancels
# — a terminal closing, a session ending, a job being killed. So the restore is also registered here,
# outside the try/finally, and runs from the signal handler.
_ACTIVE_RESTORES = {}


def _prune_empty_backup_parents(backup: Path, worktree: Path):
    """Remove only empty backup directories after a verified restore."""
    root = worktree / "build" / "mutation-battery" / "backups"
    parent = backup.parent
    while parent != root:
        try:
            parent.rmdir()
        except OSError:
            return
        parent = parent.parent
    try:
        root.rmdir()
    except OSError:
        pass


def backup_path(worktree: Path, tag: str, target: Path) -> Path:
    """Keep backups outside Sources/ so a mutation cannot change project inputs."""
    relative_target = target.resolve().relative_to(worktree.resolve())
    return (worktree / "build" / "mutation-battery" / "backups" / tag
            / relative_target.with_suffix(relative_target.suffix + ".mutbak"))


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
        # Ignore further signals FIRST. A second one arriving inside the restore loop re-enters this
        # handler and reaches the re-raise below before the remaining targets are copied back, so a
        # double Ctrl-C would leave files mutated.
        for other in _HANDLED_SIGNALS:
            signal.signal(other, signal.SIG_IGN)
        # Reap the lane FIRST. Restoring the file while xcodebuild's group survives leaves an orphan
        # running mutant tests and writing the shared DerivedData after we are gone — the file looks
        # recovered and the machine is not. Fixing only the timeout path last round missed this exit.
        _reap_active_lane()
        _restore_active(f"signal {signum}")
        # Re-raise with the default action so the exit status still says we were killed.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for sig in _HANDLED_SIGNALS:
        signal.signal(sig, handler)


def read_recipe_target(path: Path, what: str) -> str:
    """Read a file a RECIPE named, converting every failure into a Refusal.

    A recipe is data someone else wrote, so every way its target can fail to read is a bad recipe
    rather than a broken battery: missing, unreadable, or not text at all. `Sources/` holds binary
    resources too, and `read_text` on a .wav raises UnicodeDecodeError — a ValueError, so an
    OSError-only guard misses it and the unattended command emits a traceback with exit 1, the status
    reserved for a SURVIVED row.
    """
    try:
        return path.read_text()
    except UnicodeDecodeError:
        raise Refusal(
            f"{what} is not text: {path}\n"
            "A mutation edits source. Binary resources live under Sources/ too, and they are not "
            "mutation targets — nothing in a filtered Swift lane reads them as code."
        )
    except OSError as exc:
        raise Refusal(f"cannot read {what}: {path}: {exc}")


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


# The process group of the lane currently running, or None. Registered before the lane starts and
# cleared when it ends, so EVERY exit path — timeout, cancellation, an unexpected exception — can reap
# it. Fixing only the timeout path last round left cancellation orphaning the group; the defect was
# never "the timeout is wrong", it was "an exit path does not reap".
# One definition, so the spawn mask, the installer and the re-entrancy guard cannot drift apart.
_HANDLED_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT)

_ACTIVE_LANE_PGID = None
_ACTIVE_LANE_PROC = None
GRACEFUL_TERMINATION_SECONDS = 10


def _reap_active_lane():
    """Ask the canonical wrapper to clean up, then guarantee its whole process group is gone."""
    global _ACTIVE_LANE_PGID, _ACTIVE_LANE_PROC
    pgid, proc = _ACTIVE_LANE_PGID, _ACTIVE_LANE_PROC
    _ACTIVE_LANE_PGID = None
    _ACTIVE_LANE_PROC = None
    if pgid is None:
        return False
    try:
        # xcode-test.sh translates TERM into a normal exit, which runs its EXIT trap and releases any
        # SwiftPM seed lock. SIGKILL here skips that cleanup and strands every other worktree on a
        # cache miss, so it is a bounded fallback only.
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return False
    if proc is None:
        return True
    try:
        proc.wait(timeout=GRACEFUL_TERMINATION_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    # The wrapper can exit cleanly while a hung test descendant remains in the group. Always sweep the
    # group after its cleanup window; ProcessLookupError is the normal proof that nothing survived.
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    return True


def run(cmd, cwd, log_path=None, timeout=None, env=None):
    """Run a command, optionally teeing to a per-row log. Never the shared fixed log path.

    On timeout this kills the whole PROCESS GROUP, not just the direct child. `xcodebuild` spawns the
    test runner as a descendant, so killing only the parent leaves a hung mutant test process alive —
    still holding the shared DerivedData and still writing logs while later rows run, which corrupts
    their verdicts long after the source has been restored. The battery would look like it recovered.
    Cloud review, PR #2158.
    """
    global _ACTIVE_LANE_PGID, _ACTIVE_LANE_PROC
    # BLOCK the handled signals across spawn-and-register. `Popen` creates the child in its own session
    # BEFORE the pgid is stored, so a signal landing in that window sees `_ACTIVE_LANE_PGID` as None,
    # re-raises, and leaves an isolated tuist/xcodebuild group running after the battery exits. The
    # window is microseconds and the failure is SILENT — an orphan holding the shared DerivedData with
    # nothing reporting it — which is the combination that earns a fix rather than a recorded limit.
    _blocked = signal.pthread_sigmask(signal.SIG_BLOCK, _HANDLED_SIGNALS)
    try:
        proc = subprocess.Popen(
            cmd, cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=True,   # its own process group, so the kills below reach descendants
            env=env,
        )
        _ACTIVE_LANE_PROC = proc
        try:
            _ACTIVE_LANE_PGID = os.getpgid(proc.pid)
        except ProcessLookupError:
            _ACTIVE_LANE_PGID = None
    finally:
        # Restore rather than unconditionally unblock: never widen the caller's mask.
        signal.pthread_sigmask(signal.SIG_SETMASK, _blocked)
    try:
        out, _ = proc.communicate(timeout=timeout)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        # End the GROUP, then re-raise. The canonical script gets a bounded TERM window to release its
        # seed lock before the fallback kill, while the row keeps the existing timeout-as-ERROR contract.
        if not _reap_active_lane():
            proc.kill()
        try:
            out, _ = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            out = ""
        if log_path is not None:
            # APPEND. This used to overwrite what was captured before the timeout, throwing away the
            # only record of which build or test operation hung — on the one path where it matters.
            with open(log_path, "a") as fh:
                fh.write((out or "")
                         + f"\n[mutation-battery] timed out after {timeout}s; group terminated\n")
        raise
    finally:
        _ACTIVE_LANE_PGID = None
        _ACTIVE_LANE_PROC = None
    if log_path is not None:
        Path(log_path).write_text(out or "")
    return rc, out or ""


def classify_lane_output(out: str):
    """Split a lane's output into (executed count, REAL failure lines).

    Extracted so it can be tested without a build: the self-test's stubbed lane replaces `run_suite`
    wholesale, so anything parsed inside it is unreachable from those cases — a check aimed there would
    pass while testing nothing.

    Swift Testing prints ✘ for a KNOWN issue as well, and the lane still exits 0. A test wrapped in
    `withKnownIssue` is explicitly configured NOT to go red, so counting that line as a failure credits
    it with detecting a mutation it was told to tolerate — a false CAUGHT.
    """
    counts = [int(n) for n in TEST_COUNT_RE.findall(out)]
    count = sum(counts) if counts else None
    known = set(KNOWN_ISSUE_RE.findall(out))
    failures = [ln for ln in FAILURE_LINE_RE.findall(out) if ln not in known]
    return count, failures


def failed_test_identities(failure_lines):
    """The set of TEST identities that failed — never suites, never message text.

    `expect_fail` used to be matched with `in` against the whole ✘ line, which carries the display
    name, the source path AND the expectation message. Three false-CAUGHT paths followed from that:
    a sibling whose name merely CONTAINS the expected one; a short phrase matching some other test's
    message or file path; and `✘ Suite "X" failed`, which Swift Testing prints whenever ANY member
    fails, matching any expect_fail that is a substring of the suite name.

    Identity is the quoted display name, or the bare function name for an unnamed @Test.
    """
    identities = set()
    for line in failure_lines:
        line = line.strip()
        if SUITE_VERDICT_RE.match(line):
            # A suite verdict is an aggregate, never evidence about one test. REDUNDANT today, and
            # deliberately kept: TEST_VERDICT_RE already refuses to match a `✘ Suite` line, so a
            # mutation control on this branch alone cannot fail — proven, not assumed. It stays as the
            # explicit statement of intent, so loosening TEST_VERDICT_RE later cannot silently let
            # suite lines through.
            continue
        m = TEST_VERDICT_RE.match(line)
        if m:
            identities.add(m.group("quoted") if m.group("quoted") is not None else m.group("bare"))
    return identities


# ---------------------------------------------------------------------------
# RESULT BUNDLE — the structured verdict, replacing console scraping (#2225,
# #2227, #2228).
#
# `xcodebuild test` writes an `.xcresult` on EVERY run whether or not
# `-resultBundlePath` is passed; the flag only makes it ADDRESSABLE, and it
# costs nothing measurable. Three defects are unreachable from the bundle and
# unavoidable from the console:
#
#   #2225  a parameterized test's console verdict has no addressable name. The
#          bundle gives `nodeIdentifier = Suite/function(_:)`. Measured on
#          ProviderStatusMappingTests: 35 cases, one parameterized, its two
#          `Arguments` children carrying results and `nodeIdentifier: None`.
#   #2227  a CRASH prints ZERO failure marks, so the console cannot see it at
#          all. The bundle records `result: Failed` with a `Failure Message`
#          child reading `Crash: xctest at <Suite>.<test>()`.
#   #2228  xctest interleaves its stderr into the same stream, so a verdict line
#          need not start at column 0 and line-anchored regexes lose a DIFFERENT
#          set every run. A JSON field cannot be interleaved.
#
# NAME YOUR OWN PATH. The default `<derivedData>/Logs/Test/` accumulates one
# bundle per run and is shared, so "newest wins" there carries the same
# concurrent-writer hazard as the fixed log path this repo already documents.
#
# FAILS CLOSED. A missing bundle, a tool error, or an unparseable payload RAISES.
# It never falls back to the console: a half-failed measurer that returns a
# plausible number is the defect this section exists to remove, and a silent
# fallback would reintroduce it under a structured name.

BUNDLE_TOOL_TIMEOUT_SECONDS = 120


class BundleUnreadable(Exception):
    """The result bundle could not be read. Never downgraded to a console parse."""


class SuiteResults:
    """Every Test Case in one run, indexed by every name a recipe may legally use.

    `by_id` is the authority: one entry per test, keyed by `nodeIdentifier`
    (`Suite/function()`), which is unique and stable. `aliases` maps the other
    spellings a recipe may carry — the display name, the bare function name, and
    the identifier itself — onto those ids. A recipe naming a display name shared
    by two suites therefore resolves to TWO ids and is refused as ambiguous
    rather than silently matching one.
    """

    def __init__(self, by_id, aliases, crashed):
        self.by_id = by_id            # nodeIdentifier -> "Passed" | "Failed" | ...
        self.aliases = aliases        # spelling -> set(nodeIdentifier)
        self.crashed = crashed        # nodeIdentifier -> crash message

    def __len__(self):
        return len(self.by_id)

    def resolve(self, spelling: str):
        """-> set of nodeIdentifiers a recipe's `expect_fail` names. Never a substring match.

        Substring matching is what made the console path credit a sibling whose
        name merely CONTAINS the expected one; the bundle has exact keys, so the
        looser form has no reason to exist here.
        """
        return set(self.aliases.get(spelling, ()))

    def failed(self):
        return {i for i, r in self.by_id.items() if r not in ("Passed", "Skipped", "Expected Failure")}


def _walk_nodes(node, out_cases):
    if node.get("nodeType") == "Test Case":
        out_cases.append(node)
        # A parameterized case's `Arguments` children carry their own results and
        # `nodeIdentifier: None`, so they are NOT separately addressable. The
        # function's own aggregate result is what a recipe can name. Stated as a
        # chosen limit: per-argument targeting would need a key the bundle does
        # not provide.
        return
    for kid in node.get("children") or ():
        _walk_nodes(kid, out_cases)


def read_result_bundle(bundle: Path) -> "SuiteResults":
    if not bundle.exists():
        raise BundleUnreadable(
            f"no result bundle at {bundle}. `xcodebuild test` writes one on every run, so its "
            f"absence means the lane did not reach the test phase — check for a compile error.")
    argv = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)]
    try:
        proc = subprocess.run(argv, capture_output=True, text=True,
                              timeout=BUNDLE_TOOL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise BundleUnreadable(f"`xcresulttool` ran past {BUNDLE_TOOL_TIMEOUT_SECONDS}s on {bundle}")
    if proc.returncode != 0:
        # The deprecated spelling (`get test-report tests`) refuses with a message
        # naming --legacy. Surface the tool's own words rather than guessing.
        raise BundleUnreadable(
            f"`xcresulttool` exited {proc.returncode} on {bundle}:\n{proc.stderr.strip()[:400]}")
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise BundleUnreadable(f"`xcresulttool` output was not JSON ({exc}) for {bundle}")

    roots = payload.get("testNodes")
    if not isinstance(roots, list):
        raise BundleUnreadable(f"no `testNodes` array in the bundle payload for {bundle}")

    cases = []
    for root in roots:
        _walk_nodes(root, cases)
    if not cases:
        raise BundleUnreadable(
            f"the bundle at {bundle} contains ZERO Test Case nodes. An empty result is not a "
            f"passing result — a filter that matched nothing looks exactly like this.")

    by_id, aliases, crashed = {}, {}, {}
    for case in cases:
        ident = case.get("nodeIdentifier")
        if not ident:
            raise BundleUnreadable(
                f"a Test Case in {bundle} has no nodeIdentifier; the bundle shape has changed and "
                f"every verdict below it would be unattributable")
        by_id[ident] = case.get("result")
        for spelling in (ident, case.get("name"), ident.split("/")[-1]):
            if spelling:
                aliases.setdefault(spelling, set()).add(ident)
        for kid in case.get("children") or ():
            if kid.get("nodeType") == "Failure Message":
                text = (kid.get("name") or "")
                if text.startswith("Crash:"):
                    crashed[ident] = text
    return SuiteResults(by_id, aliases, crashed)


# --- the row verdict -------------------------------------------------------
#
# A DIFF AGAINST THE UNMUTATED BASELINE, not "did the named test go red".
#
# The console could afford only the second question, because it yielded one
# count and a set of failure LINES. The bundle yields the status of EVERY test
# on a run already being paid for, so the row can finally distinguish a guard
# doing its job from three things that look identical at the console:
#
#   * a mutant that changed nothing (a no-op edit, or a line the named test
#     never executes) — today scored exactly like a working guard;
#   * a row whose named test was ALREADY failing, which proves nothing;
#   * a different test catching the mutation, which is real information and is
#     not evidence about the named guard.
#
# STATED LIMIT, because a verdict that implies more than it proves is the defect
# class this tool exists to police: this diff is computed inside ONE suite run
# and cannot see a cause OUTSIDE the process. A test that reddens for an
# environmental reason — a concurrent writer, a shared resource, a machine
# state — presents here as a genuine catch. Peer-measured 2026-08-20: a
# three-arm control whose negative arm failed for exactly that reason, with the
# mutation real and the test genuinely red. Nothing in this function closes it;
# only a two-way control on the unmutated tree does.

VERDICT_CAUGHT = "CAUGHT"
VERDICT_CAUGHT_ELSEWHERE = "CAUGHT-ELSEWHERE"
VERDICT_SURVIVED = "SURVIVED"
# NOT "SURVIVED-NOOP". An unchanged test set has TWO causes and result statuses
# cannot tell them apart: the mutant was a no-op or unreachable, or it executed
# and changed behaviour NO ASSERTION COVERS — the ordinary surviving mutant this
# whole tool exists to surface. Naming the first told operators to re-aim the
# recipe precisely when the TEST was at fault.
VERDICT_NOOP = "SURVIVED-UNOBSERVED"
VERDICT_INVALID = "INVALID-ROW"
VERDICT_EXPECTED = "EXPECTED"
VERDICT_MISMATCH = "EXPECTATION-MISMATCH"


# WHAT TO DO ABOUT A ROW DEPENDS ON WHY IT IS NOT A CATCH, and the old report
# collapsed every non-catch into "needs work" — which sent an overnight session to
# tighten a test when the RECIPE was the problem.
#
# MODULE LEVEL SO IT CAN BE TESTED. It lived inside `main()`, reachable only after a
# full lane, so nothing rendered it and the self-test could not see it. That is why
# the categorical "re-aim the RECIPE" claim survived HERE for a whole review round
# after being removed from `classify_row`: the classifier is heavily covered and the
# text the operator actually acts on had no coverage at all.
#
# A VERDICT WHOSE CAUSE THE STATUSES CANNOT DETERMINE MUST NOT BE GIVEN A SINGLE
# REMEDIATION HERE. `classify_row` owns that judgement; a second sentence of guidance
# is a second owner, and it is the one that drifted.
WHAT_IT_MEANS = {
    VERDICT_EXPECTED: "the declared fire and silence sets matched",
    VERDICT_NOOP: "no test changed status; the two causes, and how to tell them apart, are below",
    VERDICT_CAUGHT_ELSEWHERE: "a different test caught it; this row says nothing about its own guard",
    VERDICT_INVALID: "the row cannot prove anything as written",
    VERDICT_SURVIVED: "the test did not detect the mutation",
    VERDICT_MISMATCH: "the suite did not match the row's declared fire and silence sets",
    "ERROR": "the row did not produce a verdict",
}


def explain_verdict(verdict):
    """-> the one-line meaning shown beneath a non-catch row.

    FAILS LOUD on an unmapped verdict. `WHAT_IT_MEANS.get(verdict, "")` rendered a
    BLANK line for one, so adding a verdict constant would have silently produced a
    report with no explanation under it — an empty string reading as an answer, which
    is the defect class this whole tool exists to police.
    """
    try:
        return WHAT_IT_MEANS[verdict]
    except KeyError:
        raise AssertionError(
            f"verdict {verdict!r} has no entry in WHAT_IT_MEANS, so the report would print a blank "
            f"line where the operator's guidance belongs. Add one when adding a verdict.")


def classify_row(baseline: "SuiteResults", mutated: "SuiteResults", expect_fail: str):
    """-> (verdict, detail). Never raises on a legitimate result; raises only on a broken premise."""
    # THE UNION, never `mutated or baseline`. With `or`, a name that is ambiguous
    # in the BASELINE resolves to a singleton whenever execution stopped before
    # the second test appeared in the mutated bundle — so the ambiguity check is
    # skipped exactly when the run was cut short, and the row is graded against
    # whichever of the two happened to run.
    targets = mutated.resolve(expect_fail) | baseline.resolve(expect_fail)
    if not targets:
        return VERDICT_INVALID, (
            f"`{expect_fail}` names no test in this suite. The bundle keys are exact — a display "
            f"name, a bare function name, or a `Suite/function()` identifier — so a near miss is a "
            f"wrong recipe rather than a missed match.")
    if len(targets) > 1:
        return VERDICT_INVALID, (
            f"`{expect_fail}` is ambiguous: it names {len(targets)} tests "
            f"({', '.join(sorted(targets))}). Use the `Suite/function()` identifier.")
    target = targets.pop()

    base_result = baseline.by_id.get(target)
    if base_result is None:
        return VERDICT_INVALID, (
            f"`{target}` did not run on the unmutated tree, so this row has no baseline to differ "
            f"from and cannot prove anything.")
    if base_result not in ("Passed", "Expected Failure"):
        return VERDICT_INVALID, (
            f"`{target}` was already {base_result} BEFORE the mutation. A row whose guard is red on "
            f"a clean tree cannot demonstrate that the guard binds.")

    changed = {
        i for i in set(baseline.by_id) | set(mutated.by_id)
        if baseline.by_id.get(i) != mutated.by_id.get(i)
    }
    # A CATCH REQUIRES A FAILURE, NOT MERELY A DIFFERENCE. Passed -> Skipped, or a
    # test vanishing because execution stopped early, is a status change and is
    # not another guard going red. Keying "something else caught it" on any
    # difference credits a disappearance as detection.
    newly_failed = mutated.failed() - baseline.failed()
    target_failed = target in mutated.failed()
    crash_note = f" (crash: {mutated.crashed[target]})" if target in mutated.crashed else ""

    if target_failed and changed == {target}:
        return VERDICT_CAUGHT, f"`{target}` went {base_result} -> {mutated.by_id[target]}{crash_note}"
    if target_failed:
        others = sorted(changed - {target})
        return VERDICT_CAUGHT, (
            f"`{target}` went {base_result} -> {mutated.by_id[target]}{crash_note}; "
            f"{len(others)} other test(s) also changed status ({', '.join(others[:5])}"
            f"{' …' if len(others) > 5 else ''}). The guard fired, and the mutation is not "
            f"isolated to it.")
    if not changed:
        return VERDICT_NOOP, (
            f"NOT ONE test changed status. Two causes produce this and the statuses cannot "
            f"separate them: (1) the suite has no assertion for what the mutation changed — an "
            f"ordinary surviving mutant, and `{target}` needs tightening; (2) the mutation was a "
            f"no-op, or `{target}` never executes that line — the RECIPE needs re-aiming. Read the "
            f"mutated line and ask whether the named test can reach it before deciding which.")
    others_failed = sorted(newly_failed - {target})
    if others_failed:
        return VERDICT_CAUGHT_ELSEWHERE, (
            f"`{target}` stayed {base_result}, but {len(others_failed)} other test(s) newly FAILED "
            f"({', '.join(others_failed[:5])}). Something else caught this mutation; that is not "
            f"evidence that `{target}` is the guard.")
    # Statuses moved, but nothing newly failed — a test was skipped, or vanished
    # because execution stopped early. That is not a catch by anyone, and calling
    # it one would credit a disappearance as detection.
    return VERDICT_SURVIVED, (
        f"`{target}` stayed {base_result} and NOTHING newly failed, though {len(changed)} test(s) "
        f"changed status ({', '.join(sorted(changed)[:5])}) — skipped, or absent from the mutated "
        f"run. No guard went red, so the mutation was not detected; check whether the run was cut "
        f"short before reading this as a weak test.")


def _resolve_expectation_names(baseline, mutated, names):
    """Resolve recipe spellings once, failing closed on missing or ambiguous names."""
    resolved = {}
    for name in names:
        targets = mutated.resolve(name) | baseline.resolve(name)
        if not targets:
            return None, f"`{name}` names no test in this suite."
        if len(targets) > 1:
            return None, (
                f"`{name}` is ambiguous: it names {len(targets)} tests "
                f"({', '.join(sorted(targets))}). Use the `Suite/function()` identifier.")
        target = next(iter(targets))
        base_result = baseline.by_id.get(target)
        if base_result not in ("Passed", "Expected Failure"):
            return None, (
                f"`{target}` was {base_result or 'absent'} BEFORE the mutation, so its expectation "
                "has no clean baseline.")
        resolved[name] = target
    return resolved, None


def classify_expectations(baseline: "SuiteResults", mutated: "SuiteResults",
                          must_fire, must_not_fire):
    """Grade an exact newly-failing set plus named controls that must stay unchanged."""
    fire, error = _resolve_expectation_names(baseline, mutated, must_fire)
    if error:
        return VERDICT_INVALID, error
    silent, error = _resolve_expectation_names(baseline, mutated, must_not_fire)
    if error:
        return VERDICT_INVALID, error

    for label, resolved in (("must_fire", fire), ("must_not_fire", silent)):
        aliases_by_test = {}
        for alias, test_id in resolved.items():
            aliases_by_test.setdefault(test_id, []).append(alias)
        duplicates = {
            test_id: aliases for test_id, aliases in aliases_by_test.items() if len(aliases) > 1
        }
        if duplicates:
            detail = "; ".join(
                f"{test_id}: {', '.join(repr(alias) for alias in aliases)}"
                for test_id, aliases in sorted(duplicates.items())
            )
            return VERDICT_INVALID, f"{label} names the same test through multiple aliases: {detail}"

    required = set(fire.values())
    forbidden = set(silent.values())
    overlap = required & forbidden
    if overlap:
        return VERDICT_INVALID, (
            "the same test is declared in both must_fire and must_not_fire: "
            + ", ".join(sorted(overlap)))

    newly_failed = mutated.failed() - baseline.failed()
    status_changed_without_failure = {
        test_id for test_id in set(baseline.by_id) & set(mutated.by_id)
        if baseline.by_id[test_id] != mutated.by_id[test_id]
        and test_id not in newly_failed
    }
    missing = required - newly_failed
    unexpected = newly_failed - required
    omitted = set(baseline.by_id) - set(mutated.by_id)
    silent_changed = {
        test_id for test_id in forbidden
        if baseline.by_id.get(test_id) != mutated.by_id.get(test_id)
    }
    if (not missing and not unexpected and not silent_changed and not omitted
            and not status_changed_without_failure):
        if required:
            return VERDICT_EXPECTED, (
                f"exact must_fire set matched ({', '.join(sorted(required))}); "
                f"{len(forbidden)} named silent control(s) stayed unchanged")
        return VERDICT_EXPECTED, (
            "expected survivor matched: no test newly failed; "
            f"{len(forbidden)} named silent control(s) stayed unchanged")

    parts = []
    if missing:
        parts.append("required test(s) did not fire: " + ", ".join(sorted(missing)))
    if unexpected:
        parts.append("unexpected test(s) fired: " + ", ".join(sorted(unexpected)))
    if silent_changed:
        parts.append("must_not_fire control(s) changed status: "
                     + ", ".join(sorted(silent_changed)))
    if status_changed_without_failure:
        parts.append(
            "test(s) changed status without failing: "
            + ", ".join(sorted(status_changed_without_failure)))
    if omitted:
        parts.append(
            f"mutated result bundle omitted {len(omitted)} baseline test(s): "
            + ", ".join(sorted(omitted)[:5]))
    return VERDICT_MISMATCH, "; ".join(parts)


class Lane:
    """One filtered Debug test run through the canonical test entry point."""

    def __init__(self, worktree: Path, derived_data: Path, log_dir: Path):
        self.worktree = worktree
        self.derived_data = derived_data
        self.log_dir = log_dir
        self.log_dir.mkdir(parents=True, exist_ok=True)

    def bundle_path(self, tag: str) -> Path:
        return self.log_dir / tag / "result.xcresult"

    def debug_log_path(self, tag: str) -> Path:
        return self.log_dir / tag / "xcode-test-debug.log"

    @staticmethod
    def _remove_previous(path: Path, label: str):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
        if path.exists() or path.is_symlink():
            raise _RowFailed(f"the previous {label} at {path} could not be removed. Remove it by hand "
                             "before re-running; a row must never read another row's receipt.")

    def run_suite(self, suite: str, tag: str):
        """-> (count, failures, compiled, log_path, rc, elapsed, results).

        `count` is None when no summary was printed; `results` is a SuiteResults, or None when the
        lane did not compile and so wrote no bundle. Every VERDICT comes from `results`; `count` and
        `compiled` answer only whether the lane reached the test phase at all.
        """
        row_dir = self.log_dir / tag
        row_dir.mkdir(parents=True, exist_ok=True)
        log_path = self.debug_log_path(tag)
        bundle = self.bundle_path(tag)
        self._remove_previous(log_path, "canonical Debug log")
        self._remove_previous(bundle, "result bundle")
        command_log = row_dir / "invocation.log"
        self._remove_previous(command_log, "invocation log")
        cmd = [
            str(self.worktree / CANONICAL_SCRIPT),
            "--filter", suite,
            "--log-dir", str(row_dir),
            "--result-bundle-path", str(bundle),
        ]
        child_env = dict(os.environ, DERIVED_DATA_PATH=str(self.derived_data))
        started = time.monotonic()
        # `monotonic` cannot be compared against a file mtime; a wall clock can.
        started_wall = time.time()
        try:
            rc, out = run(cmd, cwd=self.worktree, log_path=command_log,
                          timeout=LANE_TIMEOUT_SECONDS, env=child_env)
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            Path(command_log).write_text(
                f"lane exceeded {LANE_TIMEOUT_SECONDS}s and was killed after {elapsed:.0f}s\n")
            raise _LaneTimedOut(
                f"the lane ran past {LANE_TIMEOUT_SECONDS}s and was killed. A mutation that removes a "
                f"completion or cancellation path can hang the suite; that is a row ERROR, never a "
                f"catch ({log_path})")
        elapsed = time.monotonic() - started

        if not log_path.exists() or log_path.stat().st_mtime < started_wall:
            raise _RowFailed(
                f"the canonical Debug log was not created by this lane ({log_path}). The script failed "
                f"during setup, before there is a test receipt to grade; see {command_log}.")

        count, failures = classify_lane_output(out)
        # A red lane with compiler diagnostics and no test summary never ran the tests.
        compiled = not (count is None and COMPILE_ERROR_RE.search(out) is not None)
        results = None
        if compiled:
            if bundle.exists() and bundle.stat().st_mtime < started_wall:
                raise _RowFailed(
                    f"the result bundle at {bundle} predates this lane, so it belongs to an earlier "
                    f"run. Grading this row against it would report another mutation's outcome.")
            results = read_result_bundle(bundle)
        return count, failures, compiled, log_path, rc, elapsed, results


def check_canonical_entrypoint(worktree: Path):
    """The battery cannot grade a lane unless the canonical entry point is runnable."""
    canonical = worktree / CANONICAL_SCRIPT
    if canonical.is_symlink() or not canonical.is_file() or not os.access(canonical, os.X_OK):
        raise Refusal(
            f"{CANONICAL_SCRIPT} must be a regular executable file. The battery runs that command "
            "directly so it cannot make its own copy of the build settings."
        )


def preflight(worktree: Path):
    check_canonical_entrypoint(worktree)
    # Case-insensitive: the preflight glob is case-SENSITIVE but the default APFS volume is not, so a
    # `.MUTBAK` would be invisible here and then silently overwritten and unlinked by a row.
    leftovers = [q for q in worktree.rglob("*") if q.suffix.lower() == ".mutbak"]
    if leftovers:
        raise Refusal(
            "Backup files from an earlier battery are still on disk, so a previous run did not "
            "restore. Investigate before mutating anything else:\n  "
            + "\n  ".join(str(p) for p in leftovers)
        )
    backup_root = worktree / "build" / "mutation-battery" / "backups"
    if backup_root.exists():
        backup_leftovers = [p for p in backup_root.rglob("*") if p.is_file() or p.is_symlink()]
        if backup_leftovers:
            raise Refusal(
                "The dedicated backup directory still has files from an earlier battery. Investigate "
                "before mutating anything else:\n  "
                + "\n  ".join(str(p) for p in backup_leftovers)
            )


FENCE_RE = re.compile(r"```json\s*\n(.*?)```", re.DOTALL)
MARKDOWN_FENCE_RE = re.compile(r"```mutation-recipe\s*\n(.*?)```", re.DOTALL)
MARKDOWN_RECIPE_COLUMNS = (
    "mode", "label", "file", "anchor", "replacement", "suite", "must_fire",
    "must_not_fire", "instruction",
)


def _markdown_cells(line: str):
    """Split one pipe-table row; literal pipes must be escaped or written as `&#124;`."""
    text = line.strip()
    if not text.startswith("|") or not text.endswith("|"):
        raise Refusal("each mutation-recipe table row must start and end with '|'.")
    cells = re.split(r"(?<!\\)\|", text[1:-1])
    return [cell.replace(r"\|", "|").strip() for cell in cells]


def _markdown_value(cell: str):
    """Decode the deliberately small Markdown subset accepted inside recipe cells."""
    value = html.unescape(cell.strip())
    if len(value) >= 2 and value.startswith("`") and value.endswith("`"):
        value = value[1:-1]
    return re.sub(r"<br\s*/?>", "\n", value, flags=re.IGNORECASE).strip()


def markdown_recipe_document(raw: str):
    """Turn one explicit Markdown recipe table into the same document JSON recipes use.

    This does not parse arbitrary issue prose. A confident guess at English is worse than a refusal in
    an unattended source-rewrite tool, so only the documented table is executable. Semantic mutations
    remain useful: mark them `human`, give them an instruction, and the runner reports them as deferred.
    """
    lines = [line for line in raw.splitlines() if line.strip()]
    if len(lines) < 3:
        raise Refusal("the mutation-recipe block must contain a header, separator, and at least one row.")
    header = tuple(re.sub(r"[ -]+", "_", cell.lower()) for cell in _markdown_cells(lines[0]))
    if header != MARKDOWN_RECIPE_COLUMNS:
        raise Refusal(
            "the mutation-recipe table header must be exactly: "
            + " | ".join(MARKDOWN_RECIPE_COLUMNS)
        )
    separator = _markdown_cells(lines[1])
    if len(separator) != len(header) or any(not re.fullmatch(r":?-{3,}:?", cell) for cell in separator):
        raise Refusal("the mutation-recipe table needs one Markdown separator cell per header.")

    rows = []
    for index, line in enumerate(lines[2:], 1):
        cells = _markdown_cells(line)
        if len(cells) != len(header):
            raise Refusal(
                f"Markdown recipe row {index} has {len(cells)} cells; expected {len(header)}. "
                "Escape a literal pipe as \\| or &#124;."
            )
        values = {name: _markdown_value(cell) for name, cell in zip(header, cells)}
        mode = values["mode"].lower()
        must_fire = [name.strip(" `") for name in values["must_fire"].splitlines() if name.strip(" `")]
        must_not_fire = [
            name.strip(" `") for name in values["must_not_fire"].splitlines() if name.strip(" `")
        ]
        if mode == "human":
            rows.append({
                "mode": "human",
                "label": values["label"],
                "suite": values["suite"],
                "must_fire": must_fire,
                "must_not_fire": must_not_fire,
                "instruction": values["instruction"],
            })
            continue
        if mode != "mechanical":
            raise Refusal(
                f"Markdown recipe row {index} mode must be 'mechanical' or 'human', got "
                f"{values['mode']!r}."
            )
        rows.append({
            "mode": "mechanical",
            "label": values["label"],
            "file": values["file"],
            "anchor": values["anchor"],
            "replacement": values["replacement"],
            "suite": values["suite"],
            "must_fire": must_fire,
            "must_not_fire": must_not_fire,
        })
    return {"rows": rows}


def issue_recipe_document(number: int, text: str):
    """Select exactly one explicit recipe representation from an issue and its comments."""
    json_blocks = FENCE_RE.findall(text)
    markdown_blocks = MARKDOWN_FENCE_RE.findall(text)
    total = len(json_blocks) + len(markdown_blocks)
    if total == 0:
        raise Refusal(
            f"issue #{number} carries neither a ```json nor a ```mutation-recipe block in its body "
            "or comments. Free-form prose is never guessed into source mutations."
        )
    if total > 1:
        raise Refusal(
            f"issue #{number} carries {total} explicit recipe blocks across its body and comments. "
            "Exactly one is allowed, or the run and the issue disagree about what was tested."
        )
    if json_blocks:
        return json.loads(json_blocks[0])
    return markdown_recipe_document(markdown_blocks[0])


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
    try:
        return json.dumps(issue_recipe_document(number, out))
    except json.JSONDecodeError as exc:
        raise Refusal(f"the JSON recipe in issue #{number} is not valid JSON: {exc}") from exc


def load_recipes(path: Path, worktree: Path, raw: str = None):
    where = "the issue body" if raw is not None else str(path)
    if raw is None:
        # A missing or unreadable file is a preflight refusal like any other. Left as an OSError it
        # escapes as a traceback with exit 1, which the documented exit codes reserve for "a row
        # SURVIVED" — the one status an unattended caller must not confuse with a real result.
        raw = read_recipe_target(path, "the recipe file")
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
        mode = row.get("mode", "mechanical")
        row["_recipe_index"] = i
        if mode == "human":
            for field in ("label", "instruction"):
                if not isinstance(row.get(field), str) or not row[field]:
                    raise Refusal(f"human row {i} field '{field}' must be a non-empty string.")
            for field in ("must_fire", "must_not_fire"):
                value = row.get(field, [])
                if not isinstance(value, list) or any(
                    not isinstance(name, str) or not name for name in value
                ):
                    raise Refusal(
                        f"human row {i} field '{field}' must be a list of non-empty test-name strings.")
                if len(value) != len(set(value)):
                    raise Refusal(f"human row {i} field '{field}' contains duplicate test names.")
            overlap = sorted(set(row.get("must_fire", [])) & set(row.get("must_not_fire", [])))
            if overlap:
                raise Refusal(
                    f"human row {i} names test(s) in both must_fire and must_not_fire: "
                    f"{', '.join(overlap)}.")
            row.setdefault("must_fire", [])
            row.setdefault("must_not_fire", [])
            row.setdefault("suite", default_suite)
            if not row["suite"]:
                raise Refusal(f"human row {i} has no suite and no suite_default is set.")
            if not isinstance(row["suite"], str) or "/" not in row["suite"]:
                raise Refusal(
                    f"human row {i} suite must be a target-qualified string, got {row['suite']!r}.")
            row["_must_fire"] = row["must_fire"]
            row["_must_not_fire"] = row["must_not_fire"]
            row["_mode"] = "human"
            continue
        if mode != "mechanical":
            raise Refusal(f"row {i} mode must be 'mechanical' or 'human', got {mode!r}.")
        row["_mode"] = "mechanical"
        for field in ("label", "file", "anchor", "replacement"):
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
        has_legacy = "expect_fail" in row
        has_sets = "must_fire" in row
        if has_legacy == has_sets:
            raise Refusal(
                f"row {i} must declare exactly one of 'expect_fail' or 'must_fire'.")
        if has_legacy:
            if not isinstance(row["expect_fail"], str) or not row["expect_fail"]:
                raise Refusal(f"row {i} field 'expect_fail' must be a non-empty string.")
            if "must_not_fire" in row:
                raise Refusal(
                    f"row {i} uses legacy 'expect_fail' and cannot also declare 'must_not_fire'. "
                    "Use must_fire for a joint expectation.")
            row["_expectation_mode"] = "legacy"
            row["_must_fire"] = [row["expect_fail"]]
            row["_must_not_fire"] = []
        else:
            for field in ("must_fire", "must_not_fire"):
                value = row.get(field, [])
                if not isinstance(value, list) or any(
                    not isinstance(name, str) or not name for name in value
                ):
                    raise Refusal(
                        f"row {i} field '{field}' must be a list of non-empty test-name strings.")
                if len(value) != len(set(value)):
                    raise Refusal(f"row {i} field '{field}' contains duplicate test names.")
            row.setdefault("must_not_fire", [])
            overlap = sorted(set(row["must_fire"]) & set(row["must_not_fire"]))
            if overlap:
                raise Refusal(
                    f"row {i} names test(s) in both must_fire and must_not_fire: "
                    f"{', '.join(overlap)}.")
            row["_expectation_mode"] = "sets"
            row["_must_fire"] = row["must_fire"]
            row["_must_not_fire"] = row["must_not_fire"]
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
        rel = row["file"]
        if Path(rel).is_absolute():
            raise Refusal(f"row {i} file must be repo-relative, got an absolute path: {rel}")
        # RESOLVE BEFORE DECIDING. A prefix check on the raw string answers a question about the
        # STRING; every question worth asking here is about the FILE it names. `Sources/../Tests/x.swift`
        # passes a lexical `startswith("Sources/")`, resolves inside the worktree, and lands in Tests/ —
        # where breaking an assertion yields a false CAUGHT. Same bypass reaches Project.swift.
        # Cloud review, PR #2158.
        target = (worktree / rel).resolve()
        wt = worktree.resolve()
        if not (target == wt or wt in target.parents):
            raise Refusal(
                f"row {i} resolves OUTSIDE the worktree and will not be mutated:\n"
                f"  recipe says: {rel}\n"
                f"  resolves to: {target}\n"
                f"  worktree:    {wt}"
            )
        if not any(
            root_path == target or root_path in target.parents
            for root_path in ((wt / r).resolve() for r in MUTABLE_ROOTS)
        ):
            raise Refusal(
                f"row {i} targets {rel}, which is outside {', '.join(MUTABLE_ROOTS)} — the only place a "
                "mutation means anything here. A mutation must break PRODUCTION code the filtered lane "
                "actually executes.\n"
                "  Under Tests/ it would break the test itself, go red, and report CAUGHT, proving only "
                "that breaking a test breaks it.\n"
                "  In a Tuist input it would change the project's shape while xcodebuild kept using the "
                "baseline's generated .xcodeproj, so the row would report SURVIVED about a mutant the "
                "build never saw.\n"
                "  Anywhere the lane does not execute, every row reports SURVIVED regardless of the "
                "test's quality.\n"
                "An allow-list on purpose: the deny-list it replaced was wrong once per review round, "
                "and it is applied to the RESOLVED path, so `Sources/../Tests/x.swift` cannot walk "
                "through it. Prove a change of that kind with a full lane instead.\n"
                f"  recipe says: {rel}\n"
                f"  resolves to: {target}"
            )
        if not target.is_file():
            raise Refusal(f"row {i} target does not exist: {row['file']}")
        if target.suffix != ".swift":
            raise Refusal(
                f"row {i} targets {rel}, which is not Swift. A mutation must break code the filtered "
                "lane EXECUTES; Sources/ also holds plists, strings, JSON and docs, and a row against "
                "any of those reports SURVIVED however good the test is."
            )
        row["_resolved"] = str(target)
        if row["anchor"] == row["replacement"]:
            raise Refusal(f"row {i} anchor and replacement are identical — it would mutate nothing.")
        # Check anchor presence and uniqueness HERE, against the clean tree, so a bad recipe costs
        # nothing. The row re-checks at apply time because an earlier row may share the file.
        # Reads the resolved, contained path through the helper, so a binary resource under Sources/
        # is refused HERE — before any row runs — rather than raising mid-battery.
        clean = read_recipe_target(target, f"row {i}'s target")
        occurrences = clean.count(row["anchor"])
        if occurrences == 0:
            raise Refusal(
                f"row {i} anchor not found in {row['file']} — the mutation would never be applied, "
                "and a row that never applied is not a row that passed."
                + indentation_hint(clean, row["anchor"])
            )
        if occurrences > 1:
            raise Refusal(
                f"row {i} anchor occurs {occurrences} times in {row['file']}; it must be unique or "
                "the mutation lands somewhere you did not choose."
            )
    return rows


def reindented(anchor, delta):
    """`anchor` with every non-blank line's leading indentation shifted by `delta` spaces.

    Returns None when a dedent would eat a non-space character, so a shift that
    changes the TEXT can never be offered as the same anchor.
    """
    out = []
    for line in anchor.split("\n"):
        if not line.strip():
            out.append(line)
            continue
        if delta >= 0:
            out.append(" " * delta + line)
        else:
            if line[:-delta].strip():
                return None
            out.append(line[-delta:])
    return "\n".join(out)


def first_content_line_offset(text):
    """Where `text`'s first line that has content begins, as an index into `text`.

    Zero for the ordinary anchor. Non-zero when an anchor opens with blank lines or a
    bare newline, which say nothing about indentation and must not be the thing tested
    for beginning a line. Ref: #2529 review r3.
    """
    offset = 0
    for line in text.split("\n"):
        if line.strip():
            return offset
        offset += len(line) + 1
    return 0


def line_start_occurrences(src, text):
    """How many times `text` occurs with its FIRST CONTENT LINE beginning a line.

    `str.count` is a substring test, so it would accept a shifted anchor found in the
    middle of a longer line — which is not indentation, and the sentence this feeds
    says the word "indentation".

    **The subject is the first CONTENT line, not the first character**, which is the
    general form of a finding about anchors opening with a newline: there the match
    begins at the separator, whose preceding character is ordinary content from the
    line before, so an exact uniquely-reindented match was never reported. Testing the
    content line covers that, leading blank lines, and the ordinary case at once.
    Ref: #2529 review r1 and r3.
    """
    lead = first_content_line_offset(text)
    total, start = 0, 0
    while (found := src.find(text, start)) != -1:
        anchored = found + lead
        if anchored == 0 or src[anchored - 1] == "\n":
            total += 1
        start = found + 1
    return total


def indentation_hint(src, anchor):
    """A sentence naming the offsets at which this anchor matches exactly once, or ''.

    An anchor is TEXT, so a formatter reflow or an extract that changes only nesting
    depth retires a row while the behaviour it binds is untouched. `anchor not found`
    is true in both cases and reads like the subject is gone. This distinguishes them
    and REPORTS ONLY: re-pointing a frozen row is a judgement, never the runner's.
    Ref: #2529.

    **The candidate offsets are READ OFF THE FILE, never chosen here.** A fixed span
    is a parameter that can be wrong, and it fails toward SILENCE: a first draft
    searched +-12 and could not see code that moved four Swift nesting levels,
    reporting the anchor as gone.

    **Two rounds then landed on WHICH LINES are candidates, so that question is gone
    too.** Requiring a line to equal the anchor's first line suppressed a legitimate
    anchor covering only the START of a line (`guard let value` against
    `guard let value = item else {`). Rather than trade one matching rule for
    another, the candidates are now every distinct INDENTATION WIDTH the file
    actually uses. There is no matching heuristic left to get wrong: an offset that
    could line up with any real line is tried, and the verification below — the whole
    shifted anchor, occurring exactly once, BEGINNING A LINE — is what decides.
    Ref: #2529 review r1 and r2.
    """
    first = next((line for line in anchor.split("\n") if line.strip()), None)
    if first is None:
        return ""
    anchor_indent = len(first) - len(first.lstrip(" "))

    candidates = {
        (len(line) - len(line.lstrip(" "))) - anchor_indent
        for line in src.split("\n")
        if line.strip()
    }
    offsets = [
        delta
        for delta in sorted(candidates)
        if delta != 0
        and (shifted := reindented(anchor, delta)) is not None
        # BOTH counts, because an offset is only useful as advice if a row re-cut at
        # it would RUN. A shifted text unique at a line start but repeated mid-line —
        # duplicate bytes inside a comment or a string — passes the first count and is
        # then refused as non-unique by the check above. Naming it points the reader at
        # a number that cannot work, which is worse than naming none. Ref: #2529 r4.
        and line_start_occurrences(src, shifted) == 1
        and src.count(shifted) == 1
    ]
    if not offsets:
        return ""
    named = ", ".join(f"{delta:+d}" for delta in sorted(offsets))
    return (
        f" The same text matches exactly once at {named} spaces of indentation, so the code "
        "MOVED rather than changed. File a corrected row on a new issue; a frozen row is never "
        "edited in place."
    )


def select_recipe_row(rows, number):
    """Apply `--row` to the authored order, before human rows are separated."""
    if number is None:
        return rows
    if not 1 <= number <= len(rows):
        raise Refusal(f"--row {number} out of range (1..{len(rows)})")
    return [rows[number - 1]]


def suite_test_names(log_path) -> set:
    """Every test identity the lane REPORTED, pass or fail.

    Swift Testing prints a line per test outcome; both the ✔ and ✘ forms carry the same identity in
    the same position, so one pattern reads both. Used to prove a recipe's `expect_fail` names a test
    that exists before anything is mutated.
    """
    try:
        text = Path(log_path).read_text()
    except OSError:
        return set()
    names = set()
    for m in TEST_NAME_ANY_RE.finditer(text):
        names.add(m.group("quoted") if m.group("quoted") is not None else m.group("bare"))
    return names


def baseline(lane: Lane, suites, phase: str, seen_names: dict = None,
             results_out: dict = None):
    """Every named suite must run at least one test and pass. This is both the clean-tree control and
    the filter validation: a suite name that does not exist executes zero tests and SUCCEEDS.

    When `seen_names` is supplied, records the test identities each suite reported, so `expect_fail`
    can be checked against reality rather than discovered to match nothing after a mutation.
    """
    problems = []
    for suite in sorted(suites):
        tag = f"baseline-{phase}-{suite.replace('/', '_')}"
        try:
            count, failures, compiled, log, rc, elapsed, suite_results = lane.run_suite(suite, tag)
        except _LaneTimedOut as exc:
            problems.append(f"{suite}: {exc}")
            continue
        except _RowFailed as exc:
            # The canonical script can fail before Xcode reaches the test lane
            # (generation, package resolution, or its own setup). In that case it
            # creates no fresh Debug log, and `run_suite` deliberately refuses to
            # grade the missing receipt. A clean-tree control must report that as a
            # baseline problem instead of letting the whole battery traceback.
            problems.append(f"{suite}: {exc}")
            continue
        except BundleUnreadable as exc:
            # A NONEXISTENT SUITE ARRIVES HERE, NOT AT THE ZERO-TEST BRANCH BELOW, and
            # that is why this catch matters more than it looks. `xcodebuild` REPORTS
            # SUCCESS for a filter that matched nothing; the bundle then holds zero
            # Test Case nodes and the read raises — before `count < 1` is ever
            # consulted. Uncaught it printed a traceback, so the branch below, whose
            # own text calls this the worst failure the battery has, was unreachable
            # for its own primary trigger.
            # The ROW path already caught this: it wraps `run_suite` in a bare
            # `except Exception`. Only the baseline was bare, and only the baseline
            # had no test.
            problems.append(
                f"{suite}: the result bundle could not be read — {exc}. The usual cause is a filter "
                f"naming a suite that does not exist here: renamed, moved to another target, or read "
                f"off a filename rather than off its @Suite declaration. Nothing was mutated.")
            continue
        if not compiled:
            problems.append(f"{suite}: did not compile ({log})")
        elif count is None or count < 1:
            # Reached when the bundle IS readable and the CONSOLE still reported no
            # tests — a disagreement between the two readers. The nonexistent-suite
            # case is caught above, at the bundle read.
            problems.append(
                f"{suite}: executed ZERO tests and REPORTED SUCCESS. Nothing was mutated. The "
                f"filter names a suite that does not exist here — renamed, moved to another target, "
                f"or read off a filename rather than off its @Suite declaration. Left unchecked this "
                f"is the worst failure the battery has, because every row would score SURVIVED ({log})"
            )
        elif rc != 0 or failures:
            problems.append(f"{suite}: {len(failures)} failing on an unmutated tree ({log})")
        else:
            if seen_names is not None:
                # FROM THE BUNDLE, NOT THE CONSOLE. This set gates every row BEFORE
                # any mutation runs, so a console-derived set refuses a recipe the
                # verdict path would have resolved perfectly — which left #2225
                # fixed in the verdict and broken in validation, the half that runs
                # first. `aliases` carries every legal spelling: the display name,
                # the bare function name, and the `Suite/function()` identifier,
                # which is the only addressable identity a parameterized test has.
                if suite_results is not None:
                    seen_names[suite] = set(suite_results.aliases)
                else:
                    # NO CONSOLE FALLBACK. Falling back to `suite_test_names(log)` here
                    # would reintroduce exactly the defect this branch removed: console
                    # naming refuses a parameterized recipe before anything is mutated,
                    # and it would do it SILENTLY, on a run that looks normal.
                    # Unreachable as the call graph stands — this branch requires
                    # `compiled`, and `run_suite` returns a SuiteResults whenever it
                    # compiled, because the reader raises rather than returning None.
                    # Kept and made loud anyway: "unreachable" is a property of today's
                    # callers, and this file already carried one comment saying `should
                    # be unreachable` about something that was not.
                    problems.append(
                        f"{suite}: the lane compiled and passed but produced no result bundle, so "
                        f"the recipe's test names cannot be checked against reality. Refusing rather "
                        f"than falling back to console-scraped names, which cannot see a "
                        f"parameterized test at all.")
            # The UNMUTATED per-test status map. Every row's verdict is a DIFF
            # against this, so without it a row can only ask "did the named test
            # go red" — which cannot tell a working guard from a mutation that
            # changed nothing, nor from a test that was already failing.
            if results_out is not None and suite_results is not None:
                results_out[suite] = suite_results
            print(f"    baseline {phase}: {suite} — {count} tests green in {elapsed:.0f}s")
    return problems


_BATTERY_LOCK_FD = None


def acquire_battery_lock(worktree: Path):
    """Refuse a second writer before it can inspect or create mutation state."""
    global _BATTERY_LOCK_FD
    lock_path = worktree / "build" / "mutation-battery" / "battery.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = lock_path.open("a+")
    try:
        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fd.close()
        raise Refusal(
            f"another mutation battery already owns {lock_path}. Wait for that run to finish rather "
            "than treating its in-flight backup as stale state."
        )
    _BATTERY_LOCK_FD = fd


def release_battery_lock():
    global _BATTERY_LOCK_FD
    if _BATTERY_LOCK_FD is None:
        return
    try:
        fcntl.flock(_BATTERY_LOCK_FD.fileno(), fcntl.LOCK_UN)
    finally:
        _BATTERY_LOCK_FD.close()
        _BATTERY_LOCK_FD = None


def release_battery_lock_on_return(fn):
    """Keep the lock across every normal return and exception from a CLI run."""
    @functools.wraps(fn)
    def wrapped(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        finally:
            release_battery_lock()
    return wrapped


def main_for_test(recipes: Path, worktree: Path):
    """Entry point for the self-test's stubbed-lane cases. Same code path as the CLI."""
    return main(["--recipes", str(recipes), "--worktree", str(worktree)])


@release_battery_lock_on_return
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--print-markdown-template", action="store_true",
                    help="print the strict mixed mechanical/human recipe table and exit")
    src = ap.add_mutually_exclusive_group(required=False)
    src.add_argument("--recipes", type=Path, help="a recipe JSON file")
    src.add_argument("--from-issue", type=int, metavar="N",
                     help="read the explicit JSON or Markdown recipe in test-hardening issue #N")
    ap.add_argument("--worktree", type=Path, default=None)
    ap.add_argument("--row", type=int, default=None, help="run a single 1-indexed row")
    ap.add_argument("--dry-run", action="store_true", help="validate recipes and baseline, mutate nothing")
    ap.add_argument("--validate-only", action="store_true",
                    help="preflight and recipe validation only — no xcodebuild, no baseline, no mutations")
    args = ap.parse_args(argv)
    if args.print_markdown_template:
        if args.recipes is not None or args.from_issue is not None:
            ap.error("--print-markdown-template does not take a recipe source.")
        print("""```mutation-recipe
| mode | label | file | anchor | replacement | suite | must_fire | must_not_fire | instruction |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| mechanical | drop the guard | `Sources/Module/Foo.swift` | `guard ready else { return }` | `if false { return }` | `EnviousWisprTests/FooTests` | `the guard blocks work` | `the independent control stays green` | |
| human | re-route the semantic branch | | | | `EnviousWisprTests/FooTests` | | | Reintroduce the old deferral through the public outcome, then grade the named suite. |
```""")
        return 0
    if args.recipes is None and args.from_issue is None:
        ap.error("one of --recipes or --from-issue is required")
    if args.validate_only and (args.dry_run or args.row is not None):
        ap.error("--validate-only stops before any run; combining it with --dry-run or --row would "
                 "silently do less than the other flag promises.")

    worktree = (args.worktree or Path(__file__).resolve().parent.parent).resolve()
    # Match the canonical lane's DerivedData override so the battery's isolated child lane never falls
    # back to another checkout's shared cache.
    derived = Path(os.environ.get("DERIVED_DATA_PATH") or (worktree / ".derivedData" / "Test"))
    # NOT created here: --validate-only is documented as running nothing and touching nothing, and an
    # unconditional mkdir both breaks that promise and crashes on a read-only checkout. The Lane makes
    # it when a lane is actually about to write a log.
    log_dir = worktree / "build" / "mutation-battery"

    # A --worktree that does not exist crashed with a FileNotFoundError traceback from the first
    # subprocess, rather than refusing. Found by pointing the tool at a peer's worktree minutes after
    # it was cleaned up on merge — an ordinary thing to do, and exit 1 is the code reserved for a row
    # SURVIVING. Same class as every other input failure: it is a bad ARGUMENT, so it is a refusal.
    if not worktree.is_dir():
        print(f"\nREFUSED — the battery did not start.\n\n"
              f"--worktree does not exist: {worktree}\n"
              f"A merged branch's worktree is removed automatically, so a path that worked earlier in "
              f"the day can be gone. Point it at a checkout that has the code the recipe names.",
              file=sys.stderr)
        return 2

    if not args.validate_only:
        try:
            acquire_battery_lock(worktree)
        except Refusal as exc:
            print(f"\nREFUSED — the battery did not start.\n\n{exc}", file=sys.stderr)
            return 2

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
        rows = select_recipe_row(rows, args.row)
    except Refusal as exc:
        print(f"\nREFUSED — the battery did not start.\n\n{exc}", file=sys.stderr)
        return 2

    deferred = [row for row in rows if row.get("_mode") == "human"]
    rows = [row for row in rows if row.get("_mode") == "mechanical"]
    if deferred:
        print(f"\n{len(deferred)} human-adversary row(s) DEFERRED — no source rewrite was guessed:")
        for row in deferred:
            suite = f" [{row.get('suite')}]" if row.get("suite") else ""
            fire = f"; must fire: {row['must_fire']}" if row["must_fire"] else ""
            silent = f"; must not fire: {row['must_not_fire']}" if row["must_not_fire"] else ""
            print(
                f"  - row {row['_recipe_index']}: {row['label']}{suite}: "
                f"{row['instruction']}{fire}{silent}"
            )

    if args.validate_only:
        print(f"\n--validate-only: preflight clean, {len(rows)} row(s) well-formed (mechanical); "
              f"{len(deferred)} human row(s) deferred. Nothing was run.")
        return 0

    if not rows:
        print("\nNo mechanical rows can run unattended. Human-adversary work remains.", file=sys.stderr)
        return 1

    lane = Lane(worktree, derived, log_dir)
    suites = {row["suite"] for row in rows}

    # BEFORE anything can spawn a lane. Installed after the opening baseline, a signal during `tuist
    # generate` or the baseline itself took Python's default action and left that child's process group
    # orphaned on the shared DerivedData. Nothing is mutated yet, so the restore half is a no-op here —
    # the reaping half is not.
    _install_restore_on_signal()

    print(f"\n[1/3] baseline on a clean tree — {len(suites)} suite(s)")
    try:
        baseline_names = {}
        baseline_results = {}
        problems = baseline(lane, suites, "before", seen_names=baseline_names,
                            results_out=baseline_results)
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

    # Refuse a recipe whose expectation names no test the clean baseline ran. The answer is already in
    # hand at this point, and the alternative is discovering it as a SURVIVED verdict that blames the
    # test. A PREFIX is the common case and the message says so, because that is what an author who
    # wrote against the old substring contract will have.
    unknown = []
    for row in rows:
        i = row["_recipe_index"]
        known = baseline_names.get(row["suite"])
        names = row["_must_fire"] + row["_must_not_fire"]
        # An EMPTY identity set is not a pass. It means the log was unreadable, or Swift Testing's
        # output no longer matches the pattern — in both cases we have no evidence the named test
        # exists, and skipping the check restores exactly the false-SURVIVED this was added to stop.
        # A suite that ran at least one test always prints identity lines, so empty means the reader
        # broke, not that the suite is empty. Fail closed: the whole point of this check.
        if not known and names:
            unknown.append(
                f"row {i}: could not read any test names from {row['suite']}'s baseline run, so "
                f"{names!r} cannot be verified. The suite passed, which means it printed "
                "test lines and the reader failed — not that the suite is empty."
            )
            continue
        for name in names:
            if name in known:
                continue
            near = sorted(n for n in known if name in n or n in name)
            hint = f"\n      did you mean: {near[0]!r}" if near else ""
            unknown.append(f"row {i}: no test named {name!r} ran in {row['suite']}{hint}")
    if unknown:
        print("\nREFUSED — nothing was mutated.\n", file=sys.stderr)
        print("A recipe expectation names a test the clean baseline did not run. Matching is on the "
              "FULL test name, not a prefix — a recipe written when this matched substrings will look "
              "like this.\n", file=sys.stderr)
        for u in unknown:
            print(f"  - {u}", file=sys.stderr)
        return 2

    if args.dry_run:
        print("\n--dry-run: recipes validated, baseline green, nothing mutated.")
        return 1 if deferred else 0

    print(f"\n[2/3] {len(rows)} mutation(s), one at a time")
    results = []
    for row in rows:
        i = row["_recipe_index"]
        target = Path(row["_resolved"])
        tag = f"row{i:02d}"
        backup = backup_path(worktree, tag, target)
        verdict, detail = "ERROR", "did not run"
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, backup)
        _ACTIVE_RESTORES[target] = backup
        try:
            src = read_recipe_target(target, f"row {i}'s target")
            occurrences = src.count(row["anchor"])
            if occurrences == 0:
                detail = "anchor not found — the mutation was never applied" + indentation_hint(
                    src, row["anchor"]
                )
            elif occurrences > 1:
                detail = f"anchor occurs {occurrences} times; it must be unique"
            else:
                target.write_text(src.replace(row["anchor"], row["replacement"], 1))
                # Prove it landed by reading the file back rather than trusting the write.
                if row["replacement"] not in read_recipe_target(target, f"row {i}'s target"):
                    detail = "mutation did not land on re-read"
                else:
                    try:
                        count, failures, compiled, log, rc_run, elapsed, row_results = (
                            lane.run_suite(row["suite"], tag))
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
                    elif row_results is None:
                        detail = f"the lane produced no result bundle to grade ({log})"
                    elif row["suite"] not in baseline_results:
                        detail = (
                            f"no unmutated baseline was recorded for {row['suite']}, so this row has "
                            f"nothing to differ from ({log})")
                    elif (row["_expectation_mode"] == "sets"
                          and not row["_must_fire"] and rc_run != 0
                          and not (row_results.failed()
                                   - baseline_results[row["suite"]].failed())):
                        detail = (
                            f"expected-survivor lane exited {rc_run}, so a partial result bundle cannot "
                            f"be graded as success even though no test was recorded failing ({log})")
                    else:
                        # THE VERDICT IS A DIFF, NOT A RED/GREEN READ. See classify_row for why, and
                        # for the limit it does NOT close.
                        if row["_expectation_mode"] == "legacy":
                            verdict, detail = classify_row(
                                baseline_results[row["suite"]], row_results, row["expect_fail"])
                        else:
                            verdict, detail = classify_expectations(
                                baseline_results[row["suite"]], row_results,
                                row["_must_fire"], row["_must_not_fire"])
                        detail = f"{detail} — {elapsed:.0f}s ({log})"
        except (_RowFailed, Refusal) as exc:
            detail = str(exc)
        except Exception as exc:  # noqa: BLE001 — any row failure is this row's problem, not the run's
            detail = f"row raised {type(exc).__name__}: {exc}"
        finally:
            try:
                shutil.copy2(backup, target)
            except OSError as exc:
                print(
                    f"\nSTOPPING. Could not restore {target}: {exc}\n"
                    f"The file is still MUTATED. Its original is at {backup} — copy it back by hand "
                    f"before running anything else, including the test suite.",
                    file=sys.stderr,
                )
                # Leave the backup in place: it is the only copy of the original.
                _ACTIVE_RESTORES.pop(target, None)
                return 1
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
                results.append((verdict, row["label"], detail))
                print(f"  [ ERR  ] row {i}: {row['label']}\n           {detail}")
                print(
                    f"\nSTOPPING. {target} could not be restored, so the next row would back up a "
                    f"MUTATED file as its own baseline and every row after it would run sabotaged "
                    f"code. Its backup is kept at {backup} — restore it by hand and inspect before "
                    f"running anything else.",
                    file=sys.stderr,
                )
                return 1
            else:
                backup.unlink()   # verified byte-identical; on failure the backup is KEPT (above)
                _prune_empty_backup_parents(backup, worktree)
            _ACTIVE_RESTORES.pop(target, None)
        # KEYED BY EVERY VERDICT `classify_row` CAN RETURN. A bare dict lookup on a
        # verdict it does not know raises KeyError mid-run, which is the right
        # failure — a marker map that silently defaulted would print a row under a
        # symbol that means something else. `.get` with a fallback was rejected for
        # exactly that reason.
        marker = {
            VERDICT_CAUGHT: "  ok  ",
            VERDICT_CAUGHT_ELSEWHERE: " ELSE ",
            VERDICT_SURVIVED: " SURV ",
            VERDICT_NOOP: " NOOP ",
            VERDICT_INVALID: " BADR ",
            VERDICT_EXPECTED: " EXP  ",
            VERDICT_MISMATCH: " MISS ",
            "ERROR": " ERR  ",
        }[verdict]
        print(f"  [{marker}] row {i}: {row['label']}\n           {detail}")
        results.append((verdict, row["label"], detail))

    print("\n[3/3] baseline again — every file must be back to where it started")
    after = baseline(lane, suites, "after")
    if after:
        print("\nBASELINE NOT RESTORED. A restore failed; the tree is dirty.", file=sys.stderr)
        for p in after:
            print(f"  - {p}", file=sys.stderr)
        return 1

    successful = [r for r in results if r[0] in (VERDICT_CAUGHT, VERDICT_EXPECTED)]
    bad = [r for r in results if r[0] not in (VERDICT_CAUGHT, VERDICT_EXPECTED)]
    print(f"\n{'=' * 72}\n{len(successful)}/{len(results)} expectations matched "
          "(CAUGHT or EXPECTED), baseline green before and after.")
    if bad:
        print(f"\n{len(bad)} row(s) need work:")
        for verdict, label, detail in bad:
            print(f"  {verdict}: {label}\n    {explain_verdict(verdict)}\n    {detail}")
        return 1
    if deferred:
        print(f"\n{len(deferred)} human-adversary row(s) still require a thinking operator.")
        return 1
    print("\nEvery mutation matched its declared fire and silence expectations.")
    print("This proves the declared fire/silence pattern holds for the mutations written here.")
    print("It does NOT prove a guard is binding — identifier-name or source-text guards still need")
    print("an independent attempt to evade them, by someone other than their author.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
