import Foundation

/// One `meeting.call_prompt` row (#4012 c1 C3): how a noticed call was answered. Closed enums
/// only; never a window title, address, room or event.
public struct MeetingCallPromptTelemetry: Sendable, Equatable {
  public enum Answer: String, Sendable, CaseIterable {
    case yes, no, timeout
    case autoStarted = "auto_started"
    case switchYes = "switch_yes"
    case switchNo = "switch_no"
    /// Yes, but the Start needed the user first (a macOS prompt or the explainer).
    case needsAttention = "needs_attention"
  }

  public let family: CallAppFamily
  public let answer: Answer
  /// `CallDetectionPolicy.Mode` raw value at the time.
  public let mode: String

  public init(family: CallAppFamily, answer: Answer, mode: String) {
    self.family = family
    self.answer = answer
    self.mode = mode
  }
}
