import EnviousWisprCore
import Foundation

/// What EnviousMeet does about calls (#4012 §3.4, D1-D10): pure rules over what the watcher and
/// the evidence reader observed, with an injected clock. It decides; `CallDetectionCoordinator`
/// carries the decisions out. No system calls here, so every rule is tested directly.
///
/// Two owners, nothing else (`docs/audits/2026-10-24-4012-leak-enumeration.md`):
/// - **Episodes.** A call is an `Episode` with its own id. It begins only from known positive
///   start evidence in a complete reading. Only independently attributed, fresh call-ended
///   observations can confirm its end; microphone inactivity never owns that decision.
/// - **The interaction.** What the panel shows is `interaction`, and `token` changes with it. A
///   button press carries the token it was shown with; an old token does nothing. A start or a
///   stop is an `Operation` with its own id: its result always settles its episode, whatever
///   the panel shows by then.
public struct CallDetectionPolicy: Sendable {
  public enum Mode: String, Sendable, CaseIterable, Equatable {
    case ask
    case startByItself = "start_by_itself"
    case off
  }

  /// A microphone reading for one process: unknown never starts or ends a call (R7, §2.5 4).
  public enum Input: Sendable, Equatable { case active, inactive, unknown }

  /// One call-app process in a reading.
  public struct Holder: Sendable, Equatable {
    public let pid: Int32
    public let rule: CallAppCatalog.Rule
    public let input: Input
    /// The last evidence read for this process, or nil when none was read yet. A URL or window
    /// is START evidence only (R4).
    public let evidence: CallEvidenceReader.Evidence?

    public init(
      pid: Int32, rule: CallAppCatalog.Rule, input: Input, evidence: CallEvidenceReader.Evidence?
    ) {
      self.pid = pid
      self.rule = rule
      self.input = input
      self.evidence = evidence
    }
  }

  /// A listed microphone source instance, separate from its verified regular app run.
  package struct Source: Sendable, Equatable {
    package let id: Int
    package let pid: Int32
    package let rule: CallAppCatalog.Rule

    package init(id: Int, pid: Int32, rule: CallAppCatalog.Rule) {
      self.id = id
      self.pid = pid
      self.rule = rule
    }
  }

  /// Produced only at Flow's accepted recording request, before its first start suspension.
  /// `acceptedAt` shares the policy's monotonic clock, not a recording file's wall clock.
  package struct AcceptedStart: Sendable, Equatable {
    package let generation: Int
    package let route: MeetingEntryPoint
    package let acceptedAt: Date

    package init(generation: Int, route: MeetingEntryPoint, acceptedAt: Date) {
      self.generation = generation
      self.route = route
      self.acceptedAt = acceptedAt
    }
  }

  /// A read-only reference to the question/operation that requested fresh proof.
  package struct RefreshTarget: Sendable, Equatable {
    package enum Reference: Sendable, Equatable {
      case question(token: Int)
      case operation(Int)
    }
    package let reference: Reference
    package let episode: Int
    package let rule: CallAppCatalog.Rule
    package let family: CallAppFamily
    package let room: String

    package func matches(_ target: CallEvidenceReader.RetainedTarget) -> Bool {
      target.rule == rule && target.family == family
        && (CallDetectionPolicy.isNative(rule) || target.room == room)
    }
  }

  package struct ContinuityObservation: Sendable, Equatable {
    package let id: Int
    package let source: Source
    /// Conservative age starts when this read began, never when a later microphone poll ran.
    package let beganAt: Date
    package let completedAt: Date
    package let owner: CallEvidenceReader.AppRun?
    package let value: CallEvidenceReader.Continuity
    /// Explicit historical target for a retained query; nil means the source's current view.
    package let retainedTarget: CallEvidenceReader.RetainedTarget?

    package init(
      id: Int, source: Source, beganAt: Date, completedAt: Date,
      owner: CallEvidenceReader.AppRun?, value: CallEvidenceReader.Continuity,
      retainedTarget: CallEvidenceReader.RetainedTarget? = nil
    ) {
      self.id = id
      self.source = source
      self.beganAt = beganAt
      self.completedAt = completedAt
      self.owner = owner
      self.value = value
      self.retainedTarget = retainedTarget
    }
  }

  /// Microphone facts and independently completed call-state observations.
  public struct Reading: Sendable, Equatable {
    /// Rises with every reading the watcher takes; an older one is never applied.
    public let sequence: Int
    public let takenAt: Date
    /// The process list itself was read. When false, `holders` proves nothing.
    public let complete: Bool
    public let holders: [Holder]
    /// A process that may belong to a call app could not be named, and its microphone was on
    /// or could not be read: no call can be confirmed off.
    public let ambiguous: Bool
    package let sources: [Source]
    /// Latest completed value per source + retained-target slot. A later value replaces its
    /// own slot; fresh ongoing facts in different applicable slots still conflict with end.
    package let continuity: [ContinuityObservation]
    package let pendingSources: [Source]

    public init(
      sequence: Int, takenAt: Date, complete: Bool, holders: [Holder], ambiguous: Bool = false
    ) {
      self.init(sequence: sequence, takenAt: takenAt, complete: complete, holders: holders,
        ambiguous: ambiguous, sources: [], continuity: [], pendingSources: [])
    }

    package init(
      sequence: Int, takenAt: Date, complete: Bool, holders: [Holder], ambiguous: Bool,
      sources: [Source], continuity: [ContinuityObservation], pendingSources: [Source]
    ) {
      self.sequence = sequence
      self.takenAt = takenAt
      self.complete = complete
      self.holders = holders
      self.ambiguous = ambiguous
      self.sources = sources
      self.continuity = continuity
      self.pendingSources = pendingSources
    }
  }

  /// The meeting side, as the coordinator reports it.
  public enum Meeting: Sendable, Equatable {
    case idle
    /// Starting or stopping.
    case busy
    case recording(meetingID: UUID)
  }

  public struct Context: Sendable, Equatable {
    public var now: Date
    public var meeting: Meeting
    public var dictationActive: Bool
    public var mode: Mode
    public var appsOff: Set<String>
    public var setUp: Bool
    /// Asked only when a switch is answered: whether a detected Start would stop for setup, a
    /// macOS prompt, the explainer or low disk (checked before the current meeting stops).
    public var startBlocked: Bool
    /// D6, read when No is answered.
    public var firstTipShown: Bool
    public var noCounts: [String: Int]

    public init(
      now: Date, meeting: Meeting, dictationActive: Bool = false, mode: Mode = .ask,
      appsOff: Set<String> = [], setUp: Bool = true, startBlocked: Bool = false,
      firstTipShown: Bool = false, noCounts: [String: Int] = [:]
    ) {
      self.now = now
      self.meeting = meeting
      self.dictationActive = dictationActive
      self.mode = mode
      self.appsOff = appsOff
      self.setUp = setUp
      self.startBlocked = startBlocked
      self.firstTipShown = firstTipShown
      self.noCounts = noCounts
    }
  }

  public enum Note: Sendable, Equatable {
    case firstTip
    /// D6: the third No for the switch `rule` belongs to.
    case lastTip(rule: CallAppCatalog.Rule, family: CallAppFamily)
    case needsAttention
    case couldNotStart
  }

  public enum StopReason: Sendable, Equatable {
    case callEnded
    /// A switch stopped the old recording, but the new call could not be confirmed.
    case switchNotConfirmed
  }

  /// What the panel shows.
  public enum Interaction: Sendable, Equatable {
    case none
    /// D1 Ask: "Record this call?"
    case ask(episode: Int, family: CallAppFamily, since: Date)
    /// D10: a new call while `from` records.
    case switchCall(episode: Int, family: CallAppFamily, from: UUID, since: Date)
    /// D3: "Meeting ending in N seconds" with Keep recording.
    case countdown(episode: Int, deadline: Date)
    /// D3 as delivered: "Recording stopped" with Start a new recording.
    case stopped(StopReason, family: CallAppFamily, until: Date)
    case note(Note, until: Date)
  }

  public enum Button: String, Sendable, CaseIterable {
    case yes, no, close, keepRecording, startNewRecording, openSettings
  }

  /// A start's result, as the coordinator maps `MeetingStartFlow.Outcome`.
  public enum StartResult: Sendable, Equatable {
    case recording(meetingID: UUID)
    /// A macOS prompt or the explainer is needed first.
    case needsAttention
    /// Refused (low disk, microphone off) or the recorder failed.
    case couldNotStart
    /// Taken over while it started (a Stop, or this policy no longer wanted it).
    case superseded
    /// Nothing started and nothing to say (a meeting was already starting).
    case notStarted
  }

  public enum Event: Sendable, Equatable {
    case pressed(token: Int, Button)
    case startFinished(operation: Int, StartResult)
    case stopFinished(operation: Int)
  }

  /// What the coordinator carries out.
  public enum Command: Sendable, Equatable {
    /// A detected Start; its result comes back as `.startFinished(operation:)`.
    case start(operation: Int, family: CallAppFamily)
    /// The user's own Start (Start a new recording): the manual route.
    case startByUser(operation: Int, family: CallAppFamily)
    /// Stop `meetingID` if it is still the meeting recording; `.stopFinished(operation:)`
    /// follows either way.
    case stop(operation: Int, meetingID: UUID)
    case emit(family: CallAppFamily, answer: MeetingCallPromptTelemetry.Answer)
    case countNo(switchID: String)
    case markFirstTipShown
    case openMeetingPage
  }

  // Independent call-end confirmation retains the established 1.5 s minimum and two reads.
  // Consent questions have their own approved readiness, lifetime and global display clocks.
  public static let endConfirm: TimeInterval = 1.5
  public static let endReadingsRequired = 2
  public static let wakeHoldoff: TimeInterval = 10
  public static let countdownLength: TimeInterval = 10
  public static let questionReadiness: TimeInterval = 2
  public static let questionInterval: TimeInterval = 120
  public static let promptTimeout: TimeInterval = 120
  public static let noteTimeout: TimeInterval = 15
  public static let stoppedOffer: TimeInterval = 60
  /// A reading older than this proves nothing (five 2-second watcher intervals).
  public static let staleAfter: TimeInterval = 10

  struct Episode: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
      /// Known, not asked about yet.
      case waiting
      /// Asked, answered, timed out or recorded once: never asked about again.
      case offered
      /// A start (or a switch's stop and start) is running.
      case starting(operation: Int)
      case recording(meetingID: UUID)
      /// Keep recording: the meeting is the user's; this call's end never stops it.
      case kept(meetingID: UUID)
      case ending(meetingID: UUID, deadline: Date)
      case stopping(operation: Int)
    }

    let id: Int
    let rule: CallAppCatalog.Rule
    let family: CallAppFamily
    /// The meeting room for a browser call; one call per app for a native app.
    let room: String
    let noticedAt: Date
    var establishedAt: Date
    var sources: [Source] = []
    var owner: CallEvidenceReader.AppRun? = nil
    /// A deliberate Keep or manual Stop cannot become another automatic ownership link.
    var ownershipOverridden = false
    var phase: Phase
    /// Confirmed over while its Start ran: the Start is no longer wanted.
    var endedWhileStarting = false
    var endSince: Date?
    var endReadings = 0
    var lastEndedReadAt: Date?
    var lastObservationID = 0
  }

  enum Operation: Sendable, Equatable {
    case start(episode: Int, family: CallAppFamily, byItself: Bool)
    /// D10 Yes: stop `from`, then start the episode.
    case switchTo(episode: Int, family: CallAppFamily, from: UUID)
    case stopForEnd(episode: Int, family: CallAppFamily)
    case userStart
  }

  public private(set) var interaction: Interaction = .none
  /// Changes every time `interaction` does.
  public private(set) var token = 0
  /// A Yes pressed on this token is being checked on fresh readings: the question does not
  /// time out meanwhile. Anything that changes the panel ends the claim.
  private var claimedToken: Int?
  private(set) var episodes: [Episode] = []
  private var operations: [Int: Operation] = [:]
  /// The operation whose Start is running now, for `isStartWanted`.
  private var startingOperation: Int?
  private var nextID = 1
  private var reading: Reading?
  private var holdoffUntil: Date?
  private var lastQuestionShownAt: Date?
  private struct ManualCandidate {
    let episode: Int
    let owner: CallEvidenceReader.AppRun
    let sources: [Source]
    let room: String
    let family: CallAppFamily
    let rule: CallAppCatalog.Rule
  }
  private struct PendingManual {
    let request: AcceptedStart
    let candidate: ManualCandidate?
  }
  private enum Association {
    case rejected(UUID)
    case linked(UUID, episode: Int)
    case overridden(UUID)

    var recordingID: UUID {
      switch self {
      case .rejected(let id), .linked(let id, _), .overridden(let id): id
      }
    }
  }
  private var pendingManual: PendingManual?
  private var association: Association?
  private var latestAcceptedGeneration = 0

  public init() {}

  /// Whether any call is known: the watcher keeps polling while one is.
  public var isTrackingCalls: Bool { !episodes.isEmpty }

  /// The apps whose existing episodes still need observations, even with their microphones off.
  package func isTracking(_ rule: CallAppCatalog.Rule) -> Bool {
    episodes.contains { $0.rule == rule }
  }

  package func isTracking(_ target: CallEvidenceReader.RetainedTarget) -> Bool {
    episodes.contains {
      $0.rule == target.rule && $0.family == target.family
        && (Self.isNative(target.rule) || $0.room == target.room)
    }
  }

  package func refreshTarget(token requestedToken: Int) -> RefreshTarget? {
    guard requestedToken == token else { return nil }
    let id: Int
    switch interaction {
    case .ask(let episode, _, _), .switchCall(let episode, _, _, _): id = episode
    default: return nil
    }
    return refreshTarget(episode: id, reference: .question(token: requestedToken))
  }

  package func refreshTarget(operation: Int) -> RefreshTarget? {
    guard case .switchTo(let episode, _, _) = operations[operation] else { return nil }
    return refreshTarget(episode: episode, reference: .operation(operation))
  }

  package func isCurrent(_ target: RefreshTarget) -> Bool {
    switch target.reference {
    case .question(let token): return refreshTarget(token: token) == target
    case .operation(let id): return refreshTarget(operation: id) == target
    }
  }

  private func refreshTarget(episode id: Int, reference: RefreshTarget.Reference) -> RefreshTarget? {
    guard let episode = episodes.first(where: { $0.id == id }) else { return nil }
    return .init(reference: reference, episode: id, rule: episode.rule,
      family: episode.family, room: episode.room)
  }

  #if DEBUG
    package var inputForTesting: Reading? { reading }
  #endif

  // MARK: - Inputs

  /// A new reading. One older than the last applied is dropped.
  public mutating func observe(_ new: Reading) {
    if let reading, new.sequence < reading.sequence { return }
    reading = new
  }

  /// After wake from sleep or an audio service restart: no call starts or ends for a while,
  /// and every end is counted afresh (a sleep past a countdown's deadline never stops at once).
  public mutating func noteWakeOrRestart(at now: Date) {
    invalidateAcceptedStart()
    holdoffUntil = now.addingTimeInterval(Self.wakeHoldoff)
    let consumed = reading?.continuity.map(\.id).max() ?? 0
    for index in episodes.indices {
      episodes[index].lastObservationID = max(episodes[index].lastObservationID, consumed)
      resetEnd(index)
    }
  }

  /// The rules for this moment: ends, timeouts, new calls, questions.
  public mutating func step(_ c: Context) -> [Command] {
    var out: [Command] = []
    guard c.setUp, c.mode != .off else {
      // Nothing is watched while off, so what is known about calls is out of date: when
      // watching resumes, every call is a new one. A running recording goes on as the user's.
      episodes = []
      pendingManual = nil
      if case .recording(let id) = c.meeting { association = .rejected(id) }
      set(.none)
      return out
    }
    followMeeting(c)
    expire(c, &out)
    trackEnds(c, &out)
    noticeCalls(c)
    offer(c, &out)
    return out
  }

  /// Freeze existing provenance synchronously at Flow acceptance; no later discovery can
  /// turn a rejected request into a candidate. This observer never starts or renames a meeting.
  package mutating func acceptedStart(_ request: AcceptedStart, _ c: Context) -> [Command] {
    guard request.generation > latestAcceptedGeneration else { return [] }
    latestAcceptedGeneration = request.generation
    pendingManual = nil
    guard request.route == .menu || request.route == .history,
      c.setUp, c.mode != .off, c.meeting == .idle, request.acceptedAt <= c.now
    else { return [] }
    followMeeting(c)
    let plausible = episodes.filter { episode in
      guard !inHoldoff(c), episode.establishedAt <= request.acceptedAt, episode.owner != nil,
        !episode.ownershipOverridden,
        !c.appsOff.contains(CallAppCatalog.switchID(for: episode.rule)) else { return false }
      switch episode.phase { case .waiting, .offered: break; default: return false }
      let ongoing = (reading?.continuity ?? []).contains {
        guard $0.completedAt <= request.acceptedAt, fresh($0, c) else { return false }
        if case .ongoing? = state($0, for: episode) { return true }
        return false
      }
      return ongoing || isKnownLive(episode, c)
    }
    var candidate: ManualCandidate?
    if plausible.count == 1, let episode = plausible.first, let owner = episode.owner,
      !episode.sources.isEmpty,
      let latest = reading?.continuity.filter({ state($0, for: episode) != nil })
        .max(by: { $0.id < $1.id }),
      latest.completedAt <= request.acceptedAt, fresh(latest, c), latest.owner == owner
    {
      let qualifies: Bool
      switch state(latest, for: episode) {
      case .ongoing?: qualifies = true
      case .unknown?: qualifies = Self.isNative(episode.rule) && isKnownLive(episode, c)
      case .ended?, nil: qualifies = false
      }
      if qualifies {
        candidate = .init(episode: episode.id, owner: owner, sources: episode.sources,
          room: episode.room, family: episode.family, rule: episode.rule)
      }
    }
    pendingManual = .init(request: request, candidate: candidate)
    // A user-accepted recording is already starting; an old consent question cannot start it
    // again. Keep its offered suppression and invalidate its button token immediately.
    switch interaction { case .ask, .switchCall: set(.none); default: break }
    return []
  }

  /// A replaced read lifetime cannot carry a historical in-flight ticket into its successor.
  package mutating func invalidateAcceptedStart() {
    pendingManual = nil
  }

  package mutating func settledStart(
    _ request: AcceptedStart, recordingID: UUID?, _ c: Context
  ) -> [Command] {
    guard let pending = pendingManual, pending.request == request,
      request.generation == latestAcceptedGeneration else { return [] }
    pendingManual = nil
    guard let recordingID else { return [] }
    guard association?.recordingID != recordingID else { return [] }
    association = .rejected(recordingID)
    guard c.setUp, c.mode != .off, c.meeting == .recording(meetingID: recordingID),
      let frozen = pending.candidate,
      !c.appsOff.contains(CallAppCatalog.switchID(for: frozen.rule)),
      let index = episodes.firstIndex(where: { $0.id == frozen.episode }),
      !episodes[index].ownershipOverridden,
      episodes[index].owner == frozen.owner, episodes[index].sources == frozen.sources,
      episodes[index].room == frozen.room, episodes[index].family == frozen.family,
      episodes[index].rule == frozen.rule,
      let latest = reading?.continuity.filter({ state($0, for: episodes[index]) != nil })
        .max(by: { $0.id < $1.id }), fresh(latest, c), latest.owner == frozen.owner,
      frozen.sources.contains(latest.source)
    else { return [] }
    if case .ended? = state(latest, for: episodes[index]) { return [] }
    if case .ongoing(let family, let room) = latest.value,
      family != frozen.family || (!Self.isNative(frozen.rule) && room != frozen.room) { return [] }
    // Historical eligibility is not recomputed here; only the frozen episode/run/source/room
    // is checked for invalidation. Another candidate cannot replace it at completion.
    switch episodes[index].phase { case .waiting, .offered: break; default: return [] }
    setPhase(frozen.episode, .recording(meetingID: recordingID))
    association = .linked(recordingID, episode: frozen.episode)
    return step(c)
  }

  /// A Yes was pressed on `pressedToken`; its answer arrives after fresh readings.
  public mutating func claim(token pressedToken: Int) {
    if pressedToken == token { claimedToken = pressedToken }
  }

  public mutating func handle(_ event: Event, _ c: Context) -> [Command] {
    var out: [Command] = []
    switch event {
    case .pressed(let pressedToken, let button):
      guard pressedToken == token else { return [] }
      claimedToken = nil
      pressed(button, c, &out)
    case .startFinished(let id, let result):
      startFinished(id, result, c, &out)
    case .stopFinished(let id):
      stopFinished(id, c, &out)
    }
    return out + step(c)
  }

  /// Asked by the meeting start after each of its waits: the running detected Start is still
  /// wanted (its call was not confirmed over, and detection and its app are still on).
  /// Uncertainty never withdraws a Start the user or the rules already chose.
  public func isStartWanted(_ c: Context) -> Bool {
    guard c.setUp, c.mode != .off, let id = startingOperation, let operation = operations[id]
    else { return false }
    let episodeID: Int
    switch operation {
    case .start(let e, _, _), .switchTo(let e, _, _): episodeID = e
    case .stopForEnd, .userStart: return false
    }
    guard let episode = episodes.first(where: { $0.id == episodeID }), !episode.endedWhileStarting
    else { return false }
    return !c.appsOff.contains(CallAppCatalog.switchID(for: episode.rule))
  }

  // MARK: - Rules

  private func isFresh(_ c: Context) -> Bool {
    guard let reading, reading.complete else { return false }
    let age = c.now.timeIntervalSince(reading.takenAt)
    return age >= 0 && age <= Self.staleAfter
  }

  private func attribution(for holder: Holder, _ c: Context) -> (Source?, ContinuityObservation?) {
    guard let reading, let source = reading.sources.first(where: { $0.pid == holder.pid && $0.rule == holder.rule })
    else { return (nil, nil) }
    let observation = reading.continuity.filter { $0.source == source && $0.retainedTarget == nil }
      .max { $0.id < $1.id }
    guard let observation, fresh(observation, c) else { return (source, nil) }
    return (source, observation)
  }

  private func fresh(_ observation: ContinuityObservation, _ c: Context) -> Bool {
    let age = c.now.timeIntervalSince(observation.beganAt)
    return age >= 0 && age <= Self.staleAfter
      && observation.completedAt >= observation.beganAt && observation.completedAt <= c.now
  }

  /// Nil is another target; unknown is an applicable conflict/loss, never a convenient skip.
  private func state(_ observation: ContinuityObservation, for episode: Episode) -> CallEvidenceReader.Continuity? {
    guard observation.source.rule == episode.rule else { return nil }
    if let target = observation.retainedTarget {
      guard target.family == episode.family, target.owner == episode.owner,
        Self.isNative(episode.rule) || target.room == episode.room else { return nil }
    } else {
      let sameOwner = episode.owner != nil && observation.owner == episode.owner
      guard sameOwner || episode.sources.contains(observation.source) else { return nil }
    }
    guard let owner = episode.owner, observation.owner == owner else { return .unknown }
    switch observation.value {
    case .ongoing(let family, let room), .ended(let family, let room):
      guard family == episode.family, Self.isNative(episode.rule) || room == episode.room else { return .unknown }
      return observation.value
    case .unknown: return .unknown
    }
  }

  private func inHoldoff(_ c: Context) -> Bool {
    if let holdoffUntil, c.now < holdoffUntil { return true }
    return false
  }

  /// Candidate processes of the app; verified run and room checks decide episode membership.
  private func members(of episode: Episode) -> [Holder] {
    reading?.holders.filter { $0.rule == episode.rule } ?? []
  }

  /// Recheck the current mode at every admission, including answers to an older Ask (#4094).
  /// Existing call evidence keeps its app-specific meaning; it is not always window proof.
  private static func admittedCall(
    _ evidence: CallEvidenceReader.Evidence?, mode: Mode
  ) -> (family: CallAppFamily, room: String)? {
    guard let evidence else { return nil }
    switch evidence {
    case .call(let family, let room): return (family, room)
    case .microphoneOnly(let family, let room): return mode == .ask ? (family, room) : nil
    case .none, .unknown: return nil
    }
  }

  /// The call is going on now, known: a process of its app has the microphone on and shows
  /// this call, in a fresh complete reading.
  private func isKnownLive(_ episode: Episode, _ c: Context) -> Bool {
    guard isFresh(c) else { return false }
    return members(of: episode).contains { holder in
      guard holder.input == .active,
        let (family, room) = Self.admittedCall(holder.evidence, mode: c.mode)
      else {
        return false
      }
      guard family == episode.family && (Self.isNative(episode.rule) || room == episode.room) else { return false }
      if let owner = episode.owner {
        guard attribution(for: holder, c).1?.owner == owner else { return false }
      }
      if let latest = reading?.continuity.filter({ state($0, for: episode) != nil }).max(by: { $0.id < $1.id }),
        fresh(latest, c), latest.beganAt >= episode.establishedAt,
        case .ended? = state(latest, for: episode)
      { return false }
      return true
    }
  }

  private static func isNative(_ rule: CallAppCatalog.Rule) -> Bool {
    if case .browser = rule { return false }
    return true
  }

  /// A recording an episode owns that is no longer the meeting recording (stopped from the
  /// menu, switched): the episode stays offered. A switch question follows the recording.
  private mutating func followMeeting(_ c: Context) {
    if c.meeting != .busy {
      for index in episodes.indices {
        switch episodes[index].phase {
        case .recording(let m), .kept(let m), .ending(let m, _):
          if c.meeting != .recording(meetingID: m) {
            episodes[index].ownershipOverridden = true
            if case .linked(let linkedID, _)? = association, linkedID == m {
              association = .rejected(m)
            }
            if case .countdown(episodes[index].id, _) = interaction { set(.none) }
            episodes[index].phase = .offered
            resetEnd(index)
          }
        default: break
        }
      }
    }
    switch (interaction, c.meeting) {
    case (.switchCall(let e, let family, _, _), .idle):
      // Nothing records any more: the question is a plain Record this call?, with its own
      // full time (review r18 F1).
      set(.ask(episode: e, family: family, since: c.now))
    case (.switchCall(let e, let family, let from, _), .recording(let m)) where m != from:
      set(.switchCall(episode: e, family: family, from: m, since: c.now))
    case (.stopped, .recording), (.stopped, .busy):
      // A new recording started elsewhere: the offer is over (r6 F4).
      set(.none)
    default: break
    }
  }

  private mutating func expire(_ c: Context, _ out: inout [Command]) {
    // An answer given in time is never lost to the clock while it is checked (review r14 F2).
    if claimedToken == token { return }
    switch interaction {
    case .ask(_, let family, let since) where c.now.timeIntervalSince(since) >= Self.promptTimeout:
      // An unanswered prompt closes; not a No, and the call stays offered (D2).
      out.append(.emit(family: family, answer: .timeout))
      set(.none)
    case .switchCall(_, _, _, let since)
    where c.now.timeIntervalSince(since) >= Self.promptTimeout:
      set(.none)
    case .stopped(_, _, let until) where c.now >= until: set(.none)
    case .note(_, let until) where c.now >= until: set(.none)
    default: break
    }
  }

  private mutating func resetEnd(_ index: Int) {
    episodes[index].endSince = nil
    episodes[index].endReadings = 0
    episodes[index].lastEndedReadAt = nil
    if case .ending(let m, _) = episodes[index].phase {
      episodes[index].phase = .recording(meetingID: m)
      if case .countdown(episodes[index].id, _) = interaction { set(.none) }
    }
  }

  /// Only new, scoped completed UI observations confirm end. Cached IDs and microphone
  /// frames cannot contribute confirmations; unknown/conflict/staleness consumes old proof.
  private mutating func trackEnds(_ c: Context, _ out: inout [Command]) {
    var questionShown = false
    switch interaction {
    case .ask, .switchCall: questionShown = true
    default: break
    }
    var ended: [Int] = []
    for index in episodes.indices {
      let applicable = (reading?.continuity ?? []).filter { state($0, for: episodes[index]) != nil }
        .sorted { $0.id < $1.id }
      let latestID = applicable.last?.id ?? episodes[index].lastObservationID
      if inHoldoff(c) {
        episodes[index].lastObservationID = max(episodes[index].lastObservationID, latestID)
        resetEnd(index)
        continue
      }
      switch episodes[index].phase {
      case .stopping: continue
      case .recording where questionShown:
        // While a new call's question is on the panel, this meeting does not count down, and
        // no end confirmation builds up behind it: the question would hide the countdown and its Keep
        // recording (review r9 F2).
        episodes[index].lastObservationID = max(episodes[index].lastObservationID, latestID)
        resetEnd(index)
        continue
      default: break
      }
      let ongoing = applicable.contains { observation in
        guard fresh(observation, c) else { return false }
        if case .ongoing? = state(observation, for: episodes[index]) { return true }
        return false
      }
      guard !ongoing, let latest = applicable.last, fresh(latest, c),
        case .ended? = state(latest, for: episodes[index])
      else {
        episodes[index].lastObservationID = max(episodes[index].lastObservationID, latestID)
        resetEnd(index)
        continue
      }
      for observation in applicable where observation.id > episodes[index].lastObservationID {
        episodes[index].lastObservationID = observation.id
        guard fresh(observation, c), observation.beganAt >= episodes[index].establishedAt,
          case .ended? = state(observation, for: episodes[index])
        else { resetEnd(index); continue }
        if episodes[index].endSince == nil { episodes[index].endSince = observation.completedAt }
        episodes[index].endReadings += 1
        episodes[index].lastEndedReadAt = observation.beganAt
      }
      guard let since = episodes[index].endSince, let lastRead = episodes[index].lastEndedReadAt,
        episodes[index].endReadings >= Self.endReadingsRequired,
        lastRead.timeIntervalSince(since) >= Self.endConfirm
      else { continue }
      let episode = episodes[index]
      switch episode.phase {
      case .waiting, .offered, .kept:
        ended.append(episode.id)
      case .recording(let m):
        let deadline = c.now.addingTimeInterval(Self.countdownLength)
        episodes[index].phase = .ending(meetingID: m, deadline: deadline)
        set(.countdown(episode: episode.id, deadline: deadline))
      case .ending(let m, let deadline):
        guard c.now >= deadline else { continue }
        let id = newID()
        operations[id] = .stopForEnd(episode: episode.id, family: episode.family)
        episodes[index].phase = .stopping(operation: id)
        if case .countdown(episode.id, _) = interaction { set(.none) }
        out.append(.stop(operation: id, meetingID: m))
      case .starting:
        // Its Start is running: the episode stays until the Start settles, but the Start is no
        // longer wanted (review r2 F4).
        episodes[index].endedWhileStarting = true
      case .stopping:
        break
      }
    }
    for id in ended { remove(episode: id) }
  }

  /// New calls: a process with its microphone on showing known call evidence in a fresh
  /// complete reading, for an app that is switched on.
  private mutating func noticeCalls(_ c: Context) {
    // A switched-off app's calls that are not recording go away, and so do their questions.
    episodes.removeAll { episode in
      guard c.appsOff.contains(CallAppCatalog.switchID(for: episode.rule)) else { return false }
      switch episode.phase {
      case .waiting, .offered: return true
      default: return false
      }
    }
    withdrawOrphanQuestion()
    withdrawMovedQuestion(c)
    guard isFresh(c), let reading else { return }
    for holder in reading.holders where holder.input == .active {
      guard let (family, shownRoom) = Self.admittedCall(holder.evidence, mode: c.mode),
        !c.appsOff.contains(CallAppCatalog.switchID(for: holder.rule))
      else { continue }
      let room = Self.isNative(holder.rule) ? "app" : shownRoom
      let (source, observed) = attribution(for: holder, c)
      let owner = observed?.owner
      if let observed, case .ended = observed.value { continue }
      if let index = episodes.firstIndex(where: {
        guard $0.rule == holder.rule && $0.family == family && $0.room == room else { return false }
        if let old = $0.owner, let owner { return old == owner }
        return true // Uncertainty does not split a call or renew an offered question.
      }) {
        if let source, episodes[index].sources.contains(source), episodes[index].owner == nil, let owner {
          episodes[index].owner = owner
          episodes[index].establishedAt = c.now
          episodes[index].lastObservationID = reading.continuity.map(\.id).max() ?? 0
          resetEnd(index)
        }
        if let source, owner != nil, episodes[index].owner == owner,
          !episodes[index].sources.contains(source) { episodes[index].sources.append(source) }
        continue
      }
      var episode = Episode(id: newID(), rule: holder.rule, family: family, room: room,
        noticedAt: min(c.now, reading.takenAt), establishedAt: c.now, phase: .waiting)
      if let source { episode.sources = [source] }
      episode.owner = owner
      episode.lastObservationID = reading.continuity.map(\.id).max() ?? 0
      episodes.append(episode)
    }
  }

  /// One question at a time; a Yes always answers the call on the panel (review r2 F1).
  private mutating func offer(_ c: Context, _ out: inout [Command]) {
    switch interaction {
    case .ask, .switchCall: return
    default: break
    }
    guard pendingManual == nil, !inHoldoff(c), !startInFlight else { return }
    for index in episodes.indices where episodes[index].phase == .waiting {
      let episode = episodes[index]
      guard isKnownLive(episode, c) else { continue }
      let displaysQuestion = c.mode != .startByItself || c.meeting != .idle
      if displaysQuestion {
        guard c.now.timeIntervalSince(episode.noticedAt) >= Self.questionReadiness else { continue }
        if let lastQuestionShownAt, c.now.timeIntervalSince(lastQuestionShownAt) < Self.questionInterval { continue }
      }
      switch c.meeting {
      case .busy:
        return
      case .idle:
        // Never over a dictation: the prompt waits until it ends (§3.4).
        guard !c.dictationActive else { return }
        if c.mode == .startByItself {
          let id = newID()
          operations[id] = .start(episode: episode.id, family: episode.family, byItself: true)
          episodes[index].phase = .starting(operation: id)
          startingOperation = id
          out.append(.start(operation: id, family: episode.family))
        } else {
          episodes[index].phase = .offered
          set(.ask(episode: episode.id, family: episode.family, since: c.now))
        }
      case .recording(let m):
        episodes[index].phase = .offered
        set(.switchCall(episode: episode.id, family: episode.family, from: m, since: c.now))
        // The countdown would run on behind the question (review r9 F2).
        for other in episodes.indices { resetEnd(other) }
      }
      return
    }
  }

  // MARK: - Events

  private mutating func pressed(_ button: Button, _ c: Context, _ out: inout [Command]) {
    switch (interaction, button) {
    case (.ask, .yes) where startInFlight, (.switchCall, .yes) where startInFlight:
      // One Start at a time: the question stays for another press.
      return
    case (.ask(let e, let family, _), .yes):
      guard let episode = episode(e), isKnownLive(episode, c) else {
        // While a reading is unknown the question stays up for another press or its
        // timeout (review r2 F3).
        return
      }
      switch c.meeting {
      case .recording(let m):
        // A recording started since the question showed (from the menu): the question
        // becomes a switch question about that recording, asked again (review r15 F2).
        set(.switchCall(episode: e, family: family, from: m, since: c.now))
      case .idle:
        set(.none)
        out.append(.emit(family: family, answer: .yes))
        start(episode: e, family: family, &out)
      case .busy:
        return
      }
    case (.switchCall(let e, let family, let from, _), .yes):
      guard let episode = episode(e), isKnownLive(episode, c) else { return }
      switch c.meeting {
      case .recording(let m) where m == from:
        // Checked before the current meeting stops: a refusal known ahead keeps it recording.
        guard !c.startBlocked else {
          set(.none)
          showNote(.needsAttention, c)
          out.append(.emit(family: family, answer: .needsAttention))
          return
        }
        set(.none)
        out.append(.emit(family: family, answer: .switchYes))
        let id = newID()
        operations[id] = .switchTo(episode: e, family: family, from: from)
        setPhase(e, .starting(operation: id))
        out.append(.stop(operation: id, meetingID: from))
      case .recording(let m):
        set(.switchCall(episode: e, family: family, from: m, since: c.now))
      case .idle:
        set(.none)
        out.append(.emit(family: family, answer: .yes))
        start(episode: e, family: family, &out)
      case .busy:
        return
      }
    case (.ask(let e, let family, _), .no):
      set(.none)
      out.append(.emit(family: family, answer: .no))
      if let episode = episode(e) { tipAfterNo(episode, c, &out) }
    case (.switchCall(_, let family, _, _), .no):
      set(.none)
      out.append(.emit(family: family, answer: .switchNo))
    case (.ask, .close), (.switchCall, .close), (.stopped, .close), (.note, .close):
      set(.none)
    case (.countdown(let e, _), .keepRecording):
      if let index = episodes.firstIndex(where: { $0.id == e }),
        case .ending(let m, _) = episodes[index].phase
      {
        episodes[index].phase = .kept(meetingID: m)
        episodes[index].ownershipOverridden = true
        association = .overridden(m)
        resetEnd(index)
      }
      set(.none)
    case (.stopped(_, let family, _), .startNewRecording):
      set(.none)
      let id = newID()
      operations[id] = .userStart
      out.append(.startByUser(operation: id, family: family))
    case (.note, .openSettings):
      set(.none)
      out.append(.openMeetingPage)
    default:
      break
    }
  }

  private mutating func start(episode e: Int, family: CallAppFamily, _ out: inout [Command]) {
    let id = newID()
    operations[id] = .start(episode: e, family: family, byItself: false)
    setPhase(e, .starting(operation: id))
    startingOperation = id
    out.append(.start(operation: id, family: family))
  }

  /// D6: a tip after the first No ever; a last reminder after the third No for one switch.
  /// Counted by the switch the user can turn off (review r15 F6).
  private mutating func tipAfterNo(_ episode: Episode, _ c: Context, _ out: inout [Command]) {
    let switchID = CallAppCatalog.switchID(for: episode.rule)
    out.append(.countNo(switchID: switchID))
    if !c.firstTipShown {
      out.append(.markFirstTipShown)
      showNote(.firstTip, c)
    } else if c.noCounts[switchID, default: 0] + 1 == 3 {
      showNote(.lastTip(rule: episode.rule, family: episode.family), c)
    }
  }

  /// Every start outcome has one result (C5). The episode always settles; the panel changes
  /// only when nothing newer owns it.
  private mutating func startFinished(
    _ id: Int, _ result: StartResult, _ c: Context, _ out: inout [Command]
  ) {
    guard let operation = operations.removeValue(forKey: id) else { return }
    if startingOperation == id { startingOperation = nil }
    switch operation {
    case .userStart:
      switch result {
      case .needsAttention: showNote(.needsAttention, c)
      case .couldNotStart: showNote(.couldNotStart, c)
      case .recording, .superseded, .notStarted: break
      }
    case .start(let e, let family, _), .switchTo(let e, let family, _):
      var byItself = false
      if case .start(_, _, true) = operation { byItself = true }
      switch result {
      case .recording(let m):
        setPhase(e, .recording(meetingID: m))
        // auto_started only once it records (review r18 F4).
        if byItself { out.append(.emit(family: family, answer: .autoStarted)) }
      case .needsAttention:
        setPhase(e, .offered)
        out.append(.emit(family: family, answer: .needsAttention))
        showNote(.needsAttention, c)
      case .couldNotStart:
        setPhase(e, .offered)
        showNote(.couldNotStart, c)
      case .superseded:
        // Taken over during the start: the call is asked about again once it is known live
        // (review r17 F1).
        setPhase(e, .waiting)
      case .notStarted:
        setPhase(e, .offered)
      }
    case .stopForEnd:
      break
    }
  }

  private mutating func stopFinished(_ id: Int, _ c: Context, _ out: inout [Command]) {
    guard let operation = operations[id] else { return }
    switch operation {
    case .stopForEnd(let e, let family):
      operations[id] = nil
      remove(episode: e)
      // A newer recording or a newer question keeps the panel (r3 F1, review r10 F2).
      if c.meeting == .idle, interaction == .none {
        set(
          .stopped(.callEnded, family: family, until: c.now.addingTimeInterval(Self.stoppedOffer)))
      }
    case .switchTo(let e, let family, _):
      if let episode = episode(e), isKnownLive(episode, c), c.meeting == .idle, c.setUp,
        c.mode != .off, !c.appsOff.contains(CallAppCatalog.switchID(for: episode.rule))
      {
        startingOperation = id
        out.append(.start(operation: id, family: family))
        return
      }
      operations[id] = nil
      setPhase(e, .offered)
      // The old meeting stopped but the new call cannot be confirmed: say so and offer the
      // user's own Start, never a silent nothing (review r16 F1, r18 F3). Only while nothing
      // records and no newer question owns the panel (review r17 F2).
      if c.meeting == .idle, interaction == .none {
        set(
          .stopped(
            .switchNotConfirmed, family: family,
            until: c.now.addingTimeInterval(Self.stoppedOffer)))
      }
    case .start, .userStart:
      break
    }
  }

  // MARK: - Helpers

  /// A Start, or a switch's stop and start, is running.
  private var startInFlight: Bool {
    operations.values.contains { operation in
      switch operation {
      case .start, .switchTo: true
      case .stopForEnd, .userStart: false
      }
    }
  }

  /// A known different browser room or native app run withdraws the obsolete question.
  /// A new question still waits for fresh eligibility, readiness and the global display interval.
  /// The original episode survives microphone uncertainty until independently confirmed over.
  private mutating func withdrawMovedQuestion(_ c: Context) {
    let e: Int
    switch interaction {
    case .ask(let id, _, _), .switchCall(let id, _, _, _): e = id
    default: return
    }
    guard isFresh(c), let episode = episode(e) else { return }
    if Self.isNative(episode.rule) {
      guard let owner = episode.owner else { return }
      let replacements = members(of: episode).filter { $0.input == .active }
        .compactMap { attribution(for: $0, c).1?.owner }
      if !replacements.isEmpty, !replacements.contains(owner) { set(.none) }
      return
    }
    var shown: [(CallAppFamily, String)] = []
    for holder in members(of: episode) where holder.input == .active {
      guard case .call(let family, let room)? = holder.evidence else { return }
      shown.append((family, room))
    }
    guard !shown.isEmpty, !shown.contains(where: { $0 == episode.family && $1 == episode.room })
    else { return }
    set(.none)
  }

  private mutating func set(_ new: Interaction) {
    guard new != interaction else { return }
    switch new {
    case .ask(_, _, let since), .switchCall(_, _, _, let since): lastQuestionShownAt = since
    default: break
    }
    interaction = new
    token += 1
    claimedToken = nil
  }

  /// A tip or a "could not start" never covers a question or a countdown (review r8 F2).
  private mutating func showNote(_ note: Note, _ c: Context) {
    switch interaction {
    case .ask, .switchCall, .countdown: return
    default: set(.note(note, until: c.now.addingTimeInterval(Self.noteTimeout)))
    }
  }

  private mutating func newID() -> Int {
    defer { nextID += 1 }
    return nextID
  }

  private func episode(_ id: Int) -> Episode? { episodes.first { $0.id == id } }

  private mutating func setPhase(_ id: Int, _ phase: Episode.Phase) {
    guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
    episodes[index].phase = phase
    episodes[index].endedWhileStarting = false
    resetEnd(index)
  }

  private mutating func remove(episode id: Int) {
    episodes.removeAll { $0.id == id }
    withdrawOrphanQuestion()
  }

  /// A question whose call ended or was switched off goes away: not a No, not a timeout.
  private mutating func withdrawOrphanQuestion() {
    switch interaction {
    case .ask(let e, _, _), .switchCall(let e, _, _, _), .countdown(let e, _):
      if episode(e) == nil { set(.none) }
    default: break
    }
  }
}
