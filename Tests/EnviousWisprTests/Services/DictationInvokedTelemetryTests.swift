import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  @Suite("Dictation invoked telemetry", .serialized)
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
        triggerSource: "ptt_hotkey",
        inputMode: "pushToTalk",
        targetApp: "Terminal"
      )

      guard let event = box.value else {
        Issue.record("Expected dictation.invoked event")
        return
      }
      #expect(event.name == "dictation.invoked")
      // #723: trigger_source and input_mode are distinct fields now.
      // trigger_source = invocation surface; input_mode = configured recording mode.
      #expect(event.stringProps["trigger_source"] == "ptt_hotkey")
      #expect(event.stringProps["input_mode"] == "pushToTalk")
      #expect(event.stringProps["target_app"] == "Terminal")
    }

    @MainActor
    @Test(
      "trigger_source and input_mode are independent — toolbar invocation on toggle-configured user (#723)"
    )
    func triggerSourceIndependentFromInputMode() {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "dictation.invoked" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      // A user configured for `toggle` clicks the toolbar Record button:
      // trigger_source should reflect "toolbar", NOT "toggle".
      TelemetryService.shared.dictationInvoked(
        triggerSource: "toolbar",
        inputMode: "toggle",
        targetApp: "Safari"
      )

      guard let event = box.value else {
        Issue.record("Expected dictation.invoked event")
        return
      }
      #expect(event.stringProps["trigger_source"] == "toolbar")
      #expect(event.stringProps["input_mode"] == "toggle")
      #expect(event.stringProps["trigger_source"] != event.stringProps["input_mode"])
    }
  }

#endif
