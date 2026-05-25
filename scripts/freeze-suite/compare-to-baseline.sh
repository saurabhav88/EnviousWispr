#!/usr/bin/env bash
# compare-to-baseline.sh — Freeze-suite variance-log harness (epic #827, PR-4b.3)
#
# Replays the five committed clips (`scripts/freeze-suite/clips/*.wav`) through
# TODAY's app and summarizes how each (clip × engine × run) compares against
# `baseline.json`. **This is an OBSERVATIONAL harness, not a strict pass/fail
# merge gate.** Always exits 0 unless a fundamental precondition is missing
# (baseline file gone, app not running, etc.). Per-run variance is written to
# `compare-output.json`; one JSON line per (clip × engine) is appended to
# `variance-log.jsonl` so drift can be reviewed across the PR-4b.4 → PR-5 →
# PR-10 arc and human-judged at epic close ("real regression or nothing burger?").
#
# === Why variance-log, not pass/fail (LESSON: freeze-suite-reframed-as-variance-log) ===
# An earlier draft of this harness gated the merge on per-clip exact-match
# parity. Empirical validation in a quiet room showed two back-to-back captures
# of the same .wav clip can produce different `no_speech` flags on silence-
# adjacent clips (sudden-burst, silence, background-noise) — Parakeet and
# WhisperKit ARE deterministic on byte-identical input, but the speaker→mic
# capture loop is not. The lexical clips (`normal-speech`, `mumbled-speech`)
# DID match cleanly today on both engines — those are the cases that map to
# real user behavior. Hence the split: lexical-clip drift gets flagged for
# review; edge-clip drift is logged but not flagged.
#
# === What flags `needs_review` (founder-relevant signals) ===
#   1. Text drift on `normal-speech` or `mumbled-speech` — user-visible quality
#      regression in the case that matters.
#   2. Pipeline failed to reach terminal — orchestration didn't complete the
#      session at all (kernel mis-handled a state transition).
#   3. Backend fallback fired — a Parakeet run emitted the WhisperKit
#      completion marker, or vice versa (kernel routed to the wrong engine).
#
# Edge-clip variance (silence, sudden-burst, background-noise: `no_speech`
# flips, outcome-rule misses) is logged for visibility but does NOT flag —
# the speaker→mic loop noise floor on those clips exceeds any meaningful
# kernel-orchestration signal.
#
# === Phase 2 follow-up ===
# Today's 5 clips only partially cover the founder's stated user-behavior
# checklist (first-word capture, tail-not-clipped, long-form batch, short
# dictation, empty-press hallucination guard). Phase 2 adds 3 new clips for
# (1) first-word capture, (2) tail-not-clipped, (3) long-form batch — tracked
# as a separate issue, not blocking PR-4b.4.
#
# === Environment assumptions ===
#   - macOS + Apple-silicon generation (stamped into output for cross-machine
#     visibility).
#   - A DEBUG build of EnviousWispr (`/wispr-rebuild-debug`) is RUNNING with
#     Debug mode enabled (writes ~/Library/Logs/EnviousWispr/app.log — release
#     builds skip the log file per `tools-and-apps.md §2a`).
#   - Clip SHA-256 — verified against baseline.json; SHA divergence aborts
#     (clips edited on disk, or wrong checkout).
#   - Normalization ruleset version — must equal baseline's
#     `normalization_ruleset_version` (currently 1, per
#     `Tests/EnviousWisprTests/Pipeline/Simulator/FreezeSuiteNormalization.swift`).
#
# === WhisperKit policy ===
#   - Default: if WhisperKit model is not installed, WK clips are marked
#     `skipped` in the variance log; Parakeet still runs.
#   - Founder override: `EW_FREEZE_REQUIRE_WK=1` makes WK-unavailable a
#     `needs_review` flag.
#
# === Settings side-effect ===
#   Script saves the pre-run `selectedBackend`, runs Parakeet then WhisperKit,
#   and restores the pre-run backend in a `finally` block. Developer ends up
#   on the same backend they started with.
#
# === Exit codes (deliberately narrow — almost always 0) ===
#    0 — variance log written; review compare-output.json for `needs_review`.
#    2 — baseline.json missing, schema mismatch, capture_status != "captured",
#        OR clip SHA mismatch (preconditions for any meaningful comparison
#        broken; aborts before app interaction).
#    3 — cannot connect to the running app (Debug build not launched).
#
# === Outputs ===
#    scripts/freeze-suite/compare-output.json — current run's full variance
#    snapshot, overwritten each run.
#    scripts/freeze-suite/variance-log.jsonl — append-only across runs; one
#    JSON object per (clip × engine × run timestamp) so cross-PR drift is
#    visible. Reviewed by founder at epic close.
#
# === Usage ===
#    scripts/freeze-suite/compare-to-baseline.sh
#    EW_FREEZE_REQUIRE_WK=1 scripts/freeze-suite/compare-to-baseline.sh

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/../.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/scripts/freeze-suite"
CLIPS_DIR="${FIXTURE_DIR}/clips"
RUNTIME_UAT="${REPO_ROOT}/Tests/RuntimeUAT"
BASELINE_JSON="${FIXTURE_DIR}/baseline.json"
COMPARE_OUTPUT="${FIXTURE_DIR}/compare-output.json"
VARIANCE_LOG="${FIXTURE_DIR}/variance-log.jsonl"
REQUIRE_WK="${EW_FREEZE_REQUIRE_WK:-0}"

OS_VERSION="$(sw_vers -productVersion)"
CHIP="$(sysctl -n machdep.cpu.brand_string)"
SCRIPT_SHA="$(shasum -a 256 "${SCRIPT_PATH}" | cut -d' ' -f1)"

echo "[freeze-suite] variance-log comparison starting"
echo "[freeze-suite] macOS ${OS_VERSION} | ${CHIP} | require_wk=${REQUIRE_WK}"

python3 - "$FIXTURE_DIR" "$CLIPS_DIR" "$RUNTIME_UAT" "$BASELINE_JSON" "$COMPARE_OUTPUT" \
  "$VARIANCE_LOG" "$REQUIRE_WK" "$OS_VERSION" "$CHIP" "$SCRIPT_SHA" <<'PYEOF'
import datetime
import hashlib
import json
import os
import subprocess
import sys
import time
import unicodedata

(
    fixture_dir, clips_dir, runtime_uat, baseline_path, compare_output_path,
    variance_log_path, require_wk_str, os_version, chip, script_sha,
) = sys.argv[1:11]
require_wk = require_wk_str not in ("", "0", "false", "False")

sys.path.insert(0, runtime_uat)
import wispr_eyes as we  # noqa: E402

# --- exit codes -------------------------------------------------------------
EXIT_OK = 0  # variance-log harness: 0 is the dominant case, even with drift
EXIT_BASELINE_BAD = 2
EXIT_APP_NOT_RUNNING = 3

# --- log markers (must match capture-baseline.sh + TextProcessingRunner) ----
RAW_MARKER = "CORRECTION_DEBUG [RAW ASR] "
COMPLETION_PARAKEET = "Pipeline timing TOTAL"
COMPLETION_WHISPERKIT = "WhisperKit pipeline TOTAL"
NO_SPEECH_MARKERS = (
    "VAD gate: no speech",
    "ASR empty (no speech detected)",
    "No audio captured",
    "No audio detected",
)
# WhisperKitPipeline.swift:469-472 — `state = .error("Model load failed: ...")`.
WK_LOAD_FAILED_MARKERS = (
    "Model load failed",
    "WhisperKit model not cached",
)

CLIPS = ["normal-speech", "silence", "background-noise", "mumbled-speech", "sudden-burst"]
# (baseline label, switch_backend arg, selectedBackend rawValue)
ENGINES = [
    ("parakeet", "parakeet", "parakeet"),
    ("whisperKit", "whisperkit", "whisperKit"),
]
DEFAULTS_DOMAIN = "com.enviouswispr.app.dev"

# Clips whose drift in TEXT maps to user-visible quality regression. Drift on
# other clips is logged but not flagged for review (speaker→mic loop noise
# floor exceeds the kernel-orchestration signal on edge clips).
USER_RELEVANT_CLIPS = {"normal-speech", "mumbled-speech"}


# --- normalization (port of FreezeSuiteNormalization.swift ruleset v1) ------
NORMALIZATION_RULESET_VERSION = 1
_APOS_VARIANTS = ("’", "‘", "ʼ")
_QUOTE_MARKS = set('"' "“”«»")
_STRIPPED_PUNCT = set(",;:()[]{}/")
_TERMINAL_PUNCT = set(".!?…")


def normalize(s: str) -> str:
    """Mirrors FreezeSuiteNormalization.normalize. GOLDEN_VECTORS self-test
    below fails fast if this drifts from Swift."""
    text = unicodedata.normalize("NFC", s)
    for variant in _APOS_VARIANTS:
        text = text.replace(variant, "'")
    text = "".join(ch for ch in text if ch not in _QUOTE_MARKS)
    text = text.lower()
    text = "".join(ch for ch in text if ch not in _STRIPPED_PUNCT)
    text = text.replace("​", " ")
    text = " ".join(text.split())
    while text and text[-1] in _TERMINAL_PUNCT:
        text = text[:-1]
    return text.strip()


# Anchored against Swift FreezeSuiteNormalizationTests — adding a case here
# without the equivalent Swift #expect breaks the cross-check by design.
_GOLDEN_VECTORS = [
    ("Hello World", "hello world"),
    ("  hello   world  ", "hello world"),
    ("hello\tworld", "hello world"),
    ("hello world", "hello world"),  # NBSP
    ("hello​world", "hello world"),  # ZWSP
    ("hello world.", "hello world"),
    ("u.s. army", "u.s. army"),
    ("hello...", "hello"),
    ("hello!?", "hello"),
    ("hello…", "hello"),
    ("can’t", "can't"),
    ('"hello"', "hello"),
    ("“hello”", "hello"),
    ("hello (world)", "hello world"),
    ("a/b", "ab"),
    ("one, two; three", "one two three"),
    ("sub-second latency", "sub-second latency"),
    ("café", normalize("café")),  # NFC composed == decomposed
    ("a — b", "a — b"),  # em-dash survives
    ("“It’s done.”", "it's done"),
]


def _run_golden_vector_self_test():
    failures = []
    for idx, (raw, expected) in enumerate(_GOLDEN_VECTORS):
        got = normalize(raw)
        if got != expected:
            failures.append(f"  [{idx}] input={raw!r} expected={expected!r} got={got!r}")
    if failures:
        sys.stderr.write(
            "[freeze-suite] FATAL — Python normalization drift vs Swift ruleset v1:\n"
            + "\n".join(failures) + "\n"
            "Fix scripts/freeze-suite/compare-to-baseline.sh::normalize before "
            "proceeding. Do NOT bump baseline.json's normalization_ruleset_version "
            "without also bumping the Swift constant.\n")
        sys.exit(EXIT_BASELINE_BAD)


_run_golden_vector_self_test()


# --- helpers ----------------------------------------------------------------
def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def current_backend_rawvalue() -> str:
    r = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, "selectedBackend"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def ensure_backend(switch_arg: str, target_rawvalue: str) -> None:
    """No-op tap is rejected by AXPress (capture-baseline.sh:142-156)."""
    if current_backend_rawvalue() == target_rawvalue:
        print(f"[freeze-suite] already on {switch_arg} — no UI switch needed")
        we.connect()
        we.close_window()
        time.sleep(6.0)
        return
    we.switch_backend(switch_arg, wait=6.0)


def capture_run(clip_path: str, timeout: float) -> dict:
    log_state = we._snapshot_log_state()
    we.test_recording(audio=clip_path, timeout=timeout)
    time.sleep(0.6)  # let the async RAW-ASR log Task flush
    lines, _ = we._read_new_log_lines(log_state) if log_state else ([], None)
    text = "\n".join(lines)
    raw_hits = [ln.split(RAW_MARKER, 1)[1].strip()
                for ln in lines if RAW_MARKER in ln]
    no_speech = any(m in text for m in NO_SPEECH_MARKERS)
    hard_error = None
    for ln in lines:
        if "state = .error(" in ln or "captureError" in ln:
            if not any(m in ln for m in NO_SPEECH_MARKERS):
                hard_error = ln.strip()
                break
    wk_load_failed = any(m in text for m in WK_LOAD_FAILED_MARKERS)
    return {
        "raw_hits": raw_hits,
        "no_speech": no_speech,
        "hard_error": hard_error,
        "completion_parakeet": COMPLETION_PARAKEET in text,
        "completion_whisperkit": COMPLETION_WHISPERKIT in text,
        "wk_load_failed": wk_load_failed,
        "log_line_count": len(lines),
    }


# --- variance summarization (the heart of the variance-log shape) ----------
def summarize_variance(clip: str, engine_label: str,
                       baseline_engine: dict, observed_runs: list) -> dict:
    """Compare observed runs against baseline. Categorize variance. Decide
    whether THIS (clip × engine) flags `needs_review`.

    Categories:
      - "match" — observed values match baseline at the per-run level.
      - "text-drift" — raw_transcript differs (normalized). Flagged for review
        only when clip is in USER_RELEVANT_CLIPS.
      - "no-speech-flip" — at least one run pair disagrees on no_speech.
        Logged, NOT flagged (edge-clip noise floor).
      - "orchestration-fail" — some observed run failed to reach terminal.
        Always flagged (kernel could have mis-handled a state transition).
      - "backend-fallback" — Parakeet run emitted WhisperKit marker (or vice
        versa). Always flagged (kernel could have mis-routed).
    """
    b_runs = baseline_engine.get("runs", [])
    findings: list = []
    needs_review = False

    if len(b_runs) != len(observed_runs):
        findings.append({
            "category": "orchestration-fail",
            "detail": f"baseline has {len(b_runs)} runs, observed has {len(observed_runs)}",
        })
        needs_review = True
        return {"variance_category": "orchestration-fail", "findings": findings,
                "needs_review": needs_review, "observed_runs": observed_runs}

    # Orchestration fail — any observed run that didn't reach terminal.
    for i, o in enumerate(observed_runs):
        if not o.get("completed"):
            findings.append({
                "category": "orchestration-fail",
                "detail": f"run{i}: pipeline did not reach terminal",
            })
            needs_review = True

    # Hard-error terminal — `completed=True` because hard-error counts as
    # terminal in the main loop's terminal check, but a `.error(...)` terminal
    # IS founder-relevant on every clip regardless of user-relevance class.
    for i, o in enumerate(observed_runs):
        if o.get("hard_error"):
            findings.append({
                "category": "hard-error",
                "detail": f"run{i}: hard error terminal — {o.get('hard_error')}",
            })
            needs_review = True

    # Ambiguous RAW ASR — more than one `CORRECTION_DEBUG [RAW ASR]` line on
    # a single run means we don't know which is the real text. capture-baseline.sh
    # treats this as fail-closed (`:275-276`); the replay harness must too,
    # otherwise drift can be silently classified as match when raw_hits[0]
    # happens to equal baseline.
    for i, o in enumerate(observed_runs):
        if o.get("raw_hits_count", 0) > 1:
            findings.append({
                "category": "ambiguous-raw",
                "detail": (f"run{i}: {o['raw_hits_count']} RAW ASR log lines "
                           "— ambiguous text; only first was retained for comparison"),
            })
            needs_review = True

    # Backend fallback — emitted the wrong engine's completion marker (or BOTH
    # markers on a single run, which is the same orchestration bug). The
    # `capture_run` dict has completion_parakeet / completion_whisperkit; this
    # observed_run carries `backend_marker` ∈ {"parakeet", "whisperkit", "both", None}.
    # A Parakeet-engine run is "fallback" if it emitted the WhisperKit marker
    # OR both markers; symmetric for WhisperKit.
    for i, o in enumerate(observed_runs):
        marker = o.get("backend_marker")
        if engine_label == "parakeet" and marker in ("whisperkit", "both"):
            findings.append({
                "category": "backend-fallback",
                "detail": (f"run{i}: Parakeet run emitted WhisperKit completion marker"
                           if marker == "whisperkit"
                           else f"run{i}: Parakeet run emitted BOTH completion markers"),
            })
            needs_review = True
        elif engine_label == "whisperKit" and marker in ("parakeet", "both"):
            findings.append({
                "category": "backend-fallback",
                "detail": (f"run{i}: WhisperKit run emitted Parakeet completion marker"
                           if marker == "parakeet"
                           else f"run{i}: WhisperKit run emitted BOTH completion markers"),
            })
            needs_review = True

    # Text drift — normalized raw_transcript per-run comparison.
    text_drift_runs = []
    for i in range(len(b_runs)):
        b_text = b_runs[i].get("raw_transcript") or ""
        o_text = observed_runs[i].get("raw_transcript") or ""
        if normalize(b_text) != normalize(o_text):
            text_drift_runs.append({
                "run_index": i,
                "baseline": b_text,
                "observed": o_text,
            })
    if text_drift_runs:
        is_user_relevant = clip in USER_RELEVANT_CLIPS
        findings.append({
            "category": "text-drift",
            "user_relevant": is_user_relevant,
            "runs": text_drift_runs,
        })
        if is_user_relevant:
            needs_review = True

    # no-speech flip — per-run comparison. Logged, NEVER flagged on its own.
    ns_flip_runs = []
    for i in range(len(b_runs)):
        if b_runs[i].get("no_speech") != observed_runs[i].get("no_speech"):
            ns_flip_runs.append({
                "run_index": i,
                "baseline_no_speech": b_runs[i].get("no_speech"),
                "observed_no_speech": observed_runs[i].get("no_speech"),
            })
    if ns_flip_runs:
        findings.append({
            "category": "no-speech-flip",
            "user_relevant": False,
            "runs": ns_flip_runs,
        })

    if not findings:
        category = "match"
    elif any(f["category"] in ("orchestration-fail", "backend-fallback",
                               "hard-error", "ambiguous-raw") for f in findings):
        category = "orchestration-fail"
    elif any(f["category"] == "text-drift" for f in findings):
        category = "text-drift"
    else:
        category = "no-speech-flip"

    return {
        "variance_category": category,
        "findings": findings,
        "needs_review": needs_review,
        "observed_runs": observed_runs,
    }


# --- baseline load + validation ---------------------------------------------
if not os.path.exists(baseline_path):
    sys.stderr.write(
        f"[freeze-suite] FAIL — baseline missing: {baseline_path}\n"
        "Re-capture via: scripts/freeze-suite/capture-baseline.sh\n")
    sys.exit(EXIT_BASELINE_BAD)

try:
    with open(baseline_path) as f:
        baseline = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    sys.stderr.write(f"[freeze-suite] FAIL — baseline unreadable: {e}\n")
    sys.exit(EXIT_BASELINE_BAD)

baseline_schema = baseline.get("schema_version")
baseline_ruleset = baseline.get("normalization_ruleset_version")
baseline_status = baseline.get("capture_status")
if baseline_schema != 2:
    sys.stderr.write(
        f"[freeze-suite] FAIL — baseline schema_version={baseline_schema} (expected 2)\n")
    sys.exit(EXIT_BASELINE_BAD)
if baseline_ruleset != NORMALIZATION_RULESET_VERSION:
    sys.stderr.write(
        f"[freeze-suite] FAIL — baseline normalization_ruleset_version="
        f"{baseline_ruleset} (harness has {NORMALIZATION_RULESET_VERSION}).\n"
        "Bring the harness ruleset version in line with the baseline, OR "
        "re-capture the baseline against the new ruleset.\n")
    sys.exit(EXIT_BASELINE_BAD)
if baseline_status != "captured":
    sys.stderr.write(
        f"[freeze-suite] FAIL — baseline capture_status={baseline_status!r} "
        "(expected 'captured'). Re-capture before comparing.\n")
    sys.exit(EXIT_BASELINE_BAD)

# --- clip SHA verification (abort if clips don't match baseline) -----------
sha_failures = []
for clip in CLIPS:
    wav_path = os.path.join(clips_dir, f"{clip}.wav")
    if not os.path.exists(wav_path):
        sha_failures.append(f"{clip}: missing at {wav_path}")
        continue
    expected = baseline["clips"][clip].get("wav_sha256")
    actual = sha256(wav_path)
    if expected != actual:
        sha_failures.append(
            f"{clip}: SHA mismatch baseline={expected} actual={actual}")
if sha_failures:
    sys.stderr.write("[freeze-suite] FAIL — clip SHA divergence (abort before app interaction):\n")
    for m in sha_failures:
        sys.stderr.write(f"  - {m}\n")
    sys.stderr.write(
        "Re-clone clips from git OR re-capture baseline if the clip set "
        "intentionally changed.\n")
    sys.exit(EXIT_BASELINE_BAD)

# --- app connect + pre-run backend snapshot --------------------------------
# Catch BaseException — wispr_eyes.connect() raises SystemExit(1) on failure,
# which is NOT caught by `except Exception` (SystemExit inherits from
# BaseException, not Exception). Without BaseException catch, the script would
# exit 1 instead of the documented EXIT_APP_NOT_RUNNING=3.
try:
    we.connect()
except BaseException as e:
    sys.stderr.write(
        f"[freeze-suite] FAIL — cannot connect to running app: {e!r}\n"
        "Launch a DEBUG build first: /wispr-rebuild-debug\n")
    sys.exit(EXIT_APP_NOT_RUNNING)

# Verify app.log is available AND actively being written to. The harness
# extracts RAW ASR, completion markers, and no_speech signals from
# `~/Library/Logs/EnviousWispr/app.log`, which is only written by DEBUG builds
# with Debug mode enabled (per `tools-and-apps.md §2a`). Two failure modes:
#   (a) Log missing entirely — `_snapshot_log_state()` returns None.
#   (b) Stale log on disk from a prior debug session, but the currently
#       running app is release/debug-off, so the log file exists but is not
#       growing. The replay would still run and produce a noisy
#       all-orchestration-fail variance log.
# Detect (a) immediately; detect (b) via a 2-second probe that compares log
# file size before/after — a running debug app emits at least one log line
# within that window (UI events, idle ticks).
_log_state = we._snapshot_log_state()
if _log_state is None:
    sys.stderr.write(
        "[freeze-suite] FAIL — app.log not available. The harness needs a DEBUG\n"
        "build with Debug mode enabled (writes ~/Library/Logs/EnviousWispr/app.log).\n"
        "Release builds skip log file output. Rebuild via /wispr-rebuild-debug.\n")
    sys.exit(EXIT_APP_NOT_RUNNING)

_log_path = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
try:
    _size_before = os.path.getsize(_log_path)
except OSError:
    _size_before = -1
time.sleep(2.0)
try:
    _size_after = os.path.getsize(_log_path)
except OSError:
    _size_after = -1
if _size_after <= _size_before:
    sys.stderr.write(
        f"[freeze-suite] FAIL — app.log is not growing ({_size_before}→{_size_after}\n"
        "bytes over 2s). The running app is likely a release build OR Debug mode\n"
        "is off OR app.log is stale from a prior session. The harness depends on\n"
        "live log output for RAW ASR + completion markers. Rebuild via\n"
        "/wispr-rebuild-debug and ensure Debug mode is enabled in-app.\n")
    sys.exit(EXIT_APP_NOT_RUNNING)

pre_run_backend = current_backend_rawvalue()
print(f"[freeze-suite] pre-run backend = {pre_run_backend!r} (will restore at end)")

# Settings drift check — baseline captures settings_snapshot (VAD / debug /
# streaming / correction toggles). When today's defaults differ, the
# comparison isn't apples-to-apples; unrelated config changes can create
# false `needs_review` cells or mask real drift. We don't ABORT — fits the
# variance-log philosophy of "document drift, decide at epic close" — but we
# capture the diff in the report's top-level `settings_drift` field and flag
# it for review so the founder sees the mismatch alongside per-clip cells.
def _baseline_settings_drift() -> dict:
    baseline_settings = baseline.get("settings_snapshot") or {}
    drift = {}
    # Exclusions:
    #   `_defaults_domain` — metadata, not a real setting.
    #   `selectedBackend` — the harness force-sets this per-engine via
    #     `ensure_backend`, so its pre-run value differing from baseline's
    #     last-touched value is expected and harmless. Comparing it here just
    #     fires false `needs_review` flags.
    skip = {"selectedBackend"}
    keys = [k for k in baseline_settings.keys()
            if not k.startswith("_") and k not in skip]
    for key in keys:
        r = subprocess.run(
            ["defaults", "read", DEFAULTS_DOMAIN, key],
            capture_output=True, text=True)
        current = r.stdout.strip() if r.returncode == 0 else None
        baseline_value = baseline_settings.get(key)
        if current != baseline_value:
            drift[key] = {"baseline": baseline_value, "current": current}
    return drift


settings_drift = _baseline_settings_drift()
if settings_drift:
    print(f"[freeze-suite] WARN — {len(settings_drift)} setting(s) drift from baseline; "
          "see compare-output.json `settings_drift` for details")

runs_per_engine = int(baseline["provenance"].get("runs_per_engine", 2))
run_timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

# --- variance-log run -------------------------------------------------------
report = {
    "schema_version": 2,
    "epic": "#827 PR-4b.3 freeze-suite variance log",
    "text_stage": "raw_asr_before_finalizer",
    "normalization_ruleset_version": NORMALIZATION_RULESET_VERSION,
    "user_relevant_clips": sorted(USER_RELEVANT_CLIPS),
    "compared_against": {
        "baseline_path": os.path.relpath(baseline_path, fixture_dir),
        "baseline_commit_sha": baseline.get("provenance", {}).get("commit_sha"),
        "baseline_captured_at": baseline.get("provenance", {}).get("captured_at"),
    },
    "provenance": {
        "commit_sha": subprocess.run(
            ["git", "-C", os.path.dirname(fixture_dir), "rev-parse", "HEAD"],
            capture_output=True, text=True).stdout.strip(),
        "os_version": os_version,
        "chip": chip,
        "compare_script_sha256": script_sha,
        "compared_at": run_timestamp,
        "runs_per_engine": runs_per_engine,
        "require_wk": require_wk,
    },
    "pre_run_backend": pre_run_backend,
    "settings_drift": settings_drift,
    "clips": {c: {"engines": {}} for c in CLIPS},
}

wk_skip_reason = None
needs_review_total = 0
log_lines_to_append = []

# Settings drift is a top-level review-worthy signal — incremented once into
# the global counter so the founder sees the mismatch alongside per-clip
# cells. Logged as a synthetic line so variance-log.jsonl carries it across PRs.
if settings_drift:
    needs_review_total += 1
    log_lines_to_append.append({
        "compared_at": run_timestamp,
        "category": "settings-drift",
        "needs_review": True,
        "drift_keys": sorted(settings_drift.keys()),
    })

try:
    for engine_label, switch_arg, target_rawvalue in ENGINES:
        print(f"\n[freeze-suite] === engine: {engine_label} ===")

        if engine_label == "whisperKit" and wk_skip_reason:
            for c in CLIPS:
                entry = {"status": "skipped", "skip_reason": wk_skip_reason}
                report["clips"][c]["engines"][engine_label] = entry
                log_lines_to_append.append({
                    "compared_at": run_timestamp, "clip": c, "engine": engine_label,
                    "status": "skipped", "skip_reason": wk_skip_reason,
                })
            continue

        try:
            ensure_backend(switch_arg, target_rawvalue)
        except Exception as e:  # noqa: BLE001
            msg = f"backend select failed: {e}"
            if engine_label == "whisperKit":
                wk_skip_reason = msg
                print(f"[freeze-suite] WK unavailable — {msg}")
                for c in CLIPS:
                    entry = {"status": "skipped", "skip_reason": wk_skip_reason}
                    report["clips"][c]["engines"][engine_label] = entry
                    log_lines_to_append.append({
                        "compared_at": run_timestamp, "clip": c, "engine": engine_label,
                        "status": "skipped", "skip_reason": wk_skip_reason,
                    })
                continue
            sys.stderr.write(f"[freeze-suite] Parakeet backend select failed — flagging for review: {e}\n")
            for c in CLIPS:
                entry = {"status": "error", "error": msg, "needs_review": True}
                report["clips"][c]["engines"][engine_label] = entry
                log_lines_to_append.append({
                    "compared_at": run_timestamp, "clip": c, "engine": engine_label,
                    "status": "error", "error": msg, "needs_review": True,
                })
                needs_review_total += 1
            break

        for clip in CLIPS:
            clip_path = os.path.join(clips_dir, f"{clip}.wav")
            print(f"[freeze-suite] {engine_label} / {clip}")
            observed_runs = []
            wk_load_failed_first_clip = False
            for run_idx in range(runs_per_engine):
                model_state = "cold" if run_idx == 0 else "warm"
                r = capture_run(clip_path, timeout=25.0)
                if engine_label == "whisperKit" and r["wk_load_failed"]:
                    wk_load_failed_first_clip = True

                completed = (
                    r["completion_parakeet"] or r["completion_whisperkit"]
                    or r["no_speech"] or bool(r["hard_error"])
                )
                # Retry-once on "no terminal signal" — matches capture-baseline.sh
                # :262-266 symmetry: the speaker→mic→log path can transiently
                # miss the completion marker on a single run. A run that has
                # no terminal twice in a row is a real signal; one miss is
                # flake. Backend fallback / ambiguous raw / hard error are NOT
                # transient and are not retried.
                if not completed:
                    print(f"[freeze-suite]   no terminal signal on run{run_idx} — retrying once")
                    r = capture_run(clip_path, timeout=25.0)
                    if engine_label == "whisperKit" and r["wk_load_failed"]:
                        wk_load_failed_first_clip = True
                    completed = (
                        r["completion_parakeet"] or r["completion_whisperkit"]
                        or r["no_speech"] or bool(r["hard_error"])
                    )
                if r["completion_parakeet"] and not r["completion_whisperkit"]:
                    backend_marker = "parakeet"
                elif r["completion_whisperkit"] and not r["completion_parakeet"]:
                    backend_marker = "whisperkit"
                elif r["completion_parakeet"] and r["completion_whisperkit"]:
                    backend_marker = "both"
                else:
                    backend_marker = None

                observed_runs.append({
                    "run_index": run_idx,
                    "model_state": model_state,
                    "raw_transcript": r["raw_hits"][0] if r["raw_hits"] else None,
                    "raw_hits_count": len(r["raw_hits"]),
                    "no_speech": r["no_speech"],
                    "completed": completed,
                    "backend_marker": backend_marker,
                    "hard_error": r["hard_error"],
                    "log_line_count": r["log_line_count"],
                })

            # First WK clip + load-failed marker → mark WK skipped for the rest.
            if (engine_label == "whisperKit" and wk_load_failed_first_clip
                    and clip == CLIPS[0]):
                wk_skip_reason = "whisperkit-model-not-installed"
                print(f"[freeze-suite] WK model load failed on first clip "
                      f"— marking WK skipped (reason: {wk_skip_reason})")
                entry = {"status": "skipped", "skip_reason": wk_skip_reason,
                         "observed_runs": observed_runs}
                report["clips"][clip]["engines"][engine_label] = entry
                log_lines_to_append.append({
                    "compared_at": run_timestamp, "clip": clip, "engine": engine_label,
                    "status": "skipped", "skip_reason": wk_skip_reason,
                })
                for rc in CLIPS[CLIPS.index(clip) + 1:]:
                    skip_entry = {"status": "skipped", "skip_reason": wk_skip_reason}
                    report["clips"][rc]["engines"][engine_label] = skip_entry
                    log_lines_to_append.append({
                        "compared_at": run_timestamp, "clip": rc, "engine": engine_label,
                        "status": "skipped", "skip_reason": wk_skip_reason,
                    })
                break

            baseline_engine = baseline["clips"][clip]["engines"][engine_label]
            summary = summarize_variance(clip, engine_label, baseline_engine, observed_runs)
            entry = {"status": "compared", **summary}
            report["clips"][clip]["engines"][engine_label] = entry
            log_lines_to_append.append({
                "compared_at": run_timestamp, "clip": clip, "engine": engine_label,
                "status": "compared",
                "variance_category": summary["variance_category"],
                "needs_review": summary["needs_review"],
            })
            if summary["needs_review"]:
                needs_review_total += 1
                print(f"[freeze-suite]   {clip} variance={summary['variance_category']} — NEEDS REVIEW")
            else:
                print(f"[freeze-suite]   {clip} variance={summary['variance_category']}")

        # WK availability check: if first WK clip flagged the load-failure, the
        # remaining clips were handled inside the loop. Otherwise continue.
        if wk_skip_reason and engine_label == "whisperKit":
            continue

    # WK-unavailable + EW_FREEZE_REQUIRE_WK=1 → flag for review. Update BOTH
    # report cells (compare-output.json) AND the in-memory log_lines_to_append
    # (variance-log.jsonl) so the append-only log carries the same signal —
    # otherwise the cross-PR log silently loses the require_wk failure.
    if wk_skip_reason and require_wk:
        for clip in CLIPS:
            cell = report["clips"][clip]["engines"].get("whisperKit", {})
            cell["needs_review"] = True
            needs_review_total += 1
        for entry in log_lines_to_append:
            if entry.get("engine") == "whisperKit" and entry.get("status") == "skipped":
                entry["needs_review"] = True
finally:
    if pre_run_backend in ("parakeet", "whisperKit"):
        switch_target = "parakeet" if pre_run_backend == "parakeet" else "whisperkit"
        try:
            print(f"\n[freeze-suite] restoring pre-run backend: {pre_run_backend}")
            ensure_backend(switch_target, pre_run_backend)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(
                f"[freeze-suite] WARN — could not restore pre-run backend "
                f"({pre_run_backend}): {e}\n")

# --- summary, output, append to variance-log -------------------------------
report["summary"] = {
    "needs_review_count": needs_review_total,
    "whisperkit_skip_reason": wk_skip_reason,
}

with open(compare_output_path, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")

with open(variance_log_path, "a") as f:
    for line in log_lines_to_append:
        f.write(json.dumps(line) + "\n")

print(f"\n[freeze-suite] wrote: {compare_output_path}")
print(f"[freeze-suite] appended {len(log_lines_to_append)} entries to: {variance_log_path}")
if needs_review_total > 0:
    print(f"[freeze-suite] {needs_review_total} cell(s) flagged needs_review — "
          "inspect compare-output.json")
else:
    print(f"[freeze-suite] no cells flagged needs_review — all user-relevant "
          "clips matched + no orchestration faults")
sys.exit(EXIT_OK)
PYEOF

echo "[freeze-suite] done"
