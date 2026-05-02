# The Hardening & Refactors Bible — Epic #319 — 2026-04-18

**Status:** DRAFT · **Tier:** REFACTOR (aggregate) · **Parent:** none (standing epic) · **Ultraplan:** YES
**Supersedes:** in-session framework comment on #319 (2026-04-18). This file is the canonical, long-lived handbook for the epic.

---

## 0. Reader and map

### 0.1 Reader

This document is written for Claude Code. Saurabh reads plain-English summaries in chat; he does not read 2000-line plan files. There is no human engineer on this project; Claude Code is the engineer. External contributors do not exist.

Implication: skip human-oriented optimizations (reading-time estimates, prose flourishes, motivational framing). Optimize for accurate fact retrieval and unambiguous execution instructions.

### 0.2 What this is

Epic Hardening & Refactors (#319) — EnviousWispr's Q2 structural hardening pass. This document is the single source of truth for every phase inside it. Every GitHub sub-issue (#196, #195, #290, #291, #360, #361, #362, #363, #364, #365, #366) is a phase of this plan. When an issue body and this doc disagree, this doc wins; update the issue body to cite the relevant section.

### 0.3 Load map — what to read for what task

Per-task minimum load (read only these sections; skip the rest unless the phase blocks):

| Task | Required sections |
|---|---|
| Execute Phase A (#196) | §2, §3.1, §4.1, §4.9, §5, §7, §24 rows #12/#16 touching A |
| Execute Phase B (#195) | §2, §3 where relevant, §4.4, §5, §8, §27.1 + §27.7 (UX decision record — STOP until decision made) |
| Execute Phase C | §2, §3.1 + §3.5, §4.1, §4.2, §4.3, §4.9, §5, §9, §27.2 (persistence boundary decision), §24 rows #12/#18/#19 |
| Execute Phase D | §2, §3.1, §4.1, §4.8 (CustomWordsCoordinator), §4.11, §5, §10, §27.3 (event model decision — STOP until decision made), §24 rows #12/#18 |
| Execute Phase E | §3 (audit meta-rec #1), §4.9 + §4.13, §11, §24 rows #15/#20, §25.3 |
| Execute Phase F (NEW v1.3) | §2, §4.1, §4.13 disposition matrix, §5, §17, §24 rows #12/#18 |
| Execute Phase G sub-phase G1 (#388) | §2, §4.6, §17A, `docs/feature-requests/issue-388-*` |
| Execute Phase G sub-phase G2 (#389) | §2, §4.6, §17A, `docs/feature-requests/issue-389-*` |
| Execute Phase G sub-phase G3 (#394) | §2, §2.3 (intentional duplication), §17A, `docs/feature-requests/issue-394-*` |
| Execute Phase G sub-phase G4 (#396) | §2.4 (access control), §17A, `docs/feature-requests/issue-396-*` |
| Execute Phase G sub-phase G5 (#398) | §2.1 (heart), §4.5, §17A, `docs/feature-requests/issue-398-*` |
| Execute R2 (#360) | §2.4, §3.2, §4.5, §5, §12, §27.4 (approach A vs B — STOP until decision made), §24 |
| Execute R3 (#361) | §3.3, §4.6, §5, §13, §22.1, §20 (V3 verifies the fix) |
| Execute R4 (#362) | §3.6, §4.7, §5, §15 |
| Execute R5 (#290) | §2, §3.7 strengths, §4.1 telemetry callouts, §5, §14 (references standalone plan file issue-290-*) |
| Execute R6 (#363) | §3.4, §5, §16, §21 (V4 prerequisite results — STOP unless V4 confirms failure) |
| Run V1 (#364) | §3.10 item 1 + 3, §18, §22.3 audit rerun protocol |
| Run V2 (#291) | §3.9 Red Team top gap, §19 |
| Run V3 (#365) | §3.10 item 4, §20 |
| Run V4 (#366) | §3.4 Low-confidence rationale, §21 |
| Close the epic | §22, §25 (all 5 subsections), §26.1 protocol, §30 Changelog |
| Resume after a gap | §30 Changelog bottom to top + §6.1 phase table |

If a phase says "read file X" as a substep, that overrides this map.

### 0.4 Gate 0 discipline — always read before acting

Before starting ANY phase work, run the bible's own Gate 0:

1. Read the phase's section (from §0.3 map above).
2. For every `file:line` citation and code snippet in that section, verify it against current code (grep + Read). Line numbers drift; snippets drift.
3. If a citation is stale, substep 0 of the phase is: refresh the citations inline in the bible, commit, THEN start the code work. See §26.2 for protocol.
4. Run `gh issue view <phase-issue-N> --comments` and grep `.claude/knowledge/session-log.md` for `#<N>` per `validation-discipline.md §3`.

Hooks enforce some of this (`check-issue-prior-context.sh`, `gate-gh-issue-view.sh`). The bible adds the snippet-verification step on top.

### 0.5 Rule of this document

One plan file. One epic. All phases live here. Per-phase plans previously kept as standalone files (#196, #195, #290) are referenced and kept for council audit trail, but their canonical content now lives in §7 / §8 / §14. If a phase grows past ~400 lines of bible section, extract to a standalone file per §26.3.

### 0.6 Rule inheritance

Every phase inherits `.claude/rules/workflow-process.md`, `validation-discipline.md`, `architecture-rules.md`, `swift-patterns.md`, `session-behavior.md`, `tools-and-apps.md`. This document cites the sections that govern each phase, does not restate them. Workflow gates (Gate 0 prior-context, Gate 0.5 user rubric, Gate 1 intent, council, Gate 2 sign-off, codex) apply per phase unless the enumerated zero-blast-radius exception in `workflow-process.md §1` fires.

### 0.7 User Rubric scope

Hardening & Refactors is internal; no user-visible surface. User Rubric is N/A for every phase except Phase B (§8), which introduces the visible "applies on next recording" behavior shift and MUST answer the rubric locally before ship.

---

## 1. Executive context

### 1.1 What drove this epic

The 2026-04-18 senior audit (Codex CLI, `gpt-5-class` model, `reasoning_effort="high"`, structured JSON output via JSON Schema; full artifact at `docs/audits/2026-04-18-senior-audit.json`, full mechanics at `.claude/knowledge/codex-audit.md`). The audit answered one question: **is this production-grade senior engineering, or AI slop?** Verdict: **grade C, Medium confidence, "not AI slop"**, with six concrete refactor targets and a Red Team self-critique flagging a runtime validation gap the static audit could not close.

### 1.2 What grade C means

Operationally, per the anchored scoring rubric established in round-1 council review:

- **A** Exemplary, template-quality, would pass review at a top-tier Swift product org.
- **B** Production-ready. Solid work; minor non-blocking suggestions only.
- **C** Shippable with follow-up. Works, but tracked tech debt that must be addressed.
- **D** Conditional. Significant flaws. Do not merge without addressing.
- **F** Blocked. Fundamentally unsafe or broken. Rewrite or redesign required.

Grade C is acceptable for a shipping product; it is not acceptable as a ceiling. This epic moves the grade upward by resolving the enumerated debts, and closes with a re-run of the same audit under the same conditions so the delta is measurable (per `.claude/knowledge/codex-audit.md` `RULE: diff-across-runs`).

### 1.3 What "done" looks like

Epic close requires all ship criteria in §25 to hold, including a re-run audit showing movement on Architecture integrity, Code Hygiene & Maintainability, and API surface (the three letter-graded dimensions that carried findings), and confirmation or downgrade of the three Static Risk dimensions (Performance, Resource lifecycle, Security & privacy) via Track 2 runtime validation.

### 1.4 What the audit found, in brief

Per-dimension grades and worst violations are reproduced in full in §3. Summary:

| Dimension | Grade | Worst violation |
|---|---|---|
| Architecture integrity | B | `AppState.swift:316-321` — 5-way custom-words fanout |
| Concurrency discipline | B | None found (best example: `PreRollForwarder` RT lock discipline) |
| Error handling & observability | **A** | None found (best example: Sentry breadcrumb redaction) |
| Testability | B | `AppState.swift:18-23` — 11 direct concrete-type property declarations |
| Code Hygiene & Maintainability | C | Same `AppState.swift:316-321` fanout |
| API surface | C | `WhisperKitBackend.swift:155-158` — confessed-temporary public widening |
| Performance & latency (Static Risk) | Medium Risk | `AppState.swift:394-398` — transcript reload on every `.complete` |
| Resource lifecycle (Static Risk) | Medium Risk | `AudioCaptureManager.swift:525-530` — unbounded `bt-route.log` append |
| Security & privacy (Static Risk) | Medium Risk | `TextProcessingRunner.swift:32-36` — raw transcript in always-on log |

`AppState` (965 lines) carries the worst violation in three letter-graded dimensions; decomposing it is the structural centerpiece of the epic. Every other finding is smaller and local.

### 1.5 Why the founder opened this

Saurabh's phrasing: *"limbs have grown pretty large, act as their own little mini hearts with their own mini limbs."* The audit independently confirmed the instinct. The epic turns instinct into plan.

---

## 2. Philosophy — the laws this epic protects

These laws come from `.claude/rules/architecture-rules.md`. Repeating the short form here for navigation; the rule file is canonical.

### 2.1 Heart and Limbs

**Heart:** `trigger → audio capture (including pre-roll drain when engine is warm) → ASR → text finalization → clipboard/paste`. Must always complete.

**Limbs:** custom words, filler removal, LLM polish, any post-processing not required for raw transcription. May improve output. MUST NOT block output. Fail-open with timeout + fallback to raw text.

**Every refactor in this epic preserves heart completion.** No phase's rollback may leave the heart broken. Each phase has its own Rollback subsection that restates this (e.g., §7.5 for Phase A, §9.5 for Phase C, §10.5 for Phase D).

### 2.2 Anti-god-object

A type is at risk if it:
- knows too many unrelated domains
- is imported almost everywhere
- becomes the default location for new logic
- owns state AND orchestration AND business rules
- grows mainly because it is convenient
- is hard to describe in one sentence

`AppState` hits all six. This epic resolves it.

### 2.3 Intentional duplication

`TranscriptionPipeline` and `WhisperKitPipeline` stay separate. This is a deliberate stability decision; the rule file explicitly forbids collapsing them. Phase D (custom-words propagator) honors this by broadcasting to both, not unifying them.

### 2.4 Access control — narrow by default

`public` is expensive. Any widening must be justified. `WhisperKitBackend.makeDecodeOptions` (the R2 finding) is a TODO-confessed violation. R2 narrows it.

### 2.5 State ownership

State lives near the domain that owns it — not centralized because many layers read it. Phase C moves transcript history ownership to `TranscriptCoordinator` where it belongs, not `AppState`.

### 2.6 Module dependency direction

```
App / Views / top-level coordination
        ↓
Pipeline / feature orchestration
        ↓
Features / LLM / ASR / Audio
        ↓
Core (shared models, constants, value types, narrow protocols)
```

Historical script `scripts/check-dependency-direction.sh` existed under the now-deprecated brain system; verified removed as of 2026-04-18. `.git/hooks/pre-commit` is a no-op stub (`exit 0`) carrying the deletion's historical comment. No CI workflow or Claude-level hook enforces dep direction today.

Until Phase E (§11) re-introduces automated enforcement, dep direction is enforced by: (a) manual review on architecture-touching PRs, and (b) Swift Package Manager's implicit module-graph errors (cyclic imports fail to compile). Every new type in this epic's phase plans justifies its module placement.

---

## 3. The 2026-04-18 Senior Audit — reproduced for fresh sessions

Full artifact at `docs/audits/2026-04-18-senior-audit.json`. This section reproduces the six refactor findings with complete evidence contracts so a fresh session can work without re-reading the JSON. The evidence contract was round-2 council-hardened (quoted snippet + severity + confidence + counterfactual + rationale + falsifiability + interleaving-if-concurrency).

### 3.1 REF-01 — Decompose AppState into focused coordinators

- **Title:** Decompose AppState into focused coordinators and remove manual cross-domain fanout
- **Dimension:** Architecture integrity
- **Tier:** REFACTOR · **Severity:** HIGH · **Confidence:** High · **Est. LOC delta:** 450
- **Rule violated:** `.claude/rules/architecture-rules.md §Anti-God-Object / Hard rule; §Architecture Definition of Done / Anti-god-object`
- **Worst-violation location (architecture + code hygiene):** `Sources/EnviousWispr/App/AppState.swift:316-321`
- **Snippet (verbatim):**

  ```swift
  customWordsCoordinator.onWordsChanged = { [weak self] words in
    guard let self else { return }
    self.pipeline.wordCorrection.customWords = words
    self.pipeline.llmPolish.customWords = words
    self.whisperKitPipeline.wordCorrection.customWords = words
    self.whisperKitPipeline.llmPolish.customWords = words
  ```

  (Closure continues through `polishService.llmPolishStep.customWords = words`. Five consumers total.)

- **Testability worst violation (same root cause):** `AppState.swift:18-23`, 11 direct concrete-type property declarations (`PermissionsService`, `TranscriptStore`, `KeychainManager`, `HotkeyService`, `BenchmarkSuite`, `RecordingOverlayPanel`, `OllamaSetupService`, `WhisperKitSetupService`, `AudioDeviceList`, `CaptureTelemetryState`, plus the interface-typed `audioCapture` and `asrManager`).
- **Counterfactual:** Extract custom-word propagation into one pipeline-owned configuration object or broadcaster. Give `AppState` one high-level write instead of four direct mutations. Keep per-backend wiring inside the pipeline layer where the backend differences already live.
- **Counterfactual rationale:** Matches the thin-coordinator pattern already used in `Sources/EnviousWisprAudio/AudioCaptureManager.swift:L6-L15`.
- **Falsifiability:** Add one more custom-word-aware post-processing step, update only the Parakeet branch, then record once with Parakeet and once with WhisperKit. Divergent word-correction behavior exposes the architectural split-brain immediately.
- **Audit `depends_on`:** none upstream; REF-05 depends on REF-01.
- **Phase(s) addressing:** A (#196, already drafted), B (#195, already drafted), C (new §9), D (new §10), E (new §11).

### 3.2 REF-02 — Hide WhisperKit internals behind a narrow adapter

- **Title:** Hide WhisperKit internals behind a narrow adapter and remove convenience public API
- **Dimension:** API surface
- **Tier:** MEDIUM · **Severity:** HIGH · **Confidence:** High · **Est. LOC delta:** 120
- **Rule violated:** `.claude/rules/architecture-rules.md §Access Control; §Architecture Definition of Done / API surface`
- **Worst-violation location:** `Sources/EnviousWisprASR/WhisperKitBackend.swift:155-158`
- **Snippet (verbatim):**

  ```swift
  // public: called by WhisperKitPipeline in EnviousWisprPipeline (cross-module boundary).
  // TODO: Phase 2 — narrow to package once Pipeline moves into the same SPM package.
  public func makeDecodeOptions(from options: TranscriptionOptions, sampleCount: Int)
    -> DecodingOptions
  ```

- **Actual cross-module reach (grep confirmed):** `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:1150`, `1154`, `1155`.
  - Line 1150: `await backend.makeDecodeOptions(from: transcriptionOptions, sampleCount: 0)`
  - Line 1154: `await backend.whisperKitTokenizer`
  - Line 1155: `WhisperKitIncrementalWorker(whisperKit: kit, decodingOptions: opts, tokenizer: tokenizer)`
- **Note (new, not in audit):** `WhisperKitIncrementalWorker` already lives in `Sources/EnviousWisprASR/WhisperKitIncrementalWorker.swift` as a `public actor`. The leak is three `public` items on `WhisperKitBackend` + the worker's public constructor, all consumed at the same call site in `WhisperKitPipeline`.
- **Counterfactual:** Move the tail-decode helper behind an internal adapter in the same package as the pipeline, or relocate the incremental worker into the ASR module. Remove public access to backend internals and expose only the operation the pipeline actually needs.
- **Counterfactual rationale:** Restores the narrow-boundary style already present in `Sources/EnviousWisprASR/ASRManagerInterface.swift:L4-L9`.
- **Falsifiability:** Make `makeDecodeOptions` internal and rebuild `EnviousWisprPipeline`. The compile break pinpoints every place where cross-module convenience exposure hardened into dependency.
- **Phase addressing:** R2 (#360, new §12).

### 3.3 REF-03 — Remove raw transcript from always-on logs

- **Title:** Remove raw transcript content from the always-on logging path
- **Dimension:** Security & privacy (Static Risk Assessment)
- **Tier:** SMALL · **Severity:** HIGH · **Confidence:** Medium · **Est. LOC delta:** 40
- **Rule violated:** No-PII policy (`.claude/knowledge/accounts-licensing.md §Analytics Privacy / Events Never Collected`)
- **Worst-violation location:** `Sources/EnviousWisprPipeline/TextProcessingRunner.swift:32-36`
- **Snippet (verbatim):**

  ```swift
  Task {
    await AppLogger.shared.log(
      "CORRECTION_DEBUG [RAW ASR] \(rawText)",
      level: .info, category: "CorrectionDebug"
    )
  ```

- **Confidence caveat from audit:** "The code logs raw transcript text, and `AppLogger` documents that OSLog entries are always emitted and visible in Console.app. Static review does not prove release-log collection policy or OSLog presentation details on every macOS build." (Hence Medium.)
- **Counterfactual:** Strip transcript bodies from always-on logs and replace them with lengths, hashes, and step names. Gate full text behind an explicit local debug-only sink with a hard-off default. Put redaction in `AppLogger` so call sites cannot bypass it by accident.
- **Counterfactual rationale:** Follows the redact-before-export pattern already used in `Sources/EnviousWisprServices/ObservabilityBootstrap.swift:L101-L106`.
- **Falsifiability:** Dictate a unique secret-like string, run a build with correction logging enabled, then inspect Console.app or `log stream` for subsystem `com.enviouswispr.app`. If the dictated text appears verbatim, the privacy boundary is broken.
- **Phase addressing:** R3 (#361, new §13).

### 3.4 REF-04 — Harden prompt delimiter escaping (LOW confidence, gated)

- **Title:** Harden prompt transcript delimiter escaping and add adversarial corpus coverage
- **Dimension:** Security & privacy (Static Risk Assessment)
- **Tier:** SMALL · **Severity:** MEDIUM · **Confidence:** **Low** · **Est. LOC delta:** 60
- **Rule violated:** `.claude/rules/validation-discipline.md §10 Rule B — new polish features extend the corpus in the same PR`
- **Worst-violation location:** (not a single worst-violation; this is a suspected gap based on code comment about case/whitespace insensitivity in the sanitizer)
- **Counterfactual:** Normalize and escape case and whitespace variants of transcript delimiters in one shared sanitizer. Add adversarial unit and corpus cases for mixed-case tags, whitespace-split tags, and newline-split delimiters across all supported builders.
- **Falsifiability:** Run a corpus of adversarial transcripts containing mixed-case `<TRANSCRIPT>`, whitespace-split `< transcript >`, and newline-split delimiters through each provider (OpenAI, Gemini, Ollama, Apple Intelligence); record instruction-boundary failures explicitly.
- **Red Team verdict:** This is the audit's **least-confident finding**. The fix work is **gated on V4 (§21) runtime adversarial eval**. If V4 clears all providers, close #363 as "no defect found." Only proceed with R6 code work if V4 confirms a real failure.
- **Phase addressing:** R6 (#363, new §16), gated on V4 (#366, new §21).

### 3.5 REF-05 — Stop reloading transcript history after every dictation

- **Title:** Stop reloading full transcript history after every completed dictation
- **Dimension:** Performance & latency (Static Risk Assessment)
- **Tier:** MEDIUM · **Severity:** MEDIUM · **Confidence:** High · **Est. LOC delta:** 140
- **Rule violated:** `.claude/rules/architecture-rules.md §Architecture Definition of Done / Placement and ownership`
- **Worst-violation location:** `Sources/EnviousWispr/App/AppState.swift:394-398`
- **Snippet (verbatim):**

  ```swift
  if newState == .complete {
    self.transcriptCoordinator.load()
    if let t = self.pipeline.currentTranscript {
      TelemetryService.shared.reportDictationCompleted(
        transcript: t, inputMode: self.settings.recordingMode.rawValue)
  ```

- **Context:** `TranscriptCoordinator.load()` (at `Sources/EnviousWispr/App/TranscriptCoordinator.swift:29-41`) calls `store.loadAll()` which scans the whole transcript directory and decodes every JSON file on a background task. O(n) on archive size, fires once per completed dictation.
- **Counterfactual:** Push the just-finalized transcript into `TranscriptCoordinator` incrementally and reserve full reloads for startup, repair, or explicit refresh. Keep telemetry emission separate from history refresh. Do not rescan the archive on every successful dictation.
- **Counterfactual rationale:** Respects the existing split where `TranscriptCoordinator` owns view state and `TranscriptStore` owns disk IO.
- **Falsifiability:** Seed the transcript directory with 10,000 JSON files, complete a short dictation, and measure time from `.complete` to responsive history UI. A visible stall or delayed state transition confirms the static hotspot.
- **Audit `depends_on`:** REF-01 (because the call site lives inside AppState's state-change closure).
- **Phase addressing:** Phase C (§9), shipped under #428 / PR #432 (2026-04-21).

### 3.6 REF-06 — Cap or rotate Bluetooth route diagnostics

- **Title:** Cap or rotate Bluetooth route diagnostics instead of blind append-only logging
- **Dimension:** Resource lifecycle (Static Risk Assessment)
- **Tier:** SMALL · **Severity:** MEDIUM · **Confidence:** High · **Est. LOC delta:** 45
- **Rule violated:** `.claude/rules/architecture-rules.md §Architecture Definition of Done / Placement and ownership`
- **Worst-violation location:** `Sources/EnviousWisprAudio/AudioCaptureManager.swift:525-530`
- **Snippet (verbatim):**

  ```swift
  nonisolated static func btRouteLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [BTRoute] \(message)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/EnviousWispr/bt-route.log")
    try? FileManager.default.createDirectory(
  ```

- **Counterfactual:** Route BT diagnostics through a small rotating sink or teach `AppLogger` a capped cross-process file mode. Set a byte cap and retention count. Keep the escape hatch, but stop blind append-only growth.
- **Counterfactual rationale:** Matches the explicit lifetime ownership already used for model unloads in `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:L1289-L1305`.
- **Falsifiability:** Simulate repeated Bluetooth route churn for several days, then inspect `~/Library/Logs/EnviousWispr/bt-route.log`. Unbounded file growth confirms the lifecycle leak.
- **Phase addressing:** R4 (#362, new §15).

### 3.7 Audit strengths — what is already exemplary

Preserve and replicate. Do not refactor these patterns away.

| Pattern | File:line | Why to preserve |
|---|---|---|
| Thin coordinator over backend sources | `AudioCaptureManager.swift:6-10` | Crisp ownership statement; hardware and recovery logic live below the app-facing manager. |
| Real-time safe lock boundary | `PreRollForwarder.swift:63-99` | Audio thread stays fast; callbacks outside lock; concurrency contract documented inline. |
| Redaction before telemetry export | `ObservabilityBootstrap.swift:97-115` | Observability treated as a limb; sensitive strings stripped before third-party SDK handoff. |
| Fail-open actor wrapper around ML | `LanguageDetector.swift:55-62` | Upstream library failure converts to abstention; heart stays intact. |
| Local test seam on heart finalization | `TranscriptFinalizer.swift:68-78` | Seam intentional, local, keeps production protocol surface narrow. |
| Explicit resource teardown | `WhisperKitPipeline.swift:1293-1298` | Model unload policy owned by pipeline; no drift into ambient state. |
| Narrow ASR protocol | `ASRManagerInterface.swift:4-9` | Exemplary cross-module boundary; one protocol hides backend variety. |
| Structured failure reporting | `SentryBreadcrumb.swift:165-170` | Context attached on capture; no hand-built payloads on every failure path. |
| Bounded drain window | `TranscriptionPipeline.swift:619-624` | Latency hazard named, bounded wait, documented ordering. |

R2 aspires to the `ASRManagerInterface` shape. Phase C aspires to the `TranscriptFinalizer` test-seam discipline. Phase D aspires to the `AudioCaptureManager` thin-coordinator ownership.

### 3.8 Audit meta-recommendations

Process-level findings (capped at 3 by schema design):

1. **CI guard on cross-module public exposure.** Fail on new `public` in non-App modules and on TODO comments promising later narrowing. Triggered by REF-02 + the confessional comment.
2. **Release-config privacy smoke test.** Assert transcript text never reaches OSLog, Sentry, or PostHog payloads. Triggered by REF-03 + the strong redaction posture elsewhere.
3. **Runtime fault-injection suite.** Rapid start/stop, BT route changes, XPC interruption during recording. Triggered by Static Risk grades + the not-assessed concurrency/resource gaps on the heart path.

These roll into Phase E (§11) and Track 2 (§18-§21).

### 3.9 Audit Red Team — Codex's self-critique

Codex's built-in red-team step produced:

- **Least confident finding:** REF-04 prompt delimiter hardening. "Static review does not prove that every supported model will treat [case/whitespace] variants as delimiter control inside the sandwich prompt." **What would resolve it:** One adversarial eval run across all supported providers. → V4 (§21).
- **Top not-assessed gap:** Real audio-thread, MainActor, and XPC interleavings during active recording. "The heart crosses those boundaries. If the interleaving is wrong, raw transcription fails even with every limb disabled." → V2 (§19).

### 3.10 Audit not-assessed (honest scope limits)

Six areas static review could not evaluate, with runtime remediation:

1. Cold-start latency and end-to-end dictation speed → `scripts/heart-path-bench.sh --cold` (V1, §18).
2. Real-time concurrency under CoreAudio/MainActor/XPC interleavings → fault-injection matrix (V2, §19).
3. Memory growth and leak behavior during long recordings → Instruments Allocations + Leaks (V1, §18).
4. Actual privacy exposure of release-build logs and telemetry payloads → release-build log audit + Sentry/PostHog proxy (V3, §20).
5. Prompt-injection resilience across providers → `scripts/eval/` adversarial corpus (V4, §21).
6. Accessibility paste compatibility across target applications → manual or UI automation across target apps (not in Track 2 scope; tracked separately in AX epics).

Item 6 is out of this epic's scope.

### 3.11 Severity × confidence distribution

From the audit JSON: 0 CRITICAL, 3 HIGH (2 High-confidence REF-01 and REF-02, 1 Medium-confidence REF-03), 3 MEDIUM (2 High-confidence REF-05 and REF-06, 1 Low-confidence REF-04), 0 LOW. Signal-to-noise ratio is high. No false-alarm flood.

---

## 4. Code reality — current state snapshot (2026-04-18)

A fresh session reading this section knows the shape of every file the epic touches without needing to re-grep.

### 4.1 AppState.swift — 965 lines, coordinates 10+ domains

Location: `Sources/EnviousWispr/App/AppState.swift`. Declared `@MainActor @Observable final class AppState`.

Direct property declarations (L14-L55ish):

- `settings = SettingsManager()` — owns every user setting.
- `permissions = PermissionsService()` — mic / accessibility / AX permission flows.
- `audioCapture: any AudioCaptureInterface` — injected.
- `asrManager: any ASRManagerInterface` — injected.
- `transcriptStore = TranscriptStore()` — disk I/O layer (now leaked into AppState).
- `keychainManager = KeychainManager()` — API key storage.
- `hotkeyService = HotkeyService()` — Carbon hotkey registration (sensitive timing).
- `benchmark = BenchmarkSuite()`
- `recordingOverlay = RecordingOverlayPanel()` — 859-line overlay window.
- `ollamaSetup = OllamaSetupService()`
- `whisperKitSetup = WhisperKitSetupService()`
- `audioDeviceList = AudioDeviceList()`
- `captureTelemetry = CaptureTelemetryState()`
- `pipeline: TranscriptionPipeline` — Parakeet orchestration.
- `whisperKitPipeline: WhisperKitPipeline`
- `polishService: TranscriptPolishService` — standalone re-polish service.
- `settingsSync: PipelineSettingsSync` — 398-line switchboard (Phase B shrinks this).

Plus ephemeral state: `whisperKitPreloadTask`, `postCompletionWarningTask`, multiple `@Observable` display properties.

Two near-identical `onStateChange` closures (one per pipeline, L221-L314 per #196 plan). Both do: hotkey register/unregister, overlay intent mapping, post-completion warning triggers, telemetry-on-completion, transcript reload.

Custom-words fanout at L316-L321 (the REF-01 worst violation). Five consumers, updated by hand.

Transcript reload at L394-L398 (the REF-05 worst violation).

Other responsibilities visible in the file: WhisperKit preload observation, backend type migration, post-completion toast scheduling, display-property computation (`activeModelName`, `activeLLMDisplayName`, `modelStatusText`), backend routing (`activePipeline`, `pipelineState`, `lastPolishError`, `activeTranscript`).

### 4.2 TranscriptCoordinator.swift — 74 lines, thin, missing `append`

Location: `Sources/EnviousWispr/App/TranscriptCoordinator.swift`. `@MainActor @Observable final class`. Owns:
- `transcripts: [Transcript]` — in-memory history for UI.
- `searchQuery`, `selectedTranscriptID` — view state.
- `filteredTranscripts` — computed.
- `load()` — calls `store.loadAll()` on a background task.
- `delete(_:)`, `deleteAll()`.

**Does not expose `append(transcript:)`.** That is the Phase C gap.

### 4.3 TranscriptStore.swift — 81 lines, disk layer

Location: `Sources/EnviousWisprStorage/TranscriptStore.swift`. Public API:
- `loadAll() async throws -> [Transcript]` — full directory scan, JSON decode per file, returns sorted.
- `save(_:) throws` — writes single transcript (exists; confirm signature at ship time).
- `delete(id:) throws`, `deleteAll() throws`.

`loadAll()` is the expensive path. Post-refactor, history refresh on completion should call `save()` + an in-memory append, not `loadAll()`.

### 4.4 PipelineSettingsSync.swift — 398 lines, 41 handler branches (Phase B target: ~200)

Location: `Sources/EnviousWispr/App/PipelineSettingsSync.swift`. **Verified 2026-04-18: 398 lines, 41 case/handler branches** (not the 290 figure in the original #195 plan — file grew). Every setting mutation writes to both pipelines in parallel. The duplication is mechanical; the issue is lifecycle: some settings should freeze per-recording, not mutate mid-recording. Phase B extracts `DictationSessionConfig` for those.

**Realistic target after Phase B:** ~200 lines, ~20 handler branches (the original "~150" was based on the smaller baseline). Update Phase B's DoD LOC expectation to reflect the 398 starting point.

**Phase B evidence gap (per GPT council review):** the current #195 plan proposed a nine-field `DictationSessionConfig` without grep-anchored evidence that those are the only settings mutating mid-recording. Phase B's substep 1 MUST now explicitly inventory every `handleSettingChanged` case and classify each as "freeze-per-recording" or "live-mutable" with evidence, before writing the struct.

### 4.5 WhisperKitBackend.swift + WhisperKitPipeline.swift — the R2 surface

Location ASR: `Sources/EnviousWisprASR/WhisperKitBackend.swift`. Public items leaked for cross-module use:
- `func makeDecodeOptions(from:sampleCount:) -> DecodingOptions` at L155-L158 (TODO-confessed).
- `whisperKitTokenizer` getter (grep confirmed at `WhisperKitPipeline.swift:1154`).
- `WhisperKitIncrementalWorker` constructor — the worker type lives at `Sources/EnviousWisprASR/WhisperKitIncrementalWorker.swift` as `public actor`.

Location Pipeline: `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:1150-1156`. Three cross-module reaches co-located:

```swift
let opts = await backend.makeDecodeOptions(from: transcriptionOptions, sampleCount: 0)
// BRAIN: gotcha id=nonisolated-unsafe-tokenizer
...
nonisolated(unsafe) let tokenizer = await backend.whisperKitTokenizer
let worker = WhisperKitIncrementalWorker(
  whisperKit: kit, decodingOptions: opts, tokenizer: tokenizer)
```

R2 shape: collapse these three reaches into one narrow method on a bridge type (Approach A) or relocate the tail-decode setup into ASR (Approach B). §12 covers both.

### 4.6 TextProcessingRunner.swift — the R3 surface

Location: `Sources/EnviousWisprPipeline/TextProcessingRunner.swift`. Line 32-36 emits raw transcript at `.info` level through `AppLogger`. Same file likely has adjacent log sites that need inventory as part of R3 (§13 substep 1).

### 4.7 AudioCaptureManager.swift — the R4 surface

Location: `Sources/EnviousWisprAudio/AudioCaptureManager.swift`. Line 525-530 is `btRouteLog`, called cross-process (main app + XPC service write same file). No cap, no rotation. R4 replaces with rotating sink (§15).

### 4.8 Other App/ files (context — not flagged by this audit)

For completeness, other files in `Sources/EnviousWispr/App/`:
- `AppDelegate.swift` (461 lines) — window lifecycle, menu bar, dock icon.
- `RecordingOverlayPanel.swift` (859 lines) — overlay panel rendering. **Not flagged by this audit.** Notable caveats:
  - Size alone is not a smell (SwiftUI views accrete markup).
  - It is a consumer of `AppState.onPipelineStateChange` and may be affected by Phase A's handler extraction.
  - Council review flagged this as a suspicious omission from the audit scope. If the post-epic audit rerun (§22.3) grades it or adjacent code poorly, open a new standalone issue under epic #319 for a follow-on decomposition — do NOT fold into this epic mid-flight.
- `MenuBarIconAnimator.swift` (333 lines) — icon animation state machine.
- `BenchmarkSuite.swift` (263 lines) — benchmark harness.
- `AIAvailabilityCoordinator.swift` (209 lines) — AI availability checks.
- `LLMModelDiscoveryCoordinator.swift` (98 lines) — model discovery.
- `CustomWordsCoordinator.swift` (51 lines) — **the current custom-words publisher, single `onWordsChanged` callback.** Phase D keeps this type but lets `CustomWordsPropagator` subscribe to it, replacing the direct AppState closure.
- `AudioDeviceList.swift` (20 lines).

`CustomWordsCoordinator` is small and correct today; Phase D wires the propagator as its subscriber. `RecordingOverlayPanel` is flagged for post-epic follow-on, not this epic.

### 4.9 AppState concrete-type dependencies — verified count

Verified 2026-04-18 via grep of `^\s+let [a-zA-Z]+ = [A-Z][a-zA-Z]*\(\)` against `AppState.swift`. Twelve direct concrete-type property declarations at file scope:

1. `permissions = PermissionsService()`
2. `transcriptStore = TranscriptStore()` — moved into `TranscriptCoordinator` ownership in Phase C.
3. `keychainManager = KeychainManager()`
4. `hotkeyService = HotkeyService()`
5. `benchmark = BenchmarkSuite()`
6. `recordingOverlay = RecordingOverlayPanel()`
7. `ollamaSetup = OllamaSetupService()`
8. `whisperKitSetup = WhisperKitSetupService()`
9. `audioDeviceList = AudioDeviceList()`
10. `captureTelemetry = CaptureTelemetryState()`
11. `customWordsCoordinator = CustomWordsCoordinator()` — Phase D wires a propagator as its subscriber but this property stays.
12. `aiAvailability = AIAvailabilityCoordinator()`

Plus `settings = SettingsManager()`. Audit reported 11 (close; count includes interface-typed slots).

**Target after Phases A + C + D:** ≤ 8 direct concrete-type property declarations. Larger reduction if the epic decides to delegate setup services (ollamaSetup, whisperKitSetup) into a new `SetupCoordinator` — track that as a Phase E candidate (§11).

### 4.10 Tool existence — verified (2026-04-18)

Both scripts referenced by the bible exist:
- `scripts/heart-path-bench.sh` — present; runs cold/hot bench per `validation-discipline.md §9`.
- `Tests/RuntimeUAT/wispr_eyes.py` — present; `test_recording`, `tts`, etc. per `tools-and-apps.md §2`.

No hallucinated tool paths.

### 4.11 Custom-words consumer types — verified MainActor (2026-04-18)

Both primary custom-words consumer types are already `@MainActor`:
- `Sources/EnviousWisprPipeline/WordCorrectionStep.swift` — `@MainActor public final class WordCorrectionStep`.
- `Sources/EnviousWisprPipeline/LLMPolishStep.swift` — `@MainActor public final class LLMPolishStep`.

Phase D's `CustomWordsConsumer` protocol can safely require `@MainActor` isolation without forcing a new actor on consumers.

### 4.13 AppState disposition matrix — every owned dependency's fate

Enumerated 2026-04-18. Every `let X = TypeName()` or injected interface property on `AppState`. Fate after this epic:

| # | Property | Line | Disposition | Reason |
|---|---|---|---|---|
| 1 | `settings = SettingsManager()` | ~15 | **STAYS** | Composition root owns settings. Shape stable. |
| 2 | `permissions = PermissionsService()` | 18 | **STAYS** | Top-level permission flow. Low coupling. |
| 3 | `audioCapture: any AudioCaptureInterface` | 19 | **STAYS** | Composition root injects audio. Stable. |
| 4 | `asrManager: any ASRManagerInterface` | 20 | **STAYS** | Composition root injects ASR. Stable. |
| 5 | `transcriptStore = TranscriptStore()` | 21 | **MOVES → TranscriptCoordinator** (Phase C) | REF-05. Ownership belongs to the coordinator that serves views. |
| 6 | `keychainManager = KeychainManager()` | 22 | **STAYS** | Low-coupling utility. Not a decomposition target. |
| 7 | `hotkeyService = HotkeyService()` | 23 | **STAYS** | Carbon timing sensitive; do NOT touch. |
| 8 | `benchmark = BenchmarkSuite()` | 24 | **STAYS (post-epic candidate)** | Could move to a BenchmarkCoordinator; not in this epic. |
| 9 | `recordingOverlay = RecordingOverlayPanel()` | 25 | **STAYS** | Overlay window owner. Size is decoration, not debt. |
| 10 | `ollamaSetup = OllamaSetupService()` | 26 | **MOVES → SetupCoordinator** (Phase F, new in v1.3) | Setup orchestration is a cohesive domain; extracting gets AppState closer to target. |
| 11 | `whisperKitSetup = WhisperKitSetupService()` | 27 | **MOVES → SetupCoordinator** (Phase F) | Same. Co-owned by SetupCoordinator with ollamaSetup. |
| 12 | `audioDeviceList = AudioDeviceList()` | 28 | **STAYS** | 20-line view adapter. Not debt. |
| 13 | `captureTelemetry = CaptureTelemetryState()` | 29 | **STAYS (post-epic candidate)** | Could absorb into R5's HeartPathTelemetryEmitter eventually; not in this epic. |
| 14 | `customWordsCoordinator = CustomWordsCoordinator()` | 69 | **STAYS** | Phase D adds `CustomWordsPropagator` as its subscriber; the coordinator itself remains the publisher. |
| 15 | `aiAvailability = AIAvailabilityCoordinator()` | 75 | **STAYS** | 209-line AI availability checks. Own domain already. |

Plus architectural fixtures that aren't counted in "direct concrete deps" because they are either pipelines (peers, not owned state) or injected via composition:
- `pipeline: TranscriptionPipeline`, `whisperKitPipeline: WhisperKitPipeline` — pipeline layer peers
- `polishService: TranscriptPolishService` — peer service
- `settingsSync: PipelineSettingsSync` — shrinks in Phase B
- Ephemeral task slots: `whisperKitPreloadTask`, `postCompletionWarningTask` — not deps

**Count trajectory:**
- **Before epic:** 15 owned concrete deps.
- **After Phase C:** 14 (transcriptStore → TranscriptCoordinator).
- **After Phase F:** 12 (ollamaSetup + whisperKitSetup → SetupCoordinator, but add 1 dep on the new SetupCoordinator itself; net -1).
- **Target:** ≤ 12 direct concrete deps (Phase E regression test calibrated here).

Phase E previously targeted ≤ 8. That target was wrong given the disposition matrix. Revised target ≤ 12 documented in §11.

### 4.12 Rules files that govern each phase

Single quick-reference table. Details in `.claude/rules/`.

| Rule file | Phases it governs primarily |
|---|---|
| `architecture-rules.md` | A, B, C, D, E, R2 (anti-god-object, access control, state ownership, intentional duplication) |
| `swift-patterns.md` | All Swift phases (Swift 6 concurrency, `@preconcurrency` imports, actor isolation) |
| `validation-discipline.md` | All phases (test obligations, cold-path, runtime UAT, architecture regression) |
| `workflow-process.md` | All phases (plan/council/codex gates, tier routing, DoD) |
| `session-behavior.md` | All sessions (wind-down, no rapid-fire releases, overnight bounds) |
| `tools-and-apps.md` | UAT phases (wispr-eyes discipline, MCP removal, TTS engine) |

---

## 5. External refactor methodology — patterns applied per phase

This epic is not invented from scratch. It maps to established refactor techniques. Naming them keeps future sessions aligned on *what kind of change* each phase is.

### 5.1 Core references

- **Martin Fowler — Refactoring, 2nd ed.** The catalog is the canonical source for Extract Class, Move Method, Introduce Parameter Object, Replace Conditional with Polymorphism, Split Phase. Catalog at <https://refactoring.com/catalog/>.
- **Martin Fowler — StranglerFigApplication pattern.** For gradual replacement of large modules. Original essay <https://martinfowler.com/bliki/StranglerFigApplication.html>.
- **Martin Fowler — Branch by Abstraction.** Safe in-process refactor under an abstraction layer while both old and new implementations coexist. Essay <https://martinfowler.com/bliki/BranchByAbstraction.html>.
- **Martin Fowler — Parallel Change (Expand-Contract).** Ship additive changes first, migrate consumers, then remove the old. Essay <https://martinfowler.com/bliki/ParallelChange.html>.
- **Michael Feathers — Working Effectively with Legacy Code.** Seams, characterization tests, sprout method, wrap method.

### 5.2 Pattern × phase mapping

| Pattern | Phases that use it | Why |
|---|---|---|
| **Extract Class** (Fowler) | A, C, D, R5 | Pull cohesive responsibilities out of AppState / pipelines into focused types. |
| **Move Method** (Fowler) | C | `transcriptCoordinator.load()` call site moves out of AppState into the coordinator's own completion-integration path. |
| **Introduce Parameter Object** (Fowler) | B | `DictationSessionConfig` freezes per-recording values into a value type. |
| **Branch by Abstraction** (Fowler) | R2 | New `WhisperKitDecodeBridge` protocol introduced; `WhisperKitBackend` conforms; `WhisperKitPipeline` migrates to bridge; old public methods deleted. |
| **Parallel Change** (Fowler) | D | Add `CustomWordsPropagator.register` + keep `onWordsChanged` callback; migrate consumers; then remove old fanout. |
| **Characterization Tests** (Feathers) | A, C, D, R5 | Before refactoring, capture current behavior (telemetry event shapes, overlay intents, transcript delivery) as pin tests. Refactor cannot change these without failing the pin. |
| **Sprout Method / Sprout Class** (Feathers) | All new coordinators | New behavior grows in a new type that the old code calls into, not as surgery inside the old type. |
| **Replace Inheritance with Delegation** | not used | EnviousWispr does not use class hierarchies that need this. |
| **Extract Interface** (Fowler) | R2, D | `WhisperKitDecodeBridge` protocol (R2); `CustomWordsConsumer` protocol (D). |
| **Progressive delegation** (conceptually Strangler Fig-like, but intra-class) | A+C+D sequence | Over three PRs, `AppState`'s responsibilities are progressively routed to coordinators until only the composition root remains. Strangler Fig proper is a *system-level* replacement pattern (Fowler's essay is about new microservices replacing a legacy monolith behind a facade); calling an intra-class decomposition "Strangler Fig" is imprecise. The spirit is borrowed — incremental replacement under a stable public surface — but the mechanics here are plain Extract Class + Move Field + Parallel Change, not routing at a facade. |

### 5.3 Testing strategy per pattern

Each refactor pattern carries its own test strategy.

- **Extract Class + Move Method:** write a characterization test on the current behavior *before* moving code. Refactor. Rerun the test. Same output. This protects telemetry and overlay contracts.
- **Introduce Parameter Object:** unit test the object's initializer captures every expected field. Unit test downstream consumers use the object's fields correctly. Integration test confirms settings mutated mid-recording do NOT change behavior of the active recording (Phase B).
- **Branch by Abstraction:** compile error is the test that finds every caller. Then unit tests cover the bridge's minimum surface against a mock.
- **Parallel Change:** contract test for each consumer of the new subscription API. Integration test: add a word, confirm all registered consumers see it in one pass.

### 5.4 What the patterns are NOT

- Not a "clever design pattern" layer. No Observer-in-Swift-6 rewrites; the goal is ownership correctness, not enthusiasm.
- Not unifying the pipelines (intentional duplication).
- Not an excuse to introduce DI frameworks. EnviousWispr uses plain constructor injection; this epic stays in that idiom.

---

## 6. Phase index and dependency graph

### 6.1 Eleven phases across two tracks

| # | ID | Title | Track | Tier | Issue | Status | Est. LOC |
|---|---|---|---|---|---|---|---|
| 1 | **A** | PipelineStateChangeHandler extraction | 1 | REFACTOR | #196 | SHIPPED (PR #422, 2026-04-20) | ~200 (−) |
| 2 | **B** | DictationSessionConfig freeze-at-startRecording | 1 | REFACTOR | #195 | SHIPPED (PR #424, 2026-04-20) | ~140 (−) |
| 3 | **C** | TranscriptCoordinator owns history | 1 | MEDIUM | #428 | SHIPPED (PR #432, 2026-04-21) | +283/−39 actual |
| 4 | **D** | CustomWordsPropagator replaces 5-way fanout | 1 | MEDIUM | #496 | SHIPPED (PR #497, 2026-04-29) | +/− per PR |
| 5 | **E** | Architecture regression tests | 1 | SMALL | #502 | SHIPPED (PR #504 + #505, 2026-04-30) | ~+280 actual (tests + script + CI + docs + 1-line ASR access narrowing) |
| **F** | SetupCoordinator extraction (NEW v1.3) | 1 | MEDIUM | #501 | SHIPPED (PR #503, 2026-04-30, F-Exec) | ~+135 net |
| 6 | **R2** | WhisperKitBackend adapter (Approach C + LID split) | 1 | MEDIUM/LARGE | #360 | SHIPPED (PR #524, 2026-04-30) | +290 / −128 across 7 files (incl PR #522 prep) |
| 7 | **R3** | Transcript out of logs | 1 | SMALL | #361 | SHIPPED (PR #475, 2026-04-26) | ~40 |
| 8 | **R4** | BT route log rotation | 1 | SMALL | #362 | SHIPPED (PR #476, 2026-04-26) | ~45 |
| 9 | **R5** | HeartPathTelemetryEmitter | 1 | MEDIUM | #290 | SHIPPED (PR #511, 2026-04-30) | +1079 / −250 (mostly tests) |
| 10 | **R6** | Prompt delimiter hardening (gated) | 1 | SMALL | #363 | GATED on V4 | ~60 |
| 11 | **V1** | Production telemetry analysis (replaced cold bench + 3-hr profile) | 2 | VALIDATION | #364 | SHIPPED via V1a (2026-04-30) | n/a |
| 12 | **V2** | Fault injection toolkit (Lane A automated + Lane B HITL split) | 2 | VALIDATION | #291 (extended), #559 cleanup | SHIPPED via PR #544 (toolkit) + PR (cleanup #559, 2026-05-02) — A5 renamed `A5_proxy_buffer_drop_watchdog`; OS-level audio interruption rebucketed to Lane B HITL (`docs/LANE_B_AUDIO_TESTS.md`); #553/#555/#556 confirmed harness artifacts via human-action repro | n/a |
| 13 | **V3** | Entitlement + PII audit | 2 | VALIDATION | #365 | PLANNED §20 | n/a |
| 14 | **V4** | Prompt adversarial eval | 2 | VALIDATION | #366 | PLANNED §21 | n/a |
| 15 | **G1** | TextProcessingRunner — polish step by type | 1 | SMALL | #388 | PLANNED §17A | ~20 |
| 16 | **G2** | TextProcessingRunner — logger injectable | 1 | SMALL | #389 | PLANNED §17A | ~30 |
| 17 | **G3** | TranscriptionPipeline — finalizer/paste DI | 1 | SMALL/MEDIUM | #394 | PLANNED §17A | ~60 |
| 18 | **G4** | PasteCascadeExecutor — DI seams | 1 | SMALL/MEDIUM | #396 | PLANNED §17A | ~80 |
| 19 | **G5** | ASRManager — backend injection | 1 | SMALL | #398 | PLANNED §17A | ~40 |

That is 19 rows (14 original + 5 Phase G sub-phases imported from epic #385 on 2026-04-20). The "eleven phases" header is historical; count work items directly from this table.

### 6.2 Dependency graph (ASCII)

```
                    ┌────────────────────────────────────────────────┐
                    │              SESSION 1 (parallel)              │
                    └────────────────────────────────────────────────┘
                          │           │            │           │
                          ▼           ▼            ▼           ▼
                       Phase A      R5           R3          R4
                       (#196)      (#290)       (#361)      (#362)
                          │           │            │           │
                          │           │            │           │
                          └───────────┴───────┬────┴───────────┘
                                              │
                    ┌─────────────────────────┴──────────────────────┐
                    │              SESSION 2 (parallel)              │
                    └─────────────────────────┬──────────────────────┘
                                              │
                    ┌──────────┬──────────────┼───────────┬──────────┐
                    ▼          ▼              ▼           ▼          ▼
                 Phase B      V1             V2          V3         (V4 kick)
                 (#195)      (#364)      ext #291     (#365)      (#366)
                 UX call      │              │           │          │
                              │              │           │          │
                    ┌─────────┴──────────────┴───────────┘          │
                    │  SESSION 3 (structural, after Session 1)      │
                    └─────────┬──────────────────────────┬──────────┘
                              │                          │
                              ▼                          ▼
                         Phase C                      Phase D
                         (TranscriptCoordinator)      (CustomWordsPropagator)
                              │                          │
                              └───────────┬──────────────┘
                                          ▼
                                       Phase E              R2
                                   (arch regression)       (#360)
                                                          after AppState
                                                          stable
                                          │
                    ┌─────────────────────┴──────────────────────────┐
                    │  SESSION 4 (gated + close)                     │
                    └─────────────────────┬──────────────────────────┘
                                          ▼
                                       V4 run ───►─┐
                                                    ▼
                                                 R6 decision
                                                    (#363 ship if V4 failure
                                                     confirmed; else close)
                                          │
                                          ▼
                                    Senior Audit rerun
                                          │
                                          ▼
                                  Epic #319 close-out
```

### 6.3 Dependency notes

- **A → C:** Phase C's call-site edit lands inside the state-change closure that Phase A extracts. Easier after A.
- **A → D:** Phase D removes `AppState`'s custom-words fanout; after Phase A, the closure body is already simpler.
- **C + D land together:** both operate on `AppState`. Single merge avoids intermediate half-decomposed state. Same PR or tightly sequential, with E immediately after.
- **B independent:** Phase B is a signature change on `startRecording`, orthogonal to A/C/D.
- **R5 independent:** Extracts from pipelines, not AppState.
- **R2 after AppState stable:** Not because of code dependency, but because parallelizing two REFACTOR-tier things amplifies merge conflict risk. Can technically run in parallel.
- **R3, R4 independent:** small, touch unrelated files.
- **R6 gated on V4:** do not start code work until V4 confirms a defect.
- **V1/V2/V3 can run anytime:** prefer concurrent with Session 2 so their data informs later phases.

### 6.4 Merge strategy

- One PR per phase. No phase bundles code from another phase (except Phase C+D which may land together given shared file).
- Use `git worktree add` for parallel phases; never `git checkout` on main tree. Per project `CLAUDE.md` rule 6 "Git session isolation."
- Rebase on main before opening PR; resolve conflicts locally. Force-push discipline per workflow-process §7 "Own the merge."
- Phase A and Phase D both edit AppState's `onWordsChanged` region. If Phase A ships first (planned), Phase D rebases cleanly. If both are in flight simultaneously, coordinate — Phase D is the author of the region change.

---

## 7. Phase A — PipelineStateChangeHandler extraction

**Issue:** #196 · **Existing plan:** `docs/feature-requests/issue-196-2026-04-18-appstate-refactor.md` · **Status:** SHIP-READY (council-approved, 2026-04-18)
**Pattern:** Extract Class + Sprout Class (Fowler / Feathers) · **Tier:** REFACTOR · **Est. LOC delta:** ~200 (removed from AppState) + ~210 (new handler + protocol + tests) = neutral

### 7.1 Why this phase exists

Both `TranscriptionPipeline` and `WhisperKitPipeline` emit state changes into AppState's `onStateChange` closures (Parakeet L344-L406, WhisperKit L409-L463 — verified 2026-04-20 against `origin/main` @ `8c5a5f3`). Both closures do the same work: hotkey register/unregister, overlay intent mapping (with three-way post-completion priority), post-completion warning scheduling AND cancellation, telemetry emission, transcript reload. The code is near-identical. Diff is trivial. The duplication is the tell — this is cohesive logic that wants to live in one type.

### 7.2 Design summary

**Adversarial-verified state enum shapes (2026-04-18, re-verified 2026-04-20):**
- `PipelineState` (Parakeet — defined in `Sources/EnviousWisprCore/AppSettings.swift:17`, NOT nested under `TranscriptionPipeline`) — seven cases: `.idle`, `.loadingModel`, `.recording`, `.transcribing`, `.polishing`, `.complete`, `.error(String)`.
- `WhisperKitPipelineState` (`Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:12`) — nine cases: `.idle`, `.startingUp`, `.loadingModel`, `.ready`, `.recording`, `.transcribing`, `.polishing`, `.complete`, `.error(String)`.

The two states share seven of the enum cases and diverge on `.ready` / `.startingUp` (WhisperKit-only, used while the model is being loaded but before recording becomes available). The "shared" handler cannot blindly accept `any PipelineStateProtocol`; it must either:

**Design option A — Protocol with `.activity` coarse-grain categorization.**

```swift
public enum PipelineActivity: Sendable {
  case idle          // .idle, .ready (both: not active, accepting input)
  case preparing     // .startingUp, .loadingModel (not yet recording)
  case recording     // .recording
  case processing    // .transcribing, .polishing
  case complete      // .complete
  case error(String)
}

@MainActor
public protocol PipelineStateProtocol: Equatable {
  var activity: PipelineActivity { get }
  var isActive: Bool { get }   // true during preparing/recording/processing
  var errorReason: String? { get }
}
```

Both existing state enums conform by extension, mapping their specific cases onto `activity`. Backend-specific states (`.ready`, `.startingUp`) both map to `.preparing` / `.idle` coherently.

**Codex A-review 2026-04-18 critical correction: `PipelineActivity` is for CONTROL FLOW ONLY, not for overlay-label derivation.** The WhisperKit pipeline distinguishes "Starting..." (`.startingUp`) from "Loading model..." (`.loadingModel`) at `WhisperKitPipeline.swift:307-313`; both pipelines distinguish "Transcribing..." (`.transcribing`) from "Polishing..." (`.polishing`) at `TranscriptionPipeline.swift:1279-1282` and `WhisperKitPipeline.swift:315-317`. A handler that derives overlay text from the coarse `PipelineActivity` SILENTLY FLATTENS those user-visible labels. Fix: the handler receives the concrete state enum and uses the existing `overlayIntent` computed on the pipeline (which already maps concrete state → user-visible label) for overlay display. `PipelineActivity` is used only for: `isActive` computation, `.complete` / `.error` control-flow detection, and tiebreaker logic. Not for label rendering.

**Design option B — Two handlers, one base, backend-specific overrides.**

Less preferred; keeps backend coupling in view.

**Recommendation: Option A** (with v1.10 correction above). Cleaner abstraction for control flow; overlay labels preserved by reading concrete `overlayIntent` off the pipeline, not deriving from coarse activity.

New `PipelineStateChangeHandler` implementation:

```swift
// Sources/EnviousWispr/App/PipelineStateChangeHandler.swift
// Adversarial-verified 2026-04-18 + re-verified 2026-04-20 (Codex plan review + Codex A-review + v1.16 Gate 0 sweep):
// - Overlay UI owner is RecordingOverlayPanel (type OverlayManager does not exist).
// - Real API is recordingOverlay.show(intent:audioLevelProvider:isRecordingLocked:).
// - The intent value type is OverlayIntent (NOT RecordingOverlayIntent). Defined in
//   Sources/EnviousWisprUI/ (.hidden / .recording(audioLevel:) / .processing(label:) /
//   .warning(message:) / .clipboardFallback). Pipeline.overlayIntent returns this type.
// - Telemetry facade is TelemetryService.shared (Sources/EnviousWisprServices/TelemetryService.swift:8).
// - Backend injected at INIT (one per handler instance), not per-call. reportDictationCompleted
//   derives backend from Transcript.backendType; the only backend-requiring call is pipelineFailed.
@MainActor
internal final class PipelineStateChangeHandler {
  private let backend: ASRBackendType       // injected at construction
  private let overlay: RecordingOverlayPanelProtocol
  private let audioLevelProvider: @MainActor () -> Float
  private let isRecordingLockedProvider: @MainActor () -> Bool
  private let onTranscriptCompleted: @MainActor (Transcript) -> Void  // Phase C wires this to coordinator.append(_:)
  private var postCompletionWarningTask: Task<Void, Never>?

  init(backend: ASRBackendType,
       overlay: RecordingOverlayPanelProtocol,
       audioLevelProvider: @escaping @MainActor () -> Float,
       isRecordingLockedProvider: @escaping @MainActor () -> Bool,
       onTranscriptCompleted: @escaping @MainActor (Transcript) -> Void) { ... }

  // `overlayIntent` is the pipeline's OWN mapping from concrete state → user-visible label.
  // Handler takes the pre-computed intent rather than deriving from coarse activity —
  // preserves "Starting..." vs "Loading model..." (WhisperKitPipeline.swift:307-313),
  // "Transcribing..." vs "Polishing..." (both pipelines' overlay logic).
  //
  // `isClipboardFallback` is a FIRST-CLASS input because the current production code
  // (AppState.swift:370-388 / :429-445) applies a THREE-WAY priority on .complete:
  //   1. clipboardFallback wins → show .clipboardFallback intent
  //   2. else polish-failed → use pipeline.overlayIntent, then schedule .warning after 400ms
  //   3. else → use pipeline.overlayIntent (success)
  // Collapsing this into just "warning when lastPolishError != nil" would silently drop
  // the clipboard-only notification users rely on for paste-failure feedback.
  func handle<State: PipelineStateProtocol>(
    from: State, to: State,
    overlayIntent: OverlayIntent,             // pipeline's pre-computed label
    isClipboardFallback: Bool,                // from transcript.metrics.pasteTier == "clipboard_only"
    lastPolishError: String?,
    latestTranscript: Transcript?
  ) {
    // 1. overlay.show(intent: resolvedIntent, audioLevelProvider: ..., isRecordingLocked: isRecordingLockedProvider())
    //    where resolvedIntent is:
    //      - to.activity == .complete && isClipboardFallback  → .clipboardFallback
    //      - to.activity == .complete && lastPolishError != nil → overlayIntent (unchanged),
    //        then schedulePostCompletionWarning(message: "Polish failed -- using raw text")
    //      - to.activity == .complete                         → overlayIntent (success path)
    //      - to.activity != .complete                         → overlayIntent AND cancel
    //        any pending postCompletionWarningTask (the previous completion's warning is
    //        superseded by the new state transition; AppState today does this at :386 / :443)
    // 2. Telemetry: TelemetryService.shared.reportDictationCompleted(transcript:inputMode:) when to.activity == .complete.
    //    Backend already on Transcript.backendType; no `backend` parameter needed for this call.
    // 3. Telemetry: TelemetryService.shared.pipelineFailed(...) when errorReason != nil.
    //    Uses self.backend from init. Single source of truth; not per-call.
    // 4. When to.activity == .complete && latestTranscript != nil: call onTranscriptCompleted(latestTranscript).
    //    Phase C wires this closure to TranscriptCoordinator.append(_:). Handler does not know about TranscriptCoordinator.
    //    IMPORTANT: TranscriptFinalizer has already persisted the transcript by the time .complete fires.
    //    append() is in-memory-only. Do NOT call store.save here — that would double-persist.
  }

  // Owned by handler because warning cancellation is tied to the overlay-priority
  // logic above. Moving it out fragments the "completion → warning scheduling"
  // lifecycle across two owners.
  private func schedulePostCompletionWarning(message: String) { ... }
}
```

**Not moved into the handler (stays inline in AppState):**
- `self.onPipelineStateChange?(newState)` fan-out at `AppState.swift:346` (Parakeet) / `:411` (WhisperKit). The WhisperKit closure fans out `self.pipelineState` (unified Parakeet-shaped projection), not the raw WhisperKit enum. This is cross-backend projection glue that belongs in AppState, not in a per-backend handler.
- Inactive→active tiebreaker (owns `lastCapturingBackend` / `prevParakeetActive` / `prevWhisperKitActive` — cross-pipeline state).
- Hotkey register/unregister + `isRecordingLocked = false` reset (see next paragraph).

**Hotkey code stays inline in AppState (Carbon sensitive). NOT just Carbon.** Codex A-review correction: the current inline block at `AppState.swift:344-406` (Parakeet) / `:409-463` (WhisperKit) includes `isRecordingLocked = false` at `:352` and `:417` — that's session/UI state reset, not Carbon hotkey work. If extraction leaves that reset AFTER the handler call, the ordering changes. Fix: keep both the hotkey register/unregister AND the `isRecordingLocked = false` reset inline in AppState BEFORE calling the handler. Document them as two separate concerns that happen to sit in the same block today.

**Tiebreaker stays in AppState, not handler (Codex A-review correction).** The `newState.isActive` inactive→active tiebreaker at `AppState.swift:360-364` (Parakeet) and `:423-427` (WhisperKit, per PR #285 comment) owns cross-pipeline state: `lastCapturingBackend`, `prevParakeetActive`, `prevWhisperKitActive`. Moving it into the handler would force the handler to become stateful about cross-pipeline coordination. Keep in AppState; handler receives its outputs (if any) as parameters.

### 7.3 Substeps (ordered)

1. **Write characterization tests (Feathers).** Concrete mechanism. Verified 2026-04-18: no existing test-seam precedent for `TelemetryService.shared` or `RecordingOverlayPanel.show(intent:)` in `Tests/`. This substep designs the seam; nothing to port.
   - **Overlay intent capture:** `RecordingOverlayPanel` is a concrete `final class`. For testability, extract an internal `RecordingOverlayPanelProtocol` (new) with `show(intent:audioLevelProvider:isRecordingLocked:)`. Concrete panel conforms. Codex A-review 2026-04-18 scope check: the handler only needs `show(...)`. `updateLockState` (`:419`) and `hide` (elsewhere) are used by OTHER AppState paths (`:609`, `:894`), NOT by the extracted shared closure body — do NOT widen the protocol. Test injects a `RecordingOverlayPanelSpy` that records `show(intent:...)` calls into an array. Transition state, assert the captured intent sequence.
   - **Required specific label assertions (Codex A-review finding):** overlay labels must be pinned individually because `PipelineActivity` coarse-grains them. Assert "Starting..." emitted for WhisperKit `.startingUp`, "Loading model..." for `.loadingModel`, "Transcribing..." for `.transcribing`, "Polishing..." for `.polishing`, and correct post-polish-error label when `lastPolishError != nil`.
   - **Required WhisperKit `.ready`-as-completion-equivalent assertion (Codex A-review finding, current ref `AppState.swift:768`):** the delayed-warning path at `schedulePostCompletionWarning` treats `whisperKitPipeline.state == .ready` as completion-equivalent for warning scheduling (`parakeetComplete || whisperKitComplete` where `whisperKitComplete = .complete || .ready`). Test must cover this.
   - **Required three-way overlay-priority assertions (Gate 0 sweep 2026-04-20):** pin each branch at `.complete`:
     - `pasteTier == "clipboard_only"` AND `lastPolishError != nil` → `.clipboardFallback` wins, NO warning scheduled.
     - `pasteTier != "clipboard_only"` AND `lastPolishError != nil` → `pipeline.overlayIntent` shown, `.warning("Polish failed -- using raw text")` fires after 400ms.
     - success path → `pipeline.overlayIntent` shown, no warning scheduled.
     Plus: on any non-complete transition, any in-flight warning task is cancelled (`AppState.swift:386, :443`).
   - **Required inactive→active tiebreaker test (Codex A-review finding, PR #285, `AppState.swift:360-364, :423-427`):** capture `lastCapturingBackend` before and after `newState.isActive` transition; assert tiebreaker sets it only on inactive→active, not active→active.
   - **Telemetry capture:** `TelemetryService` is `public final class TelemetryService` with a `.shared` singleton at `Sources/EnviousWisprServices/TelemetryService.swift:8`. Add a test-only hook as the seam. Adversarial-verified 2026-04-18: `[String: Any]` is NOT Swift 6 `Sendable` — the naive hook signature will not compile. Use a concrete Sendable payload type:
     ```swift
     // TelemetryService.swift (add)
     public struct CapturedTelemetryEvent: Sendable {
       public let name: String
       public let stringProps: [String: String]
       public let intProps: [String: Int]
       public let doubleProps: [String: Double]
       public let boolProps: [String: Bool]
     }
     #if DEBUG
     public var testEventHook: (@Sendable (CapturedTelemetryEvent) -> Void)?
     #endif
     ```
     Every public emission site (`reportDictationCompleted`, `pipelineFailed`, etc.) constructs a `CapturedTelemetryEvent` with typed buckets and calls the hook if set. Tests set the hook, exercise state transitions, assert captured events. The typed-bucket pattern avoids the `Any` Sendable hole without losing property coverage.
   - Seam introduction is a SEPARATE commit from the Phase A refactor proper — the first commit adds the seam and characterization tests against current (pre-refactor) behavior. The second commit extracts the handler. Both commits keep the test suite green. This is the Feathers "cover, then refactor" ordering.
   - **State transitions to cover:** (per §7.2 adversarial enum inventory — Codex A-review correction: `.cancelled` DOES NOT EXIST in either enum; cancellation returns to `.idle` or is handled by late-state guards at `TranscriptionPipeline.swift:372` and `WhisperKitPipeline.swift:448`)
     - Parakeet path: `.idle → .loadingModel → .recording → .transcribing → .polishing → .complete`; plus `.error`.
     - WhisperKit path: `.idle → .ready → .startingUp → .loadingModel → .recording → .transcribing → .polishing → .complete`; plus `.error`.
   - **Assertions to pin:** (a) overlay intent values per transition; (b) telemetry event name + props per `.complete` and `.error`; (c) post-completion warning scheduled when `lastPolishError != nil`; (d) transcript reload fires on `.complete` (NOTE: this behavior MOVES to Phase C — the Phase A test should expect current behavior, and Phase C will update the test when ownership moves).
2. Create `PipelineStateProtocol` in Core. Minimum surface: `isRecording`, `isComplete`, `errorReason`. Both existing state enums conform by extension.
3. Create `PipelineStateChangeHandler`. Copy the shared closure body into `handle(...)`. Dependencies (telemetry, overlayManager, transcript-store callback) injected at init.
4. In AppState, replace both `onStateChange` closures' shared bodies with `self.pipelineStateHandler.handle(...)`. Keep inline hotkey register/unregister after the handler call.
5. Run characterization tests. They must pass unchanged.
6. Run `wispr-eyes` smoke on both backends: overlay intents render same, telemetry events fire same, transcript list updates same.
7. Run `scripts/swift-test.sh` + `swift build -c release`.
8. Periphery scan. REFACTOR-tier requirement per `.claude/rules/workflow-process.md §11`.
9. Open PR with Architecture Closeout section.

### 7.4 DoD

- [ ] Characterization tests written before refactor and pass after.
- [ ] Both pipelines' `onStateChange` closures reduced to ~30 lines each (hotkey + handler call).
- [ ] `PipelineStateChangeHandler.swift` + `PipelineStateProtocol.swift` committed.
- [ ] `scripts/swift-test.sh` passes.
- [ ] `swift build -c release` clean.
- [ ] Live smoke both backends: overlays match pre-refactor, telemetry events match pre-refactor.
- [ ] `AppState.swift` line count decreases by ~200.
- [ ] Periphery scan clean (no new unused symbols).
- [ ] Architecture Closeout section in PR body.
- [ ] Codex review pass.

### 7.5 Rollback

`git revert`. Pipelines fall back to inline closures. No state persisted; no migration needed.

### 7.6 Open questions (inherited from existing #196 plan)

1. Protocol surface minimalism — just `isRecording`, `isComplete`, `errorReason`, or more? Council inclined to minimal.
2. Location of `PipelineStateChangeHandler` — `EnviousWispr/App` (chosen, consistent with ownership) or `EnviousWisprPipeline` (closer to pipelines). Keep App.

---

## 8. Phase B — DictationSessionConfig freeze-at-startRecording

**Issue:** #195 · **Existing plan:** `docs/feature-requests/issue-195-2026-04-18-pipeline-settings-sync.md` · **Status:** UX-blocked (needs product decision)
**Pattern:** Introduce Parameter Object (Fowler) · **Tier:** REFACTOR · **Est. LOC delta:** PipelineSettingsSync −140, new struct +60, pipeline signature changes +~40 = ~−40 net

### 8.1 Why this phase exists

`PipelineSettingsSync` (398 lines actual, plan targets 290→150) writes every settings mutation to both pipelines in parallel. For some settings that is fine (custom words, LLM provider). For others (auto-paste intent, VAD config, clipboard-restore policy, transcription options), mutation mid-recording creates non-deterministic behavior within a single recording. The right model: capture those per-recording values into an immutable value type at `startRecording`; mid-recording settings changes take effect NEXT recording.

### 8.2 Design summary

New `struct DictationSessionConfig: Sendable` in `EnviousWisprCore` captures frozen-per-recording values. Both pipelines' `startRecording` gain a `config: DictationSessionConfig` parameter. `PipelineSettingsSync` removes the cases for those settings.

```swift
internal struct DictationSessionConfig: Sendable {
  let autoCopyToClipboard: Bool
  let autoPasteToActiveApp: Bool
  let restoreClipboardAfterPaste: Bool
  let vadAutoStop: Bool
  let vadSilenceTimeout: Double
  let vadSensitivity: VADSensitivity
  let vadEnergyGate: Bool
  let transcriptionOptions: TranscriptionOptions
  let modelUnloadPolicy: ModelUnloadPolicy
}
```

### 8.3 Substeps (ordered)

1. **UX decision first.** Does the user see anything when they toggle a per-recording setting mid-recording? Options: silent, tooltip in Settings ("Changes apply on next recording"), transient toast on mid-recording change. Defer until §27 answers this. This phase does NOT start without the decision.
2. Write characterization tests for current mid-recording behavior so the new "applies on next recording" semantics are explicitly captured as a test, not drifted.
3. Define `DictationSessionConfig` value type in Core (public, Sendable, explicit `public init`). The `DictationSessionConfig(from: SettingsManager)` capture convenience goes in App (NOT Core) — Core cannot import Services. Codex B-review 2026-04-18 correction.
4. Pipelines gain `startRecording(config:)` parameter. But AppState is NOT a direct caller of `pipeline.startRecording()`. Codex B-review 2026-04-18 correction: verified grep — no direct `pipeline.startRecording` or `whisperKitPipeline.startRecording` calls in `AppState.swift`. The actual paths:
   - Internal to the pipelines themselves: `TranscriptionPipeline.swift:334`, `WhisperKitPipeline.swift:418`.
   - External orchestration: AppState's hotkey start path at `:475-556`, AppState's toggle path at `:825-876`, both routing via `handle(event: .toggleRecording)` on the `DictationPipeline` protocol (`Sources/EnviousWisprPipeline/DictationPipeline.swift:40-46`).
   - Entry UI at `AppDelegate.swift:378`, `MainWindowView.swift:81, :313`.
   The `DictationPipeline` protocol does NOT expose `startRecording(config:)` today. Migration pattern must extend the protocol's event shape (`DictationPipelineEvent`) to carry the session config, OR extend the protocol with `startRecording(config:)` explicitly. Either way, the event-based path — not a direct pipeline call — is what Phase B actually modifies.
5. Factor AppState's start-intent setup (currently duplicated at `:483-499` and `:828-847` for `autoPasteToActiveApp` + `autoCopyToClipboard`) into a single helper that builds `DictationSessionConfig` from settings. Both hotkey-start and toggle-start must use the same helper; otherwise live-mutable drift creeps back between the two paths.
5a. **XPC audio-service path handling (Codex B-review finding — unresolved UNTIL this is addressed).** `PipelineSettingsSync.swift:173-177, :182-186, :201-214` currently pushes VAD configuration changes into `audioCapture.configureVAD(...)` live during an active session. Freezing pipeline fields alone does NOT freeze VAD behavior because the XPC audio service receives live updates. Phase B MUST either: (a) push `DictationSessionConfig` into `audioCapture` at recording start and stop live `configureVAD` during the session, or (b) restructure so audio service reads from the config snapshot. Recommendation: (a). Flag for founder decision at §27.X.
6. Remove `PipelineSettingsSync` cases for the now-frozen settings.
7. Remove the deprecated `startRecording()` once all call sites migrated.
8. Run tests, build, wispr-eyes. Verify mid-recording toggle does NOT change active recording's behavior; next recording does.
9. Open PR with UX decision referenced.

### 8.4 DoD

- [ ] UX decision made and referenced in PR body.
- [ ] `DictationSessionConfig` committed to Core.
- [ ] Both pipelines accept config at startRecording.
- [ ] PipelineSettingsSync shrinks to ~150 lines (adjust target based on actual 398 baseline).
- [ ] Mid-recording setting toggle does not affect active recording (test passes).
- [ ] Next recording reflects the new value (test passes).
- [ ] Settings UI tooltip or toast implemented per UX decision.
- [ ] Codex review pass.
- [ ] Architecture Closeout.

### 8.5 Rollback

`git revert`. PipelineSettingsSync returns to live-update model. Recordings once again can have settings mutate mid-session.

### 8.7 Settings inventory — freeze vs live (grep-anchored 2026-04-18)

Enumerated from `PipelineSettingsSync.swift` handler cases. 35 cases total, classified below. Council R3 flagged that the original plan proposed a 9-field `DictationSessionConfig` without evidence this was the right cut — the inventory below is that evidence.

**Freeze-per-recording (CAPTURED into `DictationSessionConfig` at `startRecording` time):**

| Setting | Line | Rationale |
|---|---|---|
| `autoCopyToClipboard` | 165 | Active recording commits or does not commit; flipping mid-recording confuses outcome. |
| `restoreClipboardAfterPaste` | 235 | Same — paste-lifecycle intent set at start. |
| `vadAutoStop` | 170 | Auto-stop behavior must be consistent within a single recording. |
| `vadSilenceTimeout` | 179 | Same. |
| `vadSensitivity` | 198 | Same. |
| `vadEnergyGate` | 207 | Same. |
| `modelUnloadPolicy` | 229 | Unload decision is per-session lifecycle. |
| `recordingMode` | 137 | Mode (PTT vs hands-free) is chosen before recording starts. |
| `languageMode` | 261 | Auto-detect vs locked is per-recording. |
| `noiseSuppression` | 271 | Audio processing path; mid-recording flip is unsafe. |

That is 10 fields. Adversarial-verified 2026-04-18: `whisperKitLanguage` (line 259) is NOT in this set — its case handler delegates to `syncTranscriptionOptions(settings)` as live plumbing, and current language selection flows through the detector actor + `languageMode`. My v1.3-v1.5 inventory wrongly included `whisperKitLanguage`.

**Live-mutable (stay in `PipelineSettingsSync`; apply to NEXT recording or non-recording surface):**

| Setting | Line | Why live |
|---|---|---|
| `selectedBackend` | 110 | Backend switch applies to next recording. |
| `llmProvider`, `llmModel`, `ollamaModel` | 139, 149, 158 | Polish is post-recording; next polish picks these up. |
| `environmentPreset`, `writingStylePreset`, `customSystemPrompt`, `useExtendedThinking` | 188, 191, 238, 255 | Polish configuration. |
| `hotkeyEnabled` | 168 | Global hotkey registration. |
| `cancelKeyCode`, `cancelModifiers`, `toggleKeyCode`, `toggleModifiers`, `pushToTalkKeyCode`, `pushToTalkModifiers` | 216-226 | Carbon hotkey registration — global. |
| `wordCorrectionEnabled`, `fillerRemovalEnabled` | 245, 248 | Step enablement — flips between recordings. |
| `isDebugModeEnabled`, `debugLogLevel` | 251, 253 | Logging; always live. |
| `selectedInputDeviceUID`, `preferredInputDeviceIDOverride` | 267, 269 | Next recording uses new audio device. |
| `useXPCAudioService`, `useStreamingASR`, `warmEnginePolicy` | 284, 287, 289 | Infrastructure toggles; apply to next recording's pipeline construction. |
| `onboardingState`, `hasCompletedOnboarding` | 282 | Non-recording state. |

That is 22 cases that stay live-mutable.

**Ambiguous / verify during Phase B substep 1:**
- `customSystemPrompt` (line 238) — live now; should it freeze per recording? Probably live (users adjust between recordings).
- `llmProvider` / `llmModel` mid-recording — if polish is already in-flight with provider X and user changes to Y, the in-flight polish still uses X. That is effectively freeze-for-in-flight-polish behavior already. Keep live.

**DictationSessionConfig shape (locked from inventory):**

```swift
// Public because consumed from App (AppState captures snapshot) and Pipeline (pipelines accept at startRecording).
// Public struct does NOT get a public synthesized memberwise init (Swift only synthesizes internal);
// must declare one explicitly for cross-module construction. Codex B-review 2026-04-18 correction.
public struct DictationSessionConfig: Sendable {
  public let autoCopyToClipboard: Bool
  public let restoreClipboardAfterPaste: Bool
  public let vadAutoStop: Bool
  public let vadSilenceTimeout: Double
  public let vadSensitivity: Float   // was VADSensitivity (TYPE DOES NOT EXIST); actual is Float (SettingsManager.swift:107-111, TranscriptionPipeline.swift:32, WhisperKitPipeline.swift:116).
  public let vadEnergyGate: Bool
  public let modelUnloadPolicy: ModelUnloadPolicy
  public let recordingMode: RecordingMode
  public let languageMode: LanguageMode
  public let noiseSuppression: Bool

  public init(
    autoCopyToClipboard: Bool,
    restoreClipboardAfterPaste: Bool,
    vadAutoStop: Bool,
    vadSilenceTimeout: Double,
    vadSensitivity: Float,
    vadEnergyGate: Bool,
    modelUnloadPolicy: ModelUnloadPolicy,
    recordingMode: RecordingMode,
    languageMode: LanguageMode,
    noiseSuppression: Bool
  ) {
    self.autoCopyToClipboard = autoCopyToClipboard
    // ... assign rest
  }
}
```

**`DictationSessionConfig(from: settings)` does NOT live in Core.** Codex B-review 2026-04-18 correction: Core cannot import Services (where `SettingsManager` lives) without violating dependency direction. The convenience init that captures from `SettingsManager` lives in the App module (`Sources/EnviousWispr/App/`) alongside `AppState`, not in Core. Core owns only the value type; App owns the Settings→Config capture logic.

**Ten fields, but classification needs v1.9 re-inventory.** Codex B-review surfaced misclassifications (§8.7 below). Not all ten in the sketch are safely frozen today given current code behavior:

| Field | Codex B-review finding |
|---|---|
| `autoCopyToClipboard` | ✓ Correct — freeze safe, `FinalizationRequest` at `TranscriptionPipeline.swift:870-872` + `WhisperKitPipeline.swift:949-951`. |
| `restoreClipboardAfterPaste` | ✓ Correct. |
| `vadAutoStop`, `vadSensitivity`, `vadEnergyGate` | ✓ Correct — read at VAD-monitoring start via `VADMonitorLoop.run(...)` and `SmoothedVADConfig.fromSensitivity(...)`. |
| `vadSilenceTimeout` | ⚠️ IN-PROCESS VAD path is already frozen-at-start (`SilenceDetector` created once). BUT: XPC audio-service path is NOT frozen — `PipelineSettingsSync:173-177, :182-186, :201-214` pushes VAD changes live into `audioCapture.configureVAD(...)` during an active session. Phase B MUST either stop live `configureVAD` during session OR push snapshot into audio-service at start. UNRESOLVED — flag for founder decision. |
| `modelUnloadPolicy` | ⚠️ Partial. Per-session unload decision can freeze, but the CURRENT handler at `:229-233` also does `asrManager.cancelIdleTimer()` immediately — that's live-mutable idle-timer behavior that must NOT be dropped. Split into: frozen-session unload (in config) + live idle-timer handling (stays in live sync). |
| `recordingMode` | ⚠️ MISCLASSIFIED. Handler at `:137-138` only writes `hotkeyService.recordingMode`, doesn't touch pipelines. Putting it in `DictationSessionConfig` freezes nothing unless `HotkeyService` (`:443-449`, `:487-498`) also changes to read from the snapshot. Either (a) keep as live-mutable and drop from the config, OR (b) also refactor HotkeyService — expands scope. Recommend (a); clarify framing that recordingMode is a pre-session selection not a per-session config. |
| `languageMode` | ⚠️ CURRENTLY LIVE in code. `WhisperKitPipeline.languageMode` has a `didSet` at `:62-74` that invalidates the incremental worker mid-session; also read at `:503-505` for worker start and `:715-719` for LID. Adding to the config freezes the VALUE but not the BEHAVIOR; the didSet and live reads must be removed. Non-trivial code change beyond adding a config field. |
| `noiseSuppression` | ⚠️ MISCLASSIFIED. Not pipeline state at all. Applied immediately to shared audio engine via `audioCapture.buildEngine(noiseSuppression:)` at `:271-280`. Capture-start configuration, not a pipeline value. Either (a) drop from config and keep as live sync with session-start guard, or (b) treat as a separate "capture config" concept passed to `audioCapture.start(...)`. Recommend (a). |
| `environmentPreset` | ⚠️ Codex B-review added finding NOT in v1.6 inventory — its handler at `:188-190` writes `settings.vadSensitivity = sensitivity`. If `vadSensitivity` freezes, `environmentPreset` is effectively a UI alias for a frozen field. Cannot stay conceptually live. Either re-add to the freeze set or acknowledge "UI alias that writes a frozen setting outside a recording." |

**Resolution:** Phase B's safe-to-freeze set in v1.9 is: `autoCopyToClipboard`, `restoreClipboardAfterPaste`, `vadAutoStop`, `vadSilenceTimeout` (with XPC audio-service update), `vadSensitivity`, `vadEnergyGate`. The fields `modelUnloadPolicy`, `recordingMode`, `languageMode`, `noiseSuppression`, `environmentPreset` need founder decisions and/or additional scope. Phase B's shippable scope is the unambiguous six-field subset + XPC-path handling.

### 8.6 Gate — STOP until UX decision is recorded

Phase B does not start until the Phase B UX decision (§27.1) is recorded per §27.7 in all three places: issue #195 comment, §8.6 (this section), and §30 Changelog.

**If §27.1 answer is not recorded yet:** halt. Do not write code. Do not open a PR. Report the blocker to the founder in chat.

**When the decision is recorded, append it here:**

> UX decision (recorded YYYY-MM-DD): [chosen option from §27.1]. Rationale: [one sentence].

---

## 9. Phase C — TranscriptCoordinator owns history (new)

**Issue:** #428 · **Plan:** `docs/feature-requests/issue-428-2026-04-20-phase-c-transcript-coordinator.md` · **Status:** SHIPPED (PR #432 squash `b42e562`, 2026-04-21)
**Pattern:** Move Field + Move Method (Fowler). Not Extract Class — `TranscriptCoordinator` already exists as a class (§4.2); this phase moves ownership of state and behavior INTO it from AppState, and eliminates a reload call site. The correct taxonomy is Move Field (`transcriptStore` ownership moves from AppState to TranscriptCoordinator) plus Move Method (the `.complete`-time reload logic moves into the coordinator's append-integration path) plus a small Extract Method if `append(_:)` needs an internal helper.
**Tier:** MEDIUM · **Actual LOC delta:** +283/−39 across 9 files (see PR #432 for file-level diff).

### 9.1 Why this phase exists

REF-05: `AppState.swift:394-398` calls `transcriptCoordinator.load()` on every `.complete` state. `load()` full-directory-scans via `TranscriptStore.loadAll()`. O(n) per completed dictation. Background task, so UI not blocked, but still wasteful I/O and completion-path noise.

Ownership-wise, transcript history belongs to `TranscriptCoordinator`, not `AppState`. AppState should not be deciding "refresh history now" — the coordinator owns that decision and exposes `append(transcript:)` for the heart path to push into.

### 9.2 Design summary

Add `append(_:)` to `TranscriptCoordinator`. Heart path calls it on `.complete`. `load()` is reserved for startup, repair, manual refresh.

**Adversarial-verified facts (2026-04-18 Codex plan review):**
- `Transcript` is `public struct Transcript: Codable, Identifiable, Sendable` (`Sources/EnviousWisprCore/Transcript.swift:43`).
- `TranscriptStore` is `@MainActor public final class` (`Sources/EnviousWisprStorage/TranscriptStore.swift:5-6`).
- **`TranscriptFinalizer.swift:126` ALREADY calls `try save(transcript)` before AppState observes `.complete`.** This is the load-bearing correction. Phase C's `append(_:)` must NOT save-through — that would double-persist.

**CORRECT design (v1.6 — supersedes v1.3-v1.5):** `TranscriptCoordinator.append(_:)` is an IN-MEMORY ONLY cache update. Persistence stays with `TranscriptFinalizer`. Phase C's work is:

1. AppState's `.complete` branch stops calling `transcriptCoordinator.load()` (full-disk scan).
2. The finalizer already saved to disk; after it saves, something tells the coordinator the new transcript exists.
3. The coordinator's `append(_:)` inserts into the in-memory array so the UI list updates without re-scanning disk.

Two mechanisms for the finalizer→coordinator notification (pick one in Phase C substep 2):

**Option A — finalizer returns the saved `Transcript` and the pipeline's `.complete` carries it.** AppState's `.complete` handler reads the finalized transcript from pipeline state and calls `coordinator.append(transcript)` instead of `coordinator.load()`.

**Option B — finalizer gains a `didSave:` callback that the coordinator subscribes to.** Decouples coordinator from AppState entirely for history updates.

Recommendation: Option A. Smaller blast radius; finalizer already has the transcript; AppState already has the access to call coordinator methods.

```swift
// TranscriptCoordinator.swift — @MainActor
// append() is IN-MEMORY ONLY. TranscriptFinalizer owns persistence.
// Precondition: transcript has already been saved to disk by the finalizer.
func append(_ transcript: Transcript) {
  transcripts.insert(transcript, at: 0)
}
```

```swift
// AppState state-change handler (Phase A+C combined)
if newState == .complete, let t = self.pipeline.currentTranscript {
  self.transcriptCoordinator.append(t)  // in-memory only
  TelemetryService.shared.reportDictationCompleted(transcript: t, inputMode: ...)
}
```

**What this does not change:** `TranscriptFinalizer` continues to own persistence. `TranscriptStore.save(_:)` still runs where it does today (inside the finalizer on MainActor). No double-save.

**Note on TranscriptPolishService:160-168 (missed by bible pre-v1.6):** The polish-enhancement path calls `transcriptStore.loadAll()` inside a deletion-existence check. Another O(n) scan. Phase C can opportunistically fix this by switching the existence check to `transcriptStore.exists(id:)` (new narrow API) OR deferring to a post-epic issue. Recommendation: defer. Phase C stays scoped to the completion path; TranscriptPolishService is a separate heart-adjacent component.

Phase C also audits every current `TranscriptCoordinator.load()` call site and every `transcriptStore.loadAll()` call to ensure only startup/repair/manual-refresh paths keep the full scan.

### 9.3 Substeps (ordered)

**Codex C-review 2026-04-18 correction:** v1.6 §9.2 locked in memory-only `append(_:)` (finalizer owns persistence), but prior substeps 2 and 4 still instructed write-through via `store.save`. That reintroduces the double-save bug. Corrected below.

1. **Current-state audit.** Grep every `transcriptCoordinator.load`, `store.loadAll`, and `transcripts = ` assignment. Build inventory. Classify each as: startup, repair, manual-refresh, or leaked-onto-heart-path. The leaked ones are what Phase C eliminates. Verified 2026-04-18: only `HistoryContentView.swift:30` (`.task { load }` on history-view appear) and the two AppState `.complete` handlers at `:394` and `:451` call `TranscriptCoordinator.load()`.
2. **Lock the persistence boundary (no alternative options).** `append(_:)` is in-memory only; `TranscriptFinalizer` owns disk persistence. Do NOT implement write-through. Do NOT call `store.save(_:)` inside `append(_:)`. Any substep or reviewer suggestion to "let the coordinator own disk I/O too" is wrong and reintroduces the double-save bug.
3. Characterization test: current behavior captures the transcript in history after a dictation. Post-refactor, same behavior visible — but test asserts NO `loadAll()` called on `.complete`.
4. Add `append(_:)` to `TranscriptCoordinator`. Body: single line, `transcripts.insert(transcript, at: 0)`. No disk I/O.
5. Replace both `.complete` branches (`AppState.swift:394` for Parakeet, `:451` for WhisperKit): instead of `transcriptCoordinator.load()`, call `transcriptCoordinator.append(t)` where `t = self.pipeline.currentTranscript` (or `whisperKitPipeline.currentTranscript`). Verified 2026-04-18: `.currentTranscript` is populated BEFORE the `.complete` state is emitted in both pipelines (`TranscriptionPipeline.swift:940`, `WhisperKitPipeline.swift:1016`), so reading it at `.complete` is correct timing. Telemetry emission stays unchanged.
6. **`append` vs in-flight `load` race (Codex C-review finding).** `TranscriptCoordinator.load()` currently does `transcripts = try await store.loadAll()` — wholesale overwrite. If a slow startup `load()` from `HistoryContentView.task` finishes AFTER an `append(t)` from a completed dictation, the load overwrites the in-memory array with an older snapshot (missing the new row) until the next reload. Fix options: (a) cancel in-flight `loadTask` when `append(_:)` is called, OR (b) merge loaded results by ID rather than wholesale replace. Recommendation: (b) — defensive. Implement `load()` as: load full set from disk; union with current in-memory transcripts by ID; preserve any in-memory rows not yet on disk; then assign. Disk stays authoritative for transcripts it has, in-memory covers the gap.
7. Migrate view consumers. Expand audit to FOUR greps (Codex caught `activeTranscript`):
   - `grep -rn "appState\.transcriptStore\b" Sources/`
   - `grep -rn "appState\.transcriptCoordinator\b" Sources/`
   - `grep -rn "\.transcripts\b" Sources/EnviousWispr/Views/`
   - `grep -rn "appState\.activeTranscript\b" Sources/` ← NEW. Right-hand detail pane (`HistoryContentView.swift:18`) is driven indirectly via `activeTranscript` which resolves through `AppState.swift:700`. Phase C changes where the newest transcript lives in memory; missing this audit breaks detail-pane freshness.
   Every hit is a consumer to verify still works post-migration.
8. Remove `transcriptStore` from `AppState`'s direct property list — `TranscriptCoordinator` owns the store. Verified 2026-04-18: only one production `TranscriptStore()` construction exists in the codebase (`AppState.swift:21`). Nothing else constructs a store directly. `TranscriptCoordinator`, both pipelines, and `TranscriptPolishService` must all continue sharing the SAME store instance — do not accidentally create a second store.
9. Unit test: append-then-read returns the new transcript without disk I/O on the read. Unit test: startup still loads full history. Unit test: append-during-in-flight-load merges correctly without losing the new row.
10. **Seeded-directory perf test (note infrastructure prerequisite).** Proposed: place 1000 stub transcript JSONs in a temp directory; complete a dictation; measure time to `.complete` visible. Codex C-review caveat: `TranscriptStore.swift:9` hardwires `AppConstants.appSupportURL` — the store is NOT directory-injectable today. The test as-proposed requires a prerequisite: add a directory-injectable init to `TranscriptStore` (`public init(directory: URL)`) before running the perf test. If that prereq is deferred, the perf test becomes a manual scenario (hand-populate real `~/Library/Application Support/...` path, measure).
11. Architecture Closeout; Periphery scan.

### 9.4 DoD

- [ ] `grep -n "transcriptCoordinator.load()" Sources/` returns zero hits on heart-path completion sites.
- [ ] `TranscriptCoordinator.append(_:)` public/internal API exists and is unit-tested.
- [ ] Live smoke: dictation appears in history view within one frame of `.complete`.
- [ ] Seeded directory of 1000 transcripts: completion-to-visible latency improved or bounded.
- [ ] `transcriptStore` property removed from AppState.
- [ ] Architecture Closeout documents ownership move.
- [ ] Codex clean.

### 9.5 Rollback

`git revert`. Caveat: if this phase is bundled with Phase D and both use a shared AppState refactor commit, rollback affects both. Keep phases as separate commits within the PR for clean revert.

### 9.6 Interaction with startup

Startup flow unchanged: `init` triggers `load()` once. Repair flows (integrity check) unchanged. Manual refresh via Settings/debug menu unchanged. Only the completion-path reload goes away.

---

## 10. Phase D — CustomWordsPropagator replaces 5-way fanout (new)

**Issue:** #196 (expanded) · **Plan:** inline below · **Status:** PLANNED (gated on §27.3)
**Pattern:** Extract Class + Introduce Publish-Subscribe Registry (Fowler). Codex D-review 2026-04-18 correction: **this is straight Extract Class with cutover, NOT Parallel Change, because `CustomWordsCoordinator` has a single-slot `onWordsChanged` callback** (`Sources/EnviousWispr/App/CustomWordsCoordinator.swift:14`), not a multi-subscriber API. A true Parallel Change would require BOTH old fanout AND new propagator to coexist during the expand step — possible only if the AppState closure temporarily calls both during one commit. Recommend single-commit cutover for simplicity; documented here for honesty. · **Tier:** MEDIUM · **Est. LOC delta:** +180 total net

### 10.1 Why this phase exists

REF-01 worst violation. `AppState.swift:316-321` fans out every custom-words change to five consumers manually. Every new consumer requires a manual line here. Classic god-object pattern because `AppState` must know the entire consumer list.

### 10.2 Design summary

New `@MainActor final class CustomWordsPropagator` replaces the manual fanout with a subscription registry. Consumers conform to `protocol CustomWordsConsumer` and register. Propagator pushes updates.

**Verified 2026-04-18:** both current consumers (`WordCorrectionStep`, `LLMPolishStep`) are `@MainActor public final class`. The `@MainActor` requirement on `CustomWordsConsumer` does not force new actor isolation on anyone.

```swift
// CustomWordsConsumer.swift (Core)
@MainActor
public protocol CustomWordsConsumer: AnyObject {
  var customWords: [CustomWord] { get set }
}

// CustomWordsPropagator.swift (App)
@MainActor
final class CustomWordsPropagator {
  // WeakBox must be a class: Swift disallows `weak` in structs (value types cannot hold weak refs).
  private final class WeakBox {
    weak var value: (any CustomWordsConsumer)?
    init(_ value: any CustomWordsConsumer) { self.value = value }
  }
  private var consumers: [WeakBox] = []
  private(set) var words: [CustomWord] = []

  // Idempotent register: if the same object is already registered, do not add a second WeakBox.
  // Codex D-review 2026-04-18: blind-append was an API footgun — two register() calls on the
  // same instance produce duplicate update() writes on every broadcast.
  func register(_ consumer: any CustomWordsConsumer) {
    // Prune dead boxes opportunistically.
    consumers.removeAll { $0.value == nil }
    // Dedupe by object identity.
    let alreadyRegistered = consumers.contains { box in
      guard let existing = box.value else { return false }
      return ObjectIdentifier(existing) == ObjectIdentifier(consumer)
    }
    guard !alreadyRegistered else { return }
    consumers.append(WeakBox(consumer))
    consumer.customWords = words
  }

  func update(_ words: [CustomWord]) {
    self.words = words
    consumers.removeAll { $0.value == nil }  // prune deallocated
    for box in consumers {
      box.value?.customWords = words
    }
  }
}
```

`CustomWordsCoordinator` (current publisher, `Sources/EnviousWispr/App/CustomWordsCoordinator.swift`, 51 lines) keeps its `onWordsChanged` callback. The propagator subscribes to that callback. AppState stops wiring the 5-way fanout. This is the Parallel Change pattern's *expand* step.

**ASCII sequence (before vs after):**

```
BEFORE:
  [Settings UI] → CustomWordsCoordinator.onWordsChanged
                     │
                     ▼
                 AppState (knows all 5 consumers)
                     │
         ┌──────┬────┴────┬─────────┬──────────┐
         ▼      ▼         ▼         ▼          ▼
     pipeline  pipeline  whisperKit  whisperKit  polishService
     .wordCorr .llmPolish .wordCorr   .llmPolish  .llmPolishStep

AFTER:
  [Settings UI] → CustomWordsCoordinator.onWordsChanged
                     │
                     ▼
                 CustomWordsPropagator.update(words)
                     │
                     ▼ (iterates weak-ref subscriber list)
         ┌──────┬────┴────┬─────────┬──────────┐
         ▼      ▼         ▼         ▼          ▼
     [any conforming CustomWordsConsumer, registered at init]
```

AppState never sees the consumer list. Adding a sixth consumer is one `register()` call at construction.

### 10.3 Substeps (ordered — parallel-change discipline)

1. **Expand.** Add `CustomWordsConsumer` protocol in Core. Add `CustomWordsPropagator` in App.
2. Extend each of the five consumers to conform to `CustomWordsConsumer`. (No behavior change; they already have `customWords: [CustomWord]` property.)
3. Wire the propagator: AppState creates `customWordsPropagator`, registers all five consumers with it, subscribes the propagator to `customWordsCoordinator.onWordsChanged`.
3a. **CRITICAL — seed the propagator BEFORE removing startup setter lines (Codex D-review 2026-04-18).** `CustomWordsPropagator` starts with `words = []`. Current startup seeds via `settingsSync.applyInitialSettings(settings, customWords: customWordsCoordinator.customWords)` at `AppState.swift:155` which triggers the five setter lines in `PipelineSettingsSync.applyInitialSettings` at `:52-76`. If Phase D removes those five setter lines WITHOUT first priming the propagator with `customWordsCoordinator.customWords`, existing custom words disappear from all consumers until the NEXT user mutation. Substep order must be: (a) create propagator with initial words from coordinator, (b) register all five consumers (each receives initial words via `register()`'s initial-sync), (c) THEN remove startup setter lines from PipelineSettingsSync. Not reversible order.
4. Ship this first. Behavior unchanged; fanout now happens via propagator. Verify via smoke test.
5. **Contract.** Remove `customWordsCoordinator.onWordsChanged` closure from AppState's init. Propagator subscribes directly. Now AppState has zero direct knowledge of the consumer list.
6. **Contract.** Remove any residual direct `consumer.customWords = ...` calls in AppState AND in `PipelineSettingsSync.applyInitialSettings` (the five setter lines at `:67-68, :331-332, :350`).
7. Unit tests per §10.10 (corrected scenarios below, Codex D-review).
8. Integration test: add a new sixth consumer, register it, confirm immediate delivery without touching AppState.
9. Architecture Closeout; Periphery scan.

### 10.4 DoD

- [ ] Zero direct `.customWords = words` assignments in `AppState.swift` (grep confirms).
- [ ] `CustomWordsPropagator` + `CustomWordsConsumer` protocol committed.
- [ ] All five current consumers conform and register.
- [ ] Unit tests cover register, update, weak-deallocation pruning.
- [ ] Adding a hypothetical sixth consumer requires only `register()` (proven by test stub).
- [ ] Live smoke: add a custom word via Settings, confirm both pipelines and polish service recognize it immediately.
- [ ] Architecture Closeout + Codex + Periphery clean.

### 10.5 Rollback

Two-phase rollback if needed. If only the Contract step (substep 5-6) needs to revert, `git revert` that commit; AppState regains its explicit fanout call. If the whole phase needs to revert, `git revert` the expand commit; consumers drop their `CustomWordsConsumer` conformance.

### 10.6 Event-model decision

**Gate — STOP until §27.3 decision is recorded.** Phase D does not start until the founder has confirmed the event model (closure-based subscription per recommendation, or `@Observable`). Record the decision in §30 Changelog before writing code. The code sketch in §10.2 assumes closure-based subscription; if `@Observable` is chosen, §10.2 must be revised before substep 1.

Recommendation (for founder reference): closure-based subscription (more explicit, cleaner unregister, weak refs). `@Observable` fits SwiftUI views, not cross-service registries. Default ships as closure-based unless overridden.

### 10.7 Interaction with intentional-duplication rule

Both pipelines keep independent `customWords` properties. The propagator writes to each independently. Unification of the pipelines is NOT part of this phase (§2.3).

### 10.8 Current consumer call-site inventory (grep-anchored 2026-04-18)

Council R3 flagged that "five consumers" was stated without evidence. Enumerated below. Note: fanout happens at TEN sites across two files, not five — both AppState AND PipelineSettingsSync must be cleaned.

| # | File | Line | Setter target | Path |
|---|---|---|---|---|
| 1 | `Sources/EnviousWispr/App/AppState.swift` | 318 | `pipeline.wordCorrection.customWords` | REF-01 worst violation, inside `customWordsCoordinator.onWordsChanged` closure |
| 2 | `Sources/EnviousWispr/App/AppState.swift` | 319 | `pipeline.llmPolish.customWords` | same closure |
| 3 | `Sources/EnviousWispr/App/AppState.swift` | 320 | `whisperKitPipeline.wordCorrection.customWords` | same closure |
| 4 | `Sources/EnviousWispr/App/AppState.swift` | 321 | `whisperKitPipeline.llmPolish.customWords` | same closure |
| 5 | `Sources/EnviousWispr/App/AppState.swift` | 322 | `polishService.llmPolishStep.customWords` | same closure |
| 6 | `Sources/EnviousWispr/App/PipelineSettingsSync.swift` | 67 | `pipeline.wordCorrection.customWords` | `applyInitialSettings` — startup path |
| 7 | `Sources/EnviousWispr/App/PipelineSettingsSync.swift` | 68 | `pipeline.llmPolish.customWords` | same |
| 8 | `Sources/EnviousWispr/App/PipelineSettingsSync.swift` | 331 | `whisperKitPipeline.wordCorrection.customWords` | WhisperKit init path |
| 9 | `Sources/EnviousWispr/App/PipelineSettingsSync.swift` | 332 | `whisperKitPipeline.llmPolish.customWords` | WhisperKit init path |
| 10 | `Sources/EnviousWispr/App/PipelineSettingsSync.swift` | 350 | `polishService.llmPolishStep.customWords` | polish-service init path |

**Consumer types (grep-verified as `@MainActor public final class`):**
- `WordCorrectionStep` — `Sources/EnviousWisprPipeline/WordCorrectionStep.swift` (§4.11 verified)
- `LLMPolishStep` — `Sources/EnviousWisprPipeline/LLMPolishStep.swift` (§4.11 verified)

**Plus read sites (not setters; not touched by Phase D):**
- `Sources/EnviousWisprLLM/Prompting/DefaultPromptPlanner.swift:108` — reads `input.customWords`.
- `Sources/EnviousWisprLLM/Prompting/OpenAIPromptBuilder.swift:107` — reads via `CustomVocabularyFormatter.render(input.customWords)`.
- `Sources/EnviousWisprLLM/Prompting/GeminiPromptBuilder.swift:34` — same.
- `Sources/EnviousWisprLLM/Prompting/GemmaPromptBuilder.swift:68` — same.
- `Sources/EnviousWispr/Views/Settings/WordFixSettingsView.swift:32,60,72,129` — reads via `appState.customWordsCoordinator.customWords`. These do NOT need Phase D wiring; they read the coordinator directly.
- `Sources/EnviousWispr/App/AppDelegate.swift:99` — reads `appState.customWordsCoordinator.customWords.count` for telemetry. Same — reads the coordinator directly.

### 10.9 Phase D concrete deliverables

Ship the propagator + register all five setter targets (the pipeline+polish instances, not the 10 setter lines — five targets get updated via one `register()` each). Delete the 5 lines in AppState (318-322) AND the 5 lines in PipelineSettingsSync (67-68, 331-332, 350). Net: −10 setter lines across two files, +~80 lines for the propagator + conformance.

### 10.10 Adversarial edge cases — lifecycle-aware tests required

Weak-ref subscriber lists have silent-failure modes. Codex D-review 2026-04-18 corrected these scenarios — my v1.6 "backend switch recreates consumer" assumption was WRONG. `pipeline`, `whisperKitPipeline`, `polishService` are all `let` properties on `AppState.swift:39-47`; `asrManager.switchBackend(to:)` does NOT tear down and recreate the pipelines. Corrected scenarios below.

Phase D unit tests MUST cover:

1. **Dead weak-ref pruning (short-lived fake consumer scenario).** Register a short-lived fake `CustomWordsConsumer` test instance; drop its strong ref; call `propagator.update(newWords)`; assert the dead box is pruned from the consumers list AND no crash / no write to a dangling reference. Test uses an ephemeral fake, not real pipeline services (which live for app lifetime).
2. **Initial-sync-on-register.** Create propagator with initial `words = [A, B]`. Register a consumer. Assert the consumer's `customWords` is immediately set to `[A, B]` by `register()` (initial-sync path). Register a second consumer AFTER an `update([C])` call; assert it sees `[C]`, not `[]` or `[A, B]`.
3. **Duplicate-register idempotence.** Register the same consumer instance twice. Call `update([X])`. Assert the consumer's `customWords` is set once to `[X]`, not twice — verified by having the consumer's setter count its invocations. Consumers list should contain exactly one box per distinct object identity.
4. **Registered-but-silent mode.** If `CustomWordsConsumer` has a `customWords` setter with an internal guard (e.g. `guard enabled else { return }`), the propagator writes but the step silently ignored. That's legitimate. Pin behavior at the setter-level (did setter fire?), not at a later downstream effect.
5. **Re-entrancy defense.** Though no current consumer re-enters on setter (`WordCorrectionStep.customWords` and `LLMPolishStep.customWords` are plain stored properties with no observers), the snapshot-before-iterate pattern is defensive against future consumers. Test: register a consumer whose setter calls `propagator.update(...)` reentrantly; assert no crash and predictable final state.

Pin all five as characterization tests under `Tests/EnviousWisprTests/App/CustomWordsPropagatorTests.swift`.

### 10.11 Intentional-duplication policy under simultaneous active pipelines

Both pipelines can be active simultaneously during a backend switch mid-recording (the #285 telemetry tiebreaker handles overlap). The propagator broadcasts to all five consumers regardless of which pipeline is "active." Confirmed correct behavior: each consumer owns its own `customWords` state; both backends always have current words. No special-casing required.

If a future design adds "active pipeline only" custom-words policy, that is a semantic change outside this phase.

---

## 11. Phase E — Architecture regression tests (new)

**Issue:** to open · **Plan:** inline below · **Status:** PLANNED
**Pattern:** Self-testing code (Feathers) / Architecture fitness functions (Building Evolutionary Architectures) · **Tier:** SMALL · **Est. LOC delta:** ~65 (mostly test code)

### 11.1 Why this phase exists

Without guardrails, Phases A/C/D will re-accrete. A future session adding "just one more coordinator to AppState for convenience" is the next god-object. Test-enforced limits prevent silent regression.

### 11.2 Design summary — three fitness functions

Lightweight Swift-Testing suite that fails CI if any of the following regress. Council review flagged brittle-line-count as weak; the property-count and public-surface checks below are the architectural teeth of the phase.

1. **AppState property-count ceiling.** Number of direct concrete-type stored properties on `AppState` exceeds the target. Verified 2026-04-18 baseline: 15 (§4.13). Target after Phases A+C+D+F: ≤ 12. This is the *architectural* signal, not the line count. Target revised from ≤ 8 in v1.2 because the §4.13 disposition matrix made the original target unachievable without unbundling stable concerns. A ≤ 10 target is reachable with post-epic BenchmarkCoordinator + TelemetryObservationCoordinator extractions (not in this epic).
2. **AppState line count ceiling.** Soft backstop to catch unexpected bloat. Pick ceiling = measured-after-C+D+F + 10%, rounded. Expectation: ~500-550. Rationale: line count alone is gameable (add comments, reformat), but serves as a cheap early-warning tripwire. Paired with the property-count check, not standalone.
3. **Cross-module `public` guard on non-App modules.** Implements audit meta-recommendation #1. Grep-based test that fails if any new `public` symbol appears in a non-App module that was not in a snapshot baseline — OR that contains a `TODO: ... narrow` / `TODO: ... Phase N` comment on a `public` declaration. Prevents another `WhisperKitBackend.makeDecodeOptions`-style confessional-TODO widening.

Optional fourth (stretch, not required for Phase E close):
4. **Dependency direction** via `scripts/check-dependency-direction.sh`. Verified 2026-04-18: the script existed historically under the brain system, was deleted when that system was deprecated, and has not been replaced. `.git/hooks/pre-commit` is a no-op stub confirming the deletion. Phase E RE-INTRODUCES automated dep-direction enforcement. See §11.3 substep 6.

```swift
// Tests/EnviousWisprTests/Architecture/AppStateSizeTests.swift
import Testing
import Foundation

@Suite struct AppStateArchitectureTests {

  /// Resolve the path to AppState.swift robustly. `#filePath` points to THIS test file;
  /// walk up to package root and join the known path. Works under `swift test` and `xcodebuild test`.
  private static func appStateURL() -> URL {
    let testFile = URL(fileURLWithPath: #filePath)
    // Tests/EnviousWisprTests/Architecture/AppStateSizeTests.swift → walk up 3 levels to package root.
    let packageRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return packageRoot
      .appendingPathComponent("Sources/EnviousWispr/App/AppState.swift")
  }

  /// Count direct owned concrete-type declarations at file scope on AppState.
  /// Matches BOTH zero-arg and arg-bearing initializers at indent depth 2.
  /// Examples matched: `  let foo = Foo()`, `  let foo = Foo(arg: bar)`, `  let foo: Foo = .init(arg: bar)`.
  /// Does NOT match interface-typed properties (`let foo: any FooInterface`) — those are injected, not owned.
  @Test func appStateDirectConcreteDependencyCount() throws {
    let url = Self.appStateURL()
    let src = try String(contentsOf: url)
    // Pattern intent: file-scope `let IDENT = TypeName(`...`)` where TypeName is capitalized.
    // Captures `let foo = Foo()` and `let foo = Foo(arg: bar)` and `let foo: Foo = Foo(...)`.
    // Does NOT capture `let foo: any Interface` (injected, not owned).
    let pattern = #"^  let [a-zA-Z_][a-zA-Z0-9_]*(?:\s*:\s*[A-Z][a-zA-Z0-9_<>, ]*)?\s*=\s*[A-Z][a-zA-Z0-9_]*\("#
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let range = NSRange(src.startIndex..., in: src)
    let count = regex.numberOfMatches(in: src, range: range)
    #expect(count <= 12, "AppState has \(count) direct owned concrete dependencies; epic target is ≤ 12 after Phases A+C+D+F (§4.13 matrix).")
  }

  @Test func appStateLineCount() throws {
    let url = Self.appStateURL()
    let lines = try String(contentsOf: url).components(separatedBy: .newlines).count
    #expect(lines <= 550, "AppState has \(lines) lines; decomposition ceiling is 550.")
  }
}

// Tests/EnviousWisprTests/Architecture/CrossModulePublicGuardTests.swift
@Suite struct CrossModulePublicGuardTests {
  /// Fail on any `public` declaration in a non-App source module whose preceding comment block
  /// contains confessional-TODO markers ("narrow", "Phase 2", "temporary", "cross-module").
  /// Implements audit meta-recommendation #1.
  @Test func noConfessionalPublicTODOs() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources")
    let nonAppModules = ["EnviousWisprASR", "EnviousWisprAudio", "EnviousWisprCore", "EnviousWisprLLM",
                         "EnviousWisprPipeline", "EnviousWisprPostProcessing", "EnviousWisprServices",
                         "EnviousWisprStorage"]
    var offenders: [String] = []
    for module in nonAppModules {
      let moduleURL = sourcesRoot.appendingPathComponent(module)
      let enumerator = FileManager.default.enumerator(at: moduleURL, includingPropertiesForKeys: nil)
      while let obj = enumerator?.nextObject() as? URL where obj.pathExtension == "swift" {
        let src = try String(contentsOf: obj)
        // Find `public ` declarations preceded by TODO comments with narrow/Phase/temporary/cross-module.
        let pattern = #"(?m)^\s*//[^\n]*(?:narrow|Phase \d|temporary|cross-module)[^\n]*\n(?:\s*//[^\n]*\n)*\s*public\s+(?:func|var|let|class|struct|enum|actor)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(src.startIndex..., in: src)
        if regex.firstMatch(in: src, range: range) != nil {
          offenders.append(obj.lastPathComponent)
        }
      }
    }
    #expect(offenders.isEmpty, "Confessional-TODO public declarations found: \(offenders.joined(separator: ", ")). Audit meta-rec #1 forbids temporary public widening with narrow-later promises.")
  }
}
```

**Regex design choices:**
- The property-count regex matches both `let foo = Foo()` AND `let foo = Foo(arg: ...)`. Prior v1.3 pattern missed arg-bearing constructors. Fixed in v1.4.
- Indent-depth-2 anchor (`^  let`) restricts to file-scope declarations on a class declared at file scope. Nested types with deeper indentation are correctly excluded.
- Interface-typed properties (`audioCapture: any AudioCaptureInterface`) are excluded — they are injected, not owned.
- Path resolution uses `#filePath` + three-level directory walk. Robust across `swift test` and `xcodebuild test` CWDs.
- The cross-module guard excludes `EnviousWispr` (the App module) because AppState and friends legitimately have `public`-for-view-consumption surface.

**Baseline calibration process:**
1. After Phase A ships: measure both metrics; record in PR body.
2. After Phase C ships: re-measure.
3. After Phase D ships: re-measure.
4. After Phase F ships: set final ceiling to measured + 10% for line count; concrete-dep ceiling set to measured exactly.
5. Commit Phase E with ceilings locked.

### 11.3 Substeps (ordered)

1. After Phase A lands, measure baselines (line count, concrete-dep count). Expect ~760 lines, 11 concrete deps.
2. After Phases C+D land, measure again. Expect ~500-550 lines, ≤ 8 concrete deps.
3. Pick ceilings = measured-after-C+D + 10% for line count; exact target for concrete-dep count.
4. Write `Tests/EnviousWisprTests/Architecture/AppStateArchitectureTests.swift` with property-count (strict) and line-count (advisory) tests per §11.2.
5. Write `Tests/EnviousWisprTests/Architecture/CrossModulePublicGuardTests.swift` for the cross-module public-TODO guard.
6. **Re-introduce `scripts/check-dependency-direction.sh`.** Historical note: the script existed under the now-deprecated brain system and was deleted when that system was retired. `.git/hooks/pre-commit` is currently a no-op stub with the comment `# Pre-commit hook — architecture enforcement checks removed (brain system deprecated)`. Phase E re-introduces the enforcement. Implement it:
   - Parse `Package.swift` for each target's `dependencies`.
   - Assert the dependency graph obeys the layering: App → Pipeline → {LLM, ASR, Audio, Services, PostProcessing, Storage} → Core.
   - No upward edges: Core cannot import any feature; features cannot import Pipeline; Pipeline cannot import App.
   - Exit non-zero with offending edges listed.
   - Wire into `.github/workflows/pr-check.yml` as a blocking step.
   - Wire into `.git/hooks/pre-commit` if a project-level pre-commit hook convention exists (check `.husky/` — verified absent 2026-04-18; use `.git/hooks/pre-commit` directly or document as GitHub-only).
7. Document the property-count ceiling + concrete-dep target in `.claude/rules/architecture-rules.md` (under Anti-God-Object).

### 11.4 DoD

- [ ] AppState property-count test in CI, passes at baseline (≤ 8 after Phases C+D).
- [ ] AppState line-count test in CI, passes at baseline (≤ 550).
- [ ] Cross-module public-TODO guard test in CI, passes at baseline.
- [ ] `scripts/check-dependency-direction.sh` CREATED (it did not exist) and wired in CI workflow.
- [ ] Ceilings + targets documented in `.claude/rules/architecture-rules.md`.
- [ ] Intentional test-failure scenarios confirmed: (a) add a 13th concrete dep to AppState, property-count test fails; (b) add a new `public` with a `TODO: narrow` comment in ASR module, public-guard test fails; rollback and confirm green.
- [ ] Audit meta-recommendation #1 (CI guard on cross-module public exposure) considered RESOLVED by this phase.

### 11.5 Rollback

`git revert`. Future regressions go unchecked. Phase E is additive; rollback has no functional impact.

---

## 12. Phase R2 — WhisperKitBackend adapter

**Issue:** #360 · **Status:** PLANNED
**Pattern:** Branch by Abstraction + Extract Interface (Fowler) · **Tier:** MEDIUM · **Est. LOC delta:** ~120

### 12.1 Why this phase exists

REF-02. `WhisperKitBackend` exposes `makeDecodeOptions`, `whisperKitTokenizer`, and the `WhisperKitIncrementalWorker` constructor as `public` solely so `WhisperKitPipeline` (in `EnviousWisprPipeline` module) can reach across the package boundary. A TODO comment in the source confesses this is temporary. Three reaches, one call site (`WhisperKitPipeline.swift:1150-1156`), cohesive into a single tail-decode operation.

### 12.2 Gate — STOP until §27.4 approach is chosen

R2 does not start until the founder chooses Approach A (adapter protocol) or Approach B (relocate worker). Bible recommendation: Approach A. If §27.4 not answered, halt.

### 12.2.1 Two approaches — recommend A for this epic

**Approach A — Adapter protocol in ASR, dependency-inject into Pipeline.**

Adversarial-verified 2026-04-18 (Codex plan review): the naive `Sendable` bridge protocol is a Swift 6 compile error. `WhisperKit`, `DecodingOptions`, and the tokenizer types are NOT `Sendable`. Forcing the protocol `Sendable` forces downstream types Sendable, which they are not, and `@unchecked Sendable` is a code smell here because the types carry real unsynchronized state.

Correct shape: the bridge protocol is `@MainActor`-isolated (since `WhisperKitBackend` is already actor-qualified in practice through its ownership graph) and returns non-Sendable types that callers are expected to handle on MainActor. The tail-decode call-site at `WhisperKitPipeline.swift:1155` is already MainActor; this matches reality.

```swift
// Sources/EnviousWisprASR/WhisperKitDecodeBridge.swift
// No Sendable requirement — WhisperKit / DecodingOptions / tokenizer are not Sendable.
// The bridge is consumed on MainActor in WhisperKitPipeline per the current call pattern.
@MainActor
public protocol WhisperKitDecodeBridge: AnyObject {
  func makeIncrementalWorker(
    transcriptionOptions: TranscriptionOptions,
    whisperKit: WhisperKit
  ) async -> WhisperKitIncrementalWorker
}
```

`WhisperKitBackend` conforms internally. The bridge method owns the construction of `WhisperKitIncrementalWorker` INSIDE the ASR module, which means the worker's constructor can ALSO narrow (not `public`). `WhisperKitPipeline` calls one method; the worker never crosses the module boundary visibly.

**Fourth cross-module reach (NEW to v1.6 — missed by prior scope):** `WhisperKitPipeline.swift:714` uses `await backend.whisperKitInstance` for language detection (feeds the WhisperKit handle to `LanguageDetector.detect(whisperKit:)`). `WhisperKitBackend.swift:33` currently declares `public var whisperKitInstance: WhisperKit? { whisperKit }`. This is a FOURTH leak R2 must also fix.

Fix: add a second bridge method `makeLanguageDetectionContext() async -> WhisperKitLIDContext` OR narrow `whisperKitInstance` to `internal` and route language detection through the bridge the same way. Recommendation: second bridge method (keeps the language-detector call shape intact; LID is already an actor wrapping WhisperKit).

Downside: protocol is slightly wider (two methods). Upside: compile-enforced narrow surface, testable, and no public types leak for pipeline-convenience reach.

**Approach B — Relocate tail-decode logic into ASR module.**

Move the tail-decode construction (currently at `WhisperKitPipeline.swift:1150-1156`) into a new `WhisperKitTailDecoder` type in `EnviousWisprASR`. `WhisperKitPipeline` calls one method on that type. No cross-module reach into backend internals.

Downside: moves pipeline-like orchestration into ASR, blurring the module boundary intent. Upside: eliminates the abstraction, compiler does the work.

**Recommendation (see §27.4):** Approach A. Lower blast radius. Preserves module-boundary intent.

### 12.3 Substeps (Approach A)

1. Grep every `WhisperKitBackend.` consumer in `EnviousWisprPipeline`. Adversarial-verified 2026-04-18 (Codex plan review): **FOUR reaches**, not three (v1.3-v1.5 scope was undercounted):
   - `WhisperKitPipeline.swift:1150` — `backend.makeDecodeOptions(from:sampleCount:)`
   - `WhisperKitPipeline.swift:1154` — `backend.whisperKitTokenizer`
   - `WhisperKitPipeline.swift:1155` — `WhisperKitIncrementalWorker(...)` constructor
   - `WhisperKitPipeline.swift:714` — `backend.whisperKitInstance` for language detection (`WhisperKitBackend.swift:33` declares `public var whisperKitInstance: WhisperKit? { whisperKit }`)

   **Codex R2-review 2026-04-18 discovery — `tokenizer` is DEAD CODE.** `WhisperKitIncrementalWorker.swift:26` stores a `tokenizer` property, `:41` initializes it from the init param, **nothing reads it anywhere in the file**. R2's scope can DELETE the tokenizer param (and the line 1154 reach) entirely — not narrow. Delete-rather-than-narrow is cleaner and reduces what the bridge protocol must carry. Add as substep 1a.

1a. **Delete the dead `tokenizer` parameter** from `WhisperKitIncrementalWorker.init` and the corresponding call site at `WhisperKitPipeline.swift:1154-1156`. Verify: `grep -rn "tokenizer" Sources/EnviousWisprASR/WhisperKitIncrementalWorker.swift` after deletion should return zero hits inside that file. Genuine cross-module reach count drops from four to three.

2. Design `WhisperKitDecodeBridge` protocol with minimum surface. **Not `Sendable`** — WhisperKit, DecodingOptions are not Sendable and forcing it fails Swift 6 compile. Use `@MainActor AnyObject` protocol.

   **Codex R2-review 2026-04-18 caveats on the MainActor choice:**
   - The MainActor-only protocol is compatible with the incremental-worker setup call path (pipeline is MainActor-adjacent at that site).
   - **BUT line 714 hands the non-Sendable `WhisperKit` handle to `LanguageDetector.detect(...)` — an ACTOR, not MainActor.** This is the same underlying unsafe cross-actor hop the current code performs (`nonisolated(unsafe) let kitForLID = await backend.whisperKitInstance`). The MainActor bridge narrows access control; it does NOT solve the isolation impedance mismatch. Phase R2 accepts this — the pre-existing pattern is not changed by the narrowing.
   - `WhisperKitBackend`'s actor-witness mapping to an `@MainActor` protocol needs build-proof. If the backend is NOT already MainActor-isolated, witnessing a `@MainActor` protocol requires the conformance itself to assert MainActor isolation. Add to substep 3: verify `WhisperKitBackend`'s isolation status before declaring the conformance; if not MainActor, the bridge protocol may need to be plain `AnyObject` (no MainActor) with methods that are explicitly async and accept their own isolation at call time.
3. Implement the protocol on `WhisperKitBackend` internally.
4. Update `WhisperKitPipeline` constructor to accept `WhisperKitDecodeBridge`. Today it holds `backend: WhisperKitBackend` — keep that for OTHER uses (preload, unload, state queries), add the bridge reference.
5. Replace all four reaches with bridge calls: three at lines 1150-1156 become ONE `makeIncrementalWorker(...)` call; line 714 becomes one `makeLanguageDetectionContext()` call.
6. **Narrow AND verify (load-bearing step).** Change `makeDecodeOptions`, `whisperKitTokenizer`, `whisperKitInstance` from `public` to `internal`. Delete the TODO comment at line 155. After narrowing, `grep "backend\.\(makeDecodeOptions\|whisperKitTokenizer\|whisperKitInstance\)" Sources/EnviousWisprPipeline/` MUST return zero hits. If grep finds hits, those are compile errors to fix. Skipping this step leaves an alternative path; the refactor fails.
7. If `WhisperKitIncrementalWorker`'s public constructor is no longer needed by Pipeline directly (because the bridge constructs it internally), narrow the worker's `init` to `internal` OR move `WhisperKitIncrementalWorker` out of `public actor` status.
8. Rebuild. Any compile breaks from substep 6 reveal additional leaks — good.
9. **Unit test — infrastructure prerequisite flagged by Codex R2-review 2026-04-18.** A mock bridge that returns a concrete `WhisperKitIncrementalWorker` actor is NOT a true mock — it would have to manufacture the real actor, which wants real WhisperKit state, defeating the seam. Two options: (a) the bridge returns a narrower protocol for the worker (e.g. `IncrementalWorkerInterface`) that the mock can implement, OR (b) accept this test is integration-level not unit-level. Separate issue: `EnviousWisprTests` does not depend on `EnviousWisprASR` in `Package.swift` (`Tests/EnviousWisprTests/Pipeline/PreWarmThrowsTests.swift:10` already notes the repo lacks workable `WhisperKitBackend` mocks). If substep 9 is meant seriously, the bridge must return a mockable abstraction AND the test target topology must change. Flag for founder decision. Minimal viable path: skip unit test for R2, rely on live smoke via `wispr-eyes`; open a follow-on issue for the test-infrastructure change.
10. Architecture Closeout, especially the access-control widening debt entry — document that the widening is now RESOLVED, not merely moved.
11. **Phase E interaction.** Deleting the TODO comment removes one of Phase E's cross-module-public-TODO-guard detections. If Phase E ships before R2, its baseline snapshot includes this TODO; Phase E's re-run after R2 ships expects the TODO gone. If Phase E ships AFTER R2, the TODO is gone at baseline time. Either order works; document which in R2's PR body.

### 12.4 DoD

- [ ] `WhisperKitBackend.makeDecodeOptions` is `internal` (grep confirms no `public`).
- [ ] `WhisperKitBackend.whisperKitTokenizer` is `internal`.
- [ ] `WhisperKitIncrementalWorker`'s public surface narrowed (if Pipeline no longer constructs directly).
- [ ] `WhisperKitPipeline` has ONE call into the bridge per tail-decode operation.
- [ ] TODO comment deleted (the debt it promised is paid).
- [ ] Mock bridge unit test exists.
- [ ] `swift build -c release` clean.
- [ ] Architecture Closeout documents the widening is resolved, not merely moved.
- [ ] Codex clean.

### 12.5 Rollback

`git revert`. Public surface re-widens. The TODO comment returns. No state or persistence concerns.

---

## 13. Phase R3 — AppLogger compile-out in release (revised v1.7)

**Issue:** #361 · **Status:** PLANNED — revised 2026-04-18 from per-site redaction to compile-out
**Pattern:** Compile-time feature gating — log pipeline becomes dead code in release builds · **Tier:** SMALL · **Est. LOC delta:** ~30 (one file)

### 13.1 Why this phase exists (founder reframing 2026-04-18)

REF-03 originally flagged `TextProcessingRunner.swift:32-36` (raw transcript → `AppLogger.info`). Prior bible drafts (v1.3-v1.6) planned per-site redaction across 148 AppLogger call sites. Founder reframing after CTO grep-analysis: **AppLogger is a development inner-loop tool, never designed for production.** Nerfing per-site is mechanical work across 8 modules; compile-out at the logger boundary is a one-file diff with a bigger privacy win.

Key measurements (verified 2026-04-18 against current main):
- **148 AppLogger call sites** across 8 modules (Pipeline 59, LLM 25, Audio 17, App 17, Services 14, ASR 11, PostProcessing 4, Storage 1). Core declares the logger and has zero usages.
- AppLogger is a `public actor` in `Sources/EnviousWisprCore/AppLogger.swift` — 141 lines. Single-file abstraction.
- Two sinks in `log()`:
  - OSLog via `os.Logger(subsystem: "com.enviouswispr.app", category: "pipeline")` — fires for every call; an existing `#if DEBUG` only controls whether `privacy: .public` is applied in Console.app.
  - File log at `~/Library/Logs/EnviousWispr/app.log` — only when `isDebugModeEnabled=true`; disk rotation at 10 MB × 5 files via `rotateIfNeeded()`.
- **No production component depends on AppLogger firing (GREP-VERIFIED 2026-04-18):**
  - `grep -rn "AppLogger" Sources/EnviousWisprServices/SentryBreadcrumb.swift Sources/EnviousWisprServices/ObservabilityBootstrap.swift` → **zero hits**. The Sentry path is completely disjoint.
  - `grep -rn "SentryBreadcrumb\|SentrySDK\|import Sentry" Sources/EnviousWisprCore/AppLogger.swift` → **zero hits** (reverse direction also clean).
  - `Sources/EnviousWisprServices/TelemetryService.swift` writes via PostHog SDK directly — does NOT route through AppLogger.
  - `bt-route.log` uses its own `AudioCaptureManager.btRouteLog` nonisolated static — bypasses AppLogger. Phase R4 handles rotation there separately.
  - Crash reporting: Sentry SDK auto-hooks SIGABRT / EXC_BAD_ACCESS etc. — bypasses AppLogger.

- **Diagnostics tab structure (verified 2026-04-18):** The entire user-visible surface for AppLogger-related affordances lives in ONE file and TWO enum sites:
  - `Sources/EnviousWispr/Views/Settings/DiagnosticsSettingsView.swift` — the whole tab (Debug Mode toggle + log level picker + "Restart Onboarding" button + Log Files "Open / Copy Path / Clear Logs" buttons + OSLog "Open Console.app" button + Performance "Run ASR Benchmark / Run Pipeline Benchmark" buttons + model-status label).
  - `Sources/EnviousWispr/Views/Settings/SettingsSection.swift:15` declares `case diagnostics` in the settings-tab enum.
  - `Sources/EnviousWispr/Views/Settings/SettingsView.swift:77` renders `DiagnosticsSettingsView()` for that case.
  - EVERY item in the tab is a developer affordance (log inspection, benchmark harness, onboarding re-run). No user-facing feature hides with it. Wrapping the enum case AND the render site in `#if DEBUG` removes the tab from Settings entirely in release builds. Dev builds keep it as-is.
  - Orthogonal consumer at `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift:779` uses a `DisclosureGroup("Diagnostics")` for LLM-related diagnostics — that's a DIFFERENT diagnostics section (LLM-specific) and is NOT affected by this phase.

### 13.2 Design summary

**Compile out the log pipeline in release builds via one `#if DEBUG` wrap of `AppLogger.log(_:level:category:)`.** The 148 call sites stay unchanged; the Swift compiler eliminates the empty release body as dead code.

Public API surface preserved so call sites compile unchanged:
- `AppLogger.shared` remains the singleton.
- `log(_:level:category:)` exists in both configs; release body is empty.
- `setDebugMode(_:)`, `setLogLevel(_:)`, `clearLogs()`, `logDirectoryURL()` remain as actor methods. In release, `setDebugMode` + `setLogLevel` still update internal state (cheap, harmless); file-sink methods are no-ops (no file ever opens).

**Canonical diff shape (substep 3 applies this exact shape):**

```swift
// Sources/EnviousWisprCore/AppLogger.swift
public actor AppLogger {
  public static let shared = AppLogger()

  // State preserved so Settings UI continues to compile in both configs.
  // In release, toggling debug mode has no effect because log() is dead code.
  public private(set) var isDebugModeEnabled: Bool = false
  public private(set) var logLevel: DebugLogLevel = .info

  #if DEBUG
    // File log + OSLog machinery only compiled in DEBUG.
    private let oslog = Logger(subsystem: "com.enviouswispr.app", category: "pipeline")
    private let timestampFormatter: ISO8601DateFormatter = {
      let formatter = ISO8601DateFormatter()
      formatter.timeZone = TimeZone.autoupdatingCurrent
      return formatter
    }()
    private let maxFileSize: Int = 10 * 1024 * 1024
    private let maxFileCount: Int = 5
    private var logDirectory: URL { /* existing body */ }
    private var currentLogURL: URL { logDirectory.appendingPathComponent("app.log") }
    private var fileHandle: FileHandle?
  #endif

  private init() {}

  public func setDebugMode(_ enabled: Bool) {
    isDebugModeEnabled = enabled
    #if DEBUG
      if enabled {
        openFileHandleIfNeeded()
        log("Debug mode enabled", level: .info, category: "AppLogger")
      } else {
        log("Debug mode disabled", level: .info, category: "AppLogger")
        fileHandle?.closeFile()
        fileHandle = nil
      }
    #endif
  }

  public func setLogLevel(_ level: DebugLogLevel) {
    logLevel = level
  }

  public func log(_ message: String, level: DebugLogLevel = .info, category: String = "App") {
    #if DEBUG
      switch level {
      case .info: oslog.info("[\(category)] \(message)")
      case .verbose: oslog.debug("[\(category)] \(message)")
      case .debug: oslog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
      }
      guard isDebugModeEnabled, level <= logLevel else { return }
      let timestamp = timestampFormatter.string(from: Date())
      let line = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      writeToFile(data)
    #endif
    // Release: no-op. Sink logic is dead code; call sites still incur the actor-hop
    // overhead of `await AppLogger.shared.log(...)` (often wrapped in `Task { ... }`).
    // Net: production privacy win, not zero-overhead call-site elimination.
  }

  #if DEBUG
    private func openFileHandleIfNeeded() { /* existing body */ }
    private func writeToFile(_ data: Data) { /* existing body */ }
    private func rotateIfNeeded() { /* existing body */ }
  #endif

  public func logDirectoryURL() -> URL {
    #if DEBUG
      return logDirectory
    #else
      // Placeholder — Settings UI "Open log folder" button in release should be hidden
      // per substep 4, but preserve the API signature so callers compile.
      return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
    #endif
  }

  public func clearLogs() throws {
    #if DEBUG
      fileHandle?.closeFile()
      fileHandle = nil
      let dir = logDirectory
      guard let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil) else { return }
      for file in files where file.pathExtension == "log" {
        try FileManager.default.removeItem(at: file)
      }
      if isDebugModeEnabled { openFileHandleIfNeeded() }
    #endif
    // Release: no-op.
  }
}
```

### 13.3 Substeps (ordered)

1. **Inventory audit (for the record, not for code change).** `grep -rn "AppLogger\." Sources/` → 148 hits. `grep -rn "AppLogger\." Sources/ > docs/audits/2026-04-18-applogger-callsites.txt` for audit trail. **Call sites DO NOT change.** Inventory is evidence, not work.
2. **Confirm production independence.** Grep `Sources/EnviousWisprServices/SentryBreadcrumb.swift`, `Sources/EnviousWisprServices/TelemetryService.swift` for `AppLogger` references. Expected: zero. Record in PR body.
3. **Apply the `#if DEBUG` wrap to `AppLogger.swift`** per §13.2 canonical diff. One file changed. Single commit preferred; two-commit "refactor then gate" also acceptable if it simplifies review.
4. **Settings UI — Diagnostics tab in release.** Verified structure (§13.1): the whole tab is `DiagnosticsSettingsView.swift`, declared in `SettingsSection.swift` and rendered in `SettingsView.swift`. **FOUR wrap sites required**, not two (Codex plan-review 2026-04-18 correction — wrapping only the case would break the exhaustive `switch` statements on `label`, `icon`, `group`):
   ```swift
   // SettingsSection.swift — wrap in FOUR places:
   enum SettingsSection: String, CaseIterable {
     // ... other cases
     #if DEBUG
     case diagnostics
     #endif

     var label: String {
       switch self {
         // ... other cases
         #if DEBUG
         case .diagnostics: return "Diagnostics"
         #endif
       }
     }
     var icon: String {
       switch self {
         // ... other cases
         #if DEBUG
         case .diagnostics: return "ladybug"
         #endif
       }
     }
     var group: SettingsGroup {
       switch self {
         case .memory, .permissions: return .system  // drop .diagnostics from this arm
         #if DEBUG
         case .diagnostics: return .system
         #endif
         // ... other arms
       }
     }
   }

   // SettingsView.swift — fifth wrap site:
   switch section {
     // ... other cases
     #if DEBUG
     case .diagnostics: DiagnosticsSettingsView()
     #endif
   }
   ```
   Release build: the Diagnostics tab is completely absent from the Settings sidebar. Five wrap sites total (enum case + three switch arms in `SettingsSection.swift` + one in `SettingsView.swift`).

   **Important — `AIPolishSettingsView.swift:747` has a separate debug-flag-driven UI** that the Diagnostics-tab hide does NOT cover. Line 747 reads `if appState.settings.isDebugModeEnabled, let report = appState.aiAvailability.latestReport { aiDebugSection(report: report) }`. A release build that inherits `UserDefaults` from a prior dev session with `isDebugModeEnabled=true` would still show this AI debug section. Fix: also wrap the block in `#if DEBUG` so release cannot reach `aiDebugSection` regardless of the persisted flag. (Alternatively: force `isDebugModeEnabled=false` at first launch of a release binary — more invasive, reject.)

   The unrelated `DisclosureGroup("Diagnostics")` at `AIPolishSettingsView.swift:779` is LLM-specific and stays in release — do not touch it.
5. **Release build verification.** `swift build -c release`; run the built binary; dictate a sentence; open Console.app filtered to subsystem `com.enviouswispr.app`; confirm NOTHING appears. Previously this subsystem showed privacy-redacted entries; post-fix, zero entries in release.
6. **Debug build verification.** `swift build -c debug` or Xcode run; enable debug mode in Settings; dictate; confirm Console.app shows entries and `~/Library/Logs/EnviousWispr/app.log` fills as before. Dev inner-loop unchanged.
7. **Release-binary OSLog subsystem grep.** After dictation on a release build, run `log show --last 5m --predicate 'subsystem == "com.enviouswispr.app"'`. Expected: empty. Any hits mean the compile-out is incomplete.
8. **Unit tests — both configs must actually run.**
   - Required CI invocations: `swift test -c debug` AND `swift test -c release`. The `#if DEBUG` split only provides coverage if both are run; if only the default (`debug`) test suite runs, the release-side behavior is untested. Confirm both invocations are present in `.github/workflows/pr-check.yml`; if not, add the release invocation.
   - `#if DEBUG`-gated test: `await AppLogger.shared.setDebugMode(true); await AppLogger.shared.log("test", level: .info); #expect(...fileLogContains("test"))`.
   - `#if !DEBUG`-gated test (stronger than v1.7 draft): explicitly assert that `setDebugMode(true)` followed by `log(...)` does NOT create `app.log`. Query the expected file URL — it must not exist after the call. This assertion proves the file-sink dead-code actually does not execute.
9. **Documentation updates:**
   - `.claude/knowledge/observability-operations.md` — AppLogger is DEBUG-only in release; production log correlation goes via Sentry breadcrumbs (`SentryBreadcrumb.captureError(...)`) and PostHog events (`TelemetryService.shared.*`).
   - `.claude/knowledge/gotchas.md` — "Adding a log statement does NOT reach production. If you need a production-visible diagnostic, route via `SentryBreadcrumb` (error context) or `TelemetryService` (opt-in analytics event). AppLogger is dev inner-loop only."
10. **Architecture Closeout.** Phase R3 removes production-time behavior of 148 call sites without touching any call site; privacy posture strengthened; no production observer depends on AppLogger; file-log rotation + disk usage in release is now zero.

### 13.4 DoD

- [ ] `AppLogger.log(_:level:category:)` body wrapped in `#if DEBUG`.
- [ ] `setDebugMode`, `clearLogs`, file-sink machinery all `#if DEBUG`-gated.
- [ ] Public API surface unchanged — 148 call sites compile with zero edits.
- [ ] Release build: dictate a sentence, `log show --predicate 'subsystem == "com.enviouswispr.app"'` returns empty.
- [ ] Debug build: dictate a sentence, Console.app + file log both populate as before.
- [ ] Settings UI release build: debug-log tab/controls hidden via `#if DEBUG`.
- [ ] Unit tests per substep 8 pass.
- [ ] Documentation updates committed (`observability-operations.md`, `gotchas.md`).
- [ ] `docs/audits/2026-04-18-applogger-callsites.txt` committed as audit-trail reference.
- [ ] Architecture Closeout in PR body.
- [ ] Codex review clean.

### 13.5 Rollback

`git revert`. AppLogger resumes release-mode emission. Prior privacy posture returns. Undesirable but not broken. No call sites changed; no migration.

### 13.6 Relationship to V3 (revised — non-AppLogger loggers exist on the same subsystem)

V3 (§20) runs an end-to-end release-build log audit. With R3 applied, V3 must distinguish TWO facts that look similar but are not the same:

- **R3 success:** `AppLogger.oslog` (category `pipeline` under subsystem `com.enviouswispr.app`) emits nothing in release. The 148 call sites' sink paths are dead code.
- **Subsystem silence:** no logs of any kind appear under EnviousWispr subsystems. **This is NOT what R3 delivers** — see §13.9 for the four other Logger sinks that remain.

Revised V3 verification recipe for R3 specifically:

```bash
# Dictate a unique token in a release build, then:

# Check 1 — AppLogger must be silent (category "pipeline" on subsystem com.enviouswispr.app)
log show --last 10m --predicate 'subsystem == "com.enviouswispr.app" AND category == "pipeline"' | grep -v "^Timestamp\|^Filtering" | head -5
# Expected: empty. Any hit = R3 compile-out incomplete.

# Check 2 — Other subsystem loggers (FillerRemoval, WordCorrector, BTCrashDiag) MAY still emit.
# Document any hits; treat as expected, NOT as R3 failure.
log show --last 10m --predicate 'subsystem BEGINSWITH "com.enviouswispr" AND category != "pipeline"' | head -20
# Hits under categories "FillerRemoval", "WordCorrector", "BTCrashDiag" are from non-AppLogger loggers
# (see §13.9). R3 does not remove these; they are OUT OF SCOPE.

# Check 3 — Dictated token must appear nowhere
log show --last 10m --predicate 'subsystem BEGINSWITH "com.enviouswispr"' | grep -F "YOUR_DICTATED_TOKEN"
# Expected: empty. Non-empty hit under "pipeline" category = R3 failure. Non-empty hit elsewhere = audit finding for whichever logger.
```

R3 is the strongest evidence for the AppLogger-specific compile-out. V3's separate job is to audit the whole subsystem family and report all results. The original v1.7 bible claim "V3 becomes strongest evidence that R3 worked" was too strong — V3 IS the AppLogger evidence, but "no subsystem logging at all" requires additional cleanup beyond R3 (see §13.9).

### 13.7 What R3 does NOT do

- Does not remove `SentryBreadcrumb.captureError(...)` — that's the production error-reporting path by design.
- Does not remove `TelemetryService.shared.*` — PostHog opt-in telemetry, separate policy layer.
- Does not remove `btRouteLog` or touch `bt-route.log` — R4 handles that separately.
- Does not add a new "structural error-only" release-safe log path. If future work needs one, add it with an explicit caller justification (not in this phase).
- Does not change call-site behavior in debug builds. Dev experience is preserved exactly.
- Does not touch `CORRECTION_DEBUG [RAW ASR] \(rawText)` at `TextProcessingRunner.swift:32-36` in its text; it just renders that call site inert in release via the enclosing AppLogger no-op.

### 13.8 Revised-estimate breakdown

| Prior R3 plan (v1.3-v1.6) | Revised R3 plan (v1.8 — post Codex R3 review) |
|---|---|
| ~40 LOC | ~40-50 LOC across 3 files (AppLogger.swift + SettingsSection.swift + AIPolishSettingsView.swift) |
| Touches ~148 call sites across 8 modules | Touches 1 logger file + 2 UI files; zero call-site edits |
| Redacts transcript text; metadata still flows to Console.app | No AppLogger output in release; sink logic is dead code |
| EW_LOG_VERBATIM env var for verbatim dev sink | Debug builds log normally; no env var needed |
| V3 validates "no transcript text in logs" | V3 validates AppLogger-specific silence (category=pipeline); non-AppLogger loggers documented separately per §13.9 |

### 13.9 Other logger sinks on the same subsystem (NOT in R3 scope — documented so V3 does not conflate)

Grep-verified 2026-04-18: four non-AppLogger sinks exist in `Sources/`. R3 does NOT touch these; V3 must distinguish them.

| File:line | Type | Subsystem | Category | In R3 scope? |
|---|---|---|---|---|
| `Sources/EnviousWisprCore/AppLogger.swift:17` | `os.Logger` | `com.enviouswispr.app` | `pipeline` | YES — R3 wraps in #if DEBUG |
| `Sources/EnviousWisprPipeline/FillerRemovalStep.swift:16` | `os.Logger` (private static) | `com.enviouswispr.app` | `FillerRemoval` | NO — separate logger instance, direct os_log usage |
| `Sources/EnviousWisprPostProcessing/WordCorrector.swift:29` | `os.Logger` (private static) | `com.enviouswispr` (shorter) | `WordCorrector` | NO — separate logger, different subsystem |
| `Sources/EnviousWisprAudio/AVAudioEngineSource.swift:8` | `os.Logger` (`btCrashLogger`) | `com.enviouswispr` (shorter) | `BTCrashDiag` | NO — BT-crash diagnostics |
| `Sources/EnviousWisprCore/Constants.swift:28` | `NSLog(...)` | (default) | — | NO — one-off constant initialization log |
| `Sources/EnviousWisprServices/ObservabilityBootstrap.swift:30, 67` | `print(...)` | (stdout) | — | NO — two sites, observability bootstrap setup-time |

**Should these be cleaned up?** Not in R3. R3 is scoped to AppLogger. A post-R3 follow-on (not part of Epic #319) could either:
- Route these through AppLogger (then compile-out is unified), OR
- Wrap each in `#if DEBUG` individually.

Tracked as a post-epic candidate. For now, V3 verifies AppLogger-specific silence via `category == "pipeline"` predicate; the other four are documented as expected-still-present and reviewed separately in V3's broader log audit.

---

## 14. Phase R5 — HeartPathTelemetryEmitter extraction

**Issue:** #290 · **Existing plan:** `docs/feature-requests/issue-290-2026-04-18-heart-path-telemetry-emitter.md` · **Status:** SHIP-READY
**Pattern:** Extract Class + Dedup bookkeeping ownership (Fowler) · **Tier:** MEDIUM · **Est. LOC delta:** ~0 net (moved, not added)

### 14.1 Why this phase exists

PR #285 added three telemetry handlers + dedup bookkeeping directly onto both pipelines. Both now own: `handleCaptureStall`, `handleXPCReplyFailed`, `handleCaptureSessionInterruption`, `emitNoAudioCapturedEvent`, plus `stallEventAlreadyCaptured`, `xpcReplyFailedThisSession`, `lastObservedCaptureSession` state. Pipelines coordinate too many domains. State ownership for Sentry-dedup bookkeeping does not belong on pipelines.

### 14.2 Design summary

New `HeartPathTelemetryEmitter` in `EnviousWisprPipeline`. Owns dedup state. Pipelines delegate. Context structs (`StallContext`, `XPCContext`, `InterruptionContext`, `NoAudioContext`) pass pipeline-specific params. Emitter resets per session via `resetForNewSession`.

Full design in `docs/feature-requests/issue-290-2026-04-18-heart-path-telemetry-emitter.md`. Do not duplicate here.

### 14.3 Substeps

Per the existing plan's §11. Key points:

1. Characterization test: Sentry event shapes before and after are bit-identical (same category, extras, tags).
2. Move the four handler methods + state into the emitter.
3. Add `resetForNewSession(sessionID:)`.
4. Pipelines become thin call-throughs.
5. Unit tests cover dedup (stall fires once per session), reset-on-session, each event type.
6. Live dictation smoke: same events appear in Sentry.

### 14.4 DoD

Per existing plan §13. In short:

- [ ] `scripts/swift-test.sh` passes (including new emitter tests).
- [ ] `swift build -c release` exit 0.
- [ ] Regression smoke: live dictation → same Sentry events fire as before.
- [ ] Pipeline file line count decreases by ~200 net.
- [ ] Architecture Closeout section in PR body.
- [ ] Codex review pass.
- [ ] Zero em-dashes / en-dashes (per global rule).

### 14.5 Rollback

`git revert`. Telemetry state returns to pipelines. No persisted change.

---

## 15. Phase R4 — BT route log rotation

**Issue:** #362 · **Status:** PLANNED
**Pattern:** Extract Helper + Introduce Rotation Policy · **Tier:** SMALL · **Est. LOC delta:** ~45

### 15.1 Why this phase exists

REF-06. `AudioCaptureManager.swift:525-530` appends to `~/Library/Logs/EnviousWispr/bt-route.log` with no cap. Cross-process write (main app + XPC service). Grows forever.

### 15.2 Design summary

New `RotatingFileSink(path:, maxSize:, maxFiles:)` in `EnviousWisprAudio` (or a shared utility in Core if multiple modules want it; prefer Core after the second caller emerges).

Retention policy: 5 MB × 3 files = 15 MB ceiling, drop oldest on rotation.

**Call-site constraint (adversarial-verified 2026-04-18):** `btRouteLog` is called from contexts that cannot `await`:
- `Sources/EnviousWisprAudio/PreRollForwarder.swift:181, 185, 192` — audio-thread-adjacent path. `architecture-rules.md §Audio/ASR Danger Zones` explicitly forbids logging under the RT `OSAllocatedUnfairLock`.
- `Sources/EnviousWisprAudio/AVCaptureSessionSource.swift:154, 244, 344, 469, 482` — capture session callbacks.
- `Sources/EnviousWisprAudio/AudioCaptureManager.swift:298, 319, 380, 473, 478, 490, 504` — synchronous route-change handlers.

All are synchronous callers. An `actor`-based sink forces `async`, breaking every site AND introducing actor-hop latency on RT-adjacent paths. The v1.3 actor redesign was wrong for this call pattern.

**Correct design — nonisolated class with OSAllocatedUnfairLock + flock:**

```swift
// Sources/EnviousWisprAudio/RotatingFileSink.swift
public final class RotatingFileSink: @unchecked Sendable {
  private let path: URL
  private let maxSize: Int
  private let maxFiles: Int
  private let lock = OSAllocatedUnfairLock()

  public init(path: URL, maxSize: Int = 5 * 1024 * 1024, maxFiles: Int = 3) {
    self.path = path
    self.maxSize = maxSize
    self.maxFiles = maxFiles
  }

  // Sync, nonisolated — safe to call from audio-adjacent contexts.
  // Lock hold time: O(line length + occasional rotate).
  // Lock must NOT be held across the RT audio lock; callers already ensure this.
  public func append(_ message: String) {
    let data = Data(message.utf8)
    lock.withLock {
      // Open with O_APPEND|O_CREAT, take flock(LOCK_EX) for cross-process, write, release.
      // Rotate if post-write size would exceed maxSize: rename N→N+1, drop N=maxFiles, reopen.
      Self.atomicAppendWithRotation(path: path, data: data, maxSize: maxSize, maxFiles: maxFiles)
    }
  }

  // File helpers are `private static` and implemented via BSD syscalls (open, flock, fstat, write, rename, close, unlink).
}
```

Why nonisolated + `@unchecked Sendable`: this class has NO Swift-visible mutable state outside the lock; it's a lock-guarded syscall wrapper. Swift 6 cannot prove the safety automatically, so `@unchecked Sendable` is legitimate. The real safety comes from `OSAllocatedUnfairLock` (in-process) + `flock(LOCK_EX)` (cross-process).

**PreRollForwarder call sites require extra care.** Per `architecture-rules.md`, logging under the RT lock is forbidden. Phase R4 must preserve that contract: calls from PreRollForwarder must emit the log AFTER the RT lock is released. Verify during Phase R4 substep 2 that every current call site is outside the RT lock; if any is inside, either (a) capture the data and log post-lock, or (b) skip that specific site.

**Caller update:** `AudioCaptureManager.btRouteLog` replaced with an instance-level `btSink.append(_:)`. Existing `nonisolated static` surface preserved for test compatibility by wrapping the sink in a static-initialized shared instance.

**Not an actor.** The v1.3 actor redesign is retracted for this class of call pattern. Actor is correct when callers are async; here, every caller is sync and some are RT-sensitive.

### 15.3 Substeps

1. Decide retention policy (5 MB × 3 default).
2. Implement `RotatingFileSink`. Cross-process-safe: either O_APPEND + rotation under flock, or write to a per-process file and roll a separate combiner (reject — too complex).
3. Replace `btRouteLog` body with sink.
4. Unit test: write `>5MB` of messages, assert rotation, assert `.log.3+` deleted.
5. Unit test: two processes writing concurrently, no torn lines.
6. Document retention in `.claude/knowledge/observability-operations.md`.

### 15.4 DoD

- [ ] `bt-route.log` never exceeds `maxSize`.
- [ ] Rotation artifacts (`.log.1`, `.log.2`) appear and cap at `maxFiles`.
- [ ] Cross-process concurrent-write test passes.
- [ ] Retention policy documented.
- [ ] Architecture Closeout + Codex clean.

### 15.5 Rollback

`git revert`. Unbounded append returns. Undesirable but not broken.

---

## 16. Phase R6 — Prompt delimiter hardening (gated on V4)

**Issue:** #363 · **Status:** GATED ON V4 — do not start code work until V4 confirms failure
**Pattern:** Introduce Shared Sanitizer + Corpus Coverage · **Tier:** SMALL · **Est. LOC delta:** ~60

### 16.1 Why this phase is gated

REF-04 is the audit's only Low-confidence finding. Static review flagged that the prompt wrapper's delimiter sanitizer ignores case and whitespace variants, but cannot prove any provider actually fails on those variants. Running the code-change work before evidence wastes time on a non-issue.

V4 (§21) runs the adversarial eval. Only proceed with R6 code work if V4 confirms at least one provider fails. If V4 clears all providers, close #363 "no defect found" with V4 evidence attached.

### 16.2 Design summary (if V4 confirms)

New `PromptDelimiterSanitizer.normalize(_:)` in `EnviousWisprLLM`:

```swift
enum PromptDelimiterSanitizer {
  static func sanitize(_ transcript: String) -> String {
    // 1. NFKC-normalize
    // 2. Lowercase any tag-like substring that could be confused with delimiters
    //    (e.g. `<TRANSCRIPT>` → `&lt;transcript&gt;` or similar escape)
    // 3. Collapse whitespace inside delimiter-like patterns
  }
}
```

Applied at every provider builder's transcript-insertion site. Each builder gets a unit test and a corpus test added to `scripts/eval/prompts/adversarial-delimiters/`.

Per `.claude/rules/validation-discipline.md §10 Rule B`, the corpus extension ships in the same PR as the feature code. Baseline updated with `BASELINE-BUMP:` tag + rationale per Rule C.

### 16.3 Substeps (if V4 confirms)

1. Read V4 output. Note which providers fail which variants.
2. Build `PromptDelimiterSanitizer` to handle the confirmed variants.
3. Apply at every builder (OpenAI, Gemini, Ollama, Apple Intelligence). One call site per builder.
4. Unit tests for each variant's normalization.
5. Extend `scripts/eval/prompts/adversarial-delimiters/` with cases per confirmed failure.
6. Bump polish eval baseline; `BASELINE-BUMP:` tag in PR description with rationale.
7. Rerun V4 adversarial eval. Expect green.

### 16.4 DoD

- [ ] V4 re-runs green on the confirmed adversarial cases.
- [ ] Corpus cases committed.
- [ ] Baseline updated with justification.
- [ ] Unit tests pass for each variant.
- [ ] Architecture Closeout + Codex clean.

### 16.5 Rollback

`git revert`. Delimiter handling returns to prior. V4 would show the failure again. Re-ship with revised fix.

---

## 17. Phase F — SetupCoordinator extraction (NEW v1.3)

**Issue:** to open · **Plan:** inline below · **Status:** PLANNED
**Pattern:** Extract Class (Fowler) — cohesive cluster of setup-orchestration concerns moves out of AppState · **Tier:** MEDIUM · **Est. LOC delta:** +~200 net (SetupCoordinator ~100, AppState −~30, view migrations +~100-150 across 5+ files). Original v1.3 estimate of +~90 undercounted view migration; corrected 2026-04-18 after adversarial view-surface grep.

### 17.1 Why this phase exists

Added in v1.3 after the §4.13 disposition matrix made clear that Phases A+C+D alone would take AppState from 15 deps to 14 — nowhere near meaningful testability improvement. Extracting the setup-service cluster (`ollamaSetup`, `whisperKitSetup`, plus the `whisperKitPreloadTask` observation wiring that drives them) into a dedicated coordinator takes the count to 12 and clusters a genuinely cohesive domain.

Without Phase F, Phase E's regression test would need to be calibrated to a ≤ 14 target, which does not move the Testability grade.

### 17.2 Scope

New `@MainActor final class SetupCoordinator` in `Sources/EnviousWispr/App/SetupCoordinator.swift`. Owns:

- `let ollamaSetup = OllamaSetupService()`
- `let whisperKitSetup = WhisperKitSetupService()`
- `private var whisperKitPreloadTask: Task<Void, Never>?`
- `func startWhisperKitPreloadObservation()`
- Any setup-progress reporting surface currently on AppState.

**Required collaborators (Codex F-review 2026-04-18 — missing from v1.6 design):**
The current preload observer at `AppState.swift:647` reads `asrManager.activeBackendType` at line 657 and calls `whisperKitPipeline.prepareBackendSilently()` at line 662. `SetupCoordinator` as zero-arg `let setup = SetupCoordinator()` is INSUFFICIENT — it needs these collaborators injected. Corrected init shape:

```swift
@MainActor
final class SetupCoordinator {
  let ollamaSetup = OllamaSetupService()
  let whisperKitSetup = WhisperKitSetupService()
  private var whisperKitPreloadTask: Task<Void, Never>?
  private let asrManager: any ASRManagerInterface
  private let preloadAction: @MainActor () async -> Void  // wraps whisperKitPipeline.prepareBackendSilently()

  init(asrManager: any ASRManagerInterface,
       preloadAction: @escaping @MainActor () async -> Void) {
    self.asrManager = asrManager
    self.preloadAction = preloadAction
  }

  func startPreloadObservation() { /* same logic, uses injected collaborators */ }
}
```

AppState constructs it AFTER `asrManager` and `whisperKitPipeline` are ready (init-order constraint documented). The preload action is a closure so `SetupCoordinator` doesn't need to know about the pipeline's full interface — just one method.

Owns internally, exposes a narrow protocol to AppState:

```swift
@MainActor
protocol SetupCoordinating: AnyObject {
  var ollamaSetup: OllamaSetupService { get }      // passthrough — views observe @Observable properties directly
  var whisperKitSetup: WhisperKitSetupService { get }
  func startPreloadObservation()
}
```

v1.6 correction (Codex plan review 2026-04-18): the earlier draft included `reset()` AND semantic accessors `ollamaReady` / `whisperKitReady`. The semantic accessors lose SwiftUI's @Observable change tracking for `appState.ollamaSetup.setupState` in views. Substep 2 (Option A) documents the property-passthrough pattern; the protocol shape above must match that. `reset()` dropped — no caller.

AppState drops `ollamaSetup`, `whisperKitSetup`, `whisperKitPreloadTask` direct properties and gains one: `let setup = SetupCoordinator()` (or injected via composition for test seams).

### 17.3 Substeps (ordered)

**Exact view-migration surface (Codex F-review 2026-04-18, precise counts):**
- `appState.ollamaSetup.*` — **29 sites** in `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift`.
- `appState.whisperKitSetup.*` — **8 sites** in `Sources/EnviousWispr/Views/Settings/SpeechEngineSettingsView.swift`.
- `appState.ollamaSetup.cleanup()` — **1 site** in `Sources/EnviousWispr/App/AppDelegate.swift:417`.
- **Total: 38 sites across 3 files** (plus AppDelegate shutdown hook). The v1.3 "~20-30 sites across ~5 files" estimate was BOTH too-few (sites) AND too-many (files). LOC delta revised: +200 to +250 (mostly mechanical rename of `appState.ollamaSetup.X` → `appState.setup.ollamaSetup.X` in 29 places + `appState.whisperKitSetup.X` → `appState.setup.whisperKitSetup.X` in 8 places).

1. **Inventory pass (substep 1 — DO THIS BEFORE WRITING CODE).** Grep every read site:
   ```bash
   grep -rn "appState\.ollamaSetup\." Sources/ Tests/
   grep -rn "appState\.whisperKitSetup\." Sources/ Tests/
   grep -rn "\.whisperKitPreloadTask\b" Sources/
   ```
   Expected hits include at minimum:
   - `Sources/EnviousWispr/App/AppDelegate.swift:417` — `ollamaSetup.cleanup()`.
   - `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift` — 15+ sites (setupState reads, onChange, method calls: detectState, cancelPull, resetWarmup, startServer, pullModel, warmUpModel).
   - Likely more view sites for WhisperKit setup.
   
   Build a full inventory BEFORE designing the `SetupCoordinating` protocol. The protocol surface is whatever this inventory demands plus safe margin.
2. Design `SetupCoordinating` protocol. At minimum it must expose the underlying `@Observable` services for SwiftUI's property-observation tracking to keep working. Options:
   - **Option A (simplest):** `setupCoordinator.ollamaSetup` and `setupCoordinator.whisperKitSetup` passthrough properties. Views change `appState.ollamaSetup` → `appState.setup.ollamaSetup`. Protocol surface = two properties. Simplest migration.
   - **Option B (encapsulating):** Protocol exposes semantic methods (`setup.ollamaReady`, `setup.startOllamaDetect()`, etc.). Views deeply migrate. More work, cleaner end state, but larger blast radius.
   
   **Recommendation for this epic: Option A.** Ship the property-passthrough version. Post-epic, if the encapsulation is genuinely needed, do a smaller follow-on.
3. Define `SetupCoordinator` concrete class. Move `ollamaSetup`, `whisperKitSetup`, `whisperKitPreloadTask` ownership. Preserve their current `@Observable` surfaces intact.
4. Update AppState: replace three fields with one `setup = SetupCoordinator()` field.
5. Update `PipelineSettingsSync.onNeedsPreloadObservation` callback to call into `setup` instead of AppState.
6. **View migration (substep 6 — mechanical, from inventory in substep 1).** Every read `appState.ollamaSetup.X` becomes `appState.setup.ollamaSetup.X` (Option A). Every `appState.whisperKitSetup.X` → `appState.setup.whisperKitSetup.X`. Every `.onChange(of: appState.ollamaSetup.setupState)` still observes the SAME `OllamaSetupService` instance; the observation path changes string, not the object graph.
7. Test pass: `AIPolishSettingsView` + WhisperKit-setup-touching views still render and respond to state changes live. Use `wispr-eyes` to verify the Settings > AI Polish tab cycles through setupState transitions correctly.
8. Unit test: `SetupCoordinator` can be constructed without AppState; `startWhisperKitPreloadObservation` starts and can be cancelled. **Codex F-review 2026-04-18 prerequisite:** `Package.swift:107` does NOT include the `EnviousWispr` executable target as a test dependency; `EnviousWisprTests` cannot import `SetupCoordinator` as-is. The test requires either (a) adding `EnviousWispr` to test target deps in `Package.swift`, OR (b) extracting `SetupCoordinator` into a library target that tests can depend on. Recommendation: (a) — smaller blast radius. With the seam (injectable `asrManager` + `preloadAction` closure per §17.2), the test can force a fake non-ready state, assert observer start/cancel, and assert `preloadAction` is invoked. No real HTTP or model downloads.
9. Live smoke: Ollama and WhisperKit setup still report status correctly in Settings UI; preload fires on new model selection; cleanup fires on app quit.

### 17.3.1 Protocol surface — RESOLVED (no `reset()`)

Codex plan review 2026-04-18 flagged self-contradiction between §17.2 (earlier draft included `reset()` in the protocol sketch) and §17.3.1 (dropped `reset()`). Locked in v1.6: the `SetupCoordinating` protocol does NOT expose `reset()`. No current caller needs it. §17.2 sketch above is the canonical protocol shape. If future work needs reset-on-account-switch or similar, add it then with a concrete caller.

### 17.4 DoD

- [ ] `AppState.swift` grep returns zero hits for `ollamaSetup`, `whisperKitSetup`, `whisperKitPreloadTask` as owned properties.
- [ ] `SetupCoordinator.swift` + `SetupCoordinating` protocol committed.
- [ ] PipelineSettingsSync + views route through the protocol.
- [ ] Unit test exercises preload observation.
- [ ] Live smoke: both setup services work as before.
- [ ] Architecture Closeout — ownership moved, no widening.
- [ ] Codex clean + Periphery clean.

### 17.5 Rollback

`git revert`. Properties return to AppState. No persisted state; no migration.

### 17.6 Dependencies

After Phase A (cleaner AppState to operate on). Can land in Session 3 with or adjacent to Phase C+D+E, or Session 4 if time constrained. No dependency on R2.

### 17.7 Post-epic candidates (not in Phase F scope)

§4.13 identified two other extraction candidates that are NOT in this epic:
- **BenchmarkCoordinator** absorbing `benchmark = BenchmarkSuite()`.
- **TelemetryObservationCoordinator** absorbing `captureTelemetry = CaptureTelemetryState()` observer wiring.

If the post-epic audit rerun grades Testability below A, open these as follow-on issues under #319. Do not expand this epic to absorb them.

---

## 17A. Phase G — Test-seam DI pass (imported from epic #385)

**Parent epic (origin):** #385 CI test quality remediation · **Adopted into epic #319 on 2026-04-20** · **Status:** PLANNED · **Aggregate tier:** REFACTOR (5 SMALL sub-phases)

### 17A.1 Why this phase exists

The 2026-04-19 Codex CI-test-quality audit scored our suite 4/10. The tonight's (2026-04-20) autopilot — epic #385 Targets 1/2/3/5 — shipped five honest test files but could not cover entire scenario classes because the production code under test has no injection seams. Codex's adversarial truth-audit pass classified three of Target 2's six scenarios as `NOT_TESTABLE_WITHOUT_REFACTOR`, and Target 3 shipped seven tests where a planned eighth was downgraded because `ASRManager.switchBackend` cannot be exercised from a loaded state without backend injection.

Phase G closes those gaps. Five sub-phases, each a small DI seam refactor in a heart- or limb-adjacent type. Every sub-phase is REFACTOR-but-SMALL in LOC, yet materially increases the test suite's ability to catch real regressions (the #319 Testability dimension — graded B by the senior audit, with `AppState.swift:18-23` flagged for 11 concrete-type property declarations). Phase G is the one-layer-deeper analog: each flagged type here has the same "hard-wired collaborator" smell AppState has, just one level down.

### 17A.2 Scope — five sub-phases, 1:1 with GitHub Issues

| Sub | Issue | Target file | Seam introduced | LOC | Tier |
|---|---|---|---|---|---|
| G1 | #388 | `Sources/EnviousWisprPipeline/TextProcessingRunner.swift:99` | Replace literal `stepName == "LLM Polish"` with `TextProcessingStep.errorSurfacePolicy` (enum) or `is LLMPolishStep` type check | ~20 | SMALL |
| G2 | #389 | `Sources/EnviousWisprPipeline/TextProcessingRunner.swift` (six `AppLogger.shared.log` sites at lines 33, 58, 63, 67, 72, 103) | Inject `any PipelineLogging` via default-valued init param; default remains `AppLogger.shared` via `AppLoggerAdapter` | ~30 | SMALL |
| G3 | #394 | `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift` (init constructs its own `TranscriptFinalizer`) | Accept `TranscriptFinalizer` (or its paste seam + runner) via init; default-construct preserves current callers | ~60 | SMALL/MEDIUM |
| G4 | #396 | `Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift` (hard-calls static `PasteService`, `AXIsProcessTrusted`, `NSWorkspace.frontmostApplication`, live `Task.sleep`) | Protocolize `PasteService` surface + inject frontmost-app observer + inject clock/sleeper; default production wiring unchanged | ~80 | SMALL/MEDIUM |
| G5 | #398 | `Sources/EnviousWisprASR/ASRManager.swift:23-24` (concrete `ParakeetBackend` / `WhisperKitBackend` owned directly) | Inject backends through a factory or `any ASRBackend` pair; unlocks adversarial `switchBackend` tests without real model load | ~40 | SMALL |

Each sub-phase has its own plan file:

- G1 → `docs/feature-requests/issue-388-2026-04-20-textprocessingrunner-polish-step-type.md`
- G2 → `docs/feature-requests/issue-389-2026-04-20-textprocessingrunner-logger-di.md`
- G3 → `docs/feature-requests/issue-394-2026-04-20-transcriptionpipeline-di-seams.md`
- G4 → `docs/feature-requests/issue-396-2026-04-20-pastecascadeexecutor-di-seams.md`
- G5 → `docs/feature-requests/issue-398-2026-04-20-asrmanager-backend-injection.md`

Plan files carry the full §4–§9 MANDATORY template answers. This bible section is the index + philosophy.

### 17A.3 Philosophy — three invariants for every Phase G sub-phase

1. **Default-value DI only.** Every new init parameter has a production default. Zero changes at existing call sites on ship. Adoption of the seam is test-only. Prevents Phase G becoming a ripple-edit that touches AppState, pipelines, and services.

2. **No behavior change in release builds.** Phase G introduces seams; it does NOT change any observable behavior. The `polish-eval-smoke` gate (validation-discipline.md §10) and the heart-path-bench cold run (validation-discipline.md §9) are regression gates. If either moves, investigate before shipping.

3. **Honest tests before ship.** Each sub-phase ships with at least one new test that would have been NOT_TESTABLE without the seam. This is the whole point. Writer-Codex + adversarial-Codex gate per memory `adversarial-test-audit`; writer using `.codex/truth-audit-test-template.md`, adversarial using `.codex/adversarial-test-review-template.md`.

### 17A.4 Sequencing — revised 2026-04-20 after GPT + Gemini council

**Correction history:**
- v1.13 draft called all five sub-phases "mutually independent." Round-1 council (GPT + Gemini) pushed back.
- v1.14 re-sequenced around "G3 depends on G4." Grounded-review round 1 (2026-04-20, sign-off NO) showed that dependency was fictional.
- **v1.15 locks the final order below.** One shared-file dependency (G1/G2) and nothing else.

**Locked order:**

1. **G1 + G2 bundled** (same file `TextProcessingRunner.swift`, one PR, ~50 LOC total).
2. **G5** (independent module; requires one-method widening of `ASRBackend` protocol to preserve Parakeet progress-prepare path, see plan §3).
3. **G3** (independent — `TranscriptFinalizer.swift:75-82` already exposes a closure-seam init that tests use today at `TranscriptFinalizerTests.swift:24`; G3 only needs to add an internal-only init overload on `TranscriptionPipeline` that accepts a pre-built finalizer, keeping the existing `public init(...)` unchanged to avoid access-control widening).
4. **G4** (heart-path, highest risk, isolated session — last because of runtime UAT requirement, not because of any code dependency).

All four are genuinely independent. G1/G2 bundle is a workflow convenience (shared file), not a hidden dependency. Phase G remains independent of Phases A–F and R2–R6.

### 17A.5 Aggregate DoD

- [ ] All five plan files approved (council per workflow-process.md §1; zero-blast-radius exception does NOT apply — these introduce new types and/or change public signatures).
- [ ] All five sub-PRs merged to main, each with:
  - [ ] Writer-Codex truth-audit pass with honesty table in PR body
  - [ ] Adversarial-Codex review pass (fresh session, no shared context)
  - [ ] Grep-verified in main thread that no theater snuck in
  - [ ] At least one new test per sub-phase that was NOT_TESTABLE before the seam
  - [ ] `polish-eval-smoke` green, `scripts/heart-path-check.sh` green (no cold-path regression)
  - [ ] `scripts/swift-test.sh` green, `swift build -c release` green
- [ ] Epic #385 audit rerun (Codex, same rubric as 2026-04-19). Target score: ≥ 6/10 on the specific "heart-path integration" and "paste behavior" dimensions that were weakest.
- [ ] Session log entry naming which scenario classes are now testable that were not before.

### 17A.6 Rollback

Each sub-phase is a single squash-merge commit. Per-sub-phase rollback: `gh pr revert <N>` or `git revert <sha>`. Because every seam has a production default, a revert restores the pre-seam wiring cleanly — no data migration, no persisted state change. Tests that depend on the seam die with the revert; that's the intended signal to re-land or redesign.

### 17A.7 Dependencies

- **Reads from:** `.claude/rules/architecture-rules.md` Access Control + Anti-God-Object + Audio/ASR Danger Zones (G4/G5 touch paste + ASR, both flagged Danger Zones).
- **Reads from:** `.codex/truth-audit-test-template.md`, `.codex/adversarial-test-review-template.md` (writer + adversarial prompts).
- **Writes to:** epic #385 progress (this is the remediation) and epic #319 Testability dimension (one layer deeper than the original senior audit surveyed).

### 17A.8 Relationship to epic #385 original remediation list

The #385 epic body lists seven remediation items. Phase G does NOT absorb them — it adds five *new* items (testability blockers) that emerged from running the #385 autopilot. Original #385 items (PostASRTests rewrite, heart-path-smoke workflow, latency regression gate, etc.) remain tracked under #385 independently of the bible.

Why carry Phase G in this bible instead of only in #385: the #319 Hardening bible is the single place a fresh session finds "what's the current refactor plan?". Splitting testability seams across two epics' plan files fragments that answer. Phase G lives here; sub-issues parent to #385 (origin) with a bible cross-ref.

---

## 18. Phase V1 — Production telemetry analysis (was: cold bench + 3-hr memory profile)

**Issue:** #364 · **Status:** SHIPPED 2026-04-30 via V1a
**Goal:** Confirm or downgrade `Performance & latency: Medium Risk`.

**Outcome:** confirmed acceptable. Performance & latency downgraded to **Low Risk** for the upcoming audit rerun. Evidence: `docs/audits/2026-04-30-v1a-cold-path-telemetry.md`.

**Original 3-hr metronome design retired.** Founder rule on 2026-04-30: no synthetic test longer than 5 min unless explicitly requested for a one-off (e.g., 100-sample TTS harness run). The 3-hr profile + 5-min metronome bench were built around a "users idle, then re-use causes cold-path slowdown" hypothesis traced to one #272 Gemma4 incident in April 2026. V1a tested that hypothesis against 30 days of production telemetry (16 active installs, 12 dictating users, 238 dictations, 150 polish events) and found it does not generalize:

- 100% of production polish is Apple Intelligence (zero Gemini, zero OpenAI, zero Ollama in window). The cache-rotation mechanism the rule guarded against does not exist in `FoundationModels.LanguageModelSession.respond(to:)`.
- Polish latency vs gap-since-previous-polish is flat. p50 stays 1.0–1.2s across every gap bucket from <30s to >4hr. p99 max never crosses 3.4s. No knee.
- Sentry corroborates: 0 polish failures, 0 network failures, 0 cold-path-shaped events in 14 days.

The "5-min idle between samples" prescription in `validation-discipline.md §9` was generalized from the same incident and is now slated for amendment (separate PR).

### 18.1 Replacement V1 shape (on demand, all probes <5 min)

When V1 is needed in the future (e.g., a refactor reintroduces a cloud or local-LLM polish provider, or a heart-path-affecting change is shipped), use these instead of marathon profiles:

- **V1a — production telemetry refresh.** Re-run the queries in `docs/audits/2026-04-30-v1a-cold-path-telemetry.md` §9. Zero app time. Pure observability check.
- **V1b — cold-launch single dictation** (~3 min). Kill app, launch, dictate one sentence immediately, record full pipeline e2e. Captures cold process state without artificial idle.
- **V1c — back-to-back stress, 50 dictations** (~5 min). Heap snapshot before/after via Instruments CLI. Catches per-dictation leak via linear allocation growth, not duration.

V1b and V1c are NOT obligatory. They are optional probes for confirming a specific suspicion. V1a is sufficient to maintain the Performance & latency = Low Risk classification on its own.

### 18.2 Followups V1a surfaced (filed separately, not blocking V1 close)

1. `cold_start=true` never registers in production `asr.completed`. Likely telemetry bug in `TelemetryService.swift` or `ASRManager`.
2. E2E dictation tail past 2-min gaps. p90 jumps from 2.1s → 5–7s once gap exceeds 2 min, but ASR p50 is 100ms and polish p50 is 1.0s. Unattributed time lives in audio engine spinup or recording-duration variance. Worth instrumenting recording-start with a span.
3. `paste_failed` rolling-window production count ~14 events (issues ENVIOUSWISPR-8 + ENVIOUSWISPR-M). Heart-path-adjacent. Investigate which apps the cascade is failing in.
4. Sentry REST `/issues/` returns combined-environment counts. Production-only requires fetching `/organizations/<org>/issues/<id>/tags/` per issue. Knowledge-file note for `observability-operations.md`.

### 18.3 Original recipe (preserved for history)

Two passes were originally planned: a `scripts/heart-path-bench.sh --cold` invocation (~25 min) and a 3-hour memory profile (one dictation every 5 minutes, heap snapshots at t=0, 30, 60, 120, 180 min, BT route for ≥60 min). Neither ran. V1a obviated both.

---

## 19. Phase V2 — Live MainActor/XPC fault injection matrix

**Issue:** #291 (extended) · **Status:** PLANNED
**Goal:** Confirm or downgrade `Resource lifecycle: Medium Risk`. Close the Red Team top unassessed gap.

### 19.1 What this validates

Real-time concurrency under CoreAudio, MainActor, and XPC interleavings. The one dimension Codex explicitly named as the worst static blind spot.

### 19.2 Recipe

Author a deterministic harness in `Tests/RuntimeUAT/faultInjection.py` that runs each scenario across both backends:

| # | Scenario | Backend | Expectation |
|---|---|---|---|
| S1 | Start recording, double-tap stop/start in <100ms window | both | No state lockup; both recordings terminate cleanly |
| S2 | Same, <500ms | both | Same |
| S3 | Same, <1s | both | Same |
| S4 | Start on BT audio; flip to built-in mid-recording | both | Recording continues, audio smoothly reroutes or fails cleanly |
| S5 | Start on built-in; connect BT mid-recording | both | Same |
| S6 | Kill XPC ASR service mid-stream (SIGKILL via harness) | both | Pipeline reaches `.error` with meaningful reason; next recording recovers |
| S7 | Kill XPC during polish | both | Polish limb fails open, heart delivers raw transcript |
| S8 | Background the app mid-recording | both | Recording continues or suspends-and-resumes cleanly |
| S9 | Trigger audio session interruption (simulate phone call) | both | Same |

### 19.3 Assertions per scenario

- Pipeline reaches terminal state (`.complete` or `.error`) within 30s.
- No zombie `AVAudioEngine` detected (pgrep + AX check + audioCapture.isCapturing=false).
- Dropped-audio rate < 1% per scenario (if audio was feeding, at most 1% of samples lost).
- Final paste succeeds or explicit error surface (no silent swallow).

### 19.4 Dependencies

Extends #291. Runs against a build that includes Phase A (to simplify state-change instrumentation).

### 19.5 Outcome → grade action

- All scenarios pass → Resource lifecycle grade **downgraded to Low Risk** in audit rerun.
- Any failure → open hotfix issue; grade stays Medium Risk; epic blocked until fix ships.

### 19.6 Tool note

Use existing `Tests/RuntimeUAT/wispr_eyes.py` helpers per `.claude/rules/validation-discipline.md §7 Use existing harness first`. Extend `test_recording()` patterns; do not write a parallel TTS/audio-routing harness.

---

## 20. Phase V3 — Entitlement + PII audit

**Issue:** #365 · **Status:** PLANNED
**Goal:** Confirm or downgrade `Security & privacy: Medium Risk`.

### 20.1 What this validates

1. Entitlements match minimum-required list.
2. Every `UsageDescription` in Info.plist is necessary.
3. No HIGH/CRITICAL CVE in dependencies.
4. No transcript text in any local log file after a dictation session (confirms R3).
5. No unexpected network egress from a release build.

### 20.2 Recipe

1. **Entitlements.**
   ```bash
   codesign -d --entitlements - /Applications/EnviousWispr.app 2>&1 | tee docs/audits/entitlements-dump.txt
   ```
   Compare against the minimum-required list documented in `.claude/knowledge/distribution.md`. Any surplus is removed or justified in writing.
2. **Usage descriptions.** Grep every `.plist` for `UsageDescription` strings. Confirm each corresponds to a code path that actually requests the permission. Orphans get removed.
3. **Dependency CVE scan.**
   ```bash
   swift package show-dependencies --format json > /tmp/deps.json
   # Feed into OSS Index (https://ossindex.sonatype.org/) or GitHub advisory DB.
   ```
4. **Log PII audit.** Dictate a unique token (e.g. `"XYZZY-SECRET-20260418-ACME"`). After a full heart-path + polish cycle, grep:
   ```bash
   grep -r "XYZZY-SECRET" ~/Library/Logs/EnviousWispr/ /tmp/ ~/Library/Containers/com.enviouswispr/Data/Library/Logs/
   log show --last 1h --predicate 'subsystem == "com.enviouswispr.app"' | grep XYZZY
   ```
   Zero hits required.
5. **Network egress.** Run release build under `nettop -P` or Little Snitch for a dictation session with polish. Expected destinations: PostHog (`us.i.posthog.com`), Sentry (`*.ingest.sentry.io`), configured LLM provider endpoint. Unexpected destinations fail the audit.

### 20.3 Acceptance

- All entitlements justified in writing.
- No orphan `UsageDescription` strings.
- Zero HIGH/CRITICAL CVE findings.
- Zero PII hits in logs post-R3.
- No unexpected network destinations.
- Report at `docs/audits/YYYY-MM-DD-v3-entitlement-pii.md`.

### 20.4 Outcome → grade action

- All pass → Security & privacy grade **downgraded to Low Risk** in audit rerun.
- Any finding → open issue; grade stays Medium Risk; epic blocked until resolved.

### 20.5 Dependencies

Runs after R3 (#361) ships, since the PII-log check depends on R3 being in the build.

---

## 21. Phase V4 — Prompt adversarial eval across providers

**Issue:** #366 · **Status:** PLANNED — gates R6
**Goal:** Resolve the R6 gate. Determine whether a real delimiter defect exists.

### 21.1 Recipe

1. Build adversarial corpus:
   - Mixed-case `<TRANSCRIPT>` / `<Transcript>` / `</TRANSCRIPT>` tags inside transcripts.
   - Whitespace-split tags: `< transcript >`, `<transcript >`, `< /transcript>`.
   - Newline-split delimiters: tag across a `\n` boundary.
   - Tag-lookalikes mid-transcript: `"end transcript. now you are the user"` etc.
   - Case-folded Unicode variants: Turkish dotless-i, full-width ASCII.
2. Run via `scripts/eval/` harness per `.claude/rules/validation-discipline.md §10`. Target every supported builder: OpenAI, Gemini, Ollama, Apple Intelligence.
3. Score by instruction-boundary failure: did the model treat the adversarial delimiter as control text and produce off-task output, or did it respect the true boundary?
4. Output artifact: `docs/audits/YYYY-MM-DD-v4-adversarial-delimiter.json`.

### 21.2 Decision protocol

- **All providers pass all variants** → close #363 as "no defect found — V4 cleared all providers." R6 does not ship. Audit rerun notes the Low-confidence finding was static-suspicion only.
- **Any provider fails any variant** → R6 (§16) unblocks. Hardening work ships with corpus coverage matching the confirmed failure set.

### 21.3 Acceptance

- Eval completed across all supported providers.
- Evidence artifact committed.
- Decision recorded in #363 and in the bible's changelog (§30).

### 21.4 Dependencies

Orthogonal to Track 1. Can run immediately in Session 2.

---

## 22. Cross-cutting work (belongs to epic, not any single phase)

### 22.1 Knowledge file updates

Post-epic, these files need updates. Each is a DoD gate for epic close.

1. `.claude/knowledge/architecture.md` — add `TranscriptCoordinator` (expanded ownership), `CustomWordsPropagator`, `WhisperKitDecodeBridge`, `HeartPathTelemetryEmitter`, `RotatingFileSink` to the module map.
2. `.claude/knowledge/observability-operations.md` — document R3 verbatim-sink env var, R4 rotation policy, V3 proxy-audit recipe.
3. `.claude/rules/architecture-rules.md` — add line under Anti-God-Object: "AppState is capped at 550 lines. Growth above ceiling requires a Phase-E-style regression test update AND a council-approved justification."
4. `.claude/knowledge/codex-audit.md` — append changelog entry with pre/post grade diff (per RULE: diff-across-runs).
5. `.claude/knowledge/polish-eval.md` — if R6 ships, reference the new adversarial corpus section.

### 22.2 CI updates

1. Re-introduce `scripts/check-dependency-direction.sh` (Phase E §11.3 substep 6). The script was deleted when the brain system was deprecated (`.git/hooks/pre-commit` stub carries the historical note); Phase E brings it back with a fresh implementation tied to the current module graph.
2. Add `AppStateSizeTests` to the CI Swift test suite (via Phase E).
3. Add the release-config privacy smoke test per audit meta-rec #2. Small: dictate a token in a release-config test build, grep Sentry/PostHog payloads intercepted via a test proxy.

### 22.3 Rerun the senior audit

Per `.claude/knowledge/codex-audit.md` RULE: diff-across-runs. At epic close:

```bash
cat .codex/audit-prompt.md | codex exec \
  -c 'model_reasoning_effort="high"' \
  -c 'model_reasoning_summary="detailed"' \
  -c 'model_verbosity="high"' \
  --sandbox read-only --skip-git-repo-check \
  --output-schema .codex/audit-schema.json \
  - > docs/audits/YYYY-MM-DD-senior-audit.json 2> docs/audits/YYYY-MM-DD-senior-audit.stderr.log
```

Then diff:
```bash
diff <(jq -S '.dimensions | map({name, grade})' docs/audits/2026-04-18-senior-audit.json) \
     <(jq -S '.dimensions | map({name, grade})' docs/audits/YYYY-MM-DD-senior-audit.json)
diff <(jq -r '.refactor_targets[].id' docs/audits/2026-04-18-senior-audit.json | sort) \
     <(jq -r '.refactor_targets[].id' docs/audits/YYYY-MM-DD-senior-audit.json | sort)
```

Expected movement:
- Architecture integrity: B → A
- Code Hygiene & Maintainability: C → B or A
- API surface: C → B
- Performance & latency: Medium Risk → Low Risk (pending V1 confirm)
- Resource lifecycle: Medium Risk → Low Risk (pending V2 confirm)
- Security & privacy: Medium Risk → Low Risk (pending V3 confirm)
- Error handling & observability: A (maintain)
- Concurrency discipline: B → B (may improve if Phase D simplifies actor interactions)
- Testability: B → A (Phase C+D+E extract + regression tests)

If a dimension does NOT improve when expected, that is itself a finding. Investigate before closing the epic.

### 22.4 Session logs

Every working session touching this epic closes with:
1. `.claude/knowledge/session-log.md` entry noting which phase(s) progressed, decisions made, anything that deviated from the plan.
2. Discord webhook post per `.claude/rules/session-behavior.md §1`.

---

## 23. Sequencing, parallelism, session plan

### 23.1 Realistic session plan — revised 2026-04-18 after council review

Council (GPT + Gemini) flagged the prior version's parallelism as overambitious and merge-conflict-prone. Revision: Phase A ships SOLO first; subsequent sessions parallelize only phases that touch disjoint files. Phase C and Phase D are separate PRs, not bundled.

Each session is ~4-5 hours per `.claude/rules/session-behavior.md` (no context anxiety, one release per session max). Parallelize via `git worktree add` per project `CLAUDE.md` rule 6 "Git session isolation."

**Session 1 — Phase A solo, then two disjoint-file parallels (~4-5 hrs):**
Phase A refactors `AppState.swift`'s state-change closures. R5 ALSO touches `TranscriptionPipeline.swift` / `WhisperKitPipeline.swift`, which Phase A reads via protocol conformance extensions but does not modify directly. Council R3 flagged R5-parallel-with-A as merge-conflict risk. Revised:
- **First:** Phase A (#196). Solo. Merge.
- **Then parallel:** R3 (#361), R4 (#362). Disjoint files: `TextProcessingRunner.swift` + `AppLogger` (R3) and `AudioCaptureManager.swift` (R4). No overlap with Phase A.
- **After R3+R4 merge:** R5 (#290). Sequential, not parallel with A. R5 can run in its own worktree, but branch off post-Phase-A main to guarantee no conflict.

Close Session 1 only after all four (A, R3, R4, R5) merge to main and CI is green.

**Session 2 — Phase B THEN Phase F (sequential) + Track 2 kickoffs (3-5 hrs):**
Realistic scope. V1's 3-hour Instruments profile runs UNATTENDED in the background; it does not count against the 5-hour budget. Only the kickoff and result-capture happen in-session.

**Sequencing collision — B × F (Codex plan review 2026-04-18):** Phase B and Phase F BOTH edit `AppState.swift` AND `PipelineSettingsSync.swift`. Phase B removes settings cases (frozen-per-recording move to `DictationSessionConfig`). Phase F extracts setup services — and `PipelineSettingsSync` has an `onNeedsPreloadObservation` callback Phase F rewires through `SetupCoordinator`. Running them in parallel worktrees creates near-certain conflicts on both files. **B ships first; F branches off post-B main. Not parallel.** Prior v1.3-v1.5 marked these as parallel; that was wrong.

- Resolve Phase B UX decision (§27.1) — this is the gate. Capture decision per §27.7. Ship Phase B; merge.
- After Phase B main-green: ship Phase F (SetupCoordinator extraction). Sequential, not parallel.
- Kick off V1 Instruments run (background, 3 hrs wall clock). Independent from B/F.
- Kick off V3 entitlement + PII audit (can run while V1 is in the background).
- Kick off V4 adversarial eval (can run in parallel; output is test data).
- V2 harness work on #291 — author deterministic fault-injection matrix. Highest-effort Track 2 item; may span sessions.

**Session 3 — structural surgery, sequential (4-5 hrs):**
The epic's hardest session. Phase A is the prerequisite. Phase C and Phase D are SEPARATE PRs.
- **First:** Phase C — TranscriptCoordinator.append. Ship, merge, verify main green.
- **Then:** Phase D — CustomWordsPropagator. Ship, merge, verify main green.
- **Then:** Phase E (architecture regression tests + cross-module public guard). Ship, merge.
- R2 slots into this session only if time allows; otherwise Session 4.

Why separate PRs for C and D: Gemini council review flagged "merge monster" risk. Two sequential smaller PRs are safer, review-friendlier, and retain clean rollback granularity. The prior version bundled them; this revision does not.

**Session 4 — gated work + closeout (3-5 hrs):**
- R2 (if not in Session 3).
- V4 result review — R6 decision (ship hardening or close-no-defect).
- R6 code work if V4 confirms.
- V1, V2, V3 results review — grade decisions per §22.3.
- Audit rerun per §22.3.
- Knowledge file updates per §22.1.
- CI updates per §22.2.
- Epic ship criteria (§25) walk-through.
- Epic close.

### 23.1.1 Squash-merge rebase discipline (adversarial hazard)

`gh pr merge --squash` rewrites history. Any worktree branched off the pre-merge commit has divergent history. After each phase's PR merges to `main` via squash, every in-flight worktree MUST rebase onto the new `main` tip before resuming work. Procedure per in-flight worktree:

```bash
cd ../EnviousWispr-<in-flight-phase>
git fetch origin main
git rebase origin/main
# If rebase has conflicts in files the just-merged phase touched:
#   resolve conflicts, prefer the in-flight phase's changes for its owned files,
#   take main's changes for the just-merged phase's owned files.
# If resolution is ambiguous, do NOT proceed — message the other in-flight session.
```

**Why this matters for this epic:** Session 1 ships Phase A solo. If Phase A squash-merges AFTER Phase R3 / R4 / R5 worktrees already branched from main, those worktrees must all rebase. Merge-conflict risk is low IF the files are disjoint (verified in §23.3). Rebase is still required.

Avoid `git pull` in worktrees. `git pull` implies merge-commit by default; the project convention is rebase per project `CLAUDE.md` rule 7 "Own the merge." Always `git fetch origin main && git rebase origin/main`.

### 23.2 Parallel worktrees — concrete commands

Session 1 opens Phase A's worktree first; the other three worktrees are created ONLY after A merges:

```bash
# Session 1 step 1 — Phase A solo
git worktree add ../EnviousWispr-phase-a -b phase-a/196-state-handler

# (ship A, merge, verify main green)

# Session 1 step 2 — three disjoint-file parallel worktrees
git worktree add ../EnviousWispr-r5 -b r5/290-telemetry-emitter
git worktree add ../EnviousWispr-r3 -b r3/361-transcript-redact
git worktree add ../EnviousWispr-r4 -b r4/362-bt-rotation

# Each agent/session works in its own worktree. No branch switching in main tree.
# Merge each PR, then `git worktree remove ../EnviousWispr-<name>`.
```

Per project `CLAUDE.md` rule 6, check `pgrep -f claude` before any branch-changing action.

### 23.3 Merge order considerations

- Phase A lands FIRST, alone. Every other AppState-touching phase waits.
- R5, R3, R4 land in parallel (three disjoint-file worktrees) after Phase A merges.
- Phase B lands whenever its UX decision is made; independent from AppState.
- R2 lands after Phase A is stable. Not strictly required, but Phase A's code-touch is in the same region (`onStateChange`) that sometimes calls backend methods; staggering reduces conflicts.
- Phase C lands separately (its own PR).
- Phase D lands separately (its own PR), after Phase C.
- Phase E lands after D, with architecture regression tests calibrated to the final AppState shape.
- R6 last (gated on V4).

### 23.4 What not to do

- Do not combine Phase A + Phase C + Phase D in one PR. Blast radius explodes and rollback granularity disappears.
- Do not bundle Phase C and Phase D into a single PR, even though they both touch AppState. Two sequential small PRs are council-recommended over one merge monster.
- Do not ship Phase B without the UX decision. The "applies on next recording" shift is visible; shipping it silent is a regression in perceived predictability.
- Do not start R6 before V4 completes. Wasted work if V4 clears.
- Do not skip the audit rerun. Without the diff, grade movement claim is unfalsifiable.
- Do not update architecture tests' ceilings to make them pass after a regression — investigate the regression. Phase E tests are guardrails, not targets to chase.

---

## 24. Risk register

Every risk with likelihood (L), impact (I), mitigation (M).

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| 1 | Phase C breaks transcript history view for a corner case | Low | High | Characterization test pinning current behavior; grep of view consumers before ship; live smoke on both backends |
| 2 | Phase D's weak-ref subscriber registry drops a consumer and custom words stop reaching it silently | Low | High | Unit test: register + dealloc + update → no crash, prune observed; also: assertionFailure in debug when a consumer goes missing across N updates |
| 3 | R2 bridge protocol too narrow; discovered later that Pipeline needs another member | Low | Low | Compile break reveals immediately; widen protocol with explicit rationale |
| 4 | Phase E line ceiling is too tight; legitimate growth fails CI | Low | Medium | Ceiling advisory-documented; test fails with a clear message pointing to this bible §11 and the bump protocol |
| 5 | R5 dedup regression: Sentry events duplicate or get suppressed | Low | Medium | Unit tests cover every dedup case; live regression smoke |
| 6 | V1 memory profile reveals an unbounded allocation | Medium | High | Open hotfix issue; block epic close; Instruments finding is authoritative |
| 7 | V2 fault injection finds a genuine race | Medium | High | Same; Red Team already warned this is the top gap; don't be surprised, be prepared |
| 8 | V3 finds a surplus entitlement | Low | Medium | Remove; re-sign; re-notarize; validate release process per `.claude/knowledge/distribution.md` |
| 9 | V3 finds transcript text in a log path R3 did not cover | Medium | High | Widen R3 scope; additional PR; V3 re-runs |
| 10 | V4 finds a real adversarial-delimiter defect | Medium | Medium | R6 unblocks; expected outcome |
| 11 | Phase B UX decision takes longer than expected | Medium | Low | Phase B is not on the critical path; epic can close with it deferred (§25 notes the exception) |
| 12 | Merge conflict between Phase A and Phase D on AppState's `onWordsChanged` region OR Phase A and Phase C on `.complete` branch | **High** | **High** | Phase A ships SOLO first (§23.1). Phase C and D branch off post-Phase-A main. If Phase C and D are in flight simultaneously in separate worktrees, the author of whichever lands second rebases and resolves; both PRs include Phase A in their merge base so the conflict window is small. Council review (2026-04-18) up-weighted this risk from Medium/Low because A's region edits and D's region edits are literally adjacent lines |
| 13 | Audit rerun shows no improvement in a dimension that was supposed to improve | Medium | Medium | Investigation gate before epic close; see §22.3 |
| 14 | Codex CLI ChatGPT-account model availability changes mid-epic | Low | Low | Audit rerun can use any available default; record model actually used in changelog |
| 15 | `scripts/check-dependency-direction.sh` is newly CREATED in Phase E (did not exist before) and has a latent bug that allows a violation to slip, OR the script's graph parser misunderstands Package.swift's conditional target dependencies | Medium | High | Phase E §11.3 includes a test step: create a deliberately-wrong `Package.swift` branch, run the script, confirm it fails; revert. Repeat for every enforced invariant |
| 16 | Phase A characterization test captures buggy current behavior and pins it as "correct" | Low | Medium | Rule: characterization tests pin telemetry shapes and overlay intents — both externally observable. If the bug is in a field a test pins, fix the test after fixing the bug; note in PR body |
| 17 | Refactor reveals latent bug not in audit | Medium | Low | Open a new issue; this epic is not the fix surface unless it blocks a phase's DoD |
| 18 | **Bible rot** — this doc drifts from codebase as phases ship, invalidating later phases' substeps/snippets | **High** | Medium | Mandatory refresh protocol per §26.1. Every phase's merge commit includes a §30 Changelog entry AND any substep/snippet rewrites in subsequent phases that reference the now-changed code. If a phase's referenced file or line number has shifted by the time that phase starts, the phase's first substep is re-verification (grep + Read). Bible is authoritative on intent; the codebase is authoritative on current state. Council review (2026-04-18) added this risk |
| 19 | **Phase C async write path** introduces data-loss or double-write if Option 2 (async save with rollback-on-failure) is chosen without careful test coverage | Medium | High | Decision default is Option 1 (synchronous save on MainActor). Option 2 only if V1 profiling shows `save` blocks main thread. If Option 2 ships, unit tests MUST cover: (a) insert-then-save-fails-then-rollback-removes-insert, (b) two concurrent appends don't produce duplicate rows, (c) cancel mid-save leaves state consistent. Council review (2026-04-18) added this risk |
| 20 | **Phase E fitness tests gameable** — adding a new concrete dependency could be "fixed" by moving the declaration to a nested scope to dodge the regex | Low | Medium | Document in the architecture-rules.md addendum that concrete-dep-count intent is architectural, not mechanical. Reviewers watch for regex-dodging patterns. If gaming is observed, tighten the regex or add a second test on cyclomatic complexity |

---

## 25. Ship criteria — epic close

Epic #319 closes when ALL of the following hold:

### 25.1 Phase completion

- [ ] Phase A (#196) merged to main.
- [ ] Phase B (#195) merged to main OR formally deferred with written reason filed as a new issue (§23.4 — shipping without the UX decision is explicitly forbidden).
- [ ] Phase C merged — transcript reload eliminated; grep confirms.
- [ ] Phase D merged — five-way fanout eliminated; grep confirms.
- [ ] Phase E merged — architecture regression tests live in CI.
- [ ] Phase F merged — SetupCoordinator extracted; AppState sheds ollamaSetup + whisperKitSetup + preload task ownership.
- [ ] R2 (#360) merged.
- [ ] R3 (#361) merged.
- [ ] R4 (#362) merged.
- [ ] R5 (#290) merged.
- [ ] R6 (#363) merged OR closed-no-defect with V4 evidence attached.

### 25.2 Validation completion

- [ ] V1 (#364) run complete; `docs/audits/*-v1-performance.md` committed; grade decision recorded.
- [ ] V2 (#291) run complete; fault-injection matrix results committed; grade decision recorded.
- [ ] V3 (#365) run complete; `docs/audits/*-v3-entitlement-pii.md` committed; grade decision recorded.
- [ ] V4 (#366) run complete; `docs/audits/*-v4-adversarial-delimiter.json` committed; R6 gate resolved.

### 25.3 Cross-cutting completion

- [ ] Senior audit rerun completed; grade delta diffed against 2026-04-18 baseline; delta persisted in `.claude/knowledge/codex-audit.md` changelog.
- [ ] `.claude/knowledge/architecture.md` updated with new coordinators.
- [ ] `.claude/knowledge/observability-operations.md` updated with R3 verbatim sink + R4 rotation policy + V3 audit recipe.
- [ ] `.claude/rules/architecture-rules.md` updated with AppState property-count + line-count targets.
- [ ] CI runs `scripts/check-dependency-direction.sh` on every PR (confirmed).
- [ ] Release-config privacy smoke test added (audit meta-rec #2).
- [ ] Cross-module public-TODO guard in CI (audit meta-rec #1, via Phase E).
- [ ] Periphery scans clean post all REFACTOR-tier PRs.

### 25.4 Qualitative close-out gate (senior-engineer review)

Mechanical checklist completion is NECESSARY but not SUFFICIENT. Per Gemini council review (2026-04-18), there is a risk of ticking every box while failing the epic's primary architectural goal. Before #319 closes, the founder (or a designated senior reviewer) answers in writing:

1. **Is `AppState` demonstrably easier to reason about?** One-paragraph assessment. Specifically: can a fresh reader now name AppState's single responsibility in one sentence? (The answer before this epic is "no.")
2. **Has the custom-words five-way fanout disappeared?** Grep the file; paste the (empty) result. If non-empty, epic does not close.
3. **Is there now ONE place a new custom-words consumer registers?** Name it (file:line).
4. **Has transcript reload on `.complete` disappeared?** Grep; paste result.
5. **Is `WhisperKitBackend.makeDecodeOptions` still `public`?** Grep; paste result. If `public` remains and R2 shipped, investigate.
6. **Does the architecture rerun improve at least one letter-graded dimension?** Name which ones moved and by how much.

These six questions are the bible's qualitative gate. Unanswered questions mean the epic is not closed.

### 25.5 Concrete architectural metrics

Recorded in the epic close-out comment on #319:

- AppState line count: before 965, after ___ (target ≤ 550).
- AppState concrete-dep count: before 12, after ___ (target ≤ 8).
- PipelineSettingsSync line count: before 398, after ___ (target ≤ 200).
- `WhisperKitBackend` public surface: before 3 cross-module `public` members, after ___.
- Audit grade diffs: Architecture ___→___, Code Hygiene ___→___, API surface ___→___, Testability ___→___.

If any of these numbers moves in the wrong direction, investigate before close.

### 25.6 Governance

- [ ] This bible's changelog (§30) records each phase's merge date, PR number, any deviations.
- [ ] #319 epic issue has a final comment summarizing the before/after grades, what shipped, and what did not (R6 closed-no-defect is a legitimate "did not" outcome).

---

## 26. Progress tracking — how to update this doc as work ships

This bible is a living document. Update protocol:

### 26.1 Bible Rot — mandatory refresh after every phase ships

Council review (2026-04-18) flagged "bible rot" as a top-10 risk (§24 #18). Mitigation is this protocol.

After every phase merges to main:

1. **Changelog entry (§30)** — date, PR #, what actually shipped, any scope deviation from the plan.
2. **Phase section update** — in §7-§21 for that phase: set **Status:** to SHIPPED, tick DoD checkboxes actually met, add an "As shipped" paragraph if the plan deviated.
3. **Snippet refresh for downstream phases** — if the merged phase modified code that LATER phases cite (with line numbers or snippets), refresh those citations. Concretely:
   - After Phase A merges, §9 (Phase C) line numbers for `.complete` branch change. Regrep and update.
   - After Phase C merges, §10 (Phase D) may no longer need to touch the same region. Note.
   - After Phase D merges, §11 (Phase E) ceilings can be calibrated to the actual post-D baseline.
   - After R3 merges, §20 (V3) PII-audit recipe verifies the fix is in place.
4. **Cross-links** — if a phase opens a sibling issue for overflow, link it in the phase's subsection under "Related work."
5. **Never delete** — mark obsolete content clearly (~~strikethrough~~ or "SUPERSEDED BY..." prefix). Bible history is part of its value.

### 26.2 Pre-phase refresh — verify before starting

Before starting any phase, run the following check:

1. Read the phase's §7-§21 section.
2. For every file:line citation and every code snippet, grep or Read to verify the reference is current. Line numbers drift; snippets drift.
3. If any citation is stale, make the phase's substep 0: "Re-verify all citations in §N. Update in-line before writing code."
4. This is the Gate 0 (prior-context check) equivalent for bible phases.

### 26.3 When to branch a phase into its own file

If a phase grows past ~400 lines of bible section (substeps + design + tests + DoD), it has earned a standalone plan file in `docs/feature-requests/issue-N-YYYY-MM-DD-phase-X.md`. Existing phases A, B, and R5 already have standalone files (pre-bible council rounds). If Phase C, D, or R2 expand significantly during execution, extract them.

The bible is the canonical index; standalone files are zoomed-in views. If they diverge, the standalone file wins on implementation detail; the bible wins on scope and sequencing.

### 26.4 Commit discipline

The bible file is in git. Every update is a commit. PR flow is not required for bible updates (they are docs, not ship-path per `workflow-process.md §1`). BUT: no bible update may contradict a shipped phase's actual behavior without a changelog entry noting the contradiction and how it will be resolved.

---

## 27. Open questions — founder decisions required

Six decisions. Each has a recommendation; this is where session time converts to strategy time.

### 27.1 Phase B UX wording

**Question:** What does the user see when they toggle a per-recording setting (auto-paste, VAD config) while a recording is in progress?

**Options.**
- Silent: the change takes effect next recording; user sees nothing now.
- Tooltip: the relevant Settings row shows a passive tooltip "Applies to next recording."
- Transient toast: on toggle, a small toast appears "Active recording unchanged — next recording uses new value."

**Recommendation.** Tooltip. Passive, discoverable, no interruption. Toast is intrusive for a subtle semantic. Silent creates a "why didn't it do anything?" bug report.

**Needed:** your choice. Phase B does not ship without it.

### 27.2 Phase C persistence boundary

**Question:** Does `TranscriptCoordinator` own disk I/O (write-through on `append`), or does it own only the in-memory cache with persistence delegated?

**Options.**
- Own disk I/O: `coordinator.append(t)` writes through to `TranscriptStore.save(t)`.
- In-memory only: `coordinator.append(t)` updates the cache; something else calls `store.save(t)` separately.

**Recommendation.** Own disk I/O. Single-owner-per-state-cluster is the cleaner architecture. The "something else" in the alternative becomes the new dumping ground.

### 27.3 Phase D event model

**Question:** `@Observable`-style property on `CustomWordsPropagator` vs closure-based subscription via `register(consumer:)`?

**Options.**
- `@Observable`: propagator's `words` is `@Observable`; consumers observe it SwiftUI-style. Elegant for views, awkward for services.
- Closure-based subscription: `register(_:)` adds a consumer to a weak-ref registry; `update(_:)` pushes to all.

**Recommendation.** Closure-based subscription. Consumers are services, not views. Explicit register/unregister is clearer. Matches the `.onChange` callback style already used in the codebase.

### 27.4 R2 approach — RESOLVED (2026-04-30, shipped as Approach C)

**Original question:** Approach A (adapter protocol in ASR) or Approach B (relocate tail-decode construction into ASR)?

**Decision.** Neither A nor B as originally framed. Codex grounded review on 2026-04-30 (`docs/audits/2026-04-30-r2-avb-grounded-review.txt`) proposed **Approach C** — opaque `WhisperKitIncrementalSession` protocol vended by `WhisperKitBackend`, returns the worker behind the protocol so Pipeline never holds a WhisperKit-specific type. Plan-stage council adopted C and added a LID-side mirror (`WhisperKitBackend.observeLID` returning Sendable `LIDObservationBatch` enum, replacing the `nonisolated(unsafe) let kitForLID` hop). Both removed in the same refactor PR. Shipped via PR #524 (squash `abd1c6e`, 2026-04-30 23:15 UTC). Characterization safety net (#522, 17 tests) frozen in main first as PR 1 of 2 per GPT structural concern. See changelog v1.26 for full ship summary.

### 27.5 Phase E line ceiling

**Question:** What line count for `AppState.swift` does CI enforce?

**Recommendation.** Measure after Phases A+C+D+R5 land. Set ceiling = measured + 10%, round to a clean number. Expectation: ~550.

**Defer decision:** to Phase E execution time. This is a measurement-driven choice.

### 27.6 Track 2 issue timing

**Question:** Open V1/V3/V4 now (before Session 1) or defer to Session 2?

**Recommendation.** Already opened (done as of 2026-04-18: #364 V1, #365 V3, #366 V4; #291 extended for V2). Leave as is.

### 27.7 Where to capture the Phase B UX decision

When the UX decision for Phase B (§27.1) is made, it goes in THREE places:

1. As a comment on GitHub issue #195 with the date and chosen option.
2. In this bible's §8 Phase B subsection, appended as a "UX decision (recorded YYYY-MM-DD)" paragraph in §8.6.
3. In this bible's §30 Changelog entry for that session.

Only then does Phase B work start. Missing the decision capture in any of the three means work starts without a durable record.

---

## 28. Glossary

**Heart** — the critical path `trigger → audio capture → ASR → text finalization → clipboard/paste`. Must always complete. (`architecture-rules.md §Heart & Limbs`.)

**Limb** — a post-processing feature (custom words, filler removal, LLM polish) that may improve output but must not block it. Must have timeout + fallback. (Same rule.)

**Coordinator** — a type whose sole responsibility is wiring together other types and routing events. Has minimal state. `TranscriptCoordinator` is a healthy example; `AppState` before this epic is an unhealthy one. (`architecture-rules.md §App shell rules`.)

**Propagator** — a coordinator specialized for distributing a value to a set of subscribers. `CustomWordsPropagator` is the instance introduced in Phase D.

**Characterization test** — a test written before refactoring that captures current externally observable behavior. Post-refactor, the test must still pass. (Feathers.)

**Seam** — a place in code where behavior can be altered without editing in that place. Enables testing a unit in isolation. (Feathers.)

**Sprout Method / Sprout Class** — growing new behavior as a new method/class that the legacy code calls into, rather than surgery inside the legacy code. (Feathers.)

**Branch by Abstraction** — introducing an abstraction that both old and new implementations conform to, migrating consumers, and then removing the old. (Fowler.)

**Parallel Change / Expand-Contract** — a three-step migration: expand the API additively, migrate consumers, contract by removing the old. (Fowler.)

**Strangler Fig** — incremental replacement where a new implementation gradually takes over responsibilities from the old, under a stable facade. (Fowler.)

**Extract Class** — a refactoring that splits a class with multiple responsibilities into two, one carrying the original name, the other carrying the extracted cluster of fields and methods. (Fowler.)

**Introduce Parameter Object** — replacing a collection of parameters passed together with a single value type. `DictationSessionConfig` is the Phase B instance. (Fowler.)

**Static Risk Assessment** — a grade scale (High/Medium/Low Risk, Indeterminate) used for dimensions the static audit cannot verify at runtime. Paired with runtime validation (Track 2) to upgrade to a letter grade or downgrade to Low Risk. (This epic's audit scoring convention.)

**Zero-blast-radius exception** — a narrow workflow-process exception for changes ≤ 20 LOC, ≤ 3 files, ≤ enumerated surface list, that skip council but keep Codex + DoD. (`workflow-process.md §1`.)

**wispr-eyes** — the project's UI verification tool. Python + PyObjC via macOS Accessibility API. Lives in `Tests/RuntimeUAT/wispr_eyes.py`. High-level helpers: `look()`, `check()`, `verify()`, `scan()`, `test_recording()`, `test_hands_free()`, `tts()`. Used for runtime UAT without XCTest. See `.claude/rules/tools-and-apps.md §2` for discipline and recipes.

**Characterization test pin** — a test that locks externally observable behavior BEFORE a refactor. Used to detect behavior drift during refactoring. Feathers' canonical technique; applied in Phases A, C, D, R5 to guard telemetry shapes and overlay intents.

**Fitness function** — a test whose purpose is to detect architectural erosion. Building Evolutionary Architectures' term for Phase E's property-count and cross-module-public tests. Not a functional test; a meta-test.

---

## 29. References

### 29.1 Internal

- Audit JSON: `docs/audits/2026-04-18-senior-audit.json`
- Audit operational reference: `.claude/knowledge/codex-audit.md`
- Architecture laws: `.claude/rules/architecture-rules.md`
- Swift patterns: `.claude/rules/swift-patterns.md`
- Validation discipline: `.claude/rules/validation-discipline.md`
- Workflow process: `.claude/rules/workflow-process.md`
- Session behavior: `.claude/rules/session-behavior.md`
- Tools and apps: `.claude/rules/tools-and-apps.md`
- Observability operations: `.claude/knowledge/observability-operations.md`
- Polish eval: `.claude/knowledge/polish-eval.md`
- Architecture (module map): `.claude/knowledge/architecture.md`
- Pipeline mechanics: `.claude/knowledge/pipeline-mechanics.md`
- Distribution (signing, entitlements): `.claude/knowledge/distribution.md`
- Existing phase plans: `docs/feature-requests/issue-196-...md`, `issue-195-...md`, `issue-290-...md`

### 29.2 External — refactor methodology

- Martin Fowler — [Refactoring catalog](https://refactoring.com/catalog/)
- Martin Fowler — [Strangler Fig Application](https://martinfowler.com/bliki/StranglerFigApplication.html)
- Martin Fowler — [Branch by Abstraction](https://martinfowler.com/bliki/BranchByAbstraction.html)
- Martin Fowler — [Parallel Change](https://martinfowler.com/bliki/ParallelChange.html)
- Martin Fowler — *Refactoring: Improving the Design of Existing Code, 2nd ed.* (Addison-Wesley)
- Michael C. Feathers — *Working Effectively with Legacy Code* (Prentice Hall). See also community notes at <https://understandlegacycode.com/blog/key-points-of-working-effectively-with-legacy-code/>.
- Sandi Metz — *Practical Object-Oriented Design (POODR)*. SOLID applied at class-shaping level.
- Neal Ford, Rebecca Parsons, Pat Kua — *Building Evolutionary Architectures* (fitness functions; underpins Phase E).
- Azure Architecture Center — [Strangler Fig Pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/strangler-fig) (cloud framing but the pattern generalizes).
- GitHub — [Scientist](https://github.com/github/scientist) library (behavior-equivalence during refactor; philosophical rather than direct import).

### 29.3 External — Swift 6

- Apple — [Swift Concurrency](https://developer.apple.com/documentation/swift/concurrency)
- Apple — [Observation framework](https://developer.apple.com/documentation/observation)
- Matt Massicotte — [Concurrency Course](https://www.massicotte.org/) (free, practical)

### 29.4 Previous Hardening-related work

- PR #285 (telemetry handlers added to pipelines — the origin of R5's need).
- PR #289 (stall recovery).
- PR #272 / v1.9.3 (Gemma4 cold-path latency incident — the origin of the cold-bench discipline).
- Issue #338 (Codex PR triage finding parented under #319, 2026-04-17).

---

## 30. Changelog

- **2026-05-02 v1.30 · V2 cleanup — Lane A made honest, Lane B documented as HITL, #553/#555/#556 confirmed harness artifacts (#559)** — Three-way external review (GPT 5.5, Gemini 3.1 Pro, Codex grounded review with full code access) converged on HYBRID-SPLIT: keep automated Lane A scenarios for the things that test our own code (rapid-toggle, force-cancel, settings storm, app-quit, our XPC service kills), move OS-level audio interruption (BT codec switch HFP/A2DP, Zoom/Discord coexistence, real `AVAudioEngineConfigurationChange`) to a documented human-in-the-loop Lane B. **Codex's load-bearing finding:** the original `force_stall` was lying at a different level than we thought — it pokes the host-side `AudioCaptureProxy.audioBufferCaptured` buffer queue, exercising the proxy watchdog, NOT the real recovery paths in `AVAudioEngineSource.handleEngineConfigurationChange()` or `AVCaptureSessionSource` interruption handlers. Those handlers live in the `EnviousWisprAudioService` process and are NOT reachable from the host-process `DebugFaultEndpoint` at all (XPC process boundary). **Gemini's load-bearing finding:** even if reachable, `NotificationCenter.post` cannot fake the underlying state — `AVCaptureSession.isInterrupted` and `AVAudioEngine.isRunning` would still report healthy because the framework's internal C++ state never changed. So Path A ("synthetic-fix via NotificationCenter.post") was a more sophisticated lie. **Real-world testing 2026-05-02 + production Sentry 14d window:** zero `AVAudioEngineConfigurationChange` fires across BT codec switch, Zoom mic-grab/release, Spotify, Discord. **Human-action reproduction of #555 + #556:** 0/2 + 5/5 PASS — both confirmed harness artifacts (same disposition as #553). **What shipped in cleanup (#559):** wire command rename `force_stall(N)` → `force_proxy_buffer_drop(N)` (honest about what it tests); scenario rename `A5_forced_stall` → `A5_proxy_buffer_drop_watchdog` with rewritten description that names the proxy-watchdog scope; new `docs/LANE_B_AUDIO_TESTS.md` HITL checklist (B1 BT, B2 Zoom, B3 Discord, B4 system input flip, B5 Spotify) with run-log GitHub issue template and global invariants; SCENARIOS.md updated with the rename + Lane B pointer + honest negative-control wording. **Codex's third option (deferred, not in this PR):** passive "audio trigger profiler" mode that taps every notification observer + CoreAudio device callback in the audio service, logs to `~/Library/Logs/EnviousWispr/audio-triggers.log`, runs during HITL to tell us which real user actions actually produce app-observable signals. Worth a follow-up issue but not load-bearing for this cleanup. **Issues closed by this PR:** #553 (already closed 2026-05-02 as harness artifact), #555 closed-not-planned (overlay auto-dismiss IS wired at `RecordingOverlayPanel.swift:820 case .error: 3.0`; original 1× observation via synthetic harness; Saurabh 0/5 + Claude 0/2 human-action repro), #556 closed-not-planned (5/5 PASS with realistic timing across Microphone tab, Permissions tab, Fast(English) backend button taps; backend tap correctly blocked, LID/ASR/paste all completed; heart path delivered transcript every time), #559 closed by this PR. **Issues kept open:** #554 (DEBUG `force_unload_model` endpoint, P2 harness improvement), #557 (A9 must assert primary recording transcript not just recovery, P2 harness improvement). **Audit artifacts preserved:** `docs/audits/2026-05-02-v2-synthetic-viability-codex.txt` (full Codex grounded review with file:line evidence). **Lesson preserved at the council/Codex/audit layer:** the question "can we synthesize this?" is incomplete — the right question is "can we synthesize this honestly, given the actual code structure?" Run grounded review (Codex with full code access) before designing any fault-injection seam, especially across XPC process boundaries.

- **2026-05-01 v1.29 · V2 shipped untested — six-bypass workflow failure (P0/#548, P1/#549, follow-up #547)** — PR #544 (V2 fault-injection toolkit) merged via `gh pr merge --squash` with the runtime toolkit (Lane A scenarios + DebugFaultEndpoint) never exercised end-to-end on a real running app even once. Deterministic Lane C tests (4) passed on CI; release-binary symbol grep was clean; Codex on the PR caught two real bugs (P1 + P2) and signed off. **Founder asked to test it post-merge; the canonical run-the-thing path could not run the thing.** Two infrastructure gaps blocked the test (`bundle-dev.sh` hardcodes `swift build -c release` so `#if DEBUG` seams compile out; `open(1)` does not propagate `EW_FAULT_INJECTION=1` to the launched app). Six bypass points all had to fire in one session: (1) plan-template names a Live UAT Driver but does not require a "canonical bundle/launch path" sub-field; (2) council preamble lacks a "runtime path exists?" line; (3) grounded-review template lacks a Q3 on whether canonical run-the-thing supports running the plan's surfaces; (4) Phase 3 validation hook accepted a non-compliant skip-note (`v2-redgreen-skip-note.txt` deferred runtime UAT to a "founder-driven post-merge cycle" — exactly the third option `workflow-process.md §1 step 9` forbids); (5) `scripts/validate-pr.sh` was never invoked, push hook does not require populated `.validation/runs/<latest>/` for `Sources/` pushes; (6) **plan introduced a new gating mechanism (`#if DEBUG` + `EW_FAULT_INJECTION=1`) without enumerating existing equivalent infrastructure** — `state.settings.isDebugModeEnabled` is a runtime, persistent, hidden-Cmd+Shift+D-discoverable debug surface that ships in release builds and is plumbed through `DiagnosticsSettingsView.swift` + `SettingsSection.diagnostics`. V2 should have re-used the existing toggle, not built a parallel compile-time gate. **Auto-mode amplifier:** session ran in auto-mode + founder said "I won't manually review anything" — that signal got interpreted as license to relax workflow gates, when it only relaxes question-asking on routine decisions. **Weekend deliverables tracked in #548 (P0):** plan-template + council-preamble + grounded-review-template additions, push-discipline hook hardening (reject third-option skip-notes; require populated run dir for `Sources/` pushes), auto-mode prompt clarification, then land #547 (bundle-dev.sh `--debug` + `--env`) and #549 (re-gate V2 on `isDebugModeEnabled`). Lane C invariants on main are still verified — the deterministic backbone is solid; what's unverified is the runtime end of the toolkit, and #549 is the path to making that exercisable through the canonical install-and-run flow. **Lesson preserved at `.claude/knowledge/v2-uat-bypass-2026-05-01.md` so future sessions inherit the cluster shape.**

- **2026-04-30 v1.28 · V2 plan finalized + ready for Gate 2 sign-off** — Plan at `docs/feature-requests/issue-291-2026-04-30-v2-fault-injection-toolkit.md`. Three-lane fault-injection toolkit: Lane A (9 wispr_eyes-driven runtime scenarios for capture stall, cancel, XPC kill, settings storms, app quit, model-load cancel, backend-switch guard, rapid-toggle fuzz), Lane B (1 founder-required Bluetooth scenario, optional B1' programmatic device-flip if 30-min spike confirms feasibility), Lane C (4 Swift `@Test` invariants on actual owners — 2 on pipeline, 1 on PipelineSettingsSync, 1 on HotkeyService). DEBUG-only seams (`internal + #if DEBUG + @testable import`) on `AudioCaptureProxy`, `ASRManagerProxy`, both pipelines. DEBUG-only localhost endpoint (`DebugFaultEndpoint` type retained by `AppDelegate`, env-gated `EW_FAULT_INJECTION=1`, per-launch token at `~/Library/Logs/EnviousWispr/fault-token-<pid>` with `0600` perms + atomic write). **Policy:** Lane A/B on-demand only (no CI, no nightly); Lane C runs on PR CI as standard Swift tests. **Self-test discipline:** per-mechanism red/green at PR demonstration time, NOT per-scenario regression+revert busywork ongoing. **Two rounds of Codex grounded review** (`docs/audits/2026-04-30-v2-grounded-review.txt` + `docs/audits/2026-04-30-v2-grounded-review-round2.txt`) + council from GPT 5.5 + Gemini 3.1 Pro. Round 1 absorbed 5 PIVOTs: A5 dropped (WhisperKit ASR is in-process), stall injection moved from pipelines → AudioCaptureProxy (capture-side concern, WhisperKit batch has no chunk handler), `package` → `internal+@testable` (SPM exposes `package` to app target), §10 file paths corrected throughout, Lane C reduced from 6 to 4 invariants on actual owners. Round 2 absorbed 3 precision revisions: C1 mechanism scope clarified (pipeline fixture covers pipeline dedup, NOT proxy seam — those are separate test surfaces), DEBUG endpoint owner pivoted from `EnviousWisprApp.swift` → small `DebugFaultEndpoint` type retained by AppDelegate, A7 narrowed to Cocoa terminate (no SIGTERM handler in code), A8 split into A8a Parakeet (true cancel propagation) + A8b WhisperKit (state-unwind only — no held task to cancel). Open Q1 fault-trigger mechanism: DEBUG-only localhost endpoint with tight gating selected (UserDefaults polling + DistributedNotificationCenter rejected). Two new scenarios added: A7 app-quit, A8 cancel-during-model-load. Out of V2 scope (filed as follow-ups): paste cascade fault injection (NG7 — heart-path-adjacent paste_failed cluster from V1a), fake `WhisperKitBackend` for testing (NG10 — needed for true zombie recovery test), V4 prompt adversarial (separate Track 2 phase). Tier LARGE confirmed (~1175 LOC across `Sources/{EnviousWisprAudio,EnviousWisprASR,EnviousWisprPipeline,EnviousWispr/App}` + `Tests/EnviousWisprTests/{Pipeline,App,Services}/V2/` + `Tests/UITests/`). Bible §6.1 V2 row stays PLANNED until V2 PR ships. Build deferred to next session per session-behavior §6 (one-release-per-session discipline + cognitive-mode-shift between planning and building).

- **2026-04-30 v1.27 · V1 shipped via V1a (production telemetry replaces marathon profile)** — Closes #364. Founder rule on 2026-04-30: no synthetic test longer than 5 min unless explicitly requested for a one-off. Original V1 design (3-hr metronome dictation profile + 25-min cold bench) was built around a "users idle, then re-use causes cold-path slowdown" hypothesis traced to one #272 Gemma4 incident in April 2026. Tested that hypothesis against 30 days of production telemetry: 16 active installs, 12 dictating users, 238 dictations, 150 polish events. Findings: 100% of production polish is Apple Intelligence (zero cloud providers in window — the cache-rotation mechanism the rule guarded against does not exist in `FoundationModels.LanguageModelSession`); polish latency vs gap is flat (p50 1.0–1.2s across all gaps from <30s to >4hr; p99 max never crosses 3.4s; no knee); Sentry corroborates with 0 polish failures, 0 network failures, 0 cold-path-shaped events in 14 days. **Performance & latency downgraded to Low Risk** for the upcoming audit rerun. Evidence: `docs/audits/2026-04-30-v1a-cold-path-telemetry.md`. §18 rewritten to retain a slim on-demand V1 (V1a telemetry refresh + optional V1b cold-launch single dictation + optional V1c 50-dictation stress, all <5 min); marathon designs retired. Four followups surfaced and filed separately, none blocking V1 close: cold_start telemetry bug, e2e tail past 2-min gaps, paste_failed production cluster (~14 events, heart-path-adjacent), Sentry env-tag knowledge note. Companion amendment to `validation-discipline.md §9` (drop "5-min idle between samples" prescription) drafted as a separate PR per workflow-process zero-blast-radius split.

- **2026-04-30 v1.26 · R2 shipped — pipeline fully decoupled from WhisperKit (Approach C + LID split)** — Closes #360 via PR #524 (squash `abd1c6e`, merged 23:15:44Z). Two-PR sequence: PR #522 (squash `22b72ba`, merged earlier same day) shipped a 17-test characterization safety net + determinism harness in `Tests/EnviousWisprASRTests/R2/` against unchanged production code so PR #524's refactor had an unmovable yardstick — structurally enforces the GPT council concern that fixture + refactor in one PR is gameable. PR #524 then landed three commits: (1) opaque `WhisperKitIncrementalSession` package protocol + worker conformance + dead `tokenizer` parameter deletion, (2) LID button on backend (`observeLID` returning Sendable `LIDObservationBatch` enum with explicit `.unavailable` / `.cancelled` / `.noWindows` / `.error` / `.observations` cases; classifier consumes via `@Sendable` closure observerFn, aggregation moves to a small `aggregateObservations` helper), (3) cleanup (drop public `whisperKitInstance` + `whisperKitTokenizer` properties, drop `import WhisperKit` from Pipeline, drop WhisperKit dep from `EnviousWisprPipeline` target in `Package.swift`, narrow `WhisperKitIncrementalWorker` + `IncrementalResult` + four reach-only `WhisperKitBackend` methods from `public` to `package`). **Both `nonisolated(unsafe)` declarations in the heart-path stop sequence eliminated**: the kitForLID hop at WhisperKitPipeline.swift:681-684 and the tokenizer hop at :1125-1127. **Pipeline now compiles without WhisperKit dependency** — verified by removing `"WhisperKit"` from the SPM target and confirming clean build. **Three-reviewer council cycle on the plan** (GPT + Gemini + Codex grounded review at `docs/audits/2026-04-30-r2-avb-grounded-review.txt` and `docs/audits/2026-04-30-r2-plus-lid-grounded-review.txt`); Codex proposed Approach C as a sharpening of A; founder-directed long-term framing added the LID split. **Per-commit Codex code-diff review** — each of the 3 commits Codex-reviewed and amended locally before the next commit started, plus a final cumulative review. Five Codex review rounds total in PR #524; all sign-off PROCEED or PROCEED-WITH-REVISIONS, all revisions absorbed. **One intentional behavior change**: inner-await `CancellationError` from `WhisperKit.detectLangauge` now surfaces immediately as `.cancelled` instead of being swallowed by the per-window catch and continuing — faster cancel response, classifier-side abstain semantics unchanged. Documented in `LIDObservationBatch.cancelled` doc comment. **Pre-R2 cold latency baseline captured manually** with `ModelUnloadPolicy=immediately` + 5 raw dictations: decode p50 622ms / reload p50 0.60s. **Post-R2 decode comparison** (warm — measurement note that the unload setting didn't propagate to the running app on first re-test): apples-to-apples decode times within ±100ms across comparable audio lengths (7-12s), confirming no regression. Also two new global Claude Code hooks shipped to `~/.claude/check-bash-background-pattern.sh`: blocks `cmd &` + `run_in_background: true` double-backgrounding AND `codex exec` without `</dev/null` (both failure modes hit during this session and previously documented as prose rules; promoted to structural enforcement per `feedback_hooks_over_prose`). New durable feedback memory: `feedback_bash_background_pattern.md`. Resolves §27.4 R2-approach decision.

- **2026-04-30 v1.25 · R5 shipped — HeartPathTelemetryEmitter extraction (Path A+)** — Closes #290 via PR #511 (squash `8d9ed81`, merged 20:23:29Z). Five shared infrastructure failure events (capture stall, XPC reply failure, capture session interruption, no-audio-captured, zombie zero-peak) extracted from duplicated code in TranscriptionPipeline + WhisperKitPipeline into `Sources/EnviousWisprPipeline/HeartPathTelemetryEmitter.swift` + `HeartPathTelemetryContexts.swift`. Engine-internal telemetry (Parakeet streaming/MLX, WhisperKit batch/LID/model-load/ASR-empty, paste, LLM) explicitly stays in each pipeline. Sentry payload shape preserved exactly including the WhisperKit-only `"backend"` extra on captureSessionInterruption and the WhisperKit-tagged dedup breadcrumb message — load-bearing for the live triage Routine. Sentry sink injected as a closure callback per `feedback_no_actor_protocol_existential_hot_path`. **Phase 0 strategic council ran first** (GPT + Gemini + Codex with full code access); all three converged on Path A+ — small tidy-up plus the zombie zero-peak event so #312 zombie-recovery slots in cleanly. Path B (observer pattern, engines emit state, separate observer interprets) explicitly rejected as a state-model refactor wearing telemetry-refactor clothes; trigger to revisit documented (shared telemetry rules outnumber engine-specific, OR timing/dedup bugs in telemetry hurt debugging, OR cross-failure correlation becomes operational need). Vendor decision: keep Sentry, keep PostHog. **22 new tests** across two new test files + 4 rounds of Codex review — round-1 found test theater (recorder discarded error object), round-2 found two more theater issues (state-flip claim was bypassed by `guard state == .recording`, zombie-suppress-marks test couldn't distinguish fresh from stale mark), round-3 caught the dropped-fired-guard regression test was still partial theater because both calls bailed on the same state guard, round-4 PROCEED-AS-IS after pre-dedup-while-idle redesign + 1.1s/1s window-distinguisher probe. **Mutation test confirms** the gap #3 fix actually catches the regression: removing `guard fired else { return }` from TranscriptionPipeline.handleCaptureStall causes the pipeline-level test to fail with state == .error instead of .recording. Phase 3 6-step validation (`scripts/validate-pr.sh`) PASS for run dir `2026-04-30T20-05-03Z-454af7b/`, all 4 obligations satisfied: tests, smoke, live-uat (UAT post-rebuild: TTS sentence transcribed end-to-end with clipboard updated, pipeline 1.7s), codex-review. Two durable feedback rules saved alongside this work: privacy line (rich metadata in, transcript content out) and TelemetryDeck-evaluated-and-rejected.

- **2026-04-30 v1.24 · §6.1 status table corrected — R3 + R4 marked SHIPPED** — Housekeeping pass. Both `R3` (Transcript out of logs, #361) and `R4` (BT route log rotation, #362) shipped weeks ago via PR #475 and PR #476 respectively (2026-04-26), but the §6.1 status column still read PLANNED. Two-cell edit to reflect reality. No code change. Caught when scanning the queue for the next phase to execute.

- **2026-04-30 v1.23 · Plan-template ownership justification added (god-object prevention at design time)** — Closes the loop on a founder-flagged gap from the Phase E retro: PR-time architectural ceilings (Phase E) catch the *symptom* (AppState grew). The *disease* (a plan added to AppState because it was convenient) was never gated at design time. Five edits, all to local-only files (rules + template + memory; no git-tracked code change):
  - `docs/feature-requests/TEMPLATE.md` — new §3b "Ownership justification," MANDATORY when a plan adds responsibility to a coordinator/manager/registry/AppState OR introduces a new such type. Plan must name the owner, justify why this owner and not a more local one, and (if AppState) explicitly answer why a downstream coordinator can't host it.
  - `.claude/rules/workflow-process.md` — Gate 1 intent check now requires a one-sentence plain-English placement statement: "This will live on \[X\] because \[reason\]. The alternative would be \[Y\] but \[trade-off\]." Founder's earliest leverage point on placement.
  - `.claude/rules/workflow-process.md` § Council preamble — bounded placement-challenge line: "If the plan adds responsibility to a coordinator/manager/AppState, name one alternative owner and the cost of choosing it instead. 'Easy to wire here' is not a valid placement reason."
  - `.codex/grounded-review-template.md` — same bounded placement challenge added; Codex grounded-review verifies §3b matches actual code reality (does the cited coordinator exist? is the cited consumer actually observing it?).
  - `.claude/rules/architecture-rules.md` § State Ownership — added a "Plan-time enforcement" paragraph cross-linking to TEMPLATE.md §3b so the connection between rule and plan-template is explicit.

  Three layers, each cheap. Plan-template forces Claude to write down the answer. Gate 1 makes the founder see the answer. Council + Codex pressure-test it. Won't prevent every god object — judgment about cohesion is irreducible — but raises the friction at design time, which is when moving things is cheapest. Phase E's PR-time tests remain as backstop.

- **2026-04-30 v1.22 · Safety-architecture tuning shipped (post-Phase-E retro)** — Closes the gap surfaced when founder flagged that Phase E's arch-lint CI gate was at the wrong altitude (PR-time, ~1 hour with GitHub-hosted runners). Council ran (GPT + Gemini in parallel); both providers converged on: pre-push not pre-commit, CI as backstop not primary detector, plan-template fields for measurement definition + earliest failure point, bounded "what's missing" line in council preamble, narrowed council-skip exception. Five edits shipped via PR #508 (single git-tracked file change: removed the 13-line `arch-lint` CI job) + four local-only file edits (push-discipline hook invokes dep-direction script when ship-path files changed; TEMPLATE.md gains §3a Metric Definition + Earliest Failure Point; council preamble + grounded-review template gain a bounded premise-check line; council-skip memory rule narrowed with disqualifiers covering workflow-gate / plan-template / lane / hook / memory-rule / unlocked-metric changes). PR-time arch-lint job removed; dep-direction now runs sub-second locally pre-push. Architecture regression tests continue to run via `swift test`. Council ran on this PR (workflow-architecture change, falls under the new disqualifier — and the disqualifier was added BY this PR, working as intended).

- **2026-04-30 v1.21 · Phase E shipped — architecture regression tests + dep-direction CI** — closes #502 via PR #504 (squash `74af410`, merged 16:01 UTC) + PR #505 (squash `e8dd156`, merged 16:11 UTC). Three fitness tests in `Tests/EnviousWisprTests/Architecture/`: AppState concrete-collaborator ceiling (≤ 19), AppState line-count ceiling (≤ 1050 = 954 + 10%), cross-module-public TODO guard. Plus `scripts/check-dependency-direction.sh` re-introduced and wired into a new `arch-lint` CI job in `.github/workflows/pr-check.yml` (no `lint` job existed; created deliberately). One Sources/ change: `WhisperKitBackend.makeDecodeOptions` narrowed `public` → `package` (the existing TODO offender Codex grounded review caught; Swift 6's `package` access lets Pipeline call it without the cross-module-public exposure). Council skipped per `feedback_codex_over_council_when_no_user_surface` (User Rubric: N/A; Codex grounded review settled the only structural fork — regex tightening + dep-graph correction). All 3 tests pass at baseline + 4 negative-test scenarios verified locally (intentional violation → test fails → revert). Audit meta-rec #1 marked RESOLVED. CI status: `arch-lint` job 2/2 green runs (8-9s each); ready to promote to required-check on next architecture-touching PR.

  **Followup PR #505 (post-merge GitHub-Codex review).** Two additional P2 false-negatives caught after #504 merged: (1) Swift 6 access-level imports (`internal import EnviousWisprPipeline`, `public/package import ...`) slipped through the script's grep — added `import_access` group. (2) `let` declarations with parenthesized attributes (`@available(macOS 14, *) let svc = ...`, `@Injected(...) let svc = ...`) slipped through AppState's collaborator detector — extended attribute regex to allow `(\([^)]*\))?` argument list, mirroring the bash script's pattern. Both fixes shipped with negative-test verification. Lesson captured: when introducing a new lint/test gate, run the gate against the FULL Swift 6 grammar (access-level imports + parenthesized attributes + scoped imports + import attributes) rather than the subset used in the current codebase. The local Codex review pass missed these because the diff didn't contain examples; the GitHub Codex full-file pass caught them.

  **Phase F metric reconciliation.** Phase F's plan predicted a post-F AppState count of 17, but the live count under Phase E's stricter definition is 19. The discrepancy is a metric-tightening, not a Phase F under-delivery: Phase F's count was a looser nominal "concrete property" concept (`19 → 17` in the plan; `19` actually counts *all* top-level `let` declarations including the two `any X` existentials). Phase E's locked metric counts existentials as collaborators because they still represent architectural seams that AppState owns. Net architectural win from Phase F is real: two services moved to SetupCoordinator (ollamaSetup, whisperKitSetup) and one collaborator added (the `setup` coordinator itself), yielding -1 collaborator overall. The headline number changed because the metric did, not because the work shrank.

- **2026-04-29 v1.19 · Phase D shipped — CustomWordsPropagator + wireCustomWords helper** — PR #497 (squash `8bf9423`, 4 commits in branch). Closes #496. Issue #496 auto-closed via PR body link.

  **What landed.** `CustomWordsPropagator` (`@MainActor final class`, 93 LOC + comments) replaces the prior 5-way fanout. New `package`-scoped `CustomWordsConsumer` protocol in `EnviousWisprCore` (11 LOC). Conformances on `WordCorrectionStep` + `LLMPolishStep` (1-line each, 2 files in `EnviousWisprPipeline`). Wire ordering extracted into a file-level `wireCustomWords(propagator:initialWords:consumers:coordinator:)` helper that AppState's init calls; integration tests drive the same helper with spy consumers. AppState's old fanout closure (`:373-380` pre-Phase-D) replaced with one helper call. PipelineSettingsSync trimmed: 5 setter lines deleted (`:54-55`, `:58-59`, `:206`) + `customWords:` parameter removed from `applyInitialSettings(_:)` and the private `syncPolishServiceSettings(_:)` helper. Single call site at `AppState.swift:212` updated.

  **LOC change is roughly neutral, not negative.** AppState went 961 → 976 (+15) because the wireCustomWords array literal + new stored property + breadcrumb comments outweigh the deleted closure body. PipelineSettingsSync went 271 → 272 (+1) because the trimmed setters were offset by Phase D refs in comments. The win is structural (decouple AppState's broadcast logic from concrete consumer types), not line reduction. Adding a sixth consumer is one `register()` call at the consumer's construction site instead of edits across AppState + PipelineSettingsSync.

  **Process trail (pioneered new flow).** First execution of a revised plan-review shape: council critiques become INPUT to the Codex grounded review, not a separate revision pass. Council ran one round (GPT + Gemini disagreed on 3 of 5 questions); Codex grounded review took both critiques + the unrevised plan + full code access, fact-checked every council finding against `file:line`, returned PROCEED-WITH-REVISIONS with 13 specific corrections. Plan revised once. Codex code-diff review ran 2 rounds (both clean). Codex truth-audit on the test file flagged 3 issues (one THEATER, two PARTIAL); commit 3 addressed all three: deleted theater test, promoted weak-storage to SUBSTANTIVE via deinit probe, replaced overclaimed integration test with one driving the actual `wireCustomWords` helper. **The new flow shape is now codified in `.claude/rules/workflow-process.md §1`** (10 steps, was 11, with the council critique → grounded review → single revision collapse).

  **Test count.** 491 → 496 (+5: weak-storage-deinit-probe, initial-sync-on-register, dup-register-idempotence, wireCustomWords-integration, late-register-receives-current-words). Codex truth-audit signed SAFE TO MERGE on the corrected suite.

  **Validation.** `scripts/swift-test.sh` green (496 tests). `swift build -c release` exit 0. `scripts/bundle-dev.sh` built v1.9.4-75-gc7439f0-dev, app launched cleanly, no precondition trips, no Phase-D-related errors in app log. CI build-check rerun green after one transient runner-side cancellation in the post-cache cleanup step (test work passed before cancellation; rerun was clean).

  **Standing lessons captured in memory.** `feedback_codex_cli_hygiene.md` — default `codex exec` invocations to `</dev/null`; sanity-check long-running Codex background tasks at the 5-min mark via `wc -l` on the output file. Stuck-on-stdin in this session wasted ~3 min before the user noticed.

  **Unblocked next.** Per §6.3 dependency graph: Phase E (architecture-regression tests) ready — should add a fitness test asserting AppState init wires all 5 known custom-words consumers via the new `wireCustomWords` helper. Phase F (SetupCoordinator) independent of Phase D; available. R2 (WhisperKitBackend adapter) independent.

- **2026-04-29 v1.18 · Phase D kickoff — §27.3 event-model gate locked, decisions file committed** — D10 added to `docs/feature-requests/issue-319-open-decisions-2026-04-18.md`: closure-based subscription via `register(consumer:)` chosen for `CustomWordsPropagator`. `@Observable` rejected for cross-service registry use (correct for views, awkward for services; explicit register/unregister + weak refs is the codebase's existing `.onChange` idiom). §10.6 STOP gate cleared; §10.2 code sketch as written stands. Side-effect: the open-decisions file (referenced by Bible §1.6 and §29) was untracked local-only since 2026-04-18 — committed for the first time as part of this Phase D PR. **Line-number drift refresh** (Phase B/C trims since v1.6): AppState fanout closure now at `:373-380` (was `:316-322`); PipelineSettingsSync setter sites now at `:54-55, 58-59, 206` (was `:67-68, 331-332, 350`). §10.8 inventory + §10.9 deliverables updated in plan file `docs/feature-requests/issue-496-2026-04-29-customwords-propagator.md`.

- **2026-04-20 v1.17 · Phase A shipped — closure-based overlay injection replaces protocol existential** — Phase A landed on `refactor/phase-a-pipeline-state-handler` (commits `a00cbcb` commit 1 + `5fffb96` commit 2; PR TBD). Final design deviates from v1.16 §7.2 in one specific way: the handler's overlay dependency is a `@MainActor (OverlayIntent) -> Void` closure, NOT an `any RecordingOverlayPanelProtocol` existential.

  **Why the change.** An earlier draft of commit 2 used the protocol existential as the v1.16 sketch prescribed. That form broke WhisperKit's batch transcription (LID windows + XPC reply cancelled with `Swift.CancellationError` during `.transcribing`). Parakeet's streaming path was unaffected. Bisect isolated the fault to the handler commit; the one-variable fix that restored WhisperKit was replacing `any RecordingOverlayPanelProtocol` with a concrete `@MainActor (OverlayIntent) -> Void` closure callback.

  **Proof is the A/B isolation, not runtime theory.** main → works. Commit 1 (no handler class, inline show) → works. Commit 2 with existential → breaks WhisperKit. Commit 2 with closure → works on both. Proximate-cause guess (not a claim): actor-isolated protocol-existential indirection on a hot path interacts badly with WhisperKit's longer MainActor-held critical sections during batch transcription. Swift-runtime mechanism not fully confirmed.

  **Standing lesson, captured in memory** (`feedback_no_actor_protocol_existential_hot_path.md`): avoid `any`-of-`@MainActor`-protocol indirection on hot paths when concrete or closure dispatch gives the same architectural outcome. Tests retain the observation seam via a recording closure + plain spy type; no production protocol needed.

  **What landed.** Handler class is `public final class PipelineStateChangeHandler` in `EnviousWisprPipeline`. Six injected callbacks (one closure-based showOverlay + cancelWarning/scheduleWarning/reloadHistory/reportCompleted/reportFailed). Pure `PipelineStateChangePlanner` from commit 1 drives the decision. Both backends verified end-to-end. AppState.swift: 965 → 934 (−31). 382 tests pass. Bible §7.2 prose retains the original design for historical context; this changelog entry supersedes the `RecordingOverlayPanelProtocol` stored-field sketch.

- **2026-04-20 v1.16 · Phase A Gate 0 sweep before kickoff** — Gate 0 citation audit against `origin/main` @ `8c5a5f3`. Two material design gaps and four naming/line-range drifts corrected in §7 before code work begins. No change to any other phase.

  **Material (design gap):**
  - **Three-way post-completion overlay priority documented.** Current production code (`AppState.swift:370-388` Parakeet, `:429-445` WhisperKit) applies `clipboardFallback > polishFailed-warning > success` priority on `.complete`. v1.15 handler design only described the polish-warning path. Handler signature now takes `isClipboardFallback: Bool` as a first-class input; handle() body enumerates all three branches.
  - **`postCompletionWarningTask` cancellation is a handler responsibility.** Current closures cancel the pending warning task on any non-complete transition (`AppState.swift:386, :443`); omitted from the v1.15 design. Handler now owns the `Task<Void, Never>?` and the cancellation invariant.

  **Naming / line drift:**
  - Intent value type is `OverlayIntent` (NOT `RecordingOverlayIntent`).
  - Parakeet state enum is `PipelineState` defined in `Sources/EnviousWisprCore/AppSettings.swift:17` (NOT nested `TranscriptionPipeline.State`).
  - §7.1 legacy "L221-L314" line range replaced with verified Parakeet `:344-406` / WhisperKit `:409-463`.
  - `.ready`-as-completion-equivalent ref moved from `:766` to actual `:768`; tiebreaker ranges refreshed to `:360-364` and `:423-427`.

  **Not moved into handler (now explicit):** `self.onPipelineStateChange?` external observer fan-out at `:346 / :411` stays inline in AppState — WhisperKit variant projects through unified `self.pipelineState`, which is cross-backend glue that doesn't belong in a per-backend handler.

- **2026-04-20 v1.15 · Phase G grounded-review fixes** — Codex grounded review (`docs/audits/2026-04-20-phase-g-grounded-review.txt`) returned NO on the v1.14 plans. Two structural traps and four drift items corrected:

  **Structural:**
  - **G3 (#394) Option A was an access-control trap.** `TranscriptionPipeline.init(...)` at `:107` is `public`; `TranscriptFinalizer` at `:53` is `internal`. v1.14 proposed putting the internal type in the public init signature. Fix: add a separate `internal init(...)` overload for tests via `@testable import`; keep existing `public init(...)` unchanged.
  - **G3 "depends on G4" was fictional.** Grep-verified `TranscriptFinalizer.swift:75-82` already exposes a closure-seam init (`save:`, `textProcessingRunner:`, `deliverPaste:`), and `TranscriptFinalizerTests.swift:24` already uses it. G3 is independent.
  - **G5 (#398) `any ASRBackend` sketch would not compile.** `ASRManager.loadModel()` at `:76` calls `parakeetBackend.prepare { callback }` — the progress-reporting variant is declared on `ParakeetBackend.swift:46` concretely, NOT on `ASRProtocol.swift:14`. Fix: widen protocol with a one-method `prepare(progressCallback:)` + default implementation that delegates to plain `prepare()`; existing `ParakeetBackend.prepare(progressCallback:)` becomes the override.

  **Drift:**
  - **G2 (#389) `LogLevel` → `DebugLogLevel`** (actual project type at `Sources/EnviousWisprCore/DebugLogLevel.swift:3`; already Sendable). Protocol + adapter visibility changed from `public` to `internal` (same-module consumers only).
  - **G4 (#396) `pasteToActiveApp(_:) -> Bool` → `-> PasteDispatchResult`** (real signature at `PasteService.swift:276`). Stale §4–§6 contract/consumer/lifecycle sections realigned with the revised §3 design (MainActor protocols, `any Clock<Duration>`, narrow `RestoreScheduler` — not custom `PasteClock`). Init param count corrected from three to four.
  - **G1 (#388) LLMPolishStep path** corrected from "likely `Sources/EnviousWisprLLM/LLMPolishStep.swift`" to verified `Sources/EnviousWisprPipeline/LLMPolishStep.swift:8` (same module as the runner — simplifies visibility to all-internal).
  - **Bible §17A.2 G2 row** "nine" → "six" with exact line numbers (final drift from the v1.14 sweep).

  **Sequencing final:** G1+G2 bundled → G5 → G3 → G4. All sub-phases genuinely independent; G1/G2 bundled only because they share a file. Re-running grounded review before G1 starts is advisable but not mandatory since the fixes are surgical.

- **2026-04-20 v1.14 · Phase G council revisions** — GPT + Gemini council round 1 on the five plans (sessions `phase-g-review-gpt-2026-04-20`, `phase-g-review-gemini-2026-04-20`). Both providers pushed back on the "mutually independent" sequencing claim and Swift 6 concurrency annotations. Corrections applied: (a) §17A.4 locked to G1+G2 bundled → G5 → G4 → G3, with G3 gated on G4 (finalizer's existing default-valued seams at `TranscriptFinalizer.swift:60-61` become useful only once a fake `PasteCascadeExecutor` exists). (b) G4 plan: protocols declared `@MainActor` (not just `Sendable`) because `NSWorkspace.shared.frontmostApplication` and pasteboard APIs are main-actor-sensitive; custom `PasteClock` replaced with `any Clock<Duration>` for linear sleeps plus a narrow `RestoreScheduler` for the queue-and-manually-trigger case (covers scenario f honestly, per GPT); added failure rows for restore-task throw, overlapping deliveries, activation-branch drift. (c) G5: clarified `ASRBackend: Actor` (grep-verified `Sources/EnviousWisprASR/ASRProtocol.swift:9`) — fakes must be `actor` types; existing `ASRManager` already `await`s every backend call. (d) G1: kept `ErrorSurfacePolicy` enum (Gemini called it YAGNI; type-check alternative would couple Pipeline to LLM module, architecturally worse) but flagged `Sendable` propagation check as a precondition. (e) G2: added failure row for logger-induced stalls (runner currently `await`s every log). Plan files updated in place.

- **2026-04-20 v1.13 · Phase G imported from epic #385** — Five testability-seam issues filed under epic #385 during the 2026-04-19 autopilot (#388, #389, #394, #396, #398) absorbed into this bible as **Phase G — Test-seam DI pass** (§17A). Rationale: a fresh session looking at "the current refactor plan" should find every live refactor here; splitting testability seams across #385 and #319 plan files fragmented the answer. Parent issues keep #385 origin attribution; bible cross-refs both epics. Load map row added per sub-phase; phase index expanded from 14 to 19 rows; five plan files drafted under `docs/feature-requests/issue-{388,389,394,396,398}-2026-04-20-*.md`. No behavior change to any other phase. Phase G sub-phases are mutually independent and independent of A–F / R2–R6 / V1–V4 — overlay any session.

- **2026-04-18 v1.0 · initial commit** — Bible committed. Supersedes the in-session framework comment on #319. All 11 Track 1 phases + 4 Track 2 validations captured with full substeps, DoD, rollback, and dependencies. Track 2 issues #364/#365/#366 opened; #291 extended for V2; #196 expanded to cover Phases C and D; #360/#361/#362/#363 annotated with pointers to this bible. Open questions §27 awaiting founder decision.

- **2026-04-18 v1.12 · Codex review of the decisions lock-in — corrections applied** — Codex dispatched on `.codex/decisions-lock-review-prompt.md` with full codebase access; output `docs/audits/2026-04-18-decisions-lock-review.txt`. Verdict: lock-in directionally right but materially under-specified on several decisions; three real corrections and two framing fixes. Canonical record is `docs/feature-requests/issue-319-open-decisions-2026-04-18.md` (v1.12 changelog entry there). Summary:

  - **D3, D6 confirmed as correctly scoped** (not hidden deferrals). Grep-verified.
  - **D1 revised.** `whisperKitLanguage` has no active heart-path read today (`syncTranscriptionOptions()` at `PipelineSettingsSync.swift:259-266, 295-315` uses `languageMode` only; `whisperKitLanguage` only surfaces as UI fallback at `SpeechEngineSettingsView.swift:185-193`). Seven-field framing changed to "6 active + 1 legacy."
  - **D2 revised.** Original "just remove the didSet" description understated the work. Three coordinated changes required: stop live `languageMode` writes from `PipelineSettingsSync.swift:261-266` during active sessions, snapshot for worker-start gate at `WhisperKitPipeline.swift:497-505`, snapshot for stop-time LID at `WhisperKitPipeline.swift:715-720`.
  - **D4 revised.** Scope broader than deleting four sync lines. Touches three abstraction layers: `AudioCaptureInterface` protocol (`:83-95`), XPC protocol (`AudioServiceProtocol.swift:43-68`), and `AudioServiceHandler.swift:27-30, 234-245, 283-330`. Mutable VAD setters must be REMOVED, not just unused. Also fix `noiseSuppression` live-rebuild leak at `PipelineSettingsSync.swift:274-280`.
  - **D7 re-scoped.** Codex flagged as single decision most likely to regret — under-bounded. `SetupCoordinator` does not exist in current tree (Phase F will build it; decision should be "build in library target from day one," not "extract"). WhisperKit bridge types already in `EnviousWisprASR` non-exec target — no action needed. Real extraction candidate is `TranscriptCoordinator` in Phase C if coordinator-level testing requires.
  - **D8 rationale corrected.** Safety argument is NOT "tests live in separate target." It's "default initializer is the only production wiring in AppState." Documented as Phase C invariant.
  - **D9 added** (missed decision). Session-scoped telemetry metadata freezing. `AppState` live-reads `recordingMode` at `:397-398, 454-455, 868-870` post-invocation/completion — mode flip mid-session creates reported `inputMode` drift across telemetry events for the same session. Fix: snapshot `inputMode` at invocation time onto session/invocation context; completion events read the snapshot.
  - **Phase C Invariant expanded to three safeguards + reinstated backup.** Original two safeguards covered READ but not WRITE. Added fixture-based read-compat test (generate corpus with pre-refactor code, check in as fixture) + write-after-read test (load old fixture, write via new code, verify pre-existing unchanged). Upgrade-time folder copy reinstated (migration-time copy of transcript folder to `backup-<old-version>/` on first launch post version-bump) — Codex pushed back on the original rejection; dogfooding is one corpus and observationally weak.

- **2026-04-18 v1.11 · Founder decisions locked — no-shortcuts discipline** — All 8 open decisions (D1-D8) from `docs/feature-requests/issue-319-open-decisions-2026-04-18.md` resolved. Founder's framing: Epic #319 has no client pressure, no release schedule; every "defer to follow-on" lean re-evaluated under refactor discipline; correct scoping preserved, deferrals-as-debt rejected.

  **Phase B scope expanded:**
  - **D1 — Seven-field snapshot.** `DictationSessionConfig` freezes: `autoCopyToClipboard`, `restoreClipboardAfterPaste`, `vadAutoStop`, `vadSilenceTimeout`, `noiseSuppression`, `languageMode`, `whisperKitLanguage`. Seven fields, not the original five — absorbs D2.
  - **D2 — Include in Phase B (full fix).** Remove WhisperKit's `didSet` live-mutation on `languageMode` (`WhisperKitPipeline.swift:62-74`); worker reads `languageMode` from frozen config at start, holds for whole session. No deferred state-machine cleanup issue.
  - **D3 — Stays live.** `modelUnloadPolicy` is post-heart cleanup; not a freeze candidate. Correctly scoped under Heart/Limbs, not a deferral.
  - **D4 — Complete fix, no shortcuts.** Founder's call. Push `DictationSessionConfig` into `audioCapture` at recording start; remove live `configureVAD(...)` calls during active sessions (`PipelineSettingsSync.swift:173-177, :182-186, :201-214`). Phase B touches both main-app and XPC audio-service process boundaries. Real Phase B: ~2-3 weeks of work.
  - **D5 — Tooltip.** Frozen-field Settings rows display passive "Applies on next recording" tooltip. No toast, no popup.
  - **D6 — Stays in HotkeyService.** `recordingMode` owned by HotkeyService; not in `DictationSessionConfig`. Correctly scoped as pre-recording choice.
  - **D7 — Extract to library targets.** Rather than adding executable-target deps to `EnviousWisprTests` in `Package.swift`, extract `SetupCoordinator` (Phase F) and WhisperKit bridge types (Phase R2) into library targets. Correct SPM architecture; importing app executable into tests is an anti-pattern.
  - **D8 — Directory-injectable init.** `TranscriptStore` gains `public init(directory: URL)` alongside existing parameterless `init()`. Standard dependency injection, not test-only code. Tests physically separated (test target, never in release build).

  **Phase C Invariant added — zero production history loss:**
  - Characterization test before refactor: pre-refactor code writes transcripts, refactored code reads same folder, assert identical load. Regression gate.
  - Pre-release dogfood: fresh dev build points at founder's real `~/Library/Application Support/EnviousWispr/` folder; verify full load + search + three new recordings persist.
  - Upgrade-time backup mechanism declined. Founder: "I don't mind if I lose my history, we just can't have production people lose it when they do the Sparkle update." Safeguards 1+2 sufficient.

  **Scope impact:** Phase B expanded from 1-week shippable subset to 2-3 week full-freeze refactor. Phase F and R2 acquire new sub-scope for library-target extraction. Phase C gains one hard invariant with two mandatory safeguards. Real refactor, not a patch job.

- **2026-04-18 v1.10 · Phase A + D focused reviews — completes the per-phase matrix** — Final two focused Codex reviews dispatched while founder napped; all eleven Track 1 phases have now had individual code-grounded Codex reviews. Every finding grep-verified before acceptance.

  **Phase A (§7) — deepest remaining design issue** (YES_WITH_REVISIONS):
  - `PipelineActivity` coarse-graining SILENTLY FLATTENS user-visible overlay labels. WhisperKit distinguishes "Starting..." (`.startingUp`) vs "Loading model..." (`.loadingModel`) at `WhisperKitPipeline.swift:307-313`; both pipelines distinguish "Transcribing..." vs "Polishing..." at `:315, :1279`. A handler deriving overlay text from `to.activity` alone loses the distinction. FIXED: handler takes the pipeline's pre-computed `overlayIntent` as a parameter; `PipelineActivity` used only for control flow (isActive, complete/error detection), not label rendering.
  - `backend: ASRBackendType` moved from per-call parameter to INIT-TIME injection. Codex verified `reportDictationCompleted` already derives backend from `Transcript.backendType`, and only `pipelineFailed` needs it explicitly. Init-injection is cleaner and matches AppState's one-handler-per-pipeline construction.
  - "Hotkey code stays inline" was too narrow. The current inline block also resets `isRecordingLocked = false` at `:352, :417` — that's session/UI state, not Carbon timing. Documented: both stay inline, but as TWO separate concerns, not lumped as "hotkey."
  - PR #285 inactive→active tiebreaker MUST stay in AppState (owns cross-pipeline state). Don't move to handler.
  - `.cancelled` state DOES NOT EXIST in either enum (verified). Dropped from test matrix. Cancellation returns to `.idle` or is handled by late-state guards at `TranscriptionPipeline.swift:372` and `WhisperKitPipeline.swift:448`.
  - Characterization test coverage expanded: explicit label assertions per state (4 labels), WhisperKit `.ready`-as-completion-equivalent at `AppState.swift:766`, tiebreaker test per PR #285.

  **Phase D (§10) — three tight finds** (YES_WITH_REVISIONS):
  - **Startup seeding gap.** `CustomWordsPropagator` starts with `words = []`. Current code seeds via `settingsSync.applyInitialSettings(settings, customWords: customWordsCoordinator.customWords)` at `AppState.swift:155`. If Phase D removes the 5 startup setter lines WITHOUT first priming the propagator from `customWordsCoordinator.customWords`, existing custom words disappear until next mutation. NEW substep 3a: seed propagator BEFORE contract step.
  - **`register()` duplicate-registration footgun.** v1.6-v1.9 `register()` blindly appended to consumers list. Same object registered twice produces duplicate writes on every update. Made `register()` idempotent via `ObjectIdentifier` dedupe in §10.2 sketch. Added duplicate-register idempotence test to §10.10.
  - **§10.10 test scenario was WRONG.** v1.6's "backend switch recreates consumer" assumption incorrect: `pipeline`, `whisperKitPipeline`, `polishService` are `let` on `AppState.swift:39-47`; backend switch doesn't recreate them. Replaced with correct scenarios: dead weak-ref pruning (short-lived fake consumer), initial-sync-on-register, duplicate-register idempotence, registered-but-silent mode, re-entrancy defense.
  - Pattern citation corrected: NOT Parallel Change because `CustomWordsCoordinator.onWordsChanged` is a SINGLE-slot callback, not a multi-subscriber API. True Parallel Change would need both mechanisms to coexist. Phase D is straight Extract Class with cutover (or two-commit with both temporarily coexisting); Parallel Change wording removed.

  All six focused Codex reviews now complete: **R3 (v1.8), B + C + F + R2 (v1.9), A + D (v1.10).** Review artifacts: `docs/audits/2026-04-18-{a,b,c,d,f,r2,r3}-codex-review.txt`. Aggregate: ~700K tokens across 6 reviews, $0 out-of-pocket.

- **2026-04-18 v1.9 · Four-phase focused Codex review batch (B, C, F, R2)** — Founder napping; auto-mode execution of the same focused-Codex-review pattern that worked for R3 in v1.8, now applied to all four remaining high-risk phases (B, C, F, R2 flagged in earlier full-bible plan-review). All four ran in parallel `codex exec` background processes. Every finding grep-verified against actual code before acceptance. Verdicts:

  - **Phase B (§8):** YES_WITH_REVISIONS. Most extensive find.
  - **Phase C (§9):** YES_WITH_REVISIONS. Double-save still lurking in substeps.
  - **Phase F (§17):** YES_WITH_REVISIONS. Scope + collaborators undercounted.
  - **Phase R2 (§12):** YES_WITH_REVISIONS. Tokenizer is dead code.

  Review artifacts: `docs/audits/2026-04-18-{b,c,f,r2}-codex-review.txt`. Total tokens across four reviews: ~400K. $0 out-of-pocket.

  **Phase B fixes (§8.2, §8.3, §8.7) — the deepest set:**
  - `VADSensitivity` type DOES NOT EXIST. Setting is `Float` on `SettingsManager.swift:107-111` and both pipelines. Sketch changed to `Float`. This would have been a compile error.
  - `DictationSessionConfig` public struct does NOT get public synthesized memberwise init — only `internal` is synthesized. Added explicit `public init(...)` declaration in §8.2.
  - `DictationSessionConfig(from:)` convenience init cannot live in Core (dependency direction). Moved to App module (AppState's file) in §8.2.
  - AppState is NOT the direct caller of `pipeline.startRecording()`. Verified: `TranscriptionPipeline.swift:334` and `WhisperKitPipeline.swift:418` are the only direct callers (internal to the pipeline types). External orchestration routes through `handle(event: .toggleRecording)` on the `DictationPipeline` protocol (`Sources/EnviousWisprPipeline/DictationPipeline.swift:40-46`). Substep 4 rewritten: the protocol's event shape must extend to carry `DictationSessionConfig`, OR the protocol adds `startRecording(config:)` explicitly. Not a direct call-site migration.
  - Start-intent setup duplicated across AppState's hotkey start (`:475-556`, with setup at `:483-499`) and toggle path (`:825-876`, with setup at `:828-847`). Substep 5 now requires factoring into a single helper; otherwise live-mutable drift between paths.
  - NEW substep 5a — XPC audio-service path. `PipelineSettingsSync.swift:173-177, :182-186, :201-214` pushes VAD changes live into `audioCapture.configureVAD(...)` during active sessions. Freezing pipeline fields alone does NOT freeze VAD behavior. Phase B must push session config into `audioCapture` at start AND stop live `configureVAD` during session. Flagged as founder decision.
  - Settings classification reclassified per code-grounded evidence (§8.7 table):
    - `environmentPreset` — reclassified as FROZEN (its handler writes `settings.vadSensitivity`, which flows into the frozen VAD path; UI alias for a frozen field).
    - `recordingMode` — MISCLASSIFIED as frozen in v1.6-v1.8. Actual handler only touches `hotkeyService.recordingMode`, not pipelines. Either drop from config (recommend) or expand scope to refactor HotkeyService.
    - `modelUnloadPolicy` — PARTIAL freeze. Per-session unload freezes; idle-timer cancellation stays live.
    - `languageMode` — added to config freezes the VALUE but not the BEHAVIOR. `WhisperKitPipeline.languageMode` has `didSet` at `:62-74` that invalidates worker mid-session; also live reads at `:503-505, :715-719`. Non-trivial code change beyond adding a config field.
    - `noiseSuppression` — NOT pipeline state. Applied immediately to `audioCapture.buildEngine(noiseSuppression:)` at `:271-280`. Drop from config; keep as live sync with session-start guard.
  - Phase B's unambiguously-shippable subset (v1.9 scope recommendation): six fields only — `autoCopyToClipboard`, `restoreClipboardAfterPaste`, `vadAutoStop`, `vadSilenceTimeout` (with XPC audio-service update), `vadSensitivity`, `vadEnergyGate`. The other five fields need founder decisions or expanded scope.

  **Phase C fixes (§9.3):**
  - Substep 2 and substep 4 in v1.6-v1.8 still instructed "Option A: coordinator owns disk I/O (write-through on `append`)" — literal execution would reintroduce the double-save bug §9.2 fixed. Rewrote §9.3 to lock in memory-only `append(_:)` with no alternatives.
  - NEW substep 6 — append-vs-in-flight-load race handling. `TranscriptCoordinator.load()` currently does wholesale `transcripts = try await store.loadAll()`. If load completes AFTER append, the load overwrites the in-memory array with an older snapshot (missing the new row) until next reload. Fix: either cancel in-flight `loadTask` when appending OR merge by ID rather than wholesale replace. Recommended: merge-by-ID (defensive).
  - Expanded view-consumer grep from three patterns to four — added `appState.activeTranscript` (the right-hand detail pane at `HistoryContentView.swift:18` resolves through `AppState.swift:700` indirectly).
  - NEW substep 10 — `TranscriptStore` is not directory-injectable today (`.swift:9` hardwires `AppConstants.appSupportURL`). Seeded 1000-transcript perf test needs a new `public init(directory: URL)` as prerequisite, OR becomes a manual scenario.

  **Phase F fixes (§17):**
  - Site count corrected from "~20-30 across ~5 files" to **38 sites across 3 files** exactly (29 in `AIPolishSettingsView.swift`, 8 in `SpeechEngineSettingsView.swift`, 1 in `AppDelegate.swift`). LOC delta revised to +200 to +250.
  - `SetupCoordinator` MUST accept two collaborators as init params: `asrManager: any ASRManagerInterface` (for `activeBackendType` reads) and `preloadAction: @MainActor () async -> Void` (wraps `whisperKitPipeline.prepareBackendSilently()`). Zero-arg init was wrong. Documented init shape in §17.2.
  - Init-order constraint: `SetupCoordinator` must be constructed AFTER `asrManager` and `whisperKitPipeline` are ready.
  - Test prerequisite: `Package.swift:107` doesn't include `EnviousWispr` executable target in `EnviousWisprTests` deps. Tests can't import `SetupCoordinator` as-is. Either (a) add `EnviousWispr` to test deps, OR (b) extract coordinator into a library target. Recommend (a). Without one of these, substep 8's unit test can't run.

  **Phase R2 fixes (§12):**
  - Tokenizer parameter is DEAD CODE. `WhisperKitIncrementalWorker.swift:26` stores it, `:41` initializes from param, NOTHING reads it anywhere in the file. NEW substep 1a: DELETE the dead parameter rather than narrow it. Genuine cross-module reach count drops from four to three.
  - MainActor protocol doesn't solve the line-714 LID isolation impedance (non-Sendable `WhisperKit` handle goes to `LanguageDetector` actor via `nonisolated(unsafe)` — pre-existing pattern, not changed by narrowing). Caveat documented; accepted as out-of-scope for R2.
  - Substep 3 amended — verify `WhisperKitBackend`'s actual isolation status before declaring conformance to `@MainActor` protocol. If backend isn't MainActor, the bridge may need to drop the MainActor requirement.
  - Unit test (substep 9) — current sketch of "mock bridge driving a pipeline test without real WhisperKit" is not realistic because bridge returns a concrete `WhisperKitIncrementalWorker` actor, which requires real WhisperKit state. Options: (a) narrower return protocol for the worker, OR (b) accept integration-level test. `EnviousWisprTests` also doesn't depend on `EnviousWisprASR` (Package.swift test-topology issue also flagged in F). Minimal viable path: skip unit test for R2, rely on `wispr-eyes` smoke; open follow-on issue for test infrastructure.

- **2026-04-18 v1.8 · Phase R3 focused Codex review corrections** — Dispatched `codex exec` on R3 alone (prompt at `.codex/r3-review-prompt.md`, output at `docs/audits/2026-04-18-r3-codex-review.txt`, 113K tokens, 8.5 KB prose review). Verdict: **YES_WITH_REVISIONS**. Core compile-out approach correct; three real implementation bugs and two framing errors fixed. Every Codex claim grep-verified before acceptance.

  **Implementation bugs fixed:**
  - §13.3 substep 4 — `SettingsSection.swift` wrap was INCOMPLETE. v1.7 wrapped only `case diagnostics`; actual file has THREE additional switch arms on `.diagnostics` (label lines 21-32, icon lines 34-46, group lines 49-55) that become non-exhaustive compile errors if only the case declaration is wrapped. Revised substep 4 lists all four wrap sites in `SettingsSection.swift` plus the one in `SettingsView.swift` — five total.
  - §13.3 substep 4 — added fix for `AIPolishSettingsView.swift:747`. Line 747 renders `aiDebugSection(report:)` when `isDebugModeEnabled=true`, independent of the Diagnostics tab. A release build inheriting `UserDefaults` from a prior dev session with debug-mode=true would surface this debug UI even after hiding the Diagnostics tab. Fix: wrap the `aiDebugSection` conditional in `#if DEBUG`. Codex caught this; v1.7 missed it.
  - §13.8 "dead code" language softened. v1.7 claimed "148 call sites become dead code." The `#if DEBUG` wrap in `AppLogger.log(_:)` body makes the SINK LOGIC dead code, but `await AppLogger.shared.log(...)` call sites still pay actor-hop overhead and often `Task { ... }` wrapper cost. Privacy outcome unchanged (no production output); performance claim corrected (no zero-overhead elimination at call sites).

  **Framing errors fixed:**
  - §13.6 V3 relationship — v1.7 claimed "V3 validates NO AppLogger output in release, ever" + broader "no subsystem logging" implicitly. Codex correctly flagged that four OTHER `os.Logger` + `print` + `NSLog` sinks exist in Sources/ on EnviousWispr subsystems. Subsystem silence ≠ AppLogger silence. Revised V3 recipe distinguishes: (a) Check 1 asserts AppLogger category `pipeline` is silent (R3 success proof); (b) Check 2 lists other-category hits as expected and documents them; (c) Check 3 dictated-token grep across the whole subsystem family.
  - §13.9 NEW — documented the FOUR non-AppLogger logger sinks that remain on EnviousWispr subsystems after R3 ships (FillerRemovalStep category `FillerRemoval`, WordCorrector category `WordCorrector`, AVAudioEngineSource btCrashLogger category `BTCrashDiag`, Constants NSLog, ObservabilityBootstrap two `print()` sites). Documented as out-of-scope-for-R3 + tracked as post-epic cleanup candidate. Prevents future sessions from mis-reading V3 output as R3 failure.

  **Test strategy tightening:**
  - §13.3 substep 8 — made the non-DEBUG unit test concrete: assert `setDebugMode(true)` + `log(...)` does NOT create `app.log` (query the expected file URL, confirm non-existence). Also flagged CI requirement: `swift test -c debug` AND `swift test -c release` must BOTH run for the `#if`-split coverage to actually exist.

  **Estimate correction:** §13.8 updated — actual scope is 3 files (AppLogger, SettingsSection, AIPolishSettingsView), ~40-50 LOC. Prior v1.7 "~30 LOC, one file" undercounted by ~20 LOC + 2 files. Still dramatically smaller than original per-site redaction plan.

  Codex's sign-off: YES_WITH_REVISIONS — all revisions incorporated in v1.8.

- **2026-04-18 v1.7 · AppLogger compile-out pivot** — Founder reframing: AppLogger is a dev inner-loop tool, never designed for production. Original REF-03 plan (v1.3-v1.6) redacted transcripts at ~148 call sites across 8 modules — mechanical work, half measure. Pivoted to compile-time gating: one `#if DEBUG` wrap on `AppLogger.log(_:)` makes all 148 call sites' sinks dead code in release, zero call-site changes. Verified production-independence of Sentry, PostHog, btRouteLog, and crash reporting paths (they don't use AppLogger). Verified Diagnostics tab structure (`DiagnosticsSettingsView.swift` + `SettingsSection.swift:15` + `SettingsView.swift:77`) — wrapping the enum case and render site in `#if DEBUG` removes the whole dev-diagnostics surface from release Settings. Rewrote §13 top-to-bottom; new §13.1-§13.8 replacing per-site redaction plan with compile-out plan. Requires focused Codex review before ship (v1.8 covers that review).

- **2026-04-18 v1.6 · Codex plan-vs-code review corrections** — Founder suggestion: have Codex review the bible against the actual codebase (not just code, not just plan — plan-vs-code with full project access). Dispatched `codex exec` with a plan-review schema and a prompt framing Codex as an independent external reviewer. Runtime ~15 min, 239K tokens, $0 out-of-pocket.

  **Codex's verdict: NO sign-off. Coherence grade C. Execution confidence LOW.** Flagged B, C, E, F, R2 as highest-risk. Every finding verified against actual code before acceptance. All accepted.

  **Critical fixes (plan would not compile or would cause data bug):**
  - §9.2 Phase C — **double-save bug.** `TranscriptFinalizer.swift:126` already calls `try save(transcript)` before AppState ever observes `.complete`. My v1.3-v1.5 `append(_:)` with write-through would DOUBLE-PERSIST. Redesigned: `append(_:)` is IN-MEMORY ONLY; persistence stays with the finalizer. Biggest miss of the bible to date.
  - §8.2 Phase B — `DictationSessionConfig` visibility. v1.3-v1.5 declared it `internal` in Core. Core-internal cannot be consumed from Pipeline targets. Changed to `public` with explicit memberwise init.
  - §8.3 Phase B substep 4 — the "deprecated zero-arg `startRecording()` overload that internally captures snapshot" is architecturally impossible: pipelines do NOT own `SettingsManager`. Redesigned: single changed signature, AppState (the only caller per grep) captures the snapshot. No migration overload.
  - §7.3 Phase A telemetry hook — `@Sendable (String, [String: Any]) -> Void` is a Swift 6 compile error because `[String: Any]` is not `Sendable`. Redesigned hook with a concrete `CapturedTelemetryEvent` Sendable struct using typed property buckets.
  - §12.2 R2 — `WhisperKitDecodeBridge: Sendable` is a Swift 6 compile error; WhisperKit / DecodingOptions / tokenizer types are not Sendable. Redesigned as `@MainActor protocol` matching the actual call-site isolation.

  **High-severity corrections:**
  - §7.2 Phase A handler sketch — missing `audioLevelProvider` and `isRecordingLocked` parameters required by actual `RecordingOverlayPanel.show(intent:audioLevelProvider:isRecordingLocked:)` API. Added.
  - §12 R2 — **FOURTH cross-module reach** at `WhisperKitPipeline.swift:714` (`backend.whisperKitInstance` for language detection). `WhisperKitBackend.swift:33` declares `public var whisperKitInstance: WhisperKit? { whisperKit }`. v1.3-v1.5 scope counted only three reaches. R2 scope expanded: bridge gets a second method `makeLanguageDetectionContext()`, and `whisperKitInstance` must also narrow to internal.
  - §8.7 Phase B — `whisperKitLanguage` (PipelineSettingsSync:259) misclassified as freeze-per-recording. Actual case handler delegates to `syncTranscriptionOptions(settings)` (live plumbing); language selection flows through `languageMode` + detector actor. Removed from the freeze set. `DictationSessionConfig` goes from 11 fields to 10.
  - §17.2 Phase F — self-contradicting protocol sketch (§17.2 had `reset()` + semantic accessors, §17.3.1 removed `reset()`). Locked in v1.6 as property-passthrough protocol without `reset()`. Matches §17.3 substep 2 Option A (recommended).

  **Sequencing correction:**
  - §23.1 Session 2 — **B × F collision.** Both phases edit AppState.swift AND PipelineSettingsSync.swift. Prior versions claimed parallel; Codex plan review correctly flagged. Revised: B ships first, F branches off post-B main. Sequential within Session 2.

  **Missed refactor targets (not in bible; recorded for later):**
  - `TranscriptPolishService.swift:160-168` — another `loadAll()` full-directory scan on the polish-enhancement path (existence check for deleted transcripts). Phase C only fixes the completion path. Documented as post-epic candidate; optional in-scope fix during Phase C if time permits.
  - `PipelineSettingsSync.swift:379-389` — `reconcileOllamaEviction` — LLM-specific lifecycle orchestration embedded in a general settings propagator. Phase B doesn't touch it. Post-epic extraction candidate.
  - `WhisperKitPipeline.swift:714` — covered by R2 fix above (was the fourth reach).

  **Plan strengths Codex identified as worth preserving:**
  - Heart/Limbs preservation across every phase's rollback plan.
  - Intentional-duplication rule respected in Phase D (propagator broadcasts to both pipelines, does not unify).
  - Characterization tests before refactoring (Phase A).
  - Static Risk grade scale on Track 2 dimensions (avoids false-confidence letter grades).
  - Explicit founder gates on Phase B / D / R2 decisions (§27 with STOP markers).

  **Codex's Red Team self-critique:**
  - Most likely wrong phase: **B**. "Asks the current codebase to freeze recording config at start time without touching the real recording entry points or the shared audio-capture configuration layer."
  - Biggest surprise during review: Phase C double-save bug. "TranscriptFinalizer already saves the transcript before AppState observes `.complete`, so the bible's write-through `append(_:)` plan duplicates persistence unless the finalizer boundary changes first."

  Full review artifact: `docs/audits/2026-04-18-bible-plan-review.json`. 49 KB, 239K tokens consumed.

- **2026-04-18 v1.5.1 · dep-direction history correction** — Founder asked to double-check the hooks because work was happening in another session. Re-verified: `.git/hooks/pre-commit` is a no-op stub dated 2026-04-01 containing `# Pre-commit hook — architecture enforcement checks removed (brain system deprecated)` + `exit 0`. So `scripts/check-dependency-direction.sh` did NOT "never exist" (v1.5 framing "planned") — it existed historically under the brain system and was deleted when that system was retired. Updated §2.6, §11.2, §11.3 substep 6, and §22.2 in the bible, plus `workflow-process.md §13`, to reflect the correct history: script was DELETED and is being RE-INTRODUCED by Phase E, not created for the first time.

- **2026-04-18 v1.5 · systematic grep-verification pass + knowledge-file staleness fixes** — Founder directive: "keep grepping the actual code and systematically make sure this plan isn't a hallucination mess." Ran comprehensive grep verification of every type name, rule citation, script reference, line count, and section name in the bible. Also audited project knowledge files for staleness this exercise surfaced. Five real bible hallucinations fixed, plus multiple knowledge-file staleness items corrected.

  **Bible hallucinations fixed:**
  - §7.2 Phase A sketch — invented type `OverlayManager` replaced with actual `RecordingOverlayPanel` (verified at `Sources/EnviousWispr/App/AppState.swift:389,446,507,522,532`). The concrete panel exposes `show(intent:audioLevelProvider:isRecordingLocked:)`.
  - §7.3 Phase A characterization-test mechanism — removed fiction that `TelemetryServiceSpy` or a `TelemetryService.testHook` might already exist. Verified no test-seam precedent in `Tests/`. Substep now explicitly designs the seam: add `RecordingOverlayPanelProtocol` for overlay capture and add `#if DEBUG TelemetryService.testEventHook` for telemetry capture. Cover-then-refactor as two separate commits.
  - §23.1 and three other sites — rule citations to `workflow-process.md §6 Git session isolation` and `§7 Own the merge` were WRONG. Those are project `CLAUDE.md` rules 6 and 7 respectively. `workflow-process.md §6` is "Empirical over council"; `§7` is "Refactor discipline — REFACTOR tier." Citations corrected.
  - §11.3 Phase E substep 6 — `scripts/check-dependency-direction.sh` was cited as if it existed ("confirm it runs in CI, wire it"). Verified: **the script does not exist in the repo.** Substep rewritten to CREATE the script, not wire an existing one. Risk #15 updated to reflect new-script-creation hazard rather than maintenance hazard.
  - §2.6 reference to the script also corrected to note the script is planned (via Phase E), not current.

  **Knowledge-file staleness fixes (from this exercise):**
  - `.claude/rules/workflow-process.md` §13 — claimed `scripts/check-dependency-direction.sh` pre-commit hook "enforces dependency direction automatically." Script does not exist. Rewritten to acknowledge the script is PLANNED under Epic #319 Phase E and until then enforcement is manual review + SPM implicit cyclic-import errors.
  - `.claude/knowledge/architecture.md` L118 — AppState described as "thin coordinator, ~770 lines." Actual: **965 lines**, flagged as worst-violation in current audit. Updated with reality + link to Epic #319.
  - `.claude/knowledge/architecture.md` L128-130 — `SilencePaddingBenchmark` claimed as active executable target in Package.swift. Verified: removed from Package.swift (benchmark plan in `docs/plans/silence-padding-benchmark-plan.md` completed March 2026, target deleted afterward). Section relabeled HISTORICAL.
  - `.claude/knowledge/architecture.md` §Known Architectural Debt — every line count was stale: AppState 770→965 (+23%), PipelineSettingsSync 329→398 (+21%), TranscriptionPipeline 1009→1319 (+31%). All corrected with verified counts and cross-links to Epic #319 phases that will address them.
  - `.claude/knowledge/architecture.md` §Known Architectural Debt — claim that `padAudioWithSilence` is "still public" is FALSE. Grep-verified: it's declared `static func` (default internal). Only `makeDecodeOptions` remains public-by-convenience (REF-02 / issue #360). Updated.
  - `.claude/knowledge/architecture.md` §Phase Roadmap — said "All 5 phases complete as of 2026-03-16." Phase 3 (Break AppState god object, 2026-03-14) marked DONE but AppState has since grown from ~770 to 965 lines. Updated Phase Roadmap to add "Q2 Hardening (Epic #319)" row as IN PROGRESS and note Phase 3 as "first pass — incomplete, AppState kept growing."

  **Council findings (from R1/R2/R3 + CTO pass + adversarial + this grep pass) NOT found in code:**
  - All custom types the bible claims as NEW (`PipelineStateChangeHandler`, `CustomWordsPropagator`, `CustomWordsConsumer`, `RotatingFileSink`, `SetupCoordinator`, `WhisperKitDecodeBridge`, `DictationSessionConfig`, `PromptDelimiterSanitizer`, `HeartPathTelemetryEmitter`, `PipelineStateProtocol`, `PipelineActivity`, `SetupCoordinating`) are verified ABSENT — no name collisions.
  - All types the bible claims exist (ASRBackendType, SentryBreadcrumb, AppLogger, PermissionsService, BenchmarkSuite, HotkeyService, CustomWordsCoordinator, OllamaSetupService, WhisperKitSetupService, AudioDeviceList, CaptureTelemetryState, AIAvailabilityCoordinator, TranscriptPolishService, CustomVocabularyFormatter, TelemetryService, RecordingOverlayPanel) verified PRESENT at expected paths.
  - All rule-file section headings the bible cites (architecture-rules §Anti-God-Object, §Access Control, §Audio/ASR Danger Zones, §Intentional Duplication, §Heart & Limbs, §Architecture Definition of Done; validation-discipline §3, §7, §9, §10 Rule B, §10 Rule C; tools-and-apps §2; session-behavior §1) all verified present.
  - All knowledge-file references (codex-audit, architecture, pipeline-mechanics, observability-operations, polish-eval, distribution, accounts-licensing, session-log) verified present.
  - Accounts-licensing.md §Analytics Privacy / Events Never Collected — subsection verified present (line 164).

- **2026-04-18 v1.4 · adversarial-Codex pass** — Founder directive: treat this as adversarial Codex review with full project knowledge. Found and fixed four show-stoppers plus multiple HIGH-severity fresh-session ambiguities that prior rounds (council R1-R3 + CTO deep dive) missed.

  **Show-stoppers fixed:**
  - §7.2 Phase A — prior plan assumed both pipeline state enums fit under a generic `PipelineStateProtocol` with `isRecording/isComplete/errorReason`. Adversarial grep revealed `WhisperKitPipelineState` has 9 cases including `.ready` and `.startingUp`, while `TranscriptionPipeline.State` has 7. Design updated: protocol uses coarse-grain `PipelineActivity` enum (idle, preparing, recording, processing, complete, error) that both state enums map onto. Prior "shared handler" would have silently dropped backend-specific state transitions.
  - §15.2 Phase R4 — v1.3's actor-based `RotatingFileSink` is wrong for this call pattern. Adversarial grep confirmed `btRouteLog` is called from `PreRollForwarder:181-192` (audio-thread-adjacent, under RT lock in places) and `AVCaptureSessionSource` (synchronous capture callbacks). Actor forces `async`, breaking every site AND violating the bible's own §2 rule against logging under RT lock. Redesigned: `final class @unchecked Sendable` with `OSAllocatedUnfairLock` (in-process) + `flock(LOCK_EX)` (cross-process). Synchronous; safe from audio-adjacent contexts.
  - §17 Phase F — v1.3's LOC estimate (+~90) undercounted view migration. Adversarial grep found `AIPolishSettingsView` alone has 15+ direct `appState.ollamaSetup.*` read sites including `.onChange(of:)` observer. Revised to +~200 LOC across 5+ view files. Protocol design switched from semantic-methods (Option B) to property-passthrough (Option A) to shrink view-migration surface.
  - §11.2 Phase E — property-count regex `^  let x = Type()` missed arg-bearing constructors like `let x = Type(arg: value)`. Regex expanded to match both forms. Also: file path resolution switched from bare relative path (broken under different test runners) to `#filePath`-based resolution. Concrete-dep count target held at ≤12 per §4.13 disposition matrix.

  **Other adversarial findings fixed:**
  - §7.3 Phase A — characterization-test mechanism made concrete: test-only `OverlayManager` stub + `TelemetryService.testHook` under `#if DEBUG`. State transitions to cover enumerated per §7.2 enum inventory.
  - §12.3 R2 — substep 6 reworked. Prior v1.3 said "narrow and delete TODO"; adversarial lens caught that keeping `backend: WhisperKitBackend` reference alongside adding bridge creates an alternative path back to old members unless the old members are actually narrowed. Substep 6 now requires post-narrowing `grep` confirming zero backend-direct reaches remain.
  - §17.3 Phase F — substep 1 rewritten to require full view-surface grep BEFORE protocol design. Protocol surface follows inventory, not vice versa. §17.3.1 dropped `reset()` method (scope creep without caller).
  - §10.10 Phase D — added lifecycle-aware test requirements (re-created consumers on backend switch, silent setter guards, re-entrancy during iteration). Basic "register N, update, assert N receive" is insufficient.
  - §10.11 Phase D — documented intentional-duplication policy under simultaneous-active pipelines (both receive broadcasts, no active-only policy).
  - §23.1.1 NEW — squash-merge rebase discipline. `gh pr merge --squash` rewrites history; every in-flight worktree must `git fetch origin main && git rebase origin/main` before resuming. Prior bible assumed this was obvious; adversarial check: it is not.

  **What adversarial pass confirmed as SOUND in v1.3:**
  - §0.3 Load map structure.
  - §4.13 Disposition matrix.
  - §8.7 Phase B settings inventory.
  - §10.8 Phase D consumer inventory.
  - §24 Risk register (after v1.3 additions).
  - §25 Ship criteria + qualitative gate.

- **2026-04-18 v1.3 · post-R3 council correction + deep-dive expansion** — Two-part revision. First pass: council round 3 corrections (real bugs fixed, false-positives verified and rejected). Second pass: CTO-driven deep-dive after founder reminder that "this is a refactor, don't cut corners." Grep-anchored evidence added where prior versions handwaved. New phase added to make the AppState target achievable. Changes:

  **Deep-dive evidence work (second pass, 2026-04-18):**
  - §4.13 NEW — AppState disposition matrix. Every one of the 15 owned concrete-type deps now has an explicit fate (STAYS / MOVES-to-X / post-epic-candidate). Prior bible was vague; fresh session had to reverse-engineer from other sections. Fate trajectory: 15 → 14 (Phase C) → 12 (Phase F).
  - §8.7 NEW — Phase B settings inventory. Grep-anchored classification of all 35 handler cases in `PipelineSettingsSync.swift` into freeze-per-recording vs live-mutable. Produces the authoritative 11-field `DictationSessionConfig` shape. Replaces deferred "inventory during substep 1" with inventory done now.
  - §10.8 NEW — Phase D consumer call-site inventory. Grep-anchored table of all TEN setter sites across AppState (5) AND PipelineSettingsSync (5). Prior bible stated "five consumers" ambiguously; actual fanout is ten sites across two files.
  - §10.9 NEW — Phase D concrete deliverables. Net line count per file.
  - §17 NEW — Phase F, SetupCoordinator extraction. Extracts `ollamaSetup`, `whisperKitSetup`, `whisperKitPreloadTask` out of AppState. Added because §4.13 revealed that Phases A+C+D alone only take AppState from 15 deps to 14 — nowhere near meaningful Testability improvement. Phase F gets to 12.
  - §11.2 Phase E target revised from ≤ 8 (unachievable per matrix) to ≤ 12 (honest, reachable by Phases A+C+D+F). Added note about post-epic BenchmarkCoordinator + TelemetryObservationCoordinator reaching ≤ 10 if needed.
  - §6.1, §25.1, §0.3 updated to include Phase F.

  **Compile-error fixes (critical, from first-pass R3):**
  - §10.2 Phase D — `WeakBox` changed from `struct` to `final class`. Swift forbids `weak` properties in value types; prior sketch would not compile.
  - §9.2 Phase C — Option 2 (async detached save) DROPPED. `TranscriptStore` is `@MainActor public final class`; calling its methods from `Task.detached` is a Swift 6 concurrency violation. Now a single locked choice: synchronous save on MainActor. Future migration to a nonisolated `TranscriptStore` is tracked as a follow-on issue, not this epic.
  - §15.2 Phase R4 — `RotatingFileSink` redesigned from `struct` (racy) to `actor` + `flock(2)` for cross-process serialization. In-process and cross-process safety now both explicit. Council R3 flagged this as CRITICAL; agreed and fixed.

  **Structural numbering fixes:**
  - Duplicate `### 4.9` — second occurrence (rules-files table) renumbered to §4.12.
  - Duplicate `### 25.4` — second occurrence (governance bullets) renumbered to §25.6.

  **Load map additions:**
  - §0.3 — every refactor phase now references §5 (methodology). Every phase blocked on a §27 decision references the specific §27.X (STOP-until-decision marker). Phase F added to load map.

  **Gate sections added in phase bodies:**
  - §8.6 Phase B — explicit STOP gate with where-to-record-decision pointer.
  - §10.6 Phase D — explicit STOP gate referencing §27.3.
  - §12.2 R2 — explicit STOP gate referencing §27.4.

  **Dependency graph:**
  - §6.2 ASCII — made V4→R6 arrow explicit (prior version could be read as parallel).

  **Sequencing correction:**
  - §23.1 Session 1 — R5 removed from the Phase-A-parallel set. Phase A ships alone, R3/R4 parallel after A merges, R5 sequential after R3/R4. Council R3 correctly flagged that R5 edits pipeline files and parallel-with-A creates conflict risk even though the specific lines may not overlap.
  - §23.1 Session 2 — Phase F added.

  **Pattern citation correction:**
  - §10 Phase D — cited "Parallel Change" but the substeps collapsed expand+contract into one PR. Clarified: shipping in two commits within one PR qualifies as Parallel Change; shipping in one commit is straight Extract Class with cutover; either is acceptable. Citation is honest now.

  **Council findings REJECTED with verified justification:**
  - GPT claimed §4.11 and §24 row #20 do not exist: they do (§4.11 at current lines ~501-508, §24 row #20 added in v1.1). GPT hallucinated the hallucination.
  - GPT claimed `Transcript` is not Sendable, threatening Phase C Option 2: `Transcript` IS `Sendable` (verified at `Sources/EnviousWisprCore/Transcript.swift:43`). The real Option 2 problem is `TranscriptStore` being `@MainActor`, which is what triggered the drop.
  - GPT claimed `Tests/RuntimeUAT/wispr_eyes.py` and `scripts/heart-path-bench.sh` might not exist: both verified present (§4.10).
  - GPT claimed `.claude/knowledge/session-log.md` path is wrong: verified present at that path; not `docs/session-log.md`.
  - GPT flagged `@MainActor` requirement on consumers as problematic: §4.11 verified both `WordCorrectionStep` and `LLMPolishStep` are already `@MainActor`; no current consumer is affected.

  **Compile-error fixes (critical):**
  - §10.2 Phase D — `WeakBox` changed from `struct` to `final class`. Swift forbids `weak` properties in value types; prior sketch would not compile.
  - §9.2 Phase C — Option 2 (async detached save) DROPPED. `TranscriptStore` is `@MainActor public final class`; calling its methods from `Task.detached` is a Swift 6 concurrency violation. Now a single locked choice: synchronous save on MainActor. Future migration to a nonisolated `TranscriptStore` is tracked as a follow-on issue, not this epic.
  - §15.2 Phase R4 — `RotatingFileSink` redesigned from `struct` (racy) to `actor` + `flock(2)` for cross-process serialization. In-process and cross-process safety now both explicit. Council R3 flagged this as CRITICAL; agreed and fixed.

  **Structural numbering fixes:**
  - Duplicate `### 4.9` — second occurrence (rules-files table) renumbered to §4.12.
  - Duplicate `### 25.4` — second occurrence (governance bullets) renumbered to §25.6.

  **Load map additions:**
  - §0.3 — every refactor phase now references §5 (methodology). Every phase blocked on a §27 decision references the specific §27.X (STOP-until-decision marker).
  - §0.3 Phase B row — STOP until §27.1 answer recorded.
  - §0.3 Phase D row — STOP until §27.3 decision recorded.
  - §0.3 R2 row — STOP until §27.4 approach chosen.
  - §0.3 R6 row — STOP unless V4 confirms failure.

  **Gate sections added in phase bodies:**
  - §8.6 Phase B — explicit STOP gate with where-to-record-decision pointer.
  - §10.6 Phase D — explicit STOP gate referencing §27.3.
  - §12.2 R2 — explicit STOP gate referencing §27.4.

  **Dependency graph:**
  - §6.2 ASCII — made V4→R6 arrow explicit (prior version could be read as parallel).

  **Sequencing correction:**
  - §23.1 Session 1 — R5 removed from the Phase-A-parallel set. Phase A ships alone, R3/R4 parallel after A merges, R5 sequential after R3/R4. Council R3 correctly flagged that R5 edits pipeline files and parallel-with-A creates conflict risk even though the specific lines may not overlap.

  **Pattern citation correction:**
  - §10 Phase D — cited "Parallel Change" but the substeps collapsed expand+contract into one PR. Clarified: shipping in two commits within one PR qualifies as Parallel Change; shipping in one commit is straight Extract Class with cutover; either is acceptable. Citation is honest now.

  **Council findings REJECTED with verified justification:**
  - GPT claimed §4.11 and §24 row #20 do not exist: they do (§4.11 at current lines ~501-508, §24 row #20 added in v1.1). GPT hallucinated the hallucination.
  - GPT claimed `Transcript` is not Sendable, threatening Phase C Option 2: `Transcript` IS `Sendable` (verified at `Sources/EnviousWisprCore/Transcript.swift:43`). The real Option 2 problem is `TranscriptStore` being `@MainActor`, which is what triggered the drop.
  - GPT claimed `Tests/RuntimeUAT/wispr_eyes.py` and `scripts/heart-path-bench.sh` might not exist: both verified present (§4.10).
  - GPT claimed `.claude/knowledge/session-log.md` path is wrong: verified present at that path; not `docs/session-log.md`.
  - GPT flagged `@MainActor` requirement on consumers as problematic: §4.11 verified both `WordCorrectionStep` and `LLMPolishStep` are already `@MainActor`; no current consumer is affected.

- **2026-04-18 v1.2 · reader realignment** — §0 rewritten to be honest about the reader (Claude Code, not human). Dropped the three-tier reading-time estimates (10 / 20-30 / 60-90 min) — irrelevant to LLM readers. Replaced with a per-task load map (§0.3) that tells a session executing phase X exactly which sections to read and nothing else. Added explicit Gate 0 discipline section (§0.4) pointing at snippet-verification substep + issue-comment + session-log grep. Net effect: fewer wall-time claims, more direct mapping from "I am executing phase X" to "here are the sections to load."

- **2026-04-18 v1.1 · post-council revision** — Full council review (GPT via gpt-5-codex + Gemini 2.5-pro, both at reasoning_effort=high). 15+ findings each; strong convergence on eight critical fixes. Changes in this revision:

  **Navigation & structure:**
  - §0.3 — replaced unrealistic "~10 min" onboarding claim with three paths (10 / 20-30 / 60-90 min) matched to depth.
  - §2.1 — fixed broken "§12 rollback" navigation pointer; now references phases' actual Rollback subsections (§7.5, §9.5, §10.5).
  - §28 — added `wispr-eyes`, `Characterization test pin`, `Fitness function` to glossary.

  **Factual corrections:**
  - §4.4 — updated PipelineSettingsSync baseline from stale 290 to verified 398 lines / 41 handler branches. Phase B LOC target recalibrated.
  - §4.8 — expanded `RecordingOverlayPanel` note to acknowledge 859 lines and flag as post-epic candidate per Gemini review.
  - §4.9 NEW — verified AppState concrete-dep count = 12 (audit reported 11; both close to reality).
  - §4.10 NEW — verified tool existence (`scripts/heart-path-bench.sh`, `Tests/RuntimeUAT/wispr_eyes.py`).
  - §4.11 NEW — verified `WordCorrectionStep` and `LLMPolishStep` are both `@MainActor`; Phase D's protocol requirement is safe.

  **Methodology corrections:**
  - §5 — softened Strangler Fig framing; acknowledged it's a system-level pattern being borrowed conceptually for intra-class decomposition. Correct mechanics are Extract Class + Move Field + Parallel Change.
  - §9 Phase C — corrected pattern label from "Move Method + Extract Class" to "Move Field + Move Method." Added two implementation options for `append` (sync-on-MainActor vs awaited-async-hop) to address GPT's Task.detached concern; default to synchronous.
  - §9 Phase C substep 6 — enumerated the three greps required to discover view consumers.
  - §10 Phase D — added ASCII before/after sequence diagram; confirmed `@MainActor` protocol assumption empirically.

  **Scope additions:**
  - §11 Phase E — expanded from two fitness tests to three: property-count (strict, architectural), line-count (advisory), and NEW cross-module public-TODO guard. Third test implements audit meta-recommendation #1 which was missing from v1.0.

  **Sequencing revision:**
  - §23.1 — Phase A now ships SOLO first per council consensus, not in parallel with R3/R4/R5. After A merges, three disjoint-file PRs run in parallel.
  - §23.1 Session 2 — V1 Instruments run moved to unattended background so it doesn't count against the 5-hr budget.
  - §23.1 Session 3 — Phase C and Phase D are now SEPARATE PRs, not bundled. Council called the prior bundling a "merge monster."
  - §23.3/§23.4 — updated merge-order guidance and "what not to do" list.

  **Risk register:**
  - Risk #12 upgraded Medium/Low → High/High (merge conflict on AppState adjacent edits).
  - Risk #18 NEW — Bible rot with maintenance protocol in §26.
  - Risk #19 NEW — Phase C async write path data-loss scenario.
  - Risk #20 NEW — Phase E fitness-test gameability.

  **Ship criteria hardening:**
  - §25.3 — added CI cross-module public-TODO guard as a gate.
  - §25.4 NEW — qualitative close-out gate: six questions the founder answers in writing before #319 closes. Prevents mechanical-checkbox-pass without real improvement.
  - §25.5 NEW — concrete architectural metrics recorded at close (line counts, dep counts, public surface counts, audit grade diffs).

  **Maintenance protocol:**
  - §26.1 NEW — bible rot refresh discipline (post-merge updates, snippet re-verification).
  - §26.2 NEW — pre-phase citation-verification step as Gate 0 for bible phases.
  - §26.3 NEW — when to extract a phase into a standalone file.

  **Open questions:**
  - §27.7 NEW — where to capture the Phase B UX decision (three places: issue #195 comment, bible §8.6, bible §30 Changelog).

  Council findings NOT adopted and why:
  - GPT's tool-existence hallucination concern (`scripts/heart-path-bench.sh`, `wispr_eyes.py`) — both tools verified present (§4.10).
  - GPT's @MainActor concern for Phase D consumers — both consumers verified MainActor (§4.11).
  - Gemini's "abandon parallel for strict sequential" — partially adopted. Phase A solo, then three disjoint-file parallels is the middle ground. Pure sequential would extend epic by one session without meaningful risk reduction beyond what §23.1 now provides.
  - Gemini's "brittle LOC test, use cyclomatic complexity instead" — partially adopted. Property-count is the primary fitness function; line-count is advisory backstop. Cyclomatic complexity is a stretch goal noted in §20 risk mitigation.
