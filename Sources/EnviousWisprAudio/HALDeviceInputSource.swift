@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import EnviousWisprCore
import os

/// Cross-thread set-once latch for "did any buffer reach the delegate this
/// session." Mirrors `AVCaptureSessionSource`'s `CaptureLivenessFlag` (a
/// private type per file, so not shared directly).
private final class HALCaptureLivenessFlag: Sendable {
  private let _lock = OSAllocatedUnfairLock(initialState: false)
  func markReceived() { _lock.withLock { $0 = true } }
  func wasReceived() -> Bool { _lock.withLock { $0 } }
  func reset() { _lock.withLock { $0 = false } }
}

/// Cross-thread stop latch the RT render callback checks before touching
/// anything else. Set from teardown paths; the callback bails immediately.
private final class HALStoppedFlag: Sendable {
  private let _lock = OSAllocatedUnfairLock(initialState: false)
  func set() { _lock.withLock { $0 = true } }
  func isSet() -> Bool { _lock.withLock { $0 } }
  func reset() { _lock.withLock { $0 = false } }
}

/// Fixed-capacity SPSC ring of pre-allocated raw sample chunks. The AUHAL
/// render callback (the real HAL IO thread — a harder real-time context than
/// the tap/delegate queues the other two conformers run on) pushes without
/// allocating; a queue we own drains and hands chunks to `PreRollForwarder`
/// off the IO thread. The locked region is a fixed-size memcpy only, matching
/// `keep-preroll-lock-minimal`. A lagging consumer drops the newest chunk
/// (ring full) rather than blocking the IO thread — matches the RT contract:
/// no allocation, no blocking, ever.
private final class HALSampleRing: @unchecked Sendable {
  private struct Slot {
    let storage: UnsafeMutablePointer<Float>
    var count: Int = 0
    var level: Float = 0
  }

  private var slots: [Slot]
  private let capacityPerSlot: Int
  private var writeIdx = 0
  private var readIdx = 0
  private var occupied = 0
  private let lock = OSAllocatedUnfairLock(initialState: ())

  init(slotCount: Int, capacityPerSlot: Int) {
    self.capacityPerSlot = capacityPerSlot
    self.slots = (0..<slotCount).map { _ in
      Slot(storage: .allocate(capacity: capacityPerSlot))
    }
  }

  deinit {
    for slot in slots { slot.storage.deallocate() }
  }

  /// RT-safe push. Called from the HAL IO thread inside the render callback.
  /// Returns false (dropped chunk) if the ring is full — never blocks.
  ///
  /// `withLockUnchecked` (not `withLock`) because the body captures
  /// `UnsafePointer<Float>`, which is not `Sendable`; safety here comes from
  /// the lock itself serializing the one RT producer against the one
  /// non-RT consumer, not from the compiler's Sendable check.
  @discardableResult
  func push(_ data: UnsafePointer<Float>, count: Int, level: Float) -> Bool {
    let n = min(count, capacityPerSlot)
    guard n > 0 else { return false }
    return lock.withLockUnchecked { _ in
      guard occupied < slots.count else { return false }
      slots[writeIdx].storage.update(from: data, count: n)
      slots[writeIdx].count = n
      slots[writeIdx].level = level
      writeIdx = (writeIdx + 1) % slots.count
      occupied += 1
      return true
    }
  }

  /// Non-RT drain of one chunk. Called from the consumer queue only.
  func pop() -> (samples: [Float], level: Float)? {
    lock.withLockUnchecked { _ -> (samples: [Float], level: Float)? in
      guard occupied > 0 else { return nil }
      let slot = slots[readIdx]
      let samples = Array(UnsafeBufferPointer(start: slot.storage, count: slot.count))
      readIdx = (readIdx + 1) % slots.count
      occupied -= 1
      return (samples, slot.level)
    }
  }
}

/// The RT-callback-reachable context, passed by raw pointer via `Unmanaged`
/// (an `AURenderCallback` is `@convention(c)` and cannot capture Swift state).
/// Holds only what the render callback and its off-IO-thread consumer need;
/// deliberately NOT `@MainActor` so neither hop requires actor isolation.
private final class HALRenderContext: @unchecked Sendable {
  let audioUnit: AudioUnit
  let scratch: UnsafeMutableAudioBufferListPointer
  let ring: HALSampleRing
  let stopped: HALStoppedFlag
  let liveness: HALCaptureLivenessFlag
  let forwarder: PreRollForwarder
  let consumerQueue: DispatchQueue
  /// Set once per session by the callback consumer; read by the MainActor
  /// watchdog closure via `wasReceived()` on `liveness` instead — kept here
  /// only so the consumer can skip the cross-thread mark after the first hit.
  var bufferSeenThisSession = false

  init(
    audioUnit: AudioUnit,
    scratch: UnsafeMutableAudioBufferListPointer,
    ring: HALSampleRing,
    stopped: HALStoppedFlag,
    liveness: HALCaptureLivenessFlag,
    forwarder: PreRollForwarder,
    consumerQueue: DispatchQueue
  ) {
    self.audioUnit = audioUnit
    self.scratch = scratch
    self.ring = ring
    self.stopped = stopped
    self.liveness = liveness
    self.forwarder = forwarder
    self.consumerQueue = consumerQueue
  }

  /// Drain everything currently in the ring and forward through
  /// `PreRollForwarder`, reconstructing an `AVAudioPCMBuffer` per chunk (the
  /// same per-chunk allocation shape `AVAudioEngineSource`'s tap handler and
  /// `AVCaptureSessionSource`'s delegate already use on their own callback
  /// queues — here it runs one hop off the true HAL IO thread instead of on
  /// it, since this function is called from `consumerQueue`, never directly
  /// from the render callback).
  func drainAndForward() {
    while let (samples, level) = ring.pop() {
      guard !bufferSeenThisSession else {
        forward(samples: samples, level: level)
        continue
      }
      liveness.markReceived()
      bufferSeenThisSession = true
      forward(samples: samples, level: level)
    }
  }

  private func forward(samples: [Float], level: Float) {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let channelData = buffer.floatChannelData {
      samples.withUnsafeBufferPointer { src in
        channelData[0].update(from: src.baseAddress!, count: samples.count)
      }
    }
    forwarder.route(samples: samples, level: level, buffer: buffer)
  }

  func resetSession() {
    bufferSeenThisSession = false
  }
}

/// AUHAL (`kAudioUnitSubType_HALOutput`) input-only audio capture source —
/// #1377 candidate D, reinstated 2026-07-08 to spike against candidate A
/// (`AVCaptureSessionSource`) on real Bluetooth hardware. Opens ANY device
/// directly by `AudioDeviceID` (built-in, wired, or Bluetooth) via
/// `kAudioOutputUnitProperty_CurrentDevice` — no `AVCaptureSession` /
/// `AVAudioEngine` aggregate-device layer, so there is no
/// `CADefaultDeviceAggregate` for the force-built-in crash-dodge to avoid.
///
/// Format conversion is done BY AUHAL: setting the client (output-scope,
/// element 1) stream format to 16kHz mono Float32 makes CoreAudio resample
/// from the hardware's native format for us — no `AVAudioConverter` needed.
///
/// RT-safety: the render callback (`halRenderProc`, true HAL IO thread) does
/// `AudioUnitRender` into a preallocated scratch buffer, then a fixed-size
/// memcpy into `HALSampleRing` (locked, bounded, no allocation) — see
/// `keep-preroll-lock-minimal`. The heavier work (building an
/// `AVAudioPCMBuffer`, calling `PreRollForwarder.route()`) happens on
/// `consumerQueue`, one hop off the IO thread, mirroring where the other two
/// conformers already do that same per-chunk allocation (their tap/delegate
/// callbacks, which are themselves not the literal IO thread).
@MainActor
final class HALDeviceInputSource: AudioInputSource {

  // MARK: - AudioInputSource callbacks

  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onInterrupted: (() -> Void)?
  var onLifecycleSignal: (@Sendable (String) -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  /// No `AVCaptureSession` layer — stays nil, matching `AVAudioEngineSource`.
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
  private(set) var captureGeneration: UInt64 = 0

  nonisolated let captureSourceType: String = "hal_device_input"

  private static let stallQueue = DispatchQueue(
    label: "com.enviouswispr.audio.capture-stall.hal"
  )
  private var stallWorkItem: DispatchWorkItem?

  // MARK: - State

  private(set) var isCapturing = false
  var isRunning: Bool {
    guard let audioUnit else { return false }
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioUnitGetProperty(
      audioUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
    return status == noErr && running != 0
  }

  /// Target capture device UID. Nil = built-in mic, same default-nil contract
  /// as `AVCaptureSessionSource.targetDeviceUID` (#1377 candidate A). Only
  /// ever set under `CaptureSourcePolicy.forceHALDeviceInput`; `.automatic`
  /// never emits this candidate, so it is unreachable outside the bake-off.
  var targetDeviceUID: String?

  // MARK: - Private state

  private var audioUnit: AudioUnit?
  private var renderContext: HALRenderContext?
  private var unmanagedContext: Unmanaged<HALRenderContext>?
  private var deviceIsAliveListenerDeviceID: AudioDeviceID?
  private var deviceIsAliveListenerBlock: AudioObjectPropertyListenerBlock?
  private var forwarder: PreRollForwarder?
  private let captureLiveness = HALCaptureLivenessFlag()
  private var stoppedFlag: HALStoppedFlag?
  private var isRecovering = false

  #if DEBUG
    private var boundDeviceID: AudioDeviceID?
    private var boundUID: String?
    private var lastBindOK = true
  #endif

  private static let listenerQueue = DispatchQueue(
    label: "com.enviouswispr.audio.hal-device-listener"
  )

  private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
  )!

  /// Frames per slice AUHAL is configured for; bounds the scratch buffer.
  private static let maxFramesPerSlice: UInt32 = 4096
  private static let ringSlotCount = 16

  // MARK: - Lifecycle

  func prepare() async throws {
    guard audioUnit == nil else {
      onLifecycleSignal?("hal_prepare_already_running")
      return
    }

    onLifecycleSignal?("hal_find_device_entered")
    let deviceID = resolveDeviceID()
    guard let deviceID else { throw AudioError.noBuiltInMicrophoneFound }
    onLifecycleSignal?("hal_find_device_completed")

    onLifecycleSignal?("hal_configure_entered")
    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &desc) else {
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.find_component")
    }

    var unit: AudioUnit?
    var status = AudioComponentInstanceNew(component, &unit)
    guard status == noErr, let unit else {
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.instance_new")
    }

    // Enable input on element 1, disable output on element 0 — input-only.
    var enableIO: UInt32 = 1
    status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
      &enableIO, UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.enable_input")
    }
    var disableIO: UInt32 = 0
    status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
      &disableIO, UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.disable_output")
    }

    // Pin the device — this is the whole point: any device, no aggregate.
    var pinnedDevice = deviceID
    status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
      &pinnedDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
    let bindOK = status == noErr
    #if DEBUG
      lastBindOK = bindOK
    #endif
    guard bindOK else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.set_device")
    }

    // Client format on the input element's OUTPUT scope — what our render
    // callback receives. AUHAL resamples the hardware's native format to
    // this for us.
    var clientFormat = Self.targetFormat.streamDescription.pointee
    status = AudioUnitSetProperty(
      unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
      &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    guard status == noErr else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.stream_format")
    }

    var maxFrames = Self.maxFramesPerSlice
    AudioUnitSetProperty(
      unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
      &maxFrames, UInt32(MemoryLayout<UInt32>.size))

    let scratch = AudioBufferList.allocate(maximumBuffers: 1)
    let scratchStorage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(Self.maxFramesPerSlice) * MemoryLayout<Float>.size,
      alignment: MemoryLayout<Float>.alignment
    )
    scratch[0] = AudioBuffer(
      mNumberChannels: 1,
      mDataByteSize: Self.maxFramesPerSlice * UInt32(MemoryLayout<Float>.size),
      mData: scratchStorage
    )

    let ring = HALSampleRing(
      slotCount: Self.ringSlotCount, capacityPerSlot: Int(Self.maxFramesPerSlice))
    let stopped = HALStoppedFlag()
    let fwd = PreRollForwarder()
    let consumerQueue = DispatchQueue(
      label: "com.enviouswispr.audio.hal-consumer", qos: .userInteractive)
    let context = HALRenderContext(
      audioUnit: unit, scratch: scratch, ring: ring, stopped: stopped,
      liveness: captureLiveness, forwarder: fwd, consumerQueue: consumerQueue)
    let unmanaged = Unmanaged.passRetained(context)

    // No `self.*` assignment above this line: every failure branch below must
    // release `unmanaged` + deallocate `scratch` + dispose `unit` and leave
    // `self` untouched (still a fresh, never-prepared instance) so a caller
    // that retries `prepare()` or calls `teardownUnit()` never double-releases
    // state this attempt never actually committed.
    func failPrepare(_ source: String) -> Error {
      unmanaged.release()
      scratch[0].mData?.deallocate()
      scratch.unsafeMutablePointer.deallocate()
      AudioComponentInstanceDispose(unit)
      return AudioError.formatCreationFailed(source: source)
    }

    var callbackStruct = AURenderCallbackStruct(
      inputProc: halRenderProc,
      inputProcRefCon: unmanaged.toOpaque()
    )
    status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
      &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard status == noErr else {
      throw failPrepare("HALDeviceInputSource.prepare.set_callback")
    }

    status = AudioUnitInitialize(unit)
    guard status == noErr else {
      throw failPrepare("HALDeviceInputSource.prepare.initialize")
    }
    onLifecycleSignal?("hal_configure_completed")

    onLifecycleSignal?("hal_start_entered")
    status = AudioOutputUnitStart(unit)
    guard status == noErr else {
      AudioUnitUninitialize(unit)
      throw failPrepare("HALDeviceInputSource.prepare.start")
    }
    onLifecycleSignal?("hal_start_completed")

    // Committed — every fallible step succeeded, so this is the one place
    // `self` state is assigned for this attempt.
    self.forwarder = fwd
    self.renderContext = context
    self.stoppedFlag = stopped
    self.unmanagedContext = unmanaged
    self.audioUnit = unit
    registerDeviceIsAliveListener(deviceID: deviceID)

    #if DEBUG
      boundDeviceID = deviceID
      boundUID = AudioDeviceEnumerator.inputDeviceUID(for: deviceID)
    #endif
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource: prepared with device \(deviceID) (uid=\(AudioDeviceEnumerator.inputDeviceUID(for: deviceID) ?? "unknown"))"
    )
  }

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard !isCapturing else { throw AudioError.alreadyCapturing }
    guard let fwd = forwarder else {
      throw AudioError.formatCreationFailed(
        source: "HALDeviceInputSource.startCapture.missing_forwarder")
    }

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
      self.streamContinuation = continuation
    }

    _ = fwd.activate(
      onSamples: self.onSamples,
      onBuffer: self.onBufferCaptured,
      continuation: self.streamContinuation,
      logPrefix: "HALDeviceInputSource"
    )

    captureGeneration &+= 1
    captureLiveness.reset()
    renderContext?.resetSession()
    armCaptureStallWatchdog()

    isCapturing = true
    #if DEBUG
      logBenchCaptureEvidence()
    #endif
    return stream
  }

  private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  #if DEBUG
    /// Capture-side actual-bound-device evidence (#1377 §3.5), same shape as
    /// the other two conformers so `capture_bakeoff.py` parses it unchanged.
    private func logBenchCaptureEvidence() {
      let boundTransport =
        boundDeviceID.flatMap { AudioDeviceEnumerator.transportLabel(for: $0) } ?? "unknown"
      AudioCaptureManager.btRouteLog(
        "CAPTURE_EVIDENCE backend=hal_device_input boundUID=\(boundUID ?? "unknown") boundDeviceID=\(boundDeviceID.map(String.init) ?? "nil") boundTransport=\(boundTransport) bindOK=\(lastBindOK) requestedUID=\(targetDeviceUID ?? "built_in")"
      )
    }
  #endif

  private func armCaptureStallWatchdog() {
    stallWorkItem?.cancel()
    let armedSession = captureGeneration
    let armedAtNs = DispatchTime.now().uptimeNanoseconds
    let item = Self.makeStallWorkItem(
      armedSession: armedSession, armedAtNs: armedAtNs, source: self)
    stallWorkItem = item
    Self.stallQueue.asyncAfter(
      deadline: .now() + .milliseconds(TimingConstants.audioCaptureStallWindowMs), execute: item)
  }

  nonisolated private static func makeStallWorkItem(
    armedSession: UInt64, armedAtNs: UInt64, source: HALDeviceInputSource
  ) -> DispatchWorkItem {
    return DispatchWorkItem { [weak source] in
      Task { @MainActor [weak source] in
        source?.captureStallWatchdogFired(armedSession: armedSession, armedAtNs: armedAtNs)
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
      route: "hal_device_input",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: isRunning,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: targetDeviceUID,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID()
    )
    onCaptureStalled?(ctx)
  }

  func deactivateCapture() {
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.returnToPreRoll()
    isCapturing = false
    streamContinuation = nil
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource deactivated — unit stays warm, pre-roll capturing")
  }

  func stop() async -> [Float] {
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.stop()
    forwarder = nil
    isCapturing = false
    streamContinuation = nil
    teardownUnit()
    // Source does not own samples — manager accumulates via onSamples callback.
    return []
  }

  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    // AUHAL's client format is fixed at the property we set — CoreAudio does
    // the SRC internally, so there is no format renegotiation to wait out.
    return true
  }

  func abortPrepare() {
    guard audioUnit != nil, !isCapturing else { return }
    teardownUnit()
  }

  func rebuild() {
    teardownUnit()
  }

  // MARK: - Private: teardown

  private func teardownUnit() {
    stoppedFlag?.set()
    removeDeviceIsAliveListener()
    if let unit = audioUnit {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
    }
    if let unmanagedContext {
      unmanagedContext.release()
    }
    if let context = renderContext {
      context.scratch[0].mData?.deallocate()
      context.scratch.unsafeMutablePointer.deallocate()
    }
    audioUnit = nil
    renderContext = nil
    unmanagedContext = nil
    stoppedFlag = nil
    #if DEBUG
      boundDeviceID = nil
      boundUID = nil
    #endif
  }

  // MARK: - Private: device resolution

  /// Resolve the pinned target device, falling back to built-in with the
  /// SAME log-text fragment `AVCaptureSessionSource` uses ("not found —
  /// falling back") so `capture_bakeoff.py`'s `FALLBACK_MARKER` catches it
  /// unchanged for this candidate too.
  private func resolveDeviceID() -> AudioDeviceID? {
    if let uid = targetDeviceUID, !uid.isEmpty {
      if let id = AudioDeviceEnumerator.deviceID(forUID: uid) { return id }
      AudioCaptureManager.btRouteLog(
        "HALDeviceInputSource: target device uid=\(uid) not found — falling back to built-in")
    }
    return AudioDeviceEnumerator.builtInMicrophoneDeviceID()
  }

  // MARK: - Private: disconnect handling

  /// Mirrors `AVAudioEngineSource.handleEngineConfigurationChange`'s
  /// `kAudioDevicePropertyDeviceIsAlive` check — device-vanished is engine-
  /// independent per #1377 bake-off findings, so candidate D needs the same
  /// detection. Fires `onInterrupted()`; the accumulated `capturedSamples`
  /// salvage (manager-owned) is what actually saves the partial dictation.
  private func registerDeviceIsAliveListener(deviceID: AudioDeviceID) {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.handleDeviceMayHaveVanished(deviceID: deviceID)
      }
    }
    let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, Self.listenerQueue, block)
    if status == noErr {
      deviceIsAliveListenerDeviceID = deviceID
      deviceIsAliveListenerBlock = block
    }
  }

  private func removeDeviceIsAliveListener() {
    guard let deviceID = deviceIsAliveListenerDeviceID, let block = deviceIsAliveListenerBlock
    else { return }
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListenerBlock(deviceID, &addr, Self.listenerQueue, block)
    deviceIsAliveListenerDeviceID = nil
    deviceIsAliveListenerBlock = nil
  }

  private func handleDeviceMayHaveVanished(deviceID: AudioDeviceID) {
    guard isCapturing, !isRecovering else { return }
    var isAlive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isAlive)
    guard isAlive == 0 else { return }
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource: device \(deviceID) went away — interrupting")
    onInterrupted?()
  }
}

/// The AUHAL render callback — runs on the real HAL IO thread. Must not
/// allocate, lock for long, or log. `inRefCon` is the `HALRenderContext`
/// passed via `Unmanaged` from `prepare()`.
private func halRenderProc(
  inRefCon: UnsafeMutableRawPointer,
  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  inTimeStamp: UnsafePointer<AudioTimeStamp>,
  inBusNumber: UInt32,
  inNumberFrames: UInt32,
  ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  let context = Unmanaged<HALRenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
  guard !context.stopped.isSet() else { return noErr }

  let status = AudioUnitRender(
    context.audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames,
    context.scratch.unsafeMutablePointer)
  guard status == noErr else { return status }
  guard !context.stopped.isSet() else { return noErr }

  guard let data = context.scratch[0].mData else { return noErr }
  let floatPtr = data.assumingMemoryBound(to: Float.self)
  let frameCount = Int(inNumberFrames)

  var sum: Float = 0
  for i in 0..<frameCount { sum += floatPtr[i] * floatPtr[i] }
  let level = frameCount > 0 ? (sum / Float(frameCount)).squareRoot() : 0

  context.ring.push(floatPtr, count: frameCount, level: level)
  context.consumerQueue.async { context.drainAndForward() }

  return noErr
}
