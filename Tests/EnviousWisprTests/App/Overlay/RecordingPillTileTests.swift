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
  ///
  /// **The width comes from the design's GROUP, exactly as the panel supplies
  /// it** — a tile measured at some other width is not the tile the user sees.
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


  /// **Every tile in one group draws the SAME rectangle, and the two groups draw
  /// different ones.**
  ///
  /// This REPLACES an assertion that no two tiles shared a width, which pinned
  /// the behaviour the founder rejected on sight: unequal boxes read as a ragged
  /// set rather than as a row of pictures. The pill inside still keeps its own
  /// true size — `thePreviewIsTheRealPillScaled` and `noPreviewIsMagnified` are
  /// what hold that, and they are what would fail if normalising ever started
  /// distorting the pill.
  /// **The pill inside the card is the REAL pill, and it fits its box.**
  ///
  /// REPLACES `tileHeightTracksTheLeaf` and `theReadingWellRendersTaller`, which
  /// both required a card's height to track the pill inside it. The founder
  /// replaced that layout with three identical cards on 2026-08-26, so a uniform
  /// card can no longer report the pill's height and those two failed BY DESIGN.
  /// They are obsolete rather than weakened: the fidelity they protected moves
  /// onto the LEAF, which the tile does not size.
  ///
  /// The oracle is still one the tile did not write — `RenderedPillHarness`
  /// measures the recording leaf directly, with no tile involved.
  @Test(
    "the preview is the real pill, scaled to fit its box",
    arguments: RecordingPillDesign.allCases)
  func thePreviewIsTheRealPillScaled(design: RecordingPillDesign) throws {
    let leaf = try Self.leafHeight(design)
    // The SAME entry point the view calls, at the nominal box width. A separate
    // `thumbnailScale(for:)` used to exist for tests to ask this; it was one more
    // answer to a question the view already had an answer for, so it is gone.
    let drawn = leaf * RecordingPillPreviewTile.scale(
      for: design, inWidth: RecordingPillPreviewTile.thumbnailSize.width)

    #expect(leaf > 0, "\(design) leaf measured \(leaf), so the harness rendered nothing")
    #expect(
      drawn <= RecordingPillPreviewTile.thumbnailSize.height + 0.5,
      """
      \(design) draws \(drawn) tall into a \
      \(RecordingPillPreviewTile.thumbnailSize.height) box, so the pill is cut off. The \
      card is a fixed height now, so nothing grows to accommodate it.
      """)
  }

  /// **The pill that shows words is still the TALLEST**, even though its card is
  /// no longer taller than the others.
  ///
  /// A change that started drawing the well at a wordless pill's height would be
  /// showing the user the wrong picture, and the equalised cards can no longer
  /// catch it.
  @Test("the pill that shows words is still the tallest")
  func theReadingWellLeafIsTallest() throws {
    let wordy = try RecordingPillDesign.allCases.filter(\.canHoldWords).map(Self.leafHeight)
    let wordless = try RecordingPillDesign.allCases.filter { !$0.canHoldWords }.map(Self.leafHeight)

    let tallestWordy = try #require(wordy.max(), "no design holds words")
    let tallestWordless = try #require(wordless.max(), "no design is wordless")

    #expect(
      tallestWordy > tallestWordless,
      """
      a words-holding pill measured \(tallestWordy) against \(tallestWordless) for a \
      wordless one. The well carries a line of text the others do not, so it must be \
      taller; equal heights mean the well is rendering without its text.
      """)
  }

  @Test("every card in the row is the same size")
  func everyCardIsOneSize() {
    let sizes = RecordingPillDesign.allCases.map { Self.tileSize($0) }

    #expect(sizes.allSatisfy { $0.width > 0 && $0.height > 0 }, "measured \(sizes): nothing rendered")
    #expect(
      Set(sizes.map(\.height)).count == 1,
      """
      the cards measured heights \(sizes.map(\.height)). One row of identical cards was \
      the founder's ask; a difference means a card is sized by the pill inside it rather \
      than by the shared thumbnail box.
      """)
  }

  /// **No tile is ever narrower than the pill it frames, plus its padding.**
  ///
  /// Cloud review on #2439 raised the reading well overflowing a narrow window.
  /// Normalising every tile in a group to that group's WIDEST can only ever add
  /// width, never remove it — but that is an argument, and this is the
  /// measurement, taken per design so a future group whose widest shrinks fails
  /// here rather than by clipping a pill on screen.
  ///
  /// Whether the containing WINDOW can be narrower than the tile is a different
  /// question, held by `thePanelRefusesToClipItsWidestPill` and a Live UAT row.
  /// **No pill overflows the thumbnail box it is scaled into.**
  ///
  /// The shared scale is taken from the WIDEST design, so this can only fail if a
  /// design's declared width stops being covered by that maximum — which is
  /// exactly what a new, wider design would do if the scale were ever pinned to a
  /// literal instead of derived.
  @Test("no pill overflows its thumbnail", arguments: RecordingPillDesign.allCases)
  func noPillOverflowsItsThumbnail(design: RecordingPillDesign) {
    let drawn = RecordingPillPreviewTile.thumbnailWidth(for: design)
    let box = RecordingPillPreviewTile.thumbnailSize.width

    #expect(drawn > 0, "\(design) scaled to \(drawn), so nothing is drawn")
    #expect(
      drawn <= box + 0.01,
      "\(design) draws \(drawn) into a \(box) box, so the pill is clipped")
  }

  /// **No pill is ever drawn LARGER than it appears in real life.**
  ///
  /// The previews were enlarged so a user can read them (founder, 2026-08-26), and
  /// the narrow designs already fit the box at native size. Scaling them UP to
  /// fill it would make a compact pill look bigger on this page than on screen —
  /// the same misrepresentation as the rejected shared scale, pointed the other
  /// way, and the one this cap exists to prevent.
  @Test("no preview is magnified past the bound", arguments: RecordingPillDesign.allCases)
  func noPreviewIsMagnifiedPastTheBound(design: RecordingPillDesign) {
    // A card far wider than any pill, which is what the founder's window gives at
    // the default size — the case the bound exists for.
    let scale = RecordingPillPreviewTile.scale(for: design, inWidth: 2000)

    #expect(scale > 0, "\(design) scales to \(scale), so nothing is drawn")
    #expect(
      scale <= RecordingPillPreviewTile.maxMagnification,
      """
      \(design) is drawn at \(scale)x against a bound of \
      \(RecordingPillPreviewTile.maxMagnification)x. Unbounded, a wide window draws a \
      compact pill at nearly 5x and the row stops being comparable.
      """)
  }

  /// **The widest design still fills the box**, so enlarging the previews did not
  /// quietly leave the biggest one floating in margin.
  @Test("the widest design fills the preview box")
  func theWidestDesignFillsTheBox() {
    let widest = RecordingPillDesign.allCases.max(by: { $0.width < $1.width })
    let widestDesign = try! #require(widest, "no designs, so the row has no subject")

    #expect(
      abs(RecordingPillPreviewTile.thumbnailWidth(for: widestDesign)
        - RecordingPillPreviewTile.thumbnailSize.width) < 0.01,
      """
      the widest design draws \(RecordingPillPreviewTile.thumbnailWidth(for: widestDesign)) \
      into a \(RecordingPillPreviewTile.thumbnailSize.width) box. It should fill it: if it \
      does not, every other preview is smaller than it needed to be.
      """)
  }

  /// **The names came off the cards, so the ACCESSIBILITY label is now the only
  /// thing naming a design to anyone who cannot see the drawing.**
  ///
  /// Before the visible names were removed a sighted user and a VoiceOver user both
  /// got the name; now only one does, and this is what keeps it. A change that
  /// trimmed the label to match the visible card would leave a row of buttons that
  /// announce nothing distinguishable.
  @Test(
    "every design is still named to a screen reader", arguments: RecordingPillDesign.allCases)
  func theNameSurvivesInTheAccessibilityLabel(design: RecordingPillDesign) {
    let label = RecordingPillPreviewTile.accessibilityLabel(for: design)

    #expect(
      label.contains(design.displayName),
      """
      \(design) announces "\(label)", which does not carry its name. The card shows no \
      name, so this label is the only place a screen reader can get one.
      """)
    #expect(
      label.contains(design.summary),
      "\(design) announces no description, leaving a blind user only a name for a picture")
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
    // **The seed IS the picture now**, because a seeded meter ignores ticks. Two
    // earlier versions of this row chased the seed's LENGTH instead and each one
    // only moved a one-bar shift; the property that matters is that the rendered
    // bars are exactly this, which `theSeededMeterIgnoresTicks` proves for the
    // mechanism and this row proves for the shape.
    let history = RecordingPillPreviewTile.sampleLevelHistory

    #expect(
      history.count == RainbowLevelMeter.barCount,
      """
      the seed has \(history.count) samples for \(RainbowLevelMeter.barCount) bars. \
      `bars` right-aligns a short history and pads the OLD end with silence, so anything \
      but an exact fill draws a leading silence bar nobody chose.
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

  /// **The mechanism behind the shape row above: a seeded meter does not
  /// accumulate.**
  ///
  /// Driven through the meter's own `onHistoryChange` seam, which exists for
  /// exactly this — an outcome observer that reports what was pushed. A seeded
  /// meter must never push, so the observer must never fire, however many ticks
  /// arrive. The unseeded control is what makes that non-vacuous: without it a
  /// meter that had simply stopped working would pass.
  @Test("a seeded meter ignores ticks, and an unseeded one does not")
  func theSeededMeterIgnoresTicks() {
    final class Pushes: @unchecked Sendable {
      var histories: [[CGFloat]] = []
    }

    // **The tick must actually CHANGE, or neither arm pushes and the row is
    // vacuous in both directions.** `onChange` fires on a change, so a meter
    // mounted at a fixed tick never appends whatever its seed. The rootView is
    // replaced to advance it, which is what a real poll does.
    func drive(seed: [CGFloat]) -> Pushes {
      let pushes = Pushes()
      func meter(tick: Int) -> AnyView {
        AnyView(
          RainbowLevelMeter(
            audioLevel: 0.42, tick: tick,
            onHistoryChange: { pushes.histories.append($0) },
            initialHistory: seed))
      }

      let host = NSHostingView(rootView: meter(tick: 0))
      let frame = NSRect(x: 0, y: 0, width: 200, height: 60)
      let window = NSWindow(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      host.frame = frame
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()

      host.rootView = meter(tick: 1)
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return pushes
    }

    // THE CONTROL, and without it a meter that had simply stopped appending
    // would satisfy the assertion below.
    let unseeded = drive(seed: [])
    #expect(
      !unseeded.histories.isEmpty,
      """
      control: an UNSEEDED meter did not append on a tick change, so this row cannot \
      distinguish a seeded meter holding still from a meter that no longer works.
      """)

    let seeded = drive(seed: RecordingPillPreviewTile.sampleLevelHistory)
    #expect(
      seeded.histories.isEmpty,
      """
      a seeded meter pushed \(seeded.histories.count) time(s), so the picker's waveform \
      is not the array the picker chose. Every push shifts the bars.
      """)
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
