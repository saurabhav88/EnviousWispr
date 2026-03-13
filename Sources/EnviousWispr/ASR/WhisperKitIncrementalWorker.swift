import Foundation
import EnviousWisprCore
@preconcurrency import WhisperKit

struct IncrementalResult: Sendable {
    let text: String?
    let samplesCovered: Int
    let decodeCount: Int
    let totalDecodeTimeMs: Int
    let accepted: Bool
    let mode: String
    let strategy: String
    let tailDecodeMs: Int
}

/// Periodically transcribes the growing audio buffer during recording.
/// Purely an internal latency optimization — no UI, no streaming model.
///
/// Adaptive strategy:
/// - Short recordings (<30s): re-transcribe full buffer each cycle (highest quality)
/// - Long recordings (>30s): use clipTimestamps to only decode new audio (efficient)
/// - On finalize: async tail decode covers speech after the last worker result
actor WhisperKitIncrementalWorker {
    private let whisperKit: WhisperKit
    private let baseDecodingOptions: DecodingOptions
    private let tokenizer: (any WhisperTokenizer)?
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

    init(whisperKit: WhisperKit, decodingOptions: DecodingOptions, tokenizer: (any WhisperTokenizer)?) {
        self.whisperKit = whisperKit
        self.baseDecodingOptions = decodingOptions
        self.tokenizer = tokenizer
    }

    func start(audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)) {
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

    func finalize(
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
        let hasText = candidateText != nil
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
        let tailHasSpeech = speechSegments.contains { $0.endSample > lastResultSampleCount }

        if !tailHasSpeech {
            return IncrementalResult(
                text: candidateText, samplesCovered: lastResultSampleCount,
                decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
                accepted: true, mode: baseMode,
                strategy: "worker_only", tailDecodeMs: 0
            )
        }

        // Tail has speech — async tail decode with silence padding
        let paddedSamples = WhisperKitBackend.padAudioWithSilence(finalSamples)
        let tailStart = CFAbsoluteTimeGetCurrent()
        do {
            let overlapStartSeconds = max(0, Float(lastResultSampleCount) / 16000.0 - 1.0)
            var opts = baseDecodingOptions
            opts.clipTimestamps = [overlapStartSeconds]
            opts.windowClipTime = 0

            if let tokenizer {
                let suffix = String(candidateText!.suffix(200))
                let allTokens = tokenizer.encode(text: " " + suffix.trimmingCharacters(in: .whitespaces))
                opts.promptTokens = allTokens.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }

            let results = try await whisperKit.transcribe(audioArray: paddedSamples, decodeOptions: opts)
            let tailText = results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)

            let finalText: String
            if tailText.isEmpty {
                finalText = candidateText!
            } else {
                finalText = candidateText! + " " + tailText
            }

            return IncrementalResult(
                text: finalText, samplesCovered: finalSamples.count,
                decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
                accepted: true, mode: baseMode + "+tail",
                strategy: "worker+tail", tailDecodeMs: tailMs
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

    func cancel() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Private

    private func runLoop(audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)) async {
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
                    "WhisperKit incremental decode #\(decodeCount): \(elapsedMs)ms, " +
                    "mode=\(isLongRecording ? "clipped" : "full"), " +
                    "samples=\(snapshot.count)",
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
