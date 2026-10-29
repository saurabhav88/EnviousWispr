import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// CallDetectionCoordinator turns call-app microphone use into EnviousMeet prompts, starts and
/// stops (#4012 §3b). It owns the panel and reads microphone holders and their evidence from
/// `CallSourceDiscovery` (#4013 13B), and it
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
    /// Seconds since the Mac started, as a Date: the countdown and timeouts measure elapsed
    /// time, so changing the Mac's clock never moves them (review r15 F4).
    var now: @MainActor () -> Date = {
      Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }
    /// The panel under the menu bar (`CallPromptPanel` in the app); tests hand in a stand-in.
    var makePresenter: @MainActor (@escaping @MainActor () -> NSRect?) -> any CallPromptPresenting
  }

  private let deps: Dependencies
  /// Microphone holders and their evidence; shared with speaker capture.
  let discovery: CallSourceDiscovery
  private var policy = CallDetectionPolicy()
  private lazy var panel: any CallPromptPresenting = deps.makePresenter(deps.anchor)
  private var timer: Timer?
  /// Prompts are on and readings go to the policy.
  private var watching = false
  private var wakeObserver: NSObjectProtocol?
  /// The policy token the panel's buttons were last drawn with.
  private var drawnToken = -1

  init(dependencies: Dependencies, discovery: CallSourceDiscovery) {
    deps = dependencies
    self.discovery = discovery
    discovery.keepPolling = { [weak self] in self?.policy.isTrackingCalls ?? false }
    discovery.onChange = { [weak self] in self?.discoveryChanged() }
  }

  /// Starts the once-a-second check; discovery watches for prompts only while detection is on.
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
        self.discovery.noteWake()
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
    discovery.promptDemand = false
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
      // Turning prompts on reads at once; a recording may keep discovery on after they go off.
      discovery.promptDemand = watching
    }
    #if DEBUG
      if discovery.simulation != nil {
        // A simulation is a standing reading, taken again every tick.
        discovery.repeatSimulation()
        observe()
        step()
        return
      }
    #endif
    step()
  }

  /// A new reading or evidence read. The policy sees every one; with prompts off (a recording
  /// keeps discovery on) its rules ask and start nothing.
  private func discoveryChanged() {
    observe()
    step()
  }

  private func observe() {
    let mapped: [CallDetectionPolicy.Holder] = discovery.holders.compactMap { holder in
      guard let rule = CallAppCatalog.rule(forBundleID: holder.bundleID) else { return nil }
      let input: CallDetectionPolicy.Input =
        switch holder.input {
        case .active: .active
        case .inactive: .inactive
        case .unknown: .unknown
        }
      return .init(
        pid: holder.pid, rule: rule, input: input, evidence: discovery.currentEvidence(for: holder))
    }
    policy.observe(
      .init(
        sequence: discovery.sequence, takenAt: discovery.takenAt, complete: discovery.complete,
        holders: mapped, ambiguous: discovery.ambiguous))
  }

  /// A fresh microphone poll and its evidence reads, finished, while prompts are on.
  private func refreshNow() async {
    guard watching else { return }
    await discovery.refreshNow()
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
    typealias SimulatedHolder = CallSourceDiscovery.SimulatedHolder

    var simulation: [SimulatedHolder]? { discovery.simulation }

    func simulate(_ list: [SimulatedHolder]?) {
      discovery.simulate(list)
      if list == nil { step() }
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

    var isWatching: Bool { discovery.watching }

    /// Hands discovery a watcher reading (nil: the read failed), through the same path as the
    /// real watcher, evidence reads included. Tests only.
    func deliverWatcherReading(
      _ list: [CallMicrophoneWatcher.Holder]?, ambiguous: Bool = false
    ) {
      discovery.deliverWatcherReading(list, ambiguous: ambiguous)
    }

    /// The once-a-second check, for tests that move the clock.
    func tickForTesting() { tick() }
  #endif

  // MARK: - Helpers

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
