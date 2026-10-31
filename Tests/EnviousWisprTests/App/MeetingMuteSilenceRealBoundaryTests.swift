import AVFoundation
import Darwin
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview
@testable import EnviousWisprWhisperPreviewAdapter

/// #4248 P4 input and oracle, shared by the final-pass cases (`MeetingProcessingRealBoundaryTests`)
/// and the live-words cases below.
///
/// Speech: `Tests/Fixtures/speaker-diarization/two-voice-30s.wav`, four sentences read by macOS
/// voices (`generate-fixture.sh` holds the literal text). Layout: 2 s of exact zeros, the first
/// part of the speech, 3.05 s of exact zeros starting off a 100 ms feed boundary (so it crosses
/// feed chunks), the rest of the speech, 2 s of exact zeros. Every case goes through the real
/// microphone `MeetingTrackWriter` with its 3 s silence hold; the all-zero case is the whole
/// speech silenced by the hold's own intervals.
enum MuteSilenceP4 {
  static let fixture = WhisperProductionWiringRealBoundaryTests.repoRoot
    .appending(path: "Tests/Fixtures/speaker-diarization/two-voice-30s.wav")

  static let sentences = [
    "Thanks for jumping on the call today. I wanted to walk through the numbers from last quarter before we finalize the roadmap.",
    "Sure, happy to dive in. I looked at the report this morning and a couple of the regional figures caught my attention.",
    "Which regions are you thinking of? The west coast numbers came in a bit higher than we forecasted.",
    "Exactly, the west coast and also the southern market grew faster than expected, so we might need to adjust the staffing plan.",
  ]

  static func words(_ text: String) -> [String] {
    text.lowercased().split { !($0.isLetter || $0 == "'") }.map(String.init)
  }

  static let vocabulary = Set(sentences.flatMap(words))

  static let chunk = 1_600

  struct Layout: Sendable {
    let samples: [Float]
    /// Exact-zero spans inserted around the speech, in samples.
    let zeroSpans: [Range<Int>]
  }

  static func speech() throws -> [Float] {
    let file = try AVAudioFile(forReading: fixture)
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    #expect(file.processingFormat.sampleRate == 16_000)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }

  /// Splits the speech at its quietest 100 ms between 40% and 60% (a pause between turns).
  static func layout(_ speech: [Float]) -> Layout {
    let window = 1_600
    var best = speech.count / 2
    var bestEnergy = Float.infinity
    var at = speech.count * 2 / 5
    while at + window < speech.count * 3 / 5 {
      let energy = speech[at..<(at + window)].reduce(0) { $0 + $1 * $1 }
      if energy < bestEnergy {
        bestEnergy = energy
        best = at + window / 2
      }
      at += window / 4
    }
    let head = 32_000
    let middle = 48_800
    let tail = 32_000
    var samples = [Float](repeating: 0, count: head)
    samples += speech[0..<best]
    let middleStart = samples.count
    samples += [Float](repeating: 0, count: middle)
    samples += speech[best...]
    let tailStart = samples.count
    samples += [Float](repeating: 0, count: tail)
    return Layout(
      samples: samples,
      zeroSpans: [0..<head, middleStart..<(middleStart + middle), tailStart..<(tailStart + tail)])
  }

  /// Writes `samples` through a real held microphone writer in 100 ms appends; `silenceAll`
  /// silences the whole recording with the hold's own interval. Returns the finished segments.
  static func throughGate(_ samples: [Float], silenceAll: Bool, into dir: URL) async throws
    -> MeetingTrackAudio
  {
    let anchor = mach_absolute_time()
    let writer = MeetingTrackWriter(
      configuration: .init(
        meetingID: UUID(), track: .microphone, folder: dir, anchorHostTime: anchor,
        // Appended far faster than real time: the handoff must hold the whole recording.
        bufferCapacity: samples.count + chunk, maxPendingChunks: samples.count / chunk + 8,
        silenceHoldSeconds: 3.0),
      onSegmentFinalized: { _ in }, onFailure: { _ in })
    if silenceAll {
      writer.setSilencedIntervals([MeetingSilenceInterval(start: anchor, end: .max)])
    }
    var offset = 0
    while offset < samples.count {
      let n = min(chunk, samples.count - offset)
      samples[offset..<(offset + n)].withUnsafeBufferPointer {
        writer.append($0, hostTime: anchor &+ MeetingMicrophoneSilence.ticks(forSamples: offset))
      }
      offset += n
    }
    #expect(await writer.finish() == .finalized)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .compactMap { name in MeetingSegmentNaming.parse(name).map { (name, $0) } }
      .filter { $0.1.track == .microphone && !$0.0.hasSuffix(".partial") }
      .sorted { $0.1.index < $1.1.index }
    let audio = MeetingTrackAudio(
      files: names.map { (dir.appendingPathComponent($0.0), $0.1.startMs) })
    print(
      "P4 gate wrote=\(samples.count) files=\(names.map(\.0)) segments=\(audio.segments.map { "\($0.startSample)+\($0.frameCount)" }) problems=\(audio.problems) health=\(writer.currentHealth)"
    )
    return audio
  }

  /// Every decoded sample of the segments.
  static func decoded(_ audio: MeetingTrackAudio) throws -> [Float] {
    var all: [Float] = []
    for url in audio.segments.map(\.url) {
      let file = try AVAudioFile(forReading: url)
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
      try file.read(into: buffer)
      let channel = try #require(buffer.floatChannelData?[0])
      all += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    }
    return all
  }

  /// Words in `output` that neither the speech nor the unmodified control produced.
  static func invented(_ output: [String], control: [String]) -> [String] {
    let known = vocabulary.union(control)
    return output.filter { !known.contains($0) }
  }

  static func receipt(_ route: String, _ label: String, _ text: String, extra: String = "") {
    print("P4 route=\(route) case=\(label) words=\(words(text).count) \(extra) text=\(text)")
  }
}

/// #4248 P4 on the meeting's two live-words engines: when these fail, the live card shows words
/// the user never said while EnviousMeet was silencing their muted microphone.
@Suite("Meeting mute silence on real live-words engines", .serialized, .tags(.productOutcome))
@MainActor
struct MeetingMuteSilenceRealBoundaryTests {

  private func folder(_ label: String) throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("MuteSilenceP4-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The finalized text one transcript session delivers for `samples`, fed in 100 ms chunks;
  /// returns once `end()` has delivered the session's `.ended`.
  private func transcribe(_ samples: [Float], on engine: any LivePreviewEngine) async throws
    -> String
  {
    let finalized = OSAllocatedUnfairLock(initialState: "")
    let ended = OSAllocatedUnfairLock<LiveWordsEnd?>(initialState: nil)
    let updates = OSAllocatedUnfairLock(initialState: 0)
    let session = try await engine.openTranscriptSession(
      vocabulary: LivePreviewVocabulary(
        lookups: nil, contextualPhrases: [], dictionaryEnabled: false),
      onEvent: { event in
        switch event {
        // Each update carries only the newly finalized words (a delta), in order.
        case .update(let done, _):
          updates.withLock { $0 += 1 }
          if !done.isEmpty { finalized.withLock { $0 += ($0.isEmpty ? "" : " ") + done } }
        case .ended(let reason): ended.withLock { $0 = reason }
        case .discontinuity: break
        }
      })
    // Real-time playback, as capture delivers it: the live engines are built for 100 ms every
    // 100 ms and do not keep up with audio handed over faster.
    let clock = ContinuousClock()
    let start = clock.now
    var offset = 0
    var index = 0
    while offset < samples.count {
      let n = min(MuteSilenceP4.chunk, samples.count - offset)
      await session.feed(Array(samples[offset..<(offset + n)]))
      offset += n
      index += 1
      // settle: real-time playback; chunk i is due at start + i x 100 ms.
      try await Task.sleep(until: start + .milliseconds(100 * index), clock: clock)
    }
    // end() delivers every accepted final, then exactly one .ended, before it returns.
    await session.end()
    let end = ended.withLock { $0 }
    print("P4 session end=\(String(describing: end)) updates=\(updates.withLock { $0 })")
    #expect(end == .requested, "the session ended because it was asked to")
    return finalized.withLock { $0 }
  }

  /// Control, layout and all-zero cases on one engine, with the P4 verdict.
  private func runCases(route: String, engine: any LivePreviewEngine) async throws {
    let speech = try MuteSilenceP4.speech()
    let layout = MuteSilenceP4.layout(speech)
    let dir = try folder(route)
    defer { try? FileManager.default.removeItem(at: dir) }

    let controlAudio = try await MuteSilenceP4.throughGate(
      speech, silenceAll: false,
      into: dir.appendingPathComponent("control", isDirectory: true).created())
    let layoutAudio = try await MuteSilenceP4.throughGate(
      layout.samples, silenceAll: false,
      into: dir.appendingPathComponent("layout", isDirectory: true).created())
    let zeroAudio = try await MuteSilenceP4.throughGate(
      speech, silenceAll: true,
      into: dir.appendingPathComponent("zero", isDirectory: true).created())
    let zero = try MuteSilenceP4.decoded(zeroAudio)
    #expect(zero.count == speech.count && zero.allSatisfy { $0 == 0 }, "the hold wrote exact zeros")
    let laidOut = try MuteSilenceP4.decoded(layoutAudio)
    #expect(laidOut.count == layout.samples.count)
    for span in layout.zeroSpans where span.upperBound <= laidOut.count {
      #expect(laidOut[span].allSatisfy { $0 == 0 })
    }

    let control = try await transcribe(try MuteSilenceP4.decoded(controlAudio), on: engine)
    let spliced = try await transcribe(laidOut, on: engine)
    let silent = try await transcribe(zero, on: engine)
    let spans = layout.zeroSpans.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(
      separator: ",")
    MuteSilenceP4.receipt(route, "control", control)
    MuteSilenceP4.receipt(
      route, "layout", spliced, extra: "zero_spans=\(spans) feed=\(MuteSilenceP4.chunk)")
    MuteSilenceP4.receipt(route, "all_zero", silent)

    let controlWords = MuteSilenceP4.words(control)
    #expect(controlWords.count >= 20, "the unmodified speech is transcribed")
    #expect(MuteSilenceP4.words(silent).isEmpty, "exact zeros produce no words")
    let splicedWords = MuteSilenceP4.words(spliced)
    #expect(splicedWords.count >= 20, "speech around the zero spans is kept")
    #expect(
      MuteSilenceP4.invented(splicedWords, control: controlWords).isEmpty,
      "no word outside the speech and the control")
  }

  @Test(
    "P4: Apple's meeting live words invent nothing from exact zeros and keep the speech",
    .tags(.realBoundary), .realBoundaryRun, .timeLimit(.minutes(6)))
  func appleLiveWords() async throws {
    let resolution = await ApplePreviewEngineResolver.resolveMeeting(languageTag: "en-US")
    guard case .ready(let candidate) = resolution else {
      Issue.record("Apple meeting module not ready on this Mac: \(resolution)")
      return
    }
    let engine = candidate.makeEngine()
    try await engine.prepare()
    try await runCases(route: "apple-live", engine: engine)
  }

  @Test(
    "P4: Universal live words invent nothing from exact zeros and keep the speech",
    .enabled(if: WhisperProductionWiringRealBoundaryTests.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun, .timeLimit(.minutes(10)))
  func universalLiveWords() async throws {
    let resolve = WhisperPreviewDeliveryWiring.meetingResolver(
      WhisperPreviewEngineResolver.Environment(
        artifactIdentity: "p4",
        modelPath: WhisperProductionWiringRealBoundaryTests.evaluationModel.path,
        isAdmitted: { true }, isHeartStreaming: { false }))
    guard case .ready(let makeEngine) = await resolve(.locked("en")) else {
      Issue.record("Universal meeting engine not ready")
      return
    }
    let shared = makeEngine({})
    try await shared.prepare()
    do {
      try await runCases(route: "universal-live", engine: shared.recognizer)
    } catch {
      await shared.beginRelease().value
      throw error
    }
    await shared.beginRelease().value
  }
}

extension URL {
  /// Creates this directory and returns it.
  fileprivate func created() throws -> URL {
    try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    return self
  }
}
