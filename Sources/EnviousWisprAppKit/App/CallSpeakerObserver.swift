import ApplicationServices
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Observation
import os

/// Collects one segment of a recording's speaker evidence: one call app instance, one surface
/// (#4013 chunk 13A, 13B). `CallSpeakerSession` decides which call to read and when a segment
/// starts and ends, and owns saving; this only collects.
///
/// Every 500 ms it takes one bounded Accessibility copy of the app on the shared capture lane;
/// a tick that finds the lane busy (this segment's copy, or an older recording's copy still
/// blocked) is skipped, with no catch-up. The surface's reader parses the copy on the lane too,
/// so the main actor only adds the finished reading. A copy counts only when nothing changed
/// while it was taken: dictation did not start or end, Accessibility trust held and this
/// segment's app instance is still the one to read. Each reading goes through
/// `CallSpeakerAccumulator` (admission, roster, presence, health), placed on the meeting
/// timeline from the recorder's anchor. Every 10 seconds it asks the session to save; after
/// `closeAdmission()` nothing is added and no save starts.
@MainActor
final class CallSpeakerObserver {
  /// Where copies run, and whether one is still running. One for the whole app, so a copy
  /// still blocked from a recording that ended keeps a new recording from starting another.
  /// A test makes its own.
  final class Lane: Sendable {
    let queue = DispatchQueue(label: "com.enviouswispr.call-speaker-capture", qos: .utility)
    let busy = OSAllocatedUnfairLock(initialState: false)
    static let shared = Lane()

    var isBusy: Bool { busy.withLock { $0 } }
  }

  struct Dependencies {
    /// This segment's app instance while it is still the one to read; `nil` otherwise.
    var target: @MainActor () -> CallSpeakerTarget?
    /// Goes up whenever the apps holding the microphone (or what their pages are) change, so a
    /// source that went away and came back between two checks still drops a copy in flight.
    var sourceRevision: @MainActor () -> Int = { 0 }
    /// One bounded copy of that app, run on the lane's queue.
    var capture: @Sendable (CallSpeakerTarget) -> CallAXCapture
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    /// Read inside Observation tracking, so any change to what it reads invalidates copies in
    /// flight at once, even a whole dictation that starts and ends between two ticks.
    var isDictationIdle: @MainActor () -> Bool
    /// Asks the session to save everything collected so far; throws when it could not.
    var save: @MainActor () async throws -> Void
    var log: @MainActor (String) -> Void = { _ in }
    var lane: Lane = .shared
    var tick: Duration = .milliseconds(500)
    var saveEvery: Int = 20  // ticks: 10 seconds
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  }

  private let deps: Dependencies
  private let family: CallAppFamily
  private let anchor: UInt64
  private let rules: TalkerRules
  private var accumulator: CallSpeakerAccumulator
  private var loop: Task<Void, Never>?
  /// Bumped whenever copies in flight must no longer count: closing, dictation running, trust
  /// lost, a different app instance.
  private var generation = 0
  /// Bumped synchronously by the Observation change handler, which may run off the main actor.
  private let dictationChanges = OSAllocatedUnfairLock(initialState: 0)
  private(set) var open = true
  private var lastTarget: CallSpeakerTarget?
  /// `dictationChanges` as the last tick saw it.
  private var seenDictationChanges = 0
  private var savedVersion = -1
  private var version = 0
  private var saving: Task<Void, Never>?

  /// `rules` and `lag` are the recording's frozen ones; `anchor` is the recorder's; `startMs` is
  /// where this segment starts on the recording clock.
  init(
    surface: CallSpeakerSurface, family: CallAppFamily, anchor: UInt64, startMs: Int,
    rules: TalkerRulesSnapshot, presencePolicy: CallPresencePolicy, lag: CallSpeakerLag?,
    dependencies: Dependencies
  ) {
    self.deps = dependencies
    self.family = family
    self.anchor = anchor
    self.rules = rules.rules
    self.accumulator = CallSpeakerAccumulator(
      surface: surface, rules: rules.frozen, lag: lag,
      status: CallSpeakerSurfaceChoice.hasTalkerReader(surface) ? nil : .unsupported,
      presencePolicy: presencePolicy, startMs: startMs)
    watchDictation()
  }

  /// This segment as collected so far, still open.
  var currentSegment: CallSpeakerSegment { accumulator.segment(endMs: nil, endReason: nil) }

  /// This segment, ended at `endMs` for `reason`.
  func segment(endingAt endMs: Int, reason: CallSpeakerSegmentEnd) -> CallSpeakerSegment {
    accumulator.segment(endMs: endMs, endReason: reason)
  }

  /// Whether anything was added since the last save that landed.
  var hasUnsavedChanges: Bool { version != savedVersion }

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

  /// Any change to what `isDictationIdle` reads bumps `dictationChanges` before it lands; then
  /// tracking is armed again.
  private func watchDictation() {
    guard open else { return }
    let changes = dictationChanges
    withObservationTracking {
      _ = deps.isDictationIdle()
    } onChange: { [weak self] in
      changes.withLock { $0 += 1 }
      Task { @MainActor [weak self] in self?.watchDictation() }
    }
  }

  /// One tick. Eligibility is checked every tick, even while a copy is in flight, so a change
  /// drops that copy; a copy starts only when eligible and the lane is free.
  func tick() {
    guard open, CallSpeakerSurfaceChoice.hasTalkerReader(accumulator.surface) else { return }
    // A whole dictation between two ticks still interrupts presence.
    let changes = dictationChanges.withLock { $0 }
    if changes != seenDictationChanges {
      seenDictationChanges = changes
      accumulator.noteInterruption()
      version += 1
    }
    guard deps.isDictationIdle() else {
      generation += 1
      accumulator.noteDictationSkip()
      version += 1
      return
    }
    guard deps.isTrusted() else {
      generation += 1
      accumulator.noteNoPermission()
      version += 1
      return
    }
    let target = deps.target()
    if target != lastTarget {
      generation += 1
      lastTarget = target
    }
    guard let target else { return }
    let busy = deps.lane.busy
    let claimed = busy.withLock { running -> Bool in
      if running { return false }
      running = true
      return true
    }
    guard claimed else {
      accumulator.noteBusySkip()
      version += 1
      return
    }
    let taken = Taken(
      target: target, generation: generation, dictation: dictationChanges.withLock { $0 },
      source: deps.sourceRevision())
    let capture = deps.capture
    let isTrusted = deps.isTrusted
    let surface = accumulator.surface
    let rules = rules
    let family = family
    deps.lane.queue.async { [weak self] in
      let copy = capture(target)
      // Trust is read again the moment the reads end, not only at the next tick.
      let trustedAfter = isTrusted()
      // Parsing happens here too, off the main actor.
      let parsed = Parsed(
        copy: copy,
        reading: CallSpeakerSurfaceReader.read(surface: surface, capture: copy, rules: rules),
        context: CallCaptureContext(
          completeness: copy.completeness,
          scope: CallSpeakerSurfaceReader.scope(surface: surface, capture: copy, family: family)))
      // The lane frees only once the physical work returned.
      busy.withLock { $0 = false }
      Task { @MainActor [weak self] in
        self?.captured(parsed, taken: taken, trustedAfter: trustedAfter)
      }
    }
  }

  /// What a copy was started under.
  private struct Taken: Sendable {
    let target: CallSpeakerTarget
    let generation: Int
    let dictation: Int
    let source: Int
  }

  /// A copy and what its reader made of it.
  private struct Parsed: Sendable {
    let copy: CallAXCapture
    let reading: CallSpeakerReading?
    let context: CallCaptureContext
  }

  private func captured(_ parsed: Parsed, taken: Taken, trustedAfter: Bool) {
    #if DEBUG
      deliveriesForTesting += 1
    #endif
    guard open else { return }
    let copy = parsed.copy
    accumulator.noteWalk(
      durationUs: CallSpeakerTimeline.microseconds(
        from: copy.readStartHostTime, to: copy.readEndHostTime),
      nodes: copy.nodesVisited)
    // Every change to what is saved, health included, is saved at the next interval.
    version += 1
    // Read again at delivery: nothing that would have stopped the copy may have happened since.
    guard trustedAfter, taken.generation == generation,
      taken.dictation == dictationChanges.withLock({ $0 }), taken.source == deps.sourceRevision(),
      deps.isDictationIdle(), deps.isTrusted(), deps.target() == taken.target
    else {
      accumulator.noteStaleDrop()
      return
    }
    guard
      let ms = CallSpeakerTimeline.observationMs(
        readStart: copy.readStartHostTime, readEnd: copy.readEndHostTime, anchor: anchor),
      ms >= accumulator.startMs
    else { return }
    accumulator.add(parsed.reading, context: parsed.context, observationMs: ms)
    version += 1
  }

  /// Starts a save when something changed since the last one; never two at once. A save that
  /// has not reached the writer when admission closes does not run.
  private func saveIfChanged() {
    guard open, saving == nil, version != savedVersion else { return }
    let saved = version
    saving = Task { [weak self] in
      guard let self else { return }
      defer { self.saving = nil }
      guard self.open else { return }
      do {
        try await self.deps.save()
        self.savedVersion = saved
      } catch {
        self.deps.log("call speakers save failed error=\(type(of: error))")
      }
    }
  }

  /// Closes admission at once: no more copies, results in flight no longer count, no periodic
  /// save starts. Synchronous, so a Stop calls it before its first wait.
  func closeAdmission() {
    open = false
    generation += 1
    loop?.cancel()
    loop = nil
  }

  /// Closes admission and waits for a save already running, so the session's final save is
  /// the last one.
  func drain() async {
    closeAdmission()
    await saving?.value
  }

  #if DEBUG
    /// Copies delivered to the main actor, counted or dropped.
    private(set) var deliveriesForTesting = 0
    func savingForTesting() async { await saving?.value }
    var laneBusy: Bool { deps.lane.isBusy }
    /// The periodic save, now.
    func saveNowForTesting() { saveIfChanged() }
  #endif
}
