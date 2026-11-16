import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit

/// #4021: `audio.core_audio_read_stuck` is the only fleet signal that a Core Audio read got no
/// answer (or later recovered). When these fail, the post-release check would read a wrong or
/// missing count, or the event would carry something it must not.
#if DEBUG
@MainActor
@Suite("Core Audio read telemetry", .tags(.observabilityContract))
struct CoreAudioReadTelemetryTests {
  /// Installs the test hook, runs `body` synchronously, restores it (never across an await).
  private func capture(_ body: () -> Void) -> [CapturedTelemetryEvent] {
    let events = OSAllocatedUnfairLock(initialState: [CapturedTelemetryEvent]())
    TelemetryService.shared.testEventHook = { event in
      if event.name == "audio.core_audio_read_stuck" { events.withLock { $0.append(event) } }
    }
    defer { TelemetryService.shared.testEventHook = nil }
    body()
    return events.withLock { $0 }
  }

  @Test("A timeout sends read, phase and bound only")
  func timedOutShape() {
    let events = capture {
      CoreAudioLaneReporting.report(
        name: "device_snapshot", phase: .timedOut, bound: .seconds(1), returnedAfter: nil)
    }
    #expect(
      events == [
        CapturedTelemetryEvent(
          name: "audio.core_audio_read_stuck",
          stringProps: ["read": "device_snapshot", "phase": "timed_out"],
          intProps: ["bound_ms": 1000])
      ])
  }

  @Test("A recovery adds how long the read took, with the bound that read was given")
  func recoveredShape() {
    let events = capture {
      CoreAudioLaneReporting.report(
        name: "choice_validation", phase: .recovered, bound: .milliseconds(1500),
        returnedAfter: .milliseconds(4250))
    }
    #expect(
      events == [
        CapturedTelemetryEvent(
          name: "audio.core_audio_read_stuck",
          stringProps: ["read": "choice_validation", "phase": "recovered"],
          intProps: ["bound_ms": 1500, "returned_after_ms": 4250])
      ])
  }

  /// #4601 §3.8: the audio-unit lane's stuck jobs reach the same event with their own reads.
  @Test("A stuck microphone start and its recovery send microphone_start with the job's limit")
  func audioUnitLaneShapes() {
    let events = capture {
      AudioUnitLaneReporting.report(
        name: "microphone_start", phase: .timedOut, limit: .seconds(5), after: nil)
      AudioUnitLaneReporting.report(
        name: "microphone_start", phase: .recovered, limit: .seconds(5), after: .milliseconds(7300))
      AudioUnitLaneReporting.report(
        name: "running_probe", phase: .timedOut, limit: .seconds(1), after: nil)
      AudioUnitLaneReporting.report(
        name: "microphone_release", phase: .timedOut, limit: .seconds(5), after: nil)
      AudioUnitLaneReporting.report(name: "not_a_lane_job", phase: .timedOut, limit: .seconds(1), after: nil)
    }
    #expect(
      events == [
        CapturedTelemetryEvent(
          name: "audio.core_audio_read_stuck",
          stringProps: ["read": "microphone_start", "phase": "timed_out"],
          intProps: ["bound_ms": 5000]),
        CapturedTelemetryEvent(
          name: "audio.core_audio_read_stuck",
          stringProps: ["read": "microphone_start", "phase": "recovered"],
          intProps: ["bound_ms": 5000, "returned_after_ms": 7300]),
        CapturedTelemetryEvent(
          name: "audio.core_audio_read_stuck",
          stringProps: ["read": "microphone_probe", "phase": "timed_out"],
          intProps: ["bound_ms": 1000]),
        CapturedTelemetryEvent(
          name: "audio.core_audio_read_stuck",
          stringProps: ["read": "microphone_release", "phase": "timed_out"],
          intProps: ["bound_ms": 5000]),
      ])
  }

  /// Every job name the lane is given in the shipped code has a row in the mapping, so a stuck
  /// job is never silently dropped. Reads the two submitting files' literal names; the lane's
  /// own default release name is listed by hand.
  @Test("Every audio-unit lane job name maps to the event vocabulary")
  func everyLaneJobNameIsMapped() throws {
    var names: Set<String> = ["microphone_release"]
    let pattern = try NSRegularExpression(pattern: #"lane\.(?:run|open)\(\s*"([a-z_]+)""#)
    for file in [
      "Sources/EnviousWisprAudio/HALDeviceInputSource.swift",
      "Sources/EnviousWisprAudio/AudioCaptureManager.swift",
    ] {
      let text = try String(contentsOf: RepoRoot.url.appending(path: file), encoding: .utf8)
      for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
      }
    }
    #expect(names.count >= 8, "the scan found too few names: \(names.sorted())")
    #expect(Set(AudioUnitLaneReporting.readForOperation.keys) == names)
  }

  @Test("A timeout never carries returned_after_ms, and an unknown read name sends nothing")
  func omissionsAndClosedVocabulary() {
    let timedOut = capture {
      TelemetryService.shared.coreAudioReadStuck(
        read: .deviceSnapshot, phase: .timedOut, boundMs: 1000, returnedAfterMs: 999)
    }
    #expect(timedOut.first?.intProps == ["bound_ms": 1000])
    let unknown = capture {
      CoreAudioLaneReporting.report(
        name: "some free text", phase: .timedOut, bound: .seconds(1), returnedAfter: nil)
    }
    #expect(unknown.isEmpty)

    // Every property that reaches the vendors, whatever its type: exactly these keys.
    let keys = OSAllocatedUnfairLock(initialState: [Set<String>]())
    TelemetryService.shared.testRawPropertiesHook = { name, props in
      guard name == "audio.core_audio_read_stuck" else { return }
      let names = Set(props.keys)
      keys.withLock { $0.append(names) }
    }
    defer { TelemetryService.shared.testRawPropertiesHook = nil }
    TelemetryService.shared.coreAudioReadStuck(read: .choiceValidation, phase: .recovered, boundMs: 1000, returnedAfterMs: 2000)
    TelemetryService.shared.coreAudioReadStuck(read: .deviceSnapshot, phase: .timedOut, boundMs: 1000)
    #expect(
      keys.withLock { $0 } == [
        ["read", "phase", "bound_ms", "returned_after_ms"], ["read", "phase", "bound_ms"],
      ], "no device name, UID or other content")
    #expect(
      Set(CoreAudioReadTelemetry.Read.allCases.map(\.rawValue)) == [
        "device_snapshot", "choice_validation", "microphone_start", "microphone_release",
        "microphone_probe",
      ])
    #expect(
      Set(CoreAudioReadTelemetry.Phase.allCases.map(\.rawValue)) == ["timed_out", "recovered"])
  }
}
#endif
