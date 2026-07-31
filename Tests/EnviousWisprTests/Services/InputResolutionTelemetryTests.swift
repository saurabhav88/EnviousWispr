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
