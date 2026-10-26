import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4105 (plan R1.3): when this fails, a live words download starts while a meeting records or
/// is being transcribed, or Download stays refused after the meeting ended.
@MainActor
@Suite("Meeting download admission (#4105)", .tags(.productOutcome))
struct MeetingDownloadAdmissionTests {
  @Test("a download may start only when no meeting is active, and the refusal says when it can")
  func admission() {
    #expect(MeetingDownloadAdmission.canStart(meetingActive: false))
    #expect(!MeetingDownloadAdmission.canStart(meetingActive: true))
    #expect(MeetingDownloadAdmission.refusal == "Available after the meeting.")
  }
}
