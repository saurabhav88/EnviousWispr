"""Offline analysis for the History scroll driver (#4586 WP-A). Pure functions, no app, no AX.

Three numbers per tab and input kind:

- hitch ms per moving second: Animation Hitches rows (from `xctrace export`) whose start lies inside
  a span when the list was moving on screen, summed, divided by the moving seconds. Moving spans
  come from the frame recorder: per gesture, from the first captured frame that differs from the
  picture before the gesture to the last frame that still changed.
- rows that change height after first display: per row identity, the first height the list showed
  and every later height; a row counts when a later height differs by more than HEIGHT_TOLERANCE.
- travel symmetry: the same gesture down then up moves the list by `down` and `up` points;
  asymmetry = |down - up| / down.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET

HEIGHT_TOLERANCE = 1.0       # points; AX frames are rounded to whole or half points
SETTLE_GAP_S = 0.25          # a picture unchanged this long after the last event ends a moving span


def moving_span(frames, before_hash, start_s, end_s, last_event_s=None):
    """The declared interaction interval of one gesture: from its first event (`start_s`) to the
    later of its last event (`last_event_s`) and the last captured frame inside [start_s, end_s]
    whose picture changed. Freezes at the start, in the middle and up to the last event all stay
    inside (Codex rounds 1-2). frames: [(seconds, hash)] sorted by time. None when the picture
    never changed (the list did not move)."""
    last = None
    previous = before_hash
    for at, digest in frames:
        if at < start_s:
            previous = digest
            continue
        if at > end_s:
            break
        if digest != previous:
            last = at
        previous = digest
    if last is None:
        return None
    return (start_s, max(last, last_event_s if last_event_s is not None else last))


def kept_moving_after(span, last_event_s):
    """Seconds the picture kept changing after the last scroll event (0 when it stopped first)."""
    return 0.0 if span is None else max(0.0, span[1] - last_event_s)


def parse_hitches(xml_text: str):
    """[(start_s, duration_s, pid, is_system)] from
    `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]'`.
    Columns: start, duration, process, is-system, ... xctrace writes each value once with an `id`
    and later rows point at it with `ref`; a process value reads "Name (pid)" in its `fmt`."""
    import re
    root = ET.fromstring(xml_text)
    by_id = {}
    for element in root.iter():
        if "id" in element.attrib:
            by_id[element.attrib["id"]] = element
    resolve = lambda e: by_id.get(e.attrib["ref"], e) if "ref" in e.attrib else e
    rows = []
    for row in root.iter("row"):
        cells = [resolve(e) for e in list(row)]
        if len(cells) < 2:
            continue
        start, duration = int(cells[0].text), int(cells[1].text)
        pid, system = None, None
        if len(cells) > 2:
            match = re.search(r"\((\d+)\)", cells[2].attrib.get("fmt", ""))
            pid = int(match.group(1)) if match else None
        if len(cells) > 3 and cells[3].text is not None:
            system = cells[3].text.strip() in ("1", "true", "Yes")
        rows.append((start / 1e9, duration / 1e9, pid, system))
    return rows


def hitch_rate(hitches, spans, pid=None, windows=None):
    """hitches: [(start_s, duration_s, pid, is_system)] on the same clock as spans [(a, b)]; only the
    subject's hitches count when `pid` is given. A hitch counts when it overlaps a span, or when it
    starts inside that gesture's observation window (`windows`: the end of each gesture's watched
    period) after the span: a trailing freeze then extends the interval to the hitch's end, so a
    freeze after the last changed frame is never dropped (Codex round 3).
    Returns {moving_s, hitch_ms, ms_per_s, count, longest_ms, other_process}."""
    mine = [h for h in hitches if pid is None or h[2] == pid]
    windows = windows or [None] * len(spans)
    counted, seen, moving = [], set(), 0.0
    starts = [sp[0] for sp in spans if sp is not None]
    for span, window_end in zip(spans, windows):
        if span is None or span[1] <= span[0]:
            continue
        a, b = span
        limit = max(b, window_end) if window_end is not None else b
        later = [x for x in starts if x > a]
        if later:
            limit = min(limit, later[0])   # a window never reaches into the next gesture
        inside = [(s, d) for s, d, *_ in mine if s < limit and s + d > a and (s, d) not in seen]
        seen.update(inside)                # a hitch spanning two gestures counts once (cloud review)
        end = max([b] + [s + d for s, d in inside if s >= b])
        if later:
            end = min(end, later[0])
        counted += inside
        moving += end - a
    total_ms = sum(d for _, d in counted) * 1000
    return {"moving_s": round(moving, 3), "hitch_ms": round(total_ms, 1),
            "ms_per_s": round(total_ms / moving, 2) if moving > 0 else None,
            "count": len(counted), "longest_ms": round(max([d for _, d in counted] or [0]) * 1000, 1),
            "other_process": len(hitches) - len(mine)}


def trace_start_epoch(toc_xml: str):
    """Epoch seconds of the recording start from `xctrace export --toc` (`<start-date>`, ms precision)."""
    from datetime import datetime
    root = ET.fromstring(toc_xml)
    element = root.find(".//run/info/summary/start-date")
    if element is None:
        element = root.find(".//start-date")
    return None if element is None else datetime.fromisoformat(element.text).timestamp()


def height_changes(samples):
    """samples: [{row_key: height} or None] in time order (None = a failed read). Returns
    (changed rows, rows seen, failed reads). changed: [{row, first, later}] for every row whose
    height later moved by > HEIGHT_TOLERANCE."""
    first, changed, failed = {}, {}, 0
    for sample in samples:
        if sample is None:
            failed += 1
            continue
        for key, height in sample.items():
            if key not in first:
                first[key] = height
            elif abs(height - first[key]) > HEIGHT_TOLERANCE and key not in changed:
                changed[key] = {"row": key, "first": first[key], "later": height}
    return list(changed.values()), len(first), failed


def travel(y_start, y_after_down, y_after_up, top_y=None):
    """First-row screen y before the down gesture, after it, and after the up gesture. Scrolling
    down moves the first row UP the screen (y falls). Returns {down, up, asymmetry, problem}:
    asymmetry is |down - up| / down, and None with a `problem` when the list did not move down and
    then back up, or when the up gesture ended clamped at the top (`top_y`: the first row's y when
    the list is at its newest row), where equal travel is impossible to judge."""
    down = y_start - y_after_down
    up = y_after_up - y_after_down
    out = {"down": round(down, 1), "up": round(up, 1), "asymmetry": None, "problem": None}
    if down <= 0 or up <= 0:
        out["problem"] = "the list did not move down and then back up"
    elif top_y is not None and abs(y_after_up - top_y) <= 0.5:
        out["problem"] = "the up gesture ended clamped at the top"
    else:
        out["asymmetry"] = round(abs(down - up) / down, 4)
    return out


BUDGET = {"ms_per_s": 5.0, "height_changed": 0, "asymmetry": 0.02}


def verdict(hitch, changed, symmetry, rows_seen=None, failed_reads=0, hitch_required=True):
    """PASS only when every number exists and is inside budget. FAIL when a number is over budget,
    a row changed height, or the list moved the wrong way. UNPROVEN when a number is missing, no row
    was observed, or a height read failed (unless a change already proves FAIL). A repeat without
    its own hitch trace is judged on travel and heights only (`hitch_required=False`)."""
    if symmetry is not None and symmetry.get("problem") == "the list did not move down and then back up":
        return "FAIL"
    if changed:
        return "FAIL"
    if hitch_required and hitch is not None and hitch.get("ms_per_s") is not None \
            and hitch["ms_per_s"] > BUDGET["ms_per_s"]:
        return "FAIL"
    if symmetry is not None and symmetry.get("asymmetry") is not None and symmetry["asymmetry"] > BUDGET["asymmetry"]:
        return "FAIL"
    if (hitch_required and (hitch is None or hitch.get("ms_per_s") is None)) or symmetry is None \
            or symmetry.get("asymmetry") is None or changed is None or rows_seen == 0 or failed_reads:
        return "UNPROVEN"
    return "PASS"
