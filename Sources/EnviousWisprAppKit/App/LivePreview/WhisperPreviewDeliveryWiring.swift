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

  /// Whether a universal route can be composed in this build at all — the same
  /// answer `makeRoute` gives, asked without building anything.
  ///
  /// The UI needs this answer BEFORE it offers a control: an engine that cannot
  /// run must not enable the toggle or offer a Download.
  ///
  /// #3735: false until the transcribe.cpp preview session lands (Chunk 9). The
  /// WhisperKit preview runtime is disconnected because the migration retires its
  /// model folder; the GGUF model may already be downloading or admitted, and that
  /// must not read as a preview that can run.
  static func isComposable(modelDelivery: ModelDeliveryHome) -> Bool {
    false
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
  /// #3735: always nil until Chunk 9 composes the transcribe.cpp preview route over
  /// `modelDelivery.whisperPreviewRegistration` (the GGUF); see `isComposable`.
  static func makeRoute(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager
  ) -> LivePreviewEngineRoute? {
    nil
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
  /// WhisperKit-adapter-specific: the KERNEL sets
  /// `shouldStream = config.useStreamingASR && adapter.capabilities.supportsStreaming`
  /// with no language term at all (`RecordingSessionKernel.swift:1397`), and
  /// Parakeet advertises `supportsStreaming: true`
  /// (`ParakeetEngineAdapter.swift:288`) and begins streaming regardless of
  /// language mode. WhisperKit is the engine that degrades to batch on `.auto`.
  ///
  /// So on Parakeet + streaming + Auto the heart IS decoding continuously, and
  /// the earlier predicate returned false — permitting exactly the contention
  /// this gate exists to prevent. Cloud review caught it.
  ///
  /// Read live rather than snapshotted because this is asked at the START of each
  /// recording, which is exactly when the answer must be current.
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
