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

    private(set) var results: [Result] = []
    private(set) var isRunning = false
    private(set) var progress: String = ""

    /// Run benchmarks with the given ASR manager.
    func run(using asrManager: ASRManager) async {
        guard !isRunning else { return }
        isRunning = true
        results = []

        // Ensure model is loaded
        if !asrManager.isModelLoaded {
            progress = "Loading model..."
            do {
                try await asrManager.loadModel()
            } catch {
                progress = "Model load failed: \(error.localizedDescription)"
                isRunning = false
                return
            }
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
}
