import EnviousWisprCore
import Foundation

/// Hardware and signal facts for a take that captured nothing usable (#1890).
///
/// **Every field is frozen at its PRODUCER, never re-read at the terminal.**
/// That is structural, not stylistic. `gotchas-audio.md`
/// RULE: read-the-bind-prepare-returned-never-re-derive-it establishes that the
/// bind read ORDER is load-bearing; a telemetry read at terminal time is
/// innocent in intent and indistinguishable in effect from the bug that rule
/// exists to prevent. Freezing at the producer makes the invariant true by
/// construction instead of by discipline.
///
/// Content-free by construction: counts, magnitudes, durations, and
/// closed-vocabulary transport/device-class strings. Never a raw device UID
/// (its USB form embeds the unit serial, its Bluetooth form is the peer MAC),
/// never a device name or model, never audio, never transcript.
///
/// **Every optional omits rather than defaulting.** `peakAudioLevel` is optional
/// for exactly that reason: an exact zero is the signature of a digitally dead
/// channel (#1809), so defaulting a missing reading to `0` would manufacture the
/// most diagnostically loaded value in the dataset and make absent data
/// indistinguishable from the finding this record exists to detect.
struct KernelSignalAttributionTelemetry: Sendable, Equatable {
  /// Which physical input class produced the capture, from the bind-frozen
  /// value — one of the four closed classes, never a device identifier.
  let inputDeviceKind: String?
  let effectiveTransport: String?
  let selectedTransport: String?
  let inputSelectionMode: String?

  /// Signal magnitudes measured ONCE, at the producer, over the already-captured
  /// buffer. Nil means not computed, never "silent".
  let wholeBufferRMS: Float?
  let maxWindowRMS: Float?
  let peakAudioLevel: Float?

  let durationMs: Int?
  let captureNativeRateHz: Double?
  let captureNativeChannelCount: Int?
}

/// Everything the terminal telemetry path needs, frozen at the moment the take
/// ended and valid forever after.
///
/// Constructed inside `RecordingSessionKernel.finishTerminal` once the set-once
/// guard has accepted an outcome, while `sid` still unambiguously identifies the
/// concluded session. Delivered by a single `defer` so an accepted terminal
/// cannot lose its event at a later cleanup return.
///
/// **The consumer must render this and nothing else.** It may not read
/// `KernelTelemetryState`, `KernelSessionContext`, `AudioCaptureInterface`,
/// captured samples, or any other live session state. The whole point is that
/// take B can start immediately and change all of those without altering what
/// take A reported — the identity race that made the observer path unusable for
/// this (#1884, grounded review r1).
///
/// Vendor-neutral on purpose: no PostHog event names, no property keys. The
/// kernel decides WHAT happened; the sink decides how to say it.
struct KernelTerminalTelemetrySnapshot: Sendable {
  let takeID: String
  let backend: String
  let outcome: RecordingOutcome
  let signalAttribution: KernelSignalAttributionTelemetry?
}
