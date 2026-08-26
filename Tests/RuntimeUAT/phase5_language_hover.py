"""The language chip's dwell, and that hovering pauses it (#2377 chunk 6, C6B).

Phase 5 deleted the chip's own timer, hover state and `onAutoDismiss`; the
director's clock is now the only thing that dismisses it. This row proves that
from outside: the chip must expire on its own, and must SURVIVE past that
deadline while the pointer is on it.

**PAIRED, and the no-hover arm is the control rather than a warm-up.** A hover arm
alone cannot fail in the direction that matters — a chip that never expires at all
also "survives hovering". The two arms differ in exactly one action, so the
comparison is what carries the claim:

    arm A (no hover)  ->  gone at ~6s
    arm B (hover)     ->  still present well past 6s, then gone after leaving

The dwell is the catalog's, not a number invented here:
`.after(seconds: 6, pausesOnHover: true)` at `PillCatalog.swift:242`, on a chip
requesting `.fixed(340)` width and 56pt height.

**Staging it needs a real non-English dictation, not a seam.** The presenter
refuses anything but `.consistentHighConfidence` and drops English outright
(`LanguageSuggestionPresenter.swift:128-131`), so the chip is produced by
dictating Spanish with the language mode on Auto — which is also the only way to
prove the production trigger still reaches the new clock.

The presenter persists a suppression set and dismissal counts
(`languageChipSuppressedLanguages`), so both are snapshotted and restored; a
language suppressed by an earlier run produces no chip and the row would read as
the dwell being broken.

**THE LANGUAGE CHIP IS UNREACHABLE ON PARAKEET, AND NOTHING SAYS SO.**
`languageDetector.detect(...)` has exactly ONE caller in the tree,
`WhisperKitEngineAdapter.swift:721`. Parakeet performs no language identification
at all, so on the default backend the detector never receives an accept, the
counter never increments, and no chip can ever appear. Measured: seven Spanish
takes on Parakeet produced zero chips and zero `LID result` lines, while every
`LID result` in the log's history carries `[WhisperKitEngineAdapter]`.
Nothing errors and nothing is logged, so the row reads as the dwell being broken.
This row therefore switches the backend, and ASSERTS it from the app's own
`Recording started. Backend: ...` line rather than from the value it wrote —
the same discipline the geometry row needs for the words capability.

**ONE DICTATION CANNOT ARM THE CHIP.** The detector emits
`.consistentHighConfidence` only after THREE consecutive high-confidence accepts
of the same non-English language — threshold 3, confidence floor 0.85, counter
in-memory and reset on app launch (`LanguageDetector.swift:106-111`). A run that
does not reach the threshold reports no chip, which reads as the dwell being
broken rather than as the trigger never having armed.
So each arm dictates until a chip arrives and REPORTS how many takes it needed:
only a `.highAuto` accept at >= 0.85 increments, a `.mediumAuto` is a no-op, and
identical audio does not clear the floor every time — measured 0.85, 0.91, 0.91,
then 0.65. Three takes is the BEST case, not the expected one.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_geometry_relaunch as g  # noqa: E402
import phase5_paste_target as pt  # noqa: E402
import phase5_record_key as rk  # noqa: E402
import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
OUT = UAT / "language-hover"
OUT.mkdir(parents=True, exist_ok=True)

DEV_DOMAIN = "com.enviouswispr.app.dev"
SHARED_DOMAIN = "com.enviouswispr.app"
STATE_KEYS = ["languageChipSuppressedLanguages", "languageChipDismissalCounts"]
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
# THE RAW VALUE IS THE ENUM CASE NAME, camelCase. `ASRBackendType` declares
# `case whisperKit` with no explicit raw value (`ASRResult.swift:6`), and the
# reader is `ASRBackendType(rawValue: defaults.string(...) ?? "") ?? default`
# (`SettingsManager.swift:739`) — so `"whisperkit"` parses to nil and SILENTLY
# falls back to Parakeet. Measured: eight takes recorded on parakeet after a
# write that `defaults read` echoed back happily. Same plausible-value trap as
# writing a Bool as `1`.
REQUIRED_BACKEND = "whisperKit"

# Spanish, ordinary prose. Long enough for the detector to reach
# `consistentHighConfidence` rather than a single-word guess.
SPANISH = ("Buenos días, hoy quiero hablar sobre el informe trimestral de la empresa. "
           "Los resultados han superado nuestras expectativas en todas las regiones. "
           "El equipo ha trabajado muy duro durante estos últimos meses.")

CHIP_DWELL = 6.0          # PillCatalog.swift:242
CHIP_WIDTH = 340          # requestedWidth: .fixed(340)


class Chips(threading.Thread):
    """Watch for the language chip and record when it is present.

    Identified by its REQUESTED WIDTH, which the catalog fixes at 340 — the chip
    is a different presentation from the recording pill and appears after it has
    gone, so the appear/disappear lifecycle classifier used elsewhere in this
    harness cannot separate them within one take.
    """

    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.running, self.series = pid, True, []

    def run(self):
        while self.running:
            # RECORD EVERYTHING, filter afterwards. Storing only 340-wide windows
            # makes the series unable to answer "what DID appear" when no chip is
            # found — a fixture too small to express the question it is being
            # asked, which is how a wrong width filter reads as a missing chip.
            self.series.append({"t": time.time(), "windows": g.visible_overlays(self.pid)})
            time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence

    def stop(self):
        self.running = False
        self.join(timeout=2)

    def sizes_seen(self):
        """Every distinct overlay size this arm saw, so a miss is diagnosable."""
        return sorted({(m["w"], m["h"]) for x in self.series for m in x["windows"].values()})

    def last_window(self):
        """(first_seen, last_seen, ids) for the LAST contiguous chip appearance.

        The watcher runs across the whole arm, priming included, so several chips
        may have come and gone. Taking first-to-last across all of them would
        report a "visible" span covering the gaps between them — a number that
        grows with the number of priming takes and has nothing to do with the
        dwell.
        """
        runs, cur = [], None
        for raw in self.series:
            s = {"t": raw["t"],
                 "chips": {i: m for i, m in raw["windows"].items() if m["w"] == CHIP_WIDTH}}
            if s["chips"]:
                if cur is None:
                    cur = {"first": s["t"], "last": s["t"], "ids": set(s["chips"])}
                else:
                    cur["last"] = s["t"]
                    cur["ids"] |= set(s["chips"])
            elif cur is not None:
                runs.append(cur)
                cur = None
        if cur is not None:
            runs.append(cur)
        if not runs:
            return None
        r = runs[-1]
        return r["first"], r["last"], sorted(r["ids"])


def backend_in_use(since_bytes):
    """The backend the app SAYS it recorded with, from its own log line."""
    with LOG.open("rb") as fh:
        fh.seek(since_bytes)
        tail = fh.read().decode("utf-8", errors="replace")
    seen = [l for l in tail.splitlines() if "Recording started. Backend:" in l]
    if not seen:
        return None
    return seen[-1].split("Backend:")[1].split(",")[0].strip()


def read_dev(k):
    r = subprocess.run(["defaults", "read", DEV_DOMAIN, k], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def dictate(audio):
    """One hands-free take carrying the audio, stopped cleanly."""
    if not rk.double_press_record_key():
        return False
    subprocess.run(["afplay", audio])
    rk.stop_after_short_hold(0.0)
    return True


def prime_until_chip(pid, audio, max_takes=9):
    """Dictate the same non-English audio until the chip is armed.

    Returns (takes_used, appeared). The chip fires on the take where the
    detector's consecutive-accept counter reaches its threshold, so the caller
    cannot know in advance which take that is.

    **NOT EVERY TAKE COUNTS, WHICH IS WHY THE BOUND IS GENEROUS.** Only a
    `.highAuto` accept at confidence >= 0.85 increments; a `.mediumAuto` is a
    complete no-op — it neither increments nor resets. Measured on identical
    audio across one session: `conf=0.85`, `0.91`, `0.91`, then `mediumAuto
    conf=0.65`. So three takes is the BEST case, not the expected one, and a bound
    of five left the second arm one strong accept short.
    """
    for take in range(1, max_takes + 1):
        g.await_idle()
        if not dictate(audio):
            return take, False
        # The chip is presented at pipeline completion, so wait for the pipeline
        # rather than for a clock.
        g.await_idle()
        deadline = time.time() + 6
        while time.time() < deadline:
            if any(m["w"] == CHIP_WIDTH for m in g.visible_overlays(pid).values()):
                return take, True
            time.sleep(0.05)  # test-fixture-timer: chip-appearance sampling
    return max_takes, False


def run_arm(pid, audio, hover, label):
    # THE WATCHER COVERS THE WHOLE ARM, priming included. Starting it after the
    # chip is detected would miss the chip's first moments, and the dwell is
    # measured from exactly those.
    chips = Chips(pid)
    chips.start()

    takes, armed = prime_until_chip(pid, audio)
    if not armed:
        sizes = chips.sizes_seen()
        chips.stop()
        return {"arm": label, "hover": hover, "takes": takes,
                "error": f"no window of width {CHIP_WIDTH} appeared after priming",
                "sizes_seen": sizes}

    hovered_at = None
    left_at = None
    if hover:
        # The chip is already up — `prime_until_chip` returns on its appearance —
        # so hover immediately rather than waiting for it again.
        found = {i: m for i, m in g.visible_overlays(pid).items() if m["w"] == CHIP_WIDTH}
        target = next(iter(found.values())) if found else None
        if target:
            si.move_mouse(target["x"] + target["w"] // 2, target["y"] + target["h"] // 2)
            hovered_at = time.time()
            time.sleep(CHIP_DWELL * 2)  # deadline-fallback: hold well past the
            # dwell the chip would otherwise expire at; there is no signal for
            # "the timer would have fired", which is the point of the arm.
            si.move_mouse(20, 20)       # leave, so the dwell re-arms
            left_at = time.time()

    # Let the chip finish either way.
    time.sleep(CHIP_DWELL * 2 + 2)  # deadline-fallback: bounded wait for expiry;
    # a chip still present after this is the failure the row exists to catch.
    chips.stop()

    win = chips.last_window()
    if not win:
        return {"arm": label, "hover": hover, "takes_to_arm": takes,
                "error": f"no window of width {CHIP_WIDTH} appeared",
                "sizes_seen": chips.sizes_seen()}
    first, last, ids = win
    return {
        "arm": label,
        "hover": hover,
        "takes_to_arm": takes,
        "chip_ids": ids,
        "visible_for_s": round(last - first, 2),
        "hovered_after_s": round(hovered_at - first, 2) if hovered_at else None,
        "left_after_s": round(left_at - first, 2) if left_at else None,
        "gone_after_leaving_s": round(last - left_at, 2) if left_at else None,
    }


def main():
    pids = g.dev_pids()
    if len(pids) != 1:
        print(json.dumps({"verdict": "ABORT_INSTANCE", "found": pids}))
        return
    pid = pids[0]

    snapshot = {k: read_dev(k) for k in STATE_KEYS}
    backend_before = subprocess.run(["defaults", "read", SHARED_DOMAIN, "selectedBackend"],
                                    capture_output=True, text=True).stdout.strip() or None
    report = {"pid": pid, "snapshot": snapshot, "dwell_seconds": CHIP_DWELL,
              "backend_before": backend_before}
    try:
        for k in STATE_KEYS:
            subprocess.run(["defaults", "delete", DEV_DOMAIN, k], capture_output=True)

        # Switch to the only backend that performs language identification, with
        # the app STOPPED so the write is not overwritten by the instance it
        # replaces.
        if backend_before != REQUIRED_BACKEND:
            g.stop_app()
            subprocess.run(["defaults", "write", SHARED_DOMAIN, "selectedBackend",
                            REQUIRED_BACKEND], check=True)
            pid = g.start_app()
            if not pid:
                print(json.dumps({"verdict": "ABORT_NO_INSTANCE"}))
                return
            report["pid"] = pid
        g.await_idle()

        pt.ensure()  # best effort; a missing paste target never blocks a row

        audio = w.tts(SPANISH)
        report["audio"] = audio
        report["speech_seconds"] = round(w._audio_duration(audio), 2)

        g.await_idle()
        since = LOG.stat().st_size
        report["arm_a"] = run_arm(pid, audio, hover=False, label="no hover")
        # Asserted AFTER a real take, from the app rather than from the write.
        report["backend_in_use"] = backend_in_use(since)
        if report["backend_in_use"] != REQUIRED_BACKEND:
            report["arm_a"]["error"] = (
                f"recorded on {report['backend_in_use']!r}, which performs no language "
                "identification; the chip cannot be armed on it")
        g.await_idle()
        report["arm_b"] = run_arm(pid, audio, hover=True, label="hover then leave")

        a, b = report["arm_a"], report["arm_b"]
        a_ok = "error" not in a and a["visible_for_s"] <= CHIP_DWELL + 2.5
        # The hover arm must outlive the plain dwell BY the hover, and must still
        # go away afterwards — a chip that never expires passes neither half.
        b_ok = ("error" not in b and b["hovered_after_s"] is not None
                and b["visible_for_s"] > CHIP_DWELL + 2.5
                and b["gone_after_leaving_s"] is not None)
        report["backend_correct"] = report.get("backend_in_use") == REQUIRED_BACKEND
        report["arm_a_expired_on_dwell"] = a_ok
        report["arm_b_survived_hover_then_expired"] = b_ok
        report["verdict"] = "PASS" if (a_ok and b_ok and report["backend_correct"]) else "REFUSED"
    finally:
        if backend_before and backend_before != REQUIRED_BACKEND:
            g.stop_app()
            subprocess.run(["defaults", "write", SHARED_DOMAIN, "selectedBackend",
                            backend_before], check=True)
            g.start_app()
        report["backend_restored"] = subprocess.run(
            ["defaults", "read", SHARED_DOMAIN, "selectedBackend"],
            capture_output=True, text=True).stdout.strip() or None
        for k, v in snapshot.items():
            if v is None:
                subprocess.run(["defaults", "delete", DEV_DOMAIN, k], capture_output=True)
            else:
                subprocess.run(["defaults", "write", DEV_DOMAIN, k, v], check=True)
        report["restored"] = {k: read_dev(k) for k in STATE_KEYS}
        report["restore_clean"] = report["restored"] == snapshot
        (UAT / "language-hover.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
