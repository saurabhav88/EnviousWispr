"""Two-way control for the first-render measurement harness (#2377, P6-C1).

Written BEFORE the harness it tests, and run before it to prove the suite can
fail: a refusal set whose branches have never executed is indistinguishable from
one that does not work, and this phase's whole argument rests on the instrument
refusing rather than reporting.

Every refusal below sits beside an ACCEPTED twin differing in exactly one field,
so a parser that stopped adjudicating anything cannot read as clean. The twins
are the point; the rejections alone would pass against a function that blocks
unconditionally.

Run: `python3 Tests/RuntimeUAT/measure_overlay_first_render_test.py`
"""

import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import measure_overlay_first_render as m  # noqa: E402

# ---------------------------------------------------------------- fixtures

RUN = "6F1A2B3C-0000-4000-8000-000000000001"
PID = 4242
BUNDLE = "com.enviouswispr.app.dev"
EXE = "/Users/x/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"
SHA = "a" * 64

# 1/1 timebase: one tick is one nanosecond, so the arithmetic in a failure
# message is readable by whoever has to adjudicate it.
TIMEBASE = (1, 1)

REQUESTED = m.Identity(bundle_id=BUNDLE, executable_path=EXE, sha256=SHA)
RESOLVED = m.Identity(bundle_id=BUNDLE, executable_path=EXE, sha256=SHA)

# ticks chosen so the durations are whole milliseconds under a 1/1 timebase:
# launch 3 ms, root 2 ms.
GOOD_TICKS = {
    "launch.enter": 1_000_000,
    "launch.exit": 4_000_000,
    "root.construct.start": 10_000_000,
    "root.construct.end": 12_000_000,
    "host.order_front.complete": 13_000_000,
    # Deliberately BEFORE `launch.enter`'s own tick — proves position and
    # ticks are irrelevant to `engine.ready`, which sits outside `EVENTS`'s
    # causal chain entirely (#2377, C1 repair).
    "engine.ready": 500_000,
}

ORDER = [
    "launch.enter",
    "launch.exit",
    "root.construct.start",
    "root.construct.end",
    "host.order_front.complete",
]


# Only the host event names a window; every other event writes 0.
HOST_WINDOW = 4242


def line(event, *, ticks=None, run=RUN, pid=PID, bundle=BUNDLE, schema=m.SCHEMA,
         window=None, intent=None):
    t = GOOD_TICKS[event] if ticks is None else ticks
    if window is None:
        window = HOST_WINDOW if event == "host.order_front.complete" else 0
    if intent is None:
        # A single valid host marker is implicitly THE recording — matches
        # what every existing row already meant before intent existed.
        intent = m.INTENT_RECORDING if event == "host.order_front.complete" else m.INTENT_NONE
    return (f"{schema}\trun={run}\tpid={pid}\tbundle={bundle}"
            f"\tevent={event}\tticks={t}\twindow={window}\tintent={intent}")


def text(events=None, **kw):
    return "\n".join(line(e, **kw) for e in (ORDER if events is None else events)) + "\n"


def adjudicate(marker_text, *, requested=REQUESTED, resolved=RESOLVED,
               expected_run=RUN, expected_pid=PID):
    return m.adjudicate_launch(
        marker_text,
        expected_run=expected_run,
        expected_pid=expected_pid,
        requested=requested,
        resolved=resolved,
        timebase=TIMEBASE)


FAILURES = []


def expect(name, got, want):
    if got != want:
        FAILURES.append(f"{name}: expected {want!r}, got {got!r}")


def expect_verdict(name, marker_text, want, **kw):
    expect(name, adjudicate(marker_text, **kw).verdict, want)


# ------------------------------------------------------- 1. the accepted case

def test_valid_marker_set_accepts():
    r = adjudicate(text())
    expect("a complete, consistent marker set is accepted", r.verdict, m.OK)
    if r.sample is None:
        FAILURES.append("an accepted set must carry a sample")
        return
    expect("launch duration", r.sample.launch_ms, 3.0)
    expect("root construction duration", r.sample.root_ms, 2.0)
    expect("the sample carries the window the host named",
           r.sample.host_window_id, HOST_WINDOW)
    expect("smoke verdict on an accepted set", m.smoke_verdict(r), m.SMOKE_PASS)


# ---------------------------------------------- 2. every marker is REQUIRED

def test_missing_each_required_marker_blocks():
    for event in ORDER:
        remaining = [e for e in ORDER if e != event]
        expect_verdict(
            f"a set missing {event} blocks", text(remaining), m.BLOCKED_MISSING_MARKER)
    # TWIN: the same set with the marker restored is accepted, so the refusal
    # above is about the absence and not about the fixture.
    expect_verdict("restoring every marker accepts", text(), m.OK)


# ------------------------------------------- 3. pair ORDER, not merely presence

def test_partial_or_reversed_marker_pair_blocks():
    reversed_launch = ["launch.exit", "launch.enter",
                       "root.construct.start", "root.construct.end",
                       "host.order_front.complete"]
    expect_verdict("an exit line before its enter blocks",
                   text(reversed_launch), m.BLOCKED_PAIR_ORDER)
    reversed_root = ["launch.enter", "launch.exit",
                     "root.construct.end", "root.construct.start",
                     "host.order_front.complete"]
    expect_verdict("a root end before its start blocks",
                   text(reversed_root), m.BLOCKED_PAIR_ORDER)
    # TWIN: identical lines in the shipped order.
    expect_verdict("the same lines in order accept", text(), m.OK)


# --------------------------------------------------- 4. singletons are single

def test_duplicate_singleton_marker_blocks():
    doubled = ORDER + ["host.order_front.complete"]
    expect_verdict("a second host-order line blocks",
                   text(doubled), m.BLOCKED_DUPLICATE_MARKER)
    doubled_pair = ["launch.enter", "launch.enter", "launch.exit",
                    "root.construct.start", "root.construct.end",
                    "host.order_front.complete"]
    expect_verdict("a second launch-enter blocks",
                   text(doubled_pair), m.BLOCKED_DUPLICATE_MARKER)
    expect_verdict("one of each accepts", text(), m.OK)


# ------------------------------------------------------- 5. the schema itself

def test_unknown_schema_or_malformed_line_blocks():
    # Derived from `m.SCHEMA`, not hardcoded — a hardcoded "next version"
    # string is exactly the kind of row that silently stops testing what its
    # name claims the moment `SCHEMA` bumps again (cloud review P1, C1
    # repair round 2: this row already went stale once, when V1 became V2).
    current_suffix = m.SCHEMA[len(m.SCHEMA_FAMILY) + 2:]  # "_V2" -> "2"
    future_schema = f"{m.SCHEMA_FAMILY}_V{int(current_suffix) + 1}"
    expect_verdict("a future schema version blocks",
                   text(schema=future_schema), m.BLOCKED_MALFORMED_MARKER)
    expect_verdict("a line with a missing field blocks",
                   text() + f"{m.SCHEMA}\trun={RUN}\tpid={PID}\n",
                   m.BLOCKED_MALFORMED_MARKER)
    expect_verdict("a host marker naming window 0 blocks",
                   text()[: text().rindex("\twindow=")] + "\twindow=0\n",
                   m.BLOCKED_MALFORMED_MARKER)
    expect_verdict("a non-numeric window id blocks",
                   text().replace(f"window={HOST_WINDOW}", "window=main"),
                   m.BLOCKED_MALFORMED_MARKER)
    # The window contract runs BOTH ways: only the host event names a window.
    # A non-host event carrying one means the emitter writes something this
    # parser does not model, and a contract stated only in a comment is the
    # shape that retires a check instead of failing it.
    expect_verdict("a launch event carrying a window blocks",
                   text().replace("event=launch.enter\tticks=1000000\twindow=0",
                                  "event=launch.enter\tticks=1000000\twindow=42"),
                   m.BLOCKED_MALFORMED_MARKER)
    # TWIN: the same events with window=0, which is the shipped form.
    expect_verdict("non-host events carrying window 0 accept", text(), m.OK)
    expect_verdict("a non-numeric tick count blocks",
                   text().replace("ticks=1000000", "ticks=soon"),
                   m.BLOCKED_MALFORMED_MARKER)
    expect_verdict("an unknown event name blocks",
                   text().replace("event=launch.enter", "event=launch.begin"),
                   m.BLOCKED_MALFORMED_MARKER)
    # An EMPTY file is missing evidence, never a pass, and never a crash.
    expect_verdict("an empty marker file blocks", "", m.BLOCKED_MISSING_MARKER)
    # TWIN: unrelated noise around a complete set is tolerated, because the
    # schema prefix is what selects our lines. Blocking on it would make the
    # instrument refuse whenever anything else wrote to the file.
    expect_verdict("a foreign line beside a complete set accepts",
                   "some other tool wrote this\n" + text(), m.OK)


# ----------------------------------------------------------- 6. WHOSE launch

def test_wrong_run_pid_or_bundle_blocks():
    expect_verdict("a marker from another run blocks",
                   text(run="6F1A2B3C-0000-4000-8000-000000000002"), m.BLOCKED_WRONG_APP)
    expect_verdict("a marker from another pid blocks",
                   text(pid=9999), m.BLOCKED_WRONG_APP)
    expect_verdict("a marker naming another bundle blocks",
                   text(bundle="com.enviouswispr.app"), m.BLOCKED_WRONG_APP)
    other = m.Identity(bundle_id="com.enviouswispr.app",
                       executable_path=EXE, sha256=SHA)
    expect_verdict("a resolved bundle differing from the requested one blocks",
                   text(), m.BLOCKED_WRONG_APP, resolved=other)
    elsewhere = m.Identity(bundle_id=BUNDLE,
                           executable_path="/somewhere/else/EnviousWispr", sha256=SHA)
    expect_verdict("a resolved executable PATH differing from the requested one blocks",
                   text(), m.BLOCKED_WRONG_APP, resolved=elsewhere)
    expect_verdict("the matching identity accepts", text(), m.OK)


# ------------------------ 7. the version can agree while the BYTES do not

def test_same_bundle_version_but_different_executable_hash_blocks():
    # Same bundle id, same path, ONE NIBBLE of the hash different. This is the
    # case a bundle-id check cannot see, and it is the one that matters: two
    # worktrees' dev builds are both `EnviousWispr Local.app`.
    nibble = m.Identity(bundle_id=BUNDLE, executable_path=EXE, sha256="b" + "a" * 63)
    expect_verdict("one changed hash nibble blocks",
                   text(), m.BLOCKED_WRONG_APP, resolved=nibble)
    expect_verdict("restoring the hash accepts", text(), m.OK)


# ------------------------------------------------------------- 8. time's arrow

def test_non_monotonic_ticks_block():
    # Lines in the right ORDER, ticks going backwards. Distinct from case 3:
    # there the file was out of order, here the clock is.
    backwards = text().replace("ticks=4000000", "ticks=999999")
    expect_verdict("an exit earlier than its enter blocks",
                   backwards, m.BLOCKED_NON_MONOTONIC)
    equal = text().replace("ticks=4000000", "ticks=1000000")
    expect_verdict("a zero-length launch blocks", equal, m.BLOCKED_NON_MONOTONIC)
    expect_verdict("increasing ticks accept", text(), m.OK)


# -------------- 8b. the WHOLE chain, which is what forbids a synchronous root

def test_root_construction_inside_launch_blocks():
    """Phase 6 moves root construction OUT of launch. The instrument must not
    certify the arrangement being moved away from.

    Two pairs checked separately accept a synchronous build: `enter < exit` holds
    and `start < end` holds, and nothing asks whether the root was built BEFORE
    launch returned. Only the full chain does.
    """
    synchronous = ["launch.enter", "root.construct.start", "root.construct.end",
                   "launch.exit", "host.order_front.complete"]
    expect_verdict("a root built inside launch blocks on file order",
                   text(synchronous), m.BLOCKED_PAIR_ORDER)
    # The same claim in TICKS rather than file order: lines in the shipped order,
    # but root construction starting before launch returned.
    early = text().replace("ticks=10000000", "ticks=2000000")
    expect_verdict("a root whose ticks start before launch returned blocks",
                   early, m.BLOCKED_NON_MONOTONIC)
    # And the host cannot order a panel front before the root finished existing.
    before_root = text().replace("ticks=13000000", "ticks=11000000")
    expect_verdict("a host order-front before root construction ended blocks",
                   before_root, m.BLOCKED_NON_MONOTONIC)
    # TWIN: the correctly ordered set, unchanged, is accepted.
    expect_verdict("the deferred arrangement accepts", text(), m.OK)


# ------------------- 8c. WHICH window ended the interval, named by the app

def test_ax_overlay_endpoint_waits_for_our_identified_window():
    """The app names the subject via a fixed AX identifier; the harness times it.

    **AX membership, not CGWindow-list membership (cloud review P1, #2377).**
    CGWindow-list registration can precede SwiftUI content actually being
    composited, so the plan's own "first-AX-overlay" language is the binding
    requirement, not an implementation detail. The adjudicator is pure — no
    polling, no live process — so every branch is one row here.
    """
    t0 = 1_000_000_000

    ordinary = m.adjudicate_ax_overlay(
        ax_available=True, preexisting_count=0, match_count_at_stop=1,
        first_seen_ns=t0 + 9_000_000, keydown_ns=t0, host_window_id=HOST_WINDOW)
    expect("the ordinary case accepts", ordinary.verdict, m.OK)
    expect("with the harness's own timestamp", ordinary.keypress_ms, 9.0)
    expect("the marker's window id is carried as a receipt, not the stopwatch",
           ordinary.window_id, HOST_WINDOW)

    unavailable = m.adjudicate_ax_overlay(
        ax_available=False, preexisting_count=0, match_count_at_stop=0,
        first_seen_ns=None, keydown_ns=t0, host_window_id=None)
    expect("AX permission unavailable blocks", unavailable.verdict,
           m.BLOCKED_AX_UNAVAILABLE)

    # Already present at key-down: not an event this keypress caused.
    already_there = m.adjudicate_ax_overlay(
        ax_available=True, preexisting_count=1, match_count_at_stop=1,
        first_seen_ns=t0 + 9_000_000, keydown_ns=t0, host_window_id=HOST_WINDOW)
    expect("a match that existed before the keypress blocks",
           already_there.verdict, m.BLOCKED_NO_OVERLAY)
    expect("and carries no timing", already_there.keypress_ms, None)

    never = m.adjudicate_ax_overlay(
        ax_available=True, preexisting_count=0, match_count_at_stop=0,
        first_seen_ns=None, keydown_ns=t0, host_window_id=HOST_WINDOW)
    expect("no match before the deadline blocks", never.verdict, m.BLOCKED_NO_OVERLAY)

    # More than one match at the moment of first appearance is refused, never
    # averaged or picked from.
    ambiguous = m.adjudicate_ax_overlay(
        ax_available=True, preexisting_count=0, match_count_at_stop=2,
        first_seen_ns=t0 + 9_000_000, keydown_ns=t0, host_window_id=HOST_WINDOW)
    expect("more than one matching AX window blocks",
           ambiguous.verdict, m.BLOCKED_AMBIGUOUS_OVERLAY)

    # TWIN for the whole group: the ordinary case above (exactly one match,
    # nothing preexisting, AX available) accepts.


def test_the_ax_stopping_rule_fires_on_the_first_match():
    """The rule that decides when to STOP polling, tested directly.

    Every other row here tests the adjudicator, which runs once the loop has
    already stopped. That leaves the stop condition itself untested — a
    regression to "wait for two matches" or "never stop" would leave every
    adjudicator row still passing. This is the row that fails when it is.
    """
    expect("no match does not stop polling", m.ax_overlay_has_appeared(0), False)
    expect("one match stops polling", m.ax_overlay_has_appeared(1), True)
    expect(
        "more than one match ALSO stops polling — ambiguity is judged AFTER "
        "stopping, by the adjudicator, never by waiting to see if it resolves",
        m.ax_overlay_has_appeared(2), True)

    # **The tested rule must be the BOUND rule, not a reimplementation
    # sitting beside it** (cloud review P1, C1 repair round 2). Every
    # assertion above tests `ax_overlay_has_appeared` directly; none of them
    # can see whether the LIVE poll loop actually calls it, versus
    # reimplementing its condition inline — which is exactly what the first
    # draft of this repair did, silently, with every row above still green.
    harness_source = pathlib.Path(__file__).with_name("measure_overlay_first_render.py")
    if not harness_source.exists():
        FAILURES.append(f"the harness is not at {harness_source}; this test's path is stale")
        return
    if "ax_overlay_has_appeared(len(matches))" not in harness_source.read_text():
        FAILURES.append(
            "the live poll loop does not call ax_overlay_has_appeared(len(matches)) — "
            "the stopping rule tested above is not the one the loop actually uses")


def test_a_half_written_line_is_not_a_marker():
    """The emitter loops on a short write, so a poller can read mid-line.

    A line is finished when a newline follows it. Reading the tail costs a false
    verdict about the app; discarding it costs one more poll.
    """
    complete = text()
    partial = complete[: complete.rindex("\n")]  # same bytes, no trailing newline

    expect("a complete launch.exit is ready",
           m.launch_is_ready(complete, expected_run=RUN, expected_pid=PID,
                             expected_bundle=BUNDLE), True)
    # The launch line itself, truncated mid-write.
    launch_only = line("launch.enter") + "\n" + line("launch.exit")
    expect("a launch.exit with no newline yet is NOT ready",
           m.launch_is_ready(launch_only, expected_run=RUN, expected_pid=PID,
                             expected_bundle=BUNDLE), False)
    expect("the same line, finished, is ready",
           m.launch_is_ready(launch_only + "\n", expected_run=RUN, expected_pid=PID,
                             expected_bundle=BUNDLE), True)
    # Readiness is about THIS launch, not about the event name appearing.
    expect("another run's launch.exit is not this launch's readiness",
           m.launch_is_ready(complete, expected_run="SOMEONE-ELSE", expected_pid=PID,
                             expected_bundle=BUNDLE), False)
    expect("nor another pid's",
           m.launch_is_ready(complete, expected_run=RUN, expected_pid=9999,
                             expected_bundle=BUNDLE), False)

    # The host half of the same problem.
    window, failure = m.recording_host_marker_from(partial, exhausted=False)
    expect("a half-written host line is 'not yet', not a verdict", window, None)
    expect("and not a failure either", failure, None)
    window, failure = m.recording_host_marker_from(complete, exhausted=False)
    expect("the finished line names the window", window, HOST_WINDOW)
    # A malformed line that IS finished is a real failure and must not be
    # swallowed by the same truncation rule that hides an unfinished one.
    malformed = complete.replace(f"window={HOST_WINDOW}", "window=main")
    expect("a finished malformed host line blocks",
           m.recording_host_marker_from(malformed, exhausted=False)[1][0],
           m.BLOCKED_MALFORMED_MARKER)


def test_recording_host_marker_is_read_from_the_marker_text():
    """`recording_host_marker_from` is what the live loop polls with, so it
    gets its own rows: an absent marker is 'not yet', never a verdict."""
    window, failure = m.recording_host_marker_from(text(), exhausted=False)
    expect("a complete file names the window", window, HOST_WINDOW)
    expect("and reports no failure", failure, None)

    partial = text([e for e in ORDER if e != "host.order_front.complete"])
    window, failure = m.recording_host_marker_from(partial, exhausted=False)
    expect("a file without the host marker is not yet, not a verdict", window, None)
    expect("and still no failure", failure, None)

    doubled = m.recording_host_marker_from(
        text(ORDER + ["host.order_front.complete"]), exhausted=False)
    expect("two host markers of the same intent are refused, not averaged",
           doubled[1][0], m.BLOCKED_DUPLICATE_MARKER)


def test_wrong_presentation_binding_is_refused():
    """A shared retained panel means ANY presentation can win the marker race.

    Grounded in a real path, not a hypothetical: `WisprBootstrapper
    .applicationDidFinishLaunching` starts an async crash-recovery scan on
    EVERY launch (`Task { await recoveryCoordinator.scanAndRecover() }`),
    which presents "behind the blocking recovering pill" through the SAME
    retained panel the keypress-triggered recording uses. Without intent,
    whichever wins the presentation race silently binds the marker.
    """
    def markers(*host_lines):
        return "\n".join([
            line("launch.enter"), line("launch.exit"),
            line("root.construct.start"), line("root.construct.end"),
        ] + list(host_lines)) + "\n"

    other_then_recording = markers(
        line("host.order_front.complete", window=7, intent=m.INTENT_OTHER,
             ticks=13_000_000),
        line("host.order_front.complete", window=99, intent=m.INTENT_RECORDING,
             ticks=14_000_000))
    window, failure = m.recording_host_marker_from(other_then_recording, exhausted=False)
    expect("an unrelated presentation before the recording blocks", window, None)
    if failure is None:
        FAILURES.append("other-before-recording did not block at all")
    else:
        expect("with the specific wrong-presentation verdict",
               failure[0], m.BLOCKED_WRONG_PRESENTATION)

    recording_then_other = markers(
        line("host.order_front.complete", window=99, intent=m.INTENT_RECORDING,
             ticks=13_000_000),
        line("host.order_front.complete", window=7, intent=m.INTENT_OTHER,
             ticks=14_000_000))
    window, failure = m.recording_host_marker_from(recording_then_other, exhausted=False)
    expect("a LATER unrelated presentation does not invalidate the recording",
           window, 99)
    expect("and reports no failure", failure, None)

    other_only = markers(
        line("host.order_front.complete", window=7, intent=m.INTENT_OTHER))
    window, failure = m.recording_host_marker_from(other_only, exhausted=False)
    expect("an other-only file is not yet decidable mid-poll", window, None)
    expect("the recording MIGHT still arrive, so no block yet", failure, None)
    window, failure = m.recording_host_marker_from(other_only, exhausted=True)
    expect("but IS decidable once polling has stopped", window, None)
    if failure is None:
        FAILURES.append("an exhausted other-only file did not block")
    else:
        expect("with the wrong-presentation verdict, since something DID present",
               failure[0], m.BLOCKED_WRONG_PRESENTATION)

    # Missing/illegal intent is malformed, exercised through the REAL parser
    # rather than by constructing a `Marker` by hand.
    illegal_intent = text().replace("intent=recording", "intent=urgent")
    expect_verdict("an illegal intent value is malformed",
                   illegal_intent, m.BLOCKED_MALFORMED_MARKER)
    missing_intent_field = text().replace("\tintent=recording", "")
    expect_verdict("a missing intent field is malformed",
                   missing_intent_field, m.BLOCKED_MALFORMED_MARKER)

    # The mutation control: if the Director's classifier were broken so the
    # UNRELATED presentation were ALSO tagged `.recording` — indistinguishable
    # from the real one — the FIRST control above stops being able to catch
    # it. Both markers now read intent=recording, which is a DUPLICATE, not a
    # wrong-presentation case; the verdict CLASS changes, which is what proves
    # this suite is sensitive to the classifier rather than only to marker
    # shape.
    if_misclassified = markers(
        line("host.order_front.complete", window=7, intent=m.INTENT_RECORDING,
             ticks=13_000_000),
        line("host.order_front.complete", window=99, intent=m.INTENT_RECORDING,
             ticks=14_000_000))
    window, failure = m.recording_host_marker_from(if_misclassified, exhausted=False)
    expect("misclassifying BOTH as recording still blocks", window, None)
    if failure is None:
        FAILURES.append("two same-intent markers did not block at all")
    else:
        expect(
            "but as duplicate-marker, not wrong-presentation — the first "
            "control's specific verdict would no longer distinguish this case "
            "from a real misclassification",
            failure[0], m.BLOCKED_DUPLICATE_MARKER)


def test_known_invalid_ax_preconditions_never_touch_the_record_key():
    """A synthetic keypress on a launch already known to be unusable is not
    free (cloud review P1, C1 repair round 2): it is the exact input this
    instrument exists to measure the effect of, so AX-unavailable and
    a-match-already-exists must refuse BEFORE any input, not after.

    `simulate_input`/`ptt_binding` are imported LAZILY inside
    `measure_keypress_to_overlay`, so a fake registered in `sys.modules`
    before the call is what `import ... as _si` finds instead of the real
    one. `ax_accessibility_available`/`ax_matching_windows` are called
    unqualified at module scope, so replacing the attribute on `m` itself
    is enough — no `sys.modules` trick needed for those two.
    """
    import types

    class SpyInput(types.ModuleType):
        def __init__(self, name):
            super().__init__(name)
            self.down_calls = []
            self.up_calls = []

        def modifier_down(self, keycode):
            self.down_calls.append(keycode)

        def modifier_up(self, keycode):
            self.up_calls.append(keycode)

    fake_ptt = types.ModuleType("ptt_binding")
    fake_ptt.resolve = lambda: types.SimpleNamespace(
        is_modifier_only=True, key_name="fn (globe)", keycode=63)
    spy = SpyInput("simulate_input")

    saved_modules = {name: sys.modules.get(name) for name in ("simulate_input", "ptt_binding")}
    saved_ax_available = m.ax_accessibility_available
    saved_ax_matching = m.ax_matching_windows
    saved_lock_state = m.screen_lock_state
    sys.modules["simulate_input"] = spy
    sys.modules["ptt_binding"] = fake_ptt
    # Locked out (`False` = unlocked) for every case below except the one
    # that tests it — real PTT resolution and AX queries are already mocked
    # here, so the screen lock must be too, or this test's own verdict
    # depends on whether the machine running it happens to be locked.
    # `screen_lock_block` itself stays real: it is pure and deterministic
    # given `screen_lock_state`'s True/False/None.
    m.screen_lock_state = lambda: False
    try:
        m.ax_accessibility_available = lambda pid: False
        m.ax_matching_windows = lambda pid: []
        result = m.measure_keypress_to_overlay(4242, "/nonexistent-marker-path")
        expect("AX-unavailable never presses the record key", spy.down_calls, [])
        expect("and never releases it either", spy.up_calls, [])
        expect("while still reporting the right verdict",
               result["verdict"], m.BLOCKED_AX_UNAVAILABLE)

        m.ax_accessibility_available = lambda pid: True
        m.ax_matching_windows = lambda pid: [object()]
        result = m.measure_keypress_to_overlay(4242, "/nonexistent-marker-path")
        expect("a preexisting match never presses the record key either",
               spy.down_calls, [])
        expect("nor releases it", spy.up_calls, [])
        expect("while still reporting the right verdict",
               result["verdict"], m.BLOCKED_NO_OVERLAY)

        # A screen that locked in the gap between smoke()'s own recheck and
        # this function's PTT/AX resolution work must ALSO refuse before any
        # input — this is the LAST possible gate, immediately before
        # `modifier_down` (#2377, C1 repair): AX is available and no match
        # preexists, so without this check the press would go through.
        m.ax_accessibility_available = lambda pid: True
        m.ax_matching_windows = lambda pid: []
        m.screen_lock_state = lambda: True
        result = m.measure_keypress_to_overlay(4242, "/nonexistent-marker-path")
        expect("a screen locked right before the press never presses the record key",
               spy.down_calls, [])
        expect("nor releases it", spy.up_calls, [])
        expect("while still reporting the right verdict",
               result["verdict"], m.BLOCKED_SCREEN_LOCKED)
        m.screen_lock_state = lambda: False

        # TWIN: with all three preconditions satisfied, the record key IS
        # pressed and released exactly once — the refusals above are about
        # the preconditions, not about this function never pressing a key
        # at all.
        m.ax_accessibility_available = lambda pid: True
        m.ax_matching_windows = lambda pid: []
        result = m.measure_keypress_to_overlay(4242, "/nonexistent-marker-path", timeout_s=0.05)
        expect("a clean precondition set presses the record key once", spy.down_calls, [63])
        expect("and releases it once", spy.up_calls, [63])
    finally:
        for name, mod in saved_modules.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod
        m.ax_accessibility_available = saved_ax_available
        m.ax_matching_windows = saved_ax_matching
        m.screen_lock_state = saved_lock_state


def test_screen_lock_brackets_the_whole_measured_interval():
    """A pre-press check alone cannot see the screen lock DURING the AX poll
    (up to `timeout_s`, not instantaneous) — only bracketing both ends of
    the interval closes that (#2377, C1 repair). `screen_lock_state`
    returns `[False, True]`: unlocked when the pre-press check runs, locked
    by the time the post-measure check runs after polling completes. The
    press still happens — the pre-press check correctly saw it as safe —
    but the sample must still be blocked.
    """
    import types

    class SpyInput(types.ModuleType):
        def __init__(self, name):
            super().__init__(name)
            self.down_calls = []
            self.up_calls = []

        def modifier_down(self, keycode):
            self.down_calls.append(keycode)

        def modifier_up(self, keycode):
            self.up_calls.append(keycode)

    fake_ptt = types.ModuleType("ptt_binding")
    fake_ptt.resolve = lambda: types.SimpleNamespace(
        is_modifier_only=True, key_name="fn (globe)", keycode=63)
    spy = SpyInput("simulate_input")

    saved_modules = {name: sys.modules.get(name) for name in ("simulate_input", "ptt_binding")}
    saved_ax_available = m.ax_accessibility_available
    saved_ax_matching = m.ax_matching_windows
    saved_lock_state = m.screen_lock_state
    sys.modules["simulate_input"] = spy
    sys.modules["ptt_binding"] = fake_ptt
    lock_sequence = iter([False, True])
    m.screen_lock_state = lambda: next(lock_sequence, True)
    try:
        m.ax_accessibility_available = lambda pid: True
        m.ax_matching_windows = lambda pid: []
        result = m.measure_keypress_to_overlay(4242, "/nonexistent-marker-path", timeout_s=0.05)
        expect("the pre-press check passed, so the press still occurs once",
               spy.down_calls, [63])
        expect("and releases once", spy.up_calls, [63])
        expect("but the post-measure check blocks the sample",
               result["verdict"], m.BLOCKED_SCREEN_LOCKED)
        expect("no keypress figure for a sample taken against a locked screen",
               result["keypress_ms"], None)
    finally:
        for name, mod in saved_modules.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod
        m.ax_accessibility_available = saved_ax_available
        m.ax_matching_windows = saved_ax_matching
        m.screen_lock_state = saved_lock_state


# -------------------------------------------------- 9. thirty pairs, exactly


def ok_result(launch_ms, root_ms, run):
    """One accepted launch. `run` is REQUIRED — every side of every pair is its
    own cold launch, and a shared default is how a fixture quietly stops
    expressing that."""
    return m.LaunchResult(
        verdict=m.OK, detail="",
        sample=m.LaunchSample(run=run, launch_ms=launch_ms, root_ms=root_ms,
                              order_front_ms=root_ms + 1.0,
                              host_window_id=HOST_WINDOW))


def pairs(n, *, a_launch=10.0, b_launch=10.0, a_root=2.0, b_root=2.0,
          a_key=100.0, b_key=100.0, bad_index=None, shared_run=False):
    out = []
    for i in range(n):
        a_run = RUN if shared_run else f"RUN-A-{i:04d}"
        b_run = RUN if shared_run else f"RUN-B-{i:04d}"
        a = ok_result(a_launch, a_root, a_run)
        b = ok_result(b_launch, b_root, b_run)
        if bad_index == i:
            b = m.LaunchResult(verdict=m.BLOCKED_MISSING_MARKER,
                               detail="host.order_front.complete", sample=None)
        # The keypress figure names the launch it came from, so a crossed or
        # reused measurement cannot pass the run check on the launch alone.
        out.append(m.Pair(
            order=("AB" if i % 2 == 0 else "BA"), a=a, b=b,
            a_keypress=m.KeypressSample(run=a.sample.run if a.sample else a_run,
                                        keypress_ms=a_key),
            b_keypress=m.KeypressSample(run=b.sample.run if b.sample else b_run,
                                        keypress_ms=b_key)))
    return out


BUDGET = m.Budget(launch_median_regression_ms=5.0,
                  root_p95_ms=8.0,
                  keypress_p95_regression_ms=16.7)


def test_29_pairs_block_and_30_pairs_pass():
    expect("29 pairs block",
           m.adjudicate_benchmark(pairs(29), BUDGET).verdict, m.BLOCKED_INCOMPLETE_PAIRS)
    expect("31 pairs block",
           m.adjudicate_benchmark(pairs(31), BUDGET).verdict, m.BLOCKED_INCOMPLETE_PAIRS)
    expect("30 pairs within budget pass",
           m.adjudicate_benchmark(pairs(30), BUDGET).verdict, m.BENCHMARK_PASS)


def test_one_invalid_sample_blocks_without_top_up():
    # 30 pairs, one of them carrying a blocked launch. The count is right and
    # the evidence is not, and a harness that topped up would select for
    # favourable runs.
    r = m.adjudicate_benchmark(pairs(30, bad_index=7), BUDGET)
    expect("one blocked launch among thirty blocks the whole run",
           r.verdict, m.BLOCKED_INCOMPLETE_PAIRS)
    if m.BLOCKED_MISSING_MARKER not in r.detail:
        FAILURES.append(
            f"the block must name the underlying refusal, got {r.detail!r}")
    expect("thirty clean pairs pass",
           m.adjudicate_benchmark(pairs(30), BUDGET).verdict, m.BENCHMARK_PASS)


def test_benchmark_fails_on_a_real_regression():
    # FAIL is a verdict about the CODE and is reachable only when the evidence
    # is complete. Without this row every red result would be a BLOCK, and the
    # budget would bind nothing.
    over = m.adjudicate_benchmark(pairs(30, b_launch=16.0), BUDGET)
    expect("a 6 ms launch median regression fails", over.verdict, m.BENCHMARK_FAIL)
    under = m.adjudicate_benchmark(pairs(30, b_launch=14.0), BUDGET)
    expect("a 4 ms launch median regression passes", under.verdict, m.BENCHMARK_PASS)
    root_over = m.adjudicate_benchmark(pairs(30, b_root=9.0), BUDGET)
    expect("root construction above 8 ms p95 fails", root_over.verdict, m.BENCHMARK_FAIL)
    root_under = m.adjudicate_benchmark(pairs(30, b_root=7.0), BUDGET)
    expect("root construction below 8 ms p95 passes", root_under.verdict, m.BENCHMARK_PASS)
    key_over = m.adjudicate_benchmark(pairs(30, b_key=120.0), BUDGET)
    expect("a 20 ms keypress regression fails", key_over.verdict, m.BENCHMARK_FAIL)
    key_under = m.adjudicate_benchmark(pairs(30, b_key=115.0), BUDGET)
    expect("a 15 ms keypress regression passes", key_under.verdict, m.BENCHMARK_PASS)


# ---------------------------------------------------------- 10. the schedule

def test_schedule_is_15_ab_and_15_ba():
    s = m.paired_schedule(30)
    expect("the schedule has one entry per pair", len(s), 30)
    expect("fifteen pairs run A first", s.count("AB"), 15)
    expect("fifteen pairs run B first", s.count("BA"), 15)
    # Alternating, so a thermal or cache drift across the run cannot land on
    # one bundle: any monotone trend is split evenly between the two.
    expect("the orders alternate", s[:4], ["AB", "BA", "AB", "BA"])
    # A schedule that is not 15/15 is refused rather than silently run.
    expect("an unbalanced schedule blocks",
           m.adjudicate_benchmark(
               [p._replace(order="AB") for p in pairs(30)], BUDGET).verdict,
           m.BLOCKED_SCHEDULE)
    # BALANCED IS NOT THE REQUIREMENT. Fifteen AB then fifteen BA counts 15/15
    # and hands the whole first half of any thermal or cache drift to one
    # bundle — the exact bias alternation exists to cancel.
    grouped = [p._replace(order=("AB" if i < 15 else "BA"))
               for i, p in enumerate(pairs(30))]
    expect("a balanced but GROUPED schedule blocks",
           m.adjudicate_benchmark(grouped, BUDGET).verdict, m.BLOCKED_SCHEDULE)
    expect("the alternating schedule passes",
           m.adjudicate_benchmark(pairs(30), BUDGET).verdict, m.BENCHMARK_PASS)


def test_every_side_must_be_its_own_cold_launch():
    """One launch reused sixty times satisfies every other check and produces a
    zero-variance benchmark that looks superb. The run id is what distinguishes
    thirty cold launches from one launch counted thirty times."""
    expect("sixty sides sharing one run id block",
           m.adjudicate_benchmark(pairs(30, shared_run=True), BUDGET).verdict,
           m.BLOCKED_INCOMPLETE_PAIRS)
    expect("sixty distinct runs pass",
           m.adjudicate_benchmark(pairs(30), BUDGET).verdict, m.BENCHMARK_PASS)


# -------------------------------------------------------- 11. the statistics

def test_median_uses_statistics_median():
    import statistics
    for values in ([1.0], [1.0, 2.0], [3.0, 1.0, 2.0], [4.0, 1.0, 3.0, 2.0]):
        expect(f"median{values}", m.median(values), statistics.median(values))


def test_p95_uses_nearest_rank():
    # Nearest rank: ceil(0.95 * n)-th value of the sorted list, 1-indexed.
    # With 20 values that is the 19th, NOT an interpolation between the 19th
    # and 20th — the two differ, and only one of them is a value that was
    # actually observed.
    values = [float(i) for i in range(1, 21)]
    expect("p95 of 1..20 is the 19th value", m.nearest_rank(values, 95), 19.0)
    expect("p95 of a single value is that value", m.nearest_rank([7.0], 95), 7.0)
    expect("p50 of 1..20 is the 10th value", m.nearest_rank(values, 50), 10.0)
    expect("p95 of 1..30 is the 29th value",
           m.nearest_rank([float(i) for i in range(1, 31)], 95), 29.0)
    # Order of the input must not matter.
    expect("p95 is order-independent",
           m.nearest_rank(list(reversed(values)), 95), 19.0)


# ------------------------------------------- 12. the OTHER implementation

EMITTER = (pathlib.Path(__file__).resolve().parents[2]
           / "Sources" / "EnviousWisprAppKit" / "App" / "Debug"
           / "OverlayFirstRenderMarkers.swift")
HOST = (pathlib.Path(__file__).resolve().parents[2]
        / "Sources" / "EnviousWisprAppKit" / "App" / "Overlay"
        / "OverlayWindowHost.swift")
DIRECTOR = (pathlib.Path(__file__).resolve().parents[2]
            / "Sources" / "EnviousWisprAppKit" / "App" / "Overlay"
            / "OverlayDirector.swift")
BOOTSTRAPPER = (pathlib.Path(__file__).resolve().parents[2]
                / "Sources" / "EnviousWisprAppKit" / "App" / "WisprBootstrapper.swift")


def test_the_swift_emitter_and_this_parser_agree_on_the_schema():
    """The schema has TWO implementations and nothing else links them.

    The app builds marker lines in Swift; this module parses them in Python. A
    rename on either side leaves the other compiling and passing its own tests,
    and the failure surfaces as `BLOCKED_MALFORMED_MARKER` on a benchmark night
    — reading as a broken app rather than as a drifted contract.

    So assert the agreement HERE, where it is one file read, rather than
    discovering it from a live launch. Not a substitute for the live smoke: this
    proves the two spellings match, never that the app reaches the call sites.
    """
    if not EMITTER.exists():
        FAILURES.append(f"the emitter is not at {EMITTER}; this test's path is stale")
        return
    swift = EMITTER.read_text()
    if f'"{m.SCHEMA}' not in swift:
        FAILURES.append(
            f"the emitter does not write {m.SCHEMA!r}; the schema token has drifted")
    for event in m.EVENTS:
        if f'"{event}"' not in swift:
            FAILURES.append(f"the emitter has no case spelled {event!r}")
    # `engine.ready` is a KNOWN event but deliberately not part of `EVENTS`'s
    # causal chain — checked separately so it never silently joins that list.
    if f'"{m.ENGINE_READY}"' not in swift:
        FAILURES.append(f"the emitter has no case spelled {m.ENGINE_READY!r}")
    if m.ENGINE_READY in m.EVENTS:
        FAILURES.append(
            f"{m.ENGINE_READY!r} joined the launch/root causal chain (EVENTS) — "
            "engine warm-up and first render run on independent schedules")
    for key in ("run=", "pid=", "bundle=", "event=", "ticks=", "window=", "intent="):
        if key not in swift:
            FAILURES.append(f"the emitter does not write the {key!r} field")
    # The environment names are the emitter's arming contract, and the harness
    # sets them. A rename on one side is a silent no-op on the other.
    for env in (m.MARKER_PATH_ENV, m.RUN_ID_ENV):
        if env not in swift:
            FAILURES.append(f"the emitter does not read {env}")
    # PAIRED REJECTION: a name this parser does NOT know must be absent, or the
    # checks above would pass against an emitter that writes something else too.
    if "launch.begin" in swift:
        FAILURES.append("the emitter writes an event this parser cannot read")

    # The intent values, spelled `case <name>` in the Swift enum — the same
    # PAIRED-REJECTION shape as the events above: an intent this parser does
    # NOT know must be absent, checked as one row so the acceptance checks
    # cannot pass against an emitter that also writes something else.
    for intent in m.INTENTS:
        if f"case {intent}" not in swift:
            FAILURES.append(f"the emitter has no Intent case spelled {intent!r}")
    if "case urgent" in swift:
        FAILURES.append("the emitter writes an intent this parser cannot read")

    # The AX identifier the harness polls for must be the exact string set on
    # the panel, or the C1-repair endpoint swap silently measures nothing.
    if f'"{m.AX_PANEL_IDENTIFIER}"' not in swift:
        FAILURES.append(
            f"the emitter does not define {m.AX_PANEL_IDENTIFIER!r}; the AX identity "
            "the harness polls for has drifted")

    host = HOST.read_text() if HOST.exists() else ""
    if "setAccessibilityIdentifier" not in host:
        FAILURES.append(
            "the host does not set an AX identifier on the panel; the AX endpoint has "
            "nothing to poll for")


def test_the_host_marker_is_emitted_with_a_real_window_number():
    """The window id is the newest field and the one that carries the fix.

    A host marker that always wrote 0 would parse, block every run as malformed,
    and read as a broken app. So bind the CALL SITE's source of the value, not
    just the field's spelling: `OverlayWindowHost` must pass
    `panel.windowNumber`, and it must do so on the `emitFirst` path.
    """
    if not HOST.exists():
        FAILURES.append(f"the host is not at {HOST}; this test's path is stale")
        return
    swift = HOST.read_text()
    if "window: panel.windowNumber" not in swift:
        FAILURES.append(
            "the host does not pass panel.windowNumber to the marker; the harness "
            "would have no window to wait for")
    if "emitFirst" not in swift:
        FAILURES.append(
            "the host no longer emits the order-front marker once per process")

    # **The AX identifier must be set AFTER `orderFrontRegardless()`, never at
    # construction (cloud review P1, C1 repair round 2).**
    # `accessibilityWindows` enumerates every application window regardless of
    # visibility, so setting the identifier in `ensurePanel()` would let the
    # harness's AX poll match a panel that has no content and was never
    # ordered front — a timestamp for an event the user cannot see. Source
    # order is the only thing that can catch this class of regression; the
    # marker format does not change when it does.
    #
    # **Scoped to `present()`'s own body, and matched against the FULL call**
    # (round 2 of this control): a global `.find()` for the bare substrings
    # matches this very comment, which mentions both names — so a regression
    # that moved the REAL call into `ensurePanel()` while leaving the comment
    # here would still read as passing. Isolating the function and requiring
    # the complete call text is what makes the control test the call site,
    # not the prose describing it.
    identifier_call = (
        "panel.setAccessibilityIdentifier("
        "OverlayFirstRenderMarkers.axPanelIdentifier)"
    )
    # **Anchored to the CLASS, not just a bare function name** — Codex's first
    # draft of this control searched for `resizeCurrentPresentation(` from
    # the top of the file, which matches the `OverlayWindowHosting` PROTOCOL's
    # own requirement (identically indented, and textually first) before ever
    # reaching the real implementation — the exact same "found the wrong twin"
    # shape this repo has hit before. Starting from `final class
    # OverlayWindowHost` skips the protocol declaration entirely.
    class_start = swift.find("final class OverlayWindowHost")
    present_start = swift.find("\n  func present(", class_start) if class_start >= 0 else -1
    present_end = (
        swift.find("\n  func resizeCurrentPresentation(", class_start)
        if class_start >= 0 else -1)
    if class_start < 0 or present_start < 0 or present_end < 0:
        FAILURES.append("could not isolate OverlayWindowHost.present() by source markers")
    elif swift.count(identifier_call) != 1:
        FAILURES.append(
            "the AX identifier must be assigned exactly once in OverlayWindowHost, via "
            f"the exact call {identifier_call!r}")
    else:
        order_front_index = swift.find(
            "panel.orderFrontRegardless()", present_start, present_end)
        identifier_index = swift.find(identifier_call, present_start, present_end)
        if order_front_index < 0 or identifier_index < 0:
            FAILURES.append(
                "present() must assign the AX identifier after orderFrontRegardless()")
        elif identifier_index < order_front_index:
            FAILURES.append(
                "present() assigns the AX identifier before orderFrontRegardless()")

    # The root markers must be HELD, not emitted where they are captured.
    # Emitting at the capture site puts the marker's own write inside the
    # keypress interval in the baseline bundle and outside it in the prewarmed
    # one, so the benchmark credits the change for removing instrumentation cost
    # that is not production work. Nothing about the marker FORMAT changes when
    # this regresses, so no other row here would notice.
    if not DIRECTOR.exists():
        FAILURES.append(f"the director is not at {DIRECTOR}; this test's path is stale")
        return
    d = DIRECTOR.read_text()
    emitter = EMITTER.read_text()
    if "OverlayFirstRenderMarkers.hold(" not in d:
        FAILURES.append(
            "the director does not HOLD its root captures; emitting them at the "
            "capture site biases the keypress comparison toward the prewarmed bundle")
    if "OverlayFirstRenderMarkers.emit(" in d:
        FAILURES.append(
            "the director emits directly, which is the biased form this test exists "
            "to refuse")

    # `hold` must take exactly ONE Capture, never variadic (#2377, C1
    # repair): a variadic parameter allocates a temporary `[Capture]` at
    # its CALL SITE before the function body runs, the same asymmetric
    # cost `reserveCapacity` below exists to avoid one level up. Bound at
    # BOTH ends — the signature itself, and each of the two call sites
    # appearing exactly once with a single argument — so a revert of
    # either half is caught, including the less-obvious one-element-array
    # regression that keeps the call sites looking unchanged.
    if "public static func hold(_ capture: Capture)" not in emitter:
        FAILURES.append("hold must accept exactly one Capture")
    if "func hold(_ captures: Capture...)" in emitter:
        FAILURES.append("hold regressed to a call-site-allocating variadic")
    if d.count("OverlayFirstRenderMarkers.hold(constructStart)") != 1:
        FAILURES.append("root construction must hold constructStart once")
    if d.count("OverlayFirstRenderMarkers.hold(constructEnd)") != 1:
        FAILURES.append("root construction must hold constructEnd once")
    if "hold(constructStart, constructEnd)" in d:
        FAILURES.append("root markers regressed to one variadic call")

    # **The production intent classifier must be BOUND, not just present**
    # (cloud review P1, C1 repair round 2). Every Python row above proves the
    # ADJUDICATOR reads intent correctly from fabricated marker text; none of
    # them can see whether the Director actually asks `isRecording` before
    # tagging a presentation. Flipping the real classifier to always say
    # `.recording` would leave all 28 Python rows green, because they never
    # read this file. This is the same defect class the marker's own window
    # number was written to fix, one call site over.
    if ("OverlayFirstRenderMarkers.withPresentationIntent(" not in d
            or "Self.isRecording(presentation) ? .recording : .other" not in d):
        FAILURES.append(
            "the director does not wrap host.present with "
            "withPresentationIntent(Self.isRecording(presentation) ? .recording : .other) "
            "— the intent tag is no longer bound to the real classifier, so a broken "
            "classifier would leave every marker-shape test green")

    # Holding is not enough on its own: an empty array allocates its buffer on
    # the FIRST append, which in the baseline bundle happens inside the keypress
    # interval and in the prewarmed one does not. The reservation has to happen
    # in `prepare()`, which runs before either interval.
    if "pending.reserveCapacity" not in emitter:
        FAILURES.append(
            "prepare() does not reserve the held-capture storage; the first hold "
            "would allocate inside the keypress interval in one bundle only")
    if "removeAll(keepingCapacity: true)" not in emitter:
        FAILURES.append(
            "the flush frees the capacity it just used, inside the interval it was "
            "reserved to stay out of")

    # `emitEngineReadyOnce()` must be emitted FROM INSIDE a complete
    # selected/active/readiness guard at EACH launch warm-up path
    # separately (#2377, C1 repair) — checking that four required
    # substrings all appear somewhere in a scoped window passes a mutant
    # that moves the emit call immediately ABOVE its own `if`: all four
    # strings are still present in the window, just no longer nested
    # inside the brace. Matching one
    # CONTIGUOUS block — the exact `if ... { emit }` text — is what proves
    # containment, not mere co-occurrence.
    if not BOOTSTRAPPER.exists():
        FAILURES.append(f"the bootstrapper is not at {BOOTSTRAPPER}; this test's path is stale")
        return
    boot = BOOTSTRAPPER.read_text()
    for label, anchor, backend, driver in (
        ("WhisperKit preloadAction",
         "preloadAction: { [weak whisperKitKernelDriver] in",
         "whisperKit", "whisperKitKernelDriver"),
        ("parakeet launch Task",
         "Task { [weak kernelDriver] in",
         "parakeet", "kernelDriver"),
    ):
        start = boot.find(anchor)
        if start < 0:
            FAILURES.append(f"could not locate the {label} call site by its capture list")
            continue
        window = boot[start:start + 1000]
        required_block = "\n".join((
            f"          if settings.selectedBackend == .{backend},",
            f"            asrManager.activeBackendType == .{backend},",
            f"            {driver}?.engineReadiness == .ready",
            "          {",
            "            OverlayFirstRenderMarkers.emitEngineReadyOnce()",
            "          }",
        ))
        if required_block not in window:
            FAILURES.append(
                f"the {label} path does not emit inside its complete "
                "selected/active/readiness guard")


# --------------------------------------- 12b. the engine-readiness gate

def test_engine_ready_is_a_known_event_outside_the_launch_causal_chain():
    """`engine.ready` must parse, but must never join `EVENTS` — the launch/
    root causal chain `adjudicate_launch` enforces. Mechanical guard for the
    fact `EVENTS`'s own comment states: engine warm-up and first render run
    on two independent schedules.
    """
    expect("engine.ready is not part of the launch causal chain",
           m.ENGINE_READY in m.EVENTS, False)
    expect("engine.ready is a known, parseable event",
           m.ENGINE_READY in m.KNOWN_EVENTS, True)


def test_parse_marker_line_accepts_a_well_formed_engine_ready_marker():
    parsed = m.parse_marker_line(line("engine.ready", ticks=500_000))
    expect("event", parsed.event, "engine.ready")
    expect("window is 0, like every non-host event", parsed.window, 0)
    expect("intent is none, like every non-host event", parsed.intent, m.INTENT_NONE)


def test_engine_ready_marker_position_never_affects_launch_adjudication():
    """Whether `engine.ready` is written first, last, or anywhere else in the
    file, and whatever tick it carries, a launch's OK verdict is unaffected —
    proof that it sits outside the enforced causal chain. `GOOD_TICKS` gives
    it an earlier tick than `launch.enter`'s own, which would trip
    `BLOCKED_NON_MONOTONIC` or `BLOCKED_PAIR_ORDER` were it a chain member.
    """
    expect_verdict("engine.ready written before the whole launch chain still accepts",
                   text(["engine.ready"] + ORDER), m.OK)
    expect_verdict("engine.ready written after the whole launch chain still accepts",
                   text(ORDER + ["engine.ready"]), m.OK)


def test_engine_is_ready_matches_exactly_this_launch():
    """Missing, wrong-run, wrong-pid, wrong-bundle, and partial readiness
    markers are all `False` — the precondition that must gate a synthetic
    keypress. `engine_is_ready` is what `smoke()` calls before it, so a
    `False` here is what keeps the press from ever being sent (proved by
    execution below, via `measure_after_engine_ready`).
    """
    marker = line("engine.ready", ticks=500_000)
    good = marker + "\n"
    expect("a matching complete marker is ready",
           m.engine_is_ready(good, expected_run=RUN, expected_pid=PID,
                             expected_bundle=BUNDLE),
           True)
    expect("no marker at all is not ready",
           m.engine_is_ready("", expected_run=RUN, expected_pid=PID,
                             expected_bundle=BUNDLE),
           False)
    expect("a wrong run is not ready",
           m.engine_is_ready(good, expected_run="OTHER-RUN-0000", expected_pid=PID,
                             expected_bundle=BUNDLE),
           False)
    expect("a wrong pid is not ready",
           m.engine_is_ready(good, expected_run=RUN, expected_pid=PID + 1,
                             expected_bundle=BUNDLE),
           False)
    expect("a wrong bundle is not ready",
           m.engine_is_ready(good, expected_run=RUN, expected_pid=PID,
                             expected_bundle="com.other.app"),
           False)
    # TWIN: a half-written line (no trailing newline yet) is not complete,
    # mirroring `read_complete_markers`'s own truncation discipline.
    expect("a half-written line is not ready",
           m.engine_is_ready(marker, expected_run=RUN, expected_pid=PID,
                             expected_bundle=BUNDLE),
           False)
    # Fails CLOSED on our own drifted format, not an exception with no verdict.
    expect("a malformed line of our own schema is not ready, not an exception",
           m.engine_is_ready(f"{m.SCHEMA}\tbroken\n", expected_run=RUN,
                             expected_pid=PID, expected_bundle=BUNDLE),
           False)


def test_await_engine_ready_waits_for_the_marker_and_times_out_without_it():
    """A separate clock from the keypress interval, and never a fixed sleep —
    the signal is the app's own marker, exactly like `await_launch_ready`.
    """
    calls = {"n": 0}
    ready_marker = line("engine.ready", ticks=500_000) + "\n"
    running = FakeProc()

    def eventually_ready():
        calls["n"] += 1
        return ready_marker if calls["n"] >= 3 else ""

    ready = m.await_engine_ready(
        "/nonexistent-marker-path", proc=running, run_id=RUN, expected_pid=PID,
        expected_bundle=BUNDLE, timeout_s=5.0, read_text=eventually_ready)
    expect("readiness is detected once the marker appears", ready, True)
    expect("it took more than one read to get there", calls["n"] >= 3, True)

    # TWIN: a marker for the WRONG run never satisfies readiness, and the
    # wait times out and reports False rather than hanging or raising.
    wrong_run_marker = line("engine.ready", ticks=500_000, run="SOME-OTHER-RUN") + "\n"
    never_ready = m.await_engine_ready(
        "/nonexistent-marker-path", proc=FakeProc(), run_id=RUN, expected_pid=PID,
        expected_bundle=BUNDLE, timeout_s=0.05, read_text=lambda: wrong_run_marker)
    expect("a marker for a different run never satisfies readiness", never_ready, False)


def test_await_engine_ready_raises_on_a_crash_rather_than_waiting_out_the_timeout():
    """A crash DURING warm-up must not burn the full timeout waiting for a
    marker that will never arrive, then report the plausible-sounding but
    wrong `BLOCKED_ENGINE_NOT_READY` (#2377, C1 repair). Watching
    `proc.poll()` is what tells the two apart.
    """
    crashed = FakeProc(already_gone=True)
    try:
        m.await_engine_ready(
            "/nonexistent-marker-path", proc=crashed, run_id=RUN, expected_pid=PID,
            expected_bundle=BUNDLE, timeout_s=5.0, read_text=lambda: "")
        FAILURES.append(
            "await_engine_ready did not raise when the process had already exited")
    except RuntimeError:
        pass


def test_measure_after_engine_ready_gates_the_keypress_by_call_count():
    """The "never press before the engine is ready" property, proved by
    EXECUTION rather than by reading `smoke()`'s source layout (#2377, C1
    repair) — a check that only sees where two calls sit in the file
    survives a regression that keeps the right shape but breaks the actual
    gating (e.g. a mutant `measure() if True else None`, still textually
    inside an `if`).
    """
    calls = {"n": 0}
    sentinel = object()

    def spy():
        calls["n"] += 1
        return sentinel

    not_ready_result = m.measure_after_engine_ready(False, spy)
    expect("a not-ready engine returns no measurement", not_ready_result, None)
    expect("and the measurement thunk is never called", calls["n"], 0)

    ready_result = m.measure_after_engine_ready(True, spy)
    expect("a ready engine returns the measurement", ready_result, sentinel)
    expect("calling the thunk exactly once", calls["n"], 1)


def _function_body(source, name, next_name):
    """One named function's own body text, isolated by its full definition
    signature — never a bare function name, which would match a call site
    instead (the same "found the wrong twin" class the AX-identifier order
    check hit before it anchored on `final class OverlayWindowHost`).

    Bound to exactly ONE function: a wide span covering several functions
    lets a required literal in an UNUSED sibling satisfy the check without
    the function actually under test containing it. `next_name` is the
    following top-level `def` that ends this one's body — pass the real next
    function so the span is exact, not a lowest-common-denominator boundary
    shared by every caller.
    """
    start = source.find(f"\ndef {name}(")
    end = source.find(f"\ndef {next_name}(", start) if start >= 0 else -1
    if start < 0 or end < 0:
        return None
    return source[start:end]


def test_smoke_routes_its_keypress_measurement_through_the_readiness_gate():
    """A CALLER-CONTRACT row (#2377, C1 repair): the previous test proved
    `measure_after_engine_ready` behaves correctly
    in isolation, which says nothing about whether the live sequence still
    CALLS it — replacing a live call with a direct measurement would leave
    that test green. This binds the exact live shape across the three
    functions that now share the sequence: `_drive_one_launch` (the
    readiness gate and screen-lock capture), `_launch_verdict` (the
    pre-press-lock verdict return), and `smoke` (the call graph tying them
    together plus the final adjudicator).
    """
    real_source = pathlib.Path(m.__file__).read_text()

    drive_body = _function_body(real_source, "_drive_one_launch", "_launch_receipt_fields")
    if drive_body is None:
        FAILURES.append("could not isolate _drive_one_launch()'s body")
        return

    ready_idx = drive_body.find("await_engine_ready(")
    if ready_idx < 0:
        FAILURES.append("_drive_one_launch() does not call await_engine_ready")
        return
    # Bound to THIS call, not merely present anywhere in the function — the
    # keyword must appear before the call's own closing paren is reached.
    call_end = drive_body.find(")", ready_idx)
    if 'proc=launched["process"]' not in drive_body[ready_idx:call_end + 1]:
        FAILURES.append(
            "_drive_one_launch()'s await_engine_ready call does not pass "
            'proc=launched["process"] — a crash during warm-up would wait '
            "out the full timeout instead of being detected")

    # `press_permitted` must be derived from BOTH facts — engine readiness
    # AND a screen-lock recheck taken AFTER the readiness wait (cloud review
    # P1, #2377 C1 repair): the launch and readiness waits can together run
    # long enough for the screen to lock after the caller's initial check,
    # which that initial check cannot see.
    if "pre_press_lock = screen_lock_state()" not in drive_body:
        FAILURES.append("_drive_one_launch() does not re-check the screen lock before the press")
    required_permit = "press_permitted = engine_ready and not pre_press_blocked"
    if required_permit not in drive_body:
        FAILURES.append(
            "_drive_one_launch() does not derive press_permitted from BOTH "
            "engine readiness and the pre-press screen-lock recheck")

    required_gate = "\n".join((
        "        timing = measure_after_engine_ready(",
        "            press_permitted,",
        "            lambda: measure_keypress_to_overlay(",
    ))
    gate_idx = drive_body.find(required_gate)
    if gate_idx < 0:
        FAILURES.append(
            "_drive_one_launch() does not route its keypress measurement "
            "through press_permitted")
    elif gate_idx < ready_idx:
        FAILURES.append(
            "_drive_one_launch() gates the keypress measurement BEFORE "
            "awaiting readiness — the readiness result it gates on would be stale")

    # CAPTURE lives in `_drive_one_launch`.
    required_screen_capture = "\n".join((
        "        elif pre_press_blocked:",
        "            screen_locked_before_press = pre_press_blocked",
    ))
    if required_screen_capture not in drive_body:
        FAILURES.append("_drive_one_launch() discards the pre-press lock block")

    # RETURN of that block's promised verdict lives in `_launch_verdict` —
    # bound separately, on ITS OWN function body, so each is proven rather
    # than inferred from the other.
    verdict_body = _function_body(real_source, "_launch_verdict", "smoke")
    if verdict_body is None:
        FAILURES.append("could not isolate _launch_verdict()'s body")
    else:
        required_screen_verdict = "\n".join((
            '    if piece["screen_locked_before_press"]:',
            '        return (BLOCKED_SCREEN_LOCKED, piece["screen_locked_before_press"])',
        ))
        if required_screen_verdict not in verdict_body:
            FAILURES.append("_launch_verdict() does not return the pre-press lock verdict")

    # `smoke()` must actually CALL `_drive_one_launch`, `_launch_receipt_fields`,
    # `_launch_verdict`, and the final adjudicator — the call graph itself,
    # not merely text that happens to exist in one of the three functions.
    # A wide span covering all three would let this pass with NO caller
    # actually wiring the pieces together.
    smoke_body = _function_body(real_source, "smoke", "_pin_identity")
    if smoke_body is None:
        FAILURES.append("could not isolate smoke()'s body")
        return
    required_final_adjudication = (
        'out["verdict"], out["detail"] = '
        'final_verdict_and_detail(piece["result"], piece["timing"])')
    for required, message in (
        ("_drive_one_launch(bundle_path, out_dir=out_dir)",
         "smoke() does not call _drive_one_launch"),
        ("_launch_receipt_fields(piece)",
         "smoke() does not call _launch_receipt_fields"),
        ("_launch_verdict(piece)", "smoke() does not call _launch_verdict"),
        (required_final_adjudication,
         "smoke() bypasses the timing-first final verdict adjudicator"),
    ):
        if required not in smoke_body:
            FAILURES.append(message)

    # CONTROL: a synthetic `smoke()` whose body calls a direct measurement
    # instead of `_drive_one_launch` must actually fail this test's own
    # call-graph check — proof it is not vacuously true. Never touches the
    # real file.
    bypassed_fake = (
        "\ndef smoke(bundle_path, *, out_dir):\n"
        "    ready = await_engine_ready(marker_path, proc=proc, run_id=run_id)\n"
        "    timing = measure_keypress_to_overlay(pid, marker_path)\n"
        "\ndef _pin_identity(bundle_path, label):\n")
    fake_smoke_body = _function_body(bypassed_fake, "smoke", "_pin_identity")
    if fake_smoke_body is None:
        FAILURES.append("the control fixture's own source markers do not isolate")
    elif "_drive_one_launch(bundle_path, out_dir=out_dir)" in fake_smoke_body:
        FAILURES.append(
            "the caller-contract check does not fail on a bypassed source — "
            "it cannot be trusted to catch a real regression")


def test_final_verdict_prefers_the_specific_keypress_diagnosis():
    """`timing`'s verdict must win over `result`'s (#2377, C1 repair). When
    AX is unavailable, `measure_keypress_to_overlay`
    writes no recording marker, so `adjudicate_launch` independently and
    correctly reports the true-but-less-informative `BLOCKED_MISSING_MARKER`
    for the SAME run — reporting THAT instead of the actual
    `BLOCKED_AX_UNAVAILABLE` would mask an unavailable precondition behind
    a verdict that reads like an app defect.
    """
    blocked_result = m.LaunchResult(
        verdict=m.BLOCKED_MISSING_MARKER, detail="host.order_front.complete",
        sample=None)
    ax_unavailable_timing = {"verdict": m.BLOCKED_AX_UNAVAILABLE,
                             "detail": "AX permission not granted"}
    verdict, detail = m.final_verdict_and_detail(blocked_result, ax_unavailable_timing)
    expect("the specific AX diagnosis wins over the generic marker block",
           verdict, m.BLOCKED_AX_UNAVAILABLE)
    expect("and carries its own detail, not the marker block's",
           detail, "AX permission not granted")

    # TWIN: when `timing` is OK, `result`'s own verdict is reported —
    # proving the reordering above is about PRIORITY, not about `result`
    # never being consulted at all.
    ok_timing = {"verdict": m.OK, "detail": "", "keypress_ms": 12.0}
    verdict, detail = m.final_verdict_and_detail(blocked_result, ok_timing)
    expect("result's own verdict is reported once timing is OK",
           verdict, m.BLOCKED_MISSING_MARKER)
    expect("with result's own detail", detail, "host.order_front.complete")

    # TWIN: both OK yields the smoke verdict, not a bare OK.
    ok_result = m.LaunchResult(verdict=m.OK, detail="", sample=None)
    verdict, detail = m.final_verdict_and_detail(ok_result, ok_timing)
    expect("both OK yields SMOKE_PASS, not a bare OK", verdict, m.SMOKE_PASS)


# ------------------------------------------- 13. nobody is left behind

class FakeProc:
    """Enough of `subprocess.Popen` to exercise the reaper's three outcomes."""

    def __init__(self, *, exits_on=None, already_gone=False, pid=4242):
        self.pid = pid
        # exits_on: which wait() call succeeds — 1 after TERM, 2 after KILL,
        # None for a process that ignores both.
        self.exits_on = exits_on
        self.already_gone = already_gone
        self.waits = 0
        self.terminated = False
        self.killed = False
        # Real `Popen.returncode` is `None` while running; `poll()`/`wait()`
        # set it as a side effect once the process exits. `already_gone`
        # models a process that was already dead when first observed, so it
        # is set once here rather than dynamically — enough for the crash
        # rows this fixture exercises, never a general `wait()` simulation.
        self.returncode = 0 if already_gone else None

    def poll(self):
        return 0 if self.already_gone else None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        self.waits += 1
        if self.exits_on is not None and self.waits >= self.exits_on:
            return 0
        import subprocess
        raise subprocess.TimeoutExpired(cmd="fake", timeout=timeout)


def test_an_abandoned_launch_is_actually_reaped():
    """A bare terminate-and-raise is a REQUEST, not an outcome.

    A process slow to exit, or ignoring SIGTERM, outlives the exception — and
    the next cold launch is then either blocked on occupancy or measured beside
    an orphan answering the same global hotkey and writing the same log. Every
    dev bundle here is named `EnviousWispr Local.app`, so an orphan is not
    distinguishable by name from the instance under test.
    """
    polite = FakeProc(exits_on=1)
    m.reap(polite, timeout_s=0.01)
    expect("a process that exits on TERM is not killed", polite.killed, False)
    expect("and it is waited on", polite.waits, 1)

    stubborn = FakeProc(exits_on=2)
    m.reap(stubborn, timeout_s=0.01)
    expect("a process that ignores TERM is killed", stubborn.killed, True)
    expect("and waited on again, so it is reaped rather than left a zombie",
           stubborn.waits, 2)

    wedged = FakeProc(exits_on=None)
    m.reap(wedged, timeout_s=0.01)
    expect("a wedged process is still killed", wedged.killed, True)
    expect("and the reaper returns rather than hanging the run", wedged.waits, 2)

    # TWIN: a process that has already exited is not signalled at all. Without
    # this the reaper would TERM a pid that may since have been recycled.
    gone = FakeProc(already_gone=True)
    m.reap(gone, timeout_s=0.01)
    expect("an already-exited process is not signalled", gone.terminated, False)
    expect("nor killed", gone.killed, False)


def test_every_exceptional_exit_from_the_readiness_wait_reaps():
    """`proc` is alive from the moment `Popen` returns, so nothing may leave here
    without it.

    Three ways out: ready (keep it), timeout (reap), and an exception from
    reading the marker file itself (reap). The third is the one that escaped —
    it is not a failure of the app, so nothing about it looks like a launch
    problem, and `smoke()` turns it into a tidy `BLOCKED_LAUNCH` receipt while
    the app keeps running.
    """
    good = (line("launch.enter") + "\n" + line("launch.exit") + "\n")

    # READY: the process is kept, not reaped.
    alive = FakeProc(exits_on=1)
    m.await_launch_ready(alive, pathlib.Path("/unused"), run_id=RUN,
                         expected_bundle=BUNDLE, ready_timeout_s=1.0,
                         read_text=lambda: good)
    expect("a ready launch is not terminated", alive.terminated, False)

    # TIMEOUT: never ready, so reaped and reported.
    timed_out = FakeProc(exits_on=1)
    try:
        m.await_launch_ready(timed_out, pathlib.Path("/unused"), run_id=RUN,
                             expected_bundle=BUNDLE, ready_timeout_s=0.05,
                             read_text=lambda: "")
        FAILURES.append("a launch that never became ready must raise")
    except RuntimeError:
        pass
    expect("a timed-out launch is reaped", timed_out.terminated, True)

    # THE ESCAPED CASE: reading the marker file raises.
    def explode():
        raise OSError("the output directory went away underneath the run")

    io_error = FakeProc(exits_on=1)
    try:
        m.await_launch_ready(io_error, pathlib.Path("/unused"), run_id=RUN,
                             expected_bundle=BUNDLE, ready_timeout_s=1.0,
                             read_text=explode)
        FAILURES.append("an unreadable marker file must not be swallowed")
    except OSError:
        pass
    expect("a launch whose marker read raises is still reaped",
           io_error.terminated, True)

    # And an interrupt, which is the case least likely to be cleaned up by hand.
    def interrupt():
        raise KeyboardInterrupt()

    interrupted = FakeProc(exits_on=1)
    try:
        m.await_launch_ready(interrupted, pathlib.Path("/unused"), run_id=RUN,
                             expected_bundle=BUNDLE, ready_timeout_s=1.0,
                             read_text=interrupt)
        FAILURES.append("an interrupt must propagate")
    except KeyboardInterrupt:
        pass
    expect("an interrupted launch is reaped", interrupted.terminated, True)


def test_a_locked_screen_blocks_before_a_launch_is_spent():
    """A locked screen is a different machine, not a slower one.

    `loginwindow` owns the active Space, no app window is reachable, and this
    repo has already shipped one green whose screenshots were all the login
    window. The check runs before occupancy because it costs nothing and
    invalidates the run whatever the slot looks like.
    """
    expect("a locked screen blocks", m.screen_lock_block(True) is not None, True)
    expect("an unlocked screen proceeds", m.screen_lock_block(False), None)
    # THE THIRD VALUE. Collapsing "could not tell" into "unlocked" would let the
    # run proceed on a machine it cannot describe — the exact shape that turns a
    # broken probe into a green.
    expect("an unreadable session blocks too",
           m.screen_lock_block(None) is not None, True)
    # The two refusals must not read the same, or a reader cannot tell a locked
    # screen from a probe that failed.
    if m.screen_lock_block(True) == m.screen_lock_block(None):
        FAILURES.append("locked and unknown must give distinguishable reasons")


def test_the_real_screen_lock_probe_distinguishes_absence_from_failure():
    """`screen_lock_block` above tests the POLICY on synthetic True/False/None.

    This tests the PROBE that produces those values. A live machine measurement
    (2026-08-26, this repo's own dev Mac, screen independently confirmed unlocked
    via `osascript` frontmost-process resolution and a non-overlay app window
    list) found `CGSSessionScreenIsLocked` absent from a perfectly valid session
    dict — not present-and-false, absent. Apple does not document the key as a
    standard session property, so presence-semantics (absent means unlocked) is
    the correct reading, not a broken probe. What must still fail closed is a
    session the probe genuinely could not read.
    """
    valid_session = {
        "kCGSessionUserIDKey": 501,
        "kCGSessionOnConsoleKey": True,
    }

    expect(
        "a valid session with no lock key is unlocked",
        m.screen_lock_state(lambda: valid_session),
        False,
    )

    expect(
        "a present true lock key is locked",
        m.screen_lock_state(
            lambda: {**valid_session, "CGSSessionScreenIsLocked": True}),
        True,
    )

    expect(
        "a present false lock key is unlocked",
        m.screen_lock_state(
            lambda: {**valid_session, "CGSSessionScreenIsLocked": False}),
        False,
    )

    expect(
        "no session remains unknown",
        m.screen_lock_state(lambda: None),
        None,
    )

    def failed_reader():
        raise RuntimeError("WindowServer probe failed")

    expect(
        "a failed session read remains unknown",
        m.screen_lock_state(failed_reader),
        None,
    )

    expect(
        "an unusable session object remains unknown",
        m.screen_lock_state(lambda: object()),
        None,
    )

    expect(
        "an unexpected lock value remains unknown",
        m.screen_lock_state(
            lambda: {**valid_session, "CGSSessionScreenIsLocked": "yes"}),
        None,
    )


def test_a_keypress_figure_must_name_the_launch_it_came_from():
    """Tagging the LAUNCHES is not enough; the timings need identity too.

    The distinct-run check validates `p.a`/`p.b`. A runner that reused a prior
    keypress result, or associated the two sides' timings the wrong way round,
    satisfies it completely — the launches are all distinct and only the numbers
    are wrong. `BENCHMARK_PASS` from cross-associated evidence is the worst
    outcome this instrument has, because every other check reads clean.
    """
    good = pairs(30)
    expect("matched timings pass",
           m.adjudicate_benchmark(good, BUDGET).verdict, m.BENCHMARK_PASS)

    # One side's keypress figure carries a run that is not its launch's.
    crossed = list(good)
    crossed[11] = crossed[11]._replace(
        b_keypress=m.KeypressSample(run="RUN-FROM-SOMEWHERE-ELSE",
                                    keypress_ms=100.0))
    r = m.adjudicate_benchmark(crossed, BUDGET)
    expect("a keypress figure from another run blocks",
           r.verdict, m.BLOCKED_INCOMPLETE_PAIRS)
    if "RUN-FROM-SOMEWHERE-ELSE" not in r.detail:
        FAILURES.append(f"the block must name the mismatched run: {r.detail!r}")

    # THE SWAP, which is the case a per-side check catches and a set check does
    # not: both runs are present and legitimate, on the wrong sides.
    swapped = list(good)
    p12 = swapped[12]
    swapped[12] = p12._replace(a_keypress=p12.b_keypress,
                               b_keypress=p12.a_keypress)
    expect("two legitimate timings on the wrong sides block",
           m.adjudicate_benchmark(swapped, BUDGET).verdict,
           m.BLOCKED_INCOMPLETE_PAIRS)

    expect("and the untouched set still passes",
           m.adjudicate_benchmark(pairs(30), BUDGET).verdict, m.BENCHMARK_PASS)


# ------------------------------------------------------- run_benchmark (C4)

def _fake_piece(*, run_id, identity, launch_ms=3.0, root_ms=2.0, keypress_ms=5.0):
    """A `_drive_one_launch` return value for a CLEAN launch — every field
    `run_benchmark` AND `_launch_receipt_fields` read, nothing they do not."""
    sample = m.LaunchSample(run=run_id, launch_ms=launch_ms, root_ms=root_ms,
                            order_front_ms=launch_ms + 1, host_window_id=7)
    return {
        "launched": {"run_id": run_id, "pid": 1000, "marker_path": f"/tmp/{run_id}.tsv",
                    "requested": identity},
        "resolved": identity, "timebase": (1, 1), "engine_ready_wait_ms": 1.0,
        "failure": None, "engine_not_ready": False,
        "screen_locked_before_press": None, "screen_locked_pre_press": False,
        "result": m.LaunchResult(verdict=m.OK, detail="", sample=sample),
        "timing": {
            "verdict": m.OK, "detail": "", "keypress_ms": keypress_ms,
            "window_id": 7, "host_window_id": 7, "ax_available": True,
            "match_count_at_stop": 1, "keycode": 61,
            "poll_resolution_ms_median": 0.25, "poll_resolution_ms_max": 0.5,
            "polls": 4, "screen_locked_pre_press": False,
            "screen_locked_post_measurement": False,
        },
    }


IDENTITY_A = m.Identity(bundle_id=BUNDLE, executable_path=EXE, sha256=SHA)
IDENTITY_B = m.Identity(bundle_id=BUNDLE, executable_path=EXE.replace("EnviousWispr", "EnviousWisprB"),
                        sha256="b" * 64)


def _identity_for(side):
    return IDENTITY_A if side == "A" else IDENTITY_B


def _patch_benchmark_environment(script):
    """Runs `script(calls)` with `_drive_one_launch`, `bundle_identity`,
    `screen_lock_state`, and `running_instances` all patched to synthetic,
    deterministic behavior — A and B pinned to genuinely DIFFERENT
    identities, since `run_benchmark` now refuses to compare a build with
    itself. `calls` accumulates one dict per launch in call order, so a test
    can assert on ORDER without depending on real timing.
    """
    calls = []

    saved = {
        "_drive_one_launch": m._drive_one_launch,
        "bundle_identity": m.bundle_identity,
        "screen_lock_state": m.screen_lock_state,
        "running_instances": m.running_instances,
    }
    m.screen_lock_state = lambda: False
    m.running_instances = lambda: {}
    m.bundle_identity = lambda bundle_path: (
        IDENTITY_A if str(bundle_path) == "A.app" else IDENTITY_B)

    def fake_drive(bundle_path, *, out_dir):
        run_id = f"RUN-{len(calls)}"
        side = "A" if str(bundle_path) == "A.app" else "B"
        calls.append({"bundle": str(bundle_path), "run_id": run_id})
        return _fake_piece(run_id=run_id, identity=_identity_for(side))

    m._drive_one_launch = fake_drive
    try:
        return script(calls)
    finally:
        for name, value in saved.items():
            setattr(m, name, value)


def test_run_benchmark_drives_pairs_in_the_declared_ab_ba_order():
    """The live driver must call the bundle matching `paired_schedule`'s own
    letters, in order — not merely alternate SOMETHING, which a bug swapping
    the bundle-for-letter mapping would still satisfy."""
    def script(calls):
        return m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    receipt = _patch_benchmark_environment(script)

    expect(f"{m.PAIR_COUNT} pairs drive exactly {m.PAIR_COUNT * 2} launches",
           receipt["pairs_completed"], m.PAIR_COUNT)
    expect("a clean run with distinct identities reaches a real benchmark verdict",
           receipt["verdict"] in (m.BENCHMARK_PASS, m.BENCHMARK_FAIL), True)
    expect("the schedule alternates AB/BA", receipt["schedule"][:4], ["AB", "BA", "AB", "BA"])
    # The letter 'A' must always resolve to "A.app" and 'B' to "B.app" in the
    # per-pair receipt — not merely alternate SOMETHING, which a bug swapping
    # the bundle-for-letter mapping would still satisfy.
    expect("every receipt row's side A used A.app",
           all(row["sides"]["A"]["bundle"] == "A.app" for row in receipt["pair_receipts"]), True)
    expect("every receipt row's side B used B.app",
           all(row["sides"]["B"]["bundle"] == "B.app" for row in receipt["pair_receipts"]), True)


def test_run_benchmark_blocks_on_identity_drift_mid_run_never_pass_or_fail():
    """A bundle rebuilt between two launches must BLOCK the whole run, never
    reach `BENCHMARK_PASS` or `BENCHMARK_FAIL` — the two-way control: the
    UNCHANGED twin (next test) completes normally."""
    identity_b_rebuilt = m.Identity(bundle_id=BUNDLE, executable_path=IDENTITY_B.executable_path,
                                    sha256="f" * 64)

    saved = {"_drive_one_launch": m._drive_one_launch,
            "bundle_identity": m.bundle_identity,
            "screen_lock_state": m.screen_lock_state,
            "running_instances": m.running_instances}
    m.screen_lock_state = lambda: False
    m.running_instances = lambda: {}
    # Pinning (the first two calls, one per bundle) sees the ORIGINAL identity.
    m.bundle_identity = lambda bundle_path: (
        IDENTITY_A if str(bundle_path) == "A.app" else IDENTITY_B)

    launch_calls = {"n": 0}

    def fake_drive(bundle_path, *, out_dir):
        launch_calls["n"] += 1
        run_id = f"RUN-{launch_calls['n']}"
        side = "A" if str(bundle_path) == "A.app" else "B"
        # Second overall launch (side B of pair 0) resolves to the rebuilt
        # identity, simulating a rebuild that landed between pinning and it.
        resolved = identity_b_rebuilt if launch_calls["n"] == 2 else _identity_for(side)
        return _fake_piece(run_id=run_id, identity=resolved)

    m._drive_one_launch = fake_drive
    try:
        receipt = m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    finally:
        for name, value in saved.items():
            setattr(m, name, value)

    expect("a mid-run identity drift blocks rather than PASS/FAIL",
           receipt["verdict"], m.BLOCKED_IDENTITY_DRIFT)
    expect("the run stopped at the drifted pair, none completed",
           receipt["pairs_completed"], 0)
    expect("side A of pair 0 launched, then side B drifted — exactly 2 launches",
           launch_calls["n"], 2)


def test_run_benchmark_completes_normally_when_identity_never_drifts():
    """TWIN of the drift test: the same run with identity held constant
    throughout must reach a real benchmark verdict, proving the drift
    test's block is about the DRIFT, not about identity-checking itself
    always blocking."""
    def script(calls):
        return m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    receipt = _patch_benchmark_environment(script)
    expect("an unchanged identity throughout reaches PASS or FAIL, never BLOCKED",
           receipt["verdict"] in (m.BENCHMARK_PASS, m.BENCHMARK_FAIL), True)
    expect(f"all {m.PAIR_COUNT} pairs completed", receipt["pairs_completed"], m.PAIR_COUNT)
    expect("the final re-hash is recorded", "final_identity" in receipt, True)
    expect("every pair produced a receipt row",
           len(receipt["pair_receipts"]), m.PAIR_COUNT)
    expect("each pair receipt row carries both arms",
           all(set(row["sides"]) == {"A", "B"} for row in receipt["pair_receipts"]), True)

    expect("the complete schedule is retained",
           receipt["schedule"], m.paired_schedule(m.PAIR_COUNT))
    expect("pair indexes and orders match that schedule",
           [(row["index"], row["order"]) for row in receipt["pair_receipts"]],
           list(enumerate(receipt["schedule"])))
    expect("the final identities equal the pinned identities",
           receipt["final_identity"], receipt["pinned_identity"])

    required_timing = {
        "keypress_ms", "host_window_id", "ax_available",
        "match_count_at_stop", "keycode", "poll_resolution_ms_median",
        "poll_resolution_ms_max", "polls",
        "screen_locked_pre_press", "screen_locked_post_measurement",
    }
    for row in receipt["pair_receipts"]:
        for side in ("A", "B"):
            item = row["sides"][side]
            expect(f"pair {row['index']} side {side} retains its pinned identity",
                   item["requested_identity"], receipt["pinned_identity"][side])
            expect(f"pair {row['index']} side {side} retains its resolved identity",
                   item["resolved_identity"], receipt["pinned_identity"][side])
            expect(f"pair {row['index']} side {side} retains the full timing receipt",
                   required_timing <= set(item["keypress"]), True)

    expect("both root p95 diagnostics are retained",
           {"root_p95_a_ms", "root_p95_b_ms"} <= set(receipt["measured"]), True)


def test_run_benchmark_stops_after_the_first_bad_side_no_top_up():
    """One blocked side must stop the run BEFORE launching that pair's other
    side, and before any further pair — no top-up (#2377, C4 plan §3 step 1),
    and no wasted launch on a pair that is already known bad."""
    launch_calls = {"n": 0}

    saved = {"_drive_one_launch": m._drive_one_launch,
            "bundle_identity": m.bundle_identity,
            "screen_lock_state": m.screen_lock_state,
            "running_instances": m.running_instances}
    m.screen_lock_state = lambda: False
    m.running_instances = lambda: {}
    m.bundle_identity = lambda bundle_path: (
        IDENTITY_A if str(bundle_path) == "A.app" else IDENTITY_B)

    def fake_drive(bundle_path, *, out_dir):
        launch_calls["n"] += 1
        run_id = f"RUN-{launch_calls['n']}"
        side = "A" if str(bundle_path) == "A.app" else "B"
        if launch_calls["n"] == 1:
            # The FIRST launch overall (side A of pair 0) never got
            # engine-ready — side B of that same pair must never launch.
            piece = _fake_piece(run_id=run_id, identity=_identity_for(side))
            piece["engine_not_ready"] = True
            return piece
        return _fake_piece(run_id=run_id, identity=_identity_for(side))

    m._drive_one_launch = fake_drive
    try:
        receipt = m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    finally:
        for name, value in saved.items():
            setattr(m, name, value)

    expect("a bad side blocks with the specific per-side reason",
           receipt["verdict"], m.BLOCKED_INCOMPLETE_PAIRS)
    expect("the detail names the underlying side verdict",
           m.BLOCKED_ENGINE_NOT_READY in receipt["detail"], True)
    expect("the run never reaches PASS or FAIL",
           receipt["verdict"] in (m.BENCHMARK_PASS, m.BENCHMARK_FAIL), False)
    expect("no pair completed", receipt["pairs_completed"], 0)
    expect("side B of the bad pair never launched — exactly 1 launch total",
           launch_calls["n"], 1)


def test_run_benchmark_rechecks_occupancy_before_every_launch():
    """A peer app appearing partway through a 30-pair run must block the
    NEXT launch it precedes, not only pair 0's initial check — a run
    spanning up to 60 launches is wide enough for a peer to appear well
    after the start."""
    launch_calls = {"n": 0}
    occupancy_calls = {"n": 0}

    saved = {"_drive_one_launch": m._drive_one_launch,
            "bundle_identity": m.bundle_identity,
            "screen_lock_state": m.screen_lock_state,
            "running_instances": m.running_instances}
    m.screen_lock_state = lambda: False
    m.bundle_identity = lambda bundle_path: (
        IDENTITY_A if str(bundle_path) == "A.app" else IDENTITY_B)

    def fake_instances():
        occupancy_calls["n"] += 1
        # Call 1 is the initial pre-loop check; call 2 is the per-side
        # recheck before pair 0 side A launches — both clear. Call 3 is the
        # recheck before pair 0 side B: a peer has appeared by then.
        return {} if occupancy_calls["n"] <= 2 else {4242: "/peer/EnviousWispr.app"}

    def fake_drive(bundle_path, *, out_dir):
        launch_calls["n"] += 1
        run_id = f"RUN-{launch_calls['n']}"
        side = "A" if str(bundle_path) == "A.app" else "B"
        return _fake_piece(run_id=run_id, identity=_identity_for(side))

    m.running_instances = fake_instances
    m._drive_one_launch = fake_drive
    try:
        receipt = m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    finally:
        for name, value in saved.items():
            setattr(m, name, value)

    expect("a peer appearing mid-run blocks on occupancy",
           receipt["verdict"], m.BLOCKED_OCCUPANCY)
    expect("only side A of pair 0 launched before the peer was seen",
           launch_calls["n"], 1)


def test_run_benchmark_rejects_any_pair_count_other_than_the_binding_thirty():
    """Fewer than 30 pairs has no statistical claim on a p95; more than 30
    is not the binding evidence set the plan names. Every count other than
    exactly `PAIR_COUNT` must block before any launch."""
    for bad_count in (0, 2, 29, 32):
        receipt = m.run_benchmark("A.app", "B.app", pairs=bad_count, out_dir="/tmp")
        expect(f"{bad_count} pairs blocks before any launch",
               receipt["verdict"], m.BLOCKED_INCOMPLETE_PAIRS)

    def script(calls):
        return m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    twin = _patch_benchmark_environment(script)
    expect(f"exactly {m.PAIR_COUNT} pairs reaches a real verdict, proving the "
           "count check is not vacuously blocking everything",
           twin["verdict"] in (m.BENCHMARK_PASS, m.BENCHMARK_FAIL), True)


def test_run_benchmark_refuses_two_arms_that_resolve_to_the_same_build():
    """Comparing a build with itself proves nothing about the optimization.
    Path OR hash matching alone must block."""
    saved = {"bundle_identity": m.bundle_identity,
            "screen_lock_state": m.screen_lock_state,
            "running_instances": m.running_instances}
    m.screen_lock_state = lambda: False
    m.running_instances = lambda: {}
    m.bundle_identity = lambda bundle_path: IDENTITY_A  # both arms identical
    try:
        receipt = m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    finally:
        for name, value in saved.items():
            setattr(m, name, value)
    expect("identical arms block before any launch",
           receipt["verdict"], m.BLOCKED_IDENTICAL_ARMS)


def test_cli_rejects_smoke_with_an_explicit_pairs_argument():
    """`--smoke --pairs 30` must be refused even though 30 equals the
    benchmark default — the parser cannot tell an explicit benchmark-only
    argument from an unset one unless the default itself is `None`."""
    calls = {"n": 0}
    saved_drive = m._drive_one_launch
    m._drive_one_launch = lambda bundle_path, *, out_dir: calls.__setitem__("n", calls["n"] + 1)
    try:
        exited = None
        try:
            m.main(["--smoke", "--bundle", "A.app", "--pairs", "30"])
        except SystemExit as exc:
            exited = exc.code
    finally:
        m._drive_one_launch = saved_drive

    expect("--smoke --pairs 30 exits with an argparse error", exited, 2)
    expect("no launch was ever attempted", calls["n"], 0)


def test_run_benchmark_pins_identity_before_the_first_pair():
    """Both bundles' identities must be read BEFORE pair 0 launches, not
    lazily on first use — else a rebuild during pair 0 itself would have no
    baseline to be compared against."""
    order = []

    saved = {"_drive_one_launch": m._drive_one_launch,
            "bundle_identity": m.bundle_identity,
            "screen_lock_state": m.screen_lock_state,
            "running_instances": m.running_instances}
    m.screen_lock_state = lambda: False
    m.running_instances = lambda: {}

    def fake_identity(bundle_path):
        order.append(("pin", str(bundle_path)))
        return IDENTITY_A if str(bundle_path) == "A.app" else IDENTITY_B

    def fake_drive(bundle_path, *, out_dir):
        order.append(("launch", str(bundle_path)))
        side = "A" if str(bundle_path) == "A.app" else "B"
        return _fake_piece(run_id=f"RUN-{len(order)}", identity=_identity_for(side))

    m.bundle_identity = fake_identity
    m._drive_one_launch = fake_drive
    try:
        m.run_benchmark("A.app", "B.app", pairs=m.PAIR_COUNT, out_dir="/tmp")
    finally:
        for name, value in saved.items():
            setattr(m, name, value)

    expect("both bundles are pinned before the first launch",
           order[:2], [("pin", "A.app"), ("pin", "B.app")])


# ------------------------------------------------------------------- runner

TESTS = [
    test_valid_marker_set_accepts,
    test_missing_each_required_marker_blocks,
    test_partial_or_reversed_marker_pair_blocks,
    test_duplicate_singleton_marker_blocks,
    test_unknown_schema_or_malformed_line_blocks,
    test_wrong_run_pid_or_bundle_blocks,
    test_same_bundle_version_but_different_executable_hash_blocks,
    test_non_monotonic_ticks_block,
    test_root_construction_inside_launch_blocks,
    test_ax_overlay_endpoint_waits_for_our_identified_window,
    test_the_ax_stopping_rule_fires_on_the_first_match,
    test_a_half_written_line_is_not_a_marker,
    test_recording_host_marker_is_read_from_the_marker_text,
    test_wrong_presentation_binding_is_refused,
    test_known_invalid_ax_preconditions_never_touch_the_record_key,
    test_screen_lock_brackets_the_whole_measured_interval,
    test_29_pairs_block_and_30_pairs_pass,
    test_one_invalid_sample_blocks_without_top_up,
    test_benchmark_fails_on_a_real_regression,
    test_schedule_is_15_ab_and_15_ba,
    test_every_side_must_be_its_own_cold_launch,
    test_the_swift_emitter_and_this_parser_agree_on_the_schema,
    test_the_host_marker_is_emitted_with_a_real_window_number,
    test_engine_ready_is_a_known_event_outside_the_launch_causal_chain,
    test_parse_marker_line_accepts_a_well_formed_engine_ready_marker,
    test_engine_ready_marker_position_never_affects_launch_adjudication,
    test_engine_is_ready_matches_exactly_this_launch,
    test_await_engine_ready_waits_for_the_marker_and_times_out_without_it,
    test_await_engine_ready_raises_on_a_crash_rather_than_waiting_out_the_timeout,
    test_measure_after_engine_ready_gates_the_keypress_by_call_count,
    test_smoke_routes_its_keypress_measurement_through_the_readiness_gate,
    test_final_verdict_prefers_the_specific_keypress_diagnosis,
    test_an_abandoned_launch_is_actually_reaped,
    test_every_exceptional_exit_from_the_readiness_wait_reaps,
    test_a_locked_screen_blocks_before_a_launch_is_spent,
    test_the_real_screen_lock_probe_distinguishes_absence_from_failure,
    test_a_keypress_figure_must_name_the_launch_it_came_from,
    test_median_uses_statistics_median,
    test_p95_uses_nearest_rank,
    test_run_benchmark_drives_pairs_in_the_declared_ab_ba_order,
    test_run_benchmark_blocks_on_identity_drift_mid_run_never_pass_or_fail,
    test_run_benchmark_completes_normally_when_identity_never_drifts,
    test_run_benchmark_stops_after_the_first_bad_side_no_top_up,
    test_run_benchmark_rechecks_occupancy_before_every_launch,
    test_run_benchmark_rejects_any_pair_count_other_than_the_binding_thirty,
    test_run_benchmark_refuses_two_arms_that_resolve_to_the_same_build,
    test_cli_rejects_smoke_with_an_explicit_pairs_argument,
    test_run_benchmark_pins_identity_before_the_first_pair,
]


def main():
    for t in TESTS:
        before = len(FAILURES)
        try:
            t()
        except Exception as exc:  # a raising adjudicator is itself a failure
            FAILURES.append(f"{t.__name__}: raised {type(exc).__name__}: {exc}")
        if len(FAILURES) == before:
            print(f"ok   {t.__name__}")
        else:
            print(f"FAIL {t.__name__}")
    for f in FAILURES:
        print(f"  - {f}")
    print(f"{len(TESTS)} tests, {len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
