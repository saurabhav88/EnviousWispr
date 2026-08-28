#!/usr/bin/env python3
"""Is the Sentry -> Discord notifier still being fed?

WHY THIS EXISTS. On 2026-08-16 Sentry stopped firing the integration webhook that
drives `workers/sentry-triage`, and nobody noticed for 12 days (#2486). At least 13
new problem groups were created in that window. Nothing was broken in a way anyone
could see: the Worker was healthy, Discord was healthy, and the only symptom was an
absence. **A dead notifier and a quiet week produce the identical observation**, so
no dashboard anyone was already reading could have caught it.

WHAT IT WATCHES, AND WHY FROM OUT HERE. GitHub Actions, not a Cloudflare cron: a
watchdog living inside the system it watches dies with it, and the CF account is at
its 5-cron free-plan limit anyway (#1092). The signal is Cloudflare's own count of
invocations of the notifier Worker, which is the last thing in the chain we can see
from outside Sentry.

WHAT IT CANNOT WATCH, stated so nobody reads more into a green run than it carries:
Sentry's own delivery log is UI-only for us (`/sentry-apps/<slug>/requests/` 404s
even with `sentry-master-key`, measured 2026-08-28), so this cannot distinguish
"Sentry sent nothing" from "Sentry sent something that never arrived". It answers
one question — has ANYTHING reached the notifier lately — and that is the question
whose "no" went unnoticed for 12 days.

**AND "ANYTHING" IS LITERAL: ANY HTTP REQUEST REFRESHES THIS, INCLUDING A REFUSED
ONE.** `workersInvocationsAdaptive` counts invocations, not authenticated webhooks,
and the Worker's URL is public. Demonstrated rather than theorised: on the very day
this was written the check reported "last ran 0 days ago" against an alerting path
that had been dead for twelve, because the diagnosis of #2486 had itself curled the
endpoint that afternoon. So a green run means "something reached it", never "Sentry
delivered". The outage window is unaffected — Cloudflare recorded a true zero across
Aug 17-28 because nobody was poking it — but a future outage accompanied by any
traffic at all would hide behind this.

The sharp version needs the Worker to record a heartbeat only after a VERIFIED
signature, in the KV namespace it already binds, and this check to read that key
instead. That is a Worker change plus a deploy; it is deliberately NOT bundled here,
so the coarse net can land while the deploy is blocked. Follow-up on #2486.

THRESHOLD, and why it is not tighter. Healthy traffic is bursty, not steady: the
real invocation dates before the outage were Aug 6, 8, 14, 16, a natural gap of six
days. A threshold under that cries wolf, and a guard that cries wolf gets ignored,
which is the failure mode this is supposed to prevent. Seven days is a coarse net
whose only job is to catch a SUSTAINED silence. It would have caught #2486 on Aug 23
rather than Aug 28.

FAIL CLOSED, THREE WAYS. A measurement authority that cannot measure must never
render as a number (validation-discipline.md RULE:
measure-with-the-real-tool-never-a-simulation). Cloudflare has three distinct ways to
answer badly and #1589 was caused by conflating them: a non-2xx, a GraphQL `errors`
array on a 200, and a well-formed response for a script that does not exist. Each
exits UNKNOWN here, which is loud and is NOT reported as "your alerting is broken" —
claiming an outage we did not observe is its own kind of wrong.

ZERO ROWS IS THE ALARM, NOT THE QUIET CASE. An empty result means the Worker has not
run in the whole window, or has been renamed out from under this check. Both are
states somebody must look at, and both are exactly what "no news" looks like if the
empty case is allowed to pass.
"""
import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

CF_GRAPHQL = "https://api.cloudflare.com/client/v4/graphql"
DEFAULT_SCRIPT = "enviouswispr-sentry-triage"
DEFAULT_THRESHOLD_DAYS = 7
LOOKBACK_DAYS = 30

# Exit codes. Distinct on purpose: the caller must be able to tell "the notifier is
# stale" from "this check could not run", because only the first is a claim about
# production.
EXIT_FRESH = 0
EXIT_STALE = 1
EXIT_UNKNOWN = 2

QUERY = """
query($acct:String!,$since:Time!,$until:Time!){
  viewer { accounts(filter:{accountTag:$acct}) {
    workersInvocationsAdaptive(limit:1000, filter:{datetime_geq:$since, datetime_leq:$until}) {
      sum { requests }
      dimensions { scriptName date }
    }
  } }
}
"""


class Unknown(Exception):
    """The check could not be performed. Never conflate with a stale verdict."""


def _utc_now():
    return dt.datetime.now(dt.timezone.utc)


def fetch_rows(account_id, api_key, email, *, now=None, opener=None):
    """Return the raw workersInvocationsAdaptive rows, or raise Unknown."""
    now = now or _utc_now()
    since = (now - dt.timedelta(days=LOOKBACK_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    until = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = json.dumps(
        {"query": QUERY, "variables": {"acct": account_id, "since": since, "until": until}}
    ).encode()
    req = urllib.request.Request(
        CF_GRAPHQL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "X-Auth-Email": email,
            "X-Auth-Key": api_key,
        },
    )
    try:
        raw = (opener or urllib.request.urlopen)(req).read()
    except urllib.error.HTTPError as exc:  # producer 1: non-2xx
        raise Unknown(f"Cloudflare returned HTTP {exc.code}") from exc
    except Exception as exc:  # network, DNS, TLS
        raise Unknown(f"Cloudflare request failed: {exc}") from exc

    try:
        body = json.loads(raw)
    except ValueError as exc:
        raise Unknown("Cloudflare response was not JSON") from exc

    # Producer 2: a 200 carrying a GraphQL errors array. Silently rendering this as
    # zero rows is exactly how a broken query became "0" in #1589.
    if body.get("errors"):
        raise Unknown(f"Cloudflare GraphQL errors: {json.dumps(body['errors'])[:300]}")

    try:
        accounts = body["data"]["viewer"]["accounts"]
    except (KeyError, TypeError) as exc:
        raise Unknown("Cloudflare response missing data.viewer.accounts") from exc
    if not accounts:  # producer 3: the account filter matched nothing
        raise Unknown("Cloudflare returned no account for the given account id")

    rows = accounts[0].get("workersInvocationsAdaptive")
    if rows is None:
        raise Unknown("Cloudflare response missing workersInvocationsAdaptive")
    return rows


def last_invocation_date(rows, script_name):
    """Latest YYYY-MM-DD on which `script_name` ran, or None if it never did.

    None is a REAL answer here and the caller must treat it as the alarm, not as a
    missing value to skip over.
    """
    dates = [
        r["dimensions"]["date"]
        for r in rows
        if r.get("dimensions", {}).get("scriptName") == script_name
        and (r.get("sum", {}) or {}).get("requests", 0) > 0
    ]
    return max(dates) if dates else None


def days_since(date_str, now=None):
    now = now or _utc_now()
    seen = dt.datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
    return (now.date() - seen.date()).days


def verdict(rows, script_name, threshold_days, now=None):
    """(exit_code, message). The only place staleness is decided."""
    last = last_invocation_date(rows, script_name)
    if last is None:
        return (
            EXIT_STALE,
            f"The Sentry alerter has not run once in the last {LOOKBACK_DAYS} days. "
            f"Either nothing has reached it at all, or the worker named "
            f"'{script_name}' no longer exists under that name. Someone has to look.",
        )
    age = days_since(last, now=now)
    if age > threshold_days:
        return (
            EXIT_STALE,
            f"The Sentry alerter last ran {age} days ago, on {last}. Anything longer "
            f"than {threshold_days} days means error alerts have probably stopped "
            f"reaching Discord, which is silent by nature and will not announce "
            f"itself. This is what happened for 12 days in August 2026.",
        )
    return (EXIT_FRESH, f"The Sentry alerter last ran {age} day(s) ago, on {last}.")


def post_discord(webhook_url, message, *, opener=None):
    payload = json.dumps({"content": message}).encode()
    req = urllib.request.Request(
        webhook_url, data=payload, headers={"Content-Type": "application/json"}
    )
    resp = (opener or urllib.request.urlopen)(req)
    return getattr(resp, "status", None) or resp.getcode()


def notify_if_stale(code, message, webhook, poster):
    """Post when stale, and return the exit code the caller should use.

    **A FAILED DELIVERY DOES NOT UNMAKE THE VERDICT.** The measurement already
    succeeded and said stale; only the notification failed. Returning UNKNOWN here
    would make the workflow report "could not measure", which is false, and would
    hide a real outage behind a Discord problem.

    `urlopen` RAISES on a non-2xx rather than returning one, so an unguarded call
    exits with a traceback and status 1 — indistinguishable from a clean stale
    verdict, with the message lost. Cloud review, PR for #2486.
    """
    if code != EXIT_STALE:
        return code
    if not webhook:
        print("DISCORD DELIVERY FAILED: DISCORD_WEBHOOK_URL is unset", file=sys.stderr)
        return EXIT_STALE
    try:
        status = poster(webhook, f"Error alerts may have stopped. {message}")
    except Exception as exc:  # transport, DNS, TLS, or a non-2xx raised as HTTPError
        print(f"DISCORD DELIVERY FAILED: {exc}", file=sys.stderr)
        return EXIT_STALE
    print(f"Discord responded {status}")
    if status not in (200, 204):
        print(f"DISCORD DELIVERY FAILED: status {status}", file=sys.stderr)
    return EXIT_STALE


def _self_test():
    """Pure checks over the decision layer. No network."""
    now = dt.datetime(2026, 8, 28, tzinfo=dt.timezone.utc)

    def row(name, date, requests=1):
        return {"sum": {"requests": requests}, "dimensions": {"scriptName": name, "date": date}}

    # The real #2486 data: last run Aug 16, checked on Aug 28.
    rows = [row("enviouswispr-sentry-triage", d) for d in ("2026-08-08", "2026-08-14", "2026-08-16")]
    code, msg = verdict(rows, "enviouswispr-sentry-triage", 7, now=now)
    assert code == EXIT_STALE, "the real outage must trip this guard"
    assert "12 days ago" in msg, msg

    # Two-way control: a healthy path leaves it disarmed.
    code, _ = verdict(rows + [row("enviouswispr-sentry-triage", "2026-08-27")], "x", 7, now=now)
    assert code == EXIT_STALE, "an unknown script name must be loud, not quiet"
    code, msg = verdict(
        [row("enviouswispr-sentry-triage", "2026-08-27")],
        "enviouswispr-sentry-triage", 7, now=now,
    )
    assert code == EXIT_FRESH, msg

    # A six-day gap is NORMAL traffic and must not fire, or the guard cries wolf.
    code, _ = verdict(
        [row("enviouswispr-sentry-triage", "2026-08-22")],
        "enviouswispr-sentry-triage", 7, now=now,
    )
    assert code == EXIT_FRESH, "a 6-day gap is real healthy traffic; firing here would train dismissal"

    # No rows at all is the alarm, never the quiet case.
    code, _ = verdict([], "enviouswispr-sentry-triage", 7, now=now)
    assert code == EXIT_STALE

    # A row with zero requests is not an invocation.
    code, _ = verdict(
        [row("enviouswispr-sentry-triage", "2026-08-27", requests=0)],
        "enviouswispr-sentry-triage", 7, now=now,
    )
    assert code == EXIT_STALE

    # Each Cloudflare failure producer is UNKNOWN, never a number.
    for body in (
        b'{"errors":[{"message":"bad query"}]}',
        b'{"data":{"viewer":{"accounts":[]}}}',
        b"not json",
        b'{"data":{"viewer":{"accounts":[{}]}}}',
    ):
        class _R:
            def __init__(self, b):
                self._b = b

            def read(self):
                return self._b

        try:
            fetch_rows("a", "k", "e", now=now, opener=lambda req, b=body: _R(b))
        except Unknown:
            pass
        else:
            raise AssertionError(f"expected Unknown for {body!r}")

    # A Discord problem must never be able to downgrade a real STALE verdict, and
    # must never be able to upgrade a FRESH one.
    def raiser(*_a, **_k):
        raise urllib.error.HTTPError("u", 500, "boom", None, None)

    assert notify_if_stale(EXIT_STALE, "m", "https://hook", raiser) == EXIT_STALE
    assert notify_if_stale(EXIT_STALE, "m", None, raiser) == EXIT_STALE
    assert notify_if_stale(EXIT_STALE, "m", "https://hook", lambda *_a: 500) == EXIT_STALE
    assert notify_if_stale(EXIT_STALE, "m", "https://hook", lambda *_a: 204) == EXIT_STALE
    posted = []
    assert notify_if_stale(EXIT_FRESH, "m", "https://hook", lambda *a: posted.append(a) or 204) == EXIT_FRESH
    assert posted == [], "a healthy heartbeat must never post"

    print("self-test OK")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script-name", default=DEFAULT_SCRIPT)
    ap.add_argument("--threshold-days", type=int, default=DEFAULT_THRESHOLD_DAYS)
    ap.add_argument("--notify", action="store_true", help="post to Discord when stale")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    missing = [
        n
        for n in ("CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_KEY", "CLOUDFLARE_EMAIL")
        if not os.environ.get(n)
    ]
    if missing:
        print(f"UNKNOWN: missing {', '.join(missing)}", file=sys.stderr)
        return EXIT_UNKNOWN

    try:
        rows = fetch_rows(
            os.environ["CLOUDFLARE_ACCOUNT_ID"],
            os.environ["CLOUDFLARE_API_KEY"],
            os.environ["CLOUDFLARE_EMAIL"],
        )
    except Unknown as exc:
        # Loud, and deliberately NOT a Discord post: we did not observe an outage,
        # we failed to look. Saying otherwise would be a claim we cannot support.
        print(f"UNKNOWN: {exc}", file=sys.stderr)
        return EXIT_UNKNOWN

    code, message = verdict(rows, args.script_name, args.threshold_days)
    print(message)

    if args.notify:
        code = notify_if_stale(
            code, message, os.environ.get("DISCORD_WEBHOOK_URL"), post_discord
        )
    return code


if __name__ == "__main__":
    sys.exit(main())
