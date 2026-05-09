import Foundation
import Testing

@testable import EnviousWisprServices

@Suite("AudioEnvironmentSnapshot")
struct AudioEnvironmentSnapshotTests {
  @Test("renderer hashes bundle IDs and caps lists")
  func rendererHashesAndCapsBundleIDs() {
    let snapshot = AudioEnvironmentSnapshot(
      reason: .recordingStart,
      capturedAt: Date(timeIntervalSince1970: 100),
      inputProcessCount: 10,
      outputProcessCount: 12,
      inputBundleIDs: (0..<12).map { "com.example.input\($0)" },
      outputBundleIDs: ["com.zoom.xos", "com.spotify.client", "com.zoom.xos"],
      frontmostAppBundleID: "com.apple.TextEdit",
      inputDeviceUIDDefault: "BuiltInMicrophoneDevice",
      outputDeviceUIDDefault: "AirPods-Pro",
      route: "built_in_mic",
      bluetoothOutputActive: true
    )

    let context = snapshot.sentryContext(now: Date(timeIntervalSince1970: 101))

    #expect(context["snapshot_status"] as? String == "fresh")
    #expect(context["snapshot_reason"] as? String == "recording_start")
    #expect(context["snapshot_age_ms"] as? Int == 1000)
    #expect(context["input_process_count"] as? Int == 10)
    #expect(context["output_process_count"] as? Int == 12)
    #expect((context["input_bundle_id_hashes"] as? [String])?.count == 8)
    #expect((context["output_bundle_id_hashes"] as? [String])?.count == 2)
    #expect(context["frontmost_app_bundle_id_hash"] is String)
    #expect(context["bluetooth_output_active"] as? Bool == true)

    let rendered = String(describing: context)
    #expect(!rendered.contains("com.zoom.xos"))
    #expect(!rendered.contains("com.spotify.client"))
    #expect(!rendered.contains("com.apple.TextEdit"))
  }

  @Test("stale status is explicit when cached snapshot ages out")
  func staleStatus() {
    let snapshot = AudioEnvironmentSnapshot(
      reason: .appActive,
      capturedAt: Date(timeIntervalSince1970: 100)
    )

    let context = snapshot.sentryContext(now: Date(timeIntervalSince1970: 112))

    #expect(context["snapshot_status"] as? String == "stale")
    #expect(context["snapshot_age_ms"] as? Int == 12_000)
  }

  @Test("unavailable status keeps reason but no raw app identifiers")
  func unavailableStatus() {
    let snapshot = AudioEnvironmentSnapshot.unavailable(
      reason: .audioDeviceEvent,
      capturedAt: Date(timeIntervalSince1970: 100),
      route: "built in mic",
      frontmostAppBundleID: "com.private.HealthcareClient",
      deviceEventRecentMs: 42,
      unavailableReason: "process object list unavailable"
    )

    let context = snapshot.sentryContext(now: Date(timeIntervalSince1970: 100))

    #expect(context["snapshot_status"] as? String == "unavailable")
    #expect(context["snapshot_reason"] as? String == "audio_device_event")
    #expect(context["device_event_recent_ms"] as? Int == 42)
    #expect(context["unavailable_reason"] as? String == "process_object_list_unavailable")
    #expect(context["route"] as? String == "built_in_mic")
    #expect(!String(describing: context).contains("HealthcareClient"))
  }
}
