import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #2021 — the two capture fields must reach Sentry as TAGS, not only as `extra`.
///
/// Three guards, each closing a different way this can silently regress:
/// the wire contract, the production forwarding, and a future sink added
/// without the promotion.
@Suite("Capture error promoted tags (#2021)")
@MainActor
struct CaptureErrorPromotedTagsTests {

  /// Captures the tag payload synchronously, before SDK dispatch.
  ///
  /// `SentryBreadcrumb.captureErrorTagsDelegate` is a process-global, which is
  /// normally forbidden in tests — but the ban is on asserting ACROSS an
  /// `await`, and this body installs, fires and restores with no suspension
  /// point, which `swift-patterns.md` RULE: tests-no-process-global-mutable-delegate
  /// explicitly permits.
  /// A locked box rather than a captured `var`: the delegate is `@Sendable`, so
  /// Swift 6 rejects mutating a captured local from inside it. (I simplified
  /// this away from the reviewer's version and the compiler caught it — an
  /// adopted fix still has to pass its own receipts.)
  private final class TagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String] = [:]
    func set(_ tags: [String: String]) { lock.withLock { value = tags } }
    func get() -> [String: String] { lock.withLock { value } }
  }

  private func tagsFrom(_ fire: () -> Void) -> [String: String] {
    let box = TagBox()
    let prior = SentryBreadcrumb.captureErrorTagsDelegate
    SentryBreadcrumb.captureErrorTagsDelegate = { box.set($0) }
    defer { SentryBreadcrumb.captureErrorTagsDelegate = prior }
    fire()
    return box.get()
  }

  @Test("the production sink forwards both promoted tags onto the event")
  func productionSinkForwardsTags() {
    // The unit tests on `promotedTags` prove the projection. This proves the
    // SINK actually calls it — a correct projection nobody invokes is the
    // a-guard-nothing-arms shape.
    let tags = tagsFrom {
      KernelDictationDriverFactory.defaultCaptureErrorSink(
        KernelFallbackSentryError.captureStartFailed,
        .audioCaptureFailed,
        "recording",
        [
          "capture.failure_mode": "all_zero_from_start",
          "capture.effective_transport": "built_in",
        ],
        nil)
    }
    #expect(tags["capture.failure_mode"] == "all_zero_from_start")
    #expect(tags["capture.effective_transport"] == "built_in")
    // The event's own seed tags must survive the merge.
    #expect(tags["pipeline.stage"] == "recording")
  }

  @Test("an absent transport reaches the event as no key at all")
  func productionSinkOmitsAbsentTransport() {
    // Two-way control for the defect #2021 reports: a field written as "" makes
    // an aggregate return one empty bucket, which reads as data.
    let tags = tagsFrom {
      KernelDictationDriverFactory.defaultCaptureErrorSink(
        KernelFallbackSentryError.captureStartFailed,
        .audioCaptureFailed,
        "recording",
        ["capture.failure_mode": "became_zero_mid_capture"],
        nil)
    }
    #expect(tags["capture.failure_mode"] == "became_zero_mid_capture")
    #expect(tags.keys.contains("capture.effective_transport") == false)
  }

  @Test("the promoted tag names are frozen as literals — this is a wire contract")
  func tagNamesAreFrozen() {
    // Deliberately independent string literals rather than reading
    // `promotedTagKeys`, which would test the list against itself. These names
    // are an EXTERNAL contract: every saved Sentry query and every future
    // #1810 verification is written against them, so a rename of both the
    // builder key and the promotion list together must still fail here.
    #expect(
      SentryAudioExtras.promotedTagKeys.sorted() == [
        "capture.effective_transport",
        "capture.failure_mode",
      ])
  }
}
