import Foundation

// MARK: - What one take's AI polish met (#3438)

/// The AI polish setup a take started under, frozen at recording start: the provider and the
/// model the take asks for, the warning owner's configuration revision, and the warning
/// episode it was in (nil when no warning was open). Content-free values only.
public struct PolishSetupTakeContext: Sendable, Equatable {
  public let provider: LLMProvider
  public let model: String
  public let configurationRevision: UInt64
  public let episode: UInt64?

  public init(
    provider: LLMProvider, model: String, configurationRevision: UInt64, episode: UInt64?
  ) {
    self.provider = provider
    self.model = model
    self.configurationRevision = configurationRevision
    self.episode = episode
  }
}

/// What the polish step met that could mean its setup is unfinished. Read from typed errors
/// only, never from a message. Evidence is not a verdict: the app decides whether it confirms a
/// setup problem for the take's provider.
public enum PolishSetupEvidence: String, Sendable, Equatable, CaseIterable {
  /// The cloud key was not in the Keychain (`errSecItemNotFound`) or no key slot is configured.
  case cloudKeyMissing
  /// The Keychain did not answer. Unknown, never missing.
  case cloudKeyUnreadable
  /// The provider rejected the key in its own typed answer (`LLMError.invalidAPIKey`).
  case cloudKeyRejected
  /// A rejection classified by the connector (`.classified(.apiKeyRejected)`). For OpenAI and
  /// Claude that is HTTP 401 alone; for Gemini it is a rejection read from body text, which
  /// does not confirm anything.
  case cloudKeyRejectedClassified
  /// EG-1 or S1-mini was not ready to run.
  case localEngineNotReady
  /// EG-1 or S1-mini is waiting on a download.
  case localEngineDownloadPending
  /// The Ollama check before the request found no server.
  case ollamaUnreachable
  /// The Ollama check found the chosen model missing.
  case ollamaModelUnavailable
  /// No Ollama model is chosen.
  case ollamaNoModel
}

/// A confirmed, actionable setup problem: the `polish_setup_problem` value on
/// `dictation.terminal`. Closed and provider-free (the take's provider is on its own row).
public enum PolishSetupProblemTag: String, Sendable, Equatable, CaseIterable {
  case cloudKeyMissing = "cloud_key_missing"
  case cloudKeyRejected = "cloud_key_rejected"
  case ollamaNotInstalled = "ollama_not_installed"
  case ollamaNotRunning = "ollama_not_running"
  case ollamaNoModel = "ollama_no_model"
  case ollamaModelNotInstalled = "ollama_model_not_installed"
  case localNotDownloaded = "local_not_downloaded"
  case localDownloadPaused = "local_download_paused"
  case localUpdatePaused = "local_update_paused"
  case localDownloadFailed = "local_download_failed"
}

/// What happened to the take's polish. Closed.
public enum PolishTakeResult: String, Sendable, Equatable, CaseIterable {
  /// Polish was off for this take.
  case notRequested
  /// Polish ran and its text was used.
  case polished
  /// The step chose not to call the model (for example a very short dictation).
  case bypassed
  /// Polish did not run, quietly (silent skip classes).
  case skippedSilently
  /// Polish did not run and the person was told it was skipped.
  case skippedWithNotice
  /// Polish failed and the person was told.
  case failed
  /// A torn-down request; nothing to tell.
  case cancelled
}

/// One take's polish outcome: produced once, when the polish step's result is classified, and
/// never rewritten by a later repair, acknowledgement or presentation.
public struct PolishTakeOutcome: Sendable, Equatable {
  public let takeID: String
  public let context: PolishSetupTakeContext
  public let result: PolishTakeResult
  public let evidence: PolishSetupEvidence?
  /// Set only when the app confirmed the evidence as an unfinished setup at classification.
  public let setupProblem: PolishSetupProblemTag?
  /// When the take observed what its evidence or result says (monotonic), stamped where it was
  /// observed: the saved-key read, Ollama's own check, or the provider's answer. Falls back to
  /// when the polish step began.
  public let observedAt: ContinuousClock.Instant
  /// When the request handed to a cloud connector read the saved key (the connector's first
  /// step); nil when no request was made. A request the provider answered, or rejected, carried
  /// a saved key at this moment.
  public let keyReadAt: ContinuousClock.Instant?

  public init(
    takeID: String, context: PolishSetupTakeContext, result: PolishTakeResult,
    evidence: PolishSetupEvidence?, setupProblem: PolishSetupProblemTag?,
    observedAt: ContinuousClock.Instant, keyReadAt: ContinuousClock.Instant? = nil
  ) {
    self.takeID = takeID
    self.context = context
    self.result = result
    self.evidence = evidence
    self.setupProblem = setupProblem
    self.observedAt = observedAt
    self.keyReadAt = keyReadAt
  }
}
