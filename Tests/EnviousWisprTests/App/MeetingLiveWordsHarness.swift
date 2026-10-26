import Darwin
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview
@testable import EnviousWisprWhisperPreviewAdapter

/// #3973 G1 measurement harness (off unless `EW_MLW_DIR` is set). Plays a two-track meeting
/// (`mic.wav` = You, `call.wav` = the call) in real time, 100 ms chunks on the wall clock, into the
/// shipped `MeetingLiveWords` owner with the production engines: Apple's meeting module through
/// `ApplePreviewEngineResolver.resolveMeeting` (#4105), or the Universal engine through the production meeting
/// route (`WhisperPreviewDeliveryWiring.meetingResolver`) over the installed model. The owner's
/// pumps, restart, bridge and assembler all run as in a meeting. Every 250 ms the harness writes each
/// track's live text (its lines, joined) when it changed, and every 5 s the process footprint, in
/// the event format `score.py` reads (docs/audits/2026-10-24-live-words-proof/REPORT.md).
///
/// Env (prefix with `TEST_RUNNER_` through `scripts/xcode-test.sh`): EW_MLW_DIR (meeting folder
/// with mic.wav, call.wav), EW_MLW_ENGINE (apple | universal), EW_MLW_LANGUAGE (BCP-47 tag such as
/// en-US, required: the meeting row has no Auto), EW_MLW_OUT
/// (events file, never overwritten), EW_MLW_MODEL (Universal gguf path).
@MainActor
@Suite(
  "Meeting live words harness (#3973 G1)", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_MLW_DIR"] != nil))
struct MeetingLiveWordsHarness {
  nonisolated static func loadWAV(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    // 44-byte RIFF header written by Python's wave module, 16 kHz mono 16-bit.
    return data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
      raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
    }
  }

  nonisolated static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  nonisolated static func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }

  /// A track's live text as History shows it: its lines in order, joined.
  static func text(_ live: MeetingLiveWords.Transcript?, _ track: MeetingTrackKind) -> String {
    (live?.lines ?? []).filter { $0.track == track }.map(\.text).joined(separator: " ")
  }

  static func status(_ status: MeetingLiveWords.Status?) -> String {
    guard let status else { return "none" }
    return String(describing: status)
  }

  @Test("play one meeting through MeetingLiveWords", .timeLimit(.minutes(90)))
  func run() async throws {
    let env = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: try #require(env["EW_MLW_DIR"]))
    let engine = try #require(env["EW_MLW_ENGINE"])
    let lang = try #require(env["EW_MLW_LANGUAGE"], "EW_MLW_LANGUAGE is required (BCP-47)")
    let outURL = URL(fileURLWithPath: try #require(env["EW_MLW_OUT"]))
    try #require(!FileManager.default.fileExists(atPath: outURL.path), "refusing to overwrite")
    let mic = try Self.loadWAV(dir.appending(path: "mic.wav"))
    let call = try Self.loadWAV(dir.appending(path: "call.wav"))
    let total = max(mic.count, call.count)

    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL)
    let writeLock = OSAllocatedUnfairLock()
    @Sendable func emit(_ object: [String: Any]) {
      guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      else { return }
      writeLock.withLock {
        out.write(d)
        out.write(Data([0x0A]))
      }
    }
    emit([
      "kind": "header", "engine": engine, "lang": lang, "seconds": Double(total) / 16_000,
      "idle_footprint_mb": Self.footprintMB(), "path": "MeetingLiveWords",
    ])

    let mode: LanguageMode = .locked(lang)
    let universal: @Sendable (LanguageMode) async -> MeetingLiveWords.UniversalResolution
    switch engine {
    case "apple":
      universal = { _ in .blocked(.modelNotInstalled) }
    case "universal":
      let modelPath = try #require(env["EW_MLW_MODEL"])
      universal = WhisperPreviewDeliveryWiring.meetingResolver(
        WhisperPreviewEngineResolver.Environment(
          artifactIdentity: "harness", modelPath: modelPath, isAdmitted: { true },
          isHeartStreaming: { false }))
    default:
      Issue.record("unknown engine \(engine)")
      return
    }
    let owner = MeetingLiveWords(
      dependencies: .init(
        appleSupported: { engine == "apple" && ApplePreviewEngineResolver.isSupportedOnThisSystem },
        resolveApple: { _ in await ApplePreviewEngineResolver.resolveMeeting(languageTag: lang) },
        resolveUniversal: universal,
        isHeartStreaming: { false }))

    let meetingID = UUID()
    let clock = ContinuousClock()
    let observer = owner.prepareCapture(meetingID: meetingID)
    let start = clock.now
    owner.captureStarted(
      meetingID: meetingID, captured: [.microphone, .callSound], language: mode,
      vocabulary: LivePreviewVocabulary(
        lookups: nil, contextualPhrases: [], dictionaryEnabled: false),
      clock: { Int(Self.seconds(clock.now - start) * 1000) })

    // Sampler: each track's text every 250 ms when changed, footprint every 5 s, statuses on change.
    let sampler = Task { @MainActor in
      var last: [String: String] = [:]
      var lastStatus = ""
      var tick = 0
      var peak = 0.0
      while !Task.isCancelled {
        // settle: fixed 250 ms sampling period of a real-time measurement, not a wait for state.
        try? await Task.sleep(for: .milliseconds(250))
        let t = Self.seconds(clock.now - start)
        let live = owner.transcript
        for (name, track) in [("mic", MeetingTrackKind.microphone), ("call", .callSound)] {
          let text = Self.text(live, track)
          if last[name] != text {
            last[name] = text
            emit(["kind": "text", "t": t, "track": name, "text": String(text.suffix(1500))])
          }
        }
        let statuses =
          "\(Self.status(live?.tracks[.microphone]?.status))|\(Self.status(live?.tracks[.callSound]?.status))"
        if statuses != lastStatus {
          lastStatus = statuses
          emit([
            "kind": "status", "t": t,
            "mic": Self.status(live?.tracks[.microphone]?.status),
            "call": Self.status(live?.tracks[.callSound]?.status),
            "dropped": (live?.tracks.values.contains { $0.droppedAudio }) ?? false,
          ])
        }
        tick += 1
        if tick % 20 == 0 {
          let mb = Self.footprintMB()
          peak = max(peak, mb)
          emit(["kind": "load", "t": t, "footprint_mb": mb, "peak_mb": peak, "cpu_pct": 0])
        }
      }
    }
    emit(["kind": "prepared", "seconds": 0, "footprint_mb": Self.footprintMB()])

    // Feed both tracks on the recording clock, from a non-main task as the capture threads do.
    let feeder = Task.detached {
      let chunk = 1_600
      var i = 0
      while i * chunk < total {
        let lo = i * chunk
        for (track, samples) in [(MeetingTrackKind.microphone, mic), (.callSound, call)]
        where lo < samples.count {
          samples[lo..<min(samples.count, lo + chunk)].withUnsafeBufferPointer {
            observer(track, $0)
          }
        }
        i += 1
        // settle: real-time playback; chunk i is due at start + i x 100 ms.
        try? await Task.sleep(until: start + .milliseconds(100 * i), clock: clock)
      }
    }
    await feeder.value
    // settle: the engines keep decoding after the audio ends; 20 s lets the last words land.
    try await Task.sleep(for: .seconds(20))
    sampler.cancel()
    _ = await sampler.value
    let final = owner.transcript
    owner.stop()
    let cleaned = await owner.waitForCleanups(seconds: 30)
    emit([
      "kind": "end", "wall_seconds": Self.seconds(clock.now - start),
      "footprint_mb": Self.footprintMB(), "cleanup_finished": cleaned,
      "lines": final?.lines.count ?? 0,
      "mic": Self.status(final?.tracks[.microphone]?.status),
      "call": Self.status(final?.tracks[.callSound]?.status),
    ])
    try out.close()
    #expect(cleaned, "cleanup finished within 30 s")
    #expect(!(final?.lines.isEmpty ?? true), "live words appeared")
  }
}
