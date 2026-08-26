"""Record-hotkey presses, PORTED VERBATIM from a peer's branch (#2377 chunk 6).

Source: `Tests/RuntimeUAT/wispr_eyes.py` at
`origin/fix/2409-2410-handsfree-double-press` (010934aff3ff), functions
`press_record_key`, `double_press_record_key`, `single_press_record_key`.

**Copied rather than re-derived, on Codex's instruction and the source author's.**
#2410 proposed a fresh helper "so nobody re-derives this" and the snippet it
proposed WAS a re-derivation, missing
`CGEventSetIntegerValueField(kCGKeyboardEventKeycode)` — without which a press
produces a pill on screen and ZERO chain detections, a half-working result that
indicts production code rather than the harness.

Nothing in this file is edited. When that branch merges, delete this file and
import from `wispr_eyes` instead; until then `main`'s `test_hands_free` drives the
MENU and cannot engage hands-free lock at all (#2409).

The imports below are the source module's, reproduced because the extracted block
uses those aliases. `_si` and `_ptt` are imported inside the functions themselves
and are left alone; `_dt` is module-level there, so it is module-level here. This
is the ONLY addition to the file — no ported line is edited.
"""

import datetime as _dt  # noqa: F401
import os
import subprocess  # noqa: F401
import time

# Reproduced verbatim from the source module (lines 1031 and 1463 there), because
# the extracted functions read them. Not re-derived: `_CHAIN_WINDOW_S` is the app's
# own 500 ms chain window and inventing a second value for it is how two
# implementations start disagreeing.
_APP_LOG_PATH = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
_CHAIN_WINDOW_S = 0.5

def press_record_key():
    """Post ONE press of the record hotkey, the way the app can actually see it.

    The record key is a BARE MODIFIER, so it is delivered as `kCGEventFlagsChanged`
    rather than keyDown/keyUp, and it is handled through an event tap rather than
    Carbon (`tools-and-apps.md` FACT: the-record-hotkey-IS-drivable-synthetically-only-cancel-is-not).

    **This delegates to `simulate_input.modifier_down`/`modifier_up`, which have
    carried the correct mechanism all along** — including
    `CGEventSetIntegerValueField(kCGKeyboardEventKeycode)`, because the keycode
    does NOT survive the type change on its own. #2410 proposed a fresh helper
    "so nobody re-derives this"; the snippet it proposed was itself a
    re-derivation, and it omitted that line. A press missing it produces a pill on
    screen and ZERO chain detections — events demonstrably arriving and being
    acted on, so the only conclusion available is that the app's chain detection
    is broken, which is false. A half-working result that indicts production code
    is strictly worse than a silent one.

    Do not inline a `CGEventSetType` call here or anywhere else in this harness.
    Two implementations of this already existed; a third is how they drift.
    """
    import simulate_input as _si
    import ptt_binding as _ptt

    # RESOLVE the binding; never assume it. `RECORD_KEY` is only the DEFAULT, and
    # the settings UI persists both a different key and a different recording
    # mode. Pressing right Option at a profile bound to Globe, or driving a
    # multi-press chain in toggle mode - where `HotkeyService` does not route
    # hands-free at all - produces silence, and the caller reports that silence as
    # a PRODUCT failure. That is the exact class `ptt_binding` exists for, and it
    # refuses rather than guessing.
    binding = _ptt.resolve()
    if not binding.is_modifier_only:
        raise _ptt.PTTBindingError(
            f"the record key is bound to {binding.key_name!r} (keycode "
            f"{binding.keycode}), which is not a standalone modifier. Multi-press "
            "chain detection runs on the modifier event tap; an ordinary key is "
            "registered with Carbon, which does not deliver synthetic events."
        )

    _si.modifier_down(binding.keycode)
    time.sleep(0.04)
    _si.modifier_up(binding.keycode)


def running_enviouswispr_instances():
    """Every running EnviousWispr app bundle, as {pid: executable path}.

    Reads `comm`, NOT `command`. `command` is the executable PLUS its arguments
    with no delimiter between them, so recovering the executable means guessing
    where the arguments begin - and every guess is wrong for some legal path. An
    earlier version split on the first `" -"`, which silently truncates
    `/Users/x/EW - issue/build/EnviousWispr Local.app/...` to `/Users/x/EW` and
    drops that instance from the count. `comm` is the executable alone, so there
    is nothing to parse. (Verified here: on macOS it is the full path, unlike
    Linux where `comm` is the basename.)

    Still excludes our own pid. A caller's argv routinely carries both
    `EnviousWispr` (a worktree path) and `.app/Contents/MacOS/` (a script running
    under `Python.app`), and excluding `python3` does not help - the interpreter's
    binary is named `Python`. The basename test already rejects `.../Python`, so
    the pid check is the second of two mechanisms rather than the only one; the
    self-test carries a row that binds it, because a mutant proved the obvious row
    did not.

    Deliberately NOT scoped to `EnviousWispr Local.app`. A Release-configuration
    test host is named `EnviousWispr.app`, carries the PRODUCTION bundle id, and
    answers the same global hotkey; a `Local.app` pattern cannot see it, which is
    exactly the instance you most want counted.
    """
    # `-ww` asks for unlimited width. macOS `ps(1)` documents that output can be
    # truncated to the terminal width and that a second `-w` lifts the bound. It
    # did NOT reproduce here - piped output stayed intact at 88,841 characters
    # even with COLUMNS=60 - so this is insurance, not a fix for an observed
    # truncation. It earns its place because the failure would be SILENT and in
    # the dangerous direction: a truncated suffix drops a real instance, and the
    # verdict becomes unattributable with nothing to indicate it.
    out = subprocess.run(["ps", "-eww", "-o", "pid=,comm="],
                         capture_output=True, text=True).stdout
    me = str(os.getpid())
    found = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        pid, exe = line.strip().split(None, 1)
        if pid == me:
            continue
        # An EXACT suffix, so the app's own XPC service and `llama-server` - both
        # inside the same bundle and both in this listing - are excluded.
        if exe.endswith(".app/Contents/MacOS/EnviousWispr"):
            found[pid] = exe
    return found


def _require_single_instance(what):
    """REFUSE rather than choose when more than one EnviousWispr is running.

    Every instance answers the same global hotkey and writes the same shared
    `app.log`, so a marker count drawn from that log is unattributable the moment
    there are two. Measured 2026-08-25: a second instance inside the window
    returned 2 of every marker with DISTINCT session ids - two real recordings
    from one gesture - which reads as the app double-counting a synthetic press.
    A confident wrong subject, pointing at production code.

    Returns the instance map so the caller can re-check it afterwards. A wrong
    refusal costs a rerun; a wrong verdict costs somebody a debugging session in
    correct code.
    """
    found = running_enviouswispr_instances()
    if len(found) != 1:
        rows = "\n".join(f"    {p}  {c}" for p, c in sorted(found.items()))
        print(f"BLOCKED: {what} needs exactly ONE running EnviousWispr; "
              f"found {len(found)}.\n{rows}")
        return None
    return found


# One per launch of a debug build. Chosen over `[Recovery] #1 scan pass 1 started
# (launch)` by measurement rather than taste: 437 occurrences against 112 in the
# same log, because the recovery line is conditional and this one is not. It also
# fires when a user toggles Debug Mode by hand, which OVER-reports - and
# over-reporting means refusing a verdict that might have been fine, which is the
# safe direction.
_LAUNCH_BANNER = "[AppLogger] Debug mode enabled"


def _line_timestamp(line):
    """The ISO-8601 stamp `AppLogger` puts at the head of every line, or None."""
    if not line.startswith("["):
        return None
    end = line.find("]")
    if end < 0:
        return None
    try:
        return _dt.datetime.fromisoformat(line[1:end])
    except ValueError:
        return None


def _merge_sweeps(first, second):
    """Combine two passes over the log shelf into the evidence to trust.

    Extracted so the decision is testable without staging a real rotation - the
    surviving mutant is what asked for it, since nothing could reach this logic
    while it lived inside a closure.

    ALWAYS THE UNION, AND THE INODE COMPARISON IS GONE. Three revisions landed
    here and the first two both tried to CHOOSE a pass:

      select the second when inodes differ - wrong, because one rotation during
      the validation pass makes that pass the incomplete one and its differing
      inode map is exactly what selects it;

      keep the first when inodes match - also wrong, because inode equality
      proves only that nothing was RENAMED. The app appends constantly, so a
      marker written between the two passes is present in the second and absent
      from the first, with both maps identical. In the per-attempt check that
      hides a late `Double press` and licenses a destructive retry; in the final
      check it reports a successful gesture as missing its stop marker.

    Both failures come from the same move: deciding which pass to trust. The
    union needs no such decision. A line in either pass is real evidence whose
    timestamp survived any rename, and every caller does a membership or an
    emptiness test, so a duplicate costs nothing. **Choosing between two passes
    requires knowing which is complete; taking both requires knowing nothing.**
    """
    seen, merged = set(), []
    for line in first + second:
        if line not in seen:
            seen.add(line)
            merged.append(line)
    return merged


def _line_in_window(line, start):
    """Is this log line stamped at or after `start`?

    ONE implementation, two callers. The consolidation that gave the harness a
    single log reader briefly left this test written twice - in the reader and in
    the banner counter - and the mutation control caught it as a DUPLICATED ANCHOR
    rather than as a survivor. That is the cheaper of the two ways to find out.

    A line whose stamp will not parse answers NO. `AppLogger` writes a well-formed
    stamp on every line, so an unparseable one is a mangled line rather than an
    event, and the process SAMPLES remain the mechanism that does not depend on
    the log being readable at all.
    """
    stamp = _line_timestamp(line)
    if stamp is None:
        return False
    # FLOOR THE START TO THE SECOND. `AppLogger` writes second-resolution stamps
    # (`2026-08-25T17:55:04-04:00`, no fraction) while `datetime.now()` carries
    # microseconds, so a line written 0.4s AFTER the window opened compares as
    # BEFORE it and is discarded. Measured live: the double press fired, all three
    # markers were in the log, and the per-attempt check reported "did not register
    # after 3 attempts" - the harness driving three gestures against an app that
    # had already done what was asked.
    #
    # Direction is the expensive one and it is why a unit-covered change still
    # needed a live run: it fails toward NOT SEEING evidence. For the banner scan
    # that is permissive (a launch goes uncounted); for the marker check it is a
    # false product failure; and for the retry it is the saboteur case this file
    # already documents, since an unseen marker is what licenses the next press.
    # A window a fraction of a second wide is exactly where it bites, which is the
    # per-attempt check and nowhere else - the ones with a start seconds earlier
    # were unaffected, so nothing failed until the window got small.
    return stamp >= start.replace(microsecond=0)


def log_lines_since(start):
    """Every `app.log` line stamped at or after `start`, oldest first, across the
    rotated predecessors.

    THE ONE READER. Rotation produced a finding in three consecutive review
    rounds, at three different call sites - the banner scan, the retry's own
    check, and the final marker check - and each was correct and each exposed the
    next. That is the signature of fixing sites rather than the question.

    The question every one of them was asking is "what did the app log during this
    window", and `_read_new_log_lines` cannot answer it: it follows the inode, so
    when `AppLogger.rotateIfNeeded` moves `app.log` to `app.1.log` at its 10 MiB
    bound, everything before the move is silently absent and the result still
    looks like a complete slice. A timestamp cannot be moved by a rename, so
    asking by time has no such failure.

    Cost is six names read twice - the shelf is 49 MB here and one call measured
    0.38s. That is real, and it is why the retry loop reads ONCE and asks one
    question of the result rather than reading again for a second question.

    KNOWN AND UNFIXABLE HERE: a RELEASE build writes nothing at all -
    `AppLogger.swift` gates the whole file sink behind `#if DEBUG`. So no reader
    of this log can see a Release instance, and no amount of reading better fixes
    that. The process SAMPLES are the only mechanism that sees one.
    """
    directory = os.path.dirname(_APP_LOG_PATH)
    # Oldest first: `app.5.log` down to `app.1.log`, then the live file.
    # `maxFileCount` is 5 in `AppLogger.swift`; reading one more than exists is
    # free, and reading one FEWER is the silent miss this function exists to stop.
    names = [f"app.{i}.log" for i in range(5, 0, -1)] + ["app.log"]

    def sweep():
        """One pass over the shelf."""
        found = []
        for name in names:
            path = os.path.join(directory, name)
            try:
                with open(path, "rb") as fh:
                    text = fh.read().decode("utf-8", "replace")
            except OSError:
                continue
            for line in text.splitlines():
                if _line_in_window(line, start):
                    found.append(line)
        return found

    # A ROTATION DURING THE SWEEP CAN SKIP A FILE ENTIRELY, which no ordering
    # fixes: once `app.2.log` has been read, a rotation moves the old
    # `app.1.log` onto that already-passed name and the live file onto
    # `app.1.log`, so the old `app.1.log` is never opened. Its lines keep their
    # timestamps through the rename, so they are real evidence that reads as
    # absent.
    # Detected by comparing INODES rather than assumed away: if any name now
    # resolves to a different file, the shelf moved under us and one more pass
    # sees the settled state. Bounded at two - a second rotation inside the same
    # few milliseconds needs the log to cross 10 MiB twice, and an unbounded
    # retry here would be a worse failure than the one it chases.
    # SELECTING THE SECOND PASS WAS WRONG, and the reasoning that produced it
    # ("bounded at two - a second rotation needs 10 MiB twice") was wrong too: it
    # takes only ONE rotation, occurring during the VALIDATION pass, for that pass
    # to be the incomplete one - and the differing inode map is exactly what made
    # it get selected.
    # The UNION cannot omit. A line present in either pass is real evidence, its
    # timestamp survived the rename, and every caller here does a membership test
    # or an emptiness test, so a duplicate costs nothing. Choosing between two
    # passes requires knowing which is complete; taking both requires knowing
    # nothing.
    # Two passes, always merged. Comparing them was tried three ways and every
    # one had to CHOOSE which pass to trust; the union chooses nothing.
    return _merge_sweeps(sweep(), sweep())


def launch_banners_since(start):
    """Launch banners at or after `start`, across the live log AND its rotated
    predecessors.

    READS THE FILES, NOT A CURSOR, and both halves of that are review findings.

    A cursor taken after the ownership check leaves a gap in front of it - here
    `begin_test`, `close_window` and TTS synthesis, which is seconds, not
    milliseconds - and a banner written in that gap is outside the slice. Passing
    a TIMESTAMP instead means the window starts where ownership was established
    rather than where somebody happened to open the file.

    And a cursor cannot survive ROTATION. `AppLogger.rotateIfNeeded` moves
    `app.log` to `app.1.log` (and shifts `app.N` to `app.N+1`) the moment the file
    passes its size bound, so a second launch's banner can be pushed into
    `app.1.log` while every marker that follows lands in the new `app.log`. A
    reader that follows the inode reads the new file only and sees a complete-
    looking slice with the banner missing. Scanning the predecessors costs one
    open each and removes the whole question.
    """
    return count_launch_banners(["\n".join(log_lines_since(start))], start)


def count_launch_banners(texts, start):
    """The pure half of `launch_banners_since`: count banners at or after `start`.

    Split out so the self-test can drive it with synthetic text. The FILE
    LOCATIONS deliberately stay inside `launch_banners_since` and are not a
    parameter - a caller able to redirect where this guard looks could aim it at
    an empty directory and be handed a clean verdict, which is a bypass wearing a
    test seam's clothes.
    """
    seen = 0
    for text in texts:
        for line in text.splitlines():
            if _LAUNCH_BANNER not in line:
                continue
            if _line_in_window(line, start):
                seen += 1
    return seen


def instances_stayed_single(before, window_start, samples):
    """Did exactly one EnviousWispr own this window, start to finish?

    TWO SNAPSHOTS CANNOT ANSWER THIS, and a review round is what established it:
    an instance that starts after the opening check and exits before the closing
    one leaves both endpoints reading the same single pid, while its markers sat
    in the shared log for the whole interval. The comparison passes and the
    verdict is exactly as unattributable as if the guard were absent.

    So the window is covered by two mechanisms that fail differently:

      SAMPLES   the instance set read repeatedly DURING the window rather than
                only at its ends. Closes the hole down to the sampling gap.
      BANNER    the log FILES, scanned by TIMESTAMP for another app's launch
                line from `window_start` onward, across the rotated predecessors
                too. The better of the two, because it is evidence from the SAME
                artifact the verdict is drawn from: a process that wrote into
                this window announced itself IN it, whatever the process table
                happened to say at the instants we looked.
                Reading files rather than a cursor is deliberate - see
                `launch_banners_since`, whose docstring carries the two ways a
                cursor loses the banner.

    Returns `(ok, reason)`. The reason names which mechanism objected, because "a
    second app launched mid-window" and "the app was replaced" are different
    things to go and look at.

    KNOWN RESIDUAL, stated rather than implied, because "two mechanisms" reads as
    "closed" and this is not.

    THE LARGEST MEMBER IS A RELEASE BUILD, and an earlier version of this note got
    it wrong by describing a narrow line-loss race instead. `AppLogger.swift` gates
    the ENTIRE file sink behind `#if DEBUG`, so a Release instance writes no banner
    at all - not one at risk of being lost, one that never exists. Meanwhile
    `running_enviouswispr_instances` counts Release bundles deliberately, because
    they answer the same global hotkey. So for a Release instance the banner
    mechanism contributes NOTHING and the samples are the only cover, which makes
    the residual the whole sampling gap rather than a rare coincidence.
    A debug instance is the narrow case, and it is narrower than an earlier
    revision of this note claimed. That version said the banner was "the line most
    at risk" because a second app launching means two writers - which was the
    obsolete diagnosis, and it survived here after the same claim was corrected in
    the verdict and the docstring. THIRD SITE of one sentence; a copied claim has
    siblings by construction, so grep the SENTENCE rather than the finding.
    `AppLogger.swift:187` opens with `O_APPEND`, so concurrent appends cannot
    overwrite the banner at all. Losing it now needs a ROTATION crossing the
    10 MiB bound while the two processes overlap, since rotation is still not
    locked across processes. So the debug case requires: launch AND exit between
    two samples, AND a rotation inside that same window.

    What is NOT in that residual any more, because a review round closed both: a
    banner written before the log cursor was taken, and a banner carried into a
    rotated file. Neither depends on a cursor now.

    What is NOT claimed: that this proves one instance owned the window. What is
    claimed: two independent mechanisms must both miss, where before one snapshot
    pair had a hole a whole app could live in. If a verdict from this ever has to
    be defended, defend it on the samples plus the banner plus what the log slice
    actually contains - never on this function returning True.
    """
    for snap in samples:
        if set(snap) != set(before):
            return False, (f"the running set changed mid-window "
                           f"({sorted(before)} -> {sorted(snap)})")
    launches = launch_banners_since(window_start)
    if launches:
        return False, (f"{launches} app launch banner(s) appeared inside this "
                       f"window; another instance wrote into this same log")
    return True, ""


def double_press_record_key(attempts=3):
    """Two presses inside the app's chain window — the hands-free gesture (#2410).

    The window is measured from the moment RECORDING STARTS, not from the first
    press, so the gap here is deliberately well inside 500ms rather than close to
    it.

    NO PRECONDITION ON FOCUS. Measured 2026-08-25, macOS 26.4, dev build from
    `main` at `d8cfd3b9`, two arms against one instance:

        frontmost = com.apple.TextEdit          -> 1 `Double press`, 1 activation
        frontmost = com.enviouswispr.app.dev    -> 1 `Double press`, 1 activation

    So the tap is not frontmost-scoped, and this is now a measurement rather than
    the argument-from-architecture the previous revision correctly refused to
    accept. Arm A needs Settings OPEN to be stageable at all — EnviousWispr is a
    menu-bar app with no window at rest, so activation alone cannot make it
    frontmost, and a run that skips that step reports NOT ACHIEVED rather than a
    control.

    **RUN THIS AGAINST EXACTLY ONE EnviousWispr INSTANCE, AND RE-CHECK MID-RUN.**
    The first attempt at this measurement returned 2 of every marker with distinct
    session ids — two real recordings from one gesture — because a peer's
    `build-dev-app.sh` relaunched their app INSIDE the measurement window. Both
    apps answered the same global hotkey and wrote the same shared `app.log`.
    A start-of-run instance check is a claim about a MOMENT; nothing makes it a
    claim about the run. Count the pids before AND after, and require the same
    pid rather than the same count, since a TERM-and-relaunch keeps the count at
    one while swapping the instance underneath.

    The direction is what makes it expensive: two `dictation_started` from one
    press reads as the app double-counting a synthetic press, or as the tap being
    registered twice. Both indict production code, both are false, and both come
    with a reproduction. Distinct session ids are what separate "two recordings"
    from "one duplicated log line".
    """
    # THE SYNTHETIC CHAIN IS ~80% RELIABLE AND NO GAP FIXES IT. Measured
    # 2026-08-25 against the live dev build, 24 trials at four gaps:
    #
    #     0.04s  5/6     0.08s  4/6     0.12s  5/6     0.20s  3/5     0.30s  0/5
    #
    # So the first four are one population around 80% and 0.30s is outside the
    # window entirely. Tuning the number is not available - it was tried first,
    # and the measurement is what stopped it.
    #
    # A SIGNAL-BASED WAIT WAS TRIED AND IS WORSE, which is why this is a retry and
    # not the seam fix the flake rules would otherwise ask for. Waiting for the
    # first press's `Recording started` before posting the second failed 4 out of
    # 4: that line is written AFTER the key-up has already ended the push-to-talk
    # take, so the second press lands during teardown rather than after it. The
    # subject does emit a signal; it is not a signal that means "ready".
    #
    # What a missed attempt costs is nothing: the orphan take is discarded by the
    # app as `Recording discarded - too short`, so the state is self-clearing and a
    # retry starts clean.
    #
    # THE ATTEMPT COUNT IS PRINTED, ALWAYS. A retry that hides itself turns a
    # degrading delivery path into a silent slowdown, and the next person to
    # measure this needs to see 1 become 3 before it becomes a failure.
    # KNOWN COST OF THE RETRY, and it is a real one rather than a hedge. Where no
    # file log exists at all - a Release build compiles the sink out, and Debug
    # Mode gates it in a debug build - a first attempt that SUCCEEDED reads as a
    # failure, and the next press lands on an already-locked recording where
    # `HotkeyService` takes it as the STOP gesture.
    #
    # An earlier revision tried to detect that state and drive the gesture once
    # instead. It was wrong twice in opposite directions, cost two full traversals
    # of a 49 MB shelf per attempt, and was choosing between two ways of failing
    # the run rather than preventing a loss. Deleted, and this is what deleting it
    # costs: on a build with no log, three attempts instead of one.
    #
    # The verdict below is what covers it - it names every cause it cannot rule
    # out rather than reporting a product failure it cannot distinguish from its
    # own blindness.
    for attempt in range(1, attempts + 1):
        attempt_start = _dt.datetime.now().astimezone()
        press_record_key()
        time.sleep(0.12)
        press_record_key()
        time.sleep(0.6)
        # `log_lines_since`, NOT a cursor: a rotation between the snapshot and
        # this read would hide the marker, and a hidden marker here is what turns
        # the retry into the saboteur described above.
        # ONE read, serving one question. An earlier revision took two - a
        # non-strict read for the marker and a strict one for "is the sink
        # live" - and they were 0.4s apart on this machine, because each is a
        # full traversal of a 49 MB shelf. A marker landing in that gap is
        # absent from the first read and present in the second, which is
        # exactly the state the second read existed to detect.
        #
        # `Hands-free mode activated`, NOT `Double press`. Production says so
        # in as many words at `HotkeyService.swift:673` - "this records the
        # REQUEST. Whether it becomes a lock is not known yet" - and
        # `publishLockIfReady` can answer `.notLockable` and clean up. Retrying
        # on the request marker meant declaring success on a gesture that
        # requested a lock and did not get one.
        window = log_lines_since(attempt_start)
        if any("Hands-free mode activated" in line for line in window):
            if attempt > 1:
                print(f"  double press engaged on attempt {attempt} of {attempts}")
            return True
        if attempt < attempts:
            print(f"  attempt {attempt} did not register a chain; retrying")
            # Let the orphan take finish being discarded before pressing again.
            time.sleep(1.2)
    print(f"  double press did not register after {attempts} attempts")
    return False


def stop_after_short_hold(hold):
    """Stop a recording this helper locked but is about to refuse to judge.

    A REFUSAL MUST NOT LEAVE A RECORDING RUNNING. This path is reached only after
    the double press has locked hands-free, so an early `return` left the app
    recording indefinitely - capturing ambient audio and poisoning every later run
    in the session. That is precisely what the Escape Recovery UAT did on
    2026-08-18, where the founder ended the recording by hand.

    Waits out the remainder of the lock cooldown first: `HotkeyService` ignores a
    press within 500ms of locking, so a stop posted too early is swallowed and the
    refusal leaves the same mess it was written to avoid.

    A separate function so a row can reach it. The in-line version survived its
    mutant - the fourth in this PR to survive for want of reachability rather than
    for want of a correct guard.
    """
    remaining_cooldown = _CHAIN_WINDOW_S - hold
    if remaining_cooldown > 0:
        time.sleep(remaining_cooldown)
    print("  stopping the locked recording before returning")
    single_press_record_key()
    time.sleep(1.0)


def single_press_record_key():
    """One press AFTER the lock cooldown — the hands-free stop (#2410).

    `HotkeyService` ignores presses within 500ms of locking, so a stop posted
    too early is swallowed by the cooldown and reads as "the app ignored the
    stop". The caller is responsible for having recorded for longer than that;
    this helper only refuses to be the reason it was too soon.
    """
    press_record_key()


