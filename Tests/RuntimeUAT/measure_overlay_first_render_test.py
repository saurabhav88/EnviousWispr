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
         window=None):
    t = GOOD_TICKS[event] if ticks is None else ticks
    if window is None:
        window = HOST_WINDOW if event == "host.order_front.complete" else 0
    return (f"{schema}\trun={run}\tpid={pid}\tbundle={bundle}"
            f"\tevent={event}\tticks={t}\twindow={window}")


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
    expect_verdict("a future schema version blocks",
                   text(schema="EW_OVERLAY_FIRST_RENDER_V2"), m.BLOCKED_MALFORMED_MARKER)
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

def test_overlay_endpoint_waits_for_the_window_the_app_named():
    """The app names the subject; the harness times it.

    Watching for "a new window owned by this process" and stopping at the first
    one accepts a sequence that no settling delay fixes: an unrelated window
    appears, the host marker is written, the harness stops holding only that
    window, and the real pill reaches WindowServer a moment later. Every step is
    plausible and the output is a normal-looking latency about the wrong window.

    These rows are written as SEQUENCES rather than as a set of candidates
    supplied at once, because the previous version of this test handed the
    adjudicator both windows simultaneously — and a fixture that cannot express
    the ordering cannot fail on it. That is what let the defect survive a review
    round.
    """
    t0 = 1_000_000_000
    ms = lambda n: t0 + n * 1_000_000  # noqa: E731

    # The sequence the old code got wrong: unrelated at +3, the named window at
    # +12. The named window's time is what is reported.
    unrelated_first = m.adjudicate_overlay_window(
        99, {7: ms(3), 99: ms(12)}, t0, preexisting=set())
    expect("an unrelated window arriving first does not win",
           unrelated_first.verdict, m.OK)
    expect("the named window is reported", unrelated_first.window_id, 99)
    expect("with ITS first-observed time, not the unrelated one's",
           unrelated_first.keypress_ms, 12.0)

    # TWIN: the same call with only the unrelated window present. Nothing to
    # report, and it must not fall back to the window it does have.
    only_unrelated = m.adjudicate_overlay_window(
        99, {7: ms(3)}, t0, preexisting=set())
    expect("only an unrelated window blocks", only_unrelated.verdict,
           m.BLOCKED_NO_OVERLAY)
    expect("and carries no number", only_unrelated.keypress_ms, None)

    # A window already on screen at key-down did not appear because of this
    # press, so there is no interval to attribute to it.
    preexisting = m.adjudicate_overlay_window(
        99, {99: ms(12)}, t0, preexisting={99})
    expect("a window that existed before the keypress blocks",
           preexisting.verdict, m.BLOCKED_NO_OVERLAY)
    expect("and carries no number", preexisting.keypress_ms, None)

    # The app said it ordered a window front and that window never showed up.
    never = m.adjudicate_overlay_window(99, {7: ms(3)}, t0, preexisting=set())
    expect("a named window that never appears blocks", never.verdict,
           m.BLOCKED_NO_OVERLAY)

    # No host marker at all: a different fact from a window that did not appear,
    # and it must not be reported as a latency of any kind.
    silent = m.adjudicate_overlay_window(None, {99: ms(12)}, t0, preexisting=set())
    expect("no host marker blocks", silent.verdict, m.BLOCKED_NO_OVERLAY)

    # A host marker that reached the call site and could not name a window is a
    # MALFORMED marker, not a missing overlay - different fault, different place.
    zero = m.adjudicate_overlay_window(0, {99: ms(12)}, t0, preexisting=set())
    expect("a host marker naming window 0 is malformed, not absent",
           zero.verdict, m.BLOCKED_MALFORMED_MARKER)

    # TWIN for the whole group: the ordinary case still passes.
    ordinary = m.adjudicate_overlay_window(99, {99: ms(9)}, t0, preexisting=set())
    expect("the ordinary case accepts", ordinary.verdict, m.OK)
    expect("with the harness's own timestamp", ordinary.keypress_ms, 9.0)


def test_the_live_stopping_rule_waits_for_the_named_window():
    """The rule that decides when to STOP polling, tested directly.

    Every other row here tests the adjudicator, which runs once the loop has
    already stopped. That leaves the stop condition itself untested — so the
    whole identity binding could be reverted to "the host marker plus any
    window" and every other row would still pass. This is the row that fails
    when it is.
    """
    ms = lambda n: 1_000_000_000 + n * 1_000_000  # noqa: E731
    expect("an unrelated window does not stop polling",
           m.named_window_has_appeared(99, {7: ms(3)}), False)
    expect("the named window stops polling",
           m.named_window_has_appeared(99, {7: ms(3), 99: ms(12)}), True)
    expect("nothing stops polling before the app has named a window",
           m.named_window_has_appeared(None, {7: ms(3), 99: ms(12)}), False)
    expect("and an empty screen does not stop it either",
           m.named_window_has_appeared(99, {}), False)


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
    window, failure = m.host_window_from(partial)
    expect("a half-written host line is 'not yet', not a verdict", window, None)
    expect("and not a failure either", failure, None)
    window, failure = m.host_window_from(complete)
    expect("the finished line names the window", window, HOST_WINDOW)
    # A malformed line that IS finished is a real failure and must not be
    # swallowed by the same truncation rule that hides an unfinished one.
    malformed = complete.replace(f"window={HOST_WINDOW}", "window=main")
    expect("a finished malformed host line blocks",
           m.host_window_from(malformed)[1][0], m.BLOCKED_MALFORMED_MARKER)


def test_host_window_is_read_from_the_marker_text():
    """`host_window_from` is what the live loop polls with, so it gets its own
    rows: an absent marker is 'not yet', never a verdict."""
    window, failure = m.host_window_from(text())
    expect("a complete file names the window", window, HOST_WINDOW)
    expect("and reports no failure", failure, None)

    partial = text([e for e in ORDER if e != "host.order_front.complete"])
    window, failure = m.host_window_from(partial)
    expect("a file without the host marker is not yet, not a verdict", window, None)
    expect("and still no failure", failure, None)

    doubled = m.host_window_from(text(ORDER + ["host.order_front.complete"]))
    expect("two host markers are refused, not averaged",
           doubled[1][0], m.BLOCKED_DUPLICATE_MARKER)


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
    for key in ("run=", "pid=", "bundle=", "event=", "ticks=", "window="):
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


def test_the_host_marker_is_emitted_with_a_real_window_number():
    """The window id is the newest field and the one that carries the fix.

    A host marker that always wrote 0 would parse, block every run as malformed,
    and read as a broken app. So bind the CALL SITE's source of the value, not
    just the field's spelling: `OverlayWindowHost` must pass
    `panel.windowNumber`, and it must do so on the `emitFirst` path.
    """
    host = (pathlib.Path(__file__).resolve().parents[2] / "Sources"
            / "EnviousWisprAppKit" / "App" / "Overlay" / "OverlayWindowHost.swift")
    if not host.exists():
        FAILURES.append(f"the host is not at {host}; this test's path is stale")
        return
    swift = host.read_text()
    if "window: panel.windowNumber" not in swift:
        FAILURES.append(
            "the host does not pass panel.windowNumber to the marker; the harness "
            "would have no window to wait for")
    if "emitFirst" not in swift:
        FAILURES.append(
            "the host no longer emits the order-front marker once per process")

    # The root markers must be HELD, not emitted where they are captured.
    # Emitting at the capture site puts the marker's own write inside the
    # keypress interval in the baseline bundle and outside it in the prewarmed
    # one, so the benchmark credits the change for removing instrumentation cost
    # that is not production work. Nothing about the marker FORMAT changes when
    # this regresses, so no other row here would notice.
    director = (pathlib.Path(__file__).resolve().parents[2] / "Sources"
                / "EnviousWisprAppKit" / "App" / "Overlay" / "OverlayDirector.swift")
    if not director.exists():
        FAILURES.append(f"the director is not at {director}; this test's path is stale")
        return
    d = director.read_text()
    if "OverlayFirstRenderMarkers.hold(" not in d:
        FAILURES.append(
            "the director does not HOLD its root captures; emitting them at the "
            "capture site biases the keypress comparison toward the prewarmed bundle")
    if "OverlayFirstRenderMarkers.emit(" in d:
        FAILURES.append(
            "the director emits directly, which is the biased form this test exists "
            "to refuse")

    # Holding is not enough on its own: an empty array allocates its buffer on
    # the FIRST append, which in the baseline bundle happens inside the keypress
    # interval and in the prewarmed one does not. The reservation has to happen
    # in `prepare()`, which runs before either interval.
    emitter = EMITTER.read_text()
    if "pending.reserveCapacity" not in emitter:
        FAILURES.append(
            "prepare() does not reserve the held-capture storage; the first hold "
            "would allocate inside the keypress interval in one bundle only")
    if "removeAll(keepingCapacity: true)" not in emitter:
        FAILURES.append(
            "the flush frees the capacity it just used, inside the interval it was "
            "reserved to stay out of")


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
    test_overlay_endpoint_waits_for_the_window_the_app_named,
    test_the_live_stopping_rule_waits_for_the_named_window,
    test_a_half_written_line_is_not_a_marker,
    test_host_window_is_read_from_the_marker_text,
    test_29_pairs_block_and_30_pairs_pass,
    test_one_invalid_sample_blocks_without_top_up,
    test_benchmark_fails_on_a_real_regression,
    test_schedule_is_15_ab_and_15_ba,
    test_every_side_must_be_its_own_cold_launch,
    test_the_swift_emitter_and_this_parser_agree_on_the_schema,
    test_the_host_marker_is_emitted_with_a_real_window_number,
    test_an_abandoned_launch_is_actually_reaped,
    test_every_exceptional_exit_from_the_readiness_wait_reaps,
    test_a_locked_screen_blocks_before_a_launch_is_spent,
    test_the_real_screen_lock_probe_distinguishes_absence_from_failure,
    test_a_keypress_figure_must_name_the_launch_it_came_from,
    test_median_uses_statistics_median,
    test_p95_uses_nearest_rank,
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
