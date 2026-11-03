import Darwin
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

#if DEBUG
  // Uses DEBUG-only test seams.
  /// #4013 13B.4: when these fail, a recording reads the wrong call after the user switches
  /// calls, splits one call into pieces on a brief flicker, keeps reading when two calls compete,
  /// saves after Stop, delete or quit, loses its final names when a save fails, stops saving while
  /// no call is read, grows past what a saved log may hold, or leaves the microphone watcher
  /// running after the recording ended.
  ///
  /// The live call is a stand-in (`CallSpeakerObserverTests.Sources`) and the clock is a test
  /// clock; copies are the SYNTHETIC Meet page of `CallSpeakerObserverTests`. Session and observer
  /// checks run only when a test asks (their loops sleep for an hour).
  @MainActor
  @Suite("Speaker session", .tags(.productOutcome), .timeLimit(.minutes(1)))
  struct CallSpeakerSessionTests {
    typealias Sources = CallSpeakerObserverTests.Sources

    private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
      #expect(await waitUntil(deadlineMs: 10_000, condition), "\(label)")
    }

    /// The recording clock in milliseconds, as host time.
    final class Clock: Sendable {
      let ms = OSAllocatedUnfairLock(initialState: 0)
      func host() -> UInt64 {
        let base = CallSpeakerTimeline.liveTimebase
        return UInt64(Double(ms.withLock { $0 }) * 1e6 * Double(base.denom) / Double(base.numer))
      }
    }

    private static let meet = CallSpeakerObserverTests.meetCall
    private static let zoom = CallSpeakerSourceAnswer.unique(
      .init(family: .zoom, target: CallSpeakerTarget(pid: 2, rule: .callApp(.zoom))))

    private func session(
      _ sources: Sources, clock: Clock, settleMs: Int = 2_000, tick: Duration = .seconds(3_600),
      saved: @escaping @MainActor (CallSpeakerLog) async throws -> Void = { _ in }
    ) throws -> CallSpeakerSession {
      let rules = try TalkerRulesSnapshot(
        validating: Data(
          contentsOf: RepoRoot.url.appending(
            path: "Sources/EnviousWisprServices/Resources/talker-rules.json")), origin: .bundled)
      return CallSpeakerSession(
        anchor: 0, rules: rules, bundled: rules.rules,
        dependencies: .init(
          sources: sources,
          // The SYNTHETIC Meet page, read at the test clock's time.
          capture: { _, _, _ in
            let page = CallSpeakerObserverTests.meetCopy()
            let host = clock.host()
            return CallAXCapture(
              windows: page.windows, documents: page.documents, completeness: .complete,
              readStartHostTime: host, readEndHostTime: host)
          },
          muteRules: .testPackaged, isTrusted: { true }, isDictationIdle: { true },
          save: { try await saved($0) },
          lane: .init(), hostTime: { clock.host() }, tick: tick,
          settle: .milliseconds(settleMs), observerTick: .seconds(3_600), saveEvery: 2))
    }

    /// One observer tick and its copy delivered.
    private func read(_ session: CallSpeakerSession) async {
      guard let observer = session.currentObserverForTesting else { return }
      let before = observer.deliveriesForTesting
      observer.tick()
      await eventually("copy delivered") { observer.deliveriesForTesting > before }
    }

    @Test("a different call that lasts the settle time ends the segment and starts the next")
    func switchCalls() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let session = try session(sources, clock: clock)
      clock.ms.withLock { $0 = 1_000 }
      session.start()
      await read(session)
      clock.ms.withLock { $0 = 5_000 }
      sources.answer = Self.zoom
      session.check()
      clock.ms.withLock { $0 = 6_000 }
      session.check()
      #expect(session.currentLog?.segments.count == 1, "a one-second change is not a switch")
      clock.ms.withLock { $0 = 7_000 }
      session.check()
      let log = try #require(session.currentLog)
      #expect(log.segments.count == 2)
      #expect(log.segments[0].surface == .meet)
      #expect(log.segments[0].endMs == 7_000)
      #expect(log.segments[0].endReason == .sourceChanged)
      #expect(log.segments[1].surface == .zoomApp)
      #expect(log.segments[1].startMs == 7_000)
      #expect(log.shapeProblem == nil)
    }

    @Test("a flicker shorter than the settle time keeps one segment")
    func flicker() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let session = try session(sources, clock: clock)
      session.start()
      clock.ms.withLock { $0 = 1_000 }
      sources.answer = .unavailable
      session.check()
      clock.ms.withLock { $0 = 2_500 }
      sources.answer = Self.meet
      session.check()
      clock.ms.withLock { $0 = 5_000 }
      session.check()
      #expect(session.currentLog?.segments.count == 1)
      #expect(session.currentLog?.segments[0].endMs == nil)
    }

    @Test("two competing calls end the segment and read nothing until one call remains")
    func ambiguity() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let session = try session(sources, clock: clock)
      session.start()
      await read(session)
      sources.answer = .ambiguous
      clock.ms.withLock { $0 = 1_000 }
      session.check()
      // While two calls compete, this segment's copies are refused before they start.
      #expect(session.currentObserverForTesting.map { _ in true } == true)
      clock.ms.withLock { $0 = 3_000 }
      session.check()
      #expect(session.currentObserverForTesting == nil)
      #expect(session.currentLog?.segments.map(\.endReason) == [.sourceLost])
      sources.answer = Self.meet
      clock.ms.withLock { $0 = 4_000 }
      session.check()
      #expect(session.currentLog?.segments.count == 2, "one call again: read at once")
      #expect(session.currentLog?.sessionHealth?.ambiguousSources == 2)
    }

    @Test("finish saves once with the segment ended at Stop; a copy after Stop adds nothing")
    func finish() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      var saves: [CallSpeakerLog] = []
      let session = try session(sources, clock: clock, saved: { saves.append($0) })
      session.start()
      #expect(sources.demand == 1)
      await read(session)
      clock.ms.withLock { $0 = 8_000 }
      session.closeAdmission()
      clock.ms.withLock { $0 = 9_000 }
      #expect(await session.finish())
      #expect(saves.count == 1)
      #expect(saves.last?.segments.last?.endMs == 8_000, "ended where Stop was pressed")
      #expect(saves.last?.segments.last?.endReason == .recordingEnded)
      #expect(sources.demand == 0, "discovery is released")
      #expect(await session.finish())
      #expect(saves.count == 1, "saved once")
      #expect(session.takeFinalLog() == nil, "quit after the final save has nothing to save")
    }

    @Test("cancel saves nothing and releases discovery")
    func cancel() async throws {
      let sources = Sources(Self.meet)
      var saves = 0
      let session = try session(sources, clock: Clock(), saved: { _ in saves += 1 })
      session.start()
      session.cancel()
      #expect(!(await session.finish()))
      #expect(saves == 0)
      #expect(session.takeFinalLog() == nil)
      #expect(sources.demand == 0)
    }

    @Test("a final save that failed leaves the final log for a quit to take")
    func failedFinalSave() async throws {
      struct Refused: Error {}
      let sources = Sources(Self.meet)
      let session = try session(sources, clock: Clock(), saved: { _ in throw Refused() })
      session.start()
      await read(session)
      #expect(!(await session.finish()))
      let final = session.takeFinalLog()
      #expect(final?.segments.first?.observations.isEmpty == false)
      #expect(final?.sessionHealth?.saveFailures == 1)
      #expect(session.takeFinalLog() == nil, "handed over once")
    }

    @Test("a quit while Stop waits on a periodic save takes the final log; Stop then saves none")
    func quitDuringFinish() async throws {
      let gate = AsyncStream<Void>.makeStream()
      var saves = 0
      let sources = Sources(Self.meet)
      let session = try session(
        sources, clock: Clock(),
        saved: { _ in
          saves += 1
          if saves == 1 { for await _ in gate.stream { break } }
        })
      session.start()
      await read(session)
      let observer = try #require(session.currentObserverForTesting)
      session.saveNowForTesting()
      await eventually("periodic save parked") { saves == 1 }
      let stopping = Task { await session.finish() }
      await eventually("Stop is waiting") { observer.open == false }
      let final = session.takeFinalLog()
      #expect(final?.segments.first?.observations.count == 1)
      gate.continuation.yield()
      #expect(await stopping.value, "handed to the quit")
      #expect(saves == 1, "Stop saved nothing after quit took the final log")
    }

    @Test("a save asked for by a call change never runs after delete or quit took over")
    func noSaveAfterCancelOrQuit() async throws {
      for quit in [false, true] {
        let sources = Sources(Self.meet)
        let clock = Clock()
        var saves = 0
        let session = try session(sources, clock: clock, settleMs: 0, saved: { _ in saves += 1 })
        session.start()
        sources.answer = Self.zoom
        session.check()
        session.check()
        #expect(session.currentLog?.segments.count == 2, "the change asked for a save")
        if quit {
          #expect(session.takeFinalLog()?.segments.count == 2)
        } else {
          session.cancel()
        }
        await session.savesSettledForTesting()
        #expect(saves == 0, quit ? "quit writes the final log itself" : "delete saves nothing")
      }
    }

    @Test("a recording with no call still saves every interval")
    func savesWithNoCall() async throws {
      var saved: [CallSpeakerLog] = []
      let session = try session(
        Sources(.none), clock: Clock(), tick: .milliseconds(1), saved: { saved.append($0) })
      session.start()
      await eventually("saved twice with no call") { saved.count >= 2 }
      session.cancel()
      #expect(saved.last?.segments.isEmpty == true)
      #expect((saved.last?.sessionHealth?.noSource ?? 0) >= 2)
    }

    // MARK: - Mute following (#4248 plan §18)

    private static let teams = CallSpeakerSourceAnswer.unique(
      .init(family: .teams, target: CallSpeakerTarget(pid: 3, rule: .callApp(.teams))))

    /// What a session told mute following, and a copy taker that can be held mid-copy.
    @MainActor
    final class MuteRig {
      var following = true
      var bindings: [CallCaptureBinding?] = []
      var readings: [CallMuteCopy] = []
      var saves = 0
      let holding = OSAllocatedUnfairLock(initialState: false)
      let gate = DispatchSemaphore(value: 0)
      let copies = OSAllocatedUnfairLock(initialState: 0)

      /// Lets one held copy finish.
      func letGo() {
        holding.withLock { $0 = false }
        gate.signal()
      }
    }

    private func muteSession(
      _ sources: Sources, clock: Clock, rig: MuteRig, rules withRules: Bool = true
    ) throws -> CallSpeakerSession {
      let rules = try TalkerRulesSnapshot(
        validating: Data(
          contentsOf: RepoRoot.url.appending(
            path: "Sources/EnviousWisprServices/Resources/talker-rules.json")), origin: .bundled)
      let holding = rig.holding
      let gate = rig.gate
      let copies = rig.copies
      return CallSpeakerSession(
        anchor: 0, rules: withRules ? rules : nil, bundled: withRules ? rules.rules : nil,
        dependencies: .init(
          sources: sources,
          capture: { _, _, _ in
            copies.withLock { $0 += 1 }
            if holding.withLock({ $0 }) { gate.wait() }
            let page = CallSpeakerObserverTests.meetCopy()
            let host = clock.host()
            return CallAXCapture(
              windows: page.windows, documents: page.documents, completeness: .complete,
              readStartHostTime: host, readEndHostTime: host)
          },
          muteRules: .testPackaged, isTrusted: { true }, isDictationIdle: { true },
          save: { _ in rig.saves += 1 }, lane: .init(), hostTime: { clock.host() },
          tick: .seconds(3_600), settle: .milliseconds(2_000), observerTick: .seconds(3_600),
          saveEvery: 2, muteFollowing: { rig.following },
          muteBinding: { rig.bindings.append($0) }, muteReading: { rig.readings.append($0) }))
    }

    /// One tick of whichever observer takes copies, and its copy delivered.
    private func capture(_ session: CallSpeakerSession) async throws {
      let observer = try #require(session.captureObserverForTesting)
      let before = observer.deliveriesForTesting
      observer.tick()
      await eventually("copy delivered") { observer.deliveriesForTesting > before }
    }

    @Test(
      "a single supported call binds the mute button at once; a change rebinds or unbinds at once")
    func muteBindsWithoutSettle() throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig)
      session.start()
      #expect(rig.bindings.map { $0?.surface } == [.meet])
      #expect(rig.bindings.last??.generation == 1)
      sources.answer = Self.zoom
      session.check()
      #expect(rig.bindings.map { $0?.surface } == [.meet, .zoomApp], "no settle for mute")
      #expect(rig.bindings.last??.generation == 2)
      #expect(session.currentLog?.segments.map(\.surface) == [.meet], "naming still settles")
      sources.answer = .none
      session.check()
      #expect(rig.bindings.count == 3)
      #expect(rig.bindings.last == .some(nil), "unbound at once")
      session.cancel()
    }

    @Test(
      "a copy in flight when the call changes gives no mute reading; the next copy reads the new call",
      arguments: [
        ("zoom to teams", 0, true), ("browser to native", 1, true),
        ("zoom to teams, mute only", 0, false), ("browser to native, mute only", 1, false),
      ])
    func switchWithCopyInFlight(_ name: String, _ which: Int, _ rules: Bool) async throws {
      let from = which == 0 ? Self.zoom : Self.meet
      let sources = Sources(from)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig, rules: rules)
      session.start()
      let observer = try #require(session.captureObserverForTesting)
      let observationsBefore = session.currentLog?.segments.first?.observations.count
      rig.holding.withLock { $0 = true }
      observer.tick()
      await eventually("old copy started") { rig.copies.withLock { $0 } == 1 }
      sources.answer = Self.teams
      session.check()
      rig.letGo()
      await eventually("old copy delivered") { observer.deliveriesForTesting == 1 }
      #expect(rig.readings.isEmpty, "\(name): the old call's copy is fenced")
      // Still inside naming's settle: the same observer copies the new call for mute only.
      #expect(session.captureObserverForTesting === observer)
      try await capture(session)
      #expect(rig.readings.map(\.surface) == [.teamsApp], "\(name)")
      #expect(rig.readings.map(\.generation) == [2], "\(name)")
      #expect(
        session.currentLog?.segments.first?.observations.count == observationsBefore,
        "\(name): naming counted neither copy")
      session.cancel()
    }

    @Test("a check during naming's settle drops naming's copy in flight, never mute's")
    func settleCheckKeepsMuteCopy() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig)
      session.start()
      let observer = try #require(session.captureObserverForTesting)
      let observationsBefore = session.currentLog?.segments.first?.observations.count
      sources.answer = Self.teams
      session.check()
      // A Teams copy starts, then another check runs while naming still settles.
      rig.holding.withLock { $0 = true }
      observer.tick()
      await eventually("teams copy started") { rig.copies.withLock { $0 } == 1 }
      clock.ms.withLock { $0 += 500 }
      session.check()
      rig.letGo()
      await eventually("teams copy delivered") { observer.deliveriesForTesting == 1 }
      #expect(rig.readings.map(\.surface) == [.teamsApp], "mute keeps the new call's copy")
      #expect(rig.readings.map(\.generation) == [2])
      #expect(
        session.currentLog?.segments.first?.observations.count == observationsBefore,
        "naming counts nothing during its settle")
      session.cancel()
    }

    @Test("without talker rules the mute button is still read, and nothing is saved")
    func muteWithoutRules() async throws {
      let sources = Sources(Self.teams)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig, rules: false)
      session.start()
      #expect(session.isMuteOnlyForTesting)
      try await capture(session)
      #expect(rig.readings.map(\.surface) == [.teamsApp])
      #expect(session.currentLog == nil)
      #expect(await session.finish())
      #expect(rig.saves == 0, "no log is made up without rules")
    }

    @Test("after the segment cap the mute button is still read")
    func muteAfterCapacity() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig)
      session.start()
      for n in 0..<CallSpeakerLog.maximumSegments {
        sources.answer = n.isMultiple(of: 2) ? Self.zoom : Self.meet
        session.check()
        clock.ms.withLock { $0 += 3_000 }
        session.check()
      }
      #expect(session.currentLog?.sessionHealth?.capacityReason == "segments")
      #expect(session.isMuteOnlyForTesting)
      let before = rig.readings.count
      try await capture(session)
      #expect(rig.readings.count == before + 1)
      session.cancel()
    }

    @Test("with mute following off, naming reads as before; switching it on binds at once")
    func muteOffNamingUnchanged() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let rig = MuteRig()
      rig.following = false
      let session = try muteSession(sources, clock: clock, rig: rig)
      session.start()
      try await capture(session)
      #expect(session.currentLog?.segments.first?.observations.count == 1)
      #expect(rig.bindings.isEmpty)
      #expect(rig.readings.isEmpty)
      rig.following = true
      session.muteFollowingChanged()
      #expect(rig.bindings.map { $0?.surface } == [.meet])
      try await capture(session)
      #expect(rig.readings.count == 1)
      #expect(session.currentLog?.segments.first?.observations.count == 2)
      session.cancel()
    }

    @Test("switching mute following off then on mid-recording keeps one copy taker and naming")
    func muteSwitchOffAndOnWithNaming() async throws {
      let sources = Sources(Self.meet)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig)
      session.start()
      let observer = try #require(session.captureObserverForTesting)
      try await capture(session)
      #expect(rig.readings.count == 1)
      // A copy in flight when the switch goes off reaches neither mute nor naming.
      rig.holding.withLock { $0 = true }
      observer.tick()
      await eventually("copy started") { rig.copies.withLock { $0 } == 2 }
      rig.following = false
      session.muteFollowingChanged()
      #expect(rig.bindings.map { $0?.surface } == [.meet, nil], "unbound at once")
      rig.letGo()
      await eventually("copy delivered") { observer.deliveriesForTesting == 2 }
      #expect(rig.readings.count == 1, "the copy begun while on is fenced")
      #expect(session.currentLog?.segments.first?.observations.count == 1)
      // Off: naming still reads on the same observer; mute reads nothing.
      try await capture(session)
      #expect(rig.readings.count == 1)
      #expect(session.currentLog?.segments.first?.observations.count == 2)
      rig.following = true
      session.muteFollowingChanged()
      #expect(rig.bindings.map { $0?.surface } == [.meet, nil, .meet])
      #expect(rig.bindings.last??.generation == 1, "the same call keeps its generation")
      #expect(session.captureObserverForTesting === observer, "no second copy taker")
      try await capture(session)
      #expect(rig.readings.count == 2)
      #expect(rig.copies.withLock { $0 } == 4, "one copy per tick")
      #expect(session.currentLog?.segments.first?.observations.count == 3)
      session.cancel()
    }

    @Test("without talker rules, off retires the mute-only copy taker and on starts exactly one")
    func muteSwitchOffAndOnMuteOnly() async throws {
      let sources = Sources(Self.teams)
      let clock = Clock()
      let rig = MuteRig()
      let session = try muteSession(sources, clock: clock, rig: rig, rules: false)
      session.start()
      let first = try #require(session.captureObserverForTesting)
      #expect(session.isMuteOnlyForTesting)
      rig.following = false
      session.muteFollowingChanged()
      #expect(session.captureObserverForTesting == nil, "nothing copies while off")
      #expect(rig.bindings.map { $0?.surface } == [.teamsApp, nil])
      rig.following = true
      session.muteFollowingChanged()
      session.muteFollowingChanged()
      let second = try #require(session.captureObserverForTesting)
      #expect(second !== first)
      #expect(
        rig.bindings.map { $0?.surface } == [.teamsApp, nil, .teamsApp], "a repeat is a no-op")
      try await capture(session)
      #expect(rig.readings.map(\.surface) == [.teamsApp])
      #expect(rig.copies.withLock { $0 } == 1)
      #expect(await session.finish())
    }

    @Test("past the most segments a log may hold, no segment opens and the refusal is counted")
    func segmentCapacity() async throws {
      let sources = Sources(Self.meet)
      let session = try session(sources, clock: Clock(), settleMs: 0)
      session.start()
      // Each switch: the first check sees the change, the second ends one segment and opens the next.
      for n in 0..<CallSpeakerLog.maximumSegments {
        sources.answer = n.isMultiple(of: 2) ? Self.zoom : Self.meet
        session.check()
        session.check()
      }
      let log = try #require(session.currentLog)
      #expect(log.segments.count == CallSpeakerLog.maximumSegments)
      #expect(log.sessionHealth?.capacityReason == "segments")
      #expect(log.shapeProblem == nil, "the log still saves")
      session.cancel()
    }

    // MARK: - Zoom self probe (#4356)

    /// SYNTHETIC Zoom meeting window shapes from the 2026-11-03 live takes: two tiles, the
    /// closed panel's toolbar button, and optionally the docked participants list.
    nonisolated static func zoomCopy(
      host: UInt64, list: [String]? = nil,
      button: String = "Open participants panel, closed, 2 participants"
    ) -> CallAXCapture {
      var children = [
        CallAXNode(
          role: "AXTabGroup", description: "Saurabh Vaish, Computer audio muted, Video off"),
        CallAXNode(role: "AXTabGroup", description: "Bea Chen, Computer audio unmuted, Video off"),
        CallAXNode(role: "AXButton", description: button, identifier: "participant"),
      ]
      if let list {
        children.append(
          CallAXNode(
            role: "AXOutline", description: "Participants list",
            children: list.map { entry in
              let name = ZoomAppSpeakerReader.panelEntry(entry).name
              return CallAXNode(
                role: "AXRow",
                children: [
                  CallAXNode(
                    role: "AXCell", identifier: ZoomAppSpeakerReader.joinedRowIdentifier,
                    children: [
                      CallAXNode(role: "AXStaticText", value: entry),
                      CallAXNode(
                        role: "AXMenuButton", description: "More options for \(name), collapsed"),
                    ])
                ])
            }))
      }
      let window = CallAXWindow(
        title: "Zoom Meeting",
        root: CallAXNode(role: "AXWindow", identifier: "zm.meeting.window.main", children: children)
      )
      return CallAXCapture(
        windows: [window], documents: [], completeness: .complete, readStartHostTime: host,
        readEndHostTime: host, accountTitles: ["Saurabh A Vaish(saurabhav@gmail.com)"])
    }

    /// A scripted probe: records every call and answers from `next`; `hold` makes it wait (on
    /// the lane) until the test lets it go, then it asks `shouldStop` like the real one.
    final class Probe: Sendable {
      let calls = OSAllocatedUnfairLock(initialState: [(pid: pid_t, roles: Set<String>)]())
      let next = OSAllocatedUnfairLock(
        initialState: ZoomSelfProbe.Result(
          refusal: nil, pressedOpen: true, learned: "Saurabh Vaish", panelClosed: true,
          userClosed: false, elapsedMs: 120))
      let hold = OSAllocatedUnfairLock(initialState: false)
      /// Hold after asking `shouldStop` (the press already happened) instead of before.
      let holdAfterStop = OSAllocatedUnfairLock(initialState: false)
      /// Never ask `shouldStop`: the result of a probe already past its press.
      let ignoreStop = OSAllocatedUnfairLock(initialState: false)
      let release = DispatchSemaphore(value: 0)
      let stopped = OSAllocatedUnfairLock(initialState: [Bool]())

      func run(_ target: CallSpeakerTarget, _ roles: Set<String>, _ stop: () -> Bool)
        -> ZoomSelfProbe.Result
      {
        calls.withLock { $0.append((target.pid, roles)) }
        let holding = hold.withLock { $0 }
        let late = holdAfterStop.withLock { $0 }
        // deadline-fallback: bound a missing release; the test fails on its own expectations
        if holding, !late { _ = release.wait(timeout: .now() + 10) }
        let stop = ignoreStop.withLock { $0 } ? false : stop()
        stopped.withLock { $0.append(stop) }
        // deadline-fallback: as above
        if holding, late { _ = release.wait(timeout: .now() + 10) }
        if stop { return .refused(.skipped, elapsedMs: 1) }
        return next.withLock { $0 }
      }

      var count: Int { calls.withLock { $0.count } }
    }

    /// What the session saved and the mute events it sent.
    @MainActor
    final class ZoomRig {
      var saves: [CallSpeakerLog] = []
      var muteEvents: [CallMuteCaptureEvent] = []
      var logs: [String] = []
      let dictation = CallSpeakerObserverTests.Dictation()
      var probeLines: Int { logs.filter { $0.hasPrefix("meeting zoom self probe") }.count }
    }

    /// The Zoom window each copy shows (read on the lane), and how many copies were taken.
    final class ZoomShape: Sendable {
      let shape = OSAllocatedUnfairLock(
        initialState: (
          list: [String]?.none, button: "Open participants panel, closed, 2 participants"
        ))
      let copies = OSAllocatedUnfairLock(initialState: 0)

      func set(list: [String]?, button: String) { shape.withLock { $0 = (list, button) } }
      var count: Int { copies.withLock { $0 } }
    }

    /// A scripted front app and activation feed for the focus hand-back (plan §3.4).
    @MainActor
    final class FakeFocus {
      var front: pid_t?
      var requested: [pid_t] = []
      var watching: [ObjectIdentifier: (pid_t) -> Void] = [:]
      var removed = 0
      var turns: [() -> Void] = []

      init(front: pid_t? = nil) { self.front = front }

      /// macOS activated `pid` (the user, or the probe's own press of Zoom).
      func activated(_ pid: pid_t) {
        front = pid
        for handler in watching.values { handler(pid) }
      }

      func runTurns() {
        let pending = turns
        turns = []
        for turn in pending { turn() }
      }

      var access: CallSpeakerSession.FocusAccess {
        CallSpeakerSession.FocusAccess(
          frontmost: { [self] in front },
          watch: { [self] handler in
            let token = NSObject()
            watching[ObjectIdentifier(token)] = handler
            return token
          },
          stopWatching: { [self] token in
            if watching.removeValue(forKey: ObjectIdentifier(token as AnyObject)) != nil {
              removed += 1
            }
          },
          activate: { [self] pid in requested.append(pid) },
          nextTurn: { [self] body in turns.append(body) })
      }
    }

    private func zoomSession(
      _ sources: Sources, clock: Clock, rig: ZoomRig, probe: Probe, shape: ZoomShape = ZoomShape(),
      following: Bool = false, focus: FakeFocus? = nil
    ) throws -> CallSpeakerSession {
      let focus = focus ?? FakeFocus()
      let rules = try TalkerRulesSnapshot(
        validating: Data(
          contentsOf: RepoRoot.url.appending(
            path: "Sources/EnviousWisprServices/Resources/talker-rules.json")), origin: .bundled)
      return CallSpeakerSession(
        anchor: 0, rules: rules, bundled: rules.rules,
        dependencies: .init(
          sources: sources,
          capture: { _, _, _ in
            shape.copies.withLock { $0 += 1 }
            let now = shape.shape.withLock { $0 }
            return Self.zoomCopy(host: clock.host(), list: now.list, button: now.button)
          },
          muteRules: .testPackaged, isTrusted: { true }, isDictationIdle: { rig.dictation.idle },
          save: { log in rig.saves.append(log) }, log: { rig.logs.append($0) }, lane: .init(),
          hostTime: { clock.host() },
          tick: .seconds(3_600), settle: .milliseconds(2_000), observerTick: .seconds(3_600),
          saveEvery: 1_000, muteFollowing: { following },
          muteEvent: { rig.muteEvents.append($0) },
          selfProbe: { target, roles, stop in probe.run(target, roles, stop) },
          focus: focus.access))
    }

    /// One tick of the current observer and its outcome: a copy delivered, or a probe settled.
    private func tickZoom(_ session: CallSpeakerSession, probe: Probe) async {
      guard let observer = session.currentObserverForTesting else { return }
      let deliveries = observer.deliveriesForTesting
      let probes = probe.count
      observer.tick()
      await eventually("copy delivered or probe settled") {
        observer.deliveriesForTesting > deliveries
          || (probe.count > probes && session.pendingProbeForTesting == nil)
      }
    }

    private static let zoomSource = CallSpeakerSourceAnswer.Source(
      family: .zoom, target: CallSpeakerTarget(pid: 2, rule: .callApp(.zoom)))

    @Test("an unknown user: one valid reading, then the probe in the next slot; the name is used")
    func probeLearnsAndIsUsed() async throws {
      let sources = Sources(Self.zoom)
      let clock = Clock()
      let rig = ZoomRig()
      let probe = Probe()
      let shape = ZoomShape()
      let session = try zoomSession(sources, clock: clock, rig: rig, probe: probe, shape: shape)
      session.start()
      await tickZoom(session, probe: probe)
      #expect(probe.count == 0, "the first tick reads; only a valid reading allows a probe")
      #expect(session.zoomIdentityForTesting?.ready == true)
      let copiesBefore = shape.count
      await tickZoom(session, probe: probe)
      #expect(probe.count == 1)
      #expect(shape.count == copiesBefore, "the probe took the slot instead of a copy")
      #expect(probe.calls.withLock { $0.first?.pid } == 2)
      #expect(probe.calls.withLock { $0.first?.roles } == CallMuteRules.testPackaged.protectedRoles)
      #expect(session.zoomIdentityForTesting?.knownSelf == "Saurabh Vaish")
      #expect(session.zoomIdentityForTesting?.opensUsed == 1)
      // Later copies give the Zoom reader the learned name instead of the account name, and no
      // further probe runs.
      clock.ms.withLock { $0 = 20_000 }
      await tickZoom(session, probe: probe)
      clock.ms.withLock { $0 = 40_000 }
      await tickZoom(session, probe: probe)
      #expect(probe.count == 1)
      let pairs = try #require(session.currentLog?.segments.last?.pairs)
      #expect(pairs.last?.accountNames == ["Saurabh Vaish"])
      session.cancel()
    }

    @Test("a probe slot is recorded like a busy lane tick: mute gets a busy skip, never started")
    func probeSlotAccounting() async throws {
      let sources = Sources(Self.zoom)
      let rig = ZoomRig()
      let probe = Probe()
      let session = try zoomSession(
        sources, clock: Clock(), rig: rig, probe: probe, following: true)
      session.start()
      await tickZoom(session, probe: probe)
      let started = rig.muteEvents.filter { $0 == .started }.count
      rig.muteEvents.removeAll()
      await tickZoom(session, probe: probe)
      #expect(probe.count == 1)
      #expect(rig.muteEvents == [.busySkip])
      #expect(started == 1)
      session.cancel()
    }

    @Test(
      "no probe while the list is on screen, or once a list (me) row named the user")
    func probeEligibility() async throws {
      let sources = Sources(Self.zoom)
      let rig = ZoomRig()
      let probe = Probe()
      let shape = ZoomShape()
      let session = try zoomSession(sources, clock: Clock(), rig: rig, probe: probe, shape: shape)
      session.start()
      // The list is open but marks nobody: never ready.
      shape.set(
        list: ["Bea Chen", "Saurabh Vaish"],
        button: "Close participants panel, opened, 2 participants")
      await tickZoom(session, probe: probe)
      await tickZoom(session, probe: probe)
      #expect(probe.count == 0)
      #expect(session.zoomIdentityForTesting?.ready == false)
      // The list marks the user: learned without any press.
      shape.set(
        list: ["Bea Chen", "Saurabh Vaish (Host, me)"],
        button: "Close participants panel, opened, 2 participants")
      await tickZoom(session, probe: probe)
      #expect(session.zoomIdentityForTesting?.knownSelf == "Saurabh Vaish")
      shape.set(list: nil, button: "Open participants panel, closed, 2 participants")
      await tickZoom(session, probe: probe)
      await tickZoom(session, probe: probe)
      #expect(probe.count == 0, "a known user needs no probe")
      session.cancel()
    }

    @Test(
      "at most three presses per call, two seconds apart; a refusal costs none; an open panel stops presses"
    )
    func probeBudget() async throws {
      let sources = Sources(Self.zoom)
      let clock = Clock()
      let rig = ZoomRig()
      let probe = Probe()
      probe.next.withLock {
        $0 = ZoomSelfProbe.Result(
          refusal: nil, pressedOpen: true, learned: nil, panelClosed: true, userClosed: false,
          elapsedMs: 600)
      }
      let session = try zoomSession(sources, clock: clock, rig: rig, probe: probe)
      session.start()
      var ms = 0
      func round() async {
        ms += 3_000
        let now = ms
        clock.ms.withLock { $0 = now }
        await tickZoom(session, probe: probe)  // a valid reading
        await tickZoom(session, probe: probe)  // the probe, when allowed
      }
      await round()
      #expect(probe.count == 1)
      // Too soon after the last probe: a copy, not a probe.
      await tickZoom(session, probe: probe)
      await tickZoom(session, probe: probe)
      #expect(probe.count == 1)
      await round()
      await round()
      #expect(session.zoomIdentityForTesting?.opensUsed == 3)
      await round()
      #expect(probe.count == 3, "a fourth press never happens")

      // A refusal presses nothing and uses no press.
      let other = Probe()
      other.next.withLock { $0 = .refused(.notInState, elapsedMs: 2) }
      let refused = try zoomSession(
        Sources(Self.zoom), clock: Clock(), rig: ZoomRig(), probe: other)
      refused.start()
      await tickZoom(refused, probe: other)
      await tickZoom(refused, probe: other)
      #expect(other.count == 1)
      #expect(refused.zoomIdentityForTesting?.opensUsed == 0)
      refused.cancel()

      // A panel that may still be open: no more presses this call.
      let stuck = Probe()
      stuck.next.withLock {
        $0 = ZoomSelfProbe.Result(
          refusal: nil, pressedOpen: true, learned: nil, panelClosed: false, userClosed: false,
          elapsedMs: 600)
      }
      let stuckClock = Clock()
      let stuckSession = try zoomSession(
        Sources(Self.zoom), clock: stuckClock, rig: ZoomRig(), probe: stuck)
      stuckSession.start()
      await tickZoom(stuckSession, probe: stuck)
      await tickZoom(stuckSession, probe: stuck)
      stuckClock.ms.withLock { $0 = 10_000 }
      await tickZoom(stuckSession, probe: stuck)
      await tickZoom(stuckSession, probe: stuck)
      #expect(stuck.count == 1)
      #expect(stuckSession.zoomIdentityForTesting?.pressesStopped == true)
      stuckSession.cancel()
      session.cancel()
    }

    @Test(
      "a source interruption before the press stops it; a late result for an old call changes nothing"
    )
    func probeInvalidation() async throws {
      let sources = Sources(Self.zoom)
      let clock = Clock()
      let rig = ZoomRig()
      let probe = Probe()
      let session = try zoomSession(sources, clock: clock, rig: rig, probe: probe)
      session.start()
      await tickZoom(session, probe: probe)
      probe.hold.withLock { $0 = true }
      let observer = try #require(session.currentObserverForTesting)
      observer.tick()
      await eventually("probe dispatched") { probe.count == 1 }
      // Another call appears: the token moves while the probe waits before its press.
      sources.answer = .unique(
        .init(family: .zoom, target: CallSpeakerTarget(pid: 3, rule: .callApp(.zoom))))
      session.check()
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      await eventually("probe settled") { session.pendingProbeForTesting == nil }
      #expect(probe.stopped.withLock { $0 } == [true], "the press never happened")
      #expect(session.zoomIdentityForTesting?.knownSelf == nil)
      #expect(session.zoomIdentityForTesting?.opensUsed == 0)
      session.cancel()
    }

    @Test(
      "a pending probe survives a change of call and blocks a new one; its result stays with its call"
    )
    func probeAcrossSources() async throws {
      let sources = Sources(Self.zoom)
      let clock = Clock()
      let rig = ZoomRig()
      let probe = Probe()
      let session = try zoomSession(sources, clock: clock, rig: rig, probe: probe)
      session.start()
      await tickZoom(session, probe: probe)
      // The probe is already past its press: its result names someone and counts a press.
      probe.ignoreStop.withLock { $0 = true }
      probe.hold.withLock { $0 = true }
      try #require(session.currentObserverForTesting).tick()
      await eventually("probe dispatched") { probe.count == 1 }
      let other = CallSpeakerSourceAnswer.unique(
        .init(family: .zoom, target: CallSpeakerTarget(pid: 3, rule: .callApp(.zoom))))
      sources.answer = other
      clock.ms.withLock { $0 = 1_000 }
      session.check()
      clock.ms.withLock { $0 = 4_000 }
      session.check()
      #expect(session.zoomIdentityForTesting?.source.target.pid == 3, "a new call's identity")
      #expect(session.pendingProbeForTesting != nil, "the old ticket is still out")
      // The new segment reads; no second probe starts while the first is out (the lane is held
      // too, so the tick is a busy skip).
      try #require(session.currentObserverForTesting).tick()
      #expect(probe.count == 1)
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      await eventually("old probe settled") { session.pendingProbeForTesting == nil }
      #expect(
        session.zoomIdentityForTesting?.knownSelf == nil, "the old call's name is not this call's")
      #expect(session.zoomIdentityForTesting?.opensUsed == 0, "nor its press")
      #expect(rig.probeLines == 1, "settled once")
      session.cancel()
    }

    @Test(
      "dictation stops a probe before its press, and a name from a probe it overlapped is refused")
    func probeDictation() async throws {
      let rig = ZoomRig()
      let probe = Probe()
      let session = try zoomSession(Sources(Self.zoom), clock: Clock(), rig: rig, probe: probe)
      session.start()
      await tickZoom(session, probe: probe)
      probe.hold.withLock { $0 = true }
      try #require(session.currentObserverForTesting).tick()
      await eventually("probe dispatched") { probe.count == 1 }
      // A whole dictation between two ticks, while the probe waits before its press.
      rig.dictation.idle = false
      rig.dictation.idle = true
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      await eventually("settled") { session.pendingProbeForTesting == nil }
      #expect(probe.stopped.withLock { $0 } == [true])

      // Past its press: the probe returns a name, but a dictation overlapped it.
      let late = Probe()
      let rig2 = ZoomRig()
      let second = try zoomSession(Sources(Self.zoom), clock: Clock(), rig: rig2, probe: late)
      second.start()
      await tickZoom(second, probe: late)
      late.hold.withLock { $0 = true }
      late.holdAfterStop.withLock { $0 = true }
      try #require(second.currentObserverForTesting).tick()
      await eventually("pressed") { late.stopped.withLock { $0.count } == 1 }
      rig2.dictation.idle = false
      rig2.dictation.idle = true
      late.release.signal()
      await eventually("settled") { second.pendingProbeForTesting == nil }
      #expect(second.zoomIdentityForTesting?.knownSelf == nil, "the name is refused")
      #expect(second.zoomIdentityForTesting?.opensUsed == 1, "the press still counts")
      session.cancel()
      second.cancel()
    }

    @Test("a new segment of the same call keeps the learned name and the press count")
    func probeIdentitySurvivesSegment() async throws {
      let sources = Sources(Self.zoom)
      let clock = Clock()
      let probe = Probe()
      let session = try zoomSession(sources, clock: clock, rig: ZoomRig(), probe: probe)
      session.start()
      await tickZoom(session, probe: probe)
      await tickZoom(session, probe: probe)
      #expect(session.zoomIdentityForTesting?.knownSelf == "Saurabh Vaish")
      // The call is lost for longer than the settle time, then the same call comes back.
      sources.answer = .none
      clock.ms.withLock { $0 = 1_000 }
      session.check()
      clock.ms.withLock { $0 = 4_000 }
      session.check()
      #expect(session.currentObserverForTesting == nil)
      sources.answer = Self.zoom
      clock.ms.withLock { $0 = 5_000 }
      session.check()
      #expect(session.currentLog?.segments.count == 2)
      #expect(session.zoomIdentityForTesting?.knownSelf == "Saurabh Vaish")
      #expect(session.zoomIdentityForTesting?.opensUsed == 1)
      session.cancel()
    }

    @Test("after Delete with the session dropped, a probe still out settles once and saves nothing")
    func probeOutlivesDelete() async throws {
      let rig = ZoomRig()
      let probe = Probe()
      var session: CallSpeakerSession? = try zoomSession(
        Sources(Self.zoom), clock: Clock(), rig: rig, probe: probe)
      session?.start()
      if let session { await tickZoom(session, probe: probe) }
      probe.hold.withLock { $0 = true }
      try #require(session?.currentObserverForTesting).tick()
      await eventually("probe dispatched") { probe.count == 1 }
      session?.cancel()
      weak let dropped = session
      session = nil
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      await eventually("settled once") { rig.probeLines == 1 }
      await eventually("released afterwards") { dropped == nil }
      #expect(rig.saves.isEmpty)
      #expect(rig.logs.contains("meeting zoom self known source=probe") == false)
    }

    @Test("Stop waits for a probe still out before the final save; Delete meanwhile saves nothing")
    func probeAndFinish() async throws {
      let rig = ZoomRig()
      let probe = Probe()
      let session = try zoomSession(Sources(Self.zoom), clock: Clock(), rig: rig, probe: probe)
      session.start()
      await tickZoom(session, probe: probe)
      probe.hold.withLock { $0 = true }
      try #require(session.currentObserverForTesting).tick()
      await eventually("probe dispatched") { probe.count == 1 }
      let finished = Task { await session.finish() }
      await eventually("Stop closed admission") { session.currentObserverForTesting?.open == false }
      #expect(rig.saves.isEmpty, "no final save while the probe is out")
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      #expect(await finished.value)
      #expect(rig.saves.count == 1)
      #expect(session.pendingProbeForTesting == nil)

      let rig2 = ZoomRig()
      let held = Probe()
      let deleted = try zoomSession(Sources(Self.zoom), clock: Clock(), rig: rig2, probe: held)
      deleted.start()
      await tickZoom(deleted, probe: held)
      held.hold.withLock { $0 = true }
      try #require(deleted.currentObserverForTesting).tick()
      await eventually("probe dispatched") { held.count == 1 }
      let waiting = Task { await deleted.finish() }
      await eventually("Stop closed admission") { deleted.currentObserverForTesting?.open == false }
      deleted.cancel()
      held.hold.withLock { $0 = false }
      held.release.signal()
      #expect(await waiting.value == false)
      #expect(rig2.saves.isEmpty)
      #expect(deleted.pendingProbeForTesting == nil, "the ticket still settles")
      #expect(deleted.zoomIdentityForTesting?.knownSelf == nil, "nothing learned after Delete")
    }

    // MARK: - Focus hand-back (#4356 plan §3.4)

    static let textEdit: pid_t = 50

    /// One probe with the user in TextEdit; `during` runs while the probe is out (after the
    /// ticket, before the result), as macOS and the user would.
    private func handBack(
      front: pid_t? = textEdit, pressed: Bool = true,
      during: @MainActor (FakeFocus) -> Void
    ) async throws -> (focus: FakeFocus, rig: ZoomRig) {
      let rig = ZoomRig()
      let probe = Probe()
      if !pressed { probe.next.withLock { $0 = .refused(.notInState, elapsedMs: 2) } }
      let focus = FakeFocus(front: front)
      let session = try zoomSession(
        Sources(Self.zoom), clock: Clock(), rig: rig, probe: probe, focus: focus)
      session.start()
      await tickZoom(session, probe: probe)
      probe.hold.withLock { $0 = true }
      try #require(session.currentObserverForTesting).tick()
      await eventually("probe dispatched") { probe.count == 1 }
      during(focus)
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      await eventually("settled") { session.pendingProbeForTesting == nil }
      session.cancel()
      return (focus, rig)
    }

    private func outcome(_ rig: ZoomRig) -> [String] {
      rig.logs.filter { $0.hasPrefix("meeting zoom self handback=") }
    }

    @Test("the press brought Zoom forward: the user's app is asked back once, and it came back")
    func handBackRestores() async throws {
      let (focus, rig) = try await handBack { $0.activated(2) }
      #expect(focus.requested == [Self.textEdit])
      #expect(outcome(rig).isEmpty, "the outcome is read on the next run-loop pass")
      focus.front = Self.textEdit
      focus.runTurns()
      #expect(outcome(rig) == ["meeting zoom self handback=restored"])
      #expect(focus.removed == 1)
      #expect(focus.watching.isEmpty)
    }

    @Test("macOS keeps Zoom in front: refused, never asked again")
    func handBackRefused() async throws {
      let (focus, rig) = try await handBack { $0.activated(2) }
      focus.runTurns()
      #expect(focus.requested == [Self.textEdit])
      #expect(outcome(rig) == ["meeting zoom self handback=refused"])
    }

    @Test("anything but exactly Zoom's own activation leaves the front app alone")
    func handBackUserMoved() async throws {
      let cases: [(String, @MainActor (FakeFocus) -> Void)] = [
        ("no activation", { _ in }),
        (
          "Zoom twice",
          {
            $0.activated(2)
            $0.activated(2)
          }
        ),
        ("another app", { $0.activated(77) }),
        (
          "away and back",
          {
            $0.activated(77)
            $0.activated(2)
          }
        ),
      ]
      for (label, during) in cases {
        let (focus, rig) = try await handBack(during: during)
        #expect(focus.requested.isEmpty, "\(label)")
        #expect(outcome(rig) == ["meeting zoom self handback=skipped_user_moved"], "\(label)")
        #expect(focus.watching.isEmpty, "\(label)")
      }
    }

    @Test(
      "Zoom already in front, no app in front, EnviousWispr in front, or nothing pressed: no ask")
    func handBackNotNeeded() async throws {
      for front in [pid_t(2), nil, getpid()] {
        let (focus, rig) = try await handBack(front: front) { $0.activated(2) }
        #expect(focus.requested.isEmpty)
        #expect(outcome(rig) == ["meeting zoom self handback=not_needed"])
      }
      let (focus, rig) = try await handBack(pressed: false) { _ in }
      #expect(focus.requested.isEmpty)
      #expect(outcome(rig) == ["meeting zoom self handback=not_needed"])
      #expect(focus.removed == 1, "the activation watch still ends")
    }

    @Test("after Delete with the session dropped, the hand-back still happens once")
    func handBackAfterDelete() async throws {
      let rig = ZoomRig()
      let probe = Probe()
      let focus = FakeFocus(front: Self.textEdit)
      var session: CallSpeakerSession? = try zoomSession(
        Sources(Self.zoom), clock: Clock(), rig: rig, probe: probe, focus: focus)
      session?.start()
      if let session { await tickZoom(session, probe: probe) }
      // Delete comes after the press (a Delete before it means no press and nothing to give back).
      probe.hold.withLock { $0 = true }
      probe.holdAfterStop.withLock { $0 = true }
      try #require(session?.currentObserverForTesting).tick()
      await eventually("pressed") { probe.stopped.withLock { $0.count } == 1 }
      session?.cancel()
      weak let dropped = session
      session = nil
      focus.activated(2)
      probe.release.signal()
      await eventually("asked back") { focus.requested == [Self.textEdit] }
      focus.front = Self.textEdit
      focus.runTurns()
      #expect(outcome(rig) == ["meeting zoom self handback=restored"])
      #expect(rig.saves.isEmpty)
      await eventually("released afterwards") { dropped == nil }
    }

    @Test("a settled probe's activation watch cannot touch the next probe")
    func handBackPerTicket() async throws {
      let rig = ZoomRig()
      let clock = Clock()
      let probe = Probe()
      probe.next.withLock {
        $0 = ZoomSelfProbe.Result(
          refusal: nil, pressedOpen: true, learned: nil, panelClosed: true, userClosed: false,
          elapsedMs: 600)
      }
      let focus = FakeFocus(front: Self.textEdit)
      let session = try zoomSession(
        Sources(Self.zoom), clock: clock, rig: rig, probe: probe, focus: focus)
      session.start()
      await tickZoom(session, probe: probe)
      await tickZoom(session, probe: probe)
      #expect(probe.count == 1)
      #expect(focus.watching.isEmpty, "the first ticket's watch ended")
      // The user is back in TextEdit; a second probe, with Zoom's own activation only.
      focus.front = Self.textEdit
      clock.ms.withLock { $0 = 5_000 }
      await tickZoom(session, probe: probe)
      probe.hold.withLock { $0 = true }
      try #require(session.currentObserverForTesting).tick()
      await eventually("second probe") { probe.count == 2 }
      focus.activated(2)
      probe.hold.withLock { $0 = false }
      probe.release.signal()
      await eventually("settled") { session.pendingProbeForTesting == nil }
      #expect(focus.requested == [Self.textEdit], "only the second probe asks, once")
      #expect(focus.removed == 2)
      session.cancel()
    }
  }
#endif
