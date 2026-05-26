import Foundation
import Testing

// MARK: - EngineIdentityFreezeTests (epic #827, PR-5 Rung 1)
//
// Source-level guard that the four kernel-side production sites never
// reintroduce a `.parakeet` engine-identity literal and (where they own an
// adapter reference) continue to read identity via `adapter.engineIdentity`.
// The runtime sentinel in `EngineIdentityPropagationTests` covers the
// natural-flow plumbing; this freeze test catches a future refactor that
// accidentally hard-codes the first engine again at the source level — a
// `.parakeet` literal compiles fine and would pass type-checking.

@Suite struct EngineIdentityFreezeTests {

  /// Matches the `.parakeet` enum-case literal (leading dot, identifier
  /// boundary trailing). Does NOT match `Parakeet` (capitalized engine name)
  /// nor `ParakeetEngineAdapter` (the concrete type name).
  private static let bannedIdentityLiteral = #"\.parakeet\b"#

  /// Sites that must read identity from the adapter and must not carry the
  /// banned literal.
  private static let identityReaderSites = [
    "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift",
    "Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift",
    "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift",
  ]

  /// The observer file no longer holds an emitter default — it must never
  /// reintroduce the `.parakeet` literal that previously seeded the default
  /// emitter; callers pass an explicit emitter constructed from
  /// `adapter.engineIdentity.backendType`.
  private static let identityFreeSites = [
    "Sources/EnviousWisprPipeline/KernelHeartPathTelemetryObserver.swift"
  ]

  // MARK: Positive — production sites are clean

  @Test("identity-reader sites contain at least one adapter.engineIdentity read")
  func readerSitesUseAdapterIdentity() throws {
    for relative in Self.identityReaderSites {
      let source = try Self.readSource(relative)
      #expect(
        source.contains("adapter.engineIdentity"),
        "\(relative) must read identity from `adapter.engineIdentity`")
    }
  }

  @Test("identity-reader sites carry no `.parakeet` literal")
  func readerSitesHaveNoLiteral() throws {
    for relative in Self.identityReaderSites {
      let violations = try Self.scanForLiteral(relative)
      #expect(
        violations.isEmpty,
        """
        \(relative) reintroduces `.parakeet` literal:
        \(violations.joined(separator: "\n"))
        Read identity from `adapter.engineIdentity` instead (epic §3.4, PR-5 Rung 1).
        """)
    }
  }

  @Test("identity-free sites carry no `.parakeet` literal")
  func freeSitesHaveNoLiteral() throws {
    for relative in Self.identityFreeSites {
      let violations = try Self.scanForLiteral(relative)
      #expect(
        violations.isEmpty,
        """
        \(relative) reintroduces `.parakeet` literal:
        \(violations.joined(separator: "\n"))
        This file must not declare a hard-coded engine-identity default
        (PR-5 Rung 1 — emitter is caller-supplied).
        """)
    }
  }

  // MARK: Adversarial — the scanner flags a regression

  @Test("a source line with `.parakeet` is flagged")
  func adversarialRegressionFlagged() {
    let source = """
      let snapshot = KernelRecordingSnapshotTelemetry(
        backend: ASRBackendType.parakeet.rawValue,
        audioRoute: route, wasStreaming: false,
        startTime: Date(), durationMs: 0,
        targetAppBundleID: nil)
      """
    let regex = try? NSRegularExpression(pattern: Self.bannedIdentityLiteral)
    var matches: [String] = []
    for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let text = String(line)
      let ns = text as NSString
      let range = NSRange(location: 0, length: ns.length)
      if regex?.firstMatch(in: text, range: range) != nil {
        matches.append("line \(idx + 1)")
      }
    }
    #expect(!matches.isEmpty, "`.parakeet` literal must be flagged by the scanner")
  }

  // MARK: Negative control — `Parakeet` engine-name references are not flagged

  @Test("`Parakeet`, `ParakeetEngineAdapter`, and `Parakeet v3` strings are not flagged")
  func negativeControlEngineNamePasses() {
    let source = """
      // 4. Parakeet adapter.
      let adapter = ParakeetEngineAdapter(asrManager: inputs.asrManager)
      // Display name "Parakeet v3" sourced from adapter.engineIdentity.displayName.
      """
    let regex = try? NSRegularExpression(pattern: Self.bannedIdentityLiteral)
    var matches: [String] = []
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      let ns = text as NSString
      let range = NSRange(location: 0, length: ns.length)
      if regex?.firstMatch(in: text, range: range) != nil {
        matches.append(text)
      }
    }
    #expect(matches.isEmpty, "capitalized `Parakeet` engine-name references must NOT be flagged")
  }

  // MARK: Helpers

  private static func readSource(_ relative: String) throws -> String {
    let url = repoRoot().appending(path: relative)
    return try String(contentsOf: url, encoding: .utf8)
  }

  private static func scanForLiteral(_ relative: String) throws -> [String] {
    let source = try readSource(relative)
    guard let regex = try? NSRegularExpression(pattern: bannedIdentityLiteral) else { return [] }
    var violations: [String] = []
    for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let text = String(line)
      let ns = text as NSString
      let range = NSRange(location: 0, length: ns.length)
      if regex.firstMatch(in: text, range: range) != nil {
        violations.append("  line \(idx + 1): \(text.trimmingCharacters(in: .whitespaces))")
      }
    }
    return violations
  }

  /// Repo root, anchored off `#filePath` — this file lives at
  /// `Tests/EnviousWisprTests/Architecture/`, four levels below the root.
  private static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
