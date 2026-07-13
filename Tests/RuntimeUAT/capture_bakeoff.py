#!/usr/bin/env python3
"""capture_bakeoff.py — #1377 Phase 2 capture-backend bake-off driver.

Drives each candidate capture engine (force-selected via the DEBUG policy key)
through a real recording on the running dev app, then scores it from the app's
OWN logs: the empirical transcript (`app.log` CORRECTION_DEBUG, via
wispr_eyes.test_recording) PLUS the capture-side actual-bound-device evidence
(`bt-route.log` CAPTURE_EVIDENCE). It never reads the clipboard — the founder
deletes the app's clipboard pastings, so the log is the only trustworthy verdict
source (tools-and-apps.md RULE: uat-verdicts-from-app-log).

Reuses `wispr_eyes.test_recording()` / `tts()` — no reinvented recording or TTS
loop (validation-discipline.md RULE: use-existing-uat-harness-first).

WHY log evidence, not app-derived telemetry: `effective_transport` /
`captureSourceType` are app intent (and the XPC proxy masks the backend as
`"xpc_proxy"`). The unforgeable proof a candidate captured the INTENDED device is
(a) a correct, non-silent transcript of a known sentence spoken into that device,
and (b) the source's own CAPTURE_EVIDENCE line naming the device that actually
bound. The bench runs IN-PROCESS (`useXPCAudioService=false`) so the backend tag
and bound-device log are real, not proxy-masked (plan §3.5).

COLD-STATE protocol (the Phase 0 lesson — one candidate must not warm the device
for the next): between candidates, quit the dev app, set the candidate's policy,
relaunch, and confirm the speaker is actually producing audio into the INTENDED
device. This module is the driver; the human runs the matrix trial-by-trial and
switches the input device in Settings (the device selection lives in the shared
`com.enviouswispr.app` store — the founder's real settings — so the harness never
pokes it; it only sets the per-build dev knobs).

Candidates: C (AVAudioEngine, device-override) and D (AUHAL, device-pinned).

#1524 RETIRED candidate A (AVCaptureSession): the backend it forced was deleted
with the capture-session source, which had been unreachable on the ship path
since D won the #1377 bake-off. C and D are retained deliberately — they are the
A/B instrument for validating the step-3b cutover.
"""

import argparse
import json
import os
import subprocess
import time

import wispr_eyes

# --- Constants ---------------------------------------------------------------

# Per-build dev store (DEBUG dev bundle id). `useXPCAudioService` and the bench
# policy key both read UserDefaults.standard, which for the dev build resolves
# here — the SAME suite (SettingsManager.swift:455). NOT the shared
# `com.enviouswispr.app` store where user prefs (incl. the input device) live.
DEV_DEFAULTS_DOMAIN = "com.enviouswispr.app.dev"
POLICY_KEY = "captureSourcePolicyOverride"
XPC_KEY = "useXPCAudioService"

BT_ROUTE_LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/bt-route.log")
EVIDENCE_MARKER = "CAPTURE_EVIDENCE"
# A source logs this when a pinned target UID is not a live device and it
# silently records the built-in instead. A trial that fell back did NOT capture
# the requested device, so it must FAIL even if a transcript landed.
FALLBACK_MARKER = "not found — falling back"

# Checkout root derived from THIS script's location (…/<checkout>/Tests/RuntimeUAT/
# capture_bakeoff.py → <checkout>), so the scorecard lands in the checkout being
# validated — never a hardcoded sibling worktree (Codex r1).
_CHECKOUT_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
DEFAULT_SCORECARD = os.path.join(_CHECKOUT_ROOT, ".validation", "capture-bakeoff-scorecard.json")

# candidate -> force policy + expected backend tag.
CANDIDATES = {
    "C": {
        "policy": "forceEngine",
        "backend": "av_audio_engine",
        "desc": "AVAudioEngine, device-override",
    },
    # Reinstated 2026-07-08 (slice 2b) — spiked against A per the competitive
    # research in docs/audits/2026-07-08-capture-engine-competitive-research.md.
    "D": {
        "policy": "forceHALDeviceInput",
        "backend": "hal_device_input",
        "desc": "AUHAL (kAudioUnitSubType_HALOutput), device-targeted",
    },
}

DEFAULT_SENTENCE = "Let's grab coffee before the standup and review the pull request together."


# --- Bench configuration (per-build dev knobs only) --------------------------


def configure_candidate(candidate):
    """Write the per-build dev knobs to force-select a candidate IN-PROCESS.

    Both keys are cold — read at launch only — so the caller MUST relaunch the
    dev app after this returns. Does not touch the shared user-settings store.
    """
    c = CANDIDATES[candidate]
    subprocess.run(
        ["defaults", "write", DEV_DEFAULTS_DOMAIN, XPC_KEY, "-bool", "false"], check=True
    )
    subprocess.run(
        ["defaults", "write", DEV_DEFAULTS_DOMAIN, POLICY_KEY, c["policy"]], check=True
    )
    print(f"[bakeoff] candidate {candidate} ({c['desc']}) → policy={c['policy']}, in-process ON.")
    print("[bakeoff] RELAUNCH the dev app now (cold flags), then select the target device in "
          "Settings and confirm you will speak into it.")


def clear_bench():
    """Remove the bench dev knobs, restoring the normal (XPC + .automatic) path.

    Deleting the keys makes the app read its defaults: XPC on, policy .automatic.
    Relaunch afterward to return to the shipped path.
    """
    for key in (POLICY_KEY, XPC_KEY):
        subprocess.run(
            ["defaults", "delete", DEV_DEFAULTS_DOMAIN, key],
            check=False,  # a missing key is fine
        )
    print("[bakeoff] bench knobs cleared. Relaunch for the normal XPC/.automatic path.")


# --- Capture-side evidence (bt-route.log CAPTURE_EVIDENCE) --------------------


def _bt_route_line_count():
    """Number of lines currently in bt-route.log (snapshot boundary)."""
    try:
        with open(BT_ROUTE_LOG, "r", errors="replace") as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def _read_bt_route_lines(since_line=0):
    try:
        with open(BT_ROUTE_LOG, "r", errors="replace") as f:
            return f.readlines()[since_line:]
    except FileNotFoundError:
        return []


def _parse_evidence(line):
    """Parse a CAPTURE_EVIDENCE line's `key=value` tokens into a dict.

    Source lines (per backend) carry backend/boundUID/boundDeviceID/
    boundTransport/requestedUID/benchBypass (the engine also carries bindOK);
    the manager companion carries backend/requestedUID/policy/generation.
    Tokens are whitespace-delimited
    EXCEPT `boundDevice`, whose value is a localized device name that may contain
    spaces — the Swift side emits it LAST, so we take everything from
    `boundDevice=` to end-of-line as its value and tokenize only the prefix."""
    idx = line.find(EVIDENCE_MARKER)
    if idx < 0:
        return None
    payload = line[idx + len(EVIDENCE_MARKER):].strip()
    fields = {}
    # `[manager]` tag (if present) then key=value tokens.
    if payload.startswith("[manager]"):
        fields["_kind"] = "manager"
        payload = payload[len("[manager]"):].strip()
    else:
        fields["_kind"] = "source"
    # Split off the space-containing tail field first.
    dev_idx = payload.find("boundDevice=")
    if dev_idx >= 0:
        fields["boundDevice"] = payload[dev_idx + len("boundDevice="):].strip()
        payload = payload[:dev_idx].strip()
    for token in payload.split():
        if "=" in token:
            k, v = token.split("=", 1)
            fields[k] = v
    return fields


def read_new_evidence(since_line):
    """All CAPTURE_EVIDENCE records appended after `since_line`."""
    records = []
    for line in _read_bt_route_lines(since_line):
        rec = _parse_evidence(line)
        if rec:
            records.append(rec)
    return records


def _fell_back_since(since_line):
    """True if a pinned-target fallback-to-built-in was logged in the window."""
    return any(FALLBACK_MARKER in ln for ln in _read_bt_route_lines(since_line))


def _device_bound_as_requested(source_ev, requested_uid, fell_back):
    """Did the trial bind the DEVICE it was asked to (not a fallback / wrong mic)?

    A transcript alone is not enough — a run that fell back to the built-in mic
    still transcribes fine, so the bench must reject it (cloud review P2). Uses
    the unforgeable CAPTURE_EVIDENCE:
      - both candidates log an explicit `boundUID` (the exact bound device) →
        must equal `requested_uid`. This proves the REQUESTED device bound, not
        merely a non-built-in one (a USB/virtual mic would pass a transport-only
        check).
      - the engine additionally logs `bindOK` (did AudioUnitSetProperty accept
        the device). A failed set does NOT throw and leaves boundUID == requested
        anyway, so a specific-device engine trial must ALSO have `bindOK=true`;
        `bindOK=false` means the HAL rejected the device even though we asked for
        it (cloud review P2). Candidate A (capture-session) has no `bindOK` —
        AVCaptureSession's added input IS the bound device, so boundUID suffices.
      - `boundTransport` is a fallback only when a UID could not be resolved
        (`boundUID` absent) → for a specific requested device the transport must
        not be `built_in`.
    When no specific device was requested (`auto`/`built_in`), built-in is the
    correct outcome and the check passes.
    """
    if fell_back:
        return False
    if requested_uid in ("", "auto", "built_in"):
        return True  # no specific device asked; built-in is the right result
    if source_ev is None:
        return False  # cannot confirm what bound
    bound_uid = source_ev.get("boundUID")
    if bound_uid is not None:
        # Engine reports whether the HAL actually accepted the device; a failed
        # set leaves boundUID == requested, so bindOK must gate it. Capture-
        # session has no bindOK key (None) → boundUID equality alone suffices.
        bind_ok = source_ev.get("bindOK")
        if bind_ok is not None and bind_ok != "true":
            return False
        return bound_uid == requested_uid
    transport = source_ev.get("boundTransport")
    if transport is not None:
        return transport != "built_in"
    return False  # no device evidence → cannot confirm → fail closed


# --- Trial + scorecard -------------------------------------------------------


def run_trial(candidate, device_label, sentence=DEFAULT_SENTENCE, expect=None):
    """Run one (candidate x device) trial on the ALREADY-CONFIGURED, RELAUNCHED
    dev app and return a scorecard row.

    Preconditions (human, cold-state): configure_candidate() run, app relaunched,
    the intended device selected in Settings, quiet room, speaker will actually
    talk. This function does not switch devices or relaunch — it drives the
    recording and reads the verdict from the logs.
    """
    expected_backend = CANDIDATES[candidate]["backend"]
    expected_policy = CANDIDATES[candidate]["policy"]
    since = _bt_route_line_count()

    transcript_pass = wispr_eyes.test_recording(sentence=sentence, expect=expect)

    evidence = read_new_evidence(since)
    source_ev = next((e for e in evidence if e.get("_kind") == "source"), None)
    manager_ev = next((e for e in evidence if e.get("_kind") == "manager"), None)

    bound_backend = (source_ev or manager_ev or {}).get("backend", "")
    bound_device = (source_ev or {}).get("boundDevice") or (source_ev or {}).get("boundUID")
    bound_transport = (source_ev or {}).get("boundTransport", "")
    requested_uid = (source_ev or manager_ev or {}).get("requestedUID", "")
    bound_policy = (manager_ev or {}).get("policy", "")

    backend_ok = bound_backend == expected_backend
    # The FORCED policy must actually be active. Without this, a trial run while
    # the app is on `.automatic` (dev defaults not applied / not relaunched) can
    # still pass: under Bluetooth output the automatic route ALSO yields
    # `hal_device_input`, so candidate D's backend check would match and credit D
    # for behavior the automatic route produced, not the forced candidate (cloud
    # review P2). Requires the manager companion row (in-process only).
    policy_ok = bound_policy == expected_policy
    evidence_found = source_ev is not None
    fell_back = _fell_back_since(since)
    device_ok = _device_bound_as_requested(source_ev, requested_uid, fell_back)
    # Gate: correct non-silent transcript AND the expected backend actually bound
    # AND the FORCED policy was active AND the requested DEVICE actually bound (no
    # built-in fallback / wrong mic). A transcript captured by the built-in after
    # a fallback, or under the automatic route, is a FAIL, not a pass (cloud
    # review P2) — the whole point is proving a candidate grabs the target.
    gate_pass = (
        bool(transcript_pass)
        and backend_ok
        and policy_ok
        and evidence_found
        and device_ok
        and not fell_back
    )

    row = {
        "candidate": candidate,
        "candidate_desc": CANDIDATES[candidate]["desc"],
        "device_label": device_label,
        "sentence": sentence,
        "transcript_pass": bool(transcript_pass),
        "expected_backend": expected_backend,
        "bound_backend": bound_backend,
        "backend_ok": backend_ok,
        "expected_policy": expected_policy,
        "bound_policy": bound_policy,
        "policy_ok": policy_ok,
        "bound_device": bound_device,
        "bound_transport": bound_transport,
        "requested_uid": requested_uid,
        "evidence_found": evidence_found,
        "device_ok": device_ok,
        "fell_back": fell_back,
        "gate_pass": gate_pass,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    _print_row(row)
    return row


def _print_row(row):
    verdict = "PASS" if row["gate_pass"] else "FAIL"
    print("\n" + "=" * 64)
    print(f"[bakeoff] candidate {row['candidate']} ({row['candidate_desc']}) "
          f"× {row['device_label']}: {verdict}")
    print(f"  transcript_pass = {row['transcript_pass']}")
    print(f"  backend         = {row['bound_backend']} (expected {row['expected_backend']}, "
          f"ok={row['backend_ok']})")
    print(f"  policy          = {row['bound_policy']} (expected {row['expected_policy']}, "
          f"ok={row['policy_ok']})")
    if not row["policy_ok"]:
        print("  WARN: forced policy NOT active — measuring the automatic route, not the "
              "candidate (set dev defaults + relaunch)")
    print(f"  bound device    = {row['bound_device']}  transport={row['bound_transport']}")
    print(f"  requested uid   = {row['requested_uid']}")
    print(f"  device bound OK  = {row['device_ok']}   fell_back_to_builtin = {row['fell_back']}")
    if row["fell_back"] or not row["device_ok"]:
        print("  WARN: requested device did NOT bind (fallback / wrong mic) — NOT a valid capture")
    print(f"  evidence found  = {row['evidence_found']}")
    if not row["evidence_found"]:
        print("  WARN: no CAPTURE_EVIDENCE — is this a DEBUG dev build with in-process capture?")
    print("=" * 64)


def write_scorecard(rows, path):
    """Append rows to a scorecard JSON (list). Merges with any existing file so a
    matrix run across multiple invocations accumulates."""
    existing = []
    if os.path.exists(path):
        try:
            with open(path) as f:
                existing = json.load(f)
        except (json.JSONDecodeError, OSError):
            existing = []
    existing.extend(rows)
    parent = os.path.dirname(path)
    if parent:  # bare filename → dirname is "" → nothing to create
        os.makedirs(parent, exist_ok=True)
    with open(path, "w") as f:
        json.dump(existing, f, indent=2)
    print(f"[bakeoff] scorecard → {path} ({len(existing)} rows total)")


# --- CLI ---------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="#1377 capture-backend bake-off driver")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_cfg = sub.add_parser("configure", help="force-select a candidate (per-build dev knobs)")
    p_cfg.add_argument("candidate", choices=sorted(CANDIDATES))

    sub.add_parser("clear", help="remove bench knobs (restore XPC/.automatic)")

    p_trial = sub.add_parser("trial", help="run one trial on the configured+relaunched app")
    p_trial.add_argument("candidate", choices=sorted(CANDIDATES))
    p_trial.add_argument("device_label", help="human label for the selected device, e.g. 'bose-bt'")
    p_trial.add_argument("--sentence", default=DEFAULT_SENTENCE)
    p_trial.add_argument("--expect", default=None, help="substring the transcript must contain")
    p_trial.add_argument("--scorecard", default=DEFAULT_SCORECARD)

    args = ap.parse_args()
    if args.cmd == "configure":
        configure_candidate(args.candidate)
    elif args.cmd == "clear":
        clear_bench()
    elif args.cmd == "trial":
        row = run_trial(
            args.candidate, args.device_label, sentence=args.sentence, expect=args.expect
        )
        write_scorecard([row], args.scorecard)


if __name__ == "__main__":
    main()
