"""Independent History search answers from the fixture's saved files (#4586 G1 oracle).

Reads `transcripts/*.json` and `Meetings/*/` directly and never the app, its catalog or its
logs. Mirrors the production rules it must agree with, each cited at `f9c295144`:

- Rows per tab (`HistoryCatalogSession.project`, `HistoryCatalogSession.swift:281-309`): a
  transcript with `meetingID` belongs to Meetings; `importedFileName` makes it a Transcripts row;
  everything else is a Dictation. A pending row (`escapeRecoveredAt`) is listed until
  `escapeRecoveredAt + 24 h` (`AppConstants.pendingTranscriptRetention`) and never matches a search.
- Searched fields: dictations and imports search `historyText` (`Transcript.swift:527`: a dictation
  preferring `original` gives `text`, everything else `polishedText ?? processedText ?? text`), the
  imported file name and the speaker names. Meetings (`MeetingHistoryPresentation.catalogProjection`)
  search the visible transcript text (turns not listed in `echoTurnIDs`), the title, speaker names
  and notes, only when the meeting is ready, not being deleted, and its transcript belongs to the
  committed attempt (`MeetingRecord.committedTranscriptGeneration`).
- Match: `localizedCaseInsensitiveContains` (`HistoryCatalogConnection.swift:43`); here
  `casefold()` containment when the query and every field are ASCII (they agree there), otherwise
  Foundation's own case-insensitive search through PyObjC, pinned with `pin_locale(home)` to the
  locale the fixture app runs with, so accented and non-Latin queries follow the app's rule.
- Order: `saved_at DESC, id DESC` (`HistoryCatalog.swift:297`), saved_at = `createdAt`.

Meeting visible text follows `MeetingTranscriptProjection.plainText` (`EnviousWisprCore/
MeetingTranscriptProjection.swift:29-51`): visible turns only; each turn's words are its
`processedText`, else the UTF-16 slice `originalTextRange` of the row text, trimmed; empty turns
are dropped; a turn whose speaker has a non-empty name reads "Name: words"; turns are joined by a
blank line. Gap markers are rewritten into the interface language (`MeetingGapPresentation`); the
fixture's projection context is English, where the rewrite returns the stored English marker, so
the stored text is used unchanged.

Searchable meeting context attendees (`context.json`, `MeetingParticipants.resolve`) are NOT
reproduced: the oracle refuses a meeting folder that has a `context.json`. The 2026-11-15 seed has
none (0 of 37 meetings), so the refusal never fires on it; any other corpus must extend this first.

Usage: python3 m5-speed-ground-truth.py <fixture home> <dictations|transcripts|meetings> <query> [days]
"""

from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta
import json
from pathlib import Path
import sys

REFERENCE_EPOCH = 978307200          # 2001-01-01, the Apple reference date
PENDING_RETENTION = 24 * 60 * 60     # AppConstants.pendingTranscriptRetention
LEGACY_ATTEMPT = "legacy"            # stands for MeetingRecord.legacyTranscriptAttemptID
SUPPORT = Path("Library/Application Support/EnviousWispr")
TABS = ("dictations", "transcripts", "meetings")


@dataclass(frozen=True)
class Row:
    tab: str
    id: str            # uppercase UUID string, as the catalog stores it
    created: float     # seconds since the reference date
    shown: str         # the text a card leads with (dictation text, import file name, meeting title)
    fields: tuple      # searched strings; empty means "never matches a search"
    expires: float | None = None


def _dictation_text(row: dict) -> str:
    if row.get("preferredVersion") == "original":
        return row.get("text") or ""
    return row.get("polishedText") or row.get("processedText") or row.get("text") or ""


def _display_text(row: dict) -> str:
    return row.get("polishedText") or row.get("processedText") or row.get("text") or ""


def _turn_words(row: dict, turn: dict) -> str:
    """`MeetingTranscriptProjection.displayWords`: processedText, else the clamped UTF-16 slice."""
    if turn.get("processedText") is not None:
        return turn["processedText"].strip()
    units = (row.get("text") or "").encode("utf-16-le")
    count = len(units) // 2
    span = turn.get("originalTextRange") or [0, 0]
    if not (isinstance(span, list) and len(span) == 2):
        raise ValueError(f"unexpected originalTextRange {span!r}")
    lower = max(0, min(int(span[0]), count))
    upper = max(lower, min(int(span[1]), count))
    return units[2 * lower:2 * upper].decode("utf-16-le", errors="replace").strip()


def meeting_plain_text(row: dict, echo: set) -> str:
    names = row.get("speakerNames") or {}
    paragraphs = []
    for turn in row.get("turns") or []:
        if turn.get("id") in echo:
            continue
        words = _turn_words(row, turn)
        if not words:
            continue
        name = names.get(turn.get("speakerId"))
        paragraphs.append(f"{name}: {words}" if name else words)
    return "\n\n".join(paragraphs)


def load_rows(home: Path) -> list[Row]:
    """Every History row the fixture home can list, across all three tabs."""
    support = Path(home) / SUPPORT
    transcripts = {}
    rows = []
    for path in sorted((support / "transcripts").glob("*.json")):
        row = json.loads(path.read_text())
        transcripts[str(row["id"]).upper()] = row
        if row.get("meetingID"):
            continue
        pending = row.get("escapeRecoveredAt")
        imported = row.get("importedFileName")
        text = _display_text(row) if imported else _dictation_text(row)
        fields = [text] + ([imported] if imported else []) + list((row.get("speakerNames") or {}).values())
        rows.append(Row(tab="transcripts" if imported else "dictations", id=str(row["id"]).upper(),
                        created=float(row["createdAt"]), shown=imported or text,
                        fields=() if pending is not None else tuple(fields),
                        expires=None if pending is None else float(pending) + PENDING_RETENTION))
    for meeting_file in sorted((support / "Meetings").glob("*/meeting.json")):
        meeting = json.loads(meeting_file.read_text())
        if meeting.get("deletionRequested"):
            continue
        folder = meeting_file.parent
        if (folder / "context.json").exists():
            raise ValueError(f"meeting context attendees are not reproduced by this oracle: {folder}")
        generation = meeting.get("committedTranscriptAttemptID") or (
            LEGACY_ATTEMPT if meeting.get("state") == "ready" else None)
        row = transcripts.get(str(meeting.get("transcriptID", "")).upper())
        fields = []
        if row is not None and generation is not None and meeting.get("state") == "ready" \
                and str(row.get("meetingID", "")).upper() == str(meeting["id"]).upper() \
                and (row.get("meetingTranscriptAttemptID") or LEGACY_ATTEMPT) == generation:
            fields.append(meeting_plain_text(row, set(meeting.get("echoTurnIDs") or [])))
            if meeting.get("title"):
                fields.append(meeting["title"])
            fields += list((row.get("speakerNames") or {}).values())
            notes = folder / "notes.md"
            if notes.is_file():
                fields.append(notes.read_text())
        rows.append(Row(tab="meetings", id=str(meeting["id"]).upper(), created=float(meeting["createdAt"]),
                        shown=meeting.get("title") or "", fields=tuple(fields)))
    return rows


LOCALE_ID = None   # set by pin_locale(); None means this process's current locale


def pin_locale(home=None, identifier=None) -> str:
    """Pin the Foundation matcher to the locale the fixture app runs with. With a fixture home, read
    `NSLocale.currentLocale` in a child process that has the subject's HOME and CFFIXED_USER_HOME
    (the app reads its global preferences from there). Returns the identifier in use."""
    global LOCALE_ID
    if identifier is None and home is not None:
        import os
        import subprocess
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        identifier = subprocess.run(
            [sys.executable, "-c", "from Foundation import NSLocale; print(NSLocale.currentLocale().localeIdentifier())"],
            env=env, capture_output=True, text=True, check=True).stdout.strip()
    LOCALE_ID = identifier
    return identifier


def _foundation_contains(field: str, query: str) -> bool:
    """`localizedCaseInsensitiveContains` = rangeOfString:options:NSCaseInsensitiveSearch locale:current."""
    from Foundation import NSCaseInsensitiveSearch, NSLocale, NSMakeRange, NSString, NSNotFound
    locale = NSLocale.localeWithLocaleIdentifier_(LOCALE_ID) if LOCALE_ID else NSLocale.currentLocale()
    text = NSString.stringWithString_(field)
    found = text.rangeOfString_options_range_locale_(query, NSCaseInsensitiveSearch,
                                                      NSMakeRange(0, text.length()), locale)
    return found.location != NSNotFound


def matches(row: Row, query: str) -> bool:
    if not query:
        return True
    if query.isascii() and all(field.isascii() for field in row.fields):
        needle = query.casefold()
        return any(needle in field.casefold() for field in row.fields)
    return any(_foundation_contains(field, query) for field in row.fields)


def expected(rows: list[Row], tab: str, query: str, now: float) -> list[Row]:
    """The rows History must list for `query` on `tab`, newest first, at time `now`."""
    if tab not in TABS:
        raise ValueError(f"unknown tab {tab!r}")
    listed = [r for r in rows if r.tab == tab and (r.expires is None or r.expires > now) and matches(r, query)]
    return sorted(listed, key=lambda r: (r.created, r.id), reverse=True)


def day_counts(listed: list[Row], days: int = 6) -> list[list]:
    counter = Counter(datetime.fromtimestamp(REFERENCE_EPOCH + r.created).date() for r in listed)
    return [[str(d), counter[d]] for d in sorted(counter, reverse=True)[:days]]


def now_reference() -> float:
    return datetime.now().timestamp() - REFERENCE_EPOCH


def main():
    if len(sys.argv) < 4 or sys.argv[1] in ('-h', '--help'):
        print(__doc__)
        return 2
    home, tab, query = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    days = int(sys.argv[4]) if len(sys.argv) > 4 else 6
    listed = expected(load_rows(home), tab, query, now_reference())
    print(json.dumps({"query": query, "tab": tab, "total": len(listed),
                      "first": [r.shown[:80] for r in listed[:5]], "newest_days": day_counts(listed, days)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
