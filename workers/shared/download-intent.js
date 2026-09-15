/**
 * The ONE definition of a "download intent" (#2953).
 *
 * Since #2953 every download, on-site or off-site, passes through the /download
 * doorway (website/functions/download.js), which records `download_redirect`
 * server-side: it fires even when the browser blocks the tracker, carries the
 * real IP for country, the placement of the on-site button, and, when the
 * visitor's first-party PostHog cookie is present, the same distinct_id and
 * session id as the page views. The browser no longer emits its own event.
 *
 *   - `download_redirect` counts unless the doorway excluded it as a bot.
 *   - `download_clicked` is the browser event the on-site buttons emitted
 *     BEFORE #2953, when they linked straight to GitHub and no redirect
 *     existed. Those historical rows still count; nothing emits it any more.
 *
 * Three consumers used to spell this predicate by hand (weekly digest SQL,
 * daily download-source SQL, the download-counter's qualification). A rule
 * that lives in three places drifts in one of them; import from here instead.
 */

export const DOWNLOAD_INTENT = Object.freeze({
  click: "download_clicked",
  redirect: "download_redirect",
  onsiteBucket: "onsite",
});

const p = DOWNLOAD_INTENT;

/** HogQL: a redirect that counts. Null-safe so a row with no `excluded_reason`
 * keeps counting exactly as it did. */
export const REDIRECT_INTENT_SQL =
  `(event = '${p.redirect}' AND coalesce(properties.excluded_reason, '') = '')`;

/** HogQL: every download intent, counted once. */
export const DOWNLOAD_INTENT_SQL = `(event = '${p.click}' OR ${REDIRECT_INTENT_SQL})`;

/** HogQL: a counting redirect that came from an off-site owned link, for the
 * source breakdown. Null-safe on `source_bucket` so a pre-#2953 row (no bucket)
 * stays off-site, which is all it could have been. */
export const OFFSITE_REDIRECT_SQL =
  `(${REDIRECT_INTENT_SQL} AND coalesce(properties.source_bucket, '') != '${p.onsiteBucket}')`;

/** The same rule for a single relayed event (download-counter). */
export function qualifiesDownloadIntent({ event, excludedReason }) {
  return event === p.click || (event === p.redirect && (excludedReason ?? "") === "");
}

/** Same split as OFFSITE_REDIRECT_SQL for a single relayed event. */
export function isOffsiteRedirect({ event, sourceBucket }) {
  return event === p.redirect && (sourceBucket ?? "") !== p.onsiteBucket;
}
