// POST /api/feedback: the website contact form. A fake fetch stands in for
// Resend; nothing here calls the network. Run: `npm run test:functions`.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import { onRequestOptions, onRequestPost } from "./api/feedback.js";

const realFetch = globalThis.fetch;
const realError = console.error;
afterEach(() => {
  globalThis.fetch = realFetch;
  console.error = realError;
});

const SITE = "https://enviouswispr.com";
const env = { RESEND_API_KEY: "test-key", TURNSTILE_SECRET_KEY: "ts-secret" };

function post(body, origin = SITE) {
  const headers = { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.9" };
  if (origin !== null) headers.Origin = origin;
  return new Request("https://enviouswispr.com/api/feedback", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const PASS = { success: true, hostname: "enviouswispr.com", action: "contact" };
const RESEND = "https://api.resend.com/emails";
const SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

// Fakes Resend and Siteverify. Returns the Resend calls; `verify` collects the
// Siteverify form fields. `siteverify` is a JSON verdict, an HTTP status, or a
// function that throws.
function fakeResend(status = 200, text = '{"id":"x"}', siteverify = PASS) {
  const calls = [];
  calls.verify = [];
  globalThis.fetch = async (url, init) => {
    if (url === SITEVERIFY) {
      calls.verify.push(Object.fromEntries(init.body.entries()));
      if (typeof siteverify === "function") return siteverify();
      if (typeof siteverify === "number") return new Response("", { status: siteverify });
      return Response.json(siteverify);
    }
    assert.equal(url, RESEND);
    calls.push({ url, body: JSON.parse(init.body) });
    return new Response(text, { status });
  };
  return calls;
}

const ok = { email: "reader@example.com", message: "The paste did not land.", turnstileToken: "tok-1" };

test("a valid form from the site sends one email and returns ok", async () => {
  const calls = fakeResend();
  const res = await onRequestPost({ request: post(ok), env });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls.verify, [{ secret: "ts-secret", response: "tok-1", remoteip: "203.0.113.9" }]);
  assert.equal(calls[0].body.reply_to, "reader@example.com");
  assert.equal(calls[0].body.subject, "Feedback from reader@example.com");
});

for (const origin of [null, "", "https://evil.example", "https://enviouswispr.com.evil.example", "http://localhost:43210"]) {
  test(`origin ${JSON.stringify(origin)} is refused before any email`, async () => {
    const calls = fakeResend();
    const res = await onRequestPost({ request: post(ok, origin), env });
    assert.equal(res.status, 403);
    assert.equal(calls.length, 0);
    assert.equal(calls.verify.length, 0);
  });
}

const badBodies = [
  ["not JSON", "{", 400],
  ["JSON null", "null", 400],
  ["missing email", { message: "hi" }, 400],
  ["blank message", { email: "a@b.co", message: "   " }, 400],
  ["email as an object", { email: { a: 1 }, message: "hi" }, 400],
  ["message as an array", { email: "a@b.co", message: ["x".repeat(6000)] }, 400],
  ["email with a newline", { email: "a@b.co\nBcc: c@d.co", message: "hi" }, 400],
  ["two addresses", { email: "a@b.co, c@d.co", message: "hi" }, 400],
  ["no domain dot", { email: "a@b", message: "hi" }, 400],
  ["email over 254", { email: `${"a".repeat(250)}@b.co`, message: "hi" }, 400],
  ["message over 5000", { email: "a@b.co", message: "x".repeat(5001) }, 400],
];
for (const [name, body, status] of badBodies) {
  test(`${name} is refused before any email`, async () => {
    const calls = fakeResend();
    const res = await onRequestPost({ request: post(body), env });
    assert.equal(res.status, status);
    assert.equal(calls.length, 0);
    assert.equal(calls.verify.length, 0, "a refused field must not spend the token");
    assert.equal(typeof (await res.json()).error, "string");
  });
}

test("a message of exactly 5000 characters sends", async () => {
  const calls = fakeResend();
  const res = await onRequestPost({ request: post({ ...ok, message: "x".repeat(5000) }), env });
  assert.equal(res.status, 200);
  assert.equal(calls.length, 1);
});

test("a Resend failure returns 502 without Resend's error text", async () => {
  fakeResend(422, '{"message":"secret-ish provider detail"}');
  const logged = [];
  console.error = (line) => logged.push(line);
  const res = await onRequestPost({ request: post(ok), env });
  assert.equal(res.status, 502);
  const text = await res.text();
  assert.deepEqual(JSON.parse(text), { error: "Failed to send" });
  assert.ok(!text.includes("provider detail"));
  assert.equal(logged.length, 1);
  assert.match(logged[0], /Resend 422 .*provider detail/);
});

test("preflight answers only the site's own origin", async () => {
  const pre = (origin) =>
    onRequestOptions({ request: new Request("https://enviouswispr.com/api/feedback", { method: "OPTIONS", headers: { Origin: origin } }) });
  const good = await pre(SITE);
  assert.equal(good.status, 200);
  assert.equal(good.headers.get("Access-Control-Allow-Origin"), SITE);
  const bad = await pre("https://evil.example");
  assert.equal(bad.status, 403);
  assert.equal(bad.headers.get("Access-Control-Allow-Origin"), null);
});

const refusedChecks = [
  ["no token", { ...ok, turnstileToken: undefined }, PASS, 403, 0],
  ["token as a number", { ...ok, turnstileToken: 7 }, PASS, 403, 0],
  ["token over 2048", { ...ok, turnstileToken: "t".repeat(2049) }, PASS, 403, 0],
  ["Turnstile says no", ok, { success: false, "error-codes": ["invalid-input-response"] }, 403, 1],
  ["a token from another site", ok, { ...PASS, hostname: "evil.example" }, 403, 1],
  ["a token from another form", ok, { ...PASS, action: "signup" }, 403, 1],
  ["success that is not exactly true", ok, { ...PASS, success: "true" }, 403, 1],
  ["Siteverify HTTP 500", ok, 500, 503, 1],
  ["Siteverify timeout", ok, () => { throw new DOMException("timed out", "TimeoutError"); }, 503, 1],
];
for (const [name, body, siteverify, status, verifies] of refusedChecks) {
  test(`${name}: refused with ${status} and no email`, async () => {
    const calls = fakeResend(200, "{}", siteverify);
    console.error = () => {};
    const res = await onRequestPost({ request: post(body), env });
    assert.equal(res.status, status);
    assert.equal(calls.length, 0);
    assert.equal(calls.verify.length, verifies);
    assert.equal(typeof (await res.json()).error, "string");
  });
}

test("a missing Turnstile secret refuses before any call", async () => {
  const calls = fakeResend();
  const res = await onRequestPost({ request: post(ok), env: { RESEND_API_KEY: "k" } });
  assert.equal(res.status, 500);
  assert.equal(calls.length + calls.verify.length, 0);
});

test("a localhost test-key token (other hostname, no action) passes locally only", async () => {
  const testKey = { success: true, hostname: "example.com", action: "" };
  let calls = fakeResend(200, '{"id":"x"}', testKey);
  assert.equal((await onRequestPost({ request: post(ok, "http://localhost:4321"), env })).status, 200);
  assert.equal(calls.length, 1);
  calls = fakeResend(200, '{"id":"x"}', testKey);
  assert.equal((await onRequestPost({ request: post(ok), env })).status, 403);
  assert.equal(calls.length, 0);
});
