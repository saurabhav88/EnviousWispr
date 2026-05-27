import Foundation
import Testing

// MARK: - EngineIdentityFreezeTests (epic #827, PR-5 Rung 1 + Rung 3)
//
// Source-level guard that the kernel-side production sites never reintroduce
// a hard-coded engine-identity literal and (where they own an adapter
// reference) continue to read identity via `adapter.engineIdentity`. The
// runtime sentinel in `EngineIdentityPropagationTests` covers the
// natural-flow plumbing; this freeze test catches a future refactor that
// accidentally hard-codes an engine again at the source level — a `.parakeet`
// or `.whisperKit` literal compiles fine and would pass type-checking.
//
// Rung 3 (#827) extended the scan: both engine literals are banned at every
// reader site, and `KernelLifecycleTelemetrySink` is added to the reader-site
// list (it became an identity reader once Rung 2A wired it through
// `adapter.engineIdentity`).

@Suite struct EngineIdentityFreezeTests {

  /// Matches the `.parakeet` enum-case literal (leading dot, identifier
  /// boundary trailing). Does NOT match `Parakeet` (capitalized engine name)
  /// nor `ParakeetEngineAdapter` (the concrete type name).
  private static let bannedParakeetLiteral = #"\.parakeet\b"#

  /// Matches the `.whisperKit` enum-case literal. Does NOT match
  /// `WhisperKit` (capitalized engine name) nor `WhisperKitEngineAdapter` /
  /// `WhisperKitBackend` type names.
  private static let bannedWhisperKitLiteral = #"\.whisperKit\b"#

  /// All banned engine-identity literals — both must be absent at every
  /// reader site (epic §3.4, PR-5 Rung 1 + Rung 3).
  private static let bannedIdentityLiterals: [(name: String, pattern: String)] = [
    ("parakeet", bannedParakeetLiteral),
    ("whisperKit", bannedWhisperKitLiteral),
  ]

  /// Sites that must read identity from the adapter and must not carry any
  /// banned literal. PR-5 Rung 3 widened the literal scan from `.parakeet`
  /// only to `.parakeet` AND `.whisperKit` — both engines are now banned at
  /// every reader site (epic §3.4: kernel never branches on engine identity).
  ///
  /// `KernelLifecycleTelemetrySink` is intentionally NOT in this list: it
  /// receives `backend: ASRBackendType` via init (factory-sourced from
  /// `adapter.engineIdentity.backendType`), so it doesn't reference
  /// `adapter.engineIdentity` directly. It also carries one legitimate
  /// `backend == .whisperKit` routing-policy switch at
  /// `KernelLifecycleTelemetrySink.swift:399` (only emits the backend tag
  /// in capture-failure extras for WhisperKit). That switch is pre-Rung-3
  /// behavior unrelated to the kernel-side identity-reader contract this
  /// freeze test guards; ideally it migrates to a capability flag, but
  /// that's a separate refactor (epic backlog).
  private static let identityReaderSites = [
    "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift",
    "Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift",
    "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift",
  ]

  /// The observer file no longer holds an emitter default — it must never
  /// reintroduce an engine-identity literal that previously seeded the
  /// default emitter; callers pass an explicit emitter constructed from
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

  @Test("identity-reader sites carry no banned engine-identity literal")
  func readerSitesHaveNoLiteral() throws {
    for relative in Self.identityReaderSites {
      for banned in Self.bannedIdentityLiterals {
        let violations = try Self.scanForLiteral(relative, pattern: banned.pattern)
        #expect(
          violations.isEmpty,
          """
          \(relative) reintroduces `.\(banned.name)` literal:
          \(violations.joined(separator: "\n"))
          Read identity from `adapter.engineIdentity` instead (epic §3.4,
          PR-5 Rung 1 + Rung 3).
          """)
      }
    }
  }

  @Test("identity-free sites carry no banned engine-identity literal")
  func freeSitesHaveNoLiteral() throws {
    for relative in Self.identityFreeSites {
      for banned in Self.bannedIdentityLiterals {
        let violations = try Self.scanForLiteral(relative, pattern: banned.pattern)
        #expect(
          violations.isEmpty,
          """
          \(relative) reintroduces `.\(banned.name)` literal:
          \(violations.joined(separator: "\n"))
          This file must not declare a hard-coded engine-identity default
          (PR-5 Rung 1 — emitter is caller-supplied).
          """)
      }
    }
  }

  // MARK: Adversarial — the scanner flags a regression

  @Test("a source line with `.parakeet` is flagged")
  func adversarialParakeetRegressionFlagged() {
    let source = """
      let snapshot = KernelRecordingSnapshotTelemetry(
        backend: ASRBackendType.parakeet.rawValue,
        audioRoute: route, wasStreaming: false)
      """
    #expect(
      Self.regexFlags(source: source, pattern: Self.bannedParakeetLiteral),
      "`.parakeet` literal must be flagged by the scanner")
  }

  @Test("a source line with `.whisperKit` is flagged (PR-5 Rung 3 adversarial mirror)")
  func adversarialWhisperKitRegressionFlagged() {
    let source = """
      let snapshot = KernelRecordingSnapshotTelemetry(
        backend: ASRBackendType.whisperKit.rawValue,
        audioRoute: route, wasStreaming: false)
      """
    #expect(
      Self.regexFlags(source: source, pattern: Self.bannedWhisperKitLiteral),
      "`.whisperKit` literal must be flagged by the scanner")
  }

  // MARK: Negative controls — capitalized engine-name references are not flagged

  @Test("`Parakeet`, `ParakeetEngineAdapter`, and `Parakeet v3` strings are not flagged")
  func negativeControlParakeetEngineNamePasses() {
    let source = """
      // 4. Parakeet adapter.
      let adapter = ParakeetEngineAdapter(asrManager: inputs.asrManager)
      // Display name "Parakeet v3" sourced from adapter.engineIdentity.displayName.
      """
    #expect(
      Self.regexFlags(source: source, pattern: Self.bannedParakeetLiteral) == false,
      "capitalized `Parakeet` engine-name references must NOT be flagged")
  }

  @Test(
    "`WhisperKit`, `WhisperKitEngineAdapter`, and `WhisperKitBackend` strings are not flagged (PR-5 Rung 3 negative control)"
  )
  func negativeControlWhisperKitEngineNamePasses() {
    let source = """
      // 5. WhisperKit adapter.
      let adapter = WhisperKitEngineAdapter(backend: inputs.whisperKitBackend)
      // The WhisperKit display name is sourced from adapter.engineIdentity.displayName.
      // WhisperKitBackend lives in EnviousWisprASR; reach via the package seam.
      """
    #expect(
      Self.regexFlags(source: source, pattern: Self.bannedWhisperKitLiteral) == false,
      "capitalized `WhisperKit` engine-name references must NOT be flagged")
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
      source.contains(bannedLiteral) == false,
      """
      \(relative) reintroduces the literal `\(bannedLiteral)`. The wiring's
      adapter parameter is `any ASREngineAdapter`; a type annotation, an
      `as? ParakeetEngineAdapter`, or an `as! ParakeetEngineAdapter` downcast
      would each re-couple the wiring to the concrete engine. Read through
      the protocol surface instead (epic §3.4, PR-5 Rung 2A).
      """)
  }

  // MARK: PR-5 Rung 2B optional adapter hook callers match allowlist

  @Test(
    "production code calls the three optional adapter hooks only at the allowlisted sites"
  )
  func optionalAdapterHookCallersMatchAllowlist() throws {
    let hooks = ["warmUpFromCache", "cancelPendingUnload", "observeSpeechSegments"]
    let allowed: [String: [String: Int]] = [
      "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift": [
        "warmUpFromCache": 1,
        "cancelPendingUnload": 1,
        "observeSpeechSegments": 1,
      ]
    ]
    let regexes: [String: NSRegularExpression] = try hooks.reduce(into: [:]) {
      acc, hook in
      acc[hook] = try NSRegularExpression(pattern: #"\badapter\."# + hook + #"\("#)
    }
    let sourcesRoot = Self.repoRoot().appending(path: "Sources")
    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var offenders: [String] = []
    var visited: Set<String> = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let ns = source as NSString
      let range = NSRange(location: 0, length: ns.length)
      let relative = url.path.replacingOccurrences(
        of: Self.repoRoot().path + "/", with: "")
      visited.insert(relative)
      let allowedPerHook = allowed[relative] ?? [:]
      for hook in hooks {
        let count = regexes[hook]!.numberOfMatches(in: source, range: range)
        let allowedCount = allowedPerHook[hook] ?? 0
        if count != allowedCount {
          let kind = count > allowedCount ? "unexpected addition" : "missing expected call"
          offenders.append(
            "  \(relative) adapter.\(hook): \(count) call site(s), allowlisted \(allowedCount) — \(kind)"
          )
        }
      }
    }
    for (relative, perHook) in allowed where !visited.contains(relative) {
      for (hook, allowedCount) in perHook {
        offenders.append(
          "  \(relative) adapter.\(hook): 0 call site(s), allowlisted \(allowedCount) — missing expected file"
        )
      }
    }
    #expect(
      offenders.isEmpty,
      """
      Optional adapter hook call site count drift (PR-5 Rung 2B #827 wires
      four kernel call sites at fixed lifecycle positions, counted per hook):
      \(offenders.joined(separator: "\n"))
      Adding or removing a kernel call site requires updating the allowlist
      in this freeze test in the same PR.
      """)
  }

  // MARK: Helpers

  private static func readSource(_ relative: String) throws -> String {
    let url = repoRoot().appending(path: relative)
    return try String(contentsOf: url, encoding: .utf8)
  }

  private static func scanForLiteral(_ relative: String, pattern: String) throws -> [String] {
    let source = try readSource(relative)
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
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

  /// Returns true iff the regex matches any line in `source`. Used by the
  /// adversarial + negative-control tests so they share the scanner shape
  /// rather than duplicating the regex loop.
  private static func regexFlags(source: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      let ns = text as NSString
      let range = NSRange(location: 0, length: ns.length)
      if regex.firstMatch(in: text, range: range) != nil { return true }
    }
    return false
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
