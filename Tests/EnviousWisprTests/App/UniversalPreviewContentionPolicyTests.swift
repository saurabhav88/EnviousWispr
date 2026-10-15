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
}
