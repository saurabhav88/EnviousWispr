# #1803 — replace the hand-authored word list with the macOS system dictionary

## Preface — Lane + Live UAT declaration

- **Lane:** `Code`
- **Tier:** MEDIUM (net-new runtime behaviour on the paste path; one module gains two system framework imports)
- **Live UAT:** Y — casing is only observable end to end; the founder's own reported case is the acceptance test
- **Modules:** PostProcessing (decision + runtime owner), Pipeline (deadline-bound caller), AppKit (launch-prewarm trigger)
- **Test:** required (PostProcessing)

## Preface — User Rubric

Primary persona: **Meera Patel** (Time-Pressed Parent), who has no proofreading budget and needs continuation dictation to work with zero setup. Safety persona: **Dr. Elena Vasquez**, whose names and formal notes make a wrong lowercase materially worse than a stray capital. Custom-vocabulary persona: **Priya Ramachandran**, whose technical names and brands must stay protected through Your Words.

*(An earlier draft cited a "power dictator" persona. No such persona exists in `personas.md`; the three above are the real cards. Caught by the coverage round.)*

1. **What does the user actually want?** To speak a partial thought, speak the rest a moment later, and have the two read as one sentence.
2. **What breaks today?** The second recording always arrives capitalised, because the speech engine treats every new chunk as a fresh sentence. `I can't wait to go to ` + `The museum tonight.` ships as `I can't wait to go to The museum tonight.`
3. **How often?** Every single continuation whose first word is not one of 799 hand-listed words. Measured: 23 of 35 ordinary openers covered, so roughly **one continuation in three is visibly wrong**.
4. **What does the user do about it?** Reaches for the keyboard and fixes the letter, which defeats the point of dictating.
5. **What would "fixed" feel like?** Nothing. The seam is invisible.
6. **What is the worst thing we could do instead?** Lowercase somebody's name. `mark said he would be late` is a worse artefact than a stray capital, because the stray capital reads as a machine quirk and the lowercase name reads as carelessness about a person.
7. **Does the user need to configure anything?** No. Smart Insertion is already on by default.
8. **Does the user need to understand anything new?** No.
9. **Cross-persona check.** Meera gets the improvement silently, with no setting and no setup. Dr. Vasquez's case makes name preservation and fail-closed behaviour the safety priority, which is why every failure path keeps the capital. Priya's Your Words entries outrank both the dictionary and the tagger. Non-English dictation is untouched. A user who never dictates mid-sentence never reaches this code.

**Onboarding: N/A.** This is a silent improvement inside the existing default-on Smart Insertion. It adds no permission, model download, setting, user choice, or first-run delay, and a machine lacking either system facility simply keeps today's capital without prompting.

## 0. TL;DR

Delete the 799-word hand-authored allowlist. Decide "may this capital be lowered?" from two facilities already in macOS: the **system spelling dictionary** (is the lowercase form an ordinary English word at all?) and **`NLTagger` part-of-speech over the joined sentence** (is it behaving as an ordinary word *here*, or as a name?), with a 12-word frozen exception set (each entry individually ablated), a learned-word refusal, and a single runtime owner that warms at launch and bounds every live decision with the existing `withOrderedDeadline`.

On the largest realistic sample available — 11,577 continuation rows derived from the local dictation store — recall rises from **70.5% to 75.9%**: 604 more lowercases attempted, 601 of them agreeing with the stored casing, against 3 more disagreements. The founder's own reported case is fixed. Those are characterisation counts, not certified precision (P14); the ship gate is a blinded human review of a deterministic sample.

## 1. Problem

`applyLeadingCase` lowers the first letter only when a committed resource — 830 physical lines carrying 799 entries — contains the word (`CursorInsertionRepair.swift:492`). The list cannot contain the English language. `go`, `send`, `call`, `buy`, `email`, `learn`, `sleep`, `watch`, `study`, `cook`, `pay` are all absent, so the founder's own test case stays broken. Growing the list is not a fix; the founder has rejected the approach outright:

> "Why are we trying to create our own custom list when we should just use something that is already available, such as the Apple solution or other pre-built dictionary systems? ... As if we can predict what people are going to say."

## 2. Goals & non-goals

### 2.1 Goals

- Word knowledge comes from the operating system, not from a file we maintain.
- The founder's reported case is fixed: `I can't wait to go to ` + `The museum tonight.` → `the museum tonight.`
- Precision on the lowercase decision stays **≥ 90%** (the founder's stated bar, 2026-07-26), evidenced by a blinded sample review rather than by a self-labelled corpus.
- The first paste after launch is not slowed: one-time setup moves off the paste path.
- A wrong decision fails in the safe direction: keep the capital, which is today's behaviour.

### 2.2 Non-goals

- **German and other languages.** Casing stays English-only. German is a separate, parked piece of work (branch `feat/1803-german-safe-words`) and inverts the rule; nothing here changes `LanguageRules.knowsCasing`.
- **The terminal / Ghostty spacing bug.** Separate, undiagnosed, tracked in #1803.
- **Brand names in general.** Custom Words remains the explicit protection path and is unchanged. **It is not, on this evidence, a mitigation for the disagreements this design actually produces:** re-measured against the corrected corpus, **0 of the 14** disagreement words appear in the real 32-entry custom-word set (P14). It protects what the user has already told it about, which is not the same population.
- **Removing the seam de-duplication or spacing rules** shipped in PR #1804.

## 2.5 Grounding brief

### 1. Trace producer → owner → consumer end to end

| Hop | Mechanism | Evidence |
|---|---|---|
| Caret text read from the focused app | `PasteService.readCaretContext` (AX) | `KernelFinalizationWiring.swift:369` |
| Language resolved from positive evidence | `DictationLanguageResolver.resolve` returns `String?`, `nil` when unsure | `DictationLanguageResolver.swift:79,87,90` |
| **Sole production caller of the repair** | `CursorInsertionRepair.repair(text:context:protectedWords:language:)` | `KernelFinalizationWiring.swift:376` |
| Word knowledge consulted | `lexicon.contains(bare)` | `CursorInsertionRepair.swift:492` |
| Decision recorded | `AppliedRule.telemetryName`, privacy-safe reason only | `CursorInsertionRepair.swift:124-125` |

```
$ grep -rn "CursorInsertionRepair\." --include="*.swift" Sources/ | grep -v PostProcessing/CursorInsertionRepair.swift
Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift:376:        let payloads = CursorInsertionRepair.repair(
Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift:379:            CursorInsertionRepair.CaretText(
```

**One production caller.** The blast radius is one function.

### 2. Find the existing authority before proposing one

`OrdinaryLowercaseLexicon` is the sole word-knowledge authority. No second one exists:

```
$ grep -rn "OrdinaryLowercaseLexicon|ordinary-lowercase-words" --include="*.swift" --include="*.py" --include="*.sh" --include="*.md" Sources/ Tests/ scripts/ docs/ | sort
```
Hits fall in exactly three places: `CursorInsertionRepair.swift`, the two committed resource files, and the test suite. **No `scripts/eval/` hit** — so there is no Swift↔Python mirror obligation for this resource (`validation-discipline.md` RULE: polish-quality-regression-gate names `CloudFixedPromptBuilder.cloudFixedSystemPrompt` and `CustomWordsManager.builtinDefaults`, neither of which is touched).

Capability grep for an existing spelling/dictionary/part-of-speech facility in shipped code:
```
$ grep -rn "NSSpellChecker|UITextChecker|checkSpelling|NLTagger|NSLinguisticTagger|lexicalClass|nameType" --include="*.swift" Sources/
(no matches)
```
`new authority proposed` — nothing in the app currently consults a system dictionary or a tagger.

### 3. Read prior attempts and live direction

- #1785 built the list deliberately, and documented WHY it was a product resource rather than a system lookup: determinism across machines and locales (`ordinary-lowercase-words.provenance.md:9-14`). **That decision is now overridden by the founder**, who has weighed the determinism against the coverage and chosen coverage.
- Codex review r7 on #1785 removed `general` from the list after `General Smith` was recased. The lesson stands: a homograph that is also a title/name is the failure mode to design against.
- PR #1804 (merged) added seam de-duplication, deliberately placement-only with no word knowledge (`CursorInsertionRepair.swift:381-385`).
- PR #1802 cloud review caught the language gate being bypassed on the default engine. The binding decision: **language must come from positive evidence, never from the engine's self-report.** Unchanged here.
- Founder direction 2026-07-26, verbatim: "replace the list ... but I don't want you to half hazzirdly swap it out -> so we're going to compact then create a plan for it."

### 4. Lifecycle, trust and process boundaries a naive design would miss

| Boundary | Today | Planned |
|---|---|---|
| Word knowledge source | committed file, byte-identical everywhere | **per-machine system service**; varies with the user's learned words and installed dictionaries |
| Failure mode of the source | parse fails → `isAvailable == false` → keep capitals | checker unusable → keep capitals (must be **explicitly** engineered; see the fail-open trap below) |
| Unknown language passed to the checker | n/a | **`checkSpelling(language: "xx")` reports EVERY word valid** — measured. Fail-OPEN, and the single most dangerous property of this API |
| Thread | pure value type, any thread | `NSSpellChecker` measured correct from 8 concurrent background threads with no `NSApplication` running |
| Module imports | Foundation, Core, os | **+ AppKit, + NaturalLanguage** in PostProcessing (§3b) |
| Cost on the paste path | set lookup | **0.30 ms** warm; 105.6 ms one-time setup moved off the paste path by the launch warm-up |

### 5. High-risk premises, proven

All figures below are from the real APIs on this machine, 2026-07-26, scripts retained in `docs/feature-requests/issue-1803-artifacts/`.

**P0 — word knowledge has exactly ONE consumer, and an earlier draft of this plan got that wrong.** I first wrote that the touching-full-stops rule also depends on the lexicon, taking it from the test-file comments at `OrdinaryLowercaseLexiconTests.swift:266-305`. That describes a **retired** contract. On current `main` the rule is purely positional and says so in its own comment:

```
$ sed -n '415,421p' Sources/EnviousWisprPostProcessing/CursorInsertionRepair.swift
    // What remains is not a judgement: if our text ends with a full stop and the
    // very next character is another one, the pair is a placement artifact we
    // would be creating, so we drop ours. No word knowledge, no lexicon, no
    // language, no abbreviation question.
    if out.reversed().drop(while: \.isWhitespace).first == ".",
      rightAnchor(of: context.right) == "."
```

The two tests that appear to assert the old contract pass a right-context of `"yesterday"`, so no touching full stop exists and the rule never fires for the reason their comments claim. **`applyLeadingCase` is the sole consumer of ordinary-word DECISIONS** (`isAvailable`/`contains` at `:489-493`). Two further references to the deleted type call only `normalizeApostrophes` — seam comparison at `:538-540` and the pronoun-`I` guard at `:724-725`. That helper is punctuation normalisation, not word knowledge; it is relocated before the type is deleted. An earlier draft said every lexicon-type reference sat inside `repair`, which was false. Spacing, seam de-duplication and the terminal-period rule are word-knowledge-free and must come through byte-identical.

**P1 — the system dictionary alone is unusable.** On a 38-case name corpus it wrongly lowercases **38/38** (`Mark`, `Grace`, `Slack`, `Google`, `Apple`, `Amazon`, `Tesla`…). Every one of those is a genuine English word (`tesla` is a unit, `amazon` a river, `obsidian` a mineral), so no dictionary can separate them. **A second signal is mandatory.**

**P2 — part of speech supplies a conservative safety FILTER, not a name recogniser.** The oracle accepts only the listed non-noun classes; `Noun`, `OtherWord` and no-tag keep the capital. That blocks many name readings, but it also refuses ordinary noun-led continuations, and P12's `Bill` evidence proves the tagger does not identify every name. An earlier draft claimed "names are always nouns" as though that made this a discriminator; the converse does not hold and the plan no longer implies it does.

**P3 — the existing 457-word exclusion class must NOT be reused as a production refusal list.** It contains `go`, `drive` and `cook`:
```
$ grep -cw "\"go\"" Tests/EnviousWisprTests/PostProcessing/OrdinaryLowercaseExclusionClass.swift
1
```
Reusing it unchanged would ship the entire change with the founder's own reported case still broken. It stays exactly what it is today: a **test-only** assertion, and it is deleted with the resource it guards.

**P4 — measured head-to-head**, 35 ordinary openers × 38 name continuations:

| Candidate | Coverage | Damage | Precision |
|---|---|---|---|
| Today's 799-word list | 23/35 | 0/38 | 100% |
| System dictionary alone | 35/35 | 38/38 | 47.9% |
| Gemini's proposal (`.nameType`, default-lowercase) | 35/35 | **20/38** | 63.6% |
| **Dictionary + part of speech + safe-noun set** | **34/35** | **4/38** | **89.5%** |

On a hand-built "realistic" corpus (names as the *subject* of the continuation): coverage 34/35, damage 1/34, 97.1%. **All of these author-written figures are DIAGNOSTICS ONLY and none of them gates anything** — P14 showed they mispredicted both precision and recall on realistic data. They are retained because they are useful for spotting failure shapes, not because they measure the shipped rule.

**P5 — two extra layers were measured and REJECTED.** Adding an `.nameType` veto, and adding a "does the capital carry meaning?" check (re-tag with the first word lowercased, refuse if the tag changes), each changed **zero** decisions across all 73 cases. They are not in the design. Cost without benefit is not a safety margin.

**P6 — a frozen compatibility-exception set needs BOTH contribution and safety evidence.** It is not claimed to be a complete grammatical class; §3 records the per-entry ablation, cuts three zero-contribution entries, and routes every exception-dependent decision through a separate human safety audit.

Original framing, retained for history: Refusing all nouns costs `Yesterday`, `Today`, `Tomorrow`, `Everything`, `Something`, `Nothing`, `Everyone`, `Anyone` (all tag `Noun`), and `yesterday` is an asserted shipped behaviour (`OrdinaryLowercaseLexiconTests.swift:80`). These are English indefinite pronouns and deictic time words — a closed grammatical class of ~15, not a vocabulary prediction.

**P7 — `NSSpellChecker` behaved correctly off-main in measurement; that is evidence, NOT an API guarantee.** 8 concurrent background threads returned 6/6 correct answers with `NSApplication` never run. Apple documents one shared checker per application (`NSSpellChecker.h:37-48`) and does not document thread safety. An earlier draft upgraded the measurement into a guarantee and then leaned the warm-up on it. The design no longer depends on the question: **all spell-checker access is serialised through `EnglishWordOracleRuntime`**, so warm-up and a live decision never touch the shared checker concurrently. (Live decisions run from the `@MainActor` delivery closure; launch prewarm deliberately runs OFF it — see the `@concurrent` prewarm below — and the runtime's `.warming` state prevents the two from overlapping.)

**P8 — the real caret window is 20 UTF-16 units, and my first corpus did not exercise that.** `PasteService.caretContextWindow = 20` (`PasteService.swift:422`); the repair never sees more (`PasteService.swift:446-472`). My original corpus had only 2 of 69 left contexts longer than that, so it was measuring an input the code never receives. **Re-measured** with 36 realistically long left contexts, every one clipped to the last 20 units exactly as `assembleCaretContext` does, including clips that start mid-word (`' I mentioned it and '`, `'can't wait to go to '`):

| Context | Coverage | Damage | Precision |
|---|---|---|---|
| Full sentence | 19/20 | 0/16 | 100% |
| **Clipped to 20 units (what ships)** | **19/20** | **0/16** | **100%** |

In this 36-case authored diagnostic, clipping to the production 20-unit window changed no decision. That shows the rule can work with the real input shape; it does **not** prove truncation is universally free, nor that every relevant context fits inside 20 units. Artifact: `2026-07-26-casing-20unit-window.swift`.

**P9 — the tagger has two contracts `NSSpellChecker` does not, both from the SDK headers.** `NLTagger` instances must not be used from more than one thread at a time (`NLTagger.h:56-60`), and a scheme/language pair may be **unsupported or its assets not yet loaded** on the current device, with asset requests completing asynchronously on an arbitrary queue (`NLTagger.h:40-42`, `:81-90`). CI never checks either (`.github/workflows/pr-check.yml`). Both are handled in §3: a fresh tagger per decision, and an availability probe that fails closed.

**P10 — the app is NOT sandboxed, so there is no entitlement trap.** `EnviousWispr.entitlements:19-25` omits `com.apple.security.app-sandbox` and says so explicitly. Hardened runtime is on (`scripts/build-release-dmg.sh:282-344`), which does not restrict either framework.

**P14 — LARGE APP-OUTPUT CHARACTERISATION, NOT GROUND TRUTH.** An earlier draft of this section claimed 11,562 "founder-labelled" pairs and called them ground truth. **That claim was false and grounded review r1 was right to reject it.** The generator splits stored dictations at mid-sentence word boundaries and reads `polishedText` when present, otherwise the raw transcript; the label is inferred from the casing **already present in the app's own output** (`2026-07-26-build-real-labelled-pairs.py:27-35,54-60`). Those are not founder corrections and not observed two-recording seams. The circularity is real: a name our own pipeline already lowercased is automatically labelled "safe to lowercase", so agreeing with that error scores as correct.

It remains the largest realistic sample available and is retained for **coverage characterisation and for surfacing suspicious words**, never as a precision certificate. Deterministic (sorted input, `random.seed(1803)`), **11,577 rows, 411 carrying a stored capital**.

| Candidate | Lowered | Agrees with stored casing | Disagrees | Recall |
|---|---|---|---|---|
| Today's 799-word list | 7,880 | 7,869 | 11 | 70.5% |
| **System dictionary + word type + 12 exceptions + learned-word refusal** | **8,484** | **8,470** | **14** | **75.9%** |

Stated exactly: the production design attempts **604 more lowercases**, of which **601 agree** with the stored casing, against **3 more disagreements**. Agreement among attempted lowerings is 99.83%. Characterisation counts, not independently verified fixes or damage.

**Third instrument correction, and the worst of them.** The scorer that produced an earlier version of this table still carried the **rejected 39-word** exception set — the 12 plus `nobody`, `somebody`, `none`, 18 greetings and 6 open-class nouns — so its 8,511/8,497/14 and 76.1% described a design we are not shipping. Caught by grounded review r4. The scorer now carries the shipped 12 and the figures above are its output. The lesson is recorded rather than buried: **an instrument that drifts from the design under test produces confident, wrong numbers**, and this is the third time in this plan (the others: a synthetic ungrammatical context, and a four-column schema change that broke every reader).

**These figures replace an earlier, unreproducible set** (11,562 rows / 460 stored-capital / 7,915-7,910-5 / 8,481-8,465-16). Grounded review r3 caught that my own schema change broke the generator's counter and all three Swift readers, so nothing downstream could be re-derived. Regenerated with sorted input and re-scored; the conclusion held and improved, but the numbers moved and the old ones are gone rather than kept alongside.

**The author-written corpora were misleading in both directions**, which is the durable lesson here: they predicted 89.5% precision and 97% coverage, against 99.83% agreement and 75.9% recall on realistic data. Constructed examples over-represent the adversarial case and under-represent ordinary speech. They are demoted to diagnostics.

The 14 disagreements are singletons spread across product and technical vocabulary — `Neural`, `Black`, `Hugging`, `Rung`, `German`, `Customize`, `Polish`, `Reddit`, `Bluetooth` — plus sentence-initial forms the split mislabels (`In`, `Any`, `The`, `Four`, `Let's`). Note the shipped list's own 11 disagreements are the same shape, so this is partly an artefact of the labelling, not purely a design difference. **Correction to an earlier claim, now twice revised.** I first wrote that brand homographs "fall through to the existing Custom Words mechanism". Against the superseded corpus that was already wrong — only `Claude` was protected. Re-measured against the corrected corpus and the shipped design, **none of the 14 disagreement words is in the real 32-entry custom-word set**. Custom Words is the right explicit protection path, but it demonstrably does not cover the disagreements this design produces, and the plan no longer implies it does. An earlier revision of this table also carried a "with Custom Words applied" row derived by hand and printed among measured rows; it was removed rather than re-dressed.

Note also that 5 of the 14 (`In`, `Any`, `The`, `Four`, `Let's`) are sentence-initial forms the splitting method mislabels rather than real names — the shipped list shows the same shape in its own 11 — so the genuine name-like disagreements number about 9.

**P15 — the learned-word refusal is real, and its positive control had to be forced.** The coverage round proposed refusing `NSSpellChecker.hasLearnedWord` entries because learned words skew toward names and brands. Scoring it changed **zero** decisions — but `~/Library/Spelling/LocalDictionary` is 0 bytes on this machine, so that was an untested path, not a proven no-op (`validation-discipline.md` RULE: verify-the-feature-not-the-crash). Forced control, state restored afterwards:

```
BEFORE learnWord: hasLearnedWord=false  spelledCorrectly=false
AFTER  learnWord: hasLearnedWord=true   spelledCorrectly=true   <- would become eligible to lower
hasLearnedWord("yesterday")=false, hasLearnedWord("go")=false   <- costs no ordinary vocabulary
AFTER  unlearnWord: restored, LocalDictionary back to 0 bytes
```

The claim holds: without the refusal, a word the user taught macOS becomes "an ordinary English word" and would be lowercased. **Adopted.**

**P13 — validated against 15,879 REAL dictations on this machine, which changed the design.** The transcript store holds 15,879 real dictations (13,654 English with a capitalised opener, 1,190 distinct first words). This is local-only user content: it is read on this machine to validate a decision, exactly as the privacy boundary permits, and **no transcript text, and no first-word list derived from it, is committed to the repo** — only counts and the resulting closed set of ordinary English discourse words.

*First attempt was a bad instrument, and it nearly produced a wrong conclusion.* Scoring real payloads against four fixed left contexts reported the oracle at 78.1% versus the list's 89.7% — apparently a regression. The cause was the instrument: most real payloads do not grammatically follow `"I was thinking that "`, so the tagger was reading ungrammatical joins. Re-tested in plausible continuations, the supposed losses tag correctly: `Testing`→Verb, `Okay`→Interjection, `Yeah`→Interjection, `Great`→Adjective, `First`→Adverb, `Draft`/`Open`/`Remember`/`Update`/`Use`/`Hold`→Verb. **The real-dictation corpus can validate the dictionary leg, but it cannot validate the context leg, because the store holds whole dictations and no genuine continuation PAIRS exist to draw on.** Stated as a limitation rather than papered over.

*What it found, and why that finding was ultimately REJECTED.* Five high-frequency openers tag `Noun` even in plausible continuations: `Hey` (390), `Hello` (45), `Yep` (40), `Question` (27), `Thanks` (16). That looked like a case for a second carve-out. It is **not part of the production design**: those are whole-dictation first words, not continuation openers, and on the corrected 11,577-row continuation corpus its closed-class half is worth +3 agreements and the full set +27, of which roughly 24 come from the six open-class nouns. Grounded review r1 also correctly noted it contained open-class vocabulary. No transcript-derived word list is committed. The exploratory measurement, for the record:

| Carve-out | Coverage | Damage | Precision |
|---|---|---|---|
| pronouns + time words only | 33/39 | 1/34 | 97.1% |
| **+ discourse markers** | **38/39** | **1/34** | **97.4%** |

Zero additional damage, five real openers recovered. Artifacts: `2026-07-26-casing-discourse-carveout.swift`, `2026-07-26-casing-loss-diagnosis.swift`.

**P12 — one class of case is unanswerable FROM THE TWO SIGNALS THIS DESIGN USES, and the founder's proposed dataset contains it.** A benchmark set supplied 2026-07-26 asks for `I am eating an ` + `Apple for snack.` to lowercase while `I am visiting the ` + `Apple store downtown.` keeps its capital, and the same split for `Please pay the Bill` versus `Please call Bill`. Measured, with both signals printed:

| Case | Want | lexicalClass | nameType | We do |
|---|---|---|---|---|
| `eating an Apple` | lowercase | Noun | OtherWord | keep capital ✗ |
| `visiting the Apple store` | capital | Noun | **OrganizationName** | keep capital ✓ |
| `pay the Bill` | lowercase | Noun | OtherWord | keep capital ✗ |
| `call Bill` | capital | Noun | **OtherWord** | keep capital ✓ |

`pay the Bill` and `call Bill` produce **identical signals** and opposite correct answers, so no threshold, veto or extra layer separates them — the tagger does not recognise `Bill` as a person even in `Please call Bill`. The accompanying claim that the tagger "distinguishes apple the fruit from Apple the company" does not hold: it returns `Noun`/`OtherWord` for the fruit reading, not a fruit classification.

Both failures land on **keep the capital**, which is today's behaviour, so they are missed coverage and never damage. The design accepts them. Scoring these two as failures against a coverage target would be scoring against an oracle no implementation can satisfy. 8/10 on that ten-case subset, with both misses in the safe direction. Artifact: `2026-07-26-casing-ambiguous-pairs.swift`.

**P11 — there is no executable checksum test.** The sha256 in the provenance record is prose only; the executable integrity pin is the 799-entry count assertion (`OrdinaryLowercaseLexiconTests.swift:27-32`). Deleting the resource removes both cleanly.

## 3. Design

`OrdinaryLowercaseLexicon` is deleted. `applyLeadingCase` consults a new `EnglishWordOracle`, which answers one question — *may this capitalised word be lowered here?* — in four ordered steps. Every step fails toward keeping the capital.

1. **Dictionary.** `NSSpellChecker.checkSpelling(of: word.lowercased(), language: <resolved English identifier>)` must report no misspelling. Refuse otherwise → `.notOrdinaryWord`.
2. **ONE frozen compatibility-exception set of 12 words, checked before the tagger** — `everything, something, nothing, anything, everyone, someone, anyone, everybody, yesterday, today, tomorrow, tonight`.

   These are **not** presented as the complete grammatical classes of English indefinite pronouns or deictic time words; those classes contain other members not listed. They are explicit compatibility exceptions for words measured to receive a refused `Noun` tag despite ordinary continuation use.

   **Round 2 correctly objected that the set was never ablated** — I had measured the deleted sibling but never 0-vs-15. Run on the 11,577 rows:

   | Configuration | Lowered | Agrees | Disagrees |
   |---|---|---|---|
   | no exceptions | 8,405 | 8,391 | 14 |
   | 15 exceptions | 8,484 | 8,470 | 14 |
   | **the exceptions buy** | — | **+79** | **+0** |

   Per-entry, three earn nothing and are **cut**: `nobody` (+0), `somebody` (+0), `none` (+0). Every survivor is justified individually — `something` +22, `everything` +15, `today` +13, `anything` +10, `everyone` +5, `tomorrow` +5, `nothing` +3, `someone` +2, `anyone`/`everybody`/`tonight` +1, `yesterday` +1 (also an existing shipped contract, `OrdinaryLowercaseLexiconTests.swift:78-110`) — all with zero new disagreements. An entry is retained only for a shipped contract or a measured contribution, never for belonging to a named class.

   **Robustness note:** this ablation was re-run from scratch after the corpus was regenerated with a corrected, reproducible schema. The per-entry deltas moved, but **the same three entries scored zero in both independent runs**, which is the reason to trust the cut.

   **A second "discourse marker" set was designed, measured and CUT.** It held greetings and politeness formulae plus six open-class nouns (`question, answer, note, reminder, update, example`). Grounded review r1 correctly identified that those six are a vocabulary guess selected from observed data — a smaller version of exactly what the founder rejected. Re-measured on the corrected 11,577-row corpus: its **closed-class half** (the 18 greetings and politeness formulae) buys **+3 agreements**, and grounded review r4 reports the full rejected set at **+27**. So roughly 24 of the 27 came from the six OPEN-class nouns — precisely the part that was indefensible. The earlier "one case in the whole corpus" figure came from the superseded corpus and is withdrawn. The set stays cut, but now for the honest reason: its value sat almost entirely in hand-authored vocabulary, not in a bounded grammatical rule. The 518 occurrences that motivated it were first words of whole dictations, not continuation openers, and barely arise in the population that reaches this rule. Cut entirely rather than defended: the defensible half is worth 3 decisions in 11,577, and the rest of its value came from exactly the hand-authored vocabulary the founder rejected.

   Noun-led misses stay safe-direction misses. They are reported after release and do **not** automatically create new exceptions; if recall pressure ever produces repeated noun exceptions, this design has degenerated back into a word list and should be reconsidered wholesale.
3. **Part of speech in context.** `NLTagger(.lexicalClass)` over `left + payload`, read at the payload's first word. Accept only `verb, adverb, conjunction, determiner, pronoun, adjective, preposition, particle, interjection, number`. `Noun`, `OtherWord`, and *no tag at all* refuse → `.wordClassNotSafe`.
4. Existing guards (protected/custom words, mixed case, digits, pronoun `I`, weekdays and months) run **before** all of this and are unchanged.

### The fail-open trap, and what actually closes it

Measured: `checkSpelling(language: "xx")` reports **every** word correctly spelled. An unrecognised or missing dictionary does not degrade to "no answer", it degrades to **"yes to everything"** — which would lowercase names wholesale.

The guard is to make that path unreachable: **resolve the language exactly once from `NSSpellChecker.availableLanguages`**, which Apple defines as the languages actually available (`NSSpellChecker.h:150-160`), and fail closed when no English identifier exists. An invalid identifier is then never passed at all.

**A nonsense-word canary was designed and CUT.** It would have asked the checker about `qwertyuiopzxcv` and declared the oracle unavailable if that came back valid. Grounded review r1 was right on both counts: `availableLanguages` is the documented authority, and the canary is itself corruptible — any user can teach macOS that exact word via `learnWord`, turning the health check into a permanent false outage. Removing an event you can make impossible beats detecting it (`workflow-process.md` RULE: close-the-window-never-handle-it).

Unavailable → `.caseSkipped(.dictionaryUnavailable)` → capital kept → today's behaviour. This is the same fail-closed contract the resource had, engineered against a different failure mode.

### English selection and per-user dictionary state

The oracle never uses `NSSpellChecker.language`, the user's currently selected spell-check language, or a `nil` language argument. It filters `NSSpellChecker.availableLanguages` to identifiers whose normalised base language is `en`, sorts them for deterministic selection, and takes the first. If no English identifier exists, the oracle is unavailable and keeps the capital. **Measured:** with the Mac's checker set to German and then French, an explicit English identifier still answered correctly (`yesterday` valid), while passing an empty language returned "misspelled" — so without this the feature would silently die for anyone whose spell-checker is not English.

```swift
static func resolveEnglishLanguage(from availableLanguages: [String]) -> String? {
  availableLanguages
    .filter { identifier in
      identifier
        .replacingOccurrences(of: "_", with: "-")
        .split(separator: "-", maxSplits: 1)
        .first?
        .lowercased() == "en"
    }
    .sorted()
    .first
}
```

Learned words are refused as ordinary-word evidence (P15): `guard !spellChecker.hasLearnedWord(lowercaseWord) else { return .refuse(.learnedWord) }`. The oracle owns a fresh spell-document tag and never inherits another document's ignored-word list.

### Your Words and macOS Learned Words are not the same thing

EnviousWispr Your Words is the explicit preservation authority: a matching protected spelling refuses recasing **before any system lookup**, including when the dictionary considers the lowercase form ordinary. macOS Learned Words is not a substitute and is treated as evidence against lowering, not for it. No onboarding or settings copy should tell users to manage the macOS dictionary for this feature.

### "Keep the capital" means one specific thing

It is a leading-case guarantee, not a byte-identical-payload guarantee. Every refusal path preserves the payload's original first grapheme and omits `.lowercasedFirst`; the independent spacing, seam de-duplication and touching-period rules may still run afterwards.

### The tagger's two contracts

- **A fresh `NLTagger` per decision.** The SDK forbids concurrent use of one instance (`NLTagger.h:56-60`). Production is single-threaded on the main actor, but a shared instance would be a latent trap for any future caller and buys nothing: construction is inside the measured 0.30 ms.
- **An availability probe, fail-closed.** `NLTagger.availableTagSchemes(for: .word, language: .english)` must contain `.lexicalClass`. If the asset is absent the framework returns no tag rather than an error (`NLTagger.h:81-90`), which our step 3 already refuses — but the probe makes the state explicit and reportable rather than presenting as "every word is a noun". **We never request an asset download**; a machine without the model keeps its capitals.

### Things that must NOT move

Three orderings are load-bearing and this change must leave them byte-identical:

1. **Protected/custom words are checked BEFORE any system knowledge** (`CursorInsertionRepair.swift:474-493`). Asking the dictionary first would silently weaken the Custom Words contract.
2. **Leading case runs BEFORE seam de-duplication** (`:341-398`). Reversing it retargets casing onto the second word — the grounded-review r1 defect on PR #1804, frozen by `CursorInsertionRepairTests.swift:1399-1419`.
3. **`normalizeApostrophes` is NOT word knowledge and must survive the deletion.** It is a static helper on the type being removed, and seam de-duplication (`:532-540`) and the pronoun guard (`:718-725`) both call it. It moves to file scope in `CursorInsertionRepair`; deleting it wholesale would break PR #1804 code that has nothing to do with the lexicon.

### What the residual damage costs, stated plainly

One name in the realistic corpus is still lowered: `Olive`. The mitigations are the ones that already exist — Custom Words protects any spelling the user names (`startsWithProtectedSpelling`, `CursorInsertionRepair.swift:706`), and the error is one keystroke. This is an honest regression against today's 100% precision, bought for +11 coverage cases including the founder's own. It is the trade the founder asked for; it is not hidden.

## 3b. Ownership justification

`EnglishWordOracle` remains in PostProcessing because it implements PostProcessing's own leading-case policy, has one consumer inside `CursorInsertionRepair`, holds no app or pipeline state, and returns a synchronous value. The strongest alternative is a new leaf `EnviousWisprLanguageServices` module implementing a public `EnglishWordDeciding` protocol, constructed and injected by Pipeline. That would preserve PostProcessing's present framework purity, but it requires a new target in both build systems, new cross-module public API, Pipeline composition changes at the heart-path caller, and REFACTOR-tier validation for one implementation and one consumer. That structural cost is larger than the boundary benefit here. The AppKit and NaturalLanguage imports are therefore an **intentional PostProcessing boundary expansion, not a convenience accident.**

**Scheduling and execution are split deliberately.** PostProcessing owns preparation *state* and *execution*; the app shell owns only **when preparation starts**, because launch sequencing is the shell's job. `WisprBootstrapper` triggers the non-blocking prewarm and never reads, derives or mutates oracle availability. That mirrors the classifier prewarm exactly.

The import cost is real and disclosed: **PostProcessing gains `AppKit` and `NaturalLanguage`.** Today it imports only Foundation, `EnviousWisprCore` and `os`.

- No first-party dependency direction changes. `scripts/check-dependency-direction.sh:36` keeps `EnviousWisprPostProcessing -> EnviousWisprCore`; AppKit and NaturalLanguage are system frameworks, not modules in that graph.
- Every consumer of PostProcessing in the shipped app already links AppKit — Pipeline (`KernelFinalizationWiring.swift:1-6`), the app shell (`AppDelegate.swift:1`) and the test bundle. Nothing new reaches the product.
- `NaturalLanguage` is already used in Pipeline by `DictationLanguageResolver` (`DictationLanguageResolver.swift:1-4`), so it is new only to PostProcessing.
- The **ASR XPC helper does not depend on PostProcessing** (`Package.swift:189-200`), so it acquires neither framework and this code never runs there.
- **One genuinely new link:** `scripts/eval/alias_runner` is a standalone CLI consuming the PostProcessing product (`scripts/eval/alias_runner/Package.swift:16-24`). It would newly link AppKit. It is an offline eval harness, not shipped, and it does not call cursor repair; recorded here rather than discovered at build time.
- **Declared boundary expansion:** PostProcessing is documented as Core-only in `.claude/knowledge/architecture.md:21-24`. That line is updated in this change rather than left to drift.
- Testability is preserved by keeping the oracle an injectable value on the existing `lexicon:` test seam (`CursorInsertionRepair.swift:246`), so unit tests never touch the system service.

## 3c. Single-authority check

| Concern | Owner before | Owner after |
|---|---|---|
| "is this an ordinary lowercase word" | `OrdinaryLowercaseLexicon.contains` | `EnglishWordOracle.mayLower` |
| "is this word a name here" | *nowhere* (approximated by the list's omissions) | `EnglishWordOracle`, step 3 |
| protected/custom spellings | `startsWithProtectedSpelling` | unchanged |
| weekdays and months | `alwaysCapitalized` | unchanged |
| pronoun `I` | `isFirstPersonPronoun` | unchanged |

One authority in, one authority out. No concern gains a second home.

§3c-answer: consolidated to EnglishWordOracle; deletes OrdinaryLowercaseLexicon, ordinary-lowercase-words.txt, and OrdinaryLowercaseExclusionClass. applyLeadingCase remains the sole consumer of word knowledge; startsWithProtectedSpelling, alwaysCapitalized and isFirstPersonPronoun keep their existing separate concerns and are deliberately NOT folded in, because they are closed sets that must outrank any dictionary answer.

## 4. Contract deltas

| Symbol | Before | After |
|---|---|---|
| `OrdinaryLowercaseLexicon` | struct + bundled resource | **deleted** |
| `ordinary-lowercase-words.txt` | committed resource, **830 physical lines / 799 entries** | **deleted** |
| `ordinary-lowercase-words.provenance.md` | committed record | **deleted** |
| `OrdinaryLowercaseLexicon.normalizeApostrophes` | static on the deleted type | **relocated**, not deleted — two live PR #1804 consumers (`:538-540`, `:724-725`) |
| `EnglishWordOracle` | — | new, internal to PostProcessing |
| `CaseSkipReason.notKnownLowercase` | `not_known_lowercase` | **renamed** `.notOrdinaryWord` = `not_ordinary_word` |
| `CaseSkipReason.lexiconUnavailable` | `lexicon_unavailable` | **renamed** `.dictionaryUnavailable` = `dictionary_unavailable` |
| `CaseSkipReason.wordClassNotSafe` | — | new, `word_class_not_safe` |
| `CaseSkipReason.wordClassUnavailable` | — | new, `word_class_unavailable` |
| `CaseSkipReason.learnedWord` | — | new, `learned_word` |
| `CaseSkipReason.oracleWarming` | — | new, `oracle_warming` |
| `CaseSkipReason.oracleTimedOut` | — | new, `oracle_timed_out` |
| `repair(…, lexicon:)` test seam | `OrdinaryLowercaseLexicon` | `EnglishWordOracle` |

Corrections from grounded review r1, all verified: the new cases land on **`CaseSkipReason`, not `AppliedRule`** (`AppliedRule` only carries `.caseSkipped(reason)`); the resource is **830 physical lines** carrying 799 entries; and `.wordClassUnavailable` / `.learnedWord` were promised in §8 but missing from this table — the kind of split taxonomy that ships as a telemetry gap.

Telemetry names change. They are privacy-safe reason codes with no dashboard alert bound to them; the rename is deliberate so that a dashboard reading `lexicon_unavailable` after this ships is visibly stale rather than silently wrong.

## 5. E2E state & lifecycle audit

| Class | Question | Answer |
|---|---|---|
| Interrupted | ordered deadline wins mid-decision? | Result abandoned; runtime latched `.oracleTimedOut` before paste resumes; the late result cannot publish (`claim()`). |
| Deleted | resource removed under us? | **Eliminated** — there is no resource any more. |
| Mutated | user changes spell-check language mid-dictation? | The oracle resolves English once per process. A mid-flight change cannot tear a decision. |
| Concurrent | warm-up or a second decision touching the shared checker? | Impossible by construction: `.warming` refuses without touching it, one `@MainActor` session serialises decisions, and the permanent timeout latch means no later call can race an abandoned one. |
| Nil | no English dictionary installed? | `availableLanguages` yields no English identifier → `.dictionaryUnavailable` → capital kept. |
| Stale | cached identifier disappears, or an old call finishes late? | Membership is revalidated against `availableLanguages` before every lookup; a late call is discarded by the deadline's own `claim()`. |

## 6. Downstream consumer matrix

| Consumer | Reads | Effect |
|---|---|---|
| `KernelFinalizationWiring:376` | `repairedText`, `candidateRules` | more continuations now carry `.lowercasedFirst`; no shape change |
| Paste cascade | `repairedText` | unchanged |
| Telemetry | `AppliedRule.telemetryName` | two renamed and five new `CaseSkipReason` strings; `AppliedRule` itself gains none |
| `legacyText` | untouched by casing | unchanged — the raw fallback never depends on this |
| `PasteCompletionRegistry` | the committed repaired text (`KernelFinalizationWiring.swift:438-453`) | **second-order effect:** it learns from the user's edits to what was pasted (`PasteCompletionRegistry.swift:3-17`), so a casing decision now also shifts the baseline that later learning compares against. Not a defect — but it means a wrong lowercase is not purely cosmetic, which strengthens the case for failing toward the capital |

## 7. Failure-mode × caller table

| Failure | Behaviour | Heart-path effect |
|---|---|---|
| No English dictionary | capital kept | none — raw text still pastes |
| Invalid or stale dictionary identifier | Never queried: the identifier comes from `availableLanguages` and membership is revalidated before each lookup. Failure keeps the capital. | none |
| `.lexicalClass` asset missing on device | availability probe fails → oracle unavailable, capital kept | none |
| Tagger returns no tag for the word | refuse → capital kept | none |
| Caret unreadable | `context == nil` → legacy payload only, existing path | none |
| Non-English dictation | `.languageNotSupported` before the oracle is consulted | none |
| First-call setup is cold | `.warming` refuses casing; setup stays off the paste path | measured 105.6 ms, off path; an early paste keeps today's capital |

**On that last row — an earlier draft of this plan was WRONG, and grounded review r1 caught it.** I wrote "measured cold cost is 1.33 ms, far inside the 100 ms negligible threshold." That number was only the spell-checker's first lookup. It omitted the two expensive calls. Measured properly in a cold process, everything that would land on the first stop-to-paste after launch:

| First-call work | Cost |
|---|---|
| `NLTagger.availableTagSchemes` availability probe | **80.3 ms** |
| Resolve English from `availableLanguages` (43 entries) | **20.2 ms** |
| First `checkSpelling` | 1.4 ms |
| First tagger decision | 3.7 ms |
| **Cold total on the first paste** | **105.6 ms** |
| Warm decision thereafter | 0.30 ms |

`repair` runs synchronously on the main actor with no timeout (`KernelFinalizationWiring.swift:373-412`), so that 105 ms would be a real, reproducible regression on the first dictation after every launch — over the 100 ms negligible threshold, and on the heart path.

**The fix is to remove the cost, not to bound it.** The 100 ms is entirely one-time setup, so the oracle resolves its language and probes scheme availability **once at app start, off the paste path**, and primes both services with one throwaway decision. Measured:

| | Cost |
|---|---|
| Warm-up, once, at startup | 84.9 ms (off the paste path) |
| **First paste after warm-up** | **0.50 ms** |

**I REJECTED grounded review r1's proposed deadline, on two premises that were both FALSE. Round 2 caught it and the rejection is reversed.** I argued it "makes the heart-path delivery closure async" and would be new machinery. Verified against code:

- `deliver` is **already async**: `let deliver: @MainActor (_ text: String) async -> KernelDeliveryOutcome` (`KernelFinalizationWiring.swift:153`).
- `withOrderedDeadline` **already exists** in Core (`TaskTimeout.swift:106`) and is already used on the heart path by `ParakeetEngineAdapter.swift:202`, which documents why ordered is preferred over bare `withDeadline`.

So the deadline is a proven in-house facility on an already-async path, not new machinery. **Warm-up and deadline solve different problems and both are required:** warm-up removes the *normal* 105 ms cold cost; the deadline bounds an *abnormal* stall in a system service we do not control. `NSSpellChecker` is backed by a separate spell server, so a hang is a real category, not a hypothetical race.

Residual, stated plainly: a machine where the lexical-class asset is genuinely absent is still unmeasured. The design probes availability, never requests a download, and keeps the capital when the probe fails.

#### CONSOLIDATION: `EnglishWordOracleRuntime` is the single runtime owner

Grounded review r2 named the same root for the second consecutive round — *the oracle has no one owner for readiness, availability, timeout and permanent fail-closed state* — which triggers stop-and-consolidate (`grounded-review-mechanics`; founder Rule 18). Rather than patch another symptom, the whole space is enumerated here and given one owner.

**`EnglishWordOracleRuntime` (PostProcessing) owns exactly four things** and nothing else owns any of them:

| Concern | Behaviour |
|---|---|
| **Readiness** | `.warming` until preparation completes. A decision arriving first refuses with `.oracleWarming` — casing keeps the capital while spacing and seam de-duplication continue normally. |
| **Availability** | `.ready(oracle)` or `.unavailable(reason)`. The English identifier is chosen from `availableLanguages` at preparation, and **re-validated as still present before each lookup**, so a dictionary removed mid-process cannot recreate the stale-identifier path. |
| **Timeout** | On a live timeout the runtime is set `.unavailable(.oracleTimedOut)` **synchronously, before paste resumes**, so a later paste cannot race an abandoned call against AppKit's one shared checker. Permanent for the process. |
| **Exclusive access** | At most one call is ever in flight against the shared `NSSpellChecker`, by construction (below), which removes the undocumented-thread-safety question (P7) instead of depending on a measurement. |

#### The synchronisation contract, and why ONE lock is enough

Grounded review r3 identified a genuine blocker: **if a serial queue held a lock during a stalled system call, `onTimeout` would block trying to take that same lock, and paste would hang despite having a deadline.** Verified — `withOrderedDeadline` runs `onTimeout()` to completion *before* `continuation.resume` (`TaskTimeout.swift:127-133`), and `onTimeout` is `@MainActor`, so blocking there blocks the main actor. It proposed two synchronisation domains plus a generation counter.

**A serial queue is not needed at all, because concurrency is eliminated rather than managed.** One lock, held only for brief state reads and writes and *never* across a system call:

1. **Warm-up never overlaps a decision.** While `.warming`, every decision refuses with `.oracleWarming` without touching the checker. `.ready` is published only after warm-up has finished touching it.
2. **Two decisions never overlap.** There is one recording session at a time and `deliver` is `@MainActor` (`KernelFinalizationWiring.swift:153`), so decisions are already sequential.
3. **A timed-out call is never raced, because the latch is permanent.** `onTimeout` takes the state lock briefly and sets `.unavailable(.oracleTimedOut)` for the rest of the process. The abandoned call is not holding that lock — it released it before the system call — so there is no deadlock, and no *later* call can reach the checker to race it.
4. **Late results cannot publish, and cannot corrupt state either.** `withOrderedDeadline`'s own `claim()` discards the losing decision (`TaskTimeout.swift:120-133`), so no generation counter is needed. But `claim()` does **not** roll back side effects inside the operation — grounded review r4 found the one reachable path: a stalled call that later discovers the identifier is missing would write `.unavailable(.dictionaryUnavailable)` over the timeout latch. It cannot re-block paste or permit another checker call, but it violates the documented permanent-timeout transition and mislabels the telemetry. Every operation-side write is therefore an **expected-state transition** — `.ready` may become unavailable only while it is still `.ready`:

```swift
private static func markUnavailableIfReady(_ reason: CaseSkipReason) {
  stateLock.withLock { state in
    guard case .ready = state else { return }
    state = .unavailable(reason)
  }
}
```

A stalled warm-up needs no deadline either: the state simply stays `.warming`, every decision refuses, and capitals are kept — which is today's behaviour.

**Nothing here is a new primitive.** `OSAllocatedUnfairLock(initialState:)` is already the in-repo pattern for exactly this shape — brief state mutation behind a lock — at `RecoverySpoolWriter.swift:51` and `DebugZeroFillController.swift:54`, and the package targets macOS 14 (`Package.swift:8`), well past its availability. The deadline, the prewarm call site and the lock are all ports of shipped patterns; the only genuinely new code is the decision itself.

**Binding transitions** (complete; anything not listed is unreachable):

| From | Event | To / result |
|---|---|---|
| initial | runtime constructed | `.warming` |
| `.warming` | preparation succeeds | `.ready(oracle)` |
| `.warming` | preparation fails | `.unavailable(reason)` |
| `.warming` | decision arrives | refuse `.oracleWarming`; state unchanged; checker untouched |
| `.ready` | decision succeeds | return decision; state unchanged |
| `.ready` | English identifier no longer in `availableLanguages` | `.unavailable(.dictionaryUnavailable)` |
| `.ready` | ordered deadline wins | `.unavailable(.oracleTimedOut)`, set before paste resumes |
| any | late completion of a timed-out call | decision discarded by `claim()`; **and every operation-side state write is conditional on still being `.ready`**, so it cannot overwrite the timeout latch |
| `.unavailable` | any later decision or repeated prewarm | refuse the stored reason; checker never touched again |

**Test obligation:** a fake checker that blocks past the deadline must show `onTimeout` completing without waiting on it, paste resuming with `legacyText`, the runtime latched permanently at `.oracleTimedOut`, a second decision never entering the fake at all, and the first call's late release neither restoring `.ready` nor publishing its result.

#### The two type shapes, so the build does not re-litigate them

`EnglishWordOracle` is a **value**, not a service — it keeps the existing `lexicon:` test seam working unchanged, so unit tests inject fixed answers and never touch a system service:

```swift
struct EnglishWordOracle: Sendable {
  let isAvailable: Bool
  /// Is the lowercase form an ordinary English word?
  let isOrdinaryWord: @Sendable (String) -> Bool
  /// Is the word learned by this user's macOS dictionary?
  let isLearnedWord: @Sendable (String) -> Bool
  /// Lexical class of the payload's first word, given the left window.
  let wordClass: @Sendable (_ left: String, _ payload: String) -> NLTag?

  static func unavailable(reason: CursorInsertionRepair.CaseSkipReason) -> EnglishWordOracle
}
```

`EnglishWordOracleRuntime` is the **only** thing that builds a live one, owns the state above, and is the sole caller of `NSSpellChecker` / `NLTagger`. `CursorInsertionRepair` never imports either framework directly — it consumes the value. That keeps the pure decision logic testable with zero system dependency and confines the two new framework imports to one file.

If review still finds a reachable path where a stuck call blocks paste, that is a founder escalation, not another revision round.

`WisprBootstrapper` only **triggers** prewarm, beside the existing `prewarmOutputClassifierIfNeeded` call (`WisprBootstrapper.swift:1017`).

**`WisprBootstrapper` is `@MainActor`, so a plain `Task { }` INHERITS the main actor** and would run the ~76-85 ms of synchronous language-resolution and availability-probe work there — reintroducing the stall this design exists to remove, just at launch instead of at paste. The prewarm entry point is therefore `@concurrent` and the call site awaits it off the caller's actor (`swift-concurrency-patterns.md` `cpu-work-explicit-offload`):

```swift
@concurrent
package static func prewarm() async { … }
```
```swift
Task { await EnglishWordOracleRuntime.prewarm() }
``` It must never become a second availability authority. Custom Words stays with `startsWithProtectedSpelling` and is not duplicated inside the oracle.

**Contract details verified against `TaskTimeout.swift:106-134` so the build does not rediscover them:**

- `withOrderedDeadline(seconds:operation:onTimeout:)` takes `operation: @escaping @Sendable () async -> T` and `onTimeout: @escaping @Sendable @MainActor () -> Void`. `onTimeout` **MUST be synchronous, non-throwing and non-suspending** — the file documents that an async hook would recreate the same ordering race one layer down. `EnglishWordOracleRuntime.disableAfterTimeout()` therefore takes a lock and returns; it never awaits.
- Everything the closure captures is already `Sendable`: `CaretText` (`:26`), `PreparedPayloads` (`:141`), plus `String` and `Set<String>`. No new conformance is needed.
- `onTimeout` runs to completion **before** the caller resumes, which is exactly the ordering this design needs: the runtime is disabled before paste continues, so a later paste cannot race the abandoned call.
- `operationTask.cancel()` is documented best-effort and **cannot preempt a blocked thread**. That is precisely why the runtime must latch `.unavailable(.oracleTimedOut)` permanently rather than retry.
- `PasteExecutionMetricsTests` enumerates rules in a **hand-maintained** array (`:66-78`) and asserts only that the listed names are distinct. It will therefore *not* fail automatically when the five new reasons are added — they must be added to that array deliberately, or the coverage claim in its own comment ("the whole set, so a rule added later without a name cannot slip through") becomes false.

**The earlier "the race is designed out" paragraph was wrong** and is removed. It claimed a `static let` made an early paste "slower, never wrong" — true for correctness, but it silently reintroduced the full 105 ms onto the first paste, which is the exact defect the warm-up exists to prevent. Refusing with `.oracleWarming` is the honest behaviour: the first paste after a cold launch keeps its capital, which is today's behaviour, instead of being slow.

Every failure lands on "keep the capital", which is exactly what the app did before this feature existed. The limb cannot damage the heart.

## 8. Caller-visible signals audit

`CaseSkipReason` renames two cases and adds five: `.wordClassNotSafe`, `.wordClassUnavailable`, `.learnedWord`, `.oracleWarming`, `.oracleTimedOut`. **`AppliedRule` gains no cases** — it continues to carry every reason through `.caseSkipped(reason)`. Earlier drafts said three, five and one in three different sections; that split taxonomy is exactly how a telemetry gap ships. `PasteExecutionMetricsTests` asserts rule-name strings and must be updated in the same commit. No public API leaves PostProcessing.

Telemetry distinguishes `.dictionaryUnavailable`, `.wordClassUnavailable`, `.learnedWord`, `.oracleWarming` and `.oracleTimedOut` as separate reasons — they are different deployment failures and collapsing them would make the first release window unreadable. None carries the word, the surrounding text, the selected dictionary identifier, or any other user content.

**What telemetry can and cannot tell us.** `repair_rules` plus `payload_kind` report how often the feature applies and how often either system facility is unavailable. They **cannot** determine whether a lowercase decision was semantically correct, so the first-window review is an availability and application-rate check, not a precision claim. Any correctness conclusion needs locally reproduced text or a direct user report. The plan does not claim telemetry will detect a lowercased name.

## 9. Fallback source-of-truth audit

`legacyPayload(text)` remains the single fallback and is computed before any word knowledge is consulted (`CursorInsertionRepair.swift`, `repair` entry). Nothing in this change can make the legacy payload depend on the dictionary.

## 10. File-by-file changes

| File | Change |
|---|---|
| `Sources/EnviousWisprPostProcessing/Resources/ordinary-lowercase-words.txt` | **delete**: 830 physical lines carrying 799 entries |
| `Sources/EnviousWisprPostProcessing/Resources/ordinary-lowercase-words.provenance.md` | **delete** |
| `Sources/EnviousWisprPostProcessing/EnglishWordOracle.swift` | **new** — the pure decision: dictionary, bounded exceptions, part of speech |
| `Sources/EnviousWisprPostProcessing/EnglishWordOracleRuntime.swift` | **new** — THE single runtime owner: readiness, availability, timeout, permanent fail-closed state |
| `Sources/EnviousWisprPostProcessing/CursorInsertionRepair.swift` | delete `OrdinaryLowercaseLexicon` (relocating `normalizeApostrophes`); `applyLeadingCase` takes the oracle and the joined context; rename two skip reasons and add five |
| `Tests/.../OrdinaryLowercaseLexiconTests.swift` | **delete** — it tests a file-format parser that no longer exists. Its 457-word exclusion assertion (`:61-64`) and 799-entry pin (`:27-32`) go with it |
| `Tests/.../OrdinaryLowercaseExclusionClass.swift` | **delete** — it asserts absence from a resource that no longer exists |
| `Tests/.../EnglishWordOracleTests.swift` | **new** — deterministic injected contract tests ONLY. The transcript-derived corpus is never embedded; it is a local characterisation run (§11.2) |
| `Tests/.../CursorInsertionRepairTests.swift` | update the prototype seam and the renamed reasons |
| `Tests/.../PasteExecutionMetricsTests.swift:66-78` | enumerates every telemetry reason; must cover all **seven** changed names: two renames plus five additions |
| `Tests/.../KernelFinalizationWiringTests.swift` | **six** tests assert lowering through the real bundled source (`:505-535`, `:734-767`, `:906-929`, `:1009-1043`, `:1076-1096`, `:1098-1158`) — not five as an earlier draft said. Preserve each one's actual contract under the new oracle |
| `Sources/EnviousWisprCore/Transcript.swift:20` | **missed by earlier drafts** — the `repairRules` doc comment quotes `case_skipped:not_known_lowercase` verbatim and must track the rename |
| `docs/.../2026-07-26-casing-headtohead.swift`, `2026-07-26-score-real-labelled-pairs.swift` | both read the deleted resource for their baseline column. **Decided:** retained as historical, explicitly non-rerunnable artifacts; each gains a header stating the commit and resource version that produced its recorded baseline |
| `Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift:1017-1023` | add the oracle warm-up beside the existing classifier prewarm, same `Task { }` shape, same off-heart-path call site |
| `.claude/knowledge/architecture.md:22` | PostProcessing documented as Core-only; record the two system frameworks. **Gitignored** (`.gitignore:33`), so this is a separate local `Docs/dev-tooling` edit and cannot appear in the PR |

## 11. Testing

### 11.1 Live UAT spec

1. Rebuild the dev app, Debug Mode on.
2. In TextEdit type `I can't wait to go to `, leave the caret at the end, dictate `The museum tonight.` → expect `I can't wait to go to the museum tonight.`
3. Same position, dictate `Go home and eat dinner.` → expect lowercase `go`.
4. Same position, dictate `Mark said he would be late.` → expect **capital** `Mark` retained.
5. After a full stop (`I went home. `), dictate `The museum was closed.` → expect the capital retained (`caseKept(.afterTerminator)`).
6. Verdicts from `~/Library/Logs/EnviousWispr/app.log`, not the clipboard.

### 11.2 Other test obligations

The founder supplied a benchmark suite on 2026-07-26. Its **structure is adopted**: a committed dataset with stable IDs, a `category` axis so a failure is diagnosable, per-case notes, and separately reported precision / recall / accuracy. Four things in it are corrected rather than copied, each for a reason:

1. **It must drive production code, not a copy of it.** The proposed harness reimplements the terminal-punctuation check inside the test. `CursorInsertionRepair` already owns that rule (`caseKept(.afterTerminator)`), so a reimplementation would let a real bug in the shipped rule pass green. The suite calls `CursorInsertionRepair.repair` and nothing else (`validation-discipline.md` RULE: measure-with-the-real-tool-never-a-simulation).
2. **The metric direction is inverted for our risk profile.** The proposal sets the tighter bound (>95%) on precision-of-capitalisation, whose false positives are stray capitals — the *mild* error — and the looser bound (>90%) on recall, whose false negatives are lowercased names — the *severe* error. We gate the other way round: **zero-damage is the contract, precision on the LOWERCASE decision is the gate**, and coverage is reported but never gated, because a miss leaves today's behaviour.
3. **Non-English cases are frozen as "we do nothing", not as casing targets.** Casing is `base == "en"` only. The proposal's `DE_02` (German verb → lowercase), `ES_02`/`ES_03` (Spanish months and weekdays → lowercase) and `FR_02` (nationality adjective → lowercase) all expect a lowering we deliberately never perform, so as written they would fail a correct implementation. They are kept with their **real** expected behaviour: `caseSkipped(.languageNotSupported)`, text unchanged. `JA_01` additionally asserts `trailingSpaceSkipped(.unsegmentedScript)`.
4. **The two unanswerable cases are marked as such** (P12), scored as safe-direction misses rather than failures.

### Deterministic CI tests versus system characterisation

**CI does not gate a numeric precision score produced by `NSSpellChecker` or `NLTagger`.** Those vary by OS image, installed dictionaries, NaturalLanguage assets, and per-user learned words; requiring their exact output would build a flaky gate on the required `build-check`. CI never checks either facility's availability today (`.github/workflows/pr-check.yml`), so the assets are not even guaranteed present.

CI instead uses **injected fixed answers** through the existing test seam to gate the code contract, deterministically: guard ordering, every accepted word class, every refusal class, missing-service behaviour, every runtime state, learned-word refusal, Custom Words precedence, the 20-unit context boundary, and the exact repaired text and rule names. Every refusal case asserts the payload's original first grapheme survives and `.lowercasedFirst` is absent.

The **real-system characterisation** runs against the frozen 11,577-pair corpus (P14) on the shipping Mac before release, recording macOS version, selected English identifier, tag-scheme availability, attempted decisions, coverage, damage count and every damaged word. It is advisory: a different machine result never fails CI. The author-written adversarial, realistic and long-context slices are **diagnostics**, not certification — P14 showed they were wrong in both directions.

**The corpus itself is never committed.** It is user dictation. The generator is committed; the pairs stay on the machine, and only aggregate counts reach the repo.

- Suites are Swift Testing (`@Test(arguments:)`, not XCTest — `swift-testing-patterns.md`), driving the **production** `repair` entry point.
- Fail-closed tests cover: no English identifier; the prepared identifier disappearing from `availableLanguages`; `.lexicalClass` unavailable; a decision arriving while the runtime is still `.warming`; and a live timeout. No fixed nonsense-word canary exists.
- Custom Words matrix: protect `Olive`, `PostHog` and `The Who`; assert each keeps its capital and emits `case_skipped:protected_word` **without consulting the oracle at all**.
- Existing spacing, seam de-duplication and terminal-period tests must pass unchanged — they carry no word knowledge and this change must not touch them.

## 11.5 Deviations taken during the build

Four, all narrowing rather than widening, recorded rather than left for a reviewer to find:

1. **`CursorInsertionRepair.legacyOnly(text:reason:)` (package) instead of exposing the oracle to Pipeline.** The deadline's fallback needs "today's payload plus a reason". The planned shape would have required `EnglishWordOracle` and `CaseSkipReason.unavailable` to become visible outside PostProcessing; this keeps both internal and gives Pipeline one narrow entry point (`minimize-visibility`).
2. **`WisprBootstrapper` gains `import EnviousWisprPostProcessing`.** Anticipated in §3b as a consequence of the prewarm trigger, but not spelled out in the file list.
3. **`KernelFinalizationWiringTests` gains an `init()` installing a deterministic oracle.** Six of its cases drive the real production entry point; a test process never calls `prewarm()`, so the runtime is `.warming` and casing correctly refuses. Installing a *fake* rather than calling the real prewarm is deliberate — the live oracle reads machine state, and gating the required check on it would build a flaky test.
4. **`ConsultationSpy` in the oracle tests.** The oracle's closures are `@Sendable`, so a captured `var` cannot record whether it was consulted; the spy is lock-backed.

Everything else matches §10 as written.

## 12. Blast radius & rollback

The behavioural decision still has one consumer, but the implementation touches **three modules**: PostProcessing owns the oracle and its runtime, Pipeline applies the ordered deadline and fallback, AppKit triggers prewarm. An earlier draft said "one function, one module, one caller", which understated it. Rollback is a single revert; there is no migration, no persisted state, and no schema. The deleted resource is recoverable from git history if the decision is ever reversed.

The deleted word list has never been copied into Application Support, UserDefaults, the Keychain, or any other persistent user location — it exists only inside the versioned app and module bundle, so an update replaces it and an already-installed user needs no cleanup. That must be **proved against the rebuilt product, not the source tree**:

```bash
if find "build/EnviousWispr Local.app" \
  \( -name 'ordinary-lowercase-words.txt' -o -name 'ordinary-lowercase-words.provenance.md' \) \
  -print -quit | grep -q .; then
  echo "Deleted lowercase-word resource still ships in the rebuilt app."
  exit 1
fi
```

### German branch integration

"Parked" is not an integration plan, and `feat/1803-german-safe-words` edits the same file. Land this change first, then rebase that branch onto the resulting main. The rebase must keep the English oracle English-only, port the German logic onto the post-deletion repair seam, and must not resurrect `OrdinaryLowercaseLexicon`, its resource, or its test-only exclusion class. Afterwards rerun the spacing, seam de-duplication, terminal-period, unknown-language, English-casing and German-casing suites **together**, resolving overlapping `CaseSkipReason`, `LanguageRules` and `applyLeadingCase` changes as one language-routing contract rather than as a textual conflict.

## 13. Ship criteria

The earlier draft of this section was **internally contradictory** and the coverage round was right to call it: it gated on an adversarial corpus scoring 89.5% against a ≥90% bar (so the gate failed its own corpus), while simultaneously claiming "zero damage is the contract" and allowing two damaged realistic cases. Replaced:

1. The founder's case fixed, verified in Live UAT: `I can't wait to go to ` + `The museum tonight.` ships lowercase.
2. **A blinded human precision review, specified so someone else can execute it.** Round 2 was right that the earlier wording had no sample size, no seed operation, no row IDs, and a biased denominator that mixed every likely-negative row into the precision estimate.
   - Row IDs come from the corrected generator (sorted input, `sha256(basename:offset)[:16]`).
   - From all rows the production oracle would lowercase, sort by ID and take 500 via `random.Random(1803).sample`. **This is the precision denominator.**
   - Every generated-capital row the oracle would lowercase is reviewed **separately** as a mandatory safety audit, and is NOT added to that denominator — folding likely negatives in would measure a safety audit, not precision.
   - Add 500 deterministically sampled oracle-kept decoys and shuffle with seed 1803, so the reviewer is genuinely blind to the oracle's decision.
   - The sheet carries only `case_id`, left context and payload — never the stored casing, the oracle decision, or the corpus label.
   - Reviewer records `LOWERCASE` / `KEEP CAPITAL` / `UNSURE`. **`UNSURE` counts against precision.**
   - Join to the hidden key only after review is locked. Precision = reviewed-correct lowercase decisions / 500, and must be **≥ 90%**.
   - Report the safety audit separately, listing every disagreement. The 11,577-row corpus remains coverage characterisation, never ground-truth precision.
   - **Compatibility-exception safety audit.** Separately review **every** row whose lowering depends on one of the 12 exceptions — 79 rows in the corrected corpus. Outside the 500-row denominator. Report per exception. An exception ships only with at least one reviewed-correct lowering and zero harmful ones; `UNSURE` counts as harmful. Without this, the ablation shows only that the exceptions change agreement with our own output, never that they are right.
3. Recall on the characterisation corpus strictly greater than the shipped list's 70.5%. (Measured: 75.9%.) The author-written slices are diagnostics with no independent pass threshold and cannot override item 2.
3a. **First paste after launch stays under 5 ms**, verified with the startup warm-up in place. Unwarmed it measures 105.6 ms, which is a heart-path regression.
4. Deterministic CI tests cover every acceptance and refusal branch using injected answers, calling no machine-variable service.
5. Zero change to spacing, de-duplication, terminal-period, and non-English behaviour.
6. Xcode Debug + Release build, full suite green with a nonzero executed count.
7. Neither deleted filename ships in the rebuilt app (§12 check).
8. Local `codex review` clean, then cloud review clean.
9. Include in the next What's New entry and public release notes. No onboarding, email or knowledge-base article needed.

Customer-facing copy for that note:

> Smart Insertion now joins follow-up dictations more naturally. Words such as "the", "go", "send" and "call" can continue the sentence with the right capitalisation, while names and entries in Your Words stay protected.

## 14. Open questions

1. **Is the small precision cost acceptable given today's list is near-perfect?** On the corrected characterisation corpus the production design disagrees 14 times versus the list's 11, while attempting 604 more lowerings and gaining 601 agreements. The founder set the bar at 90% and asked for the coverage. Flagged, not blocking — but item 2 of the ship criteria (blinded sample review) is what actually answers it, and this plan should not be signed off on the assumption that the answer is already known.
2. **Should a small name refusal list sit on top?** Measured as unnecessary to clear the bar, and it would reintroduce exactly what the founder rejected. Recommendation: no. Revisit only if real use produces a second `Olive`.

## 15. Related

- #1803 (this issue), #1785 (the list this deletes), PR #1804 (seam de-duplication, merged), PR #1814 (terminal, open)
- Measurement scripts and raw output: `docs/feature-requests/issue-1803-artifacts/`