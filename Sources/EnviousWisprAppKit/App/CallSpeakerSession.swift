import ApplicationServices
import Darwin
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// One recording's speaker evidence, whatever started the recording (#4013 13B): a manual
/// Start, the call prompt's Yes, or Start by itself all get exactly one session.
///
/// Responsibilities, and nothing else:
/// - Asks call-source discovery, every half second, which single call is live now
///   (`CallSpeakerSources.speakerSource()`), and keeps discovery watching while it records.
/// - Reads one call at a time: one `CallSpeakerObserver` per segment. A different call, or none,
///   that lasts `settle` closes the segment (its copies in flight no longer count); a new single
///   call opens the next one. Two competing calls, or an unreadable answer, read nothing.
/// - Freezes the talker rules and the presence rule once, at recording start, for every
///   segment; each segment resolves its own surface's lag from them.
/// - Owns saving, through one queue of saves: every 10 seconds, and when a segment ends, it
///   writes all segments so far through `save`, in the order asked, even while no call is read.
///   Once admission closes no new save starts; the final save after Stop is the last.
/// - Keeps the recording within its caps (#4013 13B.5): at most `CallSpeakerLog.maximumSegments`
///   segments, and all segments' evidence within `limits` together. When a cap is reached the
///   open segment ends (`capacityReached`), nothing more is read, and session health names the
///   cap; what was kept stays.
///
/// It never starts or stops audio, and nothing here is on the dictation path: discovery's reads
/// and the copies run off the main actor; a tick only compares cached answers.
@MainActor
final class CallSpeakerSession {
  struct Dependencies {
    var sources: any CallSpeakerSources
    /// One bounded copy of a call app instance for a family, run off the main actor.
    var capture: @Sendable (CallSpeakerTarget, CallAppFamily) -> CallAXCapture
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var isDictationIdle: @MainActor () -> Bool
    /// Writes the whole log; throws when it could not (recording goes on).
    var save: @MainActor (CallSpeakerLog) async throws -> Void
    var log: @MainActor (String) -> Void = { _ in }
    var lane: CallSpeakerObserver.Lane = .shared
    /// The recording clock's host time now.
    var hostTime: @Sendable () -> UInt64 = { mach_absolute_time() }
    var tick: Duration = .milliseconds(500)
    /// How long a change of call must last before the segment changes.
    var settle: Duration = .seconds(2)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The observer's own timing (tests shorten it).
    var observerTick: Duration = .milliseconds(500)
    /// Checks between periodic saves: 10 seconds.
    var saveEvery = 20
    var limits = CallEvidenceLimits.current
  }

  /// `finishing`: Stop is saving the final log. `saved`: the final log is on disk, or was handed
  /// to a quit. `cancelled`: nothing more is saved.
  private enum Lifecycle { case open, finishing, saved, cancelled }

  private let deps: Dependencies
  private let anchor: UInt64
  private let rules: TalkerRulesSnapshot
  private let bundled: TalkerRules
  private let presencePolicy = CallPresencePolicy.current
  private var lifecycle = Lifecycle.open
  private var loop: Task<Void, Never>?
  private var demanding = false
  private var closed: [CallSpeakerSegment] = []
  /// What the closed segments use of `limits`.
  private var closedUsage = CallEvidenceUsage()
  private var current: (source: CallSpeakerSourceAnswer.Source, observer: CallSpeakerObserver)?
  /// A different answer and when it was first seen.
  private var pending: (answer: CallSpeakerSourceAnswer, sinceMs: Int)?
  private var health = CallSessionHealth()
  /// Where the recording stopped, fixed when admission closed.
  private var stoppedAtMs: Int?
  /// The save running now, and whether another was asked for meanwhile.
  private var saving: Task<Void, Never>?
  private var saveQueued = false

  init(
    anchor: UInt64, rules: TalkerRulesSnapshot, bundled: TalkerRules, dependencies: Dependencies
  ) {
    self.deps = dependencies
    self.anchor = anchor
    self.rules = rules
    self.bundled = bundled
  }

  /// Everything collected so far: every closed segment, then the open one.
  var currentLog: CallSpeakerLog {
    CallSpeakerLog(
      rules: rules.frozen, presencePolicy: presencePolicy,
      segments: closed + (current.map { [$0.observer.currentSegment] } ?? []),
      sessionHealth: health)
  }

  private var nowMs: Int {
    CallSpeakerTimeline.observationMs(
      readStart: deps.hostTime(), readEnd: deps.hostTime(), anchor: anchor) ?? 0
  }

  func start() {
    guard lifecycle == .open, loop == nil else { return }
    demanding = true
    deps.sources.beginRecordingDemand()
    check()
    loop = Task { [weak self] in
      var checks = 0
      while !Task.isCancelled {
        guard let self else { return }
        do { try await self.deps.sleep(self.deps.tick) } catch { return }
        guard self.acceptsSaves else { return }
        checks += 1
        self.check()
        if checks % self.deps.saveEvery == 0 { self.requestSave() }
      }
    }
  }

  /// One look at the live call. Cheap: discovery answers from its last reading.
  func check() {
    guard lifecycle == .open, stoppedAtMs == nil else { return }
    let answer = deps.sources.speakerSource()
    switch answer {
    case .unique: health.uniqueSources += 1
    case .none: health.noSource += 1
    case .ambiguous: health.ambiguousSources += 1
    case .unavailable: health.unavailableSources += 1
    }
    guard health.capacityReason == nil else { return }
    let now = nowMs
    if let full = current?.observer.capacityReached {
      closeCurrent(at: now, reason: .capacityReached)
      reachedCapacity(full)
      return
    }
    if case .unique(let source) = answer, current?.source == source {
      pending = nil
      return
    }
    // Any other answer interrupts the segment's reading at once, even one that settles back:
    // copies in flight no longer count and runs of missing names start again.
    current?.observer.noteSourceInterruption()
    guard current != nil else {
      // Nothing is being read: a single call is read at once.
      pending = nil
      if case .unique(let source) = answer { open(source, at: now) }
      return
    }
    if let waiting = pending, waiting.answer == answer {
      guard now - waiting.sinceMs >= Int(deps.settle / .milliseconds(1)) else { return }
      pending = nil
      if case .unique(let source) = answer {
        closeCurrent(at: now, reason: .sourceChanged)
        open(source, at: now)
      } else {
        closeCurrent(at: now, reason: .sourceLost)
      }
      requestSave()
    } else {
      pending = (answer, now)
    }
  }

  private func open(_ source: CallSpeakerSourceAnswer.Source, at startMs: Int) {
    guard closed.count < CallSpeakerLog.maximumSegments else {
      reachedCapacity(.segments)
      return
    }
    guard
      let surface = CallSpeakerSurfaceChoice.surface(
        family: source.family, rule: source.target.rule)
    else { return }
    let lag = TalkerRules.recordingStartLag(
      for: surface, selected: rules.rules, bundled: bundled)
    let sources = deps.sources
    let capture = deps.capture
    let family = source.family
    let observer = CallSpeakerObserver(
      surface: surface, family: family, anchor: anchor, startMs: startMs, rules: rules,
      presencePolicy: presencePolicy, lag: lag, limits: deps.limits, baseline: closedUsage,
      dependencies: .init(
        // This segment's app instance only while it is still the single live call.
        target: { sources.speakerSource() == .unique(source) ? source.target : nil },
        sourceRevision: { sources.speakerSourceRevision },
        capture: { capture($0, family) }, isTrusted: deps.isTrusted,
        isDictationIdle: deps.isDictationIdle, lane: deps.lane, tick: deps.observerTick,
        sleep: deps.sleep))
    current = (source, observer)
    deps.log("meeting speaker segment started surface=\(surface.rawValue)")
    observer.start()
  }

  private func closeCurrent(at endMs: Int, reason: CallSpeakerSegmentEnd) {
    guard let current else { return }
    current.observer.closeAdmission()
    let segment = current.observer.segment(
      endingAt: max(endMs, current.observer.currentSegment.startMs), reason: reason)
    closed.append(segment)
    closedUsage.add(segment)
    self.current = nil
  }

  /// Collection stops for good; what was kept is saved.
  private func reachedCapacity(_ cap: CallEvidenceCapacity) {
    pending = nil
    health.capacityReason = cap.rawValue
    deps.log("meeting speaker evidence full cap=\(cap.rawValue)")
    requestSave()
  }

  /// Saves still start: the session is open and admission has not closed.
  private var acceptsSaves: Bool { lifecycle == .open && stoppedAtMs == nil }

  /// Asks for a save of everything so far; one runs at a time, and one asked for meanwhile runs
  /// next. A save that has not started when admission closes never starts.
  private func requestSave() {
    guard acceptsSaves else { return }
    guard saving == nil else {
      saveQueued = true
      return
    }
    saving = Task { [weak self] in await self?.runSaves() }
  }

  private func runSaves() async {
    defer { saving = nil }
    repeat {
      guard acceptsSaves else { return }
      saveQueued = false
      do { try await save() } catch {
        deps.log("call speakers save failed error=\(type(of: error))")
      }
    } while saveQueued
  }

  /// Saves everything so far. The log is put together when the write is queued, so writes
  /// land in the order asked and a later one never carries less.
  private func save() async throws {
    health.saveAttempts += 1
    do {
      try await deps.save(currentLog)
    } catch {
      health.saveFailures += 1
      throw error
    }
  }

  /// Closes admission at once: no more checks or copies, results in flight no longer count,
  /// and the stop time is fixed. Synchronous, so a Stop calls it before its first wait.
  func closeAdmission() {
    if stoppedAtMs == nil { stoppedAtMs = nowMs }
    loop?.cancel()
    loop = nil
    current?.observer.closeAdmission()
  }

  /// Normal stop: closes admission, lets the save already running land, ends the open segment
  /// at the stop time and saves the final log once. True when it is on disk (or was handed to
  /// a quit meanwhile); false when the save failed or the session was cancelled.
  @discardableResult
  func finish() async -> Bool {
    closeAdmission()
    guard lifecycle == .open else { return lifecycle == .saved }
    lifecycle = .finishing
    await saving?.value
    guard lifecycle == .finishing else { return lifecycle == .saved }
    closeCurrent(at: stoppedAtMs ?? nowMs, reason: .recordingEnded)
    endDemand()
    do {
      try await save()
      if lifecycle == .finishing { lifecycle = .saved }
    } catch {
      deps.log("call speakers final save failed error=\(type(of: error))")
    }
    return lifecycle == .saved
  }

  /// Quit: closes admission and hands back the final log for the caller to save within its own
  /// deadline; nil when it is already on disk or the session was cancelled.
  func takeFinalLog() -> CallSpeakerLog? {
    closeAdmission()
    guard lifecycle == .open || lifecycle == .finishing else { return nil }
    closeCurrent(at: stoppedAtMs ?? nowMs, reason: .recordingEnded)
    lifecycle = .saved
    endDemand()
    return currentLog
  }

  /// Delete or a failed start: closes admission and saves nothing more.
  func cancel() {
    closeAdmission()
    lifecycle = .cancelled
    endDemand()
  }

  private func endDemand() {
    guard demanding else { return }
    demanding = false
    deps.sources.endRecordingDemand()
  }

  #if DEBUG
    var currentObserverForTesting: CallSpeakerObserver? { current?.observer }
    /// The periodic save, now.
    func saveNowForTesting() { requestSave() }
    /// Waits for the save running now, if any.
    func savesSettledForTesting() async { await saving?.value }
  #endif
}
