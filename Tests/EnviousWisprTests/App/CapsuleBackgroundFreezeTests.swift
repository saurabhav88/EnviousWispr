import AppKit
import SwiftParser
import SwiftSyntax
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
    try read(at: RepoRoot.url.appending(path: path), naming: path)
  }

  /// Split from `read(_:)` so `anEmptyMemberIsRefused` can hand it a file it made
  /// itself. Nothing else about the refusal changes: this is where the throw
  /// lives, and it is the one the count-based guards go through.
  private static func read(at url: URL, naming path: String) throws -> String {
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

  /// **The fail-closed read, which nothing exercised until #2380.**
  ///
  /// Every count in this file goes through `read`. An empty or missing member
  /// makes each of them read LOW, and low is exactly what a deleted literal
  /// produces — so without the throw the two failures are indistinguishable, and
  /// the suite reports the wrong one. That is why the migration was written to
  /// refuse rather than to contribute zero.
  ///
  /// **Asserts the THROW, never a count.** Observing a count here would pass for
  /// the wrong reason: zero occurrences is the very thing being disambiguated.
  ///
  /// Both halves, because they fail differently. An EMPTY file reaches our own
  /// refusal; a MISSING one never gets past `String(contentsOf:)`, and a guard
  /// that only ever saw the second would not prove the first exists.
  @Test("an empty or missing source member is refused, never counted as zero")
  func anEmptyMemberIsRefused() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "ew-2380-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let blank = dir.appending(path: "Blank.swift")
    try "   \n\t\n".write(to: blank, atomically: true, encoding: .utf8)
    #expect(throws: CapsuleFreezeSourceError.self) {
      _ = try Self.read(at: blank, naming: "Blank.swift")
    }

    let absent = dir.appending(path: "NeverWritten.swift")
    #expect(throws: (any Error).self) {
      _ = try Self.read(at: absent, naming: "NeverWritten.swift")
    }

    // The two-way half: a member with content comes back, so the refusal above
    // is about emptiness rather than about this helper refusing everything.
    let real = dir.appending(path: "Real.swift")
    try "struct S {}\n".write(to: real, atomically: true, encoding: .utf8)
    #expect(try Self.read(at: real, naming: "Real.swift").contains("struct S"))
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

  /// **Which DECLARATION owns each literal, which the count above cannot say.**
  ///
  /// #2380. `capsuleLiteralsAreFrozen` counts across an aggregate of two files and
  /// asserts a total, so a literal that LEAVES its intended declaration while
  /// another occurrence appears anywhere else in those files leaves the count
  /// unchanged and the suite green. That is this suite's own recorded defect one
  /// level up: counting fixed the two-copies case and not the which-declaration
  /// case.
  ///
  /// Read off the SYNTAX TREE rather than the balanced brace walk #2380 proposed.
  /// A walk is a second implementation of something the parser already knows, and
  /// this suite has been bitten twice by text-shaped boundaries — a
  /// `hasPrefix("private struct DistressCapsuleBackground")` sentinel that stopped
  /// existing when #2374 widened the type to `internal`, and the whole-file
  /// `contains` before it.
  ///
  /// The notice literal's owner is `PillInk`, not `RecordingOverlayView` as #2380
  /// describes it. Tighter, and checked rather than transcribed.
  nonisolated static let literalOwners:
    [(what: String, declaration: String, expected: Int, path: String, literal: String)] = [
      (
        "capsule fill", "OverlayCapsuleBackground", 1, capsuleSourcePaths[0],
        "Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82)"
      ),
      (
        "capsule fill", "DistressCapsuleBackground", 1, capsuleSourcePaths[0],
        "Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82)"
      ),
      (
        "capsule border", "OverlayCapsuleBackground", 1, capsuleSourcePaths[0],
        "Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)"
      ),
      (
        "capsule notice text", "PillInk", 1, capsuleSourcePaths[1],
        "Color.white.opacity(0.95)"
      ),
    ]

  /// One named `struct` or `enum` declaration's own source, or nil.
  ///
  /// Both kinds, because the owners are not all structs — the notice colour lives
  /// on `enum PillInk`. A struct-only finder would have returned nil for it and,
  /// with a `#require` above, failed for the wrong reason.
  /// **CODE ONLY — comments and string contents are removed before counting.**
  ///
  /// `trimmedDescription` preserves both, so a comment documenting the previous
  /// frozen value satisfies the count while the expression it documents is gone —
  /// and a comment reading "was Color(red: 0.078, ...)" is exactly what someone
  /// deleting that colour would leave behind. Found by cloud review on PR #2532.
  ///
  /// Worth naming as a class rather than a one-off: this suite's whole history is
  /// a guard reading more text than it means to. First `contains` over both files,
  /// then a count over both files, now a count over one declaration — and each
  /// time the surplus text is where the false green came from.
  private final class CodeOnly: SyntaxRewriter {
    override func visit(_ token: TokenSyntax) -> TokenSyntax {
      token
        .with(\.leadingTrivia, Self.withoutComments(token.leadingTrivia))
        .with(\.trailingTrivia, Self.withoutComments(token.trailingTrivia))
    }

    /// String CONTENT, blanked. The delimiters stay so the syntax is still legal
    /// to print; only the text a literal could hide inside is dropped.
    override func visit(_ node: StringSegmentSyntax) -> StringSegmentSyntax {
      node.with(\.content, .stringSegment(""))
    }

    static func withoutComments(_ trivia: Trivia) -> Trivia {
      Trivia(
        pieces: trivia.filter { piece in
          switch piece {
          case .lineComment, .blockComment, .docLineComment, .docBlockComment:
            return false
          default:
            return true
          }
        })
    }
  }

  /// The parsed declaration itself, for a caller that needs its BOUNDS rather
  /// than its text. `DeclFinder` below returns comment-stripped source, which is
  /// what the ownership rows want and is useless for locating anything.
  private final class StructLocator: SyntaxVisitor {
    let wanted: String
    private(set) var found: StructDeclSyntax?
    init(_ wanted: String) {
      self.wanted = wanted
      super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      if node.name.text == wanted { found = node }
      return .visitChildren
    }
  }

  private static func structDecl(named: String, in tree: SourceFileSyntax) -> StructDeclSyntax? {
    let locator = StructLocator(named)
    locator.walk(tree)
    return locator.found
  }

  private final class DeclFinder: SyntaxVisitor {
    let wanted: String
    private(set) var found: String?
    init(_ wanted: String) {
      self.wanted = wanted
      super.init(viewMode: .sourceAccurate)
    }
    private func keep(_ node: some SyntaxProtocol) -> String {
      CodeOnly().rewrite(node).trimmedDescription
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      if node.name.text == wanted { found = keep(node) }
      return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
      if node.name.text == wanted { found = keep(node) }
      return .visitChildren
    }
  }

  @Test(
    "each frozen literal is owned by the declaration that is supposed to hold it",
    arguments: CapsuleBackgroundFreezeTests.literalOwners)
  func frozenLiteralsStayInTheirOwnDeclaration(
    entry: (what: String, declaration: String, expected: Int, path: String, literal: String)
  ) throws {
    let finder = DeclFinder(entry.declaration)
    finder.walk(Parser.parse(source: try Self.read(entry.path)))
    let body = try #require(
      finder.found,
      """
      \(entry.declaration) is not a struct or enum in \(entry.path) — this row is \
      pointed at nothing, which is not the same as the literal having moved.
      """)

    let found = body.components(separatedBy: entry.literal).count - 1
    #expect(
      found == entry.expected,
      """
      the \(entry.what) literal appears \(found) times inside \(entry.declaration), \
      expected \(entry.expected). The aggregate count can stay right while this is \
      wrong: a literal that moved OUT of this declaration and reappeared anywhere \
      else in the same two files leaves the total unchanged.
      """)
  }

  /// **Counts occurrences rather than asking whether the literal exists anywhere,
  /// and the mutation control is what found that.** The first version used
  /// `source.contains(...)`. Deleting the capsule fill entirely — the exact leak
  /// this suite exists to catch — left that check GREEN, because
  /// `DistressCapsuleBackground` carries the same literal and the whole-file
  /// search found it there. A guard that reads the whole file cannot tell which
  /// copy it found.
  ///
  /// Kept ALONGSIDE `frozenLiteralsStayInTheirOwnDeclaration` rather than replaced
  /// by it (#2380): the aggregate is a cheap floor that notices a literal vanishing
  /// from the two files entirely, and the ownership row is the sharp edge.
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
  /// reached only from the chrome's `.meterStrip` header case, so every line in it
  /// is gated and none of them says so. Lexical proximity is not the property; reachability is,
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

    // **THE PARSER BOUNDS THE STRUCT. A BRACE WALK USED TO, AND IT WAS EVADABLE.**
    //
    // The old version counted `{` and `}` per line from the struct's declaration
    // and stopped at depth zero, then asserted the landing line was exactly `}`
    // on the grounds that this closed the one SILENT failure — a stray brace in
    // a comment shrinking the region so a later ungated palette read escapes.
    //
    // It did not. Measured on #2380, both directions, source restored byte-exact:
    //
    //   one bare `}` line in a comment, then an ungated read   RED  (landed on "  }")
    //   TWO bare `}` lines in a comment, then an ungated read  GREEN — the read escaped
    //
    // One stray brace cannot reach depth zero from inside `body`, so it lands on
    // an indented line and the equality catches it. Two can, and then the landing
    // line IS `}` and the assertion is satisfied by the very thing it was added
    // to detect. The defence was one character wider than the attack, which is
    // the shape this file has paid for twice already.
    //
    // So the region no longer comes from text. `SwiftParser` knows where a
    // declaration ends, and no amount of punctuation inside a comment moves it.
    // #2380 asked for exactly this and said not to make the walk cleverer at
    // counting braces, because that is the same comparison one character wider
    // again.
    //
    // The per-read CONTEXT check below is still text proximity, and that is a
    // separate weakness #2380 names and holds out of this row deliberately: it
    // needs reachability rather than a wider match, and folding it in here would
    // mix a fix with a redesign.
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: Self.capsuleSourcePaths[0], tree: tree)
    let decl = try #require(
      Self.structDecl(named: "OverlayCapsuleBackground", in: tree),
      "OverlayCapsuleBackground not found — this guard is pointed at nothing")
    // Zero-based, to index `lines` the way the brace walk's values did.
    //
    // **`position` INCLUDES the leading trivia, so it is the wrong end of the
    // declaration.** For this file it resolves to line 4 — the top of the struct's
    // doc comment — while `struct OverlayCapsuleBackground` is on line 10. That
    // widens the region upward, and a doc or MARK comment above the struct that
    // mentions `PreviewPillPalette.` would then be counted as a palette read and
    // judged for gating. Cloud review caught it on #2380; the failure is in the
    // direction that ACCUSES correct code.
    //
    // `positionAfterSkippingLeadingTrivia` and `endPositionBeforeTrailingTrivia`
    // are the declaration itself, which is what this guard is a claim about.
    let open = converter.location(for: decl.positionAfterSkippingLeadingTrivia).line - 1
    let close = converter.location(for: decl.endPositionBeforeTrailingTrivia).line - 1

    // The bound is now a claim, so it is checked: the region must START on the
    // struct's own declaration line. A parser that ever handed back trivia again
    // would say so here rather than silently widening the scan.
    #expect(
      lines[open].contains("struct OverlayCapsuleBackground"),
      """
      the region starts on \(lines[open].trimmingCharacters(in: .whitespaces)), not on \
      OverlayCapsuleBackground's own declaration line, so it is scanning text that is \
      not the struct.
      """)

    #expect(
      open < close && close < lines.count,
      "the parsed bounds of OverlayCapsuleBackground are \(open)...\(close), which cannot index its own source"
    )

    // **REACHABILITY, not text proximity** (#2536).
    //
    // This used to join the four lines around each read and accept the presence of
    // `isPreview` or `case .rounded` anywhere in them. Those are raw source lines,
    // so a COMMENT mentioning either phrase satisfied it: the real gate could be
    // deleted and the words left nearby, and the check passed.
    //
    // #2380 named that as its own weakness and held it out of the region fix
    // deliberately, because a wider or cleverer string match is the same defect one
    // character along — the shape this file has now paid for four times.
    //
    // So the question is asked of the SYNTAX TREE instead: is this read inside the
    // preview branch? A read is gated when one of its ANCESTORS is either the
    // ternary whose condition names `isPreview`, or the `case .rounded` of a switch.
    // A comment is trivia and cannot be an ancestor, so the class disappears rather
    // than narrowing. Both conditions are read through `CodeOnly`, so a comment
    // inside the condition itself cannot satisfy them either.
    let ungated = Self.ungatedPaletteReads(in: decl, converter: converter)
    #expect(
      ungated.isEmpty,
      """
      OverlayCapsuleBackground reads the preview palette outside its preview branch \
      at \(ungated.joined(separator: "; ")). That struct paints seven pills that are \
      not the preview.
      """)

    let reads = Self.paletteReads(in: decl).count
    #expect(
      reads >= 2,
      """
      only \(reads) palette reads inside OverlayCapsuleBackground. The gate check \
      passes vacuously with nothing to gate, so this pins that the preview branch \
      really is wired to the palette.
      """)
  }

  // MARK: - Spelling normalisers, in ONE place
  //
  // **Three review rounds on this guard have been SPELLING, not meaning.** A
  // comment satisfying a text match; a condition negated; a case consolidated; a
  // module qualifier; a pair of parentheses. Renderings the compiler treats as one
  // thing, matched separately at each site, are how a guard grows a new hole every
  // round — so they are normalised HERE and nowhere else.
  //
  // **Round 4 falsified the previous closure, and the way it failed is the point.**
  // That paragraph claimed parentheses were unwrapped; they were unwrapped on the
  // CONDITION only, so `(PreviewPillPalette).surface` walked straight through. A
  // normaliser applied at one of its two sites is not a normaliser — it is the
  // per-site matching this section exists to replace, one indirection further in.
  //
  // **So the base is no longer RENDERED TO TEXT at all.** Rendering asks what the
  // source looks like, which is the question with infinitely many answers;
  // `declName` / `baseName` asks which identifier is written, which is the question
  // the compiler answers and has exactly one. Parentheses, module qualifiers and
  // comments are all trivia or wrappers around that token and cannot reach it.
  //
  // **The closure, so it is falsifiable rather than hopeful:** a next finding here
  // has to be a spelling whose *written identifier* is not `PreviewPillPalette` and
  // which still reads the palette. That is name resolution — a `typealias`, a local
  // binding, an `import` alias — which no syntax test can do and which this guard
  // has always declared out of scope. A finding INSIDE the scope means this
  // paragraph is wrong, not that another case needs adding.

  /// Whether an expression names `PreviewPillPalette`, however it is written.
  ///
  /// `nonisolated` because the visitor that calls it is not on the main actor;
  /// nothing here touches actor state.
  ///
  /// `EnviousWisprAppKit.PreviewPillPalette.surface` and `(PreviewPillPalette).surface`
  /// are the same read as `PreviewPillPalette.surface`. Only the written identifier
  /// decides, so it is taken from the node rather than from the rendered source.
  nonisolated private static func namesThePalette(_ base: ExprSyntax?) -> Bool {
    guard let base else { return false }
    let bare = unparenthesised(base)
    let written =
      bare.as(MemberAccessExprSyntax.self)?.declName.baseName.text
      ?? bare.as(DeclReferenceExprSyntax.self)?.baseName.text
    return written == "PreviewPillPalette"
  }

  /// An expression with its redundant parentheses removed.
  ///
  /// `(isPreview) ? …` gates exactly as `isPreview ? …` does, and rejecting it
  /// would accuse correct code — the direction that trains bypasses.
  ///
  /// Used by BOTH sites, which is what round 4 established: applied to only one of
  /// them it is per-site matching wearing a normaliser's name.
  nonisolated private static func unparenthesised(_ expr: ExprSyntax) -> ExprSyntax {
    var current = expr
    while let tuple = current.as(TupleExprSyntax.self),
      tuple.elements.count == 1,
      tuple.elements.first?.label == nil,
      let inner = tuple.elements.first?.expression
    {
      current = inner
    }
    return current
  }

  /// Every `PreviewPillPalette.…` read inside a declaration, as syntax rather
  /// than as matching text.
  private final class PaletteReadFinder: SyntaxVisitor {
    private(set) var reads: [MemberAccessExprSyntax] = []
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
      if CapsuleBackgroundFreezeTests.namesThePalette(node.base) { reads.append(node) }
      return .visitChildren
    }
  }

  private static func paletteReads(in decl: StructDeclSyntax) -> [MemberAccessExprSyntax] {
    let finder = PaletteReadFinder(viewMode: .sourceAccurate)
    finder.walk(decl)
    return finder.reads
  }

  /// Whether a node sits inside the preview branch.
  ///
  /// **An ANCESTOR, which a comment can never be.** The two shipped gates are the
  /// ternary on `isPreview` and the `case .rounded` of the corner-style switch, so
  /// a read is gated exactly when one of those encloses it. Both are read through
  /// `CodeOnly`, so a comment inside a condition cannot satisfy the check either.
  private static func isInsideThePreviewBranch(_ node: some SyntaxProtocol) -> Bool {
    var current = Syntax(node).parent
    while let here = current {
      // **`SwiftParser` does not FOLD operators, so there is no `TernaryExprSyntax`
      // in this tree.** `a ? b : c` arrives as a `SequenceExprSyntax` whose elements
      // are the condition, an `UnresolvedTernaryExprSyntax` holding the THEN branch,
      // and the else branch. Looking for a folded ternary found nothing and reported
      // the shipped, correctly-gated read as ungated — caught on the first run.
      //
      // Matching the UNRESOLVED node is also more precise than matching a folded
      // one: a read in the THEN branch is INSIDE it, while a read in the else branch
      // is a sibling after it. So the else branch — the shipped default that paints
      // seven pills — is correctly refused rather than accepted for sharing a
      // ternary with the preview.
      //
      // The parent of the unresolved ternary is an `ExprListSyntax`, not the
      // sequence itself — measured, after a version that went one level short
      // reported the shipped, correctly-gated read as ungated.
      //
      // **The condition must BE `isPreview`, not merely contain it.** A version
      // that asked whether the condition text contained the word accepted
      // `!isPreview ? PreviewPillPalette.surface : …`, where the then branch is the
      // NON-preview one — cloud review, and it is this guard's own defect class
      // arriving one level in: reachability replaced the proximity match, and the
      // condition itself was still being read as text. A bare
      // `DeclReferenceExprSyntax` cannot be negated or compounded, so there is
      // nothing left to spell around.
      if here.is(UnresolvedTernaryExprSyntax.self),
        let sequence = here.parent?.parent?.as(SequenceExprSyntax.self),
        sequence.elements.first.map(unparenthesised)?
          .as(DeclReferenceExprSyntax.self)?.baseName.text == "isPreview"
      {
        return true
      }
      // **EXACTLY ONE case item, and it is `.rounded`.** Asking whether the label
      // contained "rounded" accepted a consolidated `case .capsule, .rounded:`,
      // which is reachable for every non-preview capsule — same finding, same
      // round, same class. Counting the items is what makes it exclusive.
      if let switchCase = here.as(SwitchCaseSyntax.self),
        case .case(let label) = switchCase.label,
        label.caseItems.count == 1,
        label.caseItems.first?.pattern.trimmedDescription == ".rounded"
      {
        return true
      }
      current = here.parent
    }
    return false
  }

  /// The palette reads that are NOT inside the preview branch, named by line.
  private static func ungatedPaletteReads(
    in decl: StructDeclSyntax, converter: SourceLocationConverter
  ) -> [String] {
    paletteReads(in: decl)
      .filter { !isInsideThePreviewBranch($0) }
      .map {
        "line \(converter.location(for: $0.positionAfterSkippingLeadingTrivia).line): \($0.trimmedDescription)"
      }
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
