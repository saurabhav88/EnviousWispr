import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4424: finished-call probes must preserve the audio clock and short replies, release on
/// cancellation, and never turn a partial/invalid inference into a successful speaker result.
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingNeuralSpeakerAnalyzerTests {
  private typealias Analyzer = MeetingNeuralSpeakerAnalyzer
  private let directory = URL(fileURLWithPath: "/unused-admitted-fixture")

  /// Confined to the loader's sending Runtime; the locked flag is observed by the test.
  private final class Lifetime {
    let released: OSAllocatedUnfairLock<Bool>
    init(_ released: OSAllocatedUnfairLock<Bool>) { self.released = released }
    func touch() { released.withLock { $0 = false } }
    deinit { released.withLock { $0 = true } }
  }

  private func frames(_ values: [[Float]]) -> LiveSpeakerFrames {
    LiveSpeakerFrames(probabilities: values.flatMap { $0 }, frameCount: values.count)
  }

  @Test("load-only readiness releases the runtime without running inference")
  func loadOnlyReleases() async throws {
    let released = OSAllocatedUnfairLock(initialState: false)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    try await Analyzer.checkLoad(directory: directory, preset: .offline) { _, _ in
      let lifetime = Lifetime(released)
      return Analyzer.Runtime(
        stepSamples: 160, slots: 1,
        appendAndProcess: { _ in lifetime.touch(); calls.withLock { $0 += 1 }; return [] },
        finish: { lifetime.touch(); calls.withLock { $0 += 1 }; return [] })
    }
    #expect(released.withLock { $0 })
    #expect(calls.withLock { $0 } == 0)
  }

  @Test("runs cross chunks, overlapping voices stay separate, and one-frame replies survive")
  func activityAcrossChunks() throws {
    var activity = Analyzer.Activity(slots: 2)
    try activity.append(frames([[0.9, 0], [0.8, 0.9]]))
    try activity.append(frames([[0.7, 0], [0.5, 0.51], [0, 0]]))
    let result = activity.finish()
    try #require(result.count == 3)
    #expect(result.map(\.speakerId) == ["N0", "N1", "N1"])
    #expect(result.map(\.startMs) == [0, 10, 30])
    #expect(result.map(\.endMs) == [30, 20, 40])
    #expect(abs(result[0].quality - 0.8) < 0.001)
  }

  @Test("silence does not reset slots; tail closes on the model's final frame")
  func gapsAndTail() throws {
    var activity = Analyzer.Activity(slots: 1)
    try activity.append(frames([[0.8], [0], [0], [0.9], [0.9]]))
    let result = activity.finish()
    #expect(result.map(\.speakerId) == ["N0", "N0"])
    #expect(result.map(\.startMs) == [0, 30])
    #expect(result.map(\.endMs) == [10, 50])
  }

  @Test("invalid shape and nonfinite inference are failures")
  func invalidFrames() {
    for invalid in [
      LiveSpeakerFrames(probabilities: [0.8], frameCount: 1),
      LiveSpeakerFrames(probabilities: [.nan, 0], frameCount: 1),
      LiveSpeakerFrames(probabilities: [.infinity, 0], frameCount: 1),
    ] {
      var activity = Analyzer.Activity(slots: 2)
      #expect(throws: Analyzer.Failure.self) { try activity.append(invalid) }
    }
  }

  @Test("the driver reads a long timeline in bounded steps and flushes once")
  func boundedReadsAndFlush() async throws {
    struct State {
      var reads: [(Int, Int)] = []
      var processed = 0
      var finishes = 0
      var loads = 0
      var onMain = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let result = try await Analyzer.run(
      sampleCount: 16_080, directory: directory, preset: .offline,
      read: { start, count in
        state.withLock { $0.reads.append((start, count)) }
        return .init(repeating: 0, count: count)
      }, canContinue: { true },
      load: { _, _ in
        state.withLock { $0.loads += 1 }
        return Analyzer.Runtime(
          stepSamples: 160, slots: 1,
          appendAndProcess: { samples in
            state.withLock {
              $0.processed += samples.count
              $0.onMain = $0.onMain || Thread.isMainThread
            }
            return samples.count == 160
              ? [LiveSpeakerFrames(probabilities: [0.9], frameCount: 1)] : []
          },
          finish: {
            state.withLock { $0.finishes += 1 }
            return [LiveSpeakerFrames(probabilities: [0.9], frameCount: 1)]
          })
      })
    let snapshot = state.withLock { $0 }
    #expect(snapshot.loads == 1)
    #expect(snapshot.reads.count == 101)
    #expect(snapshot.reads.map(\.0) == Array(stride(from: 0, to: 16_080, by: 160)))
    #expect(snapshot.reads.dropLast().allSatisfy { $0.1 == 160 })
    #expect(snapshot.reads.last?.1 == 80)
    #expect(snapshot.processed == 16_080 && snapshot.finishes == 1)
    #expect(!snapshot.onMain)
    #expect(result.count == 1 && result[0].endMs == 1010)
  }

  @Test("read errors, short reads, nonfinite audio, and incomplete tails fail without partial success")
  func inputFailures() async {
    for mode in 0..<4 {
      await #expect(throws: (any Error).self) {
        _ = try await Analyzer.run(
          sampleCount: 320, directory: directory, preset: .offline,
          read: { start, count in
            if mode == 0, start > 0 { throw Analyzer.Failure.invalidAudio }
            if mode == 1 { return [] }
            return .init(repeating: mode == 2 ? .nan : 0, count: count)
          }, canContinue: { true },
          load: { _, _ in
            Analyzer.Runtime(
              stepSamples: 160, slots: 1,
              appendAndProcess: { _ in
                mode == 3 ? [] : [LiveSpeakerFrames(probabilities: [0.9], frameCount: 1)]
              }, finish: { [] })
          })
      }
    }
  }

  @Test("a priority change after loading prevents inference and releases its runtime")
  func admissionAfterLoad() async {
    let allowed = OSAllocatedUnfairLock(initialState: true)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let released = OSAllocatedUnfairLock(initialState: false)
    await #expect(throws: Analyzer.Failure.self) {
      _ = try await Analyzer.run(
        sampleCount: 160, directory: directory, preset: .low,
        read: { _, count in .init(repeating: 0, count: count) },
        canContinue: { allowed.withLock { $0 } },
        load: { _, _ in
          let lifetime = Lifetime(released)
          allowed.withLock { $0 = false }
          return Analyzer.Runtime(
            stepSamples: 160, slots: 1,
            appendAndProcess: { _ in
              lifetime.touch()
              calls.withLock { $0 += 1 }
              return []
            }, finish: { lifetime.touch(); return [] })
        })
    }
    #expect(calls.withLock { $0 } == 0)
    #expect(released.withLock { $0 })
  }

  @Test("an already cancelled caller never loads a model")
  func alreadyCancelled() async throws {
    let entered = BoundedWait.Signal()
    let release = BoundedWait.Signal()
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let subject = Task {
      entered.fire()
      try await BoundedWait.until(release)
      return try await Analyzer.run(
        sampleCount: 160, directory: directory, preset: .low,
        read: { _, count in .init(repeating: 0, count: count) }, canContinue: { true },
        load: { _, _ in
          loads.withLock { $0 += 1 }
          return Analyzer.Runtime(
            stepSamples: 160, slots: 1, appendAndProcess: { _ in [] }, finish: { [] })
        })
    }
    defer { release.fire(); subject.cancel() }
    try await BoundedWait.until(entered)
    subject.cancel()
    release.fire()
    let outcome = try await BoundedWait.result(of: subject)
    #expect(throws: CancellationError.self) { try outcome.get() }
    #expect(loads.withLock { $0 } == 0)
  }

  @Test("cancellation during a suspended load is checked before any native step")
  func cancellationDuringLoad() async throws {
    let entered = BoundedWait.Signal()
    let release = BoundedWait.Signal()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let subject = Task {
      try await Analyzer.run(
        sampleCount: 160, directory: directory, preset: .offline,
        read: { _, count in .init(repeating: 0, count: count) }, canContinue: { true },
        load: { _, _ in
          entered.fire()
          try await BoundedWait.until(release)
          return Analyzer.Runtime(
            stepSamples: 160, slots: 1,
            appendAndProcess: { _ in calls.withLock { $0 += 1 }; return [] }, finish: { [] })
        })
    }
    defer { release.fire(); subject.cancel() }
    try await BoundedWait.until(entered)
    subject.cancel()
    release.fire()
    let outcome = try await BoundedWait.result(of: subject)
    #expect(throws: CancellationError.self) { try outcome.get() }
    #expect(calls.withLock { $0 } == 0)
  }

  @Test("cancellation at a processing boundary prevents the next chunk")
  func cancellationBetweenSteps() async throws {
    let entered = BoundedWait.Signal()
    let release = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let subject = Task {
      try await Analyzer.run(
        sampleCount: 320, directory: directory, preset: .offline,
        read: { _, count in .init(repeating: 0, count: count) }, canContinue: { true },
        load: { _, _ in
          Analyzer.Runtime(
            stepSamples: 160, slots: 1,
            appendAndProcess: { _ in
              calls.withLock { $0 += 1 }
              entered.fire()
              // deadline-fallback: a lost release fails the enclosing test instead of hanging.
              guard release.wait(timeout: .now() + 5) == .success else {
                throw Analyzer.Failure.invalidOutput
              }
              return [LiveSpeakerFrames(probabilities: [0.9], frameCount: 1)]
            }, finish: { [] })
        })
    }
    defer { release.signal(); subject.cancel() }
    try await BoundedWait.until(entered)
    subject.cancel()
    release.signal()
    let outcome = try await BoundedWait.result(of: subject)
    #expect(throws: CancellationError.self) { try outcome.get() }
    #expect(calls.withLock { $0 } == 1)
  }
}
