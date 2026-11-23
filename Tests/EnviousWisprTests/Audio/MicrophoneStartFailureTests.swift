import Foundation
import Testing

@testable import EnviousWisprAudio

/// #4601 §3.7: the one decision behind the "can't reach your microphone" notice. When these
/// fail, a stuck driver shows the generic retry sentence again, or an unrelated failure (a
/// different step, a different status) tells the user another app's driver may be stuck.
@Suite("MicrophoneStartFailure — #4601", .tags(.productOutcome))
struct MicrophoneStartFailureTests {

  @Test(
    "a start that was not answered is not-responding, whatever step it names",
    arguments: [
      "HALDeviceInputSource.prepare.timed_out", "HALDeviceInputSource.prepare.lane_wedged",
      "AudioCaptureManager.route.timed_out",
    ])
  func notRespondingErrorIsRecognized(_ source: String) {
    #expect(MicrophoneStartFailure.isNotResponding(AudioError.microphoneNotResponding(source: source)))
  }

  @Test("status 60 from starting the unit is not-responding")
  func status60AtStartIsRecognized() {
    #expect(
      MicrophoneStartFailure.isNotResponding(
        AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.start", osStatus: 60)))
  }

  @Test("near misses keep their generic treatment")
  func nearMissesStayGeneric() {
    let misses: [any Error] = [
      AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.init", osStatus: 60),
      AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.start", osStatus: 61),
      AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.start", osStatus: nil),
      AudioError.noBuiltInMicrophoneFound,
      CancellationError(),
      NSError(domain: NSOSStatusErrorDomain, code: 60),
    ]
    for error in misses {
      #expect(MicrophoneStartFailure.isNotResponding(error) == false, "\(error)")
    }
  }
}
