"""Read the History list through accessibility (#4586 WP-A). One reader for every driver.

Calibrated live on main acd9e956e, Release subject, 2026-11-17 (run folder
`20261117-090833-4586-wpa-instruments-8dea/probe-1`): the list is an `AXTable` inside an
`AXScrollArea` (`HistoryDiaryTable`, an NSTableView). Every list entry is one `AXRow`:

- a day header row holds two texts: the date ("Saturday, November 14") and the day total
  ("2 dictations"; every tab shows it);
- a card row starts with its time label ("8:43 AM", or "2:46 PM, Zoom" on Meetings) and
  then the card's texts and button titles in reading order ("Show more", the dictation text, "Play",
  "0:02", "Whisper", "eg-1", "Show edits", "Copy", "More actions").

`AXRows` lists only the rows the table has loaded (pages of 30); `AXVisibleRows` lists the rows on
screen. Row frames come from the table's own row rectangles, so an off-screen row still reports its
position: the first loaded row's y moves with the scroll position as long as it stays the same row
(a page that loads or drops at the top changes which row is first), and a visible row's height is
the height the table gives it right now.

Reads run on the app's main thread: keep them out of any interval a hitch trace measures.
"""
from __future__ import annotations

import re

TIME_LABEL = re.compile(r"^\d{1,2}:\d{2} ?[AP]M\b")
FILL_SLACK = 1.0   # points: a last visible row ending this close to the viewport bottom fills it


def _ui():
    import ui_helpers as ui
    return ui


def find_outside_list(window, predicate, max_depth=30):
    """Every element under `window` for which `predicate(element, role)` is true, WITHOUT descending
    into any AXTable. The list's loaded rows hold hundreds of elements; answering them makes the app
    build accessibility for every hosted row, which on the M1 (8 GB) kept the main thread busy for
    minutes while the catalog rebuilt (2026-11-17). The search box, tabs and filters sit outside it."""
    ui = _ui()
    found, stack = [], [(window, 0)]
    while stack:
        element, depth = stack.pop()
        role = ui.get_attr(element, "AXRole")
        if predicate(element, role):
            found.append(element)
        if role == "AXTable" or depth >= max_depth:
            continue
        children = ui.get_attr(element, "AXChildren") or []
        stack.extend((child, depth + 1) for child in reversed(list(children)))
    return found


def find_button(window, title):
    """The first button outside the list whose title or description is `title` (tabs, filters)."""
    ui = _ui()
    hits = find_outside_list(window, lambda e, r: r in ("AXButton", "AXRadioButton") and title in (
        ui.get_attr(e, "AXTitle"), ui.get_attr(e, "AXDescription")))
    return hits[0] if hits else None


def find_search_field(window, placeholder="Search history"):
    ui = _ui()
    hits = find_outside_list(window, lambda e, r: r == "AXTextField"
                             and ui.get_attr(e, "AXPlaceholderValue") == placeholder)
    return hits[0] if hits else None


def find_list(window):
    """(table, scroll area) of the History list: the largest AXTable whose parent is a scroll area."""
    ui = _ui()
    best = None
    for table in find_outside_list(window, lambda e, r: r == "AXTable"):
        area = ui.get_attr(table, "AXParent")
        frame = ui.element_frame(area) if area is not None else None
        if not frame or not frame.get("height"):
            continue
        size = frame["width"] * frame["height"]
        if best is None or size > best[0]:
            best = (size, table, area)
    return (best[1], best[2]) if best else (None, None)


def _texts(row):
    """The row's texts in reading order, with a nested duplicate of the same text removed."""
    out = []
    for text in _ui().get_all_visible_text(row, max_depth=12) or []:
        if not out or out[-1] != text:
            out.append(text)
    return out


def item_of(texts):
    """One row's texts as a reader item: ("card", label, texts), ("header", texts) or None."""
    if not texts:
        return None
    if TIME_LABEL.match(texts[0]):
        return ("card", texts[0], texts[1:])
    return ("header", texts)


def visible_items(table, area):
    """Visible rows, top to bottom, as reader items, plus a trailing ("filled",) when the last
    visible row reaches the bottom of the viewport. None when the list cannot be read."""
    ui = _ui()
    if table is None or area is None:
        return None
    viewport = ui.element_frame(area)
    rows = ui.get_attr(table, "AXVisibleRows")
    if viewport is None or rows is None:
        return None
    placed = []
    for row in rows:
        frame = ui.element_frame(row)
        if frame is None:
            return None
        if frame["y"] + frame["height"] <= viewport["y"] or frame["y"] >= viewport["y"] + viewport["height"]:
            continue   # outside the clip view (the table can report a row it is about to recycle)
        placed.append((frame["y"], frame, _texts(row)))
    placed.sort(key=lambda p: p[0])
    items = []
    for _, _, texts in placed:
        item = item_of(texts)
        if item is None:
            return None   # a row with no text is still being built: unreadable, never evidence
        items.append(item)
    if placed:
        last = placed[-1][1]
        if last["y"] + last["height"] >= viewport["y"] + viewport["height"] - FILL_SLACK:
            items.append(("filled",))
    return items


def row_heights(table, area):
    """{row identity: height} for cards and day headers on screen, or None when the read failed (a
    failed read is never an empty observation)."""
    ui = _ui()
    viewport = ui.element_frame(area) if area is not None else None
    rows = ui.get_attr(table, "AXVisibleRows") if table is not None else None
    if viewport is None or rows is None:
        return None
    found = {}
    for row in rows:
        frame = ui.element_frame(row)
        if frame is None:
            return None
        if frame["y"] + frame["height"] <= viewport["y"] or frame["y"] >= viewport["y"] + viewport["height"]:
            continue
        texts = _texts(row)
        key = identity(texts)
        if key is None:
            if not texts:
                return None   # a row with no text yet is unreadable: the sample cannot vouch for it
            continue          # a row with text that is not a card or day header: a paging control
        found[key] = frame["height"]   # keyed by content, not loaded index (paging changes the index)
    return found or None


def require_unfiltered(window, tab):
    """Refuse to measure a filtered list: the app keeps each tab's search query (cloud review P1)."""
    field = find_search_field(window)
    value = _ui().get_attr(field, "AXValue") if field is not None else None
    if field is None or value != "":   # an unreadable value is not proof of an empty box
        raise RuntimeError(f"the {tab} list is filtered by {value!r} (or has no search box); clear it first")



def identity(texts):
    """A row's stable identity: ALL its texts, for a card (starts with its time label) or a day
    header (starts with a date or Today/Yesterday). None for anything else (a paging control, a row
    still being built): such a row cannot be followed across page loads (Codex round 10)."""
    from search_check import day_key_of
    if not texts or not (TIME_LABEL.match(texts[0]) or day_key_of(texts[0])):
        return None
    return "\x1f".join(texts)


def first_row(table):
    """(identity, screen y) of the first card or day header among the list's first loaded rows, or
    None. A few rows are read, so this stays cheap on a slow Mac. When a page loads or drops at the
    top, the first row is a different row and a y difference is not travel."""
    from ApplicationServices import AXUIElementCopyAttributeValues
    err, rows = AXUIElementCopyAttributeValues(table, "AXRows", 0, 3, None)
    if err != 0 or not rows:
        return None
    for row in rows:
        key = identity(_texts(row))
        if key is not None:
            frame = _ui().element_frame(row)
            return None if frame is None else (key, frame["y"])
    return None
