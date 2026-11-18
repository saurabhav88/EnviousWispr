"""One markdown table of a run_baseline.sh folder (#4586 WP-A). Reads only the drivers' reports.

Usage: python3 summarize_baseline.py <baseline out dir>
"""
import json
from pathlib import Path
import sys


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def fmt(value, unit="ms"):
    return "n/a" if value is None else f"{value:.0f} {unit}" if isinstance(value, (int, float)) else str(value)


def conditions(report):
    if not report:
        return "n/a"
    parts = []
    for key in ("conditions_start", "conditions_end"):
        c = report.get(key) or {}
        if c:
            parts.append(f"load {c.get('load1')}, builds {c.get('processes')}, quiet {c.get('quiet')}")
    return " → ".join(parts) or "n/a"


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    lines = [f"# History speed baseline: {root.name}", "",
             "| Case | Number | n | Budget | Verdict | Machine (start → end) |", "|---|---|---|---|---|---|"]
    pilot = load(root / "main" / "pilot.json") or {}
    for mode in ("missing", "existing"):
        r = load(root / "main" / f"open-{mode}" / "report.json")
        if r and (r.get("storage_warning") or r.get("watch_banner") or r.get("diagnostic")):
            r = None   # a banner check (either mode) is not a timing run; never summarised as one
        if r:
            p = r["launch_to_page_ms"]
            w = r["window_to_page_ms"]
            lines.append(f"| Open History, {mode} catalog: launch → complete first page | all-attempt p95 "
                         f"{fmt(r.get('launch_to_page_all_attempts_p95_ms'))} over {r.get('attempts')} attempts; "
                         f"timed-only p50 {fmt(p.get('p50'))}, p95 {fmt(p.get('p95'))} (window → page p95 {fmt(w.get('p95'))}; results {r['results']}, "
                         f"capture late {r['capture_late']}) | {r.get('attempts', p.get('n', 0))} | 300 ms p95 | {r['budget_verdict']} | "
                         f"{conditions(r)} |")
    s = load(root / "main" / "search" / "report.json")
    if s:
        o = s.get("overall", {})
        lines.append(f"| Search: keystroke → correct complete page (all timed steps) | p95 {fmt(o.get('timed_p95_ms'))} | "
                     f"{o.get('timed_n')} | 50 ms p95 | {o.get('budget_verdict')} | {conditions(s)} |")
        for name, series in s.get("series", {}).items():
            summary = series.get("summary", {})
            upper = summary.get("upper_ms", {})
            lines.append(f"| · search {name} | p50 {fmt(upper.get('p50'))}, p95 {fmt(upper.get('p95'))}; "
                         f"steps {summary.get('results', summary.get('error', ''))} | {upper.get('n', 0)} | 50 ms p95 | "
                         f"{summary.get('budget_verdict', 'UNPROVEN')} | |")
        res = s.get("resources_search_run") or {}
        lines.append(f"| Resources while searching | CPU {fmt(res.get('cpu_s'), 's')}, peak {fmt(res.get('peak_rss_mb'), 'MB')} | | none | | |")
    for folder in ("main", "indexing"):
        sc = load(root / folder / "scroll" / "report.json")
        if not sc:
            continue
        if sc.get("resources_idle"):
            idle = sc["resources_idle"]
            lines.append(f"| Resources idle on History ({idle.get('seconds')} s) | CPU {fmt(idle.get('cpu_s'), 's')}, "
                         f"peak {fmt(idle.get('peak_rss_mb'), 'MB')} | | none | | {conditions(sc)} |")
        groups = {}
        for run in sc.get("runs", []):
            groups.setdefault((run.get("case", "mid"), run["tab"], run["input"]), []).append(run)
        for (case, tab, kind), runs in groups.items():
            asym = [r["travel"]["asymmetry"] for r in runs if r.get("travel", {}).get("asymmetry") is not None]
            changed = sum(len(r.get("height_changed", [])) for r in runs)
            traced = [r["hitch"].get("ms_per_s") for r in runs if not r.get("hitch", {}).get("not_traced")]
            label = "while indexing" if folder == "indexing" else case
            lines.append(f"| **Scroll {tab} {kind} ({label}), all repeats** | hitch {traced} ms/s (traced repeats); "
                         f"worst asymmetry {max(asym) if asym else 'n/a'}; height changes {changed} | "
                         f"{len(runs)} down+up pairs ({len(traced)} traced) | 5 ms/s, 0, 2% | "
                         f"{'PASS' if all(r.get('verdict') == 'PASS' for r in runs) else 'FAIL' if any(r.get('verdict') == 'FAIL' for r in runs) else 'UNPROVEN'} | |")
        for run in sc.get("runs", []):
            h = run.get("hitch", {})
            t = run.get("travel", {})
            label = "while indexing" if folder == "indexing" else run.get("case", "mid")
            res = run.get("resources_hitch_pass", {})
            lines.append(f"| Scroll {run['tab']} {run['input']} ({label}) | hitch {fmt(h.get('ms_per_s'), 'ms/s')} over "
                         f"{fmt(h.get('moving_s'), 's')} moving{' (' + h['unproven'] + ')' if h.get('unproven') else ''}; "
                         f"height changes {len(run.get('height_changed', []))} of {run.get('rows_seen')} rows; "
                         f"travel down {t.get('down')} / up {t.get('up')} pt, asymmetry {t.get('asymmetry')}; "
                         f"kept moving {run.get('kept_moving_s')}; CPU {fmt(res.get('cpu_s'), 's')}, "
                         f"peak {fmt(res.get('peak_rss_mb'), 'MB')} | 2 gestures | "
                         f"{'0, 2% (hitch not traced in this repeat)' if h.get('not_traced') else '5 ms/s, 0, 2%'} | "
                         f"{run.get('verdict')} | |")
    c = load(root / "main" / "card" / "report.json")
    if c:
        for key, title in (("edits", "Show edits"), ("play", "Play")):
            first = c.get(f"{key}_first_change_ms", {})
            extra = ""
            if key == "edits":
                settled = c.get("edits_settled_ms", {})
                extra = f"; finished drawing p50 {fmt(settled.get('p50'))}, p95 {fmt(settled.get('p95'))}"
            lines.append(f"| {title}: press → first visible response | p50 {fmt(first.get('p50'))}, "
                         f"p95 {fmt(first.get('p95'))}{extra} | {first.get('n', 0)} | none | | {conditions(c)} |")
    lines.append("| Page queries during indexing | NOT MEASURED on current main (needs package C's `HistoryPage` signpost) | | < 15 ms | | |")
    lines += ["", f"Isolation: production preferences changed {pilot.get('session', {}).get('production_changed_keys')}; "
                  f"throwaway removed {pilot.get('session', {}).get('removed')}; catalog rows {pilot.get('catalog_rows')}; "
                  f"coverage after {pilot.get('coverage_after_s')} s."]
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
