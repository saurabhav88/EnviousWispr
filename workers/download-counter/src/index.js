/**
 * EnviousWispr Download-Notification Counter (#1691)
 *
 * Replaces a brittle Hog-script live PostHog query (which shared PostHog's
 * project-wide 3-concurrent-query ceiling and intermittently rendered
 * "Download #?!" in Discord) with an owned, always-fast counter. PostHog's
 * CDP destination becomes a thin relay: it POSTs the event's fields here,
 * and this Worker owns counting, IP-based rage-click dedup, retry-safe
 * Discord delivery, and message formatting.
 *
 * Plan (design rationale, five grounded-review rounds, all findings):
 * docs/feature-requests/issue-1691-2026-07-19-download-counter-worker.md
 *
 * The counter, IP-dedup markers, and per-event Discord-delivery state all
 * live in one singleton Durable Object (`DownloadCounter`, instance name
 * always "global" for production traffic — never taken from the request).
 * A Durable Object was required, not Workers KV: KV enforces a 60s minimum
 * write TTL and 1 write/sec/key, both of which the counter's
 * read-increment-write pattern would violate under PostHog's own retry
 * bursts (grounded review round 1).
 */

const REQUIRED_EVENT_TYPES = ["download_clicked", "download_redirect"];
const MAX_EVENT_ID_LEN = 200;

const LEASE_MS = 15_000;
const DISCORD_ATTEMPT_TIMEOUT_MS = 4_000;
const MAX_RETRY_DELAY_MS = 2_000;
const DEDUP_WINDOW_MS = 30_000;

// Discord webhook `content` hard-fails with 400 above 2000 characters
// (discord-webhooks.md FACT: posting-contract). Every field folded into the
// message is forwarded, attacker-influenceable request data (referrer, page,
// source), so both a length cap and disabling mention parsing are required —
// not just a formatting nicety. Without a cap, an oversized field would
// permanently mark a real download's delivery "failed" (never retried) even
// though the counter had already advanced; without allowed_mentions, a
// crafted "@everyone" in a referrer would actually ping the channel.
const DISCORD_CONTENT_MAX_LEN = 2000;

// Discord responses indicating the webhook URL/token itself is wrong, stale,
// or revoked (a config problem, recoverable by fixing the secret) rather than
// a defect in this specific event's content (which would never resolve on
// retry). See postToDiscord's classification.
const WEBHOOK_CONFIG_ERROR_STATUSES = new Set([401, 403, 404]);

// Delivery records are retained (not pruned after minutes) specifically to
// preserve retry-safety — see the design note at their write site. But
// "retained" must not mean "forever, unbounded": 90 days is far longer than
// any realistic PostHog retry/replay window (observed retries resolve in
// seconds), so pruning past it is pure storage hygiene, not a replay-safety
// change. A small opportunistic, bounded sweep (not a scheduled job — none
// is needed at real volume, ~1-5 downloads/day) keeps the singleton
// Durable Object's storage from growing without bound over years.
const DELIVERY_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
const PRUNE_SAMPLE_SIZE = 50;
const PRUNE_PROBABILITY = 0.02;

// seen:<hmac> markers are functionally useless after DEDUP_WINDOW_MS (30s) —
// the dedup check already ignores an expired one via the timestamp compare —
// but nothing previously deleted the key itself, so it persisted forever.
// 5 minutes gives generous headroom past the functional window before actual
// deletion (deleting exactly at 30s would work too; the margin is just
// slack, not a correctness requirement).
const IP_MARKER_RETENTION_MS = 5 * 60 * 1000;

// Exported for direct unit testing — the real call site is probability-gated
// (PRUNE_PROBABILITY), so a behavioral test through handleCount would be
// flaky without this.
export async function pruneOldDeliveryRecords(storage, now) {
  const entries = await storage.list({ prefix: "delivery:", limit: PRUNE_SAMPLE_SIZE });
  const staleKeys = [];
  for (const [key, value] of entries) {
    if (value && typeof value.createdAt === "number" && now - value.createdAt > DELIVERY_RETENTION_MS) {
      staleKeys.push(key);
    }
  }
  if (staleKeys.length > 0) {
    await storage.delete(staleKeys);
  }
}

// Exported for direct unit testing, same reasoning as pruneOldDeliveryRecords.
export async function pruneStaleIpMarkers(storage, now) {
  const entries = await storage.list({ prefix: "seen:", limit: PRUNE_SAMPLE_SIZE });
  const staleKeys = [];
  for (const [key, value] of entries) {
    if (typeof value === "number" && now - value > IP_MARKER_RETENTION_MS) {
      staleKeys.push(key);
    }
  }
  if (staleKeys.length > 0) {
    await storage.delete(staleKeys);
  }
}

// Off-site source_bucket -> human label, ported verbatim from the live Hog
// script (pulled via the PostHog API, 2026-07-19) so the Discord message text
// is byte-identical after the cutover.
const SOURCE_LABELS = {
  github_readme: "the GitHub README",
  github_release: "GitHub",
  blog: "the blog",
  directory_alternativeto: "AlternativeTo",
  directory_macupdate: "MacUpdate",
  directory_other: "a directory listing",
  linkedin: "LinkedIn",
  reddit: "Reddit",
  x: "X",
  youtube: "YouTube",
  medium: "Medium",
  facebook: "Facebook",
  hackernews: "Hacker News",
  producthunt: "Product Hunt",
  discord: "Discord",
  ai_assistant: "an AI assistant (ChatGPT/Claude/etc.)",
  newsletter: "a newsletter",
  direct_or_dark: "a direct or untracked link",
  unknown_referrer: "an unrecognized site",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname !== "/count" && url.pathname !== "/seed") {
      return new Response("not found\n", { status: 404 });
    }
    if (request.method !== "POST") {
      return new Response("method not allowed\n", { status: 405, headers: { Allow: "POST" } });
    }

    const provided = request.headers.get("x-trigger-secret");
    if (!env.TRIGGER_SECRET || provided !== env.TRIGGER_SECRET) {
      return new Response("unauthorized\n", { status: 401 });
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return Response.json({ error: "invalid_json" }, { status: 400 });
    }

    if (url.pathname === "/seed") {
      if (!Number.isInteger(payload.total) || payload.total < 0) {
        return Response.json({ error: "invalid_total" }, { status: 400 });
      }
    } else {
      if (!REQUIRED_EVENT_TYPES.includes(payload.event)) {
        return Response.json({ error: "invalid_event" }, { status: 400 });
      }
      if (
        typeof payload.eventId !== "string" ||
        payload.eventId.length === 0 ||
        payload.eventId.length > MAX_EVENT_ID_LEN
      ) {
        return Response.json({ error: "invalid_event_id" }, { status: 400 });
      }
    }

    // Durable Object instance is always "global" — never taken from the
    // request. Isolation for the smoke-test script comes from a separate
    // Wrangler environment (its own Worker deployment + DO namespace), not
    // from a caller-supplied instance name (grounded review round 4 rejected
    // an earlier design that accepted one here as a production trust-boundary
    // risk).
    const id = env.DOWNLOAD_COUNTER.idFromName("global");
    const stub = env.DOWNLOAD_COUNTER.get(id);
    return stub.fetch(`https://download-counter${url.pathname}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  },
};

export class DownloadCounter {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const payload = await request.json();

    if (url.pathname === "/seed") {
      return this.handleSeed(payload);
    }
    return this.handleCount(payload);
  }

  async handleSeed(payload) {
    const storage = this.ctx.storage;
    // Same reasoning as handleCount: the check-then-write must be one
    // indivisible step, or two overlapping /seed calls (or a /seed racing
    // the very first real /count) could both observe "uninitialized" and
    // both write, silently corrupting the one-time bootstrap contract.
    return this.ctx.blockConcurrencyWhile(async () => {
      const existingCounter = await storage.get("counter");
      const existingDeliveries = await storage.list({ prefix: "delivery:", limit: 1 });
      if (existingCounter !== undefined || existingDeliveries.size > 0) {
        return Response.json({ error: "already_seeded" }, { status: 409 });
      }
      await storage.put("counter", payload.total);
      return Response.json({ total: payload.total });
    });
  }

  async handleCount(payload) {
    const {
      eventId,
      event,
      ip,
      excludedReason,
      city,
      country,
      countryCode,
      referrer,
      page,
      browser,
      os,
      lang,
      sourceBucket,
    } = payload;

    // Qualification (#1243's definition, preserved exactly): on-site always
    // qualifies; off-site qualifies only when not bot-excluded. excludedReason
    // is never applied to download_clicked.
    const qualifies =
      event === "download_clicked" ||
      (event === "download_redirect" && (excludedReason == null || excludedReason === ""));
    if (!qualifies) {
      return Response.json({ counted: false, reason: "excluded" });
    }

    const storage = this.ctx.storage;
    const deliveryKey = `delivery:${eventId}`;

    // The read (does this event/IP already have state?), the decision (is it
    // excluded/duplicate/already-resolved?), and the reservation write must
    // all happen as one indivisible step. A Durable Object's storage.put is
    // atomic, but storage.get + a decision + a later storage.put is NOT —
    // Durable Objects are single-threaded but can still interleave two
    // DIFFERENT requests across `await` points (confirmed: Cloudflare's own
    // docs state "multiple request events may still be processed
    // out-of-order"). Without blockConcurrencyWhile, two genuinely different
    // new events overlapping here could both read the same stale counter and
    // both reserve the same total, and two events sharing an IP could both
    // pass the dedup check before either had written its `seen:` marker.
    // blockConcurrencyWhile defers every OTHER request to this Durable Object
    // instance until this callback resolves; the (potentially slow) Discord
    // POST below stays outside it on purpose, since overlapping requests
    // there are expected and already handled by the posting lease.
    const decision = await this.ctx.blockConcurrencyWhile(async () => {
      const now = Date.now();
      let record = await storage.get(deliveryKey);

      if (record) {
        if (record.status === "delivered") {
          return {
            respond: Response.json({ counted: true, total: record.total, reason: "already-delivered" }),
          };
        }
        if (record.status === "failed") {
          return {
            respond: Response.json({ counted: true, total: record.total, reason: "discord-rejected" }),
          };
        }
        // status === "pending": either a legitimate retry to resume, or a
        // genuinely concurrent overlapping request for the same event (a
        // Durable Object yields control on `await fetch()`, so two requests
        // for the same eventId can interleave around the Discord call).
        if (record.leaseUntil > now) {
          return { respond: new Response(null, { status: 503, headers: { "Retry-After": "2" } }) };
        }
        record = { ...record, leaseUntil: now + LEASE_MS };
        await storage.put(deliveryKey, record);
        return { record };
      }

      // Genuinely new event.
      let ipHmac = null;
      if (ip) {
        ipHmac = await hmacIp(ip, this.env.IP_HASH_SECRET);
        const seenAt = await storage.get(`seen:${ipHmac}`);
        if (seenAt !== undefined && now - seenAt < DEDUP_WINDOW_MS) {
          return { respond: Response.json({ counted: false, reason: "duplicate" }) };
        }
      }
      const storedCounter = (await storage.get("counter")) ?? 0;
      const total = storedCounter + 1;
      const newRecord = { status: "pending", total, leaseUntil: now + LEASE_MS, createdAt: now };
      const batch = { counter: total, [deliveryKey]: newRecord };
      if (ipHmac) batch[`seen:${ipHmac}`] = now;
      // Atomic: counter, seen marker, and delivery record commit together or
      // not at all — the counter is never persisted separately from its
      // reservation.
      await storage.put(batch);
      if (Math.random() < PRUNE_PROBABILITY) {
        await pruneOldDeliveryRecords(storage, now);
        await pruneStaleIpMarkers(storage, now);
      }
      return { record: newRecord };
    });

    if (decision.respond) {
      return decision.respond;
    }
    const record = decision.record;

    let content = formatMessage({
      total: record.total,
      isOffsite: event === "download_redirect",
      city,
      country,
      countryCode,
      referrer,
      page,
      browser,
      os,
      lang,
      sourceBucket,
    });
    // The smoke environment shares the production Discord webhook (README) so
    // it can prove a real post lands; every post it makes must be visually
    // unmistakable from a real download in the shared channel.
    if (this.env.SMOKE === "true") {
      content = `🧪 SMOKE TEST — ignore\n${content}`;
    }

    const result = await postToDiscord(this.env.DISCORD_WEBHOOK_URL, content, {
      timeoutMs: DISCORD_ATTEMPT_TIMEOUT_MS,
      maxRetryDelayMs: MAX_RETRY_DELAY_MS,
    });

    if (result.outcome === "delivered") {
      await storage.put(deliveryKey, { ...record, status: "delivered" });
      return Response.json({ counted: true, total: record.total });
    }

    if (result.outcome === "rejected") {
      await storage.put(deliveryKey, { ...record, status: "failed", failedStatus: result.status });
      console.error(
        `download-counter: Discord permanently rejected post (status ${result.status}) for eventId=${eventId}, total=${record.total}`,
      );
      return Response.json({ counted: true, total: record.total, reason: "discord-rejected" });
    }

    // Exhausted network/429/5xx retries. Clear the lease immediately (rather
    // than leaving it to expire naturally) so PostHog's own next retry can
    // reacquire it right away instead of waiting out the rest of LEASE_MS.
    await storage.put(deliveryKey, { ...record, leaseUntil: 0 });
    return new Response(null, { status: 502 });
  }
}

async function hmacIp(ip, secret) {
  if (!secret) {
    throw new Error("IP_HASH_SECRET is not configured");
  }
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(ip));
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function formatMessage({ total, isOffsite, city, country, countryCode, referrer, page, browser, os, lang, sourceBucket }) {
  const resolvedCountry = country || "Unknown location";
  const location = city ? `${city}, ${resolvedCountry}` : resolvedCountry;
  const flag = countryCode ? `:flag_${countryCode.toLowerCase()}: ` : "";
  const referrerValue = referrer && referrer !== "$direct" ? referrer : "Direct visit";

  if (isOffsite) {
    const sourceLabel = SOURCE_LABELS[sourceBucket] ?? "an off-site link";
    return (
      `:tada: **Download #${total}!** Someone just grabbed EnviousWispr\n` +
      `> ${flag}**Location:** ${location}\n` +
      `> **Source:** ${sourceLabel}\n` +
      `> **Referred by:** ${referrerValue}`
    );
  }

  const resolvedOs = os || "Unknown";
  const resolvedBrowser = browser || "Unknown";
  const resolvedPage = page || "/";
  let content =
    `:tada: **Download #${total}!** Someone just grabbed EnviousWispr\n` +
    `> ${flag}**Location:** ${location}\n` +
    `> **Platform:** ${resolvedOs} / ${resolvedBrowser}\n` +
    `> **Referred by:** ${referrerValue}\n` +
    `> **Page:** ${resolvedPage}`;
  if (lang) {
    content += `\n> **Language:** ${lang}`;
  }
  return content;
}

function truncateForDiscord(content) {
  if (content.length <= DISCORD_CONTENT_MAX_LEN) {
    return content;
  }
  const suffix = "\n> …(truncated)";
  return content.slice(0, DISCORD_CONTENT_MAX_LEN - suffix.length) + suffix;
}

async function postToDiscord(webhookUrl, content, { timeoutMs, maxRetryDelayMs }) {
  const safeContent = truncateForDiscord(content);
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(webhookUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: safeContent, allowed_mentions: { parse: [] } }),
        signal: controller.signal,
      });
      clearTimeout(timer);

      if (res.status === 200 || res.status === 204) {
        return { outcome: "delivered" };
      }
      // 401/403/404 mean the webhook URL/token itself is wrong, stale, or
      // revoked — a config problem, not a defect in THIS event's content.
      // Retrying the same request won't help immediately, but the config can
      // be fixed later, and a permanently-"failed" delivery record would
      // never resume even after that fix. Treat these as retryable (same
      // outcome as an exhausted network/5xx attempt) rather than a permanent
      // per-event rejection.
      if (WEBHOOK_CONFIG_ERROR_STATUSES.has(res.status)) {
        return { outcome: "exhausted" };
      }
      if (res.status !== 429 && res.status < 500) {
        return { outcome: "rejected", status: res.status };
      }
      if (attempt === 2) {
        return { outcome: "exhausted" };
      }
      const retryAfterHeader = res.headers.get("Retry-After");
      const retryAfterMs = retryAfterHeader ? Number(retryAfterHeader) * 1000 : maxRetryDelayMs;
      await sleep(Math.min(Math.max(retryAfterMs, 0), maxRetryDelayMs));
    } catch {
      clearTimeout(timer);
      if (attempt === 2) {
        return { outcome: "exhausted" };
      }
      await sleep(maxRetryDelayMs);
    }
  }
  return { outcome: "exhausted" };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
