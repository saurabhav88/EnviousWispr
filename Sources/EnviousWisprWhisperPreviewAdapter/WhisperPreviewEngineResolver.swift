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
    /// The admitted GGUF's resolved path (the manifest's entrypoint in its install
    /// directory). transcribe.cpp reads its vocabulary from the file itself, so there is
    /// no tokenizer to bundle or resolve.
    package let modelPath: String
    /// Has delivery admitted the artifact. Never a download trigger.
    package let isAdmitted: @Sendable () async -> Bool
    /// Is the transcription engine itself decoding continuously right now.
    package let isHeartStreaming: @Sendable () async -> Bool

    package init(
      artifactIdentity: String,
      modelPath: String,
      isAdmitted: @escaping @Sendable () async -> Bool,
      isHeartStreaming: @escaping @Sendable () async -> Bool
    ) {
      self.artifactIdentity = artifactIdentity
      self.modelPath = modelPath
      self.isAdmitted = isAdmitted
      self.isHeartStreaming = isHeartStreaming
    }
  }

  /// The engine as the app shell consumes it: one value carrying both halves, so
  /// the pill's geometry check and the recording's resolution can never be wired
  /// from different sources.
  package static func route(_ environment: Environment) -> LivePreviewEngineRoute {
    LivePreviewEngineRoute(
      telemetryEngineID: "universal",
      isSupportedOnThisSystem: { true },
      resolve: { mode in await resolve(mode, environment: environment) }
    )
  }

  /// The language Whisper decodes, and the commitment the prepared engine is keyed on. Auto
  /// decodes with detection (nil). A regional lock decodes its language subtag, since Whisper's
  /// tokens carry no region; a bare lock is passed through as it was before #3124. The commitment
  /// keeps the full code, so "en" and "en-GB" (English (UK),
  /// #3124) are different prepared engines and a switch between them rebuilds.
  package static func decodeLanguage(for mode: LanguageMode) -> (
    language: String?, commitment: String
  ) {
    switch mode {
    case .auto: return (nil, "")
    case .locked(let code):
      // Strip a REGION only ("en-GB" -> "en"). A bare code passes through untouched: the shared
      // normaliser folds distinct Whisper languages (yue -> zh, nn -> no), which would silently
      // switch a Cantonese or Nynorsk lock to another language.
      guard let separator = code.firstIndex(where: { $0 == "-" || $0 == "_" }) else {
        return (code, code)
      }
      return (String(code[..<separator]).lowercased(), code)
    }
  }

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
    //
    // #3124: a regional lock ("en-GB" for English (UK)) decodes as its bare language, because
    // Whisper's language tokens carry no region; the KEY keeps the full code below, so switching
    // between the two Englishes rebuilds the prepared engine.
    let (language, commitment) = decodeLanguage(for: mode)

    return .ready(
      LivePreviewEngineCandidate(key: key(environment, commitment)) {
        WhisperPreviewRecognizer(
          runtime: TranscribeCppPreviewRuntime(
            modelPath: environment.modelPath, isAdmitted: environment.isAdmitted),
          language: language)
      })
  }

  /// The key carries ARTIFACT identity as well as language commitment. A
  /// revision or digest change must invalidate a prepared engine; without it a
  /// user could keep previewing with weights we no longer ship.
  private static func key(_ environment: Environment, _ commitment: String)
    -> LivePreviewEngineKey
  {
    LivePreviewEngineKey(
      engine: "\(WhisperPreviewRecognizer.engineID)#\(environment.artifactIdentity)",
      commitment: commitment)
  }

  // MARK: - #3973: EnviousMeet's live words

  /// Whether the Universal engine can give a meeting live words, and with what.
  package enum MeetingResolution: Sendable {
    case ready(MeetingCandidate)
    case blocked(LivePreviewUnavailability)
  }

  /// The meeting route (plan §3.4 step 2). Admission and language only: unlike `resolve`, it
  /// does NOT ask whether the heart is streaming, because a meeting must not lose its live
  /// words for the whole recording when the user dictates once. The heart stays protected per
  /// decode instead: the meeting supplies its temporary refusal through
  /// `MeetingCandidate.makeEngine(admitTranscriptDecode:)`, which the rolling loop retries.
  /// Allocates nothing and never downloads: an unadmitted artifact is unavailable, whatever
  /// else is true.
  package static func resolveForMeeting(
    _ mode: LanguageMode, environment: Environment
  ) async -> MeetingResolution {
    guard await environment.isAdmitted() else {
      return .blocked(.modelNotInstalled)
    }
    // Same language rule as dictation's route: Auto detects, a regional lock decodes its bare
    // language and keeps the full code as the commitment.
    let (language, commitment) = decodeLanguage(for: mode)
    return .ready(
      MeetingCandidate(
        key: key(environment, commitment), language: language,
        makeRuntime: {
          TranscribeCppPreviewRuntime(
            modelPath: environment.modelPath, isAdmitted: environment.isAdmitted)
        }))
  }

  /// A ready meeting route, before anything is allocated. The meeting owner calls `makeEngine`
  /// once per recording, when it may hold a model (never while a previous recording's model
  /// is still being freed).
  package struct MeetingCandidate: Sendable {
    package let key: LivePreviewEngineKey
    let language: String?
    let makeRuntime: @Sendable () -> TranscribeCppPreviewRuntime

    /// One runtime for both tracks, and one recognizer over it whose transcript sessions ask
    /// `admitTranscriptDecode` before every decode.
    package func makeEngine(
      admitTranscriptDecode: @escaping @Sendable () async throws -> Void
    ) -> MeetingEngine {
      MeetingEngine(
        runtime: makeRuntime(), language: language, admitTranscriptDecode: admitTranscriptDecode)
    }
  }

  /// A meeting's Universal engine: the runtime both tracks share and what the owner needs to
  /// prepare, open and free it. Building it loads nothing; the model loads on `prepare()` or on
  /// the first transcript open, whichever comes first (once, shared by both tracks).
  package struct MeetingEngine: Sendable {
    /// Opens each track's transcript session; every session decodes on this engine's runtime.
    package let recognizer: any LivePreviewEngine
    private let runtime: TranscribeCppPreviewRuntime

    init(
      runtime: TranscribeCppPreviewRuntime, language: String?,
      admitTranscriptDecode: @escaping @Sendable () async throws -> Void
    ) {
      self.runtime = runtime
      self.recognizer = WhisperPreviewRecognizer(
        runtime: runtime, language: language, admitTranscriptDecode: admitTranscriptDecode)
    }

    /// Loads the model ahead of the first open (once, shared by both tracks). Throws rather than
    /// downloading.
    package func prepare() async throws {
      try await recognizer.prepare()
    }

    /// Frees this engine's model for good (`TranscribeCppPreviewRuntime.beginRelease`): on
    /// return every later load, open and decode is refused; the task completes once the model
    /// is physically freed.
    /// #3973: `prepare` failed only because dictation's engine held the executor.
    package func isTemporary(_ error: any Error) -> Bool {
      TranscribeCppPreviewRuntime.isTemporary(error)
    }

    package func beginRelease() async -> Task<Void, Never> {
      await runtime.beginRelease()
    }
  }
}
