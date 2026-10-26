import Foundation
import Speech
import Testing

@testable import EnviousWisprLivePreview

/// #4105: which Apple speech module each kind runs.
///
/// **What the user sees when this fails:** dictation's live preview silently switches to the
/// meeting module (different languages, different downloads), or EnviousMeet's live words fall
/// back to the dictation module, which caught 31% of a two-person meeting's words against 67%.
@Suite("Apple transcriber kinds (#4105)", .tags(.productOutcome))
struct AppleTranscriberFactoryTests {

  @Test(
    "Dictation runs DictationTranscriber and meetings run SpeechTranscriber",
    .enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
  func kindsBuildTheirModules() {
    guard #available(macOS 26.0, *) else { return }
    let locale = Locale(identifier: "en-US")
    #expect(
      AppleTranscriberFactory.makeModule(.dictation, locale: locale).speechModule
        is DictationTranscriber)
    #expect(
      AppleTranscriberFactory.makeModule(.meeting, locale: locale).speechModule
        is SpeechTranscriber)
    #expect(AppleTranscriberFactory.isAvailable(.dictation))
  }

  @Test(
    "A recognizer built without a kind is dictation's",
    .enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
  func recognizerDefaultsToDictation() async {
    guard #available(macOS 26.0, *) else { return }
    let locale = Locale(identifier: "en-US")
    #expect(await ApplePreviewRecognizer(locale: locale).kind == .dictation)
    #expect(await ApplePreviewRecognizer(locale: locale, kind: .meeting).kind == .meeting)
  }
}
