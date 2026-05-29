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

  /// PR-5 Rung 4: the factory's engine-agnostic assembler reads
  /// `adapter.engineIdentity.backendType` at THREE sites (polish step stamp,
  /// `HeartPathTelemetryEmitter` construction, `KernelLifecycleTelemetrySink`
  /// construction). Council coverage review (GPT, 2026-05-27) asked that the
  /// WhisperKit factory branch verify identity propagates to every
  /// backend-stamped consumer; the polish stamp is directly readable at
  /// runtime, but emitter + sink stamps are inside private collaborators.
  /// This freeze enforces the per-consumer read count at source level —
  /// stronger than runtime inspection because it catches any future refactor
  /// that drops a consumer's identity read or routes one through a different
  /// source.
  @Test(
    "KernelDictationDriverFactory reads adapter.engineIdentity at least three times (one per consumer: polish, emitter, sink)"
  )
  func factoryReadsIdentityForEveryBackendStampedConsumer() throws {
    let relative = "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift"
    let source = try Self.readSource(relative)
    let needle = "adapter.engineIdentity"
    var count = 0
    var search = source[...]
    while let range = search.range(of: needle) {
      count += 1
      search = search[range.upperBound...]
    }
    #expect(
      count >= 3,
      """
      \(relative) reads `\(needle)` \(count) time(s) — expected ≥3.
      The assembler stamps the polish step, the heart-path telemetry emitter,
      and the lifecycle telemetry sink with `adapter.engineIdentity.backendType`.
      If a future refactor drops one of those stamps or routes it through a
      different identity source, downstream telemetry will mis-stamp the
      backend for the second-engine branch.
      """)
  }

  // MARK: PR-5 Rung 4 — factory surface + production-unwired invariant

  @Test("KernelDictationDriverFactory exposes both engine-construction methods")
  func factoryExposesBothEngineMethods() throws {
    let relative = "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift"
    let source = try Self.readSource(relative)
    // PR-5 Rung 5 (#827) narrowed factory methods from `public` to `package`.
    #expect(
      source.contains("package static func makeForParakeet("),
      """
      \(relative) must expose `makeForParakeet(inputs:)` at `package` access.
      The Parakeet engine branch is the live caller path; removing or renaming
      it silently would break the App's launch-time pipeline construction.
      """)
    #expect(
      source.contains("package static func makeForWhisperKit("),
      """
      \(relative) must expose `makeForWhisperKit(inputs:)` at `package` access.
      Rung 5 wired the App caller; removing it would break WhisperKit recording.
      """)
  }

  // PR-5 Rung 5 (#827) — `makeForWhisperKitHasNoProductionCaller` was deleted
  // in this PR; its invariant inverted at cutover. The replacements below lock
  // the post-cutover invariants (exactly one App caller; zero references to
  // the deleted `WhisperKitPipeline` type / `WhisperKitPipelineState` enum /
  // `whisperKitPipeline` variable name; VAD signal source single-constructed).

  @Test("WhisperKit factory branch has exactly one production caller")
  func makeForWhisperKitHasExactlyOneProductionCaller() throws {
    let sourcesRoot = Self.repoRoot().appending(path: "Sources")
    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var callers: [String] = []
    let regex = try NSRegularExpression(pattern: #"makeForWhisperKit\s*\("#)
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let relative = url.path.replacingOccurrences(
        of: Self.repoRoot().path + "/", with: "")
      // The factory's own definition site is not a caller.
      if relative == "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift" {
        continue
      }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let ns = source as NSString
      let range = NSRange(location: 0, length: ns.length)
      if regex.firstMatch(in: source, range: range) != nil {
        callers.append(relative)
      }
    }
    #expect(
      callers.count == 1,
      """
      Expected exactly one production caller of `makeForWhisperKit(inputs:)`;
      found \(callers.count) in \(callers).
      """)
    #expect(
      callers.first?.hasSuffix("EnviousWispr/App/EnviousWisprApp.swift") == true,
      """
      The sole production caller must be `EnviousWispr/App/EnviousWisprApp.swift`;
      found \(callers).
      """)
  }

  @Test("WhisperKitPipeline has no construction site in production")
  func whisperKitPipelineHasNoConstructionSite() throws {
    let offenders = try Self.scanSources(pattern: #"\bWhisperKitPipeline\s*\("#)
    #expect(
      offenders.isEmpty,
      """
      Found WhisperKitPipeline construction site(s) — the legacy class was
      deleted in PR-5 Rung 5 (#827). Use `KernelDictationDriverFactory
      .makeForWhisperKit(inputs:)` instead.
      \(offenders.joined(separator: "\n"))
      """)
  }

  @Test("WhisperKitPipeline does not appear in type positions")
  func whisperKitPipelineHasNoTypeAnnotations() throws {
    let offenders = try Self.scanSources(
      pattern: #":\s*WhisperKitPipeline\b|:\s*any\s+WhisperKitPipeline\b"#)
    #expect(
      offenders.isEmpty,
      """
      Found WhisperKitPipeline type annotation(s) — the legacy class was
      deleted in PR-5 Rung 5 (#827). Stored fields and parameters now type
      against `KernelDictationDriver`.
      \(offenders.joined(separator: "\n"))
      """)
  }

  @Test("whisperKitPipeline variable name is fully scrubbed from Sources/")
  func whisperKitPipelineVariableNameIsGone() throws {
    let offenders = try Self.scanSources(pattern: #"\bwhisperKitPipeline\b"#)
    #expect(
      offenders.isEmpty,
      """
      Found references to the `whisperKitPipeline` identifier — PR-5 Rung 5
      (#827) renamed every App-layer field and parameter to
      `whisperKitKernelDriver`.
      \(offenders.joined(separator: "\n"))
      """)
  }

  @Test("WhisperKitPipelineState enum is deleted; no refs remain")
  func whisperKitPipelineStateHasZeroRefs() throws {
    let offenders = try Self.scanSources(pattern: #"\bWhisperKitPipelineState\b"#)
    #expect(
      offenders.isEmpty,
      """
      Found references to the deleted `WhisperKitPipelineState` enum — PR-5
      Rung 5 (#827) collapsed both backends onto the shared `PipelineState`.
      \(offenders.joined(separator: "\n"))
      """)
  }

  @Test(
    "CaptureVADSignalSource is constructed exactly once at App init via makeSharedVADSignalSource"
  )
  func vadSignalSourceHasSingleConstructionSite() throws {
    let constructs = try Self.scanSources(pattern: #"CaptureVADSignalSource\s*\("#)
    #expect(
      constructs.count == 1,
      """
      Expected exactly one CaptureVADSignalSource construction site — the
      shared App-owned VAD source that both kernel drivers share (PR-5 Rung 5
      / Codex r2 new defect 1). Multiple construction sites would re-bind
      `audioCapture.onVADAutoStop` and break two-driver auto-stop dispatch.
      \(constructs.joined(separator: "\n"))
      """)
    #expect(
      constructs.first?.contains("KernelDictationDriverFactory.swift") == true,
      """
      The single construction site must live inside `makeSharedVADSignalSource`
      in `KernelDictationDriverFactory.swift`; found \(constructs).
      """)
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

  // MARK: PR-6 (#827): concrete adapter construction confined to KernelAdapterFactory

  /// The whole-word concrete adapter type names PR-6 confines.
  private static let concreteAdapterTypeNames = [
    "ParakeetEngineAdapter", "WhisperKitEngineAdapter",
  ]

  /// The one allowlisted construction home (epic #827, PR-6).
  private static let adapterConstructionOwner =
    "Sources/EnviousWisprPipeline/KernelAdapterFactory.swift"

  private static let driverAssemblyFactory =
    "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift"

  /// Test A. Every concrete adapter CONSTRUCTION CALL (`TypeName(`) in
  /// `Sources/` lives only in `KernelAdapterFactory.swift`. The construction-call
  /// pattern (`\bTypeName\s*\(`) is deliberately narrower than a whole-word type
  /// scan: it does NOT match the adapters' own `class`/`extension` declarations
  /// (followed by `:` or `{`, never `(`) nor the 10 `category: "WhisperKitEngineAdapter"`
  /// `AppLogger` string literals, which is exactly why a whole-word repo-wide ban
  /// would false-fail (Codex r4). `scanSources` skips comment-only lines, so the
  /// `// MARK: - …Adapter (` headers are not counted either.
  @Test("concrete adapter construction calls live only in KernelAdapterFactory (PR-6 #827)")
  func adapterConstructionConfinedToKernelAdapterFactory() throws {
    for name in Self.concreteAdapterTypeNames {
      let hits = try Self.scanSources(pattern: #"\b"# + name + #"\s*\("#)
      let offenders = hits.filter {
        !$0.hasPrefix(Self.adapterConstructionOwner + ":")
      }
      #expect(
        offenders.isEmpty,
        """
        Concrete adapter construction `\(name)(` found in `Sources/` code outside
        \(Self.adapterConstructionOwner):
        \(offenders.joined(separator: "\n"))
        PR-6 (#827) confines all concrete `ASREngineAdapter` construction to
        `KernelAdapterFactory`. Add a `make…Adapter` function there and call it.
        """)
    }
  }

  /// Test B. The driver-assembly factory names NO concrete adapter type in code
  /// (whole-word: catches construction, `: Type` annotations, `.init`-style refs).
  /// Scoped to this one file, where the post-PR-6 invariant is "zero concrete-type
  /// mentions in code"; `scanSources` skips comments so the file's doc-comment
  /// mentions (`:14-22`) stay legal under the code-only policy.
  @Test("KernelDictationDriverFactory names no concrete adapter type in code (PR-6 #827)")
  func driverFactoryNamesNoConcreteAdapterTypeInCode() throws {
    for name in Self.concreteAdapterTypeNames {
      let hits = try Self.scanSources(pattern: #"\b"# + name + #"\b"#)
        .filter { $0.hasPrefix(Self.driverAssemblyFactory + ":") }
      #expect(
        hits.isEmpty,
        """
        \(Self.driverAssemblyFactory) names concrete adapter type `\(name)` in code:
        \(hits.joined(separator: "\n"))
        Post-PR-6 (#827) the driver-assembly factory must name no concrete adapter
        type in code (comments are allowed). Route construction through
        `KernelAdapterFactory`.
        """)
    }
  }

  // MARK: PR-6 adversarial + negative controls

  @Test("the construction-call scanner flags an adapter constructed outside the factory (PR-6)")
  func adversarialAdapterConstructionFlagged() {
    let source = "    let adapter = WhisperKitEngineAdapter(backend: backend)"
    #expect(
      Self.regexFlags(source: source, pattern: #"\bWhisperKitEngineAdapter\s*\("#),
      "an adapter construction call must be flagged by the construction-call scanner")
  }

  @Test(
    "the construction-call scanner does NOT flag log strings, extensions, or class decls (PR-6)")
  func negativeControlNonConstructionReferencesNotFlagged() {
    let pattern = #"\bWhisperKitEngineAdapter\s*\("#
    let logString =
      #"      await AppLogger.shared.log(m, level: .info, category: "WhisperKitEngineAdapter")"#
    let extensionDecl = "extension WhisperKitEngineAdapter: ASREngineTelemetryProviding {}"
    let classDecl = "final class WhisperKitEngineAdapter: ASREngineAdapter {"
    #expect(
      Self.regexFlags(source: logString, pattern: pattern) == false,
      "a `category: \"WhisperKitEngineAdapter\"` log string must NOT be flagged")
    #expect(
      Self.regexFlags(source: extensionDecl, pattern: pattern) == false,
      "an `extension WhisperKitEngineAdapter` declaration must NOT be flagged")
    #expect(
      Self.regexFlags(source: classDecl, pattern: pattern) == false,
      "a `final class WhisperKitEngineAdapter` declaration must NOT be flagged")
  }

  // MARK: Helpers

  private static func readSource(_ relative: String) throws -> String {
    let url = repoRoot().appending(path: relative)
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// Recursive scan over every `Sources/**/*.swift` file. Returns
  /// `relative/path.swift:LINE_NUMBER: line-content` for every line whose
  /// regex matches. Used by the PR-5 Rung 5 freeze tests that lock the
  /// post-cutover invariants (no `WhisperKitPipeline`, no
  /// `WhisperKitPipelineState`, no `whisperKitPipeline`, single VAD source).
  ///
  /// Lines whose first non-whitespace characters are `//` or `///` are
  /// skipped — comments referencing the legacy names are intentional
  /// historical breadcrumbs and must not trip the freeze.
  private static func scanSources(pattern: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let sourcesRoot = repoRoot().appending(path: "Sources")
    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var hits: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let relative = url.path.replacingOccurrences(
        of: repoRoot().path + "/", with: "")
      for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Skip comment-only lines so historical-breadcrumb mentions of
        // legacy names do not trip the freeze.
        if trimmed.hasPrefix("//") { continue }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if regex.firstMatch(in: text, range: range) != nil {
          hits.append("\(relative):\(idx + 1): \(trimmed)")
        }
      }
    }
    return hits
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
