#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #4355 PR B acceptance (G1/G2): a labelled echo case run through the shipped product path,
/// so the acceptance scorer reads what a user would get. Each case's microphone and call-sound
/// audio is replayed at real time through the real recorder and echo worker (fake capture
/// devices, the real library, the real files and proof), then the real meeting pass (installed
/// Parakeet Ultra, real speaker step, real composer) runs twice on the same call track: once on
/// the raw microphone and once on the cleaned copy the final pass selects, each with the copy the
/// product records for it, so the shipped rule applies (text echo hiding on raw only). Every
/// composed turn is written with its echo flag; on the raw arm the backstop-off view (all turns)
/// and the backstop-on view (turns not flagged) come from the SAME ASR pieces. Scoring is the run folder's, against
/// labels the product never sees.
///
/// Runs only when `EW_ECHO_ACCEPT_CASES` names a folder of cases (`<case>/mic.f32`,
/// `<case>/ref.f32`: 16 kHz mono float32, equal length) and `EW_ECHO_ACCEPT_OUT` a folder for
/// `<case>.json`. It asserts only that each arm produced a composition; the gates are scored
/// outside, from labels. Optional: `EW_ECHO_ACCEPT_REPEATS` (default 1) runs the meeting pass that
/// many times on the SAME raw and cleaned files (repeats are written as `<arm>#<n>`), and
/// `EW_ECHO_ACCEPT_KEEP_AUDIO=1` keeps the recorded files in `<out>/<case>-audio` for review.
@Suite(
  "Meeting echo acceptance instrument (#4355 PR B)",
  .tags(.productOutcome, .realBoundary), .realBoundaryRun, .serialized)
@MainActor
struct MeetingEchoAcceptanceInstrumentTests {
  typealias Fakes = MeetingRecorderTests

  nonisolated static var casesFolder: URL? {
    ProcessInfo.processInfo.environment["EW_ECHO_ACCEPT_CASES"].map { URL(filePath: $0) }
  }
  nonisolated static var outFolder: URL? {
    ProcessInfo.processInfo.environment["EW_ECHO_ACCEPT_OUT"].map { URL(filePath: $0) }
  }
  nonisolated static var repeats: Int {
    max(1, Int(ProcessInfo.processInfo.environment["EW_ECHO_ACCEPT_REPEATS"] ?? "") ?? 1)
  }
  nonisolated static var keepAudio: Bool {
    ProcessInfo.processInfo.environment["EW_ECHO_ACCEPT_KEEP_AUDIO"] == "1"
  }
  nonisolated static var enabled: Bool {
    casesFolder != nil && outFolder != nil && MeetingProcessingRealBoundaryTests.ultraIsInstalled
  }

  static func readFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  @Test(
    "labelled echo cases through the shipped recorder, echo worker and meeting pass",
    .enabled(if: MeetingEchoAcceptanceInstrumentTests.enabled),
    .timeLimit(.minutes(60)))
  func runCases() async throws {
    let root = try #require(Self.casesFolder)
    let out = try #require(Self.outFolder)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { FileManager.default.fileExists(atPath: root.appending(path: "\($0)/mic.f32").path) }
      .sorted()
    #expect(!names.isEmpty, "no cases in \(root.path)")
    for name in names {
      let mic = try Self.readFloats(root.appending(path: "\(name)/mic.f32"))
      let ref = try Self.readFloats(root.appending(path: "\(name)/ref.f32"))
      #expect(mic.count == ref.count, "\(name): mic and reference lengths differ")
      let record = try await runCase(name: name, mic: mic, ref: ref, out: out)
      let json = try JSONSerialization.data(
        withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
      try json.write(to: out.appending(path: "\(name).json"))
      print("MEETING_ECHO_ACCEPT case=\(name) written")
    }
  }

  private func runCase(name: String, mic: [Float], ref: [Float], out: URL) async throws
    -> [String: Any]
  {
    let folder = try MeetingAudioFixture.folder("MeetingEchoAccept-\(name)")
    defer {
      if Self.keepAudio {
        let kept = out.appending(path: "\(name)-audio")
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.copyItem(at: folder, to: kept)
      }
      try? FileManager.default.removeItem(at: folder)
    }
    let microphone = Fakes.FakeMicrophone()
    let calls = Fakes.Box<[Fakes.FakeCallSound]>([])
    let clock = Fakes.Clock()
    var sources = MeetingRecorder.Sources(
      makeMicrophone: { microphone },
      makeCallSound: { handler, _, onReport in
        let fake = Fakes.FakeCallSound(handler: handler, onReport: onReport)
        calls.value.append(fake)
        return fake
      },
      hostTime: { clock.now.withLock { $0 } }, reopenDelay: {})
    sources.echoPumpInterval = .milliseconds(10)
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: true, microphoneUID: nil,
        inputChannelByDeviceUID: [:]),
      sources: sources, onSegment: { _, _ in }, onFailure: { _, _ in })
    let started = try await recorder.start()
    let call = try #require(calls.value.first)

    // Real time: 10 ms of call sound then 10 ms of microphone, each 100 ms of audio released
    // when the wall clock reaches it, as capture would deliver it.
    let chunk = 160
    let total = mic.count - mic.count % chunk
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for start in stride(from: 0, to: total, by: chunk) {
      clock.advance(seconds: Double(chunk) / 16_000)
      let chunkStart =
        clock.now.withLock { $0 } &- MeetingRecorder.hostTicks(forSeconds: Double(chunk) / 16_000)
      Array(ref[start..<(start + chunk)]).withUnsafeBufferPointer {
        call.handler($0, chunkStart, false)
      }
      microphone.onSamples?(Array(mic[start..<(start + chunk)]), 0.2)
      if (start / chunk) % 10 == 9 {
        let due = wallStart + UInt64(Double(start + chunk) / 16_000 * 1e9)
        let now = DispatchTime.now().uptimeNanoseconds
        if due > now {
          // test-fixture-timer: real-time replay pacing (capture delivers audio at this rate).
          try await Task.sleep(nanoseconds: due - now)
        }
        recorder.pumpEchoForTesting()
      }
    }
    let report = await recorder.stop()

    let recovered = MeetingTrackRecovery.recover(folder: folder)
    let raw = recovered.segments[.microphone] ?? []
    let callSegments = recovered.segments[.callSound] ?? []
    func audio(_ segments: [MeetingSegmentInfo]) -> MeetingTrackAudio {
      MeetingTrackAudio(
        files: segments.map { (folder.appendingPathComponent($0.fileName), $0.startMs) })
    }
    let selection = MeetingMicrophoneSelection.decide(
      raw: raw, report: recovered, provenance: started.echoProvenance)
    guard case .cleaned(let twins, let provenance) = selection else {
      Issue.record("\(name): the cleaned copy was not chosen: \(selection)")
      return ["case": name, "error": "cleaned copy not chosen"]
    }
    let rawAudio = audio(raw)
    let cleanedAudio = audio(twins)
    let callAudio = audio(callSegments)

    var arms: [String: Any] = [:]
    // Each arm passes the copy the product's final pass would record for it, so the pass applies
    // the shipped rule (text echo hiding on the raw microphone only).
    let copies: [(String, MeetingTrackAudio, MeetingMicrophoneCopy)] = [
      ("raw", rawAudio, .raw(started.echoProvenance)),
      ("cleaned", cleanedAudio, .cleaned(provenance)),
    ]
    let runs = (1...Self.repeats).flatMap { n in
      copies.map { (n == 1 ? $0.0 : "\($0.0)#\(n)", $0.1, $0.2) }
    }
    for (arm, micAudio, copy) in runs {
      let (job, _) = try MeetingProcessingRealBoundaryTests().realJob()
      let result = try await job.run(
        tracks: [.microphone: micAudio, .callSound: callAudio], microphoneCopy: copy,
        language: nil, onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: nil))
      let composition = result.composition
      let echo = Set(composition.echoTurnIDs)
      let utf16 = Array(composition.text.utf16)
      let turns: [[String: Any]] = composition.turns.map { turn in
        let lower = max(0, min(turn.originalTextRange.lowerBound, utf16.count))
        let upper = max(lower, min(turn.originalTextRange.upperBound, utf16.count))
        return [
          "id": turn.id, "speaker": turn.speakerId,
          "track": turn.speakerId.hasPrefix("mic:") ? "microphone" : "callSound",
          "startMs": turn.startMs ?? -1, "endMs": turn.endMs ?? -1,
          "text": String(decoding: utf16[lower..<upper], as: UTF16.self),
          "echo": echo.contains(turn.id),
        ]
      }
      arms[arm] = [
        "turns": turns, "failedPieces": result.failedPieces,
        "speakerOutcomes": result.speakerOutcomes.reduce(into: [String: String]()) {
          $0[$1.key.rawValue] = $1.value.rawValue
        },
      ]
      print(
        "MEETING_ECHO_ACCEPT case=\(name) arm=\(arm) turns=\(turns.count) echo=\(echo.count)")
    }
    let summary = report.echoSummary
    return [
      "case": name, "samples": total,
      "wallSeconds": Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1e9,
      "echo": [
        "eligibleSamples": summary?.eligibleSamples ?? -1,
        "passthroughSamples": summary?.passthroughSamples ?? -1,
        "init": summary?.initOutcome?.rawValue ?? "unknown",
        "resets": summary?.resetCount ?? -1,
      ],
      "rawSamples": raw.reduce(0) { $0 + $1.frameCount },
      "cleanedSamples": twins.reduce(0) { $0 + $1.frameCount },
      "arms": arms,
    ]
  }
}
#endif
