// Unit test for the /download doorway source-bucket resolver + bot heuristic.
// Run: node website/functions/download.test.mjs
import { resolveSourceBucket, isLikelyBot } from "./download.js";

const cases = [
  [{ isBot: true, explicit: "", utmSource: "reddit", utmMedium: null, referrerHost: "reddit.com" }, "bot_filtered"],
  [{ isBot: false, explicit: "github_readme", utmSource: null, utmMedium: null, referrerHost: null }, "github_readme"],
  [{ isBot: false, explicit: "", utmSource: "reddit", utmMedium: "post", referrerHost: null }, "reddit"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: "email", referrerHost: null }, "newsletter"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "chatgpt.com" }, "ai_assistant"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "www.perplexity.ai" }, "ai_assistant"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "old.reddit.com" }, "reddit"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: null }, "direct_or_dark"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "randomsite.example" }, "unknown_referrer"],
  [{ isBot: false, explicit: "foo_not_a_bucket", utmSource: null, utmMedium: null, referrerHost: "news.ycombinator.com" }, "hackernews"],
  [{ isBot: false, explicit: "", utmSource: "github", utmMedium: "referral", referrerHost: null }, "github_readme"],
  [{ isBot: false, explicit: "", utmSource: null, utmMedium: null, referrerHost: "alternativeto.net" }, "directory_alternativeto"],
];

// Bot heuristic (cloud review PR #1240): crawler signatures match; real humans
// clicking from an in-app WebView (UA carries the bare app name) must NOT match.
const botCases = [
  ["Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)", true],
  ["Discordbot/2.0", true],
  ["facebookexternalhit/1.1", true],
  ["TelegramBot (like TwitterBot)", true],
  ["curl/8.4.0", true],
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
for (const [ua, expect] of botCases) {
  const got = isLikelyBot(ua);
  if (got === expect) { pass++; } else { fail++; console.error(`FAIL isLikelyBot expect=${expect} got=${got} ua=${ua}`); }
}
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
