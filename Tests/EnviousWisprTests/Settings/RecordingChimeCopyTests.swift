import EnviousWisprCore
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Chimes tab's words. The heading, switch title, short line, the line above the
/// cards and IN USE are new; the switch's "?" sentence and the unavailable reason are the
/// sentences the page showed before; the twelve chimes keep their names, descriptions and
/// order. Expected strings are typed from the approved copy table and the pre-#3385 source.
@Suite("Recording chime copy (#3385)", .tags(.productOutcome))
struct RecordingChimeCopyTests {
  typealias Copy = DictationSettingsCopy.Chimes

  static let expected: [String: (LocalizedStringResource, String)] = [
    "sectionHeading": (Copy.sectionHeading, "RECORDING CHIMES"),
    "toggleTitle": (Copy.toggleTitle, "Play recording chimes"),
    "toggleShort": (Copy.toggleShort, "Plays a short chime when recording starts and stops."),
    "toggleHelp": (
      Copy.toggleHelp,
      "Plays a short sound when recording starts and stops. People nearby may hear it."
    ),
    "previewExplanation": (
      Copy.previewExplanation, "Hear this chime without changing your choice."
    ),
    "previewUnavailable": (
      Copy.previewUnavailable, "Preview is unavailable while a recording is in progress."
    ),
    "inUse": (Copy.inUse, "IN USE"),
  ]

  @Test("every Chimes string keeps its approved English, and the short lines fit")
  func approvedEnglish() {
    for (name, (resource, english)) in Self.expected {
      #expect(String(localized: resource) == english, "\(name)")
    }
    for short in [Copy.toggleShort, Copy.previewExplanation] {
      let line = String(localized: short)
      #expect(!line.isEmpty && line.count <= 60, "\(line) is \(line.count) characters")
    }
  }

  @Test("the twelve chimes keep their names, descriptions and order")
  func catalogUnchanged() {
    let expected: [(RecordingSoundPairing, String, String)] = [
      (.dustMote, "Dust Mote", "Soft filtered air, no tone."),
      (.velvetHush, "Velvet Hush", "Two close tones, gentle warmth."),
      (.mutedConfirm, "Muted Confirm", "Same pitch both ways, plain."),
      (.whisperTick, "Whisper Tick", "Barely-there tick."),
      (.roundPebble, "Round Pebble", "Rounded, no edge."),
      (.paperTap, "Paper Tap", "Soft paper-like tap."),
      (.softHush, "Soft Hush", "Slow fade, like a breath."),
      (.lowNod, "Low Nod", "Low, warm, unhurried."),
      (.cloudPop, "Cloud Pop", "Tiny filtered-air pop."),
      (.velvetTap, "Velvet Tap", "Muted, compact tap."),
      (.satinShift, "Satin Shift", "Smooth two-tone shift."),
      (.airGlint, "Air Glint", "Clean, airy glint."),
    ]
    #expect(
      RecordingSoundPairing.allCases == expected.map(\.0), "catalog order or membership moved")
    for (pairing, name, description) in expected {
      #expect(RecordingChimeCatalog.name(for: pairing) == name)
      #expect(RecordingChimeCatalog.description(for: pairing) == description)
    }
  }

  @Test("the test lists every Chimes string, and the page uses every one")
  func everyStringIsCoveredAndUsed() throws {
    let copySource = try String(
      contentsOf: RepoRoot.url.appending(
        path: "Sources/EnviousWisprAppKit/Views/Settings/DictationSettingsCopy.swift"),
      encoding: .utf8)
    let declared = PillSettingsCopyTests.staticLets(inEnum: "Chimes", source: copySource)
    #expect(declared.count >= 7, "parsed \(declared.count); the enum has moved")
    #expect(declared == Set(Self.expected.keys), "declared \(declared.sorted())")

    let page = Parser.parse(
      source: try String(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprAppKit/Views/Settings/RecordingChimesContent.swift"),
        encoding: .utf8))
    let used = Self.members(of: ["Copy", "DictationSettingsCopy.Chimes"], in: page)
    #expect(used.count > 0, "no Chimes copy read from the page; the reader has stopped matching")
    let unused = declared.subtracting(used).sorted()
    #expect(unused.isEmpty, "declared but not shown on the page: \(unused)")
  }

  @Test("a member read through the alias or the full name is seen, and a comment is not")
  func memberReaderControl() {
    let fixture = Parser.parse(
      source: """
        // Copy.ghost
        let a = Copy.sectionHeading
        let b = DictationSettingsCopy.Chimes.inUse
        let c = Other.toggleTitle
        """)
    #expect(
      Self.members(of: ["Copy", "DictationSettingsCopy.Chimes"], in: fixture) == [
        "sectionHeading", "inUse",
      ])
  }

  /// Names read as `<base>.<name>` for any of `bases`, from real member accesses only.
  static func members(of bases: Set<String>, in tree: SourceFileSyntax) -> Set<String> {
    final class Finder: SyntaxVisitor {
      let bases: Set<String>
      var found: Set<String> = []
      init(bases: Set<String>) {
        self.bases = bases
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base?.trimmedDescription, bases.contains(base) {
          found.insert(node.declName.baseName.text)
        }
        return .visitChildren
      }
    }
    let finder = Finder(bases: bases)
    finder.walk(tree)
    return finder.found
  }
}
