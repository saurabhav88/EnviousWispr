import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// The settings window draws its own controls, and this suite freezes the two
/// facts that made it stop doing so.
///
/// **Why a source scan and not a UI test.** Hover is a runtime state of a
/// SwiftUI view with no headless harness in this tree, so nothing here claims a
/// pointer produced a colour. What it CAN hold is the structural precondition
/// underneath: that the settings surfaces use the app's own control rather than
/// a system button style whose rendering depends on which container it lands in.
///
/// **The regression is measured, not hypothetical (#2436, #2445, #2447).**
/// `.borderedProminent` renders accent-filled inside a sheet and plain grey on a
/// settings page, in the same build, from the same modifier. Seventeen call
/// sites carried a system style; on the pages, they rendered as the same grey
/// this app uses for DISABLED, on rows whose only action they were. The founder
/// found them by using the app -- every one had a clean build and a green suite.
///
/// Class: `driftGuard`. When this fails, nobody's dictation breaks; a settings
/// button starts depending on its container again.
@Suite("Settings controls own their own affordance (#2447)", .tags(.driftGuard))
struct SettingsControlAffordanceTests {

  private final class AccessibilityLabelFinder: SyntaxVisitor {
    private(set) var calls: [FunctionCallExprSyntax] = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
        == "accessibilityLabel"
      {
        calls.append(node)
      }
      return .visitChildren
    }
  }

  private static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Architecture
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }

  /// Every `.swift` under the settings view directory, with its repo-relative path.
  ///
  /// **Fails closed.** An empty or unreadable directory would otherwise make
  /// every assertion below vacuously true, which is the shape where a guard
  /// stops guarding without anything going red.
  private static func settingsSources() throws -> [(path: String, text: String)] {
    let dir = repoRoot.appendingPathComponent("Sources/EnviousWisprAppKit/Views/Settings")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".swift") }
      .sorted()
    let files = try names.map { name -> (String, String) in
      let url = dir.appendingPathComponent(name)
      return ("Sources/EnviousWisprAppKit/Views/Settings/\(name)", try String(contentsOf: url, encoding: .utf8))
    }
    #expect(files.count > 20, "settings source scan found \(files.count) files; the directory moved")
    return files
  }

  /// The system button styles whose appearance is a property of the CONTAINER
  /// rather than of the control.
  ///
  /// `.plain` and `.borderless` are deliberately NOT here: both render exactly
  /// what the call site draws, which is the opposite problem, and both are used
  /// correctly throughout for hand-drawn cards and rows.
  private static let containerDependentStyles = [
    "buttonStyle(.borderedProminent)",
    "buttonStyle(.bordered)",
  ]

  @Test("No settings surface uses a container-dependent button style")
  func settingsAvoidsContainerDependentButtonStyles() throws {
    var offenders: [String] = []
    for file in try Self.settingsSources() {
      for (index, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        for style in Self.containerDependentStyles where line.contains(style) {
          offenders.append("\(file.path):\(index + 1) \(style)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      Use `SettingsActionButton`, which owns its fill, border, hover and disabled \
      state, so the appearance travels with the control instead of with its \
      container. Offenders:
      \(offenders.joined(separator: "\n"))
      """)
  }

  /// A two-way control on the scanner itself.
  ///
  /// Without this, a pattern that matched nothing and a directory that resolved
  /// nowhere both report the same clean green as a genuinely clean tree. This
  /// asserts the detector finds a string it is pointed at, using the ONE file
  /// that is guaranteed to contain it: this test's own source, which spells the
  /// pattern out in `containerDependentStyles` above.
  @Test("The style scanner can actually find a match")
  func scannerFindsAKnownOccurrence() throws {
    let ownSource = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
    for style in Self.containerDependentStyles {
      #expect(
        ownSource.contains(style),
        "scanner pattern \(style) did not match its own literal; the detector is broken")
    }
  }

  /// Hover is DERIVED at render time, never stored by an `onHover` closure.
  ///
  /// **Round one of review found hover ignoring a parent's `.disabled(...)`.
  /// Round two found the same defect one layer down, in the fix: SwiftUI emits
  /// `onHover` only when the pointer CROSSES the boundary, so a control that
  /// disables while the pointer is already inside it never gets a second event
  /// and a stored `true` keeps advertising it.** Storing the answer is the
  /// defect; storing the pointer POSITION and asking
  /// `SettingsHover.respondsToPointer` at render time is the fix, because the
  /// answer then follows `isEnabled` with no event required.
  ///
  /// So the invariant is narrow and mechanical: **no `onHover` closure in the
  /// settings window assigns to `hovering`.** A closure that does has stored an
  /// answer that can go stale.
  ///
  /// **This test parses the whole closure, and the reason is worth keeping.**
  /// Its first version matched a single LINE containing both `.onHover` and the
  /// assignment, and passed -- while every modifier this change added uses the
  /// multiline form and would have sailed through a raw assignment untouched.
  /// The two-way control run against it proved only the shape that was injected,
  /// which was the single-line one. A detector and its control can agree with
  /// each other and both miss the code (review r2, #2447).
  @Test("No settings onHover closure stores a hover answer")
  func hoverIsDerivedRatherThanStored() throws {
    var offenders: [String] = []
    for file in try Self.settingsSources() {
      for (line, body) in Self.onHoverClosures(in: file.text) {
        if body.contains("hovering =") || body.contains("hovering=") {
          offenders.append("\(file.path):\(line)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      Store the pointer POSITION and derive `hovering` in a computed property \
      via `SettingsHover.respondsToPointer(_:_:_:)`; a stored answer cannot \
      follow a control that disables under a stationary pointer. Offenders:
      \(offenders.joined(separator: "\n"))
      """)
  }

  /// Every `.onHover` closure in a file, as (1-indexed opening line, closure body).
  ///
  /// Brace-counted from the closure's opening `{` rather than line-matched, so
  /// the single-line and multiline forms are read identically. String literals
  /// and comments are not excluded: a brace inside either would mis-slice, and
  /// the failure direction is a LONGER body, which over-reports rather than
  /// under-reports. That is the right way round for a guard.
  private static func onHoverClosures(in text: String) -> [(line: Int, body: String)] {
    let chars = Array(text)
    var results: [(Int, String)] = []
    var index = 0
    let needle = Array(".onHover")
    while index < chars.count - needle.count {
      guard Array(chars[index..<(index + needle.count)]) == needle else {
        index += 1
        continue
      }
      var cursor = index + needle.count
      while cursor < chars.count, chars[cursor] != "{", chars[cursor] != "\n" { cursor += 1 }
      guard cursor < chars.count, chars[cursor] == "{" else {
        index += needle.count
        continue
      }
      var depth = 0
      let bodyStart = cursor
      while cursor < chars.count {
        if chars[cursor] == "{" { depth += 1 }
        if chars[cursor] == "}" {
          depth -= 1
          if depth == 0 { break }
        }
        cursor += 1
      }
      let line = chars[0..<index].filter { $0 == "\n" }.count + 1
      results.append((line, String(chars[bodyStart...min(cursor, chars.count - 1)])))
      index = cursor
    }
    return results
  }

  @Test("The Live Preview language control announces its provenance")
  func livePreviewLanguageAccessibilityKeepsTheProvenance() throws {
    let file = try #require(
      try Self.settingsSources().first { $0.path.hasSuffix("LivePreviewSettingsView.swift") },
      "LivePreviewSettingsView.swift is absent from the settings source scan")
    let finder = AccessibilityLabelFinder(viewMode: .sourceAccurate)
    finder.walk(Parser.parse(source: file.text))
    let labels = finder.calls.compactMap { call -> StringLiteralExprSyntax? in
      guard let literal = call.arguments.first?.expression.as(StringLiteralExprSyntax.self),
        literal.trimmedDescription.contains("Change dictation language:")
      else { return nil }
      return literal
    }
    let label = try #require(
      labels.count == 1 ? labels.first : nil,
      "found \(labels.count) language-control accessibility labels")

    #expect(
      label.trimmedDescription.contains(#"\(language.name)"#)
        && label.trimmedDescription.contains(#"\(language.provenance)"#),
      """
      The language button's explicit accessibility label no longer includes the \
      same provenance a sighted user reads. An explicit label replaces its child \
      announcement, so omitting that value makes VoiceOver lose the distinction \
      between a Mac-chosen language and one the user picked.
      """)
  }

  /// A keyboard shortcut is never applied to the OUTSIDE of `SettingsActionButton`.
  ///
  /// **The failure this catches is silent in the one direction that matters.**
  /// `SettingsActionButton` is a composite `View`, not a control, and it binds
  /// its own `shortcut` to the `Button` inside. A caller that writes
  /// `.keyboardShortcut` on the outside instead is relying on behaviour Apple
  /// documents for "the modified control", and the button still works when
  /// CLICKED -- so a sheet can stop answering Escape with nothing on screen to
  /// say so. Two #2445 footers were doing exactly this and were found by review,
  /// not by use.
  @Test("Keyboard shortcuts reach the control, not the wrapper")
  func shortcutsArePassedRatherThanApplied() throws {
    var offenders: [String] = []
    for file in try Self.settingsSources() {
      let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      for (index, line) in lines.enumerated() where line.contains(".keyboardShortcut(") {
        // Walk back to the nearest line that opens a control, and report only
        // when that opener is this composite. A raw `Button` is the correct and
        // common case, and must not be flagged.
        for back in stride(from: index, through: max(0, index - 12), by: -1) {
          let candidate = lines[back]
          if candidate.contains("SettingsActionButton(") {
            offenders.append("\(file.path):\(index + 1)")
            break
          }
          if candidate.contains("Button(") || candidate.contains("Button<") { break }
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      Pass the shortcut as `SettingsActionButton(..., shortcut: .cancelAction)` \
      so it binds to the `Button` inside. Offenders:
      \(offenders.joined(separator: "\n"))
      """)
  }
}
