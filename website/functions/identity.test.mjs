// #2953: the doorway reads the visitor's first-party PostHog cookie so a
// download joins the visit that produced it. Run: `npm run test:functions`.
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  identityFromCookie,
  languageFromHeader,
  pageFromReferer,
  placementFromQuery,
  platformFromUserAgent,
  resolveSourceBucket,
} from "./download.js";

const KEY = "phc_test";
const NOW = 1_800_000_000_000;

// The exact shape posthog-js writes: encodeURIComponent(JSON.stringify(...)).
function cookie(value, { name = `ph_${KEY}_posthog`, extra = "" } = {}) {
  const raw = typeof value === "string" ? value : encodeURIComponent(JSON.stringify(value));
  return `_ga=GA1.1.1; ${name}=${raw}${extra ? `; ${extra}` : ""}`;
}

test("cookie decodes the SDK shape: distinct id and a live session", () => {
  const c = cookie({ distinct_id: "0199-visitor", $sesid: [NOW - 60_000, "0199-session", NOW - 600_000] });
  assert.deepEqual(identityFromCookie(c, KEY, NOW), { distinctId: "0199-visitor", sessionId: "0199-session" });
});

test("expired session preserves identity: idle past 30 minutes drops only the session", () => {
  const c = cookie({ distinct_id: "0199-visitor", $sesid: [NOW - 31 * 60_000, "0199-session", NOW - 40 * 60_000] });
  assert.deepEqual(identityFromCookie(c, KEY, NOW), { distinctId: "0199-visitor", sessionId: null });
});

test("session timeout boundaries: 30 minutes idle is still live, 24 hours old is not", () => {
  const atIdleLimit = cookie({ distinct_id: "v", $sesid: [NOW - 30 * 60_000, "s", NOW - 60 * 60_000] });
  assert.equal(identityFromCookie(atIdleLimit, KEY, NOW).sessionId, "s");
  const pastIdleLimit = cookie({ distinct_id: "v", $sesid: [NOW - 30 * 60_000 - 1, "s", NOW - 60 * 60_000] });
  assert.equal(identityFromCookie(pastIdleLimit, KEY, NOW).sessionId, null);
  const atMaxAge = cookie({ distinct_id: "v", $sesid: [NOW - 1000, "s", NOW - 24 * 60 * 60_000] });
  assert.equal(identityFromCookie(atMaxAge, KEY, NOW).sessionId, "s");
  const pastMaxAge = cookie({ distinct_id: "v", $sesid: [NOW - 1000, "s", NOW - 24 * 60 * 60_000 - 1] });
  assert.equal(identityFromCookie(pastMaxAge, KEY, NOW).sessionId, null);
});

test("a cookie with no session tuple still yields the visitor", () => {
  assert.deepEqual(identityFromCookie(cookie({ distinct_id: "v" }), KEY, NOW), { distinctId: "v", sessionId: null });
  assert.deepEqual(identityFromCookie(cookie({ distinct_id: "v", $sesid: null }), KEY, NOW), { distinctId: "v", sessionId: null });
});

test("invalid cookie falls back: missing, wrong key, malformed JSON, non-string id, empty value", () => {
  assert.equal(identityFromCookie(undefined, KEY, NOW), null);
  assert.equal(identityFromCookie("", KEY, NOW), null);
  assert.equal(identityFromCookie("_ga=1; other=2", KEY, NOW), null);
  assert.equal(identityFromCookie(cookie({ distinct_id: "v" }, { name: "ph_phc_other_posthog" }), KEY, NOW), null);
  assert.equal(identityFromCookie(cookie("%7Bnot-json"), KEY, NOW), null);
  assert.equal(identityFromCookie(cookie("not%20even%20an%20object"), KEY, NOW), null);
  assert.equal(identityFromCookie(cookie({ distinct_id: 42 }), KEY, NOW), null);
  assert.equal(identityFromCookie(cookie({ distinct_id: "" }), KEY, NOW), null);
  assert.equal(identityFromCookie(`ph_${KEY}_posthog=`, KEY, NOW), null);
});

test("oversized cookie falls back, and an oversized id is refused", () => {
  const huge = cookie({ distinct_id: "v", pad: "x".repeat(5000) });
  assert.equal(identityFromCookie(huge, KEY, NOW), null);
  const longId = cookie({ distinct_id: "y".repeat(257) });
  assert.equal(identityFromCookie(longId, KEY, NOW), null);
});

test("the cookie is found among others and a bad nowMs never grants a session", () => {
  const c = cookie({ distinct_id: "v", $sesid: [NOW, "s", NOW] }, { extra: "crisp-client/session=abc" });
  assert.equal(identityFromCookie(c, KEY, NOW).sessionId, "s");
  assert.equal(identityFromCookie(c, KEY, NaN).sessionId, null);
});

const REQ = "https://enviouswispr.com/download?source=onsite";

test("redirect page is the same-origin Referer pathname, query dropped", () => {
  assert.equal(pageFromReferer("https://enviouswispr.com/compare/voiceink/?utm_source=x", REQ), "/compare/voiceink/");
  assert.equal(pageFromReferer("https://enviouswispr.com/", REQ), "/");
});

test("an off-site Referer is not one of our pages: null, never its own path", () => {
  assert.equal(pageFromReferer("https://reddit.com/r/macapps/", REQ), null);
  assert.equal(pageFromReferer("https://www.enviouswispr.com/", REQ), null);
  assert.equal(pageFromReferer("http://enviouswispr.com/", REQ), null);
});

test("missing or malformed referer produces null page", () => {
  assert.equal(pageFromReferer("", REQ), null);
  assert.equal(pageFromReferer(undefined, REQ), null);
  assert.equal(pageFromReferer("not a url", REQ), null);
  assert.equal(pageFromReferer("https://enviouswispr.com/", "not a url"), null);
});

test("placement is a plain token or nothing", () => {
  assert.equal(placementFromQuery("hero"), "hero");
  assert.equal(placementFromQuery("wisprflow-alternatives-bottom"), "wisprflow-alternatives-bottom");
  assert.equal(placementFromQuery(null), null);
  assert.equal(placementFromQuery(""), null);
  assert.equal(placementFromQuery("Hero"), null);
  assert.equal(placementFromQuery("a b"), null);
  assert.equal(placementFromQuery("hero\n"), null);
  assert.equal(placementFromQuery("<script>"), null);
  assert.equal(placementFromQuery("x".repeat(41)), null);
});

test("platform from User-Agent: the common Mac browsers, and nulls for the unknown", () => {
  const safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";
  const chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
  const edge = chrome + " Edg/124.0.0.0";
  const firefox = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:125.0) Gecko/20100101 Firefox/125.0";
  const iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1";
  assert.deepEqual(platformFromUserAgent(safari), { os: "Mac OS X", browser: "Safari" });
  assert.deepEqual(platformFromUserAgent(chrome), { os: "Mac OS X", browser: "Chrome" });
  assert.deepEqual(platformFromUserAgent(edge), { os: "Mac OS X", browser: "Microsoft Edge" });
  const edgeAndroid = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36 EdgA/124.0.0.0";
  assert.deepEqual(platformFromUserAgent(edgeAndroid), { os: "Android", browser: "Microsoft Edge" });
  assert.deepEqual(platformFromUserAgent(firefox), { os: "Mac OS X", browser: "Firefox" });
  assert.deepEqual(platformFromUserAgent(iphone), { os: "iOS", browser: "Safari" });
  assert.deepEqual(platformFromUserAgent("curl/8.4.0"), { os: null, browser: null });
  assert.deepEqual(platformFromUserAgent(""), { os: null, browser: null });
});

test("language is the first Accept-Language tag or nothing", () => {
  assert.equal(languageFromHeader("en-US,en;q=0.9,fr;q=0.8"), "en-US");
  assert.equal(languageFromHeader("de"), "de");
  assert.equal(languageFromHeader("*"), null);
  assert.equal(languageFromHeader(""), null);
  assert.equal(languageFromHeader(null), null);
});

test("onsite is an explicit bucket and never falls through to a referrer class", () => {
  assert.deepEqual(
    resolveSourceBucket({ isBot: false, explicit: "onsite", utmSource: null, utmMedium: null, referrerHost: "enviouswispr.com" }),
    { bucket: "onsite", excludedReason: null },
  );
  // A bot hitting the on-site path is still a bot.
  assert.equal(
    resolveSourceBucket({ isBot: true, explicit: "onsite", utmSource: null, utmMedium: null, referrerHost: "enviouswispr.com" }).bucket,
    "bot_filtered",
  );
});
