// AppKit-local (not EnviousWisprASR) — its sole producer (WisprBootstrapper)
// and sole consumer (RecoveryCoordinator) are both already here, so this
// needs no cross-module visibility at all.

@MainActor
struct RecoveryEngineClaim {
  private let tryBeginAction: @MainActor () -> Bool
  private let endAction: @MainActor () -> Void

  static func live(
    tryBegin: @escaping @MainActor () -> Bool,
    end: @escaping @MainActor () -> Void
  ) -> Self {
    Self(tryBeginAction: tryBegin, endAction: end)
  }

  /// Same structural mitigation as `EngineMutationScope.alwaysAllowedForTesting`
  /// — zero production references, enforced by the same freeze test.
  internal static let alwaysAllowedForTesting = Self(
    tryBeginAction: { true }, endAction: {})

  func tryBegin() -> Bool { tryBeginAction() }
  func end() { endAction() }
}
