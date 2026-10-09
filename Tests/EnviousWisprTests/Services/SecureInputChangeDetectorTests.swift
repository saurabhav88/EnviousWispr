import EnviousWisprServices
import Testing

/// #3544 P3 (plan A2): the keyboard listener reports Secure Input changes, not every sample.
///
/// Observability contract: when this fails, the diagnostic log misses a Secure Input state already
/// on at launch, floods with a line every 5 s, records an unknown owner as Secure Input off, or
/// misses a change of owner while it stays on.
@Suite(.tags(.observabilityContract))
struct SecureInputChangeDetectorTests {

  @Test("the first sample is always reported, on or off")
  func firstSampleIsReported() {
    var off = SecureInputChangeDetector()
    #expect(off.sample(enabled: false, ownerPID: nil) == .init(enabled: false, ownerPID: nil))
    var on = SecureInputChangeDetector()
    #expect(on.sample(enabled: true, ownerPID: 812) == .init(enabled: true, ownerPID: 812))
  }

  @Test("an unchanged sample reports nothing")
  func unchangedIsQuiet() {
    var detector = SecureInputChangeDetector()
    _ = detector.sample(enabled: true, ownerPID: 812)
    #expect(detector.sample(enabled: true, ownerPID: 812) == nil)
    _ = detector.sample(enabled: false, ownerPID: nil)
    #expect(detector.sample(enabled: false, ownerPID: nil) == nil)
  }

  @Test("entry and clear are each reported, and clearing drops the owner")
  func entryAndClear() {
    var detector = SecureInputChangeDetector()
    _ = detector.sample(enabled: false, ownerPID: nil)
    #expect(detector.sample(enabled: true, ownerPID: 812) == .init(enabled: true, ownerPID: 812))
    // A stale owner read while off is never carried.
    #expect(
      detector.sample(enabled: false, ownerPID: 812) == .init(enabled: false, ownerPID: nil))
  }

  @Test("an unknown owner stays Secure Input on; a new owner while on is reported")
  func ownerChanges() {
    var detector = SecureInputChangeDetector()
    #expect(detector.sample(enabled: true, ownerPID: nil) == .init(enabled: true, ownerPID: nil))
    #expect(detector.sample(enabled: true, ownerPID: 812) == .init(enabled: true, ownerPID: 812))
    #expect(detector.sample(enabled: true, ownerPID: 950) == .init(enabled: true, ownerPID: 950))
  }
}
