"""Settings search arrival on the real Debug app (#3545 plan section 11.1).

    python3 Tests/RuntimeUAT/settings_search_uat.py --run-dir <existing dir> [--only <probe name>]
    python3 Tests/RuntimeUAT/uat.py run settings-search --run-dir <existing dir>
    python3 Tests/RuntimeUAT/settings_search_uat.py --self-test

Each probe starts on a Settings page (and tab), types a search into the sidebar's search field
through accessibility (AXValue), presses the named result row (AXPress) and then reads what the
app did: the process is still alive, a NEW `arrival landed=<kind> entry=<id> at=<id>` line for
that result is in `app.log` (written by the Debug build's `SettingsArrivalModifier`, category
`SettingsMap`), and the selected sidebar page (and tab, where the route table names tabs) is
the result's destination. Searching only navigates: no probe presses a setting or an action.

Every wait is bounded and ends on the observation it waits for. A probe whose own driving step
cannot be done (no search field, no result row, navigation refused) is INSTRUMENT, not FAIL.

Exit: 0 every probe PASS, 1 a probe FAIL, 2 an INSTRUMENT problem and no FAIL. Receipts:
<run dir>/settings-search.json (one row per probe) and the console.
"""
import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# The seven probes of plan section 11.1. `row_has` is extra text the result row must also show
# when the title alone is ambiguous. `kinds` are the ladder rungs this probe accepts: the row
# itself, or the documented lower rung when the row is hidden in the founder's current state.
PROBES = [
    {"name": "self-learning-dictionary", "page": "Dictionary", "tab": None,
     "query": "self-learning", "title": "Self-Learning Dictionary", "row_has": None,
     "entry": "selfLearningDictionary", "dest_page": "Dictionary", "dest_tab": None,
     "kinds": ("target",)},
    {"name": "unload-model-from-clipboard", "page": "Dictation Settings", "tab": "Clipboard",
     "query": "unload model", "title": "Unload model after", "row_has": None,
     "entry": "unloadModel", "dest_page": "Dictation Settings", "dest_tab": "Engine",
     "kinds": ("target",)},
    {"name": "auto-copy-from-engine", "page": "Dictation Settings", "tab": "Engine",
     "query": "auto-copy", "title": "Auto-copy to clipboard", "row_has": None,
     "entry": "autoCopyToClipboard", "dest_page": "Dictation Settings", "dest_tab": "Clipboard",
     "kinds": ("target",)},
    {"name": "microphone-tab-from-keybinds", "page": "Keybinds", "tab": None,
     "query": "microphone", "title": "Microphone", "row_has": "Dictation",
     "entry": "dictation.tab.microphone", "dest_page": "Dictation Settings",
     "dest_tab": "Microphone", "kinds": ("target",)},
    {"name": "enable-dictionary-from-app-settings", "page": "App Settings", "tab": "Appearance",
     "query": "enable dictionary", "title": "Enable Dictionary", "row_has": None,
     "entry": "enableDictionary", "dest_page": "Dictionary", "dest_tab": None,
     "kinds": ("target",)},
    {"name": "chime-choice-from-engine", "page": "Dictation Settings", "tab": "Engine",
     "query": "dust mote", "title": "Dust Mote", "row_has": None,
     "entry": "recordingChime.dustMote", "dest_page": "Dictation Settings", "dest_tab": "Chimes",
     "kinds": ("target",)},
    # Save shows only while a key is being typed; with no draft the row is hidden and the
    # arrival lands on a lower rung of its ladder. The probe never types or saves a key.
    {"name": "api-key-save", "page": "AI Polish", "tab": None,
     "query": "api key save", "title": "Save", "row_has": None,
     "entry": "apiKey.save", "dest_page": "AI Polish", "dest_tab": None,
     "kinds": ("target", "fallback", "section", "landing")},
]

ARRIVAL = re.compile(r"arrival landed=(\w+) entry=(\S+) at=(\S+)( upgrade=true)?")


def arrival_lines(lines, entry):
    """The arrival lines for `entry` in `lines`, oldest first, as (kind, at, upgrade)."""
    found = []
    for line in lines:
        m = ARRIVAL.search(line)
        if m and m.group(2) == entry:
            found.append((m.group(1), m.group(3), bool(m.group(4))))
    return found


def verdict(probe, alive, arrivals, page, tab):
    """PASS / FAIL with the reason, from what the run observed."""
    if not alive:
        return "FAIL", "the app is no longer running"
    if not arrivals:
        return "FAIL", "no arrival line for this result was logged"
    kind = arrivals[-1][0]
    if kind not in probe["kinds"]:
        return "FAIL", f"landed on {kind}, expected one of {list(probe['kinds'])}"
    if page != probe["dest_page"]:
        return "FAIL", f"the selected page is {page!r}, expected {probe['dest_page']!r}"
    if probe["dest_tab"] is not None and tab != probe["dest_tab"]:
        return "FAIL", f"the selected tab is {tab!r}, expected {probe['dest_tab']!r}"
    return "PASS", f"landed on {kind}"


def _label(u, el):
    return " ".join(str(u.get_attr(el, a) or "") for a in ("AXTitle", "AXDescription", "AXValue"))


def run_probe(probe, w, u, sn, pid):
    row = {"name": probe["name"], "start": [probe["page"], probe["tab"]], "query": probe["query"],
           "entry": probe["entry"]}

    def instrument(reason):
        row.update(outcome="INSTRUMENT", reason=reason)
        return row

    if not w.nav(probe["page"], probe["tab"]):
        return instrument("navigation to the starting page was refused")
    # Labels in every shipped interface language (the app may run in German).
    ax = w._ax()
    placeholders = tuple(t.casefold() for t in ax.terms("Search settings"))
    titles = [t for t in ax.terms(probe["title"])]
    hints = None if probe["row_has"] is None else ax.terms(probe["row_has"])
    fields = [e for e in u.find_all_elements(w._app, role="AXTextField")
              if (u.get_attr(e, "AXPlaceholderValue") or "").casefold().startswith(placeholders)]
    if len(fields) != 1:
        return instrument(f"expected one search field, found {len(fields)}")
    field = fields[0]
    u.set_attr(field, "AXFocused", True)
    u.set_attr(field, "AXValue", "")
    # The log is stamped to the second and its reader folds identical lines, so the search starts
    # in a fresh second: every arrival line in the window was written after this point.
    start = _dt.datetime.now().astimezone().replace(microsecond=0) + _dt.timedelta(seconds=1)
    if not u.wait_for_condition(lambda: _dt.datetime.now().astimezone() >= start, timeout=2.0,
                                interval=0.01, description="a fresh log second"):
        return instrument("could not start in a fresh log second")
    u.set_attr(field, "AXValue", probe["query"])

    def matching_rows():
        rows = []
        for b in u.find_all_elements(w._app, role="AXButton"):
            label = _label(u, b)
            if any(label.startswith(t) or (" " + t) in (" " + label) for t in titles) and (
                    hints is None or any(h in label for h in hints)):
                rows.append((b, label))
        return rows

    found = {}

    def rows_shown():
        found["rows"] = matching_rows()
        return bool(found["rows"])

    if not u.wait_for_condition(rows_shown, timeout=5.0, description="result rows"):
        return instrument(f"no result row titled {probe['title']!r}")
    element, label = found["rows"][0]
    row["chosen_row"] = label.strip()
    u.perform_action(element, "AXPress")

    def arrived():
        found["arrivals"] = arrival_lines(w.log_lines_since(start), probe["entry"])
        return bool(found["arrivals"])

    u.wait_for_condition(arrived, timeout=8.0, interval=0.3, description="arrival line")
    alive = subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode == 0
    arrivals = found.get("arrivals", [])
    page = tab = None
    if alive:
        ax = w._ax()
        root = w._app
        side = sn.sidebar(ax, root)
        selected = [p for p in sn.PAGES
                    if sn.selection_state(ax, ax.get_attr(sn.unique_control(ax, side, p), "AXValue"))]
        page = selected[0] if len(selected) == 1 else None
        if page in sn.TABS:
            tab = sn.current_tab(ax, root, page)
    outcome, reason = verdict(probe, alive, arrivals, page, tab)
    row.update(outcome=outcome, reason=reason, alive=alive, arrivals=arrivals,
               selected=[page, tab], log_window_start=start.isoformat())
    u.set_attr(field, "AXValue", "")
    return row


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-dir")
    parser.add_argument("--only", choices=[p["name"] for p in PROBES])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return _self_test()
    if not args.run_dir or not os.path.isdir(args.run_dir):
        print("REFUSED: pass --run-dir <existing directory>")
        return 2
    import settings_nav as sn
    import ui_helpers as u
    import wispr_eyes as w
    w.connect()
    pid = w._pid
    rows = []
    for probe in PROBES:
        if args.only and probe["name"] != args.only:
            continue
        row = run_probe(probe, w, u, sn, pid)
        rows.append(row)
        print(f"{row['outcome']:<10} {row['name']}: {row.get('reason')} "
              f"selected={row.get('selected')} arrivals={row.get('arrivals')}")
        if row.get("alive") is False:
            break
    with open(os.path.join(args.run_dir, "settings-search.json"), "w") as fh:
        json.dump({"pid": pid, "probes": rows}, fh, indent=2)
    outcomes = {r["outcome"] for r in rows}
    if "FAIL" in outcomes:
        return 1
    if "INSTRUMENT" in outcomes or not rows:
        return 2
    return 0


def _self_test():
    failures = []

    def check(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        if not cond:
            failures.append(name)

    lines = [
        "[2026-10-09 01:00:00] [SettingsMap] arrival landed=section entry=apiKey.save at=aiPolish.providerSection",
        "[2026-10-09 01:00:01] [SettingsMap] arrival landed=target entry=apiKey.save at=apiKey.save upgrade=true",
        "[2026-10-09 01:00:02] [SettingsMap] arrival landed=target entry=other at=other",
    ]
    check("arrival lines are read per entry, in order, with the upgrade flag",
          arrival_lines(lines, "apiKey.save") == [("section", "aiPolish.providerSection", False),
                                                  ("target", "apiKey.save", True)])
    check("no line for another entry", arrival_lines(lines, "missing") == [])
    probe = PROBES[1]
    check("dead app fails", verdict(probe, False, [("target", "x", False)], "Dictation Settings", "Engine")[0] == "FAIL")
    check("no arrival fails", verdict(probe, True, [], "Dictation Settings", "Engine")[0] == "FAIL")
    check("wrong rung fails", verdict(probe, True, [("section", "x", False)], "Dictation Settings", "Engine")[0] == "FAIL")
    check("wrong page fails", verdict(probe, True, [("target", "x", False)], "Keybinds", None)[0] == "FAIL")
    check("wrong tab fails", verdict(probe, True, [("target", "x", False)], "Dictation Settings", "Clipboard")[0] == "FAIL")
    check("the right rung, page and tab pass",
          verdict(probe, True, [("target", "x", False)], "Dictation Settings", "Engine")[0] == "PASS")
    check("the last line decides (an upgrade to the row passes)",
          verdict(probe, True, [("section", "s", False), ("target", "x", True)], "Dictation Settings", "Engine")[0] == "PASS")
    check("seven probes with unique names", len(PROBES) == 7 and len({p["name"] for p in PROBES}) == 7)
    print("self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
