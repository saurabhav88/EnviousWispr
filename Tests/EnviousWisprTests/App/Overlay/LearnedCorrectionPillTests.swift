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
    "the two sentences name the correct word only, in curly quotes; the results and the button are fixed words"
  )
  func exactStrings() {
    let added = LearnedPillFixture.model(canonical: "Tuist", kind: .added)
    let updated = LearnedPillFixture.model(canonical: "Saira", kind: .updated)
    #expect(
      CorrectionLearnedPillCopy.sentence(for: added) == "Added \u{201C}Tuist\u{201D} to Dictionary")
    #expect(CorrectionLearnedPillCopy.sentence(for: updated) == "\u{201C}Saira\u{201D} updated")
    #expect(CorrectionLearnedPillCopy.undo == "Undo")
    #expect(CorrectionLearnedPillCopy.undone == "Undone")
    #expect(CorrectionLearnedPillCopy.couldNotUndo == "Couldn\u{2019}t undo")
    #expect(
      CorrectionLearnedPillCopy.saveError(
        LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed))
        == "Couldn\u{2019}t save \u{201C}Tuist\u{201D}")
    #expect(CorrectionLearnedPillCopy.learnedDwellSeconds == 3)
    #expect(CorrectionLearnedPillCopy.undoneDwellSeconds == 1.5)
    #expect(CorrectionLearnedPillCopy.errorDwellSeconds == 3)
    #expect(CorrectionLearnedPillCopy.minimumScale == 0.5)
  }

  @Test("a very long word cannot push the Undo button off the screen: the pill's fitting width is capped")
  @MainActor func longWordStaysOnScreen() {
    let long = String(repeating: "Supercalifragilistic", count: 25)  // 500 scalars, the stored limit's neighbourhood
    let model = LearnedPillFixture.model(canonical: long, kind: .added)
    let host = NSHostingView(rootView: CorrectionLearnedPillView(model: model, onUndo: {}))
    host.layoutSubtreeIfNeeded()
    let width = host.fittingSize.width
    // The sentence is capped, and the button plus paddings ride beside it.
    #expect(width <= CorrectionLearnedPillCopy.maximumSentenceWidth + 140, "fitting width \(width)")
    // Control: a short word is narrower than the cap.
    let short = NSHostingView(
      rootView: CorrectionLearnedPillView(model: LearnedPillFixture.model(canonical: "Tuist", kind: .added), onUndo: {}))
    short.layoutSubtreeIfNeeded()
    #expect(short.fittingSize.width < CorrectionLearnedPillCopy.maximumSentenceWidth)
  }

  @Test(
    "only the learned phase offers Undo; the results draw their fixed line, and only the error is red"
  )
  func phaseButtonPolicy() {
    let learned = CorrectionLearnedPillCopy.line(for: LearnedPillFixture.model(phase: .learned))
    #expect(learned.showsUndo && !learned.isError && learned.text.hasPrefix("Added"))
    let undone = CorrectionLearnedPillCopy.line(for: LearnedPillFixture.model(phase: .undone))
    #expect(!undone.showsUndo && !undone.isError && undone.text == "Undone")
    let failed = CorrectionLearnedPillCopy.line(for: LearnedPillFixture.model(phase: .undoError))
    #expect(!failed.showsUndo && failed.isError && failed.text == "Couldn\u{2019}t undo")
  }

  @Test(
    "the announcement is the sentence plus Undo available while Undo is offered, and the bare line otherwise"
  )
  func announcement() {
    let learned = LearnedPillFixture.model(canonical: "Tuist", kind: .updated)
    #expect(
      CorrectionLearnedPillCopy.announcement(for: learned)
        == "\u{201C}Tuist\u{201D} updated. Undo available.")
    #expect(
      CorrectionLearnedPillCopy.announcement(for: LearnedPillFixture.model(phase: .undone))
        == "Undone")
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

  @Test(
    "a learned pill is admitted on an idle, empty slot with a 3 s dwell that hover does not pause, measured width, and a spoken sentence"
  )
  func admittedWhenIdleAndEmpty() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    let plan = r.reduce(.correctionLearned(model))
    #expect(plan.didChange)
    let shown = try #require(plan.presentation)
    #expect(shown.id == id && shown.content == .correctionLearned(model))
    #expect(shown.expiry == .after(seconds: 3, pausesOnHover: false))
    #expect(shown.requestedWidth == .measured && shown.reservesFixedHeight == nil)
    #expect(plan.expiryCommand == .arm(id: id, seconds: 3, target: .presentation))
    #expect(plan.announcement?.isHighPriority == false)
    #expect(plan.announcement?.text == "Added \u{201C}Tuist\u{201D} to Dictionary. Undo available.")
    #expect(r.state.featureSlotIsAvailable == false, "no other feature displaces it")
    // Hover is a no-op: the dwell is not pausable.
    #expect(r.reduce(.hoverChanged(id, true)) == .noChange)
    #expect(r.reduce(.hoverChanged(id, false)) == .noChange)
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
    #expect(empty.state.current == nil)
  }

  @Test(
    "a different learned pill replaces the current one: new identity, fresh 3 s, one end effect for the outgoing offer; a same-pill repeat changes nothing"
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
    #expect(plan.expiryCommand == .arm(id: shown.id, seconds: 3, target: .presentation))
    #expect(plan.effects == [.correctionLearnedEnded(pillID: first.id, presentation: firstID)])
    #expect(plan.announcement?.text == "\u{201C}Saira\u{201D} updated. Undo available.")
  }

  @Test("a learned pill replaces a result still on screen, and the result owes no end effect")
  func replacesAResult() throws {
    var ids = [PresentationID(), PresentationID()]
    var r = OverlayReducer(makeID: { ids.removeFirst() })
    let first = LearnedPillFixture.model()
    let firstID = try #require(r.reduce(.correctionLearned(first)).presentation?.id)
    _ = r.reduce(.correctionLearnedResult(pillID: first.id, presentation: firstID, phase: .undone))
    let plan = r.reduce(.correctionLearned(LearnedPillFixture.model(canonical: "Saira")))
    #expect(plan.didChange && plan.effects.isEmpty)
    #expect(Self.pill(r)?.canonical == "Saira")
  }

  @Test(
    "Undo is delivered once for the shown pill in its learned phase; another id or a result phase reaches nobody"
  )
  func undoGate() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    let press = r.reduce(.action(id, .undoLearnedCorrection(pillID: model.id)))
    #expect(press.deliverAction == .undoLearnedCorrection(pillID: model.id))
    #expect(r.reduce(.action(id, .undoLearnedCorrection(pillID: UUID()))) == .noChange)
    #expect(
      r.reduce(.action(PresentationID(), .undoLearnedCorrection(pillID: model.id))) == .noChange)
    _ = r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    #expect(r.reduce(.action(id, .undoLearnedCorrection(pillID: model.id))) == .noChange)
  }

  @Test(
    "Undone morphs the current offer in place: same identity, phase undone, fresh 1.5 s; Undo error morphs to 3 s; a result never morphs again; a stale pair is a no-op"
  )
  func resultMorphs() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = LearnedPillFixture.model()
    _ = r.reduce(.correctionLearned(model))
    #expect(
      r.reduce(
        .correctionLearnedResult(pillID: model.id, presentation: PresentationID(), phase: .undone))
        == .noChange)
    #expect(
      r.reduce(.correctionLearnedResult(pillID: UUID(), presentation: id, phase: .undone))
        == .noChange)
    #expect(
      r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .learned))
        == .noChange)

    let plan = r.reduce(
      .correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    let shown = try #require(plan.presentation)
    #expect(shown.id == id && Self.pill(r)?.phase == .undone && Self.pill(r)?.id == model.id)
    #expect(shown.expiry == .after(seconds: 1.5, pausesOnHover: false))
    #expect(plan.expiryCommand == .arm(id: id, seconds: 1.5, target: .presentation))
    #expect(
      r.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undoError))
        == .noChange)

    var e = OverlayReducer(makeID: { id })
    _ = e.reduce(.correctionLearned(model))
    let errorPlan = e.reduce(
      .correctionLearnedResult(pillID: model.id, presentation: id, phase: .undoError))
    #expect(Self.pill(e)?.phase == .undoError)
    #expect(errorPlan.expiryCommand == .arm(id: id, seconds: 3, target: .presentation))
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
    _ = s.reduce(.correctionLearnedResult(pillID: model.id, presentation: id, phase: .undone))
    let resultExpired = s.reduce(.expiryFired(id))
    #expect(resultExpired.presentation == nil && resultExpired.effects.isEmpty)

    var c = OverlayReducer(makeID: { id })
    _ = c.reduce(.correctionLearned(model))
    #expect(c.reduce(.correctionLearnedClose(pillID: UUID())) == .noChange)
    let closed = c.reduce(.correctionLearnedClose(pillID: model.id))
    #expect(closed.presentation == nil && closed.expiryCommand == .cancel && closed.effects.isEmpty)
    #expect(c.state.current == nil)
    #expect(c.reduce(.correctionLearnedClose(pillID: model.id)) == .noChange)
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
      shown.expiry == .after(seconds: 3, pausesOnHover: false) && shown.requestedWidth == .measured)
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
    let d = OverlayDirector(
      host: host,
      scheduler: clock.scheduler,
      announce: { log.announcements.append($0) },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    return (d, host)
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

  @Test("the pill is on screen at 2.999 s after admission and gone at 3.000 s, reported ended once")
  func undoWindow() throws {
    let clock = LearnedPillClock()
    let log = Log()
    let (d, _) = director(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)) { log.results.append($0) })
    #expect(log.results == [.presented(receipt)])
    #expect(clock.armedSeconds == [3], "the dwell armed at admission, for exactly three seconds")
    clock.advance(to: 2.999)
    #expect(shown(d)?.id == model.id && log.ended == 0)
    clock.advance(to: 3.0)
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
    #expect(log.undos == 1)

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
    let (d, _) = director(clock, log)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, log)))
    clock.advance(to: 0.5)
    d.resolveLearnedCorrection(
      pillID: model.id, presentation: receipt.presentationID, phase: .undone)
    #expect(clock.armedSeconds == [3, 1.5])
    clock.advance(to: 1.999)
    #expect(shown(d)?.phase == .undone, "the old 3 s deadline was cancelled")
    clock.advance(to: 2.0)
    #expect(d.renderModel.state.presentation == nil, "1.5 s after the morph at 0.5 s")
    #expect(log.ended == 0, "a result is not an unanswered offer")

    let clock2 = LearnedPillClock()
    let log2 = Log()
    let (d2, _) = director(clock2, log2)
    let model2 = LearnedPillFixture.model()
    let receipt2 = try #require(d2.present(request(model2, log2)))
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
    clock.advance(to: 3.999)
    #expect(shown(d)?.id == m2.id, "the second pill's own three seconds run from 1.0 s")
    clock.advance(to: 4.0)
    #expect(d.renderModel.state.presentation == nil && first.ended == 1 && second.ended == 1)
  }

  @Test("a same-pill repeat keeps the original binding: the press and the end still reach the first owner")
  func repeatKeepsTheOriginalBinding() throws {
    let clock = LearnedPillClock()
    let first = Log()
    let second = Log()
    let (d, host) = director(clock, first)
    let model = LearnedPillFixture.model()
    let receipt = try #require(d.present(request(model, first)))
    #expect(d.present(request(model, second)) == nil, "a repeat keeps the incumbent's receipt; it is not a new admission")
    #expect(shown(d)?.id == model.id && d.isCurrent(receipt))
    #expect(clock.armedSeconds == [3], "the repeat did not re-arm the dwell")
    try host.sendUserActionThroughRoot(.undoLearnedCorrection(pillID: model.id), for: receipt)
    #expect(first.undos == 1 && second.undos == 0)
    clock.advance(to: 3)
    #expect(first.ended == 1 && second.ended == 0)
  }

  @Test("an end callback that presents a newer pill wins: the stale plan is discarded, not applied over it")
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

  @Test("an owner check that presents a newer pill from inside itself loses to that pill: no rollback, no render of the stale offer, whether it answers true or false")
  func ownerCheckMayReenter() {
    for answer in [true, false] {
      let clock = LearnedPillClock()
      let log = Log()
      let (d, host) = director(clock, log)
      let model = LearnedPillFixture.model()
      // The check raises a warning as a side effect; that warning must win.
      let request = request(model, log, stillWanted: {
        d.present(.warning(reason: .polishFailed))
        return answer
      })
      _ = d.present(request) { log.results.append($0) }
      #expect(log.results == [.notPresented], "the stale offer owes its caller only false (answer \(answer))")
      guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
        Issue.record("the re-entrant warning is not on screen (answer \(answer))")
        return
      }
      #expect(notice.kind == .notification)
      #expect(d.renderModel.state.presentation?.id == d.renderModel.state.dwell?.id, "the warning keeps its own timer")
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
      livePreview: .disabled, grantAccessibility: {}, openMicrophoneSettings: {},
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
    let coordinator = LearnedCorrectionCoordinator(vocabulary: library.access, telemetry: telemetry)
    let presenter = LearnedCorrectionOverlayPresenter(host: host, coordinator: coordinator)
    coordinator.attach(presenter: presenter)
    return Fixture(
      host: host, library: library, telemetry: telemetry, coordinator: coordinator,
      presenter: presenter)
  }

  @Test("a presented pill counts learn_undo_shown once; a declined one ends the Undo record without counting")
  func presentedAndDeclined() throws {
    let f = fixture()
    f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    #expect(f.host.requests.count == 1)
    #expect(f.telemetry.events == [.added(.newWord), .undoShown])
    #expect(f.coordinator.undoRecord != nil)

    let refusing = LearnedOverlayHostFake()
    refusing.admitAs = nil
    let g = fixture(host: refusing)
    g.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    #expect(g.telemetry.events == [.added(.newWord)], "saved, no Undo offered")
    #expect(g.coordinator.undoRecord == nil)
  }

  @Test("the director's Undo press reaches the coordinator and the same-identity Undone morph comes back; the end callback drops the record")
  func undoForwardingAndResult() throws {
    let f = fixture()
    f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill = try #require(f.host.requests.first)
    let undo = try #require(f.host.undos.first)
    undo()
    #expect(f.library.userWords.isEmpty, "the word was removed")
    #expect(f.telemetry.events.last == .undone(.added, .undone))
    let resolved = try #require(f.host.resolved.first)
    #expect(resolved.0 == pill.id && resolved.1 == f.host.admitAs && resolved.2 == .undone)
    #expect(f.host.closes.isEmpty)

    let g = fixture()
    g.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let ended = try #require(g.host.endeds.first)
    ended()
    #expect(g.coordinator.undoRecord == nil)
    let stalePill = try #require(g.host.requests.first)
    #expect(g.coordinator.undo(pillID: stalePill.id) == .stale)
    #expect(g.host.closes.count == 1, "a stale Undo closes by id")
  }

  @Test("an Undo that fails morphs to the error line on the same identity; an already-changed word closes the pill")
  func undoErrorAndClose() throws {
    let f = fixture()
    f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill = try #require(f.host.requests.first)
    f.library.removeRefusal = "locked"
    let undo = try #require(f.host.undos.first)
    undo()
    #expect(f.host.resolved.map(\.2) == [.undoError] && f.host.resolved.first?.0 == pill.id)

    let g = fixture()
    g.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let pill2 = try #require(g.host.requests.first)
    g.library.userWords[0].category = .brand
    let undo2 = try #require(g.host.undos.first)
    undo2()
    #expect(g.host.closes == [pill2.id] && g.host.resolved.isEmpty)
  }

  @Test("a save refusal presents the save-error notice with the canonical")
  func saveError() {
    let f = fixture()
    f.library.saveRefusal = "disk full"
    f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    #expect(
      f.host.saveErrors == [
        LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed)
      ])
    #expect(f.host.requests.isEmpty)
  }

  @Test("a deferred first render is rolled back when a newer learn replaced the record, and only the newer pill is admitted")
  func deferredRenderFollowsTheRecord() throws {
    let host = LearnedOverlayHostFake()
    host.deferResult = true
    let f = fixture(host: host)
    f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord)
    #expect(host.requests.count == 2 && host.pendingResults.count == 2)
    host.answerPending()
    // The fake answers both relays from the LAST predicate, as the director
    // does per relay; the first pill's admission is a no-op on the coordinator
    // (its record is gone), so Undo is counted once, for the second pill.
    #expect(f.telemetry.events.filter { $0 == .undoShown }.count == 1)
    #expect(f.coordinator.undoRecord?.pillID == host.requests.last?.id)
  }
}
