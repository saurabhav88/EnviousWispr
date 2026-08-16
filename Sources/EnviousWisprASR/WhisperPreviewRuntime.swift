import Foundation
import WhisperKit

/// The ONE place that builds the Live Preview universal model (#2108, epic #2077).
///
/// Separate from `WhisperKitBackend` because they are different artifacts with
/// different rules: the backend owns the 1.6 GB transcription model whose output
/// reaches the user's document, this owns the 217 MB display model whose output
/// only draws pixels. Sharing a construction site would mean sharing a variant,
/// a tokenizer and a compute policy, and all three differ.
///
/// `package` rather than `public`: `WhisperKitTranscribing` is itself `package`,
/// and a `public` member whose type uses a package type does not compile. The
/// adapter lives in the same SwiftPM package, so `package` is the narrowest
/// visibility that works — and per `minimize-visibility`, the narrowest that
/// works is the one to take.
///
/// `WhisperKitGatedLoadFreezeTests` freezes the exact set of production files
/// allowed to construct a `WhisperKit`. This file is the second member of that
/// set, deliberately, and the freeze test names it — so a third one cannot appear
/// without someone deciding it should.
package actor WhisperPreviewRuntime {

  /// Why a preview load refused. The adapter maps these to reasons; this module
  /// owns no user-facing text.
  package enum LoadFailure: Error, Equatable {
    /// The delivery layer has not admitted the artifact. Never a download
    /// trigger — that is the user's decision, behind the engine picker.
    case notAdmitted
    /// The tokenizer that actually loaded is not the one this model needs.
    /// **Fail closed:** a wrong vocabulary transcribes fluently and wrongly,
    /// which is worse than refusing.
    case wrongTokenizer(resolved: Int?)
    /// WhisperKit itself refused the model folder.
    case modelLoadFailed(String)
  }

  /// The `noSpeechToken` a correctly-resolved `openai/whisper-small` tokenizer
  /// reports, MEASURED against the pinned WhisperKit on 2026-08-16 — not read
  /// from a comment. The large-v3 vocabulary reports `50363`, and loading it
  /// into this model succeeds silently, so this number is the only thing that
  /// distinguishes a correct load from a plausible wrong one.
  ///
  /// A control proved the check can tell them apart: a folder laid out at the
  /// same hub-structured path but containing the large-v3 vocabulary resolved to
  /// `50363`, confirming the supplied folder wins over any machine-local Hugging
  /// Face cache. Without that control the two arms were indistinguishable,
  /// because this developer machine happens to cache `openai/whisper-small`.
  package static let expectedNoSpeechToken = 50257

  private let modelDirectory: URL
  private let tokenizerDirectory: URL
  private let variant: String
  private let isAdmitted: @Sendable () async -> Bool

  private var loaded: (any WhisperKitTranscribing)?

  package init(
    modelDirectory: URL,
    tokenizerDirectory: URL,
    variant: String,
    isAdmitted: @escaping @Sendable () async -> Bool
  ) {
    self.modelDirectory = modelDirectory
    self.tokenizerDirectory = tokenizerDirectory
    self.variant = variant
    self.isAdmitted = isAdmitted
  }

  /// Load once and keep it. The adapter holds this runtime across recordings so
  /// a second press does not pay the load again; `unload()` is how it goes away.
  package func ensureLoaded() async throws -> any WhisperKitTranscribing {
    if let loaded { return loaded }

    // Admission FIRST, before anything touches the filesystem. The plan's own
    // rule: this path never starts a fetch, so a missing artifact is a refusal
    // rather than a download.
    guard await isAdmitted() else { throw LoadFailure.notAdmitted }

    let config = WhisperKitConfig(
      model: variant,
      modelFolder: modelDirectory.path,
      // EXPLICIT, and not the app's bundled `WhisperTokenizer/`. That folder has
      // a top-level `tokenizer.json` and no hub-structured subfolder, so passing
      // it here resolves the LARGE-V3 vocabulary into this small model — measured,
      // silent, and fluent-but-wrong. Passing `nil` is worse: WhisperKit's
      // tokenizer search runs independently of `download`, so it can reach the
      // network outside ModelDelivery's per-file verification.
      tokenizerFolder: tokenizerDirectory,
      // Delivery owns fetching. A config that may download bypasses per-file
      // SHA-256, the admission marker, resume and failover.
      download: false)

    let kit: WhisperKit
    do {
      kit = try await WhisperKit(config)
    } catch {
      throw LoadFailure.modelLoadFailed(String(describing: error))
    }

    // Read the identity off the LOADED instance, never from what was passed in.
    // Both wrong paths above load SUCCESSFULLY, so "it loaded" carries no
    // information about which vocabulary it loaded.
    let resolved = kit.tokenizer?.specialTokens.noSpeechToken
    guard resolved == Self.expectedNoSpeechToken else {
      throw LoadFailure.wrongTokenizer(resolved: resolved)
    }

    loaded = kit
    return kit
  }

  /// Build a streaming session over the loaded model.
  ///
  /// **The factory lives here so WhisperKit types never leave this module.** The
  /// adapter's dependency allowlist deliberately excludes the WhisperKit product:
  /// if constructing a session required `DecodingOptions` at the call site, the
  /// adapter would need that import, and the narrow allowlist that keeps this
  /// limb away from capture and the recording path would have to be widened for
  /// an unrelated reason.
  ///
  /// Options are set here rather than inherited from the transcription backend,
  /// because they differ on the axis that matters. `.auto` must stay `nil`
  /// language with detection ON: this model detects language itself, and
  /// inheriting Apple's system-locale guess would bake one engine's limitation
  /// into another. `chunkingStrategy = .none` and `windowClipTime = 0` are
  /// required by the growing-buffer decode, not preferences.
  package func makeStreamingSession(
    language: String?,
    onHypothesis: @escaping @Sendable (String) -> Void
  ) async throws -> WhisperKitStreamingSession {
    let kit = try await ensureLoaded()
    var options = DecodingOptions()
    options.language = language
    // `nil` language is NOT auto-detect on its own — detection must be asked for
    // explicitly (whisperkit-research FACT: nil-language-is-not-auto-detect).
    options.detectLanguage = (language == nil)
    options.wordTimestamps = true
    options.temperature = 0.0
    options.temperatureFallbackCount = 3
    options.temperatureIncrementOnFallback = 0.2
    options.compressionRatioThreshold = 2.4
    options.logProbThreshold = -1.0
    options.noSpeechThreshold = 0.6
    options.skipSpecialTokens = true
    options.suppressBlank = true
    options.usePrefillPrompt = true
    // The session decodes a GROWING retained buffer, so chunking would re-window
    // it and a non-zero clip time would trim trailing speech.
    options.chunkingStrategy = ChunkingStrategy.none
    options.windowClipTime = 0

    return WhisperKitStreamingSession(
      whisperKit: kit,
      decodingOptions: options,
      localAgreement: true,
      onHypothesis: onHypothesis)
  }

  /// Drop the model. Called when the engine is superseded — a revision bump, a
  /// digest change, or the user turning the preview off — so 217 MB does not sit
  /// resident for a feature nobody is using.
  package func unload() {
    loaded = nil
  }

  /// Whether a model is currently held. Lets a caller assert residency rather
  /// than infer it.
  package var isLoaded: Bool { loaded != nil }
}
