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
/// ## Why an EXPLICIT file set rather than one file or a directory glob
///
/// #2374 Phase 2 split `OverlayLegacyViews.swift` into thirteen files. The three
/// frozen literals did not travel together: the fill and border live in
/// `OverlayCapsuleBackgrounds.swift`, while the notice-text literal has always
/// been inside `RecordingOverlayView`. Pointing this guard at one file would make
/// a frozen count read 0 and invite lowering it — which deletes the coverage the
/// guard exists to provide.
///
/// A glob over `Overlay/Views/` would be worse in the other direction: an
/// unrelated future declaration could satisfy a frozen count after the intended
/// literal disappeared, which is the same vacuity this suite was rewritten to
/// close, one level up. The set therefore names exactly the two files that own a
/// frozen literal, and **fails closed** if either is missing or empty.
///
/// **Known limit of a text guard, stated rather than discovered later:** it
/// asserts the literals are present, so it catches an edit and cannot catch a
/// change made somewhere else that overrides them. It is a tripwire on the file,
/// not a proof about the pixels.
@MainActor
@Suite(.tags(.driftGuard))
struct CapsuleBackgroundFreezeTests {

  init() { _ = NSApplication.shared }

  /// The only two files that own a frozen literal. Explicit, never a glob.
  nonisolated static let capsuleSourcePaths = [
    "Sources/EnviousWisprAppKit/App/Overlay/Views/OverlayCapsuleBackgrounds.swift",
    "Sources/EnviousWisprAppKit/App/Overlay/Views/RecordingOverlayView.swift",
  ]

  private static func read(_ path: String) throws -> String {
    let url = RepoRoot.url.appending(path: path)
    let text = try String(contentsOf: url, encoding: .utf8)
    // Fails closed: an empty or unreadable member makes every count below read
    // low, which is indistinguishable from a deleted literal.
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CapsuleFreezeSourceError.empty(path)
    }
    return text
  }

  /// The two-file set, concatenated. Used by the count-based guards.
  private static func capsuleSources() throws -> String {
    try capsuleSourcePaths.map { try read($0) }.joined(separator: "\n")
  }

  /// `OverlayCapsuleBackground`'s own file, and only it. The gating check is a
  /// claim about that one struct's branches; widening its input is what would
  /// make it vacuous.
  private static func capsuleBackgroundSource() throws -> String {
    try read(capsuleSourcePaths[0])
  }

  enum CapsuleFreezeSourceError: Error, CustomStringConvertible {
    case empty(String)
    var description: String {
      switch self {
      case .empty(let path):
        return "\(path) is missing or empty — this guard is pointed at nothing"
      }
    }
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
  ///
  /// Every expectation below is UNCHANGED across the #2374 split. Only the source
  /// the guard reads changed; if a number here ever moves in a relocation commit,
  /// that is the finding.
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
    let source = try Self.capsuleSources()
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
  /// default. That struct is the eight-call-site surface; the rest of the
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
  ///
  /// **The struct's end is found by a balanced brace walk, not by the next
  /// declaration's text.** The previous sentinel was
  /// `hasPrefix("private struct DistressCapsuleBackground")`, and #2374 widened
  /// that type to `internal` — so the sentinel string stopped existing and the
  /// guard would have reported the struct as unfindable rather than as changed. A
  /// brace walk asks the language's own question and cannot be broken by an access
  /// keyword, a rename of the following type, or a reordering.
  @Test("the shared capsule background reads the palette only on its preview branch")
  func capsuleBackgroundGatesEveryPaletteRead() throws {
    let source = try Self.capsuleBackgroundSource()
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

    let open = try #require(
      lines.firstIndex { $0.contains("struct OverlayCapsuleBackground") },
      "OverlayCapsuleBackground not found — this guard is pointed at nothing")

    var depth = 0
    var end: Int? = nil
    for i in open..<lines.count {
      depth += lines[i].filter { $0 == "{" }.count
      depth -= lines[i].filter { $0 == "}" }.count
      if depth == 0 && i > open {
        end = i
        break
      }
    }
    let close = try #require(
      end,
      "OverlayCapsuleBackground's braces never balance — the guard cannot bound the struct")

    // The walk counts braces textually, so a stray brace inside a comment or a
    // string literal could land it somewhere other than the struct's own closing
    // line. Measured on this file today: zero braces in comments or strings, no
    // `#if`, no interpolation — so this is a bound on a hypothetical, not a fix
    // for an observed defect. It is here because ONE of the walk's failure modes
    // is silent: an unmatched `}` in a comment placed AFTER both palette reads
    // would shrink the region without moving `reads` below 2, so an ungated read
    // added later would escape. The other two modes (never balancing, balancing
    // early enough to drop `reads`) already fail loudly. Requiring the landing
    // line to be a top-level closing brace closes the silent one and cannot be
    // broken by reindentation, unlike a frozen source-text match.
    #expect(
      lines[close] == "}",
      """
      the brace walk ended on \(lines[close].trimmingCharacters(in: .whitespaces)), \
      not on OverlayCapsuleBackground's own closing brace. A stray brace in a comment \
      or string literal has moved the region this guard checks.
      """)

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
    let source = try Self.capsuleSources()
    let count = source.components(separatedBy: "PreviewPillPalette.").count - 1
    #expect(
      count >= 8,
      """
      only \(count) references to the preview palette across \
      \(Self.capsuleSourcePaths.count) capsule source files. The gate check above \
      passes vacuously when there is nothing to gate, so this pins that the wiring \
      is really there.
      """)
  }
}
