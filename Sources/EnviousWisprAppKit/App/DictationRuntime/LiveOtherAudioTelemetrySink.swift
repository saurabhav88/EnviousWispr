import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// #1413 — where the hold's facts go, through the two wrappers only
/// (`observability-operations.md` RULE: observability-is-a-limb).
///
/// PostHog: zero new rows. The summary is folded onto the take's existing
/// `dictation.terminal` row through `TakeStageLedger`, the #2958 mechanism.
/// Sentry: a breadcrumb per observation; `captureDefect` only for an
/// established app defect (plan §3.7) — conditions that are the user's, the
/// OS's or a player's never alert.
@MainActor
final class LiveOtherAudioTelemetrySink: OtherAudioTelemetrySink {
  private let telemetry: TelemetryService
  /// The take id the summary landed on, so the media half updates THAT row and
  /// never a later take's.
  private var summaryTakeID: String?

  init(telemetry: TelemetryService = .shared) {
    self.telemetry = telemetry
  }

  func recordTakeSummary(_ summary: OtherAudioTakeSummary) {
    summaryTakeID = telemetry.recordOtherAudioTake(
      OtherAudioTerminalFacts(
        mode: summary.mode, volume: summary.volume.rawValue, mute: summary.mute.rawValue,
        media: summary.media.rawValue, outputTransport: summary.outputTransport,
        applyMicros: summary.applyMicros, restoreMicros: summary.restoreMicros,
        recordMicros: summary.recordMicros, failure: summary.failure))
    if summaryTakeID == nil {
      Task {
        await AppLogger.shared.log(
          "other_audio summary: no open take entry", level: .info, category: "OtherAudio")
      }
    }
  }

  func recordMediaSettled(_ media: OtherAudioMediaDisposition) {
    guard let takeID = summaryTakeID else { return }
    telemetry.updateOtherAudioMedia(takeID: takeID, media: media.rawValue)
  }

  func breadcrumb(_ message: String, data: [String: String]) {
    SentryBreadcrumb.add(stage: "other_audio", message: message, data: data)
  }

  func captureDefect(_ message: String, data: [String: String]) {
    SentryBreadcrumb.captureError(
      OtherAudioDefect(message: message), category: .stateMismatch, stage: "other_audio",
      extra: data)
  }
}

/// An invariant of the hold broken by our own code (a disposition outside the
/// §4 tables, a restore attempted without a confirmed read-back). Nothing about
/// a device, a file or a player is a defect.
struct OtherAudioDefect: Error, StableSentryErrorIdentity {
  let message: String
  var sentryFingerprintDescriptor: String { "other_audio_defect" }
  var sentrySemanticID: String { message }
}
