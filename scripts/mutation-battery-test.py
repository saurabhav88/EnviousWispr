#!/usr/bin/env python3
"""Two-way tests for mutation-battery.py's refusals.

Every case is PAIRED: a rejected input and a near-identical accepted one. A checker that stopped
classifying anything looks identical to a working one when you only test the rejections.

These cover the paths that run BEFORE any xcodebuild, which is every input-validation refusal. The
run paths (baseline, mutate, restore) are proven by running the battery against a real suite with a
real mutant; a self-test cannot prove those without a build, and pretending otherwise would be the
exact vacuity this harness exists to catch.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

BATTERY = Path(__file__).resolve().parent / "mutation-battery.py"

VALID_ROW = {
    "label": "a representative mutation",
    "file": "Sources/Thing.swift",
    "anchor": "let guarded = true",
    "replacement": "let guarded = false",
    "suite": "EnviousWisprTests/ThingTests",
    "expect_fail": "the guard holds",
}

failures = []
ran = 0

# A pattern that matches no process. The dev-app check is a machine-wide `pgrep`, so without this the
# whole suite fails whenever any session has a dev app open — which is a property of the box, not of
# the code under test. The real check gets its own two-way case below, driven directly.
import os as _os_env  # noqa: E402

NEUTRAL_PATTERN = "ew-battery-self-test-matches-nothing"
NEUTRAL_ENV = dict(_os_env.environ, EW_BATTERY_DEV_APP_PATTERN=NEUTRAL_PATTERN)
# Set it in THIS process too, before the module is imported below. The subprocess cases get NEUTRAL_ENV
# explicitly; the in-process cases read the module's own DEV_APP_PATTERN, which is resolved at import.
# Without this the stubbed-lane rows fail whenever any session on the box has a dev app open — measured
# exactly that way when a peer took the slot mid-suite.
_os_env.environ["EW_BATTERY_DEV_APP_PATTERN"] = NEUTRAL_PATTERN


# A runnable entry point is the only preflight contract: the battery delegates every build setting to it.
CANONICAL_STUB = """#!/usr/bin/env bash
exit 0
"""


def mk_results(statuses, crashed=None):
    """Build a `SuiteResults` the way a real bundle read would.

    The stubbed cases drive `classify_row` directly, so they need the real class
    rather than a dict — a hand-rolled stand-in could accept a shape the real
    reader never produces, and the case would pass against a reader that cannot.
    `statuses` maps a bare test name to its result; ids are qualified so the
    alias index is exercised the same way it is in production.
    """
    by_id, aliases = {}, {}
    for name, result in statuses.items():
        ident = f"StubSuite/{name}"
        by_id[ident] = result
        for spelling in (ident, name):
            aliases.setdefault(spelling, set()).add(ident)
    return battery.SuiteResults(by_id, aliases, dict(crashed or {}))


# The unmutated tree every stubbed row is graded against: the named guard passing,
# one unrelated sibling passing. A row's verdict is the DIFF against this.
def _baseline_results():
    return mk_results({VALID_ROW["expect_fail"]: "Passed", "some other case": "Passed"})


def _stub_baseline(lane, suites, phase, seen_names=None, results_out=None):
    """Stands in for the real baseline in stubbed-lane cases.

    It MUST populate `seen_names`: the runner refuses when a suite's baseline yielded no test
    identities, because an empty set means the reader broke rather than the suite being empty. A stub
    that returned green without names would make every stubbed case hit that refusal — and weakening
    the check to suit the stub would delete the guard the check exists to be.
    """
    if seen_names is not None:
        for suite in suites:
            seen_names[suite] = {VALID_ROW["expect_fail"], "some other case"}
    if results_out is not None:
        for suite in suites:
            results_out[suite] = _baseline_results()
    return []


def make_tree(tmp: Path):
    (tmp / "Sources").mkdir(parents=True, exist_ok=True)
    (tmp / "Sources" / "Thing.swift").write_text("let guarded = true\n")
    (tmp / "scripts").mkdir(parents=True, exist_ok=True)
    canonical = tmp / "scripts" / "xcode-test.sh"
    canonical.write_text(CANONICAL_STUB)
    canonical.chmod(0o755)
    return tmp


def check(name, rows, *, expect_exit, expect_text=None, extra_files=None, top=None, remove=None,
          non_executable=None):
    """Run --validate-only against a throwaway tree and assert the exit code and message."""
    global ran
    ran += 1
    with tempfile.TemporaryDirectory() as td:
        tmp = make_tree(Path(td))
        for rel in (remove or []):
            (tmp / rel).unlink()
        for rel, body in (extra_files or {}).items():
            p = tmp / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body)
        for rel in (non_executable or []):
            (tmp / rel).chmod(0o644)
        doc = dict(top or {})
        doc["rows"] = rows
        recipes = tmp / "recipes.json"
        recipes.write_text(json.dumps(doc))
        proc = subprocess.run(
            [sys.executable, str(BATTERY), "--recipes", str(recipes),
             "--worktree", str(tmp), "--validate-only"],
            capture_output=True, text=True, env=NEUTRAL_ENV,
        )
        out = proc.stdout + proc.stderr
        if proc.returncode != expect_exit:
            failures.append(f"{name}: exit {proc.returncode}, wanted {expect_exit}\n{out.strip()[:400]}")
            return
        if expect_text and expect_text not in out:
            failures.append(f"{name}: message missing {expect_text!r}\n{out.strip()[:400]}")
            return
        print(f"  ok  {name}")


# --- the accepted case, first, so a harness that rejects everything is visible immediately -------
check("a well-formed recipe is accepted", [dict(VALID_ROW)], expect_exit=0,
      expect_text="1 row(s) well-formed")

check("suite_default supplies a missing per-row suite",
      [{k: v for k, v in VALID_ROW.items() if k != "suite"}],
      expect_exit=0, top={"suite_default": "EnviousWisprTests/ThingTests"})

# --- each rejection, paired against the accepted case above ---------------------------------------
for field in ("label", "file", "anchor", "replacement", "expect_fail"):
    check(f"missing '{field}' is refused",
          [{k: v for k, v in VALID_ROW.items() if k != field}],
          expect_exit=2, expect_text=f"missing required field '{field}'")

check("a bare suite name is refused as not target-qualified",
      [dict(VALID_ROW, suite="ThingTests")],
      expect_exit=2, expect_text="not target-qualified")

check("a non-string suite is refused, not crashed on",
      [dict(VALID_ROW, suite=1)],
      expect_exit=2, expect_text="suite must be a string")

check("no suite and no default is refused",
      [{k: v for k, v in VALID_ROW.items() if k != "suite"}],
      expect_exit=2, expect_text="no suite and no suite_default")

check("a target file that does not exist is refused",
      [dict(VALID_ROW, file="Sources/Absent.swift")],
      expect_exit=2, expect_text="target does not exist")

check("an EMPTY replacement is accepted — deleting the anchored block is a real mutation",
      [dict(VALID_ROW, replacement="")], expect_exit=0, expect_text="1 row(s) well-formed")

check("a replacement that is absent entirely is still refused",
      [{k: v for k, v in VALID_ROW.items() if k != "replacement"}],
      expect_exit=2, expect_text="missing required field 'replacement'")

check("an empty ANCHOR is still refused — only replacement may be empty",
      [dict(VALID_ROW, anchor="")],
      expect_exit=2, expect_text="missing required field 'anchor'")

check("anchor identical to replacement is refused",
      [dict(VALID_ROW, replacement=VALID_ROW["anchor"])],
      expect_exit=2, expect_text="would mutate nothing")

check("an empty row list is refused",
      [], expect_exit=2, expect_text="declares no rows")

# A leftover backup means an earlier battery did not restore. Continuing would layer a mutation on
# top of an already-broken file, which is how a battery reports a perfect score against a poisoned
# tree (2026-08-17, 8/8 CAUGHT and every row worthless).
check("a leftover .mutbak refuses the whole run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="did not restore",
      extra_files={"Sources/Thing.swift.mutbak": "let guarded = true\n"})

check("a non-backup file in the dedicated backup root refuses the whole run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="dedicated backup directory",
      extra_files={"build/mutation-battery/backups/row01/left-behind.txt": "original bytes\n"})

check("an anchor absent from the target file is refused",
      [dict(VALID_ROW, anchor="this text is nowhere in the file")],
      expect_exit=2, expect_text="anchor not found")

check("a non-unique anchor is refused",
      [dict(VALID_ROW, anchor="x")],
      expect_exit=2, expect_text="must be unique",
      extra_files={"Sources/Thing.swift": "let x = 1\nlet y = x + x\n"})

check("a missing canonical script refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="regular executable file",
      remove=["scripts/xcode-test.sh"])

check("a non-executable canonical script refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="regular executable file",
      non_executable=["scripts/xcode-test.sh"])

# A recipe arrives from an issue body, which is data someone else wrote. It may not reach out of
# the worktree — an absolute path, a `..`, or a symlink would otherwise have the battery back up,
# mutate and restore a file it was never scoped to.
# Project inputs are intentionally outside the production-code mutation scope.
for _t in ("Project.swift", "Tuist/Config.swift", "Package.swift"):
    check(f"a recipe targeting {_t} is refused as out of scope",
          [dict(VALID_ROW, file=_t)],
          expect_exit=2, expect_text="which is outside Sources/")

# The accepted counterpart: an ordinary Sources file with a similar-looking name must still pass.
check("a Sources file whose name merely resembles a Tuist input is accepted",
      [dict(VALID_ROW, file="Sources/Thing.swift")],
      expect_exit=0, expect_text="1 row(s) well-formed")

check("an absolute target path is refused",
      [dict(VALID_ROW, file="/etc/hosts")],
      expect_exit=2, expect_text="must be repo-relative")

# Deliberately starts with Sources/ so it passes the allow-list and reaches the containment check —
# otherwise the allow-list would catch it first and this case would silently stop testing containment.
# The allow-list must be applied to the RESOLVED path, not the raw string. A lexical prefix check
# answers a question about the STRING; `Sources/../Tests/x.swift` satisfies it, resolves INSIDE the
# worktree, and lands in Tests/ — where breaking an assertion yields a false CAUGHT. Cloud review found
# this walking straight through the allow-list added one round earlier.
check("a path that walks out of an allowed root via .. is refused",
      [dict(VALID_ROW, file="Sources/../Tests/FooTests.swift")],
      expect_exit=2, expect_text="which is outside Sources/")

check("the same bypass aimed at a Tuist input is refused",
      [dict(VALID_ROW, file="Sources/../Project.swift")],
      expect_exit=2, expect_text="which is outside Sources/")

# The accepted counterpart: a `..` that stays inside an allowed root is fine, so the check is about
# WHERE it lands rather than about the characters.
check("a .. that resolves back inside an allowed root is accepted",
      [dict(VALID_ROW, file="Sources/sub/../Thing.swift")],
      expect_exit=0, expect_text="1 row(s) well-formed",
      extra_files={"Sources/sub/placeholder.swift": "// keeps the directory\n"})

check("a target escaping the worktree via .. inside an allowed root is refused",
      [dict(VALID_ROW, file="Sources/../../outside.swift")],
      expect_exit=2, expect_text="resolves OUTSIDE the worktree")

# Inside the worktree, so it passes containment and genuinely reaches the allow-list. `../outside.swift`
# no longer exercises this: since the resolve-first reorder it is caught by containment, and its
# containment case above already covers that.
check("a target inside the worktree but outside the allowed roots is refused",
      [dict(VALID_ROW, file="docs/notes.swift")],
      expect_exit=2, expect_text="which is outside Sources/",
      extra_files={"docs/notes.swift": "// not a mutation target\n"})

# exit 1 means "a row survived". A missing recipe file must never be able to produce it.
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    proc = subprocess.run(
        [sys.executable, str(BATTERY), "--recipes", str(tmp / "nope.json"),
         "--worktree", str(tmp), "--validate-only"],
        capture_output=True, text=True, env=NEUTRAL_ENV,
    )
    out = proc.stdout + proc.stderr
    if proc.returncode != 2 or "cannot read the recipe file" not in out:
        failures.append(f"an unreadable recipe file should refuse with exit 2, got {proc.returncode}"
                        f"\n{out.strip()[:300]}")
    elif "Traceback" in out:
        failures.append("an unreadable recipe file produced a traceback rather than a refusal")
    else:
        print("  ok  an unreadable recipe file refuses with exit 2, not a traceback")

# --- flag-combination guard -----------------------------------------------------------------------
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    recipes = tmp / "recipes.json"
    recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
    proc = subprocess.run(
        [sys.executable, str(BATTERY), "--recipes", str(recipes), "--worktree", str(tmp),
         "--validate-only", "--dry-run"],
        capture_output=True, text=True, env=NEUTRAL_ENV,
    )
    if proc.returncode == 0 or "silently do less" not in (proc.stdout + proc.stderr):
        failures.append("--validate-only with --dry-run should be refused, not silently narrowed")
    else:
        print("  ok  --validate-only combined with --dry-run is refused")

# --- the issue-body channel -----------------------------------------------------------------------
# The issue IS the backlog, so extracting a recipe from one is a load-bearing path, not a convenience.
# Driven directly rather than through the CLI because the CLI path shells out to `gh`; what is under
# test here is the extraction and parsing, not GitHub.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("battery", BATTERY)
battery = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(battery)
# Same reason as NEUTRAL_ENV, for the in-process cases: the dev-app check is about the machine, and
# every case that is not ABOUT it should not consult it. Its own case restores this and drives it.
_REAL_CHECK_NO_DEV_APP = battery.check_no_dev_app
battery.check_no_dev_app = lambda worktree: None


def check_fence(name, body, *, expect_blocks):
    global ran, failures
    ran += 1
    got = len(battery.FENCE_RE.findall(body))
    if got != expect_blocks:
        failures.append(f"{name}: found {got} json blocks, wanted {expect_blocks}")
    else:
        print(f"  ok  {name}")


check_fence("one fenced json block is found in a prose issue body",
            "Some prose.\n\n```json\n{\"rows\": []}\n```\n\nMore prose.\n", expect_blocks=1)
check_fence("a body with no json block yields none",
            "Prose only, and a ```bash\necho hi\n``` block.\n", expect_blocks=0)
check_fence("two json blocks are both seen, so the caller can refuse",
            "```json\n{}\n```\ntext\n```json\n{}\n```\n", expect_blocks=2)


def check_raw(name, raw, *, expect_text):
    global ran, failures
    ran += 1
    import tempfile as _tf
    with _tf.TemporaryDirectory() as td:
        tmp = make_tree(Path(td))
        try:
            battery.load_recipes(None, tmp, raw=raw)
        except battery.Refusal as exc:
            if expect_text in str(exc):
                print(f"  ok  {name}")
            else:
                failures.append(f"{name}: refused with {str(exc)[:200]!r}, wanted {expect_text!r}")
            return
        except Exception as exc:  # a non-Refusal escape is itself the defect
            failures.append(f"{name}: raised {type(exc).__name__} instead of Refusal: {exc}")
            return
    failures.append(f"{name}: was ACCEPTED — it should have been refused")


check_raw("a malformed recipe in an issue body is refused as JSON, not as a crash",
          "{not json at all", expect_text="not valid JSON")
check_raw("an issue body recipe with no rows is refused, and says so about the ISSUE",
          '{"rows": []}', expect_text="the issue body declares no rows")

# Valid JSON is not the expected SHAPE. In the unattended --from-issue path these used to surface
# as an AttributeError traceback, which reads as "the battery is broken" rather than "the recipe
# is wrong".
check_raw("a recipe that is a JSON array, not an object, is refused",
          "[]", expect_text="must be a JSON object")
check_raw("a recipe whose 'rows' is not a list is refused",
          '{"rows": {"a": 1}}', expect_text="'rows' that is not a list")
check_raw("a row that is a bare number is refused, not crashed on",
          '{"rows": [1]}', expect_text="row 1 is a int, not an object")
check_raw("a row field of the wrong type is refused",
          '{"rows": [{"label": 5, "file": "Sources/Thing.swift", "anchor": "a",'
          ' "replacement": "b", "expect_fail": "c", "suite": "T/S"}]}',
          expect_text="must be a string")

# The accepted counterpart, so the two refusals above are not a checker that rejects everything.
ran += 1
import tempfile as _tf2  # noqa: E402

with _tf2.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    good = ('{"suite_default": "EnviousWisprTests/ThingTests", "rows": [{"label": "l",'
            ' "file": "Sources/Thing.swift", "anchor": "let guarded = true",'
            ' "replacement": "let guarded = false", "expect_fail": "x"}]}')
    try:
        rows = battery.load_recipes(None, tmp, raw=good)
        assert len(rows) == 1
        print("  ok  a well-formed recipe from an issue body is accepted")
    except Exception as exc:
        failures.append(f"a well-formed issue-body recipe was refused: {exc}")

# The fence COUNT decisions are the fail-closed ones — zero blocks and several blocks must both refuse.
# Driven with a stubbed `run` so this tests our decision, not GitHub's availability. The double refuses
# what the real tool refuses: a nonzero rc still produces a Refusal rather than an empty body.
def check_issue(name, *, rc, body, expect_text=None, expect_ok=False):
    global ran, failures
    ran += 1
    real = battery.run
    battery.run = lambda cmd, cwd, log_path=None, timeout=None: (rc, body)
    try:
        out = battery.recipes_from_issue(2156, Path("."))
    except battery.Refusal as exc:
        if expect_ok:
            failures.append(f"{name}: refused a valid issue: {str(exc)[:200]}")
        elif expect_text not in str(exc):
            failures.append(f"{name}: refused with {str(exc)[:200]!r}, wanted {expect_text!r}")
        else:
            print(f"  ok  {name}")
        return
    finally:
        battery.run = real
    if expect_ok:
        print(f"  ok  {name}" if out.strip() else f"  ok  {name}")
    else:
        failures.append(f"{name}: was ACCEPTED — it should have been refused")


# The recipe may live in a COMMENT. github-light.md records that in this repo the body is often stale
# and the adopted plan lives in comments, so a body-only read refuses correctly-filed work as a RULE
# rather than an edge case — it fired on a peer's issue within an hour of the format existing.
ran += 1
_seen_cmd = {}


def _capture_cmd(cmd, cwd, log_path=None, timeout=None):
    _seen_cmd["cmd"] = cmd
    return 0, 'body text\n```json\n{"rows": [1]}\n```\n'


_real = battery.run
battery.run = _capture_cmd
try:
    battery.recipes_from_issue(2156, Path("."))
finally:
    battery.run = _real

_cmd = _seen_cmd.get("cmd", [])
# The VALUE of --json is what decides what GitHub returns. Matching "comments" anywhere in the command
# was vacuous: the jq expression names it either way, so unwiring --json left this case green. Its own
# mutation control caught that.
_json_value = _cmd[_cmd.index("--json") + 1] if "--json" in _cmd else ""
if "comments" not in _json_value.split(","):
    failures.append(
        "the issue read asks for comments as well as the body: --json requested "
        f"{_json_value!r}, so a recipe posted as a comment would be invisible")
elif "body" not in _json_value.split(","):
    failures.append(
        "the issue read asks for comments as well as the body: --json requested "
        f"{_json_value!r}, dropping the body — a recipe in the body would be invisible")
else:
    print("  ok  the issue read asks for comments as well as the body")

check_issue("an issue with exactly one recipe block is accepted",
            rc=0, body='prose\n```json\n{"rows": [1]}\n```\n', expect_ok=True)
check_issue("an issue carrying NO recipe block is refused",
            rc=0, body="prose with no recipe at all\n", expect_text="carries no ```json recipe block")
check_issue("an issue carrying TWO recipe blocks is refused rather than picking the first",
            rc=0, body='```json\n{"a":1}\n```\n```json\n{"b":2}\n```\n',
            expect_text="carries 2 ```json blocks")
check_issue("a failed `gh` call is refused, never treated as an empty issue",
            rc=1, body="could not resolve to an Issue", expect_text="could not read issue #2156")

# --- the row loop, with the lane stubbed -----------------------------------------------------------
# These drive the real mutate -> evaluate -> restore machinery against a real file on disk. Everything
# in the loop is exercised EXCEPT the xcodebuild call itself, which is replaced by a stub returning the
# shapes a real lane produces. That boundary is stated rather than blurred: a green here is NOT evidence
# that the battery works end to end against a Swift suite, only that every decision around the call is
# right. The remaining gap is closed by one real run, not by more stubs.
import io  # noqa: E402
import contextlib  # noqa: E402

ORIGINAL = "let guarded = true\n"


def drive_row(lane_result, *, expect_verdict, expect_detail, raise_instead=None):
    """Run one row with a stubbed lane; return (verdict, detail, file_bytes_after)."""
    import tempfile as _t
    with _t.TemporaryDirectory() as td:
        tmp = make_tree(Path(td))
        target = tmp / "Sources" / "Thing.swift"
        recipes = tmp / "r.json"
        recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))

        seen = {}

        class StubLane:
            def __init__(self, *a, **k):
                pass

            def generate_once(self):
                pass

            def run_suite(self, suite, tag):
                # Prove the mutation was actually on disk at the moment the lane ran, rather than
                # trusting the write. A row that restores too early would still look CAUGHT.
                seen["content_during_run"] = target.read_text()
                if raise_instead is not None:
                    raise raise_instead
                return lane_result

        real_lane, real_baseline = battery.Lane, battery.baseline
        battery.Lane = StubLane
        battery.baseline = _stub_baseline
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                rc = battery.main_for_test(recipes, tmp)
        finally:
            battery.Lane, battery.baseline = real_lane, real_baseline
        return rc, buf.getvalue(), target.read_text(), seen.get("content_during_run")


def check_row(name, lane_result, *, expect_marker, expect_rc, raise_instead=None):
    global ran, failures
    ran += 1
    try:
        rc, out, after, during = drive_row(lane_result, expect_verdict=None, expect_detail=None,
                                           raise_instead=raise_instead)
    except Exception as exc:
        failures.append(f"{name}: driver raised {type(exc).__name__}: {exc}")
        return
    problems = []
    if expect_marker not in out:
        problems.append(f"report missing {expect_marker!r}")
    if rc != expect_rc:
        problems.append(f"exit {rc}, wanted {expect_rc}")
    # The control that matters most: the file must be back to byte-identical on EVERY path.
    if after != ORIGINAL:
        problems.append(f"FILE NOT RESTORED — on disk: {after!r}")
    if raise_instead is None and during != "let guarded = false\n":
        problems.append(f"mutation was not on disk when the lane ran: {during!r}")
    if problems:
        failures.append(f"{name}: " + "; ".join(problems))
    else:
        print(f"  ok  {name}")


# (count, failures, compiled, log, rc, elapsed)
check_row("the named test failing scores CAUGHT",
          (5, [], True, "log", 65, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Failed", "some other case": "Passed"})),
          expect_marker="CAUGHT", expect_rc=0)

# THE STATE THE CONSOLE COULD NOT EXPRESS. Nothing changed status, so the mutation
# never reached anything the suite observes — today that scored identically to a
# working guard, which is the verdict that sends an overnight session to "fix" a
# test that is fine.
check_row("a mutant that changes NOTHING is SURVIVED-UNOBSERVED, not a survivor to fix",
          (5, [], True, "log", 0, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Passed", "some other case": "Passed"})),
          expect_marker="SURVIVED-UNOBSERVED", expect_rc=1)

check_row("a DIFFERENT test failing is CAUGHT-ELSEWHERE, never evidence about this guard",
          (5, [], True, "log", 65, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Passed", "some other case": "Failed"})),
          expect_marker="CAUGHT-ELSEWHERE", expect_rc=1)

# A CRASH prints ZERO failure marks, so the console could not see it at all and
# scored it SURVIVED while saying the lane was green. Both halves were false.
check_row("a CRASH in the named test is CAUGHT, and the crash is named",
          (5, [], True, "log", 65, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Failed", "some other case": "Passed"},
                      crashed={f'StubSuite/{VALID_ROW["expect_fail"]}':
                               "Crash: xctest at StubSuite.theGuardHolds()"})),
          expect_marker="crash:", expect_rc=0)

# NOT COVERED HERE, deliberately and stated: "the guard was ALREADY red on the
# unmutated tree" is INVALID-ROW in `classify_row`, and this harness cannot reach
# it — `_stub_baseline` always reports the target passing. Reaching it needs a
# per-case baseline, which is worth doing and is not done. Saying so beats a case
# that asserts CAUGHT under an INVALID-ROW name.

check_row("zero executed tests is an ERROR, never a survivor and never a catch",
          (0, [], True, "log", 0, 3.0, None),
          expect_marker="ERROR", expect_rc=1)

check_row("no test summary at all is an ERROR",
          (None, [], True, "log", 0, 3.0, None),
          expect_marker="ERROR", expect_rc=1)

check_row("a mutant that does not compile is an ERROR — a red lane proves nothing if nothing ran",
          (None, [], False, "log", 65, 3.0, None),
          expect_marker="ERROR", expect_rc=1)

# The most dangerous defect this tool has had, and it is invisible to a byte comparison. `copy2`
# restores the original MODIFICATION TIME along with the bytes. Against warm DerivedData, a replacement
# the SAME SIZE as its anchor therefore leaves a file that is byte-identical AND older than the object
# compiled from the mutant, so the next row can run mutant code while every check reports clean.
ran += 1
_res = drive_row((5, [], True, "log", 65, 3.0, None),
                 expect_verdict=None, expect_detail=None)
# drive_row returns (rc, out, after, during); re-run it capturing the file's mtime instead.
import tempfile as _t3  # noqa: E402
import os as _os  # noqa: E402
with _t3.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    target = tmp / "Sources" / "Thing.swift"
    _os.utime(target, (1_000_000, 1_000_000))  # deliberately ancient
    before_mtime = target.stat().st_mtime
    recipes = tmp / "r.json"
    # A replacement the SAME LENGTH as the anchor, so bytes-and-size tell you nothing.
    same_len = dict(VALID_ROW, anchor="let guarded = true", replacement="let guarded = TRUE")
    recipes.write_text(json.dumps({"rows": [same_len]}))

    class _StubLane:
        def __init__(self, *a, **k):
            pass

        def generate_once(self):
            pass

        def run_suite(self, suite, tag):
            return (5, [], True, "log", 65, 3.0, None)

    _rl, _rb = battery.Lane, battery.baseline
    battery.Lane, battery.baseline = _StubLane, (_stub_baseline)
    try:
        import io as _io2, contextlib as _cl2
        with _cl2.redirect_stdout(_io2.StringIO()), _cl2.redirect_stderr(_io2.StringIO()):
            battery.main_for_test(recipes, tmp)
    finally:
        battery.Lane, battery.baseline = _rl, _rb

    after_mtime = target.stat().st_mtime
    if target.read_text() != "let guarded = true\n":
        failures.append("same-length restore: content was not restored")
    elif after_mtime <= before_mtime:
        failures.append(
            "a restored file is stamped NOW: it kept its OLD mtime instead, so a warm incremental "
            "build can skip recompiling and the next row runs against mutant objects")
    else:
        print("  ok  a restored file is stamped NOW, so the next build cannot reuse mutant objects")

# Preflight is a snapshot; an overnight battery is long. A dev app that starts after preflight and
# stops before the closing baseline corrupts the AppLogger tests only DURING a mutant, which credits
# the sabotage with a failure something else caused — a false CAUGHT, failing toward confidence.
ran += 1
_real_pids = battery.dev_app_pids
battery.dev_app_pids = lambda wt: ["99999"]
try:
    rc, out, after, during = drive_row((5, [], True, "log", 0, 3.0, None),
                                       expect_verdict=None, expect_detail=None)
    problems = []
    if "ERR" not in out or "appeared mid-run" not in out:
        problems.append(f"row should ERROR naming the intruder; got: {out.strip()[:200]}")
    if rc != 1:
        problems.append(f"exit {rc}, wanted 1")
    if after != ORIGINAL:
        problems.append(f"file not restored: {after!r}")
    if problems:
        failures.append("a dev app appearing mid-run fails that row: " + "; ".join(problems))
    else:
        print("  ok  a dev app appearing mid-run fails that row")
finally:
    battery.dev_app_pids = _real_pids

check_row("the file is restored even when the lane raises mid-row",
          None, expect_marker="ERR", expect_rc=1, raise_instead=RuntimeError("lane exploded"))

# A double must refuse what the real tool refuses, and it must also RETURN what the real tool returns.
# The stubbed lane above hands back a 6-tuple; if Lane.run_suite ever returns a different shape, every
# row case would keep passing against a double that no longer resembles the thing it replaces — the
# stub would be testing itself. Bind them by reading the real return statement.
ran += 1
import inspect  # noqa: E402
import re as _re  # noqa: E402

_src = inspect.getsource(battery.Lane.run_suite)
_returns = _re.findall(r"^\s*return (.+)$", _src, _re.MULTILINE)
if len(_returns) != 1:
    failures.append("the stubbed lane returns the same shape as the real one: Lane.run_suite has "
                    f"{len(_returns)} return statements; the stub assumes exactly 1")
else:
    # The stubs hand back a 7-tuple: (count, failures, compiled, log, rc, elapsed, results).
    # The last slot is the parsed result bundle, and it is what every VERDICT now
    # reads — a stub that omitted it would grade rows against `None` and score
    # every one of them an error while looking like a shape mismatch.
    _STUB_ARITY = 7
    _arity = len([t for t in _returns[0].split(",")])
    if _arity != _STUB_ARITY:
        failures.append(
            "the stubbed lane returns the same shape as the real one: "
            f"Lane.run_suite now returns {_arity} values, but the stubbed-lane cases hand back "
            f"{_STUB_ARITY}. Update the stubs AND this constant together — they are two halves of "
            "one claim, and moving only one silently retires the check.")
    else:
        print("  ok  the stubbed lane returns the same shape as the real one")

# ---- cloud review r1 on #2246: three findings, each with a case that fails
# ---- against the pre-fix code.

# P2: a CATCH REQUIRES A FAILURE. Passed -> Skipped is a status CHANGE and is not
# another guard going red; crediting it would score a disappearance as detection.
ran += 1
_base = mk_results({"guard": "Passed", "sibling": "Passed"})
_mut = mk_results({"guard": "Passed", "sibling": "Skipped"})
_v, _d = battery.classify_row(_base, _mut, "guard")
if _v == battery.VERDICT_CAUGHT_ELSEWHERE:
    failures.append("a skipped sibling is not another guard catching the mutation — it was scored "
                    "CAUGHT-ELSEWHERE, so a disappearance reads as detection")
elif _v != battery.VERDICT_SURVIVED:
    failures.append(f"a skipped sibling is not another guard catching the mutation — got {_v}")
elif "newly failed" not in _d:
    failures.append("a skipped sibling is not another guard catching the mutation — the detail does "
                    "not say nothing newly failed")
else:
    print("  ok  a skipped sibling is not another guard catching the mutation")

# The accepted counterpart, so the check above cannot pass by refusing everything.
ran += 1
_mut2 = mk_results({"guard": "Passed", "sibling": "Failed"})
_v2, _ = battery.classify_row(_base, _mut2, "guard")
if _v2 != battery.VERDICT_CAUGHT_ELSEWHERE:
    failures.append(f"a sibling that newly FAILS is still CAUGHT-ELSEWHERE — got {_v2}")
else:
    print("  ok  a sibling that newly FAILS is still CAUGHT-ELSEWHERE")

# P1b: an unchanged test set has TWO causes and the statuses cannot separate them.
# The verdict must name both, never assert the recipe is at fault — that reverses
# the tool's guidance for the ordinary surviving mutant, which is its main subject.
ran += 1
_v3, _d3 = battery.classify_row(_base, mk_results({"guard": "Passed", "sibling": "Passed"}), "guard")
_problems = []
if _v3 != battery.VERDICT_NOOP:
    _problems.append(f"verdict {_v3}")
if "no assertion for what the mutation changed" not in _d3:
    _problems.append("the detail does not offer the missing-assertion cause")
if "RECIPE needs re-aiming" not in _d3:
    _problems.append("the detail does not offer the no-op cause")
if "cannot separate them" not in _d3:
    _problems.append("the detail does not say the statuses cannot distinguish the two")
if _problems:
    failures.append("an unchanged test set names BOTH causes and asserts neither — "
                    + "; ".join(_problems))
else:
    print("  ok  an unchanged test set names BOTH causes and asserts neither")

# P1a: the row gate is fed from the BUNDLE, so a parameterized identifier resolves.
# The console has no addressable name for one, so a console-derived gate refused
# the very recipes #2225 exists to enable — before the verdict path ever ran.
ran += 1
_par = mk_results({"egOneUpdatePausedReadsAsNeedingAttention(_:)": "Passed"})
if "StubSuite/egOneUpdatePausedReadsAsNeedingAttention(_:)" not in set(_par.aliases):
    failures.append("a parameterized identifier is a legal recipe name — the qualified form is "
                    "absent from the alias index, so a recipe naming it would be refused")
elif not _par.resolve("StubSuite/egOneUpdatePausedReadsAsNeedingAttention(_:)"):
    failures.append("a parameterized identifier is a legal recipe name — it does not resolve")
else:
    print("  ok  a parameterized identifier is a legal recipe name")

# ---- cloud review r2 on #2246

# (b) AMBIGUITY ANYWHERE IS AMBIGUITY. With `mutated or baseline`, a name that is
# ambiguous in the BASELINE resolved to a singleton whenever execution stopped
# before the second test reached the mutated bundle — so the ambiguity check was
# skipped exactly when the run was cut short.
ran += 1
_amb_base = battery.SuiteResults(
    {"A/shared": "Passed", "B/shared": "Passed"},
    {"shared": {"A/shared", "B/shared"}}, {})
_amb_mut = battery.SuiteResults({"A/shared": "Failed"}, {"shared": {"A/shared"}}, {})
_v, _d = battery.classify_row(_amb_base, _amb_mut, "shared")
if _v != battery.VERDICT_INVALID:
    failures.append("a name ambiguous in the BASELINE stays ambiguous when the mutated run is cut "
                    f"short — got {_v}, so the row was graded against whichever test happened to run")
elif "ambiguous" not in _d:
    failures.append("a name ambiguous in the BASELINE stays ambiguous — the detail does not say so")
else:
    print("  ok  a name ambiguous in the BASELINE stays ambiguous")

# The accepted counterpart, so the check above cannot pass by refusing everything.
ran += 1
_ok_base = battery.SuiteResults({"A/only": "Passed"}, {"only": {"A/only"}}, {})
_ok_mut = battery.SuiteResults({"A/only": "Failed"}, {"only": {"A/only"}}, {})
_v2, _ = battery.classify_row(_ok_base, _ok_mut, "only")
if _v2 != battery.VERDICT_CAUGHT:
    failures.append(f"an unambiguous name still resolves and scores CAUGHT — got {_v2}")
else:
    print("  ok  an unambiguous name still resolves and scores CAUGHT")

# (a) A STALE BUNDLE MUST STOP THE ROW, NEVER BE READ. `ignore_errors=True` let a
# bundle that could not be removed survive; xcodebuild then declines to overwrite
# it and the read returns the PREVIOUS row's results under this row's name.
ran += 1
import tempfile as _t9  # noqa: E402
with _t9.TemporaryDirectory() as _td9:
    _ld = Path(_td9) / "logs"
    _ld.mkdir()
    _l9 = battery.Lane(Path(_td9), Path(_td9) / "dd", _ld)
    _l9.generated = True
    _stale = _l9.bundle_path("tag")
    _stale.mkdir(parents=True)
    (_stale / "keep").write_text("x")
    # SIMULATED AT THE SEAM, NOT WITH PERMISSION BITS. The first version chmod'd the
    # bundle 0o500 to make the removal fail. As root that does not stop `rmtree` at
    # all, so the removal SUCCEEDS, the row takes the unexpected path, and the
    # `finally` then chmods a directory that no longer exists — a FileNotFoundError
    # outside every except clause, aborting the entire self-test rather than failing
    # one case. A control that depends on privilege proves nothing on half the
    # machines that run it and takes the others down with it.
    _real_rmtree9 = battery.shutil.rmtree
    battery.shutil.rmtree = lambda *a, **k: None   # the removal that did not remove
    try:
        _l9.run_suite("EnviousWisprTests/Whatever", "tag")
        failures.append("a stale result bundle that cannot be removed STOPS the row — it did not; "
                        "the row would be graded against an earlier run's results")
    except battery._RowFailed as _e9:
        if "could not be removed" not in str(_e9):
            failures.append(f"a stale result bundle stops the row — wrong reason: {_e9}")
        else:
            print("  ok  a stale result bundle that cannot be removed STOPS the row")
    except Exception as _e9:  # noqa: BLE001
        failures.append(f"a stale result bundle stops the row — raised {type(_e9).__name__}: {_e9}")
    finally:
        battery.shutil.rmtree = _real_rmtree9

# A mutation that removes a completion or cancellation path is among the most valuable to write and the
# most likely to HANG. Unbounded, the unattended battery sits on that row all night and never reaches
# its restore — leaving a mutated tree behind, which is the one outcome worse than a wrong verdict.
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    target = tmp / "Sources" / "Thing.swift"
    recipes = tmp / "r.json"
    recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))

    class _HangingLane:
        def __init__(self, *a, **k):
            pass

        def generate_once(self):
            pass

        def run_suite(self, suite, tag):
            raise battery._LaneTimedOut("the lane ran past 1800s and was killed")

    _rl, _rb = battery.Lane, battery.baseline
    battery.Lane, battery.baseline = _HangingLane, (_stub_baseline)
    try:
        import io as _io3, contextlib as _cl3
        _buf = _io3.StringIO()
        with _cl3.redirect_stdout(_buf), _cl3.redirect_stderr(_buf):
            _rc = battery.main_for_test(recipes, tmp)
        _out = _buf.getvalue()
    finally:
        battery.Lane, battery.baseline = _rl, _rb

    if target.read_text() != "let guarded = true\n":
        failures.append("a hanging lane left the tree MUTATED — the restore never ran")
    elif _rc != 1 or "ERR" not in _out:
        failures.append(f"a hanging lane should be a row ERROR with exit 1, got {_rc}")
    else:
        print("  ok  a hanging lane is a row ERROR and the tree is still restored")

# The case above proves the row loop HANDLES a timeout. It does not prove the lane is bounded — its
# stub raises the exception directly. These two prove the wiring, and neither reads source text.
ran += 1
with tempfile.TemporaryDirectory() as td:
    try:
        battery.run(["/bin/sleep", "5"], cwd=td, timeout=1)
        failures.append("run() honours its timeout and kills the process: it ignored the timeout, so a "
                        "hanging lane would never be killed")
    except subprocess.TimeoutExpired:
        print("  ok  run() honours its timeout and kills the process")
    except Exception as exc:
        failures.append(f"run() raised {type(exc).__name__} instead of TimeoutExpired: {exc}")

ran += 1
_seen_kwargs = {}


def _capture(cmd, cwd, log_path=None, timeout=None, env=None):
    _seen_kwargs["timeout"] = timeout
    _seen_kwargs["env"] = env
    _seen_kwargs["cmd"] = cmd
    row_dir = Path(cmd[cmd.index("--log-dir") + 1])
    row_dir.mkdir(parents=True, exist_ok=True)
    (row_dir / "xcode-test-debug.log").write_text("Test run with 1 test\n")
    return 0, "Test run with 1 test\n"


_real_run = battery.run
battery.run = _capture
try:
    with tempfile.TemporaryDirectory() as td:
        _root = Path(td)
        _lane = battery.Lane(_root, _root / "derived", _root / "logs")
        try:
            _lane.run_suite("EnviousWisprTests/Whatever", "tag")
        except battery.BundleUnreadable:
            # EXPECTED AND NOT WHAT IS UNDER TEST. `run` is stubbed, so no lane ran and
            # no bundle exists; the assertion below is on the timeout kwarg `run_suite`
            # passed, which has already happened by the time the read is attempted.
            # Swallowing only this exception keeps the case honest — any other failure
            # still surfaces.
            pass
finally:
    battery.run = _real_run

if _seen_kwargs.get("timeout") != battery.LANE_TIMEOUT_SECONDS:
    failures.append(
        "the lane passes LANE_TIMEOUT_SECONDS to the process it starts: it passed "
        f"timeout={_seen_kwargs.get('timeout')!r} instead, so the bound exists but is not wired")
else:
    print("  ok  the lane passes LANE_TIMEOUT_SECONDS to the process it starts")

# A row's restore lives in a `finally`, and Python's DEFAULT SIGTERM action does not run it — the
# process dies where it stands and the production file stays MUTATED with a .mutbak beside it. An
# overnight battery is precisely the thing that gets cancelled, so the restore is also reachable from a
# signal handler. Driven directly rather than by killing a subprocess: what is under test is that the
# registry restores, not that macOS delivers signals.
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    target = tmp / "Sources" / "Thing.swift"
    backup = target.with_suffix(target.suffix + ".mutbak")
    import shutil as _sh
    _sh.copy2(target, backup)
    target.write_text("let guarded = false\n")            # a mutation is now live on disk
    battery._ACTIVE_RESTORES[target] = backup

    import io as _io4, contextlib as _cl4
    with _cl4.redirect_stderr(_io4.StringIO()):
        battery._restore_active("a simulated SIGTERM")

    if target.read_text() != "let guarded = true\n":
        failures.append("an interrupted row restores the file and clears its backup: it stayed "
                        "MUTATED on disk")
    elif backup.exists():
        failures.append("an interrupted row restores the file and clears its backup: the .mutbak "
                        "was left behind, which blocks the next run's preflight")
    elif battery._ACTIVE_RESTORES:
        failures.append("an interrupted row restores the file and clears its backup: the registry "
                        "was not cleared")
    else:
        print("  ok  an interrupted row restores the file and clears its backup")

# ...and the handler must actually be registered, or the restore above is unreachable in practice.
ran += 1
import signal as _sig  # noqa: E402

_prev = {s_: _sig.getsignal(s_) for s_ in (_sig.SIGTERM, _sig.SIGINT, _sig.SIGHUP)}
try:
    battery._install_restore_on_signal()
    _unhandled = [s_ for s_, _ in _prev.items()
                  if _sig.getsignal(s_) in (_sig.SIG_DFL, _sig.default_int_handler)]
    if _unhandled:
        failures.append(
            "the restore handler is registered for termination signals: "
            f"{[s_.name for s_ in _unhandled]} still has its default action, so a cancelled run "
            "leaves the tree mutated")
    else:
        print("  ok  the restore handler is registered for termination signals")
finally:
    for s_, h in _prev.items():
        _sig.signal(s_, h)

# The dev-app check itself, driven directly. A concurrent dev app corrupts the AppLogger tests, and
# those failures score as mutants CAUGHT when nothing detected the sabotage (#2080) — it fails toward
# CONFIDENCE, so it is a refusal rather than a warning, and it needs to be proven both ways.
for _label, _rc, _out, _want in [
    ("a running dev app refuses the whole run", 0, "43962\n", True),
    ("no dev app lets the run proceed", 1, "", False),
]:
    ran += 1
    _real_run2 = battery.run
    battery.run = lambda cmd, cwd, log_path=None, timeout=None, _r=_rc, _o=_out: (_r, _o)
    try:
        _REAL_CHECK_NO_DEV_APP(Path("."))
        _refused = False
    except battery.Refusal as exc:
        _refused = "A dev app is running" in str(exc)
    finally:
        battery.run = _real_run2
    if _refused != _want:
        failures.append(f"{_label}: refused={_refused}, wanted {_want}")
    else:
        print(f"  ok  {_label}")

# The runner invokes the executable command and gives it the filtered suite, isolated log directory,
# result-bundle path, and derived-data environment instead of owning a second xcodebuild argument list.
ran += 1
_expected = {"--filter", "EnviousWisprTests/Whatever", "--log-dir", "--result-bundle-path"}
if not _expected.issubset(set(_seen_kwargs.get("cmd", []))):
    failures.append("the canonical entry receives the suite, isolated log directory, and result bundle")
elif _seen_kwargs.get("env", {}).get("DERIVED_DATA_PATH") != str(_root / "derived"):
    failures.append("the canonical entry receives the requested DERIVED_DATA_PATH")
else:
    print("  ok  the canonical entry receives the isolated lane arguments")

# The canonical lane honours DERIVED_DATA_PATH (xcode-test.sh:19) and the drift guard only compares
# that assignment's TEXT — so a battery ignoring the override would run against the shared warm cache
# while an operator believed it was isolated. Read at call time, so no reload is needed.
ran += 1
_probe = "/tmp/ew-battery-derived-probe"
_env_before = _os_env.environ.get("DERIVED_DATA_PATH")
_os_env.environ["DERIVED_DATA_PATH"] = _probe
_seen = {}


class _ProbeLane:
    def __init__(self, wt, derived, logs):
        _seen["derived"] = str(derived)

    def generate_once(self):
        pass

    def run_suite(self, suite, tag):
        return (1, [], True, "log", 0, 1.0)


_rl, _rb = battery.Lane, battery.baseline
battery.Lane, battery.baseline = _ProbeLane, (_stub_baseline)
try:
    with tempfile.TemporaryDirectory() as td:
        tmp = make_tree(Path(td))
        recipes = tmp / "r.json"
        recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                battery.main(["--recipes", str(recipes), "--worktree", str(tmp), "--dry-run"])
        except BaseException as _esc:  # noqa: BLE001
            # Name this case rather than letting the traceback kill the suite. An escape here stops
            # every LATER case from reporting, so a mutation control reads them all as silent.
            _seen["escaped"] = type(_esc).__name__
finally:
    battery.Lane, battery.baseline = _rl, _rb
    if _env_before is None:
        _os_env.environ.pop("DERIVED_DATA_PATH", None)
    else:
        _os_env.environ["DERIVED_DATA_PATH"] = _env_before

if _seen.get("escaped"):
    failures.append("the battery honours DERIVED_DATA_PATH like the canonical lane — the run escaped "
                    f"as {_seen['escaped']} before it could be checked")
elif _seen.get("derived") != _probe:
    failures.append("the battery honours DERIVED_DATA_PATH like the canonical lane — it does NOT: "
                    f"used {_seen.get('derived')!r} instead of {_probe!r}")
else:
    print("  ok  the battery honours DERIVED_DATA_PATH like the canonical lane")

# The dev-app refusal exists because concurrent app-log writes corrupt the AppLogger tests. That
# reasoning is entirely about RUNNING tests, so a validation pass — which runs no lane and mutates
# nothing — must not be refused for a condition that cannot affect it. Measured when a peer's UAT app
# blocked a read-only recipe check.
for _label, _will_run, _want_refusal in [
    ("a run that WILL execute tests still refuses while a dev app is up", True, True),
    ("a validate-only pass is NOT refused for a dev app it cannot be affected by", False, False),
]:
    ran += 1
    _real_run3 = battery.run
    # Report a live dev app whatever is asked, so the only variable is whether preflight consults it.
    battery.run = lambda cmd, cwd, log_path=None, timeout=None: (0, "43962\n")
    _real_canon = battery.check_canonical_entrypoint
    battery.check_canonical_entrypoint = lambda wt: None
    # The suite neutralises check_no_dev_app globally (line ~347) so unrelated cases do not depend on
    # what else is running on the box. This case is ABOUT that check, so put the real one back.
    _neutralised = battery.check_no_dev_app
    battery.check_no_dev_app = _REAL_CHECK_NO_DEV_APP
    try:
        with tempfile.TemporaryDirectory() as td:
            _tmp = make_tree(Path(td))
            try:
                battery.preflight(_tmp, will_run_tests=_will_run)
                _got = False
            except battery.Refusal as exc:
                _got = "A dev app is running" in str(exc)
    finally:
        battery.run = _real_run3
        battery.check_canonical_entrypoint = _real_canon
        battery.check_no_dev_app = _neutralised
    if _got != _want_refusal:
        failures.append(f"{_label}: refused={_got}, wanted {_want_refusal}")
    else:
        print(f"  ok  {_label}")

# Swift Testing prints ✘ for a KNOWN issue and the lane still exits 0. A test wrapped in
# `withKnownIssue` is explicitly configured NOT to go red, so crediting it with detecting a mutation
# is a false CAUGHT — the direction that fails toward confidence.
# A test wrapped in `withKnownIssue` is configured NOT to go red, so its status
# does not change and the bundle records it as Passed. Under the diff that is a
# NO-OP verdict, which is both correct and STRONGER than the old "SURVIVED":
# it says nothing in the suite moved, rather than implying the guard was tested
# and found wanting.
check_row("a known issue does not change status, so it is a NO-OP, never CAUGHT",
          (5, [], True, "log", 0, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Passed", "some other case": "Passed"})),
          expect_marker="SURVIVED-UNOBSERVED", expect_rc=1)

# The exclusion's own case: a RED lane where the ONLY mention of the named test is a known issue. If
# known-issue lines counted as failures this would score CAUGHT; excluded, the row is correctly not a
# catch — something else made the lane red. The rc gate cannot cover this one, because the lane IS red.
# The exclusion itself, driven directly. The stubbed-lane cases replace run_suite wholesale, so
# anything parsed inside it is unreachable from them — a case aimed there passes while testing nothing.
ran += 1
_out = (
    "Test run with 5 tests\n"
    '✘ Test "the guard holds" recorded a known issue\n'
    '✘ Test "some other case" recorded an issue\n'
)
_c, _f = battery.classify_lane_output(_out)
if _c != 5:
    failures.append(f"a known issue is not counted as a real failure — wrong count {_c}")
elif any("the guard holds" in ln for ln in _f):
    failures.append("a known issue is not counted as a real failure — it WAS: a withKnownIssue line "
                    "reached the failure list, so a test told to tolerate the break would be credited")
elif not any("some other case" in ln for ln in _f):
    failures.append("a known issue is not counted as a real failure — but a REAL failure was dropped")
else:
    print("  ok  a known issue is not counted as a real failure")

# The accepted counterpart: the same named test on a RED lane is a genuine catch.
# Through the ROW LOOP, which is where expect_fail is compared. The direct failed_test_identities
# cases use exact set membership and so cannot detect substring matching returning here.
# SUBSTRING MATCHING CANNOT RETURN, because the bundle is keyed exactly. The old
# console path matched `expect_fail` with `in` against a whole ✘ line carrying the
# display name, the file path AND the message, so a sibling whose name merely
# CONTAINED the expected one scored CAUGHT. Here the sibling is a different key,
# so it presents as CAUGHT-ELSEWHERE: something went red, and it was not the guard.
check_row("a sibling whose name CONTAINS the expected one is not this guard",
          (5, [], True, "log", 65, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Passed",
                       VALID_ROW["expect_fail"] + " under load": "Failed"})),
          expect_marker="CAUGHT-ELSEWHERE", expect_rc=1)

check_row("the named test itself going red is still CAUGHT",
          (5, [], True, "log", 65, 3.0,
           mk_results({VALID_ROW["expect_fail"]: "Failed", "some other case": "Passed"})),
          expect_marker="CAUGHT", expect_rc=0)

# A timeout must kill the whole process GROUP. xcodebuild spawns the test runner as a descendant, so
# killing only the parent leaves a hung mutant test process holding the shared DerivedData and writing
# logs while later rows run — corrupting their verdicts after the source has been restored.
ran += 1
import subprocess as _sp, os as _os2, time as _t2
# A UNIQUE path per run, and a SELF-TERMINATING child. Both matter: a mutation control on this very
# guard breaks the group kill by design, which leaks the descendant — it reparents to init and keeps
# writing forever. With a shared path that orphan then fails this case on every LATER run, so the test
# reports a broken guard about code that is fine. Measured exactly that way. The bounded loop caps a
# leaked orphan's life at ~10s; the unique path means it cannot poison anyone else meanwhile.
_probe = Path(tempfile.mkdtemp(prefix="ew-battery-groupkill-")) / "probe"
try:
    # The child must NOT inherit the pipe: communicate() waits for every writer to close it, so an
    # inherited stdout makes the post-kill wait last as long as the child does — which masks exactly
    # the defect under test. Redirected, so the wait returns as soon as the parent is gone.
    # The loop is bounded so a leaked orphan expires (the control breaks this guard by design, which
    # leaks one), but LONGER than the sampling window below, or the child would finish on its own and
    # the case would pass whether or not the group was killed. The finally sweeps any survivor.
    battery.run(["/bin/sh", "-c",
                 f"(for _ in $(seq 1 200); do echo x >> {_probe}; sleep 0.2; done >/dev/null 2>&1 &) ; "
                 f"sleep 30"],
                cwd=tempfile.gettempdir(), timeout=2)
    failures.append("a timeout kills the whole process group — run() did not even time out")
except _sp.TimeoutExpired:
    _t2.sleep(1.0)
    _size_after_kill = _probe.stat().st_size if _probe.exists() else 0
    _t2.sleep(1.0)
    _size_later = _probe.stat().st_size if _probe.exists() else 0
    if _size_later != _size_after_kill:
        failures.append("a timeout kills the whole process group, not just the direct child — it does "
                        f"NOT: a descendant kept writing after the kill ({_size_after_kill} then "
                        f"{_size_later} bytes)")
    else:
        print("  ok  a timeout kills the whole process group, not just the direct child")
finally:
    # Sweep any descendant that outlived the run — guaranteed to exist whenever the control breaks the
    # group kill, and it would otherwise reparent to init and outlive the suite.
    _sp.run(["pkill", "-9", "-f", str(_probe)], capture_output=True)
    _probe.unlink(missing_ok=True)
    try:
        _probe.parent.rmdir()
    except OSError:
        pass

# The canonical script owns its SwiftPM seed locks. A timeout must ask it to run its TERM/EXIT cleanup
# before falling back to SIGKILL, or another worktree silently loses the shared seed for the rest of the
# session. Drive both branches without sending a signal to this test process.
for _label, _waits, _want in [
    ("a cooperative canonical lane gets TERM and its cleanup window", [], [battery.signal.SIGTERM]),
    ("an uncooperative canonical lane gets SIGKILL only after TERM", [battery.subprocess.TimeoutExpired("x", 1)],
     [battery.signal.SIGTERM, battery.signal.SIGKILL]),
]:
    ran += 1
    _signals = []

    class _GracefulProc:
        def wait(self, timeout=None):
            if _waits:
                raise _waits.pop(0)

    _old_pgid, _old_proc = battery._ACTIVE_LANE_PGID, battery._ACTIVE_LANE_PROC
    _old_killpg = battery.os.killpg
    battery._ACTIVE_LANE_PGID, battery._ACTIVE_LANE_PROC = 4242, _GracefulProc()
    battery.os.killpg = lambda pgid, sig: _signals.append(sig)
    try:
        _reaped_now = battery._reap_active_lane()
    finally:
        battery.os.killpg = _old_killpg
        battery._ACTIVE_LANE_PGID, battery._ACTIVE_LANE_PROC = _old_pgid, _old_proc
    if not _reaped_now or _signals != _want:
        failures.append(f"{_label}: signals={_signals}, wanted={_want}")
    else:
        print(f"  ok  {_label}")

# EVERY exit path must reap the lane, not just the timeout. Cancellation mid-lane used to restore the
# file and leave xcodebuild's group running — the file looks recovered while an orphan keeps writing
# the shared DerivedData. Fixing one exit path is not fixing the class.
ran += 1
_reaped = {}
_real_reap = battery._reap_active_lane
battery._reap_active_lane = lambda: _reaped.setdefault("called", True)
_real_restore = battery._restore_active
_order = []
battery._restore_active = lambda why: _order.append("restore")
battery._reap_active_lane = lambda: (_order.append("reap"), True)[1]
try:
    _h = None
    _real_signal = battery.signal.signal

    def _capture_signal(sig, fn):
        nonlocal_h = fn
        if sig == battery.signal.SIGTERM:
            _reaped["handler"] = fn
        return None

    battery.signal.signal = _capture_signal
    try:
        battery._install_restore_on_signal()
    finally:
        battery.signal.signal = _real_signal
    _h = _reaped.get("handler")
    if _h is None:
        failures.append("cancellation reaps the lane before restoring — no SIGTERM handler installed")
    else:
        _real_kill, battery.os.kill = battery.os.kill, lambda *a, **k: None
        try:
            _h(battery.signal.SIGTERM, None)
        finally:
            battery.os.kill = _real_kill
        if _order[:2] != ["reap", "restore"]:
            failures.append("cancellation reaps the lane before restoring — order was "
                            f"{_order} rather than ['reap', 'restore']")
        else:
            print("  ok  cancellation reaps the lane before restoring")
finally:
    battery._reap_active_lane = _real_reap
    battery._restore_active = _real_restore

# A binary resource under Sources/ is a bad RECIPE, not a broken battery: read_text on a .wav raises
# UnicodeDecodeError, which is a ValueError, so an OSError-only guard misses it and the unattended
# command emits a traceback with exit 1 — the status reserved for a SURVIVED row.
ran += 1
with tempfile.TemporaryDirectory() as td:
    _t = Path(td) / "resource.wav"
    _t.write_bytes(b"\x00\xff\xfe RIFF not text at all \x00")
    try:
        battery.read_recipe_target(_t, "a binary target")
        failures.append("a binary target is refused, not a traceback — it was ACCEPTED")
    except battery.Refusal as exc:
        if "is not text" not in str(exc):
            failures.append(f"a binary target is refused, not a traceback — wrong message: {exc}")
        else:
            print("  ok  a binary target is refused, not a traceback")
    except Exception as exc:
        failures.append("a binary target is refused, not a traceback — it raised "
                        f"{type(exc).__name__} instead of Refusal")

# The accepted counterpart, so the helper is not simply rejecting everything.
ran += 1
with tempfile.TemporaryDirectory() as td:
    _t = Path(td) / "ok.swift"
    _t.write_text("let x = 1\n")
    try:
        assert battery.read_recipe_target(_t, "a text target") == "let x = 1\n"
        print("  ok  an ordinary text target still reads")
    except Exception as exc:
        failures.append(f"an ordinary text target still reads — it did not: {exc}")

# `expect_fail` is matched on test IDENTITY, not as a substring of the ✘ line. The line carries the
# display name, the source path AND the expectation message, so substring matching produced three
# false-CAUGHT paths — each of these is one of them, and each would have scored CAUGHT before.
for _label, _lines, _expect, _want in [
    ("a sibling whose name CONTAINS the expected one is not a match",
     ['✘ Test "the guard holds under load" recorded an issue at F.swift:1:1'],
     "the guard holds", False),
    ("the expected test itself IS a match",
     ['✘ Test "the guard holds" recorded an issue at F.swift:1:1'],
     "the guard holds", True),
    ("a match inside another test's MESSAGE does not count",
     ['✘ Test "some other case" recorded an issue at F.swift:1:1: Expectation failed: budget == 3'],
     "budget", False),
    ("a match inside a FILE PATH does not count",
     ['✘ Test "some other case" recorded an issue at BudgetTests.swift:1:1'],
     "BudgetTests", False),
    ("a SUITE verdict is never evidence about one test",
     ['✘ Suite "LanguageLockDefaultCodeTests" failed after 0.1 seconds.'],
     "LanguageLockDefaultCodeTests", False),
    ("the bare function-name form is a match",
     ['✘ Test unsupportedLegacyCodeIsNotResurrected() recorded an issue at F.swift:1:1'],
     "unsupportedLegacyCodeIsNotResurrected", True),
    ("a suite line alongside the real failure still resolves to the test",
     ['✘ Suite "FooTests" failed after 0.1 seconds.',
      '✘ Test "the guard holds" recorded an issue at F.swift:1:1'],
     "the guard holds", True),
]:
    ran += 1
    _got = _expect in battery.failed_test_identities(_lines)
    if _got != _want:
        failures.append(f"{_label}: matched={_got}, wanted {_want}")
    else:
        print(f"  ok  {_label}")

# Only Swift is a mutation target. Sources/ also holds plists, strings, JSON and docs — readable text
# the allow-list accepts, and nothing a filtered Swift lane executes, so such a row reports SURVIVED
# however good the test is.
check("a non-Swift text target under Sources/ is refused",
      [dict(VALID_ROW, file="Sources/Info.plist")],
      expect_exit=2, expect_text="which is not Swift",
      extra_files={"Sources/Info.plist": "<plist/>\n"})

# The accepted counterpart is VALID_ROW itself (Sources/Thing.swift), already covered above.

# The leftover-backup preflight globs case-sensitively; the default APFS volume does not. A `.MUTBAK`
# would be invisible to it and then silently overwritten and unlinked by a row.
check("a leftover backup in different case is still caught",
      [dict(VALID_ROW)], expect_exit=2, expect_text="did not restore",
      extra_files={"Sources/Thing.swift.MUTBAK": "let guarded = true\n"})

# A failed restore must STOP the run. Continuing means the next row on that file backs up the MUTATED
# file as its own baseline, so every later row runs sabotaged code — the 8/8-CAUGHT incident
# reproduced mid-run, where the pre-run clean-tree control cannot see it.
ran += 1
_real_cmp = battery.filecmp.cmp
battery.filecmp.cmp = lambda a, b, shallow=True: False
_lanes = []
with tempfile.TemporaryDirectory() as _td:
    _tmp = make_tree(Path(_td))
    _recipes = _tmp / "r.json"
    # TWO rows: with one, the loop ends whether it stopped or finished, so the case could not tell
    # the difference. The second row running is the observable consequence of NOT stopping.
    _recipes.write_text(json.dumps({"rows": [dict(VALID_ROW, label="first"),
                                             dict(VALID_ROW, label="second")]}))

    class _CountingLane:
        def __init__(self, *a, **k):
            pass

        def generate_once(self):
            pass

        def run_suite(self, suite, tag):
            _lanes.append(tag)
            return (5, [], True, "log", 65, 3.0, None)

    _rl, _rb = battery.Lane, battery.baseline
    battery.Lane, battery.baseline = _CountingLane, (_stub_baseline)
    _buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(_buf), contextlib.redirect_stderr(_buf):
            _rc = battery.main(["--recipes", str(_recipes), "--worktree", str(_tmp)])
    finally:
        battery.Lane, battery.baseline = _rl, _rb
        battery.filecmp.cmp = _real_cmp
    _out = _buf.getvalue()
    if "RESTORE FAILED" not in _out:
        failures.append("a failed restore stops the run — it was not even reported")
    elif len(_lanes) != 1:
        failures.append("a failed restore stops the run — it did NOT: row 2 ran anyway "
                        f"(lanes: {_lanes}), so it would have backed up a MUTATED file")
    elif _rc != 1:
        failures.append(f"a failed restore stops the run — exit {_rc}, wanted 1")
    else:
        print("  ok  a failed restore stops the run")

# Any exception in the row body must fail THAT ROW, not abort before the closing baseline — the check
# that proves the tree came back. PermissionError on a read-only target is the reproducible case.
# NOTE ON AIM: raising from the LANE cannot prove the broad catch — the row loop converts any lane
# exception to _RowFailed first, so it never reaches `except Exception`. This raises from the WRITE,
# which is outside that conversion and is the reproducible case (a read-only target).
ran += 1
_real_wt = Path.write_text


def _boom(self, *a, **k):
    # ONLY the mutation write to the target itself. Patching every .swift write breaks make_tree's
    # fixture setup, and matching on the replacement TEXT also trips on the recipe JSON that contains
    # it as data — both are different failures wearing this case's name.
    if self.name == "Thing.swift" and a and "guarded = false" in str(a[0]):
        raise PermissionError("read-only file system")
    return _real_wt(self, *a, **k)


try:
    Path.write_text = _boom
    try:
        _rc, _out, _after, _during = drive_row((5, [], True, "log", 0, 3.0, None),
                                               expect_verdict=None, expect_detail=None)
    except BaseException as _esc:   # noqa: BLE001 — an escape IS the defect this case exists for
        _rc, _out = -1, f"escaped as {type(_esc).__name__}"
    if "ERR" not in _out or "PermissionError" not in _out:
        failures.append("an unexpected exception fails the row rather than aborting the run — it did "
                        f"not: {_out.strip()[:200]}")
    elif _rc != 1:
        failures.append(f"an unexpected exception fails the row rather than aborting the run — "
                        f"exit {_rc}, wanted 1")
    else:
        print("  ok  an unexpected exception fails the row rather than aborting the run")
finally:
    Path.write_text = _real_wt

# The restore COPY itself can fail — disk full, destination unwritable. That used to escape the
# `finally` before verification and backup cleanup, leaving the source MUTATED with its .mutbak
# alongside and no controlled stop. Last round handled the restore producing WRONG BYTES; this is the
# restore FAILING OUTRIGHT.
ran += 1
_real_copy = battery.shutil.copy2
_copies = []


def _copy_then_fail(src, dst, *a, **k):
    _copies.append((str(src), str(dst)))
    if str(src).endswith(".mutbak"):      # the RESTORE direction only; the backup must still be made
        raise OSError(28, "No space left on device")
    return _real_copy(src, dst, *a, **k)


battery.shutil.copy2 = _copy_then_fail
try:
    try:
        _rc, _out, _after, _during = drive_row((5, [], True, "log", 0, 3.0, None),
                                               expect_verdict=None, expect_detail=None)
    except BaseException as _esc:   # noqa: BLE001 — escaping IS the defect this case exists for
        _rc, _out = -1, f"escaped as {type(_esc).__name__}"
    if "STOPPING" not in _out or "still MUTATED" not in _out:
        failures.append("a failing restore COPY stops with a recovery path — it did not: "
                        + _out.strip()[:200])
    elif _rc != 1:
        failures.append(f"a failing restore COPY stops with a recovery path — exit {_rc}, wanted 1")
    else:
        print("  ok  a failing restore COPY stops with a recovery path")
finally:
    battery.shutil.copy2 = _real_copy

# --validate-only is documented as running nothing and touching nothing. An unconditional mkdir broke
# that promise and crashed on a read-only checkout.
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    recipes = tmp / "r.json"
    recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
    proc = subprocess.run(
        [sys.executable, str(BATTERY), "--recipes", str(recipes),
         "--worktree", str(tmp), "--validate-only"],
        capture_output=True, text=True, env=NEUTRAL_ENV,
    )
    if proc.returncode != 0:
        failures.append("--validate-only creates nothing in the worktree — it exited "
                        f"{proc.returncode}")
    elif (tmp / "build").exists():
        failures.append("--validate-only creates nothing in the worktree — it created "
                        "build/mutation-battery anyway")
    else:
        print("  ok  --validate-only creates nothing in the worktree")

# The cancellation handler must be installed BEFORE anything can spawn a lane. Installed after the
# opening baseline, a signal during `tuist generate` or the baseline itself took Python's default
# action and orphaned that child's process group on the shared DerivedData.
ran += 1
_installed_at = []
_real_sig = battery.signal.signal
_real_base = battery.baseline
battery.signal.signal = lambda sig, fn: _installed_at.append("handler")
battery.baseline = lambda lane, suites, phase, seen_names=None, results_out=None: (_installed_at.append(f"baseline-{phase}"), [])[1]


class _NullLane:
    def __init__(self, *a, **k):
        pass

    def generate_once(self):
        _installed_at.append("generate")


try:
    _rl = battery.Lane
    battery.Lane = _NullLane
    with tempfile.TemporaryDirectory() as td:
        tmp = make_tree(Path(td))
        recipes = tmp / "r.json"
        recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                battery.main(["--recipes", str(recipes), "--worktree", str(tmp), "--dry-run"])
        except BaseException as _esc:  # noqa: BLE001
            # Name this case rather than letting a traceback kill the suite: an escape here
            # stops every LATER case reporting, so a mutation control reads them as silent.
            failures.append("cancellation handlers are installed before any lane can start "
                            f"— the run escaped as {type(_esc).__name__}")
            _installed_at.append('escaped')
finally:
    battery.signal.signal = _real_sig
    battery.baseline = _real_base
    battery.Lane = _rl

if "handler" not in _installed_at:
    failures.append("cancellation handlers are installed before any lane can start — none was")
elif _installed_at.index("handler") > _installed_at.index("baseline-before"):
    failures.append("cancellation handlers are installed before any lane can start — they were "
                    f"installed AFTER the opening baseline: {_installed_at}")
else:
    print("  ok  cancellation handlers are installed before any lane can start")

# SIGQUIT (Ctrl-\ on a stuck overnight terminal) died by default action, leaving the file MUTATED.
ran += 1
_signals = []
battery.signal.signal = lambda sig, fn: _signals.append(sig)
try:
    battery._install_restore_on_signal()
finally:
    battery.signal.signal = _real_sig
_missing_sigs = [s for s in (battery.signal.SIGTERM, battery.signal.SIGINT,
                             battery.signal.SIGHUP, battery.signal.SIGQUIT) if s not in _signals]
if _missing_sigs:
    failures.append("every terminating signal is handled — these are not: "
                    + ", ".join(str(s) for s in _missing_sigs))
else:
    print("  ok  every terminating signal is handled")

# `Popen` creates the child in its own session BEFORE the pgid is stored. A signal landing in that
# window saw _ACTIVE_LANE_PGID as None, re-raised, and left the group orphaned. The handled signals are
# now blocked across spawn-and-register, and the previous mask restored rather than cleared.
ran += 1
_seen_mask = {}
_real_mask = battery.signal.pthread_sigmask
_real_popen = battery.subprocess.Popen


def _watch_mask(how, mask=None):
    if how == battery.signal.SIG_BLOCK:
        _seen_mask["blocked"] = set(mask)
    elif how == battery.signal.SIG_SETMASK:
        _seen_mask["restored"] = True
    return _real_mask(how, mask) if mask is not None else _real_mask(how, [])


def _watch_popen(*a, **k):
    # Blocked at the moment the child is created — that is the window under test.
    _seen_mask["blocked_at_spawn"] = set(_real_mask(battery.signal.SIG_BLOCK, []))
    return _real_popen(*a, **k)


battery.signal.pthread_sigmask = _watch_mask
battery.subprocess.Popen = _watch_popen
try:
    battery.run(["/bin/echo", "hi"], cwd=tempfile.gettempdir())
finally:
    battery.signal.pthread_sigmask = _real_mask
    battery.subprocess.Popen = _real_popen

_want = set(battery._HANDLED_SIGNALS)
if not _want <= _seen_mask.get("blocked_at_spawn", set()):
    failures.append("the handled signals are blocked across spawn-and-register — they were NOT at the "
                    f"moment Popen ran: {sorted(_seen_mask.get('blocked_at_spawn', set()))}")
elif not _seen_mask.get("restored"):
    failures.append("the handled signals are blocked across spawn-and-register — the previous mask was "
                    "never restored, so the caller's mask was widened")
else:
    print("  ok  the handled signals are blocked across spawn-and-register")

# `expect_fail` is matched on the FULL test name. A recipe naming a PREFIX used to match nothing, so
# the row reported SURVIVED and the report said "this test is not the guard" about a test that failed
# exactly as intended. Measured on a peer's recipe: 3 of 8 rows false-SURVIVED, all prefixes.
ran += 1
_log = Path(tempfile.mkdtemp(prefix="ew-battery-names-")) / "l.log"
_log.write_text(
    '✔ Test "Availability says On this Mac for what is installed and Available from Apple" passed\n'
    '✘ Test "A build that cannot run the engine says so, not that a download is needed" recorded\n'
    "✔ Test bareFunctionName() passed after 0.1 seconds.\n"
)
_names = battery.suite_test_names(_log)
_want = {
    "Availability says On this Mac for what is installed and Available from Apple",
    "A build that cannot run the engine says so, not that a download is needed",
    "bareFunctionName",
}
if _names != _want:
    failures.append(f"the baseline's test names are enumerated from both outcomes — got {_names}")
else:
    print("  ok  the baseline's test names are enumerated from both outcomes")

# A prefix must NOT be treated as a match — that is the false-CAUGHT bug this replaced.
ran += 1
_prefix = "Availability says On this Mac for what is installed"
if _prefix in _names:
    failures.append("a prefix is not a matching test name — it was treated as one")
else:
    print("  ok  a prefix is not a matching test name")

# An unreadable log yields no names rather than raising, so the check degrades to not-refusing rather
# than crashing a run that was otherwise fine.
ran += 1
try:
    if battery.suite_test_names(Path("/nonexistent/nope.log")) != set():
        failures.append("an unreadable log yields no names — it returned something else")
    else:
        print("  ok  an unreadable log yields no names rather than raising")
except Exception as exc:
    failures.append(f"an unreadable log yields no names rather than raising — it raised {exc}")

# An EMPTY identity set is not a pass. If the log is unreadable, or Swift Testing's output stops
# matching the pattern, we have no evidence the named test exists — and skipping the check restores
# exactly the false-SURVIVED it was added to stop. A suite that ran at least one test always prints
# identity lines, so empty means the READER broke.
ran += 1
_real_base2 = battery.baseline
battery.baseline = lambda lane, suites, phase, seen_names=None, results_out=None: []   # green, but yields NO names
_rl2, battery.Lane = battery.Lane, type("L", (), {
    "__init__": lambda self, *a, **k: None,
    "generate_once": lambda self: None,
    "run_suite": lambda self, suite, tag: (1, [], True, "log", 0, 1.0),
})
try:
    with tempfile.TemporaryDirectory() as td:
        tmp = make_tree(Path(td))
        recipes = tmp / "r.json"
        recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
        _buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(_buf), contextlib.redirect_stderr(_buf):
                _rc = battery.main(["--recipes", str(recipes), "--worktree", str(tmp)])
        except BaseException as _esc:  # noqa: BLE001 — escaping IS a way this guard can be broken
            _rc, _out = -1, f"escaped as {type(_esc).__name__}"
        else:
            _out = _buf.getvalue()
finally:
    battery.baseline = _real_base2
    battery.Lane = _rl2

if _rc != 2 or "could not read any test names" not in _out:
    failures.append("unreadable baseline names refuse the run — they did NOT: "
                    f"exit {_rc}, output {_out.strip()[:200]}")
else:
    print("  ok  unreadable baseline names refuse the run")

# A display name may CONTAIN quotes; Swift Testing prints them unescaped. Terminating on the first
# inner quote truncated the identity, so these tests could never be named in a recipe. All three names
# below are REAL tests in this repo, not invented — the defect was reachable today.
for _label, _line, _want in [
    ("a display name with an embedded quoted phrase parses whole",
     '✘ Test "founder repro: "Other apps." (2 words, punctuation kept) bypasses" recorded an issue at F.swift:1:1',
     'founder repro: "Other apps." (2 words, punctuation kept) bypasses'),
    ("a display name ending in a quoted word parses whole",
     '✔ Test "hardware class is real, never "unknown"" passed after 0.1 seconds.',
     'hardware class is real, never "unknown"'),
    ("a quoted default value inside a name parses whole",
     '✔ Test "lastObservedPhase falls back to protocol default "warmup"" passed after 0.1 seconds.',
     'lastObservedPhase falls back to protocol default "warmup"'),
    ("an ordinary name still parses",
     '✘ Test "an ordinary name" failed after 0.002 seconds with 1 issue.',
     "an ordinary name"),
]:
    ran += 1
    _got = {m.group("quoted") for m in battery.TEST_NAME_ANY_RE.finditer(_line)
            if m.group("quoted") is not None}
    if _got != {_want}:
        failures.append(f"{_label} — got {_got}, wanted {{{_want!r}}}")
    else:
        print(f"  ok  {_label}")

# And the failure-matching regex must agree with the enumerating one, or a name that validates would
# then fail to match when the row runs.
ran += 1
_q = '✘ Test "founder repro: "Other apps." (2 words, punctuation kept) bypasses" recorded an issue'
if battery.failed_test_identities([_q]) != {'founder repro: "Other apps." (2 words, punctuation kept) bypasses'}:
    failures.append("both identity readers agree on a quoted name — they do NOT, so a name that "
                    "validates at load would fail to match when the row runs")
else:
    print("  ok  both identity readers agree on a quoted name")

# A timeout must APPEND to the lane log, not overwrite it. Overwriting throws away the record of which
# operation hung, on the one path where that record is the whole point.
ran += 1
_dir = Path(tempfile.mkdtemp(prefix="ew-battery-timeoutlog-"))
_log = _dir / "row.log"
_real_popen2 = battery.subprocess.Popen


class _HangingPopen:
    def __init__(self, *a, **k):
        self.pid = _os_env.getpid()
        self.returncode = None

    def communicate(self, timeout=None):
        if timeout is not None:
            raise battery.subprocess.TimeoutExpired("cmd", timeout)
        return ("captured output that must survive\n", None)

    def kill(self):
        pass


battery.subprocess.Popen = _HangingPopen
_real_reap2 = battery._reap_active_lane
battery._reap_active_lane = lambda: True
try:
    _log.write_text("EARLIER OUTPUT THAT MUST SURVIVE\n")
    try:
        battery.run(["/bin/true"], cwd=str(_dir), log_path=_log, timeout=1)
    except battery.subprocess.TimeoutExpired:
        pass
finally:
    battery.subprocess.Popen = _real_popen2
    battery._reap_active_lane = _real_reap2

_body = _log.read_text()
if "EARLIER OUTPUT THAT MUST SURVIVE" not in _body:
    failures.append("a timeout appends to the lane log rather than overwriting it — the earlier "
                    "output was DESTROYED, which is the only record of what hung")
elif "timed out after" not in _body:
    failures.append("a timeout appends to the lane log rather than overwriting it — the timeout "
                    "marker was not written at all")
else:
    print("  ok  a timeout appends to the lane log rather than overwriting it")

# `pgrep` exits 0 for a match, 1 for NO MATCH, and 2+ when the probe itself failed. Folding that third
# answer into "none running" is fail-OPEN on a guard whose whole job is to stop a corrupted log scoring
# as a mutant CAUGHT — the battery would proceed believing the machine is clear when it does not know.
for _label, _rc, _want_refusal in [
    ("a failed dev-app probe refuses rather than reading as clear", 2, True),
    ("no match from the dev-app probe proceeds normally", 1, False),
]:
    ran += 1
    _real_run6 = battery.run
    battery.run = lambda cmd, cwd, log_path=None, timeout=None, _r=_rc: (_r, "")
    _neutralised2 = battery.check_no_dev_app
    battery.check_no_dev_app = _REAL_CHECK_NO_DEV_APP
    try:
        _REAL_CHECK_NO_DEV_APP(Path("."))
        _got = False
    except battery.Refusal as exc:
        _got = "probe failed" in str(exc)
    except Exception as exc:
        _got = False
        failures.append(f"{_label} — raised {type(exc).__name__} instead of Refusal")
    finally:
        battery.run = _real_run6
        battery.check_no_dev_app = _neutralised2
    if _got != _want_refusal:
        failures.append(f"{_label}: refused={_got}, wanted {_want_refusal}")
    else:
        print(f"  ok  {_label}")

# --- the operator-facing summary ------------------------------------------------
# Nothing rendered this block before: it was declared inside `main()`, after a full
# lane, so the self-test could not reach it. `classify_row` had a dozen cases and the
# text a human acts on had none — which is how "re-aim the RECIPE" survived here for a
# review round after being removed from the classifier one screen up.

# STRUCTURAL, and the strongest of the three: every verdict the module declares must
# have an entry. The old `.get(verdict, "")` rendered a BLANK line for an unmapped one,
# so adding a verdict constant would silently ship a report with no guidance under it.
# Closed set, enumerated from the module itself rather than a hand-written list, so a
# verdict added tomorrow is covered without editing this case.
ran += 1
# The set is the code's OWN partition, not every constant: `main` computes
# `bad = [r for r in results if r[0] != VERDICT_CAUGHT]`, so a CATCH never reaches
# the report and needs no entry. Derived that way rather than by a hand-written
# exclusion, so a verdict added later is covered without editing this case — the
# first version quantified over every VERDICT_* and reported CAUGHT as a defect.
_verdicts = {v for k, v in vars(battery).items()
             if k.startswith("VERDICT_") and isinstance(v, str)} - {battery.VERDICT_CAUGHT}
_unmapped = sorted(v for v in _verdicts if v not in battery.WHAT_IT_MEANS)
if _unmapped:
    failures.append(f"every declared verdict has operator guidance — {_unmapped} do not, so the "
                    f"report prints a blank line where the guidance belongs")
else:
    print("  ok  every declared verdict has operator guidance")

ran += 1
try:
    battery.explain_verdict("NOT-A-VERDICT")
    failures.append("an unmapped verdict fails loud rather than rendering a blank line — it did "
                    "not: explain_verdict returned instead of raising")
except AssertionError:
    print("  ok  an unmapped verdict fails loud rather than rendering a blank line")

# A verdict whose cause the statuses CANNOT determine must not be handed a single
# remediation here. `classify_row` says an unchanged test set has two causes and that
# the statuses cannot separate them; a summary line that picks one contradicts the
# classifier, and the summary is what gets acted on.
ran += 1
_noop = battery.WHAT_IT_MEANS[battery.VERDICT_NOOP]
_blames_recipe = "recipe" in _noop.lower()
_blames_test = "test" in _noop.lower()
if _blames_recipe and not _blames_test:
    failures.append(f"an undetermined cause is not given a single remediation in the summary — it "
                    f"is: {battery.VERDICT_NOOP} reads {_noop!r}, prescribing the RECIPE alone, while "
                    f"classify_row says the statuses cannot say which of two causes it is. The "
                    f"operator is sent to re-aim a recipe when the TEST may be at fault.")
else:
    print("  ok  an undetermined cause is not given a single remediation in the summary")

# PAIRED ACCEPTED CASE, so the check above cannot pass by refusing every summary that
# mentions a recipe. CAUGHT-ELSEWHERE has ONE cause the statuses do establish — another
# test went red — and its summary is allowed to say so plainly.
ran += 1
_elsewhere = battery.WHAT_IT_MEANS[battery.VERDICT_CAUGHT_ELSEWHERE]
if "different test caught it" not in _elsewhere:
    failures.append(f"a verdict whose cause IS established still states it plainly — it does not: "
                    f"CAUGHT-ELSEWHERE reads {_elsewhere!r}")
else:
    print("  ok  a verdict whose cause IS established still states it plainly")

# --- baseline()'s own exception handling ----------------------------------------
# `baseline` is replaced by `_stub_baseline` in every case that goes near it, so its
# handlers had never been executed. A nonexistent suite makes xcodebuild SUCCEED with
# an empty bundle, the read raises, and an uncaught raise printed a traceback instead
# of the diagnostic written for exactly that case.


class _RaisingLane:
    """A lane whose suite run fails in a named way. Only `run_suite` is reached."""

    def __init__(self, exc):
        self._exc = exc

    def run_suite(self, suite, tag):
        raise self._exc


class _CleanLane:
    def run_suite(self, suite, tag):
        return (5, [], True, Path("/tmp/x.log"), 0, 1.0,
                battery.SuiteResults({"S/a()": "Passed"}, {"a()": {"S/a()"}}, {}))


# CALLED ONCE, GUARDED, and both assertions read the result. The second case used to
# call `baseline` again with no guard, so under the very mutant these cases exist to
# catch it raised and took the whole self-test down before the summary printed — and
# the control then reported WRONG-RED on a mutant case one had detected perfectly. A
# case that can ABORT the run is worse than one that fails: it destroys every verdict
# after it, including its own.
_probs = None
ran += 1
try:
    _probs = battery.baseline(_RaisingLane(battery.BundleUnreadable("zero Test Case nodes")),
                              ["EnviousWisprTests/Gone"], "before")
except battery.BundleUnreadable:
    failures.append("an unreadable result bundle becomes a baseline problem — it did not: the "
                    "exception ESCAPED baseline, so main prints a traceback instead of the "
                    "diagnostic written for a nonexistent suite")
if _probs is None:
    pass
elif not _probs:
    failures.append("an unreadable result bundle becomes a baseline problem — it did not: baseline "
                    "reported NO problems, so a run against a nonexistent suite would proceed to "
                    "mutate")
elif "could not be read" not in _probs[0]:
    failures.append(f"an unreadable result bundle becomes a baseline problem — recorded, but with "
                    f"the wrong reason: {_probs[0][:120]}")
else:
    print("  ok  an unreadable result bundle becomes a baseline problem")

# The named cause has to survive into the message, because the message is the only
# thing that sends an operator to the right place — a stale suite name.
ran += 1
if not _probs:
    failures.append("the unreadable-bundle problem names the suite and the likely cause — there was "
                    "no problem recorded to name anything")
elif "@Suite" not in _probs[0] or "Gone" not in _probs[0]:
    failures.append(f"the unreadable-bundle problem names the suite and the likely cause — it does "
                    f"not: {_probs[0][:160]}")
else:
    print("  ok  the unreadable-bundle problem names the suite and the likely cause")

# PAIRED ACCEPTED CASE, so the handler above cannot pass by reporting a problem for
# everything: a suite that ran and passed produces NO problem.
ran += 1
_probs3 = battery.baseline(_CleanLane(), ["EnviousWisprTests/Fine"], "before")
if _probs3:
    failures.append(f"a clean suite produces no baseline problem — it produced {_probs3}")
else:
    print("  ok  a clean suite produces no baseline problem")

# And the pre-existing timeout path still works, so the new clause did not displace it.
ran += 1
_probs4 = battery.baseline(_RaisingLane(battery._LaneTimedOut("timed out at 900s")),
                           ["EnviousWisprTests/Slow"], "before")
if not _probs4 or "timed out" not in _probs4[0]:
    failures.append(f"a lane timeout is still a baseline problem — got {_probs4}")
else:
    print("  ok  a lane timeout is still a baseline problem")

# A canonical setup failure creates no fresh Debug log. That is neither a passing
# baseline nor a row verdict, but it must fail cleanly at the baseline boundary.
ran += 1
_probs5 = battery.baseline(
    _RaisingLane(battery._RowFailed("the canonical Debug log was not created by this lane")),
    ["EnviousWisprTests/Setup"], "before")
if not _probs5 or "canonical Debug log" not in _probs5[0]:
    failures.append(f"a canonical setup failure is a baseline problem — got {_probs5}")
else:
    print("  ok  a canonical setup failure becomes a baseline problem")

# UNREACHABLE IN PRODUCTION, PINNED ANYWAY. A lane that compiles and passes but yields
# no result bundle cannot happen as the callers stand: that branch requires `compiled`,
# and `run_suite` returns a SuiteResults whenever it compiled because the reader raises
# rather than returning None. The branch used to fall back to console-scraped names —
# the exact defect this branch removed, and console naming cannot see a parameterized
# test at all. An unreachable branch that WOULD be a defect if reachable is the one
# nothing can catch: no test, no review, no mutation row can enter it, so it is not
# wrong today and becomes wrong silently the moment some unrelated change makes it
# reachable. `baseline` takes its lane, so a fake one reaches it here and holds it.
class _NoResultsLane:
    def run_suite(self, suite, tag):
        return (5, [], True, Path("/tmp/x.log"), 0, 1.0, None)


ran += 1
_seen_nr = {}
_probs_nr = battery.baseline(_NoResultsLane(), ["EnviousWisprTests/Odd"], "before",
                             seen_names=_seen_nr)
if not _probs_nr:
    failures.append("a compiled lane with no result bundle refuses — it did not: baseline accepted "
                    "it, and would name tests from console text, which cannot see a parameterized "
                    "test at all")
elif _seen_nr:
    failures.append(f"a compiled lane with no result bundle refuses — it recorded names anyway: "
                    f"{_seen_nr}")
else:
    print("  ok  a compiled lane with no result bundle refuses rather than scraping the console")

# A second process must stop at the lock before it can mistake an in-flight backup for stale leftovers.
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    recipes = tmp / "r.json"
    recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
    battery.acquire_battery_lock(tmp)
    try:
        proc = subprocess.run(
            [sys.executable, str(BATTERY), "--recipes", str(recipes), "--worktree", str(tmp), "--dry-run"],
            capture_output=True, text=True, env=NEUTRAL_ENV,
        )
    finally:
        battery.release_battery_lock()
    out = proc.stdout + proc.stderr
    if proc.returncode != 2 or "already owns" not in out:
        failures.append("a concurrent battery refuses at the lock before preflight — it did not: "
                        + out.strip()[:250])
    else:
        print("  ok  a concurrent battery refuses at the worktree lock")

# --- a documented return shape must match the code ------------------------------
# `_STUB_ARITY` above pins run_suite's arity and says to update the stubs and the
# constant together. It said nothing about the DOCSTRING, so that drifted: it promised
# a 4-tuple while the function had returned 7 since this branch began, and it was found
# by an AST check during self-audit rather than by anyone reading it. A docstring is the
# one artifact with no compiler, so give it a mechanical check instead of an intention.
# Structural, over the AST — no text patterns, no phrase matching.
ran += 1
import ast as _ast_d  # noqa: E402
import re as _re_d  # noqa: E402
_tree_d = _ast_d.parse(Path(battery.__file__).read_text())
_mismatch = []
for _fn in _ast_d.walk(_tree_d):
    if not isinstance(_fn, (_ast_d.FunctionDef, _ast_d.AsyncFunctionDef)):
        continue
    _doc = _ast_d.get_docstring(_fn)
    if not _doc:
        continue
    _m = _re_d.search(r"\(([^)]*,[^)]*)\)", _doc.splitlines()[0])
    if not _m:
        continue
    _promised = len([p for p in _m.group(1).split(",") if p.strip()])
    _arities = {len(s.value.elts) for s in _ast_d.walk(_fn)
                if isinstance(s, _ast_d.Return) and isinstance(s.value, _ast_d.Tuple)}
    if _arities and _promised not in _arities:
        _mismatch.append(f"{_fn.name}: docstring promises {_promised}, code returns {sorted(_arities)}")
if _mismatch:
    failures.append("a documented return shape matches the code — it does not: " + "; ".join(_mismatch))
else:
    print("  ok  a documented return shape matches the code")

print()
if failures:
    print(f"{len(failures)} of {ran} FAILED:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"all {ran} cases passed")
