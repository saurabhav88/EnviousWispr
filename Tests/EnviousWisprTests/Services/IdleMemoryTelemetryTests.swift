import Foundation
import Testing

@testable import EnviousWisprServices

#if DEBUG
  /// The `app.idle_memory` row's shape (#3289 §8b). When this fails, the idle-memory chart reads a
  /// property that is missing or typed as a string, or the row carries something beyond four
  /// numbers and flags.
  @MainActor
  @Suite(
    "app.idle_memory: four typed fields, nothing else (#3289)", .serialized,
    .tags(.observabilityContract))
  struct IdleMemoryTelemetryTests {
    final class Box: @unchecked Sendable {
      // Test-only capture box; the hook is called synchronously inside the emit on this actor.
      var events: [CapturedTelemetryEvent] = []
    }

    @Test("the row carries footprint and minutes as Int and the two word-check flags as Bool")
    func payload() {
      let box = Box()
      let service = TelemetryService.shared
      let previous = service.testEventHook
      service.testEventHook = { event in
        if event.name == "app.idle_memory" { box.events.append(event) }
      }
      defer { service.testEventHook = previous }
      service.appIdleMemory(
        footprintMB: 471, minutesSinceLaunch: 12, wordCheckLoaded: false, wordCheckWanted: true)
      #expect(box.events.count == 1)
      let event = box.events.first
      #expect(event?.intProps == ["footprint_mb": 471, "minutes_since_launch": 12])
      #expect(event?.boolProps == ["word_check_loaded": false, "word_check_wanted": true])
      #expect(event?.stringProps.isEmpty == true)
      #expect(event?.doubleProps.isEmpty == true)
    }
  }
#endif
