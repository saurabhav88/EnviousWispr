#!/usr/bin/env python3
"""Dictation verdicts from `app.log` lines, as records rather than greps (#2775).

THE ONE COLLECTOR. Four sessions between 2026-08-05 and 2026-09-05 each wrote
their own reader of the same log and each re-derived the same four traps:

  * `CORRECTION_DEBUG [<step>] OUT: <text>` spans MANY lines whenever the model
    emits a list or an email envelope. The continuation lines carry no
    timestamp. A reader that stops at the first newline reports `Hi Sam,` for a
    six-line envelope and files a product defect against working behaviour
    (`code-uat.md` RULE: read-a-multi-line-polish-from-the-LOG-BLOCK-not-the-harness-field).
  * TWO forms ship: `[STEP] OUT: <text>` (the IN/OUT pair) and the bare
    `[STEP] <text>` used by `RAW ASR` and the per-step rows, which is the
    majority. Handling one form reports ZERO transcripts against a log full of
    them (`code-tooling.md` RULE: uat-instrument-needs-both-log-formats).
  * `no change` and `IN:` are STATUS, never content.
  * The file rotates and is written by more than one process, so reading it is
    `wispr_eyes.log_lines_since`'s job. This module never opens the log; it is
    handed lines.

Producers, so a reader can check the shapes against the source rather than
against this docstring:
  `Sources/EnviousWisprPipeline/TextProcessingRunner.swift`  CORRECTION_DEBUG rows
  `Sources/EnviousWisprServices/TelemetryService.swift`      dictation_terminal
  `Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift`  Pipeline timing TOTAL

Imports nothing heavy on purpose, so the self-test runs on the hosted runner
(#2426 split):

    python3 Tests/RuntimeUAT/log_verdict.py --self-test
"""

import re
import sys

# `AppLogger` stamps every line `[<ISO-8601>] [<LEVEL>] [<category>] <message>`.
# A continuation line of a multi-line OUT block has NO stamp, which is how the
# collector tells the two apart.
LINE = re.compile(r"^\[(?P<ts>\d{4}-[^\]]+)\]\s+\[(?P<level>[A-Z]+)\]\s+\[(?P<cat>[^\]]+)\]\s+(?P<msg>.*)$")

# A dictation is anchored on its terminal row because that is the one line every
# ending emits. Fields after `backend=` vary by release and are kept as a tail.
TERMINAL = re.compile(
    r"dictation_terminal result=(?P<result>\S+) reason=(?P<reason>\S+) take=(?P<take>\S+) "
    r"backend=(?P<backend>\S+)(?P<tail>.*)$")

# Both CORRECTION_DEBUG forms. `marker` captures the `OUT:` of the pair form so
# the two can be told apart: an OUT row is always real output and is never
# treated as status, while a BARE row may be a status marker.
CORRECTION = re.compile(r"CORRECTION_DEBUG \[(?P<step>[^\]]+)\] (?P<marker>OUT: )?(?P<head>.*)$")
# Status markers on a BARE row only. `no change` is the exact producer string
# (TextProcessingRunner writes `[step] no change`), so anchor it to the whole
# field — otherwise a real transcript like `no changes are needed` is discarded.
# `IN:` is the input echo of the pair form and is not the output.
CORRECTION_STATUS = re.compile(r"^(no change$|IN:)")

# The snippet sentinel prefix (SnippetExpander.prefix = "EWSNIP"). A logged step
# still carrying it is a PRE-finalization placeholder, not delivered text.
_SNIPPET_PLACEHOLDER = "EWSNIP"

PIPELINE_TOTAL = re.compile(r"Pipeline timing TOTAL: (?P<total>[0-9.]+s)")
VAD_DETAIL = re.compile(
    r"VAD detail: segments=(?P<segments>\d+), voicedMs=(?P<voiced_ms>\d+), "
    r"rawSamples=(?P<raw>\d+), filteredSamples=(?P<filtered>\d+), voicedPct=(?P<pct>[\d.]+)%")


def collect_dictations(lines):
    """One record per completed dictation, in log order.

    Each record: {ts, result, reason, take, backend, raw_asr, steps, pipeline_total, vad}
    where `steps` is an ordered dict of step name -> FULL text (all continuation
    lines joined with newlines). Rows seen before the first terminal marker are
    attached to that marker; rows after the last one are discarded, because a
    dictation with no terminal row has not finished and must not be reported as
    a result.
    """
    records, pending = [], {"steps": {}}
    i = 0
    while i < len(lines):
        m = LINE.match(lines[i])
        if not m:
            i += 1
            continue
        msg, ts = m.group("msg"), m.group("ts")

        c = CORRECTION.search(msg)
        if c:
            head = c.group("head")
            is_out = bool(c.group("marker"))
            is_raw = c.group("step") == "RAW ASR"
            # Skip status ONLY on a bare, non-RAW row. RAW ASR is always content;
            # an OUT row is always real output even if it happens to read like a
            # status word. Normalise with `.strip()` for the STATUS MATCH only.
            if not is_out and not is_raw and CORRECTION_STATUS.match(head.strip()):
                i += 1
                continue
            body = [head]
            j = i + 1
            while j < len(lines) and not LINE.match(lines[j]):
                body.append(lines[j].rstrip("\n"))
                j += 1
            # Preserve CONTENT whitespace: only surrounding blank lines are
            # boundary noise, so strip newlines but never the indentation inside a
            # line. Stripping the first line and the whole block changed indented
            # output and made a reviewer see inconsistent indentation the app never
            # produced (local Codex review, PR #2780; code-uat.md requires the
            # reader preserve output shape). Emptiness is checked with `.strip()`
            # elsewhere, so trailing spaces here do not leak into a verdict.
            text = "\n".join(body).strip("\n")
            if c.group("step") == "RAW ASR":
                # RAW ASR is the FIRST row of a dictation's processing chain, so
                # start a fresh step set here. A file import ALSO runs
                # TextProcessingRunner and emits correction rows with NO
                # dictation_terminal (cloud Codex review, PR #2780); without this
                # reset its steps would linger in `pending` and be read as the
                # NEXT live take's delivered text — a false verdict. pipeline_total
                # is re-emitted at every completion and vad is diagnostic only.
                pending["steps"] = {}
                pending["raw_asr"] = text
            else:
                pending["steps"][c.group("step")] = text
            i = j
            continue

        p = PIPELINE_TOTAL.search(msg)
        if p:
            pending["pipeline_total"] = p.group("total")

        v = VAD_DETAIL.search(msg)
        if v:
            pending["vad"] = v.groupdict()

        t = TERMINAL.search(msg)
        if t:
            rec = {
                "ts": ts,
                "result": t.group("result"),
                "reason": t.group("reason"),
                "take": t.group("take"),
                "backend": t.group("backend"),
                "raw_asr": pending.get("raw_asr"),
                "steps": pending["steps"],
                "pipeline_total": pending.get("pipeline_total"),
                "vad": pending.get("vad"),
            }
            records.append(rec)
            pending = {"steps": {}}
        i += 1
    return records


def final_text(record):
    """What the user actually received: the last NON-EMPTY step, else raw ASR.

    A limb that returns empty text does not blank the delivery — the pipeline's
    empty-output recovery floor delivers the last successful text (deterministic
    or raw ASR), per CLAUDE.md's Heart-and-Limbs principle. But the empty polish
    OUT row is still IN the log, so taking the literal last step would report ''
    and fail a take the user saw succeed (Codex diff review r3). Walk the steps
    backward to the last non-empty one, then fall back to raw ASR."""
    # The DELIVERED text is not always in the log. Exactly two transforms change
    # it AFTER the logged CORRECTION_DEBUG chain, and neither result is logged
    # (KernelFinalizationWiring, verified PR #2780):
    #   1. SnippetFinalizer — a snippet expansion, marked by the EWSNIP sentinel
    #      anywhere in the chain (even when a later polish step dropped it);
    #   2. emptyOutputRecoveryFloor — when the FINAL output is empty, the app
    #      delivers a deterministic floor or the raw ASR, computed off-log.
    # ITN and emoji-restore run INSIDE the logged chain, so they are not in this
    # set. When either post-log transform applied, the delivered text is
    # UNRECONSTRUCTABLE from the log, so return None -> classify reports the take
    # inconclusive (exit 2) rather than judging it against text the log never
    # held (code-tooling.md RULE: uat-verdicts-from-app-log). Otherwise the final
    # (last) step is the delivered text; with no steps it is the raw ASR.
    steps = record.get("steps") or {}
    if any(_SNIPPET_PLACEHOLDER in (v or "") for v in steps.values()):
        return None
    step_texts = list(steps.values())
    if not step_texts:
        return record.get("raw_asr")
    last = step_texts[-1]
    if last and last.strip():
        return last
    return None


def format_record(n, rec, width=400):
    out = [f"-- {n}. {rec['ts']}  result={rec['result']}  reason={rec['reason']}  backend={rec['backend']}"]
    vad = rec.get("vad")
    if vad:
        out.append(f"     VAD kept {vad['pct']}%  ({vad['filtered']}/{vad['raw']} samples, "
                   f"{vad['segments']} segment(s), {vad['voiced_ms']} ms voiced)")
    if rec.get("raw_asr") is not None:
        out.append(f"     [RAW ASR] {rec['raw_asr'][:width]}")
    for step, text in rec["steps"].items():
        shown = text if len(text) <= width else text[:width] + " ..."
        out.append(f"     [{step}] " + shown.replace("\n", "\n" + " " * 5 + "| "))
    if rec.get("pipeline_total"):
        out.append(f"     Pipeline TOTAL {rec['pipeline_total']}")
    return "\n".join(out)


# ---------------------------------------------------------------- self-test --

def _self_test():
    T = "[2026-09-10T10:00:0{s}-04:00] [INFO] [Pipeline] "
    D = "[2026-09-10T10:00:0{s}-04:00] [DEBUG] [TextProcessing] "

    def t(s, msg):
        return T.format(s=s) + msg

    def d(s, msg):
        return D.format(s=s) + msg

    terminal = "dictation_terminal result=delivered reason=nil take=abc backend=parakeet route=ax"
    failures, ran = [], []

    def check(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        ran.append(name)
        if not cond:
            failures.append(name)

    # Both forms, a 3-line OUT block, a status row skipped, one terminal.
    lines = [
        d(1, "CORRECTION_DEBUG [RAW ASR] hi sam this is a test"),
        d(2, "CORRECTION_DEBUG [Word Correction] no change"),
        d(3, "CORRECTION_DEBUG [Filler Removal] hi sam this is a test"),
        d(4, "CORRECTION_DEBUG [LLM Polish] IN:  hi sam this is a test"),
        d(5, "CORRECTION_DEBUG [LLM Polish] OUT: Hi Sam,"),
        "",
        "This is a test.",
        "Thanks",
        t(6, "Pipeline timing TOTAL: 1.234s (asr 0.4s polish 0.8s)"),
        t(7, "VAD detail: segments=1, voicedMs=1800, rawSamples=48000, filteredSamples=28800, voicedPct=60.0%"),
        t(8, terminal),
    ]
    recs = collect_dictations(lines)
    check("one terminal row -> one record", len(recs) == 1)
    r = recs[0] if recs else {"steps": {}}
    check("bare form captured as RAW ASR", r.get("raw_asr") == "hi sam this is a test")
    check("'no change' is status, not a step", "Word Correction" not in r["steps"])
    check("'IN:' is status, not a step", r["steps"].get("LLM Polish", "").startswith("Hi Sam"))
    # A real transcript that merely STARTS with 'no change' must survive (Codex diff review).
    nc = [d(1, "CORRECTION_DEBUG [RAW ASR] no changes are needed here"),
          d(2, "CORRECTION_DEBUG [LLM Polish] OUT: no changes are needed here"), t(3, terminal)]
    rnc = collect_dictations(nc)
    check("'no changes are needed' RAW ASR is kept, not dropped as status",
          len(rnc) == 1 and rnc[0]["raw_asr"] == "no changes are needed here")
    check("'no changes are needed' as OUT output is kept",
          rnc[0]["steps"].get("LLM Polish") == "no changes are needed here")
    check("bare per-step form captured", r["steps"].get("Filler Removal") == "hi sam this is a test")
    # THE TWO-WAY CONTROL the code-uat rule demands: the block under test is
    # multi-line and the parser returns all of it.
    polish = r["steps"].get("LLM Polish", "")
    check("multi-line OUT block kept whole (4 lines incl. blank)", polish == "Hi Sam,\n\nThis is a test.\nThanks")
    check("final_text is the last step", final_text(r) == polish)
    # An EMPTY final output is emptyOutputRecoveryFloor territory: the app
    # delivers a deterministic floor or the raw ASR, computed AFTER the logged
    # chain and never logged. The log cannot say which, so final_text reports
    # inconclusive (None) rather than guessing an intermediate step the app did
    # not deliver (local Codex review, PR #2780; supersedes the earlier
    # walk-back, which returned a pre-floor step the app skips).
    empty_polish = [d(1, "CORRECTION_DEBUG [RAW ASR] twenty dollars"),
                    d(2, "CORRECTION_DEBUG [Filler Removal] twenty dollars"),
                    d(3, "CORRECTION_DEBUG [LLM Polish] OUT: "), t(4, terminal)]
    rep = collect_dictations(empty_polish)[0]
    check("empty final output -> inconclusive (None), not a pre-floor step",
          final_text(rep) is None)
    only_empty = collect_dictations([d(1, "CORRECTION_DEBUG [RAW ASR] hello"),
                                     d(2, "CORRECTION_DEBUG [LLM Polish] OUT: "), t(3, terminal)])[0]
    check("empty final output with a raw ASR present -> still inconclusive (floor is off-log)",
          final_text(only_empty) is None)
    check("pipeline total captured", r.get("pipeline_total") == "1.234s")
    check("vad captured", (r.get("vad") or {}).get("pct") == "60.0")
    check("terminal fields", (r["result"], r["reason"], r["backend"]) == ("delivered", "nil", "parakeet"))

    # Zero terminal rows -> zero records, even with content present.
    check("no terminal -> no record", collect_dictations(lines[:-1]) == [])
    # A record with no steps falls back to raw ASR.
    only_raw = [d(1, "CORRECTION_DEBUG [RAW ASR] plain words"), t(2, terminal)]
    rr = collect_dictations(only_raw)
    check("no steps -> final_text is raw ASR", len(rr) == 1 and final_text(rr[0]) == "plain words")
    # Two dictations do not bleed into each other.
    two = only_raw + [d(3, "CORRECTION_DEBUG [RAW ASR] second take"), t(4, terminal)]
    r2 = collect_dictations(two)
    check("two terminals -> two records, no bleed",
          len(r2) == 2 and r2[0]["raw_asr"] == "plain words" and r2[1]["raw_asr"] == "second take")
    # A continuation line that happens to start with `[` but is not a stamp stays in the block.
    bracket = [d(1, "CORRECTION_DEBUG [LLM Polish] OUT: Items:"), "[x] one", "[y] two", t(2, terminal)]
    rb = collect_dictations(bracket)
    check("unstamped '[..' continuation stays in block",
          len(rb) == 1 and rb[0]["steps"]["LLM Polish"] == "Items:\n[x] one\n[y] two")
    # Empty input.
    check("empty input -> no record, no raise", collect_dictations([]) == [])

    # Indented / blank-delimited output keeps its shape: stripping the first line
    # while later lines keep their indent would fake inconsistent indentation
    # (local Codex review, PR #2780).
    indented = [d(1, "CORRECTION_DEBUG [LLM Polish] OUT:     first line"),
                "    second line", t(2, terminal)]
    rind = collect_dictations(indented)[0]
    check("indented output keeps leading whitespace on every line",
          rind["steps"]["LLM Polish"] == "    first line\n    second line")

    # A file import runs the polish engine but writes NO terminal row; a new RAW
    # ASR block starts a fresh step set so the import's steps do not leak into
    # the next live take and get read as its delivered text (cloud Codex review,
    # PR #2780).
    import_then_live = [
        d(1, "CORRECTION_DEBUG [RAW ASR] imported file words"),
        d(2, "CORRECTION_DEBUG [LLM Polish] OUT: Imported polished sentence."),
        d(3, "CORRECTION_DEBUG [RAW ASR] the quick brown fox"),
        t(4, terminal),
    ]
    ril = collect_dictations(import_then_live)
    check("import steps do not leak into the next live take",
          len(ril) == 1 and "LLM Polish" not in ril[0]["steps"])
    check("leaked import: final_text is the live raw ASR, not the import polish",
          final_text(ril[0]) == "the quick brown fox")

    # A snippet take logs an EWSNIP placeholder; SnippetFinalizer substitutes the
    # real expansion AFTER the logged chain, so the delivered text is not in the
    # log. final_text returns None -> the take is judged inconclusive, never on
    # the placeholder (cloud Codex review, PR #2780).
    snip = [d(1, "CORRECTION_DEBUG [RAW ASR] insert my address snippet"),
            d(2, "CORRECTION_DEBUG [LLM Polish] OUT: EWSNIPaddr placeholder"), t(3, terminal)]
    rsnip = collect_dictations(snip)[0]
    check("snippet placeholder in delivered text -> final_text None (inconclusive)",
          final_text(rsnip) is None)
    # The whole class: a LATER polish step that DROPPED the sentinel must not let
    # an earlier sentinel through — SnippetFinalizer rejects that polish, so the
    # log's polished text is not what was delivered (local Codex review, PR #2780).
    snip_dropped = [d(1, "CORRECTION_DEBUG [RAW ASR] insert my fox snippet"),
                    d(2, "CORRECTION_DEBUG [Filler Removal] EWSNIPfox placeholder"),
                    d(3, "CORRECTION_DEBUG [LLM Polish] OUT: unrelated dog"), t(4, terminal)]
    rsd = collect_dictations(snip_dropped)[0]
    check("sentinel in an EARLIER step -> final_text None even when polish dropped it",
          final_text(rsd) is None)

    # Counted from the rows that RAN, never a literal: a literal total drifts the
    # first time a row is added and then reports N/N+1 as a pass.
    total = len(ran)
    if failures:
        print(f"\nlog_verdict self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\nlog_verdict self-test: {total}/{total} passed")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    print("log_verdict is a library. Run `--self-test`, or `uat.py verdict` to read the live log.")
    sys.exit(2)
