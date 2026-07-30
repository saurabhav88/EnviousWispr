import EnviousWisprObservabilityCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1846 — the cross-vendor join key's acceptance contract, its survival through
/// the REAL final-payload redactor, and the freeze that keeps PostHog's
/// `distinct_id` anonymous.
@Suite("Telemetry join key (#1846)")
struct TelemetryJoinKeyTests {

  /// A canonical PostHog anonymous ID: lowercase, hyphenated, 8-4-4-4-12.
  private static let canonicalID = "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

  // MARK: - Acceptance predicate

  @Test(
    "a canonical lowercase hyphenated UUID is accepted byte-for-byte unchanged",
    arguments: [
      "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
      "00000000-0000-0000-0000-000000000000",
      "ffffffff-ffff-ffff-ffff-ffffffffffff",
      // UPPERCASE IS REAL, AND IT IS 13.6% OF THE FLEET. The SDK lowercases ids
      // it MINTS, but `PostHogStorageManager.getAnonymousId()` returns a
      // PERSISTED id unchanged, so an install whose id predates that lowercasing
      // keeps its spelling forever. Measured against production 2026-07-30:
      // 94 of 692 distinct installs carry an uppercase id, including this
      // machine's dev install. Rejecting them dropped 13.6% of the join into a
      // blind spot indistinguishable from "PostHog was skipped".
      "0198A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B",
      "019E2DB1-63F5-7776-A7E4-9ACD568A81F5",
    ])
  func acceptsCanonicalAnonymousID(raw: String) {
    // Returned VERBATIM, never normalized: the tag has to equal the string
    // PostHog actually stores, so lowercasing an uppercase id would leave the
    // join just as broken and much harder to see.
    #expect(ObservabilityBootstrap.canonicalAnonymousPostHogID(raw) == raw)
  }

  /// Each rejection is a distinct reason, not one class:
  /// - compact 32-hex would arrive as `[REDACTED]` (see the two-way control below);
  /// - MIXED case is not a spelling PostHog ever produces: it mints lowercase and
  ///   persists whatever it stored, so only the two canonical spellings are real.
  ///   `UUID(uuidString:)` accepts mixed case, which is why the predicate demands
  ///   exact equality with one of those two;
  /// - email-shaped and arbitrary values are the shapes a future `identify()`
  ///   could introduce, and copying a caller-supplied string into Sentry is not
  ///   a decision the bootstrap seam may make silently;
  /// - empty is what `getDistinctId()` returns when PostHog init was skipped for
  ///   a missing key, and it must set no tag rather than an empty tag.
  @Test(
    "every non-canonical or unsafe shape is rejected",
    arguments: [
      "0198a1b2c3d47e5f8a9b0c1d2e3f4a5b",
      "0198A1B2-c3d4-7E5F-8a9b-0C1D2E3F4A5B",
      "someone@example.com",
      "install-1846",
      "",
    ])
  func rejectsEveryOtherShape(raw: String) {
    #expect(ObservabilityBootstrap.canonicalAnonymousPostHogID(raw) == nil)
  }

  // MARK: - Redaction tripwire

  /// Two-way control against the REAL production redactor, not a restatement of
  /// its rule. The 32+-contiguous-hex heuristic destroys a compact UUID; a
  /// hyphenated one's longest hex run is 12, so it survives. If either direction
  /// flips, the join key silently becomes `[REDACTED]` on every event and the
  /// arithmetic in the plan's §2.5 premise table is no longer true.
  @Test("two-way redactor control: the hyphenated join key survives, its compact form does not")
  func joinKeySurvivesTheRealRedactor() throws {
    let accepted = try #require(
      ObservabilityBootstrap.canonicalAnonymousPostHogID(Self.canonicalID))
    let compact = Self.canonicalID.replacingOccurrences(of: "-", with: "")

    #expect(SentryEventSanitizer.redactString(accepted) == accepted)
    #expect(SentryEventSanitizer.redactString(compact) == "[REDACTED]")
  }

  // MARK: - Anonymity freeze

  /// The join key is only safe to copy into Sentry while PostHog's
  /// `distinct_id` stays the SDK's own anonymous UUID, which holds only because
  /// no production code calls `identify()` or `alias()`. This scan is the
  /// enforcement; `canonicalAnonymousPostHogID(_:)` is the second line.
  ///
  /// Anchored to `PostHogSDK.shared` on purpose: unrelated production functions
  /// named `identify` exist and are valid (`TerminalProcessScanner.swift`), so an
  /// unanchored matcher would false-positive on ordinary code.
  @Test("no production code calls PostHog identify or alias")
  func postHogIdentityIsFrozen() throws {
    let scan = try Self.scan(at: RepoRoot.sourceURL("Sources"))

    // Reached-the-tree control: a scan that read nothing reports "clean" for the
    // wrong reason. `PostHogSDK.shared.capture(` exists in the emitter today, so
    // zero control hits means the walk or the read, not the codebase, changed.
    // The forbidden pattern's OWN two-way proof is the fixture tests below —
    // `capture` and `(identify|alias)` are different regexes, so a hit on one
    // does not prove the other can match.
    #expect(
      scan.swiftFileCount > 100,
      "scanned only \(scan.swiftFileCount) Swift files — the scan did not reach the source tree")
    #expect(
      scan.controlHitCount > 0,
      "the matcher found no `PostHogSDK.shared.capture(` call, so a negative result proves nothing")

    #expect(
      scan.offenders.isEmpty,
      """
      PostHog identity is no longer anonymous — `analytics.distinct_id` may now \
      carry a caller-supplied value into Sentry:
      \(scan.offenders.joined(separator: "\n"))
      """)
  }

  /// The freeze test's green must mean "no offender exists", never "the matcher
  /// cannot see one". Drives the REAL scanner over a throwaway tree containing
  /// each forbidden form, including whitespace and a line break before `(`.
  @Test(
    "the freeze scanner actually catches a forbidden call",
    arguments: [
      "PostHogSDK.shared.identify(\"someone@example.com\")",
      "PostHogSDK.shared.alias(\"legacy-id\")",
      "PostHogSDK.shared.identify (\"spaced\")",
      "    PostHogSDK.shared.identify(distinctId)",
      "PostHogSDK.shared.identify\n      (\"multiline\")",
    ])
  func freezeScannerCatchesOffenders(offendingLine: String) throws {
    let scan = try Self.scanFixture(containing: offendingLine)
    #expect(scan.offenders.count == 1, "expected exactly one offender, got \(scan.offenders)")
  }

  /// Precision half. An unanchored `identify(` matcher would flag ordinary
  /// production code — `TerminalProcessScanner` has a legitimate `identify`
  /// function — and a gate that false-fires gets worked around rather than read.
  @Test(
    "the freeze scanner does not flag an unrelated identify or a different SDK",
    arguments: [
      "let role = identify(process: pid)",
      "scanner.identify(window)",
      "SomeOtherSDK.shared.identify(\"x\")",
      "PostHogSDK.shared.capture(\"dictation.completed\")",
    ])
  func freezeScannerIgnoresInnocentLines(innocentLine: String) throws {
    let scan = try Self.scanFixture(containing: innocentLine)
    #expect(scan.offenders.isEmpty, "false positive on `\(innocentLine)`: \(scan.offenders)")
  }

  // MARK: - Scan support

  private struct ScanResult {
    var swiftFileCount = 0
    var controlHitCount = 0
    var offenders: [String] = []
  }

  private struct ScanFailedError: Error, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "join-key freeze scan failed at \(path): \(reason)" }
  }

  /// Writes `line` into a throwaway Swift file and runs the REAL scanner over
  /// it, so the fixture exercises the production discovery, read and match path
  /// rather than a parallel simpler stand-in.
  private static func scanFixture(containing line: String) throws -> ScanResult {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "ew-1846-freeze-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "import PostHog\n\nfunc probe() {\n\(line)\n}\n"
      .write(to: root.appending(path: "Probe.swift"), atomically: true, encoding: .utf8)
    return try scan(at: root)
  }

  /// Fails CLOSED: a nil enumerator, a deferred enumeration error, or an
  /// unreadable file throws rather than falling through as zero offenders.
  private static func scan(at rootURL: URL) throws -> ScanResult {
    let relativePrefix = RepoRoot.url.path + "/"
    var result = ScanResult()
    var enumerationError: Error?

    // A trailing closure directly in a `guard` condition is a known Swift parser
    // ambiguity — passed as an explicit `errorHandler:` argument instead.
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw ScanFailedError(path: rootURL.path, reason: "could not create a directory enumerator")
    }

    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      result.swiftFileCount += 1
      let source: String
      do {
        source = try String(contentsOf: url, encoding: .utf8)
      } catch {
        throw ScanFailedError(path: url.path, reason: "could not be read: \(error)")
      }
      var relativePath = url.path
      if relativePath.hasPrefix(relativePrefix) {
        relativePath.removeFirst(relativePrefix.count)
      }
      // Matched against the WHOLE source, not line by line: `\s` spans newlines,
      // so a call reformatted with the paren on the next line cannot slip past.
      for matchStart in Self.matchStarts(of: Self.forbiddenCallPattern, in: source) {
        result.offenders.append("\(relativePath):\(Self.line(at: matchStart, in: source))")
      }
      result.controlHitCount += Self.matchStarts(of: Self.controlCallPattern, in: source).count
    }

    if let enumerationError {
      throw ScanFailedError(
        path: rootURL.path, reason: "directory enumeration failed: \(enumerationError)")
    }
    return result
  }

  /// EVERY match, not just the first: a file with two offenders must report both,
  /// or fixing one hides the other until the next run.
  private static func matchStarts(of pattern: String, in source: String) -> [String.Index] {
    var starts: [String.Index] = []
    var searchFrom = source.startIndex
    while searchFrom < source.endIndex,
      let match = source.range(
        of: pattern, options: .regularExpression, range: searchFrom..<source.endIndex)
    {
      starts.append(match.lowerBound)
      // A zero-width match would not advance; this pattern cannot produce one
      // (it ends in a literal `(`), but guard the loop rather than assume.
      searchFrom =
        match.upperBound > match.lowerBound
        ? match.upperBound : source.index(after: match.lowerBound)
    }
    return starts
  }

  private static func line(at index: String.Index, in source: String) -> Int {
    source[source.startIndex..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
  }

  /// `\s*`, not `[ \t]*`: all whitespace INCLUDING a newline, so a multiline
  /// reformatted call cannot slip past. Anchored to `PostHogSDK.shared` so an
  /// unrelated production `identify` is not flagged.
  private static let forbiddenCallPattern = #"PostHogSDK\.shared\.(identify|alias)\s*\("#
  private static let controlCallPattern = #"PostHogSDK\.shared\.capture\s*\("#
}
