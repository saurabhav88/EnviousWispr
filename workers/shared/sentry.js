/**
 * Sentry read transport, shared by every worker that queries Sentry (issue #1965).
 *
 * CONSUMERS: workers/daily-report, workers/weekly-digest, workers/sentry-triage.
 *
 * DEPLOY RULE: Cloudflare bundles each worker separately, so editing this file
 * changes NOTHING in production until EVERY consumer above is redeployed
 * (`npx wrangler deploy` from each worker directory). A merged PR does not
 * deploy; a `git revert` does not roll back. See workers/shared/README.md.
 *
 * Infrastructure ONLY - HTTP, authentication, the retryable-status set, bounded
 * retry, deadline enforcement, response-shape validation and row normalization.
 *
 * NOT here, deliberately: which window to ask about, which releases count, what
 * an `error.category` MEANS, how to word a section, or when something is worth
 * buzzing about. Every one of those is a product judgement and belongs to the
 * worker that owns the report - `workers/reporting/sentry-section.js` for the
 * two digests, `workers/sentry-triage/src/index.js` for the spike card. This is
 * the same line `workers/shared/README.md` draws for posthog.js and discord.js.
 *
 * WHY THIS IS NOT AN EXTENSION OF posthog.js: different vendor, different
 * limiter, different retry class. A Sentry request does not queue behind
 * PostHog's three-query project allowance and does not inherit its
 * up-to-30-second queue-wait backoff. Sharing that module's retry would have
 * made a Sentry 429 wait 12-45 seconds for a limit that resets far sooner, and
 * would have let a Sentry call consume a PostHog concurrency slot it never
 * needed. Measured Sentry limits on this account: 30 requests per window,
 * 15 concurrent (`x-sentry-rate-limit-*` response headers, 2026-08-06).
 *
 * Privacy: this module logs query NAMES and HTTP statuses only. Never a response
 * body, never a user id, never the auth token, never a URL (the query string
 * carries the search terms).
 */

/** Sentry's US region. Every EnviousWispr project lives here, and omitting the
 * region produces a 404 rather than a redirect - a failure that reads as "no
 * such issue" rather than "wrong host" (sentry-operations.md RULE:
 * pass-region-url). */
const SENTRY_REGION_URL = "https://us.sentry.io";

/** Retried only on this documented class. A 401/403 is a credential problem and
 * a 400 is a malformed query; retrying either wastes the window and hides the
 * real cause behind a timeout.
 *
 * 403 is deliberately ABSENT even though it is the failure most likely to be
 * seen first: the org-wide events endpoint answers 403 to a token that lacks
 * org scope, and that is a permanent configuration state, not a blip. Measured
 * 2026-08-06: `sentry-triage-worker-token` and `sentry-auth-token` both 403 on
 * `/organizations/<org>/events/` while the admin token succeeds in ~300ms. */
const RETRYABLE_SENTRY_STATUSES = new Set([429, 500, 502, 503, 504]);

/** TWO attempts total, not three, and the reason is a platform ceiling rather
 * than anything about Sentry.
 *
 * Cloudflare allows 50 subrequests per Worker invocation. The daily report's
 * designed worst case - every request retrying to exhaustion - is
 * (1 preflight + 7 adoption + 2 scorecard + 1 GitHub) x 3 + Sentry + 1 Discord.
 * At three Sentry attempts that is 49, one below the cap, so a single future
 * query anywhere in the worker would silently push the whole report over. At
 * two it is 44.
 *
 * The trade is one-sided. Sentry's per-window limit resets fast, the digest
 * runs again tomorrow, and losing the Sentry section for one day costs a
 * section; blowing the subrequest cap costs the ENTIRE report, adoption and
 * scorecard included, on exactly the day something was wrong enough to make
 * Sentry rate-limit us. */
const RETRY_DELAY_MS = [1_000];

/** Per-request ceiling. A single Sentry read measured 243-973ms across every
 * query this repo issues, so 10s is generous headroom rather than a tuned
 * value - it exists to stop one wedged socket consuming a whole run, not to
 * express an expectation about latency. */
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Carries the query name and HTTP status alongside the message, so a caller can
 * distinguish an exhausted transient failure (which a degradable section may
 * absorb) from an auth failure, a malformed query or a bad response shape
 * (which must stay loud). Mirrors PostHogQueryError deliberately: the two
 * transports are separate, but a consumer reasoning about failure classes
 * should not have to learn two vocabularies. */
export class SentryQueryError extends Error {
  constructor(queryName, status) {
    super(`Sentry query ${queryName} HTTP ${status}`);
    this.name = "SentryQueryError";
    this.queryName = queryName;
    this.status = status;
  }
}

/** The response arrived and could not be trusted: unparseable, the wrong
 * container type, or missing the field-set every response carries. Separate
 * from SentryQueryError because it is NEVER retryable and never degradable to a
 * zero - a malformed body that reads as "no errors today" is the exact failure
 * the daily report exists not to produce. */
export class SentryShapeError extends Error {
  constructor(queryName, detail) {
    super(`Sentry query ${queryName} returned an unusable response: ${detail}`);
    this.name = "SentryShapeError";
    this.queryName = queryName;
  }
}

/** The caller's absolute deadline passed. The triage worker runs inside a
 * Cloudflare `waitUntil` that is cancelled ~30s after the response, so its
 * lookups are bounded by wall clock, not by attempt count. */
export class SentryDeadlineError extends Error {
  constructor(queryName) {
    super(`Sentry query ${queryName} exceeded its deadline`);
    this.name = "SentryDeadlineError";
    this.queryName = queryName;
  }
}

/** The request failed before any response arrived.
 *
 * EXISTS TO STOP A MESSAGE CROSSING THE PRIVACY BOUNDARY, not to add a category.
 * Every other failure here is already sanitized into a fixed sentence, but a raw
 * `fetch` rejection was rethrown unchanged - and both digest workers put
 * `err.message` straight into their HTTP trigger response, while the weekly one
 * also records it in its failure summary. A runtime or fetch-implementation
 * error carrying a URL fragment would therefore have escaped, and the URL is
 * the one part of a Sentry request that contains search terms. The original
 * error is deliberately NOT attached: an unreachable field is not a boundary. */
export class SentryNetworkError extends Error {
  constructor(queryName) {
    super(`Sentry query ${queryName} failed before receiving a response`);
    this.name = "SentryNetworkError";
    this.queryName = queryName;
  }
}

/** Identifies the calling worker in Sentry's audit log and in Cloudflare logs.
 *
 * REQUIRED, never defaulted, for the same reason `hogql` requires it: a default
 * would file one worker's reads under another worker's name, which reads as
 * correct in every place a human would look. */
function requireWorkerLabel(workerLabel) {
  if (typeof workerLabel !== "string" || workerLabel.length === 0) {
    throw new TypeError("Sentry transport requires a non-empty workerLabel");
  }
  return workerLabel;
}

function requireConfig(env) {
  const org = env?.SENTRY_ORG;
  const token = env?.SENTRY_AUTH_TOKEN;
  // Checked separately so the failure names WHICH piece is missing. A combined
  // "Sentry is not configured" sends someone to rotate a token that was fine.
  if (typeof org !== "string" || org.length === 0) {
    throw new TypeError("SENTRY_ORG is not configured");
  }
  if (typeof token !== "string" || token.length === 0) {
    throw new TypeError("SENTRY_AUTH_TOKEN is not configured");
  }
  return { org, token, regionUrl: env.SENTRY_REGION_URL || SENTRY_REGION_URL };
}

/** One HTTP attempt, bounded by BOTH a per-request timeout and the caller's
 * absolute deadline. Modelled on sentry-triage's `fetchBefore`, which already
 * had to solve this for the webhook path. */
async function fetchBounded(url, token, { fetchFn, deadlineAt, requestTimeoutMs, queryName }) {
  const remainingMs = deadlineAt === null ? requestTimeoutMs : deadlineAt - Date.now();
  if (remainingMs <= 0) throw new SentryDeadlineError(queryName);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, Math.min(requestTimeoutMs, remainingMs)));
  try {
    return await fetchFn(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: controller.signal,
    });
  } catch (_) {
    // An abort is indistinguishable from a network error at the catch site
    // unless the signal is consulted, and reporting a deadline as a network
    // fault would send the reader looking for an outage that never happened.
    if (controller.signal.aborted) throw new SentryDeadlineError(queryName);
    // The caught error is DISCARDED rather than wrapped. See SentryNetworkError.
    throw new SentryNetworkError(queryName);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetches `url` with bounded retry and returns the parsed JSON body plus the
 * response headers.
 *
 * The URL is never logged: it carries the search query, and a Sentry search
 * query can name a release, an issue or a user-scoped filter.
 */
async function requestJson(url, queryName, config, opts) {
  const {
    fetchFn = fetch,
    sleepFn = sleep,
    deadlineAt = null,
    requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    workerLabel,
  } = opts;
  const label = requireWorkerLabel(workerLabel);
  const maxAttempts = RETRY_DELAY_MS.length + 1;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const res = await fetchBounded(url, config.token, {
      fetchFn,
      deadlineAt,
      requestTimeoutMs,
      queryName,
    });

    if (res?.ok) {
      let body;
      try {
        body = await res.json();
      } catch (_) {
        // A 200 whose body is not JSON is a shape failure, never a transient
        // one. Retrying it would burn the window and then report the same
        // thing, with the original cause three attempts further away.
        throw new SentryShapeError(queryName, "body was not JSON");
      }
      return { body, headers: res.headers };
    }

    const status = res?.status;
    // Draining the failed body matters specifically because a retry immediately
    // opens a NEW outbound request: an uncancelled body holds its Cloudflare
    // subrequest connection open, and enough of those across retries could
    // exhaust the account's outbound-connection ceiling. Same reasoning, and
    // the same best-effort swallow, as posthog.js.
    if (res?.body) {
      try {
        await res.body.cancel();
      } catch (_) {
        // The status remains the authoritative failure; a failed cancel must
        // not mask it.
      }
    }

    if (attempt === maxAttempts || !RETRYABLE_SENTRY_STATUSES.has(status)) {
      throw new SentryQueryError(queryName, status);
    }
    // Checked BEFORE sleeping, not after: sleeping past a deadline and then
    // discovering it consumes the caller's entire remaining budget in a wait
    // that could never have produced an answer.
    if (deadlineAt !== null && Date.now() + RETRY_DELAY_MS[attempt - 1] >= deadlineAt) {
      throw new SentryDeadlineError(queryName);
    }
    console.log(`${label} sentry ${queryName} retrying after HTTP ${status}`);
    await sleepFn(RETRY_DELAY_MS[attempt - 1]);
  }
}

/** True when Sentry says another page exists.
 *
 * TWO signals, because neither alone is sufficient. The Link header is the
 * documented one, but it is ABSENT entirely on a single-page Discover response
 * (measured 2026-08-06: empty Link on a 9-row result), so its absence proves
 * nothing about a FULL page. A full page is therefore treated as "there may be
 * more" regardless. Over-reporting here is safe: the only consequence is the
 * section printing its honest "breakdown limited to the top N" wording. */
function hasMorePages(headers, rowCount, perPage) {
  if (rowCount >= perPage) return true;
  const link = headers?.get?.("link") || "";
  return /rel="next"[^,]*results="true"/.test(link);
}

/**
 * Runs ONE Discover aggregate against `/organizations/<org>/events/`.
 *
 * Returns `{ rows, fields, truncated }`. `rows` are plain objects keyed by the
 * field names Sentry returned; this module does not rename, coerce or default
 * any value, because a defaulted metric is indistinguishable from a measured
 * one by the time it reaches a sentence.
 *
 * THE SHAPE CHECK IS ON `meta.fields`, NOT ON THE ROWS, and that is the whole
 * point of it. Zero rows is a legitimate answer - a day with no errors is the
 * outcome we want - so any per-row validation is skipped exactly when a
 * malformed empty body arrives, which is the case that would otherwise render
 * as "no errors today" (#1589's column-set lesson, hit again here). `meta.fields`
 * is present on both a populated and an empty response (measured 2026-08-06),
 * so it is the one check an empty answer cannot slip past.
 *
 * `requiredFields` is the caller's list of fields it will actually READ. It is
 * not derived from `fields` above, because Sentry does not echo every requested
 * field back under the same name: asking for `issue` yields rows carrying BOTH
 * `issue` and `issue.id`, while `meta.fields` names only `issue.id`. A check
 * built from the request would fail on a perfectly good response, and the
 * obvious repair - dropping the check - is how the empty-body case gets through.
 */
export async function discoverAggregate(env, params, opts = {}) {
  const config = requireConfig(env);
  const {
    queryName,
    fields,
    requiredFields = [],
    query = null,
    sort = null,
    perPage = 100,
    start = null,
    end = null,
    statsPeriod = null,
    environment = null,
  } = params;

  if (typeof queryName !== "string" || queryName.length === 0) {
    throw new TypeError("discoverAggregate requires a queryName");
  }
  if (!Array.isArray(fields) || fields.length === 0) {
    throw new TypeError(`${queryName}: discoverAggregate requires at least one field`);
  }
  // Exactly one window form. Sending both lets Sentry choose, and which one it
  // honours is not something this code should be guessing about when the answer
  // becomes a sentence the founder reads as "yesterday".
  const hasAbsolute = start !== null && end !== null;
  if (hasAbsolute === (statsPeriod !== null)) {
    throw new TypeError(`${queryName}: pass either start+end or statsPeriod, not both or neither`);
  }

  const url = new URL(`${config.regionUrl}/api/0/organizations/${config.org}/events/`);
  if (env.SENTRY_PROJECT_ID) url.searchParams.set("project", String(env.SENTRY_PROJECT_ID));
  for (const field of fields) url.searchParams.append("field", field);
  if (query !== null) url.searchParams.set("query", query);
  if (sort !== null) url.searchParams.set("sort", sort);
  if (environment !== null) url.searchParams.set("environment", environment);
  if (hasAbsolute) {
    url.searchParams.set("start", start);
    url.searchParams.set("end", end);
  } else {
    url.searchParams.set("statsPeriod", statsPeriod);
  }
  url.searchParams.set("per_page", String(perPage));

  const { body, headers } = await requestJson(url.toString(), queryName, config, opts);

  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new SentryShapeError(queryName, "body was not an object");
  }
  const meta = body.meta;
  if (meta === null || typeof meta !== "object" || Array.isArray(meta)) {
    throw new SentryShapeError(queryName, "meta was missing");
  }
  const metaFields = meta.fields;
  if (metaFields === null || typeof metaFields !== "object" || Array.isArray(metaFields)) {
    throw new SentryShapeError(queryName, "meta.fields was missing");
  }
  for (const required of requiredFields) {
    if (!Object.hasOwn(metaFields, required)) {
      throw new SentryShapeError(queryName, `meta.fields is missing ${required}`);
    }
  }
  const rows = body.data;
  if (!Array.isArray(rows)) {
    throw new SentryShapeError(queryName, "data was not an array");
  }
  for (let i = 0; i < rows.length; i += 1) {
    // Object.hasOwn, not a truthiness test: `data: [null]` and a sparse array
    // both survive a length check and then yield `undefined` to a formatter,
    // which renders as the string "undefined" beside a real number.
    if (!Object.hasOwn(rows, i) || rows[i] === null || typeof rows[i] !== "object") {
      throw new SentryShapeError(queryName, `data row ${i} was not an object`);
    }
  }

  return {
    rows,
    fields: Object.keys(metaFields),
    truncated: hasMorePages(headers, rows.length, perPage),
  };
}

/**
 * Lists issues from `/projects/<org>/<project>/issues/`.
 *
 * Used for exactly one thing today: the set of issues whose FIRST-EVER event
 * falls inside the window, which is the only honest source for a "new" badge.
 *
 * A caller must NOT read `count` or `userCount` from these rows as window
 * figures. They are LIFETIME totals and do not move with the window at all -
 * measured 2026-08-06, `statsPeriod=24h` and `statsPeriod=14d` both returned
 * `count=602 userCount=155` for the same issue. The window changes WHICH issues
 * come back, never their numbers. Every per-window number in the digest comes
 * from `discoverAggregate` instead, and this comment is here because the two
 * endpoints look interchangeable and are not.
 *
 * `statsPeriod: ""` is passed deliberately: it suppresses the per-issue hourly
 * `stats` array, which is a quarter of the payload and is never read
 * (measured: 66,721B with stats, 49,710B without).
 */
export async function issueList(env, params, opts = {}) {
  const config = requireConfig(env);
  const { queryName, query = "", environment = null, limit = 100, start = null, end = null } = params;

  if (typeof queryName !== "string" || queryName.length === 0) {
    throw new TypeError("issueList requires a queryName");
  }
  // Both or neither. One alone silently falls back to the relative form, which
  // is the exact confusion this parameter was added to remove.
  if ((start === null) !== (end === null)) {
    throw new TypeError(`${queryName}: start and end must be supplied together`);
  }
  const project = env?.SENTRY_PROJECT_SLUG;
  if (typeof project !== "string" || project.length === 0) {
    throw new TypeError("SENTRY_PROJECT_SLUG is not configured");
  }

  const url = new URL(`${config.regionUrl}/api/0/projects/${config.org}/${project}/issues/`);
  url.searchParams.set("query", query);
  url.searchParams.set("limit", String(limit));
  if (start !== null) {
    url.searchParams.set("start", start);
    url.searchParams.set("end", end);
  } else {
    // `statsPeriod: ""` suppresses the per-issue hourly stats array. It is NOT
    // valid alongside start/end, which is why it sits in the else branch.
    url.searchParams.set("statsPeriod", "");
  }
  if (environment !== null) url.searchParams.set("environment", environment);

  const { body, headers } = await requestJson(url.toString(), queryName, config, opts);

  // This endpoint returns a BARE ARRAY, not a wrapper object, so it has no
  // `meta` to check and an empty array is genuinely indistinguishable from a
  // malformed empty one. That is acceptable HERE and would not be acceptable
  // for the aggregate: an empty new-issue set costs a badge, an empty aggregate
  // would print "no errors today" when the truth is unknown. The asymmetry is
  // deliberate, not an oversight.
  if (!Array.isArray(body)) {
    throw new SentryShapeError(queryName, "body was not an array");
  }
  const issues = [];
  for (let i = 0; i < body.length; i += 1) {
    if (!Object.hasOwn(body, i) || body[i] === null || typeof body[i] !== "object") {
      throw new SentryShapeError(queryName, `issue ${i} was not an object`);
    }
    const shortId = body[i].shortId;
    // A row without a shortId cannot be matched to an aggregate row, so it
    // would silently fail to badge. Refusing names the problem instead.
    if (typeof shortId !== "string" || shortId.length === 0) {
      throw new SentryShapeError(queryName, `issue ${i} had no shortId`);
    }
    // `firstSeen` is REQUIRED, not defaulted to null. Every caller uses it to
    // decide whether an issue is new, and a null would silently classify a
    // genuinely-new issue as old - a missing badge nobody would ever notice.
    const firstSeen = body[i].firstSeen;
    if (typeof firstSeen !== "string" || Number.isNaN(Date.parse(firstSeen))) {
      throw new SentryShapeError(queryName, `issue ${i} had no usable firstSeen`);
    }
    issues.push({
      shortId,
      firstSeen,
      level: typeof body[i].level === "string" ? body[i].level : null,
      title: typeof body[i].title === "string" ? body[i].title : null,
    });
  }

  return { issues, truncated: hasMorePages(headers, issues.length, limit) };
}

/** Exported so a caller's subrequest-budget arithmetic reads the REAL retry
 * maximum rather than restating a literal that can drift away from it. */
export const SENTRY_MAX_ATTEMPTS = RETRY_DELAY_MS.length + 1;

export { RETRYABLE_SENTRY_STATUSES, SENTRY_REGION_URL, DEFAULT_REQUEST_TIMEOUT_MS };
