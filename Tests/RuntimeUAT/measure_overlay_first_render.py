"""First-render measurement instrument for #2377 Phase 6 (P6-C1).

**This chunk proves the INSTRUMENT, not the latency outcome.** The 30-pair
decision belongs to C4, after a final candidate exists; what ships here is the
marker contract, the adjudicator, and a one-bundle smoke receipt.

The whole design follows from one property: a benchmark that can report PASS on
incomplete evidence is worse than no benchmark, because it buys the confidence
without the cover. So no `FAIL` is reachable from missing evidence — the verdict
set is `SMOKE_PASS`, `BENCHMARK_PASS`, `BENCHMARK_FAIL`, and `BLOCKED_<reason>`,
and a `FAIL` is a claim about the CODE that requires complete evidence first.

Identity is the sharp edge. Every dev bundle on this machine is named
`EnviousWispr Local.app`, so a name, a bundle id and a version can all agree
across two worktrees' builds. The executable's SHA-256 is therefore the
authority, and the harness computes it from the launched pid's resolved
executable path — never from a marker, because an app echoing back what the
harness supplied proves nothing about which bytes ran.

The pure half of this module imports nothing but the standard library, so the
refusal suite beside it runs anywhere. Every PyObjC and app-driving import is
made inside the function that needs it.

Run the suite:  `python3 Tests/RuntimeUAT/measure_overlay_first_render_test.py`
Run the smoke:  `python3 Tests/RuntimeUAT/measure_overlay_first_render.py --smoke
                    --bundle "<path>/EnviousWispr Local.app"`
"""

import hashlib
import json
import os
import pathlib
import statistics
import subprocess
import sys
import time
import uuid
from collections import namedtuple

# The sibling harness modules are imported lazily, inside the functions that
# drive the app, so the pure half of this module stays standard-library only.
# The path insert itself imports nothing, so it belongs here rather than being
# repeated - and repeated - inside each of them.
sys.path.insert(0, str(pathlib.Path(__file__).parent))

# --------------------------------------------------------------- the contract

# The version is IN the schema token, so a future format is refused loudly by an
# old harness rather than parsed leniently into a plausible number.
SCHEMA_FAMILY = "EW_OVERLAY_FIRST_RENDER"
# V2 adds the `intent` field (#2377, C1 repair, cloud review P1): the shared
# retained panel makes every presentation look identical to a marker, so an
# unrelated one — the crash-recovery card WisprBootstrapper can show on ANY
# launch — could win the race and bind the marker instead of the
# keypress-triggered recording. A schema bump because a V1 harness reading a
# V2 line, or a V2 harness reading a V1 line, must refuse loudly rather than
# silently misparse the field count.
# V3 adds the `engine.ready` event (#2377, C1 repair, Codex's smoke ruling):
# an app launched with an engine that has not finished warming refuses a
# synthetic keypress via `ColdPressGuard` (#879), a real product policy this
# instrument's own input must not trip. A V2 harness has no such event in its
# `EVENTS`/`KNOWN_EVENTS` set and would refuse the line rather than silently
# treat it as launch/root evidence it is not.
SCHEMA = SCHEMA_FAMILY + "_V3"

LAUNCH_ENTER = "launch.enter"
LAUNCH_EXIT = "launch.exit"
ROOT_START = "root.construct.start"
ROOT_END = "root.construct.end"
ORDER_FRONT = "host.order_front.complete"
ENGINE_READY = "engine.ready"

# In causal order. The whole chain is enforced, which is what forbids a root
# built inside launch; there is deliberately no separate notion of "pairs".
# `ENGINE_READY` is deliberately NOT a member: engine warm-up and first render
# run on two independent schedules, and folding one into the other's ordering
# check would make an instrument change what it exists only to observe.
EVENTS = (LAUNCH_ENTER, LAUNCH_EXIT, ROOT_START, ROOT_END, ORDER_FRONT)

# Every event the PARSER accepts — `EVENTS` plus `ENGINE_READY`. Kept separate
# from `EVENTS` so adding a recognized event never silently widens the launch
# causal chain `adjudicate_launch` enforces.
KNOWN_EVENTS = EVENTS + (ENGINE_READY,)

# Which presentation an `ORDER_FRONT` marker belongs to. `NONE` is the only
# legal intent for every other event; `RECORDING` is the presentation the
# benchmark measures; `OTHER` is anything else sharing the retained panel.
# Must match `OverlayFirstRenderMarkers.Intent` in Swift exactly — nothing
# links the two spellings but `test_the_swift_emitter_and_this_parser_agree_on_the_schema`.
INTENT_NONE = "none"
INTENT_RECORDING = "recording"
INTENT_OTHER = "other"
INTENTS = (INTENT_NONE, INTENT_RECORDING, INTENT_OTHER)

MARKER_PATH_ENV = "EW_OVERLAY_FIRST_RENDER_MARKER_PATH"
RUN_ID_ENV = "EW_OVERLAY_FIRST_RENDER_RUN_ID"

# Must match `OverlayFirstRenderMarkers.axPanelIdentifier` in Swift exactly.
AX_PANEL_IDENTIFIER = "EW_OVERLAY_FIRST_RENDER_PANEL"

# ---------------------------------------------------------------- the verdicts

OK = "OK"
SMOKE_PASS = "SMOKE_PASS"
BENCHMARK_PASS = "BENCHMARK_PASS"
BENCHMARK_FAIL = "BENCHMARK_FAIL"

BLOCKED_MALFORMED_MARKER = "BLOCKED_MALFORMED_MARKER"
BLOCKED_WRONG_APP = "BLOCKED_WRONG_APP"
BLOCKED_MISSING_MARKER = "BLOCKED_MISSING_MARKER"
BLOCKED_DUPLICATE_MARKER = "BLOCKED_DUPLICATE_MARKER"
BLOCKED_PAIR_ORDER = "BLOCKED_PAIR_ORDER"
BLOCKED_NON_MONOTONIC = "BLOCKED_NON_MONOTONIC"
BLOCKED_INCOMPLETE_PAIRS = "BLOCKED_INCOMPLETE_PAIRS"
BLOCKED_SCHEDULE = "BLOCKED_SCHEDULE"
BLOCKED_OCCUPANCY = "BLOCKED_OCCUPANCY"
BLOCKED_LAUNCH = "BLOCKED_LAUNCH"
BLOCKED_NO_OVERLAY = "BLOCKED_NO_OVERLAY"
BLOCKED_SCREEN_LOCKED = "BLOCKED_SCREEN_LOCKED"
# An unrelated presentation (intent=other) reached the shared panel before the
# keypress-triggered recording did, so the FIRST order-front — and the root
# construction it may have caused — belongs to the wrong presentation.
BLOCKED_WRONG_PRESENTATION = "BLOCKED_WRONG_PRESENTATION"
# The AX tree could not be read: permission not granted, or the app's own
# AXRole did not resolve to AXApplication.
BLOCKED_AX_UNAVAILABLE = "BLOCKED_AX_UNAVAILABLE"
# More than one AX window bore our identifier at the moment of first
# appearance. Never averaged or picked from — refused, like every other
# ambiguity this instrument treats as evidence it cannot trust.
BLOCKED_AMBIGUOUS_OVERLAY = "BLOCKED_AMBIGUOUS_OVERLAY"
# No complete `engine.ready` marker for this run/pid/bundle within the wait.
# Sending a synthetic keypress anyway would race `ColdPressGuard` (#879),
# which correctly refuses a press on a still-warming engine — a real product
# policy, not a first-render fault, so it gets its own verdict rather than
# reusing `BLOCKED_WRONG_PRESENTATION` or `BLOCKED_LAUNCH`.
BLOCKED_ENGINE_NOT_READY = "BLOCKED_ENGINE_NOT_READY"

Identity = namedtuple("Identity", "bundle_id executable_path sha256")
Marker = namedtuple("Marker", "run pid bundle event ticks window intent index")
LaunchSample = namedtuple(
    "LaunchSample", "run launch_ms root_ms order_front_ms host_window_id")
LaunchResult = namedtuple("LaunchResult", "verdict detail sample")
OverlayTiming = namedtuple("OverlayTiming", "verdict detail window_id keypress_ms")
# A keypress figure carries the run it belongs to. Untagged floats let a runner
# associate the wrong measurement with a launch and still satisfy every other
# check — the identity argument this whole instrument rests on, one level out.
KeypressSample = namedtuple("KeypressSample", "run keypress_ms")
Pair = namedtuple("Pair", "order a b a_keypress b_keypress")
Budget = namedtuple(
    "Budget", "launch_median_regression_ms root_p95_ms keypress_p95_regression_ms")
BenchmarkResult = namedtuple("BenchmarkResult", "verdict detail measured")

# The plan's binding launch budget. Named here so a change to it has one place to
# land; the values are NOT this module's to choose.
PLAN_BUDGET = Budget(launch_median_regression_ms=5.0,
                     root_p95_ms=8.0,
                     keypress_p95_regression_ms=16.7)

PAIR_COUNT = 30


class MarkerFormatError(Exception):
    """A line carrying our schema family that we cannot read."""


# ------------------------------------------------------------------ parsing

def parse_marker_line(line, index=0):
    """One TSV marker line to a `Marker`, or raise.

    Fixed field order, each `key=value`. A positional format rather than JSON
    because the app writes this on the launch path: one `write(2)` of a
    pre-built string, no encoder, no allocation beyond the string itself.
    """
    fields = line.split("\t")
    if len(fields) != 8:
        raise MarkerFormatError(
            f"expected 8 tab-separated fields, got {len(fields)}: {line!r}")
    schema, run, pid, bundle, event, ticks, window, intent = fields
    if schema != SCHEMA:
        raise MarkerFormatError(f"unknown schema {schema!r}, this harness reads {SCHEMA}")
    parsed = {}
    for key, field in (("run", run), ("pid", pid), ("bundle", bundle),
                       ("event", event), ("ticks", ticks), ("window", window),
                       ("intent", intent)):
        prefix = key + "="
        if not field.startswith(prefix):
            raise MarkerFormatError(f"expected {prefix!r}, got {field!r}")
        parsed[key] = field[len(prefix):]
    if parsed["event"] not in KNOWN_EVENTS:
        raise MarkerFormatError(f"unknown event {parsed['event']!r}")
    if parsed["intent"] not in INTENTS:
        raise MarkerFormatError(f"unknown intent {parsed['intent']!r}")
    for key in ("pid", "ticks", "window"):
        if not parsed[key].isdigit():
            raise MarkerFormatError(
                f"{key} must be a non-negative integer, got {parsed[key]!r}")
    # Only the host event names a window; every other event writes 0, and BOTH
    # halves are enforced. A host marker with no usable window id is a MALFORMED
    # marker rather than a missing overlay — the app reached the call site and
    # could not say which window it ordered, which is a different fault sent to a
    # different place. A non-host event carrying a window means the emitter is
    # writing something this parser does not model, and a contract stated only in
    # a comment is the shape that retires the check instead of failing it.
    #
    # The SAME split applies to intent: only the host event may concern a
    # presentation, so it is the one event that must NOT carry `.none` — every
    # other event must, since carrying anything else is the emitter writing a
    # concept this parser does not model for that event.
    window_id = int(parsed["window"])
    if parsed["event"] == ORDER_FRONT:
        if window_id <= 0:
            raise MarkerFormatError(
                f"{ORDER_FRONT} must name a positive window id, got {window_id}")
        if parsed["intent"] == INTENT_NONE:
            raise MarkerFormatError(f"{ORDER_FRONT} must not carry intent={INTENT_NONE!r}")
    else:
        if window_id != 0:
            raise MarkerFormatError(
                f"{parsed['event']} must carry window 0, got {window_id}")
        if parsed["intent"] != INTENT_NONE:
            raise MarkerFormatError(
                f"{parsed['event']} must carry intent={INTENT_NONE!r}, got "
                f"{parsed['intent']!r}")
    return Marker(run=parsed["run"], pid=int(parsed["pid"]), bundle=parsed["bundle"],
                  event=parsed["event"], ticks=int(parsed["ticks"]),
                  window=int(parsed["window"]), intent=parsed["intent"], index=index)


def read_markers(text):
    """Every marker in `text`, in file order. Foreign lines are IGNORED.

    A line that does not begin with our schema FAMILY belongs to something else
    and is none of our business — refusing on it would make the instrument fail
    whenever anything else wrote to the same file. A line that DOES carry the
    family and cannot be read is a different fact and raises: that is our own
    format, drifted.
    """
    out = []
    for i, line in enumerate(text.splitlines()):
        line = line.rstrip("\r")
        if not line.startswith(SCHEMA_FAMILY):
            continue
        out.append(parse_marker_line(line, index=i))
    return out


# -------------------------------------------------------------- adjudication

def ticks_to_ms(ticks, timebase):
    numer, denom = timebase
    return (ticks * numer / denom) / 1_000_000.0


def adjudicate_launch(marker_text, *, expected_run, expected_pid,
                      requested, resolved, timebase):
    """One launch's markers to a verdict. Never raises, never guesses.

    Check order is deliberate and each step is a different question:

    1. Is this the app we asked for?  An identity mismatch makes every marker
       below it irrelevant, so it is asked first.
    2. Can we read our own format?
    3. Whose launch wrote these lines?
    4. Is every marker present, exactly once?
    5. Are the pairs in order, and does the clock move forwards?
    """
    def blocked(reason, detail):
        return LaunchResult(verdict=reason, detail=detail, sample=None)

    if resolved.bundle_id != requested.bundle_id:
        return blocked(BLOCKED_WRONG_APP,
                       f"requested bundle {requested.bundle_id!r}, "
                       f"the launched process resolves to {resolved.bundle_id!r}")
    if resolved.executable_path != requested.executable_path:
        return blocked(BLOCKED_WRONG_APP,
                       f"requested executable {requested.executable_path!r}, "
                       f"the launched pid resolves to {resolved.executable_path!r}")
    if resolved.sha256 != requested.sha256:
        # The case a bundle-id check cannot see, and the one that matters here.
        return blocked(BLOCKED_WRONG_APP,
                       f"executable hash {resolved.sha256} is not the requested "
                       f"{requested.sha256} - same path, different bytes")

    try:
        markers = read_markers(marker_text)
    except MarkerFormatError as exc:
        return blocked(BLOCKED_MALFORMED_MARKER, str(exc))

    for mk in markers:
        if mk.run != expected_run:
            return blocked(
                BLOCKED_WRONG_APP,
                f"a marker carries run {mk.run!r}, this launch is {expected_run!r}")
        if mk.pid != expected_pid:
            return blocked(
                BLOCKED_WRONG_APP,
                f"a marker carries pid {mk.pid}, this launch is {expected_pid}")
        if mk.bundle != requested.bundle_id:
            return blocked(BLOCKED_WRONG_APP,
                           f"a marker names bundle {mk.bundle!r}, we requested "
                           f"{requested.bundle_id!r}")

    by_event = {}
    for mk in markers:
        by_event.setdefault(mk.event, []).append(mk)

    # `ORDER_FRONT` is no longer a plain singleton: the shared retained panel
    # can legitimately write ONE marker per intent (`.recording`, `.other`),
    # so its own missing/duplicate/identity checks are per-INTENT rather than
    # per-event, on top of the ordinary per-event checks every other member of
    # `EVENTS` still gets.
    non_order_events = [e for e in EVENTS if e != ORDER_FRONT]

    missing = [e for e in non_order_events if not by_event.get(e)]

    order_fronts = by_event.get(ORDER_FRONT, [])
    by_intent = {}
    for mk in order_fronts:
        by_intent.setdefault(mk.intent, []).append(mk)
    # A `.recording` marker is what makes this launch usable at all — the
    # benchmark's whole subject is that presentation. An `.other`-only launch
    # is missing it exactly as if `ORDER_FRONT` were absent entirely.
    if not by_intent.get(INTENT_RECORDING):
        missing = missing + [ORDER_FRONT]

    if missing:
        return blocked(BLOCKED_MISSING_MARKER, "absent: " + ", ".join(missing))

    # Every key in `non_order_events` is now guaranteed present — `missing`
    # would have caught and returned on anything absent above — so indexing
    # `by_event` directly here cannot raise.
    doubled = [e for e in non_order_events if len(by_event[e]) > 1]
    doubled_order_front = [intent for intent, group in by_intent.items() if len(group) > 1]
    if doubled or doubled_order_front:
        # Every event is a singleton within one launch, and now so is every
        # INTENT of `ORDER_FRONT`. Two of anything means two launches — or two
        # presentations of the same intent — wrote to one file, and the
        # durations would be a mix.
        parts = [f"{e} x{len(by_event[e])}" for e in doubled]
        parts += [f"{ORDER_FRONT}(intent={intent}) x{len(by_intent[intent])}"
                 for intent in doubled_order_front]
        return blocked(BLOCKED_DUPLICATE_MARKER, "seen more than once: " + ", ".join(parts))

    # Reached only once a `.recording` marker is confirmed present and alone.
    recording_marker = by_intent[INTENT_RECORDING][0]
    other_marker = by_intent.get(INTENT_OTHER, [None])[0]
    if other_marker is not None and other_marker.index < recording_marker.index:
        # The unrelated presentation reached the panel FIRST, so root
        # construction — if this is the first-ever presentation — belongs to
        # IT, not to the recording whose timing the benchmark actually wants.
        return blocked(
            BLOCKED_WRONG_PRESENTATION,
            f"an unrelated presentation (window {other_marker.window}) reached the panel "
            f"before the recording did (window {recording_marker.window})")

    single = {e: by_event[e][0] for e in non_order_events}
    single[ORDER_FRONT] = recording_marker

    # **The whole chain, not two pairs checked separately.** `EVENTS` is in
    # causal order, and the link that only a full chain enforces is
    # `launch.exit -> root.construct.start`: without it a launch that built the
    # root SYNCHRONOUSLY, inside `applicationDidFinishLaunching`, satisfies both
    # pairs and is accepted. That is the arrangement Phase 6 exists to move away
    # from, so the instrument must not certify it.
    for earlier, later in zip(EVENTS, EVENTS[1:]):
        if single[later].index <= single[earlier].index:
            return blocked(BLOCKED_PAIR_ORDER,
                           f"{later} was written before {earlier}")
        if single[later].ticks <= single[earlier].ticks:
            return blocked(BLOCKED_NON_MONOTONIC,
                           f"{later} at {single[later].ticks} ticks is not after "
                           f"{earlier} at {single[earlier].ticks}")

    sample = LaunchSample(
        run=expected_run,
        launch_ms=ticks_to_ms(
            single[LAUNCH_EXIT].ticks - single[LAUNCH_ENTER].ticks, timebase),
        root_ms=ticks_to_ms(
            single[ROOT_END].ticks - single[ROOT_START].ticks, timebase),
        order_front_ms=ticks_to_ms(
            single[ORDER_FRONT].ticks - single[ROOT_START].ticks, timebase),
        host_window_id=single[ORDER_FRONT].window)
    return LaunchResult(verdict=OK, detail="", sample=sample)


def smoke_verdict(result):
    """One accepted launch is `SMOKE_PASS` and can never be a benchmark PASS.

    The smoke run proves the instrument works end to end on one bundle. It says
    nothing about latency, because a single launch has no baseline to be
    compared against - so it gets its own verdict rather than borrowing one that
    would read as a budget decision.
    """
    return SMOKE_PASS if result.verdict == OK else result.verdict


# ------------------------------------------------------- the overlay endpoint

def read_complete_markers(text):
    """Markers from COMPLETE lines only, for a reader polling a file being written.

    The emitter loops on a short `write(2)`, which is correct — a truncated line
    would otherwise reach the harness as a malformed one, an instrument fault
    wearing an app fault's clothes. But a poller can still read BETWEEN the two
    halves of that loop and see an unfinished final line.

    A line is finished when a newline follows it, so everything up to the last
    newline is safe to parse and anything after it is not yet a line. Discarding
    the tail costs one more poll; parsing it costs a false verdict about the app.
    """
    end = text.rfind("\n")
    if end < 0:
        return []
    return read_markers(text[:end + 1])


def launch_is_ready(text, *, expected_run, expected_pid, expected_bundle):
    """Has THIS launch written its `launch.exit` marker yet?

    An exact, complete marker matching this run, pid and bundle — not a substring
    search for the event name. A substring matches a half-written line, a line
    from another run that somehow reached this file, and the event name appearing
    anywhere at all; and it answers "ready" the instant those bytes land, which
    is before the app has finished saying anything.
    """
    try:
        markers = read_complete_markers(text)
    except MarkerFormatError:
        # A malformed line is a real fault and belongs to the adjudicator, not to
        # a readiness probe. Answering "not ready" fails CLOSED: the launch times
        # out and says so, rather than proceeding on a file it cannot read.
        return False
    return any(mk.event == LAUNCH_EXIT and mk.run == expected_run
               and mk.pid == expected_pid and mk.bundle == expected_bundle
               for mk in markers)


def engine_is_ready(text, *, expected_run, expected_pid, expected_bundle):
    """Has THIS launch written its `engine.ready` marker yet?

    Same exact-match discipline as `launch_is_ready`, for a different fact:
    the app writes `launch.exit` when `applicationDidFinishLaunching`
    returns, well before the selected engine has finished warming. Sending a
    synthetic keypress in that window races `ColdPressGuard` (#879), which
    correctly refuses the press and blocks the run for a reason that has
    nothing to do with first render — the fact this instrument exists to
    measure.
    """
    try:
        markers = read_complete_markers(text)
    except MarkerFormatError:
        return False
    return any(mk.event == ENGINE_READY and mk.run == expected_run
               and mk.pid == expected_pid and mk.bundle == expected_bundle
               for mk in markers)


def await_engine_ready(marker_path, *, run_id, expected_pid, expected_bundle,
                       timeout_s=30.0, read_text=None):
    """Wait for `engine.ready` before any synthetic input is sent.

    **A separate clock from the keypress-to-overlay interval it gates.** This
    function returns before `measure_keypress_to_overlay` ever reads
    `perf_counter_ns`, so warm-up wait time cannot fold into the number the
    plan states as PILL latency — the same reasoning `hold()`'s doc comment
    gives for keeping marker I/O cost out of the interval it would bias.

    Never a fixed sleep: the signal is the app's own marker, exactly like
    `await_launch_ready`. Returns `False` on timeout rather than raising —
    the caller turns that into `BLOCKED_ENGINE_NOT_READY`, a receipt, not an
    exception with no receipt behind it.

    `read_text` exists for the suite, which cannot launch a real app to make
    the read fail or to control what it returns.
    """
    read_text = read_text or (lambda: marker_path.read_text())
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            text = read_text()
        except OSError:
            text = ""
        if engine_is_ready(text, expected_run=run_id, expected_pid=expected_pid,
                           expected_bundle=expected_bundle):
            return True
        # deadline-fallback: the interval between reads of the app's own marker.
        time.sleep(0.02)
    return False


def ax_overlay_has_appeared(match_count):
    """The live loop's stopping rule for the AX endpoint, extracted so a test
    can reach it directly.

    Fires on the FIRST match, deliberately. Waiting to see whether a second one
    also appears would inflate the very quantity being measured; ambiguity from
    more than one match is judged AFTER the fact by the adjudicator, from the
    count recorded at the moment of the first one.
    """
    return match_count > 0


def recording_host_marker_from(marker_text, *, exhausted=False):
    """The RECORDING-intent host marker's window id, or a block, or "not yet".

    Three answers, and `exhausted` decides which of two readings an `.other`-
    only file gets:

    - `(window_id, None)` — a usable `.recording` marker exists, and no
      `.other` marker reached the panel before it.
    - `(None, (verdict, detail))` — a DEFINITIVE block: malformed content, a
      duplicate marker of one intent, an `.other` marker that beat a
      `.recording` marker that HAS arrived, or — only once `exhausted` is
      True — an `.other` marker (or nothing at all) with no `.recording`
      marker ever arriving.
    - `(None, None)` — not enough information yet. Only possible when
      `exhausted` is False: an `.other` marker alone does not yet mean the
      recording never came, because it might still land within the deadline.

    `exhausted=True` is for the ONE call made once polling has stopped (an AX
    match fired, or the deadline passed) — the point at which "no `.recording`
    marker yet" and "no `.recording` marker ever" become the same fact.
    """
    try:
        markers = read_complete_markers(marker_text)
    except MarkerFormatError as exc:
        return None, (BLOCKED_MALFORMED_MARKER, str(exc))
    hosts = [mk for mk in markers if mk.event == ORDER_FRONT]
    by_intent = {}
    for mk in hosts:
        by_intent.setdefault(mk.intent, []).append(mk)
    for intent, group in by_intent.items():
        if len(group) > 1:
            return None, (BLOCKED_DUPLICATE_MARKER,
                          f"{len(group)} {ORDER_FRONT} markers with intent={intent!r}")
    recording = by_intent.get(INTENT_RECORDING, [None])[0]
    other = by_intent.get(INTENT_OTHER, [None])[0]
    if recording is not None:
        if other is not None and other.index < recording.index:
            return None, (BLOCKED_WRONG_PRESENTATION,
                          f"an unrelated presentation (window {other.window}) reached the "
                          f"panel before the recording did (window {recording.window})")
        return recording.window, None
    if not exhausted:
        return None, None
    if other is not None:
        return None, (BLOCKED_WRONG_PRESENTATION,
                      f"only an unrelated presentation (window {other.window}) reached the "
                      "panel; the keypress-triggered recording never did")
    return None, (BLOCKED_MISSING_MARKER,
                  f"the app never reported ordering a window front with intent="
                  f"{INTENT_RECORDING!r}")


def adjudicate_ax_overlay(*, ax_available, preexisting_count, match_count_at_stop,
                          first_seen_ns, keydown_ns, host_window_id):
    """Which AX appearance ended the keypress interval — NAMED by the app's
    identifier, timed by us.

    **CGWindow-list membership can precede compositing; AX membership is the
    plan's own binding endpoint** (cloud review P1, #2377). Registration with
    WindowServer is not the same fact as SwiftUI content having been drawn —
    an app-owned window ID can appear in `CGWindowListCopyWindowInfo` before
    its content is on screen, which is exactly the case the plan's
    "first-AX-overlay" language exists to rule out.

    **AX membership is not proof of the first COMPOSITED pixel either** —
    stated so this function is never cited as more than it is. A real screen
    recording is (`wispr_eyes.record()`); that proof belongs to C5, which
    exists specifically because #2377 needed the pill's first composited
    frame and this repo's own tooling already documents that no amount of
    polling — CGWindow or AX — can answer that question.

    The value is always the harness's own first-observed timestamp for the
    identifier the panel carries. The app supplies identity; it does not
    supply time. `host_window_id` — the marker's own CGWindow number, already
    validated by `recording_host_marker_from` — is carried through as a
    receipt and identity cross-check, never as part of the stopwatch.
    """
    if not ax_available:
        return OverlayTiming(
            verdict=BLOCKED_AX_UNAVAILABLE,
            detail="the AX tree could not be read: permission not granted, or the app's "
                   "AXRole did not resolve to AXApplication",
            window_id=host_window_id, keypress_ms=None)
    if preexisting_count > 0:
        # Already present at key-down, so its appearance is not an event this
        # keypress caused and there is no interval to report.
        return OverlayTiming(
            verdict=BLOCKED_NO_OVERLAY,
            detail=(f"{preexisting_count} AX window(s) already bore our identifier before "
                    "the keypress, so nothing about their appearance is attributable to "
                    "this press"),
            window_id=host_window_id, keypress_ms=None)
    if first_seen_ns is None:
        return OverlayTiming(
            verdict=BLOCKED_NO_OVERLAY,
            detail="no AX window bearing our identifier was observed before the deadline",
            window_id=host_window_id, keypress_ms=None)
    if match_count_at_stop != 1:
        # Never averaged or picked from — refused, the same way every other
        # ambiguity this instrument meets is refused rather than resolved by
        # guessing.
        return OverlayTiming(
            verdict=BLOCKED_AMBIGUOUS_OVERLAY,
            detail=f"{match_count_at_stop} AX windows bore our identifier at the moment of "
                   "first appearance",
            window_id=host_window_id, keypress_ms=None)
    return OverlayTiming(verdict=OK, detail="", window_id=host_window_id,
                         keypress_ms=(first_seen_ns - keydown_ns) / 1e6)


# -------------------------------------------------------------- statistics

def median(values):
    return statistics.median(values)


def nearest_rank(values, percentile):
    """The nearest-rank percentile: the ceil(p/100 * n)-th of the sorted values.

    Nearest rank rather than interpolation, so every reported figure is a
    duration that was actually OBSERVED. An interpolated p95 is a number no
    launch produced, which is a poor thing to hold a budget against.

    The rank is computed in INTEGER arithmetic. `math.ceil(0.95 * n)` is a float
    expression and 0.95 has no exact binary representation, so it can land one
    rank high for values of n where the true product is a whole number -
    silently reporting the maximum as the p95.
    """
    if not values:
        raise ValueError("nearest_rank of an empty sample")
    ordered = sorted(values)
    n = len(ordered)
    rank = -(-int(percentile) * n // 100)          # ceil division, exact
    rank = max(1, min(rank, n))
    return ordered[rank - 1]


def paired_schedule(pair_count=PAIR_COUNT):
    """Alternating AB/BA, half each way.

    A run drifts - caches warm, the machine heats, the page cache fills - and a
    drift is monotone across the run. Alternating splits any such trend evenly
    between the two bundles instead of handing all of it to whichever went
    second.
    """
    if pair_count % 2:
        raise ValueError("an alternating schedule needs an even pair count")
    return ["AB" if i % 2 == 0 else "BA" for i in range(pair_count)]


# -------------------------------------------------------- benchmark verdict

def adjudicate_benchmark(pairs, budget=PLAN_BUDGET, pair_count=PAIR_COUNT):
    """Thirty complete pairs to a budget verdict, or a block naming why not.

    **No top-up.** A rejected sample blocks the whole run rather than being
    replaced, because replacing it selects for launches that happened to produce
    clean evidence - and the ones that do not are exactly the launches a latency
    question is about.
    """
    def blocked(reason, detail):
        return BenchmarkResult(verdict=reason, detail=detail, measured={})

    if len(pairs) != pair_count:
        return blocked(
            BLOCKED_INCOMPLETE_PAIRS,
            f"{len(pairs)} pairs, this benchmark requires exactly {pair_count}")

    for i, p in enumerate(pairs):
        for side, result in (("A", p.a), ("B", p.b)):
            if result.verdict != OK:
                return blocked(
                    BLOCKED_INCOMPLETE_PAIRS,
                    f"pair {i} side {side} is {result.verdict}: {result.detail}. "
                    "The run is not topped up; re-run the whole schedule.")

    # Balanced is NOT the requirement; ALTERNATING is. Fifteen AB followed by
    # fifteen BA is perfectly balanced and hands the whole first half of any
    # thermal or cache drift to one bundle, which is the bias the alternation
    # exists to cancel.
    orders = [p.order for p in pairs]
    expected_orders = paired_schedule(pair_count)
    if orders != expected_orders:
        return blocked(BLOCKED_SCHEDULE,
                       f"the order was {orders!r}; the schedule must alternate as "
                       f"{expected_orders!r}")

    # Every side must be its OWN cold launch. Without this, one result reused
    # sixty times satisfies every check above and produces a zero-variance
    # benchmark that looks superb.
    runs = [result.sample.run for p in pairs for result in (p.a, p.b)]
    if len(set(runs)) != pair_count * 2:
        return blocked(BLOCKED_INCOMPLETE_PAIRS,
                       f"{len(set(runs))} distinct run ids across {pair_count * 2} "
                       "sides; every side must come from its own cold launch")

    # Each keypress figure must name the launch it came from. The distinct-run
    # check above validates the LAUNCH samples; without this, a runner that
    # reused a prior keypress result or crossed the two sides still satisfies it
    # and produces BENCHMARK_PASS from cross-associated evidence.
    for i, p in enumerate(pairs):
        for side, result, keypress in (("A", p.a, p.a_keypress),
                                       ("B", p.b, p.b_keypress)):
            if keypress.run != result.sample.run:
                return blocked(
                    BLOCKED_INCOMPLETE_PAIRS,
                    f"pair {i} side {side}: the keypress figure names run "
                    f"{keypress.run!r} and the launch is {result.sample.run!r}. "
                    "Every timing must come from the launch it is reported with.")

    a_launch = [p.a.sample.launch_ms for p in pairs]
    b_launch = [p.b.sample.launch_ms for p in pairs]
    b_root = [p.b.sample.root_ms for p in pairs]
    a_key = [p.a_keypress.keypress_ms for p in pairs]
    b_key = [p.b_keypress.keypress_ms for p in pairs]

    launch_regression = median(b_launch) - median(a_launch)
    root_p95 = nearest_rank(b_root, 95)
    keypress_regression = nearest_rank(b_key, 95) - nearest_rank(a_key, 95)

    breaches = []
    if launch_regression > budget.launch_median_regression_ms:
        breaches.append(
            f"launch median regressed {launch_regression:.3f} ms, budget "
            f"{budget.launch_median_regression_ms} ms")
    if root_p95 > budget.root_p95_ms:
        breaches.append(
            f"root construction p95 is {root_p95:.3f} ms, budget {budget.root_p95_ms} ms")
    if keypress_regression > budget.keypress_p95_regression_ms:
        breaches.append(
            f"keypress-to-overlay p95 regressed {keypress_regression:.3f} ms, budget "
            f"{budget.keypress_p95_regression_ms} ms")

    measured = {
        "launch_median_a_ms": median(a_launch),
        "launch_median_b_ms": median(b_launch),
        "launch_median_regression_ms": launch_regression,
        "root_p95_b_ms": root_p95,
        "keypress_p95_a_ms": nearest_rank(a_key, 95),
        "keypress_p95_b_ms": nearest_rank(b_key, 95),
        "keypress_p95_regression_ms": keypress_regression,
    }
    return BenchmarkResult(
        verdict=BENCHMARK_FAIL if breaches else BENCHMARK_PASS,
        detail="; ".join(breaches),
        measured=measured)


# ============================================================================
# The live half. Everything below drives a real app; everything above is pure.
# ============================================================================


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def bundle_identity(bundle_path):
    """The requested bundle's identity, read from disk BEFORE any launch."""
    bundle = pathlib.Path(bundle_path).resolve()
    executable = bundle / "Contents" / "MacOS" / "EnviousWispr"
    if not executable.exists():
        raise FileNotFoundError(f"no executable at {executable}")
    return Identity(bundle_id=bundle_id_at(bundle / "Contents" / "Info.plist"),
                    executable_path=str(executable), sha256=sha256_of(executable))


def bundle_id_at(plist):
    """`CFBundleIdentifier` from an Info.plist, or raise."""
    result = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(plist)],
        capture_output=True, text=True, check=True)
    value = result.stdout.strip()
    # PlistBuddy prints its own failures to STDOUT — a missing file yields the
    # sentence "File Doesn't Exist, Will Create: <path>" rather than an error —
    # so every `if value:` guard downstream passes on a failure. Assert the
    # SHAPE, not the truthiness.
    if not value or " " in value:
        raise ValueError(f"PlistBuddy returned {value!r} for {plist}")
    return value


def resolved_identity(pid):
    """What the LAUNCHED process actually is, resolved entirely from its own pid.

    **Takes no bundle id.** An earlier version accepted the REQUESTED one and
    returned it unchanged, which made the resolved-versus-requested bundle
    comparison tautologically true on every live run — a check that could only
    ever pass, sitting in the identity guard this whole instrument rests on. The
    bundle id is now read from the Info.plist of the bundle that actually
    contains the running executable.

    Reads `comm`, never `command`: `command` is the executable plus its
    arguments with no delimiter, so recovering the path means guessing where the
    arguments begin, and every guess is wrong for some legal path.
    """
    exe = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not exe:
        raise RuntimeError(f"pid {pid} is not running")
    executable = pathlib.Path(exe)
    # <bundle>.app/Contents/MacOS/<exe> -> <bundle>.app
    bundle = executable.parent.parent.parent
    if bundle.suffix != ".app":
        raise RuntimeError(
            f"pid {pid} runs {exe}, which is not inside a .app bundle")
    return Identity(bundle_id=bundle_id_at(bundle / "Contents" / "Info.plist"),
                    executable_path=exe, sha256=sha256_of(exe))


def mach_timebase():
    """`mach_timebase_info`, so raw ticks convert HERE rather than in the app.

    The app emits ticks and does no arithmetic on the launch path, because the
    arithmetic would be inside the interval it is measuring.
    """
    import ctypes
    libc = ctypes.CDLL(None)

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

    tb = Timebase()
    if libc.mach_timebase_info(ctypes.byref(tb)) != 0:
        raise RuntimeError("mach_timebase_info failed")
    return (tb.numer, tb.denom)


def running_instances():
    """Every running EnviousWispr bundle as {pid: executable path}.

    Delegates to the shipped helper rather than re-deriving the `comm`-not-
    `command` reading, the basename requirement and the self-exclusion. Three
    implementations of that have existed; a fourth is how they drift.
    """
    import wispr_eyes as _we
    return _we.running_enviouswispr_instances()


def ax_accessibility_available(pid):
    """True when the AX tree is readable for this pid.

    Mirrors `ui_helpers.validate_test_environment`'s own check: `AXRole`
    resolving to `AXApplication` is what distinguishes a real, permitted read
    from the silent `None` `AXUIElementCopyAttributeValue` returns for every
    failure mode alike (no permission, wrong pid, app not responding).
    """
    import ui_helpers as _ui
    app = _ui.get_ax_app(pid)
    return _ui.get_attr(app, "AXRole") == "AXApplication"


def ax_matching_windows(pid):
    """Every AX window under this app bearing our panel's identifier.

    A LIST, not a count and not a single element — the caller decides what
    zero or more than one means; this function's only job is not to guess.
    """
    import ui_helpers as _ui
    app = _ui.get_ax_app(pid)
    windows = _ui.get_attr(app, "AXWindows") or []
    return [w for w in windows if _ui.get_attr(w, "AXIdentifier") == AX_PANEL_IDENTIFIER]


def measure_keypress_to_overlay(pid, marker_path, *, timeout_s=5.0):
    """Key DOWN to the named overlay window's first appearance, timed here.

    Both endpoints are `perf_counter_ns` reads in THIS process, because the
    quantity is what a user waits for. Splitting it across two clocks in two
    processes would measure two different things and subtract them.

    **The key is held down across the poll, and released afterwards.**
    `wispr_eyes.press_record_key` is a complete push-to-talk gesture — down, a
    40 ms hold, up — so wrapping the timer around it puts that hold INSIDE the
    interval. The pill appears during the hold, so every sample would be
    dominated by the harness's own sleep. It would still have compared the two
    bundles fairly, which is exactly why it would have survived: a constant
    added to both sides leaves the REGRESSION right and the absolute number
    meaningless, and the plan's keypress bound is stated in absolute
    milliseconds. So this calls `simulate_input.modifier_down`/`modifier_up`
    directly — those two functions ARE the owner of the event mechanism,
    including the `CGEventSetIntegerValueField(kCGKeyboardEventKeycode)` line a
    hand-rolled version omits, and `press_record_key` reaches them the same way.
    Only its sequencing is not reused.

    **AX membership, not CGWindow-list membership (cloud review P1, #2377).**
    CGWindow-list registration can precede SwiftUI content actually being
    composited — the plan's own "first-AX-overlay" language exists to rule
    that reading out. Polling continues until an `AXWindow` bearing our
    panel's identifier exists under the app; `recording_host_marker_from`
    supplies the CAUSALITY check (that the recording, not some other
    presentation, is what reached the panel), which AX identity alone cannot
    express.

    **The marker read is decoupled from the AX poll's stop condition.** The
    loop stops as soon as EITHER side has a definitive answer — an AX match
    plus a confirmed recording marker, or a marker-level block that no amount
    of further waiting would change. Re-reading the marker file only when the
    last read was inconclusive avoids re-parsing on every single poll.
    """
    import ptt_binding as _ptt
    import simulate_input as _si

    # RESOLVE the binding; never assume it. A profile bound to something else,
    # or to a non-modifier key, produces silence — and silence read as a product
    # failure is the exact class `ptt_binding` refuses rather than guessing.
    binding = _ptt.resolve()
    if not binding.is_modifier_only:
        raise _ptt.PTTBindingError(
            f"the record key is bound to {binding.key_name!r} (keycode "
            f"{binding.keycode}), which is not a standalone modifier. A plain key "
            "is registered with Carbon, which does not deliver synthetic events.")

    marker_path = pathlib.Path(marker_path)
    ax_available = ax_accessibility_available(pid)
    preexisting = ax_matching_windows(pid) if ax_available else []

    first_seen_ns = None
    match_count_at_stop = 0
    gaps = []
    marker_result = (None, None)  # (window_id, block_tuple) — both None means "not yet"
    keydown_ns = 0
    host_window_id = None
    presentation_block = None

    # **Known-invalid preconditions are checked BEFORE any synthetic input**
    # (cloud review P1, C1 repair round 2). A keypress cannot produce
    # evidence `adjudicate_ax_overlay` will accept when the AX tree is
    # unreadable or a match already exists — driving the key anyway wastes a
    # real press, and a synthetic keypress on an already-doomed launch is not
    # free: it is the exact input this instrument exists to measure the
    # effect of.
    if ax_available and not preexisting:
        keydown_ns = time.perf_counter_ns()
        _si.modifier_down(binding.keycode)
        last = time.perf_counter_ns()
        deadline = last + int(timeout_s * 1e9)
        try:
            while time.perf_counter_ns() < deadline:
                matches = ax_matching_windows(pid)
                seen = time.perf_counter_ns()
                gaps.append((seen - last) / 1e6)
                last = seen
                # **The tested stopping rule, actually called** (cloud review
                # P1, C1 repair round 2) — `ax_overlay_has_appeared` was
                # tested but the live loop reimplemented its condition inline,
                # so a mutant weakening the real rule left the whole suite
                # green.
                if ax_overlay_has_appeared(len(matches)) and first_seen_ns is None:
                    first_seen_ns = seen
                    match_count_at_stop = len(matches)
                if marker_result[0] is None and marker_result[1] is None:
                    try:
                        marker_text = marker_path.read_text()
                    except OSError:
                        marker_text = ""
                    marker_result = recording_host_marker_from(marker_text, exhausted=False)
                if marker_result[1] is not None:
                    # A definitive block. No amount of further AX polling
                    # changes a marker-level fault, so stop now rather than
                    # run out the clock on a verdict already decided.
                    break
                if first_seen_ns is not None and marker_result[0] is not None:
                    break
        finally:
            # Released whatever happened above. A modifier left down is a
            # stuck key for every app on the machine, and the failure path
            # is exactly when it is least likely to be noticed.
            _si.modifier_up(binding.keycode)

        if marker_result[0] is None and marker_result[1] is None:
            # Neither confirmed nor blocked when time ran out: force the
            # FINAL call, which is the one point "only .other, no .recording
            # yet" and "only .other, no .recording EVER" become the same
            # fact.
            try:
                marker_text = marker_path.read_text()
            except OSError:
                marker_text = ""
            marker_result = recording_host_marker_from(marker_text, exhausted=True)

        host_window_id, presentation_block = marker_result

    if presentation_block is not None:
        timing = OverlayTiming(verdict=presentation_block[0], detail=presentation_block[1],
                               window_id=host_window_id, keypress_ms=None)
    else:
        timing = adjudicate_ax_overlay(
            ax_available=ax_available,
            preexisting_count=len(preexisting),
            match_count_at_stop=match_count_at_stop,
            first_seen_ns=first_seen_ns,
            keydown_ns=keydown_ns,
            host_window_id=host_window_id)

    return {
        "verdict": timing.verdict,
        "detail": timing.detail,
        "keypress_ms": timing.keypress_ms,
        "window_id": timing.window_id,
        "host_window_id": host_window_id,
        "ax_available": ax_available,
        "match_count_at_stop": match_count_at_stop,
        "keycode": binding.keycode,
        "poll_resolution_ms_median": median(gaps) if gaps else None,
        "poll_resolution_ms_max": max(gaps) if gaps else None,
        "polls": len(gaps),
    }


def screen_lock_state(session_reader=None):
    """`True` locked, `False` unlocked, `None` could not tell.

    A readable WindowServer session uses presence semantics for
    `CGSSessionScreenIsLocked`: present and true means locked; absence means
    unlocked. Import failure, reader failure, a missing session, an unusable
    dictionary or an unexpected lock value remains unknown and fails closed.
    """
    if session_reader is None:
        try:
            import Quartz
            session_reader = Quartz.CGSessionCopyCurrentDictionary
        except Exception:
            return None

    try:
        session = session_reader()
    except Exception:
        return None

    if session is None or not hasattr(session, "get") or not hasattr(session, "__contains__"):
        return None

    key = "CGSSessionScreenIsLocked"
    if key not in session:
        return False

    value = session.get(key)
    if value is True or value == 1:
        return True
    if value is False or value == 0:
        return False
    return None


def screen_lock_block(state):
    """A verdict for a lock state, or `None` to proceed."""
    if state is True:
        return ("the screen is locked, so `loginwindow` owns the active Space and no "
                "app window is reachable. A latency figure taken here is a measurement "
                "of a different machine state, and this repo has already shipped one "
                "green whose screenshots were all the login window. Unlock and re-run.")
    if state is None:
        return ("could not read the login session, so whether the screen is locked is "
                "unknown. An instrument that cannot describe the machine must not "
                "measure it.")
    return None


def hardware_identity():
    """The machine, recorded with every run.

    A latency figure is a measurement OF THIS MAC. This one is further from the
    slowest supported machine than the last one was, so a bound cleared here is
    LOOSER than a real user's floor - and a receipt that does not name its host
    invites the opposite reading.
    """
    def sysctl(key):
        return subprocess.run(["/usr/sbin/sysctl", "-n", key],
                              capture_output=True, text=True).stdout.strip()
    return {
        "model": sysctl("hw.model"),
        "cpu": sysctl("machdep.cpu.brand_string"),
        "cores": sysctl("hw.ncpu"),
        "memory_bytes": sysctl("hw.memsize"),
        "os": subprocess.run(["/usr/bin/sw_vers", "-productVersion"],
                             capture_output=True, text=True).stdout.strip(),
    }


def reap(proc, *, timeout_s=10.0):
    """Terminate a launched app and make sure it is actually gone.

    **Every path that abandons a launch uses this one, and that is the point.**
    A bare `terminate()` followed by a raise is a request, not an outcome: a
    process slow to exit — or ignoring SIGTERM — outlives the exception, and the
    NEXT cold launch then either blocks on occupancy or, worse, is measured
    beside an orphan answering the same global hotkey and writing the same log.
    Every dev bundle on this machine is named `EnviousWispr Local.app`, so an
    orphan is not distinguishable by name from the instance under test.

    Bounded, then escalated, then waited on again: a `kill()` that is never
    reaped leaves a zombie, which `ps` still reports.
    """
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        # deadline-fallback: the signal is the process exiting; this bounds how
        # long a wedged instance can hold the shared dev-app slot.
        proc.wait(timeout=timeout_s)
        return
    except subprocess.TimeoutExpired:
        proc.kill()
    try:
        # deadline-fallback: same signal, after SIGKILL, so the child is reaped
        # rather than left as a zombie for the next occupancy probe to find.
        proc.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        pass


def await_launch_ready(proc, marker_path, *, run_id, expected_bundle,
                       ready_timeout_s=30.0, read_text=None):
    """Wait for the app's own readiness marker, and reap it on EVERY failure.

    **Separated from the launch so the guard can be tested at all**, and because
    the guard is the whole point: `proc` is alive from the moment `Popen`
    returns, so any exit from here that is not a success must leave nothing
    behind. Two of the three ways out are exceptional and one of those is not
    obvious — reading the marker file can raise on its own, if the output
    directory is cleaned up underneath the run or the filesystem returns an
    error. That escapes to `smoke()`, which turns it into `BLOCKED_LAUNCH` and
    returns a tidy-looking receipt while the app keeps running.

    An orphan is the expensive failure here rather than a cosmetic one: it
    blocks the next cold launch on occupancy, or worse is not noticed and
    answers the same global hotkey during someone else's measurement. Every dev
    bundle on this machine carries the same name, so it cannot be told apart
    from the instance under test.

    `BaseException` rather than `Exception`, deliberately: a Ctrl-C in the middle
    of a run is the case most likely to leave a stray app behind and the least
    likely to be cleaned up by hand afterwards.

    `read_text` exists for the suite, which cannot launch a real app to make the
    read fail.
    """
    read_text = read_text or (lambda: marker_path.read_text())
    try:
        deadline = time.monotonic() + ready_timeout_s
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(
                    f"the app exited during launch with {proc.returncode}")
            if launch_is_ready(read_text(), expected_run=run_id,
                               expected_pid=proc.pid, expected_bundle=expected_bundle):
                return
            # deadline-fallback: the interval between reads of the app's own
            # readiness marker, bounded by `ready_timeout_s` above. The signal is
            # the marker; this only decides how often we look for it.
            time.sleep(0.02)
        raise RuntimeError(
            f"no complete {LAUNCH_EXIT} marker for run {run_id} within "
            f"{ready_timeout_s}s. Either the build carries no emitter (a Release "
            f"build carries none by design), the marker environment did not reach "
            f"it, or the file holds a line this parser cannot read.")
    except BaseException:
        reap(proc)
        raise


def launch_with_markers(bundle_path, *, marker_dir, ready_timeout_s=30.0):
    """One cold launch with markers armed, returning everything needed to judge it.

    Launches the EXECUTABLE directly rather than through `open`, because `open`
    does not pass an environment through and the emitter is armed entirely by
    environment. The marker file is pre-created here: the app opens it WITHOUT
    `O_CREAT`, so an app that finds no file writes nothing rather than creating
    one somewhere unexpected.

    **Readiness comes from the SUBJECT, never from a settle time.** The app
    writes `launch.exit` when `applicationDidFinishLaunching` returns, which is
    the exact event a sleep would be guessing at — and a guess is wrong in both
    directions: too short and the press lands before the app can see it, too
    long and every launch pays for the slowest machine anyone ran this on.
    """
    requested = bundle_identity(bundle_path)
    run_id = str(uuid.uuid4()).upper()
    marker_path = pathlib.Path(marker_dir) / f"markers-{run_id}.tsv"
    marker_path.write_text("")

    env = dict(os.environ)
    env[MARKER_PATH_ENV] = str(marker_path)
    env[RUN_ID_ENV] = run_id

    proc = subprocess.Popen([requested.executable_path], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    await_launch_ready(proc, marker_path, run_id=run_id,
                       expected_bundle=requested.bundle_id,
                       ready_timeout_s=ready_timeout_s)
    return {"requested": requested, "run_id": run_id, "pid": proc.pid,
            "marker_path": marker_path, "process": proc}


def smoke(bundle_path, *, out_dir):
    """One bundle, one launch, one press: does the instrument produce a receipt?

    Returns a JSON-serialisable dict whose `verdict` is `SMOKE_PASS` or a
    `BLOCKED_` reason. It is never `BENCHMARK_PASS` — one bundle has nothing to
    be compared against.
    """
    out = {"kind": "smoke", "bundle": str(bundle_path),
           "hardware": hardware_identity()}

    # The screen lock is checked BEFORE occupancy, because it costs nothing and
    # invalidates the run whatever the slot looks like.
    lock = screen_lock_state()
    blocked_reason = screen_lock_block(lock)
    out["screen_locked"] = lock
    if blocked_reason:
        out["verdict"] = BLOCKED_SCREEN_LOCKED
        out["detail"] = blocked_reason
        return out

    # Occupancy: REFUSE rather than choose. Every dev bundle on this machine is
    # named the same, so picking one of two instances silently retargets the
    # measurement at somebody else's build.
    instances = running_instances()
    if instances:
        out["verdict"] = BLOCKED_OCCUPANCY
        out["detail"] = ("EnviousWispr is already running and this measurement needs a "
                         "cold launch it owns: " +
                         ", ".join(f"pid {p} at {x}" for p, x in sorted(instances.items())))
        return out

    try:
        launched = launch_with_markers(bundle_path, marker_dir=out_dir)
    except Exception as exc:
        out["verdict"] = BLOCKED_LAUNCH
        out["detail"] = f"{type(exc).__name__}: {exc}"
        return out

    resolved = None
    timing = None
    result = None
    failure = None
    timebase = None
    engine_ready_wait_ms = None
    engine_not_ready = False
    try:
        # Inside the reaped region, not before it. `mach_timebase()` loads a
        # native symbol and can raise; raising here with the app already launched
        # and the cleanup not yet armed leaves an orphan and produces no receipt
        # at all — the one run that most needs explaining.
        timebase = mach_timebase()
        # Gated BEFORE any synthetic input, on its OWN clock — never the one
        # `measure_keypress_to_overlay` starts below. A press sent while the
        # engine is still warming races `ColdPressGuard` (#879), which
        # correctly refuses it; this instrument's job is to avoid causing
        # that race, not to measure the app's response to it.
        ready_start = time.monotonic()
        engine_ready = await_engine_ready(
            launched["marker_path"], run_id=launched["run_id"],
            expected_pid=launched["pid"],
            expected_bundle=launched["requested"].bundle_id)
        engine_ready_wait_ms = (time.monotonic() - ready_start) * 1000.0
        if not engine_ready:
            engine_not_ready = True
        else:
            timing = measure_keypress_to_overlay(
                launched["pid"], launched["marker_path"])
            marker_text = launched["marker_path"].read_text()
            # `resolved_identity` raises if the pid is gone, which is exactly what a
            # crash during the take looks like. A traceback here would leave NO
            # receipt on disk for the one run that most needs explaining, so the
            # failure becomes a verdict rather than an exception.
            resolved = resolved_identity(launched["pid"])
            result = adjudicate_launch(
                marker_text,
                expected_run=launched["run_id"],
                expected_pid=launched["pid"],
                requested=launched["requested"],
                resolved=resolved,
                timebase=timebase)
    except Exception as exc:
        failure = f"{type(exc).__name__}: {exc}"
    finally:
        reap(launched["process"])

    out.update({
        "run_id": launched["run_id"],
        "pid": launched["pid"],
        "marker_path": str(launched["marker_path"]),
        "requested_identity": launched["requested"]._asdict(),
        "resolved_identity": resolved._asdict() if resolved else None,
        "timebase": timebase,
        "engine_ready_wait_ms": engine_ready_wait_ms,
        "keypress": timing,
        "detail": failure or (result.detail if result else ""),
        "sample": result.sample._asdict() if result and result.sample else None,
    })
    if engine_not_ready:
        out["verdict"] = BLOCKED_ENGINE_NOT_READY
        out["detail"] = (
            f"no complete {ENGINE_READY} marker for run {launched['run_id']} "
            f"within the warm-up wait; a keypress sent now would race "
            f"ColdPressGuard (#879)")
        return out
    if failure is not None:
        out["verdict"] = BLOCKED_LAUNCH
        return out
    if result.verdict != OK:
        out["verdict"] = result.verdict
        return out
    if timing["verdict"] != OK:
        # The markers can be complete while the keypress interval has no
        # identifiable endpoint. That is a block, never a pass with a missing
        # field: the plan's third bound is stated on this number.
        out["verdict"] = timing["verdict"]
        out["detail"] = timing["detail"]
        return out
    out["verdict"] = smoke_verdict(result)
    return out


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--smoke", action="store_true",
                    help="one bundle, one launch; proves the instrument, not the latency")
    ap.add_argument("--bundle", help="path to an EnviousWispr .app")
    ap.add_argument("--out-dir", default=None,
                    help="where the receipt and marker file are written")
    args = ap.parse_args(argv)

    if not args.smoke:
        ap.error("only --smoke is implemented in P6-C1; "
                 "the 30-pair benchmark run belongs to C4, after a final candidate exists")
    if not args.bundle:
        ap.error("--smoke needs --bundle")

    out_dir = pathlib.Path(args.out_dir or (pathlib.Path.cwd() / ".validation" /
                                            "runs" / "2377-p6c1-smoke"))
    out_dir.mkdir(parents=True, exist_ok=True)
    receipt = smoke(args.bundle, out_dir=out_dir)
    path = out_dir / "overlay-first-render-smoke.json"
    path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps(receipt, indent=2, sort_keys=True))
    print(f"\nreceipt: {path}")
    print(f"VERDICT: {receipt['verdict']}")
    return 0 if receipt["verdict"] == SMOKE_PASS else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
