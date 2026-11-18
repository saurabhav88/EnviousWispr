import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

// MARK: - Fixtures

enum LearnedPillFixture {
  static func model(
    id: UUID = UUID(), wordID: UUID = UUID(), canonical: String = "Tuist",
    kind: LearnedCorrectionPillModel.Kind = .added,
    phase: LearnedCorrectionPillModel.Phase = .learned
  ) -> LearnedCorrectionPillModel {
    LearnedCorrectionPillModel(
      id: id, wordID: wordID, canonical: canonical, kind: kind, phase: phase)
  }
}

/// A deterministic clock over the director's scheduler: every armed dwell is
/// recorded with its deadline, and `advance(to:)` fires what is due, in order.
@MainActor
final class LearnedPillClock {
  private(set) var now = 0.0
  private(set) var armed: [(deadline: Double, work: OverlayScheduledWork)] = []
  private(set) var armedSeconds: [Double] = []

  /// The fake time as a `Date`, handed to the director so its expiry clock
  /// reads the SAME time the scheduler is advanced by (#4675: remainder and
  /// deadline arithmetic use `now`, which production reads from `Date`).
  var date: Date { Date(timeIntervalSince1970: 1_000 + now) }

  var scheduler: OverlayScheduler {
    OverlayScheduler { [unowned self] seconds, body in
      let work = OverlayScheduledWork(body: body)
      self.armed.append((deadline: self.now + seconds, work: work))
      self.armedSeconds.append(seconds)
      return work
    }
  }

  func advance(to time: Double) {
    now = time
    for entry in armed where entry.deadline <= time {
      entry.work.fire()
    }
    armed.removeAll { $0.deadline <= time }
  }
}

/// Stands in for the director on the adapter's side.
@MainActor
final class LearnedOverlayHostFake: LearnedCorrectionOverlayHosting {
  private(set) var requests: [LearnedCorrectionPillModel] = []
  private(set) var saveErrors: [LearnedCorrectionSaveError] = []
  private(set) var undos: [() -> Void] = []
  private(set) var endeds: [() -> Void] = []
  private(set) var stillWanted: [() -> Bool] = []
  private(set) var pendingResults: [(PillPresentationResult) -> Void] = []
  private(set) var resolved: [(UUID, PresentationID, LearnedCorrectionPillModel.Phase)] = []
  private(set) var closes: [UUID] = []
  /// nil = refuse admission synchronously.
  var admitAs: PresentationID? = PresentationID()
  /// true = hold `onResult` for the test to answer (a deferred first render).
  var deferResult = false

  func present(
    _ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt? {
    switch request {
    case .correctionLearned(let model, let isStillWanted, let onUndo, let onEnded):
      requests.append(model)
      stillWanted.append(isStillWanted)
      undos.append(onUndo)
      endeds.append(onEnded)
    case .correctionLearnedSaveError(let error):
      saveErrors.append(error)
      onResult(.presented(PillReceipt(presentationID: PresentationID())))
      return nil
    default:
      Issue.record("the adapter presented something other than a learned pill")
      return nil
    }
    guard let id = admitAs else {
      onResult(.notPresented)
      return nil
    }
    let receipt = PillReceipt(presentationID: id)
    if deferResult {
      pendingResults.append(onResult)
    } else {
      onResult(.presented(receipt))
    }
    return receipt
  }

  /// The director's rule, mirrored: a deferred render commits only while the
  /// owner still wants it.
  func answerPending() {
    let waiting = pendingResults
    pendingResults = []
    let wanted = stillWanted.last?() ?? false
    for answer in waiting {
      answer(
        wanted
          ? .presented(PillReceipt(presentationID: admitAs ?? PresentationID())) : .notPresented)
    }
  }

  func resolveLearnedCorrection(
    pillID: UUID, presentation: PresentationID, phase: LearnedCorrectionPillModel.Phase
  ) {
    resolved.append((pillID, presentation, phase))
  }

  func closeLearnedCorrection(pillID: UUID) { closes.append(pillID) }
}

// MARK: - Copy

@Suite("Undo pill: copy table (#996 auto-learn)", .tags(.productOutcome))
struct LearnedCorrectionPillCopyTests {

  @Test(
    "the card's lines are the approved whole phrases: the word is the title, the subtitle says Added or Updated, the results and the button are fixed words"
  )
  func exactStrings() {
    let added = LearnedPillFixture.model(canonical: "Tuist", kind: .added)
    let updated = LearnedPillFixture.model(canonical: "Saira", kind: .updated)
    let addedLine = CorrectionLearnedPillCopy.line(for: added)
    let updatedLine = CorrectionLearnedPillCopy.line(for: updated)
    #expect(addedLine.title == "Tuist" && addedLine.subtitle == "Added to dictionary")
    #expect(updatedLine.title == "Saira" && updatedLine.subtitle == "Updated in dictionary")
    #expect(addedLine.undoLabel == "Undo" && CorrectionLearnedPillCopy.undo == "Undo")
    #expect(addedLine.closeLabel == "Close and keep \u{201C}Tuist\u{201D}")
    #expect(updatedLine.closeLabel == "Close and keep \u{201C}Saira\u{201D}")
    #expect(CorrectionLearnedPillCopy.undone == "Undone")
    #expect(CorrectionLearnedPillCopy.couldNotUndo == "Couldn\u{2019}t undo")
    #expect(
      CorrectionLearnedPillCopy.saveError(
        LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed))
        == "Couldn\u{2019}t save \u{201C}Tuist\u{201D}")
    #expect(CorrectionLearnedPillCopy.learnedDwellSeconds == 12)
    #expect(CorrectionLearnedPillCopy.hoverResumeFloorSeconds == 2)
    #expect(CorrectionLearnedPillCopy.undoneDwellSeconds == 1.5)
    #expect(CorrectionLearnedPillCopy.errorDwellSeconds == 3)
    #expect(CorrectionLearnedPillCopy.minimumScale == 0.5)
    #expect(CorrectionLearnedPillCopy.maximumSentenceWidth == 400)
  }

  /// The card hosted on its own, as one off-screen `NSHostingView` at its fitting size.
  @MainActor private static func fittingSize(
    of line: CorrectionLearnedPillCopy.Line, palette: PillPalette = .dark
  ) -> CGSize {
    let host = NSHostingView(
      rootView: CorrectionLearnedPillFace(line: line, progress: 0.4, palette: palette))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  /// A phase's line with its text replaced, to stand in for a translation.
  private static func line(
    _ base: CorrectionLearnedPillCopy.Line, title: String? = nil, subtitle: String? = nil,
    undo: String? = nil
  ) -> CorrectionLearnedPillCopy.Line {
    CorrectionLearnedPillCopy.Line(
      title: title ?? base.title, subtitle: subtitle ?? base.subtitle, controls: base.controls,
      isError: base.isError, undoLabel: undo ?? base.undoLabel, closeLabel: base.closeLabel,
      announcement: base.announcement)
  }

  /// The widest the card can be without its controls, from the fonts and metrics, measured
  /// independently of the view's own layout: the paddings, the icon, the text block and the gaps.
  private static func claimedWidth(
    textWidth: CGFloat, undoWord: String
  ) -> CGFloat {
    let undo =
      ceil(
        (undoWord as NSString).size(withAttributes: [
          .font: NSFont.systemFont(ofSize: LearnedPillMetrics.undoSize, weight: .semibold)
        ]).width) + 2 * LearnedPillMetrics.undoPaddingAcross
    return LearnedPillMetrics.leadingPadding + LearnedPillMetrics.discSize
      + LearnedPillMetrics.rowGap + textWidth + LearnedPillMetrics.textToControlsGap + undo
      + LearnedPillMetrics.controlGap + LearnedPillMetrics.closeSize
      + LearnedPillMetrics.trailingPadding
  }

  private static func subtitleWidth(_ text: String) -> CGFloat {
    ceil(
      (text as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: LearnedPillMetrics.subtitleSize, weight: .regular)
      ]).width)
  }

  @Test(
    "a 512-scalar word cannot push Undo and × off the card: the fitting width stays inside the cap plus the controls, and the controls' room is still counted"
  )
  @MainActor func longWordStaysOnScreen() {
    let long = String(repeating: "Supercalifragilistic", count: 26)  // 520 scalars
    #expect(long.unicodeScalars.count >= 512)
    let longLine = CorrectionLearnedPillCopy.line(
      for: LearnedPillFixture.model(canonical: long, kind: .added))
    let shortLine = CorrectionLearnedPillCopy.line(
      for: LearnedPillFixture.model(canonical: "Tuist", kind: .added))
    let long512 = Self.fittingSize(of: longLine)
    let short = Self.fittingSize(of: shortLine)
    #expect(short.width > 0 && short.height > 0, "the short card did not lay out")
    // The word is capped at 400; the icon, gaps, paddings and both controls ride beside it.
    let cap = CorrectionLearnedPillCopy.maximumSentenceWidth
    let beside = Self.claimedWidth(textWidth: 0, undoWord: longLine.undoLabel)
    #expect(long512.width <= cap + beside + 1, "fitting width \(long512.width)")
    #expect(
      long512.width >= cap + beside - 1,
      "the long word did not reach the cap, so the cap is not what limits it: \(long512.width)")
    // Control: a short word is narrower than the cap alone.
    #expect(short.width < cap)
    #expect(long512.height == short.height, "a long word changed the card's height")
  }

  @Test(
    "a three-times-long subtitle and Undo label widen the card instead of clipping the controls: the width covers every part, and the height does not change"
  )
  @MainActor func longTranslationWidensTheCard() {
    let base = CorrectionLearnedPillCopy.line(
      for: LearnedPillFixture.model(canonical: "Tuist", kind: .added))
    let longSubtitle = String(repeating: base.subtitle ?? "", count: 3)
    let longUndo = String(repeating: base.undoLabel, count: 3)
    #expect(!longSubtitle.isEmpty)
    let normal = Self.fittingSize(of: base)
    let widened = Self.fittingSize(
      of: Self.line(base, subtitle: longSubtitle, undo: longUndo))
    #expect(normal.width > 0)
    let claimed = Self.claimedWidth(
      textWidth: Self.subtitleWidth(longSubtitle), undoWord: longUndo)
    #expect(
      widened.width >= claimed - 1,
      "the card is \(widened.width) wide but its parts need \(claimed): a control is clipped")
    #expect(widened.width > normal.width, "the long translation did not widen the card")
    #expect(widened.height == normal.height, "the long translation changed the height")
  }

  @Test(
    "Pending keeps the offer's size (its controls stay laid out, invisible) and a result drops them, so the card changes size once, at the result"
  )
  @MainActor func pendingKeepsTheCardSize() {
    func size(_ phase: LearnedCorrectionPillModel.Phase) -> CGSize {
      Self.fittingSize(
        of: CorrectionLearnedPillCopy.line(
          for: LearnedPillFixture.model(canonical: "Tuist", kind: .added, phase: phase)))
    }
    let offer = size(.learned)
    let pending = size(.undoPending)
    let result = size(.undone)
    #expect(offer.width > 0 && offer.height > 0)
    #expect(pending == offer, "pressing Undo resized the card: \(offer) to \(pending)")
    #expect(result.width < offer.width, "the result card kept the controls' room")
    #expect(result.height == offer.height, "the result changed the height")
  }

  @Test(
    "the light and dark palettes lay the card out to the same size, so an appearance change cannot move the buttons"
  )
  @MainActor func themesShareOneSize() {
    let line = CorrectionLearnedPillCopy.line(for: LearnedPillFixture.model())
    #expect(
      Self.fittingSize(of: line, palette: .light) == Self.fittingSize(of: line, palette: .dark))
  }

  @Test(
    "the card follows the dwell: a paused dwell is a still picture of its frozen share, a running one animates the rest over what is left, and a resume that added time moves the line back"
  )
  func railFollowsTheDwell() {
    let id = PresentationID()
    let now = Date(timeIntervalSince1970: 1_000)
    // Frozen at 7 s left of 12: 5/12 drawn, nothing to animate, however much later it is read.
    let paused = OverlayDwellWindow(id: id, pausedAt: now, remaining: 7, totalSeconds: 12)
    let frozen = CorrectionLearnedPillView.railPlan(for: paused, at: now.addingTimeInterval(500))
    #expect(frozen.start == 5.0 / 12.0 && frozen.animatesOver == nil)
    // Running, 2 s into a 12 s dwell: 2/12 drawn, 10 s to animate.
    let running = OverlayDwellWindow(id: id, startedAt: now, seconds: 12)
    let early = CorrectionLearnedPillView.railPlan(for: running, at: now.addingTimeInterval(2))
    #expect(early.start == 2.0 / 12.0 && early.animatesOver == 10)
    // Resumed with the 2 s floor after 0.5 s were left (11.5 s elapsed): the share is 10/12, so the
    // line moves back from 11.5/12, and it animates over the 2 s.
    let resumed = OverlayDwellWindow(id: id, startedAt: now, seconds: 2, totalSeconds: 12)
    let floor = CorrectionLearnedPillView.railPlan(for: resumed, at: now)
    #expect(floor.start == 10.0 / 12.0 && floor.animatesOver == 2)
    #expect(floor.start < 11.5 / 12.0)
    // A running dwell read after its end is full and animates nothing.
    let late = CorrectionLearnedPillView.railPlan(for: running, at: now.addingTimeInterval(13))
    #expect(late.start == 1 && late.animatesOver == nil)
  }

  @Test(
    "the offer shows Undo and × and the countdown; Pending keeps the room without the controls' action or the countdown; results have no controls and only the error is red"
  )
  func phaseControlPolicy() {
    let learned = CorrectionLearnedPillCopy.line(for: LearnedPillFixture.model(phase: .learned))
    #expect(learned.controls == .live && learned.showsCountdown && !learned.isError)
    #expect(learned.title == "Tuist" && learned.subtitle == "Added to dictionary")
    let pending = CorrectionLearnedPillCopy.line(
      for: LearnedPillFixture.model(canonical: "Tuist", phase: .undoPending))
    #expect(
      pending.controls == .reserved && !pending.showsCountdown && !pending.isError
        && pending.title == "Tuist" && pending.subtitle == "Added to dictionary",
      "Pending keeps the card and its text, with both controls out of play")
    let removed = CorrectionLearnedPillCopy.line(
      for: LearnedPillFixture.model(kind: .added, phase: .undone))
    #expect(
      removed.controls == .none && !removed.isError && removed.subtitle == nil
        && removed.title == "\u{201C}Tuist\u{201D} removed")
    let restored = CorrectionLearnedPillCopy.line(
      for: LearnedPillFixture.model(kind: .updated, phase: .undone))
    #expect(restored.controls == .none && !restored.isError && restored.title == "Undone")
    let failed = CorrectionLearnedPillCopy.line(for: LearnedPillFixture.model(phase: .undoError))
    #expect(
      failed.controls == .none && failed.isError && failed.subtitle == nil
        && failed.title == "Couldn\u{2019}t undo")
  }

  @Test(
    "the announcement is the word, the subtitle and Undo available while Undo is offered, and the bare result line otherwise; Undo of an added word says removed, of an updated word says Undone"
  )
  func announcement() {
    let learned = LearnedPillFixture.model(canonical: "Tuist", kind: .updated)
    #expect(
      CorrectionLearnedPillCopy.announcement(for: learned)
        == "Tuist, Updated in dictionary. Undo available.")
    #expect(
      CorrectionLearnedPillCopy.announcement(
        for: LearnedPillFixture.model(canonical: "Tuist", kind: .added))
        == "Tuist, Added to dictionary. Undo available.")
    #expect(
      CorrectionLearnedPillCopy.announcement(
        for: LearnedPillFixture.model(kind: .added, phase: .undone))
        == "\u{201C}Tuist\u{201D} removed")
    #expect(
      CorrectionLearnedPillCopy.announcement(
        for: LearnedPillFixture.model(kind: .updated, phase: .undone)) == "Undone")
  }
}

// MARK: - Reducer

@MainActor
@Suite("Undo pill: reducer transitions (#996 auto-learn)", .tags(.productOutcome))
struct LearnedCorrectionPillReducerTests {

  private static func pill(_ reducer: OverlayReducer) -> LearnedCorrectionPillModel? {
    guard case .correctionLearned(let model)? = reducer.state.current?.content else { return nil }
    return model
  }

  /// The click: Undo pressed on the shown offer, which leaves the slot Pending.
  @discardableResult
  private static func pressUndo(
    _ reducer: inout OverlayReducer, _ id: PresentationID, _ model: LearnedCorrectionPillModel
  ) -> OverlayPlan {
    reducer.reduce(.action(id, .undoLearnedCorrection(pillID: model.id)))
  }

  @Test(
    "a learned pill is admitted on an idle, empty slot with a 12 s dwell that hover pauses and resumes with a 2 s floor, measured width, and a spoken sentence"
  )
  func admittedWhenIdleAndEmpty() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    let plan = r.reduce(.correctionLearned(model))
    #expect(plan.didChange)
    let shown = try #require(plan.presentation)
    #expect(shown.id == id && shown.content == .correctionLearned(model))
    #expect(shown.expiry == .after(seconds: 12, hover: .resume(floorSeconds: 2)))
    #expect(shown.requestedWidth == .measured && shown.reservesFixedHeight == nil)
    #expect(plan.expiryCommand == .arm(id: id, seconds: 12, target: .presentation))
    #expect(plan.announcement?.isHighPriority == false)
    #expect(plan.announcement?.text == "Tuist, Added to dictionary. Undo available.")
    #expect(r.state.featureSlotIsAvailable == false, "no other feature displaces it")
    // Hover freezes the countdown and leaving resumes it; the clock owns the
    // arithmetic, so the reducer only names the floor.
    let entered = r.reduce(.hoverChanged(id, true))
    #expect(entered.expiryCommand == .pause && entered.didChange == false)
    #expect(r.reduce(.hoverChanged(id, true)) == .noChange, "a repeated enter is dropped")
    let left = r.reduce(.hoverChanged(id, false))
    #expect(left.expiryCommand == .resume(id: id, floorSeconds: 2) && left.didChange == false)
    #expect(r.reduce(.hoverChanged(id, false)) == .noChange, "a repeated exit is dropped")
    #expect(r.reduce(.hoverChanged(PresentationID(), true)) == .noChange, "a stale id is dropped")
  }

  @Test(
    "a result is not hover-resumable, a paused offer is ended by an Escape Recovery pill, and a replacement arms a fresh 12 s"
  )
  func hoverPolicyAcrossTransitions() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    Self.pressUndo(&r, id, model)
    #expect(r.reduce(.hoverChanged(id, true)) == .noChange, "Pending ignores hover")
    #expect(r.reduce(.hoverChanged(id, false)) == .noChange, "Pending ignores hover exit")
    _ = r.reduce(
      .correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    #expect(r.reduce(.hoverChanged(id, true)) == .noChange, "an Undone result ignores hover")

    var ids = [id, PresentationID()]
    var p = OverlayReducer(makeID: { ids.removeFirst() })
    _ = p.reduce(.correctionLearned(model))
    #expect(p.reduce(.hoverChanged(id, true)).expiryCommand == .pause)
    let second = LearnedPillFixture.model(canonical: "Saira")
    let replaced = p.reduce(.correctionLearned(second))
    #expect(replaced.effects == [.correctionLearnedEnded(pillID: model.id, presentation: id)])
    guard case .arm(_, let seconds, .presentation) = replaced.expiryCommand else {
      Issue.record("the replacement did not arm: \(replaced.expiryCommand)")
      return
    }
    #expect(seconds == 12, "the replacement inherited the paused remainder")
    #expect(!p.state.isHovered, "the replacement inherited the hover")

    var escapeIDs = [id, PresentationID()]
    var e = OverlayReducer(makeID: { escapeIDs.removeFirst() })
    _ = e.reduce(.correctionLearned(model))
    _ = e.reduce(.hoverChanged(id, true))
    let escape = e.reduce(.pipeline(.escapeRecovery(transcriptID: UUID())))
    #expect(escape.effects.contains(.correctionLearnedEnded(pillID: model.id, presentation: id)))
    var rearmed = false
    if case .arm(_, let seconds, _) = escape.expiryCommand { rearmed = seconds == 3 }
    #expect(rearmed, "Escape Recovery arms its own 3 s, not the paused offer's remainder")
  }

  @Test(
    "refused while the pipeline is busy, while another feature or notice holds the slot, and for a result-phase model"
  )
  func refusals() {
    var busy = OverlayReducer()
    busy.startRecordingForTests(audioLevel: 0.2)
    let before = busy.state.current
    #expect(busy.reduce(.correctionLearned(LearnedPillFixture.model())) == .noChange)
    #expect(busy.state.current == before)

    var bluetooth = OverlayReducer()
    _ = bluetooth.reduce(.bluetoothAwareness)
    #expect(bluetooth.reduce(.correctionLearned(LearnedPillFixture.model())) == .noChange)
    #expect(bluetooth.state.current?.content == .bluetoothAwareness)

    var status = OverlayReducer()
    _ = status.reduce(.importStatus(message: "Imported 12 words"))
    #expect(status.reduce(.correctionLearned(LearnedPillFixture.model())) == .noChange)

    var empty = OverlayReducer()
    #expect(empty.reduce(.correctionLearned(LearnedPillFixture.model(phase: .undone))) == .noChange)
    #expect(
      empty.reduce(.correctionLearned(LearnedPillFixture.model(phase: .undoPending))) == .noChange,
      "a Pending model cannot create a pill either")
    #expect(empty.state.current == nil)
  }

  @Test(
    "a different learned pill replaces the current one: new identity, fresh 12 s, one end effect for the outgoing offer; a same-pill repeat changes nothing"
  )
  func replacementAndRepeat() throws {
    var ids = [PresentationID(), PresentationID()]
    var r = OverlayReducer(makeID: { ids.removeFirst() })
    let first = LearnedPillFixture.model(canonical: "Tuist")
    let firstID = try #require(r.reduce(.correctionLearned(first)).presentation?.id)

    let repeatPlan = r.reduce(.correctionLearned(first))
    #expect(!repeatPlan.didChange && repeatPlan.expiryCommand == .unchanged)
    #expect(r.state.current?.id == firstID)

    let second = LearnedPillFixture.model(canonical: "Saira", kind: .updated)
    let plan = r.reduce(.correctionLearned(second))
    #expect(plan.didChange)
    let shown = try #require(plan.presentation)
    #expect(shown.id != firstID && shown.content == .correctionLearned(second))
    #expect(plan.expiryCommand == .arm(id: shown.id, seconds: 12, target: .presentation))
    #expect(plan.effects == [.correctionLearnedEnded(pillID: first.id, presentation: firstID)])
    #expect(plan.announcement?.text == "Saira, Updated in dictionary. Undo available.")
  }

  @Test("a learned pill replaces a result still on screen, and the result owes no end effect")
  func replacesAResult() throws {
    var ids = [PresentationID(), PresentationID()]
    var r = OverlayReducer(makeID: { ids.removeFirst() })
    let first = LearnedPillFixture.model()
    let firstID = try #require(r.reduce(.correctionLearned(first)).presentation?.id)
    Self.pressUndo(&r, firstID, first)
    _ = r.reduce(.correctionLearnedResult(pillID: first.id, presentation: firstID, phase: .undone))
    let plan = r.reduce(.correctionLearned(LearnedPillFixture.model(canonical: "Saira")))
    #expect(plan.didChange && plan.effects.isEmpty)
    #expect(Self.pill(r)?.canonical == "Saira")
  }

  @Test(
    "Undo is accepted once for the shown pill in its learned phase, running or paused: the same presentation morphs to Pending with no button, hover cleared, the press delivered and the clock told to enter Pending; another id, a second press or a result phase reaches nobody"
  )
  func undoGate() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    #expect(r.reduce(.action(id, .undoLearnedCorrection(pillID: UUID()))) == .noChange)
    #expect(
      r.reduce(.action(PresentationID(), .undoLearnedCorrection(pillID: model.id))) == .noChange)

    _ = r.reduce(.hoverChanged(id, true))
    #expect(r.state.isHovered)
    let revisionBefore = r.state.slotRevision
    let press = Self.pressUndo(&r, id, model)
    #expect(press.deliverAction == .undoLearnedCorrection(pillID: model.id))
    #expect(press.didChange && press.announcement == nil)
    let pending = try #require(press.presentation)
    #expect(pending.id == id, "the morph keeps the presentation identity")
    #expect(Self.pill(r)?.phase == .undoPending && Self.pill(r)?.id == model.id)
    #expect(CorrectionLearnedPillCopy.line(for: try #require(Self.pill(r))).controls == .reserved)
    #expect(pending.expiry == .after(seconds: 3, hover: .ignore))
    #expect(press.expiryCommand == .enterPending(id: id, minimumSeconds: 3))
    #expect(!r.state.isHovered, "the hover flag is cleared")
    #expect(r.state.slotRevision != revisionBefore)

    #expect(Self.pressUndo(&r, id, model) == .noChange, "a repeat press while Pending is dropped")
    _ = r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    #expect(Self.pressUndo(&r, id, model) == .noChange, "no button on a result")
  }

  @Test(
    "× closes the unanswered offer, running or paused, exactly as expiry does: the slot empties, hover and the dwell are cleared and one end effect is emitted; a stale id, another pill, Pending and a result drop it, and a second press or an expiry already in flight finds nothing"
  )
  func dismissGate() throws {
    let id = PresentationID()
    let model = LearnedPillFixture.model()

    // Running.
    var r = OverlayReducer(makeID: { id })
    _ = r.reduce(.correctionLearned(model))
    #expect(r.reduce(.action(id, .dismissLearnedCorrection(pillID: UUID()))) == .noChange)
    #expect(
      r.reduce(.action(PresentationID(), .dismissLearnedCorrection(pillID: model.id))) == .noChange)
    #expect(Self.pill(r)?.phase == .learned, "a refused press changed the slot")
    let plan = r.reduce(.action(id, .dismissLearnedCorrection(pillID: model.id)))
    #expect(plan.presentation == nil && plan.didChange && plan.deliverAction == nil)
    #expect(plan.expiryCommand == .cancel)
    #expect(plan.effects == [.correctionLearnedEnded(pillID: model.id, presentation: id)])
    #expect(plan.announcement == nil)
    #expect(r.state.current == nil && r.state.pipelineIntent == .hidden && !r.state.isHovered)
    #expect(
      r.reduce(.action(id, .dismissLearnedCorrection(pillID: model.id))) == .noChange,
      "a second press after the slot closed")
    #expect(r.reduce(.expiryFired(id)) == .noChange, "an expiry already in flight after ×")

    // The same plan as expiry, apart from nothing: the slot, command and effect match.
    var expiring = OverlayReducer(makeID: { id })
    _ = expiring.reduce(.correctionLearned(model))
    let expired = expiring.reduce(.expiryFired(id))
    #expect(
      plan.presentation == expired.presentation && plan.expiryCommand == expired.expiryCommand
        && plan.effects == expired.effects)

    // Paused: hover set, the same close, and the hover flag cleared.
    var p = OverlayReducer(makeID: { id })
    _ = p.reduce(.correctionLearned(model))
    #expect(p.reduce(.hoverChanged(id, true)).expiryCommand == .pause)
    #expect(p.state.isHovered)
    let pausedPlan = p.reduce(.action(id, .dismissLearnedCorrection(pillID: model.id)))
    #expect(pausedPlan.presentation == nil && pausedPlan.expiryCommand == .cancel)
    #expect(pausedPlan.effects == [.correctionLearnedEnded(pillID: model.id, presentation: id)])
    #expect(p.state.current == nil && !p.state.isHovered)
    #expect(p.reduce(.hoverChanged(id, false)) == .noChange, "a hover exit after × resumes nothing")

    // Pending: dropped, and Undo's claimed record is untouched (no end effect).
    var pending = OverlayReducer(makeID: { id })
    _ = pending.reduce(.correctionLearned(model))
    Self.pressUndo(&pending, id, model)
    #expect(pending.reduce(.action(id, .dismissLearnedCorrection(pillID: model.id))) == .noChange)
    #expect(Self.pill(pending)?.phase == .undoPending)

    // Results: no button, so dropped.
    for phase in [LearnedCorrectionPillModel.Phase.undone, .undoError] {
      var result = OverlayReducer(makeID: { id })
      _ = result.reduce(.correctionLearned(model))
      Self.pressUndo(&result, id, model)
      _ = result.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: phase))
      #expect(Self.pill(result)?.phase == phase)
      #expect(
        result.reduce(.action(id, .dismissLearnedCorrection(pillID: model.id))) == .noChange,
        "a result (\(phase)) took ×")
    }
  }

  @Test("a result cannot be applied to a pill that is still the unanswered offer")
  func resultNeedsPending() {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    for phase in [LearnedCorrectionPillModel.Phase.undone, .undoError, .learned, .undoPending] {
      #expect(
        r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: phase))
          == .noChange, "phase \(phase) on a .learned offer")
    }
    #expect(Self.pill(r)?.phase == .learned)
  }

  @Test(
    "Undone morphs the current offer in place: same identity, phase undone, fresh 1.5 s; Undo error morphs to 3 s; a result never morphs again; a stale pair is a no-op"
  )
  func resultMorphs() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    Self.pressUndo(&r, id, model)
    #expect(
      r.reduce(
        .correctionLearnedResult(pillID: model.id, presentation: PresentationID(), phase: .undone))
        == .noChange)
    #expect(
      r.reduce(.correctionLearnedResult(pillID: UUID(), presentation: id, phase: .undone))
        == .noChange)
    for phase in [LearnedCorrectionPillModel.Phase.learned, .undoPending] {
      #expect(
        r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: phase))
          == .noChange, "a result phase is only undone or undoError (\(phase))")
    }

    let plan = r.reduce(
      .correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    #expect(
      plan.announcement?.text == "\u{201C}Tuist\u{201D} removed",
      "the result copy is announced once, with the plan; an added word was removed")
    #expect(plan.announcement?.isHighPriority == false)
    let shown = try #require(plan.presentation)
    #expect(shown.id == id && Self.pill(r)?.phase == .undone && Self.pill(r)?.id == model.id)
    #expect(shown.expiry == .after(seconds: 1.5, hover: .ignore))
    #expect(plan.expiryCommand == .arm(id: id, seconds: 1.5, target: .presentation))
    #expect(
      r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undoError))
        == .noChange)

    var e = OverlayReducer(makeID: { id })
    _ = e.reduce(.correctionLearned(model))
    Self.pressUndo(&e, id, model)
    let errorPlan = e.reduce(
      .correctionLearnedResult(pillID: model.id, presentation: id, phase: .undoError))
    #expect(Self.pill(e)?.phase == .undoError)
    #expect(errorPlan.expiryCommand == .arm(id: id, seconds: 3, target: .presentation))
    #expect(errorPlan.announcement?.text == "Couldn\u{2019}t undo")

    // Undo of an UPDATED word restores the earlier entry, so it says Undone, not removed.
    let updated = LearnedPillFixture.model(canonical: "Saira", kind: .updated)
    var u = OverlayReducer(makeID: { id })
    _ = u.reduce(.correctionLearned(updated))
    Self.pressUndo(&u, id, updated)
    let updatedPlan = u.reduce(
      .correctionLearnedResult(pillID: updated.id, presentation: id, phase: .undone))
    #expect(updatedPlan.announcement?.text == "Undone")
  }

  @Test(
    "expiry of the learned phase reports one end effect; expiry of a result reports none; close empties the slot without an effect and a stale close is a no-op"
  )
  func expiryAndClose() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    let expired = r.reduce(.expiryFired(id))
    #expect(expired.presentation == nil && expired.expiryCommand == .cancel)
    #expect(expired.effects == [.correctionLearnedEnded(pillID: model.id, presentation: id)])
    #expect(r.state.pipelineIntent == .hidden)

    var s = OverlayReducer(makeID: { id })
    _ = s.reduce(.correctionLearned(model))
    Self.pressUndo(&s, id, model)
    _ = s.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    let resultExpired = s.reduce(.expiryFired(id))
    #expect(resultExpired.presentation == nil && resultExpired.effects.isEmpty)

    var p = OverlayReducer(makeID: { id })
    _ = p.reduce(.correctionLearned(model))
    Self.pressUndo(&p, id, model)
    let pendingExpired = p.reduce(.expiryFired(id))
    #expect(
      pendingExpired.presentation == nil && pendingExpired.expiryCommand == .cancel
        && pendingExpired.effects.isEmpty,
      "Pending closes silently: the record is already claimed, so no end report")
    #expect(p.state.pipelineIntent == .hidden && p.state.current == nil)
    #expect(
      p.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
        == .noChange, "a late result cannot reopen the closed slot")
    #expect(p.state.current == nil)

    var c = OverlayReducer(makeID: { id })
    _ = c.reduce(.correctionLearned(model))
    #expect(c.reduce(.correctionLearnedClose(pillID: UUID())) == .noChange)
    let closed = c.reduce(.correctionLearnedClose(pillID: model.id))
    #expect(closed.presentation == nil && closed.expiryCommand == .cancel && closed.effects.isEmpty)
    #expect(c.state.current == nil)
    #expect(c.reduce(.correctionLearnedClose(pillID: model.id)) == .noChange)
  }

  @Test(
    "while Pending: a new learned word, a save error, a recording and Escape Recovery take the slot with no end report; a late result then reaches nobody"
  )
  func pendingExits() throws {
    let id = PresentationID()
    let model = LearnedPillFixture.model()
    let error = LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed)

    func pending() -> OverlayReducer {
      var ids = [id, PresentationID(), PresentationID()]
      var r = OverlayReducer(makeID: { ids.removeFirst() })
      _ = r.reduce(.correctionLearned(model))
      Self.pressUndo(&r, id, model)
      return r
    }

    var learned = pending()
    let newer = learned.reduce(.correctionLearned(LearnedPillFixture.model(canonical: "Saira")))
    #expect(newer.didChange && newer.effects.isEmpty, "replacing Pending reports nothing ended")
    #expect(newer.expiryCommand != .unchanged)
    #expect(Self.pill(learned)?.canonical == "Saira" && Self.pill(learned)?.phase == .learned)

    var saveError = pending()
    let notice = saveError.reduce(.correctionLearnedSaveError(error))
    #expect(notice.didChange && notice.effects.isEmpty)
    #expect(saveError.state.current?.content == .correctionLearnedSaveError(error))

    var recording = pending()
    let recordingPlan = recording.startRecordingForTests(audioLevel: 0.1)
    #expect(
      !recordingPlan.effects.contains(.correctionLearnedEnded(pillID: model.id, presentation: id)),
      "a recording preempting Pending reports nothing ended")
    guard case .recording? = recording.state.current?.content else {
      Issue.record("the recording did not take the slot")
      return
    }

    var escape = pending()
    let escapePlan = escape.reduce(.pipeline(.escapeRecovery(transcriptID: UUID())))
    #expect(escapePlan.effects.isEmpty, "Escape Recovery preempting Pending reports nothing ended")
    let recovery = try #require(escapePlan.presentation, "Escape Recovery did not take the slot")
    guard case .escapeRecovery = recovery.content, escape.state.current?.id == recovery.id else {
      Issue.record("Escape Recovery is not what holds the slot after preempting Pending")
      return
    }
    #expect(
      escapePlan.expiryCommand == .arm(id: recovery.id, seconds: 3, target: .presentation),
      "Escape Recovery arms its own 3 s, not Pending's")

    var saw = [learned, saveError, recording, escape]
    for i in saw.indices {
      let before = saw[i].state.current
      #expect(
        saw[i].reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
          == .noChange, "a late result must leave scenario \(i) alone")
      #expect(saw[i].state.current == before)
    }
  }

  @Test(
    "a recording displaces the learned offer with one end effect; the save-error notice takes an empty slot or replaces a learned pill, 3 s, no button"
  )
  func preemptionAndSaveError() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    r.startRecordingForTests(audioLevel: 0.1)
    guard case .recording? = r.state.current?.content else {
      Issue.record("the recording did not take the slot")
      return
    }

    var ids = [PresentationID(), PresentationID()]
    var e = OverlayReducer(makeID: { ids.removeFirst() })
    let error = LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed)
    let plan = e.reduce(.correctionLearnedSaveError(error))
    let shown = try #require(plan.presentation)
    #expect(shown.content == .correctionLearnedSaveError(error))
    #expect(
      shown.expiry == .after(seconds: 3, hover: .ignore) && shown.requestedWidth == .measured)
    #expect(plan.announcement?.text == "Couldn\u{2019}t save \u{201C}Tuist\u{201D}")
    #expect(
      e.reduce(.action(shown.id, .undoLearnedCorrection(pillID: UUID()))) == .noChange, "no button")
    #expect(e.reduce(.expiryFired(shown.id)).effects.isEmpty)

    var learnedIDs = [id, PresentationID()]
    var l = OverlayReducer(makeID: { learnedIDs.removeFirst() })
    _ = l.reduce(.correctionLearned(model))
    let replaced = l.reduce(.correctionLearnedSaveError(error))
    #expect(replaced.effects == [.correctionLearnedEnded(pillID: model.id, presentation: id)])

    var b = OverlayReducer()
    _ = b.reduce(.bluetoothAwareness)
    #expect(
      b.reduce(.correctionLearnedSaveError(error)) == .noChange, "never displaces another feature")
  }
}

// MARK: - Director

@MainActor
@Suite("Undo pill: director identity and clock (#996 auto-learn)", .tags(.productOutcome))
struct LearnedCorrectionPillDirectorTests {

  private final class Log {
    var undos = 0
    var ended = 0
    var results: [PillPresentationResult] = []
    var announcements: [OverlayAnnouncement] = []
  }

  private func director(_ clock: LearnedPillClock, _ log: Log) -> (
    OverlayDirector, WindowlessOverlayHost
  ) {
    let host = WindowlessOverlayHost()
    return (director(clock, log, host: host), host)
  }

  private func director(
    _ clock: LearnedPillClock, _ log: Log, host: any OverlayWindowHosting
  ) -> OverlayDirector {
    OverlayDirector(
      host: host,
      scheduler: clock.scheduler,
      announce: { log.announcements.append($0) },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, openMicrophoneHelp: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() },
      now: { clock.date })
  }

  private func request(
    _ model: LearnedCorrectionPillModel, _ log: Log, stillWanted: @escaping () -> Bool = { true }
  ) -> PillRequest {
    .correctionLearned(
      model: model, isStillWanted: stillWanted,
      onUndo: { log.undos += 1 }, onEnded: { log.ended += 1 })
  }

  private func shown(_ d: OverlayDirector) -> LearnedCorrectionPillModel? {
    guard case .correctionLearned(let model)? = d.renderModel.state.presentation?.content else {
      return nil
    }
    return model
  }

  @Test("the pill is on screen at 11.999 s after admission and gone at 12.000 s, reported ended once")
  func undoWindow() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, _) = director(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)) { log.results.append($0) })
    #expect(log.results == [.presented(receipt)])
    #expect(clock.armedSeconds == [12], "the dwell armed at admission, for exactly twelve seconds")
    clock.advance(to: 11.999)
    #expect(shown(d)?.id == model.id && log.ended == 0)
    clock.advance(to: 12.0)
    #expect(d.renderModel.state.presentation == nil)
    #expect(log.ended == 1 && log.undos == 0)
  }

  @Test(
    "a press on the admitted pill reaches its handler once; a press naming another pill reaches nothing; a press after Undone reaches nothing"
  )
  func undoIsIdentityBound() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = director(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    #expect(log.announcements.count == 1 && log.announcements.first?.isHighPriority == false)
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: UUID()), for: receipt)
    #expect(log.undos == 0)
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    #expect(log.undos == 1 && shown(d)?.phase == .undoPending)
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    #expect(log.undos == 1, "a repeat press while Pending is dropped")

    d.resolveLearnedCorrection(
      pillID: model.id, presentation: receipt.presentationID, phase: .undone)
    #expect(shown(d)?.phase == .undone && d.isCurrent(receipt))
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    #expect(log.undos == 1, "no button on a result")
  }

  @Test(
    "Undone shows for 1.5 s from the morph and leaves without an end report; Undo error and the save error leave at 3 s"
  )
  func resultClocks() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = director(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    clock.advance(to: 0.5)
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    d.resolveLearnedCorrection(
      pillID: model.id, presentation: receipt.presentationID, phase: .undone)
    #expect(clock.armedSeconds == [12, 11.5, 1.5], "Pending kept the 11.5 s left, then 1.5 s")
    clock.advance(to: 1.999)
    #expect(shown(d)?.phase == .undone, "the old 12 s deadline was cancelled")
    clock.advance(to: 2.0)
    #expect(d.renderModel.state.presentation == nil, "1.5 s after the morph at 0.5 s")
    #expect(log.ended == 0, "a result is not an unanswered offer")

    let clock2 = LearnedPillClock()
    let log2 = Log()
    let (d2, host2) = director(clock2, log2)
    let model2 = LearnedPillFixture.model()
    let receipt2 = try #require(d2.present(request(model2, log2)))
    try host2.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model2.id), for: receipt2)
    d2.resolveLearnedCorrection(
      pillID: model2.id, presentation: receipt2.presentationID, phase: .undoError)
    clock2.advance(to: 2.999)
    #expect(shown(d2)?.phase == .undoError)
    clock2.advance(to: 3.0)
    #expect(d2.renderModel.state.presentation == nil && log2.ended == 0)

    let clock3 = LearnedPillClock()
    let log3 = Log()
    let (d3, _) = director(clock3, log3)
    let error = LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed)
    _ = d3.present(.correctionLearnedSaveError(error)) { log3.results.append($0) }
    #expect(log3.results.count == 1 && clock3.armedSeconds == [3])
    clock3.advance(to: 2.999)
    #expect(d3.renderModel.state.presentation?.content == .correctionLearnedSaveError(error))
    clock3.advance(to: 3.0)
    #expect(d3.renderModel.state.presentation == nil)
  }

  @Test(
    "a second learned pill replaces the first with its own identity and dwell; the first is reported ended once and its press is dead"
  )
  func replacementEndsTheFirstOnce() throws {
    let clock = LearnedPillClock()
    let first = Log()
    let second = Log()
    let (d, host) = director(clock, first)
    let m1 = LearnedPillFixture.model(canonical: "Tuist")
    let r1 = try #require(d.present(request(m1, first)))
    clock.advance(to: 1.0)
    let m2 = LearnedPillFixture.model(canonical: "Saira", kind: .updated)
    let r2 = try #require(d.present(request(m2, second)))
    #expect(r2.presentationID != r1.presentationID)
    #expect(first.ended == 1 && second.ended == 0)
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: m1.id), for: r1)
    #expect(first.undos == 0, "the outgoing binding is gone")
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: m2.id), for: r2)
    #expect(second.undos == 1)
    clock.advance(to: 12.999)
    #expect(shown(d)?.id == m2.id, "the second pill's own twelve seconds run from 1.0 s")
    clock.advance(to: 13.0)
    // The second pill was answered with Undo, so it is Pending and closes without an end report.
    #expect(d.renderModel.state.presentation == nil && first.ended == 1 && second.ended == 0)
  }

  @Test(
    "a same-pill repeat keeps the original binding: the press and the end still reach the first owner"
  )
  func repeatKeepsTheOriginalBinding() throws {
    let clock = LearnedPillClock()
    let first = Log()
    let second = Log()
    let (d, host) = director(clock, first)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, first)))
    #expect(
      d.present(request(model, second)) == nil,
      "a repeat keeps the incumbent's receipt; it is not a new admission")
    #expect(shown(d)?.id == model.id && d.isCurrent(receipt))
    #expect(clock.armedSeconds == [12], "the repeat did not re-arm the dwell")
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    #expect(first.undos == 1 && second.undos == 0)
    clock.advance(to: 12)
    #expect(first.ended == 0 && second.ended == 0, "Pending closes without an end report")

    // Unanswered, the same repeat leaves the end with the FIRST owner.
    let clock2 = LearnedPillClock()
    let first2 = Log()
    let second2 = Log()
    let (d2, _) = director(clock2, first2)
    let model2 = LearnedPillFixture.model()
    _ = try #require(d2.present(request(model2, first2)))
    #expect(d2.present(request(model2, second2)) == nil)
    clock2.advance(to: 12)
    #expect(first2.ended == 1 && second2.ended == 0)
  }

  // MARK: Hover pause and resume (#4675)

  /// Hosts the director like `WindowlessOverlayHost` and keeps the root the
  /// director built, so a test can inject a hover event at the root's own
  /// `sendEvent` callback (the windowless host has no hover entry point).
  ///
  /// **What this does and does not prove.** It proves the director, reducer and
  /// clock react to `.hoverChanged` arriving at that callback, through the
  /// published dwell and its progress share. It does NOT prove that SwiftUI's
  /// `.onHover` fires, that a real pointer reaches the panel, or that the rail
  /// is drawn frozen; those are Live UAT.
  @MainActor
  private final class HoverHost: OverlayWindowHosting {
    private let inner = WindowlessOverlayHost()
    private var root: OverlayRootView?

    func present(
      _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
      position: OverlayPillPosition
    ) -> Bool {
      root = (view as? NSHostingView<OverlayRootView>)?.rootView
      return inner.present(
        view, width: width, fixedHeight: fixedHeight, isFresh: isFresh, position: position)
    }
    func resizeCurrentPresentation(to size: CGSize) { inner.resizeCurrentPresentation(to: size) }
    func hide() { inner.hide() }

    func hover(_ entering: Bool, over receipt: PillReceipt) throws {
      let hosted = try #require(root, "nothing was presented, so no root exists to hover")
      hosted.sendEvent(.hoverChanged(receipt.presentationID, entering))
    }

    func press(_ action: PillAction, over receipt: PillReceipt) throws {
      let hosted = try #require(root, "nothing was presented, so no root exists to press")
      hosted.sendEvent(.action(receipt.presentationID, action))
    }
  }

  private func hoverDirector(_ clock: LearnedPillClock, _ log: Log) -> (OverlayDirector, HoverHost) {
    let host = HoverHost()
    return (director(clock, log, host: host), host)
  }

  @Test(
    "a hover event at the root freezes the published dwell and its progress share, and a leave event resumes the ordinary remainder to a single end"
  )
  func hoverEventFreezesAndResumesThePublishedDwell() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))

    clock.advance(to: 5)
    try host.hover(true, over: receipt)
    let frozen = try #require(d.renderModel.state.dwell, "a hover published no frozen dwell")
    #expect(frozen.pausedRemaining == 7 && frozen.totalSeconds == 12)
    clock.advance(to: 100)
    #expect(shown(d)?.id == model.id && log.ended == 0, "the paused offer expired under the pointer")
    #expect(d.renderModel.state.dwell == frozen, "the frozen dwell moved while hovered")
    #expect(
      frozen.elapsedFraction(at: clock.date) == 5.0 / 12.0, "the rail share changed during hover")

    try host.hover(false, over: receipt)
    #expect(clock.armedSeconds == [12, 7], "leaving armed something other than the 7 s remainder")
    let running = try #require(d.renderModel.state.dwell)
    #expect(!running.isPaused && running.seconds == 7 && running.totalSeconds == 12)
    #expect(running.elapsedFraction(at: clock.date) == 5.0 / 12.0)
    clock.advance(to: 106.999)
    #expect(shown(d)?.id == model.id && log.ended == 0)
    clock.advance(to: 107)
    #expect(d.renderModel.state.presentation == nil)
    #expect(log.ended == 1 && log.undos == 0, "the offer must be reported ended exactly once")
  }

  @Test("a leave event with 0.5 s left resumes with the 2 s floor, and the published progress share moves back")
  func hoverExitEventFloorRaisesTheRemainder() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))

    clock.advance(to: 11.5)
    try host.hover(true, over: receipt)
    let frozen = try #require(d.renderModel.state.dwell)
    #expect(frozen.pausedRemaining == 0.5)
    clock.advance(to: 61.5)
    try host.hover(false, over: receipt)

    #expect(clock.armedSeconds == [12, 2])
    let running = try #require(d.renderModel.state.dwell)
    #expect(running.totalSeconds == 12)
    #expect(running.elapsedFraction(at: clock.date) == 10.0 / 12.0)
    #expect(running.elapsedFraction(at: clock.date) < frozen.elapsedFraction(at: clock.date))
    clock.advance(to: 63.499)
    #expect(shown(d)?.id == model.id && log.ended == 0)
    clock.advance(to: 63.5)
    #expect(d.renderModel.state.presentation == nil && log.ended == 1)
  }

  @Test(
    "a second learned word replaces a paused offer with a fresh 12 s, the first is reported ended once and its hover exit is dead"
  )
  func replacementOfAPausedOffer() throws {
    let clock = LearnedPillClock()
    let first = Log()
    let second = Log()
    let (d, host) = hoverDirector(clock, first)
    let m1 = LearnedPillFixture.model(canonical: "Tuist")
    let r1 = try #require(d.present(request(m1, first)))
    clock.advance(to: 3)
    try host.hover(true, over: r1)

    let m2 = LearnedPillFixture.model(canonical: "Saira", kind: .updated)
    let r2 = try #require(d.present(request(m2, second)))
    #expect(first.ended == 1 && second.ended == 0)
    #expect(clock.armedSeconds == [12, 12], "the replacement did not arm a fresh 12 s")
    let fresh = try #require(d.renderModel.state.dwell)
    #expect(fresh.id == r2.presentationID && !fresh.isPaused && fresh.seconds == 12)

    // The outgoing pill's pointer leaving must not resume its discarded remainder.
    try host.hover(false, over: r1)
    #expect(clock.armedSeconds == [12, 12])
    clock.advance(to: 14.999)
    #expect(shown(d)?.id == m2.id, "the second pill's own twelve seconds run from 3.0 s")
    clock.advance(to: 15)
    #expect(d.renderModel.state.presentation == nil)
    #expect(first.ended == 1 && second.ended == 1)
  }

  @Test("a recording preempts a paused offer, which is reported ended, and nothing resumes later")
  func recordingPreemptsAPausedOffer() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let receipt = try #require(d.present(request(LearnedPillFixture.model(), log)))
    clock.advance(to: 2)
    try host.hover(true, over: receipt)

    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0.2, audioLevelProvider: { 0.2 }, recordingElapsedProvider: { nil },
          isLocked: false)))
    #expect(log.ended == 1)
    guard case .recording? = d.renderModel.state.presentation?.content else {
      Issue.record("the recording did not take the slot")
      return
    }
    let armed = clock.armedSeconds
    try host.hover(false, over: receipt)
    #expect(clock.armedSeconds == armed, "the preempted offer's remainder came back")
    clock.advance(to: 500)
    guard case .recording? = d.renderModel.state.presentation?.content else {
      Issue.record("a dead offer's timer ended the recording")
      return
    }
    #expect(log.ended == 1)
  }

  @Test("Escape Recovery preempts a paused offer, which is reported ended, and arms its own 3 s")
  func escapeRecoveryPreemptsAPausedOffer() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let receipt = try #require(d.present(request(LearnedPillFixture.model(), log)))
    clock.advance(to: 2)
    try host.hover(true, over: receipt)

    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil, targetWindow: nil,
      takeFacts: .testNone)
    _ = d.present(.escapeRecovery(payload: payload, onPaste: { _ in }))

    #expect(log.ended == 1)
    guard case .escapeRecovery? = d.renderModel.state.presentation?.content else {
      Issue.record("Escape Recovery did not take the slot")
      return
    }
    #expect(clock.armedSeconds == [12, 3], "Escape Recovery inherited the paused remainder")
    let dwell = try #require(d.renderModel.state.dwell)
    #expect(!dwell.isPaused && dwell.seconds == 3 && dwell.totalSeconds == 3)
  }

  // MARK: Undo pending (#4675)

  @Test(
    "Undo pressed while running enters Pending with the live remainder when it is above 3 s, or with 3 s when less; the 12 s callback is replaced and Pending closes silently"
  )
  func undoFromRunning() throws {
    // 7 s left: above the minimum, so the remainder is kept and nothing is extended.
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    clock.advance(to: 5)
    try host.press(.undoLearnedCorrection(pillID: model.id), over: receipt)
    #expect(shown(d)?.phase == .undoPending && d.isCurrent(receipt))
    #expect(clock.armedSeconds == [12, 7])
    let dwell = try #require(d.renderModel.state.dwell)
    #expect(dwell.id == receipt.presentationID && !dwell.isPaused && dwell.seconds == 7)
    clock.advance(to: 11.999)
    #expect(shown(d)?.phase == .undoPending)
    clock.advance(to: 12)
    #expect(d.renderModel.state.presentation == nil)
    #expect(log.ended == 0 && log.undos == 1, "Pending closes with no end report")

    // 1.5 s left: Pending is raised to its 3 s minimum, and the old 12 s callback does nothing.
    let clock2 = LearnedPillClock()
    let log2 = Log()
    let (d2, host2) = hoverDirector(clock2, log2)
    let model2 = LearnedPillFixture.model()
    let receipt2 = try #require(d2.present(request(model2, log2)))
    clock2.advance(to: 10.5)
    try host2.press(.undoLearnedCorrection(pillID: model2.id), over: receipt2)
    #expect(clock2.armedSeconds == [12, 3])
    clock2.advance(to: 13.499)
    #expect(shown(d2)?.phase == .undoPending, "the old 12 s deadline closed Pending early")
    clock2.advance(to: 13.5)
    #expect(d2.renderModel.state.presentation == nil && log2.ended == 0)
  }

  @Test(
    "Undo pressed while hover has paused the offer enters Pending from the frozen remainder: 3 s when little is left, the remainder when more; hover on Pending is ignored"
  )
  func undoFromPaused() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    clock.advance(to: 11.5)
    try host.hover(true, over: receipt)
    clock.advance(to: 60)
    try host.press(.undoLearnedCorrection(pillID: model.id), over: receipt)
    #expect(clock.armedSeconds == [12, 3], "0.5 s were frozen, so the 3 s minimum arms")
    #expect(shown(d)?.phase == .undoPending)
    let pendingDwell = try #require(d.renderModel.state.dwell)
    #expect(!pendingDwell.isPaused)
    try host.hover(true, over: receipt)
    try host.hover(false, over: receipt)
    #expect(d.renderModel.state.dwell == pendingDwell, "hover changed the Pending dwell")
    #expect(clock.armedSeconds == [12, 3], "hover re-timed Pending")
    clock.advance(to: 62.999)
    #expect(shown(d)?.phase == .undoPending)
    clock.advance(to: 63)
    #expect(d.renderModel.state.presentation == nil && log.ended == 0)

    let clock2 = LearnedPillClock()
    let log2 = Log()
    let (d2, host2) = hoverDirector(clock2, log2)
    let model2 = LearnedPillFixture.model()
    let receipt2 = try #require(d2.present(request(model2, log2)))
    clock2.advance(to: 5)
    try host2.hover(true, over: receipt2)
    clock2.advance(to: 60)
    try host2.press(.undoLearnedCorrection(pillID: model2.id), over: receipt2)
    #expect(clock2.armedSeconds == [12, 7], "7 s frozen is above the minimum")
  }

  @Test(
    "× at the root closes the offer once, whether running or paused: the pill leaves, the end callback fires once, Undo never fires, and no deadline or hover resume brings anything back"
  )
  func dismissThroughTheRoot() throws {
    // Running, 5 s in.
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    clock.advance(to: 5)
    try host.press(.dismissLearnedCorrection(pillID: model.id), over: receipt)
    #expect(d.renderModel.state.presentation == nil, "× left the pill on screen")
    #expect(log.ended == 1 && log.undos == 0)
    #expect(d.renderModel.state.dwell == nil, "the published dwell outlived the pill")
    try host.press(.dismissLearnedCorrection(pillID: model.id), over: receipt)
    clock.advance(to: 500)
    #expect(log.ended == 1 && log.undos == 0, "a repeat press or the old 12 s deadline reported again")
    #expect(clock.armedSeconds == [12], "× armed something")

    // Paused: hover first, then ×; the frozen remainder must not come back.
    let clock2 = LearnedPillClock()
    let log2 = Log()
    let (d2, host2) = hoverDirector(clock2, log2)
    let model2 = LearnedPillFixture.model()
    let receipt2 = try #require(d2.present(request(model2, log2)))
    clock2.advance(to: 3)
    try host2.hover(true, over: receipt2)
    #expect(d2.renderModel.state.dwell?.isPaused == true)
    try host2.press(.dismissLearnedCorrection(pillID: model2.id), over: receipt2)
    #expect(d2.renderModel.state.presentation == nil && log2.ended == 1 && log2.undos == 0)
    try host2.hover(false, over: receipt2)
    clock2.advance(to: 500)
    #expect(clock2.armedSeconds == [12], "the paused remainder was re-armed after ×")
    #expect(log2.ended == 1, "a dead pill's timer reported the offer ended again")

    // A stale press naming another pill reaches nobody.
    let clock3 = LearnedPillClock()
    let log3 = Log()
    let (d3, host3) = hoverDirector(clock3, log3)
    let model3 = LearnedPillFixture.model()
    let receipt3 = try #require(d3.present(request(model3, log3)))
    try host3.press(.dismissLearnedCorrection(pillID: UUID()), over: receipt3)
    #expect(shown(d3)?.id == model3.id && log3.ended == 0)
  }

  @Test(
    "× pressed once Undo has been accepted reaches nobody: Pending stays, the write still returns its result, and no end is reported"
  )
  func dismissAfterUndoIsDropped() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = hoverDirector(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    try host.press(.undoLearnedCorrection(pillID: model.id), over: receipt)
    try host.press(.dismissLearnedCorrection(pillID: model.id), over: receipt)
    #expect(shown(d)?.phase == .undoPending && log.ended == 0 && log.undos == 1)
    d.resolveLearnedCorrection(
      pillID: model.id, presentation: receipt.presentationID, phase: .undone)
    #expect(shown(d)?.phase == .undone, "× on Pending closed the pill before its result")
    try host.press(.dismissLearnedCorrection(pillID: model.id), over: receipt)
    #expect(shown(d)?.phase == .undone && log.ended == 0, "× on a result closed it")
  }

  @Test(
    "the result announces its copy once when the morph lands; a repeated or late result adds nothing and reopens nothing"
  )
  func resultAnnouncedOnceAndLateResultDropped() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, host) = director(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    #expect(log.announcements.count == 1)
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    #expect(log.announcements.count == 1, "the Pending morph announced something")

    d.resolveLearnedCorrection(
      pillID: model.id, presentation: receipt.presentationID, phase: .undone)
    #expect(log.announcements.map(\.text).suffix(1) == ["\u{201C}Tuist\u{201D} removed"])
    #expect(log.announcements.count == 2 && log.announcements.last?.isHighPriority == false)
    d.resolveLearnedCorrection(
      pillID: model.id, presentation: receipt.presentationID, phase: .undoError)
    #expect(log.announcements.count == 2 && shown(d)?.phase == .undone, "a result never goes back")

    // Pending expired first: the late result finds the slot gone.
    let clock2 = LearnedPillClock()
    let log2 = Log()
    let (d2, host2) = director(clock2, log2)
    let model2 = LearnedPillFixture.model()
    let receipt2 = try #require(d2.present(request(model2, log2)))
    try host2.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model2.id), for: receipt2)
    clock2.advance(to: 12)
    #expect(d2.renderModel.state.presentation == nil)
    let shownBefore = host2.presented.count
    d2.resolveLearnedCorrection(
      pillID: model2.id, presentation: receipt2.presentationID, phase: .undone)
    #expect(d2.renderModel.state.presentation == nil && host2.presented.count == shownBefore)
    #expect(log2.announcements.count == 1, "a late result was announced")

    // A newer learned pill took the slot: the late result leaves it alone.
    let clock3 = LearnedPillClock()
    let log3 = Log()
    let (d3, host3) = director(clock3, log3)
    let first = LearnedPillFixture.model(canonical: "Tuist")
    let r1 = try #require(d3.present(request(first, log3)))
    try host3.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: first.id), for: r1)
    let second = LearnedPillFixture.model(canonical: "Saira")
    _ = try #require(d3.present(request(second, log3)))
    #expect(log3.ended == 0, "replacing Pending reports no end")
    d3.resolveLearnedCorrection(
      pillID: first.id, presentation: r1.presentationID, phase: .undone)
    #expect(shown(d3)?.id == second.id && shown(d3)?.phase == .learned)
  }

  @Test(
    "an end callback that presents a newer pill wins: the stale plan is discarded, not applied over it"
  )
  func endCallbackMayReenter() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, _) = director(clock, log)
    let model = LearnedPillFixture.model()
    let reentrant = PillRequest.correctionLearned(
      model: model, isStillWanted: { true }, onUndo: {},
      onEnded: {
        log.ended += 1
        // The owner reacts to the end by raising its own notice.
        d.present(.warning(reason: .polishFailed))
      })
    _ = try #require(d.present(reentrant))

    // Preemption by a pipeline notice: the re-entrant warning must be what stays.
    d.present(.processing(phase: .transcribing))
    #expect(log.ended == 1)
    guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
      Issue.record("the re-entrant pill is not on screen")
      return
    }
    #expect(notice.kind == .notification, "the warning, not the processing pill, holds the slot")
    #expect(d.renderModel.state.presentation?.id == d.renderModel.state.dwell?.id)

    // Preemption by a recording COMMIT: same rule through the two-stage path.
    d.dismissCurrent(.silent)
    _ = try #require(d.present(reentrant))
    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0.2, audioLevelProvider: { 0.2 }, recordingElapsedProvider: { nil },
          isLocked: false)))
    #expect(log.ended == 2)
    guard case .notice? = d.renderModel.state.presentation?.content else {
      Issue.record("the recording overwrote the re-entrant warning")
      return
    }
  }

  @Test(
    "an owner check that presents a newer pill from inside itself loses to that pill: no rollback, no render of the stale offer, whether it answers true or false"
  )
  func ownerCheckMayReenter() {
    for answer in [true, false] {
      let clock = LearnedPillClock()
      let log = Log()
      let (d, host) = director(clock, log)
      let model = LearnedPillFixture.model()
      // The check raises a warning as a side effect; that warning must win.
      let request = request(
        model, log,
        stillWanted: {
          d.present(.warning(reason: .polishFailed))
          return answer
        })
      _ = d.present(request) { log.results.append($0) }
      #expect(
        log.results == [.notPresented],
        "the stale offer owes its caller only false (answer \(answer))")
      guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
        Issue.record("the re-entrant warning is not on screen (answer \(answer))")
        return
      }
      #expect(notice.kind == .notification)
      #expect(
        d.renderModel.state.presentation?.id == d.renderModel.state.dwell?.id,
        "the warning keeps its own timer")
      #expect(host.presented.count == 1 && host.isShowing, "exactly one render: the warning")
      // The reducer had admitted the offer before the render, so the warning
      // preempts it there and the end is reported once; the owner was answered
      // `.notPresented` and never `.presented`. What must not happen is a
      // SECOND end from a rollback of the newer warning.
      #expect(log.ended == 1, "one reducer-level end, no rollback end (answer \(answer))")
    }
  }

  @Test(
    "a deferred first render is rolled back unrendered when the owner no longer wants it, and the relay hears notPresented"
  )
  func deferredRenderReChecksTheOwner() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let host = WindowlessOverlayHost()
    var deferred: (() -> Void)?
    let d = OverlayDirector(
      host: host, scheduler: clock.scheduler, announce: { log.announcements.append($0) },
      livePreview: .disabled, grantAccessibility: {}, openMicrophoneSettings: {}, openMicrophoneHelp: {},
      advisoryHint: { _ in nil }, selections: { .shipped },
      firstRenderSchedule: { deferred = $0 })
    var wanted = true
    let model = LearnedPillFixture.model()
    _ = d.present(request(model, log, stillWanted: { wanted })) { log.results.append($0) }
    #expect(log.results.isEmpty, "nothing is answered before the deferred render")
    wanted = false
    let render = try #require(deferred)
    render()
    #expect(log.results == [.notPresented])
    #expect(d.renderModel.state.presentation == nil && log.announcements.isEmpty)
  }
}

// MARK: - Presenter

@MainActor
@Suite("Undo pill: presenter adapter (#996 auto-learn)", .tags(.productOutcome))
struct LearnedCorrectionOverlayPresenterTests {

  /// Every object the adapter wires, kept alive together: the coordinator
  /// holds the presenter weakly and the library's closures are unowned.
  struct Fixture {
    let host: LearnedOverlayHostFake
    let library: LearnedLibraryFake
    let telemetry: LearnedTelemetrySpy
    let coordinator: LearnedCorrectionCoordinator
    let presenter: LearnedCorrectionOverlayPresenter
  }

  private func fixture(host: LearnedOverlayHostFake = LearnedOverlayHostFake()) -> Fixture {
    let library = LearnedLibraryFake()
    let telemetry = LearnedTelemetrySpy()
    let coordinator = LearnedCorrectionCoordinator(
      vocabulary: library.access, memory: .forTests(), telemetry: telemetry)
    let presenter = LearnedCorrectionOverlayPresenter(host: host, coordinator: coordinator)
    coordinator.attach(presenter: presenter)
    return Fixture(
      host: host, library: library, telemetry: telemetry, coordinator: coordinator,
      presenter: presenter)
  }

  @Test(
    "a presented pill counts learn_undo_shown once; a declined one ends the Undo record without counting"
  )
  func presentedAndDeclined() async throws {
    let f = fixture()
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    #expect(f.host.requests.count == 1)
    #expect(f.telemetry.events == [.added(.newWord, .judge), .undoShown])
    #expect(f.coordinator.undoRecord != nil)

    let refusing = LearnedOverlayHostFake()
    refusing.admitAs = nil
    let g = fixture(host: refusing)
    await g.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    #expect(g.telemetry.events == [.added(.newWord, .judge)], "saved, no Undo offered")
    #expect(g.coordinator.undoRecord == nil)
  }

  @Test(
    "the director's Undo press reaches the coordinator and the same-identity Undone morph comes back; the end callback drops the record"
  )
  func undoForwardingAndResult() async throws {
    let f = fixture()
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill = try #require(f.host.requests.first)
    let undo = try #require(f.host.undos.first)
    undo()
    await f.presenter.awaitUndoForTesting()
    #expect(f.library.userWords.isEmpty, "the word was removed")
    #expect(
      f.telemetry.events.suffix(2) == [
        .undone(.added, .undone, .judge, .watching), .refusedByUser(.undo, .watching),
      ])
    let resolved = try #require(f.host.resolved.first)
    #expect(resolved.0 == pill.id && resolved.1 == f.host.admitAs && resolved.2 == .undone)
    #expect(f.host.closes.isEmpty)

    let g = fixture()
    await g.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let ended = try #require(g.host.endeds.first)
    ended()
    #expect(g.coordinator.undoRecord == nil)
    let stalePill = try #require(g.host.requests.first)
    await #expect(g.coordinator.undoThroughClaim(pillID: stalePill.id) == .stale)
    #expect(g.host.closes.count == 1, "a stale Undo closes by id")
  }

  @Test(
    "an Undo that fails morphs to the error line on the same identity; an already-changed word closes the pill"
  )
  func undoErrorAndClose() async throws {
    let f = fixture()
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill = try #require(f.host.requests.first)
    f.library.removeRefusal = "locked"
    let undo = try #require(f.host.undos.first)
    undo()
    await f.presenter.awaitUndoForTesting()
    #expect(f.host.resolved.map(\.2) == [.undoError] && f.host.resolved.first?.0 == pill.id)

    let g = fixture()
    await g.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill2 = try #require(g.host.requests.first)
    g.library.userWords[0].category = .brand
    let undo2 = try #require(g.host.undos.first)
    undo2()
    await g.presenter.awaitUndoForTesting()
    #expect(g.host.closes == [pill2.id] && g.host.resolved.isEmpty)
  }

  @Test(
    "the Undo press claims the record before it returns and before the write starts, so a newer learn cannot take it; the claimed write removes its own word"
  )
  func undoClaimsAtTheClick() async throws {
    let f = fixture()
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let first = try #require(f.host.requests.first)
    let undo = try #require(f.host.undos.first)

    undo()
    #expect(f.coordinator.undoRecord == nil, "the record was still unclaimed when the press returned")
    #expect(f.library.removes.isEmpty, "the write ran inside the press instead of after the claim")

    await f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord)
    let second = try #require(f.host.requests.last)
    #expect(second.id != first.id && f.coordinator.undoRecord?.pillID == second.id)
    await f.presenter.awaitUndoForTesting()
    #expect(f.library.userWords.map(\.canonical) == ["Saira"], "the claimed word went, the newer stayed")
    #expect(f.host.resolved.map(\.0) == [first.id], "the result names the pill that was clicked")
    #expect(f.coordinator.undoRecord?.pillID == second.id)
  }

  @Test(
    "a press with nothing to claim closes only its own pill, synchronously, and starts no write"
  )
  func nilClaimClosesOnlyThatPill() async throws {
    let f = fixture()
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill = try #require(f.host.requests.first)
    let undo = try #require(f.host.undos.first)
    let ended = try #require(f.host.endeds.first)
    ended()  // the offer ended: the record is gone
    #expect(f.coordinator.undoRecord == nil)

    undo()
    #expect(f.host.closes == [pill.id], "the pill was not closed by the time the press returned")
    await f.presenter.awaitUndoForTesting()
    #expect(f.library.removes.isEmpty && f.library.userWords.count == 1)
    #expect(f.host.resolved.isEmpty)
    #expect(
      !f.telemetry.events.contains { if case .undone = $0 { true } else { false } },
      "a nil claim counted an Undo")
  }

  @Test("a save refusal presents the save-error notice with the canonical")
  func saveError() async {
    let f = fixture()
    f.library.saveRefusal = "disk full"
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    #expect(
      f.host.saveErrors == [
        LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed)
      ])
    #expect(f.host.requests.isEmpty)
  }

  @Test(
    "a deferred first render is rolled back when a newer learn replaced the record, and only the newer pill is admitted"
  )
  func deferredRenderFollowsTheRecord() async throws {
    let host = LearnedOverlayHostFake()
    host.deferResult = true
    let f = fixture(host: host)
    await f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    await f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord)
    #expect(host.requests.count == 2 && host.pendingResults.count == 2)
    host.answerPending()
    // The fake answers both relays from the LAST predicate, as the director
    // does per relay; the first pill's admission is a no-op on the coordinator
    // (its record is gone), so Undo is counted once, for the second pill.
    #expect(f.telemetry.events.filter { $0 == .undoShown }.count == 1)
    #expect(f.coordinator.undoRecord?.pillID == host.requests.last?.id)
  }
}
