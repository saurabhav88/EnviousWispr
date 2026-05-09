import Foundation
import Testing

@testable import EnviousWisprServices

@Suite("AudioEnvironmentSnapshot")
struct AudioEnvironmentSnapshotTests {
  @Test("renderer emits coarse app categories without identifiers")
  func rendererEmitsCoarseAppCategoriesWithoutIdentifiers() {
    let snapshot = AudioEnvironmentSnapshot(
      reason: .recordingStart,
      capturedAt: Date(timeIntervalSince1970: 100),
      inputProcessCount: 10,
      outputProcessCount: 12,
      inputBundleIDs: ["com.zoom.xos", "com.microsoft.teams", "com.private.HealthcareClient"],
      outputBundleIDs: ["com.spotify.client", "org.videolan.vlc", "com.zoom.xos"],
      frontmostAppBundleID: "com.google.Chrome",
      inputDeviceTransport: "built_in",
      outputDeviceTransport: "bluetooth",
      route: "built_in_mic",
      bluetoothOutputActive: true,
      deviceEventAt: Date(timeIntervalSince1970: 100.5)
    )

    let context = snapshot.sentryContext(now: Date(timeIntervalSince1970: 101))
    let inputCategories = context["input_app_category_counts"] as? [String: Int]
    let outputCategories = context["output_app_category_counts"] as? [String: Int]

    #expect(context["snapshot_status"] as? String == "fresh")
    #expect(context["snapshot_reason"] as? String == "recording_start")
    #expect(context["snapshot_age_ms"] as? Int == 1000)
    #expect(context["input_process_count"] as? Int == 10)
    #expect(context["output_process_count"] as? Int == 12)
    #expect(inputCategories?["meeting"] == 2)
    #expect(inputCategories?["unknown"] == 1)
    #expect(outputCategories?["media"] == 2)
    #expect(outputCategories?["meeting"] == 1)
    #expect(context["frontmost_app_category"] as? String == "browser")
    #expect(context["input_device_transport"] as? String == "built_in")
    #expect(context["output_device_transport"] as? String == "bluetooth")
    #expect(context["bluetooth_output_active"] as? Bool == true)
    #expect(context["device_event_recent_ms"] as? Int == 500)

    let rendered = String(describing: context)
    #expect(!rendered.contains("com.zoom.xos"))
    #expect(!rendered.contains("com.spotify.client"))
    #expect(!rendered.contains("com.microsoft.teams"))
    #expect(!rendered.contains("HealthcareClient"))
    #expect(!rendered.contains("AirPods-Pro"))
    #expect(context["input_bundle_id_hashes"] == nil)
    #expect(context["output_bundle_id_hashes"] == nil)
    #expect(context["frontmost_app_bundle_id_hash"] == nil)
    #expect(context["input_device_uid_default"] == nil)
    #expect(context["output_device_uid_default"] == nil)
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
      deviceEventAt: Date(timeIntervalSince1970: 99.5),
      unavailableReason: "process object list unavailable"
    )

    let context = snapshot.sentryContext(now: Date(timeIntervalSince1970: 100))

    #expect(context["snapshot_status"] as? String == "unavailable")
    #expect(context["snapshot_reason"] as? String == "audio_device_event")
    #expect(context["device_event_recent_ms"] as? Int == 500)
    #expect(context["unavailable_reason"] as? String == "process_object_list_unavailable")
    #expect(context["route"] as? String == "built_in_mic")
    #expect(!String(describing: context).contains("HealthcareClient"))
  }
}
