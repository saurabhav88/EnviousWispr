#!/usr/bin/env python3
"""Control for the #3304 additions to the paste-landing UAT harness itself.

    python3 Tests/RuntimeUAT/test_paste_landing_harness.py

A HARNESS CONTRACT test (testing-philosophy.md RULE: every-test-declares-which-of-four-things-it-
protects). It protects the INSTRUMENT and is never product coverage: nothing here says whether a
dictation pastes. It needs no app, no screen, no audio, never posts a key and never touches the
clipboard. NOTHING RUNS THIS AUTOMATICALLY; it is run by hand before the Live UAT that uses the
harness.

What it pins: page A's real observer script, run in a headless Chrome (no window, no key, no
clipboard), reads an exact paste as ok and an empty, truncated or doubled one as not ok; the
cleanup parsers keep checked (PR B) and unchecked (#3304 recorded window) lines apart; a sleeping proof on an awake or unreadable Chrome is INCONCLUSIVE, never PASS, and a run
with one exits 3, while a proven failure still exits 1; step 0 fails a paste that also showed
Copied; a doubled paste is not a single insertion; the push-to-talk key is released after the
before-release callback, even when that callback raises.
"""
import os
import pathlib
import subprocess
import sys
import unittest

HERE = str(pathlib.Path(__file__).resolve().parent)
sys.path.insert(0, HERE)

import paste_landing_uat as h  # noqa: E402
import simulate_input as si  # noqa: E402

CHECKED = ("Clipboard cleanup: op=keep_dictation, applied=true, delay=300ms, tier=cgevent, "
           "checked=true")
UNCHECKED = "Clipboard cleanup: op=restore, applied=true, delay=300ms, tier=cgevent"
UNAPPLIED = "Clipboard cleanup: op=restore, applied=false, delay=300ms, tier=cgevent"


class Results:
    """Runs a harness check against a fresh result list and hands back what it recorded."""

    def __enter__(self):
        self.saved = list(h.u.results)
        h.u.results.clear()
        return h.u.results

    def __exit__(self, *exc):
        h.u.results[:] = self.saved
        return False


class CleanupParsers(unittest.TestCase):
    def test_checked_line_matches_both_parsers(self):
        self.assertTrue(h.KEPT.search(CHECKED))
        self.assertEqual(h.CLEANUP.findall(CHECKED), [("keep_dictation", "true", "cgevent", ", checked=true")])

    def test_unchecked_line_only_matches_the_new_parser(self):
        self.assertIsNone(h.KEPT.search(UNCHECKED), "KEPT stays checked-only for PR B's phases")
        self.assertEqual(h.CLEANUP.findall(UNCHECKED), [("restore", "true", "cgevent", "")])

    def test_unapplied_restore_is_visible(self):
        self.assertEqual([(c[0], c[1]) for c in h.CLEANUP.findall(UNAPPLIED)], [("restore", "false")])

    def test_window_gate_and_capture_lines(self):
        line = ("WINDOW_GATE dispatch target=recorded_window result=pass_same_window take_id=t-1 "
                "bundle_id=com.google.Chrome")
        self.assertEqual(h.GATE.findall(line), [("recorded_window", "pass_same_window", "com.google.Chrome")])
        cap = "AXDiag capture: recorded window (no field) elapsed_ms=3"
        self.assertEqual([c[0] for c in h.CAPTURE.findall(cap)], ["recorded window (no field)"])
        refused = ("WINDOW_GATE refused stage=activation reason=target_window_not_confirmed"
                   "(window_mismatch) ms=1000 bundle_id=com.google.Chrome")
        self.assertEqual(h.REFUSED.findall(refused), [("activation", "window_mismatch")])


class SleepAndSummary(unittest.TestCase):
    def test_only_the_exact_sleep_code_is_asleep(self):
        self.assertTrue(h.is_asleep({"before_record": -25212, "before_stop": -25212}))
        self.assertFalse(h.is_asleep({"before_record": -25212, "before_stop": 0}), "woke before stop")
        self.assertFalse(h.is_asleep({"before_record": None}), "a failed read is not sleep")
        self.assertFalse(h.is_asleep({}), "no sample is not sleep")

    def test_inconclusive_is_never_a_pass(self):
        self.assertEqual(h.exit_status([("a", "PASS", ""), ("b", "INCONCLUSIVE", "")]), 3)
        self.assertEqual(h.exit_status([("a", "FAIL", ""), ("b", "INCONCLUSIVE", "")]), 1,
                         "a proven failure outranks an inconclusive one")
        self.assertEqual(h.exit_status([("a", "PASS", ""), ("b", "SKIP", "")]), 0)


class Insertion(unittest.TestCase):
    def test_single_and_doubled(self):
        once = "Send the draft to Maya tomorrow morning."
        self.assertTrue(h.single_insertion(once))
        self.assertFalse(h.single_insertion(once + " " + once), "a doubled paste is not single")
        self.assertTrue(h.single_insertion(" ".join([once] * 5), times=5))
        self.assertFalse(h.single_insertion(""))
        self.assertFalse(h.single_insertion(None))


class PageObservers(unittest.TestCase):
    """The instrumented pages' titles: exact per-take insertion, any change as step 0 evidence,
    and B untouched. Tuples are (paste events, ok, box length)."""

    def test_title_parsing(self):
        self.assertEqual(h.page_state("ew 3304 switch A r1 |p=2|len=80|ok=1|end - Google Chrome"),
                         (2, True, 80))
        self.assertEqual(h.page_state("ew 3304 switch B r1 |p=0|end - Google Chrome"), (0, None, None))
        self.assertIsNone(h.page_state("New Tab - Google Chrome"))

    def test_one_exact_paste(self):
        self.assertTrue(h.exact_take((0, True, 0), (1, True, 40)))

    def test_ok_zero_fails(self):
        self.assertFalse(h.exact_take((0, True, 0), (1, False, 39)), "truncated or extra text")

    def test_empty_paste_fails(self):
        self.assertFalse(h.exact_take((0, True, 0), (1, True, 0)), "a paste event that inserted nothing")

    def test_missed_then_doubled_fails_per_take(self):
        takes = [((0, True, 0), (1, True, 40)), ((1, True, 40), (1, True, 40)),
                 ((1, True, 40), (3, True, 120))]
        self.assertEqual([h.exact_take(b, a) for b, a in takes], [True, False, False])

    def test_any_change_is_step0_evidence(self):
        self.assertTrue(h.changed((0, True, 0), (1, False, 39)), "a wrong insertion is still one")
        self.assertTrue(h.changed((0, True, 0), (0, True, 5)), "text without a paste event")
        self.assertFalse(h.changed((1, True, 40), (1, True, 40)))
        self.assertTrue(h.changed((1, True, 40), None), "an unreadable page never hides a paste")

    def test_b_untouched_and_touched(self):
        self.assertTrue(h.untouched((0, None, None), (0, None, None)))
        self.assertFalse(h.untouched((0, None, None), (1, None, None)))
        self.assertFalse(h.untouched((0, None, None), None), "an unreadable B is not proven untouched")

    def test_real_page_observer_in_headless_chrome(self):
        """The page's own script, in a real (headless) Chrome, answers each case as the harness
        expects: exact reads ok, and empty, truncated and doubled read not ok."""
        got = h.calibrate_pages()
        self.assertEqual(got, {"exact": (1, True, 5), "empty": (1, False, 0),
                               "truncated": (1, False, 4), "doubled": (1, False, 10)})


class StepZero(unittest.TestCase):
    NOTICE_SHOWN = "RETAINED_NOTICE take=t-1 shown=true why=retained"
    RECORDED = "AXDiag capture: recorded window (no field) elapsed_ms=2\n"

    def statuses(self, *args, **kwargs):
        with Results() as results:
            h.check_step0("t", *args, **kwargs)
            return [status for _, status, _ in results]

    def test_paste_and_copied_fails(self):
        self.assertIn("FAIL", self.statuses(self.NOTICE_SHOWN, [], inserted=True))

    def test_copied_without_insertion_passes(self):
        self.assertEqual(self.statuses(self.NOTICE_SHOWN, [], inserted=False), ["PASS"])

    def test_recorded_window_key_paste_then_kept_fails(self):
        self.assertIn("FAIL", self.statuses(self.RECORDED + CHECKED, [("cgevent", "com.google.Chrome")],
                                            inserted=False))

    def test_recorded_window_clean_paste_passes(self):
        self.assertEqual(self.statuses(self.RECORDED + UNCHECKED, [("cgevent", "com.google.Chrome")],
                                       inserted=True), ["PASS", "PASS"])

    def test_no_capture_line_means_no_recorded_window_check(self):
        # An awake take captured its field: only the universal row runs.
        self.assertEqual(self.statuses(CHECKED, [("cgevent", "com.google.Chrome")], inserted=False),
                         ["PASS"])


class StepZeroEvidence(unittest.TestCase):
    """The helpers that turn destinations and logs into step 0 evidence, per take."""

    def test_any_text_counts_partial_and_unreadable(self):
        self.assertTrue(h.any_text([("ChatGPT", "Send the draft")]), "partial text is an insertion")
        self.assertTrue(h.any_text([("ChatGPT", None)]), "unreadable counts")
        self.assertTrue(h.any_text([]), "no box read at all counts")
        self.assertFalse(h.any_text([("ChatGPT", "")]))

    def test_partial_text_plus_notice_fails_step0(self):
        notice = "RETAINED_NOTICE take=t-1 shown=true why=retained"
        with Results() as results:
            h.check_step0("t", notice, [], inserted=h.any_text([("ChatGPT", "Send the")]))
            self.assertIn("FAIL", [status for _, status, _ in results])

    def test_combined_log_with_two_recorded_windows_keeps_the_row(self):
        log = ("AXDiag capture: recorded window (no field) elapsed_ms=2\n"
               "AXDiag capture: recorded window (no field) elapsed_ms=3\n"
               "RETAINED_NOTICE take=t-1 shown=false why=superseded\n")
        with Results() as results:
            h.check_step0("both takes", log, [("cgevent", "com.google.Chrome")], inserted=False)
            self.assertIn("FAIL", [s for _, s, _ in results],
                          "a key paste followed by a notice request fails with two captures too")

    def test_two_takes_are_judged_together(self):
        # Take 1's notice arrives after take 2 starts: never attributed to either take by position.
        log = ("Recording started (take 1) ... Recording started (take 2) ... "
               "RETAINED_NOTICE take=take-1 shown=true why=retained")
        with Results() as results:
            h.check_step0("newtake (both takes)", log, [], inserted=False)
            self.assertEqual([s for _, s, _ in results], ["PASS"], "no insertion anywhere: both pass")
        with Results() as results:
            h.check_step0("newtake (both takes)", log, [], inserted=True)
            self.assertIn("FAIL", [s for _, s, _ in results], "both happened: fail, no guessing")


class CalibrationCleanup(unittest.TestCase):
    """The calibration directory is deleted only once nothing uses its profile."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp(prefix="ew-harness-test-", dir="/tmp")
        self.saved = (h.profile_pids, h.u.wait_for)

    def tearDown(self):
        h.profile_pids, h.u.wait_for = self.saved
        if os.path.exists(self.dir):
            subprocess.run(["find", self.dir, "-xdev", "-delete"], capture_output=True)

    def test_deleted_when_no_process_remains(self):
        h.profile_pids = lambda profile: []
        self.assertTrue(h.remove_owned_profile_dir(self.dir, self.dir + "/profile"))
        self.assertFalse(os.path.exists(self.dir))

    def test_kept_when_the_probe_fails(self):
        def fail(profile):
            raise h.u.Aborted("pgrep failed")
        h.profile_pids = fail
        self.assertFalse(h.remove_owned_profile_dir(self.dir, self.dir + "/profile"))
        self.assertTrue(os.path.exists(self.dir))

    def test_kept_when_a_helper_survives(self):
        h.profile_pids = lambda profile: [2 ** 22 + 7]  # no such process: TERM is a no-op
        h.u.wait_for = lambda *a, **k: False  # the bounded wait ends with the helper still there
        self.assertFalse(h.remove_owned_profile_dir(self.dir, self.dir + "/profile"))
        self.assertTrue(os.path.exists(self.dir))


class BeforeRelease(unittest.TestCase):
    """The callback runs while the key is held, and the release is posted even when it raises."""

    def setUp(self):
        self.events = []
        self.saved = (si.CGEventPost, si.time.sleep, si._flags_changed_event)
        si.CGEventPost = lambda tap, event: self.events.append(event)
        si.time.sleep = lambda seconds: None
        si._flags_changed_event = lambda code, flags, down: "down" if down else "up"

    def tearDown(self):
        si.CGEventPost, si.time.sleep, si._flags_changed_event = self.saved

    def test_callback_runs_between_press_and_release(self):
        si.hold_modifier(54, 0.0, before_release=lambda: self.events.append("callback"))
        self.assertEqual(self.events, ["down", "callback", "up"])

    def test_release_is_posted_when_the_callback_raises(self):
        def boom():
            raise RuntimeError("sample failed")
        with self.assertRaises(RuntimeError):
            si.hold_modifier(54, 0.0, before_release=boom)
        self.assertEqual(self.events, ["down", "up"])

    def test_no_callback_is_the_plain_hold(self):
        si.hold_modifier(54, 0.0)
        self.assertEqual(self.events, ["down", "up"])


class LauncherHarness(unittest.TestCase):
    """#3423: the launcher phases' parsers and shared verdict, on synthetic log text and a scripted
    fixture report. No fixture process, app, screen or key."""

    LOG = ("[AXDiag] TARGET_FOCUS state=disagree front=com.apple.TextEdit "
           "owner=com.enviouswispr.uat.launcherpanel\n"
           "Paste cascade: tier=cgevent, app=com.enviouswispr.uat.launcherpanel, x\n"
           "dictation_terminal result=completed reason=nil take=AAAA-1 backend=parakeet\n")

    def setUp(self):
        self.saved_state = h.panel_state
        self.saved_field = h.u.field_text

    def tearDown(self):
        h.panel_state = self.saved_state
        h.u.field_text = self.saved_field

    def script(self, fields, doc=""):
        h.panel_state = lambda: {"fields": fields}
        h.u.field_text = lambda path: doc

    def statuses(self, results):
        return {name: status for name, status, _ in results}

    def test_every_launcher_phase_is_registered(self):
        for name in ("launcher_tier1", "launcher_tier2", "launcher_dismissed", "appswap"):
            self.assertIn(name, h.PHASES)
            self.assertIn(name, h.LAUNCHER_PHASES)

    def test_parsers(self):
        self.assertEqual(h.TARGET_FOCUS.findall(self.LOG),
                         [("disagree", "com.apple.TextEdit", "com.enviouswispr.uat.launcherpanel")])
        self.assertEqual(h.take_id_in(self.LOG), "AAAA-1")
        self.assertIsNone(h.take_id_in("no terminal here"))
        judged = ("learn_judged arm=classifier outcome=accepted candidates=1 accepted=1 latency_ms=40 "
                  "evidence=strong take=AAAA-1")
        self.assertEqual(h.LEARN_JUDGED.findall(judged),
                         [("classifier", "accepted", "1", "1", "AAAA-1")])
        self.assertEqual(h.LEARN_ADDED.findall("learn_added state=new_word"), ["new_word"])

    def test_learned_entry_reads_the_parsed_word_not_text(self):
        def snap(words):
            return {"exists": True, "parsed": {"version": 1, "words": words}}
        unrelated = snap([{"id": "1", "canonical": "Note", "aliases": ["Markus Marcus"],
                           "learnedAliases": []}])
        self.assertIsNone(h.learned_entry(unrelated), "the text elsewhere is not an entry")
        typed = snap([{"id": "2", "canonical": "Markus", "aliases": ["Marcus"], "learnedAliases": []}])
        self.assertIsNone(h.learned_entry(typed), "a hand-typed alias is not a learned one")
        gained = snap([{"id": "2", "canonical": "Markus", "aliases": ["Marcus"],
                        "learnedAliases": ["Marcus"]}])
        self.assertIsNotNone(h.learned_entry(gained), "an existing word gaining the learned alias")
        self.assertNotEqual(h.learned_entry(gained), h.learned_entry(typed))
        self.assertIsNone(h.learned_entry({"exists": False}))

    def test_restore_words_stops_the_app_before_restoring_even_when_bytes_match(self):
        import learn_from_edits_uat as lf
        calls = []
        saved = (h.WORDS["snap"], lf.stop_app, lf.file_restore, lf.verify_restore, h.subprocess.run)
        try:
            h.WORDS["snap"] = {"exists": True}
            lf.stop_app = lambda: calls.append("stop")
            lf.file_restore = lambda path, snap: calls.append("restore")
            lf.verify_restore = lambda path, snap, kind: (calls.append("verify") or (True, "equal"))

            class Done:
                returncode = 0
            h.subprocess.run = lambda *a, **k: calls.append("open") or Done()
            self.assertTrue(h.restore_words())
            self.assertEqual(calls, ["stop", "restore", "verify", "open"])
            self.assertIsNone(h.WORDS["snap"])
        finally:
            (h.WORDS["snap"], lf.stop_app, lf.file_restore, lf.verify_restore,
             h.subprocess.run) = saved

    def test_a_surviving_fixture_blocks_the_next_launch_and_keeps_its_handle(self):
        class Survivor:
            def poll(self):
                return None
            def wait(self, timeout=None):
                raise TimeoutError
            def terminate(self):
                pass
            def kill(self):
                pass
        saved = (dict(h.FIXTURE), h.panel_command)
        try:
            survivor = Survivor()
            h.FIXTURE["proc"] = survivor
            h.panel_command = lambda name, text="": None
            with self.assertRaises(h.u.Aborted):
                h.launch_panel("B")
            self.assertIs(h.FIXTURE["proc"], survivor)
        finally:
            h.FIXTURE.clear()
            h.FIXTURE.update(saved[0])
            h.panel_command = saved[1]

    def test_submitted_text_keeps_a_multi_line_output_whole(self):
        log = ("[2026-10-03T22:45:22-04:00] [INFO] [CorrectionDebug] CORRECTION_DEBUG [RAW ASR] a b\n"
               "[2026-10-03T22:45:24-04:00] [INFO] [CorrectionDebug] CORRECTION_DEBUG [LLM Polish] OUT: "
               "First line\nSecond line\n"
               "[2026-10-03T22:45:24-04:00] [INFO] [PipelineTiming] Paste cascade: tier=cgevent, app=x\n")
        self.assertEqual(h.submitted_text(log), "First line\nSecond line")

    def test_a_failed_relaunch_keeps_the_snapshot_for_a_retry(self):
        import learn_from_edits_uat as lf
        saved = (h.WORDS["snap"], lf.stop_app, lf.file_restore, lf.verify_restore, h.subprocess.run)
        try:
            h.WORDS["snap"] = {"exists": True}
            lf.stop_app = lambda: None
            lf.file_restore = lambda path, snap: None
            lf.verify_restore = lambda path, snap, kind: (True, "equal")

            class Failed:
                returncode = 1
            h.subprocess.run = lambda *a, **k: Failed()
            self.assertFalse(h.restore_words())
            self.assertIsNotNone(h.WORDS["snap"], "a retry must relaunch again")
        finally:
            (h.WORDS["snap"], lf.stop_app, lf.file_restore, lf.verify_restore,
             h.subprocess.run) = saved

    def test_restore_words_is_a_no_op_without_a_snapshot(self):
        saved = h.WORDS["snap"]
        try:
            h.WORDS["snap"] = None
            self.assertTrue(h.restore_words())
        finally:
            h.WORDS["snap"] = saved

    def test_one_take_in_the_right_field_passes(self):
        once = h.SENTENCE
        self.script({"A": "", "B": once})
        with Results() as results:
            value = h.verify_launcher("t", self.LOG, "B", "cgevent", host_doc="doc")
            recorded = list(results)
        self.assertEqual(value, once)
        self.assertEqual(len(recorded), 5)
        self.assertTrue(all(s == "PASS" for _, s, _ in recorded), recorded)

    def test_wrong_tier_wrong_bundle_and_host_landing_fail(self):
        self.script({"A": "", "B": h.SENTENCE}, doc="leaked")
        with Results() as results:
            h.verify_launcher("t", self.LOG.replace("tier=cgevent", "tier=clipboard_only"), "B",
                              "cgevent", host_doc="doc")
            statuses = self.statuses(results)
        self.assertEqual(statuses["t: one paste into the panel's app, tier cgevent"], "FAIL")
        self.assertEqual(statuses["t: nothing landed in the TextEdit document behind the panel"], "FAIL")
        with Results() as results:
            h.verify_launcher("t", self.LOG.replace("launcherpanel, x", "launcherpanel, x\n"
                              "Paste cascade: tier=cgevent, app=com.apple.TextEdit, y"), "B", "cgevent")
            statuses = self.statuses(results)
        self.assertEqual(statuses["t: one paste into the panel's app, tier cgevent"], "FAIL",
                         "a second paste into another app is not one paste")

    def test_front_agreement_is_not_a_launcher_take(self):
        self.script({"A": "", "B": h.SENTENCE})
        with Results() as results:
            h.verify_launcher("t", self.LOG.replace("state=disagree", "state=agree"), "B", "cgevent")
            statuses = self.statuses(results)
        self.assertEqual(statuses["t: record start targeted the panel (TARGET_FOCUS disagree)"], "FAIL")

    P = "[2026-10-03T23:00:00-04:00] [INFO] [CorrectionDebug] "
    DEBUG = (P + "CORRECTION_DEBUG [RAW ASR] please send the quarterly summary to marcus by friday afternoon\n"
             + P + "CORRECTION_DEBUG [Word Correction] no change\n"
             + P + "CORRECTION_DEBUG [LLM Polish] IN:  please send the quarterly summary\n"
             + P + "CORRECTION_DEBUG [LLM Polish] OUT: Please send the quarterly summary to Marcus by "
             "Friday afternoon.\n")

    def test_submitted_text_is_the_last_logged_output(self):
        final = "Please send the quarterly summary to Marcus by Friday afternoon."
        self.assertEqual(h.submitted_text(self.DEBUG), final)
        raw_only = (self.P + "CORRECTION_DEBUG [RAW ASR] hello there\n"
                    + self.P + "CORRECTION_DEBUG [Filler Removal] no change\n")
        self.assertEqual(h.submitted_text(raw_only), "hello there")
        self.assertIsNone(h.submitted_text("nothing logged"))

    def test_exact_insertion_rejects_doubled_truncated_and_partial_repeats(self):
        final = h.submitted_text(self.DEBUG)
        cases = {final: "PASS", final + " " + final: "FAIL", final[:-12]: "FAIL",
                 final + " Friday afternoon.": "FAIL", "": "FAIL"}
        for field, want in cases.items():
            with Results() as results:
                h.verify_exact("t", field, self.DEBUG, h.LAUNCHER_SENTENCE)
                exact = {n: st for n, st, _ in results}["t: the field holds the submitted text exactly once"]
            self.assertEqual(exact, want, repr(field))

    def test_an_unreadable_read_is_not_an_empty_field(self):
        self.assertTrue(h.readable_empty(""))
        self.assertFalse(h.readable_empty(None))
        self.assertFalse(h.readable_empty("x"))
        self.script({"A": "", "B": h.SENTENCE}, doc=None)
        with Results() as results:
            h.verify_launcher("t", self.LOG, "B", "cgevent", host_doc="doc")
            host = {n: st for n, st, _ in results}[
                "t: nothing landed in the TextEdit document behind the panel"]
        self.assertEqual(host, "FAIL", "an unreadable document proves nothing")

    def test_close_panel_confirms_each_stop_and_keeps_a_survivor(self):
        class Proc:
            def __init__(self, dies_on):
                self.dies_on, self.alive, self.calls = dies_on, True, []
            def poll(self):
                return None if self.alive else 0
            def wait(self, timeout=None):
                if self.alive:
                    raise TimeoutError
            def terminate(self):
                self.calls.append("terminate")
                if self.dies_on == "terminate":
                    self.alive = False
            def kill(self):
                self.calls.append("kill")
                if self.dies_on == "kill":
                    self.alive = False
        saved = (dict(h.FIXTURE), h.panel_command)
        try:
            h.panel_command = lambda name, text="": None  # the quit command is ignored here
            for dies_on, want_ok, want_calls in [("terminate", True, ["terminate"]),
                                                 ("kill", True, ["terminate", "kill"]),
                                                 ("never", False, ["terminate", "kill"])]:
                proc = Proc(dies_on)
                h.FIXTURE["proc"] = proc
                self.assertEqual(h.close_panel(), want_ok, dies_on)
                self.assertEqual(proc.calls, want_calls, dies_on)
                self.assertEqual(h.FIXTURE["proc"] is None, want_ok, "a survivor's handle is kept")
        finally:
            h.FIXTURE.clear()
            h.FIXTURE.update(saved[0])
            h.panel_command = saved[1]

    def test_precondition_refuses_a_focus_owner_that_is_not_the_panel(self):
        class Proc:
            pid = 4242
        saved = (h.u.require_front, h.focus_owner_pid, dict(h.FIXTURE))
        try:
            h.u.require_front = lambda bundle, label: None
            h.FIXTURE["proc"] = Proc()
            h.panel_state = lambda: {"focused": "B"}
            h.focus_owner_pid = lambda: 999
            with self.assertRaises(h.u.Aborted):
                h.launcher_precondition("com.apple.TextEdit", "B")()
            h.focus_owner_pid = lambda: 4242
            h.launcher_precondition("com.apple.TextEdit", "B")()  # passes: owner and field match
            h.panel_state = lambda: {"focused": "A"}
            with self.assertRaises(h.u.Aborted):
                h.launcher_precondition("com.apple.TextEdit", "B")()
        finally:
            h.u.require_front, h.focus_owner_pid = saved[0], saved[1]
            h.FIXTURE.clear()
            h.FIXTURE.update(saved[2])

    def test_closing_with_no_fixture_is_a_clean_no_op(self):
        saved = dict(h.FIXTURE)
        try:
            h.FIXTURE["proc"] = None
            self.assertTrue(h.close_panel())
        finally:
            h.FIXTURE.clear()
            h.FIXTURE.update(saved)


if __name__ == "__main__":
    # `unittest.main()` exits 0 when it discovers ZERO tests: count explicitly.
    suite = unittest.TestLoader().loadTestsFromModule(sys.modules[__name__])
    count = suite.countTestCases()
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(f"ran {count} tests")
    sys.exit(0 if count > 0 and result.wasSuccessful() else 1)
