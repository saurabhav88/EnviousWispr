import AppKit
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #2292. **The one-window claim, asserted structurally.**
///
/// **Drift Guard, and the class matters here.** When this fails we changed our
/// own code; the user sees nothing at the moment of failure. It must never be
/// cited as evidence that the pill renders correctly — the behavioural proof is
/// the §11.1 Live UAT, reading the panel construction count after a real
/// dictation.
///
/// ## Why this is structural rather than behavioural
///
/// The first version of this suite drove the legacy API and asserted the
/// construction counter. It passed with a measured count of **ZERO**: every
/// `showPanel` is queued with `DispatchQueue.main.async`, so a synchronous test
/// never creates a window at all. Probing the number rather than trusting the
/// green is the only reason that was found.
///
/// Making it observable seemed to need a run-loop pump, which
/// the local test-timing guard rejects the pump. That was the wrong conclusion and it is
/// corrected below rather than left standing: a MAIN-QUEUE BARRIER waits on the
/// subject, not on time, and `OverlayRetainedWindowBehaviourTests` in this file
/// now proves the legacy API reaches the retained host. **These structural
/// guards own a different question** — that no OTHER site can construct or close
/// a window — and Live UAT remains the end-to-end visual proof.
///
/// Reading the source is the only available mechanism, the same reason
/// `TestInventoryFreezeTests` parses rather than reflects. **It PARSES rather
/// than matching text**, and that was not optional: the first version searched
/// for `.close()` as a string and fired on `OverlayWindowHost`'s own doc comment
/// explaining why it never calls `close()`. A guard whose subject is a
/// construct will match prose ABOUT that construct — this repo's
/// comparison-narrower-than-the-language shape, met immediately.
///
/// Known limit, stated rather than discovered later: it proves no OTHER site
/// constructs or closes a panel, not that the one remaining site is correct —
/// the host suite owns that.
@Suite(.tags(.driftGuard))
struct OverlayRetainedWindowTests {

  /// Every `NSPanel(...)` construction and every `.close()` call in a file,
  /// found by walking the syntax tree so comments and string literals are
  /// excluded STRUCTURALLY rather than one lexical form at a time.
  private final class PanelCallFinder: SyntaxVisitor {
    private(set) var constructs = 0
    private(set) var closes = 0

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
        callee.baseName.text == "NSPanel"
      {
        constructs += 1
      }
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "close", node.arguments.isEmpty
      {
        closes += 1
      }
      return .visitChildren
    }
  }

  private static func panelCalls(in text: String) -> (constructs: Int, closes: Int) {
    let finder = PanelCallFinder(viewMode: .sourceAccurate)
    finder.walk(Parser.parse(source: text))
    return (finder.constructs, finder.closes)
  }

  private static func overlayModuleSources() throws -> [(name: String, text: String)] {
    let root = RepoRoot.url.appending(path: "Sources/EnviousWisprAppKit")
    var found: [(String, String)] = []
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
    }
    return found
  }

  /// Exactly one `NSPanel(` constructor in the whole module, and it is the host's.
  @Test("only OverlayWindowHost constructs a panel")
  func onlyTheHostConstructsAPanel() throws {
    let sources = try Self.overlayModuleSources()
    #expect(sources.count > 50, "the sweep found almost nothing — it is pointed at the wrong tree")

    let constructors = sources.filter { Self.panelCalls(in: $0.text).constructs > 0 }
    #expect(
      constructors.map(\.name) == ["OverlayWindowHost.swift"],
      """
      \(constructors.map(\.name)) construct an NSPanel. Exactly one owner may, or \
      the retained window is not retained: a second constructor is a second \
      window, which is the #930 flicker returning by another route.
      """)
  }

  /// Zero `.close()` calls. Closing is what forces every rebuild, and the four
  /// compensating mechanisms this migration removes exist only because of it.
  @Test("nothing in the overlay module closes a window")
  func nothingClosesAWindow() throws {
    let offenders = try Self.overlayModuleSources()
      .filter { Self.panelCalls(in: $0.text).closes > 0 }
      .map(\.name)
    #expect(
      offenders.isEmpty,
      """
      \(offenders) call .close() on a window. `orderOut` hides; `close` destroys \
      and is what every rebuild came from. A retained panel that gets closed is \
      strictly worse than the shipped code, because nothing rebuilds it.
      """)
  }

  /// **The rebuild-compensating mechanisms, frozen out by NAME.**
  ///
  /// **THIS COMMENT USED TO SAY THEY EXISTED FOR ONE REASON, AND THAT WAS FALSE
  /// OF `pendingCreateWork`.** Three of them do compensate for rebuilding: drag
  /// deferral so a rebuild does not fight the user's mouse, a `CATransaction`
  /// flush so the gap between destroy and create does not render as a blink, and
  /// a generation counter to tell a stale deferred creation from a live one.
  /// With one retained window there is nothing there to compensate for.
  ///
  /// `pendingCreateWork` was ALSO the vehicle for a crash fix, and the deleted
  /// panel said so at its own call site: creating an `NSHostingView` while the
  /// status-item menu dismiss animation runs causes a re-entrant `NSWindow`
  /// layout cycle and SIGABRT. Deleting it on the "one reason" argument removed
  /// the crash fix with the compensation, and four local review rounds passed it
  /// — cloud review caught it as a P1.
  ///
  /// **`deferFirstRender` is that fix, restored under a name this guard does not
  /// ban.** It is not an evasion: the banned name meant per-presentation pending
  /// creation with a cancel handle, and this defers exactly once for the lifetime
  /// of a director. Naming it differently is what keeps the guard honest about
  /// which idea is actually forbidden.
  ///
  /// **Named rather than derived, and that is a real weakness of this guard**:
  /// it cannot recognise the same idea under a different word. It is a tripwire
  /// on the exact shapes that were removed, not a proof that no equivalent
  /// returns. The structural guarantee is the one above — no second constructor
  /// and no close — and this catches the tell-tales that always accompanied
  /// them, which is worth having precisely because someone reintroducing this
  /// pattern will reach for these names.
  @Test("the four rebuild-compensating mechanisms stay gone")
  func compensatingMechanismsStayGone() throws {
    // **`generation` was a fourth name here and is deliberately NOT.** The panel
    // used it for a rebuild counter; `LanguageChipPayload` uses it for the chip's
    // own staleness token, which is legitimate, unrelated and present in three
    // files of this module. A guard that fires on correct code is the shape this
    // repo's own precision tally argues against — it trains people to route
    // around the guard rather than to stop and look. Dropped rather than
    // exempted, because an allowlist is the same defect with paperwork.
    let banned = ["pendingCreateWork", "deferringIfPanelIsBeingDragged", "CATransaction"]
    var offenders: [String] = []
    for source in try Self.overlayModuleSources() where source.name.hasPrefix("Overlay") {
      // Comments describe why these are gone, which is the point of the file
      // they are gone from — so only CODE counts, found the same structural way
      // the panel sweep is.
      let code = source.text.split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
      for name in banned where code.contains(name) {
        offenders.append("\(source.name): \(name)")
      }
    }
    #expect(
      offenders.isEmpty,
      """
      \(offenders) reintroduce a mechanism that exists only to survive a window \
      being destroyed and rebuilt. With one retained window there is nothing to \
      survive; if one of these is genuinely needed again, the retained window has \
      already been lost and THAT is the defect.
      """)
  }
}
/// The BEHAVIOURAL half, migrated off the deleted `#if DEBUG` accessors onto
/// `OverlayPanelCommandRecorder` (#2377, P6-C2) — this whole suite is now
/// Release-visible, closing the gap the earlier `#if DEBUG` wrapper (which used
/// to cover this whole file) left in `build-release`.
///
/// **Product Outcome**, and the sentence finishes: when this fails the user sees
/// the pill blink as it is destroyed and rebuilt — the stated root cause of #930.
///
/// A synchronous test creates no window on its own (every `showPanel` is
/// queued with `DispatchQueue.main.async`) and observing it needs a run-loop
/// pump, which the local test-timing guard rejects. **A main-queue barrier is
/// a SIGNAL, not a clock.** Enqueueing a continuation behind the work under
/// test resumes only after that work has run, so it waits on the subject
/// rather than on time — exactly what `never-guess-when-the-subject-is-finished`
/// asks for, and no annotation needed.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayRetainedWindowBehaviourTests {

  init() { _ = NSApplication.shared }

  /// Resumes after everything already queued on the main queue has run —
  /// including the deferred panel creation. FIFO ordering is the whole
  /// mechanism; there is no interval anywhere in it.
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  /// **The property this whole migration exists to establish.** Several
  /// transitions, ONE window. Every rebuild is the #930 flicker, and the four
  /// compensating mechanisms #2292 removes — generations, pending work, drag
  /// deferrals, `CATransaction.flush` — exist only to paper over it.
  ///
  /// **Rewritten rather than deleted at the cutover.** It used to drive the
  /// panel's `showPolishing` / `showAccessibilityToast` / `showWarning`; those
  /// methods are gone with the class, and the same three transitions are now
  /// three intents. Deleting it would have removed the only guard on the claim
  /// the branch is named for.
  @Test("several transitions build one window")
  func transitionsReuseTheRetainedWindow() async {
    let recorder = OverlayPanelCommandRecorder()
    let host = OverlayWindowHost(panelFactory: recorder.makeFactory())
    let d = OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      selections: { .shipped },
      deferFirstRender: { $0() })
    defer { recorder.panel?.orderOut(nil) }

    d.present(.processing(phase: .polishing))
    await drainMainQueue()
    #expect(
      recorder.constructionCount == 1,
      "no window was built at all — this guard is asserting nothing")

    d.present(.accessibilityNotice)
    await drainMainQueue()
    d.present(.warning(reason: .polishFailed))
    await drainMainQueue()

    #expect(
      recorder.constructionCount == 1,
      """
      the overlay built a second window for a transition. Every rebuild is the \
      #930 flicker this migration removes.
      """)
  }

  /// Hiding must ORDER OUT, never close: a closed `NSPanel` is a destroyed one,
  /// and the next presentation would have to build another.
  @Test("hiding and showing again reuses the same window")
  func hideThenShowReusesTheWindow() async {
    let recorder = OverlayPanelCommandRecorder()
    let host = OverlayWindowHost(panelFactory: recorder.makeFactory())
    let d = OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      selections: { .shipped },
      deferFirstRender: { $0() })
    defer { recorder.panel?.orderOut(nil) }

    for _ in 0..<4 {
      d.present(.processing(phase: .polishing))
      await drainMainQueue()
      d.dismissCurrent(.silent)
      await drainMainQueue()
    }

    #expect(
      recorder.constructionCount == 1,
      "hiding released the window, so the next presentation had to build a new one")
  }
}

/// **The real-panel integration Codex ruled C2 needed (#2377): retained
/// identity proven with a genuine base `NSPanel`, not the recording subclass.**
///
/// The recorder above proves the host issues the right AppKit COMMANDS; it says
/// nothing about what a real `NSPanel` does in response to them, because the
/// recording subclass overrides those same methods. This suite injects
/// `OverlayPanelFactory.live` itself — the identical factory production uses —
/// so the panel under test is exactly what ships.
///
/// **Show / hide / show, asserting identity across all three, not just the
/// last one.** A host that rebuilt on hide would still show correctly the
/// second time; only comparing the SAME `ObjectIdentifier` across the full
/// cycle catches that.
///
/// **`willCloseNotification`, not just final visibility.** `isVisible == false`
/// is what BOTH `orderOut` and `close` leave behind on a panel with
/// `isReleasedWhenClosed = false` — the earlier mutation control found exactly
/// this (`compensatingMechanismsStayGone`'s sibling test up the file). The
/// notification is the only observation that tells them apart without reading
/// private host state.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayRetainedWindowRealPanelTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  @Test("a real panel survives show, hide, show with identity intact")
  func showHideShowRetainsTheRealPanel() throws {
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { Self.screen } }, panelFactory: .live)

    nonisolated(unsafe) var closed = false
    var closeToken: NSObjectProtocol?
    defer { closeToken.map(NotificationCenter.default.removeObserver) }

    let firstView = NSView(frame: NSRect(x: 0, y: 0, width: 185, height: 44))
    #expect(
      host.present(
        firstView, width: .fixed(185), fixedHeight: nil, isFresh: true, position: .bottom)
    )
    // The panel exists only after the first `present`, so the close observer is
    // attached here rather than before — there is nothing to observe earlier.
    let panel = try #require(firstView.window)
    closeToken = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: panel, queue: nil
    ) { _ in closed = true }
    defer { host.hide() }

    #expect(panel.isVisible, "show did not put the panel on screen")
    #expect(panel.contentView === firstView, "show did not attach the content view")

    host.hide()
    #expect(panel.isVisible == false, "hide left the panel on screen")
    #expect(panel.contentView == nil, "hide left the previous content attached")

    let secondView = NSView(frame: NSRect(x: 0, y: 0, width: 185, height: 44))
    #expect(
      host.present(
        secondView, width: .fixed(185), fixedHeight: nil, isFresh: true, position: .bottom)
    )
    let secondPanel = try #require(secondView.window)

    #expect(
      ObjectIdentifier(secondPanel) == ObjectIdentifier(panel),
      "show after hide built a NEW panel — the window is not retained")
    #expect(secondPanel.isVisible, "the second show did not put the panel back on screen")
    #expect(secondPanel.contentView === secondView, "the second show kept the old content view")
    #expect(
      closed == false,
      "the panel was CLOSED at some point in show/hide/show — orderOut never posts this")
  }
}
