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


def moving_span(frames, before_hash, start_s, end_s):
    """frames: [(seconds, hash)] sorted by time. Returns (first_change_s, last_change_s) inside
    [start_s, end_s], or None when the picture never changed (the list did not move)."""
    first = last = None
    previous = before_hash
    for at, digest in frames:
        if at < start_s:
            previous = digest
            continue
        if at > end_s:
            break
        if digest != previous:
            if first is None:
                first = at
            last = at
        previous = digest
    return None if first is None else (first, last)


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


def hitch_rate(hitches, spans, pid=None):
    """hitches: [(start_s, duration_s, pid, is_system)] on the same clock as spans [(a, b)]; only the
    subject's hitches count when `pid` is given. A hitch counts when it overlaps a moving span.
    Returns {moving_s, hitch_ms, ms_per_s, count, longest_ms, other_process}."""
    spans = [s for s in spans if s is not None and s[1] > s[0]]
    moving = sum(b - a for a, b in spans)
    mine = [h for h in hitches if pid is None or h[2] == pid]
    inside = [(s, d) for s, d, *_ in mine if any(s < b and s + d > a for a, b in spans)]
    total_ms = sum(d for _, d in inside) * 1000
    return {"moving_s": round(moving, 3), "hitch_ms": round(total_ms, 1),
            "ms_per_s": round(total_ms / moving, 2) if moving > 0 else None,
            "count": len(inside), "longest_ms": round(max([d for _, d in inside] or [0]) * 1000, 1),
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
    """samples: [{row_key: height}] in time order. Returns (changed rows, rows seen).
    changed: [{row, first, later}] for every row whose height later moved by > HEIGHT_TOLERANCE."""
    first, changed = {}, {}
    for sample in samples:
        for key, height in sample.items():
            if key not in first:
                first[key] = height
            elif abs(height - first[key]) > HEIGHT_TOLERANCE and key not in changed:
                changed[key] = {"row": key, "first": first[key], "later": height}
    return list(changed.values()), len(first)


def travel(y_start, y_after_down, y_after_up):
    """Table origin y (screen points) before the down gesture, after it, and after the up gesture.
    Returns {down, up, asymmetry} where asymmetry is |down - up| / down."""
    down = abs(y_after_down - y_start)
    up = abs(y_after_up - y_after_down)
    return {"down": round(down, 1), "up": round(up, 1),
            "asymmetry": round(abs(down - up) / down, 4) if down > 0 else None}


BUDGET = {"ms_per_s": 5.0, "height_changed": 0, "asymmetry": 0.02}


def verdict(hitch, changed, symmetry):
    """PASS only when every number exists and is inside budget; UNPROVEN when one is missing."""
    if hitch is None or hitch.get("ms_per_s") is None or symmetry is None or symmetry.get("asymmetry") is None \
            or changed is None:
        return "UNPROVEN"
    ok = hitch["ms_per_s"] <= BUDGET["ms_per_s"] and len(changed) <= BUDGET["height_changed"] \
        and symmetry["asymmetry"] <= BUDGET["asymmetry"]
    return "PASS" if ok else "FAIL"
