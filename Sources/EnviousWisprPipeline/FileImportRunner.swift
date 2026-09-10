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
    public let polishError: String?
    /// Whether a polisher was asked for this part. Defaults to true so every
    /// existing construction keeps meaning what it meant.
    private let polishAttempted: Bool

    public init(
      text: String, polishedText: String?, polishError: String?, polishAttempted: Bool = true
    ) {
      self.text = text
      self.polishedText = polishedText
      self.polishError = polishError
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

  /// **One import, one configuration.** Frozen when the run starts and applied
  /// identically to every part, so a user who changes their polisher halfway
  /// through does not get a document polished two different ways. Reuses
  /// `RecordingSettingsSnapshot` rather than declaring a parallel type: it is
  /// already the single authority for "the settings a text-processing run
  /// needs", and a second one would be a second thing to keep in step.
  private var frozenSettings: RecordingSettingsSnapshot?

  /// The custom-words vocabulary, frozen with the settings for the same reason.
  private var frozenVocabulary: CorrectorVocabulary?

  public init(
    keychainManager: KeychainManager,
    egOneRuntime: (any EGOneEndpointProviding)? = nil,
    s1MiniRuntime: (any EGOneEndpointProviding)? = nil,
    outputClassifierHolder: OutputClassifierHolder? = nil
  ) {
    self.keychainManager = keychainManager
    self.egOneRuntime = egOneRuntime
    self.s1MiniRuntime = s1MiniRuntime
    self.outputClassifierHolder = outputClassifierHolder
  }

  /// Freezes the configuration this import runs under. Called once, before the
  /// first part.
  public func freeze(settings: RecordingSettingsSnapshot, vocabulary: CorrectorVocabulary?) {
    frozenSettings = settings
    frozenVocabulary = vocabulary
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
  public func process(part: String) async throws -> PartOutcome {
    guard let settings = frozenSettings else {
      throw FileImportRunnerError.notConfigured
    }
    try Task.checkCancellation()

    let steps = makeSteps(settings: settings)
    let runner = TextProcessingRunner(telemetry: .silent)
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
        engineReportedLanguage: nil),
      // No target app: an import is not being pasted anywhere, and a step that
      // adapts to the frontmost app would be adapting to whatever the user
      // happened to have open while the file decoded.
      targetAppName: nil,
      steps: steps.orderedChainForFileImport)

    // The user pressed Stop while this part was in flight. The runner will have
    // returned the deterministic floor rather than propagating, which is right
    // for a dictation and wrong here.
    try Task.checkCancellation()

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
      text: context.text, polishedText: polished, polishError: result.polishError,
      // **Read from the frozen configuration, not from the outcome.** Whether a
      // polisher was ASKED is a property of the run's settings; whether it
      // ANSWERED is a property of this part. Deriving the first from the second
      // is what let a deliberately-unpolished document accuse the app of
      // failing.
      polishAttempted: LLMProvider(rawValue: settings.llmProvider).map { $0 != .none } ?? false)
  }

  /// Builds this part's own step instances and applies the frozen settings.
  private func makeSteps(settings: RecordingSettingsSnapshot) -> LimbSteps {
    let llmPolish = LLMPolishStep(keychainManager: keychainManager, telemetry: .silent())
    // Standalone, exactly like the recovery replay: no live kernel is attached,
    // so there is nothing to stream tokens to and no lifecycle to notify.
    llmPolish.onWillProcess = nil
    llmPolish.onToken = nil
    llmPolish.outputClassifierHolder = outputClassifierHolder
    llmPolish.egOneRuntime = egOneRuntime
    llmPolish.s1MiniRuntime = s1MiniRuntime
    llmPolish.llmProvider = LLMProvider(rawValue: settings.llmProvider) ?? .none
    llmPolish.llmModel = LLMProvider.replacingRetiredModel(
      settings.llmModel, for: llmPolish.llmProvider)
    llmPolish.backend = settings.backendType
    llmPolish.s1Control = settings.s1Control ?? .default
    llmPolish.languageDetection = nil

    let wordCorrection = WordCorrectionStep()
    wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    if let frozenVocabulary { wordCorrection.correctorVocabulary = frozenVocabulary }

    let fillerRemoval = FillerRemovalStep()
    fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled

    let emojiFormatter = EmojiFormatterStep()
    emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled

    let itn = InverseTextNormalizationStep()
    itn.spokenPunctuationEnabled = settings.spokenPunctuationEnabled ?? false
    itn.backendSupportsLID = settings.backendSupportsLanguageDetection

    return LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: wordCorrection,
      fillerRemoval: fillerRemoval,
      emojiFormatter: emojiFormatter,
      inverseTextNormalization: itn,
      llmPolish: llmPolish,
      emojiRestore: EmojiRestoreStep())
  }
}

/// Why a part could not run at all, as distinct from a part that ran and could
/// not be polished.
public enum FileImportRunnerError: Error, Equatable, Sendable {
  /// `process` was called before `freeze`. A programming error, not a user one.
  case notConfigured
}
