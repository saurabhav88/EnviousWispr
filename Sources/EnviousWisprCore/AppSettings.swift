import Foundation

/// Recording mode for dictation.
public enum RecordingMode: String, Codable, CaseIterable, Sendable {
  case pushToTalk
  case toggle

  public var shortLabel: String {
    switch self {
    case .pushToTalk: return "PTT"
    case .toggle: return "Toggle"
    }
  }
}

/// Pipeline processing state.
public enum PipelineState: Equatable, Sendable {
  case idle
  case loadingModel
  case recording
  case transcribing
  case polishing
  case complete
  case error(TerminalNoticeReason)
  /// #1891: a terminal the user can act on that is NOT our failure — the
  /// microphone delivered nothing usable. Separate from `.error` because
  /// `.error` drags a Try Again button, a red menu-bar state, a red sidebar
  /// dot and a VoiceOver "Error: " prefix, all of which contradict the fact.
  case advisory(TerminalAdvisoryReason)

  public var isActive: Bool {
    switch self {
    case .loadingModel, .recording, .transcribing, .polishing:
      return true
    default:
      return false
    }
  }

  /// Stable lowercase phase label for telemetry (e.g. the `app_phase` property
  /// on `telemetry.flush_requested`, Telemetry Bible Phase 1 / #1170). Total
  /// switch (no `default`) so a new `PipelineState` case forces a compile-time
  /// decision here rather than silently mapping to a stale label.
  public var telemetryLabel: String {
    switch self {
    case .idle: return "idle"
    case .loadingModel: return "loading_model"
    case .recording: return "recording"
    case .transcribing: return "transcribing"
    case .polishing: return "polishing"
    case .complete: return "complete"
    case .error: return "error"
    // #1891: DELIBERATELY "error", not a new label. This feeds `app_phase` on
    // `telemetry.flush_requested`; a new value would change that series'
    // vocabulary at a version boundary, which is the exact trap #1813 hit
    // (analytics-operations.md RULE: enum-backed-properties-carry-retired-
    // vocabularies-split-by-version). The customer-facing split is a
    // presentation decision and does not belong in a telemetry phase label.
    case .advisory: return "error"
    }
  }

}

/// Policy controlling when idle ASR models are unloaded from memory.
public enum ModelUnloadPolicy: String, Codable, CaseIterable, Sendable {
  case never
  case immediately
  case twoMinutes
  case fiveMinutes
  case tenMinutes
  case fifteenMinutes
  case sixtyMinutes

  public var displayName: String {
    switch self {
    case .never: return "Never"
    case .immediately: return "Immediately"
    case .twoMinutes: return "After 2 minutes"
    case .fiveMinutes: return "After 5 minutes"
    case .tenMinutes: return "After 10 minutes"
    case .fifteenMinutes: return "After 15 minutes"
    case .sixtyMinutes: return "After 1 hour"
    }
  }

  /// Returns nil for .never and .immediately (timer-less policies).
  public var interval: TimeInterval? {
    switch self {
    case .never, .immediately: return nil
    case .twoMinutes: return 120
    case .fiveMinutes: return 300
    case .tenMinutes: return 600
    case .fifteenMinutes: return 900
    case .sixtyMinutes: return 3600
    }
  }
}
