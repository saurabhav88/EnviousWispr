import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// The local support trail for Escape Recovery. These cases protect what can be
/// diagnosed after a press, not whether the user's text was restored.
@MainActor
@Suite("Escape Recovery observability (#2087)", .tags(.observabilityContract))
struct EscapeRecoveryObservabilityTests {

  @MainActor
  private final class RestoreLogBox {
    var logs: [(outcome: String, ageMs: Int?, takeID: String?)] = []
    var reports: [(result: EscapeRecoveryPasteResult, takeID: String)] = []
    var retargetCount = 0
  }

  @MainActor
  private final class KeepLogBox {
    var logs: [(outcome: String, takeID: String?)] = []
  }

  @Test("an id-less Undo is logged even though telemetry cannot join it")
  func idlessUndoStillLogs() {
    let box = RestoreLogBox()
    let payload = CancelUndoPayload(
      transcriptID: UUID(), targetApp: nil, targetElement: nil)

    EscapeRecoveryPasteAction.paste(
      payload: payload,
      restorable: { _ in ("kept", Date(timeIntervalSinceNow: -1), nil) },
      copyToClipboard: { _ in },
      report: { _, result, takeID in box.reports.append((result, takeID)) },
      retarget: { _ in
        box.retargetCount += 1
        return false
      },
      targetHasQuit: { _ in false },
      recordLog: { box.logs.append(($0, $1, $2)) })

    #expect(box.retargetCount == 1, "control: the restore reached its terminal path")
    #expect(box.reports.isEmpty, "without a take id, telemetry must stay silent")
    #expect(box.logs.count == 1)
    #expect(box.logs.first?.outcome == EscapeRecoveryPasteResult.clipboardOnly.rawValue)
    #expect((box.logs.first?.ageMs ?? -1) >= 1_000)
    #expect(box.logs.first?.takeID == nil)
  }

  @Test("an Undo pressed after its row lapses records the refusal")
  func missingRowLogsTheRefusal() {
    let box = RestoreLogBox()

    EscapeRecoveryPasteAction.paste(
      payload: CancelUndoPayload(
        transcriptID: UUID(), targetApp: nil, targetElement: nil),
      restorable: { _ in nil },
      copyToClipboard: { _ in },
      report: { _, result, takeID in box.reports.append((result, takeID)) },
      retarget: { _ in
        box.retargetCount += 1
        return true
      },
      targetHasQuit: { _ in false },
      recordLog: { box.logs.append(($0, $1, $2)) })

    #expect(box.retargetCount == 0)
    #expect(box.reports.isEmpty)
    #expect(box.logs.count == 1)
    #expect(box.logs.first?.outcome == "no-row")
    #expect(box.logs.first?.ageMs == nil)
    #expect(box.logs.first?.takeID == nil)
  }

  @Test("a Keep pressed after its row lapses records the refusal")
  func refusedKeepStillLogs() {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = KeepLogBox()
    let coordinator = TranscriptCoordinator(
      store: store,
      recordEscapeRecoveryKeep: { box.logs.append(($0, $1)) })
    let vanished = held(takeID: "take-late")

    coordinator.keep(vanished)

    #expect(box.logs.count == 1)
    #expect(box.logs.first?.outcome == "refused-not-offerable")
    #expect(box.logs.first?.takeID == "take-late")
  }

  @Test("a successful Keep records its join key")
  func successfulKeepLogs() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = KeepLogBox()
    let row = held(takeID: "take-kept")
    try store.savePending(row)
    let coordinator = TranscriptCoordinator(
      store: store,
      emitEscapeRecoveryKept: { _, _ in },
      recordEscapeRecoveryKeep: { box.logs.append(($0, $1)) })

    coordinator.keep(row)

    #expect(box.logs.count == 1)
    #expect(box.logs.first?.outcome == "kept")
    #expect(box.logs.first?.takeID == "take-kept")
  }

  @Test("a successful Keep without a join key records the anomaly")
  func unreportedKeepLogs() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = KeepLogBox()
    let row = held(takeID: nil)
    try store.savePending(row)
    let coordinator = TranscriptCoordinator(
      store: store,
      recordEscapeRecoveryKeep: { box.logs.append(($0, $1)) })

    coordinator.keep(row)

    #expect(box.logs.count == 1)
    #expect(box.logs.first?.outcome == "kept-unreported")
    #expect(box.logs.first?.takeID == nil)
  }

  private func makeStore() -> (TranscriptStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-2177-observability-\(UUID().uuidString)", isDirectory: true)
    return (TranscriptStore(directory: directory), directory)
  }

  private func held(takeID: String?) -> Transcript {
    Transcript(
      text: "held", backendType: .parakeet,
      escapeRecoveredAt: Date(timeIntervalSinceNow: -60),
      escapeRecoveryTakeID: takeID)
  }
}
