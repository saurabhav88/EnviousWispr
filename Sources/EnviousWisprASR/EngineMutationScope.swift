package enum EngineMutationOutcome<T: Sendable>: Sendable {
  case refused
  case completed(T)
}

@MainActor
package struct EngineMutationScope {
  private let tryBegin: @MainActor () -> Bool
  private let end: @MainActor () -> Bool
  private let wake: @MainActor () -> Void
  private let onRefused: @MainActor (String) -> Void

  package static func live(
    tryBegin: @escaping @MainActor () -> Bool,
    end: @escaping @MainActor () -> Bool,
    wake: @escaping @MainActor () -> Void,
    onRefused: @escaping @MainActor (String) -> Void
  ) -> Self {
    Self(tryBegin: tryBegin, end: end, wake: wake, onRefused: onRefused)
  }

  /// Test-only, and INTENTIONALLY not a substitute for `.live(...)` anywhere
  /// production constructs a consumer. `internal`, not `package` or `public`
  /// (Grounded Review finding — `EnviousWisprASR` is an exported library
  /// product; a wider-than-`internal` always-allowed value is itself a
  /// silent-bypass risk if a real call site ever reaches for it by name, the
  /// same disease this plan exists to cure, one level down). Tests reach it
  /// via `@testable import EnviousWisprASR`. Mitigated structurally, not by
  /// naming alone: `EngineMutationInventoryFreezeTests` asserts ZERO
  /// references to `alwaysAllowedForTesting` under `Sources/`.
  internal static let alwaysAllowedForTesting = Self(
    tryBegin: { true }, end: { false }, wake: {}, onRefused: { _ in })

  /// Owns ONLY the claim/release/wake/refusal-telemetry ceremony — acquire
  /// once, run `operation`, always release and forward a wake if one is
  /// owed on every actual scope exit (return or throw, including a thrown
  /// `CancellationError`); emit refusal telemetry exactly once if the claim
  /// itself is refused.
  ///
  /// Task cancellation is cooperative and does not itself exit this scope.
  /// `Task.cancel()` only sets a flag; it does not force a running
  /// `operation` that ignores cancellation to return or throw. `defer`
  /// still guarantees release/wake on every exit that DOES happen, but it
  /// cannot make an uncooperative operation finish sooner.
  ///
  /// Deliberately does NOT interpret `Task` cancellation. Every site's own
  /// domain-specific cancellation and identity checks (e.g.
  /// `WhisperKitEngineAdapter`'s `sessionID`-keying re-check) stay inside
  /// that site's own `operation` closure, unchanged from today.
  package func withClaim<T: Sendable>(
    site: String,
    _ operation: @MainActor () async throws -> T
  ) async rethrows -> EngineMutationOutcome<T> {
    guard tryBegin() else {
      onRefused(site)
      return .refused
    }
    defer {
      if end() { wake() }
    }
    return .completed(try await operation())
  }
}
