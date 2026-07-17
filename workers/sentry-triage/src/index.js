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

    // Verify HMAC-SHA256 signature — must happen before 202 so we can 401 on bad sig
    const sigHeader = request.headers.get("sentry-hook-signature") ?? "";
    const verified = await verifyHmac(body, sigHeader, env.SENTRY_WEBHOOK_SECRET);
    if (!verified) {
      console.error("[sentry-triage] HMAC verification failed");
      return new Response("Unauthorized", { status: 401 });
    }

    // Return 202 immediately — Sentry retries if we take >10s. All Sentry/GitHub/
    // Discord I/O happens in the background, so it never touches Sentry's budget.
    ctx.waitUntil(handleTriage(body, env));
    return new Response("Accepted", { status: 202 });
  },
};

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

  // Validate payload shape — skip metric alerts (no data.issue) and malformed payloads
  const issue = payload?.data?.issue;
  if (!issue) {
    console.log("[sentry-triage] No data.issue — skipping (metric alert or unknown type)");
    return;
  }

  const action = payload.action ?? "";
  const issueId = issue.id ?? "";
  if (!issueId) {
    console.error("[sentry-triage] Missing issue ID, skipping");
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
  if (
    typeof lastNotifiedAt !== "number" ||
    !Number.isFinite(lastNotifiedAt) ||
    !["P0", "P1", "P2", "P3"].includes(priority)
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
