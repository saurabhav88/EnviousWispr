// Unit tests for the pure source-enrichment logic (#1229). No network.
// Run: node --test  (from workers/sentry-triage/)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  truncate,
  extractMetadata,
  classifySource,
  readableHeadline,
  metadataFields,
  buildEnrichedEmbed,
  buildFailOpenEmbed,
  buildCapAlertEmbed,
  buildFailureEmbed,
} from "../src/index.js";

function event(tags = {}, contexts = {}) {
  return {
    tags: Object.entries(tags).map(([key, value]) => ({ key, value })),
    contexts,
  };
}

// ---- extractMetadata ----
test("extractMetadata: reads category/stage/environment/buildType/release from tags[]", () => {
  const e = event({
    "error.category": "recovery_transcribe_failed",
    "pipeline.stage": "recovery",
    environment: "development",
    "app.build_type": "debug",
    release: "com.enviouswispr.app@2.2.0",
  });
  const m = extractMetadata(e);
  assert.equal(m.category, "recovery_transcribe_failed");
  assert.equal(m.stage, "recovery");
  assert.equal(m.environment, "development");
  assert.equal(m.buildType, "debug");
  assert.equal(m.release, "com.enviouswispr.app@2.2.0");
});

test("extractMetadata: reads osVersion/deviceModel from contexts, not tags", () => {
  const e = event({}, { os: { version: "26.6.0" }, device: { model: "Mac16,8" } });
  const m = extractMetadata(e);
  assert.equal(m.osVersion, "26.6.0");
  assert.equal(m.deviceModel, "Mac16,8");
});

test("extractMetadata: missing tags/contexts yield null fields, never throws", () => {
  const m = extractMetadata({});
  assert.equal(m.category, null);
  assert.equal(m.osVersion, null);
  assert.equal(m.deviceModel, null);
});

test("extractMetadata: malformed event (null) yields all-null metadata", () => {
  const m = extractMetadata(null);
  assert.equal(m.category, null);
  assert.equal(m.environment, null);
});

// ---- classifySource ----
test("classifySource: environment=development -> test build", () => {
  assert.equal(
    classifySource({ environment: "development", buildType: "release" }),
    "🧪 Your test build (dev/debug)"
  );
});

test("classifySource: buildType=debug -> test build, even with unknown environment", () => {
  assert.equal(classifySource({ environment: null, buildType: "debug" }), "🧪 Your test build (dev/debug)");
});

test("classifySource: environment=production AND buildType=release -> real user", () => {
  assert.equal(
    classifySource({ environment: "production", buildType: "release" }),
    "👤 Real user (release)"
  );
});

test("classifySource: production environment but missing buildType -> unknown, never defaults to real user", () => {
  assert.equal(
    classifySource({ environment: "production", buildType: null }),
    "❓ Unknown source (metadata missing)"
  );
});

test("classifySource: release buildType but missing environment -> unknown", () => {
  assert.equal(
    classifySource({ environment: null, buildType: "release" }),
    "❓ Unknown source (metadata missing)"
  );
});

test("classifySource: all metadata missing -> unknown", () => {
  assert.equal(classifySource({}), "❓ Unknown source (metadata missing)");
  assert.equal(classifySource(undefined), "❓ Unknown source (metadata missing)");
});

// ---- truncate ----
test("truncate: short string passes through unchanged", () => {
  assert.equal(truncate("built_in_mic"), "built_in_mic");
});

test("truncate: long string is capped with an ellipsis", () => {
  const long = "a".repeat(250);
  const out = truncate(long);
  assert.equal(out.length, 200);
  assert.ok(out.endsWith("…"));
});

test("truncate: non-string values pass through unchanged", () => {
  assert.equal(truncate(42), 42);
  assert.equal(truncate(null), null);
});

// ---- readableHeadline ----
test("readableHeadline: prefers error.category over title", () => {
  assert.equal(
    readableHeadline("[REDACTED]", { category: "recovery_transcribe_failed" }),
    "recovery_transcribe_failed"
  );
});

test("readableHeadline: falls back to title when category is missing", () => {
  assert.equal(readableHeadline("some readable title", {}), "some readable title");
});

// ---- metadataFields ----
test("metadataFields: joins category + stage for What, OS + device for System", () => {
  const { what, system } = metadataFields({
    category: "recovery_transcribe_failed",
    stage: "recovery",
    osVersion: "26.6.0",
    deviceModel: "Mac16,8",
  });
  assert.equal(what, "recovery_transcribe_failed / recovery");
  assert.equal(system, "macOS 26.6.0, Mac16,8");
});

test("metadataFields: falls back to 'unknown' when both parts are missing", () => {
  const { what, system } = metadataFields({});
  assert.equal(what, "unknown");
  assert.equal(system, "unknown");
});

// ---- buildEnrichedEmbed ----
test("buildEnrichedEmbed: dev metadata renders a readable headline + test-build source", () => {
  const embed = buildEnrichedEmbed({
    issueId: "123",
    title: "[REDACTED]",
    permalink: "https://envious-labs-llc.sentry.io/issues/123/",
    timesSeen: 5,
    userCount: 1,
    priority: "P3",
    metadata: {
      category: "recovery_transcribe_failed",
      stage: "recovery",
      environment: "development",
      buildType: "debug",
      release: "com.enviouswispr.app@2.2.0",
      osVersion: "26.6.0",
      deviceModel: "Mac16,8",
    },
  });
  assert.equal(embed.title, "[Sentry P3] recovery_transcribe_failed");
  assert.ok(!embed.title.includes("REDACTED"));
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "🧪 Your test build (dev/debug)");
  const sentry = embed.fields.find((f) => f.name === "Sentry");
  assert.match(sentry.value, /123/);
});

test("buildEnrichedEmbed: real-user metadata renders the real-user source label", () => {
  const embed = buildEnrichedEmbed({
    issueId: "456",
    title: "fallback title",
    permalink: "https://example.com/456/",
    timesSeen: 1,
    userCount: 1,
    priority: "P2",
    metadata: { environment: "production", buildType: "release" },
  });
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "👤 Real user (release)");
});

test("buildEnrichedEmbed: no em-dash or en-dash anywhere in the rendered embed", () => {
  const embed = buildEnrichedEmbed({
    issueId: "1",
    title: "t",
    permalink: "https://example.com/1/",
    timesSeen: 1,
    userCount: 1,
    priority: "P3",
    metadata: {},
  });
  const text = JSON.stringify(embed);
  assert.ok(!text.includes("—"), "no em-dash");
  assert.ok(!text.includes("–"), "no en-dash");
});

// ---- buildFailOpenEmbed ----
test("buildFailOpenEmbed: always shows unknown source + details-unavailable note", () => {
  const embed = buildFailOpenEmbed({
    issueId: "789",
    title: "[REDACTED]",
    permalink: "https://example.com/789/",
    timesSeen: 2,
    userCount: 1,
    priority: "P3",
  });
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "❓ Unknown source (Sentry fetch failed)");
  const details = embed.fields.find((f) => f.name === "Details");
  assert.match(details.value, /unavailable/i);
});

// ---- buildCapAlertEmbed / buildFailureEmbed: source field present, fail-open default ----
test("buildCapAlertEmbed: includes the Source field when a label is provided", () => {
  const embed = buildCapAlertEmbed(13, "999", "some title", "https://example.com/999/", "👤 Real user (release)");
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "👤 Real user (release)");
});

test("buildCapAlertEmbed: falls open to unknown source when sourceLabel is null", () => {
  const embed = buildCapAlertEmbed(13, "999", "some title", "https://example.com/999/", null);
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "❓ Unknown source (Sentry fetch failed)");
});

test("buildFailureEmbed: includes the Source field and falls open when sourceLabel is null", () => {
  const embed = buildFailureEmbed("1", "title", "https://example.com/1/", "P1", "boom", null);
  const source = embed.fields.find((f) => f.name === "Source");
  assert.equal(source.value, "❓ Unknown source (Sentry fetch failed)");
});
