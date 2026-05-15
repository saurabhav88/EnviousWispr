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
_INPUT_WARN = True  # Play chime before CGEvent input (click/type/key)
_TTS_PATH = "/tmp/wispr_eyes_tts.aiff"
_OPENAI_TTS_PATH = "/tmp/wispr_eyes_tts.mp3"
_OPENAI_KEY_FILE = os.path.expanduser("~/.enviouswispr-keys/openai-api-key")


def tts(sentence="The quick brown fox jumps over the lazy dog", voice="echo", engine="openai"):
    """Generate audio from text. engine='openai' (natural) or 'say' (local fallback). Returns file path."""
    if engine == "openai" and os.path.exists(_OPENAI_KEY_FILE):
        import urllib.request, json
        key = open(_OPENAI_KEY_FILE).read().strip()
        req = urllib.request.Request(
            "https://api.openai.com/v1/audio/speech",
            data=json.dumps({"model": "tts-1-hd", "input": sentence, "voice": voice}).encode(),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            with open(_OPENAI_TTS_PATH, "wb") as f:
                f.write(resp.read())
        print(f"TTS (openai/{voice}): \"{sentence}\" -> {_OPENAI_TTS_PATH}")
        return _OPENAI_TTS_PATH
    # Local fallback
    subprocess.run(["say", "-v", "Evan (Enhanced)", "-o", _TTS_PATH, sentence], check=True, timeout=10)
    print(f"TTS (say/Evan): \"{sentence}\" -> {_TTS_PATH}")
    return _TTS_PATH


def _audio_duration(path):
    """Get audio duration in seconds. Works with WAV, AIFF, and other formats."""
    try:
        import wave
        with wave.open(path, 'r') as w:
            return w.getnframes() / w.getframerate()
    except Exception:
        pass
    try:
        result = subprocess.run(["afinfo", path], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if "duration" in line.lower():
                return float(line.split()[-2])
    except Exception:
        pass
    return None

def _chime():
    """Play a short system sound to warn user that CGEvent input is about to happen."""
    if _INPUT_WARN:
        subprocess.Popen(["afplay", "/System/Library/Sounds/Tink.aiff"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

def _fuzzy_find_label(label):
    """Find an AXStaticText whose value or title contains *label* (case-insensitive).

    Strategy (in order):
    1. Exact match on AXValue or AXTitle (fast path via find_element)
    2. Fuzzy/substring match across all AXStaticText elements
    Returns the element or None.
    """
    # Fast path: exact match
    el = find_element(_app, role="AXStaticText", value=label)
    if el: return el
    el = find_element(_app, role="AXStaticText", title=label)
    if el: return el

    # Fuzzy path: substring match across all static text
    needle = label.lower()
    best, best_len = None, float("inf")
    for t in find_all_elements(_app, role="AXStaticText"):
        for attr in ("AXValue", "AXTitle"):
            v = get_attr(t, attr)
            if v and isinstance(v, str) and needle in v.lower():
                # Prefer shortest match (most specific)
                if len(v) < best_len:
                    best, best_len = t, len(v)
    return best


def _find_control_by_description(label):
    """Find a control whose AXDescription or AXTitle contains *label*.

    Handles SwiftUI toggles/pickers where the label lives on the control itself
    rather than in a separate AXStaticText element.
    Returns (control_element, value_string) or (None, None).
    """
    needle = label.lower()
    for role in ("AXCheckBox", "AXPopUpButton", "AXTextField", "AXTextArea"):
        for el in find_all_elements(_app, role=role):
            for attr in ("AXDescription", "AXTitle"):
                v = get_attr(el, attr)
                if v and isinstance(v, str) and needle in v.lower():
                    raw = get_attr(el, "AXValue") or ""
                    if role == "AXCheckBox":
                        return el, "ON" if str(raw) == "1" else "OFF"
                    return el, str(raw)
    return None, None


def read(label):
    _ensure_connected()
    try:
        # Strategy 1: Find a label AXStaticText, then locate the nearest control
        label_el = _fuzzy_find_label(label)
        if label_el:
            lf = element_frame(label_el)
            if lf:
                lcx, lcy = lf["x"] + lf["width"]/2.0, lf["y"] + lf["height"]/2.0
                best, best_dist = None, 800.0
                for cr in ("AXPopUpButton","AXTextField","AXCheckBox","AXTextArea"):
                    for cand in find_all_elements(_app, role=cr):
                        cf = element_frame(cand)
                        if not cf: continue
                        dx = cf["x"] + cf["width"]/2.0 - lcx
                        dy = cf["y"] + cf["height"]/2.0 - lcy
                        if dx < -lf["width"] and dy < -lf["height"]: continue
                        dist = (dx*dx + dy*dy * 100) ** 0.5
                        if dist < best_dist:
                            best_dist, best = dist, cand
                if best:
                    r = get_attr(best,"AXRole") or ""
                    v = get_attr(best,"AXValue") or ""
                    if r == "AXCheckBox":
                        v = "ON" if str(v) == "1" else "OFF"
                    print(f"{label} = {v}"); return v

        # Strategy 2: Label lives on the control itself (AXDescription/AXTitle)
        ctrl, val = _find_control_by_description(label)
        if ctrl:
            print(f"{label} = {val}"); return val

        print(f"{label} = (not found)"); return None
    except Exception as e: print(f"read error: {e}"); return None


_CARD_GROUPS = {
    "engine": ["Fast (English)", "Multi-Language"],
    "environment": ["Quiet", "Normal", "Noisy"],
    "style": ["Formal", "Standard", "Friendly"],
}

def read_cards(group):
    """Read which card is selected in a card group.

    Groups: 'engine', 'environment', 'style'.
    Returns dict of {card_name: selected_bool}.
    Usage: read_cards('engine')  read_cards('style')
    """
    _ensure_connected()
    try:
        keywords = _CARD_GROUPS.get(group)
        if not keywords:
            print(f"read_cards: unknown group '{group}', use: {list(_CARD_GROUPS)}")
            return {}
        results = {}
        for btn in find_all_elements(_app, role="AXButton"):
            fr = element_frame(btn)
            if not fr or fr["x"] < 200: continue
            title = get_attr(btn, "AXTitle") or get_attr(btn, "AXDescription") or ""
            if not title: continue
            # Match button to this group by keyword
            matched_kw = None
            for kw in keywords:
                if kw.lower() in title.lower():
                    matched_kw = kw
                    break
            if not matched_kw: continue
            val = get_attr(btn, "AXValue") or ""
            results[matched_kw] = str(val).lower() == "selected"
        if results:
            for name, sel in results.items():
                print(f"  {name}: {'SELECTED' if sel else '-'}")
        else:
            print(f"read_cards({group}): no cards found")
        return results
    except Exception as e: print(f"read_cards error: {e}"); return {}


def nav(tab):
    _ensure_connected()
    try:
        outline = find_element(_app, role="AXOutline")
        if not outline:
            w = find_element(_app, role="AXWindow")
            outline = find_element(w, role="AXOutline") if w else None
            if not outline:
                # Auto-open Settings and retry once
                settings_item = _find_match(_app, "Settings...", "AXMenuItem", exact=True)
                if settings_item:
                    perform_action(settings_item, "AXPress")
                    time.sleep(0.8)
                    print("Auto-opened Settings")
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
        _chime()
        _si.type_text(text)
        print(f'Typed: "{text[:40]}{"..." if len(text)>40 else ""}"')
    except Exception as e: print(f"type_text error: {e}")

def press_key(key, cmd=False, shift=False, alt=False, ctrl=False):
    _ensure_connected()
    try:
        import simulate_input as _si
        _chime()
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

# ── Screenshot + Zoom ────────────────────────────────────────────────

_SCREENSHOT_DIR = "/tmp/wispr_eyes"
_SCREENSHOT_COUNTER = [0]

def screenshot(save_path=None, window=True):
    """Take a screenshot of the app window (or full screen if window=False).

    Returns the file path. Uses native macOS screencapture.
    If save_path is None, auto-generates /tmp/wispr_eyes/shot_NNN.png.
    """
    import os
    os.makedirs(_SCREENSHOT_DIR, exist_ok=True)
    if save_path is None:
        _SCREENSHOT_COUNTER[0] += 1
        save_path = f"{_SCREENSHOT_DIR}/shot_{_SCREENSHOT_COUNTER[0]:03d}.png"

    cmd = ["screencapture", "-x"]  # -x = no sound
    if window and _pid:
        # Capture specific window by PID: use -l with window ID
        wid = _get_window_id()
        if wid:
            cmd.extend(["-l", str(wid)])
    cmd.append(save_path)
    subprocess.run(cmd, timeout=10, capture_output=True)
    if os.path.exists(save_path):
        sz = os.path.getsize(save_path)
        print(f"Screenshot: {save_path} ({sz // 1024} KB)")
    else:
        print(f"Screenshot FAILED: {save_path}")
    return save_path


def _get_window_id():
    """Get the CGWindowID for the app's frontmost window via Quartz."""
    try:
        from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
        windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
        for w in windows:
            if w.get("kCGWindowOwnerPID") == _pid:
                return w.get("kCGWindowNumber")
    except Exception:
        pass
    return None


def zoom(region, save_path=None):
    """Crop a region from the last screenshot for detail inspection.

    region: (x, y, width, height) in pixels relative to the screenshot image.
    Returns the cropped file path.
    Uses sips (no PIL dependency).
    """
    import os, glob
    os.makedirs(_SCREENSHOT_DIR, exist_ok=True)

    # Find the latest screenshot
    shots = sorted(glob.glob(f"{_SCREENSHOT_DIR}/shot_*.png"))
    if not shots:
        # Take one first
        src = screenshot()
    else:
        src = shots[-1]

    if save_path is None:
        _SCREENSHOT_COUNTER[0] += 1
        save_path = f"{_SCREENSHOT_DIR}/zoom_{_SCREENSHOT_COUNTER[0]:03d}.png"

    x, y, w, h = region
    # sips --cropToHeightWidth then --cropOffset
    # First copy the file, then crop in place
    subprocess.run(["cp", src, save_path], timeout=5)
    subprocess.run([
        "sips", "--cropToHeightWidth", str(int(h)), str(int(w)),
        "--cropOffset", str(int(y)), str(int(x)),
        save_path
    ], timeout=10, capture_output=True)

    if os.path.exists(save_path):
        print(f"Zoom: {save_path} (region {x},{y} {w}x{h})")
    else:
        print(f"Zoom FAILED")
    return save_path


# ── Scroll ───────────────────────────────────────────────────────────

def scroll(direction="down", amount=3, target=None):
    """Scroll within the app window.

    direction: 'up', 'down', 'left', 'right'
    amount: number of scroll ticks (1-100)
    target: optional label text to scroll near (finds element center)

    Usage: scroll('down', 5)
           scroll('up', 3, target='Diagnostics')
    """
    _ensure_connected()
    try:
        import simulate_input as _si

        # Determine scroll position
        x, y = None, None
        if target:
            el = _find_match(_app, target)
            if el:
                from ui_helpers import element_center
                center = element_center(el)
                if center:
                    x, y = center
                    print(f"Scrolling near '{target}' at ({x:.0f}, {y:.0f})")

        if x is None:
            # Default: center of the app's frontmost window
            w = find_element(_app, role="AXWindow")
            if w:
                from ui_helpers import element_center
                center = element_center(w)
                if center:
                    x, y = center

        dy, dx = 0, 0
        if direction == "down":
            dy = -amount
        elif direction == "up":
            dy = amount
        elif direction == "left":
            dx = amount
        elif direction == "right":
            dx = -amount

        _chime()
        _si.scroll(dx=dx, dy=dy, x=x, y=y)
        print(f"Scrolled {direction} x{amount}")
        return True
    except Exception as e:
        print(f"scroll error: {e}")
        return False


# ── Hold Key ─────────────────────────────────────────────────────────

def hold_key(key, duration=2.0, cmd=False, shift=False, alt=False, ctrl=False):
    """Press and hold a key for a duration, then release.

    Critical for PTT testing: hold_key('space', duration=3.0)
    Also works for modifier keys: hold_key('rcmd', duration=2.0)

    Args:
        key:      Key name (space, a, return, rcmd, lshift, etc.)
        duration: Seconds to hold (0-100)
        cmd/shift/alt/ctrl: Additional modifier flags
    """
    _ensure_connected()
    try:
        import simulate_input as _si
        _chime()
        _si.hold_key(key, duration=duration, cmd=cmd, shift=shift, alt=alt, ctrl=ctrl)
        m = [n for n, f in [("Cmd", cmd), ("Shift", shift), ("Alt", alt), ("Ctrl", ctrl)] if f]
        mod = '+'.join(m) + '+' if m else ''
        print(f"Held {mod}{key} for {duration:.1f}s")
        return True
    except Exception as e:
        print(f"hold_key error: {e}")
        return False


# ── Batch ────────────────────────────────────────────────────────────

def batch(actions):
    """Execute a sequence of wispr_eyes actions in one call, reducing round-trips.

    Each action is a tuple: (function_name, *args) or (function_name, *args, {kwargs}).
    Stops on first error if stop_on_error kwarg is True (default: False).

    Returns list of (action_name, result, elapsed_seconds).

    Usage:
        batch([
            ('nav', 'AI Polish'),
            ('read', 'Provider'),
            ('read', 'Model'),
            ('screenshot',),
            ('tap', 'Transcription'),
            ('read', 'Stop recording on silence'),
        ])

        # With screenshot between actions
        batch([
            ('nav', 'Diagnostics'),
            ('screenshot',),
            ('scroll', 'down', 5),
            ('screenshot',),
        ])
    """
    _ensure_connected()

    # Map action names to functions
    fn_map = {
        'connect': connect, 'see': see, 'tap': tap, 'read': read,
        'read_cards': read_cards, 'nav': nav, 'menu': menu,
        'type_text': type_text, 'press_key': press_key, 'wait_for': wait_for,
        'clipboard': clipboard, 'health': health, 'screenshot': screenshot,
        'zoom': zoom, 'scroll': scroll, 'hold_key': hold_key,
        'close_window': close_window, 'begin_test': begin_test, 'end_test': end_test,
        'record_tts': record_tts,
    }

    results = []
    for action in actions:
        if isinstance(action, str):
            action = (action,)

        name = action[0]
        args = []
        kwargs = {}

        for a in action[1:]:
            if isinstance(a, dict):
                kwargs = a
            else:
                args.append(a)

        fn = fn_map.get(name)
        if fn is None:
            print(f"batch: unknown action '{name}'")
            results.append((name, None, 0))
            continue

        t0 = time.time()
        try:
            result = fn(*args, **kwargs)
            elapsed = time.time() - t0
            results.append((name, result, elapsed))
        except Exception as e:
            elapsed = time.time() - t0
            print(f"batch: {name} error: {e}")
            results.append((name, None, elapsed))
            if kwargs.get('stop_on_error'):
                break

    total = sum(r[2] for r in results)
    print(f"\nbatch: {len(results)} actions in {total:.2f}s")
    return results


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

# ── AI Diagnostics ────────────────────────────────────────────────────

def check_ai_diagnostics():
    """Navigate to AI Polish and read the full AI diagnostics state.
    Returns dict with status, gates, and metadata. ONE call."""
    connect()
    begin_test("check ai_diagnostics")
    if not nav("AI Polish"):
        end_test()
        close_window()
        return {}

    result = {}

    # Read provider
    result["provider"] = read("Provider")

    # Read status — it's a static text near "Status:" label, not a control.
    # Find "Status:" label, then look for the adjacent text.
    try:
        status_label = _fuzzy_find_label("Status:")
        if status_label:
            sf = element_frame(status_label)
            if sf:
                # Status value is to the right of "Status:" on the same row
                scx = sf["x"] + sf["width"]
                scy = sf["y"] + sf["height"] / 2.0
                best_txt, best_dist = None, 500.0
                for el in find_all_elements(_app, role="AXStaticText"):
                    txt = _txt(el)
                    if not txt or txt == "Status:" or txt.startswith("On-device"):
                        continue
                    ef = element_frame(el)
                    if not ef:
                        continue
                    # Must be to the right and on roughly the same row
                    dx = ef["x"] - scx
                    dy = abs(ef["y"] + ef["height"] / 2.0 - scy)
                    if dx < -10 or dy > 20:
                        continue
                    dist = dx + dy * 10
                    if dist < best_dist:
                        best_dist, best_txt = dist, txt
                if best_txt:
                    result["status"] = best_txt
                    print(f"AI Status = {best_txt}")
    except Exception as e:
        print(f"status read error: {e}")

    # Expand the Diagnostics disclosure group if present
    try:
        disc = _find_match(_app, "Diagnostics", "AXDisclosureTriangle")
        if disc:
            val = get_attr(disc, "AXValue")
            if not val:  # collapsed (False or 0 or None)
                perform_action(disc, "AXPress")
                time.sleep(0.5)
                print("Expanded Diagnostics disclosure group")
            else:
                print("Diagnostics disclosure group already expanded")
        else:
            print("No Diagnostics disclosure group found (debug mode off?)")
    except Exception as e:
        print(f"disclosure toggle error: {e}")

    # Read gate results from the Diagnostics disclosure group
    gate_names = ["Build", "Runtime", "Eligibility", "Model Access", "Functional Probe"]
    gates = {}
    try:
        all_texts = find_all_elements(_app, role="AXStaticText")
        text_list = [(el, _txt(el), element_frame(el)) for el in all_texts]
        for gn in gate_names:
            for el, txt, frm in text_list:
                if txt == gn and frm:
                    # Find the summary text — next static text to the right on same row
                    gy = frm["y"] + frm["height"] / 2.0
                    gx = frm["x"] + frm["width"]
                    best_summary, best_d = "", 999
                    for _, t2, f2 in text_list:
                        if not t2 or not f2 or t2 == gn:
                            continue
                        dy = abs(f2["y"] + f2["height"] / 2.0 - gy)
                        dx = f2["x"] - gx
                        if dy > 15 or dx < -5:
                            continue
                        d = dx + dy * 10
                        if d < best_d:
                            best_d, best_summary = d, t2
                    gates[gn] = best_summary
                    break
        result["gates"] = gates
        for gn, summary in gates.items():
            print(f"  Gate {gn}: {summary}")
    except Exception as e:
        print(f"gate read error: {e}")

    # Check for Copy Diagnostics button
    copy_btn = _find_match(_app, "Copy Diagnostics", "AXButton")
    result["copy_diagnostics_button"] = copy_btn is not None
    print(f"Copy Diagnostics button: {'found' if copy_btn else 'missing'}")

    end_test()
    close_window()
    return result


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

def scan(toggle=False):
    """Full settings scan — reads every control on all 10 tabs in ONE call.

    If toggle=True, exercises each toggle (flip + verify + restore + verify).
    If toggle=False, reads current state only (faster).
    Usage: scan()  or  scan(toggle=True)
    """
    connect()
    begin_test("full-scan" + (" +toggle" if toggle else ""))
    t_total = time.time()

    # Tab manifest: (tab_name, toggles, pickers, card_groups, buttons_to_report)
    TABS = [
        ("History", [], [], [], []),  # skip button scan — 711 rows make it slow
        ("Transcription",
         ["Stop recording on silence", "Remove filler words"],
         [], ["engine", "environment"], []),
        ("Microphone", [], ["Input"], [], []),
        ("Shortcuts", [], [], [], []),
        ("AI Polish", ["Deep reasoning"], ["Provider", "Model"],
         ["style"], ["Save", "Clear", "Refresh", "Copy Diagnostics"]),
        ("Your Words", ["Enable custom words"], [], [], []),
        ("Clipboard",
         ["Auto-copy to clipboard", "Restore clipboard after paste"],
         [], [], []),
        ("Performance", [], ["Unload model after"], [], []),
        ("Permissions", [], [], [], []),
        ("Diagnostics", ["Enable debug mode"], [], [],
         ["Open Log Directory", "Copy Log Path", "Clear Logs",
          "Open Console.app", "Run ASR Benchmark", "Run Pipeline Benchmark"]),
    ]

    results = []
    for tab_name, toggles, pickers, cards, buttons in TABS:
        t0 = time.time()
        if not nav(tab_name):
            results.append((tab_name, "BLOCKED", time.time() - t0, []))
            continue
        details = []

        # Read pickers
        for p in pickers:
            v = read(p)
            details.append(f"picker:{p}={v}")

        # Read card groups
        for cg in cards:
            cr = read_cards(cg)
            sel = [k for k, v in cr.items() if v] if cr else []
            details.append(f"cards:{cg}={','.join(sel) if sel else 'none'}")

        # Toggles
        for tg in toggles:
            v = read(tg)
            if toggle and v is not None:
                tap(tg)
                time.sleep(0.3)
                v2 = read(tg)
                tap(tg)
                time.sleep(0.3)
                v3 = read(tg)
                ok = v == v3 and v != v2
                details.append(f"toggle:{tg}={v} cycle={'OK' if ok else 'FAIL'}")
            else:
                details.append(f"toggle:{tg}={v}")

        # Buttons (report existence)
        for b in buttons:
            found = _find_match(_app, b, "AXButton")
            details.append(f"btn:{b}={'found' if found else 'missing'}")

        elapsed = time.time() - t0
        results.append((tab_name, "OK", elapsed, details))

    total = time.time() - t_total
    close_window()
    end_test()

    # Print report
    print(f"\n{'='*60}")
    print(f"FULL SETTINGS SCAN {'(with toggle)' if toggle else '(read-only)'}")
    print(f"{'='*60}")
    for tab_name, status, elapsed, details in results:
        print(f"\n[{status}] {tab_name} ({elapsed:.2f}s)")
        for d in details:
            print(f"  {d}")
    print(f"\n{'='*60}")
    passed = sum(1 for _, s, _, _ in results if s == "OK")
    print(f"TOTAL: {passed}/{len(results)} tabs | {total:.2f}s")
    print(f"{'='*60}")
    return results


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


_APP_LOG_PATH = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")

# Both pipeline backends emit a completion line; only the prefix differs.
# Parakeet:   "Pipeline timing TOTAL: ..."
# WhisperKit: "WhisperKit pipeline TOTAL: ..."
_COMPLETION_MARKERS = ("Pipeline timing TOTAL", "WhisperKit pipeline TOTAL")


def _log_inode():
    """Return (inode, size) for app.log, or None if absent. Used to detect
    log rotation (inode change) and truncation (size shrinks below seek)."""
    try:
        st = os.stat(_APP_LOG_PATH)
        return (st.st_ino, st.st_size)
    except OSError:
        return None


def _snapshot_log_state():
    """Capture the pre-test state of app.log: (inode, size, mtime).
    Returns None if the file doesn't exist. The mtime is used later to
    detect a stale app.log left behind by an earlier debug run."""
    try:
        st = os.stat(_APP_LOG_PATH)
        return (st.st_ino, st.st_size, st.st_mtime)
    except OSError:
        return None


def _read_new_log_lines(log_state):
    """Yield new lines from app.log since the captured snapshot.
    Handles rotation (inode change → start from byte 0 of the new file) and
    truncation (size shrinks → start from byte 0). Returns the updated
    (inode, size) so the caller can advance its cursor. Silently no-op if
    the file is missing during a rotation race."""
    if log_state is None:
        return [], log_state
    try:
        st = os.stat(_APP_LOG_PATH)
    except OSError:
        return [], log_state
    inode, size, _ = log_state
    if st.st_ino != inode or st.st_size < size:
        # Rotation or truncation: read the new file from the start.
        seek_to = 0
    else:
        seek_to = size
    try:
        with open(_APP_LOG_PATH, "r") as f:
            f.seek(seek_to)
            new_lines = f.readlines()
    except OSError:
        return [], log_state
    return new_lines, (st.st_ino, st.st_size, st.st_mtime)


def _snapshot_log_size():
    """Compatibility shim — returns (inode, size, mtime) tuple or None.
    Callers should treat None as 'Debug mode off, fall back to clipboard'."""
    return _snapshot_log_state()


def _wait_for_pipeline_completion(log_state_before, clip_before, timeout):
    """Block until the pipeline emits a completion marker in app.log, or
    timeout. Handles rotation/truncation mid-test. Falls back to clipboard
    polling if app.log isn't actually growing (Debug mode off but a stale
    file exists from a previous session). Captures the transient clipboard
    value AT detection time so a 'restore clipboard after paste' cycle
    doesn't wipe it before extract.

    Returns: (completed, signal, completion_line, states_seen, clip_seen, lines_accumulated)
        signal in {"log", "clipboard", None}
        clip_seen: the clipboard value at the moment we detected change, or None
        lines_accumulated: all log lines observed during the loop (preserves
            content across mid-test rotation)
    """
    states_seen = []
    t_stop = time.time()
    completion_line = None
    signal = None
    clip_seen = None
    lines_accumulated = []

    log_state = log_state_before
    log_has_grown = False
    log_stale_warned = False

    mode = "log" if log_state is not None else "clipboard fallback — enable Debug mode in Settings -> Diagnostics"
    print(f"Watching pipeline ({mode})...")

    while time.time() - t_stop < timeout:
        for label in ("Transcribing", "Loading model", "Polishing", "Starting"):
            if _text_visible(label) and label not in states_seen:
                states_seen.append(label)
                print(f"  [{time.time() - t_stop:.1f}s] {label}...")

        # Log path: read any new lines, accumulate them so extraction has them
        # even if rotation later wipes the file.
        if log_state is not None:
            new_lines, log_state = _read_new_log_lines(log_state)
            if new_lines:
                log_has_grown = True
                lines_accumulated.extend(new_lines)
                for line in new_lines:
                    if any(m in line for m in _COMPLETION_MARKERS):
                        completion_line = line.strip()
                        signal = "log"
                        break
                if signal == "log":
                    print(f"  [{time.time() - t_stop:.1f}s] Pipeline complete (log)")
                    break

            # Stale-log fallback: a pre-existing app.log from a prior debug
            # session can sit on disk while Debug mode is off. After 1.5s
            # with no growth, arm clipboard polling — independent of state
            # labels, because a fast pipeline can finish before AX state
            # reads catch a label.
            if (
                not log_has_grown
                and (time.time() - t_stop) > 1.5
                and not log_stale_warned
            ):
                print(f"  [{time.time() - t_stop:.1f}s] app.log not growing — falling back to clipboard. Toggle Debug mode in Settings -> Diagnostics to fix.")
                log_stale_warned = True

        # Clipboard path: primary when no log file at all; fallback when log
        # exists but isn't being written to.
        if log_state is None or log_stale_warned:
            clip_now = get_clipboard_text() or ""
            if clip_now != clip_before:
                signal = "clipboard"
                clip_seen = clip_now  # capture before restore-after-paste reverts
                print(f"  [{time.time() - t_stop:.1f}s] Clipboard updated!")
                break

        time.sleep(0.2)
    else:
        print(f"  [{time.time() - t_stop:.1f}s] TIMEOUT — pipeline did not complete")

    return (signal is not None, signal, completion_line, states_seen, clip_seen, lines_accumulated)


def _extract_transcript_text(signal, log_state_before, clip_seen=None, lines_accumulated=None):
    """Extract the dictated text. For log-mode: prefer the lines we already
    captured during the polling loop (rotation-proof); only re-read app.log
    if we have no accumulated buffer. For clipboard-mode: prefer clip_seen
    captured at detection time (restore-after-paste may have reverted)."""
    if signal == "log":
        scan_lines = lines_accumulated
        if not scan_lines and log_state_before is not None:
            scan_lines, _ = _read_new_log_lines(log_state_before)
        raw_asr = None
        polished = None
        for line in (scan_lines or []):
            if "CORRECTION_DEBUG [RAW ASR]" in line:
                raw_asr = line.split("CORRECTION_DEBUG [RAW ASR]", 1)[1].strip()
            elif "CORRECTION_DEBUG [LLM Polish] OUT:" in line:
                polished = line.split("CORRECTION_DEBUG [LLM Polish] OUT:", 1)[1].strip()
        return polished or raw_asr
    if signal == "clipboard":
        if clip_seen is not None:
            return clip_seen.strip()
        return (get_clipboard_text() or "").strip()
    return None


# Settings UI labels for the two ASR engines. Source of truth for switch_backend.
# Updated when the buttons in Settings -> Transcription change copy.
_BACKEND_LABELS = {
    "parakeet": "Fast (English)",
    "whisperkit": "Multi-Language",
}


def switch_backend(name, wait=3.0):
    """Switch the active ASR engine via the Settings UI.

    Args:
        name: "parakeet" or "whisperkit".
        wait: seconds to let the model load after switching.

    Settings -> Transcription has two buttons:
        Fast (English)   -> Parakeet (PR #720-era label)
        Multi-Language   -> WhisperKit

    Usage:
        switch_backend("whisperkit")
        test_recording(sentence="...")  # now runs on WhisperKit
    """
    if name not in _BACKEND_LABELS:
        raise ValueError(f"Unknown backend '{name}'. Use one of: {list(_BACKEND_LABELS)}")
    connect()
    nav("Transcription")
    time.sleep(0.3)
    label = _BACKEND_LABELS[name]
    if not tap(label):
        raise RuntimeError(f"Could not tap '{label}' button in Settings -> Transcription")
    print(f"Switched backend to {name} ({label}); waiting {wait:.0f}s for model load...")
    time.sleep(wait)
    return True


def test_recording(audio=None, sentence=None, hold=3.0, expect=None, timeout=30.0):
    """End-to-end recording test: menu start -> TTS/audio playback -> menu stop -> verify pipeline.

    Args:
        audio:    Path to audio file to play through speakers (or None to use TTS).
        sentence: Text to speak via TTS. Ignored if audio is provided. Defaults to a standard sentence.
        hold:     Seconds to record. Auto-calculated from audio duration + buffer.
        expect:   Optional substring expected in the transcription result.
                  If sentence is used and expect is None, auto-derived from the sentence.
        timeout:  Max seconds to wait for pipeline completion after stop.

    Usage:
        test_recording()                                          # TTS default sentence
        test_recording(sentence="Ask Saurabh about EnviousWispr") # custom TTS
        test_recording(sentence="Check the EnviousWispr app", expect="EnviousWispr")
        test_recording(audio='/path/to/clip.wav', expect='keyword')  # explicit audio file
    """
    connect()

    # Generate TTS audio if no explicit audio file provided
    if audio is None:
        if sentence is None:
            sentence = "The quick brown fox jumps over the lazy dog"
        audio = tts(sentence)
        if expect is None:
            expect = "fox" if "fox" in sentence.lower() else sentence.split()[len(sentence.split())//2].lower()

    begin_test(f"recording{' +audio' if audio else ''}")

    # Close Settings if open
    close_window()

    # Get audio duration
    if audio:
        audio_dur = _audio_duration(audio)
        if audio_dur:
            hold = audio_dur + 1.5
            print(f"Audio: {audio} ({audio_dur:.1f}s)")
        else:
            print(f"Audio: {audio} (duration unknown, using hold={hold}s)")

    # Snapshot app.log size + clipboard before the test. Log-based detection
    # is primary (clipboard-free, doesn't race with the user's activity);
    # clipboard is a fallback when Debug mode is off.
    log_size_before = _snapshot_log_size()
    clip_before = get_clipboard_text() or ""

    # Phase 1: Start recording via menu
    print(f"\n--- START RECORDING ---")
    if not tap("Start Recording"):
        print("BLOCKED: Could not tap 'Start Recording'")
        end_test()
        return False
    time.sleep(0.5)

    # Check overlay appeared
    overlay_win = find_element(_app, role="AXWindow")
    print(f"Overlay: {'appeared' if overlay_win else 'not detected'}")

    # Phase 2: Play audio if provided
    audio_proc = None
    if audio:
        print(f"Playing audio through speakers...")
        audio_proc = subprocess.Popen(
            ["afplay", audio],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

    # Record for duration
    remaining = hold - 0.5
    if remaining > 0:
        print(f"Recording for {remaining:.1f}s...")
        time.sleep(remaining)

    # Kill audio if still playing
    if audio_proc and audio_proc.poll() is None:
        audio_proc.terminate()

    # Phase 3: Stop recording via menu
    print(f"\n--- STOP RECORDING ---")
    tap("Stop Recording")

    # Phase 4: Wait for completion (log-based with clipboard fallback)
    t_stop = time.time()
    completed, signal, completion_line, states_seen, clip_seen, log_lines = _wait_for_pipeline_completion(
        log_size_before, clip_before, timeout
    )
    pipeline_time = time.time() - t_stop

    # Phase 5: Report
    print(f"\n{'='*60}")
    print(f"RECORDING TEST RESULTS")
    print(f"{'='*60}")
    print(f"Audio:          {audio or '(silence)'}")
    print(f"Record time:    {hold:.1f}s")
    print(f"States seen:    {' → '.join(states_seen) if states_seen else '(none detected)'}")
    print(f"Pipeline time:  {pipeline_time:.1f}s")
    if completion_line:
        print(f"Log line:       {completion_line}")

    result_text = _extract_transcript_text(signal, log_size_before, clip_seen, log_lines)
    overall_pass = _report_result(completed, audio, expect, result_text)
    print(f"{'='*60}")
    end_test()
    return overall_pass


def _report_result(completed, audio, expect, result_text):
    """Print Transcription / Content check / Result lines and return the
    overall pass/fail. When expect is given, missing or mismatched content
    is FAIL even if the pipeline reported completion — otherwise rotation
    or other gaps could let a broken transcription ship as PASS."""
    if not completed:
        print(f"Transcription:  (pipeline did not complete)")
        if not audio:
            print(f"Result:         EXPECTED (silence)")
            return True
        print(f"Result:         FAIL")
        return False
    if result_text:
        print(f"Transcription:  \"{result_text[:200]}{'...' if len(result_text)>200 else ''}\"")
        if expect:
            if expect.lower() in result_text.lower():
                print(f"Content check:  PASS (found '{expect}')")
                print(f"Result:         PASS")
                return True
            else:
                print(f"Content check:  FAIL (expected '{expect}' not found)")
                print(f"Result:         FAIL")
                return False
        print(f"Result:         PASS")
        return True
    # Completed but no content captured (rotation, debug-off, etc).
    if expect:
        print(f"Transcription:  (content not captured — cannot verify expect='{expect}')")
        print(f"Result:         FAIL (content unverifiable)")
        return False
    print(f"Transcription:  (completion confirmed, content not captured)")
    print(f"Result:         PASS")
    return True


def test_cancel(hold=2.0):
    """Test cancel recording: start → Escape → verify recording stops cleanly.

    Usage: test_cancel()
    """
    connect()
    begin_test("cancel-recording")
    close_window()

    clip_before = get_clipboard_text() or ""

    # Start recording
    print("\n--- START RECORDING ---")
    if not tap("Start Recording"):
        print("BLOCKED: Could not tap 'Start Recording'")
        end_test()
        return False

    time.sleep(hold)

    # Cancel via Escape key (menu item doesn't exist for cancel)
    print("--- CANCEL (Escape) ---")
    import simulate_input as si
    _chime()
    si.press_key("escape")
    time.sleep(1.0)

    # Verify: no overlay, no clipboard change, menu shows "Start Recording" again
    start_item = _find_match(_app, "Start Recording", "AXMenuItem")
    clip_after = get_clipboard_text() or ""

    menu_ok = start_item is not None
    clip_ok = clip_after == clip_before

    print(f"\n{'='*60}")
    print(f"CANCEL TEST RESULTS")
    print(f"{'='*60}")
    print(f"Menu restored:  {'PASS' if menu_ok else 'FAIL'} ({'Start Recording' if menu_ok else 'still Stop Recording'})")
    print(f"Clipboard:      {'PASS (unchanged)' if clip_ok else 'FAIL (changed unexpectedly)'}")
    print(f"Result:         {'PASS' if menu_ok and clip_ok else 'FAIL'}")
    print(f"{'='*60}")
    end_test()
    return menu_ok and clip_ok


def test_hands_free(audio=None, sentence=None, hold=4.0, expect=None, timeout=30.0):
    """Test hands-free (persistent) recording mode via menu items.

    Menu-based recording IS hands-free: tap Start Recording -> recording persists
    until Stop Recording is tapped. This test verifies that flow works and that
    recording stays active over time (not auto-stopping).

    Args:
        audio:    Path to audio file to play during recording (or None to use TTS).
        sentence: Text to speak via TTS. Ignored if audio is provided.
        hold:     Seconds to record. Auto-calculated from audio duration + buffer.
        expect:   Optional substring expected in the transcription result.
        timeout:  Max seconds to wait for pipeline completion after stop.

    Usage:
        test_hands_free()
        test_hands_free(sentence="Ask Saurabh about EnviousWispr", expect="Saurabh")
    """
    connect()

    # Generate TTS audio if no explicit audio file provided
    if audio is None:
        if sentence is None:
            sentence = "The quick brown fox jumps over the lazy dog"
        audio = tts(sentence)
        if expect is None:
            expect = "fox" if "fox" in sentence.lower() else sentence.split()[len(sentence.split())//2].lower()

    begin_test(f"hands-free{' +audio' if audio else ''}")
    close_window()

    # Get audio duration
    if audio:
        audio_dur = _audio_duration(audio)
        if audio_dur:
            hold = audio_dur + 1.5
            print(f"Audio: {audio} ({audio_dur:.1f}s)")
        else:
            print(f"Audio: {audio} (duration unknown, using hold={hold}s)")

    log_size_before = _snapshot_log_size()
    clip_before = get_clipboard_text() or ""

    # Phase 1: Start recording via menu
    print(f"\n--- START RECORDING (hands-free) ---")
    if not tap("Start Recording"):
        print("BLOCKED: Could not tap 'Start Recording'")
        end_test()
        return False

    # Wait for recording to engage — menu should flip to "Stop Recording"
    t_start = time.time()
    recording_started = False
    for _ in range(10):
        time.sleep(0.3)
        if _find_match(_app, "Stop Recording", "AXMenuItem"):
            recording_started = True
            break
    start_latency = time.time() - t_start
    print(f"Recording started: {'YES' if recording_started else 'NO'} ({start_latency:.1f}s)")

    if not recording_started:
        print("BLOCKED: Recording did not start (menu never showed 'Stop Recording')")
        end_test()
        return False

    # Phase 2: Play audio if provided
    audio_proc = None
    if audio:
        print(f"Playing audio through speakers...")
        audio_proc = subprocess.Popen(
            ["afplay", audio],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

    # Phase 3: Let it record, with mid-recording check
    mid_check_at = min(hold / 2, 2.0)
    time.sleep(mid_check_at)

    # Mid-recording check: verify STILL recording (the hands-free test)
    still_recording_mid = _find_match(_app, "Stop Recording", "AXMenuItem") is not None
    print(f"Still recording at {mid_check_at:.1f}s: {'YES' if still_recording_mid else 'NO'}")

    remaining = hold - mid_check_at - start_latency
    if remaining > 0:
        time.sleep(remaining)

    # Final pre-stop check
    still_recording_end = _find_match(_app, "Stop Recording", "AXMenuItem") is not None
    print(f"Still recording at {hold:.1f}s: {'YES' if still_recording_end else 'NO'}")

    if audio_proc and audio_proc.poll() is None:
        audio_proc.terminate()

    # Phase 4: Stop recording via menu
    print(f"\n--- STOP RECORDING ---")
    tap("Stop Recording")

    # Phase 5: Wait for completion (log-based with clipboard fallback)
    t_stop = time.time()
    completed, signal, completion_line, states_seen, clip_seen, log_lines = _wait_for_pipeline_completion(
        log_size_before, clip_before, timeout
    )
    pipeline_time = time.time() - t_stop

    # Phase 6: Report
    print(f"\n{'='*60}")
    print(f"HANDS-FREE RECORDING TEST RESULTS")
    print(f"{'='*60}")
    print(f"Audio:          {audio or '(silence)'}")
    print(f"Started:        {'YES' if recording_started else 'NO'} ({start_latency:.1f}s)")
    print(f"Stayed active:  {'YES' if still_recording_mid and still_recording_end else 'NO'}")
    print(f"Record time:    {hold:.1f}s")
    print(f"States seen:    {' → '.join(states_seen) if states_seen else '(none detected)'}")
    print(f"Pipeline time:  {pipeline_time:.1f}s")
    if completion_line:
        print(f"Log line:       {completion_line}")

    result_text = _extract_transcript_text(signal, log_size_before, clip_seen, log_lines)
    overall_pass = _report_result(completed, audio, expect, result_text)
    print(f"{'='*60}")
    end_test()
    return overall_pass


def test_ptt(key="rcmd", audio=None, sentence=None, expect=None, timeout=10.0):
    """End-to-end PTT (push-to-talk) recording test via key hold.

    Precisely times key hold to match audio duration:
    1. Press key down (recording starts)
    2. Wait for recording to engage
    3. Play audio through speakers
    4. Wait for audio to finish + buffer
    5. Release key (recording stops, pipeline runs)
    6. Monitor pipeline via state polling + clipboard delta

    Args:
        key:      Key to hold (default 'rcmd'). Any key in simulate_input.MODIFIER_KEYS
                  or KEY_CODES (e.g. 'rcmd', 'space', 'f5').
        audio:    Path to audio file to play (or None to use TTS).
        sentence: Text to speak via TTS. Ignored if audio is provided.
        expect:   Optional substring expected in transcription.
        timeout:  Max seconds to wait for pipeline completion.

    Usage:
        test_ptt()                                    # default: rcmd + TTS fox sentence
        test_ptt(key='space')                         # space bar PTT
        test_ptt(sentence='Hello EnviousWispr')       # custom sentence
        test_ptt(audio='/path/to/clip.wav', expect='keyword')
    """
    connect()

    if audio is None:
        if sentence is None:
            sentence = "The quick brown fox jumps over the lazy dog"
        audio = tts(sentence)
        if expect is None:
            expect = "fox" if "fox" in sentence.lower() else sentence.split()[len(sentence.split()) // 2].lower()

    begin_test(f"ptt-{key}")
    close_window()

    # Get audio duration
    audio_dur = _audio_duration(audio) or 3.0
    print(f"Audio: {audio} ({audio_dur:.2f}s)")

    log_size_before = _snapshot_log_size()
    clip_before = get_clipboard_text() or ""

    # Phase 1: Key down (recording starts)
    import simulate_input as _si
    print(f"\n--- KEY DOWN ({key}) ---")
    _chime()

    key_lower = key.lower()
    if key_lower in _si.MODIFIER_KEYS:
        _si.modifier_down(_si.MODIFIER_KEYS[key_lower])
    elif key_lower in _si.KEY_CODES:
        from Quartz import CGEventCreateKeyboardEvent, CGEventPost, kCGHIDEventTap
        kc = _si.KEY_CODES[key_lower]
        down = CGEventCreateKeyboardEvent(None, kc, True)
        CGEventPost(kCGHIDEventTap, down)
    else:
        print(f"BLOCKED: Unknown key '{key}'")
        end_test()
        return False

    time.sleep(0.8)  # let recording engage + model warm

    # Phase 2: Play audio
    print(f"Playing audio ({audio_dur:.2f}s)...")
    audio_proc = subprocess.Popen(
        ["afplay", audio], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    # Phase 3: Wait for audio + buffer
    hold_audio = audio_dur + 0.8
    time.sleep(hold_audio)
    if audio_proc.poll() is None:
        audio_proc.terminate()

    # Phase 4: Key up (recording stops)
    total_hold = 0.8 + hold_audio
    print(f"\n--- KEY UP ({key}) after {total_hold:.1f}s hold ---")
    if key_lower in _si.MODIFIER_KEYS:
        _si.modifier_up(_si.MODIFIER_KEYS[key_lower])
    else:
        from Quartz import CGEventCreateKeyboardEvent, CGEventPost, kCGHIDEventTap
        kc = _si.KEY_CODES[key_lower]
        up = CGEventCreateKeyboardEvent(None, kc, False)
        CGEventPost(kCGHIDEventTap, up)

    # Phase 5: Wait for completion (log-based with clipboard fallback)
    t_stop = time.time()
    completed, signal, completion_line, states_seen, clip_seen, log_lines = _wait_for_pipeline_completion(
        log_size_before, clip_before, timeout
    )
    pipeline_time = time.time() - t_stop
    transcription = _extract_transcript_text(signal, log_size_before, clip_seen, log_lines)

    # Phase 6: Report
    print(f"\n{'=' * 60}")
    print(f"PTT HOLD TEST RESULTS ({key})")
    print(f"{'=' * 60}")
    print(f"Sentence:       {sentence or '(audio file)'}")
    print(f"Audio:          {audio} ({audio_dur:.2f}s)")
    print(f"Hold duration:  {total_hold:.1f}s")
    print(f"States seen:    {' -> '.join(states_seen) if states_seen else '(none)'}")
    print(f"Pipeline time:  {pipeline_time:.1f}s")
    if completion_line:
        print(f"Log line:       {completion_line}")

    # PTT always uses audio (we played a file), so non-completion is FAIL
    # regardless of "audio was empty" semantics.
    overall_pass = _report_result(completed, audio, expect, transcription)
    print(f"{'=' * 60}")
    end_test()
    return overall_pass


def record_tts(sentence="The quick brown fox jumps over the lazy dog", key="rcmd",
               voice="echo", wait=10.0, focus_app=None):
    """Generate TTS, hold PTT key, read raw ASR and polished output from app log.

    This is the go-to method for testing transcription quality and polish behavior.
    Does NOT rely on clipboard capture (which can be unreliable). Instead reads the
    CORRECTION_DEBUG lines from the app log for exact raw/polished comparison.

    Args:
        sentence: Text to speak via TTS.
        key:      PTT key to hold (default 'rcmd' = right command).
        voice:    OpenAI TTS voice (echo, alloy, fable, onyx, nova, shimmer).
        wait:     Seconds to wait after key release for pipeline to complete.
        focus_app: App to focus before recording (paste target). None to skip.

    Returns:
        dict with keys: raw_asr, polished, word_correction, filler_removal,
        pipeline_total, asr_time, polish_time, provider, success.

    Usage:
        record_tts()
        record_tts("Is there any hardware cost to keep the harness")
        record_tts("Deploy envious whisper now", voice="nova")

        # Batch test
        for s in ["sentence one", "sentence two"]:
            r = record_tts(s)
            print(f"  RAW: {r['raw_asr']}")
            print(f"  OUT: {r['polished']}")
    """
    import simulate_input as _si

    # Focus paste target app
    if focus_app:
        subprocess.Popen(["open", "-a", focus_app],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)

    # Generate TTS
    audio_path = tts(sentence, voice=voice)

    # Get audio duration
    audio_dur = _audio_duration(audio_path) or 3.0

    # Mark log position before recording
    log_size_before = 0
    if os.path.exists(_APP_LOG_PATH):
        log_size_before = os.path.getsize(_APP_LOG_PATH)

    # Hold PTT key + play audio concurrently
    import threading
    def _play():
        time.sleep(0.3)  # let key press register first
        subprocess.run(["afplay", audio_path],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    player = threading.Thread(target=_play)
    player.start()
    hold_dur = audio_dur + 1.0
    print(f"Holding {key} for {hold_dur:.1f}s (audio {audio_dur:.1f}s)...")
    _si.hold_key(key, duration=hold_dur)
    player.join()

    # Wait for pipeline (ASR + polish + paste)
    print(f"Waiting {wait:.0f}s for pipeline...")
    time.sleep(wait)

    # Read new log lines
    result = {
        "sentence": sentence,
        "raw_asr": None,
        "polished": None,
        "word_correction": None,
        "filler_removal": None,
        "pipeline_total": None,
        "asr_time": None,
        "polish_time": None,
        "provider": None,
        "success": False,
    }

    if not os.path.exists(_APP_LOG_PATH):
        print("ERROR: app log not found")
        return result

    with open(_APP_LOG_PATH, "r") as f:
        f.seek(log_size_before)
        new_lines = f.readlines()

    for line in new_lines:
        if "CORRECTION_DEBUG [RAW ASR]" in line:
            result["raw_asr"] = line.split("CORRECTION_DEBUG [RAW ASR]", 1)[1].strip()
        elif "CORRECTION_DEBUG [LLM Polish] OUT:" in line:
            result["polished"] = line.split("CORRECTION_DEBUG [LLM Polish] OUT:", 1)[1].strip()
        elif "CORRECTION_DEBUG [Word Correction]" in line:
            result["word_correction"] = line.split("CORRECTION_DEBUG [Word Correction]", 1)[1].strip()
        elif "CORRECTION_DEBUG [Filler Removal]" in line:
            result["filler_removal"] = line.split("CORRECTION_DEBUG [Filler Removal]", 1)[1].strip()
        elif "Pipeline timing TOTAL:" in line:
            result["pipeline_total"] = line.split("Pipeline timing TOTAL:", 1)[1].strip()
        elif "ASR completed in" in line:
            result["asr_time"] = line.split("ASR completed in", 1)[1].strip()
        elif "LLM polish complete:" in line:
            result["polish_time"] = line.split("LLM polish complete:", 1)[1].strip()
            # Extract provider
            if "provider=" in line:
                result["provider"] = line.split("provider=")[1].split(",")[0].split(")")[0]

    result["success"] = result["raw_asr"] is not None

    # Print summary
    print(f"\n{'=' * 60}")
    print(f"RECORD_TTS RESULTS")
    print(f"{'=' * 60}")
    print(f"Sentence:    {sentence}")
    print(f"RAW ASR:     {result['raw_asr'] or '(not captured)'}")
    print(f"Polished:    {result['polished'] or '(no polish or same as raw)'}")
    print(f"Provider:    {result['provider'] or '(none)'}")
    print(f"Pipeline:    {result['pipeline_total'] or '(not captured)'}")
    if result["word_correction"] and result["word_correction"] != "no change":
        print(f"WordFix:     {result['word_correction']}")
    if result["filler_removal"] and result["filler_removal"] != "no change":
        print(f"Filler:      {result['filler_removal']}")
    print(f"Result:      {'OK' if result['success'] else 'FAIL'}")
    print(f"{'=' * 60}")

    return result


def test_all(audio=None, sentence=None):
    """Full regression suite: settings scan + cancel test + recording E2E.

    Use for pre-release verification. For debugging specific features,
    use check(), verify(), scan(), or test_recording() directly.

    Audio is generated via TTS by default. Pass explicit audio/sentence to override.

    Args:
        audio:    Path to audio file for E2E test (or None to use TTS).
        sentence: Text to speak via TTS for E2E tests. Defaults to standard sentence.

    Usage: test_all()
           test_all(sentence="Check the EnviousWispr integration")
    """
    t_total = time.time()
    results = {}

    # 1. Settings scan with toggle cycling
    print("\n" + "="*60)
    print("PHASE 1: SETTINGS SCAN")
    print("="*60)
    scan_results = scan(toggle=True)
    scan_pass = all(s == "OK" for _, s, _, _ in scan_results)
    results["settings"] = scan_pass

    # 2. Cancel recording test
    print("\n" + "="*60)
    print("PHASE 2: CANCEL RECORDING")
    print("="*60)
    results["cancel"] = test_cancel()

    # 3. Hands-free recording test (TTS by default)
    print("\n" + "="*60)
    print("PHASE 3: HANDS-FREE RECORDING")
    print("="*60)
    results["hands_free"] = test_hands_free(audio=audio, sentence=sentence)

    # 4. E2E recording test (single-tap, TTS by default)
    print("\n" + "="*60)
    print("PHASE 4: E2E RECORDING")
    print("="*60)
    results["recording"] = test_recording(audio=audio, sentence=sentence)

    # Final report
    total = time.time() - t_total
    print(f"\n{'='*60}")
    print(f"FULL REGRESSION RESULTS")
    print(f"{'='*60}")
    for name, passed in results.items():
        if passed is None:
            print(f"  {name:15s}  SKIPPED")
        else:
            print(f"  {name:15s}  {'PASS' if passed else 'FAIL'}")
    all_pass = all(v is not False for v in results.values())
    print(f"\n  Overall:        {'ALL PASS' if all_pass else 'FAILURES DETECTED'}")
    print(f"  Total time:     {total:.1f}s")
    print(f"{'='*60}")
    return all_pass


# ──────────────────────────── V2 fault-injection facades (issue #291) ────────────────────────────
# Thin dispatchers — actual scenario logic lives in faultInjection.py per the
# plan's §3.4 ("Pure dispatch — no scenario logic in wispr_eyes.py itself").

def list_scenarios():
    """Print the V2 fault-injection scenario menu."""
    from faultInjection import print_scenarios
    return print_scenarios()


def run_scenario(name, **kwargs):
    """Run a single V2 fault-injection scenario by name. Forwards kwargs to
    the scenario function (e.g. `founder_present=True` for Lane B)."""
    from faultInjection import run_scenario as _run
    return _run(name, **kwargs)


def record_with_fault(scenario_name, **kwargs):
    """Convenience wrapper: connect to the app, run a Lane A scenario, return
    the result dict. For ad-hoc dev use; production demonstrations route
    through `run_scenario` directly."""
    connect()
    return run_scenario(scenario_name, **kwargs)
