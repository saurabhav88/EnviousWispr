/**
 * EnviousWispr Sentry Triage Worker
 *
 * Receives Sentry Internal Integration webhooks, verifies HMAC, classifies
 * severity, deduplicates via KV, and fires a Claude Code Routine for P0-P2 issues.
 *
 * Read-only pipeline: the downstream Routine creates/updates GitHub issues.
 * This Worker never touches GitHub directly (except the daily-cap Discord alert).
 */

const DISCORD_COLOR = { P0: 0xe74c3c, P1: 0xe67e22, P2: 0xf1c40f, P3: 0x95a5a6 };

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

    // Convert header hex to Uint8Array for timingSafeEqual
    const computedBytes = encoder.encode(computedHex);
    const receivedBytes = encoder.encode(sigHeader);

    // timingSafeEqual requires equal-length buffers — length mismatch = invalid sig
    if (computedBytes.length !== receivedBytes.length) return false;

    // crypto.timingSafeEqual is a CF Workers non-standard extension
    return crypto.timingSafeEqual(computedBytes, receivedBytes);
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
    await env.SENTRY_DEDUP.put(kvKey, JSON.stringify({ state: "resolved", updatedAt: Date.now() }));
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
    await postDiscord(env.DISCORD_WEBHOOK_URL, buildP3Embed(issueId, title, permalink, timesSeen, userCount));
    console.log(`[sentry-triage] P3 issue ${issueId} — Discord ping only`);
    return;
  }

  // Check daily Routine cap
  const today = new Date().toISOString().slice(0, 10);
  const capKey = `routines:fired:${today}`;
  const capRaw = await env.SENTRY_DEDUP.get(capKey);
  const capCount = parseInt(capRaw ?? "0", 10);

  if (capCount >= 13) {
    // Fire at 13 to leave 2 headroom for P0s that arrive late in the day.
    console.warn(`[sentry-triage] Daily Routine count at ${capCount}/15 — cap threshold reached, posting Discord alert`);
    await postDiscord(env.DISCORD_WEBHOOK_URL, buildCapAlertEmbed(capCount, issueId, title, permalink));
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

    console.log(`[sentry-triage] Routine fired for ${issueId} (${priority}) — session: ${sessionUrl}`);
  } catch (err) {
    console.error(`[sentry-triage] Routine fire failed for ${issueId}:`, err.message);

    // Fallback: post Discord alert so nothing is silently dropped
    await postDiscord(
      env.DISCORD_WEBHOOK_URL,
      buildFailureEmbed(issueId, title, permalink, priority, err.message)
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

function buildP3Embed(issueId, title, permalink, timesSeen, userCount) {
  return {
    title: `[Sentry P3] ${title}`,
    color: DISCORD_COLOR.P3,
    fields: [
      { name: "Impact", value: `${userCount} user(s), ${timesSeen} occurrences`, inline: true },
      { name: "Sentry", value: `[${issueId}](${permalink})`, inline: true },
    ],
    footer: { text: "EnviousWispr Sentry Triage • P3 (below threshold — no Routine)" },
    timestamp: new Date().toISOString(),
  };
}

function buildCapAlertEmbed(capCount, issueId, title, permalink) {
  return {
    title: "⚠️ Sentry Triage Daily Cap Reached",
    color: 0xff0000,
    description: `Daily Routine cap hit (${capCount}/15). Issue not triaged automatically.`,
    fields: [
      { name: "Missed Issue", value: `[${issueId}](${permalink}) — ${title}` },
    ],
    footer: { text: "EnviousWispr Sentry Triage • Check claude.ai/settings/usage" },
    timestamp: new Date().toISOString(),
  };
}

function buildFailureEmbed(issueId, title, permalink, priority, errMsg) {
  return {
    title: `[Sentry ${priority}] Routine fire failed`,
    color: 0xff0000,
    description: `Failed to fire Routine for [${issueId}](${permalink}). Manual triage required.`,
    fields: [
      { name: "Issue", value: title },
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
