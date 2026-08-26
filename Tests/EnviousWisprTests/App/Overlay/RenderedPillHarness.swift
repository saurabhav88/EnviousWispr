import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Hosts `OverlayRootView` and measures what it actually renders (#2376 Phase 4, C1).
///
/// **It hosts the ROOT, never a leaf, and that is the whole reason it exists.**
/// Phase 4's named likeliest regression is correct model data rendered with the
/// WRONG visual treatment. `OverlayRootView.content(for:)` and `.notices(_:on:)`
/// are both private, so a fixture that constructs `RecoveryNoticeView` itself
/// bypasses the routing switch entirely and can never observe which leaf was
/// chosen — it would only prove that the leaf it already named draws what it
/// draws. Publishing real `PillCatalog.entry` output through the model
/// exercises the routing by construction, so a row routed through the wrong leaf
/// measures differently.
///
/// **What it measures is the ROUTED CONTENT at the width the definition asks
/// for, which is not the same thing as the window's size.** The width constraint
/// mirrors `OverlayWindowHost.resolvedSize`'s own first step — a pill asking for
/// a fixed width and a content height is asking "how tall is this at that
/// width", and an unconstrained measurement answers a different question (the
/// #1891 advisory measures 927 points wide unconstrained and 360 on screen).
/// What this deliberately does NOT reproduce is the host's `fixedHeight`
/// substitution: that is the host's arithmetic, the host's suite owns it, and
/// copying it here would put a second authority for window geometry in the test
/// target.
///
/// **What it cannot see at all, stated rather than discovered later: PAINT.**
/// Icon, icon colour, corner shape and button fill do not participate in layout,
/// and `scaleEffect` is a rendering transform `fittingSize` is blind to — the 2x
/// hands-free mark measures identically to the 1x one, recorded at
/// `RecordingOverlayPreviewChromeTests.swift:105`. This instrument proves which
/// leaf ran and what it measured. Whether the chosen treatment reached the
/// pixels is a Live UAT row and is claimed nowhere else.
///
/// **The accessibility tree is NOT readable this way, measured 2026-08-25 and
/// recorded so nobody spends the afternoon again.** A recursive
/// `accessibilityChildren()` walk over the hosted root returns exactly one
/// element — the root `AXGroup`, with an empty label and no children — for both
/// action pills, because SwiftUI populates its accessibility tree lazily under a
/// real accessibility client rather than at layout. Element labels and button
/// enablement are therefore proven by Live UAT against the running app, and by
/// the axis-differential size proof below, and by nothing else.
@MainActor
enum RenderedPillHarness {

  /// A deterministic id, so a row's identity cannot vary between runs.
  static func id() -> PresentationID { PresentationID(rawValue: UUID()) }

  /// Records what a rendered root sent back, so an action row can assert on the
  /// EVENT rather than on a closure having been called.
  final class EventRecorder: @unchecked Sendable {
    private(set) var events: [OverlayEvent] = []
    func record(_ event: OverlayEvent) { events.append(event) }
    var actions: [PillAction] {
      events.compactMap { if case .action(_, let a) = $0 { return a } else { return nil } }
    }
  }

  /// Height reported by a recording leaf's own geometry background.
  final class HeightLog: @unchecked Sendable {
    private(set) var reported: [CGFloat] = []
    func record(_ h: CGFloat) { reported.append(h) }
  }

  // MARK: - Rendering the root

  /// Measure the routed content for one definition.
  static func rootSize(
    for definition: PillDefinition?,
    model: OverlayRenderModel = OverlayRenderModel(),
    recorder: EventRecorder = EventRecorder()
  ) -> CGSize {
    model.publish(definition)
    let root = OverlayRootView(model: model, sendEvent: { recorder.record($0) })

    // **The constraint is a SwiftUI WIDTH PROPOSAL, and it took two capture
    // rounds to establish that nothing else is one.** `NSHostingView.fittingSize`
    // reports the ideal size for an UNSPECIFIED width proposal, so neither
    // narrowing the hosting view's frame nor narrowing the window it sits in
    // reaches it — both were measured, and both left the #1891 advisory
    // reporting 927 x 39, one unwrapped line, for a pill that renders at 360 and
    // wraps to three. The deleted panel constrained the advisory the same way,
    // with `.frame(width: 360)` inside the SwiftUI hierarchy, which is what this
    // reproduces.
    //
    // Applied ONLY to a fixed width with a CONTENT height, which is the one
    // combination `OverlayWindowHost.resolvedSize` constrains for the same
    // reason. A `.measured` width stays unproposed, or the measurement it exists
    // for becomes the constraint we just imposed.
    var proposal: CGFloat?
    if let definition, case .fixed(let constrained) = definition.requestedWidth,
      definition.reservesFixedHeight == nil, constrained > 0
    {
      proposal = constrained
    }

    let host: NSHostingView<AnyView> =
      proposal.map { NSHostingView(rootView: AnyView(root.frame(width: $0))) }
      ?? NSHostingView(rootView: AnyView(root))

    let frame = NSRect(x: 0, y: 0, width: proposal ?? 1000, height: 600)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return host.fittingSize
  }

  /// Measure the routed content for a non-recording request, taken from the real
  /// catalog rather than from a hand-built definition.
  static func rootSize(for request: PillCatalogRequest) -> CGSize {
    rootSize(for: PillCatalog.entry(for: request, id: id()).definition)
  }

  /// Measure a recording pill at a given design, driving the providers through
  /// `OverlayRenderModel` exactly as the director does.
  ///
  /// **The preview display goes through `setRecordingProviders`, never through
  /// the leaf's `initialPreview:` seam.** That seam bypasses
  /// `OverlayRenderModel`'s `canHoldWords` gate, so seeding it would measure the
  /// leaf's willingness to draw words rather than whether the gate let any
  /// through.
  static func recordingRootSize(
    design: RecordingPillDesign,
    locked: Bool = false,
    display: LivePreviewDisplay = .off,
    audioLevel: Float = 0.4,
    elapsed: TimeInterval = 127,
    position: OverlayPillPosition = .top
  ) -> CGSize {
    let model = OverlayRenderModel()
    model.setRecordingProviders(
      audioLevel: { audioLevel },
      recordingElapsed: { elapsed },
      livePreview: { display },
      design: design,
      position: position,
      onContentHeightChange: { _ in })
    let definition = PillDefinition(
      id: id(),
      content: .recording(
        audioLevel: audioLevel, isLocked: locked, notice: nil, design: design),
      expiry: .untilReplaced,
      requestedWidth: .fixed(design.width),
      reservesFixedHeight: design.reservedHeight)
    return rootSize(for: definition, model: model)
  }

  // MARK: - The measurement the root's fixed frame hides

  /// The CONTENT height a recording leaf reports for itself, with an optional
  /// #1060 in-panel notice set.
  ///
  /// **A different question from `recordingRootSize`, and the root cannot answer
  /// it.** The root frames a without-words recording pill to its design's
  /// reserved box, so it measures 185x92 whatever the content does — which is
  /// exactly the measurement that cannot see a notice overflowing its budget. A
  /// without-words design is also handed `onContentHeightChange = { _ in }` by
  /// `OverlayRenderModel`, so nothing in production reports this either.
  static func recordingContentHeight(
    design: RecordingPillDesign,
    locked: Bool = false,
    notice: String? = nil,
    display: LivePreviewDisplay = .off,
    width: CGFloat
  ) throws -> CGFloat {
    let log = HeightLog()
    let view = RecordingOverlayView(
      audioLevelProvider: { 0.4 },
      recordingElapsedProvider: { 127 },
      livePreviewProvider: { display },
      onContentHeightChange: { log.record($0) },
      chrome: design.chrome,
      isLocked: locked,
      noticeText: notice,
      initialPreview: display)

    let host = NSHostingView(rootView: view.frame(width: width))
    let frame = NSRect(x: 0, y: 0, width: width, height: 400)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    return try #require(
      log.reported.last,
      "the recording leaf never reported a height — the measurement is missing, not failing")
  }

  /// What the recording leaf's content WOULD take if nothing constrained it.
  ///
  /// **`recordingRootSize` cannot answer this and that is the reason this exists.**
  /// It proposes the design's own fixed width, so it returns 185 or 288 whatever
  /// the content wants — pinned by construction, and therefore blind to anything
  /// that changes how much room the content needs.
  ///
  /// Written for the hands-free treatment (#2376 Phase 4, round 5): the badge sits
  /// INLINE, so it adds no height, and height is what every other recording probe
  /// here reads. Width is the observable the inline form preserves.
  ///
  /// Same blindness as the rest of this harness, restated so it is not assumed
  /// away: this measures LAYOUT, never paint. A treatment that recolours or scales
  /// without changing what the content needs is invisible to it.
  static func recordingContentNaturalWidth(
    design: RecordingPillDesign,
    locked: Bool = false,
    notice: String? = nil,
    display: LivePreviewDisplay = .off
  ) -> CGFloat {
    let view = RecordingOverlayView(
      audioLevelProvider: { 0.4 },
      recordingElapsedProvider: { 127 },
      livePreviewProvider: { display },
      onContentHeightChange: { _ in },
      chrome: design.chrome,
      isLocked: locked,
      noticeText: notice,
      initialPreview: display)

    // No `.frame(width:)`, which is the whole point — an unproposed hosting view
    // reports what the content ideally wants.
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 2000, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return host.fittingSize.width
  }
}
