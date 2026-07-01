/**
 * EnviousWispr Sentry Triage Worker
 *
 * Receives Sentry Internal Integration webhooks, verifies HMAC, classifies
 * severity, deduplicates via KV, and fires a Claude Code Routine for P0-P2 issues.
 *
 * Read-only pipeline: the downstream Routine creates/updates GitHub issues.
 * This Worker never touches GitHub directly (except the Discord alerts it posts
 * directly: P3 new-issue pings, the daily Routine cap alert, and Routine-fire
 * failures). Every Discord alert is enriched with a source label (#1229): a
 * best-effort fetch of the issue's latest Sentry event reads safe, already-scrubbed
 * metadata (category, stage, environment, build type, OS, device) and renders
 * whether the failure came from the founder's own test build or a real user.
 * Fails open to the basic embed on any fetch error — an alert is never lost.
 */

const DISCORD_COLOR = { P0: 0xe74c3c, P1: 0xe67e22, P2: 0xf1c40f, P3: 0x95a5a6 };
const SENTRY_ORG = "envious-labs-llc";
const SENTRY_FETCH_TIMEOUT_MS = 5000;
const FIELD_MAX_CHARS = 200;

// ── Entry point ──────────────────────────────────────────────────────────────

export default {
  async fetch(request, env, ctx) {
    // Only accept POST
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

    // Return 202 immediately — Sentry retries if we take >10s
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

    const signatureBuffer = await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(body)
    );

    // Convert computed signature to hex
    const computedHex = Array.from(new Uint8Array(signatureBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Constant-time comparison — avoids timing side-channels without relying
    // on any runtime-specific API. XOR each byte and OR-accumulate: diff===0 iff equal.
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

// ── Main triage handler ───────────────────────────────────────────────────────

async function handleTriage(body, env) {
  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    console.error("[sentry-triage] Failed to parse JSON payload");
    return;
  }

  // Replay protection: reject signatures seen in last 90 min
  const sigHash = await hashString(body);
  const replayKey = `replay:${sigHash}`;
  const seen = await env.SENTRY_DEDUP.get(replayKey);
  if (seen) {
    console.log("[sentry-triage] Duplicate delivery detected, skipping");
    return;
  }
  await env.SENTRY_DEDUP.put(replayKey, "1", { expirationTtl: 5400 }); // 90 min

  // Validate payload shape — skip metric alerts (data.metric_alert) and malformed payloads
  const issue = payload?.data?.issue;
  if (!issue) {
    console.log("[sentry-triage] No data.issue — skipping (metric alert or unknown type)");
    return;
  }

  const action = payload.action ?? "";
  const issueId = issue.id ?? "";
  const title = issue.title ?? "";
  const culprit = issue.culprit ?? "";
  const level = (issue.level ?? "").toLowerCase();
  const userCount = parseInt(issue.userCount, 10) || 0;
  const timesSeen = parseInt(issue.count, 10) || 0; // count is a string in Sentry payloads
  const substatus = issue.substatus ?? "";
  const permalink = issue.permalink ?? issue.web_url ?? "";
  const release = issue.release ?? null;

  if (!issueId) {
    console.error("[sentry-triage] Missing issue ID, skipping");
    return;
  }

  const kvKey = `sentry:${issueId}`;

  // Handle terminal actions — update KV state and exit without firing Routine
  if (action === "resolved" || action === "archived") {
    // 90-day TTL — same as fired state, prevents unbounded KV growth.
    await env.SENTRY_DEDUP.put(
      kvKey,
      JSON.stringify({ state: "resolved", updatedAt: Date.now() }),
      { expirationTtl: 7776000 } // 90 days
    );
    console.log(`[sentry-triage] Issue ${issueId} ${action} — KV updated, no Routine`);
    return;
  }

  if (action === "assigned") {
    console.log(`[sentry-triage] Issue ${issueId} assigned — skipping`);
    return;
  }

  // Filter: only error/fatal level
  if (level !== "error" && level !== "fatal") {
    console.log(`[sentry-triage] Issue ${issueId} level=${level} — skipping`);
    return;
  }

  // Determine intent from action + substatus
  let intent;
  if (action === "created") {
    intent = "new";
  } else if (action === "unresolved" && substatus === "regressed") {
    intent = "regression";
  } else if (action === "unresolved") {
    intent = "update";
  } else {
    console.log(`[sentry-triage] Unknown action=${action}, substatus=${substatus} — skipping`);
    return;
  }

  // Classify severity
  const { priority, label } = classifySeverity(userCount, timesSeen, level);

  // KV dedup check
  const existing = await env.SENTRY_DEDUP.get(kvKey);
  const kvData = existing ? JSON.parse(existing) : null;

  if (kvData) {
    const state = kvData.state ?? "unknown";
    const lastCommentAt = kvData.lastCommentAt ?? 0;
    const hoursSinceComment = (Date.now() - lastCommentAt) / 3600000;

    if (state === "pending" && Date.now() - (kvData.firedAt ?? 0) < 600000) {
      // Routine already in-flight (within 10 min window) — skip to avoid double-fire
      console.log(`[sentry-triage] Issue ${issueId} Routine in-flight, skipping`);
      return;
    }

    if (state !== "resolved") {
      if (intent === "regression") {
        // Always fire on regression regardless of rate limit
        console.log(`[sentry-triage] Regression detected for ${issueId}`);
      } else if (priority === "P0" || priority === "P1") {
        // P0/P1 override 24h rate limit
        console.log(`[sentry-triage] ${priority} override for ${issueId}`);
      } else if (priority === "P2" && hoursSinceComment < 24) {
        console.log(`[sentry-triage] P2 rate-limited for ${issueId} (${hoursSinceComment.toFixed(1)}h since last comment)`);
        return;
      }
    }
  }

  // P3: Discord ping only, no Routine
  if (priority === "P3") {
    const embed = await buildSourceLabeledEmbed({
      issueId, title, permalink, timesSeen, userCount, priority, env,
    });
    await postDiscord(env.DISCORD_WEBHOOK_URL, embed);
    console.log(`[sentry-triage] P3 issue ${issueId} - Discord ping only`);
    return;
  }

  // Check daily Routine cap
  const today = new Date().toISOString().slice(0, 10);
  const capKey = `routines:fired:${today}`;
  // Non-atomic read/modify/write: two concurrent Workers can both read capCount=12,
  // both pass the gate, and overwrite each other's increment. CF KV has no CAS.
  // Accepted: solo app, low volume, max over-fire bounded by per-colo concurrency.
  // P0 always bypasses the cap anyway, so worst case is a few extra P1/P2 Routines.
  const capRaw = await env.SENTRY_DEDUP.get(capKey);
  const capCount = parseInt(capRaw ?? "0", 10);

  if (capCount >= 13 && priority !== "P0") {
    // Cap at 13 to leave 2 headroom. P0 always bypasses — a critical crash at 11pm
    // should never be silently dropped because the day was busy.
    console.warn(`[sentry-triage] Daily Routine count at ${capCount}/15 - blocking ${priority}, posting Discord alert`);
    const sourceLabel = await fetchSourceLabel(issueId, env);
    await postDiscord(
      env.DISCORD_WEBHOOK_URL,
      buildCapAlertEmbed(capCount, issueId, title, permalink, sourceLabel)
    );
    return;
  }

  // Write pending state before firing (self-healing TTL of 10 min in case Routine never responds)
  await env.SENTRY_DEDUP.put(
    kvKey,
    JSON.stringify({ state: "pending", intent, firedAt: Date.now(), priority }),
    { expirationTtl: 600 } // 10 min TTL — overwritten with permanent entry on success
  );

  // Fire the Routine
  const textPayload = [
    `intent: ${intent}`,
    `sentry_issue_id: ${issueId}`,
    `sentry_url: ${permalink}`,
    `title: ${title}`,
    `culprit: ${culprit}`,
    `level: ${level}`,
    `user_count: ${userCount}`,
    `times_seen: ${timesSeen}`,
    `release: ${release ?? "null"}`,
    `environment: production`,
    `priority: ${priority}`,
  ].join("\n");

  let sessionUrl = null;
  try {
    const fireRes = await fetch(
      `https://api.anthropic.com/v1/claude_code/routines/${env.ROUTINE_TRIGGER_ID}/fire`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.ROUTINE_TOKEN}`,
          "anthropic-beta": "experimental-cc-routine-2026-04-01",
          "anthropic-version": "2023-06-01",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ text: textPayload }),
      }
    );

    if (!fireRes.ok) {
      const errBody = await fireRes.text();
      throw new Error(`HTTP ${fireRes.status}: ${errBody}`);
    }

    const fireData = await fireRes.json();
    sessionUrl = fireData.claude_code_session_url ?? null;

    // Update KV with permanent fired state (no TTL)
    // 90-day TTL — prevents unbounded KV growth while preserving dedup for active issues.
    // Resolved/archived events overwrite with state:"resolved" before this TTL matters.
    await env.SENTRY_DEDUP.put(
      kvKey,
      JSON.stringify({
        state: "fired",
        intent,
        priority,
        firedAt: Date.now(),
        sessionUrl,
        lastCommentAt: Date.now(),
      }),
      { expirationTtl: 7776000 } // 90 days
    );

    // Increment daily counter
    // Key name is the date string (routines:fired:YYYY-MM-DD) so it naturally
    // resets at midnight UTC when the date rolls over. No TTL needed.
    await env.SENTRY_DEDUP.put(capKey, String(capCount + 1));

    console.log(`[sentry-triage] Routine fired for ${issueId} (${priority}) - session: ${sessionUrl}`);
  } catch (err) {
    console.error(`[sentry-triage] Routine fire failed for ${issueId}:`, err.message);

    // Fallback: post Discord alert so nothing is silently dropped
    const sourceLabel = await fetchSourceLabel(issueId, env);
    await postDiscord(
      env.DISCORD_WEBHOOK_URL,
      buildFailureEmbed(issueId, title, permalink, priority, err.message, sourceLabel)
    );

    // Clear pending state so next event retries
    await env.SENTRY_DEDUP.delete(kvKey);
  }
}

// ── Severity classification ───────────────────────────────────────────────────

function classifySeverity(userCount, timesSeen, level) {
  if (level === "fatal" || userCount >= 10) return { priority: "P0", label: "P0-critical" };
  if (userCount >= 3 || timesSeen >= 20) return { priority: "P1", label: "P1-high" };
  if (userCount >= 2 || timesSeen >= 5) return { priority: "P2", label: "P2-medium" };
  return { priority: "P3", label: "P3-low" };
}

// ── Discord embeds ────────────────────────────────────────────────────────────

async function postDiscord(webhookUrl, embed) {
  if (!webhookUrl) {
    console.error("[sentry-triage] DISCORD_WEBHOOK_URL not set");
    return;
  }
  await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ embeds: [embed] }),
  });
}

// ── Source enrichment (#1229) ─────────────────────────────────────────────────
//
// Best-effort: fetch the issue's latest Sentry event and read already-scrubbed
// metadata (the on-device redactor ran before any of this left the user's Mac)
// to label whether the failure is the founder's own test build or a real user,
// plus surface category/stage/version/OS/device safely. Every call site fails
// open to the basic embed shape on any fetch error — an alert is never lost.

/** Safe-metadata allowlist (#1229 §3 PR-A step 6) — every value Discord ever shows. */
const SAFE_METADATA_FIELDS = [
  "category",
  "stage",
  "environment",
  "buildType",
  "release",
  "osVersion",
  "deviceModel",
];

export function truncate(value, max = FIELD_MAX_CHARS) {
  if (typeof value !== "string") return value;
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
}

/** Fetch the latest event for a Sentry issue. Throws on any non-200/timeout/parse failure. */
async function fetchLatestEvent(issueId, env) {
  const url = `https://us.sentry.io/api/0/organizations/${SENTRY_ORG}/issues/${issueId}/events/latest/`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${env.SENTRY_AUTH_TOKEN}` },
    signal: AbortSignal.timeout(SENTRY_FETCH_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`Sentry events/latest fetch failed: HTTP ${res.status}`);
  }
  return res.json();
}

/**
 * Pull the safe-metadata allowlist out of a Sentry event. `category` / `stage` /
 * `environment` / `buildType` / `release` live in `tags[]` ({key,value} pairs,
 * NOT top-level — SentryBreadcrumb sets error.category/pipeline.stage as event
 * tags and ObservabilityBootstrap sets environment/app.build_type as scope tags,
 * all merged into the same tags[] array server-side). `osVersion` / `deviceModel`
 * live under `contexts.os`/`contexts.device` (CONTEXTS, not tags) — confirmed
 * empirically against a real captured event during PR-B's round-trip (#1229).
 */
export function extractMetadata(event) {
  const tags = Array.isArray(event?.tags) ? event.tags : [];
  const tagValue = (key) => tags.find((t) => t?.key === key)?.value ?? null;

  return {
    category: tagValue("error.category"),
    stage: tagValue("pipeline.stage"),
    environment: tagValue("environment"),
    buildType: tagValue("app.build_type"),
    release: tagValue("release"),
    osVersion: event?.contexts?.os?.version ?? null,
    deviceModel: event?.contexts?.device?.model ?? null,
  };
}

/**
 * Three-state source classifier (#1229). Never defaults missing metadata to
 * "real user" — an older app version or a fetch that returned partial tags
 * must read as unknown, not silently assumed safe-to-ignore.
 */
export function classifySource(metadata) {
  const { environment, buildType } = metadata ?? {};
  if (environment === "development" || buildType === "debug") {
    return "🧪 Your test build (dev/debug)";
  }
  if (environment === "production" && buildType === "release") {
    return "👤 Real user (release)";
  }
  return "❓ Unknown source (metadata missing)";
}

/** Best-effort source label for the cap-alert / failure embeds. Null on fetch failure. */
async function fetchSourceLabel(issueId, env) {
  try {
    const event = await fetchLatestEvent(issueId, env);
    return classifySource(extractMetadata(event));
  } catch (err) {
    console.error(`[sentry-triage] Latest-event fetch failed for ${issueId}:`, err.message);
    return null;
  }
}

/** Readable headline: prefer the safe error.category tag over a possibly-stale title. */
export function readableHeadline(title, metadata) {
  return metadata?.category ?? title;
}

export function metadataFields(metadata) {
  const what = [metadata.category, metadata.stage].filter(Boolean).join(" / ") || "unknown";
  const system =
    [metadata.osVersion ? `macOS ${metadata.osVersion}` : null, metadata.deviceModel]
      .filter(Boolean)
      .join(", ") || "unknown";
  return { what, system };
}

export function buildEnrichedEmbed({ issueId, title, permalink, timesSeen, userCount, priority, metadata }) {
  const { what, system } = metadataFields(metadata);
  return {
    title: `[Sentry ${priority}] ${truncate(readableHeadline(title, metadata))}`,
    color: DISCORD_COLOR[priority] ?? DISCORD_COLOR.P3,
    fields: [
      { name: "Source", value: classifySource(metadata), inline: true },
      { name: "What", value: truncate(what), inline: true },
      {
        name: "Impact",
        value: `Sentry issue totals: ${userCount} user(s) · ${timesSeen} occurrences`,
        inline: true,
      },
      { name: "Version", value: truncate(metadata.release ?? "unknown"), inline: true },
      { name: "System", value: truncate(system), inline: true },
      { name: "Sentry", value: `[${issueId}](${permalink})`, inline: true },
    ],
    footer: { text: `EnviousWispr Sentry Triage. ${priority}` },
    timestamp: new Date().toISOString(),
  };
}

export function buildFailOpenEmbed({ issueId, title, permalink, timesSeen, userCount, priority }) {
  return {
    title: `[Sentry ${priority}] ${truncate(title)}`,
    color: DISCORD_COLOR[priority] ?? DISCORD_COLOR.P3,
    fields: [
      { name: "Source", value: "❓ Unknown source (Sentry fetch failed)", inline: true },
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

/** Orchestrator for the P3 new-issue embed: enrich, fail open on any error. */
async function buildSourceLabeledEmbed({ issueId, title, permalink, timesSeen, userCount, priority, env }) {
  try {
    const event = await fetchLatestEvent(issueId, env);
    const metadata = extractMetadata(event);
    return buildEnrichedEmbed({ issueId, title, permalink, timesSeen, userCount, priority, metadata });
  } catch (err) {
    console.error(`[sentry-triage] Latest-event fetch failed for ${issueId}:`, err.message);
    return buildFailOpenEmbed({ issueId, title, permalink, timesSeen, userCount, priority });
  }
}

export function buildCapAlertEmbed(capCount, issueId, title, permalink, sourceLabel) {
  return {
    title: "⚠️ Sentry Triage Daily Cap Reached",
    color: 0xff0000,
    description: `Daily Routine cap hit (${capCount}/15). Issue not triaged automatically.`,
    fields: [
      { name: "Missed Issue", value: truncate(`[${issueId}](${permalink}). ${title}`) },
      { name: "Source", value: sourceLabel ?? "❓ Unknown source (Sentry fetch failed)" },
    ],
    footer: { text: "EnviousWispr Sentry Triage. Check claude.ai/settings/usage" },
    timestamp: new Date().toISOString(),
  };
}

export function buildFailureEmbed(issueId, title, permalink, priority, errMsg, sourceLabel) {
  return {
    title: `[Sentry ${priority}] Routine fire failed`,
    color: 0xff0000,
    description: `Failed to fire Routine for [${issueId}](${permalink}). Manual triage required.`,
    fields: [
      { name: "Issue", value: title },
      { name: "Source", value: sourceLabel ?? "❓ Unknown source (Sentry fetch failed)" },
      { name: "Error", value: errMsg.slice(0, 200) },
    ],
    footer: { text: "EnviousWispr Sentry Triage • Routine failure" },
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
