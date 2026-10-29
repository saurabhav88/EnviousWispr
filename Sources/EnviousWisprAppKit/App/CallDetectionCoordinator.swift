import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// CallDetectionCoordinator turns call-app microphone use into EnviousMeet prompts, starts and
/// stops (#4012 §3b). CallSourceDiscovery owns the shared microphone/evidence collection; this
/// layer translates: readings go into `CallDetectionPolicy`, the policy's commands are carried
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
      -> CallEvidenceReader.Snapshot = { rule, pid, retained in
        await CallEvidenceRead.boundedSnapshot(rule: rule, pid: pid, retained: retained)
      }
    /// Seconds since the Mac started, as a Date: the countdown and timeouts measure elapsed
    /// time, so changing the Mac's clock never moves them (review r15 F4).
    var now: @MainActor () -> Date = {
      Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }
    /// The panel under the menu bar (`CallPromptPanel` in the app); tests hand in a stand-in.
    var makePresenter: @MainActor (@escaping @MainActor () -> NSRect?) -> any CallPromptPresenting
    /// Tests can supply microphone frames without starting real hardware.
    var pollMicrophone: (@MainActor () -> Void)? = nil
  }

  /// Seconds between polls while a call may be on; without the process-list listener, between
  /// every poll.
  static let pollInterval = CallSourceDiscovery.pollInterval
  static let unlistenedPollInterval = CallSourceDiscovery.unlistenedPollInterval
  static let presentationTick: TimeInterval = 0.5

  private let deps: Dependencies
  private var policy = CallDetectionPolicy()
  /// Shared with speaker capture, including recordings made with prompts Off.
  let discovery: CallSourceDiscovery
  private lazy var panel: any CallPromptPresenting = deps.makePresenter(deps.anchor)
  private var timer: Timer?
  private var watching: Bool { discovery.watching }
  private var wakeObserver: NSObjectProtocol?

  private var readEnabled: Bool?
  private var readStopped = false
  private typealias RefreshRequest = CallSourceDiscovery.RefreshRequest
  private struct PendingPress {
    let token: Int
    let button: CallDetectionPolicy.Button
    let request: RefreshRequest?
  }
  private var pressRefreshTask: Task<Void, Never>?
  private var activePress: PendingPress?
  private var queuedPress: PendingPress?
  /// The policy token the panel's buttons were last drawn with.
  private var drawnToken = -1

  init(dependencies: Dependencies, discovery: CallSourceDiscovery? = nil) {
    deps = dependencies
    self.discovery = discovery ?? CallSourceDiscovery(dependencies: .init(
      snapshot: dependencies.snapshot, now: dependencies.now,
      pollMicrophone: dependencies.pollMicrophone))
    self.discovery.keepPolling = { [weak self] in self?.policy.isTrackingCalls ?? false }
    self.discovery.tracksRule = { [weak self] in self?.policy.isTracking($0) ?? false }
    self.discovery.tracksTarget = { [weak self] in self?.policy.isTracking($0) ?? false }
    self.discovery.isCurrentTarget = { [weak self] in
      guard let self, !self.readStopped else { return false }
      return self.policy.isCurrent($0)
    }
    self.discovery.hasQueuedPress = { [weak self] in self?.queuedPress != nil }
    self.discovery.onProjectionChange = { [weak self] in self?.observe() }
    self.discovery.onChange = { [weak self] in self?.step() }
  }

  /// Starts the presentation clock; shared discovery owns prompt/recording-driven polling.
  func start() {
    guard timer == nil else { return }
    readStopped = false
    // Common modes: an open menu must not stop the prompt and countdown clocks (r6 F7).
    let clock = Timer(timeInterval: Self.presentationTick, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(clock, forMode: .common)
    timer = clock
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleWake()
      }
    }
    tick()
  }

  /// App quit: listeners and timers go away; a detected meeting is the meeting coordinator's.
  func shutDown() {
    readStopped = true
    readEnabled = false
    policy.invalidateAcceptedStart()
    queuedPress = nil
    discovery.promptDemand = false
    timer?.invalidate()
    timer = nil
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
    panel.hide()
  }

  private var mode: CallDetectionPolicy.Mode {
    CallDetectionPolicy.Mode(rawValue: deps.settings.meetingCallDetection) ?? .ask
  }

  private var enabled: Bool {
    deps.settings.meetingOnboardingComplete && mode != .off && CallMicrophoneWatcher.isSupported
  }

  private func handleWake() {
    guard !readStopped else { return }
    policy.invalidateAcceptedStart()
    queuedPress = nil
    policy.noteWakeOrRestart(at: deps.now())
    discovery.noteWake()
    step()
  }

  @discardableResult
  private func updateReadLifetime() -> Bool {
    // Explicit test readings remain usable on hosts without the live CoreAudio API.
    let wanted = !readStopped && deps.settings.meetingOnboardingComplete && mode != .off
    if readEnabled != wanted {
      readEnabled = wanted
      policy.invalidateAcceptedStart()
      queuedPress = nil
      discovery.promptDemand = wanted
    }
    return wanted
  }

  private func tick() {
    updateReadLifetime()
    #if DEBUG
      if discovery.simulation != nil { discovery.repeatSimulation() }
    #endif
    step()
  }

  private func observe(at decisionTime: Date? = nil) {
    policy.observe(discovery.policyReading(at: decisionTime))
  }

  private func refreshRequest(_ target: CallDetectionPolicy.RefreshTarget?) -> RefreshRequest? {
    discovery.refreshRequest(target)
  }

  private func refreshNow(_ request: RefreshRequest?) async {
    guard updateReadLifetime(), !readStopped else { return }
    await discovery.refreshNow(request)
  }

  nonisolated static func sameProcess(_ a: CallMicrophoneWatcher.Holder,
    _ b: CallMicrophoneWatcher.Holder) -> Bool { CallSourceDiscovery.sameProcess(a, b) }

  // MARK: - Policy

  /// Flow publishes synchronously before its recording dependency can suspend or finish.
  /// Only Policy selects/fixes the historical candidate; this layer transports fresh facts.
  func acceptedStart(_ request: CallDetectionPolicy.AcceptedStart) {
    let current = context()
    guard !readStopped else { return }
    let commands = policy.acceptedStart(request, current)
    draw()
    run(commands)
  }

  func settledStart(_ request: CallDetectionPolicy.AcceptedStart, recordingID: UUID?) {
    let current = context()
    guard !readStopped else { return }
    let matching = recordingID.flatMap { id in
      current.meeting == .recording(meetingID: id) ? id : nil
    }
    let commands = policy.settledStart(request, recordingID: matching, current)
    draw()
    run(commands)
  }

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
    discovery.pruneTrackedCalls()
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
        let target = refreshRequest(policy.refreshTarget(operation: operation))
        Task {
          // Only the recording the policy meant: one started since (from the menu) is never
          // stopped by a late command.
          if case .recording(meetingID, _) = self.deps.meetingPhase() {
            await self.deps.stopMeeting()
          }
          // Fresh readings first: a switch checks the new call against them.
          await self.refreshNow(target)
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
    guard let target = policy.refreshTarget(token: token),
      activePress?.token != token, queuedPress?.token != token else { return }
    let request = PendingPress(token: token, button: button, request: refreshRequest(target))
    // Claimed now, answered after the fresh read: a Yes in time is never lost to the timeout.
    policy.claim(token: token)
    if pressRefreshTask != nil {
      // One newer answer, not another task. Its claim survives the obsolete request's boundary.
      queuedPress = request
      return
    }
    beginPress(request)
  }

  private func beginPress(_ press: PendingPress) {
    activePress = press
    pressRefreshTask = Task {
      defer { self.finishPress(press.token) }
      // Fresh readings for a Yes: the call may have ended or moved since the last read (r4 F3).
      // A question replaced meanwhile has a new token, so this press then answers nothing.
      await self.refreshNow(press.request)
      // The rules see this moment's settings first: a question whose app was switched off
      // since it showed is withdrawn.
      self.step()
      // An obsolete answer must not clear the newer question's claimed token in Policy.handle.
      if self.policy.refreshTarget(token: press.token) != nil {
        self.deliver(.pressed(token: press.token, press.button))
      }
    }
  }

  private func finishPress(_ token: Int) {
    guard activePress?.token == token else { return }
    pressRefreshTask = nil
    activePress = nil
    let next = queuedPress
    queuedPress = nil
    if let next, !readStopped, policy.refreshTarget(token: next.token) != nil { beginPress(next) }
    else { discovery.resumeReads() }
  }

  // MARK: - Dev control (DEBUG)

  #if DEBUG
    typealias SimulatedHolder = CallSourceDiscovery.SimulatedHolder
    var simulation: [SimulatedHolder]? { discovery.simulation }

    func simulate(_ list: [SimulatedHolder]?) {
      policy.invalidateAcceptedStart()
      queuedPress = nil
      discovery.simulate(list)
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
    var evidenceReadPendingForTesting: Bool { discovery.evidenceReadPending }

    /// The policy's consumed frame, not an observer of the injected reader or its cache.
    var inputForTesting: CallDetectionPolicy.Reading? { policy.inputForTesting }
    var refreshPendingForTesting: Bool { discovery.refreshPending || pressRefreshTask != nil }
    func enablePollingForTesting() { updateReadLifetime(); discovery.enablePollingForTesting() }
    func wakeForTesting() { handleWake() }

    /// Hands the coordinator a watcher reading (nil: the read failed), through the same path
    /// as the real watcher, evidence reads included. Tests only.
    func deliverWatcherReading(
      _ list: [CallMicrophoneWatcher.Holder]?, ambiguous: Bool = false
    ) {
      updateReadLifetime()
      discovery.deliverWatcherReading(list, ambiguous: ambiguous)
    }

    /// The once-a-second check, for tests that move the clock.
    func tickForTesting() { updateReadLifetime(); discovery.tickForTesting(); tick() }

    /// Exercise the same decision ingress without starting a real microphone watcher.
    func stepForTesting() { step() }
  #endif

  // MARK: - Helpers

  nonisolated static func callBundleID(bundle: String, executablePath: String?) -> String? {
    CallSourceDiscovery.callBundleID(bundle: bundle, executablePath: executablePath)
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
