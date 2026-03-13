import AppKit
import EnviousWisprCore
import EnviousWisprStorage
import EnviousWisprAudio
import Foundation

/// Orchestrates the full dictation pipeline: record → transcribe → (correct) → (polish) → store → copy/paste.
@MainActor
@Observable
final class TranscriptionPipeline: DictationPipeline {
    private let audioCapture: AudioCaptureManager
    private let asrManager: ASRManager
    private let transcriptStore: TranscriptStore
    private let keychainManager: KeychainManager

    private(set) var state: PipelineState = .idle {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }
    var onStateChange: ((PipelineState) -> Void)?
    private(set) var currentTranscript: Transcript?
    var autoCopyToClipboard: Bool = true
    var autoPasteToActiveApp: Bool = false
    var vadAutoStop: Bool = false
    var vadSilenceTimeout: Double = 1.5
    var vadSensitivity: Float = 0.5
    var vadEnergyGate: Bool = false
    var modelUnloadPolicy: ModelUnloadPolicy = .never
    var restoreClipboardAfterPaste: Bool = false
    var transcriptionOptions: TranscriptionOptions = .default
    var lastPolishError: String?

    // Text processing steps
    private let wordCorrectionStep = WordCorrectionStep()
    private let fillerRemovalStep = FillerRemovalStep()
    private let llmPolishStep: LLMPolishStep
    private var textProcessingSteps: [any TextProcessingStep] = []

    /// Access word correction step for configuration.
    var wordCorrection: WordCorrectionStep { wordCorrectionStep }
    /// Access filler removal step for configuration.
    var fillerRemoval: FillerRemovalStep { fillerRemovalStep }
    /// Access LLM polish step for configuration.
    var llmPolish: LLMPolishStep { llmPolishStep }

    /// The app that was frontmost when recording started — re-activated before pasting.
    private var targetApp: NSRunningApplication?
    /// The specific text field that was focused when recording started — used for AX direct insertion.
    private var targetElement: AXUIElement?
    private var silenceDetector: SilenceDetector?
    private var vadMonitorTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    /// Whether streaming ASR was successfully started for the current recording.
    private var streamingASRActive = false
    /// Counters for diagnosing streaming buffer delivery (tail-cutoff instrumentation).
    private var streamingBuffersDispatched = 0
    private var streamingBuffersFed = 0
    /// Guards against concurrent stopAndTranscribe calls (e.g., VAD auto-stop racing PTT release).
    private var isStopping = false
    /// Guards against concurrent startRecording calls (e.g., rapid toggle presses).
    private var isStarting = false
    /// Set by key-up when startRecording() is still in-flight; checked after .recording is entered.
    private var stopRequested = false
    /// Whether audio input has been pre-warmed (engine started) by PTT key-down.
    private var isPreWarmed = false

    init(
        audioCapture: AudioCaptureManager,
        asrManager: ASRManager,
        transcriptStore: TranscriptStore,
        keychainManager: KeychainManager = KeychainManager()
    ) {
        self.audioCapture = audioCapture
        self.asrManager = asrManager
        self.transcriptStore = transcriptStore
        self.keychainManager = keychainManager
        self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)
        llmPolishStep.onWillProcess = { [weak self] in
            self?.state = .polishing
        }

        // Handle audio engine interruption (device disconnect, max duration cap).
        // Perform full pipeline cleanup and transition to error state.
        audioCapture.onEngineInterrupted = { [weak self] in
            guard let self else { return }
            self.vadMonitorTask?.cancel()
            self.vadMonitorTask = nil
            self.silenceDetector = nil
            if self.streamingASRActive {
                Task { [weak self] in
                    await self?.asrManager.cancelStreaming()
                }
            }
            self.deactivateStreamingForwarding()
            self.targetApp = nil
            self.recordingStartTime = nil
            self.state = .error("Audio device disconnected")
        }
        // Activate SSE streaming for Gemini — a non-nil onToken causes GeminiConnector
        // to use streamGenerateContent instead of batch generateContent.
        // No-op callback is correct; live token display in overlay is a future follow-up.
        llmPolishStep.onToken = { _ in }
        textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]
    }

    /// Pre-warm the audio input to trigger any Bluetooth codec switch before recording.
    /// Called on PTT key-down to hide the 0.5–2s Bluetooth negotiation latency.
    /// Sets `isPreWarmed` so `startRecording()` skips engine phase 1.
    func preWarmAudioInput() async {
        guard !state.isActive, state != .recording else { return }
        stopRequested = false
        await audioCapture.preWarm()
        guard !Task.isCancelled else { return }
        isPreWarmed = true
    }

    /// Toggle recording: start if idle, stop if recording.
    func toggleRecording() async {
        switch state {
        case .idle, .complete, .error:
            await startRecording()
        case .recording:
            await stopAndTranscribe()
        case .transcribing, .polishing:
            break // Don't interrupt processing
        }
    }

    /// Start recording audio from the microphone.
    func startRecording() async {
        guard !Task.isCancelled else { return }
        guard !isStarting else { return }
        guard !state.isActive || state == .complete else { return }
        isStarting = true
        defer { isStarting = false }

        lastPolishError = nil
        deactivateStreamingForwarding()

        // Cancel idle timer so model stays loaded during recording.
        asrManager.cancelIdleTimer()

        // Ensure model is loaded (model should already be cached by WhisperKitSetupService)
        if !asrManager.isModelLoaded {
            state = .transcribing
            do {
                try await asrManager.loadModel()
            } catch {
                stopRequested = false
                state = .error("Model load failed: \(error.localizedDescription)")
                return
            }
            guard !Task.isCancelled else { return }
        }

        // Remember the frontmost app and focused text field so we can paste back
        // (LLM polishing can take seconds, during which focus may shift)
        targetApp = NSWorkspace.shared.frontmostApplication
        targetElement = PasteService.captureFocusedElement()

        // BRAIN: gotcha id=pipeline-timing-misconception
        // Start streaming ASR if the backend supports it — feed audio buffers
        // to the ASR model during recording so transcription overlaps with capture.
        var streamingSetupSucceeded = false
        defer { if !streamingSetupSucceeded { deactivateStreamingForwarding() } }

        let supportsStreaming = await asrManager.activeBackendSupportsStreaming
        if supportsStreaming {
            do {
                try await asrManager.startStreaming(options: transcriptionOptions)
                streamingASRActive = true
                streamingBuffersDispatched = 0
                streamingBuffersFed = 0

                // Wire audio buffer forwarding: each converted buffer goes to streaming ASR.
                // The streamingASRActive flag gates delivery — deactivateStreamingForwarding()
                // sets it to false and nils onBufferCaptured, so in-flight tasks exit quickly.
                //
                // NOTE: This callback runs on the real-time audio thread. The TapStoppedFlag
                // in AudioCaptureManager prevents this from being called after teardown starts.
                // The nonisolated(unsafe) is safe because the buffer is created on the audio
                // thread, transferred to the main thread via Task, and never accessed from
                // both threads simultaneously.
                audioCapture.onBufferCaptured = { [weak self] buffer in
                    guard let self else { return }
                    nonisolated(unsafe) let safeBuffer = buffer
                    Task { @MainActor in
                        self.streamingBuffersDispatched += 1
                        guard self.streamingASRActive, self.state == .recording else { return }
                        try? await self.asrManager.feedAudio(safeBuffer)
                        self.streamingBuffersFed += 1
                    }
                }

                Task { await AppLogger.shared.log(
                    "Streaming ASR started during recording",
                    level: .info, category: "Pipeline"
                ) }
            } catch {
                // Streaming init failed — fall back to batch after recording
                deactivateStreamingForwarding()
                Task { await AppLogger.shared.log(
                    "Streaming ASR failed to start, will use batch: \(error.localizedDescription)",
                    level: .info, category: "Pipeline"
                ) }
            }
        }

        do {
            // Two-phase start: phase 1 triggers any Bluetooth codec switch
            if !isPreWarmed {
                try audioCapture.startEnginePhase()

                // Wait for format to stabilize (Bluetooth) or pass immediately (built-in mic)
                let stabilized = await audioCapture.waitForFormatStabilization(
                    maxWait: 1.5,
                    pollInterval: 0.2
                )
                guard !Task.isCancelled else { isPreWarmed = false; return }

                // If format never settled, rebuild engine once and retry
                if !stabilized {
                    audioCapture.rebuildEngine()
                    try audioCapture.startEnginePhase()
                }
            }
            isPreWarmed = false

            // Phase 2: install tap and start capture
            _ = try audioCapture.beginCapturePhase()
            streamingSetupSucceeded = true
            state = .recording
            recordingStartTime = Date()
            currentTranscript = nil

            if stopRequested {
                stopRequested = false
                await stopAndTranscribe()
                return
            }

            Task { await AppLogger.shared.log(
                "Recording started. Backend: \(asrManager.activeBackendType.rawValue), streaming=\(streamingASRActive)",
                level: .info, category: "Pipeline"
            ) }

            // Always start VAD monitoring for silence removal
            startVADMonitoring()
        } catch {
            // startCapture() failed — cancel any streaming session we started
            if streamingASRActive {
                await asrManager.cancelStreaming()
            }
            deactivateStreamingForwarding()
            stopRequested = false
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Stop recording, or set a flag if startRecording() is still in-flight.
    /// Handles the pre-warm phase (.idle) as well as model loading (.transcribing).
    func requestStop() async {
        switch state {
        case .recording:
            await stopAndTranscribe()
        case .idle, .transcribing:
            // .idle: startRecording is in-flight (pre-warm/engine setup) → will check after entering .recording.
            // .transcribing: model load in progress → startRecording will check and stop.
            stopRequested = true
            // PTT release before recording started — clean up pre-warmed audio engine
            if state == .idle, isPreWarmed {
                isPreWarmed = false
                audioCapture.abortPreWarm()
            }
        case .polishing, .complete, .error:
            // Pipeline is past the point of no return or already finished — ignore.
            break
        }
    }

    /// Stop recording and transcribe the captured audio.
    func stopAndTranscribe() async {
        guard state == .recording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        let pipelineStart = CFAbsoluteTimeGetCurrent()

        // Silently discard recordings shorter than minimum duration (accidental taps)
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < TimingConstants.minimumRecordingDuration {
                vadMonitorTask?.cancel()
                vadMonitorTask = nil
                if streamingASRActive {
                    await asrManager.cancelStreaming()
                }
                deactivateStreamingForwarding()
                _ = audioCapture.stopCapture()
                recordingStartTime = nil
                state = .idle
                Task { await AppLogger.shared.log(
                    "Recording too short (\(String(format: "%.2f", elapsed))s), discarded silently",
                    level: .info, category: "Pipeline"
                ) }
                return
            }
        }
        recordingStartTime = nil

        // Cancel VAD monitoring
        vadMonitorTask?.cancel()
        vadMonitorTask = nil

        let wasStreaming = streamingASRActive

        // Stop the audio tap FIRST — prevents new buffer-feed tasks from being dispatched.
        // Then yield to drain any in-flight feed tasks already queued on @MainActor.
        // These tasks check streamingASRActive (still true) and deliver their buffers
        // to the Parakeet actor before we deactivate forwarding.
        // Without this reorder, deactivateStreamingForwarding() sets the flag to false
        // and all queued tasks drop their buffers — losing ~250-500ms of trailing audio.
        let rawSamples = audioCapture.stopCapture()

        if wasStreaming {
            await Task.yield()
            await Task.yield()
        }

        deactivateStreamingForwarding()

        // Defense: if cancelRecording() ran during yield, bail out
        guard state == .recording else { return }

        // Pre-warm the LLM connection while ASR is still running (fire-and-forget).
        // Establishes TLS + HTTP/2 so the polish request skips the handshake.
        LLMNetworkSession.shared.preWarmIfConfigured(
            provider: llmPolishStep.llmProvider,
            keychainManager: keychainManager
        )

        guard !rawSamples.isEmpty else {
            // Cancel streaming if it was active — empty samples means no useful audio
            if wasStreaming {
                await asrManager.cancelStreaming()
            }
            state = .error("No audio captured")
            return
        }

        Task { await AppLogger.shared.log(
            "Captured \(rawSamples.count) samples (\(String(format: "%.2f", Double(rawSamples.count)/16000))s)",
            level: .verbose, category: "Pipeline"
        ) }

        // Filter silence using VAD speech segments (used for batch fallback and logging).
        var samples: [Float]
        if let detector = silenceDetector {
            await detector.finalizeSegments(totalSampleCount: rawSamples.count)
            samples = await detector.filterSamples(from: rawSamples)
        } else {
            samples = rawSamples
        }

        Task { await AppLogger.shared.log(
            "VAD filtered to \(samples.count) samples (\(String(format: "%.1f", Double(samples.count)/Double(max(rawSamples.count, 1))*100))% voiced)",
            level: .verbose, category: "Pipeline"
        ) }

        // ASR backends require >= 1 second of audio.
        // If VAD filtering was too aggressive, fall back to raw samples.
        let minimumSamples = AudioConstants.minimumTranscriptionSamples
        if samples.count < minimumSamples && rawSamples.count >= minimumSamples {
            samples = rawSamples
        }

        // Pad short recordings with silence so single-word inputs ("hey", "hi") work.
        if samples.count > 0 && samples.count < minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
        }

        state = .transcribing

        do {
            let asrStart = CFAbsoluteTimeGetCurrent()

            // If streaming ASR was active, finalize it (fast — just the last chunk).
            // Otherwise fall back to batch transcription on the VAD-filtered audio.
            let result: ASRResult
            if wasStreaming {
                do {
                    result = try await finalizeStreamingWithTimeout(samples: samples)
                    let audioDuration = Double(rawSamples.count) / AudioCaptureManager.targetSampleRate
                    let wordCount = result.text.split(whereSeparator: \.isWhitespace).count
                    let wps = Double(wordCount) / max(audioDuration, 0.1)
                    Task { await AppLogger.shared.log(
                        "Pipeline timing: streaming ASR finalized in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - asrStart))s",
                        level: .info, category: "PipelineTiming"
                    ) }
                    Task { await AppLogger.shared.log(
                        "Streaming tail check: fed=\(self.streamingBuffersFed)/\(self.streamingBuffersDispatched), " +
                        "streaming=\(wasStreaming), audio=\(String(format: "%.1f", audioDuration))s, " +
                        "words=\(wordCount), wps=\(String(format: "%.1f", wps))",
                        level: .info, category: "PipelineTiming"
                    ) }
                    if wasStreaming && audioDuration >= 2.0 && wps < 1.0 {
                        Task { await AppLogger.shared.log(
                            "TAIL_SUSPECT: low wps (\(String(format: "%.1f", wps))) for \(String(format: "%.1f", audioDuration))s recording",
                            level: .info, category: "PipelineTiming"
                        ) }
                    }
                } catch {
                    // Streaming finalization failed or timed out — cancel and fall back to batch
                    await asrManager.cancelStreaming()
                    Task { await AppLogger.shared.log(
                        "Streaming ASR finalize failed, falling back to batch: \(error.localizedDescription)",
                        level: .info, category: "Pipeline"
                    ) }
                    result = try await asrManager.transcribe(audioSamples: samples, options: transcriptionOptions)
                }
            } else {
                result = try await asrManager.transcribe(audioSamples: samples, options: transcriptionOptions)
            }

            let asrEnd = CFAbsoluteTimeGetCurrent()

            let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !asrText.isEmpty else {
                state = .error("No speech detected — try speaking closer to the microphone")
                Task { await AppLogger.shared.log(
                    "ASR returned empty text, showing error to user",
                    level: .info, category: "Pipeline"
                ) }
                return
            }

            Task { await AppLogger.shared.log(
                "Pipeline timing: ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s " +
                "(mode=\(wasStreaming ? "streaming" : "batch"), \(asrText.count) chars, lang=\(result.language ?? "?"))",
                level: .info, category: "PipelineTiming"
            ) }

            // Run pluggable text processing steps (word correction, LLM polish, etc.)
            let polishStart = CFAbsoluteTimeGetCurrent()
            var context: TextProcessingContext
            do {
                context = try await runTextProcessing(asrText: asrText, language: result.language)
            } catch {
                Task { await AppLogger.shared.log(
                    "Text processing failed: \(error.localizedDescription)",
                    level: .info, category: "Pipeline"
                ) }
                lastPolishError = error.localizedDescription
                context = TextProcessingContext(text: asrText, originalASRText: asrText, language: result.language)
            }
            let polishEnd = CFAbsoluteTimeGetCurrent()

            Task { await AppLogger.shared.log(
                "Pipeline timing: text processing completed in \(String(format: "%.3f", polishEnd - polishStart))s",
                level: .info, category: "PipelineTiming"
            ) }

            let finalText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                state = .error("No text after processing")
                return
            }

            let transcript = Transcript(
                text: context.text,
                polishedText: context.polishedText,
                language: result.language,
                duration: result.duration,
                processingTime: result.processingTime,
                backendType: result.backendType,
                llmProvider: context.llmProvider,
                llmModel: context.llmModel
            )

            // Save to store
            try transcriptStore.save(transcript)

            // Notify ASR manager that transcription is done; schedules unload timer if configured.
            asrManager.noteTranscriptionComplete(policy: modelUnloadPolicy)

            // Auto-copy/paste + auto-submit — tiered cascade
            let pasteStart = CFAbsoluteTimeGetCurrent()
            if autoPasteToActiveApp {
                let text = transcript.displayText
                let bundleId = targetApp?.bundleIdentifier ?? "unknown"
                var tier: PasteTier = .clipboardOnly

                // Tier 1: AX direct insertion — zero disruption, no clipboard, no focus change.
                if let element = targetElement {
                    if PasteService.insertViaAccessibility(text, element: element) {
                        tier = .axDirect
                    }
                }

                // Tier 2: Activate target app + CGEvent Cmd+V
                if tier == .clipboardOnly, let app = targetApp, !app.isTerminated {
                    let pollInterval = TimingConstants.activationPollIntervalMs
                    let timeout = TimingConstants.activationTimeoutMs
                    // Activate once, then poll. Retry activation at longer intervals.
                    app.activate(options: .activateIgnoringOtherApps)
                    var elapsed = 0
                    while elapsed < timeout {
                        try? await Task.sleep(for: .milliseconds(pollInterval))
                        elapsed += pollInterval
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                            break
                        }
                        if elapsed % 300 < pollInterval {
                            app.activate(options: .activateIgnoringOtherApps)
                        }
                    }

                    let activated = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier

                    if activated {
                        let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
                            ? PasteService.saveClipboard()
                            : nil

                        let changeCountAfterPaste = PasteService.pasteToActiveApp(text)
                        tier = .cgEvent

                        if let snapshot {
                            try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                            PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
                        }
                    } else {
                        // Tier 2b: AppleScript Edit > Paste (needs frontmost, try one more activation)
                        app.activate(options: .activateIgnoringOtherApps)
                        try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))

                        let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
                            ? PasteService.saveClipboard()
                            : nil

                        let changeCount = PasteService.copyToClipboardReturningChangeCount(text)

                        if PasteService.pasteViaAppleScript(pid: app.processIdentifier) {
                            tier = .appleScript
                        }

                        if let snapshot {
                            try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                            PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCount)
                        }
                    }
                }

                // Tier 3: Clipboard + fallback — text is never lost
                if tier == .clipboardOnly {
                    PasteService.copyToClipboard(text)
                }

                let durationMs = Int((CFAbsoluteTimeGetCurrent() - pasteStart) * 1000)
                Task { await AppLogger.shared.log(
                    "Pipeline paste: tier=\(tier.rawValue), app=\(bundleId), duration=\(durationMs)ms",
                    level: .info, category: "PipelineTiming"
                ) }

            } else if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }
            let pasteEnd = CFAbsoluteTimeGetCurrent()
            targetApp = nil
            targetElement = nil

            let pipelineEnd = CFAbsoluteTimeGetCurrent()
            Task { await AppLogger.shared.log(
                "Pipeline timing TOTAL: \(String(format: "%.3f", pipelineEnd - pipelineStart))s " +
                "(ASR=\(String(format: "%.3f", asrEnd - asrStart))s, " +
                "polish=\(String(format: "%.3f", polishEnd - polishStart))s, " +
                "paste=\(String(format: "%.3f", pasteEnd - pasteStart))s)",
                level: .info, category: "PipelineTiming"
            ) }

            currentTranscript = transcript
            state = .complete
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Polish a single transcript on demand (from detail view).
    func polishExistingTranscript(_ transcript: Transcript) async -> Transcript? {
        guard llmPolishStep.isEnabled else { return nil }
        guard !state.isActive || state == .complete else { return nil }

        state = .polishing
        let polishedText: String
        do {
            var context = TextProcessingContext(
                text: transcript.text,
                originalASRText: transcript.text,
                language: transcript.language
            )
            context = try await llmPolishStep.process(context)
            polishedText = context.polishedText ?? context.text
        } catch {
            Task { await AppLogger.shared.log(
                "LLM polish failed: \(error.localizedDescription)",
                level: .info, category: "Pipeline"
            ) }
            lastPolishError = error.localizedDescription
            state = .complete
            return nil
        }

        let updated = Transcript(
            id: transcript.id,
            text: transcript.text,
            polishedText: polishedText,
            language: transcript.language,
            duration: transcript.duration,
            processingTime: transcript.processingTime,
            backendType: transcript.backendType,
            createdAt: transcript.createdAt,
            llmProvider: llmPolishStep.llmProvider.rawValue,
            llmModel: llmPolishStep.llmModel
        )

        do {
            try transcriptStore.save(updated)
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to save polished transcript: \(error)",
                level: .info, category: "Pipeline"
            ) }
            lastPolishError = error.localizedDescription
            state = .error("Failed to save: \(error.localizedDescription)")
            return nil
        }
        currentTranscript = updated
        state = .complete
        return updated
    }

    /// Reset pipeline to idle state.
    func reset() {
        guard !isStopping, !isStarting else { return }
        stopRequested = false
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        // Cancel any active streaming ASR session to prevent orphaned sessions.
        let wasStreaming = streamingASRActive
        deactivateStreamingForwarding()
        if wasStreaming {
            Task { [weak self] in
                await self?.asrManager.cancelStreaming()
            }
        }
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        silenceDetector = nil
        recordingStartTime = nil
        state = .idle
        currentTranscript = nil
    }

    /// Cancel an active recording immediately without transcribing.
    /// Guards on `.recording` state — safe to call from any other state.
    func cancelRecording() async {
        stopRequested = false
        guard state == .recording else { return }

        // Stop VAD monitoring task immediately
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        silenceDetector = nil

        // Deactivate streaming forwarding FIRST to prevent new buffer dispatches
        let wasStreaming = streamingASRActive
        deactivateStreamingForwarding()

        // Stop the audio engine and discard samples BEFORE awaiting cancelStreaming().
        // This is critical: stopCapture() sets the TapStoppedFlag which prevents
        // the real-time audio thread from creating any new Task allocations. If we
        // await cancelStreaming() first (which suspends), the audio engine continues
        // firing tap callbacks during the suspension, creating Tasks that race with
        // teardown and corrupt the heap.
        _ = audioCapture.stopCapture()

        // Now cancel streaming ASR session (safe to await — engine is stopped)
        if wasStreaming {
            await asrManager.cancelStreaming()
        }

        // Clear target app reference — nothing will be pasted
        targetApp = nil
        recordingStartTime = nil

        // Transition to idle without saving any transcript
        state = .idle
    }

    /// Deactivate streaming ASR buffer forwarding. Does not cancel the backend session.
    private func deactivateStreamingForwarding() {
        streamingASRActive = false
        audioCapture.onBufferCaptured = nil
    }

    // MARK: - VAD Monitoring

    private func startVADMonitoring() {
        vadMonitorTask = Task { [weak self] in
            await self?.monitorVAD()
        }
    }

    private func monitorVAD() async {
        // Build SmoothedVAD config from sensitivity setting
        var config = SmoothedVADConfig.fromSensitivity(vadSensitivity)
        if vadEnergyGate {
            config.energyGateThreshold = 0.005
        }

        // Lazily create detector
        if silenceDetector == nil {
            silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
        }
        guard let detector = silenceDetector else { return }

        await detector.reset()
        await detector.updateConfig(config)

        // Prepare VAD model if needed
        if !(await detector.isReady) {
            do {
                try await detector.prepare()
            } catch {
                Task { await AppLogger.shared.log(
                    "VAD preparation failed: \(error)",
                    level: .info, category: "VAD"
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

            // Snapshot @MainActor-isolated data before any await suspension.
            let currentCount = audioCapture.capturedSamples.count

            while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
                let endIdx = processedSampleCount + chunkSize
                // Snapshot the chunk on @MainActor before crossing into the detector actor.
                let chunk = Array(audioCapture.capturedSamples[processedSampleCount..<endIdx])
                let autoStop = vadAutoStop

                let shouldStop = await detector.processChunk(chunk)

                if shouldStop && autoStop && state == .recording {
                    // Run in a new Task so cancelling vadMonitorTask
                    // doesn't propagate CancellationError into transcription.
                    Task { [weak self] in await self?.stopAndTranscribe() }
                    return
                }

                processedSampleCount += chunkSize
                await Task.yield()
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Streaming Finalization

    /// Maximum time to wait for streaming ASR finalization before falling back to batch.
    private static let streamingFinalizeTimeoutSeconds: Int = 10

    /// Finalize streaming ASR with a timeout.
    /// Races finalization against a deadline using a task group. Whichever task
    /// completes first wins; the loser is cancelled. No shared mutable state needed.
    private func finalizeStreamingWithTimeout(samples: [Float]) async throws -> ASRResult {
        // Capture the manager reference on @MainActor before entering the task group.
        // addTask closures are @Sendable and cannot capture @MainActor-isolated self,
        // so we snapshot what we need here.
        let manager = self.asrManager
        let timeout = Self.streamingFinalizeTimeoutSeconds

        return try await withThrowingTaskGroup(of: ASRResult.self) { group in
            group.addTask {
                try await manager.finalizeStreaming()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ASRError.streamingTimeout
            }
            // Whichever finishes first wins; cancel the other.
            guard let result = try await group.next() else {
                throw ASRError.streamingTimeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Text Processing

    private func runTextProcessing(asrText: String, language: String?) async throws -> TextProcessingContext {
        var context = TextProcessingContext(
            text: asrText,
            originalASRText: asrText,
            language: language
        )
        for step in textProcessingSteps where step.isEnabled {
            let stepName = String(describing: type(of: step))
            let input = context
            // nonisolated(unsafe) is safe: the task group inherits @MainActor isolation,
            // so step.process() still runs on MainActor — no real isolation crossing.
            nonisolated(unsafe) let unsafeStep = step
            do {
                context = try await withThrowingTimeout(seconds: 10) {
                    try await unsafeStep.process(input)
                }
            } catch is TimeoutError {
                Task {
                    await AppLogger.shared.log(
                        "\(stepName) timed out after 10s — skipping",
                        level: .info, category: "TextProcessing"
                    )
                }
                // Heart & Limbs: limb failed, continue with input text
            }
        }
        return context
    }

    // MARK: - DictationPipeline Conformance

    var overlayIntent: OverlayIntent {
        switch state {
        case .recording:
            return .recording(audioLevel: 0) // actual level provided by AudioCaptureManager
        case .transcribing:
            return .processing(label: "Transcribing...")
        case .polishing:
            return .processing(label: "Polishing...")
        case .idle, .complete, .error:
            return .hidden
        }
    }

    func handle(event: PipelineEvent) async {
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
}
