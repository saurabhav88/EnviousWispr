import EnviousWisprCore
import Foundation
import Observation

struct HistoryPolishChoice: Hashable, Sendable {
  let provider: LLMProvider
  let model: String
  var egOneSize: EGOneSize? = nil
  var sendsTextOffMac = false
}

@MainActor @Observable
final class HistoryRepolishRunner {
  enum Surface { case dictation, transcript, summary }
  enum Failure: Error { case busy, unavailable, noResult }

  let choices: @MainActor (Surface) -> [HistoryPolishChoice]
  private let admission: EngineAdmissionAccess
  private let freeze: @MainActor (ASRBackendType, HistoryPolishChoice) -> ImportedFileTranscriber.FrozenRun
  private let cleanup: ImportedFileTranscriber.Cleanup
  private let polishDictation: @MainActor (String, String?) async throws -> String?
  private let meetingInfo: @MainActor (Transcript) -> MeetingHistoryInfo?
  private(set) var heldRun: ImportedFileTranscriber.FrozenRun?

  init(
    choices: @escaping @MainActor (Surface) -> [HistoryPolishChoice],
    admission: EngineAdmissionAccess,
    freeze: @escaping @MainActor (ASRBackendType, HistoryPolishChoice) -> ImportedFileTranscriber.FrozenRun,
    cleanup: ImportedFileTranscriber.Cleanup,
    polishDictation: @escaping @MainActor (String, String?) async throws -> String?,
    meetingInfo: @escaping @MainActor (Transcript) -> MeetingHistoryInfo?
  ) {
    self.choices = choices
    self.admission = admission
    self.freeze = freeze
    self.cleanup = cleanup
    self.polishDictation = polishDictation
    self.meetingInfo = meetingInfo
  }

  func candidate(for row: Transcript, choice: HistoryPolishChoice) async throws -> HistoryPolishCandidate {
    try Task.checkCancellation()
    let document = row.isImported || row.isMeeting
    guard row.escapeRecoveredAt == nil, choices(document ? .transcript : .dictation).contains(choice)
    else { throw Failure.unavailable }
    let info = row.isMeeting ? meetingInfo(row) : nil
    guard !row.isMeeting || info != nil else { throw Failure.unavailable }
    guard case .granted(let token) = admission.claim() else { throw Failure.busy }
    let run = freeze(row.backendType, choice)
    heldRun = run
    defer {
      heldRun = nil
      admission.release(token)
      cleanup.release()
    }
    guard await cleanup.prepareLocalPolish(run.configuration) else { throw Failure.unavailable }
    try Task.checkCancellation()
    if document {
      return try await documentCandidate(for: row, meeting: info, run: run, choice: choice)
    }
    guard let output = try await polishDictation(row.text, row.language) else { throw Failure.noResult }
    return HistoryPolishCandidate(
      base: row, text: output, turns: nil, provider: choice.provider, model: choice.model,
      egOneSize: choice.egOneSize)
  }

  private func documentCandidate(
    for row: Transcript, meeting: MeetingHistoryInfo?, run: ImportedFileTranscriber.FrozenRun,
    choice: HistoryPolishChoice
  ) async throws -> HistoryPolishCandidate {
    let turns = row.turns
    let echoIDs = meeting?.echoTurnIDs ?? []
    let sourceTurns = turns?.filter { turn in
      !echoIDs.contains(turn.id)
        && (!row.isMeeting || !MeetingGapPresentation.containsGap(
          TranscriptDocumentPresenter.slice(row.text, turn.originalTextRange)))
    }
    guard !row.isMeeting || sourceTurns?.isEmpty == false else { throw Failure.noResult }
    let cut = FileImportDocumentMath.cleanupPieces(
      turns: sourceTurns, rawText: row.text,
      maximumWords: FileImportDocumentMath.partCeiling(run.configuration))
    var parts: [FileImportCoordinator.Part] = []
    try await cleanup.processParts(cut.pieces, row.language) { index, outcome in
      guard !Task.isCancelled, index == parts.count, cut.pieces.indices.contains(index)
      else { return false }
      parts.append(
        FileImportCoordinator.Part(
          id: index, text: outcome.displayText, isUnpolished: outcome.isUnpolished,
          wasPolished: outcome.polishedText != nil,
          turnID: cut.turnIDs.indices.contains(index) ? cut.turnIDs[index] : nil,
          trailingGap: cut.gaps.indices.contains(index) ? cut.gaps[index] : ""))
      return true
    }
    try Task.checkCancellation()
    guard parts.count == cut.pieces.count, parts.contains(where: \.wasPolished)
    else { throw Failure.noResult }
    let updated = turns.map { FileImportDocumentMath.finalTurns($0, parts: parts, cleanupCompleted: true) }
    let text = updated.map {
      $0.map { turn in
        turn.processedText ?? TranscriptDocumentPresenter.slice(row.text, turn.originalTextRange)
      }.joined(separator: "\n\n")
    } ?? FileImportDocumentMath.joinedDocument(parts)
    func previewText(_ source: [Turn]?, meeting info: MeetingHistoryInfo) -> String {
      MeetingTranscriptProjection.plainText(
        text: row.text, turns: source ?? [], speakerNames: row.speakerNames ?? [:],
        echoTurnIDs: info.echoTurnIDs, showEcho: false, line: { MeetingGapPresentation.localized($0) })
    }
    return HistoryPolishCandidate(
      base: row, text: text, turns: updated, provider: choice.provider, model: choice.model,
      egOneSize: choice.egOneSize,
      comparisonCurrentText: meeting.map { previewText(turns, meeting: $0) },
      comparisonNewText: meeting.map { previewText(updated, meeting: $0) })
  }
}
