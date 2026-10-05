import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #3385: each chime card holds two SIBLING Buttons, Preview and Select, never one inside the
/// other, and the page wires them to different things: Select writes the setting, Preview plays
/// the clicked card through the one stored preview task, gated only by live dictation. These
/// read that shape from the source with SwiftParser; comments and strings cannot satisfy them.
/// A drift guard: real presses, focus and VoiceOver are final Live UAT.
@Suite("Recording chime wiring (#3385)", .tags(.driftGuard))
struct RecordingChimeWiringTests {
  static let contentPath = "Sources/EnviousWisprAppKit/Views/Settings/RecordingChimesContent.swift"
  static let pagePath =
    "Sources/EnviousWisprAppKit/Views/Settings/RecordingSoundsSettingsView.swift"

  static func parse(_ path: String) throws -> SourceFileSyntax {
    Parser.parse(
      source: try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8))
  }

  // MARK: - Card shape

  struct CardShape: Equatable {
    /// Names the card's body stacks side by side, in order.
    var bodyChildren: [String] = []
    /// Per control property: how many Buttons it builds, its action, and what it references.
    var previewButtons = 0
    var previewAction = ""
    var previewReferencesSelect = false
    var selectButtons = 0
    var selectAction = ""
    var selectReferencesPreview = false
    var previewHitShape = ""
    var selectHitShape = ""
    /// The opacity the IN USE badge is drawn with, read from its modifier.
    var badgeOpacity = ""
    /// Any tap or gesture modifier anywhere on the card type.
    var gestures: [String] = []
  }

  static func cardShape(in tree: SourceFileSyntax) -> CardShape? {
    guard let card = structDecl("RecordingChimeCard", in: tree) else { return nil }
    var shape = CardShape()
    if let body = property("body", of: card),
      let stack = firstCall(named: "ZStack", in: body),
      let children = stack.trailingClosure?.statements
    {
      shape.bodyChildren = children.map { $0.item.trimmedDescription }
    }
    if let preview = property("previewButton", of: card) {
      let buttons = calls(named: "Button", in: preview)
      shape.previewButtons = buttons.count
      shape.previewAction = buttons.first.flatMap { argument("action", of: $0) } ?? ""
      shape.previewReferencesSelect = references("onSelect", in: preview)
      shape.previewHitShape = memberCallNodes(in: preview, named: "contentShape").first?
        .arguments.first?.expression.trimmedDescription ?? ""
    }
    if let select = property("selectButton", of: card) {
      let buttons = calls(named: "Button", in: select)
      shape.selectButtons = buttons.count
      shape.selectAction = buttons.first.flatMap { argument("action", of: $0) } ?? ""
      shape.selectReferencesPreview = references("onPreview", in: select)
      shape.selectHitShape = memberCallNodes(in: select, named: "contentShape").first?
        .arguments.first?.expression.trimmedDescription ?? ""
      // The shared footer owns badge paint; the fixture can still put it inline.
      let badgeOwner = property("reservedBadge", of: card) ?? select
      shape.badgeOpacity =
        memberCallNodes(in: badgeOwner, named: "opacity").first {
          $0.calledExpression.as(MemberAccessExprSyntax.self)?.base?.trimmedDescription == "inUseBadge"
        }.flatMap { $0.arguments.first?.expression.trimmedDescription } ?? ""
    }
    shape.gestures = memberCallNames(in: card, where: isPressHandler).sorted()
    return shape
  }

  @Test("each card holds Preview and Select as two sibling Buttons, wired apart")
  func cardHoldsSiblingButtons() throws {
    let shape = try #require(Self.cardShape(in: try Self.parse(Self.contentPath)))
    #expect(
      shape
        == CardShape(
          bodyChildren: ["selectButton", "previewButton"],
          previewButtons: 1, previewAction: "onPreview", previewReferencesSelect: false,
          selectButtons: 1, selectAction: "onSelect", selectReferencesPreview: false,
          previewHitShape: "Rectangle()", selectHitShape: "RecordingChimeSelectRegion()",
          badgeOpacity: "isSelected ? 1 : 0", gestures: []),
      "\(shape)")
  }

  @Test("a Button nested in the other, Select inside Preview, or any card press handler is seen")
  func cardShapeControl() throws {
    let fixture = Parser.parse(
      source: """
        struct RecordingChimeCard: View {
          var body: some View {
            ZStack { selectButton; previewButton }
              .onTapGesture { onSelect() }
              .onLongPressGesture(minimumDuration: 0) { onSelect() }
          }
          private var previewButton: some View {
            Button(action: onPreview) { Button(action: onSelect) { Text("x") } }
          }
          private var selectButton: some View { Button(action: onSelect) { inUseBadge.opacity(0) } }
        }
        """)
    let shape = try #require(Self.cardShape(in: fixture))
    #expect(shape.bodyChildren == ["selectButton", "previewButton"])
    #expect(shape.previewButtons == 2)
    #expect(shape.previewReferencesSelect)
    #expect(shape.gestures == ["onLongPressGesture", "onTapGesture"])
    #expect(shape.badgeOpacity == "0")
  }

  // MARK: - Page wiring

  struct CardWiring: Equatable {
    let isPreviewEnabled: String
    let onSelect: [String]
    let onPreview: [String]
  }

  static func cardWirings(in tree: SourceFileSyntax) -> [CardWiring] {
    calls(named: "RecordingChimeCard", in: tree).map { call in
      CardWiring(
        isPreviewEnabled: argument("isPreviewEnabled", of: call) ?? "",
        onSelect: closureStatements("onSelect", of: call),
        onPreview: closureStatements("onPreview", of: call))
    }
  }

  @Test("each card selects and previews its own pairing; Preview waits only for dictation")
  func cardsPassTheirOwnPairing() throws {
    let wirings = Self.cardWirings(in: try Self.parse(Self.contentPath))
    #expect(
      wirings
        == [
          CardWiring(
            isPreviewEnabled: "!isDictationActive", onSelect: ["onSelect(pairing)"],
            onPreview: ["onPreview(pairing)"])
        ], "\(wirings)")
  }

  @Test("a fixed pairing or a master-gated Preview is seen")
  func cardWiringControl() {
    let fixture = Parser.parse(
      source: """
        RecordingChimeCard(
          pairing: pairing, isSelected: false, isPreviewEnabled: playsChimes && !isDictationActive,
          onSelect: { onSelect(pairing) }, onPreview: { onPreview(.dustMote) })
        """)
    #expect(
      Self.cardWirings(in: fixture)
        == [
          CardWiring(
            isPreviewEnabled: "playsChimes && !isDictationActive", onSelect: ["onSelect(pairing)"],
            onPreview: ["onPreview(.dustMote)"])
        ])
  }

  struct PageWiring: Equatable {
    let isDictationActive: String
    let onSelect: [String]
    let onPreview: [String]
    let previewStart: [String]
    let previewLiveActivity: [String]
    let storedTasks: [String]
    let tasksCreated: Int
    let disappearCancels: Bool
    let dictationCancels: Bool
  }

  static func pageWiring(in tree: SourceFileSyntax) -> PageWiring? {
    guard let page = structDecl("RecordingSoundsSettingsView", in: tree),
      let content = calls(named: "RecordingChimesContent", in: page).first
    else { return nil }
    let startPreview = page.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .first { $0.name.text == "startPreview" }
    let start = startPreview.flatMap { decl in
      memberCallNodes(in: decl, named: "start").first {
        $0.calledExpression.as(MemberAccessExprSyntax.self)?.base?.trimmedDescription
          == "RecordingChimePreview"
      }
    }
    let assigned =
      startPreview?.body?.statements.first?.item.trimmedDescription
      .hasPrefix("activePreviewTask = RecordingChimePreview.start(") ?? false
    let storedTasks = page.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }
      .filter { $0.trimmedDescription.contains("Task<") }
      .flatMap { $0.bindings.map { $0.pattern.trimmedDescription } }
    /// `activePreviewTask?.cancel()` as a real call statement among `statements`.
    /// A cancel that follows a `return` or `throw` in the same list never runs, so it does not count.
    func cancels(_ statements: CodeBlockItemListSyntax?) -> Bool {
      for item in statements ?? [] {
        if item.item.as(FunctionCallExprSyntax.self)?.trimmedDescription
          == "activePreviewTask?.cancel()"
        {
          return true
        }
        let exits = item.tokens(viewMode: .sourceAccurate).contains {
          $0.tokenKind == .keyword(.return) || $0.tokenKind == .keyword(.throw)
        }
        if exits { return false }
      }
      return false
    }
    let disappear = memberCallNodes(in: page, named: "onDisappear").contains {
      cancels($0.trailingClosure?.statements)
    }
    // Inside `if isActive { ... }`, the positive branch, of the onChange on live dictation.
    let dictation = memberCallNodes(in: page, named: "onChange").contains { call in
      guard argument("of", of: call) == "liveRecordingState.isDictationActive",
        let statements = call.trailingClosure?.statements
      else { return false }
      return statements.contains { item in
        guard
          let branch = item.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)
            ?? item.item.as(IfExprSyntax.self)
        else { return false }
        return branch.conditions.trimmedDescription == "isActive" && cancels(branch.body.statements)
      }
    }
    return PageWiring(
      isDictationActive: argument("isDictationActive", of: content) ?? "",
      onSelect: closureStatements("onSelect", of: content),
      onPreview: closureStatements("onPreview", of: content),
      previewStart: (start?.arguments.filter { $0.label?.text != "isDictationActive" }
        .map { $0.trimmedDescription } ?? []) + (assigned ? ["assigned"] : []),
      previewLiveActivity: start.map { closureStatements("isDictationActive", of: $0) } ?? [],
      storedTasks: storedTasks,
      tasksCreated: calls(named: "Task", in: page).count,
      disappearCancels: disappear,
      dictationCancels: dictation)
  }

  @Test("the page passes live dictation, writes only on Select, and owns one preview task")
  func pageWiring() throws {
    let wiring = try #require(Self.pageWiring(in: try Self.parse(Self.pagePath)))
    #expect(
      wiring
        == PageWiring(
          isDictationActive: "liveRecordingState.isDictationActive",
          onSelect: ["settings.recordingSoundPairing = pairing"],
          onPreview: ["startPreview(pairing: pairing)"],
          previewStart: ["pairing: pairing,", "replacing: activePreviewTask,", "assigned"],
          previewLiveActivity: ["liveRecordingState.isDictationActive"],
          storedTasks: ["activePreviewTask"],
          tasksCreated: 0,
          disappearCancels: true,
          dictationCancels: true),
      "\(wiring)")
  }

  @Test("a Preview that selects, a second task, or a lost cancellation is seen")
  func pageWiringControl() throws {
    let fixture = Parser.parse(
      source: """
        struct RecordingSoundsSettingsView: View {
          @State private var activePreviewTask: Task<Void, Never>?
          @State private var other: Task<Void, Never>?
          var body: some View {
            RecordingChimesContent(
              isDictationActive: false,
              onSelect: { pairing in settings.recordingSoundPairing = pairing },
              onPreview: { pairing in settings.recordingSoundPairing = pairing; startPreview(pairing: pairing) })
            .onDisappear { }
          }
          private func startPreview(pairing: RecordingSoundPairing) {
            other = Task { }
          }
        }
        """)
    let wiring = try #require(Self.pageWiring(in: fixture))
    #expect(wiring.isDictationActive == "false")
    #expect(
      wiring.onPreview == [
        "settings.recordingSoundPairing = pairing", "startPreview(pairing: pairing)",
      ])
    #expect(wiring.storedTasks == ["activePreviewTask", "other"])
    #expect(wiring.tasksCreated == 1)
    #expect(wiring.previewStart.isEmpty)
    #expect(wiring.disappearCancels == false && wiring.dictationCancels == false)
  }

  @Test("a quoted or commented cancel, or one under the inverted branch, is seen")
  func cancellationControl() throws {
    let fixture = Parser.parse(
      source: """
        struct RecordingSoundsSettingsView: View {
          @State private var activePreviewTask: Task<Void, Never>?
          var body: some View {
            RecordingChimesContent(isDictationActive: liveRecordingState.isDictationActive)
            .onDisappear {
              // activePreviewTask?.cancel()
              _ = "activePreviewTask?.cancel()"
            }
            .onChange(of: liveRecordingState.isDictationActive) { _, isActive in
              if !isActive {
                activePreviewTask?.cancel()
              }
            }
          }
        }
        """)
    let wiring = try #require(Self.pageWiring(in: fixture))
    #expect(wiring.isDictationActive == "liveRecordingState.isDictationActive")
    #expect(wiring.disappearCancels == false, "a comment or a string counted as a cancel")
    #expect(wiring.dictationCancels == false, "a cancel under `!isActive` counted")
  }

  @Test("a cancel after a return, in either place, is not a cancel")
  func cancelAfterAnEarlyExitControl() throws {
    let fixture = Parser.parse(
      source: """
        struct RecordingSoundsSettingsView: View {
          @State private var activePreviewTask: Task<Void, Never>?
          var body: some View {
            RecordingChimesContent(isDictationActive: liveRecordingState.isDictationActive)
            .onDisappear {
              if true { return }
              activePreviewTask?.cancel()
            }
            .onChange(of: liveRecordingState.isDictationActive) { _, isActive in
              if isActive {
                if true { return }
                activePreviewTask?.cancel()
              }
            }
          }
        }
        """)
    let wiring = try #require(Self.pageWiring(in: fixture))
    #expect(wiring.disappearCancels == false, "a cancel behind an early return counted")
    #expect(wiring.dictationCancels == false, "a cancel behind an early return counted")
  }

  // MARK: - Extractors

  static func structDecl(_ name: String, in tree: some SyntaxProtocol) -> StructDeclSyntax? {
    tree.tokens(viewMode: .sourceAccurate).lazy.compactMap { token -> StructDeclSyntax? in
      guard token.tokenKind == .identifier(name), let decl = token.parent?.as(StructDeclSyntax.self)
      else { return nil }
      return decl
    }.first
  }

  static func property(_ name: String, of decl: StructDeclSyntax) -> VariableDeclSyntax? {
    decl.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }
      .first { $0.bindings.first?.pattern.trimmedDescription == name }
  }

  /// Direct calls `name(...)`, anywhere under `node`.
  static func calls(named name: String, in node: some SyntaxProtocol) -> [FunctionCallExprSyntax] {
    node.tokens(viewMode: .sourceAccurate).compactMap { token -> FunctionCallExprSyntax? in
      guard token.tokenKind == .identifier(name),
        let reference = token.parent?.as(DeclReferenceExprSyntax.self),
        let call = reference.parent?.as(FunctionCallExprSyntax.self),
        call.calledExpression.id == reference.id
      else { return nil }
      return call
    }
  }

  static func firstCall(named name: String, in node: some SyntaxProtocol) -> FunctionCallExprSyntax?
  {
    calls(named: name, in: node).first
  }

  /// Calls `x.name(...)` for any of `names`, anywhere under `node`.
  static func memberCallNodes(in node: some SyntaxProtocol, named name: String)
    -> [FunctionCallExprSyntax]
  {
    node.tokens(viewMode: .sourceAccurate).compactMap { token -> FunctionCallExprSyntax? in
      guard token.tokenKind == .identifier(name),
        let member = token.parent?.parent?.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == name,
        let call = member.parent?.as(FunctionCallExprSyntax.self),
        call.calledExpression.id == member.id
      else { return nil }
      return call
    }
  }

  /// Names of the calls `x.name(...)` under `node` that `isMatch` accepts, one per call.
  static func memberCallNames(in node: some SyntaxProtocol, where isMatch: (String) -> Bool)
    -> [String]
  {
    node.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
      guard case .identifier(let name) = token.tokenKind, isMatch(name),
        let member = token.parent?.parent?.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == name,
        let call = member.parent?.as(FunctionCallExprSyntax.self),
        call.calledExpression.id == member.id
      else { return nil }
      return name
    }
  }

  /// Every spelling that can make a card respond to a press outside its two Buttons: any
  /// `...Gesture` modifier, `onTap...` or `onLongPress...`. A fixed name list let
  /// `onLongPressGesture` through (#3385 overnight evasion pass, 2026-10-05).
  static func isPressHandler(_ name: String) -> Bool {
    name.lowercased().contains("gesture") || name.hasPrefix("onTap") || name.hasPrefix("onLongPress")
  }

  static func references(_ name: String, in node: some SyntaxProtocol) -> Bool {
    node.tokens(viewMode: .sourceAccurate).contains {
      $0.tokenKind == .identifier(name) && $0.parent?.is(DeclReferenceExprSyntax.self) == true
    }
  }

  static func argument(_ label: String, of call: FunctionCallExprSyntax) -> String? {
    call.arguments.first { $0.label?.text == label }?.expression.trimmedDescription
  }

  static func closureStatements(_ label: String, of call: FunctionCallExprSyntax) -> [String] {
    call.arguments.first { $0.label?.text == label }?.expression.as(ClosureExprSyntax.self)?
      .statements.map { $0.item.trimmedDescription } ?? []
  }
}
