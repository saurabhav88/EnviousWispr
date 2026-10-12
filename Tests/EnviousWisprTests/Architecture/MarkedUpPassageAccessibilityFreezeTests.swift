import Foundation
import SwiftParser
import SwiftSyntax
import Testing

// MARK: - MarkedUpPassageAccessibilityFreezeTests (#3573)
//
// Every marked-up passage on screen is drawn by `MarkedUpPassageText`, and that view is selectable
// and spoken through `accessibilityRepresentation`, never through `.accessibilityLabel` beside
// `.textSelection(.enabled)`. That pairing crashed the app (a stack overflow in macOS accessibility
// label resolution) on the first accessibility read after Marked up appeared; selection alone,
// label alone and the representation did not. A unit test cannot reproduce it, because SwiftUI only
// builds its accessibility tree for a real outside client, so the property is frozen in the source:
// one home, and the home keeps the safe pairing. The run that proves the crash is gone is the Live
// UAT recorded on the fix's PR.

/// Drift Guard: when this fails, a Marked up passage may be drawn with a label-plus-selection
/// pairing that crashes the app for anyone using an accessibility tool.
@Suite("Marked up passages keep the safe accessibility pairing (#3573)", .tags(.driftGuard))
struct MarkedUpPassageAccessibilityFreezeTests {

  /// Calls to `markedUpText` with the type each sits in, and the modifier names applied inside
  /// `MarkedUpPassageText`.
  private final class Visitor: SyntaxVisitor {
    private(set) var markedUpTextCalls: [String] = []
    private(set) var passageModifiers: Set<String> = []
    private(set) var passageViewCalls = 0
    private var typeStack: [String] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      typeStack.append(node.name.text)
      return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        if name == "markedUpText" { markedUpTextCalls.append(typeStack.last ?? "<top level>") }
        if typeStack.last == "MarkedUpPassageText", member.base != nil {
          passageModifiers.insert(name)
        }
      }
      if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
        ref.baseName.text == "MarkedUpPassageText", typeStack.last != "MarkedUpPassageText"
      {
        passageViewCalls += 1
      }
      return .visitChildren
    }
  }

  private static func scan() throws -> (calls: [String], modifiers: Set<String>, uses: Int) {
    let root = RepoRoot.sourceURL("Sources/EnviousWisprAppKit")
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { throw CocoaError(.fileReadUnknown) }
    var calls: [String] = []
    var modifiers: Set<String> = []
    var uses = 0
    var scanned = 0
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let visitor = Visitor(viewMode: .sourceAccurate)
      visitor.walk(Parser.parse(source: try String(contentsOf: url, encoding: .utf8)))
      calls += visitor.markedUpTextCalls
      modifiers.formUnion(visitor.passageModifiers)
      uses += visitor.passageViewCalls
    }
    // Fail closed: scanning nothing must not read as a pass.
    #expect(scanned > 100, "expected to scan the whole app module, scanned \(scanned) files")
    return (calls, modifiers, uses)
  }

  @Test("every marked-up text is drawn inside MarkedUpPassageText, and nowhere else")
  func oneHome() throws {
    let result = try Self.scan()
    #expect(
      result.calls == ["MarkedUpPassageText"],
      "marked-up text must be drawn by MarkedUpPassageText only; found \(result.calls)")
  }

  @Test("MarkedUpPassageText is selectable and speaks through a representation, never a label")
  func safePairing() throws {
    let result = try Self.scan()
    #expect(result.modifiers.contains("textSelection"))
    #expect(result.modifiers.contains("accessibilityRepresentation"))
    #expect(
      result.modifiers.isDisjoint(with: ["accessibilityLabel", "accessibilityValue"]),
      "a label or value beside textSelection crashed the app (#3573); found \(result.modifiers)")
  }

  @Test("History turns and Transcribe a File passages both use MarkedUpPassageText")
  func bothScreensUseIt() throws {
    #expect(try Self.scan().uses == 2, "expected exactly History's turn rows and the wizard")
  }
}
