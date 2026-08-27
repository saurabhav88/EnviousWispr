import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// The second layer over the desktop-effect boundary (#2455 C5, issue #2462).
///
/// **What actually enforces the boundary, stated first because the plan got this
/// wrong.** The epic's design held that separating the live code into its own
/// module makes it unreachable from the unit target, failing at compile with "no
/// such module". That is FALSE under this project's build: a file in
/// `Tests/EnviousWisprTests/` importing `EnviousWisprDesktopEffects` and
/// constructing `LiveOverlayPanelDriver` compiles and links, because Xcode places
/// every built product on one shared search path. Measured 2026-08-26; recorded on
/// #2455. SwiftPM would reject it, but CI runs Tuist and xcodebuild only.
///
/// So `scripts/check-dependency-direction.sh` is the wall — it rejects the import
/// AND the OS calls themselves outside the owning module — and this suite is a
/// second layer in front of it, not a tripwire in front of a compiler barrier that
/// does not exist.
///
/// **What a syntax pass can and cannot see.** It sees a direct reference by name,
/// including a scoped import and a qualified member type. It cannot resolve a
/// value hidden behind a helper, an alias declared in another file, an unrelated
/// captured name, or an existential. Anything reaching a
/// live type by those routes passes here and is caught — if at all — by the gate's
/// call-shape rules. Neither layer resolves types, which is why the reverted
/// attempts at type-shaped patterns are documented beside `live_effect_pattern`
/// rather than retried here.
///
/// **Why a second layer at all**, given the gate: the gate matches text against a
/// pattern list, and a new live type added to `EnviousWisprDesktopEffects` next
/// year will not be in that list. This suite bans the MODULE and its known adapter
/// names, so a new adapter is covered by the module ban on the day it is written.
@MainActor
@Suite(.tags(.driftGuard))
struct DesktopEffectIsolationFreezeTests {

  /// The live adapters. Named individually as well as by module, because a test
  /// can name a type without importing its module when another import re-exports
  /// it — rare, and cheap to cover.
  private static let bannedSymbols = [
    "LiveDesktopHotkeyEffects",
    "LiveDesktopPresentationEffects",
    "LiveOverlayPanelDriver",
    "LiveWorkspaceObserver",
    "LiveRelocationRelauncher",
  ]

  private static let bannedModule = "EnviousWisprDesktopEffects"

  /// Everything under `Tests/EnviousWisprTests/`, which is the target that must
  /// not reach a live effect. `Tests/EnviousWisprDesktopEffectsTests/` is
  /// deliberately absent: three suites there construct live drivers on purpose,
  /// and that is the target's reason to exist.
  private static func unitTestSources() throws -> [(name: String, text: String)] {
    let root = RepoRoot.sourceURL("Tests/EnviousWisprTests")
    var found: [(String, String)] = []
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
    }
    return found
  }

  @Test("the unit test target names no live desktop-effect adapter")
  func unitTargetNamesNoLiveAdapter() throws {
    let sources = try Self.unitTestSources()
    #expect(sources.count > 100, "the sweep found almost nothing — it is pointed at the wrong tree")

    var offenders: [String] = []
    for (name, text) in sources {
      // Parse rather than grep: a banned name inside a comment or a string is not
      // a reference, and this file's own header names all five.
      let tree = Parser.parse(source: text)
      let referenced = IdentifierCollector.identifiers(in: tree)
      for symbol in Self.bannedSymbols where referenced.contains(symbol) {
        offenders.append("\(name): \(symbol)")
      }
      if referenced.contains(Self.bannedModule) {
        offenders.append("\(name): imports \(Self.bannedModule)")
      }
    }

    #expect(
      offenders.isEmpty,
      """
      \(offenders.sorted()) reference a live desktop effect from the unit test \
      target. A suite that genuinely needs one belongs in \
      EnviousWisprDesktopEffectsTests, which exists for exactly that and already \
      holds three. Adding it here instead puts a real window, hotkey or activation \
      back into the run that must not have one.
      """)
  }
}

/// Collects every identifier and module name a file references.
private final class IdentifierCollector: SyntaxVisitor {
  private var names: Set<String> = []

  static func identifiers(in tree: SourceFileSyntax) -> Set<String> {
    let c = IdentifierCollector(viewMode: .sourceAccurate)
    c.walk(tree)
    return c.names
  }

  override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
    names.insert(node.name.text)
    return .visitChildren
  }

  override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
    names.insert(node.baseName.text)
    return .visitChildren
  }

  /// Every COMPONENT as well as the joined path, because a scoped import names
  /// the module and the type in one path: `import class
  /// EnviousWisprDesktopEffects.LiveOverlayPanelDriver`. Joining alone produced
  /// `EnviousWisprDesktopEffects.LiveOverlayPanelDriver`, which matches neither
  /// banned string — a hole found by review, not by the tests.
  override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
    let components = node.path.map(\.name.text)
    names.formUnion(components)
    names.insert(components.joined(separator: "."))
    return .skipChildren
  }

  /// A qualified reference — `EnviousWisprDesktopEffects.LiveOverlayPanelDriver`
  /// used as a type without importing the module unqualified.
  override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
    names.insert(node.name.text)
    return .visitChildren
  }
}
