import AppKit
import EnviousWisprCore
import SwiftUI

/// What the call panel under the menu bar shows (#4012 D2, D3, D6, D10; #4232 redesign).
enum CallPromptContent: Equatable {
  case ask(CallAppIdentity)
  case switchMeeting(CallAppIdentity)
  /// The call ended; the recording stops when the seconds run out. Nil identity: the call is no
  /// longer tracked by then.
  case countdown(CallAppIdentity?, secondsLeft: Int)
  case endConfirmation(CallAppIdentity)
  /// A switch stopped the old recording, but the new call could not be confirmed.
  case switchNotConfirmed(CallAppIdentity)
  /// #4232: the call flow stopped a recording; its notes are being written.
  case notesWriting
  /// #4232: that recording's transcript is saved and in History.
  case notesReady(meetingID: UUID)
  /// #4232: a recording the user started from the menu bar, shown for two seconds.
  case manualStart(CallAppIdentity)
  case needsAttention
  /// The Start after Yes was refused (low disk, microphone off) or taken over.
  case couldNotStart
  case firstTip
  case lastTip(appName: String)

  /// A countdown's ticks update copy, not the lifetime of its presentation.
  var presentationIdentity: Self {
    if case .countdown(let identity, _) = self { return .countdown(identity, secondsLeft: 0) }
    return self
  }

  /// The two-second menu-bar card has no buttons and no close button.
  var closes: Bool {
    if case .manualStart = self { return false }
    return true
  }
}

/// The panel's answers, back to `CallDetectionCoordinator` (or the Diagnostics preview).
struct CallPromptActions {
  var yes: @MainActor () -> Void = {}
  var no: @MainActor () -> Void = {}
  var stopRecording: @MainActor () -> Void = {}
  var keepRecording: @MainActor () -> Void = {}
  var endRecording: @MainActor () -> Void = {}
  var startNewRecording: @MainActor () -> Void = {}
  var openSettings: @MainActor () -> Void = {}
  var open: @MainActor () -> Void = {}
  /// The × on every card that has one.
  var dismiss: @MainActor () -> Void = {}
}

extension CallPromptActions {
  /// A button's action by its dev-control name, when `content` shows that button.
  func action(named name: String, for content: CallPromptContent) -> (@MainActor () -> Void)? {
    switch (name, content) {
    case ("yes", .ask), ("yes", .switchMeeting): yes
    case ("no", .ask), ("no", .switchMeeting), ("no", .switchNotConfirmed): no
    case ("keepRecording", .endConfirmation): keepRecording
    case ("stopRecording", .endConfirmation): stopRecording
    case ("endRecording", .countdown): endRecording
    case ("startNewRecording", .switchNotConfirmed): startNewRecording
    case ("openSettings", .needsAttention), ("openSettings", .couldNotStart),
      ("openSettings", .firstTip), ("openSettings", .lastTip):
      openSettings
    case ("open", .notesReady): open
    case ("close", let content) where content.closes: dismiss
    default: nil
    }
  }
}

/// What shows the call panel: the real panel, or a test's stand-in.
@MainActor
protocol CallPromptPresenting: AnyObject {
  var isShowing: Bool { get }
  var content: CallPromptContent? { get }
  var actions: CallPromptActions { get }
  func show(_ content: CallPromptContent, actions: CallPromptActions)
  func hide()
}

@MainActor
@Observable
final class CallPromptModel {
  var content: CallPromptContent?
  var actions = CallPromptActions()
  var presentationID = 0
}

/// A small non-activating panel under the menu bar icon (#4012 D2): it never takes focus from
/// the call, and it asks macOS to leave it out of screen sharing (`sharingType = .none`). macOS
/// does not guarantee that on every version, so nothing promises it is hidden. The window comes
/// from the same panel factory as the pill (`DesktopOverlayEffects.makePanel`, #2455 C4).
/// This module owns placement; the native effects tests exercise the real factory.
@MainActor
final class CallPromptPanel: CallPromptPresenting {
  private let model = CallPromptModel()
  private var panel: (any OverlayPanelDriving)?
  private var hosting: NSHostingView<CallPromptView>?
  private let anchor: @MainActor () -> NSRect?
  private let makePanel: @MainActor () -> any OverlayPanelDriving
  private let capturable: Bool

  /// `anchor` gives the menu bar icon's frame on screen, when there is one. `capturable` is for
  /// the Diagnostics preview only (#4232): it lets screenshots include the card. Real call
  /// pop-ups keep asking to stay out of screen sharing.
  init(
    anchor: @escaping @MainActor () -> NSRect?,
    makePanel: @escaping @MainActor () -> any OverlayPanelDriving,
    capturable: Bool = false
  ) {
    self.anchor = anchor
    self.makePanel = makePanel
    self.capturable = capturable
  }

  var isShowing: Bool { panel?.isVisible == true }

  var content: CallPromptContent? { model.content }
  var actions: CallPromptActions { model.actions }

  func show(_ content: CallPromptContent, actions: CallPromptActions) {
    if !isShowing || model.content?.presentationIdentity != content.presentationIdentity {
      model.presentationID += 1
    }
    model.content = content
    model.actions = actions
    let panel = self.panel ?? configuredPanel()
    self.panel = panel
    // Observation invalidation is not synchronous layout. Measure the updated card, and keep
    // the window's frame owned here rather than by NSHostingView.windowDidLayout (#3850).
    hosting?.layoutSubtreeIfNeeded()
    let measured = hosting?.fittingSize ?? .zero
    let size = Self.usable(measured) ? measured : NSSize(width: 380, height: 260)
    panel.setFrame(CGRect(origin: origin(for: size), size: size), display: true)
    hosting?.frame = panel.contentView?.bounds ?? CGRect(origin: .zero, size: size)
    panel.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut()
    model.content = nil
  }

  private func configuredPanel() -> any OverlayPanelDriving {
    let panel = makePanel()
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The card draws its own shadow. A window shadow would trace the card's soft glow inside
    // the transparent margin and draw a rough black frame around it (#4232).
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    // Best effort only (Apple: not a guarantee on macOS 15.4 and later).
    panel.sharingType = capturable ? .readOnly : .none
    panel.setAccessibilityIdentifier("meetings.callPrompt")
    let host = NSHostingView(rootView: CallPromptView(model: model))
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 260))
    host.frame = container.bounds
    host.autoresizingMask = [.width, .height]
    container.addSubview(host)
    panel.contentView = container
    hosting = host
    return panel
  }

  private static func usable(_ size: NSSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }

  private func origin(for size: NSSize) -> NSPoint {
    let icon = anchor()
    return Self.origin(
      for: size, anchor: icon,
      screens: NSScreen.screens.map(\.visibleFrame), mainScreen: NSScreen.main?.visibleFrame)
  }

  /// Under the menu bar icon, on the screen that holds it, kept inside that screen on both axes
  /// (review r2 F6: displays side by side or diagonal). Without an icon: the main screen's top
  /// right.
  static func origin(for size: NSSize, anchor: NSRect?, screens: [NSRect], mainScreen: NSRect?)
    -> NSPoint
  {
    let screen =
      anchor.flatMap { icon in
        screens.first { $0.insetBy(dx: 0, dy: -40).contains(NSPoint(x: icon.midX, y: icon.midY)) }
      } ?? mainScreen ?? screens.first ?? .zero
    var origin: NSPoint
    if let icon = anchor {
      origin = NSPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height - 6)
    } else {
      origin = NSPoint(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 6)
    }
    origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
    origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
    return origin
  }
}
