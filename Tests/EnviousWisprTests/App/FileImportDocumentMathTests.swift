import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2935: the document arithmetic moved off the coordinator. The three helpers that had no
/// direct test before the move get one here; the rest stay pinned by
/// `FileImportCoordinatorSpeakerTests`.
///
/// **When this fails, the Marked up view marks a gap the cleanup never touched as removed, a
/// file the app could not read offers "Try again" that re-reads it, or a decoder refusal reaches
/// the user as a raw error string.** Product coverage.
@Suite("File import document math (#2935)", .tags(.productOutcome))
@MainActor
struct FileImportDocumentMathTests {

  private func part(_ id: Int, _ text: String, unpolished: Bool = false) -> FileImportCoordinator.Part {
    FileImportCoordinator.Part(
      id: id, text: text, isUnpolished: unpolished, wasPolished: !unpolished, turnID: nil)
  }

  @Test("each passage carries the gap before it, the last runs to the end, an unreached one has no cleaned text")
  func placedPassagesCarryTheirGaps() {
    let raw = "alpha beta  gamma delta\n\nepsilon zeta."
    let pieces = ["alpha beta", "gamma delta", "epsilon zeta"]
    let parts = [part(0, "Alpha beta."), part(1, "Gamma delta.", unpolished: true)]
    let placed = FileImportDocumentMath.placedPassages(rawTranscript: raw, pieces: pieces, parts: parts)
    #expect(
      placed.map(\.original) == ["alpha beta", "  gamma delta", "\n\nepsilon zeta."],
      "the last passage runs to the transcript's end")
    #expect(placed.map(\.cleaned) == ["Alpha beta.", "Gamma delta.", nil])
    #expect(placed.allSatisfy { if case .placed = $0.placement { true } else { false } })
    if case .placed(let rawRange, let contentRange) = placed[1].placement {
      #expect(rawRange == 10..<23 && contentRange == 12..<23, "UTF-16 offsets of the gap and the piece")
    }
  }

  @Test("a piece the scan cannot place is compared on its own and does not move the cursor")
  func unplaceablePieceDoesNotAdvance() {
    let raw = "one two three"
    let placed = FileImportDocumentMath.placedPassages(
      rawTranscript: raw, pieces: ["nine", "two three"], parts: [])
    #expect(placed[0].placement == .unplaceable && placed[0].original == "nine")
    #expect(placed[1].original == "one two three", "the cursor stayed at the start")
  }

  @Test("only engine refusals are about the engine; the file and the polisher are not")
  func engineRefusals() {
    let engine: [FileImportCoordinator.FileImportRejection] = [
      .engineBusy(.dictation), .engineNotInstalled, .engineNotReady,
    ]
    let notEngine: [FileImportCoordinator.FileImportRejection] = [
      .cannotRead, .noAudio, .noSpeechFound, .polisherNotReady, .failed("x"),
    ]
    #expect(engine.allSatisfy { FileImportDocumentMath.isAboutTheEngine($0) })
    #expect(notEngine.allSatisfy { !FileImportDocumentMath.isAboutTheEngine($0) })
  }

  @Test("both finalTurns branches keep each turn's granularity (#3735 §3.10)")
  func finalTurnsKeepGranularity() {
    let turns = [
      Turn(
        id: "0-5", speakerId: "A", startMs: 0, endMs: 500, originalTextRange: 0..<5,
        granularity: .segment),
      Turn(
        id: "6-11", speakerId: "B", startMs: 500, endMs: 900, originalTextRange: 6..<11,
        granularity: .segment),
      Turn(id: "12-15", speakerId: "A", startMs: 900, endMs: 1_000, originalTextRange: 12..<15),
    ]
    let parts = [
      FileImportCoordinator.Part(
        id: 0, text: "Hello", isUnpolished: false, wasPolished: true, turnID: "0-5")
    ]
    for completed in [true, false] {
      let final = FileImportDocumentMath.finalTurns(turns, parts: parts, cleanupCompleted: completed)
      #expect(final.map(\.granularity) == [.segment, .segment, nil])
      #expect(final[0].processedText == "Hello", "the cleaned branch")
      #expect(final[1].processedText == nil, "the unreached branch")
    }
  }

  @Test("decoder refusals map to the two file refusals; anything else is a described failure")
  func decoderRefusalsMap() {
    #expect(FileImportDocumentMath.rejection(for: AudioFileDecoder.Rejection.unreadable) == .cannotRead)
    #expect(FileImportDocumentMath.rejection(for: AudioFileDecoder.Rejection.noAudioTrack) == .noAudio)
    #expect(FileImportDocumentMath.rejection(for: AudioFileDecoder.Rejection.noAudio) == .noAudio)
    struct Other: Error {}
    #expect(FileImportDocumentMath.rejection(for: Other()) == .failed("Other()"))
  }
}
