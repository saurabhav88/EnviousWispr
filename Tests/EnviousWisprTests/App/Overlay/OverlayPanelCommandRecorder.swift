import AppKit
import CoreGraphics

@testable import EnviousWisprAppKit

/// One AppKit command `OverlayWindowHost` issued against a panel (#2377, P6-C2).
///
/// **These observe the actual overridden AppKit calls, not the host's INTENT.**
/// A receipt shaped `.presented(width:height:isFresh:position:)` would restate
/// what the host meant to do and could stay green after the real command
/// disappeared from `present()` — exactly the risk the deleted `*ForTesting`
/// accessors carried, one layer down. `setFrame`/`setContentView`/
/// `orderFrontRegardless`/`orderOut`/`close` are the actual AppKit surface the
/// host drives; recording those, and nothing higher-level, is what makes a
/// missing call visible instead of a missing INTENTION.
enum OverlayPanelCommand: Equatable {
  case constructed(panel: ObjectIdentifier)
  case setFrame(panel: ObjectIdentifier, frame: CGRect, display: Bool, animated: Bool)
  case setContentView(panel: ObjectIdentifier, view: ObjectIdentifier?)
  case orderFrontRegardless(panel: ObjectIdentifier)
  case orderOut(panel: ObjectIdentifier)
  case close(panel: ObjectIdentifier)
}

/// Owns every panel `OverlayPanelFactory` has produced and the commands each
/// one received.
///
/// **One recorder per test, one factory closure per recorder.** `panel`
/// answers `panelForTesting`'s old question (the current occupant) without
/// reading private host state; `constructionCount` answers
/// `panelConstructionCount`'s old question by counting `.constructed` receipts
/// instead of keeping a second, independently-incrementable counter — one
/// authority for "how many panels exist" instead of two that could drift.
@MainActor
final class OverlayPanelCommandRecorder {
  fileprivate(set) var commands: [OverlayPanelCommand] = []
  fileprivate(set) var panels: [NSPanel] = []

  var panel: NSPanel? { panels.last }

  var constructionCount: Int {
    commands.reduce(into: 0) { count, command in
      if case .constructed = command { count += 1 }
    }
  }

  func makeFactory() -> OverlayPanelFactory {
    OverlayPanelFactory { [weak self] in
      let p = CommandRecordingPanel(recorder: self)
      self?.panels.append(p)
      self?.commands.append(.constructed(panel: ObjectIdentifier(p)))
      return p
    }
  }
}

/// A real `NSPanel` that reports every command this suite cares about to its
/// recorder — the panel behaves exactly as the production one does; only the
/// reporting is added.
///
/// **`close()` records BEFORE calling `super`; every successful command records
/// AFTER.** Closing is a negative tripwire on the attempted call itself, so its
/// receipt must not depend on the superclass operation completing. Production
/// never calls `close()`.
///
/// **`setFrame` is normalized to one receipt per Host call.** `NSWindow`
/// exposes animated and non-animated overloads. `animatedSetFrameDepth`
/// normalizes either AppKit implementation: independent overloads or an
/// animated overload that internally routes through the non-animated one.
private final class CommandRecordingPanel: NSPanel {
  private weak var recorder: OverlayPanelCommandRecorder?
  private var animatedSetFrameDepth = 0

  init(recorder: OverlayPanelCommandRecorder?) {
    self.recorder = recorder
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 185, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
    super.setFrame(frameRect, display: displayFlag)
    guard animatedSetFrameDepth == 0 else { return }
    recorder?.commands.append(
      .setFrame(
        panel: ObjectIdentifier(self), frame: frameRect, display: displayFlag, animated: false))
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool)
  {
    animatedSetFrameDepth += 1
    defer { animatedSetFrameDepth -= 1 }
    super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
    recorder?.commands.append(
      .setFrame(
        panel: ObjectIdentifier(self), frame: frameRect, display: displayFlag,
        animated: animateFlag))
  }

  override var contentView: NSView? {
    get { super.contentView }
    set {
      super.contentView = newValue
      recorder?.commands.append(
        .setContentView(
          panel: ObjectIdentifier(self),
          view: newValue.map(ObjectIdentifier.init)))
    }
  }

  override func orderFrontRegardless() {
    super.orderFrontRegardless()
    recorder?.commands.append(.orderFrontRegardless(panel: ObjectIdentifier(self)))
  }

  override func orderOut(_ sender: Any?) {
    super.orderOut(sender)
    recorder?.commands.append(.orderOut(panel: ObjectIdentifier(self)))
  }

  override func close() {
    recorder?.commands.append(.close(panel: ObjectIdentifier(self)))
    super.close()
  }
}
