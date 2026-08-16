import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLivePreview
import Foundation

/// Answers "can the universal model preview this recording, and with what"
/// (#2108, epic #2077 chunk 4).
///
/// Mirrors `ApplePreviewEngineResolver`, and differs in exactly the ways the two
/// engines differ: no OS floor, one artifact instead of per-language packs, and
/// its own language detection.
package enum WhisperPreviewEngineResolver {

  /// Everything the resolver needs from layers it must not import.
  ///
  /// The adapter cannot reach ModelDelivery's controller or the recording
  /// pipeline — by design, so a display limb cannot start a download or touch the
  /// heart. It receives ANSWERS instead: immutable identity, paths, and two
  /// questions someone else can answer.
  package struct Environment: Sendable {
    /// Stable artifact identity, folded into the engine key so a revision or
    /// digest change invalidates a prepared engine rather than serving stale
    /// weights from a model that is no longer the one we ship.
    package let artifactIdentity: String
    package let modelDirectory: URL
    package let tokenizerDirectory: URL
    package let variant: String
    /// Has delivery admitted the artifact. Never a download trigger.
    package let isAdmitted: @Sendable () async -> Bool
    /// Is the transcription engine itself decoding continuously right now.
    package let isHeartStreaming: @Sendable () async -> Bool

    package init(
      artifactIdentity: String,
      modelDirectory: URL,
      tokenizerDirectory: URL,
      variant: String,
      isAdmitted: @escaping @Sendable () async -> Bool,
      isHeartStreaming: @escaping @Sendable () async -> Bool
    ) {
      self.artifactIdentity = artifactIdentity
      self.modelDirectory = modelDirectory
      self.tokenizerDirectory = tokenizerDirectory
      self.variant = variant
      self.isAdmitted = isAdmitted
      self.isHeartStreaming = isHeartStreaming
    }
  }

  /// The engine as the app shell consumes it: one value carrying both halves, so
  /// the pill's geometry check and the recording's resolution can never be wired
  /// from different sources.
  package static func route(_ environment: Environment) -> LivePreviewEngineRoute {
    LivePreviewEngineRoute(
      isSupportedOnThisSystem: { true },
      resolve: { mode in await resolve(mode, environment: environment) }
    )
  }

  /// **Always true, and that is the entire point of this engine.** Apple's needs
  /// macOS 26; this one runs on the whole supported range, which is what makes
  /// the preview real for the older half of it. Anything that can change while
  /// the app runs — whether the model is downloaded — belongs in `resolve`, not
  /// here.
  package static let isSupportedOnThisSystem = true

  package static func resolve(
    _ mode: LanguageMode, environment: Environment
  ) async -> LivePreviewEngineResolution {
    // Ordered by cost and by blast radius, cheapest and most consequential
    // first.
    //
    // (1) Contention BEFORE admission, because it is the answer that holds even
    // if the model is installed. Gate C measured both models decoding together
    // at 1.50x heart latency (591ms to 885ms against a 591-626ms envelope), and
    // the heart streams throughout a recording when live transcription is on
    // with a locked language. Refusing is deliberate: taking a lock the heart
    // would await is the one fix the plan forbids, because a display limb must
    // never be able to stall transcription.
    if await environment.isHeartStreaming() {
      return .blocked(.heartIsStreaming)
    }

    // (2) Admission. Asks delivery, never the filesystem, and never starts a
    // fetch — downloading is the user's decision, behind the engine picker.
    guard await environment.isAdmitted() else {
      return .blocked(.modelNotInstalled)
    }

    // (3) Language. This engine detects language itself, so `.auto` stays nil
    // with detection ON rather than inheriting Apple's system-locale guess.
    // Handing engines a pre-resolved language would bake one engine's limitation
    // into the feature — which is why the resolver takes the SETTING, not a
    // language.
    let language: String?
    switch mode {
    case .auto: language = nil
    case .locked(let code): language = code
    }

    // The key carries ARTIFACT identity as well as language commitment. A
    // revision or digest change must invalidate a prepared engine; without it a
    // user could keep previewing with weights we no longer ship.
    let commitment = language ?? ""
    let key = LivePreviewEngineKey(
      engine: "\(WhisperPreviewRecognizer.engineID)#\(environment.artifactIdentity)",
      commitment: commitment)

    return .ready(
      LivePreviewEngineCandidate(key: key) {
        WhisperPreviewRecognizer(
          runtime: WhisperPreviewRuntime(
            modelDirectory: environment.modelDirectory,
            tokenizerDirectory: environment.tokenizerDirectory,
            variant: environment.variant,
            isAdmitted: environment.isAdmitted),
          language: language)
      })
  }
}
