#if DEBUG
  import Foundation
  import os

  /// DEBUG-only controller that substitutes captured audio with digital silence
  /// (exactly `0.0`) to reproduce the production `zombie_engine_zero_peak` dead-mic
  /// failure (#1317) on command. Test seam only — the whole type is compiled out of
  /// release (`#if DEBUG`), armed only when the fault endpoint is active.
  ///
  /// Owned by `AudioCaptureManager`, passed into every `PreRollForwarder`. Armed from
  /// MainActor (via the DEBUG XPC fault path) and consumed on capture threads, so it
  /// carries its own lock. It NEVER rebuilds, recovers, or messages the UI — it only
  /// decides which samples become zero and records that it did.
  ///
  /// Modes (sample-count based, not source-dependent buffer counts):
  /// - `.zeroFromStart` — zeroes drained pre-roll, activation delta, AND every live
  ///   sample. The only mode that touches pre-roll.
  /// - `.zeroAfter(threshold:)` — zeroes every live sample once `threshold` live
  ///   samples have committed (pre-roll and the leading `threshold` samples pass through).
  /// - `.zeroNext(budget:)` — zeroes the next `budget` live samples after arming, then
  ///   restores real audio (bounded-zero-then-restore).
  ///
  /// `zeroAfter`/`zeroNext` budgets count only LIVE (post-activation) samples, so idle
  /// warm-engine pre-roll cannot consume the requested lead or bounded-zero budget.
  final class DebugZeroFillController: @unchecked Sendable {

    enum Mode: Sendable, Equatable {
      case zeroFromStart
      case zeroAfter(threshold: Int)
      case zeroNext(budget: Int)
    }

    /// Which forwarding path is asking. `zeroFromStart` zeroes both; every other
    /// mode leaves `.preRollDrain` untouched.
    enum Context: Sendable { case preRollDrain, live }

    struct Status: Sendable {
      let armed: Bool
      let hit: Bool
      let trialID: String
      let mode: String
      let zeroedSampleCount: Int
    }

    private struct State {
      var mode: Mode?
      var trialID: String = ""
      var armed = false
      var hit = false
      var zeroedSampleCount = 0
      var liveSamplesSeen = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Arm / disarm (MainActor caller, but lock-guarded for safety)

    func arm(mode: Mode, trialID: String) {
      lock.withLock { s in
        s.mode = mode
        s.trialID = trialID
        s.armed = true
        s.hit = false
        s.zeroedSampleCount = 0
        s.liveSamplesSeen = 0
      }
    }

    func disarm() {
      lock.withLock { s in s = State() }
    }

    func status() -> Status {
      lock.withLock { s in
        Status(
          armed: s.armed,
          hit: s.hit,
          trialID: s.trialID,
          mode: s.mode.map(Self.modeTag) ?? "none",
          zeroedSampleCount: s.zeroedSampleCount
        )
      }
    }

    // MARK: - Zero-range decision (capture-thread caller)

    /// Decide which contiguous sub-range `[start, end)` of a `count`-sample chunk to
    /// zero, given the forwarding context, advancing live-sample accounting. Returns
    /// `nil` when nothing in this chunk is zeroed. A boundary chunk returns a partial
    /// range so the caller recomputes level from the transformed samples rather than
    /// reporting a false `0.0`.
    func zeroRange(count: Int, context: Context) -> Range<Int>? {
      guard count > 0 else { return nil }
      return lock.withLock { s -> Range<Int>? in
        guard s.armed, let mode = s.mode else { return nil }
        switch mode {
        case .zeroFromStart:
          if context == .live { s.liveSamplesSeen += count }
          s.zeroedSampleCount += count
          s.hit = true
          return 0..<count

        case .zeroAfter(let threshold):
          guard context == .live else { return nil }  // pre-roll passes through
          let startSeen = s.liveSamplesSeen
          s.liveSamplesSeen += count
          if startSeen >= threshold {
            s.zeroedSampleCount += count
            s.hit = true
            return 0..<count
          }
          let boundary = threshold - startSeen  // first zeroed index within this chunk
          guard boundary < count else { return nil }
          s.zeroedSampleCount += (count - boundary)
          s.hit = true
          return boundary..<count

        case .zeroNext(let budget):
          guard context == .live else { return nil }  // pre-roll passes through
          let startSeen = s.liveSamplesSeen
          s.liveSamplesSeen += count
          guard startSeen < budget else { return nil }  // budget spent → restore
          let end = min(count, budget - startSeen)
          s.zeroedSampleCount += end
          s.hit = true
          return 0..<end
        }
      }
    }

    /// True when this armed mode zeroes the pre-roll drain (only `.zeroFromStart`).
    var zeroesPreRoll: Bool {
      lock.withLock { s in
        guard s.armed, let mode = s.mode else { return false }
        if case .zeroFromStart = mode { return true }
        return false
      }
    }

    static func modeTag(_ m: Mode) -> String {
      switch m {
      case .zeroFromStart: return "zero_from_start"
      case .zeroAfter: return "zero_after_samples"
      case .zeroNext: return "zero_next_samples"
      }
    }
  }
#endif
