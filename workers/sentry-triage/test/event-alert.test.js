// The alert-rule ACTION payload (#2486). Sentry stopped firing the implicit
// `issue.created` webhook on 2026-08-16; alerting was rewired onto a workflow
// action, and an action sends a DIFFERENT payload — `data.event` with `issue_id`,
// not `data.issue`.
//
// Measured before these tests existed: the Worker answered 202 and dropped it with
// "No data.issue". Sentry's request log said delivered, the save button said saved,
// and no card reached Discord. Every assertion here is about that gap.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleTriage } from "../src/index.js";

function fakeKV(seed = {}) {
  const store = new Map(Object.entries(seed));
  return {
    store,
    async get(key) { return store.get(key) ?? null; },
    async put(key, value) { store.set(key, value); },
    async delete(key) { store.delete(key); },
  };
}

const ISSUE = {
  id: "7647106942",
  shortId: "ENVIOUSWISPR-4M",
  title: "polish_provider_failed: EnviousWisprLLM.LLMError#11",
  permalink: "https://envious-labs-llc.sentry.io/issues/7647106942/",
  count: "27",
  userCount: 2,
  level: "error",
  substatus: "ongoing",
};

// The real shape, trimmed to the fields this path reads. `issue_id`, no `id`.
function eventAlertBody() {
  return JSON.stringify({
    action: "triggered",
    data: {
      event: { event_id: "abc", issue_id: "7647106942", title: ISSUE.title },
      triggered_rule: "New Issue Detected",
    },
  });
}

function harness({ issueLookup = () => ok(ISSUE), discordStatus = 204 } = {}) {
  const realFetch = globalThis.fetch;
  const requests = [];
  const embeds = [];
  globalThis.fetch = async (url, init) => {
    const target = String(url);
    requests.push(target);
    if (/\/issues\/\d+\/$/.test(target)) return issueLookup(target);
    if (target.includes("/events/")) return ok([]); // degraded partition: fail-open path
    if (target.startsWith("https://api.github.com")) return ok([]);
    if (target.startsWith("https://discord.test")) {
      embeds.push(JSON.parse(init.body).embeds[0]);
      return { ok: discordStatus >= 200 && discordStatus < 300, status: discordStatus };
    }
    throw new Error(`unexpected fetch to ${target}`);
  };
  const env = {
    SENTRY_DEDUP: fakeKV(),
    SENTRY_AUTH_TOKEN: "token",
    GITHUB_ISSUES_READ_TOKEN: "gh",
    GITHUB_REPO: "saurabhav88/EnviousWispr",
    DISCORD_WEBHOOK_URL: "https://discord.test/hook",
  };
  return { env, requests, embeds, restore: () => (globalThis.fetch = realFetch) };
}

function ok(json) {
  return { ok: true, status: 200, async json() { return json; }, headers: { get: () => null } };
}

test("event_alert.triggered resolves the issue by id and POSTS a card", async () => {
  const h = harness();
  try {
    await handleTriage(eventAlertBody(), h.env);
  } finally {
    h.restore();
  }
  assert.ok(
    h.requests.some((u) => u.includes("/issues/7647106942/")),
    "the issue must be fetched by id; the action payload does not carry one"
  );
  assert.equal(h.embeds.length, 1, "this is the whole point: a card reaches Discord");
  assert.match(h.embeds[0].title, /ENVIOUSWISPR-4M|polish_provider_failed/);
});

test("event_alert.triggered is DROPPED loudly when the issue cannot be resolved", async () => {
  const h = harness({ issueLookup: () => ({ ok: false, status: 404 }) });
  try {
    await handleTriage(eventAlertBody(), h.env);
  } finally {
    h.restore();
  }
  assert.equal(h.embeds.length, 0, "never post a card built from blanks");
});

test("a payload with neither data.issue nor an event issue_id still skips", async () => {
  const h = harness();
  try {
    await handleTriage(JSON.stringify({ action: "triggered", data: {} }), h.env);
  } finally {
    h.restore();
  }
  assert.equal(h.embeds.length, 0);
  assert.equal(h.requests.length, 0, "nothing to look up means no subrequest spent");
});
