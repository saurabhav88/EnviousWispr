#!/usr/bin/env python3
"""Report a failed Nightly Battery run: one Discord line, one tracking issue (#3013).

Runs from nightly-battery.yml's `report` job on schedule/dispatch failures only,
never on a pull request (the workflow gates that; this script does not carry the
gate because a gate that lives in two places lives in neither).

Delivery contract, same as scripts/ci/check-alerting-heartbeat.py: `post_discord`
is IMPORTED from there, so the payload shape (`{"content": …}`, urllib) has one
owner. A failed delivery is printed and does not mask the verdict: the workflow
is already red, this only says so where the founder reads.

Issue tracking: one open issue labelled `ci-nightly`. If it exists, comment; else
create. scripts/ci/issue_upsert.py owns that call (comment_or_create_open), shared with
the per-test failure recorder. Needs `issues: write` on the job token and `gh` on PATH
(ubuntu-latest).

Usage:
  notify-nightly.py --result <failure|cancelled|timed_out> --run-url <url> --repo <owner/name>
  notify-nightly.py --self-test
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
from functools import partial
from urllib.request import urlopen

LABEL = "ci-nightly"


def _load_upsert():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("issue_upsert", os.path.join(here, "issue_upsert.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


upsert = _load_upsert()


def _load_poster():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "check_alerting_heartbeat", os.path.join(here, "check-alerting-heartbeat.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod.post_discord


def message(result: str, run_url: str) -> str:
    return (f"Nightly battery did not pass ({result}). Coverage, the full Debug and Release "
            f"suites, or the Debug-only inventory check needs a look: {run_url}")


def track_issue(repo: str, body: str, runner=subprocess.run) -> str:
    """Comment on the newest open ci-nightly issue, or create it. Returns 'commented' | 'created'."""
    return upsert.comment_or_create_open(upsert.Store(repo, runner=runner), LABEL, "CI: nightly battery failing",
                                         body, [LABEL, "bug", "P2-medium"])


def self_test() -> int:
    fails = 0
    gh = upsert.FakeGitHub()
    gh.add(42, "open", labels=[LABEL])
    got = track_issue("o/r", "body", runner=gh)
    ok = got == "commented" and gh.comments[42] == ["body"]
    print(("ok   " if ok else "FAIL ") + "[open issue -> comment on it]"); fails += 0 if ok else 1
    gh = upsert.FakeGitHub()
    gh.add(7, "closed", state="closed", labels=[LABEL])
    got = track_issue("o/r", "body", runner=gh)
    made = gh.issues.get(8, {})
    ok = (got == "created" and made.get("title") == "CI: nightly battery failing" and made.get("body") == "body"
          and [l["name"] for l in made.get("labels", [])] == [LABEL, "bug", "P2-medium"] and gh.comments[7] == [])
    print(("ok   " if ok else "FAIL ") + "[no open issue -> create one with the labels; a closed one is ignored]"); fails += 0 if ok else 1
    gh = upsert.FakeGitHub()
    gh.fail["GET issues"] = (1, "HTTP 403")
    try:
        track_issue("o/r", "body", runner=gh)
        ok = False
    except upsert.ApiError:
        ok = True
    print(("ok   " if ok else "FAIL ") + "[an API failure raises upsert.ApiError]"); fails += 0 if ok else 1
    m = message("failure", "https://x/runs/1")
    ok = "failure" in m and "https://x/runs/1" in m and len(m) < 2000
    print(("ok   " if ok else "FAIL ") + "[message names the result and the run, under the Discord limit]"); fails += 0 if ok else 1
    ok = callable(_load_poster())
    print(("ok   " if ok else "FAIL ") + "[poster imported from check-alerting-heartbeat.py]"); fails += 0 if ok else 1
    print("== notify-nightly self-test PASS ==" if not fails else f"== notify-nightly self-test FAIL ({fails}) ==")
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser()
    ap.add_argument("--result", required=True)
    ap.add_argument("--run-url", required=True)
    ap.add_argument("--repo", required=True)
    a = ap.parse_args(argv[1:])
    text = message(a.result, a.run_url)
    rc = 0
    webhook = os.environ.get("DISCORD_WEBHOOK_URL", "")
    if not webhook:
        print("DISCORD DELIVERY FAILED: DISCORD_WEBHOOK_URL is unset", file=sys.stderr); rc = 1
    else:
        try:
            # A webhook that accepts the connection and never answers would
            # otherwise eat the whole job timeout before issue tracking runs.
            status = _load_poster()(webhook, text, opener=partial(urlopen, timeout=30))
            print(f"==> Discord delivery status {status}")
        except Exception as exc:  # noqa: BLE001 - delivery failure is reported, never hidden
            print(f"DISCORD DELIVERY FAILED: {exc}", file=sys.stderr); rc = 1
    try:
        print(f"==> issue {track_issue(a.repo, text)}")
    except upsert.ApiError as exc:
        print(f"ISSUE TRACKING FAILED: {exc}", file=sys.stderr); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
