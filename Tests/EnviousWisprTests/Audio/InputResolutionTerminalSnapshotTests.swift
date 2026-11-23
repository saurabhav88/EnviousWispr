import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprServices

/// #4601 §3.8: the terminal snapshot of a microphone start must say "unknown" when the
/// start ended before its resolution or bind was known, never false, zero or
/// `not_attempted`. When these fail, the `audio.input_resolution` dashboard misstates
/// what the Mac reported (an Observability Contract, not capture coverage).
@Suite("input resolution terminal snapshot — #4601", .tags(.observabilityContract))
@MainActor
struct InputResolutionTerminalSnapshotTests {

  private static func outgoing(_ attempt: FinalizedInputResolutionAttempt) -> [String: Any] {
    let telemetry = InputResolutionAttemptTelemetry(attempt)
    return TelemetryService.inputResolutionProperties(
      defaultPresent: telemetry.defaultPresent,
      enumerationOutcome: telemetry.enumerationOutcome,
      inputDeviceCount: telemetry.inputDeviceCount,
      eligibleDeviceCount: telemetry.eligibleDeviceCount,
      inputResolutionSource: telemetry.inputResolutionSource,
      selectedTransport: telemetry.selectedTransport,
      bindOutcome: telemetry.bindOutcome,
      prepareOutcome: telemetry.prepareOutcome,
      prepareFailedStep: telemetry.prepareFailedStep,
      prepareFailedOSStatus: telemetry.prepareFailedOSStatus,
      prepareFailedOSStatusFourCC: telemetry.prepareFailedOSStatusFourCC)
  }

  @Test(
    "a start that ended before its resolution was known sends only what is known",
    arguments: [
      "HALDeviceInputSource.prepare.timed_out", "HALDeviceInputSource.prepare.lane_wedged",
    ])
  func unavailableSnapshotOmitsUnknowns(step: String) {
    let attempt = FinalizedInputResolutionAttempt.unavailable(
      failure: .microphoneNotResponding(source: step))

    let props = Self.outgoing(attempt)

    #expect(Set(props.keys) == ["prepare_outcome", "prepare_failed_step"])
    #expect(props["prepare_outcome"] as? String == "failed")
    #expect(props["prepare_failed_step"] as? String == step)
  }

  @Test("completed false and zero facts still ride as false and zero")
  func completedFalseAndZeroArePreserved() {
    let resolution = InputDeviceResolution(
      outcome: .failed(.noBuiltInMicrophoneFound), defaultPresent: false,
      enumerationOutcome: .succeeded, inputDeviceCount: 0, eligibleDeviceCount: 0,
      selectedTransport: nil)
    var state = InputResolutionAttemptState()
    state.recordFailure(of: .noBuiltInMicrophoneFound)

    let props = Self.outgoing(state.finalized(resolution: resolution))

    #expect(props["default_present"] as? Bool == false)
    #expect(props["enumeration_outcome"] as? String == "succeeded")
    #expect(props["input_device_count"] as? Int == 0)
    #expect(props["eligible_device_count"] as? Int == 0)
    #expect(props["bind_outcome"] as? String == "not_attempted")
  }

  /// #4601 §3.8: the bypassed default's kind leaves the Mac only when Auto actually bypassed it.
  @Test("skipped_default_transport rides only when a default was bypassed")
  func skippedDefaultTransportProjection() {
    func props(skipped: String?) -> [String: Any] {
      TelemetryService.inputResolutionProperties(
        defaultPresent: true, enumerationOutcome: "succeeded", inputDeviceCount: 2,
        eligibleDeviceCount: 1, inputResolutionSource: "list_fallback",
        selectedTransport: "built_in", skippedDefaultTransport: skipped, bindOutcome: "succeeded",
        prepareOutcome: "succeeded", prepareFailedStep: nil, prepareFailedOSStatus: nil,
        prepareFailedOSStatusFourCC: nil)
    }
    #expect(props(skipped: "virtual")["skipped_default_transport"] as? String == "virtual")
    #expect(props(skipped: nil)["skipped_default_transport"] == nil)

    // The frozen attempt carries the resolver's value through the projection unchanged.
    var resolution = InputDeviceResolution(
      outcome: .selected(7, source: .listFallback), defaultPresent: true,
      enumerationOutcome: .succeeded, inputDeviceCount: 2, eligibleDeviceCount: 1,
      selectedTransport: "built_in")
    resolution.skippedDefaultTransport = "aggregate"
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    state.recordPrepareSucceeded()
    let telemetry = InputResolutionAttemptTelemetry(state.finalized(resolution: resolution))
    #expect(telemetry.skippedDefaultTransport == "aggregate")
  }

  @Test("the not-responding error names its step, has no OSStatus and its own identity")
  func notRespondingErrorIdentity() {
    let error = AudioError.microphoneNotResponding(source: "HALDeviceInputSource.prepare.timed_out")

    #expect(error.diagnosticSource == "HALDeviceInputSource.prepare.timed_out")
    #expect(error.diagnosticOSStatus == nil)
    #expect(error.errorCode == 4)
    #expect(error.sentrySemanticID == "audio.microphone_not_responding")
  }
}
