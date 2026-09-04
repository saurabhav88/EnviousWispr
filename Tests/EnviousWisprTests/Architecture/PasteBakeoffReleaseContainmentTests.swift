import Foundation
import Testing

@testable import EnviousWisprPipeline

// The bake-off control plane must not exist in a shipped build (#2652).
//
// Everything else about the seam is a promise made in Swift: `#if DEBUG` around the
// non-baseline cases, a literal baseline at the one production construction site, a
// validating initializer. Those are the right mechanisms and they are all invisible in
// the artifact a user actually downloads.
//
// This suite asks the artifact instead. It is deliberately a STRING search rather than a
// behavioural test, because the question is not "does the release build route correctly"
// — a behavioural test would pass just as happily against a binary that carried the
// whole control plane and merely defaulted it off.
//
// **A skip here is not a pass.** Every case reports what it could not check, loudly,
// because the failure mode of an artifact test is silence on the machine that has no
// artifact — which is every machine except the one that just built one.
@Suite("Paste bake-off release containment (#2652)", .tags(.productOutcome))
struct PasteBakeoffReleaseContainmentTests {

  /// Strings that must never appear in a shipped executable.
  ///
  /// Two families, and both are needed. The environment keys are how a control plane
  /// would be *reached*; the writer raw values are how it would be *spelled*. A binary
  /// carrying either has the seam in it whatever its routing does at runtime.
  static let forbidden: [String] = [
    "EW_PASTE_BAKEOFF_VARIANT",
    "EW_PASTE_BAKEOFF_RUN_ID",
    "PASTE_BAKEOFF_CONTROL",
    "PASTE_BAKEOFF_TRIAL",
    "webCmdV",
    "axOneWriter",
  ]

  /// Candidate release products, newest first. Returns nil when none was built.
  static func releaseExecutable() -> URL? {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Architecture
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // checkout
    let candidates = [
      ".derivedData/Test/Build/Products/Release/EnviousWispr.app/Contents/MacOS/EnviousWispr",
      ".derivedData/Build/Products/Release/EnviousWispr.app/Contents/MacOS/EnviousWispr",
      "build/Release/EnviousWispr.app/Contents/MacOS/EnviousWispr",
    ]
    for relative in candidates {
      let url = root.appendingPathComponent(relative)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  @Test("the DEBUG-only control-plane strings are absent from a Release executable")
  func releaseArtifactCarriesNoControlPlane() throws {
    guard let executable = Self.releaseExecutable() else {
      // Loud, and deliberately not an `.enabled(if:)` gate: a disabled test reports
      // nothing at all, and this receipt is worth more than a tidy test list. The
      // release lane builds the product this needs.
      Issue.record(
        """
        SKIPPED, NOT PASSED: no Release executable found in this checkout, so release \
        containment for #2652 is UNVERIFIED here. Build the release lane \
        (`scripts/xcode-test.sh --release`) and re-run. This is a receipt that the check \
        did not happen, not evidence that it succeeded.
        """)
      return
    }

    let data = try Data(contentsOf: executable)
    // Search the raw bytes rather than a decoded string: Swift string literals land in
    // the binary as UTF-8 inside a __cstring section, and decoding a Mach-O as text
    // would silently drop most of it.
    for needle in Self.forbidden {
      let pattern = Array(needle.utf8)
      #expect(
        !data.contains(pattern),
        """
        \(executable.lastPathComponent) contains "\(needle)". The bake-off control plane \
        reached a shipped artifact. Every non-baseline policy and both environment keys \
        must be inside `#if DEBUG`.
        """)
    }
  }

  @Test("the baseline is the only policy a Release build can construct")
  func releaseCanOnlyBuildTheBaseline() {
    // Compile-time half of the same claim, and the reason it earns a row beside the
    // artifact scan: this one runs everywhere, including CI on a Debug lane, so a
    // regression is caught long before anyone builds a release.
    #expect(PasteDeliveryPolicy.baseline.id == "V0")
    #expect(PasteDeliveryPolicy.baseline.writer == .current)
    #expect(!PasteDeliveryPolicy.baseline.boundTier1MessagingTimeout)
    #expect(PasteDeliveryPolicy.baseline.isBaseline)
  }
}

extension Data {
  /// Whether these bytes contain the given byte sequence.
  fileprivate func contains(_ pattern: [UInt8]) -> Bool {
    guard !pattern.isEmpty, count >= pattern.count else { return false }
    return withUnsafeBytes { raw -> Bool in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
      let limit = count - pattern.count
      var index = 0
      while index <= limit {
        if base[index] == pattern[0] {
          var matched = true
          for offset in 1..<pattern.count where base[index + offset] != pattern[offset] {
            matched = false
            break
          }
          if matched { return true }
        }
        index += 1
      }
      return false
    }
  }
}
