import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DOWNLOAD_INTENT,
  DOWNLOAD_INTENT_SQL,
  OFFSITE_REDIRECT_SQL,
  REDIRECT_INTENT_SQL,
  isOffsiteRedirect,
  qualifiesDownloadIntent,
} from "../download-intent.js";

// One contract test for the one rule (#2953). The SQL and the functions are two
// renderings of the same predicate; both are pinned here so they cannot drift
// apart without this file noticing.

test("intent contract: historical clicks and every non-bot redirect count, bots never", () => {
  // The pre-#2953 browser event always counts, whatever else is on the row.
  assert.equal(qualifiesDownloadIntent({ event: "download_clicked" }), true);
  assert.equal(qualifiesDownloadIntent({ event: "download_clicked", excludedReason: "bot_ua" }), true);
  // A redirect counts when the doorway did not exclude it, on-site or off-site.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect" }), true);
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: "" }), true);
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: null }), true);
  // Bots never count.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: "bot_ua" }), false);
  // Anything else is not a download at all.
  assert.equal(qualifiesDownloadIntent({ event: "$pageview" }), false);
});

test("off-site split: onsite bucket is on-site, everything else (including no bucket) is off-site", () => {
  assert.equal(isOffsiteRedirect({ event: "download_redirect", sourceBucket: "onsite" }), false);
  assert.equal(isOffsiteRedirect({ event: "download_redirect", sourceBucket: "reddit" }), true);
  assert.equal(isOffsiteRedirect({ event: "download_redirect", sourceBucket: "" }), true);
  assert.equal(isOffsiteRedirect({ event: "download_redirect" }), true);
  assert.equal(isOffsiteRedirect({ event: "download_clicked", sourceBucket: "reddit" }), false);
});

test("the SQL renderings are exactly the predicate, byte for byte", () => {
  assert.equal(DOWNLOAD_INTENT.onsiteBucket, "onsite");
  assert.equal(
    REDIRECT_INTENT_SQL,
    "(event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '')",
  );
  assert.equal(
    DOWNLOAD_INTENT_SQL,
    "(event = 'download_clicked' OR (event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = ''))",
  );
  assert.equal(
    OFFSITE_REDIRECT_SQL,
    "((event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '') AND coalesce(properties.source_bucket, '') != 'onsite')",
  );
});
