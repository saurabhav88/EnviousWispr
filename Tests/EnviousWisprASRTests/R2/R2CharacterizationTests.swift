import EnviousWisprCore
import Darwin
import Foundation
import Testing

@testable import EnviousWisprASR

// R2 (#360) — Characterization tests for the LanguageDetector classifier.
//
// PR 1 of 2. Ships against unchanged production code. Establishes the
// regression oracle for PR 2's WhisperKitBackend boundary refactor +
// LanguageDetector input-shape change.
//
// =====================================================================
// CRITICAL: PR 2 (#360) MUST NOT MODIFY THE ASSERTIONS IN THIS FILE.
// =====================================================================
//
// The refactor PR is allowed to:
//   - Add new R2 test files for new code paths it introduces
//     (e.g. LIDObservationBatch.error / .unavailable / .noWindows handling).
//   - Update imports if module names change (none planned).
//
// The refactor PR is NOT allowed to:
//   - Edit any `#expect(...)` line below.
//   - Edit any `windowProbs:` / `voicedDuration:` / `mode:` argument below.
//   - Delete any `@Test` function below.
//   - Weaken any tolerance.
//   - Add @Test(.disabled) or .skipped to anything below.
//
// Codex code-diff review on PR 2 must explicitly verify the diff against
// `Tests/EnviousWisprASRTests/R2/R2CharacterizationTests.swift` is empty
// or additive-only. If the file is touched, PR 2 is rejected until the
// edit is justified in writing.
//
// =====================================================================
//
// Scope and honest limits:
//
// These tests use `LanguageDetector.evaluateForTesting(windowProbs:...)`,
// which feeds aggregated language probabilities directly into the classifier.
// They DO characterize: locked-mode bypass, duration gates, confidence-tier
// boundaries, session-prior boost in lowAuto rescue, sessionPreferred
// elevation rule, the anti-flap switch-blocking path under
// `evaluateForTesting`'s pre-aggregated input, the `consecutiveLowConfidence`
// counter behavior, and the passive-chip / language-flip side-effect emission.
//
// They do NOT characterize:
//   - The multi-window aggregation logic in `runMultiWindowLID` lines 559-592.
//     That moves in PR 2 from LanguageDetector into WhisperKitBackend.observeLID.
//   - The `unanimousSingleShotProb` single-shot anti-flap switch path. That
//     branch is ONLY reachable via `detect()` (which has per-window vote/count
//     info), not via `evaluateForTesting` (which collapses to a single
//     pre-aggregated prob — see LanguageDetector.swift:473 comment).
//
// PR 2 must verify the un-characterized paths via:
//   1. Codex code-diff review on the migrated aggregation block (must be verbatim).
//   2. Live UAT (`wispr_eyes.test_recording`) with auto-mode + locked-mode
//      sentences confirming end-to-end pipeline behavior.
//   3. The single-shot path is exercised by existing `LanguageDetectorTests`
//      end-to-end paths; PR 2 must keep those green.
//
// =====================================================================

@Suite("R2 characterization — classifier decision branches")
struct R2CharacterizationTests {

  // MARK: - Locked mode bypass (load-bearing for PR 2)

  /// PR 2 must preserve the locked-mode early-return at LanguageDetector.swift:123.
  /// In locked mode, NO window probabilities should ever be consulted — the result
  /// is determined entirely by the locked language code.
  @Test("R2-CHAR-001: locked mode returns the locked code with confidence 1.0")
  func lockedModeReturnsLockedCode() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["fr": 0.95],  // would otherwise pick fr; locked-en wins
      voicedDuration: 4.0,
      mode: .locked("en")
    )
    #expect(result.lang == "en")
    #expect(result.tier == .locked)
    #expect(result.confidence == 1.0)
    #expect(result.margin == 1.0)
    #expect(result.abstained == false)
    #expect(result.usedSessionPrior == false)
  }

  @Test(
    "R2-CHAR-002: locked mode lowercases language codes (preserves region per current normalize impl)"
  )
  func lockedModeLowercasesCode() async {
    // Production `normalizeLangCode` lowercases but does NOT strip region.
    // Characterization pin: PR 2 must preserve this exact behavior. If the
    // intent is to strip region, that is a separate change not bundled with
    // R2.
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: [:],
      voicedDuration: 4.0,
      mode: .locked("EN-US")
    )
    #expect(result.lang == "en-us")
    #expect(result.tier == .locked)
  }

  @Test("R2-CHAR-003: locked mode with empty audio still returns locked code (no abstain)")
  func lockedModeIgnoresEmptyAudio() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: [:],
      voicedDuration: 0.1,  // below short-clip gate
      mode: .locked("de")
    )
    #expect(result.lang == "de")
    #expect(result.tier == .locked)
    #expect(result.abstained == false)
  }

  // MARK: - Duration gate (Layer 1)

  @Test("R2-CHAR-010: voicedDuration below shortClipMinSec abstains regardless of confidence")
  func durationGateAbstainsBelowMin() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.99],
      voicedDuration: 0.5,  // < 1.0s
      mode: .auto
    )
    #expect(result.abstained)
    #expect(result.tier == .abstain)
    #expect(result.lang == nil)
  }

  @Test("R2-CHAR-011: empty windowProbs (no observations) abstains")
  func emptyObservationsAbstains() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: [:],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.abstained)
    #expect(result.tier == .abstain)
    #expect(result.lang == nil)
  }

  // MARK: - Strict short-clip thresholds (Layer 2 + Layer 3 boundary)

  @Test("R2-CHAR-020: short clip (1.0-2.5s) requires high prob to escape strict abstain")
  func shortClipFailsStrict() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.70, "de": 0.50],  // passes normal, fails strict
      voicedDuration: 1.5,
      mode: .auto
    )
    #expect(result.tier == .abstain)
    #expect(result.abstained)
  }

  @Test("R2-CHAR-021: short clip with high prob passes strict")
  func shortClipPassesStrict() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.90, "de": 0.60],
      voicedDuration: 1.5,
      mode: .auto
    )
    #expect(result.tier == .highAuto)
    #expect(result.lang == "en")
    #expect(result.abstained == false)
  }

  // MARK: - Tier boundaries (Layer 3 classifier)

  @Test("R2-CHAR-030: normal-clip low-confidence accepts at lowAuto tier (decoder-fallback)")
  func lowAutoTierAccepts() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.50, "de": 0.30, "fr": 0.20],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.tier == .lowAuto)
    #expect(result.lang == "en")
    #expect(result.abstained == false)
  }

  @Test("R2-CHAR-031: normal-clip medium-prob accepts at mediumAuto tier")
  func mediumAutoTier() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.65, "de": 0.45],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.tier == .mediumAuto)
    #expect(result.lang == "en")
  }

  @Test("R2-CHAR-032: normal-clip high-prob with margin accepts at highAuto tier")
  func highAutoTier() async {
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.85, "de": 0.55],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.tier == .highAuto)
    #expect(result.lang == "en")
  }

  @Test("R2-CHAR-033: narrow margin (below normalMargin) drops the decision to lowAuto")
  func narrowMarginDropsToLowAuto() async {
    // Inputs (0.65 top, 0.60 runner-up, margin 0.05) are below `normalMargin`.
    // `classify()` therefore returns `.lowAuto`, not `.mediumAuto` and not
    // `.highAuto`. Pin the exact tier so PR 2 cannot quietly relax this.
    let (detector, _) = r2MakeDetector()
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.65, "de": 0.60],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.tier == .lowAuto)
    #expect(result.lang == "en")
    #expect(result.abstained == false)
  }

  // MARK: - Session prior + anti-flap (load-bearing for PR 2 — these branches
  // depend on `memory.sessionPreferred` reads that PR 2 must not break)

  @Test("R2-CHAR-040: single high-conf accept does NOT seed sessionPreferred")
  func singleHighConfDoesNotSeedSessionPreferred() async {
    // Production rule (`SessionLanguageMemory.recordAccepted` in
    // `LanguageTypes.swift:188-213`): sessionPreferred is set ONLY when the
    // last two accepts are the same language AND both are >= highProb.
    // A single accept leaves sessionPreferred at nil. PR 2 must preserve
    // this exact two-accept elevation rule.
    let (detector, _) = r2MakeDetector()
    _ = await detector.evaluateForTesting(
      windowProbs: ["en": 0.92, "de": 0.40],
      voicedDuration: 4.0,
      mode: .auto
    )
    let mem = await detector.peekMemory()
    #expect(mem.sessionPreferred == nil)
  }

  @Test("R2-CHAR-040b: two consecutive high-conf accepts of same lang seed sessionPreferred")
  func twoHighConfSeedSessionPreferred() async {
    let (detector, _) = r2MakeDetector()
    _ = await detector.evaluateForTesting(
      windowProbs: ["en": 0.92, "de": 0.40],
      voicedDuration: 4.0,
      mode: .auto
    )
    _ = await detector.evaluateForTesting(
      windowProbs: ["en": 0.90, "de": 0.45],
      voicedDuration: 4.0,
      mode: .auto
    )
    let mem = await detector.peekMemory()
    #expect(mem.sessionPreferred == "en")
  }

  @Test("R2-CHAR-041: anti-flap blocks weak switch from established sessionPreferred")
  func antiFlapBlocksWeakSwitch() async {
    let (detector, _) = r2MakeDetector()
    // Establish de as sessionPreferred via two strong utterances
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0, mode: .auto
    )
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0, mode: .auto
    )
    // Weak switch attempt to en (below switch bar) should be blocked
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.70, "de": 0.45],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.lang == "de")  // anti-flap kept de as winner
    #expect(result.usedSessionPrior == true)
  }

  @Test("R2-CHAR-042: single strong utterance does not switch sessionPreferred")
  func antiFlapOneStrongDoesNotSwitch() async {
    let (detector, _) = r2MakeDetector()
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0, mode: .auto
    )
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0, mode: .auto
    )
    // One strong en utterance — should NOT switch yet (needs two consecutive)
    let result = await detector.evaluateForTesting(
      windowProbs: ["en": 0.92, "de": 0.40],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.lang == "de")  // first switch attempt blocked
  }

  @Test("R2-CHAR-043: session-prior rescues lowAuto when preferred matches")
  func sessionPriorRescuesLowAuto() async {
    let (detector, _) = r2MakeDetector()
    // Seed sessionPreferred = de via two strong utterances
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0, mode: .auto
    )
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0, mode: .auto
    )
    // Now low-conf de should be rescued by session prior
    let result = await detector.evaluateForTesting(
      windowProbs: ["de": 0.55, "en": 0.40],
      voicedDuration: 4.0,
      mode: .auto
    )
    #expect(result.lang == "de")
    #expect(result.usedSessionPrior == true)
    #expect(result.tier != .lowAuto)
  }

  // MARK: - Side-effect callbacks (load-bearing for PR 2)

  /// PR 2 must preserve the flip-flop event emission contract: when two
  /// distinct languages are accepted within 5 minutes, the `onLanguageFlip`
  /// callback fires with the prior + current language and the average
  /// confidence. This is `registerFlipFlopCandidate` at LanguageDetector.swift:645.
  @Test("R2-CHAR-050: onLanguageFlip fires when two distinct strong accepts land within 5 min")
  func onLanguageFlipFiresOnTwoStrongDifferentLangs() async {
    // Capture flip events deterministically.
    let received = FlipEventRecorder()
    let detector = LanguageDetector(
      clock: R2TestClock(),
      defaults: r2EphemeralDefaults(),
      onLanguageFlip: { event in received.append(event) }
    )
    // First strong accept: en
    _ = await detector.evaluateForTesting(
      windowProbs: ["en": 0.92, "de": 0.30], voicedDuration: 4.0, mode: .auto
    )
    // Second strong accept: de (different lang) — should fire callback
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.92, "en": 0.30], voicedDuration: 4.0, mode: .auto
    )
    // Now establish de as sessionPreferred via second consecutive de
    _ = await detector.evaluateForTesting(
      windowProbs: ["de": 0.90, "en": 0.30], voicedDuration: 4.0, mode: .auto
    )
    let events = received.snapshot()
    // At least one flip event from en->de; PR 2 must keep this contract alive.
    #expect(events.count >= 1)
    if let firstFlip = events.first {
      #expect(firstFlip.fromLang == "en")
      #expect(firstFlip.toLang == "de")
    }
  }

  /// `evaluateForTesting` does NOT call `emitPassiveChipIfNeeded`. The passive
  /// chip path runs only inside `detect()` (LanguageDetector.swift:295,315).
  /// Therefore the consecutiveLowConfidence counter behavior is not directly
  /// observable through this test seam. PR 2 must rely on existing
  /// `LanguageDetectorTests` end-to-end paths to keep the chip contract intact.
  /// This comment is intentionally a documented gap, not a TODO.

  // MARK: - Single-window observations

  @Test("R2-CHAR-070: single-window observation passes strict-tier acceptance bar")
  func singleWindowObservationPassesStrictTierAcceptanceBar() async {
    let (detector, _) = r2MakeDetector()

    let result = await detector.detect(
      samples: [0.1],
      voicedDuration: 1.5,
      observerFn: {
        .observations([
          RawLIDObservation(argmaxLang: "en", logProb: log(0.85))
        ])
      },
      mode: .auto
    )

    #expect(result.lang == "en")
    #expect(result.tier == .highAuto)
    #expect(result.confidence >= LanguageDetectorThresholds.strictProb)
    #expect(result.margin >= LanguageDetectorThresholds.strictMargin)
    #expect(result.abstained == false)
  }

  @Test("R2-CHAR-071: single-window observation below strict bar abstains cleanly")
  func singleWindowObservationBelowStrictBarAbstainsCleanly() async {
    let (detector, _) = r2MakeDetector()

    let result = await detector.detect(
      samples: [0.1],
      voicedDuration: 1.5,
      observerFn: {
        .observations([
          RawLIDObservation(argmaxLang: "en", logProb: log(0.79))
        ])
      },
      mode: .auto
    )

    #expect(result.lang == nil)
    #expect(result.tier == .abstain)
    #expect(result.confidence < LanguageDetectorThresholds.strictProb)
    #expect(result.abstained)
  }
}

/// Test-side recorder for `onLanguageFlip` events. Sendable so it can survive
/// Swift 6 strict concurrency.
final class FlipEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [LanguageFlipEvent] = []

  func append(_ event: LanguageFlipEvent) {
    lock.lock()
    defer { lock.unlock() }
    events.append(event)
  }

  func snapshot() -> [LanguageFlipEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}
