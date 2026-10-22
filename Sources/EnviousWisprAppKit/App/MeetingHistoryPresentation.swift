import EnviousWisprCore
import Foundation

/// The meeting facts History needs beside a meeting's row (#3972 R5, R19), read from
/// EnviousMeet's in-memory durable copy through `TranscriptCoordinator.meetingInfo`, never
/// from the meeting's files while rendering, searching or exporting.
struct MeetingHistoryInfo: Equatable, Sendable {
  /// Ids of the row's turns that repeat the call sound (hidden unless shown).
  let echoTurnIDs: Set<String>
  let title: String?
  let speakerOutcomes: [MeetingTrackKind: MeetingSpeakerOutcome]

  /// The facts History may use for `record`'s row, or nil (History then shows and delivers
  /// nothing). Only a DURABLY ready record's echo IDs belong to the row History holds: the
  /// pass writes the new row first and the ready record after it, and Retry writes queued
  /// before its new row, so in any other state the row and the echo IDs may come from
  /// different passes. Pass the durable copy (`MeetingCoordinator.record(id:)`), never the
  /// latest intent. A meeting marked for deletion is nil too: nothing of it may be shown,
  /// copied, shared or pasted while its deletion runs, stalls or failed (Codex C8 r2).
  static func paired(with record: MeetingRecord?) -> MeetingHistoryInfo? {
    guard let record, record.state == .ready, !record.deletionRequested else { return nil }
    return MeetingHistoryInfo(record: record)
  }

  init(record: MeetingRecord) {
    echoTurnIDs = Set(record.echoTurnIDs)
    title = record.title
    speakerOutcomes = record.speakerOutcomes
  }

  init(
    echoTurnIDs: Set<String>, title: String? = nil,
    speakerOutcomes: [MeetingTrackKind: MeetingSpeakerOutcome] = [:]
  ) {
    self.echoTurnIDs = echoTurnIDs
    self.title = title
    self.speakerOutcomes = speakerOutcomes
  }
}

/// What a meeting row SHOWS in History, from what it STORES (#3972 R5, R19): the one decision
/// the list preview, the detail view, search, Copy, Save, Share and Paste all read, built on
/// `MeetingTranscriptProjection`. It fails closed: a meeting whose facts are not known shows
/// nothing rather than the raw text, which may hold hidden echo lines.
enum MeetingHistoryPresentation {
  enum Projection: Equatable {
    /// The turns to show, and their plain text (speaker-prefixed paragraphs).
    case visible(turns: [Turn], plainText: String)
    /// Turns exist and the echo setting hides every one of them (R19).
    case everythingHidden
    /// The meeting's facts are not available (not listed yet, or gone). Nothing is shown.
    case unavailable
  }

  static func project(
    _ row: Transcript, info: MeetingHistoryInfo?, showEcho: Bool,
    gapForms: MeetingGapPresentation.Forms = .interface
  ) -> Projection {
    guard let info else { return .unavailable }
    let turns = row.turns ?? []
    let visible = MeetingTranscriptProjection.visible(
      turns: turns, echoTurnIDs: info.echoTurnIDs, showEcho: showEcho)
    if visible.everythingHidden { return .everythingHidden }
    let plain = MeetingTranscriptProjection.plainText(
      text: row.text, turns: turns, speakerNames: row.speakerNames ?? [:],
      echoTurnIDs: info.echoTurnIDs, showEcho: showEcho,
      line: { MeetingGapPresentation.localized($0, forms: gapForms) })
    return .visible(turns: visible.turns, plainText: plain)
  }

  /// The text a meeting row delivers (Copy, Save, Share, Paste), in History's existing export
  /// format (`TranscriptDocumentPresenter.exportText`) over the visible turns only. Nil when
  /// nothing may be delivered: every line hidden, facts unavailable, or no turns.
  ///
  /// A meeting has no polish, so it always delivers its words as `.cleaned` (History shows no
  /// view picker for it). Each turn's own words get their gap markers in the interface language
  /// (`MeetingGapPresentation`) before the presenter adds names and times, so a speaker name is
  /// never rewritten. The stored row and its ranges are unchanged.
  static func deliveryText(
    _ row: Transcript, projection: Projection, timesOn: Bool,
    gapForms: MeetingGapPresentation.Forms = .interface
  ) -> String? {
    guard case .visible(let turns, _) = projection else { return nil }
    let shown = turns.map { turn in
      Turn(
        id: turn.id, speakerId: turn.speakerId, startMs: turn.startMs, endMs: turn.endMs,
        originalTextRange: turn.originalTextRange,
        processedText: MeetingGapPresentation.localized(
          turn.processedText
            ?? TranscriptDocumentPresenter.slice(row.text, turn.originalTextRange),
          forms: gapForms),
        wasPolished: turn.wasPolished, granularity: turn.granularity)
    }
    return TranscriptDocumentPresenter.exportText(
      turns: shown, rawText: row.text, speakerNames: row.speakerNames ?? [:], timesOn: timesOn,
      mode: .cleaned)?.text
  }

  /// The list preview line for a meeting row: visible text only.
  static func previewText(_ projection: Projection) -> String {
    switch projection {
    case .visible(_, let plainText): return plainText
    case .everythingHidden: return everythingHiddenMessage
    case .unavailable: return unavailableMessage
    }
  }

  static var everythingHiddenMessage: String {
    String(
      localized: "Every line was hidden as probable echo. Show probable echo to see them.",
      comment:
        "History: a meeting whose every line repeats the call sound, so all of them are hidden.")
  }

  static var unavailableMessage: String {
    String(
      localized: "This meeting isn't available right now.",
      comment: "History: a meeting row whose meeting details have not loaded or were removed.")
  }
}
