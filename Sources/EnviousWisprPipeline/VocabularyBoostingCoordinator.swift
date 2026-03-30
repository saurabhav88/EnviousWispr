import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import os.log

private let ctcLog = Logger(subsystem: "com.enviouswispr", category: "CTC-Coordinator")

/// Minimal Phase 2A coordinator for CTC vocabulary boosting.
///
/// Syncs custom vocabulary to the XPC service and schedules post-heart CTC rescores.
/// Pipeline calls two methods: `syncVocabularyIfNeeded()` and `rescoreIfEligible(...)`.
@MainActor
public final class VocabularyBoostingCoordinator {
    private let asrProxy: ASRManagerProxy
    private let customWordsManager = CustomWordsManager()
    private var lastSyncedRevision: Int = 0
    private var vocabRevision: Int = 0
    private var currentUtteranceID: UUID?

    /// Track whether we have a non-empty vocabulary configured.
    private var hasActiveVocabulary: Bool = false

    public init(asrProxy: ASRManagerProxy) {
        self.asrProxy = asrProxy
    }

    // MARK: - Vocabulary Sync

    /// Call on PTT press or model ready. Fire-and-forget.
    /// Reads custom words, converts to DTO, sends prep request if changed.
    public func syncVocabularyIfNeeded() {
        DebugTrace.log("syncVocabularyIfNeeded enter")
        guard asrProxy.isModelLoaded else {
            DebugTrace.log("syncVocab: exit, model not loaded")
            return
        }
        guard asrProxy.activeBackendType == .parakeet else {
            DebugTrace.log("syncVocab: exit, backend=\(asrProxy.activeBackendType.rawValue)")
            return
        }

        let words = customWordsManager.load() ?? []
        DebugTrace.log("syncVocab: loaded \(words.count) words")
        let config = buildConfig(from: words)

        if config.terms.isEmpty {
            if hasActiveVocabulary {
                DebugTrace.log("syncVocab: vocab empty, clearing")
                asrProxy.clearVocabularyBoosting()
                hasActiveVocabulary = false
            }
            return
        }

        // Check if revision changed
        if config.revision == lastSyncedRevision {
            DebugTrace.log("syncVocab: same revision \(config.revision), skipping")
            return
        }

        DebugTrace.log("syncVocab: sending prep, \(config.terms.count) terms, rev=\(config.revision)")
        asrProxy.requestVocabularyBoostingPreparation(config)
        lastSyncedRevision = config.revision
        hasActiveVocabulary = true
    }

    // MARK: - Utterance Tracking

    /// Call when starting a new utterance. Returns the utterance ID.
    public func beginUtterance() -> UUID {
        let id = UUID()
        currentUtteranceID = id
        return id
    }

    /// Call on cancellation/teardown.
    public func cancelCurrentUtterance() {
        currentUtteranceID = nil
    }

    // MARK: - Rescore

    /// Call after heart result is pasted. Attempts CTC rescore.
    /// Returns improved result or nil (timeout, not ready, not applicable).
    public func rescoreIfEligible(
        utteranceID: UUID,
        audioSamples: [Float],
        baseResult: ASRResult,
        language: String,
        timeout: Duration = .milliseconds(1500)
    ) async -> ASRResult? {
        // Gate checks
        DebugTrace.log("rescoreIfEligible enter")
        guard hasActiveVocabulary else {
            DebugTrace.log("rescore: exit, no active vocabulary")
            return nil
        }
        guard asrProxy.activeBackendType == .parakeet else {
            DebugTrace.log("rescore: exit, not parakeet")
            return nil
        }
        guard utteranceID == currentUtteranceID else {
            DebugTrace.log("rescore: exit, stale utterance")
            return nil
        }

        let audioDuration = Double(audioSamples.count) / 16000.0
        guard audioDuration >= 0.3 else {
            DebugTrace.log("rescore: exit, audio too short (\(String(format: "%.1f", audioDuration))s)")
            return nil
        }

        DebugTrace.log("rescore: attempting CTC rescore (\(String(format: "%.1f", audioDuration))s audio)")

        do {
            let result = try await withThrowingTaskGroup(of: ASRResult.self) { group in
                group.addTask {
                    try await self.asrProxy.rescoreWithVocabulary(
                        audioSamples: audioSamples,
                        language: language
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }

                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            // Validate utterance still current
            guard utteranceID == currentUtteranceID else {
                ctcLog.notice("Rescore result discarded: utterance changed during rescore")
                return nil
            }

            // Check if result is meaningfully different
            if result.text == baseResult.text {
                DebugTrace.log("rescore: text unchanged")
                return nil
            }

            DebugTrace.log("rescore: improved text: \"\(result.text.prefix(80))\"")
            return result

        } catch {
            let errorDesc = (error as? ASRError)?.errorDescription ?? error.localizedDescription
            DebugTrace.log("rescore: failed/timed out: \(errorDesc)")
            return nil
        }
    }

    // MARK: - Config Building

    private func buildConfig(from words: [CustomWord]) -> VocabularyBoostingConfig {
        let terms = words.map { word in
            VocabularyBoostingConfig.VocabularyBoostingTerm(
                canonical: word.canonical,
                aliases: word.aliases
            )
        }

        // Revision: use a hash-based approach so it changes when content changes
        vocabRevision += 1

        return VocabularyBoostingConfig(terms: terms, revision: vocabRevision)
    }
}
