/**
 * EnviousWispr Weekly Digest - Cloudflare Worker (issues #1243, #1589)
 *
 * Runs Monday 13:00 UTC via a Cloudflare cron trigger and posts ONE Discord
 * message with four sections: all website traffic (Cloudflare), tracked visitor
 * activity (PostHog), downloads (GitHub + PostHog), and app usage (PostHog).
 *
 * ORCHESTRATION OWNERSHIP. This file resolves the report window ONCE, resolves
 * the dev-ID exclusion ONCE, schedules every outbound query itself under one
 * concurrency limiter, assembles ONE payload, and decides whether the run was
 * clean. Transport, retry, limiting and Discord protocol belong to
 * `workers/shared`; the SQL, the window, the failure policy and every sentence
 * the founder reads belong here.
 *
 * WHAT #1589 FIXED. Four of these were WRONG NUMBERS rather than missing ones,
 * and a wrong number is worse than an absent one:
 *   - 5 concurrent PostHog queries against a documented 3-concurrent ceiling,
 *     with no retry and no HTTP status check at all.
 *   - Every failure rendered as "?" beside real figures, indistinguishable
 *     from a quiet week.
 *   - Active installs summed two Trends buckets over an 8-day window, counting
 *     anyone present in both twice: 210 reported where 189 was true.
 *   - Page views and visitors counted a DIFFERENT PRODUCT
 *     (app.enviousstaging.com) and localhost dev servers.
 *   - "All-time" downloads read only GitHub's first page: 30 of 45 releases.
 *   - A Cloudflare failure rendered as a confident 0.
 *   - The public trigger URL needed no secret and would post to Discord for
 *     anyone who knew it.
 *
 * Privacy: output and logs are counts, labels and durations only. Never a
 * distinct_id, never a response body, never the API key or trigger secret.
 */

import {
  productionClauseFor,
  querySection,
  resolveDevIds,
  rowsToObjects,
  runLimited,
  windowClause,
} from "../../shared/posthog.js";
import { deliverReport } from "../../shared/discord.js";

const WORKER_LABEL = "weekly_digest";

/** PostHog allows only 3 concurrent queries per project (#1588), and that
 * project is shared with EnviousStaging. Two in flight leaves a slot of
 * headroom. This is the GLOBAL ceiling for this run: sections describe their
 * work, they never schedule it, because two limiters of 2 is a limiter of 4. */
const CONCURRENCY_LIMIT = 2;

const REPORT_DAYS = 7;

/** The EnviousWispr website's own hosts. Everything else in PostHog project
 * 354235 belongs to another product or to a local dev server
 * (analytics-operations.md FACT: posthog-project-is-shared-with-enviousstaging).
 *
 * `www` does not appear in 30 days of live data and is listed anyway: its
 * absence is a fact about today's DNS, not a guarantee. */
const SITE_HOSTS = ["enviouswispr.com", "www.enviouswispr.com"];

export default {
  async scheduled(event, env) {
    await runDigest(env);
  },

  /**
   * Manual trigger. Secret-gated and FAILS CLOSED: the workers.dev URL is
   * public, and before #1589 any request to it posted a real digest to Discord.
   * An unset TRIGGER_SECRET refuses everything, so a half-configured deploy
   * cannot be triggered by anyone.
   */
  async fetch(request, env) {
    const url = new URL(request.url);
    const provided = url.searchParams.get("token") || request.headers.get("x-trigger-secret");
    if (!env.TRIGGER_SECRET || provided !== env.TRIGGER_SECRET) {
      return new Response("unauthorized\n", { status: 401 });
    }
    try {
      const content = await runDigest(env);
      return new Response(content + "\n", { status: 200 });
    } catch (err) {
      // Deliberately posts nothing here. runDigest owns every Discord request;
      // a second post from this layer is how a failed run tells the founder
      // twice, or tells him after he already has the digest.
      return new Response("weekly digest failed: " + err.message + "\n", { status: 500 });
    }
  },
};

// ----- Window ---------------------------------------------------------------

/**
 * Seven whole UTC days, HALF-OPEN: `start` inclusive, `end` exclusive.
 *
 * The shipped worker used `now - 7d` to `now` with BOTH ends inclusive, which
 * is eight calendar dates. That is what produced a second weekly Trends bucket
 * and, with the bucket-summing extractor, the 210-vs-189 double count. A
 * half-open range is also what stops consecutive weeks sharing a day.
 *
 * UTC days, not Eastern days. KNOWN LIMIT, recorded rather than hidden: the
 * daily report measures Eastern calendar days, so a week of daily reports and
 * one weekly digest cover windows offset by the Eastern UTC offset and will not
 * reconcile to the exact person. Aligning them means sharing the daily report's
 * timezone machinery, which is a separate change with its own risk to a working
 * worker.
 */
export function resolveWeekWindow(now = new Date()) {
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const start = new Date(end.getTime() - REPORT_DAYS * 86400000);
  return Object.freeze({
    start,
    end,
    win: windowClause(start, end),
    startDay: start.toISOString().slice(0, 10),
    // The last day INCLUDED, for display and for Cloudflare's inclusive filter.
    // Never `end` itself: that day is outside the window.
    lastDay: new Date(end.getTime() - 86400000).toISOString().slice(0, 10),
  });
}

// ----- Cloudflare -----------------------------------------------------------

/**
 * Site-wide traffic. One request, a different API with no shared ceiling, so it
 * runs outside the PostHog limiter.
 *
 * Every failure path throws. Before #1589 none of them did: a non-2xx, a
 * GraphQL `errors` array, or a missing zone all left `zone` undefined, the
 * totals loops ran over empty arrays, and the digest reported a confident 0
 * unique visitors. Three distinct producers of one silent wrong answer.
 */
export async function fetchCloudflareStats(env, window, { fetchFn = fetch } = {}) {
  const query = `query {
    viewer {
      zones(filter: {zoneTag: "${env.CF_ZONE_ID}"}) {
        totals: httpRequests1dGroups(
          limit: ${REPORT_DAYS}
          filter: {date_geq: "${window.startDay}", date_leq: "${window.lastDay}"}
        ) {
          sum { requests pageViews }
          uniq { uniques }
        }
        byDay: httpRequests1dGroups(
          limit: ${REPORT_DAYS}
          filter: {date_geq: "${window.startDay}", date_leq: "${window.lastDay}"}
        ) {
          dimensions { date }
          sum {
            pageViews
            countryMap { clientCountryName requests }
          }
        }
      }
    }
  }`;

  // NOTE: the former "Top Referrers" query (httpRequestsAdaptiveGroups {
  // refererHost }) was removed (#1243): refererHost is rejected by the
  // Cloudflare API on the zone dataset (the valid field, clientRefererHost, is
  // paid-only), so the section was silently empty. Download attribution now
  // comes from PostHog source_bucket.
  const res = await fetchFn("https://api.cloudflare.com/client/v4/graphql", {
    method: "POST",
    headers: {
      "X-Auth-Email": env.CF_EMAIL,
      "X-Auth-Key": env.CF_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) throw new Error(`Cloudflare Analytics HTTP ${res.status}`);

  const body = await res.json();
  // GraphQL answers 200 with an `errors` array, so a status-only check passes
  // and `zone` is still undefined. Separate producer, separate check.
  if (Array.isArray(body?.errors) && body.errors.length > 0) {
    throw new Error("Cloudflare Analytics returned GraphQL errors");
  }
  const zone = body?.data?.viewer?.zones?.[0];
  if (!zone) throw new Error("Cloudflare Analytics returned no zone");

  // A 200 carrying a zone but no `totals`/`byDay` array, or groups missing
  // their numeric fields, is malformed - NOT an empty week. `|| []` and `|| 0`
  // would turn exactly that into a confident zero, which is the silent-zero
  // failure this function exists to remove; it would just move one level
  // deeper. An EMPTY array is still legitimate (a genuinely dead week), so the
  // check is on the SHAPE, never on the length.
  if (!Array.isArray(zone.totals) || !Array.isArray(zone.byDay)) {
    throw new Error("Cloudflare Analytics returned a zone without totals/byDay");
  }

  let totalRequests = 0, totalPageViews = 0, summedDailyUniques = 0;
  const countries = {};
  const num = (value, field) => {
    if (typeof value !== "number" || !Number.isFinite(value)) {
      throw new Error(`Cloudflare Analytics returned a non-numeric ${field}`);
    }
    return value;
  };
  for (const g of zone.totals) {
    totalRequests += num(g?.sum?.requests, "requests");
    totalPageViews += num(g?.sum?.pageViews, "pageViews");
    summedDailyUniques += num(g?.uniq?.uniques, "uniques");
  }
  for (const g of zone.byDay) {
    // countryMap may legitimately be absent for a day with no traffic; a
    // PRESENT but malformed entry is not tolerated. The NAME is validated
    // alongside the count: a missing one becomes the object key "undefined" and
    // gets published as a busiest place, which is a wrong answer wearing a
    // country's clothes.
    for (const c of g?.sum?.countryMap ?? []) {
      const country = c?.clientCountryName;
      if (typeof country !== "string" || country.length === 0) {
        throw new Error("Cloudflare Analytics returned a country entry without a name");
      }
      countries[country] = (countries[country] || 0) + num(c?.requests, "countryMap.requests");
    }
  }

  return {
    totalRequests,
    totalPageViews,
    // Named for what it IS. This sums each day's unique-IP count, so a visitor
    // on three days counts three times; calling it "unique visitors" was the
    // label lying about the arithmetic (founder decision 2026-08-01: relabel,
    // do not change the query).
    summedDailyUniques,
    topCountries: Object.entries(countries).sort((a, b) => b[1] - a[1]).slice(0, 5),
  };
}

// ----- GitHub ---------------------------------------------------------------

const GITHUB_PAGE_SIZE = 100;
// Bound on pages walked. 45 releases exist today; 50 pages is 5,000 releases,
// far beyond any real state, and it exists only so a malformed paging response
// cannot spin forever inside a Worker's wall clock.
const GITHUB_MAX_PAGES = 50;

/**
 * All-time DMG downloads across EVERY release.
 *
 * The shipped version made one unpaginated request. GitHub's default page size
 * is 30 and this repo has 45 releases, so the "All-Time" figure silently
 * omitted 15 releases' worth of downloads.
 *
 * A mid-pagination failure throws rather than returning the pages gathered so
 * far: a total assembled from 2 of 5 pages is a plausible, confidently wrong
 * number, which is the exact defect class this change exists to remove.
 */
export async function fetchGitHubDownloads(env, { fetchFn = fetch } = {}) {
  const headers = { "User-Agent": "EnviousWispr-Digest-Worker" };
  if (env.GITHUB_TOKEN) headers.Authorization = `token ${env.GITHUB_TOKEN}`;

  let totalDownloads = 0;
  let latestVersion = "?";

  for (let page = 1; page <= GITHUB_MAX_PAGES; page += 1) {
    const res = await fetchFn(
      `https://api.github.com/repos/${env.GITHUB_REPO}/releases?per_page=${GITHUB_PAGE_SIZE}&page=${page}`,
      { headers }
    );
    if (!res.ok) throw new Error(`GitHub releases HTTP ${res.status}`);
    const releases = await res.json();
    if (!Array.isArray(releases)) throw new Error("GitHub releases returned a non-array");

    if (page === 1) {
      const tag = releases[0]?.tag_name;
      if (releases.length && typeof tag !== "string") {
        throw new Error("GitHub releases returned a release without a tag_name");
      }
      latestVersion = tag || "?";
    }
    for (const rel of releases) {
      // `rel.assets || []` would treat a release whose asset list is MISSING as
      // a release with no downloads, silently undercounting the all-time total
      // while reporting success. A release with an empty array is different and
      // legitimate: some releases genuinely ship no dmg.
      if (!Array.isArray(rel?.assets)) {
        throw new Error("GitHub releases returned a release without an assets array");
      }
      for (const asset of rel.assets) {
        // A non-string name silently fails the .dmg test and skips a real
        // asset, which is the same undercount by a different route.
        if (typeof asset?.name !== "string") {
          throw new Error("GitHub releases returned an asset without a name");
        }
        if (!asset.name.endsWith(".dmg")) continue;
        // Same class as the PostHog and Cloudflare checks: a 200 whose body is
        // the wrong shape must not become a number. `|| 0` here would silently
        // undercount a dmg whose counter came back null or a string, which
        // reads as a quiet week rather than as the malformed response it is.
        if (typeof asset.download_count !== "number" || !Number.isFinite(asset.download_count)) {
          throw new Error("GitHub releases returned a non-numeric download_count");
        }
        totalDownloads += asset.download_count;
      }
    }
    if (releases.length < GITHUB_PAGE_SIZE) return { totalDownloads, latestVersion };
  }
  throw new Error(`GitHub releases exceeded ${GITHUB_MAX_PAGES} pages`);
}

// ----- PostHog SQL ----------------------------------------------------------

const hostFilter = `properties.$host IN (${SITE_HOSTS.map((h) => `'${h}'`).join(", ")})`;

/** App usage. The ONLY query carrying the production predicate.
 *
 * `uniqExact` over the whole window, replacing a TrendsQuery whose two weekly
 * buckets were summed. New installs uses the app's own is_fresh_install rather
 * than PostHog's first_time_for_user (founder decision 2026-08-01): it is what
 * the daily report counts, and reproducing first_time_for_user in HogQL needs a
 * whole-history min(timestamp) per user, the unbounded-scan shape that caused
 * the #1655 and #1716 timeouts. */
export function appUsageSql(prod, win) {
  return `SELECT
      uniqExact(distinct_id) AS active,
      uniqExactIf(distinct_id, properties.is_fresh_install = true) AS fresh
    FROM events
    WHERE event = 'app.launched' AND ${prod} AND ${win}`;
}

/** Website traffic. NO production predicate, deliberately.
 *
 * `productionClauseFor` always begins `properties.environment = 'production'`,
 * and website events carry no environment property at all - the site's PostHog
 * init sets none. Applying it here returns ZERO, not "the same rows more
 * slowly". The host filter is what scopes this population, and it is what stops
 * EnviousStaging and localhost being counted as EnviousWispr visitors.
 *
 * This argument is LOCAL to the three website queries and must be re-derived by
 * anyone adding a fourth. */
export function websiteSql(win) {
  return `SELECT count() AS views, uniqExact(distinct_id) AS visitors
    FROM events
    WHERE event = '$pageview' AND ${hostFilter} AND ${win}`;
}

/** Download intents and excluded bot hits in ONE query.
 *
 * Same table, same window, differing only by predicate, so two countIf columns
 * replace two round trips. `WHERE event IN (...)` keeps the merged query scoped
 * to the two relevant event types. Both predicates are byte-preserved from the
 * two builders this replaces, so the numbers do not move.
 *
 * NO host filter, on measured evidence: download_clicked appears only from
 * enviouswispr.com, and download_redirect carries no $host at all because the
 * doorway worker emits it server-side. A host filter here would silently drop
 * every off-site redirect. */
export function downloadsSql(win) {
  return `SELECT
      countIf(event = 'download_clicked'
              OR (event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '')) AS intents,
      countIf(event = 'download_redirect'
              AND coalesce(properties.excluded_reason, '') != '') AS bots_excluded
    FROM events
    WHERE event IN ('download_clicked', 'download_redirect') AND ${win}`;
}

/** Off-site download sources by canonical bucket. Stays separate from
 * downloadsSql: it is a GROUP BY producing rows, and folding it in would need a
 * UNION - and a UNION in a query that also interpolates a predicate is the
 * doubled-subquery shape behind #1655 and #1716. */
export function downloadSourcesSql(win) {
  return `SELECT properties.source_bucket AS bucket, count() AS n
    FROM events
    WHERE event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '' AND ${win}
    GROUP BY bucket
    ORDER BY n DESC
    LIMIT 8`;
}

// ----- Presentation ---------------------------------------------------------

const UNAVAILABLE = "temporarily unavailable";

const n = (value) => Number(value).toLocaleString();

// Canonical source_bucket -> human label. Unknown/null -> "Other".
export const SOURCE_LABELS = {
  github_readme: "GitHub README",
  github_release: "GitHub",
  blog: "Blog",
  directory_alternativeto: "AlternativeTo",
  directory_macupdate: "MacUpdate",
  directory_other: "Directory listing",
  linkedin: "LinkedIn",
  reddit: "Reddit",
  x: "X",
  youtube: "YouTube",
  medium: "Medium",
  facebook: "Facebook",
  hackernews: "Hacker News",
  producthunt: "Product Hunt",
  discord: "Discord",
  ai_assistant: "AI assistant",
  newsletter: "Newsletter",
  direct_or_dark: "Direct / untracked",
  unknown_referrer: "Unrecognized site",
};
export function sourceLabel(bucket) {
  return (bucket && SOURCE_LABELS[bucket]) || "Other";
}

/** Renders the source breakdown. `null` (unavailable) and `[]` (a genuine zero)
 * render differently, so a telemetry outage never masquerades as a true
 * zero-source week. This one field already got the distinction right before
 * #1589; the rest of the digest now follows it. */
export function formatSourceBreakdown(rows) {
  if (rows == null || !Array.isArray(rows)) return "Sources unavailable";
  if (rows.length === 0) return "No off-site downloads yet";
  return rows.map((r) => `${sourceLabel(r.bucket)}: ${n(r.n)}`).join("\n");
}

function formatDayRange(window) {
  const fmt = (iso) => {
    const [y, m, d] = iso.split("-").map(Number);
    return new Intl.DateTimeFormat("en-US", {
      timeZone: "UTC", month: "long", day: "numeric",
    }).format(new Date(Date.UTC(y, m - 1, d, 12)));
  };
  return `${fmt(window.startDay)} to ${fmt(window.lastDay)}`;
}

/** Every section formatter returns LINES whose FIRST line titles its embed, so
 * the payload assembler never authors a sentence of its own. */
export function formatCloudflare(cf) {
  if (!cf) return ["All website traffic", `Traffic figures were ${UNAVAILABLE} when this digest ran.`];
  const lines = [
    "All website traffic",
    `${n(cf.totalPageViews)} page views, from ${n(cf.summedDailyUniques)} daily visits added up.`,
    "Someone who visits on three days counts three times in that second number.",
    `${n(cf.totalRequests)} requests reached the site in total.`,
  ];
  if (cf.topCountries.length) {
    lines.push("", `Busiest places: ${cf.topCountries.map(([c, r]) => `${c} ${n(r)}`).join(", ")}.`);
  }
  return lines;
}

export function formatWebsite(site, intents) {
  const lines = ["Tracked visitor activity"];
  lines.push(site
    ? `${n(site.visitors)} people viewed ${n(site.views)} pages on enviouswispr.com.`
    : `Visitor figures were ${UNAVAILABLE} when this digest ran.`);
  // NOT "of them". `intents` counts download EVENTS - on-site clicks plus
  // off-site doorway redirects - so it is neither a headcount nor a subset of
  // the visitors above, and it can legitimately exceed them. Saying "of them"
  // claimed both, and a sentence that overstates what a number means is the
  // same defect class as a wrong number.
  lines.push(intents == null
    ? `Downloads started was ${UNAVAILABLE}.`
    : `${n(intents)} downloads were started, counting on-site clicks and off-site links together.`);
  lines.push("", "The visitor figures count only people whose browser runs our analytics, so they read lower than the traffic figures above.");
  return lines;
}

export function formatDownloads(gh, sources, botsExcluded) {
  const lines = ["Downloads"];
  lines.push(gh
    ? `${n(gh.totalDownloads)} downloads all time, across every release. Latest release is ${gh.latestVersion}.`
    : `All-time download figures were ${UNAVAILABLE} when this digest ran.`);
  lines.push("", "Where this week's off-site downloads came from:", "```", formatSourceBreakdown(sources), "```");
  lines.push(botsExcluded == null
    ? `Bot downloads excluded: ${UNAVAILABLE}.`
    : `Bot downloads excluded this week: ${n(botsExcluded)}.`);
  return lines;
}

export function formatAppUsage(usage) {
  if (!usage) return ["App usage", `App usage figures were ${UNAVAILABLE} when this digest ran.`];
  return [
    "App usage",
    `${n(usage.active)} people used EnviousWispr this week.`,
    `${n(usage.fresh)} of them installed it for the first time.`,
    "",
    "Dev machines are excluded from both numbers.",
  ];
}

/** One embed per section, and a REFUSAL of any shape Discord would reject,
 * while that failure still belongs to one section rather than the payload. */
function toEmbed(lines) {
  if (!Array.isArray(lines) || lines.length < 2) {
    throw new TypeError("section formatter must return a title and body as string lines");
  }
  const checked = [];
  for (let i = 0; i < lines.length; i += 1) {
    // Indexed and read exactly ONCE: Array#every skips holes, and two reads of
    // the same index let an accessor answer one value to the check and another
    // to the consumer.
    if (!Object.hasOwn(lines, i)) {
      throw new TypeError("section formatter must return a title and body as string lines");
    }
    const line = lines[i];
    if (typeof line !== "string") {
      throw new TypeError("section formatter must return a title and body as string lines");
    }
    checked.push(line);
  }
  const [title, ...body] = checked;
  const description = body.join("\n");
  if (title.length === 0 || description.length === 0) {
    throw new TypeError("section formatter must return a non-empty title and description");
  }
  return {
    title,
    description,
    color: 0x7c3aed, // brand purple
    footer: { text: "EnviousWispr Weekly Digest" },
  };
}

// ----- Orchestration --------------------------------------------------------

/** Best-effort fixed notice for a run that produced no digest at all. Carries
 * no error text, status code or response body: it goes to a Discord channel,
 * and the exception surfaces through the trigger's non-2xx status. */
async function postFailureNotice(env, label, { fetchFn = fetch } = {}) {
  if (!env.DISCORD_WEBHOOK_URL) return;
  try {
    await deliverReport(env.DISCORD_WEBHOOK_URL, {
      content:
        `EnviousWispr Weekly Digest for ${label} could not be generated. ` +
        `Nothing was measured, so this is not a report of zero.`,
    }, { fetchFn });
  } catch (_) {
    // The caller's rethrow is what surfaces the failure. A failure notice that
    // itself fails must not replace the original error.
  }
}

/** Unwraps a settled outcome, returning `null` where the section failed, so a
 * formatter renders "temporarily unavailable" instead of a fabricated number. */
function valueOrNull(outcome, failures, name) {
  if (outcome.status === "fulfilled") return outcome.value;
  failures.push(`${name}: ${outcome.reason?.message || "failed"}`);
  return null;
}

/**
 * `deps` is a test-only injection seam; production passes nothing.
 * `deps.hogqlOpts` drives retry paths without sitting through real backoff,
 * `deps.fetchFn` intercepts Cloudflare/GitHub/Discord, `deps.now` pins the
 * window.
 */
export async function runDigest(env, deps = {}) {
  const hogqlOpts = { ...(deps.hogqlOpts || {}), workerLabel: WORKER_LABEL };
  const fetchFn = deps.fetchFn || fetch;
  const now = deps.now || new Date();

  // ---- Window. The ONLY whole-run fatal dependency: without it no section has
  // a period to measure, so there is nothing honest to post.
  let window;
  try {
    window = resolveWeekWindow(now);
  } catch (err) {
    await postFailureNotice(env, "the requested week", { fetchFn });
    throw err;
  }
  const label = formatDayRange(window);

  // ---- Dev-ID resolution. Needed ONLY by app usage, so its failure costs that
  // one section and nothing else. Daily-report makes this fatal to its whole
  // run and is right to, because both of its sections are app events measured
  // over the production population. Here, three sections never touch the dev
  // list, and this is the single most timeout-prone query in the run - an
  // unbounded whole-history scan. Inheriting the fatal contract would discard
  // three working sections for an app-only dependency.
  let prod = null;
  const failures = [];
  try {
    prod = productionClauseFor(await resolveDevIds(env, hogqlOpts));
  } catch (err) {
    failures.push(`dev_ids: ${err.message}`);
    console.log(`weekly_digest dev_ids failed, app usage unavailable: ${err.message}`);
  }

  // ---- Fan-out. PostHog work goes through the ONE limiter; Cloudflare and
  // GitHub are different APIs with no shared ceiling and run alongside it.
  const posthogTasks = [
    () => querySection(env, websiteSql(window.win), "website", hogqlOpts),
    () => querySection(env, downloadsSql(window.win), "downloads", hogqlOpts),
    () => querySection(env, downloadSourcesSql(window.win), "download_sources", hogqlOpts),
  ];
  if (prod) {
    posthogTasks.push(() => querySection(env, appUsageSql(prod, window.win), "app_usage", hogqlOpts));
  }

  const [posthogOutcome, cfOutcome, ghOutcome] = await Promise.allSettled([
    runLimited(posthogTasks.map((task) => async () => {
      try {
        return { status: "fulfilled", value: await task() };
      } catch (reason) {
        return { status: "rejected", reason };
      }
    }), CONCURRENCY_LIMIT),
    fetchCloudflareStats(env, window, { fetchFn }),
    fetchGitHubDownloads(env, { fetchFn }),
  ]);

  // A rejection here is a programming error in the limiter itself, not a query
  // failure: every task above already converts its own rejection to a settled
  // record. Fatal, and deliberately not absorbed as four unavailable sections.
  if (posthogOutcome.status === "rejected") {
    await postFailureNotice(env, label, { fetchFn });
    throw posthogOutcome.reason;
  }
  const settled = posthogOutcome.value;

  // EVERY EXTERNAL FIELD THIS WORKER READS, enumerated so the malformed-200
  // class stops being found an instance at a time. Whole-diff review raised it
  // in five consecutive rounds.
  //
  // The first version of this list enumerated the values that reach a
  // FORMATTER, and review immediately found two more instances inside it. That
  // was the wrong axis: `gh.totalDownloads` is validated, but it is DERIVED
  // from `rel.assets` and `asset.name`, and a malformed one of those silently
  // skipped a real asset and undercounted the total that was then checked and
  // found perfectly numeric. So the list is now of INPUT FIELDS, not output
  // values - every field parsed out of an external response, whether or not it
  // is printed:
  //
  //   PostHog rows      site.views/.visitors, downloads.intents/.bots_excluded,
  //                     usage.active/.fresh          readAggregate, finite numbers
  //                     sources[].n                  readGrouped, finite number
  //                     sources[].bucket             readGrouped, present, string or null
  //                     devIds[]                     shared resolveDevIds, non-empty strings
  //   Cloudflare        zone.totals, zone.byDay      arrays
  //                     g.sum.requests/.pageViews,
  //                     g.uniq.uniques               num()
  //                     c.clientCountryName          non-empty string
  //                     c.requests                   num()
  //   GitHub            releases                     array
  //                     rel.assets                   array (missing != empty)
  //                     asset.name                   string
  //                     asset.download_count         finite number
  //                     releases[0].tag_name         string
  //
  // Two rules, both learned the hard way. Check the SHAPE, never the magnitude:
  // a zero is data, a missing field is a broken contract, and every check above
  // has a two-way control in the tests proving a genuine zero still reports
  // zero. And when adding a metric, add every field it READS, not just the
  // number it prints.
  const read = (index, name) => {
    if (index >= settled.length) return null;
    const outcome = settled[index];
    if (outcome.status === "rejected") {
      // querySection already absorbed every EXPECTED transient failure into a
      // degraded flag, so a rejection here is a contract failure: auth, bad
      // SQL, a malformed response shape, or a programming error. Those stay
      // loud rather than becoming a quietly missing section.
      throw outcome.reason;
    }
    if (outcome.value.degraded) {
      failures.push(`${name}: degraded after retries`);
      return null;
    }
    return rowsToObjects(outcome.value.response);
  };

  /** An AGGREGATE query returns EXACTLY ONE row whose named columns are finite
   * numbers. `uniqExact` and `countIf` over an empty window still produce a row
   * of zeros, so anything else from a 200 is a malformed response, not a quiet
   * week.
   *
   * Checking the row COUNT alone is not enough, and this is the third review
   * round on one class - a 200 whose body is the wrong SHAPE. A response with
   * `columns: ["views"]` yields `{views: 226}`, `visitors` is `undefined`, and
   * the digest publishes "NaN people viewed 226 pages" while the run reports
   * SUCCESS. So the field names and their numeric-ness are checked here, at the
   * one place every aggregate passes through, rather than at each call site
   * where the next query would forget. */
  const readAggregate = (index, name, fields) => {
    const rows = read(index, name);
    if (rows === null) return null; // already degraded and recorded
    if (rows.length !== 1) {
      failures.push(`${name}: expected exactly 1 aggregate row, got ${rows.length}`);
      return null;
    }
    const row = rows[0];
    const bad = fields.filter((f) => typeof row[f] !== "number" || !Number.isFinite(row[f]));
    if (bad.length) {
      failures.push(`${name}: missing or non-numeric ${bad.join(", ")}`);
      return null;
    }
    return row;
  };

  /** The GROUP BY counterpart. Zero rows is a LEGITIMATE empty week here, which
   * is why it does not go through readAggregate - but each row still has to be
   * the exact shape the formatter will read.
   *
   * BOTH columns are checked, and the bucket check is the subtle one. `bucket`
   * may legitimately be NULL - PostHog returns null for an absent property, and
   * sourceLabel deliberately renders that as "Other". An OMITTED or RENAMED
   * column also arrives as undefined and would take the same "Other" branch,
   * publishing a confident attribution for a query whose shape had changed. So
   * the check is on PRESENCE plus type, never on truthiness, which cannot tell
   * "no source recorded" from "the column is gone". */
  const readGrouped = (index, name) => {
    const rows = read(index, name);
    if (rows === null) return null;
    const bad = rows.find(
      (r) =>
        typeof r.n !== "number" ||
        !Number.isFinite(r.n) ||
        !Object.hasOwn(r, "bucket") ||
        !(typeof r.bucket === "string" || r.bucket === null)
    );
    if (bad) {
      failures.push(`${name}: malformed row shape`);
      return null;
    }
    return rows;
  };

  let site, downloads, sources, usage;
  try {
    site = readAggregate(0, "website", ["views", "visitors"]);
    downloads = readAggregate(1, "downloads", ["intents", "bots_excluded"]);
    sources = readGrouped(2, "download_sources");
    usage = prod ? readAggregate(3, "app_usage", ["active", "fresh"]) : null;
  } catch (err) {
    await postFailureNotice(env, label, { fetchFn });
    throw err;
  }

  const cf = valueOrNull(cfOutcome, failures, "cloudflare");
  const gh = valueOrNull(ghOutcome, failures, "github");

  const payload = {
    content: `EnviousWispr Weekly Digest, ${label}`,
    embeds: [
      toEmbed(formatCloudflare(cf)),
      toEmbed(formatWebsite(site, downloads ? downloads.intents : null)),
      toEmbed(formatDownloads(gh, sources, downloads ? downloads.bots_excluded : null)),
      toEmbed(formatAppUsage(usage)),
    ],
  };

  // Validated and sent as ONE object. An over-budget payload throws here with
  // zero requests made: the digest is sent whole or not at all.
  await deliverReport(env.DISCORD_WEBHOOK_URL, payload, { fetchFn });

  // The founder has the digest; the trigger still has to fail, or a section
  // that silently stopped working would look like a healthy run forever.
  if (failures.length) {
    throw new Error(`weekly digest delivered with unavailable sections - ${failures.join("; ")}`);
  }
  return payload.content;
}
