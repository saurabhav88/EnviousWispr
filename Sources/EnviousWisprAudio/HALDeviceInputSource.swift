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

  /// Non-RT drain of one chunk into a caller-owned, reused scratch buffer
  /// (must be at least `capacityPerSlot` long). The lock's critical section
  /// is a bounded memcpy only — same shape as `push()`'s. Building the final
  /// `[Float]`/`AVAudioPCMBuffer` the caller actually needs happens AFTER
  /// unlocking, in the caller. This lock is shared with the RT `push()`
  /// side, so any allocation done while holding it could block the render
  /// callback behind the consumer (Codex review r2 P2) — moving the
  /// allocation out is what closes that.
  func pop(into destination: inout [Float]) -> (count: Int, level: Float)? {
    lock.withLockUnchecked { _ -> (count: Int, level: Float)? in
      guard occupied > 0 else { return nil }
      let slot = slots[readIdx]
      destination.withUnsafeMutableBufferPointer { dst in
        dst.baseAddress!.update(from: slot.storage, count: slot.count)
      }
      readIdx = (readIdx + 1) % slots.count
      occupied -= 1
      return (slot.count, slot.level)
    }
  }
}

/// Per-session capture-health counters (#1434). Incremented from the RT render
/// callback (ring drops) and the consumer thread (converter errors / zero
/// output); read + reset from the MainActor source. A single unfair lock keeps
/// every touch a bounded few-instruction critical section — the same cost
/// class as `HALSampleRing`'s lock, which the RT contract already accepts.
private final class HALSessionCounters: Sendable {
  struct Snapshot {
    var ringDrops = 0
    var converterErrors = 0
    var zeroOutputs = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: Snapshot())
  func incrementRingDrop() { state.withLock { $0.ringDrops += 1 } }
  func incrementConverterError() { state.withLock { $0.converterErrors += 1 } }
  func incrementZeroOutput() { state.withLock { $0.zeroOutputs += 1 } }
  func snapshot() -> Snapshot { state.withLock { $0 } }
  func reset() { state.withLock { $0 = Snapshot() } }
}

/// The RT-callback-reachable context, passed by raw pointer via `Unmanaged`
/// (an `AURenderCallback` is `@convention(c)` and cannot capture Swift state).
/// Holds only what the render callback and its off-IO-thread consumer need;
/// deliberately NOT `@MainActor` so neither hop requires actor isolation.
private final class HALRenderContext: @unchecked Sendable {
  let audioUnit: AudioUnit
  let scratch: UnsafeMutableAudioBufferListPointer
  /// Frame capacity `scratch` was allocated for. The render callback clamps
  /// every read to this (never to the hardware-reported `inNumberFrames`
  /// alone) — see the RT-safety comment on `halRenderProc` (Codex review r1
  /// P1: a larger-than-configured slice must never read past the allocation).
  let capacityFrames: Int
  let ring: HALSampleRing
  let stopped: HALStoppedFlag
  let liveness: HALCaptureLivenessFlag
  let forwarder: PreRollForwarder
  /// The device's OWN native rate (mono Float32 non-interleaved) — what the
  /// client format was set to, and what `ring` samples actually are. AUHAL
  /// input does NOT resample (Apple QA1777: "does not provide sample rate
  /// conversion" for input on macOS) — cloud review P2 caught the prior
  /// version assuming a silent 16kHz resample that only happened to work
  /// because the Bose's Bluetooth profile is already 16kHz natively.
  let nativeFormat: AVAudioFormat
  let targetFormat: AVAudioFormat
  /// Resamples `nativeFormat` → `targetFormat` on the consumer thread —
  /// mirrors `AVAudioEngineSource`'s own `AVAudioConverter` usage exactly.
  let converter: AVAudioConverter
  /// #1434 capture-health counters — RT + consumer threads increment, the
  /// MainActor source snapshots at stop and resets per session.
  let counters = HALSessionCounters()
  /// Signaled once per rendered chunk; the dedicated consumer thread blocks
  /// on this instead of the render callback dispatching work (Codex review r1
  /// P2: `DispatchQueue.async` from the HAL IO thread can allocate/lock —
  /// signaling a semaphore is the RT-safe wake primitive).
  let semaphore = DispatchSemaphore(value: 0)
  /// Set once per session by the callback consumer; read by the MainActor
  /// watchdog closure via `wasReceived()` on `liveness` instead — kept here
  /// only so the consumer can skip the cross-thread mark after the first hit.
  var bufferSeenThisSession = false
  /// Reused destination for `ring.pop(into:)` — sized once to `capacityFrames`
  /// so the drain's bounded memcpy (shared lock with the RT `push()` side)
  /// never allocates; the per-chunk `[Float]`/`AVAudioPCMBuffer` `forward()`
  /// needs is built AFTER that copy returns, outside the lock.
  private var popScratch: [Float]

  init(
    audioUnit: AudioUnit,
    scratch: UnsafeMutableAudioBufferListPointer,
    capacityFrames: Int,
    ring: HALSampleRing,
    stopped: HALStoppedFlag,
    liveness: HALCaptureLivenessFlag,
    forwarder: PreRollForwarder,
    nativeFormat: AVAudioFormat,
    targetFormat: AVAudioFormat,
    converter: AVAudioConverter
  ) {
    self.audioUnit = audioUnit
    self.scratch = scratch
    self.capacityFrames = capacityFrames
    self.ring = ring
    self.stopped = stopped
    self.liveness = liveness
    self.forwarder = forwarder
    self.nativeFormat = nativeFormat
    self.targetFormat = targetFormat
    self.converter = converter
    self.popScratch = [Float](repeating: 0, count: capacityFrames)
  }

  /// Drain everything currently in the ring and forward through
  /// `PreRollForwarder`, reconstructing an `AVAudioPCMBuffer` per chunk (the
  /// same per-chunk allocation shape `AVAudioEngineSource`'s tap handler and
  /// `AVCaptureSessionSource`'s delegate already use on their own callback
  /// queues — here it runs one hop off the true HAL IO thread instead of on
  /// it, since this function is called from the dedicated consumer thread,
  /// never directly from the render callback).
  func drainAndForward() {
    while let (count, _) = ring.pop(into: &popScratch) {
      guard
        let nativeBuffer = AVAudioPCMBuffer(
          pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(count))
      else { continue }
      nativeBuffer.frameLength = AVAudioFrameCount(count)
      if let channelData = nativeBuffer.floatChannelData {
        popScratch.withUnsafeBufferPointer { src in
          channelData[0].update(from: src.baseAddress!, count: count)
        }
      }
      // Liveness marks only once `forward` has actually converted AND routed
      // a buffer downstream — never on mere receipt of a native-rate chunk
      // (cloud review P2). Marking on receipt would let a converter that
      // silently fails on every call (e.g. an unexpected format edge case)
      // permanently defeat the "no audio detected" stall watchdog, since
      // `bufferSeenThisSession` only ever flips once per recording.
      let routed = forward(nativeBuffer: nativeBuffer)
      if routed, !bufferSeenThisSession {
        liveness.markReceived()
        bufferSeenThisSession = true
      }
    }
  }

  /// Resample `nativeBuffer` (the device's real rate) to `targetFormat`
  /// (16kHz mono, what the pipeline expects) and forward the converted
  /// samples — never the raw native-rate ones (cloud review P2). Returns
  /// whether a converted buffer actually reached `forwarder.route`.
  @discardableResult
  private func forward(nativeBuffer: AVAudioPCMBuffer) -> Bool {
    let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(nativeBuffer.frameLength) * ratio) + 1
    guard outputFrameCount > 0,
      let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat, frameCapacity: outputFrameCount)
    else { return false }

    var error: NSError?
    nonisolated(unsafe) var inputConsumed = false
    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
      if inputConsumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      inputConsumed = true
      outStatus.pointee = .haveData
      return nativeBuffer
    }
    // One-buffer-then-.noDataNow is the documented pull-style streaming idiom
    // (AVAudioConverter docs), and dropping a zero-frame output is REQUIRED —
    // forwarding an empty buffer duplicates a timestamp downstream. Both
    // branches are counted (#1434) so a converter that fails repeatedly is
    // fleet-visible instead of silent: priming legitimately yields one
    // zero-frame output; more than ~1 per session is a signal.
    if error != nil {
      counters.incrementConverterError()
      return false
    }
    guard convertedBuffer.frameLength > 0 else {
      counters.incrementZeroOutput()
      return false
    }

    let level = AudioBufferProcessor.calculateRMS(convertedBuffer)
    guard let channelData = convertedBuffer.floatChannelData else { return false }
    let frameCount = Int(convertedBuffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    forwarder.route(samples: samples, level: level, buffer: convertedBuffer)
    return true
  }

  func resetSession() {
    bufferSeenThisSession = false
  }
}

/// AUHAL (`kAudioUnitSubType_HALOutput`) input-only audio capture source —
/// #1377 candidate D, reinstated 2026-07-08 to spike against candidate A
/// (`AVCaptureSessionSource`) on real Bluetooth hardware. Opens ANY device
/// directly by `AudioDeviceID` (built-in, wired, or Bluetooth) via
/// `kAudioOutputUnitProperty_CurrentDevice`, without an `AVCaptureSession` or
/// `AVAudioEngine` aggregate-device layer.
///
/// Format conversion is done EXPLICITLY, not by AUHAL: AUHAL input does NOT
/// resample (Apple QA1777 — "does not provide sample rate conversion" for
/// input on macOS), so the client format is set to the hardware's own native
/// rate (mono Float32), and an `AVAudioConverter` resamples to the pipeline's
/// 16kHz on the consumer thread, mirroring `AVAudioEngineSource`'s own
/// converter usage.
///
/// RT-safety: the render callback (`halRenderProc`, true HAL IO thread) does
/// `AudioUnitRender` into a preallocated scratch buffer (every read clamped to
/// its actual capacity, never trusting `inNumberFrames` alone), then a
/// fixed-size memcpy into `HALSampleRing` (locked, bounded, no allocation) —
/// see `keep-preroll-lock-minimal`. It wakes a dedicated consumer thread via
/// `DispatchSemaphore.signal()` (RT-safe; `DispatchQueue.async` is NOT — it
/// can allocate/lock on the calling thread). The heavier work (building an
/// `AVAudioPCMBuffer`, calling `PreRollForwarder.route()`) happens on that
/// consumer thread, one hop off the IO thread, mirroring where the other two
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

  /// Target capture device UID. Nil means follow the live system default input.
  var targetDeviceUID: String?

  var resolveDeviceIDForUID: (String) -> AudioDeviceID? = AudioDeviceEnumerator.deviceID(forUID:)
  var defaultInputDeviceIDProvider: () -> AudioDeviceID? =
    AudioDeviceEnumerator.defaultInputDeviceID

  // MARK: - Private state

  private var audioUnit: AudioUnit?
  private var renderContext: HALRenderContext?
  private var unmanagedContext: Unmanaged<HALRenderContext>?
  private var deviceIsAliveListenerDeviceID: AudioDeviceID?
  private var deviceIsAliveListenerBlock: AudioObjectPropertyListenerBlock?
  // #1434: mid-recording format-change listeners — one stored token PER
  // selector (stream format + nominal rate), same queue + add/remove
  // lifecycle as the DeviceIsAlive listener above.
  private var formatListenerDeviceID: AudioDeviceID?
  private var streamFormatListenerBlock: AudioObjectPropertyListenerBlock?
  private var nominalRateListenerBlock: AudioObjectPropertyListenerBlock?
  /// #1434: set (MainActor) when a format-change notification fired while
  /// capturing AND the re-read rate differs from the prepare-time rate.
  /// Log-and-telemetry only in v1 — never interrupts the recording. Reset
  /// per session in `startCapture()`.
  private var formatDivergenceObserved = false
  /// #1434 test seam: injectable native-rate reader (mirrors the existing
  /// `resolveDeviceIDForUID` injection pattern). Defaults to the real
  /// HAL property query.
  var nativeRateReader: (AudioDeviceID) -> Double? = { deviceID in
    HALDeviceInputSource.queryNativeStreamFormat(deviceID: deviceID)?.mSampleRate
  }
  private var forwarder: PreRollForwarder?
  /// Dedicated thread draining `HALRenderContext.ring` off the HAL IO thread.
  /// Retained only to keep it alive; its loop exits on its own once
  /// `teardownUnit()` signals the semaphore after the stop flag is set.
  private var consumerThread: Thread?
  private let captureLiveness = HALCaptureLivenessFlag()
  private var stoppedFlag: HALStoppedFlag?
  private var isRecovering = false

  private var boundDeviceID: AudioDeviceID?
  private var boundUID: String?
  private var boundTransport: String?
  private var lastBindOK = true

  var actualBoundTransport: String? { boundTransport }

  func resolvedDeviceIDForTesting() -> AudioDeviceID? {
    resolveDeviceID()
  }

  func setBoundDeviceIDForTesting(_ deviceID: AudioDeviceID?) {
    boundDeviceID = deviceID
  }

  func boundDeviceMatchesResolvedTargetForReuse() -> Bool {
    guard let boundDeviceID else { return false }
    return boundDeviceID == resolveDeviceID()
  }

  /// #1434: stop-time capture-health facts. The manager snapshots this BEFORE
  /// deactivate/teardown and attaches it to `CaptureResult.metadata` — the one
  /// transport object for both the in-process and XPC stop paths.
  var captureStopMetadata: CaptureStopMetadata? {
    guard let context = renderContext else { return nil }
    let snap = context.counters.snapshot()
    return CaptureStopMetadata(
      nativeRateHz: context.nativeFormat.sampleRate,
      ringDropCount: snap.ringDrops,
      converterErrorCount: snap.converterErrors,
      zeroOutputCount: snap.zeroOutputs,
      rateDivergenceDetected: formatDivergenceObserved
    )
  }

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
    lastBindOK = bindOK
    guard bindOK else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.set_device")
    }

    // AUHAL input does NOT resample (Apple QA1777: "does not provide sample
    // rate conversion" for input on macOS) — query the HARDWARE's actual
    // native rate and set the client format to MATCH it (mono/Float32 is
    // still safely convertible; sample RATE is not). Resampling to the
    // pipeline's 16kHz happens explicitly via AVAudioConverter on the
    // consumer thread (cloud review P2 on PR #1418 — the prior version
    // assumed a silent resample that only worked by coincidence on the
    // Bose, whose Bluetooth profile happens to already be 16kHz).
    guard let nativeASBD = Self.queryNativeStreamFormat(deviceID: deviceID) else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(
        source: "HALDeviceInputSource.prepare.query_native_format")
    }
    guard
      let nativeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: nativeASBD.mSampleRate, channels: 1,
        interleaved: false)
    else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.native_format")
    }
    guard let converter = AVAudioConverter(from: nativeFormat, to: Self.targetFormat) else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.converter")
    }

    // Client format on the input element's OUTPUT scope — what our render
    // callback receives, at the hardware's own rate.
    var clientFormat = nativeFormat.streamDescription.pointee
    status = AudioUnitSetProperty(
      unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
      &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    guard status == noErr else {
      AudioComponentInstanceDispose(unit)
      throw AudioError.formatCreationFailed(source: "HALDeviceInputSource.prepare.stream_format")
    }

    // Scratch/ring capacity scales with the native rate — a fixed 4096-frame
    // buffer sized for 16kHz would be too small at 44.1/48kHz. 300ms of
    // headroom at whatever rate the hardware actually runs.
    let capacityFrames = max(Int(Self.maxFramesPerSlice), Int(nativeFormat.sampleRate * 0.3))
    var maxFrames = UInt32(capacityFrames)
    let maxFramesStatus = AudioUnitSetProperty(
      unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
      &maxFrames, UInt32(MemoryLayout<UInt32>.size))
    if maxFramesStatus != noErr {
      // Non-fatal: the render callback clamps every read to the scratch
      // buffer's actual capacity regardless, so a device that ignores this
      // property still can't overrun — it just silently drops any frames
      // beyond capacity per callback. Logged (not RT-path) so the bake-off
      // evidence shows it happened.
      AudioCaptureManager.btRouteLog(
        "HALDeviceInputSource: kAudioUnitProperty_MaximumFramesPerSlice set failed (status=\(maxFramesStatus)) — render callback still clamps to scratch capacity"
      )
    }

    let scratch = AudioBufferList.allocate(maximumBuffers: 1)
    let scratchStorage = UnsafeMutableRawPointer.allocate(
      byteCount: capacityFrames * MemoryLayout<Float>.size,
      alignment: MemoryLayout<Float>.alignment
    )
    scratch[0] = AudioBuffer(
      mNumberChannels: 1,
      mDataByteSize: UInt32(capacityFrames * MemoryLayout<Float>.size),
      mData: scratchStorage
    )

    let ring = HALSampleRing(slotCount: Self.ringSlotCount, capacityPerSlot: capacityFrames)
    let stopped = HALStoppedFlag()
    let fwd = PreRollForwarder()
    let context = HALRenderContext(
      audioUnit: unit, scratch: scratch, capacityFrames: capacityFrames,
      ring: ring, stopped: stopped, liveness: captureLiveness, forwarder: fwd,
      nativeFormat: nativeFormat, targetFormat: Self.targetFormat, converter: converter)
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
    self.consumerThread = Self.makeConsumerThread(context: context)
    registerDeviceIsAliveListener(deviceID: deviceID)
    registerFormatChangeListeners(deviceID: deviceID)

    boundDeviceID = deviceID
    boundUID = AudioDeviceEnumerator.inputDeviceUID(for: deviceID)
    boundTransport = AudioDeviceEnumerator.transportLabel(for: deviceID)
    // #1434: the native rate + ratio in the prepare line is the per-recording
    // rate evidence D4 flagged as the highest-value instrumentation gap.
    let ratio = Self.targetFormat.sampleRate / nativeFormat.sampleRate
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource: prepared with device \(deviceID) (uid=\(boundUID ?? "unknown")) "
        + "nativeRate=\(Int(nativeFormat.sampleRate)) targetRate=\(Int(Self.targetFormat.sampleRate)) "
        + "ratio=\(String(format: "%.3f", ratio))"
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
    // #1434: per-session capture-health state. The warm unit outlives sessions
    // (deactivateCapture keeps it pre-rolling), so an idle-time format change
    // or pre-roll ring drop must not bleed into the next recording's telemetry.
    renderContext?.counters.reset()
    formatDivergenceObserved = false
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
      let evidenceBoundTransport = boundTransport ?? "unknown"
      AudioCaptureManager.btRouteLog(
        "CAPTURE_EVIDENCE backend=hal_device_input boundUID=\(boundUID ?? "unknown") boundDeviceID=\(boundDeviceID.map(String.init) ?? "nil") boundTransport=\(evidenceBoundTransport) bindOK=\(lastBindOK) requestedUID=\(targetDeviceUID ?? "system_default")"
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
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      // #1434: the stall fires BEFORE stopCapture(), so the source stamps its
      // own live rate/divergence here — the stop-time metadata object does
      // not exist yet. (The XPC proxy's host-side watchdog leaves these nil.)
      nativeRateHz: renderContext?.nativeFormat.sampleRate,
      rateDivergenceDetected: formatDivergenceObserved
    )
    onCaptureStalled?(ctx)
  }

  func deactivateCapture() {
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.returnToPreRoll()
    isCapturing = false
    streamContinuation = nil
    // #1434 session stats — dev-visible mirror of the CaptureStopMetadata the
    // manager reads via `captureStopMetadata` before this call.
    if let context = renderContext {
      let snap = context.counters.snapshot()
      AudioCaptureManager.btRouteLog(
        "HAL session stats: native=\(Int(context.nativeFormat.sampleRate)) "
          + "target=\(Int(context.targetFormat.sampleRate)) "
          + "ringDrops=\(snap.ringDrops) convErrors=\(snap.converterErrors) "
          + "zeroConvOut=\(snap.zeroOutputs) rateDivergence=\(formatDivergenceObserved)"
      )
    }
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource deactivated — unit stays warm, pre-roll capturing")
  }

  func stop() async -> [Float] {
    forwarder?.stop()
    forwarder = nil
    streamContinuation = nil
    // teardownUnit() cancels stallWorkItem and drops isCapturing.
    teardownUnit()
    // Source does not own samples — manager accumulates via onSamples callback.
    return []
  }

  /// Real settling check (#1434 — replaces a stub whose comment asserted the
  /// exact claim Apple QA1777 refutes: AUHAL does NOT resample input, so a
  /// device whose rate is still renegotiating DOES need waiting out).
  ///
  /// Two jobs, one contract:
  /// 1. SETTLED — poll the device's native rate until two consecutive reads
  ///    agree (mirrors `AVAudioEngineSource.waitForFormatStabilization`'s
  ///    two-reads-agree shape; Apple forum 770232 documents AirPods reporting
  ///    a transient wrong rate corrected by a later notification).
  /// 2. MATCHES — the settled rate must equal the rate this unit's converter
  ///    was built at in `prepare()`. A settled-but-DIVERGENT rate returns
  ///    false, which routes into the kernel's existing one-rebuild retry seam
  ///    (`RecordingSessionKernel` stabilization site) — `prepare()` then
  ///    re-reads the fresh rate and rebuilds the converter. The kernel makes
  ///    exactly one rebuild attempt and never re-checks stabilization after
  ///    it; residual failure is owned by the stall watchdog / ASR-empty paths.
  ///
  /// No bound device / no live unit → true (nothing to stabilize; matches the
  /// manager's no-active-source short-circuit).
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    guard let deviceID = boundDeviceID, let context = renderContext else { return true }
    let preparedRate = context.nativeFormat.sampleRate
    let stabStart = ContinuousClock.now
    let outcome = await Self.settleNativeRate(
      preparedRate: preparedRate,
      maxWait: maxWait,
      pollInterval: pollInterval,
      readRate: { [nativeRateReader] in nativeRateReader(deviceID) },
      sleep: { try? await Task.sleep(for: $0) }
    )
    let elapsed = Self.stabMs(ContinuousClock.now - stabStart)
    let settledLabel = outcome.settledRate.map { String(Int($0)) } ?? "unstable"
    AudioCaptureManager.btRouteLog(
      "HAL formatStab: settled=\(settledLabel) prepared=\(Int(preparedRate)) "
        + "matches=\(outcome.matchesPrepared) polls=\(outcome.polls) ms=\(elapsed)"
    )
    return outcome.matchesPrepared
  }

  /// Pure settle loop (#1434) — separated from the instance so tests can
  /// drive it with an injected reader + no-op sleep (`test-timing`: assert on
  /// the returned value, never the wall clock).
  ///
  /// SETTLED = two consecutive reads agree and are non-nil. The result is
  /// `matchesPrepared` — a settled-but-DIVERGENT rate is deliberately false
  /// (routes into the kernel's one-rebuild retry seam).
  struct RateSettleOutcome: Equatable {
    let settledRate: Double?
    let matchesPrepared: Bool
    let polls: Int
  }

  static func settleNativeRate(
    preparedRate: Double,
    maxWait: TimeInterval,
    pollInterval: TimeInterval,
    readRate: () -> Double?,
    sleep: (Duration) async -> Void
  ) async -> RateSettleOutcome {
    func outcome(_ settled: Double?, polls: Int) -> RateSettleOutcome {
      RateSettleOutcome(
        settledRate: settled,
        matchesPrepared: settled == preparedRate,
        polls: polls)
    }
    // Fast path: two reads 10ms apart agree (the common already-settled case
    // returns in ~10ms, keeping the warm PTT path cheap).
    var lastRate = readRate()
    await sleep(.milliseconds(10))
    var currentRate = readRate()
    if currentRate != nil, currentRate == lastRate {
      return outcome(currentRate, polls: 0)
    }
    // Bounded poll loop — polls is the budget (not wall-clock, so an injected
    // no-op sleep terminates deterministically).
    let maxPolls = max(1, Int(maxWait / max(pollInterval, 0.001)))
    var polls = 0
    while polls < maxPolls {
      lastRate = currentRate
      await sleep(.seconds(pollInterval))
      polls += 1
      currentRate = readRate()
      if currentRate != nil, currentRate == lastRate {
        return outcome(currentRate, polls: polls)
      }
    }
    // Never settled within the budget — unstable (false → rebuild seam).
    return outcome(nil, polls: polls)
  }

  /// Duration → ms for the stabilization log (file-local; the manager's
  /// equivalent helper is private to it).
  nonisolated private static func stabMs(_ d: Duration) -> Int {
    let (seconds, attoseconds) = d.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
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
    // Single authority for "this unit is going away" — every caller (normal
    // stop, abort, rebuild, AND device-vanish) must disarm the stall
    // watchdog and drop `isCapturing`, mirroring
    // `AVAudioEngineSource.emergencyTeardown()`'s same reset (its comment:
    // "isCapturing flips false ... which guards a late-fired watchdog").
    // Without this, a device-vanish mid-recording left the watchdog armed
    // and `isCapturing` stuck true — a late-firing watchdog could fire
    // `onCaptureStalled` after `onInterrupted` already handled the session,
    // and a same-second retry would see `alreadyCapturing` (cloud review P2).
    stallWorkItem?.cancel()
    stallWorkItem = nil
    isCapturing = false
    stoppedFlag?.set()
    removeDeviceIsAliveListener()
    removeFormatChangeListeners()
    if let unit = audioUnit {
      // Synchronous per Apple docs — blocks until the IO thread has genuinely
      // stopped calling the render callback, so nothing below can race a live
      // `halRenderProc` invocation.
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
    }
    // Wake the consumer thread (blocked on the semaphore) so it observes
    // `stoppedFlag` and exits its loop. No RT callback can signal again after
    // `AudioOutputUnitStop` returned above, so this is the FINAL signal —
    // the thread drains anything left, sees `stopped.isSet()`, and returns.
    renderContext?.semaphore.signal()
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
    consumerThread = nil
    boundDeviceID = nil
    boundUID = nil
    boundTransport = nil
  }

  // MARK: - Private: device resolution

  /// Resolve the pinned target device, falling back to the live system default.
  private func resolveDeviceID() -> AudioDeviceID? {
    if let uid = targetDeviceUID, !uid.isEmpty {
      if let id = resolveDeviceIDForUID(uid) { return id }
      AudioCaptureManager.btRouteLog(
        "HALDeviceInputSource: target device uid=\(uid) not found — falling back to system default")
    }
    return defaultInputDeviceIDProvider()
  }

  /// Read the device's OWN native stream format directly from the HAL device
  /// object (`kAudioDevicePropertyStreamFormat`, input scope) — the ground
  /// truth for what rate the hardware actually runs at, queried BEFORE we
  /// overwrite the AudioUnit's client-side format with our own request.
  private static func queryNativeStreamFormat(deviceID: AudioDeviceID)
    -> AudioStreamBasicDescription?
  {
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &format)
    return status == noErr ? format : nil
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

  // MARK: - Private: format-change listeners (#1434)

  /// Mid-recording format/rate-change observation — Apple's documented AirPods
  /// behavior (forum 770232) is a transient wrong rate corrected via exactly
  /// these notifications. Structural sibling of `registerDeviceIsAliveListener`:
  /// one stored token PER selector, the shared `listenerQueue`, and a MainActor
  /// hop before touching source state. v1 is LOG + FLAG only — a forced
  /// interruption would discard the dictation (#1408's known gap), converting
  /// degraded audio into guaranteed total loss.
  private func registerFormatChangeListeners(deviceID: AudioDeviceID) {
    var formatAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var rateAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let formatBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.handleDeviceFormatMayHaveChanged(deviceID: deviceID, selector: "streamFormat")
      }
    }
    let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.handleDeviceFormatMayHaveChanged(deviceID: deviceID, selector: "nominalRate")
      }
    }
    if AudioObjectAddPropertyListenerBlock(deviceID, &formatAddr, Self.listenerQueue, formatBlock)
      == noErr
    {
      streamFormatListenerBlock = formatBlock
      formatListenerDeviceID = deviceID
    }
    if AudioObjectAddPropertyListenerBlock(deviceID, &rateAddr, Self.listenerQueue, rateBlock)
      == noErr
    {
      nominalRateListenerBlock = rateBlock
      formatListenerDeviceID = deviceID
    }
  }

  private func removeFormatChangeListeners() {
    guard let deviceID = formatListenerDeviceID else { return }
    if let block = streamFormatListenerBlock {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(deviceID, &addr, Self.listenerQueue, block)
      streamFormatListenerBlock = nil
    }
    if let block = nominalRateListenerBlock {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(deviceID, &addr, Self.listenerQueue, block)
      nominalRateListenerBlock = nil
    }
    formatListenerDeviceID = nil
  }

  /// MainActor handler for either format-change selector. Guarded on
  /// `isCapturing` (idle/warm changes are the next prepare()'s problem — the
  /// per-session reset in `startCapture()` keeps them out of telemetry).
  private func handleDeviceFormatMayHaveChanged(deviceID: AudioDeviceID, selector: String) {
    guard isCapturing, let context = renderContext else { return }
    let preparedRate = context.nativeFormat.sampleRate
    let currentRate = nativeRateReader(deviceID)
    let diverged = currentRate != nil && currentRate != preparedRate
    AudioCaptureManager.btRouteLog(
      "HAL format change (\(selector)) mid-capture: prepared=\(Int(preparedRate)) "
        + "now=\(currentRate.map { String(Int($0)) } ?? "unknown") diverged=\(diverged)"
    )
    if diverged {
      formatDivergenceObserved = true
    }
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
    // Tear down BEFORE firing onInterrupted (mirrors AVAudioEngineSource's
    // emergencyTeardown-then-onInterrupted order). Without this, `isRunning`
    // still reports true (we never called AudioOutputUnitStop), so the
    // manager's warm-reuse check would try to resume capture on a HAL unit
    // bound to a device that no longer exists on the NEXT recording instead
    // of rebuilding fresh (cloud review P2).
    teardownUnit()
    onInterrupted?()
  }

  /// A dedicated thread that blocks on `context.semaphore` and drains the
  /// ring off the HAL IO thread. Signaling a semaphore (not
  /// `DispatchQueue.async`) from the render callback is the RT-safe wake
  /// primitive (Codex review r1 P2) — `async` enqueue can allocate/lock on
  /// the calling (IO) thread. Exits on its own once `teardownUnit()` signals
  /// after `stoppedFlag` is set — never joined, never needs to be.
  nonisolated private static func makeConsumerThread(context: HALRenderContext) -> Thread {
    let thread = Thread {
      while true {
        context.semaphore.wait()
        context.drainAndForward()
        if context.stopped.isSet() { break }
      }
    }
    thread.name = "com.enviouswispr.audio.hal-consumer"
    thread.qualityOfService = .userInteractive
    thread.start()
    return thread
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

  // Clamp BEFORE calling AudioUnitRender, not just after: if
  // `kAudioUnitProperty_MaximumFramesPerSlice` was ignored or the hardware
  // supplies more than `capacityFrames`, asking AudioUnitRender to write
  // `inNumberFrames` into a buffer only `capacityFrames` long is a write-side
  // overflow the post-render `min(...)` cannot undo (Codex review r2 P2 — the
  // read-side clamp alone was insufficient). Never render more than the
  // scratch buffer actually holds; a device that oversizes its slice loses
  // the excess of that one callback rather than overflowing.
  let clampedFrames = min(inNumberFrames, UInt32(context.capacityFrames))
  let byteCapacity = Int(clampedFrames) * MemoryLayout<Float>.size
  // Reset every render — `AudioUnitRender` can shrink `mDataByteSize` to the
  // actual bytes written, so a stale smaller value from a prior callback
  // would otherwise silently persist (Codex review r1 P1 context).
  context.scratch[0].mDataByteSize = UInt32(byteCapacity)

  let status = AudioUnitRender(
    context.audioUnit, ioActionFlags, inTimeStamp, 1, clampedFrames,
    context.scratch.unsafeMutablePointer)
  guard status == noErr else { return status }
  guard !context.stopped.isSet() else { return noErr }

  guard let data = context.scratch[0].mData else { return noErr }
  // Clamp again to what AudioUnitRender reports it actually wrote — never
  // trust the requested frame count alone.
  let renderedFrames = Int(context.scratch[0].mDataByteSize) / MemoryLayout<Float>.size
  let frameCount = min(Int(clampedFrames), renderedFrames)
  guard frameCount > 0 else { return noErr }
  let floatPtr = data.assumingMemoryBound(to: Float.self)

  var sum: Float = 0
  for i in 0..<frameCount { sum += floatPtr[i] * floatPtr[i] }
  let level = (sum / Float(frameCount)).squareRoot()

  // Only wake the consumer when a chunk was actually enqueued — a dropped
  // push (ring full, consumer lagging) has nothing for `drainAndForward` to
  // do, so signaling anyway just spins the consumer thread on empty work
  // (cloud review P2).
  if context.ring.push(floatPtr, count: frameCount, level: level) {
    context.semaphore.signal()
  } else {
    // #1434: a dropped chunk is lost audio — count it (bounded lock-inc, same
    // RT cost class as the ring lock) so a bad recording can prove or rule
    // out ring overrun instead of the drop staying invisible.
    context.counters.incrementRingDrop()
  }

  return noErr
}
