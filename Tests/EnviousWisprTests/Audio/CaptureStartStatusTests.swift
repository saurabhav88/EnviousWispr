import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprServices

// #1851 — the Mac's own error code at a failing microphone setup step.
//
// Class: `.observabilityContract`. When this fails, the user sees nothing;
// we lose the ability to say WHY the Mac refused to start the microphone.
// Expected values are literals written from Apple's header constants and plain
// arithmetic, never computed by the helper under test.
@Suite("capture start status — #1851", .tags(.observabilityContract))
struct CaptureStartStatusTests {
  // MARK: - four-character form

  @Test("a printable four-character status reads as its text")
  func printableStatusReadsAsText() {
    // kAudioHardwareNotRunningError, kAudioHardwareUnspecifiedError,
    // kAudioHardwareBadDeviceError (AudioHardwareBase.h), as plain integers.
    #expect(AudioStatusFormatting.fourCharacterCode(1_937_010_544) == "stop")
    #expect(AudioStatusFormatting.fourCharacterCode(2_003_329_396) == "what")
    #expect(AudioStatusFormatting.fourCharacterCode(560_227_702) == "!dev")
  }

  @Test("a numeric or unprintable status has no four-character form")
  func nonPrintableStatusIsNil() {
    // kAudioUnitErr_InvalidPropertyValue, kAudioUnitErr_FormatNotSupported,
    // noErr, a NUL first byte, and a byte above 0x7E.
    #expect(AudioStatusFormatting.fourCharacterCode(-10851) == nil)
    #expect(AudioStatusFormatting.fourCharacterCode(-10868) == nil)
    #expect(AudioStatusFormatting.fourCharacterCode(0) == nil)
    #expect(AudioStatusFormatting.fourCharacterCode(0x0074_7374) == nil)
    #expect(AudioStatusFormatting.fourCharacterCode(Int32(bitPattern: 0x8073_7470)) == nil)
  }

  @Test("noErr is never recorded as a failing status")
  func noErrIsNotAFailingStatus() {
    // `guard status == noErr, let unit` also fails on a nil unit with status 0.
    #expect(AudioStatusFormatting.failingStatus(0) == nil)
    #expect(AudioStatusFormatting.failingStatus(-10851) == -10851)
    #expect(AudioStatusFormatting.failingStatus(1_937_010_544) == 1_937_010_544)
  }

  // MARK: - the error keeps its identity

  @Test("the status rides on the error and an absent status stays nil, not zero")
  func statusRidesOnTheError() {
    let withStatus = AudioError.formatCreationFailed(
      source: "HALDeviceInputSource.prepare.start", osStatus: 1_937_010_544)
    let without = AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.start")

    #expect(withStatus.diagnosticOSStatus == 1_937_010_544)
    #expect(withStatus.diagnosticSource == "HALDeviceInputSource.prepare.start")
    #expect(without.diagnosticOSStatus == nil)
    #expect(AudioError.alreadyCapturing.diagnosticOSStatus == nil)
    #expect(AudioError.noBuiltInMicrophoneFound.diagnosticOSStatus == nil)
  }

  @Test("a status never moves the Sentry grouping, title or message")
  func statusDoesNotMoveSentryIdentity() {
    let withStatus = AudioError.formatCreationFailed(source: "x", osStatus: -10851)
    let without = AudioError.formatCreationFailed(source: "x")

    #expect(withStatus.errorCode == 1)
    #expect(withStatus.sentryFingerprintDescriptor == "EnviousWisprAudio.AudioError#1")
    #expect(withStatus.sentryFingerprintDescriptor == without.sentryFingerprintDescriptor)
    #expect(withStatus.sentrySemanticID == without.sentrySemanticID)
    #expect(withStatus.localizedDescription == "Failed to create audio format.")
    #expect(
      SentryBreadcrumb.handledErrorFingerprint(
        for: .audioCaptureFailed, error: withStatus, environment: "production")
        == SentryBreadcrumb.handledErrorFingerprint(
          for: .audioCaptureFailed, error: without, environment: "production"))
  }

  // MARK: - the attempt record

  private func projection(
    _ state: InputResolutionAttemptState
  ) -> InputResolutionAttemptTelemetry {
    InputResolutionAttemptTelemetry(
      state.finalized(
        resolution: InputDeviceResolution(
          outcome: .selected(42, source: .systemDefault),
          defaultPresent: true,
          enumerationOutcome: .notAttempted,
          inputDeviceCount: nil,
          eligibleDeviceCount: nil,
          selectedTransport: nil)))
  }

  @Test("a failed cold attempt carries the failing step and the Mac's status")
  func failedAttemptCarriesStepAndStatus() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    state.recordFailure(
      of: .formatCreationFailed(
        source: "HALDeviceInputSource.prepare.start", osStatus: 1_937_010_544))

    let telemetry = projection(state)

    #expect(telemetry.prepareOutcome == "failed")
    #expect(telemetry.prepareFailedStep == "HALDeviceInputSource.prepare.start")
    #expect(telemetry.prepareFailedOSStatus == 1_937_010_544)
    #expect(telemetry.prepareFailedOSStatusFourCC == "stop")
  }

  @Test("a negative status stays negative and has no four-character form")
  func negativeStatusStaysNegative() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    state.recordFailure(
      of: .formatCreationFailed(source: "HALDeviceInputSource.prepare.initialize", osStatus: -10868)
    )

    let telemetry = projection(state)

    #expect(telemetry.prepareFailedOSStatus == -10868)
    #expect(telemetry.prepareFailedOSStatusFourCC == nil)
  }

  @Test("the FIRST failure wins; a later one never replaces the cause")
  func firstFailureWins() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    state.recordFailure(
      of: .formatCreationFailed(source: "HALDeviceInputSource.prepare.initialize", osStatus: -10868)
    )
    state.recordFailure(
      of: .formatCreationFailed(source: "HALDeviceInputSource.prepare.start", osStatus: 1))

    let telemetry = projection(state)

    #expect(telemetry.prepareFailedStep == "HALDeviceInputSource.prepare.initialize")
    #expect(telemetry.prepareFailedOSStatus == -10868)
  }

  @Test("a step with no status reports the step alone, with no zero")
  func stepWithoutStatusHasNoStatus() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    state.recordFailure(
      of: .formatCreationFailed(source: "HALDeviceInputSource.prepare.converter"))

    let telemetry = projection(state)

    #expect(telemetry.prepareFailedStep == "HALDeviceInputSource.prepare.converter")
    #expect(telemetry.prepareFailedOSStatus == nil)
    #expect(telemetry.prepareFailedOSStatusFourCC == nil)
  }

  @Test("an unnamed step records nothing: no invented step")
  func unnamedStepRecordsNothing() {
    var state = InputResolutionAttemptState()
    state.recordFailure(of: .formatCreationFailed())  // default source "unknown"
    state.recordFailure(of: .noBuiltInMicrophoneFound)  // no diagnostic source

    let telemetry = projection(state)

    #expect(telemetry.prepareFailedStep == nil)
    #expect(telemetry.prepareFailedOSStatus == nil)
  }

  @Test("a prepare that reached the end carries no failure fields")
  func successfulAttemptCarriesNoFailure() {
    // Negative control: even with a failure recorded earlier, an attempt whose
    // outcome is `succeeded` reports none.
    var state = InputResolutionAttemptState()
    state.recordFailure(
      of: .formatCreationFailed(source: "HALDeviceInputSource.prepare.start", osStatus: 1))
    state.recordBind(succeeded: true)
    state.recordPrepareSucceeded()

    let telemetry = projection(state)

    #expect(telemetry.prepareOutcome == "succeeded")
    #expect(telemetry.prepareFailedStep == nil)
    #expect(telemetry.prepareFailedOSStatus == nil)
    #expect(telemetry.prepareFailedOSStatusFourCC == nil)
  }
}
