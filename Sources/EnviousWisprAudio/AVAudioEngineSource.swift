@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import os

/// Diagnostic logger for BT crash investigation — safe from any thread including RT audio.
/// Uses os_log under the hood (lock-free, no heap allocation on the log path).
private let btCrashLogger = Logger(subsystem: "com.enviouswispr", category: "BTCrashDiag")

/// Thread-safe stop token shared between the audio tap handler and the
/// `AVAudioEngineConfigurationChange` observer.
///
/// The config-change observer flips this IMMEDIATELY on CoreAudio's thread
/// (via `setFromConfigChange`), before any MainActor dispatch. The tap handler
/// checks `isSet()` at the top of every invocation and bails out instantly,
/// closing the race window between the BT event and main-thread recovery.
///
/// Uses `os_unfair_lock` to guarantee visibility across the real-time audio
/// thread and the main thread without priority inversion.
private final class TapStoppedFlag: Sendable {
  private struct State: Sendable {
    var stopped = false
    var configChangeTime: CFAbsoluteTime = 0
  }

  private let _lock = OSAllocatedUnfairLock(initialState: State())

  /// Mark as stopped (from main thread teardown paths).
  func set() {
    _lock.withLock { $0.stopped = true }
  }

  /// Mark as stopped from a config-change notification — records monotonic
  /// timestamp for race-window measurement.
  func setFromConfigChange() {
    _lock.withLock {
      $0.stopped = true
      $0.configChangeTime = CFAbsoluteTimeGetCurrent()
    }
  }

  func isSet() -> Bool {
    _lock.withLock { $0.stopped }
  }

  /// Reset for reuse after codec-switch recovery rebuilds the tap.
  func reset() {
    _lock.withLock { $0 = State() }
  }

  /// Timestamp of the last config-change stop, or 0 if none.
  func lastConfigChangeTime() -> CFAbsoluteTime {
    _lock.withLock { $0.configChangeTime }
  }
}

/// Cross-thread set-once latch for "did any buffer reach the tap this session."
/// Main actor reads at watchdog-fire time; the tap thread marks on first buffer.
/// `OSAllocatedUnfairLock` avoids Swift Atomics dependency; the cost is trivial
/// because the tap checks a tap-local cache first (see `TapLocalSeenCache`).
private final class CaptureLivenessState: Sendable {
  private let _lock = OSAllocatedUnfairLock(initialState: false)
  func markReceived() { _lock.withLock { $0 = true } }
  func wasReceived() -> Bool { _lock.withLock { $0 } }
  func reset() { _lock.withLock { $0 = false } }
}

/// Tap-thread-local one-shot latch. Captured by the tap closure so the first
/// buffer of a session takes the cross-thread lock exactly once; subsequent
/// buffers skip it. Main actor resets before arming the watchdog so the next
/// session rearms the latch. Races are benign — a stale `true` costs at most
/// one missed mark, and the following buffer re-marks correctly.
private final class TapLocalSeenCache: @unchecked Sendable {
  var alreadyMarkedThisSession = false
}

/// Convert a Swift Duration to milliseconds as an Int for logging.
private func ms(_ d: Duration) -> Int {
  let (seconds, attoseconds) = d.components
  return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

/// AVAudioEngine-based audio capture source. Supports voice processing (noise suppression)
/// and Bluetooth codec switch recovery.
///
/// This is a pure extraction from AudioCaptureManager — all logic moved as-is.
/// Owns the engine, tap, converter, config-change observer, and codec switch recovery.
@MainActor
final class AVAudioEngineSource: AudioInputSource {

  // MARK: - AudioInputSource callbacks

  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onInterrupted: ((EngineInterruptionCause) -> Void)?
  var onLifecycleSignal: (@Sendable (String) -> Void)?

  // MARK: - Round-4 telemetry (issue #285) — capture liveness watchdog.

  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  /// Direct engine source has no AVCaptureSession layer; callback stays nil.
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
  private(set) var captureGeneration: UInt64 = 0

  nonisolated let captureSourceType: String = "av_audio_engine"

  /// Set-once latch the tap flips on first buffer; watchdog reads at fire time.
  private let captureLiveness = CaptureLivenessState()
  /// Tap-thread-local cache that lets the tap skip the cross-thread lock after
  /// the first buffer of a session. Reset by `startCapture` before arming.
  private let tapLocalSeen = TapLocalSeenCache()
  /// Private serial queue for the stall-detection `DispatchWorkItem`.
  private static let stallQueue = DispatchQueue(
    label: "com.enviouswispr.audio.capture-stall"
  )
  /// Pending watchdog; cancelled on stop / deactivate / new session.
  private var stallWorkItem: DispatchWorkItem?

  // MARK: - State

  private(set) var isCapturing = false
  var isRunning: Bool { engine.isRunning }

  /// Whether noise suppression via Apple Voice Processing is enabled.
  var noiseSuppressionEnabled = false

  /// Persistent UID of the selected input device. Empty string means system default.
  var selectedInputDeviceUID: String = ""

  /// User override for input device. Empty string means "Auto" (smart selection enabled).
  var preferredInputDeviceIDOverride: String = ""

  #if DEBUG
    /// Bench-only bypass of the BT-output force-nil (#1377 candidate C). When
    /// true, `startCapture`'s device resolution does NOT skip `setInputDevice`
    /// under BT output, so the engine targets the user-selected (Bluetooth)
    /// device instead of the crash-dodge nil. Set ONLY under a
    /// `CaptureSourcePolicy` force-case by the bake-off; the `.automatic` route
    /// leaves it false, so the shipped crash-dodge is unchanged. Compiled out
    /// of release entirely.
    var benchBypassBTOutputForceNil = false
  #endif

  /// The CoreAudio device ID currently in use.
  private(set) var currentInputDeviceID: AudioDeviceID?

  #if DEBUG
    /// Whether the most recent `setInputDevice` actually bound the requested
    /// device — `AudioUnitSetProperty` returned noErr. A failed set does NOT
    /// throw, so this is the #1377 bench's proof the REQUESTED device bound
    /// rather than being silently ignored. True on the default/no-op path (no
    /// explicit device to bind). Read only by `logBenchCaptureEvidence()`.
    private var lastInputDeviceBindOK = true
  #endif

  // MARK: - Private state

  private var engine = AVAudioEngine()
  private var converter: AVAudioConverter?  // periphery:ignore - retains converter to prevent deallocation while tap is active
  private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private var configChangeObserver: (any NSObjectProtocol)?
  private var activeTasks: [Task<Void, Never>] = []
  private var tapStoppedFlag: TapStoppedFlag?
  private var isRecovering = false
  private var forwarder: PreRollForwarder?

  #if DEBUG
    var debugZeroFillController: DebugZeroFillController?
  #endif

  /// Called when an audio device operation fails.
  var onDeviceError: ((String) -> Void)?

  /// #1434: stop-time capture health. The engine path exposes the input
  /// node's live rate only (its converter/ring internals predate the counter
  /// instrumentation and have their own, battle-tested diagnostics); nil when
  /// the engine isn't running.
  var captureStopMetadata: CaptureStopMetadata? {
    guard engine.isRunning else { return nil }
    // Hardware format: after `setInputDevice` binds a device, `outputFormat` lags
    // the real rate, so reporting it here would tell us 48000 for exactly the
    // bound-device recordings this telemetry exists to diagnose.
    let rate = engine.inputNode.inputFormat(forBus: 0).sampleRate
    guard rate > 0 else { return nil }
    return CaptureStopMetadata(nativeRateHz: rate)
  }

  // NOTE: onPartialSamples removed — the manager owns `capturedSamples` and keeps
  // holding them across a device disconnect. It does not itself recover anything:
  // #1408 made `RecordingSessionKernel` decide, at the recording exit, whether the
  // interruption left recoverable audio and to transcribe it if so.

  // MARK: - Constants

  nonisolated static let targetSampleRate: Double = 16000
  nonisolated static let targetChannels: AVAudioChannelCount = 1

  // MARK: - Lifecycle

  func prepare() async throws {
    guard !engine.isRunning else {
      onLifecycleSignal?("engine_prepare_already_running")
      return
    }
    let prepareStart = ContinuousClock.now

    activeTasks.removeAll()

    // Step 1: Voice Processing FIRST — creates the final AudioUnit type (AUVPIO vs AUHAL).
    // CRITICAL: Must happen before setInputDevice(). If setInputDevice() runs first, it
    // instantiates an AUHAL. Then setVoiceProcessingEnabled(true) DESTROYS that AUHAL and
    // creates an AUVPIO. CoreAudio's BT I/O thread still holds a reference to the destroyed
    // AUHAL -> use-after-free -> heap corruption -> EXC_BAD_ACCESS.
    //
    // Split-route check: when input != output device (e.g., built-in mic + BT headphones),
    // CoreAudio's AEC can't sync different hardware clocks. Disable VP in this case.
    let vpStart = ContinuousClock.now
    onLifecycleSignal?("engine_voice_processing_entered")
    let inputDeviceID = AudioDeviceEnumerator.defaultInputDeviceID()
    let outputDeviceID = AudioDeviceEnumerator.defaultOutputDeviceID()
    let isSplitRoute =
      inputDeviceID != nil && outputDeviceID != nil && inputDeviceID != outputDeviceID
    let effectiveNoiseSuppression = noiseSuppressionEnabled && !isSplitRoute

    if isSplitRoute && noiseSuppressionEnabled {
      btCrashLogger.info(
        "Split route detected (input=\(inputDeviceID ?? 0) output=\(outputDeviceID ?? 0)) — disabling VP (AEC can't sync different clocks)"
      )
    }

    if effectiveNoiseSuppression {
      do {
        try engine.inputNode.setVoiceProcessingEnabled(true)
      } catch {
        Task {
          await AppLogger.shared.log(
            "Voice processing unavailable: \(error.localizedDescription). Continuing without noise suppression.",
            level: .info, category: "Audio"
          )
        }
      }
    } else {
      try? engine.inputNode.setVoiceProcessingEnabled(false)
    }
    onLifecycleSignal?("engine_voice_processing_completed")
    let vpMs = ms(ContinuousClock.now - vpStart)

    // Step 2: Resolve input device — smart selection when in Auto mode.
    // SAFETY: Skip setInputDevice() entirely when BT output is active.
    let deviceStart = ContinuousClock.now
    onLifecycleSignal?("engine_input_device_entered")
    let btOutputActive: Bool
    if let outID = AudioDeviceEnumerator.defaultOutputDeviceID() {
      btOutputActive = AudioDeviceEnumerator.isBluetoothDevice(outID)
    } else {
      btOutputActive = false
    }

    // #1377 candidate C: the bake-off can bypass the BT-output force-nil to
    // target a Bluetooth mic under BT output. In release (or on `.automatic`)
    // the crash-dodge always stands — `benchBypassBTOutputForceNil` is
    // DEBUG-only and never set by the automatic route.
    var forceNilUnderBTOutput = btOutputActive
    #if DEBUG
      if benchBypassBTOutputForceNil { forceNilUnderBTOutput = false }
    #endif

    let resolvedDeviceID: AudioDeviceID?
    if forceNilUnderBTOutput {
      // BT output active — skip device switch.
      // Forcing built-in mic via setInputDevice crashes the XPC service.
      // Root cause: CoreAudio creates corrupted CADefaultDeviceAggregate.
      // Path forward: AVCaptureSessionSource handles BT case.
      resolvedDeviceID = nil
      btCrashLogger.info(
        "BT output active — skipping setInputDevice (aggregate device crash prevention)")
    } else if !preferredInputDeviceIDOverride.isEmpty {
      resolvedDeviceID = AudioDeviceEnumerator.deviceID(forUID: preferredInputDeviceIDOverride)
    } else if !selectedInputDeviceUID.isEmpty {
      resolvedDeviceID = AudioDeviceEnumerator.deviceID(forUID: selectedInputDeviceUID)
    } else if let recommended = AudioDeviceEnumerator.recommendedInputDevice() {
      resolvedDeviceID = recommended
      Task {
        await AppLogger.shared.log(
          "Smart device selection: using built-in mic (BT output detected with active media)",
          level: .info, category: "Audio"
        )
      }
    } else {
      resolvedDeviceID = nil
    }
    try setInputDevice(resolvedDeviceID)
    currentInputDeviceID = resolvedDeviceID ?? AudioDeviceEnumerator.defaultInputDeviceID()
    onLifecycleSignal?("engine_input_device_completed")
    let deviceMs = ms(ContinuousClock.now - deviceStart)

    // Create the capture stop token for this session
    let stopToken = TapStoppedFlag()
    self.tapStoppedFlag = stopToken

    // Register for engine configuration changes
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    configChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      stopToken.setFromConfigChange()
      btCrashLogger.info("Config change notification — stop token flipped immediately")

      Task { @MainActor in
        await self?.handleEngineConfigurationChange()
      }
    }

    let engineStartTime = ContinuousClock.now
    btCrashLogger.info("Engine starting — stop token created, observer registered (queue: nil)")
    onLifecycleSignal?("engine_start_entered")
    try engine.start()
    onLifecycleSignal?("engine_start_completed")
    let engineMs = ms(ContinuousClock.now - engineStartTime)
    btCrashLogger.info("Engine started successfully")

    // Install pre-roll tap immediately after engine start.
    // The tap routes through a PreRollForwarder that buffers audio until
    // startCapture() activates live forwarding.
    //
    // Read the hardware format, not `outputFormat`. `setInputDevice` above binds
    // a device onto the input node's audio unit; after that bind `outputFormat`
    // keeps reporting the pre-bind rate while `inputFormat` tracks the device.
    // `installTap` asserts `format.sampleRate == inputHWFormat.sampleRate` and
    // raises an uncatchable ObjC exception on mismatch, aborting this helper.
    let tapStart = ContinuousClock.now
    onLifecycleSignal?("engine_preroll_tap_entered")
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)

    // A device still transitioning can report 0 Hz / 0 channels here. Feeding
    // that to AVAudioConverter yields nil, and the guards below must not leave a
    // running engine with no forwarder: `prepare()` would then short-circuit on
    // `engine.isRunning` forever and every `startCapture()` would throw
    // `missing_forwarder` — a permanent wedge.
    //
    // Tear down before throwing. `withStartRetry` does NOT retry this (it matches
    // only a wedged line or `serviceUnreachable`), so THIS recording fails; the
    // teardown is what lets the NEXT `prepare()` rebuild instead of short-circuiting.
    // One failed press beats a dead session.
    guard Self.isUsable(inputFormat) else {
      btCrashLogger.error(
        "Pre-roll: hardware format not yet usable (\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch) — tearing down for retry"
      )
      teardownEngine()
      throw AudioError.formatCreationFailed(
        source: "AVAudioEngineSource.prepare.unusable_hardware_format")
    }

    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.targetSampleRate,
        channels: Self.targetChannels,
        interleaved: false
      )
    else {
      btCrashLogger.error("Pre-roll: failed to create target format — tearing down for retry")
      teardownEngine()
      throw AudioError.formatCreationFailed(source: "AVAudioEngineSource.prepare.target_format")
    }

    guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      btCrashLogger.error(
        "Pre-roll: failed to create converter from \(inputFormat) — tearing down for retry")
      teardownEngine()
      throw AudioError.formatCreationFailed(source: "AVAudioEngineSource.prepare.converter")
    }
    self.converter = audioConverter

    let fwd = PreRollForwarder()
    self.forwarder = fwd
    #if DEBUG
      fwd.debugZeroFillController = debugZeroFillController
    #endif

    let tapHandler = Self.makeTapHandler(
      audioConverter: audioConverter,
      targetFormat: targetFormat,
      inputFormat: inputFormat,
      forwarder: fwd,
      stoppedFlag: stopToken,
      liveness: captureLiveness,
      tapLocal: tapLocalSeen
    )
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: tapHandler)
    onLifecycleSignal?("engine_preroll_tap_completed")
    let tapMs = ms(ContinuousClock.now - tapStart)
    let totalMs = ms(ContinuousClock.now - prepareStart)
    AudioCaptureManager.btRouteLog(
      "COLD-START prepare(): total=\(totalMs)ms | vp=\(vpMs)ms device=\(deviceMs)ms engine.start=\(engineMs)ms tap=\(tapMs)ms | vp=\(effectiveNoiseSuppression) bt=\(btOutputActive)"
    )
  }

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard let fwd = forwarder else {
      throw AudioError.formatCreationFailed(
        source: "AVAudioEngineSource.startCapture.missing_forwarder")
    }

    // Reset stoppedFlag in case a config change happened during pre-roll
    tapStoppedFlag?.reset()

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
      self.bufferContinuation = continuation
    }

    // Two-step activation: snapshot ring, feed pre-roll, commit, feed delta.
    _ = fwd.activate(
      onSamples: self.onSamples,
      onBuffer: self.onBufferCaptured,
      continuation: self.bufferContinuation,
      logPrefix: "Pre-roll"
    )

    captureGeneration &+= 1
    captureLiveness.reset()
    tapLocalSeen.alreadyMarkedThisSession = false
    armCaptureStallWatchdog()

    isCapturing = true
    #if DEBUG
      logBenchCaptureEvidence()
    #endif
    return stream
  }

  #if DEBUG
    /// Capture-side actual-bound-device evidence (#1377 §3.5). Emitted at every
    /// capture START (not just cold `prepare()`), so a warm-reuse bench trial —
    /// where `prepare()` early-returns on the already-running engine — still logs
    /// a fresh source row the harness can read. `boundUID` is the EXACT bound
    /// device (so candidate C proves the requested device bound, not merely a
    /// non-built-in transport); `boundTransport` characterizes it (bluetooth vs
    /// built_in); `benchBypass` records whether the BT-output dodge was skipped.
    private func logBenchCaptureEvidence() {
      // `bindOK` is the proof the REQUESTED device actually bound: setInputDevice
      // does NOT throw when `AudioUnitSetProperty` fails (it logs + fires
      // `onDeviceError` and returns), and line 263 sets `currentInputDeviceID` to
      // the requested device regardless — so `boundUID` alone would falsely
      // report a HAL-rejected Bluetooth device as bound. `bindOK=false` lets the
      // harness FAIL that trial. Reading back `kAudioOutputUnitProperty_CurrentDevice`
      // was rejected: on the default path AVAudioEngine wraps input in a private
      // `CADefaultDeviceAggregate`, so a read-back reports an aggregate UID that
      // no requested-device check could match. `bindOK` sidesteps that. (Cloud
      // review P2.)
      let boundTransport =
        currentInputDeviceID.flatMap { AudioDeviceEnumerator.transportLabel(for: $0) } ?? "unknown"
      let boundUID =
        currentInputDeviceID.flatMap { AudioDeviceEnumerator.inputDeviceUID(for: $0) } ?? "unknown"
      let requestedUID =
        preferredInputDeviceIDOverride.isEmpty
        ? selectedInputDeviceUID : preferredInputDeviceIDOverride
      AudioCaptureManager.btRouteLog(
        "CAPTURE_EVIDENCE backend=av_audio_engine boundUID=\(boundUID) boundDeviceID=\(currentInputDeviceID.map(String.init) ?? "nil") boundTransport=\(boundTransport) bindOK=\(lastInputDeviceBindOK) requestedUID=\(requestedUID.isEmpty ? "auto" : requestedUID) benchBypass=\(benchBypassBTOutputForceNil)"
      )
    }
  #endif

  /// Schedule a one-shot stall watchdog for the current `captureGeneration`.
  /// Cancels any prior pending item so stale sessions cannot fire.
  private func armCaptureStallWatchdog() {
    stallWorkItem?.cancel()
    let armedSession = captureGeneration
    let armedAtNs = DispatchTime.now().uptimeNanoseconds
    let item = Self.makeStallWorkItem(
      armedSession: armedSession, armedAtNs: armedAtNs, source: self)
    stallWorkItem = item
    Self.stallQueue.asyncAfter(
      deadline: .now() + .milliseconds(TimingConstants.audioCaptureStallWindowMs),
      execute: item
    )
  }

  /// Build the watchdog closure in a nonisolated context so it does NOT inherit
  /// the enclosing `@MainActor` isolation. Without this escape hatch, Swift 6
  /// inserts an executor check that fires `dispatch_assert_queue_fail` when
  /// the work item runs on `stallQueue`.
  nonisolated private static func makeStallWorkItem(
    armedSession: UInt64,
    armedAtNs: UInt64,
    source: AVAudioEngineSource
  ) -> DispatchWorkItem {
    return DispatchWorkItem { [weak source] in
      Task { @MainActor [weak source] in
        source?.captureStallWatchdogFired(
          armedSession: armedSession, armedAtNs: armedAtNs)
      }
    }
  }

  private func captureStallWatchdogFired(armedSession: UInt64, armedAtNs: UInt64) {
    // Guard: session still the one we armed for, still capturing, no buffers.
    guard captureGeneration == armedSession else { return }
    guard isCapturing else { return }
    guard !captureLiveness.wasReceived() else { return }

    let ctx = CaptureStallContext(
      sessionID: armedSession,
      armedAtUptimeNs: armedAtNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: "built_in_mic",
      sourceType: "av_audio_engine",
      engineStartedSuccessfully: engine.isRunning,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: preferredInputDeviceIDOverride.isEmpty
        ? nil : preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      failureMode: .noBuffers
    )
    onCaptureStalled?(ctx)
  }

  func deactivateCapture() {
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.returnToPreRoll()
    isCapturing = false
    bufferContinuation = nil
    AudioCaptureManager.btRouteLog("Engine deactivated — tap stays warm, pre-roll capturing")
  }

  func stop() async -> [Float] {
    // Cancel the stall watchdog; do NOT bump `captureGeneration`. The pipeline
    // reads `audioCapture.currentCaptureSessionID` after stop to dedup the
    // final `no_audio_captured` against the earlier stall event for the same
    // session (#285). Staleness protection for a late-fired watchdog is
    // already provided by `isCapturing == false` in `captureStallWatchdogFired`.
    stallWorkItem?.cancel()
    stallWorkItem = nil

    for task in activeTasks { task.cancel() }
    activeTasks.removeAll()

    forwarder?.stop()
    forwarder = nil

    tapStoppedFlag?.set()
    tapStoppedFlag = nil

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try? engine.inputNode.setVoiceProcessingEnabled(false)
    isCapturing = false
    currentInputDeviceID = nil
    isRecovering = false
    bufferContinuation = nil
    converter = nil
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
    // Source does not own samples — manager accumulates via onSamples callback.
    return []
  }

  /// A hardware format only counts as settled once it is also usable. During a
  /// device transition `inputFormat(forBus:)` can report 0 Hz or 0 channels; two
  /// consecutive *invalid* reads compare equal, so an equality-only check would
  /// call that "stable" and hand an unusable format to converter creation.
  nonisolated static func isUsableFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
    -> Bool
  {
    sampleRate > 0 && channelCount > 0
  }

  private var currentHardwareFormat: AVAudioFormat { engine.inputNode.inputFormat(forBus: 0) }

  nonisolated private static func isUsable(_ format: AVAudioFormat) -> Bool {
    isUsableFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
  }

  func waitForFormatStabilization(
    maxWait: TimeInterval = 1.5,
    pollInterval: TimeInterval = 0.2
  ) async -> Bool {
    // Polls the hardware format — the same accessor the tap install consumes.
    // Waiting on `outputFormat` while installing from `inputFormat` would gate on
    // one signal and act on another.
    let stabStart = ContinuousClock.now
    let deadline = Date().addingTimeInterval(maxWait)
    var lastFormat = currentHardwareFormat
    try? await Task.sleep(for: .milliseconds(10))
    let recheck = currentHardwareFormat
    if recheck == lastFormat, Self.isUsable(recheck) {
      AudioCaptureManager.btRouteLog(
        "COLD-START formatStab: stable on fast path (\(ms(ContinuousClock.now - stabStart))ms, 0 polls)"
      )
      return true
    }
    lastFormat = recheck
    var polls = 0
    while Date() < deadline {
      try? await Task.sleep(for: .seconds(pollInterval))
      polls += 1
      let format = currentHardwareFormat
      if format == lastFormat, Self.isUsable(format) {
        AudioCaptureManager.btRouteLog(
          "COLD-START formatStab: stable after \(polls) polls (\(ms(ContinuousClock.now - stabStart))ms)"
        )
        return true
      }
      lastFormat = format
    }
    AudioCaptureManager.btRouteLog(
      "COLD-START formatStab: TIMED OUT after \(polls) polls (\(ms(ContinuousClock.now - stabStart))ms)"
    )
    return false
  }

  func abortPrepare() {
    guard engine.isRunning, !isCapturing else { return }
    teardownEngine()
    try? engine.inputNode.setVoiceProcessingEnabled(false)
  }

  func rebuild() {
    teardownEngine()
    engine.reset()
    engine = AVAudioEngine()
  }

  /// Build (or rebuild) the AVAudioEngine with voice-processing configuration.
  func buildEngine(noiseSuppression: Bool) {
    teardownEngine()
    engine = AVAudioEngine()

    if noiseSuppression {
      do {
        try engine.inputNode.setVoiceProcessingEnabled(true)
        if #available(macOS 14.0, *) {
          let duckingConfig = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
          )
          engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = duckingConfig
        }
      } catch {
        Task {
          await AppLogger.shared.log(
            "Voice processing unavailable during engine build: \(error.localizedDescription)",
            level: .info, category: "Audio"
          )
        }
      }
    }
    noiseSuppressionEnabled = noiseSuppression
  }

  // MARK: - Private: Engine Teardown

  /// Shared teardown: stop forwarder, stop engine, remove tap, remove config observer.
  /// Does NOT reset or replace the engine (caller decides whether to do that).
  private func teardownEngine() {
    forwarder?.stop()
    forwarder = nil
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
  }

  // MARK: - Private: Input Device

  private func setInputDevice(_ deviceID: AudioDeviceID?) throws {
    #if DEBUG
      // Reset per attempt: the default/no-op path (no explicit device) counts as
      // OK; only a failed AudioUnitSetProperty flips this to false. (#1377 §3.5)
      lastInputDeviceBindOK = true
    #endif
    guard let deviceID, deviceID != 0 else { return }

    // Past this point a SPECIFIC device was requested. If the input audio unit is
    // unavailable we never reach AudioUnitSetProperty, so the requested device is
    // NOT bound — the bench must not read that as success.
    let audioUnit = engine.inputNode.audioUnit
    guard let au = audioUnit else {
      #if DEBUG
        lastInputDeviceBindOK = false
      #endif
      return
    }

    var devID = deviceID
    let status = AudioUnitSetProperty(
      au,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &devID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status != noErr {
      #if DEBUG
        lastInputDeviceBindOK = false
      #endif
      Task {
        await AppLogger.shared.log(
          "Failed to set input device \(deviceID): OSStatus \(status)",
          level: .info, category: "Audio"
        )
      }
      onDeviceError?("Audio device switch failed for device \(deviceID)")
    }
  }

  // MARK: - Private: Bluetooth Codec Switch Recovery

  private func handleEngineConfigurationChange() async {
    btCrashLogger.info(
      "handleEngineConfigurationChange on MainActor — isCapturing=\(self.isCapturing), isRecovering=\(self.isRecovering)"
    )
    guard isCapturing, !isRecovering else { return }

    guard let deviceID = currentInputDeviceID else {
      await AppLogger.shared.log(
        "Audio engine config changed — no device ID, performing emergency teardown",
        level: .info, category: "Audio"
      )
      emergencyTeardown()
      // #1408: we could not resolve a device id, so we never ran the
      // `DeviceIsAlive` check and cannot claim the microphone went away.
      onInterrupted?(.engineLost)
      return
    }

    switch CoreAudioDeviceLiveness.classify(deviceID: deviceID) {
    case .removed:
      await AppLogger.shared.log(
        "Audio device \(deviceID) is dead — performing emergency teardown",
        level: .info, category: "Audio"
      )
      emergencyTeardown()
      // #1408: Core Audio confirms the device is gone. This is the ONE site in
      // this source entitled to claim the user's microphone disconnected.
      onInterrupted?(.deviceRemoved)

    case .unverified:
      await AppLogger.shared.log(
        "Audio device \(deviceID) liveness unverified — performing emergency teardown",
        level: .info, category: "Audio"
      )
      emergencyTeardown()
      // #1408: the capture is broken either way, so tear down and salvage as
      // before — but Core Audio never confirmed the device left, so we do not
      // say it did.
      onInterrupted?(.engineLost)

    case .alive:
      await AppLogger.shared.log(
        "Audio engine config changed — device \(deviceID) still alive (Bluetooth codec switch), attempting graceful recovery",
        level: .info, category: "Audio"
      )
      await recoverFromCodecSwitch()
    }
  }

  private func recoverFromCodecSwitch() async {
    isRecovering = true
    defer { isRecovering = false }

    let configTime = tapStoppedFlag?.lastConfigChangeTime() ?? 0
    let recoveryStart = CFAbsoluteTimeGetCurrent()
    let gapMs = configTime > 0 ? (recoveryStart - configTime) * 1000 : -1
    btCrashLogger.info(
      "Recovery started — config→recovery gap: \(gapMs, format: .fixed(precision: 1))ms")

    tapStoppedFlag?.set()

    engine.inputNode.removeTap(onBus: 0)
    btCrashLogger.info("Recovery: tap removed")

    engine.stop()
    btCrashLogger.info("Recovery: engine stopped")

    let stabilized = await waitForFormatStabilization(
      maxWait: 1.5,
      pollInterval: 0.2
    )
    guard stabilized else {
      btCrashLogger.error("Recovery: format stabilization timed out — emergency teardown")
      emergencyTeardown()
      // #1408: the device is alive (we checked above); our engine could not
      // re-stabilize. Not a disconnect.
      onInterrupted?(.engineLost)
      return
    }

    do {
      let inputNode = engine.inputNode
      // Hardware format, not `outputFormat` — recovery never re-binds the device,
      // so the bind from `prepare()` still holds and `outputFormat` is still stale.
      // Same `installTap` assertion applies here. See the tap site in `prepare()`.
      let inputFormat = inputNode.inputFormat(forBus: 0)

      guard
        let targetFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: Self.targetSampleRate,
          channels: Self.targetChannels,
          interleaved: false
        )
      else {
        throw AudioError.formatCreationFailed(source: "AVAudioEngineSource.recover.target_format")
      }

      guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        throw AudioError.formatCreationFailed(source: "AVAudioEngineSource.recover.converter")
      }
      self.converter = audioConverter

      guard let stoppedFlag = tapStoppedFlag else {
        throw AudioError.formatCreationFailed(
          source: "AVAudioEngineSource.recover.missing_stop_token")
      }
      stoppedFlag.reset()
      btCrashLogger.info("Recovery: stop token reset for new tap")

      guard let fwd = forwarder else {
        throw AudioError.formatCreationFailed(
          source: "AVAudioEngineSource.recover.missing_forwarder")
      }

      // Validate format before reinstalling tap.
      // After codec switch, format may be zero/invalid.
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
        btCrashLogger.error(
          "Recovery: invalid input format \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch — emergency teardown"
        )
        throw AudioError.formatCreationFailed(
          source: "AVAudioEngineSource.recover.invalid_input_format")
      }

      // Safety: remove tap again before reinstalling.
      // AVAudioEngine may not fully clear tap state after engine.stop().
      inputNode.removeTap(onBus: 0)

      let bufferSize: AVAudioFrameCount = 2048
      let tapHandler = Self.makeTapHandler(
        audioConverter: audioConverter,
        targetFormat: targetFormat,
        inputFormat: inputFormat,
        forwarder: fwd,
        stoppedFlag: stoppedFlag,
        liveness: captureLiveness,
        tapLocal: tapLocalSeen
      )
      inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: tapHandler)

      do {
        try engine.start()
      } catch {
        stoppedFlag.set()
        tapStoppedFlag = nil
        inputNode.removeTap(onBus: 0)
        throw error
      }

      let totalMs = (CFAbsoluteTimeGetCurrent() - recoveryStart) * 1000
      btCrashLogger.info(
        "Recovery succeeded — total: \(totalMs, format: .fixed(precision: 1))ms, recording continues"
      )
    } catch {
      btCrashLogger.error("Recovery failed: \(error.localizedDescription) — emergency teardown")
      emergencyTeardown()
      // #1408: the device is alive; our engine failed to restart. Not a disconnect.
      onInterrupted?(.engineLost)
    }
  }

  private func emergencyTeardown() {
    guard isCapturing else { return }

    // No captureGeneration bump — see rationale in `stop()`. `isCapturing`
    // flips false below, which guards a late-fired watchdog.
    stallWorkItem?.cancel()
    stallWorkItem = nil

    for task in activeTasks { task.cancel() }
    activeTasks.removeAll()

    forwarder?.stop()
    forwarder = nil

    tapStoppedFlag?.set()
    tapStoppedFlag = nil

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset()

    isCapturing = false
    currentInputDeviceID = nil
    isRecovering = false
    bufferContinuation = nil
    converter = nil

    // Source does not own samples — manager handles partial sample recovery.

    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
  }

  // MARK: - Private: Tap Handler (nonisolated)

  nonisolated private static func makeTapHandler(
    audioConverter: AVAudioConverter,
    targetFormat: AVAudioFormat,
    inputFormat: AVAudioFormat,
    forwarder: PreRollForwarder,
    stoppedFlag: TapStoppedFlag,
    liveness: CaptureLivenessState,
    tapLocal: TapLocalSeenCache
  ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    return { buffer, _ in
      guard !stoppedFlag.isSet() else {
        btCrashLogger.debug("Tap: bailing — stop flag set")
        return
      }

      let bufferFormat = buffer.format
      guard bufferFormat.sampleRate == inputFormat.sampleRate,
        bufferFormat.channelCount == inputFormat.channelCount
      else {
        btCrashLogger.info(
          "Tap: format mismatch — \(bufferFormat.sampleRate)Hz/\(bufferFormat.channelCount)ch vs expected \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch"
        )
        return
      }

      let ratio = targetFormat.sampleRate / inputFormat.sampleRate
      let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
      guard outputFrameCount > 0, outputFrameCount <= 65536 else { return }
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: targetFormat,
          frameCapacity: outputFrameCount
        )
      else { return }

      var error: NSError?
      nonisolated(unsafe) var inputConsumed = false
      audioConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
        if inputConsumed {
          outStatus.pointee = .noDataNow
          return nil
        }
        inputConsumed = true
        outStatus.pointee = .haveData
        return buffer
      }

      guard error == nil, convertedBuffer.frameLength > 0 else { return }

      guard !stoppedFlag.isSet() else {
        btCrashLogger.debug("Tap: bailing post-convert — stop flag set during conversion")
        return
      }

      // Capture-liveness watchdog: mark on first buffer of the session.
      // Tap-local cache lets us skip the cross-thread lock after the first hit.
      if !tapLocal.alreadyMarkedThisSession {
        liveness.markReceived()
        tapLocal.alreadyMarkedThisSession = true
      }

      let level = AudioBufferProcessor.calculateRMS(convertedBuffer)

      if let channelData = convertedBuffer.floatChannelData {
        let frameCount = Int(convertedBuffer.frameLength)
        let samples = Array(
          UnsafeBufferPointer(
            start: channelData[0],
            count: frameCount
          ))
        forwarder.route(samples: samples, level: level, buffer: convertedBuffer)
      }
    }
  }
}
