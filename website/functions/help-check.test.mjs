// #3275: POST /api/app/help-check. Synthetic messages and a fake TypeSafe only;
// nothing here calls the network. Run: `npm run test:functions`.
import assert from "node:assert/strict";
import { test } from "node:test";

import CATALOG from "./_lib/help-catalog.js";
import {
  GATES,
  INFERENCE_DEADLINE_MS,
  JEV_MODEL,
  MAX_BODY_BYTES,
  NO_MATCH,
  buildPageRequest,
  countLine,
  runHelpCheck,
  validateRequest,
} from "./_lib/help-check.js";
import { handleHelpCheck } from "./api/app/help-check.js";

const byPolicy = (policy) => CATALOG.articles.find((a) => a.deflection === policy);
const RESOLVE = byPolicy("can_resolve");
const ALWAYS_SEND = byPolicy("show_but_always_send");
const NEVER = byPolicy("never_intervene");
const ENV = { HELP_CHECK_MODE: "enabled", TYPESAFE_API_KEY: "test-key" };
// One concern, so a complete issue list is the whole message.
const SECRET_TEXT = "My SECRET-PHRASE-42 keybind stopped working after the update.";

function issue(k, message, evidence, summary = "a concern", kind = "bug") {
  const start = message.indexOf(evidence);
  return { id: `i${k}`, summary, kind, evidence, start_utf16: start, end_utf16: start + evidence.length };
}

function body(overrides = {}) {
  const message = typeof overrides.original_message === "string" ? overrides.original_message : SECRET_TEXT;
  return {
    v: 1,
    original_message: message,
    mode: "decomposed",
    issues: [issue(0, message, "My SECRET-PHRASE-42 keybind stopped working after the update.")],
    overflow: false,
    decomposition_version: "afm-26.1",
    app_version: "2.6.0",
    ...overrides,
  };
}

const choice = (pick, p = 0.9, confidence = 0.9) => ({ type: "choice", choice: pick, confidence, probabilities: { [pick]: p } });
const noul = (v = 0.9) => ({ type: "noul", noul: v });
const reply = (answers, model = JEV_MODEL) => ({ status: 200, ok: true, json: async () => ({ model, answers }) });
// The first request's reply always carries the whole-list coverage answer.
const firstReply = (answers, covered = 0.9, model = JEV_MODEL) => reply({ covered: noul(covered), ...answers }, model);

// A fake TypeSafe that answers each request in turn and records what it was sent.
function fakeJev(...replies) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body), headers: init.headers, signal: init.signal });
    const next = replies[calls.length - 1];
    if (!next) throw new Error("unexpected extra TypeSafe request");
    return typeof next === "function" ? next(init) : next;
  };
  return { fetchImpl, calls };
}

const pageAnswer = (slug, covered = 0.9) => firstReply({ page_0: choice(slug), useful_0: noul() }, covered);
const sectionAnswer = (sectionId, resolves = 0.9, p = 0.9, confidence = 0.9) =>
  reply({ section_0: choice(sectionId, p, confidence), resolves_0: noul(resolves) });

test("a can_resolve section match in decomposed mode allows suppression, in two requests", async () => {
  const section = RESOLVE.sections[0];
  const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(section.id));
  const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(out.status, "ok");
  assert.equal(out.suppression_allowed, true);
  assert.equal(jev.calls.length, 2);
  assert.deepEqual(
    { ...out.issues[0], scores: undefined },
    { id: "i0", match_type: "section", page_slug: RESOLVE.slug, section_id: section.id, heading: section.heading, text: section.text, url: section.url, deflection: "can_resolve", scores: undefined, resolution_eligible: true, requires_send: false },
  );
  assert.equal(out.kb_version, CATALOG.catalogVersion);
  assert.equal(out.jev_model_version, JEV_MODEL);
  assert.equal(out.decomposition_version, "afm-26.1");
  assert.equal(out.app_version, "2.6.0");
  assert.equal(jev.calls[0].headers.Authorization, "Bearer test-key");
  assert.equal(jev.calls[0].body.model, JEV_MODEL);
  assert.equal(jev.calls[0].body.state.feedback.text, SECRET_TEXT);
});

test("the response carries no user-written text, and the count line carries none either", async () => {
  const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(RESOLVE.sections[0].id));
  const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
  assert.ok(!JSON.stringify(out).includes("SECRET-PHRASE-42"));
  assert.ok(!countLine(out).includes("SECRET-PHRASE-42"));
  assert.deepEqual(Object.keys(JSON.parse(countLine(out))).sort(), ["concerns", "event", "kb_version", "pages", "reason", "sections", "status", "suppression_allowed"]);
});

test("never_intervene pages are never offered to Jev, and a reply naming one fails open", async () => {
  const request = buildPageRequest(SECRET_TEXT, [{ id: "i0", summary: "", evidence: SECRET_TEXT }]);
  assert.ok(NEVER);
  assert.ok(!(NEVER.slug in request.questions.page_0.criteria));
  assert.ok(!request.state.articles.some((a) => a.slug === NEVER.slug));
  const offered = Object.keys(request.questions.page_0.criteria).filter((k) => k !== NO_MATCH);
  assert.equal(offered.length, CATALOG.articles.filter((a) => a.deflection !== "never_intervene").length);
  assert.ok(offered.length > 0);
  const jev = fakeJev(pageAnswer(NEVER.slug));
  const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(out.status, "send_feedback");
  assert.equal(out.reason, "bad_reply");
});

test("a show_but_always_send section is shown but always requires sending", async () => {
  const jev = fakeJev(pageAnswer(ALWAYS_SEND.slug), sectionAnswer(ALWAYS_SEND.sections[0].id));
  const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(out.issues[0].match_type, "section");
  assert.equal(out.issues[0].deflection, "show_but_always_send");
  assert.equal(out.issues[0].resolution_eligible, false);
  assert.equal(out.issues[0].requires_send, true);
  assert.equal(out.suppression_allowed, false);
});

test("whole-message mode never allows suppression, even with a strong can_resolve match", async () => {
  const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(RESOLVE.sections[0].id));
  const out = await runHelpCheck(body({ mode: "whole_message_always_send", issues: [] }), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(out.issues.length, 1);
  assert.equal(out.issues[0].match_type, "section");
  assert.equal(out.issues[0].resolution_eligible, false);
  assert.equal(out.suppression_allowed, false);
  assert.deepEqual(jev.calls[0].body.state.issues, [{ id: "i0", summary: "", evidence: SECRET_TEXT }]);
});

test("the kill switch: missing, unknown and disabled send without calling TypeSafe; suggest_only never suppresses", async () => {
  for (const mode of [undefined, "", "on", "disabled"]) {
    const jev = fakeJev();
    const out = await runHelpCheck(body(), { ...ENV, HELP_CHECK_MODE: mode }, { fetchImpl: jev.fetchImpl });
    assert.equal(out.status, "send_feedback");
    assert.equal(out.reason, "disabled");
    assert.equal(jev.calls.length, 0);
  }
  const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(RESOLVE.sections[0].id));
  const out = await runHelpCheck(body(), { ...ENV, HELP_CHECK_MODE: "suggest_only" }, { fetchImpl: jev.fetchImpl });
  assert.equal(out.issues[0].match_type, "section");
  assert.equal(out.issues[0].resolution_eligible, false);
  assert.equal(out.suppression_allowed, false);
});

test("a missing TypeSafe key sends without calling TypeSafe", async () => {
  const jev = fakeJev();
  const out = await runHelpCheck(body(), { HELP_CHECK_MODE: "enabled" }, { fetchImpl: jev.fetchImpl });
  assert.equal(out.reason, "config");
  assert.equal(jev.calls.length, 0);
});

test("no match on every concern makes one request and requires sending", async () => {
  const jev = fakeJev(pageAnswer(NO_MATCH));
  const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(jev.calls.length, 1);
  assert.equal(out.issues[0].match_type, "none");
  assert.equal(out.issues[0].requires_send, true);
  assert.equal(out.suppression_allowed, false);
});

test("zero concerns (praise) makes no request and allows no suppression", async () => {
  const jev = fakeJev();
  const out = await runHelpCheck(body({ issues: [] }), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(out.status, "ok");
  assert.equal(out.reason, "no_concerns");
  assert.equal(out.suppression_allowed, false);
  assert.equal(jev.calls.length, 0);
});

test("five concerns still make exactly two requests; any unmatched concern blocks suppression", async () => {
  const message = "One. Two. Three. Four. Five.";
  const issues = ["One.", "Two.", "Three.", "Four.", "Five."].map((e, k) => issue(k, message, e));
  const page = {};
  const section = {};
  for (let k = 0; k < 5; k++) {
    page[`page_${k}`] = choice(k === 4 ? NO_MATCH : RESOLVE.slug);
    page[`useful_${k}`] = noul();
    if (k < 4) {
      section[`section_${k}`] = choice(RESOLVE.sections[0].id);
      section[`resolves_${k}`] = noul();
    }
  }
  const jev = fakeJev(firstReply(page), reply(section));
  const out = await runHelpCheck(body({ original_message: message, issues }), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(jev.calls.length, 2);
  assert.equal(Object.keys(jev.calls[0].body.questions).length, 11, "5 page, 5 useful and 1 coverage question");
  assert.equal(Object.keys(jev.calls[1].body.questions).length, 8);
  assert.deepEqual(out.issues.map((r) => r.match_type), ["section", "section", "section", "section", "none"]);
  assert.equal(out.suppression_allowed, false);
});

test("the whole list must cover the message before anything may be suppressed", async () => {
  // Two concerns in the message, only one sent: the one card may be right, but the
  // paste problem would be lost if the report were suppressed.
  const message = "My keybind stopped working. Also paste fails in Slack.";
  const partial = body({ original_message: message, issues: [issue(0, message, "My keybind stopped working.")] });
  for (const [covered, allowed] of [[GATES.covered - 0.01, false], [GATES.covered, true], [0.1, false]]) {
    const jev = fakeJev(pageAnswer(RESOLVE.slug, covered), sectionAnswer(RESOLVE.sections[0].id));
    const out = await runHelpCheck(partial, ENV, { fetchImpl: jev.fetchImpl });
    assert.equal(out.issues[0].resolution_eligible, true, "the card itself is still a verified answer");
    assert.equal(out.suppression_allowed, allowed, `covered ${covered}`);
    assert.equal(out.coverage, covered);
  }
  const request = buildPageRequest(message, [{ id: "i0", summary: "", evidence: message }]);
  assert.equal(request.questions.covered.type, "noul");
});

test("overflow (more concerns than the app sent) blocks suppression", async () => {
  const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(RESOLVE.sections[0].id));
  const out = await runHelpCheck(body({ overflow: true }), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(out.issues[0].resolution_eligible, true);
  assert.equal(out.suppression_allowed, false);
});

test("section gates at their boundaries, then the page-link fallback", async () => {
  const id = RESOLVE.sections[0].id;
  const cases = [
    [{ resolves: GATES.resolves, p: GATES.sectionP, conf: GATES.sectionConf, pageP: 0.9 }, "section"],
    [{ resolves: GATES.resolves - 0.01, p: 0.9, conf: 0.9, pageP: 0.9 }, "none"],
    [{ resolves: 0.9, p: GATES.sectionP - 0.01, conf: 0.9, pageP: GATES.pageLinkP }, "page"],
    [{ resolves: 0.9, p: 0.9, conf: GATES.sectionConf - 0.01, pageP: GATES.pageLinkP - 0.01 }, "none"],
  ];
  for (const [c, expected] of cases) {
    const jev = fakeJev(firstReply({ page_0: choice(RESOLVE.slug, c.pageP, 0.9), useful_0: noul() }), sectionAnswer(id, c.resolves, c.p, c.conf));
    const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
    assert.equal(out.issues[0].match_type, expected, JSON.stringify(c));
    if (expected !== "section") assert.equal(out.suppression_allowed, false);
    if (expected === "page") {
      assert.equal(out.issues[0].url, RESOLVE.url);
      assert.equal(out.issues[0].requires_send, true);
    }
  }
});

test("page gates at their boundaries decide whether the second request happens", async () => {
  const cases = [
    [GATES.pageP, GATES.pageConf, GATES.useful, 2],
    [GATES.pageP - 0.01, 0.9, 0.9, 1],
    [0.9, GATES.pageConf - 0.01, 0.9, 1],
    [0.9, 0.9, GATES.useful - 0.01, 1],
  ];
  for (const [p, conf, useful, expectedCalls] of cases) {
    const jev = fakeJev(firstReply({ page_0: choice(RESOLVE.slug, p, conf), useful_0: noul(useful) }), sectionAnswer(RESOLVE.sections[0].id));
    await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
    assert.equal(jev.calls.length, expectedCalls, `${p} ${conf} ${useful}`);
  }
});

test("a quote that differs only in case can be shown but never marked solved", async () => {
  const message = "the cleaned-up text hangs for ages.";
  const evidence = "The cleaned-up text hangs for ages.";
  const out = validateRequest(body({ original_message: message, issues: [{ id: "i0", summary: "s", kind: "bug", evidence, start_utf16: 0, end_utf16: message.length }] }));
  assert.equal(out.issues[0].anchored, false);
  const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(RESOLVE.sections[0].id));
  const res = await runHelpCheck(body({ original_message: message, issues: [{ id: "i0", summary: "s", kind: "bug", evidence, start_utf16: 0, end_utf16: message.length }] }), ENV, { fetchImpl: jev.fetchImpl });
  assert.equal(res.issues[0].match_type, "section");
  assert.equal(res.issues[0].resolution_eligible, false);
  assert.equal(res.suppression_allowed, false);
  const unanchored = validateRequest(body({ issues: [{ id: "i0", summary: "s", kind: "bug", evidence: "not in the message", start_utf16: null, end_utf16: null }] }));
  assert.equal(unanchored.issues[0].anchored, false);
  // A model can return a "quote" longer than a one-word message; that is still a concern.
  const longer = validateRequest(body({ original_message: "banana", issues: [{ id: "i0", summary: "s", kind: "other", evidence: "EnviousWispr is not working at all", start_utf16: null, end_utf16: null }] }));
  assert.equal(longer.reason, undefined);
  assert.equal(longer.issues[0].anchored, false);
});

test("invalid requests fail open without calling TypeSafe", async () => {
  const m = SECRET_TEXT;
  const good = issue(0, m, "keybind stopped working");
  const invalid = [
    null,
    [],
    { ...body(), v: 2 },
    body({ original_message: "   " }),
    body({ original_message: 5 }),
    body({ mode: "other" }),
    body({ overflow: "no" }),
    body({ issues: "x" }),
    body({ decomposition_version: "bad version!" }),
    body({ app_version: "" }),
    body({ mode: "whole_message_always_send", issues: [good] }),
    body({ issues: [{ ...good, id: "i1" }] }),
    body({ issues: [good, { ...good }] }),
    body({ issues: [{ ...good, kind: "rant" }] }),
    body({ issues: [{ ...good, summary: "x".repeat(301) }] }),
    body({ issues: [{ ...good, evidence: "" }] }),
    body({ issues: [{ ...good, evidence: "x".repeat(8193), start_utf16: null, end_utf16: null }] }),
    body({ issues: [{ ...good, start_utf16: 3 }] }),
    body({ issues: [{ ...good, start_utf16: -1 }] }),
    body({ issues: [{ ...good, end_utf16: m.length + 1 }] }),
    body({ issues: [{ ...good, start_utf16: 5, end_utf16: 5 }] }),
    body({ issues: [{ ...good, start_utf16: null }] }),
    body({ issues: [0, 1, 2, 3, 4, 5].map((k) => ({ ...good, id: `i${k}` })) }),
  ];
  for (const b of invalid) {
    const jev = fakeJev();
    const out = await runHelpCheck(b, ENV, { fetchImpl: jev.fetchImpl });
    assert.equal(out.status, "send_feedback", JSON.stringify(b)?.slice(0, 120));
    assert.equal(out.suppression_allowed, false);
    assert.equal(jev.calls.length, 0);
  }
  assert.ok(invalid.length >= 20);
});

test("length limits count characters and code points like the form, not UTF-16 units", () => {
  const emoji = "👍🏽";
  assert.equal(validateRequest(body({ original_message: "a".repeat(4000), issues: [] })).reason, undefined);
  assert.equal(validateRequest(body({ original_message: "a".repeat(4001), issues: [] })).reason, "message_too_long");
  // 1,000 skin-toned thumbs: 1,000 characters, 2,000 code points, 4,000 UTF-16 units.
  assert.equal(validateRequest(body({ original_message: emoji.repeat(1000), issues: [] })).reason, undefined);
  // 2,100 of them: 2,100 characters but 4,200 code points, over Sentry's 4,096.
  assert.equal(validateRequest(body({ original_message: emoji.repeat(2100), issues: [] })).reason, "message_too_long");
  const message = `${emoji} paste fails in Slack`;
  const ok = validateRequest(body({ original_message: message, issues: [issue(0, message, "paste fails in Slack")] }));
  assert.equal(ok.issues[0].anchored, true);
  assert.equal(message.indexOf("paste"), 5);
});

test("TypeSafe failures fail open with a closed reason", async () => {
  const failures = [
    [{ status: 401, ok: false }, "config"],
    [{ status: 403, ok: false }, "config"],
    [{ status: 402, ok: false }, "unavailable"],
    [{ status: 429, ok: false }, "unavailable"],
    [{ status: 500, ok: false }, "http_500"],
    [() => Promise.reject(new TypeError("fetch failed")), "network"],
    [firstReply({ page_0: choice(RESOLVE.slug), useful_0: noul() }, 0.9, "jev-1.14.0"), "bad_reply"],
    [{ status: 200, ok: true, json: async () => { throw new SyntaxError("bad json"); } }, "bad_reply"],
    [firstReply({ page_0: choice(RESOLVE.slug, 1.5), useful_0: noul() }), "bad_reply"],
    [firstReply({ page_0: choice(RESOLVE.slug, 0.9, "high"), useful_0: noul() }), "bad_reply"],
    [firstReply({ page_0: choice("not-a-page"), useful_0: noul() }), "bad_reply"],
    [firstReply({ page_0: choice(RESOLVE.slug) }), "bad_reply"],
    [firstReply({ page_0: { type: "noul", noul: 0.9 }, useful_0: noul() }), "bad_reply"],
    [reply({ page_0: choice(RESOLVE.slug), useful_0: noul() }), "bad_reply"],
    [firstReply({ page_0: choice(RESOLVE.slug), useful_0: noul() }, 1.2), "bad_reply"],
  ];
  for (const [first, reason] of failures) {
    const jev = fakeJev(first);
    const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl });
    assert.equal(out.status, "send_feedback", reason);
    assert.equal(out.reason, reason);
    assert.equal(jev.calls.length, 1, `${reason}: no retry`);
  }
  const wrongSection = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(ALWAYS_SEND.sections[0].id));
  assert.equal((await runHelpCheck(body(), ENV, { fetchImpl: wrongSection.fetchImpl })).reason, "bad_reply");
  assert.ok(failures.length >= 15);
  // A reply that says no article is useful cannot also produce a card.
  const contradictory = fakeJev(firstReply({ page_0: choice(RESOLVE.slug), useful_0: noul(GATES.useful - 0.01) }));
  const noCard = await runHelpCheck(body(), ENV, { fetchImpl: contradictory.fetchImpl });
  assert.equal(noCard.issues[0].match_type, "none");
  assert.equal(contradictory.calls.length, 1);
});

test("both requests share one 2.0-second deadline", async () => {
  let clock = 0;
  const now = () => clock;
  // The first request uses 1.5 s, so the second gets only the remaining 0.5 s.
  const slowFirst = async () => {
    clock += 1500;
    return pageAnswer(RESOLVE.slug);
  };
  const seen = [];
  const second = (init) =>
    new Promise((_, reject) => {
      seen.push(init.signal);
      init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    });
  const jev = fakeJev(slowFirst, second);
  const started = Date.now();
  const out = await runHelpCheck(body(), ENV, { fetchImpl: jev.fetchImpl, now });
  assert.equal(out.reason, "timeout");
  assert.equal(jev.calls.length, 2);
  assert.ok(seen[0].aborted);
  assert.ok(Date.now() - started < INFERENCE_DEADLINE_MS, "the second request was cut at the shared deadline, not given a fresh 2 s");

  // A first reply that arrives whole but after the budget counts as late, and no
  // second request follows, even when it would have ended the check.
  clock = 0;
  const lateNoMatch = fakeJev(async () => {
    clock += INFERENCE_DEADLINE_MS + 501;
    return pageAnswer(NO_MATCH);
  });
  const lateOut = await runHelpCheck(body(), ENV, { fetchImpl: lateNoMatch.fetchImpl, now });
  assert.equal(lateOut.status, "send_feedback");
  assert.equal(lateOut.reason, "timeout");
  assert.equal(lateNoMatch.calls.length, 1);

  // A fetch that never settles and ignores its abort signal still ends at the deadline.
  clock = 0;
  const hung = fakeJev(() => new Promise(() => {}));
  const hungStarted = Date.now();
  const hungOut = await runHelpCheck(body(), ENV, { fetchImpl: hung.fetchImpl, now: () => Date.now() });
  assert.equal(hungOut.reason, "timeout");
  assert.ok(Date.now() - hungStarted < INFERENCE_DEADLINE_MS + 500);
  // So does a body read that never settles.
  const hungBody = fakeJev({ status: 200, ok: true, json: () => new Promise(() => {}) });
  assert.equal((await runHelpCheck(body(), ENV, { fetchImpl: hungBody.fetchImpl, now: () => Date.now() })).reason, "timeout");
  // A body read that the abort ends (rejecting before the deadline race does) is a timeout too.
  const abortedBody = fakeJev((init) => ({
    status: 200,
    ok: true,
    json: () => new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))),
  }));
  assert.equal((await runHelpCheck(body(), ENV, { fetchImpl: abortedBody.fetchImpl, now: () => Date.now() })).reason, "timeout");

  clock = 0;
  const spent = fakeJev(async () => {
    clock += INFERENCE_DEADLINE_MS;
    return pageAnswer(RESOLVE.slug);
  });
  const late = await runHelpCheck(body(), ENV, { fetchImpl: spent.fetchImpl, now });
  assert.equal(late.reason, "timeout");
  assert.equal(spent.calls.length, 1);
});

test("the web handler checks content type and size, and logs one count line without text", async () => {
  const post = (b, type = "application/json") =>
    new Request("https://enviouswispr.com/api/app/help-check", { method: "POST", headers: { "Content-Type": type }, body: b });
  assert.equal((await handleHelpCheck(post("{}", "text/plain"), ENV)).status, 415);
  assert.equal((await handleHelpCheck(post("x".repeat(MAX_BODY_BYTES + 1)), ENV)).status, 413);
  // No Content-Length: a stream past the cap is cut while reading, not buffered whole.
  let pulled = 0;
  const endless = new ReadableStream({
    pull(controller) {
      pulled++;
      controller.enqueue(new Uint8Array(16 * 1024));
    },
  });
  const streamed = new Request("https://enviouswispr.com/api/app/help-check", { method: "POST", headers: { "Content-Type": "application/json" }, body: endless, duplex: "half" });
  assert.equal(streamed.headers.get("Content-Length"), null);
  assert.equal((await handleHelpCheck(streamed, ENV)).status, 413);
  assert.ok(pulled <= Math.ceil(MAX_BODY_BYTES / (16 * 1024)) + 2, `read ${pulled} chunks`);
  const broken = new ReadableStream({
    pull(controller) {
      controller.error(new Error("connection reset"));
    },
  });
  const failed = await handleHelpCheck(new Request("https://enviouswispr.com/api/app/help-check", { method: "POST", headers: { "Content-Type": "application/json" }, body: broken, duplex: "half" }), ENV);
  assert.equal(failed.status, 400);
  assert.equal((await failed.json()).status, "send_feedback");
  const bad = await handleHelpCheck(post("{not json"), ENV);
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).status, "send_feedback");

  const logged = [];
  const original = console.log;
  console.log = (line) => logged.push(line);
  try {
    const jev = fakeJev(pageAnswer(RESOLVE.slug), sectionAnswer(RESOLVE.sections[0].id));
    const res = await handleHelpCheck(post(JSON.stringify(body())), ENV, { fetchImpl: jev.fetchImpl });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Cache-Control"), "no-store");
    assert.equal((await res.json()).suppression_allowed, true);
  } finally {
    console.log = original;
  }
  assert.equal(logged.length, 1);
  assert.ok(!logged[0].includes("SECRET-PHRASE-42"));
  assert.equal(JSON.parse(logged[0]).event, "help_check");

  const early = [];
  console.log = (line) => early.push(JSON.parse(line));
  try {
    await handleHelpCheck(post("{}", "text/plain"), ENV);
    await handleHelpCheck(post("x".repeat(MAX_BODY_BYTES + 1)), ENV);
    await handleHelpCheck(post("{not json"), ENV);
  } finally {
    console.log = original;
  }
  assert.deepEqual(early.map((l) => l.reason), ["invalid_request", "too_large", "invalid_request"]);
});

test("every suggestion target is a real catalog section or page on the help site", () => {
  let targets = 0;
  for (const a of CATALOG.articles) {
    assert.ok(a.url.startsWith("https://enviouswispr.com/help/"));
    for (const s of a.sections) {
      targets++;
      assert.ok(s.url.startsWith(a.url));
    }
  }
  assert.ok(targets > 0);
});
