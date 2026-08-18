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


CANONICAL_STUB = """#!/usr/bin/env bash
PROJECT="EnviousWispr.xcodeproj"
DEBUG_SCHEME="EnviousWispr"
DEST='platform=macOS,arch=arm64'
TEST_ARGS=(-only-testing:"$FILTER")
ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
"""


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
            capture_output=True, text=True,
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

check("no suite and no default is refused",
      [{k: v for k, v in VALID_ROW.items() if k != "suite"}],
      expect_exit=2, expect_text="no suite and no suite_default")

check("a target file that does not exist is refused",
      [dict(VALID_ROW, file="Sources/Absent.swift")],
      expect_exit=2, expect_text="target does not exist")

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
check("a canonical script that has drifted refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="differently-configured build",
      extra_files={"scripts/xcode-test.sh": "#!/usr/bin/env bash\n# settings removed\n"})

check("a missing canonical script refuses the run",
      [dict(VALID_ROW)], expect_exit=2, expect_text="cannot confirm it is building the same thing",
      remove=["scripts/xcode-test.sh"])

# --- flag-combination guard -----------------------------------------------------------------------
ran += 1
with tempfile.TemporaryDirectory() as td:
    tmp = make_tree(Path(td))
    recipes = tmp / "recipes.json"
    recipes.write_text(json.dumps({"rows": [dict(VALID_ROW)]}))
    proc = subprocess.run(
        [sys.executable, str(BATTERY), "--recipes", str(recipes), "--worktree", str(tmp),
         "--validate-only", "--dry-run"],
        capture_output=True, text=True,
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


check_issue("an issue with exactly one recipe block is accepted",
            rc=0, body='prose\n```json\n{"rows": [1]}\n```\n', expect_ok=True)
check_issue("an issue carrying NO recipe block is refused",
            rc=0, body="prose with no recipe at all\n", expect_text="carries no ```json recipe block")
check_issue("an issue carrying TWO recipe blocks is refused rather than picking the first",
            rc=0, body='```json\n{"a":1}\n```\n```json\n{"b":2}\n```\n',
            expect_text="carries 2 ```json blocks")
check_issue("a failed `gh` call is refused, never treated as an empty issue",
            rc=1, body="could not resolve to an Issue", expect_text="could not read issue #2156")

print()
if failures:
    print(f"{len(failures)} of {ran} FAILED:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"all {ran} cases passed")
