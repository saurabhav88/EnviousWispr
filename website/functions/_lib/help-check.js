// In-app help check (#3275). The app splits a feedback message into concerns on the
// Mac and sends them here; this asks TypeSafe's Jev model, in at most two requests,
// which help section answers each concern, and returns suggestions the app may show.
// Every failure answers `send_feedback`: the app then sends the report unchanged.
// This Function logs counts only and stores nothing; TypeSafe receives the message
// text for inference.
//
// Proven design, thresholds and request wording: docs/audits/2026-09-28-issue-3275-
// benchmark/ (jev_batch.py, e2e_grade.py) and the #3275 plan's Gate 2 sections.

import CATALOG from "./help-catalog.js";

export const TYPESAFE_URL = "https://api.typesafe.ai/v1/systemone";
// Pinned, not an alias: a silent model change would move every score the gates rely on.
export const JEV_MODEL = "jev-1.13.0";
export const NO_MATCH = "__no_match__";
// Both TypeSafe requests share this budget; the app's own 7.0 s limit covers the rest.
export const INFERENCE_DEADLINE_MS = 2000;
export const MAX_ISSUES = 5;
// FeedbackDraft (Sources/EnviousWisprServices/FeedbackReporter.swift): 4,000 characters
// as the form counts them, and Sentry's 4,096 code points.
export const MAX_MESSAGE_CHARACTERS = 4000;
export const MAX_MESSAGE_CODE_POINTS = 4096;
export const MAX_BODY_BYTES = 64 * 1024;
const MAX_SUMMARY_LENGTH = 300;
const KINDS = ["bug", "how_to", "feature_request", "other"];
const MODES = ["decomposed", "whole_message_always_send"];
const VERSION_PATTERN = /^[A-Za-z0-9._+-]{1,64}$/;

export const DECISION_VERSION = "2026-09-28.1";
// e2e_grade.py gates: page p, page confidence, section p, section confidence,
// resolves, page-link p. `useful` must agree with the page pick: every card in the
// real-endpoint run already had useful >= 0.5, so it removes none and blocks a reply
// that says "no useful article" while picking one. `covered` gates suppression only: the whole issue list must
// cover the message (coverage_run.py: at 0.5 it caught 55 of 57 lists missing a real
// concern and blocked about 1 in 7 complete lists, which then send).
export const GATES = { pageP: 0.5, pageConf: 0.5, useful: 0.5, sectionP: 0.5, sectionConf: 0.7, resolves: 0.7, pageLinkP: 0.8, covered: 0.5 };
export const THRESHOLD_VERSION = "g3-0.5-0.5-u0.5-0.5-0.7-0.7-0.8-c0.5";

// Candidates exclude never_intervene pages: they are never offered as cards.
const CANDIDATES = CATALOG.articles.filter((a) => a.deflection !== "never_intervene");
const CANDIDATE_BY_SLUG = new Map(CANDIDATES.map((a) => [a.slug, a]));
const PAGE_STATE = CANDIDATES.map(({ slug, title, description }) => ({ slug, title, description }));

// Kill switch. Missing or unknown means disabled: the app sends the report as usual.
// This route is public and each check spends TypeSafe credit, so set it to anything
// but "disabled" only after the path-specific Cloudflare rate-limit rule for
// /api/app/help-check exists (#3275 release step).
export function helpCheckMode(env) {
  const mode = env?.HELP_CHECK_MODE;
  return mode === "enabled" || mode === "suggest_only" ? mode : "disabled";
}

function versions(request, coverage = null) {
  return {
    coverage,
    kb_version: CATALOG.catalogVersion,
    jev_model_version: JEV_MODEL,
    decomposition_version: request?.decomposition_version ?? null,
    decision_version: DECISION_VERSION,
    threshold_version: THRESHOLD_VERSION,
    app_version: request?.app_version ?? null,
  };
}

export function sendFeedback(reason, request = null) {
  return { v: 1, status: "send_feedback", reason, suppression_allowed: false, issues: [], ...versions(request) };
}

function graphemeCount(text) {
  let n = 0;
  for (const _ of new Intl.Segmenter("en", { granularity: "grapheme" }).segment(text)) n++;
  return n;
}

const isString = (v) => typeof v === "string";
const isOffset = (v) => Number.isInteger(v) && v >= 0;

// Returns { request, issues } for a valid body, or { reason } when the app should
// just send. `issues` are what Jev sees; `anchored` says the evidence is the exact
// text at its UTF-16 range, which a card needs before it may be marked solved.
export function validateRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body) || body.v !== 1) return { reason: "invalid_request" };
  const { original_message: message, mode, issues, overflow, decomposition_version, app_version } = body;
  if (!isString(message) || !message.trim()) return { reason: "invalid_request" };
  if ([...message].length > MAX_MESSAGE_CODE_POINTS || graphemeCount(message) > MAX_MESSAGE_CHARACTERS) {
    return { reason: "message_too_long" };
  }
  if (!MODES.includes(mode) || typeof overflow !== "boolean" || !Array.isArray(issues)) return { reason: "invalid_request" };
  if (!isString(decomposition_version) || !VERSION_PATTERN.test(decomposition_version)) return { reason: "invalid_request" };
  if (!isString(app_version) || !VERSION_PATTERN.test(app_version)) return { reason: "invalid_request" };
  const request = { mode, overflow, decomposition_version, app_version };

  if (mode === "whole_message_always_send") {
    if (issues.length !== 0) return { reason: "invalid_request" };
    return { request, issues: [{ id: "i0", summary: "", evidence: message, anchored: false }] };
  }

  if (issues.length > MAX_ISSUES) return { reason: "invalid_decomposition" };
  const out = [];
  for (const [k, issue] of issues.entries()) {
    if (!issue || typeof issue !== "object") return { reason: "invalid_decomposition" };
    const { id, summary, kind, evidence, start_utf16: start, end_utf16: end } = issue;
    if (id !== `i${k}` || !KINDS.includes(kind)) return { reason: "invalid_decomposition" };
    if (!isString(summary) || summary.length > MAX_SUMMARY_LENGTH) return { reason: "invalid_decomposition" };
    // A model-changed quote can even be longer than the message; it stays as an
    // unanchored concern (shown, never suppressible) rather than failing the check.
    if (!isString(evidence) || !evidence.trim() || evidence.length > MAX_MESSAGE_CODE_POINTS * 2) return { reason: "invalid_decomposition" };
    // The app sends a range only when it found the evidence in the message; a quote
    // the model changed (macOS 26 capitalises quotes) arrives without one.
    let anchored = false;
    if (start === null && end === null) {
      anchored = false;
    } else if (isOffset(start) && isOffset(end) && start < end && end <= message.length) {
      const span = message.slice(start, end);
      if (span === evidence) anchored = true;
      else if (span.toLowerCase() !== evidence.toLowerCase()) return { reason: "invalid_decomposition" };
    } else {
      return { reason: "invalid_decomposition" };
    }
    out.push({ id, summary, evidence, anchored });
  }
  return { request, issues: out };
}

const CONTEXT = " Read it in the context of the whole message in `feedback.text`, but answer only for this issue.";

export function buildPageRequest(message, issues) {
  const criteria = Object.fromEntries(CANDIDATES.map((a) => [a.slug, null]));
  criteria[NO_MATCH] =
    "No listed article would be useful for this issue, including test-only text or issues that merely share a word with an article.";
  const questions = {
    covered: {
      type: "noul",
      instructions:
        "Does `issues` include every distinct problem, question or request that the user raises in `feedback.text`? Background detail, things the user already tried, praise, thanks and greetings are not separate problems.",
      criteria: {
        true: "Every problem, question or request in the feedback appears in `issues`.",
        false: "At least one problem, question or request in the feedback is missing from `issues`.",
      },
    },
  };
  issues.forEach((_, k) => {
    questions[`page_${k}`] = {
      type: "choice",
      criteria,
      instructions:
        `Which article in \`articles\` would be most useful for \`issues[${k}]\` (its summary and the user's own words in evidence)? Use each article's title and description. An article about the current setting can help with a request to change that setting. A shared word alone is insufficient. Choose __no_match__ if none would help.` +
        CONTEXT,
    };
    questions[`useful_${k}`] = {
      type: "noul",
      instructions: `Would at least one article in \`articles\` give useful information about \`issues[${k}]\`?`,
      criteria: {
        true: "An article addresses this issue's feature, setting, or problem.",
        false: "Unrelated, or articles only share incidental words with it.",
      },
    };
  });
  return {
    model: JEV_MODEL,
    state: { feedback: { text: message }, issues: issues.map(({ id, summary, evidence }) => ({ id, summary, evidence })), articles: PAGE_STATE },
    questions,
  };
}

export function buildSectionRequest(message, issues, picks) {
  const pages = [...new Set(picks.filter(Boolean))].sort();
  const sections = pages.flatMap((slug) =>
    CANDIDATE_BY_SLUG.get(slug).sections.map((s) => ({ id: s.id, page: CANDIDATE_BY_SLUG.get(slug).title, heading: s.heading ?? "(intro)", text: s.text })),
  );
  const questions = {};
  picks.forEach((slug, k) => {
    if (!slug) return;
    const criteria = Object.fromEntries(CANDIDATE_BY_SLUG.get(slug).sections.map((s) => [s.id, null]));
    criteria[NO_MATCH] = "No listed section would be useful for this issue.";
    questions[`section_${k}`] = {
      type: "choice",
      criteria,
      instructions:
        `Which entry in \`sections\` would be most useful for \`issues[${k}]\`? Use its page, heading and text. A section about the current setting can help with a request to change that setting. A shared word alone is insufficient. Choose __no_match__ if none would help.` +
        CONTEXT,
    };
    questions[`resolves_${k}`] = {
      type: "noul",
      // Scoped to the one page section_k chooses from: `sections` also holds other
      // concerns' pages, and this score gates a card from THIS page.
      instructions: `Would the text of the section you would pick for \`issues[${k}]\` from the entries in \`sections\` whose page is ${JSON.stringify(CANDIDATE_BY_SLUG.get(slug).title)} actually resolve that issue? Say no when those sections only describe the same feature without the specific fix, when the user says they already tried what the text suggests, or when the issue is a bug the text does not describe.`,
      criteria: {
        true: "A section's text gives the specific answer, setting or fix this issue needs and the user has not already tried.",
        false: "On topic but no fix, already tried, or an undescribed bug.",
      },
    };
  });
  return {
    model: JEV_MODEL,
    state: { feedback: { text: message }, issues: issues.map(({ id, summary, evidence }) => ({ id, summary, evidence })), sections },
    questions,
  };
}

const isProbability = (v) => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;

// Reads one Choice answer from the raw wire shape; null unless every field is sound
// and the choice is one of the offered options.
function readChoice(answer, options) {
  if (!answer || answer.type !== "choice" || !isString(answer.choice) || !options.has(answer.choice)) return null;
  const p = answer.probabilities?.[answer.choice];
  if (!isProbability(p) || !isProbability(answer.confidence)) return null;
  return { choice: answer.choice, p, confidence: answer.confidence };
}

function readNoul(answer) {
  if (!answer || answer.type !== "noul" || !isProbability(answer.noul)) return null;
  return answer.noul;
}

class ReplyError extends Error {}

async function callJev(body, env, fetchImpl, deadlineAt, now) {
  const remaining = deadlineAt - now();
  if (remaining <= 0) throw new ReplyError("timeout");
  const controller = new AbortController();
  let timer;
  // Settles at the deadline even if a fetch or body read ignores the abort signal.
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new ReplyError("timeout"));
    }, remaining);
  });
  deadline.catch(() => {}); // Handled by the races below; never an unhandled rejection.
  try {
    const res = await Promise.race([
      fetchImpl(TYPESAFE_URL, {
        method: "POST",
        headers: { Authorization: `Bearer ${env.TYPESAFE_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: controller.signal,
      }),
      deadline,
    ]);
    if (res.status === 401 || res.status === 403) throw new ReplyError("config");
    if (res.status === 402 || res.status === 429) throw new ReplyError("unavailable");
    if (!res.ok) throw new ReplyError(`http_${res.status}`);
    let json;
    try {
      json = await Promise.race([res.json(), deadline]);
    } catch (error) {
      throw error instanceof ReplyError ? error : new ReplyError("bad_reply");
    }
    // A reply that lands after the shared budget is late even if it arrived whole.
    if (controller.signal.aborted || now() >= deadlineAt) throw new ReplyError("timeout");
    if (json?.model !== JEV_MODEL || !json.answers || typeof json.answers !== "object") throw new ReplyError("bad_reply");
    return json.answers;
  } catch (error) {
    if (error instanceof ReplyError) throw error;
    throw new ReplyError(controller.signal.aborted ? "timeout" : "network");
  } finally {
    clearTimeout(timer);
  }
}

// Runs the check. `fetchImpl` and `now` are injected so tests never call TypeSafe.
export async function runHelpCheck(body, env, { fetchImpl = fetch, now = Date.now } = {}) {
  const mode = helpCheckMode(env);
  if (mode === "disabled") return sendFeedback("disabled", null);
  const parsed = validateRequest(body);
  if (parsed.reason) return sendFeedback(parsed.reason, null);
  const { request, issues } = parsed;
  if (!env.TYPESAFE_API_KEY) return sendFeedback("config", request);
  if (issues.length === 0) return { v: 1, status: "ok", reason: "no_concerns", suppression_allowed: false, issues: [], ...versions(request) };

  const message = body.original_message;
  const deadlineAt = now() + INFERENCE_DEADLINE_MS;
  const pageOptions = new Set([...CANDIDATE_BY_SLUG.keys(), NO_MATCH]);
  let pageAnswers;
  try {
    pageAnswers = await callJev(buildPageRequest(message, issues), env, fetchImpl, deadlineAt, now);
  } catch (error) {
    return sendFeedback(error.message, request);
  }

  const coverage = readNoul(pageAnswers.covered);
  if (coverage === null) return sendFeedback("bad_reply", request);
  const pages = [];
  for (let k = 0; k < issues.length; k++) {
    const page = readChoice(pageAnswers[`page_${k}`], pageOptions);
    const useful = readNoul(pageAnswers[`useful_${k}`]);
    if (!page || useful === null) return sendFeedback("bad_reply", request);
    pages.push({ ...page, useful });
  }
  const picks = pages.map((pg) =>
    pg.choice !== NO_MATCH && pg.p >= GATES.pageP && pg.confidence >= GATES.pageConf && pg.useful >= GATES.useful ? pg.choice : null,
  );

  let sectionAnswers = {};
  if (picks.some(Boolean)) {
    try {
      sectionAnswers = await callJev(buildSectionRequest(message, issues, picks), env, fetchImpl, deadlineAt, now);
    } catch (error) {
      return sendFeedback(error.message, request);
    }
  }

  const results = [];
  for (let k = 0; k < issues.length; k++) {
    const page = pages[k];
    const scores = { page_p: page.p, page_confidence: page.confidence, useful: page.useful, section_p: null, section_confidence: null, resolves: null };
    const none = { id: issues[k].id, match_type: "none", page_slug: null, section_id: null, heading: null, text: null, url: null, deflection: null, scores, resolution_eligible: false, requires_send: true };
    const slug = picks[k];
    if (!slug) {
      results.push(none);
      continue;
    }
    const article = CANDIDATE_BY_SLUG.get(slug);
    const sectionOptions = new Set([...article.sections.map((s) => s.id), NO_MATCH]);
    const section = readChoice(sectionAnswers[`section_${k}`], sectionOptions);
    const resolves = readNoul(sectionAnswers[`resolves_${k}`]);
    if (!section || resolves === null) return sendFeedback("bad_reply", request);
    scores.section_p = section.p;
    scores.section_confidence = section.confidence;
    scores.resolves = resolves;
    if (resolves < GATES.resolves) {
      results.push(none);
      continue;
    }
    if (section.choice !== NO_MATCH && section.p >= GATES.sectionP && section.confidence >= GATES.sectionConf) {
      const target = article.sections.find((s) => s.id === section.choice);
      const eligible = mode === "enabled" && request.mode === "decomposed" && issues[k].anchored && article.deflection === "can_resolve";
      results.push({
        ...none,
        match_type: "section",
        page_slug: slug,
        section_id: target.id,
        heading: target.heading,
        text: target.text,
        url: target.url,
        deflection: article.deflection,
        resolution_eligible: eligible,
        requires_send: !eligible,
      });
    } else if (page.p >= GATES.pageLinkP) {
      results.push({ ...none, match_type: "page", page_slug: slug, heading: article.title, url: article.url, deflection: article.deflection });
    } else {
      results.push(none);
    }
  }

  for (const r of results) {
    if (r.url !== null && !r.url.startsWith("https://enviouswispr.com/help/")) return sendFeedback("bad_target", request);
  }
  const suppressionAllowed =
    mode === "enabled" &&
    request.mode === "decomposed" &&
    !request.overflow &&
    coverage >= GATES.covered &&
    results.length > 0 &&
    results.every((r) => r.resolution_eligible);
  return { v: 1, status: "ok", reason: "matched", suppression_allowed: suppressionAllowed, issues: results, ...versions(request, coverage) };
}

// One count line per check, for Workers logs. Never add text, evidence or summaries.
export function countLine(result) {
  return JSON.stringify({
    event: "help_check",
    status: result.status,
    reason: result.reason,
    concerns: result.issues.length,
    sections: result.issues.filter((r) => r.match_type === "section").length,
    pages: result.issues.filter((r) => r.match_type === "page").length,
    suppression_allowed: result.suppression_allowed,
    kb_version: result.kb_version,
  });
}
