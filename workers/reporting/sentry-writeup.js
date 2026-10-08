// Daily-only policy (#3547). The weekly release-scoped section stays separate.
import { discoverAggregate, issueList, SentryShapeError } from "../shared/sentry.js";
import { runLimited } from "../shared/posthog.js";
import { classifyProblem, ERROR_CATEGORIES, parseReleaseVersion, windowInstant } from "./sentry-section.js";

const QUERY = "(event.type:error OR event.type:default) level:[error,fatal]";
const COHORTS = ["release", "development", "unknown"];
const COHORT_LABELS = { release: "Customer releases", development: "Developer builds", unknown: "Unknown build" };
const PLATFORM_LABELS = { mac: "Mac", android: "Android" };
const GROUP_FIELDS = ["issue", "environment", "app.build_type", "count()", "count_unique(user)"];
const MATRIX_FIELDS = ["issue", "environment", "app.build_type", "release", "error.category", "level", "count()"];
const HEAD_FIELDS = ["environment", "app.build_type", "count()", "count_unique(user)"];
const PAGE_LIMIT = 2;
const DESCRIPTION_BUDGET = 3800;

function count(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new SentryShapeError("daily_writeup", "invalid count");
  }
  return value;
}

function add(a, b) {
  const sum = a + b;
  if (!Number.isSafeInteger(sum)) throw new SentryShapeError("daily_writeup", "count overflow");
  return sum;
}

function cohort(row) {
  if (row["app.build_type"] === "debug" || row.environment === "development") return "development";
  if (row.environment === "production" && row["app.build_type"] === "release") return "release";
  return "unknown";
}

function issueIdentity(row) {
  const id = row["issue.id"];
  const shortId = row.issue;
  if (!Number.isSafeInteger(id) || id <= 0 || typeof shortId !== "string"
      || !/^[A-Z0-9_-]{1,80}$/.test(shortId)) {
    throw new SentryShapeError("daily_writeup", "invalid issue identity");
  }
  return { id, shortId };
}

function measure(rows, complete) {
  let events = 0;
  let users = 0;
  for (const row of rows) {
    const n = count(row["count()"]);
    const u = count(row["count_unique(user)"]);
    if (u > n) throw new SentryShapeError("daily_writeup", "users exceed events");
    events = add(events, n);
    users = Math.max(users, u);
  }
  return { events, users, eventsExact: complete, usersExact: complete && rows.length <= 1 };
}

function grouped(rows, complete, byIssue) {
  const result = new Map(COHORTS.map((c) => [c, new Map()]));
  const seen = new Set();
  for (const row of rows) {
    const identity = byIssue ? issueIdentity(row) : null;
    const key = JSON.stringify([identity?.id ?? null, row.environment ?? null, row["app.build_type"] ?? null]);
    if (seen.has(key)) throw new SentryShapeError("daily_writeup", "duplicate grouping row");
    seen.add(key);
    const bucket = result.get(cohort(row));
    const entryKey = identity?.id ?? "headline";
    const entry = bucket.get(entryKey) || { identity, rows: [] };
    if (identity && entry.identity.shortId !== identity.shortId) {
      throw new SentryShapeError("daily_writeup", "issue identity changed");
    }
    entry.rows.push(row);
    bucket.set(entryKey, entry);
  }
  for (const bucket of result.values()) {
    for (const entry of bucket.values()) entry.measure = measure(entry.rows, complete);
  }
  return result;
}

async function pages(reader, env, params, opts, field) {
  const rows = [];
  const cursors = new Set();
  let cursor = null;
  let complete = false;
  for (let page = 0; page < PAGE_LIMIT; page += 1) {
    const data = await reader(env, { ...params, cursor, includeCursor: true }, opts);
    rows.push(...data[field]);
    if (!data.truncated) { complete = true; break; }
    if (!data.nextCursor) break;
    if (cursors.has(data.nextCursor)) throw new SentryShapeError(params.queryName, "pagination cursor repeated");
    cursors.add(data.nextCursor);
    cursor = data.nextCursor;
  }
  return { rows, complete };
}

function aggregateParams(queryName, fields, start, end, sort = "-count()") {
  return {
    queryName, fields,
    requiredFields: fields.map((f) => f === "issue" ? "issue.id" : f),
    query: QUERY, start, end, sort, perPage: 100,
  };
}

// Caller supplies one calendar snapshot; this module has no clock or vendor
// preflight. Ten pages maximum, two transport attempts/page, one later post.
export async function fetchSentryWriteup(env, window, opts = {}) {
  const { startISO, endISO, priorStartISO } = window;
  const startMs = windowInstant(startISO);
  const endMs = windowInstant(endISO);
  const priorMs = windowInstant(priorStartISO);
  if (!(priorMs < startMs && startMs < endMs)) throw new TypeError("invalid write-up window");
  const task = (name, fields, start, end) => () => pages(
    discoverAggregate, env, aggregateParams(name, fields, start, end), opts, "rows"
  );
  const headline = (name, start, end) => async () => {
    const data = await discoverAggregate(env, aggregateParams(name, HEAD_FIELDS, start, end), opts);
    if (data.truncated) throw new SentryShapeError(name, "headline incomplete");
    return data.rows;
  };
  const [current, prior, matrix, currentHead, priorHead, firstSeen] = await runLimited([
    task("writeup_current_issues", GROUP_FIELDS, startISO, endISO),
    task("writeup_prior_issues", GROUP_FIELDS, priorStartISO, startISO),
    task("writeup_build_matrix", MATRIX_FIELDS, startISO, endISO),
    headline("writeup_current_headline", startISO, endISO),
    headline("writeup_prior_headline", priorStartISO, startISO),
    () => pages(issueList, env, {
      queryName: "writeup_first_seen", query: "issue.category:error firstSeen:>=" + startISO + " firstSeen:<" + endISO,
      start: startISO, end: endISO, limit: 100,
    }, opts, "issues"),
  ], 2);

  const currentGroups = grouped(current.rows, current.complete, true);
  const priorGroups = grouped(prior.rows, prior.complete, true);
  const heads = grouped(currentHead, true, false);
  const previousHeads = grouped(priorHead, true, false);
  const newIds = new Set(firstSeen.rows.filter((r) => {
    const ms = Date.parse(r.firstSeen);
    return ms >= startMs && ms < endMs;
  }).map((r) => r.shortId));
  const metadata = new Map();
  const matrixKeys = new Set();
  for (const row of matrix.rows) {
    const identity = issueIdentity(row);
    count(row["count()"]);
    const key = JSON.stringify([identity.id, row.environment ?? null, row["app.build_type"] ?? null,
      row.release ?? null, row["error.category"] ?? null, row.level ?? null]);
    if (matrixKeys.has(key)) throw new SentryShapeError("writeup_build_matrix", "duplicate matrix row");
    matrixKeys.add(key);
    const bucketKey = cohort(row) + ":" + identity.id;
    const info = metadata.get(bucketKey) || { labels: new Set(), versions: new Set(), fatal: false };
    const category = row["error.category"];
    const safeCategory = typeof category === "string" && Object.hasOwn(ERROR_CATEGORIES, category) ? category : "";
    info.labels.add(classifyProblem({ category: safeCategory, level: row.level }).label);
    const version = parseReleaseVersion(row.release);
    info.versions.add(version ? version.join(".") : "unknown version");
    info.fatal ||= row.level === "fatal";
    metadata.set(bucketKey, info);
  }

  const sections = COHORTS.map((c) => {
    const now = heads.get(c).get("headline")?.measure || measure([], true);
    const before = previousHeads.get(c).get("headline")?.measure || measure([], true);
    const entries = [...currentGroups.get(c).values()];
    const oldEntries = priorGroups.get(c);
    if (current.complete) {
      const events = entries.reduce((n, e) => add(n, e.measure.events), 0);
      if (events !== now.events) throw new SentryShapeError("writeup_current_issues", "issue/headline totals disagree");
    }
    if (prior.complete) {
      const events = [...oldEntries.values()].reduce((n, e) => add(n, e.measure.events), 0);
      if (events !== before.events) throw new SentryShapeError("writeup_prior_issues", "issue/headline totals disagree");
    }
    const problems = entries.map((e) => {
      const previous = oldEntries.get(e.identity.id)?.measure || measure([], prior.complete);
      const info = metadata.get(c + ":" + e.identity.id);
      return {
        ...e.identity, ...e.measure, previous,
        labels: info ? [...info.labels] : ["reported error"],
        versions: info ? [...info.versions].sort() : ["version detail unavailable"],
        fatal: info?.fatal || false,
        isNew: newIds.has(e.identity.shortId) ? true : firstSeen.complete ? false : null,
      };
    }).sort((a, b) => Number(b.fatal) - Number(a.fatal) || b.events - a.events || a.id - b.id);
    return { cohort: c, current: now, prior: before, problems };
  });
  return {
    sections,
    issuesComplete: current.complete,
    priorComplete: prior.complete,
    buildsComplete: matrix.complete,
    newnessComplete: firstSeen.complete,
  };
}

function numberText(value, exact) { return (exact ? "" : "at least ") + value; }
function noun(value, name) { return name + (value === 1 ? "" : "s"); }
function change(current, previous) {
  const n = current - previous;
  return n === 0 ? "unchanged" : (n > 0 ? "+" : "") + n;
}

export function formatSentryWriteup(data, { platform, date }) {
  if (!Object.hasOwn(PLATFORM_LABELS, platform) || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    throw new TypeError("invalid write-up identity");
  }
  const footer = "Counts are reports received by Sentry; users are Sentry-reported identities.";
  const blocks = data.sections.map((s) => {
    const lines = ["**" + COHORT_LABELS[s.cohort] + "**",
      s.current.events + " " + noun(s.current.events, "event") + " (" + change(s.current.events, s.prior.events) + " vs prior day); "
        + numberText(s.current.users, s.current.usersExact) + " reported " + noun(s.current.users, "user") + " ("
        + (s.current.usersExact && s.prior.usersExact ? change(s.current.users, s.prior.users) + " vs prior day" : "user change unavailable") + ")."];
    if (!s.problems.length) lines.push(s.current.events === 0 ? "No crash/error events received." : "Problem detail unavailable.");
    return { section: s, lines, shown: 0 };
  });
  const notes = [];
  if (!data.issuesComplete || !data.priorComplete) notes.push("Problem lists are incomplete; affected rows use lower bounds and omit unsupported changes.");
  if (!data.buildsComplete) notes.push("Version/type details are incomplete.");
  if (!data.newnessComplete) notes.push("Newness is unconfirmed for issues absent from the returned first-seen list.");
  const description = () => blocks.map((b) => b.lines.join("\n")).join("\n\n")
    + (notes.length ? "\n\n" + notes.join("\n") : "") + "\n\n" + footer;
  // Reserve room for an explicit omission line per cohort, never silent cuts.
  const ranks = Math.max(0, ...blocks.map((b) => b.section.problems.length));
  for (let rank = 0; rank < ranks; rank += 1) {
    for (const block of blocks) {
      const p = block.section.problems[rank];
      if (!p || block.stopped) continue;
      const novelty = p.isNew === true ? "new; " : p.isNew === null ? "newness unknown; " : "";
      const delta = p.eventsExact && p.previous.eventsExact ? "; " + change(p.events, p.previous.events) + " events vs prior" : "; event change unavailable";
      const versions = p.versions.slice(0, 3).join(", ") + (p.versions.length > 3 ? ", other versions" : "");
      const labels = p.labels.slice(0, 2).join(" / ");
      const line = "[" + p.shortId + "](https://envious-labs-llc.sentry.io/issues/" + p.id + "/): " + labels
        + " | " + novelty + numberText(p.events, p.eventsExact) + " " + noun(p.events, "event") + "; "
        + numberText(p.users, p.usersExact) + " reported " + noun(p.users, "user") + delta + "; " + versions;
      block.lines.push(line);
      if (description().length > DESCRIPTION_BUDGET - 480) { block.lines.pop(); block.stopped = true; continue; }
      block.shown += 1;
    }
  }
  for (const b of blocks) {
    const remaining = b.section.problems.length - b.shown;
    if (remaining) b.lines.push("Showing " + b.shown + " of " + b.section.problems.length + " returned problems; " + remaining + " more are included in the headline.");
  }
  const text = description();
  if (text.length > DESCRIPTION_BUDGET) throw new TypeError("write-up exceeds content budget");
  return {
    content: "Sentry morning review | " + PLATFORM_LABELS[platform] + " | " + date,
    embeds: [{ title: "Recorded crashes and errors", description: text }],
  };
}
