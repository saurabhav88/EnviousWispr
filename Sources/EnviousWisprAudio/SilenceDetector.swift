import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation

/// #905 test seam — the narrow per-chunk VAD streaming surface `SilenceDetector`
/// depends on. Lets a fake substitute for the concrete FluidAudio `VadManager`
/// (which needs a real Silero CoreML model, unreachable in a unit test), so the
/// "streaming clock advances on every chunk, before the energy gate" contract
/// (#604 followup) can be tested behaviorally instead of by grepping source text.
///
/// `SilenceDetector` is an `actor` (not `@MainActor`), so an `any StreamingVad`
/// existential is fine here — `avoid-any-mainactor-protocol-hotpath` does not
/// bind, and per-chunk existential dispatch at ~10 Hz is negligible. The real
/// `VadManager` conforms via an empty extension; the field is still built lazily
/// in `prepare()`, defaulting to the real manager, so production is unchanged.
internal protocol StreamingVad: Sendable {
  func processStreamingChunk(
    _ audioChunk: [Float],
    state: VadStreamState,
    config: VadSegmentationConfig,
    returnSeconds: Bool,
    timeResolution: Int
  ) async throws -> VadStreamResult
}

extension VadManager: StreamingVad {}

public struct SmoothedVADConfig: Sendable {
  public var emaAlpha: Float = 0.3
  public var onsetThreshold: Float = 0.5
  public var offsetThreshold: Float = 0.35
  public var onsetConfirmationChunks: Int = 1
  public var hangoverChunks: Int = 3  // periphery:ignore - public config field; SilenceDetector uses effectiveHangoverChunks but callers may set this
  public var prebufferChunks: Int = 2
  public var energyGateThreshold: Float = 0.0

  public init(
    emaAlpha: Float = 0.3,
    onsetThreshold: Float = 0.5,
    offsetThreshold: Float = 0.35,
    onsetConfirmationChunks: Int = 1,
    hangoverChunks: Int = 3,
    prebufferChunks: Int = 2,
    energyGateThreshold: Float = 0.0
  ) {
    self.emaAlpha = emaAlpha
    self.onsetThreshold = onsetThreshold
    self.offsetThreshold = offsetThreshold
    self.onsetConfirmationChunks = onsetConfirmationChunks
    self.hangoverChunks = hangoverChunks
    self.prebufferChunks = prebufferChunks
    self.energyGateThreshold = energyGateThreshold
  }

  public static func fromSensitivity(_ sensitivity: Float, energyGate: Bool = false)
    -> SmoothedVADConfig
  {
    let onset = 0.6 - (sensitivity * 0.375)  // 0.225 at sens=1.0, 0.6 at sens=0.0
    let offset = max(0.1, onset - 0.15)
    let alpha = 0.3 + (sensitivity * 0.2)  // 0.32 at sens=0.1, 0.46 at sens=0.8
    let hangover = sensitivity > 0.7 ? 4 : 3
    let confirmation = sensitivity < 0.3 ? 2 : 1

    // Energy gate scales with sensitivity. Disabled on high sensitivity (Quiet)
    // to avoid blocking whispered speech before Silero can evaluate it.
    let energy: Float
    if !energyGate {
      energy = 0.0
    } else if sensitivity >= 0.7 {
      energy = 0.0
    } else {
      energy = 0.005 * (1.0 - sensitivity * 0.6)
    }

    return SmoothedVADConfig(
      emaAlpha: alpha,
      onsetThreshold: onset,
      offsetThreshold: offset,
      onsetConfirmationChunks: confirmation,
      hangoverChunks: hangover,
      energyGateThreshold: energy
    )
  }
}

enum SmoothedVADPhase: Sendable {
  case idle
  case speech
  case hangover(chunksRemaining: Int)
}

/// Monitors audio for speech activity and detects silence after speech for auto-stop.
///
/// Uses FluidAudio's Silero VAD model for raw probability, then applies EMA smoothing
/// and a three-phase state machine (idle/speech/hangover) for robust onset/offset detection.
/// Processes 4096-sample chunks (256ms at 16kHz).
///
/// Two-signal contract (do not conflate):
///   - Segment boundaries (`speechSegments`) come from FluidAudio's
///     `VadStreamResult.event` (`.speechStart` / `.speechEnd`). Authoritative.
///     Closed at recording stop by `finalizeSegments` if `.speechEnd` did not fire.
///   - Auto-stop (`shouldAutoStop` from `processChunk`) comes from the smoothed
///     EMA + hangover state machine on raw probability.
/// Migrating either signal onto the other path requires a deliberate decision —
/// they have different timing, different thresholds, and serve different consumers
/// (WhisperKit clipTimestamps vs recording-stop UX). See issue #604.
public actor SilenceDetector {
  private var vadManager: (any StreamingVad)?
  /// #905 seam — builds the VAD lazily in `prepare()`. Defaults to the real
  /// `VadManager`; a test injects a fake. Behavior-identical by default.
  private let makeStreamingVad: @Sendable () async throws -> any StreamingVad
  private var streamState: VadStreamState = .initial()
  public private(set) var speechDetected = false
  public private(set) var isReady = false
  public private(set) var speechSegments: [SpeechSegment] = []
  private var currentSpeechStart: Int? = nil
  private var processedSampleCount: Int = 0

  // SmoothedVAD state
  private var phase: SmoothedVADPhase = .idle
  private var emaSmoothedProbability: Float = 0.0
  private var consecutiveAboveOnset: Int = 0
  public private(set) var vadConfig: SmoothedVADConfig

  // Prebuffer ring buffer
  private var prebuffer: [[Float]] = []
  private var prebufferWriteIndex: Int = 0
  private var prebufferFilled: Bool = false

  public private(set) var silenceTimeout: TimeInterval

  /// Chunk size expected by the Silero VAD model (256ms at 16kHz).
  public nonisolated static let chunkSize = 4096

  /// Hangover chunks derived from silenceTimeout so the detector waits
  /// the full user-configured duration before auto-stopping.
  private var effectiveHangoverChunks: Int {
    let chunkDurationSeconds = Double(Self.chunkSize) / AudioConstants.sampleRate  // 0.256s
    return max(3, Int(ceil(silenceTimeout / chunkDurationSeconds)))
  }

  /// - Parameter modelBundle: the bundle to load the VAD model from. Defaults
  ///   to `.main`, which is process-scoped and correctly resolves to whichever
  ///   process is calling (the audio XPC service or the main app's
  ///   direct-capture-mode fallback both bundle this asset into their own
  ///   `.main`, #1224). Explicit rather than implicit so the dependency is
  ///   documented and tests can inject a fixture bundle.
  public init(
    silenceTimeout: TimeInterval = 1.5, vadConfig: SmoothedVADConfig = SmoothedVADConfig(),
    modelBundle: Bundle = .main
  ) {
    // Delegate to the internal seam init with the real VAD factory. The seam is
    // internal (not public) so the protocol stays inside the module — #905 keeps
    // this MEDIUM, not REFACTOR. Tests reach the seam via `@testable import`.
    self.init(
      silenceTimeout: silenceTimeout, vadConfig: vadConfig,
      makeStreamingVad: {
        let model = try BundledVADModelLoader.loadModel(in: modelBundle)
        return VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
      })
  }

  /// #905 seam init — internal so the `StreamingVad` parameter does not widen the
  /// public surface. `@testable` tests inject a fake here.
  init(
    silenceTimeout: TimeInterval = 1.5,
    vadConfig: SmoothedVADConfig = SmoothedVADConfig(),
    makeStreamingVad: @Sendable @escaping () async throws -> any StreamingVad
  ) {
    self.silenceTimeout = silenceTimeout
    self.vadConfig = vadConfig
    self.makeStreamingVad = makeStreamingVad
  }

  /// Load the Silero VAD model. Call once before processing.
  public func prepare() async throws {
    guard !isReady else { return }
    vadManager = try await makeStreamingVad()
    isReady = true
  }

  /// Reset streaming state for a new recording session.
  public func reset() {
    streamState = .initial()
    speechDetected = false
    speechSegments = []
    currentSpeechStart = nil
    processedSampleCount = 0
    phase = .idle
    emaSmoothedProbability = 0.0
    consecutiveAboveOnset = 0
    prebuffer.removeAll(keepingCapacity: true)
    prebufferWriteIndex = 0
    prebufferFilled = false
  }

  /// Update the SmoothedVAD configuration.
  public func updateConfig(_ config: SmoothedVADConfig) {
    vadConfig = config
  }

  /// Update the silence timeout on a retained instance (#1224). Needed once
  /// the detector survives across recordings — the old per-recording
  /// reconstruction picked up a changed value for free at init time.
  /// `effectiveHangoverChunks` reads `silenceTimeout` live, so this takes
  /// effect on the very next chunk processed.
  public func updateSilenceTimeout(_ newValue: TimeInterval) {
    silenceTimeout = newValue
  }

  /// Process a chunk of 4096 audio samples (16kHz mono).
  /// Returns `true` if silence after speech is detected (auto-stop should trigger).
  public func processChunk(_ samples: [Float]) async -> Bool {
    guard let vad = vadManager else { return false }

    // 1. Write chunk to prebuffer (always)
    writeToPrebuffer(samples)

    // 2. Always run FluidAudio's streaming VAD on every chunk so its internal
    //    sample clock (`VadStreamState.processedSamples`) stays in lock-step
    //    with our buffer. Boundary events carry sample indices in that clock;
    //    skipping a chunk would drift the two clocks apart and produce wrong
    //    `SpeechSegment` boundaries downstream (issue #604 followup,
    //    Codex-flagged 2026-05-04). The energy gate now only suppresses what
    //    we feed into the smoothed-EMA auto-stop path; it must NOT bypass
    //    `processStreamingChunk`.
    // `speechPadding: 0.0` puts the boundary exactly at the chunk where
    // probability crossed threshold (no library-default 100ms back-dating).
    // Codex round-2 (2026-05-04) flagged this as potentially clipping soft
    // leading phonemes; the corpus run will validate empirically whether
    // that hypothetical bites our `.validation/uat-602/corpus/multilingual/`
    // cases. If the corpus shows clipping, flip back to FluidAudio's
    // calibrated default (0.1) — the Parakeet batch path already uses
    // equivalent 100ms boundary padding via `SampleFilter.filter(padding:)`.
    let segConfig = VadSegmentationConfig(
      minSpeechDuration: 0.3,
      minSilenceDuration: silenceTimeout,
      speechPadding: 0.0
    )

    let result: VadStreamResult
    do {
      result = try await vad.processStreamingChunk(
        samples,
        state: streamState,
        config: segConfig,
        returnSeconds: false,
        timeResolution: 1
      )
    } catch {
      Task {
        await AppLogger.shared.log(
          "VAD processChunk failed: \(error)",
          level: .verbose, category: "VAD"
        )
      }
      processedSampleCount += samples.count
      return false
    }

    streamState = result.state
    if let event = result.event {
      applyStreamBoundary(event)
    }

    // 3. Energy gate: zero the smoothed-EMA input on quiet chunks. This affects
    //    auto-stop only — boundary events were already applied above using
    //    FluidAudio's authoritative clock.
    let rawProbability: Float
    if vadConfig.energyGateThreshold > 0 && computeRMS(samples) < vadConfig.energyGateThreshold {
      rawProbability = 0.0
    } else {
      rawProbability = result.probability
    }

    return advanceStateMachine(rawProbability: rawProbability, samplesInChunk: samples.count)
  }

  /// Drives the smoothed-EMA + hangover state machine for one chunk's worth of
  /// processed samples. Separated from `processChunk` so unit tests can exercise
  /// the auto-stop path with synthetic probability streams without a real VAD model.
  ///
  /// Internal access for `@testable` unit tests; not part of the public contract.
  ///
  /// Two-signal contract: this function MUST NOT touch `speechSegments`. Segment
  /// boundaries are owned by `applyStreamBoundary`. See actor doc comment.
  internal func advanceStateMachine(rawProbability: Float, samplesInChunk: Int) -> Bool {
    // EMA smoothing
    let smoothed =
      vadConfig.emaAlpha * rawProbability + (1.0 - vadConfig.emaAlpha) * emaSmoothedProbability
    emaSmoothedProbability = smoothed

    var shouldAutoStop = false

    switch phase {
    case .idle:
      if smoothed >= vadConfig.onsetThreshold {
        consecutiveAboveOnset += 1
        if consecutiveAboveOnset >= vadConfig.onsetConfirmationChunks {
          phase = .speech
          speechDetected = true

          // Reset prebuffer ring on phase entry. Vestigial side-effect from
          // the pre-#604 design where the prebuffer drove segment start
          // backdating; segment boundaries now come from FluidAudio events
          // (see actor doc comment + `applyStreamBoundary`). Kept to avoid
          // unbounded prebuffer growth across multiple segments.
          _ = drainPrebuffer()
        }
      } else {
        consecutiveAboveOnset = 0
      }

    case .speech:
      if smoothed < vadConfig.offsetThreshold {
        phase = .hangover(chunksRemaining: effectiveHangoverChunks)
      }

    case .hangover(let remaining):
      if smoothed >= vadConfig.onsetThreshold {
        // Speech resumed, go back to speech phase
        phase = .speech
      } else {
        let next = remaining - 1
        if next <= 0 {
          // Hangover expired: signal auto-stop. Segment boundaries are owned
          // by FluidAudio events (see actor doc comment) — do NOT close the
          // segment here. Any open `currentSpeechStart` will be closed either
          // by a subsequent `.speechEnd` event or by `finalizeSegments` when
          // the caller stops recording in response to `shouldAutoStop`.
          phase = .idle
          consecutiveAboveOnset = 0
          shouldAutoStop = true
        } else {
          phase = .hangover(chunksRemaining: next)
        }
      }
    }

    processedSampleCount += samplesInChunk

    return shouldAutoStop
  }

  public func finalizeSegments(totalSampleCount: Int) {
    if let start = currentSpeechStart {
      speechSegments.append(
        SpeechSegment(
          startSample: start,
          endSample: totalSampleCount
        ))
      currentSpeechStart = nil
    }
  }

  // MARK: - Private Helpers

  /// Applies a FluidAudio streaming VAD boundary event to `speechSegments`.
  ///
  /// FluidAudio's streaming state machine emits `.speechStart` / `.speechEnd`
  /// with a back-dated `sampleIndex` (see
  /// `.build/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadManager+Streaming.swift`).
  /// This is the authoritative source of truth for segment boundaries; the
  /// smoothed-EMA phase machine in `processChunk` does NOT touch `speechSegments`.
  ///
  /// Internal access for `@testable` unit tests; not part of the public contract.
  internal func applyStreamBoundary(_ event: VadStreamEvent) {
    switch event.kind {
    case .speechStart:
      currentSpeechStart = event.sampleIndex
    case .speechEnd:
      guard let start = currentSpeechStart else { return }
      guard event.sampleIndex > start else {
        currentSpeechStart = nil
        return
      }
      speechSegments.append(
        SpeechSegment(
          startSample: start,
          endSample: event.sampleIndex
        ))
      currentSpeechStart = nil
    }
  }

  private func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0.0 }
    let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumOfSquares / Float(samples.count)).squareRoot()
  }

  private func writeToPrebuffer(_ chunk: [Float]) {
    let capacity = vadConfig.prebufferChunks
    guard capacity > 0 else { return }

    if prebuffer.count < capacity {
      // Still filling up the buffer
      prebuffer.append(chunk)
    } else {
      // Overwrite oldest entry in ring buffer fashion
      prebuffer[prebufferWriteIndex] = chunk
      prebufferFilled = true
    }
    prebufferWriteIndex = (prebufferWriteIndex + 1) % capacity
  }

  private func drainPrebuffer() -> [Float] {
    guard !prebuffer.isEmpty else { return [] }

    let count = prebuffer.count
    // Pre-allocate capacity to avoid repeated reallocations during append
    let estimatedSize = count * Self.chunkSize
    var result: [Float] = []
    result.reserveCapacity(estimatedSize)

    if prebufferFilled {
      // Read from writeIndex (oldest) through the buffer
      for i in 0..<count {
        let idx = (prebufferWriteIndex + i) % count
        result.append(contentsOf: prebuffer[idx])
      }
    } else {
      // Buffer not yet full, read in order
      for chunk in prebuffer {
        result.append(contentsOf: chunk)
      }
    }

    // Clear the prebuffer after draining (use removeAll to reuse capacity)
    prebuffer.removeAll(keepingCapacity: true)
    prebufferWriteIndex = 0
    prebufferFilled = false

    return result
  }
}
