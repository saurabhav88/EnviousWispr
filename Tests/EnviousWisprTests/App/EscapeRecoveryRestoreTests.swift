import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// Getting the text back: the pill's Paste, and History's (#2087, chunk 12).
///
/// Both doors were unguarded. A mutation battery deleted the field refocus and
/// deleted History's restore event, and every existing test stayed green — so
/// the pill could quietly paste into the wrong field, and every restore that did
/// not go through the three-second offer could vanish from the numbers the
/// feature is judged on.
@MainActor
@Suite("Escape Recovery restore paths (#2087)", .tags(.productOutcome))
struct EscapeRecoveryRestoreTests {

  @MainActor
  private final class Spy {
    var retargeted: [UUID] = []
    var reports: [(ageMs: Int, result: EscapeRecoveryPasteResult, takeID: String)] = []
  }

  private func run(
    payload: CancelUndoPayload,
    row: (text: String, stampedAt: Date, takeID: String?)?,
    spy: Spy
  ) {
    EscapeRecoveryPasteAction.paste(
      payload: payload,
      restorable: { _ in row },
      report: { spy.reports.append((ageMs: $0, result: $1, takeID: $2)) },
      retarget: {
        spy.retargeted.append($0.transcriptID)
        return true
      })
  }

  /// The pill's whole reason to exist over History.
  ///
  /// History pastes into whatever app you are in now. The pill pastes back into
  /// the one you were dictating into, which is why the payload retains a handle
  /// to it at all — and dropping the retarget makes the two identical while
  /// every other assertion about the pill still holds.
  @Test("a live row retargets the app and field it was dictated into")
  func pasteRetargets() {
    let spy = Spy()
    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil)

    run(payload: payload, row: ("kept", Date(), "take-1"), spy: spy)

    #expect(
      spy.retargeted == [payload.transcriptID],
      "without this the pill is just History's Paste wearing a different label")
    #expect(spy.reports.count == 1, "control: the restore is reported")
    #expect(spy.reports.first?.result == .pasted)
  }

  /// Inert, not merely harmless.
  ///
  /// A recovery can lapse between the pill being drawn and the button being
  /// pressed. Retargeting anyway would yank the user into another app to paste
  /// nothing — worse than doing nothing, because it looks like it worked.
  @Test("a lapsed row retargets nothing and reports nothing")
  func lapsedRowIsFullyInert() {
    let spy = Spy()

    run(
      payload: CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil),
      row: nil, spy: spy)

    #expect(spy.retargeted.isEmpty, "no app switch for text that is already gone")
    #expect(spy.reports.isEmpty, "and nothing to report, because nothing was restored")
  }

  /// No join key, no event.
  ///
  /// The paste still happens — the user asked for their text and gets it. Only
  /// the telemetry is dropped, because an event that cannot join the funnel
  /// inflates a denominator and answers no question.
  @Test("a row with no take id still pastes, and still reports nothing")
  func missingTakeIDPastesButDoesNotReport() {
    let spy = Spy()
    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil)

    run(payload: payload, row: ("kept", Date(), nil), spy: spy)

    #expect(spy.retargeted == [payload.transcriptID], "the user still gets their text")
    #expect(spy.reports.isEmpty)
  }

  /// The target quit while the offer stood.
  ///
  /// Activation fails silently against a dead process — and the pid can even
  /// belong to a REPLACEMENT process by then — after which an unconditional
  /// Cmd-V lands in whatever is frontmost now. That is the user's words arriving
  /// in an unrelated application, which is worse than not restoring them: they
  /// did not ask for it and may not notice where it went.
  @Test("a target that has quit is never pasted past")
  func terminatedTargetIsNotPastedInto() {
    let spy = Spy()
    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil)

    EscapeRecoveryPasteAction.paste(
      payload: payload,
      restorable: { _ in ("kept", Date(), "take-1") },
      report: { spy.reports.append((ageMs: $0, result: $1, takeID: $2)) },
      retarget: {
        spy.retargeted.append($0.transcriptID)
        return true
      },
      targetHasQuit: { _ in true })

    #expect(
      spy.retargeted.isEmpty,
      "no activation, so no keystroke goes to whatever replaced it")
    #expect(
      spy.reports.first?.result == .clipboardOnly,
      """
      still a restore, and the vocabulary already had the word for it: the text \
      is on the clipboard and the row stands in History for 24 hours. Reporting \
      `.pasted` would claim an insertion that did not happen.
      """)
  }

  /// The control that keeps the test above honest: with a live target the paste
  /// proceeds exactly as before, so the guard cannot be satisfied by refusing
  /// everything.
  @Test("a live target still pastes")
  func liveTargetStillPastes() {
    let spy = Spy()
    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil)

    EscapeRecoveryPasteAction.paste(
      payload: payload,
      restorable: { _ in ("kept", Date(), "take-1") },
      report: { spy.reports.append((ageMs: $0, result: $1, takeID: $2)) },
      retarget: {
        spy.retargeted.append($0.transcriptID)
        return true
      },
      targetHasQuit: { _ in false })

    #expect(spy.retargeted == [payload.transcriptID])
    #expect(spy.reports.first?.result == .pasted)
  }

  /// The app survived; the FIELD did not.
  ///
  /// One level finer than the terminated case above, and the same harm. The
  /// view closed, the document was shut, the element refuses focus — and a
  /// keystroke sent anyway lands in whatever that app has focused now. The user
  /// dictated into one box and the words arrive in another.
  ///
  /// Refusing costs nothing: the text is already on the clipboard and the row
  /// stands in History for 24 hours.
  @Test("a retarget that failed is never followed by a keystroke")
  func failedRetargetDoesNotPaste() {
    let spy = Spy()
    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil)

    EscapeRecoveryPasteAction.paste(
      payload: payload,
      restorable: { _ in ("kept", Date(), "take-1") },
      report: { spy.reports.append((ageMs: $0, result: $1, takeID: $2)) },
      retarget: {
        spy.retargeted.append($0.transcriptID)
        return false
      },
      targetHasQuit: { _ in false })

    #expect(
      spy.retargeted == [payload.transcriptID],
      "control: it was attempted — this is about the ANSWER being read, not skipped")
    #expect(
      spy.reports.first?.result == .clipboardOnly,
      "the words stay on the clipboard rather than landing in the wrong field")
  }

  // MARK: History's door

  private func coordinator(_ emitted: EmitBox) -> TranscriptCoordinator {
    TranscriptCoordinator(
      store: TranscriptStore(),
      emitEscapeRecoveryRestoredFromHistory: { ageMs, takeID in
        emitted.calls.append((ageMs: ageMs, takeID: takeID))
      })
  }

  @MainActor
  private final class EmitBox {
    var calls: [(ageMs: Int, takeID: String)] = []
  }

  @Test("pasting a held row from History reports the restore")
  func historyRestoreIsReported() {
    let emitted = EmitBox()
    let coordinator = coordinator(emitted)
    let held = Transcript(
      text: "kept", backendType: .parakeet,
      escapeRecoveredAt: Date(timeIntervalSinceNow: -60), escapeRecoveryTakeID: "take-7")
    coordinator.reportRestoredFromHistory(held)

    #expect(emitted.calls.map(\.takeID) == ["take-7"])
    #expect(
      (emitted.calls.first?.ageMs ?? 0) >= 60_000,
      "the age is measured from the keypress, which is what makes the offer's shelf life legible")
  }

  @Test("pasting an ordinary dictation from History reports nothing")
  func ordinaryRowReportsNothing() {
    let emitted = EmitBox()
    let coordinator = coordinator(emitted)
    let ordinary = Transcript(text: "hello", backendType: .parakeet)
    coordinator.reportRestoredFromHistory(ordinary)

    #expect(
      emitted.calls.isEmpty,
      "control: every History paste calls this, and only recoveries are restores")
  }

  /// The same refusal `textForDelivery` makes, for the same reason.
  ///
  /// A row past its window is refused the text, so reporting a restore for it
  /// would count a paste that never happened — and it would count it in the one
  /// ratio used to decide whether this feature earns its keep.
  @Test("a lapsed row reports nothing")
  func lapsedRowReportsNothing() {
    let emitted = EmitBox()
    let coordinator = coordinator(emitted)
    let lapsed = Transcript(
      text: "gone", backendType: .parakeet,
      escapeRecoveredAt: Date(timeIntervalSinceNow: -(25 * 60 * 60)),
      escapeRecoveryTakeID: "take-old")
    coordinator.reportRestoredFromHistory(lapsed)

    #expect(emitted.calls.isEmpty, "the text was refused, so there was no restore to report")
  }
}
