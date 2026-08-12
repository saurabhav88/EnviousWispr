import Foundation
import Testing

/// #2021 — every sink that forwards CAPTURE extras to Sentry must also promote
/// them to tags.
///
/// Why a source scan rather than a behavioural test: the four sinks are inline
/// DEFAULT ARGUMENTS on initialisers, so three of them cannot be invoked
/// directly and a behavioural test can only reach the one named static. The
/// failure this guards is a FIFTH sink added later without the promotion, and
/// that failure is silent in the worst way — the fleet keeps receiving tagged
/// events from the other four, so every aggregate still looks complete while
/// quietly under-counting. A partially-tagged population is worse than an
/// untagged one.
///
/// Found the hard way: this change's own plan named TWO sinks. Enumerating
/// properly found FOUR.
@Suite("Capture-error tag promotion is complete (#2021)")
struct CaptureErrorTagPromotionFreezeTests {

  /// Files whose `captureError` calls carry `SentryAudioExtras.buildCaptureExtras`
  /// output. Derived by tracing every consumer of that builder.
  private static let capturePathFiles = [
    "Sources/EnviousWisprPipeline/HeartPathTelemetryEmitter.swift",
    "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift",
    "Sources/EnviousWisprPipeline/KernelLifecycleTelemetrySink.swift",
  ]

  @Test("every capture-path captureError call promotes the tags")
  func everyCapturePathSinkPromotesTags() throws {
    let root = RepoRoot.url
    var offenders: [String] = []
    var totalCalls = 0

    for relative in Self.capturePathFiles {
      let text = try String(
        contentsOf: root.appendingPathComponent(relative), encoding: .utf8)

      // Split on the call so each fragment after the first is one call's
      // argument list. Checking the whole FILE for the promotion would pass a
      // file where one of two sinks has it and the other does not — which is
      // exactly the bug in `KernelLifecycleTelemetrySink`, whose two sinks sit
      // four lines apart.
      let fragments = text.components(separatedBy: "SentryBreadcrumb.captureError(")
      guard fragments.count > 1 else {
        offenders.append("\(relative): no captureError call found — did the file move?")
        continue
      }
      for fragment in fragments.dropFirst() {
        totalCalls += 1
        // The argument list ends at the first line that closes it. Bounded
        // window rather than the whole tail, so a LATER call's promotion cannot
        // satisfy an earlier call that lacks one.
        let window = String(fragment.prefix(400))
        if !window.contains("SentryAudioExtras.promotedTags(from:") {
          offenders.append(relative)
        }
      }
    }

    // Positive control: a scan that found nothing to check would pass vacuously.
    #expect(
      totalCalls >= 4,
      """
      expected at least 4 capture-path captureError calls, found \(totalCalls) — \
      the scan is not reaching the sinks it claims to cover
      """)

    #expect(
      offenders.isEmpty,
      """
      These capture-path `SentryBreadcrumb.captureError` calls do not pass \
      `tags: SentryAudioExtras.promotedTags(from: extra)`, so the events they \
      emit reach Sentry with `capture.effective_transport` and \
      `capture.failure_mode` only as `extra` — ungroupable, and invisible to \
      every per-transport query (#2021, #1810): \(offenders.joined(separator: ", "))
      """)
  }
}
