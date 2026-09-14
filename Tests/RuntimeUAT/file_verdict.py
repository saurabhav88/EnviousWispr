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
STORED = re.compile(r"\[TurnStorage\] outcome=(?P<outcome>stored|stopped) turns=(?P<turns>\d+) fallback=(?P<fallback>\d+) emitted=(?P<emitted>\w+) ms=(?P<ms>\d+)")

TERMINAL = ("stored", "stopped")


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
        return None
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
    # settles first), so look past `end` too, but only at door lines, and only at
    # the caller's request when it names one (an earlier request's `finished` in
    # the same window must not be attached to this run).
    for m, _l in stamped[start:]:
        if m and m.group("cat") == "DebugImportDoor":
            msg = m.group("msg")
            if request is not None and f"request={request}" not in msg:
                continue
            d, h = DOOR.search(msg), DOOR_HISTORY.search(msg)
            if d and d.group("status") in ("finished", "refused", "superseded", "timeout", "unexpected", "cancelled"):
                rec["door"] = {"status": d.group("status"), "history": h.group("history") if h else None}
    t = STORED.search(stamped[end][0].group("msg"))
    rec.update(ts_stored=stamped[end][0].group("ts"), outcome=t.group("outcome"), stored_turns=int(t.group("turns")),
               fallback=int(t.group("fallback")), emitted=t.group("emitted") == "true")
    return rec


def _int(s):
    return int(s) if s is not None else None


def row_facts(row):
    """The History row's own numbers: words from `text` (the raw transcript, what
    `estimateText` is about), sections = `turns`, file seconds, the transcript-ready
    stamp, the file name. Tolerates a row saved before polish finished."""
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

    PASS needs: a terminal `stored` row, `emitted=true`, the History row present,
    and the row's section count equal to the stored count. When the run went
    through the door, the door must have said `finished` naming that row.
    FAIL is a `stopped` terminal, a door refusal, or a row that disagrees with the
    log. INSTRUMENT is no terminal row, no History row, or a `superseded` door
    (which claims nothing about the row)."""
    if rec is None:
        return 2, "no `[TurnStorage] outcome=` row since the mark; the run has not finished or the log is not being written"
    if rec["outcome"] == "stopped":
        return 1, f"stopped mid-cleanup at {rec['stored_turns']} turns (fallback={rec['fallback']})"
    if expect_door:
        door = rec["door"]
        if door is None:
            return 2, "no terminal door reply in the window; was the file handed through the door?"
        if door["status"] == "superseded":
            return 2, "door reply `superseded` (a Stop or a new file on screen); the row is unattributable"
        if door["status"] != "finished":
            return 1, f"door reply `{door['status']}`; no row was produced"
    if expect_door and not rec["door"]["history"]:
        return 2, "door said finished but named no History row; the reply is malformed"
    if row is None:
        return 2, "the History row named by the log is not on disk; `saved` was a claim, not a read"
    facts = row_facts(row)
    if expect_door and rec["door"]["history"] and rec["door"]["history"].upper() != (facts["id"] or "").upper():
        return 1, f"door named row {rec['door']['history']} but the row read is {facts['id']}"
    if facts["sections"] != rec["stored_turns"]:
        return 1, f"row has {facts['sections']} turns, log stored {rec['stored_turns']}"
    if not rec["emitted"]:
        return 1, "stored row was not emitted to the screen (emitted=false)"
    return 0, None


def file_verdict(lines, row, expect_door=True, request=None):
    """The whole thing: collect, classify, and the numbers a receipt carries.
    Returns (exit_code, evidence dict)."""
    rec = collect_import(lines, request=request)
    code, note = classify_import(rec, row, expect_door)
    ev = {"exit_code": code, "note": note, "outcome": rec["outcome"] if rec else None,
          "stored_turns": rec["stored_turns"] if rec else None,
          "fallback": rec["fallback"] if rec else None,
          "both": (rec["assembled"] or {}).get("both") if rec else None,
          "speaker_ms": (rec["speaker"] or {}).get("ms") if rec else None,
          "speaker_outcome": (rec["speaker"] or {}).get("outcome") if rec else None,
          "pieces": (rec["polished"] + rec["skipped"]) if rec else None,
          "polished": rec["polished"] if rec else None,
          "skipped": rec["skipped"] if rec else None,
          "polish_secs": round(rec["polish_secs"], 1) if rec else None,
          "door": rec["door"] if rec else None}
    if row is not None:
        f = row_facts(row)
        ev.update(history=f["id"], file_name=f["file_name"], words=f["words"], polished_words=f["polished_words"],
                  sections=f["sections"], file_seconds=round(f["file_seconds"], 1), speakers=f["speakers"],
                  transcript_ready=f["created"].replace(microsecond=0).isoformat())
        if rec:
            stored_at = dt.datetime.fromisoformat(rec["ts_stored"])
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
        out.append(f"   door: {ev['door']['status']} history={ev['door']['history']}")
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
    check("door terminal attached with the row id", rec["door"] == {"status": "finished", "history": row_id})
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
