#!/usr/bin/env python3
"""End-to-end timing bench for Auto Dictionary (#3105): release to pasted text, every stage live.

    python3 Tests/RuntimeUAT/auto_dictionary_bench.py --run-dir <dir> --engine egOne|s1Mini \\
        --adapter <that engine's checker .gguf> --threshold 0.9 [--rounds 2]

WHAT IS TIMED. `Pipeline timing TOTAL` starts at the accepted stop (`RecordingSessionKernel`
`markPipelineTimingStart`, the same instant as the `t_release` signpost) and ends after paste
(`KernelFinalizationWiring` `pipelineEndedAtSeconds`), for every recogniser. Inside it, per take:
the recogniser, every text step from `StepTiming:` lines (deterministic clean-up, Word Correction,
the learned-word check = sensing + the engine's judge + replacing, filler, emoji, ITN, the
engine's polish, emoji restore), and paste. Nothing is simulated: real audio through BlackHole into
the real app, the selected local engine (EG-1 or S1-mini, `--engine`) polishing on the bundled
server, its checker as a LoRA adapter on the same server.

TWO ARMS, same sentences, same order:
  off: Auto Dictionary checker not installed (today's product, learned words inert)
  on:  that engine's checker installed through its Debug door (`EW_LEARNED_CHECK_EG1_ADAPTER`
       or `EW_LEARNED_CHECK_S1_ADAPTER`, with the matching `_THRESHOLD`)
Each arm: relaunch, one warm-up take (reported separately as COLD, not in the medians), then
`rounds` passes over the sentences. Six of twelve sentences carry a misspelling the dictionary has
already learned for a word (the checker is asked; aliases only since founder 2026-09-25, #3105), one
of them a three-sentence take; the rest, including a second three-sentence take, carry none.

WHAT IT TOUCHES AND PUTS BACK. The same shared-data rules as the learn-from-edits drill
(code-uat.md RULE: uat-writes-reach-the-founders-REAL-data): `custom-words.json` byte for byte,
the chosen engine's two launchctl door variables, the audio route (silent, BlackHole), and
whether the dev app was running. `llmProvider` is read and must already equal `--engine`; the
bench never writes it. The other engine's doors are not touched: its checker is never selected
while this engine is.
"""

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import learn_from_edits_uat as lfe  # noqa: E402  (shared helpers: audio route, snapshots, TextEdit)

# Each local engine's checker door (Swift: `LearnedWordCheckAdapterDoor.Engine`) and the label its
# ACTIVE line uses ("learned-check <label> door ACTIVE").
ENGINES = {
    "egOne": {"adapter": "EW_LEARNED_CHECK_EG1_ADAPTER", "threshold": "EW_LEARNED_CHECK_EG1_THRESHOLD", "label": "EG-1",
              "checker_arm": "eg1_lora"},
    "s1Mini": {"adapter": "EW_LEARNED_CHECK_S1_ADAPTER", "threshold": "EW_LEARNED_CHECK_S1_THRESHOLD", "label": "S1-mini",
               "checker_arm": "s1_lora"},
}

# A realistic learned dictionary: words the app learned from edits (born-learned), each with the
# misspellings a user's earlier fixes taught it. The checker is asked only where one reappears.
LEARNED = {
    "Tuist": ["twist", "Twoist"], "Qwen": ["Quen", "Kwen"], "PostHog": ["post hog"], "Kotlin": ["cotton"],
    "Supabase": ["super base"], "Ollama": ["a llama"], "Vercel": ["versel"], "Kaggle": ["gaggle"],
}

# (sentence, expected token in the output). First five carry a learned word as Parakeet tends to
# write it (a learned misspelling); last five carry none.
SENTENCES = [
    ("The day Tuist regenerated my whole Xcode project it saved an hour", "project"),
    ("Ask Qwen to summarize the meeting notes before lunch", "meeting"),
    ("We ship analytics through post hog and it works well", "analytics"),
    ("The Android team rewrote the client in cotton last spring", "client"),
    ("Please move the auth tables to super base this week", "tables"),
    ("Can you send me the quarterly report by Friday afternoon", "report"),
    ("The weather looks great for the hike on Saturday morning", "weather"),
    ("I will call the dentist tomorrow to move my appointment", "dentist"),
    ("Remember to water the plants while we are away next week", "plants"),
    ("The new coffee shop downtown opens at seven every day", "coffee"),
    # Multi-sentence takes: each checker question must carry only its own sentence.
    ("We had a long planning meeting this morning. The Android team rewrote the client in cotton last spring. "
     "After that we moved the auth tables to super base and everything got faster", "planning"),
    ("I spent the whole afternoon on the budget spreadsheet. Then I walked the dog around the park twice. "
     "Tomorrow I want to finish the slides before the team review", "budget"),
]
# Sentences whose Parakeet text is expected to carry a learned misspelling (the checker is asked).
TRIGGER_IDX = {0, 1, 2, 3, 4, 10}

TOTAL_RE = re.compile(r"Pipeline timing TOTAL: ([\d.]+)s \(ASR=([\d.]+)s, polish=([\d.]+)s, paste=([\d.]+)s\)")
STEP_RE = re.compile(r"StepTiming: step=(.+?) ms=([\d.]+) ran=(true|false)")
CHECK_RE = re.compile(r"LearnedWordCheck: flagged=(\d+) approved=(\d+) applied=(\d+) contested=(\d+) latency_ms=(\d+) arm=(\S+) reason=(\S+)")


def door_get(key):
    # A failed read raises: it must never look like an unset door.
    v = subprocess.run(["launchctl", "getenv", key], capture_output=True, text=True, check=True).stdout.strip()
    return v or None


def door_set(key, value):
    if value is None:
        subprocess.run(["launchctl", "unsetenv", key], check=True)
    else:
        subprocess.run(["launchctl", "setenv", key, value], check=True)


def learned_dictionary(snapshot):
    base = lfe.empty_words_like(snapshot)
    parsed = dict(base["parsed"])
    parsed["words"] = [
        {"id": f"00000000-0000-4000-8000-0000000001{i:02d}", "canonical": w, "aliases": list(misspellings),
         "category": "general", "source": "user", "isEnabled": True, "learnedAliases": list(misspellings),
         "learnedAt": 780000000 + i}
        for i, (w, misspellings) in enumerate(LEARNED.items())]
    raw = json.dumps(parsed).encode("utf-8")
    return {"exists": True, "bytes": raw, "mode": 0o600, "sha256": hashlib.sha256(raw).hexdigest(), "parsed": parsed}


def start_app():
    mark = lfe.log_mark()
    subprocess.run(["open", "-n", lfe.APP], check=True)
    if not lfe.wait_for("startup scan", lambda: lfe.has(mark, "scan finished"), deadline=90.0):
        raise lfe.Aborted("the app did not reach a ready state")
    # Same readiness wait as the drill: the status item's exact menu entry must exist
    # before a menu-driven take, or the harness falls into a system-wide menu walk.
    lfe.w.connect()
    if not lfe.wait_for("the Start Recording menu item",
                        lambda: lfe.w._find_match(lfe.w._app, "Start Recording", None, exact=True), deadline=30.0):
        raise lfe.Aborted("the relaunched app never exposed its Start Recording menu item")
    time.sleep(1.0)  # settle: overlay host and paste registry finish their first render; no ack
    return mark


def take(doc, arm, idx, sentence, expect, checker_arm):
    pair = lfe.Pair(sentence, expect, "", "", "__none__")
    mark, text, _ = lfe.dictate(doc, f"{arm}-{idx:02d}", pair, need_heard=False)
    total = lfe.wait_for("the take's timing line", lambda: TOTAL_RE.search(lfe.log_since(mark)), deadline=30.0)
    if not total:
        raise lfe.Aborted(f"{arm}-{idx}: no Pipeline timing TOTAL line")
    body = lfe.log_since(mark)
    steps = {m.group(1): float(m.group(2)) for m in STEP_RE.finditer(body) if m.group(3) == "true"}
    check = CHECK_RE.search(body)
    lfe.clear_field(doc)
    # A timing is only about the arm it names: every on take ran the engine's checker (a
    # take with no learned alias in it may say no_candidates), every off take ran none.
    # An on door that logged ACTIVE but fell back to no_checker must not produce a summary.
    want = checker_arm if arm == "on" else "none"
    if not check or check.group(6) != want:
        raise lfe.Aborted(f"{arm}-{idx}: expected checker arm {want!r}, got {check.group(0) if check else None!r}")
    return {"arm": arm, "idx": idx, "sentence": sentence, "trigger": idx % len(SENTENCES) in TRIGGER_IDX,
            "total_ms": round(float(total.group(1)) * 1000), "asr_ms": round(float(total.group(2)) * 1000),
            # The kernel's TOTAL line calls this span "polish", but it is every text step
            # (the learned-word check included); the engine's polish alone is steps_ms["LLM Polish"].
            "text_steps_ms": round(float(total.group(3)) * 1000), "paste_ms": round(float(total.group(4)) * 1000),
            "steps_ms": steps, "check": check.group(0) if check else None,
            "check_ms": int(check.group(5)) if check else None, "delivered": text}


def summarize(rows):
    def stat(xs):
        xs = sorted(xs)
        return {"n": len(xs), "median": statistics.median(xs) if xs else None,
                "p90": xs[min(len(xs) - 1, int(0.9 * len(xs)))] if xs else None}
    out = {}
    for arm in ("off", "on"):
        warm = [r for r in rows if r["arm"] == arm and not r.get("cold")]
        out[arm] = {
            "all": stat([r["total_ms"] for r in warm]),
            "auto_dictionary_sentences": stat([r["total_ms"] for r in warm if r["trigger"]]),
            "plain_sentences": stat([r["total_ms"] for r in warm if not r["trigger"]]),
            "asr": stat([r["asr_ms"] for r in warm]),
            "text_steps": stat([r["text_steps_ms"] for r in warm]),
            "paste": stat([r["paste_ms"] for r in warm]),
            "checker": stat([r["check_ms"] for r in warm if r["check_ms"] is not None]),
            "cold_total_ms": next((r["total_ms"] for r in rows if r["arm"] == arm and r.get("cold")), None),
        }
        steps = {}
        for r in warm:
            for k, v in r["steps_ms"].items():
                steps.setdefault(k, []).append(v)
        out[arm]["steps"] = {k: stat(v) for k, v in steps.items()}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--engine", choices=sorted(ENGINES), default="egOne",
                    help="the local engine whose checker is timed; llmProvider must already be this")
    ap.add_argument("--adapter", required=True, help="absolute path to that engine's checker adapter .gguf")
    ap.add_argument("--threshold", default="0.9")
    ap.add_argument("--rounds", type=int, default=2)
    args = ap.parse_args()
    lfe.run_dir = args.run_dir
    os.makedirs(args.run_dir, exist_ok=True)
    provider = subprocess.run(["defaults", "read", lfe.DOMAIN, "llmProvider"], capture_output=True, text=True).stdout.strip()
    engine = ENGINES[args.engine]
    adapter_key, threshold_key, label = engine["adapter"], engine["threshold"], engine["label"]
    if provider != args.engine:
        raise SystemExit(f"llmProvider is {provider!r}, not {args.engine!r}; the bench never changes the setting")
    if not os.path.isabs(args.adapter) or not os.path.exists(args.adapter):
        raise SystemExit(f"adapter not found: {args.adapter}")

    initially_running = lfe.app_pid() is not None
    snaps = {"words": lfe.file_snapshot(lfe.WORDS), "adapter": door_get(adapter_key), "threshold": door_get(threshold_key)}
    rows, audio_restored, route, doc = [], True, None, None
    try:
        if lfe.app_pid() is None:
            start_app()
        route = lfe.audio_route()
        route.apply()
        doc = lfe.new_doc("bench")
        lfe.prove_oracle(doc)
        for arm in ("off", "on"):
            # Relaunch on the ORIGINAL devices, then switch to BlackHole while the app runs: an app that
            # launches with BlackHole already selected is ~1 s slower per take (#3114), which would inflate
            # both arms' absolute times.
            route.restore()
            lfe.stop_app()
            lfe.file_restore(lfe.WORDS, learned_dictionary(snaps["words"]))
            door_set(adapter_key, args.adapter if arm == "on" else None)
            door_set(threshold_key, args.threshold if arm == "on" else None)
            mark = start_app()
            route.apply()
            if arm == "on" and not lfe.wait_for(f"the {label} checker door", lambda: lfe.has(mark, f"learned-check {label} door ACTIVE"), deadline=30.0):
                raise lfe.Aborted(f"the {label} checker door did not report ACTIVE")
            cold = take(doc, arm, 0, *SENTENCES[0], engine["checker_arm"])
            cold["cold"] = True
            rows.append(cold)
            print(f"  {arm} COLD total={cold['total_ms']} ms", flush=True)
            for rnd in range(args.rounds):
                for i, (sentence, expect) in enumerate(SENTENCES):
                    r = take(doc, arm, rnd * len(SENTENCES) + i, sentence, expect, engine["checker_arm"])
                    rows.append(r)
                    print(f"  {arm} {r['idx']:02d} total={r['total_ms']} asr={r['asr_ms']} text={r['text_steps_ms']} "
                          f"check={r['check_ms']} {'[AD]' if r['trigger'] else ''}", flush=True)
    finally:
        # Every cleanup step runs whatever an earlier one raised: the run
        # replaced the founder's real dictionary and launch doors, and the
        # verification below is what decides the exit code.
        if doc is not None:
            try:
                lfe.close_doc(doc)
            except Exception as error:
                print(f"    (closing the document failed: {error})")
        if route is not None:
            try:
                route.restore()
            except Exception as error:
                audio_restored = False
                print(f"AUDIO RESTORE FAILED: {error}")
        stopped = True
        try:
            lfe.stop_app()
        except Exception as error:
            stopped = False
            print(f"APP STOP FAILED: {error}")
        doors_restored = True
        for key, value in ((adapter_key, snaps["adapter"]), (threshold_key, snaps["threshold"])):
            try:
                door_set(key, value)
            except Exception as error:
                doors_restored = False
                print(f"DOOR RESTORE FAILED for {key}: {error}")
        if stopped:
            try:
                lfe.file_restore(lfe.WORDS, snaps["words"])
            except Exception as error:
                print(f"WORDS RESTORE FAILED: {error}")
        ok_w, why = lfe.verify_restore(lfe.WORDS, snaps["words"], "words") if stopped else (False, "app did not stop")
        try:
            ok_d = doors_restored and door_get(adapter_key) == snaps["adapter"] \
                and door_get(threshold_key) == snaps["threshold"]
        except Exception as error:
            ok_d = False
            print(f"DOOR READBACK FAILED: {error}")
        if initially_running and stopped:
            subprocess.run(["open", "-n", lfe.APP], check=False)
        lfe.save("rows.json", rows)
        summary = summarize(rows)
        lfe.save("summary.json", summary)
        print(json.dumps(summary, indent=1))
        print(f"RESTORE words={ok_w} ({why}) doors={ok_d} audio={audio_restored}")
        if not (ok_w and ok_d and audio_restored):
            sys.exit(3)


if __name__ == "__main__":
    main()
