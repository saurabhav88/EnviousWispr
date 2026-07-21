@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Measures ASR transcription performance across different audio durations.
@MainActor
@Observable
final class BenchmarkSuite {
  struct Result: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let processingTime: TimeInterval
    /// Real-time factor: how many seconds of audio are processed per second.
    let rtf: Double
  }

  /// Results from a full pipeline benchmark run.
  struct PipelineBenchmarkResult: Sendable {
    let batchASRTime: TimeInterval
    let streamingFinalizeTime: TimeInterval?
    let werDelta: Double?
    let audioDuration: TimeInterval
  }

  private(set) var results: [Result] = []
  private(set) var pipelineResult: PipelineBenchmarkResult?
  private(set) var isRunning = false
  private(set) var progress: String = ""

  /// #1707 Phase 3 (§3.2, rows 23/27) — `EngineRecoveryGate.tryBeginMutation()`/
  /// `endMutation()`, injected by the composition root (this type never
  /// references `EngineRecoveryGate` by concrete type). A Diagnostics-
  /// triggered benchmark must never race crash recovery on the shared
  /// engine. Defaults keep every existing test/legacy construction unchanged
  /// (always able to proceed).
  var tryBeginEngineMutation: @MainActor () -> Bool = { true }
  /// Returns whether recovery was denied while this mutation was in flight
  /// and is now owed a wake-up.
  var endEngineMutation: @MainActor () -> Bool = { false }
  /// Called when `endEngineMutation()` returns true — wakes a stranded
  /// recovery attempt. Bound to `RecoveryCoordinator.requestRecoveryRecheck`.
  var wakeRecoveryIfOwed: @MainActor () -> Void = {}

  /// Ensure model is loaded, returning false (and updating progress) if loading fails.
  private func ensureModelLoaded(using activeEngine: ActiveEngineOperation) async -> Bool {
    guard !(await activeEngine.isLoaded()) else { return true }
    progress = "Loading model..."
    do {
      try await activeEngine.load()
      return true
    } catch {
      progress = "Model load failed: \(error.localizedDescription)"
      return false
    }
  }

  /// Run ASR benchmarks with the given ASR manager.
  func run(using asrManager: any ASRManagerInterface, activeEngine: ActiveEngineOperation) async {
    guard !isRunning else { return }
    isRunning = true
    results = []

    // #1707 Phase 3 (§3.2, row 23): hold a mutation claim for the FULL
    // load+transcribe duration — a Diagnostics-triggered benchmark must
    // never race crash recovery on the shared engine.
    guard tryBeginEngineMutation() else {
      TelemetryService.shared.recoveryEngineActionDeferred(site: "benchmarkSuiteBatch")
      isRunning = false
      return
    }
    defer {
      if endEngineMutation() { wakeRecoveryIfOwed() }
    }

    guard await ensureModelLoaded(using: activeEngine) else {
      isRunning = false
      return
    }

    let durations: [TimeInterval] = [5, 15, 30]

    for duration in durations {
      progress = "Testing \(Int(duration))s audio..."
      let samples = generateTestAudio(duration: duration)

      let start = CFAbsoluteTimeGetCurrent()
      _ = try? await activeEngine.transcribe(samples, .default)
      let elapsed = CFAbsoluteTimeGetCurrent() - start

      results.append(
        Result(
          label: "\(Int(duration))s",
          processingTime: elapsed,
          rtf: duration / elapsed
        ))
    }

    progress = "Complete"
    isRunning = false
  }

  /// Run pipeline benchmark: batch ASR, streaming ASR (if supported), and WER comparison.
  func runPipelineBenchmark(
    using asrManager: any ASRManagerInterface, activeEngine: ActiveEngineOperation
  ) async {
    guard !isRunning else { return }
    isRunning = true
    pipelineResult = nil

    // #1707 Phase 3 (§3.2, row 23): hold a mutation claim for the FULL
    // load+batch-transcribe duration below — released before the separate
    // streaming portion (row 27) claims its own, since they are genuinely
    // distinct engine-touching surfaces, not one operation.
    guard tryBeginEngineMutation() else {
      TelemetryService.shared.recoveryEngineActionDeferred(site: "benchmarkSuiteBatch")
      isRunning = false
      return
    }
    var batchClaimReleased = false
    let releaseBatchClaim = {
      guard !batchClaimReleased else { return }
      batchClaimReleased = true
      if self.endEngineMutation() { self.wakeRecoveryIfOwed() }
    }
    defer { releaseBatchClaim() }

    guard await ensureModelLoaded(using: activeEngine) else {
      isRunning = false
      return
    }

    // Load test audio — try jfk.wav from WhisperKit test resources, fall back to synthetic
    let testAudioDuration: TimeInterval
    let testSamples: [Float]

    // Resolve jfk.wav relative to the bundle: .app is inside the project's build/ dir,
    // so go up two levels (Contents/MacOS → .app → build/) then ../Tests/Resources/
    let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")
    let projectRoot =
      executableURL
      .deletingLastPathComponent()  // MacOS/
      .deletingLastPathComponent()  // Contents/
      .deletingLastPathComponent()  // EnviousWispr.app/
      .deletingLastPathComponent()  // build/
    let jfkURL = projectRoot.appendingPathComponent("Tests/Resources/jfk.wav")
    if FileManager.default.fileExists(atPath: jfkURL.path) {
      progress = "Loading test audio..."
      do {
        testSamples = try loadAudioFile(url: jfkURL)
        testAudioDuration = Double(testSamples.count) / AudioConstants.sampleRate
      } catch {
        progress = "Failed to load test audio: \(error.localizedDescription)"
        isRunning = false
        return
      }
    } else {
      testAudioDuration = 15.0
      testSamples = generateTestAudio(duration: testAudioDuration)
    }

    // Step 1: Batch ASR
    progress = "Running batch ASR..."
    let batchStart = CFAbsoluteTimeGetCurrent()
    let batchResult = try? await activeEngine.transcribe(testSamples, .default)
    let batchTime = CFAbsoluteTimeGetCurrent() - batchStart
    let batchTranscript = batchResult?.text ?? ""
    // Row 23's claim covers only the batch work above — release it now,
    // before row 27's genuinely separate streaming surface claims its own.
    releaseBatchClaim()

    // Step 2: Streaming ASR (if supported)
    var streamingFinalizeTime: TimeInterval?
    var streamingTranscript: String?
    var werDelta: Double?

    let supportsStreaming = await asrManager.activeBackendSupportsStreaming
    if supportsStreaming {
      progress = "Running streaming ASR..."
      // #1707 Phase 3 (§3.2, row 27): hold a mutation claim for the whole
      // start/feed/finalize sequence below. Round 3 correction: releasing
      // the claim is NOT simply "on completion or abort" — `finalizeStreaming()`
      // only clears streaming state after a SUCCESSFUL awaited finalize, so
      // any throw below must first `await asrManager.cancelStreaming()`
      // WHILE the claim is still held, and release only after that
      // cancellation completes (or after a successful finalize) — never on
      // the bare throw alone, or the claim would say "safe" while the
      // backend's streaming session is still actually active underneath.
      guard tryBeginEngineMutation() else {
        TelemetryService.shared.recoveryEngineActionDeferred(site: "benchmarkSuiteStreaming")
        progress = "Pipeline benchmark complete"
        isRunning = false
        pipelineResult = PipelineBenchmarkResult(
          batchASRTime: batchTime, streamingFinalizeTime: nil, werDelta: nil,
          audioDuration: testAudioDuration)
        return
      }
      var streamingClaimReleased = false
      let releaseStreamingClaim = {
        guard !streamingClaimReleased else { return }
        streamingClaimReleased = true
        if self.endEngineMutation() { self.wakeRecoveryIfOwed() }
      }
      var startedStreaming = false
      do {
        try await asrManager.startStreaming(options: .default)
        startedStreaming = true

        // Chunk the samples into AVAudioPCMBuffers and feed them
        let chunkSize = AudioConstants.captureBufferSize
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: AudioConstants.sampleRate,
          channels: AVAudioChannelCount(AudioConstants.channels),
          interleaved: false
        )!

        var offset = 0
        while offset < testSamples.count {
          let remaining = testSamples.count - offset
          let count = min(chunkSize, remaining)
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
          buffer.frameLength = AVAudioFrameCount(count)
          if let channelData = buffer.floatChannelData {
            testSamples.withUnsafeBufferPointer { ptr in
              channelData[0].update(from: ptr.baseAddress! + offset, count: count)
            }
          }
          try await asrManager.feedAudio(buffer)
          offset += count
        }

        let finalizeStart = CFAbsoluteTimeGetCurrent()
        let streamResult = try await asrManager.finalizeStreaming()
        streamingFinalizeTime = CFAbsoluteTimeGetCurrent() - finalizeStart
        streamingTranscript = streamResult.text

        // WER comparison (if both transcripts have content)
        if !batchTranscript.isEmpty, let streaming = streamingTranscript, !streaming.isEmpty {
          let werResult = WERCalculator.calculate(reference: batchTranscript, hypothesis: streaming)
          werDelta = werResult.wer
        }
        // Successful finalize — the backend's streaming session has
        // genuinely ended; safe to release now.
        releaseStreamingClaim()
      } catch {
        // #1707 Phase 3 (§3.2, row 27 fix): `feed`/`finalize` throwing means
        // the streaming session may still be genuinely active underneath —
        // await the real cancellation WHILE the claim is still held, so
        // recovery cannot acquire until the backend has actually stopped,
        // not merely until this throw is caught. `startStreaming()` itself
        // throwing means there is no active session to cancel.
        if startedStreaming {
          await asrManager.cancelStreaming()
        }
        releaseStreamingClaim()
        Task {
          await AppLogger.shared.log(
            "Pipeline benchmark: streaming ASR failed: \(error.localizedDescription)",
            level: .info, category: "Benchmark"
          )
        }
      }
    }

    pipelineResult = PipelineBenchmarkResult(
      batchASRTime: batchTime,
      streamingFinalizeTime: streamingFinalizeTime,
      werDelta: werDelta,
      audioDuration: testAudioDuration
    )

    progress = "Pipeline benchmark complete"
    isRunning = false
  }

  // MARK: - Audio Helpers

  /// Generate synthetic test audio (440Hz sine wave at 16kHz mono).
  private func generateTestAudio(duration: TimeInterval) -> [Float] {
    let sampleRate = 16000
    let count = Int(duration * Double(sampleRate))
    var samples = [Float](repeating: 0, count: count)
    let frequency: Float = 440.0
    let amplitude: Float = 0.3
    for i in 0..<count {
      samples[i] = amplitude * sin(Float(i) * 2.0 * .pi * frequency / Float(sampleRate))
    }
    return samples
  }

  /// Load and resample an audio file to 16kHz mono Float32.
  private func loadAudioFile(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: AudioConstants.sampleRate,
      channels: 1,
      interleaved: false
    )!

    let sourceFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)

    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
    else {
      throw AudioError.formatCreationFailed(source: "BenchmarkSuite.loadAudioFile.source_buffer")
    }
    try file.read(into: sourceBuffer)

    // Resample if needed
    if sourceFormat.sampleRate == AudioConstants.sampleRate && sourceFormat.channelCount == 1 {
      guard let channelData = sourceBuffer.floatChannelData else {
        throw AudioError.formatCreationFailed(
          source: "BenchmarkSuite.loadAudioFile.source_channel_data")
      }
      return Array(UnsafeBufferPointer(start: channelData[0], count: Int(sourceBuffer.frameLength)))
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
      throw AudioError.formatCreationFailed(source: "BenchmarkSuite.loadAudioFile.converter")
    }

    let ratio = AudioConstants.sampleRate / sourceFormat.sampleRate
    let outputFrames = AVAudioFrameCount(Double(frameCount) * ratio)
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames) else {
      throw AudioError.formatCreationFailed(source: "BenchmarkSuite.loadAudioFile.output_buffer")
    }

    var error: NSError?
    // AVAudioConverter input callback is invoked synchronously — not concurrent.
    // nonisolated(unsafe) suppresses the false-positive Swift 6 Sendable warning.
    nonisolated(unsafe) var consumed = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }

    guard error == nil, let channelData = outputBuffer.floatChannelData else {
      throw AudioError.formatCreationFailed(
        source: "BenchmarkSuite.loadAudioFile.output_channel_data")
    }

    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
  }
}
