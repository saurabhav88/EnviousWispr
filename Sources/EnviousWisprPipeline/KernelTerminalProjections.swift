import EnviousWisprCore
import Foundation

// The two pure projections a concluded take needs, in one place because two
// different consumers need the same answer and a second copy would drift.
//
// `KernelHeartPathTelemetryObserver` reaches a terminal ASYNCHRONOUSLY, through
// observation that is explicitly not a lossless queue. The terminal telemetry
// path reaches the same terminal SYNCHRONOUSLY, from an immutable snapshot
// frozen inside `finishTerminal`. Both must classify an ending identically or
// the two vendors disagree about what happened to one dictation (#1884).

extension RecordingOutcome {

  /// The terminal lifecycle event this ending represents (#1548 D1).
  ///
  /// Total and non-optional: every `RecordingOutcome` is an ending, so there is
  /// no "not a terminal" answer to return. The observer's earlier form was
  /// `-> KernelLifecycleEvent?` with an unused `isStreaming:` parameter; neither
  /// carried information (no arm returned nil, no arm read the flag), and both
  /// were dropped when this moved here.
  ///
  /// `.noTransport` projects to `.failed(.noAudioCaptured)` — a LOCKED
  /// projection. It deliberately reuses the existing telemetry identity rather
  /// than minting a new one, so a transport-less take is counted with the
  /// captured-nothing family it belongs to.
  var lifecycleEvent: KernelLifecycleEvent {
    switch self {
    case .completed:
      .pipelineCompleted
    case .failed(let reason):
      .failed(reason)
    case .cancelled:
      .cancelled
    case .discarded(let reason):
      .discarded(reason)
    case .noSpeech(let source):
      .noSpeech(source)
    case .audioInterrupted(let cause):
      // Default defensively to `.engineLost` when the cause was not stamped: a
      // lost recording with no cause is still an unowned loss (#1174 A3).
      .audioInterrupted(cause: cause ?? .engineLost)
    case .asrInterrupted(let wasRecording):
      .asrInterrupted(wasRecording: wasRecording)
    case .noTransport:
      .failed(.noAudioCaptured)
    }
  }
}

extension RecordingFailureReason {

  /// The stable, presentation-neutral reason code for this failure.
  ///
  /// `TerminalNoticeReason.rawValue` is the SHIPPED PostHog vocabulary — it is
  /// what `pipeline.failed.error_code` already carries — so terminal telemetry
  /// reuses it rather than emitting raw Swift case names. Snake_case, stable,
  /// and already what our queries and the daily report are written against.
  ///
  /// Exhaustive with no `default`, so adding a `RecordingFailureReason` is a
  /// compile error here rather than a silently unmapped value in the data.
  ///
  /// One non-identity mapping: `.asrEmpty → .asrEmptyWithSpeech`. That is the
  /// name #1890 counts, and it is more precise than the case name — the ASR ran
  /// and returned nothing while the gate had accepted speech.
  var terminalNoticeReason: TerminalNoticeReason {
    switch self {
    case .prepareFailed: .prepareFailed
    case .permissionDenied: .permissionDenied
    case .modelWedged: .modelWedged
    case .modelLoadFailed: .modelLoadFailed
    case .captureStartFailed: .captureStartFailed
    case .noMicrophoneFound: .noMicrophoneFound
    case .noAudioCaptured: .noAudioCaptured
    case .asrEmpty: .asrEmptyWithSpeech
    case .asrFailed: .asrFailed
    case .asrWedged: .asrWedged
    case .emptyAfterProcessing: .emptyAfterProcessing
    case .captureStalled: .captureStalled
    case .zeroSignal: .zeroSignal
    }
  }
}
