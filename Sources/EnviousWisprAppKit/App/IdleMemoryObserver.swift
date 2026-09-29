import Darwin
import Foundation

/// One content-free memory sample per launch, taken the first time the app has been idle for
/// `idleThreshold` (#3289 §8b). It answers one question for the founder: after a release, does an
/// idle EnviousWispr give its memory back? Sentry's `app_memory` only rides on errors, so it cannot.
///
/// Idle means no dictation in flight and nothing holding the engine lease (a file import until its
/// work exits, crash recovery, an abandoned decode). The word check's idle timer asks a narrower
/// question (work that uses that check), so any stretch idle here is also idle for it. Work is
/// seen two ways, and both count as a
/// busy tick: the predicate true at a tick, or the engine lease's `admissionEpoch` changed since the
/// last tick. Every workload claims that one lease before it touches the engine (dictation at
/// arming, Transcribe a File at Start and Clean it again, crash recovery), so the epoch sees work
/// that started and ended between two ticks, however short, with no signal wired per entry point.
/// The first idle tick after a busy one restarts the stretch, because the work ended somewhere since
/// then. The stretch therefore never counts busy time as idle: it can only read up to one tick
/// SHORT, never long, so the sample always follows 12 real idle minutes (and the word check's
/// 10-minute unload).
///
/// Usage metrics off (#3269): nothing is sent, and any change to the switch, off or on, restarts
/// the stretch (`usageMetricsChanged`, from the settings callback), so turning metrics back on needs
/// a fresh full stretch; nothing is backfilled.
@MainActor
final class IdleMemoryObserver {
  struct Sample: Equatable {
    let footprintMB: Int
    let minutesSinceLaunch: Int
    let wordCheckLoaded: Bool
    let wordCheckWanted: Bool
  }

  static let idleThreshold: Duration = .seconds(12 * 60)
  static let tickInterval: Duration = .seconds(60)

  private let isWorkInFlight: @MainActor () -> Bool
  private let workEpoch: @MainActor () -> Int
  private var lastWorkEpoch: Int
  private let usageMetricsOn: @MainActor () -> Bool
  private let readFootprintMB: @MainActor () -> Int?
  private let wordCheckState: @MainActor () -> (loaded: Bool, wanted: Bool)
  private let emit: @MainActor (Sample) -> Void
  private let now: @MainActor () -> ContinuousClock.Instant
  private let launchedAt: ContinuousClock.Instant
  private var idleSince: ContinuousClock.Instant
  private(set) var hasSent = false
  /// The last tick saw work in flight; the next idle tick restarts the stretch.
  private var sawWork = false
  private var loop: Task<Void, Never>?

  init(
    isWorkInFlight: @escaping @MainActor () -> Bool,
    workEpoch: @escaping @MainActor () -> Int,
    usageMetricsOn: @escaping @MainActor () -> Bool,
    readFootprintMB: @escaping @MainActor () -> Int? = { IdleMemoryObserver.currentFootprintMB() },
    wordCheckState: @escaping @MainActor () -> (loaded: Bool, wanted: Bool),
    emit: @escaping @MainActor (Sample) -> Void,
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.isWorkInFlight = isWorkInFlight
    self.workEpoch = workEpoch
    lastWorkEpoch = workEpoch()
    self.usageMetricsOn = usageMetricsOn
    self.readFootprintMB = readFootprintMB
    self.wordCheckState = wordCheckState
    self.emit = emit
    self.now = now
    let start = now()
    launchedAt = start
    idleSince = start
  }

  /// The usage-metrics switch changed, either way (#3269): the stretch starts over, so a brief
  /// off-then-on between two ticks cannot count its off time.
  func usageMetricsChanged() {
    idleSince = now()
  }

  /// One check. Sends at most once per process.
  func tick() {
    guard !hasSent else { return }
    let current = now()
    let epoch = workEpoch()
    if epoch != lastWorkEpoch {
      // A claim since the last tick, possibly already over: a busy tick.
      lastWorkEpoch = epoch
      sawWork = true
    }
    if isWorkInFlight() {
      sawWork = true
      idleSince = current
      return
    }
    if sawWork {
      // The work ended since the busy tick, at a moment the tick cannot see: start from now.
      sawWork = false
      idleSince = current
      return
    }
    guard usageMetricsOn() else {
      idleSince = current
      return
    }
    guard current - idleSince >= Self.idleThreshold else { return }
    // A failed read sends nothing; the next tick tries again.
    guard let footprintMB = readFootprintMB() else { return }
    let wordCheck = wordCheckState()
    let minutes = Int((current - launchedAt).components.seconds / 60)
    hasSent = true
    loop?.cancel()
    emit(
      Sample(
        footprintMB: footprintMB, minutesSinceLaunch: minutes, wordCheckLoaded: wordCheck.loaded,
        wordCheckWanted: wordCheck.wanted))
  }

  /// Starts the once-a-minute check. The task holds the observer until the sample is sent, then
  /// ends; nothing else needs to keep it.
  func start() {
    guard loop == nil, !hasSent else { return }
    loop = Task { [self] in
      while !Task.isCancelled && !hasSent {
        try? await Task.sleep(for: Self.tickInterval)
        tick()
      }
      loop = nil
    }
  }

  /// This process's physical footprint in MiB: `task_vm_info.phys_footprint`, the figure Activity
  /// Monitor's Memory column and `footprint` report. EG-1 and S1-mini run in a child process
  /// (`llama-server`), which this does not include. Nil when the read fails.
  nonisolated static func currentFootprintMB() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int(info.phys_footprint / (1 << 20))
  }
}
