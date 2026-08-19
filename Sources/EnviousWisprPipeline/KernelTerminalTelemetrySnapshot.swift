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
  /// Built-in-family input detail frozen at bind time: `built_in_mic` or
  /// `jack_input`. Nil for USB, Bluetooth, and every other transport — those are
  /// distinguished by `effectiveTransport`, not here. Never a device identifier.
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

/// #2184 — what the VAD's segments did to this take's audio, frozen at the
/// conditioner.
///
/// The fleet had no signal for this class at all. A take whose speech the VAD
/// read as silence produces a fluent, confident, short transcript, and the only
/// place the shape was ever visible was a debug-build log line nobody queries.
/// Six of the founder's takes lost 42%, 87% and 55% of their audio and not one
/// of them was countable.
///
/// **Stamped immediately after `CapturedAudioConditioner.condition` returns**,
/// so it is present on every terminal that happens after conditioning —
/// completion, salvaged completion, ASR-empty-despite-audio, and the post-ASR
/// no-speech terminals — and absent on the ones that conclude before it. That
/// absence is the correct reading and is why the field is optional: a take that
/// never reached the conditioner has no conditioning to report, and defaulting
/// it would put a fabricated ratio in the denominator of every query.
///
/// It is deliberately NOT hung off the completion payload. That path runs only
/// after a SUCCESSFUL decode, while the zero-output cases this record exists to
/// reveal take the no-speech and asr-empty terminals instead — so a completion-
/// only signal would omit precisely the failures it was added for.
///
/// Content-free: three counts and one closed-vocabulary label. Never audio,
/// never transcript.
struct KernelVADConditioningTelemetry: Sendable, Equatable {
  /// Samples the capture produced, before any VAD trim.
  let rawSampleCount: Int

  /// Samples after `SampleFilter`, BEFORE the raw fallback and before padding —
  /// `ConditionedAudio.filteredSampleCount`. Equal to `rawSampleCount` when the
  /// filter no-op'd, which is what makes the ratio below readable.
  let filteredSampleCount: Int

  /// `ConditionedAudio.conditioningReason`: `filtered`, `filteredPaddedToMinimum`,
  /// `rawFallbackTooAggressive` or `rawSoftOnset`. A closed vocabulary owned by
  /// that type; do not mint values here.
  let conditioningReason: String

  /// The fraction of the capture the VAD kept. A population of these is what
  /// makes the failure countable: an ordinary take sits near 1.0, and the
  /// aeroplane takes that started this issue sat between 0.07 and 0.43.
  ///
  /// **Not an acceptance metric, in either direction.** Seven measured clips
  /// retain between 13% and 51% of their audio and still deliver 100% of their
  /// words, and one retains 7% and loses 88%. Read it as a distribution that
  /// shifts, never as a per-take verdict, and do not build a fallback on it.
  var retainedRatio: Double {
    Double(filteredSampleCount) / Double(max(rawSampleCount, 1))
  }
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
  /// #2087. Defaulted to `.ordinary` so every existing construction site is
  /// unchanged.
  ///
  /// The default is a trade, not a safeguard: it PERMITS a new construction site
  /// to omit the field and report an escape recovery as an ordinary dictation.
  /// What actually prevents that is `EscapeRecoveryTerminalDispositionTests`,
  /// which drives the real kernel and fails if the value is not populated —
  /// added because a mutation hardcoding `.ordinary` survived every other test.
  var deliveryDisposition: DeliveryDisposition = .ordinary

  /// #2184. Nil when the take concluded before conditioning ran. Defaulted so
  /// every existing construction site is unchanged; the default is honest here
  /// in a way `deliveryDisposition`'s is not, because "no conditioning happened"
  /// is exactly what a nil means.
  var vadConditioning: KernelVADConditioningTelemetry?
}

/// Whether a terminal row describes a delivered dictation or a held recovery
/// (#2087).
///
/// Additive on `dictation.terminal` rather than a ninth `result` label: the
/// existing eight-label vocabulary is what every shipped chart reads, so adding
/// to it breaks them, while adding a NEW dimension leaves them working and lets
/// a new query disaggregate.
enum DeliveryDisposition: String, Sendable, CaseIterable {
  case ordinary
  case escapeRecovery = "escape_recovery"
}
