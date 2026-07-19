import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { DownloadCounter } from "../src/index.js";

class FakeStorage {
  constructor() {
    this.map = new Map();
  }
  async get(key) {
    return this.map.get(key);
  }
  async put(keyOrEntries, maybeValue) {
    if (typeof keyOrEntries === "string") {
      this.map.set(keyOrEntries, maybeValue);
      return;
    }
    for (const [k, v] of Object.entries(keyOrEntries)) {
      this.map.set(k, v);
    }
  }
  async list({ prefix, limit } = {}) {
    const result = new Map();
    for (const [k, v] of this.map.entries()) {
      if (prefix && !k.startsWith(prefix)) continue;
      result.set(k, v);
      if (limit && result.size >= limit) break;
    }
    return result;
  }
}

function makeCounter(env = {}) {
  const storage = new FakeStorage();
  // Sufficient for sequential tests: no other request is ever actually
  // in flight, so a pass-through is equivalent to the real serialized
  // behavior. The dedicated concurrency test below uses a genuinely
  // serializing implementation instead.
  const ctx = { storage, blockConcurrencyWhile: (fn) => fn() };
  const counter = new DownloadCounter(ctx, {
    DISCORD_WEBHOOK_URL: "https://discord.com/api/webhooks/test",
    IP_HASH_SECRET: "test-secret",
    ...env,
  });
  return { counter, storage };
}

function makeSerializingCounter(env = {}) {
  const storage = new FakeStorage();
  let chain = Promise.resolve();
  const ctx = {
    storage,
    blockConcurrencyWhile(fn) {
      const result = chain.then(() => fn());
      chain = result.then(
        () => {},
        () => {},
      );
      return result;
    },
  };
  const counter = new DownloadCounter(ctx, {
    DISCORD_WEBHOOK_URL: "https://discord.com/api/webhooks/test",
    IP_HASH_SECRET: "test-secret",
    ...env,
  });
  return { counter, storage };
}

function countRequest(body) {
  return new Request("https://do/count", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function seedRequest(total) {
  return new Request("https://do/seed", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ total }),
  });
}

function mockFetch(responder) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return responder(calls.length);
  };
  return {
    calls,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function onSiteEvent(overrides = {}) {
  return {
    eventId: "evt-1",
    event: "download_clicked",
    ip: "1.2.3.4",
    city: "Springfield",
    country: "United States",
    countryCode: "US",
    referrer: "https://google.com",
    page: "/",
    browser: "Chrome",
    os: "Mac OS X",
    lang: "en-US",
    ...overrides,
  };
}

test("on-site download_clicked always qualifies, even with excludedReason set", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const res = await counter.fetch(countRequest(onSiteEvent({ excludedReason: "bot" })));
    const body = await res.json();
    assert.equal(body.counted, true);
    assert.equal(body.total, 1);
  } finally {
    mock.restore();
  }
});

test("off-site download_redirect with non-empty excludedReason is excluded", async () => {
  const { counter, storage } = makeCounter();
  const res = await counter.fetch(
    countRequest({ eventId: "evt-2", event: "download_redirect", excludedReason: "bot", ip: "5.6.7.8" }),
  );
  const body = await res.json();
  assert.deepEqual(body, { counted: false, reason: "excluded" });
  assert.equal(storage.map.get("counter"), undefined);
});

test("off-site download_redirect with empty excludedReason qualifies", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 200 }));
  try {
    const res = await counter.fetch(
      countRequest({
        eventId: "evt-3",
        event: "download_redirect",
        excludedReason: "",
        ip: "5.6.7.8",
        sourceBucket: "reddit",
        country: "Canada",
        referrer: "https://reddit.com/r/foo",
      }),
    );
    const body = await res.json();
    assert.equal(body.counted, true);
    assert.equal(body.total, 1);
  } finally {
    mock.restore();
  }
});

test("new event increments counter atomically and posts to Discord", async () => {
  const { counter, storage } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const res = await counter.fetch(countRequest(onSiteEvent()));
    const body = await res.json();
    assert.equal(body.total, 1);
    assert.equal(storage.map.get("counter"), 1);
    assert.equal(storage.map.get("delivery:evt-1").status, "delivered");
    assert.equal(mock.calls.length, 1);
  } finally {
    mock.restore();
  }
});

test("retry of a delivered eventId returns the stored total without re-posting", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent()));
    const res = await counter.fetch(countRequest(onSiteEvent()));
    const body = await res.json();
    assert.deepEqual(body, { counted: true, total: 1, reason: "already-delivered" });
    assert.equal(mock.calls.length, 1, "must not re-post a delivered event");
  } finally {
    mock.restore();
  }
});

test("retry of a failed (permanent 4xx) eventId returns discord-rejected without re-posting", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 400 }));
  try {
    const first = await counter.fetch(countRequest(onSiteEvent()));
    assert.equal((await first.json()).reason, "discord-rejected");
    const second = await counter.fetch(countRequest(onSiteEvent()));
    const body = await second.json();
    assert.deepEqual(body, { counted: true, total: 1, reason: "discord-rejected" });
    assert.equal(mock.calls.length, 1, "a permanent rejection must never be retried");
  } finally {
    mock.restore();
  }
});

test("a webhook config error (401/403/404) is treated as retryable, never marked permanently failed", async () => {
  for (const status of [401, 403, 404]) {
    const { counter, storage } = makeCounter();
    const mock = mockFetch(() => new Response(null, { status }));
    try {
      const res = await counter.fetch(countRequest(onSiteEvent()));
      assert.equal(res.status, 502, `status ${status} should return 502 (retryable), not a terminal 200`);
      const record = storage.map.get("delivery:evt-1");
      assert.equal(record.status, "pending", `status ${status} must stay pending, not become "failed"`);
      assert.equal(record.leaseUntil, 0);
    } finally {
      mock.restore();
    }
  }
});

test("once a webhook config error clears (e.g. secret fixed), a resumed retry can still deliver", async () => {
  const { counter, storage } = makeCounter();
  let attempt = 0;
  const mock = mockFetch(() => {
    attempt += 1;
    return new Response(null, { status: attempt === 1 ? 401 : 204 });
  });
  try {
    const first = await counter.fetch(countRequest(onSiteEvent()));
    assert.equal(first.status, 502);
    const second = await counter.fetch(countRequest(onSiteEvent()));
    const body = await second.json();
    assert.equal(body.counted, true);
    assert.equal(body.total, 1, "must resume with the original total, not re-increment");
    assert.equal(storage.map.get("delivery:evt-1").status, "delivered");
  } finally {
    mock.restore();
  }
});

test("a genuinely concurrent request for the same eventId gets 503 while the lease is held", async () => {
  const { counter, storage } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent()));
    // Force the record back into "pending" with a live lease, simulating an
    // in-flight overlapping request.
    await storage.put("delivery:evt-1", { status: "pending", total: 1, leaseUntil: Date.now() + 10_000 });
    const res = await counter.fetch(countRequest(onSiteEvent()));
    assert.equal(res.status, 503);
  } finally {
    mock.restore();
  }
});

test("an expired lease on a pending record resumes using the stored total, not a new increment", async () => {
  const { counter, storage } = makeCounter();
  await storage.put("counter", 5);
  await storage.put("delivery:evt-1", { status: "pending", total: 6, leaseUntil: Date.now() - 1_000, createdAt: Date.now() });
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const res = await counter.fetch(countRequest(onSiteEvent()));
    const body = await res.json();
    assert.equal(body.total, 6, "must reuse the reserved total, not increment again");
    assert.equal(storage.map.get("counter"), 5, "counter must not be touched on a resumed retry");
  } finally {
    mock.restore();
  }
});

test("exhausted retries clear the lease to 0 and return 502", async () => {
  const { counter, storage } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 500 }));
  try {
    const res = await counter.fetch(countRequest(onSiteEvent()));
    assert.equal(res.status, 502);
    const record = storage.map.get("delivery:evt-1");
    assert.equal(record.status, "pending");
    assert.equal(record.leaseUntil, 0);
    assert.equal(mock.calls.length, 2, "must attempt exactly 2 Discord posts on repeated 5xx");
  } finally {
    mock.restore();
  }
});

test("a cleared lease lets the very next retry take over immediately", async () => {
  const { counter, storage } = makeCounter();
  let attempt = 0;
  const mock = mockFetch(() => {
    attempt += 1;
    return new Response(null, { status: attempt <= 2 ? 500 : 204 });
  });
  try {
    const first = await counter.fetch(countRequest(onSiteEvent()));
    assert.equal(first.status, 502);
    assert.equal(storage.map.get("delivery:evt-1").leaseUntil, 0);

    const second = await counter.fetch(countRequest(onSiteEvent()));
    const body = await second.json();
    assert.equal(body.counted, true);
    assert.equal(body.total, 1, "resumed retry must reuse the original reserved total");
    assert.equal(storage.map.get("counter"), 1, "counter must never be incremented twice for one event");
  } finally {
    mock.restore();
  }
});

test("same IP within the dedup window suppresses a second distinct event, does not reserve a total", async () => {
  const { counter, storage } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent({ eventId: "evt-a", ip: "9.9.9.9" })));
    const res = await counter.fetch(countRequest(onSiteEvent({ eventId: "evt-b", ip: "9.9.9.9" })));
    const body = await res.json();
    assert.deepEqual(body, { counted: false, reason: "duplicate" });
    assert.equal(storage.map.get("counter"), 1, "the duplicate must not reserve a second total");
    assert.equal(storage.map.get("delivery:evt-b"), undefined);
  } finally {
    mock.restore();
  }
});

test("a different IP is never suppressed by another visitor's dedup marker", async () => {
  const { counter, storage } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent({ eventId: "evt-a", ip: "1.1.1.1" })));
    const res = await counter.fetch(countRequest(onSiteEvent({ eventId: "evt-b", ip: "2.2.2.2" })));
    const body = await res.json();
    assert.equal(body.counted, true);
    assert.equal(storage.map.get("counter"), 2);
  } finally {
    mock.restore();
  }
});

test("a missing IP skips dedup entirely and never collides with another missing-IP event", async () => {
  const { counter, storage } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent({ eventId: "evt-a", ip: "" })));
    const res = await counter.fetch(countRequest(onSiteEvent({ eventId: "evt-b", ip: "" })));
    const body = await res.json();
    assert.equal(body.counted, true, "a second missing-IP event must count normally, not collide");
    assert.equal(storage.map.get("counter"), 2);
    for (const key of storage.map.keys()) {
      assert.ok(!key.startsWith("seen:"), "no seen:* key may be written for a missing IP");
    }
  } finally {
    mock.restore();
  }
});

test("on-site message format matches the live Hog script's template", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent()));
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.equal(
      sent,
      ":tada: **Download #1!** Someone just grabbed EnviousWispr\n" +
        "> :flag_us: **Location:** Springfield, United States\n" +
        "> **Platform:** Mac OS X / Chrome\n" +
        "> **Referred by:** https://google.com\n" +
        "> **Page:** /\n" +
        "> **Language:** en-US",
    );
  } finally {
    mock.restore();
  }
});

test("on-site message omits the Language line when lang is absent", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent({ lang: "" })));
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.ok(!sent.includes("Language"));
  } finally {
    mock.restore();
  }
});

test("off-site message uses the Source label and omits Platform/Page/Language", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(
      countRequest({
        eventId: "evt-off",
        event: "download_redirect",
        excludedReason: "",
        ip: "8.8.8.8",
        country: "Germany",
        sourceBucket: "reddit",
        referrer: "$direct",
      }),
    );
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.equal(
      sent,
      ":tada: **Download #1!** Someone just grabbed EnviousWispr\n" +
        "> **Location:** Germany\n" +
        "> **Source:** Reddit\n" +
        "> **Referred by:** Direct visit",
    );
  } finally {
    mock.restore();
  }
});

test("an unrecognized sourceBucket falls back to a generic off-site label", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(
      countRequest({
        eventId: "evt-unk",
        event: "download_redirect",
        excludedReason: "",
        ip: "8.8.8.9",
        country: "France",
        sourceBucket: "totally_unknown",
      }),
    );
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.ok(sent.includes("an off-site link"));
  } finally {
    mock.restore();
  }
});

test("two genuinely concurrent DIFFERENT new events never reserve the same total", async () => {
  const { counter } = makeSerializingCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const [resA, resB] = await Promise.all([
      counter.fetch(countRequest(onSiteEvent({ eventId: "evt-race-a", ip: "10.0.0.1" }))),
      counter.fetch(countRequest(onSiteEvent({ eventId: "evt-race-b", ip: "10.0.0.2" }))),
    ]);
    const totalA = (await resA.json()).total;
    const totalB = (await resB.json()).total;
    assert.notEqual(totalA, totalB, "two different concurrent events must never reserve the same total");
    assert.deepEqual([totalA, totalB].sort(), [1, 2]);
  } finally {
    mock.restore();
  }
});

test("two genuinely concurrent events sharing an IP: exactly one is counted, never both", async () => {
  const { counter } = makeSerializingCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const [resA, resB] = await Promise.all([
      counter.fetch(countRequest(onSiteEvent({ eventId: "evt-race-c", ip: "10.0.0.9" }))),
      counter.fetch(countRequest(onSiteEvent({ eventId: "evt-race-d", ip: "10.0.0.9" }))),
    ]);
    const bodies = [await resA.json(), await resB.json()];
    const countedTrue = bodies.filter((b) => b.counted === true);
    const duplicates = bodies.filter((b) => b.reason === "duplicate");
    assert.equal(countedTrue.length, 1, "exactly one of the two concurrent same-IP events must count");
    assert.equal(duplicates.length, 1, "the other must be suppressed as a duplicate, not silently double-counted");
  } finally {
    mock.restore();
  }
});

test("an oversized Discord message is truncated to Discord's 2000-char limit, not rejected", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const res = await counter.fetch(countRequest(onSiteEvent({ referrer: "https://example.com/?x=" + "a".repeat(3000) })));
    const body = await res.json();
    assert.equal(body.counted, true);
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.ok(sent.length <= 2000, `expected <=2000 chars, got ${sent.length}`);
  } finally {
    mock.restore();
  }
});

test("Discord posts disable mention parsing so attacker-controlled fields can never ping the channel", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent({ referrer: "https://evil.example/?x=@everyone" })));
    const sentBody = JSON.parse(mock.calls[0].init.body);
    assert.deepEqual(sentBody.allowed_mentions, { parse: [] });
  } finally {
    mock.restore();
  }
});

test("SMOKE env prefixes the Discord message so a test post is never mistaken for a real download", async () => {
  const { counter } = makeCounter({ SMOKE: "true" });
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent()));
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.ok(sent.startsWith("🧪 SMOKE TEST — ignore\n"));
  } finally {
    mock.restore();
  }
});

test("without SMOKE set, the message carries no test marker", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent()));
    const sent = JSON.parse(mock.calls[0].init.body).content;
    assert.ok(!sent.includes("SMOKE TEST"));
  } finally {
    mock.restore();
  }
});

test("/seed succeeds once on a cold counter, then refuses with 409", async () => {
  const { counter, storage } = makeCounter();
  const first = await counter.fetch(seedRequest(756));
  assert.equal(first.status, 200);
  assert.equal(storage.map.get("counter"), 756);

  const second = await counter.fetch(seedRequest(1));
  assert.equal(second.status, 409);
  assert.equal(storage.map.get("counter"), 756, "a rejected reseed must never overwrite the real counter");
});

test("/seed refuses once real traffic has already created delivery records", async () => {
  const { counter } = makeCounter();
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    await counter.fetch(countRequest(onSiteEvent()));
    const seeded = await counter.fetch(seedRequest(999));
    assert.equal(seeded.status, 409);
  } finally {
    mock.restore();
  }
});

test("a seeded counter's next new event increments from the seeded value", async () => {
  const { counter, storage } = makeCounter();
  await counter.fetch(seedRequest(756));
  const mock = mockFetch(() => new Response(null, { status: 204 }));
  try {
    const res = await counter.fetch(countRequest(onSiteEvent()));
    const body = await res.json();
    assert.equal(body.total, 757);
    assert.equal(storage.map.get("counter"), 757);
  } finally {
    mock.restore();
  }
});

function fakeDoNamespace(counter) {
  return {
    idFromName: () => "global",
    get: () => ({ fetch: (url, init) => counter.fetch(new Request(url, init)) }),
  };
}

test("Worker: missing/wrong x-trigger-secret is rejected before the Durable Object is touched", async () => {
  const { counter } = makeCounter();
  const env = { TRIGGER_SECRET: "correct-secret", DOWNLOAD_COUNTER: fakeDoNamespace(counter) };
  const req = new Request("https://worker/count", {
    method: "POST",
    headers: { "x-trigger-secret": "wrong", "Content-Type": "application/json" },
    body: JSON.stringify(onSiteEvent()),
  });
  const res = await worker.fetch(req, env);
  assert.equal(res.status, 401);
});

test("Worker: an event outside the known two types is rejected with 400", async () => {
  const { counter } = makeCounter();
  const env = { TRIGGER_SECRET: "s", DOWNLOAD_COUNTER: fakeDoNamespace(counter) };
  const req = new Request("https://worker/count", {
    method: "POST",
    headers: { "x-trigger-secret": "s", "Content-Type": "application/json" },
    body: JSON.stringify(onSiteEvent({ event: "something_else" })),
  });
  const res = await worker.fetch(req, env);
  assert.equal(res.status, 400);
});

test("Worker: a missing, empty, or oversized eventId is rejected with 400 before storage is touched", async () => {
  const { counter, storage } = makeCounter();
  const env = { TRIGGER_SECRET: "s", DOWNLOAD_COUNTER: fakeDoNamespace(counter) };
  for (const badId of [undefined, "", "x".repeat(201)]) {
    const req = new Request("https://worker/count", {
      method: "POST",
      headers: { "x-trigger-secret": "s", "Content-Type": "application/json" },
      body: JSON.stringify(onSiteEvent({ eventId: badId })),
    });
    const res = await worker.fetch(req, env);
    assert.equal(res.status, 400, `expected 400 for eventId=${JSON.stringify(badId)}`);
  }
  assert.equal(storage.map.size, 0, "no storage write may happen for a rejected request");
});

test("Worker: an unknown route is 404, a non-POST method is 405", async () => {
  const { counter } = makeCounter();
  const env = { TRIGGER_SECRET: "s", DOWNLOAD_COUNTER: fakeDoNamespace(counter) };
  const notFound = await worker.fetch(new Request("https://worker/unknown", { method: "POST" }), env);
  assert.equal(notFound.status, 404);
  const wrongMethod = await worker.fetch(new Request("https://worker/count", { method: "GET" }), env);
  assert.equal(wrongMethod.status, 405);
});
