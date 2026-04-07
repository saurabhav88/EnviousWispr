import Foundation
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprStorage
import EnviousWisprServices

/// Standalone service for re-polishing saved transcripts.
///
/// Completely decoupled from dictation pipelines. Owns its own LLMPolishStep
/// (synced via PipelineSettingsSync) and manages its own state. Does not touch
/// pipeline state machines, overlay intents, or live-dictation error tracking.
///
/// This is a limb of a limb: if it fails, dictation is unaffected. If it succeeds,
/// the user sees polished text in the transcript detail view.
@MainActor
@Observable
public final class TranscriptPolishService {

    // MARK: - Public State

    /// ID of the transcript currently being enhanced, or nil if idle.
    public private(set) var polishingTranscriptID: Transcript.ID?

    /// Last enhancement error, scoped to a transcript ID.
    /// Cleared when a new enhancement starts or succeeds.
    public private(set) var lastEnhancementError: EnhancementError?

    // MARK: - Config Target

    /// LLM configuration target for PipelineSettingsSync.
    /// Mutable properties are synced by the settings system.
    /// At call time, config is snapshotted into an immutable value for request safety.
    public let llmPolishStep: LLMPolishStep

    // MARK: - Private

    private let transcriptStore: TranscriptStore
    private weak var dictationActivity: DictationActivityProviding?

    // MARK: - Init

    public init(
        keychainManager: KeychainManager,
        transcriptStore: TranscriptStore,
        dictationActivity: DictationActivityProviding? = nil
    ) {
        self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)
        self.transcriptStore = transcriptStore
        self.dictationActivity = dictationActivity
        // Standalone: no pipeline callbacks needed.
        self.llmPolishStep.onWillProcess = nil
        self.llmPolishStep.onToken = nil
    }

    /// Set the dictation activity provider after init (when AppState conforms post-init).
    public func setDictationActivity(_ provider: DictationActivityProviding) {
        self.dictationActivity = provider
    }

    // MARK: - Public API

    /// Enhance a saved transcript with LLM polish. Returns the updated transcript.
    ///
    /// Guards:
    /// - LLM must be enabled
    /// - Cannot enhance while another enhancement is in flight
    /// - Cannot enhance while live dictation is active
    ///
    /// The LLM config is snapshotted at call start. Mid-flight settings changes
    /// do not affect the in-progress request.
    public func polish(_ transcript: Transcript) async throws -> Transcript {
        guard llmPolishStep.isEnabled else {
            throw LLMError.providerUnavailable
        }
        guard polishingTranscriptID == nil else {
            throw LLMError.requestFailed("Enhancement already in progress")
        }
        // Fail closed: if dictation activity provider is gone, refuse to polish
        guard let activity = dictationActivity else {
            throw LLMError.requestFailed("Enhancement service not properly initialized")
        }
        if activity.isDictationActive {
            throw LLMError.requestFailed("Cannot enhance while recording")
        }

        // Snapshot config before starting (immutable for this request)
        let provider = llmPolishStep.llmProvider
        let model = llmPolishStep.llmModel

        polishingTranscriptID = transcript.id
        lastEnhancementError = nil

        defer { polishingTranscriptID = nil }

        SentryBreadcrumb.add(stage: "enhancement", message: "Transcript enhancement requested", data: [
            "transcript_id": transcript.id.uuidString,
            "origin_backend": transcript.backendType.rawValue,
            "provider": provider.rawValue,
            "model": model,
        ])

        // Run the LLM polish step
        let polishedText: String
        do {
            var context = TextProcessingContext(
                text: transcript.text,
                language: transcript.language
            )
            context = try await llmPolishStep.process(context)
            polishedText = context.polishedText ?? context.text
        } catch {
            recordError(for: transcript.id, message: error.localizedDescription)
            Task { await AppLogger.shared.log(
                "Transcript enhancement failed: \(error.localizedDescription)",
                level: .info, category: "Enhancement"
            ) }
            throw error
        }

        // Check for cancellation after LLM work completes
        try Task.checkCancellation()

        // Validate: don't save empty or identical text
        if polishedText.isEmpty {
            recordError(for: transcript.id, message: "Enhancement returned empty text")
            throw LLMError.emptyResponse
        }

        // Build updated transcript
        let updated = Transcript(
            id: transcript.id,
            text: transcript.text,
            polishedText: polishedText,
            language: transcript.language,
            duration: transcript.duration,
            processingTime: transcript.processingTime,
            backendType: transcript.backendType,
            createdAt: transcript.createdAt,
            llmProvider: provider.rawValue,
            llmModel: model,
            metrics: transcript.metrics
        )

        // Verify transcript wasn't deleted during enhancement (prevents resurrection)
        let existsOnDisk: Bool
        do {
            let allTranscripts = try await transcriptStore.loadAll()
            existsOnDisk = allTranscripts.contains(where: { $0.id == transcript.id })
        } catch {
            existsOnDisk = false
        }
        guard existsOnDisk else {
            recordError(for: transcript.id, message: "Transcript was deleted during enhancement")
            throw LLMError.requestFailed("Transcript was deleted during enhancement")
        }

        // Persist
        do {
            try transcriptStore.save(updated)
        } catch {
            recordError(for: transcript.id, message: "Failed to save: \(error.localizedDescription)")
            Task { await AppLogger.shared.log(
                "Failed to save enhanced transcript: \(error)",
                level: .info, category: "Enhancement"
            ) }
            throw LLMError.requestFailed("Failed to save enhanced transcript")
        }

        Task { await AppLogger.shared.log(
            "Transcript enhanced successfully (provider=\(provider.rawValue), model=\(model))",
            level: .info, category: "Enhancement"
        ) }

        return updated
    }

    /// Clear enhancement state. The in-flight LLM call will check Task.checkCancellation()
    /// and exit without saving if the parent Task was cancelled.
    public func cancel() {
        polishingTranscriptID = nil
    }

    // MARK: - Private Helpers

    /// Record an enhancement error scoped to a transcript.
    private func recordError(for transcriptID: UUID, message: String) {
        lastEnhancementError = EnhancementError(transcriptID: transcriptID, message: message)
    }
}
