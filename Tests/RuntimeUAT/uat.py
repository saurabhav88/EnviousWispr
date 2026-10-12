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
        app_start = pf.proc_start_epoch(int(running_here[0]))
        try:
            bin_mtime = os.path.getmtime(expected_bin)
        except OSError:
            bin_mtime = None
        if app_start is None or bin_mtime is None:
            build_matches_head = None  # cannot read one side; do not certify
        elif bin_mtime > app_start + 1:
            # Built AFTER the running app launched: rebuilt but not relaunched, so
            # the RUNNING process is the OLD binary whatever the on-disk mtime says
            # (the stale-process trap cmd_preflight already checks). A fresh binary
            # on disk does NOT mean fresh code is running.
            build_matches_head = False
        else:
            # The running app IS this on-disk binary; certify it against HEAD.
            build_matches_head = bin_mtime >= int(head_commit_epoch)
    if build_matches_head is False:
        print("HEADS UP: the running app is NOT this commit's build (either built without relaunching, or the "
              "build predates HEAD), so these results are from older code; head_sha would misattribute them. "
              "Rebuild + relaunch via /wispr-rebuild-debug before trusting the saved revision.")
    run_dir = resolve_run_dir(args.run_dir, worktree)

    # Script-backed recipe (#996 learn-from-edits): the script owns its cases,
    # verdicts, restore and receipt files; the front door only resolves the run
    # directory, forwards the recipe's own arguments and returns its exit code.
    if "script" in recipe:
        if args.audio or args.sentence or args.expect:
            raise SystemExit(f"REFUSED: recipe {args.recipe!r} is script-backed and takes no --audio / --sentence / "
                             "--expect; it speaks its own sentences")
        if not run_dir:
            raise SystemExit(f"REFUSED: recipe {args.recipe!r} writes its receipts into --run-dir; pass an existing directory")
        command = [sys.executable, "-u", os.path.join(HERE, recipe["script"]), "--run-dir", run_dir]
        if recipe.get("export"):
            if not args.export:
                raise SystemExit(f"REFUSED: recipe {args.recipe!r} needs --export <locked candidate fp32 directory>")
            command += ["--export", args.export]
        elif args.export:
            raise SystemExit(f"REFUSED: recipe {args.recipe!r} takes no --export")
        print(f"== RUN {args.recipe} -> {recipe['script']} (run dir {run_dir}) ==", flush=True)
        completed = subprocess.run(command)
        return completed.returncode

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

def cmd_capture_ready(args):
    """Read-only, authenticated readiness for this exact launched dev bundle."""
    import time
    from pathlib import Path
    import wispr_eyes as w
    from instance_guard import InstanceGuardError
    executable = str(Path(args.app).resolve() / "Contents/MacOS/EnviousWispr")
    try:
        w.connect(expected_executable=executable)
        target = w._target
        deadline = time.monotonic() + 30.0  # existing endpoint startup allowance
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print("Capture query did not become ready before the startup deadline.", file=sys.stderr)
                return 1
            try:
                w._capture_snapshot(target, min(5.0, remaining))
                print(f"Authenticated capture query ready (PID {target.pid}).")
                return 0
            except InstanceGuardError:
                raise
            except (RuntimeError, OSError):
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))  # deadline-fallback: observe endpoint readiness
    except InstanceGuardError:
        print("Capture query target identity is missing, ambiguous or replaced.", file=sys.stderr)
        return 2


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
    run.add_argument("--export", help="script-backed recipes only: the locked candidate's fp32 export directory")
    run.set_defaults(fn=cmd_run)
    v = sub.add_parser("verdict", help="dictation verdicts from app.log since the mark")
    v.add_argument("--mark", action="store_true")
    v.add_argument("--since")
    v.add_argument("--width", type=int, default=400)
    v.set_defaults(fn=cmd_verdict)
    ready = sub.add_parser("capture-ready", help="verify the launched dev app's authenticated capture query")
    ready.add_argument("--app", required=True)
    ready.set_defaults(fn=cmd_capture_ready)
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

    # Startup command contracts only: the strict capture parser is separately
    # exercised by lifecycle controls; these stubs never connect to a native app.
    import contextlib
    import io
    import types
    from unittest.mock import patch
    from instance_guard import InstanceGuardError
    from pathlib import Path
    import time as clock_module
    for name, responses, connect_error, expected in [
        ("capture readiness uses the exact pinned target", [None], None, 0),
        ("capture readiness waits for the endpoint signal", [RuntimeError("not ready"), None], None, 0),
        ("capture readiness times out instead of reporting success", [RuntimeError("not ready")], None, 1),
        ("capture readiness refuses a replaced target", [InstanceGuardError("replaced")], None, 2),
        ("capture readiness refuses an ambiguous connection", [], InstanceGuardError("ambiguous"), 2),
    ]:
        clock_state, queries, connections = {"now": 0.0}, [], []
        target = types.SimpleNamespace(pid=111)
        def fake_connect(**kwargs):
            connections.append(kwargs)
            if connect_error is not None:
                raise connect_error
        def fake_query(actual, timeout):
            queries.append((actual, timeout))
            reply = responses[min(len(queries) - 1, len(responses) - 1)]
            if isinstance(reply, Exception):
                raise reply
            return {"v": "1", "pid": "111"}
        fake_owner = types.SimpleNamespace(connect=fake_connect, _target=target, _capture_snapshot=fake_query)
        with patch.dict(sys.modules, {"wispr_eyes": fake_owner}), \
             patch.object(clock_module, "monotonic", side_effect=lambda: clock_state["now"]), \
             patch.object(clock_module, "sleep", side_effect=lambda seconds: clock_state.update(now=clock_state["now"] + seconds)), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = cmd_capture_ready(types.SimpleNamespace(app="/test/EnviousWispr Local.app"))
        wanted = str(Path("/test/EnviousWispr Local.app").resolve() / "Contents/MacOS/EnviousWispr")
        check(name, result == expected and connections == [{"expected_executable": wanted}]
              and (not queries if connect_error else bool(queries))
              and all(actual is target and 0 < timeout <= 5 for actual, timeout in queries)
              and (len(queries) == 2 if len(responses) == 2 else True))

    # Counted from the rows that RAN, never a literal (a hardcoded total drifts
    # the first time a check is added and reports N/N+1 as a pass).
    total = len(ran)
    if failures:
        print(f"\nuat self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\nuat self-test: {total}/{total} passed")
    return 0


def _lifecycle_self_test():
    """Harness contracts only: execute source owners against private OS/AX fixtures."""
    import ast
    import io
    import contextlib
    import collections
    import math
    import pathlib
    import signal as signal_api
    import stat
    import tempfile
    import types
    import wave
    import fcntl
    import concurrent.futures
    import threading
    import copy
    import hashlib
    import select
    import uuid
    from unittest.mock import patch
    import instance_guard as guard
    native_process_start = guard.process_start
    import settings_nav as settings_owner
    import ptt_binding
    from settings_nav_fixtures import FakeSettings
    root = pathlib.Path(__file__).parent
    ran, failures, skipped = [], [], []
    executable = "/test/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"
    target = guard.TargetIdentity(111, executable, (123, 456))

    def require(value):
        if not value:
            raise AssertionError("lifecycle contract did not hold")

    def compile_functions(path, names, namespace):
        tree = ast.parse(path.read_text())
        nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names]
        require({n.name for n in nodes} == names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)

    @contextlib.contextmanager
    def fixture(directory, **options):
        events, state = [], {"mode": "idle", "open": False, "alive": True, "clock": 0.0, **options}
        class Settings(FakeSettings):
            generation = 0
            def _act(self, name, change):
                original = super()._act(name, change)
                def press():
                    if name == "input-open":
                        self.generation += 1
                        if state.get("recording_during_picker"):
                            state["mode"] = "recording"
                    if name == "tab:Microphone" and state.get("recording_during_navigation"):
                        state["mode"] = "recording"
                    if name.startswith("input:") and name != "input:BlackHole 2ch" and state.get("app_noop"):
                        self.presses.append(name)
                        return True
                    result = original()
                    if name.startswith("input:") and name != "input:BlackHole 2ch" and state.get("app_raise"):
                        raise RuntimeError("microphone selection failed after acting")
                    return result
                return press
            def root(self):
                root = super().root()
                def identify(node, path=()):
                    node["_native_id"] = (path, self.generation if node.get("AXRole") in {"AXMenu", "AXMenuItem", "AXPopover"} else 0)
                    for i, child in enumerate(node.get("AXChildren", [])):
                        identify(child, path + (i,))
                identify(root)
                return root
        settings = Settings()
        application = object()
        class Signals:
            SIGINT, SIGTERM, SIGHUP = signal_api.SIGINT, signal_api.SIGTERM, signal_api.SIGHUP
            SIG_BLOCK, SIG_SETMASK = signal_api.SIG_BLOCK, signal_api.SIG_SETMASK
            SIG_IGN = signal_api.SIG_IGN
            handlers, mask, pending = {}, set(), []
            @classmethod
            def getsignal(cls, sig):
                return cls.handlers.get(sig, signal_api.SIG_DFL)
            @classmethod
            def signal(cls, sig, handler):
                cls.handlers[sig] = handler
            @classmethod
            def fire(cls, sig):
                if sig in cls.mask:
                    cls.pending.append(sig)
                else:
                    handler = cls.getsignal(sig)
                    if callable(handler):
                        handler(sig, None)
                    else:
                        raise SystemExit(128 + sig)
            @classmethod
            def pthread_sigmask(cls, how, mask):
                previous = cls.mask.copy()
                cls.mask = cls.mask | set(mask) if how == cls.SIG_BLOCK else set(mask)
                ready = [sig for sig in cls.pending if sig not in cls.mask]
                cls.pending = [sig for sig in cls.pending if sig in cls.mask]
                for sig in ready:
                    cls.fire(sig)
                return previous
        def sleep(seconds):
            state["clock"] += max(seconds, 0.001)
        clock = types.SimpleNamespace(monotonic=lambda: state["clock"], time=lambda: state["clock"], sleep=sleep)
        def ax_read(el, attr, unused):
            if el is application:
                if attr == "AXExtrasMenuBar":
                    state["start_checks"] = state.get("start_checks", 0) + 1
                    if state.get("competing_start") and state["start_checks"] == 2:
                        state["mode"] = "recording"
                    return (5, None) if state.get("unreadable") else (0, "bar")
                return 0, settings.root().get(attr)
            if isinstance(el, dict):
                return 0, el.get(attr)
            if state.get("unreadable"):
                return 5, None
            if state.get("title_error") and attr == "AXTitle":
                return 5, None
            table = {("app", "AXExtrasMenuBar"): "bar", ("bar", "AXChildren"): ["status"],
                     ("status", "AXChildren"): ["menu"] if state["open"] else [],
                     ("menu", "AXRole"): "AXMenu", ("menu", "AXChildren"): [] if state.get("empty") else
                         (["start", "stop"] if state.get("contradictory") else ["stop" if state["mode"] == "recording" else "start"]),
                     ("start", "AXRole"): "AXMenuItem", ("stop", "AXRole"): "AXMenuItem",
                     ("start", "AXTitle"): "Aufnahme starten" if state.get("german") else "Start Recording",
                     ("stop", "AXTitle"): "Aufnahme stoppen" if state.get("german") else "Stop Recording",
                     ("start", "AXEnabled"): not state.get("disabled", False) and state["mode"] != "arming", ("stop", "AXEnabled"): True}
            return (0, table[(el, attr)]) if (el, attr) in table else (5, None)
        def ax_action(el, action):
            if isinstance(el, dict):
                if action == "AXCancel":
                    settings.menu_open = False
                    settings.cancels += 1
                    settings.presses.append("cancel")
                    return True
                if action == "AXPress":
                    events.append(("selection", el.get("AXTitle") or el.get("AXDescription")))
                    return el["_press"]() if el.get("_press") else False
            events.append(("AX", el, action))
            if el == "status":
                settings.menu_open = False
                state["open"] = True
            elif el == "menu":
                state["open"] = False
                if state.get("cancel_raise") and (state.get("cancel_any") or state["mode"] == "recording"):
                    state["cancel_raise"] = False
                    raise RuntimeError("menu cancel failed")
            elif el == "start":
                state["mode"] = "recording"
                if state.get("start_raise"):
                    raise RuntimeError("Start failed after acting")
                if state.get("start_false"):
                    return False
            elif el == "stop":
                if not state.get("stop_noop"):
                    state["mode"] = "idle"
                if state.get("stop_raise"):
                    raise RuntimeError("Stop failed after acting")
                if state.get("stop_false"):
                    return False
            return True
        player = []
        class Player:
            returncode = None
            pid = 222222222
            def __init__(self, *args, **kwargs):
                self.child_fds = []
                events.append(("launch",))
                if state.get("launch_fail"):
                    raise OSError("playback launch failed")
                player.append(self)
                command = args[0]
                if len(command) > 2 and command[1] == "-c":
                    expected_fds = tuple(int(command[index]) for index in (4, 5, 6))
                    require(kwargs.get("pass_fds") == expected_fds)
                    self.child_fds = [os.dup(expected_fds[0]), os.dup(expected_fds[1])]
                    ready_fd = int(command[6])
                    os.write(ready_fd, (json.dumps({"pid": self.pid, "start": [123, 456]}) + "\n").encode())
                if state.get("signal_acquire"):
                    Signals.fire(Signals.SIGTERM)
            def poll(self):
                return self.returncode
            def wait(self, timeout):
                if self.returncode is None:
                    self.communicate(timeout)
                return self.returncode
            def close_child_fds(self):
                for fd in self.child_fds:
                    os.close(fd)
                self.child_fds = []
            def communicate(self, timeout):
                events.append(("communicate",))
                if self.returncode is not None:
                    return None, b""
                if state.get("hung") or state.get("unreapable"):
                    sleep(timeout)
                    raise subprocess.TimeoutExpired("afplay", timeout)
                if self.child_fds:
                    require(os.read(self.child_fds[1], 3) == b"GO\n")
                self.returncode = 1 if state.get("playback_fail") else 0
                self.close_child_fds()
                if state.get("premature"):
                    state["mode"] = "idle"
                return None, b"playback error" if self.returncode else b""
            def terminate(self):
                events.append(("terminate",))
                if state.get("signal_cleanup"):
                    Signals.fire(Signals.SIGTERM)
                    Signals.fire(Signals.SIGTERM)
                if not state.get("unreapable"):
                    self.returncode = -15
                    self.close_child_fds()
            def kill(self):
                events.append(("kill",))
                if not state.get("unreapable"):
                    self.returncode = -9
                    self.close_child_fds()
        devices = {"input": {"name": "Physical input", "uid": "physical-i", "id": "101", "type": "input"},
                   "output": {"name": "Physical output", "uid": "physical-o", "id": "102", "type": "output"}}
        devices["system"] = dict(devices["output"])
        originals = {k: dict(v) for k, v in devices.items()}
        def run(args, **kwargs):
            if args[0] == "ps":
                return types.SimpleNamespace(returncode=0, stdout=sys.executable + "\n", stderr="")
            if args[0] == "afinfo":
                return types.SimpleNamespace(returncode=1, stdout="duration 1.0 sec", stderr="failed")
            kind = args[args.index("-t") + 1]
            virtual = {"name": "BlackHole 2ch", "uid": "BlackHole2ch_UID", "id": "59", "type": "input" if kind == "input" else "output"}
            if "-a" in args:
                rows = [originals[kind], virtual]
                if state.get("new_recording_during_resolution") and any(
                        event[0] in {"AX", "query"} for event in events[state.get("resolution_anchor", len(events)):]):
                    state["new_recording_during_resolution"] = False
                    state["mode"] = "recording"
                if state.get("duplicate"):
                    rows.append(dict(virtual))
            elif "-c" in args:
                rows = [devices[kind]]
                if state.get("route_unreadable"):
                    return types.SimpleNamespace(returncode=1, stdout="", stderr="unreadable")
            else:
                device = virtual if args[args.index("-i") + 1] == "59" else originals[kind]
                events.append(("switch", kind, device["uid"]))
                if (state.get("restore_fail") or state.get("restore_fail_kind") == kind) and device["uid"].startswith("physical"):
                    return types.SimpleNamespace(returncode=0, stdout="", stderr="")
                devices[kind] = dict(device)
                if state.get("new_recording_after_output") and kind == "output" and device["uid"].startswith("physical"):
                    state["new_recording_after_output"] = False
                    state["mode"] = "recording"
                for option in ("signal_apply", "signal_restore"):
                    if state.get(option) and ((option == "signal_apply") == (device["uid"] == "BlackHole2ch_UID")):
                        state[option] = False
                        Signals.fire(Signals.SIGTERM)
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")
            return types.SimpleNamespace(returncode=0, stdout="\n".join(json.dumps(row) for row in rows), stderr="")
        boundary = types.SimpleNamespace(run=run, Popen=Player, DEVNULL=subprocess.DEVNULL,
                                         PIPE=subprocess.PIPE, TimeoutExpired=subprocess.TimeoutExpired)
        token_path = directory / "fault-token-111"
        token_path.write_bytes(b"a" * 64); token_path.chmod(0o600)
        class Connection:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def settimeout(self, timeout): require(timeout > 0)
            def sendall(self, payload):
                require(payload == b"a" * 64 + b"\nquery_capture_state\n")
                sequence = state.get("query_sequence")
                if sequence:
                    phase, released = sequence.pop(0)
                    state["mode"] = "recording" if phase == "live" else "arming" if phase == "arming" else "idle"
                else:
                    phase = state.get("raw_phase", "live" if state["mode"] == "recording" else "idle")
                    released = state.get("released", state["mode"] != "recording")
                other_phase = state.get("other_phase", "idle")
                other_released = state.get("other_released", True)
                reply = (f"OK v=1 pid=111 parakeet_phase={phase} parakeet_released={str(released).lower()} "
                         f"whisperkit_phase={other_phase} whisperkit_released={str(other_released).lower()} backend=parakeet\n")
                self.chunks = [state.get("query_reply", reply).encode(), b""]
                if state.get("fragment_reply"):
                    self.chunks = [self.chunks[0][:11], self.chunks[0][11:37], self.chunks[0][37:], b""]
                events.append(("query", phase, released))
            def recv(self, count):
                if state.get("query_timeout"):
                    raise TimeoutError("query timed out")
                chunk = self.chunks[0][:count]
                self.chunks[0] = self.chunks[0][count:]
                if not self.chunks[0]:
                    self.chunks.pop(0)
                if not chunk and state.get("change_token"):
                    token_path.write_bytes(b"b" * 64)
                if not chunk and state.get("change_identity"):
                    state["alive"] = False
                return chunk
        def connection(address, timeout):
            require(address == ("127.0.0.1", 8765) and timeout > 0)
            return Connection()
        native = {"AXUIElementCopyAttributeValue": ax_read, "AXUIElementGetPid": lambda el, out: (0, 111), "kAXErrorSuccess": 0}
        compile_functions(root / "ui_helpers.py", {"get_attr_checked", "element_pid"}, native)
        w = types.ModuleType("private_lifecycle_subject")
        w.__dict__.update({"__file__": str(root / "wispr_eyes.py"), "_target": target, "_pid": 111, "_app": "app",
            "_active_audio_route": None, "_standalone_player": None, "_PLAYBACK_OWNER_UNSET": object(),
            "_TABLES": (111, [{"Start Recording": "Aufnahme starten", "Stop Recording": "Aufnahme stoppen"}]),
            "_recording_cleanup_safe": True, "contextlib": contextlib, "math": math, "signal": Signals,
            "time": clock, "subprocess": boundary, "os": os, "pathlib": pathlib, "json": json, "sys": sys,
            "socket": types.SimpleNamespace(create_connection=connection), "stat": stat,
            "_CAPTURE_TOKEN_DIR": directory,
            "verify_target": guard.verify_target, "pin_target": guard.pin_target, "InstanceGuardError": guard.InstanceGuardError,
            "running_enviouswispr_instances": lambda: guard.running_enviouswispr_instances(), "get_ax_app": lambda pid: application,
            "get_attr_checked": native["get_attr_checked"], "element_pid": native["element_pid"],
            "_raw_perform_action": ax_action, "_raw_set_attr": lambda *a: True,
            "get_attr": lambda el, attr: ax_read(el, attr, None)[1],
            "_iter_children_with_menubars": lambda el: ax_read(el, "AXChildren", None)[1] or [],
            "element_frame": lambda el: el.get("_frame") if isinstance(el, dict) else None,
            "NavigationError": settings_owner.NavigationError, "RouteError": settings_owner.RouteError,
            "_sn": settings_owner,
            "close_window": lambda: False, "begin_test": lambda *a: None, "end_test": lambda: None,
            "_snapshot_log_size": lambda: 0, "get_clipboard_text": lambda: "",
            "_wait_for_pipeline_completion": lambda *a: (True, "log", "completed", ["completed"], None, []),
            "_extract_transcript_text": lambda *a: "known words", "tts": lambda *a: (_ for _ in ()).throw(AssertionError("unexpected TTS"))})
        names = {"connect", "_ensure_connected", "_verify_element", "perform_action", "set_attr", "_ui_tables", "_ui_terms",
                 "bind_after_verified_exit",
                 "_audio_duration", "_defer_recording_signals", "_recording_interruptions", "_recording_control",
                 "_read_capture_token", "_capture_snapshot", "_recording_state", "_require_idle_without_ui",
                 "_stop_recording", "_spawn_owned_playback", "_reap_playback", "_legacy_capture", "_finish_playback_on_exit", "test_recording", "_report_result", "_ax", "nav",
                 "_open_settings", "_cancel_menu", "_stored", "_input_read_uid",
                 "read_input_choice", "select_input_choice", "restore_input_choice"}
        compile_functions(root / "wispr_eyes.py", names, w.__dict__)
        audio = {"w": w, "os": os, "json": json, "signal": Signals, "sys": sys, "time": clock,
                 "subprocess": boundary, "fcntl": fcntl, "tempfile": tempfile, "stat": stat, "contextlib": contextlib,
                 "copy": copy, "hashlib": hashlib, "select": select, "threading": threading, "uuid": uuid,
                 "HERE": str(root),
                 "SWITCH": sys.executable, "SILENT_DEVICE": "BlackHole 2ch", "RESTORE_FILE": str(directory / "restore.json")}
        tree = ast.parse((root / "silent_audio.py").read_text())
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                if node.targets[0].id in {"_PLAYER", "_CHILD"}:
                    audio[node.targets[0].id] = ast.literal_eval(node.value)
        names = {n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
        compile_functions(root / "silent_audio.py", names, audio)
        audio["AlertSink"].FILE = str(directory / "alert.json")
        audio_module = types.ModuleType("private_lifecycle_audio")
        audio_module.__dict__.update(audio)
        clip = directory / "sample.wav"
        with wave.open(str(clip), "wb") as fh:
            fh.setnchannels(1); fh.setsampwidth(2); fh.setframerate(8000); fh.writeframes(b"\0\0" * 8000)
        real_ax = settings_owner.AX
        def adapter(**kwargs):
            kwargs.update(sleep=sleep, clock=lambda: state["clock"], same=lambda a, b:
                          a is b or (isinstance(a, dict) and isinstance(b, dict)
                                     and a.get("_native_id") == b.get("_native_id")))
            return real_ax(**kwargs)
        with patch.dict(sys.modules, {"silent_audio": audio_module}), \
             patch.object(settings_owner, "AX", side_effect=adapter), \
             patch.object(ptt_binding, "read_domain", side_effect=lambda: {"preferredInputDeviceIDOverride": settings.input_uid}), \
             patch.object(guard, "process_start", return_value=target.start), \
             patch.object(guard, "running_enviouswispr_instances", side_effect=lambda: {"111": executable} if state["alive"] else {}):
            try:
                yield types.SimpleNamespace(w=w, audio=audio, events=events, state=state, player=player,
                                            devices=devices, originals=originals, clip=str(clip), signals=Signals, settings=settings)
            finally:
                for process in player:
                    process.close_child_fds()

    def case(family, name, action, *, native_macos=False, **options):
        if native_macos and sys.platform != "darwin":
            skipped.append((family, name, "requires the real macOS native process identity reader"))
            return
        ran.append((family, name))
        try:
            with tempfile.TemporaryDirectory(prefix="ew-lifecycle-") as directory, \
                 fixture(pathlib.Path(directory), **options) as f, contextlib.redirect_stdout(io.StringIO()):
                action(f)
        except BaseException as error:
            failures.append(f"{family}/{name}: {error!r}")

    def recording(f):
        return f.w.test_recording(audio=f.clip, expect="known", timeout=0.2)
    def failed_recording(f):
        try:
            recording(f)
        except BaseException as error:
            expected = next(message for option, message in [
                ("start_raise", "Start failed after acting"), ("launch_fail", "playback launch failed"),
                ("playback_fail", "audio playback failed"), ("hung", "audio playback exceeded"),
                ("premature", "capture ended during playback"), ("stop_raise", "Stop failed after acting"),
                ("signal_acquire", "signal"), ("signal_cleanup", "audio playback exceeded")]
                if f.state.get(option))
            require((isinstance(error, SystemExit) and error.code == 128 + f.signals.SIGTERM)
                    if expected == "signal" else expected in str(error))
            require(any(e[:2] == ("AX", "start") for e in f.events))
            require(f.state["mode"] == "idle")
            require(all(player.poll() is not None for player in f.player))
            require(f.w._recording_cleanup_safe and not f.signals.mask and not f.signals.pending)
            return
        raise AssertionError("failed take was accepted")
    def refused_start(f):
        try:
            recording(f)
        except RuntimeError as error:
            require("recording action is not currently available" in str(error))
        else:
            raise AssertionError("competing take did not refuse Start")
        require(f.state["mode"] == "recording")
        require(not any(event[0] == "launch" or event[:2] in {("AX", "start"), ("AX", "stop")}
                        for event in f.events))
    case("recording", "Start refusal leaves existing take untouched", refused_start, competing_start=True)
    case("recording", "normal natural playback", lambda f: require(recording(f) is True))
    case("recording", "false Start that acted", lambda f: require(recording(f) is True), start_false=True)
    case("recording", "raising Start that acted", failed_recording, start_raise=True)
    case("recording", "playback launch failure", failed_recording, launch_fail=True)
    case("recording", "playback nonzero", failed_recording, playback_fail=True)
    case("recording", "playback timeout", failed_recording, hung=True)
    case("recording", "premature capture", failed_recording, premature=True)
    case("recording", "false Stop that acted", lambda f: require(recording(f) is True), stop_false=True)
    case("recording", "raising Stop that acted", failed_recording, stop_raise=True)
    def legacy_ingress(f, kind="ptt", key="ropt", failure=None, missing_marker=None,
                       second_failure=None, late_refusal=False, interrupt_thread=False):
        """Actual callers and input primitives; fake only native events, log and scheduling."""
        inputs = types.ModuleType("simulate_input")
        events = f.events
        counts = {"down": 0, "up": 0}
        native_errors = {direction: RuntimeError("native " + direction + " failed after acting")
                         for direction in ("down", "up")}
        hold_failure = RuntimeError("native hold interrupted")
        callback_failure = RuntimeError("before release failed")
        join_failure = RuntimeError("native join failed")
        def event(_, code, down):
            if late_refusal:
                # Native event construction occurs inside hold_key, after envelope preflight.
                f.state["mode"] = "recording"
            return {"code": code, "down": down}
        def post(_, value):
            direction = "down" if value["down"] else "up"
            counts[direction] += 1
            events.append(("key", direction, value["code"]))
            if kind == "hands-free":
                if value["down"] and not f.state.get("idle_gesture"):
                    f.state["mode"] = "idle" if counts["down"] >= 3 else "recording"
            else:
                if not (direction == "up" and f.state.get("cleanup_stop_noop")):
                    f.state["mode"] = "recording" if value["down"] else "idle"
            if kind == "tts" and not value["down"]:
                with log.open("a") as output:
                    output.write("CORRECTION_DEBUG [RAW ASR] known words\n")
            if failure == direction or second_failure == direction or (failure == "second-down" and direction == "down" and counts[direction] == 2):
                raise native_errors[direction]
        actual_sleep = f.w.time.sleep
        interrupted = False
        def sleep(seconds):
            nonlocal interrupted
            if not interrupted and ((failure == "engagement" and seconds == 0.8) or
                                    (failure == "hold" and seconds > 1) or
                                    (failure == "pulse" and seconds == 0.04)):
                interrupted = True
                raise hold_failure
            actual_sleep(seconds)
        inputs.__dict__.update(MODIFIER_KEYS={"ropt": 61}, KEY_CODES={"space": 49}, _MODIFIER_FLAGS={61: 8},
            CGEventCreateKeyboardEvent=event, CGEventPost=post,
            CGEventSetType=lambda *unused: None, CGEventSetFlags=lambda *unused: None,
            CGEventSetIntegerValueField=lambda *unused: None,
            kCGHIDEventTap=0, kCGEventFlagsChanged=1, kCGKeyboardEventKeycode=2,
            kCGEventFlagMaskCommand=4, kCGEventFlagMaskShift=2,
            kCGEventFlagMaskAlternate=8, kCGEventFlagMaskControl=16,
            DEFAULT_DELAY=0.1, time=types.SimpleNamespace(sleep=sleep), sys=sys)
        compile_functions(root / "simulate_input.py", {"_flags_changed_event", "hold_modifier", "hold_key"}, inputs.__dict__)
        class Thread:
            def __init__(self, target): self.target, self.started = target, False
            def start(self):
                self.started = True
                events.append(("thread", "start"))
                self.target()
                if interrupt_thread:
                    f.signals.fire(f.signals.SIGTERM)
            def join(self):
                require(self.started)
                events.append(("thread", "join"))
                if second_failure == "join":
                    raise join_failure
        scheduler = types.SimpleNamespace(Thread=Thread, current_thread=threading.current_thread,
                                           main_thread=threading.main_thread)
        binding = types.SimpleNamespace(key_name=key, keycode=61 if key == "ropt" else 49, is_modifier_only=True)
        markers = ["Double press", "Hands-free mode activated", "Single press while locked"]
        log = pathlib.Path(f.clip).with_suffix(".log")
        log.write_text("CORRECTION_DEBUG [RAW ASR] known words\n")
        f.w.__dict__.update(_dt=dt, _CHAIN_WINDOW_S=0.5, _APP_LOG_PATH=str(log),
            _chime=lambda: None, tts=lambda *args, **kwargs: f.clip,
            resolve=lambda: binding, require_push_to_talk=lambda: None,
            _ptt_binding_diagnostic=lambda *unused: None,
            _require_single_instance=lambda *unused: {"111": executable},
            instances_stayed_single=lambda *unused: (True, "private fixture"),
            log_lines_since=lambda *unused: [m for m in markers if m != missing_marker],
            _find_match=lambda *unused: None if f.state.get("missing_observation") else
                ("stop" if f.state["mode"] == "recording" else None))
        f.w.time = types.SimpleNamespace(monotonic=f.w.time.monotonic, time=f.w.time.time, sleep=sleep)
        compile_functions(root / "wispr_eyes.py", {"test_ptt", "test_hands_free", "record_tts",
            "press_record_key", "double_press_record_key", "single_press_record_key", "stop_after_short_hold"}, f.w.__dict__)
        def before_release():
            if failure == "before-release": raise callback_failure
        error = None
        with patch.dict(sys.modules, {"simulate_input": inputs, "threading": scheduler}), \
             patch.object(ptt_binding, "resolve", return_value=binding):
            try:
                if kind == "input":
                    inputs.hold_key(key, duration=2.0, before_release=before_release)
                    result = True
                elif kind == "ptt":
                    result = f.w.test_ptt(key=key, audio=f.clip, expect="known", timeout=0.2)
                elif kind == "hands-free":
                    result = f.w.test_hands_free(audio="" if failure == "short" else f.clip,
                        hold=0.2 if failure == "short" else 4.0, expect="known", timeout=0.2)
                else:
                    result = f.w.record_tts("known words", key=key, wait=0.1, before_release=before_release)
            except BaseException as caught:
                error = caught
        if f.state.get("preflight_busy") or late_refusal:
            require(error is not None and counts == {"down": 0, "up": 0} and not f.player)
            return
        should_error = bool(failure not in (None, "short") or second_failure or interrupt_thread or
                            f.state.get("launch_fail") or f.state.get("playback_fail"))
        if (error is not None) != should_error:
            raise AssertionError(f"legacy {kind}/{failure}: unexpected error outcome {error!r}")
        if should_error:
            expected_error = ("playback launch failed" if f.state.get("launch_fail") else
                "PTT playback failed" if f.state.get("playback_fail") else
                "before release failed" if failure == "before-release" else
                "native hold interrupted" if failure in ("engagement", "hold", "pulse") else
                "native " + ("down" if failure == "second-down" else failure or second_failure or "interruption") + " failed after acting")
            if interrupt_thread:
                require(isinstance(error, SystemExit) and error.code == 128 + f.signals.SIGTERM)
            else:
                require(expected_error in str(error))
            if second_failure:
                primary = callback_failure if failure == "before-release" else hold_failure if failure == "hold" else native_errors[failure or second_failure]
                require(error is primary)
                require(any(("join failed" if second_failure == "join" else "release failed" if kind == "input" else "recording did not stop" if f.state.get("cleanup_stop_noop") else "native up failed") in note
                            for note in getattr(error, "__notes__", [])))
        if interrupt_thread:
            require(counts == {"down": 0, "up": 0} and f.state["mode"] == "idle")
            require(any(e == ("thread", "join") for e in events) and
                    all(p.poll() is not None for p in f.player))
            return
        require(counts["down"] > 0 and counts["up"] >= counts["down"])
        require((f.state["mode"] == "recording" if f.state.get("cleanup_stop_noop") else f.state["mode"] == "idle")
                and all(p.poll() is not None for p in f.player))
        if f.state.get("cleanup_stop_noop"):
            require(not f.w._recording_cleanup_safe and any("Stop" in note or "recording" in note
                    for note in getattr(error, "__notes__", [])))
        if f.state.get("idle_gesture"):
            require(counts["down"] == 2 and not any(e[:2] == ("AX", "start") for e in events))
        if kind == "tts" and any(e == ("thread", "start") for e in events):
            require(any(e == ("thread", "join") for e in events))
        if failure == "short" or missing_marker is not None or f.state.get("missing_observation"):
            require(result is False)
        elif not should_error:
            require(result is True if kind != "tts" else result["success"] is True)
    for key in ("ropt", "space"):
        for failure in (None, "down", "engagement", "hold", "up"):
            case("legacy-ingress", f"PTT {key} cleans {failure or 'success'}", lambda f, key=key, failure=failure:
                 legacy_ingress(f, key=key, failure=failure))
        case("legacy-ingress", f"PTT {key} cleans playback spawn failure", lambda f, key=key:
             legacy_ingress(f, key=key), launch_fail=True)
    for failure in (None, "down", "second-down", "pulse", "short"):
        case("legacy-ingress", f"hands-free cleans {failure or 'success'}", lambda f, failure=failure:
             legacy_ingress(f, kind="hands-free", failure=failure))
    case("legacy-ingress", "missing hands-free observation never toggles idle", lambda f:
         legacy_ingress(f, kind="hands-free"), idle_gesture=True, missing_observation=True)
    for marker in ("Double press", "Hands-free mode activated", "Single press while locked"):
        case("legacy-ingress", "hands-free still requires " + marker, lambda f, marker=marker:
             legacy_ingress(f, kind="hands-free", missing_marker=marker))
    for failure in (None, "down", "before-release"):
        case("legacy-ingress", f"record_tts cleans {failure or 'success'}", lambda f, failure=failure:
             legacy_ingress(f, kind="tts", failure=failure))
    case("legacy-ingress", "record_tts propagates worker failure after join", lambda f:
         legacy_ingress(f, kind="tts"), playback_fail=True)
    def busy_legacy(f, kind):
        f.state.update(mode="recording", preflight_busy=True)
        legacy_ingress(f, kind=kind)
    for kind in ("ptt", "hands-free", "tts"):
        case("legacy-ingress", kind + " busy preflight dispatches no keys", lambda f, kind=kind: busy_legacy(f, kind))
    for key in ("ropt", "space"):
        for failure in ("down", "hold", "before-release"):
            case("legacy-ingress", f"input {key} preserves {failure} plus release error", lambda f, key=key, failure=failure:
                 legacy_ingress(f, kind="input", key=key, failure=failure, second_failure="up"))
    case("legacy-ingress", "record_tts preserves hold callback error plus join error", lambda f:
         legacy_ingress(f, kind="tts", failure="before-release", second_failure="join"))
    case("legacy-ingress", "cleanup-only release and Stop errors both survive", lambda f:
         legacy_ingress(f, second_failure="up"), cleanup_stop_noop=True, stop_noop=True)
    case("legacy-ingress", "late record_tts refusal sends no keys or worker", lambda f:
         legacy_ingress(f, kind="tts", late_refusal=True))
    case("legacy-ingress", "thread-start interruption still registers join and reaps", lambda f:
         legacy_ingress(f, kind="tts", interrupt_thread=True))
    case("signals", "interruption during acquisition", failed_recording, signal_acquire=True)
    case("signals", "repeated interruption during cleanup", failed_recording, hung=True, signal_cleanup=True)
    for name, options in [("unreadable", {"unreadable": True}), ("empty", {"empty": True}),
                          ("contradictory", {"contradictory": True}), ("disabled", {"disabled": True}),
                          ("replaced target", {"alive": False})]:
        def preflight(f):
            try: recording(f)
            except RuntimeError: pass
            else: raise AssertionError("invalid preflight accepted")
            require(not any(e[0] == "launch" or e[:2] == ("AX", "start") for e in f.events))
        case("state", name + " preflight refuses", preflight, **options)
    case("state", "localized exact recording item", lambda f: require(recording(f) is True), german=True)
    def round_trip(f):
        route = f.audio["AudioRoute"](); require(route.apply() is True)
        require(route.restore() is True and not route.applied)
        require(f.devices == f.originals and not os.path.exists(route.FILE))
    case("routes", "three choices round trip", round_trip)
    def combined_round_trip(f):
        route = f.audio["AudioRoute"](include_alerts=True)
        require(f.devices == f.originals)
        require(not any(event[0] == "switch" for event in f.events))
        require(route.original_app_device.uid == "")
        require(route.devices == f.originals)
        require(route.apply() is True)
        payload = json.loads(pathlib.Path(route.FILE).read_text())
        require(payload["kind"] == "audio-alert" and payload["devices"] == f.originals)
        require(all(device["uid"] == "BlackHole2ch_UID" for device in f.devices.values()))
        require(f.settings.input_uid == "BlackHole2ch_UID")
        index = len(f.events)
        require(route.restore() is True and not route.applied)
        require(f.devices == f.originals and f.settings.input_uid == "")
        require([event[:2] for event in f.events[index:] if event[0] == "switch"] ==
                [("switch", "output"), ("switch", "input"), ("switch", "system")])
        require(not os.path.exists(route.FILE))
    case("routes", "combined owner snapshots then restores all four choices once", combined_round_trip)
    def leased_recording(f):
        route = f.audio["AudioRoute"](include_alerts=True)
        route.apply()
        originals = json.loads(pathlib.Path(route.FILE).read_text())["devices"]
        require(recording(f) is True)
        after = json.loads(pathlib.Path(route.FILE).read_text())
        require(after["playback"] is None and after["devices"] == originals)
        require(route._player is None and all(process.poll() is not None for process in f.player))
        require(route.restore() is True and f.devices == f.originals)
    case("recording", "leased take reaps and clears its journal before restoration", leased_recording)
    def standalone_blocks_route(f):
        process = f.w._spawn_owned_playback(f.clip)
        index = len(f.events)
        try:
            f.audio["AudioRoute"]()
        except RuntimeError as error:
            require("cleanup remains unresolved" in str(error))
        else:
            raise AssertionError("an untracked live player admitted a new audio owner")
        require(not any(event[0] == "switch" for event in f.events[index:]))
        f.w._reap_playback(process, 0.2)
        route = f.audio["AudioRoute"]()
        require(route.apply() is True and route.restore() is True)
    case("recording", "standalone playback blocks routing until reaped", standalone_blocks_route)
    def actual_handoff(f, refused=False):
        route = f.audio["AudioRoute"](include_alerts=True); route.apply()
        before = pathlib.Path(route.FILE).read_bytes()
        new = guard.TargetIdentity(222, executable, (124, 456))
        token = pathlib.Path(f.clip).parent / "fault-token-222"
        token.write_bytes(b"a" * 64); token.chmod(0o600)
        phase, released = ("live", "false") if refused else ("idle", "true")
        f.state["query_reply"] = ("OK v=1 pid=222 parakeet_phase=" + phase + " parakeet_released=" + released +
            " whisperkit_phase=idle whisperkit_released=true backend=parakeet\n")
        index = len(f.events)
        with patch.object(guard, "running_enviouswispr_instances", return_value={"222": executable}), \
             patch.object(guard, "process_start", side_effect=lambda pid: new.start if pid == 222 else target.start), \
             patch.object(os, "kill", side_effect=ProcessLookupError()):
            try:
                route.transfer_after_verified_exit(new, guard.ExitProof(target, None))
            except RuntimeError:
                require(refused and pathlib.Path(route.FILE).read_bytes() == before and route.target == target and f.w._target == target)
            else:
                require(not refused and route.target == new and f.w._target == new)
                payload = json.loads(pathlib.Path(route.FILE).read_text())
                require(payload["devices"] == f.originals and payload["target"] == f.audio["_target_json"](new))
                require(payload["lineage"] == [{"old": f.audio["_target_json"](target),
                    "new": f.audio["_target_json"](new), "replacement_start": None}])
        require(not any(event[0] == "switch" for event in f.events[index:]))
        f.audio["_release_record_lock"](route._lock); route._lock = None
    case("handoff", "actual owner journals verified replacement without changing originals", actual_handoff)
    case("handoff", "actual owner refuses unreleased replacement without journal changes", lambda f: actual_handoff(f, refused=True))
    def overlapping_owner(f, first_kind):
        first = f.audio[first_kind](); first.apply()
        second_kind = "AlertSink" if first_kind == "AudioRoute" else "AudioRoute"
        second = f.audio[second_kind]()
        index = len(f.events)
        try:
            second.apply()
        except BlockingIOError:
            pass
        else:
            raise AssertionError("overlapping output owner was admitted")
        require(not any(event[0] == "switch" for event in f.events[index:]))
        require(first.restore() is True and f.devices == f.originals)
    case("publication", "audio owner excludes independent alert owner", lambda f: overlapping_owner(f, "AudioRoute"))
    case("publication", "alert owner excludes independent audio owner", lambda f: overlapping_owner(f, "AlertSink"))
    def conflicting_records(f):
        route = f.audio["AudioRoute"]()
        paths = (pathlib.Path(route.FILE), pathlib.Path(f.audio["AlertSink"].FILE))
        for path in paths:
            path.write_bytes(b"legacy conflicting recovery")
        before = [path.read_bytes() for path in paths]
        index = len(f.events)
        try:
            f.audio["_replay_recovery"](route.FILE)
        except RuntimeError as error:
            require("conflicting audio recovery records" in str(error))
        else:
            raise AssertionError("conflicting originals were guessed")
        require([path.read_bytes() for path in paths] == before)
        require(not any(event[0] == "switch" for event in f.events[index:]))
    case("recovery", "conflicting original snapshots retain both records", conflicting_records)
    def retry(f):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); f.state["restore_fail"] = True
        try: route.restore()
        except RuntimeError: pass
        else: raise AssertionError("unlanded restore accepted")
        require(route.applied and pathlib.Path(route.FILE).read_bytes() == before)
        f.state["restore_fail"] = False; require(route.restore() is True)
    case("routes", "partial restore remains retryable", retry)
    def second_restore_failure(f):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); f.state["restore_fail_kind"] = "input"
        try: route.restore()
        except RuntimeError as error: require("did not land" in str(error))
        else: raise AssertionError("second failed system restore was accepted")
        require(f.devices["output"] == f.originals["output"] and route.applied)
        require(pathlib.Path(route.FILE).read_bytes() == before)
        f.state["restore_fail_kind"] = None; require(route.restore() is True)
    case("routes", "second system restore failure retains completed first choice", second_restore_failure)
    def app_failure(f, option):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); f.state[option] = True
        try: route.restore()
        except RuntimeError as error:
            require("after acting" in str(error) if option == "app_raise" else "stored choice" in str(error))
        else: raise AssertionError("failed app microphone restore was accepted")
        require(route.applied and pathlib.Path(route.FILE).read_bytes() == before)
        require(f.settings.input_uid == ("" if option == "app_raise" else "BlackHole2ch_UID"))
        f.state[option] = False; require(route.restore() is True)
    case("microphone", "app selection acts then raises and remains retryable", lambda f: app_failure(f, "app_raise"))
    case("microphone", "app selection no-op fails actual UID verification", lambda f: app_failure(f, "app_noop"))
    def microphone_transition(f, option):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); f.state[option] = True
        if option == "recording_during_navigation":
            f.settings.remembered_tab = "Engine"
        index = len(f.events)
        try: route.restore()
        except RuntimeError as error: require("positively released capture" in str(error))
        else: raise AssertionError("microphone selected after capture began in preparation")
        require(f.settings.input_uid == "BlackHole2ch_UID" and route.applied)
        require(pathlib.Path(route.FILE).read_bytes() == before)
        require(not any(e[0] == "selection" and e[1] == "Auto" for e in f.events[index:]))
    case("microphone", "recording during actual navigation refuses selection", lambda f: microphone_transition(f, "recording_during_navigation"))
    case("microphone", "recording during picker preparation refuses selection", lambda f: microphone_transition(f, "recording_during_picker"))
    def new_recording(f):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); index = len(f.events)
        f.state["new_recording_after_output"] = True
        try: route.restore()
        except RuntimeError as error: require("positive non-recording" in str(error))
        else: raise AssertionError("physical microphone reconnected during new capture")
        switches = [e for e in f.events[index:] if e[0] == "switch"]
        require(switches == [("switch", "output", "physical-o")])
        require(route.applied and pathlib.Path(route.FILE).read_bytes() == before)
    case("routes", "new recording blocks later microphone restore", new_recording)
    def resolution_transition(f):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); index = len(f.events)
        f.state["new_recording_during_resolution"] = True
        f.state["resolution_anchor"] = index
        try: route.restore()
        except RuntimeError as error: require("positive non-recording" in str(error))
        else: raise AssertionError("recording during device resolution allowed a physical switch")
        require(not any(e[0] == "switch" for e in f.events[index:]))
        require(route.applied and pathlib.Path(route.FILE).read_bytes() == before)
    case("routes", "device resolution transition blocks final switch", resolution_transition)
    def primary_cancel(f):
        try: recording(f)
        except RuntimeError as error:
            require(str(error) == "Start failed after acting")
            require(any("menu cancel failed" in note for note in error.__notes__))
            require(f.state["mode"] == "idle" and f.w._recording_cleanup_safe)
        else: raise AssertionError("original Start failure did not escape")
    case("errors", "Start error survives menu cancellation error", primary_cancel, start_raise=True, cancel_raise=True)
    def read_cancel(f):
        try: recording(f)
        except RuntimeError as error:
            require("attribute AXTitle is unreadable" in str(error))
            require(any("menu cancel failed" in note for note in error.__notes__))
        else: raise AssertionError("original read error did not escape")
        require(not any(e[0] == "launch" or e[:2] == ("AX", "start") for e in f.events))
    case("errors", "read error survives menu cancellation error", read_cancel,
         title_error=True, cancel_raise=True, cancel_any=True)
    def cancel_only(f):
        try: recording(f)
        except RuntimeError as error: require(str(error) == "menu cancel failed")
        else: raise AssertionError("cancellation failure was swallowed")
        require(not any(e[0] == "launch" or e[:2] == ("AX", "start") for e in f.events))
    case("errors", "standalone menu cancellation error escapes", cancel_only, cancel_raise=True, cancel_any=True)
    def replay(f):
        route = f.audio["AudioRoute"](); route.apply()
        f.audio["_release_record_lock"](route._lock); route._lock = None
        f.state["mode"] = "recording"
        require(f.audio["_replay_recovery"](route.FILE) is True)
        stop = next(i for i, e in enumerate(f.events) if e[:2] == ("AX", "stop"))
        physical = [i for i, e in enumerate(f.events) if e[0] == "switch" and e[2].startswith("physical")]
        require(physical and all(i > stop for i in physical))
    case("recovery", "active capture stops before replay", replay)
    def cli(f, expected):
        tree = ast.parse((root / "silent_audio.py").read_text())
        entry = tree.body[-1]
        require(isinstance(entry, ast.If))
        def exit_(code): raise SystemExit(code)
        original = {k: f.audio.get(k) for k in ("__name__", "sys")}
        f.audio.update({"__name__": "__main__", "sys": types.SimpleNamespace(
            argv=["silent_audio.py", "restore"], stderr=io.StringIO(), exit=exit_)})
        try:
            exec(compile(ast.Module(body=[entry], type_ignores=[]), "silent_audio.py CLI", "exec"), f.audio)
        except SystemExit as error:
            require(error.code == expected)
        else:
            raise AssertionError("CLI did not report a terminal exit")
        finally:
            f.audio.update(original)
    def cli_recording(f):
        route = f.audio["AudioRoute"](); route.apply()
        f.audio["_release_record_lock"](route._lock); route._lock = None
        f.state["mode"] = "recording"
        cli(f, 0)
        require(f.state["mode"] == "idle" and f.devices == f.originals and not os.path.exists(route.FILE))
    case("recovery", "CLI entry-block fixture stops capture and restores", cli_recording)
    def cli_unknown(f):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes()
        f.audio["_release_record_lock"](route._lock); route._lock = None
        f.state["query_timeout"] = True; index = len(f.events)
        cli(f, 1)
        require(pathlib.Path(route.FILE).read_bytes() == before and not any(e[0] == "switch" for e in f.events[index:]))
    case("recovery", "CLI entry-block fixture refuses unknown state", cli_unknown)
    def publication(f):
        path = str(pathlib.Path(f.clip).with_name("publication.json"))
        barrier = threading.Barrier(8)
        published, observed = threading.Event(), threading.Event()
        real_link = os.link
        observations = []
        def link(source, destination):
            barrier.wait(timeout=5)
            real_link(source, destination)
            published.set()
            require(observed.wait(timeout=5))
        def reader():
            require(published.wait(timeout=5))
            try:
                observations.append(json.loads(pathlib.Path(path).read_bytes()))
            finally:
                observed.set()
        def publish(n):
            try: return f.audio["_publish_recovery"](path, {"winner": n, "complete": "x" * 4096})
            except FileExistsError: return None
        with patch.object(os, "link", side_effect=link), concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
            reading = pool.submit(reader)
            results = list(pool.map(publish, range(8)))
            reading.result(timeout=5)
        require(sum(result is not None for result in results) == 1)
        data = json.loads(pathlib.Path(path).read_bytes()); require(type(data["winner"]) is int)
        require(observations == [data] and data["complete"] == "x" * 4096)
        require(stat.S_IMODE(os.stat(path).st_mode) == 0o600)
    case("publication", "exclusive concurrent complete winner", publication)
    def bad_audio(f):
        for path in [f.clip + "-missing", str(pathlib.Path(f.clip).with_name("invalid.wav"))]:
            if not path.endswith("-missing"):
                pathlib.Path(path).write_bytes(b"invalid audio")
            try: f.w.test_recording(audio=path, expect="known")
            except RuntimeError: pass
            else: raise AssertionError("unreadable/unknown-duration audio accepted")
        require(not any(e[0] == "launch" or e[:2] == ("AX", "start") for e in f.events))
    case("audio", "unknown duration and missing file refuse", bad_audio)
    case("audio", "intentional silence probe", lambda f: require(
        f.w.test_recording(sentence=" ", expect="known", hold=0.1, timeout=0.2) is True))
    def unsafe_stop(f):
        try: recording(f)
        except RuntimeError as error: require("did not stop" in str(error))
        else: raise AssertionError("Stop without idle accepted")
        require(f.state["mode"] == "recording" and not f.w._recording_cleanup_safe)
    case("recording", "Stop true without idle stays unsafe", unsafe_stop, stop_noop=True)
    def unreaped(f):
        route = f.audio["AudioRoute"](); route.apply()
        try: recording(f)
        except RuntimeError as error: require("audio playback exceeded" in str(error))
        else: raise AssertionError("unreaped player accepted")
        require(not f.w._recording_cleanup_safe and f.player[0].poll() is None)
        require(("terminate",) in f.events and ("kill",) in f.events)
        before = pathlib.Path(route.FILE).read_bytes(); index = len(f.events)
        try: route.restore()
        except RuntimeError: pass
        else: raise AssertionError("restore after failed reap accepted")
        require(pathlib.Path(route.FILE).read_bytes() == before and route.applied)
        require(not any(e[0] == "switch" for e in f.events[index:]))
    case("recording", "failed reap forbids restoration", unreaped, unreapable=True)
    def existing(f):
        route = f.audio["AudioRoute"](); pathlib.Path(route.FILE).write_bytes(b"previous recovery")
        try: route.apply()
        except FileExistsError: pass
        else: raise AssertionError("existing recovery was overwritten")
        require(pathlib.Path(route.FILE).read_bytes() == b"previous recovery")
        require(not any(e[0] == "switch" for e in f.events))
    case("publication", "existing record refuses before switches", existing)
    def active_publisher(f):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes(); index = len(f.events)
        try: f.audio["_replay_recovery"](route.FILE)
        except BlockingIOError: pass
        else: raise AssertionError("replay raced an active publisher")
        require(pathlib.Path(route.FILE).read_bytes() == before and len(f.events) == index)
        require(route.restore() is True)
    case("publication", "active owner excludes replay", active_publisher)
    def blocked_replay(f, option):
        route = f.audio["AudioRoute"](); route.apply()
        before = pathlib.Path(route.FILE).read_bytes()
        f.audio["_release_record_lock"](route._lock); route._lock = None
        f.state[option] = False if option == "alive" else True
        index = len(f.events)
        try: f.audio["_replay_recovery"](route.FILE)
        except RuntimeError: pass
        else: raise AssertionError("unsafe recovery accepted")
        require(pathlib.Path(route.FILE).read_bytes() == before)
        require(not any(e[0] == "switch" for e in f.events[index:]))
    case("recovery", "unknown state retains record", lambda f: blocked_replay(f, "query_timeout"))
    case("recovery", "changed target retains record", lambda f: blocked_replay(f, "alive"))
    def stale_owner(f):
        route = f.audio["AudioRoute"](); route.apply()
        pathlib.Path(route.FILE).write_bytes(b"changed owner record"); index = len(f.events)
        try: route.restore()
        except RuntimeError: pass
        else: raise AssertionError("changed recovery ownership accepted")
        require(pathlib.Path(route.FILE).read_bytes() == b"changed owner record")
        require(not any(e[0] == "switch" for e in f.events[index:]))
    case("recovery", "changed record is neither restored nor removed", stale_owner)
    def malformed_recovery(f):
        path = f.audio["AudioRoute"].FILE
        pathlib.Path(path).write_text(json.dumps({"output": "old legacy device"}))
        before = pathlib.Path(path).read_bytes()
        cli(f, 1)
        require(pathlib.Path(path).read_bytes() == before and not any(e[0] == "switch" for e in f.events))
    case("recovery", "legacy recovery refuses without identity", malformed_recovery)
    def alert(f):
        sink = f.audio["AlertSink"](); require(sink.apply() is True)
        require(sink.restore() is True and f.devices == f.originals)
    case("routes", "alert sink uses safe round trip", alert)
    def interrupted_apply(f):
        route = f.audio["AudioRoute"](); route.install_restore_handlers()
        try: route.apply()
        except SystemExit as error: require(error.code == 128 + f.signals.SIGTERM)
        else: raise AssertionError("interruption reported success")
        require(f.devices == f.originals and not route.applied and not os.path.exists(route.FILE))
        require(not f.signals.mask and not f.signals.pending)
    case("signals", "partial application unwinds safely", interrupted_apply, signal_apply=True)
    def interrupted_restore(f):
        route = f.audio["AudioRoute"](); route.install_restore_handlers(); route.apply()
        f.state["signal_restore"] = True
        try: route.restore()
        except SystemExit as error: require(error.code == 128 + f.signals.SIGTERM)
        else: raise AssertionError("pending interruption reported success")
        require(f.devices == f.originals and not route.applied and not os.path.exists(route.FILE))
        require(not f.signals.mask and not f.signals.pending)
    case("signals", "restore finishes before pending interruption", interrupted_restore)
    def failed_apply(f, option):
        f.state[option] = True
        try: f.audio["AudioRoute"]().apply()
        except RuntimeError: pass
        else: raise AssertionError("invalid routing accepted")
        require(not any(e[0] == "switch" for e in f.events))
    case("routes", "unreadable route refuses", lambda f: failed_apply(f, "route_unreadable"))
    case("routes", "ambiguous silent device refuses", lambda f: failed_apply(f, "duplicate"))
    def native_playback_lock(f, no_go=False, parent_death=False, death_stage="after-go", fail_at=None):
        import time as native_time
        directory = pathlib.Path(f.clip).parent
        player_path = directory / "fixture-player"
        ack_path, release_path = directory / "exec-ack", directory / "player-release"
        os.mkfifo(ack_path); os.mkfifo(release_path)
        ack_fd = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        release_fd = os.open(release_path, os.O_RDWR | os.O_NONBLOCK)
        player_path.write_text("#!" + sys.executable + "\n" +
            "import json,os,sys\n" +
            "with open(sys.argv[1]) as f: paths=json.load(f)\n" +
            "with open(paths['ack'],'wb',buffering=0) as f: f.write(b'EXEC\\n')\n" +
            "with open(paths['release'],'rb',buffering=0) as f: f.read(1)\n")
        player_path.chmod(0o700)
        clip = directory / "native-descriptor.json"
        clip.write_text(json.dumps({"ack": str(ack_path), "release": str(release_path)}))
        source = (root / "silent_audio.py").read_text()
        require(source.count('"/usr/bin/afplay"') == 3)
        copied = directory / "private-native-audio.py"
        copied.write_text(source.replace('"/usr/bin/afplay"', json.dumps(str(player_path))))
        subject = dict(f.audio)
        subject.update(subprocess=subprocess, time=native_time,
                       RESTORE_FILE=str(directory / "native-restore.json"))
        tree = ast.parse(copied.read_text())
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                if node.targets[0].id in {"_PLAYER", "_CHILD"}:
                    subject[node.targets[0].id] = ast.literal_eval(node.value)
        names = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
        compile_functions(copied, names, subject)
        owner = types.ModuleType("native_playback_subject")
        owner.__dict__.update(contextlib=contextlib, signal=signal_api, subprocess=subprocess,
                              sys=sys, _standalone_player=None, _recording_cleanup_safe=True)
        compile_functions(root / "wispr_eyes.py", {"_defer_recording_signals", "_reap_playback"}, owner.__dict__)
        subject["w"] = owner
        alias = types.ModuleType("silent_audio")
        alias.__dict__.update(subject)
        route = types.SimpleNamespace(FILE=subject["RESTORE_FILE"], applied=False, _owned=None,
            _payload={"version": 2, "kind": "audio-alert", "target": subject["_target_json"](target),
                      "devices": copy.deepcopy(f.originals), "app_device": f.w.read_input_choice().to_json()})
        process = None
        harness = None
        gate_r = gate_w = ready_r = ready_w = None
        try:
            if parent_death:
                # Native identity is real; the app/OS-device boundaries below are private fixtures.
                route._payload["target"] = {"pid": os.getpid(), "executable": executable,
                                           "start": list(native_process_start(os.getpid()))}
                config = directory / "process-config.json"
                config.write_text(json.dumps({"copy": str(copied), "root": str(root),
                    "record": subject["RESTORE_FILE"], "clip": str(clip), "payload": route._payload,
                    "wispr": str(root / "wispr_eyes.py"), "death_stage": death_stage}))
                program = directory / "journal-process.py"
                program.write_text('''import ast,contextlib,copy,fcntl,hashlib,json,os,select,signal,stat,subprocess,sys,tempfile,threading,time,types,uuid
cfg=json.load(open(sys.argv[1]))
sys.path.insert(0,cfg["root"])
from instance_guard import process_start,prove_target_exited,TargetIdentity
scope=dict(globals(),HERE=cfg["root"],RESTORE_FILE=cfg["record"])
tree=ast.parse(open(cfg["copy"]).read())
for n in tree.body:
    if isinstance(n,ast.Assign) and len(n.targets)==1 and isinstance(n.targets[0],ast.Name) and n.targets[0].id in {"_PLAYER","_CHILD"}:
        scope[n.targets[0].id]=ast.literal_eval(n.value)
nodes=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef))]
exec(compile(ast.Module(body=nodes,type_ignores=[]),cfg["copy"],"exec"),scope)
def reap(p,timeout):
    if p is None:return
    if p.poll() is None:p.terminate()
    try:p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:p.kill();p.communicate(timeout=timeout)
scope["w"]=types.SimpleNamespace(_reap_playback=reap)
if sys.argv[2]=="owner":
    r=types.SimpleNamespace(FILE=cfg["record"],_payload=cfg["payload"],applied=False,_owned=None)
    r._lock=scope["_record_lock"](r.FILE)
    scope["_init_playback_journal"](r)
    r._owned=scope["_publish_recovery"](r.FILE,r._payload);r.applied=True
    actual_set=scope["_set_playback"]
    actual_verify=scope["_verify_blocked_child"]
    def checkpoint(child,start=None):
        print(json.dumps({"child":child,"start":start,"harness":os.getpid()}),flush=True)
        sys.stdin.read()
    def observed_set(route,lease):
        actual_set(route,lease)
        if lease is not None and ((cfg["death_stage"]=="intent" and lease["stage"]=="intent") or (cfg["death_stage"]=="committed" and lease["stage"]=="committed")):
            checkpoint(lease.get("pid"),lease.get("start"))
    def observed_verify(pid,start):
        actual_verify(pid,start)
        if cfg["death_stage"]=="verified":checkpoint(pid,start)
    scope["_set_playback"]=observed_set
    scope["_verify_blocked_child"]=observed_verify
    child=scope["_spawn_playback"](r,cfg["clip"])
    print(json.dumps({"child":child.pid,"harness":os.getpid()}),flush=True)
    sys.stdin.read()
elif sys.argv[2]=="recover":
    owned=scope["_record_bytes"](cfg["record"])
    payload=json.loads(owned[1])
    originals=copy.deepcopy(payload["devices"])
    scope["_stop_orphan_playback"](payload)
    assert scope["_record_bytes"](cfg["record"])==owned
    fd=scope["_record_lock"](cfg["record"])
    try:
        assert not scope["_player_running"](payload["playback"])
        payload["playback"]=None
        scope["_replace_record"](cfg["record"],owned,payload)
        assert json.load(open(cfg["record"]))["devices"]==originals
        print("RECOVERED",flush=True)
    finally:scope["_release_record_lock"](fd)
else:
    import instance_guard as identity
    import settings_nav
    original=cfg["payload"]["devices"]
    devices={kind:dict(value,uid="virtual",id="59",name="Virtual") for kind,value in original.items()}
    app_choice=settings_nav.InputChoice.from_json(cfg["payload"]["app_device"])
    expected=cfg["payload"]["target"]
    identity.running_enviouswispr_instances=lambda:{str(expected["pid"]):expected["executable"]}
    w=types.ModuleType("private_restore_boundary")
    w.__dict__.update(contextlib=contextlib,signal=signal,subprocess=subprocess,time=time,sys=sys,
                     _recording_cleanup_safe=True,_standalone_player=None,_target=None,_sn=settings_nav)
    def connect(expected_pid,expected_executable):
        w._target=identity.pin_target(expected_pid,expected_executable)
    w.connect=connect
    w._capture_snapshot=lambda target,timeout=5.0:{"parakeet_phase":"idle","parakeet_released":"true","whisperkit_phase":"idle","whisperkit_released":"true"}
    def no_action(*args):raise AssertionError("idle fixture must not dispatch recording")
    w._recording_control=no_action
    wt=ast.parse(open(cfg["wispr"]).read())
    names={"_defer_recording_signals","_recording_state","_stop_recording"}
    wn=[n for n in wt.body if isinstance(n,ast.FunctionDef) and n.name in names]
    assert {n.name for n in wn}==names
    exec(compile(ast.Module(body=wn,type_ignores=[]),cfg["wispr"],"exec"),w.__dict__)
    w.read_input_choice=lambda:app_choice
    def restore_choice(choice):
        global app_choice
        app_choice=choice
    w.restore_input_choice=restore_choice
    def device_boundary(command,**kwargs):
        kind=command[command.index("-t")+1]
        if "-a" in command:rows=[original[kind],dict(original[kind],uid="virtual",id="59",name="Virtual")]
        elif "-c" in command:rows=[devices[kind]]
        else:
            assert "-i" in command and command[command.index("-i")+1]==original[kind]["id"]
            devices[kind]=dict(original[kind]);rows=[]
        return types.SimpleNamespace(returncode=0,stdout="\\n".join(json.dumps(r) for r in rows),stderr="")
    real_run=subprocess.run
    def run_boundary(command,**kwargs):
        return device_boundary(command,**kwargs) if command[0]=="fixture-switch" else real_run(command,**kwargs)
    scope["subprocess"]=types.SimpleNamespace(run=run_boundary)
    scope["SWITCH"]="fixture-switch"
    scope["w"]=w
    scope["AlertSink"].FILE=cfg["record"]+".alerts"
    assert scope["_replay_recovery"](cfg["record"]) is True
    assert devices==original and app_choice.same_choice(settings_nav.InputChoice.from_json(cfg["payload"]["app_device"]))
    assert not os.path.exists(cfg["record"])
    print("RESTORED",flush=True)
''')
                harness = subprocess.Popen([sys.executable, str(program), str(config), "owner"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if not select.select([harness.stdout], [], [], 5.0)[0]:
                    raise AssertionError("native owner did not announce its committed child")
                announced = json.loads(harness.stdout.readline())
                require(announced["harness"] == harness.pid)
                def forced_failure(stage):
                    if fail_at == stage:
                        payload = json.loads(pathlib.Path(subject["RESTORE_FILE"]).read_text())
                        error = AssertionError("forced private fixture interruption at " + stage)
                        error.owned_child = guard.TargetIdentity(announced["child"], str(player_path),
                            tuple(announced.get("start") or payload["playback"]["start"]))
                        error.owned_lock = route.FILE
                        raise error
                forced_failure("announcement")
                if death_stage == "after-go":
                    if not select.select([ack_fd], [], [], 5.0)[0]:
                        raise AssertionError("native child did not announce exec")
                    require(os.read(ack_fd, 5) == b"EXEC\n")
                forced_failure("exec")
                before = pathlib.Path(subject["RESTORE_FILE"]).read_bytes()
                with patch.object(guard, "process_start", new=native_process_start):
                    lease = json.loads(before)["playback"]
                    child_identity = (guard.TargetIdentity(announced["child"], str(player_path),
                                      tuple(announced.get("start") or lease["start"]))
                                      if announced["child"] is not None else None)
                harness.kill(); _, errors = harness.communicate(timeout=5.0)
                if harness.returncode != -signal_api.SIGKILL or errors:
                    raise AssertionError(f"native owner kill: exit={harness.returncode}, stderr={errors!r}")
                require(pathlib.Path(subject["RESTORE_FILE"]).read_bytes() == before)
                forced_failure("death")
                if death_stage == "after-go":
                    recovery = subprocess.run([sys.executable, str(program), str(config), "recover"],
                        capture_output=True, text=True, timeout=65.0)
                    if recovery.returncode != 0 or recovery.stdout.strip() != "RECOVERED" or recovery.stderr:
                        raise AssertionError(f"fresh recovery: exit={recovery.returncode}, stdout={recovery.stdout!r}, stderr={recovery.stderr!r}")
                if child_identity is not None:
                    deadline = native_time.monotonic() + 5.0
                    with patch.object(guard, "process_start", new=native_process_start):
                        while True:
                            try:
                                guard.prove_target_exited(child_identity)
                                break
                            except guard.InstanceGuardError:
                                if native_time.monotonic() >= deadline:
                                    raise AssertionError("owned pre-GO child did not exit after parent death")
                                native_time.sleep(0.01)  # deadline-fallback: native child exit proof.
                if death_stage != "after-go":
                    require(not select.select([ack_fd], [], [], 0)[0])
                restored = subprocess.run([sys.executable, str(program), str(config), "restore"],
                    capture_output=True, text=True, timeout=35.0)
                if restored.returncode != 0 or restored.stdout.strip() != "RESTORED" or restored.stderr:
                    raise AssertionError(f"fresh restore: exit={restored.returncode}, stdout={restored.stdout!r}, stderr={restored.stderr!r}")
                require(not pathlib.Path(subject["RESTORE_FILE"]).exists())
                return
            with patch.object(guard, "process_start", new=native_process_start), \
                 patch.dict(sys.modules, {"silent_audio": alias}):
                route._lock = subject["_record_lock"](route.FILE)
                subject["_init_playback_journal"](route)
                route._owned = subject["_publish_recovery"](route.FILE, route._payload)
                route.applied = True
                if no_go:
                    gate_r, gate_w = os.pipe()
                    ready_r, ready_w = os.pipe()
                    process = subprocess.Popen([sys.executable, "-c", subject["_CHILD"], str(root),
                        str(route._lock), str(gate_r), str(ready_w), str(clip)],
                        pass_fds=(route._lock, gate_r, ready_w),
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    os.close(gate_r); gate_r = None
                    os.close(ready_w); ready_w = None
                    identity = subject["_ready_identity"](ready_r, native_time.monotonic() + 5.0)
                    require(identity["pid"] == process.pid and tuple(identity["start"]) == native_process_start(process.pid))
                    os.close(gate_w); gate_w = None
                    _, errors = process.communicate(timeout=5.0)
                    require(process.returncode == 125 and not errors)
                    require(not select.select([ack_fd], [], [], 0)[0])
                    return
                with owner._defer_recording_signals():
                    process = subject["_spawn_playback"](route, str(clip))
                require(select.select([ack_fd], [], [], 5.0)[0])
                require(os.read(ack_fd, 5) == b"EXEC\n")
                lease = json.loads(pathlib.Path(route.FILE).read_text())["playback"]
                require(lease["stage"] == "committed" and lease["pid"] == process.pid)
                require(tuple(lease["start"]) == native_process_start(process.pid))
                subject["_release_record_lock"](route._lock); route._lock = None
                try:
                    unexpected = subject["_record_lock"](route.FILE)
                except BlockingIOError:
                    pass
                else:
                    subject["_release_record_lock"](unexpected)
                    raise AssertionError("exec child lost the lock after parent close")
                require(os.write(release_fd, b"x") == 1)
                _, errors = process.communicate(timeout=5.0)
                require(process.returncode == 0 and not errors)
                route._lock = subject["_record_lock"](route.FILE)
                subject["_complete_playback"](route, process)
                require(json.loads(pathlib.Path(route.FILE).read_text())["playback"] is None)
        finally:
            primary = sys.exc_info()[1]
            cleanup_errors = []
            def clean(action):
                try:
                    action()
                except BaseException as error:
                    cleanup_errors.append(error)
            def reap_private(child):
                if child is not None:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=5.0)
            clean(lambda: reap_private(harness))
            # Only the private fixture FIFO is released; pre-GO children exit on EOF.
            clean(lambda: os.write(release_fd, b"x"))
            clean(lambda: reap_private(process))
            clean(lambda: subject["_release_record_lock"](getattr(route, "_lock", None)))
            route._lock = None
            for fd in (gate_r, gate_w, ready_r, ready_w):
                if fd is not None:
                    clean(lambda fd=fd: os.close(fd))
            def await_private_child_release():
                deadline = native_time.monotonic() + 5.0
                while True:
                    try:
                        fd = subject["_record_lock"](route.FILE)
                    except BlockingIOError:
                        if native_time.monotonic() >= deadline:
                            raise AssertionError("private child retained its lock after cleanup")
                        native_time.sleep(0.01)  # deadline-fallback: observe owned lock release.
                    else:
                        subject["_release_record_lock"](fd)
                        return
            clean(await_private_child_release)
            clean(lambda: os.close(ack_fd))
            clean(lambda: os.close(release_fd))
            if cleanup_errors:
                if primary is None:
                    primary = cleanup_errors[0]
                    for error in cleanup_errors[1:]:
                        primary.add_note(f"private child cleanup: {error!r}")
                    raise primary
                for error in cleanup_errors:
                    primary.add_note(f"private child cleanup: {error!r}")
    case("native-playback", "real exec child retains exclusion after parent close", native_playback_lock, native_macos=True)
    case("native-playback", "real child refuses playback after GO pipe closes", lambda f: native_playback_lock(f, no_go=True), native_macos=True)
    case("native-playback", "fresh process reaps committed playback after real harness death", lambda f: native_playback_lock(f, parent_death=True), native_macos=True)
    for stage in ("intent", "verified", "committed"):
        case("native-playback", "real harness death before GO at " + stage,
             lambda f, stage=stage: native_playback_lock(f, parent_death=True, death_stage=stage), native_macos=True)
    def interrupted_native_fixture(f, stage):
        import time as native_time
        try:
            native_playback_lock(f, parent_death=True, fail_at=stage)
        except AssertionError as error:
            require(str(error) == "forced private fixture interruption at " + stage)
            require(not getattr(error, "__notes__", []))
            deadline = native_time.monotonic() + 5.0
            with patch.object(guard, "process_start", new=native_process_start):
                while True:
                    try:
                        guard.prove_target_exited(error.owned_child)
                        break
                    except guard.InstanceGuardError:
                        if native_time.monotonic() >= deadline:
                            raise AssertionError("failed native fixture leaked its owned player")
                        native_time.sleep(0.01)  # deadline-fallback: observe real child exit.
            fd = f.audio["_record_lock"](error.owned_lock)
            f.audio["_release_record_lock"](fd)
        else:
            raise AssertionError("native fixture did not execute the injected failure")
    for stage in ("announcement", "exec", "death"):
        case("native-playback", "failed fixture reaps orphan after " + stage,
             lambda f, stage=stage: interrupted_native_fixture(f, stage), native_macos=True)

    def native_mask(f):
        owner = {"contextlib": contextlib, "signal": signal_api, "subprocess": subprocess,
                 "_standalone_player": None, "_recording_cleanup_safe": True}
        compile_functions(root / "wispr_eyes.py", {"_defer_recording_signals", "_reap_playback"}, owner)
        before = signal_api.pthread_sigmask(signal_api.SIG_BLOCK, set())
        previous = {sig: signal_api.getsignal(sig) for sig in (signal_api.SIGINT, signal_api.SIGTERM, signal_api.SIGHUP)}
        process = None
        try:
            with owner["_defer_recording_signals"]():
                process = subprocess.Popen([sys.executable, "-c",
                    "import signal,json; print(json.dumps(sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK,set()))))"],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                out, err = process.communicate(timeout=5)
                require(process.returncode == 0 and not err and set(json.loads(out)) == {int(s) for s in before})
        finally:
            with owner["_defer_recording_signals"]():
                owner["_reap_playback"](process, 5)
        require(signal_api.pthread_sigmask(signal_api.SIG_BLOCK, set()) == before)
        require(all(signal_api.getsignal(sig) == handler for sig, handler in previous.items()))
    case("signals", "real spawned process retains caller signal mask", native_mask)
    case("query", "fragmented complete reply is accepted", lambda f: require(f.w._recording_state(target) == "idle"), fragment_reply=True)
    case("query", "idle without released resources is stopping", lambda f: require(f.w._recording_state(target) == "stopping"), released=False)
    case("query", "released delivery is non-capturing", lambda f: require(f.w._recording_state(target) == "idle"), raw_phase="delivering", released=True)
    case("query", "either driver's live phase prohibits idle", lambda f: require(f.w._recording_state(target) == "recording"), other_phase="live", other_released=False)
    valid_reply = "OK v=1 pid=111 parakeet_phase=idle parakeet_released=true whisperkit_phase=idle whisperkit_released=true backend=parakeet\n"
    def refuse_query(f):
        try: f.w._recording_state(target)
        except (RuntimeError, OSError): return
        raise AssertionError("invalid capture query accepted")
    for name, reply in [
        ("missing newline", valid_reply.rstrip("\n")), ("premature EOF", ""),
        ("authentication failure", "ERR auth\n"), ("duplicate field", valid_reply.replace("v=1", "v=1 v=1")),
        ("wrong PID", valid_reply.replace("pid=111", "pid=222")), ("wrong version", valid_reply.replace("v=1", "v=2")),
        ("missing field", valid_reply.replace("whisperkit_released=true ", "")),
        ("unknown phase", valid_reply.replace("parakeet_phase=idle", "parakeet_phase=unknown")),
        ("unknown backend", valid_reply.replace("backend=parakeet", "backend=other")),
        ("invalid Boolean", valid_reply.replace("parakeet_released=true", "parakeet_released=1")),
        ("extra reply", valid_reply + valid_reply), ("oversized reply", "x" * 513),
    ]:
        case("query", name + " refuses", refuse_query, query_reply=reply)
    case("query", "timeout refuses", refuse_query, query_timeout=True)
    case("query", "changed launch token refuses", refuse_query, change_token=True)
    case("query", "changed native identity refuses", refuse_query, change_identity=True)
    case("query", "unreleased delivery is contradictory", refuse_query, raw_phase="delivering", released=False)
    case("query", "Stop waits through stopping and released delivery", lambda f: require(
        f.w._stop_recording(target, 0.2) is True), query_sequence=[("stopping", False), ("delivering", True)])
    def arming_cleanup(f):
        require(f.w._stop_recording(target, 0.2) is True)
        require(sum(event[:2] == ("AX", "stop") for event in f.events) == 1)
        require(f.state["mode"] == "idle")
    case("query", "arming cleanup waits for a drivable Stop then confirms release", arming_cleanup,
         mode="arming", query_sequence=[("arming", True), ("live", False)])
    for failure in failures: print("FAIL " + failure)
    for family, name, reason in skipped: print(f"SKIP {family}/{name}: {reason}")
    print("lifecycle families: " + json.dumps(dict(collections.Counter(family for family, _ in ran)), sort_keys=True))
    print(f"lifecycle controls: {len(ran)} cases, {len(failures)} failures")
    if skipped: print(f"lifecycle controls: {len(skipped)} platform cases skipped, not passed")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--lifecycle-self-test" in sys.argv:
        sys.exit(_lifecycle_self_test())
    if "--identity-self-test" in sys.argv:
        from instance_guard import run_identity_cases
        failures, total = run_identity_cases()
        for failure in failures:
            print("FAIL " + failure)
        sys.exit(1 if failures else 0)
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
