import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import EnviousWisprServices
import EnviousWisprWhisperPreviewAdapter
import Foundation

/// The ONLY place delivery is joined to the Live Preview universal engine
/// (#2108, epic #2077 chunk 4).
///
/// Mirrors `WhisperDeliveryWiring`: the app shell owns composition, and the
/// adapter owns behaviour.
///
/// **What crosses the boundary is answers, never capabilities.** The adapter
/// receives immutable identity and paths plus two closures that answer questions
/// — it is handed neither `ModelDeliveryHome`, nor `ModelDeliveryController`, nor
/// any fetch-capable handle. So "the preview cannot start a model download" is
/// a structural property rather than a rule someone has to remember. The only
/// dependency edge this creates is AppKit to Adapter; the adapter never imports
/// AppKit.
@MainActor
enum WhisperPreviewDeliveryWiring {

  /// Whether a universal route can be composed in this build at all: the same
  /// answer `makeRoute` gives, asked without building anything.
  ///
  /// The UI needs this answer BEFORE it offers a control: an engine that cannot
  /// run must not enable the toggle or offer a Download.
  static func isComposable(modelDelivery: ModelDeliveryHome) -> Bool {
    modelPath(modelDelivery.whisperPreviewRegistration) != nil
  }

  /// Where the admitted model file lives: the manifest's entrypoint in its install
  /// directory, or nil when this build registered no preview model (a build defect).
  /// The one authority both `isComposable` and `makeRoute` read.
  private static func modelPath(_ registration: DeliveryRegistration?) -> String? {
    guard let registration, let entrypoint = registration.manifest.resolvedEntrypointPath
    else { return nil }
    return registration.installDirectory.appendingPathComponent(entrypoint).path
  }

  /// Build the preview engine's route, or nil when this build cannot compose one.
  ///
  /// **Nil means UNAVAILABLE IN THIS BUILD, not not-installed** (#2123). The
  /// caller renders `engineUnavailableInThisBuild`, which offers no user remedy,
  /// because there is none: no download can supply an engine this build cannot
  /// run. Reporting not-installed would send someone to a button that cannot
  /// help, and falling back to Apple would make the chosen card and the running
  /// engine disagree.
  ///
  /// #3735: the route decodes the transcribe.cpp whisper-small GGUF registered as
  /// `modelDelivery.whisperPreviewRegistration`.
  static func makeRoute(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager
  ) -> LivePreviewEngineRoute? {
    environment(modelDelivery: modelDelivery, settings: settings).map(
      WhisperPreviewEngineResolver.route)
  }

  /// #3973: EnviousMeet's Universal route over the same artifact, admission and heart check
  /// (`WhisperPreviewEngineResolver.resolveForMeeting`). Unavailable in this build answers as
  /// `makeRoute`'s nil does.
  static func makeMeetingResolver(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager
  ) -> @Sendable (LanguageMode) async -> MeetingLiveWords.UniversalResolution {
    guard let environment = environment(modelDelivery: modelDelivery, settings: settings) else {
      return { _ in .blocked(.engineUnavailableInThisBuild) }
    }
    return meetingResolver(environment)
  }

  /// #4105: whether the Universal model is downloaded and admitted, for the meeting live words
  /// choice. False in a build with no Universal registration.
  static func makeUniversalAdmitted(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager
  ) -> @Sendable () async -> Bool {
    guard let environment = environment(modelDelivery: modelDelivery, settings: settings) else {
      return { false }
    }
    return environment.isAdmitted
  }

  /// The meeting route over one environment, as `MeetingLiveWords` consumes it.
  static func meetingResolver(
    _ environment: WhisperPreviewEngineResolver.Environment
  ) -> @Sendable (LanguageMode) async -> MeetingLiveWords.UniversalResolution {
    { mode in
      switch await WhisperPreviewEngineResolver.resolveForMeeting(mode, environment: environment) {
      case .ready(let candidate):
        return .ready(makeEngine: { admit in candidate.makeEngine(admitTranscriptDecode: admit) })
      case .blocked(let reason):
        return .blocked(reason)
      }
    }
  }

  private static func environment(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager
  ) -> WhisperPreviewEngineResolver.Environment? {
    guard let registration = modelDelivery.whisperPreviewRegistration,
      let modelPath = modelPath(registration)
    else { return nil }

    let controller = modelDelivery.controller
    let identity = registration.manifest.identity

    let environment = WhisperPreviewEngineResolver.Environment(
      // Identity + digest, so a revision bump or a re-authored manifest
      // invalidates a prepared engine instead of serving weights we no longer
      // ship.
      artifactIdentity: "\(identity.cacheKey)@\(registration.manifest.manifestDigest.prefix(12))",
      modelPath: modelPath,
      isAdmitted: { await controller.isAdmitted(registration) },
      isHeartStreaming: {
        await MainActor.run { Self.heartIsStreaming(settings: settings) }
      })
    return environment
  }

  /// Whether the transcription engine is itself decoding continuously right now.
  ///
  /// **Measured, not precautionary (#2108 Gate C).** Two models resident together
  /// cost the heart nothing; both DECODING together cost it 50% — 591ms to 885ms
  /// against a 591-626ms repeat-to-repeat envelope.
  ///
  /// **The condition is per-BACKEND, and an earlier version got that wrong.** It
  /// mirrored `WhisperEngineAdapter`'s gate — toggle on AND language locked —
  /// and applied it to both engines. But that language condition is
  /// Whisper-adapter-specific: the KERNEL sets
  /// `shouldStream = config.useStreamingASR && adapter.capabilities.supportsStreaming`
  /// with no language term at all (`RecordingSessionKernel.swift:1858` at aed04f9c), and
  /// Parakeet advertises `supportsStreaming: true`
  /// (`ParakeetEngineAdapter.swift:289`) and begins streaming regardless of
  /// language mode. Whisper is the engine that degrades to batch on `.auto`.
  ///
  /// So on Parakeet + streaming + Auto the heart IS decoding continuously, and
  /// the earlier predicate returned false — permitting exactly the contention
  /// this gate exists to prevent. Cloud review caught it.
  ///
  /// Read live rather than snapshotted because this is asked at the START of each
  /// recording, which is exactly when the answer must be current.
  /// #3973: a meeting's Universal decode waits only while a dictation is under way and
  /// dictation's engine streams through it. `heartIsStreaming` alone describes the setting, so
  /// on its own it would keep a meeting's live words blank while nobody dictates.
  static func meetingDecodeMustWait(settings: SettingsManager, dictationActive: Bool) -> Bool {
    dictationActive && heartIsStreaming(settings: settings)
  }

  static func heartIsStreaming(settings: SettingsManager) -> Bool {
    guard settings.useStreamingASR else { return false }
    switch settings.selectedBackend {
    case .parakeet:
      // No language condition: the adapter streams whenever the toggle is on.
      return true
    case .whisper:
      // Degrades to batch on `.auto`, which decodes AFTER the recording rather
      // than throughout it — no continuous overlap, so no refusal.
      switch settings.languageMode {
      case .auto: return false
      case .locked: return true
      }
    }
  }
}
