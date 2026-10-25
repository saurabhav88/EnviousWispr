import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview
@testable import EnviousWisprServices
@testable import EnviousWisprWhisperPreviewAdapter

/// #3735 Chunk 11: the whole engine x language x Faster Transcription table for the Universal
/// preview's "the heart is streaming" refusal, and the resolver's answer for each kind of
/// environment (live-preview.md RULE: universal-preview-engine-safety).
///
/// **What the user sees when this fails:** with Faster Transcription on, the Universal preview
/// decodes at the same time as the dictation engine and slows the transcript the user is
/// waiting for; or, with it off, the preview is paused for no reason.
@MainActor
@Suite("Universal preview contention policy (#3735)", .tags(.productOutcome))
struct UniversalPreviewContentionPolicyTests {

  /// The expected table, written from the product rule rather than read from the predicate:
  /// Parakeet streams whenever the toggle is on; Whisper streams only with a locked language
  /// (Auto runs batch after the recording). Toggle off never streams.
  static let languages: [LanguageMode] = [
    .auto, .locked("en"), .locked("hi"), .locked("ja"),
  ]

  static func expectedStreaming(
    backend: ASRBackendType, mode: LanguageMode, toggle: Bool
  ) -> Bool {
    guard toggle else { return false }
    switch (backend, mode) {
    case (.parakeet, _): return true
    case (.whisper, .auto): return false
    case (.whisper, .locked): return true
    }
  }

  private func settings(
    backend: ASRBackendType, mode: LanguageMode, toggle: Bool
  ) throws -> SettingsManager {
    let suite = "com.enviouswispr.tests.3735.contention.\(UUID().uuidString)"
    let settings = SettingsManager(defaults: try #require(TestDefaults.suite(suite)))
    settings.selectedBackend = backend
    settings.languageMode = mode
    settings.useStreamingASR = toggle
    return settings
  }

  @Test("every engine, language and Faster Transcription cell matches the table (16 cells)")
  func heartIsStreamingTable() throws {
    var checked = 0
    var refusals = 0
    for backend in [ASRBackendType.parakeet, .whisper] {
      for mode in Self.languages {
        for toggle in [false, true] {
          let s = try settings(backend: backend, mode: mode, toggle: toggle)
          #expect(s.selectedBackend == backend && s.useStreamingASR == toggle)
          let expected = Self.expectedStreaming(backend: backend, mode: mode, toggle: toggle)
          #expect(
            WhisperPreviewDeliveryWiring.heartIsStreaming(settings: s) == expected,
            "\(backend) \(mode) toggle=\(toggle)")
          checked += 1
          if expected { refusals += 1 }
        }
      }
    }
    #expect(checked == 16)
    // 4 Parakeet cells + 3 locked Whisper cells: the table is not trivially all-false.
    #expect(refusals == 7)
  }

  private static func environment(admitted: Bool, streaming: Bool)
    -> WhisperPreviewEngineResolver.Environment
  {
    WhisperPreviewEngineResolver.Environment(
      artifactIdentity: "test-artifact", modelPath: "/nonexistent/model.gguf",
      isAdmitted: { admitted }, isHeartStreaming: { streaming })
  }

  @Test("a streaming heart refuses Universal even when the model is installed")
  func streamingHeartRefusesFirst() async {
    for mode in Self.languages {
      let result = await WhisperPreviewEngineResolver.resolve(
        mode, environment: Self.environment(admitted: true, streaming: true))
      guard case .blocked(.heartIsStreaming) = result else {
        Issue.record("\(mode): expected heartIsStreaming, got \(result)")
        continue
      }
    }
  }

  @Test("a batch heart without the model asks for the download")
  func batchHeartWithoutModelIsNotInstalled() async {
    let result = await WhisperPreviewEngineResolver.resolve(
      .auto, environment: Self.environment(admitted: false, streaming: false))
    guard case .blocked(.modelNotInstalled) = result else {
      Issue.record("expected modelNotInstalled, got \(result)")
      return
    }
  }

  @Test("a batch heart with the model is ready: Auto detects, a lock commits to its language")
  func batchHeartWithModelIsReady() async {
    let cases: [(LanguageMode, String)] = [
      (.auto, ""), (.locked("hi"), "hi"), (.locked("ja"), "ja"), (.locked("en-GB"), "en-GB"),
    ]
    for (mode, commitment) in cases {
      let result = await WhisperPreviewEngineResolver.resolve(
        mode, environment: Self.environment(admitted: true, streaming: false))
      guard case .ready(let candidate) = result else {
        Issue.record("\(mode): expected ready, got \(result)")
        continue
      }
      #expect(candidate.key.commitment == commitment, "\(mode)")
      #expect(candidate.key.engine.hasSuffix("#test-artifact"), "\(candidate.key.engine)")
    }
  }
  // MARK: - #3973: the meeting route

  /// Counts readiness questions about the heart; the meeting route must ask none.
  final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func note() { lock.withLock { count += 1 } }
  }

  private static func meetingEnvironment(admitted: Bool, asked: Asked)
    -> WhisperPreviewEngineResolver.Environment
  {
    WhisperPreviewEngineResolver.Environment(
      artifactIdentity: "test-artifact", modelPath: "/nonexistent/model.gguf",
      isAdmitted: { admitted },
      isHeartStreaming: {
        asked.note()
        return true
      })
  }

  @Test("a meeting gets the Universal engine while the heart streams, without asking about it")
  func meetingReadyWhileStreaming() async {
    let asked = Asked()
    let result = await WhisperPreviewEngineResolver.resolveForMeeting(
      .locked("en"), environment: Self.meetingEnvironment(admitted: true, asked: asked))
    guard case .ready(let candidate) = result else {
      Issue.record("expected ready, got \(result)")
      return
    }
    #expect(asked.value == 0, "the meeting route never reads heart streaming")
    #expect(candidate.key.engine.hasSuffix("#test-artifact"))
    // Control: dictation's route on the same environment does ask, and refuses.
    let dictation = await WhisperPreviewEngineResolver.resolve(
      .locked("en"), environment: Self.meetingEnvironment(admitted: true, asked: asked))
    guard case .blocked(.heartIsStreaming) = dictation else {
      Issue.record("control: expected dictation's heartIsStreaming, got \(dictation)")
      return
    }
    #expect(asked.value == 1)
  }

  @Test("a meeting without the admitted model is unavailable, streaming or not")
  func meetingRefusesUnadmitted() async {
    let asked = Asked()
    let result = await WhisperPreviewEngineResolver.resolveForMeeting(
      .auto, environment: Self.meetingEnvironment(admitted: false, asked: asked))
    guard case .blocked(.modelNotInstalled) = result else {
      Issue.record("expected modelNotInstalled, got \(result)")
      return
    }
    #expect(asked.value == 0)
  }

  @Test("dictation still refuses for the streaming heart first, even without the model")
  func dictationStreamingPrecedence() async {
    let result = await WhisperPreviewEngineResolver.resolve(
      .auto, environment: Self.environment(admitted: false, streaming: true))
    guard case .blocked(.heartIsStreaming) = result else {
      Issue.record("expected heartIsStreaming before modelNotInstalled, got \(result)")
      return
    }
  }

  @Test("the meeting route keeps the language rule: Auto detects, a regional lock decodes bare")
  func meetingLanguageSemantics() async {
    let cases: [(LanguageMode, String?, String)] = [
      (.auto, nil, ""), (.locked("hi"), "hi", "hi"), (.locked("en-GB"), "en", "en-GB"),
      (.locked("yue"), "yue", "yue"),
    ]
    for (mode, language, commitment) in cases {
      let result = await WhisperPreviewEngineResolver.resolveForMeeting(
        mode, environment: Self.meetingEnvironment(admitted: true, asked: Asked()))
      guard case .ready(let candidate) = result else {
        Issue.record("\(mode): expected ready, got \(result)")
        continue
      }
      #expect(candidate.language == language, "\(mode)")
      #expect(candidate.key.commitment == commitment, "\(mode)")
    }
  }
}
