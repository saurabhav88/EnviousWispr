import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// Every health reason the app PRODUCES must have copy written for it.
///
/// The status card ends its reason switch with a `default` that says
/// "Something needs attention. Try the refresh button." That branch is correct
/// for a reason invented at runtime and wrong for every real one — it turns an
/// ordinary momentary state into what reads as a fault.
///
/// Two produced reasons had fallen into it. `not_started` is what EG-1 looks
/// like for a second after you select it, and the founder hit exactly that on
/// 2026-09-04: switching back to EG-1 showed "Something needs attention" until
/// he pressed refresh.
///
/// **This enumerates from the PRODUCING CODE, not from the reasons anyone
/// remembered.** The reason is a `String` inside `EGOneHealth`, so the compiler
/// cannot make this exhaustive; scanning the sources for what is actually
/// emitted is the closest thing to exhaustiveness available, and unlike a
/// hand-kept list it cannot silently fall behind.
///
/// **What the scan cannot see, stated rather than implied:** the failed-install
/// path emits `.red(reason: failure.rawValue)`, which is computed, so no regex
/// over the sources reaches it. Those states render through `failureCopy`
/// rather than this switch, so they are covered elsewhere — but a future
/// computed reason routed HERE would pass this suite while rendering the
/// generic line. The scan covers literals only.
@Suite("Health copy covers every reason the app emits (#2649)", .tags(.driftGuard))
struct LocalEngineHealthCopyTests {

  private static let fallback = "Something needs attention. Try the refresh button."

  /// Scan `Sources/` for every literal `.yellow(reason: "...")` / `.red(...)`.
  private static func producedReasons() throws -> (yellow: Set<String>, red: Set<String>) {
    let root = ParakeetShippedManifestTests.repoRoot.appendingPathComponent("Sources")
    var yellow: Set<String> = []
    var red: Set<String> = []
    let pattern = try NSRegularExpression(
      pattern: #"\.(yellow|red)\(reason: "([a-z_]+)"\)"#)

    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      let range = NSRange(text.startIndex..., in: text)
      for match in pattern.matches(in: text, range: range) {
        guard let kind = Range(match.range(at: 1), in: text),
          let reason = Range(match.range(at: 2), in: text)
        else { continue }
        if text[kind] == "yellow" {
          yellow.insert(String(text[reason]))
        } else {
          red.insert(String(text[reason]))
        }
      }
    }
    return (yellow, red)
  }

  @Test("the scan finds reasons at all, so an empty result cannot pass")
  func theScanIsNotBlind() throws {
    let produced = try Self.producedReasons()
    #expect(
      produced.yellow.count >= 6, "found \(produced.yellow.count) yellow reasons; scan is blind")
    #expect(produced.red.count >= 2, "found \(produced.red.count) red reasons; scan is blind")
    // A known member, so a regex that matches nothing useful still fails here.
    #expect(produced.yellow.contains("starting"))
  }

  @Test("every yellow reason the app emits has copy of its own")
  func everyYellowReasonIsWrittenFor() throws {
    let produced = try Self.producedReasons()
    var defaulted: [String] = []
    for reason in produced.yellow.sorted() {
      let copy = LocalEngineStatusCard.detail(for: .yellow(reason: reason))
      // `downloading` and `verifying` deliberately render nothing: the progress
      // chrome above them already says what is happening.
      if reason == "downloading" || reason == "verifying" {
        #expect(copy == nil, "\(reason) should stay silent, the progress row speaks")
        continue
      }
      if copy == Self.fallback || copy == nil { defaulted.append(reason) }
    }
    #expect(
      defaulted.isEmpty,
      "these are emitted but have no copy, so they render as a fault: \(defaulted)")
  }

  @Test("every red reason the app emits has copy of its own")
  func everyRedReasonIsWrittenFor() throws {
    let produced = try Self.producedReasons()
    let redFallback = "Not running. Use the refresh button to try again."
    var defaulted: [String] = []
    for reason in produced.red.sorted() {
      let copy = LocalEngineStatusCard.detail(for: .red(reason: reason))
      if copy == redFallback || copy == nil { defaulted.append(reason) }
    }
    #expect(
      defaulted.isEmpty,
      "these are emitted but fall to the generic red line: \(defaulted)")
  }

  /// The two that were actually broken, named so a regression is unmistakable
  /// rather than arriving as a count.
  @Test("the reasons the founder hit say something true")
  func theRegressionReasonsAreHonest() {
    #expect(
      LocalEngineStatusCard.detail(for: .yellow(reason: "not_started"))
        == "Starting the model. This takes a few seconds.")
    #expect(
      LocalEngineStatusCard.detail(for: .yellow(reason: "download_paused"))
        == "Download paused. Resume anytime.")
  }

  /// And the fallback must still be reachable for a reason nobody wrote, or the
  /// rows above would pass against a function that returns one string always.
  @Test("an unknown reason still reaches the generic line")
  func theFallbackStillWorks() {
    #expect(
      LocalEngineStatusCard.detail(for: .yellow(reason: "invented_at_runtime")) == Self.fallback)
  }
}
