import Foundation
import Testing

/// Architecture regression tests for `EnviousWisprApp`.
///
/// PR-A of #763 installs `EnviousWisprApp` as the SwiftUI composition root.
/// This test caps it before PR5+ start adding more App-owned homes, so the
/// composition root cannot quietly accrete domain methods or imports.
///
/// Tests parse the source file directly — App-struct initialization mounts
/// the real app and is not unit-testable.
///
/// Ratchet wording: lower-is-free, raise-needs-Bible §30 entry.
@Suite struct EnviousWisprAppCeilingsTests {

  /// Stored-property ceiling on the App struct.
  /// Locked at post-PR7 baseline (#773, 2026-05-18) = 11:
  /// appDelegate + isOnboardingPresented + appState + navigationCoordinator +
  /// diagnosticsCoordinator + languageSuggestionPresenter + updateCoordinatorHolder
  /// + transcriptWorkflowCoordinator (PR6) + liveRecordingState +
  /// lastRecordingResult + backendMetadata (all PR7).
  /// Counts both `let` and `var` top-level declarations (property wrappers
  /// included). Primitives (`: Bool`, `: Int`, `: String`, `: Double`) are
  /// excluded so the bool-typed `isOnboardingPresented` does count via the
  /// `@State` wrapper presence rather than the type alone.
  ///
  /// Ratchet history:
  /// - 7 → 8 in PR6 of epic #763 (2026-05-18, #772) for `TranscriptWorkflowCoordinator`.
  /// - 8 → 11 in PR7 of epic #763 (2026-05-18, #773) for `LiveRecordingState` +
  ///   `LastRecordingResult` + `BackendMetadata`. Bible §30 entry: PR7 lifts the
  ///   three live-dictation / display-label homes off AppState into App-owned
  ///   `@State` instances. By design, AppState shrinks (~14 lines) while the
  ///   composition root grows by three; this is the migration shape.
  ///   `liveRecordingState` and `lastRecordingResult` sunset to 9 in PR9
  ///   (DictationLifecycleCoordinator absorbs the push sites);
  ///   `backendMetadata` sunsets to 8 in PR11 (with AppState deletion).
  /// - 11 → 12 in PR8 of epic #763 (2026-05-19, #774) for `DictationRuntime`.
  /// - 12 → 13 in PR10 of epic #763 (2026-05-19, #776) for the shared
  ///   `HotkeyService`. Bible §30 entry: PR10 lifts `let hotkeyService` off
  ///   AppState because three independent consumers (`HotkeyController`,
  ///   `PipelineSettingsSync`, `DictationLifecycleCoordinator`) plus
  ///   `AppDelegate` termination all need the SAME instance, and AppState
  ///   is being deleted (epic #763 freeze). The App-owned `@State` is the
  ///   only composition root that survives PR11. Threaded into `AppState.init`,
  ///   DLC.init, DR.init, and `appDelegate.attach(...)`.
  /// - 13 → 14 in PR-B.1 of epic #763 (2026-05-19, #796) for
  ///   `SparkleUpdateController`. Bible §30 entry: PR-B.1 lifts the Sparkle
  ///   integration off AppDelegate into a dedicated App-owned home. The
  ///   `@State` instance is constructed from `updateCoordinatorHolder` and
  ///   threaded into `appDelegate.attach(...)` so `applicationWillFinishLaunching`
  ///   can invoke `startUpdater()` synchronously before any SwiftUI scene
  ///   body evaluates (Issue #739 env-capture invariant).
  /// - 14 → 15 in PR-B.2 of epic #763 (2026-05-19, #797) for
  ///   `AppWindowCoordinator`. Bible §30 entry: PR-B.2 lifts window lifecycle
  ///   (main + onboarding window identity, the two close observers, the
  ///   SwiftUI open/dismiss bridges, activation-policy transitions) off
  ///   AppDelegate into a dedicated App-owned home. The `@State` instance is
  ///   constructed in `init()` with two onboarding-guard closures and threaded
  ///   into `appDelegate.attach(...)` plus injected into both Window scenes
  ///   via `.environment(...)`.
  /// - 15 → 16 in PR-B.3 of epic #763 (2026-05-20, #798) for
  ///   `MenuBarController`. Bible §30 entry: PR-B.3 lifts the menu bar surface
  ///   (status item, dropdown menu, animated icon, `NSMenuDelegate`, five menu
  ///   actions) off AppDelegate into a dedicated App-owned home. The `@State`
  ///   instance is constructed in `init()` with five menu-action closures and
  ///   threaded into `appDelegate.attach(...)`. Not `.environment(...)`-injected
  ///   — no SwiftUI view consumes the menu surface.
  /// - 16 → 17 in PR-B.4 of epic #763 (2026-05-20, #799) for
  ///   `AppLifecycleCoordinator`. Bible §30 entry: PR-B.4 lifts the
  ///   process-lifecycle sequence (launch / become-active / terminate side
  ///   effects, the three process-lifetime audio objects) off AppDelegate into
  ///   a dedicated App-owned home. The `@State` instance is constructed last in
  ///   `init()` from seven already-built dependencies and threaded into
  ///   `appDelegate.attach(...)`. This is the final PR-B home — `AppDelegate`
  ///   ends as a thin AppKit adapter. Not `.environment(...)`-injected.
  @Test func envWisprAppStoredPropertyCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelStoredProperties(in: body)
    #expect(
      count <= 17,
      """
      EnviousWisprApp stored-property ceiling exceeded: \(count) > 17. \
      Raising the ceiling requires a Bible changelog entry. \
      New App-owned homes belong on EnviousWisprApp by design — this cap is \
      a thermostat: raise it deliberately, do not silently bump.
      """)
  }

  /// Non-private method ceiling — the App struct is composition-only. The
  /// only required member is the SwiftUI-protocol `body: some Scene` (computed
  /// property, not a method) and the `init()`. No callable public/internal
  /// methods are allowed because views and other types must not depend on
  /// methods of the App struct.
  @Test func envWisprAppNonPrivateMethodCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelNonPrivateMethods(in: body)
    #expect(
      count <= 0,
      """
      EnviousWisprApp non-private method ceiling exceeded: \(count) > 0. \
      The App struct is the composition root. Methods belong on the
      individual @State homes (NavigationCoordinator, DictationRuntime, ...).
      """)
  }

  /// Line-count trip-wire. Soft backstop against accidental file explosions;
  /// entanglement signals (stored properties, methods, imports) are the
  /// primary mechanical constraints. Ratcheted 250→270 in PR8 of epic #763
  /// (2026-05-19, #774) to absorb DictationRuntime construction (15 lines).
  /// Ratcheted 270→310 in PR9 of epic #763 (2026-05-19, #775) to absorb
  /// `DictationLifecycleCoordinator` construction (~25 lines: 11-collaborator
  /// init block + recordingLockedAccess struct literal + install() call +
  /// attachDictationLifecycleCoordinator call) and the hoisted
  /// `TranscriptStore` + `TranscriptCoordinator` construction (~3 lines).
  /// Ratcheted 310→340 in PR-B.2 of epic #763 (2026-05-19, #797) to absorb
  /// `AppWindowCoordinator` construction (~14 lines: two onboarding-guard
  /// closures), the `@State` declaration, the 9th `attach(...)` argument, the
  /// two `.environment(...)` injections, and the `ActionWirer` drain-before-
  /// auto-open rewrite. Soft trip-wire only — the stored-property cap is the
  /// primary entanglement signal.
  /// Ratcheted 340→370 in PR-B.3 of epic #763 (2026-05-20, #798) to absorb
  /// `MenuBarController` construction (~22 lines: five menu-action closures),
  /// the `@State` declaration, and the `_menuBarController` assignment. The
  /// `attach(...)` arg count is unchanged (drops two, adds one).
  /// Ratcheted 370→385 in PR-B.4 of epic #763 (2026-05-20, #799) to absorb
  /// `AppLifecycleCoordinator` construction (the seven-dependency `init` call)
  /// and its `@State` declaration + assignment, net of the `attach(...)` call
  /// collapsing from eight arguments to two. Cap set by the deterministic rule
  /// (post-change actual 375 + 10, rounded up to the nearest 5).
  @Test func envWisprAppLineCountCeilingHolds() throws {
    let url = envWisprAppURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      lineCount <= 385,
      """
      EnviousWisprApp line count exceeded: \(lineCount) > 385. \
      Raising the ceiling requires a Bible changelog entry.
      """)
  }

  /// Allowed-imports ceiling. The composition root must NOT depend on lower
  /// modules like EnviousWisprPipeline / EnviousWisprAudio / EnviousWisprASR /
  /// EnviousWisprLLM directly — that would couple SwiftUI mounting to engine
  /// implementation details. AppDelegate already carries those imports.
  ///
  /// PR9 of #763 added EnviousWisprStorage to construct `TranscriptStore`
  /// directly in the composition root (hoisted out of `AppState.init` so the
  /// composition root can thread the same `TranscriptCoordinator` instance
  /// to both the lifecycle home and the transcript workflow coordinator).
  /// `TranscriptStore` is a small, dependency-free persistence wrapper — not
  /// an engine internal — so allowing it on the composition root is
  /// consistent with the rule's intent.
  @Test func envWisprAppImportsCeilingHolds() throws {
    let url = envWisprAppURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let allowed: Set<String> = [
      "SwiftUI", "EnviousWisprCore", "EnviousWisprServices", "EnviousWisprStorage",
    ]
    let actual = parseImports(in: source)
    let unexpected = actual.subtracting(allowed)
    #expect(
      unexpected.isEmpty,
      """
      EnviousWisprApp imports outside allowlist: \(unexpected.sorted()). \
      Allowed: \(allowed.sorted()). Lower-tier modules belong on AppDelegate \
      or on specific @State home types, not on the composition root.
      """)
  }
}

private func envWisprAppURL() -> URL {
  URL(fileURLWithPath: "Sources/EnviousWispr/App/EnviousWisprApp.swift")
}

private func structBodyOfEnviousWisprApp() throws -> String {
  let source = try String(contentsOf: envWisprAppURL(), encoding: .utf8)
  guard let openRange = source.range(of: "struct EnviousWisprApp: App {") else {
    Issue.record("EnviousWisprApp declaration not found at expected path/shape")
    throw POSIXError(.ENOENT)
  }
  let openIdx = source.index(before: openRange.upperBound)  // points at '{'
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  Issue.record("EnviousWisprApp struct body has unbalanced braces")
  throw POSIXError(.EILSEQ)
}

/// Counts top-level (depth 0) `let` and `var` declarations on the App struct.
/// Stored properties include those marked with SwiftUI property wrappers
/// (`@State`, `@NSApplicationDelegateAdaptor`).
private func countTopLevelStoredProperties(in body: String) -> Int {
  var depth = 0
  var count = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isStoredPropertyDeclaration(s) {
        count += 1
      }
    }
    depth += opens - closes
  }
  return count
}

private let storedPropertyPattern: String = {
  // Match `let|var <ident>` at the top level, allowing property wrappers
  // (with optional parenthesized args) and access modifiers in any order
  // before the declaration keyword.
  let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
  let access = #"(public|internal|private|fileprivate|package|open)?"#
  return "^[[:space:]]*\(attrs)\(access)[[:space:]]*(let|var)[[:space:]]+[A-Za-z_]"
}()

private func isStoredPropertyDeclaration(_ line: String) -> Bool {
  guard line.range(of: storedPropertyPattern, options: .regularExpression) != nil
  else { return false }
  // Exclude computed properties — these have an opening `{` on the same line
  // as the declaration (e.g. `var body: some Scene {`). Stored properties
  // never have a trailing `{` on the declaration line.
  if line.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil {
    return false
  }
  return true
}

/// Counts top-level non-private `func` declarations. The `body` computed
/// property is intentionally not a `func` and is excluded.
private func countTopLevelNonPrivateMethods(in body: String) -> Int {
  var depth = 0
  var count = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isNonPrivateMethodDeclaration(s) {
        count += 1
      }
    }
    depth += opens - closes
  }
  return count
}

private let nonPrivateMethodPattern: String =
  #"^[[:space:]]*(public|internal|package|open)?[[:space:]]*func[[:space:]]+[A-Za-z_]"#

private func isNonPrivateMethodDeclaration(_ line: String) -> Bool {
  guard line.range(of: nonPrivateMethodPattern, options: .regularExpression) != nil
  else { return false }
  // Reject if the line declares `private func` or `fileprivate func`.
  if line.range(
    of: #"^[[:space:]]*(private|fileprivate)[[:space:]]+func"#, options: .regularExpression)
    != nil
  {
    return false
  }
  return true
}

/// Parses `import <Module>` declarations at the top of the file (depth 0
/// outside any type body). Returns the module names.
private func parseImports(in source: String) -> Set<String> {
  var result: Set<String> = []
  let pattern = #"^[[:space:]]*import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)"#
  let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
  let ns = source as NSString
  let range = NSRange(location: 0, length: ns.length)
  regex?.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
    guard let m = match, m.numberOfRanges > 1 else { return }
    result.insert(ns.substring(with: m.range(at: 1)))
  }
  return result
}
