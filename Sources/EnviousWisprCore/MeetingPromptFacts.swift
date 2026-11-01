import Foundation

/// What a meeting's summary is told about the meeting besides its words (#4286): when it started
/// and how long was recorded (from the app's own record), the call app, and the matched calendar
/// event's title and invited people (from the saved facts). Never the transcript language, a
/// wall-clock length, an AI title or a speaker's identity.
public struct MeetingPromptFacts: Sendable, Equatable {
  public var startedAt: Date
  public var recordedDurationMs: Int
  public var callAppName: String?
  public var calendarTitle: String?
  public var participants: [MeetingParticipant]

  public init(
    startedAt: Date, recordedDurationMs: Int, callAppName: String?, calendarTitle: String?,
    participants: [MeetingParticipant]
  ) {
    self.startedAt = startedAt
    self.recordedDurationMs = recordedDurationMs
    self.callAppName = callAppName
    self.calendarTitle = calendarTitle
    self.participants = participants
  }

  /// The facts of a meeting from its record's values and its saved context. The calendar title
  /// is the first saved calendar event's; the participants come from the saved attendees.
  public init(
    startedAt: Date, recordedDurationMs: Int, callApp: CallAppFamily?, context: MeetingContext?
  ) {
    self.init(
      startedAt: startedAt, recordedDurationMs: recordedDurationMs,
      callAppName: callApp?.displayName, calendarTitle: context?.calendarEvents.first?.title,
      participants: MeetingParticipants.resolve(attendees: context?.attendees ?? []))
  }
}
