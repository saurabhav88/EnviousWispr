"""Containment pilot for the History speed subject (#4586 PR 0 chunk 2).

One short contained session of the renamed pinned Release subject on a fresh fixture home:
prepare the subject, regenerate the home, launch inside `fixture.ContainedSession` (read-only
production-preference compare, throwaway cleanup), wait for the History window and for full
catalog coverage, stop. Then list every entry under the real home's EnviousWispr-related folders
that changed during the session, so any write outside the fixture home is visible.

Coverage limit: the scan sees files, not who wrote them; another process writing the same folders
during the session would also appear. Preference-daemon writes appear as plist changes, which the
production compare already checks key by key.

The caller must hold the dev-app lock (claimed in a separate tool call).

Usage: python3 containment_pilot.py <pinned EnviousWispr.app> <expected sha256> <seed dir> <new run dir>
         [--calibrate] [--run <cases.json> <samples> [--capture-compare] [--busy]] [--scroll [scroll options...]]
         [--card [--repeats N]] [--open missing|existing <samples> [--busy] [--control drop-row]] [--scroll-early] [--hold]
  --open     after the contained session (which builds full coverage), run m5-speed-open.py on the same
             subject and home; it launches and stops the subject itself, once per sample
  --scroll-early  do not wait for catalog coverage (scroll while background indexing runs)
  --scroll   run m5-speed-scroll.py on the contained subject; every argument after it is passed through
  --hold     keep the subject running for hand probing until a file named `stop` appears in the run dir
"""
import json
import os
from pathlib import Path
import sqlite3
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture  # noqa: E402

WATCH_EXACT = ["Library/Application Support/EnviousWispr", fixture.API_KEY_FOLDER, fixture.RECOVERY_KEY_FOLDER,
               "Library/Containers/com.enviouswispr.app", "Library/Logs/EnviousWispr"]
WATCH_PREFIXED = ["Library/Preferences", "Library/HTTPStorages", "Library/Caches", "Library/Saved Application State",
                  "Library/WebKit"]


def watched(real_home):
    roots = [real_home / p for p in WATCH_EXACT]
    for folder in WATCH_PREFIXED:
        base = real_home / folder
        if base.is_dir():
            roots += [base / n for n in os.listdir(base) if "enviouswispr" in n.lower()]
    return roots


def snapshot(roots):
    state = {}
    for root in roots:
        if not root.exists():
            continue
        if root.is_file():
            st = root.stat()
            state[str(root)] = (st.st_mtime_ns, st.st_size)
            continue
        for directory, _, names in os.walk(root, followlinks=False):
            for name in names:
                path = Path(directory) / name
                try:
                    st = path.lstat()
                except OSError:
                    continue
                state[str(path)] = (st.st_mtime_ns, st.st_size)
    return state


def wait_for(predicate, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.25)  # deadline-fallback: poll interval inside a signal wait bounded by `timeout`
    raise RuntimeError(f"timed out waiting for {what}")


def coverage_ready(home):
    db = fixture.catalog_dir(home) / "history.sqlite"
    if not db.is_file():
        return False
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1) as con:
            # A coverage row exists from creation with a NULL revision; only a value is certified.
            return con.execute("select revision from coverage where revision is not null and revision != ''").fetchone() is not None
    except sqlite3.Error:
        return False


def window_listed(pid):
    sys.path.insert(0, str(HERE.parent))
    import ui_helpers as ui
    return bool(ui.get_attr(ui.get_ax_app(pid), "AXWindows"))


def main():
    if len(sys.argv) < 5 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    app, sha, seed, run = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
    calibrate = "--calibrate" in sys.argv[5:]
    run_cases = None
    if "--run" in sys.argv[5:]:
        at = sys.argv.index("--run")
        run_cases, run_samples = Path(sys.argv[at + 1]), sys.argv[at + 2]
    run.mkdir(parents=True, exist_ok=False)
    real_home = Path(fixture.pwd_home())
    subject = fixture.prepare_subject(app, run / "subject", sha)
    home = fixture.regenerate_home(seed, run / "home")
    roots = watched(real_home)
    before = snapshot(roots)
    started = time.time()
    report = {"subject": str(subject), "identity": fixture.subject_identity(subject), "home": str(home)}
    with fixture.ContainedSession(subject, home, run / "app.log", real_home=real_home) as session:
        report["pid"] = session.pid
        wait_for(lambda: window_listed(session.pid), 60, "the subject's window")
        report["window_after_s"] = round(time.time() - started, 2)
        # 2026-11-15 measured 264.7 s from launch to full coverage on the 27k seed (scrollfix-rel-1).
        if "--scroll-early" not in sys.argv[5:]:
            wait_for(lambda: coverage_ready(home), 900, "full catalog coverage")
        report["coverage_after_s"] = round(time.time() - started, 2)
        if calibrate:
            import subprocess
            report["calibration"] = {}
            plan = [(tab, None) for tab in ("Dictations", "Transcripts", "Meetings")]
            plan += [("Meetings", "Budget"), ("Dictations", "Fire onboarding"), ("Transcripts", "voice"),
                     ("Dictations", "zqxjvkwplm")]
            if "--only-empty" in sys.argv:
                plan = [("Dictations", "zqxjvkwplm")]
            for tab, query in plan:
                out = run / (f"calibrate-{tab}.json" if query is None else f"calibrate-{tab}-{query[:6]}.json")
                result = subprocess.run([sys.executable, "-B", str(HERE / "m5-speed-ui-search.py"), "calibrate",
                                         str(session.pid), str(subject), tab, str(out)] + ([query] if query else []),
                                        capture_output=True, text=True, timeout=180)
                report["calibration"][out.stem] = {"exit": result.returncode, "out": str(out),
                                              "stderr_tail": result.stderr[-400:]}
        if "--hold" in sys.argv[5:]:
            (run / "pid.txt").write_text(str(session.pid))
            print(json.dumps({"holding": session.pid, "subject": str(subject), "home": str(home)}), flush=True)
            wait_for(lambda: (run / "stop").exists(), 7200, "the stop file")
        if "--scroll" in sys.argv[5:]:
            import subprocess
            extra = sys.argv[sys.argv.index("--scroll") + 1:]
            result = subprocess.run([sys.executable, "-B", str(HERE / "m5-speed-scroll.py"), str(session.pid),
                                     str(subject), str(run / "scroll")] + extra,
                                    capture_output=True, text=True, timeout=7200)
            report["scroll_run"] = {"exit": result.returncode, "stdout_tail": result.stdout[-3000:],
                                    "stderr_tail": result.stderr[-1500:]}
        if "--card" in sys.argv[5:]:
            import subprocess
            extra = ["--repeats", sys.argv[sys.argv.index("--repeats") + 1]] if "--repeats" in sys.argv else []
            result = subprocess.run([sys.executable, "-B", str(HERE / "m5-speed-card.py"), str(session.pid),
                                     str(subject), str(run / "card")] + extra, capture_output=True, text=True, timeout=3600)
            report["card_run"] = {"exit": result.returncode, "stdout_tail": result.stdout[-3000:],
                                  "stderr_tail": result.stderr[-1500:]}
        if run_cases is not None:
            import subprocess
            result = subprocess.run([sys.executable, "-B", str(HERE / "m5-speed-ui-search.py"), "run",
                                     str(session.pid), str(subject), str(home), str(run_cases), str(run / "search"),
                                     run_samples] + (["--capture-compare"] if "--capture-compare" in sys.argv[5:] else [])
                                    + (["--busy"] if "--busy" in sys.argv[5:] else [])
                                    + (["--only", sys.argv[sys.argv.index("--only") + 1]] if "--only" in sys.argv else []),
                                    capture_output=True, text=True, timeout=7200)
            report["search_run"] = {"exit": result.returncode, "stdout_tail": result.stdout[-3000:],
                                    "stderr_tail": result.stderr[-1500:]}
    report["session"] = session.report
    db = fixture.catalog_dir(home) / "history.sqlite"
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as con:
        report["catalog_rows"] = dict(con.execute("select tab, count(*) from entries group by tab").fetchall())
    after = snapshot(watched(real_home))
    changed = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))
    report["real_home_changes"] = changed
    report["fixture_writes"] = sorted(str(p.relative_to(home)) for p in home.rglob("*")
                                      if p.is_file() and p.stat().st_mtime >= started)[:200]
    if "--open" in sys.argv[5:]:
        import subprocess
        at = sys.argv.index("--open")
        extra = [a for a in ("--busy",) if a in sys.argv[5:]]
        if "--control" in sys.argv:
            extra += ["--control", sys.argv[sys.argv.index("--control") + 1]]
        result = subprocess.run([sys.executable, "-B", str(HERE / "m5-speed-open.py"), str(subject), str(home),
                                 str(run / "open"), "--mode", sys.argv[at + 1], "--samples", sys.argv[at + 2]] + extra,
                                capture_output=True, text=True, timeout=7200)
        report["open_run"] = {"exit": result.returncode, "stdout_tail": result.stdout[-3000:],
                              "stderr_tail": result.stderr[-1500:]}
    (run / "pilot.json").write_text(json.dumps(report, indent=1))
    print(json.dumps({k: v for k, v in report.items() if k != "fixture_writes"}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
