import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// The one owner of each meeting's record in memory and of the writes that make it durable
/// (#4008 F11), held by `MeetingCoordinator`. Moved out of the coordinator unchanged.
///
/// **Two copies, one truth.** `live` is each meeting's latest intended state: every change is
/// built on it and written through `MeetingFileWriter`. `records` is what is on disk, as last
/// written successfully: the coordinator's `meetings` and `record(id:)` show it, so nothing is
/// visible before its write succeeded.
///
/// **Answers can arrive in any order.** A bounded write answers on the main actor before an
/// earlier async write's continuation runs, so each write carries a sequence number: only a
/// write newer than the one already shown replaces it, and every answer, success or failure,
/// recomputes `live` from the writes still unanswered. A meeting removed meanwhile is not
/// brought back.
@MainActor
@Observable
final class MeetingRecordPersistence {
  /// What the coordinator does on each outcome: show the new records, tell the user a save
  /// failed, and log a bounded save still running at its deadline. Set once at construction; neither runs inside a state change of this type.
  struct Events {
    var published: @MainActor () -> Void
    var failed: @MainActor (Error) -> Void
    var stillRunning: @MainActor () -> Void
  }

  /// Each meeting as last written successfully.
  private(set) var records: [UUID: MeetingRecord] = [:]
  /// Each meeting's latest intended state: what every next change is built on (a pending write
  /// included), so two steps in flight never lose each other's change.
  private(set) var live: [UUID: MeetingRecord] = [:]

  /// Per meeting, the number of the latest write asked for, and of the newest one shown.
  @ObservationIgnored private var writeSequence: [UUID: Int] = [:]
  @ObservationIgnored private var durableSequence: [UUID: Int] = [:]
  /// Per meeting, writes asked for and not yet answered, oldest first: what a failed newer
  /// write rolls the live copy back to, so an earlier change still on its way is kept.
  @ObservationIgnored private var unansweredWrites:
    [UUID: [(sequence: Int, record: MeetingRecord)]] =
      [:]

  @ObservationIgnored private let writer: MeetingFileWriter
  @ObservationIgnored private let events: Events

  #if DEBUG
    /// Runs after an ordinary write landed and before its answer is applied, so a test can
    /// hold that answer behind later writes in a chosen order (#4102).
    @ObservationIgnored var writeWillAnswerForTesting: (@MainActor (MeetingRecord) async -> Void)?
  #endif

  init(writer: MeetingFileWriter, events: Events) {
    self.writer = writer
    self.events = events
  }

  // MARK: - State the coordinator sets directly

  /// A meeting that exists on disk and is not yet known here (launch listing, a created
  /// start): both copies become `record`, the intended one first.
  func adopt(_ record: MeetingRecord) {
    live[record.id] = record
    records[record.id] = record
  }

  /// A commit settled from disk (barrier recovery): the shown copy is set first, then the
  /// intended one, the order the coordinator always used there.
  func adoptSettled(_ record: MeetingRecord, for meetingID: UUID) {
    records[meetingID] = record
    live[meetingID] = record
  }

  /// Only the intended copy changes: a record whose write failed twice and that the coordinator
  /// keeps as its intention.
  func adoptLive(_ record: MeetingRecord) {
    live[record.id] = record
  }

  /// A meeting whose folder is gone.
  func remove(_ meetingID: UUID) {
    live.removeValue(forKey: meetingID)
    records.removeValue(forKey: meetingID)
  }

  // MARK: - Writes

  /// Makes `record` the live copy, writes it off the main actor in order, and shows it only
  /// once the write succeeded. False (and `events.failed`) when it could not be saved; the live
  /// copy then returns to what is on disk, unless a newer change was asked for since.
  func save(_ record: MeetingRecord) async -> Bool {
    let sequence = beginWrite(record)
    do {
      try await writer.save(record)
      #if DEBUG
        await writeWillAnswerForTesting?(record)
      #endif
      writeSucceeded(record, sequence: sequence)
      return true
    } catch {
      writeFailed(error, record: record, sequence: sequence)
      return false
    }
  }

  /// `save` bounded by `deadline` on the caller's thread, for the quit path, which cannot
  /// suspend. True only when it landed in time. A write withdrawn before it started counts as
  /// failed and rolls back. A write still running at the deadline keeps the live copy and
  /// reports once when it ends: a success is then shown (and `lateSuccess` runs), a failure
  /// rolls back.
  func saveBounded(
    _ record: MeetingRecord, until deadline: DispatchTime,
    lateSuccess: (@MainActor () -> Void)? = nil
  ) -> Bool {
    let sequence = beginWrite(record)
    let outcome = writer.saveBounded(
      record, until: deadline,
      late: lateSettlement(record, sequence: sequence, lateSuccess: lateSuccess))
    return settle(outcome, record: record, sequence: sequence)
  }

  /// `saveBounded` for Delete All, which suspends instead of blocking (#4102): the same
  /// deadline, answers and late report.
  func saveWithin(
    _ record: MeetingRecord, until deadline: DispatchTime,
    lateSuccess: (@MainActor () -> Void)? = nil
  ) async -> Bool {
    let sequence = beginWrite(record)
    let outcome = await writer.saveWithin(
      record, until: deadline,
      late: lateSettlement(record, sequence: sequence, lateSuccess: lateSuccess))
    return settle(outcome, record: record, sequence: sequence)
  }

  /// The report of a bounded write that was still running at its deadline. It may reach the
  /// main actor before or after the caller's own answer; `settle` leaves a still-running write
  /// unanswered, so either order settles it once.
  private func lateSettlement(
    _ record: MeetingRecord, sequence: Int, lateSuccess: (@MainActor () -> Void)?
  ) -> @Sendable (Result<Void, Error>) -> Void {
    { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case .success:
          self.writeSucceeded(record, sequence: sequence)
          lateSuccess?()
        case .failure(let error):
          self.writeFailed(error, record: record, sequence: sequence)
        }
      }
    }
  }

  /// A bounded write's answer to its caller: true only when it landed in time.
  private func settle(
    _ outcome: MeetingFileWriter.BoundedOutcome, record: MeetingRecord, sequence: Int
  ) -> Bool {
    switch outcome {
    case .finished(.success):
      writeSucceeded(record, sequence: sequence)
      return true
    case .finished(.failure(let error)):
      writeFailed(error, record: record, sequence: sequence)
      return false
    case .withdrawn:
      writeFailed(MeetingFileWriter.WriterError.withdrawn, record: record, sequence: sequence)
      return false
    case .stillRunning:
      events.stillRunning()
      return false
    }
  }

  private func beginWrite(_ record: MeetingRecord) -> Int {
    live[record.id] = record
    let sequence = (writeSequence[record.id] ?? 0) + 1
    writeSequence[record.id] = sequence
    unansweredWrites[record.id, default: []].append((sequence, record))
    return sequence
  }

  /// Settles one write's answer and recomputes the live copy from what is left: the newest
  /// write still unanswered (its change is still on its way) when it is newer than the newest
  /// durable success, else that durable success. Run on
  /// every answer, success or failure, newest or not, so an earlier write that fails after a
  /// newer one was withdrawn rolls back too. A meeting already removed is not brought back.
  private func answered(_ meetingID: UUID, sequence: Int) {
    unansweredWrites[meetingID]?.removeAll { $0.sequence == sequence }
    if unansweredWrites[meetingID]?.isEmpty == true { unansweredWrites[meetingID] = nil }
    guard live[meetingID] != nil else { return }
    // The newer of the two: an unanswered intention older than what is already durable (a
    // bounded write that succeeded first) must not replace it.
    if let pending = unansweredWrites[meetingID]?.last,
      pending.sequence > (durableSequence[meetingID] ?? 0)
    {
      live[meetingID] = pending.record
    } else {
      live[meetingID] = records[meetingID]
    }
  }

  /// Acknowledgements can resume out of order (a bounded write answers on the main actor
  /// before an earlier async write's continuation runs), so only a write newer than the one
  /// already shown may replace it. The disk holds the newest anyway (FIFO).
  private func writeSucceeded(_ record: MeetingRecord, sequence: Int) {
    // A meeting removed meanwhile (its folder deleted) is not brought back.
    if live[record.id] != nil, sequence > (durableSequence[record.id] ?? 0) {
      durableSequence[record.id] = sequence
      records[record.id] = record
      events.published()
    }
    answered(record.id, sequence: sequence)
  }

  private func writeFailed(_ error: Error, record: MeetingRecord, sequence: Int) {
    events.failed(error)
    answered(record.id, sequence: sequence)
  }
}
