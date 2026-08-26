"""wispr_eyes — thin visual verification wrapper for Sonnet agents.
Usage:  python3 -c "from wispr_eyes import *; connect(); see()"
        python3 -c "from wispr_eyes import *; connect(); tap('AI Polish')"
"""
import os, sys, subprocess, time
import datetime as _dt
sys.path.insert(0, os.path.dirname(__file__))
from ui_helpers import (find_app_pid, get_ax_app, get_attr, set_attr, perform_action,
    find_element, find_all_elements, find_control_for_label, wait_for_condition,
    get_process_memory_mb, get_clipboard_text, validate_app_ready, element_frame,
    _iter_children_with_menubars)
from ptt_binding import PTTBindingError, require_push_to_talk, resolve

_pid = None
_app = None
_INPUT_WARN = True  # Play chime before CGEvent input (click/type/key)
_TTS_PATH = "/tmp/wispr_eyes_tts.aiff"
_OPENAI_TTS_PATH = "/tmp/wispr_eyes_tts.mp3"
_OPENAI_KEY_FILE = os.path.expanduser("~/.enviouswispr-keys/openai-api-key")

def _resolve_ptt_key():
    """Resolve the configured PTT key name, or raise `PTTBindingError`.

    Previously this owned its own domain list, its own 4-entry keycode->name map,
    and a hardcoded `rcmd` fallback. All three were wrong at once (#1997): it read
    the retired `.dev` domain, could not name Globe (63), and on any failure
    pressed a key the app was not listening for — then the caller reported that
    silence as a product FAIL. `ptt_binding` now owns resolution and REFUSES
    rather than guessing; see that module's header for why no fallback exists.
    """
    return resolve().key_name


def _ptt_binding_diagnostic(pressed_key):
    """One line of instrument state, printed only when a PTT run produced nothing.

    The 2026-08-10 failure was indistinguishable from "the product ignored the
    hotkey": no states, no log growth, a bare timeout, and nothing anywhere
    naming the key actually pressed. This makes the instrument's own view
    legible at exactly the moment a reader is deciding whether to believe a FAIL.
    """
    try:
        binding = resolve()
        configured = (
            f"configured key={binding.key_name} keycode={binding.keycode} "
            f"modifiers={binding.modifiers_raw} mode={binding.recording_mode}"
        )
    except PTTBindingError as error:
        configured = f"configured binding unreadable: {error}"
    print(f"INSTRUMENT STATE: pressed={pressed_key}; {configured}")


def tts(sentence="The quick brown fox jumps over the lazy dog", voice="echo", engine="openai"):
    """Generate audio from text. engine='openai' (natural) or 'say' (local fallback). Returns file path."""
    env_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if engine == "openai" and (env_key or os.path.exists(_OPENAI_KEY_FILE)):
        import urllib.request, json
        key = env_key if env_key else open(_OPENAI_KEY_FILE).read().strip()
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
    "engine": ["Fast", "All Languages"],
    "style": ["Formal", "Standard", "Friendly"],
}

def read_cards(group):
    """Read which card is selected in a card group.

    Groups: 'engine', 'style'.
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
         ["Unload model after"], ["engine"], []),
        ("Microphone", [], ["Input"], [], []),
        ("Keybinds", [], [], [], []),
        # #1831 removed the Deep reasoning toggle, so the AI Polish tab now
        # declares no expected switches. An empty list is the correct
        # expectation, not a gap: naming a control that no longer exists would
        # fail every run, and naming none asserts the tab still renders.
        ("AI Polish", [], ["Provider", "Model"],
         ["style"], ["Save", "Clear", "Refresh", "Copy Diagnostics"]),
        ("Your Words", ["Enable custom words"], [], [], []),
        ("Clipboard",
         ["Auto-copy to clipboard", "Restore clipboard after paste"],
         [], [], []),
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
    "parakeet": "Fast",
    "whisperkit": "All Languages",
}


def switch_backend(name, wait=3.0):
    """Switch the active ASR engine via the Settings UI.

    Args:
        name: "parakeet" or "whisperkit".
        wait: seconds to let the model load after switching.

    Settings -> Transcription has two buttons:
        Fast            -> Parakeet
        All Languages   -> WhisperKit

    Usage:
        switch_backend("whisperkit")
        test_recording(sentence="...")  # now runs on WhisperKit
    """
    if name not in _BACKEND_LABELS:
        raise ValueError(f"Unknown backend '{name}'. Use one of: {list(_BACKEND_LABELS)}")
    connect()
    # nav("Transcription") requires AXOutline and silently no-ops against the
    # button sidebar (#1296); tap() on the sidebar button itself is reliable
    # once Settings is open. But nav()'s own auto-open-Settings fallback still
    # ran before it gave up on the sidebar search, so a caller relying on that
    # side effect (e.g. after Settings closed between two switch_backend calls)
    # needs the same explicit open here (Codex code-diff review, 2026-07-22).
    if not tap("Transcription"):
        if not tap("Settings..."):
            raise RuntimeError("Could not open Settings to reach Transcription")
        time.sleep(0.8)  # settle: mirrors nav()'s own post-auto-open wait for the window to animate in
        if not tap("Transcription"):
            raise RuntimeError("Could not tap 'Transcription' in the Settings sidebar")
    time.sleep(0.3)
    label = _BACKEND_LABELS[name]
    # These two engine buttons carry their label in AXDescription with an EMPTY
    # AXTitle, which `tap()` does not search — so `tap("Fast")` reported
    # 'Fast' not found while `see()` printed the button one line above
    # (#1884 Live UAT, 2026-07-31). A missing control and an unsearched attribute
    # look identical from the caller, which is why this resolves the element
    # itself rather than retrying a tap that can never match.
    button = _engine_button(label)
    if button is None:
        raise RuntimeError(
            f"Could not find the '{label}' engine button in Settings -> Transcription")
    if not perform_action(button, "AXPress"):
        raise RuntimeError(f"Could not press the '{label}' engine button")
    # Prove the switch LANDED, by waiting on the button's own selection state.
    # Pressing and assuming is the precondition-never-checked shape: every later
    # assertion would then describe whichever engine was already selected.
    deadline = time.time() + 5.0
    while time.time() < deadline:
        if str(get_attr(_engine_button(label), "AXValue") or "") == "Selected":
            break
        time.sleep(0.25)  # settle: poll interval around the AXValue signal wait above, not a fixed delay
    else:
        raise RuntimeError(f"Pressed '{label}' but it never reported itself selected")
    print(f"Switched backend to {name} ({label}); waiting {wait:.0f}s for model load...")
    time.sleep(wait)
    return True


def _engine_button(label):
    """The Transcription-pane engine button whose AXDescription is *label*.

    Separate from `tap()` on purpose: `tap()` matches AXTitle/AXValue across the
    whole app, and matching a description app-wide would make every caller's
    taps fuzzier. Returns None when absent.
    """
    for el in find_all_elements(_app, role="AXButton"):
        if (get_attr(el, "AXDescription") or "") == label:
            return el
    return None


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


# Right Option, the shipped default record key. `simulate_input._MODIFIER_FLAGS`
# already maps it; this constant exists so the helpers below read as a hotkey
# rather than as a keycode.
RECORD_KEY = "ropt"

# The app's own chain window, `TimingConstants.handsFreeDebounceDelayMs = 500`.
# Named rather than inlined so a future change to that constant has one place to
# meet here — a hard-coded 0.5 in three call sites is how a harness quietly stops
# reaching the behaviour it tests.
_CHAIN_WINDOW_S = 0.5


def press_record_key():
    """Post ONE press of the record hotkey, the way the app can actually see it.

    The record key is a BARE MODIFIER, so it is delivered as `kCGEventFlagsChanged`
    rather than keyDown/keyUp, and it is handled through an event tap rather than
    Carbon (`tools-and-apps.md` FACT: the-record-hotkey-IS-drivable-synthetically-only-cancel-is-not).

    **This delegates to `simulate_input.modifier_down`/`modifier_up`, which have
    carried the correct mechanism all along** — including
    `CGEventSetIntegerValueField(kCGKeyboardEventKeycode)`, because the keycode
    does NOT survive the type change on its own. #2410 proposed a fresh helper
    "so nobody re-derives this"; the snippet it proposed was itself a
    re-derivation, and it omitted that line. A press missing it produces a pill on
    screen and ZERO chain detections — events demonstrably arriving and being
    acted on, so the only conclusion available is that the app's chain detection
    is broken, which is false. A half-working result that indicts production code
    is strictly worse than a silent one.

    Do not inline a `CGEventSetType` call here or anywhere else in this harness.
    Two implementations of this already existed; a third is how they drift.
    """
    import simulate_input as _si
    import ptt_binding as _ptt

    # RESOLVE the binding; never assume it. `RECORD_KEY` is only the DEFAULT, and
    # the settings UI persists both a different key and a different recording
    # mode. Pressing right Option at a profile bound to Globe, or driving a
    # multi-press chain in toggle mode - where `HotkeyService` does not route
    # hands-free at all - produces silence, and the caller reports that silence as
    # a PRODUCT failure. That is the exact class `ptt_binding` exists for, and it
    # refuses rather than guessing.
    binding = _ptt.resolve()
    if not binding.is_modifier_only:
        raise _ptt.PTTBindingError(
            f"the record key is bound to {binding.key_name!r} (keycode "
            f"{binding.keycode}), which is not a standalone modifier. Multi-press "
            "chain detection runs on the modifier event tap; an ordinary key is "
            "registered with Carbon, which does not deliver synthetic events."
        )

    _si.modifier_down(binding.keycode)
    time.sleep(0.04)
    _si.modifier_up(binding.keycode)


def running_enviouswispr_instances():
    """Every running EnviousWispr app bundle, as {pid: executable path}.

    Reads `comm`, NOT `command`. `command` is the executable PLUS its arguments
    with no delimiter between them, so recovering the executable means guessing
    where the arguments begin - and every guess is wrong for some legal path. An
    earlier version split on the first `" -"`, which silently truncates
    `/Users/x/EW - issue/build/EnviousWispr Local.app/...` to `/Users/x/EW` and
    drops that instance from the count. `comm` is the executable alone, so there
    is nothing to parse. (Verified here: on macOS it is the full path, unlike
    Linux where `comm` is the basename.)

    Still excludes our own pid. A caller's argv routinely carries both
    `EnviousWispr` (a worktree path) and `.app/Contents/MacOS/` (a script running
    under `Python.app`), and excluding `python3` does not help - the interpreter's
    binary is named `Python`. The basename test already rejects `.../Python`, so
    the pid check is the second of two mechanisms rather than the only one; the
    self-test carries a row that binds it, because a mutant proved the obvious row
    did not.

    Deliberately NOT scoped to `EnviousWispr Local.app`. A Release-configuration
    test host is named `EnviousWispr.app`, carries the PRODUCTION bundle id, and
    answers the same global hotkey; a `Local.app` pattern cannot see it, which is
    exactly the instance you most want counted.
    """
    # `-ww` asks for unlimited width. macOS `ps(1)` documents that output can be
    # truncated to the terminal width and that a second `-w` lifts the bound. It
    # did NOT reproduce here - piped output stayed intact at 88,841 characters
    # even with COLUMNS=60 - so this is insurance, not a fix for an observed
    # truncation. It earns its place because the failure would be SILENT and in
    # the dangerous direction: a truncated suffix drops a real instance, and the
    # verdict becomes unattributable with nothing to indicate it.
    out = subprocess.run(["ps", "-eww", "-o", "pid=,comm="],
                         capture_output=True, text=True).stdout
    me = str(os.getpid())
    found = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        pid, exe = line.strip().split(None, 1)
        if pid == me:
            continue
        # An EXACT suffix, so the app's own XPC service and `llama-server` - both
        # inside the same bundle and both in this listing - are excluded.
        if exe.endswith(".app/Contents/MacOS/EnviousWispr"):
            found[pid] = exe
    return found


def _require_single_instance(what):
    """REFUSE rather than choose when more than one EnviousWispr is running.

    Every instance answers the same global hotkey and writes the same shared
    `app.log`, so a marker count drawn from that log is unattributable the moment
    there are two. Measured 2026-08-25: a second instance inside the window
    returned 2 of every marker with DISTINCT session ids - two real recordings
    from one gesture - which reads as the app double-counting a synthetic press.
    A confident wrong subject, pointing at production code.

    Returns the instance map so the caller can re-check it afterwards. A wrong
    refusal costs a rerun; a wrong verdict costs somebody a debugging session in
    correct code.
    """
    found = running_enviouswispr_instances()
    if len(found) != 1:
        rows = "\n".join(f"    {p}  {c}" for p, c in sorted(found.items()))
        print(f"BLOCKED: {what} needs exactly ONE running EnviousWispr; "
              f"found {len(found)}.\n{rows}")
        return None
    return found


# One per launch of a debug build. Chosen over `[Recovery] #1 scan pass 1 started
# (launch)` by measurement rather than taste: 437 occurrences against 112 in the
# same log, because the recovery line is conditional and this one is not. It also
# fires when a user toggles Debug Mode by hand, which OVER-reports - and
# over-reporting means refusing a verdict that might have been fine, which is the
# safe direction.
_LAUNCH_BANNER = "[AppLogger] Debug mode enabled"


def _line_timestamp(line):
    """The ISO-8601 stamp `AppLogger` puts at the head of every line, or None."""
    if not line.startswith("["):
        return None
    end = line.find("]")
    if end < 0:
        return None
    try:
        return _dt.datetime.fromisoformat(line[1:end])
    except ValueError:
        return None


def _merge_sweeps(first, second):
    """Combine two passes over the log shelf into the evidence to trust.

    Extracted so the decision is testable without staging a real rotation - the
    surviving mutant is what asked for it, since nothing could reach this logic
    while it lived inside a closure.

    ALWAYS THE UNION, AND THE INODE COMPARISON IS GONE. Three revisions landed
    here and the first two both tried to CHOOSE a pass:

      select the second when inodes differ - wrong, because one rotation during
      the validation pass makes that pass the incomplete one and its differing
      inode map is exactly what selects it;

      keep the first when inodes match - also wrong, because inode equality
      proves only that nothing was RENAMED. The app appends constantly, so a
      marker written between the two passes is present in the second and absent
      from the first, with both maps identical. In the per-attempt check that
      hides a late `Double press` and licenses a destructive retry; in the final
      check it reports a successful gesture as missing its stop marker.

    Both failures come from the same move: deciding which pass to trust. The
    union needs no such decision. A line in either pass is real evidence whose
    timestamp survived any rename, and every caller does a membership or an
    emptiness test, so a duplicate costs nothing. **Choosing between two passes
    requires knowing which is complete; taking both requires knowing nothing.**
    """
    seen, merged = set(), []
    for line in first + second:
        if line not in seen:
            seen.add(line)
            merged.append(line)
    return merged


def _line_in_window(line, start):
    """Is this log line stamped at or after `start`?

    ONE implementation, two callers. The consolidation that gave the harness a
    single log reader briefly left this test written twice - in the reader and in
    the banner counter - and the mutation control caught it as a DUPLICATED ANCHOR
    rather than as a survivor. That is the cheaper of the two ways to find out.

    A line whose stamp will not parse answers NO. `AppLogger` writes a well-formed
    stamp on every line, so an unparseable one is a mangled line rather than an
    event, and the process SAMPLES remain the mechanism that does not depend on
    the log being readable at all.
    """
    stamp = _line_timestamp(line)
    if stamp is None:
        return False
    # FLOOR THE START TO THE SECOND. `AppLogger` writes second-resolution stamps
    # (`2026-08-25T17:55:04-04:00`, no fraction) while `datetime.now()` carries
    # microseconds, so a line written 0.4s AFTER the window opened compares as
    # BEFORE it and is discarded. Measured live: the double press fired, all three
    # markers were in the log, and the per-attempt check reported "did not register
    # after 3 attempts" - the harness driving three gestures against an app that
    # had already done what was asked.
    #
    # Direction is the expensive one and it is why a unit-covered change still
    # needed a live run: it fails toward NOT SEEING evidence. For the banner scan
    # that is permissive (a launch goes uncounted); for the marker check it is a
    # false product failure; and for the retry it is the saboteur case this file
    # already documents, since an unseen marker is what licenses the next press.
    # A window a fraction of a second wide is exactly where it bites, which is the
    # per-attempt check and nowhere else - the ones with a start seconds earlier
    # were unaffected, so nothing failed until the window got small.
    return stamp >= start.replace(microsecond=0)


def log_lines_since(start):
    """Every `app.log` line stamped at or after `start`, oldest first, across the
    rotated predecessors.

    THE ONE READER. Rotation produced a finding in three consecutive review
    rounds, at three different call sites - the banner scan, the retry's own
    check, and the final marker check - and each was correct and each exposed the
    next. That is the signature of fixing sites rather than the question.

    The question every one of them was asking is "what did the app log during this
    window", and `_read_new_log_lines` cannot answer it: it follows the inode, so
    when `AppLogger.rotateIfNeeded` moves `app.log` to `app.1.log` at its 10 MiB
    bound, everything before the move is silently absent and the result still
    looks like a complete slice. A timestamp cannot be moved by a rename, so
    asking by time has no such failure.

    Cost is six names read twice - the shelf is 49 MB here and one call measured
    0.38s. That is real, and it is why the retry loop reads ONCE and asks one
    question of the result rather than reading again for a second question.

    KNOWN AND UNFIXABLE HERE: a RELEASE build writes nothing at all -
    `AppLogger.swift` gates the whole file sink behind `#if DEBUG`. So no reader
    of this log can see a Release instance, and no amount of reading better fixes
    that. The process SAMPLES are the only mechanism that sees one.
    """
    directory = os.path.dirname(_APP_LOG_PATH)
    # Oldest first: `app.5.log` down to `app.1.log`, then the live file.
    # `maxFileCount` is 5 in `AppLogger.swift`; reading one more than exists is
    # free, and reading one FEWER is the silent miss this function exists to stop.
    names = [f"app.{i}.log" for i in range(5, 0, -1)] + ["app.log"]

    def sweep():
        """One pass over the shelf."""
        found = []
        for name in names:
            path = os.path.join(directory, name)
            try:
                with open(path, "rb") as fh:
                    text = fh.read().decode("utf-8", "replace")
            except OSError:
                continue
            for line in text.splitlines():
                if _line_in_window(line, start):
                    found.append(line)
        return found

    # A ROTATION DURING THE SWEEP CAN SKIP A FILE ENTIRELY, which no ordering
    # fixes: once `app.2.log` has been read, a rotation moves the old
    # `app.1.log` onto that already-passed name and the live file onto
    # `app.1.log`, so the old `app.1.log` is never opened. Its lines keep their
    # timestamps through the rename, so they are real evidence that reads as
    # absent.
    # Detected by comparing INODES rather than assumed away: if any name now
    # resolves to a different file, the shelf moved under us and one more pass
    # sees the settled state. Bounded at two - a second rotation inside the same
    # few milliseconds needs the log to cross 10 MiB twice, and an unbounded
    # retry here would be a worse failure than the one it chases.
    # SELECTING THE SECOND PASS WAS WRONG, and the reasoning that produced it
    # ("bounded at two - a second rotation needs 10 MiB twice") was wrong too: it
    # takes only ONE rotation, occurring during the VALIDATION pass, for that pass
    # to be the incomplete one - and the differing inode map is exactly what made
    # it get selected.
    # The UNION cannot omit. A line present in either pass is real evidence, its
    # timestamp survived the rename, and every caller here does a membership test
    # or an emptiness test, so a duplicate costs nothing. Choosing between two
    # passes requires knowing which is complete; taking both requires knowing
    # nothing.
    # Two passes, always merged. Comparing them was tried three ways and every
    # one had to CHOOSE which pass to trust; the union chooses nothing.
    return _merge_sweeps(sweep(), sweep())


def launch_banners_since(start):
    """Launch banners at or after `start`, across the live log AND its rotated
    predecessors.

    READS THE FILES, NOT A CURSOR, and both halves of that are review findings.

    A cursor taken after the ownership check leaves a gap in front of it - here
    `begin_test`, `close_window` and TTS synthesis, which is seconds, not
    milliseconds - and a banner written in that gap is outside the slice. Passing
    a TIMESTAMP instead means the window starts where ownership was established
    rather than where somebody happened to open the file.

    And a cursor cannot survive ROTATION. `AppLogger.rotateIfNeeded` moves
    `app.log` to `app.1.log` (and shifts `app.N` to `app.N+1`) the moment the file
    passes its size bound, so a second launch's banner can be pushed into
    `app.1.log` while every marker that follows lands in the new `app.log`. A
    reader that follows the inode reads the new file only and sees a complete-
    looking slice with the banner missing. Scanning the predecessors costs one
    open each and removes the whole question.
    """
    return count_launch_banners(["\n".join(log_lines_since(start))], start)


def count_launch_banners(texts, start):
    """The pure half of `launch_banners_since`: count banners at or after `start`.

    Split out so the self-test can drive it with synthetic text. The FILE
    LOCATIONS deliberately stay inside `launch_banners_since` and are not a
    parameter - a caller able to redirect where this guard looks could aim it at
    an empty directory and be handed a clean verdict, which is a bypass wearing a
    test seam's clothes.
    """
    seen = 0
    for text in texts:
        for line in text.splitlines():
            if _LAUNCH_BANNER not in line:
                continue
            if _line_in_window(line, start):
                seen += 1
    return seen


def instances_stayed_single(before, window_start, samples):
    """Did exactly one EnviousWispr own this window, start to finish?

    TWO SNAPSHOTS CANNOT ANSWER THIS, and a review round is what established it:
    an instance that starts after the opening check and exits before the closing
    one leaves both endpoints reading the same single pid, while its markers sat
    in the shared log for the whole interval. The comparison passes and the
    verdict is exactly as unattributable as if the guard were absent.

    So the window is covered by two mechanisms that fail differently:

      SAMPLES   the instance set read repeatedly DURING the window rather than
                only at its ends. Closes the hole down to the sampling gap.
      BANNER    the log FILES, scanned by TIMESTAMP for another app's launch
                line from `window_start` onward, across the rotated predecessors
                too. The better of the two, because it is evidence from the SAME
                artifact the verdict is drawn from: a process that wrote into
                this window announced itself IN it, whatever the process table
                happened to say at the instants we looked.
                Reading files rather than a cursor is deliberate - see
                `launch_banners_since`, whose docstring carries the two ways a
                cursor loses the banner.

    Returns `(ok, reason)`. The reason names which mechanism objected, because "a
    second app launched mid-window" and "the app was replaced" are different
    things to go and look at.

    KNOWN RESIDUAL, stated rather than implied, because "two mechanisms" reads as
    "closed" and this is not.

    THE LARGEST MEMBER IS A RELEASE BUILD, and an earlier version of this note got
    it wrong by describing a narrow line-loss race instead. `AppLogger.swift` gates
    the ENTIRE file sink behind `#if DEBUG`, so a Release instance writes no banner
    at all - not one at risk of being lost, one that never exists. Meanwhile
    `running_enviouswispr_instances` counts Release bundles deliberately, because
    they answer the same global hotkey. So for a Release instance the banner
    mechanism contributes NOTHING and the samples are the only cover, which makes
    the residual the whole sampling gap rather than a rare coincidence.
    A debug instance is the narrow case: it must launch AND exit between two
    samples, with its banner ALSO lost to the concurrent-writer line loss
    `AppLogger` suffers - and the moment a second app launches is exactly when
    there are two writers, so the banner is the line most at risk.

    What is NOT in that residual any more, because a review round closed both: a
    banner written before the log cursor was taken, and a banner carried into a
    rotated file. Neither depends on a cursor now.

    What is NOT claimed: that this proves one instance owned the window. What is
    claimed: two independent mechanisms must both miss, where before one snapshot
    pair had a hole a whole app could live in. If a verdict from this ever has to
    be defended, defend it on the samples plus the banner plus what the log slice
    actually contains - never on this function returning True.
    """
    for snap in samples:
        if set(snap) != set(before):
            return False, (f"the running set changed mid-window "
                           f"({sorted(before)} -> {sorted(snap)})")
    launches = launch_banners_since(window_start)
    if launches:
        return False, (f"{launches} app launch banner(s) appeared inside this "
                       f"window; another instance wrote into this same log")
    return True, ""


def double_press_record_key(attempts=3):
    """Two presses inside the app's chain window — the hands-free gesture (#2410).

    The window is measured from the moment RECORDING STARTS, not from the first
    press, so the gap here is deliberately well inside 500ms rather than close to
    it.

    NO PRECONDITION ON FOCUS. Measured 2026-08-25, macOS 26.4, dev build from
    `main` at `d8cfd3b9`, two arms against one instance:

        frontmost = com.apple.TextEdit          -> 1 `Double press`, 1 activation
        frontmost = com.enviouswispr.app.dev    -> 1 `Double press`, 1 activation

    So the tap is not frontmost-scoped, and this is now a measurement rather than
    the argument-from-architecture the previous revision correctly refused to
    accept. Arm A needs Settings OPEN to be stageable at all — EnviousWispr is a
    menu-bar app with no window at rest, so activation alone cannot make it
    frontmost, and a run that skips that step reports NOT ACHIEVED rather than a
    control.

    **RUN THIS AGAINST EXACTLY ONE EnviousWispr INSTANCE, AND RE-CHECK MID-RUN.**
    The first attempt at this measurement returned 2 of every marker with distinct
    session ids — two real recordings from one gesture — because a peer's
    `build-dev-app.sh` relaunched their app INSIDE the measurement window. Both
    apps answered the same global hotkey and wrote the same shared `app.log`.
    A start-of-run instance check is a claim about a MOMENT; nothing makes it a
    claim about the run. Count the pids before AND after, and require the same
    pid rather than the same count, since a TERM-and-relaunch keeps the count at
    one while swapping the instance underneath.

    The direction is what makes it expensive: two `dictation_started` from one
    press reads as the app double-counting a synthetic press, or as the tap being
    registered twice. Both indict production code, both are false, and both come
    with a reproduction. Distinct session ids are what separate "two recordings"
    from "one duplicated log line".
    """
    # THE SYNTHETIC CHAIN IS ~80% RELIABLE AND NO GAP FIXES IT. Measured
    # 2026-08-25 against the live dev build, 24 trials at four gaps:
    #
    #     0.04s  5/6     0.08s  4/6     0.12s  5/6     0.20s  3/5     0.30s  0/5
    #
    # So the first four are one population around 80% and 0.30s is outside the
    # window entirely. Tuning the number is not available - it was tried first,
    # and the measurement is what stopped it.
    #
    # A SIGNAL-BASED WAIT WAS TRIED AND IS WORSE, which is why this is a retry and
    # not the seam fix the flake rules would otherwise ask for. Waiting for the
    # first press's `Recording started` before posting the second failed 4 out of
    # 4: that line is written AFTER the key-up has already ended the push-to-talk
    # take, so the second press lands during teardown rather than after it. The
    # subject does emit a signal; it is not a signal that means "ready".
    #
    # What a missed attempt costs is nothing: the orphan take is discarded by the
    # app as `Recording discarded - too short`, so the state is self-clearing and a
    # retry starts clean.
    #
    # THE ATTEMPT COUNT IS PRINTED, ALWAYS. A retry that hides itself turns a
    # degrading delivery path into a silent slowdown, and the next person to
    # measure this needs to see 1 become 3 before it becomes a failure.
    # KNOWN COST OF THE RETRY, and it is a real one rather than a hedge. Where no
    # file log exists at all - a Release build compiles the sink out, and Debug
    # Mode gates it in a debug build - a first attempt that SUCCEEDED reads as a
    # failure, and the next press lands on an already-locked recording where
    # `HotkeyService` takes it as the STOP gesture.
    #
    # An earlier revision tried to detect that state and drive the gesture once
    # instead. It was wrong twice in opposite directions, cost two full traversals
    # of a 49 MB shelf per attempt, and was choosing between two ways of failing
    # the run rather than preventing a loss. Deleted, and this is what deleting it
    # costs: on a build with no log, three attempts instead of one.
    #
    # The verdict below is what covers it - it names every cause it cannot rule
    # out rather than reporting a product failure it cannot distinguish from its
    # own blindness.
    for attempt in range(1, attempts + 1):
        attempt_start = _dt.datetime.now().astimezone()
        press_record_key()
        time.sleep(0.12)
        press_record_key()
        time.sleep(0.6)
        # `log_lines_since`, NOT a cursor: a rotation between the snapshot and
        # this read would hide the marker, and a hidden marker here is what turns
        # the retry into the saboteur described above.
        # ONE read, serving one question. An earlier revision took two - a
        # non-strict read for the marker and a strict one for "is the sink
        # live" - and they were 0.4s apart on this machine, because each is a
        # full traversal of a 49 MB shelf. A marker landing in that gap is
        # absent from the first read and present in the second, which is
        # exactly the state the second read existed to detect.
        #
        # `Hands-free mode activated`, NOT `Double press`. Production says so
        # in as many words at `HotkeyService.swift:673` - "this records the
        # REQUEST. Whether it becomes a lock is not known yet" - and
        # `publishLockIfReady` can answer `.notLockable` and clean up. Retrying
        # on the request marker meant declaring success on a gesture that
        # requested a lock and did not get one.
        window = log_lines_since(attempt_start)
        if any("Hands-free mode activated" in line for line in window):
            if attempt > 1:
                print(f"  double press engaged on attempt {attempt} of {attempts}")
            return True
        if attempt < attempts:
            print(f"  attempt {attempt} did not register a chain; retrying")
            # Let the orphan take finish being discarded before pressing again.
            time.sleep(1.2)
    print(f"  double press did not register after {attempts} attempts")
    return False


def stop_after_short_hold(hold):
    """Stop a recording this helper locked but is about to refuse to judge.

    A REFUSAL MUST NOT LEAVE A RECORDING RUNNING. This path is reached only after
    the double press has locked hands-free, so an early `return` left the app
    recording indefinitely - capturing ambient audio and poisoning every later run
    in the session. That is precisely what the Escape Recovery UAT did on
    2026-08-18, where the founder ended the recording by hand.

    Waits out the remainder of the lock cooldown first: `HotkeyService` ignores a
    press within 500ms of locking, so a stop posted too early is swallowed and the
    refusal leaves the same mess it was written to avoid.

    A separate function so a row can reach it. The in-line version survived its
    mutant - the fourth in this PR to survive for want of reachability rather than
    for want of a correct guard.
    """
    remaining_cooldown = _CHAIN_WINDOW_S - hold
    if remaining_cooldown > 0:
        time.sleep(remaining_cooldown)
    print("  stopping the locked recording before returning")
    single_press_record_key()
    time.sleep(1.0)


def single_press_record_key():
    """One press AFTER the lock cooldown — the hands-free stop (#2410).

    `HotkeyService` ignores presses within 500ms of locking, so a stop posted
    too early is swallowed by the cooldown and reads as "the app ignored the
    stop". The caller is responsible for having recorded for longer than that;
    this helper only refuses to be the reason it was too soon.
    """
    press_record_key()


def test_hands_free(audio=None, sentence=None, hold=4.0, expect=None, timeout=30.0):
    """Drive the real hands-free gesture: double-press to lock, single-press to stop.

    **THE OLD DOCSTRING SAID "Menu-based recording IS hands-free" AND THE APP HAS
    NEVER AGREED (#2409).** Measured across all five rotated logs, 434,924 lines:
    650 `Hands-free mode activated` against 652 `Double press`, so the double
    press accounts for effectively every activation and the menu path has produced
    none. (The two-line gap is line loss rather than a product gap. Note the
    measurement predates #2159: `AppLogger` opened without `O_APPEND` then, so
    concurrent writers overwrote each other. `AppLogger.swift:187` uses
    `O_WRONLY | O_APPEND | O_CLOEXEC` now and that mechanism is closed - rotation
    is still unlocked across processes, which is a different one.)

    That sentence did not merely mislead, it RETIRED THE CHECK: anyone asking
    "does our suite cover hands-free" read it, got an answer, and stopped looking,
    while the helper drove an ordinary menu recording and reported it as
    hands-free coverage.

    Menu start/stop is still covered - by `test_recording`, which has always done
    exactly that. So this is not a lost capability; it was a duplicate wearing a
    name that promised something else.

    ASSERTS THE HANDS-FREE MARKERS, not merely that a recording persisted. Any
    recording persists; only this gesture produces `Double press`,
    `Hands-free mode activated` and `Single press while locked`. Without that
    check the test would still be measuring the wrong thing with the right input.

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

    # The verdict below is a COUNT OF MARKERS IN A SHARED LOG, so it is only
    # attributable while ONE instance is running. Checked here and again after the
    # gesture, because a start-of-run check is a claim about a moment: a peer's
    # `build-dev-app.sh` step 8 can launch a second app mid-run, and the count
    # stays at one across a TERM-and-relaunch while the instance changes.
    instances_before = _require_single_instance("test_hands_free")
    if instances_before is None:
        return False
    # Sampled DURING the window, not only at its ends - see
    # `instances_stayed_single`. An instance that starts after the opening check
    # and exits before the closing one is invisible to two snapshots.
    instance_samples = []
    # STAMPED HERE, at the moment ownership was established, and NOT at the log
    # cursor taken further down. Everything between the two - `begin_test`,
    # `close_window`, TTS synthesis - is seconds, and a review round found that a
    # second app launching in that gap has its banner outside the slice entirely.
    # The window starts where the claim starts.
    window_start = _dt.datetime.now().astimezone()

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

    # Phase 1: the REAL gesture - two presses inside the app's chain window.
    print(f"\n--- DOUBLE PRESS (hands-free lock) ---")
    double_press_record_key()

    # Wait for recording to engage — menu should flip to "Stop Recording"
    t_start = time.time()
    recording_started = False
    for _ in range(10):
        time.sleep(0.3)
        instance_samples.append(running_enviouswispr_instances())
        if _find_match(_app, "Stop Recording", "AXMenuItem"):
            recording_started = True
            break
    start_latency = time.time() - t_start
    print(f"Recording started: {'YES' if recording_started else 'NO'} ({start_latency:.1f}s)")

    if not recording_started:
        # STOP FIRST. This branch fires when the AX probe never saw `Stop
        # Recording`, which is exactly when the harness does NOT know whether the
        # gesture locked - and returning here left the app recording if it had.
        # A press costs nothing in the other world: with nothing locked it starts
        # a take the app discards as too short.
        print("BLOCKED: Recording did not start (menu never showed 'Stop Recording')")
        print("  posting a stop press anyway, in case the gesture locked and the "
              "menu probe is what failed")
        time.sleep(_CHAIN_WINDOW_S)
        single_press_record_key()
        time.sleep(1.0)
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
    instance_samples.append(running_enviouswispr_instances())

    # Mid-recording check: verify STILL recording (the hands-free test)
    still_recording_mid = _find_match(_app, "Stop Recording", "AXMenuItem") is not None
    print(f"Still recording at {mid_check_at:.1f}s: {'YES' if still_recording_mid else 'NO'}")

    remaining = hold - mid_check_at - start_latency
    if remaining > 0:
        time.sleep(remaining)
    instance_samples.append(running_enviouswispr_instances())

    # Final pre-stop check
    still_recording_end = _find_match(_app, "Stop Recording", "AXMenuItem") is not None
    print(f"Still recording at {hold:.1f}s: {'YES' if still_recording_end else 'NO'}")

    if audio_proc and audio_proc.poll() is None:
        audio_proc.terminate()

    # Phase 4: single press to stop. `HotkeyService` ignores presses within
    # 500ms of locking, so a stop posted inside that cooldown is swallowed and
    # reads as "the app ignored it". `hold` is at least a second in every path
    # above, so the cooldown has long expired - asserted rather than assumed,
    # because a future caller passing hold=0.2 would otherwise get a confusing
    # failure in the app rather than a clear one here.
    if hold < _CHAIN_WINDOW_S:
        # STOP THE RECORDING BEFORE REFUSING. This branch is reached only AFTER
        # the double press has locked hands-free and the hold has elapsed, so
        # returning here left the app recording indefinitely - capturing ambient
        # audio and poisoning every later run in the session. That is the exact
        # failure the Escape Recovery UAT produced on 2026-08-18, where the
        # founder ended the recording by hand.
        # Wait out the lock cooldown first, or the stop press is swallowed and
        # the refusal leaves the same mess it was written to avoid.
        print(f"BLOCKED: hold={hold:.2f}s is inside the {_CHAIN_WINDOW_S:.1f}s "
              f"lock cooldown; the stop press would be swallowed")
        stop_after_short_hold(hold)
        end_test()
        return False
    print(f"\n--- SINGLE PRESS (stop) ---")
    single_press_record_key()

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

    # THE HANDS-FREE-SPECIFIC ASSERTION, and it is why this helper exists (#2409).
    # "Recording persisted" is true of EVERY recording, which is exactly how the
    # old menu-driven version passed while covering nothing. These three lines
    # are produced by the chain detection and by nothing else.
    markers = {
        "Double press": False,
        "Hands-free mode activated": False,
        "Single press while locked": False,
    }
    # Read from the FILES by timestamp rather than from the accumulated slice.
    # `_wait_for_pipeline_completion` follows the inode, so a rotation crossing
    # the 10 MiB bound mid-run leaves every marker in `app.1.log` and the slice
    # looks complete without them - which fails a SUCCESSFUL single-instance run
    # and reports it as missing hands-free markers. Same root as the banner scan
    # and the retry check; one reader now answers all three.
    for line in log_lines_since(window_start):
        for m in markers:
            if m in line:
                markers[m] = True
    print(f"\nHands-free markers in app.log:")
    for m, seen in markers.items():
        print(f"  {'YES' if seen else 'NO ':3}  {m}")
    # RE-CHECK, and it is not belt-and-braces: the check at the top of this
    # function was true when it ran and says nothing about the window that
    # followed. Compare the PIDS, never the count - a TERM-and-relaunch leaves the
    # count at one while swapping the instance, and a second app that shared this
    # log for part of the run makes every number above unattributable. Refuse the
    # verdict rather than reporting one.
    instance_samples.append(running_enviouswispr_instances())
    single, why = instances_stayed_single(instances_before, window_start,
                                          instance_samples)
    if not single:
        print(f"\n  BLOCKED: {why}.")
        print(f"  Every marker count above is unattributable: each instance answers "
              f"the same global hotkey and writes this same log.")
        print(f"  This is NOT a product failure. Re-run against one instance.")
        end_test()
        return False

    # AN UNREADABLE INSTRUMENT IS NOT A PRODUCT FAILURE, and this path used to
    # score one. With no live sink every marker is false BY CONSTRUCTION - a
    # Release build compiles the sink out entirely - so a gesture that worked and
    # a pipeline that completed would still print a product-facing FAIL naming
    # three missing markers. That is the confident-wrong-subject shape: it
    # accuses the app of a defect the harness could not have observed either way.
    #
    # An earlier round argued the caller would treat unreadable evidence as
    # BLOCKED. Review checked that premise and it was false - nothing here did.
    hands_free_proven = all(markers.values())
    if not hands_free_proven:
        # NAME EVERY POSSIBILITY RATHER THAN CHOOSING ONE. An earlier revision
        # spent ~250 lines trying to tell "the harness could not see it" from
        # "the gesture missed", so it could decide which verdict to print. It got
        # that distinction wrong twice, and the distinction was never the point:
        # BOTH end in a failed run rather than in lost data.
        #
        # What mattered was not blaming the PRODUCT for something the harness
        # cannot observe. A person is running this UAT and can check all three
        # causes in seconds, so the honest report is the list, not a guess.
        missing = [m for m, seen in markers.items() if not seen]
        print(f"  UNPROVEN: hands-free was not demonstrated - missing: "
              f"{', '.join(missing)}")
        print(f"  This is not by itself a product defect. Three causes produce "
              f"it and this harness cannot tell them apart:")
        print(f"    1. the gesture genuinely missed - the synthetic chain is "
              f"~80% reliable per attempt, which is why it retries")
        print(f"    2. nothing was writing app.log - a Release build compiles "
              f"the sink out, and Debug Mode gates it in a debug build")
        print(f"    3. a rotation crossed the 10 MiB bound mid-run - "
              f"AppLogger's rotation is still not locked across processes, so a "
              f"line can be lost as the shelf shifts")
        print(f"  Check Debug Mode is on and exactly one EnviousWispr is "
              f"running, then re-run before filing anything.")

    result_text = _extract_transcript_text(signal, log_size_before, clip_seen, log_lines)
    overall_pass = _report_result(completed, audio, expect, result_text) and hands_free_proven
    print(f"{'='*60}")
    end_test()
    return overall_pass


def test_ptt(key=None, audio=None, sentence=None, expect=None, timeout=10.0):
    """End-to-end PTT (push-to-talk) recording test via key hold.

    #1707 Phase 3 crash-safety-net Live UAT recipe (bounded-wait + refuse-
    then-retry): no new helper is warranted here — compose the existing
    low-level calls directly, per RULE: wispr-eyes-fallback-to-direct-python.
    1. Stage 2+ crashed spools: start a recording, wait for recovery arming
       (the recovery key/spool are written before the risky work), then
       kill the app with `SIGKILL` from the shell (`pgrep -f "EnviousWispr
       Local.app/Contents/MacOS/EnviousWispr"` -> `kill -9`); repeat once
       more for a second spool.
    2. Relaunch the app fresh (the measured THIRD launch is the actual test
       run — the app must not already be running before this launch).
    3. Immediately call `test_ptt()` (or `tap()`), before the scan can
       finish item 1's decode.
    4. Assert refusal: read the "recovering" pill via `see()`/`read()`, and
       grep `~/Library/Logs/EnviousWispr/app.log` for `recoveryPressBlocked`.
    5. Wait roughly one item's expected decode time (measured empirically
       per backend), bounded — this is what the harness itself times to
       prove the bounded-wait claim (press-to-engine-release, not
       `Pipeline timing TOTAL`).
    6. Call `test_ptt()` again; assert success and the expected token in
       `observed_transcript`.
    Direct fault injection (`EW_FAULT_INJECTION=1`, `force_recovery_key_fault
    (status)`) stages the Keychain-transient-lock scenario, since it is not
    reachable through normal TTS-driven dictation alone.

    Precisely times key hold to match audio duration:
    1. Press key down (recording starts)
    2. Wait for recording to engage
    3. Play audio through speakers
    4. Wait for audio to finish + buffer
    5. Release key (recording stops, pipeline runs)
    6. Monitor pipeline via state polling + clipboard delta

    Args:
        key:      Key to hold. None (default) auto-detects from EnviousWispr's
                  UserDefaults `toggleKeyCode`. Override with any key in
                  simulate_input.MODIFIER_KEYS or KEY_CODES (e.g. 'rcmd',
                  'space', 'f5').
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

    # Resolve PTT key from app settings if caller didn't override. Either path
    # raises PTTBindingError rather than pressing something unverified (#1997).
    if key is None:
        binding = resolve()
        key = binding.key_name
        print(f"PTT key auto-detected from settings: {key} (keycode {binding.keycode})")
    else:
        # An explicit key overrides the CONFIGURED KEY, never the recording mode:
        # in toggle mode this hold-and-release cannot stop the recording it
        # starts, whatever key is held (#963 captured real speech that way).
        require_push_to_talk()

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
    # Nothing happened at all: print what the instrument believed, so a reader
    # can tell a real product failure from a key the app was never listening
    # for. Gated on the silent shape so a passing run gains no noise.
    if not completed and not states_seen:
        _ptt_binding_diagnostic(key)
    print(f"{'=' * 60}")
    end_test()
    return overall_pass


def record_tts(sentence="The quick brown fox jumps over the lazy dog", key=None,
               voice="echo", wait=10.0, focus_app=None):
    """Generate TTS, hold PTT key, read raw ASR and polished output from app log.

    This is the go-to method for testing transcription quality and polish behavior.
    Does NOT rely on clipboard capture (which can be unreliable). Instead reads the
    CORRECTION_DEBUG lines from the app log for exact raw/polished comparison.

    Args:
        sentence: Text to speak via TTS.
        key:      PTT key to hold. None (default) auto-detects from
                  EnviousWispr's UserDefaults `toggleKeyCode`. Override with
                  'rcmd', 'lcmd', 'lopt', 'ropt' to force a key.
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

    # Resolve PTT key from app settings if caller didn't override. See test_ptt:
    # both paths refuse rather than press an unverified key (#1997), and the
    # explicit-key path still requires push-to-talk mode.
    if key is None:
        binding = resolve()
        key = binding.key_name
        print(f"PTT key auto-detected from settings: {key} (keycode {binding.keycode})")
    else:
        require_push_to_talk()

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


def _self_test():
    """Control for the single-instance guard - a HARNESS CONTRACT test.

    It protects the INSTRUMENT and says nothing about whether hands-free works
    (testing-philosophy.md RULE: every-test-declares-which-of-four-things-it-protects).

    NOTHING RUNS THIS AUTOMATICALLY, stated rather than implied because a suite no
    gate invokes reports nothing. The sibling `--self-test` modules that CI does
    run (`ptt_binding.py`, `faultInjection.py`) are wired in on the stated grounds
    that "neither module imports Quartz". This one does, transitively through
    `ui_helpers`, so wiring it to the required check would rest on an untested
    assumption about the hosted runner's PyObjC - and a CI addition that fails
    reddens the required check for everybody. Run it by hand:

        python3 Tests/RuntimeUAT/wispr_eyes.py --self-test

    Every row drives the real function with an injected `ps` table, and the set is
    two-way: three rows must REFUSE and two must PASS, so a guard that stopped
    classifying anything fails here rather than looking clean.
    """
    import types, pathlib, shutil
    real_run = subprocess.run
    me = str(os.getpid())

    def fake(rows):
        def _run(cmd, *a, **k):
            if list(cmd[:1]) == ["ps"]:
                return types.SimpleNamespace(stdout="\n".join(rows), returncode=0)
            return real_run(cmd, *a, **k)
        return _run

    ONE = ["  111 /Users/x/EW/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"]
    cases = [
        ("one dev instance", ONE, 1, True),
        ("two dev instances", ONE + [
            "  222 /Users/x/wt/.derivedData/Dev/Build/Products/Dev/EnviousWispr Local.app"
            "/Contents/MacOS/EnviousWispr"], 2, False),
        # The Release test host carries the PRODUCTION bundle id and answers the same
        # global hotkey, and a pattern scoped to `EnviousWispr Local.app` cannot see
        # it - which is the instance you most want counted.
        ("dev + Release test host", ONE + [
            "  333 /Users/x/wt/.derivedData/Release/Build/Products/Release/EnviousWispr.app"
            "/Contents/MacOS/EnviousWispr"], 2, False),
        # The probe's own argv carries `EnviousWispr` (a worktree path) AND
        # `.app/Contents/MacOS/` (it runs under Python.app). A command-line
        # substring test finds itself; excluding `python3` does not help, because
        # the interpreter's binary is named `Python`.
        ("one instance + this probe's own argv", ONE + [
            f"  {me} /opt/homebrew/Frameworks/Python.framework/Versions/3.13/Resources"
            f"/Python.app/Contents/MacOS/Python -u /tmp/EnviousWispr/probe.py"], 1, True),
        # The row above does NOT bind the pid exclusion, and a mutant proved it: a
        # Python probe's executable is `.../Python`, which the basename test
        # already rejects, so removing `if pid == me` left the self-test green.
        # This row is the one that binds it - our own pid wearing an executable
        # the basename test WOULD accept. Contrived as a process, exact as a
        # requirement: the two mechanisms answer different questions ("is this an
        # EnviousWispr app" and "is this me"), and only this row can tell whether
        # the second one is still there.
        ("our own pid wearing a matching executable", ONE + [
            f"  {me} /Users/x/EW/build/EnviousWispr Local.app"
            f"/Contents/MacOS/EnviousWispr"], 1, True),
        ("no instance at all", ["  999 /usr/bin/vim"], 0, False),
        # A worktree or parent directory may legally contain " - ". An earlier
        # version recovered the executable by splitting `command` on the first
        # `" -"`, which truncates this to `/Users/x/EW` and drops the instance -
        # a real second app going uncounted, which is the one failure this guard
        # exists to prevent. Reading `comm` removes the parse entirely; this row
        # is what stops anyone reintroducing one.
        ("a path containing a space-hyphen is still counted", ONE + [
            "  444 /Users/x/EW - issue/build/EnviousWispr Local.app"
            "/Contents/MacOS/EnviousWispr"], 2, False),
        # Same bundle, sibling executables. `comm` lists them, and an EXACT
        # suffix is what keeps them out of the count; a substring test would
        # treble every instance.
        ("the app's own XPC service and llama-server are not instances", ONE + [
            "  555 /Users/x/EW/build/EnviousWispr Local.app/Contents/XPCServices"
            "/EnviousWisprASRService.xpc/Contents/MacOS/EnviousWisprASRService",
            "  556 /Users/x/EW/build/EnviousWispr Local.app/Contents/Resources"
            "/llama-server"], 1, True),
    ]

    failures = []
    for name, rows, want_n, want_pass in cases:
        subprocess.run = fake(rows)
        try:
            n = len(running_enviouswispr_instances())
            got_pass = _require_single_instance("self-test") is not None
        finally:
            subprocess.run = real_run
        if n != want_n or got_pass != want_pass:
            failures.append(f"{name}: count={n} (want {want_n}), "
                            f"guard={'PASS' if got_pass else 'REFUSED'} "
                            f"(want {'PASS' if want_pass else 'REFUSED'})")
        else:
            print(f"  ok      {name}")

    # The banner counter's PURE half, driven with synthetic text. This is where
    # the two review findings on the log side live: a banner written before
    # anyone took a cursor, and a banner carried into a rotated file.
    T0 = _dt.datetime.fromisoformat("2026-01-01T12:00:00-05:00")
    def banner_at(when):
        return f"[{when}] [INFO] {_LAUNCH_BANNER}"
    banner_cases = [
        ("a banner BEFORE the window is not counted",
         [banner_at("2026-01-01T11:59:59-05:00")], 0),
        ("a banner AFTER the window is counted",
         [banner_at("2026-01-01T12:00:01-05:00")], 1),
        # The rotation finding: the banner sits in a PREDECESSOR while every
        # marker that follows it lands in the new `app.log`. A cursor that
        # follows the inode reads the new file only and sees a complete-looking
        # slice with the banner missing.
        ("a banner in a ROTATED predecessor is still counted",
         ["nothing here", banner_at("2026-01-01T12:00:02-05:00")], 1),
        ("a banner exactly AT the window start is counted",
         [banner_at("2026-01-01T12:00:00-05:00")], 1),
        # A different UTC offset must compare correctly rather than
        # lexicographically - 17:00:01Z is 12:00:01-05:00, inside the window.
        ("a banner written under a different UTC offset compares by INSTANT",
         [banner_at("2026-01-01T17:00:01+00:00")], 1),
        ("an unparseable stamp is not counted and does not raise",
         ["[not-a-date] [INFO] " + _LAUNCH_BANNER], 0),
        ("an ordinary line is not a banner",
         ["[2026-01-01T12:00:01-05:00] [INFO] [Pipeline] Recording started."], 0),
    ]
    # THE ROW THE SELF-TEST DID NOT HAVE, and a live run is what found the gap.
    # `AppLogger` stamps to the SECOND while `datetime.now()` carries microseconds,
    # so a line written a fraction of a second after the window opened compares as
    # before it. Every row above uses a whole-second start, which is exactly why
    # 22/22 stayed green while the per-attempt check reported "did not register"
    # against a log containing all three markers.
    T_SUB = _dt.datetime.fromisoformat("2026-01-01T12:00:00.500000-05:00")
    banner_rows_extra = 0
    name = "a line stamped in the same SECOND the window opened is in-window"
    got_sub = count_launch_banners([banner_at("2026-01-01T12:00:00-05:00")], T_SUB)
    if got_sub != 1:
        failures.append(f"{name}: counted {got_sub}, want 1")
    else:
        print(f"  ok      {name}")
    banner_rows_extra += 1
    for name, texts, want in banner_cases:
        got = count_launch_banners(texts, T0)
        if got != want:
            failures.append(f"{name}: counted {got}, want {want}")
        else:
            print(f"  ok      {name}")

    # The FILE half of the banner scan, which the rows above cannot reach: they
    # drive the pure counter with a list of texts and never touch the loop that
    # decides WHICH files get read. A mutant proved it - dropping the rotated
    # predecessors from that loop survived every row above, because none of them
    # opens a file.
    #
    # `_APP_LOG_PATH` is rebound in-process rather than made a parameter. A
    # directory argument would let any caller aim this guard at an empty folder
    # and be handed a clean verdict, which is a bypass wearing a test seam's
    # clothes; a module global that only an in-process test can rebind is not
    # reachable from a call site at all. Same technique as the `subprocess.run`
    # stub above.
    import tempfile as _tf
    real_log_path = _APP_LOG_PATH
    tmpdir = _tf.mkdtemp()
    try:
        pathlib.Path(tmpdir, "app.log").write_text(
            "[2026-01-01T12:00:05-05:00] [INFO] [Pipeline] Recording started.\n")
        # The rotation case exactly: the banner is in the PREDECESSOR while every
        # marker that follows it lands in the new `app.log`.
        pathlib.Path(tmpdir, "app.1.log").write_text(
            banner_at("2026-01-01T12:00:01-05:00") + "\n")
        globals()["_APP_LOG_PATH"] = str(pathlib.Path(tmpdir, "app.log"))
        got = launch_banners_since(T0)
    finally:
        globals()["_APP_LOG_PATH"] = real_log_path
        shutil.rmtree(tmpdir, ignore_errors=True)
    name = "a banner that rotation moved into app.1.log is still read off disk"
    if got != 1:
        failures.append(f"{name}: counted {got}, want 1")
    else:
        print(f"  ok      {name}")
    file_rows = 1

    # THE ONE READER, ordered. Three review rounds produced a rotation finding at
    # three different call sites, so what is asserted here is the property that
    # made them one bug: history survives a rename, and it comes back in the order
    # it was written.
    real_log_path = _APP_LOG_PATH
    tmpdir = _tf.mkdtemp()
    try:
        pathlib.Path(tmpdir, "app.2.log").write_text(
            "[2026-01-01T12:00:01-05:00] [INFO] oldest\n")
        pathlib.Path(tmpdir, "app.1.log").write_text(
            "[2026-01-01T11:59:59-05:00] [INFO] before the window\n"
            "[2026-01-01T12:00:02-05:00] [INFO] middle\n")
        pathlib.Path(tmpdir, "app.log").write_text(
            "[2026-01-01T12:00:03-05:00] [INFO] newest\n")
        globals()["_APP_LOG_PATH"] = str(pathlib.Path(tmpdir, "app.log"))
        got_lines = log_lines_since(T0)
    finally:
        globals()["_APP_LOG_PATH"] = real_log_path
        shutil.rmtree(tmpdir, ignore_errors=True)
    name = "the reader returns rotated history oldest-first and drops pre-window lines"
    tails = [l.split("] ")[-1] for l in got_lines]
    if tails != ["oldest", "middle", "newest"]:
        failures.append(f"{name}: got {tails}")
    else:
        print(f"  ok      {name}")
    file_rows += 1

    # The merge that replaced three attempts to CHOOSE a pass.
    for name, args, want in [
        ("identical passes merge to themselves",
         (["a", "b"], ["a", "b"]), ["a", "b"]),
        # The rotation case: the SECOND pass is the incomplete one, and a
        # differing inode map is what used to select exactly it.
        ("a pass missing a line still contributes the others",
         (["a", "b"], ["b", "c"]), ["a", "b", "c"]),
        # The APPEND case, which no inode comparison can see: the app wrote a
        # marker between the passes, so the second has a line the first does not
        # and both inode maps are identical. Keeping the first pass here hides a
        # late marker and licenses a destructive retry.
        ("a line appended between passes is kept",
         (["a"], ["a", "late-marker"]), ["a", "late-marker"]),
        ("the union keeps first-seen order and drops duplicates",
         (["x", "y"], ["y", "x", "z"]), ["x", "y", "z"]),
    ]:
        got_merge = _merge_sweeps(*args)
        if got_merge != want:
            failures.append(f"{name}: got {got_merge}, want {want}")
        else:
            print(f"  ok      {name}")
        file_rows += 1

    # THE RETRY'S ORACLE. `HotkeyService.swift:673` says in as many words that
    # `Double press` records the REQUEST and "whether it becomes a lock is not
    # known yet", and `publishLockIfReady` can answer `.notLockable` and clean
    # up. So a window carrying the request and NOT the activation is a gesture
    # that did not lock, and declaring success on it means the caller reports
    # `Recording did not start` for a helper that just said it engaged.
    presses = []
    real_press = globals()["press_record_key"]
    real_reader = globals()["log_lines_since"]
    real_sleep = time.sleep
    globals()["press_record_key"] = lambda: presses.append(1)
    globals()["log_lines_since"] = lambda *_a, **_k: [
        "[2026-01-01T12:00:01-05:00] [INFO] [HotkeyService] Double press "
        "- requesting hands-free mode"]
    time.sleep = lambda *_a, **_k: None
    try:
        request_only = double_press_record_key(attempts=2)
    finally:
        globals()["press_record_key"] = real_press
        globals()["log_lines_since"] = real_reader
        time.sleep = real_sleep
    name = "the request marker alone is not a lock, so it does not end the retry"
    if request_only or len(presses) != 4:
        failures.append(f"{name}: engaged={request_only}, presses={len(presses)}; "
                        f"want engaged=False and 4 presses across 2 attempts")
    else:
        print(f"  ok      {name}")
    file_rows += 1

    # A REFUSAL MUST NOT LEAVE A RECORDING RUNNING. Reached only after the
    # gesture has locked hands-free, so an early return leaves the app recording
    # indefinitely - the Escape Recovery UAT did exactly this on 2026-08-18 and
    # the founder ended it by hand.
    stops = []
    real_stop = globals()["single_press_record_key"]
    real_sleep = time.sleep
    globals()["single_press_record_key"] = lambda: stops.append(1)
    time.sleep = lambda *_a, **_k: None
    try:
        stop_after_short_hold(0.2)
    finally:
        globals()["single_press_record_key"] = real_stop
        time.sleep = real_sleep
    name = "refusing a short hold still stops the recording it locked"
    if len(stops) != 1:
        failures.append(f"{name}: {len(stops)} stop presses, want 1")
    else:
        print(f"  ok      {name}")
    file_rows += 1


    # `instances_stayed_single` answers a question no snapshot pair can: did one
    # instance own the WHOLE window. Rows 2 and 3 are the review finding that
    # produced it - an app that starts after the opening check and exits before
    # the closing one leaves both endpoints identical.
    BEFORE = {"111": "/Users/x/EW/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"}
    OTHER = dict(BEFORE, **{"222": "/Users/y/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"})
    window_cases = [
        ("a quiet window is single", BEFORE, 0, [BEFORE, BEFORE], True),
        ("a sample catching a second instance is not single",
         BEFORE, 0, [BEFORE, OTHER, BEFORE], False),
        ("a launch banner in the window is not single, even with every "
         "sample clean", BEFORE, 1, [BEFORE, BEFORE], False),
        ("a replaced instance is not single (same COUNT, different pid)",
         BEFORE, 0, [BEFORE, {"999": BEFORE["111"]}], False),
    ]
    real_count = globals()["launch_banners_since"]
    for name, before, banners, samples, want_ok in window_cases:
        globals()["launch_banners_since"] = lambda _start, _n=banners: _n
        try:
            ok, _why = instances_stayed_single(before, T0, samples)
        finally:
            globals()["launch_banners_since"] = real_count
        if ok != want_ok:
            failures.append(f"{name}: got {'single' if ok else 'NOT single'}, "
                            f"want {'single' if want_ok else 'NOT single'}")
        else:
            print(f"  ok      {name}")

    total = (len(cases) + len(banner_cases) + banner_rows_extra + file_rows
             + len(window_cases))
    if failures:
        for f in failures:
            print(f"  FAIL    {f}")
        print(f"\nwispr_eyes self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\nwispr_eyes self-test: {total}/{total} passed")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    print("wispr_eyes is a library. Run `--self-test` for the harness control, "
          "or import it from a REPL/script for UAT.")
    sys.exit(2)
