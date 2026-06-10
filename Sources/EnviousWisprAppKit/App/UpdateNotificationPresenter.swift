import EnviousWisprCore
import Foundation
import UserNotifications

/// #1019 — narrow seam over the local-notification mechanics so
/// `UpdateCoordinator` can own the *policy* (when to fire, once-per-version,
/// install guard) while the `UNUserNotificationCenter` *mechanics* (permission
/// request, posting, tap delegate) stay injectable and out of unit tests.
@MainActor
protocol UpdateNotifying: AnyObject {
  /// Invoked when the user taps the notification (or its Install action).
  /// `UpdateCoordinator` sets this and routes it through the active-dictation
  /// guard before triggering an install.
  var onInstallTapped: (() -> Void)? { get set }

  /// Lazily request authorization (first time only) and post a single
  /// "update ready" notification. A no-op if the user denied permission.
  func post(displayVersion: String)
}

/// Production `UNUserNotificationCenter` implementation. Construction is inert
/// (no `UNUserNotificationCenter.current()` touch) so unit tests that build an
/// `UpdateCoordinator` with the default notifier never reach into the
/// notification subsystem — only `post(displayVersion:)` does, and that path is
/// exercised only in the running app / Live UAT.
@MainActor
final class UpdateNotificationPresenter: NSObject, UpdateNotifying {
  var onInstallTapped: (() -> Void)?

  /// Category + action identifiers for the "Install" affordance on the banner.
  private static let categoryIdentifier = "com.enviouswispr.updateReady"
  private static let installActionIdentifier = "com.enviouswispr.updateReady.install"

  private var delegateInstalled = false

  func post(displayVersion: String) {
    let center = UNUserNotificationCenter.current()
    installDelegateIfNeeded(center)
    // `requestAuthorization` is idempotent: after the user's first decision it
    // returns the existing grant without re-prompting. So this both lazily
    // requests permission the first time and gates on it thereafter. The
    // completion captures only Sendable values (`self`, `displayVersion`) — it
    // does NOT capture `center`, which is non-Sendable and would otherwise race.
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }  // denied → limb degrades silently
      Task { @MainActor in self.deliver(displayVersion: displayVersion) }
    }
  }

  private func deliver(displayVersion: String) {
    let content = UNMutableNotificationContent()
    content.title = AppConstants.appName
    // No em/en-dashes in user-facing copy (brand rule).
    content.body = "Version \(displayVersion) is ready. Click to install."
    content.sound = nil
    content.categoryIdentifier = Self.categoryIdentifier

    let request = UNNotificationRequest(
      identifier: "\(Self.categoryIdentifier).\(displayVersion)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  private func installDelegateIfNeeded(_ center: UNUserNotificationCenter) {
    guard !delegateInstalled else { return }
    delegateInstalled = true
    let installAction = UNNotificationAction(
      identifier: Self.installActionIdentifier,
      title: "Install",
      options: [.foreground]
    )
    let category = UNNotificationCategory(
      identifier: Self.categoryIdentifier,
      actions: [installAction],
      intentIdentifiers: [],
      options: []
    )
    center.setNotificationCategories([category])
    center.delegate = self
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension UpdateNotificationPresenter: UNUserNotificationCenterDelegate {
  /// Surface the banner even when the app is foregrounded.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner])
  }

  /// Tap (body or Install action) → route through the install handler, which
  /// `UpdateCoordinator` guards on active dictation.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor in self.onInstallTapped?() }
    completionHandler()
  }
}
