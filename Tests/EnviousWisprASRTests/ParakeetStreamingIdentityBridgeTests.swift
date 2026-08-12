@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprFluidAudioBridge

/// #1654 — the one place the WHOLE chain runs: a real FluidAudio error, through the
/// bridge classifier, into the app-owned identity, out to the bridged `NSError` that
/// actually crosses XPC.
///
/// **Why this is a third file rather than a section of an existing one.** Three suites
/// now cover this feature and the split is forced by the naming trap the bridge exists
/// for, not by taste:
///
/// - `FluidAudioBridgeClassificationTests` (vendor -> kind) imports FluidAudio only. It
///   names `ASRError`, which is the vendor's.
/// - `ParakeetStreamingSentryErrorTests` (kind -> identity -> wire) lives in
///   `EnviousWisprTests`, which cannot import FluidAudio at all: `ASRError` there
///   resolves to OUR type.
/// - This file needs both `EnviousWisprASR` and FluidAudio, and importing both makes
///   `ASRError` genuinely ambiguous — the compiler says so. So it names only
///   `SlidingWindowAsrError`, which no target of ours shadows.
///
/// The consequence worth stating plainly: the start-leg positive case cannot be driven
/// end to end from here, because constructing a vendor `ASRError` requires naming it.
/// It is covered as two halves instead — vendor -> inner cause in the bridge suite,
/// inner cause -> `.startFailed` in the identity suite — and those compose soundly
/// because `FluidAudioStreamingInnerCause` is payload-free, so nothing can be lost or
/// added between them.
@Suite("Parakeet streaming identity, vendor error to wire (#1654)")
struct ParakeetStreamingIdentityBridgeTests {

  /// The named-cause path, whole. This is the row that would have caught the defect this
  /// issue was filed for: the one streaming failure production has ever recorded arrived
  /// as `error_category: "NSError"` because nothing survived the crossing.
  @Test("a real vendor error keeps a named identity all the way to the bridged NSError")
  func realVendorErrorKeepsItsIdentityToTheWire() throws {
    // A vendor error whose inner cause is one we can name is not constructible here
    // without naming `ASRError` (see the suite comment), so the inner is deliberately a
    // foreign error and the assertion is on the OUTER identity surviving intact.
    let vendor = SlidingWindowAsrError.modelProcessingFailed(NSError(domain: "f", code: 1))

    let kind = try #require(classifyFluidAudioStreamingError(vendor))
    let error = ParakeetStreamingSentryError(mapping: kind)
    let bridged = error as NSError

    #expect(bridged.domain == ParakeetStreamingSentryError.errorDomain)
    // The reconstruction the proxy performs, on the value that really crosses.
    #expect(ParakeetStreamingSentryError(reconstructingFrom: bridged) == error)
    #expect(error.sentrySemanticID == "parakeet_streaming.all_windows_failed.unrecognised")
  }

  /// Two-way control. Without it, an implementation that gave EVERY error the streaming
  /// identity would pass the test above — the suite would prove the identity is reachable
  /// and not that it is earned.
  @Test("a foreign vendor error acquires no streaming identity")
  func foreignErrorGetsNoIdentity() {
    struct ForeignError: Error {}
    #expect(classifyFluidAudioStreamingError(ForeignError()) == nil)
    #expect(ParakeetStreamingSentryError(mappingStartFailure: ForeignError()) == nil)
  }

  /// The end-to-end privacy guard: a marker planted in a real vendor error must not reach
  /// the `NSError` that crosses the process boundary. The bridge suite proves the KIND is
  /// clean; this proves nothing re-introduces the text downstream of it.
  @Test("vendor text planted in a real error cannot reach the wire")
  func vendorTextCannotReachTheWire() throws {
    let secret = "VENDOR-TEXT-THAT-MUST-NOT-TRAVEL"
    let inner = NSError(domain: "f", code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
    let vendor = SlidingWindowAsrError.modelProcessingFailed(inner)
    // Control: the fixture really does carry the marker through the vendor's own
    // description, so a clean result below belongs to our types, not to a fixture that
    // never carried it.
    #expect(vendor.localizedDescription.contains(secret))

    let kind = try #require(classifyFluidAudioStreamingError(vendor))
    let bridged = ParakeetStreamingSentryError(mapping: kind) as NSError

    #expect(!bridged.localizedDescription.contains(secret))
    #expect(!String(describing: bridged.userInfo).contains(secret))
    // And it is not clean merely by discarding everything: the cause still travels.
    #expect(bridged.localizedDescription.contains("every audio window failed"))
  }

  /// An actual archive round-trip, not an in-process cast — the same distinction the
  /// batch conformer learned the hard way. This is the closest a unit test gets to the
  /// XPC crossing itself.
  @Test("the identity survives a real NSSecureCoding archive round-trip")
  func identitySurvivesArchive() throws {
    let vendor = SlidingWindowAsrError.bufferOverflow
    let kind = try #require(classifyFluidAudioStreamingError(vendor))
    let error = ParakeetStreamingSentryError(mapping: kind)

    let data = try NSKeyedArchiver.archivedData(
      withRootObject: error as NSError, requiringSecureCoding: true)
    let decoded = try #require(
      try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))

    #expect(ParakeetStreamingSentryError(reconstructingFrom: decoded) == error)
    #expect(decoded.localizedDescription == error.errorDescription)
  }
}
