#!/usr/bin/env python3
"""Join one Sentry fingerprint to PostHog usage, per anonymous install (#1846).

Sentry records only failures, so every field on a failing event looks universal
there. This instrument answers the four questions that repeatedly went wrong without it
(#1788, #1809):

  1. How many PEOPLE, not events, does this fingerprint affect, per release?
  2. What was each affected install configured as, and what is that install's
     own success record on the same release?
  3. Is the take key landing on every intended event and release?
  4. What share of eligible takes and installs does this fingerprint affect?

Phase 1 provides the install join and configuration reconstruction. Phase 2 adds
per-event take coverage and the fingerprint take and affected-user rates.

Usage:
  telemetry-join.py --issue ENVIOUSWISPR-2F
  telemetry-join.py --issue 6712345678

Credentials are read from the process environment ONLY, never from a file, an
argument or stdin. Bridge them with the approved launcher:

  ~/.claude/bin/get-key launch sentry-master-key SENTRY_MASTER_KEY -- \\
    ~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \\
    python3 scripts/telemetry-join.py --issue ENVIOUSWISPR-2F

Self-test:
  python3 scripts/telemetry-join.py --self-test

This is a required local ship gate. No CI workflow currently invokes it.

Fails CLOSED. Any authentication, authorization, pagination, parse, partition,
completeness or exhausted-retry failure exits non-zero BEFORE printing any
measurement. A partial table that reads as complete is the failure mode this
design exists to prevent.
"""
from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Mapping, Sequence

# --------------------------------------------------------------------------
# Grounded constants. Sources:
#   sentry-operations.md FACT: connection-details, FACT: mcp-tool-selection
#   analytics-operations.md FACT: posthog-connection, RULE: filter-production-analytics,
#     FACT: posthog-project-concurrency-limit, FACT: dictation-completed-field-version-floors
# --------------------------------------------------------------------------
SENTRY_HOST = "https://us.sentry.io"
SENTRY_ORG = "envious-labs-llc"
POSTHOG_HOST = "https://us.posthog.com"
POSTHOG_PROJECT_ID = "354235"

# Plan §11.2 makes a DEVELOPMENT-environment run the primary pre-merge gate,
# while ordinary triage is production. Both vendors carry both environments, so
# the environment is an input, not a constant. Production is the default because
# that is the answer a triage session almost always wants.
ENVIRONMENTS = ("production", "development")
ASR_HELPER_ROLE = "asr_xpc"

JOIN_TAG = "analytics.distinct_id"
JOINED_IDENTITY_LABEL = "analytics.distinct_id (joined install identity)"
LEGACY_IDENTITY_LABEL = "legacy Sentry identity"

# Phase 2. The Sentry tag and the PostHog property both carry the SAME value:
# `SessionID.raw.uuidString`, the kernel's per-take identity.
TAKE_TAG = "dictation.take_id"
TAKE_PROPERTY = "take_id"

# The 13 events Phase 2 routes the take key to. MEASURED from the emitter, not
# remembered: every name here has a `["take_id"] = takeID` assignment in
# `TelemetryService.swift`. Match the FIELD, not a `props`/`properties` variable
# name — a pattern pinned to `props[...]` structurally cannot match the
# `asr.completed` emitter and silently reports 12. A name absent from this tuple
# is not measured, and a name here that the app never emits reads `not observed`.
TAKE_KEYED_EVENTS = (
    "asr.completed",
    "audio.capture_interrupted",
    "audio.dead_mic_retire_attempted",
    "dictation.completed",
    "dictation.first_vad_chunk_completed",
    "dictation.first_vad_chunk_started",
    "dictation.invoked",
    "dictation.vad_preparation_completed",
    "llm.polish_completed",
    "llm.polish_failed",
    "llm.polish_skipped",
    "paste.completed",
    "recording.cap_warning_shown",
)

# The event whose take IDs are the SUCCESS side of the fingerprint take rate.
SUCCESS_TAKE_EVENT = "dictation.completed"

# Applied INSIDE the PostHog queries. `canonical_take_id` guards the Sentry side;
# without this the PostHog side accepted any non-empty string, so a junk value
# would enter `success_takes`, enlarge both denominators and produce a confidently
# LOWER failure rate. (`match` measured against the live API 2026-07-30.)
TAKE_ID_HOGQL_PATTERN = (
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)

NOT_OBSERVED = "not observed"

NO_USAGE_ROWS = "no usage rows for this install"
NOT_SHIPPED = "not shipped on this release"

# PostHog project limit is 3 concurrent / 10s per query. This instrument runs
# partitions strictly sequentially, so the only contention is external (the
# project is shared with EnviousStaging). Retry mirrors the production workers:
# 3 attempts total, only on the documented transient status class.
RETRYABLE_STATUSES = frozenset({429, 502, 503, 504})
MAX_ATTEMPTS = 3
RETRY_DELAYS_SECONDS = (15.0, 37.0)
REQUEST_TIMEOUT_SECONDS = 30.0

# One identity emitting this many events inside this window is one frustrated
# person retrying, not a trend. #1809: five of six events inside five minutes.
RETRY_BURST_WINDOW_SECONDS = 300
RETRY_BURST_MIN_EVENTS = 3

# Explicit ceiling for the one query that returns a LIST rather than an aggregate.
# PostHog defaults a HogQL result to 100 rows and reports `hasMore`, which
# `PostHogClient.query` refuses — correct for every aggregate here, but it would
# abort the whole report the day this project passes 100 dev installs. The proven
# worker shape (`workers/daily-report/src/lib/posthog.js` `resolveDevIds`) asks for
# LIMIT n+1 and treats the overflow row as the completeness failure, so the bound
# is explicit and the failure is about the DATA, not about a default.
DEV_ID_LIST_LIMIT = 5000

# Installs per sequential PostHog partition. Small enough to stay well inside
# the documented 10s execution ceiling with a literal IN list.
PARTITION_SIZE = 25

# Version floors, verbatim from analytics-operations.md FACT:
# dictation-completed-field-version-floors. A field below its floor was never
# emitted; printing a value (or a zero) for it would be fabrication.
VERSION_FLOORS: Mapping[str, str] = {
    "recording_seconds": "2.2.0",
    "stop_reason": "2.2.0",
    "history_save_status": "2.2.0",
    "selected_transport": "2.3.2",
    "effective_transport": "2.3.2",
    "route_reason": "2.3.2",
}
# Fields with NO version floor. `llm_provider` null means "no accepted polish
# stamp", which is data, not absence.
NO_FLOOR_FIELDS = frozenset({"llm_provider", "target_app", "paste_result"})

# `settings.snapshot` property names, read from the emitter
# (TelemetryService.swift `settings.snapshot`). Reconstruction overlays later
# `settings.changed` values on the latest snapshot, per
# analytics-operations.md FACT: settings-config-reconstruction.
RECONSTRUCTED_SETTINGS = (
    "asr_backend",
    "llm_provider",
    "llm_model",
    "recording_mode",
    "vad_auto_stop",
    "warm_engine_policy",
    "filler_removal",
    "microphone_status",
    "accessibility_status",
)
# NOTE on three of the nine: `asr_backend`, `microphone_status` and
# `accessibility_status` are NOT members of `SettingsProjection.Logical`
# (Sources/EnviousWisprAppKit/App/SettingsChangeTelemetry.swift — its comment
# says it "Excludes the Phase-2-owned backend"), so they never appear as a
# `settings.changed` delta and are reconstructed from the latest snapshot ALONE.
# A backend switch between snapshots is therefore invisible to this tool. Stated
# rather than silently inaccurate.


# --------------------------------------------------------------------------
# Errors. Every one of these must reach the operator as a non-zero exit with no
# measurement printed.
# --------------------------------------------------------------------------
class InstrumentError(Exception):
    """Base: any condition that invalidates the requested report."""


class ConfigError(InstrumentError):
    """Missing credential or malformed invocation."""


class TransportError(InstrumentError):
    """The connection failed. Never carries headers or credential material."""


class AuthError(InstrumentError):
    """401/403 from a vendor. Not retryable."""


class ProtocolError(InstrumentError):
    """Malformed JSON, Link header, response shape, or missing required field."""


class IncompleteError(InstrumentError):
    """A partition or bucket total proves the evidence is incomplete."""


class RetryExhaustedError(InstrumentError):
    """A retryable status survived every attempt."""


class MissingAuthorityError(InstrumentError):
    """A version floor is required but not recorded in our knowledge base."""


# --------------------------------------------------------------------------
# The ONE transport seam. `urllib_transport` is the only function in this file
# permitted to open a network connection. Everything above it - retry, status
# classification, URL building, authorization, JSON, Link parsing, pagination,
# partition accounting, completeness, aggregation, rendering - is exercised by
# the self-test through a fixture transport.
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class HTTPRequest:
    method: str
    url: str
    headers: Mapping[str, str]
    body: bytes | None
    timeout_seconds: float


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


Transport = Callable[[HTTPRequest], HTTPResponse]
Sleeper = Callable[[float], None]


def urllib_transport(request: HTTPRequest) -> HTTPResponse:
    """Normalize both ordinary responses and HTTPError into HTTPResponse, so
    every status decision stays ABOVE this boundary. A connection-level failure
    becomes a TransportError carrying only the reason class, never the headers.
    """
    req = urllib.request.Request(
        request.url, data=request.body, method=request.method,
        headers=dict(request.headers),
    )
    try:
        with urllib.request.urlopen(req, timeout=request.timeout_seconds) as resp:
            return HTTPResponse(
                status=resp.status, headers=dict(resp.headers), body=resp.read()
            )
    except urllib.error.HTTPError as exc:
        # An error status is a RESPONSE, not a transport failure: the caller
        # decides whether it is auth, retryable, or fatal.
        return HTTPResponse(
            status=exc.code, headers=dict(exc.headers or {}), body=exc.read() or b""
        )
    except urllib.error.URLError as exc:
        raise TransportError(f"connection failed: {type(exc.reason).__name__}") from None
    except OSError as exc:
        raise TransportError(f"connection failed: {type(exc).__name__}") from None


def header(response: HTTPResponse, name: str) -> str | None:
    """Case-insensitive header read. HTTP header names are case-insensitive and
    a vendor may change casing without notice; a case-sensitive read would
    silently lose pagination.
    """
    target = name.lower()
    for key, value in response.headers.items():
        if key.lower() == target:
            return value
    return None


def decode_json(response: HTTPResponse, what: str) -> object:
    try:
        return json.loads(response.body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"{what}: response was not valid JSON ({exc.__class__.__name__})")


# --------------------------------------------------------------------------
# Sentry
# --------------------------------------------------------------------------
_LINK_SEGMENT = re.compile(r"^\s*<(?P<url>[^>]*)>(?P<params>.*)\s*$")
_SHORT_ID = re.compile(r"^[A-Z][A-Z0-9_]*-[A-Z0-9]+$")
_NUMERIC_ID = re.compile(r"^[0-9]+$")


def parse_link_header(raw: str) -> dict[str, dict[str, str]]:
    """Parse Sentry's Link header into {rel: {url, results, ...}}.

    Refuses silently-malformed input rather than treating an unparseable header
    as "no next page", which would truncate the population and report a
    confident undercount.
    """
    raw_segments = [segment.strip() for segment in raw.split(",")]
    if not raw_segments or any(not segment for segment in raw_segments):
        raise ProtocolError(f"Link header is malformed: {raw[:120]!r}")

    rels: dict[str, dict[str, str]] = {}
    for segment in raw_segments:
        # fullmatch, not findall: a valid PREFIX followed by garbage must fail,
        # not parse to the prefix and silently drop the rest.
        match = _LINK_SEGMENT.fullmatch(segment)
        if match is None:
            raise ProtocolError(f"Link segment is unparseable: {segment[:120]!r}")

        attrs: dict[str, str] = {"url": match.group("url").strip()}
        for part in match.group("params").split(";"):
            part = part.strip()
            if not part:
                continue
            if "=" not in part:
                raise ProtocolError(f"Link parameter without a value: {part!r}")
            key, _, value = part.partition("=")
            key = key.strip()
            if not key:
                raise ProtocolError(f"Link parameter has an empty key: {part!r}")
            if key in attrs:
                raise ProtocolError(f"Link segment contains duplicate parameter {key!r}")

            # `results="true"; results="false"` previously resolved to the LAST
            # value, so an ambiguous header could authorize truncation.
            raw_value = value.strip()
            starts_quoted = raw_value.startswith('"')
            ends_quoted = raw_value.endswith('"')
            if starts_quoted != ends_quoted:
                raise ProtocolError(f"Link parameter has unbalanced quotes: {part!r}")
            if starts_quoted:
                decoded_value = raw_value[1:-1]
                if '"' in decoded_value:
                    raise ProtocolError(
                        f"Link parameter contains an unsupported quote: {part!r}"
                    )
            else:
                if '"' in raw_value:
                    raise ProtocolError(
                        f"Link parameter contains an unsupported quote: {part!r}"
                    )
                decoded_value = raw_value

            attrs[key] = decoded_value

        rel = attrs.get("rel")
        if not rel:
            raise ProtocolError(f"Link segment without rel: {segment[:120]!r}")
        if rel in rels:
            raise ProtocolError(f"Link header contains duplicate rel={rel!r}")
        rels[rel] = attrs

    return rels


def validate_sentry_page_url(url: str, numeric_issue_id: str) -> None:
    """A pagination URL is vendor data, not authority to forward a credential.

    The next request attaches our Sentry bearer token, so accepting any URL that
    merely starts with "http" would let a compromised or buggy response redirect
    that credential to an arbitrary host. Pinned to the exact issue endpoint.
    """
    parsed = urllib.parse.urlsplit(url)
    expected_host = urllib.parse.urlsplit(SENTRY_HOST).netloc
    expected_path = f"/api/0/issues/{numeric_issue_id}/events/"
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

    if (
        parsed.scheme != "https"
        or parsed.netloc != expected_host
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path != expected_path
        or parsed.fragment
        or query.get("full") != ["true"]
    ):
        raise ProtocolError(
            "events pagination returned a URL outside the exact Sentry issue "
            f"endpoint: {url[:120]!r}"
        )


@dataclass(frozen=True)
class SentryEvent:
    event_id: str
    release: str
    join_key: str | None
    legacy_identity: str | None
    timestamp_epoch: float
    #: Eligibility facts, read from the tags array. Plan §3a excludes development,
    #: `synthetic=true` fault-injection launches, and the ASR helper process.
    environment: str | None = None
    synthetic: bool = False
    process_role: str | None = None
    #: Phase 2. `None` is NON-DIAGNOSTIC (plan §7): the release may predate the
    #: tag, no kernel session may have existed, or the terminal postamble may
    #: already have cleared the scope. Never read absence as "no dictation".
    take_id: str | None = None


@dataclass
class SentryClient:
    api_key: str
    transport: Transport = urllib_transport

    def _get(self, url: str, what: str) -> HTTPResponse:
        response = self.transport(
            HTTPRequest(
                method="GET", url=url,
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Accept": "application/json",
                },
                body=None, timeout_seconds=REQUEST_TIMEOUT_SECONDS,
            )
        )
        if response.status in (401, 403):
            raise AuthError(
                f"{what}: Sentry rejected the credential (HTTP {response.status}). "
                "Expected GCP `sentry-master-key`, not the DSN, CI token, or worker token."
            )
        if response.status != 200:
            raise ProtocolError(f"{what}: unexpected HTTP {response.status}")
        return response

    def resolve_issue_id(self, raw: str) -> str:
        """Accept a numeric id directly; resolve a short id such as
        ENVIOUSWISPR-2F through the organization short-id lookup.
        """
        candidate = raw.strip()
        if _NUMERIC_ID.match(candidate):
            return candidate
        if not _SHORT_ID.match(candidate.upper()):
            raise ConfigError(
                f"issue identifier {raw!r} is neither numeric nor a SHORT-ID such as "
                "ENVIOUSWISPR-2F"
            )
        url = f"{SENTRY_HOST}/api/0/organizations/{SENTRY_ORG}/shortids/{candidate.upper()}/"
        payload = decode_json(self._get(url, "short-id lookup"), "short-id lookup")
        if not isinstance(payload, dict):
            raise ProtocolError("short-id lookup: expected a JSON object")
        group = payload.get("group")
        group_id = payload.get("groupId") or (
            group.get("id") if isinstance(group, dict) else None
        )
        if not isinstance(group_id, str) or not _NUMERIC_ID.match(group_id):
            raise ProtocolError(f"short-id lookup: no numeric groupId in response for {candidate}")
        return group_id

    def fetch_events(self, numeric_issue_id: str) -> list[SentryEvent]:
        """Paginate the whole fingerprint. `full=true` because the MCP cannot
        read `extra` fields (sentry-operations.md FACT: mcp-tool-selection).
        """
        url = f"{SENTRY_HOST}/api/0/issues/{numeric_issue_id}/events/?full=true"
        seen_urls: set[str] = set()
        # URL identity is not enough: two DIFFERENT page URLs can overlap, and the
        # same event would then be counted twice.
        seen_event_ids: set[str] = set()
        events: list[SentryEvent] = []
        page = 0
        while url:
            if url in seen_urls:
                raise ProtocolError(
                    f"pagination cycle: {url[:120]!r} was already fetched — refusing to "
                    "count a population that may contain duplicates"
                )
            seen_urls.add(url)
            page += 1
            response = self._get(url, f"events page {page}")
            payload = decode_json(response, f"events page {page}")
            if not isinstance(payload, list):
                raise ProtocolError(
                    f"events page {page}: expected a JSON list, got {type(payload).__name__}"
                )
            for raw_event in payload:
                event = self._parse_event(raw_event, page)
                if event.event_id in seen_event_ids:
                    raise ProtocolError(
                        f"events page {page}: duplicate event id "
                        f"{event.event_id!r} across the paginated population"
                    )
                seen_event_ids.add(event.event_id)
                events.append(event)

            link = header(response, "Link")
            if link is None:
                raise ProtocolError(
                    f"events page {page}: missing Link header — refusing to treat "
                    "an unverifiable page boundary as the end of the population"
                )
            rels = parse_link_header(link)
            nxt = rels.get("next")
            if nxt is None:
                raise ProtocolError(
                    f"events page {page}: Link header has no next relation — refusing "
                    "to treat an unverifiable page boundary as complete"
                )
            results = nxt.get("results")
            if results not in ("true", "false"):
                raise ProtocolError(
                    f"events page {page}: next rel has results={results!r}, expected "
                    '"true" or "false"'
                )
            # Validate EVERY next relation, including the terminating one, so a
            # hostile URL cannot slip through on the last page.
            next_url = nxt.get("url", "")
            validate_sentry_page_url(next_url, numeric_issue_id)
            if results == "false":
                url = ""
                break
            url = next_url
        return events

    @staticmethod
    def _parse_event(raw_event: object, page: int) -> SentryEvent:
        if not isinstance(raw_event, dict):
            raise ProtocolError(f"events page {page}: event was not a JSON object")
        event_id = raw_event.get("id")
        if not isinstance(event_id, str) or not event_id:
            raise ProtocolError(f"events page {page}: event without an id")
        tags = raw_event.get("tags")
        if not isinstance(tags, list):
            raise ProtocolError(f"event {event_id}: `tags` missing or not a list")
        # Release lives in the tags ARRAY. `.release.version` reads null
        # (sentry-operations.md FACT: mcp-tool-selection).
        by_key: dict[str, str] = {}
        for tag in tags:
            if not isinstance(tag, dict):
                raise ProtocolError(f"event {event_id}: tag entry was not an object")
            key, value = tag.get("key"), tag.get("value")
            if isinstance(key, str) and isinstance(value, str):
                by_key[key] = value
        release = canonical_app_version(by_key.get("release"), f"event {event_id}")

        timestamp_epoch = _parse_iso8601(raw_event.get("dateCreated"))
        if timestamp_epoch is None:
            raise ProtocolError(
                f"event {event_id}: dateCreated was missing or not valid ISO-8601"
            )

        # `user.id` specifically, NOT the `user` display tag: the approved legacy
        # identity is the SDK installation UUID on `user.id`, and the display tag
        # can hold a different, non-identity string.
        join_key = canonical_join_key(by_key.get(JOIN_TAG))
        legacy_identity = _user_id(raw_event)
        if join_key is None and legacy_identity is None:
            raise ProtocolError(
                f"event {event_id}: neither a canonical {JOIN_TAG} nor "
                "legacy Sentry user.id was present"
            )

        return SentryEvent(
            event_id=event_id,
            release=release,
            join_key=join_key,
            legacy_identity=legacy_identity,
            timestamp_epoch=timestamp_epoch,
            environment=by_key.get("environment"),
            synthetic=by_key.get("synthetic") == "true",
            process_role=by_key.get("process.role"),
            # Phase 2. Unlike the join key, a missing or malformed take tag is NOT
            # an error: this tag ships from #1846 onward, so every older event
            # legitimately lacks it and the report must still be produced.
            take_id=canonical_take_id(by_key.get(TAKE_TAG)),
        )


def _user_id(raw_event: Mapping[str, object]) -> str | None:
    user = raw_event.get("user")
    if isinstance(user, dict):
        value = user.get("id")
        return value if isinstance(value, str) else None
    return None


def _parse_iso8601(value: object) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def canonical_join_key(raw: object) -> str | None:
    """Mirror of `ObservabilityBootstrap.canonicalAnonymousPostHogID`. A value
    the app would never have emitted is not a join key; treating it as one would
    query PostHog for an install that cannot exist.
    """
    if not isinstance(raw, str) or len(raw) != 36:
        return None
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", raw):
        return None
    return raw


_TAKE_ID_PATTERN = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


def canonical_take_id(raw: object) -> str | None:
    """A SEPARATE canonicalizer from `canonical_join_key`, and the case handling is
    the whole reason.

    The two identities are produced by different code and differ in CASE:
      - `analytics.distinct_id` comes from the PostHog SDK and is LOWERCASE.
      - `dictation.take_id` / `take_id` is Swift `UUID.uuidString`, which
        Foundation renders UPPERCASE (measured: `D3B6682C-A4F7-47DB-...`).

    Reusing the lowercase-only join-key matcher here would reject every real take
    ID and report take coverage as 0% — a confident, silent wrong answer of
    exactly the kind this instrument exists to prevent. Accept both cases.

    Returns the UPPERCASED form so set membership across the two vendors cannot
    fail on case alone. Both sides serialize the same `uuidString` today, so this
    is belt-and-braces rather than a known divergence, but a case-sensitive union
    would fail silently as a 0% rate rather than loudly.
    """
    if not isinstance(raw, str) or len(raw) != 36:
        return None
    if not _TAKE_ID_PATTERN.fullmatch(raw):
        return None
    return raw.upper()


_APP_VERSION_PATTERN = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$")
_SENTRY_RELEASE_PREFIX = "com.enviouswispr.app@"


def canonical_app_version(raw: object, what: str) -> str:
    """Normalize the TWO representations the app emits for the same version.

    Sentry receives `com.enviouswispr.app@<appVersion>`
    (`ObservabilityBootstrap.swift` `options.releaseName`) while PostHog receives
    `<appVersion>` raw (`register(["app_version": appVersion])`). Without this,
    an exact dictionary lookup between the two NEVER matches and every install's
    success count silently reports zero — the tool's entire denominator, empty.

    Dev builds carry a leading `v` and a git suffix, which must also normalize.

    NOTE on the hard failure: `appVersion` falls back to the literal "unknown"
    when `CFBundleShortVersionString` is absent, so malformed release evidence
    can reach this instrument. It deliberately aborts the whole report. Release
    is a required reporting dimension; excluding the event would knowingly
    undercount the fingerprint, while an "unknown" bucket would fabricate a
    release. Correct the evidence or source build, then rerun.
    """
    if not isinstance(raw, str) or not raw.strip():
        raise ProtocolError(f"{what}: release was missing or not a string")

    value = raw.strip()
    if value.startswith(_SENTRY_RELEASE_PREFIX):
        value = value[len(_SENTRY_RELEASE_PREFIX):]
    elif "@" in value:
        raise ProtocolError(f"{what}: unexpected packaged release {value!r}")

    if _APP_VERSION_PATTERN.fullmatch(value) is None:
        raise ProtocolError(f"{what}: malformed app version {value!r}")
    return value


def required_timestamp(raw: object, what: str) -> float:
    """Accept only a finite, non-negative numeric timestamp.

    A NaN comparison is always false, so an unvalidated NaN would make a valid
    later settings change silently lose to its snapshot and reconstruct the wrong
    configuration — a wrong answer, not an error.
    """
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        raise ProtocolError(f"{what}: timestamp was not numeric")
    value = float(raw)
    if not math.isfinite(value) or value < 0:
        raise ProtocolError(f"{what}: timestamp was not a finite non-negative number")
    return value


def required_count(raw: object, what: str) -> int:
    """Accept only a finite, non-negative whole number.

    `isinstance(True, int)` is True in Python, so a boolean passed the previous
    numeric check, and `int(1.5)` silently truncated a fractional count. A count
    is a measurement; a truncated one is a fabricated one.
    """
    if isinstance(raw, bool):
        raise ProtocolError(f"{what}: count was boolean, not numeric")
    if isinstance(raw, int):
        if raw < 0:
            raise ProtocolError(f"{what}: count was negative")
        return raw
    if isinstance(raw, float):
        if not math.isfinite(raw) or raw < 0 or not raw.is_integer():
            raise ProtocolError(f"{what}: count was not a finite non-negative integer")
        return int(raw)
    raise ProtocolError(f"{what}: count was not numeric")


# --------------------------------------------------------------------------
# PostHog
# --------------------------------------------------------------------------
def sql_id_list(ids: Sequence[str]) -> str:
    """Escape for a literal IN list, matching `sqlIdList` in the production
    workers (workers/daily-report/src/index.js).
    """
    return ", ".join("'" + str(i).replace("'", "''") + "'" for i in ids)


@dataclass
class PostHogClient:
    api_key: str
    transport: Transport = urllib_transport
    sleeper: Sleeper = time.sleep
    #: Every dev-tainted distinct_id, resolved ONCE. Repeating the unbounded
    #: whole-history NOT IN subquery per query is the shape that measurably
    #: 504'd production (#1655, #1716, #1720).
    environment: str = "production"
    dev_ids: tuple[str, ...] | None = None
    attempts_made: list[int] = field(default_factory=list)

    def query(self, sql: str, name: str) -> tuple[list[list[object]], list[str]]:
        body = json.dumps(
            {
                "query": {"kind": "HogQLQuery", "query": sql},
                "refresh": "blocking",
                "name": f"telemetry_join_{name}",
            }
        ).encode("utf-8")
        last_status: int | None = None
        for attempt in range(1, MAX_ATTEMPTS + 1):
            response = self.transport(
                HTTPRequest(
                    method="POST",
                    url=f"{POSTHOG_HOST}/api/projects/{POSTHOG_PROJECT_ID}/query/",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "Content-Type": "application/json",
                    },
                    body=body,
                    timeout_seconds=REQUEST_TIMEOUT_SECONDS,
                )
            )
            if response.status in (401, 403):
                raise AuthError(
                    f"query {name}: PostHog rejected the credential (HTTP {response.status}). "
                    "Expected GCP `posthog-personal-api-key`."
                )
            if response.status == 200:
                self.attempts_made.append(attempt)
                payload = decode_json(response, f"query {name}")
                if not isinstance(payload, dict):
                    raise ProtocolError(f"query {name}: expected a JSON object")
                results = payload.get("results")
                if not isinstance(results, list):
                    raise ProtocolError(f"query {name}: response has no `results` array")
                # TRUNCATION IS THE ONE FAILURE THIS INSTRUMENT CANNOT SEE IN ITS
                # OWN OUTPUT. PostHog caps a HogQL result at 100 rows and reports
                # it — MEASURED 2026-07-30: `SELECT number FROM numbers(200000)`
                # returns 100 rows with `hasMore: true, limit: 100`. A truncated
                # DISTINCT id list silently drops installs from an exclusion; a
                # truncated grouped result silently reads as an absent bucket, which
                # this tool renders as `not observed` or as zero. Both are confident
                # wrong answers of exactly the kind it exists to prevent.
                #
                # Enforced HERE, once, rather than as a per-query completeness check:
                # the server is authoritative about its own truncation, it costs no
                # extra query, and no future caller can forget it. Every query in
                # this file is either an aggregate or a bounded id list, so `hasMore`
                # is always a defect, never an expected paging signal.
                if payload.get("hasMore") is True:
                    raise IncompleteError(
                        f"query {name}: PostHog truncated the result "
                        f"(limit={payload.get('limit')}, offset={payload.get('offset')}, "
                        f"hasMore=true). Refusing to measure from a partial result — "
                        "narrow the query, partition it, or aggregate server-side."
                    )
                rows: list[list[object]] = []
                for row in results:
                    if not isinstance(row, list):
                        raise ProtocolError(f"query {name}: a result row was not a list")
                    rows.append(row)
                columns = payload.get("columns")
                if columns is not None and not isinstance(columns, list):
                    raise ProtocolError(f"query {name}: `columns` present but not a list")
                return rows, [str(c) for c in (columns or [])]
            if response.status not in RETRYABLE_STATUSES:
                raise ProtocolError(f"query {name}: unexpected HTTP {response.status}")
            last_status = response.status
            if attempt < MAX_ATTEMPTS:
                self.sleeper(RETRY_DELAYS_SECONDS[attempt - 1])
        raise RetryExhaustedError(
            f"query {name}: HTTP {last_status} survived {MAX_ATTEMPTS} attempts — "
            "the whole report fails rather than degrading to a partial answer"
        )

    def environment_clause(self) -> str:
        """The environment filter plus, for PRODUCTION only, the resolve-once
        dev-taint exclusion. An empty dev list is legitimate and must not produce
        `NOT IN ()`.

        The exclusion is deliberately NOT applied to a development query: in that
        mode the dev-tainted installs ARE the population, so excluding them would
        return zero rows and read as "no usage" — the plan's primary gate would
        silently prove nothing.
        """
        if self.environment not in ENVIRONMENTS:
            raise ConfigError(f"unknown environment {self.environment!r}")
        clause = f"properties.environment = '{self.environment}'"
        if self.environment == "production":
            if self.dev_ids is None:
                raise IncompleteError("dev-tainted install ids were never resolved")
            if self.dev_ids:
                clause += f" AND distinct_id NOT IN ({sql_id_list(self.dev_ids)})"
        return clause

    def resolve_dev_ids(self) -> tuple[str, ...]:
        """The ONE query here that returns a list rather than an aggregate, so it
        carries its own explicit bound. `LIMIT n+1` makes the overflow row the
        completeness signal — the shape `workers/daily-report` already runs daily.
        """
        rows, _ = self.query(
            "SELECT DISTINCT distinct_id FROM events "
            "WHERE properties.app_version LIKE '%-dev%' "
            f"LIMIT {DEV_ID_LIST_LIMIT + 1}",
            "dev_ids",
        )
        ids = []
        for row in rows:
            if len(row) != 1 or not isinstance(row[0], str):
                raise ProtocolError("dev_ids: expected exactly one string column per row")
            ids.append(row[0])
        if len(ids) > DEV_ID_LIST_LIMIT:
            raise IncompleteError(
                f"dev_ids: more than {DEV_ID_LIST_LIMIT} dev-tainted installs. The "
                "exclusion list would be incomplete and every production total would "
                "carry dev traffic — refusing to measure."
            )
        self.dev_ids = tuple(ids)
        return self.dev_ids


def require_complete_partitions(
    expected_indexes: set[int], completed_indexes: set[int]
) -> None:
    """The partition-accounting guard, extracted as a pure function so it is
    DIRECTLY testable. Inline in the loop it was unreachable under sequential
    fail-fast execution, which made it a guard nothing could arm
    (RULE: a-guard-nothing-arms-is-not-a-guard). As a pure function its contract
    is asserted by the self-test, and it stays correct if concurrency lands.
    """
    missing = expected_indexes - completed_indexes
    unexpected = completed_indexes - expected_indexes
    if missing or unexpected:
        raise IncompleteError(
            "PostHog partition accounting failed: "
            f"missing={sorted(missing)}, unexpected={sorted(unexpected)} — "
            "refusing to render an incomplete report"
        )


def partition(ids: Sequence[str], size: int = PARTITION_SIZE) -> list[tuple[int, list[str]]]:
    """Explicit, indexed, sequential partitions. The index is what lets the
    caller prove none went missing.
    """
    return [(i // size, list(ids[i:i + size])) for i in range(0, len(ids), size)]


# --------------------------------------------------------------------------
# Version floors
# --------------------------------------------------------------------------
def version_key(version: str) -> tuple[int, ...]:
    """Sort key. The previous version returned (0,) for any dev build, because it
    stopped at the leading `v` — so every dev release sorted as version zero.
    """
    normalized = canonical_app_version(version, "release")
    if normalized.startswith("v"):
        normalized = normalized[1:]
    numeric = re.split(r"[-+]", normalized, maxsplit=1)[0]
    return tuple(int(part) for part in numeric.split("."))


def field_shipped_on(field_name: str, release: str) -> bool:
    """Refuses to guess. An unrecorded field raises rather than defaulting to
    "shipped", which would print a fabricated absence as data.
    """
    if field_name in NO_FLOOR_FIELDS:
        return True
    floor = VERSION_FLOORS.get(field_name)
    if floor is None:
        raise MissingAuthorityError(
            f"no version floor recorded for {field_name!r}. Add it to "
            "analytics-operations.md FACT: dictation-completed-field-version-floors "
            "before reporting it."
        )
    return version_key(release) >= version_key(floor)


def render_field(field_name: str, release: str, value: object) -> str:
    if not field_shipped_on(field_name, release):
        return NOT_SHIPPED
    if value is None or value == "":
        return "null (no value recorded)"
    return str(value)


# --------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class ReleaseRow:
    release: str
    events: int
    identities: int
    events_per_identity: float
    identity_source: str


@dataclass(frozen=True)
class PopulationTotal:
    """One total per IDENTITY SYSTEM. There is deliberately no combined total:
    the joined install population and the legacy Sentry population can contain
    the same human twice, so a sum would be a fabricated number.
    """
    events: int
    identities: int
    events_per_identity: float
    identity_source: str


@dataclass(frozen=True)
class RetryBurst:
    identity: str
    release: str
    events_in_window: int
    window_seconds: int


@dataclass
class FingerprintReport:
    issue: str
    environment: str
    excluded_counts: dict[str, int]
    release_rows: list[ReleaseRow]
    population_totals: list[PopulationTotal]
    join_coverage_by_release: dict[str, tuple[int, int]]
    bursts: list[RetryBurst]
    joined_install_ids: list[str]
    joined_releases_by_install: dict[str, set[str]]
    unjoined_events: int
    #: Phase 2. Distinct take IDs seen on THIS fingerprint, keyed by
    #: (install, release). Empty for a pre-#1846 population, which is data, not
    #: an error.
    affected_takes_by_install_release: dict[tuple[str, str], set[str]] = field(
        default_factory=dict
    )
    #: Phase 2. The span the take rate is computed over — see `TakeWindow`.
    take_window: TakeWindow | None = None


@dataclass(frozen=True)
class TakeCoverageRow:
    """One (event, release) cell of the per-event take coverage table. Deliberately
    NOT pooled across events: a high-volume event at 100% would otherwise hide a
    low-volume one at 0%, which is precisely the failure this metric watches for.
    """
    event: str
    release: str
    with_take: int
    total: int


@dataclass(frozen=True)
class TakeRateRow:
    """Per release. `affected` and `union` are counts of DISTINCT take IDs, never
    of raw events — the #1809 mistake was reading six events from one retrying
    person as six independent failures.
    """
    release: str
    affected_takes: int
    union_takes: int
    affected_installs: int
    eligible_installs: int


@dataclass(frozen=True)
class TakeWindow:
    """The span the take rate is computed over, derived from the eligible Sentry
    events rather than declared, so the successful side is never widened beyond
    the failures that define the numerator.

    MILLISECOND PostHog bounds, rounded INWARD. Sentry timestamps keep fractions,
    while the PostHog comparison uses whole milliseconds. `ceil` the start and
    `floor` the end so the successful-take query cannot include events outside
    the measured Sentry failure span. (The first version compared whole seconds
    via `int(epoch)`, so a .900 .. 1.100 window admitted nearly two full seconds.
    `toUnixTimestamp64Milli` measured against the live API 2026-07-30.)

    This means the two sides are deliberately NOT claimed to have identical
    boundary precision: affected Sentry takes retain their original timestamps,
    while the successful side uses the largest whole-millisecond interval
    contained inside that span. Excluding possible boundary successes makes the
    reported rate conservative — an upper bound — rather than enlarging its
    denominator with out-of-window events.

    `degenerate` marks an interval with no positive width at PostHog's
    millisecond precision. Successful events could coincide with that timestamp,
    but a rate determined by timestamp coincidence is not a meaningful population
    measurement, so it is refused.
    """
    start_epoch: float
    end_epoch: float

    @property
    def start_millis(self) -> int:
        return math.ceil(self.start_epoch * 1000)

    @property
    def end_millis(self) -> int:
        return math.floor(self.end_epoch * 1000)

    @property
    def degenerate(self) -> bool:
        return self.end_millis <= self.start_millis


@dataclass(frozen=True)
class Eligibility:
    eligible: list[SentryEvent]
    excluded_counts: dict[str, int]


def select_eligible_events(
    events: Sequence[SentryEvent], environment: str
) -> Eligibility:
    """Plan §3a excludes development (or production, when asked for development),
    `synthetic=true` fault-injection launches, and the ASR helper process.

    Every exclusion is COUNTED by reason and reported. An instrument that silently
    drops events cannot be distinguished from one that never saw them.
    """
    if environment not in ENVIRONMENTS:
        raise ConfigError(f"unknown environment {environment!r}")
    eligible: list[SentryEvent] = []
    excluded: dict[str, int] = defaultdict(int)
    for event in events:
        if event.environment is None:
            excluded["environment tag absent"] += 1
            continue
        if event.environment != environment:
            excluded[f"environment={event.environment}"] += 1
            continue
        if event.synthetic:
            excluded["synthetic=true (fault injection)"] += 1
            continue
        if event.process_role == ASR_HELPER_ROLE:
            excluded[f"process.role={ASR_HELPER_ROLE} (documented gap)"] += 1
            continue
        eligible.append(event)
    return Eligibility(eligible=eligible, excluded_counts=dict(excluded))


def aggregate_fingerprint(
    issue: str,
    events: Sequence[SentryEvent],
    environment: str = "production",
    excluded_counts: Mapping[str, int] | None = None,
) -> FingerprintReport:
    """Keep joined and legacy identity systems in separate numerators,
    denominators, release rows and totals. They are never summed.

    The defect this shape replaces: counting ALL events for a release while
    dividing by only the JOINED identities produced an events-per-person figure
    mixing two populations — and the first version of case 20 froze that wrong
    total as expected behaviour.
    """
    joined_events: dict[str, int] = defaultdict(int)
    legacy_events: dict[str, int] = defaultdict(int)
    joined_identities: dict[str, set[str]] = defaultdict(set)
    legacy_identities: dict[str, set[str]] = defaultdict(set)
    joined_releases_by_install: dict[str, set[str]] = defaultdict(set)
    all_joined: set[str] = set()
    all_legacy: set[str] = set()
    # Phase 2. Only JOINED events can contribute a take to the rate: an event with
    # no install identity cannot be paired with that install's successes, so
    # including its take would inflate the numerator against a denominator it is
    # not part of.
    affected_takes: dict[tuple[str, str], set[str]] = defaultdict(set)

    for event in events:
        release = event.release
        if event.join_key:
            joined_events[release] += 1
            joined_identities[release].add(event.join_key)
            joined_releases_by_install[event.join_key].add(release)
            all_joined.add(event.join_key)
            if event.take_id:
                affected_takes[(event.join_key, release)].add(event.take_id)
            continue

        if not event.legacy_identity:
            raise IncompleteError(
                f"event {event.event_id} has neither {JOIN_TAG} nor a legacy "
                "Sentry identity"
            )
        legacy_events[release] += 1
        legacy_identities[release].add(event.legacy_identity)
        all_legacy.add(event.legacy_identity)

    rows: list[ReleaseRow] = []
    coverage: dict[str, tuple[int, int]] = {}
    releases = sorted(set(joined_events) | set(legacy_events), key=version_key)

    for release in releases:
        joined_count = joined_events[release]
        legacy_count = legacy_events[release]
        coverage[release] = (joined_count, joined_count + legacy_count)

        if joined_count:
            identities = len(joined_identities[release])
            rows.append(
                ReleaseRow(
                    release=release, events=joined_count, identities=identities,
                    events_per_identity=round(joined_count / identities, 1),
                    identity_source=JOINED_IDENTITY_LABEL,
                )
            )

        if legacy_count:
            identities = len(legacy_identities[release])
            rows.append(
                ReleaseRow(
                    release=release, events=legacy_count, identities=identities,
                    events_per_identity=round(legacy_count / identities, 1),
                    identity_source=LEGACY_IDENTITY_LABEL,
                )
            )

    totals: list[PopulationTotal] = []
    joined_total_events = sum(joined_events.values())
    if all_joined:
        totals.append(
            PopulationTotal(
                events=joined_total_events, identities=len(all_joined),
                events_per_identity=round(joined_total_events / len(all_joined), 1),
                identity_source=JOINED_IDENTITY_LABEL,
            )
        )

    legacy_total_events = sum(legacy_events.values())
    if all_legacy:
        # 255/60 = 4.25 resolves to 4.2 under Python's ties-to-even rounding,
        # matching the measured baseline table in the approved plan.
        totals.append(
            PopulationTotal(
                events=legacy_total_events, identities=len(all_legacy),
                events_per_identity=round(legacy_total_events / len(all_legacy), 1),
                identity_source=LEGACY_IDENTITY_LABEL,
            )
        )

    return FingerprintReport(
        issue=issue,
        environment=environment,
        excluded_counts=dict(excluded_counts or {}),
        release_rows=rows,
        population_totals=totals,
        join_coverage_by_release=coverage,
        bursts=detect_retry_bursts(events),
        joined_install_ids=sorted(all_joined),
        joined_releases_by_install={
            install: set(rels) for install, rels in joined_releases_by_install.items()
        },
        unjoined_events=legacy_total_events,
        affected_takes_by_install_release={
            pair: set(takes) for pair, takes in affected_takes.items()
        },
        # Derived from the eligible events, never declared. `events` is non-empty
        # by the caller's contract (`build_report` raises before reaching here).
        take_window=TakeWindow(
            start_epoch=min(event.timestamp_epoch for event in events),
            end_epoch=max(event.timestamp_epoch for event in events),
        ),
    )


def detect_retry_bursts(events: Sequence[SentryEvent]) -> list[RetryBurst]:
    """A retry burst inflates the EVENT count without adding a person. Finding
    it is what stops `events` being read as `people`.
    """
    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)
    for event in events:
        identity = event.join_key or event.legacy_identity
        if identity:
            grouped[(identity, event.release)].append(event.timestamp_epoch)

    bursts: list[RetryBurst] = []
    for (identity, release), stamps in grouped.items():
        stamps.sort()
        best, left = 0, 0
        for right in range(len(stamps)):
            while stamps[right] - stamps[left] > RETRY_BURST_WINDOW_SECONDS:
                left += 1
            best = max(best, right - left + 1)
        if best >= RETRY_BURST_MIN_EVENTS:
            bursts.append(
                RetryBurst(identity, release, best, RETRY_BURST_WINDOW_SECONDS)
            )
    return sorted(bursts, key=lambda b: (-b.events_in_window, b.identity))


# --------------------------------------------------------------------------
# PostHog enrichment
# --------------------------------------------------------------------------
@dataclass
class InstallUsage:
    install_id: str
    settings: dict[str, object]
    successes_by_release: dict[str, int]
    pipeline_failures_by_release: dict[str, int]
    has_usage_rows: bool


def fetch_install_usage(
    client: PostHogClient, install_ids: Sequence[str]
) -> dict[str, InstallUsage]:
    """Sequential, indexed partitions with expected-vs-completed accounting, plus
    an independent identical-filter total for bucket completeness. A LIMIT is a
    ceiling, not proof (analytics-operations.md RULE: verify-completeness-not-just-limit).
    """
    usage: dict[str, InstallUsage] = {
        install_id: InstallUsage(
            install_id=install_id, settings={}, successes_by_release={},
            pipeline_failures_by_release={}, has_usage_rows=False,
        )
        for install_id in install_ids
    }
    if not install_ids:
        return usage

    parts = partition(install_ids)
    expected_indexes = {index for index, _ in parts}
    completed_indexes: set[int] = set()
    prod = client.environment_clause()

    for index, chunk in parts:
        ids = sql_id_list(chunk)

        snapshot_rows, _ = client.query(
            f"""
            SELECT distinct_id,
                   toUnixTimestamp(max(timestamp)) AS snapshot_ts,
                   {", ".join(
                       f"argMax(properties.{name}, timestamp) AS {name}"
                       for name in RECONSTRUCTED_SETTINGS
                   )}
            FROM events
            WHERE event = 'settings.snapshot' AND {prod}
              AND distinct_id IN ({ids})
            GROUP BY distinct_id
            """,
            f"snapshot_p{index}",
        )

        settings_rows, _ = client.query(
            f"""
            SELECT distinct_id,
                   properties.setting AS setting,
                   argMax(properties.to, timestamp) AS value,
                   toUnixTimestamp(max(timestamp)) AS changed_ts
            FROM events
            WHERE event = 'settings.changed' AND {prod}
              AND distinct_id IN ({ids})
              AND properties.setting IN ({sql_id_list(RECONSTRUCTED_SETTINGS)})
            GROUP BY distinct_id, setting
            """,
            f"settings_p{index}",
        )

        # `dictation.completed` carries `result` but its ONLY production caller
        # passes "success" (TelemetryService.swift:165 -> :692), so a
        # `result != 'success'` count is structurally always zero and is
        # deliberately NOT reported — that is why the plan's own live measurement
        # read "0 failed completions". `pipeline.failed` is the real failure
        # counterpart and measured 18 on the same install.
        usage_rows, _ = client.query(
            f"""
            SELECT distinct_id,
                   properties.app_version AS release,
                   countIf(event = 'dictation.completed') AS successes,
                   countIf(event = 'pipeline.failed') AS pipeline_failures
            FROM events
            WHERE event IN ('dictation.completed', 'pipeline.failed')
              AND {prod}
              AND distinct_id IN ({ids})
            GROUP BY distinct_id, release
            """,
            f"usage_p{index}",
        )

        # A change is only an overlay if it happened AFTER the snapshot it
        # overlays. Applying an older change on top of a newer snapshot would
        # reconstruct a configuration the user had already moved on from.
        snapshot_times: dict[str, float] = {}
        for row in snapshot_rows:
            expected_columns = len(RECONSTRUCTED_SETTINGS) + 2
            if len(row) != expected_columns:
                raise ProtocolError(
                    f"snapshot_p{index}: expected {expected_columns} columns, got {len(row)}"
                )
            install, snapshot_ts = row[0], row[1]
            if not isinstance(install, str) or install not in usage:
                raise ProtocolError(f"snapshot_p{index}: unexpected distinct_id in results")
            snapshot_times[install] = required_timestamp(snapshot_ts, f"snapshot_p{index}")
            for name, value in zip(RECONSTRUCTED_SETTINGS, row[2:]):
                usage[install].settings[name] = normalize_setting(name, value)

        for row in settings_rows:
            if len(row) != 4:
                raise ProtocolError(f"settings_p{index}: expected 4 columns, got {len(row)}")
            install, setting, value, changed_ts = row
            if not isinstance(install, str) or install not in usage:
                raise ProtocolError(f"settings_p{index}: unexpected distinct_id in results")
            if not isinstance(setting, str) or setting not in RECONSTRUCTED_SETTINGS:
                raise ProtocolError(f"settings_p{index}: unexpected setting {setting!r}")
            change_time = required_timestamp(changed_ts, f"settings_p{index}")
            if change_time > snapshot_times.get(install, float("-inf")):
                usage[install].settings[setting] = normalize_setting(setting, value)

        for row in usage_rows:
            if len(row) != 4:
                raise ProtocolError(f"usage_p{index}: expected 4 columns, got {len(row)}")
            install, release, successes, pipeline_failures = row
            if not isinstance(install, str) or install not in usage:
                raise ProtocolError(f"usage_p{index}: unexpected distinct_id in results")
            success_count = required_count(successes, f"usage_p{index}: successes")
            pipeline_failure_count = required_count(
                pipeline_failures, f"usage_p{index}: pipeline_failures"
            )
            release_name = canonical_app_version(release, f"usage_p{index}")
            entry = usage[install]
            # Only USAGE rows prove usage. A settings row alone must never make
            # an install look active.
            entry.has_usage_rows = True
            entry.successes_by_release[release_name] = success_count
            entry.pipeline_failures_by_release[release_name] = pipeline_failure_count

        completed_indexes.add(index)

    require_complete_partitions(expected_indexes, completed_indexes)

    verify_bucket_completeness(client, install_ids, usage)
    return usage


def verify_bucket_completeness(
    client: PostHogClient, install_ids: Sequence[str], usage: Mapping[str, InstallUsage]
) -> None:
    """Independent identical-filter total. If the per-install buckets disagree
    with a separately-computed distinct total, the buckets are wrong and the
    report must not print.
    """
    prod = client.environment_clause()
    rows, _ = client.query(
        f"""
        SELECT uniqExact(distinct_id)
        FROM events
        WHERE event IN ('dictation.completed', 'pipeline.failed')
          AND {prod}
          AND distinct_id IN ({sql_id_list(install_ids)})
        """,
        "completeness_total",
    )
    if len(rows) != 1 or len(rows[0]) != 1:
        raise ProtocolError("completeness_total: expected one row with one count")
    independent_total = required_count(rows[0][0], "completeness_total")
    bucketed = sum(1 for entry in usage.values() if entry.has_usage_rows)
    if bucketed != independent_total:
        raise IncompleteError(
            f"bucket completeness failed: {bucketed} installs carry success buckets but an "
            f"independent identical-filter uniqExact returned {independent_total}. A LIMIT is "
            "a ceiling, not proof — refusing to render."
        )


def fetch_take_coverage(client: PostHogClient) -> list[TakeCoverageRow]:
    """Per-event take coverage — plan §5. POPULATION-WIDE and deliberately NOT
    bounded to this fingerprint's installs or window: the question it answers is
    "is the take key actually landing on this event," which wants the widest view
    available, not one fingerprint's slice.

    ONE QUERY PER EVENT, not one grouped query over all 13. A single
    `GROUP BY release, event` returns one row per observed combination, and that
    grid is ALREADY 127 rows in production (measured 2026-07-30) — over PostHog's
    100-row cap, so the shared truncation guard would have aborted the entire
    report on its first real run. Per event, each result is bounded by the number
    of releases instead, which is an order of magnitude smaller.

    Sequential and index-accounted like the install partitions, so a dropped query
    cannot pass as an event with no rows — which the renderer would print as
    `not observed`, turning a missing query into a fabricated blackout.

    Coverage counts only CANONICAL take ids, using the same pattern the rate
    queries reject on. Testing merely for NULL-or-empty would report an emitter
    that regressed to a malformed non-empty value as fully covered, while that
    value cannot join to Sentry at all and the rate queries refuse it — coverage
    would say 100% for a key that joins nothing. What is measured here is a
    USABLE join key, not the presence of a property.
    """
    coverage: list[TakeCoverageRow] = []
    expected_indexes = set(range(len(TAKE_KEYED_EVENTS)))
    completed_indexes: set[int] = set()

    for index, event_name in enumerate(TAKE_KEYED_EVENTS):
        rows, _ = client.query(
            f"""
            SELECT properties.app_version AS release,
                   count() AS total,
                   countIf(
                       match(
                           toString(properties.{TAKE_PROPERTY}),
                           '{TAKE_ID_HOGQL_PATTERN}'
                       ) = 1
                   ) AS with_take
            FROM events
            WHERE event = {sql_id_list([event_name])}
              AND {client.environment_clause()}
            GROUP BY release
            """,
            f"take_coverage_{index}",
        )
        for row in rows:
            if len(row) != 3:
                raise ProtocolError(
                    f"take_coverage_{index}: expected 3 columns, got {len(row)}"
                )
            release_raw, total, with_take = row
            total_count = required_count(total, f"take_coverage_{index}: total")
            with_take_count = required_count(with_take, f"take_coverage_{index}: with_take")
            if with_take_count > total_count:
                raise ProtocolError(
                    f"take_coverage_{index}: {event_name} on {release_raw!r} reports "
                    f"{with_take_count} keyed rows out of {total_count} — a subset "
                    "cannot exceed its set, so the query or the parse is wrong"
                )
            coverage.append(
                TakeCoverageRow(
                    event=event_name,
                    release=canonical_app_version(release_raw, f"take_coverage_{index}"),
                    with_take=with_take_count,
                    total=total_count,
                )
            )
        completed_indexes.add(index)

    require_complete_partitions(expected_indexes, completed_indexes)
    return coverage


def fetch_take_rates(
    client: PostHogClient,
    report: FingerprintReport,
) -> list[TakeRateRow]:
    """Fingerprint take rate and affected-user rate — plan §5.

    rate = distinct AFFECTED take IDs / |affected ∪ successful| takes, per release.

    TWO DIFFERENT POPULATIONS, deliberately, per plan §5:
      - The TAKE rate is CONDITIONAL on affected installs — the plan scopes its
        denominator to "the same install, release and window", so it answers
        "among people who hit this, how much of their dictation failed". It is
        NOT a fleet-wide share and the render says so explicitly.
      - The affected-USER rate is POPULATION-WIDE, over every install carrying an
        eligible take on that release.
    A whole-diff review argued the take rate should also be population-wide. That
    is a defensible but DIFFERENT metric, and changing an approved metric on a
    reviewer's say-so is plan expansion, so it is recorded as a founder question
    rather than silently swapped. What was genuinely wrong — the render calling
    this an upper bound on the POPULATION rate — is fixed.

    SQL computes the case-normalized successful-set cardinality and its overlap
    with the affected IDs, without shipping every successful take ID back — this
    install's `dictation.completed` takes could number in the thousands over the
    window. Python then computes the union from those validated counts:

        union = affected + successes - overlap

    A take appearing on both sides is therefore counted ONCE, which is the plan's
    explicit requirement.

    The successful PostHog side is bounded to the inward-rounded millisecond
    interval contained within the eligible Sentry event span. It is never widened
    beyond the failures that define the numerator. Possible boundary successes
    can therefore be excluded, which is why the rendered result is explicitly an
    upper bound rather than a claim of identical boundary precision.

    Returns [] when the window is degenerate or no affected takes exist. A rate is
    REFUSED rather than fabricated; the renderer says which.
    """
    window = report.take_window
    if window is None or window.degenerate or not report.affected_takes_by_install_release:
        return []

    # Only installs that actually carry an affected take need querying.
    installs = sorted({install for install, _ in report.affected_takes_by_install_release})
    parts = partition(installs)
    expected_indexes = {index for index, _ in parts}
    completed_indexes: set[int] = set()

    successes: dict[tuple[str, str], int] = defaultdict(int)
    overlaps: dict[tuple[str, str], int] = defaultdict(int)

    for index, chunk in parts:
        chunk_set = set(chunk)
        # Scope the affected-id list to THIS partition's installs. A global list
        # would grow the query text without changing any result.
        # Overlap must match install AND release. A partition-wide take-id list
        # lets a take affected on release A subtract from release B's union — the
        # rest of this function pairs (install, release) everywhere, so a flat
        # list was an inconsistency waiting to be exercised.
        chunk_take_ids_by_release: dict[str, set[str]] = defaultdict(set)
        for (affected_install, affected_release), takes in (
            report.affected_takes_by_install_release.items()
        ):
            if affected_install in chunk_set:
                chunk_take_ids_by_release[affected_release].update(takes)

        if not chunk_take_ids_by_release:
            completed_indexes.add(index)
            continue

        overlap_predicate = "\n OR ".join(
            f"""(
                properties.app_version = {sql_id_list([release_name])}
                AND upper(properties.{TAKE_PROPERTY})
                    IN ({sql_id_list(sorted(take_ids))})
            )"""
            for release_name, take_ids in sorted(chunk_take_ids_by_release.items())
        )

        # Built ONCE and reused by the bucket query and its completeness check, so
        # "identical filter" is guaranteed by construction rather than by two
        # hand-copied WHERE clauses that can drift apart.
        take_rate_filter = f"""
            event = '{SUCCESS_TAKE_EVENT}'
            AND {client.environment_clause()}
            AND distinct_id IN ({sql_id_list(chunk)})
            AND properties.{TAKE_PROPERTY} IS NOT NULL
            AND properties.{TAKE_PROPERTY} != ''
            AND toUnixTimestamp64Milli(timestamp) >= {window.start_millis}
            AND toUnixTimestamp64Milli(timestamp) <= {window.end_millis}
        """

        # `upper(...)` on BOTH distinct operations. Without it the total counts an
        # upper- and a lowercase spelling of one take as two successes while the
        # overlap normalizes them to one — inflating the union by the difference.
        rows, _ = client.query(
            f"""
            SELECT distinct_id,
                   properties.app_version AS release,
                   uniqExact(upper(properties.{TAKE_PROPERTY})) AS success_takes,
                   uniqExactIf(
                       upper(properties.{TAKE_PROPERTY}),
                       ({overlap_predicate})
                   ) AS overlap_takes,
                   countIf(
                       match(
                           toString(properties.{TAKE_PROPERTY}),
                           '{TAKE_ID_HOGQL_PATTERN}'
                       ) = 0
                   ) AS invalid_take_rows
            FROM events
            WHERE {take_rate_filter}
            GROUP BY distinct_id, release
            """,
            f"take_rate_p{index}",
        )

        # Independent identical-filter total, the same discipline
        # `verify_bucket_completeness` applies to install usage. A truncated
        # response would silently drop success buckets and INFLATE the rate.
        completeness_rows, _ = client.query(
            f"""
            SELECT uniqExact(
                concat(
                    toString(distinct_id),
                    '|',
                    toString(properties.app_version)
                )
            )
            FROM events
            WHERE {take_rate_filter}
            """,
            f"take_rate_completeness_p{index}",
        )
        if len(completeness_rows) != 1 or len(completeness_rows[0]) != 1:
            raise ProtocolError(
                f"take_rate_completeness_p{index}: expected one row with one count"
            )
        independent_buckets = required_count(
            completeness_rows[0][0], f"take_rate_completeness_p{index}"
        )
        if len(rows) != independent_buckets:
            raise IncompleteError(
                f"take_rate_p{index}: received {len(rows)} install-release buckets "
                f"but an independent identical-filter uniqExact returned "
                f"{independent_buckets} — refusing a potentially truncated rate"
            )
        for row in rows:
            if len(row) != 5:
                raise ProtocolError(f"take_rate_p{index}: expected 5 columns, got {len(row)}")
            install, release_raw, success_takes, overlap_takes, invalid_take_rows = row
            invalid_count = required_count(
                invalid_take_rows, f"take_rate_p{index}: invalid_take_rows"
            )
            if invalid_count:
                raise ProtocolError(
                    f"take_rate_p{index}: {invalid_count} successful rows carry a "
                    "non-canonical take_id — refusing to include fabricated take identities"
                )
            if not isinstance(install, str) or install not in chunk_set:
                raise ProtocolError(f"take_rate_p{index}: unexpected distinct_id in results")
            release = canonical_app_version(release_raw, f"take_rate_p{index}")
            success_count = required_count(success_takes, f"take_rate_p{index}: success_takes")
            overlap_count = required_count(overlap_takes, f"take_rate_p{index}: overlap_takes")
            if overlap_count > success_count:
                raise ProtocolError(
                    f"take_rate_p{index}: overlap {overlap_count} exceeds successes "
                    f"{success_count} — a subset cannot exceed its set"
                )
            successes[(install, release)] += success_count
            overlaps[(install, release)] += overlap_count
        completed_indexes.add(index)

    require_complete_partitions(expected_indexes, completed_indexes)

    # THE AFFECTED-USER DENOMINATOR IS POPULATION-WIDE, and it has to be queried
    # separately. Every query above is scoped to installs that ALREADY carry an
    # affected take, so deriving the denominator from them made it a superset of
    # itself and the rate was a structural 100% on every affected release — a
    # denominator drawn from its own numerator. The first version of the
    # arithmetic case froze that as `1/1`.
    # ELIGIBLE, not SUCCESSFUL. Plan section 5 defines the affected-user rate over
    # "installs with >=1 ELIGIBLE take" — any of the 13 keyed events — while the
    # TAKE-level rate above deliberately uses successful `dictation.completed`
    # takes. One filter served both and quietly narrowed this denominator: an
    # install with keyed VAD, invocation or failure events but no successful
    # completion vanished from it, inflating the rate. The two populations are
    # different by design and now have different filters.
    population_filter = f"""
        event IN ({sql_id_list(TAKE_KEYED_EVENTS)})
        AND {client.environment_clause()}
        AND properties.{TAKE_PROPERTY} IS NOT NULL
        AND properties.{TAKE_PROPERTY} != ''
        AND toUnixTimestamp64Milli(timestamp) >= {window.start_millis}
        AND toUnixTimestamp64Milli(timestamp) <= {window.end_millis}
    """
    # RELEASE-SCOPED, the same way the take overlap is. A global affected-install
    # list counts an install affected only on release A as affected overlap on
    # release B, which either understates B's denominator or trips the
    # impossible-pair guard. This is the install-level twin of the take-level
    # release scoping above — I fixed one and left the other, which is a partial
    # port, not two accidents.
    affected_installs_by_release: dict[str, set[str]] = defaultdict(set)
    for (affected_install, affected_release) in report.affected_takes_by_install_release:
        affected_installs_by_release[affected_release].add(affected_install)
    affected_install_predicate = "\n OR ".join(
        f"""(
            properties.app_version = {sql_id_list([release_name])}
            AND distinct_id IN ({sql_id_list(sorted(install_ids))})
        )"""
        for release_name, install_ids in sorted(affected_installs_by_release.items())
    )

    population_rows, _ = client.query(
        f"""
        SELECT properties.app_version AS release,
               uniqExact(distinct_id) AS eligible_installs,
               uniqExactIf(
                   distinct_id,
                   ({affected_install_predicate})
               ) AS affected_eligible_installs,
               countIf(
                   match(
                       toString(properties.{TAKE_PROPERTY}),
                       '{TAKE_ID_HOGQL_PATTERN}'
                   ) = 0
               ) AS invalid_take_rows
        FROM events
        WHERE {population_filter}
        GROUP BY release
        """,
        "take_rate_user_population",
    )
    eligible_install_counts: dict[str, int] = defaultdict(int)
    affected_eligible_install_counts: dict[str, int] = defaultdict(int)
    for row in population_rows:
        if len(row) != 4:
            raise ProtocolError(
                f"take_rate_user_population: expected 4 columns, got {len(row)}"
            )
        release_raw, eligible_installs, affected_eligible_installs, invalid_take_rows = row
        release = canonical_app_version(release_raw, "take_rate_user_population")
        # This query INDEPENDENTLY produces the affected-user denominator, so it
        # needs its own validity check — inheriting the bucket query's would be
        # trusting a different result set.
        if required_count(
            invalid_take_rows, f"take_rate_user_population: invalid_take_rows on {release}"
        ):
            raise ProtocolError(
                f"take_rate_user_population: rows on {release} carry a non-canonical "
                "take_id — refusing to include fabricated take identities"
            )
        eligible_install_counts[release] += required_count(
            eligible_installs,
            f"take_rate_user_population: eligible_installs on {release}",
        )
        affected_eligible_install_counts[release] += required_count(
            affected_eligible_installs,
            f"take_rate_user_population: affected_eligible_installs on {release}",
        )

    # Independent identical-filter total for THIS grouped result. Without it a
    # truncated response loses a release row, `defaultdict(int)` substitutes zero,
    # and the eligible denominator can come back smaller than its own numerator.
    population_completeness_rows, _ = client.query(
        f"""
        SELECT uniqExact(toString(properties.app_version))
        FROM events
        WHERE {population_filter}
        """,
        "take_rate_user_population_completeness",
    )
    if len(population_completeness_rows) != 1 or len(population_completeness_rows[0]) != 1:
        raise ProtocolError(
            "take_rate_user_population_completeness: expected one row with one count"
        )
    independent_releases = required_count(
        population_completeness_rows[0][0], "take_rate_user_population_completeness"
    )
    if len(population_rows) != independent_releases:
        raise IncompleteError(
            f"take_rate_user_population: received {len(population_rows)} release buckets "
            f"but an independent identical-filter uniqExact returned {independent_releases}"
        )

    # Per release. Take IDs are UUIDs, so different installs' sets are disjoint and
    # their union sizes add.
    per_release_affected: dict[str, int] = defaultdict(int)
    per_release_union: dict[str, int] = defaultdict(int)
    affected_installs: dict[str, set[str]] = defaultdict(set)

    # Report only releases on which this fingerprint HAS an affected take. A
    # successful take on some other release is not a zero-rate row for this
    # fingerprint; it is a release this fingerprint was never seen on.
    pairs = set(report.affected_takes_by_install_release)
    for install, release in sorted(pairs):
        affected = len(report.affected_takes_by_install_release.get((install, release), set()))
        union = affected + successes[(install, release)] - overlaps[(install, release)]
        if union < affected:
            raise ProtocolError(
                f"take rate for {install} on {release}: union {union} is smaller than the "
                f"{affected} affected takes it must contain — refusing to render"
            )
        per_release_affected[release] += affected
        per_release_union[release] += union
        if affected:
            affected_installs[release].add(install)

    # A checked loop, not a comprehension: the install arithmetic draws from two
    # SEPARATE query results, so it can produce an impossible pair that a
    # comprehension would silently return.
    result: list[TakeRateRow] = []
    for release in sorted(per_release_union, key=version_key):
        affected_count = len(affected_installs[release])
        eligible_population_count = eligible_install_counts[release]
        # The overlap comes from the population query itself rather than from the
        # bucket results, so both sides of the subtraction are drawn from the same
        # eligible population — deriving it from `successes` would mix two filters.
        overlap_count = affected_eligible_install_counts[release]

        if overlap_count > affected_count or overlap_count > eligible_population_count:
            raise ProtocolError(
                f"affected-user rate on {release}: affected/eligible overlap "
                f"{overlap_count} exceeds affected={affected_count} or "
                f"eligible={eligible_population_count}"
            )

        # |affected ∪ eligible| installs. Subtracting the installs counted on BOTH
        # sides keeps an install that is both affected and eligible from being
        # counted twice — the install-level twin of the take-level overlap
        # subtraction above.
        eligible_count = affected_count + eligible_population_count - overlap_count
        if eligible_count < affected_count:
            raise ProtocolError(
                f"affected-user rate on {release}: eligible denominator "
                f"{eligible_count} is smaller than affected numerator {affected_count}"
            )

        result.append(
            TakeRateRow(
                release=release,
                affected_takes=per_release_affected[release],
                union_takes=per_release_union[release],
                affected_installs=affected_count,
                eligible_installs=eligible_count,
            )
        )
    return result


def normalize_setting(name: str, value: object) -> object:
    """`filler_removal` shipped as a legacy Bool before becoming on/off, so the
    same setting arrives in two vocabularies
    (analytics-operations.md FACT: settings-config-reconstruction).
    """
    if value is None or value == "":
        return None
    if name == "filler_removal":
        text = str(value).strip().lower()
        if text in ("true", "1", "on", "yes"):
            return "on"
        if text in ("false", "0", "off", "no"):
            return "off"
    return value


# --------------------------------------------------------------------------
# Rendering. Every value is computed and validated BEFORE any output, so a late
# failure cannot leave a half-table that reads as complete
# (PROC: measurement-tool-hardening).
# --------------------------------------------------------------------------
def render_take_coverage(coverage: Sequence[TakeCoverageRow]) -> list[str]:
    """Render the COMPLETE event x observed-release grid.

    A missing cell is `not observed`, never silently omitted. The first version
    printed `not observed` only when an event had no rows on ANY release, so an
    event present on 2.6.0 and gone on 2.7.0 lost its 2.7.0 row entirely — a
    blackout invisible in exactly the table built to catch blackouts.
    """
    lines = ["Take coverage by event and release (Phase 2). Never pooled across events:"]
    by_cell: dict[tuple[str, str], TakeCoverageRow] = {}

    for row in coverage:
        key = (row.event, row.release)
        if key in by_cell:
            raise ProtocolError(
                f"take coverage contains duplicate rows for {row.event} on {row.release}"
            )
        by_cell[key] = row

    unexpected = sorted({event for event, _ in by_cell} - set(TAKE_KEYED_EVENTS))
    if unexpected:
        raise ProtocolError(
            f"take coverage contains unlisted events: {', '.join(unexpected)}"
        )

    releases = sorted({release for _, release in by_cell}, key=version_key)
    if not releases:
        for event in TAKE_KEYED_EVENTS:
            lines.append(f"  {event}: {NOT_OBSERVED}")
        return lines

    for event in TAKE_KEYED_EVENTS:
        for release in releases:
            row = by_cell.get((event, release))
            if row is None:
                lines.append(f"  {event} on {release}: {NOT_OBSERVED}")
                continue
            marker = "   <- no take keys" if row.with_take == 0 else ""
            lines.append(
                f"  {event} on {release}: "
                f"{row.with_take}/{row.total} rows carry {TAKE_PROPERTY}{marker}"
            )

    return lines


def render_take_rates(
    rates: Sequence[TakeRateRow], window: TakeWindow | None, has_affected_takes: bool
) -> list[str]:
    """Prints counts alongside every percentage. A bare rate cannot be checked;
    `12/400` can.
    """
    lines = ["Fingerprint take rate (Phase 2) — distinct TAKES, never raw events:"]
    if window is None:
        lines.append(f"  {NOT_OBSERVED} — no eligible events, so no window exists")
        return lines
    if not has_affected_takes:
        # Deliberately does NOT say why. The tool cannot tell a population that
        # predates the tag from one that shipped it and is broken, and guessing
        # would be the same fabrication the join-coverage block refuses to make.
        # It says only what it measured: no key was seen. That is not a zero rate.
        lines.append(
            f"  {NOT_OBSERVED} — no event on this fingerprint carries {TAKE_TAG}. "
            "Absence is non-diagnostic (plan §7) and is not a failure rate of zero."
        )
        return lines
    if window.degenerate:
        # The explanation deliberately carries NO numeral. A refusal that prints
        # the figure it is refusing invites exactly the misreading it exists to
        # prevent — a skimming human takes the number and drops the refusal.
        lines.append(
            "  REFUSED — the eligible events produce no positive-width observation "
            "interval at PostHog precision. A rate from one timestamp would be "
            "dominated by coincident event timing, not a measured population span."
        )
        return lines
    if not rates:
        lines.append(f"  {NOT_OBSERVED} — no release produced a non-empty take union")
        return lines

    # Render the bounds ACTUALLY QUERIED, at the precision actually used. Printing
    # `start_epoch` through a whole-second formatter displayed a window the query
    # never ran — a caption for a different measurement.
    start = (
        datetime.datetime.fromtimestamp(window.start_millis / 1000, tz=datetime.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )
    end = (
        datetime.datetime.fromtimestamp(window.end_millis / 1000, tz=datetime.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )
    lines.append(
        f"  PostHog success window {start} .. {end}, rounded inward from the "
        "eligible Sentry event span."
    )
    lines.append(
        "  The affected Sentry takes retain the original boundary events. Because "
        "the success window cannot extend beyond them and may exclude boundary "
        "successes, this take rate is an UPPER BOUND."
    )
    lines.append(
        "  SCOPE: the take rate is CONDITIONAL on installs this fingerprint "
        "affected — its denominator is those installs' own takes (plan §5). Read it "
        "as \"among people who hit this, how much of their dictation failed\", NOT "
        "as a fleet-wide share. The installs-affected figure beside it IS "
        "population-wide, over every install carrying an eligible take."
    )
    for row in rates:
        rate = row.affected_takes / row.union_takes if row.union_takes else 0.0
        lines.append(
            f"  {row.release}: {row.affected_takes}/{row.union_takes} takes affected "
            f"({rate:.1%}); {row.affected_installs}/{row.eligible_installs} installs affected"
        )
    return lines


def render_report(
    report: FingerprintReport,
    usage: Mapping[str, InstallUsage],
    take_coverage: Sequence[TakeCoverageRow] = (),
    take_rates: Sequence[TakeRateRow] = (),
) -> str:
    lines: list[str] = []
    lines.append(f"Sentry fingerprint {report.issue} — joined to PostHog usage (#1846)")
    lines.append(f"Environment: {report.environment}")
    if report.excluded_counts:
        lines.append("Excluded from this report (counted, never silently dropped):")
        for reason in sorted(report.excluded_counts):
            lines.append(f"  {report.excluded_counts[reason]} events: {reason}")
    lines.append("")
    lines.append("PEOPLE, not events. Identity populations are never combined.")
    lines.append("")
    lines.append(
        f"{'release':<12}{'events':>8}{'identities':>12}"
        f"{'events/id':>11}  identity source"
    )
    lines.append("-" * 88)
    for row in report.release_rows:
        lines.append(
            f"{row.release:<12}{row.events:>8}{row.identities:>12}"
            f"{row.events_per_identity:>11.1f}  {row.identity_source}"
        )
    lines.append("-" * 88)
    for total in report.population_totals:
        lines.append(
            f"{'TOTAL':<12}{total.events:>8}{total.identities:>12}"
            f"{total.events_per_identity:>11.1f}  {total.identity_source}"
        )

    lines.append("")
    # FOUNDER DECISION 2026-07-29: per-release only, deliberately NO overall
    # figure. An overall percentage would need to know which releases shipped the
    # join key, and every way of supplying that (a flag to remember, a constant to
    # update, or inference from the data) can silently mismeasure — inference
    # worst of all, because it would HIDE a shipped release joining at 0%.
    # A zero-coverage release is marked but NOT explained: the tool cannot tell a
    # release that predates the key from one that shipped it and is broken, and
    # guessing which would be the same fabrication.
    lines.append("Join coverage by release (no overall figure — see the code comment):")
    for release in sorted(report.join_coverage_by_release, key=version_key):
        joined, total_events = report.join_coverage_by_release[release]
        marker = "   <- no joined events" if joined == 0 else ""
        lines.append(
            f"  {release}: {joined}/{total_events} events carry {JOIN_TAG}{marker}"
        )

    all_event_count = sum(total.events for total in report.population_totals)
    if report.unjoined_events:
        lines.append("")
        lines.append(
            f"{report.unjoined_events} of {all_event_count} events carry no "
            f"{JOIN_TAG}. They remain a separately labelled legacy population."
        )
    lines.append("")

    lines.extend(render_take_coverage(take_coverage))
    lines.append("")
    lines.extend(
        render_take_rates(
            take_rates,
            report.take_window,
            has_affected_takes=bool(report.affected_takes_by_install_release),
        )
    )
    lines.append("")

    if report.bursts:
        lines.append("Retry bursts (one person retrying, not a trend):")
        for burst in report.bursts:
            lines.append(
                f"  {burst.identity}  release {burst.release}: "
                f"{burst.events_in_window} events inside {burst.window_seconds}s"
            )
        lines.append("")

    lines.append("Per-install configuration and that install's OWN success record.")
    lines.append("This is the denominator Sentry cannot show.")
    lines.append("")
    for install_id in report.joined_install_ids:
        entry = usage.get(install_id)
        lines.append(f"install {install_id}")
        if entry is None:
            lines.append(f"  {NO_USAGE_ROWS}")
            lines.append("")
            continue
        config = ", ".join(
            f"{name}="
            f"{entry.settings.get(name) if entry.settings.get(name) is not None else 'unset'}"
            for name in RECONSTRUCTED_SETTINGS
        )
        lines.append(f"  config: {config}")

        affected = report.joined_releases_by_install.get(install_id, set())
        if not entry.has_usage_rows:
            lines.append(f"  {NO_USAGE_ROWS}")
            lines.append("")
            continue

        for release in sorted(affected, key=version_key):
            successes = entry.successes_by_release.get(release, 0)
            pipeline_failed = entry.pipeline_failures_by_release.get(release, 0)
            lines.append(
                f"  {release}: {successes} successful dictations, "
                f"{pipeline_failed} pipeline.failed"
            )

        for name in ("effective_transport", "recording_seconds"):
            for release in sorted(affected, key=version_key):
                if not field_shipped_on(name, release):
                    lines.append(f"  {name} on {release}: {NOT_SHIPPED}")
        lines.append("")
    return "\n".join(lines)


def build_report(
    issue: str, sentry: SentryClient, posthog: PostHogClient, environment: str = "production"
) -> tuple[
    FingerprintReport, dict[str, InstallUsage], list[TakeCoverageRow], list[TakeRateRow]
]:
    numeric = sentry.resolve_issue_id(issue)
    events = sentry.fetch_events(numeric)
    if not events:
        raise IncompleteError(
            f"issue {issue} returned zero events — nothing to join. This is not a "
            "measurement of zero users."
        )
    selection = select_eligible_events(events, environment)
    if not selection.eligible:
        raise IncompleteError(
            f"issue {issue} has {len(events)} events but none eligible for "
            f"environment={environment} — this is not a measurement of zero users. "
            f"Exclusions: {selection.excluded_counts}"
        )
    report = aggregate_fingerprint(
        issue, selection.eligible, environment, selection.excluded_counts
    )
    if environment == "production":
        posthog.resolve_dev_ids()
    usage = fetch_install_usage(posthog, report.joined_install_ids)
    take_coverage = fetch_take_coverage(posthog)
    take_rates = fetch_take_rates(posthog, report)
    return report, usage, take_coverage, take_rates


# ==========================================================================
# SELF-TEST ONLY BELOW THIS LINE
#
# RECORDED_ENVIOUSWISPR_2F_EVENT_RECORDS is the recorded, pseudonymized shape of
# the real three-page ENVIOUSWISPR-2F result (measured 2026-07-29, 90d). It is
# STATIC and is deliberately independent of EXPECTED_ENVIOUSWISPR_2F below:
# nothing derives one from the other. Deriving the fixture from the expected
# counts would make the baseline case a simulation testing itself
# (RULE: measure-with-the-real-tool-never-a-simulation).
#
# Every field is either synthetic (event ids e0001.., install ids a01..a60) or
# a real release string. No real event id, user id, city, message, stack trace
# or unrelated tag is present.
#
# The per-release identity SETS overlap on purpose — 68 release-memberships
# across 60 distinct installs — because that overlap is the property a naive
# implementation gets wrong: summing per-release identity counts yields 68 and
# the true distinct total is 60.
# ==========================================================================
RECORDED_ENVIOUSWISPR_2F_EVENT_RECORDS = """\
2.2.1 a01 2026-06-04T06:00:11Z e0001
2.2.1 a01 2026-06-04T13:17:11Z e0002
2.3.0 a01 2026-06-08T06:00:11Z e0003
2.3.0 a02 2026-06-08T13:17:11Z e0004
2.3.0 a03 2026-06-08T20:34:11Z e0005
2.3.0 a04 2026-06-08T12:51:11Z e0006
2.3.0 a05 2026-06-08T19:08:11Z e0007
2.3.0 a06 2026-06-08T11:25:11Z e0008
2.3.0 a07 2026-06-08T18:42:11Z e0009
2.3.0 a08 2026-06-08T10:59:11Z e0010
2.3.0 a09 2026-06-08T17:16:11Z e0011
2.3.0 a01 2026-06-08T09:33:11Z e0012
2.3.0 a02 2026-06-08T16:50:11Z e0013
2.3.0 a03 2026-06-08T08:07:11Z e0014
2.3.0 a04 2026-06-08T15:24:11Z e0015
2.3.0 a05 2026-06-08T07:41:11Z e0016
2.3.0 a06 2026-06-08T14:58:11Z e0017
2.3.0 a07 2026-06-08T06:15:11Z e0018
2.3.0 a08 2026-06-08T13:32:11Z e0019
2.3.0 a09 2026-06-08T20:49:11Z e0020
2.3.0 a01 2026-06-08T12:06:11Z e0021
2.3.0 a02 2026-06-08T19:23:11Z e0022
2.3.0 a03 2026-06-08T11:40:11Z e0023
2.3.0 a04 2026-06-08T18:57:11Z e0024
2.3.0 a05 2026-06-08T10:14:11Z e0025
2.3.0 a06 2026-06-08T17:31:11Z e0026
2.3.0 a07 2026-06-09T09:48:11Z e0027
2.3.0 a08 2026-06-09T16:05:11Z e0028
2.3.0 a09 2026-06-09T08:22:11Z e0029
2.3.0 a01 2026-06-09T15:39:11Z e0030
2.3.0 a02 2026-06-09T07:56:11Z e0031
2.3.0 a03 2026-06-09T14:13:11Z e0032
2.3.0 a04 2026-06-09T06:30:11Z e0033
2.3.0 a05 2026-06-09T13:47:11Z e0034
2.3.0 a06 2026-06-09T20:04:11Z e0035
2.3.0 a07 2026-06-09T12:21:11Z e0036
2.3.0 a08 2026-06-09T19:38:11Z e0037
2.3.0 a09 2026-06-09T11:55:11Z e0038
2.3.0 a01 2026-06-09T18:12:11Z e0039
2.3.0 a02 2026-06-09T10:29:11Z e0040
2.3.0 a03 2026-06-09T17:46:11Z e0041
2.3.0 a04 2026-06-09T09:03:11Z e0042
2.3.0 a05 2026-06-09T16:20:11Z e0043
2.3.0 a06 2026-06-09T08:37:11Z e0044
2.3.0 a07 2026-06-09T15:54:11Z e0045
2.3.0 a08 2026-06-09T07:11:11Z e0046
2.3.0 a09 2026-06-09T14:28:11Z e0047
2.3.1 a05 2026-06-13T06:00:11Z e0048
2.3.1 a06 2026-06-13T13:17:11Z e0049
2.3.1 a07 2026-06-13T20:34:11Z e0050
2.3.1 a08 2026-06-13T12:51:11Z e0051
2.3.1 a09 2026-06-13T19:08:11Z e0052
2.3.1 a10 2026-06-13T11:25:11Z e0053
2.3.1 a11 2026-06-13T18:42:11Z e0054
2.3.1 a12 2026-06-13T10:59:11Z e0055
2.3.1 a13 2026-06-13T17:16:11Z e0056
2.3.1 a14 2026-06-13T09:33:11Z e0057
2.3.1 a15 2026-06-13T16:50:11Z e0058
2.3.1 a16 2026-06-13T08:07:11Z e0059
2.3.1 a17 2026-06-13T15:24:11Z e0060
2.3.1 a18 2026-06-13T07:41:11Z e0061
2.3.1 a19 2026-06-13T14:58:11Z e0062
2.3.1 a20 2026-06-13T06:15:11Z e0063
2.3.1 a21 2026-06-13T13:32:11Z e0064
2.3.1 a22 2026-06-13T20:49:11Z e0065
2.3.1 a23 2026-06-13T12:06:11Z e0066
2.3.1 a24 2026-06-13T19:23:11Z e0067
2.3.1 a25 2026-06-13T11:40:11Z e0068
2.3.1 a26 2026-06-13T18:57:11Z e0069
2.3.1 a27 2026-06-13T10:14:11Z e0070
2.3.1 a28 2026-06-13T17:31:11Z e0071
2.3.1 a29 2026-06-14T09:48:11Z e0072
2.3.1 a30 2026-06-14T16:05:11Z e0073
2.3.1 a31 2026-06-14T08:22:11Z e0074
2.3.1 a32 2026-06-14T15:39:11Z e0075
2.3.1 a33 2026-06-14T07:56:11Z e0076
2.3.1 a34 2026-06-14T14:13:11Z e0077
2.3.1 a35 2026-06-14T06:30:11Z e0078
2.3.1 a36 2026-06-14T13:47:11Z e0079
2.3.1 a37 2026-06-14T20:04:11Z e0080
2.3.1 a05 2026-06-14T12:21:11Z e0081
2.3.1 a06 2026-06-14T19:38:11Z e0082
2.3.1 a07 2026-06-14T11:55:11Z e0083
2.3.1 a08 2026-06-14T18:12:11Z e0084
2.3.1 a09 2026-06-14T10:29:11Z e0085
2.3.1 a10 2026-06-14T17:46:11Z e0086
2.3.1 a11 2026-06-14T09:03:11Z e0087
2.3.1 a12 2026-06-14T16:20:11Z e0088
2.3.1 a13 2026-06-14T08:37:11Z e0089
2.3.1 a14 2026-06-14T15:54:11Z e0090
2.3.1 a15 2026-06-14T07:11:11Z e0091
2.3.1 a16 2026-06-14T14:28:11Z e0092
2.3.1 a17 2026-06-14T06:45:11Z e0093
2.3.1 a18 2026-06-14T13:02:11Z e0094
2.3.1 a19 2026-06-14T20:19:11Z e0095
2.3.1 a20 2026-06-15T12:36:11Z e0096
2.3.1 a21 2026-06-15T19:53:11Z e0097
2.3.1 a22 2026-06-15T11:10:11Z e0098
2.3.1 a23 2026-06-15T18:27:11Z e0099
2.3.1 a24 2026-06-15T10:44:11Z e0100
2.3.1 a25 2026-06-15T17:01:11Z e0101
2.3.1 a26 2026-06-15T09:18:11Z e0102
2.3.1 a27 2026-06-15T16:35:11Z e0103
2.3.1 a28 2026-06-15T08:52:11Z e0104
2.3.1 a29 2026-06-15T15:09:11Z e0105
2.3.1 a30 2026-06-15T07:26:11Z e0106
2.3.1 a31 2026-06-15T14:43:11Z e0107
2.3.1 a32 2026-06-15T06:00:11Z e0108
2.3.1 a33 2026-06-15T13:17:11Z e0109
2.3.1 a34 2026-06-15T20:34:11Z e0110
2.3.1 a35 2026-06-15T12:51:11Z e0111
2.3.1 a36 2026-06-15T19:08:11Z e0112
2.3.1 a37 2026-06-15T11:25:11Z e0113
2.3.1 a05 2026-06-15T18:42:11Z e0114
2.3.1 a06 2026-06-15T10:59:11Z e0115
2.3.1 a07 2026-06-15T17:16:11Z e0116
2.3.1 a08 2026-06-15T09:33:11Z e0117
2.3.1 a09 2026-06-15T16:50:11Z e0118
2.3.1 a10 2026-06-15T08:07:11Z e0119
2.3.1 a11 2026-06-16T15:24:11Z e0120
2.3.1 a12 2026-06-16T07:41:11Z e0121
2.3.1 a13 2026-06-16T14:58:11Z e0122
2.3.1 a14 2026-06-16T06:15:11Z e0123
2.3.1 a15 2026-06-16T13:32:11Z e0124
2.3.1 a16 2026-06-16T20:49:11Z e0125
2.3.1 a17 2026-06-16T12:06:11Z e0126
2.3.1 a18 2026-06-16T19:23:11Z e0127
2.3.1 a19 2026-06-16T11:40:11Z e0128
2.3.1 a20 2026-06-16T18:57:11Z e0129
2.3.1 a21 2026-06-16T10:14:11Z e0130
2.3.1 a22 2026-06-16T17:31:11Z e0131
2.3.1 a23 2026-06-16T09:48:11Z e0132
2.3.1 a24 2026-06-16T16:05:11Z e0133
2.3.1 a25 2026-06-16T08:22:11Z e0134
2.3.1 a26 2026-06-16T15:39:11Z e0135
2.3.1 a27 2026-06-16T07:56:11Z e0136
2.3.1 a28 2026-06-16T14:13:11Z e0137
2.3.1 a29 2026-06-16T06:30:11Z e0138
2.3.1 a30 2026-06-16T13:47:11Z e0139
2.3.1 a31 2026-06-16T20:04:11Z e0140
2.3.1 a32 2026-06-16T12:21:11Z e0141
2.3.1 a33 2026-06-16T19:38:11Z e0142
2.3.1 a34 2026-06-16T11:55:11Z e0143
2.3.1 a35 2026-06-17T18:12:11Z e0144
2.3.1 a36 2026-06-17T10:29:11Z e0145
2.3.1 a37 2026-06-17T17:46:11Z e0146
2.3.1 a05 2026-06-17T09:03:11Z e0147
2.3.1 a06 2026-06-17T16:20:11Z e0148
2.3.1 a07 2026-06-17T08:37:11Z e0149
2.3.1 a08 2026-06-17T15:54:11Z e0150
2.3.1 a09 2026-06-17T07:11:11Z e0151
2.3.1 a10 2026-06-17T14:28:11Z e0152
2.3.1 a11 2026-06-17T06:45:11Z e0153
2.3.1 a12 2026-06-17T13:02:11Z e0154
2.3.1 a13 2026-06-17T20:19:11Z e0155
2.3.1 a14 2026-06-17T12:36:11Z e0156
2.3.1 a15 2026-06-17T19:53:11Z e0157
2.3.1 a16 2026-06-17T11:10:11Z e0158
2.3.1 a17 2026-06-17T18:27:11Z e0159
2.3.1 a18 2026-06-17T10:44:11Z e0160
2.3.1 a19 2026-06-17T17:01:11Z e0161
2.3.1 a20 2026-06-17T09:18:11Z e0162
2.3.1 a21 2026-06-17T16:35:11Z e0163
2.3.1 a22 2026-06-17T08:52:11Z e0164
2.3.1 a23 2026-06-17T15:09:11Z e0165
2.3.1 a24 2026-06-17T07:26:11Z e0166
2.3.1 a25 2026-06-17T14:43:11Z e0167
2.3.1 a26 2026-06-18T06:00:11Z e0168
2.3.1 a27 2026-06-18T13:17:11Z e0169
2.3.1 a28 2026-06-18T20:34:11Z e0170
2.3.1 a29 2026-06-18T12:51:11Z e0171
2.3.1 a30 2026-06-18T19:08:11Z e0172
2.3.2 a38 2026-06-19T06:00:11Z e0173
2.3.2 a39 2026-06-19T13:17:11Z e0174
2.3.2 a40 2026-06-19T20:34:11Z e0175
2.3.2 a41 2026-06-19T12:51:11Z e0176
2.3.2 a42 2026-06-19T19:08:11Z e0177
2.3.2 a43 2026-06-19T11:25:11Z e0178
2.3.2 a44 2026-06-19T18:42:11Z e0179
2.3.2 a45 2026-06-19T10:59:11Z e0180
2.3.2 a46 2026-06-19T17:16:11Z e0181
2.3.2 a47 2026-06-19T09:33:11Z e0182
2.3.2 a48 2026-06-19T16:50:11Z e0183
2.3.2 a49 2026-06-19T08:07:11Z e0184
2.3.2 a50 2026-06-19T15:24:11Z e0185
2.3.2 a51 2026-06-19T07:41:11Z e0186
2.3.2 a52 2026-06-19T14:58:11Z e0187
2.3.2 a53 2026-06-19T06:15:11Z e0188
2.3.2 a54 2026-06-19T13:32:11Z e0189
2.3.2 a55 2026-06-19T20:49:11Z e0190
2.3.2 a56 2026-06-19T12:06:11Z e0191
2.3.2 a57 2026-06-19T19:23:11Z e0192
2.3.2 a58 2026-06-19T11:40:11Z e0193
2.3.2 a59 2026-06-19T18:57:11Z e0194
2.3.2 a38 2026-06-19T10:14:11Z e0195
2.3.2 a39 2026-06-19T17:31:11Z e0196
2.3.2 a40 2026-06-20T09:48:11Z e0197
2.3.2 a41 2026-06-20T16:05:11Z e0198
2.3.2 a42 2026-06-20T08:22:11Z e0199
2.3.2 a43 2026-06-20T15:39:11Z e0200
2.3.2 a44 2026-06-20T07:56:11Z e0201
2.3.2 a45 2026-06-20T14:13:11Z e0202
2.3.2 a46 2026-06-20T06:30:11Z e0203
2.3.2 a47 2026-06-20T13:47:11Z e0204
2.3.2 a48 2026-06-20T20:04:11Z e0205
2.3.2 a49 2026-06-20T12:21:11Z e0206
2.3.2 a50 2026-06-20T19:38:11Z e0207
2.3.2 a51 2026-06-20T11:55:11Z e0208
2.3.2 a52 2026-06-20T18:12:11Z e0209
2.3.2 a53 2026-06-20T10:29:11Z e0210
2.3.2 a54 2026-06-20T17:46:11Z e0211
2.3.2 a55 2026-06-20T09:03:11Z e0212
2.3.2 a56 2026-06-20T16:20:11Z e0213
2.3.2 a57 2026-06-20T08:37:11Z e0214
2.3.2 a58 2026-06-20T15:54:11Z e0215
2.3.2 a59 2026-06-20T07:11:11Z e0216
2.3.2 a38 2026-06-20T14:28:11Z e0217
2.3.2 a39 2026-06-20T06:45:11Z e0218
2.3.2 a40 2026-06-20T13:02:11Z e0219
2.3.2 a41 2026-06-20T20:19:11Z e0220
2.3.2 a42 2026-06-21T12:36:11Z e0221
2.3.2 a43 2026-06-21T19:53:11Z e0222
2.3.2 a44 2026-06-21T11:10:11Z e0223
2.3.2 a45 2026-06-21T18:27:11Z e0224
2.3.2 a46 2026-06-21T10:44:11Z e0225
2.3.2 a47 2026-06-21T17:01:11Z e0226
2.3.2 a48 2026-06-21T09:18:11Z e0227
2.3.2 a49 2026-06-21T16:35:11Z e0228
2.3.2 a50 2026-06-21T08:52:11Z e0229
2.3.2 a51 2026-06-21T15:09:11Z e0230
2.3.2 a52 2026-06-21T07:26:11Z e0231
2.3.2 a53 2026-06-21T14:43:11Z e0232
2.3.2 a54 2026-06-21T06:00:11Z e0233
2.3.2 a55 2026-06-21T13:17:11Z e0234
2.3.2 a56 2026-06-21T20:34:11Z e0235
2.3.2 a57 2026-06-21T12:51:11Z e0236
2.3.2 a58 2026-06-21T19:08:11Z e0237
2.3.2 a59 2026-06-21T11:25:11Z e0238
2.3.2 a38 2026-06-21T18:42:11Z e0239
2.3.2 a39 2026-06-21T10:59:11Z e0240
2.3.2 a40 2026-06-21T17:16:11Z e0241
2.3.2 a41 2026-06-21T09:33:11Z e0242
2.3.2 a42 2026-06-21T16:50:11Z e0243
2.3.2 a43 2026-06-21T08:07:11Z e0244
2.3.2 a44 2026-06-22T15:24:11Z e0245
2.3.2 a45 2026-06-22T07:41:11Z e0246
2.4.0 a60 2026-06-24T06:00:11Z e0247
2.4.0 a60 2026-06-24T13:17:11Z e0248
2.4.1 a59 2026-06-26T06:00:11Z e0249
2.4.1 a60 2026-06-26T13:17:11Z e0250
2.4.1 a59 2026-06-26T20:34:11Z e0251
2.4.1 a60 2026-06-26T12:51:11Z e0252
2.4.1 a59 2026-06-26T19:08:11Z e0253
2.4.1 a60 2026-06-26T11:25:11Z e0254
2.4.1 a59 2026-06-26T18:42:11Z e0255
"""

EXPECTED_ENVIOUSWISPR_2F = {
    "2.2.1": (2, 1, 2.0),
    "2.3.0": (45, 9, 5.0),
    "2.3.1": (125, 33, 3.8),
    "2.3.2": (74, 22, 3.4),
    "2.4.0": (2, 1, 2.0),
    "2.4.1": (7, 2, 3.5),
}
EXPECTED_ENVIOUSWISPR_2F_TOTAL = (255, 60, 4.2)

SENTINEL_SENTRY_KEY = "sentry-key-for-self-test-only"
SENTINEL_POSTHOG_KEY = "posthog-key-for-self-test-only"
FIXTURE_INSTALL_PREFIX = "0198a1b2-c3d4-7e5f-8a9b-"


def _fixture_install_uuid(short: str) -> str:
    """`a07` -> a canonical lowercase hyphenated UUID, so the fixture exercises
    the real `canonical_join_key` predicate rather than bypassing it.
    """
    return FIXTURE_INSTALL_PREFIX + f"{int(short[1:]):012d}"


def _recorded_events() -> list[dict[str, object]]:
    events: list[dict[str, object]] = []
    for line in RECORDED_ENVIOUSWISPR_2F_EVENT_RECORDS.strip().splitlines():
        release, install, stamp, event_id = line.split()
        events.append(
            {
                "id": event_id,
                "dateCreated": stamp,
                # No JOIN_TAG: this fingerprint was measured BEFORE the join key
                # shipped, so the baseline is necessarily the legacy Sentry
                # identity population (plan §3a). Tagging these events with a
                # join key would assert an identity that could not have existed.
                "user": {"id": f"legacy-sentry-{install}"},
                "tags": [
                    # Packaged, exactly as Sentry receives it. The earlier bare
                    # value HID the release-key mismatch defect from all 255 rows.
                    {"key": "release", "value": _SENTRY_RELEASE_PREFIX + release},
                    # The recorded population was measured on production data.
                    {"key": "environment", "value": "production"},
                ],
            }
        )
    return events


def recorded_sentry_pages() -> list[tuple[int, bytes, dict[str, str]]]:
    """Pack the recorded records into the THREE raw JSON response bodies the real
    paginated call returned, with real-shaped Link headers.
    """
    events = _recorded_events()
    sizes = [100, 100, 55]
    pages: list[tuple[int, bytes, dict[str, str]]] = []
    start = 0
    for page_index, size in enumerate(sizes):
        body = json.dumps(events[start:start + size]).encode("utf-8")
        start += size
        is_last = page_index == len(sizes) - 1
        next_url = (
            f"{SENTRY_HOST}/api/0/issues/6712345678/events/?full=true&cursor=c{page_index + 1}"
        )
        link = (
            f'<{SENTRY_HOST}/api/0/issues/6712345678/events/?full=true>; rel="previous"; '
            f'results="false"; cursor="p{page_index}", '
            f'<{next_url}>; rel="next"; results="{"false" if is_last else "true"}"; '
            f'cursor="c{page_index + 1}"'
        )
        pages.append((200, body, {"Link": link}))
    return pages


@dataclass
class FixtureTransport:
    """Receives the REAL HTTPRequest the production clients build, asserts its
    shape, and returns queued raw HTTPResponse values. It parses nothing and
    duplicates no production logic.
    """
    queue: list[HTTPResponse]
    seen: list[HTTPRequest] = field(default_factory=list)

    def __call__(self, request: HTTPRequest) -> HTTPResponse:
        auth = request.headers.get("Authorization", "")
        assert auth.startswith("Bearer "), "every vendor request must carry a Bearer header"
        for sentinel in (SENTINEL_SENTRY_KEY, SENTINEL_POSTHOG_KEY):
            if sentinel in auth:
                break
        else:
            raise AssertionError("self-test transport saw a non-sentinel credential")
        self.seen.append(request)
        if not self.queue:
            raise AssertionError(f"fixture queue exhausted at {request.method} {request.url}")
        return self.queue.pop(0)


def _json_response(payload: object, status: int = 200) -> HTTPResponse:
    return HTTPResponse(status, {"Content-Type": "application/json"}, json.dumps(payload).encode())


def _posthog_response(rows: list[list[object]], columns: list[str] | None = None) -> HTTPResponse:
    return _json_response({"results": rows, "columns": columns or []})


def _sentry_client(responses: list[HTTPResponse]) -> tuple[SentryClient, FixtureTransport]:
    transport = FixtureTransport(list(responses))
    return SentryClient(SENTINEL_SENTRY_KEY, transport), transport


def _posthog_client(responses: list[HTTPResponse]) -> tuple[PostHogClient, FixtureTransport]:
    transport = FixtureTransport(list(responses))
    slept: list[float] = []
    client = PostHogClient(SENTINEL_POSTHOG_KEY, transport, slept.append)
    client.slept = slept  # type: ignore[attr-defined]
    return client, transport


def _recorded_page_responses() -> list[HTTPResponse]:
    return [
        HTTPResponse(status, {**headers, "Content-Type": "application/json"}, body)
        for status, body, headers in recorded_sentry_pages()
    ]


def _expect_raises(
    exc_type: type[BaseException],
    fn: Callable[[], object],
    what: str,
    message: str | None = None,
) -> None:
    """`message` is the fix for how this round's finding hid: six pagination cases
    asserted only `ProtocolError`, and a LATER hardening change made the fixture
    fail at the release guard first. Both paths raise the same type, so the tests
    kept passing while testing nothing. Where several guards share a type, assert
    the message so the test names the guard it is actually exercising.
    """
    try:
        fn()
    except exc_type as exc:
        if message is not None and message not in str(exc):
            raise AssertionError(
                f"{what}: raised {exc_type.__name__} but from the WRONG guard — "
                f"expected message containing {message!r}, got {str(exc)!r}"
            )
        return
    except Exception as other:  # noqa: BLE001
        raise AssertionError(f"{what}: expected {exc_type.__name__}, got {other!r}")
    raise AssertionError(f"{what}: expected {exc_type.__name__}, nothing raised")


def run_self_test() -> int:
    """Run every named case. A failing case raises AssertionError, which `main`
    converts into a non-zero exit.

    STATED LIMIT: this aborts at the FIRST failing case, so a run can hide later
    failures. Cases 1-3 deliberately share one fixture transport (case 3 asserts
    the request that case 1 made), which is why they are not isolated. The
    summary line below is only reachable when every case passed — it is not a
    counter that could ever print a non-zero failure count.
    """
    cases: list[str] = []

    def passed(name: str) -> None:
        cases.append(name)
        print(f"PASS  {name}")

    # 1 + 2: the recorded three-page baseline, and the per-release + total table.
    client, transport = _sentry_client(_recorded_page_responses())
    events = client.fetch_events("6712345678")
    assert len(events) == 255, f"expected 255 recorded events, got {len(events)}"
    selection_all = select_eligible_events(events, "production")
    assert len(selection_all.eligible) == 255, selection_all.excluded_counts
    assert selection_all.excluded_counts == {}, selection_all.excluded_counts
    assert len(transport.seen) == 3, f"expected 3 pages fetched, got {len(transport.seen)}"
    passed("recorded ENVIOUSWISPR-2F fixture paginates all three pages")

    report = aggregate_fingerprint("ENVIOUSWISPR-2F", events)
    actual = {r.release: (r.events, r.identities, r.events_per_identity) for r in report.release_rows}
    assert actual == EXPECTED_ENVIOUSWISPR_2F, f"per-release mismatch: {actual}"
    # This fingerprint predates the join key, so the baseline MUST be the legacy
    # Sentry identity population and there must be no joined population at all.
    assert report.joined_install_ids == [], report.joined_install_ids
    assert len(report.population_totals) == 1, report.population_totals
    baseline = report.population_totals[0]
    assert baseline.identity_source == LEGACY_IDENTITY_LABEL, baseline.identity_source
    assert (baseline.events, baseline.identities, baseline.events_per_identity) == (
        EXPECTED_ENVIOUSWISPR_2F_TOTAL
    ), (baseline.events, baseline.identities, baseline.events_per_identity)
    assert all(r.identity_source == LEGACY_IDENTITY_LABEL for r in report.release_rows)
    naive_sum = sum(v[1] for v in EXPECTED_ENVIOUSWISPR_2F.values())
    assert naive_sum == 68 and baseline.identities == 60, (
        "the fixture must keep cross-release identity overlap: summing per-release "
        f"identities gives {naive_sum}, the true distinct total is 60"
    )
    passed("baseline reproduces 255 events / 60 users / 4.2 on legacy Sentry identity")

    # 3: the Sentry request shape.
    first = transport.seen[0]
    assert first.method == "GET", first.method
    assert "/api/0/issues/6712345678/events/" in first.url, first.url
    assert "full=true" in first.url, first.url
    assert first.headers["Authorization"] == f"Bearer {SENTINEL_SENTRY_KEY}"
    passed("Sentry request is GET .../events/?full=true with a Bearer credential")

    # 4: the PostHog request envelope.
    ph, ph_transport = _posthog_client([_posthog_response([["a"]])])
    ph.query("SELECT 1", "shape")
    req = ph_transport.seen[0]
    assert req.method == "POST", req.method
    assert req.url == f"{POSTHOG_HOST}/api/projects/{POSTHOG_PROJECT_ID}/query/", req.url
    assert req.headers["Content-Type"] == "application/json"
    envelope = json.loads(req.body or b"{}")
    assert envelope["query"]["kind"] == "HogQLQuery", envelope
    assert envelope["refresh"] == "blocking", envelope
    assert envelope["name"] == "telemetry_join_shape", envelope
    passed("PostHog request is a blocking HogQLQuery to the project query endpoint")

    # 5 + 6: authentication failures on both vendors.
    client, _ = _sentry_client([HTTPResponse(401, {}, b"")])
    _expect_raises(AuthError, lambda: client.fetch_events("1"), "Sentry 401")
    passed("Sentry authentication failure raises AuthError and prints nothing")

    ph, _ = _posthog_client([HTTPResponse(403, {}, b"")])
    _expect_raises(AuthError, lambda: ph.query("SELECT 1", "auth"), "PostHog 403")
    passed("PostHog authorization failure raises AuthError and prints nothing")

    # 7: a 504 then success retries, with injected sleeps and no wall-clock wait.
    ph, _ = _posthog_client([HTTPResponse(504, {}, b""), _posthog_response([["ok"]])])
    rows, _cols = ph.query("SELECT 1", "retry")
    assert rows == [["ok"]], rows
    assert ph.slept == [RETRY_DELAYS_SECONDS[0]], ph.slept  # type: ignore[attr-defined]
    assert ph.attempts_made == [2], ph.attempts_made
    passed("a retryable 504 followed by success succeeds on attempt 2 without sleeping")

    # 8: exhausted retry fails the whole report.
    ph, _ = _posthog_client([HTTPResponse(504, {}, b"") for _ in range(MAX_ATTEMPTS)])
    _expect_raises(RetryExhaustedError, lambda: ph.query("SELECT 1", "dead"), "exhausted retry")
    passed("exhausted retry raises RetryExhaustedError, never a degraded table")

    # 9: malformed JSON.
    client, _ = _sentry_client([HTTPResponse(200, {}, b"{not json")])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), "malformed JSON",
        message="not valid JSON",
    )
    passed("malformed Sentry JSON fails closed")

    # 10: malformed Link header.
    # A VALID event: parsing must succeed so the pagination cases below actually
    # reach the pagination code rather than dying at the release guard.
    body = json.dumps(
        [
            {
                "id": "e1",
                "dateCreated": "2026-06-01T00:00:00Z",
                "user": {"id": "legacy-install"},
                "tags": [
                    {"key": "release", "value": "com.enviouswispr.app@2.4.1"},
                    {"key": "environment", "value": "production"},
                ],
            }
        ]
    ).encode()
    client, _ = _sentry_client([HTTPResponse(200, {"Link": "garbage-without-brackets"}, body)])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), "malformed Link",
        message="Link segment is unparseable",
    )
    passed("a malformed Link header fails closed instead of reading as no-next-page")

    # 11: results="true" with no usable next URL.
    link = '<not-a-url>; rel="next"; results="true"; cursor="c1"'
    client, _ = _sentry_client([HTTPResponse(200, {"Link": link}, body)])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), 'results="true" no URL',
        message="outside the exact Sentry issue endpoint",
    )
    passed('11. results="true" without a usable next URL fails closed')

    # 12: a pagination cycle.
    same = f"{SENTRY_HOST}/api/0/issues/1/events/?full=true"
    cycle = f'<{same}>; rel="next"; results="true"; cursor="c1"'
    client, _ = _sentry_client([HTTPResponse(200, {"Link": cycle}, body) for _ in range(3)])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), "pagination cycle",
        message="pagination cycle",
    )
    passed("a repeated pagination URL is detected as a cycle and fails closed")

    # 12b: a missing Link header is missing pagination AUTHORITY, not an ending.
    client, _ = _sentry_client([HTTPResponse(200, {}, body)])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), "missing Link header",
        message="missing Link header",
    )
    passed("a missing Link header fails closed instead of meaning complete")

    # 12c: a valid prefix must not hide malformed trailing material.
    malformed_tail = '<https://example.invalid/end>; rel="next"; results="false", trailing-garbage'
    client, _ = _sentry_client([HTTPResponse(200, {"Link": malformed_tail}, body)])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), "malformed trailing Link segment",
        message="Link segment is unparseable",
    )
    passed("the COMPLETE Link header must parse, not merely a valid prefix")

    # Ambiguous Link parameters must fail rather than silently using the last value.
    exact_endpoint = f"{SENTRY_HOST}/api/0/issues/1/events/?full=true"
    for malformed_link in (
        f'<{exact_endpoint}>; rel="next"; results="true"; results="false"',
        f'<{exact_endpoint}>; rel="next; results="false"',
    ):
        client, _ = _sentry_client([HTTPResponse(200, {"Link": malformed_link}, body)])
        _expect_raises(
            ProtocolError,
            lambda client=client: client.fetch_events("1"),
            f"ambiguous Link header {malformed_link!r}",
        )
    passed("duplicate or unbalanced Link parameters fail closed")

    # Different page URLs can still overlap. EVENT identity, not URL identity,
    # proves the population contains no duplicate.
    second_page = f"{exact_endpoint}&cursor=c1"
    terminal_page = f"{exact_endpoint}&cursor=c2"
    first_link = f'<{second_page}>; rel="next"; results="true"; cursor="c1"'
    last_link = f'<{terminal_page}>; rel="next"; results="false"; cursor="c2"'
    client, _ = _sentry_client(
        [
            HTTPResponse(200, {"Link": first_link}, body),
            HTTPResponse(200, {"Link": last_link}, body),
        ]
    )
    _expect_raises(
        ProtocolError,
        lambda: client.fetch_events("1"),
        "duplicate event id across different pagination URLs",
        message="duplicate event id",
    )
    passed("overlapping Sentry pages cannot double-count an event")

    # 13: the exact production partition-accounting guard, armed directly.
    _expect_raises(
        IncompleteError,
        lambda: require_complete_partitions({0, 1, 2}, {0, 2}),
        "missing partition index",
    )
    _expect_raises(
        IncompleteError,
        lambda: require_complete_partitions({0, 1}, {0, 1, 2}),
        "unexpected partition index",
    )
    require_complete_partitions({0, 1}, {0, 1})  # two-way control: complete passes
    passed("incomplete or unexpected partition indexes fail closed")

    # 14: malformed PostHog column count.
    ph, _ = _posthog_client([_posthog_response([["only-one-column"]])] * 3)
    ph.dev_ids = ()
    _expect_raises(
        ProtocolError,
        lambda: fetch_install_usage(ph, [_fixture_install_uuid("a01")]),
        "malformed columns",
    )
    passed("a PostHog row with the wrong column count fails closed")

    # 15: bucket total mismatch against the independent identical-filter query.
    install = _fixture_install_uuid("a01")
    ph, _ = _posthog_client(
        [
            _posthog_response([]),                                   # snapshot
            _posthog_response([]),                                   # settings.changed
            _posthog_response([[install, "2.3.1", 5, 0]]),           # usage: 1 bucket
            _posthog_response([[9]]),                                # independent total: 9
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        IncompleteError, lambda: fetch_install_usage(ph, [install]), "bucket mismatch"
    )
    passed("buckets disagreeing with an independent uniqExact total fails closed")

    # 16: a successful zero-row response is a real result, not an error or a zero.
    ph, _ = _posthog_client(
        [_posthog_response([]), _posthog_response([]), _posthog_response([]), _posthog_response([[0]])]
    )
    ph.dev_ids = ()
    usage = fetch_install_usage(ph, [install])
    assert usage[install].has_usage_rows is False
    rendered = render_report(
        aggregate_fingerprint(
            "X",
            [SentryEvent("e1", "2.3.1", install, None, 1.0)],
        ),
        usage,
    )
    assert NO_USAGE_ROWS in rendered, rendered
    assert "0 successful dictations" not in rendered, "a zero row must not become a zero rate"
    passed(f"16. a successful zero-row response prints {NO_USAGE_ROWS!r} and no rate")

    # 17: version-floor null discipline.
    assert render_field("effective_transport", "2.3.1", None) == NOT_SHIPPED
    assert render_field("effective_transport", "2.3.2", "usb") == "usb"
    assert render_field("recording_seconds", "2.1.9", None) == NOT_SHIPPED
    assert render_field("llm_provider", "2.0.0", None) == "null (no value recorded)"
    _expect_raises(
        MissingAuthorityError,
        lambda: field_shipped_on("a_field_with_no_recorded_floor", "2.3.2"),
        "unknown floor",
    )
    passed("a field below its version floor prints not-shipped; an unknown floor raises")

    # 18: retry-burst detection must not inflate the person count.
    burst_events = [
        SentryEvent(f"b{i}", "2.3.1", install, None, 1000.0 + i * 30) for i in range(5)
    ] + [SentryEvent("b9", "2.3.1", _fixture_install_uuid("a02"), None, 99999.0)]
    burst_report = aggregate_fingerprint("X", burst_events)
    assert len(burst_report.bursts) == 1, burst_report.bursts
    assert burst_report.bursts[0].events_in_window == 5, burst_report.bursts
    joined_total = next(
        total for total in burst_report.population_totals
        if total.identity_source == JOINED_IDENTITY_LABEL
    )
    assert joined_total.events == 6 and joined_total.identities == 2, joined_total
    passed("a five-event burst is flagged and still counts as one person")

    # 19: the production filter excludes development and dev-tainted installs.
    ph, ph_transport = _posthog_client([_posthog_response([["dev-install-1"], ["dev-install-2"]])])
    resolved = ph.resolve_dev_ids()
    assert resolved == ("dev-install-1", "dev-install-2"), resolved
    clause = ph.environment_clause()
    assert "properties.environment = 'production'" in clause, clause
    assert "distinct_id NOT IN ('dev-install-1', 'dev-install-2')" in clause, clause
    empty = PostHogClient(SENTINEL_POSTHOG_KEY, FixtureTransport([]), lambda _s: None)
    empty.dev_ids = ()
    assert "NOT IN ()" not in empty.environment_clause(), empty.environment_clause()
    assert len(ph_transport.seen) == 1, "dev ids must be resolved ONCE, not per query"
    passed("production filtering excludes dev, resolves dev ids once, never emits NOT IN ()")

    # The dev-id query selects exactly one column. An extra column is malformed
    # evidence, not something to read past.
    ph, _ = _posthog_client([_posthog_response([["dev-install", "unexpected-extra-column"]])])
    _expect_raises(ProtocolError, ph.resolve_dev_ids, "dev-id row with an extra column")
    ph, _ = _posthog_client([_posthog_response([["dev-install"]])])
    assert ph.resolve_dev_ids() == ("dev-install",)
    passed("dev-id rows require exactly one string column")

    # 20: joined and legacy populations keep SEPARATE numerators and denominators.
    # The previous version of this case asserted a mixed total and therefore froze
    # the defect as expected behaviour.
    mixed = [
        SentryEvent("j1", "2.4.1", install, None, 1.0),
        SentryEvent("l1", "2.1.0", None, "legacy-sentry-user-1", 2.0),
        SentryEvent("l2", "2.1.0", None, "legacy-sentry-user-2", 3.0),
    ]
    mixed_report = aggregate_fingerprint("X", mixed)
    totals = {total.identity_source: total for total in mixed_report.population_totals}
    assert len(mixed_report.population_totals) == 2, mixed_report.population_totals
    assert totals[JOINED_IDENTITY_LABEL].events == 1
    assert totals[JOINED_IDENTITY_LABEL].identities == 1
    assert totals[LEGACY_IDENTITY_LABEL].events == 2
    assert totals[LEGACY_IDENTITY_LABEL].identities == 2
    assert mixed_report.unjoined_events == 2
    assert mixed_report.join_coverage_by_release == {"2.1.0": (0, 2), "2.4.1": (1, 1)}
    passed("joined and legacy populations retain separate numerators and denominators")

    # 22: a mixed release must not divide ALL its events by only its joined
    # identities. This is the arithmetic the old shape got wrong.
    mixed_release = [
        SentryEvent("j1", "2.4.1", install, None, 1.0),
        SentryEvent("j2", "2.4.1", install, None, 2.0),
        SentryEvent("l1", "2.4.1", None, "legacy-sentry-user-1", 3.0),
        SentryEvent("l2", "2.4.1", None, "legacy-sentry-user-2", 4.0),
        SentryEvent("l3", "2.4.1", None, "legacy-sentry-user-2", 5.0),
    ]
    rows = aggregate_fingerprint("X", mixed_release).release_rows
    by_source = {row.identity_source: row for row in rows}
    assert by_source[JOINED_IDENTITY_LABEL].events == 2
    assert by_source[JOINED_IDENTITY_LABEL].identities == 1
    assert by_source[JOINED_IDENTITY_LABEL].events_per_identity == 2.0
    assert by_source[LEGACY_IDENTITY_LABEL].events == 3
    assert by_source[LEGACY_IDENTITY_LABEL].identities == 2
    assert by_source[LEGACY_IDENTITY_LABEL].events_per_identity == 1.5
    # The wrong shape would have produced 5 events over 1 joined identity = 5.0.
    assert all(row.events_per_identity != 5.0 for row in rows), rows
    passed("a mixed release never divides all its events by one population's identities")

    # 23: a settings row alone must not make an install look active.
    ph, _ = _posthog_client(
        [
            _posthog_response([[install, 1000] + [None] * len(RECONSTRUCTED_SETTINGS)]),
            _posthog_response([]),
            _posthog_response([]),
            _posthog_response([[0]]),
        ]
    )
    ph.dev_ids = ()
    settings_only = fetch_install_usage(ph, [install])
    assert settings_only[install].has_usage_rows is False
    rendered_settings_only = render_report(
        aggregate_fingerprint("X", [SentryEvent("e1", "2.3.1", install, None, 1.0)]),
        settings_only,
    )
    assert NO_USAGE_ROWS in rendered_settings_only
    passed("a settings row without usage rows still reports no usage")

    # 24: all usage counts render, including the real failure counterpart.
    ph, _ = _posthog_client(
        [
            _posthog_response([]),
            _posthog_response([]),
            _posthog_response([[install, "2.3.1", 466, 18]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    full_usage = fetch_install_usage(ph, [install])
    rendered_full = render_report(
        aggregate_fingerprint("X", [SentryEvent("e1", "2.3.1", install, None, 1.0)]),
        full_usage,
    )
    assert "466 successful dictations" in rendered_full, rendered_full
    assert "18 pipeline.failed" in rendered_full, rendered_full
    passed("successes and pipeline.failed both render for an affected release")

    # Required Sentry measurement fields must fail closed, not degrade.
    valid_event = {
        "id": "required-fields",
        "dateCreated": "2026-06-01T00:00:00Z",
        "user": {"id": "legacy-install"},
        "tags": [{"key": "release", "value": "2.4.1"}],
    }
    missing_release = {**valid_event, "tags": []}
    malformed_timestamp = {**valid_event, "dateCreated": "not-a-timestamp"}
    tag_only_identity = {
        **valid_event,
        "user": None,
        "tags": [
            {"key": "release", "value": "2.4.1"},
            {"key": "user", "value": "display-tag-is-not-user-id"},
        ],
    }
    for label, raw_event in (
        ("missing release", missing_release),
        ("malformed timestamp", malformed_timestamp),
        ("tag-only identity", tag_only_identity),
    ):
        _expect_raises(
            ProtocolError,
            lambda raw_event=raw_event: SentryClient._parse_event(raw_event, 1),
            label,
        )
    SentryClient._parse_event(valid_event, 1)  # two-way control: a valid event parses
    passed("required Sentry measurement fields fail closed")

    # A pagination URL must never carry our credential off-host.
    external_next = (
        '<https://attacker.invalid/collect?full=true>; rel="next"; results="true"; cursor="c1"'
    )
    client, transport = _sentry_client([HTTPResponse(200, {"Link": external_next}, body)])
    _expect_raises(
        ProtocolError, lambda: client.fetch_events("1"), "external pagination URL",
        message="outside the exact Sentry issue endpoint",
    )
    assert len(transport.seen) == 1, (
        "the Sentry credential must never be sent to the pagination target"
    )
    passed("pagination cannot forward the Sentry credential outside its issue endpoint")

    # Eligibility exclusions are counted and reported, never silently dropped.
    mixed_eligibility = [
        SentryEvent("ok", "2.4.1", None, "u1", 1.0, environment="production"),
        SentryEvent("dev", "2.4.1", None, "u2", 2.0, environment="development"),
        SentryEvent("synth", "2.4.1", None, "u3", 3.0, environment="production", synthetic=True),
        SentryEvent(
            "helper", "2.4.1", None, "u4", 4.0, environment="production",
            process_role=ASR_HELPER_ROLE,
        ),
        SentryEvent("notag", "2.4.1", None, "u5", 5.0),
    ]
    selection = select_eligible_events(mixed_eligibility, "production")
    assert [e.event_id for e in selection.eligible] == ["ok"], selection.eligible
    assert selection.excluded_counts == {
        "environment=development": 1,
        "synthetic=true (fault injection)": 1,
        f"process.role={ASR_HELPER_ROLE} (documented gap)": 1,
        "environment tag absent": 1,
    }, selection.excluded_counts
    dev_selection = select_eligible_events(mixed_eligibility, "development")
    assert [e.event_id for e in dev_selection.eligible] == ["dev"], dev_selection.eligible
    passed("development, synthetic, helper and untagged events are excluded and counted")

    # The dev-taint exclusion must NOT apply to a development query, or the plan's
    # own primary gate would return zero rows and read as "no usage".
    dev_client = PostHogClient(
        SENTINEL_POSTHOG_KEY, FixtureTransport([]), lambda _s: None, environment="development"
    )
    dev_clause = dev_client.environment_clause()
    assert "properties.environment = 'development'" in dev_clause, dev_clause
    assert "NOT IN" not in dev_clause, dev_clause
    prod_client = PostHogClient(SENTINEL_POSTHOG_KEY, FixtureTransport([]), lambda _s: None)
    prod_client.dev_ids = ("dev-1",)
    assert "NOT IN ('dev-1')" in prod_client.environment_clause()
    passed("a development query keeps dev installs; only production excludes them")

    # An all-ineligible fingerprint is a refusal, never a measurement of zero.
    only_dev = [SentryEvent("d", "2.4.1", None, "u", 1.0, environment="development")]
    empty_selection = select_eligible_events(only_dev, "production")
    assert empty_selection.eligible == []
    passed("an all-ineligible fingerprint yields no eligible events for the caller to refuse on")

    # Per-release coverage marks a zero WITHOUT guessing why, and prints no
    # overall figure (founder decision 2026-07-29).
    coverage_events = [
        SentryEvent("old", "2.3.1", None, "legacy-1", 1.0, environment="production"),
        SentryEvent("new", "2.5.0", install, None, 2.0, environment="production"),
    ]
    coverage_render = render_report(
        aggregate_fingerprint("X", coverage_events, "production"), {}
    )
    assert "2.3.1: 0/1 events carry" in coverage_render, coverage_render
    assert "<- no joined events" in coverage_render, coverage_render
    assert "2.5.0: 1/1 events carry" in coverage_render, coverage_render
    # SCOPED to the join-coverage block. The founder ruling forbids an overall
    # JOIN-coverage percentage; it does not forbid the Phase 2 take rate, which
    # reports per release alongside its counts. A whole-render scan for "%" was
    # the original form and it false-fired on the take-rate section's own prose —
    # re-aimed at what it means rather than reworded around
    # (`false-positives-not-gates-train-evasion`).
    join_block = coverage_render.split("Join coverage by release")[1].split("Take coverage")[0]
    assert "%" not in join_block, "no overall join-coverage percentage may be printed"
    assert "predates" not in join_block, (
        "the tool must not claim to know WHY a release has zero coverage"
    )
    # Positive control: the scoped slice must be capable of catching a percentage,
    # or "found none" is indistinguishable from a slice that captured nothing.
    assert "events carry" in join_block, "the scoped slice must contain the coverage lines"
    passed("join coverage is per-release, marks zeroes, and prints no overall figure")

    # The app gives Sentry a packaged release and PostHog the raw app version.
    # Without normalization the exact lookup never matches and EVERY install
    # reports zero successes — the tool's whole denominator, silently empty.
    packaged_event = SentryClient._parse_event(
        {
            "id": "packaged-release",
            "dateCreated": "2026-07-29T00:00:00Z",
            "tags": [
                {"key": "release", "value": "com.enviouswispr.app@2.4.1"},
                {"key": "environment", "value": "production"},
                {"key": JOIN_TAG, "value": install},
            ],
        },
        1,
    )
    assert packaged_event.release == "2.4.1", packaged_event.release
    # Dev builds previously sorted as version zero because the leading `v` stopped
    # the old parser on its first chunk.
    assert version_key("v1.6.1-14-gabc123-dev") == (1, 6, 1)
    assert version_key("com.enviouswispr.app@2.4.1") == (2, 4, 1)
    _expect_raises(
        ProtocolError, lambda: canonical_app_version("unknown", "x"), "unknown version"
    )
    _expect_raises(
        ProtocolError,
        lambda: canonical_app_version("other.app@2.4.1", "x"),
        "foreign package name",
    )

    ph, _ = _posthog_client(
        [
            _posthog_response([]),
            _posthog_response([]),
            _posthog_response([[install, "2.4.1", 466, 18]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    packaged_usage = fetch_install_usage(ph, [install])
    packaged_render = render_report(
        aggregate_fingerprint("X", [packaged_event]), packaged_usage
    )
    assert "466 successful dictations" in packaged_render, packaged_render
    assert "18 pipeline.failed" in packaged_render, packaged_render
    passed("Sentry packaged releases join PostHog raw app versions, including dev versions")

    # Counts are measurements: malformed values must not be rounded or truncated.
    #
    # Asserted on the pure authority FIRST. The integration form below failed with
    # "fixture queue exhausted" when I reverted the guard to check it was armed —
    # a real failure, but for an incidental reason that would also mask a genuine
    # regression if the query order changed. Direct assertions cannot do that.
    for bad_count in (True, False, -1, 1.5, float("nan"), float("inf"), "5", None):
        _expect_raises(
            ProtocolError,
            lambda bad=bad_count: required_count(bad, "unit"),
            f"required_count({bad_count!r})",
        )
    assert required_count(0, "unit") == 0, "zero is a legitimate count"
    assert required_count(466, "unit") == 466
    assert required_count(18.0, "unit") == 18, "a whole float is a valid count"

    # Integration form, with a COMPLETE queue so that absent the guard the run
    # would succeed — making the assertion specific to the guard, not to the fixture.
    for bad_count in (True, -1, 1.5):
        ph, _ = _posthog_client(
            [
                _posthog_response([]),
                _posthog_response([]),
                _posthog_response([[install, "2.4.1", bad_count, 0]]),
                _posthog_response([[1]]),
            ]
        )
        ph.dev_ids = ()
        _expect_raises(
            ProtocolError,
            lambda ph=ph: fetch_install_usage(ph, [install]),
            f"malformed usage count {bad_count!r}",
        )

    ph, _ = _posthog_client(
        [
            _posthog_response([]),
            _posthog_response([]),
            _posthog_response([[install, "2.4.1", 1, 0]]),
            _posthog_response([[1.5]]),
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        ProtocolError, lambda: fetch_install_usage(ph, [install]), "fractional total"
    )
    passed("malformed PostHog counts fail closed instead of being truncated")

    # Timestamps decide whether a settings change overlays its snapshot.
    for bad_timestamp in (True, False, -1, float("nan"), float("inf"), "1000", None):
        _expect_raises(
            ProtocolError,
            lambda bad=bad_timestamp: required_timestamp(bad, "unit"),
            f"required_timestamp({bad_timestamp!r})",
        )
    assert required_timestamp(0, "unit") == 0.0
    assert required_timestamp(1000, "unit") == 1000.0
    assert required_timestamp(1000.5, "unit") == 1000.5

    # Both production consumers, with COMPLETE queues so failure is specific to
    # the guard rather than to queue exhaustion.
    for bad_timestamp in (True, float("nan")):
        ph, _ = _posthog_client(
            [
                _posthog_response(
                    [[install, bad_timestamp] + [None] * len(RECONSTRUCTED_SETTINGS)]
                ),
                _posthog_response([]),
                _posthog_response([]),
                _posthog_response([[0]]),
            ]
        )
        ph.dev_ids = ()
        _expect_raises(
            ProtocolError,
            lambda ph=ph: fetch_install_usage(ph, [install]),
            f"malformed snapshot timestamp {bad_timestamp!r}",
        )

        ph, _ = _posthog_client(
            [
                _posthog_response([]),
                _posthog_response([[install, "llm_model", "eg-1", bad_timestamp]]),
                _posthog_response([]),
                _posthog_response([[0]]),
            ]
        )
        ph.dev_ids = ()
        _expect_raises(
            ProtocolError,
            lambda ph=ph: fetch_install_usage(ph, [install]),
            f"malformed settings timestamp {bad_timestamp!r}",
        )
    passed("malformed PostHog timestamps fail closed before configuration reconstruction")

    # A nested vendor field of the wrong TYPE must fail closed, not crash.
    for bad_group in ("not-a-dict", [1, 2], 7):
        client, _ = _sentry_client([_json_response({"group": bad_group})])
        _expect_raises(
            ProtocolError,
            lambda c=client: c.resolve_issue_id("ENVIOUSWISPR-2F"),
            f"short-id group={bad_group!r}",
        )
    client, _ = _sentry_client([_json_response({"group": {"id": "6712345678"}})])
    assert client.resolve_issue_id("ENVIOUSWISPR-2F") == "6712345678"
    client, _ = _sentry_client([_json_response({"groupId": "42"})])
    assert client.resolve_issue_id("ENVIOUSWISPR-2F") == "42"
    assert SentryClient("k", FixtureTransport([])).resolve_issue_id("6712345678") == "6712345678"
    passed("short-id resolution fails closed on a wrong-typed nested field")

    # 21: only urllib_transport may open a socket.
    #
    # Scoped to the PRODUCTION half deliberately. A whole-file scan matches this
    # test's own pattern literal and reports five call sites — a scanner that
    # sees itself. Splitting on the marker also makes the assertion mean what it
    # says: exactly one network call in the code that actually runs in anger.
    source = open(__file__, encoding="utf-8").read()
    marker = "# SELF-TEST ONLY BELOW THIS LINE"
    production, sep, self_test = source.partition(marker)
    assert sep, "the self-test marker must exist for this scan to be scoped correctly"
    assert len(self_test) > 0, "the self-test half must be non-empty"
    network_calls = re.findall(
        r"urlopen|HTTPSConnection|HTTPConnection|requests\.|httpx", production
    )
    assert len(network_calls) == 1, (
        f"expected exactly one network call site in the production half, found {network_calls}"
    )
    # Positive control: the pattern must be capable of matching, or "found one"
    # would be indistinguishable from a broken pattern that found nothing.
    assert re.findall(r"urlopen", "urllib.request.urlopen(x)"), "the matcher itself is broken"
    passed("exactly one function in the production half can open a network connection")

    # ----------------------------------------------------------------------
    # Phase 2 — take coverage and the fingerprint take rate
    # ----------------------------------------------------------------------

    # THE CASE-MISMATCH TRAP, frozen. The two identities differ in case because
    # they are produced by different code: the PostHog SDK emits a lowercase
    # distinct_id, while `SessionID.raw.uuidString` is Foundation's UPPERCASE
    # form (measured 2026-07-30: `D3B6682C-A4F7-47DB-A6D9-F6B0283DD651`).
    # Reusing the join-key canonicalizer would have rejected every real take ID
    # and reported take coverage as a confident 0%.
    upper_take = "D3B6682C-A4F7-47DB-A6D9-F6B0283DD651"
    assert canonical_join_key(upper_take) is None, (
        "the join-key matcher is lowercase-only — this is the trap being frozen"
    )
    assert canonical_take_id(upper_take) == upper_take
    assert canonical_take_id(upper_take.lower()) == upper_take, "normalized to upper"
    for junk in (None, "", "not-a-uuid", upper_take[:-1], upper_take + "0", 42):
        assert canonical_take_id(junk) is None, f"canonical_take_id({junk!r})"
    passed("take IDs accept Swift's UPPERCASE uuidString, which the join-key matcher rejects")

    # A Sentry event carries the take tag; an event WITHOUT it is not an error,
    # because every pre-#1846 event legitimately lacks one.
    def _sentry_event_with(tags: list[dict[str, str]]) -> SentryEvent:
        return SentryClient._parse_event(
            {
                "id": "take-evt",
                "dateCreated": "2026-07-30T00:00:00Z",
                "tags": [
                    {"key": "release", "value": "2.6.0"},
                    {"key": "environment", "value": "production"},
                    {"key": JOIN_TAG, "value": install},
                    *tags,
                ],
            },
            1,
        )

    assert _sentry_event_with([{"key": TAKE_TAG, "value": upper_take}]).take_id == upper_take
    assert _sentry_event_with([]).take_id is None, "an absent take tag must not raise"
    assert _sentry_event_with([{"key": TAKE_TAG, "value": "junk"}]).take_id is None
    passed("the Sentry take tag parses when present and is non-fatal when absent or malformed")

    # Per-event coverage: an event with rows reports its ratio; an event with NO
    # rows reports `not observed`. Never 0% and never 100% — zero rows is an
    # absence of evidence, and the whole point of the per-event shape is that a
    # busy event cannot mask a silent one.
    # ONE response per event now, in TAKE_KEYED_EVENTS order. The grouped
    # single-query form returned 127 rows in production — over PostHog's cap.
    def _coverage_fixture(per_event: dict[str, list[list[object]]]) -> list[HTTPResponse]:
        return [_posthog_response(per_event.get(name, [])) for name in TAKE_KEYED_EVENTS]

    ph, _ = _posthog_client(
        _coverage_fixture(
            {
                "dictation.completed": [["2.6.0", 400, 400], ["2.7.0", 500, 500]],
                "recording.cap_warning_shown": [["2.6.0", 3, 0]],
            }
        )
    )
    ph.dev_ids = ()
    observed_coverage = fetch_take_coverage(ph)
    coverage_lines = "\n".join(render_take_coverage(observed_coverage))
    assert "dictation.completed on 2.6.0: 400/400 rows carry take_id" in coverage_lines
    assert "dictation.completed on 2.7.0: 500/500 rows carry take_id" in coverage_lines
    assert "recording.cap_warning_shown on 2.6.0: 0/3 rows carry take_id" in coverage_lines
    assert "<- no take keys" in coverage_lines, "a zero must be marked"
    # THE BLACKOUT CELL. `recording.cap_warning_shown` was observed on 2.6.0 and is
    # absent on 2.7.0. The first renderer printed `not observed` only for events
    # missing from EVERY release, so this cell vanished silently — a per-release
    # blackout invisible in the table built to catch blackouts.
    assert "recording.cap_warning_shown on 2.7.0: not observed" in coverage_lines, coverage_lines
    # Every event the fixture never returned gets a cell on BOTH observed releases.
    for name in TAKE_KEYED_EVENTS:
        if name in ("dictation.completed", "recording.cap_warning_shown"):
            continue
        for rel in ("2.6.0", "2.7.0"):
            assert f"  {name} on {rel}: {NOT_OBSERVED}" in coverage_lines, (name, rel)
    assert "100%" not in coverage_lines and "0%" not in coverage_lines
    passed("take coverage renders the full event x release grid, blackout cells included")

    # A subset larger than its set is impossible; it means the query or the parse
    # is wrong, and a wrong coverage number is worse than none.
    ph, _ = _posthog_client(
        _coverage_fixture({"asr.completed": [["2.6.0", 5, 9]]})
    )
    ph.dev_ids = ()
    _expect_raises(ProtocolError, lambda: fetch_take_coverage(ph), "keyed exceeds total")
    # Wrong column count fails closed too — the per-event shape has 3, not 4.
    ph, _ = _posthog_client(
        _coverage_fixture({"asr.completed": [["2.6.0", "dictation.completed", 5, 5]]})
    )
    ph.dev_ids = ()
    _expect_raises(ProtocolError, lambda: fetch_take_coverage(ph), "wrong column count")
    passed("take coverage fails closed on an impossible subset or a malformed row")

    # EVERY event must be queried. A dropped query would return no rows for that
    # event, which the renderer prints as `not observed` — a missing query
    # rendered as a real telemetry blackout.
    ph, coverage_transport = _posthog_client(_coverage_fixture({}))
    ph.dev_ids = ()
    assert fetch_take_coverage(ph) == []
    # Decode the body rather than `str(bytes)`: the repr escapes the single quotes
    # the SQL uses, so the first version of this matcher found nothing and reported
    # an empty list. A matcher that cannot match is not a check.
    sent_queries = [
        json.loads(request.body or b"{}")["query"]["query"]
        for request in coverage_transport.seen
    ]
    queried = [
        name for name in TAKE_KEYED_EVENTS
        if any(f"event = '{name}'" in sql for sql in sent_queries)
    ]
    assert queried == list(TAKE_KEYED_EVENTS), queried
    assert len(coverage_transport.seen) == len(TAKE_KEYED_EVENTS), len(coverage_transport.seen)
    passed("take coverage queries every one of the 13 events, one bounded query each")

    # TRUNCATION. Measured 2026-07-30: PostHog caps a HogQL result at 100 rows and
    # sets `hasMore: true`. Every query in this file is an aggregate or a bounded
    # id list, so `hasMore` can only mean a partial answer — and a partial answer
    # here renders as `not observed`, as `unset`, or as zero, none of which is
    # distinguishable from the real thing in the output.
    truncated = HTTPResponse(
        200,
        {"Content-Type": "application/json"},
        json.dumps(
            {"results": [["2.6.0", 400, 400]],
             "columns": [], "hasMore": True, "limit": 100, "offset": 0}
        ).encode(),
    )
    ph, _ = _posthog_client([truncated])
    ph.dev_ids = ()
    _expect_raises(
        IncompleteError,
        lambda: fetch_take_coverage(ph),
        "truncated coverage result",
        "PostHog truncated the result",
    )
    # The guard lives on the CLIENT, so it covers every caller — including the
    # unbounded dev-id list, whose own truncation would silently let dev installs
    # survive the production exclusion and contaminate every total.
    ph, _ = _posthog_client([truncated])
    _expect_raises(
        IncompleteError, lambda: ph.resolve_dev_ids(), "truncated dev-id list",
        "PostHog truncated the result",
    )
    # `hasMore: false` and an absent key are both legitimate complete results.
    for flag in (False, None):
        payload: dict[str, object] = {"results": [[1]], "columns": []}
        if flag is not None:
            payload["hasMore"] = flag
        ph, _ = _posthog_client(
            [HTTPResponse(200, {"Content-Type": "application/json"}, json.dumps(payload).encode())]
        )
        assert ph.query("SELECT 1", "complete") == ([[1]], []), flag
    passed("a truncated PostHog result fails closed for every query, not just some")

    # Coverage counts USABLE join keys. A malformed non-empty value cannot join to
    # Sentry and the rate queries reject it, so counting it as covered would report
    # 100% for a key that joins nothing.
    coverage_sql_probe, coverage_sql_transport = _posthog_client(
        _coverage_fixture({"asr.completed": [["2.6.0", 5, 5]]})
    )
    coverage_sql_probe.dev_ids = ()
    fetch_take_coverage(coverage_sql_probe)
    coverage_sql = json.loads(
        coverage_sql_transport.seen[0].body or b"{}"
    )["query"]["query"]
    assert TAKE_ID_HOGQL_PATTERN in coverage_sql, coverage_sql
    assert "!= ''" not in coverage_sql, (
        "presence-only counting would report a malformed key as covered: " + coverage_sql
    )
    passed("take coverage counts canonical take ids, not merely non-empty ones")

    # THE UNION ARITHMETIC. A take on BOTH sides is counted once: two failed
    # takes, ten successful takes, one of which is the same take, is a union of
    # eleven — not twelve.
    take_a, take_b = upper_take, "11111111-2222-3333-4444-555555555555"
    take_report = aggregate_fingerprint(
        "X",
        [
            SentryEvent(
                "e1", "2.6.0", install, None, 1000.0,
                environment="production", take_id=take_a,
            ),
            SentryEvent(
                "e2", "2.6.0", install, None, 2000.0,
                environment="production", take_id=take_b,
            ),
        ],
        "production",
    )
    # Queue order: bucket rows, the bucket completeness total, then the
    # POPULATION query for the affected-user denominator.
    ph, _rate_transport = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
            _posthog_response([["2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    rates = fetch_take_rates(ph, take_report)
    assert len(rates) == 1, rates
    assert rates[0].affected_takes == 2, rates[0]
    assert rates[0].union_takes == 11, f"2 + 10 - 1 overlap = 11, got {rates[0].union_takes}"
    assert rates[0].affected_installs == 1
    # 10, NOT 1. The denominator is the population of installs with a keyed take
    # in this window, not the affected installs it contains. The first version of
    # this assertion read `== 1` and froze a structurally tautological 100%.
    assert rates[0].eligible_installs == 10, rates[0]
    # THE POPULATION QUERY MUST SPAN ALL 13 EVENTS, not just successful
    # completions. Plan section 5 defines this denominator over ELIGIBLE takes;
    # scoping it to `dictation.completed` drops any install with keyed VAD,
    # invocation or failure events but no successful completion, inflating the
    # rate. Asserted on the emitted SQL because both forms return plausible
    # numbers and only the query text distinguishes them.
    population_sql = json.loads(
        [r for r in _rate_transport.seen if b"take_rate_user_population" in (r.body or b"")][0]
        .body or b"{}"
    )["query"]["query"]
    assert f"event IN ({sql_id_list(TAKE_KEYED_EVENTS)})" in population_sql, population_sql
    assert f"event = '{SUCCESS_TAKE_EVENT}'" not in population_sql, population_sql
    # The TAKE-level union keeps `dictation.completed` — a different population by
    # design, and the bug was serving both from one filter.
    bucket_sql = json.loads(
        [r for r in _rate_transport.seen if b"take_rate_p0" in (r.body or b"")][0].body or b"{}"
    )["query"]["query"]
    assert f"event = '{SUCCESS_TAKE_EVENT}'" in bucket_sql, bucket_sql
    rate_lines = "\n".join(render_take_rates(rates, take_report.take_window, True))
    assert "2/11 takes affected (18.2%)" in rate_lines, rate_lines
    assert "1/10 installs affected" in rate_lines, rate_lines
    assert "UPPER BOUND" in rate_lines, "the window bias must be stated, not implied"
    # The take rate is CONDITIONAL on affected installs (plan §5 scopes its
    # denominator to "the same install"), while the installs figure beside it is
    # population-wide. Printing them together without saying which is which reads
    # the conditional number as a fleet-wide share — the render must name the scope.
    assert "CONDITIONAL on installs this fingerprint" in rate_lines, rate_lines
    assert "population-wide" in rate_lines, rate_lines
    assert "UPPER BOUND on the population rate" not in rate_lines, (
        "the take rate is not a population rate: " + rate_lines
    )
    passed("a take on both sides is counted once, over a denominator that is not itself")

    # Overlap is RELEASE-scoped. A partition-wide take-id list let a take affected
    # on 2.6.0 subtract from 2.7.0's union merely because the same partition held
    # both. Latent rather than observed — one take belongs to one session on one
    # build, so the same id should never appear under two app versions — but every
    # other step here pairs (install, release), and the SQL must say what it means.
    cross_release_report = aggregate_fingerprint(
        "X",
        [
            SentryEvent(
                "cr1", "2.6.0", install, None, 1000.0,
                environment="production", take_id=take_a,
            ),
            SentryEvent(
                "cr2", "2.7.0", install, None, 2000.0,
                environment="production", take_id=take_b,
            ),
        ],
        "production",
    )
    ph, cross_release_transport = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 2, 1, 0], [install, "2.7.0", 2, 1, 0]]),
            _posthog_response([[2]]),
            _posthog_response([["2.6.0", 1, 1, 0], ["2.7.0", 1, 1, 0]]),
            _posthog_response([[2]]),
        ]
    )
    ph.dev_ids = ()
    cross_release_rates = fetch_take_rates(ph, cross_release_report)
    assert {row.release: row.union_takes for row in cross_release_rates} == {
        "2.6.0": 2,
        "2.7.0": 2,
    }, cross_release_rates

    # And the emitted predicate must pair each release with ONLY its own take ids.
    envelope = json.loads(cross_release_transport.seen[0].body or b"{}")
    overlap_sql = re.sub(r"\s+", " ", envelope["query"]["query"])
    assert (
        f"properties.app_version = \'2.6.0\' "
        f"AND upper(properties.{TAKE_PROPERTY}) IN (\'{take_a}\')"
    ) in overlap_sql, overlap_sql
    assert (
        f"properties.app_version = \'2.7.0\' "
        f"AND upper(properties.{TAKE_PROPERTY}) IN (\'{take_b}\')"
    ) in overlap_sql, overlap_sql
    # The install-level twin: the affected-install predicate in the POPULATION query
    # must also pair each release with only its own installs. `cross_release_report`
    # has one install affected on both releases, so widen it — a second install
    # affected on 2.6.0 only must not be counted as affected overlap on 2.7.0.
    other_install = _fixture_install_uuid("a02")
    two_install_report = aggregate_fingerprint(
        "X",
        [
            SentryEvent(
                "ti1", "2.6.0", install, None, 1000.0,
                environment="production", take_id=take_a,
            ),
            SentryEvent(
                "ti2", "2.6.0", other_install, None, 1500.0,
                environment="production", take_id=take_b,
            ),
            SentryEvent(
                "ti3", "2.7.0", install, None, 2000.0,
                environment="production",
                take_id="22222222-3333-4444-5555-666666666666",
            ),
        ],
        "production",
    )
    ph, two_install_transport = _posthog_client(
        [
            _posthog_response(
                [[install, "2.6.0", 1, 1, 0], [other_install, "2.6.0", 1, 1, 0],
                 [install, "2.7.0", 1, 1, 0]]
            ),
            _posthog_response([[3]]),
            _posthog_response([["2.6.0", 2, 2, 0], ["2.7.0", 1, 1, 0]]),
            _posthog_response([[2]]),
        ]
    )
    ph.dev_ids = ()
    fetch_take_rates(ph, two_install_report)
    population_scoped_sql = re.sub(
        r"\s+", " ",
        json.loads(
            [r for r in two_install_transport.seen
             if b"take_rate_user_population" in (r.body or b"")][0].body or b"{}"
        )["query"]["query"],
    )
    # 2.7.0 must name ONLY the install affected there, not both.
    assert (
        f"properties.app_version = \'2.7.0\' AND distinct_id IN (\'{install}\')"
        in population_scoped_sql
    ), population_scoped_sql
    assert (
        f"properties.app_version = \'2.6.0\' AND distinct_id IN "
        f"({sql_id_list(sorted([install, other_install]))})"
        in population_scoped_sql
    ), population_scoped_sql
    passed("affected-install overlap is release-scoped too, not just the take overlap")

    # The dev-id list is the one query returning a LIST, so it carries an explicit
    # bound. Without it the shared truncation guard would abort every production
    # report the day this project passes PostHog's 100-row default — a guard that
    # breaks the thing it protects.
    over_limit = [[f"id-{i}"] for i in range(DEV_ID_LIST_LIMIT + 1)]
    ph, dev_transport = _posthog_client([_posthog_response(over_limit)])
    _expect_raises(
        IncompleteError, lambda: ph.resolve_dev_ids(), "dev-id overflow",
        "dev-tainted installs",
    )
    assert f"LIMIT {DEV_ID_LIST_LIMIT + 1}" in str(dev_transport.seen[0].body), (
        "the query must ask for one MORE than the ceiling, so overflow is detectable"
    )
    # At the ceiling exactly, it succeeds.
    ph, _ = _posthog_client([_posthog_response([[f"id-{i}"] for i in range(DEV_ID_LIST_LIMIT)])])
    assert len(ph.resolve_dev_ids()) == DEV_ID_LIST_LIMIT
    passed("the dev-id list is explicitly bounded and fails on overflow, not on a default")

    passed("overlap subtraction is scoped to the release that take was affected on")

    # An overlap larger than the successes it is drawn from is impossible.
    ph, _ = _posthog_client(
        [_posthog_response([[install, "2.6.0", 3, 7, 0]]), _posthog_response([[1]])]
    )
    ph.dev_ids = ()
    _expect_raises(
        ProtocolError, lambda: fetch_take_rates(ph, take_report), "overlap exceeds successes"
    )
    passed("the take rate fails closed when the overlap exceeds the successes")

    # A truncated bucket response silently drops successes and INFLATES the rate.
    # The independent identical-filter total is what makes that impossible.
    # COMPLETE queue, including the population response the guard never reaches.
    # With a short queue this control failed on "fixture queue exhausted" — a real
    # failure for an incidental reason, which would equally mask a genuine
    # regression. The same trap is recorded on the `required_count` case above.
    # With the full queue, removing the guard lets the call SUCCEED, so the
    # assertion is specific to the guard rather than to the fixture.
    ph, _ = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 0]]),
            _posthog_response([[2]]),
            _posthog_response([["2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        IncompleteError,
        lambda: fetch_take_rates(ph, take_report),
        "truncated take-rate buckets",
        # The message is REQUIRED, not decorative: four separate guards in this
        # file raise `IncompleteError`, so a bare type assertion cannot say which
        # one fired. Control D earlier in this chunk failed for exactly that
        # reason — an unrelated guard tripped and looked like proof.
        "received 1 install-release buckets",
    )
    passed("take-rate buckets require an independent completeness total")

    # SUB-SECOND WINDOW BOUNDS. `int(epoch)` compared whole seconds, so a window of
    # .900 -> 1.100 admitted nearly two full seconds of PostHog events and quietly
    # enlarged the denominator. Rounding INWARD makes the success query narrower
    # than the measured failure span, never wider — conservative by construction.
    fractional_window = TakeWindow(start_epoch=1000.900, end_epoch=1001.100)
    assert fractional_window.start_millis == 1_000_900, fractional_window.start_millis
    assert fractional_window.end_millis == 1_001_100, fractional_window.end_millis
    assert fractional_window.degenerate is False
    # A window with no positive width can contain coincident events, but it is not
    # a meaningful population interval. Refuse instead of reporting a rate whose
    # denominator is determined by timestamp coincidence.
    assert TakeWindow(start_epoch=1000.0001, end_epoch=1000.0002).degenerate is True
    # And the emitted SQL must carry the exact bounds — a correct property that
    # never reaches the query is not a fix.
    ph, tr = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
            _posthog_response([["2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    fetch_take_rates(ph, take_report)
    window = take_report.take_window
    assert window is not None
    sent = "\n".join(str(request.body) for request in tr.seen)
    assert f"toUnixTimestamp64Milli(timestamp) >= {window.start_millis}" in sent
    assert f"toUnixTimestamp64Milli(timestamp) <= {window.end_millis}" in sent
    # The RENDERED window must be the one queried. Formatting `start_epoch` through
    # a whole-second formatter printed a caption for a different measurement.
    # A SUB-MILLISECOND fixture, chosen so the rounded and unrounded renderings
    # DIFFER. The first version used the .900/.100 window above, where both forms
    # print identically — the control that reverted this to `start_epoch` passed
    # all 55 cases, proving the assertion could not detect the defect it named.
    sub_milli_window = TakeWindow(start_epoch=1000.9001, end_epoch=1001.1006)
    assert sub_milli_window.start_millis == 1_000_901, sub_milli_window.start_millis
    assert sub_milli_window.end_millis == 1_001_100, sub_milli_window.end_millis
    displayed_window = "\n".join(
        render_take_rates(
            [
                TakeRateRow(
                    release="2.6.0", affected_takes=1, union_takes=1,
                    affected_installs=1, eligible_installs=1,
                )
            ],
            sub_milli_window,
            True,
        )
    )
    assert (
        "1970-01-01T00:16:40.901Z .. 1970-01-01T00:16:41.100Z" in displayed_window
    ), displayed_window
    # The unrounded start would print .900 — assert its ABSENCE, so rendering the
    # raw epoch fails here instead of passing silently.
    assert "00:16:40.900Z" not in displayed_window, displayed_window
    assert "SAME span" not in displayed_window
    passed("the take-rate window is bounded, and displayed, at the precision queried")

    # A malformed PostHog take id must not become a successful take. It would
    # enlarge both denominators and produce a confidently LOWER failure rate — the
    # direction that reads as "the bug is rarer than you feared".
    # COMPLETE queue: absent the guard this call SUCCEEDS, so the assertion is
    # specific to the guard rather than to queue exhaustion.
    ph, _ = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 1]]),
            _posthog_response([[1]]),
            _posthog_response([["2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        ProtocolError,
        lambda: fetch_take_rates(ph, take_report),
        "malformed successful take id",
        "non-canonical take_id",
    )
    # Same guard on the population query, which independently produces the
    # affected-user denominator.
    ph, _ = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
            _posthog_response([["2.6.0", 10, 1, 3]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        ProtocolError,
        lambda: fetch_take_rates(ph, take_report),
        "malformed take id in the population query",
        "non-canonical take_id",
    )
    passed("malformed PostHog take IDs cannot enter either rate denominator")

    # A truncated POPULATION response loses a release row; `defaultdict(int)` would
    # substitute zero and the denominator could come back below its own numerator.
    ph, _ = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
            _posthog_response([["2.6.0", 10, 1, 0]]),
            _posthog_response([[2]]),
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        IncompleteError,
        lambda: fetch_take_rates(ph, take_report),
        "truncated population buckets",
        "received 1 release buckets",
    )
    # And an impossible pair WITHIN the population result is refused rather than
    # returned: more affected-and-eligible installs than eligible installs. Both
    # numbers come from the same query, so this can only mean a parse or query
    # defect — and it would produce a denominator below its own numerator.
    ph, _ = _posthog_client(
        [
            _posthog_response([[install, "2.6.0", 10, 1, 0]]),
            _posthog_response([[1]]),
            _posthog_response([["2.6.0", 0, 1, 0]]),
            _posthog_response([[1]]),
        ]
    )
    ph.dev_ids = ()
    _expect_raises(
        ProtocolError,
        lambda: fetch_take_rates(ph, take_report),
        "affected-eligible overlap exceeds the eligible population",
        "exceeds affected=",
    )
    passed("the affected-user denominator fails closed on truncation or an impossible pair")

    # The renderer's own fail-closed paths. Both are reachable only from a
    # hand-built list today, but an untested raise is an untested raise.
    _expect_raises(
        ProtocolError,
        lambda: render_take_coverage(
            [
                TakeCoverageRow(event="dictation.completed", release="2.6.0",
                                with_take=1, total=1),
                TakeCoverageRow(event="dictation.completed", release="2.6.0",
                                with_take=2, total=2),
            ]
        ),
        "duplicate coverage cell",
        "duplicate rows",
    )
    _expect_raises(
        ProtocolError,
        lambda: render_take_coverage(
            [TakeCoverageRow(event="not.an.event", release="2.6.0", with_take=1, total=1)]
        ),
        "unlisted event in the renderer",
        "unlisted events",
    )
    # And the empty case still names every intended event rather than printing
    # an empty table that reads as "nothing to report".
    empty_grid = "\n".join(render_take_coverage([]))
    for name in TAKE_KEYED_EVENTS:
        assert f"  {name}: {NOT_OBSERVED}" in empty_grid, name
    passed("the coverage renderer fails closed on duplicate or unlisted cells")

    # A window with no positive width can contain coincident events, but it is not
    # a meaningful population interval. Refuse instead of reporting a rate whose
    # denominator is determined by timestamp coincidence.
    point_report = aggregate_fingerprint(
        "X",
        [
            SentryEvent(
                "e1", "2.6.0", install, None, 1000.0,
                environment="production", take_id=take_a,
            )
        ],
        "production",
    )
    assert point_report.take_window is not None and point_report.take_window.degenerate
    # The fixture is a client that WOULD succeed. An empty-response client was the
    # first form and it proved nothing: removing the guard made the run fail on
    # "dev ids never resolved" instead of on this assertion, so the control fired
    # for an unrelated reason — the Python twin of a compile error passing for RED.
    # With a complete queue, the ONLY thing standing between this call and a
    # computed rate is the degenerate-window guard.
    ph, _ = _posthog_client([_posthog_response([[install, "2.6.0", 4, 0, 0]])])
    ph.dev_ids = ()
    assert fetch_take_rates(ph, point_report) == []
    point_rendered = render_take_rates([], point_report.take_window, True)
    refusal = [line for line in point_rendered if "REFUSED" in line]
    assert len(refusal) == 1, point_rendered
    # Scoped to the refusal LINE, not the block: the section header legitimately
    # contains "Phase 2", and a whole-block digit scan flagged that label as if it
    # were a reported figure. Aim the matcher at the claim it is checking.
    assert not re.search(r"\d", refusal[0]), (
        "a refusal must not print a figure — a skimming reader takes the number "
        f"and drops the refusal: {refusal[0]!r}"
    )
    passed("a zero-width take window is refused rather than reported as a certainty")

    # A pre-Phase-2 population carries no take tags at all. That reads
    # `not observed`, NEVER a 0% failure rate.
    legacy_report = aggregate_fingerprint(
        "X",
        [
            SentryEvent("e1", "2.5.0", install, None, 1000.0, environment="production"),
            SentryEvent("e2", "2.5.0", install, None, 5000.0, environment="production"),
        ],
        "production",
    )
    assert legacy_report.affected_takes_by_install_release == {}
    assert fetch_take_rates(_posthog_client([])[0], legacy_report) == []
    legacy_lines = "\n".join(
        render_take_rates([], legacy_report.take_window, has_affected_takes=False)
    )
    assert NOT_OBSERVED in legacy_lines
    assert "0%" not in legacy_lines, "absence of the tag is not a zero rate"
    passed("a population with no take tags reads not-observed, never a 0% rate")

    # Only JOINED events contribute a take. An unjoined event's take cannot be
    # paired with any install's successes, so counting it would inflate the
    # numerator against a denominator it is not part of.
    unjoined_report = aggregate_fingerprint(
        "X",
        [
            SentryEvent(
                "e1", "2.6.0", None, "legacy-user", 1000.0,
                environment="production", take_id=take_a,
            ),
            SentryEvent(
                "e2", "2.6.0", install, None, 2000.0,
                environment="production", take_id=take_b,
            ),
        ],
        "production",
    )
    assert unjoined_report.affected_takes_by_install_release == {(install, "2.6.0"): {take_b}}
    passed("an unjoined event's take never enters the rate it has no denominator for")

    # COMPOSITION, through the real entry point. Every case above calls
    # `render_take_coverage` / `render_take_rates` directly, so deleting the two
    # lines that splice them into `render_report` would leave all of them green
    # while the shipped report printed neither section
    # (`a-guard-nothing-arms-is-not-a-guard`).
    composed = render_report(
        take_report,
        {},
        take_coverage=[
            TakeCoverageRow(
                event="dictation.completed", release="2.6.0", with_take=400, total=400
            )
        ],
        take_rates=[
            TakeRateRow(
                release="2.6.0", affected_takes=2, union_takes=11,
                affected_installs=1, eligible_installs=1,
            )
        ],
    )
    assert "Take coverage by event and release" in composed, composed
    assert "dictation.completed on 2.6.0: 400/400" in composed, composed
    assert "Fingerprint take rate" in composed, composed
    assert "2/11 takes affected" in composed, composed
    passed("render_report splices both Phase 2 sections into the shipped output")

    print("")
    print(f"Self-test: {len(cases)} cases passed, 0 failed")
    return 0


# --------------------------------------------------------------------------
def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Join a Sentry fingerprint to PostHog usage per anonymous install (#1846)."
    )
    parser.add_argument("--issue", help="Sentry short id (ENVIOUSWISPR-2F) or numeric issue id")
    parser.add_argument(
        "--environment", choices=ENVIRONMENTS, default="production",
        help="which environment to report on. `development` is the plan §11.2 pre-merge gate.",
    )
    parser.add_argument("--self-test", action="store_true", help="run the built-in self-test")
    args = parser.parse_args(argv)

    if args.self_test:
        if args.issue:
            print("error: --self-test takes no --issue", file=sys.stderr)
            return 2
        try:
            return run_self_test()
        except (AssertionError, InstrumentError) as exc:
            # Report the failure as a result, not a traceback, and say plainly
            # that the run stopped rather than implying the rest passed.
            print(f"\nFAIL  {type(exc).__name__}: {exc}", file=sys.stderr)
            print(
                "Self-test: aborted at the first failing case. PASS lines above are valid; "
                "later cases did NOT run.",
                file=sys.stderr,
            )
            return 1

    if not args.issue:
        print("error: --issue is required (or use --self-test)", file=sys.stderr)
        return 2

    try:
        sentry_key = os.environ.get("SENTRY_MASTER_KEY")
        posthog_key = os.environ.get("POSTHOG_KEY")
        missing = [
            name for name, value in
            (("SENTRY_MASTER_KEY", sentry_key), ("POSTHOG_KEY", posthog_key))
            if not value
        ]
        if missing:
            raise ConfigError(
                f"missing credential(s) in the environment: {', '.join(missing)}. "
                "Bridge them with `~/.claude/bin/get-key launch` — see the module docstring."
            )
        report, usage, take_coverage, take_rates = build_report(
            args.issue,
            SentryClient(str(sentry_key)),
            PostHogClient(str(posthog_key), environment=args.environment),
            environment=args.environment,
        )
        # Rendered only after every page, partition and completeness check passed.
        print(render_report(report, usage, take_coverage, take_rates))
        return 0
    except InstrumentError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
