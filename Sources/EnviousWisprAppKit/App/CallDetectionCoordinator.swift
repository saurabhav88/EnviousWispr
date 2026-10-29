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
    var evidence: @Sendable (CallAppCatalog.Rule, Int32) async -> CallEvidenceReader.Evidence
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
  /// The last evidence read per process, with the bundle it was read for: it belongs to that
  /// process only, and goes when the process leaves the list (C2).
  /// The last evidence per process, with the process run it was read for and the reading it
  /// belongs to. It counts only with that reading: a later reading waits for its own read, so
  /// an answer about an earlier page never meets a newer microphone reading (C2).
  private var evidence:
    [Int32: (holder: CallMicrophoneWatcher.Holder, value: CallEvidenceReader.Evidence, reading: Int)] =
    [:]
  /// The evidence read running now; `refreshNow` waits for it.
  private var evidenceTask: Task<Void, Never>?
  private var rereadWanted = false
  /// The policy token the panel's buttons were last drawn with.
  private var drawnToken = -1

  /// #4013 chunk 13A: the one app instance a meeting's speaker capture reads for `family`, from
  /// the microphone holders of the last reading: a call app of that family, or a browser whose
  /// page reads as that family's call. `nil` when there is none, or more than one app instance
  /// (two calls, or two copies of one browser): the capture then reads nothing, never a guess.
  func speakerTarget(for family: CallAppFamily) -> CallSpeakerTarget? {
    var owners: [pid_t: CallAppCatalog.Rule] = [:]
    for holder in holders where holder.input == .active {
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
      let matches: Bool
      switch rule {
      case .callApp(let ruleFamily), .callWindow(let ruleFamily): matches = ruleFamily == family
      case .browser:
        if case .call(let pageFamily, _)? = evidence[holder.pid]?.value {
          matches = pageFamily == family
        } else {
          matches = false
        }
      }
      guard matches, let owner = CallSpeakerTarget.owner(ofHolder: holder.pid) else { continue }
      owners[owner] = rule
    }
    guard owners.count == 1, let (pid, rule) = owners.first else { return nil }
    return CallSpeakerTarget(pid: pid, rule: rule)
  }

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  /// Starts the once-a-second check; the watcher itself runs only while detection is on.
  func start() {
    guard timer == nil else { return }
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
        self.policy.noteWakeOrRestart(at: self.deps.now())
        if self.watching { self.watcher.poll() }
        self.step()
      }
    }
    tick()
  }

  /// App quit: listeners and timers go away; a detected meeting is the meeting coordinator's.
  func shutDown() {
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

  private func tick() {
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
      // No poll while an evidence read runs: the read belongs to the reading that started it,
      // so a reading and its evidence stay together (C2).
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
      if simulation != nil { evidence = evidence.mapValues { ($0.holder, $0.value, sequence) } }
    #endif
    takenAt = deps.now()
    self.complete = complete
    self.ambiguous = ambiguous
    holders = list
    if complete {
      evidence = evidence.filter { _, read in list.contains { Self.sameProcess($0, read.holder) } }
    }
    observe()
  }

  private func observe() {
    let mapped: [CallDetectionPolicy.Holder] = holders.compactMap { holder in
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { return nil }
      let input: CallDetectionPolicy.Input =
        switch holder.input {
        case .active: .active
        case .inactive: .inactive
        case .unknown: .unknown
        }
      let read = evidence[holder.pid].flatMap {
        Self.sameProcess($0.holder, holder) && $0.reading == sequence ? $0.value : nil
      }
      return .init(pid: holder.pid, rule: rule, input: input, evidence: read)
    }
    policy.observe(
      .init(
        sequence: sequence, takenAt: takenAt, complete: complete, holders: mapped,
        ambiguous: ambiguous))
  }

  /// Reads the evidence for every holder whose microphone is on or whose last read was unknown,
  /// one at a time; each result applies only while its process is still listed.
  private func readEvidence() {
    #if DEBUG
      guard simulation == nil else { return }
    #endif
    guard evidenceTask == nil else {
      rereadWanted = true
      return
    }
    let targets = holders.filter { holder in
      holder.input == .active || evidence[holder.pid]?.value == .unknown
    }
    guard !targets.isEmpty else { return }
    let read = deps.evidence
    let forReading = sequence
    evidenceTask = Task {
      var fresh: [Int32: (CallMicrophoneWatcher.Holder, CallEvidenceReader.Evidence)] = [:]
      for holder in targets {
        guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { continue }
        fresh[holder.pid] = (holder, await read(rule, holder.pid))
      }
      // The answers belong to the reading they were read for (C2): a newer reading that came
      // meanwhile (the process list changed) gets its own read instead, and a process that
      // left, or a new run of it under the same pid, never gets these.
      if self.sequence == forReading {
        for (pid, read) in fresh where self.holders.contains(where: { Self.sameProcess($0, read.0) }) {
          self.evidence[pid] = (read.0, read.1, forReading)
        }
      } else {
        self.rereadWanted = true
      }
      self.evidenceTask = nil
      self.observe()
      self.step()
      if self.rereadWanted {
        self.rereadWanted = false
        // An overdue microphone poll goes first (it starts its own read): reads never keep the
        // microphone from being checked.
        if self.watching, self.deps.now().timeIntervalSince(self.lastPoll) >= Self.pollInterval {
          self.watcher.poll()
        } else {
          self.readEvidence()
        }
      }
    }
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
      now: deps.now(), meeting: meeting, dictationActive: deps.dictationActive(), mode: mode,
      appsOff: appsOff, setUp: settings.meetingOnboardingComplete,
      startBlocked: switchAnswered && deps.detectedStartIsBlocked(),
      firstTipShown: settings.meetingCallFirstTipShown,
      noCounts: Self.counts(settings.meetingCallNoCounts))
  }

  private func step() {
    let commands = policy.step(context())
    draw()
    run(commands)
  }

  private func deliver(_ event: CallDetectionPolicy.Event) {
    var press = false
    if case .pressed = event { press = true }
    let commands = policy.handle(event, context(forPress: press))
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
    policy.isStartWanted(context())
  }

  // MARK: - Panel

  /// Draws `policy.interaction`; the buttons carry the token it was drawn with.
  private func draw() {
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
      simulation = list
      if let list {
        evidence = Dictionary(
          list.map { ($0.holder.pid, ($0.holder, $0.evidence, sequence)) },
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

    /// Hands the coordinator a watcher reading (nil: the read failed), through the same path
    /// as the real watcher, evidence reads included. Tests only.
    func deliverWatcherReading(
      _ list: [CallMicrophoneWatcher.Holder]?, ambiguous: Bool = false
    ) {
      received(list.map { .init(complete: true, holders: $0, ambiguous: ambiguous) } ?? .failed)
    }

    /// The once-a-second check, for tests that move the clock.
    func tickForTesting() { tick() }
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
