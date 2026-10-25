import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Every front-path paste names the layout's "v" key (#3437). The poster takes the key as a
/// required argument, so the compiler stops a caller that names none; this guard stops one that
/// names a fixed key instead of the resolver.
@Suite("Front-path paste callers pass the layout's v key (#3437)", .tags(.driftGuard))
struct PasteKeyWiringFreezeTests {

  static let callers = [
    "Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift",
    "Sources/EnviousWisprAppKit/App/LastDictationAction.swift",
    "Sources/EnviousWisprAppKit/Views/Main/HistoryPaste.swift",
  ]

  private final class PosterCalls: SyntaxVisitor {
    var keyArguments: [String] = []
    var fixedKeys = 0

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "postPasteKeystroke"
      {
        let key = node.arguments.first { $0.label?.text == "keyCode" }
        keyArguments.append(key?.expression.trimmedDescription ?? "<no keyCode argument>")
      }
      return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
      if node.baseName.text == "kVK_ANSI_V" { fixedKeys += 1 }
      return .visitChildren
    }
  }

  @Test("each caller passes SyntheticCopyChord.commandVKeyCode() and names no physical V")
  func callersPassTheResolvedKey() throws {
    for path in Self.callers {
      let source = try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8)
      let visitor = PosterCalls(viewMode: .sourceAccurate)
      visitor.walk(CachedSwiftParser.parse(source: source))
      #expect(visitor.keyArguments.isEmpty == false, "\(path) no longer posts a paste")
      for argument in visitor.keyArguments {
        #expect(argument == "SyntheticCopyChord.commandVKeyCode()", "\(path): \(argument)")
      }
      #expect(visitor.fixedKeys == 0, "\(path) names kVK_ANSI_V")
    }
  }
}
