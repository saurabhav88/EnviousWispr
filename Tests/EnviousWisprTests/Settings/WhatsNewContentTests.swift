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
        "2.4.0",
        "2.3.2", "2.3.1", "2.3.0",
        "2.2.1", "2.2.0",
        "2.1.4", "2.1.3", "2.1.2", "2.1.1", "2.1.0",
        "2.0.3", "2.0.2", "2.0.1", "2.0.0",
        "1.9.4", "1.9.3", "1.9.2", "1.9.1", "1.9.0",
      ])

    #expect(WhatsNewContent.entriesByVersion.map(\.version) == WhatsNewContent.versions)
  }

  // MARK: - Release gate

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
}
