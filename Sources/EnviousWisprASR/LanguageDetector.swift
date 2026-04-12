import Foundation
import EnviousWisprCore
@preconcurrency import WhisperKit

/// Passive UX fallback event emitted by `LanguageDetector`.
///
/// The detector never owns UI. When conditions suggest a chip like
/// "Detected: Japanese. Lock it?" should appear, it calls `onPassiveChipTrigger`
/// on the main thread. The UI layer (W1) decides whether and how to show it.
public struct PassiveChipTrigger: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case lidFlipFlop                // two different langs accepted within 5 min
        case consecutiveLowConfidence   // two low-confidence results in a session
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
    // `setPassiveChipHandler`). Needed for AppState, which can't capture
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
    /// (e.g. AppState) that cannot capture `self` at construction time because
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
    ///     it is given.
    ///   - voicedDuration: Total voiced duration, in seconds. Used by the speech
    ///     gate (Layer 1).
    ///   - whisperKit: Loaded WhisperKit instance. Passed in per call so the
    ///     detector does not own model lifecycle.
    ///   - mode: Current `LanguageMode` (auto or locked). Captured here (not at
    ///     recording-start) so late user toggles are respected.
    public func detect(
        samples: [Float],
        voicedDuration: TimeInterval,
        whisperKit: WhisperKit?,
        mode: LanguageMode
    ) async -> LanguageDetectionResult {
        // Locked short-circuit. No model call required.
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
            await log("LID abstain: voicedDuration=\(voicedDuration)s < \(LanguageDetectorThresholds.shortClipMinSec)s")
            memory.recordAbstain(now: now)
            persistMemory()
            return .abstain(voicedDuration: voicedDuration)
        }

        guard let kit = whisperKit else {
            await log("LID abstain: whisperKit instance unavailable")
            memory.recordAbstain(now: now)
            persistMemory()
            return .abstain(voicedDuration: voicedDuration)
        }

        // Layer 2: multi-window detection with mean probabilities.
        let aggregated: [String: Double]
        do {
            aggregated = try await runMultiWindowLID(samples: samples, voicedDuration: voicedDuration, whisperKit: kit)
        } catch is CancellationError {
            // User hotkey-cancelled: abstain cleanly, do not touch session memory.
            await log("LID cancelled during detectLanguage windows")
            return .abstain(voicedDuration: voicedDuration)
        } catch {
            await log("LID failed, abstaining: \(error.localizedDescription)")
            memory.recordAbstain(now: now)
            persistMemory()
            return .abstain(voicedDuration: voicedDuration)
        }

        guard !aggregated.isEmpty else {
            memory.recordAbstain(now: now)
            persistMemory()
            return .abstain(voicedDuration: voicedDuration)
        }

        // Layer 3: rank raw probabilities first so the anti-flap gate sees the
        // model's unbiased view. Session-prior boost is only applied to rescue
        // borderline (lowAuto) decisions per spec ("boost ... in later
        // low-confidence decisions").
        let rawRanked = aggregated.sorted { $0.value > $1.value }
        var top = rawRanked[0]
        var runnerUp: Double = rawRanked.count > 1 ? rawRanked[1].value : 0
        var usedSessionPrior = false

        // Decide acceptance tier against the speech-duration-aware thresholds.
        var decision = classify(
            topProb: top.value,
            margin: top.value - runnerUp,
            voicedDuration: voicedDuration
        )

        // If lowAuto AND we have a session-preferred language present in probs,
        // apply the +0.10 boost and re-rank. This is the rescue path for
        // borderline cases where the prior should tip the balance.
        if decision == .lowAuto,
           let preferred = memory.sessionPreferred,
           LanguageTypes.isSupported(preferred),
           aggregated[preferred] != nil {
            var boosted = aggregated
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

        let rawTopProb = min(max(aggregated[top.key] ?? top.value, 0), 1)
        let rawMargin = max(0, rawTopProb - (rawRanked.count > 1 ? rawRanked[1].value : 0))

        switch decision {
        case .abstain:
            await log("LID abstain: top=\(top.key) prob=\(top.value) margin=\(top.value - runnerUp) dur=\(voicedDuration)")
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
            // in a row to switch away.
            let tier: LanguageConfidenceTier = (decision == .highAuto ? .highAuto : .mediumAuto)
            let finalLang = resolveAntiFlap(
                candidate: top.key,
                topProb: top.value,
                margin: top.value - runnerUp
            )
            if finalLang == top.key {
                consecutiveLowConfidence = 0
                registerFlipFlopCandidate(lang: top.key, confidence: rawTopProb, at: now)
                memory.recordAccepted(lang: top.key, confidence: rawTopProb, now: now)
                persistMemory()
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
           windowProbs[preferred] != nil {
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
            let finalLang = resolveAntiFlap(candidate: top.key, topProb: top.value, margin: top.value - runnerUp)
            if finalLang == top.key {
                consecutiveLowConfidence = 0
                registerFlipFlopCandidate(lang: top.key, confidence: rawTopProb, at: now)
                memory.recordAccepted(lang: top.key, confidence: rawTopProb, now: now)
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

    private func runMultiWindowLID(
        samples: [Float],
        voicedDuration: TimeInterval,
        whisperKit: WhisperKit
    ) async throws -> [String: Double] {
        let sampleRate = LanguageDetectorThresholds.sampleRate
        let totalSamples = samples.count
        var windows: [[Float]] = []

        for w in LanguageDetectorThresholds.windows {
            let startIdx = min(totalSamples, Int(w.start * Double(sampleRate)))
            let endIdx = min(totalSamples, Int(w.end * Double(sampleRate)))
            guard endIdx > startIdx else { continue }
            windows.append(Array(samples[startIdx..<endIdx]))
        }
        // Full voiced window capped at 12s (always included so we always have >=1).
        let fullEnd = min(totalSamples, Int(LanguageDetectorThresholds.fullWindowMaxSec * Double(sampleRate)))
        if fullEnd > 0 {
            windows.append(Array(samples[0..<fullEnd]))
        }
        guard !windows.isEmpty else { return [:] }

        // Run up to 4 windows. The spec says "up to 4"; for short voicedDuration
        // many of the fixed windows collapse to empty and are skipped above.
        let capped = Array(windows.prefix(4))

        var accumulated: [String: Double] = [:]
        var counted = 0
        for (i, window) in capped.enumerated() {
            try Task.checkCancellation()
            // Each window is its own detectLanguage call. WhisperKit API is
            // `detectLangauge(audioArray:)` (original typo preserved upstream).
            let result: (language: String, langProbs: [String: Float])
            do {
                result = try await whisperKit.detectLangauge(audioArray: window)
            } catch {
                await log("LID window \(i) failed: \(error.localizedDescription)")
                continue
            }
            let probs = Self.softmaxFromLogProbs(result.langProbs)
            for (lang, p) in probs {
                accumulated[lang, default: 0] += p
            }
            counted += 1
        }
        guard counted > 0 else { return [:] }
        // Arithmetic mean across windows.
        for key in accumulated.keys {
            accumulated[key, default: 0] /= Double(counted)
        }
        return accumulated
    }

    /// Convert WhisperKit's log-prob map into a normalized probability map.
    /// WhisperKit returns the sampler's `logProbs` (filtered logits -> log softmax),
    /// so exp() is a decent per-token probability; we then renormalize across the
    /// reported candidates so the map sums to 1 for stable mean aggregation.
    static func softmaxFromLogProbs(_ logProbs: [String: Float]) -> [String: Double] {
        guard !logProbs.isEmpty else { return [:] }
        // Numerical stability: subtract max before exp.
        let maxLog = logProbs.values.max() ?? 0
        var exped: [String: Double] = [:]
        var sum = 0.0
        for (lang, lp) in logProbs {
            let v = exp(Double(lp - maxLog))
            exped[lang] = v
            sum += v
        }
        guard sum > 0 else { return [:] }
        for key in exped.keys { exped[key, default: 0] /= sum }
        return exped
    }

    // MARK: - Layer 3: session memory logic

    /// Anti-flap: if there is a session-preferred language and the candidate is
    /// different, require TWO consecutive utterances at prob >= 0.85 AND
    /// margin >= 0.25 before switching away (per spec). A single strong
    /// utterance sets a pending candidate; the next accepted utterance confirms
    /// or invalidates it. Any non-confirming event (abstain, lowAuto, a
    /// different strong candidate, or a candidate that fails the switch bar)
    /// resets the pending state.
    private func resolveAntiFlap(candidate: String, topProb: Double, margin: Double) -> String {
        guard let preferred = memory.sessionPreferred,
              LanguageTypes.isSupported(preferred),
              preferred != candidate else {
            // No preferred, or candidate is the preferred: no anti-flap logic needed.
            pendingSwitchCandidate = nil
            return candidate
        }
        let switchProb = 0.85
        let meetsSwitchBar = topProb >= switchProb
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

    // MARK: - Classification

    enum Decision: Equatable { case abstain, lowAuto, mediumAuto, highAuto }

    func classify(topProb: Double, margin: Double, voicedDuration: TimeInterval) -> Decision {
        // Short clip: apply strict bar; below it, abstain entirely.
        if voicedDuration < LanguageDetectorThresholds.confidentMinSec {
            if topProb >= LanguageDetectorThresholds.strictProb,
               margin >= LanguageDetectorThresholds.strictMargin {
                return .highAuto
            }
            // Per spec: stricter thresholds failed -> abstain (fall back to sticky).
            return .abstain
        }
        // Normal clip (>= 2.5s voiced).
        if topProb >= LanguageDetectorThresholds.highProb,
           margin >= LanguageDetectorThresholds.highMargin {
            return .highAuto
        }
        if topProb >= LanguageDetectorThresholds.normalProb,
           margin >= LanguageDetectorThresholds.normalMargin {
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
              var decoded = try? JSONDecoder().decode(SessionLanguageMemory.self, from: data) else {
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
