import Foundation
import SwiftParser
import SwiftSyntax
import Testing

// MARK: - EngineMutationInventoryFreezeTests (#1741 Chunk 10)
//
// The permanent safety net promised by `EngineMutationScope.swift`'s own doc
// comment (Chunk 1): every sessionless/maintenance call that touches the ASR
// engine must be accounted for — either it acquires the shared
// `EngineMutationScope` (or is reached only from a call chain that already
// holds one), or it is reached only from a context recovery structurally
// cannot race (a live dictation session, or the older `isSwitching`/
// `isRecovering` mutual exclusion), or it is a test-only/dead/unrelated-domain
// call, OR it is a real, confirmed gap tracked by its own open GitHub issue
// (`knownGap` — never a bare comment asserting "fine for now"). A future
// engineer adding a new raw mutation call anywhere in the four scanned
// modules — without classifying it here — fails this build instead of
// silently reintroducing the exact "enforced by convention and reviewer
// memory" gap issue #1741 exists to close.
//
// This is a STRUCTURAL freeze, not a behavior test: it parses source, so it
// catches a new/moved call site no runtime test happens to exercise. Shares
// its fail-closed-count and call-vs-declaration philosophy with
// `EngineSwitchOwnershipFreezeTests` / `WhisperKitGatedLoadFreezeTests` /
// `EngineIdentityFreezeTests`, but those three use a hand-rolled
// comment-skipping text scanner; this one does not.
//
// History (kept because it explains the design, not as a tracker): the first
// version of this suite DID use a hand-rolled character scanner, matching
// its siblings. Hardening its comment/string handling took 5 consecutive
// Codex review rounds (block comments, ordinary strings, raw strings,
// same-line interpolation, multi-line interpolation) with no convergence in
// sight. A web-grounded council consult (GPT-5.6-sol + Gemini-3.1-pro,
// 2026-07-22) confirmed this is a known, named class of problem — SwiftLint's
// own multi-year regex-to-SwiftSyntax migration is the closest real-world
// precedent — and that a real parser is the right fix once a scanner needs
// this level of lexical precision. This suite now parses every scanned file
// with `SwiftParser` (the same front-end the Swift compiler itself uses) and
// walks the resulting syntax tree with a `SyntaxVisitor`, so comments and
// every string form are structurally excluded rather than pattern-matched
// around. `swift-syntax` is a test-target-only SPM dependency (`Package.swift`)
// — it never reaches the shipped app.
//
// A real parser fixed the comment/string axis completely, but a second,
// narrower axis then surfaced and cost THREE more redesigns before it was
// recognized as a CONTRACT problem, not an implementation gap: trying to
// prove, from syntax alone, that a `FunctionCallExprSyntax`'s callee is
// DEFINITELY one of the 13 vocabulary methods. Round 1 unwrapped 3 wrapper
// kinds (parens, force-unwrap, optional-chaining) one at a time; round 2's
// Codex review found a 4th (`as`-casts) and warned more existed, so the
// design was generalized (fold every operator sequence with `SwiftOperators`,
// unwrap a closed, exhaustively-enumerated set of ~12 identity-preserving
// node kinds); the NEXT review round then found a missed value-selecting
// construct (postfix `#if`) AND a condition-vs-value precision bug in the
// new "ambiguous branching value" detector that redesign had added. Three
// consecutive rounds finding "one more shape in the same area" is exactly
// this repo's own signal to stop patching and name the class — so the
// founder called it what it was: the test was asking an unnecessarily hard
// question ("is this DEFINITELY the function being called?") when a safety
// NET only needs a much simpler, provably complete one: "does this source
// contain any real code reference to a protected name at all?"
//
// A web-grounded council review (GPT-5.6-sol + Gemini-3.1-pro, 2026-07-22,
// unanimous, no disagreement) confirmed this reframing — real precedent:
// SwiftLint's own banned-API rules, Semgrep, and Android Lint all catch a
// forbidden name conservatively rather than trying to prove invocation, and
// let an explicit baseline/allowlist absorb the harmless matches. This suite
// now does the same: it inventories every real code reference (bare or
// member-access) whose terminal name matches the vocabulary, makes NO
// attempt to determine whether that reference is ultimately called, stored,
// passed, or merely mentioned, and classifies every match in the same
// inventory table this file has always used. This closes the wrapper axis,
// the operator-folding axis, and the branching-ambiguity axis all at once —
// none of them matter when the question is "is the name referenced" rather
// than "is this specifically a call." It also closes a boundary the PRIOR
// design had to accept: a stored method reference (`let f = adapter.warmUp`)
// is now caught at the point of reference, not lost to an untraceable alias.
// `SwiftOperators` (operator-sequence folding) was removed entirely — it
// existed only to resolve a call's callee, which this design no longer does.
//
// Classification is a REVIEW aid, not something a parser can derive alone —
// "is this call protected" requires reading control flow. The mechanical
// guarantee this suite enforces is narrower and load-bearing on its own: the
// exact MULTISET of live call sites (by file + matcher + normalized text)
// must match this frozen table. A site that appears, disappears, or is
// duplicated fails immediately; the classification labels are then verified
// by self-review and Codex against live source (never trusted as-is).
//
// Chunk 11 (2026-07-23): what this suite covers, and an honest statement of
// what it cannot. A grounded review of Chunk 10's original 13-name
// vocabulary found it omitted real engine-mutating methods. Grounding
// expanded the deliberately bounded surface from three protocols to ten:
// seven additional known protocols this file had not previously enumerated
// (`ASREngineLanguageIdentifying`, `ASREngineWarmupCancelling`,
// `WhisperKitBackendDriving`, `WhisperKitIncrementalSession`,
// `WhisperKitTranscribing`, `ASRServiceProtocol`,
// `ASREngineTelemetryProviding` — some read-only, frozen for drift even
// though they are not vocabulary candidates themselves; see
// `EngineProtocolSurfaceFreezeTests` for all ten's frozen signatures) plus
// two concrete-only method surfaces not declared by any of the ten frozen
// protocols (`WhisperKitEngineAdapter.unloadForRemoval()`, reached via a
// type-cast at one call site; `ParakeetBackend.prepare(cacheOnly:progressCallback:)`,
// reached via a type-cast at one call site AND via direct, uncast
// construction/ownership at another — `ASRServiceHandler.swift` builds and
// holds a concrete `ParakeetBackend` natively, so "reached only via a cast"
// would be false for this one). Two consecutive grounded
// Codex reviews each found "one more engine-facing surface" the prior pass
// had missed — including, on the second pass, a structural hole in a
// proposed general downcast scanner (a real production call site takes a
// concrete engine type directly as a typed parameter, no cast at all). That
// pattern — repeated discovery with no sign of converging to zero — is this
// project's own signal that hand-enumerating "every possible way into the
// engine" cannot be proven exhaustive, and that trying to build a
// general-purpose detector for it was the wrong goal.
//
// So Chunk 11 does NOT claim, and no comment in this file should ever claim
// again, that this suite "detects all future engine-touching code," proves
// the vocabulary is complete, or makes an unsafe engine access structurally
// impossible. What it DOES do, concretely: freezes the reference inventory
// for every method name in `vocabulary` below (this file) and the exact
// signatures of the ten protocols named above plus the two known concrete
// escape hatches (`EngineProtocolSurfaceFreezeTests`) — so a NEW reference to
// an ALREADY-tracked name, or a change to an ALREADY-tracked protocol's
// signature, fails the build and demands classification. It does NOT, and
// structurally cannot, discover a brand-new protocol nobody has told it
// about, a brand-new concrete type, a new XPC route, a macro-generated call,
// or a concrete engine type accessed with no protocol and no cast at all —
// those require a human doing the same kind of grounding pass that found the
// ten protocols and two escape hatches here, not a bigger test. Real,
// already-known production races found along the way are tracked as
// `knownGap` entries pointing at their own issues (#1745, #1749) — this
// suite documents them; it does not fix them, and a test cannot substitute
// for the documentation, code review, and engineering judgment an actual
// fix or a future architecture change would need.
@Suite struct EngineMutationInventoryFreezeTests {

  // MARK: Classification

  enum Classification: Sendable {
    /// The call sits directly inside one of the 16 established
    /// `engineMutationScope.withClaim(site:)` closures (or, for the
    /// sessionless load-wedge guard, is armed/disarmed across exactly that
    /// claim's own lifetime — `KernelDictationDriver.ensureEngineWarm`'s
    /// `SessionlessLoadWedgeGuard`).
    case gated
    /// Reached only from within crash-recovery's own `recoveryEngineClaim`
    /// hold — currently unpopulated. `ActiveEngineOperation`'s `load` calls
    /// are reached by both `RecoverySpoolReplayer` (recovery) AND
    /// `BenchmarkSuite` (Diagnostics, under its own `engineMutationScope`
    /// claim), so they are NOT recovery-exclusive and are
    /// `transitivelyCoveredByCaller` instead. `ActiveEngineOperation`'s
    /// `hardCancel` calls ARE recovery-exclusive (Diagnostics never calls
    /// `hardCancel`) but are NOT reliably covered by the claim for their full
    /// duration (see `knownGap`, tracked at #1745) — recovery-exclusive is
    /// necessary but not sufficient for this case; the claim must also
    /// actually stay held throughout. Kept in the enum for the shape the
    /// founder's classification scheme specifies; a future recovery-only raw
    /// call that IS fully covered for its whole duration would take this case.
    case recoveryOwned
    /// Not itself gated, and not tied to one specific structural fact — its
    /// safety is entirely inherited from whichever caller reached it (a
    /// shared adapter/backend/XPC internal called via a chain rooted in a
    /// `gated` or `structurallySafe` entry point).
    case transitivelyCoveredByCaller
    /// Protected by a DIFFERENT, pre-#1741 mechanism, not by
    /// `EngineMutationScope`: either (a) reached only from within an active
    /// recording session, which structurally precludes a recovery claim from
    /// existing (recovery's atomic handshake requires `!isDictationActive()`
    /// — RULE: close-the-window-never-handle-it, documented not gated), (b)
    /// the older `EngineCoordinator.isSwitching` / `RecoveryCoordinator`
    /// bidirectional check that already gives full-duration mutual exclusion
    /// for an engine SWITCH specifically, or (c) a call that cannot conflict
    /// with recovery regardless of timing because the callee re-acquires its
    /// own claim internally on every invocation, or performs no actual engine
    /// mutation (a pure readiness read).
    case structurallySafe
    /// Present in source, reachable in theory, but never exercised by current
    /// production configuration (a test-seam override that is always nil in
    /// production).
    case dormant
    /// Touches a different subsystem entirely (VAD, not the ASR engine) —
    /// matched only because the method name coincides with the vocabulary.
    case unrelatedDomain
    /// A REAL, CONFIRMED protection gap — not safe, not covered by any of the
    /// six categories above, and not being papered over as one. Codex's
    /// Chunk 10 round-1 review found and confirmed this itself: the recovery
    /// Discard path's engine reset is fire-and-forget (an unawaited,
    /// unstructured `Task { ... }` — NOT `Task.detached`, but the same
    /// unawaited-completion hazard in effect here), so the recovery claim can
    /// release before that reset actually finishes, letting another mutation
    /// start touching the same engine while the abandoned reset is still
    /// running underneath it. #1741 does NOT fix this — it is out of this
    /// issue's scope (a pre-existing bug, unrelated to the ten-consumer
    /// capability migration) and requires a production code change this
    /// test-only chunk is not authorized to make. Every use of this case
    /// names an issue number and reason (structurally required by this
    /// case's associated values) — Test 9 checks that structure and that no
    /// other entry is quietly relabeled into this case to dodge Test 1; it
    /// cannot itself verify the issue is real or still open on GitHub, which
    /// is a matter for self-review and Codex, not this suite.
    case knownGap(issue: Int, reason: String)
  }

  /// Stable identity: file + matcher + normalized (trimmed) source text +
  /// classification. Deliberately NOT line number — a reformat that keeps the
  /// same call unchanged must not spuriously fail. Two physically distinct
  /// call sites with identical trimmed text (e.g. `WhisperKitEngineAdapter`'s
  /// two `await backend.unload()` claim closures) are represented as two
  /// array entries, preserving multiplicity as its own signal.
  struct CallSite {
    let file: String
    let matcher: String
    let text: String
    let classification: Classification
  }

  /// The comparison key — classification excluded, since the live scanner
  /// (plain text matching) cannot derive it. Test 1 compares raw-key
  /// multisets; the classification riding on each `CallSite` is what a human
  /// or Codex reviews against live source, never what the scanner checks.
  struct SiteKey: Hashable {
    let file: String
    let matcher: String
    let text: String
  }

  struct RawHit {
    let file: String
    let matcher: String
    let text: String
    let line: Int
    var key: SiteKey { SiteKey(file: file, matcher: matcher, text: text) }
  }

  // MARK: Vocabulary — sessionless/maintenance mutation calls only

  /// Vocabulary as of the #1741 Chunk 11 bounded known-surface freeze
  /// (2026-07-23), superseding Chunk 10's original 13 names. Two grounded
  /// Codex plan reviews traced the full engine-facing surface across TEN
  /// protocols (`ASRBackend`, `ASRManagerInterface`, `ASREngineAdapter`,
  /// `ASREngineLanguageIdentifying`, `ASREngineWarmupCancelling`,
  /// `WhisperKitBackendDriving`, `WhisperKitIncrementalSession`,
  /// `WhisperKitTranscribing`, `ASRServiceProtocol`,
  /// `ASREngineTelemetryProviding` — see `EngineProtocolSurfaceFreezeTests`
  /// for their frozen signatures) plus two concrete-only method surfaces not
  /// declared by any of the ten frozen protocols
  /// (`WhisperKitEngineAdapter.unloadForRemoval()`, reached via a type-cast;
  /// `ParakeetBackend.prepare(cacheOnly:progressCallback:)`, reached via a
  /// type-cast at one call site and via direct, uncast construction/ownership
  /// in `ASRServiceHandler`; both are already caught here because their names
  /// match an existing/added entry below. Only their EXISTENCE and signature
  /// were invisible to the old name-only protocol check, which
  /// `EngineProtocolSurfaceFreezeTests` now pins explicitly).
  ///
  /// New in Chunk 11: `transcribe`, `feedAudio`, `finalizeStreaming`,
  /// `cancelStreaming` (Codex's original finding — real across ALL of
  /// `ASRBackend`/`ASRManagerInterface`/`ASRServiceProtocol`, matched once
  /// per name since bare-identifier matching does not distinguish layers),
  /// `beginSession`, `acceptAudio`, `finalize` (`ASREngineAdapter` /
  /// `WhisperKitIncrementalSession` — `finalize` also matches
  /// `WhisperKitStreamingSession.finalize(finalSamples:speechSegments:)`,
  /// a different type sharing the bare name; classified like every other
  /// entry, not specially unified), `observeLID`, `makeStreamingSession`
  /// (`WhisperKitBackendDriving`), `cancelSessionlessWarmup`
  /// (`ASREngineWarmupCancelling`), `unloadForRemoval` (concrete-only,
  /// reached via `adapter as? WhisperKitEngineAdapter`), `transcribeSamples`,
  /// `feedAudioBuffer` (`ASRServiceProtocol` — its own `loadModel`/
  /// `unloadModel`/`startStreaming`/`finalizeStreaming`/`cancelStreaming`
  /// requirements share bare names already tracked, so only these two
  /// XPC-specific names are new).
  ///
  /// Deliberately excludes `applyUnloadPolicy(` — a container that arms a
  /// policy-scoped Task, not a raw mutation call itself (its own body's
  /// `backend.unload()` is what the `unload` matcher below catches) — and,
  /// for the same reason, `noteTranscriptionComplete`: both route to an
  /// already-tracked `unload`/`unloadModel` reference; the CORRECT reason to
  /// exclude them is that their target is independently caught, NOT (an
  /// earlier draft's wrong claim) that they "don't gate engine mutation" —
  /// `applyUnloadPolicy`'s `.immediately` case directly arms a real
  /// deferred `backend.unload()` call (`WhisperKitEngineAdapter.swift:1072`).
  ///
  /// Two names are deliberately excluded despite being real engine
  /// operations, for the SAME bare-name-collision reason, each documented
  /// with its real production call sites so the exclusion is never mistaken
  /// for an oversight:
  /// - `cancel` (`ASREngineAdapter`/`WhisperKitIncrementalSession`): ~134
  ///   raw text matches across the four scanned roots, almost all
  ///   `Task.cancel()`/`<x>Task?.cancel()` and other types' own unrelated
  ///   `cancel()` methods. The real engine-touching sites are
  ///   `KernelDictationDriver.swift:641`, `RecordingSessionKernel.swift:3852`
  ///   (`adapter.cancel()`), and `WhisperKitEngineAdapter.swift:988`
  ///   (`live.cancel()`, forwarding to `WhisperKitStreamingSession.cancel()`).
  ///   NOT claimed safe merely because their owners hold
  ///   `EngineMutationScope` — `RecordingSessionKernel.swift:3852`'s call
  ///   specifically sits inside the #1749 race window (see the doc comment
  ///   above `expected` for how that race surfaces in this table instead,
  ///   through `transcribe`).
  /// - `start` (`WhisperKitIncrementalSession`): 25 raw text matches, almost
  ///   all `Timer`/`NWListener`/`NWConnection`/hotkey-service/watcher
  ///   `.start()` calls with no relation to the ASR engine. The real sites
  ///   are `TailBenchmarkHarness.swift:163`, `TailBenchmarkHarness.swift:288`,
  ///   and `WhisperKitEngineAdapter.swift:526` (`session.start(audioSamplesProvider:)`).
  ///
  /// Both exclusions are permanent under THIS design, not temporary
  /// oversights — a future rename of either protocol requirement (e.g.
  /// `cancelEngine()`, `startIncrementalDecoding()`) would remove the
  /// bare-name collision and let either be tracked; that rename is out of
  /// scope for this chunk (no separate architecture issue tracks it — a
  /// test suite is a guardrail, not a substitute for the documentation,
  /// review, and engineering judgment an actual rename decision needs).
  ///
  /// #1741 Chunk 10, council-approved contract pivot, unchanged by Chunk 11:
  /// a "hit" is any real code reference (bare `DeclReferenceExprSyntax`, or
  /// the `.declName` of a `MemberAccessExprSyntax` — see `CallSiteVisitor`
  /// below) whose terminal identifier is one of these names — not a proof
  /// that the reference is ultimately called. `switchBackend` is matched
  /// uniformly like every other name; the founder's prior
  /// `.switchBackend(to:` argument-label distinction was deliberately
  /// dropped (Codex plan review: keeping any argument-shape special case
  /// reintroduces the exact "does this shape count" question the pivot
  /// exists to retire — the one production reference already carries `to:`
  /// in its recorded source text descriptively, so no information is lost).
  private static let vocabulary: Set<String> = [
    "warmUp", "warmUpFromCache", "unload", "unloadModel", "prepare", "loadModel", "loadModels",
    "switchBackend", "startStreaming", "cancelInFlightLoad", "recoverFromWedge",
    "recoverFromASRInterruption", "retryDecode",
    // Chunk 11 additions:
    "transcribe", "feedAudio", "finalizeStreaming", "cancelStreaming", "beginSession",
    "acceptAudio", "finalize", "observeLID", "makeStreamingSession", "cancelSessionlessWarmup",
    "unloadForRemoval", "transcribeSamples", "feedAudioBuffer",
  ]

  /// A member-access reference (`adapter.warmUp`) or bare reference
  /// (`warmUp`) is a real `DeclReferenceExprSyntax` node; the matching
  /// DECLARATION (`func warmUp(`) is a completely different node kind
  /// (`FunctionDeclSyntax`, whose name is a plain `TokenSyntax`, never
  /// wrapped in an expression node) that this visitor never visits as a
  /// reference at all — the same call-vs-declaration precision
  /// `EngineSwitchOwnershipFreezeTests` / `EngineIdentityFreezeTests` rely on,
  /// guaranteed by the parser's own grammar.
  ///
  /// The prior design's one accepted, irreducible boundary — a method
  /// reference assigned to a variable and called later
  /// (`let f = adapter.warmUp; await f()`) — is CLOSED by this contract
  /// pivot, not merely documented: the assignment line itself contains a
  /// real reference to `warmUp` and is caught and classified there. Only a
  /// reference with NO source-level spelling of the name at all (macro-
  /// generated code, or a call constructed via string-based reflection, e.g.
  /// `NSSelectorFromString("warmUp")`) is outside this test's reach — grep-
  /// verified zero occurrences of either shape across the four scanned
  /// directories today. If EnviousWispr ever adopts one of those mechanisms
  /// for ASR mutation, it needs its own explicit policy, not a bigger
  /// version of this inventory.
  private static let scannedRoots = [
    "Sources/EnviousWisprASR",
    "Sources/EnviousWisprPipeline",
    "Sources/EnviousWisprAppKit",
    "Sources/EnviousWisprASRService",
  ]

  // MARK: Frozen classified inventory, re-derived from source and cross-
  // checked against every `#1707 Phase 3 (§3.2, row N)` breadcrumb comment
  // still in the codebase; the underlying 27-row plan document is external
  // to this repo per the issue #1741 GitHub comment.
  //
  // Entry count history: 45 (round 6, the switch to a real parser found a
  // trailing-closure `unloadModel` call the old regex could never match) →
  // 54 (a bare-call widening found 9 more genuine call sites) → council-
  // approved contract pivot (this state): every real reference, not just
  // call sites, now requires classification — see the file-level doc
  // comment above for the full history. `switchBackendTo` was renamed to
  // `switchBackend` (the argument-label distinction was dropped, see the
  // vocabulary doc comment above).

  private static let expected: [CallSite] = [
    // MARK: ActiveEngineOperation — the one door for crash-recovery + the
    // Diagnostics benchmark. Not itself gated. `load` is called from BOTH
    // `RecoverySpoolReplayer` (under `recoveryEngineClaim`) and
    // `BenchmarkSuite.ensureModelLoaded` (under its own
    // `engineMutationScope.withClaim`) — always reached with a claim already
    // held, so `transitivelyCoveredByCaller` rather than `recoveryOwned`.
    // #1749 (found during the Chunk 11 grounding pass): this `load` closure is
    // reached from BOTH `BenchmarkSuite` (safe, its own separate claim) and
    // `RecoverySpoolReplayer` (recovery) — but recovery's claim does not wait
    // for a just-ended ordinary session's unawaited termination cleanup to
    // finish before this call proceeds, so this single physical site carries
    // the less-safe caller's classification rather than a caller-averaged one.
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "prepare",
      text: "try await whisperKitBackend.prepare()",
      classification: .knownGap(
        issue: 1749,
        reason:
          "recovery's claim does not wait for a just-ended ordinary session's unawaited termination cleanup to finish before this call proceeds"
      )),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "loadModel",
      text: "try await asrManager.loadModel()",
      classification: .knownGap(
        issue: 1749,
        reason:
          "recovery's claim does not wait for a just-ended ordinary session's unawaited termination cleanup to finish before this call proceeds"
      )),
    // #1749: recovery's two concrete transcribe routes, reached only after
    // the `load` calls directly above.
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "transcribe",
      text:
        "return try await whisperKitBackend.transcribe(audioSamples: samples, options: options)",
      classification: .knownGap(
        issue: 1749,
        reason:
          "recovery's claim does not wait for a just-ended ordinary session's unawaited termination cleanup to finish before this call proceeds"
      )),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "transcribe",
      text: "return try await asrManager.transcribe(audioSamples: samples, options: options)",
      classification: .knownGap(
        issue: 1749,
        reason:
          "recovery's claim does not wait for a just-ended ordinary session's unawaited termination cleanup to finish before this call proceeds"
      )),
    // #1749 — the original site this whole gap was found at: `RecoverySpoolReplayer`'s
    // own call into `activeEngine.transcribe`, one caller of the two
    // `ActiveEngineOperation` transcribe routes directly above.
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/RecoverySpoolReplayer.swift", matcher: "transcribe",
      text: "result = try await activeEngine.transcribe(recovered.samples, options)",
      classification: .knownGap(
        issue: 1749,
        reason:
          "recovery's claim does not wait for a just-ended ordinary session's unawaited termination cleanup to finish before this call proceeds"
      )),
    // `hardCancel` is DIFFERENT: its sole production caller
    // (`RecoveryCoordinator.discardActiveRecovery()` -> `resetEngine` closure,
    // `WisprBootstrapper.swift:669`) fires it inside an unawaited, unstructured
    // `Task { ... }` (NOT `Task.detached` — a plain `Task` closure, but the
    // same unawaited-completion hazard applies here). The recovery claim
    // releases via the scan loop's own `defer` as soon as
    // `replayer.replay(...)` returns, with no synchronization against that
    // Task actually finishing — so a WhisperKit `unload()` here can still be
    // running after the claim (and thus this exact protection) has already
    // been given up. Confirmed real by Codex (Chunk 10 round 1); tracked at
    // #1745, which #1741 does NOT fix (production change, out of this
    // test-only chunk's scope).
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "unload",
      text: "await whisperKitBackend.unload()",
      classification: .knownGap(
        issue: 1745,
        reason:
          "hardCancel fires in an unawaited Task the recovery claim's release does not wait for"
      )),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift",
      matcher: "cancelInFlightLoad", text: "asrManager.cancelInFlightLoad()",
      classification: .knownGap(
        issue: 1745,
        reason:
          "hardCancel fires in an unawaited Task the recovery claim's release does not wait for"
      )),

    // MARK: BenchmarkSuite — direct call inside its own "benchmarkSuiteStreaming" claim.
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/BenchmarkSuite.swift", matcher: "startStreaming",
      text: "try await asrManager.startStreaming(options: .default)", classification: .gated),

    // MARK: WisprBootstrapper — the sole `.switchBackend(to:)` call site
    // (frozen separately by `EngineSwitchOwnershipFreezeTests`). Protected by
    // the older, pre-#1741 `EngineCoordinator.isSwitching` /
    // `RecoveryCoordinator.isEngineSwitching()` bidirectional MainActor
    // check — a genuinely different, already-adequate mutual-exclusion
    // mechanism, never migrated onto `EngineMutationScope`.
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift", matcher: "switchBackend",
      text: "await asrManager.switchBackend(to: backend)", classification: .structurallySafe),

    // MARK: ASRManager
    // `switchBackend(to:)`'s internal unload — same structural protection as
    // the call site above (its one and only caller).
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "unload",
      text: "await activeBackend?.unload()", classification: .structurallySafe),
    // `loadModel()`'s Parakeet-prepare calls — reached via `adapter.warmUp()`,
    // itself reached via gated (`ensureEngineWarm`/`preWarm`) AND
    // structurally-safe (session-scoped `recoverFromASRInterruption`/
    // `retryDecode`/row-22 warmUp) callers alike.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "prepare",
      text: "try await parakeet.prepare(cacheOnly: true, progressCallback: progress)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "prepare",
      text: "try await self.parakeetBackend.prepare(progressCallback: progress)",
      classification: .transitivelyCoveredByCaller),
    // `startStreaming(options:)` — reached via BenchmarkSuite's gated claim
    // AND `ParakeetEngineAdapter.beginSession`'s structurally-safe
    // (session-start / minting-window) call; its own protection is inherited.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "startStreaming",
      text: "try await activeBackend.startStreaming(options: options)",
      classification: .transitivelyCoveredByCaller),
    // The real unload, directly inside "asrManagerUnload"'s claim closure.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "unload",
      text: "await activeBackend.unload()", classification: .gated),
    // Idle-timer firing `unloadModel()` on itself. Safe regardless of when it
    // fires: `unloadModel()`'s OWN body re-acquires "asrManagerUnload"
    // internally on every call, by construction — not because of anything
    // about this call site or its caller.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "unloadModel",
      text: "_ = Task<Void, Never> { await self?.unloadModel() }",
      classification: .structurallySafe),
    // `noteTranscriptionComplete`'s immediate-unload branch — a bare, implicit-
    // `self` call the visitor could not see before Codex r1 (SwiftSyntax-pivot
    // round) required `DeclReferenceExprSyntax` callee matching too. Same
    // reasoning as the `self?.unloadModel()` idle-timer entry directly above:
    // `unloadModel()`'s own body re-acquires its claim internally regardless
    // of how it is reached.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "unloadModel",
      text: "Task { await unloadModel() }", classification: .structurallySafe),

    // MARK: ASRManagerProxy — the XPC-fronted mirror of ASRManager.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "loadModel",
      text: "proxy.loadModel(backendType: self.activeBackendType.rawValue, cacheOnly: cacheOnly) {",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "startStreaming",
      text: "proxy.startStreaming(", classification: .transitivelyCoveredByCaller),
    // Same reasoning as ASRManager's idle-timer trigger above.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "unloadModel",
      text: "_ = Task<Void, Never> { await self?.unloadModel() }",
      classification: .structurallySafe),
    // `switchBackend`'s pre-switch drain — bare, implicit `self`. Same
    // self-re-acquiring-claim reasoning as every other bare/optional
    // `unloadModel()` call in this file.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "unloadModel",
      text: "if isModelLoaded { await unloadModel() }", classification: .structurallySafe),
    // `noteTranscriptionComplete`'s immediate-unload branch — the proxy-side
    // twin of ASRManager's identical bare call above.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "unloadModel",
      text: "Task { await unloadModel() }", classification: .structurallySafe),
    // The real XPC forwarding call, a trailing-closure call
    // (`proxy.unloadModel { cont.resume() }` — no parentheses), which the
    // OLD regex-based scanner's `\.unloadModel\(` pattern could never match
    // (it required a literal `(` immediately after the name) — a real gap in
    // the retired scanner's coverage that the semantic, parser-based visitor
    // now correctly closes (#1741 Chunk 10 round 6, found on first real run).
    // Directly inside `unloadModel()`'s own "asrManagerProxyUnload" claim
    // closure — nested inside `withCheckedContinuation`/`serviceProxy`'s
    // synchronous callback setup, never crossing a new claim boundary.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "unloadModel",
      text: "proxy.unloadModel {", classification: .gated),

    // MARK: ASRProtocol — the shared `ASRBackend` protocol extension's
    // default `prepare(progressCallback:)`, used by any conformer that does
    // not override it (ParakeetBackend does; WhisperKitBackend does not).
    // Its bare, implicit-`self` forward to `prepare()` dispatches
    // polymorphically to whichever concrete backend is live — already
    // covered by that backend's own already-classified `prepare()` entry
    // (e.g. `whisperKitBackend.prepare()` at `ActiveEngineOperation.swift`,
    // `transitivelyCoveredByCaller`). This forward crosses no new claim
    // boundary of its own.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRProtocol.swift", matcher: "prepare",
      text: "try await prepare()", classification: .transitivelyCoveredByCaller),

    // MARK: ParakeetBackend — FluidAudio's own manager, one layer below
    // ASRManager's `.prepare()`/`.startStreaming()`. Same inherited coverage.
    // The two bare `prepare()` overloads below both forward, implicit-`self`,
    // to this file's own `prepare(cacheOnly:progressCallback:)` — the same
    // instance already reached (for the no-callback overload) via
    // `whisperKitBackend.prepare()`-shaped external calls, or (for the
    // callback overload) via `ASRManager`'s `self.parakeetBackend.prepare(
    // progressCallback:)`, both already counted, `transitivelyCoveredByCaller`.
    CallSite(
      file: "Sources/EnviousWisprASR/ParakeetBackend.swift", matcher: "prepare",
      text: "try await prepare(cacheOnly: false, progressCallback: nil)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ParakeetBackend.swift", matcher: "prepare",
      text: "try await prepare(cacheOnly: false, progressCallback: progressCallback)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ParakeetBackend.swift", matcher: "loadModels",
      text: "try await manager.loadModels(loadedModels)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ParakeetBackend.swift", matcher: "loadModels",
      text: "try await manager.loadModels(models)", classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ParakeetBackend.swift", matcher: "startStreaming",
      text: "try await manager.startStreaming(source: .microphone)",
      classification: .transitivelyCoveredByCaller),

    // MARK: WhisperKitBackend — test-seam override, always nil in production.
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitBackend.swift", matcher: "loadModel",
      text: "if let seams = testSeams { return try await seams.loadModel(modelPath) }",
      classification: .dormant),

    // MARK: ASRServiceHandler — the XPC helper process's two forwarding
    // sites. No gate of its own is possible (a separate process); both are
    // covered only because the client (ASRManagerProxy) never sends the
    // message unless ITS OWN call chain already holds adequate protection.
    CallSite(
      file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "startStreaming",
      text: "try await parakeet.startStreaming(options: options)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "prepare",
      text: "try await backend.prepare(cacheOnly: cacheOnly) { fraction, phase, detail in",
      classification: .transitivelyCoveredByCaller),

    // MARK: CaptureVADSignalSource — a different subsystem (voice-activity
    // detection), not the ASR engine. Matched only by method-name coincidence.
    CallSite(
      file: "Sources/EnviousWisprPipeline/CaptureVADSignalSource.swift", matcher: "prepare",
      text: "try await detector.prepare()", classification: .unrelatedDomain),

    // MARK: KernelDictationDriver
    // The SESSIONLESS load-wedge guard's fire path. `SessionlessLoadWedgeGuard`
    // is armed immediately before, and disarmed immediately after,
    // `ensureEngineWarm`'s own "ensureEngineWarm" claim — both transitions
    // are synchronous MainActor steps with no intervening `await`, so the
    // guard's live window never outlives the claim in any observable way.
    // (The Phase-3-era "row 2" breadcrumb at this claim's own comment block
    // confirms this exact site was accounted for in the original plan, not
    // an oversight.)
    CallSite(
      file: "Sources/EnviousWisprPipeline/KernelDictationDriver.swift", matcher: "recoverFromWedge",
      text: "await self.adapter.recoverFromWedge()", classification: .gated),
    // Direct call inside "ensureEngineWarm"'s own claim closure.
    CallSite(
      file: "Sources/EnviousWisprPipeline/KernelDictationDriver.swift", matcher: "warmUp",
      text: "try await adapter.warmUp()", classification: .gated),

    // MARK: ParakeetEngineAdapter
    // `recoverFromASRInterruption()`'s own recursive warm-up — that function
    // has exactly one caller (`RecordingSessionKernel`'s mid-`.delivering`
    // ASR-interruption salvage), itself session-scoped.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "warmUp",
      text: "try await self.warmUp()", classification: .structurallySafe),
    // `retryDecode()`'s own repair-before-retry re-warm — a bare, implicit-
    // `self` call inside the SAME session-scoped `retryDecode` whose external
    // call site is already `structurallySafe` below (`RecordingSessionKernel`
    // reaches it only mid-`.delivering`). Inherits that same guarantee.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "warmUp",
      text: "try await warmUp()", classification: .structurallySafe),
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
      matcher: "cancelInFlightLoad", text: "self.asrManager.cancelInFlightLoad()",
      classification: .structurallySafe),
    // `loadModelWithTransportRecovery()`'s primary + one-shot-retry loads —
    // reached only via `warmUp()`, itself both gated- and
    // structurally-safe-reachable.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "loadModel",
      text: "try await asrManager.loadModel()", classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "loadModel",
      text: "try await asrManager.loadModel()", classification: .transitivelyCoveredByCaller),
    // `beginSession()`'s streaming start — reached only at a session's own
    // start, inside the minting window `isMintingAnySession` covers.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "startStreaming",
      text: "try await asrManager.startStreaming(options: options)",
      classification: .structurallySafe),
    // `cancel()`'s in-flight-load release — its dominant caller is genuine
    // session termination (structurally safe); its one sessionless caller
    // (`cancelSessionlessWarmup()`, the onboarding-install Cancel) performs a
    // synchronous, generation-scoped flag reset that touches no state
    // recovery's OWN load/session generation reads, and `EngineRecoveryGate`
    // explicitly tolerates non-recovery mutations overlapping each other.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
      matcher: "cancelInFlightLoad", text: "asrManager.cancelInFlightLoad()",
      classification: .structurallySafe),
    // `recoverFromWedge()`'s release — called only by the kernel's
    // SESSION-scoped load-wedge detector.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
      matcher: "cancelInFlightLoad", text: "asrManager.cancelInFlightLoad()",
      classification: .structurallySafe),
    // `retryDecode()`'s repair-before-retry release — `retryDecode` itself is
    // session-scoped (called only from `RecordingSessionKernel`'s ASR-failure
    // handling mid-`.delivering`).
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
      matcher: "cancelInFlightLoad", text: "asrManager.cancelInFlightLoad()",
      classification: .structurallySafe),

    // MARK: RecordingSessionKernel — every site below fires only from within
    // an active recording session (`.arming`/`.delivering`), which
    // structurally precludes a recovery claim from existing.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift",
      matcher: "recoverFromASRInterruption",
      text: "let recovery = await adapter.recoverFromASRInterruption()",
      classification: .structurallySafe),
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "retryDecode",
      text: "operation: { [adapter] in await adapter.retryDecode(inputSamples: retryInput) },",
      classification: .structurallySafe),
    // Row 22 — "confirmed already safe, no code change" per this file's own
    // doc comment at the site.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "warmUp",
      text: "try await adapter.warmUp()", classification: .structurallySafe),
    // The kernel's own session-entry dispatch to its PRIVATE `warmUp(_ sid:)`
    // (row 22 above) — a bare, implicit-`self` call to a same-instance
    // method, not a new engine touch of its own. The real engine mutation
    // happens one level deeper, inside that private method's body, via the
    // `adapter.warmUp()` member-access call already counted (both entries
    // immediately above and below this one).
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "warmUp",
      text: "let warmResult = await warmUp(sid)", classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift",
      matcher: "recoverFromWedge",
      text: "await adapter.recoverFromWedge()", classification: .structurallySafe),
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift",
      matcher: "recoverFromWedge",
      text: "await adapter.recoverFromWedge()", classification: .structurallySafe),
    // `preWarm()`'s best-effort cache-only pre-load, BEFORE the "preWarm"
    // claim starts. Performs no actual engine mutation for either engine
    // today (WhisperKit: a pure readiness read; Parakeet: the protocol's
    // no-op default) — cannot conflict with recovery regardless of timing.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift",
      matcher: "warmUpFromCache", text: "try? await adapter.warmUpFromCache()",
      classification: .structurallySafe),
    // Direct call inside "preWarm"'s own claim closure.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "warmUp",
      text: "try await adapter.warmUp()", classification: .gated),

    // MARK: OnboardingV2View — `startSetup(warmUp:settings:)`'s bare
    // `await warmUp()` invokes a LOCAL PARAMETER (`warmUp: @MainActor ()
    // async -> EngineWarmupOutcome`), not `ASRBackend.warmUp() async throws`
    // directly — the visitor cannot distinguish a bare call to a local
    // closure parameter from a bare call to a same-type instance method,
    // both being `DeclReferenceExprSyntax`. Codex round 2 correction: its one
    // real caller (`OnboardingV2View.swift:546`) supplies
    // `DictationRuntime.ensureActiveEngineWarmForOnboarding()`, which routes
    // through `KernelDictationDriver.ensureEngineWarm(reason:)` to the
    // already-counted, `gated` `adapter.warmUp()` call above — so this DOES
    // touch the ASR subsystem, via the callee re-acquiring (transitively)
    // the same claim regardless of how the closure got here.
    // `structurallySafe` category (c): reached only through a chain whose
    // real engine touch re-acquires its own claim internally.
    CallSite(
      file: "Sources/EnviousWisprAppKit/Views/Onboarding/OnboardingV2View.swift",
      matcher: "warmUp", text: "let outcome = await warmUp()",
      classification: .structurallySafe),
    // The one newly measured reference under the council-approved contract
    // pivot (Codex plan-review r1 predicted this exact site): one step
    // EARLIER in the same forwarding chain as the entry directly above —
    // `kickSetupIfNeeded`'s own `warmUp` parameter (same local-parameter
    // coincidental-name reasoning) is passed along to `startSetup`, whose
    // body is the sibling entry immediately above. Same sole real wiring,
    // same classification.
    CallSite(
      file: "Sources/EnviousWisprAppKit/Views/Onboarding/OnboardingV2View.swift",
      matcher: "warmUp", text: "await self.startSetup(warmUp: warmUp, settings: settings)",
      classification: .structurallySafe),

    // MARK: WhisperKitEngineAdapter
    // `recoverFromWedge()`'s deadline-bounded unload — this file's own doc
    // comment marks it "§3.2, structurally-safe row": called only by the
    // kernel's wedge detectors, which fire only within an active session.
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "unload",
      text: "await captured.unload()", classification: .structurallySafe),
    // `unloadForRemoval()`'s unload — reached ONLY via the user-facing Remove
    // command (`WhisperKitSetupService.removeModel()` -> `removeModelAction`
    // -> `WhisperKitLegacyUpgradeCoordinator.remove()` -> `unloadForRemoval`
    // closure -> `KernelDictationDriver.unloadEngineForRemoval()` -> here),
    // which is entirely inside `removeModel()`'s own "whisperKitRemove"
    // claim closure (verified end-to-end; this is NOT the same as the two
    // `whisperKitIdleUnload` sites below, which are direct claim-closure
    // calls rather than several layers of indirection into one).
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "unload",
      text: "await backend.unload()", classification: .transitivelyCoveredByCaller),
    // Direct calls inside the two "whisperKitIdleUnload" claim closures
    // (`.immediately` and the timed-interval branch).
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "unload",
      text: "await backend.unload()", classification: .gated),
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "unload",
      text: "await backend.unload()", classification: .gated),
    // `warmUp()`'s own prepare call — reached via the same gated- and
    // structurally-safe-mixed callers as `ParakeetEngineAdapter.warmUp()`.
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "prepare",
      text: "let task = Task<Void, Error> { try await captured.prepare() }",
      classification: .transitivelyCoveredByCaller),
    // `startStreamingSession`'s vend — reached only at a session's own start
    // (same window `ParakeetEngineAdapter.beginSession`'s streaming-start
    // entry above covers), a `WhisperKitBackendDriving` requirement.
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift",
      matcher: "makeStreamingSession",
      text: "guard let session = await backend.makeStreamingSession(options: options) else {",
      classification: .structurallySafe),
    // Language-ID observation inside the adapter's own finalize/decode flow —
    // session-scoped, an `ASREngineLanguageIdentifying`-adjacent read that
    // runs a real inference but never mutates persistent engine state.
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "observeLID",
      text: "await backendForObserver.observeLID(", classification: .structurallySafe),
    // The adapter's own flush into its incremental streaming session's
    // `WhisperKitIncrementalSession.finalize` — session-scoped (`streamingSession`
    // is non-nil only during an active streaming session).
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "finalize",
      text: "let result = await live.finalize(finalSamples: [], speechSegments: [])",
      classification: .structurallySafe),
    // #1749 — the WhisperKit batch transcribe inside `finalize()`, one of the
    // "ordinary-session operations that can remain in flight" Codex's
    // grounded review traced: not guaranteed to stop when the session's own
    // unawaited cancellation races recovery's gate opening.
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "transcribe",
      text: "let result = try await backend.transcribe(",
      classification: .knownGap(
        issue: 1749,
        reason:
          "an in-flight batch transcribe is not guaranteed to stop before recovery's gate opens"
      )),

    // MARK: ASRManager — new Chunk 11 XPC-mirrored operations. Same inherited-
    // safety reasoning as the file's existing `prepare`/`startStreaming`
    // entries: these are `ASRManager`'s own forwarding implementations,
    // reached by both safe (gated/session-scoped) and, transitively, the
    // #1749-affected recovery path — the #1749 tag lives at the specific
    // `ActiveEngineOperation`/adapter-level call sites Codex's grounded
    // review named, not cascaded through every deeper forwarding layer.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "transcribe",
      text:
        "return try await activeBackend.transcribe(audioSamples: audioSamples, options: options)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "feedAudio",
      text: "try await activeBackend.feedAudio(buffer)",
      classification: .transitivelyCoveredByCaller),
    // `startStreaming`'s pre-start drain, and `finalizeStreaming`'s own
    // post-finalize path — both reached via the same mixed caller set.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "cancelStreaming",
      text: "await activeBackend.cancelStreaming()", classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "cancelStreaming",
      text: "await activeBackend.cancelStreaming()", classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManager.swift", matcher: "finalizeStreaming",
      text: "let result = try await activeBackend.finalizeStreaming()",
      classification: .transitivelyCoveredByCaller),

    // MARK: ASRManagerProxy — new Chunk 11 XPC-client forwarding, same
    // reasoning as the file's existing `loadModel`/`startStreaming` entries.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "transcribeSamples",
      text: "proxy.transcribeSamples(", classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "feedAudioBuffer",
      text: "proxy.feedAudioBuffer(data, frameCount: count)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "finalizeStreaming",
      text: "proxy.finalizeStreaming { resultData, nsError in",
      classification: .transitivelyCoveredByCaller),
    // #1749 — this XPC-client `cancelStreaming` forward is part of the same
    // fire-and-forget chain `detachedAdapterCancel()` triggers on Parakeet;
    // no reply is awaited, so it can still be in flight when recovery's gate
    // opens.
    CallSite(
      file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "cancelStreaming",
      text: "serviceProxy { proxy in proxy.cancelStreaming() }",
      classification: .knownGap(
        issue: 1749,
        reason: "fire-and-forget XPC cancel forward, no reply awaited, part of the #1749 chain"
      )),

    // MARK: ASRServiceHandler — new Chunk 11 XPC-service forwarding, same
    // reasoning as the file's existing `startStreaming`/`prepare` entries.
    CallSite(
      file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "transcribe",
      text: "let result = try await parakeet.transcribe(audioSamples: samples, options: options)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "feedAudio",
      text: "Task { try? await parakeet.feedAudio(unsafeBuffer) }",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "finalizeStreaming",
      text: "let result = try await parakeet.finalizeStreaming()",
      classification: .transitivelyCoveredByCaller),
    // #1749 — the service-side twin of the XPC-client cancel forward above;
    // spawns its own untracked `Task`, never awaited by the client.
    CallSite(
      file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "cancelStreaming",
      text: "Task { await parakeet.cancelStreaming() }",
      classification: .knownGap(
        issue: 1749,
        reason: "fire-and-forget XPC cancel forward, no reply awaited, part of the #1749 chain"
      )),

    // MARK: ParakeetBackend — new Chunk 11 entry, same inherited coverage as
    // the file's existing `prepare`/`loadModels`/`startStreaming` entries:
    // the concrete `ASRBackend.transcribe` implementation, forwarding to
    // FluidAudio's own manager.
    CallSite(
      file: "Sources/EnviousWisprASR/ParakeetBackend.swift", matcher: "transcribe",
      text:
        "let fluidResult = try await manager.transcribe(audioSamples, decoderState: &decoderState)",
      classification: .transitivelyCoveredByCaller),

    // MARK: WhisperKitBackend — new Chunk 11 entries.
    // `performWarmup`'s silent probe decode — part of `warmUp()`'s own
    // already-tracked chain (gated/structurallySafe depending on caller),
    // unrelated to the #1749 race.
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitBackend.swift", matcher: "transcribe",
      text: "_ = try await wk.transcribe(audioArray: silence, decodeOptions: opts)",
      classification: .transitivelyCoveredByCaller),
    // The concrete `ASRBackend.transcribe` implementation, forwarding to the
    // real WhisperKit SDK decode. #1749 — every currently-known external
    // caller of this specific method (`ActiveEngineOperation.swift`'s direct
    // `whisperKitBackend.transcribe` and `WhisperKitEngineAdapter.swift`'s
    // `backend.transcribe`) is already tagged `knownGap(1749)` above; marking
    // this deeper layer `transitivelyCoveredByCaller` would overstate safety
    // this method does not currently have from any known caller.
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitBackend.swift", matcher: "transcribe",
      text:
        "results = try await kit.transcribe(audioArray: paddedSamples, decodeOptions: decodeOptions)",
      classification: .knownGap(
        issue: 1749,
        reason:
          "every currently-known caller of this method is itself part of the #1749 race window"
      )),

    // MARK: WhisperKitIncrementalSession — `WhisperKitTranscribing`'s
    // forwarding wrapper around WhisperKit's own real decode entry point (a
    // THIRD-PARTY method sharing this vocabulary's bare name coincidentally);
    // safety is inherited from whichever caller reached this layer, same as
    // `ASRProtocol.swift`'s existing `prepare()` forward.
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitIncrementalSession.swift", matcher: "transcribe",
      text: "try await self.transcribe(", classification: .transitivelyCoveredByCaller),

    // MARK: WhisperKitStreamingSession — the concrete incremental-decode
    // session vended by `WhisperKitBackend.makeStreamingSession()`. All three
    // `transcribe` calls below are internal decode-loop steps; #1749 —
    // "ordinary-session operations that can remain in flight" per Codex's
    // grounded review: not guaranteed to stop before recovery's gate opens.
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitStreamingSession.swift", matcher: "transcribe",
      text: "let results = try await whisperKit.transcribe(",
      classification: .knownGap(
        issue: 1749,
        reason:
          "an in-flight incremental decode is not guaranteed to stop before recovery's gate opens"
      )),
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitStreamingSession.swift", matcher: "transcribe",
      text:
        "let results = try await whisperKit.transcribe(audioArray: paddedSamples, decodeOptions: opts)",
      classification: .knownGap(
        issue: 1749,
        reason:
          "an in-flight incremental decode is not guaranteed to stop before recovery's gate opens"
      )),
    CallSite(
      file: "Sources/EnviousWisprASR/WhisperKitStreamingSession.swift", matcher: "transcribe",
      text:
        "let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)",
      classification: .knownGap(
        issue: 1749,
        reason:
          "an in-flight incremental decode is not guaranteed to stop before recovery's gate opens"
      )),

    // MARK: RecordingSessionKernel — Chunk 11 additions, same session-scoped
    // reasoning as this file's existing entries for this type.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "acceptAudio",
      text: "self.adapter.acceptAudio(handoff)", classification: .structurallySafe),
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "beginSession",
      text: "try await adapter.beginSession(", classification: .structurallySafe),
    // The real adapter-facing finalize call.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "finalize",
      text: "let outcome = await adapter.finalize(batchSamples: batchSamples)",
      classification: .structurallySafe),
    // The kernel's own private `finalize(sid:batchSamples:)` called
    // recursively during ASR-interruption salvage and the empty-result retry
    // ladder — bare, implicit-`self` calls to an already-counted deeper
    // engine touch, same pattern as the file's existing `warmUp(sid)` entry.
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "finalize",
      text: "let outcome = await finalize(sid, batchSamples: asrSamples)",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift", matcher: "finalize",
      text: "let retry = await finalize(sid, batchSamples: Array(samples[trim...]))",
      classification: .transitivelyCoveredByCaller),

    // MARK: ParakeetEngineAdapter — Chunk 11 additions.
    // Streaming-feed dispatch, guarded by session/terminal checks on the
    // `@MainActor` hop — session-scoped, same as this file's existing
    // `beginSession`/`startStreaming` entries for this type.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "feedAudio",
      text: "try await self.asrManager.feedAudio(pcmBuffer)", classification: .structurallySafe),
    // #1749 — the batch-rescue transcribe inside `finalize`/`retryDecode`,
    // reached during normal decode; one of the "ordinary-session operations
    // that can remain in flight" per Codex's grounded review.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "transcribe",
      text: "let result = try await asrManager.transcribe(",
      classification: .knownGap(
        issue: 1749,
        reason:
          "an in-flight batch transcribe is not guaranteed to stop before recovery's gate opens"
      )),
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "transcribe",
      text: "let result = try await asrManager.transcribe(",
      classification: .knownGap(
        issue: 1749,
        reason:
          "an in-flight batch transcribe is not guaranteed to stop before recovery's gate opens"
      )),
    // #1749 — `discardSession()`'s `cancelStreaming` forward, the same
    // fire-and-forget chain `detachedAdapterCancel()` triggers.
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "cancelStreaming",
      text: "await asrManager.cancelStreaming()",
      classification: .knownGap(
        issue: 1749,
        reason: "fire-and-forget cancel forward, part of the #1749 chain"
      )),
    // #1749 — `finalizeStreaming` reached when cancellation lands mid-finalize
    // (the `catch` path's own await, still able to overlap recovery).
    CallSite(
      file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
      matcher: "finalizeStreaming",
      text: "let result = try await asrManager.finalizeStreaming()",
      classification: .knownGap(
        issue: 1749,
        reason:
          "finalizeStreaming reached when cancellation lands mid-finalize is not guaranteed to stop before recovery's gate opens"
      )),

    // MARK: BenchmarkSuite — Chunk 11 additions, all directly inside this
    // file's own "benchmarkSuiteBatch"/"benchmarkSuiteStreaming" claims
    // (same claims the file's existing `startStreaming` entry already uses).
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/BenchmarkSuite.swift", matcher: "transcribe",
      text: "_ = try? await activeEngine.transcribe(samples, .default)", classification: .gated),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/BenchmarkSuite.swift", matcher: "transcribe",
      text: "let batchResult = try? await activeEngine.transcribe(testSamples, .default)",
      classification: .gated),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/BenchmarkSuite.swift", matcher: "feedAudio",
      text: "try await asrManager.feedAudio(buffer)", classification: .gated),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/BenchmarkSuite.swift", matcher: "finalizeStreaming",
      text: "let streamResult = try await asrManager.finalizeStreaming()", classification: .gated),
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/BenchmarkSuite.swift", matcher: "cancelStreaming",
      text: "await asrManager.cancelStreaming()", classification: .gated),

    // MARK: TailBenchmarkHarness — an external eval-harness support type
    // (`scripts/eval/tail_runner`), never constructed anywhere in production
    // `Sources/` (grep-verified). Reachable in theory, never exercised by the
    // shipping app's own configuration — the same `dormant` bucket as
    // `WhisperKitBackend`'s existing test-seam entry.
    CallSite(
      file: "Sources/EnviousWisprASR/TailBenchmarkHarness.swift", matcher: "transcribe",
      text:
        "let results = try await model.kit.transcribe(audioArray: decodeInput, decodeOptions: opts)",
      classification: .dormant),
    CallSite(
      file: "Sources/EnviousWisprASR/TailBenchmarkHarness.swift", matcher: "transcribe",
      text: "let results = try await model.kit.transcribe(audioArray: padded, decodeOptions: opts)",
      classification: .dormant),
    CallSite(
      file: "Sources/EnviousWisprASR/TailBenchmarkHarness.swift", matcher: "transcribe",
      text: "let results = try await model.kit.transcribe(audioArray: padded, decodeOptions: opts)",
      classification: .dormant),
    CallSite(
      file: "Sources/EnviousWisprASR/TailBenchmarkHarness.swift", matcher: "finalize",
      text: "let result = await session.finalize(finalSamples: [], speechSegments: [])",
      classification: .dormant),

    // MARK: DictationRuntime / KernelDictationDriver — the onboarding
    // install Cancel button's seam (#1388 step 3). Race-safe by
    // construction, not by claim: "the adapter's in-flight gate and the
    // delivery controller's completion-wins-the-race handling both make it a
    // no-op" against a just-completed load — `structurallySafe` category (c).
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/DictationRuntime/DictationRuntime.swift",
      matcher: "cancelSessionlessWarmup",
      text: "await starter.activeDriver.cancelSessionlessWarmup()",
      classification: .structurallySafe),
    CallSite(
      file: "Sources/EnviousWisprPipeline/KernelDictationDriver.swift",
      matcher: "cancelSessionlessWarmup", text: "await cancelling.cancelSessionlessWarmup()",
      classification: .transitivelyCoveredByCaller),

    // MARK: WhisperKitLegacyUpgradeCoordinator / KernelDictationDriver /
    // WisprBootstrapper — the three remaining links in the ALREADY-verified
    // "whisperKitRemove" claim chain this file's existing
    // `WhisperKitEngineAdapter.swift` `unloadForRemoval` entry documents
    // end-to-end (`WhisperKitSetupService.removeModel()` ->
    // `WhisperKitLegacyUpgradeCoordinator.remove()` -> `unloadForRemoval`
    // closure -> `KernelDictationDriver.unloadEngineForRemoval()` -> the
    // already-counted adapter entry). Each is one more layer of that same
    // verified chain, not a new one.
    CallSite(
      file: "Sources/EnviousWisprPipeline/WhisperKitLegacyUpgradeCoordinator.swift",
      matcher: "unloadForRemoval", text: "await unloadForRemoval()",
      classification: .transitivelyCoveredByCaller),
    CallSite(
      file: "Sources/EnviousWisprPipeline/KernelDictationDriver.swift", matcher: "unloadForRemoval",
      text: "await (adapter as? WhisperKitEngineAdapter)?.unloadForRemoval()",
      classification: .transitivelyCoveredByCaller),
    // The closure WIRING itself — a property assignment, not a call; safety
    // inherited from wherever it is actually invoked (the same chain above).
    CallSite(
      file: "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift", matcher: "unloadForRemoval",
      text: "whisperKitRetirement?.unloadForRemoval = { [weak whisperKitKernelDriver] in",
      classification: .transitivelyCoveredByCaller),
  ]

  // MARK: Live scan

  /// Council-approved contract pivot (#1741 Chunk 10): a "hit" is any real
  /// code reference to a vocabulary name, not a proof that the reference is
  /// ultimately called. `MemberAccessExprSyntax.declName` IS ITSELF a child
  /// `DeclReferenceExprSyntax` node in the tree (Codex plan-review r1
  /// correction) — so a single hook on `DeclReferenceExprSyntax` catches
  /// both a bare reference (`warmUp`) and a member reference
  /// (`adapter.warmUp`, where `warmUp` is `declName`) with no double
  /// counting and no separate `MemberAccessExprSyntax` hook needed. This
  /// deletes the entire prior callee-resolution machinery (wrapper unwrap,
  /// operator folding, ambiguous-branch detection) — none of it matters when
  /// the question is "is the name referenced" rather than "is this
  /// specifically a call."
  ///
  /// Comments are trivia the parser already excludes from the syntax tree —
  /// this visitor never sees them at all, in any form (line, block, nested).
  /// String literal CONTENT is never parsed as an expression, so vocabulary
  /// text quoted inside a log message is never mistaken for a reference, in
  /// any string form (plain, multi-line, raw, any hash count). A real
  /// reference hidden inside string interpolation — even split across
  /// multiple physical lines — is correctly found too, because SwiftParser
  /// parses an interpolation segment as a REAL, complete expression subtree.
  /// This guarantee is parser-structural and untouched by the contract
  /// pivot.
  private final class CallSiteVisitor: SyntaxVisitor {
    private(set) var hits: [(matcher: String, line: Int, text: String)] = []
    private let converter: SourceLocationConverter
    private let sourceLines: [Substring]

    init(source: String, tree: some SyntaxProtocol) {
      self.converter = SourceLocationConverter(fileName: "", tree: tree)
      self.sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
      super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
      // Codex round 1 correction: `.text` preserves backticks, so an escaped
      // reference (`` adapter.`warmUp`() ``) would silently bypass the
      // vocabulary check. `.identifier?.name` is SwiftSyntax's own canonical,
      // backtick-stripped identifier — the general fix, not a backtick
      // special case.
      guard let name = node.baseName.identifier?.name, vocabulary.contains(name) else {
        return .visitChildren
      }
      let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
      let text =
        (line - 1) < sourceLines.count
        ? sourceLines[line - 1].trimmingCharacters(in: .whitespaces) : ""
      hits.append((matcher: name, line: line, text: text))
      return .visitChildren
    }
  }

  /// A source file that could not be discovered (directory enumeration
  /// failed), read, or parsed cleanly. Codex plan-review r1 correction: an
  /// unreadable or unparseable file must fail the whole scan, never be
  /// silently treated as clean (the prior `(try? ... ) ?? ""` pattern turned
  /// an unreadable file into a successfully-parsed EMPTY file — invisible to
  /// the inventory, not merely skipped).
  private struct ScanFailedError: Error, CustomStringConvertible {
    let file: String
    let reason: String
    var description: String {
      "Scan failed for \(file): \(reason). Never silently treated as clean."
    }
  }

  /// Shared by the live file scanner and the fixture-based tests below, so a
  /// test proving comment/string handling actually exercises the SAME parser
  /// + visitor path the live scan uses (Codex round 1 P3, still honored:
  /// never a parallel, simpler stand-in).
  ///
  /// `Parser.parse` never throws — it is resilient by design and always
  /// returns SOME tree, using error-recovery nodes for malformed input.
  /// `tree.hasError` is checked explicitly and throws `ScanFailedError`
  /// rather than silently scanning a best-effort recovered tree that could
  /// hide or misplace a reference.
  private static func hits(inSource source: String, file: String) throws -> [RawHit] {
    let tree = Parser.parse(source: source)
    guard !tree.hasError else {
      throw ScanFailedError(file: file, reason: "source did not parse cleanly (tree.hasError)")
    }
    let visitor = CallSiteVisitor(source: source, tree: tree)
    visitor.walk(tree)
    return visitor.hits.map {
      RawHit(file: file, matcher: $0.matcher, text: $0.text, line: $0.line)
    }
  }

  /// Count of vocabulary-name references matching `matcher` in `source` —
  /// used by the fixture tests below.
  private static func hitCount(in source: String, matcher: String) throws -> Int {
    try Self.hits(inSource: source, file: "<fixture>").filter { $0.matcher == matcher }.count
  }

  /// Scans a single directory. Extracted from `scanLiveCallSites()` so a
  /// fixture test can point it at a throwaway temp directory to exercise the
  /// REAL discovery/read/parse failure paths, not a parallel simpler
  /// stand-in.
  private static func scanRoot(at rootURL: URL) throws -> [RawHit] {
    var hits: [RawHit] = []
    var enumerationError: Error?
    // A trailing closure directly in a `guard`/`if` condition is a known
    // Swift parser ambiguity (it can be read as the statement's own body) —
    // passed as an explicit `errorHandler:` argument instead.
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      // Codex round 1 correction: `FileManager.enumerator` returns an
      // Optional; relying solely on the error-handler closure firing left a
      // theoretical path where a nil enumerator (no callback invoked) would
      // fall through the `while let` below as zero hits — a silent, wrongly
      // "clean" scan rather than a failure. Guarded explicitly here.
      throw ScanFailedError(file: rootURL.path, reason: "could not create a directory enumerator")
    }
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let source: String
      do {
        source = try String(contentsOf: url, encoding: .utf8)
      } catch {
        throw ScanFailedError(file: url.path, reason: "could not be read: \(error)")
      }
      hits.append(contentsOf: try Self.hits(inSource: source, file: url.path))
    }
    if let enumerationError {
      throw ScanFailedError(
        file: rootURL.path, reason: "directory enumeration failed: \(enumerationError)")
    }
    return hits
  }

  private static func scanLiveCallSites() throws -> [RawHit] {
    var hits: [RawHit] = []
    let relativePrefix = RepoRoot.url.path + "/"
    for root in scannedRoots {
      let rootURL = RepoRoot.sourceURL(root)
      let rootHits = try scanRoot(at: rootURL)
      hits.append(
        contentsOf: rootHits.map {
          RawHit(
            file: $0.file.replacingOccurrences(of: relativePrefix, with: ""), matcher: $0.matcher,
            text: $0.text, line: $0.line)
        })
    }
    return hits
  }

  /// Generic recursive scan under an arbitrary repo-relative root, used by the
  /// whole-repo single-authority tests (5/6/7/8) that are not scoped to the
  /// four mutation-vocabulary directories.
  private static func scanSources(pattern: String, under root: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let rootURL = RepoRoot.sourceURL(root)
    let enumerator = FileManager.default.enumerator(
      at: rootURL, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var hits: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let relative = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        let ns = text as NSString
        if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
          hits.append("\(relative):\(idx + 1): \(trimmed)")
        }
      }
    }
    return hits
  }

  // MARK: 1 — the live scan's raw multiset exactly matches the frozen table

  @Test("live scanner output exactly matches the frozen classified inventory, as a multiset")
  func liveInventoryMatchesFrozenClassification() throws {
    let live = try Self.scanLiveCallSites()
    var liveCounts: [SiteKey: Int] = [:]
    for hit in live { liveCounts[hit.key, default: 0] += 1 }

    var expectedCounts: [SiteKey: Int] = [:]
    for site in Self.expected {
      expectedCounts[
        SiteKey(file: site.file, matcher: site.matcher, text: site.text), default: 0] += 1
    }

    let newOrDuplicated = liveCounts.filter { expectedCounts[$0.key, default: 0] < $0.value }
    let goneOrUndersized = expectedCounts.filter { liveCounts[$0.key, default: 0] < $0.value }

    func describe(_ key: SiteKey, liveHits: [RawHit]) -> String {
      let lines = liveHits.filter { $0.key == key }.map { "\($0.file):\($0.line)" }
      return "  [\(key.file)] matcher=\(key.matcher) text=`\(key.text)` (live at: \(lines))"
    }

    #expect(
      newOrDuplicated.isEmpty,
      """
      Found \(newOrDuplicated.count) live call site(s) not fully accounted for in the frozen
      table (a new call, a moved call, or a duplicate this table under-counts):
      \(newOrDuplicated.keys.map { describe($0, liveHits: live) }.joined(separator: "\n"))
      Classify the new/duplicated site and add it to `expected` in this file.
      """)
    #expect(
      goneOrUndersized.isEmpty,
      """
      Found \(goneOrUndersized.count) frozen entry/entries no longer present in live source
      (a call was deleted, renamed, or this table over-counts):
      \(goneOrUndersized.keys.map { "  [\($0.file)] matcher=\($0.matcher) text=`\($0.text)`" }
        .joined(separator: "\n"))
      Remove the stale entry/entries from `expected` in this file.
      """)
  }

  // MARK: 2 — a call expression is detected while a declaration is not

  @Test("a call expression is detected while a method declaration with the same name is not")
  func adversarialCallSiteVsDeclaration() throws {
    let call = "adapter.warmUp()"
    let decl = "func warmUp() async throws {}"
    #expect(try Self.hitCount(in: call, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: decl, matcher: "warmUp") == 0)
  }

  // MARK: 2b — direct/chained calls and stored references (council-approved
  // contract pivot: a reference is a hit regardless of whether, how, or
  // whether-at-all it is ultimately called — see the file-level doc comment
  // above for why this replaces the entire prior callee-resolution axis).

  @Test("a direct call is detected")
  func positiveControlDirectCallIsDetected() throws {
    #expect(try Self.hitCount(in: "adapter.warmUp()", matcher: "warmUp") == 1)
  }

  @Test(
    "a chained call (base is itself a call result) is detected — the base's own kind never matters")
  func positiveControlChainedCallIsDetected() throws {
    #expect(try Self.hitCount(in: "getAdapter().warmUp()", matcher: "warmUp") == 1)
  }

  @Test("a bare call with implicit `self` (no member-access receiver at all) is detected")
  func positiveControlBareImplicitSelfCallIsDetected() throws {
    #expect(try Self.hitCount(in: "Task { await unloadModel() }", matcher: "unloadModel") == 1)
  }

  @Test("a trailing-closure call with no parentheses at all is detected")
  func positiveControlTrailingClosureNoParensIsDetected() throws {
    // The real entry in the frozen table (`ASRManagerProxy.swift`) proves
    // this against live source; this fixture proves it in isolation.
    #expect(
      try Self.hitCount(in: "proxy.unloadModel { cont.resume() }", matcher: "unloadModel") == 1)
  }

  @Test(
    "a method reference stored in a variable and NEVER called is now caught at the point of reference — the prior design's one accepted, irreducible boundary is closed, not merely documented"
  )
  func positiveControlStoredUninvokedReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "let f = adapter.warmUp", matcher: "warmUp") == 1)
  }

  @Test(
    "a vocabulary name passed as a plain argument, never itself called, is still a real reference and is detected"
  )
  func positiveControlArgumentPositionReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "foo(adapter.warmUp)", matcher: "warmUp") == 1)
  }

  @Test(
    "switchBackend is matched uniformly regardless of argument label — the prior `to:`-only special case is retired"
  )
  func positiveControlSwitchBackendMatchedUniformly() throws {
    #expect(try Self.hitCount(in: "switchBackend(to: .whisperKit)", matcher: "switchBackend") == 1)
    #expect(
      try Self.hitCount(in: "switchBackend(from: .whisperKit)", matcher: "switchBackend") == 1)
  }

  @Test(
    "a member access is counted exactly once — `MemberAccessExprSyntax.declName` IS the same `DeclReferenceExprSyntax` node the generic visitor hook sees, not a second occurrence (Codex plan-review r1 double-count correction)"
  )
  func adversarialMemberAccessCountedOnce() throws {
    #expect(try Self.hitCount(in: "adapter.warmUp()", matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: "let f = adapter.warmUp", matcher: "warmUp") == 1)
  }

  @Test(
    "a backtick-escaped member reference is still detected — `.text` would preserve the backticks and silently miss this (Codex round 1 correction)"
  )
  func adversarialEscapedMemberReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "adapter.`warmUp`()", matcher: "warmUp") == 1)
  }

  @Test("a backtick-escaped bare reference is still detected")
  func adversarialEscapedBareReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "let f = `warmUp`", matcher: "warmUp") == 1)
  }

  // MARK: 2c — conditional compilation: every syntactically represented
  // branch is scanned in one pass, regardless of which flags this test
  // process itself was built with.

  @Test(
    "both branches of an #if/#else are scanned, regardless of which flag is active for this test process"
  )
  func positiveControlConditionalCompilationBothBranchesScanned() throws {
    let source = """
      #if USE_WARMUP
      adapter.warmUp()
      #else
      adapter.prepare()
      #endif
      """
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "prepare") == 1)
  }

  @Test("a postfix #if/#else directly in a member-access chain is scanned on both sides")
  func positiveControlPostfixIfConfigBothSidesScanned() throws {
    // Codex's exact counterexample from the abandoned callee-folding design
    // — a real, intentional, SwiftParser-tested form. Under the reference-
    // only contract this needs no special handling at all: both `.warmUp`
    // and `.prepare` are ordinary member references, found independently.
    let source = """
      adapter
        #if USE_WARMUP
          .warmUp
        #else
          .prepare
        #endif
        ()
      """
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "prepare") == 1)
  }

  // MARK: 2d — conditional and operator expressions: no ambiguity detection
  // needed anymore. Each branch is an independent reference, found and
  // counted on its own; there is nothing left to disambiguate.

  @Test(
    "a ternary naming a vocabulary method on either branch counts BOTH references — no ambiguity to detect"
  )
  func positiveControlTernaryBothBranchesCounted() throws {
    let source = "(useFirst ? adapter.warmUp : other.prepare)()"
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "prepare") == 1)
  }

  @Test(
    "a nil-coalescing expression naming a vocabulary method on either side counts BOTH references")
  func positiveControlNilCoalescingBothSidesCounted() throws {
    let source = "(adapter.warmUp ?? other.prepare)()"
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "prepare") == 1)
  }

  @Test("an `if`-used-as-expression selecting between vocabulary references counts BOTH branches")
  func positiveControlIfExpressionBothBranchesCounted() throws {
    let source = #"""
      (if useFirst {
        adapter.warmUp
      } else {
        other.prepare
      })()
      """#
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "prepare") == 1)
  }

  @Test(
    "an `as`-cast-wrapped reference is detected — Codex round 2's exact counterexample from the abandoned design, trivial under the new contract"
  )
  func positiveControlAsCastWrappedReferenceIsDetected() throws {
    let source = "try await (adapter.warmUp as () async throws -> Void)()"
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
  }

  @Test(
    "an `is`-check testing a vocabulary reference is a real reference and IS counted — the contract no longer tries to judge whether the surrounding expression is 'identity-preserving'"
  )
  func positiveControlIsCheckReferenceIsCounted() throws {
    #expect(try Self.hitCount(in: "(adapter.warmUp is AnyObject)()", matcher: "warmUp") == 1)
  }

  @Test("calling the RESULT of a call is not conflated with the vocabulary name that produced it")
  func adversarialDoubleCallAsCalleeIsNotFabricated() throws {
    // `adapter.warmUp()` (the INNER call) is one real reference; the OUTER
    // call's callee is that inner call's RESULT, containing no name of its
    // own — so the total is exactly 1, proving the inner reference is found
    // once and the outer call adds no phantom second reference.
    #expect(try Self.hitCount(in: "adapter.warmUp()()", matcher: "warmUp") == 1)
  }

  @Test("two distinct vocabulary references on the same line are both counted, independently")
  func positiveControlTwoDistinctReferencesOnOneLineAreBothCounted() throws {
    let source = "adapter.warmUp(); await other.unloadModel()"
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "unloadModel") == 1)
  }

  // MARK: 2e — ownership-related forms (Swift 5.9+ `consume`/`copy`/`borrow`,
  // supported by this project's Swift 6.3.3 toolchain). Plain references
  // under the new contract; no special unwrap logic required.

  @Test("a `consume`-wrapped reference is detected")
  func positiveControlConsumeReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "(consume adapter.warmUp)()", matcher: "warmUp") == 1)
  }

  @Test("a `copy`-wrapped reference is detected")
  func positiveControlCopyReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "(copy adapter.warmUp)()", matcher: "warmUp") == 1)
  }

  @Test("a `borrow`-wrapped reference is detected")
  func positiveControlBorrowReferenceIsDetected() throws {
    #expect(try Self.hitCount(in: "(borrow adapter.warmUp)()", matcher: "warmUp") == 1)
  }

  // MARK: 2f — fail-closed on discovery/read/parse failure (Codex plan-
  // review r1 correction: the prior `(try? ...) ?? ""` pattern silently
  // turned an unreadable file into a successfully-parsed empty file).

  @Test(
    "malformed source that cannot parse cleanly fails the scan closed, rather than being silently treated as clean"
  )
  func adversarialMalformedSourceFailsClosed() throws {
    let source = "func warmUp( { this is not valid Swift at all !!! ###"
    #expect(throws: ScanFailedError.self) {
      try Self.hits(inSource: source, file: "<fixture>")
    }
  }

  @Test(
    "a directory containing a file that cannot be read fails the scan closed, rather than silently skipping it"
  )
  func adversarialUnreadableFileFailsClosed() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let fileURL = tempDir.appendingPathComponent("Unreadable.swift")
    try "adapter.warmUp()".write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }
    #expect(throws: ScanFailedError.self) {
      try Self.scanRoot(at: tempDir)
    }
  }

  @Test(
    "a directory that does not exist fails the scan closed, rather than silently returning zero hits"
  )
  func adversarialNonexistentDirectoryFailsClosed() throws {
    let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "does-not-exist-\(UUID().uuidString)")
    #expect(throws: ScanFailedError.self) {
      try Self.scanRoot(at: missingDir)
    }
  }

  // MARK: 3 — comments and string content are never mistaken for a real call

  @Test("a comment-only mention of a vocabulary call is ignored — line comment")
  func negativeControlLineCommentSkipped() throws {
    let source = """
      // adapter.recoverFromWedge() used to run unconditionally here
      let x = 1
      """
    #expect(try Self.hitCount(in: source, matcher: "recoverFromWedge") == 0)
  }

  @Test("a comment-only mention of a vocabulary call is ignored — block comment")
  func negativeControlBlockCommentSkipped() throws {
    let source = """
      /* adapter.warmUp() was removed from this path */
      let x = 1
      """
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 0)
  }

  @Test("a comment-only mention of a vocabulary call is ignored — multi-line block comment")
  func negativeControlMultiLineBlockCommentSkipped() throws {
    let source = """
      /*
      adapter.warmUp() used to run here
      */
      let x = 1
      """
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 0)
  }

  @Test("vocabulary text quoted inside a string literal is not counted as a real call")
  func negativeControlVocabularyInsideStringLiteralNotCounted() throws {
    let source = #"log.info("adapter.warmUp() was skipped this run")"#
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 0)
  }

  @Test("vocabulary text quoted inside a RAW string literal is not counted as a real call")
  func negativeControlVocabularyInsideRawStringLiteralNotCounted() throws {
    let source = ##"log.info(#"adapter.warmUp() was skipped this run"#)"##
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 0)
  }

  @Test("a comment-delimiter-shaped substring inside a string literal does not confuse the parser")
  func negativeControlURLStringDoesNotConfuseTheParser() throws {
    let source = #"let url = "https://example.com"; await adapter.warmUp()"#
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
  }

  @Test("a bare `/*`-shaped substring inside a string literal does not confuse the parser")
  func negativeControlBlockCommentOpenerStringDoesNotConfuseTheParser() throws {
    let source = #"""
      let marker = "/*"; await adapter.warmUp()
      await adapter.recoverFromWedge()
      """#
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
    #expect(try Self.hitCount(in: source, matcher: "recoverFromWedge") == 1)
  }

  @Test(
    "a comment-delimiter-shaped substring inside a RAW string literal does not confuse the parser"
  )
  func negativeControlRawStringDoesNotConfuseTheParser() throws {
    let source = ##"let pattern = #"http://example.com"#; await adapter.warmUp()"##
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 1)
  }

  @Test(
    "a genuine call hidden inside string interpolation IS correctly detected (Codex round 4's first counterexample, previously a fail-closed case in the hand-rolled scanner)"
  )
  func positiveControlInterpolatedCallIsDetected() throws {
    let source = #"let result = "\(await adapter.retryDecode(inputSamples: samples))""#
    #expect(try Self.hitCount(in: source, matcher: "retryDecode") == 1)
  }

  @Test(
    "a nested quote inside an interpolation neither hides nor fabricates a hit (Codex round 4's second counterexample)"
  )
  func positiveControlNestedQuoteInInterpolationIsHandledCorrectly() throws {
    // The real call here is `format(...)`, whose argument is a plain string —
    // not a member-access call — so a real parser correctly finds zero
    // `.warmUp(` calls, exactly what a human reading this code would
    // conclude. Under the old hand-rolled scanner, this exact shape could
    // make naive quote-tracking exit the outer string early and misread the
    // inner quoted text as a real `.warmUp(` call.
    let source = ##"let text = "\(format("adapter.warmUp()"))""##
    #expect(try Self.hitCount(in: source, matcher: "warmUp") == 0)
  }

  @Test(
    "multi-line interpolation spanning multiple physical lines is correctly detected (Codex round 5)"
  )
  func positiveControlMultiLineInterpolationIsDetected() throws {
    let source = #"""
      let result = """
      \(
        await adapter.retryDecode(inputSamples: samples)
      )
      """
      """#
    #expect(try Self.hitCount(in: source, matcher: "retryDecode") == 1)
  }

  // MARK: 4 — duplicate identical calls preserve multiplicity

  @Test("duplicate identical calls on separate lines preserve multiplicity")
  func duplicateCallsOnSeparateLinesPreserveMultiplicity() throws {
    let source = """
      await adapter.warmUp()
      await adapter.warmUp()
      """
    #expect(
      try Self.hitCount(in: source, matcher: "warmUp") == 2,
      "two identical calls must both be counted, never deduplicated to one")
  }

  @Test("duplicate identical calls on the SAME line preserve multiplicity")
  func duplicateCallsOnTheSameLinePreserveMultiplicity() throws {
    let source = "await first.warmUp(); await second.warmUp()"
    #expect(
      try Self.hitCount(in: source, matcher: "warmUp") == 2,
      "two calls sharing one physical line must both be counted")
  }

  // MARK: 5 — no production consumer uses .alwaysAllowedForTesting

  @Test(
    "no production consumer references .alwaysAllowedForTesting outside its two declaring files")
  func alwaysAllowedForTestingHasNoProductionConsumer() throws {
    let declaringFiles: Set<String> = [
      "Sources/EnviousWisprASR/EngineMutationScope.swift",
      "Sources/EnviousWisprAppKit/App/RecoveryEngineClaim.swift",
    ]
    let hits = try Self.scanSources(pattern: #"alwaysAllowedForTesting"#, under: "Sources")
    let offenders = hits.filter { hit in
      !declaringFiles.contains { hit.hasPrefix($0 + ":") }
    }
    #expect(
      offenders.isEmpty,
      """
      `.alwaysAllowedForTesting` is referenced in production outside its two declaring files:
      \(offenders.joined(separator: "\n"))
      It is `internal`, test-only, and reachable only via `@testable import`; a real production
      site using it by name would be exactly the silent-bypass risk #1741 exists to prevent.
      """)
  }

  // MARK: 6 — exactly one production EngineMutationScope.live(...) call

  @Test("exactly one production EngineMutationScope.live(...) construction")
  func engineMutationScopeLiveConstructedOnce() throws {
    let hits = try Self.scanSources(pattern: #"EngineMutationScope\.live\("#, under: "Sources")
    #expect(
      hits.count == 1,
      "expected exactly one `EngineMutationScope.live(...)` construction, found \(hits.count): \(hits)"
    )
    #expect(hits.first?.contains("WisprBootstrapper.swift") == true, "found: \(hits)")
  }

  // MARK: 7 — exactly one production RecoveryEngineClaim.live(...) call

  @Test("exactly one production RecoveryEngineClaim.live(...) construction")
  func recoveryEngineClaimLiveConstructedOnce() throws {
    let hits = try Self.scanSources(pattern: #"RecoveryEngineClaim\.live\("#, under: "Sources")
    #expect(
      hits.count == 1,
      "expected exactly one `RecoveryEngineClaim.live(...)` construction, found \(hits.count): \(hits)"
    )
    #expect(hits.first?.contains("WisprBootstrapper.swift") == true, "found: \(hits)")
  }

  // MARK: 8 — both .live(...) calls live in WisprBootstrapper.swift

  @Test("both .live(...) capability constructions live in WisprBootstrapper.swift")
  func bothLiveConstructionsShareOneCompositionRoot() throws {
    let scopeHits = try Self.scanSources(pattern: #"EngineMutationScope\.live\("#, under: "Sources")
    let claimHits = try Self.scanSources(pattern: #"RecoveryEngineClaim\.live\("#, under: "Sources")
    let allInBootstrapper =
      (scopeHits + claimHits).allSatisfy { $0.contains("App/WisprBootstrapper.swift") }
    let allHits = scopeHits + claimHits
    #expect(
      allInBootstrapper,
      "both capability `.live(...)` constructions must live in the composition root: \(allHits)")
  }

  // MARK: 9 — every knownGap entry is fully tracked, and only the confirmed
  // sites carry it

  /// Every issue a `knownGap` entry may currently point at. #1745 (recovery
  /// Discard's fire-and-forget engine reset) and #1749 (recovery's claim not
  /// waiting for an ordinary session's own fire-and-forget termination
  /// cleanup) — both a real, tracked, out-of-#1741-scope production gap, not
  /// a placeholder. A future third gap needs its own issue added here
  /// deliberately, never silently.
  private static let knownGapIssues: Set<Int> = [1745, 1749]

  @Test("every knownGap classification names a positive, concrete issue and reason")
  func knownGapEntriesAreFullyTracked() {
    let gaps: [(issue: Int, reason: String)] = Self.expected.compactMap { site in
      guard case .knownGap(let issue, let reason) = site.classification else { return nil }
      return (issue, reason)
    }
    #expect(
      gaps.count == 18,
      "expected exactly 18 `knownGap` entries (2 for #1745, 16 for #1749), found \(gaps.count)"
    )
    for gap in gaps {
      #expect(
        gap.issue > 0,
        "a `knownGap` entry must name a real, positive GitHub issue number — never a placeholder")
      #expect(
        Self.knownGapIssues.contains(gap.issue),
        "expected every current `knownGap` entry to point at #1745 or #1749; found #\(gap.issue) instead"
      )
      #expect(
        !gap.reason.trimmingCharacters(in: .whitespaces).isEmpty,
        "a `knownGap` entry must carry a concrete reason, not a blank string")
    }
  }

  @Test("knownGap applies to exactly the confirmed-unsafe sites tracked at #1745/#1749, no others")
  func knownGapAppliesOnlyToTheConfirmedUnsafeSites() {
    // Ground truth extracted directly from a failing run of this test with an
    // empty expectation (measure-with-the-real-tool, not hand-transcription) —
    // 17 distinct sites; 18 total `knownGap` entries above because
    // `ParakeetEngineAdapter.swift`'s two identical-text `transcribe(` sites
    // collapse to one `SiteKey`, preserving multiplicity only in Test 1's own
    // multiset check, not in this Set-based one.
    let expectedGapKeys: Set<SiteKey> = [
      // #1745
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "unload",
        text: "await whisperKitBackend.unload()"),
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift",
        matcher: "cancelInFlightLoad", text: "asrManager.cancelInFlightLoad()"),
      // #1749
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "prepare",
        text: "try await whisperKitBackend.prepare()"),
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "loadModel",
        text: "try await asrManager.loadModel()"),
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "transcribe",
        text:
          "return try await whisperKitBackend.transcribe(audioSamples: samples, options: options)"
      ),
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/ActiveEngineOperation.swift", matcher: "transcribe",
        text: "return try await asrManager.transcribe(audioSamples: samples, options: options)"),
      SiteKey(
        file: "Sources/EnviousWisprAppKit/App/RecoverySpoolReplayer.swift", matcher: "transcribe",
        text: "result = try await activeEngine.transcribe(recovered.samples, options)"),
      SiteKey(
        file: "Sources/EnviousWisprASR/ASRManagerProxy.swift", matcher: "cancelStreaming",
        text: "serviceProxy { proxy in proxy.cancelStreaming() }"),
      SiteKey(
        file: "Sources/EnviousWisprASRService/ASRServiceHandler.swift", matcher: "cancelStreaming",
        text: "Task { await parakeet.cancelStreaming() }"),
      SiteKey(
        file: "Sources/EnviousWisprASR/WhisperKitBackend.swift", matcher: "transcribe",
        text:
          "results = try await kit.transcribe(audioArray: paddedSamples, decodeOptions: decodeOptions)"
      ),
      SiteKey(
        file: "Sources/EnviousWisprASR/WhisperKitStreamingSession.swift", matcher: "transcribe",
        text: "let results = try await whisperKit.transcribe("),
      SiteKey(
        file: "Sources/EnviousWisprASR/WhisperKitStreamingSession.swift", matcher: "transcribe",
        text:
          "let results = try await whisperKit.transcribe(audioArray: paddedSamples, decodeOptions: opts)"
      ),
      SiteKey(
        file: "Sources/EnviousWisprASR/WhisperKitStreamingSession.swift", matcher: "transcribe",
        text:
          "let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)"
      ),
      SiteKey(
        file: "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift", matcher: "transcribe",
        text: "let result = try await backend.transcribe("),
      SiteKey(
        file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift", matcher: "transcribe",
        text: "let result = try await asrManager.transcribe("),
      SiteKey(
        file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
        matcher: "cancelStreaming",
        text: "await asrManager.cancelStreaming()"),
      SiteKey(
        file: "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift",
        matcher: "finalizeStreaming", text: "let result = try await asrManager.finalizeStreaming()"),
    ]
    let actualGapKeys = Set(
      Self.expected.compactMap { site -> SiteKey? in
        guard case .knownGap = site.classification else { return nil }
        return SiteKey(file: site.file, matcher: site.matcher, text: site.text)
      })
    #expect(
      actualGapKeys == expectedGapKeys,
      """
      `knownGap` must apply to exactly the confirmed-unsafe sites tracked at #1745/#1749 — found:
      \(actualGapKeys)
      A different entry carrying `knownGap` means either a real new gap was found (open its own
      issue and add it here deliberately) or an already-safe entry was quietly weakened to dodge
      Test 1 — neither may happen silently.
      """)
  }
}
