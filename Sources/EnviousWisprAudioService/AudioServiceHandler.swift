@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprObservabilityCore
import Foundation

/// XPC service handler — composes an AudioCaptureManager and bridges its lifecycle
/// to the XPC protocol. All capture logic runs in the service process; the host app
/// receives buffers and state changes via AudioServiceClientProtocol callbacks.
final class AudioServiceHandler: NSObject, AudioServiceProtocol, @unchecked Sendable {
  /// The XPC connection back to the host — set by AudioServiceDelegate.
  weak var connection: NSXPCConnection?  // periphery:ignore - XPC connection lifecycle; set by delegate, prevents premature release
  /// Client proxy for sending callbacks to the host app.
  /// Resolved from connection.remoteObjectProxy — set by AudioServiceDelegate.
  var clientProxy: (any AudioServiceClientProtocol)?

  /// The in-process audio capture engine. Runs entirely within this XPC service process.
  /// @MainActor — the XPC service's main run loop serves as the MainActor executor.
  /// Created lazily on MainActor when first needed.
  private var _captureManager: AudioCaptureManager?

  /// Dedicated serial queue for XPC sends — keeps XPC messaging off the RT audio thread.
  private let xpcSendQueue = DispatchQueue(label: "com.enviouswispr.audioservice.xpc-send")

  // MARK: - Service-side VAD state (Step 5)

  /// Stored VAD configuration — applied when capture begins, replayed after crash.
  private var vadAutoStop: Bool = false
  private var vadSilenceTimeout: Double = 1.5
  private var vadSensitivity: Float = 0.5
  private var vadEnergyGate: Bool = false

  /// Service-owned SilenceDetector — runs VAD in the service process where samples live.
  private var silenceDetector: SilenceDetector?

  /// VAD monitoring task — started after beginCapture, cancelled on stopCapture/abortPreWarm.
  private var vadMonitorTask: Task<Void, Never>?

  // MARK: - Crash-recovery spool state (#1063 PR1)

  /// The live spool writer, built from the recovery directive at beginCapture
  /// and fed the authoritative captured samples on a poll loop. nil when
  /// recovery is off / failed to arm. MainActor-confined (like the VAD state).
  private var recoverySpoolWriter: RecoverySpoolWriter?
  /// Poll task feeding new captured samples to the writer — mirrors the VAD
  /// monitor. Cancelled on stop / invalidation.
  private var recoveryFeedTask: Task<Void, Never>?
  /// High-water mark of `capturedSamples` already handed to the writer, so the
  /// clean-stop tail is `captureResult.samples[recoveryFedSampleCount...]`.
  private var recoveryFedSampleCount: Int = 0
  /// Single-finalize guard across the clean-stop vs XPC-invalidation race
  /// (the writer is also idempotent; this avoids even queuing the second call).
  private var recoveryFinalized: Bool = false

  /// #1408 A3 (Codex code-diff r6): the `operationID` of the begin op that owns
  /// the LIVE capture. Echoed in `maxDurationReachedTriggered` so the host can
  /// reject a maximally delayed relay that would otherwise stop a LATER
  /// recording. Overwritten by every `beginCapture`; never cleared — a stale
  /// value is inert because the proxy compares against ITS active begin op,
  /// which is nil outside a session. MainActor-confined (written in
  /// `beginCapture`'s MainActor task, read in the manager callback).
  private var activeBeginOperationID: String?

  /// Get or create the capture manager on MainActor, wiring callbacks on first creation.
  @MainActor
  private var captureManager: AudioCaptureManager {
    if let existing = _captureManager { return existing }
    let manager = AudioCaptureManager()
    wireCallbacks(on: manager)
    _captureManager = manager
    return manager
  }

  /// Wire AudioCaptureManager callbacks to XPC client proxy calls.
  @MainActor
  private func wireCallbacks(on manager: AudioCaptureManager) {
    // Buffer callback: fires on CoreAudio's real-time audio thread.
    // RT discipline: only arithmetic + bounded memcpy on the RT thread.
    // XPC send dispatched to xpcSendQueue.
    manager.onBufferCaptured = { [weak self] buffer in
      guard let floatData = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      guard count > 0 else { return }

      // RMS: tight arithmetic loop — no heap allocation, RT-safe.
      // Matches AudioBufferProcessor.calculateRMS formula: -60dB..0dB → 0..1
      var sum: Float = 0
      for i in 0..<count { sum += floatData[i] * floatData[i] }
      let rms = sqrt(sum / Float(count))
      let dBFS = 20 * log10(max(rms, 1e-6))
      let level = max(0, min(1, (dBFS + 60) / 60))

      // Capture buffer to keep its memory alive across the queue hop.
      // Data(bytes:count:) does malloc — moved off RT thread to xpcSendQueue.
      nonisolated(unsafe) let safeBuffer = buffer
      self?.xpcSendQueue.async { [weak self] in
        guard let floats = safeBuffer.floatChannelData?[0] else { return }
        let data = Data(bytes: floats, count: count * MemoryLayout<Float>.size)
        self?.clientProxy?.audioBufferCaptured(data, frameCount: count, audioLevel: level)
      }
    }

    // Engine interruption callback: fires on @MainActor. Relay the cause's raw
    // value across XPC. The host preserves `.deviceRemoved` (the helper ran the
    // liveness check; the host cannot re-run it) and collapses every other loss
    // cause to `.engineLost` (AVCaptureSession interruptions have no separate
    // relay across the boundary, so they have no other owner there). See
    // `AudioCaptureProxy.engineInterrupted(cause:)` (issue #1174 A3; the
    // max-duration cap left this channel in #1408 A3 — it relays via
    // `maxDurationReachedTriggered` below).
    manager.onEngineInterrupted = { [weak self] cause in
      let raw = cause.rawValue
      self?.xpcSendQueue.async { [weak self] in
        self?.clientProxy?.engineInterrupted(cause: raw)
      }
    }

    // #1408 A3: the hard sample-count backstop is a NORMAL auto-stop, relayed
    // on its own event channel (beside `vadAutoStopTriggered`) — never through
    // the interruption relay above. The manager has already stopped appending
    // locally, so helper memory stays bounded even if this event never lands.
    manager.onMaxDurationReached = { [weak self] in
      // Snapshot the owning begin op on the MainActor (where it is written)
      // BEFORE hopping to the send queue.
      guard let self else { return }
      let owningOperationID = self.activeBeginOperationID ?? ""
      self.xpcSendQueue.async { [weak self] in
        self?.clientProxy?.maxDurationReachedTriggered(operationID: owningOperationID)
      }
    }
  }

  // MARK: - Diagnostics

  func ping(reply: @escaping (String) -> Void) {
    reply("pong")
  }

  func checkMicPermission(reply: @escaping (Int, String) -> Void) {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    let name: String
    switch status {
    case .notDetermined: name = "notDetermined"
    case .restricted: name = "restricted"
    case .denied: name = "denied"
    case .authorized: name = "authorized"
    @unknown default: name = "unknown(\(status.rawValue))"
    }
    reply(status.rawValue, name)
  }

  // MARK: - Configuration

  func buildEngine(noiseSuppression: Bool) {
    Task { @MainActor in
      captureManager.buildEngine(noiseSuppression: noiseSuppression)
    }
  }

  func setNoiseSuppressionEnabled(_ enabled: Bool) {
    Task { @MainActor in
      captureManager.noiseSuppressionEnabled = enabled
    }
  }

  func setPreferredInputDeviceUID(_ uid: String) {
    Task { @MainActor in
      captureManager.preferredInputDeviceIDOverride = uid
    }
  }

  func setSelectedInputDeviceUID(_ uid: String) {
    Task { @MainActor in
      captureManager.selectedInputDeviceUID = uid
    }
  }

  func setWarmEnginePolicy(_ rawValue: String) {
    let policy = WarmEnginePolicy(rawValue: rawValue) ?? .seconds30
    Task { @MainActor in
      captureManager.warmEnginePolicy = policy
    }
  }

  // MARK: - Lifecycle

  func startEnginePhase(
    operationID: String,
    preferredDeviceUID: String,
    selectedDeviceUID: String,
    reply: @escaping (NSError?) -> Void
  ) {
    let signal = XPCOperationSignalFile.audio.makeEmitter(operationID: operationID)
    signal.emit(stage: "audio.start_engine.received")
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      signal.emit(stage: "audio.start_engine.main_actor")
      let previousLifecycleSignal = captureManager.onLifecycleSignal
      captureManager.onLifecycleSignal = { phase in
        signal.emit(stage: "audio.start_engine.\(phase)")
      }
      defer { captureManager.onLifecycleSignal = previousLifecycleSignal }
      captureManager.preferredInputDeviceIDOverride = preferredDeviceUID
      captureManager.selectedInputDeviceUID = selectedDeviceUID
      do {
        signal.emit(stage: "audio.start_engine.prepare_entered")
        try await captureManager.startEnginePhase()
        signal.emit(stage: "audio.start_engine.prepare_completed")
        safeReply(nil)
      } catch {
        signal.emit(stage: "audio.start_engine.failed", detail: error.localizedDescription)
        // XPC error sanitization boundary.
        safeReply(XPCErrorSanitizer.sanitizeForXPC(error))
      }
    }
  }

  func waitForFormatStabilization(
    maxWait: Double,
    pollInterval: Double,
    reply: @escaping (Bool) -> Void
  ) {
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      let result = await captureManager.waitForFormatStabilization(
        maxWait: maxWait,
        pollInterval: pollInterval
      )
      safeReply(result)
    }
  }

  func beginCapture(
    operationID: String, recoveryPayload: Data?, reply: @escaping (NSError?) -> Void
  ) {
    let signal = XPCOperationSignalFile.audio.makeEmitter(operationID: operationID)
    signal.emit(stage: "audio.begin_capture.received")
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      signal.emit(stage: "audio.begin_capture.main_actor")
      // #1408 A3 (Codex code-diff r6): remember which begin op owns the live
      // capture so the max-duration relay can carry session identity — the
      // host rejects an echo that does not match its ACTIVE begin op, so a
      // maximally delayed callback can never stop a LATER recording.
      self.activeBeginOperationID = operationID
      let previousLifecycleSignal = self.captureManager.onLifecycleSignal
      self.captureManager.onLifecycleSignal = { phase in
        signal.emit(stage: "audio.begin_capture.\(phase)")
      }
      defer { self.captureManager.onLifecycleSignal = previousLifecycleSignal }
      do {
        signal.emit(stage: "audio.begin_capture.source_entered")
        _ = try await self.captureManager.beginCapturePhase()
        signal.emit(stage: "audio.begin_capture.source_completed")
        self.startVADMonitoring()
        signal.emit(stage: "audio.begin_capture.vad_started")
        // Crash-recovery limb: arm the spool from the directive. Fail-open —
        // never throws, never gates the reply (heart path is byte-identical).
        self.startRecoverySpooling(payload: recoveryPayload)
        safeReply(nil)
      } catch {
        signal.emit(stage: "audio.begin_capture.failed", detail: error.localizedDescription)
        // XPC error sanitization boundary.
        safeReply(XPCErrorSanitizer.sanitizeForXPC(error))
      }
    }
  }

  func stopCapture(operationID: String, reply: @escaping (Data, Data, Data?) -> Void) {
    let signal = XPCOperationSignalFile.audio.makeEmitter(operationID: operationID)
    signal.emit(stage: "audio.stop_capture.received")
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      signal.emit(stage: "audio.stop_capture.main_actor")
      let previousLifecycleSignal = self.captureManager.onLifecycleSignal
      self.captureManager.onLifecycleSignal = { phase in
        signal.emit(stage: "audio.stop_capture.\(phase)")
      }
      defer { self.captureManager.onLifecycleSignal = previousLifecycleSignal }
      self.cancelVADMonitoring()
      signal.emit(stage: "audio.stop_capture.vad_cancelled")

      // Stop capture first: freezes the tap, returns all accumulated samples,
      // clears the internal buffer. No new samples can arrive after this.
      signal.emit(stage: "audio.stop_capture.source_entered")
      let captureResult = await self.captureManager.stopCapture()
      signal.emit(stage: "audio.stop_capture.source_completed")

      // Finalize VAD using the EXACT count of returned samples. This guarantees
      // segment endpoints align perfectly with the sample array the caller receives.
      // Using captureResult.samples.count (not capturedSamples.count) avoids both:
      // - The original bug: capturedSamples already cleared -> count=0 -> endSample=0
      // - The race window: samples arriving during await -> count drift -> tail trim
      var vadData = Data()
      if let detector = self.silenceDetector {
        signal.emit(stage: "audio.stop_capture.vad_finalize_entered")
        await detector.finalizeSegments(totalSampleCount: captureResult.samples.count)
        let segments = await detector.speechSegments
        signal.emit(stage: "audio.stop_capture.vad_finalize_completed")
        vadData = Data(capacity: segments.count * MemoryLayout<Int32>.size * 2)
        for seg in segments {
          var start = Int32(seg.startSample)
          var end = Int32(seg.endSample)
          vadData.append(Data(bytes: &start, count: MemoryLayout<Int32>.size))
          vadData.append(Data(bytes: &end, count: MemoryLayout<Int32>.size))
        }
      }

      let sampleData = captureResult.samples.withUnsafeBytes { Data($0) }
      // #1434: capture-health metadata rides the same atomic reply — the host
      // proxy decodes it back into the identical `CaptureStopMetadata`, so
      // both stop paths yield the same `CaptureResult.metadata`. Encode
      // failure degrades to nil (diagnostic limb; never blocks the reply).
      let metadataData = captureResult.metadata.flatMap { try? JSONEncoder().encode($0) }
      signal.emit(stage: "audio.stop_capture.reply_ready")
      safeReply(sampleData, vadData, metadataData)

      // Crash-recovery limb (AFTER the heart-path reply so it never delays
      // delivery): write the final tail beyond what the poll loop fed, then
      // finalize. Uses the authoritative `captureResult.samples`, never the
      // now-cleared live buffer. Fail-open.
      self.stopRecoverySpooling(tail: captureResult.samples)
    }
  }

  func abortPreWarm() {
    Task { @MainActor in
      self.cancelVADMonitoring()
      self.captureManager.abortPreWarm()
    }
  }

  func rebuildEngine() {
    Task { @MainActor in
      captureManager.rebuildEngine()
    }
  }

  // MARK: - VAD (Step 5)

  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {
    self.vadAutoStop = autoStop
    self.vadSilenceTimeout = silenceTimeout
    self.vadSensitivity = sensitivity
    self.vadEnergyGate = energyGate

    // If VAD is already running mid-session, rebuild the detector with new config.
    if let detector = silenceDetector {
      let config = SmoothedVADConfig.fromSensitivity(sensitivity, energyGate: energyGate)
      Task { await detector.updateConfig(config) }
    }
  }

  func getSamplesSnapshot(fromIndex: Int, reply: @escaping (Data, Int) -> Void) {
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor in
      let (samples, totalCount) = await self.captureManager.getSamplesSnapshot(fromIndex: fromIndex)
      let data = samples.withUnsafeBytes { Data($0) }
      safeReply(data, totalCount)
    }
  }

  func getVADSegments(reply: @escaping (Data) -> Void) {
    nonisolated(unsafe) let safeReply = reply
    Task { @MainActor [weak self] in
      guard let self, let detector = self.silenceDetector else {
        safeReply(Data())
        return
      }
      // Finalize any open segment before returning.
      let totalCount = self.captureManager.capturedSamples.count
      await detector.finalizeSegments(totalSampleCount: totalCount)
      let segments = await detector.speechSegments

      // Encode as packed [Int32 start, Int32 end] pairs.
      var packed = Data(capacity: segments.count * MemoryLayout<Int32>.size * 2)
      for seg in segments {
        var start = Int32(seg.startSample)
        var end = Int32(seg.endSample)
        packed.append(Data(bytes: &start, count: MemoryLayout<Int32>.size))
        packed.append(Data(bytes: &end, count: MemoryLayout<Int32>.size))
      }
      safeReply(packed)
    }
  }

  // MARK: - Service-side VAD monitoring (Step 5)

  /// Start the VAD monitoring task. Called after beginCapture succeeds.
  @MainActor
  private func startVADMonitoring() {
    let config = SmoothedVADConfig.fromSensitivity(vadSensitivity, energyGate: vadEnergyGate)

    let detector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
    self.silenceDetector = detector

    vadMonitorTask = Task { @MainActor [weak self] in
      // Prepare the VAD model
      do {
        try await detector.prepare()
      } catch {
        // #1177 (Telemetry Bible Phase 8b, A4): the VAD model failed to load, so
        // silence auto-stop is silently disabled for this recording (the user must
        // stop manually). Previously a bare `return` with not even a log. Report it
        // as an in-process handled error (this runs in the audio XPC service, which
        // has its own Sentry but cannot reach the host's PostHog / SentryBreadcrumb).
        // Content-free (error type name only); fail-open continues — the heart path
        // (capture) is unaffected, only the auto-stop limb is lost.
        HelperObservability.captureHandledError(
          category: "vad#prepare_failed", detail: String(reflecting: type(of: error)))
        return
      }

      await detector.reset()

      var processedSampleCount = 0
      let chunkSize = SilenceDetector.chunkSize

      while !Task.isCancelled {
        guard let self else { return }
        let manager = self.captureManager
        guard manager.isCapturing else { return }

        let currentCount = manager.capturedSamples.count

        while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
          let endIdx = processedSampleCount + chunkSize
          let chunk = Array(manager.capturedSamples[processedSampleCount..<endIdx])

          let shouldStop = await detector.processChunk(chunk)

          if shouldStop && self.vadAutoStop {
            // Fire vadAutoStopTriggered to the host app.
            self.xpcSendQueue.async { [weak self] in
              self?.clientProxy?.vadAutoStopTriggered()
            }
            return
          }

          processedSampleCount += chunkSize
          await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  /// Cancel VAD monitoring. Called on stopCapture and abortPreWarm.
  @MainActor
  private func cancelVADMonitoring() {
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
  }

  // MARK: - Crash-recovery spool (#1063 PR1)

  /// Decode the directive and arm the spool writer + feed loop. Fail-open: any
  /// decode/preflight failure leaves recovery off and capture byte-identical.
  @MainActor
  private func startRecoverySpooling(payload: Data?) {
    recoveryFinalized = false
    recoveryFedSampleCount = 0
    recoverySpoolWriter = nil
    guard let payload,
      let directive = try? JSONDecoder().decode(RecoverySpoolDirective.self, from: payload),
      directive.enabled
    else { return }
    // Low-disk preflight: don't start a spool when free space is already below
    // the watermark the heart path needs (History save / ASR temp / model cache).
    guard Self.hasSufficientDiskSpace(forSpoolAt: directive.spoolPath) else { return }

    let writer = RecoverySpoolWriter(
      recoverySessionID: directive.recoverySessionID,
      spoolURL: URL(fileURLWithPath: directive.spoolPath),
      cipher: RecoverySpoolCipher(directive: directive),
      settings: directive.settingsSnapshot)
    writer.start()
    recoverySpoolWriter = writer
    startRecoveryFeed(writer: writer, spoolPath: directive.spoolPath)
  }

  /// Poll the authoritative `capturedSamples` and append new ranges to the
  /// writer — mirrors `startVADMonitoring`. Lossless (the same buffer
  /// `stopCapture` returns), off the RT thread, batched at ~`chunkIntervalSeconds`.
  @MainActor
  private func startRecoveryFeed(writer: RecoverySpoolWriter, spoolPath: String) {
    recoveryFeedTask = Task { @MainActor [weak self] in
      var pollCount = 0
      let flushEvery = max(
        1,
        Int(
          (RecoveryConstants.flushIntervalSeconds / RecoveryConstants.chunkIntervalSeconds)
            .rounded()))
      while !Task.isCancelled {
        guard let self else { return }
        let manager = self.captureManager
        guard manager.isCapturing, writer.isHealthy else { return }

        let currentCount = manager.capturedSamples.count
        if currentCount > self.recoveryFedSampleCount {
          let chunk = Array(manager.capturedSamples[self.recoveryFedSampleCount..<currentCount])
          writer.append(chunk)
          self.recoveryFedSampleCount = currentCount
        }

        pollCount += 1
        if pollCount % flushEvery == 0 {
          writer.flush()
          // Low-disk watermark re-check: stop spooling with an honest terminal
          // marker before recovery can starve the disk the heart path needs.
          if !Self.hasSufficientDiskSpace(forSpoolAt: spoolPath) {
            self.finalizeRecovery(.lowDiskWatermark)
            return
          }
        }

        try? await Task.sleep(for: .seconds(RecoveryConstants.chunkIntervalSeconds))
      }
    }
  }

  /// Clean stop: feed the final tail beyond what the poll loop wrote, then
  /// finalize with the clean marker. Runs once (guarded).
  @MainActor
  private func stopRecoverySpooling(tail: [Float]) {
    guard !recoveryFinalized, let writer = recoverySpoolWriter else { return }
    recoveryFinalized = true
    recoveryFeedTask?.cancel()
    recoveryFeedTask = nil
    if tail.count > recoveryFedSampleCount {
      writer.append(Array(tail[recoveryFedSampleCount...]))
    }
    writer.flush()
    writer.finalize(reason: .cleanFinalized)
    recoverySpoolWriter = nil
  }

  /// Finalize the spool for a non-clean reason (low disk, helper interrupted).
  /// Guarded so clean-stop and invalidation cannot both write a terminal marker.
  @MainActor
  private func finalizeRecovery(_ reason: RecoverySpoolTerminationReason) {
    guard !recoveryFinalized, let writer = recoverySpoolWriter else { return }
    recoveryFinalized = true
    recoveryFeedTask?.cancel()
    recoveryFeedTask = nil
    writer.finalize(reason: reason)
    recoverySpoolWriter = nil
  }

  /// Best-effort flush when the host (app) disconnects mid-recording. The helper
  /// process outlives the disconnected client, so the async finalize on the
  /// writer's serial queue typically drains and already-written frames are
  /// OS-durable; the ~3 s periodic flush + valid-prefix recovery are the real
  /// durability floor (not a guaranteed zero tail).
  func flushRecoveryOnInvalidation() {
    Task { @MainActor [weak self] in self?.finalizeRecovery(.interrupted) }
  }

  /// True when the spool volume has at least the low-disk watermark free. Reads
  /// the spool's parent directory (the file may not exist yet; the host created
  /// the directory before handing over the path). Fail-open: an unreadable
  /// value arms recovery anyway — the writer's backpressure cap is the backstop.
  private static func hasSufficientDiskSpace(forSpoolAt path: String) -> Bool {
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    guard
      let values = try? dir.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let available = values.volumeAvailableCapacityForImportantUsage
    else { return true }
    return available >= RecoveryConstants.lowDiskWatermarkBytes
  }
}
