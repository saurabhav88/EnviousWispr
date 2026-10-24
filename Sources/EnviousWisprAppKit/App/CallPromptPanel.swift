import AppKit
import EnviousWisprCore
import SwiftUI

/// What the call panel under the menu bar shows (#4012 D2, D3, D6, D10).
enum CallPromptContent: Equatable {
  case ask(appName: String)
  case switchMeeting(appName: String)
  case countdown(secondsLeft: Int)
  case stopped
  /// A switch stopped the old recording, but the new call could not be confirmed.
  case switchNotConfirmed
  case needsAttention
  /// The Start after Yes was refused (low disk, microphone off) or taken over.
  case couldNotStart
  case firstTip
  case lastTip(appName: String)
}

/// The panel's answers, back to `CallDetectionCoordinator`.
struct CallPromptActions {
  var yes: @MainActor () -> Void = {}
  var no: @MainActor () -> Void = {}
  var keepRecording: @MainActor () -> Void = {}
  var startNewRecording: @MainActor () -> Void = {}
  var openSettings: @MainActor () -> Void = {}
  var dismiss: @MainActor () -> Void = {}
}

extension CallPromptActions {
  /// A button's action by its dev-control name, when `content` shows that button.
  func action(named name: String, for content: CallPromptContent) -> (@MainActor () -> Void)? {
    switch (name, content) {
    case ("yes", .ask), ("yes", .switchMeeting): yes
    case ("no", .ask), ("no", .switchMeeting): no
    case ("keepRecording", .countdown): keepRecording
    case ("startNewRecording", .stopped), ("startNewRecording", .switchNotConfirmed):
      startNewRecording
    case ("openSettings", .needsAttention), ("openSettings", .couldNotStart),
      ("openSettings", .firstTip), ("openSettings", .lastTip):
      openSettings
    case ("close", .stopped), ("close", .switchNotConfirmed), ("close", .needsAttention), ("close", .couldNotStart),
      ("close", .firstTip), ("close", .lastTip):
      dismiss
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
}

/// A small non-activating panel under the menu bar icon (#4012 D2): it never takes focus from
/// the call, and it asks macOS to leave it out of screen sharing (`sharingType = .none`). macOS
/// does not guarantee that on every version, so nothing promises it is hidden. The window comes
/// from the same panel factory as the pill (`DesktopOverlayEffects.makePanel`, #2455 C4), so
/// this module never builds one and tests never show one.
@MainActor
final class CallPromptPanel: CallPromptPresenting {
  private let model = CallPromptModel()
  private var panel: (any OverlayPanelDriving)?
  private let anchor: @MainActor () -> NSRect?
  private let makePanel: @MainActor () -> any OverlayPanelDriving

  /// `anchor` gives the menu bar icon's frame on screen, when there is one.
  init(
    anchor: @escaping @MainActor () -> NSRect?,
    makePanel: @escaping @MainActor () -> any OverlayPanelDriving
  ) {
    self.anchor = anchor
    self.makePanel = makePanel
  }

  var isShowing: Bool { panel?.isVisible == true }

  var content: CallPromptContent? { model.content }
  var actions: CallPromptActions { model.actions }

  func show(_ content: CallPromptContent, actions: CallPromptActions) {
    model.content = content
    model.actions = actions
    let panel = self.panel ?? configuredPanel()
    self.panel = panel
    let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 120)
    panel.setFrame(CGRect(origin: origin(for: size), size: size), display: true)
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
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    // Best effort only (Apple: not a guarantee on macOS 15.4 and later).
    panel.sharingType = .none
    panel.setAccessibilityIdentifier("meetings.callPrompt")
    let host = NSHostingView(rootView: CallPromptView(model: model))
    host.sizingOptions = [.preferredContentSize]
    panel.contentView = host
    return panel
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

struct CallPromptView: View {
  let model: CallPromptModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let content = model.content {
        Text(title(content))
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.obTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
        if let detail = detail(content) {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(Color.obTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        buttons(content)
      }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.obBorder, lineWidth: 1))
    .accessibilityElement(children: .contain)
  }

  private func title(_ content: CallPromptContent) -> LocalizedStringResource {
    switch content {
    case .ask:
      LocalizedStringResource(
        "Record this call?", comment: "EnviousMeet: the question asked when a call starts.")
    case .switchMeeting(let app):
      LocalizedStringResource(
        "New call in \(app). Start a new recording?",
        comment: "EnviousMeet: a new call started while a meeting records; the app's name.")
    case .countdown(let seconds):
      LocalizedStringResource(
        "Meeting ending in \(seconds) seconds",
        comment: "EnviousMeet: the call ended; the recording stops after this many seconds.")
    case .stopped, .switchNotConfirmed:
      LocalizedStringResource(
        "Recording stopped", comment: "EnviousMeet: the detected meeting stopped.")
    case .needsAttention:
      LocalizedStringResource(
        "EnviousMeet needs your attention before it can record",
        comment:
          "EnviousMeet: a call started, but a permission or the call sound explainer is needed first."
      )
    case .couldNotStart:
      LocalizedStringResource(
        "EnviousMeet could not start recording",
        comment: "EnviousMeet: Yes to Record this call?, but the recording could not start.")
    case .firstTip:
      LocalizedStringResource(
        "Tip: you can turn off call prompts for some apps in EnviousMeet settings.",
        comment: "EnviousMeet: shown once after the first No to Record this call?")
    case .lastTip(let app):
      LocalizedStringResource(
        "You said No to \(app) a few times. Last reminder: you can turn off \(app) in EnviousMeet settings.",
        comment: "EnviousMeet: shown once after the third No for one app; the app's name twice.")
    }
  }

  private func detail(_ content: CallPromptContent) -> LocalizedStringResource? {
    switch content {
    case .ask(let app):
      LocalizedStringResource(
        "\(app) started using the microphone.",
        comment: "EnviousMeet: under Record this call?; the call app's name.")
    case .stopped:
      // No promise about the transcript: a close that timed out finishes on the next launch.
      LocalizedStringResource(
        "The call ended.", comment: "EnviousMeet: under Recording stopped.")
    case .switchNotConfirmed:
      LocalizedStringResource(
        "The new call could not be confirmed.",
        comment: "EnviousMeet: under Recording stopped, after a switch to a new call that could not be checked.")
    case .couldNotStart:
      LocalizedStringResource(
        "Open EnviousMeet to see why.",
        comment: "EnviousMeet: under EnviousMeet could not start recording.")
    default: nil
    }
  }

  @ViewBuilder private func buttons(_ content: CallPromptContent) -> some View {
    let actions = model.actions
    HStack(spacing: 8) {
      switch content {
      case .ask, .switchMeeting:
        button(
          LocalizedStringResource("Yes", comment: "EnviousMeet: answer to Record this call?"),
          primary: true
        ) {
          actions.yes()
        }
        button(
          LocalizedStringResource("No", comment: "EnviousMeet: answer to Record this call?"),
          primary: false
        ) {
          actions.no()
        }
      case .countdown:
        button(
          LocalizedStringResource(
            "Keep recording", comment: "EnviousMeet: stops the countdown; the meeting goes on."),
          primary: true
        ) {
          actions.keepRecording()
        }
      case .stopped, .switchNotConfirmed:
        button(
          LocalizedStringResource(
            "Start a new recording", comment: "EnviousMeet: after a detected meeting stopped."),
          primary: true
        ) {
          actions.startNewRecording()
        }
        button(
          LocalizedStringResource("Close", comment: "EnviousMeet: closes the call panel."),
          primary: false
        ) {
          actions.dismiss()
        }
      case .needsAttention, .couldNotStart, .firstTip, .lastTip:
        button(
          LocalizedStringResource(
            "Open settings", comment: "EnviousMeet: opens the EnviousMeet settings page."),
          primary: true
        ) {
          actions.openSettings()
        }
        button(
          LocalizedStringResource("Close", comment: "EnviousMeet: closes the call panel."),
          primary: false
        ) {
          actions.dismiss()
        }
      }
    }
  }

  private func button(_ title: LocalizedStringResource, primary: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: primary ? .semibold : .regular))
        .foregroundStyle(primary ? Color.white : Color.obTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
          primary ? Color.obButtonFill : Color.obSurface, in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
