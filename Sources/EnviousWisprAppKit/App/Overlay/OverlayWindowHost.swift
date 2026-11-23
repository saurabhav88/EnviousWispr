import AppKit
import CoreGraphics
import EnviousWisprCore
import SwiftUI

/// Sole owner of the overlay's `NSPanel` (#2292, chunk C3).
///
/// **One panel for the app's lifetime, created lazily once and morphed
/// thereafter.** That single change is what removes the four compensating
/// mechanisms the shipped panel needs only because it destroys and rebuilds
/// itself on every panel-replacing transition: the inherited-frame plumbing that
/// carries Y across a rebuild, the drag-deferral that postpones work while the
/// user holds the panel, and the generation counters.
///
/// ## What the probe established, 2026-08-21
///
/// Measured on a disposable spike before any of this was written
/// (`docs/audits/2026-08-21-overlay-probe-results.md`), because keeping a window
/// alive that the shipped code closes is the one decision that could have sent
/// the design back:
///
/// - **One construction across 203 presentations**, including a size morph.
/// - Hidden with `orderOut`, the panel is absent from `NSApp`'s on-screen count,
///   absent from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` — the list
///   Mission Control and the screenshot path draw from — and absent from a real
///   screenshot taken while hidden.
/// - **Memory converges**: flat at 45.0 MB from cycle 126 through 200, a
///   one-time cost of ~2.7 MB. Ten cycles, which is what the plan specified,
///   could NOT have shown that — at ten the curve is still rising and
///   convergence is indistinguishable from a slow leak.
///
/// Two constraints came out of it and both are honoured here rather than
/// rediscovered later:
///
/// - **`occlusionState` is unreliable and is never read.** It reported
///   `.visible` while `isVisible == false` at five of nine samples, settling
///   only after an idle beat. A guard built on it would be a confident wrong
///   answer, not a flake.
/// - **Right after `orderOut` in a fast cycle the window server may still list
///   the window, at alpha 0.00.** Invisible, but present. Any test asserting
///   `onScreen == 0` immediately after hide will flake; assert absent OR alpha 0.
/// The three operations `OverlayDirector` performs on a window (#2292, C7).
///
/// **Extracted so a test can present SUCCESSFULLY without a window**, which the
/// director's own suite cannot do any other way. Sixteen suites need a director
/// only as a dependency, and the double they share used to get its silence by
/// resolving NO SCREEN -- borrowing a production FAILURE path as a stub. That
/// worked only while a refused presentation left its state behind; the C7
/// rollback makes the refusal honest and the borrowed stub stops reporting
/// anything. A fake that SUCCEEDS is what those tests always meant.
///
/// Deliberately three members and no more. Grown to mirror the host it would
/// stop being a seam and become a second copy of the window, which is the same
/// accretion this migration exists to reverse.
///
/// The real host's refusal semantics are untouched: "no screen" and "cannot be
/// sized" remain genuine failures in production.
@MainActor
protocol OverlayWindowHosting: AnyObject {
  @discardableResult
  func present(
    _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
    position: OverlayPillPosition
  ) -> Bool
  func resizeCurrentPresentation(to size: CGSize)
  func hide()
  /// The on-screen frame (global AppKit coordinates) the current presentation was placed at, or
  /// nil when nothing is on screen. Lets the root decide from the pointer's real position whether
  /// a replacement is under it.
  var placedFrame: CGRect? { get }
}

extension OverlayWindowHosting {
  /// Hosts with no real window (test doubles) place nothing.
  var placedFrame: CGRect? { nil }
}

@MainActor
final class OverlayWindowHost: OverlayWindowHosting {

  /// `nil` until the first presentation. Never released.
  ///
  /// #2455 C4: this type is the sole AppKit CONSUMER of the overlay panel driver;
  /// the live driver owns the `NSPanel` itself. "Never closed" is now structural
  /// rather than a discipline — `OverlayPanelDriving` declares no `close`.
  private var panel: (any OverlayPanelDriving)?
  private var placement = OverlayPlacementState()
  private let screens: () -> OverlayScreenResolver

  var placedFrame: CGRect? {
    guard let panel, panel.isVisible else { return nil }
    return panel.frame
  }

  /// Whether the CURRENT occupant was sized from its content, which the Top
  /// continuing rule needs in order to choose top-edge versus centre
  /// re-anchoring.
  private var currentWasContentSized = false

  /// Non-zero while this object is moving the panel itself.
  ///
  /// **This is the `windowDidMove` discriminator, and it is not the one §11.3
  /// proposed.** The plan named `NSEvent.pressedMouseButtons`; the probe
  /// measured it reading **0 at every callback including the drag one**, so it
  /// cannot separate a user drag from a programmatic move and is deliberately
  /// not used. A depth counter around our own frame changes can, and the probe
  /// confirmed it: both programmatic moves flagged, the drag-induced callback
  /// not flagged.
  private var programmaticMoveDepth = 0

  /// #2455 C4: required and non-defaulted. The old `OverlayPanelFactory` vended
  /// an `NSPanel`, so every implementation WAS a window — including the test
  /// double, which is why the suite flashed a real pill.
  private let effects: DesktopOverlayEffects

  /// Registered here rather than on the panel because **every fact this
  /// callback needs already lives in this object**: the placement anchor, the
  /// screen resolution and the window itself. On the panel it had to re-derive
  /// them and then hand the geometry back across the seam.
  ///
  /// `queue: .main` plus `MainActor.assumeIsolated` matches the shape the panel
  /// used: the notification centre guarantees the main thread, so hopping
  /// through a `Task` only adds a scheduling round trip and delays how fast the
  /// pill reacts to the swipe.
  private var spaceChangeObservation: (any WorkspaceObservation)?

  init(
    screens: @escaping () -> OverlayScreenResolver = { .live },
    effects: DesktopOverlayEffects
  ) {
    self.screens = screens
    self.effects = effects
    spaceChangeObservation = effects.workspace.observeActiveSpaceChanges { [weak self] in
      self?.repositionForActiveSpaceChange()
    }
  }

  // No `deinit`. The observation owns its own token and cancels in ITS deinit, so
  // releasing this host releases the observation and unsubscribes — one owner for
  // one lifetime. A `deinit` here could not touch the property anyway: `deinit` is
  // nonisolated and the observation is `@MainActor`-isolated and non-Sendable, and
  // the compiler says so. That constraint pointed at the better shape rather than
  // an obstacle to work around.

  // MARK: - Presenting

  /// Show `view`, sized by `width`, morphing the existing panel rather than
  /// replacing it.
  ///
  /// `isFresh` distinguishes a genuinely new presentation from one continuing an
  /// existing on-screen pill. It is the caller's fact, not something to infer
  /// from whether a panel happens to exist: a panel retained but hidden is not
  /// a continuation.
  /// Returns whether the presentation actually reached the screen.
  ///
  /// **A retained panel makes `panel != nil` useless as a success signal, and
  /// one shipped caller depends on exactly that.** showImportStatusNow guards
  /// `self.panel != nil` before claiming the slot, because `showPanel` can
  /// no-op when no screen is available — "never claim false ownership of a slot
  /// with no actual panel" (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`). Once the
  /// panel outlives every presentation that check is ALWAYS true, so it would
  /// claim ownership of a show that never happened. Cloud review caught this
  /// before the wiring chunk was written.
  @discardableResult
  func present(
    _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
    position: OverlayPillPosition
  ) -> Bool {
    // **Resolve the size BEFORE taking the panel.** A presentation that cannot be
    // sized must not create or move a window: a zero-sized panel is an invisible
    // pill that reports success, and the earlier fallback only covered ONE of
    // `fittingSize` and the frame being zero. Both zero still produced it.
    let resolver = screens()
    let continuingFrame = isFresh ? nil : panel.flatMap { $0.isVisible ? $0.frame : nil }
    let target = if let continuingFrame {
      resolver.containing(continuingFrame) ?? resolver.current()
    } else {
      resolver.fresh()
    }
    guard let screen = target,
      let size = resolvedSize(for: view, width: width, fixedHeight: fixedHeight)
    else { return false }
    let panel = ensurePanel()

    let continuity: OverlayContinuity
    if let continuingFrame {
      // The inherited frame and clamp must use the same display. If that
      // display disappeared, use the pointer fallback to keep a live target.
      continuity = .continuing(
        currentFrame: continuingFrame, anchoredScreen: screen.id,
        outgoingWasContentSized: currentWasContentSized)
    } else {
      placement.beginFresh(at: position, screen: screen)
      continuity = .fresh(position: position, screen: screen.id)
    }

    // **Keys on HEIGHT, not width.** The Top continuing rule re-anchors a
    // content-sized outgoing panel by its top edge and a fixed one by its
    // centre — a VERTICAL decision, so a measured WIDTH has no bearing on it.
    // The first predicate ORed the two axes together and would have picked the
    // wrong branch for any measured-width, fixed-height pill. It mirrors the
    // This preserves the pre-C3b `fitToContent` sizing contract.
    currentWasContentSized = fixedHeight == nil

    // **PLACE THE WINDOW BEFORE GIVING IT THE VIEW, and this order is the whole
    // fix (#2292, C21).** Assigning `contentView` makes AppKit adopt the view's
    // size AT THE WINDOW'S CURRENT ORIGIN. Placing afterwards therefore draws
    // twice: once with the NEW size at the OLD origin, once correct. Measured
    // live at 40 ms resolution, four runs: a 400-point recording pill becoming a
    // 151-point "Transcribing…" sat 124.5 points LEFT of centre for 0.52 s
    // before snapping right, and on a no-speech dictation — where the pill's
    // whole life is shorter than that — it never recentred at all.
    //
    // Ordered this way there is one placement and one draw. `display: false`
    // because nothing is on screen yet for a fresh presentation, and a
    // continuation is already showing the OUTGOING content until the view lands.
    let frame = placement.frame(for: size, continuity: continuity, environment: screen)
    withProgrammaticMove { panel.setFrame(frame, display: false) }

    // **The view FOLLOWS the window; it must not drive it.** An `NSHostingView`
    // resizes itself as SwiftUI settles, and a self-sizing content view drags
    // the window with it — AFTER the placement above has already run. That is
    // the second half of the same defect: the frame was computed for a measured
    // 150 points and the content settled at 129, leaving the pill 10.5 points
    // left of centre PERMANENTLY, on every dictation.
    //
    // Growth that is genuinely wanted still has an explicit path:
    // `onContentHeightChange` → `resizeCurrentPresentation`, which places the
    // window deliberately. This closes the implicit one.
    //
    // **The view goes INSIDE a plain container, never in as the content view
    // itself (#3850).** A hosting view that IS the window's content view resizes
    // the window on every window layout (`NSHostingView.windowDidLayout` →
    // `updateAnimatedWindowSize`), whatever its autoresizing mask or
    // `sizingOptions` say: the German "Parakeet Ultra wird heruntergeladen" pill
    // was placed at 300 x 56 and dragged to 268 x 51, each resize changed its
    // safe area and asked for another constraints pass, and AppKit ended the
    // loop with NSGenericException (ENVIOUSWISPR-7F, a 2.5.4 launch crash).
    // Inside a container it cannot reach the window; the container follows the
    // window and the view follows the container.
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    view.autoresizingMask = [.width, .height]
    view.frame = container.bounds
    container.addSubview(view)
    panel.contentView = container
    panel.orderFrontRegardless()
    // #2377 Phase 6: DEBUG-only, and `emitFirst` rather than `emit` because the
    // host orders a panel front on EVERY presentation while the benchmark is
    // about the first one. See `OverlayFirstRenderMarkers.emitFirst`.
    #if DEBUG
      // **The AX identifier is set HERE, after `orderFrontRegardless()`, never
      // in `ensurePanel()` (cloud review P1, C1 repair round 2).**
      // `accessibilityWindows` enumerates every application window, visible or
      // not — setting the identifier at construction would make the harness's
      // AX poll match the panel the instant it exists, before content is
      // attached or the panel is ordered front, timing something the user
      // cannot see. Setting it AFTER the same two calls the marker already
      // waits on keeps both signals — AX identity and the marker — bound to
      // the same real event.
      panel.setAccessibilityIdentifier(OverlayFirstRenderMarkers.axPanelIdentifier)
      // The window number is the whole point of this marker: it lets the harness
      // NAME the window whose appearance ends the keypress interval, instead of
      // accepting whichever window it happens to notice first.
      OverlayFirstRenderMarkers.emitFirst(
        OverlayFirstRenderMarkers.capture(
          .hostOrderFrontComplete, window: panel.windowNumber))
    #endif
    return true
  }

  /// Resize the CURRENT occupant without treating it as a new presentation.
  /// Live Preview grows the pill mid-recording; the shipped path cannot do this
  /// without a rebuild, which is the whole reason the preview's size is fixed
  /// for a panel's lifetime today.
  /// **Anchored to the panel's own display, exactly as `present` is.** A resize
  /// is a continuation by definition -- the pill is on screen and growing -- so
  /// resolving the POINTER's screen here mixes coordinate spaces the same way,
  /// and a shorter pointer display drags the pill down its original one. C10
  /// fixed the transition path and left this one, which is the twin the fix
  /// missed rather than a second defect.
  func resizeCurrentPresentation(to size: CGSize) {
    guard let panel, panel.isVisible else { return }
    guard let screen = screens().containing(panel.frame) ?? screens().current() else { return }
    let frame = placement.frame(
      for: size,
      continuity: .continuing(
        currentFrame: panel.frame, anchoredScreen: screen.id,
        outgoingWasContentSized: currentWasContentSized),
      environment: screen)
    withProgrammaticMove { panel.setFrame(frame, display: true) }
  }

  /// **`orderOut`, never `close`.** Closing is what forces every rebuild, and
  /// `hide` is the only thing standing between a retained panel and a hidden
  /// window that still swallows clicks — the panel accepts events across its
  /// whole frame because it is drag-to-relocate.
  func hide() {
    panel?.orderOut()
    // **Release the hosting view, or a hidden pill keeps working.** The shipped
    // panel got this for free by being destroyed. `RecordingOverlayView` runs a
    // `.task` polling the audio level every 50 ms and `OverlayCapsuleBackground`
    // runs a `repeatForever` animation; retained and merely ordered out, both
    // keep going for the rest of the session, invisibly. Nothing in the suite
    // could see it — the window is correctly hidden either way.
    panel?.contentView = nil
  }

  /// Re-anchor after the active Space changed. Bottom only, and never for a pill
  /// the user moved — both rules live in `OverlayPlacementState`.
  func repositionForActiveSpaceChange() {
    guard let panel, panel.isVisible, let screen = screens().current() else { return }
    guard
      let frame = placement.repositionedFrameForSpaceChange(
        currentFrame: panel.frame, on: screen)
    else { return }
    withProgrammaticMove { panel.setFrame(frame, display: true, animate: true) }
  }

  // MARK: - Window ownership

  private func ensurePanel() -> any OverlayPanelDriving {
    if let panel { return panel }
    // Configuration below is copied verbatim from
    // `05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift` so
    // this chunk changes the panel's LIFETIME and nothing about its identity;
    // the panel object itself comes from the injected factory so a test can
    // observe every AppKit command issued against it.
    var p = effects.makePanel()
    p.isReleasedWhenClosed = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isMovableByWindowBackground = true
    p.hasShadow = true
    // The move callback replaces `NSWindowDelegate.windowDidMove`. The driver
    // owns the delegate relationship now, so this type no longer inherits
    // `NSObject` and the callback is plain `@MainActor` rather than `nonisolated`.
    p.onMove = { [weak self] frame in self?.panelDidMove(to: frame) }
    panel = p
    return p
  }

  /// `nil` when the presentation cannot be sized, which the caller must treat as
  /// "do not present" rather than as a zero.
  private func resolvedSize(for view: NSView, width: OverlayWidth, fixedHeight: CGFloat?)
    -> CGSize?
  {
    // **`fittingSize` can be zero, and a zero-sized panel is an INVISIBLE pill
    // that reports success.** A plain `NSView` with no constraints returns
    // `.zero`, and so does a hosting view asked before layout. Found by a test
    // fixture rather than by review, which is the useful direction: the failure
    // is silent, so nothing would have reported it in production either.
    //
    // Fall back to the view's own frame, which is what a caller that sized its
    // view already means. Never to a literal default — a plausible number here
    // is exactly what `.measured` exists to forbid.
    //
    // **A fixed width with a CONTENT height is proposed inside SwiftUI, not
    // here (#3850).** `OverlayRootView.contentWidthProposal(for:)` frames that
    // pill at its width, so `fittingSize` below is the wrapped height. Narrowing
    // this view's frame never reached the text: `fittingSize` answers for an
    // unspecified width, and the #1891 advisory measured one 39-point line here
    // while the hosting view, as the window's content view, quietly stretched
    // the window to fit afterwards. That stretching was the #3850 crash loop.
    //
    // **FLUSH THE PENDING LAYOUT BEFORE MEASURING, ALWAYS (#2292, C21).**
    //
    // `render`'s comment claimed "the model is set BEFORE this runs, so the
    // retained root has already rendered the new content by the time the host
    // measures it". That is FALSE: SwiftUI applies a published change on its own
    // schedule, so without this the host measures the OUTGOING pill — the exact
    // failure that comment was written to rule out. **THIS LINE IS THAT
    // GUARANTEE**, and `render`'s doc comment now says so rather than implying
    // the ordering alone is sufficient.
    //
    // What it cost, measured live at 40 ms across four runs: the window was
    // placed for the outgoing 400-point recording pill, SwiftUI then re-rendered
    // to a 151-point "Transcribing…", and the window shrank AT THE OLD ORIGIN --
    // 124.5 points left of centre, held for 0.52 s. On a no-speech dictation the
    // pill never recentred at all, because its whole life was shorter than that.
    // The same staleness left the settled pill 10.5 points off centre on every
    // dictation: placed for a measured 150 while the content settled at 129.
    //
    // Unconditional, not just for the fixed-width case C17 added it to. A
    // measured width is measured from this same view, so a stale layout is a
    // stale WIDTH too -- the twin site, which this migration has now paid for
    // four separate times.
    view.layoutSubtreeIfNeeded()
    let fitting = view.fittingSize
    let fallback = view.frame.size
    let measuredWidth = fitting.width > 0 ? fitting.width : fallback.width
    let measuredHeight = fitting.height > 0 ? fitting.height : fallback.height
    let w: CGFloat
    switch width {
    case .fixed(let value): w = value
    case .measured: w = measuredWidth
    }
    let size = CGSize(width: w, height: fixedHeight ?? measuredHeight)
    // Both `fittingSize` and the frame can be zero — an unlaid-out view has
    // neither. Refuse rather than present nothing.
    guard size.width > 0, size.height > 0 else { return nil }
    return size
  }

  private func withProgrammaticMove(_ body: () -> Void) {
    programmaticMoveDepth += 1
    body()
    programmaticMoveDepth -= 1
  }

  /// The user dragged the pill, so its position outranks our placement rules for
  /// the rest of this presentation.
  ///
  /// **With one retained window this is a direct observation.** The shipped code
  /// can only INFER it, by comparing the outgoing panel's Y against the last
  /// origin it set (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`) — an inference that
  /// exists solely because the panel is destroyed between presentations and the
  /// fact has to survive the rebuild. Nothing survives a rebuild here, because
  /// there is no rebuild.
  ///
  /// **The screen recorded here is the one the panel LANDED on, not the one the
  /// pointer is over.** The third member of the same class as the continuation
  /// and resize anchors, and the one no review round reached: a drag ends with
  /// the panel wherever it was dropped and the pointer wherever it is, and those
  /// differ whenever the release crosses a display boundary. The id goes into
  /// `.user(origin, position, screenID)` and `isUserAnchored(on:)` compares
  /// against it later, so a wrong one makes a pill the user deliberately placed
  /// stop counting as user-anchored on its own display — and the next Space
  /// change moves it out from under them.
  private func panelDidMove(to frame: CGRect) {
    guard programmaticMoveDepth == 0 else { return }
    guard let screen = screens().containing(frame) ?? screens().current() else { return }
    placement.userDidMove(to: frame.origin, screen: screen)
  }

}

/// How the host learns about screens.
///
/// A seam rather than a direct `NSScreen` read, so the host's geometry decisions
/// are exercisable against invented displays — a full-screen space, a second
/// monitor — none of which can be arranged from a unit test.
struct OverlayScreenResolver {
  /// Pointer, then AppKit main, then the first attached display.
  let current: () -> ScreenGeometry?

  /// Placement for a new pill, including the foreground window on multiple displays.
  let fresh: () -> ScreenGeometry?

  /// The display already holding the panel. Read it from the frame so a drag
  /// or display change cannot leave a cached display attached to the panel.
  let containing: (CGRect) -> ScreenGeometry?

  init(
    containing: @escaping (CGRect) -> ScreenGeometry? = { _ in nil },
    fresh: (() -> ScreenGeometry?)? = nil,
    current: @escaping () -> ScreenGeometry?
  ) {
    self.current = current
    self.fresh = fresh ?? current
    self.containing = containing
  }

  @MainActor
  static let live = OverlayScreenResolver(
    containing: { rect in
      let displays = NSScreen.screens
      return displayIndex(containing: rect, in: displays.map(\.frame)).map {
        geometry(displays[$0])
      }
    },
    fresh: { targetDisplay(preferForegroundWindow: true) },
    current: { targetDisplay(preferForegroundWindow: false) })

  @MainActor
  private static func targetDisplay(preferForegroundWindow: Bool) -> ScreenGeometry? {
    let displays = NSScreen.screens
    let pointer = NSEvent.mouseLocation
    guard
      let fallback = displays.firstIndex(where: { $0.frame.contains(pointer) })
        ?? NSScreen.main.flatMap({ displays.firstIndex(of: $0) }) ?? displays.indices.first
    else { return nil }

    if preferForegroundWindow, displays.count > 1 {
      let target = freshDisplayIndex(
        windowBounds: foregroundWindowBounds(), displayFrames: displays.map(\.frame),
        fallback: fallback)
      // Query fullscreen only where the pointer-first path already would.
      // A different display uses the Dock-safe baseline for its first draw.
      if target != fallback {
        return geometry(displays[target])
      }
    }

    let display = displays[fallback]
    return geometry(display, hasFullScreenSpace: isFrontmostAppFullScreen(on: display))
  }

  @MainActor
  private static func foregroundWindowBounds() -> CGRect? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      // WindowServer lists these front to back. A normal window is the best
      // available target without making a new synchronous call into the app.
      let window = windows.first(where: {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
          && ($0[kCGWindowLayer as String] as? Int) == 0
      }),
      let bounds = window[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
  }

  static func freshDisplayIndex(windowBounds: CGRect?, displayFrames: [CGRect], fallback: Int)
    -> Int
  {
    guard let windowBounds, !windowBounds.isEmpty, let primary = displayFrames.first else {
      return fallback
    }
    // Quartz starts at the primary display's top-left; AppKit's Y grows up.
    let frame = CGRect(
      x: windowBounds.minX, y: primary.maxY - windowBounds.maxY,
      width: windowBounds.width, height: windowBounds.height)
    return displayIndex(containing: frame, in: displayFrames) ?? fallback
  }

  private static func displayIndex(containing rect: CGRect, in frames: [CGRect]) -> Int? {
    // Centre first, greatest overlap second when the centre falls between displays.
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    if let onCentre = frames.firstIndex(where: { $0.contains(centre) }) {
      return onCentre
    }
    let overlaps = frames.enumerated().compactMap { index, frame -> (Int, CGFloat)? in
      let hit = frame.intersection(rect)
      guard !hit.isNull, !hit.isEmpty else { return nil }
      return (index, hit.width * hit.height)
    }
    return overlaps.max(by: { $0.1 < $1.1 })?.0
  }

  @MainActor
  private static func geometry(_ screen: NSScreen, hasFullScreenSpace: Bool = false)
    -> ScreenGeometry
  {
    ScreenGeometry(
      id: ScreenID(rawValue: screen.deviceDescription[.init("NSScreenNumber")] as? Int ?? 0),
      frame: screen.frame,
      visibleFrame: screen.visibleFrame,
      hasFullScreenSpace: hasFullScreenSpace)
  }

  /// #1341: `NSScreen.visibleFrame` does NOT shrink when a DIFFERENT app is in
  /// native full screen and the Dock is hidden from view — measured empirically
  /// 2026-07-17, leaving an ~85pt unused gap below the pill.
  ///
  /// **Ported verbatim from `05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`, not written
  /// from a description of it.** The first version of this method here was
  /// composed from memory and differed in two behaviour-changing ways: it
  /// omitted the `screen == NSScreen.main` guard, so it would have reported full
  /// screen on secondary displays where the shipped code never does, and it
  /// scanned `kAXWindowsAttribute` — every window — instead of
  /// `kAXFocusedWindowAttribute`. A behaviour change wearing a port's clothes.
  ///
  /// Untrusted for Accessibility this answers false and the pill keeps the
  /// Dock-safe position, which is the shipped fallback. The alternative is
  /// requesting Screen Recording, which is a product decision and not something
  /// to fold into a positioning fix.
  @MainActor
  private static func isFrontmostAppFullScreen(on screen: NSScreen) -> Bool {
    guard screen == NSScreen.main, AXIsProcessTrusted(),
      let frontApp = NSWorkspace.shared.frontmostApplication
    else { return false }
    let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedWindow: AnyObject?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        == .success,
      let focusedWindow
    else { return false }
    // `AXUIElement` is a CFTypeRef-family type: neither `as!` nor `as?` performs
    // a real dynamic type check here (verified empirically — both silently
    // "succeed" on a wrong CF type instead of crashing or returning nil), so a
    // checked cast would only be misleading. `kAXFocusedWindowAttribute` is
    // documented to always yield an AXUIElement on `.success`; the subsequent
    // AX call is what actually fails gracefully if that contract is ever broken.
    // swift-format-ignore: NeverForceUnwrap
    let window = focusedWindow as! AXUIElement
    var fullScreenValue: AnyObject?
    guard
      AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreenValue)
        == .success
    else { return false }
    return (fullScreenValue as? Bool) ?? false
  }
}
