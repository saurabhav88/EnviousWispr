import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4012: when EnviousMeet asks to record, starts, switches and stops. When these fail, the
/// user is asked about a video or a voice note, misses a call, a late result covers a newer
/// question, or a meeting stops during a reconnect or keeps recording after the call.
///
/// Each test is a short story: readings arrive, the clock moves, buttons are pressed, starts and
/// stops finish. The stories cover the members of both leaks in
/// `docs/audits/2026-10-24-4012-leak-enumeration.md`.
@Suite("Call detection rules", .tags(.productOutcome))
struct CallDetectionPolicyTests {
  typealias Policy = CallDetectionPolicy

  @Test("A running user Start cannot display or queue an idle Ask before setup accepts it")
  func pendingUserStartSuppressesQuestion() {
    var s = recordingZoom()
    end(&s)
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    s.stopFinished()
    #expect(isStopped(s.interaction, .callEnded), "use the real stopped offer")
    s.press(.startNewRecording)
    let userStarts = s.commands.compactMap { command -> Int? in
      if case .startByUser(let id, .zoom) = command { return id }
      return nil
    }
    guard userStarts.count == 1 else { Issue.record("no actual user Start issued"); return }
    #expect(s.meeting == .idle, "setup has not accepted the user Start yet")
    s.hold([Self.zoom(.inactive)], for: Policy.questionInterval)
    let meet = Self.chrome(.active, url: Self.meetA)
    s.ready([meet])
    #expect(s.interaction == .none, "the unaccepted manual request still owns its start interval")
    s.startFinished(.notStarted)
    s.read([meet])
    #expect(s.interaction == .none, "the blocked opportunity cannot replay after refusal")
    #expect(s.starts == [.zoom] && s.stops == 1)
  }

  @Test("A later native mic-use opportunity asks again without inventing a call-end identity",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"),
    arguments: [CallAppFamily.zoom, .slack, .teams, .facetime, .webex, .dialpadMeetings,
      .gather, .lark, .voov], [false, true])
  func nativeRepeatOpportunity(family: CallAppFamily, missing: Bool) {
    var s = Story()
    let rule: CallAppCatalog.Rule = family == .zoom || family == .slack
      ? .callWindow(family) : .callApp(family)
    let call = Policy.Holder(pid: 100, rule: rule, input: .active,
      evidence: .call(family: family, room: "native-fixture"))
    s.ready([call])
    #expect(isAsk(s.interaction, family), "the first real Ask must be displayed")
    s.press(.no)
    s.press(.close)
    s.hold([call], for: Policy.questionInterval)
    #expect(s.interaction == .none, "unchanged microphone polling cannot renew the Ask")
    let inactive = Policy.Holder(pid: call.pid, rule: rule, input: .inactive,
      evidence: call.evidence)
    s.read(missing ? [] : [inactive])
    s.ready([call])
    #expect(isAsk(s.interaction, family), "a fresh eligible edge must not stay suppressed for the app run")
    #expect(s.answers == [.no], "offering again neither invents No nor changes the previous answer")
    #expect(s.starts.isEmpty && s.stops == 0)
    #expect(s.observations.isEmpty, "this story supplies no logical-call end proof")
  }

  @Test("Uncertain frames, duplicate projections and helper changes cannot renew an idle Ask",
    arguments: ["unknown", "incomplete", "ambiguous", "stale", "duplicate", "helper", "replacement"])
  func unusableQuestionEdges(kind: String) {
    var s = Story()
    let zoom = Self.zoom(.active)
    s.ready([zoom])
    s.press(.no)
    s.press(.close)
    s.hold([zoom], for: Policy.questionInterval)
    switch kind {
    case "unknown": s.read([Self.zoom(.unknown)])
    case "incomplete": s.read([], complete: false)
    case "ambiguous": s.read([], ambiguous: true)
    case "stale":
      s.sequence += 1
      s.policy.observe(.init(sequence: s.sequence, takenAt: s.now.addingTimeInterval(-Policy.staleAfter - 1),
        complete: true, holders: []))
      s.step()
    case "duplicate":
      s.policy.observe(.init(sequence: s.sequence, takenAt: s.now, complete: true, holders: []))
      s.step()
    case "helper": s.read([zoom, Self.zoom(.active, pid: 101)])
    default: s.ready([Self.chrome(.active, url: Self.meetA)])
    }
    s.ready([zoom])
    #expect(s.interaction == .none, "only a new determinate app-count edge can renew Ask")
    #expect(s.answers == [.no] && s.starts.isEmpty && s.stops == 0)
  }

  @Test("A cooldown-rejected edge is consumed rather than queued until time passes")
  func cooldownEdgesAreConsumed() {
    var s = Story()
    let zoom = Self.zoom(.active)
    s.ready([zoom])
    s.press(.no)
    s.press(.close)
    s.read([Self.zoom(.inactive)])
    s.ready([zoom])
    s.hold([zoom], for: Policy.questionInterval)
    #expect(s.interaction == .none)
    s.read([Self.zoom(.inactive)])
    s.ready([zoom])
    #expect(isAsk(s.interaction, .zoom))
    #expect(s.answers == [.no])
  }

  @Test("A positive count decrease gets its own exact two-second opportunity clock")
  func positiveDecreaseUsesOpportunityClock() {
    var s = Story()
    let zoom = Self.zoom(.active)
    let meet = Self.chrome(.active, url: Self.meetA)
    s.ready([zoom, meet])
    s.press(.no)
    s.press(.close)
    s.hold([zoom, meet], for: Policy.questionInterval)
    #expect(s.interaction == .none)
    s.read([meet])
    s.wait(1.999)
    s.read([meet])
    #expect(s.interaction == .none, "old episode age cannot skip opportunity readiness")
    s.wait(0.001)
    s.read([meet])
    #expect(isAsk(s.interaction, .googleMeet))
  }

  @Test("An undisplayed opportunity cannot survive busy or an accepted manual recording",
    arguments: [false, true])
  func pendingQuestionDiscarded(manual: Bool) {
    var s = Story()
    let zoom = Self.zoom(.active)
    s.dictation = true
    s.ongoing(zoom)
    #expect(s.interaction == .none)
    if manual {
      let request = s.acceptManual()
      let id = UUID()
      s.meeting = .recording(meetingID: id)
      s.settleManual(request, recordingID: id)
    } else {
      s.meeting = .busy
      s.step()
    }
    s.meeting = .idle
    s.dictation = false
    s.read([zoom])
    #expect(s.interaction == .none, "returning idle cannot revive an old pending opportunity")
    #expect(s.starts.isEmpty && s.stops == 0)
  }

  @Test("Off and incomplete setup require a new microphone frame before initial-positive eligibility",
    arguments: [false, true])
  func questionBaselineRestarts(setup: Bool) {
    var s = Story()
    let zoom = Self.zoom(.active)
    s.ready([zoom])
    s.press(.no)
    s.press(.close)
    s.hold([zoom], for: Policy.questionInterval)
    if setup { s.setUp = false } else { s.mode = .off }
    s.step()
    s.setUp = true
    s.mode = .ask
    s.wait(Policy.questionReadiness)
    s.step()
    #expect(s.interaction == .none, "a cached disabled-lifetime frame cannot restart Ask")
    s.ready([zoom])
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("Wake consumes holdoff edges without queuing an Ask for holdoff expiry")
  func wakeConsumesQuestionEdges() {
    var s = Story()
    let zoom = Self.zoom(.active)
    s.ready([zoom])
    s.press(.no)
    s.press(.close)
    s.hold([zoom], for: Policy.questionInterval)
    s.policy.noteWakeOrRestart(at: s.now)
    s.read([Self.zoom(.inactive)])
    s.read([zoom])
    s.hold([zoom], for: Policy.wakeHoldoff + Policy.questionReadiness)
    #expect(s.interaction == .none)
    s.read([Self.zoom(.inactive)])
    s.ready([zoom])
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("A count change while Ask is visible never restarts its token or original lifetime")
  func countChangeKeepsQuestionDeadline() {
    var s = Story()
    let zoom = Self.zoom(.active)
    let both = [zoom, Self.chrome(.active, url: Self.meetA)]
    s.ready([zoom])
    let token = s.policy.token
    s.wait(30)
    s.read(both)
    #expect(s.policy.token == token && isAsk(s.interaction, .zoom))
    s.hold(both, for: Policy.promptTimeout - 30 - 0.001)
    #expect(isAsk(s.interaction, .zoom))
    s.wait(0.001)
    s.read(both)
    #expect(s.interaction == .none)
    #expect(s.answers == [.timeout], "the other waiting app was not queued behind this question")
  }

  @Test("Microphone edges after cooldown cannot prompt or stop an active Ask-owned recording")
  func recordingIgnoresQuestionEdges() {
    var s = recordingZoom()
    let recording = s.meeting
    let zoom = Self.zoom(.active)
    s.hold([zoom], for: Policy.questionInterval)
    s.read([])
    s.ready([zoom])
    #expect(s.meeting == recording && s.interaction == .none)
    #expect(s.starts == [.zoom] && s.stops == 0)
    #expect(s.answers == [.yes])
  }

  @Test("Microphone inactivity or disappearance alone never ends a policy-owned recording",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"), arguments: [true, false])
  func microphoneLossIsNotCallEnd(missing: Bool) throws {
    var story = Story()
    story.mode = .startByItself
    story.read([Self.zoom(.active)])
    #expect(story.lastStart != nil)
    story.startFinished(.recording(meetingID: UUID()))
    let holders = missing ? [] : [Self.zoom(.inactive)]
    story.read(holders)
    story.hold(holders, for: 2)
    if case .countdown = story.interaction { Issue.record("microphone loss is not ended proof") }
    story.hold(holders, for: 20)
    #expect(story.lastStop == nil, "no independent ended observation was supplied")
  }

  @Test("Two completed scoped end reads cross microphone polls; a cached ID and ticks cannot confirm")
  func independentEndAcrossPolls() {
    var s = recordingZoom()
    let call = Self.zoom(.active)
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call)
    s.read([call])
    s.pending = s.sources
    s.hold([call], for: 4)
    #expect(!isCountdown(s.interaction), "one completed ID, despite active microphone polls")
    s.pending = []
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call)
    s.read([call])
    #expect(isCountdown(s.interaction), "input can remain active after the actual call ends")
    s.hold([call], for: Policy.countdownLength)
    #expect(s.stops == 1)
  }

  @Test("Completed uncertainty, ongoing or owner invalidation cancels countdown and consumes old proof",
    arguments: [0, 1, 2, 3])
  func independentEndResets(kind: Int) {
    var s = recordingZoom()
    end(&s)
    #expect(isCountdown(s.interaction))
    let previous = s.observations
    if kind == 3 {
      s.wait(Policy.staleAfter + 1)
    } else {
      let value: CallEvidenceReader.Continuity = kind == 1
        ? .ongoing(family: .zoom, room: "w") : .unknown
      let owner = kind == 2 ? CallEvidenceReader.AppRun(pid: 100,
        bundleIdentifier: "test.100", birthSeconds: 2, birthMicroseconds: 0) : nil
      s.observeCall(value, holder: Self.zoom(.active), owner: owner)
    }
    s.read([Self.zoom(.inactive)])
    #expect(!isCountdown(s.interaction))
    s.observations = previous
    s.read([Self.zoom(.inactive)])
    s.step()
    #expect(!isCountdown(s.interaction), "replaying consumed old IDs cannot resurrect confirmation")
    #expect(s.stops == 0)
  }

  @Test("Fresh ongoing blocks conflicting retained end; clearing it needs two new ends; other rooms do not block")
  func retainedAndGenericReconciliation() {
    var s = Story()
    let call = Self.chrome(.active, url: Self.meetA)
    s.ongoing(call)
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    let target = CallEvidenceReader.RetainedTarget(rule: call.rule, holderPID: call.pid,
      owner: Story.owner(for: call), family: .googleMeet, room: "abc-defg-hij")
    s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: call, retained: target)
    s.read([call])
    s.wait(2)
    s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: call, retained: target)
    s.read([call])
    #expect(!isEndConfirmation(s.interaction), "fresh same-scope ongoing in another slot prevents end")
    #expect(s.stops == 0)
    s.observeCall(.unknown, holder: call)
    s.read([call])
    #expect(!isEndConfirmation(s.interaction), "clearing the conflict cannot resurrect consumed ended IDs")
    s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: call, retained: target)
    s.read([call])
    #expect(!isEndConfirmation(s.interaction), "one new end after conflict clearing is insufficient")
    s.wait(2)
    s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: call, retained: target)
    s.read([call])
    #expect(isEndConfirmation(s.interaction), "two new scoped page ends qualify consent once ongoing conflict is gone")
    let other = CallEvidenceReader.RetainedTarget(rule: call.rule, holderPID: call.pid,
      owner: target.owner, family: .googleMeet, room: "xyz-wxyz-xyz")
    s.observeCall(.ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"), holder: call, retained: other)
    s.read([call])
    #expect(isEndConfirmation(s.interaction), "another room's ongoing does not withdraw this recording's consent")
    s.observeCall(.unknown, holder: call)
    s.read([call])
    #expect(isEndConfirmation(s.interaction), "once qualified, uncertainty cannot erase unanswered consent")
    #expect(s.stops == 0)
  }

  @Test("Wrong room, family or process birth cannot end the established call", arguments: [0, 1, 2])
  func wrongEndAttribution(kind: Int) {
    var s = Story()
    let call = Self.chrome(.active, url: Self.meetA)
    s.ongoing(call)
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    let value: CallEvidenceReader.Continuity = kind == 0
      ? .ended(family: .googleMeet, room: "xyz-wxyz-xyz")
      : .ended(family: kind == 1 ? .zoom : .googleMeet, room: "abc-defg-hij")
    let owner = kind == 2 ? CallEvidenceReader.AppRun(pid: call.pid,
      bundleIdentifier: "test.200", birthSeconds: 2, birthMicroseconds: 0) : nil
    for _ in 0..<2 {
      s.wait(2)
      s.observeCall(value, holder: call, owner: owner)
      s.read([call])
    }
    #expect(!isCountdown(s.interaction))
    #expect(s.stops == 0)
  }

  @Test("Unknown cannot renew Not now; a determinate mic-use edge after cooldown can",
    arguments: [0, 1, 2])
  func declinedCallSurvivesMicrophoneLoss(kind: Int) {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.press(.no)
    s.press(.close)
    let holders = kind == 0 ? [Self.zoom(.inactive)] : kind == 1 ? [Self.zoom(.unknown)] : []
    s.hold(holders, for: 130)
    s.ready([Self.zoom(.active)])
    #expect(kind == 1 ? s.interaction == .none : isAsk(s.interaction, .zoom))
    #expect(s.answers == [.no])
  }

  @Test("Ask readiness and lifetime have exact independent boundaries; notes retain 15 seconds")
  func questionClockBoundaries() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.wait(1.999)
    s.read([Self.zoom(.active)])
    #expect(s.interaction == .none)
    s.wait(0.001)
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom))
    s.hold([Self.zoom(.active)], for: 119.999)
    #expect(isAsk(s.interaction, .zoom))
    s.wait(0.001)
    s.read([Self.zoom(.active)])
    #expect(s.interaction == .none)
    #expect(s.answers == [.timeout])
    var tip = Story()
    tip.ready([Self.zoom(.active)])
    tip.press(.no)
    tip.wait(14.999)
    tip.step()
    #expect(note(tip.interaction) == .firstTip)
    tip.wait(0.001)
    tip.step()
    #expect(tip.interaction == .none)
  }

  @Test("Global interval starts at actual display; deferred proof is checked before another question")
  func globalQuestionIntervalAndDeferredProof() {
    var s = Story()
    s.dictation = true
    let zoom = Self.zoom(.active)
    let meet = Self.chrome(.active, url: Self.meetA)
    s.read([zoom])
    s.hold([zoom], for: 130)
    s.dictation = false
    s.read([zoom])
    #expect(isAsk(s.interaction, .zoom), "candidate detection did not spend the display interval")
    s.press(.no)
    s.press(.close)
    s.read([zoom, meet])
    s.hold([zoom, meet], for: 119.999)
    #expect(s.interaction == .none)
    s.wait(0.001)
    s.read([zoom, Self.chromeUnknown(.active)])
    #expect(s.interaction == .none, "interval expiry cannot reuse stale eligibility")
    s.read([zoom, meet])
    #expect(s.interaction == .none, "cooldown expiry does not replay its rejected edge")
    s.read([Self.chromeUnknown(.active)])
    s.wait(Policy.questionReadiness)
    s.read([meet])
    #expect(isAsk(s.interaction, .googleMeet), "a new 2-to-1 edge waits for fresh proof")
  }

  @Test("Pending evidence cannot refresh an old end or reuse it as a second confirmation")
  func pendingEndBecomesStale() {
    var s = recordingZoom()
    let call = Self.zoom(.active)
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call)
    s.read([call])
    s.pending = s.sources
    s.hold([call], for: Policy.staleAfter + 1)
    #expect(!isCountdown(s.interaction))
    s.pending = []
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call)
    s.read([call])
    #expect(!isCountdown(s.interaction), "one new end after stale reset is only one confirmation")
    s.wait(2)
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call)
    s.read([call])
    #expect(isCountdown(s.interaction))
  }

  @Test("A new same-process episode cannot reuse the previous call's ended observations")
  func newEpisodeConsumesHistoricalEnd() {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    s.press(.no)
    s.press(.close)
    end(&s)
    #expect(!s.policy.isTrackingCalls)
    let historical = s.observations
    s.wait(Policy.questionInterval)
    s.ongoing(call)
    #expect(isAsk(s.interaction, .zoom))
    s.press(.no)
    s.press(.close)
    s.observations = historical
    s.read([Self.zoom(.inactive)])
    #expect(s.policy.isTrackingCalls)
    s.ready([call])
    #expect(s.interaction == .none, "historical end cannot release the new call's Not now")
    #expect(s.answers == [.no, .no])
  }

  @Test("A replacement app run withdraws the old question and cannot inherit its end count")
  func replacementRunCannotBorrowEnd() {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    guard case .ask(let first, _, _) = s.interaction else { Issue.record("no question"); return }
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call)
    s.read([Self.zoom(.inactive)])
    let replacement = CallEvidenceReader.AppRun(pid: call.pid, bundleIdentifier: "test.100",
      birthSeconds: 2, birthMicroseconds: 0)
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: call, owner: replacement)
    s.read([call])
    #expect(s.interaction == .none)
    s.wait(Policy.questionInterval)
    s.read([Self.zoom(.inactive)])
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: call, owner: replacement)
    s.ready([call])
    guard case .ask(let second, _, _) = s.interaction else { Issue.record("no replacement question"); return }
    #expect(first != second)
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    s.wait(2)
    s.observeCall(.ended(family: .zoom, room: "w"), holder: call, owner: replacement)
    s.read([Self.zoom(.inactive)])
    #expect(!isCountdown(s.interaction), "the new run has only one ended observation")
  }

  @Test("An old same-room browser page end never stops a recording without an answer",
    arguments: [Policy.Input.active, .inactive])
  func unansweredBrowserPageEndNeverStopsRecording(microphone: Policy.Input) {
    var s = Story()
    let call = Self.chrome(.active, url: Self.meetA)
    s.ongoing(call)
    s.press(.yes)
    let recording = UUID()
    s.startFinished(.recording(meetingID: recording))
    #expect(s.starts == [.googleMeet])
    // The existing reader only reports browser run + room. A rejoined tab's live
    // observation and the old tab's later ended heading share those same identifiers.
    s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: call)
    s.read([call])
    s.wait(0.5)
    s.observeCall(.ongoing(family: .googleMeet, room: "abc-defg-hij"), holder: call)
    s.read([call])
    let oldPage = Policy.Holder(pid: call.pid, rule: call.rule, input: microphone,
      evidence: CallEvidenceReader.Evidence.none)
    end(&s, [oldPage], call: call)
    s.hold([oldPage], for: Policy.countdownLength + Policy.promptTimeout)
    #expect(s.stops == 0, "a page-end heading is not permission to stop a possibly live browser call")
    #expect(s.meeting == .recording(meetingID: recording))
  }

  @Test("Browser end consent persists through silence, stale proof, busy work and wake",
    arguments: ["silence", "unknown", "busy", "wake"])
  func browserConsentPersists(kind: String) throws {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    guard case .endConfirmation = s.interaction else { Issue.record("no end consent"); return }
    let token = s.policy.token
    switch kind {
    case "unknown": s.observeCall(.unknown, holder: call); s.read([Self.chromeUnknown(.inactive)])
    case "busy": s.meeting = .busy; s.step()
    case "wake": s.policy.noteWakeOrRestart(at: s.now)
    default: break
    }
    s.wait(Policy.promptTimeout + Policy.countdownLength)
    s.step()
    #expect(s.stops == 0)
    if case .endConfirmation = s.interaction {} else { Issue.record("consent expired") }
    if kind != "wake" { #expect(s.policy.token == token, "uncertainty never replays presentation") }
    else { #expect(s.policy.token != token, "wake invalidates captured answers") }
  }

  @Test("Only explicit browser Stop dispatches once, without a new Start answer")
  func browserConsentStopOnce() throws {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    let token = s.policy.token
    let answers = s.answers
    s.press(.yes)
    #expect(s.stops == 0 && s.answers == answers)
    s.press(.stopRecording, token: token)
    s.press(.stopRecording, token: token)
    #expect(s.stops == 1 && s.starts == [.googleMeet] && s.answers == answers)
    let operation = try #require(s.lastStop)
    s.stopFinished()
    #expect(isStopped(s.interaction, .userConfirmed))
    #expect(s.policy.handle(.stopFinished(operation: operation), s.context).isEmpty)
    #expect(s.stops == 1)
  }

  @Test("Browser Keep and dismissal survive old end pages and later live proof",
    arguments: [Policy.Button.keepRecording, .close])
  func browserConsentKeep(button: Policy.Button) {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    s.press(button)
    let answers = s.answers
    for _ in 0..<2 {
      end(&s, [call], call: call)
      s.ongoing(call)
    }
    s.hold([call], for: Policy.questionInterval + 10)
    #expect(s.interaction == .none && s.stops == 0 && s.starts == [.googleMeet])
    #expect(s.answers == answers)
  }

  @Test("Fresh ongoing browser proof withdraws consent; captured Stop cannot affect a new UUID",
    arguments: [false, true])
  func browserConsentInvalidation(newRecording: Bool) {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    let oldToken = s.policy.token
    if newRecording { s.meeting = .recording(meetingID: UUID()); s.step() }
    else { s.observeCall(.ongoing(family: .googleMeet, room: "abc-defg-hij"), holder: call); s.read([call]) }
    #expect(s.interaction == .none)
    s.press(.stopRecording, token: oldToken)
    #expect(s.stops == 0)
  }

  @Test("Disabling detection or its browser clears consent without stopping or accepting an old answer",
    arguments: [false, true])
  func browserConsentDisabled(appOnly: Bool) {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    let token = s.policy.token
    if appOnly { s.appsOff = [CallAppCatalog.switchID(for: call.rule)] } else { s.mode = .off }
    s.step()
    #expect(s.interaction == .none)
    s.press(.stopRecording, token: token)
    #expect(s.stops == 0)
  }

  @Test("Switch has priority over pending browser consent, which returns after No or timeout",
    arguments: [false, true])
  func browserConsentSwitchPriority(timeout: Bool) {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    s.wait(Policy.questionInterval)
    s.observeCall(.unknown, holder: call)
    s.ready([Self.zoom(.active)])
    #expect(isSwitch(s.interaction))
    s.press(.stopRecording)
    #expect(s.stops == 0)
    if timeout { s.wait(Policy.promptTimeout); s.step() } else { s.press(.no) }
    if case .endConfirmation = s.interaction {} else { Issue.record("pending recording consent lost") }
    #expect(s.stops == 0)
  }

  @Test("A frozen manual browser Start survives only its matching uncertain page end",
    arguments: ["matching", "foreignRoom", "foreignFamily", "changedRun", "stale", "off", "wake", "newRequest"])
  func browserManualEndDuringStart(kind: String) {
    var s = Story()
    let call = Self.chrome(.active, url: Self.meetA)
    s.ongoing(call)
    let request = s.acceptManual()
    end(&s, [call], call: call)
    switch kind {
    case "foreignRoom": s.observeCall(.ended(family: .googleMeet, room: "xyz-wxyz-xyz"), holder: call)
    case "foreignFamily": s.observeCall(.ended(family: .teams, room: "abc-defg-hij"), holder: call)
    case "changedRun": s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: call,
      owner: .init(pid: call.pid, bundleIdentifier: "test.200", birthSeconds: 2, birthMicroseconds: 0))
    case "stale": s.wait(Policy.staleAfter + 1)
    case "off": s.mode = .off; s.step(); s.mode = .ask
    case "wake": s.policy.noteWakeOrRestart(at: s.now)
    case "newRequest": _ = s.acceptManual(generation: 2)
    default: break
    }
    s.read([call])
    let recording = UUID()
    s.meeting = .recording(meetingID: recording)
    s.settleManual(request, recordingID: recording)
    if kind == "matching" {
      end(&s, [call], call: call)
      if case .endConfirmation = s.interaction {} else { Issue.record("frozen matching candidate lost") }
      s.press(.stopRecording)
      #expect(s.stops == 1)
    } else {
      end(&s, [call], call: call)
      #expect(s.interaction == .none && s.stops == 0)
    }
    #expect(s.starts.isEmpty)
  }

  @Test("Every browser rule treats service page ends as consent, never an automatic timer",
    arguments: CallAppCatalog.Browser.allCases, [CallAppFamily.googleMeet, .teams, .zoom])
  func allBrowserPageEndsRequireConsent(browser: CallAppCatalog.Browser, family: CallAppFamily) {
    var s = Story()
    let call = Policy.Holder(pid: 200, rule: .browser(browser), input: .active,
      evidence: .call(family: family, room: "browser-room"))
    s.ongoing(call)
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    #expect(s.starts == [family])
    end(&s, [call], call: call)
    #expect(isEndConfirmation(s.interaction))
    s.hold([call], for: Policy.countdownLength + Policy.promptTimeout)
    #expect(s.stops == 0)
    s.press(.stopRecording)
    #expect(s.stops == 1)
  }

  @Test("An uncertain page end cannot cancel an already running detected browser Start",
    arguments: [Policy.Mode.ask, .startByItself])
  func browserEndDoesNotCancelStart(mode: Policy.Mode) {
    var s = Story()
    s.mode = mode
    let call = Self.chrome(.active, url: Self.meetA)
    s.ongoing(call)
    if mode == .ask { s.press(.yes) }
    #expect(s.starts == [.googleMeet])
    end(&s, [call], call: call)
    #expect(s.policy.isStartWanted(s.context))
    s.startFinished(.recording(meetingID: UUID()))
    end(&s, [call], call: call)
    #expect(isEndConfirmation(s.interaction) && s.stops == 0)
  }

  @Test("A late explicit-stop completion cannot claim a newer recording or reset policy",
    arguments: [false, true])
  func browserStopCompletionIsolation(reset: Bool) {
    var s = recordingBrowser()
    let call = Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    s.press(.stopRecording)
    #expect(s.stops == 1)
    if reset { s.mode = .off; s.step(); s.mode = .ask }
    s.stopFinished(meetingAfter: .recording(meetingID: UUID()))
    #expect(s.interaction == .none && s.stops == 1)
  }

  @Test("Foreign-family native uncertainty preserves the existing frozen manual-start contract")
  func nativeManualForeignEndRemainsUnknown() {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    let request = s.acceptManual()
    s.observeCall(.ended(family: .teams, room: "w"), holder: call)
    s.read([call])
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    end(&s)
    #expect(isCountdown(s.interaction), "only scoped Zoom end, not foreign-family uncertainty, owns its end")
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    #expect(s.stops == 1)
    #expect(s.commands.contains { if case .stop(_, id) = $0 { true } else { false } })
  }

  @Test("An old Stop cannot regain presentation after a newer recording has come and gone",
    arguments: [false, true])
  func stopCompletionChangeBack(native: Bool) {
    var s = native ? recordingZoom() : recordingBrowser()
    let call = native ? Self.zoom(.active) : Self.chrome(.active, url: Self.meetA)
    end(&s, [call], call: call)
    if native { s.hold([Self.zoom(.inactive)], for: Policy.countdownLength) }
    else { s.press(.stopRecording) }
    #expect(s.stops == 1)
    s.meeting = .recording(meetingID: UUID())
    s.step()
    s.meeting = .idle
    s.step()
    #expect(s.interaction == .none)
    s.stopFinished()
    #expect(s.interaction == .none, "an old Stop has no presentation authority after a newer recording")
    #expect(s.stops == 1)
  }

  func recordingBrowser() -> Story {
    var s = Story()
    s.ongoing(Self.chrome(.active, url: Self.meetA))
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    return s
  }

  @Test("A verified replacement source gets its own idle episode without borrowing an obsolete Yes",
    arguments: [false, true])
  func verifiedSourceReplacesOwnerlessIdleEpisode(offered: Bool) throws {
    var s = Story()
    let call = Self.zoom(.active)
    let original = Policy.Source(id: 41, pid: call.pid, rule: call.rule)
    let replacement = Policy.Source(id: 42, pid: call.pid, rule: call.rule)
    let owner = CallEvidenceReader.AppRun(pid: call.pid, bundleIdentifier: "us.zoom.xos",
      birthSeconds: 1, birthMicroseconds: 0)
    s.observeCall(.unknown, holder: call, sourceObservation: (original, nil))
    s.read([call])
    if offered {
      s.wait(Policy.questionReadiness)
      s.read([call])
      #expect(isAsk(s.interaction, .zoom))
    }
    let oldEpisode = try #require(s.policy.episodes.first?.id)
    let oldToken = s.policy.token

    // Discovery replaced the Core Audio object without changing its PID. A current frame
    // contains the new source only, not the historical source retained in the episode.
    s.sources = [replacement]
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: call,
      sourceObservation: (replacement, owner))
    s.read([call])
    let current = try #require(s.policy.episodes.first { $0.id != oldEpisode && $0.owner == owner },
      "a verified replacement must not stay trapped in an obsolete ownerless idle episode")
    #expect(!s.policy.episodes.contains { $0.id == oldEpisode })
    #expect(current.sources == [replacement])
    #expect(s.interaction == .none, "source replacement is not a fresh microphone-app opportunity")
    s.press(.yes, token: oldToken)
    #expect(s.starts.isEmpty && s.stops == 0, "an obsolete captured Yes cannot start or switch the replacement")

    let request = s.acceptManual()
    let recording = UUID()
    s.meeting = .recording(meetingID: recording)
    s.settleManual(request, recordingID: recording)
    end(&s, [Self.zoom(.inactive)], call: call, sourceObservation: (replacement, owner))
    #expect(isCountdown(s.interaction), "the replacement's real ownership supports the matching manual fallback")
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    #expect(s.commands.contains { if case .stop(_, recording) = $0 { true } else { false } })
    #expect(s.starts.isEmpty)
  }

  enum OwnerlessSourceGuard: CaseIterable, Equatable, Sendable {
    case sameSource, coexistingSource, ambiguousReplacement, unverifiedReplacement, recording
  }

  @Test("Source uncertainty, coexistence and recordings cannot be retired as obsolete idle offers",
    arguments: OwnerlessSourceGuard.allCases)
  func ownerlessSourceTransitionGuards(kind: OwnerlessSourceGuard) throws {
    var s = Story()
    let call = Self.zoom(.active)
    let original = Policy.Source(id: 41, pid: call.pid, rule: call.rule)
    s.observeCall(.unknown, holder: call, sourceObservation: (original, nil))
    s.ready([call])
    let oldEpisode = try #require(s.policy.episodes.first?.id)
    let recording = UUID()
    if kind == .recording {
      s.press(.yes)
      s.startFinished(.recording(meetingID: recording))
    }
    let oldToken = s.policy.token
    let nextCall = Self.zoom(.active, pid: kind == .coexistingSource ? call.pid + 1 : call.pid)
    let nextSource = kind == .sameSource ? original
      : Policy.Source(id: 42, pid: nextCall.pid, rule: nextCall.rule)
    let nextOwner: CallEvidenceReader.AppRun? = kind == .unverifiedReplacement ? nil
      : .init(pid: nextCall.pid, bundleIdentifier: "us.zoom.xos", birthSeconds: 1, birthMicroseconds: 0)
    s.sources = kind == .coexistingSource ? [original, nextSource] : [nextSource]
    s.observeCall(kind == .unverifiedReplacement ? .unknown : .ongoing(family: .zoom, room: "w"),
      holder: nextCall, sourceObservation: (nextSource, nextOwner))
    s.read(kind == .coexistingSource ? [call, nextCall] : [nextCall],
      ambiguous: kind == .ambiguousReplacement)
    let current = try #require(s.policy.episodes.first { $0.id == oldEpisode })
    #expect(s.policy.episodes.count == 1)
    #expect(current.sources == [original])
    #expect(s.policy.token == oldToken, "uncertainty or compatible ownership does not renew the question")
    if kind == .sameSource {
      #expect(current.owner == nextOwner)
      s.press(.yes, token: oldToken)
      #expect(s.starts == [.zoom], "same-source owner adoption preserves the original valid Yes")
    } else {
      #expect(current.owner == nil, "an unrelated or uncertain source cannot silently supply ownership")
      if kind == .recording {
        #expect(s.meeting == .recording(meetingID: recording))
        #expect(s.starts == [.zoom] && s.stops == 0)
      } else {
        #expect(s.starts.isEmpty && s.stops == 0)
      }
    }
  }

  @Test("Replacing an obsolete idle offer cannot stop an unrelated current recording")
  func ownerlessReplacementPreservesUnrelatedRecording() throws {
    var s = Story()
    let call = Self.zoom(.active)
    let original = Policy.Source(id: 41, pid: call.pid, rule: call.rule)
    let replacement = Policy.Source(id: 42, pid: call.pid, rule: call.rule)
    let owner = CallEvidenceReader.AppRun(pid: call.pid, bundleIdentifier: "us.zoom.xos",
      birthSeconds: 1, birthMicroseconds: 0)
    s.observeCall(.unknown, holder: call, sourceObservation: (original, nil))
    s.ready([call])
    let oldEpisode = try #require(s.policy.episodes.first?.id)
    let oldToken = s.policy.token
    let unrelated = UUID()
    s.meeting = .recording(meetingID: unrelated)
    s.sources = [replacement]
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: call,
      sourceObservation: (replacement, owner))
    s.read([call])
    #expect(!s.policy.episodes.contains { $0.id == oldEpisode })
    #expect(s.policy.episodes.contains { $0.owner == owner && $0.sources == [replacement] })
    s.press(.yes, token: oldToken)
    #expect(s.meeting == .recording(meetingID: unrelated))
    #expect(s.stops == 0 && s.starts.isEmpty)
  }

  @Test("A timed-out native Ask can link the matching manual fallback once, without another Start or Yes")
  func timedOutManualFallbackLinks() {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    let oldToken = s.policy.token
    s.hold([call], for: Policy.promptTimeout)
    #expect(s.answers == [.timeout])
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: call)
    s.read([call])
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.press(.yes, token: oldToken)
    #expect(s.starts.isEmpty && s.answers == [.timeout])
    #expect(s.interaction == .none)
    end(&s)
    #expect(isCountdown(s.interaction))
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    #expect(s.commands.contains { if case .stop(_, id) = $0 { true } else { false } })
    #expect(s.starts.isEmpty)
  }

  @Test("A browser fallback needs pre-acceptance independent room proof, not just its URL", arguments: [true, false])
  func browserManualProofRequired(ongoing: Bool) {
    var s = Story()
    let call = Self.chrome(.active, url: Self.meetA)
    s.observeCall(ongoing ? .ongoing(family: .googleMeet, room: "abc-defg-hij") : .unknown, holder: call)
    s.ready([call])
    let request = s.acceptManual(route: .history)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    // Stronger proof after settlement cannot promote a URL-only rejected request.
    s.observeCall(.ongoing(family: .googleMeet, room: "abc-defg-hij"), holder: call)
    s.read([call])
    end(&s, [Self.chrome(.inactive, url: Self.meetA)], call: call)
    #expect(isEndConfirmation(s.interaction) == ongoing)
    #expect(s.starts.isEmpty)
    if !ongoing { #expect(s.meeting == .recording(meetingID: id) && s.stops == 0) }
  }

  @Test("A call or browser room identified after acceptance cannot borrow earlier microphone activity",
    arguments: [true, false])
  func lateCallCannotBecomeManualCandidate(browser: Bool) {
    var s = Story()
    let call = browser ? Self.chrome(.active, url: Self.meetA) : Self.zoom(.active)
    let unknown = Policy.Holder(pid: call.pid, rule: call.rule, input: .active, evidence: .unknown)
    s.observeCall(.unknown, holder: unknown)
    s.read([unknown])
    let request = s.acceptManual()
    let family: CallAppFamily = browser ? .googleMeet : .zoom
    let room = browser ? "abc-defg-hij" : "w"
    s.observeCall(.ongoing(family: family, room: room), holder: call)
    s.ready([call])
    #expect(s.interaction == .none, "pending provenance does not create a transient question")
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    let inactive = Policy.Holder(pid: call.pid, rule: call.rule, input: .inactive, evidence: call.evidence)
    end(&s, [inactive], call: call)
    #expect(!isCountdown(s.interaction) && s.stops == 0)
    #expect(s.meeting == .recording(meetingID: id))
  }

  @Test("Two admitted calls leave a manual recording unassociated")
  func ambiguousManualCandidateStaysManual() {
    var s = Story()
    let zoom = Self.zoom(.active)
    let teams = Self.teams(evidence: .call(family: .teams, room: "pid-300"))
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: zoom)
    s.observeCall(.ongoing(family: .teams, room: "pid-300"), holder: teams)
    s.ready([zoom, teams])
    #expect(s.policy.isTracking(.callWindow(.zoom)) && s.policy.isTracking(.callApp(.teams)))
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    end(&s, [Self.zoom(.inactive), Self.teams(.inactive)])
    #expect(!isCountdown(s.interaction) && s.stops == 0)
    #expect(s.meeting == .recording(meetingID: id))
  }

  @Test("End/new call, changed run, feature reset, wake and app disable invalidate a frozen fallback",
    arguments: [0, 1, 2, 3, 4])
  func frozenManualInvalidation(kind: Int) {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    let request = s.acceptManual()
    let replacement = CallEvidenceReader.AppRun(pid: call.pid, bundleIdentifier: "test.100",
      birthSeconds: 2, birthMicroseconds: 0)
    switch kind {
    case 0:
      end(&s)
      s.ongoing(call)
    case 1:
      s.observeCall(.ongoing(family: .zoom, room: "w"), holder: call, owner: replacement)
      s.read([call])
    case 2:
      s.mode = .off
      s.step()
      s.mode = .ask
      s.ongoing(call)
    case 3: s.policy.noteWakeOrRestart(at: s.now)
    default: s.appsOff = ["zoom"]
    }
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    if kind == 3 { s.wait(Policy.wakeHoldoff) }
    for _ in 0..<2 {
      s.wait(2)
      s.observeCall(.ended(family: .zoom, room: "w"), holder: call,
        owner: kind == 1 ? replacement : nil)
      s.read([Self.zoom(.inactive)])
    }
    #expect(!isCountdown(s.interaction), "invalidation case \(kind)")
    #expect(s.stops == 0 && s.meeting == .recording(meetingID: id))
  }

  @Test("A newer accepted request survives an obsolete completion and stops only its matching UUID")
  func manualGenerationCannotClearNewerRequest() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    let old = s.acceptManual(generation: 1)
    let current = s.acceptManual(generation: 2)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(old, recordingID: UUID())
    s.settleManual(current, recordingID: id)
    end(&s)
    #expect(isCountdown(s.interaction))
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    #expect(s.commands.contains { if case .stop(_, id) = $0 { true } else { false } })
    #expect(s.stops == 1 && s.starts.isEmpty)
  }

  @Test("Keep or a manual Stop cannot be silently reacquired on the same call", arguments: [true, false])
  func manualOverrideCannotBeReacquired(keep: Bool) {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    let request = s.acceptManual()
    let first = UUID()
    s.meeting = .recording(meetingID: first)
    s.settleManual(request, recordingID: first)
    if keep {
      end(&s)
      #expect(isCountdown(s.interaction))
      s.press(.keepRecording)
    }
    s.meeting = .idle
    s.step()
    s.ongoing(call)
    let next = s.acceptManual(generation: 2)
    let second = UUID()
    s.meeting = .recording(meetingID: second)
    s.settleManual(next, recordingID: second)
    s.settleManual(request, recordingID: first)
    end(&s)
    #expect(!isCountdown(s.interaction) && s.stops == 0)
    #expect(s.meeting == .recording(meetingID: second))
  }

  @Test("A different browser room cannot replace a frozen room; reload loses pending provenance")
  func frozenRoomAndReloadStayManual() {
    for reload in [false, true] {
      var s = Story()
      let call = Self.chrome(.active, url: Self.meetA)
      s.ongoing(call)
      let request = s.acceptManual()
      if reload { s.policy = Policy() }
      let other = Self.chrome(.active, url: Self.meetB)
      s.observeCall(.ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"), holder: other)
      s.ready([other])
      let id = UUID()
      s.meeting = .recording(meetingID: id)
      s.settleManual(request, recordingID: id)
      end(&s, [Self.chrome(.inactive, url: Self.meetB)], call: other)
      #expect(!isCountdown(s.interaction) && s.stops == 0)
      #expect(s.meeting == .recording(meetingID: id))
    }
  }

  @Test("An admitted native call with fresh ongoing proof can link through a microphone flap")
  func nativeManualFallbackThroughMicFlap() {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    s.read([])
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    end(&s, [])
    #expect(isCountdown(s.interaction), "independent call proof survives absent mic holders")
  }

  @Test("A different eligible call still asks to switch after a manual fallback links")
  func linkedManualAllowsDifferentCallSwitch() {
    var s = Story()
    let zoom = Self.zoom(.active)
    s.ongoing(zoom)
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.wait(Policy.questionInterval)
    let meet = Self.chrome(.active, url: Self.meetA)
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: zoom)
    s.observeCall(.ongoing(family: .googleMeet, room: "abc-defg-hij"), holder: meet)
    s.ready([zoom, meet])
    #expect(isSwitch(s.interaction))
    s.press(.yes)
    #expect(s.commands.contains { if case .stop(_, id) = $0 { true } else { false } })
    #expect(s.answers == [.switchYes], "adoption itself added no Yes or autoStarted")
  }

  @Test("Two retained browser rooms in the same verified run are ambiguous for a manual start")
  func twoBrowserRoomsStayManual() {
    var s = Story()
    let a = Self.chrome(.active, url: Self.meetA)
    let b = Self.chrome(.active, url: Self.meetB)
    s.ongoing(a)
    s.observeCall(.ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"), holder: b)
    s.ready([b])
    s.observeCall(.unknown, holder: b)
    let owner = Story.owner(for: a)
    let targetA = CallEvidenceReader.RetainedTarget(rule: a.rule, holderPID: a.pid,
      owner: owner, family: .googleMeet, room: "abc-defg-hij")
    let targetB = CallEvidenceReader.RetainedTarget(rule: b.rule, holderPID: b.pid,
      owner: owner, family: .googleMeet, room: "xyz-wxyz-xyz")
    s.observeCall(.ongoing(family: .googleMeet, room: "abc-defg-hij"), holder: a, retained: targetA)
    s.observeCall(.ongoing(family: .googleMeet, room: "xyz-wxyz-xyz"), holder: b, retained: targetB)
    s.read([])
    #expect(s.policy.isTracking(targetA) && s.policy.isTracking(targetB))
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    for _ in 0..<2 {
      s.wait(2)
      s.observeCall(.ended(family: .googleMeet, room: "abc-defg-hij"), holder: a, retained: targetA)
      s.read([])
    }
    #expect(!isCountdown(s.interaction) && s.stops == 0)
    #expect(s.meeting == .recording(meetingID: id))
  }

  @Test("Wake holdoff keeps a newly accepted manual start manual and still retires its old question")
  func manualAcceptanceDuringWakeStaysManual() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.policy.noteWakeOrRestart(at: s.now)
    let request = s.acceptManual()
    #expect(s.interaction == .none)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.wait(Policy.wakeHoldoff)
    end(&s)
    #expect(!isCountdown(s.interaction) && s.stops == 0)
    #expect(s.meeting == .recording(meetingID: id))
  }

  @Test("Legacy microphone frames provide no invented independent call observations")
  func legacyFrameHasNoContinuity() {
    let frame = Policy.Reading(sequence: 7, takenAt: Date(timeIntervalSince1970: 100),
      complete: true, holders: [
        .init(pid: 1, rule: .callWindow(.zoom), input: .inactive,
          evidence: .call(family: .zoom, room: "same-call"))
      ])
    #expect(frame.sources.isEmpty)
    #expect(frame.continuity.isEmpty)
    #expect(frame.pendingSources.isEmpty)
  }

  @Test("Read-only retained membership distinguishes browser rooms")
  func trackedRetainedRoomMembership() {
    var story = Story()
    story.read([.init(pid: 1, rule: .browser(.chrome), input: .active,
      evidence: .call(family: .googleMeet, room: "abc-defg-hij"))])
    let owner = CallEvidenceReader.AppRun(pid: 2, bundleIdentifier: "com.google.Chrome",
      birthSeconds: 100, birthMicroseconds: 1)
    let known = CallEvidenceReader.RetainedTarget(rule: .browser(.chrome), holderPID: 1,
      owner: owner, family: .googleMeet, room: "abc-defg-hij")
    let other = CallEvidenceReader.RetainedTarget(rule: .browser(.chrome), holderPID: 1,
      owner: owner, family: .googleMeet, room: "xyz-wxyz-xyz")
    #expect(story.policy.isTracking(known))
    #expect(!story.policy.isTracking(other))
  }

  @Test("Refresh projections retain the switch operation's intended call after its question changes")
  func refreshTargetFollowsOperationNotNewQuestion() throws {
    var story = Story()
    story.meeting = .recording(meetingID: UUID())
    story.ready([Self.zoom(.active)])
    let question = try #require(story.policy.refreshTarget(token: story.policy.token))
    #expect(question.family == .zoom)
    story.press(.yes)
    let operation = try #require(story.lastStop)
    let captured = try #require(story.policy.refreshTarget(operation: operation))
    #expect(captured.family == .zoom && captured.rule == .callWindow(.zoom))
    #expect(!story.policy.isCurrent(question))
    story.read([.init(pid: 2, rule: .callApp(.teams), input: .active,
      evidence: .call(family: .teams, room: "another-call"))])
    #expect(story.policy.refreshTarget(operation: operation) == captured)
    #expect(story.policy.isCurrent(captured))
  }

  #if DEBUG
    @Test("A completed observation can advance without advancing the microphone frame")
    func independentObservationUpdatesSameMicrophoneFrame() {
      let at = Date(timeIntervalSince1970: 100)
      let source = Policy.Source(id: 3, pid: 1, rule: .callWindow(.zoom))
      let previous = Policy.ContinuityObservation(id: 41, source: source,
        beganAt: at.addingTimeInterval(-1), completedAt: at, owner: nil, value: .unknown)
      var policy = Policy()
      policy.observe(.init(sequence: 7, takenAt: at, complete: true, holders: [], ambiguous: false,
        sources: [source], continuity: [previous], pendingSources: [source]))
      let completed = Policy.ContinuityObservation(id: 42, source: source, beganAt: at,
        completedAt: at.addingTimeInterval(1), owner: nil, value: .unknown)
      policy.observe(.init(sequence: 7, takenAt: at, complete: true, holders: [], ambiguous: false,
        sources: [source], continuity: [completed], pendingSources: []))
      #expect(policy.inputForTesting?.sequence == 7)
      #expect(policy.inputForTesting?.takenAt == at)
      #expect(policy.inputForTesting?.continuity == [completed])
      #expect(policy.inputForTesting?.pendingSources.isEmpty == true)
    }
  #endif

  /// One policy, a clock, the meeting side and everything the policy asked for.
  struct Story {
    typealias SourceObservation = (source: Policy.Source, owner: CallEvidenceReader.AppRun?)
    var policy = Policy()
    var now = Date(timeIntervalSince1970: 2_000_000)
    var sequence = 0
    var meeting: Policy.Meeting = .idle
    var mode: Policy.Mode = .ask
    var appsOff: Set<String> = []
    var setUp = true
    var dictation = false
    var startBlocked = false
    var firstTipShown = false
    var noCounts: [String: Int] = [:]
    var commands: [Policy.Command] = []
    var sources: [Policy.Source] = []
    var pending: [Policy.Source] = []
    var observations: [Policy.ContinuityObservation] = []
    var nextObservation = 1

    /// Explicit test facts, never inferred from microphone state or absent windows.
    mutating func observeCall(_ value: CallEvidenceReader.Continuity, holder: Policy.Holder,
      owner: CallEvidenceReader.AppRun? = nil,
      retained: CallEvidenceReader.RetainedTarget? = nil,
      sourceObservation: SourceObservation? = nil) {
      let source = sourceObservation?.source ?? Policy.Source(id: Int(holder.pid), pid: holder.pid, rule: holder.rule)
      if !sources.contains(source) { sources.append(source) }
      // An explicit observation preserves nil attribution. Omitted observations keep the
      // original fixture defaults for the older stories.
      let run: CallEvidenceReader.AppRun?
      if let sourceObservation { run = sourceObservation.owner }
      else { run = owner ?? Self.owner(for: holder) }
      observations.removeAll { $0.source == source && $0.retainedTarget == retained }
      observations.append(.init(id: nextObservation, source: source, beganAt: now,
        completedAt: now, owner: run, value: value, retainedTarget: retained))
      nextObservation += 1
    }

    static func owner(for holder: Policy.Holder) -> CallEvidenceReader.AppRun {
      .init(pid: holder.pid, bundleIdentifier: "test.\(holder.pid)",
        birthSeconds: 1, birthMicroseconds: 0)
    }

    /// Reach the approved question readiness with fresh microphone facts, without UI end proof.
    mutating func ready(_ holders: [Policy.Holder]) {
      read(holders)
      wait(Policy.questionReadiness)
      read(holders)
    }

    /// An explicitly attributed ongoing call, used only by stories that exercise independent end.
    mutating func ongoing(_ holder: Policy.Holder) {
      guard case .call(let family, let room)? = holder.evidence else {
        Issue.record("ongoing fixture requires explicit call evidence"); return
      }
      observeCall(.ongoing(family: family, room: room), holder: holder)
      ready([holder])
    }

    var context: Policy.Context {
      .init(
        now: now, meeting: meeting, dictationActive: dictation, mode: mode, appsOff: appsOff,
        setUp: setUp, startBlocked: startBlocked, firstTipShown: firstTipShown,
        noCounts: noCounts)
    }

    var interaction: Policy.Interaction { policy.interaction }

    /// A reading of these holders, then a step.
    mutating func read(_ holders: [Policy.Holder], complete: Bool = true, ambiguous: Bool = false) {
      sequence += 1
      policy.observe(
        .init(
          sequence: sequence, takenAt: now, complete: complete, holders: holders,
          ambiguous: ambiguous, sources: sources, continuity: observations, pendingSources: pending))
      step()
    }

    mutating func step() { record(policy.step(context)) }

    mutating func wait(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    /// Readings every 2 seconds for `seconds`, the same holders each time.
    mutating func hold(_ holders: [Policy.Holder], for seconds: TimeInterval) {
      var left = seconds
      while left > 0 {
        wait(min(2, left))
        left -= 2
        read(holders)
      }
    }

    mutating func acceptManual(generation: Int = 1, route: MeetingEntryPoint = .menu) -> Policy.AcceptedStart {
      let request = Policy.AcceptedStart(generation: generation, route: route, acceptedAt: now)
      record(policy.acceptedStart(request, context))
      return request
    }

    mutating func settleManual(_ request: Policy.AcceptedStart, recordingID: UUID?) {
      record(policy.settledStart(request, recordingID: recordingID, context))
    }

    mutating func press(_ button: Policy.Button) {
      record(policy.handle(.pressed(token: policy.token, button), context))
    }

    /// A press with a token from before the panel changed.
    mutating func press(_ button: Policy.Button, token: Int) {
      record(policy.handle(.pressed(token: token, button), context))
    }

    mutating func startFinished(_ result: Policy.StartResult) {
      guard let id = lastStart else { return }
      if case .recording(let m) = result { meeting = .recording(meetingID: m) }
      record(policy.handle(.startFinished(operation: id, result), context))
    }

    /// The stop finished; `meetingAfter` is what records by then (nothing, usually).
    mutating func stopFinished(meetingAfter: Policy.Meeting = .idle) {
      guard let id = lastStop else { return }
      meeting = meetingAfter
      record(policy.handle(.stopFinished(operation: id), context))
    }

    var lastStart: Int? {
      for command in commands.reversed() {
        if case .start(let id, _) = command { return id }
        if case .startByUser(let id, _) = command { return id }
      }
      return nil
    }

    var lastStop: Int? {
      for command in commands.reversed() { if case .stop(let id, _) = command { return id } }
      return nil
    }

    var starts: [CallAppFamily] {
      commands.compactMap { if case .start(_, let family) = $0 { family } else { nil } }
    }

    var stops: Int { commands.filter { if case .stop = $0 { true } else { false } }.count }

    var answers: [MeetingCallPromptTelemetry.Answer] {
      commands.compactMap { if case .emit(_, let answer) = $0 { answer } else { nil } }
    }

    private mutating func record(_ new: [Policy.Command]) { commands += new }
  }

  static func zoom(
    _ input: Policy.Input, evidence: CallEvidenceReader.Evidence? = .call(family: .zoom, room: "w"),
    pid: Int32 = 100
  ) -> Policy.Holder {
    .init(pid: pid, rule: .callWindow(.zoom), input: input, evidence: evidence)
  }

  static func chrome(_ input: Policy.Input, url: String?, pid: Int32 = 200) -> Policy.Holder {
    let match = url.flatMap(CallMeetingURL.classify)
    let evidence: CallEvidenceReader.Evidence =
      match.map { .call(family: $0.family, room: $0.room) } ?? .none
    return .init(pid: pid, rule: .browser(.chrome), input: input, evidence: evidence)
  }

  static func chromeUnknown(_ input: Policy.Input, pid: Int32 = 200) -> Policy.Holder {
    .init(pid: pid, rule: .browser(.chrome), input: input, evidence: .unknown)
  }

  static let meetA = "https://meet.google.com/abc-defg-hij"
  static let meetB = "https://meet.google.com/xyz-wxyz-xyz"

  func isAsk(_ i: Policy.Interaction, _ family: CallAppFamily) -> Bool {
    if case .ask(_, family, _) = i { return true }
    return false
  }

  func isSwitch(_ i: Policy.Interaction) -> Bool {
    if case .switchCall = i { return true }
    return false
  }

  func isEndConfirmation(_ i: Policy.Interaction) -> Bool {
    if case .endConfirmation = i { return true }
    return false
  }

  func isCountdown(_ i: Policy.Interaction) -> Bool {
    if case .countdown = i { return true }
    return false
  }

  func isStopped(_ i: Policy.Interaction, _ reason: Policy.StopReason) -> Bool {
    if case .stopped(reason, _, _) = i { return true }
    return false
  }

  func note(_ i: Policy.Interaction) -> Policy.Note? {
    if case .note(let n, _) = i { return n }
    return nil
  }

  /// A Zoom call recorded through Yes.
  func recordingZoom() -> Story {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    return s
  }

  /// Two explicit completed UI end observations of the already-established call.
  func end(_ s: inout Story, _ holders: [Policy.Holder] = [zoom(.inactive)],
    call: Policy.Holder = zoom(.active), sourceObservation: Story.SourceObservation? = nil) {
    guard case .call(let family, let room)? = call.evidence else {
      Issue.record("end fixture requires an explicit scoped call"); return
    }
    s.observeCall(.ended(family: family, room: room), holder: call, sourceObservation: sourceObservation)
    s.read(holders)
    s.wait(2)
    s.observeCall(.ended(family: family, room: room), holder: call, sourceObservation: sourceObservation)
    s.read(holders)
  }

  // MARK: - Starting

  @Test(
    "A Teams microphone test never starts automatic recording",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4094"))
  func teamsMicrophoneTestDoesNotStartAutomatically() {
    let fixture = CallEvidenceReaderTests.Fixture()
    var s = Story()
    s.mode = .startByItself
    s.read([
      .init(
        pid: fixture.pid, rule: .callApp(.teams), input: .active,
        evidence: CallEvidenceReader.nativeCallEvidence(
          family: .teams, holderPID: fixture.pid, access: fixture.access))
    ])
    #expect(
      s.starts.isEmpty,
      "Microphone activity without a Teams call control must not start recording: \(s.starts)")
  }

  @Test("a Zoom meeting window with the microphone on asks once")
  func zoomAsksOnce() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom))
    s.press(.close)
    s.hold([Self.zoom(.active)], for: 6)
    #expect(s.interaction == .none)
  }

  @Test("Slack asks for a verified huddle, never for an idle channel or unreadable evidence")
  func slackHuddleAsks() {
    let control = SlackHuddleWindow.classRead(["leaveButton__wzISw"])
    for (signal, title, shouldAsk) in [
      (control, "huddle-test - Qualtrics - Slack", true),
      (.missing, "huddle-test (Channel) - Qualtrics - Slack", false),
      (.failed, "Saurabh Vaish (DM) - Qualtrics - Slack", false),
    ] as [(SlackHuddleWindow.Read, String, Bool)] {
      let verdict = SlackHuddleWindow.classify(
        windowCount: 1, identifier: { _ in signal }, title: { _ in .value(title) })
      let evidence: CallEvidenceReader.Evidence =
        switch verdict {
        case .call: .call(family: .slack, room: "solo")
        case .none: .none
        case .unknown: .unknown
        }
      var s = Story()
      s.ready([.init(pid: 300, rule: .callWindow(.slack), input: .active, evidence: evidence)])
      #expect(isAsk(s.interaction, .slack) == shouldAsk, "\(title)")
    }
  }

  @Test("no evidence, unknown evidence or an unknown microphone never asks")
  func noKnownEvidenceNoPrompt() {
    for holder in [
      Self.zoom(.active, evidence: CallEvidenceReader.Evidence.none),
      Self.zoom(.active, evidence: .unknown), Self.zoom(.active, evidence: nil),
      Self.zoom(.unknown), Self.chrome(.active, url: "https://www.youtube.com/watch?v=abc"),
    ] {
      var s = Story()
      s.read([holder])
      #expect(s.interaction == .none, "\(holder)")
    }
  }

  @Test("an incomplete or stale reading never starts a call")
  func incompleteNeverStarts() {
    var s = Story()
    s.read([Self.zoom(.active)], complete: false)
    #expect(s.interaction == .none)
    var stale = Story()
    stale.policy.observe(
      .init(sequence: 1, takenAt: stale.now, complete: true, holders: [Self.zoom(.active)]))
    stale.wait(Policy.staleAfter + 1)
    stale.step()
    #expect(stale.interaction == .none)
  }

  @Test("an older reading arriving late is never applied")
  func olderReadingDropped() {
    var s = Story()
    s.policy.observe(.init(sequence: 5, takenAt: s.now, complete: true, holders: []))
    s.policy.observe(
      .init(sequence: 4, takenAt: s.now, complete: true, holders: [Self.zoom(.active)]))
    s.step()
    #expect(s.interaction == .none)
  }

  @Test("Google Meet in Chrome asks")
  func meetAsks() {
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.meetA)])
    #expect(isAsk(s.interaction, .googleMeet))
  }

  @Test("no prompt while dictating; it comes when the dictation ends")
  func waitsForDictation() {
    var s = Story()
    s.dictation = true
    s.ready([Self.zoom(.active)])
    #expect(s.interaction == .none)
    s.dictation = false
    s.step()
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("an app switched off, Off mode, or setup not finished never asks")
  func offNeverAsks() {
    var off = Story()
    off.appsOff = ["zoom"]
    off.read([Self.zoom(.active)])
    #expect(off.interaction == .none)
    var mode = Story()
    mode.mode = .off
    mode.read([Self.zoom(.active)])
    #expect(mode.interaction == .none)
    var setup = Story()
    setup.setUp = false
    setup.read([Self.zoom(.active)])
    #expect(setup.interaction == .none)
  }

  @Test("Start by itself starts instead of asking, and says auto_started only once it records")
  func startByItself() {
    var s = Story()
    s.mode = .startByItself
    s.read([Self.zoom(.active)])
    #expect(s.starts == [.zoom])
    #expect(s.interaction == .none)
    #expect(s.answers.isEmpty)
    s.startFinished(.recording(meetingID: UUID()))
    #expect(s.answers == [.autoStarted])
  }

  @Test("Start by itself that needs attention says so and sends no started event")
  func startByItselfNeedsAttention() {
    var s = Story()
    s.mode = .startByItself
    s.read([Self.zoom(.active)])
    s.startFinished(.needsAttention)
    #expect(s.answers == [.needsAttention])
    #expect(note(s.interaction) == .needsAttention)
    s.hold([Self.zoom(.active)], for: 4)
    #expect(s.starts.count == 1, "a call that needed attention is not started again")
  }

  // MARK: - Answers

  @Test("Yes starts the call the panel asked about; a press with an old token does nothing")
  func yesAndStaleToken() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    let asked = s.policy.token
    s.press(.close)
    s.press(.yes, token: asked)
    #expect(s.starts.isEmpty)
    var t = Story()
    t.ready([Self.zoom(.active)])
    t.press(.yes)
    #expect(t.starts == [.zoom])
    #expect(t.answers == [.yes])
  }

  @Test("Yes while the reading is unknown starts nothing and keeps the question")
  func yesWhileUnknown() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.read([Self.zoom(.active, evidence: .unknown)])
    s.press(.yes)
    #expect(s.starts.isEmpty)
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("Yes after a recording started from the menu asks to switch instead")
  func yesAfterMenuStart() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.meeting = .recording(meetingID: UUID())
    s.press(.yes)
    #expect(s.starts.isEmpty)
    #expect(isSwitch(s.interaction))
  }

  @Test("No records nothing, counts the No and shows the first tip once")
  func noShowsFirstTip() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.press(.no)
    #expect(s.starts.isEmpty)
    #expect(s.answers == [.no])
    #expect(s.commands.contains(.countNo(switchID: "zoom")))
    #expect(s.commands.contains(.markFirstTipShown))
    #expect(note(s.interaction) == .firstTip)
    s.wait(Policy.promptTimeout)
    s.step()
    #expect(s.interaction == .none)
  }

  @Test("the third No for one switch shows the last reminder; a browser's is counted as browser")
  func thirdNo() {
    var s = Story()
    s.firstTipShown = true
    s.noCounts = ["browser": 2]
    s.ready([Self.chrome(.active, url: Self.meetA)])
    s.press(.no)
    #expect(s.commands.contains(.countNo(switchID: "browser")))
    #expect(note(s.interaction) == .lastTip(rule: .browser(.chrome), family: .googleMeet))
  }

  @Test("a No stays quiet on unchanged input; a later call with a fresh edge asks again")
  func noLastsForTheCall() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.press(.no)
    s.press(.close)
    s.hold([Self.zoom(.active)], for: 20)
    #expect(s.interaction == .none)
    end(&s)
    s.wait(Policy.questionInterval)
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.zoom(.active))
    s.ready([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom), "the next call asks again")
  }

  @Test("an unanswered prompt closes after 120 seconds as a timeout, not a No")
  func promptTimeout() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.hold([Self.zoom(.active)], for: Policy.promptTimeout)
    #expect(s.interaction == .none)
    #expect(s.answers == [.timeout])
    #expect(!s.commands.contains(.countNo(switchID: "zoom")))
  }

  @Test("one question at a time; the other app needs a new opportunity after cooldown")
  func oneQuestionAtATime() {
    var s = Story()
    let both = [Self.zoom(.active), Self.chrome(.active, url: Self.meetA)]
    s.ready(both)
    guard case .ask(_, let first, _) = s.interaction else {
      Issue.record("no question")
      return
    }
    s.read(both)
    if case .ask(_, let still, _) = s.interaction { #expect(still == first) }
    s.press(.no)
    // The next call waits for the global display interval.
    #expect(!isAsk(s.interaction, .googleMeet))
    s.hold(both, for: Policy.questionInterval)
    #expect(s.interaction == .none, "another waiting episode is not a queued opportunity")
    let other = first == .zoom ? [Self.chrome(.active, url: Self.meetA)] : [Self.zoom(.active)]
    s.ready(other)
    guard case .ask(_, let second, _) = s.interaction else {
      Issue.record("the second call was never asked about")
      return
    }
    #expect(second != first)
  }

  @Test("the question goes away when its call ends or its app is switched off, not on a blip")
  func questionWithdrawn() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.read([Self.zoom(.unknown)])
    s.read([Self.zoom(.inactive)])
    #expect(isAsk(s.interaction, .zoom), "one off reading is a blip")
    s.hold([Self.zoom(.inactive)], for: 2)
    #expect(isAsk(s.interaction, .zoom), "mute is not end")
    end(&s)
    #expect(s.interaction == .none)
    #expect(s.answers.isEmpty, "a withdrawn question is not a timeout")
    var off = Story()
    off.ready([Self.zoom(.active)])
    off.appsOff = ["zoom"]
    off.step()
    #expect(off.interaction == .none)
  }

  // MARK: - Ending

  @Test("a detected meeting counts down after the call ends, then stops and offers a new one")
  func countdownThenStop() {
    var s = recordingZoom()
    end(&s)
    #expect(isCountdown(s.interaction))
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    #expect(s.stops == 1)
    s.stopFinished()
    #expect(isStopped(s.interaction, .callEnded))
    s.press(.startNewRecording)
    #expect(s.commands.contains { if case .startByUser(_, .zoom) = $0 { true } else { false } })
  }

  @Test("an end needs two readings and the confirm time; one reading never ends a call")
  func endNeedsReadingsAndTime() {
    var s = recordingZoom()
    s.observeCall(.ended(family: .zoom, room: "w"), holder: Self.zoom(.active))
    s.read([Self.zoom(.inactive)])
    s.wait(5)
    s.step()
    #expect(!isCountdown(s.interaction), "time alone with one reading")
    var t = recordingZoom()
    t.observeCall(.ended(family: .zoom, room: "w"), holder: Self.zoom(.active))
    t.read([Self.zoom(.inactive)])
    t.wait(0.5)
    t.observeCall(.ended(family: .zoom, room: "w"), holder: Self.zoom(.active))
    t.read([Self.zoom(.inactive)])
    #expect(!isCountdown(t.interaction), "two readings inside the confirm time")
  }

  @Test("independent ongoing call proof during the countdown cancels it")
  func returnCancelsCountdown() {
    var s = recordingZoom()
    end(&s)
    #expect(isCountdown(s.interaction))
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.zoom(.active))
    s.read([Self.zoom(.active)])
    #expect(s.interaction == .none)
    s.hold([Self.zoom(.active)], for: 20)
    #expect(s.stops == 0)
  }

  @Test("completed unknown, ongoing or stale independent proof restarts the end count")
  func uncertaintyRestartsTheEnd() {
    let breaks: [(inout Story) -> Void] = [
      { $0.observeCall(.unknown, holder: Self.zoom(.active)); $0.read([], complete: false) },
      { $0.observeCall(.unknown, holder: Self.zoom(.active)); $0.read([Self.zoom(.inactive)], ambiguous: true) },
      { $0.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.zoom(.active)); $0.read([Self.zoom(.unknown)]) },
      { s in
        s.wait(Policy.staleAfter + 1)
        s.step()
      },
    ]
    for (index, interrupt) in breaks.enumerated() {
      var s = recordingZoom()
      end(&s)
      #expect(isCountdown(s.interaction), "case \(index)")
      interrupt(&s)
      #expect(s.interaction == .none, "case \(index): the countdown ends")
      s.read([Self.zoom(.inactive)])
      s.wait(Policy.countdownLength)
      s.step()
      #expect(s.stops == 0, "case \(index): the count starts again from zero")
    }
  }

  @Test("neither a missing process nor a failed microphone read independently proves end")
  func missingVersusFailed() {
    var s = recordingZoom()
    s.read([])
    s.hold([], for: 20)
    #expect(!isCountdown(s.interaction), "disappearance is not independent termination proof")
    var t = recordingZoom()
    for _ in 0..<6 {
      t.wait(2)
      t.read([], complete: false)
    }
    #expect(!isCountdown(t.interaction))
  }

  @Test("after wake from sleep nothing ends for 10 seconds, and a running countdown restarts")
  func wakeHoldoff() {
    var s = recordingZoom()
    end(&s)
    #expect(isCountdown(s.interaction))
    s.wait(60)
    s.policy.noteWakeOrRestart(at: s.now)
    s.read([Self.zoom(.inactive)])
    #expect(s.stops == 0)
    #expect(s.interaction == .none)
    s.hold([Self.zoom(.inactive)], for: Policy.wakeHoldoff)
    #expect(s.stops == 0)
    end(&s)
    #expect(isCountdown(s.interaction))
  }

  @Test("Keep recording ends the countdown and the call's end never stops it later")
  func keepRecording() {
    var s = recordingZoom()
    end(&s)
    s.press(.keepRecording)
    #expect(s.interaction == .none)
    s.hold([Self.zoom(.inactive)], for: 30)
    #expect(s.stops == 0)
  }

  @Test("a hand-started meeting never stops when a call ends; a new call asks to switch")
  func handStarted() {
    var s = Story()
    s.meeting = .recording(meetingID: UUID())
    s.ongoing(Self.zoom(.active))
    #expect(isSwitch(s.interaction))
    s.press(.no)
    end(&s)
    s.hold([Self.zoom(.inactive)], for: 20)
    #expect(s.stops == 0)
    #expect(s.answers == [.switchNo])
    #expect(!s.policy.isTrackingCalls, "the unrelated call was actually confirmed over")
  }

  @Test("a meeting stopped from the menu takes its countdown away")
  func menuStopEndsCountdown() {
    var s = recordingZoom()
    end(&s)
    s.meeting = .idle
    s.step()
    #expect(s.interaction == .none)
    s.hold([Self.zoom(.inactive)], for: 20)
    #expect(s.stops == 0)
  }

  @Test("a late stop never covers a newer recording or a newer question")
  func lateStop() {
    var s = recordingZoom()
    end(&s)
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    s.stopFinished(meetingAfter: .recording(meetingID: UUID()))
    #expect(!isStopped(s.interaction, .callEnded))
    var t = recordingZoom()
    end(&t)
    t.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    t.meeting = .idle
    t.wait(Policy.questionInterval)
    t.ready([Self.zoom(.inactive), Self.chrome(.active, url: Self.meetA)])
    t.stopFinished()
    #expect(isAsk(t.interaction, .googleMeet), "the newer question keeps the panel")
  }

  // MARK: - Starts and switches

  @Test("failed starts say so; a superseded Start needs a fresh idle Ask opportunity")
  func startOutcomes() {
    for (result, expected) in [
      (Policy.StartResult.couldNotStart, Policy.Note.couldNotStart),
      (.needsAttention, .needsAttention),
    ] {
      var s = Story()
      s.ready([Self.zoom(.active)])
      s.press(.yes)
      s.startFinished(result)
      #expect(note(s.interaction) == expected)
    }
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.press(.yes)
    #expect(s.lastStart != nil, "the superseded result must settle an actual issued Start")
    s.startFinished(.superseded)
    s.wait(Policy.questionInterval)
    s.read([Self.zoom(.active)])
    #expect(s.interaction == .none, "settlement plus unchanged polling cannot renew Ask")
    s.read([Self.zoom(.inactive)])
    s.ready([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom), "a new opportunity can ask again after supersession")
  }

  @Test("a start in flight is never dropped: uncertainty keeps it wanted, success records")
  func startNotDropped() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.press(.yes)
    s.meeting = .busy
    s.read([], complete: false)
    s.read([Self.zoom(.active, evidence: .unknown)])
    #expect(s.policy.isStartWanted(s.context))
    s.startFinished(.recording(meetingID: UUID()))
    end(&s)
    #expect(isCountdown(s.interaction), "the recording is watched for its end")
  }

  @Test("detection or the app switched off during a start makes it unwanted")
  func startUnwanted() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.press(.yes)
    s.meeting = .busy
    #expect(s.policy.isStartWanted(s.context))
    s.appsOff = ["zoom"]
    s.step()
    #expect(!s.policy.isStartWanted(s.context))
    var off = Story()
    off.ready([Self.zoom(.active)])
    off.press(.yes)
    off.meeting = .busy
    off.mode = .off
    off.step()
    #expect(!off.policy.isStartWanted(off.context))
  }

  @Test("busy Start opportunities do not replay; an obsolete result keeps a newer question")
  func lateStartKeepsQuestion() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.press(.yes)
    s.meeting = .busy
    s.read([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    #expect(s.interaction == .none, "no question while the start runs")
    s.wait(Policy.questionInterval)
    s.read([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    s.meeting = .idle
    s.startFinished(.couldNotStart)
    #expect(note(s.interaction) == .couldNotStart, "busy count edges cannot queue an Ask")
    s.ready([Self.chrome(.active, url: Self.meetA)])
    #expect(isAsk(s.interaction, .googleMeet), "the next call's question owns the panel")
    s.startFinished(.couldNotStart)
    #expect(isAsk(s.interaction, .googleMeet), "obsolete completion cannot cover the newer question")
    s.press(.close)
    s.hold([Self.chrome(.active, url: Self.meetA)], for: 4)
    #expect(s.interaction == .none, "the failed call is not asked about again")
  }

  @Test("switch Yes stops the old meeting, then starts the new call")
  func switchYes() {
    var s = recordingZoom()
    s.wait(Policy.questionInterval)
    let both = [Self.zoom(.active), Self.chrome(.active, url: Self.meetA)]
    s.ready(both)
    #expect(isSwitch(s.interaction))
    s.press(.yes)
    #expect(s.stops == 1)
    #expect(s.answers.last == .switchYes)
    s.stopFinished()
    #expect(s.starts == [.zoom, .googleMeet])
  }

  @Test("switch Yes that a new Start could not finish keeps the meeting recording")
  func switchBlocked() {
    var s = recordingZoom()
    s.wait(Policy.questionInterval)
    s.ready([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    s.startBlocked = true
    s.press(.yes)
    #expect(s.stops == 0)
    #expect(note(s.interaction) == .needsAttention)
  }

  @Test("a switch whose new call is not confirmed after the stop says so and offers a Start")
  func switchNotConfirmed() {
    var s = recordingZoom()
    s.wait(Policy.questionInterval)
    s.ready([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    s.press(.yes)
    s.read([Self.zoom(.active), Self.chromeUnknown(.active)])
    s.stopFinished()
    #expect(s.starts == [.zoom])
    #expect(isStopped(s.interaction, .switchNotConfirmed))
  }

  @Test("a switch question pauses the old meeting's countdown")
  func switchPausesCountdown() {
    var s = recordingZoom()
    s.wait(Policy.questionInterval)
    end(&s)
    #expect(isCountdown(s.interaction))
    let next = [Self.zoom(.inactive), Self.chrome(.active, url: Self.meetA)]
    s.ready(next)
    #expect(isSwitch(s.interaction))
    s.hold(next, for: Policy.countdownLength + 2)
    #expect(s.stops == 0)
    s.press(.no)
    end(&s, next)
    #expect(isCountdown(s.interaction), "after No it counts down in view")
  }

  @Test("a switch question becomes Record this call? once the recording stops from the menu")
  func switchBecomesAsk() {
    var s = recordingZoom()
    s.wait(Policy.questionInterval)
    s.ready([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    let before = s.policy.token
    s.meeting = .idle
    s.step()
    #expect(isAsk(s.interaction, .googleMeet))
    s.press(.yes, token: before)
    #expect(s.starts == [.zoom], "a press on the old switch question does nothing")
  }

  // MARK: - Browsers

  @Test("two Chrome processes showing one meeting are one call")
  func browserProcessesOneCall() {
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.meetA, pid: 1), Self.chrome(.active, url: Self.meetA, pid: 2)])
    s.press(.no)
    s.press(.close)
    s.read([
      Self.chrome(.inactive, url: nil, pid: 1), Self.chrome(.active, url: Self.meetA, pid: 3),
    ])
    #expect(s.interaction == .none)
  }

  @Test("another tab never stops a browser recording; scoped page-end proof asks for consent")
  func browserTabChange() {
    var s = Story()
    s.ongoing(Self.chrome(.active, url: Self.meetA))
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    s.hold([Self.chrome(.active, url: "https://mail.google.com/")], for: 20)
    #expect(s.stops == 0)
    #expect(s.interaction == .none)
    s.read([Self.chromeUnknown(.active)])
    #expect(s.interaction == .none, "an unreadable page changes nothing")
    end(&s, [Self.chromeUnknown(.inactive)], call: Self.chrome(.active, url: Self.meetA))
    #expect(isEndConfirmation(s.interaction), "scoped page-end proof asks while another tab is selected")
    #expect(s.stops == 0)
    s.press(.stopRecording)
    #expect(s.stops == 1)
  }

  @Test("another meeting's page asks to switch and keeps the recorded meeting")
  func browserOtherMeeting() {
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.meetA)])
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    s.wait(Policy.questionInterval)
    s.ready([Self.chrome(.active, url: Self.meetB)])
    #expect(isSwitch(s.interaction))
    s.press(.no)
    s.hold([Self.chrome(.active, url: Self.meetB)], for: 20)
    #expect(s.stops == 0)
  }

  @Test(
    "#4135 one meeting seen at both Meet addresses is one call: the question stays, and No holds")
  func meetBothAddressForms() {
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.meetA)])
    guard case .ask(let first, .googleMeet, _) = s.interaction else {
      Issue.record("no question")
      return
    }
    s.read([Self.chrome(.active, url: "https://meet.google.com/meet/abc-defg-hij")])
    guard case .ask(let still, .googleMeet, _) = s.interaction else {
      Issue.record("the question went when the address changed form")
      return
    }
    #expect(still == first, "the same room under the longer address is the same question")
    s.press(.no)
    s.press(.close)
    s.hold([Self.chrome(.active, url: "https://meet.google.com/meet/abc-defg-hij")], for: 20)
    s.read([Self.chrome(.active, url: Self.meetA)])
    #expect(s.interaction == .none, "No to the room holds under either address")
  }

  static let teamsLink = "https://teams.live.com/meet/9318226891234"
  static let teamsLight =
    "https://teams.live.com/light-meetings/launch?p=AbCdEfGh12345678Xy&anon=true"

  @Test(
    "#4162 Teams web hand-off withdraws the old room; a fresh microphone opportunity can ask about the new one"
  )
  func teamsWebRedirectWhileAsking() {
    // The two addresses give different rooms: no mapping between the link number and the
    // page's code is known, so the call page is asked about as itself.
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.teamsLink)])
    guard case .ask(let first, .teams, _) = s.interaction else {
      Issue.record("no question on the meeting link")
      return
    }
    s.read([Self.chrome(.active, url: Self.teamsLight)])
    #expect(s.interaction == .none, "unknown room mapping cannot keep the old question")
    s.hold([Self.chrome(.active, url: Self.teamsLight)], for: Policy.questionInterval)
    #expect(s.interaction == .none, "a same-count redirect is not a queued Ask opportunity")
    s.read([Self.chrome(.inactive, url: Self.teamsLight)])
    s.ready([Self.chrome(.active, url: Self.teamsLight)])
    guard case .ask(let second, .teams, _) = s.interaction else {
      Issue.record("no question on the call page")
      return
    }
    #expect(second != first)
    #expect(s.starts.isEmpty)
  }

  @Test(
    "#4162 a recording started on the Teams meeting link asks to switch on the call page; No keeps it"
  )
  func teamsWebRedirectWhileRecording() {
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.teamsLink)])
    s.press(.yes)
    #expect(s.lastStart != nil, "the redirect must follow an actual issued Start")
    s.startFinished(.recording(meetingID: UUID()))
    s.wait(Policy.questionInterval)
    s.ready([Self.chrome(.active, url: Self.teamsLight)])
    #expect(isSwitch(s.interaction))
    s.press(.no)
    s.hold([Self.chrome(.active, url: Self.teamsLight)], for: 20)
    #expect(s.stops == 0)
  }

  @Test("Off mode forgets every call; the same app is asked about again after")
  func offForgets() {
    var s = Story()
    s.ready([Self.zoom(.active)])
    s.press(.no)
    s.mode = .off
    s.step()
    s.mode = .ask
    s.wait(Policy.questionInterval)
    s.ready([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("a moved room withdraws its question; only a new microphone opportunity asks again")
  func movedQuestion() {
    var s = Story()
    s.ready([Self.chrome(.active, url: Self.meetA)])
    guard case .ask(let first, _, _) = s.interaction else {
      Issue.record("no question")
      return
    }
    s.read([Self.chrome(.active, url: "https://mail.google.com/")])
    if case .ask(let still, _, _) = s.interaction {
      #expect(still == first, "a page that is no meeting keeps it")
    }
    s.read([Self.chrome(.active, url: Self.meetB)])
    #expect(s.interaction == .none, "old room question withdraws during global cooldown")
    s.wait(Policy.questionInterval)
    s.read([Self.chrome(.active, url: Self.meetB)])
    #expect(s.interaction == .none, "a room change with unchanged app count cannot renew Ask")
    s.read([Self.chrome(.inactive, url: Self.meetB)])
    s.ready([Self.chrome(.active, url: Self.meetB)])
    guard case .ask(let second, .googleMeet, _) = s.interaction else {
      Issue.record("the new meeting was not asked about")
      return
    }
    #expect(second != first)
  }

  @Test("a call confirmed over while its Start runs makes the Start unwanted")
  func endedWhileStarting() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.press(.yes)
    s.meeting = .busy
    #expect(s.policy.isStartWanted(s.context))
    end(&s)
    #expect(!s.policy.isStartWanted(s.context))
  }

  @Test("one Start at a time: a second call waits while a Start runs, even before it is busy")
  func oneStartAtATime() {
    var s = Story()
    s.mode = .startByItself
    let both = [Self.zoom(.active), Self.chrome(.active, url: Self.meetA)]
    s.read(both)
    s.read(both)
    #expect(s.starts.count == 1)
    s.startFinished(.notStarted)
    s.read(both)
    #expect(s.starts.count == 2, "the other call starts once the first Start settled")
  }

  @Test("a stop names the recording it is for")
  func stopNamesItsRecording() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.press(.yes)
    let m = UUID()
    s.startFinished(.recording(meetingID: m))
    end(&s)
    s.hold([Self.zoom(.inactive)], for: Policy.countdownLength)
    #expect(s.commands.contains { if case .stop(_, m) = $0 { true } else { false } })
  }

  @Test("a Yes pressed in time is never lost to the timeout while it is checked")
  func claimedYesSurvivesTimeout() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    s.wait(Policy.promptTimeout - 0.5)
    let token = s.policy.token
    s.policy.claim(token: token)
    s.wait(1)
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.zoom(.active))
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom), "the claimed question stays")
    s.press(.yes, token: token)
    #expect(s.starts == [.zoom])
    #expect(!s.answers.contains(.timeout))
    var ended = Story()
    ended.ongoing(Self.zoom(.active))
    let asked = ended.policy.token
    ended.policy.claim(token: asked)
    end(&ended)
    ended.press(.yes, token: asked)
    #expect(ended.starts.isEmpty, "a call that ended during the check is not started")
  }

  // MARK: - Catalog

  @Test("meeting addresses: rooms are recognised, ordinary pages are not")
  func meetingURLs() {
    #expect(CallMeetingURL.classify("https://meet.google.com/abc-defg-hij")?.family == .googleMeet)
    #expect(CallMeetingURL.classify("https://meet.google.com/landing") == nil)
    // #4135: signed-in Meet shows /meet/<code> for the same room.
    #expect(
      CallMeetingURL.classify("https://meet.google.com/meet/abc-defg-hij")
        == CallMeetingURL.Match(family: .googleMeet, room: "abc-defg-hij"))
    #expect(
      CallMeetingURL.classify("https://meet.google.com/meet/abc-defg-hij?authuser=0")?.room
        == CallMeetingURL.classify("https://meet.google.com/abc-defg-hij")?.room)
    #expect(CallMeetingURL.classify("https://meet.google.com/meet") == nil)
    #expect(CallMeetingURL.classify("https://meet.google.com/meet/") == nil)
    #expect(CallMeetingURL.classify("https://meet.google.com/meet/landing") == nil)
    #expect(
      CallMeetingURL.classify("https://meet.google.com/meet/abc-defg-hi") == nil, "malformed code")
    #expect(CallMeetingURL.classify("https://meet.google.com/meet/abc-defg-hij/x") == nil)
    #expect(CallMeetingURL.classify("https://meet.google.com.evil.com/meet/abc-defg-hij") == nil)
    #expect(CallMeetingURL.classify("http://meet.google.com/meet/abc-defg-hij") == nil)
    #expect(
      CallMeetingURL.classify("https://meet.google.com/abc-defg-hij/x")?.room == "abc-defg-hij",
      "the short form keeps matching on its first segment, as before")
    #expect(
      CallMeetingURL.classify("https://us02web.zoom.us/j/81234567890?pwd=x")?.room == "81234567890")
    #expect(CallMeetingURL.classify("https://app.zoom.us/wc/81234567890/join")?.family == .zoom)
    #expect(CallMeetingURL.classify("https://zoom.us/pricing") == nil)
    #expect(
      CallMeetingURL.classify(
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0")?.family
        == .teams)
    #expect(CallMeetingURL.classify("https://teams.live.com/meet/9318226891234")?.family == .teams)
    #expect(CallMeetingURL.classify("https://teams.microsoft.com/v2/") == nil, "chat is not a call")
    // #4162: the page a teams.live.com meeting runs on; the p code is the room.
    let light = "https://teams.live.com/light-meetings/launch?p=AbCdEfGh12345678Xy&anon=true"
    #expect(CallMeetingURL.classify(light)?.family == .teams)
    #expect(
      CallMeetingURL.classify(
        "https://teams.live.com/light-meetings/launch?anon=true&p=AbCdEfGh12345678Xy")?
        .room == CallMeetingURL.classify(light)?.room, "other parameters do not change the room")
    #expect(
      CallMeetingURL.classify("https://teams.live.com/light-meetings/launch?p=Other1234567890Abc")?
        .room
        != CallMeetingURL.classify(light)?.room)
    #expect(CallMeetingURL.classify("https://teams.live.com/light-meetings/launch") == nil)
    #expect(CallMeetingURL.classify("https://teams.live.com/light-meetings/launch?p=") == nil)
    #expect(CallMeetingURL.classify("https://teams.live.com/light-meetings/other?p=AbCd") == nil)
    #expect(
      CallMeetingURL.classify("https://teams.live.com/v2/?p=AbCd") == nil, "chat is not a call")
    #expect(
      CallMeetingURL.classify("https://teams.microsoft.com/light-meetings/launch?p=AbCd") == nil,
      "not seen on the work client")
    #expect(CallMeetingURL.classify("https://acme.webex.com/meet/jdoe")?.family == .webex)
    #expect(
      CallMeetingURL.classify("https://acme.webex.com/acme/j.php?MTID=m123")?.family == .webex)
    #expect(CallMeetingURL.classify("https://www.webex.com/pricing.html") == nil)
    #expect(
      CallMeetingURL.classify("https://acme.webex.com/acme/j.php?MTID=m123&siteurl=acme")?.room
        == CallMeetingURL.classify("https://acme.webex.com/acme/j.php?siteurl=acme&MTID=m123")?.room
    )
    #expect(
      CallMeetingURL.classify("https://acme.webex.com/acme/j.php?MTID=m111")?.room
        != CallMeetingURL.classify("https://acme.webex.com/acme/j.php?MTID=m222")?.room)
    #expect(CallMeetingURL.classify("https://whereby.com/acme-standup")?.family == .whereby)
    #expect(CallMeetingURL.classify("https://meet.jit.si/AcmeRoom")?.family == .jitsi)
    #expect(CallMeetingURL.classify("https://app.slack.com/huddle/T1/C2")?.family == .slack)
    #expect(CallMeetingURL.classify("https://app.slack.com/client/T1/C2") == nil)
    #expect(CallMeetingURL.classify("http://meet.google.com/abc-defg-hij") == nil)
    #expect(CallMeetingURL.classify("not a url") == nil)
  }

  @Test("the catalog maps helpers to their app and leaves other apps out")
  func catalog() {
    #expect(CallAppCatalog.rule(forBundleID: "us.zoom.xos") == .callWindow(.zoom))
    #expect(CallAppCatalog.rule(forBundleID: "com.google.Chrome.helper") == .browser(.chrome))
    #expect(CallAppCatalog.rule(forBundleID: "com.apple.WebKit.GPU") == .browser(.safari))
    #expect(CallAppCatalog.rule(forBundleID: "com.microsoft.teams2") == .callApp(.teams))
    #expect(CallAppCatalog.rule(forBundleID: "org.mozilla.firefox") == nil)
    #expect(CallAppCatalog.rule(forBundleID: "com.hnc.discord") == nil)
    #expect(CallAppCatalog.rule(forBundleID: "com.enviouswispr.app") == nil)
    #expect(
      CallAppCatalog.owningAppPath(
        ofExecutable: "/Applications/zoom.us.app/Contents/Frameworks/x/zoom Helper")
        == "/Applications/zoom.us.app")
    #expect(CallAppCatalog.owningAppPath(ofExecutable: "/usr/libexec/coreaudiod") == nil)
  }

  @Test("every app on the settings list is a call app; switches round-trip through the setting")
  func settingsAppList() {
    for app in CallAppCatalog.nativeApps {
      for id in app.appBundleIDs {
        let rule = CallAppCatalog.rule(forBundleID: id)
        #expect(rule == .callApp(app.family) || rule == .callWindow(app.family), "\(id)")
      }
    }
    #expect(Set(CallAppCatalog.nativeApps.map(\.family)).count == CallAppCatalog.nativeApps.count)
    #expect(
      CallAppCatalog.installedNativeApps { $0 == "us.zoom.xos" || $0 == "com.apple.FaceTime" }
        == [.zoom, .facetime])
    #expect(CallAppCatalog.appsOff(from: "") == [])
    #expect(CallAppCatalog.appsOff(from: "zoom,,browser") == ["zoom", "browser"])
    #expect(CallAppCatalog.encodeAppsOff(["zoom", "browser"]) == "browser,zoom")
  }

  @Test("a process that cannot be named may be a call app only by its bundle")
  func mayBeCallApp() {
    #expect(CallAppCatalog.mayBeCallApp(bundleID: nil))
    #expect(CallAppCatalog.mayBeCallApp(bundleID: "com.google.Chrome.helper.GPU"))
    #expect(CallAppCatalog.mayBeCallApp(bundleID: "us.zoom.xos"))
    #expect(!CallAppCatalog.mayBeCallApp(bundleID: "com.apple.Music"))
    #expect(!CallAppCatalog.mayBeCallApp(bundleID: "com.google.chromecast"))
  }

  static func teams(
    _ input: Policy.Input = .active,
    evidence: CallEvidenceReader.Evidence = .microphoneOnly(family: .teams, room: "pid-300")
  ) -> Policy.Holder {
    .init(pid: 300, rule: .callApp(.teams), input: input, evidence: evidence)
  }

  @Test("Teams microphone-only evidence asks; only call proof permits automatic recording")
  func teamsEvidenceAdmission() {
    for proof in [false, true] {
      let evidence: CallEvidenceReader.Evidence =
        proof
        ? .call(family: .teams, room: "pid-300") : .microphoneOnly(family: .teams, room: "pid-300")
      let modes: [Policy.Mode] = [.ask, .startByItself, .off]
      for mode in modes {
        var s = Story()
        s.mode = mode
        s.ready([Self.teams(evidence: evidence)])
        #expect(s.starts == (proof && mode == .startByItself ? [.teams] : []))
        #expect(isAsk(s.interaction, .teams) == (mode == .ask))
      }
    }
    let inputs: [Policy.Input] = [.inactive, .unknown]
    for input in inputs {
      var s = Story()
      s.read([Self.teams(input)])
      #expect(s.interaction == .none)
      #expect(s.starts.isEmpty)
    }
  }

  @Test("An old microphone-only Teams Ask cannot start after changing to automatic mode")
  func teamsStaleAskYes() {
    var s = Story()
    s.ready([Self.teams()])
    #expect(isAsk(s.interaction, .teams))
    s.mode = .startByItself
    s.press(.yes)
    #expect(s.starts.isEmpty)
    s.read([Self.teams(evidence: .call(family: .teams, room: "pid-300"))])
    s.press(.yes)
    #expect(s.starts == [.teams], "A real call control restores eligibility for this question")
  }

  @Test("An old microphone-only Teams switch Yes cannot stop another meeting in automatic mode")
  func teamsStaleSwitchYes() {
    var s = Story()
    let existing = UUID()
    s.meeting = .recording(meetingID: existing)
    s.ready([Self.teams()])
    #expect(isSwitch(s.interaction))
    s.mode = .startByItself
    s.press(.yes)
    #expect(s.stops == 0)
    #expect(s.starts.isEmpty)
    #expect(s.meeting == .recording(meetingID: existing))
  }

  @Test("Waiting Teams microphone evidence cannot acquire automatic permission from a mode change")
  func teamsWaitingModeChange() {
    var s = Story()
    s.dictation = true
    s.read([Self.teams()])
    #expect(s.interaction == .none)
    s.mode = .startByItself
    s.dictation = false
    s.step()
    #expect(s.starts.isEmpty)
    #expect(s.interaction == .none)
    s.read([Self.teams(evidence: .call(family: .teams, room: "pid-300"))])
    #expect(s.starts == [.teams])
  }

  @Test("A Teams switch rechecks current proof and mode after the old meeting stops")
  func teamsSwitchCompletion() {
    for proof in [false, true] {
      var s = Story()
      s.meeting = .recording(meetingID: UUID())
      s.ready([Self.teams()])
      s.press(.yes)
      #expect(s.stops == 1)
      s.mode = .startByItself
      let evidence: CallEvidenceReader.Evidence =
        proof
        ? .call(family: .teams, room: "pid-300") : .microphoneOnly(family: .teams, room: "pid-300")
      s.read([Self.teams(evidence: evidence)])
      s.stopFinished()
      #expect(s.starts == (proof ? [.teams] : []))
      if !proof { #expect(isStopped(s.interaction, .switchNotConfirmed)) }
    }
  }

  @Test("A chosen Teams Ask start survives mode/proof changes and ends only with independent proof")
  func teamsChosenStartAndEnd() {
    var s = Story()
    s.observeCall(.ongoing(family: .teams, room: "pid-300"), holder: Self.teams())
    s.ready([Self.teams()])
    s.press(.yes)
    #expect(s.starts == [.teams])
    s.mode = .startByItself
    s.meeting = .busy
    s.read([Self.teams(evidence: .unknown)])
    #expect(s.policy.isStartWanted(s.context))
    s.startFinished(.recording(meetingID: UUID()))
    s.hold([Self.teams(evidence: .unknown)], for: 4)
    #expect(s.stops == 0, "Missing AX proof alone cannot end a recording")
    end(&s, [Self.teams(.inactive, evidence: .unknown)],
      call: Self.teams(evidence: .call(family: .teams, room: "pid-300")))
    #expect(isCountdown(s.interaction))
    s.hold([Self.teams(.inactive, evidence: .unknown)], for: Policy.countdownLength)
    #expect(s.stops == 1)
  }

  @Test("Other native calling apps retain microphone-based automatic starts")
  func otherNativeAppsStayAutomatic() {
    var s = Story()
    s.mode = .startByItself
    s.read([
      .init(
        pid: 400, rule: .callApp(.facetime), input: .active,
        evidence: .call(family: .facetime, room: "pid-400"))
    ])
    #expect(s.starts == [.facetime])
  }

}
