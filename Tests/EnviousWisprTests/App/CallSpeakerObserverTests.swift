import Darwin
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

#if DEBUG
  // Uses DEBUG-only test seams (deliveriesForTesting).
  /// #4013 chunk 13A: when these fail, live speaker capture runs two copies at once, keeps
  /// reading while the user dictates, adds a reading that arrived after Stop, saves after a
  /// meeting was deleted, misses its final save before the transcript is made, or reads a call
  /// for a meeting started by hand.
  ///
  /// Copies are SYNTHETIC Google Meet pages in the captured Chrome shape (tile `oZRSLe`, talker
  /// `kssMZb`); the rules are the bundled file; storage and processing are the real coordinator
  /// with stand-in recorder and job.
  @MainActor
  @Suite("Live speaker capture", .tags(.productOutcome), .timeLimit(.minutes(1)))
  struct CallSpeakerObserverTests {
    typealias Harness = MeetingCoordinatorTests.Harness

    /// Polls: the conditions read counters the capture queue writes, which Observation never
    /// reports.
    private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
      #expect(await waitUntil(deadlineMs: 10_000, condition), "\(label)")
    }

    private static func bundled() throws -> TalkerRulesSnapshot {
      try TalkerRulesSnapshot(
        validating: Data(
          contentsOf: RepoRoot.url.appending(
            path: "Sources/EnviousWisprServices/Resources/talker-rules.json")), origin: .bundled)
    }

    /// A copy of one Meet page with Alex talking and Priya quiet, read now.
    nonisolated static func meetCopy(talking: String = "Alex Rivera") -> CallAXCapture {
      func tile(_ name: String) -> CallAXNode {
        CallAXNode(
          role: "AXGroup", domClassList: ["oZRSLe"],
          children: [
            CallAXNode(role: "AXStaticText", value: name),
            CallAXNode(role: "AXGroup", domClassList: name == talking ? ["kssMZb", "BlxGDf"] : []),
          ])
      }
      let page = CallAXNode(role: "AXWebArea", children: [tile("Alex Rivera"), tile("Priya Shah")])
      let now = mach_absolute_time()
      return CallAXCapture(
        windows: [
          CallAXWindow(title: "Meet", root: CallAXNode(role: "AXWindow", children: [page]))
        ],
        documents: [CallAXDocument(url: "https://meet.google.com/abc-defg-hij", root: page)],
        completeness: .complete, readStartHostTime: now, readEndHostTime: now)
    }

    /// A capture whose calls are counted and, while `hold` is set, wait for `release`.
    final class Capture: Sendable {
      let calls = OSAllocatedUnfairLock(initialState: 0)
      let hold = OSAllocatedUnfairLock(initialState: false)
      let release = DispatchSemaphore(value: 0)

      func take() -> CallAXCapture {
        calls.withLock { $0 += 1 }
        // deadline-fallback: bound a missing release; the test fails on its own expectations
        if hold.withLock({ $0 }) { _ = release.wait(timeout: .now() + 10) }
        return CallSpeakerObserverTests.meetCopy()
      }

      func letGo() {
        hold.withLock { $0 = false }
        release.signal()
      }
    }

    /// Dictation as Observation sees it, like `LiveRecordingState.isDictationActive`.
    @Observable @MainActor
    final class Dictation {
      var idle = true
    }

    /// The facts the observer reads at each tick and again at delivery.
    @MainActor
    final class World {
      /// Read by a `@Sendable` dependency, so behind a lock.
      let trustedLock = OSAllocatedUnfairLock(initialState: true)
      var trusted: Bool {
        get { trustedLock.withLock { $0 } }
        set { trustedLock.withLock { $0 = newValue } }
      }
      var target: CallSpeakerTarget? = CallSpeakerTarget(pid: 1, rule: .browser(.chrome))
      var sourceRevision = 0
    }

    private func observer(
      capture: Capture, dictation: Dictation = Dictation(), world: World = World(),
      lane: CallSpeakerObserver.Lane = .init()
    ) throws -> CallSpeakerObserver {
      let trusted = world.trustedLock
      return CallSpeakerObserver(
        surface: .meet, anchor: 0, startMs: 0, rules: try Self.bundled(),
        presencePolicy: .current, lag: CallSpeakerLag(milliseconds: 500),
        dependencies: .init(
          binding: {
            world.target.map {
              CallCaptureBinding(
                source: .init(family: .googleMeet, target: $0), surface: .meet, generation: 1,
                mute: false)
            }
          },
          sourceRevision: { world.sourceRevision },
          capture: { _, _ in capture.take() }, muteRules: .testPackaged,
          isTrusted: { trusted.withLock { $0 } },
          isDictationIdle: { dictation.idle }, lane: lane))
    }

    @Test("one copy at a time: ticks while a copy is being taken take none")
    func oneCopyAtATime() async throws {
      let capture = Capture()
      capture.hold.withLock { $0 = true }
      let lane = CallSpeakerObserver.Lane()
      let observer = try observer(capture: capture, lane: lane)
      observer.tick()
      await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
      observer.tick()
      observer.tick()
      #expect(capture.calls.withLock { $0 } == 1)
      capture.letGo()
      await eventually("copy landed") { observer.currentSegment?.observations.count == 1 }
      #expect(observer.currentSegment?.observations.map(\.speaking) == [["Alex Rivera"]])
      #expect(observer.currentSegment?.lag?.milliseconds == 500)
      #expect(observer.currentSegment?.surface == .meet)
      observer.tick()
      await eventually("second copy") { observer.currentSegment?.observations.count == 2 }
    }

    @Test("a copy still blocked from an ended recording keeps a new recording from starting one")
    func sharedLane() async throws {
      let lane = CallSpeakerObserver.Lane()
      let old = Capture()
      old.hold.withLock { $0 = true }
      let ended = try observer(capture: old, lane: lane)
      ended.tick()
      await eventually("old copy started") { old.calls.withLock { $0 } == 1 }
      ended.closeAdmission()
      let fresh = Capture()
      let next = try observer(capture: fresh, lane: lane)
      next.tick()
      #expect(fresh.calls.withLock { $0 } == 0, "no second copy while the old one is blocked")
      old.letGo()
      await eventually("lane free") { !lane.isBusy }
      next.tick()
      await eventually("new copy") { next.currentSegment?.observations.count == 1 }
      #expect(ended.currentSegment?.observations.isEmpty == true)
    }

    @Test("dictation that starts and ends while a copy is taken drops that copy, with no tick")
    func dictationBetweenTicks() async throws {
      let capture = Capture()
      capture.hold.withLock { $0 = true }
      let dictation = Dictation()
      let observer = try observer(capture: capture, dictation: dictation)
      observer.tick()
      await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
      dictation.idle = false
      dictation.idle = true
      capture.letGo()
      await eventually("copy delivered") { observer.deliveriesForTesting == 1 }
      #expect(observer.currentSegment?.observations.isEmpty == true)
      observer.tick()
      await eventually("next copy counts") { observer.currentSegment?.observations.count == 1 }
    }

    @Test("no copy is taken while dictating")
    func noCopyWhileDictating() async throws {
      let capture = Capture()
      let dictation = Dictation()
      dictation.idle = false
      let observer = try observer(capture: capture, dictation: dictation)
      observer.tick()
      #expect(capture.calls.withLock { $0 } == 0)
      dictation.idle = true
      observer.tick()
      await eventually("copy after dictation") { observer.currentSegment?.observations.count == 1 }
    }

    @Test("a copy whose app instance changed or whose trust was lost before delivery adds nothing")
    func sourceAndTrustAtDelivery() async throws {
      for change in ["target", "trust", "source that went and came back"] {
        let capture = Capture()
        capture.hold.withLock { $0 = true }
        let world = World()
        let observer = try observer(capture: capture, world: world)
        observer.tick()
        await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
        switch change {
        case "target": world.target = CallSpeakerTarget(pid: 2, rule: .browser(.chrome))
        case "trust": world.trusted = false
        default:
          // The call app left the microphone and came back: same target, newer revision.
          world.sourceRevision += 2
        }
        capture.letGo()
        await eventually("copy delivered") { observer.deliveriesForTesting == 1 }
        #expect(observer.currentSegment?.observations.isEmpty == true, "\(change)")
      }
    }

    /// #4013 reading resilience §3.4: the read health `meeting.ended` reports is summed from
    /// what each delivered copy tolerated.
    @Test("each delivered copy's tolerated failures add up in the segment's health")
    func toleratedFailuresAccumulate() async throws {
      let base = Self.meetCopy()
      let copy = CallAXCapture(
        windows: base.windows, documents: base.documents, completeness: .complete,
        readStartHostTime: base.readStartHostTime, readEndHostTime: base.readEndHostTime,
        failedReads: 3, toleratedFailures: 2)
      let copies = Copies([copy])
      let trusted = World().trustedLock
      let observer = CallSpeakerObserver(
        surface: .meet, anchor: 0, startMs: 0, rules: try Self.bundled(),
        presencePolicy: .current, lag: CallSpeakerLag(milliseconds: 500),
        dependencies: .init(
          binding: {
            CallCaptureBinding(
              source: .init(
                family: .googleMeet, target: CallSpeakerTarget(pid: 1, rule: .browser(.chrome))),
              surface: .meet, generation: 1, mute: false)
          },
          capture: { _, _ in copies.take() }, muteRules: .testPackaged, isTrusted: { trusted.withLock { $0 } },
          isDictationIdle: { true }, lane: .init()))
      observer.tick()
      await eventually("first copy delivered") { observer.deliveriesForTesting == 1 }
      observer.tick()
      await eventually("second copy delivered") { observer.deliveriesForTesting == 2 }
      let health = try #require(observer.currentSegment?.health)
      #expect(health.toleratedFailures == 4)
      #expect(health.failedReads == 6)
      #expect(health.captureAttempts == 2)
    }

    /// A Teams app copy whose People list (count-checked) shows `names`, read at `ms` on the
    /// recording clock (anchor 0).
    nonisolated static func teamsCopy(_ names: [String], atMs ms: Int) -> CallAXCapture {
      let rows = names.map { CallAXNode(role: "AXRow", description: "\($0), Attendee, Muted") }
      let count = CallAXNode(role: "AXStaticText", value: "In this meeting, \(names.count) total")
      let base = CallSpeakerTimeline.liveTimebase
      let host = UInt64(Double(ms) * 1_000_000 * Double(base.denom) / Double(base.numer))
      return CallAXCapture(
        windows: [
          CallAXWindow(
            title: "Meeting with Saurabh Vaish",
            root: CallAXNode(role: "AXWindow", children: [count] + rows))
        ], documents: [], completeness: .complete, readStartHostTime: host, readEndHostTime: host)
    }

    /// Hands out prepared copies in order, the last one repeated.
    final class Copies: Sendable {
      let list: OSAllocatedUnfairLock<[CallAXCapture]>
      init(_ list: [CallAXCapture]) { self.list = OSAllocatedUnfairLock(initialState: list) }
      func take() -> CallAXCapture {
        list.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
      }
    }

    private func teamsObserver(
      _ copies: Copies, dictation: Dictation
    ) throws -> CallSpeakerObserver {
      CallSpeakerObserver(
        surface: .teamsApp, anchor: 0, startMs: 0, rules: try Self.bundled(),
        presencePolicy: .current, lag: CallSpeakerLag(milliseconds: 0),
        dependencies: .init(
          binding: {
            CallCaptureBinding(
              source: .init(
                family: .teams, target: CallSpeakerTarget(pid: 1, rule: .callApp(.teams))),
              surface: .teamsApp, generation: 1, mute: false)
          },
          capture: { _, _ in copies.take() }, muteRules: .testPackaged, isTrusted: { true },
          isDictationIdle: { dictation.idle }, lane: .init()))
    }

    @Test(
      "a whole dictation, or a moment on another call, between two ticks breaks a run of missing lists"
    )
    func interruptionBetweenTicksBreaksPresence() async throws {
      enum Between { case nothing, dictation, otherCall }
      func run(_ between: Between) async throws -> CallNamePresence? {
        let copies = Copies([
          Self.teamsCopy(["Alex Rivera", "Priya Shah"], atMs: 1_000),
          Self.teamsCopy(["Alex Rivera"], atMs: 1_500),
          Self.teamsCopy(["Alex Rivera"], atMs: 2_000),
          Self.teamsCopy(["Alex Rivera"], atMs: 2_500),
        ])
        let dictation = Dictation()
        let observer = try teamsObserver(copies, dictation: dictation)
        for n in 1...4 {
          if n == 4 {
            switch between {
            case .nothing: break
            case .dictation:
              // Observation reports each change as it happens, before the next tick.
              dictation.idle = false
              dictation.idle = true
            case .otherCall:
              // The session saw another answer for a moment and told the segment at once.
              observer.noteSourceInterruption()
            }
          }
          observer.tick()
          await eventually("copy \(n) delivered") { observer.deliveriesForTesting == n }
        }
        return observer.currentSegment?.presence?.first { $0.name == "Priya Shah" }
      }
      #expect(try await run(.nothing)?.absences.count == 1, "control: the run confirms")
      #expect(try await run(.dictation)?.absences.isEmpty == true)
      #expect(try await run(.otherCall)?.absences.isEmpty == true)
    }

    // MARK: - With a recording

    /// The live call, as a test sets it.
    @MainActor
    final class Sources: CallSpeakerSources {
      var answer: CallSpeakerSourceAnswer
      var speakerSourceRevision = 0
      private(set) var demand = 0
      init(_ answer: CallSpeakerSourceAnswer) { self.answer = answer }
      func beginRecordingDemand() { demand += 1 }
      func endRecordingDemand() { demand -= 1 }
      func speakerSource() -> CallSpeakerSourceAnswer { answer }
    }

    static let meetCall = CallSpeakerSourceAnswer.unique(
      .init(family: .googleMeet, target: CallSpeakerTarget(pid: 1, rule: .browser(.chrome))))

    /// A coordinator whose recordings read `sources`' live call through `capture`.
    /// `rulesGate`, when given, holds the rules read until it yields.
    private func coordinator(
      _ harness: Harness, capture: Capture, sources: Sources = Sources(meetCall),
      rulesGate: AsyncStream<Void>? = nil, muteFollowing: @escaping @MainActor () -> Bool = { true }
    ) throws -> MeetingCoordinator {
      let rules = try Self.bundled()
      var deps = harness.dependencies()
      deps.muteFollowingEnabled = muteFollowing
      deps.callSources = sources
      // Changes of call settle after one check, so a test need not wait seconds.
      deps.speakerSessionTiming = (.milliseconds(100), .zero, .milliseconds(500))
      deps.talkerRules = {
        if let rulesGate { for await _ in rulesGate { break } }
        return (rules, rules.rules)
      }
      deps.speakerCaptureLane = .init()
      deps.captureCallApp = { _, _, _ in capture.take() }
      deps.muteRules = { .testPackaged }
      deps.isAccessibilityTrusted = { true }
      return MeetingCoordinator(dependencies: deps)
    }

    // MARK: - Mute following (#4248)

    @MainActor
    final class Flag {
      var on: Bool
      init(_ on: Bool) { self.on = on }
    }

    @Test("a recording follows the call's mute button on the writer; Stop queues the end first")
    func recordingFollowsMute() async throws {
      let harness = try Harness()
      let capture = Capture()
      let coordinator = try coordinator(harness, capture: capture)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let recorder = try #require(harness.recorders.first)
      #expect(recorder.clock != nil, "the release clock is installed on the writer")
      #expect(coordinator.muteState == .unbound)
      // A bind, then at least one reading from a copy.
      await eventually("bind and a reading sent") { recorder.steps.count >= 2 }
      recorder.runSteps(now: mach_absolute_time())
      // The synthetic Meet page shows no mute button: bound and checking, nothing silenced.
      await eventually("snapshot landed") { coordinator.muteState == .checking }
      #expect(coordinator.muteCallApp == .googleMeet, "the muted line names the bound call")
      let stepsBeforeStop = recorder.steps.count
      await coordinator.stop(reason: .user)
      #expect(recorder.steps.count > stepsBeforeStop, "Stop sent the end step")
      #expect(recorder.events.last == "stop", "nothing is sent after the recorder stops")
      #expect(recorder.mutedMeter.last == false)
      #expect(coordinator.muteState == nil)
      #expect(coordinator.muteCallApp == nil)
    }

    /// #4013 reading resilience §3.5: the mute rules are frozen when the recording starts, the
    /// copy protects exactly their roles, and a newer download reaches only the next recording,
    /// whether or not names are on.
    @Test("each recording freezes its mute rules for capture protection, names on or off")
    func muteRulesFrozenPerRecording() async throws {
      for namesOn in [true, false] {
        let harness = try Harness()
        let rules = try Self.bundled()
        let newer = try CallMuteRules(
          validating: Data(
            #"{"schema":1,"revision":2,"surfaces":{"meet":{"role":"AXCheckBox","labels":{"Turn on microphone":"muted","Turn off microphone":"unmuted"}}}}"#
              .utf8), origin: .downloaded)
        let current = OSAllocatedUnfairLock(initialState: CallMuteRules.testPackaged)
        let seen = OSAllocatedUnfairLock<[Set<String>]>(initialState: [])
        var deps = harness.dependencies()
        deps.muteFollowingEnabled = { true }
        deps.callSources = Sources(Self.meetCall)
        deps.speakerSessionTiming = (.milliseconds(100), .zero, .milliseconds(100))
        deps.talkerRules = { namesOn ? (rules, rules.rules) : nil }
        deps.muteRules = { current.withLock { $0 } }
        deps.speakerCaptureLane = .init()
        deps.captureCallApp = { _, _, roles in
          seen.withLock { $0.append(roles) }
          return CallSpeakerObserverTests.meetCopy()
        }
        deps.isAccessibilityTrusted = { true }
        let coordinator = MeetingCoordinator(dependencies: deps)

        _ = await coordinator.start(from: .detected, callApp: .googleMeet)
        await eventually("first copy") { seen.withLock { !$0.isEmpty } }
        // A download lands mid-recording: this recording keeps the rules it froze.
        current.withLock { $0 = newer }
        let before = seen.withLock { $0.count }
        await eventually("more copies") { seen.withLock { $0.count } >= before + 2 }
        #expect(seen.withLock { Set($0) } == [["AXButton"]], "names on: \(namesOn)")
        await coordinator.stop(reason: .user)
        await eventually("idle") { coordinator.phase == .idle }

        seen.withLock { $0 = [] }
        _ = await coordinator.start(from: .detected, callApp: .googleMeet)
        await eventually("next recording's copy") { seen.withLock { !$0.isEmpty } }
        #expect(seen.withLock { Set($0) } == [["AXCheckBox"]], "names on: \(namesOn)")
        await coordinator.stop(reason: .user)
      }
    }

    @Test("with mute following off nothing is bound; switching it on binds at once")
    func muteFollowingSwitch() async throws {
      let harness = try Harness()
      let capture = Capture()
      let flag = Flag(false)
      let coordinator = try coordinator(harness, capture: capture, muteFollowing: { flag.on })
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let recorder = try #require(harness.recorders.first)
      #expect(coordinator.muteState == .disabled)
      await eventually("copies taken") { capture.calls.withLock { $0 } >= 1 }
      #expect(recorder.steps.isEmpty, "no binding or reading while off")
      flag.on = true
      coordinator.muteFollowingChanged()
      #expect(recorder.steps.count >= 2, "switched on, then bound, at once")
      recorder.runSteps(now: mach_absolute_time())
      await eventually("snapshot landed") { coordinator.muteState == .checking }
      await coordinator.stop(reason: .user)
    }

    @Test("switching mute following off then on mid-recording reaches the writer each time")
    func muteFollowingOffThenOn() async throws {
      let harness = try Harness()
      let capture = Capture()
      let flag = Flag(true)
      let coordinator = try coordinator(harness, capture: capture, muteFollowing: { flag.on })
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let recorder = try #require(harness.recorders.first)
      await eventually("bind and a reading sent") { recorder.steps.count >= 2 }
      recorder.runSteps(now: mach_absolute_time())
      await eventually("checking") { coordinator.muteState == .checking }
      flag.on = false
      let beforeOff = recorder.steps.count
      coordinator.muteFollowingChanged()
      #expect(recorder.steps.count >= beforeOff + 2, "switched off and unbound, at once")
      recorder.runSteps(now: mach_absolute_time())
      await eventually("disabled") { coordinator.muteState == .disabled }
      #expect(
        MeetingsPresentation.muteLine(coordinator.muteState, callApp: coordinator.muteCallApp) == nil)
      flag.on = true
      let beforeOn = recorder.steps.count
      coordinator.muteFollowingChanged()
      #expect(recorder.steps.count >= beforeOn + 2, "switched on and bound, at once")
      recorder.runSteps(now: mach_absolute_time())
      await eventually("checking again") { coordinator.muteState == .checking }
      await coordinator.stop(reason: .user)
      #expect(recorder.mutedMeter.last == false)
    }

    @Test("a muted line names the call its snapshot was decided for; an older call's cannot overwrite it")
    func muteLineNamesItsOwnCall() async throws {
      let harness = try Harness()
      let capture = Capture()
      let sources = Sources(Self.meetCall)
      let coordinator = try coordinator(harness, capture: capture, sources: sources)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let recorder = try #require(harness.recorders.first)
      // The session binds Meet first, at start, then a Meet reading follows; nothing has run on
      // the writer yet.
      await eventually("Meet bound and read") { coordinator.muteReadingsSentForTesting >= 1 }
      #expect(coordinator.muteCallAppsForTesting == [1: .googleMeet])
      let meetSteps = recorder.steps.count
      sources.answer = .unique(
        .init(family: .teams, target: CallSpeakerTarget(pid: 3, rule: .callApp(.teams))))
      await eventually("Teams bound") { coordinator.muteCallAppsForTesting[2] == .teams }
      let count = recorder.steps.count
      // The Teams binding's steps run first.
      recorder.runSteps(at: Array(meetSteps..<count), now: mach_absolute_time())
      await eventually("Teams snapshot accepted") { coordinator.muteState == .checking }
      #expect(coordinator.muteCallApp == .teams)
      #expect(
        MeetingsPresentation.muteLine(.muted, callApp: coordinator.muteCallApp)
          == "You're muted in Microsoft Teams. Your voice is left out of the notes.")
      // Then the older Meet steps; their reading always publishes a snapshot, for the Meet call.
      let delivered = coordinator.muteSnapshotsDeliveredForTesting
      recorder.runSteps(at: Array(0..<meetSteps), now: mach_absolute_time())
      await eventually("Meet snapshot delivered") {
        coordinator.muteSnapshotsDeliveredForTesting > delivered
      }
      #expect(coordinator.muteCallApp == .teams, "the older Meet snapshot was refused")
      #expect(coordinator.muteState == .checking)
      await coordinator.stop(reason: .user)
    }

    @Test("mute reading starts before the rules arrive; naming attaches to the same capture")
    func muteBeforeRules() async throws {
      let harness = try Harness()
      let capture = Capture()
      let gate = AsyncStream<Void>.makeStream()
      let coordinator = try coordinator(harness, capture: capture, rulesGate: gate.stream)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let recorder = try #require(harness.recorders.first)
      // Rules still held: the bind and readings already flow.
      await eventually("bind and a reading before rules") { recorder.steps.count >= 2 }
      let copiesBeforeRules = capture.calls.withLock { $0 }
      gate.continuation.yield()
      // Naming attaches as soon as the rules land; let two more copies reach it.
      await eventually("copies after the rules") {
        capture.calls.withLock { $0 } >= copiesBeforeRules + 2
      }
      await coordinator.stop(reason: .user)
      await MeetingCoordinatorTests.livePassFinished(coordinator, recorder.configuration.meetingID)
      guard case .usable(let log)? = harness.jobs.last?.receivedCallSpeakers.first else {
        Issue.record("naming did not attach after the rules arrived")
        return
      }
      #expect(log.surface == .meet)
    }

    @Test("a Stop before the held rules return ends mute reading and attaches no naming")
    func stopBeforeRulesWithMute() async throws {
      let harness = try Harness()
      let capture = Capture()
      let gate = AsyncStream<Void>.makeStream()
      let coordinator = try coordinator(harness, capture: capture, rulesGate: gate.stream)
      let outcome = await coordinator.start(from: .detected, callApp: .googleMeet)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      let recorder = try #require(harness.recorders.first)
      #expect(outcome == .recording(meetingID: meetingID))
      await eventually("mute bound before rules") { recorder.steps.count >= 1 }
      await coordinator.stop(reason: .user)
      let copiesAtStop = capture.calls.withLock { $0 }
      gate.continuation.yield()
      await eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
      try await Task.sleep(for: .milliseconds(1_200))
      #expect(capture.calls.withLock { $0 } == copiesAtStop, "no copy after Stop")
      #expect(recorder.events.last == "stop", "nothing sent after the recorder stopped")
      #expect(coordinator.muteState == nil)
    }

    @Test("a recording started for a Meet call saves its evidence before the transcript is made")
    func detectedRecordingSavesEvidence() async throws {
      let harness = try Harness()
      let capture = Capture()
      let coordinator = try coordinator(harness, capture: capture)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
      await coordinator.stop(reason: .user)
      await eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      guard case .usable(let log)? = harness.jobs.last?.receivedCallSpeakers.first else {
        Issue.record("the pass did not receive saved evidence")
        return
      }
      #expect(log.surface == .meet)
      #expect(log.source == .rules)
      #expect(log.status == .observed)
      #expect(log.lag?.milliseconds == 500)
      #expect(!log.observations.isEmpty)
      #expect(log.observations.allSatisfy { $0.speaking == ["Alex Rivera"] })
      let taken = capture.calls.withLock { $0 }
      // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
      try await Task.sleep(for: .milliseconds(1_200))
      #expect(capture.calls.withLock { $0 } == taken, "no copy after Stop")
    }

    @Test("a meeting started by hand reads the live call too, through the same session")
    func handStartReadsLiveCall() async throws {
      let harness = try Harness()
      let capture = Capture()
      let sources = Sources(Self.meetCall)
      let coordinator = try coordinator(harness, capture: capture, sources: sources)
      _ = await coordinator.start(from: .history)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
      #expect(sources.demand == 1, "discovery is kept watching while it records")
      await coordinator.stop(reason: .user)
      await eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      #expect(sources.demand == 0)
      guard case .usable(let log)? = harness.jobs.last?.receivedCallSpeakers.first else {
        Issue.record("the pass did not receive saved evidence")
        return
      }
      #expect(log.segments.count == 1)
      #expect(log.segments.first?.endReason == .recordingEnded)
      #expect(log.segments.first?.observations.isEmpty == false)
    }

    @Test("a recording with no call saves evidence with no segment; a call joined later is read")
    func lateCall() async throws {
      let harness = try Harness()
      let capture = Capture()
      let sources = Sources(.none)
      let coordinator = try coordinator(harness, capture: capture, sources: sources)
      _ = await coordinator.start(from: .menu)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      // settle: absence check; the session checks every 100 ms
      try await Task.sleep(for: .milliseconds(300))
      #expect(capture.calls.withLock { $0 } == 0, "no call: nothing is read")
      sources.answer = Self.meetCall
      await eventually("the late call is read") { capture.calls.withLock { $0 } >= 2 }
      await coordinator.stop(reason: .user)
      await eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      guard case .usable(let log)? = harness.jobs.last?.receivedCallSpeakers.first else {
        Issue.record("the pass did not receive saved evidence")
        return
      }
      #expect(log.segments.count == 1)
      #expect((log.segments.first?.startMs ?? 0) > 0, "the segment starts when the call was found")
    }

    @Test("deleting a recording stops its capture and leaves no evidence file")
    func deleteStopsCapture() async throws {
      let harness = try Harness()
      let capture = Capture()
      let coordinator = try coordinator(harness, capture: capture)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      await eventually("copies taken") { capture.calls.withLock { $0 } >= 1 }
      #expect(await coordinator.delete(meetingID: meetingID))
      let taken = capture.calls.withLock { $0 }
      // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
      try await Task.sleep(for: .milliseconds(1_200))
      #expect(capture.calls.withLock { $0 } == taken)
      #expect(
        !FileManager.default.fileExists(atPath: harness.store.callSpeakersURL(for: meetingID).path))
    }

    @Test("a Stop while the rules are read leaves the recording stopped and starts no capture")
    func stopWhileRulesLoad() async throws {
      let harness = try Harness()
      let capture = Capture()
      let gate = AsyncStream<Void>.makeStream()
      // Mute following off: with it on, mute reading starts before the rules (tested below).
      let coordinator = try coordinator(
        harness, capture: capture, rulesGate: gate.stream, muteFollowing: { false })
      let outcome = await coordinator.start(from: .detected, callApp: .googleMeet)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      #expect(outcome == .recording(meetingID: meetingID), "Start does not wait for the rules")
      await coordinator.stop(reason: .user)
      gate.continuation.yield()
      await eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
      try await Task.sleep(for: .milliseconds(1_200))
      #expect(capture.calls.withLock { $0 } == 0)
      #expect(coordinator.phase == .idle)
    }

    @Test("a final speaker save that failed at Stop is saved by a quit once storage works again")
    func failedFinalSaveSavedAtQuit() async throws {
      let harness = try Harness()
      let capture = Capture()
      let coordinator = try coordinator(harness, capture: capture)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
      // A folder where the file goes makes every save of it fail.
      let url = harness.store.callSpeakersURL(for: meetingID)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      await coordinator.stop(reason: .user)
      await eventually("ready") {
        coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
      }
      try FileManager.default.removeItem(at: url)
      coordinator.prepareForTermination(deadline: .now() + 2)
      guard case .usable(let log) = harness.store.loadCallSpeakers(meeting: meetingID) else {
        Issue.record("quit did not save the final log the failed Stop kept")
        return
      }
      #expect(!log.observations.isEmpty)
    }

    @Test("quit while recording saves the speaker log collected so far, within the quit deadline")
    func quitSavesFinalLog() async throws {
      let harness = try Harness()
      let capture = Capture()
      let coordinator = try coordinator(harness, capture: capture)
      _ = await coordinator.start(from: .detected, callApp: .googleMeet)
      let meetingID = try #require(harness.recorders.first).configuration.meetingID
      await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
      // settle: lets the last copy's delivery reach the main actor
      try await Task.sleep(for: .milliseconds(100))
      coordinator.prepareForTermination(deadline: .now() + 2)
      guard case .usable(let log) = harness.store.loadCallSpeakers(meeting: meetingID) else {
        Issue.record("quit saved no speaker log")
        return
      }
      #expect(!log.observations.isEmpty)
      #expect(log.observations.allSatisfy { $0.speaking == ["Alex Rivera"] })
    }
  }
#endif
