import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview
@testable import EnviousWisprWhisperPreviewAdapter

/// #3124: live preview under English (UK). When one of these fails, a British user watches
/// "color" appear while they speak and then gets "colour" pasted, or the preview asks Apple for
/// the wrong model, or dictation is handed a regional code.
@MainActor
@Suite("Live preview English (UK)", .tags(.productOutcome))
struct LivePreviewEnglishSpellingTests {

  @Test("the preview asks for en-GB only when British is in force; everything else passes through")
  func previewLanguageMapping() {
    typealias Installer = LivePreviewInstaller
    #expect(
      Installer.previewLanguageMode(languageMode: .locked("en"), stored: .british)
        == .locked("en-GB"))
    #expect(
      Installer.previewLanguageMode(languageMode: .locked("en"), stored: .american) == .locked("en")
    )
    #expect(
      Installer.previewLanguageMode(languageMode: .locked("de"), stored: .british) == .locked("de"))
    #expect(Installer.previewLanguageMode(languageMode: .auto, stored: .british) == .auto)
  }

  #if DEBUG

    /// An engine whose session says one fixed sentence as soon as it opens.
    final class SpeakingEngine: LivePreviewEngine, @unchecked Sendable {
      let heard: String
      init(heard: String) { self.heard = heard }
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        onText(heard)
        return Idle()
      }
    }

    /// An engine whose session never says anything: the control for the bounded wait.
    final class SilentEngine: LivePreviewEngine, @unchecked Sendable {
      func prepare() async throws {}
      func openSession(
        lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
      ) async throws -> any LivePreviewEngineSession {
        struct Idle: LivePreviewEngineSession {
          func feed(_ samples: [Float]) async {}
          func end() async {}
        }
        return Idle()
      }
    }

    /// Runs one recording and returns the first text the pill is given (nil when none arrives
    /// before `deadline`), plus the language the route was asked to resolve. Waits on the
    /// coordinator's own display signal, raced against a deadline so a broken publish path fails
    /// the test instead of hanging it.
    private static func firstShownText(
      heard: String?, spelling: @escaping () -> EnglishSpelling,
      mode: @escaping () -> LanguageMode = { .locked("en") },
      vocabulary: CorrectorVocabulary = .empty,
      deadline: Duration = .seconds(10),
      changeAfterStart: (() -> Void)? = nil
    ) async -> (shown: String?, resolvedWith: LanguageMode?) {
      final class Box: @unchecked Sendable { var mode: LanguageMode? }
      let asked = Box()
      let coordinator = LivePreviewCoordinator(
        readSamples: { _ in ([], 0) },
        isPreviewOn: { true },
        languageMode: mode,
        englishSpelling: spelling,
        selectedRoute: {
          LivePreviewEngineRoute(
            telemetryEngineID: "universal", isSupportedOnThisSystem: { true },
            resolve: { requested in
              asked.mode = requested
              return .ready(
                LivePreviewEngineCandidate(
                  key: LivePreviewEngineKey(engine: "test#1", commitment: ""),
                  makeEngine: {
                    if let heard { return SpeakingEngine(heard: heard) }
                    return SilentEngine()
                  }))
            })
        })
      coordinator.correctorVocabulary = vocabulary
      let (stream, signal) = AsyncStream.makeStream(of: String.self)
      coordinator.onDisplayTextForTesting = { signal.yield($0) }
      coordinator.setRecording(true)
      changeAfterStart?()
      let shown = await withTaskGroup(of: String?.self) { group in
        group.addTask {
          for await text in stream { return text }
          return nil
        }
        group.addTask {
          try? await Task.sleep(for: deadline)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        signal.finish()
        return first
      }
      coordinator.onDisplayTextForTesting = nil
      coordinator.setRecording(false)
      return (shown, asked.mode)
    }

    @Test("the wait fails, not hangs, when no text is ever shown")
    func missingSignalFails() async {
      let result = await Self.firstShownText(
        heard: nil, spelling: { .british }, deadline: .milliseconds(300))
      #expect(result.shown == nil, "a silent engine must come back empty at the deadline")
    }

    @Test("converted text is re-bounded to the preview cap")
    func convertedTextStaysBounded() async throws {
      // 333 x "color " = 1,998 characters, under the 2,000 cap as heard; 2,331 once British.
      let heard = String(repeating: "color ", count: 333)
      let result = await Self.firstShownText(heard: heard, spelling: { .british })
      let shown = try #require(result.shown)
      #expect(shown.count <= LivePreviewTextBound.maxCharacters)
      #expect(shown.hasSuffix("colour "), "the tail is kept, and it is British")
    }

    @Test("British preview text is shown in British spelling")
    func britishShown() async {
      let result = await Self.firstShownText(
        heard: "the color of the center", spelling: { .british })
      #expect(result.shown == "the colour of the centre")
    }

    @Test("American preview text is shown exactly as heard")
    func americanShown() async {
      let result = await Self.firstShownText(
        heard: "the color of the center", spelling: { .american })
      #expect(result.shown == "the color of the center")
    }

    @Test("text Apple's British model already spelled British is left as it is")
    func alreadyBritishUnchanged() async {
      let result = await Self.firstShownText(
        heard: "the colour of the centre", spelling: { .british })
      #expect(result.shown == "the colour of the centre")
    }

    @Test("the user's Custom Words stay as they typed them on screen too")
    func customWordsProtected() async {
      let vocabulary = CorrectorVocabulary(
        terms: [
          CustomWord(canonical: "Color Street"),
          CustomWord(canonical: "recognizer", source: .builtin),
        ],
        generation: 1)
      let result = await Self.firstShownText(
        heard: "the color recognizer", spelling: { .british }, vocabulary: vocabulary)
      #expect(result.shown == "the color recogniser")
    }

    @Test("a change made after the recording starts applies to the next recording, not this one")
    func midRecordingChangeWaits() async {
      final class Live: @unchecked Sendable {
        var spelling: EnglishSpelling = .british
        var mode: LanguageMode = .locked("en-GB")
      }
      let live = Live()
      let result = await Self.firstShownText(
        heard: "the color", spelling: { live.spelling }, mode: { live.mode },
        changeAfterStart: {
          live.spelling = .american
          live.mode = .locked("fr")
        })
      #expect(result.shown == "the colour", "the frozen British spelling applies")
      #expect(result.resolvedWith == .locked("en-GB"), "the frozen preview language is resolved")
    }

  #endif

  @Test("the universal preview decodes a regional lock as its language and keys on the full code")
  func whisperRegionalLock() {
    let british = WhisperPreviewEngineResolver.decodeLanguage(for: .locked("en-GB"))
    let american = WhisperPreviewEngineResolver.decodeLanguage(for: .locked("en"))
    #expect(british.language == "en", "Whisper has no regional tokens")
    #expect(british.commitment == "en-GB")
    #expect(american.language == "en")
    #expect(american.commitment == "en")
    #expect(british.commitment != american.commitment, "a US/UK switch must rebuild the engine")
    // Bare codes the shared normaliser would fold stay exactly as locked.
    for bare in ["yue", "nn", "zh", "haw"] {
      let decoded = WhisperPreviewEngineResolver.decodeLanguage(for: .locked(bare))
      #expect(decoded.language == bare, "\(bare) must decode as itself")
      #expect(decoded.commitment == bare)
    }
    let auto = WhisperPreviewEngineResolver.decodeLanguage(for: .auto)
    #expect(auto.language == nil)
    #expect(auto.commitment == "")
  }
}
