import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2918 — the Working page's own numbers under the step card: the file summary and the live
/// counts, each either known or absent, never invented.
///
/// **When this fails, the user reads a count the run has not reached, a polisher the run did
/// not freeze, or a length that is not the file's.** Product coverage.
@Suite(.tags(.productOutcome))
struct TranscribeFileWorkingPageTests {

  private func make(
    fraction: Double? = nil, landed: Bool = false, speakers: Int? = nil,
    done: Int? = nil, total: Int? = nil, words: Int? = nil, polisher: LLMProvider? = .egOne,
    engine: ASRBackendType = .whisperKit
  ) -> WorkingPageModel {
    WorkingPageModel.make(
      fileName: "4-elon-musk-jre-1470.m4a", fileSeconds: 7_208.7, engine: engine, polisher: polisher,
      estimate: "about 8 minutes", transcribingFraction: fraction, transcriptLanded: landed,
      speakersFound: speakers, sectionsDone: done, sectionsTotal: total, words: words)
  }

  private func value(_ model: WorkingPageModel, _ kind: WorkingPageModel.Count.Kind) -> String? {
    model.counts.first { $0.kind == kind }?.value
  }

  @Test("the summary is the run's frozen configuration and the file's own numbers")
  func summary() {
    let model = make()
    #expect(model.summary.fileName == "4-elon-musk-jre-1470.m4a")
    #expect(model.summary.length == "2 hr 0 min")
    #expect(model.summary.engine == "All Languages")
    #expect(model.summary.polisher == "EG-1")
    #expect(model.summary.estimate == "about 8 minutes")
    #expect(make(polisher: LLMProvider.none).summary.polisher == "None")
    #expect(make(polisher: nil).summary.polisher == "None", "no run frozen yet")
    #expect(make(engine: .parakeet).summary.engine == "Fast")
  }

  @Test("every count is absent until the run knows it, in the run's own order")
  func countsStartUnknown() {
    let model = make()
    #expect(model.counts.map(\.kind) == [.transcribed, .speakers, .sections, .words])
    #expect(model.counts.allSatisfy { $0.value == nil })
    #expect(model.counts.map(\.label) == ["Transcribed", "Speakers found", "Sections cleaned", "Words so far"])
  }

  @Test("minutes transcribed follow the fraction, floor, and read the whole length once landed")
  func transcribedMinutes() {
    #expect(value(make(fraction: 0.5), .transcribed) == "60 of 120 min")
    #expect(value(make(fraction: 0.99), .transcribed) == "118 of 120 min", "floored")
    #expect(value(make(fraction: 1.4), .transcribed) == "120 of 120 min", "clamped")
    #expect(value(make(landed: true), .transcribed) == "120 of 120 min", "the transcript is in")
    #expect(value(make(fraction: nil), .transcribed) == nil)
  }

  @Test("speakers come from the coordinator's post-assembly count, never the analyzer's own outcome")
  func speakers() {
    #expect(value(make(speakers: 2), .speakers) == "2")
    #expect(value(make(speakers: 1), .speakers) == "1")
    #expect(value(make(speakers: nil), .speakers) == nil)
    // The count the page is handed comes from the ASSEMBLED result: a labeled analysis
    // that assembly downgraded (missing timings, every turn unknown) shows no count.
    #expect(FileImportCoordinator.speakersFound(in: .labeled(count: 2)) == 2)
    #expect(FileImportCoordinator.speakersFound(in: .single) == 1)
    #expect(FileImportCoordinator.speakersFound(in: .failed(.noWordTimings)) == nil)
    #expect(FileImportCoordinator.speakersFound(in: .unanalyzed) == nil)
    #expect(FileImportCoordinator.speakersFound(in: nil) == nil)
  }

  @Test("sections and words are the cleaning counter and the raw word count, formatted")
  func sectionsAndWords() {
    #expect(value(make(done: 8, total: 14), .sections) == "8 of 14")
    #expect(value(make(done: 20, total: 14), .sections) == "14 of 14", "clamped")
    #expect(value(make(done: 0, total: 0), .sections) == nil, "no count yet")
    #expect(value(make(words: 19_363), .words) == "19,363")
    #expect(value(make(words: nil), .words) == nil)
  }
}
