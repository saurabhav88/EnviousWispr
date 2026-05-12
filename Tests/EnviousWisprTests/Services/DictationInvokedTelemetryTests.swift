import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  @Suite("Dictation invoked telemetry")
  struct DictationInvokedTelemetryTests {

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: CapturedTelemetryEvent?

      func set(_ event: CapturedTelemetryEvent) {
        lock.withLock { stored = event }
      }

      var value: CapturedTelemetryEvent? {
        lock.withLock { stored }
      }
    }

    @MainActor
    @Test("dictationInvoked exposes exact event payload through DEBUG hook")
    func dictationInvokedPayloadIsObservable() {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "dictation.invoked" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.dictationInvoked(
        triggerSource: "pushToTalk",
        inputMode: "pushToTalk",
        targetApp: "Terminal"
      )

      guard let event = box.value else {
        Issue.record("Expected dictation.invoked event")
        return
      }
      #expect(event.name == "dictation.invoked")
      #expect(event.stringProps["trigger_source"] == "pushToTalk")
      #expect(event.stringProps["input_mode"] == "pushToTalk")
      #expect(event.stringProps["target_app"] == "Terminal")
    }
  }

#endif
