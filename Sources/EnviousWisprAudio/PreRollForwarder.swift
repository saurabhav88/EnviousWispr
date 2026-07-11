@preconcurrency import AVFoundation
import os

/// Thread-safe state machine with preallocated ring buffer for pre-roll audio capture.
///
/// Eliminates first-word clipping by capturing audio between prepare() and startCapture().
/// The tap handler routes converted audio through this forwarder, which buffers during
/// pre-roll and forwards to live callbacks during capture.
///
/// Four modes:
/// - `.preRolling` -- stores converted samples in ring buffer
/// - `.activating` -- callbacks installed, still buffering (ordering transition)
/// - `.capturing` -- forwards to live callbacks
/// - `.stopped` -- drops all samples
///
/// Two-step activation ensures strict sample ordering (no live audio before pre-roll):
/// 1. `beginActivation()` -- snapshots ring, installs callbacks, enters `.activating`
/// 2. Caller feeds pre-roll through callbacks
/// 3. `commitCapture()` -- drains delta, enters `.capturing`
final class PreRollForwarder: @unchecked Sendable {

  // MARK: - Types

  enum Mode: Sendable {
    case preRolling
    case activating
    case capturing
    case stopped
  }

  private struct State: Sendable {
    var mode: Mode = .preRolling
    var ring: [Float]
    var writeIdx: Int = 0
    var count: Int = 0
    var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  }

  // MARK: - State

  /// Ring buffer capacity in samples. 500ms at 16kHz.
  private let capacity: Int
  private let lock: OSAllocatedUnfairLock<State>

  #if DEBUG
    /// #1317 proof-bench: DEBUG-only all-zero injector. Set by the owning source
    /// (which received it from `AudioCaptureManager`) when it constructs the
    /// forwarder. Nil means ordinary forwarding. Compiled out of release.
    var debugZeroFillController: DebugZeroFillController?
  #endif

  // MARK: - Init

  /// Create a forwarder with a preallocated ring buffer.
  /// Default capacity: 8000 samples = 500ms at 16kHz = 32KB.
  init(capacity: Int = 8000) {
    self.capacity = capacity
    lock = OSAllocatedUnfairLock(
      initialState: State(
        ring: [Float](repeating: 0, count: capacity)
      ))
  }

  // MARK: - Audio Thread

  /// Route converted audio samples. Called from the audio thread on every tap callback.
  ///
  /// Lock hold time is minimal: mode check + memcpy (preRolling/activating) or pointer
  /// copy (capturing). Callbacks are invoked OUTSIDE the lock.
  func route(samples: [Float], level: Float, buffer: AVAudioPCMBuffer) {
    enum Action {
      case store
      case forward(
        onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
      )
      case drop
    }

    let action: Action = lock.withLock { state in
      switch state.mode {
      case .preRolling, .activating:
        appendToRing(samples, state: &state)
        return .store
      case .capturing:
        return .forward(
          onSamples: state.onSamples,
          onBuffer: state.onBuffer,
          continuation: state.continuation
        )
      case .stopped:
        return .drop
      }
    }

    switch action {
    case .store, .drop:
      break
    case .forward(let onSamples, let onBuffer, let continuation):
      #if DEBUG
        // #1317 proof-bench: substitute digital silence for the zeroed range,
        // transforming BOTH the sample array and the PCM buffer, and recomputing
        // level (0.0 only for a fully-zero chunk; recomputed RMS on a boundary
        // chunk). Same delivery cadence/frame-count; content only.
        // Confirm a writable Float32 mono buffer whose frame count matches the
        // sample array BEFORE asking the controller for a range — `zeroRange`
        // advances state and records the hit, so an unsupported buffer shape must
        // not consume the injector or claim a hit while the array and PCM diverge.
        // `zeroRange` is last in the chain (short-circuit) so it runs only when the
        // buffer can be zeroed identically to the array.
        if let ctl = debugZeroFillController,
          let ch = buffer.floatChannelData,
          Int(buffer.frameLength) == samples.count,
          buffer.format.commonFormat == .pcmFormatFloat32,
          buffer.format.channelCount == 1,
          let range = ctl.zeroRange(count: samples.count, context: .live)
        {
          var zeroed = samples
          for i in range {
            zeroed[i] = 0
            ch[0][i] = 0
          }
          let level: Float =
            zeroed.contains(where: { $0 != 0 })
            ? (zeroed.reduce(Float(0)) { $0 + $1 * $1 } / Float(zeroed.count)).squareRoot()
            : 0
          onSamples?(zeroed, level)
          onBuffer?(buffer)
          continuation?.yield(buffer)
          return
        }
      #endif
      onSamples?(samples, level)
      onBuffer?(buffer)
      continuation?.yield(buffer)
    }
  }

  // MARK: - MainActor (Two-Step Activation)

  /// Step 1: Install callbacks, snapshot ring contents, enter `.activating` mode.
  /// During `.activating`, `route()` still writes to ring (preserving ordering).
  /// Returns the pre-roll samples captured since prepare().
  func beginActivation(
    onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?,
    onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
    continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  ) -> [Float] {
    lock.withLock { state in
      state.onSamples = onSamples
      state.onBuffer = onBuffer
      state.continuation = continuation

      let result = drainRing(&state)
      state.mode = .activating
      return result
    }
  }

  /// Step 2: Drain any delta samples accumulated during activation, flip to `.capturing`.
  /// After this call, `route()` forwards directly through callbacks.
  func commitCapture() -> [Float] {
    lock.withLock { state in
      let delta = drainRing(&state)
      state.mode = .capturing
      return delta
    }
  }

  /// Return to pre-rolling mode. Called when recording stops but engine stays warm.
  /// Clears callbacks, finishes continuation, resets ring, but keeps forwarder alive
  /// so the tap continues capturing audio for the next recording.
  func returnToPreRoll() {
    resetTo(mode: .preRolling)
  }

  /// Stop forwarding. Idempotent. Finishes the stream continuation.
  func stop() {
    resetTo(mode: .stopped)
  }

  /// Shared teardown: clear callbacks, finish continuation, reset ring, set target mode.
  /// Idempotent for `.stopped` (skips if already stopped).
  private func resetTo(mode targetMode: Mode) {
    let cont: AsyncStream<AVAudioPCMBuffer>.Continuation? = lock.withLock { state in
      if targetMode == .stopped, state.mode == .stopped { return nil }
      let c = state.continuation
      state.continuation = nil
      state.onSamples = nil
      state.onBuffer = nil
      state.count = 0
      state.writeIdx = 0
      state.mode = targetMode
      return c
    }
    cont?.finish()
  }

  // MARK: - Two-Step Activation (Convenience)

  /// Full two-step activation: beginActivation, feed pre-roll, commitCapture, feed delta.
  /// Consolidates the repeated pattern from both AVAudioEngineSource and AVCaptureSessionSource.
  func activate(
    onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?,
    onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
    continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?,
    logPrefix: String
  ) -> Int {
    var preRollSamples = beginActivation(
      onSamples: onSamples,
      onBuffer: onBuffer,
      continuation: continuation
    )

    if !preRollSamples.isEmpty {
      #if DEBUG
        // #1317 proof-bench: zero_from_start also zeroes the drained pre-roll and
        // activation delta, so real audio captured before arming cannot leak into a
        // zero-from-start trial. Other modes leave pre-roll untouched.
        if let ctl = debugZeroFillController,
          let range = ctl.zeroRange(count: preRollSamples.count, context: .preRollDrain)
        {
          for i in range { preRollSamples[i] = 0 }
        }
      #endif
      Self.feedPreRoll(
        preRollSamples, onSamples: onSamples, onBuffer: onBuffer, continuation: continuation)
      AudioCaptureManager.btRouteLog(
        "\(logPrefix) pre-roll drained: \(preRollSamples.count) samples (\(Int(Double(preRollSamples.count) / 16000.0 * 1000))ms)"
      )
    } else {
      AudioCaptureManager.btRouteLog(
        "\(logPrefix) pre-roll empty: no samples buffered during setup")
    }

    var delta = commitCapture()
    if !delta.isEmpty {
      #if DEBUG
        if let ctl = debugZeroFillController,
          let range = ctl.zeroRange(count: delta.count, context: .preRollDrain)
        {
          for i in range { delta[i] = 0 }
        }
      #endif
      Self.feedPreRoll(delta, onSamples: onSamples, onBuffer: onBuffer, continuation: continuation)
      AudioCaptureManager.btRouteLog("\(logPrefix) pre-roll delta: \(delta.count) samples")
    }

    return preRollSamples.count + delta.count
  }

  // MARK: - Pre-Roll Drain Helper

  /// Feed drained pre-roll samples through callbacks and reconstructed AVAudioPCMBuffers.
  /// Called from MainActor after beginActivation()/commitCapture() returns samples.
  /// Chunks samples into ~40ms segments to match streaming ASR cadence.
  static func feedPreRoll(
    _ samples: [Float],
    onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?,
    onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
    continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  ) {
    guard !samples.isEmpty else { return }

    let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    onSamples?(samples, rms)

    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
      )
    else { return }

    // ~40ms chunks at 16kHz
    let chunkSize = 640
    var offset = 0
    while offset < samples.count {
      let thisChunk = min(samples.count - offset, chunkSize)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(thisChunk)
        )
      else {
        offset += thisChunk
        continue
      }
      buffer.frameLength = AVAudioFrameCount(thisChunk)
      if let channelData = buffer.floatChannelData {
        samples.withUnsafeBufferPointer { src in
          channelData[0].update(from: src.baseAddress! + offset, count: thisChunk)
        }
      }
      onBuffer?(buffer)
      continuation?.yield(buffer)
      offset += thisChunk
    }
  }

  // MARK: - Private

  /// Append samples to the circular ring buffer. MUST be called under lock.
  private func appendToRing(_ samples: [Float], state: inout State) {
    for sample in samples {
      state.ring[state.writeIdx] = sample
      state.writeIdx = (state.writeIdx + 1) % capacity
    }
    state.count = min(state.count + samples.count, capacity)
  }

  /// Drain ring buffer contents in chronological order. Resets ring state.
  /// MUST be called under lock.
  private func drainRing(_ state: inout State) -> [Float] {
    let count = state.count
    guard count > 0 else { return [] }

    var result = [Float]()
    result.reserveCapacity(count)
    let startIdx = (state.writeIdx - count + capacity) % capacity
    for i in 0..<count {
      result.append(state.ring[(startIdx + i) % capacity])
    }

    state.count = 0
    state.writeIdx = 0
    return result
  }
}
