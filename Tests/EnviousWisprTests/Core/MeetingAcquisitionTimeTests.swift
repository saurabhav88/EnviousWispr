import EnviousWisprCore
import Foundation
import Testing

@Suite("Meeting acquisition time (#4355)", .tags(.productOutcome))
struct MeetingAcquisitionTimeTests {
  @Test("an estimated time never equals a hardware time with the same ticks")
  func provenanceIsPartOfIdentity() {
    let meeting = UUID()
    let hardware = MeetingAcquisitionTime(
      recording: meeting, hostTicks: 1_000, provenance: .hardware)
    let estimated = MeetingAcquisitionTime(
      recording: meeting, hostTicks: 1_000, provenance: .estimated)
    #expect(hardware != estimated)
    #expect(Set([hardware, estimated]).count == 2)
  }

  @Test("the same ticks in two meetings are two different times")
  func recordingIsPartOfIdentity() {
    let a = MeetingAcquisitionTime(recording: UUID(), hostTicks: 5, provenance: .observed)
    let b = MeetingAcquisitionTime(recording: UUID(), hostTicks: 5, provenance: .observed)
    #expect(a != b)
  }
}
