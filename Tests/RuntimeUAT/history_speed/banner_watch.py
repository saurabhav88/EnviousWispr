"""Recordings storage-warning banner watch for the History speed drivers (#4586 WP-A).

The banner is found by the accessibility identifier of its "Open Recordings settings" button
(RecordingsSettingsView), not by its translated text. The diagnostic reports only whether the banner
was seen and when (ms after spawn). Pure logic lives here so it is testable offline.
"""
BANNER_IDENTIFIER = "history.recordingStorage.openSettings"


def find_banner(history_reader, ui, window):
    """True when the banner button is present outside the list (the list is never descended)."""
    return bool(history_reader.find_outside_list(
        window, lambda e, r: ui.get_attr(e, "AXIdentifier") == BANNER_IDENTIFIER))


def watch(read_banner, now_ms, pause, deadline_ms):
    """Poll `read_banner` until the first read at or after `deadline_ms` (now_ms() is ms after spawn).

    Returns {"reads", "seen_at_ms", "watched_to_deadline"}. `seen_at_ms` is the first read that showed
    the banner, else None. `watched_to_deadline` is true only when the FIRST read happened before the
    deadline, so the reads covered the whole window up to it; a launch whose first read came late was
    not watched and must not count as "banner never seen"."""
    reads, seen_at, first_at = 0, None, None
    while True:
        shown = read_banner()
        t = now_ms()
        reads += 1
        first_at = t if first_at is None else first_at
        if shown and seen_at is None:
            seen_at = round(t)
        if t >= deadline_ms:
            break
        pause()
    return {"reads": reads, "seen_at_ms": seen_at, "watched_to_deadline": first_at < deadline_ms}
