import Foundation

/// When the helper frees its model memory (#3853). The helper keeps running; only the models
/// go, and the next request that needs them loads them again. Pure and clock-free: every
/// method is handed the time, so the rule is tested with a made-up clock.
///
/// "Idle" means the helper has not used its models for `idleSeconds`. A request that only asks
/// whether the helper is alive never counts as use, or the app's own health checks would keep
/// the models loaded forever. Time is the monotonic uptime in nanoseconds
/// (`DispatchTime.now().uptimeNanoseconds`), which does not advance while the Mac sleeps.
package struct EnviousDecodeIdleSleep: Equatable, Sendable {
  /// How long the models may sit unused before they are freed, or nil for never.
  package let idleNanoseconds: UInt64?
  private var lastUse: UInt64

  /// `startedAt` counts as the first use: a helper that loaded and has not been asked anything
  /// yet is idle from that moment.
  package init(idleSeconds: Int?, startedAt: UInt64) {
    idleNanoseconds = idleSeconds.flatMap { $0 > 0 ? UInt64($0) * 1_000_000_000 : nil }
    lastUse = startedAt
  }

  /// A request used the models, or finished using them, at `now`.
  package mutating func noteUse(at now: UInt64) {
    lastUse = max(lastUse, now)
  }

  /// True when the models are loaded, nothing is loading them, and they have been unused for
  /// the whole idle time. A `now` before the last use (a clock that went backwards) is not idle.
  package func shouldSleep(at now: UInt64, modelsLoaded: Bool, isLoading: Bool) -> Bool {
    guard let idleNanoseconds, modelsLoaded, !isLoading, now >= lastUse else { return false }
    return now - lastUse >= idleNanoseconds
  }
}
