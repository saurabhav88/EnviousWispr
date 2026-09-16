import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

// #1413 — the real sink over the real ledger fold: a hold's facts land on ITS
// take's row, a late media settlement updates only that row, a closed take is a
// no-op, and absent timings stay absent. Zero new event names: everything rides
// on the terminal projection.

@MainActor
@Suite("Other audio telemetry", .tags(.observabilityContract))
struct OtherAudioTelemetryTests {
  private func summary(
    holdID: UUID, media: OtherAudioMediaDisposition = .pending, failure: String? = nil
  ) -> OtherAudioTakeSummary {
    OtherAudioTakeSummary(
      mode: "pauseMusic", volume: .notApplied, mute: .notApplied, media: media,
      failure: failure, holdID: holdID)
  }

  @Test("Late media updates its own take through the real sink and service")
  func lateMediaKeepsTakeIdentity() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    let sink = LiveOtherAudioTelemetrySink(telemetry: service)
    let holdA = UUID()
    let holdB = UUID()

    ledger.open(takeID: "A")
    sink.recordTakeSummary(summary(holdID: holdA))
    ledger.open(takeID: "B")
    sink.recordTakeSummary(summary(holdID: holdB))

    sink.recordMediaSettled(.resumeFailed, holdID: holdA, failure: "resume_failed")

    let a = try #require(ledger.close(takeID: "A")?.otherAudio)
    #expect(a.media == "resume_failed")
    #expect(a.failure == "resume_failed")

    sink.recordMediaSettled(.resumed, holdID: holdB, failure: nil)
    let b = try #require(ledger.close(takeID: "B")?.otherAudio)
    #expect(b.media == "resumed")
    #expect(b.failure == nil)
  }

  @Test("A closed take cannot be revived or redirected to a newer take")
  func closedTakeIsNoOp() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    let sink = LiveOtherAudioTelemetrySink(telemetry: service)
    let holdA = UUID()
    let holdB = UUID()

    ledger.open(takeID: "A")
    sink.recordTakeSummary(summary(holdID: holdA))
    #expect(ledger.close(takeID: "A") != nil)

    ledger.open(takeID: "B")
    sink.recordTakeSummary(summary(holdID: holdB))
    sink.recordMediaSettled(.resumeFailed, holdID: holdA, failure: "resume_failed")

    #expect(ledger.openCount == 1)
    let b = try #require(ledger.close(takeID: "B")?.otherAudio)
    #expect(b.media == "pending")
    #expect(b.failure == nil)
    #expect(ledger.close(takeID: "A") == nil)
  }

  @Test("Settlement before its summary cannot change another hold's row")
  func earlySettlementIsIsolated() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    let sink = LiveOtherAudioTelemetrySink(telemetry: service)

    ledger.open(takeID: "A")
    sink.recordTakeSummary(summary(holdID: UUID()))
    sink.recordMediaSettled(.nothingPaused, holdID: UUID(), failure: "consent_denied")

    let a = try #require(ledger.close(takeID: "A")?.otherAudio)
    #expect(a.media == "pending")
    #expect(a.failure == nil)
  }

  @Test("Terminal projection omits absent timings and carries no local correlation")
  func terminalProjection() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    let sink = LiveOtherAudioTelemetrySink(telemetry: service)

    ledger.open(takeID: "A")
    sink.recordTakeSummary(summary(holdID: UUID(), media: .nothingPaused, failure: "record_failed"))

    let row = try #require(ledger.close(takeID: "A")).terminalProperties
    #expect(
      Set(row.keys)
        == Set([
          "vad_stage_reached", "other_audio_mode", "other_audio_volume", "other_audio_mute",
          "other_audio_media", "other_audio_failure",
        ]))
    #expect(row["other_audio_failure"] as? String == "record_failed")
    #expect(row["other_audio_media"] as? String == "nothing_paused")
  }

  @Test("Newest-entry writes target the newest open take; absent entries stay absent")
  func newestEntry() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    let facts = OtherAudioTerminalFacts(
      mode: "mute", volume: "not_applied", mute: "restored", media: "nothing_paused",
      applyMicros: 0)

    #expect(service.recordOtherAudioTake(facts) == nil)
    #expect(ledger.openCount == 0)

    ledger.open(takeID: "A")
    ledger.open(takeID: "B")
    #expect(service.recordOtherAudioTake(facts) == "B")
    #expect(ledger.close(takeID: "A")?.otherAudio == nil)

    let b = try #require(ledger.close(takeID: "B"))
    #expect(b.otherAudio == facts)
    #expect(b.terminalProperties["other_audio_apply_us"] as? Int == 0)
    #expect(b.terminalProperties["other_audio_restore_us"] == nil)

    service.updateOtherAudioMedia(takeID: "B", media: "resume_failed", failure: "resume_failed")
    #expect(ledger.openCount == 0)
  }
}
