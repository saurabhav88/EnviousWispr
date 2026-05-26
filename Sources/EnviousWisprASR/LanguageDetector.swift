import EnviousWisprCore
import Foundation

// FIXME(#827): founder/upstream action needed. The LID observer closure needs
// within-window progress from WhisperKit before LanguageDetector can recover a
// wedged language-detection await without a wall-clock timeout.

// R2 (#360): no longer reaches `WhisperKit` directly. The non-Sendable
// reference stays inside `WhisperKitBackend.observeLID`; this actor consumes
// only the Sendable `LIDObservationBatch` shape.

/// Passive UX fallback event emitted by `LanguageDetector`.
///
/// The detector never owns UI. When conditions suggest a chip like
/// "Detected: Japanese. Lock it?" should appear, it calls `onPassiveChipTrigger`
/// on the main thread. The UI layer (W1) decides whether and how to show it.
public struct PassiveChipTrigger: Sendable, Equatable {
  public enum Reason: String, Sendable, Equatable {
    case lidFlipFlop  // two different langs accepted within 5 min
    case consecutiveLowConfidence  // two low-confidence results in a session
    /// Issue #252: N consecutive high-confidence accepts of the same non-English
    /// language. Surfaces a "Detected <Lang>. Lock it?" chip in the recording
    /// overlay post-dictation. English is a no-op for this signal. Threshold:
    /// `.highAuto` tier AND `confidence >= 0.85` AND 3 consecutive same-lang
    /// accepts. Counter is in-memory only; resets on app launch and on a
    /// different non-English lang accept.
    case consistentHighConfidence
  }
  public let lang: String?
  public let reason: Reason
  public init(lang: String?, reason: Reason) {
    self.lang = lang
    self.reason = reason
  }
}

/// Telemetry hook emitted when the detector observes two distinct accepted
/// languages within 5 minutes. Vendor containment: the detector lives in
/// `EnviousWisprASR` which cannot import PostHog, so the app wires a closure
/// from `TelemetryService` at `LanguageDetector` construction time.
///
/// Callers MUST NOT do heavy work on this callback; it fires inline with
/// detection. Treat it as fire-and-forget logging.
public struct LanguageFlipEvent: Sendable, Equatable {
  public let fromLang: String
  public let toLang: String
  /// Average of the two consecutive accept confidences (0...1). Used as a
  /// rough quality signal for "how sure were we both times?".
  public let confidenceBoth: Double
  public init(fromLang: String, toLang: String, confidenceBoth: Double) {
    self.fromLang = fromLang
    self.toLang = toLang
    self.confidenceBoth = confidenceBoth
  }
}

/// Thin clock seam so tests can deterministically advance time.
public protocol LanguageDetectorClock: Sendable {
  func now() -> Date
}
public struct SystemLanguageDetectorClock: LanguageDetectorClock {
  public init() {}
  public func now() -> Date { Date() }
}

/// Actor wrapping WhisperKit's `detectLanguage` with the five-layer autodetect
/// stack defined in docs/feature-requests/multilingual-v1.md.
///
/// Heart-protection contract: every public API returns a `LanguageDetectionResult`,
/// never throws. If WhisperKit errors internally, the detector abstains and the
/// pipeline passes `nil` to `TranscriptionOptions.language`, letting WhisperKit's
/// own LID run as the final fallback.
///
/// The detector is an actor so concurrent recordings serialize naturally. It holds
/// only the `SessionLanguageMemory` state and a clock seam; WhisperKit is supplied
/// per call from the backend so unloaded-model lifecycles do not leak here.
public actor LanguageDetector {
  private var memory: SessionLanguageMemory
  private let clock: LanguageDetectorClock
  private let defaults: UserDefaults
  // Mutable so callers can wire handlers post-init (see
  // `setPassiveChipHandler`). Needed for the former root state, which can't capture
  // `self` in init because its stored properties are still being set up.
  private var onPassiveChipTrigger: (@Sendable (PassiveChipTrigger) -> Void)?
  private let onLanguageFlip: (@Sendable (LanguageFlipEvent) -> Void)?
  // Last two accept timestamps/langs/confidences for flip-flop detection (within 5 min).
  private var recentAccepts: [(lang: String, confidence: Double, at: Date)] = []
  // Count of consecutive low-confidence detections in the current session.
  private var consecutiveLowConfidence: Int = 0
  // Anti-flap: candidate language pending a second consecutive strong accept
  // before it can replace sessionPreferred. Any non-confirming utterance
  // (abstain, lowAuto, different strong candidate, or a candidate that fails
  // the switch bar) clears this.
  private var pendingSwitchCandidate: String?
  /// Issue #252: per-language counter of consecutive high-confidence accepts of
  /// the same non-English language. In-memory only; resets on app launch. The
  /// only mutations are inside this actor; the LanguageChipCoordinator does NOT
  /// touch this dict (the two state machines are independent). On English
  /// `.highAuto` accept: complete no-op (no increment, no reset of other lang
  /// counters). On non-English `.highAuto` accept with confidence >= 0.85:
  /// increment own counter, reset all other entries to 0. On `.mediumAuto`,
  /// `.lowAuto`, or `.abstain`: complete no-op (do not increment, do not reset).
  /// When a lang's counter reaches `Self.consistentChipThreshold`, emit a
  /// `.consistentHighConfidence` trigger and reset that lang's counter to 0.
  private var consecutiveStrongAcceptsByLang: [String: Int] = [:]
  /// Issue #252 threshold: N=3 consecutive high-confidence accepts settled by
  /// council. Confidence floor 0.85 is checked at the accept site.
  private static let consistentChipThreshold = 3
  /// Issue #252 confidence floor for the `.consistentHighConfidence` emit path.
  /// Tighter than the `.highAuto` tier's 0.80; council settled for safer.
  private static let consistentChipConfidenceFloor: Double = 0.85

  public init(
    clock: LanguageDetectorClock = SystemLanguageDetectorClock(),
    defaults: UserDefaults = .standard,
    onPassiveChipTrigger: (@Sendable (PassiveChipTrigger) -> Void)? = nil,
    onLanguageFlip: (@Sendable (LanguageFlipEvent) -> Void)? = nil
  ) {
    self.clock = clock
    self.defaults = defaults
    self.onPassiveChipTrigger = onPassiveChipTrigger
    self.onLanguageFlip = onLanguageFlip
    self.memory = Self.loadMemory(from: defaults)
  }

  /// Install or replace the passive-chip handler post-init. Used by owners
  /// (e.g. the former root state) that cannot capture `self` at construction time because
  /// their stored properties are still being initialized.
  public func setPassiveChipHandler(_ handler: (@Sendable (PassiveChipTrigger) -> Void)?) {
    self.onPassiveChipTrigger = handler
  }

  // MARK: - Public API

  /// Run language detection on the supplied voiced samples.
  ///
  /// - Parameters:
  ///   - samples: 16kHz mono Float32 voiced samples. May be the raw captured
  ///     buffer or a VAD-filtered subset; the detector itself just windows what
  ///     it is given. Forwarded to `observerFn` for the per-window WhisperKit
  ///     calls.
  ///   - voicedDuration: Total voiced duration, in seconds. Used by the speech
  ///     gate (Layer 1).
  ///   - observerFn: Closure that runs the WhisperKit-side LID call and returns
  ///     a `LIDObservationBatch`. R2 (#360) — moves the WhisperKit handle out
  ///     of this actor. The closure is called only when actually needed (after
  ///     the locked-mode bypass and Layer 1 speech gate). The closure must
  ///     return a Sendable batch; the non-Sendable `WhisperKit` reference
  ///     stays inside the backend's actor isolation.
  ///   - mode: Current `LanguageMode` (auto or locked). Captured here (not at
  ///     recording-start) so late user toggles are respected.
  package func detect(
    samples: [Float],
    voicedDuration: TimeInterval,
    observerFn: @Sendable () async -> LIDObservationBatch,
    mode: LanguageMode
  ) async -> LanguageDetectionResult {
    // Locked short-circuit. No model call required. observerFn is NOT invoked
    // — pinned by `R2-CHAR-050` characterization test (added 2026-04-30).
    if case .locked(let code) = mode {
      let normalized = Self.normalizeLangCode(code)
      return LanguageDetectionResult(
        lang: normalized,
        confidence: 1.0,
        margin: 1.0,
        tier: .locked,
        voicedDuration: voicedDuration,
        abstained: false,
        usedSessionPrior: false
      )
    }

    let now = clock.now()
    memory.applyInactivityTimeout(now: now)
    memory.pruneExpiredUsage(now: now)
    // Drop stale flip-flop history (>5min old) up front.
    recentAccepts = recentAccepts.filter { now.timeIntervalSince($0.at) <= 300 }

    // Layer 1: speech gate.
    if voicedDuration < LanguageDetectorThresholds.shortClipMinSec {
      await log(
        "LID abstain: voicedDuration=\(voicedDuration)s < \(LanguageDetectorThresholds.shortClipMinSec)s"
      )
      memory.recordAbstain(now: now)
      persistMemory()
      return .abstain(voicedDuration: voicedDuration)
    }

    // Layer 2: multi-window detection. The backend runs the WhisperKit calls
    // and returns a Sendable batch. We map each batch variant to the matching
    // abstain reason — this preserves the per-failure-mode semantics from
    // the previous inline implementation.
    // TODO(#827): watchdog needs a within-window progress signal from the
    // observer owner (`WhisperKitBackend.observeLID`). This actor only sees the
    // batch after all windows return.
    let batch = await observerFn()
    let multi: MultiWindowLID
    switch batch {
    case .unavailable:
      // Same as today's nil-handle abstain (with persistMemory side effect).
      await log("LID abstain: backend reports model unavailable")
      memory.recordAbstain(now: now)
      persistMemory()
      return .abstain(voicedDuration: voicedDuration)
    case .cancelled:
      // User hotkey-cancelled: abstain cleanly, do not touch session memory.
      // The classifier-side observable behavior (clean abstain, no memory
      // touch, no telemetry) matches the previous inline implementation.
      // The backend-side cancellation path is slightly more responsive — see
      // `LIDObservationBatch.cancelled` doc comment for the detail.
      await log("LID cancelled during detectLanguage windows")
      return .abstain(voicedDuration: voicedDuration)
    case .noWindows:
      // No windows constructible from the provided samples. Treat as
      // empty-result abstain (matches today's empty-windows guard).
      memory.recordAbstain(now: now)
      persistMemory()
      return .abstain(voicedDuration: voicedDuration)
    case .error(let reason):
      // All windows failed. Matches today's outer-catch abstain branch.
      await log("LID failed, abstaining: \(reason)")
      memory.recordAbstain(now: now)
      persistMemory()
      return .abstain(voicedDuration: voicedDuration)
    case .observations(let observations):
      multi = aggregateObservations(observations)
    }

    guard !multi.voteCounts.isEmpty else {
      memory.recordAbstain(now: now)
      persistMemory()
      return .abstain(voicedDuration: voicedDuration)
    }
    // Structured aggregation log: lets us audit LID behavior in UAT logs
    // without per-window noise.
    let topLog = multi.voteCounts.keys
      .sorted { lhs, rhs in
        let lv = multi.voteCounts[lhs] ?? 0
        let rv = multi.voteCounts[rhs] ?? 0
        if lv != rv { return lv > rv }
        return (multi.meanProbs[lhs] ?? 0) > (multi.meanProbs[rhs] ?? 0)
      }
      .prefix(3)
      .map { lang in
        let votes = multi.voteCounts[lang] ?? 0
        let mean = multi.meanProbs[lang] ?? 0
        return "\(lang):votes=\(votes)/\(multi.windowCount),meanP=\(String(format: "%.3f", mean))"
      }.joined(separator: " ")
    await log("LID aggregated [\(topLog)]")

    // Rank languages by (voteCount desc, meanProb desc). The winner is the
    // language most windows agreed on; meanProb breaks ties. This separation
    // keeps the downstream classifier and `recordAccepted` on true per-
    // window confidence instead of a vote-share-diluted composite.
    let rankedLangs = Array(multi.voteCounts.keys).sorted { lhs, rhs in
      let lv = multi.voteCounts[lhs] ?? 0
      let rv = multi.voteCounts[rhs] ?? 0
      if lv != rv { return lv > rv }
      return (multi.meanProbs[lhs] ?? 0) > (multi.meanProbs[rhs] ?? 0)
    }
    let windowCountD = Double(max(multi.windowCount, 1))
    var topLang = rankedLangs[0]
    var topProb = multi.meanProbs[topLang] ?? 0
    var topVoteShare = Double(multi.voteCounts[topLang] ?? 0) / windowCountD
    // Margin is the vote-share gap between the winner and the next-best
    // language (0 when there is no runner-up).
    var runnerUpVoteShare: Double =
      rankedLangs.count > 1
      ? Double(multi.voteCounts[rankedLangs[1]] ?? 0) / windowCountD
      : 0
    var margin = max(0, topVoteShare - runnerUpVoteShare)
    var usedSessionPrior = false

    var decision = classify(
      topProb: topProb,
      margin: margin,
      voicedDuration: voicedDuration
    )

    // Session-prior boost (lowAuto rescue): if the preferred language has
    // at least as many votes as any other candidate (plurality, ties
    // allowed), bump its meanProb by +0.10 and re-evaluate. The rescue
    // CANNOT overturn a clear vote majority — that would defeat the whole
    // point of majority-vote aggregation. Commits only if the boost
    // elevates the decision past lowAuto.
    let rawPreferredMeanProb = multi.meanProbs[memory.sessionPreferred ?? ""] ?? 0
    if decision == .lowAuto,
      let preferred = memory.sessionPreferred,
      LanguageTypes.isSupported(preferred),
      (multi.voteCounts[preferred] ?? 0) > 0
    {
      let preferredShare = Double(multi.voteCounts[preferred] ?? 0) / windowCountD
      let competitor = rankedLangs.first(where: { $0 != preferred })
      let competitorShare =
        competitor.map {
          Double(multi.voteCounts[$0] ?? 0) / windowCountD
        } ?? 0
      // Gate: preferred must not be a minority loser. If another lang
      // has strictly more votes, the rescue is skipped.
      if preferredShare >= competitorShare {
        let boostedProb = min(
          1.0, rawPreferredMeanProb + LanguageDetectorThresholds.sessionPriorBoost)
        let competitorMeanProb = competitor.map { multi.meanProbs[$0] ?? 0 } ?? 0
        let voteMargin = preferredShare - competitorShare
        let probMargin = boostedProb - competitorMeanProb
        let boostedMargin = max(0, max(voteMargin, probMargin))
        let boostedDecision = classify(
          topProb: boostedProb,
          margin: boostedMargin,
          voicedDuration: voicedDuration
        )
        if boostedDecision != .lowAuto && boostedDecision != .abstain {
          topLang = preferred
          topProb = boostedProb
          topVoteShare = preferredShare
          runnerUpVoteShare = competitorShare
          margin = boostedMargin
          decision = boostedDecision
          usedSessionPrior = true
        }
      }
    }

    // When the session-prior boost rescues a decision, the returned
    // confidence + the value recorded into session memory must reflect the
    // model's actual per-window confidence, not the artificially boosted
    // value. Otherwise `recordAccepted` elevates languages based on the
    // +0.10 bump rather than genuine model evidence.
    let rawTopProb: Double = {
      if usedSessionPrior { return min(max(rawPreferredMeanProb, 0), 1) }
      return min(max(topProb, 0), 1)
    }()
    let rawMargin = margin
    // Repack as a (key, value) tuple so the existing downstream switch
    // branches keep their concise spelling.
    let top = (key: topLang, value: topProb)
    let runnerUp = runnerUpVoteShare

    switch decision {
    case .abstain:
      await log(
        "LID abstain: top=\(top.key) meanP=\(String(format: "%.3f", top.value)) voteShareMargin=\(String(format: "%.3f", rawMargin)) dur=\(voicedDuration)"
      )
      consecutiveLowConfidence += 1
      // Anti-flap: abstain breaks the "consecutive" chain.
      pendingSwitchCandidate = nil
      memory.recordAbstain(now: now)
      persistMemory()
      emitPassiveChipIfNeeded(forLang: top.key)
      return LanguageDetectionResult(
        lang: nil,
        confidence: rawTopProb,
        margin: rawMargin,
        tier: .abstain,
        voicedDuration: voicedDuration,
        abstained: true,
        usedSessionPrior: usedSessionPrior
      )

    case .lowAuto:
      // Accepted for decoding fallback tracking, but lexicon injection will
      // be suppressed by the prompt layer. Do not mark as session-preferred
      // or treat as a flip, but still count as a low-confidence signal.
      consecutiveLowConfidence += 1
      // Anti-flap: a low-confidence utterance also breaks the chain.
      pendingSwitchCandidate = nil
      memory.recordAbstain(now: now)
      persistMemory()
      emitPassiveChipIfNeeded(forLang: top.key)
      return LanguageDetectionResult(
        lang: top.key,
        confidence: rawTopProb,
        margin: rawMargin,
        tier: .lowAuto,
        voicedDuration: voicedDuration,
        abstained: false,
        usedSessionPrior: usedSessionPrior
      )

    case .mediumAuto, .highAuto:
      // Anti-flap: if a sessionPreferred exists and the detected lang
      // differs, require the high bar (>=0.85 prob, >=0.25 margin) twice
      // in a row to switch away — unless the evidence is unanimous across
      // all windows at moderate per-window confidence, in which case one
      // utterance is enough (prevents first-switch hallucination on clean
      // non-preferred audio).
      //
      // Note: the switch-bar signal is the per-window `meanProb` (not the
      // combined `score = mean * voteShare`). Otherwise non-unanimous
      // winners — e.g. 3/4 windows voting a language — could never cross
      // 0.85 regardless of per-window confidence, leaving the two-
      // utterance commit path unreachable in realistic mixed-window audio.
      let tier: LanguageConfidenceTier = (decision == .highAuto ? .highAuto : .mediumAuto)
      let winningMeanProb = multi.meanProbs[top.key] ?? 0
      let unanimous = multi.voteCounts[top.key] == multi.windowCount && multi.windowCount >= 2
      let singleShotSwitch =
        unanimous && winningMeanProb >= LanguageDetectorThresholds.unanimousSingleShotProb
      let finalLang = resolveAntiFlap(
        candidate: top.key,
        switchProbSignal: winningMeanProb,
        margin: rawMargin,
        allowSingleShotSwitch: singleShotSwitch
      )
      if finalLang == top.key {
        consecutiveLowConfidence = 0
        registerFlipFlopCandidate(lang: top.key, confidence: rawTopProb, at: now)
        memory.recordAccepted(lang: top.key, confidence: rawTopProb, now: now)
        persistMemory()
        // Issue #252: track consecutive high-confidence accepts of the same
        // non-English language. Per plan §3.1 and council Q1 resolution: only
        // `.highAuto` tier with confidence >= 0.85 counts. English is a complete
        // no-op (no increment, no reset of other counters). Non-English accept
        // increments own counter and resets all OTHER non-English counters.
        // `.mediumAuto` accepts are full no-ops (do not increment, do not reset).
        evaluateConsistentChipForAccept(
          finalLang: top.key,
          tier: tier,
          rawTopProb: rawTopProb
        )
        return LanguageDetectionResult(
          lang: top.key,
          confidence: rawTopProb,
          margin: rawMargin,
          tier: tier,
          voicedDuration: voicedDuration,
          abstained: false,
          usedSessionPrior: usedSessionPrior
        )
      } else {
        // Anti-flap rejected the switch: report sessionPreferred as the
        // winner, marked usedSessionPrior, with a dampened tier.
        memory.recordAccepted(lang: finalLang, confidence: rawTopProb, now: now)
        persistMemory()
        return LanguageDetectionResult(
          lang: finalLang,
          confidence: rawTopProb,
          margin: rawMargin,
          tier: .mediumAuto,
          voicedDuration: voicedDuration,
          abstained: false,
          usedSessionPrior: true
        )
      }
    }
  }

  /// Testing-only: observe internal memory.
  public func peekMemory() -> SessionLanguageMemory { memory }
  /// Testing-only: seed memory (e.g., for anti-flap setups without replaying
  /// full history).
  public func setMemoryForTesting(_ memory: SessionLanguageMemory) {
    self.memory = memory
  }
  /// Testing seam: run Layer 3 logic over a pre-computed probability dict.
  /// Skips the WhisperKit call so tests do not need a real model.
  public func evaluateForTesting(
    windowProbs: [String: Double],
    voicedDuration: TimeInterval,
    mode: LanguageMode = .auto
  ) async -> LanguageDetectionResult {
    if case .locked(let code) = mode {
      return LanguageDetectionResult(
        lang: Self.normalizeLangCode(code),
        confidence: 1.0, margin: 1.0, tier: .locked,
        voicedDuration: voicedDuration, abstained: false, usedSessionPrior: false
      )
    }
    let now = clock.now()
    memory.applyInactivityTimeout(now: now)
    memory.pruneExpiredUsage(now: now)
    recentAccepts = recentAccepts.filter { now.timeIntervalSince($0.at) <= 300 }

    if voicedDuration < LanguageDetectorThresholds.shortClipMinSec {
      memory.recordAbstain(now: now)
      return .abstain(voicedDuration: voicedDuration)
    }
    guard !windowProbs.isEmpty else {
      memory.recordAbstain(now: now)
      return .abstain(voicedDuration: voicedDuration)
    }
    let rawRanked = windowProbs.sorted { $0.value > $1.value }
    var top = rawRanked[0]
    var runnerUp: Double = rawRanked.count > 1 ? rawRanked[1].value : 0
    var usedSessionPrior = false

    var decision = classify(
      topProb: top.value,
      margin: top.value - runnerUp,
      voicedDuration: voicedDuration
    )

    if decision == .lowAuto,
      let preferred = memory.sessionPreferred,
      LanguageTypes.isSupported(preferred),
      windowProbs[preferred] != nil
    {
      var boosted = windowProbs
      boosted[preferred, default: 0] += LanguageDetectorThresholds.sessionPriorBoost
      let boostedRanked = boosted.sorted { $0.value > $1.value }
      let boostedTop = boostedRanked[0]
      let boostedRunner: Double = boostedRanked.count > 1 ? boostedRanked[1].value : 0
      let boostedDecision = classify(
        topProb: boostedTop.value,
        margin: boostedTop.value - boostedRunner,
        voicedDuration: voicedDuration
      )
      if boostedDecision != .lowAuto && boostedDecision != .abstain {
        top = boostedTop
        runnerUp = boostedRunner
        decision = boostedDecision
        usedSessionPrior = true
      }
    }

    let rawTopProb = min(max(windowProbs[top.key] ?? top.value, 0), 1)
    let rawMargin = max(0, rawTopProb - (rawRanked.count > 1 ? rawRanked[1].value : 0))
    switch decision {
    case .abstain:
      consecutiveLowConfidence += 1
      pendingSwitchCandidate = nil
      memory.recordAbstain(now: now)
      return LanguageDetectionResult(
        lang: nil, confidence: rawTopProb, margin: rawMargin,
        tier: .abstain, voicedDuration: voicedDuration,
        abstained: true, usedSessionPrior: usedSessionPrior
      )
    case .lowAuto:
      consecutiveLowConfidence += 1
      pendingSwitchCandidate = nil
      memory.recordAbstain(now: now)
      return LanguageDetectionResult(
        lang: top.key, confidence: rawTopProb, margin: rawMargin,
        tier: .lowAuto, voicedDuration: voicedDuration,
        abstained: false, usedSessionPrior: usedSessionPrior
      )
    case .mediumAuto, .highAuto:
      let tier: LanguageConfidenceTier = (decision == .highAuto ? .highAuto : .mediumAuto)
      // evaluateForTesting has no per-window info; callers supply a
      // pre-aggregated distribution, so treat `top.value` as both the
      // switch-bar signal and the score. No single-shot path here.
      let finalLang = resolveAntiFlap(
        candidate: top.key,
        switchProbSignal: top.value,
        margin: top.value - runnerUp,
        allowSingleShotSwitch: false
      )
      if finalLang == top.key {
        consecutiveLowConfidence = 0
        registerFlipFlopCandidate(lang: top.key, confidence: rawTopProb, at: now)
        memory.recordAccepted(lang: top.key, confidence: rawTopProb, now: now)
        // Issue #252: same chip-counter evaluation as the production `detect`
        // path, so tests can drive it without WhisperKit.
        evaluateConsistentChipForAccept(
          finalLang: top.key,
          tier: tier,
          rawTopProb: rawTopProb
        )
        return LanguageDetectionResult(
          lang: top.key, confidence: rawTopProb, margin: rawMargin,
          tier: tier, voicedDuration: voicedDuration,
          abstained: false, usedSessionPrior: usedSessionPrior
        )
      } else {
        memory.recordAccepted(lang: finalLang, confidence: rawTopProb, now: now)
        return LanguageDetectionResult(
          lang: finalLang, confidence: rawTopProb, margin: rawMargin,
          tier: .mediumAuto, voicedDuration: voicedDuration,
          abstained: false, usedSessionPrior: true
        )
      }
    }
  }

  // MARK: - Layer 2: multi-window LID

  /// Aggregated outcome of the multi-window language detection pass.
  ///
  /// - `voteCounts`: Raw per-window argmax wins per language.
  /// - `meanProbs`: Mean exp(logProb) per language across windows where it won.
  /// - `windowCount`: Number of windows that actually returned a result.
  ///
  /// The classifier and anti-flap paths consume `meanProbs[winner]` as the
  /// per-window confidence and the `voteShare` gap as margin. Keeping these
  /// signals separate (instead of collapsing them into a single score)
  /// prevents vote-share dilution from masking true per-window confidence.
  struct MultiWindowLID {
    let voteCounts: [String: Int]
    let meanProbs: [String: Double]
    let windowCount: Int
  }

  /// Aggregate per-window observations into vote counts + mean probabilities.
  ///
  /// R2 (#360): This is the post-WhisperKit-call portion of the previous
  /// `runMultiWindowLID`. Window construction + the `detectLangauge` call moved
  /// to `WhisperKitBackend.observeLID`, which returns a `[RawLIDObservation]`
  /// inside `LIDObservationBatch.observations`. This helper takes that array
  /// and produces the `MultiWindowLID` shape the classifier consumes.
  ///
  /// Aggregation rule (preserved verbatim from the previous inline code):
  /// - Each observation contributes one vote to its `argmaxLang`.
  /// - Each observation's clamped `exp(logProb)` contributes to the per-language
  ///   probability sum.
  /// - The returned `meanProbs[lang]` is the average exp(logProb) across windows
  ///   where that language won.
  private func aggregateObservations(_ observations: [RawLIDObservation]) -> MultiWindowLID {
    var votes: [String: Int] = [:]
    var probSum: [String: Double] = [:]
    for obs in observations {
      let p = min(max(exp(obs.logProb), 0), 1)
      votes[obs.argmaxLang, default: 0] += 1
      probSum[obs.argmaxLang, default: 0] += p
    }
    let counted = observations.count
    guard counted > 0 else {
      return MultiWindowLID(voteCounts: [:], meanProbs: [:], windowCount: 0)
    }
    var means: [String: Double] = [:]
    for (lang, count) in votes {
      means[lang] = probSum[lang, default: 0] / Double(count)
    }
    return MultiWindowLID(voteCounts: votes, meanProbs: means, windowCount: counted)
  }

  // MARK: - Layer 3: session memory logic

  /// Anti-flap: if there is a session-preferred language and the candidate is
  /// different, require TWO consecutive utterances at prob >= 0.85 AND
  /// margin >= 0.25 before switching away (per spec). A single strong
  /// utterance sets a pending candidate; the next accepted utterance confirms
  /// or invalidates it. Any non-confirming event (abstain, lowAuto, a
  /// different strong candidate, or a candidate that fails the switch bar)
  /// resets the pending state.
  private func resolveAntiFlap(
    candidate: String,
    switchProbSignal: Double,
    margin: Double,
    allowSingleShotSwitch: Bool
  ) -> String {
    guard let preferred = memory.sessionPreferred,
      LanguageTypes.isSupported(preferred),
      preferred != candidate
    else {
      // No preferred, or candidate is the preferred: no anti-flap logic needed.
      pendingSwitchCandidate = nil
      return candidate
    }
    // Unanimous + strong per-window confidence bypasses the two-utterance
    // gate. Checked first so the low-confidence single-shot range that
    // `unanimousSingleShotProb` is designed to cover cannot be short-
    // circuited by the stricter `switchProb` bar below.
    if allowSingleShotSwitch {
      pendingSwitchCandidate = nil
      return candidate
    }
    let switchProb = 0.85
    let meetsSwitchBar =
      switchProbSignal >= switchProb
      && margin >= LanguageDetectorThresholds.highMargin
    if !meetsSwitchBar {
      // Candidate is not strong enough to count as switch evidence.
      pendingSwitchCandidate = nil
      return preferred
    }
    if pendingSwitchCandidate == candidate {
      // Second consecutive strong utterance for this candidate: commit switch.
      pendingSwitchCandidate = nil
      return candidate
    }
    // First strong utterance for this candidate: record pending, keep preferred.
    pendingSwitchCandidate = candidate
    return preferred
  }

  private func registerFlipFlopCandidate(lang: String, confidence: Double, at now: Date) {
    // Capture the most recent prior accept (if any) before we append, so we
    // can emit a `language.flip` telemetry event with from/to lang + the
    // confidence of both.
    let prior = recentAccepts.last
    recentAccepts.append((lang: lang, confidence: confidence, at: now))
    recentAccepts = recentAccepts.filter { now.timeIntervalSince($0.at) <= 300 }
    // Two distinct langs within 5 min triggers the UX chip AND telemetry.
    let uniques = Set(recentAccepts.map { $0.lang })
    if uniques.count >= 2 {
      emitPassiveChip(.init(lang: lang, reason: .lidFlipFlop))
      if let prior, prior.lang != lang, let cb = onLanguageFlip {
        let avg = (prior.confidence + confidence) / 2.0
        cb(LanguageFlipEvent(fromLang: prior.lang, toLang: lang, confidenceBoth: avg))
      }
    }
  }

  private func emitPassiveChipIfNeeded(forLang lang: String?) {
    if consecutiveLowConfidence >= 2 {
      emitPassiveChip(.init(lang: lang, reason: .consecutiveLowConfidence))
      consecutiveLowConfidence = 0
    }
  }

  private func emitPassiveChip(_ trigger: PassiveChipTrigger) {
    guard let cb = onPassiveChipTrigger else { return }
    cb(trigger)
  }

  /// Issue #252: evaluate whether this accept advances the consistent-language
  /// chip counter and emit `.consistentHighConfidence` if N is reached.
  ///
  /// Rules (council Q1 + F4 settled):
  /// - Tier MUST be `.highAuto` AND confidence >= 0.85. Anything else (mediumAuto,
  ///   lowAuto, abstain): complete no-op (do not increment, do not reset).
  /// - Normalized base "en": complete no-op (English is invisible to the chip).
  /// - Non-English with high tier + conf >= 0.85: increment own counter, reset
  ///   all other entries to 0 (different-lang resets others). If counter reaches
  ///   `consistentChipThreshold` (3), emit `.consistentHighConfidence` and reset
  ///   that lang's counter to 0 (prevents re-emit on the next accept).
  private func evaluateConsistentChipForAccept(
    finalLang: String,
    tier: LanguageConfidenceTier,
    rawTopProb: Double
  ) {
    // Tier + confidence gate
    guard tier == .highAuto, rawTopProb >= Self.consistentChipConfidenceFloor else {
      return
    }
    // English no-op (F4)
    let base = Self.normalizedBaseLang(finalLang)
    guard base != "en" else { return }
    // Non-English increment + reset others
    let next = (consecutiveStrongAcceptsByLang[base] ?? 0) + 1
    consecutiveStrongAcceptsByLang = [base: next]
    if next >= Self.consistentChipThreshold {
      consecutiveStrongAcceptsByLang[base] = 0
      emitPassiveChip(.init(lang: base, reason: .consistentHighConfidence))
    }
  }

  /// Issue #252: strip variant suffix and lowercase. Mirrors
  /// `LanguageChipCoordinator.normalizedBase`. `en-US` -> `en`, `Es_ES` -> `es`.
  private static func normalizedBaseLang(_ lang: String) -> String {
    let lower = lang.lowercased()
    if let sepIdx = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
      return String(lower[..<sepIdx])
    }
    return lower
  }

  // MARK: - Classification

  enum Decision: Equatable { case abstain, lowAuto, mediumAuto, highAuto }

  func classify(topProb: Double, margin: Double, voicedDuration: TimeInterval) -> Decision {
    // Short clip: apply strict bar; below it, abstain entirely.
    if voicedDuration < LanguageDetectorThresholds.confidentMinSec {
      if topProb >= LanguageDetectorThresholds.strictProb,
        margin >= LanguageDetectorThresholds.strictMargin
      {
        return .highAuto
      }
      // Per spec: stricter thresholds failed -> abstain (fall back to sticky).
      return .abstain
    }
    // Normal clip (>= 2.5s voiced).
    if topProb >= LanguageDetectorThresholds.highProb,
      margin >= LanguageDetectorThresholds.highMargin
    {
      return .highAuto
    }
    if topProb >= LanguageDetectorThresholds.normalProb,
      margin >= LanguageDetectorThresholds.normalMargin
    {
      return .mediumAuto
    }
    return .lowAuto
  }

  // MARK: - Persistence

  private func persistMemory() {
    guard let data = try? JSONEncoder().encode(memory) else { return }
    defaults.set(data, forKey: SessionLanguageMemory.userDefaultsKey)
  }

  private static func loadMemory(from defaults: UserDefaults) -> SessionLanguageMemory {
    guard let data = defaults.data(forKey: SessionLanguageMemory.userDefaultsKey),
      var decoded = try? JSONDecoder().decode(SessionLanguageMemory.self, from: data)
    else {
      return SessionLanguageMemory()
    }
    // Defensive: strip any langs that are not in the 99-language set.
    decoded.usage24h = decoded.usage24h.filter { LanguageTypes.isSupported($0.key) }
    decoded.accepted = decoded.accepted.filter { LanguageTypes.isSupported($0.lang) }
    if let p = decoded.sessionPreferred, !LanguageTypes.isSupported(p) {
      decoded.sessionPreferred = nil
    }
    return decoded
  }

  // MARK: - Utilities

  private static func normalizeLangCode(_ code: String) -> String {
    code.lowercased()
  }

  private func log(_ message: String) async {
    await AppLogger.shared.log(message, level: .info, category: "LanguageDetector")
  }
}
