import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Observation
import QuartzCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #4586 WP-H: when these fail, History's filter bar is laid out differently from before (a
/// control moves, wraps or overlaps at some window width), or typing in the search box measures
/// the bar again on every keystroke (the keystroke slows down).
@MainActor
@Suite("History filter bar layout (#4586 WP-H)", .tags(.productOutcome), .serialized)
struct HistoryFilterBarLayoutTests {
  init() { _ = NSApplication.shared }

  // MARK: Stand-ins and the original bar

  /// The bar's controls as boxes of known size, so the sweep needs no app state.
  struct Spec {
    var name: String
    var leading: CGSize?
    var tabFilter: CGSize?
    var date = CGSize(width: 126, height: 28)
    var selection = CGSize(width: 122, height: 28)  // Select + 8 + help
  }

  static let specs: [Spec] = [
    Spec(name: "Dictations", leading: nil, tabFilter: CGSize(width: 126, height: 28)),
    Spec(name: "Transcripts", leading: CGSize(width: 150, height: 28), tabFilter: nil),
    Spec(
      name: "Meetings", leading: CGSize(width: 138, height: 28),
      tabFilter: CGSize(width: 126, height: 28)),
    Spec(
      name: "Dictations selecting", leading: nil, tabFilter: CGSize(width: 126, height: 28),
      selection: CGSize(width: 112, height: 28)),
    Spec(
      name: "Transcripts selecting", leading: nil, tabFilter: nil,
      selection: CGSize(width: 112, height: 28)),
    // German-length words and a larger text size: wider, taller controls of mixed heights.
    Spec(
      name: "Meetings German, large text", leading: CGSize(width: 214, height: 36),
      tabFilter: CGSize(width: 158, height: 34), date: CGSize(width: 158, height: 34),
      selection: CGSize(width: 150, height: 34)),
  ]

  final class Frames { var rects: [String: CGRect] = [:] }

  struct Record: View {
    let name: String
    let frames: Frames
    var body: some View {
      GeometryReader { proxy in
        let _ = frames.rects[name] = proxy.frame(in: .named("bar"))
        Color.clear
      }
    }
  }

  /// The empty search field with its 180 pt floor, as the bar sizes it.
  struct SearchStandIn: View {
    @FocusState private var focused: Bool
    var body: some View {
      TextField("Search history", text: .constant("")).textFieldStyle(.plain)
        .font(.stBody).padding(.horizontal, 10).padding(.vertical, 7)
        .frame(minWidth: 180).focused($focused)
    }
  }

  /// `HistoryTabAction`'s shape: a view whose body is `EmptyView` on some tabs.
  struct LeadingStandIn: View {
    let size: CGSize?
    var body: some View {
      if let size { Color.clear.frame(width: size.width, height: size.height) }
    }
  }

  struct Box: View {
    let size: CGSize
    var body: some View { Color.clear.frame(width: size.width, height: size.height) }
  }

  /// The original three-candidate body (`HistoryFiltersView.body` at a03c2056c), over stand-ins.
  struct OriginalBar: View {
    let spec: Spec
    let frames: Frames

    var body: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DesignSpacing.md) {
          leading
          search.frame(maxWidth: .infinity)
          controls
        }
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          search.frame(maxWidth: .infinity)
          HStack(spacing: DesignSpacing.md) {
            leading
            Spacer(minLength: 0)
            controls
          }
        }
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          search.frame(maxWidth: .infinity)
          WrappingHStack(spacing: DesignSpacing.md) {
            leading
            date
            tabFilter
            HStack(spacing: DesignSpacing.md) { selection }.fixedSize()
          }
        }
      }
    }

    private var leading: some View {
      LeadingStandIn(size: spec.leading).fixedSize().background(
        Record(name: "leading", frames: frames))
    }
    private var search: some View {
      SearchStandIn().background(Record(name: "search", frames: frames))
    }
    private var date: some View {
      Box(size: spec.date).background(Record(name: "date", frames: frames))
    }
    @ViewBuilder private var tabFilter: some View {
      if let size = spec.tabFilter {
        Box(size: size).background(Record(name: "tabFilter", frames: frames))
      }
    }
    private var selection: some View {
      Box(size: spec.selection).background(Record(name: "selection", frames: frames))
    }
    private var controls: some View {
      HStack(spacing: DesignSpacing.md) {
        date
        tabFilter
        selection
      }
      .fixedSize()
    }
  }

  /// The new structure over the same stand-ins: the search row, then the production shapes.
  struct NewBar: View {
    let spec: Spec
    let frames: Frames

    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        SearchStandIn().background(Record(name: "search", frames: frames))
          .frame(maxWidth: .infinity)
        HistoryFilterControlsShapes(
          leading: LeadingStandIn(size: spec.leading).fixedSize()
            .background(Record(name: "leading", frames: frames)),
          date: Box(size: spec.date).background(Record(name: "date", frames: frames)),
          tabFilter: tabFilter,
          selection: Box(size: spec.selection)
            .background(Record(name: "selection", frames: frames)))
      }
    }

    @ViewBuilder private var tabFilter: some View {
      if let size = spec.tabFilter {
        Box(size: size).background(Record(name: "tabFilter", frames: frames))
      }
    }
  }

  private func host<Content: View>(_ content: Content, width: CGFloat) -> NSHostingView<some View> {
    let view = NSHostingView(
      rootView: content.coordinateSpace(name: "bar")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
    view.layoutSubtreeIfNeeded()
    return view
  }

  // MARK: The controls row keeps today's narrow shapes

  private func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 0.01 && abs(a.minY - b.minY) <= 0.01 && abs(a.width - b.width) <= 0.01
      && abs(a.height - b.height) <= 0.01
  }

  #if DEBUG
    /// Remembers each fixture's oracle width: finding it lays the original bar out many times.
    @MainActor private final class FitWidths { static var byName: [String: CGFloat] = [:] }

    /// The narrowest width at which the ORIGINAL bar puts the controls on one lower row, found by
    /// sweeping `OriginalBar` itself: coarse steps of 16 points upward from 60, then whole points
    /// back through the last step. A width is "one lower row" when the date control is below the
    /// search field and right of where the wrapped flow puts it. Nothing here repeats
    /// production's arithmetic.
    private func oneRowWidth(_ spec: Spec) throws -> CGFloat {
      if let known = FitWidths.byName[spec.name] { return known }
      let frames = Frames()
      let old = host(
        OriginalBar(spec: spec, frames: frames).environment(\.layoutDirection, .leftToRight),
        width: 60)
      let gap = DesignSpacing.md
      func lowerRow(at width: CGFloat) -> Bool {
        old.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        old.layoutSubtreeIfNeeded()
        guard let search = frames.rects["search"], let date = frames.rects["date"],
          date.minY >= search.maxY
        else { return false }
        let flowX = frames.rects["leading"].map { $0.maxX + gap } ?? 0
        return date.minX > flowX + 0.01
      }
      var coarse: CGFloat = 60
      while coarse < 2000, lowerRow(at: coarse) == false { coarse += 16 }
      try #require(
        coarse < 2000 && lowerRow(at: coarse),
        "\(spec.name): original lower row was never observed")
      var width = max(60, coarse - 16)
      while width < coarse, lowerRow(at: width) == false { width += 1 }
      FitWidths.byName[spec.name] = width
      return width
    }

    @Test(
      "just below, at and just above the one-row width the production shapes choose the right shape and match the original bar"
    )
    func shapesAroundTheFitThreshold() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      for spec in Self.specs {
        let threshold = try oneRowWidth(spec)
        var comparedBelow = 0
        var comparedAtOrAbove = 0
        for width in [threshold - 40, threshold - 1, threshold, threshold + 1, threshold + 40] {
          let oldFrames = Frames()
          let newFrames = Frames()
          probe.layout.reset()
          _ = host(OriginalBar(spec: spec, frames: oldFrames), width: width)
          _ = host(NewBar(spec: spec, frames: newFrames), width: width)
          let chosen = placedShape(probe, at: width)
          let expected = width >= threshold ? "oneRow" : "wrapped"
          #expect(
            chosen == expected, "\(spec.name) at \(width): chose \(chosen), expected \(expected)")
          let before = oldFrames.rects
          let after = newFrames.rects
          let search = try #require(before["search"])
          let date = try #require(before["date"])
          // Where the original put everything on one row with the search field, that is the one
          // thing that moved: nothing to compare.
          if date.minY < search.maxY { continue }
          if width >= threshold { comparedAtOrAbove += 1 } else { comparedBelow += 1 }
          #expect(Set(after.keys) == Set(before.keys), "\(spec.name) at \(width): children")
          for key in before.keys.sorted() {
            let a = try #require(before[key])
            let b = try #require(after[key])
            #expect(close(a, b), "\(spec.name) at \(width) \(key): original \(a) new \(b)")
          }
        }
        #expect(
          comparedBelow >= 2 && comparedAtOrAbove >= 2,
          "\(spec.name): compared \(comparedBelow) below, \(comparedAtOrAbove) at or above")
      }
    }
  #endif

  // MARK: Typing does not touch the controls

  final class Counts: @unchecked Sendable {
    var measurements = 0
    var bodies = 0
    var parentBuilds = 0
  }

  /// Passes size questions through to its child and counts them.
  struct CountingLayout: Layout {
    let counts: Counts
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      counts.measurements += 1
      return subviews.first?.sizeThatFits(proposal) ?? .zero
    }
    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
  }

  /// The tab's main action, counted: every size question and every rebuild.
  struct CountingLeading: View {
    let counts: Counts
    var width: CGFloat = 138
    var body: some View {
      let _ = counts.bodies += 1
      CountingLayout(counts: counts) { Color.clear.frame(width: width, height: 28) }
    }
  }

  /// A main action whose width a test can change at a fixed bar width.
  @Observable final class LeadingBox {
    var width: CGFloat = 138
  }

  struct LeadingObserved: View {
    let box: LeadingBox
    var body: some View { Color.clear.frame(width: box.width, height: 28) }
  }

  @Observable final class Modes {
    var isSelecting = false
  }

  /// The app's results value for a tab (`HistoryDiaryView.results[tab] = result`).
  @Observable final class Results {
    var byTab: [HistoryTab: Int] = [:]
  }

  /// The real bar under a parent that, like `HistoryDiaryView`, reads the tab's whole state and
  /// its results, so every keystroke and every publication builds the bar again.
  struct Parent: View {
    let coordinator: TranscriptCoordinator
    let tab: HistoryTab
    let counts: Counts
    let modes: Modes
    var results = Results()
    var leadingWidth: CGFloat = 138
    var body: some View {
      let _ = results.byTab[tab]
      let _ = counts.parentBuilds += 1
      HistoryFiltersView(
        coordinator: coordinator, tab: tab, state: coordinator.requestedHistoryState(for: tab),
        isSelecting: modes.isSelecting, toggleSelecting: {}
      ) {
        if modes.isSelecting == false { CountingLeading(counts: counts, width: leadingWidth) }
      }
    }
  }

  private func makeCoordinator() -> TranscriptCoordinator {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4586-bar-\(UUID().uuidString)", isDirectory: true)
    return TranscriptCoordinator(store: TranscriptStore(directory: dir))
  }

  /// Runs the main loop's pending work, with no waiting, then lays the view out.
  private func pump(_ view: NSView) {
    for _ in 0..<3 {
      // settle: drains already-queued main-loop work (observation updates); no time wait.
      RunLoop.main.run(mode: .default, before: .distantPast)
      view.layoutSubtreeIfNeeded()
      // The display pass a window runs after it is shown or focused.
      view.window?.displayIfNeeded()
      CATransaction.flush()
    }
  }

  private func textField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    for child in view.subviews { if let found = textField(in: child) { return found } }
    return nil
  }

  private func query(_ text: String, _ coordinator: TranscriptCoordinator, _ tab: HistoryTab) {
    var state = coordinator.requestedHistoryState(for: tab)
    state.query = text
    coordinator.setHistoryState(state, for: tab)
  }

  private func window(hosting view: NSView, width: CGFloat = 900) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
    return window
  }

  /// Types `text` into the live field the way the editor does: through its field editor, which
  /// reaches the field's binding.
  private func type(_ text: String, into field: NSTextField) throws {
    let editor = try #require(field.currentEditor() as? NSTextView, "the field has the focus")
    editor.insertText(text, replacementRange: editor.selectedRange())
  }

  #if DEBUG
    private struct Rig {
      let coordinator: TranscriptCoordinator
      let counts: Counts
      let modes: Modes
      let results: Results
      let probe: HistoryFilterBarProbe
      let view: NSHostingView<Parent>
      let window: NSWindow
      let field: NSTextField
    }

    /// Waits for an observed signal, not elapsed time: it publishes a results value for another
    /// tab and waits until the parent has built again, which SwiftUI does only after the updates
    /// queued before it, then lays out once more. The pass cap is a failure deadline only.
    private func settle(_ view: NSView, _ counts: Counts, _ results: Results) throws {
      let before = counts.parentBuilds
      results.byTab[.meetings, default: 0] += 1
      var passes = 0
      while counts.parentBuilds == before && passes < 200 {
        pump(view)
        passes += 1
      }
      try #require(counts.parentBuilds > before, "the parent built again within \(passes) passes")
      pump(view)
    }

    /// Gives the live search field the focus and checks it now owns the field editor.
    private func focus(_ rig: Rig) throws {
      rig.window.makeFirstResponder(rig.field)
      let editor = try #require(rig.field.currentEditor(), "the field has its field editor")
      try #require(rig.window.firstResponder === editor, "the field editor is the first responder")
    }

    /// The real bar in an off-screen window, laid out and settled, with the counters at zero and
    /// no focus yet. Cleanup is registered as soon as the window exists.
    private func withRig(
      tab: HistoryTab = .dictations, width: CGFloat = 900, _ body: (Rig) throws -> Void
    ) throws {
      let coordinator = makeCoordinator()
      let counts = Counts()
      let modes = Modes()
      let results = Results()
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      let view = NSHostingView(
        rootView: Parent(
          coordinator: coordinator, tab: tab, counts: counts, modes: modes, results: results))
      let window = window(hosting: view, width: width)
      defer {
        HistoryFilterBarProbe.current = nil
        window.close()
      }
      // A picker only stays presented in a window that is on screen: put it far off screen.
      window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
      window.orderFrontRegardless()
      try settle(view, counts, results)
      let field = try #require(textField(in: view), "the search field is in the bar")
      try #require(probe.rowBodies > 0, "the controls row was built")
      try #require(counts.measurements > 0, "the controls were measured")
      try #require(coordinator.requestedHistoryState(for: tab).query.isEmpty)
      let rig = Rig(
        coordinator: coordinator, counts: counts, modes: modes, results: results, probe: probe,
        view: view, window: window, field: field)
      reset(rig)
      try body(rig)
    }

    private func reset(_ rig: Rig) {
      rig.probe.rowBodies = 0
      rig.counts.measurements = 0
      rig.counts.bodies = 0
      rig.probe.layout.reset()
    }

    /// What one edit or publication cost the controls and the search row.
    private struct Cost: Equatable {
      var rowBodies: Int
      var measurements: Int
      var leadingBuilds: Int
      var searchFrameChanged: Bool
      var layoutMeasurements: Int
      var layoutArrangements: Int
    }

    private func cost(_ rig: Rig, searchFrame: CGRect, fieldFrame: CGRect) -> Cost {
      Cost(
        rowBodies: rig.probe.rowBodies, measurements: rig.counts.measurements,
        leadingBuilds: rig.counts.bodies,
        searchFrameChanged: rig.probe.frames["search"] != searchFrame
          || rig.field.frame != fieldFrame,
        layoutMeasurements: rig.probe.layout.measurements,
        layoutArrangements: rig.probe.layout.arrangements)
    }

    private let still = Cost(
      rowBodies: 0, measurements: 0, leadingBuilds: 0, searchFrameChanged: false,
      layoutMeasurements: 0, layoutArrangements: 0)

    @Test(
      "focus followed at once by the first character costs the controls row and the layout nothing")
    func focusThenFirstCharacter() throws {
      try withRig { rig in
        let searchFrame = try #require(rig.probe.frames["search"])
        let fieldFrame = rig.field.frame
        try focus(rig)
        try type("a", into: rig.field)
        try settle(rig.view, rig.counts, rig.results)
        // The first edit, before any counter is reset: the character reached the query and cost
        // the controls row, the controls and the layout nothing.
        #expect(
          rig.coordinator.requestedHistoryState(for: .dictations).query == "a",
          "the first character reached the query")
        #expect(rig.field.stringValue == "a")
        let first = cost(rig, searchFrame: searchFrame, fieldFrame: fieldFrame)
        // Focus may legitimately cost row work on its own (an earlier focus-only run did), so this
        // case asserts what the first character must never change: the layout and the search
        // frame. The strict zero for the first edit after focus settles is in
        // `typingLeavesTheControlsAlone`.
        #expect(
          first.layoutMeasurements == 0 && first.layoutArrangements == 0
            && first.searchFrameChanged == false,
          "focus plus the first character changed layout: \(first)")
        reset(rig)
        for letter in "bcdefghij" {
          try type(String(letter), into: rig.field)
          pump(rig.view)
        }
        let rest = cost(rig, searchFrame: searchFrame, fieldFrame: fieldFrame)
        #expect(rest == still, "the next nine characters cost \(rest)")
        #expect(rig.field.stringValue == "abcdefghij")
      }
    }

    @Test(
      "every typed character and every results publication leave the controls row unbuilt, unmeasured and the search row the same size; a width, selection or filter change does not"
    )
    func typingLeavesTheControlsAlone() throws {
      try withRig { rig in
        let searchFrame = try #require(rig.probe.frames["search"])
        let fieldFrame = rig.field.frame
        let selectFrame = try #require(rig.probe.frames["select"])

        // Control: pumping with no edit costs nothing, so a cost at an edit is the edit's own.
        for _ in 0..<5 { pump(rig.view) }
        let idle = cost(rig, searchFrame: searchFrame, fieldFrame: fieldFrame)
        #expect(idle == still, "idle passes cost \(idle)")
        reset(rig)

        // Typing into an already focused, empty field: the FIRST character and the rest go
        // through the real field. (Focus and the first key together are the next test.)
        try focus(rig)
        try settle(rig.view, rig.counts, rig.results)
        reset(rig)
        var typed = ""
        var edits: [Cost] = []
        for letter in "a long search about dictation notes from last week's meeting" {
          try type(String(letter), into: rig.field)
          typed.append(letter)
          pump(rig.view)
          edits.append(cost(rig, searchFrame: searchFrame, fieldFrame: fieldFrame))
          reset(rig)
        }
        #expect(
          rig.coordinator.requestedHistoryState(for: .dictations).query == typed,
          "the characters reached the query through the field's binding")
        #expect(rig.field.stringValue == typed)
        // Every character, the first included, costs the controls and the layout nothing.
        #expect(
          edits.allSatisfy { $0 == still },
          "edits that cost something: \(edits.enumerated().filter { $0.element != still }.prefix(4))"
        )
        #expect(rig.probe.frames["select"] == selectFrame, "the controls row did not move")

        // Publications: the parent assigns a new results value for the tab, as the diary does.
        var publications: [Cost] = []
        for number in 1...3 {
          rig.results.byTab[.dictations] = number
          pump(rig.view)
          publications.append(cost(rig, searchFrame: searchFrame, fieldFrame: fieldFrame))
          reset(rig)
        }
        #expect(publications.allSatisfy { $0 == still }, "publications: \(publications)")

        // Positive control 1: a new width measures the controls.
        rig.window.contentView?.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        pump(rig.view)
        #expect(rig.probe.layout.arrangements > 0, "a width change arranges the controls again")

        // Positive control 2: a filter change rebuilds the row.
        reset(rig)
        var filtered = rig.coordinator.requestedHistoryState(for: .dictations)
        filtered.app = .unknown
        rig.coordinator.setHistoryState(filtered, for: .dictations)
        pump(rig.view)
        #expect(rig.probe.rowBodies > 0, "a filter change rebuilds the controls row")

        // Positive control 3: selection mode rebuilds the row.
        reset(rig)
        rig.modes.isSelecting = true
        pump(rig.view)
        #expect(rig.probe.rowBodies > 0, "selection mode rebuilds the controls row")
      }
    }

    @Test("typing with a picker open closes it (the row changes once), then the row stays still")
    func typingClosesAnOpenPicker() throws {
      try withRig { rig in
        try focus(rig)
        try settle(rig.view, rig.counts, rig.results)
        reset(rig)
        // Open the date picker as its button does, with the focus in the search field.
        let open = try #require(rig.probe.openPicker, "the bar registered its picker control")
        open("date")
        try settle(rig.view, rig.counts, rig.results)
        try #require(rig.probe.pickerStates.last == .some("date"), "\(rig.probe.pickerStates)")
        try #require(rig.probe.rowBodies > 0, "opening the picker changed the row")
        reset(rig)
        try type("a", into: rig.field)
        try settle(rig.view, rig.counts, rig.results)
        #expect(rig.probe.pickerStates.last == .some(nil), "the character closed the picker")
        #expect(rig.probe.rowBodies == 1, "the first character closed the picker: one row change")
        reset(rig)
        for letter in "bcdefgh" {
          try type(String(letter), into: rig.field)
          pump(rig.view)
        }
        #expect(
          rig.probe.rowBodies == 0 && rig.counts.measurements == 0, "then the row stays still")
        #expect(rig.coordinator.requestedHistoryState(for: .dictations).query == "abcdefgh")
      }
    }

    // MARK: The real bar at the window minimum

    /// The shape the layout placed at exactly `width` ("oneRow", "wrapped", "mixed" if the
    /// placements at that width disagree, nil if none): the size walk's own placements at other
    /// proposals are not the bar's.
    private func placedShape(_ probe: HistoryFilterBarProbe, at width: CGFloat) -> String? {
      let shapes = Set(probe.layout.placements.filter { $0.proposalWidth == width }.map(\.oneRow))
      switch shapes {
      case [true]: return "oneRow"
      case [false]: return "wrapped"
      case []: return nil
      default: return "mixed"
      }
    }

    private func realFrames(width: CGFloat, leadingWidth: CGFloat, tab: HistoryTab) throws
      -> (frames: [String: CGRect], shape: String?)
    {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      let view = NSHostingView(
        rootView: Parent(
          coordinator: makeCoordinator(), tab: tab, counts: Counts(), modes: Modes(),
          leadingWidth: leadingWidth))
      let window = window(hosting: view, width: width)
      defer { window.close() }
      pump(view)
      return (probe.frames, placedShape(probe, at: width))
    }

    @Test(
      "the real search slot and controls fit, do not overlap and choose the right shape around the fit width and at the 750 pt window"
    )
    func realBarAroundTheFitWidthAndAtTheMinimum() throws {
      defer { HistoryFilterBarProbe.current = nil }
      // Meetings with a German-length main action (214 pt) next to the app filter.
      let leadingWidth: CGFloat = 214
      let wide = try realFrames(width: 1000, leadingWidth: leadingWidth, tab: .meetings).frames
      let gap = DesignSpacing.md
      let parts = ["leading", "date", "tabFilter", "select", "help"]
      let sum = try parts.reduce(CGFloat(0)) { $0 + (try #require(wide[$1])).width }
      // One row needs the five controls, the spacer's gap and four more gaps between them.
      let threshold = sum + 5 * gap
      let minimumContent: CGFloat = 750 - 290  // History's content at the 750 pt window
      // Whole points: the host rounds fractions, so the fit width is bracketed by whole widths.
      let below = threshold.rounded(.down) - 1
      let at = threshold.rounded(.up)
      for width in [below, at, at + 1, minimumContent, minimumContent + 100] {
        let (frames, shapes) = try realFrames(
          width: width, leadingWidth: leadingWidth, tab: .meetings)
        let expected = width >= threshold ? "oneRow" : "wrapped"
        #expect(shapes == expected, "at \(width): chose \(shapes), expected \(expected)")
        let search = try #require(frames["search"])
        #expect(
          abs(search.width - width) < 0.5 && search.height > 20,
          "the search slot fills the row: \(search)")
        let controls = try parts.map { (name: $0, frame: try #require(frames[$0])) }
        for item in controls {
          #expect(
            item.frame.minX >= -0.01 && item.frame.maxX <= width + 0.01,
            "\(item.name) inside the bar at \(width): \(item.frame)")
          #expect(item.frame.minY >= search.maxY, "\(item.name) below the search slot")
        }
        for (index, first) in controls.enumerated() {
          for second in controls[(index + 1)...] {
            let overlap = first.frame.intersection(second.frame)
            #expect(
              overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
              "\(first.name) and \(second.name) overlap at \(width)")
          }
        }
      }
    }

    // MARK: The controls layout caches every proposal of the window's size walk

    /// Asks its child the sizes a window's size walk asks, twice, and tells `after` when each
    /// round is over.
    struct Walking: Layout {
      let questions: [ProposedViewSize]
      let after: (Int) -> Void
      func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Bool) -> CGSize
      {
        if cache == false, let child = subviews.first {
          cache = true
          for round in 0..<3 {
            for question in questions {
              _ = child.sizeThatFits(question)
            }
            after(round)
          }
        }
        return proposal.replacingUnspecifiedDimensions()
      }
      func makeCache(subviews: Subviews) -> Bool { false }
      func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Bool
      ) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
      }
    }

    @Test(
      "asking the controls layout the size walk's proposals a second time measures no child; a new width and a changed leading control do"
    )
    func theSizeWalkIsCached() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      let spec = Self.specs[2]  // Meetings: leading and the app filter
      let walk: [ProposedViewSize] = [
        .zero, .unspecified, ProposedViewSize(width: 900, height: nil),
        ProposedViewSize(width: 900, height: 300), ProposedViewSize(width: 420, height: nil),
      ]
      var measured: [Int] = []
      var arranged: [Int] = []
      let walking = Walking(questions: walk) { _ in
        measured.append(probe.layout.measurements)
        arranged.append(probe.layout.arrangements)
      }
      let view = walking {
        HistoryFilterControlsShapes(
          leading: LeadingStandIn(size: spec.leading), date: Box(size: spec.date),
          tabFilter: Box(size: spec.tabFilter ?? .zero), selection: Box(size: spec.selection))
      }
      let hosting = NSHostingView(rootView: view.frame(width: 900, height: 300))
      hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
      hosting.layoutSubtreeIfNeeded()
      try #require(measured.count >= 3, "three rounds were asked: \(measured)")
      #expect(measured[0] > 0 && arranged[0] > 0, "round 1 measured: \(measured) \(arranged)")
      #expect(measured[1] == measured[0], "round 2 measured nothing new: \(measured)")
      #expect(arranged[1] == arranged[0], "round 2 arranged nothing new: \(arranged)")
      #expect(measured[2] == measured[0] && arranged[2] == arranged[0], "round 3 too")
    }

    @Test("a width change and a changed leading control are laid out again, not served stale")
    func widthAndLeadingChangesRecompute() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      let box = LeadingBox()
      let frames = Frames()
      let spec = Self.specs[2]
      let view = NSHostingView(
        rootView: HistoryFilterControlsShapes(
          leading: LeadingObserved(box: box).background(Record(name: "leading", frames: frames)),
          date: Box(size: spec.date).background(Record(name: "date", frames: frames)),
          tabFilter: Box(size: spec.tabFilter ?? .zero), selection: Box(size: spec.selection)
        )
        .coordinateSpace(name: "bar")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
      let window = window(hosting: view, width: 900)
      defer { window.close() }
      pump(view)
      try #require(probe.layout.arrangements > 0)
      #expect(frames.rects["leading"]?.width == 138, "\(String(describing: frames.rects))")
      let before = probe.layout.arrangements

      // Same width, same children, nothing changed: nothing is recomputed.
      pump(view)
      #expect(probe.layout.arrangements == before)

      // The leading control gets wider at the same width: the layout lays it out again.
      box.width = 220
      pump(view)
      #expect(probe.layout.arrangements > before, "arranged again after the leading change")
      #expect(frames.rects["leading"]?.width == 220, "\(String(describing: frames.rects))")

      // The leading control gets so wide that the row no longer fits: the same width now wraps,
      // and the date control moves next to it on the first row.
      #expect(placedShape(probe, at: 900) == "oneRow")
      let oneRowDate = try #require(frames.rects["date"])
      probe.layout.reset()
      box.width = 520
      pump(view)
      #expect(placedShape(probe, at: 900) == "wrapped", "crossing the one-row boundary re-chose")
      let wrappedDate = try #require(frames.rects["date"])
      #expect(wrappedDate.minX == 520 + DesignSpacing.md && wrappedDate.minY == 0, "\(wrappedDate)")
      #expect(oneRowDate.minX != wrappedDate.minX, "the date control moved: \(oneRowDate)")

      // A new width is a new proposal.
      let afterLeading = probe.layout.arrangements
      view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
      pump(view)
      #expect(probe.layout.arrangements > afterLeading, "arranged again after the width change")
      #expect(placedShape(probe, at: 520) == "wrapped")
    }

    // MARK: Wrapped-row breaks, right-to-left, and heights

    /// The widths at which the original wrapped bar puts an item on another row: the first width
    /// whose row positions differ from the one before it, below the one-row width.
    private func wrapBreaks(_ spec: Spec) throws -> [CGFloat] {
      let fit = try oneRowWidth(spec)
      let frames = Frames()
      let old = host(OriginalBar(spec: spec, frames: frames), width: 60)
      func signature() -> [CGFloat] {
        ["leading", "date", "tabFilter", "selection"].map { frames.rects[$0]?.minY ?? -1 }
      }
      var breaks: [CGFloat] = []
      var previous = signature()
      var width: CGFloat = 61
      while width < fit {
        old.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        old.layoutSubtreeIfNeeded()
        let now = signature()
        if now != previous { breaks.append(width) }
        previous = now
        width += 1
      }
      return breaks
    }

    @Test(
      "just below, at and just above every wrapped-row break of every fixture the controls sit where the original bar put them"
    )
    func wrappedRowBreaksMatchTheOriginalBar() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      for spec in Self.specs {
        let breaks = try wrapBreaks(spec)
        try #require(breaks.isEmpty == false, "\(spec.name): the original wraps somewhere")
        for edge in breaks {
          for width in [edge - 1, edge, edge + 1] {
            let oldFrames = Frames()
            let newFrames = Frames()
            probe.layout.reset()
            _ = host(OriginalBar(spec: spec, frames: oldFrames), width: width)
            _ = host(NewBar(spec: spec, frames: newFrames), width: width)
            #expect(placedShape(probe, at: width) == "wrapped", "\(spec.name) at \(width)")
            for key in oldFrames.rects.keys.sorted() {
              let a = try #require(oldFrames.rects[key])
              let b = try #require(newFrames.rects[key])
              #expect(close(a, b), "\(spec.name) at \(width) \(key): original \(a) new \(b)")
            }
          }
        }
      }
    }

    @Test(
      "under right-to-left the one row and the wrapped rows sit where the original bar put them")
    func rightToLeftMatchesTheOriginalBar() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      let spec = Self.specs[2]  // wide Meetings: leading and the app filter
      let fit = try oneRowWidth(spec)
      for (width, shape) in [
        (fit + 40, "oneRow"), (fit - 60, "wrapped"), (CGFloat(400), "wrapped"),
      ] {
        let oldFrames = Frames()
        let newFrames = Frames()
        probe.layout.reset()
        _ = host(
          OriginalBar(spec: spec, frames: oldFrames).environment(\.layoutDirection, .rightToLeft),
          width: width)
        _ = host(
          NewBar(spec: spec, frames: newFrames).environment(\.layoutDirection, .rightToLeft),
          width: width)
        #expect(placedShape(probe, at: width) == shape, "at \(width)")
        for key in oldFrames.rects.keys.sorted() {
          let a = try #require(oldFrames.rects[key])
          let b = try #require(newFrames.rects[key])
          #expect(close(a, b), "right-to-left at \(width) \(key): original \(a) new \(b)")
        }
        // The control that sits first in reading order is at the right edge.
        if let leading = newFrames.rects["leading"] {
          #expect(leading.maxX > width / 2, "leading at the right: \(leading) in \(width)")
        }
      }
    }

    @Test("nine proposal heights at one wrapped width measure once")
    func heightsShareOneArrangement() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      let spec = Self.specs[2]
      let walk = (1...9).map { ProposedViewSize(width: 420, height: CGFloat($0) * 50) }
      var measured: [Int] = []
      var arranged: [Int] = []
      let walking = Walking(questions: walk) { _ in
        measured.append(probe.layout.measurements)
        arranged.append(probe.layout.arrangements)
      }
      let view = walking {
        HistoryFilterControlsShapes(
          leading: LeadingStandIn(size: spec.leading), date: Box(size: spec.date),
          tabFilter: Box(size: spec.tabFilter ?? .zero), selection: Box(size: spec.selection))
      }
      let hosting = NSHostingView(rootView: view.frame(width: 900, height: 300))
      hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
      hosting.layoutSubtreeIfNeeded()
      try #require(measured.count >= 3, "rounds were asked: \(measured)")
      #expect(arranged[0] == 1, "nine heights, one arrangement: \(arranged)")
      #expect(measured[0] > 0, "the first call measured: \(measured)")
      #expect(measured[1] == measured[0] && measured[2] == measured[0], "then nothing: \(measured)")
    }

    // MARK: The date button's words

    /// A plain clock the test advances by hand: nothing observes it, so only a notification
    /// can make the label read it again.
    final class Clock {
      var now: Date
      init(_ now: Date) { self.now = now }
    }

    /// The titles this test's label drew (earlier tests' bars, still alive, also hear the posts).
    private func mine(_ probe: HistoryFilterBarProbe, _ interval: DateInterval) -> [String] {
      probe.dateTitles.filter { $0.interval == interval }.map(\.title)
    }

    @Test("the same saved interval reads Today, then Yesterday after the day changes")
    func dateLabelFollowsTheDay() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      let calendar = Calendar.current
      let first =
        calendar.date(
          from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)) ?? Date()
      let clock = Clock(first)
      let today = HistoryDateFilter.today.interval(now: first, calendar: calendar)
      let view = NSHostingView(
        rootView: HistoryDateButtonLabel(interval: today, now: { clock.now }))
      let window = window(hosting: view)
      defer { window.close() }
      pump(view)
      #expect(mine(probe, today).last == HistoryDateFilter.today.title, "\(probe.dateTitles)")

      // Midnight passes with History open; the saved interval is untouched. Until the system
      // says the day changed, nothing makes the label read the clock again.
      clock.now = try #require(calendar.date(byAdding: .day, value: 1, to: first))
      pump(view)
      #expect(
        mine(probe, today).last == HistoryDateFilter.today.title,
        "still Today before the notification: \(probe.dateTitles)")
      NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
      pump(view)
      #expect(mine(probe, today).last == HistoryDateFilter.yesterday.title, "\(probe.dateTitles)")

      // The other two clocks recompute too (control: the count moves for each).
      let before = mine(probe, today).count
      NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
      pump(view)
      let afterZone = mine(probe, today).count
      NotificationCenter.default.post(
        name: NSLocale.currentLocaleDidChangeNotification, object: nil)
      pump(view)
      #expect(afterZone > before && mine(probe, today).count > afterZone)
    }
    @Test("an unfiltered date label does not redraw when the day, the zone or the locale changes")
    func unfilteredDateLabelStaysQuiet() throws {
      let probe = HistoryFilterBarProbe()
      HistoryFilterBarProbe.current = probe
      defer { HistoryFilterBarProbe.current = nil }
      let calendar = Calendar.current
      let now =
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)) ?? Date()
      let active = HistoryDateFilter.today.interval(now: now, calendar: calendar)
      let quiet = NSHostingView(rootView: HistoryDateButtonLabel(interval: nil, now: { now }))
      let live = NSHostingView(rootView: HistoryDateButtonLabel(interval: active, now: { now }))
      let first = window(hosting: quiet)
      let second = window(hosting: live)
      defer {
        first.close()
        second.close()
      }
      pump(quiet)
      pump(live)
      func draws(_ interval: DateInterval?) -> Int {
        probe.dateTitles.filter { $0.interval == interval }.count
      }
      let unfilteredBefore = draws(nil)
      let activeBefore = draws(active)
      try #require(unfilteredBefore >= 1 && activeBefore >= 1, "both labels drew once")
      for name in [
        Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
        NSLocale.currentLocaleDidChangeNotification,
      ] {
        NotificationCenter.default.post(name: name, object: nil)
      }
      pump(quiet)
      pump(live)
      #expect(draws(nil) == unfilteredBefore, "\"Any time\" did not redraw")
      #expect(draws(active) > activeBefore, "control: a label with an active interval did redraw")
    }
  #endif

  // MARK: The field follows the query

  @Observable final class TabBox { var tab: HistoryTab = .dictations }

  struct TabParent: View {
    let coordinator: TranscriptCoordinator
    let tabBox: TabBox
    var body: some View {
      Parent(coordinator: coordinator, tab: tabBox.tab, counts: Counts(), modes: Modes())
    }
  }

  @Test("an external clear and a tab switch reach the search field")
  func externalWritesReachTheField() throws {
    let coordinator = makeCoordinator()
    let tabBox = TabBox()
    let view = NSHostingView(rootView: TabParent(coordinator: coordinator, tabBox: tabBox))
    let window = window(hosting: view)
    defer { window.close() }
    pump(view)
    let field = try #require(textField(in: view), "the search field is in the bar")

    query("hello", coordinator, .dictations)
    pump(view)
    #expect(field.stringValue == "hello", "an outside write shows in the field")
    query("", coordinator, .dictations)  // what HistoryDiaryLayout.opening does
    pump(view)
    #expect(field.stringValue == "", "an outside clear empties the field")

    query("alpha", coordinator, .dictations)
    query("beta", coordinator, .transcripts)
    pump(view)
    tabBox.tab = .transcripts
    pump(view)
    #expect(try #require(textField(in: view)).stringValue == "beta", "a tab switch shows its query")
    tabBox.tab = .dictations
    pump(view)
    #expect(try #require(textField(in: view)).stringValue == "alpha")
  }
}
