import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Clipboard tab's four switches are shared rows, each wired to its own setting,
/// in two headed sections: the three recording-scoped settings under CLIPBOARD with the
/// next-recording note, and Quick Add under its own heading with no note. Read from the source
/// with SwiftParser; comments, strings and stray calls cannot satisfy it. A drift guard: real
/// toggles, persistence and clipboard outcomes are final Live UAT.
@Suite("Clipboard settings wiring (#3385)", .tags(.driftGuard))
struct ClipboardSettingsWiringTests {
  static let path = "Sources/EnviousWisprAppKit/Views/Settings/ClipboardSettingsView.swift"

  static func tree() throws -> SourceFileSyntax {
    Parser.parse(
      source: try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8))
  }

  struct Row: Equatable, CustomStringConvertible {
    var icon = ""
    var title = ""
    var short = ""
    var help = ""
    var toggles = 0
    var toggleTitle = ""
    var binding = ""
    var modifiers: [String] = []
    /// Each modifier's arguments, in the same order as `modifiers`.
    var modifierArguments: [[String]] = []
    var accessibilityLabel = ""
    /// The heading call that precedes this row's section in the page, and its note.
    var sectionHeading = ""
    var sectionNote = ""
    var description: String {
      "\(title) [\(binding)] mods=\(modifiers) a11y=\(accessibilityLabel) under \(sectionHeading) note=\(sectionNote)"
    }
  }

  /// Every `SettingsRow(...)` in the file, in source order.
  static func rows(in tree: SourceFileSyntax) -> [Row] {
    calls(named: "SettingsRow", in: tree).map { call in
      var row = Row()
      row.icon = argument("icon", of: call) ?? ""
      // #3482: a mapped row names itself by its Settings Map id; fixtures may still use title:.
      row.title = argument("map", of: call) ?? argument("title", of: call) ?? ""
      row.short = argument("short", of: call) ?? ""
      row.help = argument("help", of: call) ?? ""
      let toggles = call.trailingClosure.map { calls(named: "Toggle", in: $0) } ?? []
      row.toggles = toggles.count
      if let toggle = toggles.first {
        row.toggleTitle =
          toggle.arguments.first { $0.label == nil }?.expression.trimmedDescription ?? ""
        row.binding = argument("isOn", of: toggle) ?? ""
        var current = Syntax(toggle)
        while let member = current.parent?.as(MemberAccessExprSyntax.self),
          let outer = member.parent?.as(FunctionCallExprSyntax.self)
        {
          let name = member.declName.baseName.text
          row.modifiers.append(name)
          row.modifierArguments.append(outer.arguments.map { $0.expression.trimmedDescription })
          if name == "accessibilityLabel" {
            row.accessibilityLabel = outer.arguments.first?.expression.trimmedDescription ?? ""
          }
          current = Syntax(outer)
        }
      }
      (row.sectionHeading, row.sectionNote) = heading(above: call)
      return row
    }
  }

  /// The `SettingsSectionHeading` statement nearest before the `BrandedSection` holding `node`,
  /// among the page's statements, with the expression its note `Text` shows ("" when none).
  static func heading(above node: some SyntaxProtocol) -> (String, String) {
    var current: Syntax? = Syntax(node)
    while let syntax = current {
      if let call = syntax.as(FunctionCallExprSyntax.self),
        call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "BrandedSection",
        let item = call.parent?.as(CodeBlockItemSyntax.self),
        let list = item.parent?.as(CodeBlockItemListSyntax.self)
      {
        let before = list.prefix { $0.id != item.id }
        for candidate in before.reversed() {
          guard let heading = candidate.item.as(FunctionCallExprSyntax.self),
            heading.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
              == "SettingsSectionHeading"
          else { continue }
          let title =
            argument("map", of: heading) ?? argument("resolvedTitle", of: heading)
            ?? argument("title", of: heading) ?? ""
          let note =
            heading.trailingClosure.flatMap { calls(named: "Text", in: $0).first }?
            .arguments.first?.expression.trimmedDescription ?? ""
          return (title, note)
        }
        return ("", "")
      }
      current = syntax.parent
    }
    return ("", "")
  }

  /// The `isOn:` binding of every `Toggle(...)` in `ClipboardSettingsView`, inside a shared row
  /// or not, in source order.
  static func allToggleBindings(in tree: SourceFileSyntax) -> [String] {
    let view = tree.statements.compactMap { $0.item.as(StructDeclSyntax.self) }
      .first { $0.name.text == "ClipboardSettingsView" }
    return view.map { calls(named: "Toggle", in: $0).map { argument("isOn", of: $0) ?? "" } } ?? []
  }

  static let toggleModifiers = ["labelsHidden", "toggleStyle", "fixedSize", "accessibilityLabel"]
  static let clipboardHeading = ".id(.sectionClipboard)"
  static let note = "DictationSettingsCopy.Engine.nextRecordingNote"

  static func expectedRow(
    _ icon: String, _ name: String, map: String, binding: String, quickAdd: Bool = false
  ) -> Row {
    Row(
      // #3482: the short line is the map node's description, checked in `shortLinesFromTheMap`.
      icon: "\"\(icon)\"", title: ".id(.\(map))", short: "",
      help: "Copy.\(name)Help", toggles: 1, toggleTitle: "\"\"", binding: binding,
      modifiers: toggleModifiers,
      modifierArguments: [[], ["BrandedToggleStyle()"], [], ["Text(Copy.\(name)Title)"]],
      accessibilityLabel: "Text(Copy.\(name)Title)",
      sectionHeading: quickAdd
        ? ".id(.sectionQuickAddClipboard)" : clipboardHeading,
      sectionNote: quickAdd ? "" : note)
  }

  @Test("four rows, each with its own copy, icon, setting and an unlabeled fixed-size switch")
  func fourRowsWiredToTheirOwnSettings() throws {
    let rows = Self.rows(in: try Self.tree())
    let expected = [
      Self.expectedRow(
        "doc.on.clipboard", "autoCopy", map: "autoCopyToClipboard",
        binding: "$settings.autoCopyToClipboard"),
      Self.expectedRow(
        "arrow.uturn.backward", "restore", map: "restoreClipboard",
        binding: "$settings.restoreClipboardAfterPaste"),
      Self.expectedRow(
        "text.cursor", "smartInsertion", map: "smartInsertion", binding: "$settings.smartInsertion"),
      Self.expectedRow(
        "text.viewfinder", "quickAdd", map: "quickAddClipboardFallback",
        binding: "$settings.quickAddClipboardFallback",
        quickAdd: true),
    ]
    #expect(rows.count == 4, "\(rows.count) rows: \(rows)")
    #expect(
      Self.allToggleBindings(in: try Self.tree())
        == [
          "$settings.autoCopyToClipboard", "$settings.restoreClipboardAfterPaste",
          "$settings.smartInsertion", "$settings.quickAddClipboardFallback",
        ], "the page holds a switch outside the four rows, or lost one")
    for (row, want) in zip(rows, expected) {
      #expect(row == want, "got \(row)\nwant \(want)")
    }
  }

  @Test("each row's short line is its own copy, read from its Settings Map node")
  func shortLinesFromTheMap() {
    let expected: [(SettingsMapID, LocalizedStringResource)] = [
      (.autoCopyToClipboard, DictationSettingsCopy.Clipboard.autoCopyShort),
      (.restoreClipboard, DictationSettingsCopy.Clipboard.restoreShort),
      (.smartInsertion, DictationSettingsCopy.Clipboard.smartInsertionShort),
      (.quickAddClipboardFallback, DictationSettingsCopy.Clipboard.quickAddShort),
    ]
    for (id, copy) in expected {
      #expect(SettingsMapRef.id(id).shortLine == String(localized: copy), "\(id.rawValue)")
    }
  }

  @Test("the page has exactly two headed sections, the note only on Clipboard")
  func twoSections() throws {
    let tree = try Self.tree()
    let headings = Self.calls(named: "SettingsSectionHeading", in: tree)
    #expect(headings.count == 2)
    #expect(Self.calls(named: "BrandedSection", in: tree).count == 2)
    let notes = headings.map {
      $0.trailingClosure.flatMap { Self.calls(named: "Text", in: $0).first }?
        .arguments.first?.expression.trimmedDescription ?? ""
    }
    #expect(notes == [Self.note, ""], "\(notes)")
    #expect(
      Self.calls(named: "FrozenPerRecordingFootnote", in: tree).isEmpty, "the old footnote is back")
  }

  @Test("a switch outside the rows, a no-op fixedSize or a swapped style is seen")
  func toggleControls() {
    let fixture = Parser.parse(
      source: """
        struct ClipboardSettingsView: View {
          var body: some View {
            SettingsContentView {
              SettingsRow(icon: "a", title: Copy.smartInsertionTitle, short: X, help: Y) {
                Toggle("", isOn: $settings.smartInsertion)
                  .labelsHidden().toggleStyle(.switch).fixedSize(horizontal: false, vertical: false)
              }
              Toggle("Duplicate Smart insertion", isOn: $settings.smartInsertion)
            }
          }
        }
        """)
    #expect(
      Self.allToggleBindings(in: fixture) == ["$settings.smartInsertion", "$settings.smartInsertion"])
    let row = Self.rows(in: fixture).first
    #expect(row?.modifierArguments == [[], [".switch"], ["false", "false"]])
  }

  @Test("a swapped binding, a duplicate row, or Quick Add inside the noted section is seen")
  func extractorControls() {
    let fixture = Parser.parse(
      source: """
        SettingsContentView {
          SettingsSectionHeading(resolvedTitle: A) { Text(DictationSettingsCopy.Engine.nextRecordingNote) }
          BrandedSection {
            SettingsRow(icon: "a", title: Copy.autoCopyTitle, short: Copy.autoCopyShort, help: Copy.autoCopyHelp) {
              Toggle("", isOn: $settings.restoreClipboardAfterPaste).labelsHidden()
            }
            SettingsRow(icon: "b", title: Copy.smartInsertionTitle, short: X, help: Y) {
              Toggle("Smart insertion", isOn: $settings.smartInsertion)
            }
            SettingsRow(icon: "c", title: Copy.smartInsertionTitle, short: X, help: Y) {
              Toggle("", isOn: $settings.smartInsertion)
            }
            SettingsRow(icon: "d", title: Copy.quickAddTitle, short: X, help: Y) {
              Toggle("", isOn: $settings.quickAddClipboardFallback)
            }
          }
          // SettingsRow(icon: "e", title: Copy.restoreTitle)
        }
        """)
    let rows = Self.rows(in: fixture)
    #expect(rows.count == 4)
    #expect(rows.first?.binding == "$settings.restoreClipboardAfterPaste")
    #expect(rows.first?.modifiers == ["labelsHidden"])
    #expect(rows.filter { $0.title == "Copy.smartInsertionTitle" }.count == 2)
    #expect(rows[1].toggleTitle == "\"Smart insertion\"")
    #expect(rows.last?.sectionNote == Self.note, "Quick Add read as outside the noted section")
    #expect(rows.last?.sectionHeading == "A")
  }

  // MARK: - Shared extractors

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

  static func argument(_ label: String, of call: FunctionCallExprSyntax) -> String? {
    call.arguments.first { $0.label?.text == label }?.expression.trimmedDescription
  }
}
