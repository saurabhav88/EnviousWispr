"""Recordings storage-warning banner watch for the History speed drivers (#4586 WP-A).

The banner is found by the accessibility identifier of its "Open Recordings settings" button
(RecordingsSettingsView), not by its translated text. Pure logic lives here so it is testable offline.
"""
BANNER_IDENTIFIER = "history.recordingStorage.openSettings"


def find_banner(history_reader, ui, window):
    """True when the banner button is present outside the list (the list is never descended)."""
    return bool(history_reader.find_outside_list(
        window, lambda e, r: ui.get_attr(e, "AXIdentifier") == BANNER_IDENTIFIER))


def banner_jump(polls):
    """`polls` is [(t_ms, shown, list_y_or_None)] taken together, in order, from page confirmation.

    Returns the report record. The jump is a number only when a valid list-position read exists both
    before the first poll that shows the banner and at or after it (the reads bracket the change);
    otherwise `jump_pt` is None with a `jump_not_measured` reason, never 0."""
    seen = next((i for i, p in enumerate(polls) if p[1]), None)
    record = {"reads": len(polls), "seen_at_ms": polls[seen][0] if seen is not None else None,
              "list_y_before": None, "list_y_after": None, "jump_pt": None, "jump_not_measured": None}
    if seen is None:
        record["jump_not_measured"] = "banner never seen" if polls else "no reads"
        return record
    before = [p[2] for p in polls[:seen] if p[2] is not None]
    after = [p[2] for p in polls[seen:] if p[2] is not None]
    if not before:
        record["jump_not_measured"] = "no valid list position read before the banner first appeared"
    elif not after:
        record["jump_not_measured"] = "no valid list position read after the banner appeared"
    else:
        # the read that brackets the change: last one before, first one at or after the banner poll
        record["list_y_before"], record["list_y_after"] = before[-1], after[0]
        record["jump_pt"] = round(after[0] - before[-1], 1)
    return record


def read_poll(read_banner, read_y):
    """One poll: banner, then list y, then the banner again. If the two banner reads differ the banner
    appeared (or went) between them, so the y may belong to either layout: it is invalid (None) and
    `shown` takes the second read. Returns (shown, y)."""
    before = read_banner()
    y = read_y()
    after = read_banner()
    if before != after:
        return after, None
    return after, y
