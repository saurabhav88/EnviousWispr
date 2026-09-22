#!/usr/bin/env python3
"""Learn-from-edits replay over a REAL word list (#996): would the feature have
learned each of these words from one fix?

    python3 Tests/RuntimeUAT/learn_from_edits_words_uat.py --run-dir <dir> --export <fp32 dir> \\
        --words <custom-words.json snapshot> [--only Saurabh,pixii] [--limit N]

For every word in the snapshot: speak a carrier sentence that contains the
word's first recorded mishearing (its first alias, spelled the way the
recogniser once wrote it) through BlackHole into TextEdit, read what the
recogniser delivered between two anchor words, and then:

  - if it delivered the right spelling already: `already_right` (nothing to
    learn; the built-in corrector or the model knows the word);
  - otherwise fix the heard form to the right spelling through accessibility
    and wait for the judge and the save; record what the judge said, whether
    the save landed the alias (`learn_added`, then the file), and whether the
    Undo pill was offered (`learn_undo_shown`; it is never pressed).

Every row names the outcome with the log token that decides it, so the table
answers "which of my words would this catch, and why not the others". The
word list is PRIVATE local data: the script reads it from the path given,
writes rows to the run directory only, and never prints a word to a tracked
file. The run starts from an EMPTY word list (so the recogniser has no help)
and restores the original in `finally`, verified byte for byte.

Same audio, log and restore mechanics as `learn_from_edits_uat.py`, which this
imports. Exit 0 when every row has a verdict, 2 when the rig could not produce
one (INSTRUMENT), 3 when the restore is unverified.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import learn_from_edits_uat as d  # noqa: E402
import wispr_eyes as w  # noqa: E402
from ui_helpers import perform_action  # noqa: E402

CARRIER = "Please ask {} about the invoices today"
BEFORE, AFTER = "ask", "about"


def heard_between(text):
    m = re.search(re.escape(BEFORE) + r"\s+(.+?)\s+" + re.escape(AFTER), text, re.IGNORECASE)
    return m.group(1) if m else None


def learn_tokens(mark):
    return [l.split("[LearnFromEdits]")[1].strip() for l in w.log_entries_since(mark) if "[LearnFromEdits]" in l]


def take(path, sentence, expect):
    """One take into the TextEdit document; returns the delivered text (or None)."""
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    time.sleep(0.8)  # settle: TextEdit frontmost before the menu-driven take; no ack
    mark = d.log_mark()
    clip = w.tts(sentence, engine="say")
    if not os.path.exists(clip) or os.path.getsize(clip) < 8192:
        return mark, None
    ok = w.test_recording(audio=clip, expect=expect, timeout=45.0)
    if not d.wait_for("the paste cascade line", lambda: re.search(r"Paste cascade: tier=\S+, app=com\.apple\.TextEdit", d.log_since(mark)), deadline=20.0):
        return mark, None
    text = d.wait_for("the delivered text", lambda: d.field_text(path) or None, deadline=10.0)
    return mark, text


def replay_word(path, word, index):
    canonical = word["canonical"]
    aliases = [a for a in (word.get("aliases") or []) if a and a.strip()]
    spoken = aliases[0] if aliases else canonical
    row = {"index": index, "canonical": canonical, "spoken": spoken, "category": word.get("category")}
    mark, text = take(path, CARRIER.format(spoken), "invoices")
    row["delivered"] = text
    if not text:
        row["outcome"] = "INSTRUMENT: nothing delivered"
        return row
    heard = heard_between(text)
    row["heard"] = heard
    if heard is None:
        row["outcome"] = "INSTRUMENT: anchors not found in the delivered text"
        return row
    if heard.lower() == canonical.lower():
        row["outcome"] = "already_right"
        return row
    if d.has(mark, "dead_mic_retire_attempted"):
        row["mic_retired_in_take"] = True
    fix_mark = d.log_mark()
    try:
        d.apply_fix(path, f"word-{index}", heard, canonical)
    except d.Aborted as error:
        row["outcome"] = f"INSTRUMENT: {error}"
        return row
    judged = d.wait_for("learn_judged", lambda: re.search(r"learn_judged arm=\w+ outcome=\w+ candidates=\d+ accepted=\d+", d.log_since(fix_mark)), deadline=12.0)
    if not judged:
        # No judge call: the watcher ended or filtered before it. Name why.
        ended = d.wait_for("observation end", lambda: re.search(r"learn_observation_ended reason=\w+", d.log_since(fix_mark)), deadline=8.0)
        skipped = re.search(r"learn_skipped reason=\w+", d.log_since(mark))
        row["outcome"] = "not_judged: " + (ended.group(0) if ended else (skipped.group(0) if skipped else "no observation end within 8 s"))
        row["learn_lines"] = learn_tokens(mark)
        return row
    row["judged"] = judged.group(0)
    verdict = d.parse_judged(judged.group(0))
    if verdict["outcome"] != "verdict":
        row["outcome"] = f"judge_bypassed: {verdict['outcome']}"
        return row
    if verdict["accepted"] == 0:
        row["outcome"] = "judge_refused"
        return row
    # The save is immediate: `learn_added` proves it landed (emitted only after
    # the app's post-write reread); `learn_save_failed` is a terminal refusal.
    added = d.wait_for("learn_added", lambda: re.search(r"learn_added state=(\w+)", d.log_since(fix_mark)), deadline=8.0)
    if not added:
        failed = re.search(r"learn_save_failed reason=(\w+)", d.log_since(fix_mark))
        row["outcome"] = f"save_failed: {failed.group(1)}" if failed else "judged_accepted_but_no_learn_added"
        row["learn_lines"] = learn_tokens(mark)
        return row
    row["added_state"] = added.group(1)
    # The judge names the RUN the aligner found: for a multi-word term where
    # only one word was misheard ("Clock Code" → "Claude Code") that is the one
    # changed word, so what lands is that pair, not the whole term. The Debug
    # `judged` line names the pair; the landed check follows it.
    pair_original, pair_corrected = d.parse_judged_pair(fix_mark) or (heard, canonical)
    row["judged_pair"] = [pair_original, pair_corrected]
    landed = d.wait_for("the alias in custom-words.json", lambda: (lambda entry: bool(entry) and pair_original.lower() in [a.lower() for a in (entry.get("aliases") or [])])(d.word_named(pair_corrected)), deadline=5.0)
    # Recorded, never pressed: the pill is the main drill's question.
    row["undo_shown"] = bool(d.wait_for("learn_undo_shown", lambda: d.has(fix_mark, "learn_undo_shown"), deadline=3.0))
    if landed:
        row["outcome"] = "learned" if pair_corrected.lower() == canonical.lower() else "learned_one_word_of_term"
    else:
        row["outcome"] = f"added_but_not_in_file: state={added.group(1)}"
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--export", required=True)
    parser.add_argument("--words", required=True, help="a custom-words.json snapshot to replay (private; read only)")
    parser.add_argument("--only", default="")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()
    d.run_dir = os.path.abspath(args.run_dir)
    os.makedirs(d.run_dir, exist_ok=True)
    with open(args.words) as fh:
        words = json.load(fh)["words"]
    only = {x.lower() for x in args.only.split(",") if x}
    if only:
        words = [x for x in words if x["canonical"].lower() in only]
    if args.limit:
        words = words[: args.limit]

    if d.screen_is_locked():
        raise d.Aborted("the screen is locked; unlock it and hands off the Mac")
    others = [p for p in d.running_instances().values() if p != d.APP_BIN]
    if others:
        raise d.Aborted(f"another EnviousWispr instance is running: {others}; refusing to choose")
    initially_running = d.app_pid() is not None
    snaps = {"words": d.file_snapshot(d.WORDS), "defaults": d.defaults_snapshot(), "launchctl": d.launchctl_get()}
    rows = []
    exit_code = 0
    route = None
    doc = None
    app_stopped = False
    audio_restored = True
    try:
        if d.app_pid() is None:
            d.launchctl_set(args.export)
            d.start_app()
        route = d.audio_route()
        route.apply()
        # ONE relaunch on an empty word list, so nothing helps the recogniser.
        d.stop_app()
        d.file_restore(d.WORDS, d.empty_words_like(snaps["words"]))
        d.defaults_write_bool(True)
        d.launchctl_set(args.export)
        d.start_app()
        doc = d.new_doc("words")
        d.prove_oracle(doc)
        for i, word in enumerate(words, 1):
            d.park_pointer()
            d.clear_field(doc)
            print(f"\n=== {i}/{len(words)} {word['canonical']} (spoken: {(word.get('aliases') or [word['canonical']])[0]}) ===", flush=True)
            try:
                row = replay_word(doc, word, i)
            except d.Aborted as error:
                row = {"index": i, "canonical": word["canonical"], "outcome": f"INSTRUMENT: {error}"}
            rows.append(row)
            print(f"  {row['outcome']}  heard={row.get('heard')!r}", flush=True)
            d.save("rows.json", rows)
            # Leave no pill on screen for the next word: the 3 s Undo window
            # passes untouched (nothing here may press Undo).
            time.sleep(2.5)  # settle: the Undo pill leaves on its own before the field is cleared
            end_mark = d.log_mark()
            d.clear_field(doc)
            # An emptied field ends a live watch (`textbox_emptied`); one that
            # already ended logs nothing more. Either way the next word starts clean.
            d.wait_for("the watch to end", lambda: d.has(end_mark, "learn_observation_ended"), deadline=3.0)
    except d.Aborted as error:
        rows.append({"outcome": f"INSTRUMENT: {error}"})
        exit_code = 2
    finally:
        try:
            if doc:
                d.close_doc(doc)
        except Exception as error:
            print(f"    (closing the document failed: {error})")
        try:
            if route is not None:
                route.restore()
        except Exception as error:
            audio_restored = False
            print(f"    (audio restore failed: {error})")
        try:
            d.stop_app()
            app_stopped = True
        except d.Aborted as error:
            print(f"    (app stop failed: {error})")
        restored, receipt = d.finish_restore(snaps, initially_running, app_stopped, audio_restored)
        print(f"\n  {'PASS' if restored else 'FAIL'}  restore :: {receipt}")
        if not restored:
            exit_code = 3
        elif any(str(r.get("outcome", "")).startswith("INSTRUMENT") for r in rows):
            exit_code = max(exit_code, 2)
        tally = {}
        for r in rows:
            key = str(r.get("outcome", "?")).split(":")[0]
            tally[key] = tally.get(key, 0) + 1
        d.save("summary.json", {"exit_code": exit_code, "tally": tally, "rows": rows, "restored": restored, "receipt": receipt})
        print("  TALLY:", json.dumps(tally))
    print(f"\nEXIT {exit_code}")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except d.Aborted as error:
        print(f"INSTRUMENT: {error}")
        sys.exit(2)
