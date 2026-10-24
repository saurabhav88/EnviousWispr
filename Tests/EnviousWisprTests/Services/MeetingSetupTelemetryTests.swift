import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

#if DEBUG
  /// The `meeting.setup` row's shape (#4017 R8). When this fails, the founder's setup funnel
  /// reads a property that is missing or typed wrong, or the row carries something beyond its
  /// closed enums and duration (never calendar or event content).
  @MainActor
  @Suite(
    "meeting.setup: approved typed fields, nothing else (#4017)", .serialized,
    .tags(.observabilityContract))
  struct MeetingSetupTelemetryTests {
    final class Box: @unchecked Sendable {
      // Test-only capture box; the hook is called synchronously inside the emit on this actor.
      var events: [CapturedTelemetryEvent] = []
    }

    @Test("the row carries exactly the approved keys, enums as strings and seconds as a number")
    func shape() throws {
      let box = Box()
      let service = TelemetryService.shared
      let previous = service.testEventHook
      service.testEventHook = { captured in
        if captured.name == "meeting.setup" { box.events.append(captured) }
      }
      defer { service.testEventHook = previous }
      service.trackMeetingSetup(
        MeetingSetupTelemetry(
          outcome: .finished, screen: .done, seconds: 37.5, microphone: .granted,
          callSound: .requestedUnknown, calendar: .skipped))
      let row = try #require(box.events.first)
      #expect(box.events.count == 1)
      #expect(
        Set(row.stringProps.keys).union(row.doubleProps.keys)
          == ["outcome", "screen", "seconds", "microphone", "call_sound", "calendar"])
      #expect(row.stringProps["outcome"] == "finished")
      #expect(row.stringProps["call_sound"] == "requested_unknown")
      #expect(row.doubleProps["seconds"] == 37.5)
    }
  }
#endif
