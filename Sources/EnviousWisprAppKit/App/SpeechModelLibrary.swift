import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation

/// Reports, installs and removes the speech engine models on this Mac (#4578).
///
/// One app-owned instance, built by the bootstrapper. Settings, Setup and the jobs that need a
/// speech engine reach the models through it instead of each asking a delivery handle or a
/// setup service on its own. It owns no bytes: the delivery handles, the Whisper setup service
/// and the Parakeet upgrade coordinator stay the owners of their mechanics; this type is the one
/// place that decides which of them a speech-model command or question goes to.
@MainActor
final class SpeechModelLibrary {
  /// The Whisper parts the removal command drives, attached once `WhisperDeliveryWiring` has
  /// built them (the wiring needs this library's removal command first).
  struct WhisperParts {
    let setupService: WhisperSetupService
    let migration: WhisperModelMigration
    let removal: WhisperRemovalHook
  }

  /// The answer to a download request: refused, accepted (its end is observed later), or
  /// answered once the attempt ended.
  enum DownloadRequest: Sendable {
    case refused
    case accepted
    case ended(ModelDeliveryController.DeliveryOutcome)
  }

  private let modelDelivery: ModelDeliveryHome
  private var whisper: WhisperParts?

  init(modelDelivery: ModelDeliveryHome) {
    self.modelDelivery = modelDelivery
  }

  func attachWhisper(_ parts: WhisperParts) {
    whisper = parts
  }

  // MARK: - Delivery facts

  /// Whether this engine's delivery kill switch allows a download now, read fresh.
  func isDeliveryEnabled(_ engine: ASRBackendType) -> Bool {
    switch engine {
    case .parakeet: modelDelivery.parakeetHandle?.isEnabled() ?? false
    case .whisper: modelDelivery.whisperHandle?.isEnabled() ?? false
    }
  }

  /// Setup's installed question. Parakeet's answer is recorded in `parakeetAdmission` under the
  /// delivery key read before the await, for Setup's synchronous phase.
  func isInstalledForSetup(
    _ engine: ASRBackendType, parakeetAdmission: OnboardingParakeetAdmission
  ) async -> Bool {
    switch engine {
    case .parakeet: return await parakeetAdmission.read(modelDelivery)
    case .whisper: return await modelDelivery.whisperHandle?.isAdmitted() ?? false
    }
  }

  // MARK: - Commands

  /// Starts this engine's download through the same door Settings uses. Parakeet answers once
  /// the attempt ended; Whisper's task answers acceptance only.
  func requestDownload(_ engine: ASRBackendType) async -> DownloadRequest {
    switch engine {
    case .parakeet:
      guard let attempt = modelDelivery.resumeParakeetDownload() else { return .refused }
      switch await attempt.value {
      case .refused: return .refused
      case .attempted(let outcome): return .ended(outcome)
      }
    case .whisper:
      guard let setupService = whisper?.setupService else { return .refused }
      return await setupService.downloadModel().value ? .accepted : .refused
    }
  }

  func cancelDownload(_ engine: ASRBackendType) {
    switch engine {
    case .parakeet: modelDelivery.cancelParakeetDownload()
    case .whisper: whisper?.setupService.cancelDownload()
    }
  }

  /// The Whisper setup service's Remove action over `library`, held weakly. nil is success, so a
  /// gone library fails explicitly instead of through `?? .failed` (which would turn a completed
  /// removal into a failure).
  static func whisperRemoveAction(_ library: SpeechModelLibrary)
    -> @MainActor () async -> WhisperRemoveNotice?
  {
    { [weak library] in
      guard let library else { return .failed }
      return await library.removeWhisperModel()
    }
  }

  /// Remove: record the decline, stop any fetch, unload the engine, then delete. The
  /// dictation-in-flight refusal already happened in the presentation layer
  /// (`WhisperSetupService.removeModel`).
  func removeWhisperModel() async -> WhisperRemoveNotice? {
    guard let handle = modelDelivery.whisperHandle, let whisper else { return .failed }
    guard whisper.migration.decline(.dictation) == .done else { return .failed }
    await handle.cancelActiveFetch()
    await whisper.removal.unloadForRemoval()
    let removed = await handle.remove()
    await whisper.removal.finishRemoval()
    return removed ? nil : .failed
  }
}
