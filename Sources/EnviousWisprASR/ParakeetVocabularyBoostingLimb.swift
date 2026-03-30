import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation

// Use our own ASRResult, not FluidAudio's.
typealias CTCASRResult = EnviousWisprCore.ASRResult

/// CTC vocabulary boosting limb for the Parakeet backend.
///
/// Owns a dedicated `AsrManager` configured with CTC vocabulary boosting,
/// separate from the heart-path batch manager. All operations on the CTC
/// manager are serialized through `AsrManagerMutex` to prevent reentrancy
/// (AsrManager is a class, not an actor).
///
/// State machine:
/// - `.idle` -> `.preparing` (on requestPreparation with non-empty terms)
/// - `.preparing` -> `.ready` (on successful download + tokenize + configure)
/// - `.preparing` -> `.failed` (on error)
/// - `.ready` -> `.preparing` (on new config with different key)
/// - Any -> `.idle` (on clear)
actor ParakeetVocabularyBoostingLimb {

    // MARK: - State

    enum State: Sendable {
        case idle
        case preparing(revision: Int, task: Task<Void, any Error>)
        case ready(key: VocabularyConfigurationKey)
        case failed(revision: Int, error: String, retryAfter: Date?)
    }

    /// Bundled CTC resources: models + tokenizer, invalidated together.
    struct CtcResources: Sendable {
        let models: CtcModels
        let tokenizer: CtcTokenizer
    }

    private var state: State = .idle
    private var ctcResources: CtcResources?
    private var ctcAsrManager: AsrManager?
    private let mutex = AsrManagerMutex()

    /// Monotonically increasing counter to detect superseded preparation tasks.
    private var preparationGeneration: Int = 0

    private static let backendModelID = "parakeet-tdt-v3"

    // MARK: - Public API

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Fire-and-forget: spawns background preparation task.
    /// Returns immediately. Does not throw.
    func requestPreparation(
        config: VocabularyBoostingConfig,
        primaryModels: AsrModels
    ) {
        guard !config.terms.isEmpty else {
            clear()
            return
        }

        let targetKey = VocabularyConfigurationKey.from(
            config: config,
            backendModelID: Self.backendModelID
        )

        // No-op if already ready or preparing with same key
        switch state {
        case .ready(let currentKey) where currentKey == targetKey:
            return
        case .preparing(let rev, _) where rev == config.revision:
            // Same revision already preparing. Check if key would match.
            // Since we can't compute the key cheaply in preparing state,
            // let it continue. Worst case: redundant prep that no-ops on completion.
            return
        default:
            break
        }

        // Cancel any in-flight preparation
        if case .preparing(_, let task) = state {
            task.cancel()
        }

        preparationGeneration += 1
        let generation = preparationGeneration
        let terms = config.terms

        let task = Task<Void, any Error> { [weak self] in
            guard let self else { return }

            do {
                // Step 1: Download/load CTC models if not cached
                let resources = try await self.ensureCtcResources()
                try Task.checkCancellation()

                // Step 2: Tokenize all terms
                let tokenizedTerms = Self.tokenizeTerms(terms, tokenizer: resources.tokenizer)
                try Task.checkCancellation()

                // Step 3: Build CustomVocabularyContext
                let vocab = CustomVocabularyContext(terms: tokenizedTerms)
                try Task.checkCancellation()

                // Step 4: Create or reuse AsrManager, configure CTC
                try await self.configureCtcManager(
                    primaryModels: primaryModels,
                    vocabulary: vocab,
                    ctcModels: resources.models,
                    generation: generation,
                    targetKey: targetKey
                )
            } catch is CancellationError {
                // Cancelled by newer request, don't update state
                return
            } catch {
                await self.handlePreparationFailure(
                    generation: generation,
                    revision: config.revision,
                    error: error
                )
            }
        }

        state = .preparing(revision: config.revision, task: task)
    }

    /// Clear all CTC state and free resources.
    func clear() {
        if case .preparing(_, let task) = state {
            task.cancel()
        }
        ctcAsrManager?.cleanup()
        ctcAsrManager = nil
        // Keep ctcResources cached (models + tokenizer are expensive to reload).
        // They'll be reused if vocab is re-configured.
        state = .idle
    }

    /// Rescore audio samples using CTC-configured manager.
    /// Fails fast if not in `.ready` state.
    func rescore(
        audioSamples: [Float],
        language: String
    ) async throws -> CTCASRResult {
        guard case .ready = state else {
            if case .preparing = state {
                throw ASRError.vocabularyBoostingNotReady
            }
            throw ASRError.vocabularyBoostingNotConfigured
        }

        guard let manager = ctcAsrManager else {
            throw ASRError.vocabularyBoostingNotConfigured
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let fluidResult = try await mutex.run { [manager] in
            try await manager.transcribe(audioSamples, source: .microphone)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return CTCASRResult(
            text: fluidResult.text,
            language: language,
            duration: fluidResult.duration,
            processingTime: elapsed,
            backendType: .parakeet
        )
    }

    // MARK: - Internal

    /// Ensure CTC models and tokenizer are loaded. Caches across preparations.
    private func ensureCtcResources() async throws -> CtcResources {
        if let existing = ctcResources {
            return existing
        }

        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: .ctc110m)
        )

        let resources = CtcResources(models: models, tokenizer: tokenizer)
        ctcResources = resources
        return resources
    }

    /// Tokenize vocabulary terms for CTC. Terms with empty token IDs are skipped.
    private static func tokenizeTerms(
        _ terms: [VocabularyBoostingConfig.VocabularyBoostingTerm],
        tokenizer: CtcTokenizer
    ) -> [CustomVocabularyTerm] {
        terms.compactMap { term -> CustomVocabularyTerm? in
            let canonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return nil }

            let ctcTokenIds = tokenizer.encode(canonical)
            guard !ctcTokenIds.isEmpty else { return nil }

            let aliases = term.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return CustomVocabularyTerm(
                text: canonical,
                aliases: aliases.isEmpty ? nil : aliases,
                ctcTokenIds: ctcTokenIds
            )
        }
    }

    /// Configure the CTC AsrManager. Verifies generation before committing.
    private func configureCtcManager(
        primaryModels: AsrModels,
        vocabulary: CustomVocabularyContext,
        ctcModels: CtcModels,
        generation: Int,
        targetKey: VocabularyConfigurationKey
    ) async throws {
        // Create manager if needed (initialize is cheap: just property assignments)
        if ctcAsrManager == nil {
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: primaryModels)
            ctcAsrManager = manager
        }

        guard let manager = ctcAsrManager else { return }

        // Configure CTC through mutex (serialized with any in-flight rescore)
        try await mutex.run { [manager] in
            try await manager.configureVocabularyBoosting(
                vocabulary: vocabulary,
                ctcModels: ctcModels
            )
        }

        // Generation check: only commit if we're still the current request
        guard generation == preparationGeneration else { return }

        state = .ready(key: targetKey)
    }

    /// Handle preparation failure with state update.
    private func handlePreparationFailure(
        generation: Int,
        revision: Int,
        error: any Error
    ) {
        // Only update state if this is still the current generation
        guard generation == preparationGeneration else { return }

        let retryAfter = Date().addingTimeInterval(30) // 30s backoff
        state = .failed(
            revision: revision,
            error: String(describing: error),
            retryAfter: retryAfter
        )
    }
}
