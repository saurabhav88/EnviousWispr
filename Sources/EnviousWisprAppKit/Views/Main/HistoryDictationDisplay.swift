import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// What a History dictation card draws (#4609). Built from the catalog summary, so a card is
/// complete on first display and never resizes when a file read finishes, or from a live
/// `Transcript` (rows this process holds, the legacy reader). It is never written anywhere and
/// never delivered: Copy, Paste, Share, Save and every action read the live, verified row at the
/// press through `TranscriptCoordinator`.
///
/// Property names follow `Transcript`'s, so the card reads the same fields it always did.
struct HistoryDictationDisplay: Equatable, Sendable, Identifiable {
  let id: UUID
  let createdAt: Date
  let text: String
  let polishedText: String?
  let processedText: String?
  let preferredVersion: Transcript.PreferredVersion?
  let language: String?
  let backendName: String
  let llmProvider: String?
  let llmModel: String?
  /// `historyPolishEGOneSize ?? metrics?.polishModelSize`.
  let egOneSize: String?
  let inputDeviceWasRemoved: Bool?
  let isRecovered: Bool?
  let escapeRecoveredAt: Date?
  let escapeRecoveryTakeID: String?

  /// `Transcript.displayText`: polished, else processed, else the recognized text.
  var displayText: String { polishedText ?? processedText ?? text }

  /// `Transcript.effectivePreferredVersion`.
  var effectivePreferredVersion: Transcript.PreferredVersion { preferredVersion ?? .polished }

  init(_ row: Transcript) {
    id = row.id
    createdAt = row.createdAt
    text = row.text
    polishedText = row.polishedText
    processedText = row.processedText
    preferredVersion = row.preferredVersion
    language = row.language
    backendName = row.backendType.displayName
    llmProvider = row.llmProvider
    llmModel = row.llmModel
    egOneSize = row.historyPolishEGOneSize ?? row.metrics?.polishModelSize
    inputDeviceWasRemoved = row.inputDeviceWasRemoved
    isRecovered = row.isRecovered
    escapeRecoveredAt = row.escapeRecoveredAt
    escapeRecoveryTakeID = row.escapeRecoveryTakeID
  }

  /// Nil for a summary without the dictation projection (a catalog row indexed before #4609;
  /// the schema bump rebuilds those).
  init?(_ summary: HistoryCatalog.Summary) {
    guard summary.key.tab == .dictations, let data = summary.dictation else { return nil }
    id = summary.key.id
    createdAt = summary.date
    text = data.text
    polishedText = data.polishedText
    processedText = data.processedText
    preferredVersion = data.preferredVersion.flatMap(Transcript.PreferredVersion.init(rawValue:))
    language = data.language
    backendName = summary.backendName ?? ""
    llmProvider = data.llmProvider
    llmModel = data.llmModel
    egOneSize = data.egOneSize
    inputDeviceWasRemoved = summary.interrupted
    isRecovered = summary.recovered
    escapeRecoveredAt = data.escapeRecoveredAt
    escapeRecoveryTakeID = data.escapeRecoveryTakeID
  }

  /// The catalog's copy of a dictation's drawn fields, written by the projection.
  nonisolated static func catalogData(of row: Transcript) -> HistoryCatalog.DictationDisplay {
    HistoryCatalog.DictationDisplay(
      text: row.text, polishedText: row.polishedText, processedText: row.processedText,
      preferredVersion: row.preferredVersion?.rawValue, language: row.language,
      llmProvider: row.llmProvider, llmModel: row.llmModel,
      egOneSize: row.historyPolishEGOneSize ?? row.metrics?.polishModelSize,
      targetApp: row.metrics?.targetApp, escapeRecoveredAt: row.escapeRecoveredAt,
      escapeRecoveryTakeID: row.escapeRecoveryTakeID)
  }
}
