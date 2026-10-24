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

  /// One policy, a clock, the meeting side and everything the policy asked for.
  struct Story {
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

    var context: Policy.Context {
      .init(
        now: now, meeting: meeting, dictationActive: dictation, mode: mode, appsOff: appsOff,
        setUp: setUp, startBlocked: startBlocked, firstTipShown: firstTipShown,
        noCounts: noCounts)
    }

    var interaction: Policy.Interaction { policy.interaction }

    /// A reading of these holders, then a step.
    mutating func read(_ holders: [Policy.Holder], complete: Bool = true, ambiguous: Bool = false)
    {
      sequence += 1
      policy.observe(
        .init(
          sequence: sequence, takenAt: now, complete: complete, holders: holders,
          ambiguous: ambiguous))
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
    s.read([Self.zoom(.active)])
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    return s
  }

  /// Ends a call: the microphone off in readings for long enough.
  func end(_ s: inout Story, _ holders: [Policy.Holder] = [zoom(.inactive)]) {
    s.read(holders)
    s.hold(holders, for: 2)
  }

  // MARK: - Starting

  @Test("a Zoom meeting window with the microphone on asks once")
  func zoomAsksOnce() {
    var s = Story()
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom))
    s.press(.close)
    s.hold([Self.zoom(.active)], for: 6)
    #expect(s.interaction == .none)
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
    s.read([Self.chrome(.active, url: Self.meetA)])
    #expect(isAsk(s.interaction, .googleMeet))
  }

  @Test("no prompt while dictating; it comes when the dictation ends")
  func waitsForDictation() {
    var s = Story()
    s.dictation = true
    s.read([Self.zoom(.active)])
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
    s.read([Self.zoom(.active)])
    let asked = s.policy.token
    s.press(.close)
    s.press(.yes, token: asked)
    #expect(s.starts.isEmpty)
    var t = Story()
    t.read([Self.zoom(.active)])
    t.press(.yes)
    #expect(t.starts == [.zoom])
    #expect(t.answers == [.yes])
  }

  @Test("Yes while the reading is unknown starts nothing and keeps the question")
  func yesWhileUnknown() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.read([Self.zoom(.active, evidence: .unknown)])
    s.press(.yes)
    #expect(s.starts.isEmpty)
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("Yes after a recording started from the menu asks to switch instead")
  func yesAfterMenuStart() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.meeting = .recording(meetingID: UUID())
    s.press(.yes)
    #expect(s.starts.isEmpty)
    #expect(isSwitch(s.interaction))
  }

  @Test("No records nothing, counts the No and shows the first tip once")
  func noShowsFirstTip() {
    var s = Story()
    s.read([Self.zoom(.active)])
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
    s.read([Self.chrome(.active, url: Self.meetA)])
    s.press(.no)
    #expect(s.commands.contains(.countNo(switchID: "browser")))
    #expect(note(s.interaction) == .lastTip(rule: .browser(.chrome), family: .googleMeet))
  }

  @Test("a No lasts for the call: it is not asked again until the call ends")
  func noLastsForTheCall() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.press(.no)
    s.press(.close)
    s.hold([Self.zoom(.active)], for: 20)
    #expect(s.interaction == .none)
    end(&s)
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom), "the next call asks again")
  }

  @Test("an unanswered prompt closes after 15 seconds as a timeout, not a No")
  func promptTimeout() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.hold([Self.zoom(.active)], for: Policy.promptTimeout)
    #expect(s.interaction == .none)
    #expect(s.answers == [.timeout])
    #expect(!s.commands.contains(.countNo(switchID: "zoom")))
  }

  @Test("one question at a time: a second call waits until the first is answered")
  func oneQuestionAtATime() {
    var s = Story()
    let both = [Self.zoom(.active), Self.chrome(.active, url: Self.meetA)]
    s.read(both)
    guard case .ask(_, let first, _) = s.interaction else {
      Issue.record("no question")
      return
    }
    s.read(both)
    if case .ask(_, let still, _) = s.interaction { #expect(still == first) }
    s.press(.no)
    // The next question replaces the tip at once.
    guard case .ask(_, let second, _) = s.interaction else {
      Issue.record("the second call was never asked about")
      return
    }
    #expect(second != first)
  }

  @Test("the question goes away when its call ends or its app is switched off, not on a blip")
  func questionWithdrawn() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.read([Self.zoom(.unknown)])
    s.read([Self.zoom(.inactive)])
    #expect(isAsk(s.interaction, .zoom), "one off reading is a blip")
    s.hold([Self.zoom(.inactive)], for: 2)
    #expect(s.interaction == .none)
    #expect(s.answers.isEmpty, "a withdrawn question is not a timeout")
    var off = Story()
    off.read([Self.zoom(.active)])
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
    s.read([Self.zoom(.inactive)])
    s.wait(5)
    s.step()
    #expect(!isCountdown(s.interaction), "time alone with one reading")
    var t = recordingZoom()
    t.read([Self.zoom(.inactive)])
    t.wait(0.5)
    t.read([Self.zoom(.inactive)])
    #expect(!isCountdown(t.interaction), "two readings inside the confirm time")
  }

  @Test("the microphone coming back during the countdown cancels it")
  func returnCancelsCountdown() {
    var s = recordingZoom()
    end(&s)
    #expect(isCountdown(s.interaction))
    s.read([Self.zoom(.active)])
    #expect(s.interaction == .none)
    s.hold([Self.zoom(.active)], for: 20)
    #expect(s.stops == 0)
  }

  @Test("an incomplete, stale, ambiguous or unknown reading restarts the end count")
  func uncertaintyRestartsTheEnd() {
    let breaks: [(inout Story) -> Void] = [
      { $0.read([], complete: false) },
      { $0.read([Self.zoom(.inactive)], ambiguous: true) },
      { $0.read([Self.zoom(.unknown)]) },
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

  @Test("a missing process in a complete reading has left; a failed read is not that")
  func missingVersusFailed() {
    var s = recordingZoom()
    end(&s, [])
    #expect(isCountdown(s.interaction), "the app quit")
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
    s.hold([Self.zoom(.inactive)], for: 4)
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
    s.read([Self.zoom(.active)])
    #expect(isSwitch(s.interaction))
    s.press(.no)
    end(&s)
    s.hold([Self.zoom(.inactive)], for: 20)
    #expect(s.stops == 0)
    #expect(s.answers == [.switchNo])
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
    t.read([Self.zoom(.inactive), Self.chrome(.active, url: Self.meetA)])
    t.stopFinished()
    #expect(isAsk(t.interaction, .googleMeet), "the newer question keeps the panel")
  }

  // MARK: - Starts and switches

  @Test("a start that fails, is refused or needs attention says so; superseded asks again")
  func startOutcomes() {
    for (result, expected) in [
      (Policy.StartResult.couldNotStart, Policy.Note.couldNotStart),
      (.needsAttention, .needsAttention),
    ] {
      var s = Story()
      s.read([Self.zoom(.active)])
      s.press(.yes)
      s.startFinished(result)
      #expect(note(s.interaction) == expected)
    }
    var s = Story()
    s.read([Self.zoom(.active)])
    s.press(.yes)
    s.startFinished(.superseded)
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom), "a superseded Start is asked about again")
  }

  @Test("a start in flight is never dropped: uncertainty keeps it wanted, success records")
  func startNotDropped() {
    var s = Story()
    s.read([Self.zoom(.active)])
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
    s.read([Self.zoom(.active)])
    s.press(.yes)
    s.meeting = .busy
    #expect(s.policy.isStartWanted(s.context))
    s.appsOff = ["zoom"]
    s.step()
    #expect(!s.policy.isStartWanted(s.context))
    var off = Story()
    off.read([Self.zoom(.active)])
    off.press(.yes)
    off.meeting = .busy
    off.mode = .off
    off.step()
    #expect(!off.policy.isStartWanted(off.context))
  }

  @Test("a late start result after a newer question settles its call but keeps the question")
  func lateStartKeepsQuestion() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.press(.yes)
    s.meeting = .busy
    s.read([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    #expect(s.interaction == .none, "no question while the start runs")
    s.meeting = .idle
    s.startFinished(.couldNotStart)
    #expect(isAsk(s.interaction, .googleMeet), "the next call's question owns the panel")
    s.press(.close)
    s.hold([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)], for: 4)
    #expect(s.interaction == .none, "the failed call is not asked about again")
  }

  @Test("switch Yes stops the old meeting, then starts the new call")
  func switchYes() {
    var s = recordingZoom()
    let both = [Self.zoom(.active), Self.chrome(.active, url: Self.meetA)]
    s.read(both)
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
    s.read([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    s.startBlocked = true
    s.press(.yes)
    #expect(s.stops == 0)
    #expect(note(s.interaction) == .needsAttention)
  }

  @Test("a switch whose new call is not confirmed after the stop says so and offers a Start")
  func switchNotConfirmed() {
    var s = recordingZoom()
    s.read([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
    s.press(.yes)
    s.read([Self.zoom(.active), Self.chromeUnknown(.active)])
    s.stopFinished()
    #expect(s.starts == [.zoom])
    #expect(isStopped(s.interaction, .switchNotConfirmed))
  }

  @Test("a switch question pauses the old meeting's countdown")
  func switchPausesCountdown() {
    var s = recordingZoom()
    end(&s)
    #expect(isCountdown(s.interaction))
    let next = [Self.zoom(.inactive), Self.chrome(.active, url: Self.meetA)]
    s.read(next)
    #expect(isSwitch(s.interaction))
    s.hold(next, for: Policy.countdownLength + 2)
    #expect(s.stops == 0)
    s.press(.no)
    s.hold(next, for: 4)
    #expect(isCountdown(s.interaction), "after No it counts down in view")
  }

  @Test("a switch question becomes Record this call? once the recording stops from the menu")
  func switchBecomesAsk() {
    var s = recordingZoom()
    s.read([Self.zoom(.active), Self.chrome(.active, url: Self.meetA)])
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
    s.read([Self.chrome(.active, url: Self.meetA, pid: 1), Self.chrome(.active, url: Self.meetA, pid: 2)])
    s.press(.no)
    s.press(.close)
    s.read([Self.chrome(.inactive, url: nil, pid: 1), Self.chrome(.active, url: Self.meetA, pid: 3)])
    #expect(s.interaction == .none)
  }

  @Test("another tab never ends a browser meeting; only every Chrome process off does")
  func browserTabChange() {
    var s = Story()
    s.read([Self.chrome(.active, url: Self.meetA)])
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    s.hold([Self.chrome(.active, url: "https://mail.google.com/")], for: 20)
    #expect(s.stops == 0)
    #expect(s.interaction == .none)
    s.read([Self.chromeUnknown(.active)])
    #expect(s.interaction == .none, "an unreadable page changes nothing")
    end(&s, [Self.chromeUnknown(.inactive)])
    #expect(isCountdown(s.interaction), "Chrome off the microphone ends it, whatever the page")
  }

  @Test("another meeting's page asks to switch and keeps the recorded meeting")
  func browserOtherMeeting() {
    var s = Story()
    s.read([Self.chrome(.active, url: Self.meetA)])
    s.press(.yes)
    s.startFinished(.recording(meetingID: UUID()))
    s.read([Self.chrome(.active, url: Self.meetB)])
    #expect(isSwitch(s.interaction))
    s.press(.no)
    s.hold([Self.chrome(.active, url: Self.meetB)], for: 20)
    #expect(s.stops == 0)
  }

  @Test("Off mode forgets every call; the same app is asked about again after")
  func offForgets() {
    var s = Story()
    s.read([Self.zoom(.active)])
    s.press(.no)
    s.mode = .off
    s.step()
    s.mode = .ask
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom))
  }

  @Test("a question about one meeting goes when the browser shows another; that one is asked")
  func movedQuestion() {
    var s = Story()
    s.read([Self.chrome(.active, url: Self.meetA)])
    guard case .ask(let first, _, _) = s.interaction else {
      Issue.record("no question")
      return
    }
    s.read([Self.chrome(.active, url: "https://mail.google.com/")])
    if case .ask(let still, _, _) = s.interaction { #expect(still == first, "a page that is no meeting keeps it") }
    s.read([Self.chrome(.active, url: Self.meetB)])
    guard case .ask(let second, .googleMeet, _) = s.interaction else {
      Issue.record("the new meeting was not asked about")
      return
    }
    #expect(second != first)
  }

  @Test("a call confirmed over while its Start runs makes the Start unwanted")
  func endedWhileStarting() {
    var s = Story()
    s.read([Self.zoom(.active)])
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
    s.read([Self.zoom(.active)])
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
    s.read([Self.zoom(.active)])
    s.wait(Policy.promptTimeout - 0.5)
    let token = s.policy.token
    s.policy.claim(token: token)
    s.wait(1)
    s.read([Self.zoom(.active)])
    #expect(isAsk(s.interaction, .zoom), "the claimed question stays")
    s.press(.yes, token: token)
    #expect(s.starts == [.zoom])
    #expect(!s.answers.contains(.timeout))
    var ended = Story()
    ended.read([Self.zoom(.active)])
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
    #expect(CallMeetingURL.classify("https://acme.webex.com/meet/jdoe")?.family == .webex)
    #expect(
      CallMeetingURL.classify("https://acme.webex.com/acme/j.php?MTID=m123")?.family == .webex)
    #expect(CallMeetingURL.classify("https://www.webex.com/pricing.html") == nil)
    #expect(
      CallMeetingURL.classify("https://acme.webex.com/acme/j.php?MTID=m123&siteurl=acme")?.room
        == CallMeetingURL.classify("https://acme.webex.com/acme/j.php?siteurl=acme&MTID=m123")?.room)
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
}
