import CryptoKit
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// The pure arithmetic of a file import's document, moved off `FileImportCoordinator` as a
/// semantic no-op (#2935): joining parts, placing passages, cutting the cleanup's pieces,
/// assembling the final turns, the PCM digest, the refusal and speaker-log mappings. None of
/// it reads coordinator state; `placedPassages` takes the three values the instance method
/// read. Every causal comment travels with its code verbatim (workflow-process RULE:
/// move-recorded-reasons-before-simplifying); nothing here is simplified in the move.
///
/// `@MainActor` because these were statics of a `@MainActor` class and the port keeps their
/// isolation exactly; lifting it is a later change with its own review, not this move.
@MainActor
enum FileImportDocumentMath {
  /// The document as the parts make it: a blank line between parts (one paragraph per
  /// passage, or per speaker section), but two pieces of ONE long turn rejoin with the raw
  /// gap that lay between them, never an invented paragraph break (cloud review of PR #2898:
  /// a space-free script cut at a character boundary has no gap at all).
  static func joinedDocument(_ parts: [FileImportCoordinator.Part]) -> String {
    var out = ""
    for (index, part) in parts.enumerated() {
      out += part.text
      guard index + 1 < parts.count else { break }
      let next = parts[index + 1]
      if let id = part.turnID, next.turnID == id {
        out += part.trailingGap
      } else {
        out += "\n\n"
      }
    }
    return out
  }

  /// Whether this refusal is about the ENGINE rather than the file.
  ///
  /// **The difference decides what the user has to redo.** A file we could not
  /// read needs a different file. A busy engine, a missing model or a warm-up
  /// that did not take needs nothing redone at all — the audio is decoded and in
  /// memory, and the message says "try again". It did not mean it: the only
  /// route back was choosing the file again and paying the read a second time,
  /// which on a long recording is the slowest part. Found by Codex.
  static func isAboutTheEngine(_ reason: FileImportCoordinator.FileImportRejection) -> Bool {
    switch reason {
    case .engineBusy, .engineNotInstalled, .engineNotReady: return true
    // About the POLISHER, not the transcription engine: nothing needs reading again, so
    // Try again (which re-transcribes) is the wrong offer. The document is in hand, the
    // refusal renders beside it on Done, and Review's Clean it again is the retry.
    case .cannotRead, .noAudio, .noSpeechFound, .polisherNotReady, .failed: return false
    }
  }

  /// One cleanup passage as the scan placed it in the raw transcript (#2851 §3c: computed
  /// ONCE here and shared by the marked-up view and the turn-text alignment).
  struct PlacedPassage: Equatable, Sendable {
    let placement: PiecePlacement
    /// The passage's original text: from the previous cursor to the piece's end, so the gap
    /// BEFORE the piece rides with it; the unplaceable case carries the piece itself.
    let original: String
    let cleaned: String?
  }

  /// The split's pieces are the passages the cleanup ran on, in order; `parts[i]` is what it
  /// made of `pendingPieces[i]`. A piece past the last finished part was never reached.
  /// Each passage's original is recovered FROM the transcript, not taken from the piece:
  /// `TranscriptSplitter` slices from a word's start to a word's end and drops the
  /// whitespace between pieces, so the pieces concatenated rendered "alphaalpha" across a
  /// cut. Each piece is found by scanning forward, and the passage is the text from the
  /// cursor to the piece's end, so the gap BEFORE a piece rides with it; the last passage
  /// runs to the transcript's end. Every gap renders exactly as spoken. A piece the scan
  /// cannot place should not happen (the splitter yields ordered verbatim slices); if it
  /// did, that piece is compared directly, marked unplaceable for the aligner, and the
  /// cursor does not advance, so later pieces still place by their own scan (Codex,
  /// confirming round; #2851 P5).
  static func placedPassages(
    rawTranscript: String, pieces pendingPieces: [String], parts: [FileImportCoordinator.Part]
  ) -> [PlacedPassage] {
    var cursor = rawTranscript.startIndex
    var passages: [PlacedPassage] = []
    for (index, piece) in pendingPieces.enumerated() {
      let cleaned = index < parts.count ? parts[index].text : nil
      // No per-passage polish flag here (#2851 §3 D retired it with the aligner): the turns'
      // `isUnpolished` drives the "Not fully polished" disclosure, and the header's credit reads
      // `Part.wasPolished`; the Marked up view reads only `original` and `cleaned` (found by the
      // #2864 night battery, 2026-09-14: the field had no production reader).
      guard
        let found = rawTranscript.range(
          of: piece, options: .literal, range: cursor..<rawTranscript.endIndex)
      else {
        passages.append(
          PlacedPassage(placement: .unplaceable, original: piece, cleaned: cleaned))
        continue
      }
      let end = index == pendingPieces.count - 1 ? rawTranscript.endIndex : found.upperBound
      let rawRange = cursor.utf16Offset(in: rawTranscript)..<end.utf16Offset(in: rawTranscript)
      let contentRange =
        found.lowerBound.utf16Offset(in: rawTranscript)..<end.utf16Offset(in: rawTranscript)
      passages.append(
        PlacedPassage(
          placement: .placed(rawRange: rawRange, contentRange: contentRange),
          original: String(rawTranscript[cursor..<end]), cleaned: cleaned))
      cursor = end
    }
    return passages
  }

  /// Where a cleanup piece sits in the raw transcript, for the marked-up view. UTF-16 ranges
  /// from the coordinator's own scan (never a cumulative length): `rawRange` is the piece's
  /// ORIGINAL text including the gap that precedes its first word; `contentRange` is the
  /// piece the scan actually found.
  enum PiecePlacement: Equatable, Sendable {
    case placed(rawRange: Range<Int>, contentRange: Range<Int>)
    case unplaceable
  }

  /// The part ceiling for a run's polisher (see `cleanupPieces`). Pure, pinned by
  /// `FileImportCoordinatorSpeakerTests`.
  static func partCeiling(_ configuration: FileImportCoordinator.RunConfiguration?) -> Int {
    // No frozen run (a cleanup asked for outside one), a cloud polisher, or NO polisher (the
    // smaller part exists for a polish budget that a run without polish never spends; cloud
    // review of PR #2927) keeps the wider default.
    guard let configuration, !configuration.polishIsCloud, configuration.polishProvider != .none
    else {
      return TranscriptSplitter.maximumWordsPerPart
    }
    return TranscriptSplitter.maximumWordsPerLocalPart
  }

  /// Cuts the raw transcript into the pieces the cleanup runs on: one per speaker turn when
  /// the turns exist (a turn over the splitter's ceilings becomes several pieces carrying the
  /// same turn id), else the word-count passages of a single-speaker document. Each piece is
  /// a verbatim slice of `rawText`, in order, so `placedPassages()` finds it by literal search
  /// like any passage.
  ///
  /// `maximumWords` is the part ceiling for this run's polisher: `TranscriptSplitter.
  /// maximumWordsPerLocalPart` for an on-device polisher, whose time grows with the words,
  /// `maximumWordsPerPart` for a cloud one, whose cost grows with the calls.
  static func cleanupPieces(
    turns: [Turn]?, rawText: String, maximumWords: Int = TranscriptSplitter.maximumWordsPerPart
  ) -> Pieces {
    guard let turns, !turns.isEmpty else {
      return Pieces(
        pieces: TranscriptSplitter.split(rawText, maximumWords: maximumWords), turnIDs: [],
        gaps: [])
    }
    var pieces: [String] = []
    var ids: [String?] = []
    var gaps: [String] = []
    for turn in turns {
      let text = TranscriptDocumentPresenter.slice(rawText, turn.originalTextRange)
      let split = TranscriptSplitter.split(text, maximumWords: maximumWords)
      // The raw text between consecutive pieces of ONE turn, so the turn is rebuilt with
      // what really lay there: a space, a newline, or nothing at all when the splitter cut
      // a space-free script at a character boundary (cloud review of PR #2898). Found by
      // scanning forward, like `placedPassages()`.
      var cursor = text.startIndex
      var ends: [String.Index] = []
      var starts: [String.Index] = []
      for piece in split {
        guard let found = text.range(of: piece, options: .literal, range: cursor..<text.endIndex)
        else {
          ends.append(cursor)
          starts.append(cursor)
          continue
        }
        starts.append(found.lowerBound)
        ends.append(found.upperBound)
        cursor = found.upperBound
      }
      for (n, piece) in split.enumerated() {
        pieces.append(piece)
        ids.append(turn.id)
        let gap = n + 1 < split.count && ends[n] <= starts[n + 1]
          ? String(text[ends[n]..<starts[n + 1]]) : ""
        gaps.append(n + 1 < split.count ? gap : "")
      }
    }
    return Pieces(pieces: pieces, turnIDs: ids, gaps: gaps)
  }

  /// The cleanup's input, cut from the raw text: the pieces in order, the turn each belongs
  /// to (empty on a document with no turns), and the raw gap that follows each piece inside
  /// its turn ("" after a turn's last piece).
  struct Pieces: Equatable, Sendable {
    let pieces: [String]
    let turnIDs: [String?]
    let gaps: [String]
  }

  /// The turns as the final write stores them: each turn's cleaned words are its own pieces
  /// joined in order, and it is polished only when every piece was (a piece the polisher
  /// declined for being too short is not a failure: `PartOutcome.isUnpolished`). A turn with no
  /// piece keeps its raw words: not disclosed when the cleanup completed (a whitespace-only
  /// turn), disclosed when it did not reach the turn (Stop, or a refused polisher).
  static func finalTurns(
    _ turns: [Turn], parts: [FileImportCoordinator.Part], cleanupCompleted: Bool
  ) -> [Turn] {
    turns.map { turn in
      let mine = parts.filter { $0.turnID == turn.id }
      guard !mine.isEmpty else {
        return Turn(
          id: turn.id, speakerId: turn.speakerId, startMs: turn.startMs, endMs: turn.endMs,
          originalTextRange: turn.originalTextRange, processedText: nil,
          wasPolished: cleanupCompleted)
      }
      // Rebuilt with each piece's own raw gap, never an invented space.
      let joined = mine.map { $0.text + $0.trailingGap }.joined()
      return Turn(
        id: turn.id, speakerId: turn.speakerId, startMs: turn.startMs, endMs: turn.endMs,
        originalTextRange: turn.originalTextRange,
        processedText: joined,
        wasPolished: !mine.contains(where: \.isUnpolished))
    }
  }

  /// SHA-256 over the raw Float32 bytes of the PCM ASR consumed, so a retry can compare a
  /// re-decoded source against what actually ran without re-reading the whole buffer.
  /// #2809 addendum §2.5 "Retry identity" — a method with a unit test and no caller in
  /// phase 2; phase 4's retry-after-failure UI is the first caller.
  static func pcmDigestHex(_ samples: [Float]) -> String {
    samples.withUnsafeBufferPointer { buffer in
      let digest = SHA256.hash(data: Data(buffer: buffer))
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  static func speakerLogOutcome(_ analysis: SpeakerAnalysis) -> String {
    switch analysis {
    case .single: return "single"
    case .labeled: return "labeled"
    case .failed(let failure):
      switch failure {
      case .modelsUnavailable: return "failed_models_unavailable"
      case .analyzerThrew: return "failed_analyzer_threw"
      case .noSpeakerSegments: return "failed_no_speaker_segments"
      case .cancelled: return "cancelled"
      }
    case .timedOut: return "timed_out"
    }
  }

  static func speakerLogCount(_ analysis: SpeakerAnalysis) -> String {
    switch analysis {
    case .single: return "1"
    case .labeled(let count, _): return "\(count)"
    case .failed, .timedOut: return "n/a"
    }
  }

  static func rejection(for error: any Error) -> FileImportCoordinator.FileImportRejection {
    switch error {
    case AudioFileDecoder.Rejection.unreadable:
      return .cannotRead
    case AudioFileDecoder.Rejection.noAudioTrack, AudioFileDecoder.Rejection.noAudio:
      return .noAudio
    default:
      return .failed(String(describing: error))
    }
  }
}
