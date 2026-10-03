import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

// #1714 locks the `audio.input_resolution` event shape and the
// `input_resolution_source` stamps on both terminal events.
//
// `route_resolution_source` answers how a transport label was derived.
// `input_resolution_source` answers why the input device was selected.
// `dictation.completed` can carry both, so its coexistence test freezes their
// distinct names and values.
//
// `testEventHook` + `CapturedTelemetryEvent` are DEBUG-only, so this suite is
// DEBUG-gated to compile under both flavors.
@Suite("input resolution telemetry — #1714")
@MainActor
struct InputResolutionTelemetryTests {
  #if DEBUG

    private final class Box: @unchecked Sendable {
      var event: CapturedTelemetryEvent?
    }

    private func capture(_ body: () -> Void) -> CapturedTelemetryEvent? {
      let box = Box()
      let previous = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = previous }
      body()
      return box.event
    }

    // MARK: - audio.input_resolution

    @Test("the ordinary system-default cold attempt emits a complete event")
    func systemDefaultAttemptEmits() {
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true,
          enumerationOutcome: "not_attempted",
          inputDeviceCount: nil,
          eligibleDeviceCount: nil,
          inputResolutionSource: "system_default",
          selectedTransport: nil,
          bindOutcome: "succeeded",
          prepareOutcome: "succeeded"
        )
      }

      #expect(event?.name == "audio.input_resolution")
      #expect(event?.boolProps["default_present"] == true)
      #expect(event?.stringProps["enumeration_outcome"] == "not_attempted")
      #expect(event?.stringProps["input_resolution_source"] == "system_default")
      #expect(event?.stringProps["bind_outcome"] == "succeeded")
      #expect(event?.stringProps["prepare_outcome"] == "succeeded")
    }

    // MARK: - #1851 the failing step and the Mac's status

    @Test(
      "a failed cold attempt emits the step, the signed status and its four-character form",
      .tags(.observabilityContract))
    func failedAttemptEmitsStepAndStatus() {
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true,
          enumerationOutcome: "succeeded",
          inputDeviceCount: 2,
          eligibleDeviceCount: 1,
          inputResolutionSource: "system_default",
          selectedTransport: "built_in",
          bindOutcome: "succeeded",
          prepareOutcome: "failed",
          prepareFailedStep: "HALDeviceInputSource.prepare.start",
          prepareFailedOSStatus: 1_937_010_544,
          prepareFailedOSStatusFourCC: "stop"
        )
      }

      #expect(event?.stringProps["prepare_outcome"] == "failed")
      #expect(event?.stringProps["prepare_failed_step"] == "HALDeviceInputSource.prepare.start")
      #expect(event?.intProps["prepare_failed_os_status"] == 1_937_010_544)
      #expect(event?.stringProps["prepare_failed_os_status_fourcc"] == "stop")
    }

    @Test(
      "a negative status stays negative and an absent step or status is omitted",
      .tags(.observabilityContract))
    func absentFailureFieldsAreOmitted() {
      let negative = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true, enumerationOutcome: "succeeded", inputDeviceCount: nil,
          eligibleDeviceCount: nil, inputResolutionSource: nil, selectedTransport: nil,
          bindOutcome: "succeeded", prepareOutcome: "failed",
          prepareFailedStep: "HALDeviceInputSource.prepare.initialize",
          prepareFailedOSStatus: -10868, prepareFailedOSStatusFourCC: nil)
      }
      #expect(negative?.intProps["prepare_failed_os_status"] == -10868)
      #expect(negative?.stringProps.keys.contains("prepare_failed_os_status_fourcc") == false)

      let none = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true, enumerationOutcome: "succeeded", inputDeviceCount: nil,
          eligibleDeviceCount: nil, inputResolutionSource: nil, selectedTransport: nil,
          bindOutcome: "succeeded", prepareOutcome: "succeeded")
      }
      #expect(none?.stringProps.keys.contains("prepare_failed_step") == false)
      #expect(none?.intProps.keys.contains("prepare_failed_os_status") == false)
      #expect(none?.stringProps.keys.contains("prepare_failed_os_status_fourcc") == false)
    }

    @Test(
      "the outgoing property list has exactly the expected keys and the hook preserves them",
      .tags(.observabilityContract))
    func outgoingKeysAreTheExpectedLiteralSet() {
      // The expected set is a literal written from the event's documented
      // properties, not read from the builder under test. This checks the
      // builder's keys and the DEBUG hook's conversion; it does not observe
      // the SDK's own delivery, which no seam exposes.
      let expectedKeys: Set<String> = [
        "default_present", "enumeration_outcome",
        "input_device_count", "eligible_device_count",
        "input_resolution_source", "selected_transport",
        "bind_outcome", "prepare_outcome",
        "prepare_failed_step", "prepare_failed_os_status",
        "prepare_failed_os_status_fourcc",
      ]
      let outgoing = TelemetryService.inputResolutionProperties(
        defaultPresent: true, enumerationOutcome: "succeeded", inputDeviceCount: 3,
        eligibleDeviceCount: 0, inputResolutionSource: "system_default",
        selectedTransport: "usb", bindOutcome: "succeeded", prepareOutcome: "failed",
        prepareFailedStep: "HALDeviceInputSource.prepare.start",
        prepareFailedOSStatus: 560_227_702, prepareFailedOSStatusFourCC: "!dev")
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true, enumerationOutcome: "succeeded", inputDeviceCount: 3,
          eligibleDeviceCount: 0, inputResolutionSource: "system_default",
          selectedTransport: "usb", bindOutcome: "succeeded", prepareOutcome: "failed",
          prepareFailedStep: "HALDeviceInputSource.prepare.start",
          prepareFailedOSStatus: 560_227_702, prepareFailedOSStatusFourCC: "!dev")
      }
      var hookKeys = Set<String>()
      if let event {
        hookKeys.formUnion(event.stringProps.keys)
        hookKeys.formUnion(event.intProps.keys)
        hookKeys.formUnion(event.boolProps.keys)
      }

      #expect(Set(outgoing.keys) == expectedKeys)
      #expect(hookKeys == expectedKeys)
      // An explicit zero count is a real answer and rides as zero.
      #expect(outgoing["eligible_device_count"] as? Int == 0)
      #expect(event?.intProps["eligible_device_count"] == 0)
      #expect(outgoing["prepare_failed_os_status"] as? Int == 560_227_702)
    }

    @Test(
      "the property builder is the outgoing shape: signed Int, nil keys omitted",
      .tags(.observabilityContract))
    func builderIsTheOutgoingShape() {
      // The DEBUG hook and the PostHog capture both read this one builder, so a
      // test on it is a test on what leaves the Mac.
      let full = TelemetryService.inputResolutionFailureProperties(
        step: "HALDeviceInputSource.prepare.start", osStatus: -10851, fourCC: nil)
      #expect(full.count == 2)
      #expect(full["prepare_failed_step"] as? String == "HALDeviceInputSource.prepare.start")
      #expect(full["prepare_failed_os_status"] as? Int == -10851)

      #expect(TelemetryService.inputResolutionFailureProperties(step: nil, osStatus: nil, fourCC: nil)
        .isEmpty)
      // An empty or "unknown" step is never sent; an invented step is worse than none.
      #expect(TelemetryService.inputResolutionFailureProperties(step: "", osStatus: nil, fourCC: nil)
        .isEmpty)
      #expect(
        TelemetryService.inputResolutionFailureProperties(step: "unknown", osStatus: nil, fourCC: nil)
          .isEmpty)
      // A status of zero is a real, different answer and is sent as zero.
      #expect(
        TelemetryService.inputResolutionFailureProperties(step: nil, osStatus: 0, fourCC: nil)[
          "prepare_failed_os_status"] as? Int == 0)
    }

    @Test("a nil count is OMITTED, never flattened to zero")
    func nilCountsOmitted() {
      // nil means NOT KNOWN — enumeration was skipped or its read failed.
      // Emitting 0 would claim the machine listed no input devices, which is a
      // different and much more alarming fact.
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true,
          enumerationOutcome: "not_attempted",
          inputDeviceCount: nil,
          eligibleDeviceCount: nil,
          inputResolutionSource: "system_default",
          selectedTransport: nil,
          bindOutcome: "succeeded",
          prepareOutcome: "succeeded"
        )
      }

      #expect(event?.intProps["input_device_count"] == nil)
      #expect(event?.intProps.keys.contains("input_device_count") == false)
      #expect(event?.intProps.keys.contains("eligible_device_count") == false)
      #expect(event?.stringProps.keys.contains("selected_transport") == false)
    }

    @Test("an explicit ZERO count rides as zero")
    func explicitZeroCountsEmitted() {
      // The other half of the same distinction: a successful enumeration that
      // genuinely found nothing must be visible as 0, not absent.
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: false,
          enumerationOutcome: "succeeded",
          inputDeviceCount: 0,
          eligibleDeviceCount: 0,
          inputResolutionSource: nil,
          selectedTransport: nil,
          bindOutcome: "not_attempted",
          prepareOutcome: "failed"
        )
      }

      #expect(event?.intProps["input_device_count"] == 0)
      #expect(event?.intProps["eligible_device_count"] == 0)
      #expect(event?.boolProps["default_present"] == false)
      // No device was selected, so there is nothing to attribute.
      #expect(event?.stringProps.keys.contains("input_resolution_source") == false)
    }

    @Test("the fallback attempt carries every field")
    func fallbackAttemptCarriesEverything() {
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: false,
          enumerationOutcome: "succeeded",
          inputDeviceCount: 4,
          eligibleDeviceCount: 1,
          inputResolutionSource: "list_fallback",
          selectedTransport: "built_in",
          bindOutcome: "succeeded",
          prepareOutcome: "succeeded"
        )
      }

      #expect(event?.boolProps["default_present"] == false)
      #expect(event?.intProps["input_device_count"] == 4)
      #expect(event?.intProps["eligible_device_count"] == 1)
      #expect(event?.stringProps["input_resolution_source"] == "list_fallback")
      #expect(event?.stringProps["selected_transport"] == "built_in")
    }

    @Test("the event never carries the ambiguous name `resolution_source`")
    func neverEmitsAmbiguousName() {
      let event = capture {
        TelemetryService.shared.audioInputResolution(
          defaultPresent: true,
          enumerationOutcome: "not_attempted",
          inputDeviceCount: nil,
          eligibleDeviceCount: nil,
          inputResolutionSource: "system_default",
          selectedTransport: nil,
          bindOutcome: "succeeded",
          prepareOutcome: "succeeded"
        )
      }

      #expect(event?.stringProps.keys.contains("resolution_source") == false)
      #expect(event?.stringProps.keys.contains("route_resolution_source") == false)
    }

    // MARK: - pipeline.failed

    @Test("pipeline.failed carries the frozen input resolution source")
    func pipelineFailedCarriesSource() {
      let event = capture {
        TelemetryService.shared.pipelineFailed(
          stage: "transcription", errorCategory: "pipeline_error",
          errorCode: "no_microphone_found", recoverable: false, backend: "parakeet",
          inputResolutionSource: "list_fallback")
      }

      #expect(event?.name == "pipeline.failed")
      #expect(event?.stringProps["input_resolution_source"] == "list_fallback")
    }

    @Test("pipeline.failed omits the key when attribution is unavailable")
    func pipelineFailedOmitsNilSource() {
      let event = capture {
        TelemetryService.shared.pipelineFailed(
          stage: "transcription", errorCategory: "pipeline_error",
          errorCode: "no_microphone_found", recoverable: false, backend: "parakeet")
      }

      #expect(event?.stringProps.keys.contains("input_resolution_source") == false)
    }
  #endif
}
