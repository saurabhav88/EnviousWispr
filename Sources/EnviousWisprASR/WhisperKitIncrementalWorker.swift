import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

package struct IncrementalResult: Sendable {
  package let text: String?
  package let samplesCovered: Int
  package let decodeCount: Int
  package let totalDecodeTimeMs: Int  // periphery:ignore - telemetry field, populated for diagnostics
  package let accepted: Bool
  package let mode: String
  package let strategy: String
  package let tailDecodeMs: Int
}

/// Periodically transcribes the growing audio buffer during recording.
/// Purely an internal latency optimization — no UI, no streaming model.
///
/// Adaptive strategy:
/// - Short recordings (<30s): re-transcribe full buffer each cycle (highest quality)
/// - Long recordings (>30s): use clipTimestamps to only decode new audio (efficient)
/// - On finalize: async tail decode covers speech after the last worker result
package actor WhisperKitIncrementalWorker: WhisperKitIncrementalSession {
  private let whisperKit: WhisperKit
  private let baseDecodingOptions: DecodingOptions
  private let cadence: Duration = .seconds(3)
  private let longRecordingThreshold: Int = 16000 * 30

  private var accumulatedText: String = ""
  private var lastFullResult: String?
  private var lastResultSampleCount: Int = 0
  private var lastClipSeconds: Float = 0
  private var decodeCount: Int = 0
  private var totalDecodeTimeMs: Int = 0

  private var running = false
  private var loopTask: Task<Void, Never>?

  package init(whisperKit: WhisperKit, decodingOptions: DecodingOptions) {
    self.whisperKit = whisperKit
    self.baseDecodingOptions = decodingOptions
  }

  package func start(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) {
    running = true
    accumulatedText = ""
    lastFullResult = nil
    lastResultSampleCount = 0
    lastClipSeconds = 0
    decodeCount = 0
    totalDecodeTimeMs = 0

    loopTask = Task { [weak self] in
      guard let self else { return }
      await self.runLoop(audioSamplesProvider: audioSamplesProvider)
    }
  }

  // periphery:ignore:parameters speechSegments - kept for API compatibility; energy-based gate replaced VAD segment check
  package func finalize(
    finalSamples: [Float],
    speechSegments: [SpeechSegment]
  ) async -> IncrementalResult {
    running = false
    loopTask?.cancel()
    loopTask = nil

    let isLong = finalSamples.count > longRecordingThreshold

    guard decodeCount > 0 else {
      return IncrementalResult(
        text: nil, samplesCovered: 0, decodeCount: 0,
        totalDecodeTimeMs: 0, accepted: false,
        mode: isLong ? "clipped" : "full",
        strategy: "no_worker", tailDecodeMs: 0
      )
    }

    let candidateText = isLong ? accumulatedText : lastFullResult
    let hasText =
      candidateText != nil
      && !candidateText!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    guard hasText else {
      return IncrementalResult(
        text: nil, samplesCovered: lastResultSampleCount, decodeCount: decodeCount,
        totalDecodeTimeMs: totalDecodeTimeMs, accepted: false,
        mode: isLong ? "clipped" : "full",
        strategy: "no_worker", tailDecodeMs: 0
      )
    }

    let baseMode = isLong ? "clipped" : "full"

    // Gate tail decode on uncovered sample count + energy, not VAD segments.
    // In XPC mode, speechSegments is always [] (silenceDetector is nil in pipeline's
    // XPC monitorVAD branch), so the old tailHasSpeech guard always returned false
    // and the tail decode was permanently skipped — losing up to 3s of audio.
    let uncoveredSamples = finalSamples.count - lastResultSampleCount
    let needsTailDecode: Bool
    if uncoveredSamples > 1600 {  // >100ms uncovered
      // Quick RMS check — is there actual audio in the tail, not just silence?
      let tailStart = max(0, lastResultSampleCount)
      let tailSlice = Array(finalSamples[tailStart..<finalSamples.count])
      let rms =
        tailSlice.isEmpty
        ? Float(0) : sqrt(tailSlice.reduce(Float(0)) { $0 + $1 * $1 } / Float(tailSlice.count))
      needsTailDecode = rms > 0.001  // above noise floor
    } else {
      needsTailDecode = false
    }

    if !needsTailDecode {
      return IncrementalResult(
        text: candidateText, samplesCovered: lastResultSampleCount,
        decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
        accepted: true, mode: baseMode,
        strategy: "worker_only", tailDecodeMs: 0
      )
    }

    // Tail has speech — decode with standard silence padding.
    let paddedSamples = WhisperKitBackend.padAudioWithSilence(finalSamples)

    let tailStart = CFAbsoluteTimeGetCurrent()
    do {
      let overlapStartSeconds = max(0, Float(lastResultSampleCount) / 16000.0 - 1.0)
      let tailDurationSeconds = Float(finalSamples.count - lastResultSampleCount) / 16000.0
      var opts = baseDecodingOptions
      opts.clipTimestamps = [overlapStartSeconds]
      opts.windowClipTime = 0

      // Do NOT pass promptTokens for the tail decode. When the worker's last
      // text ends a sentence (e.g., "finalize the vendor contract"), prompt
      // tokens bias the decoder to emit end-of-text instead of transcribing
      // the remaining short fragment (e.g., "by Friday"). This was the root
      // cause of #216: tail decode returned empty despite speech being present.

      let results = try await whisperKit.transcribe(audioArray: paddedSamples, decodeOptions: opts)
      let tailText = results.map(\.text)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)

      await AppLogger.shared.log(
        "TAIL_DIAG: workerText=[\(candidateText?.suffix(60) ?? "nil")] "
          + "tailText=[\(tailText.suffix(60))] "
          + "overlapStart=\(String(format: "%.1f", overlapStartSeconds))s "
          + "uncoveredDuration=\(String(format: "%.1f", tailDurationSeconds))s "
          + "tailDecodeMs=\(tailMs)",
        level: .info, category: "WhisperKitWorker"
      )

      if !tailText.isEmpty {
        let finalText = candidateText! + " " + tailText
        return IncrementalResult(
          text: finalText, samplesCovered: finalSamples.count,
          decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
          accepted: true, mode: baseMode + "+tail",
          strategy: "worker+tail", tailDecodeMs: tailMs
        )
      }

      // Tail decode returned empty despite speech evidence (RMS > 0.001).
      // Do NOT silently accept the truncated worker result. Signal batch
      // fallback so the pipeline re-transcribes the full audio.
      await AppLogger.shared.log(
        "TAIL_DIAG: empty tail despite speech evidence, triggering batch fallback "
          + "(uncovered=\(String(format: "%.1f", tailDurationSeconds))s)",
        level: .info, category: "WhisperKitWorker"
      )
      return IncrementalResult(
        text: nil, samplesCovered: lastResultSampleCount,
        decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
        accepted: false, mode: baseMode,
        strategy: "tail_empty_fallback", tailDecodeMs: tailMs
      )
    } catch {
      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)
      return IncrementalResult(
        text: nil, samplesCovered: lastResultSampleCount,
        decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
        accepted: false, mode: baseMode,
        strategy: "batch_fallback", tailDecodeMs: tailMs
      )
    }
  }

  package func cancel() {
    running = false
    loopTask?.cancel()
    loopTask = nil
  }

  // MARK: - Private

  private func runLoop(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) async {
    while running && !Task.isCancelled {
      try? await Task.sleep(for: cadence)
      guard running && !Task.isCancelled else { break }

      let snapshot = await audioSamplesProvider()
      guard snapshot.count >= 16000 else { continue }

      let isLongRecording = snapshot.count > longRecordingThreshold
      let decodeStart = CFAbsoluteTimeGetCurrent()

      do {
        if isLongRecording {
          var opts = baseDecodingOptions
          opts.clipTimestamps = [lastClipSeconds]
          let results = try await whisperKit.transcribe(
            audioArray: snapshot.samples, decodeOptions: opts
          )
          let newText = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if !newText.isEmpty {
            if let lastSeg = results.last?.segments.last {
              lastClipSeconds = lastSeg.end
            }
            if accumulatedText.isEmpty {
              accumulatedText = newText
            } else {
              accumulatedText = accumulatedText + " " + newText
            }
            lastResultSampleCount = snapshot.count
          }
        } else {
          let results = try await whisperKit.transcribe(
            audioArray: snapshot.samples, decodeOptions: baseDecodingOptions
          )
          let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if !text.isEmpty {
            lastFullResult = text
            lastResultSampleCount = snapshot.count
          }
        }

        decodeCount += 1
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
        totalDecodeTimeMs += elapsedMs

        await AppLogger.shared.log(
          "WhisperKit incremental decode #\(decodeCount): \(elapsedMs)ms, "
            + "mode=\(isLongRecording ? "clipped" : "full"), " + "samples=\(snapshot.count)",
          level: .info, category: "WhisperKitWorker"
        )
      } catch {
        if !Task.isCancelled {
          await AppLogger.shared.log(
            "WhisperKit incremental decode failed: \(error.localizedDescription)",
            level: .info, category: "WhisperKitWorker"
          )
        }
      }
    }
  }
}
