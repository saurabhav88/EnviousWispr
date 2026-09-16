// Unit test for the /download doorway source-bucket resolver + bot heuristic.
// Run: node website/functions/download.test.mjs
import assert from "node:assert/strict";
import { resolveSourceBucket, isLikelyBot } from "./download.js";

const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15";
const SELF = "enviouswispr.com";
const cases = [
  [{ isBot: true, explicit: "", utmSource: "reddit", utmMedium: null, referrerHost: "reddit.com", ua: "curl/8.4.0", selfHost: SELF }, "bot_filtered"],
  [{ isBot: false, explicit: "github_readme", utmSource: null, utmMedium: null, referrerHost: null, ua: UA, selfHost: SELF }, "github_readme"],
  [{ isBot: false, explicit: "", utmSource: "reddit", utmMedium: "post", referrerHost: null, ua: UA, selfHost: SELF }, "reddit"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: "email", referrerHost: null, ua: UA, selfHost: SELF }, "newsletter"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "chatgpt.com", ua: UA, selfHost: SELF }, "ai_assistant"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "www.perplexity.ai", ua: UA, selfHost: SELF }, "ai_assistant"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "old.reddit.com", ua: UA, selfHost: SELF }, "reddit"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: null, ua: UA, selfHost: SELF }, "direct_or_dark"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "randomsite.example", ua: UA, selfHost: SELF }, "unknown_referrer"],
  [{ isBot: false, explicit: "foo_not_a_bucket", utmSource: null, utmMedium: null, referrerHost: "news.ycombinator.com", ua: UA, selfHost: SELF }, "hackernews"],
  [{ isBot: false, explicit: "", utmSource: "github", utmMedium: "referral", referrerHost: null, ua: UA, selfHost: SELF }, "github_readme"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "alternativeto.net", ua: UA, selfHost: SELF }, "directory_alternativeto"],
];

// #2993 scanner shapes, bucket AND reason together: the bucket alone cannot tell
// a counted click from an excluded scanner hit. Save-correlated requests suggest
// scanning; these heuristics can also exclude a human request with a stripped UA
// or an own-host Referer on an explicit off-site tag. Null $os/$browser on a row
// does not prove its UA was empty.
const base = { isBot: false, explicit: "youtube", utmSource: "youtube", utmMedium: "social", ua: UA, selfHost: SELF, referrerHost: null };
const shapeCases = [
  [{ ua: "" }, "youtube", "no_ua"],
  [{ ua: "", explicit: "onsite", utmSource: null, utmMedium: null }, "onsite", null],
  [{ referrerHost: SELF }, "youtube", "self_referred_offsite"],
  [{ referrerHost: "www.youtube.com" }, "youtube", null],
  [{ ua: "UnrecognisedClient/1.0" }, "youtube", null],
  [{ selfHost: "preview.pages.dev", referrerHost: "preview.pages.dev" }, "youtube", "self_referred_offsite"],
  [{ explicit: "", referrerHost: SELF }, "youtube", null],
  [{ explicit: "onsite", utmSource: null, utmMedium: null, referrerHost: SELF }, "onsite", null],
  [{ explicit: "github_readme", utmSource: null, utmMedium: null, referrerHost: "github.com" }, "github_readme", null],
  [{ isBot: true, ua: "curl/8.4.0" }, "bot_filtered", "bot_ua"],
  [{ isBot: true, ua: "Google-Safety" }, "bot_filtered", "bot_ua"],
];

// Bot heuristic (cloud review PR #1240): crawler signatures match; real humans
// clicking from an in-app WebView (UA carries the bare app name) must NOT match.
const botCases = [
  ["Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)", true],
  ["Discordbot/2.0", true],
  ["facebookexternalhit/1.1", true],
  ["TelegramBot (like TwitterBot)", true],
  ["curl/8.4.0", true],
  ["Google-Safety", true],
  // Real humans in in-app WebViews — bare app name, no "bot": MUST be false.
  ["Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Discord/200.0", false],
  ["Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 ... Telegram", false],
  ["Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 Mobile/15E148 [Slack]", false],
  ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", false],
];

let pass = 0, fail = 0;
for (const [input, expect] of cases) {
  const got = resolveSourceBucket(input).bucket;
  if (got === expect) { pass++; } else { fail++; console.error(`FAIL bucket expect=${expect} got=${got} ${JSON.stringify(input)}`); }
}
for (const [patch, bucket, excludedReason] of shapeCases) {
  const input = { ...base, ...patch };
  try {
    assert.deepEqual(resolveSourceBucket(input), { bucket, excludedReason });
    pass++;
  } catch (e) {
    fail++; console.error(`FAIL shape ${JSON.stringify(patch)}: ${e.message}`);
  }
}
// A caller that forgets ua or selfHost must fail loud, never read as a browser.
for (const key of ["ua", "selfHost"]) {
  const input = { ...base };
  delete input[key];
  try {
    assert.throws(() => resolveSourceBucket(input), TypeError);
    pass++;
  } catch (e) {
    fail++; console.error(`FAIL missing ${key} did not throw TypeError: ${e.message}`);
  }
}
for (const [ua, expect] of botCases) {
  const got = isLikelyBot(ua);
  if (got === expect) { pass++; } else { fail++; console.error(`FAIL isLikelyBot expect=${expect} got=${got} ua=${ua}`); }
}
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
