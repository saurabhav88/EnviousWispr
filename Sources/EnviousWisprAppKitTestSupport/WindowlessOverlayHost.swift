// #2455 C4 (#2461): moved out of `EnviousWisprTests` into a shared support target.
//
// Sixteen suites use this fake. `OverlayHostingParityTests` stays in
// `EnviousWisprTests` and compares this against the real host; the suites in
// `EnviousWisprDesktopEffectsTests` need it too. Duplicating it would defeat the
// parity check it exists to serve: two copies of a fake drift apart and nothing
// fails.
//
// A NON-SHIPPING library target, not a test target: a SwiftPM `.testTarget`
// cannot be depended on by another test target.

import AppKit
import SwiftUI
import CoreGraphics
import EnviousWisprAppKit
import EnviousWisprCore

@testable import EnviousWisprAppKit

/// An `OverlayWindowHosting` that SUCCEEDS and builds no window (#2292, C7).
///
/// **The point is that it succeeds.** The double it replaces got its silence by
/// resolving no screen, so `OverlayWindowHost.present` refused — a production
/// FAILURE path borrowed as a stub. That only ever reported anything because a
/// refused presentation left its state behind, and C7 removed exactly that. A
/// test asserting what the overlay shows needs a host that shows it.
///
/// It exists only in the non-shipping `EnviousWisprAppKitTestSupport` target,
/// which the test targets link and the app does not, so no runtime flag or
/// test-shaped branch
/// enters `OverlayWindowHost` and nothing here can ship.
///
/// **It deliberately cannot answer a geometry question.** It records the request
/// and no frame, because a fake that returned a plausible width is how a
/// geometry regression goes unnoticed — the real host owns placement, ordering
/// and the panel count, and its own suite keeps them.
@MainActor
package final class WindowlessOverlayHost: OverlayWindowHosting {

  package init() {}

  /// Every presentation this host was asked for, in order.
  package private(set) var presented: [(width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool)] = []
  package private(set) var resizes: [CGSize] = []
  package private(set) var hideCount = 0
  /// Whether a presentation is currently up, which is the one piece of window
  /// state a caller can legitimately ask a windowless host about.
  package private(set) var isShowing = false

  /// The root view the director handed over, captured so a test can enter
  /// through the SAME closure a click does (#2292 C5c).
  private var hostedRoot: OverlayRootView?

  @discardableResult
  package func present(
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
  package func sendUserActionThroughRoot(
    _ action: PillAction, for receipt: PillReceipt
  ) throws {
    // #2455 C4: `#require` -> a thrown error. A non-test target cannot import
    // `Testing`, and this fake now lives in one so BOTH test targets can share it.
    // The failure still surfaces as a test failure — Swift Testing reports a
    // thrown error from a `throws` test — and the message is preserved.
    guard let root = hostedRoot else {
      throw WindowlessOverlayHostError("nothing was presented, so no root exists to press")
    }
    root.sendEvent(.action(receipt.presentationID, action))
  }

  /// Deliver an action to the presentation currently published by the hosted root.
  ///
  /// Use only when the production subject presents internally and returns no receipt.
  /// Unlike a real leaf callback, this reads `model.presentation` at invocation time;
  /// it therefore cannot prove stale, replacement, or queued-click behavior. Those
  /// cases must use `sendUserActionThroughRoot(_:for:)`.
  package func sendCurrentUserActionThroughRoot(_ action: PillAction) throws {
    guard let root = hostedRoot else {
      throw WindowlessOverlayHostError("nothing was presented, so no root exists")
    }
    guard let id = root.model.state.presentation?.id else {
      throw WindowlessOverlayHostError("no pill is currently presented")
    }
    root.sendEvent(.action(id, action))
  }

  package func resizeCurrentPresentation(to size: CGSize) {
    resizes.append(size)
  }

  package func hide() {
    hideCount += 1
    isShowing = false
  }
}

/// What this fake throws when a test asks it for something that is not there.
///
/// Replaces `#require`, which needs `Testing` — unavailable to the non-test target
/// this fake moved into so both test targets could share it. Swift Testing reports
/// a thrown error from a `throws` test, so the failure is equally visible and the
/// message is unchanged.
package struct WindowlessOverlayHostError: Error, CustomStringConvertible {
  package let description: String
  package init(_ description: String) { self.description = description }
}
