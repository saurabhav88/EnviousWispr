import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DOWNLOAD_INTENT,
  DOWNLOAD_INTENT_SQL,
  OFFSITE_REDIRECT_SQL,
  PRE_FILTER_BOT_UA_SQL,
  isOffsiteRedirect,
  qualifiesDownloadIntent,
} from "../download-intent.js";

// One contract test for the one rule (#2953). The SQL and the functions are two
// renderings of the same predicate; both are pinned here so they cannot drift
// apart without this file noticing.

test("intent contract: clicks and non-excluded off-site redirects count", () => {
  // Client click always counts, whatever else is on the row.
  assert.equal(qualifiesDownloadIntent({ event: "download_clicked" }), true);
  assert.equal(qualifiesDownloadIntent({ event: "download_clicked", excludedReason: "bot_ua", sourceBucket: "onsite" }), true);
  // Off-site redirect counts when the doorway did not exclude it.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", sourceBucket: "reddit" }), true);
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: "", sourceBucket: "github_readme" }), true);
  // A pre-#2953 redirect row carries no source_bucket at all and still counts.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: null }), true);
  // Bot-excluded redirects never count.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: "bot_ua", sourceBucket: "reddit" }), false);
  // The on-site redirect is the click's server-side twin, never a second intent.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", sourceBucket: "onsite" }), false);
  // Anything else is not a download at all.
  assert.equal(qualifiesDownloadIntent({ event: "$pageview" }), false);
});

test("off-site split: onsite bucket is on-site, everything else (including no bucket) is off-site", () => {
  assert.equal(isOffsiteRedirect({ event: "download_redirect", sourceBucket: "onsite" }), false);
  assert.equal(isOffsiteRedirect({ event: "download_redirect", sourceBucket: "reddit" }), true);
  assert.equal(isOffsiteRedirect({ event: "download_redirect" }), true);
  assert.equal(isOffsiteRedirect({ event: "download_clicked", sourceBucket: "reddit" }), false);
});

test("the SQL renderings are exactly the predicate, byte for byte", () => {
  assert.equal(DOWNLOAD_INTENT.onsiteBucket, "onsite");
  assert.equal(
    OFFSITE_REDIRECT_SQL,
    "(event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '' AND coalesce(properties.source_bucket, '') != 'onsite' AND NOT match(coalesce(properties.$raw_user_agent, ''), '(?i)^(Click/[0-9][0-9.]*|msh-pdfmin/[0-9][0-9.]*)$'))",
  );
  assert.equal(
    DOWNLOAD_INTENT_SQL,
    "(event = 'download_clicked' OR (event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '' AND coalesce(properties.source_bucket, '') != 'onsite' AND NOT match(coalesce(properties.$raw_user_agent, ''), '(?i)^(Click/[0-9][0-9.]*|msh-pdfmin/[0-9][0-9.]*)$')))",
  );
});

test("pre-filter robot clause matches only the WHOLE User-Agent of the two named fetchers", () => {
  // HogQL `match` is RE2; JS RegExp agrees on this pattern, so pin its behavior here.
  const m = PRE_FILTER_BOT_UA_SQL.match(/'\(\?i\)(.*)'\)$/);
  assert.ok(m, "the clause must carry one case-insensitive regex literal");
  const re = new RegExp(m[1], "i");
  for (const ua of ["Click/1.0", "click/2.13", "msh-pdfmin/1", "msh-pdfmin/1.2"]) {
    assert.equal(re.test(ua), true, ua);
  }
  for (const ua of [
    "",
    "Click",
    "msh-pdfmin",
    "Mozilla/5.0 (Macintosh) Click/1.0 Safari/605.1.15",
    "Mozilla/5.0 (Macintosh) msh-pdfmin/1 Safari/605.1.15",
    "Google-Safety",
  ]) {
    assert.equal(re.test(ua), false, ua);
  }
  assert.ok(OFFSITE_REDIRECT_SQL.endsWith(`AND ${PRE_FILTER_BOT_UA_SQL})`));
});
