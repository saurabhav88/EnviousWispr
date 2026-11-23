import Foundation

/// One `guided_tour` row (#4565): what happened in the guided tour and at which stop. Shape
/// only: two closed vocabularies, never a count of the user's own data, a page's contents or a
/// name of anything the user made.
public struct GuidedTourTelemetry: Sendable, Equatable {
  public enum Action: String, Sendable, CaseIterable {
    /// The automatic offer card first appeared.
    case offered
    /// Start was accepted on the offer (stop: the first stop, as requested).
    case started
    /// A stop's page and tab were showing and its card was reachable, once per stop per run.
    case stopViewed = "stop_viewed"
    /// The run ended before its last stop: End tour, Not now, window close or Quit.
    case endedEarly = "ended_early"
    /// Finish tour was pressed after arrival at the last stop.
    case completed
    /// A replay from a menu began (stop: the first stop).
    case replayed
  }

  public enum Stop: String, Sendable, CaseIterable {
    case offer
    case keybinds
    case history
    case dictation
    case aiPolish = "ai_polish"
    case dictionary
    case snippets
    case transcribeFile = "transcribe_file"
    case meetings
    case recordings
  }

  public let action: Action
  public let stop: Stop

  public init(action: Action, stop: Stop) {
    self.action = action
    self.stop = stop
  }
}
