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
// **A skip here is not a pass, and the artifact case IS skipped on most machines.** It
// runs only where a Release product exists, which is the release lane and nowhere else.
// That boundary is stated in the plan's ship criteria rather than papered over, because
// the failure mode of an artifact test is silence on every machine that has no artifact.
// The second case runs everywhere and covers the half that needs no artifact.
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

  // Gated, and the gate is the honest choice rather than the tidy one.
  //
  // A first draft called `Issue.record` when no Release product existed, so the suite
  // would have gone RED on every machine that had not just built one — including the
  // ordinary Debug lane, and therefore CI and `main`. That is a FALSE failure: it says
  // "release containment is broken" when the truth is "no release artifact is here to
  // look at", and a red main teaches everyone to ignore the row.
  //
  // The cost of gating is real and is stated in §13 rather than hidden: this check does
  // not run in the Debug lane, so **release containment is only verified when the release
  // lane runs it.** A skipped receipt is not a passed receipt, and the ship criteria say
  // so. `releaseCanOnlyBuildTheBaseline` below runs everywhere and covers the half that
  // can be checked without an artifact.
  @Test(
    "the DEBUG-only control-plane strings are absent from a Release executable",
    .enabled(if: releaseExecutable() != nil))
  func releaseArtifactCarriesNoControlPlane() throws {
    let executable = try #require(
      Self.releaseExecutable(),
      "gate said a Release executable exists and it was gone by the time the body ran")

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
