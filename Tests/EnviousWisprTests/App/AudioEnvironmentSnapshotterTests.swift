import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprServices

@Suite("AudioEnvironmentSnapshotter")
@MainActor
struct AudioEnvironmentSnapshotterTests {
  private struct FakeCollector: AudioEnvironmentCollecting {
    func collect(
      reason: AudioEnvironmentSnapshot.Reason,
      route: String?,
      frontmostAppBundleID: String?,
      deviceEventRecentMs: Int?,
      capturedAt: Date
    ) -> AudioEnvironmentSnapshot {
      AudioEnvironmentSnapshot(
        reason: reason,
        capturedAt: capturedAt,
        inputProcessCount: 1,
        outputProcessCount: 2,
        inputBundleIDs: ["com.example.input"],
        outputBundleIDs: ["com.example.output"],
        frontmostAppBundleID: frontmostAppBundleID,
        inputDeviceUIDDefault: "InputDevice",
        outputDeviceUIDDefault: "OutputDevice",
        route: route,
        bluetoothOutputActive: false,
        deviceEventRecentMs: deviceEventRecentMs
      )
    }
  }

  @Test("recording start refresh publishes cached snapshot")
  func recordingStartRefreshPublishesSnapshot() async throws {
    let snapshotter = AudioEnvironmentSnapshotter(
      collector: FakeCollector(),
      routeProvider: { "built_in_mic" },
      now: { Date(timeIntervalSince1970: 100) }
    )

    snapshotter.recordingStarted()
    let context = try await latestContext(from: snapshotter)

    #expect(context["snapshot_reason"] as? String == "recording_start")
    #expect(context["snapshot_status"] as? String == "fresh")
    #expect(context["route"] as? String == "built_in_mic")
    #expect(context["input_process_count"] as? Int == 1)
  }

  @Test("device event refresh includes recent event age")
  func deviceEventRefreshIncludesRecentEventAge() async throws {
    var currentDate = Date(timeIntervalSince1970: 100)
    let snapshotter = AudioEnvironmentSnapshotter(
      collector: FakeCollector(),
      routeProvider: { "bt_headset" },
      now: { currentDate }
    )

    snapshotter.audioDeviceEventOccurred()
    currentDate = Date(timeIntervalSince1970: 100.25)
    let context = try await latestContext(from: snapshotter)

    #expect(context["snapshot_reason"] as? String == "audio_device_event")
    #expect(context["device_event_recent_ms"] as? Int == 0)
  }

  private func latestContext(
    from snapshotter: AudioEnvironmentSnapshotter
  ) async throws -> [String: Any] {
    for _ in 0..<50 {
      if let context = snapshotter.latestForError() {
        return context
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("snapshot did not publish")
    return [:]
  }
}
