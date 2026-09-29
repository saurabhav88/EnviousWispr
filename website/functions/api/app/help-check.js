// POST /api/app/help-check (#3275): the app's in-app help check. Logic, contract and
// privacy rules live in ../../_lib/help-check.js; this only reads the request.
import { MAX_BODY_BYTES, countLine, runHelpCheck, sendFeedback } from "../../_lib/help-check.js";

const json = (body, status) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

// Reads the body with a running byte limit, so a request without an honest
// Content-Length cannot make the Function buffer more than MAX_BODY_BYTES.
// Returns the bytes, "too_large" or "read_failed".
async function readLimited(request) {
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel().catch(() => {});
        return "too_large";
      }
      chunks.push(value);
    }
  } catch {
    return "read_failed";
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.byteLength;
  }
  return bytes;
}

async function check(request, env, deps) {
  const type = request.headers.get("Content-Type") || "";
  if (!/^application\/json\b/i.test(type)) return [sendFeedback("invalid_request"), 415];
  if (Number(request.headers.get("Content-Length")) > MAX_BODY_BYTES) return [sendFeedback("too_large"), 413];
  const bytes = await readLimited(request);
  if (bytes === "too_large") return [sendFeedback("too_large"), 413];
  if (bytes === "read_failed") return [sendFeedback("invalid_request"), 400];
  let body;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return [sendFeedback("invalid_request"), 400];
  }
  return [await runHelpCheck(body, env, deps), 200];
}

export async function handleHelpCheck(request, env, deps) {
  const [result, status] = await check(request, env, deps);
  console.log(countLine(result));
  return json(result, status);
}

export function onRequestPost({ request, env }) {
  return handleHelpCheck(request, env);
}
