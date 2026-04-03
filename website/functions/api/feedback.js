export async function onRequestPost(context) {
  const { request, env } = context;

  const origin = request.headers.get("Origin") || "";
  const allowed = ["https://enviouswispr.com", "http://localhost:4321"];
  if (!allowed.some((o) => origin.startsWith(o))) {
    return new Response("Forbidden", { status: 403 });
  }

  const cors = {
    "Access-Control-Allow-Origin": origin,
    "Content-Type": "application/json",
  };

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: cors,
    });
  }

  const { email, message } = body;
  if (!email || !message) {
    return new Response(
      JSON.stringify({ error: "Email and message are required" }),
      { status: 400, headers: cors }
    );
  }

  if (message.length > 5000) {
    return new Response(
      JSON.stringify({ error: "Message too long (max 5000 characters)" }),
      { status: 400, headers: cors }
    );
  }

  const apiKey = env.RESEND_API_KEY;
  if (!apiKey) {
    return new Response(
      JSON.stringify({ error: "Server misconfigured" }),
      { status: 500, headers: cors }
    );
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
    const err = await res.text();
    return new Response(
      JSON.stringify({ error: "Failed to send", detail: err }),
      { status: 502, headers: cors }
    );
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: cors,
  });
}

export async function onRequestOptions() {
  return new Response(null, {
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    },
  });
}
