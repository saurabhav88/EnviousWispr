import AppKit
import SwiftUI
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #3385: the real expanded choice cards remain readable and their footer action
/// remains a separate target. Frames cover layout; live presses remain Claude's UAT.
@MainActor
@Suite("Shared engine card layout", .tags(.productOutcome))
struct SharedEngineCardLayoutTests {
  init() { _ = NSApplication.shared }

  @Test("expanded engine choices and their footer stay contained at all PR1 widths")
  func choicesStayContained() throws {
    for width: CGFloat in [460, 530, 1010] {
      let frames = try SettingsSummaryCardTests.measure(width: width, expanded: true)
      #expect(frames["choices"] != nil && frames["status"] != nil)
      for (_, frame) in frames { #expect(frame.minX >= 0 && frame.maxX <= width) }
      let footer = try LivePreviewSettingsLayoutTests.frame(width: (width - 12) / 2) { probe in
        EngineCard(icon: "globe", map: .id(.transcriptionEngineAllLanguages), tagline: "For other languages or the toughest audio",
          specs: [("Model", "Whisper Large v3 Turbo"), ("Languages", "99+ languages"),
            ("Runs on", "Apple GPU"), ("Transcribe time", "Usually 1-2s after you speak")],
          isSelected: true, onSelect: {}, footer: {
            SettingsActionButton(title: "Remove", isEnabled: true, emphasis: .quiet,
              shape: .roundedRect, size: .medium, action: {})
              .background(probe).padding(12)
          })
          .environment(\.settingsPR1Density, true)
      }
      print("SHARED-ENGINE width=\(width) footerVisible=true footer=\(footer)")
      #expect(footer.minX >= 0 && footer.maxX <= (width - 12) / 2)
      #expect(footer.width > 50 && footer.height >= 28)
    }
  }
}

@Suite("Shared engine presentation wiring", .tags(.driftGuard))
struct SharedEnginePresentationWiringTests {
  @Test("summary status is referenced once and outside the disclosure condition")
  func statusHasOneStableMount() throws {
    let source = try String(contentsOf: RepoRoot.sourceURL(
      "Sources/EnviousWisprAppKit/Views/Settings/SettingsComponents.swift"), encoding: .utf8)
    let start = try #require(source.range(of: "struct SettingsSummaryCard"))
    let end = try #require(source.range(of: "// MARK: - Settings Content Container", range: start.lowerBound..<source.endIndex))
    let tree = SwiftParser.Parser.parse(source: String(source[start.lowerBound..<end.lowerBound]))
    let bodies = tree.tokens(viewMode: .sourceAccurate).compactMap { token -> SwiftSyntax.AccessorBlockSyntax? in
      // #3482: `body` adds the card's Settings Map registration to `content`, which holds the layout.
      guard token.text == "content", let binding = token.parent?.parent?.as(SwiftSyntax.PatternBindingSyntax.self) else { return nil }
      return binding.accessorBlock
    }
    let body = try #require(bodies.first)
    let references = body.tokens(viewMode: .sourceAccurate).filter { $0.tokenKind == .identifier("status") }
    #expect(references.count == 1)
    for reference in references {
      var parent = reference.parent
      while let node = parent {
        #expect(node.is(SwiftSyntax.IfExprSyntax.self) == false, "status moved behind the disclosure")
        parent = node.parent
      }
    }
  }

  @Test("Fast re-check reads current controller admission and starts no work")
  func fastRecheckIsReadOnly() throws {
    let source = try String(contentsOf: RepoRoot.sourceURL(
      "Sources/EnviousWisprAppKit/App/ModelDeliveryHome.swift"), encoding: .utf8)
    let tree = SwiftParser.Parser.parse(source: source)
    let method = try #require(tree.tokens(viewMode: .sourceAccurate).first {
      $0.text == "currentParakeetAdmission" && $0.parent?.is(SwiftSyntax.FunctionDeclSyntax.self) == true
    }?.parent?.as(SwiftSyntax.FunctionDeclSyntax.self))
    let body = try #require(method.body)
    let tokens = Set(body.tokens(viewMode: .sourceAccurate).map(\.text))
    #expect(tokens.contains("isAdmitted"))
    #expect(tokens.contains("controller"))
    #expect(tokens.isDisjoint(with: ["parakeetState", "selectedInstalled", "ensureAvailable", "resumeParakeetDownload", "downloadModel", "selectedBackend"]))
  }

  @Test("Reset belongs to Auto-detect and keeps its action, help and identity")
  func resetBelongsToAutoDetect() throws {
    let tree = SwiftParser.Parser.parse(source: try String(contentsOf: RepoRoot.sourceURL(
      "Sources/EnviousWisprAppKit/Views/Settings/SpeechEngineSettingsView.swift"), encoding: .utf8))
    let rows = ClipboardSettingsWiringTests.calls(named: "SettingsRow", in: tree)
    let resetRows = rows.filter { row in
      row.tokens(viewMode: .sourceAccurate).contains { $0.text == "resetAllChipState" }
    }
    #expect(resetRows.count == 1)
    let row = try #require(resetRows.first)
    #expect(ClipboardSettingsWiringTests.argument("map", of: row) == ".id(.autoDetectLanguage)")
    #expect(row.tokens(viewMode: .sourceAccurate).contains { $0.text == "suggestionsHelp" })
    #expect(row.tokens(viewMode: .sourceAccurate).contains { $0.text == "accessibilityLabel" })
    let buttons = ClipboardSettingsWiringTests.calls(named: "Button", in: row)
    #expect(buttons.count == 1)
    #expect(buttons.first?.arguments.first?.expression.trimmedDescription == "SettingsItemCopy.Engine.resetSuggestions")
    #expect(ClipboardSettingsWiringTests.calls(named: "SettingsInfoButton", in: row).isEmpty)
    #expect(ClipboardSettingsWiringTests.argument("resolvedHelp", of: row)?.contains("Copy.suggestionsHelp") == true)
  }
}
