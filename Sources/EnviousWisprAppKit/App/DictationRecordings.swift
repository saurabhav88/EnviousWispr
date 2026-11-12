import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// The app side of saved dictation recordings (#3147 §3.1 "Archive durability"): every change
/// to the archive goes through History's one command queue (`HistoryTransactionExecutor.admit`),
/// so a save, a deletion and a late encode can never overtake each other.
///
/// How one recording is kept:
/// 1. A command mints a ticket for the row (its current audio generation).
/// 2. Encoding runs OUTSIDE the queue, at utility priority, into the archive's own partial path,
///    so History is never held while audio compresses.
/// 3. A second command publishes it only if the ticket is still current and the permanent row
///    file still exists. Otherwise it removes only its own partial file.
///
/// Every deletion (audio only, the row, Delete All) withdraws the row's ticket first, so an
/// encode that finishes later is discarded instead of bringing audio back. A newer ticket for
/// the same row replaces an older one, so an older encode can never overwrite newer audio.
///
/// Integration obligations for later chunks: the take-start recording preference and the
/// permanent-save receipt arrive with the capture producer (Chunk 3B); before a deletion command
/// gains a playback consumer (Chunk 4), it stops that recording through the shared playback
/// owner on this same path.
@MainActor final class DictationRecordings {
  /// One admitted audio operation: the row and the generation it was admitted under.
  struct Ticket: Sendable, Equatable {
    let rowID: UUID
    let generation: UInt64
  }

  /// What became of one `record` call.
  enum Outcome: Sendable, Equatable {
    case stored
    case storedWithoutTimings
    /// The row or its audio was deleted, or a newer recording replaced it, while encoding ran.
    case discarded
    /// Encoding or publication failed; `saveFailed` is recorded for the row.
    case failed
  }

  typealias Encode = @Sendable (_ samples: [Float], _ destination: URL) throws -> Void

  private let archive: RecordingArchive
  private let executor: HistoryTransactionExecutor
  /// Whether the permanent row file exists now (`HistoryTransactionExecutor.readRow`).
  private let permanentRowExists: @MainActor (UUID) async throws -> Bool
  /// Ids of every permanent row file, nil when that cannot be certified.
  private let permanentRowIDs: @MainActor () async throws -> Set<UUID>?
  private let encode: Encode

  /// The one generation authority: the current ticket generation per row. A row with no entry
  /// has no admitted encode, so nothing may be published for it.
  private var generations: [UUID: UInt64] = [:]
  private var nextGeneration: UInt64 = 0
  private var startup: Task<Void, Never>?

  init(
    archive: RecordingArchive,
    executor: HistoryTransactionExecutor,
    permanentRowExists: @escaping @MainActor (UUID) async throws -> Bool,
    permanentRowIDs: @escaping @MainActor () async throws -> Set<UUID>?,
    encode: @escaping Encode = { samples, destination in
      _ = try SpeechAudioEncoder.encode(samples: samples, purpose: .dictation, to: destination)
    }
  ) {
    self.archive = archive
    self.executor = executor
    self.permanentRowExists = permanentRowExists
    self.permanentRowIDs = permanentRowIDs
    self.encode = encode
  }

  // MARK: - Launch

  /// Once per launch, before any recording is admitted: removes encodes the last run left
  /// behind, then removes recordings whose text row no longer exists. One History command, so no
  /// deletion can interleave. `record` waits for it, so cleanup never races an encode.
  func start() {
    guard startup == nil else { return }
    startup = Task { [self] in
      await executor.admit { [self] in await launchCleanup() }
    }
  }

  /// Awaitable completion of `start()`, for callers and tests that need the cleanup finished.
  func waitForStartup() async {
    await startup?.value
  }

  private func launchCleanup() async {
    do {
      let removed = try await archive.removeInterruptedPartials()
      if removed > 0 { log("removed \(removed) interrupted recording encodes") }
    } catch {
      log("interrupted encode cleanup failed: \(type(of: error))")
    }
    // The recordings are listed BEFORE the rows. Every listed recording was published while its
    // permanent row existed, and no row can be removed while this command holds the queue, so a
    // listed recording whose row is missing from the later listing is a true orphan.
    let recorded: Set<UUID>
    let rows: Set<UUID>
    do {
      recorded = try await archive.recordedRowIDs()
      guard let listed = try await permanentRowIDs() else {
        log("recording reconciliation skipped: History rows could not be certified")
        return
      }
      rows = listed
    } catch {
      log("recording reconciliation skipped: \(type(of: error))")
      return
    }
    var removed = 0
    for id in recorded.subtracting(rows) where generations[id] == nil {
      do {
        try await archive.forget(rowID: id)
        removed += 1
      } catch {
        log("orphan recording kept: \(type(of: error))")
      }
    }
    if removed > 0 { log("removed \(removed) recordings whose text row is gone") }
  }

  // MARK: - Keeping a recording

  /// Encodes `samples` for `rowID` and publishes it if the row and its audio are still current
  /// when encoding ends. Never call it from inside a History command: it admits two of its own.
  /// Callers that must not wait (capture, paste) run it in their own task.
  @discardableResult
  func record(rowID: UUID, samples: [Float], timing: RecordingTiming?) async -> Outcome {
    await waitForStartup()
    let ticket = await executor.admit { [self] in mintTicket(for: rowID) }

    let partial: URL
    do {
      partial = try await archive.partialURL(for: rowID)
    } catch {
      return await executor.admit { [self] in await failed(ticket, partial: nil, error) }
    }
    let encode = encode
    let encoded = await Task.detached(priority: .utility) {
      Result { try encode(samples, partial) }
    }.value

    return await executor.admit { [self] in
      guard isCurrent(ticket), (try? await permanentRowExists(rowID)) == true else {
        try? await archive.discardPartial(partial)
        if generations[rowID] == ticket.generation { generations[rowID] = nil }
        return .discarded
      }
      if case .failure(let error) = encoded {
        return await failed(ticket, partial: partial, error)
      }
      do {
        let stored = try await archive.store(rowID: rowID, fileURL: partial, timing: timing)
        generations[rowID] = nil
        return stored == .stored ? .stored : .storedWithoutTimings
      } catch {
        return await failed(ticket, partial: partial, error)
      }
    }
  }

  private func mintTicket(for rowID: UUID) -> Ticket {
    nextGeneration += 1
    generations[rowID] = nextGeneration
    return Ticket(rowID: rowID, generation: nextGeneration)
  }

  private func isCurrent(_ ticket: Ticket) -> Bool {
    generations[ticket.rowID] == ticket.generation
  }

  /// Inside a command: a current ticket whose encode or publication failed records `saveFailed`;
  /// a stale one changes nothing. Its partial file is removed either way.
  private func failed(_ ticket: Ticket, partial: URL?, _ error: any Error) async -> Outcome {
    if let partial { try? await archive.discardPartial(partial) }
    guard isCurrent(ticket) else { return .discarded }
    generations[ticket.rowID] = nil
    log("recording not saved: \(type(of: error))")
    do {
      try await archive.recordAbsence(.saveFailed, for: ticket.rowID)
    } catch {
      log("recording failure not recorded: \(type(of: error))")
    }
    return .failed
  }

  // MARK: - Commands for History, Settings and retention

  /// Deletes one recording and keeps its text, recording `reason`.
  func deleteRecording(rowID: UUID, reason: RecordingAbsence) async throws {
    try await executor.admit { [self] in
      await executor.capture { try await deleteRecordingInCommand(rowID: rowID, reason: reason) }
    }.get()
  }

  func pin(rowID: UUID) async throws {
    try await executor.admit { [self] in
      await executor.capture { try await archive.pin(rowID: rowID) }
    }.get()
  }

  func unpin(rowID: UUID) async throws {
    try await executor.admit { [self] in
      await executor.capture { try await archive.unpin(rowID: rowID) }
    }.get()
  }

  // MARK: - Inside an admitted History command (never admit again from these)

  /// Audio-only deletion. The ticket is withdrawn before the files go, so a late encode cannot
  /// bring the recording back even if the removal fails.
  func deleteRecordingInCommand(rowID: UUID, reason: RecordingAbsence) async throws {
    generations[rowID] = nil
    try await archive.delete(rowID: rowID, reason: reason)
  }

  /// The text row was removed (or was already gone): its recording, Keep mark and recorded
  /// reason go too.
  func forgetInCommand(rowID: UUID) async throws {
    generations[rowID] = nil
    try await archive.forget(rowID: rowID)
  }

  /// Delete All removed every text row: every ticket is withdrawn and the archive emptied.
  func removeAllInCommand() async throws {
    generations.removeAll()
    try await archive.removeEverything()
  }

  private func log(_ message: String) {
    Task { await AppLogger.shared.log(message, level: .info, category: "DictationRecordings") }
  }
}
