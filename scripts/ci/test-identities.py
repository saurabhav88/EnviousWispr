#!/usr/bin/env python3
"""Every executed test and its result, from one Xcode test lane's result bundle (#3524 PR 4).

The test jobs run this after their test step, on the macOS runner, and upload the JSON it
writes as artifact `test-identities-<job>-<run>-<attempt>`. scripts/ci/record-test-failures.py
reads only that JSON, never the bundle, so the trusted recorder runs no Xcode tool and parses
no test output.

Source: `xcrun xcresulttool get test-results tests --path <bundle>` (measured on Xcode 27A266a,
2026-10-08, fixtures in scripts/ci/fixtures/test-identities/). Each "Test Case" node is one
identity:
  key               nodeIdentifierURL, e.g. test://com.apple.xcode/EnviousWispr/
                    EnviousWisprTests/RouterCeilingParserTests/classBody_ignoresBraceInComment()
                    (unique across a 7758-case run; it names the bundle, suite and function)
  target / suite    the enclosing "Unit test bundle" and nearest "Test Suite" names
  result            PASSED | FAILED | SKIPPED | EXPECTED_FAILURE (from Passed, Failed, Skipped,
                    Expected Failure; scripts/lib/lane-verdict.py reads the same field)
A parameterized test is ONE identity; its failing "Arguments" are listed under it. Repetitions
sit under Arguments and do not add identities.

Evidence is all or nothing. A missing bundle, a failed or malformed extraction, a Test Case
without a key or result, an unknown result or a duplicate key writes `"evidence": "gap"` with
the reason and NO identities, so a partial list can never pass for a complete one.

Exit 0 when the JSON was written (complete or gap); 2 on bad arguments or when it cannot be
written. The workflow step never changes the job's verdict (continue-on-error).

Usage:
  test-identities.py --bundle <x.xcresult> --job <name> --run <id> --attempt <n>
                     --sha <tested sha> --lane-outcome <success|failure|cancelled|skipped> --out <json>
  test-identities.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

SCHEMA = 1
RESULTS = {"Passed": "PASSED", "Failed": "FAILED", "Skipped": "SKIPPED", "Expected Failure": "EXPECTED_FAILURE"}
OUTCOMES = ("success", "failure", "cancelled", "skipped")
MAX_MESSAGES, MAX_MESSAGE_CHARS = 5, 500
MAX_ARGUMENTS, MAX_ARGUMENT_CHARS = 10, 300
_SHA = re.compile(r"[0-9a-f]{40}")
_JOB = re.compile(r"[A-Za-z0-9_.-]{1,64}")


class Gap(Exception):
    """The bundle cannot vouch for a complete list of identities."""


def _children(node):
    kids = node.get("children", [])
    if not isinstance(kids, list):
        raise Gap(f"a {node.get('nodeType')!r} node has non-list children")
    if any(not isinstance(k, dict) for k in kids):
        raise Gap(f"a {node.get('nodeType')!r} node has a children entry that is not an object")
    return kids


def _validate_tree(node):
    """Every node down to Arguments and Repetitions is an object with a list of objects."""
    for child in _children(node):
        _validate_tree(child)


def _bounded(values, count, chars):
    return [str(v)[:chars] for v in values[:count]]


def identities(results):
    """[identity] from parsed `get test-results tests` JSON; raises Gap on any doubt."""
    if not isinstance(results, dict) or not isinstance(results.get("testNodes"), list):
        raise Gap("no testNodes list in the extraction")
    found, seen = [], set()

    def walk(node, target, suite):
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            target = node.get("name")
        elif kind == "Test Suite":
            suite = node.get("name")
        if kind != "Test Case":
            for child in _children(node):
                walk(child, target, suite)
            return
        key, raw = node.get("nodeIdentifierURL"), node.get("result")
        if not isinstance(key, str) or not key.startswith("test://"):
            raise Gap(f"a Test Case has no nodeIdentifierURL ({node.get('nodeIdentifier')!r})")
        if not isinstance(raw, str) or raw not in RESULTS:
            raise Gap(f"unknown result {raw!r} for {key}")
        if key in seen:
            raise Gap(f"duplicate test key {key}")
        seen.add(key)
        kids = _children(node)
        found.append({
            "key": key,
            "target": target,
            "suite": suite,
            "name": node.get("name"),
            "node_identifier": node.get("nodeIdentifier"),
            "result": RESULTS[raw],
            "failures": _bounded([k.get("name") for k in kids if k.get("nodeType") == "Failure Message"],
                                 MAX_MESSAGES, MAX_MESSAGE_CHARS),
            "failed_arguments": _bounded([k.get("name") for k in kids
                                          if k.get("nodeType") == "Arguments" and k.get("result") == "Failed"],
                                         MAX_ARGUMENTS, MAX_ARGUMENT_CHARS),
        })

    for node in results["testNodes"]:
        if not isinstance(node, dict):
            raise Gap("a testNodes entry is not an object")
        _validate_tree(node)
        walk(node, None, None)
    if not found:
        raise Gap("the extraction holds no Test Case")
    return found


def extract(bundle, runner=subprocess.run):
    """Parsed `get test-results tests` JSON for bundle; raises Gap when it cannot be read."""
    if not pathlib.Path(bundle).is_dir():
        raise Gap(f"no result bundle at {bundle}")
    try:
        proc = runner(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                      capture_output=True, text=True)
    except OSError as error:
        raise Gap(f"could not launch xcresulttool: {error}") from error
    if proc.returncode != 0:
        raise Gap(f"xcresulttool exited {proc.returncode}: {(proc.stderr or '').strip()[:300]}")
    try:
        return json.loads(proc.stdout)
    except ValueError as error:
        raise Gap(f"xcresulttool printed malformed JSON: {error}") from error


def xcode_build(runner=subprocess.run):
    try:
        out = runner(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split()
        return out[-1] if out else None
    except OSError:
        return None


def record(meta, load):
    """The document to write: meta plus identities, or meta plus the gap reason."""
    doc = {"schema": SCHEMA, **meta, "evidence": "complete", "gap": None, "counts": {}, "identities": []}
    try:
        found = identities(load())
    except Gap as gap:
        doc.update(evidence="gap", gap=str(gap))
        return doc
    doc["identities"] = found
    for item in found:
        doc["counts"][item["result"]] = doc["counts"].get(item["result"], 0) + 1
    return doc


def _meta(args):
    problems = []
    if not _JOB.fullmatch(args.job):
        problems.append(f"--job {args.job!r}")
    if args.run < 1 or args.attempt < 1:
        problems.append("--run and --attempt must be positive")
    if not _SHA.fullmatch(args.sha):
        problems.append(f"--sha {args.sha!r} is not a full lowercase sha")
    if args.lane_outcome not in OUTCOMES:
        problems.append(f"--lane-outcome {args.lane_outcome!r}")
    if problems:
        raise ValueError("; ".join(problems))
    return {"job": args.job, "run": args.run, "attempt": args.attempt, "sha": args.sha,
            "lane_outcome": args.lane_outcome}


def write(doc, out):
    out = pathlib.Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n")
    os.replace(tmp, out)


def self_test():
    here = pathlib.Path(__file__).resolve().parent / "fixtures" / "test-identities"
    failures, cases = [], 0

    def expect(name, got, want):
        nonlocal cases
        cases += 1
        ok = got == want
        print(f"{'ok  ' if ok else 'FAIL'} [{name}]" + ("" if ok else f" expected {want!r}, got {got!r}"))
        if not ok:
            failures.append(name)

    meta = {"job": "build-and-test", "run": 7, "attempt": 2, "sha": "a" * 40, "lane_outcome": "failure"}
    base = "test://com.apple.xcode/EnviousWispr/EnviousWisprTests/"

    doc = record(meta, lambda: json.loads((here / "failed-run.json").read_text()))
    failed = sorted(i["key"] for i in doc["identities"] if i["result"] == "FAILED")
    expect("1 a real failed run: complete, 9 identities, the 3 that failed",
           (doc["evidence"], len(doc["identities"]), failed),
           ("complete", 9, [base + "InverseTextNormalizerStreetAddressTests/" + n
                            for n in ("control(text:)", "notAddress(row:)", "yearGuardMiss()")]))
    by_key = {i["key"]: i for i in doc["identities"]}
    year = by_key[base + "InverseTextNormalizerStreetAddressTests/yearGuardMiss()"]
    expect("2 a failure keeps its target, suite and message",
           (year["target"], year["suite"], len(year["failures"]), year["failures"][0][:20]),
           ("EnviousWisprTests", "ITN formats dictated US street addresses (#3211)", 1, "Expectation failed: "))
    note = by_key[base + "InverseTextNormalizerStreetAddressTests/notAddress(row:)"]
    expect("3 a parameterized failure is one identity listing its failing arguments",
           [a[:24] for a in note["failed_arguments"]], ['(dictated: "Figures from', '(dictated: "Revenue for '])
    expect("4 the meta is carried unchanged", {k: doc[k] for k in meta}, meta)

    doc = record(meta, lambda: json.loads((here / "passed-run.json").read_text()))
    expect("5 a real passing run: 80 identities by result",
           (doc["evidence"], len(doc["identities"]), doc["counts"]),
           ("complete", 80, {"PASSED": 75, "SKIPPED": 3, "EXPECTED_FAILURE": 2}))
    reps = [i for i in doc["identities"] if i["key"].endswith("Issue1358FillerEmptyReproTests/realWordSurvives(_:)")]
    expect("6 repetitions do not add identities", len(reps), 1)
    expected_failures = sorted(i["key"].rsplit("/", 1)[1] for i in doc["identities"] if i["result"] == "EXPECTED_FAILURE")
    expect("7 Expected Failure is its own result", expected_failures,
           ["classBody_failsClosedOnSourceThatDoesNotParse()", "neverConcludingSessionIsReportedLoudly()"])

    def gap_of(results):
        doc = record(meta, lambda: results)
        return doc["evidence"], doc["identities"], doc["counts"], (doc["gap"] or "")

    real = json.loads((here / "failed-run.json").read_text())

    def mutate(edit):
        data = json.loads(json.dumps(real))
        edit(data)
        return data

    def first_case(data):
        node = data["testNodes"][0]
        while node.get("nodeType") != "Test Case":
            node = node["children"][0]
        return node

    def first_case_with_arguments(data):
        found = []

        def walk(node):
            if node.get("nodeType") == "Test Case" and any(c.get("nodeType") == "Arguments"
                                                            for c in node.get("children") or []):
                found.append(node)
            for child in node.get("children") or []:
                walk(child)
        for node in data["testNodes"]:
            walk(node)
        return found[0]

    for name, results, reason in [
        ("8 no testNodes", {"devices": []}, "no testNodes"),
        ("9 no Test Case at all", {"testNodes": [{"nodeType": "Test Plan", "children": []}]}, "no Test Case"),
        ("10 an unknown result", mutate(lambda d: first_case(d).update(result="Crashed")), "unknown result 'Crashed'"),
        ("11 a Test Case without its key", mutate(lambda d: first_case(d).pop("nodeIdentifierURL")), "no nodeIdentifierURL"),
        ("12 a duplicate key", mutate(lambda d: d["testNodes"][0]["children"][0]["children"][0]["children"].append(
            dict(first_case(d)))), "duplicate test key"),
        ("13 non-list children", mutate(lambda d: d["testNodes"][0].update(children="x")), "non-list children"),
        ("13b a string beside valid children", mutate(lambda d: d["testNodes"][0]["children"].append("x")),
         "not an object"),
        ("13c a malformed entry under an Arguments node", mutate(lambda d: next(
            c for c in first_case_with_arguments(d)["children"] if c.get("nodeType") == "Arguments"
        ).setdefault("children", []).append(7)), "not an object"),
        ("13d a list-valued result", mutate(lambda d: first_case(d).update(result=["Passed"])), "unknown result"),
        ("13e an object-valued result", mutate(lambda d: first_case(d).update(result={"x": 1})), "unknown result"),
    ]:
        evidence, found, counts, why = gap_of(results)
        expect(f"{name}: a gap with no identities", (evidence, found, counts, reason in why), ("gap", [], {}, True))

    def bad_load():
        raise Gap("xcresulttool exited 1: boom")
    doc = record(meta, bad_load)
    expect("14 an extraction failure is a gap", (doc["evidence"], doc["gap"], doc["identities"]),
           ("gap", "xcresulttool exited 1: boom", []))
    with tempfile.TemporaryDirectory() as tmp:
        try:
            extract(pathlib.Path(tmp) / "absent.xcresult")
            got = None
        except Gap as gap:
            got = str(gap)
        expect("15 a missing bundle is a gap", (got or "").startswith("no result bundle at"), True)
        bundle = pathlib.Path(tmp) / "b.xcresult"
        bundle.mkdir()

        class Proc:
            def __init__(self, rc, out, err=""):
                self.returncode, self.stdout, self.stderr = rc, out, err
        for name, proc, want in [("16 xcresulttool failing", Proc(65, "", "bad bundle"), "xcresulttool exited 65: bad bundle"),
                                 ("17 malformed xcresulttool JSON", Proc(0, "{"), "malformed JSON")]:
            try:
                extract(bundle, runner=lambda *a, **k: proc)
                got = ""
            except Gap as gap:
                got = str(gap)
            expect(f"{name} is a gap", want in got, True)
        def no_tool(*a, **k):
            raise FileNotFoundError(2, "No such file or directory", "xcrun")
        import contextlib, io
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            doc = record(meta, lambda: extract(bundle, runner=no_tool))
        expect("17b a tool that cannot launch is a gap, with no identities and no traceback",
               (doc["evidence"], doc["identities"], doc["counts"], doc["gap"].startswith("could not launch xcresulttool"),
                "Traceback" in err.getvalue()), ("gap", [], {}, True, False))
        calls = []
        extract(bundle, runner=lambda argv, **k: calls.append(argv) or Proc(0, "{}"))
        expect("18 the extraction command", calls, [["xcrun", "xcresulttool", "get", "test-results", "tests",
                                                     "--path", str(bundle)]])

        out = pathlib.Path(tmp) / "nested" / "ids.json"
        code = main(["--from-json", str(here / "failed-run.json"), "--job", "build-and-test", "--run", "7",
                     "--attempt", "2", "--sha", "a" * 40, "--lane-outcome", "failure", "--out", str(out)])
        written = json.loads(out.read_text())
        expect("19 the CLI writes the document", (code, written["evidence"], written["schema"], len(written["identities"])),
               (0, "complete", 1, 9))
        for name, argv in [("20 a short sha", ["--sha", "abc"]), ("21 an unknown lane outcome", ["--lane-outcome", "ok"]),
                           ("22 attempt 0", ["--attempt", "0"]), ("23 a job name with a slash", ["--job", "a/b"])]:
            args = {"--job": "build-and-test", "--run": "7", "--attempt": "2", "--sha": "a" * 40,
                    "--lane-outcome": "failure", **dict(zip(argv[::2], argv[1::2]))}
            stray = pathlib.Path(tmp) / f"stray{cases}.json"
            code = main(["--from-json", str(here / "failed-run.json"), *[x for kv in args.items() for x in kv],
                         "--out", str(stray)])
            expect(f"{name} is refused and writes nothing", (code, stray.exists()), (2, False))

    print(f"self-test: {cases} cases, {len(failures)} failure(s)")
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--self-test", action="store_true")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--bundle", type=pathlib.Path)
    source.add_argument("--from-json", type=pathlib.Path, help="already extracted JSON (tests and replays)")
    for flag in ("--job", "--sha", "--lane-outcome", "--out"):
        parser.add_argument(flag)
    parser.add_argument("--run", type=int)
    parser.add_argument("--attempt", type=int)
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if (args.bundle is None) == (args.from_json is None) or None in (args.job, args.sha, args.lane_outcome,
                                                                      args.out, args.run, args.attempt):
        print("test-identities: need --bundle or --from-json, and --job --run --attempt --sha "
              "--lane-outcome --out", file=sys.stderr)
        return 2
    try:
        meta = _meta(args)
    except ValueError as error:
        print(f"test-identities: {error}", file=sys.stderr)
        return 2
    meta["xcode_build"] = xcode_build() if args.bundle else None

    def load():
        if args.bundle is not None:
            return extract(args.bundle)
        try:
            return json.loads(args.from_json.read_text())
        except (OSError, ValueError) as error:
            raise Gap(f"cannot read {args.from_json}: {error}") from error

    doc = record(meta, load)
    try:
        write(doc, args.out)
    except OSError as error:
        print(f"test-identities: cannot write {args.out}: {error}", file=sys.stderr)
        return 2
    summary = doc["gap"] if doc["evidence"] == "gap" else ", ".join(f"{k} {v}" for k, v in sorted(doc["counts"].items()))
    print(f"test-identities: {doc['evidence']} ({summary}) -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
