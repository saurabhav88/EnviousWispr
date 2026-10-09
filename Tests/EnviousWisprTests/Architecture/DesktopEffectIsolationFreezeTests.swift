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
    // #1413: the output-volume writer and the Music/Spotify scripter.
    "LiveOutputVolumeEffects",
    "LiveMediaPlaybackEffects",
    // #3544 P2: the keyboard event tap.
    "LiveKeyboardListener",
  ]

  /// #3544 P2: keyboard event taps and event posting. A tap sees every keystroke system-wide and
  /// a post types into the front app, so a unit test must reach neither. Built by concatenation so
  /// this file's own text does not trip `check-dependency-direction.sh`, which reads strings.
  private static let bannedTapPostNames: Set<String> = {
    let cg = "CGEvent"
    let c = ["TapCreate", "TapCreateForPid", "TapCreateForPSN", "TapEnable", "Post", "PostToPid",
      "PostToPSN", "TapPostEvent"].map { cg + $0 }
    let swift = ["tap" + "Create", "tap" + "CreateForPid", "tap" + "CreateForPSN", "tap" + "Enable",
      "tap" + "PostEvent", "post" + "ToPid", "post" + "ToPSN"]
    return Set(c + swift)
  }()

  /// The tap and post references a file makes, read from its syntax tree: the name and the whole
  /// statement it sits in, whitespace collapsed, so a call split across lines is one statement.
  fileprivate static func tapPostReferences(in text: String) -> [TapPostCollector.Hit] {
    TapPostCollector.references(in: Parser.parse(source: text), banned: bannedTapPostNames)
  }

  /// The existing posting sites, each permitted as its exact statement in its own file, as in
  /// `check-dependency-direction.sh`: paste's Cmd+V pair and the synthetic Copy chord.
  private static let permittedTapPost: Set<String> = {
    let paste = "Sources/EnviousWisprServices/PasteService.swift|"
    let copy = "Sources/EnviousWisprPipeline/SyntheticCopyChord.swift|"
    let sessionPost = ".post" + "(tap: .cgAnnotatedSessionEventTap)"
    let pidPost = ".post" + "ToPid(pid)"
    return [
      paste + "keyDown" + sessionPost, paste + "keyUp" + sessionPost,
      copy + "commandDown" + pidPost, copy + "keyDown" + pidPost,
      copy + "keyUp" + pidPost, copy + "commandUp" + pidPost,
    ]
  }()

  /// Whether a file may make raw tap and post calls: only the owning desktop module, the same
  /// scope `check-dependency-direction.sh` exempts. `EnviousWisprDesktopEffectsTests` may import
  /// live adapters but may not make raw tap or post calls itself.
  fileprivate static func ownsTapAndPost(_ path: String) -> Bool {
    path.hasPrefix("Sources/EnviousWisprDesktopEffects/")
  }

  /// Every Swift file in `Sources/` and `Tests/` except the owning desktop module.
  private static func nonOwnerSwiftSources() throws -> [(path: String, text: String)] {
    var found: [(String, String)] = []
    for top in ["Sources", "Tests"] {
      let root = RepoRoot.sourceURL(top)
      let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
      while let url = e?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let path = top + url.path.dropFirst(root.path.count)
        if ownsTapAndPost(path) { continue }
        found.append((path, try String(contentsOf: url, encoding: .utf8)))
      }
    }
    return found
  }

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
  @Test("only the desktop module taps or posts keyboard events, apart from the permitted statements")
  func onlyTheDesktopModuleTapsOrPosts() throws {
    let sources = try Self.nonOwnerSwiftSources()
    #expect(sources.count > 500, "the sweep found almost nothing — it is pointed at the wrong tree")
    #expect(
      sources.contains { $0.path.hasPrefix("Tests/EnviousWisprDesktopEffectsTests/") },
      "the tap/post sweep must include the live-adapter test target")
    var offenders: [String] = []
    var permittedSeen: Set<String> = []
    for (path, text) in sources {
      for hit in Self.tapPostReferences(in: text) {
        let key = path + "|" + hit.statement
        if Self.permittedTapPost.contains(key) {
          permittedSeen.insert(key)
        } else {
          offenders.append("\(path): \(hit.name) in `\(hit.statement)`")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      \(offenders.sorted()) create an event tap or post an event outside \
      EnviousWisprDesktopEffects. Either one reaches the user's real keyboard; put the call in the \
      desktop module behind DesktopHotkeyEffects, and drive it in tests through \
      RecordingDesktopHotkeyEffects.
      """)
    // A permitted statement that no longer exists is a stale exception someone could reuse.
    #expect(permittedSeen == Self.permittedTapPost)
  }

  @Test("the tap and post scope exempts only the desktop module itself")
  func tapPostScopeControls() {
    let split = "e.post" + "(\n  tap: .cghidEventTap)"
    #expect(Self.tapPostReferences(in: split).isEmpty == false)
    #expect(Self.ownsTapAndPost("Sources/EnviousWisprDesktopEffects/LiveKeyboardListener.swift"))
    #expect(Self.ownsTapAndPost("Tests/EnviousWisprDesktopEffectsTests/X.swift") == false)
    #expect(Self.ownsTapAndPost("Tests/EnviousWisprASRTests/X.swift") == false)
    #expect(Self.ownsTapAndPost("Sources/EnviousWisprServices/X.swift") == false)
  }

  /// Sources for the reader's controls and whether each should be found.
  private static let tapPostControls: [(source: String, hit: Bool)] = {
    let cg = "CGEvent"
    let post = "post"
    var rows: [(String, Bool)] = []
    rows.append(("let t = \(cg).tap" + "Create(tap: a, place: b, options: c, eventsOfInterest: d, callback: e, userInfo: nil)", true))
    rows.append(("let f = \(cg).tap" + "Create", true))
    rows.append(("\(cg)Post(.cghidEventTap, e)", true))
    rows.append(("let g = \(cg)TapEnable", true))
    rows.append(("e.\(post)(tap: .cghidEventTap)", true))
    rows.append(("let h = \(cg).\(post)(tap:)", true))
    rows.append(("e.\(post)ToPid(pid)", true))
    rows.append(("NotificationCenter.default.post(name: .x, object: nil)", false))
    rows.append(("service.post(message)", false))
    rows.append(("// e.\(post)(tap: .cghidEventTap)", false))
    rows.append(("let s = \"\(cg)Post\"", false))
    rows.append(("e.\(post)(\n  tap: .cghidEventTap)", true))
    rows.append(("e\n  .\(post)ToPid(pid)", true))
    rows.append(("let t = \(cg).`tap" + "Create`(tap: a)", true))
    rows.append(("e.`\(post)`(`tap`: .cghidEventTap)", true))
    return rows
  }()

  /// The collector's own controls, parsed in memory and never compiled. Sources are assembled at
  /// run time for the reason given on `bannedTapPostNames`.
  @Test("the tap and post reader finds calls and references and ignores look-alikes")
  func tapPostReaderControls() {
    #expect(Self.tapPostControls.count == 15)
    for (source, hit) in Self.tapPostControls {
      #expect(Self.tapPostReferences(in: source).isEmpty == (hit == false), "\(source)")
    }
  }
}

/// Collects the tap and post references a file makes (#3544 P2): a banned name used as a call or
/// a reference, and `post` called or referenced with a `tap:` label. Comments and string literals
/// are trivia or literal segments in the tree, so they never match.
private final class TapPostCollector: SyntaxVisitor {
  struct Hit {
    let name: String
    /// The enclosing statement, whitespace collapsed to single spaces.
    let statement: String
  }

  private let banned: Set<String>
  private var found: [Hit] = []

  private init(banned: Set<String>) {
    self.banned = banned
    super.init(viewMode: .sourceAccurate)
  }

  static func references(in tree: SourceFileSyntax, banned: Set<String>) -> [Hit] {
    let c = TapPostCollector(banned: banned)
    c.walk(tree)
    return c.found
  }

  /// The name without backticks: `identifier?.name` reads `` `tapCreate` `` and `tapCreate` alike.
  private static func name(_ token: TokenSyntax) -> String {
    token.identifier?.name ?? token.text
  }

  private func record(_ name: String, at node: some SyntaxProtocol) {
    var statement: Syntax = Syntax(node)
    var cursor: Syntax? = Syntax(node)
    while let current = cursor {
      if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) {
        statement = current
        break
      }
      cursor = current.parent
    }
    let text = statement.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    found.append(Hit(name: name, statement: text))
  }

  override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
    let name = Self.name(node.baseName)
    if banned.contains(name) { record(name, at: node) }
    // A function reference: `CGEvent.post(tap:)`.
    if name == "post", let labels = node.argumentNames?.arguments,
      labels.first.map({ Self.name($0.name) }) == "tap"
    {
      record("post(tap:)", at: node)
    }
    return .visitChildren
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
      Self.name(member.declName.baseName) == "post",
      node.arguments.first?.label.map(Self.name) == "tap"
    {
      record("post(tap:)", at: node)
    }
    return .visitChildren
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
