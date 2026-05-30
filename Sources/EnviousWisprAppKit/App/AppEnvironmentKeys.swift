import EnviousWisprASR
import EnviousWisprLLM
import SwiftUI

/// PR-C.1 of #763 — custom SwiftUI environment keys for the two view-facing
/// homes that cannot use the object-based `.environment(_:)` modifier:
///
/// - `asrManager` is an `any ASRManagerInterface` existential; the protocol is
///   not `Observable`-constrained, so the object-based modifier does not apply.
/// - `KeychainManager` is a plain `Sendable` service, not `@Observable`.
///
/// The seven `@Observable` homes (settings, permissions, customWordsCoordinator,
/// setup, audioDeviceList, aiAvailability, llmDiscovery) use the object-based
/// `.environment(_:)` modifier directly and need no key here.
///
/// Values are optional with a `nil` default: `EnviousWisprApp` always injects a
/// real instance, so consuming views (migrated in PR-C.2 / PR-C.3) read a
/// non-nil value at runtime. The optionality exists only to satisfy
/// `EnvironmentKey`'s `defaultValue` requirement.

private struct ASRManagerEnvironmentKey: EnvironmentKey {
  // Computed (not a stored `static let`): `any ASRManagerInterface` is not
  // `Sendable`, so a stored static of this type trips Swift 6's
  // `#MutableGlobalVariable` concurrency check. A computed property returning
  // `nil` has no stored global state and is concurrency-safe.
  static var defaultValue: (any ASRManagerInterface)? { nil }
}

private struct KeychainManagerEnvironmentKey: EnvironmentKey {
  static let defaultValue: KeychainManager? = nil
}

extension EnvironmentValues {
  var asrManager: (any ASRManagerInterface)? {
    get { self[ASRManagerEnvironmentKey.self] }
    set { self[ASRManagerEnvironmentKey.self] = newValue }
  }

  var keychainManager: KeychainManager? {
    get { self[KeychainManagerEnvironmentKey.self] }
    set { self[KeychainManagerEnvironmentKey.self] = newValue }
  }
}
