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
/// user holds the panel, the parallel `OverlayNoticeState` channel whose own doc
/// comment says it exists so a notice can morph the live pill "WITHOUT tearing
/// the panel down", and the generation counters.
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
}

@MainActor
final class OverlayWindowHost: NSObject, OverlayWindowHosting, NSWindowDelegate {

  /// `nil` until the first presentation. Never closed, never released.
  private var panel: NSPanel?
  private var placement = OverlayPlacementState()
  private let screens: () -> OverlayScreenResolver

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

  #if DEBUG
    /// The #2292 acceptance metric: reads 1 after a full dictation exercising
    /// every transition.
    private(set) var panelConstructionCount = 0
  #endif

  /// Registered here rather than on the panel because **every fact this
  /// callback needs already lives in this object**: the placement anchor, the
  /// screen resolution and the window itself. On the panel it had to re-derive
  /// them and then hand the geometry back across the seam.
  ///
  /// `queue: .main` plus `MainActor.assumeIsolated` matches the shape the panel
  /// used: the notification centre guarantees the main thread, so hopping
  /// through a `Task` only adds a scheduling round trip and delays how fast the
  /// pill reacts to the swipe.
  private nonisolated(unsafe) var spaceChangeObserver: NSObjectProtocol?

  init(screens: @escaping () -> OverlayScreenResolver = { .live }) {
    self.screens = screens
    super.init()
    spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.repositionForActiveSpaceChange() }
    }
  }

  deinit {
    if let spaceChangeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
    }
  }

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
    guard let screen = screens().current(),
      let size = resolvedSize(for: view, width: width, fixedHeight: fixedHeight)
    else { return false }
    let panel = ensurePanel()

    let continuity: OverlayContinuity
    // **The screen whose rules apply, which is NOT always the one resolved
    // above.** A fresh presentation belongs where the pointer is, which is the
    // shipped target resolution. A CONTINUING one is already somewhere, and its
    // inherited frame is in that display's coordinate space -- so the clamp and
    // the anchor have to read the same display the frame came from.
    let environment: ScreenGeometry
    if isFresh || !panel.isVisible {
      placement.beginFresh(at: position, screen: screen)
      continuity = .fresh(position: position, screen: screen.id)
      environment = screen
    } else {
      // Falls back to the pointer's screen when nothing contains the panel,
      // which is what a just-disconnected display looks like: re-home the pill
      // onto a screen that exists rather than clamp it against one that does not.
      let anchored = screens().containing(panel.frame) ?? screen
      continuity = .continuing(
        currentFrame: panel.frame, anchoredScreen: anchored.id,
        outgoingWasContentSized: currentWasContentSized)
      environment = anchored
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
    let frame = placement.frame(for: size, continuity: continuity, environment: environment)
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
    view.autoresizingMask = [.width, .height]
    view.frame = NSRect(origin: .zero, size: size)
    panel.contentView = view
    panel.orderFrontRegardless()
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
    panel?.orderOut(nil)
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

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    #if DEBUG
      panelConstructionCount += 1
    #endif
    // Configuration copied verbatim from `05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`
    // so this chunk changes the panel's LIFETIME and nothing about its identity.
    let p = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 185, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    p.isReleasedWhenClosed = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isMovableByWindowBackground = true
    p.hasShadow = true
    p.delegate = self
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
    // **CONSTRAIN THE WIDTH BEFORE MEASURING THE HEIGHT.** A pill that asks for a
    // fixed width and a CONTENT height is asking "how tall is this text at that
    // width", and an unconstrained `fittingSize` answers a different question:
    // how tall it is at whatever width it would naturally take. For the #1891
    // advisory that is one line, so the panel was then narrowed to 360 points
    // without gaining the height its sentence needs and the text was clipped.
    //
    // The deleted panel avoided this by wrapping the advisory in
    // `.frame(width: 360)` inside the SwiftUI hierarchy. Fixing it HERE instead
    // covers every fixed-width, measured-height pill rather than the one that
    // happened to be reported -- the twin-site class this repo already names
    // (`workflow-process.md` RULE: port-proven-patterns-wholesale).
    //
    // Only that combination is touched: a `.measured` width must stay
    // unconstrained, or the measurement it exists for is the constraint we just
    // imposed.
    if case .fixed(let constrained) = width, fixedHeight == nil, constrained > 0 {
      view.setFrameSize(NSSize(width: constrained, height: view.frame.height))
    }
    // **FLUSH THE PENDING LAYOUT BEFORE MEASURING, ALWAYS (#2292, C21).**
    //
    // `render`'s comment claimed "the model is set BEFORE this runs, so the
    // retained root has already rendered the new content by the time the host
    // measures it". That is FALSE: SwiftUI applies a published change on its own
    // schedule, so without this the host measures the OUTGOING pill — the exact
    // failure that comment was written to rule out.
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
  nonisolated func windowDidMove(_ notification: Notification) {
    MainActor.assumeIsolated {
      guard programmaticMoveDepth == 0, let panel else { return }
      guard let screen = screens().containing(panel.frame) ?? screens().current() else { return }
      placement.userDidMove(to: panel.frame.origin, screen: screen)
    }
  }

  #if DEBUG
    var placementForTesting: OverlayPlacementState { placement }
    var panelForTesting: NSPanel? { panel }
    var isProgrammaticallyMovingForTesting: Bool { programmaticMoveDepth > 0 }
  #endif
}

/// How the host learns about screens.
///
/// A seam rather than a direct `NSScreen` read, so the host's geometry decisions
/// are exercisable against invented displays — a full-screen space, a second
/// monitor — none of which can be arranged from a unit test.
struct OverlayScreenResolver {
  let current: () -> ScreenGeometry?

  /// The screen a given rect actually sits on, or `nil` if that cannot be
  /// answered (#2292, C10).
  ///
  /// **`current` answers "where is the POINTER", which is the wrong question for
  /// a pill already on screen.** A recording-to-processing transition inherits
  /// the live panel's frame, and the frame is in the coordinate space of the
  /// display the panel is on. Resolving the environment from the pointer instead
  /// mixes two spaces: the Y clamp then measures an inherited Y against a
  /// DIFFERENT display's `visibleFrame`, and moves the pill on its own display
  /// for no reason the user can see. Vertically arranged or differently sized
  /// monitors expose it; identical side-by-side ones hide it completely.
  ///
  /// DERIVED, not remembered. A cached "screen we last presented on" goes stale
  /// on a drag, a Space change or a display being unplugged, and stale geometry
  /// is how a pill ends up off-screen. Reading it from the frame is always
  /// current by construction.
  ///
  /// The default answers `nil` so every existing construction keeps compiling
  /// and behaving exactly as before; callers fall back to `current`, which is
  /// also the right degradation when the pill's display has just been
  /// disconnected and there is genuinely no screen containing it.
  let containing: (CGRect) -> ScreenGeometry?

  init(
    containing: @escaping (CGRect) -> ScreenGeometry? = { _ in nil },
    current: @escaping () -> ScreenGeometry?
  ) {
    self.current = current
    self.containing = containing
  }

  /// Mirrors the shipped target-screen resolution
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`): the screen under the pointer,
  /// then main, then the first attached.
  @MainActor
  static let live = OverlayScreenResolver(
    containing: { rect in
      // **Centre first, greatest overlap second.** A pill straddling a boundary
      // belongs to whichever display shows most of it, and the centre answers
      // that for every case where one display fully contains it — which is all
      // of them, in practice, because the placement rules never straddle.
      let centre = CGPoint(x: rect.midX, y: rect.midY)
      if let onCentre = NSScreen.screens.first(where: { $0.frame.contains(centre) }) {
        return OverlayScreenResolver.geometry(onCentre)
      }
      // `intersection` returns `.null` for disjoint rects, whose width and
      // height are not meaningful — so overlap is measured only where the rects
      // actually meet, and a straddling pill with no containing centre falls to
      // whichever display shows most of it.
      let overlaps = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
        let hit = screen.frame.intersection(rect)
        guard !hit.isNull, !hit.isEmpty else { return nil }
        return (screen, hit.width * hit.height)
      }
      return overlaps.max(by: { $0.1 < $1.1 }).map { OverlayScreenResolver.geometry($0.0) }
    },
    current: {
      let target =
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main ?? NSScreen.screens.first
      // A closure rather than a bare function reference: passing
      // `geometry` as a value strips its `@MainActor` isolation and does not
      // compile. Calling it keeps the isolation this closure already has.
      return target.map { OverlayScreenResolver.geometry($0) }
    })

  /// One construction of a `ScreenGeometry` from an `NSScreen`, shared by both
  /// lookups. Two copies drifting apart is how one resolver would start
  /// reporting a different full-screen answer than the other for the same
  /// display.
  @MainActor
  private static func geometry(_ screen: NSScreen) -> ScreenGeometry {
    ScreenGeometry(
      id: ScreenID(rawValue: screen.deviceDescription[.init("NSScreenNumber")] as? Int ?? 0),
      frame: screen.frame,
      visibleFrame: screen.visibleFrame,
      hasFullScreenSpace: OverlayScreenResolver.isFrontmostAppFullScreen(on: screen))
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
