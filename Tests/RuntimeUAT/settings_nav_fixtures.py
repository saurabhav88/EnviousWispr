"""Modelled Settings windows for `settings_nav --self-test` (#3385).

Founder 2026-10-02 (#3385): wrapping supersedes the horizontal scrolling
fixture; clipped wrapped tabs must fail without a scrolling rescue.

A `FakeSettings` holds the window's state (selected page, remembered tab, the wrapped strip's geometry, engine choices open or not, the microphone choice) and builds a fresh dictionary tree
on every `root()` call, the way the real tree is re-read after a press. Presses mutate the
state through the elements' `_press` callbacks, so `settings_nav.navigate` and friends run
their real code paths. No app, process, input device, audio, defaults or network is touched.
"""
import settings_nav as sn

# German tab names are lane C draft fixtures, not verified catalog lookups.
GERMAN = {
    "Selected": "Ausgewählt", "Not selected": "Nicht ausgewählt", "Auto": "Automatisch",
    "History": "Verlauf", "What's New": "Neuigkeiten", "Appearance": "Erscheinungsbild",
    "Dictation Settings": "Diktiereinstellungen", "Keybinds": "Tastenkürzel",
    "Transcribe a File": "Datei transkribieren", "AI Polish": "KI-Feinschliff",
    "Dictionary": "Wörterbuch", "Snippets": "Textbausteine", "Permissions": "Berechtigungen",
    "What's New & Updates": "Neues & Updates", "Send feedback": "Feedback senden",
    "All release notes on GitHub": "Alle Versionshinweise auf GitHub",
    "Check for Updates…": "Nach Updates suchen…",
    "App Settings": "App-Einstellungen", "Privacy": "Datenschutz", "Licenses": "Lizenzen", "Check for Updates": "Nach Updates suchen",
    "Engine": "Engine", "Microphone & Media": "Mikrofon & Medien", "Live Preview": "Live-Vorschau",
    "Recording Pill": "Aufnahmeanzeige", "Chimes": "Signaltöne", "Clipboard": "Zwischenablage",
    "Input device": "Eingabegerät", "Choose a microphone": "Mikrofon auswählen",
    "Built-in": "Integriert",
}


def el(role, title="", value="", desc="", children=(), frame=None, press=None):
    return {"AXRole": role, "AXTitle": title, "AXValue": value, "AXDescription": desc,
            "AXChildren": list(children), "_frame": frame, "_press": press}


class FakeSettings:
    def __init__(self, german=False, open_=True, press_result=True, press_lands=True,
                 strip_width=476, tab_width=120, duplicate_sidebar_label=None,
                 description_only=True, strip_group=True, clip_height=None, tab_dx=0):
        self.german = german
        self.open = open_
        self.page = "History"
        self.remembered_tab = "Engine"
        self.app_tab = "Appearance"
        self.strip_width = strip_width
        self.tab_width = tab_width
        self.strip_group = strip_group     # row groups under the wrapping group
        self.clip_height = clip_height     # optional ancestor scroll viewport
        self.tab_dx = tab_dx               # deliberately broken horizontal placement
        self.press_result = press_result   # what AXPress REPORTS
        self.press_lands = press_lands     # whether the press CHANGES anything
        self.duplicate_sidebar_label = duplicate_sidebar_label
        self.description_only = description_only
        self.choices_open = False
        self.engine = "Fast"
        # The stored choice is a UID ("" = Auto); Auto opens `auto_uid`. (uid, name, badge).
        self.input_uid = ""
        self.auto_uid = "BuiltInMicrophoneDevice"
        self.devices = [("BuiltInMicrophoneDevice", "MacBook Pro Microphone", "Built-in"),
                        ("BlackHole2ch_UID", "BlackHole 2ch", None),
                        ("AppleUSBAudioEngine:Studio", "Studio Mic", "USB")]
        self.uid_unreadable = False
        self.menu_open = False
        self.presses = []
        self.scrolls = 0
        self.cancels = 0

    # ---- shown text ---------------------------------------------------------
    def t(self, english):
        return GERMAN.get(english, english) if self.german else english

    def sel(self, on, activity=None):
        base = self.t("Selected") if on else self.t("Not selected")
        return f"{base}. {activity}" if activity else base

    # None: the remembered tab alone reads Selected. "none": no tab does. "two": the
    # remembered tab AND Engine both do (a strip the harness must refuse to read).
    tab_selection = None

    def _tab_selected(self, tab):
        if self.tab_selection == "none":
            return False
        if self.tab_selection == "two":
            return tab in (self.remembered_tab, "Engine")
        return tab == (self.app_tab if self.page == "App Settings" else self.remembered_tab)

    def named(self, role, english, value="", frame=None, press=None):
        if self.description_only:
            return el(role, desc=self.t(english), value=value, frame=frame, press=press)
        return el(role, title=self.t(english), value=value, frame=frame, press=press)

    # ---- actions ------------------------------------------------------------
    def _act(self, name, change):
        def press():
            self.presses.append(name)
            if self.press_lands:
                change()
            return self.press_result
        return press

    def _select_page(self, page):
        def change():
            self.page = page
        return self._act(f"page:{page}", change)

    def _select_tab(self, tab):
        def change():
            if self.page == "App Settings": self.app_tab = tab
            else: self.remembered_tab = tab
        return self._act(f"tab:{tab}", change)

    # ---- tree ---------------------------------------------------------------
    def root(self):
        window_children = []
        if self.open:
            window_children = [self.sidebar_tree(), self.content_tree()]
        return el("AXApplication", children=[el("AXWindow", title="EnviousWispr",
                                                 children=window_children,
                                                 frame={"x": 100, "y": 100, "width": 900,
                                                        "height": 700})])

    def sidebar_tree(self):
        rows = []
        for page in sn.PAGES:
            activity = "Dictionary enrichment in progress" if page == "Dictionary" else None
            rows.append(self.named("AXButton", page, value=self.sel(page == self.page, activity),
                                   press=self._select_page(page)))
        if self.duplicate_sidebar_label:
            rows.append(self.named("AXButton", self.duplicate_sidebar_label, value=self.sel(False)))
        return el("AXScrollArea", children=[el("AXGroup", children=rows)],
                  frame={"x": 100, "y": 100, "width": 200, "height": 700})

    def content_tree(self):
        kids = []
        # A decoy in the CONTENT named like a sidebar page and a tab: a whole-app fuzzy
        # lookup would press these.
        kids.append(self.named("AXButton", "Dictionary", value=""))
        kids.append(self.named("AXButton", "Engine", value=""))
        if self.page in sn.TABS:
            tabs = []
            per_row = max(1, int(self.strip_width // self.tab_width))
            row_count = (len(sn.TABS[self.page]) + per_row - 1) // per_row
            for i, tab in enumerate(sn.TABS[self.page]):
                x = 320 + (i % per_row) * self.tab_width + self.tab_dx
                y = 120 + (i // per_row) * 52
                tabs.append(self.named("AXButton", tab, value=self.sel(self._tab_selected(tab)),
                                       frame={"x": x, "y": y, "width": self.tab_width - 4,
                                              "height": 52},
                                       press=self._select_tab(tab)))
            if self.strip_group:
                # Both rows are modelled in AX. Groups do not clip; only a window
                # or a scroll viewport decides whether a wrapped tab is visible.
                tabs = [el("AXGroup", children=tabs[i:i + per_row])
                        for i in range(0, len(tabs), per_row)]
            strip = el("AXGroup", children=tabs,
                       frame={"x": 320, "y": 120, "width": self.strip_width,
                              "height": row_count * 52})
            if self.clip_height is not None:
                strip = el("AXScrollArea", children=[strip],
                           frame={"x": 320, "y": 120, "width": self.strip_width,
                                  "height": self.clip_height})
            kids.append(strip)
            if self.remembered_tab == "Engine":
                kids += self.engine_tree()
            if self.remembered_tab == "Microphone & Media":
                kids.append(self.input_tree())
        return el("AXGroup", children=kids,
                  frame={"x": 310, "y": 100, "width": 690, "height": 700})

    def engine_tree(self):
        out = [self.named("AXButton", "Change preview engine")]
        if self.choices_open:
            for label in sn.ENGINE_LABELS:
                def choose(label=label):
                    self.engine = label
                    self.choices_open = False
                out.append(self.named("AXButton", label, value=self.sel(label == self.engine),
                                      press=self._act(f"engine:{label}", choose)))
            out.append(self.named("AXButton", "Keep current engine"))
        else:
            out.append(el("AXGroup", desc=f"{self.t(self.engine)}, Parakeet v3, For everyday"))
            out.append(self.named("AXButton", sn.CHANGE_ENGINE,
                                  press=self._act("change", lambda: setattr(self, "choices_open", True))))
        return out

    def device(self, uid):
        return next(((n, b) for u, n, b in self.devices if u == uid), None)

    def input_value(self):
        """As `MicrophoneDevicePicker` builds it: "<name or placeholder>[, <detail>]"."""
        auto = self.input_uid == ""
        found = self.device(self.auto_uid if auto else self.input_uid)
        name, badge = found if found else (self.t("Choose a microphone"), None)
        badge = self.t(badge) if badge else None
        if auto:
            detail = self.t("Auto") + (f" · {badge}" if badge else "")
        else:
            detail = badge
        return name + (f", {detail}" if detail else "")

    def read_uid(self):
        if self.uid_unreadable:
            raise sn.PreferenceError("preferredInputDeviceIDOverride: defaults exited 1")
        return self.input_uid

    def input_tree(self):
        menu_children = []
        if self.menu_open:
            items = [el("AXMenuItem", title=self.t("Auto"), press=self._act(
                "input:Auto", lambda: self._set_input("")))]
            for uid, name, badge in self.devices:
                title = name + (f" · {self.t(badge)}" if badge else "")
                items.append(el("AXMenuItem", title=title, press=self._act(
                    f"input:{name}", lambda uid=uid: self._set_input(uid))))
            menu_children = [el("AXMenu", children=items)]
        return el("AXMenuButton", desc=self.t("Input device"), value=self.input_value(),
                  children=menu_children,
                  press=self._act("input-open", lambda: setattr(self, "menu_open", True)))

    def _set_input(self, uid):
        self.input_uid = uid
        self.menu_open = False

    # ---- the adapter ----------------------------------------------------------
    def ax(self):
        clock = {"t": 0.0}

        def sleep(s):
            clock["t"] += s

        def cancel(menu):
            self.cancels += 1
            self.presses.append("cancel")
            self.menu_open = False

        a = sn.AX(
            get_attr=lambda e, k: e.get(k) if isinstance(e, dict) else None,
            children=lambda e: e.get("AXChildren") or [],
            press=lambda e: e["_press"]() if e.get("_press") else False,
            frame=lambda e: e.get("_frame"),
            terms=lambda text: [text] + ([GERMAN[text]] if self.german and text in GERMAN else []),
            sleep=sleep, clock=lambda: clock["t"])
        # Trap any future attempt to rescue clipped tabs by scrolling.
        def scroll(element):
            self.scrolls += 1
            raise AssertionError("wrapped tabs must never scroll")
        a.scroll_to_visible = scroll
        a.cancel = cancel
        return a


def _nav(fake, page, tab=None, **kw):
    ax = fake.ax()
    return sn.navigate(ax, fake.root, page, tab, **kw)


def raising_cases():
    """(why, fn, exception) rows: each must raise that exception."""
    def no_tab_selected():
        f = FakeSettings()
        f.page, f.tab_selection = "Dictation Settings", "none"
        _nav(f, "Dictation Settings")

    def two_tabs_selected_remembered():
        f = FakeSettings()
        f.page, f.remembered_tab, f.tab_selection = "Dictation Settings", "Chimes", "two"
        _nav(f, "Dictation Settings")

    def two_tabs_selected_explicit():
        f = FakeSettings()
        f.page, f.remembered_tab, f.tab_selection = "Dictation Settings", "Chimes", "two"
        _nav(f, "Dictation Settings", "Engine")

    def wrong_region():
        # A content button named "Dictionary" sits beside the sidebar row: the lookup must
        # still pick the sidebar's, so a SECOND sidebar row of that name is what refuses.
        f = FakeSettings(duplicate_sidebar_label="Dictionary")
        _nav(f, "Dictionary")

    def press_reports_ok_but_nothing_lands():
        f = FakeSettings(press_lands=False, press_result=True)
        _nav(f, "Keybinds")

    def tab_never_lands():
        f = FakeSettings()
        _nav(f, "Dictation Settings")
        f.press_lands = False
        _nav(f, "Dictation Settings", "Chimes")

    def frames_unreadable():
        f = FakeSettings()
        f.page = "Dictation Settings"
        ax = f.ax()
        ax.frame = lambda e: None
        sn.navigate(ax, f.root, "Dictation Settings", "Clipboard")

    def change_ambiguous():
        f = FakeSettings()
        f.page, f.remembered_tab = "Dictation Settings", "Engine"
        ax = f.ax()
        real_root = f.root

        def doubled():
            r = real_root()
            content = r["AXChildren"][0]["AXChildren"][1]
            content["AXChildren"].append(f.named("AXButton", sn.CHANGE_ENGINE))
            return r
        sn.choose_engine(ax, doubled, "All Languages")

    def mic(**kw):
        f = FakeSettings(**kw)
        f.page, f.remembered_tab = "Dictation Settings", "Microphone & Media"
        return f, f.ax()

    def input_ambiguous():
        f, ax = mic()
        f.devices.append(("Studio2", "Studio Mic", None))   # two items read "Studio Mic[ · …]"
        sn.select_input(ax, f.root, f.read_uid, auto=False, name="Studio Mic", cancel=ax.cancel)

    def input_missing():
        f = FakeSettings()
        f.page, f.remembered_tab = "Dictation Settings", "Engine"
        sn.select_input(f.ax(), f.root, f.read_uid, auto=True)

    def uid_unreadable_capture():
        f, ax = mic()
        f.uid_unreadable = True
        sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)

    def unresolved_named_device():
        f, ax = mic()
        f.input_uid = "UnpluggedHeadset"        # stored, but not among the connected devices
        sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)

    def display_contradicts_store():
        f, ax = mic()
        f.input_uid = "AppleUSBAudioEngine:Studio"
        ax2 = f.ax()
        sn.display_candidates(ax2, f.input_value(), auto=True)

    def both_readings_listed():
        # "Studio" over USB and a device NAMED "Studio, USB" (no known transport) both read
        # "Studio, USB" and both appear in the menu: no reading of the value is safe.
        f, ax = mic()
        f.devices = [("A", "Studio", "USB"), ("B", "Studio, USB", None)]
        f.input_uid = "B"
        sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)

    def ambiguous_without_menu_access():
        f, ax = mic()
        f.devices = [("B", "Studio, USB", None)]
        f.input_uid = "B"
        sn.read_input(ax, f.root, f.read_uid)

    def restore_lands_on_other_uid():
        # Two devices share a name; restoring by name alone could pick the wrong one, so the
        # stored UID must match the captured one or the restore fails.
        f, ax = mic()
        f.devices = [("U1", "Desk Mic", None), ("U2", "Desk Mic 2", None)]
        f.input_uid = "U1"
        choice = sn.InputChoice("U1", "Desk Mic")
        f.input_uid = "U2"
        f.devices = [("U2", "Desk Mic", None)]   # U1 gone; U2 now carries the same name
        sn.restore_input(ax, f.root, f.read_uid, choice, cancel=ax.cancel)

    def select_named_variant_never_reports_the_other():
        # A "Studio" over USB and B named "Studio, USB" (no transport) both read
        # "Studio, USB". With A stored, asking for B must press B and then verify B by its
        # resolved name, which the menu cannot settle: it fails, never returns A.
        f, ax = mic()
        f.devices = [("A", "Studio", "USB"), ("B", "Studio, USB", None)]
        f.input_uid = "A"
        sn.select_input(ax, f.root, f.read_uid, auto=False, name="Studio, USB", cancel=ax.cancel)

    def duplicate_names_refuse_at_capture():
        # Two devices named "Desk Mic": capturing either would later refuse to restore, after
        # the caller had already switched the audio, so the capture itself refuses.
        f, ax = mic()
        f.devices = [("U1", "Desk Mic", None), ("U2", "Desk Mic", None)]
        f.input_uid = "U1"
        sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)

    def duplicate_auto_refuses_at_capture():
        # An aggregate device NAMED "Auto" makes two "Auto" items; Auto could not be put back.
        f, ax = mic()
        f.devices.append(("AGG", "Auto", None))
        sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)

    def menu_that_will_not_close_refuses():
        f, ax = mic()
        f.input_uid = "AppleUSBAudioEngine:Studio"
        ax.cancel = lambda menu: None          # the cancel is refused; the menu stays open
        sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)

    def legacy_restore_record():
        sn.InputChoice.from_json({"auto": False, "shown": "Studio Mic"})

    def wrapped_second_row_clipped():
        f = FakeSettings(clip_height=52)
        try:
            _nav(f, "Dictation Settings", "Clipboard")
        finally:
            assert f.scrolls == 0 and "tab:Clipboard" not in f.presses

    def wrapped_tab_clipped_horizontally():
        f = FakeSettings(tab_dx=-221)
        _nav(f, "Dictation Settings", "Engine")

    def remembered_page_with_clipped_tab():
        f = FakeSettings(clip_height=52)
        _nav(f, "Dictation Settings")

    def selection_moves_tab_outside_viewport():
        f = FakeSettings()
        old_select = f._select_tab
        def select(tab):
            action = old_select(tab)
            def press():
                result = action()
                f.tab_dx = 1000
                return result
            return press
        f._select_tab = select
        try:
            _nav(f, "Dictation Settings", "Clipboard")
        finally:
            assert f.scrolls == 0

    def closed_window_no_opener():
        f = FakeSettings(open_=False)
        _nav(f, "History")

    def app_refuses(page="App Settings", tab="Privacy", **kwargs):
        f = FakeSettings(**kwargs)
        _nav(f, page, tab)

    return [
        ("App tab selection must land", lambda: app_refuses(press_lands=False), sn.NavigationError),
        ("App wrapped tabs must be visible", lambda: app_refuses(clip_height=52, strip_width=240), sn.NavigationError),
        ("App content cannot replace a sidebar row", lambda: app_refuses(duplicate_sidebar_label="App Settings"), sn.NavigationError),
        ("removed standalone Permissions is refused", lambda: sn.validate_route("Permissions"), sn.RouteError),
        ("removed standalone Appearance is refused", lambda: sn.validate_route("Appearance"), sn.RouteError),
        ("no selected tab is never a success with an unknown tab", no_tab_selected,
         sn.NavigationError),
        ("two selected tabs fail the remembered route", two_tabs_selected_remembered,
         sn.NavigationError),
        ("two selected tabs fail an explicit route even when the asked tab is one of them",
         two_tabs_selected_explicit, sn.NavigationError),
        ("a tab without its page is refused before any action",
         lambda: sn.validate_route(None, "Engine"), sn.RouteError),
        ("a tab on a page without tabs is refused",
         lambda: sn.validate_route("Keybinds", "Engine"), sn.RouteError),
        ("an unknown tab is refused", lambda: sn.validate_route("Dictation Settings", "Sounds"),
         sn.RouteError),
        ("a removed page name is refused, not translated (Transcription)",
         lambda: sn.validate_route("Transcription"), sn.RouteError),
        ("a removed page name is refused (Your Words)",
         lambda: sn.validate_route("Your Words"), sn.RouteError),
        ("Check for Updates is an action, not a page",
         lambda: sn.validate_route("Check for Updates"), sn.RouteError),
        ("Diagnostics is refused on a known release build",
         lambda: sn.validate_route("Diagnostics", debug_build=False), sn.RouteError),
        ("a duplicate label INSIDE the sidebar refuses rather than choosing", wrong_region,
         sn.NavigationError),
        ("a press that reports OK but changes nothing fails",
         press_reports_ok_but_nothing_lands, sn.NavigationError),
        ("a tab press that never lands fails", tab_never_lands, sn.NavigationError),
        ("unreadable frames refuse instead of assuming the tab is on screen", frames_unreadable,
         sn.NavigationError),
        ("two 'Change speech engine' buttons refuse", change_ambiguous, sn.NavigationError),
        ("two menu items matching one device refuse", input_ambiguous, sn.NavigationError),
        ("a missing Input device control refuses", input_missing, sn.NavigationError),
        ("an unreadable stored microphone UID refuses before any change",
         uid_unreadable_capture, sn.PreferenceError),
        ("a chosen device that is not connected (placeholder shown) refuses",
         unresolved_named_device, sn.NavigationError),
        ("a display that contradicts the stored choice refuses", display_contradicts_store,
         sn.NavigationError),
        ("a value two listed devices could both produce refuses", both_readings_listed,
         sn.NavigationError),
        ("an ambiguous value with no way to read the menu refuses",
         ambiguous_without_menu_access, sn.NavigationError),
        ("a restore landing on another device with the same name fails on its UID",
         restore_lands_on_other_uid, sn.NavigationError),
        ("a restore record without a UID is refused", legacy_restore_record, sn.PreferenceError),
        ("asking for 'Studio, USB' while 'Studio' over USB is stored never reports Studio",
         select_named_variant_never_reports_the_other, sn.NavigationError),
        ("two devices with one name refuse at capture, before any routing",
         duplicate_names_refuse_at_capture, sn.NavigationError),
        ("a device named 'Auto' makes Auto refuse at capture, before any routing",
         duplicate_auto_refuses_at_capture, sn.NavigationError),
        ("a menu whose AX cancel does not close it refuses the capture",
         menu_that_will_not_close_refuses, sn.NavigationError),
        ("a wrapped second row clipped by an ancestor viewport fails without rescue",
         wrapped_second_row_clipped, sn.NavigationError),
        ("a wrapped tab clipped by the window fails", wrapped_tab_clipped_horizontally,
         sn.NavigationError),
        ("returning to a remembered page also refuses clipped tabs",
         remembered_page_with_clipped_tab, sn.NavigationError),
        ("a selected value cannot pass after selection moves tabs out of view",
         selection_moves_tab_outside_viewport, sn.NavigationError),
        ("a closed window with no opener fails instead of pressing anything",
         closed_window_no_opener, sn.NavigationError),
        ("an unknown engine label is refused",
         lambda: sn.choose_engine(FakeSettings().ax(), FakeSettings().root, "Turbo"), sn.RouteError),
    ]


def valued_cases():
    """(why, got, want) rows. Each block runs on its own: one that raises becomes a FAILED row
    naming it, so a broken path never hides the rows of the blocks after it."""
    rows = []
    blocks = []

    def block_0(rows):
        ax_en = FakeSettings().ax()
        ax_de = FakeSettings(german=True).ax()
        st = sn.selection_state
        rows += [
            ("'Selected' reads selected", st(ax_en, "Selected"), True),
            ("'Not selected' reads NOT selected (no substring match)", st(ax_en, "Not selected"), False),
            ("a compound selected value reads selected",
             st(ax_en, "Selected. Dictionary enrichment in progress"), True),
            ("a compound unselected value reads not selected",
             st(ax_en, "Not selected. Importing in progress"), False),
            ("German 'Ausgewählt. …' reads selected", st(ax_de, "Ausgewählt. Importieren läuft"), True),
            ("German 'Nicht ausgewählt' reads not selected", st(ax_de, "Nicht ausgewählt"), False),
            ("an empty value is unknown, not unselected", st(ax_en, ""), None),
        ]

    blocks.append(('selection values', block_0))

    def block_1(rows):
        # Navigation in English with the content decoys present.
        f = FakeSettings()
        r = _nav(f, "Dictionary")
        rows.append(("the sidebar row is pressed, not the content decoy of the same name",
                     (r.page, f.page, f.presses), ("Dictionary", "Dictionary", ["page:Dictionary"])))

    blocks.append(('Navigation in English with the content decoys present', block_1))

    def block_2(rows):
        # German tree, English request.
        f = FakeSettings(german=True)
        r = _nav(f, "Dictation Settings", "Chimes")
        rows.append(("English names reach a German sidebar and strip",
                     (f.page, f.remembered_tab), ("Dictation Settings", "Chimes")))

    blocks.append(('German tree, English request', block_2))

    def block_3(rows):
        # Labels only in AXTitle (no description) still resolve.
        f = FakeSettings(description_only=False)
        _nav(f, "Snippets")
        rows.append(("a row named by AXTitle resolves too", f.page, "Snippets"))

    blocks.append(('Labels only in AXTitle (no description) still resolve', block_3))

    def block_4(rows):
        # A press that reports FAILURE but lands is a success.
        f = FakeSettings(press_result=False)
        r = _nav(f, "AI Polish")
        rows.append(("a press reporting failure whose state lands still succeeds", f.page, "AI Polish"))

    blocks.append(('A press that reports FAILURE but lands is a success', block_4))

    def block_5(rows):
        # Remembered parent: no tab keeps the remembered tab; explicit tab overrides it.
        f = FakeSettings()
        f.remembered_tab = "Chimes"
        r = _nav(f, "Dictation Settings")
        rows.append(("nav(page) keeps the remembered tab and presses no tab",
                     (r.shown_tab, [p for p in f.presses if p.startswith("tab:")]), ("Chimes", [])))
        r = _nav(f, "Dictation Settings", "Engine")
        rows.append(("an explicit tab overrides the remembered one", (r.tab, f.remembered_tab),
                     ("Engine", "Engine")))

    blocks.append(('Remembered parent: no tab keeps the remembered tab; explicit tab overrides it', block_5))

    def gift_menu(rows):
        for german in (False, True):
            f = FakeSettings(german=german)
            showing = {"open": False}
            def root():
                toolbar = el("AXToolbar", children=[
                    f.named("AXButton", sn.GIFT_CAPTION, press=lambda: showing.update(open=True)),
                    f.named("AXButton", "Send feedback")])
                pop = el("AXPopover", children=[f.named("AXStaticText", "What's New"),
                    f.named("AXButton", "Check for Updates…"),
                    f.named("AXLink", "All release notes on GitHub")])
                return el("AXWindow", children=[toolbar] + ([pop] if showing["open"] else []))
            pop = sn.open_gift(f.ax(), root)
            rows.append((f"gift dropdown observed, German={german}", pop["AXRole"], "AXPopover"))
    blocks.append(("Gift dropdown", gift_menu))

    def app_tabs(rows):
        for german in (False, True):
            f = FakeSettings(german=german)
            for tab in ("Appearance", "Permissions", "Privacy", "Licenses"):
                route = _nav(f, "App Settings", tab)
                rows.append((f"App Settings {tab}, German={german}", route.shown_tab, tab))
            _nav(f, "History")
            rows.append(("App sidebar return remembers Licenses", _nav(f, "App Settings").shown_tab, "Licenses"))
            rows.append(("App explicit override", _nav(f, "App Settings", "Privacy").shown_tab, "Privacy"))
            _nav(f, "Dictation Settings", "Chimes")
            rows.append(("App and Dictation remember independently", _nav(f, "App Settings").shown_tab, "Privacy"))
    blocks.append(("App Settings tabs", app_tabs))

    def block_6(rows):
        f = FakeSettings()
        for tab in sn.TABS["Dictation Settings"]:
            _nav(f, "Dictation Settings", tab)
        rows.append(("all six tabs across both rows are selected without scrolling",
                     (f.scrolls, f.remembered_tab), (0, "Clipboard")))
        strip = sn.tab_strip(f.ax(), f.root(), "Dictation Settings")
        frames = [f.ax().frame(sn.unique_control(f.ax(), strip, tab))
                  for tab in sn.TABS["Dictation Settings"]]
        rows.append(("the fixture actually models two distinct rows",
                     sorted(set(frame["y"] for frame in frames)), [120, 172]))

    blocks.append(('Wrapped tabs: every tab is visible and selectable', block_6))

    def block_7(rows):
        # Already on the route: nothing is pressed again, the state is still re-read.
        f = FakeSettings()
        _nav(f, "Dictation Settings", "Engine")
        before = list(f.presses)
        _nav(f, "Dictation Settings", "Engine")
        rows.append(("an already-landed route presses nothing", list(f.presses), before))

        # An external change after a cached navigation is seen: state is re-read, not trusted.
        f.remembered_tab = "Live Preview"     # the user clicked another tab
        _nav(f, "Dictation Settings", "Engine")
        rows.append(("a tab changed behind the harness's back is re-selected",
                     f.remembered_tab, "Engine"))

    blocks.append(('Already on the route: nothing is pressed again, the state is still re-read', block_7))

    def block_8(rows):
        # A closed window with an opener opens it first.
        f = FakeSettings(open_=False)
        _nav(f, "App Settings", "Permissions", open_settings=lambda: setattr(f, "open", True))
        rows.append(("a closed window is opened, then the page selected", f.page, "App Settings"))

    blocks.append(('A closed window with an opener opens it first', block_8))

    def block_9(rows):
        # Engine choices: opens the RIGHT Change button, selects, requires collapse + summary.
        f = FakeSettings()
        f.page, f.remembered_tab = "Dictation Settings", "Engine"
        sn.choose_engine(f.ax(), f.root, "All Languages")
        rows.append(("choose_engine opens 'Change speech engine', not the preview one, and lands",
                     (f.engine, f.choices_open, "change" in f.presses), ("All Languages", False, True)))
        sn.choose_engine(f.ax(), f.root, "Fast")
        rows.append(("restoring the engine re-opens Change before pressing",
                     (f.engine, f.presses.count("change")), ("Fast", 2)))

    blocks.append(('Engine choices: opens the RIGHT Change button, selects, requires collapse + summary', block_9))

    def block_10(rows):
        # Microphone: the stored UID is the choice; the display only names it.
        f, ax = FakeSettings(), None
        f.page, f.remembered_tab = "Dictation Settings", "Microphone & Media"
        ax = f.ax()
        got = sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel)
        rows.append(("Auto reads as Auto (stored UID empty), naming the device it resolved to",
                     got, sn.InputChoice("", "MacBook Pro Microphone")))
        picked = sn.select_input(ax, f.root, f.read_uid, auto=False, name="Studio Mic",
                                 cancel=ax.cancel)
        rows.append(("a decorated item ('Studio Mic · USB') is chosen by name and its UID stored",
                     (f.input_uid, picked), ("AppleUSBAudioEngine:Studio",
                                             sn.InputChoice("AppleUSBAudioEngine:Studio", "Studio Mic"))))
        rows.append(("a chosen device reads back by its stored UID",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel),
                     sn.InputChoice("AppleUSBAudioEngine:Studio", "Studio Mic")))
        sn.restore_input(ax, f.root, f.read_uid, got, cancel=ax.cancel)
        rows.append(("Auto is restored as Auto (UID empty), not as the device it shows",
                     f.input_uid, ""))
        f.menu_open = True
        start = len(f.presses)
        sn.select_input(ax, f.root, f.read_uid, auto=False, name="BlackHole 2ch", cancel=ax.cancel)
        rows.append(("a stale open menu is cancelled through AX before the menu is opened",
                     (f.presses[start:start + 2], f.input_uid), (["cancel", "input-open"],
                                                                 "BlackHole2ch_UID")))
        rows.append(("an InputChoice round-trips through the restore file with its UID",
                     sn.InputChoice.from_json(sn.InputChoice("BlackHole2ch_UID", "BlackHole 2ch").to_json()),
                     sn.InputChoice("BlackHole2ch_UID", "BlackHole 2ch")))

        def mic_with(devices, uid, auto_uid=None, german=False):
            f = FakeSettings(german=german)
            f.page, f.remembered_tab = "Dictation Settings", "Microphone & Media"
            f.devices, f.input_uid = devices, uid
            if auto_uid:
                f.auto_uid = auto_uid
            return f, f.ax()

        f, ax = mic_with([("C1", "Studio, microphone", None)], "C1")
        rows.append(("a comma inside a device name stays in the name",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel),
                     sn.InputChoice("C1", "Studio, microphone")))
        f, ax = mic_with([("C2", "Studio, Auto", None)], "C2")
        rows.append(("a device NAMED 'Studio, Auto' is a chosen device, not Auto",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel),
                     sn.InputChoice("C2", "Studio, Auto")))
        f, ax = mic_with([("C3", "Studio", None)], "", auto_uid="C3")
        rows.append(("Auto resolving to 'Studio' (no badge) reads as Auto naming Studio",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel), sn.InputChoice("", "Studio")))
        f, ax = mic_with([("C4", "Studio, USB", None), ("C5", "Other", "USB")], "C4")
        menus_before = f.presses.count("input-open")
        rows.append(("'Studio, USB' with no transport is settled by the menu as the whole name",
                     (sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel), f.cancels,
                      f.presses.count("input-open") - menus_before),
                     (sn.InputChoice("C4", "Studio, USB"), 1, 1)))
        f, ax = mic_with([("C6", "Studio", "USB")], "C6")
        rows.append(("'Studio' over USB is settled by the menu as Studio",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel), sn.InputChoice("C6", "Studio")))
        f, ax = mic_with([], "", auto_uid="none-connected")
        rows.append(("Auto with nothing resolved reads as Auto with no name",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel), sn.InputChoice("", None)))
        f, ax = mic_with([("G1", "MacBook Pro Microphone", "Built-in")], "", auto_uid="G1",
                         german=True)
        rows.append(("German Auto ('Automatisch · Integriert') reads as Auto",
                     sn.read_input(ax, f.root, f.read_uid, cancel=ax.cancel),
                     sn.InputChoice("", "MacBook Pro Microphone")))

    blocks.append(('Microphone: the stored UID is the choice; the display only names it', block_10))

    def block_11(rows):
        # Stored settings: the shared domain, the app's own fallbacks, refusals.
        st = sn.stored
        rows += [
            ("a missing key is the shipped default", st(lambda: {}, "selectedBackend"), "parakeet"),
            ("a stored backend is read", st(lambda: {"selectedBackend": "whisperKit"},
                                            "selectedBackend"), "whisperKit"),
            ("an unknown backend string is the default, as the app treats it",
             st(lambda: {"selectedBackend": "turbo"}, "selectedBackend"), "parakeet"),
            ("a stored Bool is read", st(lambda: {"fillerRemovalEnabled": False},
                                         "fillerRemovalEnabled"), False),
            ("a missing Bool is its default", st(lambda: {}, "wordCorrectionEnabled"), True),
            ("a stored microphone UID is read",
             st(lambda: {"preferredInputDeviceIDOverride": "X"}, "preferredInputDeviceIDOverride"), "X"),
        ]
        for why, read, key in (
            ("a domain that cannot be read refuses", lambda: (_ for _ in ()).throw(OSError("exit 1")),
             "selectedBackend"),
            ("an integer where a Bool is stored refuses", lambda: {"fillerRemovalEnabled": 1},
             "fillerRemovalEnabled"),
            ("a number where a String is stored refuses", lambda: {"selectedBackend": 3},
             "selectedBackend"),
        ):
            try:
                st(read, key)
                rows.append((why, "no refusal", "PreferenceError"))
            except sn.PreferenceError:
                rows.append((why, "PreferenceError", "PreferenceError"))

    blocks.append(("Stored settings: the shared domain, the app's own fallbacks, refusals", block_11))

    def block_12(rows):
        # Wrapped tabs can also be direct children of the strip.
        f = FakeSettings(strip_width=300, strip_group=False)
        _nav(f, "Dictation Settings", "Clipboard")
        rows.append(("a wrapped tab directly under the group is selected without scrolling",
                     (f.scrolls, f.remembered_tab), (0, "Clipboard")))

    blocks.append(('Direct wrapped tabs remain reachable', block_12))

    def block_13(rows):
        # Scan statuses.
        probes = {"yes": lambda: True, "no": lambda: False, "unknown": lambda: None,
                  "boom": lambda: 1 / 0}
        rows += [
            ("a missing required control is FAIL", sn.absent_status(None, probes), "FAIL"),
            ("a missing control whose condition holds is FAIL", sn.absent_status("yes", probes), "FAIL"),
            ("a missing control whose condition is false is N/A", sn.absent_status("no", probes), "N/A"),
            ("an unknown condition is BLOCKED, not skipped", sn.absent_status("unknown", probes),
             "BLOCKED"),
            ("an unprobed condition is BLOCKED", sn.absent_status("never-defined", probes), "BLOCKED"),
            ("a probe that raises is BLOCKED", sn.absent_status("boom", probes), "BLOCKED"),
            ("one FAIL makes the row FAIL", sn.row_status(["OK", "N/A", "FAIL", "BLOCKED"]), "FAIL"),
            ("BLOCKED without FAIL makes the row BLOCKED", sn.row_status(["OK", "BLOCKED"]), "BLOCKED"),
            ("OK and N/A make an OK row", sn.row_status(["OK", "N/A"]), "OK"),
            ("the scan covers 16 release surfaces",
             len(sn.SCAN), 16),
            ("every Dictation tab is scanned explicitly",
             sorted(t for p, t, _ in sn.SCAN if p == "Dictation Settings" and t), sorted(sn.TABS["Dictation Settings"])),
            ("every release page is scanned",
             sorted({p for p, _, _ in sn.SCAN}), sorted(sn.PAGES)),
        ]
    blocks.append(('Scan statuses', block_13))

    for name, block in blocks:
        try:
            block(rows)
        except Exception as e:  # noqa: BLE001 - reported as a failing row
            rows.append((f"block '{name}' runs to its end", f"raised {type(e).__name__}: {e}",
                         "no exception"))
    rows += scan_cases()
    rows += coverage_cases()
    rows += pr3_cases()
    return rows


# ── Scan readers on modelled rows ───────────────────────────────────────────

def _window(content, sidebar_value="Not selected"):
    """An app tree with the real sidebar and `content` as the window's content."""
    rows = [el("AXButton", desc=p, value=sidebar_value) for p in sn.SIDEBAR_LABELS]
    return el("AXApplication", children=[el("AXWindow", frame={"x": 0, "y": 0, "width": 900,
                                                                "height": 900}, children=[
        el("AXGroup", children=rows), el("AXGroup", children=list(content))])])


def _f(y, h=20, x=300, w=100):
    return {"x": x, "y": y, "width": w, "height": h}


def _ax_plain():
    return sn.AX(get_attr=lambda e, k: e.get(k) if isinstance(e, dict) else None,
                 children=lambda e: e.get("AXChildren") or [],
                 press=lambda e: e["_press"]() if e.get("_press") else False,
                 frame=lambda e: e.get("_frame"), sleep=lambda s: None,
                 clock=_Clock())


class _Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        self.t += 0.2
        return self.t


def _info(title, y):
    return el("AXButton", desc=f"About {title}", frame=_f(y, 16, x=420, w=16))


def _flat_rows():
    """Rows SwiftUI flattened into one container: each row's "?", text and control are
    siblings, told apart only by their vertical band."""
    return [
        el("AXStaticText", value="Spoken punctuation", frame=_f(100)),
        _info("Spoken punctuation", 100),
        el("AXCheckBox", desc="Spoken punctuation", value="On", frame=_f(108, 22, x=700, w=38)),
        el("AXStaticText", value="Unload model after", frame=_f(160)),
        _info("Unload model after", 160),
        el("AXPopUpButton", value="Never", frame=_f(166, 22, x=650, w=120)),
        el("AXStaticText", value="Media during dictation", frame=_f(220)),
        _info("Media during dictation", 220),
    ] + [el("AXButton", desc=f"{o}, {sym}", value=("selected" if o == "Lower" else ""),
            frame=_f(226, 26, x=500 + i * 60, w=56))
         for i, (o, sym) in enumerate([("Continue", "play.fill"), ("Lower", "speaker.wave.1"),
                                      ("Mute", "speaker.slash"), ("Pause", "pause.circle")])]


def _grouped(title, control, y=100):
    return el("AXGroup", frame=_f(y, 50, x=300, w=500), children=[
        el("AXStaticText", value=title, frame=_f(y)), _info(title, y), control])


def scan_cases():
    rows = []
    ax = _ax_plain()

    def run(content, kind, spec, hooks=None):
        root = _window(content)
        return sn.scan_control(ax, root, kind, spec, {"root_of": lambda: root, **(hooks or {})})

    # Grouped rows: ownership is the row's subtree.
    got = run([_grouped("Unload model after", el("AXPopUpButton", value="Never", frame=_f(106)))],
              "picker", "Unload model after")
    rows.append(("a picker inside its row group is read", got,
                 ("OK", "picker:Unload model after=Never")))
    # Codex's probe: a switch near the label and no picker must not read as the picker.
    got = run([el("AXGroup", children=[_grouped("Unload model after", el("AXStaticText",
                                                                         value="(none)")),
                                      el("AXCheckBox", desc="Spoken punctuation", value="1",
                                         frame=_f(110, x=700))])],
              "picker", "Unload model after")
    rows.append(("a row with no picker FAILs even with a switch nearby",
                 (got[0], "0 AXPopUpButton" in got[1]), ("FAIL", True)))
    got = run([_grouped("Unload model after", el("AXCheckBox", desc="x", value="1"))],
              "picker", "Unload model after")
    rows.append(("a wrong-role control in the row FAILs",
                 (got[0], "0 AXPopUpButton" in got[1]), ("FAIL", True)))
    got = run([_grouped("Unload model after", el("AXGroup", children=[
        el("AXPopUpButton", value="Never", frame=_f(106)),
        el("AXPopUpButton", value="Always", frame=_f(106, x=420))]))],
        "picker", "Unload model after")
    rows.append(("two pickers in one row FAIL as ambiguous",
                 (got[0], "2 AXPopUpButton" in got[1]), ("FAIL", True)))
    got = run([_grouped("Unload model after", el("AXPopUpButton", value="", frame=_f(106)))],
              "picker", "Unload model after")
    rows.append(("a picker with no readable value FAILs",
                 (got[0], "unreadable" in got[1]), ("FAIL", True)))
    got = run([], "picker", "Unload model after")
    rows.append(("a row that is not on the page is absent (its condition decides)", got[0], None))

    # Flattened rows: ownership is the band from this "?" to the next one.
    got = run(_flat_rows(), "picker", "Unload model after")
    rows.append(("in flattened rows the picker in its band is read", got,
                 ("OK", "picker:Unload model after=Never")))
    flat_no_popup = [e for e in _flat_rows() if e["AXRole"] != "AXPopUpButton"]
    flat_no_popup.append(el("AXPopUpButton", value="Decoy", frame=_f(226, 22, x=820, w=60)))
    got = run(flat_no_popup, "picker", "Unload model after")
    rows.append(("a picker in the NEXT row's band is not this row's (FAIL)",
                 (got[0], "0 AXPopUpButton" in got[1]), ("FAIL", True)))
    got = run(_flat_rows(), "segments", ("Media during dictation",
                                         ("Continue", "Lower", "Mute", "Pause")))
    rows.append(("icon segments ('Lower, speaker.wave.1') are read by option name", got,
                 ("OK", "segments:Media during dictation=Lower, speaker.wave.1")))
    bad = [dict(e, AXValue="") if e.get("AXValue") == "selected" else e for e in _flat_rows()]
    got = run(bad, "segments", ("Media during dictation", ("Continue", "Lower", "Mute", "Pause")))
    rows.append(("an option group with nothing selected FAILs", got[0], "FAIL"))
    missing = [e for e in _flat_rows() if not str(e.get("AXDescription", "")).startswith("Mute")]
    got = run(missing, "segments", ("Media during dictation",
                                    ("Continue", "Lower", "Mute", "Pause")))
    rows.append(("an option group missing an option FAILs", got[0], "FAIL"))
    got = run([e for e in _flat_rows() if e.get("_frame") and e["_frame"]["y"] < 150]
              + [_info("Unload model after", 160)], "picker", "Unload model after")
    rows.append(("a flattened row with no control in its band FAILs",
                 (got[0], "0 AXPopUpButton" in got[1]), ("FAIL", True)))
    unframed = [dict(e, _frame=None) if e["AXRole"] == "AXPopUpButton" else e for e in _flat_rows()]
    got = run(unframed, "picker", "Unload model after")
    rows.append(("a candidate without a readable frame FAILs, never guessed",
                 (got[0], "no readable frame" in got[1]), ("FAIL", True)))

    # Pause duration as production lays it out: title, then the slider, then the short line
    # with its "?" BELOW the slider; the rows above and below hold decoy sliders.
    def pause_rows(grouped):
        prev = [el("AXStaticText", value="Stop recording on silence", frame=_f(40)),
                _info("Stop recording on silence", 40),
                el("AXSlider", value=9, frame=_f(48, 20, x=600))]
        row = [el("AXStaticText", value="Pause duration", frame=_f(100)),
               el("AXSlider", value=1.5, frame=_f(124, 20, x=360, w=300)),
               el("AXStaticText", value="How long a pause ends the recording.", frame=_f(152)),
               _info("Pause duration", 152)]
        nxt = [el("AXStaticText", value="Remove filler words", frame=_f(200)),
               _info("Remove filler words", 200),
               el("AXSlider", value=7, frame=_f(206, 20, x=600))]
        if grouped:
            return [el("AXGroup", children=prev, frame=_f(30, 50, w=500)),
                    el("AXGroup", children=row, frame=_f(95, 80, w=500)),
                    el("AXGroup", children=nxt, frame=_f(190, 50, w=500))]
        return prev + row + nxt
    for shape in ("grouped", "flattened"):
        got = run(pause_rows(shape == "grouped"), "slider", "Pause duration")
        rows.append((f"Pause duration's slider ABOVE its \"?\" is read ({shape} rows, decoys "
                     "above and below)", got, ("OK", "slider:Pause duration=1.5")))

    # Sockets: numbered options or one popup.
    sockets = [el("AXButton", desc=f"Input {i}", value=("selected" if i == 2 else ""),
                  frame=_f(106, x=500 + i * 60, w=56)) for i in (1, 2, 3)]
    got = run([_grouped("Mic is on", el("AXGroup", children=sockets))], "segments",
              ("Mic is on", None))
    rows.append(("numbered socket options read the selected one", got,
                 ("OK", "segments:Mic is on=Input 2")))
    got = run([_grouped("Mic is on", el("AXPopUpButton", value="Input 7", frame=_f(106)))],
              "segments",
              ("Mic is on", None))
    rows.append(("more than six sockets read through their popup", got,
                 ("OK", "segments:Mic is on=Input 7")))

    # Slider and a row's own button.
    got = run([_grouped("Pause duration", el("AXSlider", value=1.5, frame=_f(110)))], "slider",
              "Pause duration")
    rows.append(("the row's slider is read", got, ("OK", "slider:Pause duration=1.5")))
    got = run([_grouped("Auto-detect language", el("AXButton", desc="Reset", frame=_f(106)))],
              "rowbtn",
              ("Auto-detect language", "Reset"))
    rows.append(("a row's own button is found inside its row", got[0], "OK"))
    got = run([_grouped("Auto-detect language", el("AXStaticText", value="x")),
               el("AXButton", desc="Reset", frame=_f(400))], "rowbtn",
              ("Auto-detect language", "Reset"))
    rows.append(("a same-named button outside the row is not the row's (FAIL)",
                 (got[0], "0 AXButton" in got[1]), ("FAIL", True)))

    # Switches: the style's spoken On/Off and the classic 1/0 both read.
    got = run([el("AXCheckBox", desc="Smart insertion", value="Off")], "toggle", "Smart insertion")
    rows.append(("a switch reading 'Off' is OFF", got, ("OK", "toggle:Smart insertion=OFF")))
    got = run([el("AXCheckBox", desc="Show app in Dock, When off, the Dock icon...", value=1)],
              "toggle^", "Show app in Dock")
    rows.append(("a two-line switch label is matched by its first line", got[0], "OK"))
    got = run([el("AXCheckBox", desc="Smart insertion", value="maybe")], "toggle",
              "Smart insertion")
    rows.append(("a switch with an unreadable value FAILs", got[0], "FAIL"))
    got = run([el("AXCheckBox", desc="Smart insertion", value="On"),
               el("AXCheckBox", desc="Smart insertion", value="On")], "toggle", "Smart insertion")
    rows.append(("two switches with one name FAIL as ambiguous", got[0], "FAIL"))
    got = run([el("AXButton", desc="Vocabulary Packs"), el("AXStaticText", value="x")], "named",
              "Vocabulary Packs")
    rows.append(("a text anchor is never satisfied by a button of that name", got[0], None))

    # The popover: the one that opened is read, then closed through AX on EVERY path.
    class Pop:
        def __init__(self, closes=True, wrapped=True, switches=1):
            self.open, self.closes, self.wrapped, self.switches = False, closes, wrapped, switches
            self.cancels = 0

        def root(self):
            kids = [el("AXButton", desc="Learn more", press=lambda: setattr(self, "open", True))]
            if self.open:
                sws = [el("AXCheckBox", desc="Show Bluetooth tips", value="On")
                       for _ in range(self.switches)] or [el("AXStaticText", value="Tips")]
                kids += [el("AXPopover", children=sws)] if self.wrapped else sws
            return _window(kids)

        def cancel(self, e):
            self.cancels += 1
            if self.closes:
                self.open = False

    def pop_run(pop):
        try:
            got = sn.scan_control(ax, pop.root(), "popover", ("Learn more", "Show Bluetooth tips"),
                                  {"root_of": pop.root, "cancel": pop.cancel})[0]
        except sn.ScanStop:
            got = "STOP"
        return got, pop.cancels, pop.open
    for why, pop, want in [
        ("a popover switch is read and the popover closed through AX", Pop(), ("OK", 1, False)),
        ("a popover missing its switch FAILs and is still closed", Pop(switches=0),
         ("FAIL", 1, False)),
        ("two switches in the popover FAIL and it is still closed", Pop(switches=2),
         ("FAIL", 1, False)),
        ("a popover that will not close stops the scan", Pop(closes=False), ("STOP", 1, True)),
        ("no recognisable popover appearing stops the scan", Pop(wrapped=False),
         ("STOP", 0, True)),
    ]:
        rows.append((why, pop_run(pop), want))

    # A stop ends the surface: no later control on it is read or pressed.
    pop = Pop(wrapped=False)
    later = []
    root = pop.root

    def root_with_later():
        r = root()
        r["AXChildren"][0]["AXChildren"][1]["AXChildren"].append(
            el("AXButton", desc="Later", press=lambda: later.append("pressed")))
        return r
    try:
        sn.scan_surface(ax, root_with_later, [("popover", ("Learn more", "Show Bluetooth tips"),
                                               None), ("button", "Later", None)],
                        {}, {"cancel": pop.cancel})
        got = "returned"
    except sn.ScanStop:
        got = "stopped"
    rows.append(("a scan stop propagates out of the surface before its next control",
                 (got, later), ("stopped", [])))

    # The language button by its template, the comparison link, the Model popup.
    got = run([el("AXButton", desc="Change dictation language: English (United States), from your Mac")],
              "prefix", sn.PREVIEW_LANGUAGE)
    rows.append(("the preview language button is found by its template's fixed start", got[0], "OK"))
    got = run([el("AXLink", desc="Compare engines, arrow.up.right")], "link", "Compare engines")
    rows.append(("the comparison link is found without being pressed", got[0], "OK"))
    got = run([el("AXStaticText", value="Model"), el("AXPopUpButton", title="Model", value="gpt-5")],
              "popup", "Model")
    rows.append(("the Model popup is read, not the card title of the same name", got,
                 ("OK", "popup:Model=gpt-5")))

    # Engine choosers: opened, the Selected card read, closed with Keep, nothing chosen.
    class Chooser:
        def __init__(self, selected=("Fast",), keep_works=True):
            self.open, self.selected, self.keep_works, self.chosen = False, selected, keep_works, []

        def root(self):
            if not self.open:
                kids = [el("AXButton", desc=sn.CHANGE_ENGINE,
                           press=lambda: setattr(self, "open", True))]
            else:
                kids = [el("AXButton", desc=c, value=("Selected" if c in self.selected else ""),
                           press=lambda c=c: self.chosen.append(c)) for c in sn.ENGINE_LABELS]
                kids.append(el("AXButton", desc="Keep current engine",
                               press=lambda: setattr(self, "open", not self.keep_works)))
            return _window(kids)

    def chooser_run(c):
        try:
            got = sn.scan_control(ax, c.root(), "disclose", sn.ENGINE_DISCLOSURE,
                                  {"root_of": c.root})[0]
        except sn.ScanStop:
            got = "STOP"
        return got, c.open, c.chosen
    rows += [
        ("an engine chooser is read and closed with nothing chosen", chooser_run(Chooser()),
         ("OK", False, [])),
        ("two Selected engine cards FAIL and the chooser is still closed",
         chooser_run(Chooser(selected=("Fast", "All Languages"))), ("FAIL", False, [])),
        ("a chooser that will not close stops the scan", chooser_run(Chooser(keep_works=False)),
         ("STOP", True, [])),
    ]

    # Dictionary sections: each is selected and read, then the first one is selected again.
    class Dict:
        def __init__(self, anchors=True):
            self.section, self.anchors, self.presses = "Vocabulary Packs", anchors, []

        def root(self):
            rail = [el("AXButton", desc=s, value=("Selected" if s == self.section else
                                                   "Not selected"),
                       press=(lambda s=s: (self.presses.append(s),
                                           setattr(self, "section", s))))
                    for s in sn.DICTIONARY_SECTIONS]
            body = {"Your Words": el("AXButton", desc="Add word"),
                    "Vocabulary Packs": el("AXStaticText", value="VOCABULARY PACKS"),
                    "Learn from...": el("AXCheckBox", desc="Self-Learning Dictionary", value="1"),
                    "Quick Add": el("AXStaticText", value="Highlight a word")}[self.section]
            kids = [el("AXCheckBox", desc="Enable Dictionary", value="1"),
                    el("AXGroup", desc="Dictionary section", children=rail)]
            return _window(kids + ([body] if self.anchors else []))
    d = Dict()
    surface = [c for p, _, c in sn.SCAN if p == "Dictionary"][0]
    out = sn.scan_surface(ax, d.root, surface, {}, {})
    rows.append(("every Dictionary section is selected and read, then the first one again",
                 ([s for s, _ in out], d.presses, d.section),
                 (["OK"] * 6, ["Your Words", "Vocabulary Packs", "Learn from...", "Quick Add",
                               "Vocabulary Packs"], "Vocabulary Packs")))
    d = Dict(anchors=False)
    out = sn.scan_surface(ax, d.root, surface, {}, {})
    rows.append(("a selected section that shows nothing FAILs, and the first is selected again",
                 [s for s, _ in out][1:], ["FAIL"] * 4 + ["OK"]))

    class StuckDict(Dict):
        """Refuses to go back to the first section."""
        def root(self):
            r = Dict.root(self)
            if self.section != "Vocabulary Packs":
                for b in r["AXChildren"][0]["AXChildren"][1]["AXChildren"][1]["AXChildren"]:
                    if b["AXDescription"] == "Vocabulary Packs":
                        b["_press"] = lambda: None
            return r
    d = StuckDict()
    out = sn.scan_surface(ax, d.root, surface, {}, {})
    rows.append(("a restore that does not land is a FAIL row, not a quiet OK",
                 (out[-1][0], d.section), ("FAIL", "Quick Add")))

    class UnreadDict(Dict):
        def root(self):
            r = Dict.root(self)
            for b in r["AXChildren"][0]["AXChildren"][1]["AXChildren"][1]["AXChildren"]:
                b["AXValue"] = ""
            return r
    d = UnreadDict()
    out = sn.scan_surface(ax, d.root, surface, {}, {})
    rows.append(("an unreadable section selection changes no section (BLOCKED)",
                 ([s for s, _ in out][1:], d.presses), (["BLOCKED"] * 4, [])))
    return rows


# ── Coverage: the PR1 inventory against the manifest ───────────────────────

# Every interactive row of inventory 05 sections 1, 3-5, 7 (pill position), 8-10 and the §21
# Dictionary and DEBUG Diagnostics surfaces, written from that inventory (not from SCAN): each
# must be scanned (surface, kind, spec) or exempted by key in `SCAN_EXEMPT`.
E, M, L, P, C, K = (("Dictation Settings", t) for t in sn.TABS["Dictation Settings"])
INVENTORY = [
    ("1 engine cards (behind Change)", E, ("disclose", sn.ENGINE_DISCLOSURE)),
    ("1 WhisperKit model actions", E, ("one_of", sn.WHISPERKIT_ACTIONS)),
    ("1 WhisperKit re-check", E, ("button", "Re-check model status")),
    ("1 Fast read-only re-check", E, ("button", "Re-check Fast model status")),
    ("1 Auto-detect language", E, ("toggle", "Auto-detect language")),
    ("1 Change (language)", E, ("button", "Change dictation language")),
    ("1 Reset (Language suggestions)", E, ("rowbtn", ("Auto-detect language", "Reset"))),
    ("1 Stop recording on silence", E, ("toggle", "Stop recording on silence")),
    ("1 Pause duration", E, ("slider", "Pause duration")),
    ("1 Parakeet delivery Cancel/Resume/Try Again", E, ("one_of", sn.PARAKEET_ACTIONS)),
    ("1 Faster Transcription", E, ("toggle", "Faster Transcription")),
    ("1 per-engine ? help", None, "info-buttons"),
    ("1 Remove filler words", E, ("toggle", "Remove filler words (um, uh, hmm...)")),
    ("1 Convert spoken emoji", E, ("toggle", sn.EMOJI_TITLE)),
    ("1 Spoken punctuation", E, ("toggle", "Spoken punctuation")),
    ("1 Unload model after", E, ("picker", "Unload model after")),
    ("3 Input device", M, ("input", sn.INPUT_DEVICE)),
    ("3 Input socket", M, ("segments", ("Mic is on", None))),
    ("4 Media during dictation", M, ("segments", ("Media during dictation",
                                                 ("Continue", "Lower", "Mute", "Pause")))),
    ("3 Microphone readiness", M, ("segments", ("Microphone readiness",
                                               ("Off", "10 sec", "30 sec", "60 sec", "Always")))),
    ("3 Always warning", None, "readiness-always-warning"),
    ("4 Media warnings", None, "media-mode-warnings"),
    ("3 Bluetooth Learn more", M, ("rowbtn", ("Using a Bluetooth microphone?", "Learn more"))),
    ("3 Show Bluetooth tips", M, ("popover", ("Learn more", "Show Bluetooth tips"))),
    ("5 Language button", L, ("prefix", sn.PREVIEW_LANGUAGE)),
    ("5 Live Preview toggle", L, ("toggle", "Show words while you speak")),
    ("5 Browse downloads", L, ("button", "Browse downloads")),
    ("5 Learn more / Compare engines", L, ("link", "Compare engines")),
    ("5 Apple / Universal cards", L, ("disclose", sn.PREVIEW_DISCLOSURE)),
    ("5 Universal footer actions", L, ("one_of", sn.UNIVERSAL_ACTIONS)),
    ("5 Install new languages", L, ("one_of", sn.INSTALL_ROW_TITLES)),
    ("7 Pill position", P, ("segments", ("Position on screen", ("Top", "Bottom")))),
    ("8 design tiles", P, ("cards", "pill")),
    ("8 greyed reasons", None, "pill-greyed-reason"),
    ("8 Configure Live Preview", P, ("button", "Configure Live Preview")),
    ("9 Play recording chimes", C, ("toggle", "Play recording chimes")),
    ("9 per-card Preview", C, ("button", "Preview Air Glint")),
    ("9 pairing cards", C, ("cards", "chime")),
    ("10 Auto-copy", K, ("toggle", "Auto-copy to clipboard")),
    ("10 Restore clipboard", K, ("toggle", "Restore clipboard after paste")),
    ("10 Smart insertion", K, ("toggle", "Smart insertion")),
    ("10 Read selections", K, ("toggle", "Read selections through the clipboard")),
    ("21 Enable Dictionary", ("Dictionary", None), ("toggle", "Enable Dictionary")),
    ("21 Your Words", ("Dictionary", None), ("section", ("Your Words", "button", "Add word"))),
    ("21 Vocabulary Packs", ("Dictionary", None),
     ("section", ("Vocabulary Packs", "named", "Vocabulary Packs"))),
    ("21 Learn from", ("Dictionary", None),
     ("section", ("Learn from...", "toggle", "Self-Learning Dictionary"))),
    ("21 Quick Add", ("Dictionary", None), ("section", ("Quick Add", "named", "Highlight a word"))),
] + [(f"21 Diagnostics {label}", ("Diagnostics", None), (kind, label)) for kind, label in [
    ("toggle", "Enable debug mode"), ("toggle", "Use tuned on-device adapter (PoC)"),
    ("named", "Log Level"), ("named", "Simulate AI polish state"),
    ("button", "Restart Onboarding…"), ("toggle", "Save dictation audio for debugging"),
    ("button", "Open Log Directory"), ("button", "Copy Log Path"), ("button", "Clear Logs"),
    ("button", "Open Console.app"), ("button", "Run ASR Benchmark"),
    ("button", "Run Pipeline Benchmark")]]


def coverage_cases():
    manifest = {(p, t, k, spec) for p, t, cs in sn.SCAN + sn.SCAN_DEBUG for k, spec, _ in cs}
    missing = []
    for row, surface, want in INVENTORY:
        if surface is None:
            if want not in sn.SCAN_EXEMPT:
                missing.append(f"{row}: exemption {want!r} not recorded")
        elif (surface[0], surface[1], want[0], want[1]) not in manifest:
            missing.append(f"{row}: {surface} {want} not scanned")
    used = {key for _, s, key in INVENTORY if s is None}
    order = _capture_before_routing()
    conditions = {c for _, _, cs in sn.SCAN + sn.SCAN_DEBUG for _, _, c in cs if c}
    return [
        ("every PR1 inventory row is scanned or exempted with a reason", missing, []),
        ("every exemption is one an inventory row uses", sorted(set(sn.SCAN_EXEMPT) - used), []),
        ("each microphone caller captures the app's choice before it switches any audio",
         order, []),
        ("the Diagnostics inventory has its 12 controls", sum(
            1 for _, s, _ in INVENTORY if s == ("Diagnostics", None)), 12),
        ("the conditions the manifest names", sorted(conditions), sorted([
            "apple_packs_shown", "debug_mode_on", "language_locked", "language_section_visible",
            "model_picker_shown", "polish_enabled", "multi_input_device", "parakeet_delivery_actions_shown",
            "pill_holds_words", "preview_language_shown", "preview_needs_language",
            "universal_engine_built", "vad_auto_stop", "whisperkit_actions_shown",
            "whisperkit_recheck_shown", "parakeet_selected"])),
    ]



def _capture_before_routing():
    """Problems with the callers' order, read from their source: `AudioRoute.__init__` must
    capture the app's choice (`read_input_choice`, which refuses an unrestorable original) and
    switch nothing; the switching happens in `apply`. The #1946 helper lives in the main
    checkout and is checked when present."""
    import ast
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    paths = [os.path.join(here, "silent_audio.py")]
    band = os.path.join(os.path.dirname(os.path.dirname(here)), "docs", "feature-requests",
                        "issue-1946-artifacts", "2026-09-08-live-uat-background-band.py")
    if os.path.exists(band):
        paths.append(band)
    problems = []
    for path in paths:
        tree = ast.parse(open(path).read())
        cls = next((n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)
                    and n.name == "AudioRoute"), None)
        if cls is None:
            problems.append(f"{os.path.basename(path)}: no AudioRoute")
            continue
        methods = {f.name: ast.unparse(f) for f in cls.body if isinstance(f, ast.FunctionDef)}
        init, apply_ = methods.get("__init__", ""), methods.get("apply", "")
        if "read_input_choice" not in init:
            problems.append(f"{os.path.basename(path)}: __init__ does not capture the choice")
        if "'-s'" in init or "select_input" in init:
            problems.append(f"{os.path.basename(path)}: __init__ switches audio")
        if "'-s'" not in apply_:
            problems.append(f"{os.path.basename(path)}: apply does not do the switching")
    return problems


def pr3_cases():
    """PR3 harness contracts on literal trees, independent of SCAN's manifest."""
    rows = []
    for german in (False, True):
        translations = {
            "Change paste last dictation keybind": "Tastenkürzel zum Einfügen ändern",
            "Paste last dictation": "Letztes Diktat einfügen",
            "Reset keybind to default": "Tastenkürzel zurücksetzen",
            "About %@": "Über %@", "Apple Intelligence": "Apple Intelligence",
            "Selected": "Ausgewählt", "Not selected": "Nicht ausgewählt",
            "Trigger": "Auslöser", "Text to paste": "Einzufügender Text",
        } if german else {}
        ax = _ax_plain()
        ax.terms = lambda text: [text] + ([translations[text]] if text in translations else [])
        tr = lambda text: translations.get(text, text)
        label = "Change paste last dictation keybind"
        title = "Paste last dictation"
        field = el("AXButton", desc=tr(label), value="⌃⌘ V", frame=_f(30))
        action = el("AXButton", desc=tr(label), frame=_f(30, x=500))
        reset = el("AXButton", desc=tr("Reset keybind to default"), frame=_f(65))
        other_reset = el("AXButton", desc=tr("Reset keybind to default"), frame=_f(66))
        info = el("AXButton", desc=tr("About %@").replace("%@", tr(title)), frame=_f(20))
        other_info = el("AXButton", desc=tr("About %@").replace("%@", "Copy last dictation"),
                        frame=_f(60, x=10))
        group = el("AXGroup", children=[info, field, action, reset])
        root = _window([group, el("AXGroup", children=[other_info, other_reset])])
        rows.append((f"PR3 {german}: readable field wins over same-label Change",
                     sn.keybind_control(ax, root, label) is field, True))
        rows.append((f"PR3 {german}: Reset stays inside the recorder row",
                     sn.keybind_control(ax, root, label, reset=True) is reset, True))
        rows.append((f"PR3 {german}: scan finds field and separate Change",
                     sn.scan_control(ax, root, "keybind", label, {})[0], "OK"))
        group["AXChildren"].remove(reset)
        rows.append((f"PR3 {german}: absent own Reset never borrows another row's",
                     sn.keybind_control(ax, root, label, reset=True), None))
        group["AXChildren"].remove(action)
        rows.append((f"PR3 {german}: missing Change fails even with a field",
                     sn.scan_control(ax, root, "keybind", label, {})[0], "FAIL"))
        # SwiftUI may flatten recorder rows into one container; only the band separates them.
        flat_reset = el("AXButton", desc=tr("Reset keybind to default"), frame=_f(65))
        next_info = el("AXButton", desc=tr("About %@").replace("%@", "Copy last dictation"),
                       frame=_f(120, x=10))
        next_reset = el("AXButton", desc=tr("Reset keybind to default"), frame=_f(160))
        flat = el("AXGroup", children=[info, field, flat_reset, next_info, next_reset])
        flat_root = _window([flat])
        rows.append((f"PR3 {german}: flattened rows: Reset is this row's own",
                     sn.keybind_control(ax, flat_root, label, reset=True) is flat_reset, True))
        flat["AXChildren"].remove(flat_reset)
        rows.append((f"PR3 {german}: flattened rows: no own Reset never borrows the next row's",
                     sn.keybind_control(ax, flat_root, label, reset=True), None))
        chosen = {"name": "Ollama"}
        def tile(name):
            return el("AXButton", desc=tr(name) + ", on this Mac",
                      value=tr("Selected" if chosen["name"] == name else "Not selected")
                      + ", Ready", press=lambda: chosen.update(name=name))
        root_of = lambda: _window([tile("Apple Intelligence"), tile("Ollama")])
        sn.select_provider(ax, root_of, "Apple Intelligence")
        rows.append((f"PR3 {german}: Apple selection is observed before diagnostics",
                     chosen["name"], "Apple Intelligence"))
        sn.select_provider(ax, root_of, "Ollama")
        rows.append((f"PR3 {german}: original provider is restored", chosen["name"], "Ollama"))
        stale = _window([el("AXButton", desc=tr("Apple Intelligence") + ", on this Mac",
                            value=tr("Not selected") + ", Ready")])
        try:
            sn.select_provider(ax, lambda: stale, "Apple Intelligence")
            got = "returned"
        except sn.NavigationError:
            got = "refused"
        rows.append((f"PR3 {german}: a press that does not select Apple refuses", got, "refused"))
        trigger = el("AXTextField", desc=tr("Trigger"))
        text = el("AXTextArea", desc=tr("Text to paste"))
        sheet = el("AXSheet", children=[trigger, text])
        controls = sn.snippet_edit_controls(ax, sheet)
        rows.append((f"PR3 {german}: snippet reads Trigger and Text to paste inside its sheet",
                     (controls["Trigger"] is trigger, controls["Text to paste"] is text),
                     (True, True)))
        try:
            sn.snippet_edit_controls(ax, el("AXSheet", children=[el("AXTextField", desc="Snippet")]))
            got = "returned"
        except sn.ControlError:
            got = "refused"
        rows.append((f"PR3 {german}: old snippet editor labels are refused", got, "refused"))
    state = {"open": False}
    def opener(): state["open"] = True
    def cancel(): state["open"] = False
    def root_of():
        return _window([el("AXButton", desc="Add snippet", press=opener)] + ([
            el("AXSheet", children=[el("AXTextField", desc="Trigger"),
                el("AXTextArea", desc="Text to paste"), el("AXButton", desc="Cancel", press=cancel),
                el("AXButton", desc="Save")])] if state["open"] else []))
    ax = _ax_plain()
    result = sn.scan_control(ax, root_of(), "snippet_sheet", "Add snippet", {"root_of": root_of})
    rows.append(("PR3: snippet scan reads the new draft then cancels", result[0], "OK"))
    rows.append(("PR3: snippet scan observes the sheet closed", state["open"], False))
    state["open"] = True
    try:
        sn.scan_control(ax, root_of(), "snippet_sheet", "Add snippet", {"root_of": root_of})
        got = "returned"
    except sn.ScanStop:
        got = "refused"
    rows.append(("PR3: an existing draft is neither edited nor dismissed", (got, state["open"]),
                 ("refused", True)))
    return rows


if __name__ == "__main__":
    raise SystemExit(sn._self_test())
