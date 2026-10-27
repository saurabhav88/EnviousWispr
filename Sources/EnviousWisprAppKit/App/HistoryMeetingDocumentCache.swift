import EnviousWisprCore
import Foundation

/// History's memoized meeting document text (#4102 S2): the display/search text and the
/// summary text, each kept per row while what it is made from is unchanged. Owned by one
/// `TranscriptCoordinator`, which reads every live input (rows, meeting facts, echo choice,
/// locale) before it asks; this type reads no observable state itself.
@MainActor final class HistoryMeetingDocumentCache {
  /// #4001: a meeting's visible text and which projection it came from, kept per row while what
  /// it is made from is unchanged, so neither a search keystroke nor a row's preview projects
  /// every meeting again. Search and the preview read this one entry.
  func text(
    of row: Transcript, info: MeetingHistoryInfo?, showEcho: Bool, locale: String,
    localizations: [String], bypass: Bool
  ) -> MeetingText {
    let inputs = SearchTextInputs(
      text: row.text, turns: row.turns ?? [], speakerNames: row.speakerNames ?? [:],
      info: info, showEcho: showEcho, locale: locale, localizations: localizations)
    if bypass { return Self.meetingText(row, inputs) }
    if let kept = searchTextCache[row.id], kept.inputs == inputs,
      MeetingDocumentHash.sameBytes(kept.inputs.text, inputs.text),
      MeetingDocumentHash.sameBytes(kept.inputs.speakerNames, inputs.speakerNames)
    {
      return kept.text
    }
    let text = Self.meetingText(row, inputs)
    #if DEBUG
      meetingTextBuildsForTesting += 1
    #endif
    searchTextCache[row.id] = (inputs, text)
    return text
  }

  /// A meeting summary's echo-hidden projection, including its availability and emptiness.
  /// Uses the same projection as search and preview, with a separate cache so the display's
  /// echo choice never evicts it. Reused only for byte-identical words and names because
  /// summary fingerprints hash bytes. The caller reads the row and meeting facts live.
  func summaryText(
    of row: Transcript, info: MeetingHistoryInfo?, locale: String, localizations: [String],
    bypass: Bool
  ) -> MeetingText {
    let inputs = SearchTextInputs(
      text: row.text, turns: row.turns ?? [], speakerNames: row.speakerNames ?? [:],
      info: info, showEcho: false, locale: locale, localizations: localizations)
    let text: MeetingText
    if !bypass, let kept = summaryTextCache[row.id], kept.inputs == inputs,
      MeetingDocumentHash.sameBytes(kept.inputs.text, inputs.text),
      MeetingDocumentHash.sameBytes(kept.inputs.speakerNames, inputs.speakerNames)
    {
      text = kept.text
    } else {
      text = Self.meetingText(row, inputs)
      #if DEBUG
        meetingTextBuildsForTesting += 1
      #endif
      if !bypass { summaryTextCache[row.id] = (inputs, text) }
    }
    return text
  }

  private var summaryTextCache: [UUID: (inputs: SearchTextInputs, text: MeetingText)] = [:]

  private static func meetingText(_ row: Transcript, _ inputs: SearchTextInputs) -> MeetingText {
    switch MeetingHistoryPresentation.project(row, info: inputs.info, showEcho: inputs.showEcho) {
    case .visible(_, let plain): MeetingText(kind: .visible, plain: plain)
    case .everythingHidden: MeetingText(kind: .everythingHidden, plain: "")
    case .unavailable: MeetingText(kind: .unavailable, plain: "")
    }
  }

  /// Which projection a kept meeting text came from: an empty `.visible` text is not a hidden
  /// or unavailable meeting, so the kind is kept beside the text, not read from it.
  struct MeetingText {
    enum Kind { case visible, everythingHidden, unavailable }
    let kind: Kind
    let plain: String

    /// The text a summary is written from; nil when nothing is visible.
    var visibleText: String? {
      kind == .visible && !plain.isEmpty ? plain : nil
    }

    /// #4148: known inputs with no visible transcript text (visible but empty, or every turn
    /// hidden as probable echo). Unavailable is not empty: those facts are not known.
    var hasNoWords: Bool {
      switch kind {
      case .visible: plain.isEmpty
      case .everythingHidden: true
      case .unavailable: false
      }
    }
  }

  /// What a meeting's searchable text is made from (`Transcript` is not Equatable).
  private struct SearchTextInputs: Equatable {
    let text: String
    let turns: [Turn]
    let speakerNames: [String: String]
    let info: MeetingHistoryInfo?
    let showEcho: Bool
    let locale: String
    let localizations: [String]
  }

  private var searchTextCache: [UUID: (inputs: SearchTextInputs, text: MeetingText)] = [:]

  /// Drops kept text of rows that no longer exist; a changed row is caught by its inputs.
  func prune(keeping rows: [Transcript]) {
    guard !searchTextCache.isEmpty || !summaryTextCache.isEmpty else { return }
    let ids = Set(rows.map(\.id))
    searchTextCache = searchTextCache.filter { ids.contains($0.key) }
    summaryTextCache = summaryTextCache.filter { ids.contains($0.key) }
  }

  #if DEBUG
    /// How many times a meeting's text was projected rather than read from the kept entry.
    private(set) var meetingTextBuildsForTesting = 0
  #endif
}
