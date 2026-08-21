import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #2292. **The one-window claim, asserted structurally.**
///
/// **Drift Guard, and the class matters here.** When this fails we changed our
/// own code; the user sees nothing at the moment of failure. It must never be
/// cited as evidence that the pill renders correctly — the behavioural proof is
/// the §11.1 Live UAT, reading `panelConstructionCountForTesting` after a real
/// dictation.
///
/// ## Why this is structural rather than behavioural
///
/// The first version of this suite drove the legacy API and asserted the
/// construction counter. It passed with a measured count of **ZERO**: every
/// `showPanel` is queued with `DispatchQueue.main.async`, so a synchronous test
/// never creates a window at all. Probing the number rather than trusting the
/// green is the only reason that was found.
///
/// Making it observable meant pumping a run loop, which
/// `check-test-timing.sh` refuses — correctly. A clock-based wait to observe a
/// deliberately deferred creation is the harness fighting itself. The runtime
/// property belongs in Live UAT; what a unit test CAN own is the property that
/// makes the runtime claim possible, and that is a fact about the source.
///
/// Reading the source is the only available mechanism, the same reason
/// `TestInventoryFreezeTests` parses rather than reflects. **It PARSES rather
/// than matching text**, and that was not optional: the first version searched
/// for `.close()` as a string and fired on `OverlayWindowHost`'s own doc comment
/// explaining why it never calls `close()`. A guard whose subject is a
/// construct will match prose ABOUT that construct — this repo's
/// comparison-narrower-than-the-language shape, met immediately.
///
/// Known limit, stated rather than discovered later: it proves no OTHER site
/// constructs or closes a panel, not that the one remaining site is correct —
/// the host suite owns that.
@Suite(.tags(.driftGuard))
struct OverlayRetainedWindowTests {

  /// Every `NSPanel(...)` construction and every `.close()` call in a file,
  /// found by walking the syntax tree so comments and string literals are
  /// excluded STRUCTURALLY rather than one lexical form at a time.
  private final class PanelCallFinder: SyntaxVisitor {
    private(set) var constructs = 0
    private(set) var closes = 0

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
        callee.baseName.text == "NSPanel"
      {
        constructs += 1
      }
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "close", node.arguments.isEmpty
      {
        closes += 1
      }
      return .visitChildren
    }
  }

  private static func panelCalls(in text: String) -> (constructs: Int, closes: Int) {
    let finder = PanelCallFinder(viewMode: .sourceAccurate)
    finder.walk(Parser.parse(source: text))
    return (finder.constructs, finder.closes)
  }

  private static func overlayModuleSources() throws -> [(name: String, text: String)] {
    let root = RepoRoot.url.appending(path: "Sources/EnviousWisprAppKit")
    var found: [(String, String)] = []
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
    }
    return found
  }

  /// Exactly one `NSPanel(` constructor in the whole module, and it is the host's.
  @Test("only OverlayWindowHost constructs a panel")
  func onlyTheHostConstructsAPanel() throws {
    let sources = try Self.overlayModuleSources()
    #expect(sources.count > 50, "the sweep found almost nothing — it is pointed at the wrong tree")

    let constructors = sources.filter { Self.panelCalls(in: $0.text).constructs > 0 }
    #expect(
      constructors.map(\.name) == ["OverlayWindowHost.swift"],
      """
      \(constructors.map(\.name)) construct an NSPanel. Exactly one owner may, or \
      the retained window is not retained: a second constructor is a second \
      window, which is the #930 flicker returning by another route.
      """)
  }

  /// Zero `.close()` calls. Closing is what forces every rebuild, and the four
  /// compensating mechanisms this migration removes exist only because of it.
  @Test("nothing in the overlay module closes a window")
  func nothingClosesAWindow() throws {
    let offenders = try Self.overlayModuleSources()
      .filter { Self.panelCalls(in: $0.text).closes > 0 }
      .map(\.name)
    #expect(
      offenders.isEmpty,
      """
      \(offenders) call .close() on a window. `orderOut` hides; `close` destroys \
      and is what every rebuild came from. A retained panel that gets closed is \
      strictly worse than the shipped code, because nothing rebuilds it.
      """)
  }
}
