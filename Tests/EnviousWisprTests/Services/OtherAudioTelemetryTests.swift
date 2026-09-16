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

    sink.recordMediaSettled(.resumeFailed, holdID: holdA, failure: "resume_failed", route: nil, adapterFailure: nil)

    let a = try #require(ledger.close(takeID: "A")?.otherAudio)
    #expect(a.media == "resume_failed")
    #expect(a.failure == "resume_failed")

    sink.recordMediaSettled(.resumed, holdID: holdB, failure: nil, route: nil, adapterFailure: nil)
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
    sink.recordMediaSettled(.resumeFailed, holdID: holdA, failure: "resume_failed", route: nil, adapterFailure: nil)

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
    sink.recordMediaSettled(.nothingPaused, holdID: UUID(), failure: "consent_denied", route: nil, adapterFailure: nil)

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

  @Test("v1.1: route and adapter failure are absent until set, then ride the same row")
  func routeFacts() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    let sink = LiveOtherAudioTelemetrySink(telemetry: service)
    let hold = UUID()

    ledger.open(takeID: "A")
    var pending = summary(holdID: hold, media: .pending, failure: nil)
    pending.mediaRoute = "adapter"
    sink.recordTakeSummary(pending)
    sink.recordMediaSettled(.sourceChanged, holdID: hold, failure: nil, route: "adapter", adapterFailure: nil)
    let a = try #require(ledger.close(takeID: "A")).terminalProperties
    #expect(a["other_audio_media_route"] as? String == "adapter")
    #expect(a["other_audio_media"] as? String == "source_changed")
    #expect(a["other_audio_adapter_failure"] == nil)

    ledger.open(takeID: "B")
    var fell = summary(holdID: UUID(), media: .nothingPaused, failure: nil)
    fell.mediaRoute = "scripted"
    fell.adapterFailure = "timeout"
    sink.recordTakeSummary(fell)
    let b = try #require(ledger.close(takeID: "B")).terminalProperties
    #expect(b["other_audio_media_route"] as? String == "scripted")
    #expect(b["other_audio_adapter_failure"] as? String == "timeout")

    ledger.open(takeID: "C")
    let late = UUID()
    sink.recordTakeSummary(summary(holdID: late, media: .pending, failure: nil))
    sink.recordMediaSettled(.resumed, holdID: late, failure: nil, route: "scripted", adapterFailure: "exit")
    let c = try #require(ledger.close(takeID: "C")).terminalProperties
    #expect(c["other_audio_media_route"] as? String == "scripted", "a late outcome carries the route")
    #expect(c["other_audio_adapter_failure"] as? String == "exit")
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
