import CoreMedia
import Foundation
import Speech

/// Which Apple speech module a recognizer runs (#4105).
///
/// `.dictation` is the live preview's `DictationTranscriber`, built for one person speaking close
/// to the Mac. `.meeting` is `SpeechTranscriber`, built for long-form speech. Measured on the
/// founder's two-person, one-microphone test meeting (2026-10-25,
/// `docs/audits/2026-10-25-founder-meeting-replay/result.txt`): word-sequence agreement with the
/// meeting's final Parakeet transcript was 31% for the dictation module and 67% for the meeting
/// module. EnviousMeet never uses `.dictation` (founder, decisions file item 18).
package enum AppleTranscriberKind: String, Sendable {
  case dictation
  case meeting
}

/// The one place that builds Apple speech modules and answers which locales each kind supports
/// or has installed. Every site that used to name `DictationTranscriber` directly goes through
/// here, so the two kinds can never disagree about which module a session runs.
///
/// Building a module is inert: only `AssetInventory.assetInstallationRequest` +
/// `downloadAndInstall` fetch bytes, and neither appears in this file (#2080).
@available(macOS 26.0, *)
package enum AppleTranscriberFactory {

  /// One freshly built module plus the way to read its results. A module belongs to exactly ONE
  /// `SpeechAnalyzer` (`ApplePreviewRecognizer` trap 1), so this is built per analyzer.
  package struct Module: @unchecked Sendable {
    let speechModule: any SpeechModule
    /// Iterates the module's results, calling `deliver` with each one. Throws when the results
    /// stream throws; returns when it completes. Both kinds deliver per segment: a volatile
    /// result replaces the segment in flight, a final appends it
    /// (`ApplePreviewRecognizer.collect`; SDK `SpeechTranscriber.Result` /
    /// `DictationTranscriber.Result`). The meeting kind also delivers each attributed run's
    /// `audioTimeRange` on the session's input timeline (#4355).
    let consume:
      @Sendable (_ deliver: @escaping @Sendable (LiveTranscriptResult) -> Void) async throws
        -> Void
  }

  /// The preset each kind runs with.
  package static func makeModule(_ kind: AppleTranscriberKind, locale: Locale) -> Module {
    switch kind {
    case .dictation:
      let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
      return Module(
        speechModule: module,
        consume: { deliver in
          for try await result in module.results {
            deliver(.untimed(String(result.text.characters), isFinal: result.isFinal))
          }
        })
    case .meeting:
      // #4355 Phase 0a step 5: the time-indexed preset reports `audioTimeRange` on every run
      // (140 of 140 finals on the probe call); the progressive preset reports none.
      let module = SpeechTranscriber(
        locale: locale, preset: .timeIndexedProgressiveTranscription)
      return Module(
        speechModule: module,
        consume: { deliver in
          for try await result in module.results {
            let runs = result.text.runs.map { run in
              LiveTranscriptResult.Run(
                text: String(result.text[run.range].characters),
                startSeconds: run.audioTimeRange.flatMap { seconds($0.start) },
                endSeconds: run.audioTimeRange.flatMap { seconds($0.end) })
            }
            deliver(
              LiveTranscriptResult(
                text: String(result.text.characters), isFinal: result.isFinal, runs: runs,
                startSeconds: seconds(result.range.start)))
          }
        })
    }
  }

  /// A time in seconds, or nil when it is not a number (invalid, indefinite or infinite).
  private static func seconds(_ time: CMTime) -> Double? {
    guard time.isNumeric else { return nil }
    let value = time.seconds
    return value.isFinite ? value : nil
  }

  /// Whether this kind can run on this Mac at all. `SpeechTranscriber` also depends on the
  /// hardware (`SpeechTranscriber.isAvailable`); the dictation module has no such check.
  package static func isAvailable(_ kind: AppleTranscriberKind) -> Bool {
    switch kind {
    case .dictation: true
    case .meeting: SpeechTranscriber.isAvailable
    }
  }

  /// Apple's own regional equivalence for a code (`ApplePreviewRecognizer.resolveLocale`).
  package static func supportedLocale(
    _ kind: AppleTranscriberKind, equivalentTo locale: Locale
  ) async -> Locale? {
    switch kind {
    case .dictation: await DictationTranscriber.supportedLocale(equivalentTo: locale)
    case .meeting: await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }
  }

  /// Every locale this kind can transcribe, read from the system each time.
  package static func supportedLocales(_ kind: AppleTranscriberKind) async -> [Locale] {
    switch kind {
    case .dictation: await DictationTranscriber.supportedLocales
    case .meeting: await SpeechTranscriber.supportedLocales
    }
  }

  /// The locales whose model for this kind is on this Mac. The two kinds use different assets:
  /// on 2026-10-25 this Mac had 24 dictation locales installed and only English for the meeting
  /// module (issue #4105).
  package static func installedLocales(_ kind: AppleTranscriberKind) async -> [Locale] {
    switch kind {
    case .dictation: await DictationTranscriber.installedLocales
    case .meeting: await SpeechTranscriber.installedLocales
    }
  }
}
