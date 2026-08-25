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
  func present(_ content: some View) {
    let panel = ensurePanel()
    let host = NSHostingView(rootView: AnyView(content))
    panel.contentView = host

    guard let size = resolvedSize(of: host) else {
      // **A zero fitting size is an INVISIBLE panel that reports success**, which the overlay work
      // found by fixture rather than by review. Refusing to present is the honest outcome: the
      // caller gets no panel and the user gets nothing, rather than a window that is up, focused,
      // swallowing Return, and blank.
      panel.contentView = nil
      return
    }
    panel.setContentSize(size)
    panel.center()

    // Activate BEFORE making key, and only now — the selection was read while the other app was
    // still frontmost, which is the whole reason this happens here rather than at capture time.
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

  func windowDidResignKey(_ notification: Notification) {
    // **A SHEET TAKING KEY IS NOT THE USER CLICKING AWAY, and treating it as one made "Create a new
    // word" tear down its own editor.** A SwiftUI `.sheet` on this panel is a real attached window;
    // presenting it makes the sheet key and sends this to the parent, which is still visible — so
    // the visibility guard below passes and the panel orders itself out, taking the hosting view and
    // the sheet with it. The route the feature offers for a word you do not have yet ended in an
    // empty screen.
    guard panel?.attachedSheet == nil else { return }
    // Clicking away is a dismissal. The panel holds no unsaved state the user could lose — the word
    // is written on Return and not before — so there is nothing to confirm.
    guard panel?.isVisible == true else { return }
    dismiss()
    onDismiss?()
  }

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
    p.standardWindowButton(.closeButton)?.isHidden = true
    p.standardWindowButton(.miniaturizeButton)?.isHidden = true
    p.standardWindowButton(.zoomButton)?.isHidden = true
    p.isMovableByWindowBackground = true
    // Survives being ordered out, which is what makes reuse possible at all.
    p.isReleasedWhenClosed = false
    p.level = .floating
    p.hidesOnDeactivate = false
    p.delegate = self
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
}
