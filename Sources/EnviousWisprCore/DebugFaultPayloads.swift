#if DEBUG
  import Foundation

  /// #1317 proof-bench (DEBUG only): JSON wire payloads for the DEBUG all-zero
  /// injector's XPC arm/status channel. They cross the `@objc AudioServiceProtocol`
  /// boundary as `Data` (the protocol is `@objc`, so only plist types travel
  /// directly). Whole file compiled out of release.
  ///
  /// `package` access: shared across `EnviousWisprCore`, `EnviousWisprAudio`
  /// (proxy + manager), `EnviousWisprAudioService` (handler), and
  /// `EnviousWisprAppKit` (`DebugFaultEndpoint`) — all one SPM package. Matches
  /// the existing DEBUG-seam access level (`AudioCaptureProxy.forceStallRemainingBuffers`).

  /// Arm request: which zero-fill mode, its sample budget/threshold, and the
  /// trial id the harness correlates status against.
  package struct DebugZeroFillArm: Codable, Sendable {
    /// Wire form of `DebugZeroFillController.Mode`. `AudioCaptureManager` (service
    /// side) translates this into the controller's associated-value enum — the
    /// controller type itself stays module-internal.
    package enum Mode: String, Codable, Sendable {
      case zeroFromStart = "zero_from_start"
      case zeroAfterSamples = "zero_after_samples"
      case zeroNextSamples = "zero_next_samples"
      /// Clears any armed fault (disarms the controller). Lets the bench restore a
      /// clean pipe for a positive-control take, so "no canary on the dead take" is
      /// distinguishable from "TTS/ASR broken." `n`/`trialID` are ignored.
      case disarmed = "disarmed"
    }

    package let mode: Mode
    /// Threshold (for `zeroAfterSamples`) or budget (for `zeroNextSamples`) in
    /// LIVE samples. Ignored for `zeroFromStart`.
    package let n: Int
    package let trialID: String

    package init(mode: Mode, n: Int, trialID: String) {
      self.mode = mode
      self.n = n
      self.trialID = trialID
    }
  }

  /// Service-side status snapshot returned across XPC. The proxy merges its own
  /// `ConnectionSlot.current.generation` on top of these fields before handing a
  /// complete status to the endpoint; `armed` is never evidence of `hit`.
  package struct DebugFaultServiceStatus: Codable, Sendable {
    package let armed: Bool
    package let hit: Bool
    package let trialID: String
    package let mode: String
    package let zeroedSampleCount: Int
    /// Monotonic manager-owned resource generation — the `fresh_pipe_proven`
    /// oracle. NOT the capture-session id.
    package let sourceIncarnation: UInt64
    /// Low-cardinality tag of the ACTIVE capture backend the injector is riding
    /// (`av_audio_engine` / `hal_device_input` / `none`),
    /// so the scorecard records WHICH mic route each trial ran on — the built-in
    /// vs Bluetooth path cannot otherwise be distinguished in the evidence.
    package let captureSourceType: String

    package init(
      armed: Bool, hit: Bool, trialID: String, mode: String,
      zeroedSampleCount: Int, sourceIncarnation: UInt64, captureSourceType: String
    ) {
      self.armed = armed
      self.hit = hit
      self.trialID = trialID
      self.mode = mode
      self.zeroedSampleCount = zeroedSampleCount
      self.sourceIncarnation = sourceIncarnation
      self.captureSourceType = captureSourceType
    }
  }
#endif
