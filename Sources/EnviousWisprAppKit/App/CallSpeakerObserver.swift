import ApplicationServices
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Collects one recording's speaker evidence from its call app while it records (#4013 chunk
/// 13A). Bound to the call-app family the recording was started for, one surface per
/// recording, as Granola binds its speaker monitors.
///
/// Every 500 ms it takes one bounded Accessibility copy of the app on its own serial queue; a
/// tick that finds a copy still being taken is skipped (no catch-up). While dictation is not
/// idle it takes none and drops any copy in flight. Each copy is read by the surface's reader
/// and goes through `CallSpeakerAccumulator` (admission, roster rule), placed on the meeting
/// timeline from the recorder's anchor. The log is saved every 10 seconds and once more at
/// `finish()`; after `finish()` or `cancel()` nothing is added or saved.
@MainActor
final class CallSpeakerObserver {
  struct Dependencies {
    /// The app instance to read now; `nil` when there is none, or more than one.
    var target: @MainActor () -> CallSpeakerTarget?
    /// One bounded copy of that app, run on the observer's queue.
    var capture: @Sendable (CallSpeakerTarget) -> CallAXCapture
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var isDictationIdle: @MainActor () -> Bool
    /// Saves the log; throws when it could not (recording goes on).
    var save: @MainActor (CallSpeakerLog) async throws -> Void
    var log: @MainActor (String) -> Void = { _ in }
    var tick: Duration = .milliseconds(500)
    var saveEvery: Int = 20  // ticks: 10 seconds
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  }

  private let deps: Dependencies
  private let family: CallAppFamily
  private let anchor: UInt64
  private let rules: TalkerRules
  private var accumulator: CallSpeakerAccumulator
  private let queue = DispatchQueue(label: "com.enviouswispr.call-speaker-capture", qos: .utility)
  private var loop: Task<Void, Never>?
  /// A copy is being taken on the queue (kept until the queue work itself returns).
  private var captureInFlight = false
  /// Bumped whenever results in flight must no longer count.
  private var generation = 0
  private var open = true
  private var finished = false
  private var savedVersion = -1
  private var version = 0
  private var saving: Task<Void, Never>?

  /// `rules` and `lag` are frozen by the caller at recording start; `anchor` is the recorder's.
  init(
    surface: CallSpeakerSurface, family: CallAppFamily, anchor: UInt64, rules: TalkerRulesSnapshot,
    lag: CallSpeakerLag?, dependencies: Dependencies
  ) {
    self.deps = dependencies
    self.family = family
    self.anchor = anchor
    self.rules = rules.rules
    self.accumulator = CallSpeakerAccumulator(
      surface: surface, rules: rules.frozen, lag: lag,
      status: CallSpeakerSurfaceChoice.hasTalkerReader(surface) ? nil : .unsupported)
  }

  /// The log as collected so far.
  var currentLog: CallSpeakerLog { accumulator.log }

  func start() {
    guard open, loop == nil else { return }
    loop = Task { [weak self] in
      var ticks = 0
      while !Task.isCancelled {
        guard let self else { return }
        do { try await self.deps.sleep(self.deps.tick) } catch { return }
        guard self.open else { return }
        ticks += 1
        self.tick()
        if ticks % self.deps.saveEvery == 0 { self.saveIfChanged() }
      }
    }
  }

  /// One tick: skipped while a copy is in flight; while dictation runs, copies in flight are
  /// dropped and none is taken.
  func tick() {
    guard open else { return }
    guard deps.isDictationIdle() else {
      generation += 1
      return
    }
    guard !captureInFlight, CallSpeakerSurfaceChoice.hasTalkerReader(accumulator.surface)
    else { return }
    guard deps.isTrusted() else {
      accumulator.noteNoPermission()
      version += 1
      return
    }
    guard let target = deps.target() else { return }
    captureInFlight = true
    let current = generation
    let capture = deps.capture
    queue.async { [weak self] in
      let copy = capture(target)
      Task { @MainActor [weak self] in self?.captured(copy, generation: current) }
    }
  }

  private func captured(_ copy: CallAXCapture, generation taken: Int) {
    captureInFlight = false
    guard open, taken == generation, deps.isDictationIdle() else { return }
    guard
      let ms = CallSpeakerTimeline.observationMs(
        readStart: copy.readStartHostTime, readEnd: copy.readEndHostTime, anchor: anchor)
    else { return }
    let surface = accumulator.surface
    let reading = CallSpeakerSurfaceReader.read(surface: surface, capture: copy, rules: rules)
    let context = CallCaptureContext(
      completeness: copy.completeness,
      scope: CallSpeakerSurfaceReader.scope(surface: surface, capture: copy, family: family))
    accumulator.add(reading, context: context, observationMs: ms)
    version += 1
  }

  /// Starts a save when the log changed since the last one; never two at once.
  private func saveIfChanged() {
    guard open, saving == nil, version != savedVersion else { return }
    let log = accumulator.log
    let saved = version
    saving = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.deps.save(log)
        self.savedVersion = saved
      } catch {
        self.deps.log("call speakers save failed error=\(type(of: error))")
      }
      self.saving = nil
    }
  }

  /// Closes admission at once: no more copies, results in flight no longer count, no periodic
  /// save starts. Synchronous, so a Stop calls it before its first wait.
  func close() {
    open = false
    generation += 1
    loop?.cancel()
    loop = nil
  }

  /// Normal stop: closes admission, waits for a save already running, then saves the final log
  /// once. Returns after the final save, so processing reads it.
  func finish() async {
    close()
    guard !finished else { return }
    finished = true
    await saving?.value
    do {
      try await deps.save(accumulator.log)
    } catch {
      deps.log("call speakers final save failed error=\(type(of: error))")
    }
  }

  /// Delete, quit or a failed start: closes admission and saves nothing more. A save already
  /// running finishes on its own; the caller's deletion runs after the file writer drains.
  func cancel() {
    close()
    finished = true
  }

  #if DEBUG
    var isCaptureInFlightForTesting: Bool { captureInFlight }
    func savingForTesting() async { await saving?.value }
  #endif
}
