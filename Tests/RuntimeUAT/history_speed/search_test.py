#!/usr/bin/env python3
"""Harness contract tests for the History search oracle and checker (#4586 PR 0 chunk 2). Offline.

The literal corpus below has answers written by hand in this file; nothing here reads expected
values back through the oracle it tests.
"""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import search_check as check  # noqa: E402

spec = importlib.util.spec_from_file_location("ground_truth", HERE / "m5-speed-ground-truth.py")
truth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(truth)

DAY = 86400.0
T0 = 800_000_000.0   # a fixed instant, seconds since 2001-01-01, at local noon-ish of some day
NOW = T0 + 10 * DAY

# id, createdAt, extra fields. Expected answers are spelled out per test, by hand.
TRANSCRIPTS = [
    ("00000000-0000-0000-0000-00000000000A", T0 + 1, {"text": "budget meeting raw", "polishedText": "Budget meeting polished"}),
    ("00000000-0000-0000-0000-00000000000B", T0 + 2, {"text": "the quick fox"}),
    ("00000000-0000-0000-0000-00000000000C", T0 + 3, {"text": "original words budget", "polishedText": "polished words",
                                                     "preferredVersion": "original"}),
    ("00000000-0000-0000-0000-00000000000D", T0 + 4, {"text": "imported body", "importedFileName": "clip-voice.wav"}),
    ("00000000-0000-0000-0000-00000000000E", T0 + 5, {"text": "pending budget", "escapeRecoveredAt": NOW - 3600}),
    ("00000000-0000-0000-0000-00000000000F", T0 + 6, {"text": "expired budget", "escapeRecoveredAt": NOW - 2 * DAY}),
    ("00000000-0000-0000-0000-000000000010", T0 + 1, {"text": "same instant budget"}),   # ties with A on createdAt
    ("00000000-0000-0000-0000-000000000011", T0 + 7, {"text": "speaker row", "speakerNames": {"0": "Budgie"}}),
    # Meeting transcripts.
    ("00000000-0000-0000-0000-0000000000M1", T0 + 8, {
        "text": "hello budget world", "meetingID": "AAAAAAAA-0000-0000-0000-000000000001",
        "turns": [{"id": "t1", "processedText": "hello budget"}, {"id": "t2", "processedText": "echo secret"}]}),
    ("00000000-0000-0000-0000-0000000000M2", T0 + 9, {
        "text": "other", "meetingID": "AAAAAAAA-0000-0000-0000-000000000002",
        "meetingTranscriptAttemptID": "attempt-old", "turns": [{"id": "t1", "processedText": "budget too"}]}),
]
MEETINGS = [
    ("AAAAAAAA-0000-0000-0000-000000000001", T0 + 8, {"title": "Weekly Sync", "state": "ready",
     "transcriptID": "00000000-0000-0000-0000-0000000000M1", "echoTurnIDs": ["t2"],
     "committedTranscriptAttemptID": None}),
    # Its transcript belongs to an older attempt, so it lists but never matches a search.
    ("AAAAAAAA-0000-0000-0000-000000000002", T0 + 9, {"title": "Budget Planning", "state": "ready",
     "transcriptID": "00000000-0000-0000-0000-0000000000M2", "committedTranscriptAttemptID": "attempt-new"}),
    ("AAAAAAAA-0000-0000-0000-000000000003", T0 + 10, {"title": "Deleted one", "state": "ready",
     "transcriptID": "none", "deletionRequested": True}),
]


def make_home(root: Path) -> Path:
    support = root / "home" / truth.SUPPORT
    (support / "transcripts").mkdir(parents=True)
    for tid, created, extra in TRANSCRIPTS:
        (support / "transcripts" / f"{tid}.json").write_text(json.dumps({"id": tid, "createdAt": created, **extra}))
    for mid, created, extra in MEETINGS:
        folder = support / "Meetings" / mid
        folder.mkdir(parents=True)
        (folder / "meeting.json").write_text(json.dumps({"id": mid, "createdAt": created, **extra}))
    (support / "Meetings" / MEETINGS[0][0] / "notes.md").write_text("Agenda: roadmap")
    return root / "home"


class OracleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._dir = tempfile.TemporaryDirectory()
        cls.rows = truth.load_rows(make_home(Path(cls._dir.name)))

    @classmethod
    def tearDownClass(cls):
        cls._dir.cleanup()

    def ids(self, tab, query):
        return [r.id[-2:] for r in truth.expected(self.rows, tab, query, NOW)]

    def test_unfiltered_dictations_newest_first_with_id_tiebreak(self):
        # E pending and unexpired is listed; F expired is not; 10 and 0A share createdAt, larger id first.
        self.assertEqual(self.ids("dictations", ""), ["11", "0E", "0C", "0B", "10", "0A"])

    def test_search_rules_per_row(self):
        # A matches through polished text, C through its preferred original, 10 plainly, 11 through a
        # speaker name; E is pending (never matches); F expired.
        self.assertEqual(self.ids("dictations", "BUDG"), ["11", "0C", "10", "0A"])

    def test_preferred_original_hides_polished_text(self):
        self.assertEqual(self.ids("dictations", "polished words"), [])

    def test_imports_search_file_name_and_body(self):
        self.assertEqual(self.ids("transcripts", "voice"), ["0D"])
        self.assertEqual(self.ids("transcripts", "imported"), ["0D"])
        self.assertEqual(self.ids("dictations", "voice"), [])

    def test_meetings_visible_text_title_notes_and_attempt(self):
        self.assertEqual(self.ids("meetings", ""), ["02", "01"])          # deleted one excluded
        self.assertEqual(self.ids("meetings", "budget"), ["01"])         # 02 is an old attempt
        self.assertEqual(self.ids("meetings", "secret"), [])             # echo turn hidden
        self.assertEqual(self.ids("meetings", "roadmap"), ["01"])        # notes
        self.assertEqual(self.ids("meetings", "weekly"), ["01"])         # title

    def test_meeting_text_slices_utf16_and_labels_speakers(self):
        # "🙂 budget": the emoji is two UTF-16 units, so the word starts at unit 3, not character 2.
        row = {"text": "🙂 budget talk", "speakerNames": {"mic:S1": "Ana"},
               "turns": [{"id": "a", "speakerId": "mic:S1", "originalTextRange": [3, 9]},
                         {"id": "b", "speakerId": "sys:S2", "processedText": "  plain words  "},
                         {"id": "c", "speakerId": "mic:S1", "originalTextRange": [9, 9]},
                         {"id": "d", "speakerId": "mic:S1", "processedText": "hidden echo"}]}
        self.assertEqual(truth.meeting_plain_text(row, {"d"}), "Ana: budget\n\nplain words")

    def test_context_attendees_are_refused_not_guessed(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = make_home(Path(tmp))
            (home / truth.SUPPORT / "Meetings" / MEETINGS[0][0] / "context.json").write_text("{}")
            with self.assertRaisesRegex(ValueError, "context attendees"):
                truth.load_rows(home)

    def test_non_ascii_query_uses_foundation_matching(self):
        # The app matches with localizedCaseInsensitiveContains: case folds, accents do not.
        Row = truth.Row
        rows = [Row("dictations", "A", NOW - 10, "Café", ("Café au lait",)),
                Row("dictations", "B", NOW - 20, "cafe", ("cafe plain",)),
                Row("dictations", "C", NOW - 30, "日本", ("日本語のテキスト",))]
        self.assertEqual([r.id for r in truth.expected(rows, "dictations", "CAFÉ", NOW)], ["A"])
        self.assertEqual([r.id for r in truth.expected(rows, "dictations", "日本", NOW)], ["C"])

    def test_hand_written_rows_check_the_foundation_oracle_itself(self):
        # Independent expectations written by hand (parent session 2026-11-17), not derived from
        # Foundation: sharp s folds to "ss" both ways; case folds; accents and width do not.
        Row = truth.Row
        truth.pin_locale(identifier="en_US")
        rows = [Row("dictations", "S", NOW - 10, "Straße", ("Hauptstraße 5",)),
                Row("dictations", "E", NOW - 20, "Élan", ("ÉLAN vital",)),
                Row("dictations", "N", NOW - 30, "naive", ("naive plain",))]
        ids = lambda q: [r.id for r in truth.expected(rows, "dictations", q, NOW)]
        self.assertEqual(ids("strasse"), ["S"])
        self.assertEqual(ids("STRASSE"), ["S"])
        self.assertEqual(ids("straße"), ["S"])
        self.assertEqual(ids("élan"), ["E"])
        self.assertEqual(ids("elan"), [])
        self.assertEqual(ids("naïve"), [])


class Fake:
    def __init__(self, shown, created):
        self.shown, self.created = shown, created


DAY1, DAY2 = T0 + DAY + 3600, T0 + 3600   # two local days, newest first


class CheckerTests(unittest.TestCase):
    def setUp(self):
        self.rows = [Fake("alpha", DAY1), Fake("beta text", DAY1 - 60), Fake("gamma", DAY2)]
        self.answer = check.expected_tokens(self.rows)
        self.previous = check.expected_tokens([Fake("delta", DAY1 + 60), Fake("alpha", DAY1)])
        self.older = check.expected_tokens([Fake("omega", DAY2 + 30)])

    def card(self, row, *texts):
        return ("card", check.time_label(row.created), list(texts) or [row.shown])

    def obs(self, *items):
        return check.tokens_from_items(list(items))

    def test_expected_tokens_carry_day_totals_labels_and_primary_text(self):
        self.assertEqual(self.answer, [
            ("count", 2), ("row", check.time_label(DAY1), "alpha"),
            ("row", check.time_label(DAY1 - 60), "beta text"),
            ("count", 1), ("row", check.time_label(DAY2), "gamma")])
        self.assertEqual(check.expected_tokens([]), [check.EMPTY])

    def test_exact_text_with_matching_label_is_correct(self):
        a, b = self.rows[0], self.rows[1]
        observed = self.obs(self.card(a, "Play", "alpha", "Whisper", "eg-1"), self.card(b, "beta", "text"),
                            ("filled",))
        self.assertEqual(check.classify(observed, self.answer, [self.previous]), "correct")

    def test_a_prefix_that_does_not_fill_the_list_is_incomplete(self):
        # Codex verdict 2026-11-17: one correct card must never validate an incomplete page.
        a, b, c = self.rows
        self.assertEqual(check.classify(self.obs(self.card(a)), self.answer, []), "incomplete")
        self.assertEqual(check.classify(self.obs(self.card(a), self.card(b)), self.answer, []), "incomplete")
        # The whole answer visible needs no FILLED mark; a filled viewport needs no whole answer.
        self.assertEqual(check.classify(self.obs(self.card(a), self.card(b), self.card(c)), self.answer, []),
                         "correct")
        self.assertEqual(check.classify(self.obs(self.card(a), ("filled",)), self.answer, []), "correct")
        # FILLED alone is not a page.
        self.assertEqual(check.classify(self.obs(("filled",)), self.answer, []), "unreadable")

    def test_containment_is_not_enough(self):
        # An old card "alpha beta" at the right time must not pass for the expected row "alpha".
        observed = self.obs(("card", check.time_label(DAY1), ["alpha beta"]))
        self.assertEqual(check.classify(observed, self.answer, []), "wrong")

    def test_wrong_time_label_is_not_a_match(self):
        observed = self.obs(("card", check.time_label(DAY1 - 3600), ["alpha"]))
        self.assertEqual(check.classify(observed, self.answer, []), "wrong")

    def test_shown_day_total_must_match(self):
        a = self.rows[0]
        good = self.obs(("header", ["Saturday, November 14", "2 meetings"]), self.card(a), ("filled",))
        bad = self.obs(("header", ["Saturday, November 14", "5 meetings"]), self.card(a))
        self.assertEqual(check.classify(good, self.answer, []), "correct")
        self.assertEqual(check.classify(bad, self.answer, []), "wrong")

    def test_previous_page_is_retained_and_older_is_stale(self):
        delta = Fake("delta", DAY1 + 60)
        self.assertEqual(check.classify(self.obs(self.card(delta)), self.answer, [self.previous]), "retained")
        omega = Fake("omega", DAY2 + 30)
        self.assertEqual(check.classify(self.obs(self.card(omega)), self.answer, [self.older, self.previous]), "stale")

    def test_card_matching_a_different_expected_row_is_ambiguous(self):
        twin = [Fake("same", DAY1), Fake("same", DAY1), Fake("other", DAY1)]
        answer = check.expected_tokens(twin)
        # Identical rows are interchangeable: not ambiguous.
        self.assertEqual(check.classify(self.obs(self.card(twin[0]), self.card(twin[1]), ("filled",)), answer, []),
                         "correct")
        # A card whose texts also hold a different expected row's text at the same time is refused.
        mixed = self.obs(("card", check.time_label(DAY1), ["same", "other"]))
        self.assertEqual(check.classify(mixed, answer, []), "ambiguous")

    def test_unreadable_incomplete_wrong_and_empty_state(self):
        self.assertEqual(check.classify(None, self.answer, []), "unreadable")
        self.assertEqual(check.classify([], self.answer, []), "unreadable")
        self.assertIsNone(check.tokens_from_items([("card", check.time_label(DAY1), [" "])]))
        self.assertEqual(check.classify(self.obs(("card", "1:00\u202fAM", ["zzz"])), self.answer, [self.previous]), "wrong")
        empty = check.expected_tokens([])
        self.assertEqual(check.classify(check.tokens_from_items([("text", "Try a different search")]), empty,
                                        [self.answer]), "correct")

    def test_time_label_pattern_and_format(self):
        for label in ("8:43\u202fAM", "11:27\u202fPM", "2:46\u202fPM, Zoom"):
            self.assertTrue(check.TIME_LABEL.match(label), label)
        for text in ("Whisper", "8:43", "Copy"):
            self.assertFalse(check.TIME_LABEL.match(text), text)
        self.assertRegex(check.time_label(T0), r"^\d{1,2}:\d{2}\u202f[AP]M$")


class CasesTests(unittest.TestCase):
    def test_cases_cover_every_tab_and_step_kind(self):
        cases = json.loads((HERE / "search_cases.json").read_text())
        # The seven 2026-11-14 cases plus the 2026-11-17 short and non-ASCII cases.
        self.assertEqual(len(cases["historical"]), 13)
        queries = [c["query"] for c in cases["historical"]]
        self.assertTrue(any(len(q) <= 2 for q in queries))
        self.assertTrue(any(not q.isascii() and any(ord(ch) > 0x900 for ch in q) for q in queries))
        self.assertTrue(any(not q.isascii() and all(ord(ch) < 0x300 for ch in q) for q in queries))
        tabs = {s["tab"] for s in cases["sequences"]}
        kinds = {step[0] for s in cases["sequences"] for step in s["steps"]}
        self.assertEqual(tabs, {"Dictations", "Transcripts", "Meetings"})
        self.assertTrue({"overlap", "clear"} <= kinds)
        for s in cases["sequences"]:
            self.assertTrue(all(step[0] in {"type", "paste", "overlap", "clear"} for step in s["steps"]))


if __name__ == "__main__":
    unittest.main()
