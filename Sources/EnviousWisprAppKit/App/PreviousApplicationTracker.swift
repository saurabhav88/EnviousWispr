import AppKit
import Observation

/// The last application other than this one that came to the front (#4101). History Paste reads
/// it at the press, when this app is in front, as the app the user came from and means to paste
/// into. It only records: it never activates, polls or chooses a replacement when the recorded
/// app quits; History Paste refuses then.
///
/// Its own observer, not `AccessibilityWarmupObserver`'s: that one wakes accessibility in the app
/// that came forward, cools down per app and is switched off for one UAT harness, none of which
/// may decide where a paste goes.
@MainActor
@Observable
final class PreviousApplicationTracker {
  struct Effects {
    var notificationCenter: NotificationCenter
    var frontmost: @MainActor () -> NSRunningApplication?
    var ownProcessIdentifier: pid_t
    var isTerminated: @MainActor (NSRunningApplication) -> Bool

    static var live: Effects {
      Effects(
        notificationCenter: NSWorkspace.shared.notificationCenter,
        frontmost: { NSWorkspace.shared.frontmostApplication },
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        isTerminated: { $0.isTerminated })
    }
  }

  /// The latest other live application seen coming to the front; nil until one has.
  private(set) var lastOtherApplication: NSRunningApplication?

  /// Activations handled since start, ours included. Tests read it to see one subscription.
  @ObservationIgnored private(set) var activationsHandled = 0

  @ObservationIgnored private let effects: Effects
  @ObservationIgnored private var token: NSObjectProtocol?

  init(effects: Effects = .live) {
    self.effects = effects
  }

  var isObserving: Bool { token != nil }

  /// Begin observing. Idempotent.
  func start() {
    guard token == nil else { return }
    token = effects.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      // Read the payload before `assumeIsolated`: reading `note` inside it trips "sending 'note'
      // risks causing data races" under Swift 6.
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        guard let self, let app else { return }
        self.activationsHandled += 1
        self.record(app)
      }
    }
    // The app already in front when observing starts sends no new activation.
    if let front = effects.frontmost() { record(front) }
  }

  /// Stop observing. Idempotent. The record is kept.
  func stop() {
    if let token { effects.notificationCenter.removeObserver(token) }
    token = nil
  }

  private func record(_ app: NSRunningApplication) {
    guard app.processIdentifier != effects.ownProcessIdentifier, !effects.isTerminated(app) else {
      return
    }
    lastOtherApplication = app
  }
}
