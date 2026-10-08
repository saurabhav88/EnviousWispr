#!/usr/bin/env python3
"""Record CI test failures as one GitHub issue per test (#3524 PR 4).

Runs from the trusted recorder workflow (default-branch code, `contents: read`,
`actions: read`, `issues: write`, one concurrency group). It reads the
`test-identities-<job>-<run>-<attempt>` artifacts that scripts/ci/test-identities.py wrote
on the macOS test jobs, checks each with that file's validate_document(), and records
through scripts/ci/issue_upsert.py (label `ci-test-failure`, one issue per test key, each
event once).

What it records, and how it words it:
- Main Post-Merge Check on main (push, schedule or dispatch): every test FAILED in a failed
  release-validation or debug-validation attempt: "failed on main; cause not established".
- PR Check from this repository: a test FAILED in a failed build-and-test attempt k and
  explicitly PASSED in the next successful attempt m of the same run, whose lane outcome is
  success and whose tested sha equals attempt k's: "failed, then passed on re-run of the same
  SHA". The event is named by attempt k. A missing or skipped identity establishes nothing.
- A PR failure never re-run, a fork's PR and any other workflow are not recorded. Repetition
  alone never says "random"; only a re-run pass does.
- Escalation: an issue with events on two distinct main SHAs, or three events in all, gets
  P1-high and loses its other P label (P0-critical is kept).

Evidence gaps (an artifact missing, expired or invalid for an attempt that matters, or a
failed job with no failed test) are reported and, in reconcile mode, listed on the ledger
issue. An API failure prints "could not record", leaves the checkpoint where it was, and the
next reconcile replays; replays add nothing already recorded.

Usage:
  record-test-failures.py run --repo <o/r> --run-id <id> [--dry-run]
  record-test-failures.py reconcile --repo <o/r> [--now <ISO>] [--dry-run]
  record-test-failures.py canary --repo <o/r> --run-id <id>
  record-test-failures.py --self-test
Exit 0 whenever the arguments were valid, including "could not record"; 2 on bad arguments.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


upsert = _load("issue_upsert", "issue_upsert.py")
identities = _load("test_identities", "test-identities.py")
ApiError = upsert.ApiError

LABEL = "ci-test-failure"
LABELS = [LABEL, "bug", "P3-low", "area:dev-infra"]
PRIORITIES = ("P0-critical", "P1-high", "P2-medium", "P3-low", "P4-backlog")
MAIN, PR = ".github/workflows/main-post-merge.yml", ".github/workflows/pr-check.yml"
JOBS = {MAIN: ("release-validation", "debug-validation"), PR: ("build-and-test",)}
MAIN_EVENTS = ("push", "schedule", "workflow_dispatch")
LEDGER_MARKER = "<!-- ci-test-failure-ledger -->"
CHECKPOINT = re.compile(r"<!-- ci-reconcile-checkpoint: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) -->")
KIND = re.compile(r"<!-- ci-event-kind: (main|rerun) ([0-9a-f]{40}) -->")
MAX_ZIP_BYTES = 64 * 1024 * 1024
DEFAULT_WINDOW = dt.timedelta(days=3)
OVERLAP = dt.timedelta(days=1)
# GitHub lets a run be re-run for 30 days; reconcile lists runs CREATED that far back (plus a
# margin) and reads only those UPDATED since its window start, so a late re-run is found even
# when its workflow_run callback was lost.
RERUN_HORIZON = dt.timedelta(days=31)
CONCLUSIONS = ("success", "failure", "cancelled", "skipped", "neutral", "timed_out", "action_required", "stale",
               "startup_failure")
FAILED_CONCLUSIONS = ("failure", "timed_out")


def artifact_name(job, run, attempt):
    return f"test-identities-{job}-{run}-{attempt}"


class Actions:
    """Workflow runs, attempts, jobs and artifacts of one repository, through `gh api`."""

    def __init__(self, repo, runner=subprocess.run):
        self.repo, self.runner = repo, runner

    def _raw(self, *args):
        try:
            proc = self.runner(["gh", "api", *args], capture_output=True)
        except OSError as error:
            raise ApiError(f"could not launch gh: {error}") from error
        if proc.returncode != 0:
            err = proc.stderr.decode(errors="replace") if isinstance(proc.stderr, bytes) else (proc.stderr or "")
            raise ApiError(f"gh api {args[-1][:80]} exited {proc.returncode}: {err.strip()[:300]}")
        return proc.stdout if isinstance(proc.stdout, bytes) else (proc.stdout or "").encode()

    def _json(self, *args):
        try:
            return json.loads(self._raw(*args))
        except ValueError as error:
            raise ApiError(f"gh api {args[-1][:80]} printed malformed JSON: {error}") from error

    def _listed(self, path, field):
        pages = self._json("--paginate", "--slurp", path)
        if not isinstance(pages, list) or not all(isinstance(p, dict) and isinstance(p.get(field), list) for p in pages):
            raise ApiError(f"{path}: expected pages carrying {field!r}")
        rows = [row for page in pages for row in page[field]]
        if not all(isinstance(row, dict) for row in rows):
            raise ApiError(f"{path}: a {field} row is not an object")
        return rows

    def run(self, run_id):
        info = self._json(f"repos/{self.repo}/actions/runs/{run_id}")
        head = info.get("head_repository") if isinstance(info, dict) else None
        if not isinstance(info, dict) or type(info.get("id")) is not int or info["id"] != run_id or run_id < 1 \
                or type(info.get("run_attempt")) is not int or not 1 <= info["run_attempt"] <= 100 \
                or not isinstance(info.get("path"), str) or not isinstance(head, dict):
            raise ApiError(f"run {run_id}: unexpected run record")
        return info

    def runs(self, workflow_file, since):
        rows = self._listed(f"repos/{self.repo}/actions/workflows/{workflow_file}/runs?status=completed"
                            f"&created=%3E%3D{since}&per_page=100", "workflow_runs")
        for row in rows:
            if type(row.get("id")) is not int or row["id"] < 1 or type(row.get("run_attempt")) is not int \
                    or row["run_attempt"] < 1 or not isinstance(row.get("updated_at"), str) \
                    or not isinstance(row.get("conclusion"), (str, type(None))):
                raise ApiError(f"{workflow_file}: a malformed run row")
        return rows

    def job_conclusion(self, run_id, attempt, job):
        """The conclusion of job in that attempt, or None when the job did not run in it."""
        rows = self._listed(f"repos/{self.repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", "jobs")
        for row in rows:
            if not isinstance(row.get("name"), str) or not row["name"] or row.get("status") != "completed" \
                    or row.get("conclusion") not in CONCLUSIONS:
                raise ApiError(f"run {run_id} attempt {attempt}: a malformed or unfinished job row")
        rows = [row for row in rows if row["name"] == job]
        if len(rows) > 1:
            raise ApiError(f"run {run_id} attempt {attempt}: {len(rows)} jobs named {job}")
        return rows[0].get("conclusion") if rows else None

    def artifacts(self, run_id):
        rows = self._listed(f"repos/{self.repo}/actions/runs/{run_id}/artifacts?per_page=100", "artifacts")
        for row in rows:
            if not isinstance(row.get("name"), str) or type(row.get("id")) is not int or row["id"] < 1 \
                    or type(row.get("expired")) is not bool or type(row.get("size_in_bytes")) is not int \
                    or row["size_in_bytes"] < 0:
                raise ApiError(f"run {run_id}: a malformed artifact row")
        return rows

    def download(self, artifact_id):
        return self._raw(f"repos/{self.repo}/actions/artifacts/{artifact_id}/zip")


class Gap(Exception):
    """This attempt's test identities are not available as evidence."""


def load_document(actions, listing, job, run_id, attempt):
    name = artifact_name(job, run_id, attempt)
    found = [a for a in listing if a.get("name") == name]
    if not found:
        raise Gap(f"{name}: no such artifact")
    if len(found) > 1:
        raise Gap(f"{name}: {len(found)} artifacts with this name")
    art = found[0]
    if art.get("expired"):
        raise Gap(f"{name}: expired")
    if type(art.get("id")) is not int or type(art.get("size_in_bytes")) is not int or art["size_in_bytes"] > MAX_ZIP_BYTES:
        raise Gap(f"{name}: bad id or size")
    blob = actions.download(art["id"])
    try:
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            members = archive.infolist()
            if len(members) != 1 or members[0].filename != "test-identities.json" \
                    or members[0].file_size > MAX_ZIP_BYTES:
                raise Gap(f"{name}: expected exactly test-identities.json")
            doc = json.loads(archive.read(members[0]))
    except (zipfile.BadZipFile, ValueError, KeyError, RuntimeError, NotImplementedError, zlib.error, EOFError,
            OSError) as error:
        raise Gap(f"{name}: unreadable ({error})") from error
    try:
        doc = identities.validate_document(doc, job, run_id, attempt)
    except ValueError as error:
        raise Gap(str(error)) from error
    if doc["evidence"] == "gap":
        raise Gap(f"{name}: the job recorded a gap: {doc['gap']}")
    return doc


def _event_text(kind, doc, item, run_url, detail):
    # Artifact text is escaped, so test output can never read as a recorder marker; only the
    # markers this file writes stay unescaped.
    def shown(text):
        return html.escape(text.replace("\n", " "), quote=True)
    lines = [detail, "", f"- Test: `{shown(item['key'])}`", f"- Tested SHA: `{doc['sha']}`", f"- Run: {run_url}"]
    for message in item["failures"]:
        lines.append(f"- Failure: {shown(message)}")
    for argument in item["failed_arguments"]:
        lines.append(f"- Failing argument: {shown(argument)}")
    lines.append(f"<!-- ci-event-kind: {kind} {doc['sha']} -->")
    return "\n".join(lines)


def _title(item):
    where = item["suite"] or item["target"] or "test"
    return f"CI test failure: {where} / {item['name'] or item['node_identifier']}"[:200]


def can_hold_failure(path, run_attempt, conclusion):
    """False for a run that cannot hold a recordable failure: a main run that passed on its first
    attempt has no failed attempt, and a PR run never re-run records nothing."""
    return run_attempt != 1 or (path == MAIN and conclusion != "success")


def plan_run(actions, repo, run_id, server="https://github.com"):
    """(events, gaps, skipped_reason) for one run. Each event is a dict for record_event()."""
    info = actions.run(run_id)
    path, event = info["path"], info.get("event")
    if info["head_repository"].get("full_name") != repo:
        return [], [], "a fork or another repository"
    if path == MAIN and event in MAIN_EVENTS and info.get("head_branch") == "main":
        mode = "main"
    elif path == PR and event == "pull_request":
        mode = "rerun"
    else:
        return [], [], f"not a recorded workflow or event ({path}, {event})"
    if not can_hold_failure(path, info["run_attempt"], info.get("conclusion")):
        return [], [], None
    run_url = f"{server}/{repo}/actions/runs/{run_id}"
    listing = None
    events, gaps = [], []
    cache = {}

    def doc_for(job, attempt):
        nonlocal listing
        if (job, attempt) not in cache:
            if listing is None:
                listing = actions.artifacts(run_id)
            try:
                cache[(job, attempt)] = load_document(actions, listing, job, run_id, attempt)
            except Gap as gap:
                cache[(job, attempt)] = gap
        return cache[(job, attempt)]

    for job in JOBS[path]:
        conclusions = {k: actions.job_conclusion(run_id, k, job) for k in range(1, info["run_attempt"] + 1)}
        for k, conclusion in conclusions.items():
            if conclusion not in FAILED_CONCLUSIONS:
                continue
            later = [m for m in conclusions if m > k and conclusions[m] == "success"]
            if mode == "rerun" and not later:
                continue  # a PR failure never re-run to a pass records nothing and reads nothing
            failed_doc = doc_for(job, k)
            if isinstance(failed_doc, Gap):
                gaps.append(f"{job} attempt {k}: {failed_doc}")
                continue
            failed = [i for i in failed_doc["identities"] if i["result"] == "FAILED"]
            if not failed:
                gaps.append(f"{job} attempt {k}: the job failed but no test failed (a build or harness failure)")
                continue
            if mode == "main":
                for item in failed:
                    events.append({"key": item["key"], "event": f"{run_id}/{k}/{job}/{item['key']}", "title": _title(item),
                                   "text": _event_text("main", failed_doc, item, run_url,
                                                       f"Failed on main in Main Post-Merge Check, job {job}, attempt {k}. "
                                                       "Cause not established.")})
                continue
            m = later[0]
            passed_doc = doc_for(job, m)
            if isinstance(passed_doc, Gap):
                gaps.append(f"{job} attempt {m}: {passed_doc}")
                continue
            if passed_doc["lane_outcome"] != "success" or passed_doc["sha"] != failed_doc["sha"]:
                gaps.append(f"{job} attempts {k}->{m}: not a same-SHA passing re-run")
                continue
            passed = {i["key"] for i in passed_doc["identities"] if i["result"] == "PASSED"}
            for item in failed:
                if item["key"] in passed:
                    events.append({"key": item["key"], "event": f"{run_id}/{k}/{job}/{item['key']}", "title": _title(item),
                                   "text": _event_text("rerun", failed_doc, item, run_url,
                                                       f"Failed in PR Check job {job} attempt {k}, then passed on re-run of "
                                                       f"the same SHA (attempt {m}).")})
    return events, gaps, None


def escalate(store, number):
    """P1-high when the issue's events span two main SHAs or number three; returns True if changed."""
    rows = [row for row in store.issues(LABEL) if row["number"] == number]
    if len(rows) != 1:
        raise ApiError(f"issue #{number} not found for escalation")
    texts = [rows[0]["body"] or "", *store.comments(number)]
    kinds = [m for text in texts for m in KIND.findall(text)]
    main_shas = {sha for kind, sha in kinds if kind == "main"}
    if len(kinds) < 3 and len(main_shas) < 2:
        return False
    names = [label.get("name") for label in rows[0].get("labels") or [] if isinstance(label, dict)]
    if "P0-critical" in names or ("P1-high" in names and not set(names) & (set(PRIORITIES) - {"P1-high"})):
        return False
    store.update(number, labels=[n for n in names if n not in PRIORITIES] + ["P1-high"])
    return True


def record_events(store, events):
    """Record each event; returns outcome counts. ApiError propagates (nothing half-recorded)."""
    tally = {}
    for item in events:
        outcome, number = upsert.upsert_event(store, LABEL, item["key"], item["event"], item["title"],
                                              item["text"], LABELS)
        tally[outcome] = tally.get(outcome, 0) + 1
        # Also on a duplicate: a replay repairs an escalation whose label write failed.
        if escalate(store, number):
            tally["escalated"] = tally.get("escalated", 0) + 1
    return tally


def ledger(store, dry_run):
    rows = [row for row in store.issues(LABEL) if LEDGER_MARKER in (row["body"] or "")]
    if rows:
        return min(row["number"] for row in rows)
    if dry_run:
        return None
    return store.create("CI test-failure recorder: ledger",
                        f"{LEDGER_MARKER}\nCheckpoints and evidence gaps of the daily reconcile "
                        "(scripts/ci/record-test-failures.py). Keep this issue open.", [LABEL, "task", "P4-backlog",
                                                                                       "area:dev-infra"])


def last_checkpoint(store, number):
    if number is None:
        return None
    stamps = [m for text in store.comments(number) for m in CHECKPOINT.findall(text)]
    return max(stamps) if stamps else None


def _iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def reconcile(actions, store, repo, now, dry_run=False, out=print):
    number = ledger(store, dry_run)
    previous = last_checkpoint(store, number)
    start = (dt.datetime.strptime(previous, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc) - OVERLAP
             if previous else now - DEFAULT_WINDOW)
    since = _iso(start)
    # Listed by creation over the whole re-run horizon; read only when updated since the window
    # start and able to hold a recordable failure (a main run that passed on its first attempt
    # has no failed attempt, and a PR run never re-run records nothing).
    created = _iso(min(start, now - RERUN_HORIZON))
    run_ids = sorted({row["id"] for workflow in (MAIN, PR) for row in actions.runs(os.path.basename(workflow), created)
                      if row["updated_at"] >= since and can_hold_failure(workflow, row["run_attempt"], row["conclusion"])})
    gaps, tally = [], {}
    for run_id in run_ids:
        events, run_gaps, _ = plan_run(actions, repo, run_id)
        gaps += [f"run {run_id}: {g}" for g in run_gaps]
        if dry_run:
            for e in events:
                out(f"would record {e['event']}")
            continue
        for k, v in record_events(store, events).items():
            tally[k] = tally.get(k, 0) + v
    note = "\n".join([f"<!-- ci-reconcile-checkpoint: {_iso(now)} -->",
                      f"Reconciled {len(run_ids)} run(s) updated since {since}: "
                      + (", ".join(f"{k} {v}" for k, v in sorted(tally.items())) or "nothing new") + ".",
                      *([f"Evidence gaps ({len(gaps)}):"] + [f"- {g}" for g in gaps[:100]] if gaps else ["No evidence gaps."])])
    if not dry_run:
        store.comment(number, note)
    return len(run_ids), tally, gaps


CANARY_KEY = "test://com.apple.xcode/EnviousWispr/RecorderCanary/recorderCanary()"


def canary(store, run_id):
    """One fixture event through the real issue path, then the fixture issue is closed."""
    outcome, number = upsert.upsert_event(
        store, LABEL, CANARY_KEY, f"canary/{run_id}", "CI test-failure recorder: canary (fixture, not a test failure)",
        f"Canary from recorder run {run_id}: the recorder can create, comment and close issues. Not a test failure.",
        [LABEL, "task", "P4-backlog", "area:dev-infra"])
    store.update(number, state="closed")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("run")
    p.add_argument("--repo", required=True)
    p.add_argument("--run-id", type=int, required=True)
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("canary", help="record one fixture event, then close its issue (live wiring proof)")
    p.add_argument("--repo", required=True)
    p.add_argument("--run-id", type=int, required=True)
    p = sub.add_parser("reconcile")
    p.add_argument("--repo", required=True)
    p.add_argument("--now")
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.command or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.print_usage(sys.stderr)
        return 2
    actions, store = Actions(args.repo), upsert.Store(args.repo)
    try:
        if args.command == "canary":
            number = canary(store, args.run_id)
            print(f"record-test-failures: canary recorded on #{number} and closed it")
        elif args.command == "run":
            events, gaps, skipped = plan_run(actions, args.repo, args.run_id)
            if skipped:
                print(f"record-test-failures: run {args.run_id} not recorded: {skipped}")
                return 0
            for gap in gaps:
                print(f"::warning::evidence gap: run {args.run_id}: {gap}")
            if args.dry_run:
                for e in events:
                    print(f"would record {e['event']}")
                return 0
            print(f"record-test-failures: run {args.run_id}: {record_events(store, events) or 'nothing to record'}")
        else:
            now = (dt.datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
                   if args.now else dt.datetime.now(dt.timezone.utc).replace(microsecond=0))
            count, tally, gaps = reconcile(actions, store, args.repo, now, args.dry_run)
            print(f"record-test-failures: reconciled {count} run(s): {tally or 'nothing new'}; {len(gaps)} evidence gap(s)")
    except ApiError as error:
        print(f"::warning::could not record: {error}")
    return 0


# --- self-test ------------------------------------------------------------------------------

class FakeActions:
    """The Actions API calls this file makes, over a FakeGitHub for issues (tests only)."""

    def __init__(self, repo="o/r"):
        self.repo, self.issues = repo, upsert.FakeGitHub(page_size=2)
        self.runs, self.jobs, self.artifacts, self.blobs, self.fail, self.calls = {}, {}, {}, {}, {}, []

    def add_run(self, run_id, path, event="push", branch="main", attempts=1, head_repo=None, created="2026-10-08T10:00:00Z",
                conclusion="failure", updated=None):
        self.runs[run_id] = {"id": run_id, "path": path, "event": event, "head_branch": branch, "run_attempt": attempts,
                             "head_repository": {"full_name": head_repo or self.repo}, "created_at": created,
                             "conclusion": conclusion, "updated_at": updated or created}

    def set_job(self, run_id, attempt, job, conclusion):
        self.jobs.setdefault((run_id, attempt), []).append({"name": job, "status": "completed", "conclusion": conclusion})

    def add_doc(self, job, run_id, attempt, doc, expired=False, raw=None):
        art_id = 1000 + len(self.blobs)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as archive:
            archive.writestr("test-identities.json", raw if raw is not None else json.dumps(doc))
        self.blobs[art_id] = buf.getvalue()
        self.artifacts.setdefault(run_id, []).append({"id": art_id, "name": artifact_name(job, run_id, attempt),
                                                      "expired": expired, "size_in_bytes": len(self.blobs[art_id])})

    def __call__(self, argv, input=None, **kw):
        path = next((a for a in argv if a.startswith("repos/")), "")
        if "/actions/" not in path:
            return self.issues(argv, input=input, **kw)
        self.calls.append(path)

        class Proc:
            def __init__(self, rc, out, err=b""):
                self.returncode, self.stdout, self.stderr = rc, out, err
        for needle, (rc, err) in list(self.fail.items()):
            if needle in path:
                del self.fail[needle]
                return Proc(rc, b"", err.encode())
        parts = path.split("?")[0].split("/")[3:]
        if parts[:2] == ["actions", "runs"] and len(parts) == 3:
            return Proc(0, json.dumps(self.runs[int(parts[2])]).encode())
        if parts[:2] == ["actions", "runs"] and parts[3:4] == ["attempts"]:
            rows = self.jobs.get((int(parts[2]), int(parts[4])), [])
            return Proc(0, json.dumps([{"jobs": rows[:1]}, {"jobs": rows[1:]}]).encode())
        if parts[:2] == ["actions", "runs"] and parts[3:4] == ["artifacts"]:
            return Proc(0, json.dumps([{"artifacts": self.artifacts.get(int(parts[2]), [])}]).encode())
        if parts[:2] == ["actions", "artifacts"]:
            return Proc(0, self.blobs[int(parts[2])])
        if parts[:2] == ["actions", "workflows"]:
            query = path.split("?", 1)[1]
            since = re.search(r"created=%3E%3D([^&]+)", query).group(1)
            rows = [r for r in self.runs.values() if r["path"].endswith(parts[2]) and r["created_at"] >= since]
            return Proc(0, json.dumps([{"workflow_runs": rows}]).encode())
        raise AssertionError(f"unexpected call {path}")


def _doc(job, run_id, attempt, sha, outcome, results):
    items = [{"key": f"test://com.apple.xcode/EnviousWispr/EnviousWisprTests/S/{name}()", "target": "EnviousWisprTests",
              "suite": "S", "name": f"{name}()", "node_identifier": f"S/{name}()", "result": result,
              "failures": ["Expectation failed"] if result == "FAILED" else [], "failed_arguments": []}
             for name, result in results.items()]
    counts = {}
    for item in items:
        counts[item["result"]] = counts.get(item["result"], 0) + 1
    return {"schema": 1, "job": job, "run": run_id, "attempt": attempt, "sha": sha, "lane_outcome": outcome,
            "xcode_build": "27A266a", "evidence": "complete", "gap": None, "counts": counts, "identities": items}


def self_test():
    failures, cases = [], 0
    A, B = "a" * 40, "b" * 40
    key = lambda name: f"test://com.apple.xcode/EnviousWispr/EnviousWisprTests/S/{name}()"

    def expect(name, got, want):
        nonlocal cases
        cases += 1
        ok = got == want
        print(f"{'ok  ' if ok else 'FAIL'} [{name}]" + ("" if ok else f" expected {want!r}, got {got!r}"))
        if not ok:
            failures.append(name)

    def issue_for(fake, name):
        rows = [i for i in fake.issues.issues.values() if upsert.key_marker(key(name)) in i["body"]]
        return rows[0] if len(rows) == 1 else None

    def events_of(fake, issue):
        texts = [issue["body"], *fake.issues.comments[issue["number"]]]
        return [m for t in texts for m in re.findall(r"<!-- ci-event: ([^ ]+) -->", t)]

    def run(fake, run_id):
        actions, store = Actions("o/r", runner=fake), upsert.Store("o/r", runner=fake)
        events, gaps, skipped = plan_run(actions, "o/r", run_id)
        return record_events(store, events), gaps, skipped

    # Main: one failing attempt.
    fake = FakeActions()
    fake.add_run(10, MAIN)
    fake.set_job(10, 1, "release-validation", "failure")
    fake.set_job(10, 1, "debug-validation", "success")
    fake.add_doc("release-validation", 10, 1, _doc("release-validation", 10, 1, A, "failure", {"x": "FAILED", "y": "PASSED"}))
    tally, gaps, _ = run(fake, 10)
    issue = issue_for(fake, "x")
    expect("1 a main failure: one issue for the failed test only, worded as cause not established",
           (tally, gaps, issue is not None and "Cause not established" in issue["body"], issue_for(fake, "y")),
           ({"created": 1}, [], True, None))
    expect("2 the issue has the label set and the event marker",
           ([l["name"] for l in issue["labels"]], events_of(fake, issue)),
           (LABELS, [f"10/1/release-validation/{key('x')}"]))
    tally, _, _ = run(fake, 10)
    expect("3 replaying the same run records nothing", (tally, len(fake.issues.comments[issue["number"]])), ({"duplicate": 1}, 0))

    # Main again on another SHA: escalation on two distinct main SHAs.
    fake.add_run(11, MAIN, attempts=1)
    fake.set_job(11, 1, "debug-validation", "failure")
    fake.add_doc("debug-validation", 11, 1, _doc("debug-validation", 11, 1, B, "failure", {"x": "FAILED"}))
    tally, _, _ = run(fake, 11)
    names = [l["name"] for l in issue_for(fake, "x")["labels"]]
    expect("4 a second main SHA: commented and escalated to P1-high, P3 removed",
           (tally, "P1-high" in names, "P3-low" in names), ({"commented": 1, "escalated": 1}, True, False))

    # Two failures on ONE main sha, plus a third event: escalation by count.
    fake = FakeActions()
    fake.add_run(20, MAIN, attempts=2)
    for k in (1, 2):
        fake.set_job(20, k, "release-validation", "failure")
        fake.add_doc("release-validation", 20, k, _doc("release-validation", 20, k, A, "failure", {"z": "FAILED"}))
    run(fake, 20)
    names = [l["name"] for l in issue_for(fake, "z")["labels"]]
    expect("5 two events on one SHA: not escalated", ("P1-high" in names, len(events_of(fake, issue_for(fake, "z")))),
           (False, 2))
    fake.add_run(21, MAIN)
    fake.set_job(21, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 21, 1, _doc("release-validation", 21, 1, A, "failure", {"z": "FAILED"}))
    run(fake, 21)
    expect("6 a third event: escalated", "P1-high" in [l["name"] for l in issue_for(fake, "z")["labels"]], True)

    # PR re-run recovery.
    fake = FakeActions()
    fake.add_run(30, PR, event="pull_request", branch="feat/x", attempts=2)
    fake.set_job(30, 1, "build-and-test", "failure")
    fake.set_job(30, 2, "build-and-test", "success")
    fake.add_doc("build-and-test", 30, 1, _doc("build-and-test", 30, 1, A, "failure", {"f": "FAILED", "g": "FAILED", "h": "FAILED"}))
    fake.add_doc("build-and-test", 30, 2, _doc("build-and-test", 30, 2, A, "success", {"f": "PASSED", "g": "SKIPPED"}))
    tally, gaps, _ = run(fake, 30)
    issue = issue_for(fake, "f")
    expect("7 a PR re-run pass: only the explicitly PASSED test, named by the failing attempt",
           (tally, issue is not None and "passed on re-run of the same SHA" in issue["body"], events_of(fake, issue) if issue else None,
            issue_for(fake, "g"), issue_for(fake, "h")),
           ({"created": 1}, True, [f"30/1/build-and-test/{key('f')}"], None, None))
    expect("7b a re-run event is marked as such, not as a main failure",
           KIND.findall(issue["body"]) if issue else None, [("rerun", A)])
    fake.add_run(36, PR, event="pull_request", branch="feat/x", attempts=2)
    fake.set_job(36, 1, "build-and-test", "failure")
    fake.set_job(36, 2, "build-and-test", "success")
    fake.add_doc("build-and-test", 36, 1, _doc("build-and-test", 36, 1, B, "failure", {"f": "FAILED"}))
    fake.add_doc("build-and-test", 36, 2, _doc("build-and-test", 36, 2, B, "success", {"f": "PASSED"}))
    run(fake, 36)
    expect("7c two re-run events on two SHAs do not count as two main SHAs (no escalation yet)",
           "P1-high" in [l["name"] for l in issue_for(fake, "f")["labels"]], False)

    for name, mutate, want_gap in [
        ("8 a different tested SHA on the passing attempt", lambda d: d.update(sha=B), "not a same-SHA passing re-run"),
        ("9 a passing attempt whose lane outcome is not success", lambda d: d.update(lane_outcome="failure"),
         "not a same-SHA passing re-run"),
    ]:
        fake = FakeActions()
        fake.add_run(31, PR, event="pull_request", branch="feat/x", attempts=2)
        fake.set_job(31, 1, "build-and-test", "failure")
        fake.set_job(31, 2, "build-and-test", "success")
        fake.add_doc("build-and-test", 31, 1, _doc("build-and-test", 31, 1, A, "failure", {"f": "FAILED"}))
        passed = _doc("build-and-test", 31, 2, A, "success", {"f": "PASSED"})
        mutate(passed)
        fake.add_doc("build-and-test", 31, 2, passed)
        tally, gaps, _ = run(fake, 31)
        expect(f"{name}: nothing recorded, a gap reported", (tally, any(want_gap in g for g in gaps)), ({}, True))

    fake = FakeActions()
    fake.add_run(32, PR, event="pull_request", branch="feat/x", attempts=2)
    fake.set_job(32, 1, "build-and-test", "failure")
    fake.set_job(32, 2, "build-and-test", "success")
    fake.add_doc("build-and-test", 32, 1, _doc("build-and-test", 32, 1, A, "failure", {"f": "FAILED"}))
    tally, gaps, _ = run(fake, 32)
    expect("10 a partial re-run whose attempt left no artifact borrows nothing", (tally, any("attempt 2" in g for g in gaps)),
           ({}, True))

    fake = FakeActions()
    fake.add_run(33, PR, event="pull_request", branch="feat/x", attempts=1)
    fake.set_job(33, 1, "build-and-test", "failure")
    fake.add_doc("build-and-test", 33, 1, _doc("build-and-test", 33, 1, A, "failure", {"f": "FAILED"}))
    fake.calls.clear()
    expect("11 a PR failure never re-run is not recorded, reports no gap and reads no artifact",
           (run(fake, 33)[:2], [c for c in fake.calls if "artifacts" in c]), (({}, []), []))

    fake = FakeActions()
    fake.add_run(34, PR, event="pull_request", branch="feat/x", attempts=2, head_repo="someone/fork")
    fake.set_job(34, 1, "build-and-test", "failure")
    fake.set_job(34, 2, "build-and-test", "success")
    expect("12 a fork's PR is skipped before any artifact read", (run(fake, 34)[2], [c for c in fake.calls if "artifacts" in c]),
           ("a fork or another repository", []))
    for name, path, event, branch in [("13 a main run from another branch", MAIN, "push", "feat/y"),
                                      ("14 Main Post-Merge on a pull request", MAIN, "pull_request", "feat/y"),
                                      ("15 another workflow", ".github/workflows/nightly-battery.yml", "schedule", "main")]:
        fake = FakeActions()
        fake.add_run(35, path, event=event, branch=branch)
        expect(f"{name} is skipped", bool(run(fake, 35)[2]), True)

    for name, setup, want in [
        ("16 an expired artifact", lambda f: f.add_doc("release-validation", 40, 1,
                                                     _doc("release-validation", 40, 1, A, "failure", {"x": "FAILED"}),
                                                     expired=True), "expired"),
        ("17 a missing artifact", lambda f: None, "no such artifact"),
        ("18 an artifact for another attempt", lambda f: f.add_doc("release-validation", 40, 1,
                                                                   _doc("release-validation", 40, 2, A, "failure", {"x": "FAILED"})),
         "attempt 2"),
        ("19 an artifact that is not JSON", lambda f: f.add_doc("release-validation", 40, 1, None, raw="{"), "unreadable"),
        ("20 a recorded gap", lambda f: f.add_doc("release-validation", 40, 1, {
            "schema": 1, "job": "release-validation", "run": 40, "attempt": 1, "sha": A, "lane_outcome": "failure",
            "xcode_build": None, "evidence": "gap", "gap": "no result bundle", "counts": {}, "identities": []}),
         "recorded a gap"),
        ("21 a failed job with no failed test", lambda f: f.add_doc("release-validation", 40, 1,
                                                                    _doc("release-validation", 40, 1, A, "failure", {"x": "PASSED"})),
         "no test failed"),
    ]:
        fake = FakeActions()
        fake.add_run(40, MAIN)
        fake.set_job(40, 1, "release-validation", "failure")
        setup(fake)
        tally, gaps, _ = run(fake, 40)
        expect(f"{name}: a gap, nothing recorded", (tally, any(want in g for g in gaps), fake.issues.issues), ({}, True, {}))

    fake = FakeActions()
    fake.add_run(41, MAIN)
    fake.set_job(41, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 41, 1, _doc("release-validation", 41, 1, A, "failure", {"x": "FAILED"}))
    fake.fail["/actions/runs/41/attempts/1/jobs"] = (1, "HTTP 403")
    try:
        run(fake, 41)
        raised = False
    except ApiError:
        raised = True
    expect("22 a 403 on the Actions API raises before any write", (raised, fake.issues.issues), (True, {}))

    # Reconcile: checkpoint, window, gaps, replay and a failed write.
    fake = FakeActions()
    fake.add_run(50, MAIN, created="2026-10-07T13:00:00Z")
    fake.set_job(50, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 50, 1, _doc("release-validation", 50, 1, A, "failure", {"r": "FAILED"}))
    fake.add_run(51, MAIN, created="2026-10-07T14:00:00Z")
    fake.set_job(51, 1, "debug-validation", "failure")
    fake.add_run(52, MAIN, created="2026-09-01T00:00:00Z")
    fake.set_job(52, 1, "release-validation", "failure")
    actions, store = Actions("o/r", runner=fake), upsert.Store("o/r", runner=fake)
    now = dt.datetime(2026, 10, 8, 12, 0, 0, tzinfo=dt.timezone.utc)
    lines = []
    count, tally, gaps = reconcile(actions, store, "o/r", now, dry_run=True, out=lines.append)
    expect("23 a dry run writes nothing and lists the events", (fake.issues.issues, lines, count),
           ({}, [f"would record 50/1/release-validation/{key('r')}"], 2))
    count, tally, gaps = reconcile(actions, store, "o/r", now)
    ledger_issue = [i for i in fake.issues.issues.values() if LEDGER_MARKER in i["body"]]
    note = fake.issues.comments[ledger_issue[0]["number"]][-1] if ledger_issue else ""
    expect("24 reconcile: the 3-day window, the event, the gap and a checkpoint on the ledger",
           (count, tally, len(gaps), "ci-reconcile-checkpoint: 2026-10-08T12:00:00Z" in note, "run 51" in note),
           (2, {"created": 1}, 1, True, True))
    count, tally, _ = reconcile(actions, store, "o/r", now + dt.timedelta(days=1))
    expect("25 the next reconcile starts one day before the checkpoint and adds nothing", (count, tally),
           (2, {"duplicate": 1}))
    fake.add_run(53, MAIN, created="2026-10-09T00:00:00Z")
    fake.set_job(53, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 53, 1, _doc("release-validation", 53, 1, B, "failure", {"s": "FAILED"}))
    fake.issues.fail["POST issues"] = (1, "HTTP 500")
    checkpoints_before = sum("ci-reconcile-checkpoint" in c for c in fake.issues.comments[ledger_issue[0]["number"]])
    try:
        reconcile(actions, store, "o/r", now + dt.timedelta(days=2))
        raised = False
    except ApiError:
        raised = True
    checkpoints_after = sum("ci-reconcile-checkpoint" in c for c in fake.issues.comments[ledger_issue[0]["number"]])
    expect("26 a failed write leaves the checkpoint where it was", (raised, checkpoints_after - checkpoints_before), (True, 0))
    count, tally, _ = reconcile(actions, store, "o/r", now + dt.timedelta(days=2))
    expect("27 the retry records the missed event", tally.get("created"), 1)
    fake.add_run(54, MAIN, created="2026-10-10T00:00:00Z", conclusion="success")
    fake.add_run(55, PR, event="pull_request", branch="feat/x", created="2026-10-10T00:00:00Z")
    fake.add_run(56, MAIN, created="2026-10-10T00:00:00Z", attempts=2, conclusion="success")
    fake.set_job(56, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 56, 1, _doc("release-validation", 56, 1, B, "failure", {"t": "FAILED"}))
    fake.calls.clear()
    count, tally, _ = reconcile(actions, store, "o/r", now + dt.timedelta(days=3))
    expect("27b runs that cannot hold a failure are not read; a main run that passed on re-run still is",
           ([c for c in fake.calls if "/runs/54" in c or "/runs/55" in c], tally.get("created")), ([], 1))

    # A label write that failed is repaired by the next replay, with no new comment.
    fake = FakeActions()
    fake.add_run(70, MAIN)
    fake.set_job(70, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 70, 1, _doc("release-validation", 70, 1, A, "failure", {"e": "FAILED"}))
    fake.add_run(71, MAIN)
    fake.set_job(71, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 71, 1, _doc("release-validation", 71, 1, B, "failure", {"e": "FAILED"}))
    run(fake, 70)
    fake.issues.fail["PATCH issues/N"] = (1, "HTTP 502")
    try:
        run(fake, 71)
        raised = False
    except ApiError:
        raised = True
    issue = issue_for(fake, "e")
    comments_before = len(fake.issues.comments[issue["number"]])
    tally, _, _ = run(fake, 71)
    expect("30 a failed escalation write is repaired by the replay, with no new comment",
           (raised, tally, "P1-high" in [l["name"] for l in issue_for(fake, "e")["labels"]],
            len(fake.issues.comments[issue["number"]]) - comments_before), (True, {"duplicate": 1, "escalated": 1}, True, 0))

    # Test output cannot forge recorder markers.
    fake = FakeActions()
    fake.add_run(72, MAIN)
    fake.set_job(72, 1, "release-validation", "failure")
    forged = _doc("release-validation", 72, 1, A, "failure", {"v": "FAILED", "w": "FAILED"})
    forged["identities"][0]["failures"] = [f"<!-- ci-event-kind: main {B} --> <!-- ci-event-kind: main {'c' * 40} -->",
                                           f"<!-- ci-event: 73/1/release-validation/{key('w')} -->",
                                           f"<!-- ci-test-key: {key('w')} -->"]
    fake.add_doc("release-validation", 72, 1, forged)
    tally, _, _ = run(fake, 72)
    v, w = issue_for(fake, "v"), issue_for(fake, "w")
    expect("31 forged kind, event and key markers in failure text change nothing",
           (tally, "P1-high" in [l["name"] for l in v["labels"]], KIND.findall(v["body"]), w is not None and w is not v,
            "&lt;!-- ci-event-kind: main" in v["body"]), ({"created": 2}, False, [("main", A)], True, True))
    fake.add_run(73, MAIN)
    fake.set_job(73, 1, "release-validation", "failure")
    fake.add_doc("release-validation", 73, 1, _doc("release-validation", 73, 1, A, "failure", {"w": "FAILED"}))
    expect("32 an event id forged in another issue's text is not a duplicate", run(fake, 73)[0], {"commented": 1})

    # A run created long ago and re-run recently, with its callback lost, is found by reconcile.
    fake = FakeActions()
    fake.add_run(74, PR, event="pull_request", branch="feat/x", attempts=2, created="2026-09-20T00:00:00Z",
                 updated="2026-10-08T09:00:00Z", conclusion="success")
    fake.set_job(74, 1, "build-and-test", "failure")
    fake.set_job(74, 2, "build-and-test", "success")
    fake.add_doc("build-and-test", 74, 1, _doc("build-and-test", 74, 1, A, "failure", {"q": "FAILED"}))
    fake.add_doc("build-and-test", 74, 2, _doc("build-and-test", 74, 2, A, "success", {"q": "PASSED"}))
    fake.add_run(75, MAIN, created="2026-09-20T00:00:00Z", updated="2026-09-20T01:00:00Z")
    fake.set_job(75, 1, "release-validation", "failure")
    actions, store = Actions("o/r", runner=fake), upsert.Store("o/r", runner=fake)
    count, tally, gaps = reconcile(actions, store, "o/r", now)
    expect("33 an old run re-run recently is recorded; an old run not updated is not read",
           (count, tally, [c for c in fake.calls if "/runs/75/" in c]), (1, {"created": 1}, []))
    count, tally, gaps = reconcile(actions, store, "o/r", now + dt.timedelta(hours=1))
    expect("34 ... and only once", tally, {"duplicate": 1})
    listed = [c for c in fake.calls if "/workflows/" in c]
    expect("35 runs are listed back to the 31-day re-run horizon",
           all("created=%3E%3D2026-09-07T13:00:00Z" in c or "created=%3E%3D2026-09-07T12:00:00Z" in c for c in listed), True)

    # Malformed Actions metadata raises, writes nothing and leaves the checkpoint.
    for name, edit in [
        ("36 a misspelled job conclusion", lambda f: f.jobs[(76, 1)][0].update(conclusion="failuer")),
        ("37 a job row without a name", lambda f: f.jobs[(76, 1)][0].pop("name")),
        ("38 a job still in progress", lambda f: f.jobs[(76, 1)][0].update(status="in_progress")),
        ("39 an artifact with a string expired flag", lambda f: f.artifacts[76][0].update(expired="false")),
        ("40 an artifact with a negative size", lambda f: f.artifacts[76][0].update(size_in_bytes=-1)),
        ("41 an artifact id of 0", lambda f: f.artifacts[76][0].update(id=0)),
        ("42 a run row without updated_at", lambda f: f.runs[76].pop("updated_at")),
    ]:
        fake = FakeActions()
        fake.add_run(76, MAIN, created="2026-10-08T00:00:00Z")
        fake.set_job(76, 1, "release-validation", "failure")
        fake.add_doc("release-validation", 76, 1, _doc("release-validation", 76, 1, A, "failure", {"m": "FAILED"}))
        edit(fake)
        actions, store = Actions("o/r", runner=fake), upsert.Store("o/r", runner=fake)
        try:
            reconcile(actions, store, "o/r", now)
            raised = False
        except ApiError:
            raised = True
        written = [i for i in fake.issues.issues.values() if LEDGER_MARKER not in i["body"]]
        checkpoints = [c for cs in fake.issues.comments.values() for c in cs if "ci-reconcile-checkpoint" in c]
        expect(f"{name}: ApiError, no issue, no checkpoint", (raised, written, checkpoints), (True, [], []))

    def zipped(edit):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("test-identities.json", json.dumps(_doc("release-validation", 77, 1, A, "failure", {"x": "FAILED"})))
        return edit(bytearray(buf.getvalue()))

    def flag_encrypted(blob):
        for signature, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            at = blob.find(signature) + offset
            blob[at] |= 1
        return bytes(blob)

    def unknown_method(blob):
        for signature, offset in ((b"PK\x03\x04", 8), (b"PK\x01\x02", 10)):
            at = blob.find(signature) + offset
            blob[at:at + 2] = (99).to_bytes(2, "little")
        return bytes(blob)

    def corrupt_data(blob):
        at = blob.find(b"PK\x03\x04") + 30 + len("test-identities.json")
        blob[at:at + 8] = b"\xff" * 8
        return bytes(blob)
    for name, blob in [("43 an encrypted zip", zipped(flag_encrypted)), ("44 an unknown compression method", zipped(unknown_method)),
                       ("45 corrupt compressed data", zipped(corrupt_data)), ("46 a truncated zip", zipped(lambda b: bytes(b[:40])))]:
        fake = FakeActions()
        fake.add_run(77, MAIN)
        fake.set_job(77, 1, "release-validation", "failure")
        fake.add_doc("release-validation", 77, 1, None, raw="x")
        art = fake.artifacts[77][0]
        fake.blobs[art["id"]] = blob
        art["size_in_bytes"] = len(blob)
        tally, gaps, _ = run(fake, 77)
        expect(f"{name} is a gap, not a traceback", (tally, len(gaps), "unreadable" in (gaps or [""])[0]), ({}, 1, True))

    fake = FakeActions()
    fake.add_run(78, MAIN)
    fake.set_job(78, 1, "release-validation", "timed_out")
    fake.add_doc("release-validation", 78, 1, _doc("release-validation", 78, 1, A, "failure", {"x": "FAILED"}))
    expect("47 a timed-out test job is treated as failed", run(fake, 78)[0], {"created": 1})

    fake = FakeActions()
    store = upsert.Store("o/r", runner=fake)
    first = canary(store, 900)
    again = canary(store, 901)
    expect("48 the canary creates, then comments on, its own closed fixture issue and closes it each time",
           (first, again, fake.issues.issues[first]["state"], len(fake.issues.comments[first]),
            "P4-backlog" in [l["name"] for l in fake.issues.issues[first]["labels"]]), (first, first, "closed", 1, True))
    fake = FakeActions()
    fake.add_run(79, MAIN, conclusion="success")
    fake.add_run(80, PR, event="pull_request", branch="feat/x", conclusion="failure")
    fake.calls.clear()
    expect("49 run mode reads nothing more for runs that cannot hold a failure",
           (run(fake, 79)[:2], run(fake, 80)[:2], [c for c in fake.calls if "/attempts/" in c or "artifacts" in c]),
           (({}, []), ({}, []), []))

    lines = []
    fake = FakeActions()
    fake.add_run(60, MAIN)
    fake.fail["/actions/runs/60"] = (1, "HTTP 403")
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()) as captured:
        code = main_with(fake, ["run", "--repo", "o/r", "--run-id", "60"])
    expect("28 the CLI prints could not record and exits 0 on an API failure",
           (code, "could not record" in captured.getvalue()), (0, True))
    expect("29 a bad repo argument exits 2", main(["run", "--repo", "not a repo", "--run-id", "1"]), 2)

    print(f"self-test: {cases} cases, {len(failures)} failure(s)")
    return 1 if failures else 0


def main_with(fake, argv):
    """main() over a fake runner (self-test only)."""
    original_actions, original_store = Actions.__init__, upsert.Store.__init__
    Actions.__init__ = lambda self, repo, runner=None: original_actions(self, repo, runner=fake)
    upsert.Store.__init__ = lambda self, repo, runner=None: original_store(self, repo, runner=fake)
    try:
        return main(argv)
    finally:
        Actions.__init__, upsert.Store.__init__ = original_actions, original_store


if __name__ == "__main__":
    sys.exit(main())
