@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprAudio
import EnviousWisprASR
import Foundation

/// Measures ASR transcription performance across different audio durations.
@MainActor
@Observable
final class BenchmarkSuite {
    struct Result: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let audioDuration: TimeInterval
        let processingTime: TimeInterval
        /// Real-time factor: how many seconds of audio are processed per second.
        let rtf: Double
        let backend: ASRBackendType
    }

    /// Results from a full pipeline benchmark run.
    struct PipelineBenchmarkResult: Sendable {
        let batchASRTime: TimeInterval
        let batchTranscript: String
        let streamingFinalizeTime: TimeInterval?
        let streamingTranscript: String?
        let werDelta: Double?
        let audioDuration: TimeInterval
        let backend: ASRBackendType
    }

    private(set) var results: [Result] = []
    private(set) var pipelineResult: PipelineBenchmarkResult?
    private(set) var isRunning = false
    private(set) var progress: String = ""

    /// Ensure model is loaded, returning false (and updating progress) if loading fails.
    private func ensureModelLoaded(using asrManager: ASRManager) async -> Bool {
        guard !asrManager.isModelLoaded else { return true }
        progress = "Loading model..."
        do {
            try await asrManager.loadModel()
            return true
        } catch {
            progress = "Model load failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Run ASR benchmarks with the given ASR manager.
    func run(using asrManager: ASRManager) async {
        guard !isRunning else { return }
        isRunning = true
        results = []

        guard await ensureModelLoaded(using: asrManager) else {
            isRunning = false
            return
        }

        let durations: [TimeInterval] = [5, 15, 30]
        let backend = asrManager.activeBackendType

        for duration in durations {
            progress = "Testing \(Int(duration))s audio..."
            let samples = generateTestAudio(duration: duration)

            let start = CFAbsoluteTimeGetCurrent()
            _ = try? await asrManager.transcribe(audioSamples: samples)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            results.append(Result(
                label: "\(Int(duration))s",
                audioDuration: duration,
                processingTime: elapsed,
                rtf: duration / elapsed,
                backend: backend
            ))
        }

        progress = "Complete"
        isRunning = false
    }

    /// Run pipeline benchmark: batch ASR, streaming ASR (if supported), and WER comparison.
    func runPipelineBenchmark(using asrManager: ASRManager) async {
        guard !isRunning else { return }
        isRunning = true
        pipelineResult = nil

        guard await ensureModelLoaded(using: asrManager) else {
            isRunning = false
            return
        }

        let backend = asrManager.activeBackendType

        // Load test audio — try jfk.wav from WhisperKit test resources, fall back to synthetic
        let testAudioDuration: TimeInterval
        let testSamples: [Float]

        // Resolve jfk.wav relative to the bundle: .app is inside the project's build/ dir,
        // so go up two levels (Contents/MacOS → .app → build/) then ../Tests/Resources/
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")
        let projectRoot = executableURL
            .deletingLastPathComponent() // MacOS/
            .deletingLastPathComponent() // Contents/
            .deletingLastPathComponent() // EnviousWispr.app/
            .deletingLastPathComponent() // build/
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
        let batchResult = try? await asrManager.transcribe(audioSamples: testSamples)
        let batchTime = CFAbsoluteTimeGetCurrent() - batchStart
        let batchTranscript = batchResult?.text ?? ""

        // Step 2: Streaming ASR (if supported)
        var streamingFinalizeTime: TimeInterval?
        var streamingTranscript: String?
        var werDelta: Double?

        let supportsStreaming = await asrManager.activeBackendSupportsStreaming
        if supportsStreaming {
            progress = "Running streaming ASR..."
            do {
                try await asrManager.startStreaming()

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
            } catch {
                Task { await AppLogger.shared.log(
                    "Pipeline benchmark: streaming ASR failed: \(error.localizedDescription)",
                    level: .info, category: "Benchmark"
                ) }
            }
        }

        pipelineResult = PipelineBenchmarkResult(
            batchASRTime: batchTime,
            batchTranscript: batchTranscript,
            streamingFinalizeTime: streamingFinalizeTime,
            streamingTranscript: streamingTranscript,
            werDelta: werDelta,
            audioDuration: testAudioDuration,
            backend: backend
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

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AudioError.formatCreationFailed
        }
        try file.read(into: sourceBuffer)

        // Resample if needed
        if sourceFormat.sampleRate == AudioConstants.sampleRate && sourceFormat.channelCount == 1 {
            guard let channelData = sourceBuffer.floatChannelData else {
                throw AudioError.formatCreationFailed
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(sourceBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw AudioError.formatCreationFailed
        }

        let ratio = AudioConstants.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames) else {
            throw AudioError.formatCreationFailed
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
            throw AudioError.formatCreationFailed
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
