import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR

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
      voicedDuration: 0.1,  // even below short-clip gate
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
    let latin = ["en", "de", "fr", "es", "pt", "tr", "vi", "id", "sw", "nl"]
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

  @Test("Unsegmented script: CJK/Thai/Lao use char count, whitespace langs do not")
  func unsegmentedScriptClassification() {
    // CJK + Southeast Asian non-whitespace-segmented scripts.
    for code in ["ja", "zh", "yue", "th", "lo", "my", "km"] {
      #expect(LanguageTypes.isUnsegmentedScript(code), "expected unsegmented: \(code)")
    }
    // Scripts that DO whitespace-segment and must stay on the word-count
    // path: Korean (Eojeol-spaced), Indic, Arabic, Hebrew, Cyrillic.
    for code in ["ko", "hi", "gu", "ta", "te", "mr", "bn", "ar", "he", "ru", "uk"] {
      #expect(!LanguageTypes.isUnsegmentedScript(code), "expected segmented: \(code)")
    }
    // Latin too.
    for code in ["en", "es", "fr", "de"] {
      #expect(!LanguageTypes.isUnsegmentedScript(code))
    }
    // Case-insensitive.
    #expect(LanguageTypes.isUnsegmentedScript("JA"))
    #expect(LanguageTypes.isUnsegmentedScript("Zh"))
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
        sessionPreferred: "xx",  // not in Whisper's 99
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

  // MARK: - Passive chip

  @Test("Passive chip fires on LID flip-flop within 5 minutes")
  func passiveChipFlipFlop() async {
    let clock = TestClock()
    actor Collector {
      var triggers: [PassiveChipTrigger] = []
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

  // MARK: - Issue #252: consistentHighConfidence chip emit

  /// Helper to fan out a chip-trigger collector across the actor boundary.
  private actor ChipCollector {
    var triggers: [PassiveChipTrigger] = []
    func add(_ t: PassiveChipTrigger) { triggers.append(t) }
    func consistent() -> [PassiveChipTrigger] {
      triggers.filter { $0.reason == .consistentHighConfidence }
    }
  }

  /// Drive a high-confidence-non-English accept (probability >= 0.85, margin >=
  /// 0.25) into evaluateForTesting. Returns the result.
  private func acceptOnce(
    _ det: LanguageDetector, lang: String, confidence: Double = 0.92
  ) async -> LanguageDetectionResult {
    let competitor = max(0.0, confidence - 0.40)
    return await det.evaluateForTesting(
      windowProbs: [lang: confidence, "xx": competitor],
      voicedDuration: 4.0)
  }

  @Test("Consistent chip fires after 3 same-lang high-conf accepts of non-English")
  func consistentChipFiresAtThreeStrikes() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    _ = await acceptOnce(det, lang: "es")
    _ = await acceptOnce(det, lang: "es")
    var fired = await collector.consistent()
    #expect(fired.isEmpty, "Should not fire before 3 accepts")
    _ = await acceptOnce(det, lang: "es")
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    fired = await collector.consistent()
    #expect(fired.count == 1, "Should fire once at exactly N=3")
    #expect(fired.first?.lang == "es")
  }

  @Test("English accepts never fire the consistent chip")
  func consistentChipNeverForEnglish() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    for _ in 0..<5 {
      _ = await acceptOnce(det, lang: "en")
    }
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let fired = await collector.consistent()
    #expect(fired.isEmpty, "English must never trip the chip counter")
  }

  @Test("Non-English accept resets OTHER non-English counters")
  func consistentChipResetsOtherLangs() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    // ES, FR, ES, ES: should NOT fire because FR resets ES counter.
    // After this sequence: counts = ["es": 2] (started fresh after FR, only 2 ES).
    // We avoid 2 consecutive ES at start (which would elevate sessionPreferred
    // and cause anti-flap to reject FR — masking the reset behavior we want
    // to test). Instead interleave so sessionPreferred never sticks.
    _ = await acceptOnce(det, lang: "es")
    _ = await acceptOnce(det, lang: "fr")  // resets es counter to 0 (replaced)
    _ = await acceptOnce(det, lang: "es")  // counter=es:1
    _ = await acceptOnce(det, lang: "es")  // counter=es:2
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let fired = await collector.consistent()
    #expect(fired.isEmpty, "FR reset ES counter; only 2 ES strikes after — no fire")
  }

  @Test("English between non-English accepts does NOT reset the counter")
  func consistentChipEnglishIsNoOp() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    _ = await acceptOnce(det, lang: "es")
    _ = await acceptOnce(det, lang: "en")  // English no-op
    _ = await acceptOnce(det, lang: "es")
    _ = await acceptOnce(det, lang: "en")
    _ = await acceptOnce(det, lang: "es")
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let fired = await collector.consistent()
    #expect(fired.count == 1, "ES streak survives English interleave (F4)")
    #expect(fired.first?.lang == "es")
  }

  @Test("Counter resets to 0 after emit (does not re-fire on next accept)")
  func consistentChipResetsAfterEmit() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    for _ in 0..<3 {
      _ = await acceptOnce(det, lang: "es")
    }
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    var fired = await collector.consistent()
    #expect(fired.count == 1)
    // One more accept — should NOT fire again (counter reset to 0 after emit).
    _ = await acceptOnce(det, lang: "es")
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    fired = await collector.consistent()
    #expect(fired.count == 1, "Counter must reset; no immediate re-emit")
  }

  @Test("Confidence below 0.85 does not increment counter")
  func consistentChipConfidenceFloorEnforced() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    // 0.84 confidence — mediumAuto-level. Should NOT increment chip counter.
    for _ in 0..<5 {
      _ = await acceptOnce(det, lang: "es", confidence: 0.84)
    }
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let fired = await collector.consistent()
    #expect(fired.isEmpty, "Confidence < 0.85 must not advance chip counter")
  }

  @Test("Variant-coded English (en-US) does not fire chip")
  func consistentChipEnglishVariantNoOp() async {
    let collector = ChipCollector()
    let det = LanguageDetector(
      clock: TestClock(), defaults: makeEphemeralDefaults()
    ) { trigger in
      Task { await collector.add(trigger) }
    }
    // evaluateForTesting normalizes via the detector's own path which lowercases
    // but does NOT strip variant. The new evaluateConsistentChipForAccept uses
    // a hasPrefix-style normalization on finalLang, so en-US should be treated
    // as English. NOTE: the detector's normalizeLangCode only lowercases; the
    // variant comes through as "en-us". The new chip helper strips it.
    for _ in 0..<5 {
      _ = await acceptOnce(det, lang: "en-us")
    }
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let fired = await collector.consistent()
    #expect(fired.isEmpty, "en-us must normalize to en and be a no-op")
  }
}
