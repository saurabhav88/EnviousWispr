import AppKit
import ApplicationServices
import Darwin
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import os

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
/// - Binds the mute button (#4248 plan §18): every check, a single call on a surface whose mute
///   button is followed binds at once, with a new generation when the call changes; any other
///   answer unbinds at once. Naming's settle does not delay it. One observer takes every copy
///   on the shared lane, for the live binding; without a naming segment (no talker rules, the
///   caps reached, or between segments) a mute-only observer does.
///
/// It never starts or stops audio, and nothing here is on the dictation path: discovery's reads
/// and the copies run off the main actor; a tick only compares cached answers.
@MainActor
final class CallSpeakerSession {
  struct Dependencies {
    var sources: any CallSpeakerSources
    /// One bounded copy of a call app instance for a family, run off the main actor, keeping
    /// every read on the given roles strict (the mute rules' roles, #4013 reading resilience
    /// §3.1).
    var capture: @Sendable (CallSpeakerTarget, CallAppFamily, Set<String>) -> CallAXCapture
    /// The self-mute rules frozen at recording start (#4248; downloadable since #4013 reading
    /// resilience §3.5). Every copy is taken protecting their roles and read with them, so the
    /// capture and the mute reader always use the same rules; a download during the recording
    /// applies to the next one.
    var muteRules: CallMuteRules
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
    /// Mute following (#4248): whether it is on, binding changes (nil: unbound) and readings.
    var muteFollowing: @MainActor () -> Bool = { false }
    var muteBinding: @MainActor (CallCaptureBinding?) -> Void = { _ in }
    var muteReading: @MainActor (CallMuteCopy) -> Void = { _ in }
    var muteEvent: @MainActor (CallMuteCaptureEvent) -> Void = { _ in }
    /// Every check: time passed, so an expired mute reading closes even with no copy.
    var muteTick: @MainActor () -> Void = {}
    /// #4356: the Zoom self probe against one call app instance, run on the lane, keeping the
    /// recording's mute-rule roles strict; the closure says right before the press whether to
    /// stop. The default presses nothing.
    var selfProbe: @Sendable (CallSpeakerTarget, Set<String>, () -> Bool) -> ZoomSelfProbe.Result =
      { _, _, _ in .refused(.notFound, elapsedMs: 0) }
    /// #4356 plan §3.4: the frontmost app and app activations, for the focus hand-back.
    var focus: FocusAccess = .live
  }

  /// #4356 plan §3.4: what the focus hand-back reads and asks of macOS, by process id. Every
  /// call runs on the main actor (the app's run loop keeps NSWorkspace current).
  struct FocusAccess {
    /// The frontmost app's process id; nil when there is none.
    var frontmost: @MainActor () -> pid_t?
    /// Starts counting app activations; the handler gets each activated app's process id.
    var watch: @MainActor (@escaping @MainActor (pid_t) -> Void) -> NSObjectProtocol
    var stopWatching: @MainActor (NSObjectProtocol) -> Void
    /// A request (macOS 14+ may refuse it), never a guarantee.
    var activate: @MainActor (pid_t) -> Void
    /// Runs `body` on the next pass of the main run loop.
    var nextTurn: @MainActor (@escaping @MainActor () -> Void) -> Void

    static let live = FocusAccess(
      frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
      watch: { handler in
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
          // Read the payload before `assumeIsolated` (see `AccessibilityWarmupObserver`).
          let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .processIdentifier
          MainActor.assumeIsolated {
            if let pid { handler(pid) }
          }
        }
      },
      stopWatching: { NSWorkspace.shared.notificationCenter.removeObserver($0) },
      activate: { pid in _ = NSRunningApplication(processIdentifier: pid)?.activate() },
      nextTurn: { body in DispatchQueue.main.async { MainActor.assumeIsolated { body() } } })
  }

  /// #4356 plan §3.4: one ticket's hand-back: the app to ask back, and every app activation
  /// since the ticket was made, in order.
  private struct HandBack {
    let ticketID: Int
    let returnTo: pid_t?
    var activations: [pid_t] = []
    var watch: NSObjectProtocol?
  }

  /// #4356 plan §3.3: what this recording knows about the user in one Zoom app call. Kept across
  /// naming segments of the same call; a segment for another call starts it again.
  struct ZoomSelfIdentity {
    let source: CallSpeakerSourceAnswer.Source
    /// Set once, from a probe or a valid reading's one bound `(me)` row; never replaced.
    var knownSelf: String?
    /// Open presses sent (a press that could not complete counts).
    var opensUsed = 0
    var lastProbeAtMs: Int?
    /// A probe could not confirm that the panel it opened was closed again: no more presses.
    var pressesStopped = false
    /// The last valid reading showed the moment a probe may open the panel.
    var ready = false
  }

  /// `finishing`: Stop is saving the final log. `saved`: the final log is on disk, or was handed
  /// to a quit. `cancelled`: nothing more is saved.
  private enum Lifecycle { case open, finishing, saved, cancelled }

  private let deps: Dependencies
  private let anchor: UInt64
  /// Nil: naming is off for this recording and nothing is saved; only the mute button is read.
  /// Set once by `attachNaming` when the rules arrive after the session started.
  private var rules: TalkerRulesSnapshot?
  private var bundled: TalkerRules?
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
  /// The live call every copy is taken for; nil when there is no single supported call.
  private var binding: CallCaptureBinding?
  private var bindingGeneration: UInt64 = 0
  /// The binding last handed to `muteBinding` (nil: unbound).
  private var muteBound: CallCaptureBinding?
  /// The copy taker while no naming segment is open.
  private var muteOnly: CallSpeakerObserver?
  /// #4356: the user's identity in the Zoom app call being read.
  private var identity: ZoomSelfIdentity?
  /// #4356: where the open naming segment started (its probe tickets carry it).
  private var currentStartMs: Int?
  /// #4356: the one probe dispatched and not yet settled, for the whole recording: a change of
  /// call never clears it, and no other probe starts while it is out.
  private var pendingProbe: ZoomSelfProbeTicket?
  private var nextProbeID = 0
  /// #4356: moves whenever a probe ticket must stop counting (a different binding, a source
  /// interruption, admission closed); the lane reads it right before the open press.
  private let probeToken = OSAllocatedUnfairLock(initialState: 0)
  /// Waiting for `pendingProbe` to settle (`finish`).
  private var probeWaiters: [CheckedContinuation<Void, Never>] = []
  /// #4356: the pending probe's focus hand-back context; not part of the call's identity.
  private var handBack: HandBack?

  /// #4356: probes at least this far apart, and at most this many open presses per call.
  static let probeSpacingMs = 2_000
  static let maximumProbeOpens = 3

  init(
    anchor: UInt64, rules: TalkerRulesSnapshot?, bundled: TalkerRules?, dependencies: Dependencies
  ) {
    self.deps = dependencies
    self.anchor = anchor
    self.rules = rules
    self.bundled = bundled
  }

  /// Everything collected so far: every closed segment, then the open one. Nil without rules.
  var currentLog: CallSpeakerLog? {
    guard let rules else { return nil }
    return CallSpeakerLog(
      rules: rules.frozen, presencePolicy: presencePolicy,
      segments: closed + (current.flatMap { $0.observer.currentSegment.map { [$0] } } ?? []),
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
    rebind(answer)
    if muteBound != nil { deps.muteTick() }
    defer { driveCapture() }
    guard rules != nil, health.capacityReason == nil else { return }
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
    probeToken.withLock { $0 += 1 }
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
    guard let rules, let bundled else { return }
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
    if identity?.source != source {
      identity = surface == .zoomApp ? ZoomSelfIdentity(source: source) : nil
    }
    // One copy taker at a time on the lane: a running mute-only observer becomes this
    // segment's, keeping its copy loop.
    if let observer = muteOnly {
      muteOnly = nil
      observer.attachNaming(
        surface: surface, source: source, startMs: startMs, rules: rules,
        presencePolicy: presencePolicy, lag: lag, limits: deps.limits, baseline: closedUsage)
      current = (source, observer)
      currentStartMs = startMs
      deps.log("meeting speaker segment started surface=\(surface.rawValue)")
      return
    }
    let observer = CallSpeakerObserver(
      surface: surface, source: source, anchor: anchor, startMs: startMs, rules: rules,
      presencePolicy: presencePolicy, lag: lag, limits: deps.limits, baseline: closedUsage,
      dependencies: observerDependencies())
    current = (source, observer)
    currentStartMs = startMs
    deps.log("meeting speaker segment started surface=\(surface.rawValue)")
    observer.start()
  }

  private func closeCurrent(at endMs: Int, reason: CallSpeakerSegmentEnd) {
    guard let current else { return }
    current.observer.closeAdmission()
    let startMs = current.observer.currentSegment?.startMs ?? endMs
    if let segment = current.observer.segment(endingAt: max(endMs, startMs), reason: reason) {
      closed.append(segment)
      closedUsage.add(segment)
    }
    self.current = nil
    currentStartMs = nil
  }

  // MARK: - Capture binding (#4248)

  /// What every observer of this session copies with: the live binding, re-checked against
  /// discovery's answer now, so a change of call stops copies before the next check.
  private func observerDependencies() -> CallSpeakerObserver.Dependencies {
    let sources = deps.sources
    return .init(
      binding: { [weak self] in
        guard let self, let binding = self.binding,
          sources.speakerSource() == .unique(binding.source)
        else { return nil }
        return binding
      },
      sourceRevision: { sources.speakerSourceRevision },
      capture: { [capture = deps.capture, roles = deps.muteRules.protectedRoles] target, family in
        capture(target, family, roles)
      }, muteRules: deps.muteRules, isTrusted: deps.isTrusted, isDictationIdle: deps.isDictationIdle, lane: deps.lane,
      tick: deps.observerTick, sleep: deps.sleep,
      mute: { [weak self] copy in self?.deps.muteReading(copy) },
      muteEvent: { [weak self] event in self?.deps.muteEvent(event) }, hostTime: deps.hostTime,
      knownSelf: { [weak self] binding in
        guard let identity = self?.identity, identity.source == binding.source else { return nil }
        return identity.knownSelf
      },
      probeRequest: { [weak self] binding in self?.requestProbe(for: binding) },
      selfProbe: { [probe = deps.selfProbe, roles = deps.muteRules.protectedRoles] target, stop in
        probe(target, roles, stop)
      },
      probeCurrent: { [token = probeToken] ticket in token.withLock { $0 } == ticket.token },
      probeFinished: { [weak self] ticket in
        guard let self else { return { _ in } }
        // Held by the lane job until its result lands, then released (no lasting cycle).
        return { [self] result in self.probeFinished(ticket: ticket, result: result) }
      },
      probeInvalidated: { [token = probeToken] in token.withLock { $0 += 1 } },
      readingAdmitted: { [weak self] binding, facts in self?.readingAdmitted(binding, facts) })
  }

  // MARK: - Zoom self probe (#4356)

  /// A ticket for the lane slot an observer just claimed, when this call's user is unknown and
  /// the last valid reading showed the moment to open the panel; nil otherwise.
  private func requestProbe(for binding: CallCaptureBinding) -> ZoomSelfProbeTicket? {
    guard lifecycle == .open, stoppedAtMs == nil, binding.surface == .zoomApp,
      pendingProbe == nil, current?.source == binding.source, let segmentStartMs = currentStartMs,
      var identity, identity.source == binding.source,
      identity.knownSelf == nil, identity.ready, !identity.pressesStopped,
      identity.opensUsed < Self.maximumProbeOpens, deps.isDictationIdle()
    else { return nil }
    let now = nowMs
    if let last = identity.lastProbeAtMs, now - last < Self.probeSpacingMs { return nil }
    nextProbeID += 1
    let ticket = ZoomSelfProbeTicket(
      id: nextProbeID, source: binding.source, segmentStartMs: segmentStartMs,
      token: probeToken.withLock { $0 }, sourceRevision: deps.sources.speakerSourceRevision)
    beginHandBack(ticket: nextProbeID, zoom: binding.source.target.pid)
    // The next probe needs a fresh valid reading that shows the moment again.
    identity.ready = false
    identity.lastProbeAtMs = now
    self.identity = identity
    pendingProbe = ticket
    return ticket
  }

  /// A valid Zoom app reading of the bound call: its readiness, and the user's name when one
  /// bound `(me)` row shows it and none is known yet.
  private func readingAdmitted(_ binding: CallCaptureBinding, _ facts: ZoomSelfProbeFacts) {
    guard lifecycle == .open, var identity, identity.source == binding.source else { return }
    identity.ready = facts.ready
    if identity.knownSelf == nil, facts.boundSelfMarks.count == 1 {
      identity.knownSelf = facts.boundSelfMarks[0]
      deps.log("meeting zoom self known source=list")
    }
    self.identity = identity
  }

  /// Settles the matching ticket once. A result for another call settles its own ticket but
  /// changes nothing else; after Stop, Delete or a token move it teaches no name.
  private func probeFinished(ticket: ZoomSelfProbeTicket, result: ZoomSelfProbe.Result) {
    guard pendingProbe == ticket else { return }
    pendingProbe = nil
    let waiters = probeWaiters
    probeWaiters = []
    for waiter in waiters { waiter.resume() }
    deps.log(
      "meeting zoom self probe opened=\(result.pressedOpen) learned=\(result.learned != nil)"
        + " closed=\(result.panelClosed.map { String($0) } ?? "unknown")"
        + " user_closed=\(result.userClosed) refusal=\(result.refusal?.rawValue ?? "none")"
        + " ms=\(result.elapsedMs)")
    finishHandBack(ticket: ticket, result: result)
    // Everything below needs a live recording; the hand-back above also runs after Delete.
    guard lifecycle == .open || lifecycle == .finishing, var identity,
      identity.source == ticket.source
    else { return }
    if result.pressedOpen {
      identity.opensUsed += 1
      if !result.userClosed, result.panelClosed != true { identity.pressesStopped = true }
    }
    if identity.knownSelf == nil, let name = result.learned,
      probeToken.withLock({ $0 }) == ticket.token,
      deps.sources.speakerSourceRevision == ticket.sourceRevision
    {
      identity.knownSelf = name
      deps.log("meeting zoom self known source=probe")
    }
    self.identity = identity
  }

  /// Saves the app to ask back (never Zoom, never EnviousWispr) and starts counting
  /// activations, before the lane job can press anything.
  private func beginHandBack(ticket id: Int, zoom: pid_t) {
    if let old = handBack?.watch { deps.focus.stopWatching(old) }
    let front = deps.focus.frontmost()
    let returnTo = front.flatMap { $0 == zoom || $0 == getpid() ? nil : $0 }
    var context = HandBack(ticketID: id, returnTo: returnTo)
    if returnTo != nil {
      context.watch = deps.focus.watch { [weak self] pid in
        guard self?.handBack?.ticketID == id else { return }
        self?.handBack?.activations.append(pid)
      }
    }
    handBack = context
  }

  /// After the probe returned: asks the saved app back once, only when the probe pressed, the
  /// one activation since the ticket was Zoom's, and Zoom is still in front. Anything else the
  /// user did in between wins. The outcome is read on the next run-loop pass.
  private func finishHandBack(ticket: ZoomSelfProbeTicket, result: ZoomSelfProbe.Result) {
    guard let context = handBack, context.ticketID == ticket.id else { return }
    handBack = nil
    if let watch = context.watch { deps.focus.stopWatching(watch) }
    let zoom = ticket.source.target.pid
    guard result.pressedOpen, let returnTo = context.returnTo else {
      deps.log("meeting zoom self handback=not_needed")
      return
    }
    guard context.activations == [zoom], deps.focus.frontmost() == zoom else {
      deps.log("meeting zoom self handback=skipped_user_moved")
      return
    }
    deps.focus.activate(returnTo)
    deps.focus.nextTurn { [self] in
      let restored = deps.focus.frontmost() == returnTo
      deps.log("meeting zoom self handback=\(restored ? "restored" : "refused")")
    }
  }

  /// Returns once no probe is out.
  private func probeSettled() async {
    guard pendingProbe != nil else { return }
    await withCheckedContinuation { probeWaiters.append($0) }
  }

  /// Binds the live call from `answer`, at once.
  private func rebind(_ answer: CallSpeakerSourceAnswer) {
    var next: CallCaptureBinding?
    if case .unique(let source) = answer,
      let surface = CallSpeakerSurfaceChoice.surface(
        family: source.family, rule: source.target.rule)
    {
      if binding?.source != source { bindingGeneration += 1 }
      next = CallCaptureBinding(
        source: source, surface: surface, generation: bindingGeneration,
        mute: deps.muteFollowing() && CallMuteRules.families[surface] != nil)
    }
    if next != binding { probeToken.withLock { $0 += 1 } }
    binding = next
    let mute = next?.mute == true ? next : nil
    guard mute != muteBound else { return }
    muteBound = mute
    deps.muteBinding(mute)
  }

  /// The talker rules arrived after the session started (mute reading never waits for them):
  /// naming starts at the next check, on the running copy loop. Ignored after admission closed
  /// or when rules are already set.
  func attachNaming(rules: TalkerRulesSnapshot, bundled: TalkerRules) {
    guard lifecycle == .open, stoppedAtMs == nil, self.rules == nil else { return }
    self.rules = rules
    self.bundled = bundled
    check()
  }

  /// Mute following was switched; the binding follows at once.
  func muteFollowingChanged() {
    guard lifecycle == .open, stoppedAtMs == nil else { return }
    rebind(deps.sources.speakerSource())
    driveCapture()
  }

  /// Keeps one copy taker running: the naming segment's observer, or else a mute-only one
  /// while the binding follows the mute button.
  private func driveCapture() {
    guard current == nil else {
      retireMuteOnly()
      return
    }
    guard binding?.mute == true else {
      // Switched off or no supported call: nothing is left to read.
      retireMuteOnly()
      return
    }
    guard muteOnly == nil else { return }
    let observer = CallSpeakerObserver(
      muteOnlyAnchor: anchor, dependencies: observerDependencies())
    muteOnly = observer
    observer.start()
  }

  private func retireMuteOnly() {
    muteOnly?.closeAdmission()
    muteOnly = nil
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
    guard acceptsSaves, rules != nil else { return }
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
    guard let log = currentLog else { return }
    health.saveAttempts += 1
    do {
      try await deps.save(log)
    } catch {
      health.saveFailures += 1
      throw error
    }
  }

  /// Closes admission at once: no more checks or copies, results in flight no longer count,
  /// and the stop time is fixed. Synchronous, so a Stop calls it before its first wait.
  func closeAdmission() {
    if stoppedAtMs == nil { stoppedAtMs = nowMs }
    probeToken.withLock { $0 += 1 }
    loop?.cancel()
    loop = nil
    current?.observer.closeAdmission()
    retireMuteOnly()
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
    // A probe still out finishes its own close; its result settles before the final save.
    await probeSettled()
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
    /// Whichever observer takes copies now: the naming segment's, or the mute-only one.
    var captureObserverForTesting: CallSpeakerObserver? { current?.observer ?? muteOnly }
    var isMuteOnlyForTesting: Bool { current == nil && muteOnly != nil }
    /// The periodic save, now.
    func saveNowForTesting() { requestSave() }
    /// Waits for the save running now, if any.
    func savesSettledForTesting() async { await saving?.value }
    var zoomIdentityForTesting: ZoomSelfIdentity? { identity }
    var pendingProbeForTesting: ZoomSelfProbeTicket? { pendingProbe }
  #endif
}
