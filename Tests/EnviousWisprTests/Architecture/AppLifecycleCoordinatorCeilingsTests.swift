import Foundation
import Testing

/// PR-B.4 of #763 — locks `AppLifecycleCoordinator`'s initial shape so the
/// extracted process-lifecycle home does not silently accrete domain state.
///
/// The shape gate is an EXACT stored-property-name allowlist, not a
/// parser-visible count (the shared parser counts only non-primitive `let`s,
/// which a count alone would under-report). This test parses every stored
/// declaration in the class body (`let` and `var`, all access levels,
/// primitives included) and asserts the name set EQUALS the allowlist.
/// Adding an unlisted field fails the test.
///
/// Bible §30 baseline (PR-B.4): 10 stored — 3 owned `var` + 7 injected `let`
/// including the single `appState`.
///
/// Bible §30 entry (PR-C.3 of #763, 2026-05-20, #815): the single `appState`
/// reference is replaced by the 10 specific homes the launch / become-active /
/// terminate bodies actually read (`settings`, `permissions`, `keychainManager`,
/// `customWordsCoordinator`, `aiAvailability`, `audioCapture`, `asrManager`,
/// `pipeline`, `whisperKitPipeline`, `setup`). This is de-coupling, not
/// god-object accretion: the coordinator trades one wide god-reference for ten
/// narrow ones, reads nothing new, and its non-private method count is
/// unchanged at 3. Allowlist count rises 10 → 19 (3 owned `var` + 16 injected
/// `let`); non-private `func`s `runDidFinishLaunching`, `runDidBecomeActive`,
/// `runWillTerminate` unchanged (`init` is not a `func`).
@Suite struct AppLifecycleCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/AppLifecycleCoordinator.swift"

  private static let storedPropertyAllowlist: Set<String> = [
    "audioEnvironmentSnapshotter",
    "audioSystemEventReporter",
    "debugFaultEndpoint",
    "settings",
    "permissions",
    "keychainManager",
    "customWordsCoordinator",
    "aiAvailability",
    "audioCapture",
    "asrManager",
    "kernelDriver",
    "whisperKitPipeline",
    "setup",
    "dictationRuntime",
    "dictationLifecycleCoordinator",
    "liveRecordingState",
    "menuBarController",
    "appWindowCoordinator",
    "hotkeyService",
  ]

  @Test func storedPropertyNamesMatchAllowlist() throws {
    let body = try RouterCeilingParser.classBody(
      named: "AppLifecycleCoordinator", at: Self.sourcePath)
    let names = storedPropertyNames(in: body)
    let extras = names.subtracting(Self.storedPropertyAllowlist)
    let missing = Self.storedPropertyAllowlist.subtracting(names)
    #expect(
      extras.isEmpty && missing.isEmpty,
      """
      AppLifecycleCoordinator stored-property set drifted from the \
      19-name allowlist. Unexpected: \(extras.sorted()). Missing: \
      \(missing.sorted()). Adding a stored property is god-object drift — \
      raising the allowlist requires a Bible §30 entry. Removing one means \
      this allowlist must shrink in the same PR.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "AppLifecycleCoordinator", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 4,
      """
      AppLifecycleCoordinator non-private method ceiling exceeded: \
      \(count) > 4 non-private `func` declarations in the class body. \
      PR-B.4 baseline: runDidFinishLaunching, runDidBecomeActive, \
      runWillTerminate. The method cap is the primary anti-accretion gate — \
      it blocks "and now this also fires at launch" helper growth.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 600,
      """
      AppLifecycleCoordinator line count exceeded: \(count) > 600 (soft \
      trip-wire). File should stay focused on the process-lifecycle sequence.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    // `RouterCeilingParser.imports` surfaces every anchored `import` line,
    // including inside `#if DEBUG` — so `EnviousWisprPipeline` (imported only
    // for `DebugFaultEndpoint` in debug builds) is on the allowlist.
    let allowed: Set<String> = [
      "AppKit", "EnviousWisprASR", "EnviousWisprAudio", "EnviousWisprCore",
      "EnviousWisprLLM", "EnviousWisprPipeline", "EnviousWisprServices",
      "Foundation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      AppLifecycleCoordinator imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }

  /// Parser self-test: a fixture body with an 11th stored property must be
  /// flagged. If this stops failing, the real gate above is untrustworthy.
  @Test func parserCatchesExtraStoredProperty() {
    let fixture = """
        private var audioEnvironmentSnapshotter: AudioEnvironmentSnapshotter?
        private let permissions: PermissionsService
        private let hotkeyService: HotkeyService
        private var smuggledExtraField: Int = 0
      """
    let names = storedPropertyNames(in: fixture)
    #expect(
      names.contains("smuggledExtraField"),
      "Parser failed to detect a smuggled stored property — the gate cannot be trusted.")
  }
}

/// Extracts the names of top-level (brace-depth 0) `let`/`var` stored-property
/// declarations in a class body. Includes all access levels and primitive
/// types; excludes computed properties (declaration line ends with `{`).
private func storedPropertyNames(in body: String) -> Set<String> {
  let declPattern =
    #"^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
    + #"(public|internal|private|fileprivate|package|open)?[[:space:]]*"#
    + #"(weak[[:space:]]+)?(let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)"#
  guard let regex = try? NSRegularExpression(pattern: declPattern) else { return [] }

  var depth = 0
  var names: Set<String> = []
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      let isComputed =
        s.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil
      if !isComputed {
        let ns = s as NSString
        if let m = regex.firstMatch(
          in: s, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 6, m.range(at: 6).location != NSNotFound
        {
          names.insert(ns.substring(with: m.range(at: 6)))
        }
      }
    }
    depth += opens - closes
  }
  return names
}
