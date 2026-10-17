import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// #2648 — what one part of an imported transcript goes through.
///
/// **The third caller of `TextProcessingRunner`, not a second pipeline.**
/// `RecoveryTextProcessor` is the proven precedent for exactly this shape: the
/// runner takes its steps as a parameter, so a new caller supplies a step list
/// and reuses the shipped execution algorithm — ordering, timeouts, the
/// raw-text floor, the silent-skip classification. Nothing about cleaning text
/// is reimplemented here.
///
/// **Fresh steps per part, deliberately.** `InverseTextNormalizationStep` keeps
/// a `lastRun` its telemetry reads after `process` returns
/// (`InverseTextNormalizationStep.swift:71`), so two parts sharing one instance
/// could describe each other. Parts run one at a time today, because the whole
/// reason the engine claim exists is that EG-1 has one inference slot — but that
/// ordering is a property of the shared resource, not a promise the step is
/// entitled to. Building per part costs nothing measurable against a part that
/// occupies the polisher for about twelve seconds. Finding owed to the #2758
/// session.
@MainActor
public final class FileImportRunner {

  /// What one part produced.
  ///
  /// `text` is the deterministic floor — the chain's output with polish removed
  /// — and it is what the user gets when polish fails. That is the Heart &
  /// Limbs contract applied per part: thirteen good parts and one raw part is a
  /// good outcome, and hiding the raw one is the failure.
  public struct PartOutcome: Sendable, Equatable {
    public let text: String
    public let polishedText: String?
    /// Whether a polisher was asked for this part. Defaults to true so every
    /// existing construction keeps meaning what it meant.
    private let polishAttempted: Bool

    public init(
      text: String, polishedText: String?, polishAttempted: Bool = true
    ) {
      self.text = text
      self.polishedText = polishedText
      self.polishAttempted = polishAttempted
    }

    /// What the document shows for this part: polished when there is one, the
    /// deterministic floor otherwise.
    public var displayText: String { polishedText ?? text }

    /// Whether this part is showing raw text because its polish FAILED.
    ///
    /// **Failure and bypass are different things and must not share a field.**
    /// `polishedText == nil` is true both when a polisher tried and could not,
    /// and when the user chose no polisher at all — and the notice this drives
    /// says "could not be cleaned up", which over a deliberately-unpolished
    /// document accuses the app of failing at something nobody asked it to do.
    /// A bypass is not a failure: downstream must treat it as "the step never
    /// happened", never as "the step went wrong". Found by Codex.
    public var isUnpolished: Bool { polishedText == nil && wasPolishAttempted }

    /// Whether a polisher was asked at all. False when the frozen configuration
    /// names no polisher, which is a setting, not an outcome.
    public var wasPolishAttempted: Bool { polishAttempted }
  }

  private let keychainManager: KeychainManager
  private let egOneRuntime: (any EGOneEndpointProviding)?
  private let s1MiniRuntime: (any EGOneEndpointProviding)?
  private let outputClassifierHolder: OutputClassifierHolder?
  private let checkerSelectionProvider:
    (@MainActor (LLMProvider, String?) async -> LearnedWordCheckerSelection)?

  /// Test seams (#3111), production defaults unchanged: the language recogniser the
  /// runner resolves with, the EG-1 polisher factory, and the prompt planner, so a test
  /// can observe which prompt an import and its "Clean it again" pass send without a real
  /// model. The planner is a seam because the default reads the EG-1 family from the APP
  /// bundle's manifest, which a test host does not carry.
  private let languageIdentifier: (String) -> (language: String, confidence: Double)?
  private let makeEGOnePolisher: (@MainActor (EGOneEndpoint) -> any TranscriptPolisher)?
  private let promptPlanner: (any PromptPlanning)?
  private let makePolisher: LLMPolishStep.PolisherFactory?

  /// **One import, one configuration.** Frozen when the run starts and applied
  /// identically to every part, so a user who changes their polisher halfway
  /// through does not get a document polished two different ways. Reuses
  /// `RecordingSettingsSnapshot` rather than declaring a parallel type: it is
  /// already the single authority for "the settings a text-processing run
  /// needs", and a second one would be a second thing to keep in step.
  private var frozenSettings: RecordingSettingsSnapshot?

  /// The custom-words vocabulary, frozen with the settings for the same reason.
  private var frozenVocabulary: CorrectorVocabulary?
  /// An import is one invocation even when it has many parts, so the endpoint
  /// is chosen once per language. The choice is keyed by each part's resolved
  /// language because S1-mini's check prompt names that language (#3105): a
  /// later Spanish part must not reuse a checker built for an English one.
  /// Key "" is an unresolved language.
  private var frozenCheckerSelections: [String: LearnedWordCheckerSelection] = [:]
  /// Bumped by every freeze and every release (#3289). A selection that returns after either
  /// belongs to a run that no longer owns the cache, so it must not write into it: a stale checker
  /// parked there would keep the word check's model in memory after the job ended.
  private var checkerSelectionGeneration: UInt64 = 0

  /// The polish engine this import was frozen with, for the word check's residency (#3289): a held
  /// run keeps needing the check its frozen engine selects, whatever the settings say now.
  public var frozenLLMProvider: LLMProvider? {
    frozenSettings.map { LLMProvider(rawValue: $0.llmProvider) ?? .none }
  }

  public convenience init(
    keychainManager: KeychainManager,
    egOneRuntime: (any EGOneEndpointProviding)? = nil,
    s1MiniRuntime: (any EGOneEndpointProviding)? = nil,
    outputClassifierHolder: OutputClassifierHolder? = nil,
    checkerSelectionProvider: (@MainActor (LLMProvider, String?) async -> LearnedWordCheckerSelection)? = nil
  ) {
    self.init(
      keychainManager: keychainManager, egOneRuntime: egOneRuntime, s1MiniRuntime: s1MiniRuntime,
      outputClassifierHolder: outputClassifierHolder,
      languageIdentifier: DictationLanguageResolver.identify, makeEGOnePolisher: nil,
      promptPlanner: nil, checkerSelectionProvider: checkerSelectionProvider)
  }

  init(
    keychainManager: KeychainManager,
    egOneRuntime: (any EGOneEndpointProviding)?,
    s1MiniRuntime: (any EGOneEndpointProviding)?,
    outputClassifierHolder: OutputClassifierHolder?,
    languageIdentifier: @escaping (String) -> (language: String, confidence: Double)?,
    makeEGOnePolisher: (@MainActor (EGOneEndpoint) -> any TranscriptPolisher)?,
    promptPlanner: (any PromptPlanning)?,
    checkerSelectionProvider: (@MainActor (LLMProvider, String?) async -> LearnedWordCheckerSelection)? = nil,
    makePolisher: LLMPolishStep.PolisherFactory? = nil
  ) {
    self.keychainManager = keychainManager
    self.egOneRuntime = egOneRuntime
    self.s1MiniRuntime = s1MiniRuntime
    self.outputClassifierHolder = outputClassifierHolder
    self.languageIdentifier = languageIdentifier
    self.makeEGOnePolisher = makeEGOnePolisher
    self.promptPlanner = promptPlanner
    self.makePolisher = makePolisher
    self.checkerSelectionProvider = checkerSelectionProvider
  }

  /// Freezes the configuration this import runs under. Called once, before the
  /// first part.
  public func freeze(settings: RecordingSettingsSnapshot, vocabulary: CorrectorVocabulary?) {
    frozenSettings = settings
    frozenVocabulary = vocabulary
    frozenCheckerSelections = [:]
    checkerSelectionGeneration &+= 1
  }

  /// The job's engine hold ended (#3289): drop the cached checker selections, so the word check's
  /// model is no longer held by an import that has finished. Called after the physical work exits;
  /// a late checker answer still holds its own reference until it returns. A later Clean it again
  /// freezes again and asks the selection provider afresh.
  public func releaseCheckerSelections() {
    frozenCheckerSelections = [:]
    checkerSelectionGeneration &+= 1
  }

  /// Runs one part through the shipped chain.
  ///
  /// **Cancellation is checked after the run, and a cancelled part commits
  /// nothing.** The shared runner deliberately absorbs cancellation as a silent
  /// skip, because for a live dictation an interrupted limb should still deliver
  /// the words the user just spoke. An import is the opposite case: the user
  /// pressed Stop, so the honest outcome is that this part did not happen. The
  /// check lives here rather than in the runner, so the heart path's behaviour
  /// is untouched by a feature it does not participate in.
  /// - Parameter engineLanguage: the language the ASR engine reported for this
  ///   recording, or nil when the engine does not report one.
  public func process(part: String, engineLanguage: String? = nil) async throws -> PartOutcome {
    guard let settings = frozenSettings else {
      throw FileImportRunnerError.notConfigured
    }
    try Task.checkCancellation()

    let steps = makeSteps(settings: settings)
    let runner = TextProcessingRunner(telemetry: .silent, languageIdentifier: languageIdentifier)
    // The frozen locked language, or nil for auto — matched to how the recovery
    // replay reads the same field (`RecoveryTextProcessor.swift:149`), so an
    // import and a replay resolve language the same way rather than two ways.
    var lockedLanguage: String?
    if case .locked(let code) = settings.languageMode { lockedLanguage = code }
    let result = try await runner.run(
      rawText: part,
      evidence: LanguageEvidence(
        lockedLanguage: lockedLanguage,
        engineDetectsLanguage: settings.backendSupportsLanguageDetection,
        // **What the ENGINE heard, not nil.** Whisper reports the language it
        // detected and the resolver's ladder prefers that over identifying the
        // language from the text — which is the weaker source, and the only one
        // an import had. A Spanish recording under automatic language was
        // cleaned up as whatever the text identifier guessed from the ASR
        // output, and ASR output for a language the engine was not told about is
        // exactly the text least safe to guess from. Found by cloud review.
        engineReportedLanguage: engineLanguage,
        // #3124: frozen at Start with the lock; nil (never set) is American.
        englishSpelling: settings.englishSpelling ?? .american),
      // No target app: an import is not being pasted anywhere, and a step that
      // adapts to the frontmost app would be adapting to whatever the user
      // happened to have open while the file decoded.
      targetAppName: nil,
      steps: steps.orderedChainForFileImport,
      frozenCorrectorVocabulary: steps.wordCorrection.correctorVocabulary)

    // The user pressed Stop while this part was in flight. The runner will have
    // returned the deterministic floor rather than propagating, which is right
    // for a dictation and wrong here.
    try Task.checkCancellation()

    return Self.outcome(settings: settings, result: result)
  }

  private struct PreparedPart {
    let index: Int
    let context: TextProcessingContext
    let steps: LimbSteps
    let member: LLMPolishStep.FileBatchMember?
  }

  /// File import's ordered streaming cleanup. A rejected callback ends the invocation.
  /// Locals and singletons retain the existing pipeline; only compatible cloud pieces share a call.
  package func process(
    parts: [String], engineLanguage: String? = nil,
    onOutcome: @MainActor (Int, PartOutcome) -> Bool
  ) async throws {
    guard let settings = frozenSettings else { throw FileImportRunnerError.notConfigured }
    let vocabulary = frozenVocabulary
    let generation = checkerSelectionGeneration
    let provider = LLMProvider(rawValue: settings.llmProvider) ?? .none
    let runner = TextProcessingRunner(telemetry: .silent, languageIdentifier: languageIdentifier)
    var pending: [PreparedPart] = []
    var groupStep: LLMPolishStep?

    func checkCurrent() throws {
      try Task.checkCancellation()
      guard checkerSelectionGeneration == generation else { throw CancellationError() }
    }
    func emit(_ index: Int, _ outcome: PartOutcome) throws {
      try checkCurrent()
      guard onOutcome(index, outcome) else { throw CancellationError() }
      try checkCurrent()
    }
    func finish(_ part: PreparedPart, context: TextProcessingContext, includePolish: Bool) async throws {
      try checkCurrent()
      let stages = part.steps.fileImportStages
      let chain = (includePolish ? [stages.polish] : []) + stages.afterPolish
      let result = try await runner.run(context: context, steps: chain)
      try checkCurrent()
      try emit(part.index, Self.outcome(settings: settings, result: result))
    }
    func flush() async throws {
      try checkCurrent()
      guard pending.isEmpty == false else { return }
      let current = pending
      let step = groupStep
      pending.removeAll(keepingCapacity: true)
      groupStep = nil
      let members = current.compactMap(\.member)
      if current.count > 1, let step, members.count == current.count,
        let input = step.prepareFileBatch(members)
      {
        try checkCurrent()
        let accepted = try await runner.run(context: input, steps: [step])
        try checkCurrent()
        let mapped = step.takeFileBatchResults(accepted: accepted.context)
        for (offset, part) in current.enumerated() {
          try await finish(part, context: mapped?[offset] ?? part.context, includePolish: false)
          try checkCurrent()
        }
      } else {
        for part in current {
          try await finish(part, context: part.context, includePolish: true)
          try checkCurrent()
        }
      }
    }
    func fits(_ members: [LLMPolishStep.FileBatchMember]) -> Bool {
      let text = SectionEnvelope.wrap(members.map { $0.context.text })
      return text.split(whereSeparator: \.isWhitespace).count <= TranscriptSplitter.maximumWordsPerPart
        && text.utf8.count <= TranscriptSplitter.maximumBytesPerPart
    }

    try checkCurrent()
    for (index, text) in parts.enumerated() {
      try checkCurrent()
      guard [.openAI, .gemini, .claude].contains(provider) else {
        do {
          let outcome = try await process(part: text, engineLanguage: engineLanguage)
          try checkCurrent()
          try emit(index, outcome)
        } catch is CancellationError { throw CancellationError() }
        catch {
          try checkCurrent()
          try emit(index, PartOutcome(text: text, polishedText: nil))
        }
        continue
      }
      // Preparation retains the full chain's frozen language/checker/spelling state once.
      let steps = makeSteps(settings: settings, vocabulary: vocabulary, generation: generation)
      let stages = steps.fileImportStages
      var lock: String?
      if case .locked(let code) = settings.languageMode { lock = code }
      let seed = await runner.makeContext(
        rawText: text,
        evidence: LanguageEvidence(
          lockedLanguage: lock, engineDetectsLanguage: settings.backendSupportsLanguageDetection,
          engineReportedLanguage: engineLanguage, englishSpelling: settings.englishSpelling ?? .american),
        targetAppName: nil, steps: steps.orderedChainForFileImport,
        frozenCorrectorVocabulary: steps.wordCorrection.correctorVocabulary)
      try checkCurrent()
      let prefix = try await runner.run(context: seed, steps: stages.beforePolish)
      try checkCurrent()
      let context = prefix.context
      let member = stages.polish.fileBatchMember(context)
      let part = PreparedPart(index: index, context: context, steps: steps, member: member)
      if let member, fits([member]) {
        let candidates = pending.compactMap(\.member) + [member]
        if pending.isEmpty == false,
          (fits(candidates) == false || groupStep?.canShareFileBatch(candidates) != true)
        {
          try await flush()
          try checkCurrent()
        }
        if pending.isEmpty {
          groupStep = makeSteps(settings: settings, vocabulary: vocabulary, generation: generation).llmPolish
        }
        pending.append(part)
      } else {
        // Bypass/short/oversized pieces keep their ordinary policy and original position.
        try await flush()
        try checkCurrent()
        try await finish(part, context: context, includePolish: true)
        try checkCurrent()
      }
    }
    try await flush()
    try checkCurrent()
  }

  private static func outcome(
    settings: RecordingSettingsSnapshot, result: TextProcessingRunResult
  ) -> PartOutcome {
    // A blank polish is not a polish — the same rule the recovery replay
    // applies, for the same reason: the floor is real text and an empty string
    // is not an improvement on it. Reachable the same way as on the live path,
    // where a connector accepts a whitespace response as success and trims it.
    //
    // **`SnippetFinalizer` is deliberately absent here, unlike the replay path.**
    // It resolves the sentinels the snippet step leaves behind, and this chain
    // does not run that step, so there is nothing for it to resolve. Said out
    // loud because the asymmetry with `RecoveryTextProcessor` is the first thing
    // a reader comparing the two will notice.
    let context = result.context
    let polished = (context.polishedText?.isEmpty ?? true) ? nil : context.polishedText
    return PartOutcome(
      text: context.text, polishedText: polished,
      // **Read from the frozen configuration, not from the outcome.** Whether a
      // polisher was ASKED is a property of the run's settings; whether it
      // ANSWERED is a property of this part. Deriving the first from the second
      // is what let a deliberately-unpolished document accuse the app of
      // failing.
      // **A provider being SELECTED is not the same as a polish being
      // ATTEMPTED.** `LLMPolishStep` deliberately bypasses a passage too short
      // to be worth sending — at most three words, or under ten non-whitespace
      // characters in an unsegmented script — and returns no polished text and
      // no error, which is exactly the shape of a failure. Reading the setting
      // alone marked those passages "could not be cleaned up" for a bypass the
      // pipeline chose on purpose. Found by cloud review, one round after the
      // same distinction was drawn for the provider-is-None case: the setting
      // answers "was one asked for", and only the OUTCOME answers "was one
      // made".
      polishAttempted: Self.polishWasAttempted(settings: settings, result: result))
  }

  /// Whether a polisher was actually asked about THIS passage.
  ///
  /// False when no provider is selected, and false when the step bypassed the
  /// passage for being too short. Both are settings-or-policy decisions rather
  /// than outcomes, and neither is a failure the user should be told about.
  private static func polishWasAttempted(
    settings: RecordingSettingsSnapshot, result: TextProcessingRunResult
  ) -> Bool {
    guard let provider = LLMProvider(rawValue: settings.llmProvider), provider != .none else {
      return false
    }
    // `LLMPolishStep` is the only thing that knows whether it declined, so it
    // says so rather than being guessed at from the shape of the result.
    return !result.context.polishWasBypassed
  }

  /// Builds this part's own step instances and applies the frozen settings.
  /// Internal, not private, so a test can see which settings reached the steps it builds (#2450).
  func makeSteps(settings: RecordingSettingsSnapshot) -> LimbSteps {
    makeSteps(settings: settings, vocabulary: frozenVocabulary, generation: checkerSelectionGeneration)
  }

  private func makeSteps(
    settings: RecordingSettingsSnapshot, vocabulary: CorrectorVocabulary?, generation: UInt64
  ) -> LimbSteps {
    let llmPolish = LLMPolishStep(keychainManager: keychainManager, telemetry: .silent())
    // Standalone, exactly like the recovery replay: no live kernel is attached,
    // so there is nothing to stream tokens to and no lifecycle to notify.
    llmPolish.onWillProcess = nil
    llmPolish.onToken = nil
    llmPolish.outputClassifierHolder = outputClassifierHolder
    llmPolish.egOneRuntime = egOneRuntime
    if let makeEGOnePolisher { llmPolish.makeEGOnePolisher = makeEGOnePolisher }
    if let promptPlanner { llmPolish.promptPlanner = promptPlanner }
    if let makePolisher { llmPolish.makePolisher = makePolisher }
    llmPolish.s1MiniRuntime = s1MiniRuntime
    llmPolish.llmProvider = LLMProvider(rawValue: settings.llmProvider) ?? .none
    llmPolish.llmModel = LLMProvider.replacingRetiredModel(
      settings.llmModel, for: llmPolish.llmProvider)
    llmPolish.backend = settings.backendType
    llmPolish.s1Control = settings.s1Control ?? .default
    llmPolish.languageDetection = nil

    let wordCorrection = WordCorrectionStep()
    wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    if let vocabulary { wordCorrection.correctorVocabulary = vocabulary }
    let learnedWordCheck = LearnedWordCheckStep()
    learnedWordCheck.selectionProvider = { [weak self] provider, language in
      guard let self, self.checkerSelectionGeneration == generation
      else { return .init(absence: .serverUnavailable) }
      let key = language ?? ""
      if let frozen = self.frozenCheckerSelections[key] { return frozen }
      let selection = await self.checkerSelectionProvider?(provider, language)
        ?? .init(absence: .serverUnavailable)
      // A release or a newer freeze happened while this selection was out: it answers this part
      // only, and never refills a cache that belongs to nobody or to a newer run.
      if self.checkerSelectionGeneration == generation {
        self.frozenCheckerSelections[key] = selection
      }
      return selection
    }
    learnedWordCheck.wordCorrectionEnabled = settings.wordCorrectionEnabled
    if let vocabulary { learnedWordCheck.correctorVocabulary = vocabulary }

    let fillerRemoval = FillerRemovalStep()
    fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled

    let emojiFormatter = EmojiFormatterStep()
    emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled

    // #3737: the freeze passes false (an imported recording is a document, not a reply); read it
    // rather than hard-code it, so the snapshot stays the one authority for this run.
    let casualEnding = CasualEndingStep()
    casualEnding.casualModeEnabled = settings.casualModeEnabled ?? false

    let itn = InverseTextNormalizationStep()
    itn.spokenPunctuation = settings.spokenPunctuationSettings
    itn.backendSupportsLID = settings.backendSupportsLanguageDetection

    return LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: wordCorrection,
      learnedWordCheck: learnedWordCheck,
      fillerRemoval: fillerRemoval,
      emojiFormatter: emojiFormatter,
      inverseTextNormalization: itn,
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: llmPolish,
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep(), casualEnding: casualEnding)
  }
}

/// Why a part could not run at all, as distinct from a part that ran and could
/// not be polished.
package enum FileImportRunnerError: Error, Equatable, Sendable {
  /// `process` was called before `freeze`. A programming error, not a user one.
  case notConfigured
}
