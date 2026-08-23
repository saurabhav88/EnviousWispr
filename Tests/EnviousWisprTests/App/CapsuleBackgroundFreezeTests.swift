import AppKit
import Testing

@testable import EnviousWisprAppKit

/// #2204: `OverlayCapsuleBackground`'s NON-preview paint is frozen.
///
/// **This is a Drift Guard, not a Product Outcome, and the distinction is not
/// bookkeeping.** It does not prove the polishing pill looks right; it proves
/// nobody changed it. When it fails, the user sees nothing — we changed our own
/// code. It must never be counted as evidence that any pill renders correctly.
///
/// ## Why it exists anyway
///
/// `OverlayCapsuleBackground` has EIGHT call sites and only one is the preview.
/// The other seven — the polishing pill, the cold-start notice, the distress
/// variant, the notification, import-status, accessibility-toast and recovery
/// pills — ship to EVERY user. The preview ships OFF by default and needs
/// macOS 26+.
///
/// So the leak direction is badly asymmetric: a mistake in the preview's colours
/// is seen by the few who opted in, while a mistake in the shared default is seen
/// by everyone, on surfaces the founder explicitly reserved for a later redesign.
/// And it is invisible to every preview test by construction, because none of them
/// render the capsule.
///
/// ## Why it reads source rather than rendering
///
/// A `Color` literal inside a `View`'s body cannot be interrogated without
/// rendering, and rendering a capsule proves what it looks like today rather than
/// that it is unchanged. Reading the declaration is the only mechanism that
/// answers "is this still what it was" — the same reason
/// `TestInventoryFreezeTests` parses Swift rather than enumerating suites at
/// runtime.
///
/// **Known limit of a text guard, stated rather than discovered later:** it
/// asserts the literals are present, so it catches an edit and cannot catch a
/// change made somewhere else that overrides them. It is a tripwire on the file,
/// not a proof about the pixels.
@MainActor
@Suite(.tags(.driftGuard))
struct CapsuleBackgroundFreezeTests {

  init() { _ = NSApplication.shared }

  private static func overlaySource() throws -> String {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/App/Overlay/Views/OverlayLegacyViews.swift")
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The capsule's own values, exactly as they were before #2204.
  /// Counts MEASURED against the tree at #2204's base, not reasoned about — the
  /// first version guessed 2 for the border and the suite went red on its own
  /// expectation. A drop names a deletion; a rise names a stale list.
  ///
  /// `capsule fill` is 2 because `DistressCapsuleBackground` carries the same
  /// value, which is precisely how the earlier existence check managed to pass
  /// while the capsule's own fill had been deleted. The border is 1 because only
  /// the `.capsule` branch spells it with the `Capsule()` prefix.
  nonisolated static let frozenCapsuleLiterals: [(what: String, expected: Int, literal: String)] = [
    ("capsule fill", 2, "Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82)"),
    ("capsule border", 1, "Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)"),
    ("capsule notice text", 1, "Color.white.opacity(0.95)"),
  ]

  /// **Counts occurrences rather than asking whether the literal exists anywhere,
  /// and the mutation control is what found that.** The first version used
  /// `source.contains(...)`. Deleting the capsule fill entirely — the exact leak
  /// this suite exists to catch — left that check GREEN, because
  /// `DistressCapsuleBackground` carries the same literal and the whole-file
  /// search found it there. A guard that reads the whole file cannot tell which
  /// copy it found.
  @Test(
    "the capsule's own colours are unchanged",
    arguments: CapsuleBackgroundFreezeTests.frozenCapsuleLiterals)
  func capsuleLiteralsAreFrozen(entry: (what: String, expected: Int, literal: String)) throws {
    let source = try Self.overlaySource()
    let found = source.components(separatedBy: entry.literal).count - 1
    #expect(
      found == entry.expected,
      """
      the \(entry.what) literal appears \(found) times, expected \(entry.expected). \
      #2204 is gated to the preview branch; the capsule paint is shared by seven \
      other pills that ship to everyone and is reserved for a separate redesign. A \
      count that DROPPED means one of them lost its colour; a count that ROSE means \
      the freeze list is stale.
      """)
  }

  /// The palette must not be readable from `OverlayCapsuleBackground`'s SHARED
  /// default. That struct is the eight-call-site surface; the rest of the file's
  /// palette reads live in `previewHeader` and `PreviewWellText`, which are
  /// preview-only by CONSTRUCTION rather than by a nearby keyword.
  ///
  /// **The first version of this checked for a gate keyword within six lines of
  /// each palette reference, and it was wrong in the way this repo keeps
  /// recording: a comparison narrower than the language.** `previewHeader` is
  /// reached only from `if usesPreviewLayout`, so every line in it is gated and
  /// none of them says so. Lexical proximity is not the property; reachability is,
  /// and the honest way to check reachability cheaply is to scope the check to the
  /// one type where a leak is possible.
  @Test("the shared capsule background reads the palette only on its preview branch")
  func capsuleBackgroundGatesEveryPaletteRead() throws {
    let source = try Self.overlaySource()
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

    let open = try #require(
      lines.firstIndex { $0.contains("struct OverlayCapsuleBackground") },
      "OverlayCapsuleBackground not found — this guard is pointed at nothing")
    let close = try #require(
      lines[open...].firstIndex { $0.hasPrefix("private struct DistressCapsuleBackground") },
      "could not find the end of OverlayCapsuleBackground")

    var reads = 0
    for i in open..<close where lines[i].contains("PreviewPillPalette.") {
      reads += 1
      let context = lines[max(open, i - 3)...min(close, i + 1)].joined(separator: "\n")
      #expect(
        context.contains("isPreview") || context.contains("case .rounded"),
        """
        line \(i + 1) of OverlayCapsuleBackground reads the preview palette outside \
        its preview branch: \(lines[i].trimmingCharacters(in: .whitespaces)). That \
        struct paints seven pills that are not the preview.
        """)
    }

    #expect(
      reads >= 2,
      """
      only \(reads) palette reads inside OverlayCapsuleBackground. The gate check \
      passes vacuously with nothing to gate, so this pins that the preview branch \
      really is wired to the palette.
      """)
  }

  /// A two-way control: the guard above is worthless if the palette is never
  /// mentioned at all, which would also make every line trivially "gated".
  @Test("the palette is actually used, so the gate check is not vacuous")
  func paletteIsActuallyReferenced() throws {
    let source = try Self.overlaySource()
    let count = source.components(separatedBy: "PreviewPillPalette.").count - 1
    #expect(
      count >= 8,
      """
      only \(count) references to the preview palette in OverlayLegacyViews.swift. \
      The gate check above passes vacuously when there is nothing to gate, so this \
      pins that the wiring is really there.
      """)
  }
}
