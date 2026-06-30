// Unit test for the /download doorway source-bucket resolver.
// Run: node website/functions/download.test.mjs
import { resolveSourceBucket } from "./download.js";

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

let pass = 0, fail = 0;
for (const [input, expect] of cases) {
  const got = resolveSourceBucket(input).bucket;
  if (got === expect) { pass++; } else { fail++; console.error(`FAIL expect=${expect} got=${got} ${JSON.stringify(input)}`); }
}
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
