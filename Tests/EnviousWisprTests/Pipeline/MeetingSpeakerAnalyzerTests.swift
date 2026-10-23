import AVFoundation
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #3972 R25: when these fail, a meeting loses its words because speaker labelling failed, a
/// labelling worker keeps running after its unit ended, or a cancel is reported as a timeout.
@Suite("MeetingSpeakerAnalyzer", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSpeakerAnalyzerTests {
  private func track() throws -> MeetingTrackAudio {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakerAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = try MeetingAudioFixture.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000)
    return MeetingTrackAudio(files: [(url, 0)])
  }

  private func labeler(deadline: Double = 5) -> SpeakerLabeler {
    SpeakerLabeler(
      deadlineSecondsOverride: deadline,
      analysisTask: { _ in Task { [] } })
  }

  private func segment(_ id: String) -> SpeakerSegment {
    SpeakerSegment(speakerId: id, startMs: 0, endMs: 500, quality: 1)
  }

  @Test("two speakers are labeled, one is single, none is no speech, an error is failed")
  func outcomes() async throws {
    let audio = try track()
    let two = await MeetingSpeakerAnalyzer.analyze(
      audio, labeler: labeler(), makeWork: { _ in Task { [segment("a"), segment("b")] } })
    #expect(two.outcome == .labeled)
    #expect(two.segments.count == 2)
    let one = await MeetingSpeakerAnalyzer.analyze(
      audio, labeler: labeler(), makeWork: { _ in Task { [segment("a")] } })
    #expect(one.outcome == .single)
    let none = await MeetingSpeakerAnalyzer.analyze(
      audio, labeler: labeler(), makeWork: { _ in Task { [] } })
    #expect(none.outcome == .noSpeech)
    let failed = await MeetingSpeakerAnalyzer.analyze(
      audio, labeler: labeler(),
      makeWork: { _ in Task { throw BundledSpeakerModelLoader.LoadError.resourceNotFound("x") } })
    #expect(failed.outcome == .failed)
    #expect(failed.segments.isEmpty)
  }

  @Test("a timeout returns only after the worker physically finished, even a late one")
  func timeoutJoinsLateWorker() async throws {
    let audio = try track()
    let finished = OSAllocatedUnfairLock(initialState: false)
    let result = await MeetingSpeakerAnalyzer.analyze(
      audio, labeler: labeler(deadline: 0.05),
      makeWork: { _ in
        Task {
          // Ignores cancellation for a while, like a vendor step that cooperates late.
          while !Task.isCancelled { await Task.yield() }
          for _ in 0..<1_000 { await Task.yield() }
          finished.withLock { $0 = true }
          return [SpeakerSegment(speakerId: "a", startMs: 0, endMs: 1, quality: 1)]
        }
      })
    #expect(result.outcome == .timedOut)
    #expect(finished.withLock { $0 }, "the worker was still running when the unit ended")
  }

  @Test("a caller cancel is reported as failed (not a timeout) after joining the worker")
  func callerCancelJoins() async throws {
    let audio = try track()
    let finished = OSAllocatedUnfairLock(initialState: false)
    let started = AsyncStream<Void>.makeStream()
    let analysis = Task {
      await MeetingSpeakerAnalyzer.analyze(
        audio, labeler: labeler(deadline: 30),
        makeWork: { _ in
          Task {
            started.continuation.yield()
            while !Task.isCancelled { await Task.yield() }
            finished.withLock { $0 = true }
            throw CancellationError()
          }
        })
    }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    analysis.cancel()
    let result = await analysis.value
    #expect(result.outcome == .failed)
    #expect(finished.withLock { $0 })
  }
}
