/**
 * EnviousWispr Sentry Triage Worker
 *
 * Receives Sentry Internal Integration webhooks, verifies HMAC, and decides
 * whether to buzz the founder on Discord for this issue. It NO LONGER wakes the
 * daily TIK routine — TIK's single daily run is the sole normal writer of
 * `sentry-triage` GitHub tickets (issue #1470). This worker is a binary
 * post-or-suppress notifier: every Discord post buzzes the founder's phone
 * equally; there are no loudness tiers and no role mention.
 *
 * Policy is owned by one pure function, `decideNotification` (§3.1 rules 1-7 of
 * the #1470 plan). `handleTriage` is orchestration only: parse, validate, gather
 * typed lookups (Sentry events, open GitHub tickets, KV throttle), call the pure
 * decision, post when told, and persist a successful-post timestamp. It contains
 * no severity, known-ticket, or throttle branches of its own.
 *
 * The Discord embed is source-labeled (#1229): it reads already-scrubbed metadata
 * (category, stage, environment, build type, OS, device) from the Sentry events we
 * already fetched for scoring, so no extra subrequest is spent. It fails open to a
 * basic embed when event data is unavailable — an alert is never lost.
 */

// The SHARED Sentry transport, and nothing else from workers/. This worker does
// NOT import workers/reporting/sentry-section.js: the digest section renders a
// lost-vs-degraded breakdown this card does not show, over a different window,
// production-only where this one deliberately keeps dev events. Importing it
// would add a third independently-deployed consumer of that module without
// removing any real duplicate authority (#1965).
import { discoverAggregate } from "../../shared/sentry.js";

const DISCORD_COLOR = { P0: 0xe74c3c, P1: 0xe67e22, P2: 0xf1c40f, P3: 0x95a5a6 };
const SENTRY_ORG = "envious-labs-llc";
const SENTRY_FETCH_TIMEOUT_MS = 5000;
const GITHUB_FETCH_TIMEOUT_MS = 5000;
const DISCORD_ATTEMPT_TIMEOUT_MS = 4000;
const FIELD_MAX_CHARS = 200;

// Background-operation deadlines (§3.3). Cloudflare cancels waitUntil ~30s after
// the 202 response; we leave ~2s headroom for logging + KV cleanup.
const LOOKUP_DEADLINE_MS = 20_000;
const OPERATION_DEADLINE_MS = 28_000;

// Per-invocation hard caps (§3.3): 10 Sentry pages + 5 GitHub pages + 2 Discord
// attempts = 17 external subrequests, below the Workers Free limit of 50.
const SENTRY_MAX_PAGES = 10;
const SENTRY_PER_PAGE = 100;
const GITHUB_MAX_PAGES = 5;
const GITHUB_PER_PAGE = 100;

const THROTTLE_HOURS = { P0: 0, P1: 6, P2: 24, P3: 24 };
// Urgency rank: lower is more urgent. Used by rule 7's escalation comparison.
const PRIORITY_RANK = { P0: 0, P1: 1, P2: 2, P3: 3 };
const KV_TTL_SECONDS = 7776000; // 90 days

// ── Entry point ──────────────────────────────────────────────────────────────

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const body = await request.text();

    // **Sentry's alert-rule-action SETTINGS probe, answered before the HMAC gate and
    // deliberately doing nothing (#2486).** The integration's schema declares
    // `"settings": { "type": "alert-rule-settings", "uri": "/" }`, so when a workflow
    // action is saved Sentry POSTs the submitted fields to this same root path. That
    // probe carries NO `sentry-hook-signature`, so the gate below answered it 401 and
    // Sentry surfaced `{"actionFilters":{"nonfielderrors":["Claude Triage Webhook:
    // Something went wrong!"]}}` on every save — measured on
    // `PUT /organizations/envious-labs-llc/workflows/3202076/`, which is why the
    // integration could not be wired as an explicit workflow action at all.
    //
    // **The discriminator is the PRESENCE of the signature header, not the body.** A
    // real webhook always carries it, so requiring it for the triage path is unchanged
    // and a forged probe cannot reach `handleTriage`: this branch returns before any
    // Sentry, GitHub, KV or Discord work is scheduled. The endpoint becomes
    // unauthenticated only for a request that performs no action and reads no state.
    //
    // Sentry uses the STATUS to decide whether the action saved; the body is not read
    // for `alert-rule-settings` (a `select` field's options come from its own `uri`,
    // and this schema declares none). So `{}` is the honest answer.
    if (!request.headers.has("sentry-hook-signature")) {
      // **A UI-component request is signed under a DIFFERENT header name.** Sentry's
      // webhooks carry `Sentry-Hook-Signature`; its integration-platform component
      // requests carry `Sentry-App-Signature`, over the same client secret. So the
      // probe is authenticated whenever that header is present, and a signature that
      // is present and WRONG is a forgery rather than a probe — refuse it.
      //
      // The `appSig` absent case still answers 200, deliberately: the header name is
      // Sentry's to change, and refusing an unrecognised shape is exactly the failure
      // this commit exists to end. That path returns a constant with no work behind
      // it, so the cost of being wrong here is an endpoint that says `{}`.
      const appSig = request.headers.get("sentry-app-signature");
      if (appSig && !(await verifyHmac(body, appSig, env.SENTRY_WEBHOOK_SECRET))) {
        console.error(
          `[sentry-triage] component request signature invalid; headers=${headerNames(request)}`
        );
        return new Response("Unauthorized", { status: 401 });
      }
      console.log(
        `[sentry-triage] settings probe answered 200; signed=${appSig ? "yes" : "no"}; ` +
          `headers=${headerNames(request)}`
      );
      return new Response("{}", {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    // Verify HMAC-SHA256 signature — must happen before 202 so we can 401 on bad sig
    const sigHeader = request.headers.get("sentry-hook-signature") ?? "";
    const verified = await verifyHmac(body, sigHeader, env.SENTRY_WEBHOOK_SECRET);
    if (!verified) {
      // **Header NAMES, never values.** A signature value is a credential and a
      // body can carry user content; the names alone answer the only question a
      // refusal leaves open — whether this was a forged webhook or a Sentry
      // request shape we do not yet handle — which is precisely what could not be
      // answered while #2486 was open.
      console.error(
        `[sentry-triage] HMAC verification failed; headers=${headerNames(request)}`
      );
      return new Response("Unauthorized", { status: 401 });
    }

    // Return 202 immediately — Sentry retries if we take >10s. All Sentry/GitHub/
    // Discord I/O happens in the background, so it never touches Sentry's budget.
    ctx.waitUntil(handleTriage(body, env));
    return new Response("Accepted", { status: 202 });
  },
};

/** Sorted header NAMES, comma-joined. Never values: one of them is a credential. */
export function headerNames(request) {
  return [...request.headers.keys()].sort().join(",");
}

// ── HMAC verification ─────────────────────────────────────────────────────────

async function verifyHmac(body, sigHeader, secret) {
  try {
    if (!secret || !sigHeader) return false;

    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );

    const signatureBuffer = await crypto.subtle.sign("HMAC", key, encoder.encode(body));

    const computedHex = Array.from(new Uint8Array(signatureBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Constant-time comparison — XOR each byte and OR-accumulate: diff===0 iff equal.
    const computedBytes = encoder.encode(computedHex);
    const receivedBytes = encoder.encode(sigHeader);

    if (computedBytes.length !== receivedBytes.length) return false;

    let diff = 0;
    for (let i = 0; i < computedBytes.length; i++) {
      diff |= computedBytes[i] ^ receivedBytes[i];
    }
    return diff === 0;
  } catch (err) {
    console.error("[sentry-triage] HMAC error:", err.message);
    return false;
  }
}

// ── Main triage handler (orchestration only) ───────────────────────────────────

export async function handleTriage(body, env) {
  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    console.error("[sentry-triage] Failed to parse JSON payload");
    return;
  }

  const startedAt = Date.now();
  const lookupDeadlineAt = startedAt + LOOKUP_DEADLINE_MS;
  const operationDeadlineAt = startedAt + OPERATION_DEADLINE_MS;

  // Replay protection: reject bodies seen in the last 90 min. Written before the
  // background I/O, so a cancelled/failed delivery may leave replay:{hash} set for
  // its TTL with no notification — an exact re-delivery is suppressed up to 90 min,
  // but a later lifecycle webhook has a different body/hash and stays eligible (§8).
  const sigHash = await hashString(body);
  const replayKey = `replay:${sigHash}`;
  const seen = await env.SENTRY_DEDUP.get(replayKey);
  if (seen) {
    console.log("[sentry-triage] Duplicate delivery detected, skipping");
    return;
  }
  await env.SENTRY_DEDUP.put(replayKey, "1", { expirationTtl: 5400 }); // 90 min

  // Validate payload shape. Malformed payloads carry no issue and are dropped.
  //
  // THIS COMMENT USED TO SAY it skipped metric alerts "(no data.issue)". That
  // was false, and it mattered: Sentry files every metric-alert firing as an
  // ISSUE, with `issueCategory: "metric"`, `userCount: 0` and no release. Those
  // payloads DO carry `data.issue`, so this guard never once fired for them and
  // every rate alert fell straight through to the ordinary error path, where it
  // rendered as `What: unknown / Version: unknown / Impact: 0 user(s)` (#1965).
  const issue = payload?.data?.issue;
  if (!issue) {
    console.log("[sentry-triage] No data.issue — skipping malformed or unknown payload");
    return;
  }

  const action = payload.action ?? "";
  const issueId = issue.id ?? "";
  if (!issueId) {
    console.error("[sentry-triage] Missing issue ID, skipping");
    return;
  }

  // Rate alerts take a DIFFERENT path entirely, before any of the error-issue
  // policy below. Scoring one as an error is what produced the empty card: it
  // has no user count to score, no release to scope to, and no category to name.
  //
  // BEING FIRST MEANS IT SKIPS THE TERMINAL-ACTION GUARDS BELOW, so the spike
  // path carries its own action eligibility rather than inheriting theirs by
  // placement. Cloud review caught this: a metric issue arriving as `resolved`,
  // `archived` or `assigned` reached handleSpike and would buzz whenever the
  // six-hour throttle happened to be absent or expired - a Discord post saying
  // errors are spiking, sent because the alert had just been RESOLVED.
  //
  // Fixed in the policy rather than by moving this branch below the guards.
  // Placement is not a contract: the next edit that reorders these blocks would
  // silently reopen it, and `decideSpike` is where a reader looks for what the
  // spike path does.
  if (isMetricIssue(issue)) {
    await handleSpike({ action, issue, issueId, env, lookupDeadlineAt, operationDeadlineAt, now: startedAt });
    return;
  }

  const kvKey = `sentry:${issueId}`;

  // Terminal actions post nothing and need no KV write. The throttle key is
  // deliberately left alone: Rule 7's explicit regression bypass (`action ===
  // "unresolved" && issue?.substatus === "regressed"`) already lets a genuine
  // regression post regardless of a stored throttle, so clearing the key here
  // served no purpose for that case — it only let a bare resolved -> unresolved
  // flap (no substatus:regressed) read as `stored == null` at Rule 7 and re-buzz
  // inside the throttle window (#1485). The stored entry's own TTL
  // (KV_TTL_SECONDS) reclaims it once the window is long past.
  if (action === "resolved" || action === "archived") {
    console.log(`[sentry-triage] Issue ${issueId} ${action} — no post`);
    return;
  }

  if (action === "assigned") {
    console.log(`[sentry-triage] Issue ${issueId} assigned — skipping`);
    return;
  }

  // Gather typed lookups. The Sentry-event and GitHub-ticket reads are independent,
  // so run them CONCURRENTLY on the shared lookup deadline — otherwise slow Sentry
  // pagination could consume the whole budget and starve the ticket check, forcing a
  // fail-open buzz for an issue that already has an open ticket. Each fails open to a
  // degraded status rather than throwing.
  const shortId = typeof issue.shortId === "string" ? issue.shortId : null;
  const [eventLookup, ticketLookup] = await Promise.all([
    fetchEventPartition(issueId, env, lookupDeadlineAt),
    fetchTicketLookup(shortId, env, lookupDeadlineAt),
  ]);
  const throttleLookup = await readThrottle(env, kvKey);

  const now = Date.now();
  const decision = decideNotification({
    action,
    issue,
    eventLookup,
    ticketLookup,
    throttleLookup,
    now,
  });

  if (!decision.post) {
    console.log(
      `[sentry-triage] Issue ${issueId} suppressed (${decision.reason}, ${decision.priority ?? "n/a"})`
    );
    return;
  }

  const title = issue.title ?? "";
  const permalink = issue.permalink ?? issue.web_url ?? "";
  const userCount = parseInt(issue.userCount, 10) || 0;
  const timesSeen = parseInt(issue.count, 10) || 0;

  const embed = buildEmbedFromLookup(eventLookup, {
    issueId,
    title,
    permalink,
    timesSeen,
    userCount,
    priority: decision.priority,
  });

  const result = await postDiscord(env.DISCORD_WEBHOOK_URL, embed, {
    issueId,
    deadlineAt: operationDeadlineAt,
  });

  if (!result.ok) {
    // postDiscord already emitted the structured discord_delivery_failed record.
    // Do NOT claim a post here, and do NOT write a throttle — a failed delivery
    // leaves the fingerprint eligible for the next webhook.
    console.warn(
      `[sentry-triage] Issue ${issueId} NOT delivered after ${result.attempts} attempt(s), no throttle written (${decision.priority}, ${decision.reason})`
    );
    return;
  }

  // Transport-commit invariant: write the throttle ONLY after confirmed delivery
  // AND only when the priority carries a throttle window. P0 (throttleHours:0) never
  // writes, so a second P0 stays eligible.
  if (decision.throttleHours > 0) {
    try {
      await env.SENTRY_DEDUP.put(
        kvKey,
        JSON.stringify({ lastNotifiedAt: now, priority: decision.priority }),
        { expirationTtl: KV_TTL_SECONDS }
      );
    } catch (err) {
      console.error(`[sentry-triage] Throttle write failed for ${issueId}:`, err.message);
    }
  }

  console.log(
    `[sentry-triage] Issue ${issueId} posted (${decision.priority}, ${decision.countSource}, ${decision.reason})`
  );
}

// ── Notification policy: the single pure owner (§3.1 rules 1-7) ─────────────────

/**
 * Binary post/suppress decision. No loudness — every post buzzes equally.
 * `priority` sets the throttle window and message text but never gates the post.
 *
 * Returns { post, priority, throttleHours, reason, countSource }.
 * Suppression (post:false) occurs on exactly: rule 1 (not an eligible error),
 * rule 5 (already ticketed), or rule 7 (active throttle). Everything else posts.
 */
export function decideNotification({ action, issue, eventLookup, ticketLookup, throttleLookup, now }) {
  const level = (issue?.level ?? "").toLowerCase();

  // Rule 1 — eligibility. Unsupported action or a non-error level suppresses.
  const supportedAction = action === "created" || action === "unresolved";
  if (!supportedAction || (level !== "error" && level !== "fatal")) {
    return { post: false, priority: null, throttleHours: 0, reason: "ineligible", countSource: "none" };
  }

  // Rules 2-4 — severity. Score from a trustworthy production event partition; on
  // any degraded event data, fall open to the webhook-derived display priority.
  let priority;
  let countSource;
  const scored = scoreFromEvents(eventLookup);
  if (scored) {
    priority = classifySeverity(scored.users, scored.occurrences, level);
    countSource = "events";
  } else {
    const webhookUsers = parseInt(issue?.userCount, 10) || 0;
    const webhookOccurrences = parseInt(issue?.count, 10) || 0;
    priority = classifySeverity(webhookUsers, webhookOccurrences, level);
    countSource = "webhook-fallback";
  }

  const throttleHours = THROTTLE_HOURS[priority];

  // Rule 5 — already-ticketed suppression. Only a COMPLETE lookup with an exact
  // open marker suppresses; incomplete/unavailable is unconfirmed-known → post.
  if (ticketLookup?.status === "complete" && ticketLookup.openExactMarker === true) {
    return { post: false, priority, throttleHours, reason: "already-ticketed", countSource };
  }

  // Rule 6 — throttle read failure fails open: never let it suppress.
  if (throttleLookup?.status !== "complete") {
    return { post: true, priority, throttleHours, reason: "throttle-unavailable-failopen", countSource };
  }

  // Rule 7 — throttle bypass vs active window.
  const stored = throttleLookup.value; // null or { lastNotifiedAt, priority }
  const isP0 = priority === "P0";
  // Only a genuine REGRESSION (Sentry auto-reopened the issue because it recurred)
  // bypasses an active throttle. A bare "unresolved" (a manual reopen/unmute) is
  // eligible but still respects the throttle, so a flapping state cannot re-buzz.
  const isRegression = action === "unresolved" && issue?.substatus === "regressed";
  const escalates = stored != null && PRIORITY_RANK[priority] < PRIORITY_RANK[stored.priority];

  if (isP0 || isRegression || escalates || stored == null) {
    const reason = isP0
      ? "p0-no-throttle"
      : isRegression
        ? "regression-bypass"
        : escalates
          ? "priority-escalation-bypass"
          : "no-throttle";
    return { post: true, priority, throttleHours, reason, countSource };
  }

  const elapsedMs = now - stored.lastNotifiedAt;
  const windowMs = throttleHours * 3600_000;
  if (elapsedMs < windowMs) {
    return { post: false, priority, throttleHours, reason: "throttled", countSource };
  }
  return { post: true, priority, throttleHours, reason: "throttle-expired", countSource };
}

/**
 * Score occurrence + distinct-user counts on the newest observed production
 * release (§3.1 rule 2). Returns null when there is no trustworthy production
 * partition — an incomplete/unavailable/malformed lookup, no production events,
 * or no release that normalizes to a clean version — which routes to rule 4.
 */
export function scoreFromEvents(eventLookup) {
  if (!eventLookup || eventLookup.status !== "complete") return null;
  const events = Array.isArray(eventLookup.events) ? eventLookup.events : null;
  if (!events || events.length === 0) return null;

  // Keep production release builds only. Require buildType === "release" (not merely
  // "not debug") so an event whose app.build_type tag is absent — older versions, an
  // untagged process — is NOT silently trusted as a release; that matches how
  // classifyBuildType treats the same missing metadata as not-release. When no event
  // clears this bar, scoreFromEvents returns null and severity falls open to webhook counts.
  const production = events.filter(
    (e) => e && e.environment === "production" && e.buildType === "release"
  );
  if (production.length === 0) return null;

  const withRelease = production
    .map((e) => ({ event: e, release: normalizeRelease(e.release) }))
    .filter((r) => r.release !== null);
  if (withRelease.length === 0) return null;

  let newest = withRelease[0].release;
  for (const r of withRelease) {
    if (compareRelease(r.release, newest) > 0) newest = r.release;
  }

  const partition = withRelease.filter((r) => r.release.key === newest.key);
  const occurrences = partition.length;
  // Count each anonymous (null/empty user_id) event as its OWN user. EnviousWispr
  // sets no Sentry user and sendDefaultPii=false, so many events carry no id; 10
  // such events could be 10 distinct people, and under-scoring would hide a P0.
  // Over-counting is the safe direction for severity — ports tik_eligibility.py
  // `_distinct_users` (the reviewed precedent for the same data).
  const knownUsers = new Set();
  let anonymous = 0;
  for (const r of partition) {
    const id = r.event.userId;
    if (id != null && id !== "") knownUsers.add(id);
    else anonymous += 1;
  }
  const users = knownUsers.size + anonymous;
  return { occurrences, users };
}

/** Strictly parse a Sentry release into a comparable semver key. Null if it does not parse. */
export function normalizeRelease(release) {
  if (typeof release !== "string") return null;
  // Forms: "com.enviouswispr.app@2.3.1", "2.3.1", "2.3.1+build", "2.3.1-beta".
  const at = release.lastIndexOf("@");
  const versionPart = at >= 0 ? release.slice(at + 1) : release;
  const m = versionPart.match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  const tuple = [Number(m[1]), Number(m[2]), Number(m[3])];
  return { key: `${tuple[0]}.${tuple[1]}.${tuple[2]}`, tuple };
}

/**
 * Human-readable version for the embed. Sentry stores the release as
 * "com.enviouswispr.app@2.3.1"; show just "2.3.1". Falls back to the part after
 * the last "@" for a non-semver release, and "unknown" when there is no release.
 */
export function displayVersion(release) {
  if (typeof release !== "string" || release.length === 0) return "unknown";
  const norm = normalizeRelease(release);
  if (norm) return norm.key;
  const at = release.lastIndexOf("@");
  return at >= 0 ? release.slice(at + 1) : release;
}

/** Render an OS value as "macOS X", tolerating a source that already includes the prefix. */
export function formatOs(osVersion) {
  if (!osVersion) return null;
  return /^macos/i.test(osVersion) ? osVersion : `macOS ${osVersion}`;
}

function compareRelease(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a.tuple[i] !== b.tuple[i]) return a.tuple[i] - b.tuple[i];
  }
  return 0;
}

/** Severity thresholds (§3.1 rule 3). Counts are release-scoped (scored) or webhook (fallback). */
export function classifySeverity(userCount, timesSeen, level) {
  if (level === "fatal" || userCount >= 10) return "P0";
  if (userCount >= 3 || timesSeen >= 20) return "P1";
  if (userCount >= 2 || timesSeen >= 5) return "P2";
  return "P3";
}

// ── Rate-alert (spike) path (#1965) ────────────────────────────────────────────

/** Sentry files each metric-alert firing as an issue. `issueCategory` is the
 * documented discriminator; `issueType` is checked too because a payload
 * carrying one and not the other is exactly the ambiguity that should take the
 * safe path rather than be guessed at. */
export function isMetricIssue(issue) {
  return issue?.issueCategory === "metric" || issue?.issueType === "metric_issue";
}

/** SIX HOURS, fixed, on a key of its own.
 *
 * NOT inherited from THROTTLE_HOURS. That table is keyed by PRIORITY, and a
 * metric issue whose count has passed 20 scores P1 and then flips to
 * `substatus: "regressed"` on every single firing - which hits rule 7's
 * explicit regression bypass and would post every time, throttle or no. The
 * generic policy cannot deliver a six-hour gap for this shape, so this is new
 * policy rather than a free inheritance. An earlier draft of the plan claimed
 * otherwise and contradicted itself two sections later. */
const SPIKE_THROTTLE_HOURS = 6;

/** Its own namespace, so a rate alert and an error issue can never collide on a
 * key or evict each other's window. */
const spikeKey = (issueId) => `spike:${issueId}`;

/** The breakdown must describe the SAME population the rule counted, or the
 * card explains a firing with numbers that did not cause it.
 *
 * VERBATIM from the live rules, re-queried 2026-08-06 rather than read from
 * notes: 415417 "Error Spike (>5/hr)", 415418 "XPC Service Crash (>1/hr)" and
 * 415419 "AI Failure Spike (>3/hr)" are all `count()` over `is:unresolved` on a
 * 60-minute window. Copy the string; do not improve on it. A cleverer predicate
 * that is merely equivalent today drifts the moment Sentry changes what
 * `is:unresolved` covers, and the card would then be confidently wrong rather
 * than obviously stale.
 *
 * Measured overcount at the time of writing: ZERO resolved-issue events over
 * both 24h and 7d, so this corrects a mechanism rather than a live wrong
 * number. It is still worth having, because the failure is silent - an inflated
 * card looks exactly like a real spike - and because #1965 collapses the three
 * rules to one, after which any drift between rule and card has a single place
 * to go wrong. If that surviving rule's query is ever edited, edit this too. */
const SPIKE_RULE_PREDICATE = "is:unresolved";

/** ONE Sentry call. Grouped by issue AND release AND environment, because that
 * single response answers all three questions the card asks - which problems,
 * which versions, and how much of it is the founder's own dev machine - and a
 * separate call per question would be three round trips inside a webhook
 * deadline for data Sentry will hand over at once.
 *
 * DEV EVENTS ARE KEPT. The digests force production-only; this one must not.
 * The alert rules have `environment: null` by founder decision (2026-08-06):
 * dev events feed the same counters deliberately, because they prove the
 * pipeline is alive. The card's job is to SHOW the split, not to hide it.
 *
 * BUT THE RESOLVED FILTER IS NOT OPTIONAL, and for the opposite reason. This
 * card exists to explain ONE firing, so it must describe the population that
 * actually triggered it. All three metric rules count `is:unresolved` (see
 * SPIKE_RULE_PREDICATE), so an unfiltered breakdown can attribute the firing to
 * problems already resolved and inflate both the headline total and the
 * real-versus-dev split. Environment is widened deliberately; resolution status
 * is matched deliberately. They are different axes and pull opposite ways. */
async function fetchSpikeBreakdown(env, deadlineAt) {
  return discoverAggregate(
    { ...env, SENTRY_ORG },
    {
      queryName: "spike_breakdown",
      fields: ["issue", "title", "error.category", "release", "environment", "count()", "count_unique(user)"],
      requiredFields: ["error.category", "count()", "count_unique(user)"],
      query: SPIKE_RULE_PREDICATE,
      statsPeriod: "1h",
      sort: "-count()",
      perPage: 100,
    },
    { workerLabel: "sentry_triage", deadlineAt, requestTimeoutMs: SENTRY_FETCH_TIMEOUT_MS }
  );
}

/**
 * Reduces the grouped rows to the card's four numbers.
 *
 * EVENTS ARE THE UNIT, deliberately, and every total below is a sum of event
 * counts. Event counts ARE additive across rows; distinct-user counts are NOT,
 * because the same person appears under several (issue, release, environment)
 * rows. Summing them would produce a confident number that is simply wrong, so
 * per-problem people is reported as the largest single row - a genuine LOWER
 * bound - and worded as "at least". This is also the right unit on its own
 * terms: the rule that fires this card counts errors per hour.
 */
export function summarizeSpike(rows) {
  const byProblem = new Map();
  const releases = new Set();
  let totalEvents = 0;
  let devEvents = 0;

  for (const row of rows) {
    // THROWS rather than skipping. An earlier version skipped a malformed row
    // and carried on, which left a PARTIAL sum being published as "N errors in
    // the last hour" with nothing marking it short. The caller turns this into
    // the fail-open card, which says the breakdown could not be read - honest,
    // and still one buzz.
    const events = requireSpikeCount(row["count()"], "event count");
    const people = requireSpikeCount(row["count_unique(user)"], "people count");
    totalEvents = addSpikeCounts(totalEvents, events, "event total");

    // Anything not explicitly production counts as dev here. The split exists
    // to stop a founder's own testing reading as a user-facing incident, so the
    // conservative direction is to attribute an unlabelled event to dev rather
    // than to real users.
    if (row.environment !== "production") devEvents = addSpikeCounts(devEvents, events, "dev-event total");

    const category = typeof row["error.category"] === "string" ? row["error.category"].trim() : "";
    const label = category || (typeof row.title === "string" ? row.title.split(":", 1)[0].trim() : "") || "uncategorised";
    const existing = byProblem.get(label) || { label, events: 0, atLeastPeople: 0 };
    existing.events = addSpikeCounts(existing.events, events, "problem-event total");
    existing.atLeastPeople = Math.max(existing.atLeastPeople, people);
    byProblem.set(label, existing);

    if (typeof row.release === "string" && row.release.length > 0) {
      releases.add(displayVersion(row.release));
    }
  }

  return {
    totalEvents,
    devEvents,
    realEvents: totalEvents - devEvents,
    problems: [...byProblem.values()].sort((a, b) => b.events - a.events),
    releases: [...releases].sort(),
  };
}

/** Same discipline as the digest section, for the same reason: `Number()`
 * accepts `null`, `""`, `false`, `[]` and `["7"]`, and every one of those would
 * become a plausible figure in a card the founder acts on. */
function requireSpikeCount(value, field) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`Sentry spike breakdown returned an invalid ${field}`);
  }
  return value;
}

/** Each addend is a safe integer; their sum need not be. */
function addSpikeCounts(left, right, field) {
  const total = left + right;
  if (!Number.isSafeInteger(total)) {
    throw new TypeError(`Sentry spike breakdown ${field} exceeded the safe integer range`);
  }
  return total;
}

const SPIKE_PROBLEM_ROWS = 5;

/** The card. Names the problems, the versions and the dev split, which is
 * everything the old card could not say. */
export function buildSpikeEmbed(summary, { issueId, title, permalink }) {
  const top = summary.problems.slice(0, SPIKE_PROBLEM_ROWS);
  const remainder = summary.problems.length - top.length;
  const lines = top.map(
    (p) => `${p.events} × ${p.label} (at least ${p.atLeastPeople} ${p.atLeastPeople === 1 ? "person" : "people"})`
  );
  if (remainder > 0) lines.push(`plus ${remainder} more, included in the total`);

  return {
    // Says what it measured, not what the rule happens to be called. The three
    // old rules asserted diagnoses their `count()` query could not make.
    title: `[Sentry Spike] ${summary.totalEvents} errors in the last hour`,
    color: DISCORD_COLOR.P1,
    fields: [
      {
        name: "Real vs dev",
        value: `${summary.realEvents} from real users, ${summary.devEvents} from dev builds`,
        inline: true,
      },
      {
        name: "Versions",
        value: truncate(summary.releases.length ? summary.releases.join(", ") : "unknown"),
        inline: true,
      },
      { name: "Alert", value: `[${issueId}](${permalink})`, inline: true },
      {
        name: "What is driving it",
        value: truncate(lines.length ? lines.join("\n") : "no breakdown available", 900),
        inline: false,
      },
    ],
    footer: { text: `EnviousWispr Sentry Triage. Rate alert, ${SPIKE_THROTTLE_HOURS}h between posts` },
    timestamp: new Date().toISOString(),
  };
}

/** Fail-open card. A rate alert that cannot be enriched is still worth one
 * buzz: the founder learns the rule fired, and learns explicitly that the
 * breakdown is missing rather than being shown a confident empty one. */
export function buildSpikeFailOpenEmbed({ issueId, title, permalink }) {
  return {
    title: `[Sentry Spike] ${truncate(title || "error rate alert fired")}`,
    color: DISCORD_COLOR.P1,
    fields: [
      { name: "Alert", value: `[${issueId}](${permalink})`, inline: true },
      {
        name: "Breakdown",
        value: "Unavailable. The rule fired, but the hourly breakdown could not be read from Sentry.",
        inline: false,
      },
    ],
    footer: { text: `EnviousWispr Sentry Triage. Rate alert, ${SPIKE_THROTTLE_HOURS}h between posts` },
    timestamp: new Date().toISOString(),
  };
}

/** Pure, so the whole policy is testable without a KV or a network. */
export function decideSpike({ action, throttleLookup, now }) {
  // ELIGIBILITY FIRST, mirroring rule 1 for error issues. Only a firing posts:
  // `created`, or `unresolved` when Sentry reopens the metric issue on the next
  // breach. Everything else - `resolved`, `archived`, `assigned` - is somebody
  // tidying up, and a spike card sent because an alert was RESOLVED is worse
  // than no card at all.
  //
  // Checked BEFORE the throttle, so an ineligible action costs no KV read and
  // cannot be rescued by a fail-open throttle path.
  if (action !== "created" && action !== "unresolved") {
    return { post: false, reason: "ineligible-action" };
  }

  // A throttle READ failure fails open, exactly as rule 6 does for errors:
  // never let an unavailable KV suppress a real signal.
  if (throttleLookup?.status !== "complete") {
    return { post: true, reason: "throttle-unavailable-failopen" };
  }
  const stored = throttleLookup.value;
  if (stored == null) return { post: true, reason: "no-throttle" };
  const elapsedMs = now - stored.lastNotifiedAt;
  if (elapsedMs < SPIKE_THROTTLE_HOURS * 3600_000) {
    return { post: false, reason: "throttled" };
  }
  return { post: true, reason: "throttle-expired" };
}

async function handleSpike({ action, issue, issueId, env, lookupDeadlineAt, operationDeadlineAt, now }) {
  const kvKey = spikeKey(issueId);
  // The eligibility check inside decideSpike needs no KV read, so an ineligible
  // action is decided before one is spent.
  const eligibility = decideSpike({ action, throttleLookup: null, now });
  if (!eligibility.post && eligibility.reason === "ineligible-action") {
    console.log(`[sentry-triage] Spike ${issueId} ${action} — no post`);
    return;
  }
  const decision = decideSpike({ action, throttleLookup: await readThrottle(env, kvKey), now });
  if (!decision.post) {
    console.log(`[sentry-triage] Spike ${issueId} suppressed (${decision.reason})`);
    return;
  }

  const title = issue.title ?? "";
  const permalink = issue.permalink ?? issue.web_url ?? "";

  let embed;
  try {
    const breakdown = await fetchSpikeBreakdown(env, lookupDeadlineAt);
    // A FULL PAGE means the sum is short, and the card's headline states an
    // exact count. Unlike the digest - which discloses its ceiling in a list the
    // founder is already reading - this card's whole content IS the number, so
    // there is nothing left to qualify. Fail open instead of publishing a
    // partial total as exact.
    const summary = breakdown.truncated ? null : summarizeSpike(breakdown.rows);
    // An empty breakdown is the same problem from the other end: the enriched
    // card would read "0 errors in the last hour" beside an alert that fired
    // because there were more than five.
    embed = summary && summary.totalEvents > 0
      ? buildSpikeEmbed(summary, { issueId, title, permalink })
      : buildSpikeFailOpenEmbed({ issueId, title, permalink });
  } catch (err) {
    console.warn(`[sentry-triage] Spike ${issueId} breakdown unavailable: ${err.message}`);
    embed = buildSpikeFailOpenEmbed({ issueId, title, permalink });
  }

  const result = await postDiscord(env.DISCORD_WEBHOOK_URL, embed, {
    issueId,
    deadlineAt: operationDeadlineAt,
  });
  if (!result.ok) {
    // Same transport-commit invariant as the error path: no confirmed delivery,
    // no throttle, so the next firing stays eligible.
    console.warn(`[sentry-triage] Spike ${issueId} NOT delivered after ${result.attempts} attempt(s), no throttle written`);
    return;
  }

  try {
    await env.SENTRY_DEDUP.put(
      kvKey,
      JSON.stringify({ lastNotifiedAt: now, priority: "spike" }),
      { expirationTtl: KV_TTL_SECONDS }
    );
  } catch (err) {
    console.error(`[sentry-triage] Spike throttle write failed for ${issueId}:`, err.message);
  }
  console.log(`[sentry-triage] Spike ${issueId} posted (${decision.reason})`);
}

// ── Data acquisition (§3.2) ─────────────────────────────────────────────────────

/**
 * Paginated compact event read. Never returns a partial list as complete: any
 * failed page, malformed body, deadline expiry, or page-cap-with-more-pending
 * returns an incomplete/malformed status so severity fails open (rule 4).
 */
async function fetchEventPartition(issueId, env, deadlineAt) {
  const base =
    `https://us.sentry.io/api/0/organizations/${SENTRY_ORG}/issues/${issueId}/events/` +
    `?statsPeriod=90d&per_page=${SENTRY_PER_PAGE}`;
  let url = base;
  const events = [];

  for (let page = 0; page < SENTRY_MAX_PAGES; page++) {
    if (Date.now() >= deadlineAt) return { status: "incomplete" };

    let res;
    try {
      res = await fetchBefore(
        url,
        { headers: { Authorization: `Bearer ${env.SENTRY_AUTH_TOKEN}` } },
        deadlineAt,
        SENTRY_FETCH_TIMEOUT_MS,
        "sentry-events"
      );
    } catch {
      return { status: "incomplete" };
    }
    if (!res.ok) return { status: "incomplete" };

    let arr;
    try {
      arr = await res.json();
    } catch {
      return { status: "malformed" };
    }
    if (!Array.isArray(arr)) return { status: "malformed" };

    for (const e of arr) events.push(extractEventRecord(e));

    const next = parseNextCursor(res.headers.get("link"));
    if (!next) return { status: "complete", events };
    url = next;
  }

  // Reached the page cap with a next cursor still pending — not a complete partition.
  return { status: "incomplete" };
}

/** Extract the fields §3.2 needs plus the safe metadata the embed renders. */
export function extractEventRecord(event) {
  const tags = Array.isArray(event?.tags) ? event.tags : [];
  const tagValue = (key) => tags.find((t) => t?.key === key)?.value ?? null;

  const releaseTag = tagValue("release");
  const release =
    releaseTag ??
    (typeof event?.release === "string"
      ? event.release
      : typeof event?.release?.version === "string"
        ? event.release.version
        : null);

  return {
    release,
    environment: tagValue("environment") ?? event?.environment ?? null,
    buildType: tagValue("app.build_type"),
    level: (tagValue("level") ?? event?.level ?? "").toLowerCase() || null,
    userId: event?.user?.id ?? null,
    category: tagValue("error.category"),
    stage: tagValue("pipeline.stage"),
    // The compact events-list endpoint returns contexts:null; OS/device live in
    // tags there (os="macOS 26.6.0", device="Mac16,8"). Read tags first, keep the
    // contexts path as a defensive fallback for any richer event serialization.
    osVersion: tagValue("os") ?? event?.contexts?.os?.version ?? null,
    deviceModel: tagValue("device") ?? event?.contexts?.device?.model ?? null,
  };
}

/** Parse Sentry's RFC-5988 Link header, returning the next-page URL when more results exist. */
export function parseNextCursor(linkHeader) {
  if (!linkHeader) return null;
  const parts = linkHeader.split(",");
  for (const part of parts) {
    if (/rel="next"/.test(part) && /results="true"/.test(part)) {
      const m = part.match(/<([^>]+)>/);
      if (m) return m[1];
    }
  }
  return null;
}

/**
 * Search open GitHub issues for an exact `<!-- sentry-issue-id: {shortId} -->`
 * marker. A missing/invalid shortId, a failed page, or the page cap with results
 * still pending returns unavailable/incomplete → rule 5 treats it as
 * unconfirmed-known and posts (fail-open). Only a fully paged search with no
 * match returns complete/openExactMarker:false.
 */
async function fetchTicketLookup(shortId, env, deadlineAt) {
  if (!shortId) return { status: "unavailable" };

  const repo = env.GITHUB_REPO;

  for (let page = 1; page <= GITHUB_MAX_PAGES; page++) {
    if (Date.now() >= deadlineAt) return { status: "incomplete" };

    const url =
      `https://api.github.com/repos/${repo}/issues` +
      `?state=open&per_page=${GITHUB_PER_PAGE}&page=${page}`;

    let res;
    try {
      res = await fetchBefore(
        url,
        {
          headers: {
            Authorization: `Bearer ${env.GITHUB_ISSUES_READ_TOKEN}`,
            Accept: "application/vnd.github+json",
            "User-Agent": "enviouswispr-sentry-triage",
            "X-GitHub-Api-Version": "2022-11-28",
          },
        },
        deadlineAt,
        GITHUB_FETCH_TIMEOUT_MS,
        "github-issues"
      );
    } catch {
      return { status: "incomplete" };
    }
    if (!res.ok) return { status: "incomplete" };

    let arr;
    try {
      arr = await res.json();
    } catch {
      return { status: "incomplete" };
    }
    if (!Array.isArray(arr)) return { status: "incomplete" };

    if (pageHasExactTicket(arr, shortId)) return { status: "complete", openExactMarker: true };

    // A short page is the last page: the search completed with no exact match.
    if (arr.length < GITHUB_PER_PAGE) return { status: "complete", openExactMarker: false };
  }

  // Exhausted the page cap with a full final page — more may remain, so unconfirmed.
  return { status: "incomplete" };
}

/**
 * True if any real ISSUE on this page carries the exact
 * `<!-- sentry-issue-id: {shortId} -->` marker. GitHub's Issues endpoint also
 * returns pull requests (they have a `pull_request` field); a PR that copied the
 * ticket template must NEVER count as an open ticket — that would falsely suppress
 * a Discord post. A fuzzy body mention without the exact marker also does not count.
 */
export function pageHasExactTicket(issues, shortId) {
  if (!Array.isArray(issues)) return false;
  const marker = `<!-- sentry-issue-id: ${shortId} -->`;
  for (const gh of issues) {
    if (gh?.pull_request) continue; // a PR is never a triage ticket
    const bodyText = typeof gh?.body === "string" ? gh.body : "";
    if (bodyText.includes(marker)) return true;
  }
  return false;
}

/**
 * Read the per-issue notification throttle. Returns typed status so rule 6 can
 * fail open. A legacy record with no `lastNotifiedAt` normalizes to no throttle;
 * any other malformed shape is reported as malformed (also fail-open).
 */
async function readThrottle(env, kvKey) {
  let raw;
  try {
    raw = await env.SENTRY_DEDUP.get(kvKey);
  } catch {
    return { status: "unavailable" };
  }
  if (!raw) return { status: "complete", value: null };

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { status: "malformed" };
  }
  if (!parsed || typeof parsed !== "object") return { status: "malformed" };

  // Legacy {state:pending|fired|resolved,...} records have no lastNotifiedAt →
  // treat as no active throttle; never branch on the old `state` field.
  if (!("lastNotifiedAt" in parsed)) return { status: "complete", value: null };

  const { lastNotifiedAt, priority } = parsed;
  // "spike" joins the four priorities because the rate-alert path stores its
  // window through this same reader (#1965). Without it, every spike record
  // read back as MALFORMED, decideSpike fell open, and the six-hour throttle
  // never once applied - which is the exact triple-buzz this was built to stop.
  // Caught by its own test rather than in production.
  //
  // The two record kinds cannot be confused: error windows live under
  // `sentry:<id>` and spike windows under `spike:<id>`, so neither path can
  // ever read the other's value however this list grows.
  if (
    typeof lastNotifiedAt !== "number" ||
    !Number.isFinite(lastNotifiedAt) ||
    !["P0", "P1", "P2", "P3", "spike"].includes(priority)
  ) {
    return { status: "malformed" };
  }
  return { status: "complete", value: { lastNotifiedAt, priority } };
}

// ── Discord transport (§7 / r3 Edit 4) ──────────────────────────────────────────

class DeadlineExceededError extends Error {
  constructor(stage) {
    super(`${stage} deadline exceeded`);
    this.name = "DeadlineExceededError";
  }
}

/** fetch() bounded by both an absolute deadline and a per-request limit. */
async function fetchBefore(url, options, deadlineAt, perRequestLimitMs, stage) {
  const remainingMs = deadlineAt - Date.now();
  if (remainingMs <= 0) throw new DeadlineExceededError(stage);

  const controller = new AbortController();
  const timeoutMs = Math.max(1, Math.min(perRequestLimitMs, remainingMs));
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (error) {
    if (controller.signal.aborted) throw new DeadlineExceededError(stage);
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Post an embed to Discord with a status check and one retry. Returns
 * { ok, attempts }. On two failures, emits one structured `discord_delivery_failed`
 * log (issue ID, attempt count, HTTP status/error class, timestamp) and returns
 * ok:false so the caller writes no throttle.
 */
async function postDiscord(webhookUrl, embed, { issueId = "unknown", deadlineAt = Date.now() + 8000 } = {}) {
  if (!webhookUrl) {
    console.error(
      JSON.stringify({
        event: "discord_delivery_failed",
        issueId,
        attempts: 0,
        errorClass: "missing_webhook_url",
        timestamp: new Date().toISOString(),
      })
    );
    return { ok: false, attempts: 0 };
  }

  let lastStatus = null;
  let lastErrorClass = null;

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      const response = await fetchBefore(
        webhookUrl,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ embeds: [embed] }),
        },
        deadlineAt,
        DISCORD_ATTEMPT_TIMEOUT_MS,
        "discord"
      );

      if (response.ok) return { ok: true, attempts: attempt };

      lastStatus = response.status;
      lastErrorClass = "http_non_2xx";
    } catch (error) {
      lastErrorClass = error?.name ?? "network_error";
    }
  }

  console.error(
    JSON.stringify({
      event: "discord_delivery_failed",
      issueId,
      attempts: 2,
      httpStatus: lastStatus,
      errorClass: lastErrorClass,
      timestamp: new Date().toISOString(),
    })
  );

  return { ok: false, attempts: 2 };
}

// ── Discord embeds ───────────────────────────────────────────────────────────

/**
 * Build the embed from the already-fetched event partition (no extra subrequest).
 * The newest event supplies safe source/category/version metadata; if the event
 * lookup is degraded, fall open to a basic embed built from webhook fields.
 */
export function buildEmbedFromLookup(eventLookup, { issueId, title, permalink, timesSeen, userCount, priority }) {
  const events =
    eventLookup && eventLookup.status === "complete" && Array.isArray(eventLookup.events)
      ? eventLookup.events
      : null;

  if (!events || events.length === 0) {
    // Degraded/empty event data → classifyBuildType returns "unknown".
    return buildFailOpenEmbed({ issueId, title, permalink, timesSeen, userCount, priority, buildType: "unknown" });
  }

  const buildType = classifyBuildType(eventLookup);
  // Show metadata from the event that best represents WHY the issue got its label,
  // so the headline/version/system never contradict the tag. Events are newest-first,
  // so find() picks the newest such event:
  //   release → the confirmed real-user event
  //   dev     → the dev event (all events are dev here)
  //   unknown → the unclassifiable (not-confidently-dev) event that made it untrusted,
  //             never the dev-noise event that would read as "just my testing"
  const rep =
    (buildType === "release" && events.find(isReleaseEvent)) ||
    (buildType === "dev" && events.find(isDevEvent)) ||
    (buildType === "unknown" && events.find((e) => !isDevEvent(e))) ||
    events[0];
  const metadata = {
    category: rep.category,
    stage: rep.stage,
    environment: rep.environment,
    buildType: rep.buildType,
    release: rep.release,
    osVersion: rep.osVersion,
    deviceModel: rep.deviceModel,
  };
  return buildEnrichedEmbed({ issueId, title, permalink, timesSeen, userCount, priority, metadata, buildType });
}

export function truncate(value, max = FIELD_MAX_CHARS) {
  if (typeof value !== "string") return value;
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
}

/**
 * Build-type of the whole issue, from all fetched events (#1470 follow-up).
 * "release" if ANY event is a real user on a production release build — a mixed
 * issue that reached real users reads Release, matching how severity scores the
 * production partition. "dev" if there is no such event but some event is
 * development/debug (your own testing). "unknown" for degraded/empty event data.
 * The single authority for the Dev-vs-Release label shown in the alert.
 */
// Per-event signals over the (environment × app.build_type) matrix:
//   release: production + release build      → a confirmed real user
//   dev:     debug build OR development env  → confidently your own testing (debug
//            is authoritative even if the env tag says production)
// Anything else (e.g. a release build with a missing environment tag, or a
// production event with a missing build type) is UNCLASSIFIABLE and may be a real user.
const isReleaseEvent = (e) => e && e.environment === "production" && e.buildType === "release";
const isDevEvent = (e) => e && (e.buildType === "debug" || e.environment === "development");

export function classifyBuildType(eventLookup) {
  if (!eventLookup || eventLookup.status !== "complete" || !Array.isArray(eventLookup.events)) {
    return "unknown";
  }
  const events = eventLookup.events;
  // A confirmed real user wins. Otherwise call it Dev ONLY when every event is
  // confidently dev — a single unclassifiable (possibly-real-user) event keeps the
  // whole issue Unknown rather than masking it as your testing.
  if (events.some(isReleaseEvent)) return "release";
  if (events.length > 0 && events.every(isDevEvent)) return "dev";
  return "unknown";
}

/** Short tag for the alert title: Release / Dev / Unknown build. */
export function buildTypeTag(buildType) {
  if (buildType === "release") return "Release";
  if (buildType === "dev") return "Dev";
  return "Unknown build";
}

/** Longer source label for the embed body. */
export function sourceLabelFor(buildType) {
  if (buildType === "release") return "👤 Release (real users)";
  if (buildType === "dev") return "🧪 Dev build (your testing)";
  return "❓ Unknown build";
}

/** Readable headline: prefer the safe error.category tag over a possibly-stale title. */
export function readableHeadline(title, metadata) {
  return metadata?.category ?? title;
}

export function metadataFields(metadata) {
  const what = [metadata.category, metadata.stage].filter(Boolean).join(" / ") || "unknown";
  const system =
    [formatOs(metadata.osVersion), metadata.deviceModel].filter(Boolean).join(", ") || "unknown";
  return { what, system };
}

export function buildEnrichedEmbed({ issueId, title, permalink, timesSeen, userCount, priority, metadata, buildType = "unknown" }) {
  const { what, system } = metadataFields(metadata);
  return {
    title: `[Sentry ${priority} · ${buildTypeTag(buildType)}] ${truncate(readableHeadline(title, metadata))}`,
    color: DISCORD_COLOR[priority] ?? DISCORD_COLOR.P3,
    fields: [
      { name: "Source", value: sourceLabelFor(buildType), inline: true },
      { name: "What", value: truncate(what), inline: true },
      {
        name: "Impact",
        value: `Sentry issue totals: ${userCount} user(s) · ${timesSeen} occurrences`,
        inline: true,
      },
      { name: "Version", value: truncate(displayVersion(metadata.release)), inline: true },
      { name: "System", value: truncate(system), inline: true },
      { name: "Sentry", value: `[${issueId}](${permalink})`, inline: true },
    ],
    footer: { text: `EnviousWispr Sentry Triage. ${priority}` },
    timestamp: new Date().toISOString(),
  };
}

export function buildFailOpenEmbed({ issueId, title, permalink, timesSeen, userCount, priority, buildType = "unknown" }) {
  return {
    title: `[Sentry ${priority} · ${buildTypeTag(buildType)}] ${truncate(title)}`,
    color: DISCORD_COLOR[priority] ?? DISCORD_COLOR.P3,
    fields: [
      { name: "Source", value: `${sourceLabelFor(buildType)} (Sentry fetch failed)`, inline: true },
      {
        name: "Impact",
        value: `Sentry issue totals: ${userCount} user(s) · ${timesSeen} occurrences`,
        inline: true,
      },
      { name: "Sentry", value: `[${issueId}](${permalink})`, inline: true },
      { name: "Details", value: "Details unavailable. Sentry fetch failed.", inline: false },
    ],
    footer: { text: `EnviousWispr Sentry Triage. ${priority}` },
    timestamp: new Date().toISOString(),
  };
}

// ── Utilities ─────────────────────────────────────────────────────────────────

async function hashString(str) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(str));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
