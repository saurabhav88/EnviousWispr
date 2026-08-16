import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import EnviousWisprServices
import EnviousWisprWhisperPreviewAdapter
import Foundation

/// The ONLY place delivery is joined to the Live Preview universal engine
/// (#2108, epic #2077 chunk 4).
///
/// Mirrors `WhisperKitDeliveryWiring`: the app shell owns composition, and the
/// adapter owns behaviour.
///
/// **What crosses the boundary is answers, never capabilities.** The adapter
/// receives immutable identity and paths plus two closures that answer questions
/// — it is handed neither `ModelDeliveryHome`, nor `ModelDeliveryController`, nor
/// any fetch-capable handle. So "the preview cannot start a 217 MB download" is
/// a structural property rather than a rule someone has to remember. The only
/// dependency edge this creates is AppKit to Adapter; the adapter never imports
/// AppKit.
@MainActor
enum WhisperPreviewDeliveryWiring {

  /// Build the preview engine's route, or nil when the bundled manifest failed to
  /// load — the same can't-happen-in-release condition the sibling registrations
  /// guard, and the same honest answer: no route means the engine reports
  /// not-installed rather than guessing.
  static func makeRoute(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager
  ) -> LivePreviewEngineRoute? {
    guard let registration = modelDelivery.whisperPreviewRegistration else { return nil }

    guard
      let tokenizerDirectory = Bundle.main.url(
        forResource: "WhisperPreviewTokenizer", withExtension: nil)
    else {
      // No tokenizer, no engine. Refusing here is deliberate: WhisperKit's
      // tokenizer search runs independently of `download: false`, so a nil
      // folder can reach the network, and the app's other bundled tokenizer is
      // large-v3 and would load the WRONG vocabulary silently. Both measured.
      // A missing bundled resource is a build defect, and the honest response is
      // to have no engine rather than a subtly wrong one.
      return nil
    }

    let controller = modelDelivery.controller
    let identity = registration.manifest.identity

    let environment = WhisperPreviewEngineResolver.Environment(
      // Identity + digest, so a revision bump or a re-authored manifest
      // invalidates a prepared engine instead of serving weights we no longer
      // ship.
      artifactIdentity: "\(identity.cacheKey)@\(registration.manifest.manifestDigest.prefix(12))",
      modelDirectory: registration.installDirectory,
      tokenizerDirectory: tokenizerDirectory,
      variant: identity.variant,
      isAdmitted: { await controller.isAdmitted(registration) },
      isHeartStreaming: {
        await MainActor.run { Self.heartIsStreaming(settings: settings) }
      })

    return WhisperPreviewEngineResolver.route(environment)
  }

  /// Whether the transcription engine is itself decoding continuously right now.
  ///
  /// **Measured, not precautionary (#2108 Gate C).** Two models resident together
  /// cost the heart nothing; both DECODING together cost it 50% — 591ms to 885ms
  /// against a 591-626ms repeat-to-repeat envelope.
  ///
  /// The condition mirrors `WhisperKitEngineAdapter`'s own streaming gate: the
  /// authoritative streaming session starts when the toggle is on AND the
  /// language is locked. With `.auto` that adapter falls back to batch, which
  /// decodes after the recording ends rather than throughout it — no continuous
  /// overlap, so no refusal.
  ///
  /// Read live rather than snapshotted because this is asked at the START of each
  /// recording, which is exactly when the answer must be current.
  static func heartIsStreaming(settings: SettingsManager) -> Bool {
    guard settings.useStreamingASR else { return false }
    switch settings.languageMode {
    case .auto: return false
    case .locked: return true
    }
  }
}
