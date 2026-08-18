import Foundation
import Speech

/// The real macOS claim table behind `LocaleClaims`.
///
/// The ONLY file that names `AssetInventory`. Everything that decides anything —  which locale to
/// release, whether to evict, whether to retry — lives in `LocaleClaims` and `AppleLocaleClaim`,
/// where a test can reach it. This adapter is deliberately dumb: four calls, no policy, nothing to
/// get wrong that a reader cannot see at a glance. #2145 is what the opposite arrangement cost.
extension LocaleInventory {
  package static let live = LocaleInventory(
    reserved: {
      guard #available(macOS 26.0, *) else { return [] }
      return await AssetInventory.reservedLocales
    },
    reserve: { locale in
      guard #available(macOS 26.0, *) else { return false }
      return try await AssetInventory.reserve(locale: locale)
    },
    release: { locale in
      guard #available(macOS 26.0, *) else { return false }
      return await AssetInventory.release(reservedLocale: locale)
    },
    maximumReserved: {
      // `Int.max` below macOS 26, not 0: the Apple engine is unreachable there (the resolver
      // returns `.unsupportedSystem`), and a 0 would make the capacity branch fire on an empty
      // table if it ever were reached. Fail towards doing nothing.
      guard #available(macOS 26.0, *) else { return Int.max }
      return AssetInventory.maximumReservedLocales
    }
  )
}
