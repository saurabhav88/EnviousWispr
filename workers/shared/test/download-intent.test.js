import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DOWNLOAD_INTENT,
  DOWNLOAD_INTENT_SQL,
  OFFSITE_REDIRECT_SQL,
  qualifiesDownloadIntent,
} from "../download-intent.js";

// One contract test for the one rule (#2953). The SQL and the function are two
// renderings of the same predicate; both are pinned here so they cannot drift
// apart without this file noticing.

test("intent contract preserves clicks and offsite, excludes onsite and bots", () => {
  // Client click always counts, whatever else is on the row.
  assert.equal(qualifiesDownloadIntent({ event: "download_clicked" }), true);
  assert.equal(
    qualifiesDownloadIntent({ event: "download_clicked", excludedReason: "bot_ua", sourceBucket: "onsite" }),
    true,
  );
  // Off-site redirect counts when the doorway did not exclude it.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", sourceBucket: "reddit" }), true);
  assert.equal(
    qualifiesDownloadIntent({ event: "download_redirect", excludedReason: "", sourceBucket: "github_readme" }),
    true,
  );
  // A pre-#2953 redirect row carries no source_bucket at all and still counts.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", excludedReason: null }), true);
  // Bots never count.
  assert.equal(
    qualifiesDownloadIntent({ event: "download_redirect", excludedReason: "bot_ua", sourceBucket: "reddit" }),
    false,
  );
  // The on-site redirect is the click's server-side twin, never a second intent.
  assert.equal(qualifiesDownloadIntent({ event: "download_redirect", sourceBucket: "onsite" }), false);
  // Anything else is not a download at all.
  assert.equal(qualifiesDownloadIntent({ event: "$pageview" }), false);
});

test("the SQL rendering names the same events and the same excluded bucket", () => {
  assert.equal(DOWNLOAD_INTENT.excludedBucket, "onsite");
  assert.match(OFFSITE_REDIRECT_SQL, /event = 'download_redirect'/);
  assert.match(OFFSITE_REDIRECT_SQL, /coalesce\(properties\.excluded_reason, ''\) = ''/);
  assert.match(OFFSITE_REDIRECT_SQL, /coalesce\(properties\.source_bucket, ''\) != 'onsite'/);
  assert.match(DOWNLOAD_INTENT_SQL, /^\(event = 'download_clicked' OR \(event = 'download_redirect'/);
  // Null-safety is the point: a bare comparison would drop every row with no bucket.
  assert.doesNotMatch(OFFSITE_REDIRECT_SQL, /properties\.source_bucket != /);
});
