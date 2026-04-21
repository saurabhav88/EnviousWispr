# Issue #381 — Dual-mode Apple polish router — 2026-04-20

GitHub issue: `#381`. Parent/epic: #320 Transcript Quality. Tier: **SMALL** (new isolated module, no runtime wiring yet). Status: DRAFT.

## Preface — User Rubric

1. **Who in this moment?** Marcus (staff engineer, dev persona) dictating "Write a SQL query that joins users and orders" to land in Claude Code. Priya (CSM/exec persona) dictating "Draft an email to Anand saying thanks for the intro" to land in Gmail. Dr. Vasquez dictating "Write a nursing note stating the wound dressing was changed" to land in Epic.
2. **Why would they want this?** Marcus: *"I don't want my dictation button to start writing code for me when I was just telling Claude what to do."* Priya: *"I want filler words gone but I don't want my imperative verbs deleted when I say 'Draft a memo'."* Dr. Vasquez: *"I want the nursing note preserved word-for-word, not paraphrased."*
3. **How would they invoke it?** Reactive, side effect of polish already running. Never visible as a toggle — router decides silently. Marcus is already in his terminal/Claude app; Priya already in Gmail; Dr. V already in Epic. No context switch.
4. **What apps?** Marcus: Claude Code, Cursor, VS Code, Terminal. Priya: Gmail, Slack, Linear, Notion. Dr. V: Epic, EHR charting apps, Outlook. All surfaces receive pasted text; none read Apple Intelligence structure.
5. **Natural inputs (5 per persona, realistic dictation):** Marcus: *"claude write a python script that reads a robinhood csv and maps it to monarch"*, *"the websocket keeps dropping when the device sleeps, we need a reconnection strategy"*, *"refactor this swift struct to use associated values"*, *"the vercel build is failing because of a type error"*, *"implement a fallback so if the api rate limits us it queues requests in local storage"*. Priya: *"draft an email to the enterprise team saying we need to rethink churn mitigation"*, *"let's push the q3 nrr review to thursday at four thirty"*, *"remind me to bring up the aws billing discrepancy during the all-hands"*, *"the client is asking for custom integration we cannot support so tell them no"*, *"schedule a sync with the european team on gdpr"*. Dr. V: *"write a nursing note stating wound dressing changed moderate serosanguinous drainage"*, *"patient in 402 complaining of sharp lower quadrant pain 8 out of 10"*, *"hold morning dose of lisinopril his bp is running low"*, *"stat ekg on 410 she's having shortness of breath"*, *"administer 4 milligrams zofran iv push for nausea"*.
6. **What does success feel like?** They never notice. Polish cleans fillers from their descriptive dictation (Priya/Dr. V's default), preserves their imperatives when they dictate commands (Marcus's default), and never writes code when they meant to pass an instruction downstream. Invisible when correct, because that's polish working.
7. **What does wrong-not-broken look like?** Marcus dictates "write a python script that reads this csv" to Claude Code; polish returns actual Python code and Marcus pastes that into Claude expecting a conversation about the script. He doesn't file a bug; he just stops trusting dictation for technical prompts. Priya dictates "draft an email"; polish drops "Draft" and keeps the body; she pastes into Gmail, realizes the imperative is gone, retypes. Quiet trust loss.
8. **Power-user hack-around.** Manual toggle in settings. Explicit prefix word ("dictation:" / "command:"). Retry polish. None of these land in v1 because the whole point is the classifier runs invisibly.
9. **Control ladder.** Off (current shipped prompt, no router) → Auto inference (this PR's follow-up: router picks mode silently) → Explicit toggle (future: hotkey to force technical). Default ships Auto; deterministic router means misroutes are tunable from telemetry rather than stuck as a policy choice.

### Cross-persona check

- **Priya**: Router protects her "Draft an email / Schedule a sync" imperatives from getting verb-dropped. Minor concern: she sometimes says "um" before "draft" — imperative-at-start still fires because she pauses before the verb, not within it.
- **Marcus**: Explicit win. "Write a Python script" no longer gets executed.
- **Diana** (marketing): Her dictation is closer to Priya's. No regression expected.
- **Dr. Vasquez**: Most of her dictation is descriptive ("patient complaining of..."); router keeps this natural. Her nursing-note imperatives ("Write a nursing note...") go technical.
- **Aaron** (retiree learning dictation): Purely conversational; every sentence routes natural.
- **Meera / Frank** (accessibility-first users): Their dictation rarely includes imperative verbs or code-adjacent nouns; router stays on natural, which is the preserved behavior.

Disagreement: zero. Router is a safety net for imperative preservation that doesn't change natural-speech behavior — every persona either benefits or sees no change.

## 0. TL;DR

Tonight's benchmark work established, with data, that a single on-device polish prompt cannot serve both "clean my dictation" (v30 prompt family) and "preserve my technical instruction" (v31 prompt family) without a material regression on one or the other. This PR adds the deterministic classifier (`ApplePolishRouter`) that picks between the two modes from the ASR transcript text alone — no new model call, no network, no AI. It does NOT yet wire the router into `AppleIntelligenceConnector.polish(...)`. Integration is a follow-up PR.

## 1. Problem

v30 (current worktree candidate) is the right polish prompt for natural dictation: on Gemini-100 it hit **engaged 87, filler-clean 90** vs v31's **engaged 63, filler-clean 68** — a -24/-22 regression on natural speech if we shipped v31 alone. v31 is the right polish prompt for technical/imperative/code-adjacent speech: on Codex's code_speech_v1 bench it scored **77/100** vs v30's **69/100**, and v31's filter catches imperative-execution (answer-this-question, translate-this, write-a-poem) that v30 misses. Shipping one prompt costs us 8 points on one axis or 24 points on the other.

Prior art: peer voice-to-text apps (Superwhisper, WisprFlow) ship mode switches. Our users dictate both flavors freely; manual toggling would be friction; we need deterministic routing.

## 2. Goals & non-goals

### 2.1 Goals

- Add `ApplePolishMode` enum (`.natural`, `.technical`) in `Sources/EnviousWisprLLM/`.
- Add `ApplePolishRouter` with pure `classify(_:) -> ApplePolishMode` and `decide(_:) -> Decision` that exposes the signals.
- Every rule, list, and weight lives in one file for telemetry-driven tuning later.
- Unit tests cover every tier, every category the issue asked for (natural / exec / tech-imperative / tech-descriptive / spoken-literal / opener / self-correction / ambiguous mixed), plus empirical cases pulled from Gemini-100 and code_speech_v1.

### 2.2 Non-goals

- Wiring the router into `AppleIntelligenceConnector.polish(...)`. Follow-up PR.
- A second output filter. The existing `EnviousOutputFilter` is shared across both modes.
- Two separate prompts in source. Follow-up PR.
- Telemetry emission for route decisions. Follow-up issue (depends on router being wired).
- AI classifier, regex engine external to Swift, on-device model call for classification.

## 3. Design

### 3a. Tiered signal evaluation

Router evaluates in this order and short-circuits on the first positive match in Tier 1:

1. **Strong phrase** — regex-matched patterns like `(write|create|generate|draft|compose|build) a (python|sql|bash|swift|regex|...)`, `convert this into (json|yaml|...)`, `generate a (sql|regex) query`, `respond with json`. Short-circuits to technical.
2. **Preservation intent** — phrases like "preserve the words", "exactly as words", "dictate the words", "verbatim", "literally". Short-circuits to technical. *Runs before imperative-at-start so "Dictate the words ... exactly as words" routes via the more specific signal.*
3. **Hard imperative at sentence start** — first meaningful word (leading fillers like "um / uh / please / hey / okay / so / well" are skipped) is a hard imperative: `write, draft, generate, create, compose, build, make, convert, translate, summarize, summarise, paraphrase, rewrite, refactor, implement, turn, chart, plot, calculate, parse, compile`. Short-circuits to technical.

If none of the above matches, fall to Tier 2 additive scoring:

- **Conversational imperative at start** (+3, no cap since only first word counts): `send, schedule, remind, answer, respond, reply, list, record, administer, dictate`. These are casual/friendly imperatives common in ordinary speech ("Remind me to pick up eggs", "Schedule lunch with Sam"). Scoring — not short-circuiting — keeps bare conversational imperatives on natural while letting them tip technical when paired with code-adjacent signals.
- **Code/tech nouns** (+2 each, cap 2 hits): python, sql, regex, swift, json, markdown, yaml, api, endpoint, webhook, docker, github, kubernetes, react, typescript, javascript, repository, repo, commit, merge, branch, hotfix, function, prisma, tailwind, vercel, cors.
- **Spoken formatting nouns** (+2 each, cap 3 hits — higher because multiple distinct formatting words are unambiguous): bullet, heading, backtick, underscore, open paren, close paren, slash, quote, dash, colon, semicolon, etc.
- **Self-correction markers** (-1 each, cap -2): wait, no, sorry, actually, scratch that.
- **Filler words** (-1 each, cap -2): um, uh, you know, i mean, like, basically, honestly, essentially.
- **Threshold**: `technical` if final score ≥ 5; else `natural`.

All term matching uses `\b` word-boundary regex so "api" does not match "apiary", "swift" does not match "swiftly", and "no" does not match "note/not/nor". Per-term dedupe: a sentence with "bullet bullet bullet" contributes one hit for "bullet" (not three) — the cap governs *distinct* term variety, not repetition.

### 3b. Why this shape

- Strong phrases carry unambiguous intent; scoring them against a threshold wastes the signal.
- Preservation intent is more specific than a generic imperative — "Dictate the words ... exactly as words" is a preservation directive, not a dictation command; signal label should reflect that.
- Hard imperatives at sentence start short-circuit because the empirical data from v30 (shipped prompt family) shows v30 *drops* the imperative ("Draft an email about Q4" → "An email about Q4") or *executes* it ("Write a nursing note stating X" → "X") — both quiet trust losses. Better to route those to the more conservative technical mode.
- Conversational imperatives (send/schedule/remind/reply) score instead of short-circuiting because "Remind me to pick up eggs" or "Schedule lunch with Sam" are ordinary speech where filler cleanup (natural mode) matters more than verb preservation.
- Leading filler skip ("um, draft an email") ensures Priya's natural "um, draft the reply" still routes technical — the imperative is the intent even with a pause before it.
- Self-correction adds a mild natural pull but cannot flip a Tier-1 technical decision — "Write a Python script, wait no, a Ruby script" is still technical.

### 3c. File placement

`Sources/EnviousWisprLLM/ApplePolishRouter.swift` (alongside `EnviousOutputFilter.swift` and `AppleIntelligenceConnector.swift`). Test: `Tests/EnviousWisprTests/LLM/ApplePolishRouterTests.swift`.

## 4. Contract deltas

| What changed | Semantics | Invariants |
|---|---|---|
| New public enum `ApplePolishMode` | Which polish prompt family to use for a given transcript. Two cases today; never expand silently. | Callers must handle both cases. |
| New public enum `ApplePolishRouter` with `classify` and `decide` | Pure classifier over `String`. No side effects, no logging, no persistence. | Must be idempotent. `classify(x) == classify(x)` always. |
| New public enum `RouterSignal` | Structured signal cases: `emptyInput`, `strongPhrase(String)`, `preservationIntent(String)`, `imperativeStart(String)`, `conversationalImperativeStart(String)`, `techNouns([String])`, `spokenFormatting([String])`, `selfCorrection([String])`, `filler([String])`. | Telemetry-safe; rule tuning may add new cases but existing cases are stable. |
| New public enum `RouterBasis` | How the router reached its decision: `.empty` / `.tier1` / `.scored`. Distinguishes "technical because Tier-1 matched" from "natural because nothing scored" — same `.mode` but different tuning implications. | Stable set; additions only. |
| New public struct `ApplePolishRouter.Decision` | Logging vehicle — `mode`, `score`, `basis`, `signals`. | `signals` is a `[RouterSignal]` enum array, not free-form strings. Consumers should pattern-match on cases, not stringify. |

No consumer today. Follow-up PR wires `Decision.mode` into `AppleIntelligenceConnector.polish(...)` and `Decision.signals` / `Decision.basis` into breadcrumbs.

## 5. Integration plan (follow-up PR, not this one)

1. Add two prompt constants in `AppleIntelligenceConnector`: `onDeviceInstructionsNatural` (current v30 copy) and `onDeviceInstructionsTechnical` (copy v31 from `codex/afm-v31`).
2. In `polish(...)`, call `ApplePolishRouter.decide(text)` before `makeSession`.
3. Thread the resolved `ApplePolishMode` into `makeSession(mode:)`, which selects the corresponding prompt.
4. Log the routing decision (signals + chosen mode) via the existing `LLMTaskMetricsCollector` or a new debug breadcrumb for PostHog. Out of scope for this PR.
5. Keep `EnviousOutputFilter` unchanged and apply it to both modes' output.

## 6. Router rules in plain English

- If the sentence starts with a hard command verb (Write, Draft, Generate, Create, Convert, Summarize, Refactor, Translate, Turn, Build, Make, Paraphrase, Rewrite, Implement, Compose, Chart, Plot, Calculate, Parse, Compile) → technical. Leading fillers like "um" or "please" are skipped before checking.
- If the sentence contains a strong phrase like "write a Python script", "generate a SQL query", "convert this into JSON", or "respond with JSON" → technical.
- If the sentence asks for literal preservation ("preserve the words...", "dictate the words...", "exactly as said...", "literally", "verbatim") → technical.
- If the sentence has two or more code-world nouns (Python + JSON, branch + commit) OR three or more spoken-formatting words (heading + colon + bullet) → technical.
- Conversational imperatives (Send, Schedule, Remind, Reply, Answer) at sentence start add +3 score but don't short-circuit. Alone they stay natural; combined with code-world nouns they tip technical.
- Everything else → natural.
- Self-correction markers (wait / no / sorry / actually) and filler words (um / uh / like / you know / basically / honestly / essentially / i mean) both pull gently toward natural but cannot override a Tier-1 technical decision.

## 7. Ambiguous cases & how the router resolves them

| Input | Resolved mode | Why |
|---|---|---|
| "The script for tomorrow's demo is too long." | natural | "Script" is NOT in the tech-noun list (intentionally ambiguous: theatre script vs shell script). No imperative, no strong phrase. Score 0 → natural. |
| "Here is the issue, Apple Intelligence is enabled but the model is unavailable." | natural | Descriptive; opener phrase isn't a preservation directive; no imperative; "model" not in tech-noun list. |
| "Draft an email to Anand saying thanks for the intro." | technical | "Draft" at sentence start matches imperative-at-start. Short-circuits. Safer to preserve than to drop the imperative word. |
| "Let's write a blog post about the launch." | natural | "Let's" is first word; "write" is mid-sentence; no strong phrase; "blog post" not a tech noun. |
| "Convert this into JSON with fields for title owner and deadline." | technical | Strong phrase `convert this into json` matches. |
| "The branch is feature slash billing, no, hotfix slash billing." | technical | Tech-noun (branch + hotfix) = +4. Spoken formatting (slash) = +2 (dedupe — one distinct term). Self-correction "no" = -1. Score 5, threshold hit. |
| "Dictate the words import React from quote react quote exactly as words." | technical | Preservation intent ("preserve the words" / "exactly as words") short-circuits before imperative-at-start. |
| "My son wants me to write a story for bedtime." | natural | "Write" is mid-sentence, not at start; no strong phrase ("story" not in code-noun list). |
| "Please preserve the words write code in the blog post title." | technical | Preservation intent short-circuits. |

### 7.1 Known misroutes the router will make (accept as v1 tradeoffs)

- `"Can you write a quick summary of the meeting?"` → natural (mid-sentence "write", no tech noun). Intended: natural. Match.
- `"Generate some ideas for the offsite."` → technical (starts with "Generate", hard imperative). Intended: arguably natural. **Accepted misroute**: technical mode (v31) still produces reasonable output since it preserves the imperative rather than executing it. Cost is slightly-under-cleaned fillers on this class of sentence (-8 class).
- `"Summarize yesterday's all-hands for the team."` → technical (starts with "Summarize"). Intended: debatable. v31 preserves the imperative rather than actually summarizing — arguably correct given the user will paste into another tool.
- `"The SQL migration is broken."` → natural (one tech noun "sql", score 2, below threshold). Intended: probably natural, descriptive. Match.
- `"Remind me to check the PostHog dashboard."` → natural (conversational imperative +3, one tech noun not in list, below threshold). Intended: natural. Match.
- `"Send a GitHub invite to the new hire."` → tentatively natural (conversational imperative "send" +3, plus "github" tech noun +2 = 5 → technical). Actually routes technical. **Borderline**: this is an ordinary exec request; v31 preserves verbatim which is fine, but might lightly regress filler cleanup. Acceptable for v1; telemetry will tell us if this class is common.

Rule of thumb for v1: false-technicals are cheap (prompt is more conservative, still produces valid polish); false-naturals on actual imperatives are expensive (AFM executes them). The asymmetry in scoring (hard imperative-at-start short-circuits, conversational imperative just adds score) reflects the 3× asymmetric regression cost from the empirical data.

## 8. Testing

37 unit tests, all passing. Coverage by category:

- Tier 1 strong phrase: 4 tests (python script, sql query, json convert, regex)
- Tier 1 hard imperative-at-start: 6 tests (draft an email, summarize notes, refactor struct, translate, "let's" negative, leading "um" skip, leading "please" skip)
- Tier 1 preservation intent: 2 tests (preserve-the-words, dictate-the-words)
- Tier 2 technical-wins: 2 tests (spoken formatting heavy, branch+slash+self-correction)
- Tier 2 conversational-imperative natural: 4 tests (remind / schedule / send / reply)
- Tier 2 natural-wins: 4 tests (self-correction only, filler heavy, descriptive noun, opener phrase)
- Edge cases: 2 tests (empty, whitespace-only)
- Substring traps: 2 tests (apiary doesn't trigger api; swiftly doesn't trigger swift)
- Empirical Gemini-100 cases: 2 tests (push-to-thursday, honestly-conversational)
- Empirical code_speech_v1 cases: 2 tests (vercel descriptive, race-condition)
- Clinical speech: 4 tests (descriptive / hold-dose / stat-ekg → natural; write-nursing-note → technical)
- API shape: 2 tests (classify == decide.mode, basis observability distinguishes tier1/scored/empty)

Run: `scripts/swift-test.sh --filter ApplePolishRouter`. 37/37 pass locally.

## 9. Rollout plan

This PR: land router + tests. No behavior change for users.

Follow-up PR: wire router into `AppleIntelligenceConnector.polish(...)` + add second prompt. That's where user-visible behavior changes — run Gemini-100 + code_speech_v1 end-to-end before merging, verify no regression on either axis, write integration tests, optionally add a debug breadcrumb.

Follow-up issue: telemetry for misroutes (log the chosen mode alongside user's post-polish behavior; manual review of top N to tune the rules).
