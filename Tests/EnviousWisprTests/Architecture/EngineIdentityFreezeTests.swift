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

  // MARK: PR-5 Rung 2A KernelFinalizationWiring takes the protocol type

  @Test(
    "KernelFinalizationWiring.init(adapter:) takes any ASREngineAdapter, not the concrete type"
  )
  func kernelFinalizationWiringInitTakesProtocolType() throws {
    let relative = "Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift"
    let source = try Self.readSource(relative)
    #expect(
      source.contains("any ASREngineAdapter"),
      """
      \(relative) must keep `any ASREngineAdapter` somewhere. Rung 2A retyped
      the wiring's init parameter onto the protocol existential. Re-narrowing
      to the concrete ParakeetEngineAdapter type would couple the wiring to
      a single engine and block Rung 3.
      """)
    let bannedLiteral = "ParakeetEngineAdapter"
    #expect(
      !source.contains(bannedLiteral),
      """
      \(relative) reintroduces the literal `\(bannedLiteral)`. The wiring's
      adapter parameter is `any ASREngineAdapter`; a type annotation, an
      `as? ParakeetEngineAdapter`, or an `as! ParakeetEngineAdapter` downcast
      would each re-couple the wiring to the concrete engine. Read through
      the protocol surface instead (epic §3.4, PR-5 Rung 2A).
      """)
  }

  // MARK: PR-5 Rung 2A no production caller for the optional adapter hooks

  @Test(
    "production code calls the three optional adapter hooks only at the allowlisted sites"
  )
  func noOptionalHookCallersInProduction() throws {
    // Allowlist (PR-5 Rung 2A plan §3a). Rung 2A is the passive-surface
    // rung: the kernel does NOT call any of these hooks yet. The protocol
    // declares + extension-defaults them, and the Parakeet conformer
    // overrides one (`cancelPendingUnload`). Any other production caller
    // means Rung 2B (or later) leaked into Rung 2A.
    let allowed: [String: Int] = [
      "Sources/EnviousWisprPipeline/ASREngineAdapter.swift": 6,  // 3 decls + 3 ext defaults
      "Sources/EnviousWisprPipeline/ParakeetEngineAdapter.swift": 1,  // override decl
    ]
    let pattern = #"\b(warmUpFromCache|cancelPendingUnload|observeSpeechSegments)\("#
    let regex = try NSRegularExpression(pattern: pattern)
    let sourcesRoot = Self.repoRoot().appending(path: "Sources")
    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var offenders: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let ns = source as NSString
      let range = NSRange(location: 0, length: ns.length)
      let count = regex.numberOfMatches(in: source, range: range)
      guard count > 0 else { continue }
      let relative = url.path.replacingOccurrences(
        of: Self.repoRoot().path + "/", with: "")
      let allowedCount = allowed[relative] ?? 0
      if count > allowedCount {
        offenders.append(
          "  \(relative): \(count) call site(s), allowlisted \(allowedCount)")
      }
    }
    #expect(
      offenders.isEmpty,
      """
      Unexpected production call site(s) for the optional adapter hooks
      (PR-5 Rung 2A is the passive-surface rung, no kernel callers):
      \(offenders.joined(separator: "\n"))
      If this is Rung 2B+ wiring, update the allowlist in this freeze test in
      the same PR.
      """)
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
