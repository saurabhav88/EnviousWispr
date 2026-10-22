import Dispatch
import Foundation
import Observation

/// The two production waits an EnviousMeet pass unit admits on (#3972 R25, plan §6): dictation
/// idle, and memory pressure back to normal. Both are event-driven and return when their task
/// is cancelled, as `MeetingTranscriptionJob.Dependencies` requires.
@MainActor
enum MeetingWorkAdmission {
  /// Returns once `condition()` is true, or when the calling task is cancelled.
  ///
  /// Re-checked on every change Swift Observation reports for the observable state the
  /// condition reads, and on every `poke` of `wakes` (for inputs that are not observable, whose
  /// owner pokes when they change). No timer: an input that is neither observed nor poked is a
  /// wiring defect, and `MeetingWiringTests` drives each production input.
  static func waitUntil(
    _ condition: @escaping @MainActor () -> Bool, wakes: MeetingWakeSignal? = nil
  ) async {
    while !condition(), !Task.isCancelled {
      let waiter = OneShot()
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          waiter.arm(continuation)
          // Armed before reading, so a change between the read and the registration is seen.
          withObservationTracking {
            _ = condition()
          } onChange: {
            Task { @MainActor in waiter.fire() }
          }
          let token = wakes?.register { waiter.fire() }
          waiter.onFire = { if let token { wakes?.unregister(token) } }
          if Task.isCancelled || condition() { waiter.fire() }
        }
      } onCancel: {
        Task { @MainActor in waiter.fire() }
      }
    }
  }

  /// Resumes its continuation exactly once, whichever of observation, poke or cancellation
  /// arrives first; the others find nothing to resume.
  @MainActor
  final class OneShot {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    var onFire: (() -> Void)?

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
      if fired {
        continuation.resume()
      } else {
        self.continuation = continuation
      }
    }

    func fire() {
      guard !fired else { return }
      fired = true
      onFire?()
      onFire = nil
      continuation?.resume()
      continuation = nil
    }
  }
}

/// A poke for an admission input that Observation cannot see (for example a flag its owner
/// keeps `@ObservationIgnored`). The owner calls `poke()` whenever the input may have changed.
@MainActor
final class MeetingWakeSignal {
  private var handlers: [UUID: @MainActor () -> Void] = [:]

  func register(_ handler: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    handlers[id] = handler
    return id
  }

  func unregister(_ id: UUID) { handlers.removeValue(forKey: id) }

  func poke() {
    let current = handlers
    for handler in current.values { handler() }
  }

  #if DEBUG
    var registrationCountForTesting: Int { handlers.count }
  #endif
}

/// macOS memory pressure for EnviousMeet (plan §6): elevated at warning or critical, normal
/// again when the system says so. Owns its dispatch source from `start()` to `stop()`.
@MainActor
@Observable
final class MeetingMemoryPressure {
  enum Level: Equatable {
    case normal
    case warning
    case critical
  }

  private(set) var level: Level = .normal
  @ObservationIgnored private var source: DispatchSourceMemoryPressure?

  init() {}

  var isElevated: Bool { level != .normal }

  /// Starts listening to the system's memory pressure events. Repeatable.
  func start() {
    guard source == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      let event = source.data
      MainActor.assumeIsolated { self?.receive(event) }
    }
    source.activate()
    self.source = source
  }

  func stop() {
    source?.cancel()
    source = nil
  }

  /// One system event. Internal so tests drive transitions without a real low-memory Mac.
  func receive(_ event: DispatchSource.MemoryPressureEvent) {
    if event.contains(.critical) {
      level = .critical
    } else if event.contains(.warning) {
      level = .warning
    } else if event.contains(.normal) {
      level = .normal
    }
  }

  /// Returns once pressure is normal, or when the calling task is cancelled.
  func waitUntilNormal() async {
    await MeetingWorkAdmission.waitUntil { [weak self] in !(self?.isElevated ?? false) }
  }
}
