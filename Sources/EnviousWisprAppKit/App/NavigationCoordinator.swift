import Observation

/// Owns the "open this settings tab next" signal that menu actions and
/// in-app shortcuts hand off to the sidebar. Extracted from the former root state per
/// epic #763 (PR2, issue #765).
@MainActor
@Observable
final class NavigationCoordinator {
  private(set) var pendingDestination: SettingsDestination?

  func request(_ destination: SettingsDestination) {
    pendingDestination = destination
  }

  func consume() {
    pendingDestination = nil
  }

  /// #4353 D4: the model menu a screen should open when its card next appears or is already
  /// on screen. One at a time; a newer ask replaces an unconsumed one.
  private(set) var pendingModelMenu: ModelMenuRequest?

  func requestModelMenu(on surface: ProviderSetupSurface) {
    pendingModelMenu = ModelMenuRequest(surface: surface)
  }

  /// Consumes exactly the request the card saw, so a newer one is never lost.
  func consumeModelMenu(_ request: ModelMenuRequest) {
    if pendingModelMenu == request { pendingModelMenu = nil }
  }

  /// #4353 D4: one Settings control to bring into view and ring, through the same arrival a
  /// search result uses (scrolls only when it is not fully visible). Consumed by the window.
  private(set) var pendingReveal: SettingsMapID?

  func requestReveal(_ id: SettingsMapID) { pendingReveal = id }

  func consumeReveal() { pendingReveal = nil }
}
