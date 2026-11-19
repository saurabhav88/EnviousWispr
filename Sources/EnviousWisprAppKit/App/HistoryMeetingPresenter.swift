import EnviousWisprCore
import Foundation
import Observation

/// How History shows a meeting row's text: each row's probable-echo choice, the meeting
/// projection, preview and summary text, and the meeting-text cache (#4586 N6). Owned by
/// `TranscriptCoordinator`, which decides when the cache is pruned.
@MainActor @Observable
final class HistoryMeetingPresenter {
  /// #3972 R5/R19: a meeting's History facts (echo turns, title, speaker outcomes), by meeting
  /// id, from EnviousMeet's in-memory durable copy. Observable on that side, so a view that
  /// reads it redraws when the meeting changes. Nil (tests, or before wiring) and an unknown
  /// meeting both fail closed: the row shows nothing.
  @ObservationIgnored var meetingInfo: (@MainActor (UUID) -> MeetingHistoryInfo?)?
  /// Rows whose probable echo is shown (#3972 R19). Per row and in memory only: one row's
  /// choice never reaches another, and every row starts hidden.
  private(set) var echoShownRowIDs: Set<UUID> = []
  @ObservationIgnored private let meetingDocuments = HistoryMeetingDocumentCache()

  #if DEBUG
    var meetingDocumentCacheForTesting: HistoryMeetingDocumentCache { meetingDocuments }
  #endif

  /// Keeps only the meeting texts of `rows`, the writer's live and hydrated rows (#4586 N6).
  func prune(keeping rows: [Transcript]) {
    meetingDocuments.prune(keeping: rows)
  }

  /// Forgets every row's echo choice, for Delete All (#4586 N6).
  func clearEcho() {
    echoShownRowIDs.removeAll()
  }

  // MARK: - Meeting rows (#3972 R5, R19)

  func isShowingEcho(rowID: UUID) -> Bool { echoShownRowIDs.contains(rowID) }

  /// The document-scoped "Show probable echo" choice; C5 gives it a control.
  func setShowEcho(_ show: Bool, rowID: UUID) {
    if show { echoShownRowIDs.insert(rowID) } else { echoShownRowIDs.remove(rowID) }
  }

  /// #3973 C2: the probable-echo turn IDs of `row`'s own transcript generation, or nil when
  /// its facts are not known.
  func meetingEchoTurnIDs(of row: Transcript) -> Set<String>? {
    guard let meetingID = row.meetingID else { return nil }
    return meetingInfo?(meetingID)?.matching(row)?.echoTurnIDs
  }

  /// #3973 C2: whether `row`'s own transcript generation has probable-echo lines, the facts
  /// "Show probable echo" acts on. False for a row whose facts are not known.
  func meetingHasProbableEcho(_ row: Transcript) -> Bool {
    meetingEchoTurnIDs(of: row)?.isEmpty == false
  }

  /// What a meeting row shows; `.unavailable` for a row that is not a meeting.
  func meetingProjection(of row: Transcript) -> MeetingHistoryPresentation.Projection {
    guard let meetingID = row.meetingID else { return .unavailable }
    // #3973 C2: only the facts of this row's own transcript generation.
    let info = meetingInfo?(meetingID)?.matching(row)
    let showEcho = isShowingEcho(rowID: row.id)
    // #4075 R6: the plain text comes from the kept meeting text (the same projection search and
    // the preview read), so a detail redraw does not rebuild the whole meeting's text. Only the
    // visible turns, a filter, are computed here.
    let text = meetingDocuments.text(
      of: row, info: info, showEcho: showEcho, locale: Locale.current.identifier,
      localizations: Bundle.main.preferredLocalizations, bypass: false)
    switch text.kind {
    case .unavailable: return .unavailable
    case .everythingHidden: return .everythingHidden
    case .visible:
      guard let info else { return .unavailable }
      let visible = MeetingTranscriptProjection.visible(
        turns: row.turns ?? [], echoTurnIDs: info.echoTurnIDs, showEcho: showEcho)
      return .visible(turns: visible.turns, plainText: text.plain)
    }
  }

  /// A meeting row's two-line list preview, the same text `meetingProjection` gives, read from
  /// the kept meeting text (#4001 step 2a) so a row body does not project the whole meeting.
  /// The meeting info and echo choice are read on every call, so the row stays subscribed.
  func meetingPreviewText(of row: Transcript) -> String {
    guard let meetingID = row.meetingID else {
      return MeetingHistoryPresentation.unavailableMessage
    }
    let text = meetingDocuments.text(
      of: row, info: meetingInfo?(meetingID), showEcho: isShowingEcho(rowID: row.id),
      locale: Locale.current.identifier, localizations: Bundle.main.preferredLocalizations,
      bypass: false)
    switch text.kind {
    case .visible: return text.plain
    case .everythingHidden: return MeetingHistoryPresentation.everythingHiddenMessage
    case .unavailable: return MeetingHistoryPresentation.unavailableMessage
    }
  }

  /// A meeting summary's source text: the visible text, echo always hidden, nil when nothing is
  /// visible (`HistoryMeetingDocumentCache.summaryText`). The caller reads the row and the
  /// meeting facts live, before this lookup.
  func summaryVisibleText(of row: Transcript, info: MeetingHistoryInfo?) -> String? {
    summaryText(of: row, info: info).visibleText
  }

  /// #4148: true when the same projection is known and has no visible transcript text.
  func summaryHasNoWords(of row: Transcript, info: MeetingHistoryInfo?) -> Bool {
    summaryText(of: row, info: info).hasNoWords
  }

  private func summaryText(
    of row: Transcript, info: MeetingHistoryInfo?
  ) -> HistoryMeetingDocumentCache.MeetingText {
    meetingDocuments.summaryText(
      of: row, info: info, locale: Locale.current.identifier,
      localizations: Bundle.main.preferredLocalizations, bypass: false)
  }
}
