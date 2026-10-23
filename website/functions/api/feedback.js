// POST /api/feedback: the website contact form, sent to hello@ through Resend.
// The Origin check only stops other websites' pages from posting through a
// visitor's browser; a script can send any Origin, so abuse limits belong at
// the Cloudflare edge, not here.
const ALLOWED_ORIGINS = new Set(["https://enviouswispr.com", "http://localhost:4321"]);
const MAX_EMAIL = 254;
const MAX_MESSAGE = 5000;
// One address, no spaces or control characters: it becomes the Reply-To and
// part of the Subject, so nothing else may ride along in it.
const EMAIL_SHAPE = /^[^\s@\p{Cc}]+@[^\s@\p{Cc}]+\.[^\s@\p{Cc}]+$/u;

export async function onRequestPost(context) {
  const { request, env } = context;

  const origin = request.headers.get("Origin") || "";
  if (!ALLOWED_ORIGINS.has(origin)) {
    return new Response("Forbidden", { status: 403 });
  }

  const cors = {
    "Access-Control-Allow-Origin": origin,
    "Content-Type": "application/json",
  };
  const fail = (error, status) =>
    new Response(JSON.stringify({ error }), { status, headers: cors });

  let body;
  try {
    body = await request.json();
  } catch {
    return fail("Invalid JSON", 400);
  }

  const email = typeof body?.email === "string" ? body.email.trim() : "";
  const message = typeof body?.message === "string" ? body.message : "";
  if (!email || !message.trim()) {
    return fail("Email and message are required", 400);
  }
  if (email.length > MAX_EMAIL || !EMAIL_SHAPE.test(email)) {
    return fail("Please enter a valid email address", 400);
  }
  if (message.length > MAX_MESSAGE) {
    return fail(`Message too long (max ${MAX_MESSAGE} characters)`, 400);
  }

  const apiKey = env.RESEND_API_KEY;
  if (!apiKey) {
    return fail("Server misconfigured", 500);
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "EnviousWispr Feedback <feedback@enviouswispr.com>",
      to: "hello@enviouswispr.com",
      reply_to: email,
      subject: `Feedback from ${email}`,
      text: `From: ${email}\n\n${message}`,
    }),
  });

  if (!res.ok) {
    // Resend's error text stays in the Function log; the caller learns only
    // that sending failed.
    console.error(`feedback: Resend ${res.status} ${await res.text()}`);
    return fail("Failed to send", 502);
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: cors,
  });
}

export async function onRequestOptions({ request }) {
  const origin = request.headers.get("Origin") || "";
  if (!ALLOWED_ORIGINS.has(origin)) {
    return new Response(null, { status: 403 });
  }
  return new Response(null, {
    headers: {
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    },
  });
}
