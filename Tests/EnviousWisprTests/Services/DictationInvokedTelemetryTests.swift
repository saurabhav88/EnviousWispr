import EnviousWisprServices
import Testing

#if DEBUG

  @Suite("Dictation invoked telemetry")
  struct DictationInvokedTelemetryTests {

    @MainActor
    final class EventBox {
      var value: CapturedTelemetryEvent?
    }

    @MainActor
    @Test("dictationInvoked exposes exact event payload through DEBUG hook")
    func dictationInvokedPayloadIsObservable() async {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in
          if event.name == "dictation.invoked" { box.value = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.dictationInvoked(
        triggerSource: "pushToTalk",
        inputMode: "pushToTalk",
        targetApp: "Terminal"
      )

      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)

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
