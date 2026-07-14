#!/usr/bin/env python3
"""capture_bakeoff.py — heart-path capture verification driver (#1533 cutover).

After the 3b cutover there is ONE capture backend (`HALDeviceInputSource`) and
the `.automatic` route is the only route. The former #1377 bake-off force-policy
control plane (candidates C/D, `captureSourcePolicyOverride`) is DELETED with the
second backend, so this driver no longer force-selects a candidate — it measures
the AUTOMATIC path on the cutover build and confirms every device binds through
HAL.

Drives a real recording on the running dev app, then scores it from the app's
OWN logs: the empirical transcript (`app.log` CORRECTION_DEBUG, via
wispr_eyes.test_recording) PLUS the capture-side actual-bound-device evidence
(`bt-route.log` CAPTURE_EVIDENCE). It never reads the clipboard — the founder
deletes the app's clipboard pastings, so the log is the only trustworthy verdict
source (tools-and-apps.md RULE: uat-verdicts-from-app-log).

Reuses `wispr_eyes.test_recording()` / `tts()` — no reinvented recording or TTS
loop (validation-discipline.md RULE: use-existing-uat-harness-first).

WHY log evidence, not app-derived telemetry: the app-side `captureSourceType` is
masked `"xpc_proxy"` on the default XPC path (plan §2.5 boundary 3). The
unforgeable proof a recording captured the INTENDED device is (a) a correct,
non-silent transcript of a known sentence, and (b) the CAPTURE_EVIDENCE line
naming the device that actually bound and the real backend. That line is written
by the DEBUG capture manager in whichever process hosts it, so it reports the
REAL backend on BOTH the in-process and the default XPC path — the `"xpc_proxy"`
mask only hides the app-side `captureSourceType`, which this bench never reads.
So this validator does NOT require in-process mode; `configure` remains available
to force it (e.g. to also unmask the app-side tag), and every trial records which
path actually produced the evidence.

COLD-STATE protocol: between devices, quit the dev app, relaunch, select the
target device in Settings, and confirm the speaker is actually producing audio
into the INTENDED device. This module is the driver; the human runs the matrix
device-by-device and switches the input device in Settings (device selection
lives in the shared `com.enviouswispr.app` store — the founder's real settings —
so the harness never pokes it; it only sets the per-build dev knobs).
"""

import argparse
import json
import os
import subprocess
import time

import wispr_eyes

# --- Constants ---------------------------------------------------------------

# Per-build dev store (DEBUG dev bundle id). `useXPCAudioService` reads
# UserDefaults.standard, which for the dev build resolves here
# (SettingsManager.swift). NOT the shared `com.enviouswispr.app` store where user
# prefs (incl. the input device) live.
DEV_DEFAULTS_DOMAIN = "com.enviouswispr.app.dev"
XPC_KEY = "useXPCAudioService"

BT_ROUTE_LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/bt-route.log")
EVIDENCE_MARKER = "CAPTURE_EVIDENCE"
# A source logs this when a pinned target UID is not a live device and it
# silently records the built-in instead. A trial that fell back did NOT capture
# the requested device, so it must FAIL even if a transcript landed.
FALLBACK_MARKER = "not found — falling back"

# The sole capture backend after the 3b cutover.
EXPECTED_BACKEND = "hal_device_input"

# Checkout root derived from THIS script's location (…/<checkout>/Tests/RuntimeUAT/
# capture_bakeoff.py → <checkout>), so the scorecard lands in the checkout being
# validated — never a hardcoded sibling worktree.
_CHECKOUT_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
DEFAULT_SCORECARD = os.path.join(_CHECKOUT_ROOT, ".validation", "capture-bakeoff-scorecard.json")

DEFAULT_SENTENCE = "Let's grab coffee before the standup and review the pull request together."


# --- Bench configuration (per-build dev knobs only) --------------------------


def read_uses_xpc():
    """The build's live `useXPCAudioService` (default true when unset). Read-only.

    Tells a trial which path actually produced its CAPTURE_EVIDENCE — the evidence
    is real either way, but the row records the path so a reader knows.
    """
    out = subprocess.run(
        ["defaults", "read", DEV_DEFAULTS_DOMAIN, XPC_KEY],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return True  # unset → the shipped default is XPC on
    return out.stdout.strip() not in ("0", "false", "NO")


def configure_in_process():
    """OPTIONAL: force in-process capture (useXPCAudioService=false).

    Not required for a valid measurement — CAPTURE_EVIDENCE is real on both the
    in-process and the default XPC path (see module docstring). Use this only to
    also exercise/unmask the in-process path. The key is cold — read at launch
    only — so the caller MUST relaunch the dev app after this returns. Does not
    touch the shared user-settings store.
    """
    subprocess.run(
        ["defaults", "write", DEV_DEFAULTS_DOMAIN, XPC_KEY, "-bool", "false"], check=True
    )
    print("[bakeoff] in-process capture ON (useXPCAudioService=false).")
    print("[bakeoff] RELAUNCH the dev app now (cold flag), then select the target device in "
          "Settings and confirm you will speak into it.")


def clear_bench():
    """Remove the bench dev knob, restoring the normal (XPC) path.

    Deleting the key makes the app read its default: XPC on. Relaunch afterward
    to return to the shipped path.
    """
    subprocess.run(
        ["defaults", "delete", DEV_DEFAULTS_DOMAIN, XPC_KEY],
        check=False,  # a missing key is fine
    )
    print("[bakeoff] bench knob cleared. Relaunch for the normal XPC path.")


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

    Source lines carry backend/boundUID/boundDeviceID/boundTransport/requestedUID;
    the manager companion carries backend/requestedUID/generation. Tokens are
    whitespace-delimited EXCEPT `boundDevice`, whose value is a localized device
    name that may contain spaces — the Swift side emits it LAST, so we take
    everything from `boundDevice=` to end-of-line as its value and tokenize only
    the prefix."""
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
    still transcribes fine, so the bench must reject it. Uses the unforgeable
    CAPTURE_EVIDENCE `boundUID` (the exact bound device) → must equal
    `requested_uid`. This proves the REQUESTED device bound, not merely a
    non-built-in one (a USB/virtual mic would pass a transport-only check).
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
        return bound_uid == requested_uid
    transport = source_ev.get("boundTransport")
    if transport is not None:
        return transport != "built_in"
    return False  # no device evidence → cannot confirm → fail closed


# --- Trial + scorecard -------------------------------------------------------


def run_trial(device_label, sentence=DEFAULT_SENTENCE, expect=None):
    """Run one device trial on the ALREADY-RELAUNCHED in-process dev app and
    return a scorecard row.

    Preconditions (human, cold-state): configure_in_process() run, app relaunched,
    the intended device selected in Settings, quiet room, speaker will actually
    talk. This function does not switch devices or relaunch — it drives the
    recording and reads the verdict from the logs.
    """
    since = _bt_route_line_count()
    uses_xpc = read_uses_xpc()

    transcript_pass = wispr_eyes.test_recording(sentence=sentence, expect=expect)

    evidence = read_new_evidence(since)
    source_ev = next((e for e in evidence if e.get("_kind") == "source"), None)
    manager_ev = next((e for e in evidence if e.get("_kind") == "manager"), None)

    bound_backend = (source_ev or manager_ev or {}).get("backend", "")
    bound_device = (source_ev or {}).get("boundDevice") or (source_ev or {}).get("boundUID")
    bound_transport = (source_ev or {}).get("boundTransport", "")
    requested_uid = (source_ev or manager_ev or {}).get("requestedUID", "")

    backend_ok = bound_backend == EXPECTED_BACKEND
    evidence_found = source_ev is not None
    fell_back = _fell_back_since(since)
    device_ok = _device_bound_as_requested(source_ev, requested_uid, fell_back)
    # Gate: correct non-silent transcript AND HAL actually bound AND the requested
    # DEVICE actually bound (no built-in fallback / wrong mic). A transcript
    # captured by the built-in after a fallback is a FAIL — the whole point is
    # proving the automatic route grabs the target through HAL.
    gate_pass = (
        bool(transcript_pass)
        and backend_ok
        and evidence_found
        and device_ok
        and not fell_back
    )

    row = {
        "device_label": device_label,
        "sentence": sentence,
        "measured_path": "xpc" if uses_xpc else "in_process",
        "transcript_pass": bool(transcript_pass),
        "expected_backend": EXPECTED_BACKEND,
        "bound_backend": bound_backend,
        "backend_ok": backend_ok,
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
    print(f"[bakeoff] automatic route × {row['device_label']}: {verdict}")
    print(f"  measured path   = {row['measured_path']} (evidence is real on both)")
    print(f"  transcript_pass = {row['transcript_pass']}")
    print(f"  backend         = {row['bound_backend']} (expected {row['expected_backend']}, "
          f"ok={row['backend_ok']})")
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
    ap = argparse.ArgumentParser(description="#1533 heart-path capture verification driver")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("configure", help="OPTIONAL: force in-process capture (per-build dev knob)")
    sub.add_parser("clear", help="remove the bench knob (restore XPC)")

    p_trial = sub.add_parser("trial", help="run one device trial on the relaunched app")
    p_trial.add_argument("device_label", help="human label for the selected device, e.g. 'bose-bt'")
    p_trial.add_argument("--sentence", default=DEFAULT_SENTENCE)
    p_trial.add_argument("--expect", default=None, help="substring the transcript must contain")
    p_trial.add_argument("--scorecard", default=DEFAULT_SCORECARD)

    args = ap.parse_args()
    if args.cmd == "configure":
        configure_in_process()
    elif args.cmd == "clear":
        clear_bench()
    elif args.cmd == "trial":
        row = run_trial(args.device_label, sentence=args.sentence, expect=args.expect)
        write_scorecard([row], args.scorecard)


if __name__ == "__main__":
    main()
