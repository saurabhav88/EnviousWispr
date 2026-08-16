import Foundation
import Testing

// MARK: - EscapeRecoveryBoundaryFreezeTests (#2087)
//
// Escape Recovery's architecture rests on one boundary claim: the kernel owns
// what a finalizing session IS (`FinalizationDisposition`), and AppKit never
// learns it. AppKit gets a single narrow capability instead —
// `KernelDictationDriver.isEscapeRecoveryTranscribing` — so policy code asks
// "may the cancel affordance stay live", never "which disposition is this".
//
// That claim is free to state and easy to break silently. Adding `public` to the
// enum, or referencing it from one AppKit file, costs nothing at the keyboard and
// is invisible in review once the feature is large. Both are caught here.
//
// Why it matters beyond tidiness: the disposition is a THREE-case identity whose
// third case (`.abandonedEscapeRecovery`) exists to keep the kernel busy while a
// non-preemptible decode finishes. An AppKit consumer branching on that identity
// would be making engine-lifetime decisions from outside the engine, which is the
// hazard the whole chunked build exists to avoid.
//
// Two invariants, both fail-closed on a count:
//   1. `FinalizationDisposition` has exactly ONE declaration, and it is not
//      `public`. A count of 0 means a rename — update this guard in lockstep.
//   2. `FinalizationDisposition` appears nowhere under
//      `Sources/EnviousWisprAppKit/`.
//
// Known blind spot, named not fixed: a wrapper type in Pipeline that re-exposes
// the same three-way identity publicly under another name would satisfy both
// invariants. The covering layers are the public-surface review on each chunk and
// the fact that `isEscapeRecoveryTranscribing` is the only capability any AppKit
// consumer has been given a reason to want.

@Suite struct EscapeRecoveryBoundaryFreezeTests {

  /// The `enum` keyword precedes the name only at the declaration; a usage such
  /// as `FinalizationDisposition.ordinary` is never preceded by `enum`.
  private static let declaration = #"\benum\s+FinalizationDisposition\b"#
  /// A `public`/`package`/`open` modifier immediately before that declaration.
  private static let publicDeclaration =
    #"\b(public|package|open)\s+enum\s+FinalizationDisposition\b"#
  private static let anyMention = #"\bFinalizationDisposition\b"#

  // MARK: 1 — one declaration, and it stays internal

  @Test("FinalizationDisposition has exactly one declaration")
  func singleDeclaration() throws {
    let hits = try Self.scan(root: "Sources", pattern: Self.declaration)
    #expect(
      hits.count == 1,
      """
      Expected exactly ONE `enum FinalizationDisposition` declaration, found \(hits.count):
      \(hits.joined(separator: "\n"))
      A count of 0 means the enum was renamed — update this guard in lockstep.
      A count above 1 means a second session-identity authority exists, which is
      the divergence #2087 chunk 2 already paid for once.
      """)
  }

  @Test("FinalizationDisposition is not published outside Pipeline")
  func declarationIsNotPublic() throws {
    let hits = try Self.scan(root: "Sources", pattern: Self.publicDeclaration)
    #expect(
      hits.isEmpty,
      """
      `FinalizationDisposition` is declared with a widened access level:
      \(hits.joined(separator: "\n"))
      It is deliberately internal to EnviousWisprPipeline. AppKit needs the
      capability `KernelDictationDriver.isEscapeRecoveryTranscribing`, not the
      identity. If a consumer genuinely needs more, add another narrow capability
      — do not publish the enum.
      """)
  }

  // MARK: 2 — AppKit never sees the disposition

  @Test("no AppKit source references FinalizationDisposition")
  func appKitDoesNotReferenceTheDisposition() throws {
    let hits = try Self.scan(root: "Sources/EnviousWisprAppKit", pattern: Self.anyMention)
    #expect(
      hits.isEmpty,
      """
      AppKit references the kernel's finalization disposition:
      \(hits.joined(separator: "\n"))
      Read `isEscapeRecoveryTranscribing` instead. Branching on the disposition
      from AppKit puts engine-lifetime decisions outside the engine.
      """)
  }

  // MARK: 3 — the matcher itself is exercised, in both directions

  /// A guard that cannot fire is decoration. These prove the patterns match what
  /// they claim and reject what they must not, without touching disk — the
  /// two-way control that separates a working detector from a silent one.
  @Test("the declaration matchers distinguish a declaration from a usage")
  func matchersAreTwoWay() throws {
    let declRegex = try NSRegularExpression(pattern: Self.declaration)
    let publicRegex = try NSRegularExpression(pattern: Self.publicDeclaration)

    func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
      let ns = line as NSString
      return regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    #expect(matches(declRegex, "enum FinalizationDisposition: Equatable, Sendable {"))
    #expect(matches(declRegex, "public enum FinalizationDisposition {"))
    #expect(!matches(declRegex, "    disposition = FinalizationDisposition.ordinary"))
    #expect(!matches(declRegex, "  var disposition: FinalizationDisposition = .ordinary"))

    #expect(matches(publicRegex, "public enum FinalizationDisposition: Equatable {"))
    #expect(matches(publicRegex, "package enum FinalizationDisposition {"))
    #expect(!matches(publicRegex, "enum FinalizationDisposition: Equatable, Sendable {"))
  }

  // MARK: Scanner

  /// Scan `root/**/*.swift` for `pattern`, skipping comment-only lines so the
  /// doc comments that legitimately NAME the enum do not trip the guards.
  private static func scan(root: String, pattern: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let rootURL = RepoRoot.url.appending(path: root)
    let enumerator = FileManager.default.enumerator(
      at: rootURL, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var hits: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let relative = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
      for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        let ns = text as NSString
        if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
          hits.append("\(relative):\(idx + 1): \(trimmed)")
        }
      }
    }
    return hits
  }
}
