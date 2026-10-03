"""settings_nav: the ONE owner of Settings navigation for the runtime harness (#3385).

Every caller that drives the Settings window goes through here: `wispr_eyes.nav/check/look/
verify/scan/switch_backend`, `uat_runner`, the scenario drivers and the microphone helpers.
It holds the route table (pages, the Dictation Settings tabs, the one action row), resolves a
row inside the SIDEBAR and a tab inside the TAB STRIP (never a whole-app fuzzy match), presses,
and then proves the requested page and tab are the selected ones by reading the tree again.

PyObjC-free on purpose. It reads the accessibility tree only through an `AX` adapter, so the
offline self-test drives the real implementation with dictionary trees and stubbed presses:

    python3 Tests/RuntimeUAT/settings_nav.py --self-test

A green self-test certifies the instrument against MODELLED trees. It says nothing about the
real app's accessibility topology; that is the live UAT's job.
"""
import time

# ── Route table ────────────────────────────────────────────────────────────

# Final release sidebar. Updates are in a toolbar popover, never a page.
PAGES = (
    "History", "Dictation Settings", "Keybinds", "Transcribe a File",
    "AI Polish", "Dictionary", "Snippets", "App Settings",
)
DEBUG_PAGES = ("Diagnostics",)
ACTION_ROWS = ()
GIFT_CAPTION = "What's New & Updates"
TABS = {
    "Dictation Settings": (
        "Engine", "Microphone & Media", "Live Preview", "Recording Pill", "Chimes", "Clipboard",
    ),
    "App Settings": ("Appearance", "Permissions", "Privacy", "Licenses"),
}
SIDEBAR_LABELS = PAGES


class RouteError(ValueError):
    """The caller asked for a route that does not exist. Raised BEFORE any UI action."""


class NavigationError(RuntimeError):
    """The route exists but the window did not land on it, or the tree could not tell."""


class ControlError(NavigationError):
    """A control is present but broken: its row has no control of the right kind, two
    candidates, or an unreadable value. FAIL, never BLOCKED and never OK."""


def validate_route(page, tab=None, debug_build=None):
    """Check a (page, tab) request against the route table. Returns it unchanged.

    `debug_build` False refuses the DEBUG-only page; None (unknown) lets it through, and the
    sidebar lookup then decides, so an unknown build never pretends the page is absent.
    """
    if page is None:
        if tab is not None:
            raise RouteError(f"tab {tab!r} needs its page; pass nav(page, tab)")
        raise RouteError("no page given")
    if page in ACTION_ROWS:
        raise RouteError(f"{page!r} is an action row, not a page; it never selects anything")
    if page in DEBUG_PAGES:
        if debug_build is False:
            raise RouteError(f"{page!r} exists only in a DEBUG build")
    elif page not in PAGES:
        raise RouteError(f"unknown page {page!r}; pages are {list(PAGES)} "
                         f"(+ {list(DEBUG_PAGES)} in DEBUG)")
    if tab is not None:
        tabs = TABS.get(page)
        if not tabs:
            raise RouteError(f"{page!r} has no tabs; drop tab={tab!r}")
        if tab not in tabs:
            raise RouteError(f"{page!r} has no tab {tab!r}; tabs are {list(tabs)}")
    return page, tab


# ── Reading the tree ───────────────────────────────────────────────────────

class AX:
    """How this module touches the accessibility tree. Every operation is injected."""

    def __init__(self, get_attr, children, press, frame=None,
                 terms=None, sleep=time.sleep, clock=time.monotonic, same=None):
        self.get_attr = get_attr
        self.children = children
        self.press = press
        self.frame = frame or (lambda el: None)
        # English name -> [English, and what the app shows for it in each shipped language]
        self.terms = terms or (lambda text: [text])
        self.sleep = sleep
        self.clock = clock
        self.same = same or (lambda a, b: a is b or a == b)

    def text(self, el, attr):
        v = self.get_attr(el, attr)
        return v.strip() if isinstance(v, str) and v.strip() else ""

    def role(self, el):
        return self.get_attr(el, "AXRole") or ""

    def label_names(self, el):
        """A control's NAME: AXTitle and AXDescription. AXValue is left out on purpose: on a
        sidebar row or a tab it holds the selection state ("Not selected"), never the name."""
        return [t for t in (self.text(el, "AXTitle"), self.text(el, "AXDescription")) if t]

    def walk(self, el, depth=0, max_depth=60, skip=None):
        if el is None or depth > max_depth:
            return
        if skip is not None and any(self.same(el, s) for s in skip):
            return
        yield el
        for c in self.children(el) or []:
            yield from self.walk(c, depth + 1, max_depth, skip)


def _labelled(ax, el, english, role="AXButton"):
    if role is not None and ax.role(el) != role:
        return False
    wanted = [t.lower() for t in ax.terms(english)]
    return any(n.lower() in wanted for n in ax.label_names(el))


def selection_state(ax, value):
    """True for "Selected" (alone or "Selected. <activity>"), False for "Not selected" (likewise),
    None when the value says neither. Compares the WHOLE first clause, in every shipped
    language: "Not selected" contains "selected", so a substring test would read it as chosen."""
    if not isinstance(value, str) or not value.strip():
        return None
    head = value.strip().split(". ", 1)[0].strip().rstrip(".").lower()
    if head in [t.lower() for t in ax.terms("Not selected")]:
        return False
    if head in [t.lower() for t in ax.terms("Selected")]:
        return True
    return None


def _minimal_region(ax, root, required, skip=None):
    """The smallest subtree holding a button for EVERY label in `required`.

    Exactly one such subtree, or NavigationError: none means the region is not on screen,
    more than one means the tree is ambiguous and choosing would be a guess.
    """
    candidates = []

    def visit(el, depth=0):
        if depth > 60:
            return set()
        if skip is not None and any(ax.same(el, s) for s in skip):
            return set()
        found = {label for label in required if _labelled(ax, el, label)}
        child_hit = False
        for c in ax.children(el) or []:
            sub = visit(c, depth + 1)
            if sub is True:
                child_hit = True
                continue
            found |= sub
        if child_hit:
            return True
        if found >= set(required):
            candidates.append(el)
            return True
        return found

    visit(root)
    if not candidates:
        raise NavigationError(f"no region holds all of {list(required)}")
    if len(candidates) > 1:
        raise NavigationError(f"{len(candidates)} regions each hold all of {list(required)}; "
                              "refusing to choose")
    return candidates[0]


def sidebar(ax, root):
    """The Settings sidebar: the one subtree holding every page row and the update row."""
    return _minimal_region(ax, root, SIDEBAR_LABELS)


def tab_strip(ax, root, page, side=None):
    """The tab strip of a tabbed page, outside the sidebar."""
    return _minimal_region(ax, root, TABS[page], skip=[side] if side is not None else None)


def unique_control(ax, region, english, role="AXButton", skip=None):
    """The one control in `region` named `english` (or its translation). 0 or 2+ refuse."""
    hits = [el for el in ax.walk(region, skip=skip) if _labelled(ax, el, english, role)]
    if not hits:
        raise NavigationError(f"{english!r} ({role}) not found in its region")
    if len(hits) > 1:
        raise NavigationError(f"{len(hits)} controls named {english!r} ({role}) in one region; "
                              "refusing to choose")
    return hits[0]


def content_controls(ax, root, english, role="AXButton"):
    """Every control named `english` in the window's CONTENT (the sidebar excluded)."""
    side = sidebar(ax, root)
    return [el for el in ax.walk(root, skip=[side]) if _labelled(ax, el, english, role)]


def wait_until(ax, check, timeout, what):
    """Poll `check` (which may raise NavigationError while the tree settles) until it is
    true. A deadline, never a delay used as proof: the answer is the observed state."""
    deadline = ax.clock() + timeout
    last = None
    while True:
        try:
            if check():
                return True
        except NavigationError as e:
            last = e
        if ax.clock() >= deadline:
            raise NavigationError(f"{what}: not observed within {timeout:.1f}s"
                                  + (f" ({last})" if last else ""))
        ax.sleep(0.15)  # settle: poll interval inside a bounded wait for an observed state


def _path_to(ax, root, target):
    """The elements from `root` down to `target`, both included, or None."""
    def visit(el, path, depth):
        if depth > 60:
            return None
        path = path + [el]
        if ax.same(el, target):
            return path
        for c in ax.children(el) or []:
            found = visit(c, path, depth + 1)
            if found:
                return found
        return None
    return visit(root, [], 0)


def _intersect(a, b):
    x0, y0 = max(a["x"], b["x"]), max(a["y"], b["y"])
    x1 = min(a["x"] + a["width"], b["x"] + b["width"])
    y1 = min(a["y"] + a["height"], b["y"] + b["height"])
    return {"x": x0, "y": y0, "width": max(0.0, x1 - x0), "height": max(0.0, y1 - y0)}


def _visible_rect(ax, root, el):
    """The part of the window `el` can be seen through: the window's frame clipped by every
    scroll viewport (AXScrollArea) above `el`. A plain group's frame is NOT a viewport: a
    wrapped strip's group can include content outside an ancestor viewport."""
    path = _path_to(ax, root, el)
    if not path:
        raise NavigationError("the control is not in the tree it was found in")
    clips = [p for p in path[:-1] if ax.role(p) in ("AXWindow", "AXScrollArea")]
    if not clips:
        raise NavigationError("no window or scroll viewport above the control")
    rect = None
    for p in clips:
        f = ax.frame(p)
        if not f:
            raise NavigationError("cannot read a viewport frame that says whether a tab is on screen")
        rect = f if rect is None else _intersect(rect, f)
    return rect


def _visible_within(ax, el, root):
    """Whether all of `el` lies inside its visible viewport (`_visible_rect`)."""
    f = ax.frame(el)
    if not f:
        raise NavigationError("cannot read the frame that says whether a tab is on screen")
    r = _visible_rect(ax, root, el)
    return (f["width"] > 0 and f["height"] > 0 and f["x"] >= r["x"] - 0.5 and f["x"] + f["width"] <= r["x"] + r["width"] + 0.5
            and f["y"] >= r["y"] - 0.5 and f["y"] + f["height"] <= r["y"] + r["height"] + 0.5)


class Route:
    def __init__(self, page, tab, shown_tab):
        self.page, self.tab, self.shown_tab = page, tab, shown_tab

    def __repr__(self):
        return f"Route({self.page!r}, tab={self.tab!r}, shown_tab={self.shown_tab!r})"


def current_tab(ax, root, page):
    """Which tab of `page` reports itself selected, or None when the tree cannot say."""
    side = sidebar(ax, root)
    strip = tab_strip(ax, root, page, side)
    chosen = [t for t in TABS[page]
              if selection_state(ax, ax.get_attr(unique_control(ax, strip, t), "AXValue")) is True]
    return chosen[0] if len(chosen) == 1 else None


def navigate(ax, root_of, page, tab=None, open_settings=None, timeout=3.0, debug_build=None):
    """Select `page` in the sidebar and, when given, `tab` in its strip, and PROVE both.

    `root_of()` returns the current tree root (re-read after every press). A press's own return
    value is never the verdict: plain SwiftUI buttons can report an error and still fire, or
    report success and do nothing, so success is the row (and tab) reading Selected afterwards.
    With no `tab`, the page keeps whichever tab the app remembers; `shown_tab` reports it.
    """
    validate_route(page, tab, debug_build)

    def side_row():
        root = root_of()
        return root, sidebar(ax, root)

    try:
        root, side = side_row()
    except NavigationError:
        if open_settings is None:
            raise
        open_settings()
        wait_until(ax, lambda: side_row() is not None, timeout, "the Settings sidebar")
        root, side = side_row()

    row = unique_control(ax, side, page)
    if selection_state(ax, ax.get_attr(row, "AXValue")) is not True:
        pressed = ax.press(row)

        def page_landed():
            root2, side2 = side_row()
            return selection_state(ax, ax.get_attr(unique_control(ax, side2, page), "AXValue")) is True
        try:
            wait_until(ax, page_landed, timeout, f"page {page!r} selected")
        except NavigationError as e:
            raise NavigationError(f"{e} (the press itself reported {pressed!r})") from None

    if page not in TABS:
        return Route(page, None, None)

    def strip_buttons():
        root2 = root_of()
        side2 = sidebar(ax, root2)
        strip = tab_strip(ax, root2, page, side2)
        return root2, {name: unique_control(ax, strip, name) for name in TABS[page]}

    wait_until(ax, lambda: strip_buttons() is not None, timeout, f"the {page!r} tab strip")
    def visible_buttons():
        root2, buttons2 = strip_buttons()
        # Founder 2026-10-02 (#3385): every tab wraps into view. An offscreen tab is
        # a layout failure, never something AXScrollToVisible may rescue.
        for name, candidate in buttons2.items():
            if not _visible_within(ax, candidate, root2):
                raise NavigationError(f"wrapped tab {name!r} is clipped outside its viewport")
        return root2, buttons2

    root, buttons = visible_buttons()
    if tab is None:
        # The remembered tab must be exactly ONE selected tab: none or two selected is a
        # strip the harness cannot read, never a success with an unknown tab.
        shown = {}

        def remembered_landed():
            selected = current_tab(ax, visible_buttons()[0], page)
            if selected is None:
                return False
            shown["tab"] = selected
            return True
        wait_until(ax, remembered_landed, timeout, "exactly one selected tab")
        return Route(page, None, shown["tab"])

    def strip_and_tab():
        root2, buttons2 = visible_buttons()
        return root2, buttons2[tab]

    button = buttons[tab]
    if selection_state(ax, ax.get_attr(button, "AXValue")) is not True:
        pressed = ax.press(button)

        def tab_landed():
            _, b = strip_and_tab()
            return selection_state(ax, ax.get_attr(b, "AXValue")) is True
        try:
            wait_until(ax, tab_landed, timeout, f"tab {tab!r} selected")
        except NavigationError as e:
            raise NavigationError(f"{e} (the press itself reported {pressed!r})") from None
    # Selected is not enough: no OTHER tab may read Selected too.
    wait_until(ax, lambda: current_tab(ax, visible_buttons()[0], page) == tab, timeout,
               f"exactly tab {tab!r} selected")
    return Route(page, tab, tab)


def _gift_heading(ax, el):
    """The dropdown's "What's New" title; SwiftUI exposes it as AXHeading (it is a header)."""
    return (ax.role(el) in ("AXHeading", "AXStaticText")
            and _labelled(ax, el, "What's New", role=None))


def open_gift(ax, root_of, timeout=3.0):
    """Open the toolbar gift and require its OWN popover heading and both footer actions.
    Never checks for updates or follows the release link. Returns the presented popover.
    """
    root = root_of()
    toolbars = [e for e in ax.walk(root) if ax.role(e) == "AXToolbar"
                and any(_labelled(ax, c, GIFT_CAPTION) for c in ax.walk(e))]
    if len(toolbars) != 1:
        raise NavigationError(f"{len(toolbars)} toolbars contain the gift caption; refusing to choose")
    toolbar = toolbars[0]
    feedback = [e for e in ax.walk(toolbar) if any(_labelled(ax, e, label) for label in
                ("Send feedback", "Send feedback: your message is waiting"))]
    if len(feedback) != 1:
        raise NavigationError("the gift toolbar does not contain exactly one Feedback control")
    opener = unique_control(ax, toolbar, GIFT_CAPTION)
    before = [e for e in ax.walk(root) if ax.role(e) == "AXPopover"]
    # An already-open gift dropdown is reused (pressing again would toggle it shut), so
    # gift(True) then gift(False) can close what the first call opened.
    existing = [p for p in before
                if any(_gift_heading(ax, e) for e in ax.walk(p))]
    if len(existing) > 1:
        raise NavigationError("multiple gift popovers; refusing to choose")
    if not existing:
        # Opening marks the notes read in the app's real saved settings, and nothing
        # here can put the unread state back, so an unread gift is never opened.
        if ax.text(opener, "AXValue") not in ax.terms("No new release notes"):
            raise NavigationError(
                "the gift has unread release notes; opening it would mark them read. "
                "Open it by hand first, or run with isolated settings")
        ax.press(opener)
    found = {}

    def landed():
        pops = [e for e in ax.walk(root_of()) if ax.role(e) == "AXPopover"
                and (any(ax.same(e, p) for p in existing)
                     or not any(ax.same(e, old) for old in before))]
        if len(pops) != 1:
            return False
        pop = pops[0]
        if not any(_gift_heading(ax, e) for e in ax.walk(pop)):
            return False
        unique_control(ax, pop, "Check for Updates…")
        links = [e for e in ax.walk(pop) if ax.role(e) in ("AXLink", "AXButton")
                 and _labelled(ax, e, "All release notes on GitHub", role=None)]
        if len(links) != 1:
            return False
        found["popover"] = pop
        return True

    wait_until(ax, landed, timeout, "the What's New dropdown and its footer")
    return found["popover"]


# ── Engine choices (Dictation Settings > Engine) ───────────────────────────

CHANGE_ENGINE = "Change speech engine"
ENGINE_LABELS = ("Fast", "All Languages")


def _summary_names(ax, root, label):
    """Non-button text in the content that STARTS with the engine's name: the collapsed
    summary reads "<name>, <model>, <line>" (one combined element)."""
    side = sidebar(ax, root)
    wanted = [t.lower() for t in ax.terms(label)]
    for el in ax.walk(root, skip=[side]):
        if ax.role(el) == "AXButton":
            continue
        for attr in ("AXTitle", "AXDescription", "AXValue"):
            t = ax.text(el, attr).lower()
            if any(t == w or t.startswith(w + ",") or t.startswith(w + " ") for w in wanted):
                return True
    return False


def choose_engine(ax, root_of, label, timeout=5.0):
    """On Dictation Settings > Engine: open "Change speech engine" (never the preview engine's or
    the language's Change), press `label`'s card, then require the choices to close and the
    summary to name `label`. Starts no download: a card press only selects."""
    if label not in ENGINE_LABELS:
        raise RouteError(f"unknown engine {label!r}; engines are {list(ENGINE_LABELS)}")
    root = root_of()
    cards = content_controls(ax, root, label)
    if not cards:
        change = content_controls(ax, root, CHANGE_ENGINE)
        if len(change) != 1:
            raise NavigationError(f"{len(change)} {CHANGE_ENGINE!r} buttons; refusing to choose")
        ax.press(change[0])
        wait_until(ax, lambda: len(content_controls(ax, root_of(), label)) == 1, timeout,
                   "the engine choices open")
        cards = content_controls(ax, root_of(), label)
    if len(cards) != 1:
        raise NavigationError(f"{len(cards)} {label!r} engine cards; refusing to choose")
    ax.press(cards[0])

    def collapsed_on_label():
        r = root_of()
        return (not content_controls(ax, r, label)
                and len(content_controls(ax, r, CHANGE_ENGINE)) == 1
                and _summary_names(ax, r, label))
    wait_until(ax, collapsed_on_label, timeout, f"the engine summary naming {label!r}")
    return True


# ── The app's stored settings ──────────────────────────────────────────────

# Both builds read and write ONE preference domain, `com.enviouswispr.app`: the dev build
# redirects there (`SettingsDefaults.store`, Sources/EnviousWisprServices/SettingsDefaults.swift).
# The connected bundle's own domain (`com.enviouswispr.app.dev`) holds only pre-#923 leftovers,
# so reading it reads a value the app ignores. `ptt_binding.read_domain()` owns exporting the
# domain; this owns reading the keys the Settings harness needs the way `SettingsManager`
# loads them.

class PreferenceError(RuntimeError):
    """A stored setting could not be read, or holds a value the harness cannot interpret."""


# key -> (kind, allowed raw values or None, the shipped default). Defaults mirror
# `SettingsDefaultValues.swift`, enum values mirror their Swift enums' cases; the self-test
# checks both against the Swift source.
STORED = {
    "selectedBackend": ("enum", ("parakeet", "whisperKit"), "parakeet"),
    "llmProvider": ("enum", ("openAI", "gemini", "claude", "ollama", "appleIntelligence",
                             "egOne", "s1Mini", "none"), "appleIntelligence"),
    "wordCorrectionEnabled": ("bool", None, True),
    "fillerRemovalEnabled": ("bool", None, True),
    "preferredInputDeviceIDOverride": ("string", None, ""),
    "vadAutoStop": ("bool", None, False),
    "livePreviewEngine": ("enum", ("apple", "universal"), "apple"),
}


def stored(read_domain, key):
    """The value the app uses for `key`. `read_domain()` returns the exported domain (a dict;
    `{}` when nothing is stored) or raises. A missing key is the shipped default, an enum
    string the app does not know is the default too (`SettingsManager` falls back the same
    way), and any other type REFUSES: guessing a restore value is how a run overwrites
    someone's setting with the wrong one."""
    if key not in STORED:
        raise KeyError(f"{key!r} is not a stored setting this harness reads")
    kind, allowed, default = STORED[key]
    try:
        domain = read_domain()
    except Exception as e:  # noqa: BLE001 - every read failure is one refusal
        raise PreferenceError(f"{key}: the preference domain could not be read ({e})") from e
    if not isinstance(domain, dict):
        raise PreferenceError(f"{key}: the preference domain is not a dictionary")
    if key not in domain:
        return default
    value = domain[key]
    if kind == "bool":
        if isinstance(value, bool):
            return value
        raise PreferenceError(f"{key}: {value!r} is not a stored Bool")
    if not isinstance(value, str):
        raise PreferenceError(f"{key}: {value!r} is not a stored String")
    if kind == "enum":
        return value if value in allowed else default
    return value


# ── The microphone menu (Dictation Settings > Microphone & Media) ──────────

INPUT_DEVICE = "Input device"
INPUT_KEY = "preferredInputDeviceIDOverride"
_INPUT_ROLES = ("AXMenuButton", "AXPopUpButton", "AXButton")
# `MicrophoneDevicePresentation.transportBadge` and `MicrophoneDevicePicker.placeholder`.
TRANSPORT_BADGES = ("Built-in", "USB", "Bluetooth")
INPUT_PLACEHOLDER = "Choose a microphone"


class InputChoice:
    """The app's STORED microphone choice: Auto (`uid == ""`) or the device with that UID,
    read from the preference `preferredInputDeviceIDOverride`, never from display text.
    `shown` is the device name the control displays (for Auto, the device Auto resolved to;
    None when it shows no name). Two choices are the same choice when their UIDs match."""

    def __init__(self, uid, shown):
        if not isinstance(uid, str):
            raise PreferenceError(f"a microphone choice needs its stored UID, got {uid!r}")
        self.uid, self.shown = uid, shown

    @property
    def auto(self):
        return self.uid == ""

    def same_choice(self, other):
        return isinstance(other, InputChoice) and self.uid == other.uid

    def __eq__(self, other):
        return isinstance(other, InputChoice) and (self.uid, self.shown) == (other.uid, other.shown)

    def __repr__(self):
        return f"InputChoice({'Auto' if self.auto else 'uid=' + repr(self.uid)}, shown={self.shown!r})"

    def to_json(self):
        return {"uid": self.uid, "shown": self.shown}

    @classmethod
    def from_json(cls, data):
        """Refuses a record without a UID (the pre-#3385 format kept only display text, which
        cannot say which device a named choice was)."""
        if not isinstance(data, dict) or "uid" not in data:
            raise PreferenceError(f"a saved microphone choice without its UID: {data!r}")
        return cls(data["uid"], data.get("shown"))


def _lowered(ax, words):
    return {t.lower() for w in words for t in ax.terms(w)}


def display_candidates(ax, value, auto):
    """The device names the control's value can mean, given whether the STORED choice is Auto.

    The value is "<name or placeholder>[, <detail>]" (`MicrophoneDevicePicker`'s
    accessibilityValue): Auto's detail is "Auto" or "Auto · <badge>"; a chosen device's is its
    transport badge, or nothing when the transport is unknown. So for a chosen device a
    trailing ", <badge>" is either the badge or the end of a name like "Studio, USB"; both
    readings are returned and the menu settles it. Returns a tuple; () means the control
    shows the placeholder. Raises NavigationError when the value is unreadable or contradicts
    the stored choice (the two were read mid-change)."""
    if not isinstance(value, str) or not value.strip():
        raise ControlError("the Input device control's value is unreadable")
    v = value.strip()
    head, sep, tail = v.rpartition(", ")
    tail_l = tail.strip().lower()
    badges = _lowered(ax, TRANSPORT_BADGES)
    if auto:
        first, dot, badge = tail_l.partition(" · ")
        if not sep or first not in _lowered(ax, ["Auto"]) or (dot and badge not in badges):
            raise ControlError(f"the stored choice is Auto but the control reads {v!r}")
        names = (head.strip(),)
    elif sep and tail_l in badges:
        names = (head.strip(), v)
    else:
        names = (v,)
    placeholders = _lowered(ax, [INPUT_PLACEHOLDER])
    return tuple(n for n in names if n and n.lower() not in placeholders)


def input_control(ax, root):
    """The one "Input device" control in the content. Never "the first popup on the page"."""
    side = sidebar(ax, root)
    hits = [el for el in ax.walk(root, skip=[side])
            if ax.role(el) in _INPUT_ROLES and _labelled(ax, el, INPUT_DEVICE, role=None)]
    if len(hits) != 1:
        raise NavigationError(f"{len(hits)} {INPUT_DEVICE!r} controls; refusing to choose")
    return hits[0]


def _item_names(ax, title, name):
    """Whether a menu item is the device `name`: "<name>" or "<name> · <known badge>"."""
    t = (title or "").strip()
    if t == name:
        return True
    prefix = name + " · "
    return t.startswith(prefix) and t[len(prefix):].strip().lower() in _lowered(ax, TRANSPORT_BADGES)


def _own_menu(ax, control):
    return next((k for k in (ax.children(control) or []) if ax.role(k) == "AXMenu"), None)


def _open_menu(ax, root_of, timeout, cancel):
    """Open the control's OWN menu and return (menu, item elements). A stale open menu is
    cancelled through AX first, never with an Escape key that would reach the front app."""
    control = input_control(ax, root_of())
    stale = _own_menu(ax, control)
    if stale is not None:
        if cancel is None:
            raise NavigationError("a menu is already open on the Input device control")
        cancel(stale)
    ax.press(control)
    wait_until(ax, lambda: _own_menu(ax, input_control(ax, root_of())) is not None, timeout,
               "the input menu open")
    menu = _own_menu(ax, input_control(ax, root_of()))
    return menu, [i for i in ax.walk(menu) if ax.role(i) == "AXMenuItem"]


def _menu_titles(ax, root_of, timeout, cancel):
    """The item titles of the Input device control's own menu: opened, read, then closed
    through AX and OBSERVED closed. Refuses without an AX cancel."""
    if cancel is None:
        raise NavigationError("the microphone choice is checked against its menu, and no AX "
                              "cancel was given to close it again")
    menu, items = _open_menu(ax, root_of, timeout, cancel)
    try:
        return [ax.text(i, "AXTitle") for i in items]
    finally:
        cancel(menu)
        wait_until(ax, lambda: _own_menu(ax, input_control(ax, root_of())) is None, timeout,
                   "the input menu closing")


def read_input(ax, root_of, read_uid, cancel=None, timeout=5.0):
    """The stored microphone choice with the name the control shows for it.

    `read_uid()` returns the stored UID (`stored(read_domain, INPUT_KEY)`). Refuses, before
    anything is changed, when the UID is unreadable, the display contradicts it, or a chosen
    device cannot be chosen again: it shows no name (not connected), the menu's item titles
    do not settle which name it is, or its name does not pick exactly ONE menu item (two
    devices sharing a name). A chosen device is therefore always checked against the menu,
    which needs `cancel` to close it again."""
    uid = read_uid()
    names = display_candidates(ax, ax.get_attr(input_control(ax, root_of()), "AXValue"),
                               auto=(uid == ""))
    if read_uid() != uid:
        raise NavigationError("the stored microphone choice changed while it was read")
    if uid == "":
        # Auto too must be choosable again: exactly one "Auto" item (a device can be NAMED
        # "Auto"), checked in the menu before any caller changes routing.
        titles = _menu_titles(ax, root_of, timeout, cancel)
        autos = _lowered(ax, ["Auto"])
        if sum(1 for t in titles if t.lower() in autos) != 1:
            raise NavigationError(f"the menu {titles} does not hold exactly one Auto item; "
                                  "Auto could not be put back, refusing")
        if read_uid() != uid:
            raise NavigationError("the microphone choice changed during capture")
        return InputChoice("", names[0] if names else None)
    if not names:
        raise NavigationError("the chosen microphone shows no name (not connected); "
                              "it could not be chosen again")
    titles = _menu_titles(ax, root_of, timeout, cancel)
    if len(names) == 1:
        name = names[0]
    else:
        head, whole = names
        badge = whole[len(head) + 2:]
        # With its badge the device `head` is listed as "<head> · <badge>"; the device named
        # `whole` has no known transport, so it is listed as plain "<whole>".
        matches = [n for n, want in ((head, f"{head} · {badge}"), (whole, whole))
                   if titles.count(want) == 1]
        if len(matches) != 1:
            raise NavigationError(f"the control's value could name {list(names)} and the menu "
                                  f"{titles} does not settle it; refusing to guess")
        name = matches[0]
    # The same matcher `select_input` uses to choose it again: exactly one item, or the choice
    # could not be put back.
    picks = [t for t in titles if _item_names(ax, t, name)]
    if len(picks) != 1:
        raise NavigationError(f"{len(picks)} menu items would be chosen for {name!r} ({titles}); "
                              "the choice could not be put back, refusing")
    return InputChoice(uid, name)


def select_input(ax, root_of, read_uid, auto, name=None, uid=None, timeout=5.0, cancel=None):
    """Choose Auto (`auto=True`) or the device `name` in the control's OWN menu, then PROVE the
    stored choice took it: Auto stores "" and the control shows Auto; a device stores a
    non-empty UID (exactly `uid` when given, as a restore does) and `read_input` resolves the
    control to exactly `name`. Returns the resulting InputChoice."""
    if not auto and not name:
        raise RouteError("a named device needs its name")

    def stored_matches(stored_uid):
        if auto:
            return stored_uid == ""
        return stored_uid != "" and (uid is None or stored_uid == uid)

    def landed():
        if not stored_matches(read_uid()):
            return None
        got = read_input(ax, root_of, read_uid, cancel=cancel, timeout=timeout)
        return got if (auto or got.shown == name) else None

    try:
        already = landed()
    except NavigationError:
        already = None
    if already is not None:
        return already
    menu, items = _open_menu(ax, root_of, timeout, cancel)
    if auto:
        autos = _lowered(ax, ["Auto"])
        hits = [i for i in items if ax.text(i, "AXTitle").lower() in autos]
    else:
        hits = [i for i in items if _item_names(ax, ax.text(i, "AXTitle"), name)]
    if len(hits) != 1:
        if cancel is not None:
            cancel(menu)
        raise NavigationError(f"refusing: {len(hits)} menu items match "
                              f"{'Auto' if auto else name!r} in {[ax.text(i, 'AXTitle') for i in items]}")
    ax.press(hits[0])
    result = {}

    def landed_and_kept():
        got = landed()
        if got is not None:
            result["choice"] = got
        return got is not None
    wait_until(ax, landed_and_kept, timeout,
               f"the stored choice becoming {'Auto' if auto else name!r}")
    return result["choice"]


def restore_input(ax, root_of, read_uid, choice, timeout=5.0, cancel=None):
    """Put back a choice `read_input` captured: Auto as Auto, a device by its name AND its UID."""
    if not isinstance(choice, InputChoice):
        raise PreferenceError(f"not a captured microphone choice: {choice!r}")
    if choice.auto:
        return select_input(ax, root_of, read_uid, True, timeout=timeout, cancel=cancel)
    if not choice.shown:
        raise PreferenceError(f"{choice!r} has no name to choose it by")
    return select_input(ax, root_of, read_uid, False, choice.shown, uid=choice.uid,
                        timeout=timeout, cancel=cancel)


# ── The scan manifest ──────────────────────────────────────────────────────

# (page, tab, controls). Each control is (kind, spec, condition). `condition` None = always
# required; otherwise a name the caller's probes answer True / False / None. A control that is
# PRESENT is read whatever its condition; an ABSENT one is FAIL when its condition is True,
# N/A when False, and BLOCKED when the probe cannot tell. A control that is present but
# broken (its row has no control of the right kind, two candidates, an unreadable value) is
# FAIL whatever its condition: ambiguity never reads as OK.
#
# Kinds and their spec:
#   toggle   label                 AXCheckBox named label, its on/off state readable
#   toggle^  label                 the same, the name only STARTS with label (a two-line label)
#   button   label                 AXButton named label
#   one_of   (label, ...)          any one of these AXButtons
#   named    label                 any element whose name, value or placeholder is label
#   cards    group                 a `read_cards` group, exactly one selected
#   input    -                     the Input device control and the stored choice behind it
#   picker   row title             the AXPopUpButton in the row whose "?" is "About <title>"
#   slider   row title             the AXSlider in that row, its value readable
#   segments (row title, options)  that row's option buttons, exactly one "selected";
#                                  options None = numbered sockets ("Input N") or one popup
#   rowbtn   (row title, label)    the AXButton named label in that row
#   popover  (opener, toggle)      press opener, read the toggle inside, close it through AX
#   section  (label, kind, spec)   press the Dictionary section button, prove it is
#                                  selected, then read (kind, spec) inside it
#   prefix   template              AXButton whose name starts with the template's text before
#                                  its first %@ ("Change dictation language: %@, %@")
#   link     label                 AXLink or AXButton named label (presence only, never pressed)
#   popup    label                 AXPopUpButton named label on the control, value readable
#   disclose (open, cards, close)  press open, read exactly one Selected card WITHOUT pressing
#                                  any, press close, observe it closed
CHIME_NAMES = ("Dust Mote", "Velvet Hush", "Muted Confirm", "Whisper Tick", "Round Pebble",
               "Paper Tap", "Soft Hush", "Low Nod", "Cloud Pop", "Velvet Tap", "Satin Shift",
               "Air Glint")
EMOJI_TITLE = "Convert spoken emoji (e.g. \"thumbs up emoji\" → \U0001F44D)"
UNIVERSAL_ACTIONS = ("Download", "Cancel", "Resume", "Try Again", "Remove")
PARAKEET_ACTIONS = ("Cancel", "Resume", "Try Again")
PREVIEW_LANGUAGE = "Change dictation language: %@, %@"
ENGINE_DISCLOSURE = (CHANGE_ENGINE, ENGINE_LABELS, "Keep current engine")
PREVIEW_DISCLOSURE = ("Change preview engine", ("Apple", "Universal"), "Keep current preview engine")
WHISPERKIT_ACTIONS = ("Set up model", "Cancel", "Resume", "Remove Model", "Try Again")
INSTALL_ROW_TITLES = ("Install new languages", "Checking which languages are on this Mac",
                      "Could not read the language list from macOS. Reopen this page to try again.")
DICTIONARY_SECTIONS = ("Your Words", "Vocabulary Packs", "Learn from...", "Quick Add")
KEYBINDS = {
    "Change recording keybind": "Start / stop recording",
    "Change cancel keybind": "Cancel recording",
    "Change add-a-word keybind": "Add selected word to Dictionary",
    "Change paste last dictation keybind": "Paste last dictation",
    "Change copy last dictation keybind": "Copy last dictation",
}
POLISH_PROVIDERS = ("EG-1", "S1-mini", "Apple Intelligence", "Ollama", "OpenAI",
                    "Google Gemini", "Claude")

SCAN = [
    ("History", None, [("named", "Search history", None)]),
    ("App Settings", "Appearance", [
        ("button", "System", None), ("button", "Light", None), ("button", "Dark", None),
        ("toggle^", "Show app in Dock", None),
    ]),
    ("Dictation Settings", "Engine", [
        ("button", CHANGE_ENGINE, None),
        ("disclose", ENGINE_DISCLOSURE, None),
        ("one_of", WHISPERKIT_ACTIONS, "whisperkit_actions_shown"),
        ("one_of", PARAKEET_ACTIONS, "parakeet_delivery_actions_shown"),
        ("button", "Re-check model status", "whisperkit_recheck_shown"),
        ("button", "Re-check Fast model status", "parakeet_selected"),
        ("toggle", "Auto-detect language", "language_section_visible"),
        ("button", "Change dictation language", "language_locked"),
        ("rowbtn", ("Auto-detect language", "Reset"), "language_section_visible"),
        ("toggle", "Faster Transcription", None),
        ("toggle", "Stop recording on silence", None),
        ("slider", "Pause duration", "vad_auto_stop"),
        ("toggle", "Remove filler words (um, uh, hmm...)", None),
        ("toggle", EMOJI_TITLE, None),
        ("toggle", "Spoken punctuation", None),
        ("picker", "Unload model after", None),
    ]),
    ("Dictation Settings", "Microphone & Media", [
        ("input", INPUT_DEVICE, None),
        ("segments", ("Mic is on", None), "multi_input_device"),
        ("segments", ("Media during dictation", ("Continue", "Lower", "Mute", "Pause")), None),
        ("segments", ("Microphone readiness", ("Off", "10 sec", "30 sec", "60 sec", "Always")),
         None),
        ("rowbtn", ("Using a Bluetooth microphone?", "Learn more"), None),
        ("popover", ("Learn more", "Show Bluetooth tips"), None),
    ]),
    ("Dictation Settings", "Live Preview", [
        ("toggle", "Show words while you speak", None),
        ("prefix", PREVIEW_LANGUAGE, "preview_language_shown"),
        ("button", "Change preview engine", None),
        ("disclose", PREVIEW_DISCLOSURE, None),
        ("link", "Compare engines", None),
        ("one_of", UNIVERSAL_ACTIONS, "universal_engine_built"),
        ("button", "Browse downloads", "preview_needs_language"),
        ("one_of", INSTALL_ROW_TITLES, "apple_packs_shown"),
    ]),
    ("Dictation Settings", "Recording Pill", [
        ("segments", ("Position on screen", ("Top", "Bottom")), None),
        ("cards", "pill", None),
        ("button", "Configure Live Preview", "pill_holds_words"),
    ]),
    ("Dictation Settings", "Chimes", [
        ("toggle", "Play recording chimes", None),
        ("cards", "chime", None),
    ] + [("button", f"Preview {n}", None) for n in CHIME_NAMES]),
    ("Dictation Settings", "Clipboard", [
        ("toggle", "Auto-copy to clipboard", None),
        ("toggle", "Restore clipboard after paste", None),
        ("toggle", "Smart insertion", None),
        ("toggle", "Read selections through the clipboard", None),
    ]),
    ("Keybinds", None, [
        ("segments", ("Recording mode", ("Push to Talk", "Toggle")), None),
        ("toggle", "Escape Recovery", None),
    ] + [("keybind", label, None) for label in KEYBINDS]),
    ("Transcribe a File", None, [("button", "Upload", None)]),
    ("AI Polish", None, [
        ("toggle^", "Enable AI Polish", None),
        ("picker", "Model", "model_picker_shown"),
    ] + [("provider", name, "polish_enabled") for name in POLISH_PROVIDERS]),
    ("Dictionary", None, [
        ("toggle", "Enable Dictionary", None),
        ("section", ("Your Words", "button", "Add word"), None),
        ("section", ("Vocabulary Packs", "named", "Vocabulary Packs"), None),
        ("section", ("Learn from...", "toggle", "Self-Learning Dictionary"), None),
        ("section", ("Quick Add", "named", "Highlight a word"), None),
    ]),
    ("Snippets", None, [("button", "Add snippet", None), ("button", "Import", None),
                        ("field", "Keyword", None), ("named", "How snippets work", None),
                        ("snippet_sheet", "Add snippet", None)]),
    ("App Settings", "Privacy", [
        ("toggle", "Share usage metrics", None), ("toggle", "Send crash reports", None),
    ]),
    ("App Settings", "Permissions", [("named", "Microphone", None),
                                          ("named", "Accessibility", None)]),
    ("App Settings", "Licenses", [("button", "View license", None),
                                      ("button", "View notices", None)]),
]
SCAN_DEBUG = [
    ("Diagnostics", None, [
        ("toggle", "Enable debug mode", None),
        ("toggle", "Use tuned on-device adapter (PoC)", None),
        ("named", "Log Level", "debug_mode_on"),
        ("named", "Simulate AI polish state", "debug_mode_on"),
        ("button", "Restart Onboarding…", "debug_mode_on"),
        ("toggle", "Save dictation audio for debugging", None),
        ("button", "Open Log Directory", None), ("button", "Copy Log Path", None),
        ("button", "Clear Logs", None), ("button", "Open Console.app", None),
        ("button", "Run ASR Benchmark", None), ("button", "Run Pipeline Benchmark", None),
    ]),
]

# Inventory rows the scan does not read, each with the reason. A row here is reviewed with
# the manifest: `--self-test` requires every PR1 inventory row to be scanned or listed here.
SCAN_EXEMPT = {
    "readiness-always-warning": "a sentence, not a control (shown for Always)",
    "media-mode-warnings": "sentences, not controls (speaker and Pause-consent conditions)",
    "pill-greyed-reason": "a sentence, not a control",
    "info-buttons": "each row's \"?\" is FOUND for every row the scan reads by row (picker, "
                    "slider, segments, rowbtn: it anchors the row); its help popover is not "
                    "opened, which Live UAT does",
}


ABOUT = "About %@"          # `SettingsInfoButton`'s accessibility label for a row's "?"
_SWITCH_ON, _SWITCH_OFF = ("1", "on", "true"), ("0", "off", "false")


def _names_match(ax, el, english, prefix=False):
    for name in ax.label_names(el):
        n = name.lower()
        for t in ax.terms(english):
            t = t.lower()
            if n == t or (prefix and (n.startswith(t + ",") or n.startswith(t + "\n")
                                      or n.startswith(t + " "))):
                return True
    return False


def _content(ax, root):
    side = sidebar(ax, root)
    return [el for el in ax.walk(root, skip=[side])]


def _one(hits, what):
    if len(hits) > 1:
        raise ControlError(f"{len(hits)} controls for {what}; refusing to choose")
    return hits[0] if hits else None


def switch_state(ax, value):
    """"ON" / "OFF" for a switch's AXValue (1/0, or the style's spoken On/Off), else None."""
    if value is True or value == 1:
        return "ON"
    if value is False or value == 0:
        return "OFF"
    if isinstance(value, str):
        v = value.strip().lower()
        if v in _SWITCH_ON or v in _lowered(ax, ["On"]):
            return "ON"
        if v in _SWITCH_OFF or v in _lowered(ax, ["Off"]):
            return "OFF"
    return None


def find_switch(ax, root, label, prefix=False):
    return _one([el for el in _content(ax, root)
                 if ax.role(el) == "AXCheckBox" and _names_match(ax, el, label, prefix)],
                f"switch {label!r}")


def find_button(ax, root, label):
    return _one([el for el in _content(ax, root)
                 if ax.role(el) == "AXButton" and _names_match(ax, el, label)],
                f"button {label!r}")


def _info_prefixes(ax):
    return [t.split("%@")[0].lower() for t in ax.terms(ABOUT) if "%@" in t]


def _is_info_button(ax, el):
    if ax.role(el) != "AXButton":
        return False
    prefixes = _info_prefixes(ax)
    return any(n.lower().startswith(p) for n in ax.label_names(el) for p in prefixes if p)


def info_button(ax, root, title):
    """The row's "?" ("About <title>" in the language the app shows), or None."""
    wanted = {tmpl.replace("%@", t).lower() for tmpl in ax.terms(ABOUT) for t in ax.terms(title)}
    return _one([el for el in _content(ax, root)
                 if ax.role(el) == "AXButton"
                 and any(n.lower() in wanted for n in ax.label_names(el))],
                f"the \"?\" of row {title!r}")


BAND_SLACK = 8.0   # pt above the "?" still inside its row (the "?" sits on the title line)
ROW_MAX = 90.0     # pt below the "?" a row can reach: title, short line, a wrapped line


def row_controls(ax, root, title, accept):
    """The controls `accept` picks in the row whose "?" is "About <title>".

    Returns (info, controls); info None when the row is absent. The search climbs from the "?"
    to the smallest subtree holding a candidate, and keeps only candidates inside the row's
    band: from just above the row's title (the nearest title text at or above the "?", or the
    "?" itself) down to the next row's "?" in that subtree, and never more than `ROW_MAX`
    below the "?". So the row's own group works, rows SwiftUI flattened into one
    container work, and a control in another row (or outside every row) is never this row's.
    Any frame the decision needs that cannot be read is a ControlError, never a guess."""
    info = info_button(ax, root, title)
    if info is None:
        return None, []
    path = _path_to(ax, root, info)
    side = sidebar(ax, root)
    for anc in reversed(path[:-1]):
        if ax.same(anc, side):
            break
        inside = [el for el in ax.walk(anc) if not ax.same(el, info)]
        cands = [el for el in inside if accept(el) and not _is_info_button(ax, el)]
        if not cands:
            continue
        others = [el for el in inside if _is_info_button(ax, el)]
        fi = ax.frame(info)
        if not fi:
            raise ControlError(f"row {title!r}: the \"?\" has no readable frame")
        hi = fi["y"] + ROW_MAX
        for o in others:
            fo = ax.frame(o)
            if not fo:
                raise ControlError(f"row {title!r}: a neighbouring \"?\" has no readable frame")
            if fo["y"] > fi["y"] + 0.5:
                hi = min(hi, fo["y"])
        # The row starts at its title, which can sit ABOVE the "?" (Pause duration: title,
        # slider, then the short line with its "?"). The nearest title at or above the "?".
        titles = {t.lower() for t in ax.terms(title)}
        above = []
        for el in inside:
            if ax.role(el) == "AXButton":
                continue
            if any(ax.text(el, a).lower() in titles for a in ("AXValue", "AXTitle", "AXDescription")):
                ft = ax.frame(el)
                if not ft:
                    raise ControlError(f"row {title!r}: its title has no readable frame")
                if ft["y"] <= fi["y"] + 0.5:
                    above.append(ft["y"])
        top = max(above) if above else fi["y"]
        lo = min(top, fi["y"]) - BAND_SLACK
        owned = []
        for c in cands:
            fc = ax.frame(c)
            if not fc:
                raise ControlError(f"row {title!r}: a candidate control has no readable frame")
            if lo <= fc["y"] + fc["height"] / 2 < hi:
                owned.append(c)
        return info, owned
    return info, []


def _option_named(ax, el, option):
    """A segment is named its option; an icon segment may read "<option>, <symbol name>"."""
    for name in ax.label_names(el):
        parts = [p.strip().lower() for p in name.split(",")]
        if any(t.lower() == name.lower() or t.lower() == parts[0] for t in ax.terms(option)):
            return True
    return False


def _segment_selected(ax, value):
    return isinstance(value, str) and value.strip().lower() in _lowered(ax, ["selected",
                                                                             "Selected"])


def read_segments(ax, root, title, options):
    """(None, detail) when the row is absent, else ("OK", detail); ControlError when broken."""
    if options is None:
        info, popups = row_controls(ax, root, title, lambda e: ax.role(e) == "AXPopUpButton")
        if info is None:
            return None, f"segments:{title}=absent"
        if len(popups) == 1:
            v = ax.get_attr(popups[0], "AXValue")
            if not isinstance(v, str) or not v.strip():
                raise ControlError(f"row {title!r}: its popup's value is unreadable")
            return "OK", f"segments:{title}={v}"
        _, buttons = row_controls(ax, root, title, lambda e: ax.role(e) == "AXButton")
        if len(buttons) < 2 or popups:
            raise ControlError(f"row {title!r}: {len(buttons)} options and {len(popups)} popups")
        chosen = [b for b in buttons if _segment_selected(ax, ax.get_attr(b, "AXValue"))]
    else:
        info, buttons = row_controls(ax, root, title, lambda e: ax.role(e) == "AXButton")
        if info is None:
            return None, f"segments:{title}=absent"
        for option in options:
            n = sum(1 for b in buttons if _option_named(ax, b, option))
            if n != 1:
                raise ControlError(f"row {title!r}: {n} options named {option!r}")
        buttons = [b for b in buttons if any(_option_named(ax, b, o) for o in options)]
        chosen = [b for b in buttons if _segment_selected(ax, ax.get_attr(b, "AXValue"))]
    if len(chosen) != 1:
        raise ControlError(f"row {title!r}: {len(chosen)} options read selected")
    name = (ax.label_names(chosen[0]) or ["?"])[0]
    return "OK", f"segments:{title}={name}"


def read_row_single(ax, root, title, role, label=None):
    """The one `role` control (named `label` when given) in row `title`."""
    def accept(e):
        return ax.role(e) == role and (label is None or _names_match(ax, e, label))
    info, hits = row_controls(ax, root, title, accept)
    if info is None:
        return None
    if len(hits) != 1:
        raise ControlError(f"row {title!r}: {len(hits)} {role} controls"
                           + (f" named {label!r}" if label else ""))
    return hits[0]


def keybind_control(ax, root, label, reset=False):
    """Read ONLY this recorder row. Field and Change share a label; only the field has a
    readable AXValue. Reset is optional and belongs to this same row, never nearest by y."""
    if label not in KEYBINDS:
        raise ControlError(f"unknown keybind {label!r}")
    if reset:
        # The row band keeps a flattened neighbour's Reset out, as for every other row control.
        _, resets = row_controls(ax, root, KEYBINDS[label],
                                 lambda e: ax.role(e) == "AXButton"
                                 and _names_match(ax, e, "Reset keybind to default"))
        return _one(resets, f"Reset for {label!r}")
    info, buttons = row_controls(ax, root, KEYBINDS[label],
                                 lambda e: ax.role(e) == "AXButton"
                                 and _names_match(ax, e, label))
    if info is None:
        return None
    fields = [b for b in buttons if ax.text(b, "AXValue")]
    return _one(fields, f"keybind field {label!r}")


def provider_button(ax, root, name):
    """Provider rail tile: its name precedes the spoken group, and its value precedes status."""
    return _one([e for e in _content(ax, root) if ax.role(e) == "AXButton"
                 and _names_match(ax, e, name, prefix=True)], f"provider {name!r}")


def provider_selected(ax, button):
    value = ax.text(button, "AXValue") if button is not None else ""
    return selection_state(ax, value.split(",", 1)[0])


def select_provider(ax, root_of, name):
    button = provider_button(ax, root_of(), name)
    if button is None:
        raise ControlError(f"provider {name!r} absent (AI Polish may be off)")
    if provider_selected(ax, button) is not True:
        ax.press(button)
        wait_until(ax, lambda: provider_selected(ax, provider_button(ax, root_of(), name)) is True,
                   3.0, f"provider {name!r} selected")
    return provider_button(ax, root_of(), name)


def snippet_edit_controls(ax, sheet):
    """Scope the editor to an already-open sheet. No draft is saved or deleted."""
    result = {}
    for label, role in (("Trigger", "AXTextField"), ("Text to paste", "AXTextArea")):
        result[label] = _one([e for e in ax.walk(sheet) if ax.role(e) == role
                              and _names_match(ax, e, label)], f"snippet {label!r}")
        if result[label] is None:
            raise ControlError(f"snippet sheet has no {label!r} {role}")
    return result


def read_named(ax, root, text):
    """An element shown with `text` that is not a button: a heading, a field, a popup. Buttons
    are left out so a Dictionary section's own rail button never stands in for its content."""
    wanted = {t.lower() for t in ax.terms(text)}
    for el in _content(ax, root):
        if ax.role(el) == "AXButton":
            continue
        for attr in ("AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue"):
            if ax.text(el, attr).lower() in wanted:
                return el
    return None


def scan_control(ax, root, kind, spec, hooks):
    """(status, detail) for one manifest control on the current surface. status is "OK",
    "FAIL", or None when the control is absent (the caller applies its condition).
    `hooks` supplies what needs the app: "cards"(group) -> {name: selected},
    "read_uid"() -> stored microphone UID, "cycle"(label, before) -> (status, detail) or None
    for read-only, "cancel"(element), "root_of"()."""
    try:
        return _scan_control(ax, root, kind, spec, hooks)
    except ControlError as e:
        return "FAIL", f"{kind}:{spec} ({e})"


def _scan_control(ax, root, kind, spec, hooks):
    if kind == "snippet_sheet":
        return _scan_snippet_sheet(ax, spec, hooks)
    if kind == "keybind":
        field = keybind_control(ax, root, spec)
        if field is None:
            return None, f"keybind:{spec}=absent"
        _, buttons = row_controls(ax, root, KEYBINDS[spec],
                                  lambda e: ax.role(e) == "AXButton"
                                  and _names_match(ax, e, spec))
        actions = [b for b in buttons if not ax.text(b, "AXValue")]
        if len(actions) != 1:
            raise ControlError(f"keybind {spec!r}: {len(actions)} Change actions")
        return "OK", f"keybind:{spec}={ax.text(field, 'AXValue')} (Change found)"
    if kind == "provider":
        button = provider_button(ax, root, spec)
        if button is None:
            return None, f"provider:{spec}=absent"
        chosen = provider_selected(ax, button)
        if chosen is None:
            raise ControlError(f"provider {spec!r}: selection unreadable")
        return "OK", f"provider:{spec}={ax.text(button, 'AXValue')}"
    if kind == "field":
        field = read_row_single(ax, root, spec, "AXTextField")
        if field is None:
            return None, f"field:{spec}=absent"
        if not ax.text(field, "AXValue"):
            raise ControlError(f"field {spec!r}: value unreadable")
        return "OK", f"field:{spec}={ax.text(field, 'AXValue')}"
    if kind in ("toggle", "toggle^"):
        el = find_switch(ax, root, spec, prefix=(kind == "toggle^"))
        if el is None:
            return None, f"toggle:{spec}=absent"
        before = switch_state(ax, ax.get_attr(el, "AXValue"))
        if before is None:
            raise ControlError(f"switch {spec!r}: value {ax.get_attr(el, 'AXValue')!r} unreadable")
        cycle = hooks.get("cycle")
        return cycle(spec, before) if cycle else ("OK", f"toggle:{spec}={before}")
    if kind == "button":
        el = find_button(ax, root, spec)
        return ("OK", f"btn:{spec}=found") if el is not None else (None, f"btn:{spec}=absent")
    if kind == "one_of":
        present = [l for l in spec if find_button(ax, root, l) is not None]
        return ("OK", f"one_of:{present}") if present else (None, f"one_of:{list(spec)}=absent")
    if kind == "named":
        return (("OK", f"named:{spec}=found") if read_named(ax, root, spec) is not None
                else (None, f"named:{spec}=absent"))
    if kind == "cards":
        cards = hooks["cards"](spec)
        if not cards:
            return None, f"cards:{spec}=absent"
        sel = [k for k, v in cards.items() if v]
        if len(sel) != 1:
            raise ControlError(f"cards {spec!r} selected={sel} (want exactly one)")
        return "OK", f"cards:{spec}={sel[0]}"
    if kind == "input":
        try:
            input_control(ax, root)
        except NavigationError:
            return None, f"input:{spec}=absent"
        uid = hooks["read_uid"]()
        names = display_candidates(ax, ax.get_attr(input_control(ax, root), "AXValue"),
                                   auto=(uid == ""))
        return "OK", f"input:{'Auto' if uid == '' else 'chosen'} shows {list(names)}"
    if kind == "picker":
        el = read_row_single(ax, root, spec, "AXPopUpButton")
        if el is None:
            return None, f"picker:{spec}=absent"
        v = ax.get_attr(el, "AXValue")
        if not isinstance(v, str) or not v.strip():
            raise ControlError(f"picker {spec!r}: value {v!r} unreadable")
        return "OK", f"picker:{spec}={v}"
    if kind == "slider":
        el = read_row_single(ax, root, spec, "AXSlider")
        if el is None:
            return None, f"slider:{spec}=absent"
        v = ax.get_attr(el, "AXValue")
        if v is None or (isinstance(v, str) and not v.strip()):
            raise ControlError(f"slider {spec!r}: value unreadable")
        return "OK", f"slider:{spec}={v}"
    if kind == "segments":
        title, options = spec
        return read_segments(ax, root, title, options)
    if kind == "rowbtn":
        title, label = spec
        el = read_row_single(ax, root, title, "AXButton", label)
        return ("OK", f"rowbtn:{title}>{label}") if el is not None else (None, f"rowbtn:{title}=absent")
    if kind == "popover":
        return _scan_popover(ax, root, spec, hooks)
    if kind == "prefix":
        heads = {t.split("%@")[0].lower() for t in ax.terms(spec) if "%@" in t}
        hits = [el for el in _content(ax, root) if ax.role(el) == "AXButton"
                and any(n.lower().startswith(h) for n in ax.label_names(el) for h in heads if h)]
        el = _one(hits, f"button {spec!r}")
        return (("OK", f"prefix:{(ax.label_names(el) or [''])[0]}") if el is not None
                else (None, f"prefix:{spec}=absent"))
    if kind == "link":
        hits = [el for el in _content(ax, root) if ax.role(el) in ("AXLink", "AXButton")
                and _names_match(ax, el, spec, prefix=True)]
        el = _one(hits, f"link {spec!r}")
        return ("OK", f"link:{spec}=found") if el is not None else (None, f"link:{spec}=absent")
    if kind == "popup":
        el = _one([e for e in _content(ax, root) if ax.role(e) == "AXPopUpButton"
                   and _names_match(ax, e, spec)], f"popup {spec!r}")
        if el is None:
            return None, f"popup:{spec}=absent"
        v = ax.get_attr(el, "AXValue")
        if not isinstance(v, str) or not v.strip():
            raise ControlError(f"popup {spec!r}: value {v!r} unreadable")
        return "OK", f"popup:{spec}={v}"
    if kind == "disclose":
        return _scan_disclosure(ax, spec, hooks)
    if kind == "section":
        return _scan_section(ax, spec, hooks)
    raise ValueError(f"unknown manifest kind {kind!r}")


def _scan_snippet_sheet(ax, label, hooks):
    root_of = hooks["root_of"]
    sheets = lambda: [e for e in ax.walk(root_of()) if ax.role(e) == "AXSheet"]
    if sheets():
        raise ScanStop("a sheet was already open; refusing to edit or dismiss it")
    opener = find_button(ax, root_of(), label)
    if opener is None:
        return None, f"snippet_sheet:{label}=absent"
    ax.press(opener)
    try:
        wait_until(ax, lambda: len(sheets()) == 1, 3.0, "new snippet sheet opened")
    except NavigationError as exc:
        raise ScanStop(f"snippet sheet opening could not be observed ({exc})") from None
    try:
        sheet = sheets()[0]
        snippet_edit_controls(ax, sheet)
        for name in ("Cancel", "Save"):
            if _one([e for e in ax.walk(sheet) if ax.role(e) == "AXButton"
                     and _names_match(ax, e, name)], f"snippet {name}") is None:
                raise ControlError(f"snippet sheet has no {name}")
        return "OK", "snippet_sheet:Trigger, Text to paste, Cancel, Save (nothing saved)"
    finally:
        try:
            open_sheets = sheets()
            if len(open_sheets) > 1:
                raise ControlError("more than one sheet is open")
            cancel = _one([e for e in ax.walk(open_sheets[0]) if ax.role(e) == "AXButton"
                           and _names_match(ax, e, "Cancel")], "snippet Cancel") if open_sheets else None
            if open_sheets and cancel is None:
                raise ControlError("snippet Cancel is absent")
        except ControlError as exc:
            raise ScanStop(f"cannot safely close the snippet sheet ({exc})") from None
        if cancel is not None:
            ax.press(cancel)
        try:
            wait_until(ax, lambda: not sheets(), 3.0, "new snippet sheet closed")
        except NavigationError:
            raise ScanStop("new snippet sheet did not close; scan stopped") from None


class ScanStop(RuntimeError):
    """The scan changed something it could not put back (a popover it could not close).
    Driving further would act on a window in an unknown state, so the scan stops."""


def _popovers(ax, root):
    return [el for el in _content(ax, root) if ax.role(el) == "AXPopover"]


def _scan_popover(ax, root, spec, hooks):
    """Press the opener, read the switch inside the popover that opened, then close THAT
    popover through AX and observe it gone, on every path (a missing or unreadable switch
    included). The popover is identified as the AXPopover that was not there before the
    press, not through the switch. A popover that cannot be closed stops the scan."""
    opener_label, toggle_label = spec
    root_of = hooks["root_of"]
    cancel = hooks.get("cancel")
    opener = find_button(ax, root, opener_label)
    if opener is None:
        return None, f"popover:{opener_label}=absent"
    if cancel is None:
        raise ControlError(f"no AX cancel to close the {opener_label!r} popover; not opened")
    before = _popovers(ax, root)

    def opened():
        return [p for p in _popovers(ax, root_of()) if not any(ax.same(p, b) for b in before)]

    ax.press(opener)
    try:
        wait_until(ax, lambda: len(opened()) == 1, 3.0, f"the {opener_label!r} popover opening")
    except NavigationError as e:
        raise ScanStop(f"{opener_label!r}: could not establish a recoverable popover; "
                       f"scan stopped ({e})") from None
    pop = opened()[0]
    try:
        hits = [el for el in ax.walk(pop) if ax.role(el) == "AXCheckBox"
                and _names_match(ax, el, toggle_label)]
        if len(hits) != 1:
            raise ControlError(f"{len(hits)} switches {toggle_label!r} in the popover")
        state = switch_state(ax, ax.get_attr(hits[0], "AXValue"))
        if state is None:
            raise ControlError(f"{toggle_label!r} in the popover: value unreadable")
        return "OK", f"popover:{toggle_label}={state} (closed)"
    finally:
        cancel(pop)
        try:
            wait_until(ax, lambda: not opened(), 3.0, f"the {opener_label!r} popover closing")
        except NavigationError:
            raise ScanStop(f"the {opener_label!r} popover did not close; scan stopped") from None


def _scan_disclosure(ax, spec, hooks):
    """Open an engine chooser, read which card is Selected WITHOUT pressing a card, close it
    with its Keep button and observe it closed (Change back, cards gone). It is closed on
    every path; one that cannot be closed stops the scan."""
    open_label, cards, close_label = spec
    root_of = hooks["root_of"]
    opener = find_button(ax, root_of(), open_label)
    if opener is None:
        return None, f"disclose:{open_label}=absent"

    def card_buttons():
        return {c: find_button(ax, root_of(), c) for c in cards}

    def is_open():
        return all(b is not None for b in card_buttons().values())

    def is_closed():
        return (find_button(ax, root_of(), open_label) is not None
                and all(b is None for b in card_buttons().values()))

    ax.press(opener)
    try:
        try:
            wait_until(ax, is_open, 3.0, f"{open_label!r} showing its cards")
        except NavigationError as e:
            raise ControlError(str(e)) from None
        chosen = [c for c, b in card_buttons().items()
                  if selection_state(ax, ax.get_attr(b, "AXValue")) is True]
        if len(chosen) != 1:
            raise ControlError(f"{open_label!r}: {len(chosen)} cards read Selected ({chosen})")
        return "OK", f"disclose:{open_label} selected={chosen[0]} (closed, nothing chosen)"
    finally:
        if not is_closed():
            keep = find_button(ax, root_of(), close_label)
            if keep is None:
                raise ScanStop(f"{open_label!r} is open and has no {close_label!r}; scan stopped")
            ax.press(keep)
            try:
                wait_until(ax, is_closed, 3.0, f"{open_label!r} closing")
            except NavigationError:
                raise ScanStop(f"{open_label!r} did not close; scan stopped") from None


def _scan_section(ax, spec, hooks):
    """Select a Dictionary section in its rail, prove it reads Selected, read its anchor."""
    label, kind, inner = spec
    root_of = hooks["root_of"]
    btn = find_button(ax, root_of(), label)
    if btn is None:
        return None, f"section:{label}=absent"
    if selection_state(ax, ax.get_attr(btn, "AXValue")) is not True:
        ax.press(btn)
        try:
            wait_until(ax, lambda: selection_state(
                ax, ax.get_attr(find_button(ax, root_of(), label), "AXValue")) is True,
                3.0, f"Dictionary section {label!r} selected")
        except NavigationError as e:
            raise ControlError(str(e)) from None
    status, detail = _scan_control(ax, root_of(), kind, inner, {**hooks, "cycle": None})
    if status is None:
        raise ControlError(f"section {label!r} is selected but shows no {kind} {inner!r}")
    return status, f"section:{label} {detail}"


def selected_section(ax, root):
    """The Dictionary section the rail reports Selected, or None."""
    chosen = [s for s in DICTIONARY_SECTIONS
              if (b := find_button(ax, root, s)) is not None
              and selection_state(ax, ax.get_attr(b, "AXValue")) is True]
    return chosen[0] if len(chosen) == 1 else None


def scan_surface(ax, root_of, controls, probes, hooks):
    """Read one surface's manifest rows: [(status, detail)]. A surface with Dictionary sections
    first reads which section is showing; when that cannot be read the sections are not
    touched (BLOCKED). Afterwards that section is selected again and OBSERVED selected; a
    restore that does not land adds a FAIL row. `ScanStop` propagates: the caller stops."""
    out = []
    first = None
    has_sections = any(kind == "section" for kind, _, _ in controls)
    if has_sections:
        first = selected_section(ax, root_of())
    try:
        for kind, spec, condition in controls:
            if kind == "section" and first is None:
                out.append(("BLOCKED", f"section:{spec[0]} (the section showing now cannot be "
                                       "read, so none is changed)"))
                continue
            try:
                status, detail = scan_control(ax, root_of(), kind, spec,
                                              {**hooks, "root_of": root_of})
            except (NavigationError, PreferenceError) as e:
                status, detail = "BLOCKED", f"{kind}:{spec} ({e})"
            if status is None:
                status = absent_status(condition, probes)
                detail += f" [{status}" + (f", when {condition}" if condition else "") + "]"
            out.append((status, detail))
    finally:
        if first is not None:
            out.append(_restore_section(ax, root_of, first))
    return out


def _restore_section(ax, root_of, first):
    try:
        if selected_section(ax, root_of()) != first:
            b = find_button(ax, root_of(), first)
            if b is None:
                return "FAIL", f"restore:section {first!r} button gone"
            ax.press(b)
            wait_until(ax, lambda: selected_section(ax, root_of()) == first, 3.0,
                       f"Dictionary section {first!r} selected again")
        return "OK", f"restore:section {first!r}"
    except NavigationError as e:
        return "FAIL", f"restore:section {first!r} ({e})"


def inputs_on_device(profile, name):
    """How many inputs `name` has, from `system_profiler SPAudioDataType -json` (parsed):
    the number, or None when the device is not listed exactly once."""
    items = [it for grp in (profile or {}).get("SPAudioDataType", []) or []
             for it in grp.get("_items", []) or [] if it.get("_name") == name]
    if len(items) != 1:
        return None
    n = items[0].get("coreaudio_device_input")
    return n if isinstance(n, int) else None


def absent_status(condition, probes):
    """What an absent control means: FAIL (required), N/A (condition false) or BLOCKED."""
    if condition is None:
        return "FAIL"
    probe = probes.get(condition)
    if probe is None:
        return "BLOCKED"
    try:
        answer = probe()
    except Exception:
        answer = None
    if answer is True:
        return "FAIL"
    if answer is False:
        return "N/A"
    return "BLOCKED"


def row_status(statuses):
    """A surface's row: FAIL beats BLOCKED beats OK; N/A is fine."""
    if "FAIL" in statuses:
        return "FAIL"
    if "BLOCKED" in statuses:
        return "BLOCKED"
    return "OK"


# ── Offline self-test ──────────────────────────────────────────────────────

def _self_test():
    """Harness contract: drives this module's real functions against modelled trees.
    Protects the INSTRUMENT, not the product."""
    failures = []
    rows = 0

    def case(why, got, want):
        nonlocal rows
        rows += 1
        if got != want:
            failures.append(f"{why}: got {got!r}, want {want!r}")
        else:
            print(f"  ok      {why}")

    def raises(why, fn, exc):
        nonlocal rows
        rows += 1
        try:
            fn()
        except exc as e:
            print(f"  ok      {why} ({type(e).__name__})")
            return
        except Exception as e:  # noqa: BLE001
            failures.append(f"{why}: raised {type(e).__name__}: {e}")
            return
        failures.append(f"{why}: did not raise")

    for why, fn, exc in fixture_cases():
        raises(why, fn, exc)
    for why, got, want in value_cases():
        case(why, got, want)

    if failures:
        for f in failures:
            print(f"  FAIL    {f}")
        print(f"\nsettings_nav self-test: {len(failures)} of {rows} FAILED")
        return 1
    print(f"\nsettings_nav self-test: {rows}/{rows} passed")
    return 0


# Fixtures live in settings_nav_fixtures.py so this module stays the implementation.
def fixture_cases():
    from settings_nav_fixtures import raising_cases
    return raising_cases()


def value_cases():
    from settings_nav_fixtures import valued_cases
    return valued_cases()


if __name__ == "__main__":
    import os
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    print("settings_nav is a library. Run `--self-test` for its offline control.")
    sys.exit(2)
