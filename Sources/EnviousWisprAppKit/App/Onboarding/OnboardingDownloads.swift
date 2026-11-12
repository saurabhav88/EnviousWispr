import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import EnviousWisprServices
import Foundation

/// What a download START returned (#4528 plan §3.4, M6). A request is never completion: the
/// download's progress and result are read afterwards from its owner (`OnboardingDownloadPhase`).
enum OnboardingStartAnswer: Equatable, Sendable {
  /// The owner accepted the request and said so itself (Parakeet answers when its attempt has
  /// run; Whisper and the local runtimes when the start is accepted). Progress and the result
  /// are read from the owner's state.
  case requested
  /// Already on this Mac; nothing was downloaded.
  case alreadyInstalled
  /// Refused before any work (the family's delivery kill switch is off, or the owner did not
  /// accept the start). Setup shows "Download unavailable" with Retry.
  case refused
  /// Apple Intelligence, a cloud key or polish off: there is nothing to download.
  case noDownload
  /// The task was cancelled or the person picked another engine while this start waited, so
  /// nothing was requested for the old pick (plan M49).
  case superseded
}

/// A start's answer, tagged with the pick it was made for, so the coordinator can drop the
/// answer of a pick the person has since changed.
struct OnboardingStart<ID: Equatable & Sendable>: Equatable, Sendable {
  let id: ID
  let answer: OnboardingStartAnswer
  /// The transfer's end when the owner answers only once its attempt ended (Parakeet), else nil.
  var ended: OnboardingTelemetry.DownloadResult? = nil
}

/// A speech owner's answer to a request (plan M49; the end forwarded for F2b, M68).
enum OnboardingSpeechRequestAnswer: Equatable, Sendable {
  case refused
  /// Accepted; the transfer's end is observed later (Whisper's task answers acceptance only).
  case accepted
  /// Accepted, answered once the attempt ended (Parakeet's `DeliveryOutcome`).
  case ended(OnboardingTelemetry.DownloadResult)
}

/// Why a download failed, in the OWNER's own typed form, so Setup shows the copy those owners
/// already use (`ModelDeliveryCopy` for delivery failures, the local engine card's copy for EG-1
/// and S1-mini) and no new customer wording exists.
enum OnboardingDownloadFailure: Equatable, Sendable {
  case delivery(DeliveryFailure)
  /// Whisper's presentation owner already carries customer copy in its error state.
  case whisper(String)
  case localPolish(EGOneDownloadFailure)
}

/// One model's download as Setup shows it. Read from the owner each time; never stored.
enum OnboardingDownloadPhase: Equatable, Sendable {
  /// The owner has not answered yet whether the model is on this Mac (an upgrade-served
  /// Parakeet before its first read, P1). Never treated as missing: no bytes are counted, no
  /// cancel is sent, Downloads is not finished; the next owner read resolves it.
  case unknown
  case notStarted
  case downloading(fraction: Double?)
  case verifying
  /// On this Mac and verified. Not warm, not loaded: readiness is a separate read.
  case installed
  case paused
  case failed(OnboardingDownloadFailure)
  /// Refused or out of attempts: "Download unavailable" with Retry.
  case unavailable
}

/// Setup's last upgrade-aware answer to "is Parakeet usable" (#4528 P1, plan M70). The owner's
/// answer is async (`ModelDeliveryHome.isParakeetUsable()`) and `parakeetState` mirrors only the
/// BASE registration, which stays `.notReady` on a Mac the Parakeet upgrade serves. Setup's
/// existing reads (readiness and the start path) record each answer with the delivery key read
/// BEFORE the await; a synchronous phase uses it only while that key is still current.
@MainActor
final class OnboardingParakeetAdmission {
  struct Key: Equatable {
    let state: DeliveryState
    let revision: UInt64
  }

  private var answer: (key: Key, usable: Bool)?

  func record(_ usable: Bool, at key: Key) { answer = (key, usable) }

  /// The recorded answer for `key`, or nil when the delivery facts changed since.
  func usable(at key: Key) -> Bool? {
    guard let answer, answer.key == key else { return nil }
    return answer.usable
  }

  /// The current key of `modelDelivery`'s Parakeet facts.
  static func key(_ modelDelivery: ModelDeliveryHome) -> Key {
    Key(state: modelDelivery.parakeetState, revision: modelDelivery.parakeetPresentationRevision)
  }

  /// Reads the owner's answer through the existing call and records it under the pre-await key.
  func read(_ modelDelivery: ModelDeliveryHome) async -> Bool {
    let key = Self.key(modelDelivery)
    let usable = await modelDelivery.isParakeetUsable()
    record(usable, at: key)
    return usable
  }
}

/// The existing owners Setup's downloads go through, as narrow closures (plan §3.4, M6, M22).
/// Production builds them with `live(...)` over ModelDeliveryHome, WhisperSetupService,
/// LocalPolishRuntimeSet and SettingsManager; tests inject the boundary. Setup owns no model
/// bytes, process, retry policy or transfer: those stay with their owners.
@MainActor
struct OnboardingDownloadOwners {
  var speechDeliveryEnabled: (ASRBackendType) -> Bool
  var speechInstalled: (ASRBackendType) async -> Bool
  var writeSelectedBackend: (ASRBackendType) -> Void
  /// The engine currently picked (`settings.selectedBackend`), re-read after every await.
  var selectedBackend: () -> ASRBackendType
  /// The owner's own accept/refuse answer (plan M49); never inferred from calling it.
  var requestSpeech: (ASRBackendType) async -> OnboardingSpeechRequestAnswer
  var cancelSpeech: (ASRBackendType) -> Void
  /// Clears an owner-recorded block (Parakeet's spent attempt budget) before a Retry; false
  /// when the owner refused to clear it.
  var clearSpeechBlock: (ASRBackendType) -> Bool
  var speechPhase: (ASRBackendType) -> OnboardingDownloadPhase

  var writePolishSelection: (LocalPolishModelID) -> Void
  var polishPhase: (LocalPolishModelID) -> OnboardingDownloadPhase
  /// Starts, resumes or retries; false when the runtime did not accept the start.
  var requestPolish: (LocalPolishModelID) -> Bool
  var cancelPolish: (LocalPolishModelID) -> Void
  /// Loads an already-installed model, only while it is still the current pick.
  var activatePolish: (LocalPolishModelID) -> Void
  /// Whether this engine's owner answers a request only once the attempt ended (`.ended`).
  var speechReportsEnd: (ASRBackendType) -> Bool = { _ in false }
}

/// Setup's download operations over the existing owners (#4528 chunk C2a).
@MainActor
struct OnboardingDownloads {
  let owners: OnboardingDownloadOwners

  /// The local model a polish pick downloads, or nil for Apple Intelligence, a cloud key and
  /// polish off. Pick identifiers have one owner, `SetupRules.registeredPolish`.
  static func localModel(forPolish id: String) -> LocalPolishModelID? {
    guard let model = SetupRules.registeredPolish[id] else { return nil }
    switch model.provider {
    case .egOne, .s1Mini: return model
    case .appleIntelligence, .openAI, .gemini, .claude, .ollama, .none: return nil
    }
  }

  // MARK: Speech

  /// Writes the pick FIRST, so the engine owner warms the chosen engine and never an older one
  /// (plan M6), then adopts an installed model or asks its owner for the download.
  func startSpeech(_ engine: ASRBackendType) async -> OnboardingStart<ASRBackendType> {
    owners.writeSelectedBackend(engine)
    let installed = await owners.speechInstalled(engine)
    // The await released the main actor: the person may have picked another engine, or the
    // coordinator cancelled this start. Request nothing for an old pick.
    guard !Task.isCancelled, owners.selectedBackend() == engine else {
      return OnboardingStart(id: engine, answer: .superseded)
    }
    if installed { return OnboardingStart(id: engine, answer: .alreadyInstalled) }
    guard owners.speechDeliveryEnabled(engine) else {
      return OnboardingStart(id: engine, answer: .refused)
    }
    switch await owners.requestSpeech(engine) {
    case .refused: return OnboardingStart(id: engine, answer: .refused)
    case .accepted: return OnboardingStart(id: engine, answer: .requested)
    case .ended(let result): return OnboardingStart(id: engine, answer: .requested, ended: result)
    }
  }

  /// Asks the owner whether the engine's model is on this Mac (for Parakeet this also records
  /// the upgrade-aware answer Setup's phase reads), before an installed-dependent decision.
  func resolveSpeechInstalled(_ engine: ASRBackendType) async -> Bool {
    await owners.speechInstalled(engine)
  }

  /// Whether a request for this engine is answered with the attempt's end.
  func speechReportsEnd(_ engine: ASRBackendType) -> Bool { owners.speechReportsEnd(engine) }

  /// Parakeet's typed attempt outcome as Setup's download result.
  static func result(of outcome: ModelDeliveryController.DeliveryOutcome)
    -> OnboardingTelemetry.DownloadResult
  {
    switch outcome {
    case .admitted: .ok
    case .failed: .failed
    case .cancelled: .cancelled
    }
  }

  func cancelSpeech(_ engine: ASRBackendType) { owners.cancelSpeech(engine) }

  /// Retry: clear the owner's recorded block, then the same start (the owner resumes partial
  /// bytes; single-flight joins a running fetch).
  func retrySpeech(_ engine: ASRBackendType) async -> OnboardingStart<ASRBackendType> {
    guard owners.clearSpeechBlock(engine) else {
      return OnboardingStart(id: engine, answer: .refused)
    }
    return await startSpeech(engine)
  }

  func speechPhase(_ engine: ASRBackendType) -> OnboardingDownloadPhase {
    owners.speechPhase(engine)
  }

  // MARK: Polish

  /// Writes the provider and EG-1 size FIRST, because a runtime activates after download only
  /// when it is the current provider at completion (plan M22). An installed model is loaded
  /// instead of downloaded again. Apple Intelligence, cloud and off start nothing.
  func startPolish(_ id: String) -> OnboardingStart<String> {
    guard let model = Self.localModel(forPolish: id) else {
      return OnboardingStart(id: id, answer: .noDownload)
    }
    owners.writePolishSelection(model)
    if owners.polishPhase(model) == .installed {
      owners.activatePolish(model)
      return OnboardingStart(id: id, answer: .alreadyInstalled)
    }
    return OnboardingStart(id: id, answer: owners.requestPolish(model) ? .requested : .refused)
  }

  /// Nothing to cancel for a pick that downloads nothing.
  func cancelPolish(_ id: String) {
    guard let model = Self.localModel(forPolish: id) else { return }
    owners.cancelPolish(model)
  }

  /// The runtime's one start call is also its retry and resume.
  func retryPolish(_ id: String) -> OnboardingStart<String> { startPolish(id) }

  /// Nil for a pick with no local download.
  func polishPhase(_ id: String) -> OnboardingDownloadPhase? {
    Self.localModel(forPolish: id).map(owners.polishPhase)
  }

  // MARK: Owner state → phase (pure)

  /// `usable` is the owner's upgrade-aware answer for the current delivery key (nil: not
  /// answered for this key yet). A transfer or failure in the mirror is shown as is; an idle or
  /// cancelled mirror reads installed when the owner says Parakeet is usable, and `unknown`
  /// (never missing) until the owner has answered (P1).
  static func phase(parakeet state: DeliveryState, needsExplicitRetry: Bool, usable: Bool?)
    -> OnboardingDownloadPhase
  {
    if needsExplicitRetry { return .unavailable }
    switch (state, usable) {
    case (.notReady, true?), (.cancelled, true?): return .installed
    case (.notReady, nil), (.cancelled, nil): return .unknown
    default: break  // a transfer or failure in the mirror is shown as is
    }
    switch state {
    case .notReady: return .notStarted
    case .preparing: return .downloading(fraction: nil)
    case .downloading(let fraction, _, _): return .downloading(fraction: fraction)
    case .verifying: return .verifying
    case .admitted: return .installed
    case .cancelled(let resumable): return resumable ? .paused : .notStarted
    case .failed(let failure): return .failed(.delivery(failure))
    }
  }

  static func phase(whisper state: WhisperSetupState) -> OnboardingDownloadPhase {
    switch state {
    case .checking, .notDownloaded: return .notStarted
    case .downloading(let progress, _): return .downloading(fraction: progress)
    case .paused: return .paused
    case .ready: return .installed
    case .error(let message): return .failed(.whisper(message))
    }
  }

  static func phase(localPolish state: EGOneInstallState) -> OnboardingDownloadPhase {
    switch state {
    case .notInstalled: return .notStarted
    case .downloading(let fraction, _): return .downloading(fraction: fraction)
    case .verifying: return .verifying
    case .installed: return .installed
    case .paused, .updatePaused: return .paused
    case .failed(.cancelled): return .paused
    case .failed(let failure): return .failed(.localPolish(failure))
    }
  }
}

extension OnboardingDownloadOwners {
  /// The production owners. Each closure is the same door Settings uses, so kill switches,
  /// mutation claims, single-flight joins, verification and activation guards stay where they
  /// are.
  static func live(
    settings: SettingsManager, modelDelivery: ModelDeliveryHome, whisperSetup: WhisperSetupService,
    localPolish: LocalPolishRuntimeSet, parakeetAdmission: OnboardingParakeetAdmission
  ) -> OnboardingDownloadOwners {
    OnboardingDownloadOwners(
      speechDeliveryEnabled: { engine in
        switch engine {
        case .parakeet: modelDelivery.parakeetHandle?.isEnabled() ?? false
        case .whisper: modelDelivery.whisperHandle?.isEnabled() ?? false
        }
      },
      speechInstalled: { engine in
        switch engine {
        case .parakeet: return await parakeetAdmission.read(modelDelivery)
        case .whisper: return await modelDelivery.whisperHandle?.isAdmitted() ?? false
        }
      },
      writeSelectedBackend: { engine in
        if settings.selectedBackend != engine { settings.selectedBackend = engine }
      },
      selectedBackend: { settings.selectedBackend },
      requestSpeech: { engine in
        switch engine {
        case .parakeet:
          guard let attempt = modelDelivery.resumeParakeetDownload() else { return .refused }
          switch await attempt.value {
          case .refused: return .refused
          case .attempted(let outcome): return .ended(OnboardingDownloads.result(of: outcome))
          }
        case .whisper:
          return await whisperSetup.downloadModel().value ? .accepted : .refused
        }
      },
      cancelSpeech: { engine in
        switch engine {
        case .parakeet: modelDelivery.cancelParakeetDownload()
        case .whisper: whisperSetup.cancelDownload()
        }
      },
      clearSpeechBlock: { engine in
        engine == .parakeet ? modelDelivery.retryParakeetUpgradeIfBlocked() : true
      },
      speechPhase: { engine in
        switch engine {
        case .parakeet:
          OnboardingDownloads.phase(
            parakeet: modelDelivery.parakeetState,
            needsExplicitRetry: modelDelivery.parakeetNeedsExplicitRetry,
            usable: parakeetAdmission.usable(at: OnboardingParakeetAdmission.key(modelDelivery)))
        case .whisper: OnboardingDownloads.phase(whisper: whisperSetup.setupState)
        }
      },
      writePolishSelection: { model in
        // Size before provider: activation is keyed on the provider's CURRENT size, so writing
        // the provider first could activate the previously stored size for a moment.
        if let size = model.size, settings.egOneSize != size { settings.selectEGOneSize(size) }
        if settings.llmProvider != model.provider { settings.llmProvider = model.provider }
      },
      polishPhase: { model in
        guard let runtime = localPolish.runtime(for: model) else { return .unavailable }
        return OnboardingDownloads.phase(localPolish: runtime.installState)
      },
      requestPolish: { model in
        guard let runtime = localPolish.runtime(for: model),
          runtime.installState.acceptsDownloadStart
        else { return false }
        runtime.startDownload()
        return true
      },
      cancelPolish: { model in localPolish.runtime(for: model)?.cancelDownload() },
      activatePolish: { model in
        // `activateAndProbe` itself does not check the current provider; this does, so an
        // older pick is never loaded over the current one.
        guard settings.polishModelID(for: settings.llmProvider) == model else { return }
        localPolish.runtime(for: model)?.activateAndProbe()
      },
      // Parakeet's request answers with the attempt's `DeliveryOutcome`; Whisper's only accepts.
      speechReportsEnd: { $0 == .parakeet })
  }
}
