#!/usr/bin/env python3
"""The one owner of "comment on the tracking issue, or create it" for CI scripts (#3524 PR 4).

Callers:
  scripts/ci/notify-nightly.py      comment_or_create_open(): the newest OPEN issue with a label
  scripts/ci/record-test-failures.py upsert_event(): one issue per marker key, every event once

Every call goes through `gh api` with the job token (GH_TOKEN), reads every page
(`--paginate --slurp`), and sends bodies as JSON on stdin, so no body text is ever a
command-line argument. Pull requests that the issues endpoint also returns are ignored.

Exactly-once is NOT promised by this file alone: list-then-create is not atomic. The callers'
workflows serialise writers with one concurrency group, and upsert_event() is idempotent by
its event marker, so a replay after a lost or uncertain write adds nothing. A failed call
raises ApiError and leaves nothing half-recorded that a replay cannot finish.

Usage: issue_upsert.py --self-test
"""

from __future__ import annotations

import json
import subprocess
import sys


class ApiError(Exception):
    """A gh api call failed; the message carries its exit status and stderr."""


def key_marker(key):
    return f"<!-- ci-test-key: {key} -->"


def event_marker(event):
    return f"<!-- ci-event: {event} -->"


def _body(row, what):
    """A row's body: present, and a string or null (null reads as empty)."""
    if "body" not in row or not (row["body"] is None or isinstance(row["body"], str)):
        raise ApiError(f"{what} has no valid body")
    return row["body"] or ""


class Store:
    """GitHub issues of one repository, through `gh api`."""

    def __init__(self, repo, runner=subprocess.run):
        self.repo, self.runner = repo, runner

    def _api(self, *args, payload=None):
        try:
            proc = self.runner(["gh", "api", *args], input=None if payload is None else json.dumps(payload),
                               capture_output=True, text=True)
        except OSError as error:
            raise ApiError(f"could not launch gh: {error}") from error
        if proc.returncode != 0:
            raise ApiError(f"gh api {' '.join(args[:3])} exited {proc.returncode}: {(proc.stderr or '').strip()[:300]}")
        try:
            return json.loads(proc.stdout) if (proc.stdout or "").strip() else None
        except ValueError as error:
            raise ApiError(f"gh api {' '.join(args[:3])} printed malformed JSON: {error}") from error

    def _pages(self, path):
        pages = self._api("--paginate", "--slurp", path)
        if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
            raise ApiError(f"{path}: expected a list of pages")
        rows = [item for page in pages for item in page]
        if any(not isinstance(item, dict) for item in rows):
            raise ApiError(f"{path}: a row is not an object")
        return rows

    def issues(self, label, state="all"):
        """Every issue (not pull request) with label, newest first."""
        rows = self._pages(f"repos/{self.repo}/issues?labels={label}&state={state}&per_page=100"
                           "&sort=created&direction=desc")
        for row in rows:
            number, state = row.get("number"), row.get("state")
            if type(number) is not int or number < 1:
                raise ApiError(f"issue row with invalid number {number!r}")
            if state not in ("open", "closed"):
                raise ApiError(f"issue #{number} has invalid state {state!r}")
            _body(row, f"issue #{number}")
        return [row for row in rows if "pull_request" not in row]

    def comments(self, number):
        return [_body(row, f"a comment on #{number}") for row in
                self._pages(f"repos/{self.repo}/issues/{number}/comments?per_page=100")]

    def create(self, title, body, labels):
        made = self._api("-X", "POST", f"repos/{self.repo}/issues", "--input", "-",
                         payload={"title": title, "body": body, "labels": list(labels)})
        if not isinstance(made, dict) or type(made.get("number")) is not int or made["number"] < 1:
            raise ApiError("issue create returned no valid number")
        return made["number"]

    def comment(self, number, body):
        self._api("-X", "POST", f"repos/{self.repo}/issues/{number}/comments", "--input", "-", payload={"body": body})

    def update(self, number, **fields):
        self._api("-X", "PATCH", f"repos/{self.repo}/issues/{number}", "--input", "-", payload=fields)


def comment_or_create_open(store, label, title, body, labels):
    """Comment on the newest OPEN issue with label, or create one. Returns 'commented' | 'created'."""
    open_issues = store.issues(label, state="open")
    if open_issues:
        store.comment(open_issues[0]["number"], body)
        return "commented"
    store.create(title, body, labels)
    return "created"


def upsert_event(store, label, key, event, title, body, labels):
    """Record one event for one key: the issue whose body carries key_marker(key) (lowest number
    if a race made two), reopened when closed; skipped when event_marker(event) is already in its
    body or any comment. Returns (outcome, number): outcome is 'created', 'commented', 'reopened'
    or 'duplicate'."""
    marker, stamp = key_marker(key), event_marker(event)
    text = f"{body}\n\n{stamp}"
    matches = sorted((row for row in store.issues(label) if marker in (row.get("body") or "")),
                     key=lambda row: row["number"])
    if not matches:
        number = store.create(title, f"{marker}\n{text}", labels)
        return "created", number
    issue = matches[0]
    number = issue["number"]
    # A race twin may already carry this event: check every matching issue before writing.
    for matched in matches:
        if stamp in (matched.get("body") or "") or any(stamp in c for c in store.comments(matched["number"])):
            return "duplicate", number
    reopened = issue.get("state") == "closed"
    if reopened:
        store.update(number, state="open")
    store.comment(number, text)
    return ("reopened" if reopened else "commented"), number


class FakeGitHub:
    """An in-memory issues API answering the exact `gh api` calls Store makes (tests only)."""

    def __init__(self, page_size=2):
        self.issues, self.comments, self.calls, self.page_size = {}, {}, [], page_size
        self.fail = {}  # call kind -> (returncode, stderr), consumed once
        self.lose_response = set()  # call kinds whose write lands but whose answer is lost

    def add(self, number, body="", state="open", labels=(), pull_request=False):
        self.issues[number] = {"number": number, "body": body, "state": state, "title": f"#{number}",
                               "labels": [{"name": n} for n in labels]}
        if pull_request:
            self.issues[number]["pull_request"] = {}
        self.comments.setdefault(number, [])

    def __call__(self, argv, input=None, **_):
        class Proc:
            def __init__(self, rc=0, out="", err=""):
                self.returncode, self.stdout, self.stderr = rc, out, err
        assert argv[:2] == ["gh", "api"], argv
        args = argv[2:]
        self.calls.append(args)
        method = args[1] if args[0] == "-X" else "GET"
        path = next(a for a in args if a.startswith("repos/"))
        route = path.split("?")[0].split("/")[3:]
        kind = f"{method} {'/'.join('N' if p.isdigit() else p for p in route)}"
        if kind in self.fail:
            rc, err = self.fail.pop(kind)
            return Proc(rc, "", err)
        payload = json.loads(input) if input else {}
        if method == "GET":
            query = dict(part.split("=", 1) for part in path.split("?", 1)[1].split("&"))
            if route == ["issues"]:
                rows = [i for i in sorted(self.issues.values(), key=lambda i: -i["number"])
                        if any(l["name"] == query["labels"] for l in i["labels"])
                        and query["state"] in ("all", i["state"])]
            else:
                rows = [{"body": b} for b in self.comments[int(route[1])]]
            pages = [rows[i:i + self.page_size] for i in range(0, len(rows), self.page_size)] or [[]]
            return Proc(0, json.dumps(pages))
        if kind == "POST issues":
            number = max(self.issues, default=0) + 1
            self.add(number, payload["body"], labels=payload["labels"])
            self.issues[number]["title"] = payload["title"]
            out = {"number": number}
        elif kind == "POST issues/N/comments":
            self.comments[int(route[1])].append(payload["body"])
            out = {}
        elif kind == "PATCH issues/N":
            issue = self.issues[int(route[1])]
            if "state" in payload:
                issue["state"] = payload["state"]
            if "labels" in payload:
                issue["labels"] = [{"name": n} for n in payload["labels"]]
            out = {}
        else:
            raise AssertionError(f"unexpected call {kind}")
        if kind in self.lose_response:
            self.lose_response.discard(kind)
            return Proc(1, "", "HTTP 502: Bad Gateway")
        return Proc(0, json.dumps(out))


def self_test():
    failures, cases = [], 0

    def expect(name, got, want):
        nonlocal cases
        cases += 1
        ok = got == want
        print(f"{'ok  ' if ok else 'FAIL'} [{name}]" + ("" if ok else f" expected {want!r}, got {got!r}"))
        if not ok:
            failures.append(name)

    def raises(fn):
        try:
            fn()
        except ApiError as error:
            return str(error)
        return None

    gh = FakeGitHub()
    store = Store("o/r", runner=gh)
    expect("1 no open issue: created with the labels",
           (comment_or_create_open(store, "ci-nightly", "T", "b1", ["ci-nightly", "bug"]),
            gh.issues[1]["title"], [l["name"] for l in gh.issues[1]["labels"]]), ("created", "T", ["ci-nightly", "bug"]))
    gh.add(5, "old", state="closed", labels=["ci-nightly"])
    expect("2 an open issue: commented, a closed one ignored",
           (comment_or_create_open(store, "ci-nightly", "T", "b2", ["ci-nightly"]), gh.comments[1], gh.comments[5]),
           ("commented", ["b2"], []))
    gh.add(9, "newer", labels=["ci-nightly"])
    comment_or_create_open(store, "ci-nightly", "T", "b3", ["ci-nightly"])
    expect("3 the NEWEST open issue gets the comment", (gh.comments[9], gh.comments[1]), (["b3"], ["b2"]))
    expect("4 bodies go on stdin, never on the command line (create and comment)",
           [a for call in gh.calls for a in call if any(b in a for b in ("b1", "b2", "b3"))], [])

    gh = FakeGitHub(page_size=2)
    store = Store("o/r", runner=gh)
    for n in range(1, 6):
        gh.add(n, f"issue {n}", labels=["ci-test-failure"])
    gh.add(6, "a pull request", labels=["ci-test-failure"], pull_request=True)
    out = upsert_event(store, "ci-test-failure", "test://k", "1/1/job/test://k", "Test fails: k", "first", ["ci-test-failure"])
    expect("5 a new key: created with both markers", (out, key_marker("test://k") in gh.issues[7]["body"],
                                                      event_marker("1/1/job/test://k") in gh.issues[7]["body"]),
           (("created", 7), True, True))
    for n in range(8, 12):
        gh.add(n, f"filler {n}", labels=["ci-test-failure"])
    out = upsert_event(store, "ci-test-failure", "test://k", "2/1/job/test://k", "Test fails: k", "second", ["ci-test-failure"])
    expect("6 the key found past the first page: commented with the event marker",
           (out, len(gh.comments[7]), event_marker("2/1/job/test://k") in gh.comments[7][0]), (("commented", 7), 1, True))
    out = upsert_event(store, "ci-test-failure", "test://k", "2/1/job/test://k", "Test fails: k", "again", ["ci-test-failure"])
    expect("7 the same event again: duplicate, nothing written", (out, len(gh.comments[7])), (("duplicate", 7), 1))
    out = upsert_event(store, "ci-test-failure", "test://k", "1/1/job/test://k", "Test fails: k", "again", ["ci-test-failure"])
    expect("8 the creating event, replayed: duplicate (its marker is in the body)", out, ("duplicate", 7))
    for n in range(3):
        gh.comments[7].insert(0, f"other comment {n}")
    out = upsert_event(store, "ci-test-failure", "test://k", "2/1/job/test://k", "Test fails: k", "again", ["ci-test-failure"])
    expect("9 an event marker on a later comments page: duplicate", out, ("duplicate", 7))
    gh.issues[7]["state"] = "closed"
    out = upsert_event(store, "ci-test-failure", "test://k", "3/1/job/test://k", "Test fails: k", "third", ["ci-test-failure"])
    expect("10 a closed issue failing again: reopened and commented", (out, gh.issues[7]["state"]), (("reopened", 7), "open"))
    gh.add(20, key_marker("test://k") + "\nrace twin", labels=["ci-test-failure"])
    out = upsert_event(store, "ci-test-failure", "test://k", "4/1/job/test://k", "Test fails: k", "fourth", ["ci-test-failure"])
    expect("11 two issues for one key (a race): the lowest number is used", out, ("commented", 7))
    gh.add(30, key_marker("test://other") + " in a pull request", labels=["ci-test-failure"], pull_request=True)
    out = upsert_event(store, "ci-test-failure", "test://other", "1/1/job/test://other", "T", "x", ["ci-test-failure"])
    expect("12 a pull request carrying the marker is not an issue", out[0], "created")

    gh = FakeGitHub()
    store = Store("o/r", runner=gh)
    gh.fail["GET issues"] = (1, "HTTP 403: Resource not accessible by integration")
    expect("13 a 403 on listing raises ApiError and writes nothing",
           (bool(raises(lambda: upsert_event(store, "L", "k", "e", "T", "b", ["L"]))), gh.issues), (True, {}))
    gh.lose_response.add("POST issues")
    lost = raises(lambda: upsert_event(store, "L", "k", "e1", "T", "b", ["L"]))
    out = upsert_event(store, "L", "k", "e1", "T", "b", ["L"])
    expect("14 a create whose answer was lost: the replay finds it, nothing doubled",
           (bool(lost), out, len(gh.issues), gh.comments[1]), (True, ("duplicate", 1), 1, []))
    gh.lose_response.add("POST issues/N/comments")
    lost = raises(lambda: upsert_event(store, "L", "k", "e2", "T", "b", ["L"]))
    out = upsert_event(store, "L", "k", "e2", "T", "b", ["L"])
    expect("15 a comment whose answer was lost: the replay finds it", (bool(lost), out, len(gh.comments[1])),
           (True, ("duplicate", 1), 1))
    gh.fail["POST issues/N/comments"] = (1, "HTTP 500")
    expect("16 a failed comment raises", bool(raises(lambda: upsert_event(store, "L", "k", "e3", "T", "b", ["L"]))), True)
    gh.issues[1]["state"] = "closed"
    gh.fail["POST issues/N/comments"] = (1, "HTTP 500")
    failed = raises(lambda: upsert_event(store, "L", "k", "e4", "T", "b", ["L"]))
    out = upsert_event(store, "L", "k", "e4", "T", "b", ["L"])
    expect("17 reopened but the comment failed: the replay comments once", (bool(failed), out[0], len(gh.comments[1])),
           (True, "commented", 2))

    class Bad:
        returncode, stdout, stderr = 0, "{not json", ""
    expect("18 malformed gh output raises", "malformed JSON" in (raises(lambda: Store("o/r", runner=lambda *a, **k: Bad()).issues("L")) or ""), True)

    def canned(pages_by_kind):
        class Proc:
            def __init__(self, out):
                self.returncode, self.stdout, self.stderr = 0, out, ""
        writes = []

        def run(argv, **_):
            if "-X" in argv:
                writes.append(argv)
                return Proc('{"number": 1}')
            path = next(a for a in argv if a.startswith("repos/"))
            kind = "comments" if "/comments" in path else "issues"
            return Proc(json.dumps(pages_by_kind[kind]))
        return run, writes

    marked = {"number": 3, "state": "open", "body": key_marker("k")}
    for name, issues_pages, comment_pages in [
        ("20 a null row", [[None]], [[]]),
        ("21 a bool issue number", [[{**marked, "number": True}]], [[]]),
        ("22 a zero issue number", [[{**marked, "number": 0}]], [[]]),
        ("23 an unknown state", [[{**marked, "state": "locked"}]], [[]]),
        ("24 an issue without a body field", [[{"number": 3, "state": "open"}]], [[]]),
        ("25 a list-valued body", [[{**marked, "body": ["x"]}]], [[]]),
        ("26 a malformed comment row", [[marked]], [[{"body": 5}]]),
        ("27 a page that is not a list", [{"number": 3}], [[]]),
    ]:
        run, writes = canned({"issues": issues_pages, "comments": comment_pages})
        err = raises(lambda: upsert_event(Store("o/r", runner=run), "L", "k", "e", "T", "b", ["L"]))
        expect(f"{name}: ApiError and zero writes", (bool(err), writes), (True, []))
    run, writes = canned({"issues": [[], []], "comments": [[]]})
    expect("28 genuinely empty pages still create", upsert_event(Store("o/r", runner=run), "L", "k", "e", "T", "b", ["L"])[0],
           "created")
    run, writes = canned({"issues": [[{**marked, "body": None}]], "comments": [[]]})
    expect("29 a null body reads as empty: no marker, so created", upsert_event(Store("o/r", runner=run), "L", "k", "e", "T",
                                                                              "b", ["L"])[0], "created")
    for name, bad in [("30 create answering a bool number", {"number": True}), ("31 create answering 0", {"number": 0})]:
        class P:
            returncode, stderr = 0, ""
            stdout = json.dumps(bad)
        expect(f"{name} raises", "no valid number" in (raises(lambda: Store("o/r", runner=lambda *a, **k: P()).create("T", "b", [])) or ""), True)

    gh = FakeGitHub(page_size=2)
    store = Store("o/r", runner=gh)
    gh.add(1, key_marker("k"), labels=["L"])
    gh.add(2, key_marker("k") + "\n" + event_marker("e-body"), labels=["L"], state="closed")
    gh.add(3, "unrelated", labels=["L"])
    gh.comments[2] = ["x", "y", "z " + event_marker("e-comment")]
    calls_before = len(gh.calls)
    out_body = upsert_event(store, "L", "k", "e-body", "T", "b", ["L"])
    out_comment = upsert_event(store, "L", "k", "e-comment", "T", "b", ["L"])
    writes = [c for c in gh.calls[calls_before:] if c[0] == "-X"]
    expect("32 an event already on the race twin (body, or a later comments page): duplicate, no write",
           (out_body, out_comment, writes, gh.issues[2]["state"], gh.comments[1]),
           (("duplicate", 1), ("duplicate", 1), [], "closed", []))
    out = upsert_event(store, "L", "k", "e-new", "T", "new", ["L"])
    expect("33 a new event still goes to the lowest-numbered twin", (out, len(gh.comments[1]), len(gh.comments[2])),
           (("commented", 1), 1, 3))

    def no_gh(*a, **k):
        raise FileNotFoundError(2, "No such file or directory", "gh")
    expect("19 a missing gh raises ApiError", "could not launch gh" in (raises(lambda: Store("o/r", runner=no_gh).issues("L")) or ""), True)

    print(f"self-test: {cases} cases, {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    print("usage: issue_upsert.py --self-test (library; import it)", file=sys.stderr)
    sys.exit(2)
