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
create. Needs `issues: write` on the job token and `gh` on PATH (ubuntu-latest).

Usage:
  notify-nightly.py --result <failure|cancelled|timed_out> --run-url <url> --repo <owner/name>
  notify-nightly.py --self-test
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from functools import partial
from urllib.request import urlopen

LABEL = "ci-nightly"


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
    """Comment on the open ci-nightly issue, or create it. Returns 'commented' | 'created'."""
    listed = runner(["gh", "issue", "list", "-R", repo, "--label", LABEL, "--state", "open",
                     "--json", "number", "--limit", "1"], check=True, capture_output=True, text=True)
    numbers = [row["number"] for row in json.loads(listed.stdout or "[]")]
    if numbers:
        runner(["gh", "issue", "comment", "-R", repo, str(numbers[0]), "--body", body],
               check=True, capture_output=True, text=True)
        return "commented"
    runner(["gh", "issue", "create", "-R", repo, "--label", LABEL, "--label", "bug", "--label", "P2-medium",
            "--title", "CI: nightly battery failing", "--body", body],
           check=True, capture_output=True, text=True)
    return "created"


def self_test() -> int:
    fails = 0
    calls: list[list[str]] = []

    class R:
        def __init__(self, stdout): self.stdout = stdout

    def fake_runner(argv, **_):
        calls.append(argv)
        if argv[:3] == ["gh", "issue", "list"]:
            return R(json.dumps([{"number": 42}]) if fake_runner.open_issue else "[]")
        return R("")

    fake_runner.open_issue = True
    got = track_issue("o/r", "body", runner=fake_runner)
    ok = got == "commented" and calls[-1][:4] == ["gh", "issue", "comment", "-R"] and "42" in calls[-1]
    print(("ok   " if ok else "FAIL ") + "[open issue -> comment on it]"); fails += 0 if ok else 1
    calls.clear(); fake_runner.open_issue = False
    got = track_issue("o/r", "body", runner=fake_runner)
    ok = got == "created" and calls[-1][:4] == ["gh", "issue", "create", "-R"] and LABEL in calls[-1]
    print(("ok   " if ok else "FAIL ") + "[no open issue -> create one with the label]"); fails += 0 if ok else 1
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
    except subprocess.CalledProcessError as exc:
        print(f"ISSUE TRACKING FAILED: {exc.stderr or exc}", file=sys.stderr); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
