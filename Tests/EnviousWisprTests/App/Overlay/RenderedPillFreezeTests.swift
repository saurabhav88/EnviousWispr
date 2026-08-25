import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// What every pill measures on `main` at `e062ab4d`, before Phase 4 moves a line
/// (#2376 C1).
///
/// **Every number here was RUN and TRANSCRIBED, never computed from the code it
/// freezes.** A table derived from the implementation agrees with every future
/// version of that implementation, which is the one thing a freeze must not do.
/// The capture that produced them is in the commit message; re-take them by
/// printing `RenderedPillHarness.rootSize` per row rather than by reading the
/// views.
///
/// **A Drift Guard, deliberately, and not a Product Outcome test.** When a row
/// here fails the user sees nothing yet — it says WE changed our own rendering,
/// which is exactly what Phase 4 does on purpose in some chunks and must not do
/// by accident in others. The sentence "when this fails the user sees ___" has
/// no ending, so it is not product coverage and is not counted as any.
@MainActor
@Suite(.tags(.driftGuard))
struct RenderedPillFreezeTests {

  init() { _ = NSApplication.shared }

  // MARK: - The frozen table

  /// **Is this a machine whose text metrics the frozen tables were taken on?**
  ///
  /// `scripts/xcode-test.sh` forwards `CI` as `TEST_RUNNER_CI`, because an
  /// inherited variable does not reach the test process — measured both ways, and
  /// the direction is what matters: a gate reading the runner's own `CI` fails
  /// OPEN, so it runs the machine-dependent rows on the machine it meant to
  /// exclude. An EMPTY value is a local run, since the script forwards the
  /// variable unconditionally and it is unset here.
  nonisolated static var isDeveloperMachine: Bool {
    (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty
  }

  /// Sizes of the routed content, measured 2026-08-25 on `e062ab4d`.
  ///
  /// Read `RenderedPillHarness`'s own doc for what a row means: it is the
  /// content at the width the definition asks for, which is not the window's
  /// size, and it is blind to paint.
  nonisolated static let frozenNotices:
    [(label: String, request: PillCatalogRequest, width: CGFloat, height: CGFloat)] = [
      ("processing.transcribing", .processing(phase: .transcribing), 151.5, 44),
      ("clipboardFallback", .clipboardFallback, 226.5, 44),
      ("accessibilityToast", .accessibilityToast, 332.5, 43),
      ("warning.polishFailed", .warning(reason: .polishFailed), 231, 37),
      ("error.asrFailed", .error(reason: .asrFailed), 239, 38),
      // The one row whose width is a PROPOSAL rather than an ideal, because it
      // is the one pill asking for a fixed width and a content height. At its
      // real 360 it wraps to 68pt; unproposed it reports 927 x 39, a single
      // unwrapped line — which is the reading two earlier capture rounds took
      // and the reason the harness proposes a width at all.
      ("advisory.zeroSignal", .advisory(reason: .zeroSignal), 360, 68),
      ("interruption.deviceRemoved", .interruption(reason: .deviceRemoved), 225.5, 44),
      ("cachingModel", .cachingModel(engineLabel: "Parakeet"), 259.5, 51),
      ("engineReady", .engineReady, 213, 40),
      ("recoveringLastRecording", .recoveringLastRecording, 352, 51),
      ("recoverySucceeded", .recoverySucceeded, 245, 51),
      ("importStatus", .importStatus(message: "Imported 12 words"), 170, 38),
    ]

  /// **TEXT LAYOUT IS A PROPERTY OF THE MACHINE, so the exact-size half of this
  /// suite runs on a development Mac and reports SKIPPED on a hosted runner.**
  ///
  /// Measured, and this is the whole justification rather than a precaution: this
  /// table passed locally at 6,958 tests and failed on CI at ELEVEN of its twelve
  /// rows, on the same commit, with every other suite in the run agreeing. Font
  /// metrics, system version and rendering defaults all differ, and a freeze over
  /// absolute point sizes cannot survive that by construction — the numbers are a
  /// reading of one Mac on one day.
  ///
  /// **What that costs is stated rather than hidden: on CI this row proves
  /// nothing, and a skipped receipt is not a passed receipt.** The claim that
  /// travels is the companion below, which asserts the RELATIONS these numbers
  /// happen to satisfy and holds on any machine. Two tests because there are two
  /// claims, and only one of them is portable.
  ///
  /// The frozen values keep their evidential job either way: they are the
  /// pre-Phase-4 reading, and the parity they were written to prove was
  /// established on the machine that took them.
  @Test(
    "every notice pill renders exactly what it rendered before Phase 4",
    .enabled(if: RenderedPillFreezeTests.isDeveloperMachine),
    arguments: RenderedPillFreezeTests.frozenNotices)
  func noticeRowsAreFrozen(
    row: (label: String, request: PillCatalogRequest, width: CGFloat, height: CGFloat)
  ) throws {
    let size = RenderedPillHarness.rootSize(for: row.request)
    // The instrument control comes FIRST and is a `#require`: a hosting view
    // measured before layout reports `.zero`, and a table of zeroes would freeze
    // perfectly for ever.
    try #require(
      size.width > 0 && size.height > 0,
      "\(row.label) measured \(size) — the harness returned nothing, which is not a pass")
    #expect(
      size.width == row.width && size.height == row.height,
      """
      \(row.label) measured \(size.width) x \(size.height), frozen at \
      \(row.width) x \(row.height). Either this pill is routed through a different \
      leaf now, or its treatment changed, or this is not the Mac the table was \
      measured on. Phase 4 changes where a leaf's WORDS come from and must not \
      change what any of them draws.
      """)
  }

  /// **The portable half, and the one CI actually runs.** Every claim here is a
  /// RELATION between measurements taken in the same process, so it holds
  /// whatever that process's font metrics are.
  ///
  /// Two properties, each of which a real regression would break, and NEITHER of
  /// them a size: every notice is drawn at all, and a notice whose definition
  /// asks for a FIXED width is given that width rather than its unwrapped ideal.
  ///
  /// **Deliberately NOT asserted here: that a notice fits the recording pill's
  /// reserved box.** These are standalone pills with their own windows, not
  /// content inside the capsule, so that budget is not theirs and asserting it
  /// would be a claim about the wrong subject that happens to hold today. The
  /// in-panel notices, which DO inherit that box and have no headroom in it, are
  /// covered by `inPanelNoticesFitTheReservedBox` below.
  @Test(
    "every notice pill is drawn, and a fixed width is honoured",
    arguments: RenderedPillFreezeTests.frozenNotices)
  func noticeRowsSatisfyTheirPortableRelations(
    row: (label: String, request: PillCatalogRequest, width: CGFloat, height: CGFloat)
  ) throws {
    let definition = try #require(
      PillCatalog.entry(for: row.request, id: RenderedPillHarness.id()).definition,
      "\(row.label) produced no definition at all, so nothing below is about a pill")
    let size = RenderedPillHarness.rootSize(for: definition)
    try #require(
      size.width > 0 && size.height > 0,
      "\(row.label) measured \(size) — the harness returned nothing, which is not a pass")

    // The advisory is the one such row today, and it is the row two capture
    // rounds got wrong by reading its unwrapped 927 instead of its real 360.
    if case .fixed(let requested) = definition.requestedWidth,
      definition.reservesFixedHeight == nil, requested > 0
    {
      #expect(
        size.width == requested,
        """
        \(row.label) asked for a fixed \(requested) and measured \(size.width). \
        A width that is not the one requested means the proposal never reached the \
        content, so its height is the height of some other layout entirely.
        """)
    }
  }

  /// **The one product CONSTANT the frozen table was silently carrying, pinned
  /// where a hosted runner can see it** (#2376 Phase 4, round 4).
  ///
  /// Gating `noticeRowsAreFrozen` to a development Mac was right — its numbers are
  /// rendered measurements — but it took a real guard with it. That table was the
  /// only thing binding the advisory's 360pt REQUEST, and a request is not a
  /// measurement: it is a value in the catalog, identical on every machine. So it
  /// belongs in an always-enabled case, and narrowing it is caught everywhere
  /// rather than only here.
  ///
  /// Note what the portable relations case CANNOT do instead: it asserts the
  /// rendered width equals the REQUESTED one, so moving the request moves both
  /// sides and it stays green. A test that follows the value it is checking binds
  /// nothing.
  @Test("the advisory asks for the width the panel reserves for it")
  func advisoryWidthIsPinned() throws {
    let definition = try #require(
      PillCatalog.entry(for: .advisory(reason: .zeroSignal), id: RenderedPillHarness.id())
        .definition)
    guard case .fixed(let requested) = definition.requestedWidth else {
      Issue.record("the advisory no longer asks for a fixed width at all")
      return
    }
    #expect(
      requested == 360,
      """
      the advisory asks for \(requested)pt, not the 360 the overlay panel reserves. \
      #1891: unconstrained it measures 927 and wraps to nothing sensible, so this \
      number is what makes the pill legible rather than a style choice.
      """)
  }

  // MARK: - The instrument's own controls

  /// **An empty slot must be distinguishable from every pill**, or a harness
  /// that silently measured nothing would agree with a table of the right shape.
  @Test("an empty slot measures nothing, and nothing measures like a pill")
  func emptySlotIsDistinguishable() {
    let empty = RenderedPillHarness.rootSize(for: nil as PillDefinition?)
    #expect(empty == .zero, "an empty slot measured \(empty)")
    for row in Self.frozenNotices {
      #expect(
        !(row.width == empty.width && row.height == empty.height),
        "\(row.label) is frozen at the empty-slot size, so its row proves nothing")
    }
  }

  /// **The four notification severities must not all measure the same, and the
  /// TEXT is held constant so that claim is about the severity.**
  ///
  /// An earlier version drove four different catalog requests — `.warning`,
  /// `.error`, `.advisory`, `.interruption` — each carrying its own copy. Cloud
  /// review refuted it: those four measure differently because their MESSAGES
  /// differ, so the control passes just as well against a build that routes every
  /// severity through one style, while claiming to prove the opposite. A control
  /// that cannot fail for the reason it names buys confidence without cover.
  ///
  /// Holding the sentence fixed and varying only the severity makes a collapsed
  /// mapping fail: the four would then measure identically.
  ///
  /// **The first correction held the MESSAGE constant and left a second axis
  /// varying, which cloud review then refuted on the same case.** `isMultiline`
  /// was set for `.advisory` alone, so that row wrapped where the others did not
  /// and could measure differently even under a collapsed mapping — the same
  /// defect the first fix was for, one axis over. A control varies ONE thing;
  /// "the message is now constant" is not that claim, and only enumerating what
  /// else the definition carries gets there.
  ///
  /// Re-measured 2026-08-25 with one sentence, `isMultiline: false` throughout,
  /// at a fixed 280pt: **warning 37, error 38, distress 44, advisory 39** (the
  /// advisory's 52 in the previous revision was its wrapping, not its style).
  /// Three of the four gaps are ONE point, from the SF Symbols' differing
  /// heights — real, small, and the reason this suite claims discrimination
  /// rather than claiming to see paint. The heights are pinned below as well as
  /// compared, because at a one-point spread a mapping could collapse two styles
  /// onto a third and still produce four distinct numbers.
  @Test("the notification severities are told apart by the instrument")
  func severitiesAreDiscriminated() {
    let text = "Something went wrong while polishing your text."
    // EVERY field but `severity` is held fixed. That is the claim.
    let expected: [(NoticeModel.Severity, CGFloat)] = [
      (.warning, 37), (.error, 38), (.distress, 44), (.advisory, 39),
    ]
    let sizes = expected.map { severity, _ in
      RenderedPillHarness.rootSize(
        for: PillDefinition(
          id: RenderedPillHarness.id(),
          content: .notice(
            NoticeModel(
              kind: .notification, text: text, severity: severity,
              isMultiline: false)),
          expiry: .untilReplaced, requestedWidth: .fixed(280)))
    }
    #expect(
      Set(sizes.map { "\($0.width)x\($0.height)" }).count == sizes.count,
      """
      two or more notification severities measured identically on ONE sentence with \
      one wrapping mode: \(sizes). Either the severity-to-style mapping has \
      collapsed, or this instrument cannot tell the treatments apart — and every \
      frozen row above is a claim it cannot support.
      """)
    // **The exact heights are NOT asserted here, and that is deliberate.** They
    // are a reading of one Mac (recorded above as evidence), and the row that
    // pins absolute sizes is skipped on CI for exactly that reason. What travels
    // is the ORDER, which is a relation between measurements in one process: the
    // distress style is the tallest treatment, and it is the one whose height
    // comes from its own chrome rather than from the sentence.
    let tallest = zip(expected, sizes).max(by: { $0.1.height < $1.1.height })
    #expect(
      tallest?.0.0 == .distress,
      """
      \(String(describing: tallest?.0.0)) measured tallest, not .distress. \
      Distinctness alone would not have caught this: with the four barely a point \
      apart, two styles can collapse onto a third and still give four different \
      numbers, so the ordering is the part that says WHICH treatment each got.
      """)
  }

  /// The paired case, so the row above cannot pass merely because five inputs
  /// give five answers: `.neutral` has no style of its own and maps to
  /// `.warning`, so it must measure IDENTICALLY to it. A harness that returned a
  /// different number for every input would fail here.
  @Test("the styleless severity measures as the style it maps to")
  func neutralMeasuresAsWarning() {
    let text = "Something went wrong while polishing your text."
    func size(_ severity: NoticeModel.Severity) -> CGSize {
      RenderedPillHarness.rootSize(
        for: PillDefinition(
          id: RenderedPillHarness.id(),
          content: .notice(NoticeModel(kind: .notification, text: text, severity: severity)),
          expiry: .untilReplaced, requestedWidth: .fixed(280)))
    }
    #expect(
      size(.neutral) == size(.warning),
      """
      `.neutral` measured \(size(.neutral)) against `.warning`'s \(size(.warning)). \
      `OverlayRootView.style(for:)` maps the styleless severity to `.warning` \
      deliberately, so a row landing there is styled-wrong-but-VISIBLE rather than \
      unstyled; if these differ, that mapping moved.
      """)
  }

  /// Reconciles this instrument against a number pinned independently, by a
  /// different rig, before this suite existed. A disagreement here indicts the
  /// harness rather than the app.
  @Test("the classic capsule measures what its own suite already pins")
  func classicAgreesWithTheIndependentPin() throws {
    let contentHeight = try RenderedPillHarness.recordingContentHeight(
      design: .classic, width: 185)
    #expect(
      contentHeight == 44,
      """
      the capsule's content measured \(contentHeight)pt, against the 44pt \
      `RecordingOverlayPreviewChromeTests.capsuleHeightIsPinned` has pinned since \
      #2202. Two rigs disagreeing about one pill means one of them is wrong, and \
      this is the newer one.
      """)
  }

  // MARK: - Recording pills

  nonisolated static let frozenRecording:
    [(label: String, design: RecordingPillDesign, locked: Bool, width: CGFloat, height: CGFloat)] =
      [
        ("classic.unlocked", .classic, false, 185, 92),
        ("classic.locked", .classic, true, 185, 92),
        ("readingWell.unlocked", .readingWell, false, 400, 34),
        ("readingWell.locked", .readingWell, true, 400, 34),
      ]

  @Test(
    "every recording pill renders exactly what it rendered before Phase 4",
    arguments: RenderedPillFreezeTests.frozenRecording)
  func recordingRowsAreFrozen(
    row: (
      label: String, design: RecordingPillDesign, locked: Bool, width: CGFloat, height: CGFloat
    )
  ) throws {
    let size = RenderedPillHarness.recordingRootSize(design: row.design, locked: row.locked)
    try #require(size.width > 0 && size.height > 0, "\(row.label) measured \(size)")
    #expect(
      size.width == row.width && size.height == row.height,
      "\(row.label) measured \(size.width) x \(size.height), frozen at \(row.width) x \(row.height)"
    )
  }

  /// The reading well earns its height a line at a time, and that growth is the
  /// feature. Frozen as a specific measurement rather than as "taller", because
  /// "taller" also passes if it grows to the wrong size.
  @Test("the reading well grows for words, and by exactly as much as it did")
  func readingWellGrowsForWords() {
    let words = RenderedPillHarness.recordingRootSize(
      design: .readingWell,
      display: .text("the quarterly numbers came in ahead of plan and the board was pleased"))
    #expect(words.width == 400 && words.height == 99, "the reading well measured \(words)")
  }

  // MARK: - The measurement nobody had taken

  /// **The classic pill's reserved box has ZERO headroom for its own longest
  /// notice, and that is measured rather than asserted.**
  ///
  /// The #1060 banner is the only thing that makes a without-words pill grow.
  /// The root frames such a pill to `RecordingPillDesign.reservedHeight`, and a
  /// without-words design is handed a no-op growth callback by
  /// `OverlayRenderModel`, so nothing in production and nothing in this tree
  /// could previously observe the content exceeding the box.
  ///
  /// Measured 2026-08-25: `approachingCap` fills the 92-point box EXACTLY, and
  /// `autoStopUnavailable` uses 78. A three-line sentence measures 120 and would
  /// be silently cut off. So this is not a defect today and is one word of copy
  /// away from being one — which is precisely why the budget is pinned here
  /// rather than left as a number in a doc comment.
  @Test(
    "the shipped in-panel notices fit the box the classic pill reserves",
    arguments: [RecordingNoticeReason.approachingCap, .autoStopUnavailable])
  func inPanelNoticesFitTheReservedBox(reason: RecordingNoticeReason) throws {
    let budget = try #require(RecordingPillDesign.classic.reservedHeight)
    for locked in [false, true] {
      let height = try RenderedPillHarness.recordingContentHeight(
        design: .classic, locked: locked,
        notice: DictationNarrator.copy(for: reason), width: RecordingPillDesign.classic.width)
      #expect(
        height <= budget,
        """
        the \(reason) banner made the capsule \(height)pt tall (locked: \(locked)) \
        against the \(budget)pt box the classic design reserves. The pill cannot \
        grow — a without-words design is handed a no-op growth callback — so the \
        overflow is CLIPPED on screen with nothing reporting it. Shorten the copy \
        or raise the reserved height; do not raise this expectation.
        """)
    }
  }

  /// The paired case, so the row above cannot pass by measuring nothing. A
  /// notice must make the pill genuinely taller than a bare one.
  @Test("a notice is what makes the capsule grow at all")
  func aNoticeGrowsTheCapsule() throws {
    let bare = try RenderedPillHarness.recordingContentHeight(
      design: .classic, width: 185)
    let withNotice = try RenderedPillHarness.recordingContentHeight(
      design: .classic,
      notice: DictationNarrator.copy(for: .approachingCap), width: 185)
    #expect(
      withNotice > bare,
      "a notice measured \(withNotice)pt against a bare \(bare)pt — the banner never rendered")
  }
}
