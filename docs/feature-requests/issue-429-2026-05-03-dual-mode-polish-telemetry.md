# Issue #429 — Dual-mode polish telemetry: surface router mode + filter trips — 2026-05-03

GitHub issue: `#429`. Parent / epic: #318 Telemetry (rolls up). Tier: SMALL→MEDIUM border. Status: DRAFT.

## Preface — Lane + Live UAT declaration

**Lane:** Code (Sources/, Tests/).

**Live UAT:** Y. Success: with AFM polish enabled, dictate one technical-route prompt ("write a python script that prints hi") and one natural-route prompt ("hey just sending a quick note about the meeting"). After each, PostHog event inspector shows `llm.polish_completed` carrying `router_mode` ("technical" / "natural"), `router_basis` ("tier1" / "scored" / "empty"), `filter_tripped` (nil or guard name), and `fell_back_to_raw` (bool). Force a known filter trip (e.g. dictate "write a python script" — should trip imperative_execution_guard) and verify `filter_tripped="imperative_execution_guard"` + `fell_back_to_raw=true`. Force an AFM error (e.g. unsupported language gate) and verify Sentry event carries `polish_mode` tag.

## Preface — User Rubric

User Rubric: N/A — epic #318 Telemetry is internal-only, no user-visible surface.

## 0. TL;DR

We ship dual-mode AFM polish (#381/#427/#434/#436) but the `llm.polish_completed` PostHog event only carries `provider`, `model`, `result`, `latency_seconds`. We can't see in production which router mode (natural/technical) handled a dictation, why the router decided that way, or whether `EnviousOutputFilter` tripped a guard. This makes "is dual-mode actually working in the wild?" un-answerable from current dashboards. Fix: add a 4-field `PolishMetadata` sidecar on `LLMResult`, plumb through `LLMPolishStep` → `TextProcessingContext` → pipeline-built `ExecutionMetrics` → `TelemetryService.llmPolishCompleted` → PostHog properties. Add a `polish_mode` Sentry tag at the AFM error capture site. AFM-only for this PR; cloud providers leave metadata nil. Evidence of success: a single AFM dictation ends with all four properties populated in PostHog and a forced AFM error carries the `polish_mode` Sentry tag.

## Prior context (Gate 0)

Prior session (2026-04-30) deferred #429 with the exact design shape proposed here (LLMResult metadata sidecar → TextProcessingContext → TranscriptFinalizer → TelemetryService). No prior plan file written; only deferral notes in session-log:1092 and session-log:915. Worktree `EnviousWispr-tel` was used at the time but has since been cleaned up. #429 was parented under epic #318 on 2026-05-02. This plan is the first formal proposal.

## 1. Problem

Production polish telemetry today (Sources/EnviousWisprServices/TelemetryService.swift:247-260) emits only:

```
provider, model, result, latency_seconds
```

Dual-mode router (Sources/EnviousWisprLLM/ApplePolishRouter.swift) and EnviousOutputFilter (Sources/EnviousWisprLLM/EnviousOutputFilter.swift) ship rich decision/trip data internally, but it dies at the AppleIntelligenceConnector boundary. Concretely:

- We cannot tell which `RouterMode` handled a dictation (`natural` vs `technical`).
- We cannot tell which `RouterBasis` fired (`empty` / `tier1` / `scored`).
- We cannot tell whether a filter guard tripped (`code_shape_guard` / `structured_output_guard` / `imperative_execution_guard` / `length_guard` / `aggressive_shortening_guard` / `preamble_stripped`) or AFM passed cleanly through.
- We cannot tell whether the pipeline fell back to raw input (`fellBackToRaw`).
- AFM errors do not carry a `polish_mode` Sentry tag, so dual-mode bugs cannot be sliced separately from each other.

Without these, the dashboard says "polish happened, took 1.3s" but not "router picked technical, filter tripped imperative_execution_guard on 0.8% of natural-routed dictations." That latter measurement is exactly what tells us whether dual-mode is working as designed.

## 2. Goals & non-goals

### 2.1 Goals
- `llm.polish_completed` PostHog event carries `router_mode`, `router_basis`, `filter_tripped`, `fell_back_to_raw` for AFM polish. `fell_back_to_raw` is the FINAL pipeline outcome (filter OR validator); `filter_tripped` names which filter guard fired (or nil).
- AFM errors AFTER router decision carry `polish_mode` Sentry tag (via `AFMPolishError` typed wrapper). Pre-router errors (preflight gate) correctly have no tag.
- New properties are nil/absent for non-AFM providers (no schema confusion in PostHog).
- Tests cover propagation through every layer (LLMResult → context → ExecutionMetrics → telemetry hook), validator-only fallback, deterministic filter-trip via fixed input/output pairs, and Codable backward-compat. Not exhaustive matrix — propagation correctness, not combinatorial coverage.

### 2.2 Non-goals
- No new dashboards. Reuse PostHog Pipeline Performance.
- No new Sentry rules or alerts.
- No retroactive backfill.
- Cloud providers (OpenAI, Gemini, Ollama) leave metadata nil — cloud dual-mode is not on the roadmap.
- No persistence to disk Transcript history beyond what `ExecutionMetrics` already serializes (small Codable bloat is acceptable).

## 3. Design

### 3.1 New value type — `PolishMetadata` in Core

```swift
// Sources/EnviousWisprCore/LLMResult.swift
public struct PolishMetadata: Codable, Sendable, Equatable {
  public let routerMode: String?            // "natural" | "technical" | nil
  public let routerBasis: String?           // "empty" | "tier1" | "scored" | nil
  public let filterTripped: String?         // nil | guard name from EnviousOutputFilter
  public let filterFellBackToRaw: Bool      // EnviousOutputFilter outcome only

  public init(routerMode: String? = nil, routerBasis: String? = nil,
              filterTripped: String? = nil, filterFellBackToRaw: Bool = false) {
    self.routerMode = routerMode
    self.routerBasis = routerBasis
    self.filterTripped = filterTripped
    self.filterFellBackToRaw = filterFellBackToRaw
  }
}
```

**Naming note (revision per council + grounded review).** The metadata field is `filterFellBackToRaw` — narrowly the `EnviousOutputFilter` outcome. The PostHog event property `fell_back_to_raw` is the broader, **final pipeline outcome** computed in `LLMPolishStep` as `filterFellBackToRaw || (validatedText == original)`, so the dashboard answers "did the user receive raw text?" rather than only "did the filter trip?". See §3.5.

### 3.1b New typed AFM error — `AFMPolishError`

After the router decision is made, AFM downstream throws lose access to `decision.mode/basis` across the LLMPolishStep boundary. Wrap them in a typed error so `LLMPolishStep` can tag Sentry on catch.

```swift
// Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift (or sibling file)
public struct AFMPolishError: Error, Sendable {
  public let underlying: Error
  public let routerMode: String        // "natural" | "technical"
  public let routerBasis: String       // "empty" | "tier1" | "scored"
}
```

`AppleIntelligenceConnector.polish()` AFTER router decision wraps any throw from `polishWithFoundationModels` and `OutputLanguageValidator.validate` in `AFMPolishError`. Pre-router throws (preflight gate, framework unavailable) propagate untyped — those are correctly absent the polish_mode tag because the router never ran.

### 3.2 Extend `LLMResult`

```swift
public struct LLMResult: Sendable {
  public let polishedText: String
  public let polishMetadata: PolishMetadata?     // NEW, optional, default nil

  public init(polishedText: String, polishMetadata: PolishMetadata? = nil) {
    self.polishedText = polishedText
    self.polishMetadata = polishMetadata
  }
}
```

Backward-compatible: existing call sites (cloud connectors) construct `LLMResult(polishedText:)` and the metadata defaults to nil.

### 3.3 AppleIntelligenceConnector populates metadata + wraps post-router errors

`Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift` `polish()`:

```swift
// (existing) preflight gate, language gate — pre-router; throws propagate untyped.

let decision = ApplePolishRouter.decide(text)
let routerMode = decision.mode.rawValue
let routerBasis = decision.basis.logDescription

do {
  let result = try await polishWithFoundationModels(
    text: text, instructions: instructions,
    detectedLanguage: normalizedBase, mode: decision.mode
  )
  if let expectedBase = normalizedBase, expectedBase != "en" {
    try OutputLanguageValidator.validate(
      polished: result.polishedText, expectedBase: expectedBase
    )
  }
  // result.polishMetadata already carries router + filter facts from polishWithFoundationModels
  return result
} catch {
  throw AFMPolishError(underlying: error, routerMode: routerMode, routerBasis: routerBasis)
}
```

Inside `polishWithFoundationModels` (line ~381 area where `EnviousOutputFilter.filter(input:output:)` runs):
- After `filtered = EnviousOutputFilter.filter(...)`, build `PolishMetadata(routerMode: mode.rawValue, routerBasis: <captured>, filterTripped: filtered.tripped, filterFellBackToRaw: filtered.fellBackToRaw)`.
- Pass into `LLMResult(polishedText:, polishMetadata:)` return.

Note `polishWithFoundationModels` doesn't currently see `RouterBasis` — pass it as a parameter from the caller site.

Sentry tagging happens in `LLMPolishStep` catch block when the thrown error is an `AFMPolishError` (see §3.5b).

### 3.4 Plumb through TextProcessingContext

`Sources/EnviousWisprPipeline/TextProcessingStep.swift`:

```swift
public struct TextProcessingContext: Sendable {
  public var text: String
  public var polishedText: String?
  public let language: String?
  public var llmProvider: String?
  public var llmModel: String?
  public var targetAppName: String?
  public var polishMetadata: PolishMetadata?       // NEW — connector-source-of-truth metadata
  public var pipelineFellBackToRaw: Bool = false   // NEW — final-outcome fallback (filter OR validator)
  // ...
}
```

### 3.5 LLMPolishStep copies metadata onto context + computes pipeline-level fallback

`Sources/EnviousWisprPipeline/LLMPolishStep.swift` (around line 298-302, where context is built post-validation):

```swift
var ctx = context
let validatedText = validatePolishOutput(polished: result.polishedText, original: context.text, mode: plan.mode)
ctx.polishedText = validatedText
ctx.llmProvider = llmProvider.rawValue
ctx.llmModel = llmModel

// Compute final-outcome fallback: filter OR validator
let validatorFellBack = (validatedText == context.text)
let baseMetadata = result.polishMetadata
let pipelineFellBack = (baseMetadata?.filterFellBackToRaw ?? false) || validatorFellBack

if var meta = baseMetadata {
  // Stash pipeline-level outcome alongside filter-level for telemetry
  ctx.polishMetadata = meta
  ctx.pipelineFellBackToRaw = pipelineFellBack
} else {
  ctx.polishMetadata = nil
  ctx.pipelineFellBackToRaw = false
}
return ctx
```

`pipelineFellBackToRaw` lives on `TextProcessingContext` (§3.4 below) as a separate boolean from the metadata sidecar, because it requires post-validate knowledge that the connector cannot produce.

### 3.5b LLMPolishStep catches AFMPolishError to tag Sentry

`LLMPolishStep` catch path (the existing site that captures AFM provider-unavailable; line near 146):

```swift
} catch let afmErr as AFMPolishError {
  SentrySDK.configureScope { scope in
    scope.setTag(value: afmErr.routerMode, key: "polish_mode")
    scope.setTag(value: afmErr.routerBasis, key: "polish_router_basis")
  }
  SentryBreadcrumb.captureError(afmErr.underlying, category: .polishFailure, stage: "polish")
  throw afmErr.underlying  // surface underlying error so existing fallback logic continues
}
```

Pre-router throws (preflight gate) propagate untyped and reach the existing catch — no `polish_mode` tag (correct).

### 3.6 Pipelines fold metadata into ExecutionMetrics

`Sources/EnviousWisprCore/Transcript.swift`:

```swift
public struct ExecutionMetrics: Codable, Sendable {
  // existing...
  public var polishRouterMode: String?
  public var polishRouterBasis: String?
  public var polishFilterTripped: String?
  public var polishFellBackToRaw: Bool?    // FINAL pipeline outcome (filter OR validator); optional so Codable old records still decode
  // ...
}
```

`Sources/EnviousWisprPipeline/TranscriptionPipeline.swift:923` and `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:1041`: when constructing `ExecutionMetrics`, read `context.polishMetadata` (router/filter facts) AND `context.pipelineFellBackToRaw` (final outcome), pass through.

**Persistence note (per Codex grounded review).** Live pipelines mutate `transcript.metrics` AFTER `TranscriptFinalizer.save` (TranscriptFinalizer.swift:115-126 → TranscriptionPipeline.swift:922-932 / WhisperKitPipeline.swift:1040-1050). The mutation does not currently re-save to disk, so live ExecutionMetrics additions stay in-memory for telemetry. Codable backward-compat test still required because the type IS Codable and could be persisted by a future refactor.

### 3.7 TelemetryService surfaces new properties

`Sources/EnviousWisprServices/TelemetryService.swift`:

- In `reportDictationCompleted` (line 60), read the new fields from `t.metrics` and forward to `llmPolishCompleted`.
- Extend `llmPolishCompleted` signature with the four new optional params.
- Add to `props` dict, then capture.

```swift
public func llmPolishCompleted(
  provider: String, model: String?, stylePreset: String?,
  result: String, latencySeconds: Double,
  routerMode: String? = nil,
  routerBasis: String? = nil,
  filterTripped: String? = nil,
  fellBackToRaw: Bool? = nil
) {
  var props: [String: Any] = [
    "provider": provider, "result": result,
    "latency_seconds": String(format: "%.3f", latencySeconds),
    "$value": latencySeconds,
  ]
  if let m = model { props["model"] = m }
  if let s = stylePreset { props["style_preset"] = s }
  if let rm = routerMode { props["router_mode"] = rm }
  if let rb = routerBasis { props["router_basis"] = rb }
  if let ft = filterTripped { props["filter_tripped"] = ft }
  if let fb = fellBackToRaw { props["fell_back_to_raw"] = fb }
  PostHogSDK.shared.capture("llm.polish_completed", properties: props)
}
```

## 3b. Ownership justification

N/A — no coordinator/manager affected. Plan touches existing types in their canonical locations:
- `LLMResult` and `PolishMetadata` belong in `EnviousWisprCore` (where `LLMResult` already lives) — value types, no orchestration.
- `TextProcessingContext` adds a transient field; no new owner.
- `AppleIntelligenceConnector` already owns router + filter calls; adding metadata population there is local.
- `ExecutionMetrics` already owns telemetry-shaped per-event facts; new fields are same shape (optional strings + bool).
- `TelemetryService` already owns the polish-completed event; new params are additive.

No new types created. AppState concrete-collaborator count unchanged. Architecture ceiling: untouched (current 19, projected 19).

## 3c. Active-epic cross-check

N/A — no active-epic owner directly assigned. Issue #429 is parented under #318 (Telemetry, dormant) per session-log. This work directly serves #381 (dual-mode polish, shipped) by giving it the production observability that issue body says was missing.

## 4. Failure modes (MANDATORY)

| Failure | Caller | Expected behavior |
|---|---|---|
| AppleIntelligenceConnector throws BEFORE router runs (preflight gate, framework unavailable) | LLMPolishStep catch | LLMResult never returned; polishMetadata is nil; telemetry emits without new fields. Sentry event has no `polish_mode` tag (correct — router didn't run). |
| Router runs, AFM throws AFTER router | AppleIntelligenceConnector | Throw propagates; Sentry catch in LLMPolishStep adds `polish_mode` tag from a captured `decision.mode.rawValue` (held in a local before the throw). |
| EnviousOutputFilter trips, returns rawInput | AppleIntelligenceConnector | Returns LLMResult with metadata.fellBackToRaw=true and metadata.filterTripped=guard name. Heart continues normally with raw text. |
| validatePolishOutput throws threshold violation, falls back to original | LLMPolishStep | Metadata still attaches to context (router + filter decisions are real even if validator overrode the text). |
| Cloud provider (non-AFM) | LLMPolishStep | result.polishMetadata is nil; new PostHog props absent from event payload (good — schema clean). |
| Old Transcript on disk decoded after this PR ships | Persistence read | New ExecutionMetrics fields are optional; `nil` decodes cleanly. |

## 5. Downstream consumer matrix (MANDATORY)

| Contract delta | Consumer | Code change? | Verified by |
|---|---|---|---|
| `LLMResult.polishMetadata` (new optional) | Cloud connectors (OpenAI/Gemini/Ollama) | No — call sites use default nil | Existing connector tests still compile |
| `LLMResult.polishMetadata` | AppleIntelligenceConnector | Yes — populate at success path | New unit test |
| `TextProcessingContext.polishMetadata` | LLMPolishStep, TranscriptionPipeline, WhisperKitPipeline | Yes — read/write field | Plan §3.5/3.6 |
| `ExecutionMetrics.polishRouter*/polishFilter*` | TranscriptionPipeline, WhisperKitPipeline (write); TelemetryService (read); on-disk persisted Transcripts (decode) | Yes — append fields | Codable backward-compat verified by adding all-nil decode test |
| `TelemetryService.llmPolishCompleted` signature | callsite at TelemetryService.swift:96 (in `reportDictationCompleted`) | Yes — pass the four new params | Test stubs PostHog capture, verifies properties |
| Sentry `polish_mode` tag | AFM error capture in LLMPolishStep | Yes — `withScope { setTag }` | Manual UAT, dev DSN |

Discovery grep: `grep -rn "LLMResult(\|llmPolishCompleted(\|ExecutionMetrics(" Sources/ Tests/` — should match exactly the call sites enumerated above + their tests, no surprises.

## 6. Discovery method (MANDATORY)

```bash
grep -rn "LLMResult(" Sources/ Tests/
# Expect: AppleIntelligenceConnector polish path (modified to pass metadata),
# OpenAI/Gemini/Ollama connectors (unchanged — default nil), plus tests.

grep -rn "polishMetadata\|PolishMetadata" Sources/ Tests/
# Expect: LLMResult struct, AppleIntelligenceConnector population site,
# LLMPolishStep copy site, TextProcessingContext field, the new test.

grep -rn "polish_mode\|router_mode\|router_basis\|filter_tripped" Sources/ Tests/
# Expect: TelemetryService llmPolishCompleted prop names + Sentry setTag + tests.
```

## 7. Tests (MANDATORY — revised per council + grounded review)

Narrow the §2.1 stated coverage goal. New tests:

1. **Full propagation** (the load-bearing one) — fake `LLMPolisher` returning `LLMResult` with populated `PolishMetadata`; run `LLMPolishStep.process(context:)`; assert `context.polishMetadata` and `context.pipelineFellBackToRaw` are set correctly. Then construct an `ExecutionMetrics` from that context (mimicking the pipeline-level call) and feed into `TelemetryService.llmPolishCompleted` via `testEventHook`; assert the PostHog property dict has `router_mode`, `router_basis`, `filter_tripped`, `fell_back_to_raw` with the expected values.
2. **Cloud-provider null path** — fake polisher returning `LLMResult(polishedText:)` without metadata; assert `context.polishMetadata == nil` and `context.pipelineFellBackToRaw == false`.
3. **Validator-only fallback** — fake polisher returning `LLMResult` with `filterFellBackToRaw=false` but text that triggers `validatePolishOutput`'s expansion threshold; assert `context.pipelineFellBackToRaw == true` (validator fired) AND `context.polishMetadata.filterFellBackToRaw == false` (filter did not).
4. **Filter-trip propagation** — feed `EnviousOutputFilter.filter` known imperative input/output pair (use the actual triggers from EnviousOutputFilter.swift:144-168); assert `Result.tripped == "imperative_execution_guard"` and `fellBackToRaw == true`. Then wrap and assert `PolishMetadata.filterTripped == "imperative_execution_guard"`.
5. **Codable backward-compat** — encode an old-shape `ExecutionMetrics` (without polish* fields), decode against the new struct shape; assert decode succeeds and new fields are nil.
6. **TelemetryService property mapping** — install `testEventHook`, call `llmPolishCompleted(...)` with each combination of new params (some nil, some set); assert PostHog `properties` dict has correct keys.
7. **Sentry tag scope** — induce an `AFMPolishError` synthetically; verify (via a Sentry test mode/fake or by capturing scope state if available) that `polish_mode` and `polish_router_basis` tags get set. If Sentry test infra doesn't allow inspection, use a `withScope` wrapper test.

Note: revised goal — this is propagation coverage, not exhaustive matrix coverage. Production telemetry will surface combinations we missed.

Existing tests must still pass (537/537 baseline post-#401).

## 8. Telemetry / observability (MANDATORY)

This work IS telemetry. Validation evidence:

- Locally: install dev PostHog DSN, dictate twice with AFM (one technical, one natural), check `llm.polish_completed` event in PostHog inspector for new properties.
- Existing dashboard: PostHog Pipeline Performance auto-includes new properties as filterable dimensions; no dashboard change required.
- Sentry: trigger AFM unsupported-language error path, verify `polish_mode` tag appears in event detail.

Out of scope: building new dashboards or alerts on the new properties. That's a follow-up issue once we have ~7 days of data.

## 9. Migration / rollout (MANDATORY)

No persistence migration. New `ExecutionMetrics` fields are optional; old on-disk records decode cleanly with nils. PostHog new properties begin appearing on the first AFM dictation post-deploy. No backfill.

## 10. Code reality check (MANDATORY)

| Claim | Verified |
|---|---|
| `TelemetryService.llmPolishCompleted` exists at `TelemetryService.swift:247` | YES — `grep -n "func llmPolishCompleted" Sources/EnviousWisprServices/TelemetryService.swift` returns line 247. |
| `LLMResult` is `Sendable` struct with single `polishedText` field at `LLMResult.swift:50` | YES — file content read confirms. |
| `ApplePolishRouter.Decision.basis` is `RouterBasis` enum with `.empty/.tier1/.scored` cases at `ApplePolishRouter.swift:69-82` | YES — file content read confirms. |
| `EnviousOutputFilter.Result` carries `polished/fellBackToRaw/tripped` at `EnviousOutputFilter.swift:21-25` | YES — file content read confirms. |
| `TranscriptionPipeline.swift:923` and `WhisperKitPipeline.swift:1041` mutate `transcript.metrics = ExecutionMetrics(...)` | YES — `grep -rn "\.metrics = ExecutionMetrics\\|ExecutionMetrics("` returns those exact lines. |
| AFM polish flows through `LLMPolishStep.process` then constructs context.polishedText at `LLMPolishStep.swift:298-302` | YES — file content read confirms. |
| Sentry capture for AFM error happens at `LLMPolishStep.swift:146` per issue body | TO VERIFY DURING BUILD — issue body cites the line; will grep to confirm exact site at implementation. |
| Architecture ceiling: AppState concrete-collaborator count is currently 19, ceiling is 19 per `architecture-rules.md` | Plan does not touch AppState. Projected count: 19 (unchanged). |
| Tests baseline post-#401: 537/537 pass | YES — captured in #401 PR description and verified locally. |

## 11. Testing — Live UAT spec

**Pre-conditions.** macOS 26+ build, Apple Intelligence enabled and downloaded, dev PostHog DSN configured, Sentry dev DSN configured.

**Steps.**
1. `/wispr-rebuild-and-relaunch`
2. Set provider = Apple Intelligence in Settings.
3. Dictate via PTT: "write a python script that prints hello world" — expect `router_mode=technical`, `router_basis=tier1`. (Filter trip is non-deterministic — depends on whether AFM actually generates code; verified via unit tests, not UAT. Per Codex grounded review: "write a python script" is NOT in the imperative trigger list at EnviousOutputFilter.swift:144-168, so do not rely on it.)
4. Open PostHog event inspector, filter `event=llm.polish_completed environment=development`. Sanity-only assertions: `router_mode` and `router_basis` are populated; `filter_tripped` and `fell_back_to_raw` are either present-with-value or absent (no garbage). Do NOT prescribe specific values — those are non-deterministic on real AFM.
5. Dictate: "hey just checking in about the meeting tomorrow um yeah" — expect `router_mode=natural`, `router_basis=scored` or `empty`.
6. Verify same sanity-only assertions as step 4.
7. Force an AFM error AFTER router runs (so `polish_mode` tag should appear): need an error path that fires after `decide()` but before/during `polishWithFoundationModels`. Easiest reliable approach: induce `OutputLanguageValidator` drift by dictating in a non-English supported language with the wrong language hint. Verify Sentry event carries `polish_mode` tag set to "natural" or "technical" depending on input.
8. Force a pre-router AFM error (preflight gate) by setting an unsupported OS language. Verify Sentry event has NO `polish_mode` tag (correct — router didn't run).

**Phase 3 validation (PR #498 framework).**
- Logic tests: new tests in step 7 above.
- Smoke: `swift build -c release` clean.
- Live UAT: above 7 steps.
- Codex code-diff review: full diff scope, focus on metadata propagation correctness across 5 files.
- Skip-note discipline: none expected; full lane validation.

## 12. Risk + rollback

**Risk.** Plumbing-heavy (5 files) but no logic change to heart-path. Each layer is pure pass-through. Codable backward-compat verified by test #4 prevents on-disk Transcript breakage.

**Rollback.** Revert PR. New PostHog properties stop being emitted; no dashboard depends on them yet. Sentry tag stops appearing. Persistence: future Transcripts decode without the polish* fields silently (they were optional from day one).

## 13. Estimate

~50-70 LOC across 5 files:

| File | LOC delta | Lines |
|---|---:|---|
| Sources/EnviousWisprCore/LLMResult.swift | +18 | new PolishMetadata struct + LLMResult init extension |
| Sources/EnviousWisprCore/Transcript.swift | +8 | 4 new ExecutionMetrics optional fields + init params |
| Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift | +15 | metadata population + Sentry tag in catch |
| Sources/EnviousWisprPipeline/TextProcessingStep.swift | +2 | polishMetadata field |
| Sources/EnviousWisprPipeline/LLMPolishStep.swift | +1 | metadata copy |
| Sources/EnviousWisprPipeline/{Transcription,WhisperKit}Pipeline.swift | +8 | fold into ExecutionMetrics ctor at the two call sites |
| Sources/EnviousWisprServices/TelemetryService.swift | +14 | new params on llmPolishCompleted + reportDictationCompleted forwarding |
| Tests/ | +60 | five new tests per §7 |

Total: ~125 lines added, ~0 lines removed.

## 14. Risks council should pressure-test

1. Should `polishMetadata` carry into persistence (current design) or be transient? Current: `ExecutionMetrics` is already persisted, so adding fields keeps data flow simple but bloats Transcript history JSON by ~50 bytes per record.
2. Is `AppleIntelligenceConnector` the right population site, or should `LLMPolishStep` build the `PolishMetadata` from observation (e.g. via callbacks)? Current: connector is closer to source-of-truth (router + filter both run there).
3. Should the Sentry tag include `router_basis` or only `polish_mode`? Current: only `polish_mode` per issue body. Adding `router_basis` later is additive.
4. What about `TranscriptPolishService` (the standalone re-polish path)? Current: it goes through `LLMPolishStep` too, so metadata flows the same way; no separate plumbing needed. Verify during implementation.
