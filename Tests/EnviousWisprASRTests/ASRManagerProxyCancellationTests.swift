import Foundation
import Testing

@testable import EnviousWisprASR

/// #1654 (cloud review P2) — a cancellation that crosses the XPC boundary must arrive as a
/// `CancellationError` again, not as an anonymous `NSError`.
///
/// **The defect this closes was mine and it was one commit from shipping.** #1654 gave the
/// streaming START leg a telemetry event where it previously emitted nothing. The adapter
/// guards that leg with `catch is CancellationError` — but `XPCErrorSanitizer` preserves
/// only domain, code and description, so a service-side cancellation reaches the app as a
/// plain `NSError` and the guard cannot match it. A user cancelling a recording would have
/// been counted as a streaming start FAILURE.
///
/// The first test is the measurement the fix rests on, written as an executable assertion
/// rather than a comment, so a Swift change to the bridged representation fails here
/// instead of silently turning the reconstruction into a no-op.
@Suite("Cancellation survives the XPC boundary (#1654)")
struct ASRManagerProxyCancellationTests {

  /// Pins the bridged representation. If this fails, `reconstructCancellation`'s domain
  /// and code are wrong and every other test in this file is passing vacuously.
  @Test("a bridged CancellationError is domain Swift.CancellationError, code 1")
  func bridgedRepresentationIsPinned() {
    let bridged = CancellationError() as NSError
    #expect(bridged.domain == "Swift.CancellationError")
    #expect(bridged.code == 1)
  }

  /// The reason the reconstruction has to exist at all: the type does NOT survive on its
  /// own. This is the negative half — without it, someone could reasonably conclude the
  /// whole mechanism is redundant.
  @Test("the CancellationError TYPE does not survive a real archive round-trip")
  func typeIsLostAcrossTheBoundary() throws {
    let bridged = CancellationError() as NSError
    let sanitized = NSError(
      domain: bridged.domain, code: bridged.code,
      userInfo: [NSLocalizedDescriptionKey: bridged.localizedDescription])
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: sanitized, requiringSecureCoding: true)
    let decoded = try #require(
      try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))

    #expect(!((decoded as Error) is CancellationError))
  }

  @Test("reconstructCancellation restores the type from the flattened error")
  func restoresTheType() throws {
    let bridged = CancellationError() as NSError
    let restored = try #require(ASRManagerProxy.reconstructCancellation(bridged))
    #expect(restored is CancellationError)
  }

  /// The two-way control. A reconstructor that returned `CancellationError()` for
  /// everything would pass every test above while silently swallowing real failures —
  /// which is the worse failure direction, so it gets the explicit cases.
  @Test("reconstructCancellation refuses anything that is not a cancellation")
  func refusesNonCancellations() {
    let cases: [NSError] = [
      // Our own streaming identity, which must keep its own reconstruction.
      ParakeetStreamingSentryError.allWindowsFailed(inner: .processingFailed) as NSError,
      // Right domain, wrong code.
      NSError(domain: "Swift.CancellationError", code: 2),
      // Right code, wrong domain.
      NSError(domain: "SomeOtherDomain", code: 1),
      // A prefix match would wrongly accept this; an exact match does not.
      NSError(domain: "Swift.CancellationErrorish", code: 1),
      NSError(domain: "com.apple.CoreML", code: 0),
    ]
    for error in cases {
      #expect(
        ASRManagerProxy.reconstructCancellation(error) == nil,
        "must not claim \(error.domain)#\(error.code)")
    }
  }

  /// Ordering matters: cancellation is checked before the identity reconstructors, so this
  /// asserts the two cannot collide. Our identity domain is distinct, so a cancellation
  /// can never be mistaken for a streaming failure or vice versa.
  @Test("the cancellation domain cannot collide with the streaming identity domain")
  func domainsAreDisjoint() {
    #expect(ParakeetStreamingSentryError.errorDomain != "Swift.CancellationError")
    let streaming = ParakeetStreamingSentryError.startFailed(inner: .notInitialized) as NSError
    #expect(ASRManagerProxy.reconstructCancellation(streaming) == nil)
    #expect(ParakeetStreamingSentryError(reconstructingFrom: CancellationError() as NSError) == nil)
  }
}
