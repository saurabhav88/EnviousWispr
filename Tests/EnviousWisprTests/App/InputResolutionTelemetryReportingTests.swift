import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprServices

// #1714 — locks the ONE mapper from the Audio module's cold-attempt projection
// to `TelemetryService`.
//
// The mapper is deliberately dumb: eight fields in, eight fields out, no
// renaming, defaulting or recomputation. This suite exists because a mapper is
// exactly where a `?? 0` or a renamed key gets added later without anyone
// noticing that the resolver's decision and the recorded event have drifted.
//
// `testEventHook` is DEBUG-only, so this suite is DEBUG-gated.
@Suite("InputResolutionTelemetryReporting — #1714")
@MainActor
struct InputResolutionTelemetryReportingTests {
  #if DEBUG

    private final class Box: @unchecked Sendable {
      var event: CapturedTelemetryEvent?
    }

    /// Builds the projection the way production does: through a real finalised
    /// attempt, not by hand. A hand-built projection would let this suite
    /// disagree with the resolver and still pass.
    private func projection(
      _ source: InputResolutionSource?,
      bindSucceeded: Bool,
      prepareSucceeded: Bool,
      counts: (Int, Int)?
    ) -> InputResolutionAttemptTelemetry {
      var state = InputResolutionAttemptState()
      state.recordBind(succeeded: bindSucceeded)
      if prepareSucceeded { state.recordPrepareSucceeded() }
      let outcome: InputDeviceResolution.Outcome =
        source.map { .selected(42, source: $0) } ?? .failed(.noBuiltInMicrophoneFound)
      return InputResolutionAttemptTelemetry(
        state.finalized(
          resolution: InputDeviceResolution(
            outcome: outcome,
            defaultPresent: source == .systemDefault,
            enumerationOutcome: counts == nil ? .notAttempted : .succeeded,
            inputDeviceCount: counts?.0,
            eligibleDeviceCount: counts?.1,
            selectedTransport: source == nil ? nil : "built_in")))
    }

    private func capture(_ attempt: InputResolutionAttemptTelemetry)
      -> CapturedTelemetryEvent?
    {
      let box = Box()
      let previous = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = previous }
      InputResolutionTelemetryReporting.report(attempt)
      return box.event
    }

    @Test("every field reaches TelemetryService unchanged")
    func allFieldsPassThrough() {
      let event = capture(
        projection(.listFallback, bindSucceeded: true, prepareSucceeded: true, counts: (4, 1)))

      #expect(event?.name == "audio.input_resolution")
      #expect(event?.boolProps["default_present"] == false)
      #expect(event?.stringProps["enumeration_outcome"] == "succeeded")
      #expect(event?.intProps["input_device_count"] == 4)
      #expect(event?.intProps["eligible_device_count"] == 1)
      #expect(event?.stringProps["input_resolution_source"] == "list_fallback")
      #expect(event?.stringProps["selected_transport"] == "built_in")
      #expect(event?.stringProps["bind_outcome"] == "succeeded")
      #expect(event?.stringProps["prepare_outcome"] == "succeeded")
    }

    @Test("the mapper does not invent counts for a not-attempted enumeration")
    func doesNotInventCounts() {
      let event = capture(
        projection(.systemDefault, bindSucceeded: true, prepareSucceeded: true, counts: nil))

      #expect(event?.intProps.keys.contains("input_device_count") == false)
      #expect(event?.intProps.keys.contains("eligible_device_count") == false)
      #expect(event?.stringProps["enumeration_outcome"] == "not_attempted")
      #expect(event?.boolProps["default_present"] == true)
    }

    @Test("a failed resolution reports no source and no transport")
    func failedResolutionReportsNoSource() {
      let event = capture(
        projection(nil, bindSucceeded: false, prepareSucceeded: false, counts: (0, 0)))

      #expect(event?.stringProps.keys.contains("input_resolution_source") == false)
      #expect(event?.stringProps.keys.contains("selected_transport") == false)
      // An explicit zero is a real answer and must still ride.
      #expect(event?.intProps["input_device_count"] == 0)
      #expect(event?.stringProps["bind_outcome"] == "failed")
      #expect(event?.stringProps["prepare_outcome"] == "failed")
    }

    @Test("a prepare cannot report success on a device that was never bound")
    func neverReportsSuccessWithoutBind() {
      // The structural invariant from Chunk 2, carried all the way to the wire.
      let event = capture(
        projection(.systemDefault, bindSucceeded: false, prepareSucceeded: true, counts: nil))

      #expect(event?.stringProps["bind_outcome"] == "failed")
      #expect(event?.stringProps["prepare_outcome"] == "failed")
    }

    // MARK: - The installer, and its ONE production call site
    //
    // `report(_:)` being correct proves nothing if nobody installs it. These two
    // cover the wire itself: deleting the installer or its bootstrapper call
    // previously left every other test in this suite green.

    @Test("observing installs the manager's outbound callback")
    func observingInstallsOutboundCallback() {
      let manager = InputResolutionTelemetryReporting.observing(AudioCaptureManager())

      #expect(
        manager.onFinalizedInputResolutionAttempt.map { _ in true } ?? false,
        "the reporting helper must install the manager observer")
    }

    @Test("the production composition root installs observing exactly once")
    func bootstrapperInstallsObservingExactlyOnce() throws {
      let source = try String(
        contentsOf: RepoRoot.sourceURL(
          "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"),
        encoding: .utf8)
      let needle = "InputResolutionTelemetryReporting.observing("
      let count = source.components(separatedBy: needle).count - 1

      #expect(count == 1, "expected one production installer, found \(count)")
    }

  #endif
}
