import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #3142: Transcribe a File sentences that used to splice an estimate phrase, ", under your own
/// key" or a number into a sentence are now whole sentences. Each oracle rebuilds the OLD
/// spliced English independently, so the English must match byte for byte, including numbers
/// of 1,000 and more (no thousands separator). Unit tests run outside the app bundle, so they
/// read English.
@Suite("Transcribe a File copy", .tags(.productOutcome))
struct TranscribeFileCopyTests {

  /// The old phrase: rounded minutes, "under a minute" below 30 s.
  private static func oldPhrase(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    switch minutes {
    case ..<1: return "under a minute"
    case 1: return "about a minute"
    default: return "about \(minutes) minutes"
    }
  }

  private static let estimateSeconds: [Double] = [0, 29, 30, 89, 90, 600, 1_234 * 60]

  @Test("every estimate sentence matches the old spliced frame")
  func estimateSentences() {
    for seconds in Self.estimateSeconds {
      let phrase = Self.oldPhrase(seconds)
      #expect(ImportEstimateWording.text(seconds: seconds) == phrase)
      #expect(ImportEstimateWording.readyIn(seconds: seconds) == "Ready in \(phrase)")
      #expect(ImportEstimateWording.left(seconds: seconds) == "\(phrase) left")
      #expect(
        ImportEstimateWording.dictationPauses(seconds: seconds)
          == "Dictation pauses while this runs. Your keybind will not record until the transcript is finished, in \(phrase)."
      )
    }
  }

  @Test("the privacy footer matches the old frame for every step, provider and location")
  func privacyFooter() {
    let providers: [LLMProvider] = [.openAI, .gemini, .claude, .ollama, .egOne, .none]
    for provider in providers {
      let ownKeyProviders: Set<LLMProvider> = [.openAI, .gemini, .claude]
      let underOwnKey = ownKeyProviders.contains(provider) ? ", under your own key" : ""
      let name = provider.displayName
      for isCloud in [true, false] {
        #expect(
          TranscribeFileView.footerDetail(
            step: .working, isCloudPolish: isCloud, provider: provider)
            == (isCloud
              ? "Your audio never leaves this Mac. The text is going to \(name)\(underOwnKey)."
              : "Your audio and text both stay on this Mac."))
        #expect(
          TranscribeFileView.footerDetail(step: .done, isCloudPolish: isCloud, provider: provider)
            == (isCloud
              ? "Your audio stayed on this Mac. Only the text went to \(name)\(underOwnKey)."
              : "Your untouched words are kept beside this one."))
        for step in [FileImportCoordinator.Step.upload, .transcription, .polish, .review] {
          #expect(
            TranscribeFileView.footerDetail(step: step, isCloudPolish: isCloud, provider: provider)
              == (isCloud
                ? "Your audio never leaves this Mac. Only the text goes to \(name)\(underOwnKey)."
                : "Your audio and text both stay on this Mac."))
        }
      }
    }
  }

  @Test("the word count chip keeps its old English, digits included")
  func wordCountChip() {
    for n in [0, 1, 2, 1_234, 25_000] {
      #expect(TranscribeFileView.wordCountChip(n) == "\(n) words")
    }
  }

  @Test("durations and channel counts read as before")
  func fileDetails() {
    #expect(FileImportCoordinator.durationText(48) == "48 sec")
    #expect(FileImportCoordinator.durationText(3 * 60) == "3 min")
    #expect(FileImportCoordinator.durationText(72 * 60) == "1 hr 12 min")
    #expect(FileImportCoordinator.channelsText(1) == "mono")
    #expect(FileImportCoordinator.channelsText(2) == "stereo")
    #expect(FileImportCoordinator.channelsText(6) == "6 channels")
    #expect(FileImportCoordinator.channelsText(1_000) == "1000 channels")
    #expect(FileImportCoordinator.durationText(1_000 * 3_600) == "1000 hr 0 min")
  }

  @Test("progress counts print large numbers without a separator")
  func progressCounts() {
    #expect(
      WorkingStepModel.transcribingTitle(fraction: 0.5, fileSeconds: 2_468 * 60)
        == "Transcribing 1234 of 2468 minutes")
    #expect(WorkingPageModel.minutesOf(1_234, 2_468) == "1234 of 2468 min")
    #expect(
      TranscribeFileWorkingCard.elapsedText(
        since: .init(timeIntervalSince1970: 0), now: .init(timeIntervalSince1970: 1_500))
        == "1500 s")
  }

  @Test("the marked-up text reads aloud as before")
  func markedUpAccessibility() {
    let segments: [WordDiff.Segment] = [
      .init(kind: .same, text: "we", trailing: " "),
      .init(kind: .removed, text: "um", trailing: " "),
      .init(kind: .changed, text: "shipped", trailing: " "),
      .init(kind: .added, text: "today", trailing: ""),
    ]
    #expect(
      TranscribeFileExport.markedUpAccessibilityText(segments)
        == "we Removed: um. Changed: shipped. Added: today. ")
  }

  @Test("the sections count prints large numbers without a separator")
  func sectionsCount() {
    let model = WorkingPageModel.make(
      fileName: "a.m4a", fileSeconds: 60, engine: .parakeet, polisher: .none, estimate: "",
      transcribingFraction: nil, transcriptLanded: false, speakersFound: nil,
      sectionsDone: 1_200, sectionsTotal: 1_500, words: nil)
    #expect(model.counts.first { $0.kind == .sections }?.value == "1200 of 1500")
  }
}
