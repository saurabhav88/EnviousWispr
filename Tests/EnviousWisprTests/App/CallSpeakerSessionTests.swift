import Darwin
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

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
        capture: { _, _ in
          let page = CallSpeakerObserverTests.meetCopy()
          let host = clock.host()
          return CallAXCapture(
            windows: page.windows, documents: page.documents, completeness: .complete,
            readStartHostTime: host, readEndHostTime: host)
        },
        isTrusted: { true }, isDictationIdle: { true }, save: { try await saved($0) },
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
    #expect(session.currentLog.segments.count == 1, "a one-second change is not a switch")
    clock.ms.withLock { $0 = 7_000 }
    session.check()
    let log = session.currentLog
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
    #expect(session.currentLog.segments.count == 1)
    #expect(session.currentLog.segments[0].endMs == nil)
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
    #expect(session.currentLog.segments.map(\.endReason) == [.sourceLost])
    sources.answer = Self.meet
    clock.ms.withLock { $0 = 4_000 }
    session.check()
    #expect(session.currentLog.segments.count == 2, "one call again: read at once")
    #expect(session.currentLog.sessionHealth?.ambiguousSources == 2)
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
      #expect(session.currentLog.segments.count == 2, "the change asked for a save")
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
    let log = session.currentLog
    #expect(log.segments.count == CallSpeakerLog.maximumSegments)
    #expect(log.sessionHealth?.capacityReason == "segments")
    #expect(log.shapeProblem == nil, "the log still saves")
    session.cancel()
  }
}
