import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprServices

/// #3978: every paste chord we post holds its V key before releasing it. When this fails, an edit
/// has taken the hold out of one of the two chords, and TinyMCE 5 in Chrome (Roundcube webmail)
/// pastes every dictation twice again. Not product coverage: Live UAT on #3978 is.
@Suite("Synthetic key hold before release (#3978)", .tags(.driftGuard))
struct SyntheticKeyHoldTests {
  @Test("The hold asks for 20 ms")
  func holdDuration() {
    var requested: [TimeInterval] = []
    SyntheticKeyHold.beforeRelease(sleep: { requested.append($0) })
    #expect(requested == [0.020])
  }

  /// The two chords, each identified by file and by the one function that posts it. The post
  /// method names are not spelled with a dot here, so `check-dependency-direction.sh`, which reads
  /// strings, finds nothing to match in this file.
  @Test(
    "The hold sits between the key-down and key-up posts",
    arguments: [
      ("Sources/EnviousWisprServices/PasteService.swift", "dispatchCmdV", nil),
      ("Sources/EnviousWisprPipeline/SyntheticCopyChord.swift", "post", "at"),
    ] as [(String, String, String?)])
  func holdBetweenPosts(path: String, function: String, firstLabel: String?) throws {
    let text = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
    let tree = CachedSwiftParser.parse(source: text)
    let finder = FunctionFinder(name: function, firstLabel: firstLabel, viewMode: .sourceAccurate)
    finder.walk(tree)
    #expect(
      finder.found.count == 1, "expected one \(function) in \(path), found \(finder.found.count)")
    let body = try #require(finder.found.first?.body, "\(function) in \(path) has no body")

    // Direct statements of the body only: a hold inside an `if` or a closure would not run on
    // every chord, so it does not count.
    let kinds = body.statements.map { Self.kind(of: $0.item) }
    #expect(kinds.filter { $0 == .hold }.count == 1, "\(function): expected exactly one hold")
    let d = try #require(kinds.firstIndex(of: .keyDownPost), "\(function): no key-down post")
    let h = try #require(kinds.firstIndex(of: .hold), "\(function): no direct hold statement")
    let u = try #require(kinds.firstIndex(of: .keyUpPost), "\(function): no key-up post")
    #expect(d < h && h < u, "\(function): order must be key-down post, hold, key-up post")
    // The pid chord exposes Command to the target app: release it before the hold so
    // the app does not retain an unmatched Command-down during the wait (#3978 cloud review).
    let commandUp = kinds.firstIndex(of: .commandUpPost)
    #expect(function != "post" || commandUp.map { $0 < h } == true, "\(function): release Command first")
  }

  private enum Kind: Equatable { case keyDownPost, hold, keyUpPost, commandUpPost, other }

  /// `keyDown.post…(…)`, `SyntheticKeyHold.beforeRelease()` or `keyUp.post…(…)` as a whole
  /// statement; anything else is `other`.
  private static func kind(of item: CodeBlockItemSyntax.Item) -> Kind {
    guard let call = item.as(FunctionCallExprSyntax.self),
      let member = call.calledExpression.as(MemberAccessExprSyntax.self),
      let base = member.base?.as(DeclReferenceExprSyntax.self)
    else { return .other }
    let receiver = base.baseName.text
    let method = member.declName.baseName.text
    if receiver == "SyntheticKeyHold", method == "beforeRelease", call.arguments.isEmpty {
      return .hold
    }
    guard method.hasPrefix("post") else { return .other }
    switch receiver {
    case "keyDown": return .keyDownPost
    case "keyUp": return .keyUpPost
    case "commandUp": return .commandUpPost
    default: return .other
    }
  }
}

/// Every function declaration with this name (and, when given, this first argument label).
private final class FunctionFinder: SyntaxVisitor {
  let name: String
  let firstLabel: String?
  private(set) var found: [FunctionDeclSyntax] = []

  init(name: String, firstLabel: String?, viewMode: SyntaxTreeViewMode) {
    self.name = name
    self.firstLabel = firstLabel
    super.init(viewMode: viewMode)
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.name.text == name else { return .visitChildren }
    if let firstLabel {
      guard node.signature.parameterClause.parameters.first?.firstName.text == firstLabel else {
        return .visitChildren
      }
    }
    found.append(node)
    return .visitChildren
  }
}
