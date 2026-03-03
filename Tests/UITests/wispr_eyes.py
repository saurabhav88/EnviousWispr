"""wispr_eyes — thin visual verification wrapper for Sonnet agents.
Usage:  python3 -c "from wispr_eyes import *; connect(); see()"
        python3 -c "from wispr_eyes import *; connect(); tap('AI Polish')"
"""
import os, sys, subprocess, time
sys.path.insert(0, os.path.dirname(__file__))
from ui_helpers import (find_app_pid, get_ax_app, get_attr, set_attr, perform_action,
    find_element, find_all_elements, find_control_for_label, wait_for_condition,
    get_process_memory_mb, get_clipboard_text, validate_app_ready, element_frame,
    _iter_children_with_menubars)

_pid = None
_app = None
_NOISE = {"AXGroup","AXScrollArea","AXSplitGroup","AXLayoutArea","AXScrollBar"}
_SHORT = {"AXWindow":"window","AXButton":"btn","AXPopUpButton":"picker",
    "AXCheckBox":"toggle","AXTextField":"field","AXTextArea":"textarea",
    "AXImage":"img","AXHeading":"heading","AXOutline":"sidebar",
    "AXMenuItem":"menuitem","AXToolbar":"toolbar","AXTab":"tab"}
_MAX_LINES = 50

def _fuzzy(t, s): return bool(t and s and t.lower() in s.lower())

def _txt(el):
    for a in ("AXTitle","AXValue","AXDescription"):
        v = get_attr(el, a)
        if v and isinstance(v, str) and v.strip(): return v.strip()
    return ""

def _row_text(row, depth=0):
    if depth > 4: return ""
    t = _txt(row)
    if t: return t
    for k in (get_attr(row,"AXChildren") or []):
        t = _row_text(k, depth + 1)
        if t: return t
    return ""

def _ensure_connected():
    """Guard: abort with clear message if connect() hasn't been called."""
    if _app is None:
        print("ERROR: Not connected. Call connect() first.")
        raise SystemExit(1)

def _find_match(root, text, role_filter=None, exact=False, mx=10, dep=0):
    """Unified DFS find by text. Returns first match or None.
    exact=True: case-insensitive full match. exact=False: substring match.
    """
    if dep > mx: return None
    r = get_attr(root,"AXRole") or ""
    if role_filter is None or r == role_filter:
        t = _txt(root)
        if t:
            if exact and t.lower() == text.lower(): return root
            if not exact and _fuzzy(text, t): return root
    for c in _iter_children_with_menubars(root):
        f = _find_match(c, text, role_filter, exact, mx, dep+1)
        if f: return f
    return None

def _text_visible(text):
    """Walk AX tree, return True as soon as text is found (short-circuit)."""
    needle = text.lower()
    def _search(el, dep=0):
        if dep > 10: return False
        for a in ("AXTitle","AXValue","AXDescription"):
            v = get_attr(el, a)
            if v and isinstance(v, str) and needle in v.lower(): return True
        for c in (get_attr(el,"AXChildren") or []):
            if _search(c, dep+1): return True
        return False
    return _search(_app)

# ── Public API ───────────────────────────────────────────────────────
def connect(app="EnviousWispr"):
    """Find PID, create AX ref. Raises SystemExit(1) if app not found."""
    global _pid, _app
    pid = find_app_pid(app)
    if not pid:
        print(f"ERROR: {app} not running")
        raise SystemExit(1)
    _pid, _app = pid, get_ax_app(pid)
    print(f"Connected to {app} (PID {pid})")

def health():
    _ensure_connected()
    try:
        ready, msg = validate_app_ready(_pid)
        mem = get_process_memory_mb(_pid)
        print(f"Health: {'OK' if ready else 'FAIL'} | Memory: {f'{mem:.0f} MB' if mem else '?'} | {msg}")
        return {"status": "OK" if ready else "FAIL", "memory_mb": mem, "message": msg}
    except Exception as e: print(f"Health error: {e}"); return None

def see(scope=None):
    _ensure_connected()
    try:
        root = _app
        if scope:
            f = _find_match(root, scope)
            if f:
                root = f
            else:
                print(f"Scope '{scope}' not found")
        lines = []
        _walk(root, lines, 0)
        if len(lines) > _MAX_LINES:
            lines = lines[:_MAX_LINES] + ["... (truncated)"]
        print("\n".join(lines) if lines else "(empty tree)")
    except Exception as e: print(f"see error: {e}")

def _walk(el, out, d):
    if len(out) >= _MAX_LINES: return
    role = get_attr(el,"AXRole") or ""
    ind = "  " * d
    children = list(_iter_children_with_menubars(el))
    if role == "AXOutline":  # sidebar — compact inline
        sel = None
        rows = get_attr(el,"AXRows") or get_attr(el,"AXChildren") or []
        names = []
        for r in rows:
            if get_attr(r,"AXRole") != "AXRow": continue
            t = _row_text(r)
            if get_attr(r,"AXSelected"): sel = t
            if t: names.append(f"*{t}*" if t == sel else t)
        out.append(f'{ind}[sidebar] selected="{sel or "?"}"')
        if names:
            line = ind + "  "
            for i, n in enumerate(names):
                add = (", " if i else "") + n
                if len(line) + len(add) > 72:
                    out.append(line); line = ind + "  " + n
                else: line += add
            if line.strip(): out.append(line)
        return
    if role in _NOISE:
        for c in children:
            if len(out) >= _MAX_LINES: return
            _walk(c, out, d)
        return
    if role == "AXStaticText":
        t = get_attr(el,"AXValue") or get_attr(el,"AXTitle") or ""
        if t.strip(): out.append(f'{ind}"{t.strip()}"')
        return
    if role == "AXRow":
        t = _row_text(el)
        if t: out.append(f"{ind}- {t}")
        return
    s = _SHORT.get(role)
    if s:
        out.append(f"{ind}{_label(el, role, s)}")
    elif role == "AXApplication":
        out.append(f'{ind}[app "{get_attr(el,"AXTitle") or ""}"]')
        # Walk windows first, then menus — windows have the useful content
        windows = [c for c in children if (get_attr(c,"AXRole") or "") == "AXWindow"]
        rest = [c for c in children if (get_attr(c,"AXRole") or "") != "AXWindow"]
        for c in windows + rest:
            if len(out) >= _MAX_LINES: return
            _walk(c, out, d + 1)
        return
    elif role and role not in _NOISE:
        t = _txt(el)
        if t: out.append(f'{ind}[{role.replace("AX","").lower()}] "{t}"')
    for c in children:
        if len(out) >= _MAX_LINES: return
        _walk(c, out, d + 1)

def _label(el, role, s):
    title = get_attr(el,"AXTitle") or ""
    value = get_attr(el,"AXValue") or ""
    desc = get_attr(el,"AXDescription") or ""
    disp = title or desc
    if s == "window":
        fr = element_frame(el)
        sz = f" {int(fr['width'])}x{int(fr['height'])}" if fr else ""
        return f'[window "{disp}"{sz}]'
    if s == "picker":
        return f'[picker] = "{value}"' if value else "[picker]"
    if s == "toggle":
        lbl = f' "{disp}"' if disp else ""
        return f'[toggle{lbl}] {"ON" if str(value)=="1" else "OFF"}'
    if s in ("field","textarea"):
        is_secure = any(k in (disp or "").lower() for k in ("key","secret","password","token"))
        if is_secure:
            if not value:
                return f"[{s} (secure, empty)]"
            shown = value[:8] + "... (secure)" if len(value) > 8 else value + " (secure)"
            return f'[{s} = "{shown}"]'
        if value:
            shown = value[:30] + "..." if len(value) > 30 else value
            return f'[{s} = "{shown}"]'
        return f"[{s}]"
    if s == "heading":
        return f'[heading] "{disp}"' if disp else "[heading]"
    return f'[{s} "{disp}"]' if disp else f"[{s}]"

# Ordered: buttons/controls first, menu items last (they match too broadly via substring)
_ACTIONABLE = ("AXButton","AXPopUpButton","AXCheckBox","AXRadioButton","AXLink","AXRow","AXMenuItem")

def tap(text, role=None):
    _ensure_connected()
    try:
        # Prefer exact match, fall back to fuzzy.
        # When no role specified, try actionable elements in priority order
        # to avoid matching static text or menu items that contain the same words.
        if role:
            tgt = _find_match(_app, text, role, exact=True) or _find_match(_app, text, role)
        else:
            tgt = None
            # First pass: exact match on actionable roles
            for r in _ACTIONABLE:
                tgt = _find_match(_app, text, r, exact=True)
                if tgt: break
            # Second pass: fuzzy match on actionable roles
            if not tgt:
                for r in _ACTIONABLE:
                    tgt = _find_match(_app, text, r)
                    if tgt: break
            # Final fallback: any role
            if not tgt:
                tgt = _find_match(_app, text, None, exact=True) or _find_match(_app, text, None)
        if not tgt: print(f"tap: '{text}' not found"); return False
        r, t = get_attr(tgt,"AXRole") or "", _txt(tgt)
        ok = set_attr(tgt,"AXSelected",True) if r=="AXRow" else perform_action(tgt,"AXPress")
        print(f"tap({r}): '{t}' -> {'OK' if ok else 'FAILED'}"); return ok
    except Exception as e: print(f"tap error: {e}"); return False

def read(label):
    _ensure_connected()
    try:
        # Find label element once (avoids 4x repeated tree walks)
        label_el = find_element(_app, role="AXStaticText", value=label)
        if not label_el:
            label_el = find_element(_app, role="AXStaticText", title=label)
        if not label_el:
            print(f"{label} = (not found)"); return None

        lf = element_frame(label_el)
        if not lf:
            print(f"{label} = (no frame)"); return None
        lcx, lcy = lf["x"] + lf["width"]/2.0, lf["y"] + lf["height"]/2.0

        # Find nearest control on the same form row (Y-aligned).
        # In SwiftUI Form, labels sit far left and controls far right,
        # so X distance is large but Y should be within ~20px for same row.
        best, best_dist = None, 800.0
        for cr in ("AXPopUpButton","AXTextField","AXCheckBox","AXTextArea"):
            for cand in find_all_elements(_app, role=cr):
                cf = element_frame(cand)
                if not cf: continue
                dx = cf["x"] + cf["width"]/2.0 - lcx
                dy = cf["y"] + cf["height"]/2.0 - lcy
                if dx < -lf["width"] and dy < -lf["height"]: continue
                # Weight Y 10x to prefer same-row controls
                dist = (dx*dx + dy*dy * 100) ** 0.5
                if dist < best_dist:
                    best_dist, best = dist, cand

        if not best:
            print(f"{label} = (not found)"); return None
        r = get_attr(best,"AXRole") or ""
        v = get_attr(best,"AXValue") or ""
        if r == "AXCheckBox":
            v = "ON" if str(v) == "1" else "OFF"
        print(f"{label} = {v}"); return v
    except Exception as e: print(f"read error: {e}"); return None

def nav(tab):
    _ensure_connected()
    try:
        outline = find_element(_app, role="AXOutline")
        if not outline:
            w = find_element(_app, role="AXWindow")
            outline = find_element(w, role="AXOutline") if w else None
            if not outline: print("No sidebar found. Is Settings open?"); return False
        for row in (get_attr(outline,"AXRows") or get_attr(outline,"AXChildren") or []):
            if get_attr(row,"AXRole") != "AXRow": continue
            t = _row_text(row)
            if t and _fuzzy(tab, t):
                set_attr(row,"AXSelected",True); time.sleep(0.3)
                print(f"Navigated to {t}"); return True
        print(f"Tab '{tab}' not found in sidebar"); return False
    except Exception as e: print(f"nav error: {e}"); return False

def menu():
    _ensure_connected()
    try:
        bar = get_attr(_app,"AXExtrasMenuBar")
        if not bar: print("No extras menu bar"); return
        for c in (get_attr(bar,"AXChildren") or []):
            print(f"[menu] {get_attr(c,'AXTitle') or get_attr(c,'AXDescription') or '?'}")
    except Exception as e: print(f"menu error: {e}")

def type_text(text):
    _ensure_connected()
    try:
        import simulate_input as _si
        _si.type_text(text)
        print(f'Typed: "{text[:40]}{"..." if len(text)>40 else ""}"')
    except Exception as e: print(f"type_text error: {e}")

def press_key(key, cmd=False, shift=False, alt=False, ctrl=False):
    _ensure_connected()
    try:
        import simulate_input as _si
        _si.press_key(key, cmd=cmd, shift=shift, alt=alt, ctrl=ctrl)
        m = [n for n,f in [("Cmd",cmd),("Shift",shift),("Alt",alt),("Ctrl",ctrl)] if f]
        print(f"Pressed: {'+'.join(m)+'+' if m else ''}{key}")
    except Exception as e: print(f"press_key error: {e}")

def wait_for(text, timeout=3.0):
    _ensure_connected()
    try:
        ok = wait_for_condition(lambda: _text_visible(text),
            timeout=timeout, description=f"wait_for('{text}')")
        print(f"{'Found' if ok else 'Timeout'}: '{text}'" + (f" not found after {timeout}s" if not ok else ""))
        return ok
    except Exception as e: print(f"wait_for error: {e}"); return False

def clipboard():
    try:
        t = get_clipboard_text()
        if t is None: print("Clipboard: (empty)"); return None
        print(f"Clipboard: {t[:200]}{'...' if len(t)>200 else ''}"); return t
    except Exception as e: print(f"clipboard error: {e}"); return None

def _notify(msg):
    subprocess.run(["osascript","-e",f'display notification "{msg}" with title "wispr_eyes"'],
        timeout=5, capture_output=True)

def begin_test(label):
    try: _notify(f"UAT Active: {label}"); print(f"Test started: {label}")
    except Exception as e: print(f"begin_test error: {e}")

def end_test():
    try: _notify("UAT Complete"); print("Test ended")
    except Exception as e: print(f"end_test error: {e}")

def close_window():
    """Close the frontmost app window via AXCloseButton."""
    _ensure_connected()
    try:
        from ui_helpers import find_all_elements, perform_action
        for w in find_all_elements(_app, role="AXWindow"):
            btn = get_attr(w, "AXCloseButton")
            if btn:
                perform_action(btn, "AXPress")
                print("Window closed")
                return True
        print("No window to close")
        return False
    except Exception as e: print(f"close_window error: {e}"); return False

# ── High-Level Tasks (one call, no decisions) ─────────────────────────

def check(tab, *labels):
    """Navigate to a settings tab and read one or more label values.
    Usage: check('polish', 'Provider', 'Model')
    Returns dict of label→value."""
    connect()
    begin_test(f"check {tab}")
    if not nav(tab):
        end_test()
        close_window()
        return {}
    results = {}
    for label in labels:
        results[label] = read(label)
    end_test()
    close_window()
    return results

def look(tab=None):
    """Connect and show what's on screen. Optionally navigate to a tab first.
    Usage: look()  or  look('polish')"""
    connect()
    if tab:
        nav(tab)
    see()

def verify(tab, expectations):
    """Navigate to a tab and check expected values. Reports VERIFIED/ISSUE per item.
    Usage: verify('polish', {'Provider': 'OpenAI', 'Model': 'gpt-4o-mini'})
    Pass None as value to just read without checking."""
    connect()
    begin_test(f"verify {tab}")
    if not nav(tab):
        print(f"BLOCKED: Could not navigate to '{tab}'")
        end_test()
        close_window()
        return
    for label, expected in expectations.items():
        actual = read(label)
        if expected is None:
            print(f"INFO: {label} = {actual}")
        elif actual and expected.lower() in actual.lower():
            print(f"VERIFIED: {label} = {actual}")
        else:
            print(f"ISSUE: {label} expected '{expected}', got '{actual}'")
    end_test()
    close_window()
