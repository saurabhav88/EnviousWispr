/**
 * The ONE definition of a "download intent" (#2953).
 *
 * Two events describe a download: `download_clicked` (the browser, fired by the
 * on-site button listener in website/src/components/SiteServices.astro) and
 * `download_redirect` (the server, fired by the /download doorway in
 * website/functions/download.js). Since #2953 every on-site button ALSO passes
 * through the doorway, so one on-site click produces BOTH events. The doorway
 * tags those `source_bucket = 'onsite'`, and this file is where every consumer
 * agrees to count an intent exactly once:
 *
 *   - on-site: the client click counts; the on-site redirect is the richer
 *     record (referrer, country, cookie-bound visitor and session ids) and is
 *     NOT an intent.
 *   - off-site: the redirect counts, unless the doorway excluded it as a bot.
 *
 * Three consumers used to spell this predicate by hand (weekly digest SQL,
 * daily download-source SQL, the download-counter's qualification). A rule
 * that lives in three places drifts in one of them; import from here instead.
 */

export const DOWNLOAD_INTENT = Object.freeze({
  click: "download_clicked",
  redirect: "download_redirect",
  excludedBucket: "onsite",
});

const p = DOWNLOAD_INTENT;

/** HogQL: an off-site redirect that counts. Null-safe on both properties so a
 * pre-#2953 row (no `source_bucket`) and a row with no `excluded_reason` keep
 * counting exactly as they did. */
export const OFFSITE_REDIRECT_SQL =
  `(event = '${p.redirect}' AND ` +
  `coalesce(properties.excluded_reason, '') = '' AND ` +
  `coalesce(properties.source_bucket, '') != '${p.excludedBucket}')`;

/** HogQL: every download intent, on-site or off-site, counted once. */
export const DOWNLOAD_INTENT_SQL = `(event = '${p.click}' OR ${OFFSITE_REDIRECT_SQL})`;

/** The same rule for a single relayed event (download-counter). */
export function qualifiesDownloadIntent({ event, excludedReason, sourceBucket }) {
  return (
    event === p.click ||
    (event === p.redirect &&
      (excludedReason ?? "") === "" &&
      sourceBucket !== p.excludedBucket)
  );
}
