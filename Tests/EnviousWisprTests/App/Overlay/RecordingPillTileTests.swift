import AppKit
import EnviousWisprCore
import Foundation
import SwiftParser
import SwiftSyntax
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// The Appearance picker draws each pill instead of describing it (#2435).
///
/// **Product Outcome.** When these fail, a user picking a recording pill is
/// looking at the wrong picture, an empty box, or a preview that says nothing to
/// a screen reader — and picks by guessing, which is the failure the whole change
/// exists to remove.
///
/// **Every size assertion here is a RELATION between two measurements taken in
/// one process, never a frozen point value.** The 2026-08-25 lesson from #2376
/// Phase 4 is that an absolute rendered size is a reading of one Mac's font
/// metrics: the suite went Debug-green and CI-red on exactly that. Differences
/// and orderings survive a different machine; numbers do not.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingPillTileTests {

  init() { _ = NSApplication.shared }

  /// The tile as the settings page builds it, measured unconstrained so it
  /// reports what it ideally wants.
  private static func tileSize(_ design: RecordingPillDesign) -> CGSize {
    let tile = RecordingPillPreviewTile(
      design: design, isSelected: false, isEnabled: true, onSelect: {})
    let host = NSHostingView(rootView: AnyView(tile))
    let frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return host.fittingSize
  }

  /// **The oracle the tile did not write.** `RenderedPillHarness` measures the
  /// recording leaf directly, through the leaf's own height callback, with no
  /// tile involved. The sample display comes from the tile so both sides are
  /// looking at the same picture — that is the INPUT, not the thing under test.
  private static func leafHeight(_ design: RecordingPillDesign) throws -> CGFloat {
    try RenderedPillHarness.recordingContentHeight(
      design: design,
      display: RecordingPillPreviewTile.sampleDisplay(for: design),
      width: design.width)
  }

  // MARK: - The tile renders the real pill

  /// **The strong one: the tile's height tracks the LEAF's height exactly.**
  ///
  /// Stated as a difference so the tile's own padding cancels out of both sides.
  /// A tile that drew a placeholder, an empty box, or another design's chrome
  /// would have a height unrelated to what the leaf reports for itself, and no
  /// absolute constant is involved on either side.
  @Test(
    "each tile is as tall as the pill inside it",
    arguments: [RecordingPillDesign.levelRail, RecordingPillDesign.readingWell])
  func tileHeightTracksTheLeaf(design: RecordingPillDesign) throws {
    let baseline = RecordingPillDesign.classic

    let tileDelta = Self.tileSize(design).height - Self.tileSize(baseline).height
    let leafDelta = try Self.leafHeight(design) - Self.leafHeight(baseline)

    // Equality, with no tolerance: the tile's padding cancels algebraically from
    // both sides of one in-process comparison, so a tolerance would only be a
    // number nobody measured.
    #expect(
      tileDelta == leafDelta,
      """
      the \(design) tile is \(tileDelta)pt taller than the \(baseline) tile while the \
      PILLS differ by \(leafDelta)pt. The tile is not sized by the pill it contains, so \
      it is drawing something else.
      """)
  }

  /// **The two wordless designs are the same height, because they are the same
  /// chrome.** A tile that routed one of them through the reading well's layout
  /// would differ here, and the difference is what no static mock could catch.
  @Test("the two wordless pills give tiles of equal height")
  func wordlessTilesAgree() {
    let capsule = Self.tileSize(.classic).height
    let rail = Self.tileSize(.levelRail).height

    #expect(capsule > 0 && rail > 0, "measured \(capsule)/\(rail): nothing rendered, which is not a pass")
    #expect(
      capsule == rail,
      "the capsule tile is \(capsule)pt and the level rail tile is \(rail)pt, so one of them is not the pill it claims")
  }

  /// **The reading well ends up taller, which is a FINAL geometry outcome and not
  /// a claim about the first frame.**
  ///
  /// This row was first named for `initialPreview:` seeding, and it cannot prove
  /// that: the leaf's first asynchronous provider read can win before
  /// `fittingSize` is sampled, so an unseeded tile measures tall here too. What
  /// it does prove is that the design which shows your words renders visibly more
  /// than one that cannot, which a placeholder-sized well would fail.
  ///
  /// The seeding has no rendered observable at all, so it is covered structurally
  /// by `RecordingPillPreviewWiringTests` below.
  @Test("the rendered reading well tile is taller than a wordless tile")
  func theReadingWellRendersTaller() {
    let well = Self.tileSize(.readingWell).height
    let capsule = Self.tileSize(.classic).height

    #expect(
      well > capsule,
      """
      the reading well tile is \(well)pt against a \(capsule)pt capsule tile, so the \
      design that shows your words as you speak is drawn no larger than one that cannot.
      """)
  }

  /// Each design asks for its own width, so no two tiles are interchangeable.
  @Test("no two tiles are the same width")
  func tileWidthsAreDistinct() {
    let widths = RecordingPillDesign.allCases.map { Self.tileSize($0).width }
    #expect(widths.allSatisfy { $0 > 0 }, "measured \(widths): nothing rendered")
    #expect(
      Set(widths).count == widths.count,
      "two tiles measured the same width \(widths), so the picker shows one design twice")
  }

  /// **Every tile asks for its design's DECLARED width, and the excess over that
  /// is one constant shared by all three.**
  ///
  /// Cloud review on #2439 raised the reading well overflowing a narrow window.
  /// This is the half that can be measured rather than argued: the tile's ideal
  /// width is the design's own `width` plus a padding that does not vary by
  /// design. Whether the containing window can ever be narrower than that is a
  /// Live UAT row, and the horizontal scroll fallback is what keeps it from
  /// clipping when it is.
  @Test("a tile asks for its design's declared width plus a shared padding")
  func tileWidthIsTheDesignWidthPlusOnePadding() {
    let overheads = RecordingPillDesign.allCases.map {
      Self.tileSize($0).width - $0.width
    }

    #expect(
      overheads.allSatisfy { $0 > 0 },
      """
      measured overheads \(overheads). A tile no wider than its design's declared width \
      has no padding at all, which means the pill is touching the tile's border.
      """)
    #expect(
      Set(overheads).count == 1,
      """
      the three tiles add \(overheads) to their designs' widths. They share one padding \
      constant, so a difference means a tile is sized by something other than the pill \
      inside it.
      """)
  }

  /// **The page refuses to be narrower than its widest pill.**
  ///
  /// Rendered at a 380 point content width the reading well was CUT OFF: a grid
  /// column cannot shrink below its content and the tile clips its own, so there
  /// is no width at which a too-narrow layout degrades gracefully. The panel
  /// therefore carries a minimum that propagates to the window.
  ///
  /// Asserted as a RELATION against the tile's own width, so no point value is
  /// frozen. What this does NOT prove is that the WINDOW honours it — that is a
  /// Live UAT row, dragging the real window narrow.
  @Test("the picker will not lay out narrower than its widest pill")
  func thePanelRefusesToClipItsWidestPill() {
    let widest = RecordingPillDesign.allCases
      .filter(\.canHoldWords)
      .map(RecordingPillPreviewTile.width(for:))
      .max()
    let required = try! #require(widest, "no design can hold words, so this guard has no subject")

    #expect(
      RecordingPillAppearancePanel.widestTile(holdingWords: true) == required,
      """
      the panel sizes its with-words column to \
      \(RecordingPillAppearancePanel.widestTile(holdingWords: true)) while its widest tile \
      needs \(required). A column narrower than its tile clips the pill, because the tile \
      clips its own content.
      """)

    // And the wordless side, which has its own widest design.
    let wordless = RecordingPillDesign.allCases
      .filter { !$0.canHoldWords }
      .map(RecordingPillPreviewTile.width(for:))
      .max()
    if let wordless {
      #expect(
        RecordingPillAppearancePanel.widestTile(holdingWords: false) == wordless,
        "the wordless column is sized to something other than its widest tile")
    }
  }

  // MARK: - What a screen reader gets

  /// **The words that left the screen have to arrive somewhere, and the LABEL is
  /// the only channel a macOS user cannot switch off.**
  ///
  /// VoiceOver Utility's Verbosity pane sets hints and extra content to "Do
  /// Nothing", so a design that put the description in either could go silent on
  /// a real reader's machine. WCAG 1.1.1 asks for a text alternative serving an
  /// EQUIVALENT purpose, and once the tile is only a picture, the option's name
  /// alone does not serve it.
  ///
  /// **What this row does NOT prove, stated rather than discovered later:** the
  /// selected VALUE, the `.isSelected` TRAIT and DISABLED reporting are carried
  /// by modifiers on the tile, and a hosted SwiftUI view's accessibility tree is
  /// not readable from a test — measured 2026-08-25 and recorded in
  /// `RenderedPillHarness`. Those three are unchanged from the control this tile
  /// replaces and are confirmed by the VoiceOver pass in Live UAT.
  @Test("every tile announces its name and what it looks like", arguments: RecordingPillDesign.allCases)
  func theLabelCarriesNameAndDescription(design: RecordingPillDesign) {
    let label = RecordingPillPreviewTile.accessibilityLabel(for: design)

    #expect(
      label.contains(design.displayName),
      "the \(design) tile announces \"\(label)\", which does not name the option")
    #expect(
      label.contains(design.summary),
      """
      the \(design) tile announces \"\(label)\", which drops the description. That \
      description is no longer on screen, so a reader who cannot see the picture now \
      gets nothing about what this option looks like.
      """)
  }

  /// **The still pill's meter is DRAWN from this, so it is the picture.**
  ///
  /// Nothing rendered can see it: the meter is paint, and `fittingSize` is blind
  /// to paint. So the shape is asserted here and the wiring in
  /// `RecordingPillPreviewWiringTests`.
  @Test("the sample waveform fills the meter and ends where the mark is")
  func theSampleWaveformIsWellFormed() {
    // **The subject is what the meter DRAWS, not the array as written.** `.still`
    // polls once, that poll appends, and asserting the raw seed would be asserting
    // a value nothing renders — which is exactly the defect cloud review found in
    // the round that introduced the seed.
    let history = RainbowLevelMeter.pushed(
      RecordingPillPreviewTile.sampleLevelHistory,
      level: CGFloat(RecordingPillPreviewTile.sampleLevel))

    #expect(
      RecordingPillPreviewTile.sampleLevelHistory.count == RainbowLevelMeter.barCount - 1,
      """
      the seed has \(RecordingPillPreviewTile.sampleLevelHistory.count) samples for \
      \(RainbowLevelMeter.barCount) bars. It must be exactly one short: the single still \
      poll completes it, and a FULL seed drops its oldest and shifts every bar.
      """)
    #expect(
      history.count == RainbowLevelMeter.barCount,
      """
      after the one still poll the meter holds \(history.count) samples for \
      \(RainbowLevelMeter.barCount) bars, so the rendered waveform is not the shape \
      written here.
      """)
    #expect(
      history.allSatisfy { $0 >= 0 && $0 <= 1 },
      "a sample outside 0...1 clamps at the meter and is not the shape written here: \(history)")
    #expect(
      history.last == CGFloat(RecordingPillPreviewTile.sampleLevel),
      """
      the waveform ends at \(history.last ?? -1) while the rainbow mark is driven by \
      \(RecordingPillPreviewTile.sampleLevel). Both render the same instant, so a picker \
      showing them disagreeing is drawing a pill that cannot occur.
      """)
    // **This is about an AUTHORED constant, not about a recording**, and the
    // distinction matters if anyone copies the assertion: a genuinely SILENT take
    // renders all-zeros for honest reasons and would fail it. Here the array is
    // written by hand and a flat one would mean somebody replaced a waveform with
    // a placeholder. Raised by a peer session against its own prewarm work.
    #expect(
      Set(history).count > 1,
      "every sample in the authored waveform is identical, so the meter draws a flat bar")
  }

  @Test("no two tiles announce the same thing")
  func labelsAreDistinct() {
    let labels = RecordingPillDesign.allCases.map {
      RecordingPillPreviewTile.accessibilityLabel(for: $0)
    }
    #expect(
      Set(labels).count == labels.count,
      "two tiles announce identically: \(labels)")
  }

  /// House style, swept over the surface that is now the ONLY place these strings
  /// are read (GR-NO-DASHES).
  @Test("no announced string carries a dash", arguments: RecordingPillDesign.allCases)
  func labelsCarryNoDashes(design: RecordingPillDesign) {
    let label = RecordingPillPreviewTile.accessibilityLabel(for: design)
    #expect(!label.contains("\u{2014}"), "em dash in: \(label)")
    #expect(!label.contains("\u{2013}"), "en dash in: \(label)")
  }

  /// The sample sentence is a real one, and the wordless designs get no words —
  /// which is what makes their tiles pictures of a capsule rather than of a well.
  @Test("only a design that can hold words is shown holding any", arguments: RecordingPillDesign.allCases)
  func onlyWordCapableDesignsAreShownWords(design: RecordingPillDesign) {
    switch RecordingPillPreviewTile.sampleDisplay(for: design) {
    case .text(let sentence):
      #expect(design.canHoldWords, "\(design) cannot hold words and is drawn holding \"\(sentence)\"")
      #expect(!sentence.isEmpty, "\(design) is drawn holding an empty sentence")
    case .off:
      #expect(!design.canHoldWords, "\(design) can hold words and is drawn empty, so its tile understates it")
    default:
      Issue.record("\(design) is sampled in a transient state, which is not an appearance")
    }
  }
}

// MARK: - The wiring that has no rendered observable

/// How the settings tile CONSTRUCTS the recording leaf (#2435).
///
/// **Drift Guard, and the class is the point.** When this fails we changed our
/// own code and the user sees nothing at that moment. It must never be cited as
/// evidence that the picker looks right — `RecordingPillTileTests` measures what
/// is drawn, and the Live UAT pass is what proves it to a person.
///
/// **It exists because every decision it covers has NO rendered observable, which
/// was established rather than assumed.** Whether a `repeatForever` animation is
/// armed cannot be read back from a hosted view; whether the poll parks cannot be
/// counted from outside a `private` struct's own constant providers; whether the
/// first frame was seeded is indistinguishable from the first asynchronous read
/// winning the race to `fittingSize`; and a locked sample changes paint, which
/// `fittingSize` is blind to. Each would ship green if it silently reverted, and
/// each costs a user something real: a settings page that animates forever, three
/// tiles reading their providers sixty times a second between them, a reading well
/// that flashes empty, and a picker comparing a locked pill against unlocked ones.
///
/// **It PARSES rather than matching text**, for the reason
/// `OverlayRetainedWindowTests` already records: a guard whose subject is a
/// construct will otherwise match the prose ABOUT that construct, and this file
/// has a comment beside every one of these arguments explaining it.
@Suite(.tags(.driftGuard))
struct RecordingPillPreviewWiringTests {

  private final class OverlayConstructionFinder: SyntaxVisitor {
    private(set) var calls: [FunctionCallExprSyntax] = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
        callee.baseName.text == "RecordingOverlayView"
      {
        calls.append(node)
      }
      return .visitChildren
    }
  }

  private static let panel =
    "Sources/EnviousWisprAppKit/Views/Settings/RecordingPillAppearancePanel.swift"

  /// The one construction, required rather than expected: a file that grew a
  /// second one would make every row below ambiguous rather than failing.
  private static func theConstruction() throws -> FunctionCallExprSyntax {
    let text = try String(
      contentsOf: RepoRoot.url.appending(path: panel), encoding: .utf8)
    let finder = OverlayConstructionFinder(viewMode: .sourceAccurate)
    finder.walk(Parser.parse(source: text))

    #expect(
      finder.calls.count == 1,
      """
      \(panel) constructs RecordingOverlayView \(finder.calls.count) times. Zero means \
      this guard is pointed at the wrong file and proves nothing; more than one means \
      the rows below are checking an arbitrary one of them.
      """)
    return try #require(finder.calls.first)
  }

  private static func argument(
    _ label: String, of call: FunctionCallExprSyntax
  ) -> ExprSyntax? {
    call.arguments.first { $0.label?.text == label }?.expression
  }

  static let leaf = "Sources/EnviousWisprAppKit/App/Overlay/Views/RecordingOverlayView.swift"

  private final class StructFinder: SyntaxVisitor {
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
    let f = StructFinder(named)
    f.walk(tree)
    return f.found
  }

  /// Names of the `@State` properties declared DIRECTLY on this struct.
  private static func stateProperties(of decl: StructDeclSyntax) -> Set<String> {
    var names: Set<String> = []
    for member in decl.memberBlock.members {
      guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
      let isState = variable.attributes.contains { attribute in
        attribute.as(AttributeSyntax.self)?
          .attributeName.as(IdentifierTypeSyntax.self)?.name.text == "State"
      }
      guard isState else { continue }
      for binding in variable.bindings {
        if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
          names.insert(pattern.identifier.text)
        }
      }
    }
    return names
  }

  /// **Assignments the view makes to its own names, with initializers EXCLUDED.**
  /// An init writes `_name = State(initialValue:)`, which is the seed itself, so
  /// counting it would make every property look poll-written.
  private final class AssignmentFinder: SyntaxVisitor {
    private(set) var names: Set<String> = []
    private var initDepth = 0

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
      initDepth += 1
      return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { initDepth -= 1 }

    /// **`SequenceExprSyntax`, not `InfixOperatorExprSyntax`.** An unfolded parse
    /// represents `a = b` as a flat sequence — reference, operator, value — and
    /// the folded infix form never appears. Reaching for the infix node returned
    /// an EMPTY set, which the `audioTick` control below caught rather than
    /// letting it pass as "the poll writes nothing".
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
      guard initDepth == 0 else { return .visitChildren }
      let elements = Array(node.elements)
      guard elements.count >= 3,
        let target = elements[0].as(DeclReferenceExprSyntax.self)
      else { return .visitChildren }

      let isAssignment =
        elements[1].is(AssignmentExprSyntax.self)
        || (elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text.hasSuffix("=") ?? false)
      if isAssignment { names.insert(target.baseName.text) }
      return .visitChildren
    }
  }

  private static func namesAssignedOutsideInit(of decl: StructDeclSyntax) -> Set<String> {
    let f = AssignmentFinder(viewMode: .sourceAccurate)
    f.walk(decl)
    return f.names
  }

  /// Every parameter label on this struct's initializers.
  private static func initParameterNames(of decl: StructDeclSyntax) -> Set<String> {
    var names: Set<String> = []
    for member in decl.memberBlock.members {
      guard let initializer = member.decl.as(InitializerDeclSyntax.self) else { continue }
      for parameter in initializer.signature.parameterClause.parameters {
        names.insert((parameter.secondName ?? parameter.firstName).text)
      }
    }
    return names
  }

  @Test("the settings tile parks its poll instead of running one")
  func theTilePassesTheStillCadence() throws {
    let call = try Self.theConstruction()
    let expr = try #require(
      Self.argument("cadence", of: call), "the tile passes no cadence, so it polls at 50 ms")
    let member = try #require(
      expr.as(MemberAccessExprSyntax.self),
      "the cadence is \(expr.trimmedDescription), which this guard cannot judge")

    #expect(
      member.declName.baseName.text == "still",
      """
      the settings tile passes cadence .\(member.declName.baseName.text). Three tiles on \
      a live cadence read their providers sixty times a second between them for as long \
      as the window is open.
      """)
  }

  @Test("the settings tile does not breathe")
  func theTileDisablesTheGlow() throws {
    let call = try Self.theConstruction()
    let expr = try #require(
      Self.argument("animatesGlow", of: call),
      "the tile passes no animatesGlow, so it takes the default true and pulses forever")
    let literal = try #require(
      expr.as(BooleanLiteralExprSyntax.self),
      "animatesGlow is \(expr.trimmedDescription), which this guard cannot judge")

    #expect(
      literal.literal.tokenKind == .keyword(.false),
      "the settings tile passes animatesGlow: true, so every capsule tile runs a permanent two second pulse")
  }

  /// **The seed and the provider must be the SAME expression**, which is the
  /// property rather than the spelling. A seed of `.off` renders an empty reading
  /// well on the first frame; a seed of some OTHER display renders the wrong
  /// picture until the first poll replaces it. Both are invisible to a size test.
  @Test("the first frame is seeded with exactly what the provider returns")
  func theSeedMatchesTheProvider() throws {
    let call = try Self.theConstruction()

    let seed = try #require(
      Self.argument("initialPreview", of: call)?.as(DeclReferenceExprSyntax.self),
      """
      initialPreview is \
      \(Self.argument("initialPreview", of: call)?.trimmedDescription ?? "absent"), not a \
      reference to the same value the provider returns. Absent means it defaults to .off \
      and the reading well flashes empty.
      """)

    let provider = try #require(
      Self.argument("livePreviewProvider", of: call)?.as(ClosureExprSyntax.self),
      "livePreviewProvider is not a literal closure, so this guard cannot compare the two")
    let onlyStatement = try #require(
      provider.statements.count == 1 ? provider.statements.first : nil,
      "livePreviewProvider has \(provider.statements.count) statements; this guard reads a single expression")
    let returned = try #require(
      onlyStatement.item.as(ExprSyntax.self)?.as(DeclReferenceExprSyntax.self),
      "livePreviewProvider returns \(onlyStatement.item.trimmedDescription), not a plain reference")

    #expect(
      seed.baseName.text == returned.baseName.text,
      """
      the tile seeds its first frame with `\(seed.baseName.text)` and its provider returns \
      `\(returned.baseName.text)`. The seed is what the user sees before the first poll, so \
      these disagreeing means the picker briefly shows a picture nothing chose.
      """)
  }

  /// **The seeded meter has no rendered observable at all**, because the meter is
  /// paint and `fittingSize` cannot see paint. Without the seed the rail draws one
  /// bar at the sample level and twenty-three at the silence floor, which is a
  /// picture of the wrong design, and every size row in the suite still passes.
  @Test("the still meter is handed a history to draw")
  func theMeterIsSeeded() throws {
    let call = try Self.theConstruction()
    let expr = try #require(
      Self.argument("initialLevelHistory", of: call),
      """
      the tile passes no initialLevelHistory, so the meter starts empty and a pill that \
      never polls draws a single bar. The Level Rail IS that meter.
      """)

    #expect(
      expr.as(ArrayExprSyntax.self)?.elements.isEmpty != true,
      "initialLevelHistory is an empty literal, which is the same as not passing it")
    #expect(
      expr.trimmedDescription.contains("sampleLevelHistory"),
      """
      initialLevelHistory is \(expr.trimmedDescription), not the sample waveform this \
      picker owns. `theSampleWaveformIsWellFormed` asserts that array's shape and would \
      then be asserting something nothing draws.
      """)
  }

  /// **THE CLOSURE ROW. Every piece of `@State` the poll writes must be seedable,
  /// and this ENUMERATES them from the poll body rather than from a list I wrote.**
  ///
  /// Three cloud-review rounds each found a different member of one set: the
  /// reading well's words, the meter's history, then the level and the clock. That
  /// is the signature of DESCRIBING a set instead of enumerating one — a
  /// description always has a next counterexample, and the reviewer finds it
  /// faster than the author can extend it.
  ///
  /// So the machine prints the structure. It reads `RecordingOverlayView`'s own
  /// `@State` declarations, finds which of them the view assigns outside its
  /// initializer, and requires an `initial<Name>` parameter for each. A fifth one
  /// added later fails HERE, before a picker can ship drawing it wrong.
  ///
  /// `audioTick` is the one exemption and it is exempted BY NAME with its reason:
  /// it is a counter rather than a picture, it exists so the meter appends on
  /// every poll including silent ones, and seeding it to anything but zero would
  /// suppress the meter's first append. The meter takes `initialHistory` instead.
  @Test("every piece of state the poll writes can be seeded")
  func thePollsStateIsSeedable() throws {
    let text = try String(
      contentsOf: RepoRoot.url.appending(path: Self.leaf), encoding: .utf8)
    let view = try #require(
      Self.structDecl(named: "RecordingOverlayView", in: Parser.parse(source: text)),
      "RecordingOverlayView is not in \(Self.leaf) — this guard is pointed at the wrong file")

    let stateNames = Self.stateProperties(of: view)
    #expect(
      stateNames.count >= 4,
      "found \(stateNames.count) @State properties, which is fewer than the four this view is known to hold: \(stateNames)")

    let written = Self.namesAssignedOutsideInit(of: view).intersection(stateNames)
    #expect(
      written.contains("audioTick"),
      """
      the poll no longer writes audioTick, so this guard's one exemption is stale and \
      its reason needs re-reading rather than the name being deleted.
      """)

    let seeds = Self.initParameterNames(of: view)
    let unseeded = written.subtracting(["audioTick"]).filter {
      !seeds.contains("initial" + $0.prefix(1).uppercased() + $0.dropFirst())
    }

    #expect(
      unseeded.isEmpty,
      """
      the poll writes \(unseeded.sorted()) and the view takes no seed for them, so a pill \
      rendered as a PICTURE draws those at their zero value and then snaps once the single \
      poll lands. Add `initial<Name>` and pass it from the picker, or state here why this \
      one is a counter rather than a picture.
      """)
  }

  /// The sample is FIXED, and these two are the ones that change the pixels. A
  /// picker showing one design locked and another unlocked would be comparing
  /// two different things and calling it a choice.
  @Test("the sample pill is unlocked and carries no notice")
  func theSampleStateIsFixed() throws {
    let call = try Self.theConstruction()

    let locked = try #require(
      Self.argument("isLocked", of: call)?.as(BooleanLiteralExprSyntax.self),
      "isLocked is not a literal, so the tile's sample state depends on something")
    #expect(
      locked.literal.tokenKind == .keyword(.false),
      "the tile draws the hands free variant, which is a mode rather than an appearance")

    let notice = Self.argument("noticeText", of: call)
    #expect(
      notice?.is(NilLiteralExprSyntax.self) == true,
      """
      noticeText is \(notice?.trimmedDescription ?? "absent"). The #1060 banner is a runtime \
      event, so a picker drawing one is showing a state the design does not have.
      """)
  }
}
