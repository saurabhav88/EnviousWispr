import EnviousWisprAudio
import Foundation

/// Reason the VAD monitor loop requests a recording stop.
internal enum VADStopReason: Sendable {
  case silenceTimeout
  case maxDuration
}

/// Shared VAD monitoring loop used by both pipelines during recording.
///
/// Does not own the SilenceDetector, the monitoring task, or stop guards.
/// Those stay on the pipeline. This is the loop algorithm only.
@MainActor
internal enum VADMonitorLoop {

  /// Run the VAD monitoring loop. Returns when recording stops or auto-stop triggers.
  ///
  /// For in-process mode: pass the prepared detector. Processes audio chunks and triggers
  /// auto-stop on silence detection.
  /// For XPC mode: pass nil for detector. Only enforces max recording duration.
  ///
  /// - Parameters:
  ///   - detector: Prepared SilenceDetector, or nil for XPC mode (service handles VAD)
  ///   - vadAutoStop: Whether silence-triggered auto-stop is enabled
  ///   - maxDuration: Maximum recording duration in seconds
  ///   - recordingStartTime: When recording began (for max duration check)
  ///   - sampleProvider: Returns current captured samples array (called on @MainActor)
  ///   - isRecording: Returns whether recording is still active
  ///   - warningLead: Seconds before `maxDuration` at which to fire the one-shot
  ///     approaching-cap warning (#1060). No warning if `warningLead <= 0` or
  ///     `maxDuration <= warningLead`.
  ///   - now: Injectable wall clock (defaults to `Date()`); tests pass a manual
  ///     clock so the warning/stop thresholds are exercised without real sleeps.
  ///   - onApproachingMaxDuration: Fired at most once when elapsed crosses
  ///     `maxDuration - warningLead`, carrying the actual remaining seconds.
  ///     Advisory only — recording continues; never stops.
  ///   - onStop: Called when auto-stop should trigger. Runs in a new Task to avoid
  ///     cancellation propagation from the monitor task into transcription.
  static func run(
    detector: SilenceDetector?,
    vadAutoStop: Bool,
    maxDuration: TimeInterval,
    warningLead: TimeInterval,
    recordingStartTime: Date,
    sampleProvider: @escaping @MainActor () -> [Float],
    isRecording: @escaping @MainActor () -> Bool,
    now: @escaping @MainActor () -> Date = { Date() },
    onApproachingMaxDuration: @escaping @MainActor (TimeInterval) -> Void,
    onStop: @escaping @MainActor (VADStopReason) -> Void
  ) async {
    // One-shot approaching-cap warning (#1060). Fires at most once per run when
    // elapsed crosses `maxDuration - warningLead`, only when the cap is long
    // enough to have a lead window. Advisory — it never stops the recording.
    var warningFired = false
    let warningArmed = warningLead > 0 && maxDuration > warningLead
    let warningThreshold = maxDuration - warningLead
    func maybeWarn(elapsed: TimeInterval) {
      guard warningArmed, !warningFired, elapsed >= warningThreshold else { return }
      warningFired = true
      onApproachingMaxDuration(maxDuration - elapsed)
    }

    if let detector {
      // In-process mode: process chunks through SilenceDetector
      var processedSampleCount = 0
      let chunkSize = SilenceDetector.chunkSize

      while isRecording() && !Task.isCancelled {
        // Max duration check
        let elapsed = now().timeIntervalSince(recordingStartTime)
        if elapsed >= maxDuration {
          onStop(.maxDuration)
          return
        }
        maybeWarn(elapsed: elapsed)

        // Snapshot only the COUNT (an Int), never the whole array, across the
        // chunk-processing awaits below. Binding `sampleProvider()`'s full array
        // while `ingestSamples` appends would COW-copy the entire growing
        // recording once per chunk — quadratic memory traffic that can stall a
        // long dictation now that this is the production path (#1543 Codex r2
        // P1). Each chunk is sliced fresh into its own small array; the slice
        // happens MainActor-atomically (no await between the read and the copy),
        // so the capture buffer keeps refcount 1 and appends never copy.
        let currentCount = sampleProvider().count

        while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
          let endIdx = processedSampleCount + chunkSize
          // Re-check LIVE bounds before slicing (#1543 Codex r3 P1): a cancel or
          // capture failure can run `stopCapture()` during the prior
          // `processChunk` await, clearing `capturedSamples` so it is now shorter
          // than the stale `currentCount`. Slicing `[processedSampleCount..<endIdx]`
          // against the shrunk array would trap out-of-bounds. The count read and
          // the slice are MainActor-atomic (no await between), so the length
          // cannot change under us here.
          guard isRecording(), sampleProvider().count >= endIdx else { break }
          let chunk = Array(sampleProvider()[processedSampleCount..<endIdx])

          let shouldStop = await detector.processChunk(chunk)

          if shouldStop && vadAutoStop && isRecording() {
            onStop(.silenceTimeout)
            return
          }

          processedSampleCount += chunkSize
          await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(100))
      }
    } else {
      // XPC mode: service handles VAD. Only enforce max duration + warning here.
      while isRecording() && !Task.isCancelled {
        let elapsed = now().timeIntervalSince(recordingStartTime)
        if elapsed >= maxDuration {
          onStop(.maxDuration)
          return
        }
        maybeWarn(elapsed: elapsed)
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}
