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

  /// Asked before Escape takes the panel down. Returning true means the CONTENT consumed the
  /// keypress and the window must not dismiss.
  ///
  /// **The window is where Escape arrives and the window is the one place that cannot decide what
  /// it means.** `cancelOperation` is overridden on the panel because a focused text field's field
  /// editor claims Escape first, so a view-level handler never sees it — and the panel now has two
  /// stages where Escape means two different things. Asking the content, rather than teaching the
  /// window about stages, keeps every keyboard rule in the model that already owns the rest of them.
  ///
  /// Defaults to "not consumed", which is the shipped behaviour: an unset seam dismisses, so a
  /// caller that forgets to wire this loses a feature rather than trapping the user in a panel.
  var shouldConsumeCancel: () -> Bool = { false }

  private var panel: NSPanel?

  /// What held the keyboard before the panel took it, and the window if it was ours.
  ///
  /// Written by the two observers below and by nothing else, so there is no route to miss. Weak,
  /// because a Settings window the user closed during the beat must not be resurrected or retained.
  private var focusOrigin: FocusOriginKind = .unknown
  private weak var originWindow: NSWindow?
  private var focusObservers: [NSObjectProtocol] = []


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
    // **An `NSHostingController` rather than a bare `NSHostingView`, and the reason is that the
    // content can now change SHAPE while it is on screen.** The panel used to render one thing —
    // a search field over a ranked list — and its size was decided once, here, at present time.
    // It now has stages (pick, compose), and a stage change makes the ideal height jump; a window
    // sized once shows the new stage floating in the old stage's space.
    //
    // `sizingOptions = .preferredContentSize` is the mechanism AppKit provides for exactly this:
    // the controller republishes its ideal size whenever the SwiftUI content's changes, and the
    // window follows. Doing it by hand would mean the caller re-measuring after every mutation, on
    // a later run loop pass, which is a race with SwiftUI's own layout.
    let controller = NSHostingController(rootView: AnyView(content))
    controller.sizingOptions = [.preferredContentSize]
    // Force the view to load and lay out BEFORE measuring. `fittingSize` on an unloaded view is
    // zero, which this method's own guard would then read as an unmeasurable panel.
    controller.view.layoutSubtreeIfNeeded()

    guard let size = resolvedSize(of: controller.view) else {
      // **A zero fitting size is an INVISIBLE panel that reports success**, which the overlay work
      // found by fixture rather than by review. Refusing to present is the honest outcome: the
      // caller gets no panel and the user gets nothing, rather than a window that is up, focused,
      // swallowing Return, and blank.
      //
      // Refused BEFORE the controller is installed, so nothing is ever half-swapped — and then the
      // panel is TAKEN DOWN, because "leave it exactly as it was" is the wrong answer once the panel
      // can be reused across invocations.
      //
      // **What it would have been left showing is a CONFIRMATION from an invocation that already
      // resolved.** A fresh capture arriving inside the fade cancels that fade deliberately
      // (`QuickAddWiring.mayBeginCapture`), so nothing else is coming to clear it: the old
      // `"clawwed" added to Claude` would sit on screen indefinitely while the caller emits
      // `failedToOpen`, describing an invocation the user has moved past. A stale sentence is worse
      // than no window, which is the same reason this method refuses an unmeasurable panel at all.
      dismiss()
      return false
    }
    panel.contentViewController = controller
    panel.setContentSize(size)
    panel.center()

    // Activate BEFORE making key, and only now — the selection was read while the other app was
    // still frontmost, which is the whole reason this happens here rather than at capture time.
    takeFocus(panel)
    return true
  }

  /// Take activation and key status, recording what was taken so `releaseFocus` can give back
  /// exactly that.
  ///
  /// **One owner, because there are TWO takers and the second was missed by three review rounds.**
  /// `present` and `raise` both activate and both call `makeKeyAndOrderFront`; only the first
  /// recorded it, so after a raise both records described the PREVIOUS presentation. Reachable:
  /// open from another app, click into our Settings window, press the shortcut again — the raise
  /// takes key status from Settings while the records still say the app was activated from outside,
  /// and the release then deactivates, hiding the user's own window.
  ///
  /// A third taker cannot be added without coming through here, which is the point of it existing
  /// rather than the two lines being repeated.
  /// Bring the panel forward and give it the keyboard.
  ///
  /// **Records nothing, deliberately.** An earlier revision remembered who focus was taken FROM so
  /// it could be handed back, and three review rounds each found another way for the panel to gain
  /// focus without passing through here — a raise, a mouse click, and whatever comes next. That set
  /// is AppKit's rather than ours. `releaseFocus` now derives its answer from the live world instead,
  /// so there is no record that can go stale.
  private func takeFocus(_ panel: NSPanel) {
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  /// What held the keyboard immediately before this panel took it.
  ///
  /// **Provenance, and the third attempt at where to capture it.** Recording it in `present` and
  /// `raise` enumerates ROUTES, and routes are AppKit's set — a raise, a mouse click, command-tab,
  /// the Dock — so three review rounds each found another one. Deriving it instead from "do we have
  /// another window on screen" is closed and WRONG: leave Settings open behind TextEdit, invoke the
  /// shortcut from TextEdit, and a window-list answer sends the keyboard to Settings.
  ///
  /// The closed capture point is not a list of routes at all. It is the two notifications AppKit
  /// posts however focus moved, below.
  package enum FocusOriginKind: Equatable, Sendable, CaseIterable {
    /// Another application was frontmost.
    case otherApp
    /// One of OUR windows held key — Settings, reachable because the shortcut is global.
    case ourWindow
    /// Nothing observed yet. Reachable only before either notification has fired.
    case unknown
  }

  /// Where the keyboard goes when the panel gives it up.
  package enum FocusRelease: Equatable, Sendable, CaseIterable {
    /// Hand key to the window of ours that had it. Deactivating would hide the user's own window.
    case handToOurOwnWindow
    /// Give the app behind us the keyboard back.
    case deactivateApp
  }

  /// **`unknown` deactivates, and the asymmetry is deliberate.** Guessing "our window" when the user
  /// came from another app eats the keystrokes this whole mechanism exists to protect; guessing
  /// "deactivate" when they were in our app costs them a click. The second is the cheaper error.
  package static func focusRelease(origin: FocusOriginKind) -> FocusRelease {
    origin == .ourWindow ? .handToOurOwnWindow : .deactivateApp
  }


  /// Bring an already-visible panel back to the front and give it key focus.
  ///
  /// Needed because `windowDidResignKey` is now a no-op, so a panel can be visible and unfocused —
  /// a state that did not exist while focus loss dismissed it. A second shortcut press in that state
  /// should answer "I am not sure that fired" by SHOWING the panel, not by silently doing nothing
  /// and not by throwing away the selection it already holds.
  func raise() {
    guard let panel, panel.isVisible else { return }
    takeFocus(panel)
  }

  /// Hand keyboard focus back to whatever the user was working in, WITHOUT taking the panel down.
  ///
  /// **The one property that made the confirmation safe to put in the panel at all.** This panel is
  /// key-capable because Return is the whole feature, so a panel that lingers for a beat after
  /// Return is a panel that owns the keyboard for that beat — and the user has already gone back to
  /// their sentence. The first letters of their next word would land in our search field. That cost
  /// nearly sent the confirmation to the dictation overlay instead, which is non-activating by
  /// construction.
  ///
  /// `NSApp.deactivate()` gives focus to the app behind us. The panel stays visible because
  /// `hidesOnDeactivate` is false and it sits at `.floating` — both set for their own reasons long
  /// before this needed them.
  ///
  /// **Returns exactly what `present` took, which is TWO things rather than one.** Opened from
  /// another app it took activation, and giving that back returns key status with it. Opened from
  /// our own Settings window it took activation from nobody and key status from that window, so the
  /// window is what gets it back — deactivating there would hide the user's own window instead.
  func releaseFocus() {
    guard let panel, panel.isVisible else { return }
    switch Self.focusRelease(origin: focusOrigin) {
    case .handToOurOwnWindow:
      // A window that has since been closed leaves nothing to hand to; deactivating instead would
      // be a guess about an app the user may not have come from, so do neither.
      guard let originWindow, originWindow !== panel, originWindow.isVisible else { return }
      originWindow.makeKeyAndOrderFront(nil)
    case .deactivateApp:
      NSApp.deactivate()
    }
  }

  /// Watch what holds the keyboard, so `releaseFocus` never has to know HOW the panel got it.
  ///
  /// **Two notifications, and between them they cover every route** — including the ones three
  /// review rounds found one at a time. Last writer wins, which orders them without timestamps.
  ///
  /// The panel becoming key is deliberately IGNORED rather than recorded: a mouse click on the panel
  /// activates us, and treating that as "the user is now in our app" is what would send their
  /// keyboard to the wrong place afterwards. Clicking an accessory panel is not moving into an app.
  private func installFocusObservers() {
    guard focusObservers.isEmpty else { return }
    focusObservers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        // Extracted BEFORE entering the isolated block: reading `note` inside trips Swift 6's
        // sending-risks-data-races on a task-isolated capture.
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        MainActor.assumeIsolated {
          guard let self, let app, app != NSRunningApplication.current else { return }
          self.focusOrigin = .otherApp
          self.originWindow = nil
        }
      })
    focusObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] note in
        let window = note.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self, let window, window !== self.panel else { return }
          self.focusOrigin = .ourWindow
          self.originWindow = window
        }
      })
  }

  /// Take the panel down. Idempotent.
  ///
  /// `orderOut`, never `close`: closing is what forces a rebuild, and this panel is reused.
  func dismiss() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    panel.contentViewController = nil
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
    panel?.contentViewController = nil
    onDismiss?()
  }

  /// Keep the panel centred when its content changes stage.
  ///
  /// An `NSWindow` resizes about its BOTTOM-LEFT corner, so a panel that shrinks appears to slide
  /// down the screen and one that grows appears to climb. That is fine for a window the user is
  /// dragging and wrong for one that changes height because the user pressed a button: the panel
  /// opened centred, and it should still look centred after it changes what it is asking.
  ///
  /// `center()` moves the origin and never the size, so this cannot recurse.
  func windowDidResize(_ notification: Notification) {
    guard let panel, panel.isVisible else { return }
    panel.center()
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
      // The content gets first refusal. See `shouldConsumeCancel`.
      guard !self.shouldConsumeCancel() else { return }
      self.dismiss()
      self.onDismiss?()
    }
    panel = p
    installFocusObservers()
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
