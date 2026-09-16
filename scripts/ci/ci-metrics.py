#!/usr/bin/env python3
"""scripts/ci/ci-metrics.py — one line of numbers per macOS CI job (#3019).

The #3013 receipts (Mac-minutes, cache outcome, compiler hit counts, phase
seconds) were assembled by hand from downloaded job logs. The macOS build/test
jobs (build-and-test, release-validation, debug-validation, battery; not the
advisory older-macOS launch) end with `ci-metrics.py emit`, which prints one line

    EW-CI-METRICS {"job": ..., "family": ..., "phase_build_release_s": 359, ...}

and a Markdown table into $GITHUB_STEP_SUMMARY. `collect` pulls those lines
back out of the last N completed runs, adds each job's queue seconds from the
jobs API, and prints JSON lines: the input for the efficiency regrade.

emit reads:
  --metrics-file   the `phase_<name>_s=<int>` lines scripts/lib/ci-phase.sh
                   appended (one per wrapped phase)
  --log GLOB       phase logs to count compiler `Cache hit` / `Cache miss`
                   remarks in (repeatable); a log that does not exist is an
                   error, a glob that matches nothing is an error
  --set KEY=VALUE  values the workflow already knows (cache matched key, exact
                   hit, in-process validation outcome/seconds, restore and save
                   seconds); repeatable; VALUE may be empty
  --job, --family  identity

emit is advisory in the workflows (continue-on-error), so a nonzero exit here
never fails a lane; it does make a broken instrument visible in the step log
instead of printing a plausible line with holes. Unreadable inputs exit 1
AFTER printing whatever was collected, with `"errors": [...]` in the JSON.

collect needs `gh` authenticated with actions:read on the repository:
  ci-metrics.py collect --workflow pr-check.yml --runs 10 [--event pull_request]
  ci-metrics.py collect --workflow main-post-merge.yml --runs 10 --event push

`--self-test` runs the fixture matrix and never touches GitHub.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

MARKER = "EW-CI-METRICS "
# Xcode's compilation-cache remarks. The job's own diagnostic line
# `==> Xcode cache: matched=<key> hit=false` must NOT count: it never carries
# the two words adjacent, and the regex requires exactly that adjacency.
# `Cache hit rate: 95%` is a summary, not an event: excluded by the lookahead.
HIT_RE = re.compile(r"\bcache hit\b(?![ \t]+(?:rate|ratio)\b)", re.IGNORECASE)
MISS_RE = re.compile(r"\bcache miss\b(?![ \t]+(?:rate|ratio)\b)", re.IGNORECASE)
PHASE_RE = re.compile(r"^phase_([A-Za-z0-9_]+)_s=(\d+)$")
# collect: every job that ran on a macOS runner counts toward Mac-minutes,
# including the advisory older-macOS launch and jobs that failed before their
# metrics step. Selected by runner LABEL, never by name, so a renamed or added
# macOS job cannot fall out of the accounting.
CACHE_SIZE_RE = re.compile(r"Cache Size: ~\d+ MB \((\d+) B\)")
CACHE_KEY_RE = re.compile(r"Cache restored from key: (\S+)")


def _ncpu() -> int | None:
    try:
        out = subprocess.run(["sysctl", "-n", "hw.ncpu"], capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return int(out.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return os.cpu_count()


def read_phases(path: str, errors: list) -> dict:
    phases: dict = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                m = PHASE_RE.match(line)
                if not m:
                    errors.append(f"metrics-file: unparseable line {line!r}")
                    continue
                key = f"phase_{m.group(1)}_s"
                # A phase wrapped twice (a retry) keeps the SUM, and says so.
                phases[key] = phases.get(key, 0) + int(m.group(2))
    except OSError as exc:
        errors.append(f"metrics-file: {exc}")
    return phases


def count_cache_remarks(patterns: list, errors: list) -> tuple:
    """(hits, misses, measured). `measured` is True only when at least one log
    was read AND nothing asked for was missing or unreadable: a partial count
    would otherwise be published as a measurement. Each file is counted once
    even when two patterns match it."""
    hits = misses = 0
    seen: set = set()
    complete = True
    for pattern in patterns:
        matches = sorted(glob.glob(pattern))
        if not matches:
            errors.append(f"log: no file matches {pattern!r}")
            complete = False
        for path in matches:
            canonical = os.path.realpath(path)
            if canonical in seen:
                continue
            seen.add(canonical)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if HIT_RE.search(line):
                            hits += 1
                        elif MISS_RE.search(line):
                            misses += 1
            except OSError as exc:
                errors.append(f"log {path}: {exc}")
                complete = False
    if patterns and not seen:
        errors.append("log: no phase log could be read; hit/miss counts are not measurements")
    return hits, misses, bool(seen) and complete


def parse_sets(items: list, errors: list) -> dict:
    out: dict = {}
    for item in items:
        if "=" not in item:
            errors.append(f"--set expects KEY=VALUE, got {item!r}")
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z0-9_]+", key):
            errors.append(f"--set key must match [A-Za-z0-9_]+, got {key!r}")
            continue
        value = value.strip()
        if re.fullmatch(r"-?\d+", value):
            out[key] = int(value)
        elif value.lower() in ("true", "false"):
            out[key] = value.lower() == "true"
        else:
            out[key] = value
    return out


def build_record(args, env: dict) -> tuple:
    errors: list = []
    record = {
        "job": args.job,
        "family": args.family,
        "run_id": env.get("GITHUB_RUN_ID", ""),
        "run_attempt": env.get("GITHUB_RUN_ATTEMPT", ""),
        "sha": env.get("GITHUB_SHA", ""),
        "event": env.get("GITHUB_EVENT_NAME", ""),
        "ncpu": _ncpu(),
    }
    record.update(read_phases(args.metrics_file, errors))
    hits, misses, measured = count_cache_remarks(args.log, errors)
    if measured:
        record["compiler_cache_hits"] = hits
        record["compiler_cache_misses"] = misses
    record.update(parse_sets(args.set, errors))
    # Every phase is wrapped exactly once and none nests another (the
    # overlapped eval+tests pair was measured slower and removed, #3019), so
    # the total is a plain sum.
    phases = {k: v for k, v in record.items()
              if k.startswith("phase_") and k.endswith("_s") and type(v) is int}
    record["phases_total_s"] = sum(phases.values())
    if errors:
        record["errors"] = errors
    return record, errors


def summary_table(record: dict) -> str:
    rows = ["| metric | value |", "|---|---|"]
    for key in sorted(record):
        if key == "errors":
            continue
        rows.append(f"| `{key}` | {record[key]} |")
    for err in record.get("errors", []):
        rows.append(f"| error | {err} |")
    return "\n".join(rows) + "\n"


def cmd_emit(args) -> int:
    record, errors = build_record(args, os.environ)
    line = MARKER + json.dumps(record, sort_keys=True, separators=(",", ":"))
    print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        try:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write(f"### CI metrics: {record['job']}\n\n{summary_table(record)}\n")
        except OSError as exc:
            errors.append(f"step summary: {exc}")
            print(f"ci-metrics: could not write step summary: {exc}", file=sys.stderr)
    for err in errors:
        print(f"ci-metrics: {err}", file=sys.stderr)
    return 1 if errors else 0


# --- collect -----------------------------------------------------------------

def _gh_json(args: list):
    proc = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def _gh_text(args: list) -> str:
    proc = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: {proc.stderr.strip()}")
    return proc.stdout


def _iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def extract_restore_facts(log_text: str) -> dict:
    """The archive size and key `actions/cache/restore` prints. Only the log has
    the ARCHIVE bytes; the in-job line carries the on-disk size, which is a
    different number and is never substituted for this one."""
    out: dict = {}
    m = CACHE_SIZE_RE.search(log_text)
    if m:
        out["cache_archive_bytes"] = int(m.group(1))
    m = CACHE_KEY_RE.search(log_text)
    if m:
        out["cache_restored_from_key"] = m.group(1)
    return out


def is_macos_job(job: dict) -> bool:
    labels = job.get("labels") or []
    return any(str(label).lower().startswith("macos") for label in labels)


def extract_metric_lines(log_text: str) -> list:
    """Every EW-CI-METRICS record in a job log. The runner prefixes each line
    with a timestamp; the marker is searched anywhere in the line. A line whose
    JSON does not parse is reported as {"parse_error": ...} rather than dropped."""
    out = []
    for line in log_text.splitlines():
        idx = line.find(MARKER)
        if idx < 0:
            continue
        payload = line[idx + len(MARKER):].strip()
        try:
            value = json.loads(payload)
            if not isinstance(value, dict):
                raise ValueError("metrics payload must be a JSON object")
            out.append(value)
        except ValueError as exc:  # JSONDecodeError is a ValueError
            out.append({"parse_error": str(exc), "raw": payload[:200]})
    return out


def cmd_collect(args) -> int:
    repo = args.repo
    list_args = ["run", "list", "--repo", repo, "--workflow", args.workflow, "--status", "completed",
                 "--limit", str(args.runs), "--json", "databaseId,createdAt,event,headSha,conclusion,headBranch"]
    if args.event:
        list_args += ["--event", args.event]
    if args.branch:
        list_args += ["--branch", args.branch]
    runs = _gh_json(list_args)
    if not isinstance(runs, list):
        print("ci-metrics collect: run list is not a JSON array", file=sys.stderr)
        return 1
    emitted = 0
    for run in runs:
        run_id = run["databaseId"]
        # Every attempt (filter=all) and every page: a rerun's earlier attempt
        # cost Mac-minutes too, and the default filter hides it.
        pages = _gh_json(["api", "--paginate", "--slurp",
                          f"repos/{repo}/actions/runs/{run_id}/jobs?filter=all&per_page=100"])
        jobs = [job for page in pages for job in page.get("jobs", [])]
        for job in jobs:
            name = job.get("name", "")
            if not is_macos_job(job):
                continue
            base = {
                "run_id": run_id,
                "run_created_at": run.get("createdAt"),
                "run_event": run.get("event"),
                "run_conclusion": run.get("conclusion"),
                "run_branch": run.get("headBranch"),
                "sha": run.get("headSha"),
                "job_name": name,
                "job_conclusion": job.get("conclusion"),
                "job_id": job.get("id"),
                "job_labels": job.get("labels"),
            }
            try:
                created = _iso(job["created_at"]) if job.get("created_at") else None
                started = _iso(job["started_at"]) if job.get("started_at") else None
                completed = _iso(job["completed_at"]) if job.get("completed_at") else None
                base["queue_s"] = int((started - created).total_seconds()) if created and started else None
                base["execution_s"] = int((completed - started).total_seconds()) if started and completed else None
            except (ValueError, KeyError) as exc:
                base["time_error"] = str(exc)
            restore_facts: dict = {}
            try:
                log_text = _gh_text(["api", f"repos/{repo}/actions/jobs/{job['id']}/logs"])
                records = extract_metric_lines(log_text)
                restore_facts = extract_restore_facts(log_text)
            except RuntimeError as exc:
                records = [{"log_error": str(exc)}]
            if not records:
                # A macOS job with no marker: the advisory launch (no metrics
                # step by design) or a job that died before its metrics step.
                # Reported, never dropped, so Mac-minutes stay complete.
                records = [{"metrics_missing": True}]
            if len(records) > 1:
                # One accounting row per job: a second marker (a re-run step)
                # must not double the job's queue/execution seconds.
                records = [{**records[-1], "metric_records": records}]
            base.update(restore_facts)
            for rec in records:
                merged = dict(base)
                merged.update(rec)
                print(json.dumps(merged, sort_keys=True))
                emitted += 1
    print(f"ci-metrics collect: {emitted} job record(s) from {len(runs)} run(s)", file=sys.stderr)
    return 0 if emitted else 1


# --- self-test ---------------------------------------------------------------

def self_test() -> int:
    fails = 0

    def expect(label, cond):
        nonlocal fails
        print(("ok   " if cond else "FAIL ") + label)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        metrics = os.path.join(tmp, "m.env")
        with open(metrics, "w") as fh:
            fh.write("phase_build_release_s=359\nphase_tests_release_s=287\nphase_tests_release_s=3\n")
        log_a = os.path.join(tmp, "xcode-build-release.log")
        with open(log_a, "w") as fh:
            fh.write("remark: Cache hit for x\nCache miss\nCache miss\n==> Xcode cache: matched=k hit=false\n"
                     "something CACHE HIT here\nno cache remark on this line\nCache hit rate: 95%\nCache miss ratio 5%\n")
        log_b = os.path.join(tmp, "xcode-tests-release.log")
        with open(log_b, "w") as fh:
            fh.write("Cache hit\n")

        class A:  # emit args
            job = "build-and-test"; family = "release"; metrics_file = metrics
            log = [os.path.join(tmp, "xcode-*.log")]
            set = ["cache_matched_key=abc-def", "cache_hit=false", "cas_validate_s=87", "note="]

        env = {"GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": "deadbeef", "GITHUB_EVENT_NAME": "pull_request"}
        rec, errs = build_record(A, env)
        expect("clean inputs: no errors", not errs)
        expect("phase seconds parsed", rec.get("phase_build_release_s") == 359)
        expect("repeated phase is summed (retry)", rec.get("phase_tests_release_s") == 290)
        expect("phases_total_s sums the phases", rec.get("phases_total_s") == 649)
        expect("hits counted across both logs, case-insensitive", rec.get("compiler_cache_hits") == 3)
        expect("misses counted", rec.get("compiler_cache_misses") == 2)
        expect("the job's own 'cache: matched= hit=' line is NOT a hit", rec.get("compiler_cache_hits") == 3)
        expect("--set int becomes int", rec.get("cas_validate_s") == 87)
        expect("--set bool becomes bool", rec.get("cache_hit") is False)
        expect("--set empty value kept as empty string", rec.get("note") == "")
        expect("identity from env", rec.get("sha") == "deadbeef" and rec.get("event") == "pull_request")
        line = MARKER + json.dumps(rec, sort_keys=True, separators=(",", ":"))
        expect("emit line round-trips through extract_metric_lines",
               extract_metric_lines("2026-09-16T00:00:00.0Z " + line + "\nother\n") == [rec])

        class B(A):
            metrics_file = os.path.join(tmp, "missing.env")
            log = [os.path.join(tmp, "nothing-*.log")]
            set = ["bad", "weird key=1"]

        rec_b, errs_b = build_record(B, env)
        expect("missing metrics file is an error, not a silent zero", any("metrics-file" in e for e in errs_b))
        expect("glob with no match is an error", any("no file matches" in e for e in errs_b))
        expect("no readable log means NO hit/miss keys (not 0/0)", "compiler_cache_hits" not in rec_b)
        expect("malformed --set is an error", sum("--set" in e for e in errs_b) == 2)
        expect("errors travel in the record", rec_b.get("errors") == errs_b)

        class C1(A):
            log = [os.path.join(tmp, "xcode-*.log"), os.path.join(tmp, "xcode-build-*.log")]
        rec_c1, _ = build_record(C1, env)
        expect("overlapping --log patterns count each file once", rec_c1.get("compiler_cache_hits") == 3)

        class C2(A):
            log = [os.path.join(tmp, "xcode-*.log"), os.path.join(tmp, "nothing-*.log")]
        rec_c2, _ = build_record(C2, env)
        expect("a pattern with no match makes the count NOT a measurement", "compiler_cache_hits" not in rec_c2)

        with open(metrics, "a") as fh:
            fh.write("phase_eval_packages_s=120\n")
        rec_d, _ = build_record(A, env)
        expect("phases_total_s is the plain sum of every wrapped phase (359 + 290 + 120)",
               rec_d.get("phases_total_s") == 769)
        with open(metrics, "w") as fh:
            fh.write("phase_build_release_s=359\nphase_tests_release_s=287\nphase_tests_release_s=3\n")

        with open(metrics, "a") as fh:
            fh.write("garbage line\n")
        rec_c, errs_c = build_record(A, env)
        expect("unparseable metrics line is an error and the rest still parse",
               any("unparseable" in e for e in errs_c) and rec_c.get("phase_build_release_s") == 359)

        expect("collect: a metric line with broken JSON is reported, not dropped",
               extract_metric_lines(MARKER + "{not json")[0].get("parse_error") is not None)
        expect("collect: no marker means no records", extract_metric_lines("plain\nlog\n") == [])
        expect("collect: a non-object payload is a parse error, not a crash later",
               extract_metric_lines(MARKER + "null")[0].get("parse_error") is not None
               and extract_metric_lines(MARKER + "[1,2]")[0].get("parse_error") is not None)
        facts = extract_restore_facts("x Cache Size: ~5420 MB (5683439065 B)\ny Cache restored from key: macOS-ARM64-xcode-release-abc\n")
        expect("collect: archive bytes and restored key come from the restore log lines",
               facts == {"cache_archive_bytes": 5683439065, "cache_restored_from_key": "macOS-ARM64-xcode-release-abc"})
        expect("collect: no restore lines means no archive facts", extract_restore_facts("Cache not found for input keys: k") == {})
        expect("collect: macOS jobs are picked by runner label, including the advisory launch",
               is_macos_job({"labels": ["macos-14"]}) and is_macos_job({"labels": ["macos-26"]})
               and not is_macos_job({"labels": ["ubuntu-latest"]}) and not is_macos_job({}))

    print("== ci-metrics self-test " + ("PASS" if fails == 0 else f"FAIL ({fails})") + " ==")
    return 1 if fails else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="cmd")
    emit = sub.add_parser("emit")
    emit.add_argument("--job", required=True)
    emit.add_argument("--family", required=True)
    emit.add_argument("--metrics-file", required=True)
    emit.add_argument("--log", action="append", default=[])
    emit.add_argument("--set", action="append", default=[])
    collect = sub.add_parser("collect")
    collect.add_argument("--workflow", required=True)
    collect.add_argument("--runs", type=int, default=10)
    collect.add_argument("--event", default="")
    collect.add_argument("--branch", default="")
    collect.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "saurabhav88/EnviousWispr"))
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.cmd == "emit":
        return cmd_emit(args)
    if args.cmd == "collect":
        try:
            return cmd_collect(args)
        except (RuntimeError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
            print(f"ci-metrics collect: {exc}", file=sys.stderr)
            return 1
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
