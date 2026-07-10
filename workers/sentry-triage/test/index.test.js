// Unit tests for the pure notification policy + embed logic (#1470, #1229). No network.
// Run: node --test  (from workers/sentry-triage/)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decideNotification,
  scoreFromEvents,
  normalizeRelease,
  classifySeverity,
  extractEventRecord,
  parseNextCursor,
  pageHasExactTicket,
  buildEmbedFromLookup,
  truncate,
  classifySource,
  readableHeadline,
  metadataFields,
  buildEnrichedEmbed,
  buildFailOpenEmbed,
} from "../src/index.js";

const NOW = 1_800_000_000_000;

// Already-extracted event record (what scoreFromEvents / buildEmbedFromLookup consume).
function rec(overrides = {}) {
  return {
    release: "com.enviouswispr.app@2.3.1",
    environment: "production",
    buildType: "release",
    level: "error",
    userId: "u1",
    category: null,
    stage: null,
    osVersion: null,
    deviceModel: null,
    ...overrides,
  };
}

// N distinct-user production events on one release.
function prodEvents(release, n) {
  return Array.from({ length: n }, (_, i) => rec({ release, userId: `u${i}` }));
}

// ─────────────────────────────── decideNotification ───────────────────────────

test("decideNotification: fatal, no open ticket, complete lookups -> post P0, throttleHours 0", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "fatal", userCount: "1", count: "1" },
    eventLookup: { status: "complete", events: prodEvents("com.enviouswispr.app@2.3.1", 1) },
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: { status: "complete", value: null },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.priority, "P0");
  assert.equal(r.throttleHours, 0);
  assert.equal(r.countSource, "events");
});

test("decideNotification: paste_failed shape (already ticketed, 18 users newest release) -> suppress", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "18", count: "335" },
    eventLookup: { status: "complete", events: prodEvents("com.enviouswispr.app@2.3.1", 18) },
    ticketLookup: { status: "complete", openExactMarker: true },
    throttleLookup: { status: "complete", value: null },
    now: NOW,
  });
  assert.equal(r.post, false);
  assert.equal(r.reason, "already-ticketed");
  assert.equal(r.priority, "P0"); // 18 users still scores P0, but rule 5 suppresses
});

test("decideNotification: incomplete events -> post with webhook-fallback display priority", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "2", count: "5" },
    eventLookup: { status: "incomplete" },
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: { status: "complete", value: null },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.priority, "P2");
  assert.equal(r.countSource, "webhook-fallback");
});

test("decideNotification: unconfirmed ticket lookup (unavailable) -> post (fail-open)", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "1", count: "1" },
    eventLookup: { status: "unavailable" },
    ticketLookup: { status: "unavailable" },
    throttleLookup: { status: "complete", value: null },
    now: NOW,
  });
  assert.equal(r.post, true);
});

test("decideNotification: throttle read failure -> post (fail-open)", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "1", count: "1" },
    eventLookup: { status: "unavailable" },
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: { status: "unavailable" },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.reason, "throttle-unavailable-failopen");
});

test("decideNotification: active same-priority P2 throttle with action:created -> suppress", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "2", count: "5" },
    eventLookup: { status: "unavailable" }, // webhook fallback -> P2
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: {
      status: "complete",
      value: { lastNotifiedAt: NOW - 60_000, priority: "P2" },
    },
    now: NOW,
  });
  assert.equal(r.priority, "P2");
  assert.equal(r.post, false);
  assert.equal(r.reason, "throttled");
});

test("decideNotification: P0 bypasses an active stored P2 throttle -> post P0, throttleHours 0", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "fatal", userCount: "1", count: "1" },
    eventLookup: { status: "complete", events: prodEvents("com.enviouswispr.app@2.3.1", 1) },
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: {
      status: "complete",
      value: { lastNotifiedAt: NOW - 60_000, priority: "P2" },
    },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.priority, "P0");
  assert.equal(r.throttleHours, 0);
});

test("decideNotification: non-P0 escalation (P1) bypasses an active stored P2 throttle", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "3", count: "3" },
    eventLookup: { status: "complete", events: prodEvents("com.enviouswispr.app@2.3.1", 3) },
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: {
      status: "complete",
      value: { lastNotifiedAt: NOW - 60_000, priority: "P2" },
    },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.priority, "P1");
  assert.equal(r.reason, "priority-escalation-bypass");
});

test("decideNotification: regression (unresolved + substatus regressed) bypasses an active same-priority throttle", () => {
  const r = decideNotification({
    action: "unresolved",
    issue: { level: "error", userCount: "2", count: "5", substatus: "regressed" },
    eventLookup: { status: "unavailable" }, // webhook fallback -> P2
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: {
      status: "complete",
      value: { lastNotifiedAt: NOW - 60_000, priority: "P2" },
    },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.reason, "regression-bypass");
});

test("decideNotification: bare unresolved (not regressed) still respects an active throttle", () => {
  // A manual reopen/unmute, same priority, within the window -> suppressed, so a
  // flapping resolved/unresolved state cannot re-buzz. Only substatus:regressed bypasses.
  const r = decideNotification({
    action: "unresolved",
    issue: { level: "error", userCount: "2", count: "5", substatus: "ongoing" },
    eventLookup: { status: "unavailable" }, // webhook fallback -> P2
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: {
      status: "complete",
      value: { lastNotifiedAt: NOW - 60_000, priority: "P2" },
    },
    now: NOW,
  });
  assert.equal(r.post, false);
  assert.equal(r.reason, "throttled");
});

test("decideNotification: unsupported action -> suppress", () => {
  const r = decideNotification({
    action: "assigned",
    issue: { level: "error", userCount: "5", count: "50" },
    eventLookup: { status: "unavailable" },
    ticketLookup: { status: "unavailable" },
    throttleLookup: { status: "complete", value: null },
    now: NOW,
  });
  assert.equal(r.post, false);
  assert.equal(r.reason, "ineligible");
});

test("decideNotification: non-error level -> suppress", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "warning", userCount: "5", count: "50" },
    eventLookup: { status: "unavailable" },
    ticketLookup: { status: "unavailable" },
    throttleLookup: { status: "complete", value: null },
    now: NOW,
  });
  assert.equal(r.post, false);
  assert.equal(r.reason, "ineligible");
});

test("decideNotification: expired same-priority throttle -> post", () => {
  const r = decideNotification({
    action: "created",
    issue: { level: "error", userCount: "2", count: "5" },
    eventLookup: { status: "unavailable" }, // webhook fallback -> P2 (24h window)
    ticketLookup: { status: "complete", openExactMarker: false },
    throttleLookup: {
      status: "complete",
      value: { lastNotifiedAt: NOW - 25 * 3600_000, priority: "P2" },
    },
    now: NOW,
  });
  assert.equal(r.post, true);
  assert.equal(r.reason, "throttle-expired");
});

// ─────────────────────────────── scoreFromEvents ──────────────────────────────

test("scoreFromEvents: scores the newest production release only", () => {
  const events = [
    ...prodEvents("com.enviouswispr.app@2.3.0", 5),
    ...prodEvents("com.enviouswispr.app@2.3.1", 2),
  ];
  const scored = scoreFromEvents({ status: "complete", events });
  assert.equal(scored.occurrences, 2); // 2.3.1 partition, not the 5-user 2.3.0
  assert.equal(scored.users, 2);
});

test("scoreFromEvents: excludes development/debug events", () => {
  const events = [
    rec({ environment: "development", userId: "d1" }),
    rec({ buildType: "debug", userId: "d2" }),
    ...prodEvents("com.enviouswispr.app@2.3.1", 3),
  ];
  const scored = scoreFromEvents({ status: "complete", events });
  assert.equal(scored.users, 3);
  assert.equal(scored.occurrences, 3);
});

test("scoreFromEvents: no production partition -> null (routes to fallback)", () => {
  const events = [rec({ environment: "development" }), rec({ buildType: "debug" })];
  assert.equal(scoreFromEvents({ status: "complete", events }), null);
});

test("scoreFromEvents: no parseable release -> null", () => {
  const events = [rec({ release: "nightly" }), rec({ release: null })];
  assert.equal(scoreFromEvents({ status: "complete", events }), null);
});

test("scoreFromEvents: production event missing buildType is not trusted as release -> null", () => {
  // app.build_type absent (older version / untagged process): don't silently score it.
  const events = [rec({ environment: "production", buildType: null })];
  assert.equal(scoreFromEvents({ status: "complete", events }), null);
});

test("scoreFromEvents: non-complete status -> null", () => {
  assert.equal(scoreFromEvents({ status: "incomplete" }), null);
  assert.equal(scoreFromEvents({ status: "unavailable" }), null);
  assert.equal(scoreFromEvents(null), null);
});

test("scoreFromEvents: dedupes known ids but counts each anonymous event as its own user", () => {
  // Safe over-count (ports tik_eligibility.py _distinct_users): known {u1,u2}=2
  // plus 2 anonymous events (null, "") = 4, so a P0 is never hidden by missing ids.
  const events = [
    rec({ userId: "u1" }),
    rec({ userId: "u1" }),
    rec({ userId: null }),
    rec({ userId: "" }),
    rec({ userId: "u2" }),
  ];
  const scored = scoreFromEvents({ status: "complete", events });
  assert.equal(scored.occurrences, 5);
  assert.equal(scored.users, 4);
});

test("scoreFromEvents: 10 anonymous production occurrences score P0-eligible (users=10)", () => {
  const events = Array.from({ length: 10 }, () => rec({ userId: null }));
  const scored = scoreFromEvents({ status: "complete", events });
  assert.equal(scored.users, 10);
  assert.equal(classifySeverity(scored.users, scored.occurrences, "error"), "P0");
});

// ─────────────────────────────── normalizeRelease ─────────────────────────────

test("normalizeRelease: parses bundle@semver and bare semver", () => {
  assert.deepEqual(normalizeRelease("com.enviouswispr.app@2.3.1").tuple, [2, 3, 1]);
  assert.deepEqual(normalizeRelease("2.3.1").tuple, [2, 3, 1]);
  assert.deepEqual(normalizeRelease("2.3.1+build47").tuple, [2, 3, 1]);
  assert.deepEqual(normalizeRelease("2.3.1-beta").tuple, [2, 3, 1]);
});

test("normalizeRelease: junk / non-string -> null", () => {
  assert.equal(normalizeRelease("nightly"), null);
  assert.equal(normalizeRelease("2.3"), null);
  assert.equal(normalizeRelease(null), null);
  assert.equal(normalizeRelease(undefined), null);
});

// ─────────────────────────────── classifySeverity ─────────────────────────────

test("classifySeverity: threshold ladder", () => {
  assert.equal(classifySeverity(0, 0, "fatal"), "P0");
  assert.equal(classifySeverity(10, 0, "error"), "P0");
  assert.equal(classifySeverity(3, 0, "error"), "P1");
  assert.equal(classifySeverity(0, 20, "error"), "P1");
  assert.equal(classifySeverity(2, 0, "error"), "P2");
  assert.equal(classifySeverity(0, 5, "error"), "P2");
  assert.equal(classifySeverity(1, 1, "error"), "P3");
});

// ─────────────────────────────── extractEventRecord ───────────────────────────

function rawEvent(tags = {}, extra = {}) {
  return {
    tags: Object.entries(tags).map(([key, value]) => ({ key, value })),
    ...extra,
  };
}

test("extractEventRecord: reads release/env/buildType/level/category/stage from tags", () => {
  const r = extractEventRecord(
    rawEvent(
      {
        release: "com.enviouswispr.app@2.3.1",
        environment: "production",
        "app.build_type": "release",
        level: "error",
        "error.category": "paste_failed",
        "pipeline.stage": "paste",
      },
      { user: { id: "user-42" }, contexts: { os: { version: "26.6.0" }, device: { model: "Mac16,8" } } }
    )
  );
  assert.equal(r.release, "com.enviouswispr.app@2.3.1");
  assert.equal(r.environment, "production");
  assert.equal(r.buildType, "release");
  assert.equal(r.level, "error");
  assert.equal(r.userId, "user-42");
  assert.equal(r.category, "paste_failed");
  assert.equal(r.stage, "paste");
  assert.equal(r.osVersion, "26.6.0");
  assert.equal(r.deviceModel, "Mac16,8");
});

test("extractEventRecord: missing tags/user/contexts yield null fields, never throws", () => {
  const r = extractEventRecord({});
  assert.equal(r.release, null);
  assert.equal(r.environment, null);
  assert.equal(r.buildType, null);
  assert.equal(r.userId, null);
  assert.equal(r.osVersion, null);
});

test("extractEventRecord: malformed event (null) yields all-null record", () => {
  const r = extractEventRecord(null);
  assert.equal(r.release, null);
  assert.equal(r.level, null);
});

// ─────────────────────────────── parseNextCursor ──────────────────────────────

test("parseNextCursor: returns next URL when results=true", () => {
  const link =
    '<https://us.sentry.io/api/0/x/?cursor=0:0:1>; rel="previous"; results="false"; cursor="0:0:1", ' +
    '<https://us.sentry.io/api/0/x/?cursor=0:100:0>; rel="next"; results="true"; cursor="0:100:0"';
  assert.equal(parseNextCursor(link), "https://us.sentry.io/api/0/x/?cursor=0:100:0");
});

test("parseNextCursor: null when next has results=false or header absent", () => {
  const link =
    '<https://us.sentry.io/api/0/x/?cursor=0:100:0>; rel="next"; results="false"; cursor="0:100:0"';
  assert.equal(parseNextCursor(link), null);
  assert.equal(parseNextCursor(null), null);
  assert.equal(parseNextCursor(""), null);
});

// ─────────────────────────────── pageHasExactTicket ───────────────────────────

const MARK = (id) => `<!-- sentry-issue-id: ${id} -->`;

test("pageHasExactTicket: exact marker on an issue counts", () => {
  const page = [{ body: `Tracking\n${MARK("ENVIOUSWISPR-F")}\ndetails` }];
  assert.equal(pageHasExactTicket(page, "ENVIOUSWISPR-F"), true);
});

test("pageHasExactTicket: a PR carrying the marker never counts", () => {
  const page = [{ body: `Fixes it\n${MARK("ENVIOUSWISPR-F")}`, pull_request: { url: "https://x" } }];
  assert.equal(pageHasExactTicket(page, "ENVIOUSWISPR-F"), false);
});

test("pageHasExactTicket: a fuzzy mention without the exact marker does not count", () => {
  const page = [{ body: "mentions ENVIOUSWISPR-F somewhere but no HTML marker" }];
  assert.equal(pageHasExactTicket(page, "ENVIOUSWISPR-F"), false);
});

test("pageHasExactTicket: skips the PR but still finds a real issue on the same page", () => {
  const page = [
    { body: MARK("ENVIOUSWISPR-F"), pull_request: {} },
    { body: `real ticket ${MARK("ENVIOUSWISPR-F")}` },
  ];
  assert.equal(pageHasExactTicket(page, "ENVIOUSWISPR-F"), true);
});

test("pageHasExactTicket: empty/missing bodies and non-array input are safe", () => {
  assert.equal(pageHasExactTicket([{ body: null }, {}], "ENVIOUSWISPR-F"), false);
  assert.equal(pageHasExactTicket(null, "ENVIOUSWISPR-F"), false);
});

// ─────────────────────────────── buildEmbedFromLookup ─────────────────────────

test("buildEmbedFromLookup: complete lookup -> enriched embed with source label", () => {
  const events = [
    rec({ environment: "production", buildType: "release", category: "paste_failed", stage: "paste", release: "com.enviouswispr.app@2.3.1" }),
  ];
  const embed = buildEmbedFromLookup(
    { status: "complete", events },
    { issueId: "123", title: "[REDACTED]", permalink: "https://x/123/", timesSeen: 5, userCount: 2, priority: "P2" }
  );
  assert.equal(embed.title, "[Sentry P2] paste_failed");
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "👤 Real user (release)");
});

test("buildEmbedFromLookup: degraded lookup -> fail-open embed", () => {
  const embed = buildEmbedFromLookup(
    { status: "unavailable" },
    { issueId: "123", title: "boom", permalink: "https://x/123/", timesSeen: 1, userCount: 1, priority: "P3" }
  );
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "❓ Unknown source (Sentry fetch failed)");
});

// ─────────────────────────────── existing embed helpers ───────────────────────

test("truncate: short passes through, long capped with ellipsis, non-string unchanged", () => {
  assert.equal(truncate("built_in_mic"), "built_in_mic");
  const out = truncate("a".repeat(250));
  assert.equal(out.length, 200);
  assert.ok(out.endsWith("…"));
  assert.equal(truncate(42), 42);
  assert.equal(truncate(null), null);
});

test("classifySource: dev/debug -> test build, prod+release -> real user, else unknown", () => {
  assert.equal(classifySource({ environment: "development", buildType: "release" }), "🧪 Your test build (dev/debug)");
  assert.equal(classifySource({ environment: null, buildType: "debug" }), "🧪 Your test build (dev/debug)");
  assert.equal(classifySource({ environment: "production", buildType: "release" }), "👤 Real user (release)");
  assert.equal(classifySource({ environment: "production", buildType: null }), "❓ Unknown source (metadata missing)");
  assert.equal(classifySource({}), "❓ Unknown source (metadata missing)");
  assert.equal(classifySource(undefined), "❓ Unknown source (metadata missing)");
});

test("readableHeadline: prefers category, falls back to title", () => {
  assert.equal(readableHeadline("[REDACTED]", { category: "paste_failed" }), "paste_failed");
  assert.equal(readableHeadline("readable", {}), "readable");
});

test("metadataFields: joins category/stage and os/device, falls back to unknown", () => {
  const a = metadataFields({ category: "paste_failed", stage: "paste", osVersion: "26.6.0", deviceModel: "Mac16,8" });
  assert.equal(a.what, "paste_failed / paste");
  assert.equal(a.system, "macOS 26.6.0, Mac16,8");
  const b = metadataFields({});
  assert.equal(b.what, "unknown");
  assert.equal(b.system, "unknown");
});

test("buildEnrichedEmbed: readable headline, real-user source, no em/en dash", () => {
  const embed = buildEnrichedEmbed({
    issueId: "456",
    title: "[REDACTED]",
    permalink: "https://x/456/",
    timesSeen: 1,
    userCount: 1,
    priority: "P2",
    metadata: { category: "paste_failed", environment: "production", buildType: "release", release: "com.enviouswispr.app@2.3.1" },
  });
  assert.equal(embed.title, "[Sentry P2] paste_failed");
  assert.ok(!embed.title.includes("REDACTED"));
  const text = JSON.stringify(embed);
  assert.ok(!text.includes("—"), "no em-dash");
  assert.ok(!text.includes("–"), "no en-dash");
});

test("buildFailOpenEmbed: unknown source + details-unavailable note", () => {
  const embed = buildFailOpenEmbed({ issueId: "789", title: "t", permalink: "https://x/789/", timesSeen: 2, userCount: 1, priority: "P3" });
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "❓ Unknown source (Sentry fetch failed)");
  const details = embed.fields.find((f) => f.name === "Details");
  assert.match(details.value, /unavailable/i);
});
