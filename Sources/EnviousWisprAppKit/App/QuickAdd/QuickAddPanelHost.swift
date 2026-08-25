import AppKit
import SwiftUI

/// The Quick Add panel's window, and nothing else (#2381).
///
/// **Sole owner of the `NSPanel`.** The #2292 overlay work had to extract window lifetime out of a
/// coordinator after the fact; this starts where that ended up. The coordinator below it decides
/// WHAT to show and never touches a window.
///
/// **This panel is key-capable, and that is the one way it must differ from the dictation overlay.**
/// `OverlayWindowHost` builds `[.borderless, .nonactivatingPanel]`, and a non-activating panel can
/// never become key — so it could never receive the Return keypress this whole feature is built
/// around. The shape here follows `RelocationCardPanel` instead, which is the app's existing
/// key-capable card: `.titled` + `.fullSizeContentView` with the title bar hidden, which also buys
/// native rounding and shadow rather than hand-drawn ones.
///
/// Nonmodal on purpose. A modal panel would trap the user in a limb: Quick Add is something you
/// abandon by pressing Escape or clicking away, and a run loop that refuses to let you is worse than
/// the misheard word.
@MainActor
final class QuickAddPanelHost: NSObject, NSWindowDelegate {

  /// Fired when the panel goes away for any reason the host can see — Escape, clicking away, or the
  /// window closing under it. The coordinator treats all three as "the user is done".
  var onDismiss: (() -> Void)?

  private var panel: NSPanel?

  #if DEBUG
    /// How many panels this host has built. A second one means the reuse path broke, which is
    /// invisible on screen: two identical panels stack and the user sees one.
    private(set) var panelConstructionCount = 0
  #endif

  var isVisible: Bool { panel?.isVisible ?? false }

  /// Show `content`, reusing the existing panel if one is already up.
  ///
  /// **Reuse, not a second panel.** Pressing the shortcut again while the panel is open is an
  /// ordinary thing to do — the user is not sure it fired — and opening a second identical panel on
  /// top of the first looks exactly like nothing happening while leaving a window nobody can reach.
  /// - Returns: whether a panel is now on screen. **The caller MUST read it.** A refusal here used
  ///   to be invisible: the coordinator had already emitted `opened`, nothing resolved it, and the
  ///   user got no window — the same shape as the refresh failure that returned no panel, reached
  ///   through the one path that cannot report a reason.
  @discardableResult
  func present(_ content: some View) -> Bool {
    let panel = ensurePanel()
    let host = NSHostingView(rootView: AnyView(content))
    panel.contentView = host

    guard let size = resolvedSize(of: host) else {
      // **A zero fitting size is an INVISIBLE panel that reports success**, which the overlay work
      // found by fixture rather than by review. Refusing to present is the honest outcome: the
      // caller gets no panel and the user gets nothing, rather than a window that is up, focused,
      // swallowing Return, and blank.
      panel.contentView = nil
      return false
    }
    panel.setContentSize(size)
    panel.center()

    // Activate BEFORE making key, and only now — the selection was read while the other app was
    // still frontmost, which is the whole reason this happens here rather than at capture time.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    return true
  }

  /// Bring an already-visible panel back to the front and give it key focus.
  ///
  /// Needed because `windowDidResignKey` is now a no-op, so a panel can be visible and unfocused —
  /// a state that did not exist while focus loss dismissed it. A second shortcut press in that state
  /// should answer "I am not sure that fired" by SHOWING the panel, not by silently doing nothing
  /// and not by throwing away the selection it already holds.
  func raise() {
    guard let panel, panel.isVisible else { return }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Take the panel down. Idempotent.
  ///
  /// `orderOut`, never `close`: closing is what forces a rebuild, and this panel is reused.
  func dismiss() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    panel.contentView = nil
  }

  // MARK: - NSWindowDelegate

  /// **DELIBERATELY EMPTY. Losing key focus is not the user saying they are done.**
  ///
  /// This used to dismiss, and Live UAT measured what that costs: the panel cancelled itself after
  /// 339 ms on one run and 19.7 seconds on the next, both times because an unrelated process took
  /// key — a terminal reclaiming focus, then a screenshot tool. Neither was a user decision. On a
  /// real machine the same list includes a notification, Spotlight, a background app waking, and the
  /// Services system handing focus back to the app the selection came from. The user's selected word
  /// was discarded and the panel evaporated, which from their side is indistinguishable from the
  /// shortcut doing nothing.
  ///
  /// **The two arrival times looked like variance and were not.** Each panel died at the FIRST focus
  /// event after opening; only when that arrived differed. So there is nothing to tune here — no
  /// grace period, no debounce. The signal was wrong, not slow, and a timing-shaped fix would have
  /// been tuned to whichever arm got measured.
  ///
  /// The founder's complaint arrived from the opposite direction — "there's no way to close out the
  /// window" — and it is the SAME mistake: key state was chosen as the done-signal because it was
  /// available, so it fires when the user is not done and it is the only exit when it does not fire.
  /// Leaving is now something the user does on purpose: Escape (`cancelOperation`, below) or the
  /// close control.
  ///
  /// Kept as an explicit no-op rather than deleted, because an absent delegate method is
  /// indistinguishable from one nobody thought about.
  func windowDidResignKey(_ notification: Notification) {}

  /// The close control, and anything else that genuinely closes the window.
  ///
  /// Reachable for the first time now that the close button is visible. `isReleasedWhenClosed` is
  /// false, so the panel survives to be reused; clearing the hosting view is what stops the old
  /// content being handed back on the next present.
  func windowWillClose(_ notification: Notification) {
    panel?.contentView = nil
    onDismiss?()
  }

  // MARK: - Ownership

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    #if DEBUG
      panelConstructionCount += 1
    #endif
    let p = KeyCapablePanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    p.titleVisibility = .hidden
    p.titlebarAppearsTransparent = true
    // **STILL HIDDEN, and unhiding it is a change that LOOKS like a fix and is not.** Measured:
    // setting `isHidden = false` produced no visible control, because `.fullSizeContentView` puts
    // the hosting view over the titlebar area and the standard buttons sit behind it. A screenshot
    // of the running panel shows no close control at all.
    //
    // So the answer to the founder's "there's no way to close out the window" cannot come from the
    // window at all — it has to be drawn IN the content, which is what the chosen design does with
    // its own chrome. Left hidden deliberately rather than left `false` as a line that reads as a
    // fix and does nothing.
    p.standardWindowButton(.closeButton)?.isHidden = true
    p.standardWindowButton(.miniaturizeButton)?.isHidden = true
    p.standardWindowButton(.zoomButton)?.isHidden = true
    p.isMovableByWindowBackground = true
    // Survives being ordered out, which is what makes reuse possible at all.
    p.isReleasedWhenClosed = false
    p.level = .floating
    p.hidesOnDeactivate = false
    p.delegate = self
    p.onCancelOperation = { [weak self] in
      guard let self, self.isVisible else { return }
      self.dismiss()
      self.onDismiss?()
    }
    panel = p
    return p
  }

  /// The presented size, or nil when the content could not be measured.
  ///
  /// nil means DO NOT PRESENT. Never a plausible default: a literal fallback here is how an
  /// unmeasurable panel becomes a confidently wrong-sized one, and the caller cannot tell the two
  /// apart afterwards.
  private func resolvedSize(of view: NSView) -> CGSize? {
    let fitting = view.fittingSize
    if fitting.width > 0, fitting.height > 0 { return fitting }
    let frame = view.frame.size
    if frame.width > 0, frame.height > 0 { return frame }
    return nil
  }
}

/// A borderless-looking panel that can take keyboard focus.
///
/// `canBecomeKey` is `false` by default for a panel without a real title bar, and without it Return
/// never arrives — the panel would render perfectly and ignore the only key the feature needs.
private final class KeyCapablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  /// Not main: this is an accessory over whatever the user was working in, and taking main status
  /// would reorder their windows behind it.
  override var canBecomeMain: Bool { false }

  /// What Escape should do, handled HERE rather than in the view.
  ///
  /// The view had `.onExitCommand`, and the search field takes focus the moment the panel opens. An
  /// `NSTextField`'s field editor claims `cancelOperation(_:)` first and treats Escape as "cancel
  /// field editing", so the SwiftUI modifier only ever saw what the responder chain handed back —
  /// which is why the panel's one documented keyboard exit did not work.
  ///
  /// A window-level override cannot be intercepted by a field editor, and it keeps working whatever
  /// gains focus later. That last part is the reason to prefer it even after the field is fixed: a
  /// future control that also swallows Escape would silently break the view-level version again.
  var onCancelOperation: (() -> Void)?
  override func cancelOperation(_ sender: Any?) { onCancelOperation?() }
}
