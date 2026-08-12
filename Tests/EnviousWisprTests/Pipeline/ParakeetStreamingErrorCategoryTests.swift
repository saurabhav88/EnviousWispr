import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprFluidAudioBridge
@testable import EnviousWisprPipeline

/// #1654 ship criterion 5 — the change that makes every other part of this work
/// observable.
///
/// Before this, `limb.failure_observed` carried `String(reflecting: type(of: error))`,
/// so a streaming failure reported the name of whatever wrapper survived the trip from
/// the transcription helper. Production has exactly one such event, from 2026-07-30, and
/// its category is the literal string `NSError` — every distinct cause reading as one
/// type is the defect, measured rather than argued.
///
/// **Scope of this suite, stated so it is not read as more than it is.** It tests the
/// category MAPPING, not the emit path: it proves an identified error yields its semantic
/// ID and an unidentified one still yields the type name. Whether the emission fires, and
/// with which `result`, is the adapter's own behaviour and is covered by the existing
/// adapter suites.
@MainActor
@Suite("Streaming failure category is the semantic ID, not the type name (#1654)")
struct ParakeetStreamingErrorCategoryTests {

  /// A stand-in conformer. Deliberately NOT one of the shipped identity types: the
  /// contract under test is "any error that declares a stable identity keeps it", and
  /// using a shipped type would let the test pass on a concrete-type check that would
  /// silently drop every other conformer.
  private struct IdentifiedError: Error, StableSentryErrorIdentity {
    var sentryFingerprintDescriptor: String { "Fixture.descriptor" }
    var sentrySemanticID: String { "fixture.semantic_id" }
  }

  private struct PlainError: Error {}

  @Test("an error that declares a stable identity reports its semantic ID")
  func identifiedErrorReportsSemanticID() {
    #expect(
      ParakeetEngineAdapter.streamingErrorCategory(IdentifiedError()) == "fixture.semantic_id")
  }

  /// The two-way control. Without it, a mapping that returned a constant would pass the
  /// test above, and the suite would prove the field is populated rather than correct.
  @Test("an error without a declared identity still falls back to its type name")
  func plainErrorFallsBackToTypeName() {
    let category = ParakeetEngineAdapter.streamingErrorCategory(PlainError())
    #expect(category.contains("PlainError"))
    #expect(category != "fixture.semantic_id")
  }

  /// The regression this issue exists for, pinned as a value rather than described. A
  /// bridged `NSError` declares no identity, so it takes the fallback — and the fallback
  /// is exactly what production has been sending.
  @Test("a bare NSError still reports NSError, which is the shipped behaviour being replaced")
  func bareNSErrorReportsTheOldShape() {
    let category = ParakeetEngineAdapter.streamingErrorCategory(NSError(domain: "d", code: 1))
    #expect(category.contains("NSError"))
  }

  /// And the case that closes the loop: the real shipped streaming identity, reaching the
  /// category through the same path, produces a name that says what actually failed.
  @Test("the shipped streaming identity produces a cause-naming category")
  func shippedStreamingIdentityReportsItsCause() {
    let error = ParakeetStreamingSentryError.allWindowsFailed(inner: .processingFailed)
    #expect(
      ParakeetEngineAdapter.streamingErrorCategory(error)
        == "parakeet_streaming.all_windows_failed.processing_failed")
  }
}
