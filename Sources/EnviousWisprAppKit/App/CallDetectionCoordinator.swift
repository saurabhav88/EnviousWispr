import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// CallDetectionCoordinator turns call-app microphone use into EnviousMeet prompts, starts and
/// stops (#4012 §3b). It owns the microphone watcher, the evidence reads and the panel, and it
/// only translates: readings go into `CallDetectionPolicy`, the policy's commands are carried
/// out, and their results go back in as events. What the panel shows is the policy's
/// `interaction`, drawn here and nowhere else. Meetings themselves stay `MeetingCoordinator`'s,
/// and every Start goes through `MeetingStartFlow`. A limb: when anything here fails, manual
/// Start and Stop and dictation go on unchanged.
@MainActor
final class CallDetectionCoordinator {
  struct Dependencies {
    var settings: SettingsManager
    var meetingPhase: @MainActor () -> MeetingCoordinator.Phase
    var stopMeeting: @MainActor () async -> Void
    /// A Start for a call (`MeetingStartFlow.requestStart(from: .detected, callApp:)`).
    var requestStart: @MainActor (CallAppFamily?) async -> MeetingStartFlow.Outcome
    /// The user's own Start from the panel ("Start a new recording"): the manual route, which
    /// may ask macOS or show the explainer because the user asked for it.
    var startByUser: @MainActor (CallAppFamily?) async -> MeetingStartFlow.Outcome
    /// Whether a detected Start would stop for setup, a macOS prompt or the explainer
    /// (`MeetingStartFlow.detectedStartIsBlocked`); a switch checks it before stopping.
    var detectedStartIsBlocked: @MainActor () -> Bool
    var dictationActive: @MainActor () -> Bool
    var showMeetingPage: @MainActor () -> Void
    var anchor: @MainActor () -> NSRect?
    var emit: @MainActor (MeetingCallPromptTelemetry) -> Void
    /// The evidence for one holder, read off the main actor with its own bound.
    var snapshot: @Sendable (CallAppCatalog.Rule, Int32, CallEvidenceReader.RetainedTarget?) async
      -> CallEvidenceReader.Snapshot
    /// Seconds since the Mac started, as a Date: the countdown and timeouts measure elapsed
    /// time, so changing the Mac's clock never moves them (review r15 F4).
    var now: @MainActor () -> Date = {
      Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }
    /// The panel under the menu bar (`CallPromptPanel` in the app); tests hand in a stand-in.
    var makePresenter: @MainActor (@escaping @MainActor () -> NSRect?) -> any CallPromptPresenting
  }

  /// Seconds between polls while a call may be on; without the process-list listener, between
  /// every poll.
  static let pollInterval: TimeInterval = 2
  static let unlistenedPollInterval: TimeInterval = 10

  private let deps: Dependencies
  private var policy = CallDetectionPolicy()
  private lazy var watcher = CallMicrophoneWatcher(
    candidateBundleID: { bundle, path in Self.callBundleID(bundle: bundle, executablePath: path) },
    mayBeCandidate: { CallAppCatalog.mayBeCallApp(bundleID: $0) },
    onReading: { [weak self] reading in self?.received(reading) })
  private lazy var panel: any CallPromptPresenting = deps.makePresenter(deps.anchor)
  private var timer: Timer?
  private var watching = false
  private var wakeObserver: NSObjectProtocol?

  /// The last watcher reading, as it came.
  private var holders: [CallMicrophoneWatcher.Holder] = []
  private var complete = false
  private var ambiguous = false
  private var takenAt = Date.distantPast
  private var sequence = 0
  private var lastPoll = Date.distantPast
  private struct CachedEvidence {
    let holder: CallMicrophoneWatcher.Holder
    let value: CallEvidenceReader.Evidence
    var reading: Int
    var source: CallDetectionPolicy.Source? = nil
    var activityRevision = 0
    var beganAt = Date.distantPast
  }
  private struct SourceState {
    var holder: CallMicrophoneWatcher.Holder
    var source: CallDetectionPolicy.Source
    var activityRevision = 0
    var present = true
    var owner: CallEvidenceReader.AppRun? = nil
    var knownCalls: [CallEvidenceReader.RetainedTarget] = []
  }
  private struct ReadTarget {
    let state: SourceState
    let retained: CallEvidenceReader.RetainedTarget?
  }
  private var evidence: [Int32: CachedEvidence] = [:]
  private var sources: [Int32: SourceState] = [:]
  /// These survive microphone polls and absence; no cached observation is re-dated.
  private var continuity: [CallDetectionPolicy.ContinuityObservation] = []
  private var pendingSources: [CallDetectionPolicy.Source] = []
  private var nextSourceID = 0
  private var nextObservationID = 0
  private var readLifetime = 0
  private var nextReadID = 0
  private var currentReadID: Int?
  private var readEnabled: Bool?
  private var readStopped = false
  /// The evidence read running now; `refreshNow` waits for it.
  private var evidenceTask: Task<Void, Never>?
  private var rereadWanted = false
  /// The policy token the panel's buttons were last drawn with.
  private var drawnToken = -1

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  /// Starts the once-a-second check; the watcher itself runs only while detection is on.
  func start() {
    guard timer == nil else { return }
    readStopped = false
    // Common modes: an open menu must not stop the prompt and countdown clocks (r6 F7).
    let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(clock, forMode: .common)
    timer = clock
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidateReadWork()
        self.policy.noteWakeOrRestart(at: self.deps.now())
        if self.watching { self.watcher.poll() }
        self.step()
      }
    }
    tick()
  }

  /// App quit: listeners and timers go away; a detected meeting is the meeting coordinator's.
  func shutDown() {
    readStopped = true
    readEnabled = false
    invalidateReadWork()
    timer?.invalidate()
    timer = nil
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
    watcher.stop()
    watching = false
    panel.hide()
  }

  private var mode: CallDetectionPolicy.Mode {
    CallDetectionPolicy.Mode(rawValue: deps.settings.meetingCallDetection) ?? .ask
  }

  private var enabled: Bool {
    deps.settings.meetingOnboardingComplete && mode != .off && CallMicrophoneWatcher.isSupported
  }

  /// Reading lifetime is independent of microphone-frame sequence. A cancelled bounded read
  /// retains its task slot until it really returns; no new AX work is piled behind it.
  private func invalidateReadWork(clearInputs: Bool = true) {
    readLifetime += 1
    evidenceTask?.cancel()
    rereadWanted = false
    sources = [:]
    continuity = []
    pendingSources = []
    if clearInputs {
      holders = []
      evidence = [:]
      complete = false
      ambiguous = false
      takenAt = .distantPast
    }
    observe()
  }

  @discardableResult
  private func updateReadLifetime() -> Bool {
    // Explicit test readings remain usable on hosts without the live CoreAudio API.
    let wanted = !readStopped && deps.settings.meetingOnboardingComplete && mode != .off
    if let previous = readEnabled, previous != wanted {
      var clearInputs = true
      #if DEBUG
        clearInputs = simulation == nil
      #endif
      invalidateReadWork(clearInputs: clearInputs)
    }
    readEnabled = wanted
    return wanted
  }

  private func tick() {
    updateReadLifetime()
    if enabled != watching {
      watching = enabled
      if watching {
        watcher.start()
      } else {
        watcher.stop()
        holders = []
        evidence = [:]
        complete = false
      }
    }
    let now = deps.now()
    #if DEBUG
      if simulation != nil {
        // A simulation is a standing reading, taken again every tick.
        record(holders: holders, complete: true, ambiguous: false)
        step()
        return
      }
    #endif
    if watching {
      let mayBeOn = !holders.isEmpty || !complete || policy.isTrackingCalls
      let interval = watcher.isListening ? Self.pollInterval : Self.unlistenedPollInterval
      // Retain the existing poll schedule until the fair-cycle/cadence cutover. Listener
      // readings can arrive during a read without invalidating independent continuity.
      // Every poll reads the evidence afresh: a tab switched to a meeting while the microphone
      // stays on is seen, and an unknown read is retried (review r4 F2).
      if evidenceTask == nil, mayBeOn || !watcher.isListening,
        now.timeIntervalSince(lastPoll) >= interval
      {
        watcher.poll()
      }
    }
    step()
  }

  private func received(_ reading: CallMicrophoneWatcher.Reading) {
    #if DEBUG
      // A dev-control simulation owns the readings until it is cleared.
      guard simulation == nil else { return }
    #endif
    guard updateReadLifetime() else { step(); return }
    lastPoll = deps.now()
    record(holders: reading.holders, complete: reading.complete, ambiguous: reading.ambiguous)
    readEvidence()
    step()
  }

  /// Keeps a reading and hands it to the policy with the evidence of its processes.
  private func record(holders list: [CallMicrophoneWatcher.Holder], complete: Bool, ambiguous: Bool)
  {
    sequence += 1
    #if DEBUG
      // A simulation's evidence is part of its standing reading.
      if simulation != nil {
        evidence = evidence.mapValues { cached in
          var standing = cached
          standing.reading = sequence
          return standing
        }
      }
    #endif
    takenAt = deps.now()
    self.complete = complete
    self.ambiguous = ambiguous
    holders = list
    var seen: Set<Int32> = []
    for holder in list {
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
      seen.insert(holder.pid)
      if var state = sources[holder.pid], Self.sameProcess(state.holder, holder) {
        if !state.present || state.holder.input != holder.input { state.activityRevision += 1 }
        state.holder = holder
        state.present = true
        sources[holder.pid] = state
      } else {
        if let previous = sources[holder.pid] {
          publishContinuity(.unknown, owner: nil, for: previous.source, beganAt: deps.now())
        }
        nextSourceID += 1
        sources[holder.pid] = .init(holder: holder,
          source: .init(id: nextSourceID, pid: holder.pid, rule: rule))
      }
    }
    if complete {
      evidence = evidence.filter { _, read in list.contains { Self.sameProcess($0, read.holder) } }
      for pid in Array(sources.keys) where !seen.contains(pid) {
        guard var state = sources[pid] else { continue }
        if state.present { state.activityRevision += 1 }
        state.present = false
        sources[pid] = state
      }
      // Hold the last independent observation for tracked calls, not for every past process.
      sources = sources.filter { seen.contains($0.key) || policy.isTracking($0.value.source.rule) }
      continuity = continuity.filter { value in
        sources[value.source.pid]?.source == value.source || policy.isTracking(value.source.rule)
      }
    }
    observe()
  }

  private func observe(at decisionTime: Date? = nil) {
    let projectionTime = decisionTime ?? deps.now()
    let mapped: [CallDetectionPolicy.Holder] = holders.compactMap { holder in
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { return nil }
      let input: CallDetectionPolicy.Input =
        switch holder.input {
        case .active: .active
        case .inactive: .inactive
        case .unknown: .unknown
        }
      let read = evidence[holder.pid].flatMap { cached -> CallEvidenceReader.Evidence? in
        guard Self.sameProcess(cached.holder, holder) else { return nil }
        #if DEBUG
          if simulation != nil { return cached.reading == sequence ? cached.value : nil }
        #endif
        guard let state = sources[holder.pid], cached.source == state.source,
          cached.activityRevision == state.activityRevision
        else { return nil }
        let age = projectionTime.timeIntervalSince(cached.beganAt)
        return age >= 0 && age <= CallDetectionPolicy.staleAfter ? cached.value : nil
      }
      return .init(pid: holder.pid, rule: rule, input: input, evidence: read)
    }
    policy.observe(
      .init(
        sequence: sequence, takenAt: takenAt, complete: complete, holders: mapped,
        ambiguous: ambiguous,
        sources: holders.compactMap { sources[$0.pid]?.source },
        continuity: continuity.sorted { $0.id < $1.id },
        pendingSources: pendingSources.filter { sources[$0.pid]?.source == $0 }))
  }

  /// Reads active or unknown holders and the apps of tracked calls, even when their microphones
  /// are off. Results belong to their source/request, independently of microphone sequence.
  private func readEvidence() {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard updateReadLifetime() else { return }
    guard evidenceTask == nil else {
      rereadWanted = true
      return
    }
    let listed = holders.filter { holder in
      let tracked = CallAppCatalog.rule(forBundleID: holder.bundleID)
        .map { policy.isTracking($0) } ?? false
      return holder.input == .active || evidence[holder.pid]?.value == .unknown || tracked
    }.compactMap { holder -> SourceState? in
      guard let state = sources[holder.pid], state.present,
        Self.sameProcess(state.holder, holder) else { return nil }
      return state
    }
    var targets = listed.map { ReadTarget(state: $0, retained: nil) }
    for state in sources.values.sorted(by: { $0.source.id < $1.source.id }) where !state.present {
      for target in state.knownCalls where target.owner == state.owner && policy.isTracking(target) {
        targets.append(.init(state: state, retained: target))
      }
    }
    guard !targets.isEmpty else { return }
    let read = deps.snapshot
    let lifetime = readLifetime
    nextReadID += 1
    let requestID = nextReadID
    currentReadID = requestID
    pendingSources = targets.map(\.state.source)
    observe()
    evidenceTask = Task {
      defer { self.finishRead(requestID) }
      for target in targets {
        guard self.currentReadID == requestID, self.readLifetime == lifetime,
          !Task.isCancelled, self.updateReadLifetime() else { break }
        guard let current = self.sources[target.state.source.pid],
          current.source == target.state.source,
          self.canQuery(current, retained: target.retained)
        else {
          self.removePending(target.state.source)
          continue
        }
        let beganAt = self.deps.now()
        let value = await read(current.source.rule, current.holder.pid, target.retained)
        guard self.currentReadID == requestID, self.readLifetime == lifetime,
          !Task.isCancelled, self.updateReadLifetime() else { break }
        self.removePending(current.source)
        if let retained = target.retained {
          self.acceptRetained(value, requested: current, target: retained, beganAt: beganAt)
        } else { self.accept(value, requested: current, beganAt: beganAt) }
        // A healthy early source is useful now, not after every other app has answered.
        self.observe()
        self.step()
      }
    }
  }

  private func canQuery(_ state: SourceState, retained: CallEvidenceReader.RetainedTarget?) -> Bool {
    if let retained {
      return !state.present && state.owner == retained.owner && state.knownCalls.contains(retained)
        && policy.isTracking(retained)
    }
    return state.present && holders.contains { Self.sameProcess($0, state.holder) }
  }

  private func removePending(_ source: CallDetectionPolicy.Source) {
    if let index = pendingSources.firstIndex(of: source) { pendingSources.remove(at: index) }
  }

  private func accept(
    _ value: CallEvidenceReader.Snapshot, requested: SourceState, beganAt: Date
  ) {
    let pid = requested.source.pid
    guard var current = sources[pid], current.present, current.source == requested.source,
      holders.contains(where: { Self.sameProcess($0, requested.holder) })
    else { return }
    if let expected = requested.owner, let actual = value.owner, expected != actual {
      // This request belongs to the replaced run. Publish loss of its identity, never its
      // positive result; a new microphone frame and query must establish the replacement.
      publishContinuity(.unknown, owner: nil, for: requested.source, beganAt: beganAt)
      nextSourceID += 1
      current.source = .init(id: nextSourceID, pid: pid, rule: current.source.rule)
      current.activityRevision += 1
      current.present = false
      current.owner = actual
      current.knownCalls = []
      sources[pid] = current
      evidence[pid] = nil
      rereadWanted = true
      return
    }
    let sameRun = requested.owner == nil || requested.owner == value.owner
    publishContinuity(sameRun && value.owner != nil ? value.continuity : .unknown,
      owner: sameRun ? value.owner : nil, for: requested.source, beganAt: beganAt)
    if let owner = value.owner { current.owner = owner }
    if sameRun, let target = capturedTarget(value, source: current.source), !current.knownCalls.contains(target) {
      current.knownCalls.append(target)
    }
    sources[pid] = current
    if current.activityRevision == requested.activityRevision {
      let start: CallEvidenceReader.Evidence
      if !sameRun, case .call = value.startEvidence { start = .unknown }
      else { start = value.startEvidence }
      evidence[pid] = .init(holder: current.holder, value: start, reading: sequence,
        source: current.source, activityRevision: current.activityRevision, beganAt: beganAt)
    }
  }

  private func capturedTarget(
    _ value: CallEvidenceReader.Snapshot, source: CallDetectionPolicy.Source
  ) -> CallEvidenceReader.RetainedTarget? {
    guard let owner = value.owner else { return nil }
    let call: (CallAppFamily, String)
    switch value.continuity {
    case .ongoing(let family, let room), .ended(let family, let room): call = (family, room)
    case .unknown:
      switch value.startEvidence {
      case .call(let family, let room), .microphoneOnly(let family, let room): call = (family, room)
      case .none, .unknown: return nil
      }
    }
    return .init(rule: source.rule, holderPID: source.pid, owner: owner, family: call.0, room: call.1)
  }

  private func acceptRetained(
    _ value: CallEvidenceReader.Snapshot, requested: SourceState,
    target: CallEvidenceReader.RetainedTarget, beganAt: Date
  ) {
    guard let current = sources[requested.source.pid], current.source == requested.source,
      current.owner == target.owner, current.knownCalls.contains(target), policy.isTracking(target)
    else { return }
    let valid = value.owner == target.owner && target.accepts(value.continuity)
    publishContinuity(valid ? value.continuity : .unknown, owner: valid ? value.owner : nil,
      for: requested.source, beganAt: beganAt, retainedTarget: target)
    // No start cache or microphone field is written by a retained completion.
  }

  private func publishContinuity(
    _ value: CallEvidenceReader.Continuity, owner: CallEvidenceReader.AppRun?,
    for source: CallDetectionPolicy.Source, beganAt: Date,
    retainedTarget: CallEvidenceReader.RetainedTarget? = nil
  ) {
    nextObservationID += 1
    continuity.removeAll { $0.source == source && $0.retainedTarget == retainedTarget }
    continuity.append(.init(id: nextObservationID, source: source, beganAt: beganAt,
      completedAt: deps.now(), owner: owner, value: value, retainedTarget: retainedTarget))
  }

  private func finishRead(_ id: Int) {
    guard currentReadID == id else { return }
    evidenceTask = nil
    currentReadID = nil
    pendingSources = []
    guard !readStopped else { return }
    observe()
    step()
    guard rereadWanted, updateReadLifetime() else { return }
    rereadWanted = false
    // Preserve the existing finite poll/refresh scheduling until the scheduling cutover.
    if watching, deps.now().timeIntervalSince(lastPoll) >= Self.pollInterval { watcher.poll() }
    else { readEvidence() }
  }

  /// A fresh microphone poll and the evidence reads it starts, finished: a Yes and a switch
  /// act on what the call shows now, not on a read from before (review r4 F3, r12 F1).
  private func refreshNow() async {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard watching else { return }
    // A read already running belongs to an older reading: let it finish first.
    if let running = evidenceTask { await running.value }
    watcher.poll()
    // The reads for this poll, and at most one more if the process list changed meanwhile:
    // never an open-ended wait.
    for _ in 0..<2 {
      guard let running = evidenceTask else { break }
      await running.value
    }
  }

  nonisolated static func sameProcess(
    _ a: CallMicrophoneWatcher.Holder, _ b: CallMicrophoneWatcher.Holder
  ) -> Bool {
    a.pid == b.pid && a.bundleID == b.bundleID && a.object == b.object
  }

  // MARK: - Policy

  private var appsOff: Set<String> {
    CallAppCatalog.appsOff(from: deps.settings.meetingCallAppsOff)
  }

  private func context(forPress: Bool = false) -> CallDetectionPolicy.Context {
    updateReadLifetime()
    let now = deps.now()
    // All decision ingresses use one time for proof projection and policy freshness.
    // This updates no microphone timestamp or completed continuity observation.
    observe(at: now)
    let meeting: CallDetectionPolicy.Meeting =
      switch deps.meetingPhase() {
      case .idle: .idle
      case .starting, .stopping: .busy
      case .recording(let id, _): .recording(meetingID: id)
      }
    let settings = deps.settings
    var switchAnswered = false
    if forPress, case .switchCall = policy.interaction { switchAnswered = true }
    return .init(
      now: now, meeting: meeting, dictationActive: deps.dictationActive(), mode: mode,
      appsOff: appsOff, setUp: settings.meetingOnboardingComplete,
      startBlocked: switchAnswered && deps.detectedStartIsBlocked(),
      firstTipShown: settings.meetingCallFirstTipShown,
      noCounts: Self.counts(settings.meetingCallNoCounts))
  }

  private func step() {
    updateReadLifetime()
    guard !readStopped else { return }
    let current = context()
    let commands = policy.step(current)
    draw()
    run(commands)
    for pid in Array(sources.keys) {
      guard var state = sources[pid] else { continue }
      state.knownCalls.removeAll { !policy.isTracking($0) }
      sources[pid] = state
    }
  }

  private func deliver(_ event: CallDetectionPolicy.Event) {
    var press = false
    if case .pressed = event { press = true }
    let current = context(forPress: press)
    let commands = policy.handle(event, current)
    draw()
    run(commands)
  }

  private func run(_ commands: [CallDetectionPolicy.Command]) {
    for command in commands {
      switch command {
      case .start(let operation, let family):
        Task {
          let outcome = await self.deps.requestStart(family)
          self.deliver(.startFinished(operation: operation, Self.result(outcome)))
        }
      case .startByUser(let operation, let family):
        Task {
          // The user's own Start: the manual route handles its explainer and prompts itself.
          let outcome = await self.deps.startByUser(family)
          self.deliver(.startFinished(operation: operation, Self.result(outcome)))
        }
      case .stop(let operation, let meetingID):
        Task {
          // Only the recording the policy meant: one started since (from the menu) is never
          // stopped by a late command.
          if case .recording(meetingID, _) = self.deps.meetingPhase() {
            await self.deps.stopMeeting()
          }
          // Fresh readings first: a switch checks the new call against them.
          await self.refreshNow()
          self.deliver(.stopFinished(operation: operation))
        }
      case .emit(let family, let answer):
        deps.emit(.init(family: family, answer: answer, mode: mode.rawValue))
      case .countNo(let switchID):
        var counts = Self.counts(deps.settings.meetingCallNoCounts)
        counts[switchID, default: 0] += 1
        deps.settings.meetingCallNoCounts = Self.encode(counts)
      case .markFirstTipShown:
        deps.settings.meetingCallFirstTipShown = true
      case .openMeetingPage:
        deps.showMeetingPage()
      }
    }
  }

  static func result(_ outcome: MeetingStartFlow.Outcome) -> CallDetectionPolicy.StartResult {
    switch outcome {
    case .started(.recording(let id)): .recording(meetingID: id)
    case .started(.refused), .started(.failed): .couldNotStart
    case .started(.superseded): .superseded
    case .needsAttention: .needsAttention
    case .started(.notIdle), .waitingForExplainer, .joinedMicrophonePrompt, .cancelled, .notIdle,
      .setupRequired:
      .notStarted
    }
  }

  /// Asked by the meeting start after each of its waits (review r4 F1, r12 F1).
  func detectedStartStillWanted() -> Bool {
    let current = context()
    return policy.isStartWanted(current)
  }

  // MARK: - Panel

  /// Draws `policy.interaction`; the buttons carry the token it was drawn with.
  private func draw() {
    guard !readStopped else { panel.hide(); return }
    guard let content = content(policy.interaction) else {
      if panel.isShowing || panel.content != nil { panel.hide() }
      drawnToken = policy.token
      return
    }
    if policy.token != drawnToken || panel.content != content || !panel.isShowing {
      panel.show(content, actions: actions(token: policy.token))
    }
    drawnToken = policy.token
  }

  private func content(_ interaction: CallDetectionPolicy.Interaction) -> CallPromptContent? {
    switch interaction {
    case .none: nil
    case .ask(_, let family, _): .ask(appName: family.displayName)
    case .switchCall(_, let family, _, _): .switchMeeting(appName: family.displayName)
    case .countdown(_, let deadline):
      .countdown(secondsLeft: max(1, Int(ceil(deadline.timeIntervalSince(deps.now())))))
    case .stopped(.callEnded, _, _): .stopped
    case .stopped(.switchNotConfirmed, _, _): .switchNotConfirmed
    case .note(.firstTip, _): .firstTip
    case .note(.lastTip(let rule, let family), _):
      // Named by the switch the user can turn off: a browser meeting's is "Meetings in a
      // browser", not the meeting service (review r15 F6).
      if case .browser = rule {
        .lastTip(appName: String(localized: MeetingsCopy.browserMeetings))
      } else {
        .lastTip(appName: family.displayName)
      }
    case .note(.needsAttention, _): .needsAttention
    case .note(.couldNotStart, _): .couldNotStart
    }
  }

  private func actions(token: Int) -> CallPromptActions {
    func press(_ button: CallDetectionPolicy.Button) -> @MainActor () -> Void {
      { [weak self] in self?.pressed(button, token: token) }
    }
    return CallPromptActions(
      yes: press(.yes), no: press(.no), keepRecording: press(.keepRecording),
      startNewRecording: press(.startNewRecording), openSettings: press(.openSettings),
      dismiss: press(.close))
  }

  private func pressed(_ button: CallDetectionPolicy.Button, token: Int) {
    guard button == .yes else {
      step()
      deliver(.pressed(token: token, button))
      return
    }
    // Claimed now, answered after the fresh read: a Yes in time is never lost to the timeout.
    policy.claim(token: token)
    Task {
      // Fresh readings for a Yes: the call may have ended or moved since the last read (r4 F3).
      // A question replaced meanwhile has a new token, so this press then answers nothing.
      await self.refreshNow()
      // The rules see this moment's settings first: a question whose app was switched off
      // since it showed is withdrawn.
      self.step()
      self.deliver(.pressed(token: token, button))
    }
  }

  // MARK: - Dev control (DEBUG)

  #if DEBUG
    /// One faked microphone holder and the evidence its read returns (`call.simulate`).
    struct SimulatedHolder {
      let holder: CallMicrophoneWatcher.Holder
      let evidence: CallEvidenceReader.Evidence
    }

    /// While set, these replace the watcher's readings and the Accessibility reads; the rules,
    /// the panel and every Start run as in production.
    private(set) var simulation: [SimulatedHolder]?

    func simulate(_ list: [SimulatedHolder]?) {
      invalidateReadWork()
      simulation = list
      if let list {
        evidence = Dictionary(
          list.map { ($0.holder.pid, CachedEvidence(holder: $0.holder, value: $0.evidence, reading: sequence)) },
          uniquingKeysWith: { a, _ in a })
        record(holders: list.map(\.holder), complete: true, ambiguous: false)
      } else {
        holders = []
        evidence = [:]
        complete = false
        // Back to the real microphone.
        if watching { watcher.poll() }
      }
      step()
    }

    /// What the panel shows, for the dev-control reply.
    var panelContent: CallPromptContent? { panel.isShowing ? panel.content : nil }

    /// The panel's buttons, pressed through dev control when a click cannot reach them.
    func press(_ button: String) -> Bool {
      guard panel.isShowing, let content = panel.content,
        let action = panel.actions.action(named: button, for: content)
      else { return false }
      action()
      return true
    }

    var isWatching: Bool { watching }

    /// A negative reader-selection assertion must wait for the actual async batch to settle.
    var evidenceReadPendingForTesting: Bool { evidenceTask != nil }

    /// The policy's consumed frame, not an observer of the injected reader or its cache.
    var inputForTesting: CallDetectionPolicy.Reading? { policy.inputForTesting }

    /// Hands the coordinator a watcher reading (nil: the read failed), through the same path
    /// as the real watcher, evidence reads included. Tests only.
    func deliverWatcherReading(
      _ list: [CallMicrophoneWatcher.Holder]?, ambiguous: Bool = false
    ) {
      received(list.map { .init(complete: true, holders: $0, ambiguous: ambiguous) } ?? .failed)
    }

    /// The once-a-second check, for tests that move the clock.
    func tickForTesting() { tick() }

    /// Exercise the same decision ingress without starting a real microphone watcher.
    func stepForTesting() { step() }
  #endif

  // MARK: - Helpers

  /// The bundle identifier the catalog knows for a microphone-holding process: its own, or for
  /// a helper without one, its owning app's (§3.2).
  nonisolated static func callBundleID(bundle: String, executablePath: String?) -> String? {
    if !bundle.isEmpty, CallAppCatalog.rule(forBundleID: bundle) != nil {
      return bundle.lowercased()
    }
    guard let path = executablePath, let app = CallAppCatalog.owningAppPath(ofExecutable: path),
      let owner = Bundle(path: app)?.bundleIdentifier,
      CallAppCatalog.rule(forBundleID: owner) != nil
    else { return nil }
    return owner.lowercased()
  }

  static func counts(_ text: String) -> [String: Int] {
    var result: [String: Int] = [:]
    for pair in text.split(separator: ",") {
      let parts = pair.split(separator: "=")
      if parts.count == 2, let n = Int(parts[1]) { result[String(parts[0])] = n }
    }
    return result
  }

  static func encode(_ counts: [String: Int]) -> String {
    counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ",")
  }
}
