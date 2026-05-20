import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// Root observable state for the application.
///
/// PR-C.1 of #763 — AppState is now **receive-only**. Construction of every
/// subsystem and all init-time wiring moved to `EnviousWisprApp.init()` (the
/// composition root). AppState's init only stores the references it is handed;
/// it constructs nothing and wires nothing. It stays `@Environment`-injected so
/// the not-yet-migrated views keep working unchanged. PR-C.2 / PR-C.3 migrate
/// those views off `@Environment(AppState.self)`; PR-C.4 deletes this file.
///
/// The `let`/`var` split of the stored properties is unchanged from pre-PR-C.1
/// on purpose: `AppStateCeilingsTests` counts only `let` collaborators and must
/// stay green until PR-C.4 removes it. `var settings`, the four `attach`-set
/// outlets, and `var isRecordingLocked` stay `var`.
@MainActor
@Observable
final class AppState {
  var settings: SettingsManager
  let permissions: PermissionsService
  let audioCapture: any AudioCaptureInterface
  let asrManager: any ASRManagerInterface
  let keychainManager: KeychainManager
  let recordingOverlay: RecordingOverlayPanel
  let setup: SetupCoordinator
  let audioDeviceList: AudioDeviceList
  let captureTelemetry: CaptureTelemetryState
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline

  /// Standalone service for re-polishing saved transcripts from the detail view.
  let polishService: TranscriptPolishService

  /// Forwards settings changes to pipelines and subsystems.
  let settingsSync: PipelineSettingsSync

  /// True when recording is in hands-free (locked) mode via double-press.
  /// Read by the overlay. Written through PR9's `RecordingLockedAccess` get/set
  /// struct. PR-C.3 of #763 rehomes this onto `LiveRecordingState`.
  var isRecordingLocked: Bool = false

  // Feature #8: custom word management.
  let customWordsCoordinator: CustomWordsCoordinator

  /// Broadcasts custom-words changes to all registered consumers.
  let customWordsPropagator: CustomWordsPropagator

  // Model discovery.
  let llmDiscovery: LLMModelDiscoveryCoordinator

  // Apple Intelligence availability.
  let aiAvailability: AIAvailabilityCoordinator

  /// PR4 of #763 — chip presenter, setter-injected by `EnviousWisprApp` after
  /// both AppState and the presenter exist.
  private(set) var languageSuggestionPresenter: LanguageSuggestionPresenter?
  func attachLanguageSuggestionPresenter(_ presenter: LanguageSuggestionPresenter) {
    self.languageSuggestionPresenter = presenter
  }

  /// PR7 of #763 — App-owned home for live dictation facts. Setter-injected.
  private(set) var liveRecordingState: LiveRecordingState?
  func attachLiveRecordingState(_ state: LiveRecordingState) {
    self.liveRecordingState = state
  }

  /// PR7 of #763 — App-owned home for post-recording polish error state.
  private(set) var lastRecordingResult: LastRecordingResult?
  func attachLastRecordingResult(_ result: LastRecordingResult) {
    self.lastRecordingResult = result
  }

  /// PR7 of #763 — App-owned home for backend display labels. Setter-injected.
  private(set) var backendMetadata: BackendMetadata?
  func attachBackendMetadata(_ metadata: BackendMetadata) {
    self.backendMetadata = metadata
  }

  /// Receive-only initializer (PR-C.1 of #763). Every subsystem is constructed
  /// and wired by `EnviousWisprApp.init()`; AppState stores the references and
  /// does nothing else. No construction, no wiring, no `Task`, no side effects.
  init(
    settings: SettingsManager,
    permissions: PermissionsService,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    keychainManager: KeychainManager,
    recordingOverlay: RecordingOverlayPanel,
    setup: SetupCoordinator,
    audioDeviceList: AudioDeviceList,
    captureTelemetry: CaptureTelemetryState,
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    polishService: TranscriptPolishService,
    settingsSync: PipelineSettingsSync,
    customWordsCoordinator: CustomWordsCoordinator,
    customWordsPropagator: CustomWordsPropagator,
    llmDiscovery: LLMModelDiscoveryCoordinator,
    aiAvailability: AIAvailabilityCoordinator
  ) {
    self.settings = settings
    self.permissions = permissions
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.keychainManager = keychainManager
    self.recordingOverlay = recordingOverlay
    self.setup = setup
    self.audioDeviceList = audioDeviceList
    self.captureTelemetry = captureTelemetry
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline
    self.polishService = polishService
    self.settingsSync = settingsSync
    self.customWordsCoordinator = customWordsCoordinator
    self.customWordsPropagator = customWordsPropagator
    self.llmDiscovery = llmDiscovery
    self.aiAvailability = aiAvailability
  }
}

// MARK: - DictationActivityProviding

extension AppState: DictationActivityProviding {
  /// True when either pipeline is actively recording, transcribing, or polishing.
  /// Used by TranscriptPolishService to prevent concurrent re-polish + live dictation.
  var isDictationActive: Bool {
    pipeline.state.isActive || whisperKitPipeline.state.isActive
  }
}

extension WhisperKitPipelineState {
  /// One authoritative mapping from WhisperKit's 9-state enum to unified PipelineState.
  var asPipelineState: PipelineState {
    switch self {
    case .idle, .ready: return .idle
    case .startingUp, .loadingModel: return .loadingModel
    case .recording: return .recording
    case .transcribing: return .transcribing
    case .polishing: return .polishing
    case .complete: return .complete
    case .error(let msg): return .error(msg)
    }
  }
}
