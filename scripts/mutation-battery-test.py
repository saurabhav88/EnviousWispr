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

NEUTRAL_ENV = dict(_os_env.environ,
                   EW_BATTERY_DEV_APP_PATTERN="ew-battery-self-test-matches-nothing")


# Mirrors the real scripts/xcode-test.sh closely enough for the drift guard to parse. Kept in this
# shape deliberately: a stub that does not resemble the artifact under test proves nothing about it.
CANONICAL_STUB = """#!/usr/bin/env bash
PROJECT="EnviousWispr.xcodeproj"
DEBUG_SCHEME="EnviousWispr"
DEST='platform=macOS,arch=arm64'
TEST_ARGS=(-only-testing:"$FILTER")
DERIVED_DATA="${DERIVED_DATA_PATH:-$PROJECT_ROOT/.derivedData/Test}"
mise x tuist@4.195.11 -- tuist generate --no-open
run_lane() {
  xcodebuild test \\
    -project "$PROJECT" \\
    -scheme "$scheme" \\
    -configuration "$config" \\
    -derivedDataPath "$DERIVED_DATA" \\
    -destination "$DEST" \\
    ARCHS=arm64 \\
    VALID_ARCHS=arm64 \\
    ONLY_ACTIVE_ARCH=YES \\
    "$@" \\
    "${TEST_ARGS[@]}" | tee "$PROJECT_ROOT/$log"
}
run_lane "$DEBUG_SCHEME" Debug build/xcode-test-debug.log
"""

# The exact line the two directional drift cases add to or remove from the stub. Derived from the
# stub itself rather than retyped, because a hand-typed copy of an escaped line is how both of
# these cases silently tested nothing the first time.
ONLY_ACTIVE = [l for l in CANONICAL_STUB.split("\n") if "ONLY_ACTIVE_ARCH" in l][0] + "\n"
assert ONLY_ACTIVE in CANONICAL_STUB, "the stub line the drift cases edit must exist verbatim"


def make_tree(tmp: Path):
    (tmp / "Sources").mkdir(parents=True, exist_ok=True)
    (tmp / "Sources" / "Thing.swift").write_text("let guarded = true\n")
    (tmp / "scripts").mkdir(parents=True, exist_ok=True)
    (tmp / "scripts" / "xcode-test.sh").write_text(CANONICAL_STUB)
    return tmp


def check(name, rows, *, expect_exit, expect_text=None, extra_files=None, top=None, remove=None):
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

check("an anchor absent from the target file is refused",
      [dict(VALID_ROW, anchor="this text is nowhere in the file")],
      expect_exit=2, expect_text="anchor not found")

check("a non-unique anchor is refused",
      [dict(VALID_ROW, anchor="x")],
      expect_exit=2, expect_text="must be unique",
      extra_files={"Sources/Thing.swift": "let x = 1\nlet y = x + x\n"})

# The runner reproduces scripts/xcode-test.sh's build settings rather than shelling out to it. That
# buys two sources of truth, so drift must be loud: if the canonical script stops carrying a setting
# this runner reproduces, the battery refuses rather than measuring a differently-configured build.
check("a canonical script with its invocation gone refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="could not find the `xcodebuild test",
      extra_files={"scripts/xcode-test.sh": "#!/usr/bin/env bash\n# gutted\n"})

check("a canonical script that DROPPED a setting refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="no longer passes",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(ONLY_ACTIVE, "")})

# The direction a presence-only check is blind to, and what cloud review flagged on PR #2158: the
# lane GAINS a setting, everything the runner already knew about is still there, and a
# one-directional guard stays green while the battery builds differently from the canonical lane.
check("a canonical script that ADDED a setting refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="does NOT reproduce",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          ONLY_ACTIVE, ONLY_ACTIVE + "    ENABLE_TESTABILITY=YES \\\\\n")})

# Each of these is the drift class at an axis the first two review rounds did not reach. Enumerated
# rather than waited for: two rounds of one shape is the signal to sweep the whole class yourself.
check("a canonical Debug call site switched to Release refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="no longer has",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          'run_lane "$DEBUG_SCHEME" Debug', 'run_lane "$RELEASE_SCHEME" Release')})

check("a canonical DerivedData default that moved refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="no longer has",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          ".derivedData/Test", ".derivedData/Somewhere")})

check("a bumped tuist pin refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="no longer has",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          "tuist@4.195.11", "tuist@4.200.0")})

# Round 3 of the drift class, at the axis the round-2 enumeration missed: it enumerated WHICH INPUTS
# decide the build, not HOW an argument can arrive. An argument reaching xcodebuild through a variable
# used to be dropped, so indirection read as absence.
# The call site was matched as a PREFIX, so trailing positionals — which reach xcodebuild through
# `"$@"`, accepted by the expansion allowlist without its contents being visible — slipped past.
check("extra positional build settings on the canonical call site refuse the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="no longer has",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          'run_lane "$DEBUG_SCHEME" Debug build/xcode-test-debug.log',
          'run_lane "$DEBUG_SCHEME" Debug build/xcode-test-debug.log ENABLE_TESTABILITY=YES')})

check("an unrecognised shell expansion in the invocation refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="cannot see",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          '    "$@" ', '    "${EXTRA_ARGS[@]}" ')})

# Fifth instance of the drift class, and answered as a BOUND rather than another enumerated axis: the
# runner invokes xcodebuild with its ambient environment, so anything running BEFORE xcodebuild means
# the canonical lane can use a different toolchain. Required to be empty; no prefix list to maintain.
check("an environment prefix before xcodebuild refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="runs BEFORE xcodebuild",
      extra_files={"scripts/xcode-test.sh": CANONICAL_STUB.replace(
          "  xcodebuild test \\",
          "  DEVELOPER_DIR=/other/Xcode.app/Contents/Developer xcodebuild test \\")})

check("a missing canonical script refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="cannot confirm it is building the same thing",
      remove=["scripts/xcode-test.sh"])

# A recipe arrives from an issue body, which is data someone else wrote. It may not reach out of
# the worktree — an absolute path, a `..`, or a symlink would otherwise have the battery back up,
# mutate and restore a file it was never scoped to.
# `generate_once` reuses one generated project for every row, which is only sound while a mutation
# changes file CONTENT rather than the project's SHAPE. A recipe targeting a Tuist input would leave
# xcodebuild consuming the clean baseline's .xcodeproj, so the row reports SURVIVED about a mutant the
# build never saw. A doc comment asserted this precondition from the start; nothing enforced it.
for _t in ("Project.swift", "Tuist/Config.swift", "Package.swift"):
    check(f"a recipe targeting {_t} is refused as out of scope",
          [dict(VALID_ROW, file=_t)],
          expect_exit=2, expect_text="the generated Xcode project is BUILT FROM")

# The accepted counterpart: an ordinary Sources file with a similar-looking name must still pass.
check("a Sources file whose name merely resembles a Tuist input is accepted",
      [dict(VALID_ROW, file="Sources/Thing.swift")],
      expect_exit=0, expect_text="1 row(s) well-formed")

check("an absolute target path is refused",
      [dict(VALID_ROW, file="/etc/hosts")],
      expect_exit=2, expect_text="must be repo-relative")

check("a target escaping the worktree with .. is refused",
      [dict(VALID_ROW, file="../outside.swift")],
      expect_exit=2, expect_text="resolves OUTSIDE the worktree")

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
        battery.baseline = lambda lane, suites, phase: []
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
          (5, ["✘ Test \"the guard holds\" recorded an issue"], True, "log", 65, 3.0),
          expect_marker="ok", expect_rc=0)

check_row("the suite staying green scores SURVIVED, not a pass",
          (5, [], True, "log", 0, 3.0),
          expect_marker="SURV", expect_rc=1)

check_row("a DIFFERENT test failing is SURVIVED — something else caught it, so this test is not the guard",
          (5, ["✘ Test \"some other case\" recorded an issue"], True, "log", 65, 3.0),
          expect_marker="SURV", expect_rc=1)

check_row("zero executed tests is an ERROR, never a survivor and never a catch",
          (0, [], True, "log", 0, 3.0),
          expect_marker="ERR", expect_rc=1)

check_row("no test summary at all is an ERROR",
          (None, [], True, "log", 65, 3.0),
          expect_marker="ERR", expect_rc=1)

check_row("a mutant that does not compile is an ERROR — a red lane proves nothing if nothing ran",
          (None, [], False, "log", 65, 3.0),
          expect_marker="ERR", expect_rc=1)

# The most dangerous defect this tool has had, and it is invisible to a byte comparison. `copy2`
# restores the original MODIFICATION TIME along with the bytes. Against warm DerivedData, a replacement
# the SAME SIZE as its anchor therefore leaves a file that is byte-identical AND older than the object
# compiled from the mutant, so the next row can run mutant code while every check reports clean.
ran += 1
_res = drive_row((5, ['✘ Test "the guard holds" recorded an issue'], True, "log", 65, 3.0),
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
            return (5, ['✘ Test "the guard holds" recorded an issue'], True, "log", 65, 3.0)

    _rl, _rb = battery.Lane, battery.baseline
    battery.Lane, battery.baseline = _StubLane, (lambda lane, suites, phase: [])
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
    _arity = len([t for t in _returns[0].split(",")])
    if _arity != 6:
        failures.append(
            "the stubbed lane returns the same shape as the real one: "
            f"Lane.run_suite now returns {_arity} values, but the stubbed-lane cases hand back 6. "
            "Update the stub, or every row case is exercising a double that no longer resembles the "
            "real lane.")
    else:
        print("  ok  the stubbed lane returns the same shape as the real one")

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
    battery.Lane, battery.baseline = _HangingLane, (lambda lane, suites, phase: [])
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


def _capture(cmd, cwd, log_path=None, timeout=None):
    _seen_kwargs["timeout"] = timeout
    return 0, "Test run with 1 test\n"


_real_run = battery.run
battery.run = _capture
try:
    _lane = battery.Lane(Path("."), Path("."), Path("."))
    _lane.generated = True  # skip tuist; this case is about the test lane's timeout only
    _lane.run_suite("EnviousWisprTests/Whatever", "tag")
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

print()
if failures:
    print(f"{len(failures)} of {ran} FAILED:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"all {ran} cases passed")
