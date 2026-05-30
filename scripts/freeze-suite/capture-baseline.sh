#!/usr/bin/env bash
# capture-baseline.sh — Freeze-suite baseline capture (epic #827, PR-3 §3.8)
#
# Captures a frozen "before" snapshot of how TODAY's unmodified Parakeet and
# WhisperKit pipelines handle five fixed audio clips. PR-4 / PR-5 replay the
# kernel-migrated paths and assert parity against this snapshot.
#
# This is runtime DATA CAPTURE, not behaviour validation — it snapshots current
# behaviour, it proves nothing. It ships only committed data + this script + a
# `.gitignore` line; the kernel's CI gate never runs it (PR-3 plan §3.9).
#
# Procedure (PR-3 plan §3.8):
#   1. Use the five committed clips in `clips/` (regenerated only if absent —
#      the committed `.wav` is the frozen artefact, its SHA-256 is recorded).
#   2. Run each clip through TranscriptionPipeline (Parakeet) and
#      WhisperKitPipeline (WhisperKit) via `wispr_eyes` against a DEBUG build
#      (debug build required for app.log evidence — tools-and-apps.md §2a).
#      Each clip runs TWICE per engine.
#   3. Collect provenance: commit SHA + clean-tree, per-clip SHA-256, OS +
#      Apple-silicon generation, captured_at, this script's own hash.
#   4. Extract, per run, the RAW ASR text BEFORE the limb steps from a single
#      explicit log marker (`CORRECTION_DEBUG [RAW ASR]`, identical for both
#      backends — TextProcessingRunner.swift:73), the terminal outcome, and the
#      no-speech flag. Fail closed on any corruption signal (§3.8 item 5).
#   5. Write baseline.json with capture_status="captured" only when all
#      5 clips x 2 engines x 2 runs pass the fail-closed checks.
#
# Usage:  scripts/freeze-suite/capture-baseline.sh
#
# Prerequisites: a DEBUG build of EnviousWispr running (`/wispr-rebuild-debug`),
# Debug mode enabled in-app (writes ~/Library/Logs/EnviousWispr/app.log), and
# the OpenAI key reachable by the `tts()` helper (only if a clip is missing).

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/../.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/scripts/freeze-suite"
CLIPS_DIR="${FIXTURE_DIR}/clips"
RUNTIME_UAT="${REPO_ROOT}/Tests/RuntimeUAT"
BASELINE_JSON="${FIXTURE_DIR}/baseline.json"
RUNS_PER_ENGINE=2

mkdir -p "${CLIPS_DIR}"

echo "[freeze-suite] capture starting — fixture dir: ${FIXTURE_DIR}"

COMMIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
if [ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]; then
  CLEAN_TREE="true"
else
  CLEAN_TREE="false"
  echo "[freeze-suite] WARNING: dirty tree — baseline records clean_tree=false"
fi
OS_VERSION="$(sw_vers -productVersion)"
CHIP="$(sysctl -n machdep.cpu.brand_string)"
SCRIPT_SHA="$(shasum -a 256 "${SCRIPT_PATH}" | cut -d' ' -f1)"
echo "[freeze-suite] commit ${COMMIT_SHA} clean=${CLEAN_TREE} | macOS ${OS_VERSION} | ${CHIP}"

python3 - "$FIXTURE_DIR" "$CLIPS_DIR" "$RUNTIME_UAT" "$BASELINE_JSON" "$RUNS_PER_ENGINE" \
  "$COMMIT_SHA" "$CLEAN_TREE" "$OS_VERSION" "$CHIP" "$SCRIPT_SHA" <<'PYEOF'
import hashlib, json, os, sys, time, wave, subprocess, datetime

fixture_dir, clips_dir, runtime_uat, out_path, runs_per_engine = sys.argv[1:6]
commit_sha, clean_tree, os_version, chip, script_sha = sys.argv[6:11]
runs_per_engine = int(runs_per_engine)

sys.path.insert(0, runtime_uat)
import wispr_eyes as we

# Clip order is fixed; engine order is fixed (Parakeet then WhisperKit).
CLIPS = ["normal-speech", "silence", "background-noise", "mumbled-speech", "sudden-burst"]
# (baseline label, switch_backend arg, selectedBackend rawValue)
ENGINES = [
    ("parakeet", "parakeet", "parakeet"),
    ("whisperKit", "whisperkit", "whisperKit"),
]

# Per-clip expected-outcome rule — written explicitly, never inferred (§3.8).
OUTCOME_RULE = {
    "normal-speech": "lexical-parity",
    "mumbled-speech": "lexical-parity-if-stable-else-outcome-parity",
    "silence": "noSpeech-parity",
    "background-noise": "noSpeech-parity-or-transcript-parity",
    "sudden-burst": "noSpeech-parity",
}
# Clips whose expected text is graded lexically — an empty RAW ASR is a failure.
LEXICAL_CLIPS = {"normal-speech", "mumbled-speech"}

# A no-speech outcome family — the pipeline ran cleanly and found no transcribable
# speech. This is a valid terminal, NOT a hard error, for any clip.
NO_SPEECH_MARKERS = (
    "VAD gate: no speech",
    "ASR empty (no speech detected)",
    "No audio captured",
    "No audio detected",
)
RAW_MARKER = "CORRECTION_DEBUG [RAW ASR] "
COMPLETION_PARAKEET = "Pipeline timing TOTAL"
COMPLETION_WHISPERKIT = "WhisperKit pipeline TOTAL"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def wav_meta(path):
    with wave.open(path, "rb") as w:
        return {
            "sample_rate_hz": w.getframerate(),
            "channels": w.getnchannels(),
            "sample_width_bytes": w.getsampwidth(),
            "duration_s": round(w.getnframes() / w.getframerate(), 3),
        }


def settings_snapshot():
    """The app settings in force at capture — PR-4/PR-5 replay under these
    (§3.8). Read straight from the app's UserDefaults domain."""
    keys = [
        "selectedBackend", "recordingMode", "llmProvider", "llmModel", "ollamaModel",
        "vadAutoStop", "vadSilenceTimeout", "vadSensitivity", "vadEnergyGate",
        "wordCorrectionEnabled", "fillerRemovalEnabled", "emojiFormatterEnabled",
        "useStreamingASR", "warmEnginePolicy", "modelUnloadPolicy",
        "autoCopyToClipboard", "restoreClipboardAfterPaste", "isDebugModeEnabled",
    ]
    # The DEBUG build this capture runs against is the dev bundle — its
    # UserDefaults live under the `.dev` domain (the dev bundle id built by
    # scripts/build-dev-app.sh).
    domain = "com.enviouswispr.app.dev"
    snap = {"_defaults_domain": domain}
    for k in keys:
        r = subprocess.run(["defaults", "read", domain, k],
                           capture_output=True, text=True)
        snap[k] = r.stdout.strip() if r.returncode == 0 else None
    return snap


def ensure_backend(switch_arg, target_rawvalue):
    """Select `switch_arg` as the active ASR engine. The Settings segmented
    picker is a no-op tap when the engine is already selected — and an AXPress
    on an already-selected segment reports failure — so skip the UI switch when
    the app already sits on the target backend."""
    cur = subprocess.run(
        ["defaults", "read", "com.enviouswispr.app.dev", "selectedBackend"],
        capture_output=True, text=True).stdout.strip()
    if cur == target_rawvalue:
        print(f"[freeze-suite] already on {switch_arg} — no UI switch needed")
        we.connect()
        we.close_window()
        time.sleep(6.0)  # parity with switch_backend's model-load settle
        return
    we.switch_backend(switch_arg, wait=6.0)


def capture_run(clip_path, timeout):
    """Drive one recording of `clip_path` through the live app and return the
    parsed log evidence for that run. The orchestration (menu start, afplay,
    menu stop, completion wait) reuses wispr_eyes.test_recording; the log lines
    are read independently so the baseline never depends on that helper's
    return value (which is polished-before-raw — §3.8)."""
    log_state = we._snapshot_log_state()
    we.test_recording(audio=clip_path, timeout=timeout)
    # test_recording blocks until pipeline completion/timeout — the log now
    # holds the full run. Give the async RAW-ASR log Task a beat to flush.
    time.sleep(0.6)
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
    return {
        "raw_hits": raw_hits,
        "no_speech": no_speech,
        "hard_error": hard_error,
        "completion_parakeet": COMPLETION_PARAKEET in text,
        "completion_whisperkit": COMPLETION_WHISPERKIT in text,
        "log_line_count": len(lines),
    }


# --- provenance -------------------------------------------------------------
missing = [c for c in CLIPS if not os.path.exists(os.path.join(clips_dir, f"{c}.wav"))]
if missing:
    print(f"[freeze-suite] FAIL — committed clips missing: {missing}")
    print("[freeze-suite]   regenerate via scripts/freeze-suite (clip generator) and re-commit.")
    sys.exit(1)

clip_meta = {}
for c in CLIPS:
    wav = os.path.join(clips_dir, f"{c}.wav")
    clip_meta[c] = {"wav_sha256": sha256(wav), **wav_meta(wav)}

baseline = {
    "schema_version": 2,
    "epic": "#827 PR-3 freeze-suite baseline",
    "capture_status": "pending",
    "text_stage": "raw_asr_before_finalizer",
    "normalization_ruleset_version": 1,
    "provenance": {
        "commit_sha": commit_sha,
        "clean_tree": clean_tree == "true",
        "os_version": os_version,
        "chip": chip,
        "capture_script_sha256": script_sha,
        "captured_at": None,
        "runs_per_engine": runs_per_engine,
    },
    "settings_snapshot": settings_snapshot(),
    "clips": {},
}

# --- capture loop -----------------------------------------------------------
failures = []
for c in CLIPS:
    baseline["clips"][c] = {
        "expected_outcome_rule": OUTCOME_RULE[c],
        **clip_meta[c],
        "engines": {},
    }

for engine_label, switch_arg, target_rawvalue in ENGINES:
    print(f"\n[freeze-suite] === engine: {engine_label} ===")
    try:
        ensure_backend(switch_arg, target_rawvalue)
    except Exception as e:  # noqa: BLE001
        failures.append(f"{engine_label}: backend select failed — {e}")
        continue

    for c in CLIPS:
        clip_path = os.path.join(clips_dir, f"{c}.wav")
        # auto-stop is recorded as null: menu-based recording is stopped by the
        # Stop tap, never by VAD auto-stop (§11.1) — no clip "should auto-stop".
        eng_entry = {
            "model_state_by_run": [],
            "runs": [],
            "raw_transcript": None,
            "vad_auto_stop_frame_index": None,
            "no_speech": None,
            "unstable_fields": [],
        }
        for run_idx in range(runs_per_engine):
            model_state = "cold" if run_idx == 0 else "warm"
            print(f"[freeze-suite] {engine_label} / {c} / run {run_idx} ({model_state})")
            r = capture_run(clip_path, timeout=25.0)
            completed = (r["completion_parakeet"] or r["completion_whisperkit"]
                         or r["no_speech"] or bool(r["hard_error"]))
            # "No terminal signal" is the transient-stall signature (a WhisperKit
            # cold-run stall — plan §3.9). Retry the run ONCE; a run that stalls
            # twice is a real failure. Backend fallback / ambiguous raw / hard
            # error are not transient and are not retried.
            if not completed:
                print("[freeze-suite]   no terminal signal — retrying run once")
                r = capture_run(clip_path, timeout=25.0)
                completed = (r["completion_parakeet"] or r["completion_whisperkit"]
                             or r["no_speech"] or bool(r["hard_error"]))

            run_failures = []
            if not completed:
                run_failures.append("no terminal signal — clip did not run or model unavailable")
            if engine_label == "parakeet" and r["completion_whisperkit"]:
                run_failures.append("backend fallback — WhisperKit marker on a Parakeet run")
            if engine_label == "whisperKit" and r["completion_parakeet"] and not r["completion_whisperkit"]:
                run_failures.append("backend fallback — Parakeet marker on a WhisperKit run")
            if len(r["raw_hits"]) > 1:
                run_failures.append(f"{len(r['raw_hits'])} RAW ASR log lines — ambiguous raw text")
            if r["hard_error"]:
                run_failures.append(f"hard error terminal: {r['hard_error']}")
            raw_text = r["raw_hits"][0] if r["raw_hits"] else None
            if c in LEXICAL_CLIPS and not raw_text:
                run_failures.append("lexical-parity clip produced no RAW ASR text")

            eng_entry["model_state_by_run"].append(model_state)
            eng_entry["runs"].append({
                "run_index": run_idx,
                "model_state": model_state,
                "raw_transcript": raw_text,
                "no_speech": r["no_speech"],
                "completed": completed,
                "log_line_count": r["log_line_count"],
                "failures": run_failures,
            })
            failures.extend(f"{engine_label}/{c}/run{run_idx}: {m}" for m in run_failures)

        runs = eng_entry["runs"]
        raws = [x["raw_transcript"] for x in runs]
        nos = [x["no_speech"] for x in runs]
        if len(set(raws)) > 1:
            eng_entry["unstable_fields"].append("raw_transcript")
        else:
            eng_entry["raw_transcript"] = raws[0]
        if len(set(nos)) > 1:
            eng_entry["unstable_fields"].append("no_speech")
        else:
            eng_entry["no_speech"] = nos[0]
        baseline["clips"][c]["engines"][engine_label] = eng_entry

# --- finalize ---------------------------------------------------------------
if failures:
    baseline["capture_status"] = "failed"
    baseline["capture_failures"] = failures
    with open(out_path, "w") as f:
        json.dump(baseline, f, indent=2)
        f.write("\n")
    print(f"\n[freeze-suite] FAIL — {len(failures)} fail-closed condition(s):")
    for m in failures:
        print(f"  - {m}")
    print(f"[freeze-suite] wrote baseline (capture_status=failed): {out_path}")
    sys.exit(1)

baseline["capture_status"] = "captured"
baseline["provenance"]["captured_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(out_path, "w") as f:
    json.dump(baseline, f, indent=2)
    f.write("\n")
print(f"\n[freeze-suite] OK — all {len(CLIPS)} clips x {len(ENGINES)} engines x "
      f"{runs_per_engine} runs passed.")
print(f"[freeze-suite] wrote baseline (capture_status=captured): {out_path}")
PYEOF

echo "[freeze-suite] done"
