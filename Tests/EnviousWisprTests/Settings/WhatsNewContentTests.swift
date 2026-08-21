import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// What's New had NO Swift test coverage before #1493 — its only guard was the
/// weekly `render-release-notes.py --self-test` in ci-drift-check, which is not a
/// per-PR gate. These tests are the Swift-side twin of that self-test: they freeze
/// the invariants the release-notes renderer and the Settings screen both depend on.
@Suite("What's New content")
struct WhatsNewContentTests {

  private struct ReleaseNoteEntry: Codable, Equatable, Sendable {
    let title: String
    let desc: String
    let version: String
  }

  private enum ReleaseNoteDrift: Error {
    case rendererFailed(String)
    case parsedValuesDiffer(
      index: Int, parsed: ReleaseNoteEntry?, compiled: ReleaseNoteEntry?)
  }

  private static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Settings
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }

  private static func parsedReleaseNoteEntries(from swiftFile: URL) throws -> [ReleaseNoteEntry] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "python3",
      repoRoot.appendingPathComponent("scripts/ci/render-release-notes.py").path,
      "--swift-file", swiftFile.path,
      "--dump-json",
    ]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    // Drain while the child runs so a future verbose parser failure cannot fill
    // a pipe and deadlock before `waitUntilExit`.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(data: data, encoding: .utf8) ?? ""
      throw ReleaseNoteDrift.rendererFailed(message)
    }
    return try JSONDecoder().decode([ReleaseNoteEntry].self, from: data)
  }

  private static func requireRendererEquivalence(
    swiftFile: URL, compiledEntries: [ReleaseNoteEntry]
  ) throws {
    let parsedEntries = try parsedReleaseNoteEntries(from: swiftFile)
    guard parsedEntries == compiledEntries else {
      let index = (0..<max(parsedEntries.count, compiledEntries.count)).first {
        parsedEntries.indices.contains($0) && compiledEntries.indices.contains($0)
          ? parsedEntries[$0] != compiledEntries[$0]
          : true
      } ?? 0
      throw ReleaseNoteDrift.parsedValuesDiffer(
        index: index,
        parsed: parsedEntries.indices.contains(index) ? parsedEntries[index] : nil,
        compiled: compiledEntries.indices.contains(index) ? compiledEntries[index] : nil)
    }
  }

  // MARK: - Grouping preserves every entry

  @Test("entriesByVersion drops no entry")
  func groupingDropsNothing() {
    let grouped = WhatsNewContent.entriesByVersion.flatMap(\.entries)
    #expect(grouped.count == WhatsNewContent.entries.count)

    // Not just the count — the same entries, so a filter bug cannot pass by
    // coincidentally swapping one entry for another.
    #expect(Set(grouped.map(\.id)) == Set(WhatsNewContent.entries.map(\.id)))
  }

  @Test("every entry appears under exactly one version group")
  func noEntryDuplicated() {
    let grouped = WhatsNewContent.entriesByVersion.flatMap(\.entries)
    #expect(Set(grouped.map(\.id)).count == grouped.count)
  }

  @Test("entry ids are unique")
  func idsAreUnique() {
    let ids = WhatsNewContent.entries.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  // MARK: - Order is the hierarchy (no category tier rescues it)

  /// Since the category tier was removed, within-version SOURCE ORDER is exactly
  /// what the user reads — in the app and in the generated GitHub release notes.
  /// If this regresses, a release silently stops leading with its headline feature.
  @Test("within a version, entries stay in source order")
  func sourceOrderPreserved() {
    for group in WhatsNewContent.entriesByVersion {
      let expected = WhatsNewContent.entries
        .filter { $0.version == group.version }
        .map(\.id)
      #expect(group.entries.map(\.id) == expected, "v\(group.version) lost source order")
    }
  }

  @Test("versions are newest-first")
  func versionsAreNewestFirst() {
    // Assert the real current sequence. This is deliberately NOT a claim about
    // hypothetical multi-digit components (e.g. 2.3.10 vs 2.3.9): no such version
    // exists in the array, every current component is a single digit, so this data
    // physically cannot distinguish numeric from lexical sorting. The comparator is
    // untouched by #1493; asserting the real sequence is the falsifiable version.
    #expect(
      WhatsNewContent.versions == [
        "2.4.5", "2.4.4", "2.4.3", "2.4.1", "2.4.0",
        "2.3.2", "2.3.1", "2.3.0",
        "2.2.1", "2.2.0",
        "2.1.4", "2.1.3", "2.1.2", "2.1.1", "2.1.0",
        "2.0.3", "2.0.2", "2.0.1", "2.0.0",
        "1.9.4", "1.9.3", "1.9.2", "1.9.1", "1.9.0",
      ])

    #expect(WhatsNewContent.entriesByVersion.map(\.version) == WhatsNewContent.versions)
  }

  // MARK: - Release gate

  /// #2105: the renderer reads source text while the app reads compiled Swift.
  /// Counts and non-empty strings both passed when concatenation truncated a
  /// public release note and interpolation emitted raw Swift syntax. Compare the
  /// actual values on both sides instead, in source order.
  @Test("GitHub release notes parse exactly what the app compiles")
  func releaseNoteRendererMatchesCompiledValues() throws {
    let swiftFile = Self.repoRoot.appendingPathComponent(
      "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift")
    let compiled = WhatsNewContent.entries.map {
      ReleaseNoteEntry(title: $0.title, desc: $0.description, version: $0.version)
    }
    try Self.requireRendererEquivalence(swiftFile: swiftFile, compiledEntries: compiled)
  }

  /// Two-way control for the comparison itself. Both forms still parse as one
  /// non-empty entry, so the old count and completeness checks pass. Only the
  /// parsed-versus-compiled value check rejects them.
  @Test("the renderer comparison rejects shortened or unresolved descriptions")
  func releaseNoteRendererMutationControl() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-2105-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let expected = [ReleaseNoteEntry(title: "Headline", desc: "First second", version: "9.9.9")]
    for (name, description) in [
      ("concatenated", #""First " + "second""#),
      ("interpolated", #""First \(word)""#),
    ] {
      let fixture = directory.appendingPathComponent("\(name).swift")
      try """
      Entry(
        title: "Headline",
        description: \(description),
        version: "9.9.9"
      )
      """.write(to: fixture, atomically: true, encoding: .utf8)

      #expect(
        throws: ReleaseNoteDrift.self,
        "\(name) must disagree with the compiled value even though it still parses"
      ) {
        try Self.requireRendererEquivalence(swiftFile: fixture, compiledEntries: expected)
      }
    }
  }

  /// whats-new-protocol.md RULE: whats-new-release-gate — every release ships notes.
  /// Previously this was only checked by a weekly CI job; now a release that bumps
  /// the content version without writing an entry fails the test suite immediately.
  @Test("the current content version has at least one entry")
  func currentVersionHasEntries() {
    let current = WhatsNewConstants.currentContentVersion
    let entries = WhatsNewContent.entries.filter { $0.version == current }
    #expect(
      !entries.isEmpty,
      "currentContentVersion is \(current) but no What's New entry ships for it")
  }

  @Test("the newest version group IS the current content version")
  func newestGroupIsCurrentVersion() {
    #expect(
      WhatsNewContent.entriesByVersion.first?.version == WhatsNewConstants.currentContentVersion)
  }

  // MARK: - Content sanity

  /// The title is now the ONLY header on the card, so an empty one leaves an entry
  /// with no heading at all, and an empty description leaves an empty card.
  @Test("no entry has an empty title, description, or icon")
  func noEmptyFields() {
    for entry in WhatsNewContent.entries {
      #expect(!entry.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id): empty title")
      #expect(
        !entry.description.trimmingCharacters(in: .whitespaces).isEmpty,
        "\(entry.id): empty description")
      #expect(!entry.icon.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id): empty icon")
    }
  }

  /// #1987 — the Globe-key entry, pinned field by field.
  ///
  /// Deliberately NOT covered by `currentVersionHasEntries` above: other 2.4.4
  /// entries are already in the group, so that test passes whether or not this one
  /// exists. Only an exact-ID lookup can tell the difference.
  ///
  /// The description is asserted verbatim because it is founder-approved copy
  /// naming a System Settings route, so a paraphrase sends the user looking for a
  /// menu that is not there.
  ///
  /// Two separate facts, previously conflated here into a causal claim that was
  /// simply false:
  ///
  /// 1. This wording now uses the exact macOS label "Press 🌐 key to", matching
  ///    the help article and the popover. It previously said "Press Globe key to",
  ///    recorded as a copy decision with no rationale beside it while the sentence
  ///    directly above asserted the opposite principle — that a paraphrase sends
  ///    the user looking for a menu that is not there. Three surfaces describe one
  ///    System Settings route and this was the only one paraphrasing it. Changed
  ///    2026-08-09 (v2.4.4). It was never a technical limit: measured the same day
  ///    by putting the symbol in this description and re-running the renderer,
  ///    which parsed all 116 entries and emitted the symbol intact.
  /// 2. `title`, `description`, and `version` must stay direct Swift literals
  ///    rather than shared constants, because `scripts/ci/render-release-notes.py`
  ///    parses the SOURCE TEXT of this file rather than compiled values.
  @Test("the Globe key entry ships in the current version with its approved copy")
  func globeKeyEntryShips() throws {
    let entry = try #require(
      WhatsNewContent.entries.first { $0.id == "globe-key-dictation-hotkey" },
      "the #1987 Globe key entry is missing from What's New")

    #expect(entry.icon == "globe")
    #expect(entry.title == "Use the Globe key, or Fn, as your dictation keybind")
    #expect(
      entry.description
        == "You can now use the Globe key, marked Fn on many Macs, as your dictation keybind. "
        + "Right Option stays exactly as it is unless you choose Globe. If macOS also opens "
        + "emoji, switches your keyboard language, or starts its own dictation when you press "
        + "it, go to System Settings, then Keyboard, then Press 🌐 key to, and choose Do "
        + "Nothing.")

    // Founder amendment 2026-08-09, same reason as the popover: the macOS menu
    // offers three actions and the original copy named two. Membership rather than
    // equality, because the defect being guarded against is a dropped member.
    #expect(entry.description.contains("emoji"))
    #expect(entry.description.contains("keyboard language"))
    #expect(entry.description.contains("its own dictation"))
    // Pinned to the release it actually shipped in, NOT to `currentContentVersion`.
    // Those two agreed only while 2.4.4 was the open group, so the second assertion was
    // guaranteed to break the moment any later work opened a new one — as 2.4.5 just
    // did. The durable claim is which release the copy shipped in; coupling a shipped
    // entry to "whatever is current" expires every release by construction.
    #expect(entry.version == "2.4.4")
  }
}
