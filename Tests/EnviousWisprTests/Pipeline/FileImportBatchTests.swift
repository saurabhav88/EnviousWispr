import EnviousWisprCore
@testable import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite(.tags(.productOutcome))
struct FileImportBatchTests {
  private static let passages = [
    "the color of the center is important to everyone on the design team",
    "please send the final report to the whole team before lunch tomorrow",
    "we should review the remaining changes with our colleagues before we publish"
  ]
  private static let cleaned = [
    "The color of the center is important to everyone on the design team.",
    "Please send the final report to the whole team before lunch tomorrow.",
    "We should review the remaining changes with our colleagues before we publish."
  ]
  @MainActor
  private final class Capture {
    var users: [String] = []
    var systems: [String?] = []
    var configs: [LLMProviderConfig] = []
    var replyMode = "normal"
    var onRequest: (@MainActor () async throws -> Void)?
    func answer(user: String, system: String?, config: LLMProviderConfig) async throws -> LLMResult {
      users.append(user); systems.append(system)
      configs.append(config)
      try await onRequest?()
      if replyMode == "error" { throw LLMError.requestFailed("Fixture failure") }
      if replyMode == "malformed" { return LLMResult(polishedText: "<s1>Missing the rest.</s1>") }
      let prefix = "Transcript to clean:\n\n"
      let text = user.hasPrefix(prefix) ? String(user.dropFirst(prefix.count)) : user
      func clean(_ value: String) -> String {
        let original = value.replacingOccurrences(of: "colour", with: "color")
          .replacingOccurrences(of: "centre", with: "center")
        return original.prefix(1).uppercased() + original.dropFirst() + "."
      }
      if text.hasPrefix("<s1>"), let count = system?.components(separatedBy: " sections, each").first?.split(separator: " ").last,
        let expected = Int(count), let parts = SectionEnvelope.unwrap(text, expected: expected)
      {
        var outputs = parts.map(clean)
        if replyMode == "blank" { outputs[1] = "" }
        if replyMode == "chatter" {
          outputs[1] = "Sure, I can do that for you and the team tomorrow."
          outputs[2] = "Sure, I will send the file to you and the team tonight."
          return LLMResult(polishedText: "Certainly! Here is the cleaned transcript:\n" + SectionEnvelope.wrap(outputs))
        }
        return LLMResult(polishedText: SectionEnvelope.wrap(outputs))
      }
      return LLMResult(polishedText: clean(text))
    }
  }
  private struct Polisher: TranscriptPolisher {
    let capture: Capture
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult { try await capture.answer(user: text, system: instructions.systemPrompt, config: config) }
    func polish(
      envelope: PromptEnvelope, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      let pair = envelope.asSingleTurn()
      return try await capture.answer(user: pair?.user ?? "", system: pair?.system, config: config)
    }
  }
  private func snapshot(
    provider: LLMProvider = .openAI, spelling: EnglishSpelling = .american,
    language: LanguageMode = .locked("en"), correction: Bool = false, model: String? = nil
  ) -> RecordingSettingsSnapshot {
    let batchModel = provider == .openAI ? "gpt-6.1-sol"
      : provider == .claude ? "claude-sonnet-4-6" : LLMProvider.defaultModel(for: provider)
    return RecordingSettingsSnapshot(
      backendType: .parakeet, backendSupportsLanguageDetection: false, languageMode: language,
      wordCorrectionEnabled: correction, fillerRemovalEnabled: false, emojiFormatterEnabled: false,
      spokenPunctuationEnabled: false, spokenPunctuationStartWords: nil, spokenPunctuationEnglishPeriodWord: nil,
      llmProvider: provider.rawValue, llmModel: model ?? batchModel, s1Control: nil,
      englishSpelling: spelling, casualModeEnabled: false)
  }
  private func runner(
    _ capture: Capture, identify: @escaping (String) -> (language: String, confidence: Double)? = { _ in ("en", 0.99) },
    selection: (@MainActor (LLMProvider, String?) async -> LearnedWordCheckerSelection)? = nil
  ) -> FileImportRunner {
    FileImportRunner(
      keychainManager: KeychainManager(), egOneRuntime: nil, s1MiniRuntime: nil,
      outputClassifierHolder: nil, languageIdentifier: identify, makeEGOnePolisher: nil,
      promptPlanner: nil, checkerSelectionProvider: selection,
      makePolisher: { _, _, _ in Polisher(capture: capture) })
  }

  @Test("Models that failed batch qualification retain their ordinary requests, configuration and outcomes",
    arguments: [
      (LLMProvider.openAI, "gpt-4o-mini"),
      (LLMProvider.openAI, "gpt-4o-mini-2024-07-18"),
      (LLMProvider.claude, "claude-haiku-4-5"),
      (LLMProvider.claude, "claude-haiku-4-5-20251001")
    ])
  func individualRequestModelParity(provider: LLMProvider, model: String) async throws {
    let capture = Capture(); let grouped = runner(capture)
    let ordinaryCapture = Capture(); let ordinary = runner(ordinaryCapture)
    let settings = snapshot(provider: provider, model: model)
    grouped.freeze(settings: settings, vocabulary: nil)
    ordinary.freeze(settings: settings, vocabulary: nil)
    var expected: [FileImportRunner.PartOutcome] = []
    for text in Self.passages { expected.append(try await ordinary.process(part: text)) }
    var indices: [Int] = []; var actual: [FileImportRunner.PartOutcome] = []
    try await grouped.process(parts: Self.passages) { index, outcome in
      indices.append(index); actual.append(outcome); return true
    }
    #expect(indices == [0, 1, 2])
    #expect(actual.count == 3)
    #expect(expected.count == 3)
    #expect(actual == expected)
    #expect(capture.users.count == 3)
    #expect(ordinaryCapture.users.count == 3)
    #expect(capture.users == ordinaryCapture.users)
    #expect(capture.systems == ordinaryCapture.systems)
    #expect(capture.users.allSatisfy { $0.hasPrefix("Transcript to clean:\n\n<s1>") == false })
    #expect(capture.configs.count == 3)
    #expect(ordinaryCapture.configs.count == 3)
    for (actual, expected) in zip(capture.configs, ordinaryCapture.configs) {
      #expect(actual.model == model)
      #expect(actual.model == expected.model)
      #expect(actual.apiKeyKeychainId == expected.apiKeyKeychainId)
      #expect(actual.outputTokens == expected.outputTokens)
      #expect(actual.temperature == expected.temperature)
      #expect(actual.thinking == expected.thinking)
      #expect(actual.detectedLanguage == expected.detectedLanguage)
    }
  }

  @Test("Qualified Gemini and Sonnet selections retain one request and ordered cleanup outcomes",
    arguments: [LLMProvider.gemini, .claude])
  func qualifiedProvidersKeepBatching(provider: LLMProvider) async throws {
    let model = provider == .claude ? "claude-sonnet-4-6" : LLMProvider.defaultModel(for: provider)
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(provider: provider, model: model), vocabulary: nil)
    var indices: [Int] = []; var outcomes: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: Self.passages) { index, outcome in
      indices.append(index); outcomes.append(outcome); return true
    }
    #expect(indices == [0, 1, 2])
    #expect(capture.users.count == 1)
    #expect(capture.configs.count == 1)
    #expect(capture.configs.first?.model == model)
    #expect(outcomes.map { $0.displayText } == Self.cleaned)
  }

  @Test("outer chatter is removed while the second section keeps its own dictated opening")
  func sourceBoundChatter() async throws {
    let capture = Capture(); capture.replyMode = "chatter"
    let subject = runner(capture)
    subject.freeze(settings: snapshot(), vocabulary: nil)
    var outputs: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: [Self.passages[0], "sure I can do that for you and the team tomorrow", "I will send the file to you and the team tonight"]) { _, outcome in
      outputs.append(outcome); return true
    }
    #expect(capture.users.count == 1)
    #expect(outputs.count == 3)
    #expect(outputs[0].displayText == Self.cleaned[0])
    #expect(outputs[1].displayText == "Sure, I can do that for you and the team tomorrow.")
    #expect(outputs[2].displayText == "I will send the file to you and the team tonight.")
    #expect(outputs[1].isUnpolished == false)
  }

  @Test("Compatible sections share one call and emit their independently expected text in source order")
  func orderedBatch() async throws {
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(), vocabulary: nil)
    var indices: [Int] = []; var outputs: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: Self.passages) { index, outcome in
      indices.append(index); outputs.append(outcome); return true
    }
    #expect(capture.users.count == 1)
    #expect(indices == [0, 1, 2])
    #expect(outputs.map(\.text) == Self.passages)
    #expect(outputs.map(\.polishedText) == Self.cleaned.map(Optional.some))
    #expect(outputs.allSatisfy { $0.wasPolishAttempted })
  }

  @Test("Empty and tiny inputs make no requests; existing short instructions remain individual")
  func bypassAndMinimalEdit() async throws {
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(), vocabulary: nil)
    var outputs: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: []) { _, _ in Issue.record("empty input emitted a part"); return true }
    try await subject.process(parts: ["thank you", "yes"]) { _, outcome in outputs.append(outcome); return true }
    #expect(capture.users.isEmpty)
    #expect(outputs.count == 2)
    #expect(outputs.allSatisfy { $0.wasPolishAttempted == false && $0.isUnpolished == false })
    try await subject.process(parts: ["Please send the report tomorrow."]) { _, _ in true }
    #expect(capture.users.count == 1)
    #expect(capture.users[0] == "Transcript to clean:\n\nPlease send the report tomorrow.")
    #expect(capture.systems[0]?.contains("Very short input. Return as-is") == true)
  }

  @Test("Word input limits flush and progress begins before the whole document is prepared")
  func wordBudgetAndProgress() async throws {
    let capture = Capture(); var prepared = 0
    let subject = runner(capture, identify: { _ in prepared += 1; return ("en", 0.99) })
    subject.freeze(settings: snapshot(), vocabulary: nil)
    let passage = (0..<250).map { "word\($0)" }.joined(separator: " ")
    var indices: [Int] = []; var atFirstOutput: Int?
    try await subject.process(parts: Array(repeating: passage, count: 6)) { index, _ in
      if atFirstOutput == nil { atFirstOutput = prepared }
      indices.append(index); return true
    }
    #expect(indices == [0, 1, 2, 3, 4, 5])
    #expect(capture.users.count == 3)
    #expect(prepared == 6)
    #expect(try #require(atFirstOutput) < 6)
    for user in capture.users {
      let payload = user.replacingOccurrences(of: "Transcript to clean:\n\n", with: "")
      #expect(payload.split(whereSeparator: \.isWhitespace).count <= TranscriptSplitter.maximumWordsPerPart)
      #expect(payload.utf8.count <= TranscriptSplitter.maximumBytesPerPart)
    }
  }

  @Test("UTF8 and escaped framing overhead bound input, oversized and one-piece calls remain ordinary")
  func byteBudgetAndOversized() async throws {
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(), vocabulary: nil)
    let tail = " one two three four five six seven eight nine ten"
    let large = String(repeating: "語", count: 1250) + tail
    #expect(large.utf8.count < TranscriptSplitter.maximumBytesPerPart)
    #expect(SectionEnvelope.wrap([large, large]).utf8.count > TranscriptSplitter.maximumBytesPerPart)
    var outputs = 0
    try await subject.process(parts: [large, large]) { _, _ in outputs += 1; return true }
    #expect(outputs == 2)
    #expect(capture.users.count == 2)
    #expect(capture.users.allSatisfy { $0.hasPrefix("Transcript to clean:\n\n<s1>") == false })
    let oversized = String(repeating: "語", count: TranscriptSplitter.maximumBytesPerPart / 3 + 1) + tail
    try await subject.process(parts: [oversized]) { _, _ in true }
    #expect(capture.users.count == 3)
    #expect(capture.users[2] == "Transcript to clean:\n\n" + oversized)
    let base = "keep <s2> one two three four five six seven eight nine "
    let framingBytes = "<s1></s1>\n<s2></s2>".utf8.count
    let bodyBytes = (TranscriptSplitter.maximumBytesPerPart - framingBytes) / 2
    let literal = base + String(repeating: "x", count: bodyBytes - base.utf8.count)
    let unescaped = "<s1>\(literal)</s1>\n<s2>\(literal)</s2>"
    #expect(unescaped.utf8.count <= TranscriptSplitter.maximumBytesPerPart)
    #expect(SectionEnvelope.wrap([literal, literal]).utf8.count > TranscriptSplitter.maximumBytesPerPart)
    try await subject.process(parts: [literal, literal]) { _, _ in true }
    #expect(capture.users.count == 5)
    #expect(capture.users[3] == "Transcript to clean:\n\n" + literal)
    #expect(capture.users[4] == "Transcript to clean:\n\n" + literal)

  }

  @Test("Deterministic prefix reaches the request and per-piece suffix matches the existing ordinary path")
  func preparedFloorAndSuffix() async throws {
    let groupedCapture = Capture(); var identified = 0
    let grouped = runner(groupedCapture, identify: { _ in identified += 1; return ("en", 0.99) })
    let ordinaryCapture = Capture(); let ordinary = runner(ordinaryCapture)
    let settings = snapshot(spelling: .british)
    grouped.freeze(settings: settings, vocabulary: nil)
    ordinary.freeze(settings: settings, vocabulary: nil)
    var expected: [FileImportRunner.PartOutcome] = []
    for text in Self.passages.prefix(2) { expected.append(try await ordinary.process(part: text)) }
    var actual: [FileImportRunner.PartOutcome] = []
    try await grouped.process(parts: Array(Self.passages.prefix(2))) { _, outcome in actual.append(outcome); return true }
    #expect(actual == expected)
    #expect(identified == 2)
    #expect(groupedCapture.users.count == 1)
    #expect(ordinaryCapture.users.count == 2)
    #expect(groupedCapture.users[0].contains("the colour of the centre"))
    #expect(actual[0].polishedText == "The colour of the centre is important to everyone on the design team.")
  }

  @Test("Frozen vocabulary correction and protected spelling reach each request and suffix")
  func vocabularyAndSpelling() async throws {
    let capture = Capture(); let subject = runner(capture)
    let vocabulary = CorrectorVocabulary(terms: [CustomWord(canonical: "color", aliases: ["collar"])], generation: 51)
    subject.freeze(settings: snapshot(spelling: .british, correction: true), vocabulary: vocabulary)
    let raw = Self.passages[0].replacingOccurrences(of: "color", with: "collar")
    var outputs: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: [raw, Self.passages[1]]) { _, outcome in outputs.append(outcome); return true }
    #expect(capture.users.count == 1)
    #expect(capture.users[0].contains("the color of the centre"))
    #expect(outputs[0].text == "the color of the centre is important to everyone on the design team")
    #expect(outputs[0].polishedText == "The color of the centre is important to everyone on the design team.")
  }

  @Test("Incompatible prepared language policies flush before later preparation")
  func languageCompatibility() async throws {
    let capture = Capture(); var prepared = 0
    let subject = runner(capture, identify: { text in
      prepared += 1; return (text.hasPrefix("bonjour") ? "fr" : "en", 0.99)
    })
    subject.freeze(settings: snapshot(language: .auto), vocabulary: nil)
    let french = "bonjour merci de transmettre ce rapport à toute notre équipe avant demain matin"
    var firstOutput: Int?
    try await subject.process(parts: [Self.passages[0], french, Self.passages[2]]) { _, _ in
      if firstOutput == nil { firstOutput = prepared }; return true
    }
    #expect(capture.users.count == 3)
    #expect(firstOutput == 2)
    #expect(capture.users.allSatisfy { $0.contains("<s1>") == false })
  }

  @Test("Malformed, blank and failed responses keep each prepared floor without repair calls", arguments: ["malformed", "blank", "error"])
  func failureFloors(kind: String) async throws {
    let capture = Capture(); capture.replyMode = kind
    let subject = runner(capture); subject.freeze(settings: snapshot(spelling: .british), vocabulary: nil)
    var outputs: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: Array(Self.passages.prefix(2))) { _, outcome in outputs.append(outcome); return true }
    #expect(capture.users.count == 1)
    #expect(outputs.count == 2)
    #expect(outputs[0].text == "the colour of the centre is important to everyone on the design team")
    #expect(outputs[1].text == Self.passages[1])
    #expect(outputs[1].polishedText == nil)
    #expect(outputs[1].isUnpolished)
    #expect(outputs[0].isUnpolished == (kind != "blank"))
  }

  @Test("Callback rejection stops remaining outcomes and dispatches")
  func rejectedCallback() async throws {
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(), vocabulary: nil)
    let passage = (0..<250).map { "word\($0)" }.joined(separator: " ")
    var emitted: [Int] = []
    await #expect(throws: CancellationError.self) {
      try await subject.process(parts: Array(repeating: passage, count: 4)) { index, _ in emitted.append(index); return false }
    }
    #expect(emitted == [0])
    #expect(capture.users.count == 1)
  }

  @Test("Cancellation and superseded freezes/releases during a request publish nothing further", arguments: ["cancel", "freeze", "release"])
  func suspendedRequest(action: String) async throws {
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(), vocabulary: nil)
    let entered = BoundedWait.Signal(); let release = BoundedWait.Signal()
    capture.onRequest = { entered.fire(); try await BoundedWait.until(release) }
    let long = (0..<250).map { "word\($0)" }.joined(separator: " ")
    var emitted: [Int] = []
    let work = Task {
      try await subject.process(parts: Array(repeating: long, count: 4)) { index, _ in emitted.append(index); return true }
    }
    defer { work.cancel(); release.fire() }
    try await BoundedWait.until(entered)
    if action == "cancel" { work.cancel() }
    else if action == "freeze" { subject.freeze(settings: snapshot(provider: .gemini), vocabulary: nil) }
    else { subject.releaseCheckerSelections() }
    release.fire()
    let result = try await BoundedWait.result(of: work, onExpiry: { release.fire() })
    switch result {
    case .success: Issue.record("a cancelled or superseded invocation completed normally")
    case .failure(let error): #expect(error is CancellationError)
    }
    #expect(emitted.isEmpty)
    #expect(capture.users.count == 1)
  }

  @Test("A suspended preparation cannot refill the cache of a newer freeze or released run", arguments: ["freeze", "release"])
  func suspendedPreparation(action: String) async throws {
    let capture = Capture()
    let entered = BoundedWait.Signal(); let release = BoundedWait.Signal()
    var selections = 0
    let subject = runner(capture, selection: { _, _ in
      selections += 1
      if selections == 1 { entered.fire(); try? await BoundedWait.until(release) }
      return .init(absence: .serverUnavailable)
    })
    let vocabulary = CorrectorVocabulary(terms: [CustomWord(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
      learnedAt: Date(timeIntervalSince1970: 1_790_000_000))], generation: 1)
    let settings = snapshot(correction: true)
    subject.freeze(settings: settings, vocabulary: vocabulary)
    var emitted = 0
    let work = Task {
      try await subject.process(parts: Self.passages) { _, _ in emitted += 1; return true }
    }
    defer { work.cancel(); release.fire() }
    try await BoundedWait.until(entered)
    if action == "freeze" { subject.freeze(settings: settings, vocabulary: vocabulary) }
    else { subject.releaseCheckerSelections() }
    release.fire()
    let result = try await BoundedWait.result(of: work, onExpiry: { release.fire() })
    switch result {
    case .success: Issue.record("superseded preparation completed normally")
    case .failure(let error): #expect(error is CancellationError)
    }
    #expect(emitted == 0)
    #expect(capture.users.isEmpty)
    try await subject.process(parts: [Self.passages[0]]) { _, _ in true }
    #expect(selections == 2)
    #expect(capture.users.count == 1)
  }

  @Test("No-provider cleanup remains serial and does not claim an AI attempt")
  func noProvider() async throws {
    let capture = Capture(); let subject = runner(capture)
    subject.freeze(settings: snapshot(provider: .none, spelling: .british), vocabulary: nil)
    var outputs: [FileImportRunner.PartOutcome] = []
    try await subject.process(parts: Self.passages) { _, outcome in outputs.append(outcome); return true }
    #expect(capture.users.isEmpty)
    #expect(outputs.count == 3)
    #expect(outputs.allSatisfy { $0.polishedText == nil && $0.wasPolishAttempted == false })
    #expect(outputs[0].text == "the colour of the centre is important to everyone on the design team")
  }

  @Test("Local EG1 keeps its existing one-piece requests")
  func localSerial() async throws {
    let capture = NamedPromptCapture()
    let subject = FileImportRunner(
      keychainManager: KeychainManager(), egOneRuntime: ReadyEGOneRuntime(), s1MiniRuntime: nil,
      outputClassifierHolder: nil, languageIdentifier: { _ in ("pl", 0.99) },
      makeEGOnePolisher: { _ in PromptCapturingPolisher(capture: capture) },
      promptPlanner: DefaultPromptPlanner(egOneFamily: .egOneEnvelopeNamedLanguage))
    subject.freeze(settings: FileImportRunnerTests.egOneSnapshot, vocabulary: nil)
    var emitted: [Int] = []
    try await subject.process(parts: [FileImportRunnerTests.polishPart, FileImportRunnerTests.polishPart]) { index, _ in emitted.append(index); return true }
    #expect(capture.systemPrompts == [FileImportRunnerTests.namedPolishPrompt, FileImportRunnerTests.namedPolishPrompt])
    #expect(emitted == [0, 1])
  }
}
