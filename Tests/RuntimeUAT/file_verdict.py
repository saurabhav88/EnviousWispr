#!/usr/bin/env python3
"""Transcribe a File verdicts from `app.log` lines plus the History row (#2775 slice 2).

THE ONE READER. Three sessions on 2026-09-13 each typed this marker list into a
scratchpad driver and each read the row by hand. This module is handed lines
(`wispr_eyes.log_entries_since`) and a row dict; it never opens the log.

What a run writes, in order (producers, so the shapes are checked against source):
  `[DebugImportDoor] ... request=<uuid> status=<s> ...`  DebugImportDoor.swift (dev builds; fields
                                                          sorted alphabetically, so match `status=`)
  `[FileImportCoordinator] [SpeakerLabeler] outcome=<o> speakers=N ms=N [retry=true]`
  `[FileImportCoordinator] [TurnStorage] assembled turns=N both=N ms=N`   (05:33 builds wrote `raw turns=N`)
  `[PipelineTiming] LLM polish complete: N chars in N.NNNs (...)`         one per section, or
  `[LLM] LLM polish skipped: transcript too short (N words, minimum 4)`    one per skipped section
  `[FileImportCoordinator] [TurnAlign] turns=N aligned=N ... final=true`   only on builds that align
  `[FileImportCoordinator] [TurnStorage] outcome=<stored|stopped> turns=N fallback=N emitted=<b> ms=N`
Transcript-ready has NO log line; the History row's `createdAt` (Cocoa epoch) is that stamp.

    python3 Tests/RuntimeUAT/file_verdict.py --self-test
"""

import datetime as dt
import json
import math
import os
import re
import sys

from log_verdict import LINE  # `[<ISO-8601>] [<LEVEL>] [<category>] <message>`

COCOA_EPOCH = 978307200  # 2001-01-01T00:00:00Z; History rows store Foundation dates

DOOR = re.compile(r"status=(?P<status>\w+)")
DOOR_HISTORY = re.compile(r"history=(?P<history>[0-9A-Fa-f-]{36})")
SPEAKER = re.compile(r"\[SpeakerLabeler\] outcome=(?P<outcome>\w+)(?: speakers=(?P<speakers>\d+))? ms=(?P<ms>\d+)(?P<retry> retry=true)?")
ASSEMBLED = re.compile(r"\[TurnStorage\] (?:assembled|raw) turns=(?P<turns>\d+)(?: both=(?P<both>\d+))? ms=(?P<ms>\d+)")
POLISHED = re.compile(r"LLM polish complete: (?P<chars>\d+) chars in (?P<secs>[0-9.]+)s")
SKIPPED = re.compile(r"LLM polish skipped: transcript too short")
ALIGN_FINAL = re.compile(r"\[TurnAlign\] turns=(?P<turns>\d+) aligned=(?P<aligned>\d+).* final=true")
STORED = re.compile(r"\[TurnStorage\] outcome=(?P<outcome>[a-z_]+) turns=(?P<turns>\d+) fallback=(?P<fallback>\d+) emitted=(?P<emitted>\w+) ms=(?P<ms>\d+)")
DOOR_REASON = re.compile(r"reason=(?P<reason>[A-Za-z]+)")

# The coordinator's terminal outcomes, the CLOSED set `TelemetryService.FileImportTurnsOutcome`
# (raw values), each with the verdict it earns. The self-test reads that enum from the Swift
# source when the checkout is present and fails if a case is missing here, so a new outcome
# cannot fall into a default.
#   0 PASS: the product did what it promises for the file.
#   1 FAIL: the product did not.
#   2 INSTRUMENT: the run was interrupted or its environment was not ready; no claim either way.
TERMINAL_OUTCOMES = {
    "stored": (0, None),
    "single_no_turns": (0, "one voice: a plain transcript, no turns, as designed"),
    "stopped": (1, "stopped mid-cleanup"),
    "save_failed": (1, "the History save failed"),
    "no_word_timings": (1, "no usable word timings, so no speaker labels (expected only for a script written without spaces)"),
    "row_deleted": (2, "the History row was deleted while the run was in flight"),
    "polisher_not_ready": (2, "the polisher could not start; turns kept their raw words"),
}
# The door's terminal `refused` reasons (`FileImportRejection` names in DebugImportDoor.swift),
# a run the door accepted and the app then rejected before any turn storage.
REFUSED_REASONS = {
    "cannotRead": 1, "noAudio": 1, "noSpeechFound": 1, "failed": 1,  # `failed:<message>` reads as `failed`
    "engineBusy": 2, "engineNotInstalled": 2, "engineNotReady": 2, "polisherNotReady": 2,
}


CATEGORIES = {"FileImportCoordinator", "DebugImportDoor", "PipelineTiming", "LLM"}


def collect_import(lines, request=None):
    """One record for the LAST Transcribe a File run in `lines`, or None.

    Anchored on the terminal `[TurnStorage] outcome=` row, the one line every
    ending writes (a run with no terminal row has not finished and is not a
    result). Everything from the last `[SpeakerLabeler]` row before it belongs to
    the run. The door reply attached is the terminal reply of `request` when the
    caller knows its request id (uat.py does), else the last terminal door reply
    after the run's start. Only the four CATEGORIES are read, so a fixture cut to
    them and the live log reach the same verdict (local review r1, finding e).

    Record: {ts_stored, outcome, stored_turns, fallback, emitted, speaker: {outcome,
    speakers, ms, retry}, assembled: {turns, both, ms}, polished, skipped,
    polish_secs, align_final: {turns, aligned} | None, door: {status, history} | None}
    """
    stamped = [(m, l) for m, l in ((LINE.match(l), l) for l in lines)
               if m and m.group("cat") in CATEGORIES]
    idx = [i for i, (m, _l) in enumerate(stamped) if m and STORED.search(m.group("msg"))]
    if not idx:
        # No terminal row: the run may still have ENDED at the door (a refusal after accept,
        # a timeout), which is graded on the reply alone.
        door = _door_terminal(stamped, 0, request)
        return {"outcome": None, "door": door} if door else None
    end = idx[-1]
    starts = [i for i, (m, _l) in enumerate(stamped[:end]) if m and SPEAKER.search(m.group("msg"))]
    start = starts[-1] if starts else 0
    rec = {"speaker": None, "assembled": None, "polished": 0, "skipped": 0, "polish_secs": 0.0,
           "align_final": None, "door": None}
    for m, _l in stamped[start:end + 1]:
        if not m:
            continue
        msg = m.group("msg")
        if (s := SPEAKER.search(msg)) and rec["speaker"] is None:
            rec["speaker"] = {"outcome": s.group("outcome"), "speakers": _int(s.group("speakers")),
                              "ms": int(s.group("ms")), "retry": bool(s.group("retry"))}
        elif a := ASSEMBLED.search(msg):
            rec["assembled"] = {"turns": int(a.group("turns")), "both": _int(a.group("both")), "ms": int(a.group("ms"))}
        elif p := POLISHED.search(msg):
            rec["polished"] += 1
            rec["polish_secs"] += float(p.group("secs"))
        elif SKIPPED.search(msg):
            rec["skipped"] += 1
        elif f := ALIGN_FINAL.search(msg):
            rec["align_final"] = {"turns": int(f.group("turns")), "aligned": int(f.group("aligned"))}
    # The door's terminal reply lands a beat AFTER the stored row (the coordinator
    # settles first), so look past `end` too.
    rec["door"] = _door_terminal(stamped, start, request)
    t = STORED.search(stamped[end][0].group("msg"))
    rec.update(ts_stored=stamped[end][0].group("ts"), outcome=t.group("outcome"), stored_turns=int(t.group("turns")),
               fallback=int(t.group("fallback")), emitted=t.group("emitted") == "true")
    return rec


def _door_terminal(stamped, start, request):
    """The last terminal door reply at or after `start`, only for the caller's request when
    it names one (an earlier request's `finished` in the same window must not be attached
    to this run), or None."""
    found = None
    for m, _l in stamped[start:]:
        if m and m.group("cat") == "DebugImportDoor":
            msg = m.group("msg")
            if request is not None and f"request={request}" not in msg:
                continue
            d, h, r = DOOR.search(msg), DOOR_HISTORY.search(msg), DOOR_REASON.search(msg)
            if d and d.group("status") in ("finished", "refused", "superseded", "timeout", "unexpected", "cancelled"):
                found = {"status": d.group("status"), "history": h.group("history") if h else None,
                         "reason": r.group("reason") if r else None}
    return found


def _int(s):
    return int(s) if s is not None else None


def row_is_malformed(row):
    """Why a loaded History row cannot be read, or None. A syntactically valid but
    incomplete row (no `createdAt`, a null stamp, a non-numeric duration, turns that
    are not a list) is an INSTRUMENT condition, never a product verdict."""
    if not isinstance(row, dict):
        return "row is not an object"
    if not isinstance(row.get("createdAt"), (int, float)) or isinstance(row.get("createdAt"), bool):
        return "row has no numeric createdAt"
    if row.get("duration") is not None and not isinstance(row.get("duration"), (int, float)):
        return "row duration is not numeric"
    if row.get("turns") is not None and not isinstance(row.get("turns"), list):
        return "row turns is not a list"
    if not isinstance(row.get("id"), str) or not row["id"]:
        return "row has no id"
    for key, kind in (("text", str), ("polishedText", str), ("speakerNames", dict), ("importedFileName", str)):
        if row.get(key) is not None and not isinstance(row[key], kind):
            return f"row {key} is not a {kind.__name__}"
    try:
        dt.datetime.fromtimestamp(row["createdAt"] + COCOA_EPOCH).astimezone()
        if row.get("duration") is not None and (isinstance(row["duration"], bool) or not math.isfinite(float(row["duration"]))):
            return "row duration is not a finite number"
    except (OverflowError, ValueError, OSError):
        return "row createdAt is out of range"
    return None


def row_facts(row):
    """The History row's own numbers: words from `text` (the raw transcript, what
    `estimateText` is about), sections = `turns`, file seconds, the transcript-ready
    stamp, the file name. Tolerates a row saved before polish finished; call
    `row_is_malformed` first."""
    created = dt.datetime.fromtimestamp(row["createdAt"] + COCOA_EPOCH).astimezone()
    return {"words": len((row.get("text") or "").split()),
            "polished_words": len((row.get("polishedText") or "").split()),
            "sections": len(row.get("turns") or []),
            "file_seconds": float(row.get("duration") or 0.0),
            "created": created,
            "file_name": row.get("importedFileName"),
            "speakers": len(row.get("speakerNames") or {}),
            "id": row.get("id")}


def classify_import(rec, row, expect_door=True):
    """PURE. Returns (exit_code, note): 0 pass, 1 fail, 2 instrument.

    PASS needs: a terminal `stored` (or `single_no_turns`) row, the History row present,
    and the row's section count equal to the stored count. When the run went
    through the door, the door must have said `finished` naming that row.
    FAIL is a `stopped` terminal, a door refusal, or a row that disagrees with the
    log. INSTRUMENT is no terminal row, no History row, or a `superseded` door
    (which claims nothing about the row)."""
    if rec is None:
        return 2, "no `[TurnStorage] outcome=` row and no terminal door reply since the mark; the run has not finished or the log is not being written"
    if rec["outcome"] is None:
        # Ended at the door with no turn storage: a refusal after accept, or an interruption.
        door = rec["door"]
        if door["status"] == "refused":
            code = REFUSED_REASONS.get(door["reason"] or "", 2)  # an unknown reason claims nothing
            return code, f"the app refused the file after accepting it: {door['reason'] or 'no reason given'}"
        return 2, f"door reply `{door['status']}` with no turn storage; the run did not complete"
    if rec["outcome"] not in TERMINAL_OUTCOMES:
        return 2, f"unknown terminal outcome `{rec['outcome']}`; add it to TERMINAL_OUTCOMES from FileImportTurnsOutcome"
    code, note = TERMINAL_OUTCOMES[rec["outcome"]]
    if code == 1:
        return 1, f"{note} (turns={rec['stored_turns']}, fallback={rec['fallback']})"
    if code == 2:
        return 2, note
    if expect_door:
        door = rec["door"]
        if door is None:
            return 2, "no terminal door reply in the window; was the file handed through the door?"
        if door["status"] == "superseded":
            return 2, "door reply `superseded` (a Stop or a new file on screen); the row is unattributable"
        if door["status"] != "finished":
            return 1, f"door reply `{door['status']}`; no row was produced"
        if not door["history"]:
            return 2, "door said finished but named no History row; the reply is malformed"
    if row is None:
        return 2, "the History row named by the log is not on disk; `saved` was a claim, not a read"
    if (why := row_is_malformed(row)):
        return 2, f"the History row is malformed: {why}"
    facts = row_facts(row)
    if expect_door and rec["door"]["history"] and rec["door"]["history"].upper() != (facts["id"] or "").upper():
        return 1, f"door named row {rec['door']['history']} but the row read is {facts['id']}"
    if facts["sections"] != rec["stored_turns"]:
        return 1, f"row has {facts['sections']} turns, log stored {rec['stored_turns']}"
    # `emitted` is the coordinator's telemetry flag (false on a Clean it again over the same
    # row, `FileImportCoordinator.swift:2339`), reported and never graded.
    return 0, note


def file_verdict(lines, row, expect_door=True, request=None):
    """The whole thing: collect, classify, and the numbers a receipt carries.
    Returns (exit_code, evidence dict)."""
    rec = collect_import(lines, request=request)
    code, note = classify_import(rec, row, expect_door)
    full = rec if rec and rec.get("outcome") is not None else None
    ev = {"exit_code": code, "note": note, "outcome": full["outcome"] if full else None,
          "stored_turns": full["stored_turns"] if full else None,
          "fallback": full["fallback"] if full else None,
          "both": (full["assembled"] or {}).get("both") if full else None,
          "speaker_ms": (full["speaker"] or {}).get("ms") if full else None,
          "speaker_outcome": (full["speaker"] or {}).get("outcome") if full else None,
          "pieces": (full["polished"] + full["skipped"]) if full else None,
          "polished": full["polished"] if full else None,
          "skipped": full["skipped"] if full else None,
          "polish_secs": round(full["polish_secs"], 1) if full else None,
          "door": rec["door"] if rec else None}
    if row is not None and not row_is_malformed(row):
        f = row_facts(row)
        ev.update(history=f["id"], file_name=f["file_name"], words=f["words"], polished_words=f["polished_words"],
                  sections=f["sections"], file_seconds=round(f["file_seconds"], 1), speakers=f["speakers"],
                  transcript_ready=f["created"].replace(microsecond=0).isoformat())
        if full:
            stored_at = dt.datetime.fromisoformat(full["ts_stored"])
            ev["clean_wall_s"] = round((stored_at - f["created"]).total_seconds())
    return code, ev


def format_verdict(ev):
    tag = {0: "PASS", 1: "FAIL", 2: "INSTRUMENT"}[ev["exit_code"]]
    out = [f"== TRANSCRIBE A FILE: {tag} =="]
    if ev.get("note"):
        out.append(f"   {ev['note']}")
    if ev.get("history"):
        out.append(f"   row {ev['history']}  {ev['file_name']}  {ev['file_seconds']} s of audio")
        out.append(f"   words {ev['words']} (polished {ev['polished_words']})  sections {ev['sections']}  speakers {ev['speakers']}")
    if ev.get("outcome"):
        out.append(f"   log: outcome={ev['outcome']} turns={ev['stored_turns']} fallback={ev['fallback']} both={ev['both']}")
        out.append(f"   speakers: {ev['speaker_outcome']} in {ev['speaker_ms']} ms;  pieces {ev['pieces']} "
                   f"({ev['polished']} polished + {ev['skipped']} skipped), model time {ev['polish_secs']} s")
    if ev.get("clean_wall_s") is not None:
        out.append(f"   transcript ready {ev['transcript_ready']}  ->  stored {ev['clean_wall_s']} s later")
    if ev.get("door"):
        out.append(f"   door: {ev['door']['status']} history={ev['door']['history']}"
                   + (f" reason={ev['door']['reason']}" if ev['door'].get('reason') else ""))
    return "\n".join(out)


# ---------------------------------------------------------------- self-test --

def _self_test():
    failures, ran = [], []

    def check(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        ran.append(name)
        if not cond:
            failures.append(name)

    P = "[2026-09-13T18:51:{s:02d}-04:00] [INFO] [PipelineTiming] "
    C = "[2026-09-13T18:51:{s:02d}-04:00] [INFO] [FileImportCoordinator] "
    D = "[2026-09-13T18:51:{s:02d}-04:00] [INFO] [DebugImportDoor] "
    M = "[2026-09-13T18:51:{s:02d}-04:00] [INFO] [LLM] "
    row_id = "88F0B7E7-75B6-420B-805D-D546CC75B71A"
    lines = [
        D.format(s=22) + "executable=/x/EnviousWispr launch=L pid=1 request=r1 status=accepted",
        C.format(s=25) + "[SpeakerLabeler] outcome=labeled speakers=2 ms=1072",
        C.format(s=25) + "[TurnStorage] assembled turns=17 both=1 ms=2",
    ] + [P.format(s=27) + "LLM polish complete: 100 chars in 0.400s (provider=egOne, model=eg-1)"] * 16 + [
        M.format(s=30) + "LLM polish skipped: transcript too short (3 words, minimum 4)",
        C.format(s=35) + "[TurnStorage] outcome=stored turns=17 fallback=0 emitted=true ms=11",
        D.format(s=35) + f"executable=/x/EnviousWispr history={row_id} launch=L pid=1 polisher=eg-1 request=r1 status=finished",
    ]
    # createdAt = 2026-09-13T18:51:23.92-04:00 in Cocoa seconds (the real row's value).
    row = {"id": row_id, "createdAt": 811032683.920841, "duration": 239.999625,
           "importedFileName": "clip-ariana-4min.m4a", "text": " ".join(["w"] * 743),
           "polishedText": " ".join(["w"] * 647), "turns": [{}] * 17, "speakerNames": {"a": 1, "b": 2}}

    rec = collect_import(lines)
    check("terminal row anchors one record", rec is not None and rec["outcome"] == "stored")
    check("speaker ms read", rec["speaker"]["ms"] == 1072)
    check("both count read from the assembled row", rec["assembled"]["both"] == 1)
    check("pieces = polished + skipped = sections", rec["polished"] + rec["skipped"] == 17)
    check("door terminal attached with the row id", rec["door"] == {"status": "finished", "history": row_id, "reason": None})
    code, ev = file_verdict(lines, row)
    check("the short run passes", code == 0)
    check("wall time from createdAt to the stored stamp", ev["clean_wall_s"] == 11)
    check("words from the row text", ev["words"] == 743 and ev["sections"] == 17)

    # Stop mid-cleanup: FAIL.
    stopped = lines[:-2] + [C.format(s=33) + "[TurnStorage] outcome=stopped turns=17 fallback=17 emitted=true ms=8"]
    check("stopped is FAIL", file_verdict(stopped, row, expect_door=False)[0] == 1)
    # Superseded door: INSTRUMENT, never a claim about the row.
    sup = lines[:-1] + [D.format(s=35) + "executable=/x/EnviousWispr launch=L pid=1 request=r1 status=superseded"]
    check("superseded door is INSTRUMENT", file_verdict(sup, row)[0] == 2)
    # No terminal row: INSTRUMENT.
    check("no terminal row is INSTRUMENT", file_verdict(lines[:-2], row)[0] == 2)
    # Row disagrees with the log: FAIL.
    short_row = dict(row, turns=[{}] * 16)
    check("row/log turn mismatch is FAIL", file_verdict(lines, short_row)[0] == 1)
    # Missing row: INSTRUMENT.
    check("missing row is INSTRUMENT", file_verdict(lines, None)[0] == 2)
    # An EARLIER request's `finished` in the same window must not be attached to this run.
    earlier = [D.format(s=20) + f"executable=/x/EnviousWispr history={row_id} launch=L pid=1 polisher=eg-1 request=r0 status=finished"] + lines
    check("another request's terminal reply is ignored when the caller names its request",
          collect_import(earlier, request="r1")["door"]["history"] == row_id
          and collect_import(lines[:-1] + [D.format(s=36) + "executable=/x/EnviousWispr launch=L pid=1 request=r9 status=superseded"], request="r1")["door"] is None)
    check("a finished reply that names no row is INSTRUMENT",
          file_verdict(lines[:-1] + [D.format(s=35) + "executable=/x/EnviousWispr launch=L pid=1 request=r1 status=finished"], row)[0] == 2)
    check("lines outside the four categories are ignored, so a cut fixture and the live log agree",
          collect_import(lines + ["[2026-09-13T18:51:36-04:00] [INFO] [CorrectionDebug] [TurnStorage] outcome=stopped turns=1 fallback=1 emitted=true ms=1"])["outcome"] == "stored")
    # The outcome table is the CLOSED set the coordinator can write: read the enum's raw
    # values from the Swift source when this checkout has it (CI does), and require every
    # case in TERMINAL_OUTCOMES and nothing else.
    swift = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                         "Sources", "EnviousWisprServices", "TelemetryService.swift")
    if os.path.isfile(swift):
        src = open(swift, encoding="utf-8").read()
        body = src[src.index("enum FileImportTurnsOutcome"):]
        body = body[:body.index("\n  }\n")]
        cases = set(re.findall(r'case\s+(\w+)\s*=\s*"([a-z_]+)"', body))
        raw = {v for _k, v in cases} | {k for k in re.findall(r"case\s+(\w+)\s*$", body, re.M)}
        # bare cases (no raw value) use their name
        raw |= {k for k in re.findall(r"case\s+(\w+)\s*\n", body) if "=" not in k}
        check(f"TERMINAL_OUTCOMES matches FileImportTurnsOutcome {sorted(raw ^ set(TERMINAL_OUTCOMES))}",
              raw == set(TERMINAL_OUTCOMES))
    else:
        check("TERMINAL_OUTCOMES checked against the Swift enum (checkout absent, skipped)", True)
    unknown = [lines[1], C.format(s=30) + "[TurnStorage] outcome=teleported turns=0 fallback=0 emitted=true ms=3"]
    check("an outcome the table does not know is INSTRUMENT, never a pass or a fail",
          file_verdict(unknown, row, expect_door=False)[0] == 2)
    single_row = dict(row, turns=[])
    for outcome, code in (("single_no_turns", 0), ("save_failed", 1), ("no_word_timings", 1),
                          ("row_deleted", 2), ("polisher_not_ready", 2)):
        term = [lines[1], C.format(s=30) + f"[TurnStorage] outcome={outcome} turns=0 fallback=0 emitted=true ms=3"]
        got = file_verdict(term, single_row, expect_door=False)[0]
        check(f"outcome {outcome} exits {code}", got == code)
    single = [lines[0], lines[1], C.format(s=30) + "[TurnStorage] outcome=single_no_turns turns=0 fallback=0 emitted=true ms=3",
              D.format(s=31) + f"executable=/x/EnviousWispr history={row_id} launch=L pid=1 polisher=eg-1 request=r1 status=finished"]
    check("a one-voice file passes through the door with a no-turn row", file_verdict(single, single_row)[0] == 0)
    # The door accepted and the app then refused before any turn storage.
    for reason, code in (("noAudio", 1), ("cannotRead", 1), ("noSpeechFound", 1), ("engineBusy", 2), ("polisherNotReady", 2)):
        refused = [lines[0], D.format(s=23) + f"executable=/x/EnviousWispr launch=L pid=1 reason={reason} request=r1 saved=false status=refused"]
        got, ev = file_verdict(refused, None, request="r1")
        check(f"door refused {reason} exits {code} with the reason", got == code and reason in (ev["note"] or ""))
    check("a timeout at the door with no turn storage is INSTRUMENT",
          file_verdict([lines[0], D.format(s=23) + "executable=/x/EnviousWispr launch=L pid=1 request=r1 status=timeout"], None)[0] == 2)
    check("door refused with an unknown reason is INSTRUMENT",
          file_verdict([lines[0], D.format(s=23) + "executable=/x/EnviousWispr launch=L pid=1 reason=somethingNew request=r1 status=refused"], None)[0] == 2)
    check("door refused failed:<message> is FAIL",
          file_verdict([lines[0], D.format(s=23) + "executable=/x/EnviousWispr launch=L pid=1 reason=failed:decoder request=r1 status=refused"], None)[0] == 1)
    # A Clean it again over the same row writes emitted=false: still a PASS.
    again = lines[:-2] + [C.format(s=35) + "[TurnStorage] outcome=stored turns=17 fallback=0 emitted=false ms=11", lines[-1]]
    check("emitted=false (a re-clean of the same row) is not a failure", file_verdict(again, row)[0] == 0)
    # Malformed rows are the instrument, never a product verdict.
    for bad in (dict(row, createdAt=None), {k: v for k, v in row.items() if k != "createdAt"},
                dict(row, duration="long"), dict(row, turns="17"), dict(row, id=""),
                dict(row, text=743), dict(row, speakerNames=["a"]), dict(row, duration=float("inf")),
                dict(row, createdAt=1e300)):
        check(f"malformed row is INSTRUMENT ({row_is_malformed(bad)})", file_verdict(lines, bad)[0] == 2)
    # A hand-driven run (no door) passes on the coordinator rows alone.
    check("no-door run passes with expect_door=False", file_verdict(lines[1:-1], row, expect_door=False)[0] == 0)
    # 05:33-build shape (`raw turns=`) still parses.
    raw = [lines[1], C.format(s=25) + "[TurnStorage] raw turns=31 ms=13"] + lines[3:-1]
    check("`raw turns=` assembled shape parses", collect_import(raw)["assembled"]["turns"] == 31)

    # Five real runs from 2026-09-13, cut from app.log to the four categories the reader
    # matches (FileImportCoordinator, DebugImportDoor, PipelineTiming, LLM) and the History
    # row stripped to the fields it reads, with the transcript replaced by a same-count
    # placeholder. Two properties the inline rows cannot pin: polished + skipped equals the
    # stored count on every real run, and `[TurnAlign]` rows are absent on this build.
    FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "file_verdict")
    EXPECT = {  # name: (door, speaker_ms, both, pieces, stored_turns, words, sections, wall_s, exit)
        "elon":      (True,  42810, 8, 338, 338, 19363, 338, 441, 0),
        "interview": (True,   7482, 8, 209, 209,  9101, 209, 163, 0),
        "ariana":    (False,  7781, 7, 200, 200,  9137, 200, 153, 0),
        "short":     (True,   1072, 1,  17,  17,   743,  17,  11, 0),
    }
    check("the fixtures are beside the reader", os.path.isdir(FIXTURES))
    if os.path.isdir(FIXTURES):
        for name, (door, ms, both, pieces, turns, words, sections, wall, code) in EXPECT.items():
            with open(os.path.join(FIXTURES, name + ".log"), encoding="utf-8", errors="replace") as fh:
                flines = fh.read().splitlines()
            with open(os.path.join(FIXTURES, name + ".row.json"), encoding="utf-8") as fh:
                frow = json.load(fh)
            got, ev = file_verdict(flines, frow, expect_door=door)
            check(f"fixture {name}: exit {code}", got == code)
            check(f"fixture {name}: numbers", (ev["speaker_ms"], ev["both"], ev["pieces"], ev["stored_turns"],
                                                ev["words"], ev["sections"]) == (ms, both, pieces, turns, words, sections)
                  and abs(ev["clean_wall_s"] - wall) <= 1)
            check(f"fixture {name}: no align rows on this build", collect_import(flines)["align_final"] is None)
        # Stop mid-cleanup through the door (17:19:46): the coordinator wrote `stopped`, the
        # door answered `superseded`; the run is a FAIL on the coordinator row alone.
        with open(os.path.join(FIXTURES, "stopped.log"), encoding="utf-8", errors="replace") as fh:
            slines = fh.read().splitlines()
        code, ev = file_verdict(slines, None, expect_door=False)
        check("fixture stopped: exit 1 with fallback on every turn", code == 1 and ev["fallback"] == 17)
        check("fixture stopped: the door said superseded", collect_import(slines)["door"]["status"] == "superseded")

    print(f"\n{len(ran) - len(failures)}/{len(ran)} checks passed")
    return 0 if not failures else 1


def main(argv):
    if "--self-test" in argv:
        return _self_test()
    print("usage: file_verdict.py --self-test   (uat.py run transcribe-file drives it live)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
