import Foundation
import Testing

// MARK: - EngineSwitchOwnershipFreezeTests (#1171)
//
// Source-level guard that engine SWITCHING stays single-owner under
// `EngineCoordinator`, and that the duct-tape "want"-state vocabulary the first
// #1171 fix introduced never returns.
//
// Two invariants:
//   1. There is EXACTLY ONE production call site of `.switchBackend(to:` outside
//      the ASR managers (`Sources/EnviousWisprASR/`, which DECLARE + IMPLEMENT the
//      method) — the coordinator's injected `performSwitch`, wired in the
//      composition root (`WisprBootstrapper`). Fail-closed `== 1`: 0 means the
//      call moved/renamed (update this guard in lockstep), >1 means a second site
//      switches engines around the coordinator (the fragmentation that lost six
//      review rounds).
//   2. The duct-tape symbols (`desiredBackend`, `pendingBackendSwitch`,
//      `backendSwitchTask`, `ensureActiveBackend`, `drainBackendSwitch`,
//      `retryDeferredBackendSwitch`) are ABSENT from `Sources/` — pending-switch
//      is DERIVED (`selected != active`), never stored.
//
// Mirrors `KernelOwnershipFreezeTests` / `EngineIdentityFreezeTests` (comment-
// skipping scanner, fail-closed counts, adversarial + negative controls).

@Suite struct EngineSwitchOwnershipFreezeTests {

  // A METHOD CALL on a receiver: `foo.switchBackend(to: ...)`. The leading `\.`
  // excludes the `func switchBackend(to type:)` declarations in the ASR managers.
  private static let switchCallSite = #"\.switchBackend\(to:"#

  // Files allowed to own the single switch call site: the coordinator's injected
  // switch operation is wired in the composition root.
  private static let allowedSwitchOwners = ["WisprBootstrapper.swift", "EngineCoordinator.swift"]

  private static let bannedDuctTapeSymbols: [(name: String, pattern: String)] = [
    ("desiredBackend", #"\bdesiredBackend\b"#),
    ("pendingBackendSwitch", #"\bpendingBackendSwitch\b"#),
    ("backendSwitchTask", #"\bbackendSwitchTask\b"#),
    ("ensureActiveBackend", #"\bensureActiveBackend\b"#),
    ("drainBackendSwitch", #"\bdrainBackendSwitch\b"#),
    ("retryDeferredBackendSwitch", #"\bretryDeferredBackendSwitch\b"#),
  ]

  // MARK: 1 — exactly one production switch call site, in the composition root

  @Test("exactly one production .switchBackend(to:) call site, owned by the coordinator wiring")
  func singleSwitchCallSite() throws {
    // The ASR managers DECLARE/IMPLEMENT switchBackend; exclude that directory so
    // only CALL sites count.
    let hits = try Self.scanSources(
      pattern: Self.switchCallSite, excludingDir: "Sources/EnviousWisprASR/")
    #expect(
      hits.count == 1,
      """
      Expected EXACTLY ONE production `.switchBackend(to:)` call site (the
      EngineCoordinator's injected switch, wired in WisprBootstrapper), found \(hits.count):
      \(hits.joined(separator: "\n"))
      0 means the call moved/renamed (update this guard in lockstep). >1 means a
      second site switches engines around the coordinator — the duct-tape
      fragmentation #1171 deleted. All other sites must `poke()` / read `status`.
      """)
    if let only = hits.first {
      let inAllowedOwner = Self.allowedSwitchOwners.contains { only.contains($0) }
      #expect(
        inAllowedOwner,
        """
        The single `.switchBackend(to:)` call site is not in the coordinator's
        composition-root wiring: \(only)
        Allowed owners: \(Self.allowedSwitchOwners.joined(separator: ", ")).
        """)
    }
  }

  // MARK: 2 — the duct-tape "want"-state vocabulary stays deleted

  @Test("duct-tape backend-switch symbols are absent from Sources/")
  func ductTapeSymbolsAbsent() throws {
    for symbol in Self.bannedDuctTapeSymbols {
      let hits = try Self.scanSources(pattern: symbol.pattern, excludingDir: nil)
      #expect(
        hits.isEmpty,
        """
        The deleted duct-tape symbol `\(symbol.name)` reappears in Sources/:
        \(hits.joined(separator: "\n"))
        #1171 replaced stored "want" state with EngineCoordinator (selected read
        live; pending-switch DERIVED as selected != active). Do not reintroduce it.
        """)
    }
  }

  // MARK: Adversarial — the matchers flag real reintroductions

  @Test("a switchBackend CALL site is flagged; the declaration is not")
  func adversarialCallSiteVsDeclaration() {
    let call = "      await self.asrManager.switchBackend(to: want)"
    let decl = "  public func switchBackend(to type: ASRBackendType) async {"
    #expect(Self.regexFlags(source: call, pattern: Self.switchCallSite))
    #expect(Self.regexFlags(source: decl, pattern: Self.switchCallSite) == false)
  }

  @Test("a re-added desiredBackend / drainBackendSwitch is flagged")
  func adversarialDuctTapeReintroductionFlagged() {
    let v = "  private var desiredBackend: ASRBackendType?"
    let f = "  private func drainBackendSwitch(deferred: Bool) async {"
    #expect(Self.regexFlags(source: v, pattern: #"\bdesiredBackend\b"#))
    #expect(Self.regexFlags(source: f, pattern: #"\bdrainBackendSwitch\b"#))
  }

  @Test("single-call-site lock is fail-closed: 0 and 2 both differ from 1")
  func singleCallSiteFailClosed() {
    let zero = "let x = 1\n"
    let two = "a.switchBackend(to: x)\nb.switchBackend(to: y)\n"
    #expect(Self.countMatches(in: zero, pattern: Self.switchCallSite) == 0)
    #expect(Self.countMatches(in: two, pattern: Self.switchCallSite) == 2)
  }

  @Test("a comment-only mention of a banned token is skipped")
  func negativeControlCommentSkipped() {
    let source = "  // retryDeferredBackendSwitch was deleted in #1171\n  let x = 1\n"
    #expect(Self.countMatches(in: source, pattern: #"\bretryDeferredBackendSwitch\b"#) == 0)
  }

  // MARK: - Helpers (mirror KernelOwnershipFreezeTests)

  private static func scanSources(pattern: String, excludingDir: String?) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let rootURL = repoRoot().appending(path: "Sources")
    let enumerator = FileManager.default.enumerator(
      at: rootURL, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var hits: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let relative = url.path.replacingOccurrences(of: repoRoot().path + "/", with: "")
      if let dir = excludingDir, relative.hasPrefix(dir) { continue }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        let ns = text as NSString
        if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
          hits.append("\(relative):\(idx + 1): \(trimmed)")
        }
      }
    }
    return hits
  }

  private static func countMatches(in source: String, pattern: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    var count = 0
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
      let ns = text as NSString
      if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
        count += 1
      }
    }
    return count
  }

  private static func regexFlags(source: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let ns = source as NSString
    return regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) != nil
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
