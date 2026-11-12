import AppKit
import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Observation

/// Meeting audio as retention sees it: the meetings that may expire and the owner's own removal.
@MainActor
protocol MeetingAudioRetaining: AnyObject {
  func audioRetentionCandidates() async -> [MeetingCoordinator.AudioRetentionCandidate]
  func removeAudioForRetention(
    meetingID: UUID, stillEligible: @MainActor (Date) -> Bool
  ) async -> MeetingCoordinator.AudioRetentionOutcome
}

extension MeetingCoordinator: MeetingAudioRetaining {}

/// Decides which recordings are past their keep period, or (in the threshold's automatic mode)
/// which dictation recordings to trim, and asks each kind's owner to remove them (#3147 §3.1,
/// §3b). It removes no file itself: dictation recordings go through
/// `DictationRecordings.removeAutomatically` (History's command order, the same path as Delete),
/// meeting audio through `MeetingCoordinator.removeAudioForRetention` (the Delete audio path).
///
/// Defaults delete nothing: both keep periods default to "until I delete" and the threshold to
/// "ask" (Gate 2, D2/D3). Kept recordings and meetings set to "until I delete" are never removed
/// automatically; text, notes and summaries are never touched.
///
/// A recording's age is its saved item's date (the dictation's `createdAt`, the meeting's end),
/// never a file date. It is expired once `days × 24 hours` have passed since then.
///
/// Runs at launch, on wake and every six hours, one pass at a time; overlapping requests merge.
/// A recording change asks for a storage re-check after a short pause. A shorter keep period is
/// never applied by a bare setting change: the Settings page calls `stage` (count preview), then
/// `commitStaged` or `undoStaged`; only a committed setting reaches a sweep.
@MainActor
@Observable
final class RecordingRetention {
  /// What History and Settings show about the storage warning threshold (chunk 6 presents it).
  enum StorageWarning: Sendable, Equatable {
    /// "Ask me to free space": over the threshold; nothing was deleted.
    case overThreshold(totalBytes: Int64, thresholdBytes: Int64)
    /// Automatic mode removed what it could; kept, playing, meeting or temporary audio keeps
    /// usage above the threshold.
    case cannotReachThreshold(totalBytes: Int64, thresholdBytes: Int64)
    /// Usage could not be fully measured, so nothing was removed for space.
    case usageUnknown(thresholdBytes: Int64)
  }

  /// One pass's outcome counts, for the content-free log and tests.
  struct SweepSummary: Sendable, Equatable {
    var expiredDictations = 0
    var expiredMeetings = 0
    var removedForSpace = 0
    var skipped = 0
    var failed = 0
  }

  /// A keep-period change waiting for the user's confirmation.
  enum RetentionChange: Sendable, Equatable {
    case dictations(DictationRecordingRetention)
    case meetings(MeetingRecordingRetention)
  }

  /// What the next sweep would remove under a staged change.
  struct RetentionPreview: Sendable, Equatable {
    let change: RetentionChange
    /// Recordings the change would remove at the next sweep; nil when they could not be counted
    /// (the Settings page then says so instead of a number).
    let recordingsToRemove: Int?
  }

  struct Dependencies {
    let settings: SettingsManager
    let recordings: DictationRecordings
    let archive: RecordingArchive
    /// Saved dates of permanent rows (`TranscriptStore.savedDates`).
    let savedDates: @MainActor (Set<UUID>) async -> (dates: [UUID: Date], unreadable: Set<UUID>)
    let meetings: @MainActor () -> (any MeetingAudioRetaining)?
    let usage: RecordingUsage
    var now: @MainActor () -> Date = { Date() }
    /// The threshold's size in bytes (`RecordingStorageWarningThreshold.bytes`); tests use small
    /// sizes so they need not write gigabytes.
    var thresholdBytes: @Sendable (RecordingStorageWarningThreshold) -> Int64? = { $0.bytes }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var log: @MainActor (String) -> Void = { message in
      Task { await AppLogger.shared.log(message, level: .info, category: "RecordingRetention") }
    }
  }

  static let sweepInterval: Duration = .seconds(6 * 60 * 60)
  /// A burst of recording changes (Delete All, a run of dictations) becomes one usage check.
  static let usageCheckDelay: Duration = .seconds(2)

  private(set) var warning: StorageWarning?
  private(set) var lastSweep: SweepSummary?
  private(set) var staged: RetentionPreview?
  /// Moves on every stage, Undo and commit, so a count that finishes late is dropped.
  @ObservationIgnored private var stageGeneration = 0

  @ObservationIgnored private let deps: Dependencies
  @ObservationIgnored private var started = false
  @ObservationIgnored private var pending: Set<Work> = []
  @ObservationIgnored private var runner: Task<Void, Never>?
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var usageCheck: Task<Void, Never>?
  @ObservationIgnored private var wakeObserver: NSObjectProtocol?

  private enum Work: Hashable {
    case sweep
    case usage
  }

  init(_ deps: Dependencies) {
    self.deps = deps
  }

  // MARK: - Lifecycle

  /// Starts the launch sweep, the wake observer and the six-hour timer. Idempotent. Never waits
  /// for anything capture or paste needs: each sweep waits for the archive's launch cleanup and
  /// the meetings' launch load on its own task.
  func start() {
    guard !started else { return }
    started = true
    deps.recordings.changes.onChange = { [weak self] in self?.recordingsChanged() }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.request(.sweep) }
    }
    let sleep = deps.sleep
    timer = Task { [weak self] in
      while !Task.isCancelled {
        do { try await sleep(Self.sweepInterval) } catch { return }
        self?.request(.sweep)
      }
    }
    request(.sweep)
  }

  /// Stops every task and observer. Idempotent; called at termination.
  func stop() {
    started = false
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
    timer?.cancel()
    timer = nil
    usageCheck?.cancel()
    usageCheck = nil
    // The pass ends at its next check; it clears `runner` itself, so a waiter sees it finish.
    runner?.cancel()
    pending = []
    deps.recordings.changes.onChange = nil
  }

  /// A retention or threshold setting changed (a committed keep period, or the threshold):
  /// sweep again under it.
  func settingsChanged() {
    request(.sweep)
  }

  /// Measure usage and re-check the threshold now (after a Settings deletion or a page open).
  func refresh() {
    request(.usage)
  }

  /// Whether `change` shortens its keep period and so must go through `stage`.
  func isShortening(_ change: RetentionChange) -> Bool {
    switch change {
    case .dictations(let new):
      Self.shortens(from: deps.settings.dictationRecordingRetention.days, to: new.days)
    case .meetings(let new):
      Self.shortens(from: deps.settings.meetingRecordingRetention.days, to: new.days)
    }
  }

  nonisolated static func shortens(from old: Int?, to new: Int?) -> Bool {
    guard let new else { return false }
    guard let old else { return true }
    return new < old
  }

  /// A longer keep period or "until I delete" removes nothing earlier than before, so it
  /// applies at once. A shortening is refused here (false): it must be staged and confirmed.
  @discardableResult
  func applyWithoutPreview(_ change: RetentionChange) -> Bool {
    guard !isShortening(change) else { return false }
    stageGeneration += 1
    staged = nil
    switch change {
    case .dictations(let retention): deps.settings.dictationRecordingRetention = retention
    case .meetings(let retention): deps.settings.meetingRecordingRetention = retention
    }
    return true
  }

  /// Awaitable end of every requested pass, for callers and tests.
  func waitUntilIdle() async {
    while let runner { await runner.value }
  }

  private func recordingsChanged() {
    guard started else { return }
    usageCheck?.cancel()
    let sleep = deps.sleep
    usageCheck = Task { [weak self] in
      do { try await sleep(Self.usageCheckDelay) } catch { return }
      self?.request(.usage)
    }
  }

  private func request(_ work: Work) {
    guard started else { return }
    pending.insert(work)
    guard runner == nil else { return }
    runner = Task { [weak self] in await self?.drain() }
  }

  private func drain() async {
    while started, !pending.isEmpty, !Task.isCancelled {
      let work = pending
      pending = []
      if work.contains(.sweep) {
        await sweep()
      } else {
        var summary = SweepSummary()
        await applyThreshold(&summary)
        logIfAny(summary)
      }
    }
    runner = nil
  }

  // MARK: - One pass

  private func sweep() async {
    await deps.recordings.waitForStartup()
    var summary = SweepSummary()
    await expireDictations(&summary)
    await expireMeetings(&summary)
    await applyThreshold(&summary)
    lastSweep = summary
    logIfAny(summary)
  }

  private func expireDictations(_ summary: inout SweepSummary) async {
    guard let days = deps.settings.dictationRecordingRetention.days else { return }
    guard let candidates = await dictationCandidates() else { return }
    let now = deps.now()
    let expired = candidates.filter { Self.isExpired(savedAt: $0.savedAt, days: days, now: now) }
    for candidate in expired {
      guard started else { return }
      let outcome = await deps.recordings.removeAutomatically(
        rowID: candidate.rowID, as: .expired(days: days),
        stillEligible: { [weak self, deps] in
          // The policy now, not the one this scan read: a longer period or "until I delete"
          // set since then keeps the recording. A stopped retention removes nothing.
          guard self?.started == true,
            deps.settings.dictationRecordingRetention.days == days
          else { return false }
          return Self.isExpired(savedAt: candidate.savedAt, days: days, now: deps.now())
        })
      count(outcome, into: &summary, removed: \.expiredDictations)
    }
  }

  private func expireMeetings(_ summary: inout SweepSummary) async {
    guard let days = deps.settings.meetingRecordingRetention.days,
      let meetings = deps.meetings()
    else { return }
    let now = deps.now()
    let expired = await meetings.audioRetentionCandidates()
      .filter { Self.isExpired(savedAt: $0.endedAt, days: days, now: now) }
      .sorted { $0.endedAt < $1.endedAt }
    for candidate in expired {
      guard started else { return }
      let outcome = await meetings.removeAudioForRetention(
        meetingID: candidate.meetingID,
        stillEligible: { [weak self, deps] endedAt in
          guard self?.started == true, deps.settings.meetingRecordingRetention.days == days
          else { return false }
          return Self.isExpired(savedAt: endedAt, days: days, now: deps.now())
        })
      switch outcome {
      case .removed: summary.expiredMeetings += 1
      case .skipped: summary.skipped += 1
      case .failed: summary.failed += 1
      }
    }
  }

  /// Measures usage, sets the warning and, in automatic mode, removes the oldest unpinned
  /// dictation recordings until usage is at or below the threshold or nothing more is eligible.
  /// Each removal is decided on a complete measurement of BOTH owners taken inside its own
  /// History command, so space freed meanwhile (a manual deletion, meeting audio removed) is
  /// seen and no recording goes that is no longer needed.
  private func applyThreshold(_ summary: inout SweepSummary) async {
    let snapshot = await deps.usage.measure()
    guard let threshold = deps.thresholdBytes(deps.settings.recordingStorageWarningThreshold) else {
      warning = nil
      return
    }
    guard let pressure = Self.pressure(snapshot, threshold: threshold) else {
      warning = .usageUnknown(thresholdBytes: threshold)
      return
    }
    guard pressure else {
      warning = nil
      return
    }
    guard deps.settings.recordingThresholdBehavior == .removeOldestDictations else {
      warning = .overThreshold(totalBytes: snapshot.totalBytes ?? 0, thresholdBytes: threshold)
      return
    }
    for candidate in await dictationCandidates() ?? [] {
      guard started else { return }
      // Measured inside the command, after the candidate's own checks: unmeasurable or at or
      // below the threshold ends trimming. A candidate skipped before that (kept or gone since
      // the scan) moves on to the next.
      let check = PressureCheck()
      let outcome = await deps.recordings.removeAutomatically(
        rowID: candidate.rowID, as: .removedForSpace,
        stillNeeded: { [deps] in
          let now = await deps.usage.measure()
          check.measured = true
          check.pressure = Self.pressure(now, threshold: threshold)
          return check.pressure == true
        },
        stillEligible: { [weak self, deps] in
          self?.started == true
            && deps.settings.recordingThresholdBehavior == .removeOldestDictations
            && deps.thresholdBytes(deps.settings.recordingStorageWarningThreshold) == threshold
        })
      if outcome == .skipped, check.measured, check.pressure != true { break }
      count(outcome, into: &summary, removed: \.removedForSpace)
    }
    let final = await deps.usage.measure()
    switch Self.pressure(final, threshold: threshold) {
    case nil: warning = .usageUnknown(thresholdBytes: threshold)
    case true?:
      warning = .cannotReachThreshold(totalBytes: final.totalBytes ?? 0, thresholdBytes: threshold)
    case false?: warning = nil
    }
  }

  /// What one removal's in-command measurement found.
  @MainActor private final class PressureCheck {
    var measured = false
    var pressure: Bool?
  }

  /// True above the threshold, false at or below, nil when usage could not be fully measured
  /// (a partial measurement could hide audio, so it never authorizes removal).
  private nonisolated static func pressure(
    _ snapshot: RecordingUsageSnapshot, threshold: Int64
  ) -> Bool? {
    guard snapshot.isComplete, let total = snapshot.totalBytes else { return nil }
    return total > threshold
  }

  private func count(
    _ outcome: DictationRecordings.AutomaticRemovalOutcome, into summary: inout SweepSummary,
    removed: WritableKeyPath<SweepSummary, Int>
  ) {
    switch outcome {
    case .removed: summary[keyPath: removed] += 1
    case .skipped: summary.skipped += 1
    case .failed: summary.failed += 1
    }
  }

  private func logIfAny(_ summary: SweepSummary) {
    guard summary != SweepSummary() else { return }
    deps.log(
      "recording retention expiredDictations=\(summary.expiredDictations) "
        + "expiredMeetings=\(summary.expiredMeetings) removedForSpace=\(summary.removedForSpace) "
        + "skipped=\(summary.skipped) failed=\(summary.failed)")
  }

  // MARK: - Candidates

  struct DictationCandidate: Sendable, Equatable {
    let rowID: UUID
    let savedAt: Date
  }

  /// Unpinned dictation recordings with a readable saved date, oldest first. Nil when the
  /// archive or its Keep list cannot be read, which authorizes nothing. A row whose date cannot
  /// be read is left out (never guessed old).
  private func dictationCandidates() async -> [DictationCandidate]? {
    let recorded: Set<UUID>
    let pinned: Set<UUID>
    do {
      recorded = try await deps.archive.index()
      pinned = try await deps.archive.pinnedRowIDs()
    } catch {
      deps.log("recording retention skipped: archive unreadable \(type(of: error))")
      return nil
    }
    let (dates, unreadable) = await deps.savedDates(recorded.subtracting(pinned))
    if !unreadable.isEmpty {
      deps.log("recording retention left out \(unreadable.count) rows with unreadable dates")
    }
    return dates.map { DictationCandidate(rowID: $0.key, savedAt: $0.value) }
      .sorted { ($0.savedAt, $0.rowID.uuidString) < ($1.savedAt, $1.rowID.uuidString) }
  }

  /// Expired once `days × 24 hours` have passed since the saved date.
  nonisolated static func isExpired(savedAt: Date, days: Int, now: Date) -> Bool {
    now.timeIntervalSince(savedAt) >= Double(days) * 86_400
  }

  // MARK: - Shortening: count preview, then commit or Undo

  /// Counts what the next sweep would remove under `change` and holds it as the staged change.
  /// Writes no setting and removes nothing, so a sweep that runs meanwhile still uses the
  /// current setting. Any earlier staged change stops being committable at once. Nil when a
  /// newer stage, an Undo or a commit came while this one was counting: it is dropped, never
  /// shown or committed.
  @discardableResult
  func stage(_ change: RetentionChange) async -> RetentionPreview? {
    stageGeneration += 1
    let generation = stageGeneration
    staged = nil
    let now = deps.now()
    let count: Int?
    switch change {
    case .dictations(let retention):
      if let days = retention.days {
        count = await dictationCandidates().map { candidates in
          candidates.filter { Self.isExpired(savedAt: $0.savedAt, days: days, now: now) }.count
        }
      } else {
        count = 0
      }
    case .meetings(let retention):
      if let days = retention.days, let meetings = deps.meetings() {
        count = await meetings.audioRetentionCandidates()
          .filter { Self.isExpired(savedAt: $0.endedAt, days: days, now: now) }.count
      } else {
        count = retention.days == nil ? 0 : nil
      }
    }
    guard generation == stageGeneration else { return nil }
    let preview = RetentionPreview(change: change, recordingsToRemove: count)
    staged = preview
    return preview
  }

  /// The user kept the staged change: it becomes the setting and the next sweep applies it.
  func commitStaged() {
    guard let staged else { return }
    stageGeneration += 1
    self.staged = nil
    switch staged.change {
    case .dictations(let retention): deps.settings.dictationRecordingRetention = retention
    case .meetings(let retention): deps.settings.meetingRecordingRetention = retention
    }
    request(.sweep)
  }

  /// Undo: the staged change is dropped and the setting stays as it was.
  func undoStaged() {
    stageGeneration += 1
    staged = nil
  }
}
