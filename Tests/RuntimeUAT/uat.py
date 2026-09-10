#!/usr/bin/env python3
"""The front door for Live UAT (#2775). Four verbs, in the order a session uses them:

    python3 Tests/RuntimeUAT/uat.py recipes            # what exists, what to trust, where it is written up
    python3 Tests/RuntimeUAT/uat.py preflight          # is THIS machine ready for UAT right now (nudge, never blocks)
    python3 Tests/RuntimeUAT/uat.py run <recipe> ...   # run a canonical recipe, read the verdict from the log
    python3 Tests/RuntimeUAT/uat.py verdict [--mark]   # read dictation verdicts from the log, whole, rotation-proof

Why a front door: sessions reached Live UAT with no entry point, rebuilt what
`wispr_eyes.py` already does, and repeated traps that were written down.
`preflight` prints the recipe index INTO the session as it runs, so the reading
is delivered rather than looked up, and checks the machine (right build running,
debug log on, speaker not muted, room quiet). It is a NUDGE, never a gate
(founder 2026-09-10): it reports what is ready and never blocks anything.

This module imports `wispr_eyes` (PyObjC) and runs on the dev machine only.
Its pure halves (`uat_catalog`, `preflight`, `log_verdict`) carry the
self-tests and run on CI.
"""

import argparse
import datetime as dt
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import uat_catalog as cat  # noqa: E402
import preflight as pf  # noqa: E402
import log_verdict as lv  # noqa: E402
from instance_guard import running_enviouswispr_instances  # noqa: E402

MARK = "/tmp/.ew-uat-mark"
DEV_BUNDLE_SUFFIX = "/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"


def _git(*args, cwd=HERE):
    return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=15).stdout.strip()


def this_worktree():
    return _git("rev-parse", "--show-toplevel")


def now_iso():
    return dt.datetime.now().astimezone().replace(microsecond=0).isoformat()


def _silent_wav(seconds=6.0, path="/tmp/ew_uat_silence.wav", rate=16000):
    """A file of TRUE silence to feed the occupied-room probe. `test_recording`
    with `audio=None` would call `tts(" ")`, which generates a real (near-silent)
    clip AND shortens the hold to that clip's duration (Codex diff review) — so
    the probe would neither be silent nor last the intended time. Playing this
    exact-length silent wav records genuine silence for `seconds` (stdlib `wave`,
    16-bit mono PCM zeros)."""
    import wave
    n = int(seconds * rate)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * n)
    return path


# ---------------------------------------------------------------------------
# THE VERDICT CONTRACT (enumerated once, Codex diff review r2-r6).
#
# Every recipe verdict is PASS(0) / FAIL(1) / INSTRUMENT(2). Reaching PASS or
# FAIL (rather than INSTRUMENT) requires evidence that is:
#   1. ATTRIBUTABLE  — exactly ONE dictation record since the mark (else INSTRUMENT);
#   2. a VALID TERMINAL for the recipe — the take's `result` is in the recipe's
#      accepted set (KernelLifecycleTelemetrySink.terminalStateLabel emits eight:
#      completed, failed, audio_interrupted, asr_interrupted, discarded, no_speech,
#      asr_empty_despite_audio, cancelled);
#   3. PRESENT where the recipe reads text — a `completed` take whose transcript
#      row was lost to a competing log writer (code-tooling.md RULE:
#      uat-verdicts-from-app-log) proves nothing and is INSTRUMENT, never a pass.
#
# Per recipe:
#   heart-path / quality : accept {completed}; PASS iff delivered text (final_text,
#     which honours the empty-output recovery floor) is non-empty AND contains the
#     expected token. An --audio file with no --expect has no valid expectation and
#     is refused before running.
#   silent-probe         : accept {completed, no_speech}. no_speech -> quiet.
#     completed with a PRESENT transcript -> quiet(<2 words)/occupied(>=2).
#     completed with a MISSING transcript -> INSTRUMENT.
# ---------------------------------------------------------------------------

_SILENT_PROBE_TERMINALS = ("completed", "no_speech")


def classify_transcription(recs, expected_token):
    """The heart-path / quality verdict, PURE over the collected records so it is
    CI-testable (Codex diff review r2-r6 all landed on this logic). Returns
    (exit_code, observed_text, take, note): 0 pass, 1 fail, 2 instrument."""
    if len(recs) != 1:
        note = (f"{len(recs)} records since the mark; cannot attribute the verdict to this recipe"
                if len(recs) > 1 else "no dictation record since the mark")
        return 2, None, None, note
    rec = recs[0]
    take = rec.get("take")
    # Terminal result FIRST (Codex diff review r6). A non-`completed` take is a
    # CONFIRMED non-delivery — failed, cancelled, no_speech, interrupted — and
    # FAILS the recipe (exit 1). Only a take that DID complete but whose transcript
    # row is missing is lost evidence (exit 2); checking text first would misreport
    # a real early failure (which legitimately has no transcript) as an instrument
    # problem.
    if rec.get("result") != "completed":
        return 1, lv.final_text(rec), take, f"take ended {rec.get('result')!r} (reason={rec.get('reason')!r}); no delivery"
    observed = lv.final_text(rec)
    if observed is None:
        return 2, None, take, ("the take completed but the delivered text is not recoverable from app.log "
                               "(a lost transcript row, a snippet expansion, or an empty-output recovery); inconclusive")
    token_ok = bool(expected_token and expected_token.lower() in observed.lower())
    return (0 if token_ok else 1), observed, take, None


def classify_silent(recs):
    """The silent-probe verdict, PURE. Returns (state, words): state in
    quiet / occupied / inconclusive."""
    if len(recs) != 1:
        return "inconclusive", None
    rec = recs[0]
    result = rec.get("result")
    if result not in _SILENT_PROBE_TERMINALS:
        return "inconclusive", None
    if result == "no_speech":
        return "quiet", 0
    if rec.get("raw_asr") is None:  # completed but transcript row lost
        return "inconclusive", None
    words = len(rec["raw_asr"].split())
    return ("occupied" if words >= 2 else "quiet"), words


def collect_settled(w, mark, grace=3.0, stable_reads=3, interval=0.2,
                    _read=None, _now=time.time, _sleep=time.sleep):
    """Collect dictation records after the harness reports completion, waiting
    for the record set to be STABLE (its length unchanged across `stable_reads`
    consecutive non-empty reads) or until `grace` elapses.

    The harness returns as soon as it sees `Pipeline timing TOTAL`, but the
    `dictation_terminal` row that ANCHORS a record is written by a separate
    async task in TelemetryService and lands a beat later (cloud Codex review,
    PR #2780). Reading immediately misses it, so a good take reports as lost
    evidence (exit 2). Gating on STABILITY, not on the first non-empty read, is
    load-bearing: when TWO takes finish close together — two instances answering
    one PTT gesture — their terminals are separately scheduled, so stopping at
    the first record would miss the second and attribute a single-take verdict
    where the honest answer is `cannot attribute` (two records -> exit 2). This
    is FACT: ew-watcher-classification (gate on stability, not a count); it also
    restores the two-in-one-second safety `_line_in_window` relies on.

    `_read`/`_now`/`_sleep` are test seams; the defaults drive the live app."""
    read = _read if _read is not None else (lambda: lv.collect_dictations(w.log_entries_since(mark)))
    deadline = _now() + grace
    recs = read()
    stable, last_n = 0, len(recs)
    while _now() < deadline:
        _sleep(interval)  # settle: poll interval around the STABILITY signal below (count unchanged across `stable_reads`), with `grace` as the deadline fallback
        recs = read()
        n = len(recs)
        if n and n == last_n:
            stable += 1
            if stable >= stable_reads:
                break
        else:
            stable, last_n = 0, n
    return recs


def run_silent_probe(w, seconds=6.0):
    """Record `seconds` of true silence and report what the mic heard.

    Returns (state, words, record):
      "quiet"        -> an attributable take with a PRESENT transcript of < 2 words,
                        or a `no_speech` take (a genuinely quiet room)
      "occupied"     -> a completed take whose transcript has >= 2 words
      "inconclusive" -> not attributable, a non-accepted terminal, or a `completed`
                        take whose transcript row was lost; `words` is None
    """
    audio = _silent_wav(seconds)
    mark = dt.datetime.now().astimezone()
    w.test_recording(audio=audio, expect="\x00nomatch")
    recs = collect_settled(w, mark)
    state, words = classify_silent(recs)
    rec = recs[0] if len(recs) == 1 else (recs[-1] if recs else None)
    return state, words, rec


# --------------------------------------------------------------- preflight --

def cmd_recipes(args):
    try:
        entries = cat.doc_index()
    except cat.DocsUnreadable as e:
        print(cat.render([], False))
        print(f"\nDOCS UNREADABLE: {e}", file=sys.stderr)
        return 3
    if args.names:
        print("\n".join(cat.RECIPES))
        return 0
    if args.json:
        print(json.dumps({"recipes": cat.RECIPES, "status": cat.HARNESS_STATUS,
                          "docs": [{"file": f, "line": n, "heading": h} for f, n, h in entries]}, indent=2))
        return 0
    print(cat.render(entries))
    return 0


def cmd_preflight(args):
    warnings, fails = [], []
    worktree = this_worktree()

    # 1. The written recipes, into the transcript, before anything else.
    try:
        entries = cat.doc_index()
        print(cat.render(entries))
    except cat.DocsUnreadable as e:
        print(cat.render([], False))
        fails.append(f"docs: cannot read the written recipes at {e}; the index above is incomplete")

    print("\n== PREFLIGHT ==")

    # 2. Exactly one instance, and it is THIS worktree's build.
    pid, app_path = None, None
    instances = running_enviouswispr_instances()
    if len(instances) == 0:
        fails.append("app: no EnviousWispr instance is running; launch this worktree's debug build (/wispr-rebuild-debug)")
    elif len(instances) > 1:
        listing = "; ".join(f"pid {p} {x}" for p, x in instances.items())
        fails.append(f"app: {len(instances)} instances running ({listing}); every verdict would be unattributable. "
                     "Refuse rather than pick (tools-and-apps.md RULE: peer-occupancy-procedure)")
    else:
        (pid, app_path), = instances.items()
        expected = worktree + DEV_BUNDLE_SUFFIX
        if app_path != expected:
            fails.append(f"app: the running instance is {app_path}, not this worktree's build ({expected}). "
                         "A verdict from it is about someone else's code. Build and launch here, or run UAT from "
                         "the worktree that owns that build")
        else:
            print(f"OK    app               pid {pid}, this worktree's build")

    # 3. Debug build with Debug Mode on: a launch banner at or after the process start.
    app_start = None
    if pid is not None:
        app_start = pf.proc_start_epoch(int(pid))
        if app_start is None:
            fails.append(f"app: could not read the start time of pid {pid}")
        else:
            # The running IMAGE must not predate the on-disk build (stale-process
            # trap, faultInjection proc_start_epoch note): the binary's mtime is
            # when this worktree last built; it must be OLDER than the launch.
            try:
                bin_mtime = os.path.getmtime(app_path)
                if bin_mtime > app_start + 1:
                    fails.append("app: the on-disk build is NEWER than the running image; you built but did not "
                                 "relaunch. Relaunch via /wispr-rebuild-debug before UAT")
            except OSError:
                bin_mtime = None
            try:
                import wispr_eyes as w  # heavy; only once an instance is established
            except ImportError as e:
                # Preflight EXISTS to diagnose readiness, so a missing PyObjC must be
                # a reported NOT-READY item, never a crash before the report prints
                # (local Codex review, PR #2780). Skip the banner check (it needs the
                # driver); the machine probes below still run.
                w = None
                fails.append(f"harness: cannot import the driver in this Python ({e}); PyObjC is missing. "
                             "Run uat.py with the dev Python that has pyobjc (or `pip install pyobjc`). "
                             "Skipping the Debug-mode banner check")
            since = dt.datetime.fromtimestamp(app_start).astimezone()
            banners = w.launch_banners_since(since) if w is not None else None
            if banners is None:
                pass  # harness import failed above; the fail item is already recorded
            elif banners == 0:
                fails.append("log: no `[AppLogger] Debug mode enabled` banner since the app started. Either this "
                             "is not a debug build (use /wispr-rebuild-debug) or Debug Mode is off "
                             "(Settings > Diagnostics > Enable debug mode). Without it, app.log carries no verdicts")
            else:
                # The banner proves Debug Mode was on AT SOME POINT since launch, not
                # that it is on NOW: toggling it off closes the file sink but leaves the
                # banner (Codex diff review r4). The real current-logging proof is a
                # `uat.py run` returning exit 2 when no record lands, so this stays a
                # heads-up rather than a hard READY signal.
                print(f"OK    log               a Debug-mode banner is present since launch ({since.isoformat()})")
                print("NOTE  log-staleness      if Debug Mode was toggled OFF since, `uat.py run` will report "
                      "instrument failure — that, not this banner, is the current-logging proof")

    # 4. Machine probes. `fail` is hard, `warn`/`info` are recorded.
    for name, level, detail in pf.run_all():
        print(f"{level.upper():5} {name:17} {detail}")
        if level == "fail":
            fails.append(f"{name}: {detail}")
        elif level == "warn":
            warnings.append(f"{name}: {detail}")

    # 5. Reminders that are not probes but that every audio UAT has paid for.
    print("NOTE  real-data          custom-words.json is SHARED with the shipped app; snapshot before an import UAT "
          "(code-uat.md RULE: uat-writes-reach-the-founders-REAL-data)")
    print("NOTE  background         type_text/press_key/hold_key/scroll and every recipe that uses them need "
          "run_in_background: true")

    # 6. Optional occupied-room control (#2123): record 6 s of TRUE silence and
    # report the word count. Words with nothing to hear means someone is talking
    # near the mic and audio verdicts this session are suspect.
    if args.silent_probe and not fails:
        print("\n== SILENT PROBE (6 s of true silence) ==")
        import wispr_eyes as w
        state, words, _rec = run_silent_probe(w)
        if state == "inconclusive":
            warnings.append("silent-probe: no completed, attributable take; cannot tell whether the room is quiet. Re-run")
        elif state == "occupied":
            warnings.append(f"silent-probe: {words} words transcribed from silence; someone is talking near the mic and "
                            "every audio verdict would be theirs (#2123). Wait, or use the BlackHole recipe")
        else:
            print(f"OK    silent-probe      {words} word(s) from silence: room is quiet")

    # This is a NUDGE, not a gate (founder 2026-09-10): it reports what is and is
    # not ready and never blocks. `fails` are things that would make an audio UAT
    # meaningless (no app, wrong build, no debug log); a session reads them and
    # decides. Exit code mirrors the verdict for a caller that wants it, but
    # nothing downstream refuses on it.
    verdict = "READY" if not fails else "NOT-READY"
    print("\n== VERDICT ==")
    for f in fails:
        print(f"NOT READY  {f}")
    for wv in warnings:
        print(f"HEADS UP   {wv}")
    print(verdict)
    print("Recipes: " + ", ".join(cat.RECIPES) + "   ->   python3 Tests/RuntimeUAT/uat.py run <recipe>")
    return 0 if verdict == "READY" else 1


# --------------------------------------------------------------------- run --

def resolve_run_dir(explicit, worktree):
    """Where to drop `live-uat.json`, or None. This is a CONVENIENCE — the
    evidence file is useful to attach to a PR, never a gate — so a missing run
    dir just means "print, do not write", never a refusal (founder 2026-09-10:
    nudge, do not block)."""
    if explicit:
        explicit = os.path.abspath(explicit)
        return explicit if os.path.isdir(explicit) else None
    short = _git("rev-parse", "--short", "HEAD")
    matches = [d for d in glob.glob(os.path.join(worktree, ".validation", "runs", f"*-{short}"))
               if os.path.isdir(d)]
    return sorted(matches, key=os.path.getmtime)[-1] if matches else None


def derive_expected(sentence):
    """Same rule `test_recording` applies when `expect` is not given."""
    if "fox" in sentence.lower():
        return "fox"
    words = sentence.split()
    return words[len(words) // 2].lower() if words else ""


def cmd_run(args):
    worktree = this_worktree()
    recipe = cat.RECIPES.get(args.recipe)
    if recipe is None:
        raise SystemExit(f"unknown recipe {args.recipe!r}; one of: {', '.join(cat.RECIPES)}")
    # A heads-up, not a gate: an audio recipe against a muted speaker will read
    # silence as a product defect, so say so, but let the caller decide.
    if recipe["audio"]:
        level, detail, _l, _muted = pf.output_volume()
        if level != "ok":
            print(f"HEADS UP: {detail}")
    full_head = _git("rev-parse", "HEAD")
    # Build-vs-HEAD freshness for the receipt (local Codex review, PR #2780). The
    # front door does NOT prove the running build == HEAD — that is the push
    # gate's job — so if the running binary PREDATES HEAD's commit, these results
    # are from an older build and stamping them with head_sha would misattribute
    # them. Record what is verifiable: True (binary built at/after HEAD), False
    # (older, stale), or None (cannot tell — no single instance at this worktree's
    # path). A heads-up, never a gate.
    head_commit_epoch = _git("show", "-s", "--format=%ct", "HEAD")
    expected_bin = worktree + DEV_BUNDLE_SUFFIX
    running_here = [p for p, path in running_enviouswispr_instances().items() if path == expected_bin]
    build_matches_head = None
    if len(running_here) == 1 and head_commit_epoch.isdigit():
        try:
            build_matches_head = os.path.getmtime(expected_bin) >= int(head_commit_epoch)
        except OSError:
            build_matches_head = None
    if build_matches_head is False:
        print("HEADS UP: the running build is OLDER than HEAD's commit, so these results are from a build that "
              "predates this commit; head_sha would misattribute them. Rebuild + relaunch via "
              "/wispr-rebuild-debug before trusting the saved revision.")
    run_dir = resolve_run_dir(args.run_dir, worktree)

    import wispr_eyes as w

    # silent-probe always plays its OWN generated silence and derives its own
    # empty expectation, so --audio / --sentence / --expect are silently ignored.
    # A caller passing `--audio speech.wav` would believe they tested speech while
    # the probe played silence (cloud Codex review, PR #2780). Refuse them.
    if args.recipe == "silent-probe" and (args.audio or args.sentence or args.expect):
        raise SystemExit("REFUSED: silent-probe plays its own 6 s of silence and takes no --audio / "
                         "--sentence / --expect; drop them, or use heart-path / ptt to test a clip")

    # Reject inputs the recipe cannot honor rather than silently substituting the
    # default (Codex diff review r2): `record_tts` generates speech from a
    # sentence and has no audio-file input, so `--audio` there would be dropped
    # and the fox default could pass, testing nothing the caller asked for.
    if recipe["function"] == "record_tts" and args.audio:
        raise SystemExit(f"REFUSED: recipe {args.recipe!r} speaks --sentence and has no audio-file input; "
                         "drop --audio, or use heart-path / ptt, which accept --audio")
    # An --audio file with no --expect has no valid expectation: the default token
    # is derived from the FOX sentence, which the file never played, so a perfectly
    # transcribed clip would fail on `fox` (Codex diff review r4). Require --expect.
    if args.audio and not args.expect and args.recipe != "silent-probe":
        raise SystemExit(f"REFUSED: --audio needs --expect (a word the clip actually says); without it the "
                         "check would look for the default sentence the clip never played")
    # A missing, unreadable or empty --audio file makes `afplay` fail silently
    # (its stderr is suppressed and its exit is never checked in test_recording /
    # test_ptt), so the app records SILENCE and the front door would report a
    # false pass on a clip that never played (cloud Codex review, PR #2780).
    # Reject it up front rather than at the recipe.
    if args.audio:
        if not os.path.isfile(args.audio) or not os.access(args.audio, os.R_OK):
            raise SystemExit(f"REFUSED: --audio {args.audio!r} is not a readable file; the app would record "
                             "silence and the verdict would be a false pass")
        if os.path.getsize(args.audio) == 0:
            raise SystemExit(f"REFUSED: --audio {args.audio!r} is empty (0 bytes); nothing would play")

    sentence = args.sentence

    # The silent probe is not a generic recipe: it must play TRUE silence, not a
    # TTS clip, and its verdict is a word count gated on a completed take.
    if args.recipe == "silent-probe":
        print("== RUN silent-probe -> 6 s of true silence ==")
        state, words, newest = run_silent_probe(w)
        observed = (newest or {}).get("raw_asr") if newest else None
        take = (newest or {}).get("take") if newest else None
        expected_token, sentence = "", None
        harness_verdict = state == "quiet"
        exit_code = {"quiet": 0, "occupied": 1, "inconclusive": 2}[state]
        recs = [newest] if newest else []
    else:
        fn = getattr(w, recipe["function"])
        kwargs = dict(recipe.get("kwargs", {}))
        if args.audio:
            kwargs["audio"] = args.audio
        elif sentence:
            kwargs["sentence"] = sentence
        if args.expect:
            kwargs["expect"] = args.expect
        if recipe["function"] == "record_tts":
            kwargs.pop("expect", None)
            kwargs.pop("audio", None)
            if not sentence:
                sentence = "The quick brown fox jumps over the lazy dog"
            kwargs["sentence"] = sentence
        expected_token = args.expect or derive_expected(sentence or "The quick brown fox jumps over the lazy dog")

        mark = dt.datetime.now().astimezone()
        print(f"== RUN {args.recipe} -> {recipe['function']}({', '.join(f'{k}={v!r}' for k, v in kwargs.items())}) ==")
        result = fn(**kwargs)
        # Result adapter per recipe (r1 R6): record_tts returns a DICT whose
        # failure value is still truthy, so read its `success` field.
        if recipe["function"] == "record_tts":
            harness_verdict = bool(result.get("success")) if isinstance(result, dict) else False
        else:
            harness_verdict = bool(result)

        recs = collect_settled(w, mark)
        exit_code, observed, take, note = classify_transcription(recs, expected_token)
        if note:
            print(("INSTRUMENT: " if exit_code == 2 else "") + note)

    evidence = {
        "recipe": args.recipe,
        "function": recipe["function"],
        "sentence": sentence if args.recipe != "silent-probe" else None,
        "expected_token": expected_token,
        "observed_transcript": observed,
        "exit_code": exit_code,
        "harness_verdict": harness_verdict,
        "take": take,
        "head_sha": full_head,
        "build_matches_head": build_matches_head,
        "skipped": False,
        "dictations": recs,
        "ran_at": now_iso(),
    }
    print("\n== EVIDENCE ==")
    for n, r in enumerate(recs, 1):
        print(lv.format_record(n, r))
    print(f"expected_token={expected_token!r} observed_transcript={observed!r} exit_code={exit_code}")
    if run_dir:
        out = os.path.join(run_dir, "live-uat.json")
        tmp = out + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(evidence, fh, indent=2)
        os.replace(tmp, out)
        print(f"written: {out}  (attach to the PR if you like; not required)")
    else:
        print("no .validation run dir for HEAD; evidence printed above, not written. "
              "Pass --run-dir <dir> to save it.")
    if exit_code == 2:
        print("INSTRUMENT: no dictation record landed in app.log after the run. Check Debug Mode, the running "
              "build, and whether a second process was writing the log (code-tooling.md RULE: uat-verdicts-from-app-log)")
    return exit_code


# ----------------------------------------------------------------- verdict --

def cmd_verdict(args):
    if args.mark:
        with open(MARK, "w") as fh:
            fh.write(now_iso() + "\n")
        print(f"marked {now_iso()} -> {MARK}. Do the dictations, then: python3 Tests/RuntimeUAT/uat.py verdict")
        return 0
    if args.since:
        start = dt.datetime.fromisoformat(args.since)
    else:
        try:
            start = dt.datetime.fromisoformat(open(MARK).read().strip())
        except (OSError, ValueError):
            raise SystemExit("no mark; run `uat.py verdict --mark` BEFORE the dictations, or pass --since <ISO-8601>")
    if start.tzinfo is None:
        start = start.astimezone()
    import wispr_eyes as w
    recs = lv.collect_dictations(w.log_entries_since(start))
    if not recs:
        print(f"FAIL-CLOSED: no completed dictation since {start.isoformat()}. Either none ran, or the running app is "
              "not a debug build with Debug Mode on, or another process overwrote the log. An empty report is NOT a pass.")
        return 1
    print(f"{len(recs)} dictation(s) since {start.isoformat()}\n")
    for n, r in enumerate(recs, 1):
        print(lv.format_record(n, r, width=args.width))
        print()
    return 0


# -------------------------------------------------------------------- main --

def main(argv=None):
    p = argparse.ArgumentParser(prog="uat.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="verb", required=True)
    r = sub.add_parser("recipes", help="print recipes, harness function status, and the written-recipe index")
    r.add_argument("--names", action="store_true", help="recipe ids only, one per line")
    r.add_argument("--json", action="store_true")
    r.set_defaults(fn=cmd_recipes)
    pre = sub.add_parser("preflight", help="check this machine and write the receipt the gates read")
    pre.add_argument("--silent-probe", action="store_true", help="also record 6 s of silence to detect an occupied room")
    pre.set_defaults(fn=cmd_preflight)
    run = sub.add_parser("run", help="run a recipe and write live-uat.json")
    run.add_argument("recipe", choices=list(cat.RECIPES))
    run.add_argument("--sentence")
    run.add_argument("--expect")
    run.add_argument("--audio")
    run.add_argument("--run-dir")
    run.set_defaults(fn=cmd_run)
    v = sub.add_parser("verdict", help="dictation verdicts from app.log since the mark")
    v.add_argument("--mark", action="store_true")
    v.add_argument("--since")
    v.add_argument("--width", type=int, default=400)
    v.set_defaults(fn=cmd_verdict)
    args = p.parse_args(argv)
    return args.fn(args)


def _self_test():
    """Pure verdict-classifier control. uat.py imports no PyObjC at module level,
    so this runs on the hosted runner and locks the contract Codex diff review
    r2-r5 kept probing."""
    failures, ran = [], []

    def check(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        ran.append(name)
        if not cond:
            failures.append(name)

    def rec(result="completed", raw="the quick brown fox", steps=None, take="t1"):
        r = {"result": result, "raw_asr": raw, "steps": steps or {}, "take": take, "reason": "nil"}
        return r

    # --- classify_transcription ---
    ec, obs, _t, _n = classify_transcription([rec(steps={"LLM Polish": "the quick brown fox"})], "fox")
    check("completed + token present -> pass(0)", ec == 0 and obs == "the quick brown fox")
    ec, _o, _t, _n = classify_transcription([rec(steps={"LLM Polish": "the quick brown dog"})], "fox")
    check("completed + token absent -> fail(1)", ec == 1)
    ec, _o, _t, _n = classify_transcription([rec(result="failed", raw="fox")], "fox")
    check("failed terminal, even with the word -> fail(1)", ec == 1)
    # An early failure legitimately has NO transcript; that is a confirmed failure
    # (exit 1), never lost evidence (exit 2). Codex diff review r6.
    ec, _o, _t, _n = classify_transcription([rec(result="failed", raw=None, steps={})], "fox")
    check("failed terminal with NO transcript -> fail(1), not instrument", ec == 1)
    ec, _o, _t, _n = classify_transcription([rec(result="cancelled", raw=None, steps={})], "fox")
    check("cancelled terminal with no transcript -> fail(1)", ec == 1)
    ec, _o, _t, _n = classify_transcription([rec(result="completed", raw=None, steps={})], "fox")
    check("COMPLETED but no transcript -> instrument(2)", ec == 2)
    ec, _o, _t, _n = classify_transcription([rec(), rec(take="t2")], "fox")
    check("two records -> instrument(2), not 'the newest'", ec == 2)
    ec, _o, _t, _n = classify_transcription([], "fox")
    check("no record -> instrument(2)", ec == 2)
    # An empty final output is emptyOutputRecoveryFloor territory: the delivered
    # text is computed off-log, so a completed take is INCONCLUSIVE, never judged
    # against a pre-floor step (local Codex review, PR #2780).
    ec, obs, _t, _n = classify_transcription(
        [rec(steps={"Filler Removal": "the quick brown fox", "LLM Polish": ""})], "fox")
    check("empty final output -> instrument(2), not a pass on a pre-floor step", ec == 2 and obs is None)

    # --- classify_silent ---
    check("no_speech -> quiet", classify_silent([rec(result="no_speech", raw="")]) == ("quiet", 0))
    check("completed, <2 words from silence -> quiet", classify_silent([rec(result="completed", raw="")]) == ("quiet", 0))
    check("completed, >=2 words -> occupied",
          classify_silent([rec(result="completed", raw="two words here")]) == ("occupied", 3))
    check("completed but transcript lost -> inconclusive",
          classify_silent([rec(result="completed", raw=None)]) == ("inconclusive", None))
    check("failed take -> inconclusive", classify_silent([rec(result="failed", raw="")]) == ("inconclusive", None))
    check("cancelled take -> inconclusive", classify_silent([rec(result="cancelled", raw="")]) == ("inconclusive", None))
    check("no record -> inconclusive", classify_silent([]) == ("inconclusive", None))
    check("two records -> inconclusive", classify_silent([rec(), rec(take="t2")]) == ("inconclusive", None))

    # --- collect_settled gates on STABILITY, not the first record ---
    # A second terminal landing a beat later (two instances answering one PTT
    # gesture) must not be missed; the reader waits for the count to hold across
    # stable_reads (cloud Codex review, PR #2780). Scripted reader + fake clock,
    # no real app.
    def scripted(seq):
        state = {"i": 0}
        def _read():
            v = seq[min(state["i"], len(seq) - 1)]
            state["i"] += 1
            return v
        return _read
    clock = {"t": 0.0}
    def now():
        return clock["t"]
    def tick(_):
        clock["t"] += 0.2
    one, two = [{"take": "a"}], [{"take": "a"}, {"take": "b"}]
    # One record, stable -> returns the single record.
    clock["t"] = 0.0
    r_one = collect_settled(None, None, stable_reads=3, _read=scripted([one, one, one, one, one]), _now=now, _sleep=tick)
    check("collect_settled: one stable record -> 1", len(r_one) == 1)
    # A second terminal appears on read 2; must NOT stop at the first record.
    clock["t"] = 0.0
    r_two = collect_settled(None, None, stable_reads=3,
                            _read=scripted([one, two, two, two, two, two]), _now=now, _sleep=tick)
    check("collect_settled: a late second record is not missed -> 2", len(r_two) == 2)

    # --- silent wav is real ---
    import wave
    p = _silent_wav(6.0)
    with wave.open(p) as wv:
        check("silent wav is ~6 s mono 16-bit", abs(wv.getnframes() / wv.getframerate() - 6.0) < 0.01
              and wv.getnchannels() == 1 and wv.getsampwidth() == 2)

    # Counted from the rows that RAN, never a literal (a hardcoded total drifts
    # the first time a check is added and reports N/N+1 as a pass).
    total = len(ran)
    if failures:
        print(f"\nuat self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\nuat self-test: {total}/{total} passed")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
