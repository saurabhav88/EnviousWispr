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

    // MARK: - #1846 take key on the wire

    /// The property name is the joinable contract: PostHog `take_id` has to pair
    /// with the Sentry tag `dictation.take_id`. A rename on either side silently
    /// breaks every join, so the literal string is frozen here rather than left to
    /// the call site.
    @MainActor
    @Test("dictation.invoked puts the take key on the wire as take_id")
    func dictationInvokedEmitsTakeIDProperty() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "dictation.invoked" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.dictationInvoked(
        triggerSource: "ptt_hotkey", inputMode: "pushToTalk", targetApp: nil,
        takeID: "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33")

      let event = try #require(box.value)
      #expect(event.stringProps["take_id"] == "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33")
    }

    /// ABSENT, not empty. A query has to distinguish "this release predates the
    /// key" and "no take produced this event" from "a take whose id we lost", and an
    /// empty-string placeholder would collapse all three into one value that also
    /// counts as present.
    @MainActor
    @Test("dictation.invoked omits take_id entirely when there is no take")
    func dictationInvokedOmitsTakeIDWhenNil() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "dictation.invoked" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.dictationInvoked(
        triggerSource: "toolbar", inputMode: "toggle", targetApp: nil, takeID: nil)

      let event = try #require(box.value)
      #expect(
        event.stringProps["take_id"] == nil,
        "take_id must be absent, not empty — got \(String(describing: event.stringProps["take_id"]))"
      )
      // The rest of the event is unaffected, so the omission is not suppressing it.
      #expect(event.stringProps["trigger_source"] == "toolbar")
    }

    /// Same contract on the interruption counter.
    @MainActor
    @Test("audio.capture_interrupted carries take_id when present and omits it when nil")
    func audioCaptureInterruptedTakeIDContract() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "audio.capture_interrupted" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.audioCaptureInterrupted(
        cause: "engineLost", salvageAttempted: true, salvageSucceeded: true,
        terminalState: "completed", backend: "parakeet",
        takeID: "1e5b7a90-2c46-4d18-8f03-6b9e4a2c7d51")
      let presentEvent = try #require(box.value)
      #expect(
        presentEvent.stringProps["take_id"]
          == "1e5b7a90-2c46-4d18-8f03-6b9e4a2c7d51")

      TelemetryService.shared.audioCaptureInterrupted(
        cause: "engineLost", salvageAttempted: true, salvageSucceeded: true,
        terminalState: "completed", backend: "parakeet", takeID: nil)
      let absentEvent = try #require(box.value)
      #expect(absentEvent.stringProps["take_id"] == nil)
      // Still the interruption event, so the nil did not suppress the emission.
      #expect(absentEvent.stringProps["cause"] == "engineLost")
    }
  }

#endif
