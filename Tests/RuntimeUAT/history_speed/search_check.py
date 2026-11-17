"""Decide what one observation of the History list shows, against independent answers (#4586 G1).

Fitted to the calibrated layout (2026-11-15, pinned Release subject): the list's content is a flat
run of accessibility elements. A day header is a group holding the date and, on Meetings, the day
total ("3 meetings"). Every card starts with its time label ("8:43\u202fAM", or "2:46\u202fPM, Zoom"
on Meetings) and its texts follow until the next time label or day header.

Expected tokens come from the independent oracle (`m5-speed-ground-truth.py`): per local day a
("count", n, ISO day) token, then one ("row", time label, primary text) per row, newest first. The primary
text is the dictation text, the import file name, or the meeting title.

Observed tokens: ("count", n, ISO day or None) for a header that shows a total, ("card", time label, texts).
A card shows a row only when the card's label starts with the row's time label AND one of the
card's texts, or a contiguous run of them joined by spaces, EQUALS the row's primary text
(containment is not enough: an old card "alpha beta" must not pass for "alpha"). A header total,
when shown, must equal the expected total of its day.

    correct     the visible tokens are the start of this query's answer AND the page is complete:
                the reader saw the list fill its viewport (a trailing FILLED token), or every
                expected row is visible. A prefix that stops short of both is `incomplete`.
    incomplete  a correct start that neither fills the viewport nor ends the answer
    retained    they are the start of the previous complete page (approved while pending)
    stale       they are the start of an OLDER or superseded query's answer: a late publication
    ambiguous   a visible card also matches a different expected row: refused, never correct
    wrong       anything else readable
    unreadable  nothing, or an incomplete card, could be read; never a timing sample
"""
from datetime import datetime
import re

TIME_LABEL = re.compile(r"^\d{1,2}:\d{2}\u202f?[AP]M\b")
COUNT_RE = re.compile(r"^(\d+) (dictations?|transcripts?|meetings?)$")
EMPTY_STATE = "Try a different search"   # the driver also emits it for an empty, loaded list (no message in this build)
EMPTY = ("empty",)
FILLED = ("filled",)   # the reader's mark: the last visible row reaches the viewport bottom
REFERENCE_EPOCH = 978307200


def normalise(text: str) -> str:
    return " ".join(text.split())


def time_label(created: float) -> str:
    """The card's time as the app shows it for the en_US fixture context: "8:43\u202fAM"."""
    moment = datetime.fromtimestamp(REFERENCE_EPOCH + created)
    return moment.strftime("%-I:%M") + "\u202f" + moment.strftime("%p")


MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December")
DAY_RE = re.compile(r"\b(" + "|".join(MONTHS) + r") (\d{1,2})(?:, (\d{4}))?\b")


def day_key(date) -> str:
    """The calendar day a day header names, as ISO "2026-11-14"."""
    return date.isoformat()


def day_key_of(text: str, today=None):
    """A day header's text as ISO date: "Today", "Yesterday", "Saturday, November 14" (this year)
    or "Monday, March 3, 2025". None when the text names no day (it is then not compared)."""
    from datetime import date, timedelta
    today = today or date.today()
    lowered = text.strip().lower()
    if lowered == "today":
        return today.isoformat()
    if lowered == "yesterday":
        return (today - timedelta(days=1)).isoformat()
    m = DAY_RE.search(text)
    if not m:
        return None
    year = int(m.group(3)) if m.group(3) else today.year
    return date(year, MONTHS.index(m.group(1)) + 1, int(m.group(2))).isoformat()


def expected_tokens(rows) -> list:
    if not rows:
        return [EMPTY]
    tokens, day, count_at = [], None, None
    for row in rows:
        this_day = datetime.fromtimestamp(REFERENCE_EPOCH + row.created).date()
        if this_day != day:
            day = this_day
            count_at = len(tokens)
            tokens.append(["count", 0, day_key(this_day)])
        tokens[count_at][1] += 1
        tokens.append(("row", time_label(row.created), normalise(row.shown)))
    return [tuple(t) for t in tokens]


def tokens_from_items(items) -> list | None:
    """items: ("header", texts), ("card", label, texts) or ("text", s), in on-screen order."""
    if items is None:
        return None
    tokens = []
    for item in items:
        if item[0] == "filled":
            tokens.append(FILLED)
            continue
        if item[0] == "text":
            if EMPTY_STATE in item[1]:
                return [EMPTY]
            continue
        if item[0] == "header":
            texts = [normalise(t) for t in item[1]]
            day = next((key for key in (day_key_of(t) for t in texts) if key), None)
            for text in texts:
                m = COUNT_RE.match(text)
                if m:
                    tokens.append(("count", int(m.group(1)), day))
            continue
        label, texts = item[1], [normalise(t) for t in item[2] if normalise(t)]
        if not texts:
            return None   # an incomplete card is unreadable, never evidence
        tokens.append(("card", label, tuple(texts)))
    return tokens


def _shows(card, row) -> bool:
    if card[0] != "card" or row[0] != "row" or not card[1].startswith(row[1]):
        return False
    texts = card[2]
    for start in range(len(texts)):
        for end in range(start + 1, len(texts) + 1):
            if " ".join(texts[start:end]) == row[2]:
                return True
    return False


def _align(observed, answer):
    """Pairs (observed index, answer index) for a prefix match, or None."""
    if not observed:
        return None
    if observed == [EMPTY] or answer == [EMPTY]:
        return [] if list(observed) == list(answer) else None
    pairs, j = [], 0
    for i, token in enumerate(observed):
        if token[0] == "count":
            # The day total must match, and so must the day when the header names one (a stale page
            # with the same times, texts and totals on another day is not this answer).
            if j >= len(answer) or answer[j][0] != "count" or answer[j][1] != token[1] \
                    or (token[2] is not None and token[2] != answer[j][2]):
                return None
            j += 1
            continue
        while j < len(answer) and answer[j][0] == "count":
            j += 1
        if j >= len(answer) or not _shows(token, answer[j]):
            return None
        pairs.append((i, j))
        j += 1
    return pairs if pairs else None


def _ambiguous(observed, answer, pairs) -> bool:
    for i, j in pairs:
        for k, row in enumerate(answer):
            if row[0] == "row" and k != j and row != answer[j] and _shows(observed[i], row):
                return True
    return False


def classify(observed, current, history) -> str:
    """`history` lists earlier answers in the order they were shown; its last entry is the
    previous complete page. Superseded queries belong before it, so they count as older."""
    if observed is None or len(observed) == 0:
        return "unreadable"
    filled = observed[-1] == FILLED
    observed = [t for t in observed if t != FILLED]
    if not observed:
        return "unreadable"
    pairs = _align(observed, current)
    if pairs is not None:
        if _ambiguous(observed, current, pairs):
            return "ambiguous"
        rows_expected = sum(1 for t in current if t[0] == "row")
        if observed == [EMPTY] or filled or len(pairs) == rows_expected:
            return "correct"
        return "incomplete"
    if history:
        if _align(observed, history[-1]) is not None:
            return "retained"
        if any(_align(observed, older) is not None for older in history[:-1]):
            return "stale"
    return "wrong"
