import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #2450: which takes the start-word spoken-punctuation pass runs on, and what the cleanup step reports
/// about it.
///
/// **Product Outcome.** When these fail a German, French, Spanish or Italian speaker's command is
/// ignored or applied to the wrong take, an English speaker's dictation changes, a hung pass shows the
/// user partly-cleaned text, or a snippet the user saved is damaged. Expectations are literal.
///
/// The real-chain rows drive each step's `process` in the production order from `LimbSteps.orderedChain`
/// and deliberately NOT through the runner: the runner skips a step that misses its wall-clock budget,
/// which makes a chain-level assertion load-dependent (the same reasoning `SnippetChainPlacementTests`
/// records).
@MainActor
@Suite("Spoken punctuation routing (#2450)", .tags(.productOutcome))
struct SpokenPunctuationRoutingTests {

  private static let on = SpokenPunctuationSettings(enabled: true, startWordOverrides: [:])
  private static let off = SpokenPunctuationSettings.off

  private func ctx(
    _ text: String, language: String?, vetoed: Bool = false,
    source: DictationLanguageResolver.Resolution.Source? = nil
  ) -> TextProcessingContext {
    var context = TextProcessingContext(text: text, language: language)
    context.englishRulesVetoed = vetoed
    context.languageSource = source
    return context
  }

  private func step(
    _ settings: SpokenPunctuationSettings, lid: Bool = true
  ) -> InverseTextNormalizationStep {
    let step = InverseTextNormalizationStep()
    step.spokenPunctuation = settings
    step.backendSupportsLID = lid
    return step
  }

  // MARK: - The routing table, as one pure function

  @Test(
    "A take that is not attempted reports why",
    arguments: [
      // (switch on, veto, language, expected status)
      (false, false, "de" as String?, SpokenPunctuationStatus.disabled),
      (false, true, "de", .disabled),
      (false, false, nil, .disabled),
      (true, true, "de", .unresolved),
      (true, false, nil, .unresolved),
      (true, false, "", .unresolved),
      (true, false, "und", .unresolved),
      (true, false, "nl", .unsupported),
      (true, false, "pl", .unsupported),
      (true, false, "en", .unsupported),
    ])
  func notAttempted(
    enabled: Bool, vetoed: Bool, language: String?, expected: SpokenPunctuationStatus
  ) {
    let plan = InverseTextNormalizationStep.punctuationPlan(
      language: language, englishVetoed: vetoed,
      settings: SpokenPunctuationSettings(enabled: enabled, startWordOverrides: [:]))
    #expect(plan.attemptLanguage == nil)
    #expect(plan.startWord == nil)
    #expect(plan.notAttemptedStatus == expected)
  }

  @Test(
    "An eligible take is attempted under its base language and that language's default word",
    arguments: [
      ("de", "de", "Setze"), ("de-DE", "de", "Setze"), ("DE", "de", "Setze"),
      ("fr", "fr", "Insère"), ("fr_FR", "fr", "Insère"),
      ("es", "es", "Pon"), ("es-419", "es", "Pon"), ("it", "it", "Metti"),
    ])
  func eligible(language: String, base: String, word: String) {
    let plan = InverseTextNormalizationStep.punctuationPlan(
      language: language, englishVetoed: false, settings: Self.on)
    #expect(plan.attemptLanguage == base)
    #expect(plan.startWord == word)
    #expect(plan.notAttemptedStatus == nil)
  }

  @Test("A valid override is the word that is matched")
  func overrideIsUsed() {
    let settings = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Diktiere"])
    #expect(
      InverseTextNormalizationStep.punctuationPlan(
        language: "de", englishVetoed: false, settings: settings
      ).startWord == "Diktiere")
    #expect(
      InverseTextNormalizationStep.punctuationPlan(
        language: "fr", englishVetoed: false, settings: settings
      ).startWord == "Insère", "another language keeps its default")
  }

  @Test(
    "An invalid override never widens matching: the default word is used instead",
    arguments: ["Punkt", "zwei Worte", "", "set3", "x", String(repeating: "a", count: 21)])
  func invalidOverrideFallsBackToTheDefault(word: String) {
    let settings = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": word])
    let plan = InverseTextNormalizationStep.punctuationPlan(
      language: "de", englishVetoed: false, settings: settings)
    #expect(plan.attemptLanguage == "de")
    #expect(plan.startWord == "Setze")
  }

  @Test("The status vocabulary is closed and spelled as it is queried")
  func statusVocabulary() {
    #expect(
      Set(SpokenPunctuationStatus.allCases.map(\.rawValue)) == [
        "disabled", "unresolved", "unsupported", "ran_no_match", "rewrote", "timed_out",
      ])
  }

  @Test("Not attempted, matched nothing and abandoned stay three different answers")
  func outcomeMatrix() {
    let attempted = PunctuationPlan(
      attemptLanguage: "de", startWord: "Setze", notAttemptedStatus: nil)
    let skipped = PunctuationPlan(
      attemptLanguage: nil, startWord: nil, notAttemptedStatus: .unsupported)

    let notAttempted = InverseTextNormalizationStep.punctuationOutcome(
      plan: skipped, result: ITNWorkResult(text: "x", punctuationRulesFired: 3))
    #expect(notAttempted.status == .unsupported)
    #expect(notAttempted.rulesFired == nil)

    let none = InverseTextNormalizationStep.punctuationOutcome(
      plan: attempted, result: ITNWorkResult(text: "x", punctuationRulesFired: 0))
    #expect(none.status == .ranNoMatch)
    #expect(none.rulesFired == 0)

    let missing = InverseTextNormalizationStep.punctuationOutcome(
      plan: attempted, result: ITNWorkResult(text: "x", punctuationRulesFired: nil))
    #expect(missing.status == .ranNoMatch, "a pass that reported no count ran and matched nothing")
    #expect(missing.rulesFired == 0)

    let rewrote = InverseTextNormalizationStep.punctuationOutcome(
      plan: attempted, result: ITNWorkResult(text: "x", punctuationRulesFired: 2))
    #expect(rewrote.status == .rewrote)
    #expect(rewrote.rulesFired == 2)

    let abandoned = InverseTextNormalizationStep.punctuationOutcome(plan: attempted, result: nil)
    #expect(abandoned.status == .timedOut)
    #expect(abandoned.rulesFired == nil, "an abandoned run discards its count")

    let skippedAbandoned = InverseTextNormalizationStep.punctuationOutcome(
      plan: skipped, result: nil)
    #expect(skippedAbandoned.status == .unsupported, "no pass was attempted, so nothing timed out")
  }

  // MARK: - Through the step

  @Test("A German take with the switch on rewrites the command and reports it")
  func germanRewrites() async throws {
    let step = step(Self.on)
    let out = try await step.process(
      ctx("Das ist gut Setze Punkt es geht weiter", language: "de-DE", source: .dictation))
    #expect(out.text == "Das ist gut. Es geht weiter")
    let run = try #require(step.lastRun)
    #expect(run.ran == false)
    #expect(run.skipReason == "non_english")
    #expect(run.changed == true)
    #expect(run.punctuationStatus == .rewrote)
    #expect(run.punctuationRulesFired == 1)
    #expect(run.punctuationLanguage == "de", "the base code, from the resolved language")
    #expect(run.punctuationResolutionSource == "dictation", "read from the context, never re-resolved")
  }

  @Test("The neutral subset runs first, then the commands")
  func neutralThenPunctuation() async throws {
    let step = step(Self.on)
    let out = try await step.process(ctx("Frage B Bindestrich 2 Setze Punkt Code", language: "de"))
    #expect(out.text == "Frage B-2. Code")
    #expect(step.lastRun?.punctuationStatus == .rewrote)
  }

  @Test("With the switch off the neutral subset still runs and the command stays")
  func switchOffKeepsNeutralAndLeavesTheCommand() async throws {
    let step = step(Self.off)
    let out = try await step.process(ctx("Frage B Bindestrich 2 Setze Punkt Code", language: "de"))
    #expect(out.text == "Frage B-2 Setze Punkt Code")
    #expect(step.lastRun?.punctuationStatus == .disabled)
    #expect(step.lastRun?.punctuationRulesFired == nil)
  }

  @Test("A take with no command reports that it ran and matched nothing")
  func ranNoMatch() async throws {
    let step = step(Self.on)
    let input = "Das ist der springende Punkt und Punkt für Punkt"
    let out = try await step.process(ctx(input, language: "de"))
    #expect(out.text == input)
    #expect(step.lastRun?.punctuationStatus == .ranNoMatch)
    #expect(step.lastRun?.punctuationRulesFired == 0)
  }

  @Test(
    "Each language rewrites under its own word, and regional tags reach the same table",
    arguments: [
      ("fr", "c'est fini Insère point", "c'est fini."),
      ("es", "hola Pon coma adiós", "hola, adiós"),
      ("it", "ciao Metti punto interrogativo", "ciao?"),
      ("de-DE", "alpha Setze Fragezeichen", "alpha?"),
    ])
  func languages(language: String, input: String, expected: String) async throws {
    let step = step(Self.on)
    let out = try await step.process(ctx(input, language: language))
    #expect(out.text == expected)
    #expect(step.lastRun?.punctuationStatus == .rewrote)
  }

  @Test("A language with no table is reported unsupported and never given another table")
  func unsupportedLanguage() async throws {
    let step = step(Self.on)
    let input = "Dit is goed Setze Punkt maar period"
    let out = try await step.process(ctx(input, language: "nl", source: .engine))
    #expect(out.text == input)
    #expect(step.lastRun?.punctuationStatus == .unsupported)
    #expect(step.lastRun?.punctuationRulesFired == nil)
    #expect(step.lastRun?.punctuationLanguage == "nl")
    #expect(step.lastRun?.punctuationResolutionSource == "engine")
  }

  @Test("A vetoed take is unresolved, and a nil language on an LID engine is unresolved")
  func unresolved() async throws {
    let vetoed = step(Self.on, lid: false)
    _ = try await vetoed.process(ctx("alpha Setze Punkt beta", language: nil, vetoed: true))
    #expect(vetoed.lastRun?.punctuationStatus == .unresolved)
    #expect(vetoed.lastRun?.punctuationLanguage == nil, "an unresolved take names no language")

    let lidNil = step(Self.on, lid: true)
    let out = try await lidNil.process(ctx("alpha Setze Punkt beta", language: nil))
    #expect(out.text == "alpha Setze Punkt beta")
    #expect(lidNil.lastRun?.skipReason == "lid_backend_nil")
    #expect(lidNil.lastRun?.punctuationStatus == .unresolved)
  }

  @Test("A custom start word works and the default no longer does")
  func customWord() async throws {
    let settings = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Diktiere"])
    let custom = step(settings)
    let out = try await custom.process(ctx("alpha Diktiere Punkt beta", language: "de"))
    #expect(out.text == "alpha. Beta")
    let old = try await custom.process(ctx("alpha Setze Punkt beta", language: "de"))
    #expect(old.text == "alpha Setze Punkt beta")
    #expect(custom.lastRun?.punctuationStatus == .ranNoMatch)
  }

  @Test("An invalid stored word is never matched: the default word works, the invalid one does not")
  func invalidStoredWordIsNeverMatched() async throws {
    let settings = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Punkt"])
    let step = step(settings)
    let plain = try await step.process(ctx("alpha Punkt Punkt beta", language: "de"))
    #expect(
      plain.text == "alpha Punkt Punkt beta",
      "an override that collides with a command must not widen matching")
    let viaDefault = try await step.process(ctx("alpha Setze Punkt beta", language: "de"))
    #expect(viaDefault.text == "alpha. Beta")
  }

  // MARK: - English is not touched

  @Test("An English take takes the English route: no status, bare words as before")
  func englishRoute() async throws {
    let step = step(Self.on)
    let out = try await step.process(ctx("hello period world", language: "en", source: .locked))
    #expect(out.text == "hello. World")
    let run = try #require(step.lastRun)
    #expect(run.ran == true)
    #expect(run.skipReason == nil)
    #expect(run.punctuationStatus == nil)
    #expect(run.punctuationRulesFired == nil)
    #expect(run.punctuationLanguage == "en")
    #expect(run.punctuationResolutionSource == "locked")
  }

  @Test("English output is byte-identical to the unchanged normalizer, switch on and off")
  func englishParity() async throws {
    let inputs = [
      "hello period world", "alpha comma beta new line gamma", "the code is two zero three",
      "what question mark", "Period.", "New paragraph.",
    ]
    for enabled in [true, false] {
      let step = step(SpokenPunctuationSettings(enabled: enabled, startWordOverrides: [:]))
      for input in inputs {
        let out = try await step.process(ctx(input, language: "en"))
        #expect(
          out.text == InverseTextNormalizer().normalize(input, spokenPunctuation: enabled),
          "enabled=\(enabled) input=\(input)")
      }
    }
  }

  @Test("A nil language on a non-LID engine still runs the English route, as before")
  func nilLanguageNonLIDIsEnglish() async throws {
    let step = step(Self.on, lid: false)
    let out = try await step.process(ctx("alpha period beta Setze Punkt gamma", language: nil))
    #expect(
      out.text.hasPrefix("alpha."), "the English table applies, exactly as before: \(out.text)")
    #expect(out.text.contains("Setze Punkt"), "the start-word pass does not run here")
    #expect(step.lastRun?.punctuationStatus == nil)
    // The English table ran while the resolved language is still nil, which is exactly why this
    // field is not just `cleanup_language`.
    #expect(step.lastRun?.punctuationLanguage == "en")
    #expect(step.lastRun?.punctuationResolutionSource == nil)
  }

  @Test("A later run never inherits the previous run's punctuation metadata")
  func nothingIsInherited() async throws {
    let step = step(Self.on)
    _ = try await step.process(ctx("alpha Setze Punkt beta", language: "de"))
    #expect(step.lastRun?.punctuationStatus == .rewrote)
    _ = try await step.process(ctx("hello period world", language: "en"))
    #expect(step.lastRun?.punctuationStatus == nil)
    #expect(step.lastRun?.punctuationRulesFired == nil)
    #expect(step.lastRun?.punctuationLanguage == "en")
  }

  // MARK: - The deadline

  /// Work that outlasts the 0.5 s floor. A cooperative sleep, so the abandoned branch frees its
  /// executor at the floor (the same shape `InverseTextNormalizationBudgetTests` uses).
  private static func slowWork(_ request: ITNWorkRequest) async -> ITNWorkResult {
    try? await Task.sleep(for: .seconds(2.0))  // test-fixture-timer: the deadline itself is under test
    return ITNWorkResult(text: "PARTIAL:" + request.input, punctuationRulesFired: 5)
  }

  @Test(
    "A hung non-English pass is abandoned, the whole pre-ITN text returns and it reports timed_out")
  func nonEnglishTimeout() async throws {
    var timeouts: [[String: Any]] = []
    let step = InverseTextNormalizationStep(
      requestWork: Self.slowWork, onTimeoutForTesting: { timeouts.append($0) })
    step.spokenPunctuation = Self.on
    step.backendSupportsLID = true
    let input = "Frage B Bindestrich 2 Setze Punkt Code"
    let out = try await step.process(ctx(input, language: "de"))

    #expect(out.text == input, "the entire pre-ITN text, never a neutral-only middle")
    let run = try #require(step.lastRun)
    #expect(run.punctuationStatus == .timedOut)
    #expect(run.punctuationRulesFired == nil, "the abandoned run's count is discarded")
    #expect(run.changed == false)
    #expect(timeouts.count == 1)
    #expect(timeouts.first?["route"] as? String == "neutral")
  }

  @Test("A hung non-English run with nothing attempted is not reported as a punctuation timeout")
  func nonEnglishTimeoutWithoutAnAttempt() async throws {
    let step = InverseTextNormalizationStep(requestWork: Self.slowWork)
    step.spokenPunctuation = Self.off
    step.backendSupportsLID = true
    let input = "Frage B Bindestrich 2 Setze Punkt Code"
    let out = try await step.process(ctx(input, language: "de"))
    #expect(out.text == input)
    #expect(step.lastRun?.punctuationStatus == .disabled)
  }

  @Test("A hung English run still falls back to the pre-ITN text and carries no punctuation status")
  func englishTimeout() async throws {
    var timeouts: [[String: Any]] = []
    let step = InverseTextNormalizationStep(
      requestWork: Self.slowWork, onTimeoutForTesting: { timeouts.append($0) })
    step.spokenPunctuation = Self.on
    let input = "meet at three thirty"
    let out = try await step.process(ctx(input, language: "en"))
    #expect(out.text == input)
    #expect(step.lastRun?.punctuationStatus == nil)
    #expect(timeouts.count == 1)
    #expect(timeouts.first?["route"] as? String == "english", "the English breadcrumb names its route")
  }

  // MARK: - The snapshot is taken before the hop

  private actor Gate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
      entered = true
      for waiter in enterWaiters { waiter.resume() }
      enterWaiters = []
      if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitUntilEntered() async {
      if entered { return }
      await withCheckedContinuation { enterWaiters.append($0) }
    }

    func release() {
      released = true
      for waiter in releaseWaiters { waiter.resume() }
      releaseWaiters = []
    }
  }

  private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ITNWorkRequest] = []
    func add(_ request: ITNWorkRequest) { lock.withLock { requests.append(request) } }
    var all: [ITNWorkRequest] { lock.withLock { requests } }
  }

  @Test("A settings edit after the run entered its work cannot reach that run")
  func inFlightRunKeepsItsSnapshot() async throws {
    let gate = Gate()
    let seen = Seen()
    let step = InverseTextNormalizationStep(requestWork: { request in
      seen.add(request)
      await gate.enter()
      return ITNWorkResult(text: request.input, punctuationRulesFired: 0)
    })
    step.backendSupportsLID = true
    let original = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Diktiere"])
    step.spokenPunctuation = original

    let context = ctx("alpha Diktiere Punkt beta", language: "de")
    let task = Task { @MainActor in try await step.process(context) }
    await gate.waitUntilEntered()

    // Both halves change after the work began.
    step.spokenPunctuation = SpokenPunctuationSettings(
      enabled: false, startWordOverrides: ["de": "Anders", "fr": "Mets"])
    await gate.release()
    _ = try await task.value

    let request = try #require(seen.all.first)
    #expect(seen.all.count == 1)
    #expect(
      request.spokenPunctuation == original,
      "the whole value, both halves, as it stood at the start")
    #expect(request.punctuationLanguage == "de")
    #expect(request.startWord == "Diktiere")
    #expect(step.lastRun?.punctuationStatus == .ranNoMatch)
  }

  @Test("The request carries the exact sentinels of the take")
  func requestCarriesSentinels() async throws {
    let seen = Seen()
    let step = InverseTextNormalizationStep(requestWork: { request in
      seen.add(request)
      return ITNWorkResult(text: request.input, punctuationRulesFired: 0)
    })
    step.spokenPunctuation = Self.on
    step.backendSupportsLID = true
    var context = ctx("alpha EWSNIPabc123 beta", language: "de")
    context.protectedExpansions = [
      SnippetExpansionRecord(sentinel: "EWSNIPabc123", expansion: "hello")
    ]
    _ = try await step.process(context)
    #expect(seen.all.first?.protectedSentinels == ["EWSNIPabc123"])
  }

  // MARK: - The real chain

  private func makeChain(
    candidateSource: @escaping SnippetExpander.CandidateSource = SnippetExpander.randomCandidate,
    snippets: [Snippet]
  ) -> LimbSteps {
    let expansion = SnippetExpansionStep(
      expander: SnippetExpander(candidateSource: candidateSource),
      now: { Date(timeIntervalSince1970: 1_789_584_300) },
      clipboardText: { nil })
    expansion.snippetVocabulary = SnippetVocabulary(
      snippets: snippets, keyword: SnippetVocabulary.defaultKeyword, generation: 1)
    let steps = LimbSteps(
      snippetExpansion: expansion,
      wordCorrection: WordCorrectionStep(),
      learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep())
    steps.inverseTextNormalization.spokenPunctuation = Self.on
    steps.inverseTextNormalization.backendSupportsLID = true
    return steps
  }

  /// Every enabled step in the production order, called directly (no runner budget).
  private func runChain(_ steps: LimbSteps, _ context: TextProcessingContext) async throws
    -> TextProcessingContext
  {
    var current = context
    for step in steps.orderedChain where step.isEnabled {
      // Polish and its siblings need a provider and the network; the deterministic limbs are the
      // subject, and ITN is the step that reads the sentinels.
      if step is LLMPolishStep { continue }
      current = try await step.process(current)
    }
    return current
  }

  @Test("The production chain order puts snippet expansion before inverse text normalization")
  func chainOrder() {
    let names = makeChain(snippets: []).orderedChain.map(\.name)
    let snippetIndex = names.firstIndex(of: "Snippet Expansion")
    let itnIndex = names.firstIndex(of: "Inverse Text Normalization")
    #expect(snippetIndex != nil && itnIndex != nil)
    #expect((snippetIndex ?? Int.max) < (itnIndex ?? Int.min))
  }

  @Test("A snippet before and after a command is carried through byte for byte and then restored")
  func snippetsAroundCommands() async throws {
    let snippets = [
      Snippet(trigger: "my sign off", expansion: "thanks, sam"),
      Snippet(trigger: "my address", expansion: "1 Main Street"),
    ]
    let steps = makeChain(snippets: snippets)
    let result = try await runChain(
      steps,
      ctx(
        "Bis morgen backslash my sign off Setze Punkt backslash my address Setze Komma danke",
        language: "de"))

    let sentinels = result.protectedExpansions.map(\.sentinel)
    #expect(sentinels.count == 2)
    for sentinel in sentinels {
      #expect(
        result.text.components(separatedBy: sentinel).count == 2,
        "sentinel appears exactly once: \(result.text)")
    }
    var finished = result
    SnippetFinalizer.finalize(&finished)
    #expect(finished.text == "Bis morgen thanks, sam. 1 Main Street, danke")
  }

  @Test(
    "A command phrase that is also a saved snippet trigger goes to the snippet, bare it goes to punctuation"
  )
  func snippetBeatsCommandWhenKeywordIsSpoken() async throws {
    let steps = makeChain(snippets: [Snippet(trigger: "setze punkt", expansion: "STOP")])
    let viaSnippet = try await runChain(
      steps, ctx("alpha backslash setze punkt beta", language: "de"))
    var finished = viaSnippet
    SnippetFinalizer.finalize(&finished)
    #expect(finished.text == "alpha STOP beta")

    let bare = try await runChain(steps, ctx("alpha Setze Punkt beta", language: "de"))
    #expect(bare.protectedExpansions.isEmpty)
    #expect(bare.text == "alpha. Beta")
  }

  @Test("The fallback sentinel shape survives the neutral subset and the punctuation pass")
  func fallbackSentinelSurvives() async throws {
    // A degenerate candidate source forces the second snippet onto the `EWSNIPfallback<n>` path.
    let steps = makeChain(
      candidateSource: { "EWSNIPcafe" },
      snippets: [
        Snippet(trigger: "one", expansion: "FIRST"), Snippet(trigger: "two", expansion: "SECOND"),
      ])
    let result = try await runChain(
      steps, ctx("a backslash one Setze Punkt backslash two Setze Komma b", language: "de"))
    let sentinels = result.protectedExpansions.map(\.sentinel)
    #expect(sentinels.count == 2)
    #expect(
      sentinels.contains { $0.hasPrefix("EWSNIPfallback") },
      "the fallback path was reached: \(sentinels)")
    for sentinel in sentinels {
      #expect(
        result.text.contains(sentinel),
        "\(sentinel) must reach the end of the chain intact: \(result.text)")
    }
    var finished = result
    SnippetFinalizer.finalize(&finished)
    #expect(finished.text == "a FIRST. SECOND, b")
  }

  @Test("Capitalisation next to a snippet never touches the sentinel")
  func capitalisationNextToASentinel() async throws {
    let steps = makeChain(
      candidateSource: { "EWSNIPcafe" },
      snippets: [Snippet(trigger: "my link", expansion: "example.com")])
    let result = try await runChain(
      steps, ctx("Schau hier Setze Punkt backslash my link Setze Komma dann", language: "de"))
    var finished = result
    SnippetFinalizer.finalize(&finished)
    #expect(finished.text == "Schau hier. example.com, dann")
  }

  // MARK: - Filler removal cannot eat a command

  @Test(
    "No default start word or command form of any language is a filler the earlier step removes",
    arguments: SpokenPunctuationRules.supportedLanguages)
  func fillerRemovalLeavesCommandsAlone(language: String) async throws {
    let forms = try #require(SpokenPunctuationRules.spokenForms(for: language))
    let start = try #require(SpokenPunctuationRules.defaultStartWord(for: language))
    let filler = FillerRemovalStep()
    filler.fillerRemovalEnabled = true
    for form in forms {
      let sentence = "wir sagen \(start) \(form) und weiter"
      let out = try await filler.process(ctx(sentence, language: language))
      #expect(out.text == sentence, "language \(language), form \(form)")
    }
  }
}
