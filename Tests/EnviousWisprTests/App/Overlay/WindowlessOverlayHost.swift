import AppKit
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

  @discardableResult
  func present(
    _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
    position: OverlayPillPosition
  ) -> Bool {
    presented.append((width: width, fixedHeight: fixedHeight, isFresh: isFresh))
    isShowing = true
    return true
  }

  func resizeCurrentPresentation(to size: CGSize) {
    resizes.append(size)
  }

  func hide() {
    hideCount += 1
    isShowing = false
  }
}
