@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import EnviousWisprCore
import Foundation

/// CTC vocabulary boosting limb for the Parakeet backend.
///
/// Downloads the CTC model once, stores the vocabulary config, and creates a fresh
/// boosted SlidingWindowAsrManager per rescore to avoid state contamination.
/// Shares primary AsrModels with the heart manager (reference copy, not recompilation).
///
/// This is a LIMB: it may fail, time out, or be unavailable without affecting
/// the heart path. Callers should always have the heart result ready as fallback.
public actor ParakeetVocabularyBoostingLimb {

    // MARK: - State

    public enum State: Sendable {
        case idle
        case preparing(contentHash: String)
        case ready(contentHash: String)
        case failed(message: String)
    }

    public private(set) var state: State = .idle

    // MARK: - Resources

    private var loadedCtcModels: CtcModels?
    private var storedVocabulary: CustomVocabularyContext?
    private var storedPrimaryModels: AsrModels?
    private var preparationTask: Task<Void, any Error>?
    private var preparationGeneration: Int = 0

    public init() {}

    // MARK: - Preparation

    /// Fire-and-forget: spawns background preparation task.
    /// Downloads CTC model if needed, tokenizes vocabulary, validates config.
    /// Safe to call multiple times; no-ops if already ready with same config.
    public func requestPreparation(
        config: VocabularyBoostingConfig,
        primaryModels: AsrModels
    ) {
        guard !config.terms.isEmpty else {
            clear()
            return
        }

        let newHash = config.contentHash

        // Already ready with same config
        if case .ready(let hash) = state, hash == newHash {
            self.storedPrimaryModels = primaryModels
            return
        }

        // Already preparing for same config (don't cancel and restart)
        if case .preparing(let hash) = state, hash == newHash {
            self.storedPrimaryModels = primaryModels
            return
        }

        // Cancel any in-flight preparation for a different config
        preparationTask?.cancel()
        preparationGeneration += 1
        let generation = preparationGeneration

        self.storedPrimaryModels = primaryModels
        state = .preparing(contentHash: newHash)

        preparationTask = Task {
            do {
                try Task.checkCancellation()

                // Download CTC models if not cached (~64MB, one-time)
                let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)

                try Task.checkCancellation()

                // Build vocabulary context with FluidVoice-derived thresholds
                let terms = config.terms.map { term in
                    CustomVocabularyTerm(
                        text: term.canonical,
                        aliases: term.aliases.isEmpty ? nil : term.aliases
                    )
                }
                let vocabulary = CustomVocabularyContext(
                    terms: terms,
                    alpha: 2.8,
                    minCtcScore: -2.2,
                    minSimilarity: 0.72,
                    minCombinedConfidence: 0.64
                )

                try Task.checkCancellation()

                // Generation check: only commit if we're still the current preparation
                guard self.isCurrentGeneration(generation) else { return }

                self.loadedCtcModels = models
                self.storedVocabulary = vocabulary
                self.state = .ready(contentHash: newHash)

                Task { await AppLogger.shared.log(
                    "CTC vocabulary boosting ready (\(config.terms.count) terms, hash: \(newHash))",
                    level: .info, category: "CTC"
                ) }
            } catch is CancellationError {
                // Superseded by newer preparation; silently discard
            } catch {
                guard self.isCurrentGeneration(generation) else { return }
                self.state = .failed(message: error.localizedDescription)
                Task { await AppLogger.shared.log(
                    "CTC vocabulary boosting preparation failed: \(error.localizedDescription)",
                    level: .info, category: "CTC"
                ) }
            }
        }
    }

    /// Clear vocabulary configuration and free CTC resources.
    public func clear() {
        preparationTask?.cancel()
        preparationTask = nil
        preparationGeneration += 1  // Invalidate any in-flight task past its last checkCancellation
        loadedCtcModels = nil
        storedVocabulary = nil
        state = .idle
    }

    // MARK: - Rescore

    /// Re-transcribe audio through a CTC-boosted SlidingWindowAsrManager.
    /// Creates a fresh manager per call to avoid decoder state contamination.
    /// Returns nil if not ready or on any failure (limb pattern: silent fallback).
    public func rescore(audioSamples: [Float], language: String) async -> String? {
        guard case .ready = state else { return nil }
        guard let models = storedPrimaryModels,
              let ctcModels = loadedCtcModels,
              let vocabulary = storedVocabulary else { return nil }

        let rescoreStart = CFAbsoluteTimeGetCurrent()

        do {
            // Fresh manager per rescore: no state contamination between utterances.
            // Configure vocabulary BEFORE start to match FluidAudio's documented lifecycle.
            let config = SlidingWindowAsrConfig.streaming
            let manager = SlidingWindowAsrManager(config: config)
            try await manager.configureVocabularyBoosting(
                vocabulary: vocabulary,
                ctcModels: ctcModels
            )
            try await manager.start(models: models, source: .microphone)

            // Feed all audio as a single buffer for batch-final transcription
            guard let buffer = Self.samplesToBuffer(audioSamples) else { return nil }
            nonisolated(unsafe) let unsafeBuffer = buffer
            await manager.streamAudio(unsafeBuffer)

            let text = try await manager.finish()
            let elapsed = CFAbsoluteTimeGetCurrent() - rescoreStart

            Task { await AppLogger.shared.log(
                "CTC rescore completed in \(String(format: "%.3f", elapsed))s: \(text.prefix(80))...",
                level: .info, category: "CTC"
            ) }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            Task { await AppLogger.shared.log(
                "CTC rescore failed (limb, non-fatal): \(error.localizedDescription)",
                level: .info, category: "CTC"
            ) }
            return nil
        }
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Private

    private func isCurrentGeneration(_ gen: Int) -> Bool {
        gen == preparationGeneration
    }

    /// Convert Float32 samples to AVAudioPCMBuffer for SlidingWindowAsrManager.
    private static func samplesToBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
