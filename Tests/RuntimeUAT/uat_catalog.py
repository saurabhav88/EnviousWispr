#!/usr/bin/env python3
"""The closed sets behind `uat.py` (#2775): which recipes exist, which harness
functions can be trusted, and where the written recipes live.

ONE OWNER for facts that used to live in four places and disagreed: the
wispr-eyes skill, the wispr-eyes agent definition, `code-tooling.md`
FACT: uat-tool-boundaries, and each session's memory. `uat.py recipes` prints
this module; the docs point here rather than carrying their own copy.

The self-test parses `wispr_eyes.py` with `ast` (never imports it, so this runs
on the hosted runner, #2426) and requires `HARNESS_STATUS` to cover every
public top-level name in BOTH directions. A new public function with no row
FAILS CI; a row for a deleted function FAILS CI. That is the mechanism that
keeps the table honest, not anyone's diligence.

    python3 Tests/RuntimeUAT/uat_catalog.py --self-test
"""

import ast
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WISPR_EYES = os.path.join(HERE, "wispr_eyes.py")
SCENARIOS_MD = os.path.join(HERE, "SCENARIOS.md")

# --------------------------------------------------------------------------
# Recipes: the closed set `uat.py run <id>` accepts and the validators check.
# `function` must be a HARNESS_STATUS key with status `recipe`.
# `audio` says whether the recipe plays sound through the speaker (and so is
# refused when the output is muted or below the floor).
# --------------------------------------------------------------------------
RECIPES = {
    "heart-path": {
        "function": "test_recording",
        "purpose": "Menu-driven record -> TTS through the speaker -> stop -> pipeline completes. "
                   "The default Code-lane Live UAT: proves capture, ASR, polish and delivery still work.",
        "verdict": "app.log: `Pipeline timing TOTAL` + the CORRECTION_DEBUG chain; expected token in the final text",
        "audio": True,
        "needs": "one debug instance of THIS worktree's build; speaker unmuted >= 25; Accessibility",
    },
    "ptt": {
        "function": "test_ptt",
        "purpose": "Hold the configured push-to-talk key for the audio's duration; verifies overlay states and delivery.",
        "verdict": "app.log completion marker + overlay states seen; binding resolved by ptt_binding (refuses on doubt, #1997)",
        "audio": True,
        "needs": "push-to-talk mode in Settings; speaker unmuted; Accessibility",
    },
    "quality": {
        "function": "record_tts",
        "purpose": "One dictation whose raw ASR and polished output are read from the log. For transcription/polish quality questions.",
        "verdict": "app.log CORRECTION_DEBUG rows, read WHOLE by uat.py verdict (record_tts's own `polished` field is one line, #2547)",
        "audio": True,
        "needs": "push-to-talk mode; speaker unmuted; Accessibility",
    },
    "silent-probe": {
        "function": "test_recording",
        "purpose": "Record 6 s of TRUE silence (plays a silent wav, not a TTS clip). The control for an occupied "
                   "room: words in the transcript mean someone is talking near the mic and every audio verdict this "
                   "session is suspect (#2123).",
        "verdict": "WORD COUNT of the raw transcript on a COMPLETED take; a failed take is inconclusive, not quiet",
        "audio": False,
        "needs": "Accessibility. Safe during someone's call: it plays only silence",
        # No static kwargs: `uat.py run silent-probe` and `preflight --silent-probe`
        # route through `run_silent_probe`, which feeds a real silent wav so the
        # hold stays 6 s and no speech service is invoked.
    },
}

# --------------------------------------------------------------------------
# Every public top-level name in wispr_eyes.py, with what a session may trust
# it for. Statuses:
#   recipe     - drives an end-to-end flow and returns a verdict; RECIPES may use it
#   primitive  - a building block; fine to call, produces no verdict on its own
#   unreliable - known to lie in a named way; use only with the note's workaround
#   broken     - returns a verdict for something that did not happen; never use
# Source of the judgments: code-tooling.md FACT: uat-tool-boundaries and the
# issues cited. Change the table when the code changes, never the other way.
# --------------------------------------------------------------------------
HARNESS_STATUS = {
    # recipes
    "test_recording":  {"status": "recipe", "issue": None, "note": "menu-driven; log verdict, clipboard fallback only when Debug Mode is off"},
    "test_ptt":        {"status": "recipe", "issue": None, "note": "needs run_in_background (CGEvent); FAIL with `asr_empty_despite_audio` usually means TTS went to a Bluetooth output"},
    "record_tts":      {"status": "recipe", "issue": "#2547", "note": "`polished` is ONE LINE; read multi-line output with uat.py verdict. focus_app takes an APP NAME, not a bundle id"},
    "test_cancel":     {"status": "broken", "issue": "code-tooling", "note": "cancels via a synthetic Escape, which does NOT reach the Carbon hotkey (code-tooling.md FACT: synthetic-escape-does-not-reach-a-carbon-hotkey), so it reports FAIL on a working app. Not a runnable recipe; cancel needs a human press until a real driver exists"},
    # broken / unreliable
    "test_hands_free": {"status": "broken", "issue": "#2409", "note": "drives the MENU and cannot engage hands-free lock; returns PASS for a gesture that never fired. Use double_press_record_key"},
    "test_all":        {"status": "primitive", "issue": None, "note": "chains scan()/check(); those work now (#1296 nav defect is FIXED). A long AX sweep of every tab: informational, never a release gate"},
    "check":           {"status": "primitive", "issue": None, "note": "nav(tab) + read(label); the #1296 nav defect is FIXED. Reads Settings via AX, so treat output as informational, not a hard pass/fail"},
    "verify":          {"status": "primitive", "issue": None, "note": "nav(tab) + read(); #1296 is FIXED. AX read, informational"},
    "scan":            {"status": "primitive", "issue": None, "note": "reads every tab via nav()+read(); #1296 is FIXED. Slow AX sweep, informational"},
    "check_ai_diagnostics": {"status": "primitive", "issue": None, "note": "#1296 is FIXED. AX read of the AI Polish diagnostics pane"},
    "nav":             {"status": "primitive", "issue": None, "note": "drives the button sidebar directly; the #1296 AXOutline->AXButton swap is FIXED and switch_backend relies on nav. Auto-opens Settings if closed"},
    "tap":             {"status": "primitive", "issue": None, "note": "the #2511 NOT FOUND for a button whose AXValue holds a state (Dictionary sub-tabs) is FIXED: matching reads every text attribute via _names(), display still reads the first via _txt(). Bound by the self-test's see()/tap() property row"},
    "look":            {"status": "primitive", "issue": None, "note": "exploration only; never a pass/fail source"},
    "see":             {"status": "primitive", "issue": None, "note": "PRINTS the tree and returns None; capture with redirect_stdout, never str(see())"},
    "clipboard":       {"status": "primitive", "issue": None, "note": "fallback signal only; verdicts come from app.log (RULE: uat-verdicts-from-app-log)"},
    # primitives
    "connect":         {"status": "primitive", "issue": None, "note": "attaches to WHATEVER holds the dev slot; uat.py preflight proves it is this worktree's build"},
    "health":          {"status": "primitive", "issue": None, "note": ""},
    "read":            {"status": "primitive", "issue": None, "note": ""},
    "read_cards":      {"status": "primitive", "issue": None, "note": ""},
    "menu":            {"status": "primitive", "issue": None, "note": ""},
    "type_text":       {"status": "primitive", "issue": None, "note": "CGEvent: run_in_background"},
    "press_key":       {"status": "primitive", "issue": None, "note": "CGEvent: run_in_background"},
    "hold_key":        {"status": "primitive", "issue": None, "note": "CGEvent: run_in_background"},
    "scroll":          {"status": "primitive", "issue": None, "note": "CGEvent: run_in_background"},
    "wait_for":        {"status": "primitive", "issue": None, "note": ""},
    "select_word_at":  {"status": "primitive", "issue": None, "note": ""},
    "modifier_flags":  {"status": "primitive", "issue": None, "note": ""},
    "clear_modifier_flags": {"status": "primitive", "issue": None, "note": "after any CGEvent drive that could leave a modifier stuck"},
    "acquisition_verdict": {"status": "primitive", "issue": None, "note": "selection-acquisition route reading"},
    "screenshot":      {"status": "primitive", "issue": None, "note": "needs Screen Recording; WINDOW capture, never full screen"},
    "zoom":            {"status": "primitive", "issue": None, "note": ""},
    "record":          {"status": "primitive", "issue": None, "note": "screen video around a flow; pick the frame afterwards (README)"},
    "Recording":       {"status": "primitive", "issue": None, "note": "context manager behind record()"},
    "batch":           {"status": "primitive", "issue": None, "note": ""},
    "begin_test":      {"status": "primitive", "issue": None, "note": ""},
    "end_test":        {"status": "primitive", "issue": None, "note": ""},
    "close_window":    {"status": "primitive", "issue": None, "note": ""},
    "switch_backend":  {"status": "primitive", "issue": None, "note": ""},
    "tts":             {"status": "primitive", "issue": None, "note": "OpenAI echo by default; macOS say offline; NEVER for non-English (Azure)"},
    "press_record_key": {"status": "primitive", "issue": None, "note": ""},
    "single_press_record_key": {"status": "primitive", "issue": None, "note": ""},
    "double_press_record_key": {"status": "primitive", "issue": None, "note": "the working hands-free gesture; retries and reads its own markers"},
    "stop_after_short_hold": {"status": "primitive", "issue": None, "note": ""},
    "log_lines_since": {"status": "primitive", "issue": None, "note": "rotation-proof reader of STAMPED lines; for content use log_entries_since"},
    "log_entries_since": {"status": "primitive", "issue": None, "note": "rotation-proof reader that keeps multi-line CORRECTION_DEBUG blocks whole; the content reader"},
    "launch_banners_since": {"status": "primitive", "issue": None, "note": "debug-build + Debug Mode proof"},
    "count_launch_banners": {"status": "primitive", "issue": None, "note": ""},
    "instances_stayed_single": {"status": "primitive", "issue": None, "note": ""},
    "list_scenarios":  {"status": "primitive", "issue": None, "note": "fault-injection menu (SCENARIOS.md)"},
    "run_scenario":    {"status": "primitive", "issue": None, "note": "needs the debug build launched with EW_FAULT_INJECTION=1"},
    "record_with_fault": {"status": "primitive", "issue": None, "note": ""},
}

# --------------------------------------------------------------------------
# Where the written recipes live. Gitignored files are reached through the MAIN
# worktree, because a feature worktree has no `.claude/` at all and a relative
# read there returns "no such file" (validation-discipline.md silent-empty table).
# --------------------------------------------------------------------------
DOC_FILES = (
    ".claude/knowledge/uat-testing.md",
    ".claude/rules/code-uat.md",
    ".claude/rules/code-tooling.md",
)
HEADING = re.compile(r"^## (FACT|RULE|PROC): (.*)$")
SCENARIO_HEADING = re.compile(r"^### (\S+)")


class DocsUnreadable(RuntimeError):
    pass


def main_worktree(start=HERE):
    """Absolute path of the MAIN worktree for the repo containing `start`.
    `git worktree list --porcelain` prints the main worktree first."""
    try:
        out = subprocess.run(["git", "-C", start, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=10, check=True).stdout
    except (OSError, subprocess.SubprocessError) as e:
        raise DocsUnreadable(f"git worktree list failed: {e}")
    for line in out.splitlines():
        if line.startswith("worktree "):
            return line[len("worktree "):].strip()
    raise DocsUnreadable("git worktree list printed no worktree line")


def doc_index(main_root=None, scenarios_md=SCENARIOS_MD):
    """[(file, line, heading)] for every recipe heading. Raises DocsUnreadable
    naming the first missing file: an EMPTY index would read as 'no recipes',
    which is the failure this whole module exists to stop."""
    root = main_root or main_worktree()
    entries = []
    for rel in DOC_FILES:
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    m = HEADING.match(line.rstrip("\n"))
                    if m:
                        entries.append((rel, n, f"{m.group(1)}: {m.group(2)}"))
        except OSError:
            raise DocsUnreadable(path)
    try:
        with open(scenarios_md, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                m = SCENARIO_HEADING.match(line)
                if m:
                    entries.append(("Tests/RuntimeUAT/SCENARIOS.md", n, f"SCENARIO: {m.group(1)}"))
    except OSError:
        raise DocsUnreadable(scenarios_md)
    return entries


def public_names(path=WISPR_EYES):
    """Top-level public def/class names of wispr_eyes.py by STATIC parse."""
    tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
    return sorted(n.name for n in tree.body
                  if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
                  and not n.name.startswith("_"))


# ---------------------------------------------------------------- printing --

def render(entries=None, include_docs=True):
    lines = ["== RECIPES (uat.py run <id>) =="]
    for rid, r in RECIPES.items():
        lines.append(f"  {rid:13} -> {r['function']}()  [{'audio' if r['audio'] else 'no audio'}]")
        lines.append(f"      {r['purpose']}")
        lines.append(f"      verdict: {r['verdict']}")
        lines.append(f"      needs:   {r['needs']}")
    lines.append("")
    lines.append("== HARNESS FUNCTION STATUS (Tests/RuntimeUAT/wispr_eyes.py) ==")
    order = {"recipe": 0, "broken": 1, "unreliable": 2, "primitive": 3}
    for name, row in sorted(HARNESS_STATUS.items(), key=lambda kv: (order[kv[1]["status"]], kv[0])):
        tag = row["status"].upper() + (f" {row['issue']}" if row["issue"] else "")
        note = f"  - {row['note']}" if row["note"] else ""
        lines.append(f"  {tag:18} {name}{note}")
    if include_docs:
        lines.append("")
        lines.append("== WRITTEN RECIPES (read the entry with: sed -n '<line>,+40p' <main-worktree>/<file>) ==")
        for rel, n, heading in entries or []:
            lines.append(f"  {rel}:{n}  {heading}")
    return "\n".join(lines)


# ---------------------------------------------------------------- self-test --

def _self_test():
    import tempfile
    failures, ran = [], []

    def check(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        ran.append(name)
        if not cond:
            failures.append(name)

    names = set(public_names())
    rows = set(HARNESS_STATUS)
    missing = sorted(names - rows)
    stale = sorted(rows - names)
    check(f"every public wispr_eyes name has a status row (missing: {missing})", not missing)
    check(f"every status row names a live function (stale: {stale})", not stale)
    check("statuses are from the closed set",
          all(r["status"] in ("recipe", "primitive", "unreliable", "broken") for r in HARNESS_STATUS.values()))
    check("broken/unreliable rows cite an issue",
          all(r["issue"] for r in HARNESS_STATUS.values() if r["status"] in ("broken", "unreliable")))
    check("every recipe function is a `recipe`-status row",
          all(HARNESS_STATUS.get(r["function"], {}).get("status") == "recipe" for r in RECIPES.values()))
    check("recipe ids are shell-safe", all(re.fullmatch(r"[a-z][a-z0-9-]*", rid) for rid in RECIPES))
    check("test_hands_free is broken (#2409)", HARNESS_STATUS["test_hands_free"]["status"] == "broken")

    with tempfile.TemporaryDirectory() as tmp:
        for rel in DOC_FILES:
            os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
            with open(os.path.join(tmp, rel), "w") as fh:
                fh.write("# x\n\n## FACT: planted-heading\nbody\n## not a heading\n")
        scen = os.path.join(tmp, "SCENARIOS.md")
        with open(scen, "w") as fh:
            fh.write("# s\n### A1_planted (Lane A)\n")
        idx = doc_index(tmp, scen)
        check("doc_index finds planted headings with line numbers",
              len(idx) == len(DOC_FILES) + 1 and idx[0][1] == 3 and idx[-1][2] == "SCENARIO: A1_planted")
        os.remove(os.path.join(tmp, DOC_FILES[1]))
        try:
            doc_index(tmp, scen)
            check("doc_index raises on a missing file", False)
        except DocsUnreadable as e:
            check("doc_index raises on a missing file (names it)", DOC_FILES[1] in str(e))

    check("render() lists every recipe id", all(rid in render([], False) for rid in RECIPES))

    total = len(ran)
    if failures:
        print(f"\nuat_catalog self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\nuat_catalog self-test: {total}/{total} passed")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    if "--names" in sys.argv:
        print("\n".join(RECIPES))
        sys.exit(0)
    try:
        print(render(doc_index()))
    except DocsUnreadable as e:
        print(render([], False))
        print(f"\nDOCS UNREADABLE: {e}", file=sys.stderr)
        sys.exit(3)
