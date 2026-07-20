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
/// `pipeline`, `whisperKitKernelDriver`, `setup`). This is de-coupling, not
/// god-object accretion: the coordinator trades one wide god-reference for ten
/// narrow ones, reads nothing new, and its non-private method count is
/// unchanged at 3. Allowlist count rises 10 → 19 (3 owned `var` + 16 injected
/// `let`); non-private `func`s `runDidFinishLaunching`, `runDidBecomeActive`,
/// `runWillTerminate` unchanged (`init` is not a `func`).
/// Bible §30 entry (#636, 2026-06-06): `contactsImportCoordinator` added — the
/// App-layer orchestrator for Import-from-Contacts. Injected `let`, read by
/// `runDidFinishLaunching` for the opt-in launch sync only. Allowlist 19 → 20
/// (3 owned `var` + 17 injected `let`); non-private method count unchanged at 3.
/// A narrow new coordinator, not god-object accretion (issue-636 §3b).
/// Bible §30 entry (#1451, 2026-07-10): `applicationRelocationCoordinator` added
/// — the App Translocation recovery limb. Injected `let`, called once by
/// `runDidFinishLaunching` (`evaluateAndOfferIfNeeded()`); the coordinator owns
/// all relocation policy, so this is one narrow delegation, not accretion (§3b).
/// Allowlist 20 → 21 (3 owned `var` + 18 injected `let`); non-private method
/// count unchanged at 3.
/// Bible §30 entry (#1480, 2026-07-11): `bluetoothAwarenessPresenter` added — the
/// Bluetooth cold-start card's decision owner. Injected `let`; the three lifecycle
/// closures (`onPipelineStateChange`, `onAudioDeviceEvent`, the launch
/// completed-onboarding block) forward a `Trigger` fact to `reconcile(...)`. The
/// coordinator carries NO Bluetooth predicate, overlay branching, or once-per-launch
/// state — all decision logic lives on the presenter (§3b), so this is one narrow
/// delegation, not accretion. Allowlist 21 → 22 (3 owned `var` + 19 injected `let`);
/// non-private method count unchanged at 3. #1707 Phase 2: 22 → 23 (3 owned
/// `var` + 20 injected `let`) — `batchDecodeFaultController`, a deliberate,
/// explicit addition for the new DEBUG fault-injection oracle (§11.1/§3.2a-i),
/// forwarded into `DebugFaultEndpoint`'s construction; not accretion.
@Suite struct AppLifecycleCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/AppLifecycleCoordinator.swift"

  private static let storedPropertyAllowlist: Set<String> = [
    "audioEnvironmentSnapshotter",
    "audioSystemEventReporter",
    "debugFaultEndpoint",
    "settings",
    "permissions",
    "keychainManager",
    "customWordsCoordinator",
    "contactsImportCoordinator",
    "aiAvailability",
    "audioCapture",
    "asrManager",
    "kernelDriver",
    "whisperKitKernelDriver",
    "setup",
    "dictationRuntime",
    "dictationLifecycleCoordinator",
    "liveRecordingState",
    "menuBarController",
    "appWindowCoordinator",
    "hotkeyService",
    "applicationRelocationCoordinator",
    "bluetoothAwarenessPresenter",
    "batchDecodeFaultController",
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
      22-name allowlist. Unexpected: \(extras.sorted()). Missing: \
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
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
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
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
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
