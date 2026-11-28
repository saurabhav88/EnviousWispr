// Observability/Harness Contract: exercise the authenticated worker entrypoint,
// fixed destinations, vendor independence and delivery commit behavior.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";
import { ENV, rig } from "../fixtures/sentry-writeup-fixture.js";

const MODE_ENV = { ...ENV, TRIGGER_SECRET: "fixture-secret", DISCORD_WEBHOOK_URL: "https://discord.invalid/mac", DISCORD_ANDROID_WEBHOOK_URL: "https://discord.invalid/android", DISCORD_WINDOWS_WEBHOOK_URL: "https://discord.invalid/windows" };
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

test("Windows overrides stale Mac project bindings and delivers only to Windows without PostHog credentials", async () => {
  await withMode({}, async ({ data, deliveries, env }) => {
    const isolated = { ...env };
    Object.defineProperty(isolated, "POSTHOG_PERSONAL_API_KEY", { get() { throw new Error("Sentry read a PostHog credential"); } });
    Object.defineProperty(isolated, "APPCAST_URL", { get() { throw new Error("Sentry read performance release state"); } });
    const result = await worker.fetch(endpoint("report=sentry&platform=windows"), isolated);
    assert.equal(result.status, 200); assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].url, MODE_ENV.DISCORD_WINDOWS_WEBHOOK_URL);
    assert.match(deliveries[0].payload.content, /Sentry morning review \| Windows \| 2026-10-07/);
    for (const url of data.requests.filter((u) => u.pathname.endsWith("/events/"))) assert.equal(url.searchParams.get("project"), "4512506748010496");
    assert.equal(data.requests.some((u) => u.pathname === "/api/0/projects/envious-labs-llc/enviouswispr-windows/issues/"), true);
  });
});

test("missing Windows destination refuses before any query without Mac fallback", async () => {
  const env = { ...MODE_ENV }; delete env.DISCORD_WINDOWS_WEBHOOK_URL;
  await withMode({}, async ({ data, deliveries }) => {
    const result = await worker.fetch(endpoint("report=sentry&platform=windows"), env);
    assert.equal(result.status, 500); assert.match(await result.text(), /Windows report destination/);
    assert.equal(data.requests.length, 0); assert.equal(deliveries.length, 0);
  });
});

test("empty Windows project renders a valid zero report distinctly from unavailable", async () => {
  await withMode({ current: [], prior: [], matrix: [], currentHead: [], priorHead: [], firstSeen: [] }, async ({ deliveries, env }) => {
    const result = await worker.fetch(endpoint("report=sentry&platform=windows"), env);
    assert.equal(result.status, 200); assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].url, MODE_ENV.DISCORD_WINDOWS_WEBHOOK_URL);
    assert.equal(deliveries[0].payload.embeds[0].title, "Recorded crashes and errors");
    assert.match(deliveries[0].payload.embeds[0].description, /No crash\/error events received\./);
    assert.doesNotMatch(deliveries[0].payload.embeds[0].description, /unavailable today/i);
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

test("delivery transport exceptions never leak webhook URL or token in the worker response", async () => {
  const secretToken = "SECRET_WEBHOOK_TOKEN_987654321";
  const secretUrl = "https://discord.invalid/api/webhooks/1576039882214871070/" + secretToken;
  const env = { ...MODE_ENV, DISCORD_WINDOWS_WEBHOOK_URL: secretUrl };
  const data = rig();
  const original = globalThis.fetch;
  let capturedInit = null;
  globalThis.fetch = async (target, init) => {
    if (String(target) === secretUrl) {
      capturedInit = init;
      throw new TypeError("fetch failed for " + secretUrl);
    }
    return data.opts.fetchFn(target, init);
  };
  try {
    const result = await worker.fetch(endpoint("report=sentry&platform=windows"), env);
    assert.equal(result.status, 500);
    const body = await result.text();
    assert.equal(capturedInit?.redirect, "manual");
    assert.doesNotMatch(body, /SECRET_WEBHOOK_TOKEN_987654321/);
    assert.doesNotMatch(body, /discord\.invalid/);
    assert.match(body, /Discord delivery failed: transport error/);
  } finally {
    globalThis.fetch = original;
  }
});

test("discord delivery rejects 3xx redirects under manual redirect mode without leaking webhook", async () => {
  const secretUrl = "https://discord.invalid/api/webhooks/1576039882214871070/SECRET_REDIRECT_TOKEN_12345";
  const env = { ...MODE_ENV, DISCORD_WINDOWS_WEBHOOK_URL: secretUrl };
  const data = rig();
  const original = globalThis.fetch;
  let capturedInit = null;
  let discordCalls = 0;
  globalThis.fetch = async (target, init) => {
    if (String(target) === secretUrl) {
      discordCalls += 1;
      capturedInit = init;
      return new Response("", { status: 302, headers: { Location: "https://evil.invalid/steal" } });
    }
    return data.opts.fetchFn(target, init);
  };
  try {
    const result = await worker.fetch(endpoint("report=sentry&platform=windows"), env);
    assert.equal(result.status, 500);
    const body = await result.text();
    assert.equal(discordCalls, 1);
    assert.equal(capturedInit?.redirect, "manual");
    assert.doesNotMatch(body, /SECRET_REDIRECT_TOKEN_12345/);
    assert.doesNotMatch(body, /evil\.invalid/);
    assert.match(body, /Discord rejected the report: HTTP 302/);
  } finally {
    globalThis.fetch = original;
  }
});

test("morning modes derive exact target routing, guard date globbing, and avoid sibling cancellation", () => {
  const source = readFileSync(new URL("../../../.github/workflows/daily-report-ping.yml", import.meta.url), "utf8");
  assert.match(source, /report=performance/); assert.match(source, /report=sentry&platform=/);
  assert.match(source, /fail-fast: false/); assert.match(source, /cancel-in-progress: false/);
  assert.doesNotMatch(source, /^\s+needs:/m); assert.doesNotMatch(source, /curl[^\n]*--retry/);

  // Both curl invocations disable globbing and enforce YYYY-MM-DD before invoking curl.
  const globoffMatches = source.match(/curl[^\n]*--globoff/g) || [];
  assert.equal(globoffMatches.length, 2);
  const dateGuards = source.match(/\^\[0-9\]\{4\}-\[0-9\]\{2\}-\[0-9\]\{2\}\$/g) || [];
  assert.equal(dateGuards.length, 2);
  assert.equal(/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test("2026-10-[07-09]"), false);
  assert.equal(/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test("2026-10-07"), true);

  // Extract and evaluate the ACTUAL workflow job conditions and matrix expression for all six choices.
  const pingIfMatch = source.match(/\n  ping:\n    if:\s*\$\{\{\s*([^\n]+?)\s*\}\}/);
  const sentryIfMatch = source.match(/\n  sentry:\n    if:\s*\$\{\{\s*([^\n]+?)\s*\}\}/);
  const matrixExprMatch = source.match(/platform:\s*\$\{\{\s*fromJSON\(([^\n]+)\)\s*\}\}/);
  assert.ok(pingIfMatch, "ping job must gate on inputs.target");
  assert.ok(sentryIfMatch, "sentry job must gate on inputs.target");
  assert.ok(matrixExprMatch, "sentry matrix must derive platform list from inputs.target");
  const evalGhaExpr = (expr, target) => {
    // Only allow safe GitHub Actions boolean/comparison/string expressions over inputs.target.
    assert.match(expr, /^[a-zA-Z0-9_.\s'"=&|!\[\],-]+$/);
    const fn = new Function("inputs", "return (" + expr + ");");
    return fn({ target });
  };
  const evalWorkflowFor = (target) => {
    const runsPerformance = Boolean(evalGhaExpr(pingIfMatch[1], target));
    const runsSentry = Boolean(evalGhaExpr(sentryIfMatch[1], target));
    const sentryPlatforms = runsSentry ? JSON.parse(evalGhaExpr(matrixExprMatch[1], target)) : [];
    return { runsPerformance, sentryPlatforms };
  };
  assert.deepEqual(evalWorkflowFor("sentry-windows"), { runsPerformance: false, sentryPlatforms: ["windows"] });
  assert.deepEqual(evalWorkflowFor("sentry-mac"), { runsPerformance: false, sentryPlatforms: ["mac"] });
  assert.deepEqual(evalWorkflowFor("sentry-android"), { runsPerformance: false, sentryPlatforms: ["android"] });
  assert.deepEqual(evalWorkflowFor("all-sentry"), { runsPerformance: false, sentryPlatforms: ["mac", "android", "windows"] });
  assert.deepEqual(evalWorkflowFor("performance"), { runsPerformance: true, sentryPlatforms: [] });
  assert.deepEqual(evalWorkflowFor("all"), { runsPerformance: true, sentryPlatforms: ["mac", "android", "windows"] });
});
