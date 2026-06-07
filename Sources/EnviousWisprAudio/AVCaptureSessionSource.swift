@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import os

/// Cross-thread set-once latch for "did any buffer reach the delegate this
/// session." The `CaptureDelegate` marks from its callback queue; the
/// MainActor watchdog reads at fire time. `OSAllocatedUnfairLock` keeps the
/// write cost negligible.
private final class CaptureLivenessFlag: Sendable {
  private let _lock = OSAllocatedUnfairLock(initialState: false)
  func markReceived() { _lock.withLock { $0 = true } }
  func wasReceived() -> Bool { _lock.withLock { $0 } }
  func reset() { _lock.withLock { $0 = false } }
}

/// One-shot await helper for AVCaptureSession lifecycle calls. Start can use
/// platform notifications as terminal signals. Stop uses notifications only as
/// progress ticks; `stopRunning()` returning is the cleanup boundary.
private final class SessionLifecycleSignal<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Never>?
  private var observers: [NSObjectProtocol] = []

  init(_ continuation: CheckedContinuation<T, Never>) {
    self.continuation = continuation
  }

  func observe(
    name: Notification.Name,
    object: Any?,
    returning value: T,
    onSignal: (@Sendable () -> Void)?
  ) {
    let observer = NotificationCenter.default.addObserver(
      forName: name,
      object: object,
      queue: nil
    ) { [weak self] _ in
      onSignal?()
      self?.resume(returning: value)
    }
    lock.lock()
    observers.append(observer)
    lock.unlock()
  }

  func observeProgress(
    name: Notification.Name,
    object: Any?,
    onSignal: @escaping @Sendable () -> Void
  ) {
    let observer = NotificationCenter.default.addObserver(
      forName: name,
      object: object,
      queue: nil
    ) { _ in
      onSignal()
    }
    lock.lock()
    observers.append(observer)
    lock.unlock()
  }

  func resume(returning value: T) {
    lock.lock()
    let cont = continuation
    continuation = nil
    let observersToRemove = observers
    observers = []
    lock.unlock()

    for observer in observersToRemove {
      NotificationCenter.default.removeObserver(observer)
    }
    cont?.resume(returning: value)
  }
}

/// AVCaptureSession-based audio capture source. Avoids BT A2DP→SCO codec switch by
/// capturing from the built-in microphone via AVCaptureSession, which on macOS does NOT
/// trigger Bluetooth audio route changes (AVAudioSession is API_UNAVAILABLE(macos)).
///
/// The framework handles sample rate conversion internally when audioSettings is set
/// to request 16kHz mono Float32 — no manual AVAudioConverter needed.
///
/// Used when BT headphones are connected as output. The engine source (AVAudioEngineSource)
/// is used when no BT output is active (supports voice processing/noise suppression).
@MainActor
final class AVCaptureSessionSource: AudioInputSource {

  // MARK: - AudioInputSource callbacks

  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onInterrupted: (() -> Void)?
  var onLifecycleSignal: (@Sendable (String) -> Void)?

  // MARK: - Round-4 telemetry (issue #285) — stall watchdog + interruption ctx.

  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
  private(set) var captureGeneration: UInt64 = 0

  nonisolated let captureSourceType: String = "av_capture_session"

  /// Set-once latch the delegate flips on first buffer; watchdog reads at fire time.
  private let captureLiveness = CaptureLivenessFlag()
  private static let stallQueue = DispatchQueue(
    label: "com.enviouswispr.audio.capture-stall.session"
  )
  private var stallWorkItem: DispatchWorkItem?

  // MARK: - State

  private(set) var isCapturing = false
  var isRunning: Bool { session?.isRunning ?? false }

  // MARK: - Private state

  private var session: AVCaptureSession?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var delegate: CaptureDelegate?
  private var interruptionObservers: [NSObjectProtocol] = []
  private var forwarder: PreRollForwarder?

  /// Dedicated serial queue for AVCaptureSession start/stop operations.
  /// Apple recommends session lifecycle on a serial queue to avoid race conditions.
  /// IMPORTANT: This is separate from callbackQueue to avoid ordering bugs — lifecycle
  /// work (start/stop) and sample delivery (captureOutput) never share a queue.
  private let sessionQueue = DispatchQueue(label: "com.enviouswispr.capture-session-lifecycle")

  /// Serial queue for sample buffer delivery. Separate from sessionQueue.
  private let callbackQueue = DispatchQueue(
    label: "com.enviouswispr.capture-session-callback", qos: .userInteractive)

  /// 16kHz mono Float32 format — matches ASR backend requirements.
  private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
  )!

  // MARK: - Lifecycle

  func prepare() async throws {
    // Double-start protection
    guard session == nil || session?.isRunning == false else {
      onLifecycleSignal?("capture_session_prepare_already_running")
      return
    }

    // Find the built-in microphone by transport type — NOT AVCaptureDevice.default(for: .audio)
    // which follows the system default and may return a BT device.
    onLifecycleSignal?("capture_session_find_mic_entered")
    let builtInMic = findBuiltInMicrophone()
    guard let mic = builtInMic else {
      throw AudioError.noBuiltInMicrophoneFound
    }
    onLifecycleSignal?("capture_session_find_mic_completed")

    onLifecycleSignal?("capture_session_configure_entered")
    let captureSession = AVCaptureSession()

    let input = try AVCaptureDeviceInput(device: mic)
    guard captureSession.canAddInput(input) else {
      throw AudioError.formatCreationFailed(source: "AVCaptureSessionSource.prepare.can_add_input")
    }
    captureSession.addInput(input)

    let output = AVCaptureAudioDataOutput()
    // Request 16kHz mono Float32 directly — macOS-only API.
    // The framework handles sample rate conversion internally.
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: true,
    ]

    guard captureSession.canAddOutput(output) else {
      throw AudioError.formatCreationFailed(source: "AVCaptureSessionSource.prepare.can_add_output")
    }
    captureSession.addOutput(output)

    self.session = captureSession
    self.audioOutput = output

    // Install pre-roll delegate to capture audio during setup latency.
    // CaptureDelegate routes through PreRollForwarder, which buffers until
    // startCapture() activates live forwarding.
    let fwd = PreRollForwarder()
    self.forwarder = fwd
    let preRollDelegate = CaptureDelegate(
      targetFormat: Self.targetFormat,
      forwarder: fwd,
      liveness: captureLiveness
    )
    self.delegate = preRollDelegate
    output.setSampleBufferDelegate(preRollDelegate, queue: callbackQueue)
    onLifecycleSignal?("capture_session_configure_completed")

    // Register interruption observers
    onLifecycleSignal?("capture_session_observers_entered")
    registerInterruptionObservers(for: captureSession)
    onLifecycleSignal?("capture_session_observers_completed")

    // Start the session — this does NOT trigger BT route changes on macOS.
    // IMPORTANT: startRunning() is a blocking call that Apple says must not run on main thread.
    // Dispatch to background and await completion.
    onLifecycleSignal?("capture_session_start_running_entered")
    let started = await awaitStartRunning(captureSession, lifecycleSignal: onLifecycleSignal)
    onLifecycleSignal?("capture_session_start_running_completed")

    guard started else {
      throw AudioError.formatCreationFailed(source: "AVCaptureSessionSource.prepare.start_running")
    }

    AudioCaptureManager.btRouteLog(
      "AVCaptureSessionSource: prepared with \(mic.localizedName) (uid=\(mic.uniqueID))")
  }

  private func awaitStartRunning(
    _ captureSession: AVCaptureSession,
    lifecycleSignal: (@Sendable (String) -> Void)?
  ) async -> Bool {
    let sessionQ = sessionQueue
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      let signal = SessionLifecycleSignal(cont)
      signal.observe(
        name: .AVCaptureSessionDidStartRunning, object: captureSession, returning: true
      ) {
        lifecycleSignal?("capture_session_did_start_running")
      }
      signal.observe(
        name: .AVCaptureSessionRuntimeError, object: captureSession, returning: false
      ) {
        lifecycleSignal?("capture_session_runtime_error")
      }
      signal.observe(
        name: .AVCaptureSessionWasInterrupted, object: captureSession, returning: false
      ) {
        lifecycleSignal?("capture_session_was_interrupted")
      }
      sessionQ.async {
        captureSession.startRunning()
        lifecycleSignal?("capture_session_start_running_returned")
        signal.resume(returning: captureSession.isRunning)
      }
    }
  }

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard !isCapturing else {
      throw AudioError.alreadyCapturing
    }
    guard let fwd = forwarder else {
      throw AudioError.formatCreationFailed(
        source: "AVCaptureSessionSource.startCapture.missing_forwarder")
    }

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
      self.delegate?.continuation = continuation
    }

    // Two-step activation: snapshot ring, feed pre-roll, commit, feed delta.
    _ = fwd.activate(
      onSamples: self.onSamples,
      onBuffer: self.onBufferCaptured,
      continuation: self.delegate?.continuation,
      logPrefix: "AVCaptureSessionSource"
    )

    captureGeneration &+= 1
    captureLiveness.reset()
    delegate?.resetBufferSeen()
    armCaptureStallWatchdog()

    isCapturing = true
    return stream
  }

  /// Issue #285 — arm one-shot stall watchdog for the current capture session.
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
  /// the work item runs on the stall queue.
  nonisolated private static func makeStallWorkItem(
    armedSession: UInt64,
    armedAtNs: UInt64,
    source: AVCaptureSessionSource
  ) -> DispatchWorkItem {
    return DispatchWorkItem { [weak source] in
      Task { @MainActor [weak source] in
        source?.captureStallWatchdogFired(
          armedSession: armedSession, armedAtNs: armedAtNs)
      }
    }
  }

  private func captureStallWatchdogFired(armedSession: UInt64, armedAtNs: UInt64) {
    guard captureGeneration == armedSession else { return }
    guard isCapturing else { return }
    guard !captureLiveness.wasReceived() else { return }

    let ctx = CaptureStallContext(
      sessionID: armedSession,
      armedAtUptimeNs: armedAtNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: "capture_session_bt",
      sourceType: "av_capture_session",
      engineStartedSuccessfully: session?.isRunning ?? false,
      tapInstalled: true,
      formatMismatchObserved: delegate?.didObserveFormatMismatch ?? false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID()
    )
    onCaptureStalled?(ctx)
  }

  func deactivateCapture() {
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.returnToPreRoll()
    isCapturing = false
    delegate?.continuation = nil
    AudioCaptureManager.btRouteLog(
      "AVCaptureSession deactivated — session stays warm, pre-roll capturing")
  }

  func stop() async -> [Float] {
    // Do NOT bump `captureGeneration` — it must stay stable across stop so the
    // pipeline's stall→no-audio dedup keys the same session (#285). Watchdog
    // staleness is covered by `stallWorkItem?.cancel()` + the `isCapturing`
    // guard in `captureStallWatchdogFired`.
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.stop()
    forwarder = nil

    // Stop session FIRST — stopRunning() is synchronous per Apple docs, blocks until
    // the session stops and no new frames are delivered to callbackQueue.
    // RULE: Do NOT touch delegate, callback queue, or continuation state until
    // stopRunning() has returned. No "cleanup optimization" before the session stops.
    if let captureSession = session {
      onLifecycleSignal?("capture_session_stop_running_entered")
      await awaitStopRunning(captureSession, lifecycleSignal: onLifecycleSignal)
      onLifecycleSignal?("capture_session_stop_running_completed")
    }

    // NOW safe to clear delegate — session is stopped, no more buffers arriving.
    audioOutput?.setSampleBufferDelegate(nil, queue: nil)

    isCapturing = false
    removeInterruptionObservers()

    delegate?.continuation = nil
    delegate = nil

    // Source does not own samples — manager accumulates via onSamples callback.
    return []
  }

  private func awaitStopRunning(
    _ captureSession: AVCaptureSession,
    lifecycleSignal: (@Sendable (String) -> Void)?
  ) async {
    let sessionQ = sessionQueue
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let signal = SessionLifecycleSignal(cont)
      signal.observeProgress(
        name: .AVCaptureSessionDidStopRunning, object: captureSession
      ) {
        lifecycleSignal?("capture_session_did_stop_running")
      }
      signal.observeProgress(
        name: .AVCaptureSessionRuntimeError, object: captureSession
      ) {
        lifecycleSignal?("capture_session_runtime_error")
      }
      signal.observeProgress(
        name: .AVCaptureSessionWasInterrupted, object: captureSession
      ) {
        lifecycleSignal?("capture_session_was_interrupted")
      }
      sessionQ.async {
        captureSession.stopRunning()
        lifecycleSignal?("capture_session_stop_running_returned")
        signal.resume(returning: ())
      }
    }
  }

  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    // AVCaptureSession has no codec-switch problem — format is immediately stable.
    return true
  }

  func abortPrepare() {
    guard session?.isRunning == true, !isCapturing else { return }
    teardownSession(clearDelegate: false)
  }

  func rebuild() {
    teardownSession(clearDelegate: true)
    session = nil
    audioOutput = nil
  }

  /// Shared teardown: stop forwarder, fire-and-forget session stop, remove observers.
  /// `clearDelegate` controls whether delegate/continuation are nil'd (rebuild needs it,
  /// abortPrepare does not because session stop handles it).
  private func teardownSession(clearDelegate: Bool) {
    forwarder?.stop()
    forwarder = nil
    if clearDelegate {
      audioOutput?.setSampleBufferDelegate(nil, queue: nil)
      delegate?.continuation?.finish()
      delegate = nil
    }
    // Fire-and-forget stop — synchronous protocol methods can't await.
    // Using async avoids serial-queue self-deadlock risk.
    let captureSession = session
    sessionQueue.async {
      captureSession?.stopRunning()
    }
    removeInterruptionObservers()
  }

  // MARK: - Private: Device Discovery

  /// Find the built-in microphone via CoreAudio transport type.
  /// Does NOT use AVCaptureDevice.default(for: .audio) which follows system default
  /// and may return BT devices.
  private func findBuiltInMicrophone() -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone],
      mediaType: .audio,
      position: .unspecified
    )

    // Match by CoreAudio transport type — the most reliable way to identify built-in mic.
    for device in discovery.devices {
      if let audioDeviceID = AudioDeviceEnumerator.deviceID(forUID: device.uniqueID) {
        let transport = AudioDeviceEnumerator.transportType(for: audioDeviceID)
        if transport == kAudioDeviceTransportTypeBuiltIn {
          return device
        }
      }
    }

    // Fallback: match by name (less reliable but covers edge cases)
    AudioCaptureManager.btRouteLog(
      "findBuiltInMicrophone: CoreAudio transport lookup found no built-in device, trying name fallback"
    )
    for device in discovery.devices {
      let name = device.localizedName.lowercased()
      if name.contains("built-in") || name.contains("macbook") {
        return device
      }
    }

    return nil
  }

  // MARK: - Private: Interruption Handling

  private func registerInterruptionObservers(for session: AVCaptureSession) {
    let wasInterrupted = NotificationCenter.default.addObserver(
      forName: .AVCaptureSessionWasInterrupted,
      object: session,
      queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.emitCaptureSessionInterruption(kind: .wasInterrupted, notification: notification)
        self.onInterrupted?()
      }
    }

    let runtimeError = NotificationCenter.default.addObserver(
      forName: .AVCaptureSessionRuntimeError,
      object: session,
      queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.emitCaptureSessionInterruption(kind: .runtimeError, notification: notification)
        self.onInterrupted?()
      }
    }

    interruptionObservers = [wasInterrupted, runtimeError]
  }

  /// Issue #285 — build `CaptureSessionInterruptionContext` from the
  /// notification userInfo and invoke `onCaptureSessionInterruption`. Kept
  /// defensive: userInfo keys are optional on macOS and any shape may be nil.
  private func emitCaptureSessionInterruption(
    kind: CaptureSessionInterruptionContext.Kind,
    notification: Notification
  ) {
    // macOS: `AVCaptureSessionInterruptionReasonKey` is iOS-only. The
    // wasInterrupted notification has no reason userInfo; only runtimeError
    // carries an `AVCaptureSessionErrorKey` NSError.
    let userInfo = notification.userInfo
    let reasonCode: Int? = nil
    let reasonLabel: String? = nil
    let error = userInfo?[AVCaptureSessionErrorKey] as? NSError
    let ctx = CaptureSessionInterruptionContext(
      kind: kind,
      reasonCode: reasonCode,
      reasonLabel: reasonLabel,
      errorDomain: error?.domain,
      errorCode: error.map { $0.code },
      errorDescription: error?.localizedDescription,
      sessionID: captureGeneration,
      isActivelyCapturing: isCapturing
    )
    onCaptureSessionInterruption?(ctx)
  }

  private func removeInterruptionObservers() {
    for observer in interruptionObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    interruptionObservers = []
  }
}

// MARK: - Capture Delegate

/// Handles AVCaptureAudioDataOutput sample buffer delivery on a serial dispatch queue.
/// Extracts Float32 samples from CMSampleBuffer and forwards via callbacks.
private final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable
{

  /// Set after init by the AsyncStream closure.
  var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private let forwarder: PreRollForwarder
  private let liveness: CaptureLivenessFlag
  /// Callback-queue-local latch so we only mark once per session.
  private var bufferSeenThisSession = false

  /// Track whether first buffer format has been validated.
  private var formatValidated = false
  /// If true, format was wrong — drop all subsequent buffers.
  private var formatMismatch = false

  /// Readable by the source for `CaptureStallContext.formatMismatchObserved`.
  var didObserveFormatMismatch: Bool { formatMismatch }

  /// Called from the source on `startCapture` to rearm the per-session latch.
  func resetBufferSeen() { bufferSeenThisSession = false }

  init(targetFormat: AVAudioFormat, forwarder: PreRollForwarder, liveness: CaptureLivenessFlag) {
    _ = targetFormat  // validated at init site; format checking done in captureOutput
    self.forwarder = forwarder
    self.liveness = liveness
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !formatMismatch else { return }  // Format was wrong — drop all buffers
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
    guard numSamples > 0 else { return }

    // Format validation gate — debug assert, release log + fail safe
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)!.pointee
    if !formatValidated {
      let actualRate = asbd.mSampleRate
      let actualChannels = asbd.mChannelsPerFrame
      AudioCaptureManager.btRouteLog(
        "AVCaptureSessionSource first buffer: \(actualRate)Hz/\(actualChannels)ch, bits=\(asbd.mBitsPerChannel), float=\(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)"
      )

      #if DEBUG
        assert(
          actualRate == 16000 && actualChannels == 1,
          "AVCaptureSession format mismatch: \(actualRate)Hz/\(actualChannels)ch — expected 16000Hz/1ch"
        )
      #endif

      formatValidated = true  // Set regardless of match — log once, not on every buffer
      if actualRate != 16000 || actualChannels != 1 {
        AudioCaptureManager.btRouteLog(
          "FORMAT MISMATCH: expected 16000Hz/1ch, got \(actualRate)Hz/\(actualChannels)ch — dropping all buffers"
        )
        formatMismatch = true
        return
      }
    }

    // Extract Float32 samples from CMSampleBuffer
    let frameCount = numSamples

    let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
    guard
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else { return }

    pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

    // Copy PCM data from CMSampleBuffer into AVAudioPCMBuffer
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: pcmBuffer.mutableAudioBufferList
    )
    guard status == noErr else { return }

    // Capture-liveness watchdog: mark on first buffer of the session.
    if !bufferSeenThisSession {
      liveness.markReceived()
      bufferSeenThisSession = true
    }

    // Calculate audio level (RMS)
    let level = AudioBufferProcessor.calculateRMS(pcmBuffer)

    // Route through forwarder (pre-roll ring or live callbacks)
    if let channelData = pcmBuffer.floatChannelData {
      let samples = Array(
        UnsafeBufferPointer(
          start: channelData[0],
          count: frameCount
        ))
      forwarder.route(samples: samples, level: level, buffer: pcmBuffer)
    }
  }
}
