import Foundation
import Testing
@testable import EnviousWisprASR
import EnviousWisprCore

// Mutable clock seam for deterministic tests of session timeout and flip-flop.
final class TestClock: LanguageDetectorClock, @unchecked Sendable {
    var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

// Per-test UserDefaults suite so tests do not cross-contaminate or pollute
// the real defaults domain.
func makeEphemeralDefaults(_ suite: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: suite)!
}

@Suite("LanguageDetector boundary logic")
struct LanguageDetectorTests {

    // MARK: - Duration gate

    @Test("Below 1.0s voiced: abstain, never call LID")
    func durationBelowShortGate() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let result = await det.evaluateForTesting(
            windowProbs: ["en": 0.99, "de": 0.01],
            voicedDuration: 0.5,
            mode: .auto
        )
        #expect(result.abstained)
        #expect(result.tier == .abstain)
        #expect(result.lang == nil)
    }

    @Test("Between 1.0 and 2.5s voiced: strict thresholds apply")
    func durationStrictWindow() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        // 0.70/0.20 passes normal, fails strict => abstain on short clip.
        let mid = await det.evaluateForTesting(
            windowProbs: ["en": 0.70, "de": 0.50],
            voicedDuration: 1.5,
            mode: .auto
        )
        #expect(mid.tier == .abstain)
        #expect(mid.abstained)
    }

    @Test("Between 1.0 and 2.5s: high-confidence lang passes strict")
    func strictPassesAtHighConfidence() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let ok = await det.evaluateForTesting(
            windowProbs: ["en": 0.90, "de": 0.60],
            voicedDuration: 1.5,
            mode: .auto
        )
        #expect(ok.tier == .highAuto)
        #expect(ok.lang == "en")
    }

    // MARK: - Normal thresholds

    @Test("Normal clip: below 0.65 prob => lowAuto (accepted but unlexiconed)")
    func lowAutoTier() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let r = await det.evaluateForTesting(
            windowProbs: ["en": 0.50, "de": 0.30, "fr": 0.20],
            voicedDuration: 4.0,
            mode: .auto
        )
        #expect(r.tier == .lowAuto)
        #expect(r.lang == "en")
    }

    @Test("Normal clip: 0.65/0.20 boundary is mediumAuto")
    func mediumAutoBoundary() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let r = await det.evaluateForTesting(
            windowProbs: ["en": 0.65, "de": 0.45],
            voicedDuration: 4.0,
            mode: .auto
        )
        #expect(r.tier == .mediumAuto)
        #expect(r.lang == "en")
    }

    @Test("Normal clip: margin below 0.20 drops to lowAuto")
    func marginGate() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let r = await det.evaluateForTesting(
            windowProbs: ["en": 0.65, "de": 0.60],
            voicedDuration: 4.0,
            mode: .auto
        )
        #expect(r.tier == .lowAuto)
    }

    @Test("Normal clip: 0.80/0.25 => highAuto")
    func highAuto() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let r = await det.evaluateForTesting(
            windowProbs: ["en": 0.85, "de": 0.55],
            voicedDuration: 4.0,
            mode: .auto
        )
        #expect(r.tier == .highAuto)
        #expect(r.lang == "en")
    }

    // MARK: - Locked mode

    @Test("Locked mode: short-circuit to .locked tier")
    func lockedShortCircuit() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let r = await det.evaluateForTesting(
            windowProbs: ["fr": 0.99],
            voicedDuration: 0.1,            // even below short-clip gate
            mode: .locked("ja")
        )
        #expect(r.tier == .locked)
        #expect(r.lang == "ja")
        #expect(!r.abstained)
    }

    @Test("Locked mode normalizes to lowercase")
    func lockedNormalizes() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        let r = await det.evaluateForTesting(
            windowProbs: [:],
            voicedDuration: 3.0,
            mode: .locked("ZH")
        )
        #expect(r.lang == "zh")
        #expect(r.tier == .locked)
    }

    // MARK: - Session memory / anti-flap

    @Test("Two consecutive high-confidence accepts elevate sessionPreferred")
    func sessionElevation() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        _ = await det.evaluateForTesting(
            windowProbs: ["de": 0.90, "en": 0.50],
            voicedDuration: 4.0
        )
        _ = await det.evaluateForTesting(
            windowProbs: ["de": 0.88, "en": 0.40],
            voicedDuration: 4.0
        )
        let mem = await det.peekMemory()
        #expect(mem.sessionPreferred == "de")
    }

    @Test("Anti-flap: switch away requires prob >= 0.85 AND margin >= 0.25")
    func antiFlapBlocksWeakSwitch() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        // Elevate 'de' as sessionPreferred.
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0)
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0)
        #expect(await det.peekMemory().sessionPreferred == "de")

        // mediumAuto-level 'en' should NOT flip sessionPreferred.
        let r = await det.evaluateForTesting(
            windowProbs: ["en": 0.70, "de": 0.45],
            voicedDuration: 4.0
        )
        #expect(r.lang == "de")
        #expect(r.usedSessionPrior)
    }

    @Test("Anti-flap: one strong utterance alone does NOT switch (pending)")
    func antiFlapOneStrongDoesNotSwitch() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        // Elevate 'de' as sessionPreferred.
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0)
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0)
        // First strong 'fr' utterance: must NOT flip preferred yet (pending).
        let r = await det.evaluateForTesting(
            windowProbs: ["fr": 0.90, "de": 0.40],
            voicedDuration: 4.0
        )
        #expect(r.lang == "de")
        #expect(r.usedSessionPrior)
    }

    @Test("Anti-flap: two consecutive strong utterances commit the switch")
    func antiFlapTwoConsecutiveStrongSwitches() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0)
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0)
        // First strong 'fr': pending, preferred still 'de'.
        _ = await det.evaluateForTesting(windowProbs: ["fr": 0.90, "de": 0.40], voicedDuration: 4.0)
        // Second consecutive strong 'fr': commits the switch.
        let r = await det.evaluateForTesting(
            windowProbs: ["fr": 0.91, "de": 0.35],
            voicedDuration: 4.0
        )
        #expect(r.lang == "fr")
        #expect(r.tier == .highAuto)
    }

    @Test("Anti-flap: intervening weak utterance resets pending switch")
    func antiFlapResetsOnInterruption() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0)
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0)
        // First strong 'fr' (pending).
        _ = await det.evaluateForTesting(windowProbs: ["fr": 0.90, "de": 0.40], voicedDuration: 4.0)
        // Low-confidence utterance breaks the chain (pending cleared).
        _ = await det.evaluateForTesting(windowProbs: ["en": 0.50, "de": 0.45], voicedDuration: 4.0)
        // Another strong 'fr' should now be pending again, NOT commit switch.
        let r = await det.evaluateForTesting(
            windowProbs: ["fr": 0.91, "de": 0.35],
            voicedDuration: 4.0
        )
        #expect(r.lang == "de")
        #expect(r.usedSessionPrior)
    }

    @Test("10-minute inactivity clears sessionPreferred")
    func sessionInactivityTimeout() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.92, "en": 0.40], voicedDuration: 4.0)
        _ = await det.evaluateForTesting(windowProbs: ["de": 0.90, "en": 0.45], voicedDuration: 4.0)
        #expect(await det.peekMemory().sessionPreferred == "de")

        clock.advance(601)  // 10 min + 1s
        _ = await det.evaluateForTesting(windowProbs: [:], voicedDuration: 0.5)
        #expect(await det.peekMemory().sessionPreferred == nil)
    }

    @Test("Session prior boosts low-confidence decision toward preferred lang")
    func sessionPriorBoost() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        // Seed sessionPreferred = "en" without depending on the elevation path.
        await det.setMemoryForTesting(
            SessionLanguageMemory(
                accepted: [
                    .init(lang: "en", confidence: 0.9, timestamp: clock.now()),
                    .init(lang: "en", confidence: 0.88, timestamp: clock.now()),
                ],
                sessionPreferred: "en",
                usage24h: [:],
                lastActivity: clock.now()
            )
        )
        // Raw: top=en prob=0.56 margin=0.16 -> lowAuto. With +0.10 session-prior
        // boost on en (preferred), en=0.66 margin=0.26 -> promoted to mediumAuto.
        let r = await det.evaluateForTesting(
            windowProbs: ["de": 0.40, "en": 0.56],
            voicedDuration: 4.0
        )
        #expect(r.lang == "en")
        #expect(r.tier == .mediumAuto)
        #expect(r.usedSessionPrior)
    }

    // MARK: - Script guardrail classification

    @Test("Script guardrail: isNonLatinScript maps correctly")
    func scriptGuardrailClassification() {
        let nonLatin = ["ja", "zh", "ko", "hi", "ta", "ar", "he", "ru", "uk", "yue"]
        let latin    = ["en", "de", "fr", "es", "pt", "tr", "vi", "id", "sw", "nl"]
        for code in nonLatin {
            #expect(LanguageTypes.isNonLatinScript(code), "expected non-Latin: \(code)")
        }
        for code in latin {
            #expect(!LanguageTypes.isNonLatinScript(code), "expected Latin: \(code)")
        }
        // Case-insensitive.
        #expect(LanguageTypes.isNonLatinScript("JA"))
    }

    @Test("Script guardrail: unknown code treated as Latin (conservative default)")
    func scriptGuardrailUnknown() {
        #expect(!LanguageTypes.isNonLatinScript("xx"))
        #expect(!LanguageTypes.isNonLatinScript(""))
    }

    // MARK: - Whisper-supported set

    @Test("whisperSupportedLanguages matches the spec roster size")
    func whisperSupportedSize() {
        // Spec claims 99 but enumerates 100 codes verbatim (includes both 'jw'
        // and Whisper's full set). We track the enumerated list, not the marketing
        // number, and flag future drift.
        #expect(LanguageTypes.whisperSupportedLanguages.count == 100)
        #expect(LanguageTypes.isSupported("en"))
        #expect(LanguageTypes.isSupported("yue"))
        #expect(!LanguageTypes.isSupported("xx"))
    }

    // MARK: - Defensive: stale persisted lang

    @Test("Stale (unsupported) sessionPreferred is ignored, not crashed")
    func stalePersistedLangIgnored() async {
        let clock = TestClock()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults())
        await det.setMemoryForTesting(
            SessionLanguageMemory(
                accepted: [],
                sessionPreferred: "xx",        // not in Whisper's 99
                usage24h: [:],
                lastActivity: clock.now()
            )
        )
        let r = await det.evaluateForTesting(
            windowProbs: ["en": 0.70, "de": 0.45],
            voicedDuration: 4.0
        )
        #expect(r.lang == "en")
        #expect(!r.usedSessionPrior)
    }

    // MARK: - LanguageMode codable round-trip

    @Test("LanguageMode Codable round-trip")
    func languageModeCodable() throws {
        let auto: LanguageMode = .auto
        let locked: LanguageMode = .locked("ja")
        let encA = try JSONEncoder().encode(auto)
        let encL = try JSONEncoder().encode(locked)
        let decA = try JSONDecoder().decode(LanguageMode.self, from: encA)
        let decL = try JSONDecoder().decode(LanguageMode.self, from: encL)
        #expect(decA == .auto)
        #expect(decL == .locked("ja"))
    }

    // MARK: - Softmax helper

    @Test("softmaxFromLogProbs normalizes to sum=1 and preserves ordering")
    func softmaxHelper() {
        let logProbs: [String: Float] = ["en": -0.2, "de": -2.0, "fr": -4.0]
        let probs = LanguageDetector.softmaxFromLogProbs(logProbs)
        let sum = probs.values.reduce(0, +)
        #expect(abs(sum - 1.0) < 1e-6)
        #expect((probs["en"] ?? 0) > (probs["de"] ?? 0))
        #expect((probs["de"] ?? 0) > (probs["fr"] ?? 0))
    }

    @Test("softmaxFromLogProbs on empty map returns empty")
    func softmaxEmpty() {
        #expect(LanguageDetector.softmaxFromLogProbs([:]).isEmpty)
    }

    // MARK: - Passive chip

    @Test("Passive chip fires on LID flip-flop within 5 minutes")
    func passiveChipFlipFlop() async {
        let clock = TestClock()
        actor Collector { var triggers: [PassiveChipTrigger] = []
            func add(_ t: PassiveChipTrigger) { triggers.append(t) }
            func all() -> [PassiveChipTrigger] { triggers }
        }
        let collector = Collector()
        let det = LanguageDetector(clock: clock, defaults: makeEphemeralDefaults()) { trigger in
            Task { await collector.add(trigger) }
        }
        // First accept: en.
        _ = await det.evaluateForTesting(windowProbs: ["en": 0.90, "de": 0.40], voicedDuration: 4.0)
        // Second accept, different lang within the window. Use strong bar to
        // beat anti-flap in case 'en' was elevated.
        _ = await det.evaluateForTesting(windowProbs: ["fr": 0.90, "en": 0.40], voicedDuration: 4.0)
        // Yield to let the Task-delivered trigger land.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let triggers = await collector.all()
        #expect(triggers.contains { $0.reason == .lidFlipFlop })
    }
}
