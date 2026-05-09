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
      deviceEventAt: Date?,
      capturedAt: Date
    ) -> AudioEnvironmentSnapshot {
      AudioEnvironmentSnapshot(
        reason: reason,
        capturedAt: capturedAt,
        inputProcessCount: 1,
        outputProcessCount: 2,
        inputBundleIDs: ["com.zoom.xos"],
        outputBundleIDs: ["com.spotify.client"],
        frontmostAppBundleID: frontmostAppBundleID,
        inputDeviceTransport: "built_in",
        outputDeviceTransport: "bluetooth",
        route: route,
        bluetoothOutputActive: false,
        deviceEventAt: deviceEventAt
      )
    }
  }

  private struct UnavailableCollector: AudioEnvironmentCollecting {
    func collect(
      reason: AudioEnvironmentSnapshot.Reason,
      route: String?,
      frontmostAppBundleID: String?,
      deviceEventAt: Date?,
      capturedAt: Date
    ) -> AudioEnvironmentSnapshot {
      .unavailable(
        reason: reason,
        capturedAt: capturedAt,
        route: route,
        frontmostAppBundleID: frontmostAppBundleID,
        deviceEventAt: deviceEventAt,
        unavailableReason: "process object list unavailable"
      )
    }
  }

  private final class OutOfOrderCollector: AudioEnvironmentCollecting, @unchecked Sendable {
    func collect(
      reason: AudioEnvironmentSnapshot.Reason,
      route: String?,
      frontmostAppBundleID: String?,
      deviceEventAt: Date?,
      capturedAt: Date
    ) -> AudioEnvironmentSnapshot {
      if reason == .recordingStart {
        Thread.sleep(forTimeInterval: 0.2)
      }
      return AudioEnvironmentSnapshot(
        reason: reason,
        capturedAt: capturedAt,
        inputBundleIDs: [reason == .recordingStart ? "com.zoom.xos" : "com.spotify.client"],
        route: route,
        deviceEventAt: deviceEventAt
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
    let inputCategories = context["input_app_category_counts"] as? [String: Int]
    #expect(inputCategories?["meeting"] == 1)
  }

  @Test("device event age is computed at error render time")
  func deviceEventRefreshIncludesRecentEventAge() async throws {
    var currentDate = Date(timeIntervalSince1970: 100)
    let snapshotter = AudioEnvironmentSnapshotter(
      collector: FakeCollector(),
      routeProvider: { "bt_headset" },
      now: { currentDate }
    )

    snapshotter.audioDeviceEventOccurred()
    currentDate = Date(timeIntervalSince1970: 100.5)
    let context = try await latestContext(from: snapshotter)

    #expect(context["snapshot_reason"] as? String == "audio_device_event")
    #expect(context["device_event_recent_ms"] as? Int == 500)
  }

  @Test("unavailable collector result is cached")
  func unavailableCollectorResultIsCached() async throws {
    let snapshotter = AudioEnvironmentSnapshotter(
      collector: UnavailableCollector(),
      routeProvider: { "built_in_mic" },
      now: { Date(timeIntervalSince1970: 100) }
    )

    snapshotter.recordingStarted()
    let context = try await latestContext(from: snapshotter)

    #expect(context["snapshot_status"] as? String == "unavailable")
    #expect(context["unavailable_reason"] as? String == "process_object_list_unavailable")
    #expect(context["route"] as? String == "built_in_mic")
  }

  @Test("older refresh completion cannot replace newer snapshot")
  func olderRefreshCompletionCannotReplaceNewerSnapshot() async throws {
    let snapshotter = AudioEnvironmentSnapshotter(
      collector: OutOfOrderCollector(),
      routeProvider: { "built_in_mic" },
      now: { Date(timeIntervalSince1970: 100) }
    )

    snapshotter.recordingStarted()
    snapshotter.applicationBecameActive()
    let context = try await latestContext(from: snapshotter)

    #expect(context["snapshot_reason"] as? String == "app_active")
    let inputCategories = context["input_app_category_counts"] as? [String: Int]
    #expect(inputCategories?["media"] == 1)

    try await Task.sleep(nanoseconds: 250_000_000)
    let laterContext = try #require(snapshotter.latestForError())
    #expect(laterContext["snapshot_reason"] as? String == "app_active")
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
