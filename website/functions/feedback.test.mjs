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
const env = { RESEND_API_KEY: "test-key" };

function post(body, origin = SITE) {
  const headers = { "Content-Type": "application/json" };
  if (origin !== null) headers.Origin = origin;
  return new Request("https://enviouswispr.com/api/feedback", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// Records every Resend call and answers with the given status and text.
function fakeResend(status = 200, text = '{"id":"x"}') {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return new Response(text, { status });
  };
  return calls;
}

const ok = { email: "reader@example.com", message: "The paste did not land." };

test("a valid form from the site sends one email and returns ok", async () => {
  const calls = fakeResend();
  const res = await onRequestPost({ request: post(ok), env });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.resend.com/emails");
  assert.equal(calls[0].body.reply_to, "reader@example.com");
  assert.equal(calls[0].body.subject, "Feedback from reader@example.com");
});

for (const origin of [null, "", "https://evil.example", "https://enviouswispr.com.evil.example", "http://localhost:43210"]) {
  test(`origin ${JSON.stringify(origin)} is refused before any email`, async () => {
    const calls = fakeResend();
    const res = await onRequestPost({ request: post(ok, origin), env });
    assert.equal(res.status, 403);
    assert.equal(calls.length, 0);
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
    assert.equal(typeof (await res.json()).error, "string");
  });
}

test("a message of exactly 5000 characters sends", async () => {
  const calls = fakeResend();
  const res = await onRequestPost({ request: post({ email: "a@b.co", message: "x".repeat(5000) }), env });
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
