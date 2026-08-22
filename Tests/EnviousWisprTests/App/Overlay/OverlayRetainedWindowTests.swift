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
/// the §11.1 Live UAT, reading panelConstructionCountForTesting after a real
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

  /// **The four compensating mechanisms, frozen out by NAME.**
  ///
  /// They existed for ONE reason: every overlay transition destroyed the window
  /// and built another, so the code needed a generation counter to tell a stale
  /// deferred creation from a live one, a handle on that pending work to cancel
  /// it, drag deferral so a rebuild did not fight the user's mouse, and a
  /// `CATransaction` flush to stop the gap between destroy and create rendering
  /// as a blink. With one retained window there is nothing to compensate for.
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

  /// **A per-owner ceiling, because the failure mode of this migration is one
  /// file becoming the thing it replaced.** `RecordingOverlayPanel` reached 3,368
  /// lines by being the only place anything about the overlay could live; nothing
  /// stopped it, and no single commit was where it went wrong.
  ///
  /// The numbers are today's `wc -l` rounded up, not a target — the point is that
  /// crossing one is a DECISION rather than a drift. Raise a row deliberately and
  /// say why, exactly as the app's other ceilings require; if a row needs raising
  /// twice, the responsibility probably belongs in a new owner instead.
  ///
  /// `OverlayLegacyViews.swift` is exempt and named rather than silently omitted:
  /// it is the nine leaf views moved WHOLE in C1, byte-identical, and its cleanup
  /// is explicitly outside this migration. Capping it would invite exactly the
  /// unrelated edit this migration keeps out of its own diff.
  @Test("no overlay owner grows into the panel it replaced")
  func perOwnerCeilings() throws {
    let ceilings: [String: Int] = [
      "OverlayAccessibilityEligibility.swift": 60,
      "OverlayChipWiring.swift": 80,
      "OverlayDirector.swift": 680,
      "OverlayOutputRouter.swift": 100,
      "OverlayPlacementState.swift": 220,
      "OverlayReducer.swift": 790,
      "OverlayRenderModel.swift": 110,
      "OverlayRootView.swift": 240,
      "OverlayVocabulary.swift": 470,
      "OverlayWindowHost.swift": 390,
    ]
    let root = RepoRoot.url.appending(path: "Sources/EnviousWisprAppKit/App/Overlay")
    for (name, ceiling) in ceilings.sorted(by: { $0.key < $1.key }) {
      let url = root.appending(path: name)
      let text = try String(contentsOf: url, encoding: .utf8)
      let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
      #expect(
        count <= ceiling,
        "\(name) is \(count) lines against a ceiling of \(ceiling). Raise it deliberately and say why, or move the responsibility to a new owner.")
    }

    // The set is CHECKED, not assumed: a new owner added to the module without a
    // ceiling is exactly how the old one grew unnoticed.
    let onDisk = try FileManager.default
      .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      .map(\.lastPathComponent)
      .filter { $0 != "OverlayLegacyViews.swift" }
    #expect(
      Set(onDisk) == Set(ceilings.keys),
      "the overlay module and this ceiling table disagree: \(Set(onDisk).symmetricDifference(Set(ceilings.keys)))")
  }
}
// **Only the BEHAVIOURAL suite below is DEBUG-only.** It reads
// panelConstructionCountForTesting, which lives inside `#if DEBUG` on the
// panel, so without this guard the RELEASE build of the test target does not
// compile — something a Debug-only local run cannot see by construction.
//
// The two guards ABOVE it read source files and need no seam at all. Wrapping
// the whole file, which is what the first repair did, silently dropped two
// configuration-independent structural guards out of the Release lane: a fix
// that created the next defect, which is the shape this migration keeps
// producing.
#if DEBUG
  /// The BEHAVIOURAL half, which I had wrongly concluded was untestable.
  ///
  /// **Product Outcome**, and the sentence finishes: when this fails the user sees
  /// the pill blink as it is destroyed and rebuilt — the stated root cause of #930.
  ///
  /// I moved this claim to Live UAT after finding that a synchronous test creates
  /// no window (every `showPanel` is queued with `DispatchQueue.main.async`) and
  /// that observing it seemed to need a run-loop pump, which
  /// the local test-timing guard rejects the pump. Asked directly whether I had talked myself
  /// out of a guard I should have written, cloud review said yes and named the
  /// mechanism: **a main-queue barrier is a SIGNAL, not a clock.** Enqueueing a
  /// continuation behind the work under test resumes only after that work has run,
  /// so it waits on the subject rather than on time — exactly what
  /// `never-guess-when-the-subject-is-finished` asks for, and no annotation needed.
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
      let host = OverlayWindowHost()
      let d = OverlayDirector(
        host: host, deliverEffect: { _ in }, deliverAppAction: { _ in },
        announce: { _ in })
      defer { host.panelForTesting?.orderOut(nil) }

      d.send(.pipeline(.processing(phase: .polishing)), actions: nil)
      await drainMainQueue()
      #expect(
        host.panelConstructionCount == 1,
        "no window was built at all — this guard is asserting nothing")

      d.send(.pipeline(.accessibilityToast), actions: nil)
      await drainMainQueue()
      d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)
      await drainMainQueue()

      #expect(
        host.panelConstructionCount == 1,
        """
        the overlay built a second window for a transition. Every rebuild is the \
        #930 flicker this migration removes.
        """)
    }

    /// Hiding must ORDER OUT, never close: a closed `NSPanel` is a destroyed one,
    /// and the next presentation would have to build another.
    @Test("hiding and showing again reuses the same window")
    func hideThenShowReusesTheWindow() async {
      let host = OverlayWindowHost()
      let d = OverlayDirector(
        host: host, deliverEffect: { _ in }, deliverAppAction: { _ in },
        announce: { _ in })
      defer { host.panelForTesting?.orderOut(nil) }

      for _ in 0..<4 {
        d.send(.pipeline(.processing(phase: .polishing)), actions: nil)
        await drainMainQueue()
        d.dismissSilently()
        await drainMainQueue()
      }

      #expect(
        host.panelConstructionCount == 1,
        "hiding released the window, so the next presentation had to build a new one")
    }
  }
#endif
