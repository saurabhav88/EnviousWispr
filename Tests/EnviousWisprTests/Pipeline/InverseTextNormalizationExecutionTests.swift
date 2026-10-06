import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing
import os

@testable import EnviousWisprPipeline

// MARK: - Route execution, snapshotting and deadline (#1677, chunk 3)
//
// What the wired step does with the route chunk 2 selects. The production registry is EMPTY, so every
// language-route case here injects its own immutable registry through the package seam; nothing in
// production can reach `.language` yet.
//
// EVIDENCE BOUNDARY: the injected "language pass" below is a test-only stand-in. These tests prove
// ordering (neutral work is visible to the language pass), snapshotting, the single shared deadline,
// outcome semantics and fail-closed behaviour. They prove NOTHING about linguistic rules; real
// passes arrive in a later PR.

@MainActor
@Suite("ITN route execution (#1677)", .tags(.productOutcome))
struct InverseTextNormalizationExecutionTests {

  private typealias Gate = InverseTextNormalizationGate

  private nonisolated static let germanInput = "Frage B Bindestrich 2, Code zwei null drei"
  private nonisolated static let germanNeutral = "Frage B-2, Code zwei null drei"
  private nonisolated static let marker = "|TEST-LANGUAGE-PASS"

  private func ctx(_ text: String, language: String?, vetoed: Bool = false) -> TextProcessingContext
  {
    var c = TextProcessingContext(text: text, language: language)
    c.englishRulesVetoed = vetoed
    return c
  }

  private func registry(_ languages: String...) -> LanguageRuleRegistry {
    try! LanguageRuleRegistry(languages.compactMap { LanguageRuleSet(language: $0) })
  }

  /// Work that never finishes inside the budget: the deadline itself is under test. Cancellable, so
  /// it releases its executor when the timeout branch cancels the operation.
  private nonisolated static func slowWork(_ text: String, _ spoken: Bool) async -> String {
    try? await Task.sleep(for: .seconds(3))  // test-fixture-timer: the deadline itself is under test
    return "LATE:" + text
  }

  // MARK: Shared execution and the public facade

  @Test("the facade runs the English engine for .english and the neutral subset for .neutral")
  func facadeMatchesTheEngines() {
    let engine = InverseTextNormalizer()
    #expect(
      Gate.normalize(
        "the code is two zero three", route: .english, normalizer: engine, spokenPunctuation: false)
        == "the code is 203")
    #expect(
      Gate.normalize(
        Self.germanInput, route: .neutral("non_english"), normalizer: engine,
        spokenPunctuation: false) == Self.germanNeutral)
  }

  @Test("a language route with no vetted snapshot fails closed to neutral, never to English")
  func missingOrForgedSnapshotFailsClosed() {
    let engine = InverseTextNormalizer()
    let german = "Ruf mich bitte um 7 am Abend an. " + Self.germanInput
    let neutralExpected = "Ruf mich bitte um 7 am Abend an. " + Self.germanNeutral
    // Public facade: the production registry is empty, so a `.language` route has no snapshot.
    let viaFacade = Gate.normalize(
      german, route: .language("de"), normalizer: engine, spokenPunctuation: false)
    #expect(viaFacade == neutralExpected)
    // Shared execution: a missing snapshot, and a snapshot for a DIFFERENT language.
    let fr = LanguageRuleSet(language: "fr")!
    for rules in [nil, fr] as [LanguageRuleSet?] {
      let out = Gate.execute(
        german, route: .language("de"), rules: rules, normalizer: engine, spokenPunctuation: false)
      #expect(out == neutralExpected)
    }
    #expect(viaFacade.contains("7:00 AM") == false, "the English time rule must never run")
  }

  // MARK: Ordering, snapshot and outcome through process

  @Test(
    "neutral work is visible to the language pass, its output reaches process, and the outcome says admitted"
  )
  func languageRouteOrderingAndOutcome() async throws {
    let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    let routeBox = OSAllocatedUnfairLock<Gate.Route?>(initialState: nil)
    let codeBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    let step = InverseTextNormalizationStep(
      registry: registry("de"),
      workFactory: { route, rules in
        routeBox.withLock { $0 = route }
        codeBox.withLock { $0 = rules?.baseCode }
        let engine = InverseTextNormalizer()
        return { text, spoken in
          let neutral = Gate.execute(
            text, route: route, rules: rules, normalizer: engine, spokenPunctuation: spoken)
          seen.withLock { $0.append(neutral) }
          return neutral + Self.marker
        }
      })
    step.backendSupportsLID = true
    let out = try await step.process(ctx(Self.germanInput, language: "de-DE"))
    #expect(out.text == Self.germanNeutral + Self.marker)
    #expect(seen.withLock { $0 } == [Self.germanNeutral], "the pass saw the NEUTRAL output")
    #expect(routeBox.withLock { $0 } == .language("de"))
    #expect(codeBox.withLock { $0 } == "de", "the factory received the matching snapshot")
    #expect(step.lastRun?.ran == true)
    #expect(step.lastRun?.skipReason == nil)
    #expect(step.lastRun?.changed == true)
  }

  @Test("an unregistered or vetoed language never reaches the language route")
  func injectedRegistryStillFallsBackToNeutral() async throws {
    for (language, vetoed, reason) in [
      ("es", false, "non_english"), ("de", true, "language_vetoed"),
    ] {
      let routeBox = OSAllocatedUnfairLock<Gate.Route?>(initialState: nil)
      let step = InverseTextNormalizationStep(
        registry: registry("de"),
        workFactory: { route, rules in
          routeBox.withLock { $0 = route }
          let engine = InverseTextNormalizer()
          return { text, spoken in
            Gate.execute(
              text, route: route, rules: rules, normalizer: engine, spokenPunctuation: spoken)
          }
        })
      step.backendSupportsLID = true
      let out = try await step.process(ctx(Self.germanInput, language: language, vetoed: vetoed))
      #expect(out.text == Self.germanNeutral, "\(language) vetoed=\(vetoed)")
      #expect(routeBox.withLock { $0 } == .neutral(reason))
      #expect(step.lastRun?.ran == false)
      #expect(step.lastRun?.skipReason == reason)
    }
  }

  // MARK: One shared deadline

  @Test("a language route that times out after its neutral work returns the ORIGINAL input")
  func languageTimeoutKeepsTheWholeInput() async throws {
    #expect(Self.germanNeutral != Self.germanInput, "fixture: neutral work must be visible")
    let partialOutputs = OSAllocatedUnfairLock<[String]>(initialState: [])
    var timeouts: [[String: Any]] = []
    let step = InverseTextNormalizationStep(
      registry: registry("de"),
      workFactory: { route, rules in
        let engine = InverseTextNormalizer()
        return { text, spoken in
          // Neutral work completes (and would visibly change the text) BEFORE the stall.
          let partial = Gate.execute(
            text, route: route, rules: rules, normalizer: engine, spokenPunctuation: spoken)
          partialOutputs.withLock { $0.append(partial) }
          _ = await Self.slowWork(partial, spoken)
          return partial + Self.marker
        }
      },
      onTimeoutForTesting: { timeouts.append($0) })
    step.backendSupportsLID = true
    let out = try await step.process(ctx(Self.germanInput, language: "de"))
    #expect(
      partialOutputs.withLock { $0 } == [Self.germanNeutral],
      "neutral conversion must complete before the language-phase stall")
    #expect(out.text == Self.germanInput, "never partial neutral or language output")
    #expect(timeouts.count == 1)
    let extra = try #require(timeouts.first)
    #expect(extra["route"] as? String == "language:de")
    #expect(step.lastRun?.ran == true, "admitted to the language route")
    #expect(step.lastRun?.changed == false)
    #expect(step.lastRun?.skipReason == nil)
    #expect(step.lastRun?.lenAfter == Self.germanInput.count)
  }

  @Test("neutral and English timeouts keep the input and name their route")
  func neutralAndEnglishTimeoutClassification() async throws {
    let cases:
      [(label: String, language: String?, vetoed: Bool, route: String, ran: Bool, reason: String?)] =
        [
          ("neutral non_english", "de", false, "neutral", false, "non_english"),
          ("neutral vetoed", nil, true, "neutral", false, "language_vetoed"),
          ("english", "en", false, "english", true, nil),
        ]
    for c in cases {
      var timeouts: [[String: Any]] = []
      let step = InverseTextNormalizationStep(
        work: Self.slowWork, onTimeoutForTesting: { timeouts.append($0) })
      step.backendSupportsLID = true
      let out = try await step.process(
        ctx(Self.germanInput, language: c.language, vetoed: c.vetoed))
      #expect(out.text == Self.germanInput, "\(c.label)")
      #expect(timeouts.count == 1, "\(c.label): exactly one breadcrumb")
      #expect(timeouts.first?["route"] as? String == c.route, "\(c.label)")
      #expect(step.lastRun?.ran == c.ran, "\(c.label)")
      #expect(step.lastRun?.skipReason == c.reason, "\(c.label)")
      #expect(step.lastRun?.changed == false, "\(c.label)")
    }
  }

  // MARK: The work seam

  @Test("a caller-supplied work replaces the whole operation on every route")
  func workOverrideRunsOnEveryRoute() async throws {
    let cases: [(String?, Bool)] = [("en", false), ("de", false), (nil, true)]
    for (language, vetoed) in cases {
      let calls = OSAllocatedUnfairLock<Int>(initialState: 0)
      let step = InverseTextNormalizationStep(work: { text, _ in
        calls.withLock { $0 += 1 }
        return "OVERRIDE:" + text
      })
      step.backendSupportsLID = true
      let out = try await step.process(ctx("hello there", language: language, vetoed: vetoed))
      #expect(out.text == "OVERRIDE:hello there", "\(language ?? "nil") vetoed=\(vetoed)")
      #expect(calls.withLock { $0 } == 1)
    }
  }

  @Test("the prepared language snapshot and punctuation survive a staged settings change")
  func snapshotSurvivesAStagedSettingChange() async throws {
    let (entered, enteredSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingOldest(1))
    let (release, releaseSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingOldest(1))
    defer {
      enteredSignal.finish()
      releaseSignal.finish()
    }

    let received = OSAllocatedUnfairLock<
      (route: Gate.Route?, code: String?, spoken: Bool?)
    >(initialState: (nil, nil, nil))
    var timeouts: [[String: Any]] = []

    let step = InverseTextNormalizationStep(
      registry: registry("de"),
      workFactory: { route, rules in
        let engine = InverseTextNormalizer()
        return { text, spoken in
          received.withLock {
            $0 = (route: route, code: rules?.baseCode, spoken: spoken)
          }
          enteredSignal.yield()
          for await _ in release { break }
          return Gate.execute(
            text, route: route, rules: rules, normalizer: engine,
            spokenPunctuation: spoken)
        }
      },
      onTimeoutForTesting: { timeouts.append($0) })

    step.spokenPunctuation = SpokenPunctuationSettings(enabled: true, startWordOverrides: [:])
    step.backendSupportsLID = false
    let context = ctx(Self.germanInput, language: "de-DE")
    let task = Task { @MainActor in try await step.process(context) }
    defer { task.cancel() }

    // deadline-fallback: bound a missing work-entry signal, not normalization latency.
    let enteredInTime = await withDeadline(seconds: 5) {
      var iterator = entered.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(enteredInTime == true, "normalization work never entered")

    step.spokenPunctuation = SpokenPunctuationSettings(enabled: false, startWordOverrides: [:])  // a settings toggle lands mid-run
    step.backendSupportsLID = true
    releaseSignal.yield()

    let out = try await task.value
    let snapshot = received.withLock { $0 }
    #expect(snapshot.route == .language("de"))
    #expect(snapshot.code == "de")
    #expect(snapshot.spoken == true)
    #expect(out.text == Self.germanNeutral)
    #expect(step.lastRun?.ran == true)
    #expect(step.lastRun?.skipReason == nil)
    #expect(timeouts.isEmpty, "the staged success case must not pass through timeout")
  }
}
