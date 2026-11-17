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
position: the first row's y is the list's scroll position (travel), and a visible row's height is
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


def find_list(window):
    """(table, scroll area) of the History list: the largest AXTable whose parent is a scroll area."""
    ui = _ui()
    best = None
    for table in ui.find_all_elements(window, "AXTable", max_depth=30):
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


def first_row_y(table):
    """Screen y of the table's first row: moves exactly with the scroll position. None if unread."""
    from ApplicationServices import AXUIElementCopyAttributeValues
    err, rows = AXUIElementCopyAttributeValues(table, "AXRows", 0, 1, None)
    if err != 0 or not rows:
        return None
    frame = _ui().element_frame(rows[0])
    return None if frame is None else frame["y"]


def row_heights(table, area):
    """{row key: height} for rows on screen, or None when the read failed (a failed read is never an
    empty observation). Key = row index plus the row's first text."""
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
        found[f"{ui.get_attr(row, 'AXIndex')}:{(texts[0] if texts else '')[:40]}"] = frame["height"]
    return found or None
