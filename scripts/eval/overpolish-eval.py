#!/usr/bin/env python3
"""Over-Polish Evaluation: Question Preservation Test.

Tests whether Apple Intelligence (or LLM polish) answers questions instead of
polishing them. The original bug: user dictated "I think we should is there any
hardware cost to keep the harness in place or should we strip it?" and AI polish
returned "I think we should strip it." -- the LLM answered the question instead
of cleaning up the transcription.

Corpus: 30 questions of varying lengths and styles. Pass criteria: output must
still be a question (contains '?' or preserves interrogative structure), and
must not collapse into a declarative answer.

Usage:
    python3 test/overpolish-eval.py generate    # Generate TTS audio (once)
    python3 test/overpolish-eval.py run         # Run full assessment
    python3 test/overpolish-eval.py run --ids 1-10  # Run subset
    python3 test/overpolish-eval.py report      # Print last results
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

PROJ_ROOT = Path(__file__).parent.parent.parent
AUDIO_DIR = Path("/tmp/overpolish-eval-audio")
LOG_PATH = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
RESULTS_DIR = PROJ_ROOT / "benchmark-results" / "overpolish-eval"
POST_RELEASE_WAIT = 3  # seconds after PTT release to let pipeline finish

TTS_MODEL = "tts-1-hd"
TTS_VOICE = "echo"
OPENAI_KEY_PATH = os.path.expanduser("~/.enviouswispr-keys/openai-api-key")

# ────────────────────────────────────────────────────────────────
# CORPUS: 30 questions across 6 categories
#
# Categories:
#   short_q       - Short direct questions (5-8 words)
#   medium_q      - Medium questions (10-18 words)
#   long_q        - Long/compound questions (20+ words)
#   disfluent_q   - Questions with self-corrections and disfluencies (the bug trigger)
#   embedded_q    - Questions embedded in longer declarative framing
#   compound_q    - Multiple questions in one utterance
#
# Each entry has:
#   must_be_question: True = output MUST contain '?' or interrogative words
#   key_words: words that must survive in the output (case-insensitive)
#   trap_answers: if any of these appear in output, the LLM answered instead of polishing
# ────────────────────────────────────────────────────────────────
CORPUS = [
    # ── Short questions (5) ──
    {"id": 1, "text": "What time is the meeting?",
     "category": "short_q", "must_be_question": True,
     "key_words": ["time", "meeting"],
     "trap_answers": []},

    {"id": 2, "text": "Should we deploy today or tomorrow?",
     "category": "short_q", "must_be_question": True,
     "key_words": ["deploy", "today", "tomorrow"],
     "trap_answers": ["we should deploy", "deploy today", "deploy tomorrow"]},

    {"id": 3, "text": "Can you review my pull request?",
     "category": "short_q", "must_be_question": True,
     "key_words": ["review", "pull request"],
     "trap_answers": ["yes", "sure", "I can"]},

    {"id": 4, "text": "Where did you put the config file?",
     "category": "short_q", "must_be_question": True,
     "key_words": ["config", "file"],
     "trap_answers": ["in the", "it's in"]},

    {"id": 5, "text": "Who is handling the on-call rotation this week?",
     "category": "short_q", "must_be_question": True,
     "key_words": ["on-call", "rotation", "week"],
     "trap_answers": []},

    # ── Medium questions (5) ──
    {"id": 6, "text": "Do we need to update the API documentation before the release goes out?",
     "category": "medium_q", "must_be_question": True,
     "key_words": ["update", "API", "documentation", "release"],
     "trap_answers": ["we need to", "yes we", "no we"]},

    {"id": 7, "text": "How many users are currently on the free tier versus the paid plan?",
     "category": "medium_q", "must_be_question": True,
     "key_words": ["users", "free tier", "paid"],
     "trap_answers": ["there are", "about"]},

    {"id": 8, "text": "Is there a reason we chose Postgres over SQLite for this particular service?",
     "category": "medium_q", "must_be_question": True,
     "key_words": ["Postgres", "SQLite", "service"],
     "trap_answers": ["the reason is", "because", "we chose"]},

    {"id": 9, "text": "What happens if the webhook fails and the retry queue is already full?",
     "category": "medium_q", "must_be_question": True,
     "key_words": ["webhook", "fails", "retry", "queue", "full"],
     "trap_answers": ["it will", "the system"]},

    {"id": 10, "text": "Are we tracking latency per endpoint or just the aggregate across the whole service?",
     "category": "medium_q", "must_be_question": True,
     "key_words": ["latency", "endpoint", "aggregate"],
     "trap_answers": ["we are tracking", "we track"]},

    # ── Long questions (5) ──
    {"id": 11, "text": "If we migrate the authentication service to the new cluster, will the existing session tokens still be valid or do we need to force everyone to re-authenticate?",
     "category": "long_q", "must_be_question": True,
     "key_words": ["migrate", "authentication", "cluster", "session tokens", "re-authenticate"],
     "trap_answers": ["they will", "you need to", "tokens will"]},

    {"id": 12, "text": "Given that the database is already at eighty percent capacity, should we scale vertically by upgrading the instance or horizontally by adding read replicas?",
     "category": "long_q", "must_be_question": True,
     "key_words": ["database", "capacity", "scale", "vertically", "horizontally", "read replicas"],
     "trap_answers": ["you should", "scale vertically", "add read replicas"]},

    {"id": 13, "text": "When the user clicks the export button and the file is larger than fifty megabytes, do we stream it directly or generate it in the background and send a notification?",
     "category": "long_q", "must_be_question": True,
     "key_words": ["export", "fifty megabytes", "stream", "background", "notification"],
     "trap_answers": ["we stream", "generate it", "you should"]},

    {"id": 14, "text": "Has anyone looked into why the build times on CI jumped from four minutes to twelve minutes after we merged the dependency update last Thursday?",
     "category": "long_q", "must_be_question": True,
     "key_words": ["build times", "CI", "four minutes", "twelve minutes", "dependency"],
     "trap_answers": ["it's because", "the reason"]},

    {"id": 15, "text": "Could we potentially use the same caching layer that the search service uses for the recommendation engine, or would the access patterns be too different to share infrastructure?",
     "category": "long_q", "must_be_question": True,
     "key_words": ["caching", "search", "recommendation", "access patterns", "infrastructure"],
     "trap_answers": ["yes you could", "no the", "you can"]},

    # ── Disfluent questions (5) -- THE BUG TRIGGER CATEGORY ──
    {"id": 16, "text": "I think we should is there any is there any hardware cost to keep the harness in place or should we strip it?",
     "category": "disfluent_q", "must_be_question": True,
     "key_words": ["hardware cost", "harness", "strip"],
     "trap_answers": ["we should strip", "strip it", "I think we should strip"]},

    {"id": 17, "text": "So the thing is like can we actually do we have enough budget to hire another contractor for the backend work?",
     "category": "disfluent_q", "must_be_question": True,
     "key_words": ["budget", "hire", "contractor", "backend"],
     "trap_answers": ["we have", "we don't have", "yes", "no"]},

    {"id": 18, "text": "Wait so if we go with the, no actually, does the current plan even support multi-region failover or would we need to upgrade?",
     "category": "disfluent_q", "must_be_question": True,
     "key_words": ["plan", "multi-region", "failover", "upgrade"],
     "trap_answers": ["the plan supports", "you need to upgrade", "it does"]},

    {"id": 19, "text": "I was going to say we should just, well actually, is the old API still being called by any external partners or can we safely deprecate it?",
     "category": "disfluent_q", "must_be_question": True,
     "key_words": ["old API", "external partners", "deprecate"],
     "trap_answers": ["we can safely", "deprecate it", "it is still"]},

    {"id": 20, "text": "Um okay so like the question is really whether we should uh should we keep both implementations running in parallel or just cut over to the new one?",
     "category": "disfluent_q", "must_be_question": True,
     "key_words": ["implementations", "parallel", "cut over"],
     "trap_answers": ["keep both", "cut over", "you should"]},

    # ── Embedded questions (5) ──
    {"id": 21, "text": "I was wondering if you had a chance to look at whether the memory leak in the worker process has gotten any worse since the last deploy?",
     "category": "embedded_q", "must_be_question": True,
     "key_words": ["memory leak", "worker", "worse", "deploy"],
     "trap_answers": ["it has", "it hasn't", "the leak"]},

    {"id": 22, "text": "The client asked me to find out how long it would take to add single sign-on support to the admin portal?",
     "category": "embedded_q", "must_be_question": True,
     "key_words": ["client", "single sign-on", "admin portal"],
     "trap_answers": ["it would take", "about"]},

    {"id": 23, "text": "Before we start the sprint, I need to understand whether the design team has finalized the new onboarding flow or if that is still in review?",
     "category": "embedded_q", "must_be_question": True,
     "key_words": ["sprint", "design team", "onboarding", "review"],
     "trap_answers": ["they have", "it is still", "the design"]},

    {"id": 24, "text": "Sarah mentioned something about the staging environment being down, do you know if someone is already looking into that?",
     "category": "embedded_q", "must_be_question": True,
     "key_words": ["Sarah", "staging", "down", "looking into"],
     "trap_answers": ["someone is", "yes", "no"]},

    {"id": 25, "text": "I keep hearing that we might switch from AWS to GCP next quarter, is that actually happening or just speculation at this point?",
     "category": "embedded_q", "must_be_question": True,
     "key_words": ["AWS", "GCP", "quarter", "speculation"],
     "trap_answers": ["it is happening", "it's just"]},

    # ── Compound questions (5) ──
    {"id": 26, "text": "What is the current error rate on the payments endpoint, and has it changed since we deployed the retry logic?",
     "category": "compound_q", "must_be_question": True,
     "key_words": ["error rate", "payments", "retry logic"],
     "trap_answers": ["the error rate is", "it has"]},

    {"id": 27, "text": "Who owns the notification service now, and do they know about the timezone bug that keeps sending alerts at three in the morning?",
     "category": "compound_q", "must_be_question": True,
     "key_words": ["notification", "timezone", "bug", "three in the morning"],
     "trap_answers": ["they know", "it's owned by"]},

    {"id": 28, "text": "Can we add rate limiting to the public API without breaking existing integrations, and if so, what would be a reasonable threshold?",
     "category": "compound_q", "must_be_question": True,
     "key_words": ["rate limiting", "public API", "integrations", "threshold"],
     "trap_answers": ["you can", "a reasonable threshold would be"]},

    {"id": 29, "text": "Did the customer data export finish running, and were there any rows that failed validation during the process?",
     "category": "compound_q", "must_be_question": True,
     "key_words": ["export", "finish", "rows", "validation"],
     "trap_answers": ["it finished", "there were"]},

    {"id": 30, "text": "How does the current caching strategy handle cache invalidation across regions, and is there a risk of stale data being served during a deploy?",
     "category": "compound_q", "must_be_question": True,
     "key_words": ["caching", "invalidation", "regions", "stale data", "deploy"],
     "trap_answers": ["it handles", "there is a risk", "there is no risk"]},
]


def get_openai_key():
    with open(OPENAI_KEY_PATH) as f:
        return f.read().strip()


def generate_tts(text, output_path):
    """Generate TTS audio via OpenAI API."""
    import urllib.request
    key = get_openai_key()
    payload = json.dumps({
        "model": TTS_MODEL,
        "voice": TTS_VOICE,
        "input": text,
        "response_format": "mp3"
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=payload,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json"
        }
    )
    with urllib.request.urlopen(req) as resp:
        with open(output_path, "wb") as f:
            f.write(resp.read())


def generate_audio():
    """Generate TTS audio files for all corpus entries."""
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    generated = 0
    for entry in CORPUS:
        path = AUDIO_DIR / f"{entry['id']:03d}.mp3"
        if path.exists():
            continue
        print(f"  Generating #{entry['id']:02d}: {entry['text'][:60]}...")
        generate_tts(entry["text"], str(path))
        generated += 1
        time.sleep(0.3)
    print(f"Generated {generated} new audio files ({len(CORPUS)} total in {AUDIO_DIR})")


def get_audio_duration(path):
    """Get audio duration in seconds via afinfo."""
    result = subprocess.run(
        ["afinfo", str(path)], capture_output=True, text=True
    )
    for line in result.stdout.split("\n"):
        if "estimated duration:" in line:
            return float(line.split(":")[1].strip().split(" ")[0])
    return 3.0


def read_clipboard():
    result = subprocess.run(["pbpaste"], capture_output=True, text=True)
    return result.stdout.strip()


def clear_clipboard():
    subprocess.run(["pbcopy"], input=b"", check=True)


def get_log_line_count():
    """Get current line count of the log file."""
    try:
        result = subprocess.run(
            ["wc", "-l", LOG_PATH], capture_output=True, text=True
        )
        return int(result.stdout.strip().split()[0])
    except Exception:
        return 0


def get_log_lines_after(start_line):
    """Get log lines after a given line number."""
    try:
        result = subprocess.run(
            ["tail", "-n", f"+{start_line + 1}", LOG_PATH],
            capture_output=True, text=True
        )
        return result.stdout
    except Exception:
        return ""


def parse_pipeline_output(log_text):
    """Extract final output from logs. Walks the correction chain to find
    what actually got pasted. Falls back to raw ASR if no corrections fired."""
    raw_asr = ""
    polish_in = ""
    polish_out = ""
    polish_no_change = False
    wc_out = ""
    filler_out = ""
    final_output = ""

    for line in log_text.split("\n"):
        if "CORRECTION_DEBUG" not in line:
            continue
        if "[RAW ASR]" in line:
            raw_asr = line.split("[RAW ASR]")[1].strip()
        elif "[LLM Polish]" in line:
            if "IN:" in line:
                polish_in = line.split("IN:")[1].strip()
            elif "OUT:" in line:
                polish_out = line.split("OUT:")[1].strip()
            elif "no change" in line:
                polish_no_change = True
        elif "[Word Correction]" in line:
            if "OUT:" in line:
                wc_out = line.split("OUT:")[1].strip()
        elif "[Filler Removal]" in line:
            if "OUT:" in line:
                filler_out = line.split("OUT:")[1].strip()

    # Resolve final output: last stage that produced output wins
    if polish_out:
        final_output = polish_out
    elif polish_no_change and polish_in:
        final_output = polish_in
    elif polish_no_change and not polish_in:
        # no change and no IN logged means polish passed through its input
        final_output = filler_out or wc_out or raw_asr
    elif filler_out:
        final_output = filler_out
    elif wc_out:
        final_output = wc_out
    else:
        final_output = raw_asr

    return raw_asr, polish_in, polish_out, final_output


def check_result(entry, final_output, raw_asr, polish_in, polish_out):
    """Check if polish preserved the question vs. answered it."""
    result = {
        "passed": True,
        "failures": [],
        "warnings": [],
    }

    output = final_output
    output_lower = output.lower()

    if not output:
        result["passed"] = False
        result["failures"].append("No pipeline output found in logs")
        return result

    # 1. Must still be a question
    if entry["must_be_question"]:
        has_question_mark = "?" in output
        interrogative_words = ["who", "what", "where", "when", "why", "how",
                               "is there", "can we", "should we", "do we",
                               "does", "did", "could", "would", "has",
                               "are we", "will", "if", "whether"]
        has_interrogative = any(w in output_lower for w in interrogative_words)

        if not has_question_mark and not has_interrogative:
            result["passed"] = False
            result["failures"].append("ANSWERED: output is no longer a question")

    # 2. Key words must survive
    for word in entry.get("key_words", []):
        if word.lower() not in output_lower:
            result["warnings"].append(f"Key word missing: {word}")

    # 3. Trap answer detection
    for trap in entry.get("trap_answers", []):
        if trap.lower() in output_lower:
            # Only flag as trap if the original text didn't contain it
            if trap.lower() not in entry["text"].lower():
                result["passed"] = False
                result["failures"].append(f"TRAP ANSWER detected: '{trap}'")

    # 4. Severe content drop (output < 40% of input word count)
    input_words = len(entry["text"].split())
    output_words = len(output.split())
    if output_words < input_words * 0.4:
        result["passed"] = False
        result["failures"].append(
            f"CONTENT DROP: {output_words} words out of {input_words} "
            f"({output_words/max(input_words,1)*100:.0f}%)"
        )

    return result


def hold_key_and_play(audio_path, hold_seconds):
    """Hold right-cmd key while playing audio."""
    hold_proc = subprocess.Popen(
        ["python3", "-c",
         "import Quartz, time\n"
         "e = Quartz.CGEventCreateKeyboardEvent(None, 0x36, True)\n"
         "Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)\n"
         f"time.sleep({hold_seconds})\n"
         "e = Quartz.CGEventCreateKeyboardEvent(None, 0x36, False)\n"
         "Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)\n"
        ],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(0.3)
    subprocess.run(["afplay", str(audio_path)], capture_output=True)
    hold_proc.wait()


def run_assessment(ids=None):
    """Run the over-polish assessment."""
    entries = CORPUS if ids is None else [e for e in CORPUS if e["id"] in ids]
    if not entries:
        print("No matching entries found.")
        return

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    results_file = RESULTS_DIR / f"run-{timestamp}.jsonl"
    summary_file = RESULTS_DIR / f"run-{timestamp}-summary.json"

    print(f"\n{'='*70}")
    print(f"Over-Polish Assessment: {len(entries)} questions")
    print(f"Testing: does AI polish answer questions instead of cleaning them?")
    print(f"Results: {results_file}")
    print(f"{'='*70}\n")

    all_results = []
    pass_count = 0
    fail_count = 0

    for idx, entry in enumerate(entries):
        eid = entry["id"]
        audio_path = AUDIO_DIR / f"{eid:03d}.mp3"

        if not audio_path.exists():
            print(f"  SKIP #{eid}: audio file missing. Run 'generate' first.")
            continue

        duration = get_audio_duration(audio_path)
        hold_time = duration + 1.5

        print(f"[{idx+1}/{len(entries)}] #{eid} ({entry['category']}): {entry['text'][:60]}...")

        log_before = get_log_line_count()
        hold_key_and_play(audio_path, hold_time)
        time.sleep(POST_RELEASE_WAIT)

        new_log = get_log_lines_after(log_before)
        raw_asr, polish_in, polish_out, final_output = parse_pipeline_output(new_log)
        assessment = check_result(entry, final_output, raw_asr, polish_in, polish_out)

        row = {
            "id": eid,
            "spoken": entry["text"],
            "category": entry["category"],
            "final_output": final_output,
            "raw_asr": raw_asr,
            "polish_input": polish_in,
            "polish_output": polish_out,
            "passed": assessment["passed"],
            "failures": assessment["failures"],
            "warnings": assessment["warnings"],
        }
        all_results.append(row)

        with open(results_file, "a") as f:
            f.write(json.dumps(row) + "\n")

        status = "PASS" if assessment["passed"] else "FAIL"
        if assessment["passed"]:
            pass_count += 1
        else:
            fail_count += 1

        print(f"  {status}: [{final_output[:70]}]")
        if assessment["failures"]:
            for f_msg in assessment["failures"]:
                print(f"    FAIL: {f_msg}")
        if assessment["warnings"]:
            for w_msg in assessment["warnings"]:
                print(f"    WARN: {w_msg}")

    total = pass_count + fail_count
    summary = {
        "timestamp": timestamp,
        "total": total,
        "passed": pass_count,
        "failed": fail_count,
        "pass_rate": f"{pass_count/max(total,1)*100:.1f}%",
        "by_category": {},
        "failure_types": {
            "answered_question": 0,
            "trap_answer": 0,
            "content_drop": 0,
            "empty_clipboard": 0,
        }
    }

    categories = set(r["category"] for r in all_results)
    for cat in sorted(categories):
        cat_results = [r for r in all_results if r["category"] == cat]
        cat_pass = sum(1 for r in cat_results if r["passed"])
        summary["by_category"][cat] = {
            "total": len(cat_results),
            "passed": cat_pass,
            "failed": len(cat_results) - cat_pass,
        }

    for r in all_results:
        for f_msg in r.get("failures", []):
            if "ANSWERED" in f_msg:
                summary["failure_types"]["answered_question"] += 1
            elif "TRAP ANSWER" in f_msg:
                summary["failure_types"]["trap_answer"] += 1
            elif "CONTENT DROP" in f_msg:
                summary["failure_types"]["content_drop"] += 1
            elif "Empty clipboard" in f_msg:
                summary["failure_types"]["empty_clipboard"] += 1

    with open(summary_file, "w") as f:
        json.dump(summary, f, indent=2)

    print(f"\n{'='*70}")
    print(f"RESULTS: {pass_count}/{total} passed ({summary['pass_rate']})")
    print(f"{'='*70}")
    print(f"\nBy category:")
    for cat, stats in summary["by_category"].items():
        status = "OK" if stats["failed"] == 0 else f"{stats['failed']} FAIL"
        print(f"  {cat:20s}: {stats['passed']}/{stats['total']} ({status})")
    print(f"\nFailure types:")
    for ftype, count in summary["failure_types"].items():
        if count > 0:
            print(f"  {ftype:25s}: {count}")
    print(f"\nFull results: {results_file}")
    print(f"Summary: {summary_file}")


def print_report():
    """Print the most recent results."""
    if not RESULTS_DIR.exists():
        print("No results found. Run 'generate' then 'run' first.")
        return
    summaries = sorted(RESULTS_DIR.glob("*-summary.json"), reverse=True)
    if not summaries:
        print("No summary files found.")
        return
    with open(summaries[0]) as f:
        summary = json.load(f)
    print(json.dumps(summary, indent=2))

    jsonl_name = summaries[0].name.replace("-summary.json", ".jsonl")
    jsonl = summaries[0].with_name(jsonl_name)
    if jsonl.exists():
        print(f"\nFailures:")
        with open(jsonl) as f:
            for line in f:
                row = json.loads(line)
                if not row["passed"]:
                    print(f"\n  #{row['id']} ({row['category']})")
                    print(f"    Spoken:  {row['spoken'][:70]}")
                    print(f"    Output:  {row['final_output'][:70]}")
                    for fail in row["failures"]:
                        print(f"    -> {fail}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 test/overpolish-eval.py [generate|run|report]")
        print("  generate       Generate TTS audio files (once)")
        print("  run            Run full 30-question assessment")
        print("  run --ids 1-10 Run specific IDs")
        print("  report         Print last results")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "generate":
        generate_audio()
    elif cmd == "run":
        ids = None
        if "--ids" in sys.argv:
            arg_idx = sys.argv.index("--ids")
            if arg_idx + 1 < len(sys.argv):
                id_spec = sys.argv[arg_idx + 1]
                if "-" in id_spec:
                    start, end = id_spec.split("-")
                    ids = list(range(int(start), int(end) + 1))
                else:
                    ids = [int(x) for x in id_spec.split(",")]
        run_assessment(ids)
    elif cmd == "report":
        print_report()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
