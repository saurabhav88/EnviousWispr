import Foundation

/// One `meeting.setup` row: how a visit to EnviousMeet's setup ended (#4017 R8). Shape only:
/// closed enums and a duration, never calendar titles, events or any content.
public struct MeetingSetupTelemetry: Sendable, Equatable {
  public enum Outcome: String, Sendable, CaseIterable {
    /// The user pressed "Open EnviousMeet": setup is finished.
    case finished
    /// The page went away (another page, or the window closed) before setup finished.
    case left
  }

  /// The furthest screen of the visit at its terminal.
  public enum Screen: String, Sendable, CaseIterable {
    case welcome, legal, permissions, done
  }

  /// One permission's answer at the terminal.
  public enum Answer: String, Sendable, CaseIterable {
    case granted
    /// macOS was asked, and its answer cannot be read (call sound without a readable status).
    case requestedUnknown = "requested_unknown"
    case denied
    case skipped
    case unknown
  }

  public let outcome: Outcome
  public let screen: Screen
  /// Visit start to terminal, including time waiting on macOS prompts.
  public let seconds: Double
  public let microphone: Answer
  public let callSound: Answer
  public let calendar: Answer

  public init(
    outcome: Outcome, screen: Screen, seconds: Double, microphone: Answer, callSound: Answer,
    calendar: Answer
  ) {
    self.outcome = outcome
    self.screen = screen
    self.seconds = seconds
    self.microphone = microphone
    self.callSound = callSound
    self.calendar = calendar
  }
}
