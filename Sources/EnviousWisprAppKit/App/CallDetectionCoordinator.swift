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
    /// The user's own Start from the panel (Start recording on the failed-switch card): the manual route, which
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
    /// #4232: the attempt a recording will transcribe (`MeetingCoordinator.pendingAttemptID`),
    /// read before a call-flow stop so its notes card follows that attempt only.
    var pendingAttemptID: @MainActor (UUID) -> UUID? = { _ in nil }
    /// #4232: where the followed attempt's notes stand (`MeetingCoordinator.notesFollowUp`).
    var notesFollowUp: @MainActor (UUID, UUID) -> MeetingCoordinator.NotesFact = { _, _ in .ended }
    /// #4232: opens a meeting in History (the menu's Show in History route).
    var showMeeting: @MainActor (UUID) -> Void = { _ in }
    /// #4232: whether the Mac's sound is being captured for this recording now.
    var callSoundCaptured: @MainActor (UUID) -> Bool = { _ in false }
  }

  /// #4232 card lifetimes: the writing card's cap, the ready card, the menu-bar start card.
  nonisolated static let notesWritingCap: TimeInterval = 120
  nonisolated static let notesReadyLength: TimeInterval = 60
  nonisolated static let manualStartLength: TimeInterval = 2

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
  /// Whether the real call pop-up is on screen; the Diagnostics preview steps aside for it.
  var isPromptShowing: Bool { panel.isShowing }
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
  /// What the panel was last drawn with: the policy token for a policy card, a presentation
  /// generation for the coordinator's own cards.
  private var drawnKey: DrawKey?
  private enum DrawKey: Equatable {
    case policy(Int)
    case own(Int)
  }
  /// #4232: a countdown the user closed with ×. Its token is never redrawn; the countdown goes on.
  private var hiddenToken: Int?
  /// #4232: the attempt each call-flow stop froze before awaiting the stop, by meeting.
  private var frozenAttempts: [UUID: UUID] = [:]
  /// #4232: the one recording whose notes the panel follows.
  private struct NotesFollow {
    let meetingID: UUID
    let attemptID: UUID
    /// New when Ready replaces Writing, so a Writing button can never act on Ready.
    var generation: Int
    var writingShownAt: Date?
    var writingHidden = false
    var readySince: Date?
  }
  private var follow: NotesFollow?
  /// #4232: the two-second menu-bar start card.
  private struct ManualCard {
    let recordingID: UUID
    /// The linked call, or nil for the microphone card (its Mac-sound line is read each draw).
    let call: CallAppIdentity?
    let until: Date
    let generation: Int
  }
  private var manualCard: ManualCard?
  private var ownGeneration = 0

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
    follow = nil
    manualCard = nil
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
    // The failed-switch card's own Start recording rides the menu route but is no menu-bar
    // start; the flow marks it, also across the call-sound explainer.
    if request.route == .menu, !request.fromCallPanel, let matching {
      // #4232: a menu-bar Start says what it records, for two seconds. Only for the recording
      // that still runs; the call is named only when the policy linked this start to one.
      ownGeneration += 1
      manualCard = ManualCard(
        recordingID: matching, call: policy.linkedCall(matching).map(CallAppIdentity.init),
        until: current.now.addingTimeInterval(Self.manualStartLength), generation: ownGeneration)
    }
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
        // #4232: frozen before the stop can suspend, so the notes card follows this recording's
        // attempt and never one that replaced it meanwhile.
        if let attempt = deps.pendingAttemptID(meetingID) { frozenAttempts[meetingID] = attempt }
        Task {
          // Only the recording the policy meant: one started since (from the menu) is never
          // stopped by a late command.
          if case .recording(meetingID, _) = self.deps.meetingPhase() {
            await self.deps.stopMeeting()
          }
          // Fresh readings first: a switch checks the new call against them.
          await self.refreshNow(target)
          self.deliver(.stopFinished(operation: operation))
          self.frozenAttempts[meetingID] = nil
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
      case .followNotes(let meetingID, _):
        // No frozen attempt: nothing is known to follow, so no card (plan §3.5).
        guard let attempt = frozenAttempts.removeValue(forKey: meetingID) else { continue }
        ownGeneration += 1
        follow = NotesFollow(meetingID: meetingID, attemptID: attempt, generation: ownGeneration)
        draw()
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

  /// Draws the one card the panel shows. Priority: the policy's card, then the menu-bar start
  /// card, then the notes follow-up (#4232). Every card's clock runs whether or not it is drawn,
  /// and a card that expired while covered never comes back.
  private func draw() {
    guard !readStopped else { panel.hide(); return }
    let now = deps.now()
    let followed = followContent(now)
    if let card = manualCard {
      // It says a recording is running: gone the moment that recording is not.
      let running: Bool
      if case .recording(card.recordingID, _) = deps.meetingPhase() { running = true } else { running = false }
      if now >= card.until || !running { manualCard = nil }
    }
    if let content = content(policy.interaction) {
      if policy.token == hiddenToken {
        hidePanel()
        return
      }
      show(content, key: .policy(policy.token)) { self.actions(token: self.policy.token, for: content) }
    } else if let card = manualCard {
      let identity =
        card.call ?? .microphone(withCallSound: deps.callSoundCaptured(card.recordingID))
      show(.manualStart(identity), key: .own(card.generation)) { CallPromptActions() }
    } else if let followed {
      show(followed.content, key: .own(followed.generation)) {
        self.followActions(generation: followed.generation)
      }
    } else {
      hidePanel()
    }
  }

  private func show(
    _ content: CallPromptContent, key: DrawKey, actions: () -> CallPromptActions
  ) {
    if key != drawnKey || panel.content != content || !panel.isShowing {
      panel.show(content, actions: actions())
    }
    drawnKey = key
    if case .own = key, case .notesWriting = content, follow?.writingShownAt == nil {
      follow?.writingShownAt = deps.now()
    }
  }

  private func hidePanel() {
    if panel.isShowing || panel.content != nil { panel.hide() }
    drawnKey = nil
  }

  /// The notes follow-up's card now, with its generation; retires the follow-up when its
  /// recording ended, was replaced, or its card expired. Its deadlines are stored once.
  private func followContent(_ now: Date) -> (content: CallPromptContent, generation: Int)? {
    guard var current = follow else { return nil }
    if case .recording(let id, _) = deps.meetingPhase(), id != current.meetingID {
      follow = nil
      return nil
    }
    switch deps.notesFollowUp(current.meetingID, current.attemptID) {
    case .ended:
      follow = nil
      return nil
    case .ready:
      if current.readySince == nil {
        ownGeneration += 1
        current.generation = ownGeneration
      }
      let since = current.readySince ?? now
      current.readySince = since
      guard now < since.addingTimeInterval(Self.notesReadyLength) else {
        follow = nil
        return nil
      }
      follow = current
      return (.notesReady(meetingID: current.meetingID), current.generation)
    case .writing:
      if let shown = current.writingShownAt,
        now >= shown.addingTimeInterval(Self.notesWritingCap)
      {
        current.writingHidden = true
      }
      follow = current
      return current.writingHidden ? nil : (.notesWriting, current.generation)
    }
  }

  private func followActions(generation: Int) -> CallPromptActions {
    func current() -> NotesFollow? {
      guard let follow, follow.generation == generation else { return nil }
      return follow
    }
    return CallPromptActions(
      open: { [weak self] in
        guard let self, let followed = current() else { return }
        // Checked again now: the meeting may have been deleted or transcribed again since the
        // card was drawn.
        guard self.followContent(self.deps.now())?.generation == generation,
          self.deps.notesFollowUp(followed.meetingID, followed.attemptID) == .ready
        else {
          self.draw()
          return
        }
        self.follow = nil
        self.deps.showMeeting(followed.meetingID)
        self.draw()
      },
      dismiss: { [weak self] in
        guard let self, let followed = current() else { return }
        // × on Writing only hides it; × on Ready ends the follow-up.
        if followed.readySince == nil { self.follow?.writingHidden = true } else { self.follow = nil }
        self.draw()
      })
  }

  private func identity(episode: Int, family: CallAppFamily) -> CallAppIdentity {
    policy.call(episode: episode).map(CallAppIdentity.init) ?? .app(family, bundleID: nil)
  }

  private func content(_ interaction: CallDetectionPolicy.Interaction) -> CallPromptContent? {
    switch interaction {
    case .none: nil
    case .ask(let e, let family, _): .ask(identity(episode: e, family: family))
    case .switchCall(let e, let family, _, _): .switchMeeting(identity(episode: e, family: family))
    case .endConfirmation(let e, let family): .endConfirmation(identity(episode: e, family: family))
    case .countdown(let e, let deadline):
      .countdown(
        policy.call(episode: e).map(CallAppIdentity.init),
        secondsLeft: max(1, Int(ceil(deadline.timeIntervalSince(deps.now())))))
    case .switchNotConfirmed(let family, _): .switchNotConfirmed(.app(family, bundleID: nil))
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

  private func actions(token: Int, for content: CallPromptContent) -> CallPromptActions {
    func press(_ button: CallDetectionPolicy.Button) -> @MainActor () -> Void {
      { [weak self] in self?.pressed(button, token: token) }
    }
    var actions = CallPromptActions(
      yes: press(.yes), no: press(.no), stopRecording: press(.stopRecording),
      keepRecording: press(.keepRecording), endRecording: press(.endRecording),
      startNewRecording: press(.startNewRecording), openSettings: press(.openSettings),
      dismiss: press(.close))
    if case .countdown = content {
      // #4232: × hides the countdown and changes nothing else; the recording still stops.
      actions.dismiss = { [weak self] in
        guard let self, self.policy.token == token else { return }
        self.hiddenToken = token
        self.draw()
      }
    }
    return actions
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
