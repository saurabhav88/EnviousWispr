/**
 * Feedback → help-article match (#3275, V1a: silent log).
 *
 * When a user sends in-app feedback, ask TypeSafe's Jev model which help article
 * (if any) answers it, and post the guess and its scores to Discord as a SEPARATE
 * message. Nothing reaches the user. The posts are the labelled sample the founder
 * reads before any confidence threshold, or any in-app "does this help?" screen, is
 * designed. So this code never gates on a score; it only reports them.
 *
 * **The alert is the heart, this is a limb.** index.js schedules this on its own
 * `ctx.waitUntil` and never awaits it, and every function here returns a result
 * rather than throwing, so a TypeSafe outage, a bad key or a malformed answer can
 * never delay, change or drop the existing feedback alert. The two share one
 * Cloudflare post-response budget, so a slow match can be cancelled; that is an
 * accepted best-effort limit, not a bug.
 *
 * **Privacy: only the message text crosses to TypeSafe.** The request `state`
 * carries the capped report text and the public article catalog, never the reply
 * email, user, tags or contexts. The help page and privacy policy disclose exactly
 * this forward (founder Gate 2, 2026-09-28); widening the state widens that promise.
 */

import CATALOG from "./articleCatalog.js";

export const TYPESAFE_URL = "https://api.typesafe.ai/v1/systemone";
// Pinned, not an alias: aliases move on release, and a silent model swap would
// split the labelled sample across two models mid-collection.
export const JEV_MODEL = "jev-1.13.0";
export const NO_MATCH = "__no_match__";
export const FEEDBACK_TEXT_CAP = 1600;
const TYPESAFE_TIMEOUT_MS = 8000;
const HELP_BASE_URL = "https://enviouswispr.com/help/";
const MATCH_COLOR = 0x3498db;

/** Same discriminator pair isMetricIssue uses: category documented, type as backup. */
export function isFeedbackIssue(issue) {
  return issue?.issueCategory === "feedback" || issue?.issueType === "feedback";
}

/**
 * Question wording ported verbatim from the PoC that picked the right article for
 * both real reports (2026-09-28). Changing it changes what the sample measures.
 */
export function buildTypeSafeRequest(text, catalog = CATALOG) {
  const criteria = {};
  for (const article of catalog.articles) criteria[article.slug] = null;
  criteria[NO_MATCH] =
    "No listed article would be useful for this feedback, including test-only " +
    "messages or reports that merely share a word with an article.";

  return {
    model: JEV_MODEL,
    state: {
      feedback: { text },
      articles: catalog.articles,
    },
    questions: {
      article: {
        type: "choice",
        instructions:
          "Which article in `articles` would be most useful for the " +
          "concern in `feedback.text`? Use its title and description. " +
          "An article about the current setting can help with a request " +
          "to change that setting. A shared word alone is insufficient. " +
          "Choose __no_match__ if none would help.",
        criteria,
      },
      useful_article_exists: {
        type: "noul",
        instructions:
          "Would at least one article in `articles`, based on its title " +
          "and description, give useful information about the actual " +
          "concern in `feedback.text`?",
        criteria: {
          true: "An article addresses the concern's feature, setting, or problem.",
          false:
            "This is test-only or unrelated feedback, or the articles " +
            "only share incidental words with it.",
        },
      },
    },
  };
}

function isProbability(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

/**
 * Read the RAW wire shape, `{model, usage, answers}`. The Python SDK's
 * `.choices`/`.nouls` are computed properties over `answers` and do not exist on
 * the wire. Returns null for anything that does not validate, so a malformed
 * answer is reported as one rather than posted as scores.
 */
export function parseTypeSafeResponse(body, catalog = CATALOG) {
  const article = body?.answers?.article;
  const useful = body?.answers?.useful_article_exists;
  const choice = article?.choice;
  const known = choice === NO_MATCH || catalog.articles.some((a) => a.slug === choice);
  if (typeof choice !== "string" || !known) return null;

  const choiceProbability = article?.probabilities?.[choice];
  const choiceConfidence = article?.confidence;
  const usefulProbability = useful?.noul;
  if (![choiceProbability, choiceConfidence, usefulProbability].every(isProbability)) return null;

  const inputTokens = body?.usage?.input_tokens;
  return {
    choice,
    choiceProbability,
    choiceConfidence,
    usefulProbability,
    model: typeof body?.model === "string" ? body.model : null,
    inputTokens: Number.isInteger(inputTokens) ? inputTokens : null,
  };
}

/**
 * Every return carries `reason` (a skip) or a parsed pick, never neither, and
 * nothing here throws. `fetchFullIssue(id)` is index.js's issue lookup, injected
 * because that helper is module-private; `fetchBefore` is its deadline-bounded fetch.
 */
export async function matchFeedbackArticle({ issue, env, deadlineAt, fetchFullIssue, fetchBefore }) {
  const base = { catalogVersion: CATALOG.catalogVersion, truncated: false };
  try {
    // The webhook body's shape varies by delivery path (#2486), so always read the
    // report from the REST issue, whose `metadata.value` carries the full message.
    const full = await fetchFullIssue(String(issue.id));
    const raw = full?.metadata?.value ?? full?.metadata?.message;
    const text = typeof raw === "string" ? raw.trim() : "";
    if (!text) return { ...base, matched: false, reason: "no_report_text" };

    const capped = text.slice(0, FEEDBACK_TEXT_CAP);
    const truncated = text.length > FEEDBACK_TEXT_CAP;
    if (!env.TYPESAFE_API_KEY) return { ...base, truncated, matched: false, reason: "config" };

    let res;
    try {
      res = await fetchBefore(
        TYPESAFE_URL,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.TYPESAFE_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(buildTypeSafeRequest(capped)),
        },
        deadlineAt,
        TYPESAFE_TIMEOUT_MS,
        "typesafe"
      );
    } catch (error) {
      const reason = error?.name === "DeadlineExceededError" ? "timeout" : "network";
      return { ...base, truncated, matched: false, reason };
    }
    if (res.status === 401 || res.status === 403) {
      return { ...base, truncated, matched: false, reason: "config" };
    }
    if (!res.ok) return { ...base, truncated, matched: false, reason: `http_${res.status}` };

    let body;
    try {
      body = await res.json();
    } catch {
      return { ...base, truncated, matched: false, reason: "bad_response" };
    }
    const pick = parseTypeSafeResponse(body);
    if (!pick) return { ...base, truncated, matched: false, reason: "bad_response" };
    if (pick.choice === NO_MATCH) return { ...base, truncated, ...pick, matched: false, reason: "no_match" };
    return { ...base, truncated, ...pick, matched: true };
  } catch (error) {
    return { ...base, matched: false, reason: `error_${error?.name ?? "unknown"}` };
  }
}

function score(value) {
  return value.toFixed(2);
}

/** The follow-up Discord card. Carries no feedback text: the alert card has the report. */
export function buildFeedbackMatchEmbed(result, { shortId, permalink }) {
  const label = shortId ?? "feedback";
  const fields = [];

  if (result.matched) {
    const article = CATALOG.articles.find((a) => a.slug === result.choice);
    fields.push({
      name: "Article",
      value: `[${article?.title ?? result.choice}](${HELP_BASE_URL}${result.choice}/)`,
      inline: false,
    });
  } else {
    fields.push({ name: "Article", value: `none (${result.reason})`, inline: false });
  }

  if (typeof result.choiceProbability === "number") {
    fields.push({
      name: "Scores",
      value:
        `pick ${score(result.choiceProbability)} · confidence ${score(result.choiceConfidence)} · ` +
        `useful ${score(result.usefulProbability)}`,
      inline: false,
    });
  }

  const meta = [`catalog ${result.catalogVersion}`];
  if (result.model) meta.push(result.model);
  if (result.inputTokens != null) meta.push(`${result.inputTokens} tokens`);
  if (result.truncated) meta.push(`first ${FEEDBACK_TEXT_CAP} chars only`);
  fields.push({ name: "Run", value: meta.join(" · "), inline: false });

  return {
    title: `Help article guess: ${label}`,
    ...(permalink ? { url: permalink } : {}),
    color: MATCH_COLOR,
    description: "Silent log (#3275). Not shown to the user.",
    fields,
  };
}
