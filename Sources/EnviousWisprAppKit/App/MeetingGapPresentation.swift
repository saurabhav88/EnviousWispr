import Foundation

/// The interface-language form of a meeting's gap markers (#3972 C5).
///
/// The pass writes two fixed English markers into the stored text
/// (`MeetingTranscriptionJob.gapMarker` and `missingAudioMarker`):
/// `[Could not transcribe 1:00 to 1:30]` and `[Could not transcribe from 2:00]`. The stored text
/// and every turn's UTF-16 range stay as written; meeting readers call `localized(_:)` on text
/// they already sliced, so a translation never moves a range.
///
/// Only those exact forms are recognised: the brackets, the words and a `m:ss` or `h:mm:ss`
/// clock written by `MeetingTranscriptionJob.clock`. Speech never contains them (the engine
/// writes no brackets), so ordinary words, even the same words without brackets, are left
/// alone. Reopen this if a meeting engine that can emit brackets is added.
enum MeetingGapPresentation {
  /// The two marker forms in the current interface language.
  struct Forms: Sendable {
    /// A stretch with both ends known.
    let bounded: @Sendable (_ start: String, _ end: String) -> String
    /// A stretch whose end is not known.
    let from: @Sendable (_ start: String) -> String

    static let interface = Forms(
      bounded: { start, end in
        String(
          localized: "[Could not transcribe \(start) to \(end)]",
          comment:
            "EnviousMeet transcript: a stretch of the meeting that could not be turned into words. The two values are times in the meeting, like 1:00 and 1:30. Keep the square brackets."
        )
      },
      from: { start in
        String(
          localized: "[Could not transcribe from \(start)]",
          comment:
            "EnviousMeet transcript: the meeting could not be turned into words from this time on (the end is not known). The value is a time in the meeting, like 2:00. Keep the square brackets."
        )
      })
  }

  /// `text` with every exact gap marker in `forms`' language; everything else unchanged.
  static func localized(_ text: String, forms: Forms = .interface) -> String {
    guard text.contains("[Could not transcribe ") else { return text }
    // A clock as `MeetingTranscriptionJob.clock` writes it: `m:ss` (minutes one or more
    // digits) or `h:mm:ss`.
    let markerPattern =
      /\[Could not transcribe (?:(?<boundedStart>\d+:\d{2}(?::\d{2})?) to (?<boundedEnd>\d+:\d{2}(?::\d{2})?)|from (?<fromStart>\d+:\d{2}(?::\d{2})?))\]/

    return text.replacing(markerPattern) { match in
      if let start = match.output.boundedStart, let end = match.output.boundedEnd {
        return forms.bounded(String(start), String(end))
      }
      if let start = match.output.fromStart { return forms.from(String(start)) }
      return String(match.output.0)
    }
  }

  /// Rendered History turns with their plain text localized. A meeting row shows only plain
  /// turns (it has no polish to mark up); a marked-up turn passes through unchanged.
  static func localized(
    _ turns: [TranscriptDocumentPresenter.RenderedTurn]?, forms: Forms = .interface
  ) -> [TranscriptDocumentPresenter.RenderedTurn]? {
    turns?.map { turn in
      guard case .plain(let text) = turn.content else { return turn }
      return TranscriptDocumentPresenter.RenderedTurn(
        speakerId: turn.speakerId, speakerName: turn.speakerName, timeLabel: turn.timeLabel,
        content: .plain(localized(text, forms: forms)), isUncleaned: turn.isUncleaned,
        startMs: turn.startMs)
    }
  }
}
