import Foundation

/// #4353 D4: a one-shot ask to open ONE screen's cloud model menu, raised by the "Select a new
/// cloud model" button. Carries its own identity so asking twice opens the menu twice, and the
/// surface so only that screen's card consumes it. Never persisted.
struct ModelMenuRequest: Equatable, Sendable {
  let surface: ProviderSetupSurface
  let id: UUID

  init(surface: ProviderSetupSurface, id: UUID = UUID()) {
    self.surface = surface
    self.id = id
  }

  /// The request a mounted card should act on now, or nil to leave it pending: only its own
  /// surface, only a cloud provider, and only once the menu can open (models loaded). A request
  /// left pending is acted on when the models arrive.
  static func toOpen(
    pending: ModelMenuRequest?, surface: ProviderSetupSurface, providerIsCloud: Bool,
    modelsLoaded: Bool
  ) -> ModelMenuRequest? {
    guard let pending, pending.surface == surface, providerIsCloud, modelsLoaded else {
      return nil
    }
    return pending
  }
}
