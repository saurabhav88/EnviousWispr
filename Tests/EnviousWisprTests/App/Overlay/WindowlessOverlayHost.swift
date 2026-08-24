import AppKit
import SwiftUI
import CoreGraphics
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// An `OverlayWindowHosting` that SUCCEEDS and builds no window (#2292, C7).
///
/// **The point is that it succeeds.** The double it replaces got its silence by
/// resolving no screen, so `OverlayWindowHost.present` refused — a production
/// FAILURE path borrowed as a stub. That only ever reported anything because a
/// refused presentation left its state behind, and C7 removed exactly that. A
/// test asserting what the overlay shows needs a host that shows it.
///
/// It exists only in the test target, so no runtime flag or test-shaped branch
/// enters `OverlayWindowHost` and nothing here can ship.
///
/// **It deliberately cannot answer a geometry question.** It records the request
/// and no frame, because a fake that returned a plausible width is how a
/// geometry regression goes unnoticed — the real host owns placement, ordering
/// and the panel count, and its own suite keeps them.
@MainActor
final class WindowlessOverlayHost: OverlayWindowHosting {

  /// Every presentation this host was asked for, in order.
  private(set) var presented: [(width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool)] = []
  private(set) var resizes: [CGSize] = []
  private(set) var hideCount = 0
  /// Whether a presentation is currently up, which is the one piece of window
  /// state a caller can legitimately ask a windowless host about.
  private(set) var isShowing = false

  /// The root view the director handed over, captured so a test can enter
  /// through the SAME closure a click does (#2292 C5c).
  private var hostedRoot: OverlayRootView?

  @discardableResult
  func present(
    _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
    position: OverlayPillPosition
  ) -> Bool {
    hostedRoot = (view as? NSHostingView<OverlayRootView>)?.rootView
    presented.append((width: width, fixedHeight: fixedHeight, isFresh: isFresh))
    isShowing = true
    return true
  }

  /// Deliver a user action through the root view's own event closure.
  ///
  /// **This is how a test presses a button since C5c**, and the name says what it
  /// actually does: it enters through the ROOT, it does not click a SwiftUI
  /// control. The director's generic event ingress is private now, and a
  /// `package` press seam was rejected for a specific reason — a broken root
  /// closure would leave every visible button dead while every test using such a
  /// seam stayed green. Grant, Discard, Undo, the language chip and the Bluetooth
  /// card all travel this closure when a user clicks, so they travel it here too.
  func sendUserActionThroughRoot(
    _ action: PillAction, for receipt: PillReceipt
  ) throws {
    let root = try #require(hostedRoot, "nothing was presented, so no root exists to press")
    root.sendEvent(.action(receipt.presentationID, action))
  }

  /// Deliver an action to the presentation currently published by the hosted root.
  ///
  /// Use only when the production subject presents internally and returns no receipt.
  /// Unlike a real leaf callback, this reads `model.presentation` at invocation time;
  /// it therefore cannot prove stale, replacement, or queued-click behavior. Those
  /// cases must use `sendUserActionThroughRoot(_:for:)`.
  func sendCurrentUserActionThroughRoot(_ action: PillAction) throws {
    let root = try #require(hostedRoot, "nothing was presented, so no root exists")
    let id = try #require(root.model.presentation?.id, "no pill is currently presented")
    root.sendEvent(.action(id, action))
  }

  func resizeCurrentPresentation(to size: CGSize) {
    resizes.append(size)
  }

  func hide() {
    hideCount += 1
    isShowing = false
  }
}
