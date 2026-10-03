import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #1635 / #3385: the "getting the model ready" impression may fire only from the subview that
/// visibly renders the preparing words: inside the `.ready` setup state, in the
/// `ModelPreparingCopy.isPreparing` branch, on the `.onAppear` of the view showing
/// `ModelPreparingCopy.label`. #3385 moved the engine page into a summary card; this guard keeps
/// the emitter off the page root, the collapsed choices, an initializer and a help popover.
/// A drift guard over the SOURCE; the rebuilt-app UAT proves the label and the event arrive.
@Suite("Model preparing impression placement", .tags(.driftGuard))
struct ModelPreparingImpressionPlacementTests {

  static let path = "Sources/EnviousWisprAppKit/Views/Settings/SpeechEngineSettingsView.swift"

  @Test("the production emitter sits on the visible preparing label")
  func productionPlacement() throws {
    let source = try String(contentsOf: RepoRoot.url.appending(path: Self.path), encoding: .utf8)
    let emitters = Self.emitters(in: source)
    #expect(emitters.count == 1, "expected one emitter, found \(emitters.count)")
    let emitter = try #require(emitters.first)
    #expect(emitter.isValid, "emitter context: \(emitter)")
  }

  @Test("an emitter on the page root is refused")
  func refusesPageRoot() {
    let fixture = """
      var body: some View {
        SettingsContentView { Text("x") }
          .onAppear {
            TelemetryService.shared.settingsModelPreparingImpression(engine: "whisperKit", reason: "engine_swap")
          }
      }
      """
    let emitters = Self.emitters(in: fixture)
    #expect(emitters.count == 1)
    #expect(emitters.allSatisfy { $0.isValid == false })
  }

  @Test("an emitter in the ready branch but on the settled label is refused")
  func refusesSettledBranch() {
    let fixture = """
      switch state {
      case .ready:
        if ModelPreparingCopy.isPreparing(warmInFlight: x) {
          Text(ModelPreparingCopy.label(warmInFlight: x))
        } else {
          Label(ModelPreparingCopy.label(warmInFlight: x), systemImage: "checkmark")
            .onAppear {
              TelemetryService.shared.settingsModelPreparingImpression(engine: "whisperKit", reason: "engine_swap")
            }
        }
      default: EmptyView()
      }
      """
    let emitters = Self.emitters(in: fixture)
    #expect(emitters.count == 1)
    #expect(emitters.allSatisfy { $0.isValid == false })
  }

  @Test("quoted text that spells out the label is not the label")
  func refusesQuotedDecoy() {
    let fixture = """
      switch state {
      case .ready:
        if ModelPreparingCopy.isPreparing(warmInFlight: x) {
          Text("Text(ModelPreparingCopy.label")
            .onAppear {
              TelemetryService.shared.settingsModelPreparingImpression(engine: "whisperKit", reason: "engine_swap")
            }
        }
      default: EmptyView()
      }
      """
    let emitters = Self.emitters(in: fixture)
    #expect(emitters.count == 1)
    #expect(emitters.allSatisfy { $0.isValid == false })
  }

  @Test("an inverted preparing condition is refused")
  func refusesInvertedPredicate() {
    let fixture = """
      switch state {
      case .ready:
        if ModelPreparingCopy.isPreparing(warmInFlight: x) == false {
          Text(ModelPreparingCopy.label(warmInFlight: x))
            .onAppear {
              TelemetryService.shared.settingsModelPreparingImpression(engine: "whisperKit", reason: "engine_swap")
            }
        }
      default: EmptyView()
      }
      """
    let emitters = Self.emitters(in: fixture)
    #expect(emitters.count == 1)
    #expect(emitters.allSatisfy { $0.isValid == false })
  }

  @Test("the shipped shape is accepted")
  func acceptsShippedShape() {
    let fixture = """
      switch state {
      case .ready:
        if ModelPreparingCopy.isPreparing(warmInFlight: x) {
          HStack {
            ProgressView()
            Text(ModelPreparingCopy.label(warmInFlight: x))
          }
          .onAppear {
            TelemetryService.shared.settingsModelPreparingImpression(engine: "whisperKit", reason: "engine_swap")
          }
        }
      default: EmptyView()
      }
      """
    let emitters = Self.emitters(in: fixture)
    #expect(emitters.count == 1)
    #expect(emitters.allSatisfy { $0.isValid })
  }

  // MARK: - Extractor

  struct Emitter: CustomStringConvertible {
    let inOnAppearOfPreparingLabel: Bool
    let inPreparingBranch: Bool
    let inReadyCase: Bool
    var isValid: Bool { inOnAppearOfPreparingLabel && inPreparingBranch && inReadyCase }
    var description: String {
      "onAppear-of-label=\(inOnAppearOfPreparingLabel) preparing-branch=\(inPreparingBranch) ready-case=\(inReadyCase)"
    }
  }

  /// A real `Text(ModelPreparingCopy.label(...))` call inside `expression`, found in the
  /// syntax tree, so quoted text that merely spells it out does not count.
  final class PreparingLabelFinder: SyntaxVisitor {
    var found = false

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(
      _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
      if node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Text",
        let argument = node.arguments.first?.expression.as(FunctionCallExprSyntax.self),
        let member = argument.calledExpression.as(MemberAccessExprSyntax.self),
        member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "ModelPreparingCopy",
        member.declName.baseName.text == "label"
      {
        found = true
      }
      return .visitChildren
    }
  }

  static func hasPreparingLabel(in expression: ExprSyntax) -> Bool {
    let finder = PreparingLabelFinder()
    finder.walk(expression)
    return finder.found
  }

  static func emitters(in source: String) -> [Emitter] {
    let visitor = Collector()
    visitor.walk(Parser.parse(source: source))
    return visitor.found
  }

  final class Collector: SyntaxVisitor {
    var found: [Emitter] = []
    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "settingsModelPreparingImpression"
      else { return .visitChildren }
      var onAppear = false
      var preparing = false
      var ready = false
      var child = Syntax(node)
      var current = node.parent
      while let parent = current {
        // `<view>.onAppear { emitter }`: the view the modifier is attached to must render
        // the preparing label.
        if let call = parent.as(FunctionCallExprSyntax.self),
          let called = call.calledExpression.as(MemberAccessExprSyntax.self),
          called.declName.baseName.text == "onAppear",
          let base = called.base,
          ModelPreparingImpressionPlacementTests.hasPreparingLabel(in: base)
        {
          onAppear = true
        }
        if let ifExpr = parent.as(IfExprSyntax.self),
          ifExpr.conditions.count == 1,
          let condition = ifExpr.conditions.first?.condition.as(FunctionCallExprSyntax.self),
          let predicate = condition.calledExpression.as(MemberAccessExprSyntax.self),
          predicate.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "ModelPreparingCopy",
          predicate.declName.baseName.text == "isPreparing",
          Syntax(ifExpr.body) == child
        {
          preparing = true
        }
        if let switchCase = parent.as(SwitchCaseSyntax.self),
          let label = switchCase.label.as(SwitchCaseLabelSyntax.self),
          label.caseItems.count == 1,
          let pattern = label.caseItems.first?.pattern.as(ExpressionPatternSyntax.self),
          let value = pattern.expression.as(MemberAccessExprSyntax.self),
          value.base == nil,
          value.declName.baseName.text == "ready"
        {
          ready = true
        }
        child = parent
        current = parent.parent
      }
      found.append(
        Emitter(inOnAppearOfPreparingLabel: onAppear, inPreparingBranch: preparing, inReadyCase: ready))
      return .visitChildren
    }
  }
}
