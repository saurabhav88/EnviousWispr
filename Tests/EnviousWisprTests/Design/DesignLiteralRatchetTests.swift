import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Stops the app's hand-typed design values from growing (#4506).
///
/// Internal drift protection, not product coverage. DESIGN.md owns the app's colors, fonts and
/// sizes; this suite counts three spellings that bypass it, per file, and compares the counts with
/// `design-literal-baseline.json`:
/// - `radius`: a numeric literal argument labelled `cornerRadius:`
///   (`RoundedRectangle(cornerRadius: 8)`);
/// - `fontSize`: a numeric literal `size:` argument to `.system(...)`
///   (`.font(.system(size: 14))`);
/// - `color`: `Color(red:...)`, `Color(.sRGB, ...)`, `NSColor(red:...)` and
///   `NSColor(srgbRed:...)`.
///
/// A file's count may not rise, and a file not in the baseline must count zero. When a count falls
/// the suite fails and names the number to lower the baseline to, so the baseline only goes down.
/// One file's decrease never offsets another's increase.
///
/// Limits, stated as such: SwiftParser does not resolve types, so a type alias, a contextual
/// `.init(red:...)`, the unlabelled `.cornerRadius(8)` modifier, and swapping one literal for
/// another inside the same file all pass. It is a reminder for the common spellings, not
/// compiler-resolved enforcement. Padding and animation literals are not counted.
///
/// Excluded: the generated token file and the six brand-art owners named in DESIGN.md, whose
/// drawings are made of literal colors and sizes by design.
///
/// To regenerate the baseline (only after a reviewed reduction or with a recorded reason):
///     TEST_RUNNER_EW_WRITE_DESIGN_LITERAL_BASELINE=1 scripts/xcode-test.sh \
///       --filter EnviousWisprTests/DesignLiteralRatchetTests
@Suite(.tags(.driftGuard))
struct DesignLiteralRatchetTests {

  enum Category: String, CaseIterable, Codable, Comparable {
    case radius, fontSize, color
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  typealias Counts = [Category: Int]

  static let excluded: Set<String> = [
    "Sources/EnviousWisprAppKit/Views/Design/DesignTokens.generated.swift",
    "Sources/EnviousWisprAppKit/Views/Settings/WisprLogoMark.swift",
    "Sources/EnviousWisprAppKit/App/Brand/RainbowLipsIcon.swift",
    "Sources/EnviousWisprAppKit/Views/Onboarding/RainbowLipsView.swift",
    "Sources/EnviousWisprAppKit/App/Brand/SpectrumWheelIcon.swift",
    "Sources/EnviousWisprAppKit/App/Overlay/Views/RainbowLevelMeter.swift",
    "Sources/EnviousWisprAppKit/Views/Settings/RecordingChimeWaveform.swift",
  ]

  static let baselineURL = RepoRoot.url.appending(
    path: "Tests/EnviousWisprTests/Design/design-literal-baseline.json")

  // MARK: - Scanner

  final class LiteralCounter: SyntaxVisitor {
    var counts: Counts = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    static func isNumeric(_ expression: ExprSyntax) -> Bool {
      expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self)
    }

    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
      if node.label?.text == "cornerRadius", Self.isNumeric(node.expression) {
        counts[.radius, default: 0] += 1
      }
      return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      let arguments = Array(node.arguments)
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "system",
        arguments.contains(where: { $0.label?.text == "size" && Self.isNumeric($0.expression) })
      {
        counts[.fontSize, default: 0] += 1
      }
      if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
        let first = arguments.first
      {
        let name = callee.baseName.text
        let label = first.label?.text
        let isSRGBSpace =
          label == nil
          && first.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "sRGB"
        if (name == "Color" && (label == "red" || isSRGBSpace))
          || (name == "NSColor" && (label == "red" || label == "srgbRed"))
        {
          counts[.color, default: 0] += 1
        }
      }
      return .visitChildren
    }
  }

  static func count(_ tree: some SyntaxProtocol) -> Counts {
    let counter = LiteralCounter()
    counter.walk(tree)
    return counter.counts.filter { $0.value > 0 }
  }

  static func count(source: String) -> Counts {
    count(CachedSwiftParser.parse(source: source))
  }

  struct ScanError: Error, CustomStringConvertible {
    let description: String
  }

  /// Every Swift file under `Sources/`, keyed by repo-relative path. Throws rather than returning
  /// an empty or partial answer.
  static func scanSources() throws -> (counts: [String: Counts], files: Int) {
    let root = RepoRoot.url.appending(path: "Sources")
    let rootPath = RepoRoot.url.path + "/"
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey],
        errorHandler: { url, error in
          Issue.record("cannot enumerate \(url.path): \(error)")
          return false
        })
    else { throw ScanError(description: "cannot enumerate \(root.path)") }

    var result: [String: Counts] = [:]
    var files = 0
    var excludedSeen: Set<String> = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let path = url.path
      guard path.hasPrefix(rootPath) else {
        throw ScanError(description: "\(path) is outside \(rootPath)")
      }
      let relative = String(path.dropFirst(rootPath.count))
      if excluded.contains(relative) {
        excludedSeen.insert(relative)
        continue
      }
      files += 1
      let snapshot = try CachedSwiftParser.snapshot(at: url)
      if snapshot.tree.hasError {
        throw ScanError(description: "\(relative) does not parse")
      }
      let counts = count(snapshot.tree)
      if !counts.isEmpty { result[relative] = counts }
    }
    let missing = excluded.subtracting(excludedSeen)
    if !missing.isEmpty {
      throw ScanError(description: "excluded files no longer exist: \(missing.sorted())")
    }
    return (result, files)
  }

  // MARK: - Baseline comparison

  struct Baseline: Codable, Equatable {
    var total: [String: Int]
    var files: [String: [String: Int]]
  }

  static func baseline(from counts: [String: Counts]) -> Baseline {
    var total: [String: Int] = [:]
    var files: [String: [String: Int]] = [:]
    for (path, fileCounts) in counts {
      for (category, value) in fileCounts {
        files[path, default: [:]][category.rawValue] = value
        total[category.rawValue, default: 0] += value
      }
    }
    return Baseline(total: total, files: files)
  }

  /// Every disagreement between measured counts and the baseline, one line each. Empty means the
  /// tree matches the baseline exactly.
  static func compare(_ measured: [String: Counts], with baseline: Baseline) -> [String] {
    var problems: [String] = []
    let paths = Set(measured.keys).union(baseline.files.keys).sorted()
    for path in paths {
      for category in Category.allCases {
        let actual = measured[path]?[category] ?? 0
        let allowed = baseline.files[path]?[category.rawValue] ?? 0
        if actual > allowed {
          problems.append(
            "\(path): \(actual) raw \(category.rawValue) literal(s), baseline \(allowed). "
              + "Use a DESIGN.md token instead of adding a hand-typed value.")
        } else if actual < allowed {
          problems.append(
            "\(path): \(category.rawValue) fell to \(actual). Lower the baseline to \(actual) "
              + "in design-literal-baseline.json.")
        }
      }
    }
    return problems
  }

  static func encode(_ baseline: Baseline) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(baseline) + Data("\n".utf8)
  }

  // MARK: - The real tree

  @Test("no Swift file under Sources/ adds a hand-typed corner size, font size or color")
  func sourcesMatchTheBaseline() throws {
    let scan = try Self.scanSources()
    let measured = Self.baseline(from: scan.counts)
    let hits = measured.total.values.reduce(0, +)
    print(
      "DESIGN LITERALS: \(scan.files) files scanned, \(scan.counts.count) with hits, "
        + "\(hits) hits \(measured.total.sorted { $0.key < $1.key })")
    #expect(scan.files > 100, "suspiciously few Swift files scanned: \(scan.files)")
    #expect(hits > 0, "zero hits: the scanner is not seeing the source")

    if ProcessInfo.processInfo.environment["EW_WRITE_DESIGN_LITERAL_BASELINE"] == "1" {
      try Self.encode(measured).write(to: Self.baselineURL)
      Issue.record("wrote \(Self.baselineURL.path); rerun without the variable to compare")
      return
    }

    let data = try Data(contentsOf: Self.baselineURL)
    let baseline = try JSONDecoder().decode(Baseline.self, from: data)
    let problems = Self.compare(scan.counts, with: baseline)
    #expect(problems.isEmpty, "\(["", problems.joined(separator: "\n")].joined(separator: "\n"))")
  }

  // MARK: - Controls (same scanner and comparison path)

  @Test("each counted spelling is found, and lookalikes are not")
  func scannerCountsTheApprovedSpellings() {
    let counted = Self.count(
      source: """
        let a = RoundedRectangle(cornerRadius: 8)
        let b = RoundedRectangle(cornerRadius: 9.5, style: .continuous)
        let c = Text("x").font(.system(size: 14, weight: .semibold))
        let d = Font.system(size: 12)
        let e = Color(red: 1, green: 0, blue: 0)
        let f = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        let g = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        let h = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        """)
    #expect(counted == [.radius: 2, .fontSize: 2, .color: 4])

    let ignored = Self.count(
      source: """
        // RoundedRectangle(cornerRadius: 8) and Color(red: 1, green: 0, blue: 0) in a comment
        let s = "RoundedRectangle(cornerRadius: 8) .system(size: 14)"
        let t = RoundedRectangle(cornerRadius: DesignRadius.md)
        let u = Font.system(size: DesignSpacing.md)
        let v = Color(white: 0.5)
        let w = NSColor(name: nil) { _ in .black }
        let x = Text("x").font(.stBody)
        """)
    #expect(ignored.isEmpty, "counted a lookalike: \(ignored)")
  }

  @Test("a raised count, a new file and a lowered count all fail with the file named")
  func comparisonFailsInEveryDirection() {
    let baseline = Self.baseline(from: ["Sources/A.swift": [.radius: 2, .color: 1]])

    #expect(Self.compare(["Sources/A.swift": [.radius: 2, .color: 1]], with: baseline).isEmpty)

    let raised = Self.compare(["Sources/A.swift": [.radius: 3, .color: 1]], with: baseline)
    #expect(raised.count == 1 && raised[0].contains("Sources/A.swift: 3 raw radius"))

    let newFile = Self.compare(
      ["Sources/A.swift": [.radius: 2, .color: 1], "Sources/B.swift": [.fontSize: 1]],
      with: baseline)
    #expect(newFile.count == 1 && newFile[0].contains("Sources/B.swift: 1 raw fontSize"))

    let lowered = Self.compare(["Sources/A.swift": [.radius: 1, .color: 1]], with: baseline)
    #expect(lowered.count == 1 && lowered[0].contains("Lower the baseline to 1"))

    let offset = Self.compare(
      ["Sources/A.swift": [.radius: 1, .color: 1], "Sources/C.swift": [.radius: 1]],
      with: baseline)
    #expect(offset.count == 2, "a decrease in one file must not hide an increase in another")
  }

  @Test("one added raw radius in a real file fails the real comparison")
  func addingARadiusToARealFileFails() throws {
    let scan = try Self.scanSources()
    let baseline = Self.baseline(from: scan.counts)
    #expect(Self.compare(scan.counts, with: baseline).isEmpty)

    let path = "Sources/EnviousWisprAppKit/Views/Settings/SettingsComponents.swift"
    let source = try String(
      contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8)
    var mutated = scan.counts
    mutated[path] = Self.count(
      source: source + "\nlet ratchetControl = RoundedRectangle(cornerRadius: 3)\n")
    let problems = Self.compare(mutated, with: baseline)
    #expect(problems.count == 1 && problems[0].hasPrefix("\(path): "), "\(problems)")
  }
}
