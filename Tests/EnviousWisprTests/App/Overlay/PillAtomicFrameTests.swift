import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// One publication reaches the recording leaf as ONE frame (#2377 Phase 5, C1).
///
/// **What this suite asserts is a property of the FIRST evaluation after a
/// publication, and nothing else in the suite can see that.** Every other
/// recording probe reads `fittingSize` after `layoutSubtreeIfNeeded`, which is
/// the SETTLED size — a first pass built from an outgoing lock has already been
/// replaced by a correct second pass before any of them measure. So a torn frame
/// and an atomic one produce identical sizes, identical heights and identical
/// widths, which is why this needs the construction-boundary observer rather
/// than a geometry reading.
///
/// The tear it exists to refuse was structural rather than intermittent: the
/// root wrote the lock and the notice into two `@Observable` side-channels from
/// `.onChange(of: model.presentation)`, which SwiftUI runs AFTER the body that
/// observed the change. Every publication carrying a new lock or a new notice
/// therefore drew once with the previous pill's values.
@Suite(.tags(.productOutcome), .serialized)
@MainActor
struct PillAtomicFrameTests {

  /// What one recording leaf was built with.
  private struct LeafFrame: Equatable, CustomStringConvertible {
    let id: PresentationID
    let isLocked: Bool
    let noticeText: String?
    var description: String {
      "(locked: \(isLocked), notice: \(noticeText ?? "nil"))"
    }
  }

  /// Hosts the real root ONCE and republishes into it.
  ///
  /// **A fresh host per publication cannot express the question.** A tear is a
  /// property of a transition — what the leaf received on the first evaluation
  /// after a frame REPLACED another — so the outgoing frame has to have been
  /// rendered by the same hosting view.
  @MainActor
  private final class Rig {
    let model = OverlayRenderModel()
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    private(set) var frames: [LeafFrame] = []

    @MainActor
    init() {
      let root = OverlayRootView(model: model, sendEvent: { _ in })
      host = NSHostingView(rootView: AnyView(root))
      let rect = NSRect(x: 0, y: 0, width: 400, height: 400)
      window = NSWindow(
        contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      host.frame = rect
    }

    @MainActor
    func publish(_ definition: PillDefinition) {
      model.publish(definition)
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
    }

    @MainActor
    func record(_ id: PresentationID, _ locked: Bool, _ notice: String?) {
      frames.append(LeafFrame(id: id, isLocked: locked, noticeText: notice))
    }

    /// The first frame the leaf was built with for `id`.
    ///
    /// Fails LOUDLY rather than returning nil: an empty observation list means
    /// the leaf never ran, which is a missing measurement and must never read as
    /// a passing one.
    @MainActor
    func firstFrame(for id: PresentationID) throws -> LeafFrame {
      try #require(
        frames.first(where: { $0.id == id }),
        """
        the recording leaf was never built for this presentation — the \
        measurement is missing, not failing. Observed \(frames.count) frame(s).
        """)
    }
  }

  private static func recording(
    id: PresentationID, locked: Bool, notice: InPanelNotice?,
    design: RecordingPillDesign = .classic
  ) -> PillDefinition {
    PillDefinition(
      id: id,
      content: .recording(audioLevel: 0.4, isLocked: locked, notice: notice, design: design),
      expiry: .untilReplaced,
      requestedWidth: .fixed(design.width),
      reservesFixedHeight: design.reservedHeight)
  }

  private static let capNotice = InPanelNotice(reason: .approachingCap, dismissAfter: nil)
  private static var capCopy: String {
    DictationNarrator.copy(for: RecordingNoticeReason.approachingCap)
  }

  /// Run `body` with the leaf observer installed, and always take it back down.
  ///
  /// The observer is a static on a shipped type, so a suite that left it set
  /// would leak into every later test in the process. `defer` rather than a
  /// trailing statement, so an assertion failure inside `body` still clears it.
  private func observing(_ rig: Rig, _ body: () throws -> Void) rethrows {
    OverlayRootView.leafObserverForTesting = { [weak rig] id, locked, notice in
      rig?.record(id, locked, notice)
    }
    defer { OverlayRootView.leafObserverForTesting = nil }
    try body()
  }

  @Test("a born-locked recording with a notice reaches the leaf as one frame")
  func bornLockedAndNoticeReachFirstLeafEvaluationAtomically() throws {
    let rig = Rig()
    let outgoing = PresentationID(rawValue: UUID())
    let incoming = PresentationID(rawValue: UUID())

    try observing(rig) {
      // An ordinary live recording: no lock, no banner.
      rig.publish(Self.recording(id: outgoing, locked: false, notice: nil))
      // A DIFFERENT pill, born locked and already carrying its #1060 banner.
      rig.publish(Self.recording(id: incoming, locked: true, notice: Self.capNotice))
    }

    let first = try rig.firstFrame(for: incoming)
    #expect(
      first == LeafFrame(id: incoming, isLocked: true, noticeText: Self.capCopy),
      """
      the first evaluation of the incoming pill drew \(first) — a frame torn \
      across two publications, carrying the outgoing pill's lock or banner
      """)
  }

  @Test("a same-id notice morph and clear never expose the outgoing frame")
  func sameIDNoticeMorphAndClearNeverExposeOutgoingTuple() throws {
    let rig = Rig()
    let id = PresentationID(rawValue: UUID())

    try observing(rig) {
      rig.publish(Self.recording(id: id, locked: false, notice: nil))
      let beforeMorph = rig.frames.count
      rig.publish(Self.recording(id: id, locked: false, notice: Self.capNotice))
      let afterMorph = Array(rig.frames.dropFirst(beforeMorph))
      // **`allSatisfy` is VACUOUSLY TRUE on an empty array**, so without this the
      // row passes on a leaf that stopped evaluating after the morph — a green
      // that means "nothing was observed", which is the one result that must
      // never read as a pass.
      try #require(!afterMorph.isEmpty, "the morph produced no observed leaf frame")
      #expect(
        afterMorph.allSatisfy { $0.noticeText == Self.capCopy },
        "the banner morph drew \(afterMorph) — at least one frame still had no banner")

      let beforeClear = rig.frames.count
      rig.publish(Self.recording(id: id, locked: false, notice: nil))
      let afterClear = Array(rig.frames.dropFirst(beforeClear))
      try #require(!afterClear.isEmpty, "the clear produced no observed leaf frame")
      #expect(
        afterClear.allSatisfy { $0.noticeText == nil },
        "the banner clear drew \(afterClear) — at least one frame still had the banner")
    }
  }

  /// **A dwell survives a same-id publication and dies on a replacement.**
  ///
  /// Paired deliberately: the surviving half alone is satisfied by a `publish`
  /// that never clears a dwell at all, which is the stale-countdown defect in the
  /// other direction. Three same-id recording morphs emit `.unchanged` for the
  /// expiry — an audio tick, a lock change, a notice change — so a `publish` that
  /// cleared unconditionally discarded a window the director had armed, twenty
  /// times a second during a live recording with a timed banner.
  @Test("a dwell survives a same-id publication and dies on a replacement")
  func dwellSurvivesAMorphAndDiesOnAReplacement() throws {
    let model = OverlayRenderModel()
    let id = PresentationID(rawValue: UUID())
    let other = PresentationID(rawValue: UUID())

    model.publish(Self.recording(id: id, locked: false, notice: nil))
    let window = OverlayDwellWindow(id: id, startedAt: Date(), seconds: 4)
    model.markDwellStarted(window)
    try #require(model.state.dwell == window, "the dwell was never armed, so this row proves nothing")

    // A same-id morph: an audio tick carrying a new level.
    model.publish(Self.recording(id: id, locked: true, notice: nil))
    #expect(model.state.dwell == window, "a same-id morph discarded the running clock")

    // A different pill takes the slot.
    model.publish(Self.recording(id: other, locked: false, notice: nil))
    #expect(model.state.dwell == nil, "a replacement inherited the outgoing pill's clock")
  }

  /// A window naming a pill that is not current never reaches a frame.
  @Test("a dwell for a pill that is no longer current is dropped at publication")
  func aStaleDwellIsDroppedRatherThanFiltered() {
    let model = OverlayRenderModel()
    let current = PresentationID(rawValue: UUID())
    let stale = PresentationID(rawValue: UUID())

    model.publish(Self.recording(id: current, locked: false, notice: nil))
    model.markDwellStarted(OverlayDwellWindow(id: stale, startedAt: Date(), seconds: 3))

    #expect(model.state.dwell == nil, "a window for another pill reached the frame")
  }

  /// **The negative control, and without it the two rows above pass on a leaf
  /// that always reports locked.** They assert the presence of a lock and a
  /// banner; nothing in them would notice an observer wired to constants.
  @Test("an unlocked recording with no notice reaches the leaf as the opposite frame")
  func unlockedWithoutNoticeIsObservedAsSuch() throws {
    let rig = Rig()
    let id = PresentationID(rawValue: UUID())

    try observing(rig) {
      rig.publish(Self.recording(id: id, locked: false, notice: nil))
    }

    let first = try rig.firstFrame(for: id)
    #expect(first == LeafFrame(id: id, isLocked: false, noticeText: nil), "drew \(first)")
  }
}
