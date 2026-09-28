// Feedback → help-article match (#3275). The guess is a limb: every test that
// exercises it through handleTriage also asserts the existing alert card still
// posts, unchanged and unawaited, whatever the guess does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleTriage } from "../src/index.js";
import {
  FEEDBACK_TEXT_CAP,
  NO_MATCH,
  buildTypeSafeRequest,
  parseTypeSafeResponse,
} from "../src/feedbackMatch.js";
import CATALOG from "../src/articleCatalog.js";

const REPORT = "Could we get an option to show the app in the Dock instead of only the menu bar?";

// The live REST shape, trimmed (ENVIOUSWISPR-5G, pulled 2026-09-28).
const FEEDBACK_ISSUE = {
  id: "7759520095",
  shortId: "ENVIOUSWISPR-5G",
  title: "User Feedback: Could we get an option to show the app in the Dock",
  permalink: "https://envious-labs-llc.sentry.io/issues/7759520095/",
  count: "1",
  userCount: 1,
  level: "error",
  substatus: "new",
  issueCategory: "feedback",
  issueType: "feedback",
  metadata: { value: REPORT, message: REPORT, contact_email: "person@example.com" },
};

const ERROR_ISSUE = {
  id: "7647106942",
  shortId: "ENVIOUSWISPR-4M",
  title: "polish_provider_failed: EnviousWisprLLM.LLMError#11",
  permalink: "https://envious-labs-llc.sentry.io/issues/7647106942/",
  count: "27",
  userCount: 2,
  level: "error",
  substatus: "ongoing",
  issueCategory: "error",
};

function jevAnswer(choice = "sounds-and-appearance", overrides = {}) {
  return {
    model: "jev-1.13.0",
    usage: { input_tokens: 4548 },
    answers: {
      article: { choice, probabilities: { [choice]: 0.63 }, confidence: 0.61 },
      useful_article_exists: { noul: 0.63 },
    },
    ...overrides,
  };
}

function fakeKV() {
  const store = new Map();
  return {
    async get(key) { return store.get(key) ?? null; },
    async put(key, value) { store.set(key, value); },
    async delete(key) { store.delete(key); },
  };
}

function ok(json) {
  return { ok: true, status: 200, async json() { return json; }, headers: { get: () => null } };
}

function webhook(issue, action = "created") {
  return JSON.stringify({ action, data: { issue } });
}

/**
 * `typesafe` answers the TypeSafe POST; `issueLookup` answers the REST re-fetch;
 * `tickets` is the GitHub open-issue page. Every Discord embed is captured in
 * arrival order, and `ctx.waitUntil` promises are collected so a test can choose
 * when the background work is allowed to finish.
 */
function harness({
  typesafe = () => ok(jevAnswer()),
  issueLookup = () => ok(FEEDBACK_ISSUE),
  tickets = [],
  key = "ts-key",
} = {}) {
  const realFetch = globalThis.fetch;
  const typesafeBodies = [];
  const embeds = [];
  globalThis.fetch = async (url, init) => {
    const target = String(url);
    if (target === "https://api.typesafe.ai/v1/systemone") {
      typesafeBodies.push({ headers: init.headers, body: JSON.parse(init.body) });
      return typesafe();
    }
    if (/\/issues\/\d+\/$/.test(target)) return issueLookup();
    if (target.includes("/events/")) return ok([]);
    if (target.startsWith("https://api.github.com")) return ok(tickets);
    if (target.startsWith("https://discord.test")) {
      embeds.push(JSON.parse(init.body).embeds[0]);
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch to ${target}`);
  };
  const env = {
    SENTRY_DEDUP: fakeKV(),
    SENTRY_AUTH_TOKEN: "token",
    GITHUB_ISSUES_READ_TOKEN: "gh",
    GITHUB_REPO: "saurabhav88/EnviousWispr",
    DISCORD_WEBHOOK_URL: "https://discord.test/hook",
    ...(key ? { TYPESAFE_API_KEY: key } : {}),
  };
  const background = [];
  const ctx = { waitUntil: (p) => background.push(p) };
  return {
    env,
    ctx,
    embeds,
    typesafeBodies,
    background,
    settle: () => Promise.all(background),
    restore: () => (globalThis.fetch = realFetch),
  };
}

const isMatchCard = (e) => e.title.startsWith("Help article guess");
const alertCards = (h) => h.embeds.filter((e) => !isMatchCard(e));
const matchCards = (h) => h.embeds.filter(isMatchCard);

async function run(h, body) {
  try {
    await handleTriage(body, h.env, h.ctx);
    await h.settle();
  } finally {
    h.restore();
  }
}

test("a new feedback report gets the alert AND a separate help-article card", async () => {
  const h = harness();
  await run(h, webhook(FEEDBACK_ISSUE));
  assert.equal(alertCards(h).length, 1, "the existing alert still posts");
  assert.equal(matchCards(h).length, 1);
  const card = matchCards(h)[0];
  assert.equal(card.title, "Help article guess: ENVIOUSWISPR-5G");
  assert.equal(card.url, FEEDBACK_ISSUE.permalink);
  assert.match(card.fields[0].value, /\[Sounds and Appearance\]\(https:\/\/enviouswispr\.com\/help\/sounds-and-appearance\/\)/);
  assert.equal(card.fields[1].value, "pick 0.63 · confidence 0.61 · useful 0.63");
  assert.match(card.fields[2].value, new RegExp(`catalog ${CATALOG.catalogVersion} · jev-1\\.13\\.0 · 4548 tokens`));
});

test("only the message text crosses to TypeSafe: never the email, user or tags", async () => {
  const h = harness();
  await run(h, webhook(FEEDBACK_ISSUE));
  assert.equal(h.typesafeBodies.length, 1);
  const { headers, body } = h.typesafeBodies[0];
  assert.equal(headers.Authorization, "Bearer ts-key");
  assert.equal(body.model, "jev-1.13.0");
  assert.deepEqual(Object.keys(body.state).sort(), ["articles", "feedback"]);
  assert.deepEqual(body.state.feedback, { text: REPORT });
  assert.equal(JSON.stringify(body).includes("person@example.com"), false);
  assert.equal(body.state.articles.length, CATALOG.articles.length);
});

// The timeout turns a regression (the guess awaited inline) into a failure rather
// than a hang: an awaited guess never returns while TypeSafe is held pending.
test("the alert posts without waiting for the guess", { timeout: 2000 }, async () => {
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const h = harness({ typesafe: () => gate.then(() => ok(jevAnswer())) });
  try {
    await handleTriage(webhook(FEEDBACK_ISSUE), h.env, h.ctx);
    assert.equal(alertCards(h).length, 1, "alert delivered while TypeSafe is still pending");
    assert.equal(matchCards(h).length, 0);
    release();
    await h.settle();
    assert.equal(matchCards(h).length, 1);
  } finally {
    h.restore();
  }
});

for (const [name, opts, reason] of [
  ["TypeSafe 500", { typesafe: () => ({ ok: false, status: 500 }) }, "http_500"],
  ["TypeSafe rejects the key", { typesafe: () => ({ ok: false, status: 401 }) }, "config"],
  ["no key installed", { key: null }, "config"],
  ["TypeSafe network error", { typesafe: () => { throw new TypeError("fetch failed"); } }, "network"],
  ["malformed TypeSafe body", { typesafe: () => ok({ answers: {} }) }, "bad_response"],
  ["report re-fetch fails", { issueLookup: () => ({ ok: false, status: 404 }) }, "no_report_text"],
  ["Jev picks no article", { typesafe: () => ok(jevAnswer(NO_MATCH)) }, "no_match"],
]) {
  test(`${name}: the card reads a skip reason and the alert is untouched`, async () => {
    const h = harness(opts);
    await run(h, webhook(FEEDBACK_ISSUE));
    assert.equal(alertCards(h).length, 1, "the alert must post whatever the guess does");
    assert.equal(matchCards(h).length, 1);
    assert.equal(matchCards(h)[0].fields[0].value, `none (${reason})`);
  });
}

test("the alert card is identical with and without the guess", async () => {
  const withGuess = harness();
  await run(withGuess, webhook(FEEDBACK_ISSUE));
  const without = harness();
  try {
    await handleTriage(webhook(FEEDBACK_ISSUE), without.env); // no ctx: nothing scheduled
  } finally {
    without.restore();
  }
  assert.deepEqual(alertCards(withGuess), without.embeds);
  assert.equal(without.typesafeBodies.length, 0);
});

test("the guess still posts when the alert is suppressed by an open ticket", async () => {
  const h = harness({
    tickets: [{ number: 9, state: "open", body: "<!-- sentry-issue-id: ENVIOUSWISPR-5G -->" }],
  });
  await run(h, webhook(FEEDBACK_ISSUE));
  assert.equal(alertCards(h).length, 0, "control: this ticket really suppresses the alert");
  assert.equal(matchCards(h).length, 1);
});

test("non-feedback issues and non-new feedback are never sent to TypeSafe", async () => {
  for (const body of [webhook(ERROR_ISSUE), webhook(FEEDBACK_ISSUE, "unresolved"), webhook(FEEDBACK_ISSUE, "resolved")]) {
    const h = harness();
    await run(h, body);
    assert.equal(h.typesafeBodies.length, 0, body);
    assert.equal(matchCards(h).length, 0, body);
    assert.equal(h.background.length, 0, body);
  }
});

test("a report over the cap sends the first 1600 characters and says so", async () => {
  const long = "a".repeat(FEEDBACK_TEXT_CAP + 400);
  const issue = { ...FEEDBACK_ISSUE, metadata: { value: long } };
  const h = harness({ issueLookup: () => ok(issue) });
  await run(h, webhook(issue));
  assert.equal(h.typesafeBodies[0].body.state.feedback.text.length, FEEDBACK_TEXT_CAP);
  assert.match(matchCards(h)[0].fields[2].value, /first 1600 chars only/);
});

test("the question wording matches the PoC and offers every article plus no-match", () => {
  const request = buildTypeSafeRequest("x");
  const options = Object.keys(request.questions.article.criteria);
  assert.equal(options.length, CATALOG.articles.length + 1);
  assert.ok(options.includes(NO_MATCH));
  assert.equal(request.questions.article.type, "choice");
  assert.equal(request.questions.useful_article_exists.type, "noul");
});

test("parseTypeSafeResponse refuses unknown slugs and out-of-range scores", () => {
  assert.ok(parseTypeSafeResponse(jevAnswer()));
  assert.equal(parseTypeSafeResponse(jevAnswer("not-a-real-article")), null);
  const outOfRange = jevAnswer();
  outOfRange.answers.useful_article_exists.noul = 1.5;
  assert.equal(parseTypeSafeResponse(outOfRange), null);
  const missingProbability = jevAnswer();
  missingProbability.answers.article.probabilities = {};
  assert.equal(parseTypeSafeResponse(missingProbability), null);
});
