import EnviousWisprCore
import Foundation

/// What EnviousMeet does about calls (#4012 §3.4, D1-D10): pure rules over what the watcher and
/// the evidence reader observed, with an injected clock. It decides; `CallDetectionCoordinator`
/// carries the decisions out. No system calls here, so every rule is tested directly.
///
/// Two owners, nothing else (`docs/audits/2026-10-24-4012-leak-enumeration.md`):
/// - **Episodes.** A call is an `Episode` with its own id. It begins only from known positive
///   start evidence in a complete reading. Two inputs can confirm its end: independently
///   attributed, fresh call-ended observations, or (#4249, reversing #4142 by founder decision)
///   a confirmed microphone release by the episode's own verified app run.
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
    /// #4232: the call panel's own Start recording asked for it (on the menu route), so it is
    /// no menu-bar start and gets no start card.
    package let fromCallPanel: Bool

    package init(
      generation: Int, route: MeetingEntryPoint, acceptedAt: Date, fromCallPanel: Bool = false
    ) {
      self.generation = generation
      self.route = route
      self.acceptedAt = acceptedAt
      self.fromCallPanel = fromCallPanel
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
      self.init(
        sequence: sequence, takenAt: takenAt, complete: complete, holders: holders,
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
    /// #4249: when the recording's call-track live words last advanced; nil when live words
    /// do not run on that track. Only holds a microphone-release countdown; never proves silence.
    public var callWordsAt: Date?
    /// #4249: when the current meeting recording began, for the minimum recording age before a
    /// microphone release can start the countdown. Nil falls back to when the call was linked.
    public var recordingSince: Date?
    /// #4249 silence backstop: when any track's live words last advanced (or first appeared),
    /// nil while none were heard; and whether the live words run without reported drops.
    public var anyWordsAt: Date?
    public var wordsHealthy: Bool

    public init(
      now: Date, meeting: Meeting, dictationActive: Bool = false, mode: Mode = .ask,
      appsOff: Set<String> = [], setUp: Bool = true, startBlocked: Bool = false,
      firstTipShown: Bool = false, noCounts: [String: Int] = [:], callWordsAt: Date? = nil,
      recordingSince: Date? = nil, anyWordsAt: Date? = nil, wordsHealthy: Bool = false
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
      self.callWordsAt = callWordsAt
      self.recordingSince = recordingSince
      self.anyWordsAt = anyWordsAt
      self.wordsHealthy = wordsHealthy
    }
  }

  public enum Note: Sendable, Equatable {
    case firstTip
    /// D6: the third No for the switch `rule` belongs to.
    case lastTip(rule: CallAppCatalog.Rule, family: CallAppFamily)
    case needsAttention
    case couldNotStart
  }

  /// What the panel shows.
  public enum Interaction: Sendable, Equatable {
    case none
    /// D1 Ask: "Record this call?"
    case ask(episode: Int, family: CallAppFamily, since: Date)
    /// D10: a new call while `from` records.
    case switchCall(episode: Int, family: CallAppFamily, from: UUID, since: Date)
    /// D3, #4232, #4249: "Recording stops in N seconds" with End recording and Keep recording.
    /// A call that comes back cancels it; Keep is restored because a microphone release can also
    /// happen inside a live call (Leave computer audio, a slow device switch).
    case countdown(episode: Int, deadline: Date)
    /// A browser page ended, but the recording continues until explicit consent.
    case endConfirmation(episode: Int, family: CallAppFamily)
    /// A switch stopped the old recording, but the new call could not be confirmed: the user's
    /// own Start is offered, never a silent nothing (review r16 F1, r18 F3).
    case switchNotConfirmed(family: CallAppFamily, until: Date)
    case note(Note, until: Date)
    /// #4249 silence backstop (Wispr Flow `tickSilence`): "Still in a meeting?" after 10 healthy
    /// minutes with no new words; with no answer the meeting stops at `deadline`.
    case stillInMeeting(meetingID: UUID, deadline: Date)
  }

  public enum Button: String, Sendable, CaseIterable {
    case yes, no, close, keepRecording, stopRecording, endRecording, startNewRecording, openSettings
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
    /// The user's own Start (Start recording on the failed-switch card): the manual route.
    case startByUser(operation: Int, family: CallAppFamily)
    /// Stop `meetingID` if it is still the meeting recording; `.stopFinished(operation:)`
    /// follows either way. `reason` is the route that stopped it (#4249, `meeting.ended`).
    case stop(operation: Int, meetingID: UUID, reason: MeetingEndedTelemetry.StopReason)
    case emit(family: CallAppFamily, answer: MeetingCallPromptTelemetry.Answer)
    case countNo(switchID: String)
    case markFirstTipShown
    case openMeetingPage
    /// #4232: the call flow stopped `meetingID` (countdown, End recording, Stop recording); the
    /// panel follows its notes. The coordinator holds the attempt it froze for that stop. Nil
    /// family: the silence backstop stopped a recording with no call (#4249).
    case followNotes(meetingID: UUID, family: CallAppFamily?)
  }

  // Independent call-end confirmation retains the established 1.5 s minimum and two reads.
  // Consent questions have their own approved readiness, lifetime and global display clocks.
  public static let endConfirm: TimeInterval = 1.5
  public static let endReadingsRequired = 2
  public static let wakeHoldoff: TimeInterval = 10
  public static let countdownLength: TimeInterval = 10
  /// #4249: the call app's microphone release starts the countdown after this much continuous
  /// release, confirmed by a later microphone reading (Wispr Flow `absenceConfirmMs:1500`,
  /// the same value as `endConfirm`).
  public static let releaseConfirm: TimeInterval = 1.5
  /// #4249: call-track words newer than this hold the release countdown (Wispr Flow `graceMs:5e3`).
  public static let farSideQuiet: TimeInterval = 5
  /// #4249: the far-side hold ends this long after the release began (Wispr Flow `C3=25e3`).
  public static let farSideHoldCap: TimeInterval = 25
  /// #4249: a release in a recording's first seconds (waiting room, joining audio) never starts
  /// the countdown before this age (Wispr Flow `minSessionAgeMs:15e3`).
  public static let minRecordingAge: TimeInterval = 15
  /// #4249 silence backstop, copied from Wispr Flow `tickSilence`: ask after this much healthy
  /// time with no new words (`6e5`), answer within `silenceAnswer` (`oG=3e4`, default end), and
  /// count at most `silenceTickCap` per step (`maxGapMs 2e3`, so sleep never counts).
  public static let silenceAsk: TimeInterval = 600
  public static let silenceAnswer: TimeInterval = 30
  public static let silenceTickCap: TimeInterval = 2
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
      /// Already offered. A new idle Ask needs a fresh microphone opportunity (#4142 G1),
      /// not a new recording owner or an invented logical-call identity.
      case offered
      /// A start (or a switch's stop and start) is running.
      case starting(operation: Int)
      case recording(meetingID: UUID)
      /// The meeting is the user's; this call's end never stops it. Only non-card overrides
      /// produce it (an app switched off while recording). Card Keep re-arms instead (#4249).
      case kept(meetingID: UUID)
      case ending(meetingID: UUID, deadline: Date)
      case confirmingEnd(meetingID: UUID)
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
    /// A manual Stop, an app switched off or a superseded stop cannot become another automatic
    /// ownership link. Card Keep never sets it (#4249: it re-arms on the next release).
    var ownershipOverridden = false
    var phase: Phase
    /// Confirmed over while its Start ran: the Start is no longer wanted.
    var endedWhileStarting = false
    var endSince: Date?
    var endReadings = 0
    var lastEndedReadAt: Date?
    var lastObservationID = 0
    /// #4249 microphone-release end. Release tracking arms only on an active reading strictly
    /// newer than `armBoundary` (the reading at link or at the last card Keep).
    var armBoundary = 0
    var releaseArmed = false
    /// First released reading's time and sequence; a later reading must confirm the interval.
    var releaseSince: Date?
    var releaseFirstSequence: Int?
    /// When this episode was linked to its recording (fallback for `Context.recordingSince`).
    var linkedAt: Date?
    /// A card Keep blocks both automatic end paths until a new active-then-release cycle.
    var keptUntilRearm = false
    /// What started the current countdown.
    var endOrigin: EndOrigin?
    var countdownStartedAt: Date?
    /// A release countdown paused by far-side words keeps its remaining time here (#4249).
    var pausedRemaining: TimeInterval?
    /// A window-origin countdown saw the app release the microphone; taking it back cancels.
    /// (#4142: input can stay on after a real call end, so active input alone does not.)
    var releasedDuringWindowCountdown = false
  }

  enum EndOrigin: Sendable, Equatable { case release, window }

  private enum ReleaseState { case active, released, unknown }

  enum Operation: Sendable, Equatable {
    case start(episode: Int, family: CallAppFamily, byItself: Bool)
    /// D10 Yes: stop `from`, then start the episode.
    case switchTo(episode: Int, family: CallAppFamily, from: UUID)
    case stopForEnd(episode: Int, family: CallAppFamily, meetingID: UUID)
    case stopAfterConfirmation(episode: Int, family: CallAppFamily, meetingID: UUID)
    case userStart
    /// #4249: the silence backstop's stop; no call episode needed.
    case stopForSilence(meetingID: UUID)
  }

  public private(set) var interaction: Interaction = .none
  /// Changes every time `interaction` does, except across a release countdown's far-side pause
  /// and resume (#4249, `setKeepingToken`).
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
  private var lastQuestionReadingSequence: Int?
  private var lastQuestionAppCount: Int?
  private var questionOpportunityAt: Date?
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
  /// #4342: the running recording was started by hand (menu bar or History). Kept apart from the
  /// frozen call, so a start whose frozen call was dropped or refused can still follow a live call.
  private struct HandStart {
    let recordingID: UUID
    let route: MeetingEntryPoint
    let generation: Int
  }
  private var handStart: HandStart?
  /// #4342: a hand-started recording linked to a call after its start. The coordinator drains it
  /// once to show the start card and log the link.
  package struct LaterLink: Sendable, Equatable {
    package let recordingID: UUID
    package let episode: Int
    package let route: MeetingEntryPoint
    package let generation: Int
  }
  private var laterLinks: [LaterLink] = []
  /// #4249 silence backstop state for the current recording (Wispr Flow `silenceAccruedMs`).
  private struct Silence {
    let meetingID: UUID
    var accrued: TimeInterval = 0
    var lastStepAt: Date?
    var lastWordsAt: Date?
  }
  private var silence: Silence?
  /// #4249: per recording, what `meeting.ended` reports about its call (link, last countdown
  /// trigger, Keep presses). Read by the coordinator; bounded to the newest few recordings.
  package struct CallFacts: Sendable, Equatable {
    package var link: MeetingEndedTelemetry.CallLink?
    package var endTrigger: MeetingEndedTelemetry.EndTrigger?
    package var keepCount = 0
  }
  private var callFacts: [UUID: CallFacts] = [:]
  private var callFactsOrder: [UUID] = []

  package func callFacts(for meetingID: UUID) -> CallFacts { callFacts[meetingID] ?? CallFacts() }

  private mutating func updateFacts(_ meetingID: UUID, _ change: (inout CallFacts) -> Void) {
    if callFacts[meetingID] == nil {
      callFactsOrder.append(meetingID)
      if callFactsOrder.count > 8 { callFacts[callFactsOrder.removeFirst()] = nil }
    }
    var facts = callFacts[meetingID] ?? CallFacts()
    change(&facts)
    callFacts[meetingID] = facts
  }
  private var latestAcceptedGeneration = 0

  /// #4249: why a hand-started recording (menu bar or History) was or was not linked to a call,
  /// so a call whose end never stopped such a recording can be diagnosed from `app.log`. Closed
  /// values only: each names the one check that decided. Diagnostics only; nothing reads it to
  /// decide anything.
  package enum ManualLinkReason: String, Sendable, Equatable {
    // At acceptance (the call is frozen here or never).
    case notReady = "not_ready"
    case noCall = "no_call"
    case severalCalls = "several_calls"
    case noSource = "no_source"
    case noEvidence = "no_evidence"
    case staleEvidence = "stale_evidence"
    case otherAppRun = "other_app_run"
    case callEnded = "call_ended"
    case evidenceUnknown = "evidence_unknown"
    case candidate
    // At settlement (the frozen call is only checked for invalidation).
    case superseded
    /// The pending start was cleared before it finished (wake, call detection switched off, a
    /// replaced read lifetime), so its frozen call was dropped.
    case invalidated
    case notStarted = "not_started"
    case alreadyDecided = "already_decided"
    case meetingChanged = "meeting_changed"
    case appOff = "app_off"
    case episodeGone = "episode_gone"
    case overridden
    case callChanged = "call_changed"
    case noEvidenceAtSettle = "no_evidence_at_settle"
    case staleAtSettle = "stale_at_settle"
    case otherAppRunAtSettle = "other_app_run_at_settle"
    case sourceNotFrozen = "source_not_frozen"
    case endedAtSettle = "ended_at_settle"
    case otherCall = "other_call"
    case phaseClosed = "phase_closed"
    /// #4342: another call also had fresh live evidence at settlement; the start links later
    /// only once one call is left.
    case severalCallsAtSettle = "several_calls_at_settle"
    case linked
    /// #4342: linked to a call after its start by `followHandStart`.
    case linkedLater = "linked_later"
  }

  /// The latest hand start's decision, keyed by its acceptance generation.
  package private(set) var manualLink: (generation: Int, reason: ManualLinkReason)?

  public init() {}

  /// #4342: later links made since the last drain, each returned once.
  package mutating func drainLaterLinks() -> [LaterLink] {
    defer { laterLinks = [] }
    return laterLinks
  }

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

  private func refreshTarget(episode id: Int, reference: RefreshTarget.Reference) -> RefreshTarget?
  {
    guard let episode = episodes.first(where: { $0.id == id }) else { return nil }
    return .init(
      reference: reference, episode: id, rule: episode.rule,
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
    if case .endConfirmation = interaction {
      token += 1
      claimedToken = nil
    }
    questionOpportunityAt = nil
    holdoffUntil = now.addingTimeInterval(Self.wakeHoldoff)
    let consumed = reading?.continuity.map(\.id).max() ?? 0
    for index in episodes.indices {
      episodes[index].lastObservationID = max(episodes[index].lastObservationID, consumed)
      resetEnd(index)
      clearRelease(index)
    }
  }

  /// #4249: one content-free line saying what the call rules see now, so `app.log` can explain why
  /// a call's end did or did not start the countdown. Only words for states and small counts: no
  /// room, title, URL, bundle or process id. The coordinator writes it when it changes.
  public func diagnosticLine(_ c: Context) -> String {
    var parts: [String] = ["meeting=\(Self.word(c.meeting))", "mode=\(c.mode.rawValue)"]
    if let reading {
      let age = max(0, Int(c.now.timeIntervalSince(reading.takenAt) * 1000))
      parts.append(
        "reading=\(reading.complete ? "complete" : "partial") age_ms=\(age) holders=\(reading.holders.count)"
          + " mic_on=\(reading.holders.filter { $0.input == .active }.count)"
          + " mic_unknown=\(reading.holders.filter { $0.input == .unknown }.count)"
          + " ambiguous=\(reading.ambiguous)")
    } else {
      parts.append("reading=none")
    }
    parts.append("interaction=\(Self.word(interaction))")
    if inHoldoff(c) { parts.append("holdoff=on") }
    for episode in episodes {
      let applicable = (reading?.continuity ?? []).filter { state($0, for: episode) != nil }
      let latest = applicable.max { $0.id < $1.id }
      var view = "none"
      // `trackEnds` lets any fresh ongoing observation block an end, so it wins over a newer ended one.
      let anyFreshOngoing = applicable.contains { observation in
        guard fresh(observation, c), case .ongoing? = state(observation, for: episode) else {
          return false
        }
        return true
      }
      if anyFreshOngoing {
        view = "ongoing"
      } else if let latest {
        let value: String
        switch state(latest, for: episode) {
        case .ongoing?: value = "ongoing"
        case .ended?: value = "ended"
        default: value = "unknown"
        }
        view = "\(value)\(fresh(latest, c) ? "" : "_stale")"
      }
      let live = members(of: episode).contains { $0.input == .active }
      parts.append(
        "episode=\(episode.id) app=\(episode.family.rawValue) phase=\(Self.word(episode.phase))"
          + " native=\(Self.isNative(episode.rule)) owner=\(episode.owner != nil ? "known" : "none")"
          + " evidence=\(view) observations=\(applicable.count) mic_on=\(live)"
          + " end_reads=\(episode.endReadings)/\(Self.endReadingsRequired)"
          + " release=\(Self.releaseWord(episode))")
    }
    return parts.joined(separator: " ")
  }

  /// #4249: the microphone-release state in one word: counting (a release countdown runs),
  /// held (a release is seen but waits: confirmation, age, far side, or a paused countdown),
  /// armed (the app used the microphone since the link or the last Keep), none.
  private static func releaseWord(_ episode: Episode) -> String {
    if case .ending = episode.phase, episode.endOrigin == .release {
      return episode.pausedRemaining == nil ? "counting" : "held"
    }
    if episode.releaseSince != nil { return "held" }
    return episode.releaseArmed ? "armed" : "none"
  }

  private static func word(_ meeting: Meeting) -> String {
    switch meeting {
    case .idle: "idle"
    case .busy: "busy"
    case .recording: "recording"
    }
  }

  private static func word(_ interaction: Interaction) -> String {
    switch interaction {
    case .none: "none"
    case .ask: "ask"
    case .switchCall: "switch"
    case .countdown: "countdown"
    case .endConfirmation: "end_confirmation"
    case .switchNotConfirmed: "switch_not_confirmed"
    case .note: "note"
    case .stillInMeeting: "still_in_meeting"
    }
  }

  private static func word(_ phase: Episode.Phase) -> String {
    switch phase {
    case .waiting: "waiting"
    case .offered: "offered"
    case .starting: "starting"
    case .recording: "recording"
    case .kept: "kept"
    case .ending: "ending"
    case .confirmingEnd: "confirming_end"
    case .stopping: "stopping"
    }
  }

  /// The rules for this moment: ends, timeouts, new calls, questions.
  public mutating func step(_ c: Context) -> [Command] {
    var out: [Command] = []
    // #4342: provenance lives exactly as long as its recording, also across Off.
    if let hand = handStart, c.meeting != .recording(meetingID: hand.recordingID) {
      handStart = nil
    }
    guard c.setUp, c.mode != .off else {
      // Nothing is watched while off, so what is known about calls is out of date: when
      // watching resumes, every call is a new one. A running recording goes on as the user's.
      episodes = []
      pendingManual = nil
      questionOpportunityAt = nil
      lastQuestionAppCount = nil
      if let sequence = reading?.sequence {
        lastQuestionReadingSequence = max(lastQuestionReadingSequence ?? sequence, sequence)
      }
      if case .recording(let id) = c.meeting { association = .rejected(id) }
      // Wispr Flow `tickSilence` with auto-end off: the silence count starts over (#4249).
      silence = nil
      set(.none)
      return out
    }
    followMeeting(c)
    expire(c, &out)
    trackEnds(c, &out)
    noticeCalls(c)
    // After discovery, so a call that just appeared can take the recording (#4342).
    followHandStart(c)
    // After owner and helper adoption, so release judges the episode's current sources.
    trackReleases(c)
    expireEndings(c, &out)
    trackSilence(c, &out)
    noticeQuestionOpportunity(c)
    offer(c, &out)
    offerEndConfirmation(c)
    return out
  }

  /// Freeze existing provenance synchronously at Flow acceptance; no later discovery can
  /// turn a rejected request into a candidate. This observer never starts or renames a meeting.
  package mutating func acceptedStart(_ request: AcceptedStart, _ c: Context) -> [Command] {
    guard request.generation > latestAcceptedGeneration else { return [] }
    latestAcceptedGeneration = request.generation
    questionOpportunityAt = nil
    pendingManual = nil
    guard request.route == .menu || request.route == .history else { return [] }
    // A newer user request retires the old Switch answer, even if this request cannot start.
    for (id, operation) in operations {
      guard case .switchTo(let e, _, _) = operation else { continue }
      operations[id] = nil
      if startingOperation == id { startingOperation = nil }
      if episode(e)?.phase == .starting(operation: id) { setPhase(e, .offered) }
    }
    guard c.setUp, c.mode != .off, c.meeting == .idle, request.acceptedAt <= c.now
    else {
      manualLink = (request.generation, .notReady)
      return []
    }
    followMeeting(c)
    func plausibleCalls(countingOverridden: Bool) -> [Episode] {
      episodes.filter { episode in
        guard !inHoldoff(c), episode.establishedAt <= request.acceptedAt, episode.owner != nil,
          countingOverridden || !episode.ownershipOverridden,
          !c.appsOff.contains(CallAppCatalog.switchID(for: episode.rule))
        else { return false }
        switch episode.phase {
        case .waiting, .offered: break
        default: return false
        }
        let ongoing = (reading?.continuity ?? []).contains {
          guard $0.completedAt <= request.acceptedAt, fresh($0, c) else { return false }
          if case .ongoing? = state($0, for: episode) { return true }
          return false
        }
        return ongoing || isKnownLive(episode, c)
      }
    }
    let plausible = plausibleCalls(countingOverridden: false)
    var candidate: ManualCandidate?
    // Same conditions as before #4249, checked one at a time so the deciding one is named.
    let reason: ManualLinkReason
    if plausible.isEmpty {
      // Diagnostics only: a call left out solely because the user stopped its earlier
      // recording by hand is named, since that is by design and no defect.
      reason = plausibleCalls(countingOverridden: true).isEmpty ? .noCall : .overridden
    } else if plausible.count > 1 {
      reason = .severalCalls
    } else if let episode = plausible.first, let owner = episode.owner, !episode.sources.isEmpty {
      if let latest = reading?.continuity.filter({ state($0, for: episode) != nil })
        .max(by: { $0.id < $1.id })
      {
        if latest.completedAt > request.acceptedAt || !fresh(latest, c) {
          reason = .staleEvidence
        } else if latest.owner != owner {
          reason = .otherAppRun
        } else {
          switch state(latest, for: episode) {
          case .ongoing?:
            reason = .candidate
          case .unknown?:
            reason =
              Self.isNative(episode.rule) && isKnownLive(episode, c) ? .candidate : .evidenceUnknown
          case .ended?, nil:
            reason = .callEnded
          }
          if reason == .candidate {
            candidate = .init(
              episode: episode.id, owner: owner, sources: episode.sources,
              room: episode.room, family: episode.family, rule: episode.rule)
          }
        }
      } else {
        reason = .noEvidence
      }
    } else {
      reason = .noSource
    }
    manualLink = (request.generation, reason)
    pendingManual = .init(request: request, candidate: candidate)
    // A user-accepted recording is already starting; an old consent question cannot start it
    // again. Keep its offered suppression and invalidate its button token immediately.
    switch interaction {
    case .ask, .switchCall: set(.none)
    default: break
    }
    return []
  }

  /// #4232: what a card needs to show a call's app: its family, rule and owning app run.
  package struct CallIdentity: Sendable, Equatable {
    package let family: CallAppFamily
    package let rule: CallAppCatalog.Rule
    package let owner: CallEvidenceReader.AppRun?
  }

  /// The call an episode tracks, while it is known.
  package func call(episode id: Int) -> CallIdentity? {
    episode(id).map { CallIdentity(family: $0.family, rule: $0.rule, owner: $0.owner) }
  }

  /// The call a hand-started recording was linked to by `settledStart`, for its start card. Nil
  /// when the start matched no single call (the card then names the microphone).
  package func linkedCall(_ recordingID: UUID) -> CallIdentity? {
    guard case .linked(recordingID, let e)? = association else { return nil }
    return call(episode: e)
  }

  /// A replaced read lifetime cannot carry a historical in-flight ticket into its successor.
  package mutating func invalidateAcceptedStart() {
    pendingManual = nil
  }

  package mutating func settledStart(
    _ request: AcceptedStart, recordingID: UUID?, _ c: Context
  ) -> [Command] {
    // #4249: each refusal names itself in `manualLink`. The checks and their order are the same
    // as before; they are split only so the deciding one is known.
    func refuse(_ reason: ManualLinkReason) -> [Command] {
      manualLink = (request.generation, reason)
      return []
    }
    guard let pending = pendingManual, pending.request == request,
      request.generation == latestAcceptedGeneration
    else {
      // A request refused at acceptance keeps that reason; a hand start that was replaced says
      // so. A detected call's own start never had a manual decision.
      if request.route == .menu || request.route == .history {
        if manualLink?.generation != request.generation {
          manualLink = (request.generation, .superseded)
        } else if manualLink?.reason == .candidate {
          manualLink = (request.generation, .invalidated)
        }
        // #4342: a successful hand start whose frozen call was dropped still follows a live
        // call. A superseded completion (older generation) never does.
        if request.generation == latestAcceptedGeneration, let recordingID,
          c.meeting == .recording(meetingID: recordingID), association?.recordingID != recordingID
        {
          association = .rejected(recordingID)
          handStart = .init(
            recordingID: recordingID, route: request.route, generation: request.generation)
        }
      }
      return []
    }
    pendingManual = nil
    guard let recordingID else { return refuse(.notStarted) }
    // #4249: the hand start's link outcome, decided by the checks below.
    defer {
      let outcome: MeetingEndedTelemetry.CallLink =
        switch manualLink?.reason {
        case .linked?: .manual
        case .noCall?: .noCall
        default: .unlinked
        }
      updateFacts(recordingID) { $0.link = $0.link ?? outcome }
    }
    guard association?.recordingID != recordingID else { return refuse(.alreadyDecided) }
    association = .rejected(recordingID)
    guard c.setUp, c.mode != .off, c.meeting == .recording(meetingID: recordingID) else {
      return refuse(.meetingChanged)
    }
    if request.route == .menu || request.route == .history {
      handStart = .init(
        recordingID: recordingID, route: request.route, generation: request.generation)
    }
    // No frozen call: the acceptance reason already says why.
    guard let frozen = pending.candidate else { return [] }
    guard !c.appsOff.contains(CallAppCatalog.switchID(for: frozen.rule)) else {
      return refuse(.appOff)
    }
    guard let index = episodes.firstIndex(where: { $0.id == frozen.episode }) else {
      return refuse(.episodeGone)
    }
    guard !episodes[index].ownershipOverridden else { return refuse(.overridden) }
    guard episodes[index].owner == frozen.owner, episodes[index].sources == frozen.sources,
      episodes[index].room == frozen.room, episodes[index].family == frozen.family,
      episodes[index].rule == frozen.rule
    else { return refuse(.callChanged) }
    guard
      let latest = reading?.continuity.filter({ state($0, for: episodes[index]) != nil })
        .max(by: { $0.id < $1.id })
    else { return refuse(.noEvidenceAtSettle) }
    guard fresh(latest, c) else { return refuse(.staleAtSettle) }
    guard latest.owner == frozen.owner else { return refuse(.otherAppRunAtSettle) }
    // #4342: one verified app run reads as several processes, and the newest observation is
    // often a sibling the frozen call never listed. The frozen call still needs a fresh
    // observation of its own; the newest one keeps deciding ended and other-call below.
    let frozenSourceSeen = (reading?.continuity ?? []).contains {
      frozen.sources.contains($0.source) && $0.owner == frozen.owner && fresh($0, c)
        && state($0, for: episodes[index]) != nil
    }
    guard frozenSourceSeen else { return refuse(.sourceNotFrozen) }
    if Self.isNative(frozen.rule) {
      if case .ended? = state(latest, for: episodes[index]) { return refuse(.endedAtSettle) }
    } else if case .ended(let family, let room) = latest.value {
      guard family == frozen.family, room == frozen.room else { return refuse(.otherCall) }
    }
    if case .ongoing(let family, let room) = latest.value,
      family != frozen.family || (!Self.isNative(frozen.rule) && room != frozen.room)
    {
      return refuse(.otherCall)
    }
    // Historical eligibility is not recomputed here; only the frozen episode/run/source/room
    // is checked for invalidation. Another candidate cannot replace it at completion.
    switch episodes[index].phase {
    case .waiting, .offered: break
    default: return refuse(.phaseClosed)
    }
    guard ambiguityPopulation(c).allSatisfy({ $0 == frozen.episode }) else {
      return refuse(.severalCallsAtSettle)
    }
    linkRecording(frozen.episode, recordingID, c)
    association = .linked(recordingID, episode: frozen.episode)
    manualLink = (request.generation, .linked)
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
    case .stopForEnd, .stopAfterConfirmation, .userStart, .stopForSilence: return false
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
    guard let reading,
      let source = reading.sources.first(where: { $0.pid == holder.pid && $0.rule == holder.rule })
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
  private func state(_ observation: ContinuityObservation, for episode: Episode)
    -> CallEvidenceReader.Continuity?
  {
    guard observation.source.rule == episode.rule else { return nil }
    if let target = observation.retainedTarget {
      guard target.family == episode.family, target.owner == episode.owner,
        Self.isNative(episode.rule) || target.room == episode.room
      else { return nil }
    } else {
      let sameOwner = episode.owner != nil && observation.owner == episode.owner
      guard sameOwner || episode.sources.contains(observation.source) else { return nil }
    }
    guard let owner = episode.owner, observation.owner == owner else { return .unknown }
    switch observation.value {
    case .ongoing(let family, let room), .ended(let family, let room):
      guard family == episode.family, Self.isNative(episode.rule) || room == episode.room else {
        return .unknown
      }
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
      guard family == episode.family && (Self.isNative(episode.rule) || room == episode.room) else {
        return false
      }
      if let owner = episode.owner {
        guard attribution(for: holder, c).1?.owner == owner else { return false }
      }
      if let latest = reading?.continuity.filter({ state($0, for: episode) != nil }).max(by: {
        $0.id < $1.id
      }),
        fresh(latest, c), latest.beganAt >= episode.establishedAt,
        case .ended? = state(latest, for: episode)
      {
        return false
      }
      return true
    }
  }

  /// #4342: calls with fresh positive evidence now, counted before any per-call veto. Overridden
  /// calls and each browser room count, and positive evidence for one room never hides another.
  /// More than one means no hand-started recording links.
  private func ambiguityPopulation(_ c: Context) -> [Int] {
    episodes.filter { episode in
      guard episode.owner != nil,
        !c.appsOff.contains(CallAppCatalog.switchID(for: episode.rule))
      else { return false }
      switch episode.phase {
      case .waiting, .offered: break
      default: return false
      }
      let observedOngoing = (reading?.continuity ?? []).contains { observation in
        guard fresh(observation, c), case .ongoing? = state(observation, for: episode) else {
          return false
        }
        return true
      }
      if observedOngoing { return true }
      guard isFresh(c) else { return false }
      return members(of: episode).contains { holder in
        guard holder.input == .active,
          let (family, room) = Self.admittedCall(holder.evidence, mode: c.mode),
          family == episode.family, Self.isNative(episode.rule) || room == episode.room
        else { return false }
        return attribution(for: holder, c).1?.owner == episode.owner
      }
    }.map(\.id)
  }

  /// #4342 (D1-D3): a recording started by hand that no call has taken follows the one live call
  /// at any point while it records: an early start the settle check refused, a call joined
  /// later, or the same call after a hand Stop. Two or more live calls link nothing.
  private mutating func followHandStart(_ c: Context) {
    guard let hand = handStart, c.meeting == .recording(meetingID: hand.recordingID),
      case .rejected(let rejectedID)? = association, rejectedID == hand.recordingID,
      pendingManual == nil, !inHoldoff(c), isFresh(c), startingOperation == nil, !startInFlight
    else { return }
    let m = hand.recordingID
    guard !operations.values.contains(where: { Self.operation($0, affects: m) }),
      !episodes.contains(where: { Self.phase($0.phase, holds: m) })
    else { return }
    let population = ambiguityPopulation(c)
    guard population.count == 1, let e = population.first,
      let index = episodes.firstIndex(where: { $0.id == e }), canFollow(episodes[index], c)
    else { return }
    linkRecording(e, m, c)
    association = .linked(m, episode: e)
    // The settle-time outcome (no_call/unlinked) is replaced: the recording is now linked.
    updateFacts(m) { $0.link = .manual }
    switch interaction {
    case .ask(e, _, _), .switchCall(e, _, _, _): set(.none)
    default: break
    }
    laterLinks.append(
      .init(recordingID: m, episode: e, route: hand.route, generation: hand.generation))
  }

  /// The one candidate is live now: a native app holds the microphone for this call; a browser
  /// room's newest applicable observation is a fresh, same-run ongoing one.
  private func canFollow(_ episode: Episode, _ c: Context) -> Bool {
    guard let owner = episode.owner else { return false }
    if Self.isNative(episode.rule) { return isKnownLive(episode, c) }
    guard
      let latest = reading?.continuity.filter({ state($0, for: episode) != nil })
        .max(by: { $0.id < $1.id }),
      fresh(latest, c), latest.owner == owner, case .ongoing? = state(latest, for: episode)
    else { return false }
    return true
  }

  private static func phase(_ phase: Episode.Phase, holds m: UUID) -> Bool {
    switch phase {
    case .recording(let id), .kept(let id), .ending(let id, _), .confirmingEnd(let id): id == m
    case .waiting, .offered, .starting, .stopping: false
    }
  }

  private static func operation(_ operation: Operation, affects m: UUID) -> Bool {
    switch operation {
    case .switchTo(_, _, let from): from == m
    case .stopForEnd(_, _, let id), .stopAfterConfirmation(_, _, let id), .stopForSilence(let id):
      id == m
    case .start, .userStart: false
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
        let automaticRecording: UUID?
        switch episodes[index].phase {
        case .recording(let m), .ending(let m, _), .confirmingEnd(let m): automaticRecording = m
        default: automaticRecording = nil
        }
        if let m = automaticRecording, c.meeting == .recording(meetingID: m),
          c.appsOff.contains(CallAppCatalog.switchID(for: episodes[index].rule))
        {
          episodes[index].phase = .kept(meetingID: m)
          episodes[index].ownershipOverridden = true
          association = .overridden(m)
          switch interaction {
          case .countdown(episodes[index].id, _), .endConfirmation(episodes[index].id, _):
            set(.none)
          default: break
          }
        }
        switch episodes[index].phase {
        case .recording(let m), .kept(let m), .ending(let m, _), .confirmingEnd(let m):
          if c.meeting != .recording(meetingID: m) {
            episodes[index].ownershipOverridden = true
            if case .linked(let linkedID, _)? = association, linkedID == m {
              association = .rejected(m)
            }
            switch interaction {
            case .countdown(episodes[index].id, _), .endConfirmation(episodes[index].id, _):
              set(.none)
            default: break
            }
            episodes[index].phase = .offered
            resetEnd(index)
          }
        case .stopping(let id):
          let original: UUID?
          switch operations[id] {
          case .stopForEnd(_, _, let m)?, .stopAfterConfirmation(_, _, let m)?: original = m
          default: original = nil
          }
          if let original, case .recording(let current) = c.meeting, current != original {
            // A later idle state cannot revive this old completion's presentation authority.
            operations[id] = nil
            episodes[index].phase = .offered
            episodes[index].ownershipOverridden = true
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
    case (.switchNotConfirmed, .recording), (.switchNotConfirmed, .busy):
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
    case .switchNotConfirmed(_, let until) where c.now >= until: set(.none)
    case .note(_, let until) where c.now >= until: set(.none)
    default: break
    }
  }

  /// Clears accumulated window end proof and cancels a running countdown.
  private mutating func resetEnd(_ index: Int) {
    clearEndProof(index)
    cancelCountdown(index)
  }

  private mutating func clearEndProof(_ index: Int) {
    episodes[index].endSince = nil
    episodes[index].endReadings = 0
    episodes[index].lastEndedReadAt = nil
  }

  private mutating func cancelCountdown(_ index: Int) {
    if case .ending(let m, _) = episodes[index].phase {
      episodes[index].phase = .recording(meetingID: m)
      episodes[index].endOrigin = nil
      episodes[index].countdownStartedAt = nil
      episodes[index].pausedRemaining = nil
      episodes[index].releasedDuringWindowCountdown = false
      if case .countdown(episodes[index].id, _) = interaction { set(.none) }
    }
  }

  private mutating func clearRelease(_ index: Int) {
    episodes[index].releaseSince = nil
    episodes[index].releaseFirstSequence = nil
  }

  /// #4249: link admission (and a card Keep) sets the boundary a newer active reading must cross.
  private mutating func disarmRelease(_ index: Int) {
    episodes[index].armBoundary = reading?.sequence ?? 0
    episodes[index].releaseArmed = false
    clearRelease(index)
  }

  private mutating func linkRecording(_ e: Int, _ m: UUID, _ c: Context) {
    setPhase(e, .recording(meetingID: m))
    guard let index = episodes.firstIndex(where: { $0.id == e }) else { return }
    disarmRelease(index)
    episodes[index].keptUntilRearm = false
    episodes[index].linkedAt = c.now
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
      if ongoing, case .confirmingEnd(let m) = episodes[index].phase {
        episodes[index].phase = .recording(meetingID: m)
        if case .endConfirmation(episodes[index].id, _) = interaction { set(.none) }
      }
      // #4249: a release countdown is not window proof, so missing, unknown or stale window
      // evidence only clears window proof; fresh ongoing evidence still cancels it.
      let releaseCountdown = episodes[index].endOrigin == .release && !ongoing
      guard !ongoing, let latest = applicable.last, fresh(latest, c),
        case .ended? = state(latest, for: episodes[index])
      else {
        episodes[index].lastObservationID = max(episodes[index].lastObservationID, latestID)
        if releaseCountdown { clearEndProof(index) } else { resetEnd(index) }
        continue
      }
      for observation in applicable where observation.id > episodes[index].lastObservationID {
        episodes[index].lastObservationID = observation.id
        guard fresh(observation, c), observation.beganAt >= episodes[index].establishedAt,
          case .ended? = state(observation, for: episodes[index])
        else {
          if releaseCountdown { clearEndProof(index) } else { resetEnd(index) }
          continue
        }
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
      case .waiting, .offered:
        // Do not destroy a browser candidate frozen before its manual Start suspended.
        if !Self.isNative(episode.rule), pendingManual?.candidate?.episode == episode.id {
          continue
        }
        ended.append(episode.id)
      case .kept:
        if Self.isNative(episode.rule) { ended.append(episode.id) }
      case .recording(let m):
        // #4249: after a card Keep, window proof waits for a new active-then-release cycle.
        if episode.keptUntilRearm { continue }
        if !Self.isNative(episode.rule) {
          episodes[index].phase = .confirmingEnd(meetingID: m)
          continue
        }
        startCountdown(index, m, origin: .window, c)
      case .ending:
        // The deadline is handled by `expireEndings`, independent of window confirmation.
        continue
      case .starting:
        // Proven native end cancels the running Start. A browser page end cannot prove
        // that the call ended, so its admitted Start remains wanted until settlement.
        if Self.isNative(episode.rule) { episodes[index].endedWhileStarting = true }
      case .confirmingEnd, .stopping:
        break
      }
    }
    for id in ended { remove(episode: id) }
  }

  private mutating func startCountdown(_ index: Int, _ m: UUID, origin: EndOrigin, _ c: Context) {
    updateFacts(m) { $0.endTrigger = origin == .release ? .micRelease : .window }
    let deadline = c.now.addingTimeInterval(Self.countdownLength)
    episodes[index].phase = .ending(meetingID: m, deadline: deadline)
    episodes[index].endOrigin = origin
    episodes[index].countdownStartedAt = c.now
    episodes[index].pausedRemaining = nil
    episodes[index].releasedDuringWindowCountdown = false
    set(.countdown(episode: episodes[index].id, deadline: deadline))
  }

  /// A countdown's deadline stops the meeting, whichever path started it (#4249).
  private mutating func expireEndings(_ c: Context, _ out: inout [Command]) {
    for index in episodes.indices {
      guard case .ending(let m, let deadline) = episodes[index].phase, c.now >= deadline,
        episodes[index].pausedRemaining == nil
      else { continue }
      let episode = episodes[index]
      let id = newID()
      operations[id] = .stopForEnd(episode: episode.id, family: episode.family, meetingID: m)
      episodes[index].phase = .stopping(operation: id)
      if case .countdown(episode.id, _) = interaction { set(.none) }
      out.append(.stop(operation: id, meetingID: m, reason: .callCountdown))
    }
  }

  /// #4249: how this episode's own app run uses the microphone in the current reading. Only a
  /// fresh, complete, unambiguous reading of an owned episode with exact source identity can say
  /// `released`; anything uncertain is `unknown`, which never ends a recording.
  private func releaseState(of episode: Episode, _ c: Context) -> ReleaseState {
    guard isFresh(c), let reading, !reading.ambiguous, let owner = episode.owner,
      !episode.sources.isEmpty
    else { return .unknown }
    // Known activity of the episode's app run wins over any uncertainty elsewhere (§3.2).
    var active = false
    var uncertain = false
    for source in episode.sources {
      // The same process now projected under another source identity: unresolved.
      if reading.sources.contains(where: {
        $0.pid == source.pid && $0.rule == source.rule && $0.id != source.id
      }) {
        uncertain = true
        continue
      }
      // Absent from the complete candidate listing (which lists inactive holders too): released.
      guard
        let holder = reading.holders.first(where: { $0.pid == source.pid && $0.rule == source.rule }
        )
      else { continue }
      switch holder.input {
      case .active: active = true
      case .unknown: uncertain = true
      case .inactive: break
      }
    }
    // Other processes of the same app (helpers, a relaunch) that still use the microphone.
    for holder in members(of: episode) where holder.input != .inactive {
      guard !episode.sources.contains(where: { $0.pid == holder.pid && $0.rule == holder.rule })
      else { continue }
      guard let observedOwner = attribution(for: holder, c).1?.owner else {
        uncertain = true
        continue
      }
      guard observedOwner == owner else { continue }  // another app run says nothing about this call
      if holder.input == .unknown { uncertain = true } else { active = true }
    }
    if active { return .active }
    return uncertain ? .unknown : .released
  }

  /// Fresh window evidence that the call is still going on (the same test `trackEnds` uses).
  private func windowOngoing(_ episode: Episode, _ c: Context) -> Bool {
    (reading?.continuity ?? []).contains { observation in
      guard fresh(observation, c), case .ongoing? = state(observation, for: episode) else {
        return false
      }
      return true
    }
  }

  private func farSideHeld(_ episode: Episode, _ c: Context) -> Bool {
    guard let words = c.callWordsAt, let since = episode.releaseSince else { return false }
    return c.now.timeIntervalSince(words) < Self.farSideQuiet
      && c.now.timeIntervalSince(since) < Self.farSideHoldCap
  }

  /// #4249: the call app releasing the microphone ends a linked recording's call, like every
  /// competitor does; reverses #4142's "inactive input is not end proof" by founder decision
  /// (Gate 1, 2026-11-02). Leave computer audio is the accepted false case; Keep recovers it.
  private mutating func trackReleases(_ c: Context) {
    var questionShown = false
    switch interaction {
    case .ask, .switchCall: questionShown = true
    default: break
    }
    for index in episodes.indices {
      let phase = episodes[index].phase
      let meetingID: UUID
      switch phase {
      case .recording(let m), .confirmingEnd(let m), .ending(let m, _): meetingID = m
      default:
        clearRelease(index)
        continue
      }
      if inHoldoff(c) || questionShown {
        clearRelease(index)
        continue
      }
      guard let reading else { continue }
      let counting: Bool
      if case .ending = phase { counting = true } else { counting = false }
      let state = releaseState(of: episodes[index], c)
      // A window-origin countdown only listens for the app taking the microphone back after
      // releasing it during the countdown (a reacquisition, §3.2).
      if counting, episodes[index].endOrigin != .release {
        if state == .released { episodes[index].releasedDuringWindowCountdown = true }
        if state == .active, episodes[index].releasedDuringWindowCountdown {
          episodes[index].lastObservationID = max(
            episodes[index].lastObservationID, reading.continuity.map(\.id).max() ?? 0)
          resetEnd(index)
        }
        continue
      }
      switch state {
      case .active:
        // The call came back (or never left): a release countdown is cancelled.
        if counting { cancelCountdown(index) }
        clearRelease(index)
        if reading.sequence > episodes[index].armBoundary { episodes[index].releaseArmed = true }
      case .unknown:
        // Unknown never counts toward a release; it does not cancel a running countdown, whose
        // far-side pause still follows the words (a paused countdown must be able to resume).
        if counting {
          pauseOrResume(index, meetingID, held: farSideHeld(episodes[index], c), c)
        } else {
          clearRelease(index)
        }
      case .released:
        guard episodes[index].releaseArmed else { continue }
        // A new active-then-release cycle after a card Keep: window proof may count again.
        episodes[index].keptUntilRearm = false
        if episodes[index].releaseSince == nil {
          episodes[index].releaseSince = reading.takenAt
          episodes[index].releaseFirstSequence = reading.sequence
        }
        let held = farSideHeld(episodes[index], c)
        if counting {
          pauseOrResume(index, meetingID, held: held, c)
          continue
        }
        guard let since = episodes[index].releaseSince,
          let first = episodes[index].releaseFirstSequence, reading.sequence > first,
          reading.takenAt.timeIntervalSince(since) >= Self.releaseConfirm, !held,
          // Fresh window proof that the call goes on (#4142: Leave computer audio keeps the
          // call window) outranks the release, as it cancels a running countdown in `trackEnds`.
          !windowOngoing(episodes[index], c)
        else { continue }
        let recordingStart = c.recordingSince ?? episodes[index].linkedAt ?? c.now
        guard c.now.timeIntervalSince(recordingStart) >= Self.minRecordingAge else { continue }
        clearEndProof(index)
        startCountdown(index, meetingID, origin: .release, c)
      }
    }
  }

  /// #4249 §3.2: far-side words that advance during a release countdown pause it (the card
  /// hides) and keep its remaining time; it resumes with that time when the hold lapses.
  private mutating func pauseOrResume(_ index: Int, _ m: UUID, held: Bool, _ c: Context) {
    guard case .ending(_, let deadline) = episodes[index].phase else { return }
    if let remaining = episodes[index].pausedRemaining {
      guard !held else { return }
      let resumed = c.now.addingTimeInterval(remaining)
      episodes[index].pausedRemaining = nil
      episodes[index].phase = .ending(meetingID: m, deadline: resumed)
      episodes[index].countdownStartedAt = c.now
      // The same countdown continues: same token, so a card hidden with × stays hidden.
      if interaction == .none {
        setKeepingToken(.countdown(episode: episodes[index].id, deadline: resumed))
      }
      return
    }
    guard held, let started = episodes[index].countdownStartedAt, let words = c.callWordsAt,
      words > started
    else { return }
    episodes[index].pausedRemaining = max(0, deadline.timeIntervalSince(c.now))
    if case .countdown(episodes[index].id, _) = interaction { setKeepingToken(.none) }
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
      if let source, owner != nil, !reading.ambiguous {
        // An absent provisional source cannot lend its question or ownerless episode to a
        // verified replacement. Presence (even inactive/unknown) preserves uncertainty;
        // a recording or an operation is never retired by this idle-admission transition.
        let obsolete = episodes.compactMap { episode -> Int? in
          guard episode.owner == nil, episode.rule == holder.rule,
            episode.family == family, episode.room == room,
            !episode.sources.contains(source),
            !episode.sources.contains(where: { reading.sources.contains($0) })
          else { return nil }
          switch episode.phase {
          case .waiting, .offered: return episode.id
          default: return nil
          }
        }
        for id in obsolete { remove(episode: id) }
      }
      if let index = episodes.firstIndex(where: {
        guard $0.rule == holder.rule && $0.family == family && $0.room == room else { return false }
        if let old = $0.owner, let owner { return old == owner }
        return true  // Uncertainty does not split a call or renew an offered question.
      }) {
        if let source, episodes[index].sources.contains(source), episodes[index].owner == nil,
          let owner
        {
          episodes[index].owner = owner
          episodes[index].establishedAt = c.now
          episodes[index].lastObservationID = reading.continuity.map(\.id).max() ?? 0
          resetEnd(index)
        }
        if let source, owner != nil, episodes[index].owner == owner,
          !episodes[index].sources.contains(source)
        {
          episodes[index].sources.append(source)
        }
        continue
      }
      var episode = Episode(
        id: newID(), rule: holder.rule, family: family, room: room,
        noticedAt: min(c.now, reading.takenAt), establishedAt: c.now, phase: .waiting)
      if let source { episode.sources = [source] }
      episode.owner = owner
      episode.lastObservationID = reading.continuity.map(\.id).max() ?? 0
      episodes.append(episode)
    }
  }

  /// Only determinate microphone frames count apps; helper/process and AX changes are not
  /// new opportunities. Recording/end provenance deliberately does not participate.
  private func questionAppCount(_ c: Context) -> Int? {
    guard isFresh(c), let reading, !reading.ambiguous,
      !reading.holders.contains(where: { $0.input == .unknown })
    else { return nil }
    var rules: [CallAppCatalog.Rule] = []
    for holder in reading.holders where holder.input == .active {
      if !rules.contains(holder.rule) { rules.append(holder.rule) }
    }
    return rules.count
  }

  /// Granola-style prompt opportunities are separate from recording episodes (#4142).
  /// Consuming a frame during cooldown/busy never queues a question for later polling.
  private mutating func noticeQuestionOpportunity(_ c: Context) {
    // A user Start can still be in setup while the meeting reports idle. Its operation
    // suppresses idle Ask without changing startInFlight's automatic/Switch contract.
    let userStartPending = operations.values.contains { operation in
      if case .userStart = operation { return true }
      return false
    }
    let suppressed =
      c.mode != .ask || c.meeting != .idle || pendingManual != nil
      || startInFlight || userStartPending || inHoldoff(c)
    if suppressed { questionOpportunityAt = nil }
    guard let reading,
      lastQuestionReadingSequence.map({ reading.sequence > $0 }) ?? true
    else { return }
    lastQuestionReadingSequence = reading.sequence
    guard let count = questionAppCount(c) else { return }
    let changed = lastQuestionAppCount != count
    lastQuestionAppCount = count
    guard changed else { return }
    questionOpportunityAt = nil
    guard count > 0, !suppressed else { return }
    switch interaction {
    case .ask, .switchCall: return
    default: break
    }
    if let lastQuestionShownAt,
      c.now.timeIntervalSince(lastQuestionShownAt) < Self.questionInterval
    {
      return
    }
    questionOpportunityAt = min(c.now, reading.takenAt)
  }

  /// One question at a time; a Yes always answers the call on the panel (review r2 F1).
  private mutating func offer(_ c: Context, _ out: inout [Command]) {
    // #4342 (D3): an unlinked hand-started recording is never asked to Switch. One live call is
    // followed instead (`followHandStart`); two or more ask nothing.
    if let hand = handStart, c.meeting == .recording(meetingID: hand.recordingID),
      case .rejected(let rejectedID)? = association, rejectedID == hand.recordingID
    {
      if case .switchCall(_, _, let from, _) = interaction, from == hand.recordingID { set(.none) }
      return
    }
    switch interaction {
    case .ask, .switchCall: return
    default: break
    }
    guard pendingManual == nil, !inHoldoff(c), !startInFlight else { return }
    let idleAsk = c.mode == .ask && c.meeting == .idle
    for index in episodes.indices {
      switch episodes[index].phase {
      case .waiting: break
      case .offered where idleAsk: break
      default: continue
      }
      let episode = episodes[index]
      guard isKnownLive(episode, c) else { continue }
      // A live replacement call cancels the old countdown even while its question waits (#4275).
      if case .recording = c.meeting {
        for other in episodes.indices { resetEnd(other) }
      }
      let displaysQuestion = c.mode != .startByItself || c.meeting != .idle
      if displaysQuestion {
        let since: Date
        if idleAsk {
          guard let opportunity = questionOpportunityAt, questionAppCount(c) != nil else {
            continue
          }
          since = opportunity
        } else {
          since = episode.noticedAt
        }
        guard c.now.timeIntervalSince(since) >= Self.questionReadiness else { continue }
        if let lastQuestionShownAt,
          c.now.timeIntervalSince(lastQuestionShownAt) < Self.questionInterval
        {
          continue
        }
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
          questionOpportunityAt = nil
          episodes[index].phase = .offered
          set(.ask(episode: episode.id, family: episode.family, since: c.now))
        }
      case .recording(let m):
        episodes[index].phase = .offered
        set(.switchCall(episode: episode.id, family: episode.family, from: m, since: c.now))
      }
      return
    }
  }

  /// Consent belongs to the recording, not the current page or an expiring timer.
  /// A different-call question has presentation priority without erasing this decision.
  private mutating func offerEndConfirmation(_ c: Context) {
    switch interaction {
    case .ask, .switchCall, .countdown: return
    default: break
    }
    for episode in episodes {
      if case .confirmingEnd(let m) = episode.phase, c.meeting == .recording(meetingID: m) {
        set(.endConfirmation(episode: episode.id, family: episode.family))
        return
      }
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
        out.append(.stop(operation: id, meetingID: from, reason: .callSwitch))
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
    case (.ask, .close), (.switchCall, .close), (.switchNotConfirmed, .close),
      (.switchNotConfirmed, .no), (.note, .close):
      // Not now on a failed switch only closes it: no No answer, no refusal count (#4232).
      set(.none)
    case (.endConfirmation(let e, let family), .stopRecording):
      guard let index = episodes.firstIndex(where: { $0.id == e }),
        case .confirmingEnd(let m) = episodes[index].phase,
        c.meeting == .recording(meetingID: m), c.setUp, c.mode != .off,
        !c.appsOff.contains(CallAppCatalog.switchID(for: episodes[index].rule))
      else { return }
      let id = newID()
      operations[id] = .stopAfterConfirmation(episode: e, family: family, meetingID: m)
      episodes[index].phase = .stopping(operation: id)
      set(.none)
      out.append(.stop(operation: id, meetingID: m, reason: .callEndConfirmed))
    case (.endConfirmation(let e, _), .keepRecording), (.endConfirmation(let e, _), .close):
      guard let index = episodes.firstIndex(where: { $0.id == e }),
        case .confirmingEnd(let m) = episodes[index].phase,
        c.meeting == .recording(meetingID: m)
      else { return }
      // x keeps recording here too, but only the Keep button counts as a Keep (#4249 telemetry).
      keepAfterCard(index, m, counted: button == .keepRecording)
    case (.countdown(let e, _), .keepRecording):
      // #4249: restored. The meeting stays linked; the next real release asks again.
      guard let index = episodes.firstIndex(where: { $0.id == e }),
        case .ending(let m, _) = episodes[index].phase, c.meeting == .recording(meetingID: m)
      else { return }
      keepAfterCard(index, m, counted: true)
    case (.countdown(let e, _), .endRecording):
      // #4232: End recording stops now, exactly as the countdown's deadline would.
      guard let index = episodes.firstIndex(where: { $0.id == e }),
        case .ending(let m, _) = episodes[index].phase, c.meeting == .recording(meetingID: m)
      else { return }
      let id = newID()
      operations[id] = .stopForEnd(episode: e, family: episodes[index].family, meetingID: m)
      episodes[index].phase = .stopping(operation: id)
      set(.none)
      out.append(.stop(operation: id, meetingID: m, reason: .callEndButton))
    case (.stillInMeeting(let m, _), .keepRecording):
      guard c.meeting == .recording(meetingID: m) else { return }
      updateFacts(m) { $0.keepCount += 1 }
      silence?.accrued = 0
      set(.none)
    case (.stillInMeeting(let m, _), .endRecording):
      guard c.meeting == .recording(meetingID: m) else { return }
      stopForSilence(m, reason: .silenceEndButton, &out)
    case (.switchNotConfirmed(let family, _), .startNewRecording):
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

  /// #4249: a card Keep keeps the call's link (no permanent `.kept`), consumes the current proof
  /// and blocks both automatic end paths until the app's microphone is active again.
  private mutating func keepAfterCard(_ index: Int, _ m: UUID, counted: Bool) {
    if counted { updateFacts(m) { $0.keepCount += 1 } }
    episodes[index].phase = .recording(meetingID: m)
    episodes[index].endOrigin = nil
    episodes[index].countdownStartedAt = nil
    clearEndProof(index)
    episodes[index].lastObservationID = max(
      episodes[index].lastObservationID, reading?.continuity.map(\.id).max() ?? 0)
    disarmRelease(index)
    episodes[index].keptUntilRearm = true
    set(.none)
  }

  private mutating func stopForSilence(
    _ m: UUID, reason: MeetingEndedTelemetry.StopReason, _ out: inout [Command]
  ) {
    let id = newID()
    operations[id] = .stopForSilence(meetingID: m)
    silence?.accrued = 0
    set(.none)
    out.append(.stop(operation: id, meetingID: m, reason: reason))
  }

  /// #4249 silence backstop, a copy of Wispr Flow `tickSilence`: healthy steps with no new words
  /// accrue (each capped at 2 s); new words or unhealthy live words reset it to zero; after
  /// 10 minutes, and only once some words were heard, "Still in a meeting?" asks for 30 s with
  /// End as the default. New words withdraw the question; Keep restarts the clock. Covers every
  /// recording, linked to a call or not, while call detection runs.
  private mutating func trackSilence(_ c: Context, _ out: inout [Command]) {
    guard case .recording(let m) = c.meeting else {
      silence = nil
      if case .stillInMeeting = interaction { set(.none) }
      return
    }
    if silence?.meetingID != m {
      silence = Silence(meetingID: m, lastWordsAt: c.anyWordsAt)
      if case .stillInMeeting = interaction { set(.none) }
    }
    guard var state = silence else { return }
    let wordsNow = c.anyWordsAt != nil && c.anyWordsAt != state.lastWordsAt
    if wordsNow { state.lastWordsAt = c.anyWordsAt }
    let step =
      state.lastStepAt.map { min(max(0, c.now.timeIntervalSince($0)), Self.silenceTickCap) } ?? 0
    state.lastStepAt = c.now
    defer { silence = state }
    if case .stillInMeeting(m, let deadline) = interaction {
      if wordsNow {
        state.accrued = 0
        set(.none)
      } else if c.now >= deadline {
        silence = state
        stopForSilence(m, reason: .silenceTimeout, &out)
        state.accrued = 0
      }
      return
    }
    if !c.wordsHealthy || wordsNow { state.accrued = 0 } else { state.accrued += step }
    guard state.accrued >= Self.silenceAsk, state.lastWordsAt != nil else { return }
    switch interaction {
    case .none, .note: break
    default: return
    }
    set(.stillInMeeting(meetingID: m, deadline: c.now.addingTimeInterval(Self.silenceAnswer)))
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
        linkRecording(e, m, c)
        updateFacts(m) { $0.link = $0.link ?? (byItself ? .auto : .prompt) }
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
        // (review r17 F1). Idle Ask additionally needs a fresh G1 opportunity; automatic
        // admission retains its existing proof gate rather than inheriting that prompt gate.
        setPhase(e, .waiting)
      case .notStarted:
        setPhase(e, .offered)
      }
    case .stopForEnd, .stopAfterConfirmation, .stopForSilence:
      break
    }
  }

  private mutating func stopFinished(_ id: Int, _ c: Context, _ out: inout [Command]) {
    guard let operation = operations[id] else { return }
    switch operation {
    case .stopAfterConfirmation(let e, let family, let m):
      operations[id] = nil
      guard let episode = episode(e), case .stopping(id) = episode.phase else { return }
      remove(episode: e)
      if c.setUp, c.mode != .off, c.meeting == .idle, interaction == .none {
        out.append(.followNotes(meetingID: m, family: family))
      }
    case .stopForEnd(let e, let family, let m):
      operations[id] = nil
      guard let episode = episode(e), case .stopping(id) = episode.phase else { return }
      remove(episode: e)
      // A newer recording or a newer question keeps the panel (r3 F1, review r10 F2).
      if c.meeting == .idle, interaction == .none {
        out.append(.followNotes(meetingID: m, family: family))
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
        set(.switchNotConfirmed(family: family, until: c.now.addingTimeInterval(Self.stoppedOffer)))
      }
    case .stopForSilence(let m):
      operations[id] = nil
      // A newer recording or a newer question keeps the panel, as for a call end.
      if c.meeting == .idle, interaction == .none {
        out.append(.followNotes(meetingID: m, family: nil))
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
      case .stopForEnd, .stopAfterConfirmation, .userStart, .stopForSilence: false
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

  /// #4249: the one exception to "the token changes with the interaction": a release countdown's
  /// far-side pause and resume are the same countdown, so the coordinator's × hide (keyed by
  /// token) survives them. Any other interaction change in between takes a new token as usual.
  private mutating func setKeepingToken(_ new: Interaction) {
    interaction = new
    claimedToken = nil
  }

  /// A tip or a "could not start" never covers a question or a countdown (review r8 F2).
  private mutating func showNote(_ note: Note, _ c: Context) {
    switch interaction {
    case .ask, .switchCall, .countdown, .endConfirmation, .stillInMeeting: return
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
    case .ask(let e, _, _), .switchCall(let e, _, _, _), .countdown(let e, _),
      .endConfirmation(let e, _):
      if episode(e) == nil { set(.none) }
    default: break
    }
  }
}
