import EnviousWisprCore
import Foundation
import Observation

/// #3147 PR3 (founder-delegated R7): Transcribe again with REPLACES an import's text in place,
/// after the user confirmed, keeping its id; History never shows two copies of one file.
///
/// **The one owner of every row's job state.** Every window showing a row reads this instance,
/// so two windows show one job, and a start from the second window while the first runs answers
/// `.busy` rather than starting a second job.
///
/// **Nothing runs before `startConfirmed`.** The confirmation is the caller's; this type is never
/// asked before it.
///
/// **The row changes only through History's replacement ticket.** The ticket is taken first, so
/// any change the row sees during the run (a rename, a relink, a deletion, a newer ticket, a
/// Cancel) makes the commit refuse and the old row stays. A failed transcription, an
/// unavailable original or a failed write leaves the old row as it was; no new row is ever
/// written.
@MainActor
@Observable
final class TranscriptRetranscription: ImportedTranscriptRetranscribing {
  private(set) var states: [UUID: ImportedRetranscriptionState] = [:]

  @ObservationIgnored private let history: TranscriptCoordinator
  @ObservationIgnored private let sources: any ImportedSourceAccessing
  @ObservationIgnored private let transcriber: ImportedFileTranscriber
  @ObservationIgnored private let installedModels: @MainActor () -> [ImportedASRChoice]
  @ObservationIgnored private var jobs: [UUID: Job] = [:]

  private struct Job {
    let id: UUID
    let task: Task<ImportedRetranscriptionOutcome, Never>
  }

  init(
    history: TranscriptCoordinator, sources: any ImportedSourceAccessing,
    transcriber: ImportedFileTranscriber,
    installedModels: @escaping @MainActor () -> [ImportedASRChoice]
  ) {
    self.history = history
    self.sources = sources
    self.transcriber = transcriber
    self.installedModels = installedModels
  }

  /// The run physically holding the engine claim, for the settings gates (see
  /// `ImportedFileTranscriber.heldRun`).
  var heldRun: ImportedFileTranscriber.FrozenRun? { transcriber.heldRun }
  var isEngineHeld: Bool { transcriber.isEngineHeld }

  /// The installed, usable models for an import, in the composition's order (`installedModels`
  /// reads delivery's admitted installs now and never downloads). Empty for a row that is gone
  /// or not an import.
  ///
  /// **No choice is marked current.** A row records its engine, not its model, and what is
  /// installed today does not say which model made old text (Parakeet v3 may have been removed
  /// since), so claiming one would be a guess.
  func choices(for rowID: UUID) -> [ImportedASRChoice] {
    guard let row = history.currentRow(id: rowID), row.isImported else { return [] }
    return installedModels().map { model in
      ImportedASRChoice(
        id: model.id, title: model.title, selection: model.selection, isCurrent: false)
    }
  }

  func state(for rowID: UUID) -> ImportedRetranscriptionState {
    states[rowID] ?? .idle
  }

  func startConfirmed(rowID: UUID, selection: ImportedASRSelection) async
    -> ImportedRetranscriptionOutcome
  {
    // One job per row; a job that is cancelling still counts until its work has exited.
    guard jobs[rowID] == nil else { return .busy }
    let jobID = UUID()
    states[rowID] = .running(fraction: nil)
    let task = Task { await self.run(rowID: rowID, selection: selection) }
    jobs[rowID] = Job(id: jobID, task: task)
    let outcome = await task.value
    if jobs[rowID]?.id == jobID {
      jobs[rowID] = nil
      states[rowID] = .finished(outcome)
    }
    return outcome
  }

  /// Cancels the row's job. The ticket goes stale at once, so a commit already under way
  /// refuses; the job then drains its engine work, unloads and releases the engine once, and
  /// finishes `.cancelled` with the old row unchanged.
  func cancel(rowID: UUID) {
    guard let job = jobs[rowID] else { return }
    states[rowID] = .cancelling
    history.invalidateImportedReplacement(for: rowID)
    job.task.cancel()
  }

  private func run(rowID: UUID, selection: ImportedASRSelection) async
    -> ImportedRetranscriptionOutcome
  {
    let ticket: ImportedReplacementTicket
    do {
      guard let minted = try await history.beginImportedReplacement(for: rowID) else {
        return Task.isCancelled ? .cancelled : .stale
      }
      ticket = minted
    } catch {
      return Task.isCancelled || error is CancellationError ? .cancelled : .failed
    }
    let outcome = await replace(rowID: rowID, selection: selection, ticket: ticket)
    if outcome != .replaced { history.invalidateImportedReplacement(for: rowID) }
    return outcome
  }

  private func replace(
    rowID: UUID, selection: ImportedASRSelection, ticket: ImportedReplacementTicket
  ) async -> ImportedRetranscriptionOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard case .available(let source) = await sources.state(for: rowID) else {
      return Task.isCancelled ? .cancelled : .sourceUnavailable
    }
    guard !Task.isCancelled else { return .cancelled }
    // The file found now must be the one the ticket's row links to.
    guard source.rowID == rowID, source.reference == ticket.source else { return .stale }

    let result: Transcript
    switch await transcriber.transcribe(
      url: source.url, identity: source.identity, selection: selection)
    {
    case .success(let transcript): result = transcript
    case .failure(.busy): return .busy
    case .failure(.sourceChanged): return .sourceUnavailable
    case .failure(.cancelled): return .cancelled
    case .failure(.modelUnavailable), .failure(.noSpeech), .failure(.failed): return .failed
    }
    guard !Task.isCancelled else { return .cancelled }
    do {
      if try await history.commitImportedReplacement(result, ticket: ticket) { return .replaced }
      // A Cancel during the command makes it refuse; that is the user's Cancel, not a change.
      return Task.isCancelled ? .cancelled : .stale
    } catch {
      return Task.isCancelled || error is CancellationError ? .cancelled : .failed
    }
  }
}
