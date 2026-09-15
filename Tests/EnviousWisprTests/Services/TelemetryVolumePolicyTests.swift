import Foundation
import Testing

@testable import EnviousWisprServices

/// #2958: the one boundary that decides whether a PostHog row leaves the Mac.
///
/// Fixtures name their bucket as a LITERAL computed by an independent oracle (Python:
/// `int.from_bytes(sha256(uuid.upper()).digest()[:4], 'big') % 100`), so the bucket test
/// cannot pass by agreeing with the code under test.
@Suite("TelemetryVolumePolicy (#2958)", .tags(.observabilityContract))
struct TelemetryVolumePolicyTests {

  /// Bucket 6: inside the 10% kept band.
  private static let keptUUID = UUID(uuidString: "65C82E99-657B-2334-831D-0F310DA1A14B")!
  /// Bucket 69: outside it.
  private static let droppedUUID = UUID(uuidString: "717C5468-9069-4DE5-3D25-BDA064959C35")!
  /// Bucket 10: the FIRST excluded bucket, so `<` becoming `<=` shows.
  private static let edgeUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
  /// Bucket 9: the LAST kept bucket, so `<` becoming `<` of a smaller threshold shows.
  private static let lastKeptUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000039")!

  private typealias Policy = TelemetryVolumePolicy

  @Test("buckets match the independent oracle")
  func bucketsMatchOracle() {
    #expect(Policy.bucket(for: Self.keptUUID) == 6)
    #expect(Policy.bucket(for: Self.droppedUUID) == 69)
    #expect(Policy.bucket(for: Self.edgeUUID) == 10)
    #expect(Policy.bucket(for: Self.lastKeptUUID) == 9)
    #expect(Policy.bucket(for: UUID(uuidString: "9EB03C05-23F6-784C-01CF-13C075DE87E3")!) == 1)
  }

  @Test("the bucket is a property of the UUID, not of the process or the case of its spelling")
  func bucketIsDeterministic() {
    let lower = UUID(uuidString: "65c82e99-657b-2334-831d-0f310da1a14b")!
    #expect(Policy.bucket(for: lower) == Policy.bucket(for: Self.keptUUID))
  }

  @Test("roughly one in ten random events lands in the kept band")
  func keptBandIsAboutTenPercent() {
    let kept = (0..<10_000).filter { _ in
      Policy.bucket(for: UUID()) < Policy.sampleThresholdPercent
    }.count
    #expect((800...1_200).contains(kept), "kept \(kept) of 10,000")
  }

  // MARK: - Drops

  @Test("Application Backgrounded never leaves")
  func backgroundedDrops() {
    #expect(
      Policy.decide(event: "Application Backgrounded", properties: [:], uuid: Self.keptUUID)
        == .drop)
  }

  @Test("Application Opened keeps the process start and drops the foreground return")
  func openedKeepsProcessStartOnly() {
    #expect(
      Policy.decide(
        event: "Application Opened", properties: ["from_background": false],
        uuid: Self.droppedUUID) == .keep)
    #expect(
      Policy.decide(
        event: "Application Opened", properties: ["from_background": true],
        uuid: Self.keptUUID) == .drop)
    // A missing or oddly-typed flag is kept: an unexpected shape must never read as "return".
    #expect(
      Policy.decide(event: "Application Opened", properties: [:], uuid: Self.keptUUID) == .keep)
    #expect(
      Policy.decide(
        event: "Application Opened", properties: ["from_background": "true"],
        uuid: Self.keptUUID) == .keep)
  }

  @Test("Application Installed and Application Updated are untouched")
  func installedAndUpdatedKeep() {
    for name in ["Application Installed", "Application Updated"] {
      #expect(Policy.decide(event: name, properties: [:], uuid: Self.droppedUUID) == .keep)
    }
  }

  // MARK: - Sampled happy paths

  private static let sampled = Policy.Decision.keepSampled(thresholdPercent: 10)

  @Test("hotkey start and toggle presses are sampled; every other action is kept whole")
  func hotkeyPresses() {
    for action in ["start", "toggle"] {
      #expect(
        Policy.decide(
          event: "hotkey.pressed", properties: ["press_action": action], uuid: Self.keptUUID)
          == Self.sampled)
      #expect(
        Policy.decide(
          event: "hotkey.pressed", properties: ["press_action": action], uuid: Self.droppedUUID)
          == .drop)
      #expect(
        Policy.decide(
          event: "hotkey.pressed", properties: ["press_action": action], uuid: Self.edgeUUID)
          == .drop, "bucket 10 is the first excluded bucket")
      #expect(
        Policy.decide(
          event: "hotkey.pressed", properties: ["press_action": action], uuid: Self.lastKeptUUID)
          == Self.sampled, "bucket 9 is the last kept bucket")
    }
    for action in ["lock", "stop", "cancel", "ignored_processing", "quick_add", "unheard_of"] {
      #expect(
        Policy.decide(
          event: "hotkey.pressed", properties: ["press_action": action], uuid: Self.droppedUUID)
          == .keep, Comment(rawValue: action))
    }
    #expect(
      Policy.decide(event: "hotkey.pressed", properties: [:], uuid: Self.droppedUUID) == .keep)
  }

  @Test("an all-succeeded cold prepare is sampled; any failed outcome is kept whole")
  func inputResolution() {
    let happy: [String: Any] = [
      "prepare_outcome": "succeeded", "bind_outcome": "succeeded",
      "enumeration_outcome": "not_attempted",
    ]
    #expect(
      Policy.decide(event: "audio.input_resolution", properties: happy, uuid: Self.keptUUID)
        == Self.sampled)
    #expect(
      Policy.decide(event: "audio.input_resolution", properties: happy, uuid: Self.droppedUUID)
        == .drop)
    var enumerated = happy
    enumerated["enumeration_outcome"] = "succeeded"
    #expect(
      Policy.decide(event: "audio.input_resolution", properties: enumerated, uuid: Self.droppedUUID)
        == .drop)
    for key in ["prepare_outcome", "bind_outcome", "enumeration_outcome"] {
      var failed = happy
      failed[key] = "failed"
      #expect(
        Policy.decide(event: "audio.input_resolution", properties: failed, uuid: Self.droppedUUID)
          == .keep, Comment(rawValue: key))
    }
    var missing = happy
    missing["bind_outcome"] = nil
    #expect(
      Policy.decide(event: "audio.input_resolution", properties: missing, uuid: Self.droppedUUID)
        == .keep)
  }

  @Test("live preview: started is sampled, every other outcome is kept whole")
  func livePreview() {
    #expect(
      Policy.decide(
        event: "live_preview.outcome", properties: ["engine": "apple", "outcome": "started"],
        uuid: Self.droppedUUID) == .drop)
    for outcome in ["open_failed", "prepare_failed", "blocked"] {
      #expect(
        Policy.decide(
          event: "live_preview.outcome", properties: ["engine": "apple", "outcome": outcome],
          uuid: Self.droppedUUID) == .keep, Comment(rawValue: outcome))
    }
  }

  @Test(
    "copies observed: no_before_image is sampled, every measured or refused status is kept whole")
  func copiesObserved() {
    #expect(
      Policy.decide(
        event: "paste.copies_observed", properties: ["status": "no_before_image"],
        uuid: Self.droppedUUID) == .drop)
    for status in [
      "measured", "unclassified", "element_unreadable", "probe_busy", "process_disabled",
    ] {
      #expect(
        Policy.decide(
          event: "paste.copies_observed", properties: ["status": status], uuid: Self.droppedUUID)
          == .keep, Comment(rawValue: status))
    }
  }

  @Test(
    "proactive update check: fired is kept whole, known non-fired reasons are sampled, unknown reasons kept whole"
  )
  func proactiveCheck() {
    #expect(
      Policy.decide(
        event: "update.proactive_check_triggered",
        properties: ["trigger": "wake", "fired": true, "reason": "fired"],
        uuid: Self.droppedUUID) == .keep)
    for reason in ["cooldown", "session_in_progress", "auto_checks_off", "no_updater"] {
      #expect(
        Policy.decide(
          event: "update.proactive_check_triggered",
          properties: ["trigger": "wake", "fired": false, "reason": reason],
          uuid: Self.droppedUUID) == .drop, Comment(rawValue: reason))
      #expect(
        Policy.decide(
          event: "update.proactive_check_triggered",
          properties: ["trigger": "wake", "fired": false, "reason": reason],
          uuid: Self.keptUUID) == Self.sampled, Comment(rawValue: reason))
    }
    #expect(
      Policy.decide(
        event: "update.proactive_check_triggered",
        properties: ["trigger": "wake", "fired": false, "reason": "new_vocabulary"],
        uuid: Self.droppedUUID) == .keep)
    // `fired` as a string is an unexpected shape and is kept.
    #expect(
      Policy.decide(
        event: "update.proactive_check_triggered",
        properties: ["trigger": "wake", "fired": "false", "reason": "cooldown"],
        uuid: Self.droppedUUID) == .keep)
  }

  @Test("the counting backbone and every unknown event are kept whole")
  func backboneAndUnknownKeep() {
    for name in [
      "dictation.started", "dictation.terminal", "dictation.completed", "dictation.invoked",
      "asr.completed", "paste.completed", "llm.polish_completed", "llm.polish_skipped",
      "llm.polish_failed", "settings.snapshot", "app.launched", "onboarding.completed",
      "some.future_event",
    ] {
      #expect(
        Policy.decide(event: name, properties: ["take_id": "x"], uuid: Self.droppedUUID) == .keep,
        Comment(rawValue: name))
    }
  }

  // MARK: - Stamps

  @Test("a kept row carries the policy version and nothing else new")
  func keptRowStamp() throws {
    let out = try #require(
      Policy.apply(
        event: "dictation.started", properties: ["take_id": "T", "backend": "parakeet"],
        uuid: Self.droppedUUID))
    #expect(out["telemetry_policy_version"] as? Int == 1)
    #expect(out["take_id"] as? String == "T")
    #expect(out["$sample_threshold"] == nil)
    #expect(out.count == 3)
  }

  @Test("a kept sampled row carries PostHog's sampling vocabulary")
  func sampledRowStamp() throws {
    let out = try #require(
      Policy.apply(
        event: "hotkey.pressed", properties: ["press_action": "start"], uuid: Self.keptUUID))
    #expect(out["telemetry_policy_version"] as? Int == 1)
    #expect(out["$sample_type"] as? [String] == ["sampleByEvent"])
    // A FRACTION, as posthog-js stores it: a percentage here would make the standard
    // `1 / $sample_threshold` weight ten-fold wrong (cloud review on #2962).
    #expect(out["$sample_threshold"] as? Double == 0.1)
    #expect(out["$sampled_events"] as? [String] == ["hotkey.pressed"])
    #expect(out["press_action"] as? String == "start")
  }

  @Test("a dropped row returns nil")
  func droppedRowIsNil() {
    #expect(
      Policy.apply(
        event: "hotkey.pressed", properties: ["press_action": "start"], uuid: Self.droppedUUID)
        == nil)
    #expect(
      Policy.apply(event: "Application Backgrounded", properties: [:], uuid: Self.keptUUID) == nil)
  }

  // MARK: - The real boundary

  @Test("the beforeSend body drops, then stamps, then redacts, and keeps both join keys")
  func beforeSendBody() throws {
    #expect(
      ObservabilityBootstrap.processPostHogEvent(
        name: "Application Backgrounded", properties: [:], uuid: Self.keptUUID) == nil)
    let out = try #require(
      ObservabilityBootstrap.processPostHogEvent(
        name: "dictation.terminal",
        properties: [
          "take_id": "9F2C1D84-6B3A-4E07-9C51-0A7D2E6F1B33",
          "distinct_id": "019f93ff-404b-7638-99e6-62cfd4da84f8",
          "note": "someone@example.com",
        ],
        uuid: Self.droppedUUID))
    #expect(out["telemetry_policy_version"] as? Int == 1)
    // The two bundle stamps come from the CURRENT bundle, on every row, whether or not
    // `register()` has run: `Application Installed` rows carried no environment at all
    // before this (801 of 801 in the 30 days to 2026-09-15).
    #expect(out["environment"] as? String == ObservabilityBootstrap.currentEnvironment)
    #expect((out["app_version"] as? String)?.isEmpty == false)
    // #2982: the shared-project source tag, read AFTER the sanitizer so a redaction
    // heuristic that ate the literal would fail here, not in a dashboard.
    #expect(out["app"] as? String == "enviouswispr")
    #expect(out["take_id"] as? String == "9F2C1D84-6B3A-4E07-9C51-0A7D2E6F1B33")
    #expect(out["distinct_id"] as? String == "019f93ff-404b-7638-99e6-62cfd4da84f8")
    #expect(
      out["note"] as? String == "[REDACTED]", "the privacy sanitizer still runs after the policy")
    let sampled = try #require(
      ObservabilityBootstrap.processPostHogEvent(
        name: "hotkey.pressed", properties: ["press_action": "toggle"], uuid: Self.keptUUID))
    #expect(sampled["$sample_type"] as? [String] == ["sampleByEvent"], "stamps survive redaction")
  }

  @Test("a stale registered stamp is overwritten by the current bundle's value")
  func staleStampsAreOverwritten() throws {
    // Super properties persist on disk, so after an update the first rows would carry
    // the PREVIOUS launch's `app_version` until `register()` runs. The boundary wins.
    let out = try #require(
      ObservabilityBootstrap.processPostHogEvent(
        name: "Application Installed",
        properties: ["environment": "stale", "app_version": "0.0.0-stale", "app": "stale"],
        uuid: Self.droppedUUID))
    #expect(out["environment"] as? String == ObservabilityBootstrap.currentEnvironment)
    #expect(out["app_version"] as? String != "0.0.0-stale")
    #expect(out["app"] as? String == "enviouswispr")
  }
}
