# Issue #388 — TextProcessingRunner: identify polish step by type, not literal string — 2026-04-20

GitHub issue: `#388`. Parent / epic: #385 (origin) and #319 Phase G (bible §17A). Tier: SMALL (REFACTOR aggregate under Phase G). Status: DRAFT.

User Rubric: N/A — #319 Hardening and Refactors is internal-only, no user-visible surface.

---

## 0. TL;DR

`TextProcessingRunner.swift:99` decides whether to surface a step's error as `polishError` by matching the literal string `"LLM Polish"`. Renaming the step silently changes user-visible error behavior with no compile or test signal. Replace the string match with a per-step `errorSurfacePolicy: ErrorSurfacePolicy` protocol property. SMALL: ~20 LOC net, one production file + test.

## 1. Problem

`TextProcessingRunner.run(...)` runs `[any TextProcessingStep]` in order and decides per-step whether a thrown error becomes user-visible `polishError` or is silently swallowed (limb fallback).

At `Sources/EnviousWisprPipeline/TextProcessingRunner.swift:99`:

```swift
if stepName == "LLM Polish" && !isLanguageGateSkip {
  polishError = error.localizedDescription
}
```

Failure mode: if `LLMPolishStep.name` ever changes (rename, localization, typo) the branch becomes dead code. No compile error, no test failure, no Sentry breadcrumb — the "AI polish failed" banner silently stops firing.

Found by Codex during 2026-04-19 audit (`docs/audits/2026-04-19-postasr-test-rewrite.txt`).

## 2. Goals & non-goals

### 2.1 Goals

- Eliminate string-literal dispatch on step identity for the error-surface decision.
- Preserve exact current behavior: only `LLMPolishStep` errors (excluding language-gate skips) set `polishError`.
- Add a test that fails if the dispatch regresses.

### 2.2 Non-goals

- Renaming `LLMPolishStep`.
- Changing any other protocol member (`name`, `maxDuration`, `isEnabled`, `process(_:)`).
- Changing how `polishError` propagates out of the runner.

## 3. Design

Add to the file declaring `TextProcessingStep` protocol (grep to locate; do not assume path):

```swift
internal enum ErrorSurfacePolicy {
  case surface  // error propagates to user as `polishError`
  case swallow  // step failure is a limb: log and continue
}

// TextProcessingStep protocol stays as-is; we ADD one requirement, not change inheritance.
internal protocol TextProcessingStep {
  // ... existing members unchanged (name, maxDuration, isEnabled, process) ...
  var errorSurfacePolicy: ErrorSurfacePolicy { get }
}

extension TextProcessingStep {
  var errorSurfacePolicy: ErrorSurfacePolicy { .swallow }
}
```

**Visibility note (council-revised 2026-04-20):** Internal, not public. Both protocol and `LLMPolishStep` live in `EnviousWisprPipeline`. Do NOT add `Sendable` to the protocol — council flagged that Sendable propagation to existing conformers is a silent scope expansion; the enum value is inert and does not require protocol-level Sendable upgrade.

`LLMPolishStep` overrides with `.surface`. `WordCorrectionStep` and `FillerRemovalStep` inherit the default, matching today's behavior.

At `TextProcessingRunner.swift:99`:

```swift
// BEFORE
if stepName == "LLM Polish" && !isLanguageGateSkip {
  polishError = error.localizedDescription
}

// AFTER
if step.errorSurfacePolicy == .surface && !isLanguageGateSkip {
  polishError = error.localizedDescription
}
```

Language-gate skip logic unchanged.

## 4. MANDATORY Contract deltas

- **Added `ErrorSurfacePolicy` enum + `errorSurfacePolicy` protocol requirement.**
  - Semantics: Policy, not event. Declares how the runner treats a thrown error from `process(_:)`. `.surface` = limb failure the user should see. `.swallow` = limb failure the heart absorbs.
  - Invariant: every conforming type either accepts the default `.swallow` or overrides explicitly. Runner MUST read the property (not `step.name`) when deciding `polishError`.

No persisted fields. Enum is in-memory only. No Codable impact. No legacy data.

## 5. MANDATORY E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new item | `TextProcessingRunner.run(...)` per dictation. Success path unchanged. Error path reads `errorSurfacePolicy` instead of `stepName`. Identical outcome for all three current steps. |
| Saved / reloaded item | N/A — runner does not persist step results. |
| Retry or re-run | Re-polish path (`TranscriptPolishService`) invokes the same runner. Identical outcome. |
| Background / async completion arriving after state changed | N/A — runner is a synchronous MainActor `for` loop over steps with per-step timeout. No out-of-order completion. |
| User manual override / edit | N/A — user cannot override policy; code-defined per step. |

**Upstream sources.** `grep -rn "TextProcessingRunner" Sources/ Tests/`.

**UI side effects.** `polishError` propagates via `TextProcessingRunResult` → consumer in the pipeline finalizer → `appState.lastPolishError` → "AI polish failed" banner. No new UI surface.

**Persistence.** None.

**App-kill scenario.** N/A — runner is transient per dictation.

**Concurrency guard.** MainActor-isolated, unchanged.

## 6. MANDATORY Downstream consumer matrix

| Contract delta | Consumer | Current | Required | Change? | Verified by |
|---|---|---|---|---|---|
| `errorSurfacePolicy` default `.swallow` | `WordCorrectionStep` | conforms | inherits default | No | compile + new test |
| (same) | `FillerRemovalStep` | conforms | inherits default | No | compile + new test |
| (same) | `LLMPolishStep` | conforms | overrides to `.surface` | **Yes** | new test |
| runner error branch | `TextProcessingRunner` | string compare on `stepName` | enum compare on policy | **Yes** | new test |
| future conformances | outside this PR | none known | inherit `.swallow` | No | protocol extension |

Discovery method:
```
grep -rn "TextProcessingStep\|TextProcessingRunner\|LLMPolishStep\|WordCorrectionStep\|FillerRemovalStep" Sources/ Tests/
```

## 7. MANDATORY Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Persisted | Metadata | Retry |
|---|---|---|---|---|---|---|
| `LLMPolishStep.process(_:)` throws non-language-gate | LLM provider or timeout | runner | "AI polish failed" banner (unchanged) | no polish metadata | none added | user retries with other provider |
| `WordCorrectionStep` or `FillerRemovalStep` throws | internal logic | runner | silent (unchanged) | unchanged | none | next dictation |
| Language-gate skip | `LLMPolishStep` | runner | silent (unchanged) | unchanged | none | N/A — skip is expected |

All three rows preserved exactly. No new failure mode.

## 8. MANDATORY Caller-visible signals audit

- `TextProcessingStep.errorSurfacePolicy` — read only by the runner; no UI or persistence keys off it.
- `TextProcessingRunResult.polishError` — unchanged. Existing implicit signal (`polishError != nil` → banner) preserved.

Grep to confirm no external dispatch on step identity remains:
```
grep -rn "stepName\b\|step\.name\b\|\"LLM Polish\"\|\"Word Correction\"\|\"Filler Removal\"" Sources/ Tests/
```

`step.name` remains for debug logging; no behavioral dispatch keys off it after this change.

## 9. MANDATORY Fallback source-of-truth audit

No new fallback branch. Existing fallback (limb failure → continue with prior `context`) unchanged. Source-of-truth for continuation: `context` as it stood at the start of the failing step's iteration. `catch` block does not reassign `context`, so the next step sees the prior step's output. Documented in the file as "Heart & Limbs: limb failed, continue with input text."

## 10. File-by-file changes

- **`Sources/EnviousWisprPipeline/TextProcessingRunner.swift`**: line 99 condition swap.
- **`Sources/EnviousWisprPipeline/TextProcessingStep.swift`** (grep-verified at line 29): add `ErrorSurfacePolicy` enum + protocol requirement + default extension.
- **`Sources/EnviousWisprPipeline/LLMPolishStep.swift`** (grep-verified at line 8; same module as the runner, NOT `EnviousWisprLLM` as v1 plan said): add `public let errorSurfacePolicy: ErrorSurfacePolicy = .surface`.
- **New or extended test** (e.g. `Tests/EnviousWisprPipelineTests/TextProcessingRunnerErrorSurfaceTests.swift`): four tests per §11.

## 11. Testing

Unit tests (new):
- `errorSurfacePolicyEqualsSurface_setsPolishError` — fake `.surface` step throws generic error → `result.polishError != nil`.
- `errorSurfacePolicyEqualsSwallow_doesNotSetPolishError` — fake `.swallow` step throws generic error → `result.polishError == nil`.
- `llmPolishStep_declaresSurfacePolicy` — runtime assert `LLMPolishStep().errorSurfacePolicy == .surface`.
- `languageGateSkip_stillSwallowsDespiteSurfacePolicy` — `.surface` step throws `LLMError.unsupportedInputLanguage` → `polishError == nil`.

UAT: none — no observable behavior change.

Benchmarks: none — enum compare equivalent to string compare.

## 12. Blast radius & rollback

Touched: `EnviousWisprPipeline` (runner + protocol), `EnviousWisprLLM` (one conformance). Untouched: AppState, pipelines, UI, persistence, telemetry. Rollback: `gh pr revert <N>` or `git revert <sha>`. Clean.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes
- [ ] `swift build -c release` exit 0
- [ ] Writer-Codex truth-audit pass (`.codex/truth-audit-test-template.md`)
- [ ] Adversarial-Codex review pass in fresh session (`.codex/adversarial-test-review-template.md`)
- [ ] Grep verifies no `stepName ==` or `step.name ==` dispatch remains elsewhere
- [ ] Zero em-dashes / en-dashes in new code and docs
- [ ] `polish-eval-smoke` green
- [ ] `scripts/heart-path-check.sh` green
- [ ] Architecture DoD: `ErrorSurfacePolicy` visibility narrowed as far as conformances allow

## 14. Open questions

- **RESOLVED 2026-04-20:** `ErrorSurfacePolicy` visibility: grep-verified both `TextProcessingStep` protocol and `LLMPolishStep` live in `Sources/EnviousWisprPipeline/`. Same module — `internal` is sufficient. `public` would be warranted only if a cross-module conformer needs to override; none exists today.
- Third case `.log` (swallow but explicit warn log)? Not today; defer as YAGNI.
- **Council-flagged precondition (both providers, 2026-04-20):** Adding `Sendable` to `TextProcessingStep` propagates to every conformer. Grep-verify before implementation: `WordCorrectionStep`, `FillerRemovalStep`, `LLMPolishStep`. If any already fails a stricter `Sendable` check (mutable non-isolated state, captured references), the scope widens. Preferred: do NOT add `Sendable` requirement unless needed — the `errorSurfacePolicy` enum value alone is inert and does not require protocol Sendable upgrade. Revised protocol shape: keep protocol as-is today and add ONLY the `errorSurfacePolicy` property + default extension. Existing protocol inheritance untouched.
- **Design alternative rejected (Gemini 2026-04-20):** `is LLMPolishStep` type check. Rejected because it would couple `EnviousWisprPipeline` (runner) to `EnviousWisprLLM` (LLMPolishStep) via type identity — architecturally worse than a policy enum even if the enum has only one non-default case today. Enum is the right shape for this codebase's module layout.

## 15. Related

- Origin epic: #385 (2026-04-19 Codex CI audit)
- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §17A Phase G (G1)
- Siblings: #389 (G2), #394 (G3), #396 (G4), #398 (G5)
- Audit: `docs/audits/2026-04-19-postasr-test-rewrite.txt`
