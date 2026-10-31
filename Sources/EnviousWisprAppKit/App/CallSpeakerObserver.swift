import ApplicationServices
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Observation
import os

/// The call a copy is taken for, fixed when the copy starts (#4248 plan §18): the app instance
/// and its family, the surface its readers use, the session's binding generation, and whether
/// the mute button is followed for it. A copy whose binding is no longer the live one when it
/// lands counts for nothing.
struct CallCaptureBinding: Equatable, Sendable {
  let source: CallSpeakerSourceAnswer.Source
  let surface: CallSpeakerSurface
  let generation: UInt64
  let mute: Bool
}

/// One mute reading from a copy that was still valid when it landed (#4248).
struct CallMuteCopy: Equatable, Sendable {
  let reading: CallSelfMute
  let surface: CallSpeakerSurface
  /// T and E: the copy's read start and end host times.
  let copyStart: UInt64
  let copyEnd: UInt64
  /// M: when the main actor received it (trace only; never stands in for delivery).
  let received: UInt64
  let completeness: CallCaptureContext.Completeness
  let nodes: Int
  let generation: UInt64
}

/// What became of one chance to read the mute button (#4248 timing receipt): counted for
/// every tick whose live binding follows the mute button, whatever naming does.
enum CallMuteCaptureEvent: Sendable, Equatable {
  /// A copy started.
  case started
  case dictationSkip
  case noPermission
  /// The lane was still busy with an earlier copy.
  case busySkip
  /// The copy landed after something changed and gave no reading.
  case staleDrop
}

/// Takes one recording's call copies on the shared lane and hands out what they show
/// (#4013 chunk 13A, 13B; #4248). With naming, it collects one segment of speaker evidence:
/// one call app instance, one surface. `CallSpeakerSession` decides which call to read and when
/// a segment starts and ends, and owns saving; this only collects. Without naming (no talker
/// rules, or the evidence caps were reached) it only reads the mute button.
///
/// Each copy is taken for the session's live `CallCaptureBinding`, which follows a new single
/// call at once; naming counts the copy only while that call is the segment's own, and mute
/// only while the binding follows the mute button. So a change of call stops naming at once
/// (its settle is the session's) and moves mute reading to the new call at once.
///
/// Every 500 ms it takes one bounded Accessibility copy of the app on the shared capture lane;
/// a tick that finds the lane busy (this segment's copy, or an older recording's copy still
/// blocked) is skipped, with no catch-up. The surface's reader parses the copy on the lane too,
/// so the main actor only adds the finished reading. A copy counts only when nothing changed
/// while it was taken: dictation did not start or end, Accessibility trust held and this
/// segment's app instance is still the one to read. Each reading goes through
/// `CallSpeakerAccumulator` (admission, roster, presence, health), placed on the meeting
/// timeline from the recorder's anchor. After `closeAdmission()` nothing is added.
/// The session saves what it collected.
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
    /// The live call to copy, read at every tick and again when a copy lands; `nil` when there
    /// is none.
    var binding: @MainActor () -> CallCaptureBinding?
    /// Goes up whenever the apps holding the microphone (or what their pages are) change, so a
    /// source that went away and came back between two checks still drops a copy in flight.
    var sourceRevision: @MainActor () -> Int = { 0 }
    /// One bounded copy of that app, run on the lane's queue.
    var capture: @Sendable (CallSpeakerTarget, CallAppFamily) -> CallAXCapture
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    /// Read inside Observation tracking, so any change to what it reads invalidates copies in
    /// flight at once, even a whole dictation that starts and ends between two ticks.
    var isDictationIdle: @MainActor () -> Bool
    var lane: Lane = .shared
    var tick: Duration = .milliseconds(500)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Receives each valid mute reading (#4248).
    var mute: @MainActor (CallMuteCopy) -> Void = { _ in }
    var muteEvent: @MainActor (CallMuteCaptureEvent) -> Void = { _ in }
    var hostTime: @Sendable () -> UInt64 = { mach_absolute_time() }
  }

  /// One segment's speaker evidence.
  private struct Naming {
    let source: CallSpeakerSourceAnswer.Source?
    let rules: TalkerRules
    var accumulator: CallSpeakerAccumulator
  }

  private let deps: Dependencies
  private let anchor: UInt64
  /// Nil when this observer only reads the mute button.
  private var naming: Naming?
  private var loop: Task<Void, Never>?
  /// Bumped whenever copies in flight must no longer count: closing, dictation running, trust
  /// lost, a different app instance.
  private var generation = 0
  /// Bumped when the session sees a different answer while naming's segment settles: only
  /// naming's copies in flight stop counting; mute's copies of the live binding still do.
  private var namingGeneration = 0
  /// Bumped synchronously by the Observation change handler, which may run off the main actor.
  private let dictationChanges = OSAllocatedUnfairLock(initialState: 0)
  private(set) var open = true
  private var lastBinding: CallCaptureBinding?
  /// `dictationChanges` as the last tick saw it.
  private var seenDictationChanges = 0

  /// A naming observer for `source`'s segment (nil `source`: whatever call the binding names,
  /// for tests). `rules` and `lag` are the recording's frozen ones; `anchor` is the recorder's;
  /// `startMs` is where this segment starts on the recording clock; `baseline` is what the
  /// recording's earlier segments use of `limits`.
  init(
    surface: CallSpeakerSurface, source: CallSpeakerSourceAnswer.Source? = nil, anchor: UInt64,
    startMs: Int, rules: TalkerRulesSnapshot, presencePolicy: CallPresencePolicy,
    lag: CallSpeakerLag?, limits: CallEvidenceLimits = .current,
    baseline: CallEvidenceUsage = CallEvidenceUsage(), dependencies: Dependencies
  ) {
    self.deps = dependencies
    self.anchor = anchor
    self.naming = Naming(
      source: source, rules: rules.rules,
      accumulator: CallSpeakerAccumulator(
        surface: surface, rules: rules.frozen, lag: lag,
        status: CallSpeakerSurfaceChoice.hasTalkerReader(surface) ? nil : .unsupported,
        presencePolicy: presencePolicy, startMs: startMs, limits: limits, baseline: baseline))
    watchDictation()
  }

  /// Turns a mute-only observer into `source`'s naming observer, keeping its copy loop: naming
  /// starts counting from the next copy.
  func attachNaming(
    surface: CallSpeakerSurface, source: CallSpeakerSourceAnswer.Source, startMs: Int,
    rules: TalkerRulesSnapshot, presencePolicy: CallPresencePolicy, lag: CallSpeakerLag?,
    limits: CallEvidenceLimits, baseline: CallEvidenceUsage
  ) {
    guard open, naming == nil else { return }
    namingGeneration += 1
    naming = Naming(
      source: source, rules: rules.rules,
      accumulator: CallSpeakerAccumulator(
        surface: surface, rules: rules.frozen, lag: lag,
        status: CallSpeakerSurfaceChoice.hasTalkerReader(surface) ? nil : .unsupported,
        presencePolicy: presencePolicy, startMs: startMs, limits: limits, baseline: baseline))
  }

  /// An observer that only reads the mute button.
  init(muteOnlyAnchor anchor: UInt64, dependencies: Dependencies) {
    self.deps = dependencies
    self.anchor = anchor
    self.naming = nil
    watchDictation()
  }

  /// The cap that stopped this segment's collection, if one did; then naming takes no copy.
  var capacityReached: CallEvidenceCapacity? { naming?.accumulator.capacityReached }

  /// This segment as collected so far, still open; nil for a mute-only observer.
  var currentSegment: CallSpeakerSegment? {
    naming?.accumulator.segment(endMs: nil, endReason: nil)
  }

  /// This segment, ended at `endMs` for `reason`; nil for a mute-only observer.
  func segment(endingAt endMs: Int, reason: CallSpeakerSegmentEnd) -> CallSpeakerSegment? {
    naming?.accumulator.segment(endMs: endMs, endReason: reason)
  }

  /// Whether naming still collects (a reader for its surface, under its caps).
  private var namingCollects: Bool {
    guard let naming else { return false }
    return naming.accumulator.capacityReached == nil
      && CallSpeakerSurfaceChoice.hasTalkerReader(naming.accumulator.surface)
  }

  /// Whether naming counts a copy taken for `binding`.
  private func namingCounts(_ binding: CallCaptureBinding) -> Bool {
    guard namingCollects, let naming else { return false }
    return naming.source.map { $0 == binding.source } ?? true
  }

  func start() {
    guard open, loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        do { try await self.deps.sleep(self.deps.tick) } catch { return }
        guard self.open else { return }
        self.tick()
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
  /// drops that copy; a copy starts only when naming or mute wants it and the lane is free.
  func tick() {
    guard open else { return }
    let collects = namingCollects
    let muteWanted = deps.binding()?.mute == true
    // A whole dictation between two ticks still interrupts presence.
    let changes = dictationChanges.withLock { $0 }
    if changes != seenDictationChanges {
      seenDictationChanges = changes
      if collects { naming?.accumulator.noteInterruption() }
    }
    guard deps.isDictationIdle() else {
      generation += 1
      if collects { naming?.accumulator.noteDictationSkip() }
      if muteWanted { deps.muteEvent(.dictationSkip) }
      return
    }
    guard deps.isTrusted() else {
      generation += 1
      if collects { naming?.accumulator.noteNoPermission() }
      if muteWanted { deps.muteEvent(.noPermission) }
      return
    }
    let binding = deps.binding()
    if binding != lastBinding {
      generation += 1
      lastBinding = binding
    }
    let forNaming = binding.map(namingCounts) ?? false
    // Another call, or none: naming's reading is interrupted (the session settles the segment).
    if collects, !forNaming { naming?.accumulator.noteInterruption() }
    guard let binding, forNaming || binding.mute else { return }
    let busy = deps.lane.busy
    let claimed = busy.withLock { running -> Bool in
      if running { return false }
      running = true
      return true
    }
    guard claimed else {
      if forNaming { naming?.accumulator.noteBusySkip() }
      if binding.mute { deps.muteEvent(.busySkip) }
      return
    }
    if binding.mute { deps.muteEvent(.started) }
    let taken = Taken(
      binding: binding, forNaming: forNaming, generation: generation,
      namingGeneration: namingGeneration,
      dictation: dictationChanges.withLock { $0 }, source: deps.sourceRevision())
    let capture = deps.capture
    let isTrusted = deps.isTrusted
    let rules = forNaming ? naming?.rules : nil
    deps.lane.queue.async { [weak self] in
      let copy = capture(binding.source.target, binding.source.family)
      // Trust is read again the moment the reads end, not only at the next tick.
      let trustedAfter = isTrusted()
      // Parsing happens here too, off the main actor.
      let parsed = Parsed(
        copy: copy,
        reading: rules.flatMap {
          CallSpeakerSurfaceReader.read(surface: binding.surface, capture: copy, rules: $0)
        },
        context: CallCaptureContext(
          completeness: copy.completeness,
          scope: CallSpeakerSurfaceReader.scope(
            surface: binding.surface, capture: copy, family: binding.source.family)),
        mute: binding.mute ? CallSelfMuteReader.read(surface: binding.surface, capture: copy) : nil)
      // The lane frees only once the physical work returned.
      busy.withLock { $0 = false }
      Task { @MainActor [weak self] in
        self?.captured(parsed, taken: taken, trustedAfter: trustedAfter)
      }
    }
  }

  /// What a copy was started under.
  private struct Taken: Sendable {
    let binding: CallCaptureBinding
    let forNaming: Bool
    let generation: Int
    let namingGeneration: Int
    let dictation: Int
    let source: Int
  }

  /// A copy and what its reader made of it.
  private struct Parsed: Sendable {
    let copy: CallAXCapture
    let reading: CallSpeakerReading?
    let context: CallCaptureContext
    /// Nil when the binding does not follow the mute button.
    let mute: CallSelfMute?
  }

  private func captured(_ parsed: Parsed, taken: Taken, trustedAfter: Bool) {
    #if DEBUG
      deliveriesForTesting += 1
    #endif
    guard open else { return }
    let received = deps.hostTime()
    let copy = parsed.copy
    if taken.forNaming {
      naming?.accumulator.noteWalk(
        durationUs: CallSpeakerTimeline.microseconds(
          from: copy.readStartHostTime, to: copy.readEndHostTime),
        nodes: copy.nodesVisited, failedReads: copy.failedReads,
        prunedControls: copy.prunedControls, skippedWindows: copy.skippedWindows)
    }
    // Read again at delivery: nothing that would have stopped the copy may have happened since,
    // and the copy's whole binding is still the live one.
    guard trustedAfter, taken.generation == generation,
      taken.dictation == dictationChanges.withLock({ $0 }), taken.source == deps.sourceRevision(),
      deps.isDictationIdle(), deps.isTrusted(), deps.binding() == taken.binding
    else {
      if taken.forNaming { naming?.accumulator.noteStaleDrop() }
      if taken.binding.mute { deps.muteEvent(.staleDrop) }
      return
    }
    if let mute = parsed.mute {
      deps.mute(
        CallMuteCopy(
          reading: mute, surface: taken.binding.surface, copyStart: copy.readStartHostTime,
          copyEnd: copy.readEndHostTime, received: received, completeness: copy.completeness,
          nodes: copy.nodesVisited, generation: taken.binding.generation))
    }
    guard taken.forNaming else { return }
    // A different answer while naming settles drops naming's copy, not mute's.
    guard taken.namingGeneration == namingGeneration else {
      naming?.accumulator.noteStaleDrop()
      return
    }
    guard namingCollects, let startMs = naming?.accumulator.startMs,
      let ms = CallSpeakerTimeline.observationMs(
        readStart: copy.readStartHostTime, readEnd: copy.readEndHostTime, anchor: anchor),
      ms >= startMs
    else { return }
    naming?.accumulator.add(parsed.reading, context: parsed.context, observationMs: ms)
  }

  /// The session saw a different answer about the live call, perhaps only for a moment: copies
  /// in flight no longer count and runs of missing names start again.
  func noteSourceInterruption() {
    guard open else { return }
    namingGeneration += 1
    naming?.accumulator.noteInterruption()
  }

  /// Closes admission at once: no more copies, and results in flight no longer count.
  /// Synchronous, so a Stop calls it before its first wait.
  func closeAdmission() {
    open = false
    generation += 1
    loop?.cancel()
    loop = nil
  }

  #if DEBUG
    /// Copies delivered to the main actor, counted or dropped.
    private(set) var deliveriesForTesting = 0
    var laneBusy: Bool { deps.lane.isBusy }
  #endif
}
