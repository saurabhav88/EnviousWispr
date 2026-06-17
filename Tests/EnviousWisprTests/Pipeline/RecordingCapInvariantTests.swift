import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

// MARK: - RecordingCapInvariantTests (#1060)
//
// Locks the soft-vs-hard cap relationship: the in-process emergency ceiling
// (`AudioCaptureManager.maxRecordingDurationSeconds`) MUST stay strictly above
// the graceful soft cap (`TimingConstants.maxRecordingDuration`) so the graceful
// stop+transcribe always pre-empts the hard teardown. A regression here would
// make the hard cap fire first and tear capture down non-gracefully.

@Suite struct RecordingCapInvariantTests {

  @Test("hard emergency cap is strictly greater than the graceful soft cap")
  func hardCapExceedsSoftCap() {
    #expect(AudioCaptureManager.maxRecordingDurationSeconds > TimingConstants.maxRecordingDuration)
  }

  @Test("soft cap is the 60-minute value and leaves room for the warning lead")
  func softCapAndLeadAreConsistent() {
    // In release these are the shipped constants (DEBUG overrides default off).
    #expect(TimingConstants.maxRecordingDuration == 3600)
    #expect(TimingConstants.maxDurationWarningLeadSeconds == 60)
    #expect(TimingConstants.maxRecordingDuration > TimingConstants.maxDurationWarningLeadSeconds)
  }
}
