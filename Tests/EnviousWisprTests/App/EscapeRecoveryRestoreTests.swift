import AppKit
import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// Getting the text back: the pill's Paste, and History's (#2087, chunk 12).
///
/// Both doors were unguarded. A mutation battery deleted History's restore event and every
/// existing test stayed green, so every restore that did not go through the three-second offer
/// could vanish from the numbers the feature is judged on. #3437: the pill's Undo now hands its
/// text to the dictation delivery (`HeldTextDelivery`); where the text lands is that delivery's
/// contract (`HeldTextDeliveryTests`), and this suite pins what Undo does with the result.
@MainActor
@Suite("Escape Recovery restore paths (#2087)", .tags(.productOutcome))
struct EscapeRecoveryRestoreTests {

  @MainActor
  private final class Spy {
    var delivered: [(text: String, payload: ObjectIdentifier, takeID: String?)] = []
    var notices: [(result: HeldTextDeliveryResult, takeID: String?, transcriptID: UUID)] = []
    var reports: [(ageMs: Int, result: EscapeRecoveryPasteResult, takeID: String)] = []
    var logs: [(outcome: String, takeID: String?)] = []
  }

  private func payload() -> CancelUndoPayload {
    CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil, targetWindow: nil,
      takeFacts: .testNone)
  }

  private func run(
    payload: CancelUndoPayload,
    row: (text: String, stampedAt: Date, takeID: String?)?,
    returning result: HeldTextDeliveryResult = HeldTextDeliveryResult(
      outcome: .pasted, fallbackClipboardChangeCount: nil),
    spy: Spy
  ) async {
    await EscapeRecoveryPasteAction.paste(
      payload: payload,
      restorable: { _ in row },
      deliver: { text, payload, takeID in
        spy.delivered.append((text, ObjectIdentifier(payload), takeID))
        return result
      },
      presentNotice: { spy.notices.append(($0, $1, $2)) },
      report: { spy.reports.append((ageMs: $0, result: $1, takeID: $2)) },
      recordLog: { outcome, _, takeID in spy.logs.append((outcome, takeID)) })
  }

  // MARK: The pill's door (#3437: the dictation delivery, not a paste of its own)

  @Test("a live row hands its text, its payload and its take id to the delivery")
  func liveRowIsDelivered() async {
    let spy = Spy()
    let held = payload()
    await run(payload: held, row: ("kept text", Date(), "take-1"), spy: spy)

    #expect(spy.delivered.count == 1)
    #expect(spy.delivered.first?.text == "kept text")
    #expect(spy.delivered.first?.payload == ObjectIdentifier(held))
    #expect(spy.delivered.first?.takeID == "take-1")
    #expect(spy.notices.isEmpty, "a delivered paste raises no Copied notice")
    #expect(spy.reports.map(\.result) == [.pasted])
    #expect(spy.reports.map(\.takeID) == ["take-1"])
  }

  @Test("a lapsed row delivers nothing and reports nothing")
  func lapsedRowDeliversNothing() async {
    let spy = Spy()
    await run(payload: payload(), row: nil, spy: spy)

    #expect(spy.delivered.isEmpty)
    #expect(spy.notices.isEmpty)
    #expect(spy.reports.isEmpty)
    #expect(spy.logs.map(\.outcome) == ["no-row"])
  }

  @Test("a row with no take id still delivers and logs, and reports nothing")
  func idlessRowDeliversWithoutTelemetry() async {
    let spy = Spy()
    await run(payload: payload(), row: ("kept", Date(), nil), spy: spy)

    #expect(spy.delivered.count == 1 && spy.delivered.first?.takeID == nil)
    #expect(spy.reports.isEmpty, "without a take id, telemetry must stay silent")
    #expect(spy.logs.map(\.outcome) == [EscapeRecoveryPasteResult.pasted.rawValue])
  }

  @Test(
    "a delivery that ends on the clipboard asks for the Copied notice and reports clipboard_only",
    arguments: [HeldTextDeliveryOutcome.clipboardOnly, .accessibilityDenied])
  func clipboardEndingShowsTheNotice(outcome: HeldTextDeliveryOutcome) async {
    let spy = Spy()
    let held = payload()
    let result = HeldTextDeliveryResult(outcome: outcome, fallbackClipboardChangeCount: 7)
    await run(payload: held, row: ("kept", Date(), "take-2"), returning: result, spy: spy)

    #expect(spy.notices.count == 1)
    #expect(spy.notices.first?.result == result, "the delivery's own receipt reaches the notice")
    #expect(spy.notices.first?.takeID == "take-2")
    #expect(spy.notices.first?.transcriptID == held.transcriptID)
    #expect(spy.reports.map(\.result) == [.clipboardOnly])
  }

  /// The settings are read at the PRESS, before anything is awaited. A coordinator with no row
  /// keeps the delivery from running, so this case never reaches a live field or clipboard.
  @Test("the wiring reads the delivery settings synchronously at the press")
  func settingsAreSnapshottedAtThePress() {
    let coordinator = TranscriptCoordinator(store: TranscriptStore())
    final class Reads { var count = 0 }
    let reads = Reads()
    let action = EscapeRecoveryWiring.pasteAction(
      coordinator: coordinator, overlay: nil,
      settingsAtPress: {
        reads.count += 1
        return HeldDeliverySettings(
          smartInsertion: true, autoPasteToActiveApp: true, restoreClipboardAfterPaste: false)
      },
      report: { _, _, _ in })

    action(payload())

    #expect(reads.count == 1, "read once, before the press returns")
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
