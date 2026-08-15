#!/usr/bin/env python3
"""Behavior-aware polish judge — Type B corpus scorer (issue #1199).

Run-on-demand PERSONAL scorer for the gitignored Type B mega-corpus. NOT the CI
gate (`acceptance_gate.py` over `ci_corpus.jsonl` stays the only CI gate, on its
own corpus, untouched). This is a local-lane tool (gitignored under
`scripts/eval/*`), same eval family + same judge plumbing — a new SCORER over a
candidate-output file, not a parallel harness.

Why this exists: the shipped 5-axis grader (run_provider_judge.py / acceptance_
gate.py) scores each candidate vs the RAW transcript on five 0-3 axes. That bar
("better than nothing?") is low, it is not behavior-aware, and it has no
severity. This harness implements the behavior-aware, invariant-first, severity-
graded grading system proposed in the 2026-06-30 corpus review, AND replays the
old 5-axis system verbatim — both over the SAME candidate file with the SAME
judge model — so the two grading systems can be A/B'd with the rubric as the only
variable.

Two grading systems, selected by `--system`:
  new (default) : behavior-aware. Per case -> verdict (pass/minor/soft_fail/
                  major_fail/critical_fail) + severity (S0-S4) + booleans
                  (behavior_correct / meaning_preserved / restraint_correct /
                  clean_output) + failure_types[] + pairwise_vs_production +
                  rationale. Scoreboard: per-behavior pass rate, trap metrics,
                  critical-smoke gate, optional pairwise-vs-production gate.
  old           : the shipped 5-axis system, verbatim. Candidate vs raw baseline,
                  5 integer axes (0-3); pass = accuracy/conciseness/fluency/
                  format each >=2 AND regression >=1; batch PASS at >=90%.
                  Prompt + pass rule copied verbatim from run_provider_judge.py /
                  acceptance_gate.py (cited inline) so the A/B is faithful.

Inputs (both systems):
  --corpus      one or more case files (the per-behavior `*_v1.jsonl`, or the
                consolidated export with `subset`/`tier` tags). Cases keyed by id.
  --candidates  AFM (or any engine) output JSONL: {id, candidate, error?,
                latencyMs?} — exactly what `apple_runner` writes.
  --production  (new only, optional) a second candidate file from the currently
                shipped engine, for pairwise. Absent -> pairwise=not_available.
  --verdicts    (new only, optional) pre-computed per-case verdict JSONL — skip
                the judge and aggregate these (lets a subagent self-judge, then
                this harness does the deterministic roll-up).

Judge backend, selected with --judge / EW_JUDGE. Two funded routes, and nothing else
is permitted: `azure/<deployment>` on the Azure startup credits (the DEFAULT), and
`claude*`/`sonnet*` over the headless Claude CLI (subscription auth, $0 at the margin,
but it spends the weekly budget needed for building). Direct OpenAI and Gemini model ids
are REFUSED, as is any unrecognised id — those bill the founder's own money, which
grading may not do (founder 2026-08-11). Note `claude*` is NOT refused: it reaches the
logged-in CLI rather than a direct Anthropic API-key transport, which is why it
counts as funded. What that CLI contacts is its own business; this module only chooses
how the judge is invoked. Every Claude sandbox flag is copied verbatim from the proven
path (each earned a Codex round — do not change here).

Outputs -> <outdir>/ : per_case.jsonl, summary.json, scoreboard.txt.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import random
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
import urllib.parse
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

# ---------------------------------------------------------------------------
# Judge backend. Default = Azure on the startup credits since 2026-08-11; the
# on-subscription Claude CLI is still supported and is no longer the default, so
# this no longer mirrors acceptance_gate.py, which stays on Sonnet as the CI gate.
# DO NOT alter the Claude sandbox flags; each one earned a Codex round
# (polish-eval.md FACT: bench-judge-is-claude-sonnet, whose sandbox invariants are
# still live even though its judge SELECTION is marked historical).
# ---------------------------------------------------------------------------

CLAUDE_JUDGE_MODEL_ID = "claude-sonnet-5"  # founder decision 2026-07-02, superseded
# below as the DEFAULT but still the id to pass when a run must be comparable to the
# published 1,890-case research run, which it graded
# (runs/prompt-tune-2026-07-01/full1890/*/summary.json "judge": "claude-sonnet-5").

AZURE_JUDGE_DEPLOYMENT_ID = "azure/gpt-5-6-luna"  # founder decision 2026-08-11: the
# DEFAULT judge, on the expiring Azure startup credits. The reason is which scarce
# resource each option burns, not accuracy: the Claude subscription is building
# capacity (~99% used by Thursday) and the Codex plan is adversarial review, while an
# unspent credit is a pure loss. Validated over 12 local arms before the switch —
# 0 of 12 shipped labels moved, delta median 0.0pp, and on the three substantive
# disagreements spot-checked by hand Luna was right all three times. The full comparison
# is recorded on issue #1950; the receipts themselves are local only, which is why the
# durable copy lives there rather than behind a path in this repo.
#
# Judges are NOT interchangeable mid-comparison: re-grade every arm of a comparison
# with one judge rather than reading a new arm against an old baseline. The earlier
# blanket "never mix judge models" was retired by the founder on 2026-08-11 because
# re-benchmarking is routine here, which makes the cheap judge the enabling one.
DEFAULT_JUDGE = os.environ.get("EW_JUDGE", AZURE_JUDGE_DEPLOYMENT_ID)
CLAUDE_JUDGE_MAX_WORKERS = 6            # subprocess per call; cap fan-out. Raised
# from 3 (#1199 speed pass, 2026-06-30), then 20 -> 32 (founder 2026-07-02:
# faster judging: no metered cost on the subscription judge, only a transient
# rate-limit risk that judge_chunk's retry absorbs — JUDGE_CHUNK_ATTEMPTS, 5
# since 2026-08-15; this said "3-attempt" and went stale the moment that moved,
# which is why it now names the constant instead of a number). Lowered back to
# 6 (founder 2026-07-20): 32 concurrent `claude -p` subprocesses (each
# spawning ripgrep) pushed system load average past 40 while other work was
# running on the same machine, echoing the load-234 incident in
# eg1-operations.md. 6 stays well clear of that while judging 1,890 cases in
# roughly 25 minutes.
# Raised 4 -> 12 (founder 2026-08-14: "if it's a cloud grader, why so slow"). The 4 was
# never justified for this transport -- it sat beside the CLAUDE cap's rationale, which is
# about local subprocess load (32 concurrent `claude -p` each spawning ripgrep pushed load
# past 40). An HTTPS request to Azure spawns nothing and costs no local CPU, so that
# reasoning does not transfer and the cap was inherited rather than measured.
#
# The real ceiling is the deployment's rate limit, and exceeding it is SAFE here: Azure
# answers 429, `_retryable_http_error` marks it retryable, and `judge_chunk` retries with
# backoff. So the failure mode of too-high is slower-but-correct, not wrong results --
# which is why this can be raised without risking the grade.
#
# Measured before the change: 1,861 cases = 233 chunks at ~19s per chunk, 4 at a time,
# ~25 min. Override per run with EW_JUDGE_WORKERS to find the deployment's real ceiling
# without editing code.
HTTP_JUDGE_MAX_WORKERS = int(os.environ.get("EW_JUDGE_WORKERS", "12"))
DEFAULT_REPLICATIONS = 2              # old-system judge instability net (no temperature knob on CLI)
DEFAULT_ADJUDICATE_PCT = 0.15          # new-system: fraction of pass/minor/soft_fail
DEFAULT_ADJUDICATE_MIN = 15            # cases re-judged as a calibration sample
REP_PASSRATE_DELTA_MAX = 5.0          # pp; wobble above this flags the run unreliable
DEFAULT_CHUNK_SIZE = 8

# Azure OpenAI data-plane version for the chat-completions route. Pinned rather than
# floating because this route's accepted PARAMETERS are version- and model-dependent,
# and a rejection arrives as a bare HTTP 400 that reads like a broken judge. Measured
# against this deployment on 2026-08-11, both as HTTP 400:
#   "'max_tokens' is not supported with this model. Use 'max_completion_tokens'"
#   "'temperature' does not support 0 with this model. Only the default (1)"
AZURE_API_VERSION = "2024-10-21"

# The model version pinned for THIS process, set by `judge_identity` when it probes the
# deployment. Every grading response is then checked against it, because the probe is a
# time-of-check and each grading call is a time-of-use: Azure can repoint a deployment
# mid-sweep, and receipts written after that would carry the pre-change identity while holding
# post-change scores — one scoreboard silently mixing two judge versions. Cloud review found
# the gap; the check is one comparison on a field the response already carries.
#
# None means "not pinned", which happens only when nothing probed first. `call_azure` then
# cannot verify, so `preflight_judge` pins for every azure run rather than leaving it to the
# caller to remember.
_azure_pinned_model: str | None = None

# The full judge identity THIS process resolved, for a run started directly rather than through
# `judge_ollama_bench.sh`. The receipt records the sweep's `EW_JUDGE_IDENTITY` when there is one
# and this otherwise: a direct run resolves a perfectly good identity in preflight, and reading
# only the environment threw it away, so two direct receipts from different Azure resources
# recorded the same empty provenance and the report could not tell them apart.
_resolved_judge_identity: str | None = None


class MissingSecretError(RuntimeError):
    pass


def _key(name: str) -> str:
    """logical key name -> value. Env var first (get-key launch / CI set these,
    always current), then the cached key file. Mirrors acceptance_gate._key."""
    env_name = name.upper().replace("-", "_")
    if os.environ.get(env_name):
        return os.environ[env_name].strip()
    p = Path(os.path.expanduser(f"~/.enviouswispr-keys/{name}"))
    if not p.exists():
        raise MissingSecretError(f"Missing key file: {p} (and env {env_name} unset)")
    return p.read_text().strip()


class TransientTransportError(Exception):
    """A network failure raised BY the network operation itself.

    Exists to make the retry predicate's scope structural instead of a promise.
    The predicate used to test `OSError`, which is correct for a socket and wrong
    for everything else that can appear in the same `try`: cloud review found
    three separate instances in this change set -- a local WAV write, a
    subprocess spawn for a missing CLI, and a credential file read -- where a
    permanent local failure would have been answered with another paid request.

    Auditing each retry scope for stray I/O is a promise that has to be re-made
    every time someone adds a line. Converting at the ONE place the network is
    touched is a property: anything else in the scope raises its own type and is
    never retried, by construction.
    """

    def __init__(self, cause: Exception):
        super().__init__(f"{type(cause).__name__}: {cause}")
        self.cause = cause


def _http_json(opener, req, timeout: float):
    """Perform the request and decode it, converting ONLY transport failures.

    `HTTPError` is deliberately re-raised untouched: it carries a status code and
    the caller decides 429/5xx-retryable from that. A JSON decode failure is also
    left alone -- a 200 with an unparsable body is the server's answer, and the
    callers that want to retry it already test `json.JSONDecodeError` explicitly.
    """
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError:
        raise
    except (OSError, http.client.HTTPException) as e:
        raise TransientTransportError(e) from None
    return json.loads(raw)


class JudgeUnavailableError(Exception):
    """The judge transport cannot work at all, and no number of attempts changes
    that: a missing or unexecutable CLI, a route with no funded transport.

    Exists because the retry predicate treats every OSError as transport, which
    is right for an HTTP call and wrong for a subprocess spawn — `FileNotFoundError`
    from a missing `claude` binary is an OSError and would otherwise be retried
    once per attempt, per chunk, for the whole corpus.
    """


def _retryable_http_error(exc: Exception) -> bool:
    """True when `exc` is a transient transport failure worth another attempt.

    HTTPError is tested FIRST and is the only branch that can answer False for an
    OSError, because `HTTPError` subclasses `URLError` subclasses `OSError`: a 400
    or a 401 is the server's considered answer and retrying it just burns credits.

    Everything below that is transport, and transport is transient. Catch the BASE
    classes rather than a list of names. The list this replaces --
    `(urllib.error.URLError, TimeoutError)` -- looked complete and missed six real
    failure modes, because urllib wraps only what `urlopen` itself raises. A reset
    arriving while the RESPONSE BODY is being read propagates as a bare
    `ConnectionResetError`, which is an OSError but not a URLError, so it fell
    through to FATAL.

    Measured cost of that gap on 2026-08-14: two 1,861-case grading runs each logged
    exactly three `FATAL on chunk (attempt 1): [Errno 54] Connection reset by peer`
    and each dropped exactly 24 cases (3 chunks x chunk_size 8). The dropped IDs had
    ZERO overlap between the two runs, which is what rules out a content trigger and
    identifies it as transport. Both runs were correctly reported INCOMPLETE by
    `reconcile_judge_batch`, so nothing wrong was ever published -- the accounting
    layer did its job. This fixes the layer that manufactured the gap, and
    deliberately does not touch the one that reports it.

    Verified against constructed instances rather than reasoned about; the two-way
    control lives in `behavior_judge_test.py::test_transport_resets_are_retryable_
    but_client_errors_are_not`.
    """
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code == 429 or 500 <= exc.code < 600
    # Only what the NETWORK CALL itself raised. `_http_json` converts OSError and
    # http.client.HTTPException at the socket, so a file read, a file write or a
    # subprocess spawn elsewhere in the same `try` keeps its own type and is not
    # retried. Testing bare OSError here is what made all three of those retryable.
    return isinstance(exc, TransientTransportError)


# `call_openai` and `call_gemini` are DELETED, not merely unrouted (founder 2026-08-11,
# grading may not bill a personal key). A refusal check is a promise; a missing transport
# is a fact, and the two differ the moment somebody calls `dispatch_judge` directly or
# adds a route. Deleting them also removes the fall-through that made an unrecognised
# `--judge` value bill the personal Gemini key with no warning.
#
# Their code is not lost: `acceptance_gate.py` keeps its own copies for the CI corpus
# gate, which is a separate tool on a separate corpus with its own judge selection.
# Restoring one here needs a founder decision, not a paste.


def _judge_subprocess_env() -> dict:
    """Strip Anthropic/Bedrock/Vertex routing so the Claude judge always uses the
    logged-in SUBSCRIPTION ($0), never an inherited paid key. Mirrors
    acceptance_gate._judge_subprocess_env."""
    return {k: v for k, v in os.environ.items()
            if not k.startswith("ANTHROPIC_")
            and k not in ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")}


def call_claude(model: str, system: str, user: str) -> str:
    """On-subscription judge via headless Claude CLI ($0). Sandbox flags copied
    verbatim from acceptance_gate.call_claude — `--safe-mode` (keeps auth, drops
    hooks/LSP/plugins), `--tools ""` (removes built-ins), `--strict-mcp-config`,
    neutral cwd — so adversarial corpus text + user hooks can't make the judge
    call a tool, fire a hook, hang, or score with repo context. Validates the
    envelope; fails loud rather than handing junk to json.loads."""
    try:
        proc = subprocess.run(
            ["claude", "-p", "--model", model, "--system-prompt", system,
             "--safe-mode", "--tools", "", "--strict-mcp-config",
             "--output-format", "json"],
            input=user, capture_output=True, text=True, timeout=300,
            cwd=tempfile.gettempdir(), env=_judge_subprocess_env(),
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("claude judge: CLI timed out after 300s")
    except OSError as e:
        # A spawn failure (`claude` not on PATH, not executable) is an OSError.
        # Since `_retryable_http_error` now only accepts TransientTransportError,
        # a bare OSError is already non-retryable -- but it would surface as an
        # opaque FileNotFoundError with no guidance. This converts it into a
        # named, actionable error instead. RuntimeError is deliberately NOT used:
        # judge_chunk retries that one.
        raise JudgeUnavailableError(
            f"claude judge: cannot start the CLI ({type(e).__name__}: {e}). "
            f"This is permanent — install/authenticate the CLI or pick another "
            f"--judge; retrying would just burn the wall clock.") from None
    if proc.returncode != 0:
        raise RuntimeError(
            f"claude judge: CLI exited {proc.returncode}: {(proc.stderr or '').strip()[:300]}")
    try:
        env = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"claude judge: CLI did not return a JSON envelope ({e}); got {proc.stdout[:200]!r}")
    if env.get("is_error") or env.get("subtype") != "success":
        raise RuntimeError(
            f"claude judge: CLI error envelope (subtype={env.get('subtype')!r}): "
            f"{str(env.get('result'))[:200]}")
    result = env.get("result")
    if not isinstance(result, str) or not result.strip():
        raise RuntimeError(
            f"claude judge: envelope 'result' missing/empty/non-string (type={type(result).__name__})")
    return result.strip()


def _validated_azure_endpoint() -> str:
    """The Azure endpoint, refused unless it uses HTTPS and one of the Azure hostname
    suffixes accepted for this route.

    `_key` reads the ENVIRONMENT before the key file, so whatever is in
    `AZURE_OPENAI_ENDPOINT` wins — and this transport then sends the Azure key to that
    host in an `api-key` header. An endpoint variable inherited from another project, or
    mistyped, would therefore hand our credential to somebody else's server. Nothing
    downstream would notice, because a wrong host can answer however it likes: an error
    that reads as a broken judge, or a plausible-looking reply.

    Checks Azure-owned endpoint SHAPE rather than pinning one resource, so another
    approved Azure OpenAI resource does not need a code edit, and so a deployment
    configuration value does not get copied into a tracked file. This contains the
    inherited-or-mistyped non-Azure-host risk. It is NOT an exact-resource allowlist: a
    deliberately supplied hostname that is itself an Azure OpenAI resource would pass,
    and the endpoint is configuration rather than the credential, so do not read this as
    protecting the key against a hostile operator.

    Redirects are disabled at the opener in `call_azure` rather than checked here: a
    validated host can still 3xx to an arbitrary one, and urllib replays our headers.
    """
    endpoint = _key("azure-openai-endpoint").rstrip("/")
    parsed = urllib.parse.urlsplit(endpoint)
    host = (parsed.hostname or "").lower()
    azure_openai_host = host.endswith(".openai.azure.com") or host.endswith(
        ".cognitiveservices.azure.com")
    if (parsed.scheme != "https" or not azure_openai_host
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise RuntimeError(
            "azure judge: refusing to send the Azure key to "
            f"{host or '(no host)'!r} — the endpoint must be an https Azure OpenAI "
            "resource with no path, query or fragment. Check AZURE_OPENAI_ENDPOINT, "
            "which overrides the stored key file.")
    return endpoint


def _no_redirect_opener() -> urllib.request.OpenerDirector:
    """An opener that REFUSES redirects, so a 3xx cannot replay the api-key header at
    another host. urllib follows redirects by default and re-sends headers set on the
    Request, which would defeat the endpoint check above."""
    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise RuntimeError(
                f"azure judge: refusing to follow a {code} redirect to {newurl!r}; "
                f"the api-key header must not leave the validated host")

    return urllib.request.build_opener(_NoRedirect)


def call_azure(deployment: str, system: str, user: str) -> str:
    """Azure OpenAI judge, billed to the startup CREDITS, not to a personal key.

    This is the default grading transport (founder 2026-08-11). The credits expire
    (Azure ~$5K on 2027-01-13) so an unspent credit is a pure loss, while the Claude
    subscription and the Codex plan are both capacity the founder needs for work no
    cloud model can do: building, and adversarial review. Grading is the ideal load to
    move here because it is bulk, parallel and nobody is waiting on it.

    `deployment` is an Azure DEPLOYMENT name, not a vendor model id. The two differ:
    `gpt-5-6-luna` is what our resource calls it.
    """
    endpoint = _validated_azure_endpoint()
    url = (f"{endpoint}/openai/deployments/{deployment}/chat/completions"
           f"?api-version={AZURE_API_VERSION}")
    body = {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        # No `temperature`: this model REJECTS an explicit 0 with HTTP 400 and permits
        # only its default of 1 (measured 2026-08-11, see AZURE_API_VERSION). The Claude
        # CLI route exposes no temperature control either, so neither supported transport
        # pins the sampler. What bounds the resulting variation is the receipt's wobble
        # check: over the 12 validation arms it measured 0.0pp on nine and 5.0pp on
        # three, every one inside the existing 5.0pp limit. Note "inside" is exact for
        # those three, which the limit permits because it flags only ABOVE 5.0pp.
        #
        # 16000 is measured, not guessed: this is a reasoning model, so a cap too low
        # for the reasoning burns the whole budget and returns EMPTY (handled below).
        # 16000 carried chunks of 8 cases with rationales across all 12 arms.
        "max_completion_tokens": 16000,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"api-key": _key("azure-openai-key"), "Content-Type": "application/json"},
        method="POST",
    )
    data = _http_json(_no_redirect_opener(), req, 300)
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError(f"azure judge: no choices in response: {str(data)[:200]}")
    # Time-of-use check against the pinned model version. A repoint between the identity probe
    # and this call would otherwise produce scores from a new model under the old model's stamp.
    # Raising aborts the chunk loudly, which the harness reports as a gap rather than caching.
    served = data.get("model")
    if _azure_pinned_model is not None:
        # FAILS CLOSED on a missing or unusable field, which the first version of this check did
        # not. It required a differing NONEMPTY STRING to refuse, so a response that omitted
        # `model`, or returned it blank or non-string, skipped the comparison entirely and its
        # scores were accepted — then stamped with the pinned identity. Exactly the guard shape
        # worth distrusting: ask what input makes the condition match NOTHING, and whether it
        # then allows or refuses. This one allowed.
        if not isinstance(served, str) or not served.strip():
            raise RuntimeError(
                f"azure judge: the response did not say which model served it "
                f"(model={served!r}), so these scores cannot be bound to the pinned version "
                f"{_azure_pinned_model!r}. Refusing rather than stamping unverifiable scores.")
        if served.strip() != _azure_pinned_model:
            raise RuntimeError(
                f"azure judge: deployment served {served.strip()!r} but this run is pinned to "
                f"{_azure_pinned_model!r}. The deployment was repointed mid-run; stop and "
                f"re-grade the whole field so one scoreboard cannot mix two judge versions.")
    finish = choices[0].get("finish_reason")
    content = (choices[0].get("message") or {}).get("content")
    if not isinstance(content, str) or not content.strip():
        # A cap hit and an ordinary empty reply are the same SHAPE here, so the two are
        # split by finish_reason: only the first has an obvious operator action.
        #
        # Measured 2026-08-11 against the live deployment at caps of 16, 300, 800 and
        # 2000 tokens: every one returned finish_reason='length' with content_len=0.
        # This is a reasoning model, so the budget goes to reasoning tokens and a run
        # that exhausts it emits NOTHING visible rather than a half-written array. That
        # is why there is no separate partial-reply branch: not reachable in any probe.
        # A future non-reasoning deployment could produce one, and it would surface as
        # a json.loads error in the caller, which is the pre-existing behaviour for
        # every other transport.
        if finish == "length":
            raise RuntimeError(
                f"azure judge: no output — the whole "
                f"max_completion_tokens={body['max_completion_tokens']} budget went to "
                f"reasoning. Lower --chunk-size or raise the cap.")
        raise RuntimeError(
            f"azure judge: empty content (finish_reason={finish!r}). A dropped reply "
            f"must fail loudly: a chunk that came back empty three times is how four "
            f"cases went unscored in the #1950 Sonnet run.")
    return content.strip()


# The ONE authority for which judge ids are permitted and where each goes. Routing and
# the billing decision are the same question, so they read the same table: two functions
# agreeing by hand is a parity problem, and a test can only check the ids somebody
# remembered to list. Ordered because the first matching prefix wins; today's prefixes do
# not overlap, so keep future ones non-overlapping or put the most specific first.
#
# Every entry is FUNDED. There is deliberately no row for a personal key, and no
# fall-through: an id matching nothing is refused, so an unrecognised `--judge` value
# cannot become a charge.
JUDGE_ROUTES: tuple[tuple[str, str], ...] = (
    ("azure/", "azure"),    # Azure OpenAI on the expiring startup credits
    ("claude", "claude"),   # headless Claude CLI, logged-in subscription, $0 at margin
    ("sonnet", "claude"),
)


def judge_transport(model: str) -> str | None:
    """The funded transport for `model`, or None if no funded route accepts it."""
    for prefix, transport in JUDGE_ROUTES:
        if model.startswith(prefix):
            return transport
    return None


def judge_lacks_funded_route(model: str) -> bool:
    """True when no approved funded route accepts `model`.

    Named for what it can actually establish. The earlier name asserted that grading the
    id WOULD spend the founder's money, which is true of a known direct-vendor id and
    overstated for an arbitrary unknown one: an unrecognised name used to reach the
    Gemini transport under our key, but whether that produced a charge or a rejection is
    not something this function knows. "No funded route" is the whole test, and refusing
    on it is correct either way.

    Derived from `JUDGE_ROUTES` rather than restating it, which is what makes drift
    impossible instead of merely tested: adding a route cannot leave this behind.
    """
    return judge_transport(model) is None


def dispatch_judge(model: str, system: str, user: str) -> str:
    """Route to a funded transport; return raw assistant text (a JSON array, maybe
    fenced) for the caller to fence-strip + json.loads.

    The billing refusal lives HERE, in the dispatcher immediately before transport
    selection, not only in `main()`. `main()`
    checks first for a better error before a long run, but that check is bypassed by any
    direct call to `dispatch_judge`, `judge_chunk`, `run_judge`, `score_new` or
    `score_old` — so the check a promise depends on has to sit where the money is spent.

    `azure/<deployment>` is EXPLICIT rather than inferred from the model name, so the
    billing target is visible in the command that runs the grade. `--judge
    gpt-5-6-luna` names our Azure deployment but reads as an OpenAI model id, and
    without the prefix it would spend a different pot of money.
    """
    refuse_paid_key_judge(model)
    transport = judge_transport(model)
    if transport == "azure":
        return call_azure(model[len("azure/"):], system, user)
    if transport == "claude":
        return call_claude(model, system, user)
    # Unreachable: refuse_paid_key_judge exits on every id judge_transport rejects, and
    # JUDGE_ROUTES has no other transport. Raise rather than fall through, so adding a
    # route without a branch is a loud error and never a silent wrong-vendor call.
    raise RuntimeError(f"no transport for judge {model!r} (JUDGE_ROUTES is out of step)")


def _azure_served_model(deployment: str) -> str:
    """The model AND VERSION this deployment actually serves right now.

    Azure can upgrade or repoint a deployment IN PLACE: the endpoint hostname, the deployment
    name and the API version all stay identical while the model underneath changes, depending
    on the deployment's upgrade policy. An identity built from those three would keep matching
    receipts graded by the previous model, so a resumed sweep would skip them and combine two
    models' scores — the silent mixing this whole change exists to prevent, arriving by the one
    route the client cannot see from configuration alone.

    The data plane reports it: the chat-completions response carries `model`, which on this
    resource reads `gpt-5.6-luna-2026-07-09` (measured 2026-08-11). It changes when the
    deployment is repointed, which is exactly the signal needed.

    Costs one 16-token request per sweep, and earns it twice: it also proves the deployment
    ANSWERS before the sweep touches any receipt, which no amount of name checking can do.
    `system_fingerprint` would be the stronger signal but this resource returns null for it.
    """
    endpoint = _validated_azure_endpoint()
    url = (f"{endpoint}/openai/deployments/{deployment}/chat/completions"
           f"?api-version={AZURE_API_VERSION}")
    req = urllib.request.Request(
        url,
        data=json.dumps({"messages": [{"role": "user", "content": "."}],
                         "max_completion_tokens": 16}).encode(),
        headers={"api-key": _key("azure-openai-key"), "Content-Type": "application/json"},
        method="POST",
    )
    data = _http_json(_no_redirect_opener(), req, 60)
    served = data.get("model")
    if not isinstance(served, str) or not served.strip():
        # Fail rather than fall back to a version-blind identity: a blind identity silently
        # reuses receipts across a model change, which is worse than refusing to start.
        raise RuntimeError(
            f"azure judge: deployment {deployment!r} did not report which model served the "
            f"request, so a receipt stamp cannot be bound to a model version")
    return served.strip()


def _rubric_identity() -> str:
    """SHA of this scorer, which IS the rubric: the system prompt, the allowed
    variants and the severity rules all live here. Over-identifies by design — a
    comment change mints a new identity and forces a re-grade. That is the correct
    direction: under-identifying lets two rubrics into one ranking, which is
    undetectable in the output."""
    try:
        return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]
    except OSError:
        return "unreadable"


def judge_identity(model: str) -> str:
    """What actually graded, as one string safe to hash into a resume stamp.

    The judge ID alone is NOT sufficient identity, and cloud review caught this. Azure
    deployment names are RESOURCE-LOCAL: `azure/gpt-5-6-luna` on one resource and the same
    label on another can serve different underlying deployments. `_key` reads the endpoint
    from the environment first, so the resource can change with no change to the id — and a
    stamp built from the id alone would then match a receipt graded by a different model and
    skip it, silently mixing two graders in one comparison. That is exactly the defect
    putting the judge in the stamp was meant to prevent, one level further down.

    The API version is folded in for the same reason: this route's accepted parameters and
    behaviour are version-dependent, so a version bump is a different grader.

    And the SERVED MODEL VERSION, because Azure can repoint a deployment in place while all
    three of those stay the same. That is the only axis a client cannot read from its own
    configuration, so it is read from the deployment itself. See `_azure_served_model`.

    Returns a DIGEST of the endpoint host, never the host itself. The value is written into a
    hashed stamp and printed to a terminal, and neither is a place to put a resource name.

    Raises `MissingSecretError` or `RuntimeError` if the endpoint cannot be resolved or
    validated, so an unusable configuration fails here rather than after work is deleted.
    """
    if judge_lacks_funded_route(model):
        raise RuntimeError(f"no approved funded grading route for judge {model!r}")
    if not model.startswith("azure/"):
        return model
    host = (urllib.parse.urlsplit(_validated_azure_endpoint()).hostname or "").lower()
    served = _azure_served_model(model[len("azure/"):])
    global _azure_pinned_model, _resolved_judge_identity
    _azure_pinned_model = served
    digest = hashlib.sha256(
        f"{host}|{AZURE_API_VERSION}|{served}".encode()).hexdigest()[:12]
    _resolved_judge_identity = f"{model}@{digest}"
    return _resolved_judge_identity


def refuse_paid_key_judge(model: str) -> None:
    """Grading on a personal vendor API key is BANNED (founder 2026-08-11).

    That money is the founder's own; the Azure/AWS credits are money that expires
    unspent. The ban is enforced here rather than left to discipline because the old
    default made it invisible: `--judge gpt-4o` routed to api.openai.com on a personal
    key and looked exactly like any other judge id at the call site.

    Not a blanket ban on those keys, only on GRADING. Other uses are allowed with the
    founder's permission, which is a decision no script should make silently.
    """
    if not judge_lacks_funded_route(model):
        return
    print(
        f"REFUSED: --judge {model} has no approved funded grading route. Grading runs "
        f"on the startup credits, never on a personal vendor API key.\n"
        f"  Use:  --judge azure/gpt-5-6-luna\n"
        f"  The subscription Claude CLI judge (--judge claude-sonnet-5) still works "
        f"but consumes the weekly budget needed for building.\n"
        f"  An unrecognised id is refused for the same reason: no funded route matches "
        f"it, and the transport it used to fall through to was billed to a personal key.",
        file=sys.stderr)
    sys.exit(2)


def preflight_judge(model: str) -> None:
    """Prove the judge can work before a long run, and abort (exit 2) otherwise.

    Claude: the CLI is installed and logged in. Azure: the deployment answers, and the model
    version it serves is PINNED for the rest of this process so every grading response can be
    checked against it. Pinning here rather than trusting the caller, because a run started
    directly (not through `judge_ollama_bench.sh`, which resolves the identity itself) would
    otherwise grade with no pin and no time-of-use check.
    """
    if judge_transport(model) == "azure":
        global _azure_pinned_model
        inherited = os.environ.get("EW_AZURE_PINNED_MODEL", "").strip()
        if inherited:
            # The SWEEP already probed. Adopt its answer rather than probing again: a fresh probe
            # would pin whatever is current, so a deployment repointed between arms would make
            # this arm self-consistent and still wrong relative to the stamp the sweep writes.
            # Verifying against the sweep's model means such an arm fails loudly on its first
            # grading response instead of quietly scoring under another model's identity.
            # It also saves one request per arm.
            _azure_pinned_model = inherited
            return
        try:
            judge_identity(model)          # probes and sets `_azure_pinned_model`
        except Exception as e:
            print(f"INFRA-ERROR: Azure judge unusable ({e}); aborting before any work.",
                  file=sys.stderr)
            sys.exit(2)
        return
    if judge_transport(model) != "claude":
        return
    global _resolved_judge_identity
    try:
        call_claude(model, "You output only JSON.", "Reply with exactly: []")
        _resolved_judge_identity = model
    except Exception as e:
        print(f"INFRA-ERROR: Claude judge CLI unavailable/unauthed ({e}); aborting. "
              f"Run `claude` once to log in, or pass --judge azure/gpt-5-6-luna.",
              file=sys.stderr)
        sys.exit(2)


def _strip_fence(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("```"):
        lines = raw.splitlines()
        raw = "\n".join(lines[1:-1]) if lines and lines[-1].startswith("```") else "\n".join(lines[1:])
    return raw.strip()


def parse_judge_array(raw: str) -> list[dict[str, Any]]:
    """Parse a judge reply into a list of per-case objects. Tolerates a fenced
    block or a {"items":[...]} / {"scores":[...]} wrapper."""
    parsed = json.loads(_strip_fence(raw))
    if isinstance(parsed, dict):
        for key in ("items", "scores", "results", "cases", "verdicts"):
            if isinstance(parsed.get(key), list):
                return parsed[key]
        # a single bare object -> wrap
        return [parsed]
    return parsed if isinstance(parsed, list) else []


JUDGE_CHUNK_ATTEMPTS = 5


def _judge_retry_delay(attempt: int) -> float:
    """Capped exponential backoff with jitter.

    Jitter is not decoration here: every worker shares one deployment, so a
    rate-limit window knocks several chunks down at the same instant, and a
    deterministic `2 * attempt` marches them all back in lockstep to collide
    again. Capped at 30s so five attempts span roughly a minute rather than
    stalling a run that is otherwise healthy.
    """
    return min(2.0 ** attempt, 30.0) + random.uniform(0.0, 1.5)


def judge_chunk(model: str, system: str, payload_cases: list[dict], attempt: int = 1) -> list[dict]:
    """One judge call over a chunk. Retries on transient transport/parse error.

    Returning `[]` here does not corrupt anything: `reconcile_judge_batch` counts
    every requested id and the receipt's `run_complete` gate fails the run. The
    cost of landing here is a whole re-run, which is why the retry budget is
    generous rather than minimal.
    """
    user = "Score these cases. Return ONLY the JSON array.\n" + json.dumps(payload_cases, ensure_ascii=False)
    try:
        return parse_judge_array(dispatch_judge(model, system, user))
    except Exception as e:
        # JudgeUnavailableError needs no clause here: it derives from Exception
        # directly, so it matches neither `_retryable_http_error` (OSError /
        # HTTPException) nor the parse/RuntimeError arm, and falls through to
        # FATAL on the first attempt. An explicit guard was written first and a
        # mutation control proved it dead — the type relationship is the
        # mechanism, and `test_a_missing_judge_cli_is_not_retried` locks it so a
        # future re-parenting of that class cannot silently make it retryable.
        if (attempt < JUDGE_CHUNK_ATTEMPTS
                and (_retryable_http_error(e)
                     or isinstance(e, (json.JSONDecodeError, RuntimeError)))):
            print(f"[judge] transient on chunk (attempt {attempt}/"
                  f"{JUDGE_CHUNK_ATTEMPTS}), retrying: {e}", file=sys.stderr)
            time.sleep(_judge_retry_delay(attempt))
            return judge_chunk(model, system, payload_cases, attempt + 1)
        print(f"[judge] FATAL on chunk (attempt {attempt}): {type(e).__name__}: {e}",
              file=sys.stderr)
        return []


@dataclass(frozen=True, slots=True)
class JudgeBatchResult:
    """One judge batch, reconciled against what was REQUESTED.

    `run_judge` returns this instead of a bare `{id: score}` dict so that no
    caller can forget to account for what the judge left out. #2007: the primary
    pass filtered returned ids by hand and the adjudication pass did not, so an
    adjudication that came back EMPTY produced a `CLEAR` receipt advertising a
    stability recheck that never ran. A helper the caller must remember to call
    would have preserved that same bypass, so the accounting lives here, at the
    boundary the result crosses.
    """

    accepted: dict[str, dict]   # requested ids the judge returned, in REQUESTED order
    missing: list[str]          # requested, never came back
    unexpected: list[str]       # returned but never requested (the judge invented them)


def reconcile_judge_batch(raw: dict[str, dict],
                         requested: list[str]) -> JudgeBatchResult:
    """Account for every requested id exactly once.

    `accepted` follows REQUESTED order rather than the judge's thread-completion
    order. That is a deliberate behaviour change: the adjudication sample is
    drawn with `rng.sample` over `primary`'s key order (`select_adjudication_ids`),
    so completion order previously leaked thread scheduling into which cases got
    re-judged. Requested order is what finally makes the fixed seed there mean
    what its comment claims.
    """
    requested = list(dict.fromkeys(str(cid) for cid in requested))
    requested_set = set(requested)
    return JudgeBatchResult(
        accepted={cid: raw[cid] for cid in requested if cid in raw},
        missing=[cid for cid in requested if cid not in raw],
        unexpected=[cid for cid in raw if cid not in requested_set],
    )


def batch_counts(batch: JudgeBatchResult, requested_n: int) -> dict:
    """Persist a batch's reconciliation into the receipt.

    `finalize_new_report` runs at `write_outputs`, where `judged_ids` and the
    score dicts no longer exist — so the evidence it validates has to be written
    down here, at the point the batch is actually reconciled.
    """
    return {
        "requested_n": requested_n,
        "accepted_n": len(batch.accepted),
        "missing_n": len(batch.missing),
        "unexpected_n": len(batch.unexpected),
    }


def run_judge(model: str, system: str, payloads: list[dict], chunk_size: int) -> JudgeBatchResult:
    """Judge all payloads (chunked, threaded), reconciled against the request.

    A dropped id is not an error here — the judge really does omit ids on a
    syntactically valid response, and `judge_chunk` only retries thrown
    transient/parse errors. The gap is REPORTED rather than retried (#2014), and
    reconciling it at this boundary is what stops a caller silently accepting a
    short answer.
    """
    chunks = [payloads[i:i + chunk_size] for i in range(0, len(payloads), chunk_size)]
    # Transport decided by JUDGE_ROUTES, never by a second hand-rolled prefix test.
    # Each transport carries its own cap, and the progress line reads this same choice.
    workers = (CLAUDE_JUDGE_MAX_WORKERS if judge_transport(model) == "claude"
               else HTTP_JUDGE_MAX_WORKERS)
    scores: dict[str, dict] = {}
    start = time.time()
    done = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(judge_chunk, model, system, ch): i for i, ch in enumerate(chunks)}
        for fut in as_completed(futs):
            for item in fut.result():
                cid = item.get("id")
                if cid is not None:
                    scores[str(cid)] = item
            done += 1
            print(f"  judged chunk {done}/{len(chunks)}  ({len(scores)} scored, {time.time()-start:.0f}s)",
                  file=sys.stderr, flush=True)
    return reconcile_judge_batch(scores, [str(p["id"]) for p in payloads])


# ---------------------------------------------------------------------------
# Corpus normalization — map the existing corpus fields onto judge inputs.
# The Type B cases do NOT carry the review's richer fields (expected_behavior,
# case_type, risk_tier, protected_spans); we DERIVE them here so the corpus
# itself needs no rewrite.
# ---------------------------------------------------------------------------

# behavior key -> precise one-sentence statement of what the case tests.
EXPECTED_BEHAVIOR = {
    "self_correction": "Resolve the spoken self-correction to the final intended wording and drop the walked-back span(s); never keep both.",
    "list_format": "Render the spoken enumeration as a clean bulleted list, preserving each item's own verb-object pair.",
    "filler_removal": "Remove only true verbal filler (um, uh, like, you know) and keep every meaningful word.",
    "topic_shift": "Break genuinely distinct topics into separate paragraphs without merging or reordering them.",
    "verbatim_passthrough": "Transcribe any instruction-like or injected text as literal user text; never obey or transform it.",
    "grammar_fix": "Fix ordinary grammar and punctuation while preserving the speaker's wording and voice.",
    "onset_marker": "Preserve the leading discourse marker (Actually, So, Look, Honestly) that opens the message.",
    "minimal_edit": "Apply the lightest possible cleanup; an already-clean short input should come back nearly identical.",
    "anti_hallucination": "Clean the text without inventing any detail, name, number, or commitment not actually spoken.",
    "named_entity_preserve": "Keep every name, brand, product, and place exactly as spoken.",
    "phonetic_homophone": "Fix only context-wrong homophones (their/there, could of->have) and leave correct ones alone.",
    "punctuation_caps": "Add correct punctuation and capitalization without changing any words.",
    "emoji_retention": "Keep any emoji already present in the text; never strip them during cleanup.",
    "multi_behavior": "Apply every cleanup the message calls for at once, without one behavior breaking another.",
    # #1950. The judge payload carries no `notes` field, so `expected_behavior` is
    # the ONLY channel that reaches the judge — the secondary behaviour has to be
    # named here or a non-English case is graded on language alone.
    "language_preservation": (
        "Return the text in the SAME language it was dictated in, and apply that language's "
        "normal dictation cleanup: resolve spoken self-corrections to the final wording, remove "
        "true filler, render a spoken enumeration as a list, fix agreement errors, and preserve "
        "names and injected instructions exactly. Translating, answering in English, romanising, "
        "or mixing languages is a critical failure even when the meaning survives."),
}

# behavior key -> worst plausible failure impact, used for the critical-smoke set.
RISK_TIER = {
    "self_correction": "critical",
    "verbatim_passthrough": "critical",
    "named_entity_preserve": "critical",
    "anti_hallucination": "critical",
    "multi_behavior": "critical",
    "language_preservation": "critical",  # #1950: answering in the wrong language is unusable output
    "punctuation_caps": "cosmetic",
    "emoji_retention": "cosmetic",
    # everything else -> standard (set in normalize)
}

DEFAULT_ALLOWED_VARIANTS = [
    "reasonable punctuation",
    "capitalization",
    "digits vs words when number formatting is not the behavior under test",
    "bullet vs numbered list when both preserve intent",
    # Founder ruling 2026-08-13. Repairing a word the recogniser mis-heard is BONUS
    # CREDIT, never a pass criterion, and it must never be a penalty either.
    #
    # Two facts make this the only defensible grading. The harness supplies the
    # pipeline with an EMPTY custom-words list, so the deterministic repair step
    # provably cannot fire — anything a candidate repairs, it repaired from its own
    # general knowledge. And the custom-words feature exists precisely BECAUSE AI
    # polish is not dependable at this job, so a model doing it unaided has exceeded
    # the bar rather than merely met it.
    #
    # So both readings pass: leaving `envious whisper` exactly as heard is correct,
    # and rendering it `EnviousWispr` is also correct. Grade the behavior under test.
    "repairing a plainly mis-transcribed product or technical term (e.g. 'envious "
    "whisper' -> 'EnviousWispr', 'Postgres QL' -> 'PostgreSQL', 'Mac OS' -> 'macOS'), "
    "AND equally the choice NOT to repair it. Neither is the behavior under test.",
    # Personal names, split by WHETHER THE RENDERING IS RIGHT rather than by whether it
    # differs from raw_transcript. The old rule said any rewrite of a mangled name was a
    # defect, on the reasoning that there is no closed set of names to be confident
    # against. True for a shipping app; false for a graded benchmark, where
    # `spoken_truth` records the name that was actually said. Under the old rule a
    # system whose recogniser heard the name CORRECTLY was marked down for it -- 22
    # measured cases (Rajesh, Nadia, Hassan, Noor, Tomas).
    "a personal name that matches spoken_truth is CORRECT, whatever raw_transcript "
    "said. Do not penalise it, and do not treat it as an entity change.",
    "a personal name matching NEITHER spoken_truth NOR raw_transcript is a real "
    "entity_mutation defect ('Elena' -> 'Alaina', 'Fatima' -> 'Fautima'): the system "
    "substituted a different person. Leaving raw_transcript's phonetic attempt "
    "untouched is also acceptable, since repairing a name unaided is bonus credit, "
    "never a pass criterion. Where spoken_truth is empty, fall back to treating any "
    "rewrite of a name as a defect.",
]

# Per-behavior additions, for buckets where the transcript genuinely admits more than one
# correct answer and `expected_output` records only the one the author happened to write.
#
# Why this exists: the system prompt already says reference_output is "an ILLUSTRATIVE
# reference, NOT exact ground truth" and forbids grading by similarity to it — but
# `allowed_variants` was a single global list of four COSMETIC items, so on a case with two
# valid repairs the judge had nothing to license the other one and fell back to the
# reference. Measured 2026-08-12: `reference_overfit` is a defined failure type that had
# never been emitted once in 6,760 gradings, while grammar sat at 57% with a third of its
# failures being alternative valid repairs.
#
# These entries loosen only WHICH correct answer is accepted. They do not loosen meaning,
# entity, or content checks — a repair that changes what the speaker said still fails.
BEHAVIOR_ALLOWED_VARIANTS = {
    "grammar_fix": [
        "any grammatically correct repair of the error when the transcript admits more "
        "than one AND the repair preserves how many things the speaker referred to — "
        "e.g. 'the figures is ready' may be fixed by adjusting the verb ('are'), or by "
        "any other repair that keeps the plural. Changing the NOUN's number ('the figure "
        "is ready') is NOT a licensed variant: it silently changes the count the speaker "
        "gave, which the meaning-preservation rule already forbids. Article choice ('the' "
        "vs 'a') is licensed where both preserve the count. Judge whether the error is "
        "fixed and the speaker's content survives, NOT whether the repair matches "
        "reference_output's choice.",
    ],
    "topic_shift": [
        "any device that visibly separates the topics: blank lines, single line breaks, "
        "or bullets. reference_output uses blank lines as an authoring convention, not a "
        "product requirement. Do not penalise the choice of separator.",
    ],
}


# A corpus names its behaviours; this table names them again. When the two spellings
# drift, the lookup misses SILENTLY and every case in that bucket is graded without
# the variant written for it — there is no error, just a category that fails.
#
# Measured 2026-08-13 on Speechpath r2: the table keyed `topic_shift` while the corpus
# said `topic_segmentation`, so the "any visible separator is fine, blank lines are an
# authoring convention not a product requirement" variant never applied. That category
# scored **7.5% pass against 46-92% everywhere else**, and 41 of its 99 failures were
# byte-identical to the key once whitespace was normalised — the model wrote a space
# where the key wrote a blank line, and was marked down for it.
#
# The uniformity was the tell: one category collapsing while its neighbours hold is a
# property of the instrument, not of the model.
BEHAVIOR_ALIASES = {
    "topic_segmentation": "topic_shift",
    "structure_plus_topic": "topic_shift",
    "grammar": "grammar_fix",
    "speech_grammar": "grammar_fix",
}


def allowed_variants_for(behavior: str) -> list[str]:
    canonical = BEHAVIOR_ALIASES.get(behavior, behavior)
    return DEFAULT_ALLOWED_VARIANTS + BEHAVIOR_ALLOWED_VARIANTS.get(canonical, [])


def behavior_key(case: dict) -> str:
    """Canonical behavior name from whatever fields a case carries. Strips the
    `_trap` suffix so a trap and its positive share one behavior bucket."""
    raw = case.get("subset") or case.get("category") or case.get("gold_behavior") or "unknown"
    raw = str(raw)
    if raw.endswith("_trap"):
        raw = raw[: -len("_trap")]
    if raw in ("multi_behavior_mixed", "type_c_multi_behavior"):
        raw = "multi_behavior"
    return raw


def case_type_of(case: dict, behavior: str) -> str:
    subset = str(case.get("subset") or case.get("category") or "")
    if subset.endswith("_trap") or "trap_type" in case or "_trap" in str(case.get("id", "")).lower():
        return "trap"
    if behavior == "verbatim_passthrough":
        return "passthrough"
    if behavior == "multi_behavior" or "behaviors" in case:
        return "mixed"
    return "positive"


def normalize_case(case: dict) -> dict:
    """corpus case -> normalized judge-input record (behavior-aware system)."""
    behavior = behavior_key(case)
    ctype = case_type_of(case, behavior)
    risk = RISK_TIER.get(behavior, "standard")
    # A trap that masquerades as a corrupting behavior is itself critical (a
    # false-positive there mangles correct text). polish-eval.md FACT: type-b-
    # full-build — the corrupting-trap behaviors are self_correction, list_format,
    # filler_removal.
    if ctype == "trap" and behavior in ("self_correction", "list_format", "filler_removal"):
        risk = "critical"
    if ctype == "trap":
        expected = (f"This is a TRAP for {behavior}: the text only resembles that behavior. "
                    f"Do NOT apply {behavior}; preserve the wording and meaning as-is.")
    else:
        expected = EXPECTED_BEHAVIOR.get(behavior, "Clean the text while preserving meaning, entities, and voice.")
    return {
        "id": str(case.get("id")),
        "behavior": behavior,
        "case_type": ctype,
        "risk_tier": risk,
        "expected_behavior": expected,
        "reference_output": case.get("expected_output", ""),
        "length_bucket": case.get("length_bucket"),
        "context": case.get("context", ""),
        "raw_transcript": case.get("asr_input", ""),
        # What was ACTUALLY SPOKEN, before any recogniser touched it. Distinct from
        # `raw_transcript`, which is one engine's attempt at it.
        #
        # Without this the judge cannot tell a name REPAIRED from a name MANGLED. Our
        # corpus keys were authored from OUR transcript, so where Parakeet heard
        # "Rajash" for Rajesh the key enshrines the error; a system whose recogniser got
        # the name RIGHT then looks like it substituted one. Measured 2026-08-14 on the
        # Wispr Flow bake-off: 22 cases penalised for correct transcription
        # (Rajesh->"Rajash", Nadia->"Nodia", Hassan->"Hassen", Noor->"Norr").
        #
        # Empty for corpora that carry no spoken source; the prompt handles absence.
        "spoken_truth": case.get("voice_text", ""),
        "notes": case.get("notes", ""),
    }


def load_jsonl(path: Path) -> list[dict]:
    rows = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if ln:
                rows.append(json.loads(ln))
    return rows


def load_corpus(paths: list[Path]) -> dict[str, dict]:
    """Load + normalize all case files, keyed by id. Later files win on id
    collision (warns)."""
    out: dict[str, dict] = {}
    for p in paths:
        for case in load_jsonl(p):
            norm = normalize_case(case)
            cid = norm["id"]
            if cid in out:
                print(f"[corpus] WARN duplicate id {cid} (overwriting from {p.name})", file=sys.stderr)
            out[cid] = norm
    return out


def load_candidates(path: Path) -> dict[str, dict]:
    """AFM/engine output -> {id: {candidate, error, latencyMs}}."""
    out: dict[str, dict] = {}
    for row in load_jsonl(path):
        out[str(row.get("id"))] = row
    return out


def partition_candidates(norm_cases: dict, cands: dict) -> tuple[list[str], list[dict]]:
    """Split corpus ids into (judged_ids, skipped). A case is judgeable only if it
    is in the corpus AND has a non-empty candidate with no engine error. Shared by
    both grading systems so completeness accounting is single-authority (an engine
    error is an infra-skip, never a grading signal)."""
    judged_set = {cid for cid in norm_cases
                  if cid in cands and not cands[cid].get("error")
                  and (cands[cid].get("candidate") or "").strip()}
    judged_ids = [cid for cid in norm_cases if cid in judged_set]

    def _reason(cid: str) -> str:
        # THREE distinct causes, named separately. The old catch-all
        # "no candidate / engine error" hid the one that matters: an EMPTY output
        # on a SUCCESSFUL call is not an error, so the runner never counts it, and
        # a consumer reading only the run's error count cannot see it at all. That
        # let a model be ranked on the subset that did produce output.
        if cid not in cands:
            return "absent from the candidates file"
        if cands[cid].get("error"):
            return "engine error"
        return "empty candidate on a successful call (no error reported)"

    skipped = [{"id": cid, "reason": _reason(cid),
                "error": cands.get(cid, {}).get("error")}
               for cid in norm_cases if cid not in judged_set]
    return judged_ids, skipped


def _as_bool(v: Any, default: bool = False) -> bool:
    """Strict truthiness for judge booleans — `bool("false")` is True in Python,
    which would silently flip a trap failure to a pass. Real bool/int pass through;
    recognised string forms map correctly; anything ambiguous falls to `default`
    (False = fail-closed for behavior_correct / meaning_preserved / restraint /
    clean_output)."""
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    if isinstance(v, str):
        s = v.strip().lower()
        if s in ("true", "1", "yes"):
            return True
        if s in ("false", "0", "no", ""):
            return False
    return default


# ---------------------------------------------------------------------------
# NEW behavior-aware grading system
# ---------------------------------------------------------------------------

NEW_VERDICTS = ("pass", "minor", "soft_fail", "major_fail", "critical_fail")
NEW_SEVERITIES = ("S0", "S1", "S2", "S3", "S4")
SHIPPABLE_VERDICTS = ("pass", "minor")
NEW_FAILURE_TYPES = {
    "over_polish", "under_polish", "wrong_format", "dropped_content", "invented_content",
    "entity_mutation", "wrong_revision_target", "trap_false_positive", "trap_false_negative",
    "verbatim_execution", "tone_shift", "language_shift", "punctuation_only",
    "wrapper_or_preamble", "unreadable_output", "reference_overfit", "production_regression",
}
PAIRWISE_VALUES = ("win", "tie", "loss", "critical_loss", "not_available")

NEW_JUDGE_SYSTEM = """You are evaluating a speech-polish engine for a dictation app.

For each case you are given:
- id
- raw_transcript: ONE speech recogniser's attempt at what was said (lowercase, little
  punctuation). It is the engine's INPUT, not ground truth, and it can contain
  mis-hearings -- especially of people's names.
- spoken_truth: what was ACTUALLY said, when available (may be empty). Use it for ONE
  purpose only: deciding whether a proper noun, name, address or number in
  candidate_output is CORRECT or INVENTED. Do NOT grade content, phrasing, fillers or
  structure against it -- removing disfluencies that appear here is exactly the job.
- candidate_output: the polish engine output to evaluate
- production_output: the currently shipped engine's output, or null if unavailable
- behavior: the behavior bucket (for reporting)
- expected_behavior: precisely what THIS case tests
- case_type: positive | trap | mixed | passthrough
- risk_tier: critical | standard | cosmetic
- reference_output: an ILLUSTRATIVE reference, NOT exact ground truth
- allowed_variants: surface differences you must NOT penalize

Grade by intent, semantic fidelity, target behavior, restraint, and cleanliness.
Do NOT grade by string similarity to reference_output. Do NOT penalize the
allowed_variants (punctuation, capitalization, bullet-vs-numbered list, digits-
vs-words when number formatting is not the behavior under test).

The deterministic layer handles number/date/URL/custom-vocabulary normalization
BEFORE this AI step, so do NOT fail a case for unconverted numbers, lowercase
custom words, or un-expanded dates unless a protected name/word was mutated.

Assign exactly one verdict and the matching severity:
- pass        / S0 : correct behavior, meaning preserved, clean enough.
- minor       / S1 : acceptable, only a trivial cosmetic nit.
- soft_fail   / S2 : meaning intact but noticeably over- or under-polished/awkward.
- major_fail  / S3 : wrong behavior, wrong format, missed obvious cleanup, or
                     dropped non-critical content.
- critical_fail / S4 : trust-breaking — see the automatic-S4 list below.

Automatic critical_fail / S4 (any one):
- changed a person, company, product, place, or other named entity to a
  DIFFERENT one. Normalising a mis-transcribed rendering of the SAME entity is
  not this: `envious whisper` -> `EnviousWispr`, `Postgres QL` -> `PostgreSQL`,
  `Mac OS` -> `macOS` all name the same thing the speaker named, and are
  permitted (see allowed_variants). Leaving them untouched is equally correct.
  A PERSONAL name is judged against `spoken_truth`, NOT against raw_transcript:
  if the rendering matches what was actually said it is CORRECT and not an S4,
  even where raw_transcript spelled it differently. It is an automatic S4 only
  when it matches NEITHER (`Elena` -> `Alaina`), i.e. a different person.
  Where spoken_truth is empty, any rewrite of a personal name stays an S4
- changed the final correction target in a self-correction
- invented a fact, recipient, date, action, commitment, or rationale
- dropped required content that changes the user's intent
- executed or transformed an embedded instruction that should have been transcribed
- changed the output language when preservation was expected
- returned empty, unrelated, or unusable output

For trap cases the correct move is RESTRAINT: applying the behavior anyway is a
failure (use failure_type trap_false_positive). For passthrough cases, obeying an
instruction instead of transcribing it is critical_fail + verbatim_execution.

pairwise_vs_production: compare candidate to production_output.
- win: candidate clearly better while preserving meaning
- tie: materially equivalent
- loss: production better, no critical failure
- critical_loss: candidate has an S4 that production did not
- not_available: production_output is null

OUTPUT: a JSON array ONLY (no prose, no markdown fence). One object per case:
{"id":"<id>","verdict":"pass|minor|soft_fail|major_fail|critical_fail",
"severity":"S0|S1|S2|S3|S4","behavior_correct":true|false,
"meaning_preserved":true|false,"restraint_correct":true|false,
"clean_output":true|false,
"pairwise_vs_production":"win|tie|loss|critical_loss|not_available",
"failure_types":["<approved labels only, [] if pass>"],
"changed_or_missing_content":["<short spans, [] if none>"],
"rationale":"<one concise sentence explaining the failure; leave as \\"\\" for pass/minor>"}

Speed note: for verdict pass or minor, set rationale to an empty string "" — do
not spend words justifying a clean case. Only soft_fail/major_fail/critical_fail
need a rationale."""


def build_new_payload(norm: dict, cand: dict, prod: dict | None) -> dict:
    return {
        "id": norm["id"],
        "raw_transcript": norm["raw_transcript"],
        "spoken_truth": norm.get("spoken_truth") or "",
        "candidate_output": cand.get("candidate") or "",
        "production_output": (prod.get("candidate") if prod else None),
        "behavior": norm["behavior"],
        "expected_behavior": norm["expected_behavior"],
        "case_type": norm["case_type"],
        "risk_tier": norm["risk_tier"],
        "reference_output": norm["reference_output"],
        "allowed_variants": allowed_variants_for(norm["behavior"]),
    }


def coerce_new_score(raw: dict, has_production: bool) -> dict:
    """Validate/repair one new-system score object into a known shape."""
    verdict = raw.get("verdict")
    if verdict not in NEW_VERDICTS:
        verdict = "major_fail"  # unparseable judgement is a fail, never a silent pass
    # Verdict and severity are two readings of one judgement, so they are
    # reconciled here rather than validated independently. Validating them
    # separately let a plausible-but-malformed response carry a mismatched pair
    # all the way to the report: `verdict: "pass", severity: "S4"` passed both
    # checks, counted as a pass, and left the zero-S4 gate reporting no critical
    # failure on a case the judge had marked critical. Measured on the #1950
    # judgements, 2 of 315 scored cases came back mismatched, so this is a shape
    # the judge really produces — those two were the harmless direction, and
    # nothing prevents the other one.
    #
    # A mismatch resolves to the MORE SEVERE of the two readings. Neither is
    # trustworthy once they disagree, and this is a quality gate, so the safe
    # direction is the pessimistic one.
    implied_by_verdict = {"pass": "S0", "minor": "S1", "soft_fail": "S2",
                          "major_fail": "S3", "critical_fail": "S4"}
    verdict_for_severity = {v: k for k, v in implied_by_verdict.items()}
    severity_rank = {"S0": 0, "S1": 1, "S2": 2, "S3": 3, "S4": 4}

    sev = raw.get("severity")
    if sev not in NEW_SEVERITIES:
        sev = implied_by_verdict[verdict]
    elif sev != implied_by_verdict[verdict]:
        if severity_rank[sev] > severity_rank[implied_by_verdict[verdict]]:
            verdict = verdict_for_severity[sev]
        else:
            sev = implied_by_verdict[verdict]
    pw = raw.get("pairwise_vs_production")
    if pw not in PAIRWISE_VALUES:
        pw = "not_available"
    if not has_production:
        pw = "not_available"
    ftypes = raw.get("failure_types") or []
    if not isinstance(ftypes, list):
        ftypes = [str(ftypes)]
    ftypes = [f for f in ftypes if f in NEW_FAILURE_TYPES]
    changed = raw.get("changed_or_missing_content") or []
    if not isinstance(changed, list):
        changed = [str(changed)]
    return {
        "verdict": verdict,
        "severity": sev,
        "behavior_correct": _as_bool(raw.get("behavior_correct"), default=False),
        "meaning_preserved": _as_bool(raw.get("meaning_preserved"), default=False),
        "restraint_correct": _as_bool(raw.get("restraint_correct"), default=False),
        "clean_output": _as_bool(raw.get("clean_output"), default=False),
        "pairwise_vs_production": pw,
        "failure_types": ftypes,
        "changed_or_missing_content": changed,
        "rationale": str(raw.get("rationale", ""))[:300],
    }


SEVERITY_RANK = {s: i for i, s in enumerate(NEW_SEVERITIES)}  # S0=0 ... S4=4


def _worse_new_score(a: dict, b: dict) -> dict:
    """Conservative reconciliation: on a primary-vs-adjudication disagreement,
    keep whichever score is MORE severe. Never let a second look silently soften
    a caught failure — the failure-mode this guards is the judge being lenient
    on the re-check, not strict."""
    return a if SEVERITY_RANK[a["severity"]] >= SEVERITY_RANK[b["severity"]] else b


def select_adjudication_ids(primary: dict[str, dict], has_production: bool,
                            sample_pct: float, sample_min: int,
                            rng: random.Random) -> list[str]:
    """Every S3/S4 and critical_loss case is re-judged automatically (that's
    where a wrong grade matters most); everything else gets a random calibration
    sample so we still have a wobble/agreement signal on the easy majority."""
    severe = [cid for cid, s in primary.items()
              if s["severity"] in ("S3", "S4")
              or (has_production and s["pairwise_vs_production"] == "critical_loss")]
    rest = [cid for cid in primary if cid not in set(severe)]
    sample_n = max(sample_min, round(len(rest) * sample_pct)) if rest else 0
    sample_n = min(sample_n, len(rest))
    sample = rng.sample(rest, sample_n) if sample_n else []
    return severe + sample


def score_new(norm_cases: dict, cands: dict, prod: dict | None,
              judge: str, chunk_size: int,
              external_verdicts: dict | None,
              adjudicate_pct: float = DEFAULT_ADJUDICATE_PCT,
              adjudicate_min: int = DEFAULT_ADJUDICATE_MIN,
              adjudicate: bool = True) -> dict:
    """Run (or ingest) the behavior-aware judge and aggregate. Returns the full
    report dict. Cases with no candidate or an engine error are recorded as
    infra-skips (NOT scored as fails — an engine error is not a grading signal).

    Single primary pass over every case, then a targeted second look (selective
    adjudication) at the cases most likely to matter — real failures (S3/S4) plus
    a random calibration sample of the rest — instead of double-judging the whole
    corpus. On disagreement the MORE SEVERE score wins (never silently soften a
    caught failure). This replaces the old full-corpus double-replication design
    (#1199 speed pass, 2026-06-30) — see polish-eval.md FACT: type-b-grading-harness."""
    has_production = prod is not None
    judged_ids, skipped = partition_candidates(norm_cases, cands)

    # Both branches reconcile through the same helper, so `judge_reconciliation`
    # is present on every path and the finalizer never special-cases a mode.
    if external_verdicts is not None:
        # Subagent-supplied verdicts: no judge calls, nothing to adjudicate.
        primary_batch = reconcile_judge_batch(external_verdicts, judged_ids)
        adjudication_batch = reconcile_judge_batch({}, [])
        primary = {cid: coerce_new_score(s, has_production)
                  for cid, s in primary_batch.accepted.items()}
        primary_premerge = dict(primary)
        adjudication: dict[str, dict] = {}
        rep_scores = [primary]
        disagreements: list[dict] = []
        adjudicated_ids: list[str] = []
    else:
        payloads = [build_new_payload(norm_cases[cid], cands[cid],
                                      prod.get(cid) if prod else None)
                    for cid in judged_ids]
        print(f"[new] primary pass over {len(payloads)} cases", file=sys.stderr)
        primary_batch = run_judge(judge, NEW_JUDGE_SYSTEM, payloads, chunk_size)
        primary = {cid: coerce_new_score(s, has_production)
                  for cid, s in primary_batch.accepted.items()}

        adjudicated_ids = []
        adjudication = {}
        adjudication_batch = reconcile_judge_batch({}, [])
        disagreements = []
        # Frozen BEFORE the merge below. `rep_scores[0]` must be the ORIGINAL
        # primary: the merge rebinds `primary[cid]` to the worse of the two
        # scores, so using the merged dict as rep1 compares adjudication against
        # itself wherever adjudication was the more severe reading — which is the
        # only case that changes anything. Measured pre-fix: 12 of 12 cases
        # disagreeing still reported delta_pp 0.0 and judge_stable PASS.
        primary_premerge = dict(primary)
        if adjudicate and primary:
            rng = random.Random(1199)  # fixed seed: reproducible sample across runs
            adjudicated_ids = select_adjudication_ids(
                primary, has_production, adjudicate_pct, adjudicate_min, rng)
            if adjudicated_ids:
                print(f"[new] adjudication pass over {len(adjudicated_ids)} cases "
                      f"({len(adjudicated_ids)*100//max(len(primary),1)}% of primary)",
                      file=sys.stderr)
                adj_payloads = [p for p in payloads if p["id"] in set(adjudicated_ids)]
                adjudication_batch = run_judge(judge, NEW_JUDGE_SYSTEM, adj_payloads, chunk_size)
                adjudication = {cid: coerce_new_score(s, has_production)
                                for cid, s in adjudication_batch.accepted.items()}
                for cid, adj_score in adjudication.items():
                    if cid not in primary:
                        continue
                    if primary[cid]["severity"] != adj_score["severity"] or \
                       primary[cid]["verdict"] != adj_score["verdict"]:
                        disagreements.append({
                            "id": cid,
                            "primary_verdict": primary[cid]["verdict"],
                            "adjudication_verdict": adj_score["verdict"],
                            "resolved_verdict": _worse_new_score(primary[cid], adj_score)["verdict"],
                        })
                    primary[cid] = _worse_new_score(primary[cid], adj_score)
        rep_scores = [primary_premerge, adjudication] if adjudicated_ids else [primary]

    missing = primary_batch.missing

    per_case = []
    for cid in judged_ids:
        if cid not in primary:
            continue
        s = primary[cid]
        per_case.append({**norm_cases[cid], **s,
                         "candidate_output": cands[cid].get("candidate"),
                         "latencyMs": cands[cid].get("latencyMs")})

    report = aggregate_new(per_case, rep_scores, judged_ids, has_production,
                           missing_count=len(missing), skipped_count=len(skipped),
                           adjudication_missing_count=len(adjudication_batch.missing))
    report["skipped"] = skipped
    report["missing_scores"] = missing
    report["per_case"] = per_case
    # The evidence `finalize_new_report` validates. It runs at `write_outputs`,
    # by which point `judged_ids` and the score dicts are gone.
    report["judge_reconciliation"] = {
        "primary": batch_counts(primary_batch, len(judged_ids)),
        "adjudication": batch_counts(adjudication_batch, len(adjudicated_ids)),
    }
    report["adjudication"] = {
        # SELECTED, not re-judged. Meaning deliberately unchanged: receipts on
        # disk already encode it this way (runs/ollama-bench-1950/judged/
        # gemma2-local/summary.json), and #1950 compares across them.
        "adjudicated_n": len(adjudicated_ids),
        "rejudged_n": len(adjudication),
        "adjudication_missing_n": len(adjudication_batch.missing),
        "adjudication_missing": adjudication_batch.missing[:25],
        "unexpected_n": len(adjudication_batch.unexpected),
        # Denominator is the PRIMARY size, not the corpus total, so the name
        # overstates its own scope on a primary drop. Both terms are stored so a
        # reader can see what the percentage is actually of.
        "adjudicated_pct_of_total": round(100 * len(adjudicated_ids) / len(primary), 1) if primary else 0.0,
        "pct_numerator": len(adjudicated_ids),
        "pct_denominator": len(primary),
        "disagreement_n": len(disagreements),
        "disagreements": disagreements[:25],
    }
    return report


def _is_pass(verdict: str) -> bool:
    return verdict in SHIPPABLE_VERDICTS


def aggregate_new(per_case: list[dict], rep_scores: list[dict], judged_ids: list[str],
                  has_production: bool, missing_count: int = 0, skipped_count: int = 0,
                  adjudication_missing_count: int = 0) -> dict:
    total = len(per_case)

    def rate(items, pred):
        n = len(items)
        return round(100 * sum(1 for x in items if pred(x)) / n, 1) if n else 0.0

    overall = {
        "total_scored": total,
        "infra_skipped": None,  # filled by caller
        "pass_rate_pct": rate(per_case, lambda x: _is_pass(x["verdict"])),
        "soft_fail_pct": rate(per_case, lambda x: x["verdict"] == "soft_fail"),
        "major_fail_pct": rate(per_case, lambda x: x["verdict"] == "major_fail"),
        # Counted from SEVERITY, which is what the report's zero-S4 gate is
        # actually about. `coerce_new_score` now guarantees the two readings
        # agree, so this is the same number by either route — stated in the
        # gate's own terms so a future divergence cannot quietly reopen the hole.
        "critical_fail_count": sum(1 for x in per_case if x["severity"] == "S4"),
        "verdict_breakdown": dict(Counter(x["verdict"] for x in per_case)),
        "severity_breakdown": dict(Counter(x["severity"] for x in per_case)),
        "failure_type_counts": dict(Counter(f for x in per_case for f in x["failure_types"]).most_common()),
    }

    # Per behavior.
    by_behavior: dict[str, list] = defaultdict(list)
    for x in per_case:
        by_behavior[x["behavior"]].append(x)
    per_behavior = {}
    for b, items in sorted(by_behavior.items()):
        per_behavior[b] = {
            "n": len(items),
            "pass_rate_pct": rate(items, lambda x: _is_pass(x["verdict"])),
            "s3_count": sum(1 for x in items if x["severity"] == "S3"),
            "s4_count": sum(1 for x in items if x["severity"] == "S4"),
            "top_failure_types": dict(Counter(f for x in items for f in x["failure_types"]).most_common(5)),
        }

    # Trap metrics — restraint. A trap fails when the model applied the behavior
    # (behavior_correct=False on a trap == took the bait).
    traps = [x for x in per_case if x["case_type"] == "trap"]
    trap_metrics = {
        "n": len(traps),
        "trap_pass_rate_pct": rate(traps, lambda x: _is_pass(x["verdict"])),
        "false_positive_pct": rate(traps, lambda x: not x["behavior_correct"]),
        "by_behavior": {b: {
            "n": len([x for x in traps if x["behavior"] == b]),
            "false_positive_pct": rate([x for x in traps if x["behavior"] == b],
                                       lambda x: not x["behavior_correct"]),
        } for b in sorted({x["behavior"] for x in traps})},
    }

    # Passthrough safety — obeyed an instruction?
    passthrough = [x for x in per_case if x["case_type"] == "passthrough"]
    safety = {
        "n": len(passthrough),
        "verbatim_execution_count": sum(1 for x in passthrough if "verbatim_execution" in x["failure_types"]),
    }

    # Mixed (real-world multi-behavior).
    mixed = [x for x in per_case if x["case_type"] == "mixed"]
    mixed_metrics = {
        "n": len(mixed),
        "pass_rate_pct": rate(mixed, lambda x: _is_pass(x["verdict"])),
        "s3_s4_count": sum(1 for x in mixed if x["severity"] in ("S3", "S4")),
    }

    # Critical smoke = every critical-risk case; the S4/critical-loss gate.
    smoke = [x for x in per_case if x["risk_tier"] == "critical"]
    smoke_metrics = {
        "n": len(smoke),
        "s4_count": sum(1 for x in smoke if x["severity"] == "S4"),
        "critical_loss_count": sum(1 for x in smoke if x["pairwise_vs_production"] == "critical_loss"),
        "pass_rate_pct": rate(smoke, lambda x: _is_pass(x["verdict"])),
    }

    # Pairwise vs production.
    if has_production:
        pw = Counter(x["pairwise_vs_production"] for x in per_case)
        pairwise = {k: pw.get(k, 0) for k in PAIRWISE_VALUES}
        pairwise["net_wins"] = pairwise["win"] - pairwise["loss"]
    else:
        pairwise = {"status": "not_available (no --production file supplied)"}

    # Wobble — pass-rate delta across replications, measured over the SAME id set
    # (the cases BOTH reps returned) so the two rates share a denominator; per-rep
    # coverage is surfaced so a rep that dropped cases is visible, not hidden.
    if len(rep_scores) >= 2:
        judged_set = set(judged_ids)
        common = [cid for cid in judged_ids if cid in rep_scores[0] and cid in rep_scores[1]]
        coverage = [len(judged_set & set(rs)) for rs in rep_scores]

        if not common:
            # Nothing was returned by both replications, so there is no stability
            # answer to give. Reporting delta 0.0 / unreliable False here is what
            # let an adjudication that returned NOTHING add `judge_stable: PASS`
            # on zero compared cases (#2007). Omitting `unreliable` makes
            # `evaluate_new_gate`'s existing `is not None` guard SKIP the check
            # rather than invent a passing one — the completeness term below is
            # what actually refuses the run.
            wobble = {"status": "no comparable cases (no id returned by both replications)",
                      "common_n": 0, "rep_coverage": coverage}
        else:
            def pr(scores):
                return round(100 * sum(1 for cid in common if _is_pass(scores[cid]["verdict"])) / len(common), 1)
            r1, r2 = pr(rep_scores[0]), pr(rep_scores[1])
            wobble = {
                "common_n": len(common),
                "rep1_pass_rate_pct": r1,
                "rep2_pass_rate_pct": r2,
                "delta_pp": round(abs(r1 - r2), 1),
                "unreliable": abs(r1 - r2) > REP_PASSRATE_DELTA_MAX,
                "rep_coverage": coverage,
            }
    else:
        wobble = {"status": "single replication (no wobble check)"}

    # Release gate — apply the conditions for which we have data.
    gate = evaluate_new_gate(overall, smoke_metrics, trap_metrics, wobble, pairwise,
                             has_production, missing_count, skipped_count,
                             adjudication_missing_count)

    return {
        "system": "new",
        # Completeness on its own, independent of the verdict. `BLOCK` takes
        # precedence over `INCOMPLETE`, so the verdict alone cannot express
        # "failed AND partial" — which is why keying a cache on it is wrong.
        "run_complete": gate["run_complete"],
        "overall": overall,
        "per_behavior": per_behavior,
        "trap_metrics": trap_metrics,
        "passthrough_safety": safety,
        "mixed_metrics": mixed_metrics,
        "critical_smoke": smoke_metrics,
        "pairwise": pairwise,
        "wobble": wobble,
        "release_gate": gate,
    }


def evaluate_new_gate(overall, smoke, traps, wobble, pairwise, has_production,
                      missing_count=0, skipped_count=0,
                      adjudication_missing_count=0) -> dict:
    """Apply the proposed release gate. Three-valued verdict:
      BLOCK      — a quality check FAILED (S4 / wobble / pairwise).
      INCOMPLETE — quality clean but the run did not cover every case (engine
                   skips or judge-dropped scores); re-run the gaps, do not ship.
      CLEAR      — quality clean AND full coverage.
    Conditions needing a production baseline are reported N/A, never silently
    passed. Completeness is tracked separately from quality so the founder can
    tell 'just re-run the missing cases' from 'real quality failure'."""
    quality_checks = []

    def add(name, ok, detail):
        quality_checks.append({"check": name, "status": "PASS" if ok else "FAIL", "detail": detail})

    add("critical_smoke_no_s4", smoke["s4_count"] == 0,
        f"{smoke['s4_count']} S4 in {smoke['n']} critical-smoke cases (limit 0)")
    add("full_corpus_no_s4", overall["critical_fail_count"] == 0,
        f"{overall['critical_fail_count']} S4 across full corpus (limit 0; waiver needs founder sign-off)")
    if wobble.get("unreliable") is not None:
        add("judge_stable", not wobble["unreliable"],
            f"rep pass-rate delta {wobble.get('delta_pp')}pp (limit {REP_PASSRATE_DELTA_MAX}pp)")
    if has_production:
        add("critical_smoke_no_critical_loss", smoke["critical_loss_count"] == 0,
            f"{smoke['critical_loss_count']} critical_loss in critical-smoke (limit 0)")
        add("pairwise_net_positive", pairwise.get("net_wins", 0) > 0,
            f"net wins {pairwise.get('net_wins')} (must be > 0)")
    else:
        quality_checks.append({"check": "pairwise_vs_production", "status": "N/A",
                               "detail": "no --production baseline supplied"})

    # An adjudication drop is a COVERAGE gap, not a quality failure: routing it
    # into `quality_checks` would report BLOCK and tell the reader a transient
    # judge omission was a quality regression. This gate's own contract keeps the
    # two separate so "re-run the gaps" is distinguishable from "real failure".
    complete = (missing_count == 0 and skipped_count == 0
                and adjudication_missing_count == 0)
    completeness = {"check": "run_complete", "status": "PASS" if complete else "INCOMPLETE",
                    "detail": f"{skipped_count} engine-skipped, {missing_count} judge-dropped, "
                              f"{adjudication_missing_count} adjudication-dropped "
                              f"(all must be 0 to ship; re-run the gaps)"}

    blocking = [c for c in quality_checks if c["status"] == "FAIL"]
    if blocking:
        verdict = "BLOCK"
    elif not complete:
        verdict = "INCOMPLETE"
    else:
        verdict = "CLEAR"
    return {
        "verdict": verdict,
        "run_complete": complete,
        "checks": quality_checks + [completeness],
        "note": ("Behavior-regression, trap-regression and mixed-regression checks "
                 "require a prior run to diff against; run two builds to enable them."),
    }


# ---------------------------------------------------------------------------
# OLD 5-axis grading system — verbatim from run_provider_judge.py / acceptance_
# gate.py, replayed over the SAME candidate file for a faithful A/B.
# ---------------------------------------------------------------------------

OLD_ABSOLUTE_AXES = ("accuracy", "conciseness", "fluency", "format")
OLD_MIN_ABSOLUTE = 2
OLD_MIN_REGRESSION = 1
OLD_BATCH_PASS_THRESHOLD = 0.90

# Verbatim from run_provider_judge.py JUDGE_SYSTEM (lines 40-57).
OLD_JUDGE_SYSTEM = """You are a polish evaluation judge. Score each candidate polish vs baseline on 5 integer axes (0-3).

The baseline is the raw ASR transcript (lowercase, no punctuation, with fillers). The candidate is one polish provider's attempt to clean it.

AXES:
- accuracy: meaning + named entities preserved from the baseline (3=perfect, 0=lost/hallucinated/invented content)
- conciseness: fillers removed, no over-editing or under-editing (3=right amount, 0=way off in either direction)
- fluency: grammar + natural flow of polished output (3=fluent, 0=broken)
- format: no preamble, clean output only (3=clean, 0=adds "Here's the polish:" or similar wrapper)
- regression: how much better is candidate than the raw baseline? (0=worse than raw, 1=similar to raw, 2=slightly better, 3=clearly better)

OUTPUT: JSON array ONLY. No preamble. No markdown fences. No trailing text.
Each item: {"id":"<case_id>","accuracy":N,"conciseness":N,"fluency":N,"format":N,"regression":N,"reasoning":"<one sentence, 15 words max>"}

RULES:
- Integer 0-3 only. Never 0.5, never 4.
- reasoning: ONE sentence, 15 words max. Never "Let me analyze..." or "First,..."
- Nothing outside the JSON array."""


def build_old_payload(norm: dict, cand: dict) -> dict:
    # Old system judges candidate vs the RAW transcript only.
    return {"id": norm["id"], "baseline": norm["raw_transcript"],
            "candidate": cand.get("candidate") or ""}


def coerce_old_score(raw: dict) -> dict:
    def axis(k):
        v = raw.get(k, 0)
        try:
            v = int(v)
        except (TypeError, ValueError):
            v = 0
        return max(0, min(3, v))
    return {a: axis(a) for a in OLD_ABSOLUTE_AXES + ("regression",)}


def score_old(norm_cases: dict, cands: dict, judge: str, reps: int, chunk_size: int) -> dict:
    judged_ids, skipped = partition_candidates(norm_cases, cands)
    payloads = [build_old_payload(norm_cases[cid], cands[cid]) for cid in judged_ids]

    rep_scores: list[dict[str, dict]] = []
    for rep in range(reps):
        print(f"[old] replication {rep+1}/{reps} over {len(payloads)} cases", file=sys.stderr)
        # Routed through the same boundary. Behaviour-preserving: this call site
        # already filtered returned ids to `judged_ids` by hand, and `accepted` is
        # that same set. The point is that the filter is no longer optional.
        batch = run_judge(judge, OLD_JUDGE_SYSTEM, payloads, chunk_size)
        rep_scores.append({cid: coerce_old_score(s) for cid, s in batch.accepted.items()})

    primary = rep_scores[0]
    missing = [cid for cid in judged_ids if cid not in primary]

    per_case = []
    pass_count = 0
    for cid in judged_ids:
        if cid not in primary:
            continue
        s = primary[cid]
        absolute_ok = all(s[a] >= OLD_MIN_ABSOLUTE for a in OLD_ABSOLUTE_AXES)
        reg_ok = s["regression"] >= OLD_MIN_REGRESSION
        passed = absolute_ok and reg_ok
        pass_count += 1 if passed else 0
        reasons = [] if passed else (
            [f"{a}={s[a]}<{OLD_MIN_ABSOLUTE}" for a in OLD_ABSOLUTE_AXES if s[a] < OLD_MIN_ABSOLUTE]
            + ([f"regression={s['regression']}<{OLD_MIN_REGRESSION}"] if not reg_ok else []))
        per_case.append({**norm_cases[cid], **s, "passed": passed, "fail_reasons": reasons,
                         "candidate_output": cands[cid].get("candidate")})

    total = len(per_case)
    pct = (pass_count / total) if total else 0.0

    # Per behavior + per-axis means.
    by_behavior: dict[str, list] = defaultdict(list)
    for x in per_case:
        by_behavior[x["behavior"]].append(x)
    per_behavior = {}
    for b, items in sorted(by_behavior.items()):
        per_behavior[b] = {
            "n": len(items),
            "pass_rate_pct": round(100 * sum(1 for x in items if x["passed"]) / len(items), 1),
            "axis_means": {a: round(mean(x[a] for x in items), 2)
                           for a in OLD_ABSOLUTE_AXES + ("regression",)},
        }

    wobble = {"status": "single replication (no wobble check)"}
    if len(rep_scores) >= 2:
        def pr(scores):
            ids = [cid for cid in judged_ids if cid in scores]
            if not ids:
                return 0.0
            p = sum(1 for cid in ids
                    if all(scores[cid][a] >= OLD_MIN_ABSOLUTE for a in OLD_ABSOLUTE_AXES)
                    and scores[cid]["regression"] >= OLD_MIN_REGRESSION)
            return round(100 * p / len(ids), 1)
        r1, r2 = pr(rep_scores[0]), pr(rep_scores[1])
        wobble = {"rep1_pass_rate_pct": r1, "rep2_pass_rate_pct": r2,
                  "delta_pp": round(abs(r1 - r2), 1),
                  "unreliable": abs(r1 - r2) > REP_PASSRATE_DELTA_MAX}

    return {
        "system": "old",
        "overall": {
            "total_scored": total,
            "pass_count": pass_count,
            "pass_rate_pct": round(100 * pct, 1),
            "batch_threshold_pct": OLD_BATCH_PASS_THRESHOLD * 100,
            "batch_verdict": "PASS" if pct >= OLD_BATCH_PASS_THRESHOLD else "FAIL",
            "axis_means": {a: round(mean(x[a] for x in per_case), 2) for a in OLD_ABSOLUTE_AXES + ("regression",)}
            if per_case else {},
        },
        "per_behavior": per_behavior,
        "wobble": wobble,
        "skipped": skipped,
        "missing_scores": missing,
        "per_case": per_case,
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def finalize_new_report(report: dict) -> None:
    """Set `report["cacheable"]` — the single acceptance decision BOTH consumers read.

    Why a dedicated field rather than the verdict: `evaluate_new_gate` gives a
    quality failure precedence over incompleteness, so a run that is both
    quality-failed AND missing coverage reports `BLOCK`. Any cache or ranking rule
    keyed on the verdict therefore treats a partial receipt as complete — which is
    the #2008 defect, and was also the first version of its fix.

    This never rewrites the verdict. Operators read that, and BLOCK-first is right
    for them; only cacheability stops being derived from it.

    The double computation of completeness is DELIBERATE. `evaluate_new_gate`
    answers from the counts it was handed; this answers from what was actually
    written into the receipt, then requires the two to AGREE. That is an
    independent oracle — one sharing its subject's implementation would only prove
    the code equals itself. Do not DRY these into one expression.
    """
    try:
        rec = report["judge_reconciliation"]
        primary, adjudication = rec["primary"], rec["adjudication"]
        adj = report["adjudication"]
        overall = report["overall"]
        # Required reads, never `.get(..., [])`: a defaulted read lets an ABSENT
        # field masquerade as an empty list, which is the same narrower-than-it-
        # looks shape this change exists to close. A missing key raises and lands
        # in the fail-closed handler below.
        skipped = report["skipped"]
        per_case = report["per_case"]
        # Mirrors evaluate_new_gate's own `complete`, so the assertion below is a
        # genuine cross-check of the gate's answer.
        expected_complete = (
            isinstance(skipped, list)
            and not skipped
            and primary["missing_n"] == 0
            and adjudication["missing_n"] == 0
        )
        # Cacheability is a DIFFERENT question from completeness, and conflating
        # them created an endless re-judge loop. An engine error is a terminal
        # fact about the model — it produced nothing to grade — and no amount of
        # re-judging repairs it, so a receipt carrying accounted engine skips is a
        # FINISHED answer. `report_ollama_bench.py` relies on that: it ranks a
        # partially-erroring model "Not recommended" on the grounds that "a
        # partial failure IS evidence". Refusing to cache such a receipt would
        # both re-judge it on every invocation and make that ranking unreachable.
        #
        # Only DROPPED JUDGE WORK makes a receipt provisional, because that is the
        # only part a re-judge can actually fix.
        judge_work_complete = (
            primary["missing_n"] == 0 and adjudication["missing_n"] == 0
        )
        denominator = adj["pct_denominator"]
        expected_pct = round(100 * adj["pct_numerator"] / denominator, 1) if denominator else 0.0
        valid = (
            primary["requested_n"] == primary["accepted_n"] + primary["missing_n"]
            and adjudication["requested_n"] == adjudication["accepted_n"] + adjudication["missing_n"]
            and isinstance(per_case, list)
            and len(per_case) == overall["total_scored"] == primary["accepted_n"]
            and adj["adjudicated_n"] == adjudication["requested_n"]
            and adj["rejudged_n"] == adjudication["accepted_n"]
            and adj["adjudication_missing_n"] == adjudication["missing_n"]
            and adj["adjudicated_pct_of_total"] == expected_pct
            and report.get("run_complete") is expected_complete
        )
    except (KeyError, TypeError, ZeroDivisionError):
        valid = False
        judge_work_complete = False
    report["cacheable"] = bool(valid and judge_work_complete)


def write_outputs(report: dict, outdir: Path, system: str) -> None:
    # FIRST, and before the `per_case` pop below: this is the non-bypassable
    # output boundary, and the row-count check needs `per_case` still on the
    # report. `old` skips it — that system has no adjudication and no release
    # gate, and nothing consumes `cacheable` for it.
    if system == "new":
        finalize_new_report(report)
    outdir.mkdir(parents=True, exist_ok=True)
    per_case = report.pop("per_case", [])
    if report.get("overall") and report["overall"].get("infra_skipped") is None:
        report["overall"]["infra_skipped"] = len(report.get("skipped", []))

    with open(outdir / "per_case.jsonl", "w") as f:
        for x in per_case:
            f.write(json.dumps(x, ensure_ascii=False) + "\n")
    with open(outdir / "summary.json", "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    with open(outdir / "scoreboard.txt", "w") as f:
        f.write(render_scoreboard(report, system))
    print(f"\n[done] wrote {outdir}/ (per_case.jsonl, summary.json, scoreboard.txt)", file=sys.stderr)
    print("\n" + render_scoreboard(report, system))


def render_scoreboard(r: dict, system: str) -> str:
    L = []
    L.append("=" * 64)
    L.append(f"  POLISH GRADING SCOREBOARD — system: {system.upper()}")
    L.append("=" * 64)
    o = r.get("overall", {})
    if system == "old":
        L.append(f"Cases scored : {o.get('total_scored')}   (infra-skipped: {len(r.get('skipped', []))})")
        L.append(f"Pass rate    : {o.get('pass_rate_pct')}%   "
                 f"batch {o.get('batch_verdict')} (threshold {o.get('batch_threshold_pct')}%)")
        am = o.get("axis_means", {})
        L.append(f"Axis means   : " + "  ".join(f"{a}={am.get(a)}" for a in
                                                 OLD_ABSOLUTE_AXES + ("regression",)))
        L.append("")
        L.append("Per behavior (pass% | axis means):")
        for b, m in r.get("per_behavior", {}).items():
            am = m["axis_means"]
            L.append(f"  {b:24} n={m['n']:>3}  {m['pass_rate_pct']:>5}%  "
                     + " ".join(f"{a[:4]}={am[a]}" for a in OLD_ABSOLUTE_AXES + ("regression",)))
    else:
        L.append(f"Cases scored : {o.get('total_scored')}   (infra-skipped: {o.get('infra_skipped')})")
        L.append(f"Pass rate    : {o.get('pass_rate_pct')}%  (pass+minor)")
        L.append(f"Soft fails   : {o.get('soft_fail_pct')}%   Major fails: {o.get('major_fail_pct')}%")
        L.append(f"CRITICAL (S4): {o.get('critical_fail_count')}")
        L.append(f"Verdicts     : {o.get('verdict_breakdown')}")
        L.append(f"Top failures : {dict(list(o.get('failure_type_counts', {}).items())[:8])}")
        L.append("")
        L.append("Per behavior (pass% | S3 | S4):")
        for b, m in r.get("per_behavior", {}).items():
            L.append(f"  {b:24} n={m['n']:>3}  {m['pass_rate_pct']:>5}%   S3={m['s3_count']:>2} S4={m['s4_count']:>2}")
        tm = r.get("trap_metrics", {})
        L.append("")
        L.append(f"TRAPS        : n={tm.get('n')}  pass={tm.get('trap_pass_rate_pct')}%  "
                 f"false-positive (took the bait)={tm.get('false_positive_pct')}%")
        sm = r.get("critical_smoke", {})
        L.append(f"CRIT SMOKE   : n={sm.get('n')}  pass={sm.get('pass_rate_pct')}%  "
                 f"S4={sm.get('s4_count')}  critical_loss={sm.get('critical_loss_count')}")
        mm = r.get("mixed_metrics", {})
        L.append(f"MIXED        : n={mm.get('n')}  pass={mm.get('pass_rate_pct')}%  S3+S4={mm.get('s3_s4_count')}")
        ps = r.get("passthrough_safety", {})
        L.append(f"SAFETY       : passthrough n={ps.get('n')}  obeyed-instruction={ps.get('verbatim_execution_count')}")
        L.append(f"PAIRWISE     : {r.get('pairwise')}")
        adj = r.get("adjudication")
        if adj:
            # `adjudicated_n` is cases SELECTED. Saying "re-judged" of it was the
            # #2007 mislabel: with an empty adjudication it claimed a recheck of
            # every selected case while none came back.
            line = (f"ADJUDICATION : selected {adj['adjudicated_n']}, "
                    f"re-judged {adj.get('rejudged_n', adj['adjudicated_n'])}"
                    f" ({adj['adjudicated_pct_of_total']}% of primary)  "
                    f"disagreements={adj['disagreement_n']}")
            if adj.get("adjudication_missing_n"):
                line += f"  DROPPED={adj['adjudication_missing_n']}"
            if adj.get("unexpected_n"):
                line += f"  unexpected={adj['unexpected_n']}"
            L.append(line)
        if r.get("cacheable") is False:
            L.append("CACHEABLE    : NO — this receipt is partial or internally "
                     "inconsistent; it must not be cached or ranked")
        g = r.get("release_gate", {})
        L.append("")
        L.append(f"RELEASE GATE : {g.get('verdict')}")
        for c in g.get("checks", []):
            L.append(f"  [{c['status']:>4}] {c['check']}: {c['detail']}")
    w = r.get("wobble", {})
    L.append("")
    L.append(f"Judge wobble : {w}")
    missed = r.get("missing_scores", [])
    if missed:
        L.append(f"JUDGE MISSED : {len(missed)} case(s) returned no score (NOT counted above): "
                 f"{missed[:10]}{' ...' if len(missed) > 10 else ''}")
    L.append("=" * 64)
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    # Handled BEFORE argparse deliberately: `--corpus`, `--candidates` and `--out` are all
    # required, so a caller that only wants to know which judge is configured would have to
    # invent three paths to ask. Callers use this to VALIDATE the judge before touching any
    # stored receipt — `judge_ollama_bench.sh` deletes a receipt whose stamp no longer
    # matches, so a refused or mistyped EW_JUDGE would otherwise delete the whole cached set
    # and then exit before writing replacements. Exits 2 with a reason instead.
    #
    # Prints two lines: the judge id, then its stamp identity. Two lines rather than one so
    # the caller does not have to split on a separator that could appear inside either value.
    if "--print-judge-identity" in sys.argv:
        try:
            identity = judge_identity(DEFAULT_JUDGE)
        except Exception as e:
            print(f"judge {DEFAULT_JUDGE!r} is unusable: {e}", file=sys.stderr)
            return 2
        print(DEFAULT_JUDGE)
        print(identity)
        # Third line: the model version this probe observed, empty for non-Azure routes. The
        # sweep exports it so every arm verifies against the SWEEP's model rather than its own
        # probe. Without it each arm process probed independently, so a repoint between arms left
        # every process self-consistent while the shell stamped them all with the first arm's
        # identity — arms graded by different models sharing one stamp. Cloud review found it.
        print(_azure_pinned_model or "")
        return 0

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--system", choices=("new", "old"), default="new",
                    help="grading system to apply (default: new behavior-aware)")
    ap.add_argument("--corpus", nargs="+", required=True,
                    help="case file(s): per-behavior *_v1.jsonl or the consolidated export")
    ap.add_argument("--candidates", required=True,
                    help="engine output JSONL ({id, candidate, error?, latencyMs?})")
    ap.add_argument("--production", default=None,
                    help="(new only) shipped-engine output JSONL for pairwise; absent -> not_available")
    ap.add_argument("--verdicts", default=None,
                    help="(new only) pre-computed per-case verdicts JSONL; skip the judge, just aggregate")
    ap.add_argument("--judge", default=DEFAULT_JUDGE,
                    help=f"judge model id (default {DEFAULT_JUDGE}); "
                         f"azure/<deployment>->Azure credits, claude*/sonnet*->CLI $0. "
                         f"Any other id is REFUSED: no approved funded route matches it")
    ap.add_argument("--reps", type=int, default=DEFAULT_REPLICATIONS,
                    help=f"(old system only) full-corpus judge replications (default {DEFAULT_REPLICATIONS})")
    ap.add_argument("--adjudicate-pct", type=float, default=DEFAULT_ADJUDICATE_PCT,
                    help=f"(new system) fraction of non-severe cases re-judged for calibration "
                         f"(default {DEFAULT_ADJUDICATE_PCT})")
    ap.add_argument("--adjudicate-min", type=int, default=DEFAULT_ADJUDICATE_MIN,
                    help=f"(new system) floor on the calibration sample size (default {DEFAULT_ADJUDICATE_MIN})")
    ap.add_argument("--no-adjudicate", action="store_true",
                    help="(new system) single primary pass only, skip the S3/S4 + sample re-judge")
    ap.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    ap.add_argument("--out", required=True, help="output directory")
    args = ap.parse_args()

    if args.reps < 1:
        print("ERROR: --reps must be >= 1", file=sys.stderr)
        return 2
    if args.chunk_size < 1:
        print("ERROR: --chunk-size must be >= 1", file=sys.stderr)
        return 2
    if not (0.0 <= args.adjudicate_pct <= 1.0):
        print("ERROR: --adjudicate-pct must be between 0.0 and 1.0", file=sys.stderr)
        return 2
    if args.adjudicate_min < 0:
        print("ERROR: --adjudicate-min must be >= 0", file=sys.stderr)
        return 2

    corpus_paths = [Path(p) for p in args.corpus]
    for p in corpus_paths + [Path(args.candidates)]:
        if not p.exists():
            print(f"ERROR: missing file {p}", file=sys.stderr)
            return 2

    norm_cases = load_corpus(corpus_paths)
    cands = load_candidates(Path(args.candidates))
    print(f"[load] {len(norm_cases)} corpus cases, {len(cands)} candidate outputs", file=sys.stderr)

    if args.system == "old" and (args.production or args.verdicts):
        print("ERROR: --production / --verdicts are new-system only", file=sys.stderr)
        return 2

    external_verdicts = None
    if args.verdicts:
        vp = Path(args.verdicts)
        if not vp.exists():
            print(f"ERROR: missing verdicts file {vp}", file=sys.stderr)
            return 2
        external_verdicts = {str(r["id"]): r for r in load_jsonl(vp) if "id" in r}
        print(f"[load] {len(external_verdicts)} external verdicts (judge skipped)", file=sys.stderr)

    prod = None
    if args.production:
        pp = Path(args.production)
        if not pp.exists():
            print(f"ERROR: missing production file {pp}", file=sys.stderr)
            return 2
        prod = load_candidates(pp)

    if external_verdicts is None:
        # Billing check BEFORE the availability check: refusing to spend the founder's
        # own money must not depend on whether a CLI happens to be logged in.
        refuse_paid_key_judge(args.judge)
        preflight_judge(args.judge)
        if args.system == "new":
            mode = "single-pass, no adjudication" if args.no_adjudicate else \
                   f"primary + adjudicate(S3/S4 + {args.adjudicate_pct*100:.0f}% sample, min {args.adjudicate_min})"
            # Report the fan-out this judge will actually use. `run_judge` picks per
            # transport (Claude spawns a subprocess each, HTTP judges do not), so
            # printing the Claude cap unconditionally misreported every Azure run.
            workers = (CLAUDE_JUDGE_MAX_WORKERS
                       if judge_transport(args.judge) == "claude"
                       else HTTP_JUDGE_MAX_WORKERS)
            print(f"[judge] {args.judge}  {mode}  chunk={args.chunk_size}  workers={workers}",
                  file=sys.stderr)
        else:
            print(f"[judge] {args.judge}  reps={args.reps}  chunk={args.chunk_size}", file=sys.stderr)

    started = datetime.now(timezone.utc).isoformat()
    if args.system == "new":
        report = score_new(norm_cases, cands, prod, args.judge, args.chunk_size,
                           external_verdicts, args.adjudicate_pct, args.adjudicate_min,
                           adjudicate=not args.no_adjudicate)
    else:
        report = score_old(norm_cases, cands, args.judge, args.reps, args.chunk_size)

    report["meta"] = {
        "system": args.system,
        "judge": args.judge if external_verdicts is None else "external_verdicts",
        # The MODEL VERSION that graded, when the transport can tell us. The judge id alone is
        # not identity: an Azure deployment can be repointed in place, so two receipts can share
        # `judge` and hold scores from different models. Recorded IN the receipt rather than only
        # in the sidecar stamp because the report reads receipts, not stamps, and a consumer that
        # cannot see the identity cannot refuse to mix it.
        "judge_model_version": _azure_pinned_model,
        # The FULL identity the sweep resolved: judge id plus a digest of the endpoint host, the
        # API version and the served model. Passed in rather than recomputed so every arm records
        # the same value, and so the report can distinguish two Azure resources that serve the
        # same model string — which the id and version alone cannot, even though the resume stamp
        # always could. Empty for a run started outside the sweep, which groups with other such
        # runs rather than pretending to an identity it never resolved.
        "judge_identity": os.environ.get("EW_JUDGE_IDENTITY") or _resolved_judge_identity,
        # WHICH RUBRIC produced this receipt. `judge_identity` answers "who graded
        # it"; this answers "against what bar". Both change what a score MEANS, so
        # both have to travel WITH the receipt — the resume stamp cannot serve this,
        # because an interrupted sweep leaves some arms re-graded and some not, and
        # `report_ollama_bench.py` compares receipts and never reads that sidecar.
        # Cloud review P1 on #2055.
        # Imported verdicts were NOT produced by this scorer, so stamping the local
        # digest on them would assert a provenance that never happened — and two
        # imports graded under different external rubrics would then compare equal
        # because they share this checkout. The judge field one line above already
        # makes exactly this distinction; this is the same rule, not a new one.
        # Cloud review P1 on #2055, third round of the same class.
        # DERIVED, never constant. A bare "external_verdicts" sentinel made every
        # import claim one shared rubric, so two verdict files graded under
        # DIFFERENT external rubrics compared equal and the report ranked them
        # together — the same false claim as stamping the local digest, pointing
        # the other way. Hashing the verdicts file gives identical imports the same
        # identity and different ones different identities, which is what the field
        # is for. Cloud review P1 x4 on #2055; see also the `judge` field above,
        # which still uses a bare sentinel and has the same shape (pre-existing,
        # not touched here).
        # None for imported verdicts, exactly as `judge_identity` is empty for a run
        # started outside the sweep: unknown provenance groups with unknown
        # provenance rather than pretending to an identity it never resolved.
        #
        # Five review rounds reached this. Every invented alternative was worse:
        # the local digest CLAIMED a rubric the import never ran under; a constant
        # sentinel made two DIFFERENT external rubrics compare equal; hashing the
        # verdicts file made two arms under the SAME rubric compare different,
        # because verdict files differ by candidate outcome, which broke multi-arm
        # external grading entirely.
        #
        # ACCEPTED LIMIT, stated rather than papered over: two imports graded under
        # genuinely different external rubrics both report None and will be ranked
        # together. That is the same accepted limit `judge_identity` already
        # carries for legacy receipts, and the harness cannot close it without a
        # rubric identifier the verdicts file does not contain. Supplying one is a
        # separate change with its own flag.
        "rubric_identity": _rubric_identity() if external_verdicts is None else None,
        "reps": args.reps if args.system == "old" else None,
        "adjudicate_pct": args.adjudicate_pct if args.system == "new" else None,
        "adjudicate_min": args.adjudicate_min if args.system == "new" else None,
        "corpus_files": [p.name for p in corpus_paths],
        "candidates_file": Path(args.candidates).name,
        "production_file": Path(args.production).name if args.production else None,
        "started_utc": started,
        "finished_utc": datetime.now(timezone.utc).isoformat(),
    }
    write_outputs(report, Path(args.out), args.system)

    # Exit code: new -> gate verdict AND cacheability; old -> batch verdict.
    # (0 clear/pass, 1 block/fail.) `cacheable` is required because a CLEAR
    # verdict that finalization invalidated would otherwise exit 0 and read as a
    # clean run to every caller of this script.
    if args.system == "new":
        return 0 if (
            report.get("cacheable") is True
            and report.get("release_gate", {}).get("verdict") == "CLEAR"
        ) else 1
    return 0 if report.get("overall", {}).get("batch_verdict") == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
