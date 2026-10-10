import EnviousWisprCore
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Recording Pill tab's words. Two rows gain a short line and a "?" sentence, and
/// each design card shows its name with one short line under the picture. Expected strings
/// are typed from the approved copy table, not read from the code under test. The card's
/// screen-reader label keeps the design's full summary; `RecordingPillTileTests` owns that.
@Suite("Recording Pill settings copy (#3385)", .tags(.productOutcome))
struct PillSettingsCopyTests {
  typealias Copy = DictationSettingsCopy.Pill

  /// Every `static let` in `DictationSettingsCopy.Pill`, with its approved English.
  static let expected: [String: (LocalizedStringResource, String)] = [
    "positionTitle": (Copy.positionTitle, "Position on screen"),
    "positionShort": (Copy.positionShort, "Where the pill floats while you dictate."),
    "positionHelp": (Copy.positionHelp, "Choose Top or Bottom for the recording pill."),
    "styleTitle": (Copy.styleTitle, "Style"),
    "styleShort": (Copy.styleShort, "What the floating pill shows while you record."),
    "styleHelp": (
      Copy.styleHelp,
      "Capsule and Level Rail show volume. Reading Well shows words and turns Live Preview on."
    ),
    "capsuleShort": (Copy.capsuleShort, "A compact pill with a dot and level meter."),
    "levelRailShort": (Copy.levelRailShort, "A slim rail that follows your volume."),
    "readingWellShort": (Copy.readingWellShort, "Shows words as you speak. Turns Live Preview on."),
  ]

  @Test("every Recording Pill string keeps its approved English")
  func approvedEnglish() {
    for (name, (resource, english)) in Self.expected {
      #expect(String(localized: resource) == english, "\(name)")
    }
  }

  @Test("each design shows its own short line, and every short line fits")
  func shortLinesPerDesign() {
    let byDesign: [RecordingPillDesign: String] = [
      .classic: "A compact pill with a dot and level meter.",
      .levelRail: "A slim rail that follows your volume.",
      .readingWell: "Shows words as you speak. Turns Live Preview on.",
    ]
    #expect(Set(byDesign.keys) == Set(RecordingPillDesign.allCases), "a design has no line")
    for design in RecordingPillDesign.allCases {
      let line = String(localized: Copy.shortDescription(for: design))
      #expect(line == byDesign[design], "\(design) shows \(line)")
      #expect(!line.isEmpty && line.count <= 60, "\(design): \(line.count) characters")
      // The short line is a glance; the full summary is what VoiceOver hears.
      #expect(line != design.summary, "\(design)'s short line repeats its summary")
    }
    for short in [Copy.positionShort, Copy.styleShort] {
      let line = String(localized: short)
      #expect(!line.isEmpty && line.count <= 60, "\(line) is \(line.count) characters")
    }
  }

  /// Names of the `static let`s declared directly inside `enum <name>`.
  static func staticLets(inEnum name: String, source: String) -> Set<String> {
    final class Finder: SyntaxVisitor {
      let name: String
      var found: Set<String> = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == name else { return .visitChildren }
        for member in node.memberBlock.members {
          guard let variable = member.decl.as(VariableDeclSyntax.self),
            variable.modifiers.contains(where: { $0.name.text == "static" })
          else { continue }
          for binding in variable.bindings {
            if let id = binding.pattern.as(IdentifierPatternSyntax.self) {
              found.insert(id.identifier.text)
            }
          }
        }
        return .skipChildren
      }
    }
    let finder = Finder(name: name)
    finder.walk(Parser.parse(source: source))
    return finder.found
  }
}
