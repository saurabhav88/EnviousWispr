import AppKit
import EnviousWisprCore
import EnviousWisprStorage
import EnviousWisprAudio
import EnviousWisprServices
import EnviousWisprASR
import EnviousWisprLLM
import Foundation
@preconcurrency import WhisperKit

/// Internal state machine for the WhisperKit highway — independent of PipelineState.
public enum WhisperKitPipelineState: Equatable, Sendable {
    case idle
    case startingUp       // engine warm-up / pre-capture setup
    case loadingModel
    case ready
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)

    public var isActive: Bool {
        switch self {
        case .startingUp, .recording, .transcribing, .polishing, .loadingModel:
            return true
        default:
            return false
        }
    }
}

/// Independent WhisperKit dictation pipeline — batch record → transcribe → polish → paste.
///
/// Owns its own 8-state machine, shares only AudioCaptureManager and LLM infrastructure
/// with the Parakeet highway (TranscriptionPipeline). No streaming — batch only.
@MainActor
@Observable
public final class WhisperKitPipeline: DictationPipeline {
    private let audioCapture: any AudioCaptureInterface
    private let backend: WhisperKitBackend
    private let transcriptStore: TranscriptStore
    private let keychainManager: KeychainManager

    public private(set) var state: WhisperKitPipelineState = .idle {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }
    public var onStateChange: ((WhisperKitPipelineState) -> Void)?
    public private(set) var currentTranscript: Transcript?
    public var autoCopyToClipboard: Bool = true
    public var autoPasteToActiveApp: Bool = false
    public var restoreClipboardAfterPaste: Bool = false
    public var transcriptionOptions: TranscriptionOptions = .default
    public var lastPolishError: String?
    public var modelUnloadPolicy: ModelUnloadPolicy = .never

    // Shared services
    private let pasteExecutor = PasteCascadeExecutor()
    private let textProcessingRunner = TextProcessingRunner()

    // Text processing steps (own instances — not shared with Parakeet)
    public let wordCorrectionStep = WordCorrectionStep()
    public let fillerRemovalStep = FillerRemovalStep()
    public let llmPolishStep: LLMPolishStep
    private var textProcessingSteps: [any TextProcessingStep] = []

    /// Access for configuration
    public var wordCorrection: WordCorrectionStep { wordCorrectionStep }
    public var fillerRemoval: FillerRemovalStep { fillerRemovalStep }
    public var llmPolish: LLMPolishStep { llmPolishStep }

    /// The app that was frontmost when recording started.
    private var targetApp: NSRunningApplication?
    private var targetElement: AXUIElement?
    private var recordingStartTime: Date?
    /// Guards against concurrent stopAndTranscribe calls.
    private var isStopping = false
    /// Whether audio input has been pre-warmed by PTT key-down.
    private var isPreWarmed = false

    // VAD properties
    public var vadAutoStop: Bool = false
    public var vadSilenceTimeout: Double = 1.5
    public var vadSensitivity: Float = 0.5
    public var vadEnergyGate: Bool = false

    private var silenceDetector: SilenceDetector?
    private var vadMonitorTask: Task<Void, Never>?
    /// Frozen snapshot of recording state, built before teardown for post-recording error enrichment.
    private var frozenSnapshot: SentryBreadcrumb.RecordingSnapshot?
    private var incrementalWorker: WhisperKitIncrementalWorker?
    private var modelUnloadTask: Task<Void, Never>?

    public init(
        audioCapture: any AudioCaptureInterface,
        backend: WhisperKitBackend,
        transcriptStore: TranscriptStore,
        keychainManager: KeychainManager
    ) {
        self.audioCapture = audioCapture
        self.backend = backend
        self.transcriptStore = transcriptStore
        self.keychainManager = keychainManager
        self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)

        llmPolishStep.onWillProcess = { [weak self] in
            self?.state = .polishing
        }

        // Engine interruption cleanup is wired by AppState.onEngineInterrupted
        // (unified handler that routes to the active pipeline). The pipeline exposes
        // handleEngineInterruption() for AppState to call.

        // Activate SSE streaming for Gemini
        llmPolishStep.onToken = { _ in }
        textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]
    }

    // MARK: - DictationPipeline Conformance

    public var overlayIntent: OverlayIntent {
        switch state {
        case .startingUp:
            return .processing(label: "Starting...")
        case .loadingModel:
            return .processing(label: "Loading model...")
        case .recording:
            return .recording(audioLevel: 0)
        case .transcribing:
            return .processing(label: "Transcribing...")
        case .polishing:
            return .processing(label: "Polishing...")
        case .idle, .ready, .complete:
            return .hidden
        case .error(let msg):
            return .error(message: msg)
        }
    }

    public func handle(event: PipelineEvent) async {
        switch event {
        case .preWarm:
            await preWarmAudioInput()
        case .toggleRecording:
            await toggleRecording()
        case .requestStop:
            await requestStop()
        case .cancelRecording:
            await cancelRecording()
        case .reset:
            reset()
        }
    }

    // MARK: - Background Pre-load

    /// Silently load the WhisperKit model into RAM without changing pipeline state.
    /// Called after model download completes or on launch if model is already cached.
    /// Uses prepareIfCached() to avoid triggering a silent network download.
    /// If user presses record before this finishes, startRecording() handles it with its own .loadingModel flow.
    public func prepareBackendSilently() async {
        let isBackendReady = await backend.isReady
        guard !isBackendReady else { return }
        do {
            let loaded = try await backend.prepareIfCached()
            if loaded {
                Task { await AppLogger.shared.log(
                    "WhisperKit model pre-loaded successfully (background)",
                    level: .info, category: "WhisperKitPipeline"
                ) }
            } else {
                Task { await AppLogger.shared.log(
                    "WhisperKit model not cached, skipping silent pre-load",
                    level: .info, category: "WhisperKitPipeline"
                ) }
            }
        } catch {
            Task { await AppLogger.shared.log(
                "WhisperKit model pre-load failed: \(error.localizedDescription)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        }
    }

    // MARK: - Recording Lifecycle

    public func preWarmAudioInput() async {
        guard !state.isActive, state != .recording else { return }
        let start = ContinuousClock.now
        await audioCapture.preWarm()
        guard !Task.isCancelled else { return }
        isPreWarmed = true
        let totalMs = Self.durationMs(ContinuousClock.now - start)
        Task { await AppLogger.shared.log(
            "COLD-START [WhisperKit] preWarmAudioInput total=\(totalMs)ms",
            level: .info, category: "Pipeline"
        ) }
        // Defense-in-depth: ensure model is loaded from cache (no download).
        // If not cached, startRecording() handles the full load with user-visible UI.
        Task { _ = try? await backend.prepareIfCached() }
    }

    /// Convert Duration to milliseconds for logging.
    private static func durationMs(_ d: Duration) -> Int {
        let (seconds, attoseconds) = d.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    public func toggleRecording() async {
        switch state {
        case .idle, .ready, .complete, .error:
            await startRecording()
        case .recording:
            await stopAndTranscribe()
        case .loadingModel, .startingUp, .transcribing, .polishing:
            break
        }
    }

    public func startRecording() async {
        guard !state.isActive || state == .complete || state == .ready else { return }

        // Cancel any pending model unload — keep model loaded during recording.
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        state = .startingUp
        lastPolishError = nil
        SentryBreadcrumb.add(stage: "whisperkit", message: "Pipeline starting up")

        // Load model if not ready
        let isBackendReady = await backend.isReady
        guard state == .startingUp else { return }  // cancelled during await

        if !isBackendReady {
            state = .loadingModel
            SentryBreadcrumb.add(stage: "asr", message: "WhisperKit model loading")
            do {
                try await backend.prepare()
            } catch {
                SentryBreadcrumb.captureError(error, category: .modelLoadFailed, stage: "asr", extra: ["backend": "whisperKit"])
                state = .error("Model load failed: \(error.localizedDescription)")
                return
            }
            guard state == .loadingModel else { return }  // cancelled during model load
            state = .startingUp  // back to startingUp for engine setup
        }

        // Capture target app for paste-back
        targetApp = NSWorkspace.shared.frontmostApplication
        targetElement = PasteService.captureFocusedElement()

        // No streaming buffer forwarding for batch mode
        audioCapture.onBufferCaptured = nil

        do {
            if !isPreWarmed {
                try await audioCapture.startEnginePhase()
                let stabilized = await audioCapture.waitForFormatStabilization(
                    maxWait: 1.5,
                    pollInterval: 0.2
                )
                guard state == .startingUp else { return }  // cancelled during stabilization
                if !stabilized {
                    audioCapture.rebuildEngine()
                    try await audioCapture.startEnginePhase()
                }
            }
            isPreWarmed = false

            _ = try await audioCapture.beginCapturePhase()
            state = .recording
            recordingStartTime = Date()
            currentTranscript = nil
            SentryBreadcrumb.add(stage: "recording", message: "WhisperKit recording started", data: ["backend": "whisperKit"])
            SentryBreadcrumb.updateRecordingState(active: true, backend: "whisperkit")
            SentryBreadcrumb.updateAudioRoute(audioCapture.currentAudioRoute)
            startVADMonitoring()
            await startIncrementalWorker()

            Task { await AppLogger.shared.log(
                "WhisperKit recording started (batch mode, incremental worker active)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        } catch {
            SentryBreadcrumb.captureError(error, category: .audioCaptureFailed, stage: "recording", extra: ["backend": "whisperKit"])
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    public func requestStop() async {
        switch state {
        case .recording:
            await stopAndTranscribe()
        case .startingUp, .loadingModel:
            // Clean abort — startRecording() checks state after each await suspension point.
            state = .idle
        case .idle, .ready, .complete, .error:
            // PTT release before recording started — clean up pre-warmed audio engine
            if isPreWarmed {
                isPreWarmed = false
                audioCapture.abortPreWarm()
            }
        case .transcribing, .polishing:
            // Pipeline is past the point of no return — ignore.
            break
        }
    }

    public func stopAndTranscribe() async {
        guard state == .recording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        let pipelineStart = CFAbsoluteTimeGetCurrent()

        // Discard accidental short recordings
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < TimingConstants.minimumRecordingDuration {
                vadMonitorTask?.cancel()
                vadMonitorTask = nil
                await incrementalWorker?.cancel()
                incrementalWorker = nil
                _ = await audioCapture.stopCapture()
                recordingStartTime = nil
                state = .idle
                Task { await AppLogger.shared.log(
                    "WhisperKit recording too short (\(String(format: "%.2f", elapsed))s), discarded",
                    level: .info, category: "WhisperKitPipeline"
                ) }
                return
            }
        }
        // Freeze snapshot BEFORE teardown — post-recording errors use this instead of live scope.
        let snapshotStartTime = recordingStartTime ?? Date()
        let durationMs = Int(Date().timeIntervalSince(snapshotStartTime) * 1000)
        frozenSnapshot = SentryBreadcrumb.RecordingSnapshot(
            backend: "whisperkit",
            audioRoute: audioCapture.currentAudioRoute,
            wasStreaming: false,
            startTime: snapshotStartTime,
            durationMs: durationMs,
            targetAppBundleID: targetApp?.bundleIdentifier
        )

        recordingStartTime = nil
        vadMonitorTask?.cancel()
        vadMonitorTask = nil

        let rawSamples = await audioCapture.stopCapture()
        SentryBreadcrumb.add(stage: "recording", message: "WhisperKit recording stopped", data: ["sample_count": rawSamples.count])
        SentryBreadcrumb.updateRecordingState(active: false)

        // Pre-warm LLM connection while ASR runs
        LLMNetworkSession.shared.preWarmIfConfigured(
            provider: llmPolishStep.llmProvider,
            keychainManager: keychainManager
        )

        guard !rawSamples.isEmpty else {
            SentryBreadcrumb.add(stage: "recording", message: "No audio captured (WhisperKit)", level: .warning)
            state = .error("No audio captured")
            return
        }

        // Post-capture VAD filtering — remove silence segments
        var samples: [Float]
        var hasSpeechEvidence = false
        var vadSegmentCount = 0
        var vadSpeechDurationMs = 0
        let isXPCMode = audioCapture is AudioCaptureProxy
        if isXPCMode {
            // XPC mode: get speech segments from service-side VAD.
            let segments = await audioCapture.getVADSegments()
            hasSpeechEvidence = !segments.isEmpty
            vadSegmentCount = segments.count
            vadSpeechDurationMs = segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000 / 16000
            if !segments.isEmpty {
                samples = Self.filterSamples(from: rawSamples, segments: segments)
                let pct = String(format: "%.1f", Double(samples.count) / Double(max(rawSamples.count, 1)) * 100)
                Task { await AppLogger.shared.log(
                    "WhisperKit VAD (XPC) filtered to \(samples.count) samples (\(pct)% voiced)",
                    level: .info, category: "WhisperKitPipeline"
                ) }
            } else {
                samples = rawSamples
            }
        } else if let detector = silenceDetector {
            await detector.finalizeSegments(totalSampleCount: rawSamples.count)
            let segments = await detector.speechSegments
            hasSpeechEvidence = !segments.isEmpty
            vadSegmentCount = segments.count
            vadSpeechDurationMs = segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000 / 16000
            samples = await detector.filterSamples(from: rawSamples)
            let pct = String(format: "%.1f", Double(samples.count) / Double(max(rawSamples.count, 1)) * 100)
            Task { await AppLogger.shared.log(
                "WhisperKit VAD filtered to \(samples.count) samples (\(pct)% voiced)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        } else {
            samples = rawSamples
            // No VAD detector available -- default to true so empty ASR results
            // still fire Sentry errors (fail toward visibility).
            hasSpeechEvidence = true
        }
        let peakAudioLevel = rawSamples.reduce(Float(0)) { max($0, abs($1)) }

        // VAD gate: if no speech was detected, skip ASR entirely.
        // Prevents noise-induced hallucinations from ambient sounds.
        if !hasSpeechEvidence {
            if let worker = incrementalWorker {
                await worker.cancel()
                incrementalWorker = nil
            }
            SentryBreadcrumb.add(
                stage: "asr", message: "VAD gate: no speech detected, skipping WhisperKit ASR",
                level: .info,
                data: [
                    "backend": "whisperKit",
                    "raw_sample_count": rawSamples.count,
                    "peak_audio_level": peakAudioLevel,
                ]
            )
            frozenSnapshot = nil
            state = .idle
            Task { await AppLogger.shared.log(
                "VAD gate: no speech, skipping WhisperKit ASR (samples=\(rawSamples.count), peak=\(String(format: "%.4f", peakAudioLevel)))",
                level: .info, category: "WhisperKitPipeline"
            ) }
            return
        }

        // Fallback: if VAD was too aggressive, use raw
        let minimumSamples = AudioConstants.minimumTranscriptionSamples
        if samples.count < minimumSamples && rawSamples.count >= minimumSamples {
            samples = rawSamples
        }

        // Pad short recordings
        if samples.count > 0 && samples.count < minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
        }

        state = .transcribing
        SentryBreadcrumb.add(stage: "asr", message: "WhisperKit transcription started", data: ["backend": "whisperKit"])

        do {
            let asrStart = CFAbsoluteTimeGetCurrent()

            // Try background worker result first, batch fallback if stale/empty
            let asrText: String
            let asrLanguage: String?
            var usedIncremental = false

            if let worker = incrementalWorker {
                let segments = await silenceDetector?.speechSegments ?? []
                let result = await worker.finalize(finalSamples: rawSamples, speechSegments: segments)
                incrementalWorker = nil

                let coveragePct = rawSamples.count > 0
                    ? String(format: "%.1f", Double(result.samplesCovered) / Double(rawSamples.count) * 100)
                    : "0"

                if result.accepted, let text = result.text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    asrText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    asrLanguage = transcriptionOptions.language
                    usedIncremental = true

                    Task { await AppLogger.shared.log(
                        "WhisperKit finalize: strategy=\(result.strategy), mode=\(result.mode), " +
                        "decodes=\(result.decodeCount), tailDecodeMs=\(result.tailDecodeMs), " +
                        "coverage=\(result.samplesCovered)/\(rawSamples.count) (\(coveragePct)%)",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                } else {
                    Task { await AppLogger.shared.log(
                        "WhisperKit finalize: strategy=\(result.strategy), " +
                        "workerDecodes=\(result.decodeCount), workerCoverage=\(coveragePct)%, " +
                        "falling back to batch",
                        level: .info, category: "WhisperKitPipeline"
                    ) }

                    let batchStart = CFAbsoluteTimeGetCurrent()
                    let batchResult = try await backend.transcribe(audioSamples: samples, options: transcriptionOptions)
                    let batchMs = Int((CFAbsoluteTimeGetCurrent() - batchStart) * 1000)
                    asrText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    asrLanguage = batchResult.language

                    Task { await AppLogger.shared.log(
                        "WhisperKit finalize: strategy=\(result.strategy), batchMs=\(batchMs), " +
                        "workerDecodes=\(result.decodeCount), workerCoverage=\(coveragePct)%",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                }
            } else {
                let batchResult = try await backend.transcribe(audioSamples: samples, options: transcriptionOptions)
                asrText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                asrLanguage = batchResult.language
            }

            let asrEnd = CFAbsoluteTimeGetCurrent()

            guard !asrText.isEmpty else {
                if hasSpeechEvidence {
                    // Real ASR failure: VAD detected speech but decoder returned nothing
                    SentryBreadcrumb.captureError(
                        NSError(domain: "EnviousWispr", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit ASR returned empty text despite speech evidence"]),
                        category: .asrEmptyResult, stage: "asr",
                        extra: [
                            "backend": "whisperKit",
                            "incremental": usedIncremental,
                            "has_speech_evidence": true,
                            "raw_sample_count": rawSamples.count,
                            "vad_segment_count": vadSegmentCount,
                            "vad_speech_duration_ms": vadSpeechDurationMs,
                            "peak_audio_level": peakAudioLevel,
                        ],
                        snapshot: frozenSnapshot
                    )
                    state = .error("Couldn't catch that -- try again")
                    Task { await AppLogger.shared.log(
                        "WhisperKit ASR empty despite speech evidence (segments=\(vadSegmentCount), speechMs=\(vadSpeechDurationMs), peak=\(peakAudioLevel))",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                } else {
                    // Expected: user held button without speaking
                    SentryBreadcrumb.add(
                        stage: "asr", message: "WhisperKit ASR empty (no speech detected)",
                        level: .info,
                        data: ["backend": "whisperKit", "incremental": usedIncremental]
                    )
                    state = .idle
                    Task { await AppLogger.shared.log(
                        "WhisperKit: no speech detected, returning to idle",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                }
                frozenSnapshot = nil
                return
            }

            SentryBreadcrumb.add(stage: "asr", message: "WhisperKit ASR completed", data: [
                "duration_s": String(format: "%.3f", asrEnd - asrStart),
                "char_count": asrText.count,
                "incremental": usedIncremental,
            ])
            Task { await AppLogger.shared.log(
                "WhisperKit ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s " +
                "(\(asrText.count) chars, lang=\(asrLanguage ?? "?"), incremental=\(usedIncremental))",
                level: .info, category: "WhisperKitPipeline"
            ) }

            // Run text processing (word correction, filler removal, LLM polish)
            let polishStart = CFAbsoluteTimeGetCurrent()
            var context: TextProcessingContext
            do {
                context = try await runTextProcessing(asrText: asrText, language: asrLanguage)
            } catch {
                SentryBreadcrumb.captureError(error, category: .generationFailed, stage: "polish", extra: [
                    "provider": llmPolishStep.llmProvider.rawValue,
                    "model": llmPolishStep.llmModel,
                ])
                // Fire-and-forget: AI diagnostics must not block paste path (up to 10s timeout)
                if llmPolishStep.llmProvider == .appleIntelligence {
                    let capturedStartTime = self.recordingStartTime
                    Task { [weak self] in
                        let aiReport = await AppleIntelligenceDiagnosticsService.runDiagnostics()
                        guard self?.recordingStartTime == capturedStartTime else { return }
                        SentryBreadcrumb.reportAIFailure(aiReport)
                    }
                }
                lastPolishError = error.localizedDescription
                context = TextProcessingContext(text: asrText, language: asrLanguage)
                context.targetAppName = targetApp?.localizedName
            }
            let polishEnd = CFAbsoluteTimeGetCurrent()

            let finalText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                state = .error("No text after processing")
                return
            }

            let recordingDuration = Double(rawSamples.count) / 16000.0
            var transcript = Transcript(
                text: context.text,
                polishedText: context.polishedText,
                language: asrLanguage,
                duration: recordingDuration,
                processingTime: asrEnd - asrStart,
                backendType: .whisperKit,
                llmProvider: context.llmProvider,
                llmModel: context.llmModel
            )

            try transcriptStore.save(transcript)

            // Paste cascade (same tiered approach as TranscriptionPipeline)
            let pasteStart = CFAbsoluteTimeGetCurrent()
            let pasteTargetApp = targetApp?.bundleIdentifier
            var pasteTier: PasteTier?
            var pasteMs: Int?
            if autoPasteToActiveApp {
                let text = PasteService.appendTrailingSpace(transcript.displayText)
                let result = await performPaste(text: text, pasteStart: pasteStart)
                pasteTier = result.tier
                pasteMs = result.durationMs
            } else if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }
            targetApp = nil
            targetElement = nil

            let pipelineEnd = CFAbsoluteTimeGetCurrent()
            Task { await AppLogger.shared.log(
                "WhisperKit pipeline TOTAL: \(String(format: "%.3f", pipelineEnd - pipelineStart))s " +
                "(ASR=\(String(format: "%.3f", asrEnd - asrStart))s, " +
                "polish=\(String(format: "%.3f", polishEnd - polishStart))s)",
                level: .info, category: "WhisperKitPipeline"
            ) }

            transcript.metrics = ExecutionMetrics(
                asrLatencySeconds: asrEnd - asrStart,
                llmLatencySeconds: polishEnd - polishStart,
                pasteTier: pasteTier?.rawValue,
                pasteLatencyMs: pasteMs,
                targetApp: pasteTargetApp,
                coldStart: false,
                streamingMode: false,
                e2eSeconds: pipelineEnd - pipelineStart
            )
            currentTranscript = transcript
            SentryBreadcrumb.add(stage: "pipeline", message: "WhisperKit pipeline complete", data: [
                "e2e_s": String(format: "%.3f", pipelineEnd - pipelineStart),
                "asr_s": String(format: "%.3f", asrEnd - asrStart),
                "polish_s": String(format: "%.3f", polishEnd - polishStart),
                "paste_tier": pasteTier?.rawValue ?? "none",
            ])
            frozenSnapshot = nil
            state = .complete
            scheduleModelUnloadIfNeeded()
        } catch {
            SentryBreadcrumb.captureError(error, category: .asrFailed, stage: "transcription", extra: ["backend": "whisperKit"], snapshot: frozenSnapshot)
            frozenSnapshot = nil
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Handle audio engine interruption (device disconnect, service crash, max duration cap).
    /// Called by AppState's unified interruption handler, not set directly on audioCapture.
    public func handleEngineInterruption() {
        let snapshot = buildInterruptionSnapshot()
        SentryBreadcrumb.captureError(
            NSError(domain: "EnviousWispr", code: -2, userInfo: [NSLocalizedDescriptionKey: "Audio engine interrupted (WhisperKit)"]),
            category: .xpcServiceError, stage: "audio",
            extra: ["was_recording": state == .recording, "backend": "whisperKit"],
            snapshot: snapshot
        )
        SentryBreadcrumb.updateRecordingState(active: false)
        frozenSnapshot = nil
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        silenceDetector = nil
        targetApp = nil
        targetElement = nil
        recordingStartTime = nil
        isStopping = false
        isPreWarmed = false
        state = .error("Audio device disconnected")
    }

    /// Handle ASR XPC service crash during active session.
    /// Called by AppState's unified ASR interruption handler when this pipeline is active.
    /// Must stop audio capture (still running — only ASR died) and clean up fully.
    public func handleASRServiceInterruption() {
        let snapshot = buildInterruptionSnapshot()
        SentryBreadcrumb.captureError(
            NSError(domain: "EnviousWispr", code: -3, userInfo: [NSLocalizedDescriptionKey: "ASR XPC service crashed (WhisperKit)"]),
            category: .xpcServiceError, stage: "asr",
            extra: ["was_recording": state == .recording, "backend": "whisperKit"],
            snapshot: snapshot
        )
        SentryBreadcrumb.updateRecordingState(active: false)
        frozenSnapshot = nil
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        silenceDetector = nil
        Task { [weak self] in
            await self?.audioCapture.stopCapture()
        }
        targetApp = nil
        targetElement = nil
        recordingStartTime = nil
        isStopping = false
        isPreWarmed = false
        state = .error("Transcription service crashed — please try again")
    }

    private func buildInterruptionSnapshot() -> SentryBreadcrumb.RecordingSnapshot {
        if let existing = frozenSnapshot { return existing }
        let start = recordingStartTime ?? Date()
        return SentryBreadcrumb.RecordingSnapshot(
            backend: "whisperkit",
            audioRoute: audioCapture.currentAudioRoute,
            wasStreaming: false,
            startTime: start,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            targetAppBundleID: targetApp?.bundleIdentifier
        )
    }

    public func cancelRecording() async {
        if state == .startingUp || state == .loadingModel {
            // Cancel during startup or model load — transition to idle
            state = .idle
            return
        }

        guard state == .recording else { return }
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        await incrementalWorker?.cancel()
        incrementalWorker = nil
        silenceDetector = nil
        _ = await audioCapture.stopCapture()
        targetApp = nil
        targetElement = nil
        recordingStartTime = nil
        state = .idle
    }

    public func reset() {
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        // Fire-and-forget cancel — reset() is synchronous, worker cancel is safe to defer
        if let worker = incrementalWorker {
            incrementalWorker = nil
            Task { await worker.cancel() }
        }
        silenceDetector = nil
        if audioCapture.isCapturing {
            let capture = audioCapture
            Task { _ = await capture.stopCapture() }
        }
        audioCapture.onBufferCaptured = nil
        recordingStartTime = nil
        state = .idle
        currentTranscript = nil
    }

    // MARK: - Incremental Worker

    private func startIncrementalWorker() async {
        guard let kit = await backend.whisperKitInstance else { return }
        let opts = await backend.makeDecodeOptions(from: transcriptionOptions, sampleCount: 0)
        // BRAIN: gotcha id=nonisolated-unsafe-tokenizer
        // nonisolated(unsafe): WhisperTokenizer is not Sendable but is safe to transfer —
        // the backend is the sole owner and we pass it to a single actor that holds it for its lifetime.
        nonisolated(unsafe) let tokenizer = await backend.whisperKitTokenizer
        let worker = WhisperKitIncrementalWorker(whisperKit: kit, decodingOptions: opts, tokenizer: tokenizer)
        self.incrementalWorker = worker

        let isXPCMode = audioCapture is AudioCaptureProxy
        let capture = audioCapture

        if isXPCMode {
            // XPC mode: use getSamplesSnapshot for incremental sample access.
            // Tracks fromIndex locally — each call fetches only new samples since last snapshot.
            //
            // Memory: `accumulated` grows linearly with recording duration, mirroring the
            // in-process path where capturedSamples grows the same way. The worker expects
            // full audio history for re-transcription. At 16kHz Float32, 2 min = ~7.7MB,
            // 5 min (max recording) = ~19MB. Bounded by TimingConstants.maxRecordingDuration.
            var nextIndex = 0
            var accumulated: [Float] = []
            await worker.start(audioSamplesProvider: { @MainActor in
                let (newSamples, totalCount) = await capture.getSamplesSnapshot(fromIndex: nextIndex)
                accumulated.append(contentsOf: newSamples)
                nextIndex = totalCount
                return (samples: accumulated, count: accumulated.count)
            })
        } else {
            // In-process mode: read directly from MainActor-isolated capturedSamples.
            await worker.start(audioSamplesProvider: { @MainActor in
                let samples = capture.capturedSamples
                return (samples: samples, count: samples.count)
            })
        }
    }

    // MARK: - VAD Monitoring

    private func startVADMonitoring() {
        vadMonitorTask = Task { [weak self] in
            await self?.monitorVAD()
        }
    }

    private func monitorVAD() async {
        // Max-duration enforcement runs regardless of backend mode.
        // VAD chunk processing only runs for in-process capture.
        // XPC-mode VAD runs in the service and fires vadAutoStopTriggered callback.
        //
        // TEMPORARY DEBT: `is AudioCaptureProxy` — see TranscriptionPipeline.monitorVAD comment.
        // Step 7 should replace with interface capability query.
        let isXPCMode = audioCapture is AudioCaptureProxy

        if !isXPCMode {
            let config = SmoothedVADConfig.fromSensitivity(vadSensitivity, energyGate: vadEnergyGate)

            if silenceDetector == nil {
                silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
            }
            guard let detector = silenceDetector else { return }

            await detector.reset()
            await detector.updateConfig(config)

            if !(await detector.isReady) {
                do {
                    try await detector.prepare()
                } catch {
                    Task { await AppLogger.shared.log(
                        "WhisperKit VAD preparation failed: \(error)",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                    return
                }
            }

            var processedSampleCount = 0
            let chunkSize = SilenceDetector.chunkSize

            while state == .recording && !Task.isCancelled {
                // Graceful max duration check — auto-stop before AudioCaptureManager's hard limit.
                if let startTime = recordingStartTime,
                   Date().timeIntervalSince(startTime) >= TimingConstants.maxRecordingDuration {
                    Task { [weak self] in await self?.stopAndTranscribe() }
                    return
                }

                let currentCount = audioCapture.capturedSamples.count

                while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
                    let endIdx = processedSampleCount + chunkSize
                    let chunk = Array(audioCapture.capturedSamples[processedSampleCount..<endIdx])
                    let autoStop = vadAutoStop

                    let shouldStop = await detector.processChunk(chunk)

                    if shouldStop && autoStop && state == .recording {
                        Task { [weak self] in await self?.stopAndTranscribe() }
                        return
                    }

                    processedSampleCount += chunkSize
                    await Task.yield()
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            // XPC mode: service handles VAD, fires vadAutoStopTriggered callback.
            // Only run max-duration enforcement here.
            while state == .recording && !Task.isCancelled {
                if let startTime = recordingStartTime,
                   Date().timeIntervalSince(startTime) >= TimingConstants.maxRecordingDuration {
                    Task { [weak self] in await self?.stopAndTranscribe() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - VAD Segment Filtering

    /// Filter samples using speech segments from service-side VAD (XPC mode).
    /// Mirrors SilenceDetector.filterSamples logic — pad segments, merge overlaps, extract voiced audio.
    private static func filterSamples(from allSamples: [Float], segments: [SpeechSegment], padding: Int = 1600) -> [Float] {
        guard !segments.isEmpty else { return allSamples }

        let totalVoiced = segments.reduce(0) { $0 + ($1.endSample - $1.startSample) }
        guard totalVoiced >= 4800 else { return allSamples }

        var merged: [(start: Int, end: Int)] = []
        for segment in segments {
            let start = max(0, segment.startSample - padding)
            let end = min(allSamples.count, segment.endSample + padding)
            if let last = merged.last, start <= last.end {
                merged[merged.count - 1].end = max(last.end, end)
            } else {
                merged.append((start, end))
            }
        }

        var result: [Float] = []
        for range in merged {
            guard range.start < range.end else { continue }
            result.append(contentsOf: allSamples[range.start..<range.end])
        }
        return result.isEmpty ? allSamples : result
    }

    // MARK: - Model Lifecycle

    private func scheduleModelUnloadIfNeeded() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        switch modelUnloadPolicy {
        case .never:
            return
        case .immediately:
            modelUnloadTask = Task { [weak self] in
                await self?.backend.unload()
            }
        default:
            guard let interval = modelUnloadPolicy.interval else { return }
            modelUnloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.backend.unload()
            }
        }
    }

    // MARK: - Text Processing

    private func runTextProcessing(asrText: String, language: String?) async throws -> TextProcessingContext {
        let result = try await textProcessingRunner.run(
            rawText: asrText,
            language: language,
            targetAppName: targetApp?.localizedName,
            steps: textProcessingSteps
        )
        if let error = result.polishError {
            lastPolishError = error
        }
        return result.context
    }

    // MARK: - Paste Cascade

    private func performPaste(text: String, pasteStart: CFAbsoluteTime) async -> (tier: PasteTier, durationMs: Int) {
        let result = await pasteExecutor.deliver(PasteDeliveryRequest(
            text: text,
            targetApp: targetApp,
            targetElement: targetElement,
            restoreClipboardAfterPaste: restoreClipboardAfterPaste
        ))
        return (result.tier, result.durationMs)
    }
}
