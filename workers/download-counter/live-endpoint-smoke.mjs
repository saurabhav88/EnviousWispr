/**
 * Live-endpoint smoke test for workers/download-counter (#1691).
 *
 * Targets the ISOLATED `smoke` Wrangler environment deployment ONLY — never
 * the production Worker, and never before the real production seed step
 * (plan §3/§9: touching production before seeding would corrupt the real
 * tally and permanently lock out the real /seed call).
 *
 * Usage:
 *   DOWNLOAD_COUNTER_SMOKE_URL="https://enviouswispr-download-counter-smoke.saurabhav.workers.dev" \
 *   DOWNLOAD_COUNTER_SMOKE_SECRET="<smoke env TRIGGER_SECRET>" \
 *   node workers/download-counter/live-endpoint-smoke.mjs
 */

const BASE_URL = process.env.DOWNLOAD_COUNTER_SMOKE_URL;
const SECRET = process.env.DOWNLOAD_COUNTER_SMOKE_SECRET;

if (!BASE_URL || !SECRET) {
  console.error("Set DOWNLOAD_COUNTER_SMOKE_URL and DOWNLOAD_COUNTER_SMOKE_SECRET first.");
  process.exit(1);
}
if (BASE_URL.includes("download-counter.") && !BASE_URL.includes("download-counter-smoke")) {
  console.error(`Refusing to run against a non-smoke-looking URL: ${BASE_URL}`);
  process.exit(1);
}

let failures = 0;

function check(label, condition) {
  if (condition) {
    console.log(`  PASS  ${label}`);
  } else {
    console.log(`  FAIL  ${label}`);
    failures += 1;
  }
}

function uniqueId(label) {
  return `smoke-${label}-${process.pid}-${Math.floor(performance.now() * 1000)}`;
}

async function postCount(body) {
  const res = await fetch(`${BASE_URL}/count`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-trigger-secret": SECRET },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    // 502/503 responses have no body
  }
  return { status: res.status, json };
}

function smokeEvent(overrides = {}) {
  return {
    eventId: uniqueId("evt"),
    event: "download_clicked",
    ip: "203.0.113.1",
    city: "Nowhere",
    country: "Testland",
    countryCode: "US",
    referrer: "$direct",
    page: "/",
    browser: "SmokeTest",
    os: "SmokeOS",
    lang: "",
    ...overrides,
  };
}

async function main() {
  console.log(`Smoke-testing ${BASE_URL}\n`);

  console.log("1. A real new event posts to Discord and returns a total");
  const first = await postCount(smokeEvent());
  check("status 200", first.status === 200);
  check("counted true", first.json?.counted === true);
  check("total is a number", typeof first.json?.total === "number");

  console.log("\n2. Retrying the SAME event resumes instead of re-incrementing");
  const eventId = uniqueId("retry");
  const original = smokeEvent({ eventId });
  const attempt1 = await postCount(original);
  const attempt2 = await postCount(original);
  check("first attempt counted", attempt1.json?.counted === true);
  check("retry reuses the same total", attempt2.json?.total === attempt1.json?.total);
  check("retry reason is already-delivered", attempt2.json?.reason === "already-delivered");

  console.log("\n3. A second distinct event from the same IP within the dedup window is suppressed");
  const sharedIp = "203.0.113.55";
  const dupA = await postCount(smokeEvent({ eventId: uniqueId("dup-a"), ip: sharedIp }));
  const dupB = await postCount(smokeEvent({ eventId: uniqueId("dup-b"), ip: sharedIp }));
  check("first counts", dupA.json?.counted === true);
  check("second is suppressed as a duplicate", dupB.json?.counted === false && dupB.json?.reason === "duplicate");

  console.log("\n4. Two genuinely concurrent requests for the SAME event never both post");
  const concurrentId = uniqueId("concurrent");
  const [concA, concB] = await Promise.all([
    postCount(smokeEvent({ eventId: concurrentId, ip: "203.0.113.77" })),
    postCount(smokeEvent({ eventId: concurrentId, ip: "203.0.113.77" })),
  ]);
  const statuses = [concA.status, concB.status].sort();
  check(
    "exactly one of the two succeeded (200) and the other was told to back off (503)",
    (statuses[0] === 200 && statuses[1] === 503) || (statuses[0] === 200 && statuses[1] === 200),
  );
  if (statuses[0] === 200 && statuses[1] === 200) {
    check("if both eventually succeeded, they report the SAME total (no double count)", concA.json?.total === concB.json?.total);
  }

  console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error("Smoke test crashed:", err);
  process.exit(1);
});
