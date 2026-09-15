/**
 * The ONE definition of a "download intent" (#2953).
 *
 * Two events describe a download: `download_clicked` (the browser, fired by the
 * on-site button handler in website/src/components/SiteServices.astro) and
 * `download_redirect` (the server, fired by the /download doorway in
 * website/functions/download.js). Every on-site button passes through the
 * doorway, so one on-site click produces BOTH events; the doorway tags those
 * `source_bucket = 'onsite'`. This file is where every consumer agrees to count
 * an intent exactly once:
 *
 *   - on-site: the CLICK counts. It carries the visit's origin (`$referring_domain`
 *     is Google, Reddit, direct: the tracker keeps the first referrer of the
 *     visit), which is what the founder reads. The on-site redirect is the
 *     click's server-side twin (cookie-bound ids, placement, country) and is
 *     NOT an intent: the doorway also receives fetches that never ran the page
 *     script (link checkers, previews, prefetchers; 18 of 27 on-site hits in the
 *     first two hours of 2026-09-15 carried no cookie), and the click is what
 *     filters those out. Founder decision 2026-09-15 after two hours the other
 *     way round.
 *   - off-site: the redirect counts, unless the doorway excluded it as a bot.
 *
 * Three consumers used to spell this predicate by hand (weekly digest SQL,
 * daily download-source SQL, the download-counter's qualification), and the
 * EnviousMarketing puller mirrors it (ops/tracker/lib/metrics-shared.mjs). A
 * rule that lives in several places drifts in one of them; import from here.
 */

export const DOWNLOAD_INTENT = Object.freeze({
  click: "download_clicked",
  redirect: "download_redirect",
  onsiteBucket: "onsite",
});

const p = DOWNLOAD_INTENT;

/** HogQL: an off-site redirect that counts. Null-safe on both properties so a
 * pre-#2953 row (no `source_bucket`) and a row with no `excluded_reason` keep
 * counting exactly as they did. */
export const OFFSITE_REDIRECT_SQL =
  `(event = '${p.redirect}' AND ` +
  `coalesce(properties.excluded_reason, '') = '' AND ` +
  `coalesce(properties.source_bucket, '') != '${p.onsiteBucket}')`;

/** HogQL: every download intent, on-site or off-site, counted once. */
export const DOWNLOAD_INTENT_SQL = `(event = '${p.click}' OR ${OFFSITE_REDIRECT_SQL})`;

/** The same rule for a single relayed event (download-counter). */
export function qualifiesDownloadIntent({ event, excludedReason, sourceBucket }) {
  return (
    event === p.click ||
    (event === p.redirect && (excludedReason ?? "") === "" && (sourceBucket ?? "") !== p.onsiteBucket)
  );
}

/** Same split as OFFSITE_REDIRECT_SQL for a single relayed event. */
export function isOffsiteRedirect({ event, sourceBucket }) {
  return event === p.redirect && (sourceBucket ?? "") !== p.onsiteBucket;
}
