// Observability/Harness Contract: exercise the authenticated worker entrypoint,
// fixed destinations, vendor independence and delivery commit behavior.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";
import { ENV, rig } from "../fixtures/sentry-writeup-fixture.js";

const MODE_ENV = { ...ENV, TRIGGER_SECRET: "fixture-secret", DISCORD_WEBHOOK_URL: "https://discord.invalid/mac", DISCORD_ANDROID_WEBHOOK_URL: "https://discord.invalid/android" };
const endpoint = (query, secret = "fixture-secret") => new Request("https://worker.invalid/?date=2026-10-07&" + query, { headers: { "x-trigger-secret": secret } });

async function withMode(overrides, action, env = MODE_ENV) {
  const data = rig(overrides);
  const deliveries = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (target, init) => {
    const url = String(target);
    if (url.startsWith("https://discord.invalid/")) {
      deliveries.push({ url, payload: JSON.parse(init.body) });
      return { status: overrides.discordStatus || 204 };
    }
    if (url.includes("posthog.com") || url.includes("appcast")) throw new Error("Sentry mode reached performance dependency");
    return data.opts.fetchFn(target, init);
  };
  try { return await action({ data, deliveries, env }); }
  finally { globalThis.fetch = original; }
}

test("unauthorized, unknown and empty modes/platforms make zero outbound calls", async () => {
  let count = 0;
  const original = globalThis.fetch; globalThis.fetch = async () => { count += 1; throw new Error("unexpected outbound call"); };
  try {
    for (const query of ["report=sentry&platform=mac", "report=performance"]) {
      assert.equal((await worker.fetch(endpoint(query, "wrong"), MODE_ENV)).status, 401);
    }
    for (const query of ["report=", "report=unknown", "report=sentry", "report=sentry&platform=", "report=sentry&platform=other", "report=performance&platform=mac"]) {
      assert.equal((await worker.fetch(endpoint(query), MODE_ENV)).status, 400);
    }
    assert.equal(count, 0);
  } finally { globalThis.fetch = original; }
});

test("Mac Sentry mode uses fixed project and channel without PostHog credentials", async () => {
  await withMode({}, async ({ data, deliveries, env }) => {
    const isolated = { ...env };
    Object.defineProperty(isolated, "POSTHOG_PERSONAL_API_KEY", { get() { throw new Error("Sentry read a PostHog credential"); } });
    Object.defineProperty(isolated, "APPCAST_URL", { get() { throw new Error("Sentry read performance release state"); } });
    const result = await worker.fetch(endpoint("report=sentry&platform=mac"), isolated);
    assert.equal(result.status, 200); assert.match(await result.text(), /Sentry morning review \| Mac \| 2026-10-07/);
    assert.equal(deliveries.length, 1); assert.equal(deliveries[0].url, MODE_ENV.DISCORD_WEBHOOK_URL);
    assert.equal(data.requests.length, 6);
    for (const url of data.requests.filter((u) => u.pathname.endsWith("/events/"))) assert.equal(url.searchParams.get("project"), "4511097112428544");
    assert.equal(data.requests.some((u) => u.pathname === "/api/0/projects/envious-labs-llc/enviouswispr/issues/"), true);
    assert.match(deliveries[0].payload.embeds[0].description, /5 events \(\+3 vs prior day\)/);
  });
});

test("Android overrides stale Mac project bindings and delivers only to Android", async () => {
  await withMode({}, async ({ data, deliveries, env }) => {
    const result = await worker.fetch(endpoint("report=sentry&platform=android"), env);
    assert.equal(result.status, 200); assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].url, MODE_ENV.DISCORD_ANDROID_WEBHOOK_URL);
    assert.match(deliveries[0].payload.content, /Android/);
    for (const url of data.requests.filter((u) => u.pathname.endsWith("/events/"))) assert.equal(url.searchParams.get("project"), "4512117176795136");
    assert.equal(data.requests.some((u) => u.pathname === "/api/0/projects/envious-labs-llc/enviouswispr-android/issues/"), true);
  });
});

test("missing Android destination refuses before any query without Mac fallback", async () => {
  const env = { ...MODE_ENV }; delete env.DISCORD_ANDROID_WEBHOOK_URL;
  await withMode({}, async ({ data, deliveries }) => {
    const result = await worker.fetch(endpoint("report=sentry&platform=android"), env);
    assert.equal(result.status, 500); assert.match(await result.text(), /Android report destination/);
    assert.equal(data.requests.length, 0); assert.equal(deliveries.length, 0);
  });
});

test("Sentry query failure emits one unavailable report and a failed status", async () => {
  await withMode({ currentStatus: 401 }, async ({ deliveries, env }) => {
    const result = await worker.fetch(endpoint("report=sentry&platform=mac"), env);
    assert.equal(result.status, 500); assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].payload.embeds[0].title, "Crash/error reporting unavailable today");
    assert.match(deliveries[0].payload.embeds[0].description, /not a report of zero/);
  });
});

test("delivery rejection has one attempted post and no misleading follow-up", async () => {
  await withMode({ discordStatus: 500 }, async ({ deliveries, env }) => {
    const result = await worker.fetch(endpoint("report=sentry&platform=mac"), env);
    assert.equal(result.status, 500); assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].payload.embeds[0].title, "Recorded crashes and errors");
  });
});

test("bad backfill dates refuse before vendor work", async () => {
  await withMode({}, async ({ data, deliveries, env }) => {
    const req = new Request("https://worker.invalid/?report=sentry&platform=mac&date=2026-02-30", { headers: { "x-trigger-secret": "fixture-secret" } });
    const result = await worker.fetch(req, env);
    assert.equal(result.status, 500); assert.equal(data.requests.length, 0); assert.equal(deliveries.length, 0);
  });
});

test("morning modes have no vendor needs dependency or sibling cancellation", () => {
  const source = readFileSync(new URL("../../../.github/workflows/daily-report-ping.yml", import.meta.url), "utf8");
  assert.match(source, /report=performance/); assert.match(source, /report=sentry&platform=/);
  assert.match(source, /platform: \[mac, android\]/); assert.match(source, /fail-fast: false/);
  assert.doesNotMatch(source, /^\s+needs:/m); assert.match(source, /cancel-in-progress: false/);
  assert.doesNotMatch(source, /curl[^\n]*--retry/);
});
