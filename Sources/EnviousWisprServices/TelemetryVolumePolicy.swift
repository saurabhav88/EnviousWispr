import CryptoKit
import Foundation

/// #2958. The ONE place that decides whether a PostHog row leaves the Mac, and how it
/// is labelled when it does. Run from the PostHog SDK's `beforeSend` (see
/// `ObservabilityBootstrap.processPostHogEvent`), BEFORE the privacy sanitizer, so every
/// row, including the SDK's own lifecycle events, passes through it exactly once.
///
/// Why one boundary and not per-emitter guards: 112 emitters share one wire, and the
/// question "does this row leave" must have one reader. An emitter keeps describing what
/// happened; this type keeps deciding what is worth a billed row.
///
/// The policy is PURE: no SDK calls, no clock, no random source, no shared state. A sampled
/// row is kept or dropped by hashing the event's own UUID, so the decision is reproducible
/// from the payload alone and a test can name the bucket a fixture lands in.
///
/// Sentry is untouched by construction: this type never sees a Sentry event, and the
/// breadcrumb twins of every folded or sampled row still travel with any Sentry error.
///
/// Reading sampled data: a kept sampled row carries PostHog's own sampling vocabulary
/// (`$sample_type`, `$sample_threshold`, `$sampled_events`, the names posthog-js stamps
/// from `sampleByEvent`). `$sample_threshold` is the RETAINED FRACTION (0.1 for one in
/// ten), exactly as posthog-js stores it, so an estimated total is
/// `sum(1 / $sample_threshold)` with unsampled rows weighted one. Owner of the reading rules:
/// `.claude/knowledge/analytics-operations.md` RULE: weight-sampled-rows-by-their-threshold.
public enum TelemetryVolumePolicy {

  /// Bumped whenever a rule below changes what leaves the Mac. Stamped on EVERY kept row so
  /// a query can floor by policy rather than by app version.
  public static let policyVersion = 1
  public static let policyVersionKey = "telemetry_policy_version"

  /// Percent of matching happy-path rows that are KEPT. One rate on purpose: a table of
  /// rates is a table nobody re-reads.
  public static let sampleThresholdPercent = 10

  public enum Decision: Equatable, Sendable {
    /// Leaves as-is (plus the policy stamp).
    case keep
    /// Leaves with the sampling stamps; the row won its bucket.
    case keepSampled(thresholdPercent: Int)
    /// Never leaves the Mac. Not billed, not queryable.
    case drop
  }

  /// The closed set of `update.proactive_check_triggered.reason` values that mean "did not
  /// fire". A reason outside this set is kept at 100%: an unknown vocabulary is exactly the
  /// row a reader wants to see in full.
  static let knownNonFiredProactiveReasons: Set<String> = [
    "cooldown", "auto_checks_off", "no_updater", "session_in_progress",
  ]

  /// The common `hotkey.pressed` actions: `start` for push-to-talk and `toggle`, which
  /// covers BOTH edges of a toggle, so these presses are not one-to-one with accepted
  /// recordings. Every other action (lock, stop, cancel, ignored_processing, quick_add)
  /// is the signal and stays whole.
  static let happyPathPressActions: Set<String> = ["start", "toggle"]

  // MARK: - Decision

  public static func decide(event: String, properties: [String: Any], uuid: UUID) -> Decision {
    if let sampled = sampledDecision(event: event, properties: properties) {
      return sampled(uuid)
    }
    switch event {
    case "Application Backgrounded":
      // SDK lifecycle noise with no consumer: 14k rows/month measured 2026-09-15.
      return .drop
    case "Application Opened":
      // A foreground return (alt-tab back in) is not a launch. The process-start marker
      // is `from_background = false` and is kept; a missing or non-Bool value is kept
      // too, because an unexpected shape must never be read as "return".
      if properties["from_background"] as? Bool == true { return .drop }
      return .keep
    default:
      return .keep
    }
  }

  /// Applies `decide` and returns the properties to send, or nil when the row is dropped.
  public static func apply(event: String, properties: [String: Any], uuid: UUID) -> [String: Any]? {
    switch decide(event: event, properties: properties, uuid: uuid) {
    case .drop:
      return nil
    case .keep:
      var out = properties
      out[policyVersionKey] = policyVersion
      return out
    case .keepSampled(let threshold):
      var out = properties
      out[policyVersionKey] = policyVersion
      out["$sample_type"] = ["sampleByEvent"]
      // posthog-js stores the retained FRACTION (its `percent` parameter is 0...1), so
      // the standard `1 / $sample_threshold` weight works unchanged on our rows.
      out["$sample_threshold"] = Double(threshold) / 100.0
      out["$sampled_events"] = [event]
      return out
    }
  }

  // MARK: - Sampling rules

  /// Returns the sampling closure when the row is a happy-path row of a sampled event, or
  /// nil when the row is not subject to sampling at all. The predicates are deliberately
  /// EXACT: a property with an unexpected value falls through to `.keep`.
  private static func sampledDecision(
    event: String, properties: [String: Any]
  ) -> ((UUID) -> Decision)? {
    let isHappyPath: Bool
    switch event {
    case "hotkey.pressed":
      guard let action = properties["press_action"] as? String else { return nil }
      isHappyPath = happyPathPressActions.contains(action)
    case "audio.input_resolution":
      // The cold-prepare diagnostic. 99.75% of rows are all-succeeded (measured
      // 2026-09-15); a failure on any of the three outcomes is kept in full.
      guard
        let prepare = properties["prepare_outcome"] as? String,
        let bind = properties["bind_outcome"] as? String,
        let enumeration = properties["enumeration_outcome"] as? String
      else { return nil }
      isHappyPath =
        prepare == "succeeded" && bind == "succeeded"
        && (enumeration == "succeeded" || enumeration == "not_attempted")
    case "live_preview.outcome":
      guard let outcome = properties["outcome"] as? String else { return nil }
      isHappyPath = outcome == "started"
    case "paste.copies_observed":
      // `no_before_image` means the probe was never eligible; it is 55% of rows and
      // carries no measurement. Every measured or refused status stays at 100%.
      guard let status = properties["status"] as? String else { return nil }
      isHappyPath = status == "no_before_image"
    case "update.proactive_check_triggered":
      // "SAMPLE and record the rate, never suppress" (analytics-operations.md). Fired
      // checks stay at 100%; the non-fired reasons are sampled with the rate stamped.
      guard
        let fired = properties["fired"] as? Bool,
        let reason = properties["reason"] as? String
      else { return nil }
      isHappyPath = fired == false && knownNonFiredProactiveReasons.contains(reason)
    default:
      return nil
    }
    guard isHappyPath else { return nil }
    return { uuid in
      bucket(for: uuid) < sampleThresholdPercent
        ? .keepSampled(thresholdPercent: sampleThresholdPercent)
        : .drop
    }
  }

  // MARK: - Bucketing

  /// 0...99, derived from SHA-256 of the canonical uppercase UUID string, big-endian
  /// first four bytes modulo 100. Never Swift's `Hasher`, which is seeded per process.
  static func bucket(for uuid: UUID) -> Int {
    let digest = SHA256.hash(data: Data(uuid.uuidString.utf8))
    var word: UInt32 = 0
    for byte in digest.prefix(4) {
      word = (word << 8) | UInt32(byte)
    }
    return Int(word % 100)
  }
}
