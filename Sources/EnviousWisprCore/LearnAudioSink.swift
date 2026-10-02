import Foundation

// MARK: - Take-scoped learn audio (#3338 PR-4, plan §3.E E.1, registry K5/K6)
//
// After a Parakeet dictation, the recording session hands the winning decode's own
// input to a short-lived hold, so a later learn decision about that take can listen
// to it again (the nudge). These are the shapes only: the kernel produces records
// through `LearnAudioSink`, the AppKit hold owns them, and the nudge provider reads
// them through `LearnAudioLeasing`. Nothing here retains, schedules or decodes.

/// Which decode produced the text that was pasted, so the samples and word timings
/// in a `LearnTakeAudio` are known to belong to the same pass. A successful streaming
/// finalization has no case: its exact consumed samples cannot be named, so such a
/// take keeps no learn audio (plan §16, 2026-10-02).
package enum LearnTakeDecodePath: String, Sendable, Equatable, CaseIterable {
  /// Batch decode of the recorded samples.
  case batch
  /// Batch decode of conditioned samples (the kernel's conditioned ASR input).
  case conditionedBatch
  /// The batch decode that rescued a failed streaming take.
  case streamingRescueBatch
  /// A retry decode that replaced the first result.
  case retry
  /// The lead-trimmed salvage decode.
  case leadSalvage
}

/// Which buffer the samples in a `LearnTakeAudio` were copied from, so a reader can tell
/// the kernel's ASR input from an adapter fallback or a streaming capture.
package enum LearnTakeSampleOrigin: String, Sendable, Equatable, CaseIterable {
  /// The kernel's ASR input handed to the adapter's finalize (`batchSamples`).
  case kernelASRInput
  /// The adapter's own retained PCM, used when no `batchSamples` was handed over.
  case adapterRetainedPCM
  /// The lead-trimmed slice of the kernel's ASR input that the salvage decode received.
  case leadTrimmedASRInput
}

/// An encoder window the winning batch decode already computed, handed over so a
/// nudge can decode it again without a second encoder pass (plan C.2b).
///
/// Opaque on purpose: Core names no engine types. The ASR module implements it
/// around the engine's own window. A conformer may be reused for a nudge only when
/// its sample origin, frame and context geometry and decode language are verified to
/// match the record it rides in; otherwise the nudge re-encodes `samples`.
/// Class-bound so a handle keeps its identity: releasing the last reference
/// releases the window.
package protocol LearnPreparedWindowHandle: AnyObject, Sendable {}

/// Everything a later learn decision may use from one take's winning decode.
/// Immutable; built once by the recording session.
package struct LearnTakeAudio: Sendable {
  /// The sample rate every record carries: the engine's input rate.
  package static let sampleRate = 16_000

  package let takeID: String
  /// The exact 16 kHz mono samples the winning decode received.
  package let samples: [Float]
  package let decodePath: LearnTakeDecodePath
  /// The buffer `samples` came from.
  package let sampleOrigin: LearnTakeSampleOrigin
  /// The language option exactly as passed to the decode (`TranscriptionOptions.language`).
  /// `nil` means no language option was supplied; it is never inferred or filled in afterwards.
  package let decodeLanguage: String?
  /// The decode's raw text, before polish or formatting.
  package let rawText: String
  /// The decode's raw word timings over `rawText`. `nil` when the decode gave none;
  /// never synthesized.
  package let wordTimings: [ASRWordTiming]?
  /// Encoder windows from the same decode, when handed over (plan C.2b); empty otherwise.
  package let preparedWindows: [any LearnPreparedWindowHandle]

  /// `nil` for an empty take: there is nothing to listen to again.
  package init?(
    takeID: String, samples: [Float], decodePath: LearnTakeDecodePath, sampleOrigin: LearnTakeSampleOrigin,
    decodeLanguage: String?,
    rawText: String, wordTimings: [ASRWordTiming]?,
    preparedWindows: [any LearnPreparedWindowHandle] = []
  ) {
    guard !takeID.isEmpty, !samples.isEmpty else { return nil }
    self.takeID = takeID
    self.samples = samples
    self.decodePath = decodePath
    self.sampleOrigin = sampleOrigin
    self.decodeLanguage = decodeLanguage
    self.rawText = rawText
    self.wordTimings = wordTimings
    self.preparedWindows = preparedWindows
  }

  /// Length of the take in milliseconds.
  package var durationMs: Int { samples.count * 1000 / Self.sampleRate }
}

/// The recording session's side of the hold. The session calls `retain` right after
/// transcription and before paste, `markPasted` only after a successful paste, and
/// `discard` on a failed, clipboard-only or suppressed delivery.
///
/// `atMs` is the learn watcher's clock (the clock its 60 s watch ceiling uses), so the
/// hold's expiry and the watch window are measured on one clock.
///
/// Synchronous main-actor bookkeeping: the session calls these on its own path, so a
/// take is retained before processing and paste begin. A conformer only records or
/// drops entries here; it must not suspend, decode or block. Expiry and cancellation
/// work runs separately.
@MainActor
package protocol LearnAudioSink: Sendable {
  func retain(takeID: String, record: LearnTakeAudio)
  func markPasted(takeID: String, atMs: Int)
  func discard(takeID: String)
}

/// The nudge's side of the hold. A lease is a read-only view of one take's record.
package protocol LearnAudioLeasing: Sendable {
  /// A lease on the take's record, or `nil` when the take is unknown, expired, no
  /// longer accepting leases, or not eligible.
  func lease(takeID: String) async -> (any LearnAudioLease)?
}

/// One borrower's access to a held record.
///
/// Obligations (the hold enforces the first two; the borrower owns the third):
/// - `read()` returns `nil` once the lease has ended or the hold cancelled it; there is
///   no new access after either.
/// - `end()` is idempotent; the hold frees a take's samples only when the take is gone
///   AND every lease on it has ended.
/// - The borrower drops every copy of the record and of its windows when its work
///   finishes or is cancelled. A protocol cannot enforce that release; the hold's
///   release tests measure it.
package protocol LearnAudioLease: Sendable {
  func read() async -> LearnTakeAudio?
  /// True once the hold cancelled this lease (expiry, recording start, toggle off,
  /// sleep, memory pressure, termination). Borrowers check it between steps.
  var isCancelled: Bool { get async }
  /// Registers the borrower's cancellation signal. Called at most once, when the hold
  /// cancels this lease; called at once if it is already cancelled. Never called after
  /// `end()`. The handler only signals (for example, cancels a task); it must not decode or wait.
  func onCancel(_ handler: @escaping @Sendable () -> Void) async
  func end() async
}
